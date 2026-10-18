import XCTest
@testable import FluniProx

/// The crash-fix rules for MPC browsers (Core/BrowserLedger.swift): a browser that may still be browsing is
/// never released; one MPC stopped in the background is released only after the grace period, and only
/// while the app is still in the background.
final class BrowserLedgerTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 5_000_000)

    func testNeverStartedBrowserIsReleasedAtOnce() {
        var l = BrowserLedger()
        l.add(1)
        XCTAssertTrue(l.park(1))
        XCTAssertEqual(l.parkedCount, 0)
    }

    func testBrowsingBrowserIsNeverReleasedInTheForeground() {
        var l = BrowserLedger()
        l.add(1); l.started(1)
        XCTAssertFalse(l.park(1))
        XCTAssertEqual(l.releasable(at: t0.addingTimeInterval(3600)), [])
        XCTAssertEqual(l.parkedCount, 1)
    }

    func testReleasedOnlyAfterGraceInTheBackground() {
        var l = BrowserLedger()
        l.add(1); l.started(1)
        _ = l.park(1)
        l.enteredBackground(at: t0)
        XCTAssertEqual(l.releasable(at: t0.addingTimeInterval(BrowserLedger.grace - 0.1)), [])
        XCTAssertEqual(l.releasable(at: t0.addingTimeInterval(BrowserLedger.grace)), [1])
        XCTAssertEqual(l.parkedCount, 0)
        XCTAssertEqual(l.releasable(at: t0.addingTimeInterval(100)), [], "released once only")
    }

    func testReturnToForegroundBeforeGraceKeepsItParked() {
        var l = BrowserLedger()
        l.add(1); l.started(1)
        _ = l.park(1)
        l.enteredBackground(at: t0)
        l.willEnterForeground()  // MPC restarts it: browsing again
        XCTAssertEqual(l.releasable(at: t0.addingTimeInterval(60)), [])
        l.enteredBackground(at: t0.addingTimeInterval(100))
        XCTAssertEqual(l.releasable(at: t0.addingTimeInterval(100 + BrowserLedger.grace - 0.1)), [])
        XCTAssertEqual(l.releasable(at: t0.addingTimeInterval(100 + BrowserLedger.grace)), [1])
    }

    func testCurrentBrowserParkedInTheBackgroundUsesTheBackgroundTime() {
        var l = BrowserLedger()
        l.add(1); l.started(1)
        l.enteredBackground(at: t0)          // still current: MPC stops it
        _ = l.park(1)                        // rotation in the background, 30 s later
        XCTAssertEqual(l.releasable(at: t0.addingTimeInterval(30)), [1])
    }

    func testNoBrowserStartsInTheBackground() {
        var l = BrowserLedger(inBackground: true)
        XCTAssertFalse(l.canStartBrowser)
        l.add(1); l.started(1)               // ignored: stays idle
        XCTAssertTrue(l.park(1), "a browser that never browsed is released at once")
        l.willEnterForeground()
        XCTAssertTrue(l.canStartBrowser)
    }

    func testCapStopsNewBrowsersUntilTheBackgroundFreesRoom() {
        var l = BrowserLedger()
        for b in 0 ..< BrowserLedger.cap { l.add(b); l.started(b); _ = l.park(b) }
        XCTAssertFalse(l.canStartBrowser)
        l.enteredBackground(at: t0)
        XCTAssertEqual(l.releasable(at: t0.addingTimeInterval(BrowserLedger.grace)).count, BrowserLedger.cap)
        l.willEnterForeground()
        XCTAssertTrue(l.canStartBrowser)
    }

    func testUnknownBrowserIsIgnored() {
        var l = BrowserLedger()
        XCTAssertFalse(l.park(42))
        XCTAssertEqual(l.parkedCount, 0)
    }
}
