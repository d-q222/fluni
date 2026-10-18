import XCTest
@testable import FluniProx

final class DayTimelineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    private func ep(_ start: Double, _ minutes: Double, weighted: Double? = nil, _ risk: Risk = .contagious) -> ExposureEpisode {
        ExposureEpisode(start: at(start), end: at(start + minutes), weightedMinutes: weighted ?? minutes, maxRisk: risk)
    }
    private func visit(_ name: String, _ start: Double, _ end: Double, phones: Int = 0) -> PlaceVisit {
        PlaceVisit(buildingID: name.lowercased(), name: name, start: at(start), end: at(end), maxPhones: phones)
    }

    func testShortEpisodeIsAHeadsUpAndALongOneACloseContact() {
        let m = DayTimeline.moments([ep(0, 6), ep(100, 18)], visits: [], now: at(200))
        XCTAssertEqual(m.map(\.kind), [.headsUp, .closeContact])
    }

    func testRunningTotalCrossingFifteenMakesThatEpisodeTheCloseContact() {
        // 8 + 8 weighted minutes: the second crosses the 15-minute mark, like the live alert.
        let m = DayTimeline.moments([ep(0, 8), ep(60, 8), ep(120, 3)], visits: [], now: at(200))
        XCTAssertEqual(m.map(\.kind), [.headsUp, .closeContact, .headsUp], "only the crossing one is the moment")
    }

    func testHalfWeightedSymptomsDoNotCrossEarly() {
        // 20 minutes near someone with symptoms counts 10 weighted minutes: still a heads-up.
        let m = DayTimeline.moments([ep(0, 20, weighted: 10, .possible)], visits: [], now: at(60))
        XCTAssertEqual(m.map(\.kind), [.headsUp])
    }

    func testOnlyTheLast24HoursCountAndDuplicatesAreDropped() {
        let old = ep(0, 16)
        let recent = ep(24 * 60 + 30, 4)
        let m = DayTimeline.moments([old, recent, recent], visits: [], now: at(24 * 60 + 60))
        XCTAssertEqual(m.count, 1, "the old close contact ended over 24 h ago; the ongoing copy is not listed twice")
        XCTAssertEqual(m.first?.kind, .headsUp, "and its minutes no longer add to the total")
    }

    func testMomentIsPlacedInTheVisitThatCoversIt() {
        let visits = [visit("Gates", 0, 80), visit("Green Library", 90, 200)]
        let m = DayTimeline.moments([ep(120, 18), ep(85, 2)], visits: visits, now: at(210))
        XCTAssertEqual(m[0].placeName, nil, "between visits, more than a minute from either")
        XCTAssertEqual(m[1].placeName, "Green Library")
        XCTAssertEqual(DayTimeline.place(at: at(80.9), in: visits)?.name, "Gates", "a minute of slack after the last fix")
    }

    func testRowsAreNewestFirstWithMomentsInTheirPlace() {
        let quad = visit("Main Quad", 0, 3)                     // passing through, nothing happened: left out
        let gates = visit("Gates", 10, 80, phones: 4)
        let green = visit("Green Library", 90, 200, phones: 3)
        let all = [quad, gates, green]
        let moments = DayTimeline.moments([ep(20, 4), ep(84, 2), ep(120, 18)], visits: all, now: at(200))
        let rows = DayTimeline.rows(visits: all, current: green, moments: moments, now: at(200))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].visit?.name, "Green Library")
        XCTAssertTrue(rows[0].isNow)
        XCTAssertEqual(rows[0].moments.map(\.kind), [.closeContact])
        XCTAssertNil(rows[1].visit, "a moment between visits gets a row of its own")
        XCTAssertEqual(rows[1].moments.first?.episode.start, at(84))
        XCTAssertEqual(rows[2].visit?.name, "Gates")
        XCTAssertFalse(rows[2].isNow)
        XCTAssertEqual(rows[2].moments.map(\.kind), [.headsUp])
    }

    func testAShortVisitStaysWhenSomethingHappenedOrItIsNow() {
        let quad = visit("Main Quad", 0, 3)
        let withMoment = DayTimeline.rows(visits: [quad], current: nil,
                                          moments: DayTimeline.moments([ep(1, 1)], visits: [quad], now: at(10)), now: at(10))
        XCTAssertEqual(withMoment.first?.visit?.name, "Main Quad")
        XCTAssertEqual(DayTimeline.rows(visits: [quad], current: quad, moments: [], now: at(3)).count, 1)
        XCTAssertTrue(DayTimeline.rows(visits: [quad], current: nil, moments: [], now: at(10)).isEmpty)
        XCTAssertTrue(DayTimeline.rows(visits: [visit("Gates", 0, 60)], current: nil, moments: [], now: at(26 * 60)).isEmpty,
                      "a visit that ended over 24 h ago is gone")
    }
}

final class StayHomeTrackTests: XCTestCase {
    private var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Los_Angeles")!; return c }()
    private func day(_ d: Int, _ h: Int = 10) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))! }

    func testOnsetDayIsDayZeroAndTheLastDayIsDayFive() throws {
        let r = SelfReporter(calendar: cal)
        let rec = try r.reportSymptoms(SelfReportRecord(), symptoms: [.cough], onset: day(15), now: day(17))
        XCTAssertEqual(r.dayNumber(rec, now: day(17)), 2, "Thu 15 is day 0, Sat 17 day 2")
        let track = r.trackDays(rec)
        XCTAssertEqual(track.map(\.day), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(track.last?.date, cal.startOfDay(for: day(20)), "home through Tue Oct 20")
        XCTAssertEqual(r.phase(rec, now: day(17)), .inProgress(day: 2, lastDay: cal.startOfDay(for: day(20))))
        XCTAssertTrue(r.trackDays(SelfReportRecord()).isEmpty)
    }

    func testCheckInKeepsTheFeeling() throws {
        let r = SelfReporter(calendar: cal)
        let rec = try r.reportSymptoms(SelfReportRecord(), symptoms: [.cough], onset: day(15), now: day(16))
        let after = r.checkIn(rec, stillSymptomatic: true, hasFever: false, feeling: .better, now: day(17))
        XCTAssertEqual(after.lastFeeling, .better)
        XCTAssertEqual(after.lastCheckIn, day(17))
        XCTAssertEqual(after.risk, .possible, "feeling better is not the same as no symptoms")
        XCTAssertFalse(r.checkInDue(after, now: day(17, 20)))
        XCTAssertTrue(r.checkInDue(after, now: day(18, 8)))
        let worse = r.checkIn(after, stillSymptomatic: true, hasFever: true, feeling: .worse, now: day(18))
        XCTAssertEqual(worse.lastFeeling, .worse)
        XCTAssertEqual(worse.lastFeverAt, day(18))
    }
}
