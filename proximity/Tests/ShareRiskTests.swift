import CoreBluetooth
import XCTest
@testable import FluniProx

// Risk sharing (product owner 2026-10-17): each phone broadcasts its own score (and days since onset) in a
// FLU2 beacon; other phones use them for their estimate and never show them.

// MARK: - Beacon v2

final class BeaconV2Tests: XCTestCase {
    private let id10 = Data((0..<10).map { UInt8($0 * 25 + 3) })

    func testLayoutByteByByte() throws {
        let u = try XCTUnwrap(BLEBeacon.payload(id: id10, risk: .possible, score: 0.25, days: 3))
        let b = Array(BeaconGATT.bytes(u))
        XCTAssertEqual(b.count, 16)
        XCTAssertEqual(Array(b[0..<4]), Array("FLU2".utf8))
        XCTAssertEqual(b[4], 1 | 3 << 2, "status: risk in bits 0-1, days in bits 2-5")
        XCTAssertEqual(b[5], 128, "round(255 * sqrt(0.25)) = round(127.5) = 128")
        XCTAssertEqual(Array(b[6...]), Array(id10))
        XCTAssertEqual(BLEBeacon.statusByte(risk: .contagious, days: nil), 2 | 15 << 2, "unknown days = 15")
        XCTAssertEqual(BLEBeacon.statusByte(risk: .none, days: 99), 0 | 14 << 2, "clamped to 14")
        XCTAssertEqual(BLEBeacon.statusByte(risk: .none, days: -3), 0, "clamped to 0")
    }

    func testRoundTripEveryStatusDayAndManyScores() throws {
        var rng = SplitMix(41)
        for _ in 0..<200 {
            let id = Data(rng.bytes(10))
            for risk in Risk.allCases {
                for days in [nil, 0, 1, 7, 13, 14] as [Int?] {
                    let p = rng.unit()
                    let v = try XCTUnwrap(BeaconGATT.value(id: id, risk: risk, score: p, days: days))
                    let hit = try XCTUnwrap(BeaconGATT.decode(v))
                    XCTAssertEqual(hit.id, id.hex)
                    XCTAssertEqual(hit.id.count, 20)
                    XCTAssertEqual(hit.risk, risk)
                    XCTAssertEqual(hit.daysSinceOnset, days)
                    let q = try XCTUnwrap(hit.score)
                    XCTAssertLessThanOrEqual(abs(q - p), (2 * p.squareRoot() + 1.0 / 510) / 510 + 1e-15, "p \(p)")
                    // The advert UUID and the GATT value decode the same.
                    XCTAssertEqual(BLEBeacon.decode(CBUUID(data: v)), hit)
                }
            }
        }
    }

    /// Error bounds of the sqrt byte: |p' - p| <= (2√p + 1/510) / 510 (half a step in √p). Pinned at the
    /// owner's points, and finer than a linear byte (step 1/255 = 0.39 pp) near the 2% baseline.
    func testScoreRoundTripErrorBounds() {
        let cases: [(p: Double, bound: Double)] = [(0.02, 0.00056), (0.05, 0.00088), (0.10, 0.00125), (0.50, 0.00278), (0.97, 0.00387)]
        for c in cases {
            let b = BLEBeacon.scoreByte(c.p)!
            let q = BLEBeacon.score(fromByte: b)
            let err = abs(q - c.p)
            XCTAssertLessThanOrEqual(err, c.bound, "p \(c.p): byte \(b) -> \(q)")
            XCTAssertLessThanOrEqual(err, (2 * c.p.squareRoot() + 1.0 / 510) / 510, "p \(c.p)")
            print("SHARERISK score \(c.p): byte \(b) decodes \(q), error \(err)")
        }
        XCTAssertEqual(BLEBeacon.scoreByte(0.02), 36)
        XCTAssertEqual(BLEBeacon.score(fromByte: 36), 0.019930795847750864, accuracy: 1e-15)
        // Resolution near 2%: adjacent bytes are ~0.11 pp apart.
        let step = BLEBeacon.score(fromByte: 37) - BLEBeacon.score(fromByte: 36)
        XCTAssertLessThan(step, 0.0012)
        XCTAssertLessThan(step, 1.0 / 255 / 3)
        // Ends are exact; every byte survives decode -> encode; the mapping is strictly increasing.
        XCTAssertEqual(BLEBeacon.scoreByte(0), 0); XCTAssertEqual(BLEBeacon.scoreByte(1), 255)
        XCTAssertEqual(BLEBeacon.score(fromByte: 0), 0); XCTAssertEqual(BLEBeacon.score(fromByte: 255), 1)
        for b in 0...255 {
            XCTAssertEqual(BLEBeacon.scoreByte(BLEBeacon.score(fromByte: UInt8(b))), UInt8(b))
            if b > 0 { XCTAssertGreaterThan(BLEBeacon.score(fromByte: UInt8(b)), BLEBeacon.score(fromByte: UInt8(b - 1))) }
        }
    }

