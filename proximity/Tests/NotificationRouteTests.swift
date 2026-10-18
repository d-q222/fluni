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

    func testCloseContactBodyIsTheAdviceCutWithTapForMore() {
        let body = NotificationRoute.text(kind: .closeContact, detailed: true).body
        XCTAssertEqual(body, "You've spent about 15 minutes within 6 ft of someone who may be sick. "
                       + "Leave the room now, or move well away and put on a mask. Tap for more details.")
        XCTAssertLessThanOrEqual(body.count, NotificationRoute.bodyBudget)
        XCTAssertFalse(body.contains("Tap to see what to do"))
    }

    func testShortAdviceIsSentWholeWithoutTapForMore() {
        let nearby = NotificationRoute.text(kind: .nearby, detailed: true).body
        XCTAssertEqual(nearby, "Someone within 6 ft may be sick. Put 6 ft or more between you, or step outside. "
                       + "Consider wearing a mask while you're here.")
        let building = NotificationRoute.text(kind: .building, detailed: true, buildingName: "Jerry").body
        XCTAssertEqual(building, "Jerry has a lot of illness right now. Consider a mask, or a different spot.")
    }

    func testFitKeepsWholeSentencesInOrderAndMarksTheCut() {
        let more = NotificationRoute.more, n = NotificationRoute.bodyBudget
        XCTAssertEqual(NotificationRoute.fit([]), "")
        let exact = String(repeating: "a", count: n - 1) + "."
        XCTAssertEqual(NotificationRoute.fit([exact]), exact, "exactly the budget: sent whole")
        let a = String(repeating: "a", count: 100) + ".", b = String(repeating: "b", count: 100) + "."
        XCTAssertEqual(NotificationRoute.fit([a, b]), a + " " + more)
        let huge = String(repeating: "h", count: 400) + "."
        XCTAssertEqual(NotificationRoute.fit([huge, "x."]), huge + " " + more, "the first sentence is never dropped")
        let s1 = String(repeating: "c", count: 60) + ".", s2 = String(repeating: "d", count: 60) + "."
        let s3 = String(repeating: "e", count: 60) + "."
        // s1 + s2 + more = 61+1+61+1+21 = 145 fits; adding s3 would not.
        XCTAssertEqual(NotificationRoute.fit([s1, s2, s3]), [s1, s2, more].joined(separator: " "))
    }

    func testCategoryIDsAreDistinct() {
        XCTAssertEqual(Set(NotificationKind.allCases.map(\.categoryID)).count, NotificationKind.allCases.count)
    }
}
