import XCTest
@testable import FluniProx

final class PlaceLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    func testStayingInOneBuildingIsOneVisitWithTheMostPhones() {
        var log = PlaceLog()
        log.observe(buildingID: "green", name: "Green Library", phones: 2, at: at(0))
        log.observe(buildingID: "green", name: "Green Library", phones: 5, sick: 1, at: at(4))
        log.observe(buildingID: "green", name: "Green Library", phones: 3, sick: 9, at: at(8))
        XCTAssertEqual(log.visits.count, 1)
        let v = log.visits[0]
        XCTAssertEqual(v.name, "Green Library")
        XCTAssertEqual(v.start, at(0))
        XCTAssertEqual(v.end, at(8))
        XCTAssertEqual(v.minutes, 8, accuracy: 1e-9)
        XCTAssertEqual(v.maxPhones, 5)
        XCTAssertEqual(v.maxSick, 3, "the most sick phones at once, never more than the phones seen then")
        XCTAssertEqual(log.current, v)
    }

    func testAnotherBuildingStartsANewVisit() {
        var log = PlaceLog()
        log.observe(buildingID: "gates", name: "Gates", phones: 1, at: at(0))
        log.observe(buildingID: "green", name: "Green Library", phones: 0, at: at(30))
        XCTAssertEqual(log.visits.map(\.buildingID), ["gates", "green"])
        XCTAssertEqual(log.current?.buildingID, "green")
        XCTAssertEqual(log.visits[0].end, at(0), "the old visit keeps its last seen time")
    }

    func testLeavingEndsTheCurrentVisitAndShortFlickerRejoins() {
        var log = PlaceLog()
        log.observe(buildingID: "green", name: "Green Library", phones: 0, at: at(0))
        log.observe(buildingID: nil, name: nil, phones: 0, at: at(3))
        XCTAssertNil(log.current, "outside: no current visit")
        // Back inside within the 10-minute gap: the same visit continues.
        log.observe(buildingID: "green", name: "Green Library", phones: 0, at: at(6))
        XCTAssertEqual(log.visits.count, 1)
        XCTAssertEqual(log.current?.end, at(6))
    }

    func testReturningAfterTheGapIsANewVisit() {
        var log = PlaceLog()
        log.observe(buildingID: "green", name: "Green Library", phones: 0, at: at(0))
        log.observe(buildingID: "green", name: "Green Library", phones: 0, at: at(10.01))
        XCTAssertEqual(log.visits.count, 2, "more than 10 minutes unseen: a new stay")
        var exact = PlaceLog()
        exact.observe(buildingID: "green", name: "Green Library", phones: 0, at: at(0))
        exact.observe(buildingID: "green", name: "Green Library", phones: 0, at: at(10))
        XCTAssertEqual(exact.visits.count, 1, "exactly 10 minutes still continues")
    }

    func testExpireEndsAVisitNobodyConfirmed() {
        var log = PlaceLog()
        log.observe(buildingID: "green", name: "Green Library", phones: 0, at: at(0))
        log.expire(now: at(10))
        XCTAssertNotNil(log.current, "within the gap")
        log.expire(now: at(11))
        XCTAssertNil(log.current)
        XCTAssertEqual(log.visits.count, 1, "the visit itself stays in the log")
    }

    func testBackwardsClockIsIgnoredAndPhonesNeverNegative() {
        var log = PlaceLog()
        log.observe(buildingID: "green", name: "Green Library", phones: -3, at: at(5))
        XCTAssertEqual(log.visits[0].maxPhones, 0)
        log.observe(buildingID: "gates", name: "Gates", phones: 9, at: at(1))
        XCTAssertEqual(log.visits.count, 1)
        XCTAssertEqual(log.current?.buildingID, "green")
    }

    func testMissingNameFallsBackToTheID() {
        var log = PlaceLog()
        log.observe(buildingID: "b12", name: nil, phones: 0, at: at(0))
        XCTAssertEqual(log.visits[0].name, "b12")
    }

    func testPruneKeepsExactly24HoursAndNothingOlder() {
        var log = PlaceLog()
        log.observe(buildingID: "a", name: "A", phones: 0, at: at(0))
        log.observe(buildingID: "b", name: "B", phones: 0, at: at(60))
        log.prune(now: at(60 + 24 * 60))
        XCTAssertEqual(log.visits.map(\.buildingID), ["b"], "A ended 25 h ago; B ended exactly 24 h ago")
        log.prune(now: at(60 + 24 * 60 + 0.01))
        XCTAssertTrue(log.visits.isEmpty)
        XCTAssertNil(log.current)
    }

    func testPassingThroughIsUnderFiveMinutes() {
        let short = PlaceVisit(buildingID: "q", name: "Main Quad", start: at(0), end: at(4.99), maxPhones: 0)
        let stay = PlaceVisit(buildingID: "q", name: "Main Quad", start: at(0), end: at(5), maxPhones: 0)
        XCTAssertTrue(short.isPassingThrough)
        XCTAssertFalse(stay.isPassingThrough)
    }

    func testRoundTripsAndToleratesJunk() throws {
        var log = PlaceLog()
        log.observe(buildingID: "green", name: "Green Library", phones: 3, at: at(0))
        log.observe(buildingID: "green", name: "Green Library", phones: 3, at: at(7))
        let back = PlaceLog.decode(try PlaceLog.encode(log))
        XCTAssertEqual(back, log)
        XCTAssertEqual(PlaceLog.decode(Data("not json".utf8)), PlaceLog())
        let json = String(decoding: try PlaceLog.encode(log), as: UTF8.self)
        XCTAssertFalse(json.contains("lat"), "no coordinates are ever stored")
    }
}