    func testEncoderRejectsNonProbabilities() {
        for bad in [Double.nan, .infinity, -.infinity, -0.0001, 1.0001, -1, 2] {
            XCTAssertNil(BLEBeacon.scoreByte(bad), "\(bad)")
            XCTAssertNil(BLEBeacon.payload(id: id10, risk: .none, score: bad, days: nil), "\(bad)")
        }
        XCTAssertNil(BLEBeacon.payload(id: Data(count: 9), risk: .none, score: 0.02, days: nil))
        XCTAssertNil(BLEBeacon.payload(id: Data(count: 11), risk: .none, score: 0.02, days: nil), "v2 IDs are 10 bytes")
    }

    func testDecoderRejectsGarbage() throws {
        let good = Array(BeaconGATT.value(id: id10, risk: .possible, score: 0.3, days: 2)!)
        XCTAssertNotNil(BeaconGATT.decode(Data(good)))
        // Every status byte: risk bits 3 or any spare bit set -> rejected; the rest decode as specified.
        for sb in 0...255 {
            var b = good; b[4] = UInt8(sb)
            let hit = BeaconGATT.decode(Data(b))
            if sb & 0xC0 != 0 || sb & 0x03 == 3 { XCTAssertNil(hit, "status byte \(sb)") } else {
                let h = try XCTUnwrap(hit, "status byte \(sb)")
                XCTAssertEqual(h.risk.rawValue, sb & 3)
                let d = (sb >> 2) & 15
                XCTAssertEqual(h.daysSinceOnset, d == 15 ? Int?.none : Int?.some(d))
            }
        }
        // Any score byte is a valid probability in [0, 1].
        for v in 0...255 {
            var b = good; b[5] = UInt8(v)
            let s = try XCTUnwrap(BeaconGATT.decode(Data(b))?.score)
            XCTAssertTrue(s.isFinite && s >= 0 && s <= 1)
        }
        // Magic: FLU0, FLU3, flu2, FLV2 are not ours.
        for m in [[0x46, 0x4C, 0x55, 0x30], [0x46, 0x4C, 0x55, 0x33], [0x66, 0x6C, 0x75, 0x32], [0x46, 0x4C, 0x56, 0x32]] as [[UInt8]] {
            var b = good; b.replaceSubrange(0..<4, with: m)
            XCTAssertNil(BeaconGATT.decode(Data(b)), "\(m)")
        }
        for n in [0, 6, 15, 17] { XCTAssertNil(BeaconGATT.decode(Data(good.prefix(n) + Array(repeating: 0, count: max(0, n - 16))))) }
    }

    /// An older build's FLU1 beacon still decodes: status and 11-byte ID, score and days unknown, so s is the
    /// status level and the stage the illness average.
    func testFLU1StillAcceptedWithScoreUnknown() throws {
        let id11 = Data(repeating: 0x5A, count: 11)
        for risk in Risk.allCases {
            let hit = try XCTUnwrap(BeaconGATT.decode(BeaconGATT.value(id: id11, risk: risk)!))
            XCTAssertEqual(hit.id, id11.hex); XCTAssertEqual(hit.id.count, 22)
            XCTAssertEqual(hit.risk, risk)
            XCTAssertNil(hit.score); XCTAssertNil(hit.daysSinceOnset)
            XCTAssertEqual(RiskEstimate.sourceS(status: risk, score: hit.score), RiskEstimate.evidence(risk))
            XCTAssertEqual(RiskEstimate.sourceStage(status: risk, daysSinceOnset: hit.daysSinceOnset), RiskEstimate.stage)
        }
        // The peer link accepts both ID lengths, nothing else.
        XCTAssertTrue(LinkGuard.isEphemeralID(id11.hex))
        XCTAssertTrue(LinkGuard.isEphemeralID(id10.hex))
        for n in [9, 12] { XCTAssertFalse(LinkGuard.isEphemeralID(Data(repeating: 1, count: n).hex)) }
        XCTAssertFalse(LinkGuard.isEphemeralID(id10.hex + "0"))
    }
}

// MARK: - Own score, status floor, one-tick lag

final class OwnScoreTests: XCTestCase {
    func testPositiveNeverBelow097EvenWithNoDose() {
        for live in [0, RiskEstimate.prior, 0.3, .nan, -1] as [Double] {
            XCTAssertGreaterThanOrEqual(RiskEstimate.ownScore(liveRisk: live, status: .contagious), 0.97, "\(live)")
            XCTAssertGreaterThanOrEqual(RiskEstimate.ownScore(liveRisk: live, status: .possible), 0.6, "\(live)")
        }
        XCTAssertEqual(RiskEstimate.ownScore(liveRisk: 0, status: .contagious), RiskEstimate.posTest)
        XCTAssertEqual(RiskEstimate.ownScore(liveRisk: 0.99, status: .contagious), 0.99, "the estimate wins when higher")
        XCTAssertEqual(RiskEstimate.ownScore(liveRisk: 0.02, status: .possible), RiskEstimate.selfReport)
        XCTAssertEqual(RiskEstimate.ownScore(liveRisk: 0.7, status: .possible), 0.7)
        XCTAssertEqual(RiskEstimate.ownScore(liveRisk: 0.034, status: .none), 0.034, "healthy: just the estimate")
        // The UI can't present a reported-sick user as low: the band of their score is High.
        var lag = OwnScoreLag(status: .contagious)
        XCTAssertEqual(lag.current, 0.97)
        lag.tick(liveRisk: RiskEstimate.prior, status: .contagious)
        XCTAssertEqual(RiskEstimate.band(lag.current), .high)
        XCTAssertEqual(RiskEstimate.band(RiskEstimate.ownScore(liveRisk: 0.02, status: .possible)), .high)
        XCTAssertEqual(RiskEstimate.band(RiskEstimate.ownScore(liveRisk: 0.02, status: .none)), .low)
    }

