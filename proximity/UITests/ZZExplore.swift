import XCTest

// SCRATCH exploratory QA file. Never commit. Plain XCUIApplication: no reset, radios as normal.
final class ZZExplore: XCTestCase {
    var app: XCUIApplication!
    var step = 0

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        step = 0
    }

    func shot(_ name: String) {
        step += 1
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = String(format: "%02d_%@", step, name)
        a.lifetime = .keepAlways
        add(a)
    }

    func note(_ name: String, _ text: String) {
        let a = XCTAttachment(string: text)
        a.name = "note_\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    func tab(_ n: String) -> XCUIElement { app.buttons["tab.\(n)"] }

    func alerts() {
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if sb.alerts.firstMatch.waitForExistence(timeout: 1) {
            shot("SYSTEM_ALERT")
            note("system_alert", sb.alerts.firstMatch.debugDescription)
        }
    }

    func launch(_ args: [String] = []) {
        app.launchArguments = args
        app.launch()
        alerts()
    }

    func goTab(_ n: String) {
        let t = tab(n)
        if t.waitForExistence(timeout: 10) { t.tap() } else { note("missing_tab_\(n)", app.debugDescription) }
        sleep(1)
    }

    func dismissSheet() {
        let done = app.navigationBars.buttons["Done"]
        if done.exists { done.tap(); sleep(1); return }
        let cancel = app.navigationBars.buttons["Cancel"]
        if cancel.exists { cancel.tap(); sleep(1); return }
        app.swipeDown(velocity: .fast); sleep(1)
    }

    func scrollToBottom(_ max: Int = 8) { for _ in 0..<max { app.swipeUp(velocity: .fast) }; sleep(1) }

    // MARK: 1 launch + tabs

    func test01LaunchTabs() {
        launch()
        for t in [0.2, 0.8, 1.5] { Thread.sleep(forTimeInterval: t); shot("intro") }
        sleep(3); shot("after_intro")
        note("tree_launch", app.debugDescription)
        for n in ["map", "me", "today", "me", "map", "today"] {
            goTab(n)
            shot("tab_\(n)")
            note("navbars_\(n)", app.navigationBars.allElementsBoundByIndex.map { $0.identifier }.joined(separator: ","))
        }
    }

    // MARK: 2 Today

    func test02Today() {
        launch(["-hasOnboarded", "YES"])
        sleep(4)
        goTab("today")
        shot("today_top")
        note("today_tree", app.debugDescription)
        let info = el("status.info")
        if info.exists { info.tap(); sleep(1); shot("status_info_sheet"); dismissSheet() } else { note("status_info", "absent") }
        let how = el("risk.how")
        if how.waitForExistence(timeout: 5) {
            if !how.isHittable { app.swipeUp() }
            how.tap(); sleep(1); shot("calc_sheet")
            note("calc_tree", app.debugDescription)
            app.swipeUp(); shot("calc_sheet_scrolled")
            dismissSheet(); shot("after_calc")
        } else { note("risk_how", "missing") }
        let card = el("risk.card")
        if card.exists { card.tap(); sleep(1); shot("tapped_risk_card"); if app.navigationBars.buttons["Done"].exists { dismissSheet() } }
        let ac = app.buttons["Not now"]
        note("always_card", ac.exists ? "present" : "absent")
        let seeAll = app.staticTexts["See the last 14 days"]
        if seeAll.exists || app.buttons["See the last 14 days"].exists {
            var s = app.buttons["See the last 14 days"]; if !s.exists { s = seeAll }
            var n = 0; while !s.isHittable && n < 6 { app.swipeUp(); n += 1 }
            s.tap(); sleep(1); shot("recent_contacts")
            scrollToBottom(3); shot("recent_contacts_bottom")
            app.navigationBars.buttons.firstMatch.tap(); sleep(1)
        } else { note("see_last_14", "missing") }
        scrollToBottom()
        shot("today_bottom")
        let foot = app.buttons["How FlUni works and what it shares"]
        let box = tab("today")
        note("footnote_frames", "footnote=\(foot.exists ? "\(foot.frame) hittable=\(foot.isHittable)" : "missing") tabToday=\(box.frame) window=\(app.windows.firstMatch.frame)")
        if foot.exists { foot.tap(); sleep(1); shot("how_it_works"); scrollToBottom(4); shot("how_it_works_bottom"); dismissSheet() }
        shot("today_end")
    }

    // MARK: 2b Always card

    func test03AlwaysCard() {
        launch(["-hasOnboarded", "YES"])
        sleep(4); goTab("today")
        shot("today_for_always")
        let notNow = app.buttons["Not now"]
        if notNow.exists { notNow.tap(); sleep(1); shot("after_not_now") } else { note("always_card", "absent: \(app.staticTexts.allElementsBoundByIndex.prefix(30).map { $0.label })") }
    }

    // MARK: 3 Map

    func tapLatLon(_ wv: XCUIElement, _ a: (String, Double, Double), _ b: (String, Double, Double), _ lat: Double, _ lon: Double) -> Bool {
        let ea = wv.staticTexts[a.0].firstMatch, eb = wv.staticTexts[b.0].firstMatch
        guard ea.exists, eb.exists else { return false }
        let pa = CGPoint(x: ea.frame.midX, y: ea.frame.midY), pb = CGPoint(x: eb.frame.midX, y: eb.frame.midY)
        let sx = (pb.x - pa.x) / CGFloat(b.2 - a.2), sy = (pb.y - pa.y) / CGFloat(b.1 - a.1)
        let x = pa.x + CGFloat(lon - a.2) * sx, y = pa.y + CGFloat(lat - a.1) * sy
        let o = wv.frame.origin
        wv.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - o.x, dy: y - o.y)).tap()
        return true
    }

    func test04Map() {
        launch(["-hasOnboarded", "YES"])
        sleep(4)
        goTab("map")
        sleep(4); shot("map_loaded")
        let wv = app.webViews.firstMatch
        note("map_tree", wv.exists ? wv.debugDescription : "NO WEBVIEW\n" + app.debugDescription)
        let later = wv.buttons["In 1 hour"]
        if later.exists { later.tap(); sleep(2); shot("map_in_1_hour"); wv.buttons["Now"].tap(); sleep(2); shot("map_now") } else { note("horizon", "missing") }
        let info = wv.buttons["About this map"]
        if info.exists { info.tap(); sleep(1); shot("map_legend_info"); note("legend_tree", wv.debugDescription); info.tap(); sleep(1); shot("map_legend_closed") } else { note("legend_info", "missing") }
        // Label anchors (lat, lon) from labels.json; building centroids from buildings.geojson.
        let A = ("Main Quad", 37.42767, -122.1702), B = ("Green Library", 37.4268, -122.1665)
        let targets: [(String, Double, Double)] = [
            ("FloMo", 37.42203, -122.17175), ("LucieStern", 37.42442, -122.16566),
            ("GreenLibrary", 37.42666, -122.16688), ("Tresidder", 37.42415, -122.17095),
        ]
        var frames = "MainQuad=\(wv.staticTexts[A.0].firstMatch.frame) Green=\(wv.staticTexts[B.0].firstMatch.frame)\n"
        for t in targets {
            if tapLatLon(wv, A, B, t.1, t.2) {
                sleep(2); shot("map_tap_\(t.0)")
                frames += "\(t.0): popup texts=\(wv.staticTexts.allElementsBoundByIndex.map { $0.label }.filter { $0.contains("sick") || $0.contains("people") })\n"
                // close popup by tapping empty top-left area of the map
                wv.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.95)).tap(); sleep(1)
            } else { frames += "\(t.0): anchors missing\n" }
        }
        note("map_taps", frames)
        // tap visible label positions directly too
        for l in ["Tresidder", "Green Library", "Stern"] {
            let e = wv.staticTexts[l].firstMatch
            if e.exists && e.isHittable { e.tap(); sleep(2); shot("map_label_\(l)") }
        }
        wv.pinch(withScale: 2.5, velocity: 2); sleep(2); shot("map_zoomed")
        wv.swipeLeft(); sleep(1); shot("map_panned")
        goTab("today"); goTab("map"); sleep(1); shot("map_return")
    }

    // MARK: 4 Me

    func test05Me() {
        launch(["-hasOnboarded", "YES"])
        sleep(4)
        goTab("me"); shot("me_top")
        note("me_tree", app.debugDescription)
        for k in ["symptoms", "positive", "negative"] {
            let r = el("report.\(k)")
            var n = 0; while r.exists && !r.isHittable && n < 5 { app.swipeUp(); n += 1 }
            if r.exists { r.tap(); sleep(1); shot("sheet_\(k)"); note("sheet_\(k)", app.debugDescription); scrollToBottom(3); shot("sheet_\(k)_bottom")
                let c = app.navigationBars.buttons["Cancel"]
                if c.exists { c.tap() } else { app.swipeDown(velocity: .fast) }
                sleep(1); shot("after_cancel_\(k)")
            } else { note("row_\(k)", "missing") }
        }
        note("selection", ["fine","symptoms","positive","negative"].map { "\($0)=\(el("report.\($0)").isSelected)" }.joined(separator: " "))
        scrollToBottom(); shot("me_bottom")
        note("me_bottom_frames", "settings=\(el("settings.row").frame) dev=\(el("developer.row").frame) tab=\(tab("me").frame)")
        let dev = el("developer.row")
        if dev.exists && dev.isHittable { dev.tap(); sleep(2); shot("developer"); dismissSheet(); if app.navigationBars["Developer"].exists { app.swipeDown(velocity: .fast); sleep(1) } }
        let s = el("settings.row")
        if s.exists { if !s.isHittable { scrollToBottom() }; s.tap(); sleep(1); shot("settings_top")
            note("settings_tree", app.debugDescription)
            let p = el("settings.pause")
            if p.exists { p.tap(); sleep(1); shot("pause_menu")
                // dismiss menu without choosing
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap(); sleep(1); shot("pause_menu_dismissed") }
            scrollToBottom(); shot("settings_bottom")
            let d = el("settings.delete")
            if d.exists { d.tap(); sleep(1); shot("delete_dialog")
                let cancel = app.sheets.buttons["Cancel"].exists ? app.sheets.buttons["Cancel"] : app.buttons["Cancel"]
                if cancel.exists { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap() }
                sleep(1); shot("after_delete_cancel")
                note("still_onboarded", "Me navbar? \(app.navigationBars["Settings"].exists) onboarding? \(app.buttons["onboarding.next"].exists)")
            }
            app.navigationBars.buttons.firstMatch.tap(); sleep(1); shot("back_to_me")
        }
    }

    // MARK: 5 Tissue alert (test launch)

    func test06TissueAlert() {
        launch(["-hasOnboarded", "YES", "-demoPeer", "contagious@0.5"])
        sleep(2); goTab("today"); shot("demo_today_start")
        let pop = el("tissueAlert.pop")
        let ok = pop.waitForExistence(timeout: 150)
        shot(ok ? "pop_visible" : "pop_never_appeared")
        note("pop", ok ? "\(pop.frame) hittable=\(pop.isHittable)" : app.debugDescription)
        guard ok else { return }
        let start = pop.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -260)))
        shot("pulled_immediate")
        let gotIt = el("tissueAlert.ok")
        let sheet = gotIt.waitForExistence(timeout: 5)
        shot(sheet ? "sheet_open" : "sheet_missing")
        note("sheet_tree", app.debugDescription)
        if sheet {
            gotIt.tap()
            Thread.sleep(forTimeInterval: 0.3); shot("gotit_anim")
            sleep(2); shot("after_gotit")
        }
        scrollToBottom(); shot("demo_today_bottom")
        note("demo_frames", "footnote=\(app.buttons["How FlUni works and what it shares"].frame) tab=\(tab("today").frame)")
        if el("status.info").exists { scrollUpTop(); el("status.info").tap(); sleep(1); shot("demo_status_info"); dismissSheet() }
        goTab("me"); shot("demo_me"); goTab("today"); shot("demo_today_again")
    }

    func scrollUpTop() { for _ in 0..<6 { app.swipeDown(velocity: .fast) } }

    // MARK: 5b tissue: drag down pushes back

    func test07TissuePushBack() {
        launch(["-hasOnboarded", "YES", "-demoPeer", "contagious@0.5"])
        sleep(2); goTab("today")
        let pop = el("tissueAlert.pop")
        guard pop.waitForExistence(timeout: 150) else { shot("no_pop"); return }
        shot("pop")
        let s = pop.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        s.press(forDuration: 0.2, thenDragTo: s.withOffset(CGVector(dx: 0, dy: -260)))
        let gotIt = el("tissueAlert.ok")
        guard gotIt.waitForExistence(timeout: 5) else { shot("sheet_missing"); return }
        shot("sheet")
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        top.press(forDuration: 0.2, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 400)))
        Thread.sleep(forTimeInterval: 0.3); shot("pushdown_anim")
        sleep(2); shot("after_pushdown")
        note("after_pushdown", "ok exists=\(gotIt.exists) pop exists=\(pop.exists)")
        // switch tabs while alert pending
        goTab("map"); shot("map_with_alert"); goTab("me"); shot("me_with_alert"); goTab("today"); shot("today_with_alert")
    }

    // MARK: 6 stress

    func test08Stress() {
        launch(["-hasOnboarded", "YES"])
        sleep(4)
        XCUIDevice.shared.orientation = .landscapeLeft; sleep(2); shot("landscape_today")
        goTab("map"); sleep(2); shot("landscape_map")
        goTab("me"); shot("landscape_me")
        XCUIDevice.shared.orientation = .portrait; sleep(2); shot("portrait_back")
        XCUIDevice.shared.press(.home); sleep(3)
        app.activate(); sleep(2); shot("after_foreground")
        let names = ["today", "map", "me"]
        for i in 0..<45 { let t = tab(names[i % 3]); if t.exists { t.tap() } }
        sleep(2); shot("after_rapid_tabs")
        for i in 0..<20 { let t = tab(names[(i * 2) % 3]); if t.exists { t.tap() } ; if i % 5 == 0 { XCUIDevice.shared.press(.home); app.activate() } }
        sleep(2); shot("after_rapid_bg")
        goTab("today"); shot("final_today")
        note("final_state", "state=\(app.state.rawValue)")
    }
}
