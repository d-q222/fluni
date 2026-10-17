import CoreLocation
import Foundation
import MultipeerConnectivity
import UIKit
import UserNotifications

/// Everything known about one nearby Fluni phone, keyed by its ephemeral ID.
struct PeerState: Identifiable, Equatable {
    let id: String
    var risk = Risk.none
    var lastSeen = Date()
    var rssi: Double?
    var uwb: Reading?
    var ble: Reading?
    var gps: Reading?
    var peerFix: CLLocation?
    var calibrator = BLECalibrator()
    var estimate: Estimate?
    var pClose = 0.0

    /// Ignores lastSeen (not shown), so the UI republishes only when something visible changed.
    static func == (a: PeerState, b: PeerState) -> Bool {
        a.id == b.id && a.risk == b.risk && a.rssi == b.rssi && a.uwb == b.uwb && a.ble == b.ble
            && a.gps == b.gps && a.peerFix == b.peerFix && a.calibrator == b.calibrator
            && a.estimate == b.estimate && a.pClose == b.pClose
    }
}

/// Glues the three channels together. All callbacks arrive on the main queue.
final class ProximityModel: ObservableObject {
    @Published var myRisk = Risk.none { didSet { announce() } }
    @Published var speed = 1.0  // real time; demo/test launches pass -speed
    @Published var enabled: Set<Source> = Set(Source.allCases)
    @Published private(set) var peers: [PeerState] = []
    @Published private(set) var exposure = ExposureTracker()
    @Published private(set) var status: [String: String] = [:]
    @Published private(set) var myID = Data()
    /// When the user last chose their own status (nil = never). Persisted with the status.
    @Published private(set) var statusSetAt: Date?
    /// Non-nil while detection is paused: nothing is broadcast or scanned and exposure doesn't accrue.
    @Published private(set) var pauseState: PauseState?
    var isPaused: Bool { pauseState != nil }

    private let ble = BLEBeacon()
    private let link = PeerLink()
    private let uwb = UWBRanger()
    private let gps = GPSRanger()

    private var byID: [String: PeerState] = [:]
    private var linkIDs: [MCPeerID: String] = [:]
    private var myFix: CLLocation?
    /// This phone's latest own GPS fix, for on-phone use only (the walk-in warning). Not shared by this property.
    @Published private(set) var lastFix: CLLocation?
    private var lastTick = Date()
    private var lastRotation = Date()
    private var lastSummary = Date.distantPast
    private var lastFixSent = Date.distantPast
    private var timer: Timer?
    private var notifiedLevel = AlertLevel.none
    /// Local-only list of past exposure episodes (14 days), shown on Today.
    let exposureHistory = ExposureHistoryStore()

    /// Ephemeral IDs rotate like GAEN's rolling proximity IDs (shorter via -rotate for tests).
    private var rotationInterval: TimeInterval = 15 * 60

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true  // keep the screen on during the demo
        restoreSavedStatus()
        restorePause()
        applyLaunchArguments()  // first: link settings must be in place before the session exists
        rotateID()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        ble.onState = { [weak self] in self?.setStatus("BLE", $0) }
        ble.onSighting = { [weak self] id, risk, rssi in self?.bleSighting(id: id, risk: risk, rssi: rssi) }

        link.onConnected = { [weak self] peer in self?.linked(peer) }
        link.onDisconnected = { [weak self] peer in self?.unlinked(peer) }
        link.onMessage = { [weak self] peer, w in self?.received(w, from: peer) }
        status["Link"] = "searching"

        uwb.onState = { [weak self] in self?.setStatus("UWB", $0); self?.log("uwb \($0)") }
        uwb.onToken = { [weak self] peer, data in self?.link.send(Wire(kind: .uwbToken, token: data), to: [peer]) }
        uwb.onDistance = { [weak self] peer, d in self?.uwbDistance(peer: peer, d: d) }
        status["UWB"] = UWBRanger.isSupported ? "waiting for peer" : "not supported on this device"