    func testBroadcastIsPreviousTicksScore() {
        var lag = OwnScoreLag()
        XCTAssertEqual(lag.current, RiskEstimate.prior); XCTAssertEqual(lag.broadcast, RiskEstimate.prior)
        let live = [0.021, 0.025, 0.04, 0.04, 0.2, 0.18]
        var previous = lag.current
        for x in live {
            lag.tick(liveRisk: x, status: .none)
            XCTAssertEqual(lag.current, x, "this tick's own score")
            XCTAssertEqual(lag.broadcast, previous, "the beacon carries last tick's")
            XCTAssertNotEqual(lag.broadcast, lag.current == previous ? -1 : lag.current)
            previous = lag.current
        }
        // A report between ticks: the shown score jumps at once, the broadcast waits one tick.
        lag.statusChanged(liveRisk: 0.18, status: .contagious)
        XCTAssertEqual(lag.current, 0.97)
        XCTAssertEqual(lag.broadcast, 0.2, "still the tick before's value")
        lag.tick(liveRisk: 0.19, status: .contagious)
        XCTAssertEqual(lag.broadcast, 0.97)
        XCTAssertEqual(lag.current, 0.97)
    }

    func testDaysSinceOnsetIsCalendarDaysFromDayZero() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let zero = cal.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        let at = { (d: Int, h: Int) in cal.date(byAdding: DateComponents(day: d, hour: h), to: zero)! }
        XCTAssertEqual(RiskEstimate.daysSinceOnset(dayZero: zero, status: .contagious, now: at(0, 23), calendar: cal), 0)
        XCTAssertEqual(RiskEstimate.daysSinceOnset(dayZero: zero, status: .contagious, now: at(1, 0), calendar: cal), 1)
        XCTAssertEqual(RiskEstimate.daysSinceOnset(dayZero: zero, status: .possible, now: at(6, 12), calendar: cal), 6)
        XCTAssertEqual(RiskEstimate.daysSinceOnset(dayZero: zero, status: .possible, now: at(40, 0), calendar: cal), 14)
        XCTAssertNil(RiskEstimate.daysSinceOnset(dayZero: zero, status: .none, now: at(1, 0), calendar: cal), "healthy: unknown")
        XCTAssertNil(RiskEstimate.daysSinceOnset(dayZero: nil, status: .contagious, now: at(1, 0), calendar: cal))
        // Same count as the self-report's own day number.
        let r = SelfReportRecord(risk: .contagious, onset: zero)
        for d in 0..<10 {
            XCTAssertEqual(RiskEstimate.daysSinceOnset(dayZero: r.dayZero, status: r.risk, now: at(d, 9), calendar: cal),
                           SelfReporter(calendar: cal).dayNumber(r, now: at(d, 9)))
        }
    }
}

// MARK: - s, stage and room through the phone's pipeline

