import Foundation
import MultipeerConnectivity

/// Message sent over the peer link. One flat struct keeps the wire format obvious.
struct Wire: Codable {
    enum Kind: String, Codable { case hello, uwbToken, gps }
    var kind: Kind
    var id: String? = nil       // hello: ephemeral ID (same one the BLE beacon carries)
    var risk: Risk? = nil       // hello
    var token: Data? = nil      // uwbToken: archived NIDiscoveryToken
    var lat: Double? = nil      // gps
    var lon: Double? = nil
    var acc: Double? = nil
}

/// Encrypted local link (Bluetooth + peer-to-peer Wi-Fi) to nearby Fluni phones.
/// Carries the UWB discovery tokens, GPS fixes and risk status. The display name is random,
/// never the device name.
final class PeerLink: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    static let serviceType = "fluni-prox"

    var onConnected: ((MCPeerID) -> Void)?
    var onDisconnected: ((MCPeerID) -> Void)?
    var onMessage: ((MCPeerID, Wire) -> Void)?

    /// Set before first use (launch arguments); the session is created lazily with them.
    var encryption = MCEncryptionPreference.required
    var inviteTimeout: TimeInterval = 10

    private let me = MCPeerID(displayName: String(UUID().uuidString.prefix(8)))
    private lazy var session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: encryption)
    private lazy var advertiser = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: nil, serviceType: Self.serviceType)
    private lazy var browser = MCNearbyServiceBrowser(peer: me, serviceType: Self.serviceType)
    private var found: Set<MCPeerID> = []

    var connectedPeers: [MCPeerID] { session.connectedPeers }

    func start() {
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func send(_ w: Wire, to peers: [MCPeerID]? = nil) {
        let targets = peers ?? session.connectedPeers
        guard !targets.isEmpty, let data = try? JSONEncoder().encode(w) else { return }
        try? session.send(data, toPeers: targets, with: .reliable)
    }

    // Both phones browse; only the one with the smaller name invites, so they don't race.
    func browser(_ b: MCNearbyServiceBrowser, foundPeer peer: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            self.found.insert(peer)
            self.invite(peer)
        }
    }

    func browser(_ b: MCNearbyServiceBrowser, lostPeer peer: MCPeerID) {
        DispatchQueue.main.async { self.found.remove(peer) }
    }

    private func invite(_ peer: MCPeerID) {
        guard me.displayName < peer.displayName, found.contains(peer),
              !session.connectedPeers.contains(peer) else { return }
        browser.invitePeer(peer, to: session, withContext: nil, timeout: inviteTimeout)
    }

    func advertiser(_ a: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peer: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    func session(_ s: MCSession, peer: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected: self.onConnected?(peer)
            case .notConnected:
                self.onDisconnected?(peer)
                // Invites fail on first run (permission prompt) or links drop; keep trying while it's around.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.invite(peer) }
            default: break
            }
        }
    }

    func session(_ s: MCSession, didReceive data: Data, fromPeer peer: MCPeerID) {
        guard let w = try? JSONDecoder().decode(Wire.self, from: data) else { return }
        DispatchQueue.main.async { self.onMessage?(peer, w) }
    }

    func session(_ s: MCSession, didReceive stream: InputStream, withName n: String, fromPeer p: MCPeerID) {}
    func session(_ s: MCSession, didStartReceivingResourceWithName n: String, fromPeer p: MCPeerID, with progress: Progress) {}
    func session(_ s: MCSession, didFinishReceivingResourceWithName n: String, fromPeer p: MCPeerID, at url: URL?, withError e: Error?) {}
}
