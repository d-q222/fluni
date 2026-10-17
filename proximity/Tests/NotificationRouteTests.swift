import XCTest
@testable import FluniProx

final class NotificationRouteTests: XCTestCase {
    private func r(_ info: [AnyHashable: Any], _ a: String) -> Route { NotificationRoute.route(userInfo: info, actionIdentifier: a) }
    private let cc: [AnyHashable: Any] = ["kind": "close_contact"]
    private let nb: [AnyHashable: Any] = ["kind": "nearby"]
    private let bw: [AnyHashable: Any] = ["kind": "building", "building_id": "jerry"]

    func testDefaultTapPerKind() {
        XCTAssertEqual(r(cc, NotificationAction.defaultTap), .closeContact)
        XCTAssertEqual(r(nb, NotificationAction.defaultTap), .openToday)
        XCTAssertEqual(r(bw, NotificationAction.defaultTap), .mapFocus("jerry"))
    }

    func testQuickActions() {
        XCTAssertEqual(r(cc, NotificationAction.reportSymptoms), .reportSymptoms)
        XCTAssertEqual(r(cc, NotificationAction.seeAdvice), .closeContact)
        XCTAssertEqual(r(nb, NotificationAction.gotIt), .ignore)
        XCTAssertEqual(r(bw, NotificationAction.showOnMap), .mapFocus("jerry"))
    }

    func testDismissIsIgnoredForEveryKind() {
        for info in [cc, nb, bw, [:]] { XCTAssertEqual(r(info, NotificationAction.dismiss), .ignore) }
    }

    func testUnknownOrMissingKind() {
        XCTAssertEqual(r(["kind": "lottery"], NotificationAction.defaultTap), .openToday)
        XCTAssertEqual(r([:], NotificationAction.defaultTap), .openToday)
        XCTAssertEqual(r(["kind": 7], NotificationAction.defaultTap), .openToday)
        XCTAssertEqual(r(["kind": "lottery"], NotificationAction.reportSymptoms), .ignore)
        XCTAssertEqual(r([:], NotificationAction.showOnMap), .ignore)
    }

    func testMissingOrBadBuildingID() {
        XCTAssertEqual(r(["kind": "building"], NotificationAction.defaultTap), .openToday)
        XCTAssertEqual(r(["kind": "building"], NotificationAction.showOnMap), .openToday)
        XCTAssertEqual(r(["kind": "building", "building_id": ""], NotificationAction.showOnMap), .openToday)
        XCTAssertEqual(r(["kind": "building", "building_id": "  "], NotificationAction.defaultTap), .openToday)
        XCTAssertEqual(r(["kind": "building", "building_id": 5], NotificationAction.defaultTap), .openToday)
        XCTAssertEqual(r(["kind": "building", "building_id": String(repeating: "x", count: 65)], NotificationAction.defaultTap), .openToday)
    }

    func testActionForTheWrongCategoryIsIgnored() {
        XCTAssertEqual(r(nb, NotificationAction.reportSymptoms), .ignore)
        XCTAssertEqual(r(bw, NotificationAction.seeAdvice), .ignore)
        XCTAssertEqual(r(cc, NotificationAction.showOnMap), .ignore)
        XCTAssertEqual(r(cc, NotificationAction.gotIt), .ignore)
        XCTAssertEqual(r(bw, NotificationAction.reportSymptoms), .ignore)
        XCTAssertEqual(r(cc, "fluni.action.nonsense"), .ignore)
        XCTAssertEqual(r(cc, ""), .ignore)
    }

    func testTextIsNeutralInTitleAndBodyWhenDetailsOff() {
        for k in NotificationKind.allCases {
            for detailed in [true, false] {
                let t = NotificationRoute.text(kind: k, detailed: detailed, buildingName: "Jerry")
                XCTAssertEqual(t.title, "FlUni")
            }
            let hidden = NotificationRoute.text(kind: k, detailed: false, buildingName: "Jerry")
            XCTAssertFalse(hidden.body.lowercased().contains("sick"))
            XCTAssertFalse(hidden.body.contains("Jerry"))
        }
    }

    func testCategoryIDsAreDistinct() {
        XCTAssertEqual(Set(NotificationKind.allCases.map(\.categoryID)).count, NotificationKind.allCases.count)
    }
}