final class SharedRiskPipelineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testSFromScoreVsStatus() {
        XCTAssertEqual(RiskEstimate.sourceS(status: .none, score: 0.3), 0.28, accuracy: 1e-15)
        XCTAssertEqual(RiskEstimate.sourceS(status: .none, score: 0.02), 0, "at the prior: nothing")
        XCTAssertEqual(RiskEstimate.sourceS(status: .none, score: 0.01), 0, "below the prior: nothing, never negative")
        XCTAssertEqual(RiskEstimate.sourceS(status: .none, score: nil), 0)
        XCTAssertEqual(RiskEstimate.sourceS(status: .possible, score: 0.3), 0.6, "status wins")
        XCTAssertEqual(RiskEstimate.sourceS(status: .possible, score: 0.85), 0.83, accuracy: 1e-15, "score wins")
        XCTAssertEqual(RiskEstimate.sourceS(status: .contagious, score: 0.02), 0.97)
        XCTAssertEqual(RiskEstimate.sourceS(status: .contagious, score: 1), 0.98, accuracy: 1e-15)
        XCTAssertEqual(RiskEstimate.sourceS(status: .none, score: .nan), 0)
        XCTAssertEqual(RiskEstimate.sourceS(status: .possible, score: .infinity), 0.6)
        // Stage: the peer's days when it reports a status, else the average.
        XCTAssertEqual(RiskEstimate.sourceStage(status: .contagious, daysSinceOnset: 0), 1.0)
        XCTAssertEqual(RiskEstimate.sourceStage(status: .possible, daysSinceOnset: 3), 0.35)
        XCTAssertEqual(RiskEstimate.sourceStage(status: .possible, daysSinceOnset: 2), 0.6)
        XCTAssertEqual(RiskEstimate.sourceStage(status: .contagious, daysSinceOnset: 8), 0, "past day 7: not infectious")
        XCTAssertEqual(RiskEstimate.sourceStage(status: .none, daysSinceOnset: 0), RiskEstimate.stage, "healthy days are ignored")
        XCTAssertEqual(RiskEstimate.sourceStage(status: .contagious, daysSinceOnset: nil), RiskEstimate.stage)
    }

    private func input(_ id: String, risk: Risk = .none, score: Double?, distance: Double, days: Int? = nil,
                       at now: Date) -> ContactGuard.Input {
        .init(id: id, risk: risk, pClose: distance <= 1.83 ? 1 : 0, distance: distance, rssi: nil, sources: [.uwb],
              uwbAt: now, score: score, days: days)
    }

    /// One tick per second through ContactGuard and ExposureTick, as ProximityModel.tick does.
    private struct Phone {
        var g = ContactGuard(), a = SightingAccrual(), e = ExposureTracker()
        var now: Date
        mutating func run(seconds: Int, room: RiskEstimate.Room = .standard, _ peers: (Date) -> [ContactGuard.Input]) {
            for _ in 0..<seconds {
                now = now.addingTimeInterval(1)
                let out = g.apply(now: now, peers(now))
                ExposureTick.run(guarded: out, fresh: Set(out.map(\.id)), now: now, wall: 1, speed: 1, accrues: true,
                                 accrual: &a, exposure: &e, room: room)
            }
        }
    }

    /// A healthy-status peer whose own score is 0.3 raises p through the dose, but adds no close-contact
    /// minutes and never triggers the heads-up (those stay status-only).
    func testScoreOnlyPeerRaisesProbabilityButNotMinutesOrHeadsUp() {
        var ph = Phone(now: t0)
        ph.run(seconds: 601) { [self] in [input("a", score: 0.3, distance: 0.5, at: $0)] }
        XCTAssertGreaterThan(ph.e.probability, RiskEstimate.prior + 0.01)
        XCTAssertEqual(ph.e.minutes, 0)
        XCTAssertEqual(ph.e.level, .none)
        let src = ph.e.sources["a"]!
        XCTAssertEqual(src.s, 0.28, accuracy: 1e-15)
        let u = RiskEstimate.unitDose(distance: 0.5, seconds: 600)
        XCTAssertEqual(src.dose, u, accuracy: 1e-12)
        XCTAssertEqual(ph.e.probability, 0.02 + 0.98 * 0.28 * (1 - exp(-RiskEstimate.stage * u)), accuracy: 1e-12)
        // The same peer from an old build (FLU1, no score): nothing at all.
        var old = Phone(now: t0)
        old.run(seconds: 601) { [self] in [input("a", score: nil, distance: 0.5, at: $0)] }
        XCTAssertEqual(old.e.probability, RiskEstimate.prior)
        XCTAssertNil(old.e.sources["a"])
    }

    /// Moving closer to a peer with P = 0.3: 3 m -> 1 m -> 0.5 m, 5 minutes each. p rises at every step and
    /// each step adds more than the one before.
    func testMonotonicRiseMovingCloserToPeerWithP03() {
        var ph = Phone(now: t0)
        var ps = [ph.e.probability]
        ph.run(seconds: 1) { [self] in [input("a", score: 0.3, distance: 3, at: $0)] }  // first sighting
        for d in [3.0, 1.0, 0.5] {
            for _ in 0..<5 {
                ph.run(seconds: 60) { [self] in [input("a", score: 0.3, distance: d, at: $0)] }
                XCTAssertGreaterThan(ph.e.probability, ps.last!, "\(d) m")
                ps.append(ph.e.probability)
            }
        }
        let gains = stride(from: 1, to: ps.count, by: 5).map { ps[min($0 + 4, ps.count - 1)] - ps[$0 - 1] }
        XCTAssertEqual(gains.count, 3)
        XCTAssertGreaterThan(gains[1], gains[0] * 3, "1 m adds much more than 3 m")
        XCTAssertGreaterThan(gains[2], gains[1] * 2, "0.5 m adds much more than 1 m")
        let w = RiskEstimate.stage * (RiskEstimate.unitDose(distance: 3, seconds: 300) + RiskEstimate.unitDose(distance: 1, seconds: 300)
            + RiskEstimate.unitDose(distance: 0.5, seconds: 300))
        XCTAssertEqual(ph.e.probability, 0.02 + 0.98 * 0.28 * (1 - exp(-w)), accuracy: 1e-12)
    }

    /// Per-source stage: a positive peer on day 0 (stage 1.0) adds 1/0.352 times the average dose; on day 8 none.
    func testStageFromBroadcastDays() {
        func p(days: Int?) -> Double {
            var ph = Phone(now: t0)
            ph.run(seconds: 601) { [self] in [input("a", risk: .contagious, score: 0.97, distance: 1, days: days, at: $0)] }
            return ph.e.probability
        }
        let u = RiskEstimate.unitDose(distance: 1, seconds: 600)
        XCTAssertEqual(p(days: 0), 0.02 + 0.98 * 0.97 * (1 - exp(-1.0 * u)), accuracy: 1e-12)
        XCTAssertEqual(p(days: 4), 0.02 + 0.98 * 0.97 * (1 - exp(-0.18 * u)), accuracy: 1e-12)
        XCTAssertEqual(p(days: nil), 0.02 + 0.98 * 0.97 * (1 - exp(-RiskEstimate.stage * u)), accuracy: 1e-12)
        XCTAssertEqual(p(days: 8), RiskEstimate.prior, "past the profile: no dose")
        XCTAssertEqual(p(days: 99), 0.02 + 0.98 * 0.97 * (1 - exp(-RiskEstimate.stage * u)), accuracy: 1e-12,
                       "an out-of-range day is unknown")
    }

    func testRoomChangesTheDose() {
        func p(_ room: RiskEstimate.Room) -> Double {
            var ph = Phone(now: t0)
            ph.run(seconds: 1801, room: room) { [self] in [input("a", risk: .contagious, score: nil, distance: 2, at: $0)] }
            return ph.e.probability
        }
        let std = p(.standard), out = p(.outdoors), dorm = p(.room(volume: 53.52, ach: 2, dorm: true)), hall = p(.room(volume: 2000, ach: 6, dorm: false))
        XCTAssertLessThan(out, std, "outdoors: no room air, wind dilutes the plume")
        XCTAssertLessThan(dorm, std, "dorm room: quiet quanta")
        XCTAssertLessThan(hall, std, "big ventilated hall: less shared air")
        let u = 10 * 0.5 * (1800 / 3600.0) * (1 / (30 * 4.0 * 5))
        XCTAssertEqual(out, 0.02 + 0.98 * 0.97 * (1 - exp(-RiskEstimate.stage * u)), accuracy: 1e-12)
    }

    // MARK: Spoofing

    func testHealthyStatusWithScoreAtLeast09IsIgnored() {
        var g = ContactGuard()
        var out = g.apply(now: t0, [input("a", score: 0.95, distance: 0.5, at: t0)])
        XCTAssertNil(out[0].score); XCTAssertEqual(out[0].s, 0)
        out = g.apply(now: t0.addingTimeInterval(1), [input("b", score: 0.9, distance: 0.5, at: t0)])
        XCTAssertNil(out[0].score, "0.9 itself is implausible")
        out = g.apply(now: t0.addingTimeInterval(2), [input("c", score: 0.89, distance: 0.5, at: t0)])
        XCTAssertEqual(out[0].score, 0.89)
        XCTAssertEqual(out[0].s, 0.87, accuracy: 1e-15)
        // With a status the same score is plausible.
        out = g.apply(now: t0.addingTimeInterval(3), [input("d", risk: .possible, score: 0.95, distance: 0.5, at: t0)])
        XCTAssertEqual(out[0].score, 0.95)
        // Garbage never gets through.
        for bad in [Double.nan, .infinity, -0.1, 1.5] {
            out = g.apply(now: t0.addingTimeInterval(4), [input("e", risk: .possible, score: bad, distance: 0.5, at: t0)])
            XCTAssertNil(out[0].score, "\(bad)")
        }
        // End to end: the ignored score adds no dose.
        var ph = Phone(now: t0)
        ph.run(seconds: 300) { [self] in [input("a", score: 0.95, distance: 0.5, at: $0)] }
        XCTAssertEqual(ph.e.probability, RiskEstimate.prior)
    }

    func testScoreJumpOverHalfWithinAMinuteIsIgnored() {
        var g = ContactGuard()
        let at = { (s: Double) in self.t0.addingTimeInterval(s) }
        XCTAssertEqual(g.apply(now: at(0), [input("a", score: 0.05, distance: 1, at: at(0))])[0].score, 0.05)
        XCTAssertNil(g.apply(now: at(10), [input("a", score: 0.6, distance: 1, at: at(10))])[0].score, "+0.55 in 10 s")
        XCTAssertNil(g.apply(now: at(30), [input("a", score: 0.6, distance: 1, at: at(30))])[0].score, "0.05 still within the minute")
        XCTAssertNil(g.apply(now: at(40), [input("a", score: 0.05, distance: 1, at: at(40))])[0].score, "bouncing back is a jump too")
        // Once everything 0.5 away has aged out (> 60 s), a steady score is accepted.
        XCTAssertNil(g.apply(now: at(100), [input("a", score: 0.6, distance: 1, at: at(100))])[0].score, "0.05 at 40 s, exactly 60 s ago")
        XCTAssertEqual(g.apply(now: at(101), [input("a", score: 0.6, distance: 1, at: at(101))])[0].score, 0.6)
        // A jump of exactly 0.5 is allowed; small real changes always are.
        var h = ContactGuard()
        XCTAssertEqual(h.apply(now: at(0), [input("b", score: 0.25, distance: 1, at: at(0))])[0].score, 0.25)
        XCTAssertEqual(h.apply(now: at(1), [input("b", score: 0.75, distance: 1, at: at(1))])[0].score, 0.75)
        XCTAssertEqual(h.apply(now: at(2), [input("b", score: 0.74, distance: 1, at: at(2))])[0].score, 0.74)
        XCTAssertNil(h.apply(now: at(3), [input("b", score: 0.76, distance: 1, at: at(3))])[0].score, "0.51 above the 0.25 two seconds ago")
    }

    /// A real report makes the score jump to 0.97; the jump rule ignores the score, but the status carries
    /// the same s, so the report is never lost.
    func testRealPositiveReportStillCountsFully() {
        var g = ContactGuard()
        _ = g.apply(now: t0, [input("a", score: 0.03, distance: 1, at: t0)])
        let out = g.apply(now: t0.addingTimeInterval(1), [input("a", risk: .contagious, score: 0.97, distance: 1, at: t0)])
        XCTAssertNil(out[0].score)
        XCTAssertEqual(out[0].s, 0.97)
        XCTAssertEqual(out[0].pClose, 1)
    }

    /// Rule 2 counts "healthy" IDs whose score alone gives s >= 0.6: five of them at once trip the burst.
    func testFloodOfHighScoreHealthyIDsTripsTheBurstRule() {
        var g = ContactGuard()
        let flood = (0..<5).map { ContactGuard.Input(id: "f\($0)", risk: .none, pClose: 1, distance: 0.5, rssi: -55, score: 0.85) }
        _ = g.apply(now: t0, flood)
        XCTAssertTrue(g.flagged)
        var low = ContactGuard()
        _ = low.apply(now: t0, (0..<5).map { ContactGuard.Input(id: "c\($0)", risk: .none, pClose: 1, distance: 0.5, rssi: -55, score: 0.05) })
        XCTAssertFalse(low.flagged, "a crowd of ordinary classmates is not a burst")
        let out = g.apply(now: t0.addingTimeInterval(1), flood)
        XCTAssertTrue(out.allSatisfy { $0.distance == nil }, "Bluetooth-only burst IDs add no dose")
    }

    /// Rule 1 for the dose: at most two sources, the two that add most. Five slightly exposed classmates right
    /// beside you can't push out a positive peer 3 m away.
    func testDoseCapKeepsTheTwoLargestSources() {
        var g = ContactGuard()
        var peers = (0..<5).map { input("c\($0)", score: 0.025, distance: 0.4, at: t0) }
        peers.append(input("sick", risk: .contagious, score: 0.97, distance: 3, at: t0))
        peers.append(input("mid", score: 0.4, distance: 1, at: t0))
        let out = g.apply(now: t0, peers)
        let kept = Set(out.filter { $0.distance != nil }.map(\.id))
        XCTAssertEqual(kept, ["sick", "mid"])
        XCTAssertEqual(out.first { $0.id == "sick" }?.pClose, 0, "beyond 6 ft: no minutes either way")
    }
}

