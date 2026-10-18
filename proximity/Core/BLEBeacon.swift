import CoreBluetooth
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Broadcasts and hears anonymous beacons. The whole payload rides in one 128-bit service UUID.
/// [sharerisk] Version 2, what this build sends (`payload(id:risk:score:days:)`):
///   bytes 0-3  "FLU2" magic
///   byte  4    status: bits 0-1 risk level (0...2), bits 2-5 days since symptom onset or positive test
///              (0...14, 15 = unknown), bits 6-7 zero
///   byte  5    own score p as round(255 · sqrt(p)), decoded (b/255)²: finest near the 2% baseline
///   bytes 6-15 ephemeral ID (10 bytes, rotates)
/// Version 1, still accepted from older builds (score and days unknown):
///   bytes 0-3  "FLU1" magic, byte 4 risk level, bytes 5-15 ephemeral ID (11 bytes)
/// 80 random bits are still collision-safe: with n IDs alive the chance any two match is about n²/2^81, so
/// a campus of 20,000 phones rotating every 15 min (~1.9 M IDs a day, 7·10^8 a year) collides with
/// probability ~2·10^-7 over a whole year, and two IDs must also be heard in the same place to matter.
/// No connection is needed, so risk status gets through even if the peer link is down.
///
/// iOS hides that UUID from scanners while the advertising app is in the background. With
/// `worksInBackground` (FlUni) the beacon also advertises the fixed `BeaconGATT.service` UUID and serves
/// the same 16 bytes from a GATT characteristic; a second scanner looks for that UUID (iOS requires a
/// named service to scan in the background, and to match another phone's background advert at all) and
/// reads the payload over a short connection when the advert doesn't carry it. Privacy is unchanged:
/// the same rotating ID, status, days and score, read over GATT instead of from the advert.
final class BLEBeacon: NSObject, CBPeripheralManagerDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let magic: [UInt8] = [0x46, 0x4C, 0x55, 0x31]
    // [sharerisk] begin: beacon v2 constants
    /// "FLU2": status + days, score, 10-byte ID.
    static let magic2: [UInt8] = [0x46, 0x4C, 0x55, 0x32]
    /// Ephemeral ID length in a v2 beacon (v1: 11).
    static let idBytes = 10
    static let maxDays = 14
    static let unknownDays: UInt8 = 15
    // [sharerisk] end

    /// (beacon contents, smoothed RSSI)
    var onSighting: ((Hit, Double) -> Void)?
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
    private var reading: [UUID: (peripheral: CBPeripheral, rssi: Double)] = [:]  // scanQueue only
    private var restored: [CBPeripheral] = []  // scanQueue only
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

    // [sharerisk] begin: advertise v2; encode/decode v1 + v2
    /// Advertises a v2 beacon. A call with the same contents as now is a no-op, so the 1 s tick can call
    /// this every time without restarting the radio.
    func advertise(id: Data, risk: Risk, score: Double, days: Int?) {
        guard let p = Self.payload(id: id, risk: risk, score: score, days: days) else { return }
        guard p != payload else { return }
        payload = p
        gattValue = BeaconGATT.bytes(p)  // what the GATT characteristic serves from now on
        restartAdvertising()
    }

    /// What a beacon says. `score` and `daysSinceOnset` are nil from a v1 beacon (older builds) and when
    /// days are unknown. Other people's score and days are used for the estimate only: never shown in FlUni.
    struct Hit: Equatable {
        let id: String
        let risk: Risk
        let score: Double?
        let daysSinceOnset: Int?
    }

    /// One byte for a probability: round(255 · sqrt(p)). sqrt spends the resolution near 0 (steps of ~0.1
    /// percentage point at 2%). nil for NaN, infinities and values outside [0, 1].
    static func scoreByte(_ p: Double) -> UInt8? {
        guard p.isFinite, p >= 0, p <= 1 else { return nil }
        return UInt8((255 * p.squareRoot()).rounded())
    }

    static func score(fromByte b: UInt8) -> Double {
        let x = Double(b) / 255
        return x * x
    }

    /// Status byte: risk in bits 0-1, days in bits 2-5 (clamped to 0...14; nil = 15, unknown), bits 6-7 zero.
    static func statusByte(risk: Risk, days: Int?) -> UInt8 {
        let d = days.map { UInt8(min(max($0, 0), maxDays)) } ?? unknownDays
        return UInt8(risk.rawValue) | d << 2
    }

    /// nil for a risk level outside 0...2 or non-zero spare bits.
    static func status(fromByte b: UInt8) -> (risk: Risk, days: Int?)? {
        guard b & 0xC0 == 0, let r = Risk(rawValue: Int(b & 0x03)) else { return nil }
        let d = (b >> 2) & 0x0F
        return (r, d == unknownDays ? nil : Int(d))
    }

    /// The 16 payload bytes of a v2 beacon as a UUID: "FLU2", status, score, 10-byte ID.
    /// nil for a wrong-length ID or a score that isn't a probability.
    static func payload(id: Data, risk: Risk, score: Double, days: Int?) -> CBUUID? {
        guard id.count == idBytes, let sb = scoreByte(score) else { return nil }
        return CBUUID(data: Data(magic2 + [statusByte(risk: risk, days: days), sb]) + id)
    }

    /// A v1 beacon ("FLU1", risk, 11-byte ID), as older builds send. Kept for compatibility tests.
    static func payload(id: Data, risk: Risk) -> CBUUID? {
        guard id.count == 11 else { return nil }
        return CBUUID(data: Data(magic + [UInt8(risk.rawValue)]) + id.prefix(11))
    }

    static func decode(_ uuid: CBUUID) -> Hit? {
        let d = uuid.data
        guard d.count == 16 else { return nil }
        // Check the magic in place; most adverts on a busy campus aren't ours.
        let b = d.startIndex
        guard d[b] == magic[0], d[b + 1] == magic[1], d[b + 2] == magic[2] else { return nil }
        if d[b + 3] == magic[3] {
            guard let risk = Risk(rawValue: Int(d[b + 4])) else { return nil }
            return Hit(id: d[(b + 5)...].hex, risk: risk, score: nil, daysSinceOnset: nil)
        }
        guard d[b + 3] == magic2[3], let st = status(fromByte: d[b + 4]) else { return nil }
        return Hit(id: d[(b + 6)...].hex, risk: st.risk, score: score(fromByte: d[b + 5]), daysSinceOnset: st.days)
    }
    // [sharerisk] end

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
                for p in restored { c.cancelPeripheralConnection(p) }  // half-done reads from before the relaunch
                restored.removeAll()
            } else {
                reading.removeAll()  // connections are gone with the radio
                limiter.reset()
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
        report(hit, raw)
    }

    /// scanQueue. Median over the last few seconds: single BLE samples swing by ±10 dB.
    private func report(_ hit: Hit, _ raw: Double) {  // [sharerisk] Hit instead of (id, risk)
        let now = Date()
        let s = smoothed[hit.id, default: RSSIWindow()].add(raw, at: now)
        if now.timeIntervalSince(lastPrune) > 30 {  // rotated IDs would otherwise pile up
            lastPrune = now
            smoothed = smoothed.filter { $0.value.lastAt.map { now.timeIntervalSince($0) < 30 } ?? false }
        }
        DispatchQueue.main.async { self.onSighting?(hit, s) }
    }

    // MARK: Reading a background advertiser over GATT (scanQueue)

    private func gattDiscover(_ c: CBCentralManager, _ p: CBPeripheral, _ ad: [String: Any], _ rssi: NSNumber) {
        let raw = rssi.doubleValue
        guard !paused, raw < 0, raw > -110 else { return }
        let uuids = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (ad[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        if let hit = uuids.lazy.compactMap(Self.decode).first {
            // A foreground FlUni: the open scan reports it while we're in the foreground; in the background
            // only this scan runs.
            if inBackground { report(hit, raw) }
            return
        }
        // Fixed UUID but no payload: FlUni in the background (or a hash collision in another app's overflow
        // area, which the read below rejects). Connect, read 16 bytes, disconnect.
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
        guard reading[p.identifier] != nil else { c.cancelPeripheralConnection(p); return }
        p.delegate = self
        p.discoverServices([BeaconGATT.service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { finish(p) }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { finish(p) }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == BeaconGATT.service }) else { finish(p); return }
        p.discoverCharacteristics([BeaconGATT.characteristic], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let ch = s.characteristics?.first(where: { $0.uuid == BeaconGATT.characteristic }) else { finish(p); return }
        p.readValue(for: ch)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        defer { finish(p) }
        guard ch.uuid == BeaconGATT.characteristic, let r = reading[p.identifier], !paused,
              let value = ch.value, let hit = BeaconGATT.decode(value) else { return }
        log("bg gatt read peer=\(hit.id.prefix(6)) risk=\(hit.risk) rssi=\(Int(r.rssi))")
        report(hit, r.rssi)
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
