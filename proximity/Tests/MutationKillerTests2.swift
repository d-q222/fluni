import XCTest
@testable import FluniProx

/// Second mutation-testing round. Every expected value is a literal from the spec (README / doc comments),
/// never read back from the code under test.
final class MutationKillerTests2: XCTestCase {
    private func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private typealias Contact = (pClose: Double, risk: Risk)

    // MARK: SelfReport

    // reconciled(): the model says "healthy" -> the stored record is wiped completely, whatever setAt is.
    func testReconcileToNoneWipesTheWholeRecord() {
        let day = d("2026-03-02T00:00:00Z")
        let r = SelfReportRecord(risk: .contagious, symptoms: [.cough], onset: day, positiveKind: .pcr,
                                 positiveDate: day, lastFeverAt: day, lastCheckIn: day)
        let out = SelfReporter(calendar: utc).reconciled(r, risk: .none, setAt: d("2026-03-04T10:00:00Z"))
        XCTAssertEqual(out, SelfReportRecord())
        XCTAssertNil(out.lastCheckIn)
    }

    // "Fever resets the 24 h clock" only for someone who still has symptoms.
    func testFeverWithoutSymptomsDoesNotResetFeverClock() {
        let old = d("2026-03-01T08:00:00Z")
        let now = d("2026-03-03T08:00:00Z")
        let r = SelfReportRecord(risk: .contagious, symptoms: [.fever], onset: d("2026-03-01T00:00:00Z"), lastFeverAt: old)
        let out = SelfReporter(calendar: utc).checkIn(r, stillSymptomatic: false, hasFever: true, now: now)
        XCTAssertEqual(out.lastFeverAt, old)
        XCTAssertEqual(out.lastCheckIn, now)
        XCTAssertEqual(out.risk, .contagious)
        let out2 = SelfReporter(calendar: utc).checkIn(r, stillSymptomatic: true, hasFever: true, now: now)
        XCTAssertEqual(out2.lastFeverAt, now)
    }

    // MARK: PauseSchedule

    // Clock skew tolerance is 2 minutes: 100 s back is normal, 130 s back means the clock was set back.
    func testClockSkewToleranceIsTwoMinutes() {
        let since = d("2026-06-10T12:00:00Z")
        let p = PauseState(since: since, until: since.addingTimeInterval(3600))
        XCTAssertFalse(PauseSchedule.shouldResume(p, now: since.addingTimeInterval(-100)))
        XCTAssertFalse(PauseSchedule.shouldResume(p, now: since.addingTimeInterval(-119)))
        XCTAssertTrue(PauseSchedule.shouldResume(p, now: since.addingTimeInterval(-130)))
    }

    // An end more than 26 h away cannot be a real pause (longest is 25 h on a DST day).
    func testEndFurtherThan26HoursAwayResumes() {
        let since = d("2026-06-10T12:00:00Z")
        let now = since.addingTimeInterval(60)
        XCTAssertFalse(PauseSchedule.shouldResume(PauseState(since: since, until: now.addingTimeInterval(25.9 * 3600)), now: now))
        XCTAssertTrue(PauseSchedule.shouldResume(PauseState(since: since, until: now.addingTimeInterval(26.5 * 3600)), now: now))
        XCTAssertTrue(PauseSchedule.shouldResume(PauseState(since: since, until: now.addingTimeInterval(27 * 3600)), now: now))
        XCTAssertTrue(PauseSchedule.shouldResume(PauseState(since: since, until: now.addingTimeInterval(48 * 3600)), now: now))
    }