// MARK: - Room context

final class RoomContextTests: XCTestCase {
    private static let file = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("FlUni/Resources/building_rooms.csv")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testBundledFileParses() throws {
        let ctx = RoomContext.parse(try Data(contentsOf: Self.file))
        XCTAssertEqual(ctx.rejected, 0)
        XCTAssertGreaterThan(ctx.places.count, 800)
        XCTAssertEqual(ctx.rooms["bld_1040231570"], .room(volume: 53.52, ach: 2, dorm: true))
        XCTAssertEqual(ctx.rooms["bld_109151789"], .room(volume: 216, ach: 3, dorm: false))
        XCTAssertEqual(ctx.rooms["bld_m_white_plaza"], .outdoors)
        XCTAssertEqual(ctx.rooms["bld_18564360"], .outdoors, "the stadium is open air")
    }

    func testFixToRoom() throws {
        let ctx = RoomContext.parse(try Data(contentsOf: Self.file))
        let dorm = ctx.places.first { $0.id == "bld_1040231570" }!
        XCTAssertEqual(ctx.room(lat: dorm.lat, lon: dorm.lon, accuracy: 5, fixAt: now, now: now), dorm.room)
        let plaza = ctx.places.first { $0.id == "bld_m_white_plaza" }!
        XCTAssertEqual(ctx.room(lat: plaza.lat, lon: plaza.lon, accuracy: 5, fixAt: now, now: now), .outdoors)
        // Far from every building, accurate fix: outdoors. Same spot, accuracy reaching a building: unsure, default room.
        XCTAssertEqual(ctx.room(lat: 37.40, lon: -122.20, accuracy: 10, fixAt: now, now: now), .outdoors)
        XCTAssertEqual(ctx.room(lat: 37.40, lon: -122.20, accuracy: 50_000, fixAt: now, now: now), .standard)
        // Stale, future, invalid fix: default room.
        XCTAssertEqual(ctx.room(lat: dorm.lat, lon: dorm.lon, accuracy: 5, fixAt: now.addingTimeInterval(-61), now: now), .standard)
        XCTAssertEqual(ctx.room(lat: dorm.lat, lon: dorm.lon, accuracy: 5, fixAt: now.addingTimeInterval(30), now: now), .standard)
        XCTAssertEqual(ctx.room(lat: dorm.lat, lon: dorm.lon, accuracy: -1, fixAt: now, now: now), .standard)
        XCTAssertEqual(ctx.room(lat: .nan, lon: dorm.lon, accuracy: 5, fixAt: now, now: now), .standard)
        XCTAssertEqual(RoomContext().room(lat: dorm.lat, lon: dorm.lon, accuracy: 5, fixAt: now, now: now), .standard, "no data")
    }

