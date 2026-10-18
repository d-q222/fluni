import XCTest

final class FlUniUITests: FlUniUITestCase {

    // MARK: Onboarding

    func testOnboardingCompletesAndIsNotShownAgain() {
        app.launch()
        XCTAssertTrue(app.staticTexts["Know when someone sick is near"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["onboarding.next"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "no tabs during onboarding")
        completeOnboarding()
        XCTAssertTrue(app.staticTexts["All clear"].waitForExistence(timeout: 5), "fresh install is all clear")

        // Relaunch without the reset: the saved "hasOnboarded" flag must skip onboarding.
        app.terminate()
        app.launchEnvironment["FLUNI_UITEST_RESET"] = nil
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["onboarding.next"].exists)
        XCTAssertFalse(app.staticTexts["Know when someone sick is near"].exists)
    }

    // MARK: Tabs

    func testTabsSwitchAndShowTheirTitles() {
        launchPastOnboarding()
        XCTAssertTrue(tab("Today").isSelected)
        openTab("Map")
        XCTAssertTrue(tab("Map").isSelected)
        XCTAssertFalse(app.navigationBars["Today"].exists)
        openTab("Me")
        XCTAssertTrue(tab("Me").isSelected)
        XCTAssertTrue(app.staticTexts["How are you doing?"].waitForExistence(timeout: 5))
        openTab("Today")
        XCTAssertTrue(tab("Today").isSelected)
        XCTAssertTrue(app.staticTexts["All clear"].exists)
    }

    // MARK: Risk

    func testRiskCardShowsPercentageAndCalculationShowsNumbers() {
        launchPastOnboarding()
        let card = el("risk.card")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertNotNil(card.label.range(of: #"\d{1,3}(\.\d)?%"#, options: .regularExpression),
                        "risk card should show a percentage, got: \(card.label)")
        XCTAssertTrue(card.label.contains("Your risk estimate"), card.label)

        scrollTo(app.buttons["risk.how"]).tap()
        XCTAssertTrue(app.navigationBars["How is this calculated?"].waitForExistence(timeout: 5))
        // With no nearby phones: "You: 0.0 of 15", "Your exposure dose: 0.000", "This phone's estimate: 2.0%".
        XCTAssertTrue(app.staticTexts["You: 0.0 of 15"].exists)
        XCTAssertTrue(app.staticTexts["Your exposure dose: 0.000"].exists)
        let estimate = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "This phone's estimate: ")).firstMatch
        XCTAssertTrue(estimate.exists, "the estimate line with p")
        XCTAssertNotNil(estimate.label.range(of: #"estimate: 2\.0%"#, options: .regularExpression), estimate.label)

        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["How is this calculated?"].exists)
    }

    /// Debug -demoPeer puts a pretend contagious phone 0.5 m away (no radios); at -speed 30 each 1 s tick
    /// credits 30 s, so the headline number must climb on screen within a few seconds, one decimal at a time.
    func testRiskNumberClimbsLiveNearAPretendContagiousPeer() {
        app.launchArguments += ["-demoPeer", "contagious@0.5", "-speed", "30"]
        launchPastOnboarding()
        let card = el("risk.card")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        func shown() -> Double? {
            guard let r = card.label.range(of: #"\d{1,3}\.\d(?=%)"#, options: .regularExpression) else { return nil }
            return Double(card.label[r])
        }
        var seen: [Double] = []
        for _ in 0 ..< 6 {
            if let v = shown() { seen.append(v) }
            Thread.sleep(forTimeInterval: 1.2)
        }
        XCTAssertEqual(seen.count, 6, "one-decimal percentage on the card: \(card.label)")
        for (a, b) in zip(seen, seen.dropFirst()) { XCTAssertGreaterThanOrEqual(b, a, "never drops: \(seen)") }
        XCTAssertGreaterThanOrEqual(Set(seen).count, 4, "changes almost every reading: \(seen)")
        XCTAssertGreaterThan(seen.last!, 2.0, "\(seen)")
    }

    // MARK: Self-report

    func testSymptomsSubmitNeedsASymptomThenSetsPossiblySick() {
        launchPastOnboarding()
        openTab("Me")
        XCTAssertTrue(el("report.fine").isSelected, "starts healthy")
        XCTAssertFalse(el("athome.card").exists)

        el("report.symptoms").tap()
        XCTAssertTrue(app.navigationBars["I have symptoms"].waitForExistence(timeout: 5))
        let submit = app.buttons["report.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled, "disabled with no symptom picked")

        let cough = el("symptom.cough")
        cough.tap()
        XCTAssertTrue(cough.isSelected)
        XCTAssertTrue(submit.isEnabled, "enabled once a symptom is picked")
        cough.tap()
        XCTAssertFalse(submit.isEnabled, "disabled again when unpicked")
        cough.tap()
        submit.tap()

        XCTAssertTrue(app.navigationBars["Me"].waitForExistence(timeout: 5))
        XCTAssertTrue(el("report.symptoms").isSelected, "status reads possibly sick")
        XCTAssertFalse(el("report.fine").isSelected)
        XCTAssertTrue(el("athome.card").waitForExistence(timeout: 5), "At home card appears")
        XCTAssertTrue(app.staticTexts["What to do"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Day 1 of'")).firstMatch.exists)
    }

    func testPositiveNeedsConfirmationAndCancelKeepsOldStatus() {
        launchPastOnboarding()
        reportSymptoms()
        XCTAssertTrue(el("report.symptoms").isSelected)

        el("report.positive").tap()
        XCTAssertTrue(app.navigationBars["I tested positive"].waitForExistence(timeout: 5))
        app.buttons["report.submit"].tap()
        let share = dialogButton("Share that I tested positive")
        XCTAssertTrue(share.waitForExistence(timeout: 5), "tapping Review and share only opens a confirmation")
        XCTAssertTrue(app.staticTexts["Tell nearby phones you tested positive?"].exists)
        dialogButton("Cancel").tap()
        XCTAssertTrue(share.waitForNonExistence(timeout: 5), "dialog closed")
        XCTAssertTrue(app.navigationBars["I tested positive"].exists, "still in the form, nothing submitted")

        app.navigationBars["I tested positive"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Me"].waitForExistence(timeout: 5))
        XCTAssertTrue(el("report.symptoms").isSelected, "status unchanged: possibly sick")
        XCTAssertFalse(el("report.positive").isSelected)
    }

    func testFeelFineCannotClearContagiousEarly() {
        launchPastOnboarding()
        reportPositive()
        XCTAssertTrue(el("report.positive").isSelected, "status reads contagious")
        XCTAssertTrue(el("athome.card").waitForExistence(timeout: 5))

        el("report.fine").tap()
        let alert = app.alerts["Can't change that yet"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "explanation appears")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'stay marked contagious'")).firstMatch.exists,
                      "explains why")
        alert.buttons["OK"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(el("report.positive").isSelected, "still contagious")
        XCTAssertFalse(el("report.fine").isSelected)
    }

    // MARK: Settings

    func testPauseForOneHourShowsBannerAndResumeRemovesIt() {
        launchPastOnboarding()
        XCTAssertFalse(el("banner.paused").exists)
        openTab("Me")
        scrollTo(el("settings.row")).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let pause = el("settings.pause")
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        let hour = app.buttons["For 1 hour"]
        XCTAssertTrue(hour.waitForExistence(timeout: 5), "pause menu")
        hour.tap()
        XCTAssertTrue(app.buttons["Turn detection back on"].waitForExistence(timeout: 5), "settings shows it is paused")

        app.navigationBars["Settings"].buttons.firstMatch.tap()  // back to Me
        openTab("Today")
        XCTAssertTrue(el("banner.paused").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Detection is paused"].exists)
        let resume = app.buttons["banner.resume"]
        XCTAssertTrue(resume.isHittable)
        resume.tap()
        XCTAssertTrue(el("banner.paused").waitForNonExistence(timeout: 5), "banner gone")
        XCTAssertFalse(app.staticTexts["Detection is paused"].exists)
    }

    func testDeleteMyDataReturnsToOnboarding() {
        launchPastOnboarding()
        reportSymptoms()
        scrollTo(el("settings.row")).tap()
        let delete = app.buttons["settings.delete"]
        scrollTo(delete).tap()
        XCTAssertTrue(app.staticTexts["Delete all data on this phone?"].waitForExistence(timeout: 5))
        dialogButton("Delete my data").tap()

        XCTAssertTrue(app.buttons["onboarding.next"].waitForExistence(timeout: 10), "back to onboarding")
        XCTAssertTrue(app.staticTexts["Know when someone sick is near"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        // And the saved status is gone once onboarding is done again.
        completeOnboarding()
        openTab("Me")
        XCTAssertTrue(el("report.fine").isSelected)
        XCTAssertFalse(el("athome.card").exists)
    }

    // MARK: Accessibility smoke

    func testLargestDynamicTypeKeepsKeyButtonsReachable() {
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()

        let next = app.buttons["onboarding.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 15))
        XCTAssertTrue(next.isHittable, "Next reachable at XXXL")
        next.tap()
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(next.isHittable)
        next.tap()
        let turnOn = app.buttons["onboarding.turnOn"]
        XCTAssertTrue(turnOn.waitForExistence(timeout: 5))
        XCTAssertTrue(turnOn.isHittable, "Turn on detection reachable at XXXL")
        turnOn.tap()

        // Today
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        XCTAssertTrue(tab("Today").isHittable)
        XCTAssertTrue(scrollTo(app.buttons["risk.how"]).isHittable, "risk details button")

        // Map
        XCTAssertTrue(tab("Map").isHittable)
        openTab("Map")

        // Me
        XCTAssertTrue(tab("Me").isHittable)
        openTab("Me")
        for id in ["report.fine", "report.symptoms", "report.positive", "report.negative", "settings.row", "developer.row"] {
            XCTAssertTrue(scrollTo(el(id)).isHittable, "\(id) hittable at XXXL")
        }
        // The symptoms form is still usable.
        scrollTo(el("report.symptoms")).tap()
        XCTAssertTrue(app.navigationBars["I have symptoms"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollTo(el("symptom.fever")).isHittable)
        XCTAssertTrue(scrollTo(app.buttons["report.submit"]).isHittable, "submit reachable by scrolling")
    }
}
