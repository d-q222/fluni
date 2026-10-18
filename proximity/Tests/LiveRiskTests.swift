import XCTest
@testable import FluniProx

/// The on-screen risk estimate is live: driven through the same per-tick step ProximityModel.tick runs
/// (ContactGuard → SightingAccrual → AccrualFeed → ExposureTracker, via ExposureTick), p moves on every
/// 1 s tick near someone sick, lands on infer.js's golden value after 15 min, and only the 24 h window
/// takes it back down.
final class LiveRiskTests: XCTestCase {
    /// One phone's exposure state, ticked like ProximityModel.tick with UWB-ranged peers.
    private struct Phone {
        var contactGuard = ContactGuard()
        var accrual = SightingAccrual()
        var exposure = ExposureTracker()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var speed = 1.0
        var p: Double { exposure.probability }

        /// One tick `seconds` after the last, with these peers in range.
        mutating func tick(_ peers: [(id: String, risk: Risk, distance: Double)], seconds: Double = 1) {
            now += seconds
            let inputs = peers.map { x -> ContactGuard.Input in
                let est = Estimate(distance: x.distance, sigma: 0.1, sources: [.uwb])
                return .init(id: x.id, risk: x.risk, pClose: Fusion.exposurePClose(est),
                             distance: Fusion.doseDistance(est), sources: [.uwb], uwbAt: now)
            }
            let guarded = contactGuard.apply(now: now, inputs)
            ExposureTick.run(guarded: guarded, fresh: Set(peers.map(\.id)), now: now, wall: seconds, speed: speed,
                             accrues: seconds >= SightingAccrual.minStep, accrual: &accrual, exposure: &exposure)
        }

        /// The first sighting credits nothing; then `n` one-second ticks. Returns p after every tick.
        mutating func stay(_ n: Int, near peer: (id: String, risk: Risk, distance: Double)) -> [Double] {
            tick([peer])
            return (0 ..< n).map { _ in tick([peer]); return p }
        }
    }

    private struct Scenario: Decodable { let name: String; let p: Double }
    private struct Golden: Decodable { let scenarios: [Scenario] }
    /// p from the real model/infer.js (Fixtures/xcheck/golden.json).
    private func golden(_ name: String) throws -> Double {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/xcheck/golden.json")
        let g = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
        return try XCTUnwrap(g.scenarios.first { $0.name == name }, name).p
    }

    private let positive = (id: "A", risk: Risk.contagious, distance: 0.5)

    // MARK: Live, not stepped

    func testFirstSightingLeavesThePrior() {
        var phone = Phone()
        phone.tick([positive])
        XCTAssertEqual(phone.p, RiskEstimate.prior)
    }

    func testPRisesOnEveryOneSecondTickNearSomeoneWhoTestedPositive() throws {
        var phone = Phone()
        let ps = phone.stay(900, near: positive)
        var prev = RiskEstimate.prior
        for (i, p) in ps.enumerated() {
            XCTAssertGreaterThan(p, prev, "tick \(i + 1): p must rise every second, not once a minute")
            prev = p
        }
        // Every second adds about the same: no minute-sized jump at the bucket boundaries (60, 120, ...).
        let steps = zip(ps.dropFirst(), ps).map { $0 - $1 }
        XCTAssertLessThan(steps.max()! / steps.min()!, 1.1)
        // The first second, by hand: p = prior + (1 − prior)·s·(1 − e^(−stage·unitDose)).
        let u = 10 * 0.5 * (1.0 / 3600) * (1 / (30 * 0.5 * 0.5) + RiskEstimate.roomFar)
        XCTAssertEqual(ps[0], 0.02 + 0.98 * 0.97 * (1 - exp(-0.352 * u)), accuracy: 1e-12)
    }

    func testFifteenMinutesAtHalfAMetreIsTheInferJSValue() throws {
        var phone = Phone()
        let p = try XCTUnwrap(phone.stay(900, near: positive).last)
        XCTAssertEqual(p, try golden("A s=0.97 0.5m/900s"), accuracy: 1e-9)
        XCTAssertEqual(p, 0.0752, accuracy: 1e-4)
    }

    func testFifteenMinutesAtThreeMetresIsTheInferJSValue() throws {
        var phone = Phone()
        let p = try XCTUnwrap(phone.stay(900, near: (id: "A", risk: .contagious, distance: 3)).last)
        XCTAssertEqual(p, try golden("A s=0.97 3m/900s"), accuracy: 1e-9)
        XCTAssertEqual(p, 0.0226, accuracy: 1e-4)
    }

    // MARK: Who and how close

    func testPossiblySickRaisesPLessThanTestedPositiveEverySecond() throws {
        var pos = Phone(), sym = Phone()
        let a = pos.stay(900, near: positive)
        let b = sym.stay(900, near: (id: "A", risk: .possible, distance: 0.5))
        var (pa, pb) = (RiskEstimate.prior, RiskEstimate.prior)
        for i in a.indices {
            XCTAssertGreaterThan(b[i], pb, "possibly sick still raises p, tick \(i + 1)")
            XCTAssertGreaterThan(a[i] - pa, b[i] - pb, "tested positive rises faster, tick \(i + 1)")
            (pa, pb) = (a[i], b[i])
        }
        XCTAssertEqual(b.last!, try golden("A s=0.6 0.5m/900s"), accuracy: 1e-9)
        XCTAssertLessThan(b.last!, a.last!)
    }

