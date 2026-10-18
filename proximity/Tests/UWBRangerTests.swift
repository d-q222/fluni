import XCTest
import MultipeerConnectivity
@testable import FluniProx

/// The UWB session state machine (Core/UWBRanger.swift) with a fake session and a manual clock:
/// invalidation → retry, rotation → fresh token exchange, suspension → resume, background → foreground,
/// peers never heard on Bluetooth, the session limit, and the coverage metric.
final class UWBRangerTests: XCTestCase {
    final class FakeSession: UWBSession {
        var onEvent: ((UWBEvent) -> Void)?
        let tokenData: Data?
        var runs: [(token: Data, extended: Bool)] = []
        var invalidated = false
        init(_ n: Int) { tokenData = Data("mine\(n)".utf8) }
        func run(peerToken: Data, extended: Bool) -> Bool { runs.append((peerToken, extended)); return true }
        func invalidate() { invalidated = true }
    }

    var sessions: [FakeSession] = []
    var pending: [(at: TimeInterval, work: () -> Void)] = []
    var clock: TimeInterval = 0
    var sent: [(LinkPeer, Data)] = []
    var distances: [Double] = []
    var stopped: [LinkPeer] = []

    func makeRanger(extended: Bool = false) -> UWBRanger {
        let r = UWBRanger(supported: true, extendedCapable: extended,
                          makeSession: { [unowned self] in let s = FakeSession(self.sessions.count); self.sessions.append(s); return s },
                          after: { [unowned self] d, f in self.pending.append((self.clock + d, f)) },
                          now: { [unowned self] in Date(timeIntervalSinceReferenceDate: self.clock) })
        r.onToken = { [unowned self] p, d in self.sent.append((p, d)) }
        r.onDistance = { [unowned self] _, d in self.distances.append(d) }
        r.onStopped = { [unowned self] p in self.stopped.append(p) }
        return r
    }

    /// Runs every scheduled block due by `t`.
    func advance(to t: TimeInterval) {
        clock = t
        while let i = pending.indices.filter({ pending[$0].at <= t }).min(by: { pending[$0].at < pending[$1].at }) {
            let w = pending.remove(at: i).work
            w()
        }
    }

    let peer = LinkPeer(remote: MCPeerID(displayName: "AAAA0001"), gen: 1)
    let theirs = Data("theirs".utf8)

    /// Linked, heard, tokens swapped: one session ranging.
    func ranging(_ r: UWBRanger) {
        r.linkUp(peer)
        r.setHeard(true, for: peer)
        r.receive(tokenData: theirs, from: peer)
    }