    func testBadRowsAreRejected() {
        let csv = RoomContext.header + "\nb1,37.4,-122.1,20,r,100,2,lab,1\nb2,abc,-122.1,20,r,100,2,lab,1\nb3,37.4,-122.1,0,r,100,2,lab,1\n"
            + "b4,37.4,-122.1,20,r,100,2,lab,2\nb5,37.4,-122.1,20,r,,,lab,1\nshort,row\n"
        let ctx = RoomContext.parse(Data(csv.utf8))
        XCTAssertEqual(ctx.places.map(\.id), ["b1", "b5"])
        XCTAssertEqual(ctx.rejected, 4)
        XCTAssertEqual(ctx.rooms["b5"], .standard, "missing volume and ach: the default room's, as infer.js mkRoom")
        XCTAssertEqual(RoomContext.parse(Data("nope\n".utf8)).places, [])
    }
}

// MARK: - Golden vectors from the real infer.js

final class SharedRiskCrossCheckTests: XCTestCase {
    private static let dir = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()

    private struct Golden: Decodable {
        struct C: Decodable { let distance: Double; let seconds: Double; let day: Int; let days: Int?; let building: String? }
        struct Src: Decodable { let id: String; let status: String; let score: Double?; let s: Double; let contacts: [C] }
        struct Scenario: Decodable { let name: String; let sources: [Src]; let p: Double; let inferP: Double }
        struct RoomDose: Decodable { let kind: String; let building: String?; let distance: Double; let seconds: Double; let dose: Double }
        struct Stage: Decodable { let day: Int; let stage: Double }
        let shared: [Scenario]; let roomDose: [RoomDose]; let stageFactor: [Stage]
        let quietQuanta: Double; let outdoorNearDilution: Double
    }