    // Same-day end shows only the time; another day adds a short date. (U+202F before AM/PM normalised.)
    func testDescribeShowsDateOnlyWhenNotToday() {
        var c = utc
        c.locale = Locale(identifier: "en_US")
        let now = d("2026-06-10T12:00:00Z")
        func text(_ until: String) -> String {
            PauseSchedule.describe(PauseState(since: now, until: d(until)), calendar: c, now: now)
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        XCTAssertEqual(text("2026-06-10T15:40:00Z"), "until 3:40 PM")
        XCTAssertEqual(text("2026-06-11T09:05:00Z"), "until 6/11/26, 9:05 AM")
    }

    // MARK: ExposureHistory

    private func epi(_ s: Double, mins: Double = 1) -> ExposureEpisode {
        ExposureEpisode(start: Date(timeIntervalSince1970: s), end: Date(timeIntervalSince1970: s + 60), weightedMinutes: mins, maxRisk: .contagious)
    }

    // The saved list comes back oldest first, whatever order it arrived in.
    func testPrunedIsOldestFirst() {
        let now = Date(timeIntervalSince1970: 10_000)
        let out = ExposureLog.pruned([epi(5000), epi(1000), epi(3000)], now: now)
        XCTAssertEqual(out.map(\.start.timeIntervalSince1970), [1000, 3000, 5000])
    }

    // 1200 quiet ticks of 0.1 s add up to 119.99999999999746 in floating point; that is still the 2-minute gap.
    func testGapCountsFloatSumsOfTwoMinutes() {
        var h = ExposureHistory()
        var now = t0
        _ = h.advance(simSeconds: 60, contacts: [(pClose: 1.0, risk: Risk.contagious)], at: now)
        var done: [ExposureEpisode] = []
        for i in 1...1200 {
            now = now.addingTimeInterval(0.1)
            done = h.advance(simSeconds: 0.1, contacts: [], at: now)
            if i < 1200 { XCTAssertTrue(done.isEmpty, "tick \(i)") }
        }
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done.first?.weightedMinutes ?? -1, 1.0, accuracy: 1e-9)
    }

