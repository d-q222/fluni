import XCTest
@testable import FluniProx

final class ExposureTests: XCTestCase {
    /// Simulates `seconds` of real time, one tick per second, at a demo speed-up.
    private func run(_ t: inout ExposureTracker, seconds: Int, speed: Double, pClose: Double, risk: Risk) {
        for _ in 0..<seconds { t.advance(simSeconds: speed, contacts: [(pClose, risk)]) }
    }

    func testFifteenMinutesTogetherWithContagiousPhoneAlerts() {
        var t = ExposureTracker()
        run(&t, seconds: 14 * 60, speed: 1, pClose: 1, risk: .contagious)
        XCTAssertEqual(t.level, .nearby)
        run(&t, seconds: 60, speed: 1, pClose: 1, risk: .contagious)
        XCTAssertEqual(t.level, .closeContact)
    }

    func testDemoSpeedUpReachesAlertIn15RealSeconds() {
        var t = ExposureTracker()
        run(&t, seconds: 15, speed: 60, pClose: 1, risk: .contagious)
        XCTAssertEqual(t.level, .closeContact)
    }

    func testHealthyPeerNeverAlerts() {
        var t = ExposureTracker()
        run(&t, seconds: 60, speed: 60, pClose: 1, risk: .none)
        XCTAssertEqual(t.level, .none)
        XCTAssertEqual(t.minutes, 0)
    }

    func testFarAwayContagiousPeerDoesNotAlert() {
        var t = ExposureTracker()
        run(&t, seconds: 60, speed: 60, pClose: 0.001, risk: .contagious)
        XCTAssertEqual(t.level, .none)
    }

    func testPossiblySickCountsHalf() {
        var t = ExposureTracker()
        run(&t, seconds: 15, speed: 60, pClose: 1, risk: .possible)
        XCTAssertEqual(t.minutes, 7.5, accuracy: 1e-9)
        XCTAssertEqual(t.level, .nearby)
    }

    // The episode rule: minutes keep adding and reset to exactly 0 only after 2 h with nobody possibly sick in range.
    func testMinutesAccumulateAcrossAShortGap() {
        var t = ExposureTracker()
        run(&t, seconds: 10, speed: 60, pClose: 1, risk: .contagious)     // 10 min
        t.advance(simSeconds: 119 * 60, contacts: [])                       // 1 h 59 min away: bridged
        XCTAssertEqual(t.minutes, 10, accuracy: 1e-9, "a gap under 2 h neither grows nor decays the total")
        run(&t, seconds: 5, speed: 60, pClose: 1, risk: .contagious)      // 5 more: same episode
        XCTAssertEqual(t.minutes, 15, accuracy: 1e-9)
        XCTAssertEqual(t.level, .closeContact)
    }

    func testMinutesResetAfterTwoHoursAway() {
        var t = ExposureTracker()
        run(&t, seconds: 15, speed: 60, pClose: 1, risk: .contagious)
        XCTAssertEqual(t.level, .closeContact)
        t.advance(simSeconds: 3 * 3600, contacts: [])
        XCTAssertEqual(t.minutes, 0)
        XCTAssertEqual(t.level, .none)
        run(&t, seconds: 5, speed: 60, pClose: 1, risk: .contagious)      // a fresh episode starts from 0
        XCTAssertEqual(t.minutes, 5, accuracy: 1e-9)
    }

    func testResetBoundaryIsExactlyTwoHours() {
        var t = ExposureTracker()
        t.advance(simSeconds: 600, contacts: [(1, .contagious)])           // contact ends at clock 600
        t.advance(simSeconds: 7_199, contacts: [])                          // 1 s short of 2 h
        XCTAssertEqual(t.minutes, 10, accuracy: 1e-9)
        t.advance(simSeconds: 1, contacts: [])                              // exactly 2 h since the end
        XCTAssertEqual(t.minutes, 0)
        XCTAssertEqual(t.lastContact, nil)
    }

