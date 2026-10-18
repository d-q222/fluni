import XCTest
@testable import FluniProx

final class WalkInWarningTests: XCTestCase {
    func testSickUsersGetRestAdviceNotMaskAdvice() {
        let well = WalkInWarning.message(for: "Green Library")
        let sick = WalkInWarning.message(for: "Green Library", sick: true)
        XCTAssertTrue(well.contains("Consider a mask"))
        XCTAssertEqual(sick, "You're out at Green Library while you're unwell. Head home and rest up when you can.")
        XCTAssertFalse(sick.contains("mask"))
        XCTAssertEqual(WalkInWarning.message(for: "Green Library", sick: false), well)
    }

    func testNotificationTextFollowsSick() {
        let well = NotificationRoute.text(kind: .building, detailed: true, buildingName: "Jerry").body
        let sick = NotificationRoute.text(kind: .building, detailed: true, buildingName: "Jerry", sick: true).body
        XCTAssertTrue(well.contains("mask"))
        XCTAssertTrue(sick.contains("Head home and rest up"))
        XCTAssertFalse(sick.contains("mask"))
        // Details off stays neutral for everyone.
        XCTAssertEqual(NotificationRoute.text(kind: .building, detailed: false, buildingName: "Jerry", sick: true).body,
                       NotificationRoute.text(kind: .building, detailed: false, buildingName: "Jerry").body)
    }

    private let jerry = BuildingHeat.Building(id: "a", name: "Jerry", lat: 1, lon: 2, radius: 40)
    private let lib = BuildingHeat.Building(id: "b", name: "Library", lat: 1, lon: 2, radius: 40)
    private let hot = BuildingHeat.Reading(people: 100, expectedSick: 50, heat: 0.6, high: true)
    private let warm = BuildingHeat.Reading(people: 100, expectedSick: 20, heat: 0.4, high: false)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testHighInsideBannersAndNotifiesOnce() {
        var w = WalkInWarning()
        let o = w.evaluate(now: t0, building: jerry, reading: hot, paused: false)
        XCTAssertEqual(o, .init(bannerBuilding: jerry, notify: true))
        let o2 = w.evaluate(now: t0 + 60, building: jerry, reading: hot, paused: false)
        XCTAssertEqual(o2, .init(bannerBuilding: jerry, notify: false))
    }

    func testCooldownBoundary() {
        var w = WalkInWarning()
        XCTAssertTrue(w.evaluate(now: t0, building: jerry, reading: hot, paused: false).notify)
        XCTAssertFalse(w.evaluate(now: t0 + 7199, building: jerry, reading: hot, paused: false).notify)
        XCTAssertTrue(w.evaluate(now: t0 + 7200, building: jerry, reading: hot, paused: false).notify)
        XCTAssertFalse(w.evaluate(now: t0 + 7200 + 7199, building: jerry, reading: hot, paused: false).notify)
    }

    func testCooldownIsPerBuilding() {
        var w = WalkInWarning()
        XCTAssertTrue(w.evaluate(now: t0, building: jerry, reading: hot, paused: false).notify)
        XCTAssertTrue(w.evaluate(now: t0 + 10, building: lib, reading: hot, paused: false).notify)
    }

    func testLeavingAndReenteringWithinCooldownDoesNotRenotify() {
        var w = WalkInWarning()
        XCTAssertTrue(w.evaluate(now: t0, building: jerry, reading: hot, paused: false).notify)
        XCTAssertEqual(w.evaluate(now: t0 + 600, building: nil, reading: nil, paused: false), .init(bannerBuilding: nil, notify: false))
        XCTAssertEqual(w.evaluate(now: t0 + 1200, building: jerry, reading: hot, paused: false), .init(bannerBuilding: jerry, notify: false))
        XCTAssertTrue(w.evaluate(now: t0 + 7300, building: jerry, reading: hot, paused: false).notify)
    }

    func testBuildingTurnsHighWhileInside() {
        var w = WalkInWarning()
        XCTAssertEqual(w.evaluate(now: t0, building: jerry, reading: warm, paused: false), .init(bannerBuilding: nil, notify: false))
        XCTAssertEqual(w.evaluate(now: t0 + 900, building: jerry, reading: hot, paused: false), .init(bannerBuilding: jerry, notify: true))
        XCTAssertEqual(w.evaluate(now: t0 + 1800, building: jerry, reading: warm, paused: false), .init(bannerBuilding: nil, notify: false))
    }

    func testNoDataIsNotAWarning() {
        var w = WalkInWarning()
        XCTAssertEqual(w.evaluate(now: t0, building: jerry, reading: nil, paused: false), .init(bannerBuilding: nil, notify: false))
    }

    func testPausedNeverWarnsAndKeepsCooldownFree() {
        var w = WalkInWarning()
        XCTAssertEqual(w.evaluate(now: t0, building: jerry, reading: hot, paused: true), .init(bannerBuilding: nil, notify: false))
        XCTAssertTrue(w.evaluate(now: t0 + 1, building: jerry, reading: hot, paused: false).notify)
    }

    func testPersistedCooldownIsHonoured() {
        var w = WalkInWarning(lastNotified: ["a": t0])
        XCTAssertFalse(w.evaluate(now: t0 + 100, building: jerry, reading: hot, paused: false).notify)
    }

    func testMessage() {
        XCTAssertEqual(WalkInWarning.message(for: "Jerry"), "Jerry has a lot of illness right now. Consider a mask, or a different spot.")
    }

    /// The walk-in warning fires on building_heat.csv's `high`; the Map tab shades from the bundled totals.json.
    /// Both must call a building "high" for the same reason: at least MIN_PEOPLE people and
    /// sqrt(expected sick above the baseline / colour max) >= 0.5 (the map's dark half of the ramp).
    /// totals.json rounds counts to 2 decimals, so a building within 0.01 of the line may differ.
    func testWarningHighMatchesWhatTheMapShadesDark() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FlUni/Resources")
        let heat = try BuildingHeat.parse(try Fixture.data("building_heat.csv", sourcePath: src.appendingPathComponent("building_heat.csv")))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: src.appendingPathComponent("app-bundle/data/totals.json"))) as! [String: Any]
        let ids = (json["buildings"] as! [[String: Any]]).map { $0["id"] as! String }
        let steps = json["steps"] as! [[[Double]]]
        let stepMs = json["stepMs"] as! Double, minPeople = json["minPeople"] as! Double
        func excess(_ r: [Double]) -> Double { r.count > 3 ? r[3] : r[2] }
        let peaks = steps.map { $0.map(excess).max() ?? 0 }.sorted()
        let vmax = peaks[Int(0.9 * Double(peaks.count - 1))]
        XCTAssertGreaterThan(vmax, 0)
        var checked = 0, high = 0
        for (s, rows) in steps.enumerated() {
            guard let snap = heat.state(at: Double(s) * stepMs / 1000 + (heat.timeRange?.lowerBound ?? 0)) else { continue }
            for r in rows where r[1] >= minPeople {
                guard let reading = snap.readings[ids[Int(r[0])]] else { continue }
                let x = (excess(r) / vmax).squareRoot()
                if abs(x - 0.5) < 0.01 { continue }
                checked += 1
                if reading.high { high += 1 }
                XCTAssertEqual(reading.high, x >= 0.5, "step \(s) \(ids[Int(r[0])])")
            }
        }
        XCTAssertGreaterThan(checked, 1000)
        XCTAssertGreaterThan(high, 100)
    }
}