    func testNoSessionUntilBluetoothHearsThePeer() {
        let r = makeRanger()
        r.linkUp(peer)
        r.receive(tokenData: theirs, from: peer)  // token before heard: kept, no session
        XCTAssertTrue(sessions.isEmpty)
        r.setHeard(true, for: peer)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].runs.map(\.token), [theirs])  // runs with the token that came early
        XCTAssertEqual(sent.map(\.1), [Data("mine0".utf8)])
    }

    func testTokenBeforeLinkUpIsKept() {
        let r = makeRanger()
        r.receive(tokenData: theirs, from: peer)
        r.linkUp(peer)
        r.setHeard(true, for: peer)
        XCTAssertEqual(sessions.first?.runs.count, 1)
    }

    func testInvalidationRetriesWithBackoffForeverWhileLinkedAndHeard() {
        let r = makeRanger()
        ranging(r)
        var expectedDelays: [TimeInterval] = []
        for i in 0..<8 {
            sessions.last!.onEvent?(.invalidated(.invalidConfiguration))
            XCTAssertEqual(sessions.count, i + 1, "no immediate re-create")
            let due = pending.last!.at - clock
            expectedDelays.append(due)
            advance(to: clock + due)
            XCTAssertEqual(sessions.count, i + 2, "re-created after \(due) s")
            XCTAssertEqual(sessions.last!.runs.last?.token, theirs, "their token is still good")
            XCTAssertEqual(sent.last?.1, Data("mine\(i + 1)".utf8), "new token re-sent")
        }
        XCTAssertEqual(expectedDelays, [0.5, 1, 2, 4, 8, 16, 30, 30])
        XCTAssertEqual(r.failures[.invalidConfiguration], 8)
    }

    func testDistanceResetsBackoff() {
        let r = makeRanger()
        ranging(r)
        for _ in 0..<3 {
            sessions.last!.onEvent?(.invalidated(.sessionFailed))
            advance(to: pending.last!.at)
        }
        sessions.last!.onEvent?(.distance(1.2))
        sessions.last!.onEvent?(.invalidated(.sessionFailed))
        XCTAssertEqual(pending.last!.at - clock, 0.5)
        XCTAssertEqual(distances, [1.2])
    }

    func testRetryWaitsForLinkThenResumesOnReconnect() {
        let r = makeRanger()
        ranging(r)
        r.linkDown(peer)
        sessions.last!.onEvent?(.invalidated(.sessionFailed))
        advance(to: clock + 1)
        XCTAssertEqual(sessions.count, 1, "a new token can't reach the peer without the link")
        r.linkUp(peer)
        XCTAssertEqual(sessions.count, 2)
        advance(to: clock + 60)
        XCTAssertTrue(stopped.isEmpty, "the link came back within the grace")
    }

    func testLinkGraceStopsAfterThirtySeconds() {
        let r = makeRanger()
        ranging(r)
        r.linkDown(peer)
        advance(to: 29)
        XCTAssertTrue(stopped.isEmpty)
        sessions[0].onEvent?(.distance(0.8))  // still ranging without the link
        advance(to: 30)
        XCTAssertEqual(stopped, [peer])
        XCTAssertTrue(sessions[0].invalidated)
        XCTAssertEqual(distances, [0.8])
    }

    func testRotationGivesNewSessionAndFreshTokens() {
        let r = makeRanger()
        ranging(r)
        // The peer (or we) rotated: a new link identity, a new handle; make-before-break.
        let rotated = LinkPeer(remote: MCPeerID(displayName: "BBBB0002"), gen: 2)
        r.linkUp(rotated)
        r.setHeard(true, for: rotated)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sent.last?.0, rotated)
        XCTAssertNotEqual(sent.last?.1, sent.first?.1, "never reuses the old token")
        XCTAssertTrue(sessions[1].runs.isEmpty, "waits for the peer's new token, not the old one")
        let newTheirs = Data("theirs2".utf8)
        r.receive(tokenData: newTheirs, from: rotated)
        XCTAssertEqual(sessions[1].runs.map(\.token), [newTheirs])
        r.stop(for: peer)  // old identity retired
        XCTAssertTrue(sessions[0].invalidated)
        XCTAssertFalse(sessions[1].invalidated)
    }

    func testPeerRestartedResendsOurTokenOnceAndReRuns() {
        let r = makeRanger()
        ranging(r)
        sent.removeAll()
        let restarted = Data("theirs-new".utf8)
        r.receive(tokenData: restarted, from: peer)
        XCTAssertEqual(sessions[0].runs.map(\.token), [theirs, restarted])
        XCTAssertEqual(sent.count, 1)
        r.receive(tokenData: restarted, from: peer)  // same token again: no reply (no ping-pong)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sessions[0].runs.count, 2)
    }

    func testSuspensionResumesWithRunAndToken() {
        let r = makeRanger()
        ranging(r)
        sent.removeAll()
        sessions[0].onEvent?(.suspended)
        XCTAssertEqual(sessions[0].runs.count, 1, "no run while suspended")
        sessions[0].onEvent?(.suspensionEnded)
        XCTAssertEqual(sessions[0].runs.count, 2)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(r.suspensions, 1)
    }

    func testTimeoutReRunsPeerEndedWaitsForNewToken() {
        let r = makeRanger()
        ranging(r)
        sessions[0].onEvent?(.removed(peerEnded: false))
        XCTAssertEqual(sessions[0].runs.count, 2)
        sent.removeAll()
        sessions[0].onEvent?(.removed(peerEnded: true))
        XCTAssertEqual(sessions[0].runs.count, 2)
        XCTAssertEqual(sent.count, 1, "ours re-sent")
    }

    func testBackgroundDefersRetryAndForegroundRecreatesAtOnce() {
        let r = makeRanger()
        ranging(r)
        r.setActive(false)
        sessions[0].onEvent?(.invalidated(.resourceUsageTimeout))
        advance(to: clock + 60)
        XCTAssertEqual(sessions.count, 1, "no sessions in the background")
        r.setActive(true)
        XCTAssertEqual(sessions.count, 2, "back in the foreground: at once, not after a backoff")
        XCTAssertEqual(sessions[1].runs.count, 1)
    }

    func testForegroundResetsLongBackoff() {
        let r = makeRanger()
        ranging(r)
        for _ in 0..<6 {
            sessions.last!.onEvent?(.invalidated(.sessionFailed))
            advance(to: pending.last!.at)
        }
        sessions.last!.onEvent?(.invalidated(.sessionFailed))  // now a 30 s wait
        r.setActive(false)
        r.setActive(true)
        XCTAssertEqual(sessions.count, 8, "no 30 s wait after foregrounding")
        advance(to: clock + 30)
        XCTAssertEqual(sessions.count, 8, "the stale retry doesn't make a second session")
    }

    func testDeniedStopsRetriesUntilForeground() {
        let r = makeRanger()
        ranging(r)
        sessions[0].onEvent?(.invalidated(.userDidNotAllow))
        advance(to: clock + 120)
        r.setHeard(false, for: peer); r.setHeard(true, for: peer)
        XCTAssertEqual(sessions.count, 1)
        r.setActive(false); r.setActive(true)
        XCTAssertEqual(sessions.count, 2, "tried once more: Settings may have changed")
    }

    func testSessionLimitWaitsAtLeastFiveSecondsThenRetries() {
        let r = makeRanger()
        ranging(r)
        sessions[0].onEvent?(.invalidated(.activeSessionsLimitExceeded))
        XCTAssertEqual(pending.last!.at - clock, 5)
        advance(to: clock + 5)
        XCTAssertEqual(sessions.count, 2)
    }

    func testMorePeersThanSessionsAllowedEachKeepsTrying() {
        let r = makeRanger()
        let many = (0..<10).map { LinkPeer(remote: MCPeerID(displayName: "PEER\($0)"), gen: 1) }
        for p in many { r.linkUp(p); r.setHeard(true, for: p); r.receive(tokenData: theirs, from: p) }
        XCTAssertEqual(sessions.count, 10)
        // iOS refuses the last 4 (its limit is dynamic): they retry, the others keep ranging.
        for s in sessions[6...] { s.onEvent?(.invalidated(.activeSessionsLimitExceeded)) }
        sessions[0].onEvent?(.distance(1))
        advance(to: clock + 5)
        XCTAssertEqual(sessions.count, 14)
        XCTAssertEqual(r.failures[.activeSessionsLimitExceeded], 4)
        XCTAssertFalse(sessions[0].invalidated)
    }

    func testExtendedOnlyWhenBothAndDroppedAfterRejection() {
        let r = makeRanger(extended: true)
        ranging(r)
        XCTAssertEqual(sessions[0].runs.last?.extended, false, "no hello yet: plain")
        r.setExtended(true, for: peer)
        XCTAssertEqual(sessions[0].runs.last?.extended, true)
        sessions[0].onEvent?(.invalidated(.incompatiblePeerDevice))
        advance(to: pending.last!.at)
        XCTAssertEqual(sessions[1].runs.last?.extended, false, "one strike: plain from now on")
    }

    func testU1PhoneNeverAsksForExtended() {
        let r = makeRanger(extended: false)
        ranging(r)
        r.setExtended(true, for: peer)
        XCTAssertTrue(sessions[0].runs.allSatisfy { !$0.extended })
    }

    func testStopAllForgetsEverythingWithoutCallbacks() {
        let r = makeRanger()
        ranging(r)
        r.stopAll()
        r.stopAll()
        XCTAssertTrue(sessions[0].invalidated)
        XCTAssertTrue(stopped.isEmpty)
        sessions[0].onEvent?(.invalidated(.sessionFailed))  // late callback: ignored
        advance(to: clock + 60)
        XCTAssertEqual(sessions.count, 1)
    }

    func testUnsupportedDeviceMakesNoSessions() {
        let r = UWBRanger(supported: false, makeSession: { XCTFail("no session"); return FakeSession(0) })
        r.linkUp(peer)
        r.setHeard(true, for: peer)
        r.receive(tokenData: theirs, from: peer)
    }

    // MARK: Coverage metric

    func testCoverageCountsPeerSecondsWithFreshUWB() {
        var c = UWBCoverage()
        XCTAssertNil(c.percent)
        c.add(dt: 1, eligiblePeers: 1, coveredPeers: 1)
        c.add(dt: 1, eligiblePeers: 1, coveredPeers: 0)
        c.add(dt: 1, eligiblePeers: 2, coveredPeers: 1)
        c.add(dt: 1, eligiblePeers: 0, coveredPeers: 0)  // nobody near: not counted
        c.add(dt: 600, eligiblePeers: 1, coveredPeers: 1)  // a stall counts as 2 s at most
        XCTAssertEqual(c.eligible, 6)
        XCTAssertEqual(c.covered, 4)
        XCTAssertEqual(c.percent!, 100 * 4 / 6, accuracy: 1e-9)
    }

    func testCoverageClassify() {
        XCTAssertTrue(UWBCoverage.classify(bleAge: 1, uwbAge: 2.9, capable: true) == (true, true))
        XCTAssertTrue(UWBCoverage.classify(bleAge: 1, uwbAge: 3.1, capable: nil) == (true, false))
        XCTAssertTrue(UWBCoverage.classify(bleAge: 1, uwbAge: nil, capable: nil) == (true, false),
                      "unlinked peer: a link that never forms counts against UWB")
        XCTAssertTrue(UWBCoverage.classify(bleAge: 1, uwbAge: nil, capable: false) == (false, false), "no UWB chip")
        XCTAssertTrue(UWBCoverage.classify(bleAge: 11, uwbAge: 0, capable: true) == (false, false), "not heard")
        XCTAssertTrue(UWBCoverage.classify(bleAge: nil, uwbAge: 0, capable: true) == (false, false))
    }

    func testHelloUWBFieldOnlyOnHello() {
        XCTAssertTrue(LinkGuard.isValid(Wire(kind: .hello, id: String(repeating: "a", count: 20), uwb: true)))
        XCTAssertFalse(LinkGuard.isValid(Wire(kind: .uwbToken, uwb: true, token: Data([1]))))
        XCTAssertFalse(LinkGuard.isValid(Wire(kind: .gps, uwb: false, lat: 1, lon: 1, acc: 5)))
    }
}
