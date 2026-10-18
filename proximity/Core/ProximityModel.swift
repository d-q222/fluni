import CoreLocation
import Foundation
import MultipeerConnectivity
import UIKit
import UserNotifications

/// Everything known about one nearby Fluni phone, keyed by its ephemeral ID. This is what views (the
/// developer list) see, so it deliberately has no score and no days since onset: those stay private to
/// ProximityModel and feed only the estimate (product owner 2026-10-17: others use it, nobody sees it).
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
    @Published var myRisk = Risk.none {
        didSet {
            own.statusChanged(liveRisk: liveRisk, status: myRisk)
            if ownScore != own.current { ownScore = own.current }
            announce()
        }
    }
    @Published var speed = 1.0  // real time; demo/test launches pass -speed
    @Published var enabled: Set<Source> = Set(Source.allCases)
    @Published private(set) var peers: [PeerState] = []
    /// Not @Published: the tracker's clock moves on every 1 s tick, so publishing every change redrew every view
    /// that watches the model once a second with nobody around. `setExposure` announces only what a view can see.
    private(set) var exposure = ExposureTracker() {
        didSet { if liveRisk != exposure.probability { liveRisk = exposure.probability } }
    }
    /// This phone's risk estimate p (RiskEstimate, Rio's formula), recomputed on every 1 s tick while a
    /// risky peer's dose accrues, on return to the foreground, and when the 24 h dose window drops old dose.
    /// Bind the on-screen number to this.
    @Published private(set) var liveRisk = RiskEstimate.prior
    /// This user's own score: max(liveRisk, status floor), so someone who reported a positive test reads at
    /// least 97% (High) and someone with symptoms at least 60%, even with no exposure. Recomputed every tick
    /// and on a status change. The beacon broadcasts last tick's value (OwnScoreLag), for other phones' estimate.
    @Published private(set) var ownScore = RiskEstimate.prior
    /// True while the user's own report (symptoms or a positive test) sets their risk: the UI should show
    /// "you've reported being sick" rather than an exposure estimate.
    var selfStatusOverridesRisk: Bool { myRisk != .none }
    /// The user's day 0 (SelfReportRecord.dayZero), for the days-since-onset the beacon carries. Persisted.
    @Published private(set) var myDayZero: Date?
    /// Where this phone is, for the room-air term: FlUni sets it from building_rooms.csv. nil = default room.
    var roomContext: RoomContext?
    private var own = OwnScoreLag()
    /// Score and days from each peer's latest beacon. Private: used for the estimate only, never published.
    private var heard: [String: (score: Double?, days: Int?)] = [:]
    /// True while ContactGuard sees a burst of new risky IDs (likely spoofing); Bluetooth-only alerts are paused.
    @Published private(set) var unusualSignals = false
    private var contactGuard = ContactGuard()
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
    /// The ID each link peer claims in its hello. Used only while Bluetooth also hears that ID (`boundID`).
    private var linkIDs: [LinkPeer: String] = [:]
    /// When the link that carried this ID's UWB dropped, for the `link metric uwb_resume` line.
    private var uwbDropAt: [String: Date] = [:]
    /// Each linked ID's hello said whether that phone has UWB (nil: older build / not linked). Coverage metric only.
    private var uwbCapable: [String: Bool] = [:]
    /// UWB health (Debug screen and `uwb metric` log lines only, never shown to students).
    private var uwbCoverage = UWBCoverage()
    private var lastCoverageTick: Date?
    private var lastHealth = Date.distantPast
    private var lastCoverageLog = Date()
    /// When FlUni last came to the foreground, until the first UWB distance after it (resume metric).
    private var foregroundAt: Date?
    private var lastResume: TimeInterval?
    #if DEBUG
    /// Debug only: stops the screen sleeping while FlUni is on screen, because iOS ranges iPhone-to-iPhone UWB only
    /// in the foreground. Saved in UserDefaults (default off); `-FLUNIKeepAwake YES` at launch turns it on.
    @Published var keepAwake = UserDefaults.standard.bool(forKey: "FLUNIKeepAwake") {
        didSet { UserDefaults.standard.set(keepAwake, forKey: "FLUNIKeepAwake"); applyKeepAwake() }
    }
    private var lastSnapshot = Date.distantPast
    #endif
    private var myFix: CLLocation?
    /// This phone's latest own GPS fix, for on-phone use only (the walk-in warning). Not shared by this property.
    /// @Unobserved: WalkInMonitor subscribes to `$lastFix`; no view reads it, so a fix (~1 Hz) redraws nothing.
    @Unobserved private(set) var lastFix: CLLocation?
    private var lastTick = Date()
    private var lastRotation = Date()
    private var lastSummary = Date.distantPast
    private var lastRescan: Date?
    private var lastFixSent = Date.distantPast
    private var timer: Timer?
    /// flu-offdetect: which alert levels get a notification (crossings up, per-level cooldown), the same on a
    /// background wake-up as in the foreground.
    private(set) var alertGate = AlertGate()
    /// Posts alerts; the default keeps FlUni running until iOS has taken the request (UNPoster).
    var alertPoster: AlertPosting = UNPoster()
    /// Per-peer "credited up to" times: exposure accrues from sightings, so it keeps counting while iOS
    /// only wakes FlUni for Bluetooth events, and the timer and those wake-ups never count a second twice.
    private var accrual = SightingAccrual()
    private var started = false
    private var backgroundTickPending = false
    /// Local-only list of past exposure episodes (14 days), shown on Today.
    let exposureHistory = ExposureHistoryStore()
    /// flu-persist: the exposure and alert state on this phone, so a relaunch keeps the estimate.
    let riskStore: RiskStateStore

    /// flu-persist: starts from the saved state (moved on to now; nothing credited for the time FlUni wasn't
    /// running), so the first frame already shows the restored estimate.
    init(riskStore: RiskStateStore = RiskStateStore()) {
        self.riskStore = riskStore
        if let r = riskStore.load(now: Date()) {
            exposure = r.exposure
            alertGate = r.gate
            liveRisk = r.exposure.probability
            own = OwnScoreLag(liveRisk: liveRisk)
            ownScore = own.current
        }
    }

    /// Ephemeral IDs rotate like GAEN's rolling proximity IDs (shorter via -rotate for tests).
    private var rotationInterval: TimeInterval = 15 * 60

    /// Safe to call more than once (FlUni starts it on a background relaunch and again when a window appears).
    func start() {
        guard !started else { return }
        started = true
        if UIApplication.shared.applicationState == .background { log("bg launch") }
        if keepsScreenOn { UIApplication.shared.isIdleTimerDisabled = true }  // harness only
        restoreSavedStatus()
        restorePause()
        #if DEBUG
        if acceptsLaunchArguments && LaunchMode.isTestLaunch { DebugFileLog.shared.start { [weak self] in self?.log($0) } }  // flu-offdetect
        #endif
        applyLaunchArguments()  // first: link settings must be in place before the session exists
        rotateID()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        ble.onState = { [weak self] in self?.setStatus("BLE", $0) }
        ble.onSighting = { [weak self] hit, rssi, n in self?.bleSighting(hit, rssi: rssi, samples: n) }
        ble.onLog = { [weak self] in self?.log($0) }
        ble.onRead = { [weak self] in self?.rotateIfDue(Date()) }  // a read may be our only wake-up for a while
        ble.worksInBackground = worksInBackground

        link.onConnected = { [weak self] peer in self?.linked(peer) }
        link.onDisconnected = { [weak self] peer, final in self?.unlinked(peer, final: final) }
        link.onMessage = { [weak self] peer, w in self?.received(w, from: peer) }
        status["Link"] = "searching"

        uwb.onState = { [weak self] in self?.setStatus("UWB", $0); self?.log("uwb \($0)") }
        uwb.onToken = { [weak self] peer, data in self?.link.send(Wire(kind: .uwbToken, token: data), to: [peer]) }
        uwb.onDistance = { [weak self] peer, d in self?.uwbDistance(peer: peer, d: d) }
        uwb.onStopped = { [weak self] peer in self?.linkIDs[peer] = nil }
        uwb.setActive(UIApplication.shared.applicationState != .background)
        status["UWB"] = UWBRanger.isSupported ? "waiting for peer" : "not supported on this device"

        gps.onState = { [weak self] in self?.setStatus("GPS", $0) }
        gps.onFix = { [weak self] in self?.ownFix($0) }
        // flu-offdetect: with Always, coarse background location keeps FlUni running off screen (BackgroundLocation).
        gps.keepsAppAlive = worksInBackground
        gps.onMode = { [weak self] in self?.log("location mode \($0)") }

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
        // Back in the foreground: credit the gap now, so p shows what accrued in the background at once
        // rather than on the timer's next fire.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.cameForward(); self?.tick() }
        // iOS suspends iPhone-to-iPhone UWB in the background; the ranger makes no sessions there and re-makes
        // missing ones the moment FlUni is back (UWBRanger.setActive).
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.wentBack() }
        // flu-persist: iOS may end FlUni in the background and a swipe-away in the app switcher gives no
        // termination callback, so save on the way out (resign active, then background).
        #if DEBUG
        applyKeepAwake()
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.applyKeepAwake() }
        #endif
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.saveRiskState() }
        }
    }

    private func cameForward() {
        #if DEBUG
        applyKeepAwake()
        #endif
        uwb.setActive(true)
        if !isPaused, enabled.contains(.uwb), UWBRanger.isSupported { foregroundAt = Date() }
    }

    private func wentBack() {
        #if DEBUG
        applyKeepAwake()
        #endif
        uwb.setActive(false)
        foregroundAt = nil
        lastCoverageTick = nil
        logUWBHealth()
    }

    /// @Published fires on every set, even an equal one; skip those.
    private func setStatus(_ k: String, _ v: String) {
        if status[k] != v { status[k] = v }
    }

    /// The user's own choice in the Me tab (not a launch argument): remembered across launches.
    func setMyStatus(_ r: Risk, dayZero: Date? = nil) {
        myDayZero = r == .none ? nil : dayZero
        myRisk = r
        statusSetAt = Date()
        UserDefaults.standard.set(r.rawValue, forKey: "savedStatus")
        UserDefaults.standard.set(statusSetAt, forKey: "savedStatusAt")
        UserDefaults.standard.set(myDayZero, forKey: "savedDayZero")
    }

    /// The self-report's day 0 changed without a status change (e.g. a new onset date). Remembered.
    func setMyDayZero(_ d: Date?) {
        let v = myRisk == .none ? nil : d
        guard v != myDayZero else { return }
        myDayZero = v
        UserDefaults.standard.set(v, forKey: "savedDayZero")
        announce()
    }

    private func restoreSavedStatus() {
        guard !(acceptsLaunchArguments && LaunchMode.isTestLaunch) else { return }
        let d = UserDefaults.standard
        if let r = Risk(rawValue: d.integer(forKey: "savedStatus")), let at = d.object(forKey: "savedStatusAt") as? Date {
            myDayZero = d.object(forKey: "savedDayZero") as? Date
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
        heard.removeAll()
        accrual.reset()  // nothing is credited across a pause
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
        pause(.untilResumed)  // radios stay off until onboarding's "Turn on" calls resume()
        UserDefaults.standard.removeObject(forKey: "pauseState")  // a relaunch starts fresh, not paused
        myRisk = .none
        statusSetAt = nil
        myDayZero = nil
        UserDefaults.standard.removeObject(forKey: "savedDayZero")
        resetExposure()
        exposureHistory.reset()
        lastFix = nil
    }

    func resetExposure() {
        setExposure(ExposureTracker())
        accrual.reset()
        alertGate = AlertGate()
        riskStore.clear()  // flu-persist
    }

    /// flu-persist: writes the exposure and alert state now (going to the background).
    func saveRiskState() {
        riskStore.save(exposure, gate: alertGate, now: Date())
    }

    /// flu-persist: the user read the in-app alert for `level` (the tissue's "Got it"); saved at once, so it doesn't
    /// pop again after a relaunch within the level's cooldown.
    func markAlertRead(_ level: AlertLevel, now: Date = Date()) {
        alertGate.markRead(level, now: now)
        riskStore.save(exposure, gate: alertGate, now: now)
    }

    func isAlertRead(_ level: AlertLevel, now: Date = Date()) -> Bool { alertGate.isRead(level, now: now) }

    /// The harness (com.fluni.proxtest) obeys test launch arguments; the FlUni product sets this to
    /// false so a stray argument can never change what a student sees.
    var acceptsLaunchArguments = true

    /// GPS-to-GPS ranging needs each phone's fix on the other phone. The harness keeps it for testing;
    /// FlUni turns it off so "your precise location never leaves this phone" is literally true
    /// (indoors GPS was 7–10 m off at 0.5 m anyway, so detection loses next to nothing).
    /// Fails closed: false unless the harness opts in.
    var sharesLocationWithPeers = false {
        didSet { gps.rangesWithPeers = sharesLocationWithPeers }  // GPS may only relax while it ranges
    }
    /// Harness only: keep the screen on during link tests. FlUni lets the phone lock.
    var keepsScreenOn = false

    /// FlUni sets this before start(): Bluetooth keeps working in the background (fixed service UUID +
    /// GATT read, state restoration) and sightings drive exposure while the timer is asleep. The harness
    /// leaves it off (no Bluetooth background modes there).
    var worksInBackground = false

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
        #if DEBUG
        DebugFileLog.shared.append(s)  // flu-offdetect: test launches only (no-op otherwise)
        #endif
    }

    // MARK: Identity and status broadcast

    private func rotateIfDue(_ now: Date) {
        if !isPaused, now.timeIntervalSince(lastRotation) >= rotationInterval { rotateID() }
    }

    private func rotateID() {
        var bytes = [UInt8](repeating: 0, count: BLEBeacon.idBytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        myID = Data(bytes)
        lastRotation = Date()
        log("rotate me=\(myID.hex.prefix(6))")
        // New link identity too, so the link can't tie the old ID to the new one. The new ID is only ever
        // sent over links made under the new identity (announce() sends to those; there are none yet).
        link.rotateIdentity()
        announce()
    }

    private func announce() {
        guard myID.count == BLEBeacon.idBytes, !isPaused else { return }  // -risk is applied before the first ID exists
        advertise()
        link.send(hello())
    }

    /// The beacon: status, days since onset, last tick's own score, ID. A no-op when nothing changed.
    private func advertise() {
        guard myID.count == BLEBeacon.idBytes, !isPaused else { return }
        ble.advertise(id: myID, risk: myRisk, score: own.broadcast,
                      days: RiskEstimate.daysSinceOnset(dayZero: myDayZero, status: myRisk, now: Date()))
    }

    private func hello() -> Wire {
        Wire(kind: .hello, id: myID.hex, risk: myRisk, ext: UWBRanger.isSupported && UWBRanger.supportsExtendedDistance,
             uwb: UWBRanger.isSupported)
    }

    // MARK: Channel inputs

    /// `samples`: RSSI samples behind the median. Few samples (off screen: no adverts, a polled link every 2 s)
    /// widen the reading's error so pClose stays honest (OffScreenRSSI; flu-offdetect).
    private func bleSighting(_ hit: BLEBeacon.Hit, rssi: Double, samples: Int) {
        guard !isPaused else { return }  // a callback that was already queued when we paused
        let id = hit.id, risk = hit.risk
        // The latest beacon wins; a held link's poll (no payload) never erases what an advert said. Not logged or published.
        if hit.score != nil || hit.daysSinceOnset != nil || heard[id] == nil { heard[id] = (hit.score, hit.daysSinceOnset) }
        if let old = byID[id]?.risk, old != risk { log("peer \(id.prefix(6)) risk=\(risk) via=ble") }
        if byID[id] == nil { log("ble seen \(id.prefix(6)) risk=\(risk)") }
        update(id) { p in
            p.risk = risk
            p.rssi = rssi
            p.ble = OffScreenRSSI.widened(p.calibrator.reading(rssi: rssi, at: Date()), samples: samples)
        }
        if worksInBackground, UIApplication.shared.applicationState != .active { scheduleBackgroundTick() }
    }

    /// The 1 s timer doesn't run while iOS has FlUni in the background; a sighting wakes it briefly, so
    /// fuse and accrue shortly after (1 s lets a burst of sightings land in one tick).
    private func scheduleBackgroundTick() {
        guard !backgroundTickPending else { return }
        backgroundTickPending = true
        // flu-offdetect: hold the wake-up open until that tick (and any notification it posts) has run.
        let window = BackgroundWindow.begin("fluni.tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.backgroundTickPending = false
            self?.tick()
            window.end()
        }
    }

    private func linked(_ peer: LinkPeer) {
        guard !isPaused else { return }
        setStatus("Link", "\(link.connectedPeers.count) connected")
        log("link connected \(peer)")
        link.send(hello(), to: [peer])
        if sharesLocationWithPeers, let f = myFix { link.send(fixWire(f), to: [peer]) }
        uwb.linkUp(peer)  // reuses a session still ranging from before a drop, and re-sends our token
    }

    /// A drop keeps UWB ranging (and the claimed ID) for a grace period while the link reconnects;
    /// a retired identity's link is final, so its UWB stops now.
    private func unlinked(_ peer: LinkPeer, final: Bool) {
        setStatus("Link", link.connectedPeers.isEmpty ? "searching" : "\(link.connectedPeers.count) connected")
        if final {
            log("link retired \(peer)")
            uwb.stop(for: peer)
            linkIDs[peer] = nil
        } else {
            log("link lost \(peer)")
            if let id = linkIDs[peer] { uwbDropAt[id] = Date() }
            uwb.linkDown(peer)
        }
    }

    /// The ID a link peer claimed, if Bluetooth also heard that ID in the last 30 s. The link is
    /// unauthenticated; a claim nobody hears on Bluetooth gets no UWB or GPS readings and creates no peer.
    private func boundID(_ peer: LinkPeer) -> String? {
        guard let id = linkIDs[peer], LinkGuard.isHeardOnBluetooth(lastHeard: byID[id]?.ble?.at, now: Date()) else { return nil }
        return id
    }

    private func received(_ w: Wire, from peer: LinkPeer) {
        guard !isPaused else { return }
        switch w.kind {
        case .hello:
            // PeerLink has validated it (20 or 22 lowercase hex ID). No state is carried from the peer's previous
            // ID (that would link its rotating IDs), and the link's risk is never used: Bluetooth's risk for
            // the same ID always stands, so a link can neither raise nor hide anyone's status.
            guard let id = w.id else { return }
            linkIDs[peer] = id
            if let c = w.uwb { uwbCapable[id] = c }
            uwb.setHeard(boundID(peer) != nil, for: peer)  // UWB only with a phone Bluetooth hears (see UWBRanger)
            let ext = LinkGuard.useExtendedDistance(mine: UWBRanger.supportsExtendedDistance, theirs: w.ext)
            uwb.setExtended(ext, for: peer)
            log("link hello \(id.prefix(6)) from \(peer) heard=\(boundID(peer) != nil ? "yes" : "no") ext=\(ext ? "yes" : "no")")
        case .uwbToken:
            if let t = w.token { uwb.receive(tokenData: t, from: peer) }
        case .gps:
            guard sharesLocationWithPeers else { return }  // FlUni doesn't take others' locations either
            guard let id = boundID(peer), let lat = w.lat, let lon = w.lon, let acc = w.acc else { return }
            let fix = CLLocation(coordinate: .init(latitude: lat, longitude: lon), altitude: 0,
                                 horizontalAccuracy: acc, verticalAccuracy: -1, timestamp: Date())
            update(id) { p in p.peerFix = fix }
            refreshGPS(id)
        }
    }

    private func uwbDistance(peer: LinkPeer, d: Double) {
        guard !isPaused else { return }
        guard let id = boundID(peer) else { return }
        let now = Date()
        // Metric for tools/stress.py: how long UWB was missing (gap) and, after a link drop, how long
        // until it was back (after_drop; ~0 when ranging carried on through the drop).
        let gap = byID[id]?.uwb.map { now.timeIntervalSince($0.at) }
        let drop = uwbDropAt.removeValue(forKey: id).map { now.timeIntervalSince($0) }.flatMap { $0 < 120 ? $0 : nil }
        if drop != nil || (gap ?? 0) > 1 {
            log("link metric uwb_resume gap=\(gap.map(fmt) ?? "-") after_drop=\(drop.map(fmt) ?? "-") peer=\(id.prefix(6))")
        }
        if let f = foregroundAt {
            foregroundAt = nil
            let t = now.timeIntervalSince(f)
            if t < 120 { lastResume = t; log("uwb metric resume_after_foreground=\(fmt(t))") }
        }
        var newlyCalibrated: Double?
        update(id) { p in
            p.uwb = Reading(source: .uwb, distance: d, sigma: 0.1, at: now)
            // UWB is ground truth for this phone pair: teach the BLE model while we have it.
            if let rssi = p.rssi {
                let was = p.calibrator.isCalibrated
                p.calibrator.observe(rssi: rssi, trueDistance: d)
                if !was && p.calibrator.isCalibrated { newlyCalibrated = p.calibrator.txPower }
            }
        }
        // ...and remember it for every future peer, so Bluetooth-only ranging starts calibrated.
        if let tx = newlyCalibrated {
            txPrior.learn(tx)
            if let data = try? JSONEncoder().encode(txPrior) { UserDefaults.standard.set(data, forKey: Self.txPriorKey) }
            log("ble prior txPower=\(fmt(txPrior.txPower)) pairs=\(txPrior.pairs)")
        }
    }

    private static let txPriorKey = "ble.txPowerPrior"
    private lazy var txPrior: TxPowerPrior = UserDefaults.standard.data(forKey: Self.txPriorKey)
        .flatMap { try? JSONDecoder().decode(TxPowerPrior.self, from: $0) } ?? TxPowerPrior()

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
        var p = byID[id] ?? PeerState(id: id, calibrator: .fromPrior(txPrior))
        change(&p)
        p.lastSeen = Date()
        byID[id] = p
        // First sighting: fuse now instead of waiting up to 1 s for the timer.
        if isNew { DispatchQueue.main.async { [weak self] in self?.tick() } }
    }

    // MARK: Fusion + exposure, once a second (and after background sightings)

    private func tick() {
        #if DEBUG
        if demoTimer != nil { return }  // -demoPeer: the pretend peer is the only exposure source
        #endif
        let signpost = Signposts.poi.beginInterval("tick")
        defer { Signposts.poi.endInterval("tick", signpost) }
        let now = Date()
        if let p = pauseState {
            lastTick = now  // so the first tick after resume doesn't count the paused time
            if PauseSchedule.shouldResume(p, now: now) { resume() }
            return
        }
        rotateIfDue(now)
        // Wall time since the last accrual. It moves the exposure clock (so the 24 h window is real time,
        // background included); capping at the window is enough to expire everything older.
        let wall = now.timeIntervalSince(lastTick)
        let accrues = wall >= SightingAccrual.minStep
        if accrues || wall < 0 { lastTick = now }  // a backwards clock re-anchors without crediting
        let dt = min(max(wall, 0), ExposureTracker.window / speed)

        byID = byID.filter { now.timeIntervalSince($0.value.lastSeen) < 30 }
        heard = heard.filter { byID[$0.key] != nil }
        uwbCapable = uwbCapable.filter { byID[$0.key] != nil || linkIDs.values.contains($0.key) }
        // A linked peer becomes UWB-eligible once Bluetooth hears its hello ID (and stays so while heard).
        for peer in linkIDs.keys { uwb.setHeard(boundID(peer) != nil, for: peer) }
        trackUWBCoverage(now)
        #if DEBUG
        writeHealthSnapshot(now)
        #endif
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
        // Spoof guard first, over every peer (it needs to see bursts); then background-safe accrual credits
        // only peers with a fresh estimate, each for [lastCreditedAt, now].
        let inputs = byID.values.map { p -> ContactGuard.Input in
            var i = p.guardInput
            i.score = heard[p.id]?.score
            i.days = heard[p.id]?.days
            return i
        }
        let guarded = contactGuard.apply(now: now, inputs, log: log)
        if unusualSignals != contactGuard.flagged { unusualSignals = contactGuard.flagged }
        let fresh = Set(byID.values.filter { $0.estimate != nil }.map(\.id))
        let fed = ExposureTick.run(guarded: guarded, fresh: fresh, now: now, wall: dt, speed: speed, accrues: accrues,
                                   accrual: &accrual, exposure: &e, room: currentRoom(now)) { c in
            if c.risk != .none, c.pClose > 0,
               c.seconds >= 5 || UIApplication.shared.applicationState != .active {
                log("bg credit peer=\(c.id.prefix(6)) secs=\(fmt(c.seconds)) p=\(fmt(c.pClose)) risk=\(c.risk)")
            }
        }
        if let fed { exposureHistory.record(simSeconds: dt * speed, contacts: fed, at: now) }
        setExposure(e)  // unchanged ticks don't republish; any change in p does
        tickOwnScore()
        if exposure.level != before { log("ALERT \(exposure.level) minutes=\(fmt(exposure.minutes))") }
        let kind = alertGate.step(exposure.level, now: now)
        if let kind {
            log("notify \(kind.rawValue) state=\(UIApplication.shared.applicationState == .active ? "active" : "background")")
            if UIApplication.shared.applicationState == .active {
                UINotificationFeedbackGenerator().notificationOccurred(kind == .closeContact ? .error : .warning)
            }
            alertPoster.post(kind)
        }
        // flu-persist: a level change or a notification is written at once (a swipe-away gives no callback).
        riskStore.saveIfDue(exposure, gate: alertGate, now: now, levelChanged: exposure.level != before || kind != nil)
        if now.timeIntervalSince(lastSummary) >= 5 { lastSummary = now; logSummary() }
        // flu-offdetect: kept alive off screen, so restart Bluetooth scanning now and then (iOS reports each phone
        // once per background scan; a restart lets phones that came near be found again).
        if BackgroundLocation.shouldRescan(gps.mode, last: lastRescan, now: now) {
            lastRescan = now
            ble.refreshScan()
        }

        // Ease GPS off while any enabled UWB reading was fresh in the last 15 s (hysteresis vs flapping).
        gps.setRelaxed(enabled.contains(.uwb) && byID.values.contains { $0.uwb.map { now.timeIntervalSince($0.at) < 15 } ?? false })

        let sorted = byID.values.sorted { $0.id < $1.id }
        if sorted != peers { peers = sorted }
    }

    /// Stores the tracker; tells observers only when something they can show changed (any change in p does).
    private func setExposure(_ e: ExposureTracker) {
        guard e != exposure else { return }
        if !e.showsSame(as: exposure) { objectWillChange.send() }
        exposure = e
    }

    /// Own score for this tick (see OwnScoreLag), then the beacon with last tick's value.
    private func tickOwnScore() {
        own.tick(liveRisk: liveRisk, status: myRisk)
        if ownScore != own.current { ownScore = own.current }
        advertise()
    }

    /// The room this phone is in now, from its own latest fix (on the phone only).
    private func currentRoom(_ now: Date) -> RiskEstimate.Room {
        guard let ctx = roomContext, let f = lastFix else { return .standard }
        return ctx.room(lat: f.coordinate.latitude, lon: f.coordinate.longitude, accuracy: f.horizontalAccuracy,
                        fixAt: f.timestamp, now: now)
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

    /// UWB coverage over foreground peer-seconds (UWBCoverage), shown as "UWB health" in Developer > Radios and
    /// logged as `uwb metric` every minute and on each trip to the background.
    private func trackUWBCoverage(_ now: Date) {
        let counting = UWBRanger.isSupported && enabled.contains(.uwb) && UIApplication.shared.applicationState == .active
        defer { lastCoverageTick = counting ? now : nil }
        guard counting else { return }
        if let last = lastCoverageTick {
            var e = 0, c = 0
            let linked = Set(linkIDs.values)  // a Bluetooth-only device or a stale rotated ID has no UWB link
            for p in byID.values {
                let k = UWBCoverage.classify(bleAge: p.ble.map { now.timeIntervalSince($0.at) },
                                             uwbAge: p.uwb.map { now.timeIntervalSince($0.at) },
                                             capable: linked.contains(p.id) ? uwbCapable[p.id] : false)  // only link peers can range
                if k.eligible { e += 1 }
                if k.covered { c += 1 }
            }
            uwbCoverage.add(dt: now.timeIntervalSince(last), eligiblePeers: e, coveredPeers: c)
        }
        if now.timeIntervalSince(lastHealth) >= 5 {
            lastHealth = now
            setStatus("UWB health", uwbHealth)
        }
        if now.timeIntervalSince(lastCoverageLog) >= 60 { logUWBHealth() }
    }

    private var uwbHealth: String {
        let cov = uwbCoverage.percent.map { String(format: "%.0f%% of %.0f peer-s", $0, uwbCoverage.eligible) } ?? "no UWB peer yet"
        return "coverage \(cov); resume \(lastResume.map { String(format: "%.1f s", $0) } ?? "-"); \(uwb.summary)"
            + (ProcessInfo.processInfo.isLowPowerModeEnabled ? "; Low Power Mode" : "")
    }

    private func logUWBHealth() {
        lastCoverageLog = Date()
        let bad = uwb.failures.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue):\($0.value)" }.joined(separator: ",")
        log("uwb metric coverage=\(uwbCoverage.percent.map { String(format: "%.1f", $0) } ?? "-") eligible_s=\(String(format: "%.0f", uwbCoverage.eligible))"
            + " covered_s=\(String(format: "%.0f", uwbCoverage.covered)) sessions=\(uwb.sessionsCreated) timeouts=\(uwb.timeouts)"
            + " suspended=\(uwb.suspensions) invalid=\(bad.isEmpty ? "-" : bad) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled ? "yes" : "no")")
    }

    #if DEBUG
    private func applyKeepAwake() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake && UIApplication.shared.applicationState == .active
    }

    /// Debug only: every 30 s writes UWB health to Library/Caches/fluni-uwb-health.json so a soak can be read off a
    /// phone without a UI test runner:
    ///   devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier com.fluni.app \
    ///     --source Library/Caches/fluni-uwb-health.json --destination <file>
    private func writeHealthSnapshot(_ now: Date) {
        guard now.timeIntervalSince(lastSnapshot) >= 30 else { return }
        lastSnapshot = now
        let peerRows: [[String: Any]] = byID.values.sorted { $0.id < $1.id }.map { p in
            var r: [String: Any] = ["id": String(p.id.prefix(6))]
            if let u = p.uwb { r["uwb_m"] = u.distance; r["uwb_age_s"] = now.timeIntervalSince(u.at) }
            if let b = p.ble { r["ble_m"] = b.distance; r["ble_age_s"] = now.timeIntervalSince(b.at) }
            return r
        }
        let last = byID.values.compactMap { $0.uwb }.max { $0.at < $1.at }
        var j: [String: Any] = [
            "written_at": now.timeIntervalSince1970,
            "foreground": UIApplication.shared.applicationState == .active,
            "keep_awake": keepAwake,
            "eligible_s": uwbCoverage.eligible,
            "ranging_s": uwbCoverage.covered,
            "errors_by_reason": Dictionary(uniqueKeysWithValues: uwb.failures.map { ($0.key.rawValue, $0.value) }),
            "sessions_created": uwb.sessionsCreated, "timeouts": uwb.timeouts, "suspensions": uwb.suspensions,
            "peers": peerRows,
        ]
        if let c = uwbCoverage.percent { j["coverage_percent"] = c }
        if let r = lastResume { j["resume_s"] = r }
        if let l = last { j["last_distance_m"] = l.distance }
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: j, options: [.sortedKeys]) else { return }
        try? data.write(to: dir.appendingPathComponent("fluni-uwb-health.json"), options: .atomic)
    }

    private var demoTimer: Timer?
    private var demoAccrual = SightingAccrual()

    /// Debug only: `-demoPeer contagious@0.5` (or `possible@2`, distance in metres) puts a pretend peer
    /// beside this phone, credited every second through the same `ExposureTick` as tick() but with no
    /// radios, so the simulator and UI tests can watch the live estimate climb. Honours `-speed`. While it
    /// runs, tick() does nothing (one exposure clock). Safe to call more than once.
    func startDemoPeerFromLaunchArguments() {
        let d = UserDefaults.standard
        guard demoTimer == nil, let spec = d.string(forKey: "demoPeer") else { return }
        let parts = spec.split(separator: "@")
        guard parts.count == 2, let risk = Risk.allCases.first(where: { "\($0)" == parts[0] }),
              let metres = Double(parts[1]), metres.isFinite, metres >= 0 else {
            log("demoPeer ignored: \(spec)")
            return
        }
        if d.double(forKey: "speed") > 0 { speed = d.double(forKey: "speed") }
        let est = Estimate(distance: metres, sigma: 0.1, sources: [.uwb])
        let peer = ContactGuard.Output(id: "demo-peer", risk: risk, pClose: Fusion.exposurePClose(est),
                                       distance: Fusion.doseDistance(est), corroborated: true)
        log("demoPeer risk=\(risk) distance=\(metres) speed=\(speed)")
        var last = Date()
        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, !self.isPaused else { return }
            let signpost = Signposts.poi.beginInterval("tick")
            defer { Signposts.poi.endInterval("tick", signpost) }
            let now = Date()
            let wall = min(max(now.timeIntervalSince(last), 0), ExposureTracker.window / self.speed)
            last = now
            var e = self.exposure
            let before = e.level
            let fed = ExposureTick.run(guarded: [peer], fresh: [peer.id], now: now, wall: wall, speed: self.speed,
                                       accrues: true, accrual: &self.demoAccrual, exposure: &e, room: self.currentRoom(now))
            if let fed { self.exposureHistory.record(simSeconds: wall * self.speed, contacts: fed, at: now) }  // Today's timeline
            self.setExposure(e)
            self.tickOwnScore()
            self.riskStore.saveIfDue(e, gate: self.alertGate, now: now, levelChanged: e.level != before)  // flu-persist
        }
        demoTimer = t
    }
    #endif

}

/// Posts through UNUserNotificationCenter (text from NotificationRoute via AppNotifications, which respects the
/// lock-screen details setting). A background task keeps FlUni running until iOS has accepted the request, so a
/// wake-up that crosses a threshold can't be suspended halfway through posting it (flu-offdetect).
final class UNPoster: AlertPosting {
    func post(_ kind: NotificationKind) {
        let window = BackgroundWindow.begin("fluni.alert")
        let c = AppNotifications.content(kind: kind)  // category + userInfo + neutral text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { _ in
            window.end()
        }
    }
}
