import Foundation
import NearbyInteraction

/// What a ranging session reports. NISession's delegate callbacks, as plain values so the state machine
/// below can be unit-tested with a fake session (NISession can't range in a simulator or a test).
enum UWBEvent: Equatable {
    case distance(Double)
    case removed(peerEnded: Bool)   // false = timeout (out of range, blocked)
    case suspended
    case suspensionEnded
    case invalidated(UWBFailure)
}

/// Why a session was invalidated: NIError.Code by name, so logs and the Debug screen can count them.
enum UWBFailure: String, CaseIterable {
    case invalidConfiguration, userDidNotAllow, activeSessionsLimitExceeded, resourceUsageTimeout, sessionFailed,
         incompatiblePeerDevice, extendedSessionsLimitExceeded, unsupportedPlatform, badPeerToken, other

    init(_ error: Error) {
        guard let e = error as? NIError else { self = .other; return }
        switch e.code {
        case .invalidConfiguration: self = .invalidConfiguration
        case .userDidNotAllow: self = .userDidNotAllow
        case .activeSessionsLimitExceeded: self = .activeSessionsLimitExceeded
        case .resourceUsageTimeout: self = .resourceUsageTimeout
        case .sessionFailed: self = .sessionFailed
        case .unsupportedPlatform: self = .unsupportedPlatform
        default:
            if #available(iOS 17.0, *) {
                if e.code == .incompatiblePeerDevice { self = .incompatiblePeerDevice; return }
                if e.code == .activeExtendedDistanceSessionsLimitExceeded { self = .extendedSessionsLimitExceeded; return }
            }
            self = .other
        }
    }

    /// Failures that mean "this pair can't do extended distance": retry the pair without it.
    var blamesExtended: Bool {
        self == .invalidConfiguration || self == .incompatiblePeerDevice || self == .extendedSessionsLimitExceeded
    }
}

/// One ranging session with one peer. `NIRangingSession` in the app, a fake in tests.
protocol UWBSession: AnyObject {
    var onEvent: ((UWBEvent) -> Void)? { get set }
    /// Our archived discovery token for this session (sent to the peer over the link).
    var tokenData: Data? { get }
    /// Runs against the peer's archived token. false = the token can't be decoded.
    func run(peerToken: Data, extended: Bool) -> Bool
    func invalidate()
}

/// The real thing: one NISession. Never reads the peer token's `deviceCapabilities` (it is nil on a token
/// unarchived from a peer and Swift imports it as non-optional, so reading it crashes: SIGSEGV of 2026-10-17).
final class NIRangingSession: NSObject, UWBSession, NISessionDelegate {
    private let session = NISession()
    var onEvent: ((UWBEvent) -> Void)?

    override init() {
        super.init()
        session.delegate = self  // delegate queue: main (the default)
    }

    var tokenData: Data? {
        session.discoveryToken.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
    }

    func run(peerToken: Data, extended: Bool) -> Bool {
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: peerToken) else { return false }
        let config = NINearbyPeerConfiguration(peerToken: token)
        if extended { config.isExtendedDistanceMeasurementEnabled = true }
        // Camera assistance stays off (the default): distance is all FlUni needs and it would need the camera.
        session.run(config)
        return true
    }

    func invalidate() { session.invalidate() }

    func session(_ s: NISession, didUpdate objects: [NINearbyObject]) {
        // distance is nil while the peer is out of range or the measurement isn't ready.
        if let d = objects.first?.distance { onEvent?(.distance(Double(d))) }
    }
    func session(_ s: NISession, didRemove objects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        onEvent?(.removed(peerEnded: reason == .peerEnded))
    }
    func sessionWasSuspended(_ s: NISession) { onEvent?(.suspended) }
    func sessionSuspensionEnded(_ s: NISession) { onEvent?(.suspensionEnded) }
    func session(_ s: NISession, didInvalidateWith error: Error) { onEvent?(.invalidated(UWBFailure(error))) }
}

