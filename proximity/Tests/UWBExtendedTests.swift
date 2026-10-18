import XCTest
@testable import FluniProx

/// Extended-distance UWB is requested only when both hellos, this phone and the peer's token agree, and
/// never again for a pair after NI rejected it (Core/UWBRanger.swift).
final class UWBExtendedTests: XCTestCase {
    func testExtendedOnlyWhenEverySideAgreesAndNotRejected() {
        XCTAssertTrue(UWBRanger.wantsExtended(helloSaysBoth: true, mine: true, tokenSupports: true, rejected: false))
        XCTAssertFalse(UWBRanger.wantsExtended(helloSaysBoth: true, mine: true, tokenSupports: false, rejected: false))
        XCTAssertFalse(UWBRanger.wantsExtended(helloSaysBoth: true, mine: false, tokenSupports: true, rejected: false))
        XCTAssertFalse(UWBRanger.wantsExtended(helloSaysBoth: false, mine: true, tokenSupports: true, rejected: false))
        XCTAssertFalse(UWBRanger.wantsExtended(helloSaysBoth: true, mine: true, tokenSupports: true, rejected: true))
    }
}
