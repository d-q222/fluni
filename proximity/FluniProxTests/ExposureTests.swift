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

    func testCloseContactPersistsAfterWalkingAway() {
        var t = ExposureTracker()
        run(&t, seconds: 15, speed: 60, pClose: 1, risk: .contagious)
        t.advance(simSeconds: 60, contacts: [])
        XCTAssertEqual(t.level, .closeContact)
        t.reset()
        XCTAssertEqual(t.level, .none)
    }
}