/// Ultra-wideband ranging, one session per linked peer. Each side sends its discovery token over the
/// peer link; once both have the other's token the chips range directly (UWB + Bluetooth, not the link).
///
/// Goal: whenever a linked FlUni phone is near (heard on Bluetooth) and FlUni is in the foreground, a
/// session is up, and it comes back by itself after any failure. Rules:
/// - **Only for peers heard on Bluetooth** (`setHeard`). Every NIERROR_INVALID_CONFIGURATION_DESCRIPTION in the
///   2026-10-17/18 logs (~180) came from a link peer whose hello ID Bluetooth never heard: the other FlUni app on
///   the same phone (FlUni and the harness share the MPC service) or FlUni in a simulator over the Mac's
///   network. Their tokens can never range. Real phone pairs (including U2 pairs with extended distance)
///   ranged fine.
/// - **Never gives up while the peer is linked and heard.** Invalidation → a fresh session (new token,
///   re-sent) after a backoff of 0.5, 1, 2 … 30 s; a distance resets it. Only the user's "Don't Allow" stops
///   retries, until FlUni is next foregrounded (they may have changed it in Settings).
/// - **Foreground only.** iOS suspends iPhone-to-iPhone sessions in the background. No sessions are created
///   in the background; `setActive(true)` re-creates any that are missing at once (backoff reset).
/// - Suspension: Apple's docs say a suspended session resumes only when `run` is called again after
///   `sessionSuspensionEnded`, so that re-runs and re-sends our token.
/// - The link is only needed to swap tokens. A link drop keeps the session for `linkGrace` while the link
///   reconnects; reconnecting re-sends our token at once in case the peer restarted meanwhile.
/// - `.timeout` removal (out of range, blocked): re-run the same configuration. `.peerEnded`: the peer's
///   token is dead; re-send ours and wait for its new one.
/// - Extended distance (iOS 17, U2 chip) only when both hellos say so, and never again for a pair after NI
///   rejected it once.
/// - ID rotation: a new link identity is a new `LinkPeer`, so it gets a new session and a fresh token
///   exchange; the old one ranges until its link retires (make-before-break). Tokens are never reused.
final class UWBRanger {
    static var isSupported: Bool { NISession.deviceCapabilities.supportsPreciseDistanceMeasurement }
    static var supportsExtendedDistance: Bool { NISession.deviceCapabilities.supportsExtendedDistanceMeasurement }

    /// Keep a session this long after its link drops, waiting for the link (and tokens) to come back.
    static let linkGrace: TimeInterval = 30
    static let maxBackoff: TimeInterval = 30

    /// Archived token to send to this peer.
    var onToken: ((LinkPeer, Data) -> Void)?
    var onDistance: ((LinkPeer, Double) -> Void)?
    var onState: ((String) -> Void)?
    /// The peer's session is gone for good (link grace ran out, or stop()).
    var onStopped: ((LinkPeer) -> Void)?

    /// Health counters for the Debug screen and `uwb metric` log lines.
    private(set) var failures: [UWBFailure: Int] = [:]
    private(set) var suspensions = 0
    private(set) var timeouts = 0
    private(set) var sessionsCreated = 0

    private struct Peer {
        var session: UWBSession?
        var myTokenData: Data?
        var theirTokenData: Data?
        var ranToken: Data?           // the peer token the current session last ran with
        var linkUp = true
        var downSince: Date?
        var heard = false             // the hello's ID was heard on Bluetooth recently
        var extended = false          // both hellos said the phones support extended distance
        var extendedRejected = false  // NI rejected an extended configuration with this peer: plain from now on
        var ranExtended = false       // the last run asked for extended distance
        var failures = 0              // consecutive invalidations without a distance in between
        var retryPending = false
        var suspended = false
    }

    private let supported: Bool
    private let extendedCapable: Bool
    private let makeSession: () -> UWBSession
    private let after: (TimeInterval, @escaping () -> Void) -> Void
    private let now: () -> Date

    private var peers: [LinkPeer: Peer] = [:]
    private(set) var isActive = true   // app in the foreground
    private var denied = false         // the user declined Nearby Interaction

