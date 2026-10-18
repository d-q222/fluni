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
}
