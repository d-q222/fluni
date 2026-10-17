import XCTest
@testable import FluniProx

final class ContactGuardTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func peer(_ id: String, risk: Risk = .contagious, p: Double = 1, rssi: Double? = -55,
                      sources: [Source] = [.ble], uwbAt: Date? = nil) -> ContactGuard.Input {
        .init(id: id, risk: risk, pClose: p, tier: p, rssi: rssi, sources: sources, uwbAt: uwbAt)
    }

    /// Runs one tick per real second at `speed`, feeding the guard output to the tracker.
    private func run(_ g: inout ContactGuard, _ t: inout ExposureTracker, seconds: Int, speed: Double,
                     start: Double = 0, peers: (Int) -> [ContactGuard.Input]) {
        for s in 0..<seconds {
            let out = g.apply(now: t0.addingTimeInterval(start + Double(s)), peers(s))
            t.advance(simSeconds: speed, contacts: out.map { ($0.pClose, $0.risk) }, tiers: out.map(\.tier))
        }
    }

    func testFifteenSpoofedIDsForOneRealMinuteAddNothing() {
        var g = ContactGuard(), t = ExposureTracker()
        run(&g, &t, seconds: 60, speed: 60) { _ in (0..<15).map { peer("spoof\($0)") } }
        XCTAssertEqual(t.minutes, 0, accuracy: 1e-9)
        XCTAssertEqual(t.level, .none)
        XCTAssertTrue(g.flagged)
    }

    func testFourSpoofedIDsAreCappedAtTwoContactsPerTick() {
        var g = ContactGuard(), t = ExposureTracker()
        run(&g, &t, seconds: 60, speed: 1) { _ in (0..<4).map { peer("spoof\($0)") } }
        XCTAssertEqual(t.minutes, 2.0, accuracy: 1e-9)  // 2 contacts x 1 sim-minute, not 4
        XCTAssertFalse(g.flagged)
    }

    func testRealContagiousPeerStillReachesCloseContactAsBefore() {
        var g = ContactGuard(), t = ExposureTracker()
        run(&g, &t, seconds: 15 * 60, speed: 1) { _ in [peer("real")] }
        XCTAssertEqual(t.minutes, 15.0, accuracy: 1e-6)
        XCTAssertEqual(t.level, .closeContact)
        XCTAssertFalse(g.flagged)
    }

    func testNormalRotationNeverTripsBurst() {
        var g = ContactGuard(), t = ExposureTracker()
        for k in 0..<8 {  // a new ID every 15 min for 2 h
            run(&g, &t, seconds: 15 * 60, speed: 1, start: Double(k * 900)) { _ in [peer("id\(k)")] }
            XCTAssertFalse(g.flagged)
        }
    }

    func testBurstTripsLogsAndClearsAtWindowBoundary() {
        var g = ContactGuard()
        var logs: [String] = []
        _ = g.apply(now: t0, (0..<5).map { peer("b\($0)") }, log: { logs.append($0) })
        XCTAssertTrue(g.flagged)
        XCTAssertEqual(logs, ["guard burst ids=5"])
        let still = [peer("b0")]
        _ = g.apply(now: t0.addingTimeInterval(299), still)
        XCTAssertTrue(g.flagged)
        let out = g.apply(now: t0.addingTimeInterval(300), still)
        XCTAssertFalse(g.flagged)
        XCTAssertEqual(out[0].pClose, 1)
    }

    func testFlaggedBurstSuppressesBluetoothOnlyButNotUWB() {
        var g = ContactGuard()
        let ps = (0..<5).map { peer("b\($0)") } + [peer("uwb", sources: [.uwb, .ble], uwbAt: t0)]
        let out = g.apply(now: t0, ps)
        XCTAssertEqual(out.dropLast().map(\.pClose), [0, 0, 0, 0, 0])
        XCTAssertEqual(out.last?.pClose, 1)
        XCTAssertEqual(out.last?.corroborated, true)
        XCTAssertEqual(out.first?.corroborated, false)
    }

    func testStaleUWBIsNotCorroborated() {
        var g = ContactGuard()
        let out = g.apply(now: t0, [peer("a", sources: [.uwb], uwbAt: t0.addingTimeInterval(-10))])
        XCTAssertFalse(out[0].corroborated)
    }

    func testRSSIMinus25IsIgnoredAndMinus45Counts() {
        var g = ContactGuard()
        XCTAssertEqual(g.apply(now: t0, [peer("a", rssi: -25)])[0].pClose, 0)
        XCTAssertEqual(g.apply(now: t0.addingTimeInterval(10), [peer("b", rssi: -45)])[0].pClose, 1)
    }

    func testPlus25dBJumpWithinTwoSecondsIsIgnoredForThatTickOnly() {
        var g = ContactGuard()
        XCTAssertEqual(g.apply(now: t0, [peer("a", rssi: -75)])[0].pClose, 1)
        XCTAssertEqual(g.apply(now: t0.addingTimeInterval(1), [peer("a", rssi: -50)])[0].pClose, 0)
        XCTAssertEqual(g.apply(now: t0.addingTimeInterval(2), [peer("a", rssi: -50)])[0].pClose, 1)
    }

    func testSlowRiseOrSmallJumpCounts() {
        var g = ContactGuard()
        _ = g.apply(now: t0, [peer("a", rssi: -70)])
        XCTAssertEqual(g.apply(now: t0.addingTimeInterval(1), [peer("a", rssi: -52)])[0].pClose, 1)  // 18 dB
        XCTAssertEqual(g.apply(now: t0.addingTimeInterval(10), [peer("a", rssi: -20 - 40)])[0].pClose, 1)  // > 2 s apart
    }

    func testRiskFlappingIsIgnoredAndLoggedOnce() {
        var g = ContactGuard()
        var logs: [String] = []
        let log = { (s: String) in logs.append(s) }
        XCTAssertEqual(g.apply(now: t0, [peer("flip", risk: .none)], log: log)[0].pClose, 1)
        XCTAssertEqual(g.apply(now: t0.addingTimeInterval(10), [peer("flip", risk: .contagious)], log: log)[0].pClose, 1)  // 1 change
        XCTAssertEqual(g.apply(now: t0.addingTimeInterval(20), [peer("flip", risk: .none)], log: log)[0].pClose, 0)  // 2nd change
        XCTAssertEqual(g.apply(now: t0.addingTimeInterval(30), [peer("flip", risk: .contagious)], log: log)[0].pClose, 0)
        _ = g.apply(now: t0.addingTimeInterval(31), [peer("flip", risk: .contagious)], log: log)
        XCTAssertEqual(logs, ["guard risk flip id=flip ignored"])
        // 15 min after the first changes the ID is trusted again.
        XCTAssertEqual(g.apply(now: t0.addingTimeInterval(1000), [peer("flip", risk: .contagious)], log: log)[0].pClose, 1)
    }

    func testSingleRiskChangeIsTrusted() {
        var g = ContactGuard()
        _ = g.apply(now: t0, [peer("a", risk: .none)])
        XCTAssertEqual(g.apply(now: t0.addingTimeInterval(5), [peer("a", risk: .contagious)])[0].pClose, 1)
    }

    func testClockGoingBackwardsDoesNotRewindOrCrash() {
        var g = ContactGuard()
        _ = g.apply(now: t0, (0..<5).map { peer("b\($0)") })
        XCTAssertTrue(g.flagged)
        _ = g.apply(now: t0.addingTimeInterval(-1000), [peer("b0")])
        XCTAssertTrue(g.flagged)
        _ = g.apply(now: t0.addingTimeInterval(300), [peer("b0")])
        XCTAssertFalse(g.flagged)
    }

    func testNaNAndEmptyInput() {
        var g = ContactGuard()
        XCTAssertEqual(g.apply(now: t0, []), [])
        let out = g.apply(now: t0.addingTimeInterval(1), [
            ContactGuard.Input(id: "n", risk: .contagious, pClose: .nan, tier: .infinity, rssi: .nan),
            peer("ok", rssi: .nan),
        ])
        XCTAssertEqual(out.map(\.pClose), [0, 1])
        XCTAssertEqual(out.map(\.tier), [0, 1])
    }

    func testHealthyPeersAreNeverCountedButKeptInOutput() {
        var g = ContactGuard()
        let out = g.apply(now: t0, [peer("h", risk: .none), peer("a"), peer("b"), peer("c", risk: .possible)])
        XCTAssertEqual(out.map(\.pClose), [1, 1, 1, 0])  // none is left alone; possible ranks third and is capped
    }
}