    init(supported: Bool = UWBRanger.isSupported, extendedCapable: Bool = UWBRanger.supportsExtendedDistance,
         makeSession: @escaping () -> UWBSession = { NIRangingSession() },
         after: @escaping (TimeInterval, @escaping () -> Void) -> Void = { d, f in DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: f) },
         now: @escaping () -> Date = Date.init) {
        self.supported = supported
        self.extendedCapable = extendedCapable
        self.makeSession = makeSession
        self.after = after
        self.now = now
    }

    /// Whether to ask NI for extended distance. After one rejection the pair ranges without it. (The peer
    /// token's `deviceCapabilities` can't be used to check first: reading it crashes, see NIRangingSession.)
    static func wantsExtended(helloSaysBoth: Bool, mine: Bool, rejected: Bool) -> Bool {
        helloSaysBoth && mine && !rejected
    }

    /// Delay before re-creating a session after `n` consecutive failures: 0.5, 1, 2 … 30 s. A session
    /// limit waits at least 5 s (another session has to end first).
    static func backoff(failures n: Int, _ f: UWBFailure) -> TimeInterval {
        let b = min(maxBackoff, 0.5 * pow(2, Double(max(0, n - 1))))
        return f == .activeSessionsLimitExceeded ? max(5, b) : b
    }

    /// The link to this peer is up (new or reconnected).
    func linkUp(_ p: LinkPeer) {
        guard supported else { onState?("not supported on this device"); return }
        peers[p, default: Peer()].linkUp = true
        peers[p]?.downSince = nil
        if let mine = peers[p]?.myTokenData, peers[p]?.session != nil {
            onToken?(p, mine)  // proactively: the peer may have lost it
        } else {
            ensure(p)
        }
    }

    /// The link dropped. Ranging continues; the session ends only if the link isn't back in `linkGrace`.
    func linkDown(_ p: LinkPeer) {
        guard peers[p] != nil else { return }
        let at = now()
        peers[p]?.linkUp = false
        peers[p]?.downSince = at
        after(Self.linkGrace) { [weak self] in
            guard let self, let st = self.peers[p], !st.linkUp, st.downSince == at else { return }
            self.onState?("link gone, stopping")
            self.stop(for: p)
        }
    }

    /// Whether Bluetooth heard this peer's hello ID recently. Sessions are only created for heard peers;
    /// a peer that is linked but never heard (same phone, simulator) would only fail with an invalid token.
    func setHeard(_ heard: Bool, for p: LinkPeer) {
        guard peers[p] != nil, peers[p]?.heard != heard else { return }
        peers[p]?.heard = heard
        if heard { ensure(p) }
    }

    /// Whether to use extended distance with this peer (from the hello). Re-runs if it changed.
    func setExtended(_ on: Bool, for p: LinkPeer) {
        guard var st = peers[p], st.extended != on else { return }
        st.extended = on
        peers[p] = st
        if st.session != nil, st.theirTokenData != nil { run(p) }
    }

    /// The app came to the foreground (true) or left it. Back in the foreground every missing session is
    /// re-created at once, with the backoff reset, and a past "Don't Allow" is tried once more.
    func setActive(_ on: Bool) {
        guard isActive != on else { return }
        isActive = on
        guard on else { return }
        denied = false
        for p in peers.keys {
            peers[p]?.failures = 0
            peers[p]?.retryPending = false
            ensure(p)
        }
    }

    func receive(tokenData: Data, from p: LinkPeer) {
        guard tokenData.count <= LinkGuard.maxTokenBytes else { return }
        // Kept even before our session exists (the token can arrive before our own hello/heard checks).
        var st = peers[p, default: Peer()]
        let isNew = st.theirTokenData != tokenData
        st.theirTokenData = tokenData
        peers[p] = st
        guard st.session != nil else { ensure(p); return }
        if isNew || st.ranToken == nil { run(p) }
        // The peer has a new token, so it restarted and may have forgotten ours: send it again.
        // Terminates because an unchanged token does not trigger a reply.
        if isNew, let mine = st.myTokenData { onToken?(p, mine) }
    }

    func stop(for p: LinkPeer) {
        guard let st = peers.removeValue(forKey: p) else { return }
        st.session?.invalidate()
        onStopped?(p)
    }

    /// Ends every session and forgets every token. Safe to call twice. No onStopped callbacks.
    func stopAll() {
        let old = peers
        peers.removeAll()  // first, so late callbacks find no peer and do nothing
        old.values.forEach { $0.session?.invalidate() }
    }

    /// Short state for the Debug screen: sessions, waiting peers, counters.
    var summary: String {
        let up = peers.values.filter { $0.session != nil }.count
        let bad = failures.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)×\($0.value)" }
        return "sessions \(up)/\(peers.count), made \(sessionsCreated), timeouts \(timeouts), suspended \(suspensions)"
            + (bad.isEmpty ? "" : ", invalidated: " + bad.joined(separator: " "))
            + (denied ? ", NOT ALLOWED in Settings" : "")
    }

    // MARK: State machine

    /// Creates the session if everything allows one now.
    private func ensure(_ p: LinkPeer) {
        guard supported, isActive, !denied, let st = peers[p], st.session == nil, st.linkUp, st.heard,
              !st.retryPending else { return }
        let s = makeSession()
        s.onEvent = { [weak self, weak s] e in
            guard let self, let s else { return }
            self.handle(e, from: s)
        }
        sessionsCreated += 1
        peers[p]?.session = s
        peers[p]?.ranToken = nil
        peers[p]?.suspended = false
        guard let data = s.tokenData else { return }
        peers[p]?.myTokenData = data
        onToken?(p, data)
        if peers[p]?.theirTokenData != nil { run(p) }
    }

    private func run(_ p: LinkPeer) {
        guard let st = peers[p], let s = st.session, let theirs = st.theirTokenData else { return }
        let ext = Self.wantsExtended(helloSaysBoth: st.extended, mine: extendedCapable, rejected: st.extendedRejected)
        peers[p]?.ranExtended = ext
        peers[p]?.ranToken = theirs
        guard s.run(peerToken: theirs, extended: ext) else {
            // Not a token at all: forget it and wait for a good one.
            peers[p]?.theirTokenData = nil
            peers[p]?.ranToken = nil
            failures[.badPeerToken, default: 0] += 1
            onState?("bad peer token from \(p)")
            return
        }
        onState?(ext ? "ranging (extended)" : "ranging")
    }

    private func handle(_ e: UWBEvent, from s: UWBSession) {
        guard let p = peers.first(where: { $0.value.session === s })?.key, let st = peers[p] else { return }
        switch e {
        case .distance(let d):
            if st.failures != 0 { peers[p]?.failures = 0 }
            onDistance?(p, d)
        case .removed(let peerEnded):
            if peerEnded {
                onState?("peer ended")
                // Its token is dead: wait for the new one (receive() re-runs) and re-send ours.
                if st.linkUp, let mine = st.myTokenData { onToken?(p, mine) }
            } else {
                // Timeout = peer briefly out of range or blocked; re-run so ranging resumes when it's back.
                timeouts += 1
                run(p)
            }
        case .suspended:
            suspensions += 1
            peers[p]?.suspended = true
            onState?("suspended")
        case .suspensionEnded:
            peers[p]?.suspended = false
            if st.linkUp, let mine = st.myTokenData { onToken?(p, mine) }  // the peer may have restarted meanwhile
            run(p)
        case .invalidated(let f):
            invalidated(p, f)
        }
    }

    private func invalidated(_ p: LinkPeer, _ f: UWBFailure) {
        guard let st = peers[p] else { return }
        failures[f, default: 0] += 1
        peers[p]?.session = nil
        peers[p]?.ranToken = nil
        onState?("invalidated \(f.rawValue) (\(p))")
        if f == .userDidNotAllow {
            denied = true  // retrying can't help until the user changes Settings; tried again on next foreground
            onState?("not allowed")
            return
        }
        // Extended distance gets one strike per pair: an extended run that fails this way, or fails twice
        // in a row with no distance, is retried without it.
        if st.ranExtended, f.blamesExtended || st.failures >= 1 {
            peers[p]?.extendedRejected = true
            onState?("extended distance rejected, ranging without it")
        }
        let n = st.failures + 1
        peers[p]?.failures = n
        peers[p]?.retryPending = true
        let delay = Self.backoff(failures: n, f)
        onState?("retrying in \(String(format: "%.1f", delay)) s")
        after(delay) { [weak self] in
            guard let self, self.peers[p]?.retryPending == true else { return }
            self.peers[p]?.retryPending = false
            self.ensure(p)  // no-op while the link is down, unheard or in the background: those re-ensure later
        }
    }
}

