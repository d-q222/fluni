import XCTest
@testable import FluniProx

final class WalkInWarningTests: XCTestCase {
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