    func testCloserRaisesPFasterEverySecond() {
        var near = Phone(), far = Phone()
        let a = near.stay(300, near: positive)
        let b = far.stay(300, near: (id: "A", risk: .contagious, distance: 3))
        var (pa, pb) = (RiskEstimate.prior, RiskEstimate.prior)
        for i in a.indices {
            // 1/d²: 0.5 m vs 3 m is 36× on the near-field term; the shared-air term is the same for both.
            XCTAssertGreaterThan(a[i] - pa, 5 * (b[i] - pb), "tick \(i + 1)")
            (pa, pb) = (a[i], b[i])
        }
    }

    func testHealthyPeerAddsNothing() {
        var phone = Phone()
        let ps = phone.stay(120, near: (id: "A", risk: .none, distance: 0.5))
        XCTAssertTrue(ps.allSatisfy { $0 == RiskEstimate.prior })
    }

    // MARK: After they leave

    func testPHoldsAfterThePeerLeavesAndFallsOnlyWithThe24HourWindow() throws {
        var phone = Phone()
        let start = phone.now
        let peak = try XCTUnwrap(phone.stay(900, near: positive).last)
        let lastCredit = phone.now
        // Gone: an hour of 1 s ticks with nobody in range changes nothing.
        for i in 0 ..< 3600 {
            phone.tick([])
            XCTAssertEqual(phone.p, peak, "tick \(i + 1) after they left")
        }
        // Still exactly the peak until 24 h after the first credited second (minute buckets: allow 1 min).
        while phone.now.timeIntervalSince(start) < ExposureTracker.window - 60 {
            phone.tick([], seconds: 60)
            XCTAssertEqual(phone.p, peak)
        }
        // Then it falls, never rises, and is back at the prior once the last second is 24 h old.
        var prev = peak
        while phone.now.timeIntervalSince(lastCredit) <= ExposureTracker.window + 120 {
            phone.tick([])
            XCTAssertLessThanOrEqual(phone.p, prev)
            prev = phone.p
        }
        XCTAssertEqual(phone.p, RiskEstimate.prior)
    }

    // MARK: Background, then foreground

    /// iOS wakes FlUni only now and then in the background. The first tick back (on a wake-up or on
    /// returning to the foreground) credits the whole gap at once, so p jumps straight to what accrued.
    func testFirstTickAfterABackgroundGapJumpsToTheAccruedValue() {
        var gap = Phone(), steady = Phone()
        _ = gap.stay(10, near: positive)
        gap.tick([positive], seconds: 240)  // within SightingAccrual.maxGap
        let ps = steady.stay(250, near: positive)
        XCTAssertEqual(gap.p, ps.last!, accuracy: 1e-12)
    }

    // MARK: What the screen shows

    func testLiveTextShowsOneDecimalBelowTenPercent() {
        XCTAssertEqual(RiskEstimate.liveText(0.02), "2.0%")
        XCTAssertEqual(RiskEstimate.liveText(0.0226157024771422), "2.3%")
        XCTAssertEqual(RiskEstimate.liveText(0.0751728192911298), "7.5%")
        XCTAssertEqual(RiskEstimate.liveText(0.004), "0.4%")
        XCTAssertEqual(RiskEstimate.liveText(0.0994), "9.9%")
        XCTAssertEqual(RiskEstimate.liveText(0.0996), "10%")
        XCTAssertEqual(RiskEstimate.liveText(0.1234), "12%")
        XCTAssertEqual(RiskEstimate.liveText(1), "100%")
        XCTAssertEqual(RiskEstimate.liveText(0), "0%")
        XCTAssertEqual(RiskEstimate.liveText(.nan), "0%")
        // The shared whole-percent text (heatmap/app.js percentText) is unchanged.
        XCTAssertEqual(RiskEstimate.percentText(0.0751728192911298), "8%")
        XCTAssertEqual(RiskEstimate.percentText(0.02), "2%")
    }

    /// At demo speed 60× (the -speed launch argument) the shown number changes on every 1 s tick.
    func testAtDemoSpeedTheShownNumberChangesEveryTick() {
        var phone = Phone()
        phone.speed = 60
        let texts = phone.stay(15, near: positive).map(RiskEstimate.liveText)
        XCTAssertEqual(Set(texts).count, texts.count, "\(texts)")
        XCTAssertNotEqual(texts.first, "2.0%")
    }

    /// At 1× the one-decimal text moves often over 15 min and never goes back.
    func testAtRealTimeTheShownNumberClimbsSteadily() {
        var phone = Phone()
        let ps = phone.stay(900, near: positive)
        let texts = ps.map(RiskEstimate.liveText)
        var changes = 0
        for (a, b) in zip(texts, texts.dropFirst()) where a != b {
            changes += 1
            XCTAssertGreaterThan(Double(b.dropLast())!, Double(a.dropLast())!)
        }
        XCTAssertGreaterThanOrEqual(changes, 50, "2.0% → 7.5% in 0.1 steps")
        XCTAssertEqual(texts.last, "7.5%")
    }
}