/// UWB coverage: the share of peer-seconds with a fresh UWB distance (at most 3 s old, Fusion's full-weight
/// window) while a UWB-capable peer is heard on Bluetooth and FlUni is in the foreground with UWB on. A peer
/// counts as capable unless its hello said it isn't (an unlinked peer counts: a link that never forms is a
/// UWB failure too). Background time is not counted: iOS doesn't allow iPhone-to-iPhone UWB there.
struct UWBCoverage: Equatable {
    static let fresh: TimeInterval = 3
    static let heard: TimeInterval = 10

    private(set) var eligible: Double = 0   // peer-seconds
    private(set) var covered: Double = 0

    /// One tick of `dt` seconds (capped at 2, so a stall isn't counted as a long gap).
    mutating func add(dt: TimeInterval, eligiblePeers: Int, coveredPeers: Int) {
        guard dt > 0, eligiblePeers > 0 else { return }
        let t = min(dt, 2)
        eligible += t * Double(eligiblePeers)
        covered += t * Double(min(coveredPeers, eligiblePeers))
    }

    /// 0-100, or nil before any eligible time.
    var percent: Double? { eligible > 0 ? 100 * covered / eligible : nil }

    /// Peer `i` is eligible if heard on Bluetooth within 10 s and not known to lack UWB; covered if its UWB
    /// reading is also fresh.
    static func classify(bleAge: TimeInterval?, uwbAge: TimeInterval?, capable: Bool?) -> (eligible: Bool, covered: Bool) {
        guard let b = bleAge, b <= heard, capable != false else { return (false, false) }
        return (true, (uwbAge ?? .infinity) <= fresh)
    }
}
