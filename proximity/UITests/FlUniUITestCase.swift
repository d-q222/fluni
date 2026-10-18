import XCTest

/// Base class: launches FlUni fresh (UserDefaults and Application Support cleared) with the radios off,
/// via the test-only environment variables read in FlUni/FlUniApp.swift.
///
/// Screens are found by accessibility identifier, not navigation-bar titles: Today and You draw their own
/// headers (the wordmark, "You"), and Campus is the bundled web map with no bar.
class FlUniUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["FLUNI_UITEST_RESET"] = "1"
        app.launchEnvironment["FLUNI_UITEST_NO_RADIOS"] = "1"
    }

    // MARK: Flows

    /// Walks the three onboarding pages and lands on Today.
    func completeOnboarding(file: StaticString = #filePath, line: UInt = #line) {
        let next = app.buttons["onboarding.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 15), "onboarding should show on a fresh launch", file: file, line: line)
        next.tap()
        XCTAssertTrue(app.staticTexts["Private by design"].waitForExistence(timeout: 5), file: file, line: line)
        next.tap()
        let turnOn = app.buttons["onboarding.turnOn"]
        XCTAssertTrue(turnOn.waitForExistence(timeout: 5), file: file, line: line)
        turnOn.tap()
        XCTAssertTrue(el("today.now").waitForExistence(timeout: 10), "should land on Today", file: file, line: line)
    }

    func launchPastOnboarding() {
        app.launch()
        completeOnboarding()
    }

    func tab(_ name: String) -> XCUIElement { app.tabBars.buttons[name] }

    /// The element each tab shows once it's open.
    func marker(_ tabName: String) -> XCUIElement {
        switch tabName {
        // Today is the day timeline, or the stay-home track while sick.
        case "Today": return app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ["today.now", "today.athome"])).firstMatch
        case "Campus": return app.webViews.firstMatch
        default: return el("you.title")
        }
    }

    func openTab(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let t = tab(name)
        XCTAssertTrue(t.waitForExistence(timeout: 10), "\(name) tab", file: file, line: line)
        t.tap()
        XCTAssertTrue(t.isSelected, "\(name) selected", file: file, line: line)
        XCTAssertTrue(marker(name).waitForExistence(timeout: 10), "\(name) screen", file: file, line: line)
    }

    /// Any element type, by accessibility identifier (SwiftUI combined elements vary in type).
    func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// Swipes up until the element exists and can be tapped (lists only build rows near the screen).
    @discardableResult
    func scrollTo(_ e: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        var n = 0
        while !(e.exists && e.isHittable) && n < 12 {
            if n == 0 && e.waitForExistence(timeout: 3) && e.isHittable { break }
            app.swipeUp(); n += 1
        }
        XCTAssertTrue(e.exists, "\(e) should exist", file: file, line: line)
        return e
    }

    /// Button inside a confirmation dialog (an action sheet on iPhone), not the same-named button behind it.
    func dialogButton(_ label: String) -> XCUIElement {
        let inSheet = app.sheets.buttons[label]
        if inSheet.waitForExistence(timeout: 5) { return inSheet }
        return app.buttons.matching(identifier: label).allElementsBoundByIndex.last ?? inSheet
    }

    /// Closes an open confirmation dialog without choosing: its Cancel button, or (where iOS draws the dialog
    /// as a popover with no Cancel row) a tap outside it.
    func cancelDialog() {
        let cancel = app.sheets.buttons["Cancel"]
        if cancel.waitForExistence(timeout: 2) { cancel.tap(); return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
    }

    /// You > I have symptoms (opens the report at its stickers step) > Cough > submit. The sheet shows Lisa's
    /// "Self-reported" stamp for a moment before it closes.
    func reportSymptoms(file: StaticString = #filePath, line: UInt = #line) {
        openTab("You", file: file, line: line)
        let row = el("report.symptoms")
        XCTAssertTrue(row.waitForExistence(timeout: 10), file: file, line: line)
        row.tap()
        let cough = el("symptom.cough")
        XCTAssertTrue(cough.waitForExistence(timeout: 5), file: file, line: line)
        cough.tap()
        let submit = app.buttons["report.submit"]
        XCTAssertTrue(submit.isEnabled, file: file, line: line)
        submit.tap()
        XCTAssertTrue(submit.waitForNonExistence(timeout: 5), "sheet should close", file: file, line: line)
        XCTAssertTrue(el("you.title").waitForExistence(timeout: 5), file: file, line: line)
    }

    /// You > I tested positive > Review and share > confirm.
    func reportPositive(file: StaticString = #filePath, line: UInt = #line) {
        openTab("You", file: file, line: line)
        el("report.positive").tap()
        XCTAssertTrue(el("report.title").waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(el("report.title").label.contains("I tested positive"), el("report.title").label, file: file, line: line)
        app.buttons["report.submit"].tap()
        let share = dialogButton("Share that I tested positive")
        XCTAssertTrue(share.waitForExistence(timeout: 5), "confirmation dialog", file: file, line: line)
        share.tap()
        XCTAssertTrue(app.buttons["report.submit"].waitForNonExistence(timeout: 5), "sheet should close", file: file, line: line)
    }
}
