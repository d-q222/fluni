import XCTest
@testable import FluniProx

/// Extended-distance UWB is requested only when both hellos and this phone agree, and
/// never again for a pair after NI rejected it (Core/UWBRanger.swift).
final class UWBExtendedTests: XCTestCase {
    func testExtendedOnlyWhenEverySideAgreesAndNotRejected() {
        XCTAssertTrue(UWBRanger.wantsExtended(helloSaysBoth: true, mine: true, rejected: false))
        XCTAssertFalse(UWBRanger.wantsExtended(helloSaysBoth: true, mine: false, rejected: false))
        XCTAssertFalse(UWBRanger.wantsExtended(helloSaysBoth: false, mine: true, rejected: false))
        XCTAssertFalse(UWBRanger.wantsExtended(helloSaysBoth: true, mine: true, rejected: true))
    }
}
