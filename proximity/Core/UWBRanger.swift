import Foundation
import NearbyInteraction

/// Ultra-wideband ranging, one NISession per linked peer. Each side sends its discovery token over the
/// peer link; once both have the other's token the chips range directly (UWB + Bluetooth, not the link).
///
/// Uptime rules (Apple docs / Apple's "Implementing Interactions Between Users in Close Proximity"
/// sample, which keeps its NISession when the MPC link drops and re-runs on timeout):
/// - The link is only needed to swap tokens. A link drop does NOT end the session: it keeps ranging
///   for up to `linkGrace` while the link reconnects (unsure until measured on phones how long NI keeps
///   ranging with no link; `link metric uwb_resume` shows it). Reconnecting to the same handle reuses
///   the session and re-sends our token at once, in case the peer restarted meanwhile.
/// - `.timeout` removal (out of range, blocked): re-run the same configuration.
/// - `.peerEnded`: the peer's token is dead; with the link up, re-send ours and wait for its new one;
///   with the link down, there is no way to get it, so stop.
/// - Suspension (background, another app using NI): Apple's docs say a suspended session resumes only
///   when `run` is called again, so `sessionSuspensionEnded` re-runs and re-sends the token.
/// - Invalidation: a fresh session (new token) after a short backoff, only while the link is up.
/// - Extended distance (iOS 17, U2 chip: iPhone 15 and later) only when both phones say they support it.
final class UWBRanger: NSObject, NISessionDelegate {
    static var isSupported: Bool { NISession.deviceCapabilities.supportsPreciseDistanceMeasurement }
    static var supportsExtendedDistance: Bool { NISession.deviceCapabilities.supportsExtendedDistanceMeasurement }

    /// Keep a session this long after its link drops, waiting for the link (and tokens) to come back.
    static let linkGrace: TimeInterval = 30

    /// Archived token to send to this peer.
    var onToken: ((LinkPeer, Data) -> Void)?
    var onDistance: ((LinkPeer, Double) -> Void)?
    var onState: ((String) -> Void)?
    /// The peer's session is gone for good (grace ran out, peer ended while unlinked, or stop()).
    var onStopped: ((LinkPeer) -> Void)?

    private struct Peer {
        var session: NISession?
        var myTokenData: Data?
        var theirToken: NIDiscoveryToken?
        var theirTokenData: Data?
        var linkUp = true
        var downSince: Date?
        var extended = false
        var restarts = 0           // consecutive invalidations without a distance in between
    }

    private var peers: [LinkPeer: Peer] = [:]

    /// The link to this peer is up (new or reconnected).
    func linkUp(_ p: LinkPeer) {
        guard Self.isSupported else { onState?("not supported on this device"); return }
        if var st = peers[p], st.session != nil {
            st.linkUp = true
            st.downSince = nil
            peers[p] = st
            if let mine = st.myTokenData { onToken?(p, mine) }  // proactively: the peer may have lost it
            return
        }
        peers[p, default: Peer()].linkUp = true
        peers[p]?.downSince = nil
        newSession(p)
    }

    /// The link dropped. Ranging continues; the session ends only if the link isn't back in `linkGrace`.
    func linkDown(_ p: LinkPeer) {
        guard peers[p] != nil else { return }
        let at = Date()
        peers[p]?.linkUp = false
        peers[p]?.downSince = at
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linkGrace) { [weak self] in
            guard let self, let st = self.peers[p], !st.linkUp, st.downSince == at else { return }
            self.onState?("link gone, stopping")
            self.stop(for: p)
        }
    }

    /// Whether to use extended distance with this peer (from the hello). Re-runs if it changed.
    func setExtended(_ on: Bool, for p: LinkPeer) {
        guard var st = peers[p], st.extended != on else { return }
        st.extended = on
        peers[p] = st
        if let s = st.session, let t = st.theirToken { run(s, t, p) }
    }

    func receive(tokenData: Data, from p: LinkPeer) {
        guard tokenData.count <= LinkGuard.maxTokenBytes,
              let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: tokenData),
              var st = peers[p] else { return }
        let isNew = st.theirTokenData != tokenData
        st.theirToken = token
        st.theirTokenData = tokenData
        peers[p] = st
        guard let s = st.session else { return }  // a restart is pending; it will run with this token
        if isNew || s.configuration == nil { run(s, token, p) }
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
        peers.removeAll()  // first, so the invalidation callbacks find no peer and do nothing
        old.values.forEach { $0.session?.invalidate() }
    }

    private func newSession(_ p: LinkPeer) {
        peers[p]?.session?.invalidate()
        let s = NISession()
        s.delegate = self
        peers[p]?.session = s
        guard let token = s.discoveryToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        else { return }
        peers[p]?.myTokenData = data
        onToken?(p, data)
        if let theirs = peers[p]?.theirToken { run(s, theirs, p) }
    }

    private func run(_ s: NISession, _ token: NIDiscoveryToken, _ p: LinkPeer) {
        let config = NINearbyPeerConfiguration(peerToken: token)
        let ext = (peers[p]?.extended ?? false) && Self.supportsExtendedDistance
        if ext { config.isExtendedDistanceMeasurementEnabled = true }
        s.run(config)
        onState?(ext ? "ranging (extended)" : "ranging")
    }

    private func handle(of s: NISession) -> LinkPeer? {
        peers.first { $0.value.session === s }?.key
    }

    func session(_ s: NISession, didUpdate objects: [NINearbyObject]) {
        guard let p = handle(of: s), let d = objects.first?.distance else { return }
        if peers[p]?.restarts != 0 { peers[p]?.restarts = 0 }
        onDistance?(p, Double(d))
    }

    func session(_ s: NISession, didRemove objects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard let p = handle(of: s), let st = peers[p] else { return }
        switch reason {
        case .peerEnded:
            onState?("peer ended")
            guard st.linkUp else { stop(for: p); return }
            // Its token is dead: wait for the new one (receive() re-runs) and re-send ours.
            if let mine = st.myTokenData { onToken?(p, mine) }
        default:
            // Timeout = peer briefly out of range or blocked; re-run so ranging resumes when it's back.
            if let t = st.theirToken { run(s, t, p) }
        }
    }

    func sessionWasSuspended(_ s: NISession) { onState?("suspended") }

    func sessionSuspensionEnded(_ s: NISession) {
        guard let p = handle(of: s), let st = peers[p] else { return }
        if st.linkUp, let mine = st.myTokenData { onToken?(p, mine) }  // the peer may have restarted meanwhile
        if let t = st.theirToken { run(s, t, p) }
    }

    func session(_ s: NISession, didInvalidateWith error: Error) {
        guard let p = handle(of: s) else { return }
        peers[p]?.session = nil
        if (error as? NIError)?.code == .userDidNotAllow { onState?("not allowed"); stop(for: p); return }  // retrying can't help
        onState?("restarting: \(error.localizedDescription)")
        // A new session has a new token, which needs the link. Their token is still good. Backoff
        // (0.25, 0.5, 1, 2, 4 s) so a persistent failure can't spin; skipped if the peer left meanwhile.
        let n = peers[p]?.restarts ?? 0
        peers[p]?.restarts = n + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + min(4, 0.25 * pow(2, Double(n)))) { [weak self] in
            guard let self, let st = self.peers[p], st.session == nil else { return }
            if st.linkUp { self.newSession(p) } else { self.stop(for: p) }
        }
    }
}
