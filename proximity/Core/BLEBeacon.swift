import CoreBluetooth
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Broadcasts and hears anonymous beacons. The whole payload rides in one 128-bit service UUID:
///   bytes 0-3  "FLU1" magic
///   byte  4    risk level
///   bytes 5-15 ephemeral ID (rotates)
/// No connection is needed, so risk status gets through even if the peer link is down.
///
/// iOS hides that UUID from scanners while the advertising app is in the background. With
/// `worksInBackground` (FlUni) the beacon also advertises the fixed `BeaconGATT.service` UUID and serves
/// the same 16 bytes from a GATT characteristic; a second scanner looks for that UUID (iOS requires a
/// named service to scan in the background, and to match another phone's background advert at all) and
/// reads the payload over a short connection when the advert doesn't carry it. Privacy is unchanged:
/// the same rotating ID and 3-level status, read over GATT instead of from the advert.
final class BLEBeacon: NSObject, CBPeripheralManagerDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let magic: [UInt8] = [0x46, 0x4C, 0x55, 0x31]

    /// (ephemeral ID hex, risk, smoothed RSSI, samples in the median window)
    var onSighting: ((String, Risk, Double, Int) -> Void)?
    var onState: ((String) -> Void)?
    /// One-line events for the "[fluni]" log, delivered on the main queue.
    var onLog: ((String) -> Void)?
    /// A nearby phone is about to read our payload over GATT (main queue). This can be the only time
    /// iOS runs FlUni for a while, so the owner may rotate the ID first.
    var onRead: (() -> Void)?
    /// FlUni sets this before start(): fixed UUID + GATT service, background scanning, state restoration.
    /// The harness leaves it off and behaves exactly as before.
    var worksInBackground = false

    private var peripheral: CBPeripheralManager!
    private var central: CBCentralManager!
    /// Scans for BeaconGATT.service only (worksInBackground). Runs in the foreground too: a phone whose
    /// FlUni is in the background is only visible to a scan that names the service.
    private var gattCentral: CBCentralManager?
    private var payload: CBUUID?
    private var gattValue: Data?  // payload's 16 bytes, copied (main queue)
    private var serviceAdded = false  // main queue
    private let scanQueue = DispatchQueue(label: "fluni.ble.scan")  // keeps the advert flood off the main thread
    private var smoothed: [String: RSSIWindow] = [:]  // scanQueue only
    private var lastPrune = Date()
    private var limiter = ConnectLimiter()  // scanQueue only
    private var reading: [UUID: (peripheral: CBPeripheral, rssi: Double?)] = [:]  // scanQueue only; nil rssi: reconnect/restore
    private var restored: [CBPeripheral] = []  // scanQueue only
    // flu-offdetect: links held open for off-screen ranging (Core/OffScreenRanging.swift). scanQueue only.
    private var held = HeldLinks()
    private var heldChars: [UUID: (peripheral: CBPeripheral, characteristic: CBCharacteristic)] = [:]
    private var pollPending: Set<UUID> = []
    private var reconnecting: [UUID: (peripheral: CBPeripheral, since: Date)] = [:]
    private var advertAt: [String: Date] = [:]  // last advert-borne sample per ID
    private var pollLog: [UUID: (at: Date, polls: Int)] = [:]
    private let pauseLock = NSLock()
    private var _paused = false
    private var paused: Bool {
        get { pauseLock.lock(); defer { pauseLock.unlock() }; return _paused }
        set { pauseLock.lock(); _paused = newValue; pauseLock.unlock() }
    }
    private var _inBackground = false
    private var inBackground: Bool {
        get { pauseLock.lock(); defer { pauseLock.unlock() }; return _inBackground }
        set { pauseLock.lock(); _inBackground = newValue; pauseLock.unlock() }
    }

    /// Stops advertising and scanning. Safe to call twice. Radios stay allocated; resume() restarts them.
    func stop() {
        paused = true
        peripheral?.stopAdvertising()
        scanQueue.sync {
            central?.stopScan()
            gattCentral?.stopScan()
            for r in reading.values { gattCentral?.cancelPeripheralConnection(r.peripheral) }
            reading.removeAll()
            limiter.reset()
            smoothed.removeAll()
            releaseAllLinks()  // flu-offdetect
        }
    }

    /// Starts again after stop() (or for the first time, if the app launched paused).
    func resume() {
        guard peripheral != nil else { paused = false; start(); return }
        paused = false
        onState?("advertiser \(peripheral.state.name)")
        onState?("scanner \(central.state.name)")
        restartAdvertising()
        scanQueue.async { self.restartScan() }
    }

    func start() {
        #if os(iOS)
        if worksInBackground {
            inBackground = UIApplication.shared.applicationState == .background
            // Restore identifiers let iOS keep advertising and scanning for FlUni after the system ends it,
            // and relaunch it in the background on a Bluetooth event (not after the user swipes it away).
            peripheral = CBPeripheralManager(delegate: self, queue: nil,
                                             options: [CBPeripheralManagerOptionRestoreIdentifierKey: "fluni.advertiser"])
            gattCentral = CBCentralManager(delegate: self, queue: scanQueue,
                                           options: [CBCentralManagerOptionRestoreIdentifierKey: "fluni.scanner"])
        }
        #endif
        if peripheral == nil { peripheral = CBPeripheralManager(delegate: self, queue: nil) }
        central = CBCentralManager(delegate: self, queue: scanQueue)
        // Radios can be left idle or stale after a trip through the background or a Bluetooth toggle.
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.inBackground = false
            self?.restartAdvertising()
            self?.scanQueue.async { self?.restartScan() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.inBackground = true
        }
        #endif
    }

    private func restartScan() {
        guard !paused else { return }
        if let central, central.state == .poweredOn {
            central.stopScan()
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
        // Background scans must name a service; duplicates are coalesced there, but help in the foreground.
        if let gattCentral, gattCentral.state == .poweredOn {
            gattCentral.stopScan()
            gattCentral.scanForPeripherals(withServices: [BeaconGATT.service],
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    private func log(_ s: String) {
        DispatchQueue.main.async { self.onLog?(s) }
    }

    func peripheralManagerDidStartAdvertising(_ p: CBPeripheralManager, error: Error?) {
        guard error != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.restartAdvertising() }
    }

    func advertise(id: Data, risk: Risk) {
        guard let p = Self.payload(id: id, risk: risk) else { return }
        payload = p
        gattValue = BeaconGATT.bytes(p)  // what the GATT characteristic serves from now on
        restartAdvertising()
    }

    /// The 16 payload bytes as a UUID: "FLU1", risk, 11-byte ID.
    static func payload(id: Data, risk: Risk) -> CBUUID? {
        guard id.count == 11 else { return nil }
        return CBUUID(data: Data(magic + [UInt8(risk.rawValue)]) + id.prefix(11))
    }

    static func decode(_ uuid: CBUUID) -> (id: String, risk: Risk)? {
        let d = uuid.data
        guard d.count == 16 else { return nil }
        // Check the magic in place; most adverts on a busy campus aren't ours.
        let b = d.startIndex
        guard d[b] == magic[0], d[b + 1] == magic[1], d[b + 2] == magic[2], d[b + 3] == magic[3],
              let risk = Risk(rawValue: Int(d[b + 4])) else { return nil }
        return (d[(b + 5)...].hex, risk)
    }

    private func restartAdvertising() {
        guard !paused, let peripheral, peripheral.state == .poweredOn, let payload else { return }
        peripheral.stopAdvertising()
        // Payload first: a foreground advert has room for one 128-bit UUID, and open scans need the payload.
        // The fixed UUID then goes to the overflow area, where scans that name it still match.
        let uuids = worksInBackground ? [payload, BeaconGATT.service] : [payload]
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: uuids])
    }

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        onState?("advertiser \(p.state.name)")
        if p.state != .poweredOn {
            serviceAdded = false  // iOS drops published services when Bluetooth goes off
        } else if worksInBackground && !serviceAdded {
            serviceAdded = true
            p.removeAllServices()  // a restored launch may still have the previous run's copy
            let ch = CBMutableCharacteristic(type: BeaconGATT.characteristic, properties: [.read], value: nil,
                                             permissions: [.readable])  // nil value: answered live, so rotation shows at once
            let svc = CBMutableService(type: BeaconGATT.service, primary: true)
            svc.characteristics = [ch]
            p.add(svc)
        }
        restartAdvertising()
    }

    /// Serves the current payload: exactly the bytes the advert carries, nothing more.
    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == BeaconGATT.characteristic else {
            p.respond(to: request, withResult: .attributeNotFound); return
        }
        onRead?()
        guard !paused, let value = gattValue else { p.respond(to: request, withResult: .unlikelyError); return }
        guard let slice = BeaconGATT.slice(value, offset: request.offset) else {
            p.respond(to: request, withResult: .invalidOffset); return
        }
        request.value = slice
        p.respond(to: request, withResult: .success)
        if request.offset == 0, let me = BeaconGATT.decode(value) { onLog?("bg gatt served me=\(me.id.prefix(6))") }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c === gattCentral {
            if c.state == .poweredOn {
                // flu-offdetect: a link iOS kept open across the relaunch is read again and held; anything else
                // is a half-done read from before the relaunch.
                for p in restored {
                    if worksInBackground, p.state == .connected, !paused { adopt(p) } else { c.cancelPeripheralConnection(p) }
                }
                restored.removeAll()
            } else {
                reading.removeAll()  // connections are gone with the radio
                limiter.reset()
                held.reset()  // flu-offdetect
                heldChars.removeAll()
                reconnecting.removeAll()
            }
            restartScan()
            return
        }
        let s = "scanner \(c.state.name)"
        DispatchQueue.main.async { self.onState?(s) }
        restartScan()
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        if c === gattCentral { gattDiscover(c, p, advertisementData, rssi); return }
        let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard !paused, let hit = uuids.lazy.compactMap(Self.decode).first else { return }
        let raw = rssi.doubleValue
        guard raw < 0, raw > -110 else { return }  // 127 = unavailable
        report(hit, raw, fromAdvert: true)
    }

    /// scanQueue. Median over the last few seconds: single BLE samples swing by ±10 dB.
    /// `fromAdvert`: the sample came from an advert (not a GATT read or a held link's RSSI poll).
    private func report(_ hit: (id: String, risk: Risk), _ raw: Double, fromAdvert: Bool) {
        let now = Date()
        let s = smoothed[hit.id, default: RSSIWindow()].add(raw, at: now)
        let n = smoothed[hit.id]?.samples.count ?? 1
        if fromAdvert { advertAt[hit.id] = now }
        if now.timeIntervalSince(lastPrune) > 30 {  // rotated IDs would otherwise pile up
            lastPrune = now
            smoothed = smoothed.filter { $0.value.lastAt.map { now.timeIntervalSince($0) < 30 } ?? false }
            advertAt = advertAt.filter { now.timeIntervalSince($0.value) < 30 }
        }
        DispatchQueue.main.async { self.onSighting?(hit.id, hit.risk, s, n) }
    }

    // MARK: Reading a background advertiser over GATT (scanQueue)

    private func gattDiscover(_ c: CBCentralManager, _ p: CBPeripheral, _ ad: [String: Any], _ rssi: NSNumber) {
        let raw = rssi.doubleValue
        guard !paused, raw < 0, raw > -110 else { return }
        let uuids = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (ad[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        let hit = uuids.lazy.compactMap(Self.decode).first
        // flu-offdetect: a phone we already hold a link to. Its advert RSSI is the best sample there is; a
        // backgrounded one's advert has no payload, so it is filed under the ID last read over the link.
        if let h = held.link(p.identifier) {
            held.heard(p.identifier, rssi: raw)
            if let hit {
                if inBackground { report(hit, raw, fromAdvert: true) }
            } else {
                report((h.id, h.risk), raw, fromAdvert: true)
            }
            kickPoll(p)
            return
        }
        if let hit {
            // A foreground FlUni: the open scan reports it while we're in the foreground; in the background
            // only this scan runs.
            if inBackground { report(hit, raw, fromAdvert: true) }
            // flu-offdetect: also open a link to it, so ranging carries on once either phone is locked.
            guard admitLink(rssi: raw) else { return }
        }
        // Fixed UUID but no payload: FlUni in the background (or a hash collision in another app's overflow
        // area, which the read below rejects). Connect and read 16 bytes; the link then stays open if there
        // is room (HeldLinks), else it is closed.
        let now = Date()
        guard limiter.tryBegin(p.identifier, at: now) else { return }
        reading[p.identifier] = (p, raw)
        c.connect(p, options: nil)
        scanQueue.asyncAfter(deadline: .now() + 15) { [weak self] in self?.finish(p) }  // give up on a stuck connect
    }

    private func finish(_ p: CBPeripheral) {
        guard reading.removeValue(forKey: p.identifier) != nil else { return }
        limiter.end(p.identifier)
        gattCentral?.cancelPeripheralConnection(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        if reconnecting.removeValue(forKey: p.identifier) != nil {  // flu-offdetect: a held link came back
            log("hold reconnected")
            adopt(p)
            return
        }
        guard reading[p.identifier] != nil else { c.cancelPeripheralConnection(p); return }
        p.delegate = self
        p.discoverServices([BeaconGATT.service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if reconnecting.removeValue(forKey: p.identifier) != nil { return }  // flu-offdetect
        finish(p)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        // flu-offdetect: a held link dropped (out of range, or the peer's Bluetooth went off). A pending connect
        // has no timeout and completes, waking FlUni, when that phone is back in range, even with both locked.
        if held.link(p.identifier) != nil {
            held.drop(p.identifier)
            heldChars[p.identifier] = nil
            pollLog[p.identifier] = nil
            guard !paused, c === gattCentral else { return }
            let since = Date()
            reconnecting[p.identifier] = (p, since)
            c.connect(p, options: nil)
            log("hold lost links=\(held.count) reconnecting")
            scanQueue.asyncAfter(deadline: .now() + HeldLinks.reconnectFor) { [weak self] in
                guard let self, let r = self.reconnecting[p.identifier], r.since == since else { return }
                self.reconnecting[p.identifier] = nil
                self.gattCentral?.cancelPeripheralConnection(p)
            }
            return
        }
        finish(p)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == BeaconGATT.service }) else { finish(p); return }
        p.discoverCharacteristics([BeaconGATT.characteristic], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let ch = s.characteristics?.first(where: { $0.uuid == BeaconGATT.characteristic }) else { finish(p); return }
        p.readValue(for: ch)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        let r = reading[p.identifier]
        let wasHeld = held.link(p.identifier)
        guard ch.uuid == BeaconGATT.characteristic, r != nil || wasHeld != nil, !paused, error == nil,
              let value = ch.value, let hit = BeaconGATT.decode(value) else {
            if r != nil { finish(p) } else if wasHeld != nil { schedulePoll(p, after: HeldLinks.pollInterval) }
            return
        }
        if let r {
            log("bg gatt read peer=\(hit.id.prefix(6)) risk=\(hit.risk) rssi=\(r.rssi.map { "\(Int($0))" } ?? "-")")
            if let rssi = r.rssi { report(hit, rssi, fromAdvert: false) }
        } else if let w = wasHeld, w.id != hit.id || w.risk != hit.risk {
            log("hold reread peer=\(hit.id.prefix(6)) risk=\(hit.risk)")
        }
        // flu-offdetect: keep the link open (re-read, or a new link with room) and poll its RSSI; else close it.
        guard worksInBackground, held.read(p.identifier, id: hit.id, risk: hit.risk, rssi: r?.rssi, at: Date()) else {
            finish(p)
            return
        }
        heldChars[p.identifier] = (p, ch)
        if r != nil {
            reading.removeValue(forKey: p.identifier)
            limiter.end(p.identifier)
            log("hold open peer=\(hit.id.prefix(6)) links=\(held.count)")
            schedulePoll(p, after: 0)  // first RSSI sample at once
        } else {
            schedulePoll(p, after: HeldLinks.pollInterval)
        }
    }

    // MARK: Held links: RSSI polling while off screen (flu-offdetect; logic in Core/OffScreenRanging.swift)

    /// Room for a link to a phone heard at `rssi`? A full table releases its weakest link for a much stronger one.
    private func admitLink(rssi: Double) -> Bool {
        guard worksInBackground else { return false }
        switch held.admit(rssi: rssi) {
        case .room: return true
        case .full: return false
        case .replace(let weak):
            log("hold released for a nearer phone")
            release(weak)
            return true
        }
    }

    private func release(_ id: UUID) {
        let hc = heldChars.removeValue(forKey: id)
        held.drop(id)
        pollLog[id] = nil
        if let hc { gattCentral?.cancelPeripheralConnection(hc.peripheral) }
    }

    private func releaseAllLinks() {
        for id in Array(heldChars.keys) { release(id) }
        held.reset()
        for r in reconnecting.values { gattCentral?.cancelPeripheralConnection(r.peripheral) }
        reconnecting.removeAll()
        advertAt.removeAll()
    }

    /// A connected peripheral we have no read for (a held link that reconnected, or one iOS restored):
    /// read its payload again; the link is then held as after any read.
    private func adopt(_ p: CBPeripheral) {
        reading[p.identifier] = (p, nil)
        p.delegate = self
        p.discoverServices([BeaconGATT.service])
        scanQueue.asyncAfter(deadline: .now() + 15) { [weak self] in self?.finish(p) }
    }

    private func schedulePoll(_ p: CBPeripheral, after s: TimeInterval) {
        guard pollPending.insert(p.identifier).inserted else { return }
        scanQueue.asyncAfter(deadline: .now() + max(s, 0)) { [weak self] in
            guard let self else { return }
            self.pollPending.remove(p.identifier)
            self.poll(p)
        }
    }

    /// Something woke us (an advert from that phone): poll now if a poll is due and none is queued.
    private func kickPoll(_ p: CBPeripheral) {
        if !pollPending.contains(p.identifier) { poll(p) }
    }

    private func poll(_ p: CBPeripheral) {
        guard !paused, p.state == .connected, let hc = heldChars[p.identifier] else { return }
        let now = Date()
        switch held.next(p.identifier, at: now) {
        case .none: return
        case .wait(let s): schedulePoll(p, after: s); return
        case .readRSSI: p.readRSSI()
        case .readPayload: p.readValue(for: hc.characteristic)
        }
        held.polled(p.identifier, at: now)
        // Watchdog: a read that never answers must not end the chain. Normally the answer has queued the
        // next poll by then and this does nothing.
        scanQueue.asyncAfter(deadline: .now() + 3 * HeldLinks.pollInterval) { [weak self] in
            guard let self, !self.pollPending.contains(p.identifier) else { return }
            if case .wait = self.held.next(p.identifier, at: Date()) { return }
            self.poll(p)
        }
    }

    func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard let h = held.link(p.identifier) else { return }
        defer { schedulePoll(p, after: HeldLinks.pollInterval) }
        guard error == nil, !paused else { return }
        let raw = RSSI.doubleValue, now = Date()
        if raw < 0, raw > -110 { held.heard(p.identifier, rssi: raw) }
        let used = HeldLinks.reports(rssi: raw, lastAdvert: advertAt[h.id], now: now)
        if used { report((h.id, h.risk), raw, fromAdvert: false) }
        // One line per link per 10 s: polls since, this sample, and the current window median (in the
        // foreground the advert's), so connection and advert RSSI can be compared.
        var pl = pollLog[p.identifier] ?? (at: .distantPast, polls: 0)
        pl.polls += 1
        if now.timeIntervalSince(pl.at) >= 10 {
            let win = smoothed[h.id]?.samples.map(\.rssi).sorted()
            let med = win.flatMap { $0.isEmpty ? nil : $0[$0.count / 2] }
            log("hold poll peer=\(h.id.prefix(6)) conn=\(Int(raw)) win=\(med.map { "\(Int($0))" } ?? "-") n=\(win?.count ?? 0) "
                + "used=\(used ? "yes" : "no") polls=\(pl.polls) bg=\(inBackground ? "yes" : "no") links=\(held.count)")
            pl = (now, 0)
        }
        pollLog[p.identifier] = pl
    }

    // MARK: State restoration (iOS relaunched FlUni for a Bluetooth event)

    #if os(iOS)
    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        let scanning = (dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID])?.isEmpty == false
        log("bg restore scanner peripherals=\(restored.count) scanning=\(scanning)")
    }

    func peripheralManager(_ p: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        let services = (dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService])?.count ?? 0
        let advertising = dict[CBPeripheralManagerRestoredStateAdvertisementDataKey] != nil
        onLog?("bg restore advertiser services=\(services) advertising=\(advertising)")
    }
    #endif
}

extension CBManagerState {
    var name: String {
        switch self {
        case .poweredOn: return "on"
        case .poweredOff: return "off"
        case .unauthorized: return "not allowed"
        case .unsupported: return "unsupported"
        default: return "starting"
        }
    }
}

extension Data {
    var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8](); out.reserveCapacity(count * 2)
        for b in self { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 15)]) }
        return String(decoding: out, as: UTF8.self)
    }
}
