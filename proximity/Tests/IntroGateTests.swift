import XCTest
@testable import FluniProx

final class IntroGateTests: XCTestCase {
    func testColdLaunchOnScreenPlaysOnce() {
        var g = IntroGate()
        XCTAssertTrue(g.phase(.active))
        XCTAssertFalse(g.phase(.active), "a repeated active must not replay")
    }

    func testLaunchedInBackgroundPlaysOnlyWhenOpened() {
        var g = IntroGate()
        XCTAssertFalse(g.phase(.background), "iOS relaunched it with nobody looking")
        XCTAssertFalse(g.phase(.background))
        XCTAssertFalse(g.phase(.inactive), "opening passes through inactive first")
        XCTAssertTrue(g.phase(.active), "the student opens FlUni: play")
    }

    func testEveryReturnFromBackgroundPlays() {
        var g = IntroGate()
        XCTAssertTrue(g.phase(.active))
        for _ in 0..<3 {
            XCTAssertFalse(g.phase(.inactive))
            XCTAssertFalse(g.phase(.background))
            XCTAssertFalse(g.phase(.inactive))
            XCTAssertTrue(g.phase(.active))
        }
    }

    func testNotificationCentrePullDoesNotReplay() {
        var g = IntroGate()
        XCTAssertTrue(g.phase(.active))
        XCTAssertFalse(g.phase(.inactive))
        XCTAssertFalse(g.phase(.active), "active -> inactive -> active without background is not an open")
    }
}