    private func golden() throws -> Golden {
        try JSONDecoder().decode(Golden.self, from: Data(contentsOf: Self.dir.appendingPathComponent("Fixtures/xcheck/golden.json")))
    }

    private func rooms() throws -> RoomContext {
        RoomContext.parse(try Data(contentsOf: Self.dir.deletingLastPathComponent().appendingPathComponent("FlUni/Resources/building_rooms.csv")))
    }

    private func room(_ b: String?, _ ctx: RoomContext) throws -> RiskEstimate.Room {
        guard let b else { return .standard }
        if b == "outdoors" { return .outdoors }
        return try XCTUnwrap(ctx.rooms[b], b)
    }

    func testConstantsAndStageFactor() throws {
        let g = try golden()
        XCTAssertEqual(RiskEstimate.quietQuanta, g.quietQuanta)
        XCTAssertEqual(RiskEstimate.outdoorNearDilution, g.outdoorNearDilution)
        for s in g.stageFactor { XCTAssertEqual(RiskEstimate.stageFactor(day: s.day), s.stage, "day \(s.day)") }
    }

    func testRoomDoseMatchesInferJS() throws {
        let g = try golden(), ctx = try rooms()
        XCTAssertGreaterThanOrEqual(g.roomDose.count, 40)
        XCTAssertEqual(Set(g.roomDose.map(\.kind)), ["default", "outdoors", "generic", "dorm", "classroom", "outdoorPlace", "arena"])
        var worst = 0.0
        for c in g.roomDose {
            let u = RiskEstimate.unitDose(distance: c.distance, seconds: c.seconds, room: try room(c.building, ctx))
            XCTAssertEqual(u, c.dose, accuracy: 1e-12, "\(c.kind) \(c.distance) m")
            XCTAssertEqual(u / c.dose, 1, accuracy: 1e-12)
            worst = max(worst, abs(u - c.dose))
        }
        print("CROSSCHECK max |Swift - JS| room unitDose: \(worst)")
    }