    func testHealthyPeersDoNotKeepTheEpisodeAlive() {
        var t = ExposureTracker()
        t.advance(simSeconds: 600, contacts: [(1, .contagious)])
        for _ in 0..<130 { t.advance(simSeconds: 60, contacts: [(1, .none)]) }   // 2 h 10 min beside a healthy peer
        XCTAssertEqual(t.minutes, 0)
    }

    func testFarAwaySickPeerDoesNotKeepTheEpisodeAlive() {
        var t = ExposureTracker()
        t.advance(simSeconds: 600, contacts: [(1, .contagious)])
        for _ in 0..<130 { t.advance(simSeconds: 60, contacts: [(0.1, .contagious)]) }  // probably beyond 6 ft
        // Reset at 2 h after the real contact, then only the small p share of the remaining 11 ticks.
        XCTAssertEqual(t.minutes, 1.1, accuracy: 1e-9)
        XCTAssertEqual(t.level, .none)
    }

    func testContactInsideTheGapKeepsTheEpisode() {
        var t = ExposureTracker()
        t.advance(simSeconds: 60, contacts: [(1, .contagious)])
        for _ in 0..<5 {                                                    // 1 h 50 min away, then 1 min of contact, x5
            t.advance(simSeconds: 110 * 60, contacts: [])
            t.advance(simSeconds: 60, contacts: [(1, .contagious)])
        }
        XCTAssertEqual(t.minutes, 6, accuracy: 1e-9, "each contact is within 2 h of the last, so one episode")
    }

    func testOnlyTheStrongestPeerCountsAtOnce() {
        var t = ExposureTracker()
        t.advance(simSeconds: 600, contacts: [(1, .contagious), (1, .possible), (1, .contagious)])
        XCTAssertEqual(t.minutes, 10, accuracy: 1e-9)
    }

    func testCopiesOfOnePeerStillAdd() {   // AccrualFeed gives a long credit as several copies of one ID
        var t = ExposureTracker()
        let d = DosePeer(id: "a", distance: 0.5)
        t.advance(simSeconds: 60, contacts: [(1, .contagious), (1, .contagious)], doses: [d, d])
        XCTAssertEqual(t.minutes, 2, accuracy: 1e-9)
    }

    func testDurationText() {
        XCTAssertEqual(ExposureTracker.durationText(0), "0 min")
        XCTAssertEqual(ExposureTracker.durationText(59.9), "59 min")
        XCTAssertEqual(ExposureTracker.durationText(60), "1 h 0 min")
        XCTAssertEqual(ExposureTracker.durationText(135), "2 h 15 min")
    }

    func testCloseContactPersistsAfterWalkingAway() {
        var t = ExposureTracker()
        run(&t, seconds: 15, speed: 60, pClose: 1, risk: .contagious)
        t.advance(simSeconds: 60, contacts: [])
        XCTAssertEqual(t.level, .closeContact)
        t.reset()
        XCTAssertEqual(t.level, .none)
    }

    /// The model republishes only when `showsSame` is false: an idle tick moves the clock (so `==` differs)
    /// but nothing a view shows; any dose, minute or level change must count as a visible change.
    func testShowsSameIgnoresOnlyTheClock() {
        var t = ExposureTracker()
        let before = t
        t.advance(simSeconds: 1, contacts: [])
        XCTAssertNotEqual(t, before)
        XCTAssertTrue(t.showsSame(as: before))
        let idle = t
        t.advance(simSeconds: 1, contacts: [(1, .contagious)], doses: [DosePeer(id: "A", distance: 0.5)])
        XCTAssertFalse(t.showsSame(as: idle), "minutes, dose and p moved")
        let near = t
        t.advance(simSeconds: 0, contacts: [])
        XCTAssertNotEqual(t.level, near.level)
        XCTAssertFalse(t.showsSame(as: near), "the heads-up level cleared")
    }
}
