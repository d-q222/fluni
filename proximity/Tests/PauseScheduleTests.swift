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

    func testUntilTomorrowIs6AMTomorrowAfterSix() {
        let c = cal(ny)
        let end = PauseSchedule.until(.untilTomorrow, from: at("2026-06-10T15:00:00Z"), calendar: c)!  // 11:00 EDT
        XCTAssertEqual(end, at("2026-06-11T10:00:00Z"))  // 06:00 EDT on the 11th
        XCTAssertEqual(c.dateComponents([.hour, .minute], from: end).hour, 6)
    }

    func testBeforeSixItEndsAt6AMToday() {
        let c = cal(ny)
        // 00:00 EDT, 02:30 EDT and 05:59:59 EDT all end at 06:00 EDT the same day.
        for now in ["2026-06-11T04:00:00Z", "2026-06-11T06:30:00Z", "2026-06-11T09:59:59Z"] {
            XCTAssertEqual(PauseSchedule.until(.untilTomorrow, from: at(now), calendar: c), at("2026-06-11T10:00:00Z"), now)
        }
    }

    func testExactlySixAMEndsTomorrowAtSix() {
        let end = PauseSchedule.until(.untilTomorrow, from: at("2026-06-11T10:00:00Z"), calendar: cal(ny))!
        XCTAssertEqual(end, at("2026-06-12T10:00:00Z"))
    }

    func testUntilTomorrowOnTheSpringForwardDay() {
        // 2026-03-08 is 23 h in New York (EST until 02:00, EDT after). 06:00 EDT = 10:00Z.
        let c = cal(ny)
        // Noon EDT on the 8th -> 06:00 EDT on the 9th.
        XCTAssertEqual(PauseSchedule.until(.untilTomorrow, from: at("2026-03-08T16:00:00Z"), calendar: c), at("2026-03-09T10:00:00Z"))
        // 01:00 EST on the 8th (before the jump) -> 06:00 EDT the same day, only 4 h later.
        let early = at("2026-03-08T06:00:00Z")
        XCTAssertEqual(PauseSchedule.until(.untilTomorrow, from: early, calendar: c), at("2026-03-08T10:00:00Z"))
        // 23:00 EST on the 7th -> 06:00 EDT on the 8th.
        XCTAssertEqual(PauseSchedule.until(.untilTomorrow, from: at("2026-03-08T04:00:00Z"), calendar: c), at("2026-03-08T10:00:00Z"))
        // Sat 7th noon EST -> Sun 8th 06:00 EDT.
        XCTAssertEqual(PauseSchedule.until(.untilTomorrow, from: at("2026-03-07T17:00:00Z"), calendar: c), at("2026-03-08T10:00:00Z"))
    }

    func testUntilTomorrowOnTheFallBackDay() {
        // 2026-11-01 is 25 h in New York. 06:00 EST = 11:00Z.
        let c = cal(ny)
        let now = at("2026-11-01T11:00:00Z")  // exactly 06:00 EST on the 1st
        let end = PauseSchedule.until(.untilTomorrow, from: now, calendar: c)!
        XCTAssertEqual(end, at("2026-11-02T11:00:00Z"))
        XCTAssertEqual(end.timeIntervalSince(now), 24 * 3600)
        // Paused at 06:00 EDT on Oct 31 (10:00Z) spans the 25 h day: the longest case.
        let long = at("2026-10-31T10:00:00Z")
        let longEnd = PauseSchedule.until(.untilTomorrow, from: long, calendar: c)!
        XCTAssertEqual(longEnd, at("2026-11-01T11:00:00Z"))
        XCTAssertEqual(longEnd.timeIntervalSince(long), 25 * 3600)
        XCTAssertLessThan(longEnd.timeIntervalSince(long), PauseSchedule.maxSpan)
    }

    func testTimeZoneDecidesWhichSixAM() {
        let now = at("2026-06-10T23:30:00Z")
        XCTAssertEqual(PauseSchedule.until(.untilTomorrow, from: now, calendar: cal("UTC")), at("2026-06-11T06:00:00Z"))
        XCTAssertEqual(PauseSchedule.until(.untilTomorrow, from: now, calendar: cal("Pacific/Auckland")), at("2026-06-11T18:00:00Z"))
    }

    func testSaoPauloDSTDayStillEndsAtSix() {
        // Sao Paulo used to skip 00:00 on DST day; 6 AM exists but check anyway (2018-11-04: clocks 00:00 -> 01:00).
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
        for start in ["2026-10-31T10:00:00Z", "2026-11-01T04:00:00Z", "2026-03-08T05:00:00Z", "2026-03-07T05:00:00Z", "2026-11-02T05:00:00Z"] {
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
