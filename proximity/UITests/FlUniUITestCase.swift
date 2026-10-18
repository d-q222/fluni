import XCTest

/// Base class: launches FlUni fresh (UserDefaults and Application Support cleared) with the radios off,
/// via the test-only environment variables read in FlUni/FlUniApp.swift.
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
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10), "should land on Today", file: file, line: line)
    }

    func launchPastOnboarding() {
        app.launch()
        completeOnboarding()
    }

    /// Lisa's tissue tab bar: buttons with ids tab.today / tab.map / tab.me (the system tab bar is hidden).
    func tab(_ name: String) -> XCUIElement { app.buttons["tab.\(name.lowercased())"] }

    func openTab(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let t = tab(name)
        XCTAssertTrue(t.waitForExistence(timeout: 10), "\(name) tab", file: file, line: line)
        t.tap()
        // The Map tab is the bundled web map with no navigation bar; Today and Me have their titles.
        let screen = name == "Map" ? app.webViews.firstMatch : app.navigationBars[name]
        XCTAssertTrue(screen.waitForExistence(timeout: 10), "\(name) screen", file: file, line: line)
    }

    /// Any element type, by accessibility identifier (SwiftUI combined elements vary in type).
    func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// Swipes up until the element exists, can be tapped and is clear of Lisa's tab bar (a Form only builds rows
    /// near the screen, so Settings' Delete row doesn't exist until scrolled to; from flu-design2). XCUITest calls
    /// a row behind the box "hittable", but a tap there lands on a tissue (Me's Settings row opened Today).
    @discardableResult
    func scrollTo(_ e: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let window = app.windows.firstMatch.frame
        let boxTop = window.maxY - window.width / 3.0233  // TissueTabBar.aspect
        func ready() -> Bool { e.exists && e.isHittable && e.frame.maxY <= boxTop }
        var n = 0
        _ = e.waitForExistence(timeout: 3)
        while !ready() && n < 12 { app.swipeUp(); n += 1 }
        XCTAssertTrue(e.exists, "\(e) should exist", file: file, line: line)
        return e
    }

    /// Button inside a confirmation dialog (an action sheet on iPhone), not the same-named button behind it.
    func dialogButton(_ label: String) -> XCUIElement {
        let inSheet = app.sheets.buttons[label]
        if inSheet.waitForExistence(timeout: 5) { return inSheet }
        return app.buttons.matching(identifier: label).allElementsBoundByIndex.last ?? inSheet
    }

    /// Me > I have symptoms > pick one > submit.
    func reportSymptoms() {
        openTab("Me")
        let row = el("report.symptoms")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let cough = el("symptom.cough")
        XCTAssertTrue(cough.waitForExistence(timeout: 5))
        cough.tap()
        let submit = app.buttons["report.submit"]
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        // The sheet shows Lisa's "Self-reported" stamp for a moment before it closes.
        XCTAssertTrue(submit.waitForNonExistence(timeout: 5), "sheet should close")
        XCTAssertTrue(app.navigationBars["Me"].waitForExistence(timeout: 5))
    }

    /// Me > I tested positive > Review and share > confirm.
    func reportPositive() {
        openTab("Me")
        el("report.positive").tap()
        XCTAssertTrue(app.navigationBars["I tested positive"].waitForExistence(timeout: 5))
        app.buttons["report.submit"].tap()
        let share = dialogButton("Share that I tested positive")
        XCTAssertTrue(share.waitForExistence(timeout: 5), "confirmation dialog")
        share.tap()
        XCTAssertTrue(app.navigationBars["Me"].waitForExistence(timeout: 5), "sheet should close")
    }
}
