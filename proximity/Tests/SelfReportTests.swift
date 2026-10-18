import XCTest
@testable import FluniProx

/// Self-report rules with a fixed calendar (America/Los_Angeles, Gregorian), so day counts across midnight
/// and DST never depend on the machine running the tests. DST 2026: clocks go forward Sun 8 Mar 02:00 and
/// back Sun 1 Nov 02:00.
final class SelfReportTests: XCTestCase {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    private var sr: SelfReporter { SelfReporter(calendar: cal) }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: s))!
    }

    /// Symptomatic (no fever) with onset 10 Oct 2026, reported that evening.
    private func sick(onset: Date? = nil) throws -> SelfReportRecord {
        try sr.reportSymptoms(SelfReportRecord(), symptoms: [.cough], onset: onset ?? at(2026, 10, 10), now: at(2026, 10, 10, 20))
    }

    // MARK: day boundaries

    func testDayNumberChangesAtMidnightExactly() throws {
        let r = try sick()
        XCTAssertEqual(sr.dayNumber(r, now: at(2026, 10, 10, 0, 0, 0)), 0)
        XCTAssertEqual(sr.dayNumber(r, now: at(2026, 10, 10, 23, 59, 59)), 0)
        XCTAssertEqual(sr.dayNumber(r, now: at(2026, 10, 11, 0, 0, 0)), 1)
    }

    func testOnsetTimeOfDayIsIgnored() throws {
        let r = try sr.reportSymptoms(SelfReportRecord(), symptoms: [.aches], onset: at(2026, 10, 10, 23, 30), now: at(2026, 10, 11, 8))
        XCTAssertEqual(r.onset, at(2026, 10, 10))
        XCTAssertEqual(sr.dayNumber(r, now: at(2026, 10, 11, 0, 5)), 1)
    }

    func testSpringForwardDayIsStillOneDay() throws {
        // 8 Mar is 23 hours long. Onset 7 Mar.
        let r = try sr.reportSymptoms(SelfReportRecord(), symptoms: [.cough], onset: at(2026, 3, 7), now: at(2026, 3, 7, 12))
        XCTAssertEqual(sr.dayNumber(r, now: at(2026, 3, 8, 0, 0)), 1)
        XCTAssertEqual(sr.dayNumber(r, now: at(2026, 3, 8, 23, 59, 59)), 1)
        XCTAssertEqual(sr.dayNumber(r, now: at(2026, 3, 9, 0, 0)), 2)
    }

    func testFallBackDayIsStillOneDay() throws {
        // 1 Nov is 25 hours long. Onset 31 Oct.
        let r = try sr.reportSymptoms(SelfReportRecord(), symptoms: [.cough], onset: at(2026, 10, 31), now: at(2026, 10, 31, 12))
        XCTAssertEqual(sr.dayNumber(r, now: at(2026, 11, 1, 0, 0)), 1)
        XCTAssertEqual(sr.dayNumber(r, now: at(2026, 11, 1, 23, 30)), 1)  // 24 h after midnight is still 1 Nov (25 h day)
        XCTAssertEqual(sr.dayNumber(r, now: at(2026, 11, 2, 0, 0)), 2)
    }

    func testPeriodEndIsLocalMidnightOfDaySixAcrossDST() throws {
        // Onset 30 Oct, day 6 is 5 Nov (after the fall-back): end must be 5 Nov 00:00 local, not 23:00 on the 4th.
        let r = try sr.reportSymptoms(SelfReportRecord(), symptoms: [.cough], onset: at(2026, 10, 30), now: at(2026, 10, 30, 9))
        XCTAssertEqual(sr.periodEnd(r), at(2026, 11, 5))
        XCTAssertEqual(sr.phase(r, now: at(2026, 11, 4, 23, 59, 59)), .inProgress(day: 5, lastDay: at(2026, 11, 4)))
        XCTAssertEqual(sr.phase(r, now: at(2026, 11, 5, 0, 0, 0)), .periodOver(feverFree: true))
        // And across spring-forward: onset 5 Mar -> end 11 Mar 00:00.
        let s = try sr.reportSymptoms(SelfReportRecord(), symptoms: [.cough], onset: at(2026, 3, 5), now: at(2026, 3, 5, 9))
        XCTAssertEqual(sr.periodEnd(s), at(2026, 3, 11))
    }

    // MARK: the 5-day boundary

    func testFiveDayBoundaryIsExact() throws {
        let r = try sick()  // day 0 = 10 Oct, so day 5 = 15 Oct, day 6 = 16 Oct
        XCTAssertEqual(sr.phase(r, now: at(2026, 10, 15, 23, 59, 59)), .inProgress(day: 5, lastDay: at(2026, 10, 15)))
        XCTAssertFalse(sr.shouldPromptToUpdate(r, now: at(2026, 10, 15, 23, 59, 59)))
        XCTAssertEqual(sr.phase(r, now: at(2026, 10, 16, 0, 0, 0)), .periodOver(feverFree: true))
        XCTAssertTrue(sr.shouldPromptToUpdate(r, now: at(2026, 10, 16, 0, 0, 0)))
        XCTAssertEqual(IsolationPolicy.days, 5)
    }

    func testPositiveTestWithNoSymptomsCountsFromTestDay() throws {
        let r = try sr.reportPositive(SelfReportRecord(), kind: .rapid, date: at(2026, 10, 10, 15), now: at(2026, 10, 10, 15))
        XCTAssertEqual(r.risk, .contagious)
        XCTAssertEqual(sr.phase(r, now: at(2026, 10, 15, 23, 59, 59)), .inProgress(day: 5, lastDay: at(2026, 10, 15)))
        XCTAssertEqual(sr.phase(r, now: at(2026, 10, 16)), .periodOver(feverFree: true))
    }

    func testEarlierOnsetPullsDayZeroEarlier() throws {
        // Symptoms from 8 Oct, positive test on 10 Oct: counted from 8 Oct.
        var r = try sr.reportSymptoms(SelfReportRecord(), symptoms: [.cough], onset: at(2026, 10, 8), now: at(2026, 10, 10, 9))
        r = try sr.reportPositive(r, kind: .pcr, date: at(2026, 10, 10), now: at(2026, 10, 10, 10))
        XCTAssertEqual(r.dayZero, at(2026, 10, 8))
        XCTAssertEqual(sr.dayNumber(r, now: at(2026, 10, 10, 11)), 2)
    }

    func testNoStatusMeansNoIsolation() {
        XCTAssertEqual(sr.phase(SelfReportRecord(), now: at(2026, 10, 10)), .notIsolating)
        XCTAssertNil(sr.dayNumber(SelfReportRecord(), now: at(2026, 10, 10)))
        XCTAssertFalse(sr.checkInDue(SelfReportRecord(), now: at(2026, 10, 10)))
    }

    // MARK: fever-free rule

    func testFeverFreeIsExactly24Hours() throws {
        // Fever reported 15 Oct 18:00 (past the 5 days at 16 Oct 00:00, but fever clock still running).
        var r = try sick()
        r = sr.checkIn(r, stillSymptomatic: true, hasFever: true, now: at(2026, 10, 15, 18))
        XCTAssertEqual(r.lastFeverAt, at(2026, 10, 15, 18))
        XCTAssertEqual(sr.phase(r, now: at(2026, 10, 16, 0)), .periodOver(feverFree: false))
        XCTAssertEqual(sr.phase(r, now: at(2026, 10, 16, 17, 59, 59)), .periodOver(feverFree: false))
        XCTAssertFalse(sr.shouldPromptToUpdate(r, now: at(2026, 10, 16, 17, 59, 59)))
        XCTAssertEqual(sr.phase(r, now: at(2026, 10, 16, 18, 0, 0)), .periodOver(feverFree: true))
        XCTAssertTrue(sr.shouldPromptToUpdate(r, now: at(2026, 10, 16, 18, 0, 0)))
    }

    func testFeverSymptomStartsTheFeverClock() throws {
        let r = try sr.reportSymptoms(SelfReportRecord(), symptoms: [.fever, .cough], onset: at(2026, 10, 10), now: at(2026, 10, 10, 20))
        XCTAssertEqual(r.lastFeverAt, at(2026, 10, 10, 20))
        XCTAssertFalse(sr.isFeverFree(r, now: at(2026, 10, 11, 19, 59, 59)))
        XCTAssertTrue(sr.isFeverFree(r, now: at(2026, 10, 11, 20, 0, 0)))
    }

    func testFeverFreeIs24HoursOfElapsedTimeAcrossDST() {
        // Fever at 31 Oct 23:00 PDT; 1 Nov has 25 hours, so 24 elapsed hours later is 22:00 on 1 Nov.
        var r = SelfReportRecord(); r.risk = .possible; r.lastFeverAt = at(2026, 10, 31, 23)
        let exactly24h = r.lastFeverAt!.addingTimeInterval(24 * 3600)
        XCTAssertEqual(cal.component(.hour, from: exactly24h), 22)  // 25-hour day: 23:00 + 24 h = 22:00 next day
        XCTAssertFalse(sr.isFeverFree(r, now: exactly24h.addingTimeInterval(-1)))
        XCTAssertTrue(sr.isFeverFree(r, now: exactly24h))
    }

    func testCheckInWithFeverRestartsTheClockAndNoFeverDoesNot() throws {
        var r = try sr.reportSymptoms(SelfReportRecord(), symptoms: [.fever], onset: at(2026, 10, 10), now: at(2026, 10, 10, 8))
        r = sr.checkIn(r, stillSymptomatic: true, hasFever: false, now: at(2026, 10, 11, 8))
        XCTAssertEqual(r.lastFeverAt, at(2026, 10, 10, 8))
        r = sr.checkIn(r, stillSymptomatic: true, hasFever: true, now: at(2026, 10, 12, 8))
        XCTAssertEqual(r.lastFeverAt, at(2026, 10, 12, 8))
    }

    // MARK: status transitions

    func testRapidNegativeNeverClearsAPositive() throws {
        var r = try sr.reportPositive(SelfReportRecord(), kind: .rapid, date: at(2026, 10, 10), now: at(2026, 10, 10, 9))
        XCTAssertEqual(try sr.reportNegative(r, kind: .rapid, date: at(2026, 10, 11), now: at(2026, 10, 11, 9)), r)
        // Same with symptoms on top of the positive.
        r = try sr.reportSymptoms(r, symptoms: [.cough], onset: at(2026, 10, 9), now: at(2026, 10, 10, 10))
        XCTAssertEqual(try sr.reportNegative(r, kind: .rapid, date: at(2026, 10, 10), now: at(2026, 10, 10, 11)).risk, .contagious)
    }

    func testPCRDatedBeforeThePositiveDoesNotClearIt() throws {
        let r = try sr.reportPositive(SelfReportRecord(), kind: .rapid, date: at(2026, 10, 10), now: at(2026, 10, 11, 9))
        let after = try sr.reportNegative(r, kind: .pcr, date: at(2026, 10, 9, 23, 59), now: at(2026, 10, 11, 9))
        XCTAssertEqual(after, r)
    }

    func testPCRNegativeOnOrAfterThePositiveDayClearsIt() throws {
        let r = try sr.reportPositive(SelfReportRecord(), kind: .rapid, date: at(2026, 10, 10, 15), now: at(2026, 10, 10, 15))
        // Same day (even earlier in the day) and a later day both count.
        XCTAssertEqual(try sr.reportNegative(r, kind: .pcr, date: at(2026, 10, 10, 8), now: at(2026, 10, 10, 16)), SelfReportRecord())
        XCTAssertEqual(try sr.reportNegative(r, kind: .pcr, date: at(2026, 10, 12), now: at(2026, 10, 12, 9)), SelfReportRecord())
    }

    func testPCRNegativeKeepsSymptomsState() throws {
        var r = try sr.reportSymptoms(SelfReportRecord(), symptoms: [.fever, .cough], onset: at(2026, 10, 9), now: at(2026, 10, 9, 20))
        r = try sr.reportPositive(r, kind: .pcr, date: at(2026, 10, 10), now: at(2026, 10, 10, 9))
        let now = at(2026, 10, 11, 9)
        let after = try sr.reportNegative(r, kind: .pcr, date: at(2026, 10, 11), now: now)
        XCTAssertEqual(after.risk, .possible)
        XCTAssertNil(after.positiveKind)
        XCTAssertNil(after.positiveDate)
        XCTAssertEqual(after.symptoms, [.fever, .cough])
        XCTAssertEqual(after.onset, at(2026, 10, 9))
        XCTAssertEqual(after.dayZero, at(2026, 10, 9))
        // The fever clock still holds you at home.
        XCTAssertEqual(after.lastFeverAt, r.lastFeverAt)
        XCTAssertFalse(sr.isFeverFree(after, now: at(2026, 10, 10, 1)))
    }

    func testPCRNegativeWithoutSymptomsGoesBackToNone() throws {
        let r = try sr.reportPositive(SelfReportRecord(), kind: .pcr, date: at(2026, 10, 10), now: at(2026, 10, 10, 9))
        let after = try sr.reportNegative(r, kind: .pcr, date: at(2026, 10, 10), now: at(2026, 10, 10, 12))
        XCTAssertEqual(after.risk, .none)
        XCTAssertNil(after.dayZero)
        XCTAssertNil(sr.dayNumber(after, now: at(2026, 10, 10, 12)))
    }

    func testRecordWithClearedPositiveRoundTripsAndOldJSONStillDecodes() throws {
        var r = try sr.reportSymptoms(SelfReportRecord(), symptoms: [.cough], onset: at(2026, 10, 9), now: at(2026, 10, 9, 20))
        r = try sr.reportPositive(r, kind: .pcr, date: at(2026, 10, 10), now: at(2026, 10, 10, 9))
        let cleared = try sr.reportNegative(r, kind: .pcr, date: at(2026, 10, 10), now: at(2026, 10, 10, 12))
        for rec in [r, cleared] {
            XCTAssertEqual(try JSONDecoder().decode(SelfReportRecord.self, from: JSONEncoder().encode(rec)), rec)
        }
        // A record saved before this change (no new fields were added, but keep that promise honest).
        let old = #"{"risk":1,"symptoms":["cough"]}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(SelfReportRecord.self, from: old).risk, .possible)
    }

    func testNegativeClearsPossibleOnOrAfterOnsetOnly() throws {
        let r = try sick()  // onset 10 Oct
        XCTAssertEqual(try sr.reportNegative(r, kind: .rapid, date: at(2026, 10, 10), now: at(2026, 10, 10, 21)), SelfReportRecord())
        XCTAssertEqual(try sr.reportNegative(r, kind: .pcr, date: at(2026, 10, 9, 23, 59), now: at(2026, 10, 10, 21)), r)
    }

    func testNegativeWhenHealthyChangesNothing() throws {
        let r = try sr.reportNegative(SelfReportRecord(), kind: .rapid, date: at(2026, 10, 10), now: at(2026, 10, 10, 9))
        XCTAssertEqual(r, SelfReportRecord())
    }

    func testFutureDatesAreRejected() {
        let now = at(2026, 10, 17, 12)
        XCTAssertThrowsError(try sr.reportSymptoms(SelfReportRecord(), symptoms: [.cough], onset: at(2026, 10, 18), now: now)) {
            XCTAssertEqual($0 as? ReportError, .dateInFuture)
        }
        XCTAssertThrowsError(try sr.reportPositive(SelfReportRecord(), kind: .rapid, date: at(2026, 10, 18), now: now)) {
            XCTAssertEqual($0 as? ReportError, .dateInFuture)
        }
        XCTAssertThrowsError(try sr.reportNegative(SelfReportRecord(), kind: .rapid, date: at(2026, 10, 18), now: now)) {
            XCTAssertEqual($0 as? ReportError, .dateInFuture)
        }
        // Later today is fine (only the calendar day matters); a day ahead by one second is not.
        XCTAssertNoThrow(try sr.reportSymptoms(SelfReportRecord(), symptoms: [.cough], onset: at(2026, 10, 17, 23, 59, 59), now: now))
        XCTAssertThrowsError(try sr.reportSymptoms(SelfReportRecord(), symptoms: [.cough], onset: at(2026, 10, 18, 0, 0, 0), now: now))
    }

    func testSymptomsNeedAtLeastOne() {
        XCTAssertThrowsError(try sr.reportSymptoms(SelfReportRecord(), symptoms: [], onset: at(2026, 10, 10), now: at(2026, 10, 10, 9))) {
            XCTAssertEqual($0 as? ReportError, .noSymptoms)
        }
    }

    func testAnySingleSymptomMeansPossible() throws {
        for s in Symptom.allCases {
            let r = try sr.reportSymptoms(SelfReportRecord(), symptoms: [s], onset: at(2026, 10, 10), now: at(2026, 10, 10, 9))
            XCTAssertEqual(r.risk, .possible, "\(s)")
        }
        XCTAssertEqual(Symptom.allCases.count, 6)
    }

    func testSymptomsNeverDowngradeContagious() throws {
        let p = try sr.reportPositive(SelfReportRecord(), kind: .pcr, date: at(2026, 10, 10), now: at(2026, 10, 10, 9))
        let r = try sr.reportSymptoms(p, symptoms: [.fatigue], onset: at(2026, 10, 10), now: at(2026, 10, 10, 10))
        XCTAssertEqual(r.risk, .contagious)
        XCTAssertEqual(r.positiveDate, at(2026, 10, 10))
    }

    func testContagiousCannotBeClearedEarlyOrWithFever() throws {
        let p = try sr.reportPositive(SelfReportRecord(), kind: .rapid, date: at(2026, 10, 10), now: at(2026, 10, 10, 9))
        XCTAssertThrowsError(try sr.reportFine(p, now: at(2026, 10, 15, 23, 59, 59))) {
            XCTAssertEqual($0 as? ReportError, .notYetClearable)
        }
        XCTAssertEqual(try sr.reportFine(p, now: at(2026, 10, 16)), SelfReportRecord())
        let feverish = sr.checkIn(p, stillSymptomatic: true, hasFever: true, now: at(2026, 10, 15, 20))
        XCTAssertThrowsError(try sr.reportFine(feverish, now: at(2026, 10, 16, 12)))
        XCTAssertNoThrow(try sr.reportFine(feverish, now: at(2026, 10, 16, 20)))
    }

    func testPossibleCanBeClearedAnyTime() throws {
        XCTAssertEqual(try sr.reportFine(try sick(), now: at(2026, 10, 10, 21)), SelfReportRecord())
    }

    func testCheckInNoSymptomsClearsPossibleButNotContagious() throws {
        XCTAssertEqual(sr.checkIn(try sick(), stillSymptomatic: false, hasFever: false, now: at(2026, 10, 11, 9)), SelfReportRecord())
        let p = try sr.reportPositive(SelfReportRecord(), kind: .rapid, date: at(2026, 10, 10), now: at(2026, 10, 10, 9))
        let c = sr.checkIn(p, stillSymptomatic: false, hasFever: false, now: at(2026, 10, 11, 9))
        XCTAssertEqual(c.risk, .contagious)
        XCTAssertEqual(c.lastCheckIn, at(2026, 10, 11, 9))
    }

    func testPeriodEndNeverClearsAnythingByItself() throws {
        let p = try sr.reportPositive(SelfReportRecord(), kind: .rapid, date: at(2026, 10, 10), now: at(2026, 10, 10, 9))
        // Nothing in SelfReporter mutates a record on read: a month later it is still contagious and merely prompts.
        XCTAssertEqual(p.risk, .contagious)
        XCTAssertTrue(sr.shouldPromptToUpdate(p, now: at(2026, 11, 20)))
        XCTAssertEqual(sr.reconciled(p, risk: .contagious, setAt: at(2026, 10, 10)), p)
    }

    // MARK: daily check-in and reconciliation

    func testCheckInDueOncePerCalendarDay() throws {
        let r = try sick()  // reported 10 Oct 20:00
        XCTAssertFalse(sr.checkInDue(r, now: at(2026, 10, 10, 23, 59, 59)))
        XCTAssertTrue(sr.checkInDue(r, now: at(2026, 10, 11, 0, 0, 0)))
        let done = sr.checkIn(r, stillSymptomatic: true, hasFever: false, now: at(2026, 10, 11, 0, 1))
        XCTAssertFalse(sr.checkInDue(done, now: at(2026, 10, 11, 23, 59)))
        XCTAssertTrue(sr.checkInDue(done, now: at(2026, 10, 12)))
    }

    func testReconcileWithModelStatus() throws {
        let r = try sick()
        XCTAssertEqual(sr.reconciled(r, risk: .none, setAt: nil), SelfReportRecord())
        let adopted = sr.reconciled(SelfReportRecord(), risk: .possible, setAt: at(2026, 10, 12, 15))
        XCTAssertEqual(adopted.risk, .possible)
        XCTAssertEqual(adopted.onset, at(2026, 10, 12))
        XCTAssertEqual(sr.reconciled(r, risk: .possible, setAt: at(2026, 10, 12)), r)
    }

    func testRecordRoundTripsThroughJSON() throws {
        var r = try sr.reportSymptoms(SelfReportRecord(), symptoms: [.fever, .cough], onset: at(2026, 10, 10), now: at(2026, 10, 10, 9))
        r = try sr.reportPositive(r, kind: .pcr, date: at(2026, 10, 11), now: at(2026, 10, 11, 9))
        let back = try JSONDecoder().decode(SelfReportRecord.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
    }
}
