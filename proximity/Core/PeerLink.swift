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
    var token: Data? = nil      // uwbToken: archived NIDiscoveryToken
    var lat: Double? = nil      // gps
    var lon: Double? = nil
    var acc: Double? = nil
}

/// Encrypted local link (Bluetooth + peer-to-peer Wi-Fi) to nearby Fluni phones.
/// Carries the UWB discovery tokens, GPS fixes and risk status. The display name is random per
/// launch, never the device name.
///
/// Robustness design (all state on the main queue): one MCSession per remote peer, created fresh for
/// every connection attempt, so a half-open or failed handshake can never poison another attempt or
/// peer. Callbacks from a session that is no longer current are ignored. Invites are tracked (one
/// pending attempt per peer, with a watchdog) and retried with backoff instead of a fixed 1 s storm.
final class PeerLink: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    static let serviceType = "fluni-prox"

    var onConnected: ((MCPeerID) -> Void)?
    var onDisconnected: ((MCPeerID) -> Void)?
    var onMessage: ((MCPeerID, Wire) -> Void)?

    /// Set before first use (launch arguments); sessions are created lazily with them.
    var encryption = MCEncryptionPreference.required
    var inviteTimeout: TimeInterval = 10

    private struct Slot {
        var session: MCSession
        var state: MCSessionState = .notConnected
        var since = Date()          // when `state` was entered
        var failures = 0            // consecutive attempts that did not reach .connected
        var nextTry = Date.distantPast
    }

    private let me = MCPeerID(displayName: String(UUID().uuidString.prefix(8)))
    private lazy var advertiser = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: nil, serviceType: Self.serviceType)
    private lazy var browser = MCNearbyServiceBrowser(peer: me, serviceType: Self.serviceType)
    private var found: [MCPeerID: Date] = [:]   // peer -> first seen
    private var slots: [MCPeerID: Slot] = [:]
    private var tick: Timer?
    private var lastDiscoveryRestart = Date()
    private var totalFailures = 0
    private var started = false
    private var paused = false

    var connectedPeers: [MCPeerID] { slots.filter { $0.value.state == .connected }.map(\.key) }

    private func log(_ s: String) { print("[fluni] \(s)"); fflush(stdout) }

    func start() {
        started = true
        advertiser.delegate = self
        browser.delegate = self
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        tick = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.maintain() }
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.restartDiscovery("foreground") }
        #endif
    }

    /// Stops advertising and browsing and drops every connection. Safe to call twice. No callbacks
    /// fire for the dropped peers; the caller clears its own per-peer state.
    func stop() {
        paused = true
        tick?.invalidate()
        tick = nil
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        for slot in slots.values { slot.session.delegate = nil; slot.session.disconnect() }
        slots.removeAll()
        found.removeAll()
    }

    /// Starts again after stop() (or for the first time, if the app launched paused).
    func resume() {
        paused = false
        guard started else { start(); return }
        guard tick == nil else { return }
        lastDiscoveryRestart = .distantPast
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        tick = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.maintain() }
    }

    func send(_ w: Wire, to peers: [MCPeerID]? = nil) {
        guard let data = try? JSONEncoder().encode(w) else { return }
        for p in peers ?? connectedPeers {
            guard let slot = slots[p], slot.state == .connected else { continue }
            try? slot.session.send(data, toPeers: [p], with: .reliable)
        }
    }

    // MARK: Discovery

    // Both phones browse; the smaller name invites. If the larger one has waited a long time and
    // nothing arrived, it invites too (glare is resolved in the invitation handler).
    func browser(_ b: MCNearbyServiceBrowser, foundPeer peer: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            guard !self.paused else { return }
            if self.found[peer] == nil { self.found[peer] = Date() }
            self.maintain()
        }
    }

    func browser(_ b: MCNearbyServiceBrowser, lostPeer peer: MCPeerID) {
        // Only discovery is lost; an established session is judged by its own state.
        DispatchQueue.main.async { self.found[peer] = nil }
    }

    func browser(_ b: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        log("link browse failed: \(error.localizedDescription)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.restartDiscovery("browse error") }
    }

    func advertiser(_ a: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        log("link advertise failed: \(error.localizedDescription)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.restartDiscovery("advertise error") }
    }

    private func restartDiscovery(_ why: String) {
        guard !paused, Date().timeIntervalSince(lastDiscoveryRestart) > 3 else { return }
        lastDiscoveryRestart = Date()
        log("link discovery restart (\(why))")
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        found.removeAll()  // foundPeer fires again for peers still around
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    // MARK: Attempts

    private func newSession(for peer: MCPeerID) -> MCSession {
        if let old = slots[peer]?.session { old.delegate = nil; old.disconnect() }
        let s = MCSession(peer: me, securityIdentity: nil, encryptionPreference: encryption)
        s.delegate = self
        return s
    }

    private func backoff(_ failures: Int) -> TimeInterval {
        min(8, pow(2, Double(max(0, failures - 1)))) + Double.random(in: 0...0.5)
    }

    /// Drop a failed or stuck slot and schedule the next attempt.
    private func fail(_ peer: MCPeerID, _ why: String) {
        guard var slot = slots[peer] else { return }
        slot.session.delegate = nil
        slot.session.disconnect()
        slot.failures += 1
        totalFailures += 1
        slot.nextTry = Date().addingTimeInterval(backoff(slot.failures))
        slot.state = .notConnected
        slot.since = Date()
        slots[peer] = slot
        log("link attempt failed \(peer.displayName) (\(why)) failures=\(slot.failures)")
        if totalFailures % 4 == 0 { restartDiscovery("repeated failures") }
    }

    private func invite(_ peer: MCPeerID) {
        guard found[peer] != nil, slots[peer].map({ $0.state == .notConnected && Date() >= $0.nextTry }) ?? true else { return }
        let failures = slots[peer]?.failures ?? 0
        var slot = Slot(session: newSession(for: peer))
        slot.state = .connecting
        slot.failures = failures
        slots[peer] = slot
        log("link connecting \(peer.displayName) (invite, attempt \(failures + 1))")
        browser.invitePeer(peer, to: slot.session, withContext: nil, timeout: inviteTimeout)
    }

    /// Every 2 s: expire stuck attempts and (re)invite found peers that aren't linked.
    private func maintain() {
        guard !paused else { return }
        let now = Date()
        for (peer, slot) in slots where slot.state == .connecting
            && now.timeIntervalSince(slot.since) > inviteTimeout + 5 {
            fail(peer, "connecting timeout")
        }
        for (peer, seen) in found where (slots[peer]?.state ?? .notConnected) == .notConnected {
            // The smaller name invites; the larger waits for that, but not forever.
            if me.displayName < peer.displayName || now.timeIntervalSince(seen) > 20 { invite(peer) }
        }
    }

    func advertiser(_ a: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peer: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async {
            if self.paused { invitationHandler(false, nil); return }
            // Glare (both inviting): the smaller name's invite wins. Otherwise always accept, also
            // over an existing session: the sender only re-invites once it considers the old one dead.
            if self.slots[peer]?.state == .connecting, self.me.displayName < peer.displayName {
                invitationHandler(false, nil); return
            }
            var slot = Slot(session: self.newSession(for: peer))
            slot.state = .connecting
            slot.failures = self.slots[peer]?.failures ?? 0
            self.slots[peer] = slot
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

    func session(_ s: MCSession, peer: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            // Ignore callbacks from sessions we already replaced.
            guard var slot = self.slots[peer], slot.session === s else { return }
            let was = slot.state
            switch state {
            case .connected:
                slot.state = .connected
                slot.since = Date()
                slot.failures = 0
                self.slots[peer] = slot
                self.log("link up \(peer.displayName)")
                self.onConnected?(peer)
            case .connecting:
                break
            case .notConnected:
                if was == .connected {
                    // Real drop: discard the session, reconnect with a fresh one shortly.
                    slot.session.delegate = nil
                    slot.session.disconnect()
                    slot.state = .notConnected
                    slot.since = Date()
                    slot.nextTry = Date().addingTimeInterval(0.5)
                    self.slots[peer] = slot
                    self.onDisconnected?(peer)
                } else {
                    self.fail(peer, "handshake ended")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.maintain() }
            @unknown default: break
            }
        }
    }

    func session(_ s: MCSession, didReceive data: Data, fromPeer peer: MCPeerID) {
        guard let w = try? JSONDecoder().decode(Wire.self, from: data) else { return }
        DispatchQueue.main.async {
            guard self.slots[peer]?.session === s else { return }
            self.onMessage?(peer, w)
        }
    }

    func session(_ s: MCSession, didReceive stream: InputStream, withName n: String, fromPeer p: MCPeerID) {}
    func session(_ s: MCSession, didStartReceivingResourceWithName n: String, fromPeer p: MCPeerID, with progress: Progress) {}
    func session(_ s: MCSession, didFinishReceivingResourceWithName n: String, fromPeer p: MCPeerID, at url: URL?, withError e: Error?) {}
}
