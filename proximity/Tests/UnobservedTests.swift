import Combine
import XCTest
@testable import FluniProx

/// @Unobserved (ProximityModel.lastFix): Combine subscribers hear every value, views watching the object don't.
final class UnobservedTests: XCTestCase {
    private final class Box: ObservableObject {
        @Unobserved var fix: Int? = nil
        @Published var shown = 0
    }

    func testSubscribersGetEveryValueButObjectWillChangeStaysQuiet() {
        let box = Box()
        var seen: [Int?] = []
        var willChange = 0
        let a = box.$fix.sink { seen.append($0) }
        let b = box.objectWillChange.sink { willChange += 1 }
        box.fix = 1
        box.fix = 2
        XCTAssertEqual(seen, [nil, 1, 2], "current value on subscribe, then every set, like @Published")
        XCTAssertEqual(box.fix, 2)
        XCTAssertEqual(willChange, 0)
        box.shown = 1
        XCTAssertEqual(willChange, 1, "other @Published properties still announce")
        _ = (a, b)
    }
}