    // Quiet ticks (pClose < 0.5, even a risky peer) add nothing to the episode and the episode ends 120 s later.
    func testQuietTicksAddNoWeight() {
        var h = ExposureHistory()
        _ = h.advance(simSeconds: 60, contacts: [(pClose: 1.0, risk: Risk.contagious)], at: t0)
        let weak: [Contact] = [(pClose: 0.3, risk: .contagious)]
        XCTAssertTrue(h.advance(simSeconds: 60, contacts: weak, at: t0.addingTimeInterval(120)).isEmpty)
        XCTAssertEqual(h.ongoing?.weightedMinutes ?? -1, 1.0, accuracy: 1e-12)
        let done = h.advance(simSeconds: 60, contacts: weak, at: t0.addingTimeInterval(180))
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done[0].weightedMinutes, 1.0, accuracy: 1e-12)
        XCTAssertEqual(done[0].end, t0)  // end of the last risky tick, tail excluded
    }

    // A risky tick resets the quiet timer: 60 s quiet, risky, 90 s quiet is one episode still open.
    func testRiskyTickResetsTheQuietTimer() {
        var h = ExposureHistory()
        let risky: [Contact] = [(pClose: 1.0, risk: .contagious)]
        _ = h.advance(simSeconds: 60, contacts: risky, at: t0)
        XCTAssertTrue(h.advance(simSeconds: 60, contacts: [], at: t0.addingTimeInterval(120)).isEmpty)
        _ = h.advance(simSeconds: 60, contacts: risky, at: t0.addingTimeInterval(180))
        XCTAssertTrue(h.advance(simSeconds: 90, contacts: [], at: t0.addingTimeInterval(270)).isEmpty)
        XCTAssertNotNil(h.ongoing)
        let done = h.advance(simSeconds: 30, contacts: [], at: t0.addingTimeInterval(300))
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done[0].weightedMinutes, 2.0, accuracy: 1e-12)
    }

    // NaN / infinite durations count as 0 s, not as 24 h.
    func testNonFiniteDurationCountsAsZero() {
        for bad in [Double.nan, .infinity, -.infinity, -5] {
            var h = ExposureHistory()
            _ = h.advance(simSeconds: bad, contacts: [(pClose: 1.0, risk: Risk.contagious)], at: t0)
            XCTAssertEqual(h.ongoing?.start, t0, "\(bad)")
            XCTAssertEqual(h.ongoing?.weightedMinutes, 0, "\(bad)")
        }
    }

    // A tick is clamped to 24 h: a 10-day tick counts 1440 minutes and starts 24 h before it ended.
    func testHugeDurationClampedTo24Hours() {
        var h = ExposureHistory()
        _ = h.advance(simSeconds: 864_000, contacts: [(pClose: 1.0, risk: Risk.contagious)], at: t0)
        XCTAssertEqual(h.ongoing?.weightedMinutes ?? -1, 1440, accuracy: 1e-9)
        XCTAssertEqual(h.ongoing?.start, t0.addingTimeInterval(-86_400))
    }

    // Close-contact threshold is 15 weighted minutes with a 1e-6 float allowance.
    func testEpisodeCloseContactThreshold() {
        func e(_ m: Double) -> ExposureEpisode { ExposureEpisode(start: t0, end: t0, weightedMinutes: m, maxRisk: .contagious) }
        XCTAssertTrue(e(15).isCloseContact)
        XCTAssertTrue(e(15 - 1e-7).isCloseContact)
        XCTAssertFalse(e(15 - 1e-5).isCloseContact)
        XCTAssertFalse(e(14.9).isCloseContact)
    }

    // Reset closes the episode in progress and lists it (once).
    func testFinishOpenReturnsTheEpisodeOnce() {
        var h = ExposureHistory()
        _ = h.advance(simSeconds: 60, contacts: [(pClose: 1.0, risk: Risk.contagious)], at: t0)
        let done = h.finishOpen()
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done[0].weightedMinutes, 1.0, accuracy: 1e-12)
        XCTAssertEqual(done[0].maxRisk, .contagious)
        XCTAssertTrue(h.finishOpen().isEmpty)
        XCTAssertNil(h.ongoing)
        // under 0.5 weighted minutes is not listed
        _ = h.advance(simSeconds: 20, contacts: [(pClose: 1.0, risk: Risk.possible)], at: t0)  // 0.1667
        XCTAssertTrue(h.finishOpen().isEmpty)
    }

    // MARK: PSickFeed time parsing

    func testImpossibleDateTimeFieldsAreRejected() {
        XCTAssertNil(PSickFeed.simSeconds(iso: "2026-00-05T00:00:00"), "month 0")
        XCTAssertNil(PSickFeed.simSeconds(iso: "2026-13-05T00:00:00"), "month 13")
        XCTAssertNil(PSickFeed.simSeconds(iso: "2026-01-00T00:00:00"), "day 0")
        XCTAssertNil(PSickFeed.simSeconds(iso: "2026-01-32T00:00:00"), "day 32")
        XCTAssertNil(PSickFeed.simSeconds(iso: "2026-01-05T24:00:00"), "hour 24")
        XCTAssertNil(PSickFeed.simSeconds(iso: "2026-01-05T00:60:00"), "minute 60")
        XCTAssertNil(PSickFeed.simSeconds(iso: "2026-01-05T00:00:60"), "second 60")
        XCTAssertEqual(PSickFeed.simSeconds(iso: "2026-01-01T00:00:00"), 1_767_225_600)
        XCTAssertEqual(PSickFeed.simSeconds(iso: "2026-12-31T23:59:59"), 1_798_761_599)
    }

    // Anything after the seconds must be ".digits"; zone suffixes and junk are rejected.
    func testTrailingJunkAfterSecondsIsRejected() {
        XCTAssertNil(PSickFeed.simSeconds(iso: "2026-01-08T16:20:00-0500"))
        XCTAssertNil(PSickFeed.simSeconds(iso: "2026-01-08T16:20:00x123"))
        XCTAssertNil(PSickFeed.simSeconds(iso: "2026-01-08T16:20:00+05:00"))
        XCTAssertNil(PSickFeed.simSeconds(iso: "2026-01-08T16:20:00Z"))
        XCTAssertNil(PSickFeed.simSeconds(iso: "2026-01-08T16:20:00."))
        XCTAssertEqual(PSickFeed.simSeconds(iso: "2026-01-08T16:20:00.25")!, 1_767_889_200.25, accuracy: 1e-6)
        XCTAssertEqual(PSickFeed.simSeconds(iso: "2026-01-08T16:20:00.5")!, 1_767_889_200.5, accuracy: 1e-6)
    }

    // One row: the time range is a single instant, not nil.
    func testTimeRangeOfASingleRow() throws {
        let f = try PSickFeed.parse("agent_id,t_iso,p_sick\nA0000,2026-01-08T16:20:00,0.1\n")
        XCTAssertEqual(f.timeRange, 1_767_889_200...1_767_889_200)
    }

    // MARK: BuildingHeat

    private let hdr = "t_iso,building_id,name,lat,lon,people,expected_sick,heat,high\n"
    private var hdrR: String { String(hdr.dropLast()) + ",radius_m\n" }
    private let T0 = 1_767_571_200.0  // 2026-01-05T00:00:00
    private func bh(_ rows: String..., radius: Bool = false) throws -> BuildingHeat {
        try BuildingHeat.parse((radius ? hdrR : hdr) + rows.joined(separator: "\n") + "\n")
    }
    private let ts = "2026-01-05T00:00:00"

    func testZeroPeopleSickHeatAreValid() throws {
        let b = try bh("\(ts),b1,N,37.4,-122.1,0,0,0,0")
        XCTAssertEqual(b.rejected, 0)
        XCTAssertEqual(b.reading("b1", at: T0), .init(people: 0, expectedSick: 0, heat: 0, high: false))
        XCTAssertEqual(try bh("\(ts),b1,N,37.4,-122.1,5,1,1,1").rejected, 0)
        XCTAssertEqual(try bh("\(ts),b1,N,37.4,-122.1,5,1,1.0001,1").rejected, 1)
        XCTAssertEqual(try bh("\(ts),b1,N,37.4,-122.1,5,1,-0.0001,0").rejected, 1)
        XCTAssertEqual(try bh("\(ts),b1,N,37.4,-122.1,-1,1,0.5,0").rejected, 1)
        XCTAssertEqual(try bh("\(ts),b1,N,37.4,-122.1,5,-1,0.5,0").rejected, 1)
        XCTAssertEqual(try bh("\(ts),b1,N,37.4,-122.1,5,1,0.5,2").rejected, 1)
    }

    func testNonFiniteNumbersAreRejected() throws {
        XCTAssertEqual(try bh("\(ts),b1,N,37.4,-122.1,inf,1,0.5,0").rejected, 1)
        XCTAssertEqual(try bh("\(ts),b1,N,37.4,-122.1,5,inf,0.5,0").rejected, 1)
        XCTAssertEqual(try bh("\(ts),b1,N,37.4,-122.1,nan,1,0.5,0").rejected, 1)
        XCTAssertEqual(try bh("\(ts),b1,N,37.4,-122.1,5,1,0.5,0,inf", radius: true).rejected, 1)
    }

    func testRadiusMustBePositiveAndDefaultsTo40() throws {
        XCTAssertEqual(try bh("\(ts),b1,N,37.4,-122.1,5,1,0.5,0,0", radius: true).rejected, 1)
        XCTAssertEqual(try bh("\(ts),b1,N,37.4,-122.1,5,1,0.5,0,-5", radius: true).rejected, 1)
        XCTAssertEqual(try bh("\(ts),b1,N,37.4,-122.1,5,1,0.5,0,0.5", radius: true).buildings["b1"]?.radius, 0.5)
        XCTAssertEqual(try bh("\(ts),b1,N,37.4,-122.1,5,1,0.5,0,", radius: true).buildings["b1"]?.radius, 40)
        XCTAssertEqual(try bh("\(ts),b1,N,37.4,-122.1,5,1,0.5,0").buildings["b1"]?.radius, 40)
        // a row of the wrong width for the header is rejected
        XCTAssertEqual(try bh("\(ts),b1,N,37.4,-122.1,5,1,0.5,0", radius: true).rejected, 1)
        XCTAssertEqual(try bh("\(ts),b1,N,37.4,-122.1,5,1,0.5,0,30").rejected, 1)
    }

    func testOnlyOneOfLatLonIsRejectedAndRangesAreInclusive() throws {
        XCTAssertEqual(try bh("\(ts),b1,N,37.4,,5,1,0.5,0").rejected, 1)
        XCTAssertEqual(try bh("\(ts),b1,N,,-122.1,5,1,0.5,0").rejected, 1)
        let none = try bh("\(ts),b1,N,,,5,1,0.5,0")
        XCTAssertEqual(none.rejected, 0)
        XCTAssertFalse(none.buildings["b1"]!.hasGeometry)
        XCTAssertEqual(try bh("\(ts),b1,N,90,180,5,1,0.5,0").rejected, 0)
        XCTAssertEqual(try bh("\(ts),b1,N,-90,-180,5,1,0.5,0").rejected, 0)
        XCTAssertEqual(try bh("\(ts),b1,N,90.0001,0,5,1,0.5,0").rejected, 1)
        XCTAssertEqual(try bh("\(ts),b1,N,0,180.0001,5,1,0.5,0").rejected, 1)
        XCTAssertEqual(try bh("\(ts),b1,N,0,-181,5,1,0.5,0").rejected, 1)
        XCTAssertEqual(try bh("\(ts),b1,N,0,270,5,1,0.5,0").rejected, 1)
    }

    func testEmptyNameFallsBackToId() throws {
        XCTAssertEqual(try bh("\(ts),bld_7,,37.4,-122.1,5,1,0.5,0").buildings["bld_7"]?.name, "bld_7")
    }

    func testFirstGeometrySeenIsKeptAndMissingGeometryIsFilledIn() throws {
        let b = try bh("2026-01-05T00:00:00,b1,N,,,5,1,0.5,0",
                       "2026-01-05T00:15:00,b1,N,37.5,-122.5,5,1,0.5,0",
                       "2026-01-05T00:30:00,b1,N,38.0,-121.0,5,1,0.5,0")
        XCTAssertEqual(b.buildings["b1"]?.lat, 37.5)
        XCTAssertEqual(b.buildings["b1"]?.lon, -122.5)
        XCTAssertEqual(b.mappable.map(\.id), ["b1"])
        XCTAssertEqual(b.snapshots.count, 3)
    }

    func testRepeatedTimeAndBuildingLaterRowWins() throws {
        let b = try bh("\(ts),b1,N,37.4,-122.1,5,1,0.2,0", "\(ts),b1,N,37.4,-122.1,9,3,0.8,1")
        XCTAssertEqual(b.rowCount, 2)
        XCTAssertEqual(b.snapshots.count, 1)
        XCTAssertEqual(b.reading("b1", at: T0), .init(people: 9, expectedSick: 3, heat: 0.8, high: true))
    }

    func testBrokenQuotingVariantsAreRejected() throws {
        XCTAssertEqual(try bh("\(ts),b1,ab\"c,37.4,-122.1,5,1,0.5,0").rejected, 1, "quote mid-field")
        XCTAssertEqual(try bh("\(ts),b1,\"ab\"c,37.4,-122.1,5,1,0.5,0").rejected, 1, "text after closing quote")
        XCTAssertEqual(try bh("\(ts),b1,\"abc,37.4,-122.1,5,1,0.5,0").rejected, 1, "unterminated")
        XCTAssertEqual(try bh("\(ts),b1,\"ab\"\"c\"x,37.4,-122.1,5,1,0.5,0").rejected, 1, "text after closing quote 2")
        XCTAssertEqual(try bh("\(ts),b1,ab\"c\",37.4,-122.1,5,1,0.5,0").rejected, 1, "quote opens mid-field and closes")
        XCTAssertEqual(try bh("\(ts),b1,N,37.4,-122.1,5,1,0.5,\"0").rejected, 1, "unterminated quote in the last field")
        let ok = try bh("\(ts),b1,\"Smith, \"\"Hall\"\"\",37.4,-122.1,5,1,0.5,0")
        XCTAssertEqual(ok.rejected, 0)
        XCTAssertEqual(ok.buildings["b1"]?.name, "Smith, \"Hall\"")
    }

    func testColourIsClampedOutsideZeroToOne() {
        func rgb(_ h: Double) -> [Double] { let c = BuildingHeat.rgb(heat: h); return [c.r, c.g, c.b] }
        XCTAssertEqual(rgb(2), [219, 108, 89])
        XCTAssertEqual(rgb(1), [219, 108, 89])
        XCTAssertEqual(rgb(-1), [172, 188, 139])
        XCTAssertEqual(rgb(0), [172, 188, 139])
        XCTAssertEqual(rgb(0.5), [235, 209, 135])
        XCTAssertEqual(rgb(0.25), [203.5, 198.5, 137], accuracy: 1e-9)
        XCTAssertEqual(rgb(0.75), [227, 158.5, 112], accuracy: 1e-9)
    }

    func testHaversineAgainstKnownDistances() {
        // One degree of latitude on a 6371 km sphere: 6371000 * pi / 180 = 111194.93 m.
        XCTAssertEqual(BuildingHeat.haversine(0, 0, 1, 0), 111_194.93, accuracy: 1)
        // Half the circumference. This pair lands at a = 1.0000000000000002, which must not turn into NaN.
        let far = BuildingHeat.haversine(86.9738, 33.5461, -86.9738, -146.4539)
        XCTAssertFalse(far.isNaN)
        XCTAssertEqual(far, 20_015_086.8, accuracy: 1)
        XCTAssertEqual(BuildingHeat.haversine(10, 20, 10, 20), 0, accuracy: 1e-9)
        for (a, b, c, e) in [(77.87221684660642, 61.93995265435262, -77.87221684660642, -118.06004734564738),
                             (-75.14841975866581, 101.71455511031724, 75.14841975866581, -78.28544488968276),
                             (-40.19324355475085, 108.75555549861559, 40.19324355475085, -71.24444450138441)] {
            let d = BuildingHeat.haversine(a, b, c, e)
            XCTAssertFalse(d.isNaN, "\(a),\(b)")
            XCTAssertEqual(d, 20_015_086.8, accuracy: 1)
        }
        // Every antipodal pair is half the circumference, never NaN from rounding past 1.
        for lat in stride(from: -89.0, through: 89.0, by: 6.1) {
            for lon in stride(from: -179.0, through: 0.0, by: 7.3) {
                let d = BuildingHeat.haversine(lat, lon, -lat, lon + 180)
                XCTAssertFalse(d.isNaN, "\(lat),\(lon)")
                XCTAssertEqual(d, 20_015_086.8, accuracy: 1, "\(lat),\(lon)")
            }
        }
    }

    func testTiesBreakByLowerIdAndMappableIsNameThenId() throws {
        let b = try bh("\(ts),b_b,Same,37.4,-122.1,5,1,0.5,0", "\(ts),b_a,Same,37.4,-122.1,5,1,0.5,0")
        XCTAssertEqual(b.nearest(lat: 37.4, lon: -122.1)?.building.id, "b_a")
        XCTAssertEqual(b.inside(lat: 37.4, lon: -122.1)?.id, "b_a")
        let m = try bh("\(ts),b1,Zed,37.4,-122.1,5,1,0.5,0", "\(ts),b9,Alpha,37.4,-122.1,5,1,0.5,0",
                       "\(ts),b2,Alpha,37.4,-122.1,5,1,0.5,0", "\(ts),b3,,,,5,1,0.5,0")
        XCTAssertEqual(m.mappable.map(\.id), ["b2", "b9", "b1"])
    }

    // MARK: Exposure window and dose

    // A tick that ended at 60 s: the episode resets exactly 2 h after it (7200 s later), not a second before.
    func testMinutesResetExactlyTwoHoursAfterTheLastContact() {
        var t = ExposureTracker()
        t.advance(simSeconds: 60, contacts: [(pClose: 1.0, risk: Risk.contagious)])
        t.advance(simSeconds: 7_199, contacts: [])
        XCTAssertEqual(t.minutes, 1.0, accuracy: 1e-12)
        t.advance(simSeconds: 1, contacts: [])
        XCTAssertEqual(t.minutes, 0)
    }



    // Ticks in the same simulated minute share one bucket (at most 1440 buckets).
    func testSameMinuteTicksShareOneBucket() {
        var a = ExposureTracker(), b = ExposureTracker()
        a.advance(simSeconds: 10, contacts: [(pClose: 1.0, risk: Risk.contagious)])
        a.advance(simSeconds: 10, contacts: [(pClose: 1.0, risk: Risk.contagious)])
        b.advance(simSeconds: 20, contacts: [(pClose: 1.0, risk: Risk.contagious)])
        XCTAssertEqual(a, b)
    }











    // MARK: RiskEstimate text

    func testPercentTextEdges() {
        XCTAssertEqual(RiskEstimate.percentText(0), "0%")
        XCTAssertEqual(RiskEstimate.percentText(-0.2), "0%")
        XCTAssertEqual(RiskEstimate.percentText(0.004), "<1%")
        XCTAssertEqual(RiskEstimate.percentText(0.0001), "<1%")
        XCTAssertEqual(RiskEstimate.percentText(0.01), "1%")
        XCTAssertEqual(RiskEstimate.percentText(0.02), "2%")
        XCTAssertEqual(RiskEstimate.percentText(0.123), "12%")
        XCTAssertEqual(RiskEstimate.percentText(1.0), "100%")
        XCTAssertEqual(RiskEstimate.percentText(1.5), "100%")
    }
}

private func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
