import CoreLocation
import XCTest
@testable import FluniProx

/// Always location keeps FlUni running off screen; without it nothing changes (flu-offdetect).
final class BackgroundLocationTests: XCTestCase {
    typealias BL = BackgroundLocation
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testAuthMapping() {
        XCTAssertEqual(BL.Auth(.authorizedAlways), .always)
        XCTAssertEqual(BL.Auth(.authorizedWhenInUse), .whenInUse)
        XCTAssertEqual(BL.Auth(.denied), .denied)
        XCTAssertEqual(BL.Auth(.restricted), .denied)
        XCTAssertEqual(BL.Auth(.notDetermined), .notDetermined)
    }

    func testModeForEveryCombination() {
        let auths: [BL.Auth] = [.notDetermined, .denied, .whenInUse, .always]
        for a in auths {
            for paused in [false, true] {
                for active in [false, true] {
                    for can in [false, true] {
                        let m = BL.mode(auth: a, paused: paused, active: active, canKeepAlive: can)
                        let want: BL.Mode = paused || a == .denied ? .off
                            : (a == .always && !active && can ? .keepAlive : .foreground)
                        XCTAssertEqual(m, want, "\(a) paused=\(paused) active=\(active) canKeepAlive=\(can)")
                    }
                }
            }
        }
        // The cases that matter, spelled out.
        XCTAssertEqual(BL.mode(auth: .always, paused: false, active: false, canKeepAlive: true), .keepAlive)
        XCTAssertEqual(BL.mode(auth: .always, paused: true, active: false, canKeepAlive: true), .off, "Pause stops it")
        XCTAssertEqual(BL.mode(auth: .whenInUse, paused: false, active: false, canKeepAlive: true), .foreground,
                       "no Always: exactly as before (iOS stops delivering in the background)")
        XCTAssertEqual(BL.mode(auth: .always, paused: false, active: false, canKeepAlive: false), .foreground, "harness")
    }

    func testWithoutAlwaysSettingsAreTheOldOnes() {
        for a in [BL.Auth.notDetermined, .whenInUse] {
            XCTAssertEqual(BL.settings(.foreground, auth: a, relaxed: false, canKeepAlive: true),
                           .init(accuracy: kCLLocationAccuracyBest, distanceFilter: kCLDistanceFilterNone,
                                 allowsBackground: false, showsIndicator: false))
            XCTAssertEqual(BL.settings(.foreground, auth: a, relaxed: true, canKeepAlive: true),
                           .init(accuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 5,
                                 allowsBackground: false, showsIndicator: false))
        }
        XCTAssertNil(BL.settings(.off, auth: .always, relaxed: false, canKeepAlive: true))
    }

    func testWithAlwaysForegroundAllowsBackgroundAndShowsIndicator() {
        XCTAssertEqual(BL.settings(.foreground, auth: .always, relaxed: false, canKeepAlive: true),
                       .init(accuracy: kCLLocationAccuracyBest, distanceFilter: kCLDistanceFilterNone,
                             allowsBackground: true, showsIndicator: true))
        XCTAssertEqual(BL.settings(.foreground, auth: .always, relaxed: false, canKeepAlive: false)?.allowsBackground, false,
                       "never without the location background mode")
    }

    func testKeepAliveIsCoarseAndHonest() {
        let s = BL.settings(.keepAlive, auth: .always, relaxed: true, canKeepAlive: true)!
        XCTAssertEqual(s.accuracy, kCLLocationAccuracyThreeKilometers)
        XCTAssertEqual(s.distanceFilter, 500)
        XCTAssertTrue(s.allowsBackground)
        XCTAssertTrue(s.showsIndicator, "the blue indicator says location is in use")
        XCTAssertEqual(BL.keepAliveAccuracy, kCLLocationAccuracyThreeKilometers)
        XCTAssertEqual(BL.keepAliveDistanceFilter, 500)
        XCTAssertEqual(BL.maxOffScreenFixAccuracy, 100)
        XCTAssertEqual(BL.rescanInterval, 10)
    }

    func testCoarseFixesNeverReachWalkInWhileKeptAlive() {
        XCTAssertTrue(BL.usesFix(.keepAlive, horizontalAccuracy: 100))
        XCTAssertFalse(BL.usesFix(.keepAlive, horizontalAccuracy: 100.01))
        XCTAssertFalse(BL.usesFix(.keepAlive, horizontalAccuracy: 3000))
        XCTAssertTrue(BL.usesFix(.foreground, horizontalAccuracy: 3000), "open: unchanged (approximate location still shows)")
        XCTAssertTrue(BL.usesFix(.foreground, horizontalAccuracy: 0))
        for m in [BL.Mode.foreground, .keepAlive] {
            XCTAssertFalse(BL.usesFix(m, horizontalAccuracy: -1), "CoreLocation's invalid")
            XCTAssertFalse(BL.usesFix(m, horizontalAccuracy: .nan))
            XCTAssertFalse(BL.usesFix(m, horizontalAccuracy: .infinity))
        }
        XCTAssertFalse(BL.usesFix(.off, horizontalAccuracy: 5), "paused")
    }

    func testRescanCadence() {
        XCTAssertTrue(BL.shouldRescan(.keepAlive, last: nil, now: t0))
        XCTAssertFalse(BL.shouldRescan(.keepAlive, last: t0, now: t0.addingTimeInterval(9.999)))
        XCTAssertTrue(BL.shouldRescan(.keepAlive, last: t0, now: t0.addingTimeInterval(10)))
        XCTAssertTrue(BL.shouldRescan(.keepAlive, last: t0, now: t0.addingTimeInterval(-1)), "backwards clock")
        XCTAssertFalse(BL.shouldRescan(.foreground, last: nil, now: t0), "open: scans already run freely")
        XCTAssertFalse(BL.shouldRescan(.off, last: nil, now: t0))
    }

    func testWhenToOfferAlways() {
        XCTAssertTrue(BL.offersAlways(auth: .whenInUse, onboarded: true, dismissed: false))
        XCTAssertFalse(BL.offersAlways(auth: .whenInUse, onboarded: false, dismissed: false), "not during onboarding")
        XCTAssertFalse(BL.offersAlways(auth: .whenInUse, onboarded: true, dismissed: true), "Not now is respected")
        XCTAssertFalse(BL.offersAlways(auth: .always, onboarded: true, dismissed: false), "already granted")
        XCTAssertFalse(BL.offersAlways(auth: .denied, onboarded: true, dismissed: false), "denied: Settings explains, no nagging")
        XCTAssertFalse(BL.offersAlways(auth: .notDetermined, onboarded: true, dismissed: false), "When In Use comes first")
    }
}