    /// Each scenario through the real tracker (60 s ticks), with s from status + score, stage from the days the
    /// peer broadcasts and this phone's room, vs the phone rule in JS and the real inferRisk (1e-12).
    func testSharedRiskScenariosMatchInferJS() throws {
        let g = try golden(), ctx = try rooms()
        XCTAssertGreaterThanOrEqual(g.shared.count, 45)
        XCTAssertTrue(g.shared.contains { $0.sources.contains { $0.status == "none" && ($0.score ?? 0) > 0.02 } }, "score sources")
        XCTAssertTrue(g.shared.contains { $0.sources.contains { $0.contacts.contains { $0.days == 0 } } }, "per-source stage")
        XCTAssertTrue(g.shared.contains { $0.sources.contains { $0.contacts.contains { $0.building == "outdoors" } } }, "outdoors")
        var worst = 0.0
        for sc in g.shared {
            var t = ExposureTracker()
            for src in sc.sources {
                let status: Risk = src.status == "contagious" ? .contagious : src.status == "possible" ? .possible : .none
                let s = RiskEstimate.sourceS(status: status, score: src.score)
                XCTAssertEqual(s, src.s, accuracy: 1e-15, "s rule: \(sc.name)")
                for c in src.contacts {
                    let dose = DosePeer(id: src.id, distance: c.distance, s: s,
                                        stage: RiskEstimate.sourceStage(status: status, daysSinceOnset: c.days), room: try room(c.building, ctx))
                    var left = c.seconds
                    while left > 0 {
                        let dt = min(60, left)
                        t.advance(simSeconds: dt, contacts: [(pClose: 1, risk: status)], doses: [dose])
                        left -= dt
                    }
                }
            }
            XCTAssertEqual(t.probability, sc.p, accuracy: 1e-12, sc.name)
            XCTAssertEqual(t.probability, sc.inferP, accuracy: 1e-12, "vs inferRisk: \(sc.name)")
            worst = max(worst, abs(t.probability - sc.p), abs(t.probability - sc.inferP))
        }
        print("CROSSCHECK max |Swift - JS| shared-risk p: \(worst)")
        // Closer to the P = 0.3 peer: strictly rising in the real infer.js too.
        let walk = ["P=0.3 at 3m", "P=0.3 at 3m then 1m", "P=0.3 at 3m then 1m then 0.5m"].map { n in g.shared.first { $0.name == n }!.inferP }
        XCTAssertLessThan(RiskEstimate.prior, walk[0]); XCTAssertLessThan(walk[0], walk[1]); XCTAssertLessThan(walk[1], walk[2])
    }
}

// MARK: - Nobody sees anyone else's score

final class ScoreIsNeverShownTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// The per-peer state views read (ProximityModel.peers) has no score and no days: there is nothing to show.
    func testPeerStateCarriesNoScoreOrDays() {
        let p = PeerState(id: "x")
        let labels = Mirror(reflecting: p).children.compactMap(\.label).map { $0.lowercased() }
        XCTAssertFalse(labels.isEmpty)
        for bad in ["score", "days", "onset", "stage", "evidence"] {
            XCTAssertFalse(labels.contains { $0.contains(bad) }, "PeerState.\(bad)")
        }
    }

    /// Strips `#if DEBUG ... #endif` blocks (debug-only developer views may show it).
    private func releaseCode(_ s: String) -> String {
        var out: [Substring] = [], depth = 0, debugAt: [Int] = []
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#if") { depth += 1; if t.contains("DEBUG") && !t.contains("!DEBUG") { debugAt.append(depth) }; continue }
            if t.hasPrefix("#else") || t.hasPrefix("#elseif") { if debugAt.last == depth { debugAt.removeLast() }; continue }
            if t.hasPrefix("#endif") { if debugAt.last == depth { debugAt.removeLast() }; depth -= 1; continue }
            if debugAt.isEmpty { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    private func swiftFiles(_ dir: String) throws -> [(String, String)] {
        let url = Self.root.appendingPathComponent(dir)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasSuffix(".swift") }
        return try names.map { ($0, try String(contentsOf: url.appendingPathComponent($0), encoding: .utf8)) }
    }

    /// Every FlUni and shared view, in Release code: nothing reads a peer's score, days, s, stage or the
    /// per-source table. (Core is where they are used; it has no views.)
    func testNoViewReadsAnotherPersonsScore() throws {
        let views = try swiftFiles("FlUni") + swiftFiles("SharedUI") + swiftFiles("Harness")
        XCTAssertGreaterThan(views.count, 20)
        let forbidden = [#"\.score\b"#, #"daysSinceOnset"#, #"\bheard\b"#, #"exposure\.sources"#, #"\.sources\["#,
                         #"BLEBeacon\.Hit"#, #"guardInput"#, #"sourceS\("#, #"sourceStage\("#, #"\.weighted\b"#]
        for (name, text) in views {
            let code = releaseCode(text)
            for f in forbidden {
                XCTAssertNil(code.range(of: f, options: .regularExpression), "\(name) uses \(f)")
            }
        }
        // ownScore is this user's own: allowed, and the risk card shows it.
        let today = try XCTUnwrap(views.first { $0.0 == "TodayView.swift" }?.1)
        XCTAssertTrue(today.contains("RiskCardView(p: model.ownScore)"))
    }

    /// Log lines never carry another phone's score or days (Release or not: the logs go to the Mac).
    func testLogsCarryNoScore() throws {
        for (name, text) in try swiftFiles("Core") {
            for line in text.split(separator: "\n") where line.contains("log(\"") || line.contains("onLog?(\"") || line.contains("print(\"") {
                for bad in ["score", "daysSinceOnset", "days=", "\\(sc)", "stage="] where !line.contains("guard score implausible id=") {
                    XCTAssertFalse(line.contains(bad), "\(name): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }
}
