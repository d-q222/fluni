import Foundation
import MultipeerConnectivity
import NearbyInteraction

/// Ultra-wideband ranging, one NISession per peer. Each side sends its discovery token over the
/// peer link; once both have the other's token, the U1 chips range to ~10 cm.
final class UWBRanger: NSObject, NISessionDelegate {
    static var isSupported: Bool { NISession.deviceCapabilities.supportsPreciseDistanceMeasurement }

    /// Archived token to send to this peer.
    var onToken: ((MCPeerID, Data) -> Void)?
    var onDistance: ((MCPeerID, Double) -> Void)?
    var onState: ((String) -> Void)?

    private var sessions: [MCPeerID: NISession] = [:]
    private var peerTokens: [MCPeerID: NIDiscoveryToken] = [:]
    private var active: Set<MCPeerID> = []  // linked peers; a delayed restart checks this
    private var myTokenData: [MCPeerID: Data] = [:]
    private var peerTokenData: [MCPeerID: Data] = [:]

    func start(for peer: MCPeerID) {
        guard Self.isSupported else { onState?("not supported on this device"); return }
        active.insert(peer)
        sessions.removeValue(forKey: peer)?.invalidate()
        let s = NISession()
        s.delegate = self
        sessions[peer] = s
        guard let token = s.discoveryToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        else { return }
        myTokenData[peer] = data
        onToken?(peer, data)
        if let theirs = peerTokens[peer] { run(s, theirs) }
    }

    func receive(tokenData: Data, from peer: MCPeerID) {
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: tokenData)
        else { return }
        let isNew = peerTokenData[peer] != tokenData
        peerTokens[peer] = token
        peerTokenData[peer] = tokenData
        guard let s = sessions[peer] else { return }
        run(s, token)
        // The peer has a new token, so it restarted and may have forgotten ours: send it again.
        // Terminates because an unchanged token does not trigger a reply.
        if isNew, let mine = myTokenData[peer] { onToken?(peer, mine) }
    }

    func stop(for peer: MCPeerID) {
        active.remove(peer)
        sessions.removeValue(forKey: peer)?.invalidate()
        peerTokens.removeValue(forKey: peer)
        peerTokenData.removeValue(forKey: peer)
        myTokenData.removeValue(forKey: peer)
    }

    private func run(_ s: NISession, _ token: NIDiscoveryToken) {
        s.run(NINearbyPeerConfiguration(peerToken: token))
        onState?("ranging")
    }

    private func peer(of s: NISession) -> MCPeerID? {
        sessions.first { $0.value === s }?.key
    }

    func session(_ s: NISession, didUpdate objects: [NINearbyObject]) {
        guard let peer = peer(of: s), let d = objects.first?.distance else { return }
        onDistance?(peer, Double(d))
    }

    func session(_ s: NISession, didRemove objects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard let peer = peer(of: s) else { return }
        if reason == .peerEnded {
            // The peer ended its session, so our copy of its token is dead. Wait for its new token
            // (receive() re-runs) and re-send ours in case it restarted without it.
            onState?("peer ended")
            if let mine = myTokenData[peer] { onToken?(peer, mine) }
            return
        }
        // Timeout = peer briefly out of range; re-run so ranging resumes when it's back.
        guard let t = peerTokens[peer] else { return }
        run(s, t)
    }

    func sessionWasSuspended(_ s: NISession) { onState?("suspended") }

    func sessionSuspensionEnded(_ s: NISession) {
        guard let peer = peer(of: s) else { return }
        if let mine = myTokenData[peer] { onToken?(peer, mine) }  // the peer may have restarted meanwhile
        if let t = peerTokens[peer] { run(s, t) }
    }

    func session(_ s: NISession, didInvalidateWith error: Error) {
        guard let peer = peer(of: s) else { return }
        sessions.removeValue(forKey: peer)
        if (error as? NIError)?.code == .userDidNotAllow { onState?("not allowed"); return }  // retrying can't help
        onState?("restarting: \(error.localizedDescription)")
        // A new session has a new token, so the peer must get it again. Their token is still good.
        // Delayed so a persistent failure can't spin; skipped if the peer left meanwhile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.active.contains(peer), self.sessions[peer] == nil else { return }
            self.start(for: peer)
        }
    }
}
