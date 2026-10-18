import Foundation
import MultipeerConnectivity
#if canImport(UIKit)
import UIKit
#endif

/// Message sent over the peer link. One flat struct keeps the wire format obvious.
struct Wire: Codable {
    enum Kind: String, Codable { case hello, uwbToken, gps }
    var kind: Kind
    var id: String? = nil       // hello: ephemeral ID (same one the BLE beacon carries)
    var risk: Risk? = nil       // hello (informational: Bluetooth's risk is the one used)
    var ext: Bool? = nil        // hello, optional: this phone supports UWB extended distance. Older builds omit it
                                // and ignore it (unknown JSON keys are skipped), so the format stays compatible.
    var uwb: Bool? = nil        // hello, optional: this phone can range with UWB (for the UWB coverage metric only)
    var token: Data? = nil      // uwbToken: archived NIDiscoveryToken
    var lat: Double? = nil      // gps
    var lon: Double? = nil
    var acc: Double? = nil
}

/// One remote phone as seen through one of our link identities. A new identity (ID rotation) gives a
/// new handle even for the same remote phone, so the old and new links can overlap (make-before-break).
struct LinkPeer: Hashable, CustomStringConvertible {
    let remote: MCPeerID
    let gen: Int
    var description: String { remote.displayName }
}