        gps.onState = { [weak self] in self?.setStatus("GPS", $0) }
        gps.onFix = { [weak self] in self?.ownFix($0) }

        if isPaused {
            markSensorsPaused()  // launched while paused: the radios stay off until resume()
            log("paused")
        } else {
            ble.start()
            link.start()
            gps.start()
        }

        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.2  // lets iOS coalesce wakeups
        timer = t
    }

    /// @Published fires on every set, even an equal one; skip those.
    private func setStatus(_ k: String, _ v: String) {
        if status[k] != v { status[k] = v }
    }

    /// The user's own choice in the Me tab (not a launch argument): remembered across launches.
    func setMyStatus(_ r: Risk) {
        myRisk = r
        statusSetAt = Date()
        UserDefaults.standard.set(r.rawValue, forKey: "savedStatus")
        UserDefaults.standard.set(statusSetAt, forKey: "savedStatusAt")
    }

    private func restoreSavedStatus() {
        guard !(acceptsLaunchArguments && LaunchMode.isTestLaunch) else { return }
        let d = UserDefaults.standard
        if let r = Risk(rawValue: d.integer(forKey: "savedStatus")), let at = d.object(forKey: "savedStatusAt") as? Date {
            myRisk = r
            statusSetAt = at
        }
    }

    // MARK: Pause (privacy and battery)

    /// Turns every radio off. Idempotent: pausing while paused only changes how long the pause lasts.
    func pause(_ choice: PauseChoice = .untilResumed, now: Date = Date(), calendar: Calendar = .current) {
        let state = PauseSchedule.state(choice, from: now, calendar: calendar)
        let wasPaused = isPaused
        pauseState = state
        persistPause()
        guard !wasPaused else { return }
        ble.stop()
        link.stop()
        uwb.stopAll()
        gps.stop()
        byID.removeAll()
        linkIDs.removeAll()
        myFix = nil
        peers = []
        markSensorsPaused()
        log("paused")
    }

    /// Turns the radios back on with a fresh random ID, announcing the current status. Idempotent.
    func resume() {
        guard isPaused else { return }
        pauseState = nil
        persistPause()
        lastTick = Date()
        lastFixSent = .distantPast
        status["Link"] = "searching"
        status["UWB"] = UWBRanger.isSupported ? "waiting for peer" : "not supported on this device"
        ble.resume()
        link.resume()
        gps.resume()
        rotateID()  // new ID after the gap, and announce() sends the current status
        log("resumed")
    }

    private func markSensorsPaused() {
        for k in ["BLE", "Link", "UWB", "GPS"] { setStatus(k, "paused") }
    }

    private func persistPause() {
        guard !(acceptsLaunchArguments && LaunchMode.isTestLaunch) else { return }
        let d = UserDefaults.standard
        if let p = pauseState, let data = try? JSONEncoder().encode(p) { d.set(data, forKey: "pauseState") } else { d.removeObject(forKey: "pauseState") }
    }

    /// A pause survives relaunch, unless it has already run out.
    private func restorePause() {
        guard !(acceptsLaunchArguments && LaunchMode.isTestLaunch),
              let data = UserDefaults.standard.data(forKey: "pauseState"),
              let p = try? JSONDecoder().decode(PauseState.self, from: data) else { return }
        if PauseSchedule.shouldResume(p, now: Date()) {
            UserDefaults.standard.removeObject(forKey: "pauseState")
        } else {
            pauseState = p
        }
    }

    /// After "Delete my data": back to a fresh install's state (the caller has cleared the files and defaults).
    func forgetEverything() {
        if isPaused { resume() }
        myRisk = .none
        statusSetAt = nil
        resetExposure()
    }

    func resetExposure() {
        exposure.reset()
        notifiedLevel = .none
    }

    /// The harness (com.fluni.proxtest) obeys test launch arguments; the FlUni product sets this to
    /// false so a stray argument can never change what a student sees.
    var acceptsLaunchArguments = true

    /// GPS-to-GPS ranging needs each phone's fix on the other phone. The harness keeps it for testing;
    /// FlUni turns it off so "your precise location never leaves this phone" is literally true
    /// (indoors GPS was 7–10 m off at 0.5 m anyway, so detection loses next to nothing).
    var sharesLocationWithPeers = true

    /// Lets tests drive the phones from the Mac, e.g.
    ///   devicectl ... launch --console com.fluni.proxtest -risk contagious -speed 60 -sources UWB,BLE
    private func applyLaunchArguments() {
        guard acceptsLaunchArguments else {
            log("start risk=\(myRisk) speed=\(speed) product build: launch arguments ignored")
            return
        }
        let d = UserDefaults.standard
        if let r = d.string(forKey: "risk"), let risk = Risk.allCases.first(where: { "\($0)" == r }) { myRisk = risk }
        if d.double(forKey: "speed") > 0 { speed = d.double(forKey: "speed") }
        if let s = d.string(forKey: "sources") {
            enabled = Set(s.split(separator: ",").compactMap { Source(rawValue: $0.uppercased()) })
        }
        // Stress-test knobs: -encryption required|optional|none, -inviteTimeout 10, -rotate 20, -riskAfter 20:contagious
        let enc = d.string(forKey: "encryption") ?? "required"
        switch enc {
        case "optional": link.encryption = .optional
        case "none": link.encryption = .none
        default: link.encryption = .required
        }
        if d.double(forKey: "inviteTimeout") > 0 { link.inviteTimeout = d.double(forKey: "inviteTimeout") }
        if d.double(forKey: "rotate") > 0 { rotationInterval = d.double(forKey: "rotate") }
        if let ra = d.string(forKey: "riskAfter"), let colon = ra.firstIndex(of: ":"),
           let secs = Double(ra[..<colon]), let risk = Risk.allCases.first(where: { "\($0)" == ra[ra.index(after: colon)...] }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
                self?.myRisk = risk
                self?.log("risk set \(risk)")
            }
        }
        log("start risk=\(myRisk) speed=\(speed) sources=\(enabled.map(\.rawValue).sorted()) encryption=\(enc) invite=\(link.inviteTimeout) rotate=\(rotationInterval)")
    }

    /// One-line events on stdout, so a monitor on the Mac can follow both phones.
    private func log(_ s: String) {
        print("[fluni] \(s)")
        fflush(stdout)  // stdout is a pipe under devicectl --console, so it would otherwise buffer
    }

    // MARK: Identity and status broadcast

    private func rotateID() {
        var bytes = [UInt8](repeating: 0, count: 11)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        myID = Data(bytes)
        lastRotation = Date()
        log("rotate me=\(myID.hex.prefix(6))")
        announce()
    }

    private func announce() {
        guard myID.count == 11, !isPaused else { return }  // -risk is applied before the first ID exists
        ble.advertise(id: myID, risk: myRisk)
        link.send(Wire(kind: .hello, id: myID.hex, risk: myRisk))
    }

    // MARK: Channel inputs

    private func bleSighting(id: String, risk: Risk, rssi: Double) {
        guard !isPaused else { return }  // a callback that was already queued when we paused
        if let old = byID[id]?.risk, old != risk { log("peer \(id.prefix(6)) risk=\(risk) via=ble") }
        if byID[id] == nil { log("ble seen \(id.prefix(6)) risk=\(risk)") }
        update(id) { p in
            p.risk = risk
            p.rssi = rssi
            p.ble = p.calibrator.reading(rssi: rssi, at: Date())
        }
    }

    private func linked(_ peer: MCPeerID) {
        guard !isPaused else { return }
        setStatus("Link", "\(link.connectedPeers.count) connected")
        log("link connected \(peer.displayName)")
        link.send(Wire(kind: .hello, id: myID.hex, risk: myRisk), to: [peer])
        if sharesLocationWithPeers, let f = myFix { link.send(fixWire(f), to: [peer]) }
        uwb.start(for: peer)
    }

    private func unlinked(_ peer: MCPeerID) {
        setStatus("Link", link.connectedPeers.isEmpty ? "searching" : "\(link.connectedPeers.count) connected")
        log("link lost \(peer.displayName)")
        uwb.stop(for: peer)
        linkIDs[peer] = nil
    }

    private func received(_ w: Wire, from peer: MCPeerID) {
        guard !isPaused else { return }
        switch w.kind {
        case .hello:
            guard let id = w.id else { return }
            // The peer rotated its ID: carry its state over instead of counting it twice.
            if let old = linkIDs[peer], old != id, let p = byID.removeValue(forKey: old), byID[id] == nil {
                byID[id] = PeerState(id: id, rssi: p.rssi, peerFix: p.peerFix, calibrator: p.calibrator)
            }
            linkIDs[peer] = id
            if let old = byID[id]?.risk, old != (w.risk ?? .none) { log("peer \(id.prefix(6)) risk=\(w.risk ?? .none) via=link") }
            update(id) { p in p.risk = w.risk ?? .none }
        case .uwbToken:
            if let t = w.token { uwb.receive(tokenData: t, from: peer) }
        case .gps:
            guard sharesLocationWithPeers else { return }  // FlUni doesn't take others' locations either
            guard let id = linkIDs[peer], let lat = w.lat, let lon = w.lon, let acc = w.acc else { return }
            let fix = CLLocation(coordinate: .init(latitude: lat, longitude: lon), altitude: 0,
                                 horizontalAccuracy: acc, verticalAccuracy: -1, timestamp: Date())
            update(id) { p in p.peerFix = fix }
            refreshGPS(id)
        }
    }

    private func uwbDistance(peer: MCPeerID, d: Double) {
        guard !isPaused else { return }
        guard let id = linkIDs[peer] else { return }
        update(id) { p in
            p.uwb = Reading(source: .uwb, distance: d, sigma: 0.1, at: Date())
            // UWB is ground truth for this phone pair: teach the BLE model while we have it.
            if let rssi = p.rssi { p.calibrator.observe(rssi: rssi, trueDistance: d) }
        }
    }

    private func ownFix(_ fix: CLLocation) {
        guard !isPaused else { return }
        myFix = fix
        lastFix = fix
        if sharesLocationWithPeers { link.send(fixWire(fix)) }
        for id in byID.keys { refreshGPS(id) }
    }

    private func fixWire(_ f: CLLocation) -> Wire {
        Wire(kind: .gps, lat: f.coordinate.latitude, lon: f.coordinate.longitude, acc: f.horizontalAccuracy)
    }

    /// A still phone (distance filter on) stops getting new fixes, but its last one is still where it is,
    /// so a GPS reading is current as long as the peer keeps re-sending (every 10 s, see tick).
    private func refreshGPS(_ id: String) {
        guard let mine = myFix, let theirs = byID[id]?.peerFix,
              Date().timeIntervalSince(theirs.timestamp) < 30 else { return }  // peerFix timestamp = receipt time
        let r = gpsReading(myLat: mine.coordinate.latitude, myLon: mine.coordinate.longitude,
                           myAcc: mine.horizontalAccuracy,
                           peerLat: theirs.coordinate.latitude, peerLon: theirs.coordinate.longitude,
                           peerAcc: theirs.horizontalAccuracy,
                           at: Date())
        byID[id]?.gps = r
    }

    private func update(_ id: String, _ change: (inout PeerState) -> Void) {
        let isNew = byID[id] == nil
        var p = byID[id] ?? PeerState(id: id)
        change(&p)
        p.lastSeen = Date()
        byID[id] = p
        // First sighting: fuse now instead of waiting up to 1 s for the timer.
        if isNew { DispatchQueue.main.async { [weak self] in self?.tick() } }
    }

    // MARK: Fusion + exposure, once a second

    private func tick() {
        let now = Date()
        if let p = pauseState {
            lastTick = now  // so the first tick after resume doesn't count the paused time
            if PauseSchedule.shouldResume(p, now: now) { resume() }
            return
        }
        if now.timeIntervalSince(lastRotation) >= rotationInterval { rotateID() }
        let dt = min(now.timeIntervalSince(lastTick), 2)  // no jump after a pause
        lastTick = now

        byID = byID.filter { now.timeIntervalSince($0.value.lastSeen) < 30 }
        if sharesLocationWithPeers, let f = myFix, now.timeIntervalSince(lastFixSent) >= 10 {
            lastFixSent = now
            link.send(fixWire(f))
        }
        for id in byID.keys {
            refreshGPS(id)
            guard var p = byID[id] else { continue }
            let readings = [p.uwb, p.ble, p.gps].compactMap { $0 }.filter { enabled.contains($0.source) }
            p.estimate = Fusion.fuse(readings, now: now)
            p.pClose = p.estimate.map(Fusion.exposurePClose) ?? 0
            byID[id] = p
        }

        let before = exposure.level
        var e = exposure
        let ps = Array(byID.values)
        e.advance(simSeconds: dt * speed, contacts: ps.map { ($0.pClose, $0.risk) },
                  tiers: ps.map { $0.estimate.map(Fusion.tierWeight) ?? 0 })
        exposureHistory.record(simSeconds: dt * speed, contacts: ps.map { ($0.pClose, $0.risk) }, at: now)
        if e != exposure { exposure = e }  // unchanged ticks don't republish
        if exposure.level != before { log("ALERT \(exposure.level) minutes=\(fmt(exposure.minutes))") }
        if exposure.level > notifiedLevel {
            notifiedLevel = exposure.level
            notify(exposure.level)
        }
        if now.timeIntervalSince(lastSummary) >= 5 { lastSummary = now; logSummary() }

        // Ease GPS off while any enabled UWB reading was fresh in the last 15 s (hysteresis vs flapping).
        gps.setRelaxed(enabled.contains(.uwb) && byID.values.contains { $0.uwb.map { now.timeIntervalSince($0.at) < 15 } ?? false })

        let sorted = byID.values.sorted { $0.id < $1.id }
        if sorted != peers { peers = sorted }
    }

    private func logSummary() {
        let ps = byID.values.sorted { $0.id < $1.id }.map { p in
            let e = p.estimate.map { "d=\(fmt($0.distance))±\(fmt($0.sigma)) via=\($0.sources.map(\.rawValue).joined(separator: "+"))" } ?? "d=none"
            return "peer=\(p.id.prefix(6)) risk=\(p.risk) \(e) p=\(fmt(p.pClose))"
                + " uwb=\(p.uwb.map { fmt($0.distance) } ?? "-") rssi=\(p.rssi.map { fmt($0) } ?? "-")"
                + " ble=\(p.ble.map { fmt($0.distance) } ?? "-") gps=\(p.gps.map { fmt($0.distance) } ?? "-")"
                + " cal=\(p.calibrator.isCalibrated ? fmt(p.calibrator.txPower) : "no")"
        }
        log("tick me=\(myID.hex.prefix(6)) risk=\(myRisk) minutes=\(fmt(exposure.minutes)) level=\(exposure.level) "
            + (ps.isEmpty ? "peers=0" : ps.joined(separator: " | ")))
    }

    private func fmt(_ x: Double) -> String { String(format: "%.2f", x) }

    private func notify(_ level: AlertLevel) {
        UINotificationFeedbackGenerator().notificationOccurred(level == .closeContact ? .error : .warning)
        let c = UNMutableNotificationContent()
        c.title = Advice.title(level)
        c.body = Advice.body(level).joined(separator: " ")
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
