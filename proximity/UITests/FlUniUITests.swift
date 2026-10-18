import XCTest

final class FlUniUITests: FlUniUITestCase {

    // MARK: Onboarding

    func testOnboardingCompletesAndIsNotShownAgain() {
        app.launch()
        XCTAssertTrue(app.staticTexts["Know when someone sick is near"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["onboarding.next"].exists)
        XCTAssertFalse(tab("Today").exists, "no tabs during onboarding")
        completeOnboarding()
        XCTAssertEqual(el("today.status").label, "All clear", "fresh install is all clear")
        XCTAssertTrue(el("tissue.says").exists, "the tissue says how things are")

        // Relaunch without the reset: the saved "hasOnboarded" flag must skip onboarding.
        app.terminate()
        app.launchEnvironment["FLUNI_UITEST_RESET"] = nil
        app.launch()
        XCTAssertTrue(el("today.now").waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["onboarding.next"].exists)
        XCTAssertFalse(app.staticTexts["Know when someone sick is near"].exists)
    }

    // MARK: Tabs

    func testTabsSwitchAndShowTheirScreens() {
        launchPastOnboarding()
        XCTAssertTrue(tab("Today").isSelected)
        // Lisa's tissue-box bar: three buttons by id, labelled Today / Map / Me; no system tab bar.
        XCTAssertEqual(tab("Map").label, "Map")
        XCTAssertEqual(tab("Me").label, "Me")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "no system tab bar")
        openTab("Map")
        XCTAssertFalse(el("today.now").isHittable, "Today is behind")
        openTab("Me")
        XCTAssertTrue(app.staticTexts["How are you feeling?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["What nearby phones see about you"].exists)
        openTab("Today")
        XCTAssertEqual(el("today.status").label, "All clear")
    }

    /// The privacy promise is on Today, word for word.
    func testTodayShowsThePrivacyPromise() {
        launchPastOnboarding()
        let promise = scrollTo(el("today.privacy"))
        XCTAssertTrue(promise.label.contains("Your precise location never leaves this phone and is never seen by anyone."), promise.label)
    }

    // MARK: Risk

    func testRiskCardShowsPercentageAndCalculationShowsNumbers() {
        launchPastOnboarding()
        let card = el("risk.card")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertNotNil(card.label.range(of: #"\d{1,3}(\.\d)?%"#, options: .regularExpression),
                        "risk card should show a percentage, got: \(card.label)")
        XCTAssertTrue(card.label.contains("Your risk estimate"), card.label)

        scrollTo(card).tap()
        XCTAssertTrue(app.navigationBars["How is this calculated?"].waitForExistence(timeout: 5))
        // With no nearby phones: "You: 0.0 of 15", "Your exposure dose: 0.000", "This phone's estimate: 2.0%".
        XCTAssertTrue(app.staticTexts["You: 0.0 of 15"].exists)
        XCTAssertTrue(app.staticTexts["Your exposure dose: 0.000"].exists)
        let estimate = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "This phone's estimate: ")).firstMatch
        XCTAssertTrue(estimate.exists, "the estimate line with p")
        XCTAssertNotNil(estimate.label.range(of: #"estimate: 2\.0%"#, options: .regularExpression), estimate.label)

        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["How is this calculated?"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(el("today.now").exists)
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

    // MARK: Heads-up and close contact

    /// A pretend contagious phone 0.5 m away: Today first draws the heads-up state (the brief's words), then at
    /// 15 minutes the close contact opens in place with the four steps and the risk in context; Got it folds it.
    func testHeadsUpThenCloseContactOpensInPlace() {
        app.launchArguments += ["-demoPeer", "contagious@0.5", "-speed", "40"]
        launchPastOnboarding()
        XCTAssertTrue(el("today.headsUp").waitForExistence(timeout: 10), "heads-up drawn")
        XCTAssertEqual(el("today.status").label, "Heads-up")
        XCTAssertTrue(app.staticTexts["Put 6 ft or more between you, or step outside."].exists)
        XCTAssertTrue(app.staticTexts["Consider wearing a mask while you're here."].exists)

        let gotIt = el("closeContact.gotIt")
        XCTAssertTrue(gotIt.waitForExistence(timeout: 60), "close contact opens in place")
        XCTAssertEqual(el("today.status").label, "Close contact")
        for step in ["Leave the room now, or move well away and put on a mask.",
                     "Wash your hands; avoid touching your face.",
                     "Watch for fever, cough or sore throat over the next 1–4 days.",
                     "If symptoms start, get tested and report it in FlUni."] {
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", step)).firstMatch.exists, step)
        }
        let risk = el("closeContact.risk")
        XCTAssertTrue(risk.label.hasPrefix("Your risk estimate went from 2.0% to "), risk.label)
        scrollTo(gotIt).tap()
        XCTAssertTrue(gotIt.waitForNonExistence(timeout: 5), "folded")
        XCTAssertTrue(el("today.closeContact").exists, "still on the timeline, folded")
        XCTAssertTrue(el("today.reportSymptoms").exists, "the Now action is back")
    }

    // MARK: Self-report

    /// Today > I don't feel well > step 1 > I have symptoms > step 2 (stickers, start day) > stamp > staying home.
    func testReportFromTodayInTwoStepsStartsTheStayHomeTrack() {
        launchPastOnboarding()
        scrollTo(el("today.reportSymptoms")).tap()
        XCTAssertTrue(el("report.title").waitForExistence(timeout: 5))
        XCTAssertTrue(el("report.title").label.contains("Step 1 of 2"), el("report.title").label)
        XCTAssertTrue(el("report.title").label.contains("How are you feeling?"))
        for id in ["choose.fine", "choose.symptoms", "choose.positive", "choose.negative"] {
            XCTAssertTrue(el(id).exists, id)
        }
        el("choose.symptoms").tap()
        XCTAssertTrue(el("symptom.fever").waitForExistence(timeout: 5), "step 2: the stickers")
        XCTAssertTrue(el("report.title").label.contains("Step 2 of 2"), el("report.title").label)
        let submit = app.buttons["report.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled, "disabled with no sticker picked")
        el("symptom.fever").tap()
        XCTAssertTrue(el("symptom.fever").isSelected)
        XCTAssertTrue(submit.isEnabled)
        XCTAssertTrue(el("report.dayLine").label.hasPrefix("That makes today Day 0."), el("report.dayLine").label)
        el("day.Yesterday").tap()
        XCTAssertTrue(el("report.dayLine").label.hasPrefix("That makes today Day 1."), el("report.dayLine").label)
        submit.tap()
        XCTAssertTrue(el("report.stamp").waitForExistence(timeout: 3), "Lisa's stamp lands on save")
        XCTAssertTrue(submit.waitForNonExistence(timeout: 5), "then the sheet closes")

        let heading = el("athome.heading")
        XCTAssertTrue(heading.waitForExistence(timeout: 5), "Today becomes the stay-home track")
        XCTAssertTrue(heading.label.contains("Day 1 of 5"), heading.label)
        XCTAssertFalse(el("risk.card").exists, "no risk number while sick")
        XCTAssertTrue(scrollTo(app.staticTexts["Tell your RA and your professors that you're sick and staying home."]).exists)
        XCTAssertTrue(app.staticTexts["Use Vaden Health Center for testing and care. Call ahead instead of walking in."].exists)
    }

    /// Day 0 is the day symptoms started (Core/SelfReport.swift's IsolationPolicy), so a report about today
    /// reads "Day 0 of 5", and the last day home is five days later.
    func testSymptomsSubmitNeedsASymptomThenSetsPossiblySick() {
        launchPastOnboarding()
        openTab("Me")
        XCTAssertTrue(el("report.fine").isSelected, "starts healthy")
        XCTAssertFalse(el("athome.card").exists)

        el("report.symptoms").tap()
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

        XCTAssertTrue(submit.waitForNonExistence(timeout: 5), "sheet closes after the stamp")
        XCTAssertTrue(el("you.title").waitForExistence(timeout: 5))
        XCTAssertTrue(el("report.symptoms").isSelected, "status reads possibly sick")
        XCTAssertFalse(el("report.fine").isSelected)
        XCTAssertTrue(el("athome.card").waitForExistence(timeout: 5), "stay-home summary appears")
        XCTAssertTrue(app.staticTexts["Staying home, day 0 of 5"].exists, "the report day is day 0")

        openTab("Today")
        let heading = el("athome.heading")
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertTrue(heading.label.contains("Day 0 of 5"), heading.label)
        XCTAssertTrue(heading.label.contains("possibly sick"), heading.label)
    }

    func testCheckInIsOneTapAndSaysSo() {
        launchPastOnboarding()
        reportSymptoms()
        openTab("Today")
        // Reporting counts as today's check-in; "Change" asks again.
        let change = scrollTo(app.buttons["Change"])
        change.tap()
        let worse = scrollTo(el("checkin.worse"))
        XCTAssertTrue(el("checkin.better").exists && el("checkin.same").exists)
        worse.tap()
        let done = el("checkin.done")
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(done.label.hasPrefix("Checked in: worse."), done.label)
    }

    func testPositiveNeedsConfirmationAndCancelKeepsOldStatus() {
        launchPastOnboarding()
        reportSymptoms()
        XCTAssertTrue(el("report.symptoms").isSelected)

        el("report.positive").tap()
        XCTAssertTrue(el("report.title").waitForExistence(timeout: 5))
        XCTAssertTrue(el("report.title").label.contains("I tested positive"))
        app.buttons["report.submit"].tap()
        let share = dialogButton("Share that I tested positive")
        XCTAssertTrue(share.waitForExistence(timeout: 5), "tapping Review and share only opens a confirmation")
        XCTAssertTrue(app.staticTexts["Tell nearby phones you tested positive?"].exists)
        cancelDialog()
        XCTAssertTrue(share.waitForNonExistence(timeout: 5), "dialog closed")
        XCTAssertTrue(app.buttons["report.submit"].exists, "still in the form, nothing submitted")

        el("report.close").tap()
        XCTAssertTrue(app.buttons["report.submit"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(el("report.symptoms").isSelected, "status unchanged: possibly sick")
        XCTAssertFalse(el("report.positive").isSelected)
    }

    func testFeelFineCannotClearContagiousEarly() {
        launchPastOnboarding()
        reportPositive()
        XCTAssertTrue(el("report.positive").waitForExistence(timeout: 5))
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

    /// Owner's ruling: someone who reported a positive test (or symptoms) never sees a risk percentage or band.
    func testAfterAPositiveReportNoRiskPercentageAnywhere() {
        launchPastOnboarding()
        XCTAssertTrue(el("risk.card").exists, "healthy: the estimate is there")
        reportPositive()
        let percent = NSPredicate(format: "label MATCHES %@", #".*\d+(\.\d)?\s?%.*"#)
        let band = NSPredicate(format: "label CONTAINS[c] 'risk estimate'")
        func noRisk(_ screen: String) {
            XCTAssertEqual(app.descendants(matching: .any).matching(percent).count, 0, "no % on \(screen)")
            XCTAssertEqual(app.descendants(matching: .any).matching(band).count, 0, "no risk estimate on \(screen)")
            XCTAssertFalse(el("risk.card").exists, screen)
            XCTAssertFalse(el("risk.advice").exists, screen)
        }
        noRisk("Me")
        openTab("Today")
        XCTAssertTrue(el("athome.heading").waitForExistence(timeout: 5))
        XCTAssertTrue(el("athome.heading").label.contains("contagious"), el("athome.heading").label)
        for _ in 0..<3 { noRisk("Today"); app.swipeUp() }
    }

    // MARK: Pause and data

    func testPauseForOneHourShowsPausedStateAndResumeRemovesIt() {
        launchPastOnboarding()
        XCTAssertFalse(el("banner.paused").exists)
        openTab("Me")
        scrollTo(el("you.pause")).tap()
        let hour = dialogButton("For 1 hour")
        XCTAssertTrue(hour.waitForExistence(timeout: 5), "pause choices")
        hour.tap()
        XCTAssertTrue(el("you.resume").waitForExistence(timeout: 5), "You shows it is paused")

        openTab("Today")
        XCTAssertTrue(el("banner.paused").waitForExistence(timeout: 5))
        XCTAssertEqual(el("today.status").label, "Paused")
        let resume = scrollTo(app.buttons["banner.resume"])
        XCTAssertTrue(resume.isHittable)
        resume.tap()
        XCTAssertTrue(el("banner.paused").waitForNonExistence(timeout: 5), "paused note gone")
        XCTAssertEqual(el("today.status").label, "All clear")
    }

    /// Settings keeps its own pause menu too.
    func testSettingsPauseMenuStillWorks() {
        launchPastOnboarding()
        openTab("Me")
        scrollTo(el("settings.row")).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let pause = el("settings.pause")
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        let hour = dialogButton("For 1 hour")
        XCTAssertTrue(hour.waitForExistence(timeout: 5), "pause choices")
        hour.tap()
        XCTAssertTrue(app.buttons["Turn detection back on"].waitForExistence(timeout: 5), "settings shows it is paused")
    }

    func testDeleteMyDataFromSettingsReturnsToOnboarding() {
        launchPastOnboarding()
        reportSymptoms()
        scrollTo(el("settings.row")).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        scrollTo(app.buttons["settings.delete"]).tap()
        XCTAssertTrue(app.staticTexts["Delete all data on this phone?"].waitForExistence(timeout: 5))
        dialogButton("Delete my data").tap()

        XCTAssertTrue(app.buttons["onboarding.next"].waitForExistence(timeout: 10), "back to onboarding")
        XCTAssertTrue(app.staticTexts["Know when someone sick is near"].exists)
        XCTAssertFalse(tab("Today").exists)
        // And the saved status is gone once onboarding is done again.
        completeOnboarding()
        openTab("Me")
        XCTAssertTrue(el("report.fine").isSelected)
        XCTAssertFalse(el("athome.card").exists)
    }

    func testDeleteMyDataFromYou() {
        launchPastOnboarding()
        reportSymptoms()
        scrollTo(el("you.delete")).tap()
        XCTAssertTrue(app.staticTexts["Delete all data on this phone?"].waitForExistence(timeout: 5))
        dialogButton("Delete my data").tap()
        XCTAssertTrue(app.buttons["onboarding.next"].waitForExistence(timeout: 10), "back to onboarding")
        completeOnboarding()
        XCTAssertTrue(el("today.now").exists, "Today's day timeline, not the stay-home track")
        openTab("Me")
        XCTAssertTrue(el("report.fine").isSelected, "status back to healthy")
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
        XCTAssertTrue(el("today.now").waitForExistence(timeout: 10))
        XCTAssertTrue(tab("Today").isHittable)
        XCTAssertTrue(scrollTo(el("risk.card")).isHittable, "risk details")
        XCTAssertTrue(scrollTo(el("today.reportSymptoms")).isHittable, "I don't feel well")

        // Campus
        XCTAssertTrue(tab("Map").isHittable)
        openTab("Map")

        // You
        XCTAssertTrue(tab("Me").isHittable)
        openTab("Me")
        for id in ["report.fine", "report.symptoms", "report.positive", "report.negative", "you.pause", "settings.row", "you.delete", "developer.row"] {
            XCTAssertTrue(scrollTo(el(id)).isHittable, "\(id) hittable at XXXL")
        }
        // The stickers step is still usable.
        app.swipeDown(); app.swipeDown(); app.swipeDown(); app.swipeDown()
        scrollTo(el("report.symptoms")).tap()
        XCTAssertTrue(scrollTo(el("symptom.fever")).isHittable)
        el("symptom.fever").tap()
        XCTAssertTrue(app.buttons["report.submit"].isHittable, "submit stays in reach")
    }
}
