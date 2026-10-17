import XCTest
@testable import FluniProx

final class PauseScheduleTests: XCTestCase {
    private func cal(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }
    private func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    private let ny = "America/New_York"

    // MARK: until

    func testOneHourIsExactlyAnHourEvenAcrossDST() {
        let now = at("2026-03-08T06:30:00Z")  // 01:30 EST, 30 min before the spring-forward
        XCTAssertEqual(PauseSchedule.until(.oneHour, from: now, calendar: cal(ny)), now.addingTimeInterval(3600))
    }

    func testUntilResumedHasNoEnd() {
        XCTAssertNil(PauseSchedule.until(.untilResumed, from: Date(), calendar: cal(ny)))
    }

    func testUntilTomorrowIsTheNextLocalMidnight() {
        let c = cal(ny)
        let end = PauseSchedule.until(.untilTomorrow, from: at("2026-06-10T15:00:00Z"), calendar: c)!  // 11:00 EDT
        XCTAssertEqual(end, at("2026-06-11T04:00:00Z"))  // 00:00 EDT on the 11th
        XCTAssertEqual(c.dateComponents([.hour, .minute], from: end).hour, 0)
    }

    func testPausingExactlyAtMidnightLastsAFullDay() {
        let end = PauseSchedule.until(.untilTomorrow, from: at("2026-06-11T04:00:00Z"), calendar: cal(ny))!
        XCTAssertEqual(end, at("2026-06-12T04:00:00Z"))
    }

    func testOneSecondBeforeMidnightEndsASecondLater() {
        let now = at("2026-06-11T03:59:59Z")
        XCTAssertEqual(PauseSchedule.until(.untilTomorrow, from: now, calendar: cal(ny)), at("2026-06-11T04:00:00Z"))
    }

    func testUntilTomorrowOnTheSpringForwardDayIs23HoursLong() {
        // 2026-03-08 is 23 h in New York. Noon EDT (16:00Z) to midnight EDT (04:00Z on the 9th) is 12 h.
        let now = at("2026-03-08T16:00:00Z")
        let end = PauseSchedule.until(.untilTomorrow, from: now, calendar: cal(ny))!
        XCTAssertEqual(end, at("2026-03-09T04:00:00Z"))
        // Paused just after 00:00 on that short day: 23 h, not 24.
        let early = PauseSchedule.until(.untilTomorrow, from: at("2026-03-08T05:00:00Z"), calendar: cal(ny))!
        XCTAssertEqual(early.timeIntervalSince(at("2026-03-08T05:00:00Z")), 23 * 3600)
    }

    func testUntilTomorrowOnTheFallBackDayIs25HoursLong() {
        // 2026-11-01 is 25 h in New York.
        let now = at("2026-11-01T04:00:00Z")  // 00:00 EDT
        let end = PauseSchedule.until(.untilTomorrow, from: now, calendar: cal(ny))!
        XCTAssertEqual(end, at("2026-11-02T05:00:00Z"))  // 00:00 EST
        XCTAssertEqual(end.timeIntervalSince(now), 25 * 3600)
        XCTAssertLessThan(end.timeIntervalSince(now), PauseSchedule.maxSpan)
    }

    func testTimeZoneDecidesWhichMidnight() {
        let now = at("2026-06-10T23:30:00Z")
        XCTAssertEqual(PauseSchedule.until(.untilTomorrow, from: now, calendar: cal("UTC")), at("2026-06-11T00:00:00Z"))
        XCTAssertEqual(PauseSchedule.until(.untilTomorrow, from: now, calendar: cal("Pacific/Auckland")), at("2026-06-11T12:00:00Z"))
    }

    func testMidnightThatDoesNotExistStillEndsTheNextMorning() {
        // Sao Paulo used to skip 00:00 on DST day (2018-11-04: clocks 00:00 -> 01:00).
        let now = at("2018-11-03T15:00:00Z")  // noon local
        let end = PauseSchedule.until(.untilTomorrow, from: now, calendar: cal("America/Sao_Paulo"))!
        XCTAssertGreaterThan(end, now)
        XCTAssertLessThanOrEqual(end.timeIntervalSince(now), PauseSchedule.maxSpan)
    }

