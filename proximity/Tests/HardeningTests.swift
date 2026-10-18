import XCTest
@testable import FluniProx

final class HardeningTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func tmp(_ name: String = UUID().uuidString) -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("hard-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent(name)
    }

    // MARK: notifiedLevel

    func testNotifierNotifiesOnRiseOnly() {
        XCTAssertEqual(AlertNotifier.next(level: .nearby, notified: .none).notify, .nearby)
        XCTAssertNil(AlertNotifier.next(level: .nearby, notified: .nearby).notify)
        XCTAssertEqual(AlertNotifier.next(level: .closeContact, notified: .nearby).notify, .closeContact)
        XCTAssertNil(AlertNotifier.next(level: .none, notified: .none).notify)
    }

    func testNotifierLowersWhenLevelDropsSoLaterRiseNotifiesAgain() {
        var notified = AlertLevel.none
        var sent: [AlertLevel] = []
        for level in [AlertLevel.nearby, .nearby, .none, .none, .nearby, .closeContact, .closeContact, .nearby, .closeContact] {
            let n = AlertNotifier.next(level: level, notified: notified)
            notified = n.notified
            if let l = n.notify { sent.append(l) }
        }
        XCTAssertEqual(sent, [.nearby, .nearby, .closeContact, .closeContact])
        XCTAssertEqual(notified, .closeContact)
    }

    // MARK: cooldown reset

    func testResetCooldownsLetsABuildingWarnAgain() {
        let b = BuildingHeat.Building(id: "a", name: "A", lat: 1, lon: 2, radius: 40)
        let hot = BuildingHeat.Reading(people: 10, expectedSick: 5, heat: 0.9, high: true)
        var w = WalkInWarning()
        XCTAssertTrue(w.evaluate(now: t0, building: b, reading: hot, paused: false).notify)
        XCTAssertFalse(w.evaluate(now: t0 + 60, building: b, reading: hot, paused: false).notify)
        w.resetCooldowns()
        XCTAssertTrue(w.lastNotified.isEmpty)
        XCTAssertTrue(w.evaluate(now: t0 + 120, building: b, reading: hot, paused: false).notify)
        w.resetCooldowns(); w.resetCooldowns()  // idempotent
        XCTAssertTrue(w.lastNotified.isEmpty)
    }

    // MARK: exposure history: save across a relaunch, reset

    private func riskyStore(_ url: URL, minutes: Int) -> ExposureHistoryStore {
        let s = ExposureHistoryStore(url: url, now: t0)
        for i in 1...(minutes * 60) { s.record(simSeconds: 1, contacts: [(1, .contagious)], at: t0.addingTimeInterval(Double(i))) }
        return s
    }

    func testOngoingEpisodeSurvivesBackgroundAndContinuesWithinGap() throws {
        let url = tmp("exposure-history.json")
        let s = riskyStore(url, minutes: 5)
        let start = try XCTUnwrap(s.ongoing).start
        s.saveOngoing(now: t0.addingTimeInterval(300))
        XCTAssertTrue(s.episodes.isEmpty)  // backgrounding did not close it
        let again = ExposureHistoryStore(url: url, now: t0.addingTimeInterval(300 + 60))  // 60 s away
        XCTAssertEqual(again.ongoing?.start, start)
        XCTAssertTrue(again.episodes.isEmpty)
        // Risky again: still the same episode, not a second one.
        again.record(simSeconds: 60, contacts: [(1, .contagious)], at: t0.addingTimeInterval(300 + 120))
        XCTAssertEqual(again.ongoing?.start, start)
        XCTAssertEqual(again.ongoing?.weightedMinutes ?? 0, 6, accuracy: 1e-6)
    }

    func testOngoingEpisodeEndsOnRelaunchAfterTwoMinutesAway() throws {
        let url = tmp("exposure-history.json")
        let s = riskyStore(url, minutes: 5)
        s.saveOngoing(now: t0.addingTimeInterval(300))
        let again = ExposureHistoryStore(url: url, now: t0.addingTimeInterval(300 + 120))  // exactly the gap
        XCTAssertNil(again.ongoing)
        XCTAssertEqual(again.episodes.count, 1)
        XCTAssertEqual(again.episodes[0].weightedMinutes, 5, accuracy: 1e-6)
        // The saved open episode is consumed: another relaunch doesn't resurrect or duplicate it.
        let third = ExposureHistoryStore(url: url, now: t0.addingTimeInterval(1000))
        XCTAssertNil(third.ongoing)
        XCTAssertEqual(third.episodes.count, 1)
    }

    func testRestoreHandlesClockGoingBackwards() {
        var h = ExposureHistory()
        _ = h.advance(simSeconds: 60, contacts: [(1, .contagious)], at: t0)
        let o = h.openSnapshot!
        var h2 = ExposureHistory()
        XCTAssertEqual(h2.restore(o, savedAt: t0, now: t0.addingTimeInterval(-3600)), [])  // negative gap counts as 0
        XCTAssertNotNil(h2.ongoing)
    }

    func testStoreWithNothingOpenLeavesNoFile() {
        let url = tmp("exposure-history.json")
        let s = ExposureHistoryStore(url: url, now: t0)
        s.saveOngoing(now: t0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("exposure-open.json").path))
    }

    func testResetEmptiesMemoryAndFilesAndCannotRewrite() throws {
        let url = tmp("exposure-history.json")
        let s = riskyStore(url, minutes: 3)
        s.finishOngoing(now: t0.addingTimeInterval(200))
        XCTAssertFalse(s.episodes.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        _ = riskyStore(url, minutes: 1).saveOngoing(now: t0)  // an open file too
        s.reset()
        XCTAssertTrue(s.episodes.isEmpty); XCTAssertNil(s.ongoing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("exposure-open.json").path))
        s.finishOngoing(now: t0 + 1000)  // must not bring anything back
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(ExposureHistoryStore(url: url, now: t0 + 1000).episodes.isEmpty)
    }

    // MARK: self-report file

    func testSelfReportMigratesFromDefaultsOnceThenDeletesOldKey() throws {
        let suite = "hard-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        var rec = SelfReportRecord(); rec.risk = .possible; rec.symptoms = [.fever]; rec.onset = t0
        d.set(try JSONEncoder().encode(rec), forKey: SelfReportFile.oldDefaultsKey)
        let url = tmp("self-report.json")
        XCTAssertEqual(SelfReportFile.load(url: url, defaults: d), rec)
        XCTAssertNil(d.data(forKey: SelfReportFile.oldDefaultsKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(SelfReportFile.load(url: url, defaults: d), rec)  // now from the file
    }

    func testSelfReportCorruptOldValueIsDroppedAndUnwritableFileKeepsOldKey() throws {
        let suite = "hard-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set(Data("garbage".utf8), forKey: SelfReportFile.oldDefaultsKey)
        XCTAssertNil(SelfReportFile.load(url: tmp(), defaults: d))
        XCTAssertNil(d.data(forKey: SelfReportFile.oldDefaultsKey))
        // A destination that can't be written (its folder doesn't exist): keep the old copy, still return it.
        var rec = SelfReportRecord(); rec.risk = .contagious
        d.set(try JSONEncoder().encode(rec), forKey: SelfReportFile.oldDefaultsKey)
        let bad = URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/self-report.json")
        XCTAssertEqual(SelfReportFile.load(url: bad, defaults: d), rec)
        XCTAssertNotNil(d.data(forKey: SelfReportFile.oldDefaultsKey))
    }

    func testSelfReportNothingSavedIsNil() {
        let suite = "hard-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertNil(SelfReportFile.load(url: tmp(), defaults: d))
    }

    // MARK: geofence entries

    private func heat() throws -> BuildingHeat {
        try BuildingHeat.parse(BuildingHeat.header + "\n2026-01-05T00:00:00,a,A,37.4000,-122.1000,10,1.0,0.9,1\n")
    }

    func testRegionRadiusIsAtLeast100ButNotOverTheMaximum() {
        XCTAssertEqual(GeofenceEntry.regionRadius(for: 40, maximum: 400_000), 100)
        XCTAssertEqual(GeofenceEntry.regionRadius(for: 250, maximum: 400_000), 250)
        XCTAssertEqual(GeofenceEntry.regionRadius(for: 250, maximum: 150), 150)
    }

    func testEntryPostsOnlyWithAFreshFixInsideTheRealRadius() throws {
        let h = try heat(), now = t0
        let pending = ["a": now.addingTimeInterval(-2)]
        // At the centre: confirmed.
        XCTAssertEqual(GeofenceEntry.confirmed(pending: pending, fixLat: 37.4, fixLon: -122.1, accuracy: 10, fixTime: now, now: now, heat: h), ["a"])
        // 80 m away: inside the 100 m monitored circle but outside the real 40 m radius.
        XCTAssertEqual(GeofenceEntry.confirmed(pending: pending, fixLat: 37.4 + 0.00072, fixLon: -122.1, accuracy: 10, fixTime: now, now: now, heat: h), [])
    }

    func testEntryTimesOutAndRejectsStaleOrInvalidFixes() throws {
        let h = try heat(), now = t0
        XCTAssertEqual(GeofenceEntry.confirmed(pending: ["a": now.addingTimeInterval(-11)], fixLat: 37.4, fixLon: -122.1, accuracy: 10, fixTime: now, now: now, heat: h), [])
        XCTAssertEqual(GeofenceEntry.confirmed(pending: ["a": now.addingTimeInterval(-10)], fixLat: 37.4, fixLon: -122.1, accuracy: 10, fixTime: now, now: now, heat: h), ["a"])
        let p = ["a": now.addingTimeInterval(-1)]
        XCTAssertEqual(GeofenceEntry.confirmed(pending: p, fixLat: 37.4, fixLon: -122.1, accuracy: 10, fixTime: now.addingTimeInterval(-60), now: now, heat: h), [])  // old fix
        XCTAssertEqual(GeofenceEntry.confirmed(pending: p, fixLat: 37.4, fixLon: -122.1, accuracy: -1, fixTime: now, now: now, heat: h), [])  // invalid fix
        XCTAssertEqual(GeofenceEntry.confirmed(pending: ["zzz": now], fixLat: 37.4, fixLon: -122.1, accuracy: 10, fixTime: now, now: now, heat: h), [])  // unknown id
        XCTAssertEqual(GeofenceEntry.confirmed(pending: [:], fixLat: 37.4, fixLon: -122.1, accuracy: 10, fixTime: now, now: now, heat: h), [])
        XCTAssertEqual(GeofenceEntry.pruned(["a": now.addingTimeInterval(-11), "b": now.addingTimeInterval(-3)], now: now).keys.sorted(), ["b"])
    }
}
