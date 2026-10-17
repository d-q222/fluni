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

    func testMinutesExpireAfterRolling24Hours() {
        var t = ExposureTracker()
        run(&t, seconds: 15, speed: 60, pClose: 1, risk: .contagious)     // 15 min close contact
        XCTAssertEqual(t.level, .closeContact)
        t.advance(simSeconds: 23 * 3600, contacts: [])                      // 23 h later: still counts
        XCTAssertEqual(t.minutes, 15, accuracy: 1e-9)
        XCTAssertEqual(t.level, .closeContact)
        t.advance(simSeconds: 3600, contacts: [])                           // past 24 h: gone
        XCTAssertEqual(t.minutes, 0)
        XCTAssertEqual(t.level, .none)
    }

    func testOnlyTheOldPartExpires() {
        var t = ExposureTracker()
        run(&t, seconds: 10, speed: 60, pClose: 1, risk: .contagious)     // 10 min at t ≈ 0
        t.advance(simSeconds: 20 * 3600, contacts: [])
        run(&t, seconds: 10, speed: 60, pClose: 1, risk: .contagious)     // 10 more at t ≈ 20 h
        XCTAssertEqual(t.minutes, 20, accuracy: 1e-6)
        XCTAssertEqual(t.level, .closeContact)
        t.advance(simSeconds: 4 * 3600 + 120, contacts: [])                 // first 10 fall out of the window
        XCTAssertEqual(t.minutes, 10, accuracy: 1e-6)
        XCTAssertEqual(t.level, .none, "below 15 in the last 24 h, so the close-contact alert clears")
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