/// Encrypted local link (Bluetooth + peer-to-peer Wi-Fi) to nearby Fluni phones. Carries the UWB
/// discovery tokens and the hello (ID, risk, UWB capability); GPS fixes only in the harness.
///
/// Identity: the MCPeerID's display name is random and is replaced on every ephemeral-ID rotation
/// (`rotateIdentity`), so the link can't tie two rotating IDs together. The old identity stops
/// advertising at once but keeps its sessions until each remote is linked again under the new one
/// (or 15 s pass): make-before-break, so UWB ranging isn't interrupted by a rotation.
///
/// Reliability, from field logs (3 phones, 128 failed vs 27 good handshakes): good handshakes take
/// 2.4-4.5 s; failed ones hang until the invite timeout; the success rate fell from 39 % with no other
/// handshake in progress on the phone to 0 % with three, and was 0 of 12 when discovery restarted
/// mid-handshake. So: at most ONE handshake in progress per phone (we neither invite nor accept while
/// another is connecting), a 6 s invite timeout, short backoff, peers with fewer failures first.
///
/// Browsers are never stopped (crash fix, 2026-10-17). 19 SIGTRAPs on one day all had the stack
/// `_CFAssertMismatchedTypeID < CFRunLoopSourceInvalidate < CFNetwork _BrowserCancel`, and every crash
/// that had a console log followed a "link discovery restart" by under 1 s. MPC's stop (and dealloc) stops
/// its NSNetServiceBrowser from MPC's background queue while that browser is scheduled on the main run
/// loop; CFNetwork's deferred cancel then sometimes runs on freed memory. Apple bug r. 60399638, no fix, see
/// developer.apple.com/forums/thread/663772. Keeping our wrapper alive (the first fix) can't help, because
/// the freed object is MPC's own. So there are no discovery restarts. A retired identity's browser is parked
/// (BrowserLedger) until MPC has stopped it itself in the background. Browsing only starts while the app is
/// active. Advertisers have no browser inside, so they are stopped and started freely.
///
/// All state on the main queue. One MCSession per remote, fresh per attempt; callbacks from a session
/// that is no longer current are ignored. Every message is size-capped, rate-limited and validated
/// (LinkGuard) before anyone sees it.
final class PeerLink: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    static let serviceType = "fluni-prox"

    var onConnected: ((LinkPeer) -> Void)?
    /// `final` = the handle won't come back (identity retired): stop UWB for it now rather than waiting.
    var onDisconnected: ((LinkPeer, _ final: Bool) -> Void)?
    var onMessage: ((LinkPeer, Wire) -> Void)?

    /// Set before first use (launch arguments); sessions are created lazily with them.
    var encryption = MCEncryptionPreference.required
    var inviteTimeout: TimeInterval = 6

    // Tuning (see the type comment for the field data behind them).
    static let watchdogSlack: TimeInterval = 1        // a handshake still connecting this long past the invite timeout is dead
    static let largerNameWait: TimeInterval = 4       // the larger name invites too if the smaller hasn't by then
    static let restartDelay: TimeInterval = 0.5       // stop, then start on a later main-queue turn
    static let releaseDelay: TimeInterval = 120       // keep a released identity's sessions/advertiser alive this long
    static let browseRetryDelay: TimeInterval = 30    // after a browse error, park that browser and try a fresh one
    static let retireAfterRelink: TimeInterval = 3    // old identity kept this long after the new link is up (UWB tokens)
    static let retireDeadline: TimeInterval = 15

    private struct Slot {
        var session: MCSession
        var state: MCSessionState = .notConnected
        var since = Date()          // when `state` was entered
        var failures = 0            // consecutive attempts that did not reach .connected
        var nextTry = Date.distantPast
        var limiter = RateLimiter()
        var warned = false          // logged a dropped message already
    }

    private final class Identity {
        let gen: Int
        let me: MCPeerID
        let advertiser: MCNearbyServiceAdvertiser
        /// Created when browsing starts (only while the app is active), parked when the identity stops
        /// discovering. Never stopped, never started twice.
        var browser: MCNearbyServiceBrowser?
        var found: [MCPeerID: Date] = [:]   // peer -> first seen
        var slots: [MCPeerID: Slot] = [:]
        var retireBy: Date?                 // non-nil once replaced by a newer identity
        var discovering = false

        init(gen: Int) {
            self.gen = gen
            // Random per identity, never the device name. 8 hex digits, as before.
            me = MCPeerID(displayName: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)))
            advertiser = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: nil, serviceType: PeerLink.serviceType)
        }
    }

    private var gens = 0
    private lazy var current = makeIdentity()
    private var retiring: [Identity] = []
    private var graveyard: [Identity] = []   // released identities (sessions, advertiser), kept a while
    private var ledger = BrowserLedger()
    private var parkedBrowsers: [Int: MCNearbyServiceBrowser] = [:]   // keyed like the ledger
    private var lastBrowseRetry = Date.distantPast
    private var observing = false
    private var tick: Timer?
    private var started = false
    private var paused = false

    /// Linked peers under the current identity (the ones that get the hello and GPS fixes).
    var connectedPeers: [LinkPeer] {
        current.slots.filter { $0.value.state == .connected }.map { LinkPeer(remote: $0.key, gen: current.gen) }
    }

    private func log(_ s: String) { print("[fluni] \(s)"); fflush(stdout) }

    private func makeIdentity() -> Identity {
        gens += 1
        let id = Identity(gen: gens)
        id.advertiser.delegate = self
        return id
    }

    private var identities: [Identity] { [current] + retiring }

    func start() {
        started = true
        paused = false
        observeAppState()
        startDiscovery(current)
        startTimer()
    }

    /// MPC itself stops browsing when the app goes to the background and restarts it on return. The ledger
    /// mirrors that, so parked browsers are released only after MPC has stopped them.
    private func observeAppState() {
        guard !observing else { return }
        observing = true
        #if canImport(UIKit)
        ledger = BrowserLedger(inBackground: UIApplication.shared.applicationState == .background)
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.ledger.enteredBackground(at: Date())
            self.log("link app background, parked=\(self.ledger.parkedCount)")
            guard self.ledger.parkedCount > 0 else { return }
            // Stay awake past the grace period (the harness has no background mode), then release.
            if self.releaseTask == .invalid {
                self.releaseTask = UIApplication.shared.beginBackgroundTask(withName: "fluni.link.release") { [weak self] in
                    self?.endReleaseTask()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + BrowserLedger.grace + 1) { [weak self] in
                self?.releaseParked()
                self?.endReleaseTask()
            }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.ledger.willEnterForeground()
        }
        // An identity made in the background (rotation, Bluetooth relaunch) starts browsing now.
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            // A launch into the background may become active without willEnterForeground. Treating MPC-stopped
            // browsers as browsing again is the safe direction (they are just released later).
            if self.ledger.inBackground { self.ledger.willEnterForeground() }
            guard self.started, !self.paused else { return }
            self.startBrowsing(self.current)
        }
        #endif
    }

    #if canImport(UIKit)
    private var releaseTask = UIBackgroundTaskIdentifier.invalid
    private func endReleaseTask() {
        guard releaseTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(releaseTask)
        releaseTask = .invalid
    }
    #endif

    /// Deallocates the parked browsers MPC has stopped (see BrowserLedger).
    private func releaseParked() {
        let gone = ledger.releasable(at: Date())
        for k in gone { parkedBrowsers[k] = nil }
        if !gone.isEmpty { log("link released \(gone.count) parked browsers, \(ledger.parkedCount) left") }
    }

    /// Retires a browser without stopping it (see type comment).
    private func park(_ b: MCNearbyServiceBrowser) {
        b.delegate = nil
        let k = ObjectIdentifier(b).hashValue
        if !ledger.park(k) { parkedBrowsers[k] = b }  // never started: let it go now
        releaseParked()
    }

    private func startTimer() {
        guard tick == nil else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.maintain() }
    }

    private func startDiscovery(_ id: Identity) {
        guard !id.discovering else { return }
        id.discovering = true
        id.advertiser.startAdvertisingPeer()
        startBrowsing(id)
    }

    /// A fresh browser, only while the app is active and under the parked cap. Otherwise the identity only
    /// advertises (peers can still invite it) until the app is next active with room.
    private func startBrowsing(_ id: Identity) {
        guard id.discovering, id.browser == nil, id === current else { return }
        guard ledger.canStartBrowser else {
            if !ledger.inBackground { log("link browse deferred: \(ledger.parkedCount) parked browsers (cap)") }
            return
        }
        let b = MCNearbyServiceBrowser(peer: id.me, serviceType: PeerLink.serviceType)
        b.delegate = self
        let k = ObjectIdentifier(b).hashValue
        ledger.add(k)
        ledger.started(k)
        id.browser = b
        b.startBrowsingForPeers()
        log("link browse start gen=\(id.gen) parked=\(ledger.parkedCount)")
    }

    /// Stops advertising (safe: no browser inside) and parks the browser (never stopped, see type comment).
    private func stopDiscovery(_ id: Identity) {
        guard id.discovering else { return }
        id.discovering = false
        id.advertiser.stopAdvertisingPeer()
        if let b = id.browser { id.browser = nil; park(b) }
    }

    /// Disconnects and forgets an identity, keeping its objects alive for a moment (see type comment).
    private func release(_ id: Identity, notify: Bool) {
        stopDiscovery(id)
        for (peer, slot) in id.slots {
            slot.session.delegate = nil
            slot.session.disconnect()
            if notify, slot.state == .connected { onDisconnected?(LinkPeer(remote: peer, gen: id.gen), true) }
        }
        id.slots.removeAll()
        id.found.removeAll()
        retiring.removeAll { $0 === id }
        graveyard.append(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseDelay) { [weak self] in
            self?.graveyard.removeAll { $0 === id }
        }
    }

    /// Stops advertising and browsing and drops every connection. Safe to call twice. No callbacks
    /// fire for the dropped peers; the caller clears its own per-peer state.
    func stop() {
        paused = true
        tick?.invalidate()
        tick = nil
        for id in retiring { release(id, notify: false) }
        stopDiscovery(current)  // the browser is parked; resume() starts a fresh one
        for slot in current.slots.values { slot.session.delegate = nil; slot.session.disconnect() }
        current.slots.removeAll()
        current.found.removeAll()
    }

    /// Starts again after stop() (or for the first time, if the app launched paused).
    func resume() {
        guard started else { start(); return }
        guard paused else { return }
        paused = false
        // Not in the same run-loop turn as a stop() that may just have happened.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartDelay) { [weak self] in
            guard let self, !self.paused else { return }
            self.startDiscovery(self.current)
            self.startTimer()
        }
    }

    /// New random MCPeerID, called on every ephemeral-ID rotation. Make-before-break: the old identity
    /// stops advertising now but keeps its links until the same phones are linked again under the new
    /// one (plus a few seconds for the UWB token swap) or 15 s pass. Before start() or while paused it
    /// simply swaps.
    func rotateIdentity() {
        let old = current
        current = makeIdentity()
        stopDiscovery(old)
        let hasLinks = old.slots.values.contains { $0.state == .connected }
        if hasLinks && started && !paused {
            for (peer, slot) in old.slots where slot.state != .connected {  // half-open attempts: drop
                slot.session.delegate = nil
                slot.session.disconnect()
                old.slots[peer] = nil
            }
            old.found.removeAll()
            old.retireBy = Date().addingTimeInterval(Self.retireDeadline)
            retiring.append(old)
        } else {
            release(old, notify: false)
        }
        log("link identity gen=\(current.gen) retiring=\(retiring.count) parked=\(ledger.parkedCount)")
        guard started, !paused else { return }
        let cur = current
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartDelay) { [weak self] in
            guard let self, !self.paused, cur === self.current else { return }
            self.startDiscovery(cur)
        }
    }

    func send(_ w: Wire, to peers: [LinkPeer]? = nil) {
        guard let data = try? JSONEncoder().encode(w) else { return }
        for p in peers ?? connectedPeers {
            guard let id = identities.first(where: { $0.gen == p.gen }), let slot = id.slots[p.remote],
                  slot.state == .connected else { continue }
            try? slot.session.send(data, toPeers: [p.remote], with: .reliable)
        }
    }

    // MARK: Discovery

    private func identity(of advertiser: MCNearbyServiceAdvertiser) -> Identity? {
        identities.first { $0.advertiser === advertiser }
    }

    private func identity(of browser: MCNearbyServiceBrowser) -> Identity? {
        identities.first { $0.browser === browser }
    }

    func browser(_ b: MCNearbyServiceBrowser, foundPeer peer: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            guard !self.paused, let id = self.identity(of: b), id === self.current else { return }
            guard peer.displayName != id.me.displayName else { return }
            if id.found[peer] == nil { id.found[peer] = Date() }
            self.maintain()
        }
    }

    func browser(_ b: MCNearbyServiceBrowser, lostPeer peer: MCPeerID) {
        // Only discovery is lost; an established session is judged by its own state.
        DispatchQueue.main.async { self.identity(of: b)?.found[peer] = nil }
    }

    /// The browse never started. Park that browser (not stopped, see type comment) and try a fresh one,
    /// at most every `browseRetryDelay`.
    func browser(_ b: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async {
            self.log("link browse failed: \(error.localizedDescription)")
            guard let id = self.identity(of: b), id === self.current, id.browser === b else { return }
            id.browser = nil
            id.found.removeAll()
            self.park(b)
            let wait = max(0, Self.browseRetryDelay - Date().timeIntervalSince(self.lastBrowseRetry))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                guard !self.paused, id === self.current else { return }
                self.lastBrowseRetry = Date()
                self.startBrowsing(id)
            }
        }
    }

    /// Advertisers hold no browser, so restarting one is safe: stop now, start a few seconds later.
    func advertiser(_ a: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async {
            self.log("link advertise failed: \(error.localizedDescription)")
            guard let id = self.identity(of: a), id === self.current, id.discovering else { return }
            a.stopAdvertisingPeer()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard !self.paused, id === self.current, id.discovering else { return }
                a.startAdvertisingPeer()
            }
        }
    }

    private var anyConnecting: Bool {
        identities.contains { $0.slots.values.contains { $0.state == .connecting } }
    }

    // MARK: Attempts

    private func newSession(_ id: Identity, for peer: MCPeerID) -> MCSession {
        if let old = id.slots[peer]?.session { old.delegate = nil; old.disconnect() }
        let s = MCSession(peer: id.me, securityIdentity: nil, encryptionPreference: encryption)
        s.delegate = self
        return s
    }

    /// 0.5, 1, 2, 4, 4 ... s plus jitter, so two phones that failed together don't retry in lockstep.
    static func backoff(_ failures: Int) -> TimeInterval {
        min(4, 0.5 * pow(2, Double(max(0, failures - 1)))) + Double.random(in: 0 ... 0.5)
    }

    /// Drop a failed or stuck slot and schedule the next attempt.
    private func fail(_ id: Identity, _ peer: MCPeerID, _ why: String) {
        guard var slot = id.slots[peer] else { return }
        slot.session.delegate = nil
        slot.session.disconnect()
        slot.failures += 1
        slot.nextTry = Date().addingTimeInterval(Self.backoff(slot.failures))
        slot.state = .notConnected
        slot.since = Date()
        id.slots[peer] = slot
        log("link attempt failed \(peer.displayName) (\(why)) failures=\(slot.failures)")
    }

    private func activeCount(_ id: Identity) -> Int {
        id.slots.values.filter { $0.state != .notConnected }.count
    }

    private func invite(_ id: Identity, _ peer: MCPeerID) {
        let failures = id.slots[peer]?.failures ?? 0
        var slot = Slot(session: newSession(id, for: peer))
        slot.state = .connecting
        slot.failures = failures
        id.slots[peer] = slot
        log("link connecting \(peer.displayName) (invite, attempt \(failures + 1))")
        id.browser?.invitePeer(peer, to: slot.session, withContext: nil, timeout: inviteTimeout)
    }

    /// Every second (and on discovery events): expire stuck attempts, retire old identities, prune
    /// forgotten slots, then start at most one handshake.
    private func maintain() {
        guard started, !paused else { return }
        let now = Date()
        for id in identities {
            for (peer, slot) in id.slots where slot.state == .connecting
                && now.timeIntervalSince(slot.since) > inviteTimeout + Self.watchdogSlack {
                if id === current { fail(id, peer, "connecting timeout") } else {
                    slot.session.delegate = nil; slot.session.disconnect(); id.slots[peer] = nil
                }
            }
            // A peer that is gone from discovery and not linked for a minute is forgotten.
            for (peer, slot) in id.slots where slot.state == .notConnected && id.found[peer] == nil
                && now.timeIntervalSince(slot.since) > 60 {
                id.slots[peer] = nil
            }
        }
        for old in retiring {
            let linked = old.slots.filter { $0.value.state == .connected }.map(\.key)
            let moved = linked.allSatisfy { r in
                current.slots[r].map { $0.state == .connected && now.timeIntervalSince($0.since) >= Self.retireAfterRelink } ?? false
            }
            if moved || now >= (old.retireBy ?? now) {
                log("link retired gen=\(old.gen) links=\(linked.count) relinked=\(moved)")
                release(old, notify: true)
            }
        }
        guard current.browser != nil, !anyConnecting, activeCount(current) < LinkGuard.maxPeers else { return }
        // One handshake at a time; the peer that has failed least goes first (a stale Bonjour entry
        // that never answers can't starve the real phones).
        let me = current.me.displayName
        let candidates = current.found.filter { peer, seen in
            let slot = current.slots[peer]
            guard (slot?.state ?? .notConnected) == .notConnected, now >= (slot?.nextTry ?? .distantPast) else { return false }
            // The smaller name invites; the larger waits for that, but not for long.
            return me < peer.displayName || now.timeIntervalSince(max(seen, slot?.since ?? seen)) > Self.largerNameWait
        }
        if let next = candidates.min(by: { (current.slots[$0.key]?.failures ?? 0, $0.value) < (current.slots[$1.key]?.failures ?? 0, $1.value) }) {
            invite(current, next.key)
        }
    }

    func advertiser(_ a: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peer: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async {
            guard !self.paused, let id = self.identity(of: a), id === self.current else {
                invitationHandler(false, nil); return
            }
            let mine = id.slots[peer]
            // Glare (both inviting each other): the smaller name's invite wins.
            if mine?.state == .connecting, id.me.displayName < peer.displayName {
                invitationHandler(false, nil); return
            }
            // One handshake at a time: busy with another phone -> decline; it retries after a short backoff.
            let busyElsewhere = self.identities.contains { other in
                other.slots.contains { $0.value.state == .connecting && !(other === id && $0.key == peer) }
            }
            let isNew = (mine?.state ?? .notConnected) == .notConnected
            if busyElsewhere || (isNew && self.activeCount(id) >= LinkGuard.maxPeers) {
                invitationHandler(false, nil); return
            }
            // Otherwise accept, also over an existing session: the sender only re-invites once it
            // considers the old one dead.
            var slot = Slot(session: self.newSession(id, for: peer))
            slot.state = .connecting
            slot.failures = mine?.failures ?? 0
            id.slots[peer] = slot
            if mine?.state == .connected { self.onDisconnected?(LinkPeer(remote: peer, gen: id.gen), false) }
            self.log("link connecting \(peer.displayName) (accepted invite)")
            invitationHandler(true, slot.session)
        }
    }

    // MARK: Session

    func session(_ s: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peer: MCPeerID,
                 certificateHandler: @escaping (Bool) -> Void) {
        // No identity pinning (peers are anonymous by design). Answering at once avoids handshake stalls.
        certificateHandler(true)
    }

    /// The identity whose current session for `peer` is `s`, if any.
    private func owner(of s: MCSession, _ peer: MCPeerID) -> Identity? {
        identities.first { $0.slots[peer]?.session === s }
    }

    func session(_ s: MCSession, peer: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            // Ignore callbacks from sessions we already replaced.
            guard let id = self.owner(of: s, peer), var slot = id.slots[peer] else { return }
            let handle = LinkPeer(remote: peer, gen: id.gen)
            let was = slot.state
            switch state {
            case .connected:
                let took = Date().timeIntervalSince(slot.since)
                slot.state = .connected
                slot.since = Date()
                slot.failures = 0
                id.slots[peer] = slot
                self.log("link up \(peer.displayName)")
                self.log("link metric handshake=\(String(format: "%.2f", took)) gen=\(id.gen)")
                self.onConnected?(handle)
            case .connecting:
                break
            case .notConnected:
                if was == .connected {
                    // Real drop: discard the session; reconnect with a fresh one shortly (current identity only).
                    slot.session.delegate = nil
                    slot.session.disconnect()
                    if id === self.current {
                        slot.state = .notConnected
                        slot.since = Date()
                        slot.nextTry = Date().addingTimeInterval(0.5)
                        id.slots[peer] = slot
                    } else {
                        id.slots[peer] = nil
                    }
                    self.onDisconnected?(handle, id !== self.current)
                } else if id === self.current {
                    self.fail(id, peer, "handshake ended")
                } else {
                    id.slots[peer] = nil
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.maintain() }
            @unknown default: break
            }
        }
    }

    func session(_ s: MCSession, didReceive data: Data, fromPeer peer: MCPeerID) {
        let size = data.count
        let w = size <= LinkGuard.maxMessageBytes ? LinkGuard.decode(data) : nil  // decode off the main queue
        DispatchQueue.main.async {
            guard let id = self.owner(of: s, peer), id.slots[peer]?.state == .connected else { return }
            let allowed = id.slots[peer]?.limiter.allow(now: Date()) ?? false
            guard allowed, let w else {
                if id.slots[peer]?.warned == false {
                    id.slots[peer]?.warned = true
                    self.log("link dropped message from \(peer.displayName) (\(allowed ? "invalid, \(size) bytes" : "rate limit"))")
                }
                return
            }
            self.onMessage?(LinkPeer(remote: peer, gen: id.gen), w)
        }
    }

    func session(_ s: MCSession, didReceive stream: InputStream, withName n: String, fromPeer p: MCPeerID) {
        stream.close()  // never used; don't hold a stream open
    }
    func session(_ s: MCSession, didStartReceivingResourceWithName n: String, fromPeer p: MCPeerID, with progress: Progress) {
        progress.cancel()  // never used
    }
    func session(_ s: MCSession, didFinishReceivingResourceWithName n: String, fromPeer p: MCPeerID, at url: URL?, withError e: Error?) {}
}