    // MARK: shouldResume

    func testBoundaryIsInclusive() {
        let s = at("2026-06-10T12:00:00Z")
        let p = PauseSchedule.state(.oneHour, from: s, calendar: cal(ny))
        XCTAssertFalse(PauseSchedule.shouldResume(p, now: s))
        XCTAssertFalse(PauseSchedule.shouldResume(p, now: s.addingTimeInterval(3599.999)))
        XCTAssertTrue(PauseSchedule.shouldResume(p, now: s.addingTimeInterval(3600)))
        XCTAssertTrue(PauseSchedule.shouldResume(p, now: s.addingTimeInterval(3600.001)))
        XCTAssertTrue(PauseSchedule.shouldResume(p, now: s.addingTimeInterval(86400 * 30)))
    }

    func testOpenEndedPauseNeverResumesOnItsOwn() {
        let p = PauseState(since: at("2026-06-10T12:00:00Z"), until: nil)
        for d: TimeInterval in [0, 1, 3600, 86400 * 365, -86400 * 365] {
            XCTAssertFalse(PauseSchedule.shouldResume(p, now: p.since.addingTimeInterval(d)))
        }
    }

    func testSmallBackwardsClockStepDoesNotEndAPause() {
        let s = at("2026-06-10T12:00:00Z")
        let p = PauseSchedule.state(.oneHour, from: s, calendar: cal(ny))
        XCTAssertFalse(PauseSchedule.shouldResume(p, now: s.addingTimeInterval(-0.3)))
        XCTAssertFalse(PauseSchedule.shouldResume(p, now: s.addingTimeInterval(-PauseSchedule.clockSkewTolerance)))
    }

    func testClockSetBackBeforeThePauseBeganResumes() {
        let s = at("2026-06-10T12:00:00Z")
        let p = PauseSchedule.state(.oneHour, from: s, calendar: cal(ny))
        XCTAssertTrue(PauseSchedule.shouldResume(p, now: s.addingTimeInterval(-PauseSchedule.clockSkewTolerance - 1)))
        XCTAssertTrue(PauseSchedule.shouldResume(p, now: s.addingTimeInterval(-86400 * 365)))
    }

    func testClockSetBackAfterPauseBeganIsCappedByMaxSpan() {
        // A one-hour pause that appears to have 3 days left means the clock moved; don't stay off for 3 days.
        let s = at("2026-06-10T12:00:00Z")
        let far = PauseState(since: s, until: s.addingTimeInterval(PauseSchedule.maxSpan + 1))
        XCTAssertTrue(PauseSchedule.shouldResume(far, now: s))
        let ok = PauseState(since: s, until: s.addingTimeInterval(PauseSchedule.maxSpan))
        XCTAssertFalse(PauseSchedule.shouldResume(ok, now: s))
    }

    func testTomorrowPauseAcrossDSTNeverLooksLikeAClockJump() {
        let c = cal(ny)
        for start in ["2026-11-01T04:00:00Z", "2026-03-08T05:00:00Z", "2026-03-07T05:00:00Z", "2026-11-02T05:00:00Z"] {
            let p = PauseSchedule.state(.untilTomorrow, from: at(start), calendar: c)
            XCTAssertFalse(PauseSchedule.shouldResume(p, now: p.since), start)
        }
    }

    func testStateRoundTripsThroughJSON() throws {
        let p = PauseSchedule.state(.untilTomorrow, from: at("2026-06-10T12:00:00Z"), calendar: cal(ny))
        XCTAssertEqual(try JSONDecoder().decode(PauseState.self, from: JSONEncoder().encode(p)), p)
    }

    func testDescribe() {
        let c = cal("UTC")
        let now = at("2026-06-10T12:00:00Z")
        XCTAssertEqual(PauseSchedule.describe(PauseState(since: now, until: nil), calendar: c, now: now), "until you turn it back on")
        XCTAssertTrue(PauseSchedule.describe(PauseSchedule.state(.oneHour, from: now, calendar: c), calendar: c, now: now).hasPrefix("until "))
    }
}
