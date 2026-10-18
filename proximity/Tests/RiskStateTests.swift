import XCTest
@testable import FluniProx

/// flu-persist: the risk estimate and its alert state survive a relaunch, on this phone only.
final class RiskStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var dir: URL!
    private var file: URL { dir.appendingPathComponent(RiskStateStore.fileName) }
    private var logs: [String] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("risk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logs = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store() -> RiskStateStore { RiskStateStore(url: file) { [unowned self] in self.logs.append($0) } }

    private func pClose(_ metres: Double) -> Double {
        Fusion.exposurePClose(Estimate(distance: metres, sigma: 0.1, sources: [.uwb]))
    }

    /// `seconds` one-second ticks beside one peer, as ExposureTick feeds them.
    private func contact(_ e: inout ExposureTracker, seconds: Int, id: String = "a", metres: Double = 0.5,
                         risk: Risk = .contagious, s: Double? = nil, stage: Double? = nil) {
        let p = pClose(metres)
        for _ in 0 ..< seconds {
            e.advance(simSeconds: 1, contacts: [(p, risk)], doses: [DosePeer(id: id, distance: metres, s: s, stage: stage)])
        }
    }

    private func quiet(_ e: inout ExposureTracker, seconds: Int, step: Double = 1) {
        for _ in 0 ..< seconds { e.advance(simSeconds: step, contacts: []) }
    }

    // MARK: Round trip

    func testRoundTripGivesAnIdenticalTrackerAndP() throws {
        var e = ExposureTracker()
        quiet(&e, seconds: 37, step: 1.37)                              // clock off the minute grid
        contact(&e, seconds: 600, id: "old", metres: 1.2, risk: .possible, s: 0.6, stage: 0.9)
        quiet(&e, seconds: 20, step: 3600)                              // 20 h on
        contact(&e, seconds: 500, id: "new", metres: 0.5)
        e.advance(simSeconds: 1, contacts: [(0.4, .contagious)])        // nearby held by hysteresis (>= 0.3)
        XCTAssertEqual(e.level, .nearby)
        XCTAssertGreaterThan(e.probability, 0.05)
        var gate = AlertGate()
        XCTAssertEqual(gate.step(.nearby, now: t0), .nearby)

        let state = RiskState(savedAt: t0, exposure: e, gate: gate)
        let back = try XCTUnwrap(RiskStateFile.decode(try RiskStateFile.encode(state)))
        XCTAssertEqual(back, state)                                     // every field, buckets and clock included
        XCTAssertEqual(back.exposure.probability, e.probability, accuracy: 1e-12)
        XCTAssertEqual(back.exposure.minutes, e.minutes, accuracy: 1e-12)
        XCTAssertEqual(back.exposure.dose, e.dose, accuracy: 1e-12)
        XCTAssertEqual(back.exposure.sources, e.sources)
        XCTAssertEqual(back.exposure.level, .nearby)

        // The hidden state (clock, per-minute buckets) carried over: both expire the old contact at the same moment.
        var a = e, b = back.exposure
        quiet(&a, seconds: 5, step: 3600)
        quiet(&b, seconds: 5, step: 3600)
        XCTAssertNil(a.sources["old"], "the 20 h-old contact has expired")
        XCTAssertNotNil(a.sources["new"])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.probability, b.probability, accuracy: 1e-12)
    }

    // MARK: Restore rules

    func testRestoreOneHourLaterEqualsAnUninterruptedTrackerWithNoContacts() throws {
        var e = ExposureTracker()
        contact(&e, seconds: 15 * 60)                                   // 15 min, contagious, 0.5 m
        XCTAssertGreaterThan(e.probability, 0.07, "the contact must move p well off the 2% prior (7.5% after 15 min at 0.5 m)")
        let s = store()
        s.save(e, gate: AlertGate(), now: t0)

        var uninterrupted = e
        quiet(&uninterrupted, seconds: 3600)                            // the phone kept running, nobody around

        let r = try XCTUnwrap(store().load(now: t0.addingTimeInterval(3600)))
        XCTAssertEqual(r.exposure.probability, uninterrupted.probability, accuracy: 1e-12)
        XCTAssertEqual(r.exposure.probability, e.probability, accuracy: 1e-12, "nothing credited for the gap")
        XCTAssertEqual(r.exposure.minutes, uninterrupted.minutes, accuracy: 1e-12)
        XCTAssertEqual(r.exposure.dose, uninterrupted.dose, accuracy: 1e-12)
        XCTAssertEqual(r.exposure.sources, uninterrupted.sources)
        XCTAssertEqual(r.exposure.level, uninterrupted.level)
    }

    func testRestoreExpiresOnlyWhatLeftTheWindow() throws {
        var e = ExposureTracker()
        quiet(&e, seconds: 1, step: 17.3)
        contact(&e, seconds: 10 * 60, id: "early")
        quiet(&e, seconds: 20 * 60, step: 60)                           // 20 h
        contact(&e, seconds: 5 * 60, id: "late", metres: 1)
        store().save(e, gate: AlertGate(), now: t0)

        var uninterrupted = e
        quiet(&uninterrupted, seconds: 5 * 60, step: 60)                // 5 h: "early" leaves the window, "late" stays
        let r = try XCTUnwrap(store().load(now: t0.addingTimeInterval(5 * 3600)))
        XCTAssertNil(r.exposure.sources["early"])
        XCTAssertNotNil(r.exposure.sources["late"])
        XCTAssertEqual(r.exposure.sources, uninterrupted.sources)
        XCTAssertEqual(r.exposure.probability, uninterrupted.probability, accuracy: 1e-12)
        XCTAssertLessThan(r.exposure.probability, e.probability)
        XCTAssertGreaterThan(r.exposure.probability, RiskEstimate.prior)
    }

    func testRestoreAfter25HoursIsBackToThePrior() throws {
        var e = ExposureTracker()
        contact(&e, seconds: 20 * 60)
        XCTAssertEqual(e.level, .closeContact)
        store().save(e, gate: AlertGate(), now: t0)
        let r = try XCTUnwrap(store().load(now: t0.addingTimeInterval(25 * 3600)))
        XCTAssertEqual(r.exposure.probability, RiskEstimate.prior)
        XCTAssertEqual(r.exposure.minutes, 0)
        XCTAssertEqual(r.exposure.dose, 0)
        XCTAssertEqual(r.exposure.level, .none)
        XCTAssertTrue(r.exposure.isEmpty)
    }

    func testAHeadsUpNeedsSomeoneInRangeAfterARelaunchButACloseContactStays() throws {
        var e = ExposureTracker()
        contact(&e, seconds: 60)
        XCTAssertEqual(e.level, .nearby)
        store().save(e, gate: AlertGate(), now: t0)
        XCTAssertEqual(try XCTUnwrap(store().load(now: t0.addingTimeInterval(5))).exposure.level, .none)

        contact(&e, seconds: 15 * 60)
        XCTAssertEqual(e.level, .closeContact)
        store().save(e, gate: AlertGate(), now: t0)
        XCTAssertEqual(try XCTUnwrap(store().load(now: t0.addingTimeInterval(3600))).exposure.level, .closeContact)
    }

    func testClockSetBackwardsOrAFileFromTheFutureStartsFresh() throws {
        var e = ExposureTracker()
        contact(&e, seconds: 15 * 60)
        store().save(e, gate: AlertGate(), now: t0)

        for back: Double in [3600, 61, 30 * 24 * 3600] {
            logs = []
            XCTAssertNil(store().load(now: t0.addingTimeInterval(-back)), "\(back) s back")
            XCTAssertEqual(logs.count, 1)
            XCTAssertTrue(logs[0].contains("future"), logs[0])
        }
        // A small correction (network time) is no gap, not a reason to drop the estimate.
        let r = try XCTUnwrap(store().load(now: t0.addingTimeInterval(-30)))
        XCTAssertEqual(r.exposure.probability, e.probability, accuracy: 1e-12)

        // A model given a future-dated file runs with a fresh estimate.
        let s = store()
        s.save(e, gate: AlertGate(), now: Date().addingTimeInterval(7200))
        let m = ProximityModel(riskStore: s)
        XCTAssertEqual(m.liveRisk, RiskEstimate.prior)
        XCTAssertEqual(m.exposure, ExposureTracker())
    }

    func testCorruptOrImplausibleFilesStartFreshAndAreLoggedOnce() throws {
        var e = ExposureTracker()
        contact(&e, seconds: 15 * 60)
        let good = try RiskStateFile.encode(RiskState(savedAt: t0, exposure: e, gate: AlertGate()))
        let json = String(decoding: good, as: UTF8.self)

        func tampered(_ key: String, _ value: String) -> Data {
            let r = try! NSRegularExpression(pattern: "\"\(key)\":[-0-9.eE+]+")
            let out = r.stringByReplacingMatches(in: json, range: NSRange(json.startIndex..., in: json),
                                                 withTemplate: "\"\(key)\":\(value)")
            XCTAssertNotEqual(out, json, "\(key) not found")
            return Data(out.utf8)
        }
        let bad: [(String, Data)] = [
            ("garbage", Data([0xff, 0x00, 0x13, 0x37])),
            ("empty", Data()),
            ("truncated", good.prefix(good.count / 2)),
            ("wrong version", tampered("version", "2")),
            ("p not from its sources", tampered("probability", "0.9")),
            ("p above 1", tampered("probability", "1.5")),
            ("negative minutes", tampered("minutes", "-5")),
            ("negative clock", tampered("clock", "-1")),
        ]
        for (name, data) in bad {
            try data.write(to: file)
            logs = []
            let s = store()
            XCTAssertNil(s.load(now: t0.addingTimeInterval(60)), name)
            XCTAssertEqual(logs.count, 1, name)
            XCTAssertTrue(logs.first?.contains("corrupt") ?? false, name)
            // Still writable: the next save replaces the bad file with a good one.
            s.save(e, gate: AlertGate(), now: t0)
            XCTAssertEqual(try XCTUnwrap(RiskStateFile.decode(Data(contentsOf: file))).exposure, e, name)
        }
        // The untouched file is accepted (so the checks above aren't rejecting everything).
        try good.write(to: file)
        XCTAssertNotNil(store().load(now: t0.addingTimeInterval(60)))
    }

    // MARK: Where and when it is written

    func testTestLaunchesAndTheUnitTestHostNeverReadOrWriteTheFile() throws {
        XCTAssertNil(RiskStateStore.location(isTestLaunch: true, isUnitTestHost: false))
        XCTAssertNil(RiskStateStore.location(isTestLaunch: false, isUnitTestHost: true))
        XCTAssertNil(RiskStateStore.location(isTestLaunch: true, isUnitTestHost: true, keepOnTestLaunch: true))
        XCTAssertNotNil(RiskStateStore.location(isTestLaunch: true, isUnitTestHost: false, keepOnTestLaunch: true),
                        "Debug -keepRiskState opts a test launch in")
        XCTAssertNil(RiskStateStore.defaultURL, "this run is the unit-test host")
        XCTAssertNil(ProximityModel().riskStore.url)

        // A store without a file reads nothing and writes nothing.
        var e = ExposureTracker()
        contact(&e, seconds: 15 * 60)
        let none = RiskStateStore(url: nil)
        XCTAssertNil(none.load(now: t0))
        none.save(e, gate: AlertGate(), now: t0)
        none.saveIfDue(e, gate: AlertGate(), now: t0, levelChanged: true)
        XCTAssertEqual(none.writes, 0)
    }

    func testTheFileIsInApplicationSupportWhichDeleteMyDataEmpties() throws {
        // SettingsView.eraseLocalData removes every item in Application Support; the file must live there.
        let url = try XCTUnwrap(RiskStateStore.location(isTestLaunch: false, isUnitTestHost: false))
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, support.standardizedFileURL)
        XCTAssertEqual(url.lastPathComponent, "risk-state.json")
    }

    func testDeleteMyDataRemovesTheFileAndNothingWritesItBack() throws {
        var e = ExposureTracker()
        contact(&e, seconds: 16 * 60)
        var gate = AlertGate()
        _ = gate.step(.closeContact, now: Date())
        store().save(e, gate: gate, now: Date())

        let m = ProximityModel(riskStore: store())
        XCTAssertEqual(m.liveRisk, e.probability, accuracy: 1e-12, "restored before the first frame")
        XCTAssertEqual(m.exposure.level, .closeContact)
        XCTAssertEqual(m.alertGate, gate)
        XCTAssertEqual(m.ownScore, e.probability, accuracy: 1e-12, "the own score starts from the restored estimate")
        XCTAssertEqual(RiskEstimate.liveText(m.liveRisk), RiskEstimate.liveText(e.probability))

        m.forgetEverything()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(m.liveRisk, RiskEstimate.prior)
        m.saveRiskState()                                               // e.g. going to the background afterwards
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(ProximityModel(riskStore: store()).liveRisk, RiskEstimate.prior)
    }

    func testSavesOnLevelChangesAndAtMostEvery30SecondsOtherwise() throws {
        let s = store()
        var e = ExposureTracker()
        var levelChanges: [Int] = []
        // Beside a contagious peer, saving on every 1 s tick the way the model does; p climbs on every tick.
        for i in 1 ... 579 {
            let before = e.level
            contact(&e, seconds: 1)
            if e.level != before { levelChanges.append(i) }
            s.saveIfDue(e, gate: AlertGate(), now: t0.addingTimeInterval(Double(i)), levelChanged: e.level != before)
        }
        XCTAssertEqual(levelChanges, [1], "none -> nearby on the first tick")
        XCTAssertEqual(s.writes, 20, "t = 1 (the level change), then 31, 61, ..., 571: 579 ticks, 20 writes")
        var saved = try XCTUnwrap(RiskStateFile.decode(Data(contentsOf: file)))
        XCTAssertEqual(saved.savedAt, t0.addingTimeInterval(571))
        XCTAssertEqual(saved.exposure.level, .nearby)

        // The peer leaves: nearby -> none is written at once, 9 s after the last write.
        quiet(&e, seconds: 1)
        XCTAssertEqual(e.level, .none)
        s.saveIfDue(e, gate: AlertGate(), now: t0.addingTimeInterval(580), levelChanged: true)
        XCTAssertEqual(s.writes, 21)
        saved = try XCTUnwrap(RiskStateFile.decode(Data(contentsOf: file)))
        XCTAssertEqual(saved.exposure.level, .none)
        XCTAssertEqual(saved.exposure.probability, e.probability, accuracy: 1e-12)

        // Nobody around: the clock moves but nothing visible changes, so nothing more is written.
        for i in 581 ... 700 {
            quiet(&e, seconds: 1)
            s.saveIfDue(e, gate: AlertGate(), now: t0.addingTimeInterval(Double(i)), levelChanged: false)
        }
        XCTAssertEqual(s.writes, 21)
    }

    // MARK: Notifications

    func testARestoredGateDoesNotNotifyTheSameAlertAgain() throws {
        var e = ExposureTracker()
        var gate = AlertGate()
        var posted: [NotificationKind] = []
        let p = pClose(0.5)
        for i in 1 ... 16 * 60 {
            e.advance(simSeconds: 1, contacts: [(p, .contagious)], doses: [DosePeer(id: "a", distance: 0.5)])
            if let k = gate.step(e.level, now: t0.addingTimeInterval(Double(i))) { posted.append(k) }
        }
        XCTAssertEqual(posted, [.nearby, .closeContact])
        store().save(e, gate: gate, now: t0.addingTimeInterval(960))

        // Relaunch 10 min later: the close contact is still in the window and must not notify again, on the first
        // tick or later, even when the peer is back.
        let r = try XCTUnwrap(store().load(now: t0.addingTimeInterval(1560)))
        var restored = r.gate, re = r.exposure
        XCTAssertNil(restored.step(re.level, now: t0.addingTimeInterval(1561)))
        for i in 1 ... 300 {
            re.advance(simSeconds: 1, contacts: [(p, .contagious)], doses: [DosePeer(id: "b", distance: 0.5)])
            XCTAssertNil(restored.step(re.level, now: t0.addingTimeInterval(1561 + Double(i))))
        }
        // Without the saved gate the same relaunch would notify again (so the check above can fail).
        var fresh = AlertGate()
        XCTAssertEqual(fresh.step(r.exposure.level, now: t0.addingTimeInterval(1561)), .closeContact)
    }

    func testARestoredHeadsUpCooldownHolds() throws {
        var e = ExposureTracker()
        var gate = AlertGate()
        contact(&e, seconds: 30)
        XCTAssertEqual(gate.step(e.level, now: t0), .nearby)
        store().save(e, gate: gate, now: t0)

        let r = try XCTUnwrap(store().load(now: t0.addingTimeInterval(600)))
        var restored = r.gate, re = r.exposure
        XCTAssertNil(restored.step(re.level, now: t0.addingTimeInterval(600)))      // level none after the gap
        contact(&re, seconds: 5)                                                    // the peer is back, 10 min later
        XCTAssertEqual(re.level, .nearby)
        XCTAssertNil(restored.step(re.level, now: t0.addingTimeInterval(605)), "inside the 30 min cooldown")
        var fresh = AlertGate()
        _ = fresh.step(.none, now: t0.addingTimeInterval(600))
        XCTAssertEqual(fresh.step(.nearby, now: t0.addingTimeInterval(605)), .nearby)
    }
}
