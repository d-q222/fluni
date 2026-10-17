import XCTest
@testable import FluniProx

final class LiveClockTests: XCTestCase {
    private let la = TimeZone(identifier: "America/Los_Angeles")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func cal(_ tz: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0, tz: TimeZone? = nil) -> Date {
        let tz = tz ?? la
        return cal(tz).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: s))!
    }
    private func sim(_ iso: String) -> Double { PSickFeed.simSeconds(iso: iso)! }
    private func run(_ a: String, _ b: String) -> ClosedRange<Double> { sim(a)...sim(b) }

    /// The default run: 14 days from Monday 2026-01-05, 15-minute steps.
    private var twoWeeks: ClosedRange<Double> { run("2026-01-05T00:00:00", "2026-01-18T23:45:00") }

    private func at(_ now: Date, _ r: ClosedRange<Double>, tz: TimeZone? = nil) -> Double {
        LiveClock.simTime(now: now, calendar: cal(tz ?? la), run: r)
    }

    func testSaturdayFourThirtyMapsToFirstSaturday() {
        // Sat 2026-10-17 16:30 -> first run Saturday 2026-01-10 16:30
        XCTAssertEqual(at(date(2026, 10, 17, 16, 30), twoWeeks), sim("2026-01-10T16:30:00"))
    }

    func testEveryWeekdayMidnightAndLastMinute() {
        // 2026-10-12 is a Monday. Run Monday 2026-01-05 -> run days 5..11 Jan for Mon..Sun.
        for i in 0..<7 {
            let runDay = String(format: "2026-01-%02d", 5 + i)
            XCTAssertEqual(at(date(2026, 10, 12 + i, 0, 0, 0), twoWeeks), sim("\(runDay)T00:00:00"), "midnight, weekday \(i)")
            XCTAssertEqual(at(date(2026, 10, 12 + i, 23, 59, 59), twoWeeks), sim("\(runDay)T23:59:59"), "23:59:59, weekday \(i)")
            XCTAssertEqual(at(date(2026, 10, 12 + i, 23, 59, 0), twoWeeks), sim("\(runDay)T23:59:00"), "23:59, weekday \(i)")
        }
    }

    func testSameWeekdayInDifferentWeeksGivesSameMoment() {
        XCTAssertEqual(at(date(2026, 10, 14, 9, 5), twoWeeks), at(date(2027, 3, 3, 9, 5), twoWeeks))
    }

    func testAdvancesInRealTime() {
        let a = at(date(2026, 10, 17, 16, 30, 0), twoWeeks)
        XCTAssertEqual(at(date(2026, 10, 17, 16, 30, 45), twoWeeks) - a, 45, accuracy: 1e-6)
        XCTAssertEqual(at(date(2026, 10, 17, 16, 30, 0).addingTimeInterval(0.5), twoWeeks) - a, 0.5, accuracy: 1e-6)
    }

    func testRunStartingMidWeek() {
        // Wednesday 2026-01-07 start, 7 days (Wed..Tue). Saturday -> Sat 2026-01-10; Monday -> Mon 2026-01-12.
        let r = run("2026-01-07T00:00:00", "2026-01-13T23:45:00")
        XCTAssertEqual(at(date(2026, 10, 14, 8, 0), r), sim("2026-01-07T08:00:00"))   // Wed = day 0
        XCTAssertEqual(at(date(2026, 10, 17, 16, 30), r), sim("2026-01-10T16:30:00"))
        XCTAssertEqual(at(date(2026, 10, 12, 12, 0), r), sim("2026-01-12T12:00:00"))   // Mon
        XCTAssertEqual(at(date(2026, 10, 13, 23, 59), r), r.upperBound)  // Tue, last day: clamped to the last step
    }

    func testRunStartingMidWeekAndLongerThanAWeekUsesFirstMatch() {
        // 10 days from Wednesday 2026-01-07: a Wednesday is run day 0, not day 7.
        let r = run("2026-01-07T00:00:00", "2026-01-16T23:45:00")
        XCTAssertEqual(at(date(2026, 10, 14, 10, 0), r), sim("2026-01-07T10:00:00"))
    }

    func testRunShorterThanAWeekUsesModRule() {
        // Mon-Tue run (2 days). Weekdays it has: Mon, Tue. Others: daysSinceMonday mod 2.
        let r = run("2026-01-05T00:00:00", "2026-01-06T23:45:00")
        XCTAssertEqual(at(date(2026, 10, 12, 7, 0), r), sim("2026-01-05T07:00:00"))   // Mon
        XCTAssertEqual(at(date(2026, 10, 13, 7, 0), r), sim("2026-01-06T07:00:00"))   // Tue
        XCTAssertEqual(at(date(2026, 10, 14, 7, 0), r), sim("2026-01-05T07:00:00"))   // Wed: 2 mod 2 = 0
        XCTAssertEqual(at(date(2026, 10, 15, 7, 0), r), sim("2026-01-06T07:00:00"))   // Thu: 3 mod 2 = 1
        XCTAssertEqual(at(date(2026, 10, 17, 16, 55), r), sim("2026-01-06T16:55:00"))  // Sat: 5 mod 2 = 1
        XCTAssertEqual(at(date(2026, 10, 18, 16, 55), r), sim("2026-01-05T16:55:00"))  // Sun: 6 mod 2 = 0
    }

    func testThreeDayRunStartingWednesday() {
        // Wed-Fri. Monday has no match: 0 mod 3 = run day 0 (Wed). Sunday: 6 mod 3 = 0. Saturday: 5 mod 3 = 2 (Fri).
        let r = run("2026-01-07T00:00:00", "2026-01-09T23:45:00")
        XCTAssertEqual(at(date(2026, 10, 12, 9, 0), r), sim("2026-01-07T09:00:00"))
        XCTAssertEqual(at(date(2026, 10, 17, 9, 0), r), sim("2026-01-09T09:00:00"))
        XCTAssertEqual(at(date(2026, 10, 18, 9, 0), r), sim("2026-01-07T09:00:00"))
    }

    func testSingleDayRun() {
        let r = run("2026-01-07T06:00:00", "2026-01-07T22:00:00")
        for d in 12...18 {
            let v = at(date(2026, 10, d, 12, 0), r)
            XCTAssertTrue(r.contains(v)); XCTAssertEqual(v, sim("2026-01-07T12:00:00"))
        }
    }

    func testClampsToFirstAndLastStep() {
        let r = run("2026-01-05T08:00:00", "2026-01-18T20:00:00")
        XCTAssertEqual(at(date(2026, 10, 12, 3, 0), r), r.lowerBound)      // before the first step on day 0
        XCTAssertEqual(at(date(2026, 10, 18, 23, 59), r), sim("2026-01-11T23:59:00")) // inside, not clamped
        // Last run day is Sunday 18th, but the first Sunday is the 11th, so reach the end via a short run.
        let s = run("2026-01-05T08:00:00", "2026-01-05T20:00:00")
        XCTAssertEqual(at(date(2026, 10, 12, 23, 0), s), s.upperBound)
    }

    func testSpringForwardDay() {
        // 2026-03-08 (Sunday) in Los Angeles: 02:00 -> 03:00. The wall clock skips an hour.
        let before = date(2026, 3, 8, 1, 59, 59)
        let after = date(2026, 3, 8, 3, 0, 0)
        XCTAssertEqual(after.timeIntervalSince(before), 1, accuracy: 1e-6)  // one real second apart
        XCTAssertEqual(at(before, twoWeeks), sim("2026-01-11T01:59:59"))
        XCTAssertEqual(at(after, twoWeeks), sim("2026-01-11T03:00:00"))
        // Still the right weekday and monotonic across the gap; the end of the day is 23:59.
        XCTAssertLessThan(at(before, twoWeeks), at(after, twoWeeks))
        XCTAssertEqual(at(date(2026, 3, 8, 23, 59, 59), twoWeeks), sim("2026-01-11T23:59:59"))
    }

    func testFallBackDay() {
        // 2026-11-01 (Sunday): 02:00 PDT -> 01:00 PST. 01:30 happens twice.
        let first = Date(timeIntervalSince1970: 1_793_521_800)  // 2026-11-01T08:30:00Z = 01:30 PDT
        XCTAssertEqual(cal(la).component(.hour, from: first), 1)
        let second = first.addingTimeInterval(3600)                          // 01:30 PST
        XCTAssertEqual(at(first, twoWeeks), sim("2026-01-11T01:30:00"))
        XCTAssertEqual(at(second, twoWeeks), sim("2026-01-11T01:30:00"))    // the repeated hour reads the same moment
        XCTAssertEqual(at(second.addingTimeInterval(1800), twoWeeks), sim("2026-01-11T02:00:00"))
        XCTAssertEqual(at(date(2026, 11, 1, 23, 59, 59), twoWeeks), sim("2026-01-11T23:59:59"))
        XCTAssertEqual(at(date(2026, 11, 1, 0, 0, 0), twoWeeks), sim("2026-01-11T00:00:00"))
    }

    func testTimeZoneChange() {
        // The same instant is Saturday 16:30 in Los Angeles and Sunday 08:30 in Tokyo (PDT is UTC-7).
        let now = date(2026, 10, 17, 16, 30)
        XCTAssertEqual(at(now, twoWeeks, tz: la), sim("2026-01-10T16:30:00"))
        XCTAssertEqual(at(now, twoWeeks, tz: tokyo), sim("2026-01-11T08:30:00"))
        // Back again: nothing is remembered.
        XCTAssertEqual(at(now, twoWeeks, tz: la), sim("2026-01-10T16:30:00"))
    }

    func testSystemClockJumpingBackwards() {
        let t1 = date(2026, 10, 17, 16, 30)
        let a = at(t1, twoWeeks)
        // Clock set back a day and a half: the answer follows, and is exactly that much earlier in sim time.
        let t2 = t1.addingTimeInterval(-36 * 3600)
        let b = at(t2, twoWeeks)
        XCTAssertEqual(b, sim("2026-01-09T04:30:00"))
        XCTAssertEqual(a - b, 36 * 3600, accuracy: 1e-6)
        // Set back across the start of the weekly cycle: Monday 00:00 minus 1 s is Sunday 23:59:59.
        XCTAssertEqual(at(date(2026, 10, 12, 0, 0, 0).addingTimeInterval(-1), twoWeeks), sim("2026-01-11T23:59:59"))
        // Pure: asking again after the jump gives the earlier answer unchanged.
        XCTAssertEqual(at(t1, twoWeeks), a)
    }

    func testResultAlwaysInsideTheRun() {
        let runs = [twoWeeks, run("2026-01-07T00:00:00", "2026-01-09T23:45:00"), run("2026-01-05T08:00:00", "2026-01-05T20:00:00")]
        var now = date(2026, 1, 1)
        for _ in 0..<2000 {
            for r in runs { XCTAssertTrue(r.contains(LiveClock.simTime(now: now, calendar: cal(la), run: r))) }
            now = now.addingTimeInterval(5 * 3600 + 1234)
        }
    }

    func testTimeTextFollowsLocale() {
        let t = sim("2026-01-10T16:30:00")
        XCTAssertTrue(LiveClock.timeText(t, locale: Locale(identifier: "en_US")).hasPrefix("4:30"))
        XCTAssertEqual(LiveClock.timeText(t, locale: Locale(identifier: "de_DE")), "16:30")
    }
}
