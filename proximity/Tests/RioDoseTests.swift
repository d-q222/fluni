import XCTest
@testable import FluniProx

/// Adversarial tests for the per-ID Rio dose in ExposureTracker (the phone rule; golden values are in
/// CrossCheckTests). U(d, s) = RiskEstimate.unitDose.
final class RioDoseTests: XCTestCase {
    private typealias Contact = (pClose: Double, risk: Risk)
    private func U(_ d: Double, _ s: Double) -> Double { RiskEstimate.unitDose(distance: d, seconds: s) }

    private func tick(_ t: inout ExposureTracker, _ seconds: Double, _ id: String, _ d: Double,
                      risk: Risk = .contagious, pClose: Double = 1) {
        t.advance(simSeconds: seconds, contacts: [(pClose, risk)], doses: [DosePeer(id: id, distance: d)])
    }

    // MARK: 24 h window

    /// Mutation review round 2 bug: Int() truncated toward zero, so a first-minute contact expired up to
    /// ~90 s early while the clock was just under 24 h. It must count at 86399 s and be gone at 86460 s.
    func testFirstMinuteContactLastsTheFull24Hours() {
        var t = ExposureTracker()
        tick(&t, 30, "a", 1)  // clock 0-30 s
        t.advance(simSeconds: 86_399 - 30, contacts: [])
        XCTAssertEqual(t.minutes, 0.5, accuracy: 1e-12, "still inside 24 h at 86399 s")
        XCTAssertEqual(t.sources["a"]?.dose ?? 0, U(1, 30), accuracy: 1e-15)
        XCTAssertGreaterThan(t.probability, RiskEstimate.prior)
        t.advance(simSeconds: 86_460 - 86_399, contacts: [])
        XCTAssertEqual(t.minutes, 0)
        XCTAssertNil(t.sources["a"])
        XCTAssertEqual(t.dose, 0)
        XCTAssertEqual(t.probability, RiskEstimate.prior)
    }

    /// Re-targeted from mutation review round 2 (testDoseExpiresWithItsBucket): only the older tick leaves,
    /// and each ID keeps exactly its own remaining dose.
    func testPerIDDoseExpiresWithItsBucket() {
        var t = ExposureTracker()
        tick(&t, 60, "a", 0.5)
        t.advance(simSeconds: 3540, contacts: [])
        tick(&t, 60, "a", 2)
        tick(&t, 60, "b", 1, risk: .possible)
        XCTAssertEqual(t.sources["a"]?.dose ?? 0, U(0.5, 60) + U(2, 60), accuracy: 1e-15)
        t.advance(simSeconds: 82_800, contacts: [])  // clock 86520: the first tick (minute 1) is out
        XCTAssertEqual(t.sources["a"]?.dose ?? 0, U(2, 60), accuracy: 1e-15)
        XCTAssertEqual(t.sources["b"]?.dose ?? 0, U(1, 60), accuracy: 1e-15)
        XCTAssertEqual(t.dose, U(2, 60) + U(1, 60), accuracy: 1e-15)
        XCTAssertEqual(t.probability, RiskEstimate.probability(t.sources))
        t.advance(simSeconds: ExposureTracker.window, contacts: [])
        XCTAssertEqual(t.sources, [:])
        XCTAssertEqual(t.probability, RiskEstimate.prior)
    }

    // MARK: Evidence level s

    /// s is the highest level seen for the ID in the window and applies to all its dose; a later downgrade
    /// keeps it; once the high bucket expires, s falls back to what is left.
    func testEvidenceUpgradeWithinTheWindow() {
        var t = ExposureTracker()
        for _ in 0..<10 { tick(&t, 60, "x", 1, risk: .possible) }
        XCTAssertEqual(t.sources["x"]?.s, RiskEstimate.selfReport)
        let before = t.probability
        tick(&t, 60, "x", 1, risk: .contagious)  // the peer reports a positive test
        XCTAssertEqual(t.sources["x"]?.s, RiskEstimate.posTest)
        let dose = U(1, 60) * 11
        XCTAssertEqual(t.sources["x"]?.dose ?? 0, dose, accuracy: 1e-14)
        XCTAssertEqual(t.probability, 0.02 + 0.98 * 0.97 * (1 - exp(-RiskEstimate.stage * dose)), accuracy: 1e-12)
        XCTAssertGreaterThan(t.probability, before)
        tick(&t, 60, "x", 1, risk: .possible)  // a downgrade does not lower s within the window
        XCTAssertEqual(t.sources["x"]?.s, RiskEstimate.posTest)
        // Move on so only the last (possible) minute is in the window: s is 0.6 again.
        t.advance(simSeconds: ExposureTracker.window - 60, contacts: [])
        XCTAssertEqual(t.sources["x"]?.s, RiskEstimate.selfReport)
        XCTAssertEqual(t.sources["x"]?.dose ?? 0, U(1, 60), accuracy: 1e-15)
    }

    func testHealthyPeerAddsNoDoseAndNoEvidence() {
        var t = ExposureTracker()
        tick(&t, 600, "h", 0.2, risk: .none)
        XCTAssertEqual(t.sources, [:])
        XCTAssertEqual(t.probability, RiskEstimate.prior)
    }

    // MARK: Garbage in

    func testNonFiniteOrNegativeDistanceAddsNothing() {
        for d in [Double.nan, .infinity, -.infinity, -1, -0.001, -1e308] {
            var t = ExposureTracker()
            tick(&t, 60, "a", d)
            XCTAssertEqual(t.sources, [:], "distance \(d)")
            XCTAssertEqual(t.probability, RiskEstimate.prior, "distance \(d)")
            XCTAssertEqual(t.minutes, 1, "minutes don't depend on the distance input")
        }
        XCTAssertEqual(RiskEstimate.contactDose(distance: -0.0, seconds: 60), U(0, 60), "-0 is 0 m")
    }

    func testNonFiniteOrNegativeTimeAddsNothing() {
        for dt in [Double.nan, .infinity, -.infinity, -60, 0] {
            var t = ExposureTracker()
            tick(&t, dt, "a", 1)
            XCTAssertEqual(t.sources, [:], "dt \(dt)")
            XCTAssertEqual(t.dose, 0)
            XCTAssertTrue(t.probability.isFinite)
        }
        for share in [Double.nan, .infinity, -1, 0] {
            var t = ExposureTracker()
            t.advance(simSeconds: 60, contacts: [(1, .contagious)], doses: [DosePeer(id: "a", distance: 1, share: share)])
            XCTAssertEqual(t.sources, [:], "share \(share)")
        }
        for (d, s) in [(1.0, Double.nan), (1, .infinity), (1, -5), (.nan, 60)] {
            XCTAssertEqual(RiskEstimate.contactDose(distance: d, seconds: s), 0, "\(d) m, \(s) s")
        }
    }

    /// A contact without a doses entry (nil, or the array is shorter) adds no dose but keeps its minutes.
    func testMissingDoseEntryAddsNoDose() {
        var t = ExposureTracker()
        t.advance(simSeconds: 60, contacts: [(1, .contagious), (1, .contagious)], doses: [nil])
        t.advance(simSeconds: 60, contacts: [(1, .contagious)])
        XCTAssertEqual(t.sources, [:])
        XCTAssertEqual(t.minutes, 3, accuracy: 1e-12)
    }

    /// Re-targeted from mutation review round 2 (testDoseAccumulatesWithZeroPClose / ...UsesTierNotPClose):
    /// the dose depends on distance and time only, never on pClose (pClose drives the minutes).
    func testDoseIsIndependentOfPClose() {
        var a = ExposureTracker(), b = ExposureTracker(), c = ExposureTracker()
        tick(&a, 60, "x", 3, pClose: 0)
        tick(&b, 60, "x", 3, pClose: 0.5)
        tick(&c, 60, "x", 3, pClose: .nan)
        XCTAssertEqual(a.minutes, 0); XCTAssertEqual(b.minutes, 0.5, accuracy: 1e-12); XCTAssertEqual(c.minutes, 0)
        for t in [a, b, c] { XCTAssertEqual(t.sources["x"]?.dose ?? 0, U(3, 60), accuracy: 1e-15) }
    }

    // MARK: Range and the near-field floor

    /// Bluetooth range is inclusive, as the heat map's mock-up (`d <= 10`): 9.99 and 10.0 count, 10.01 doesn't.
    func testTenMetreCutoffIsInclusive() {
        XCTAssertEqual(RiskEstimate.doseRange, 10)
        XCTAssertEqual(RiskEstimate.contactDose(distance: 9.99, seconds: 60), U(9.99, 60))
        XCTAssertEqual(RiskEstimate.contactDose(distance: 10.0, seconds: 60), U(10, 60))
        XCTAssertGreaterThan(U(10, 60), 0)
        XCTAssertEqual(RiskEstimate.contactDose(distance: 10.01, seconds: 60), 0)
        XCTAssertEqual(RiskEstimate.contactDose(distance: 10.0.nextUp, seconds: 60), 0)
        var t = ExposureTracker()
        tick(&t, 60, "far", 10.01, pClose: 0)
        XCTAssertEqual(t.probability, RiskEstimate.prior)
        tick(&t, 60, "edge", 10, pClose: 0)
        XCTAssertGreaterThan(t.probability, RiskEstimate.prior)
    }

    func testCloserThanThirtyCentimetresCountsAsThirty() {
        for d in [0, 0.1, 0.2, 0.29999] { XCTAssertEqual(U(d, 60), U(0.3, 60), "\(d) m") }
        XCTAssertLessThan(U(0.31, 60), U(0.3, 60))
        // Closer counts much more: near field ~1/d², room air the same everywhere.
        XCTAssertGreaterThan(U(0.5, 60) / U(3, 60), 10)
        XCTAssertGreaterThan(U(5, 60), U(10, 60))
        XCTAssertEqual(U(10, 60), U(100, 60), accuracy: U(10, 60) * 0.25, "far away the room term dominates")
    }

    // MARK: Coarse GPS

    func testCoarseGPSOnlyAddsNoDose() {
        let gps = Estimate(distance: 0.5, sigma: 25, sources: [.gps])
        XCTAssertTrue(Fusion.isCoarseGPSOnly(gps))
        XCTAssertNil(Fusion.doseDistance(gps))
        var g = ContactGuard(), t = ExposureTracker()
        let out = g.apply(now: Date(timeIntervalSince1970: 0), [
            ContactGuard.Input(id: "gps", risk: .contagious, pClose: Fusion.exposurePClose(gps),
                               distance: Fusion.doseDistance(gps), sources: [.gps]),
        ])
        XCTAssertEqual(out.map(\.distance), [nil])
        t.advance(simSeconds: 3600, contacts: out.map { ($0.pClose, $0.risk) },
                  doses: out.map { o in o.distance.map { DosePeer(id: o.id, distance: $0) } })
        XCTAssertEqual(t.sources, [:])
        XCTAssertEqual(t.minutes, 0)
        XCTAssertEqual(t.probability, RiskEstimate.prior)
    }

    // MARK: Spoofing

    private func guarded(_ g: inout ContactGuard, _ t: inout ExposureTracker, seconds: Int,
                         peers: [ContactGuard.Input]) {
        for s in 0..<seconds {
            let out = g.apply(now: Date(timeIntervalSince1970: 1_000_000 + Double(s)), peers)
            t.advance(simSeconds: 1, contacts: out.map { ($0.pClose, $0.risk) },
                      doses: out.map { o in o.distance.map { DosePeer(id: o.id, distance: $0) } })
        }
    }

    /// 15 Bluetooth-only IDs at once trip the burst rule: they add no dose (and no minutes).
    func testSpoofedIDBurstAddsNoDose() {
        var g = ContactGuard(), t = ExposureTracker()
        let peers = (0..<15).map { ContactGuard.Input(id: "spoof\($0)", risk: .contagious, pClose: 1, distance: 0.3, rssi: -55) }
        guarded(&g, &t, seconds: 60, peers: peers)
        XCTAssertTrue(g.flagged)
        XCTAssertEqual(t.sources, [:])
        XCTAssertEqual(t.probability, RiskEstimate.prior)
    }

    /// Many IDs that each look corroborated (fresh UWB, so the burst rule doesn't apply) are still capped
    /// at the top 2 per tick, so at most 2 sources get any dose.
    func testManyCorroboratedIDsAreCappedAtTwoSources() {
        var g = ContactGuard(), t = ExposureTracker()
        let now = Date(timeIntervalSince1970: 1_000_000)
        for s in 0..<60 {
            let at = now.addingTimeInterval(Double(s))
            let peers = (0..<8).map {
                ContactGuard.Input(id: "id\($0)", risk: .contagious, pClose: 1 - Double($0) * 0.01, distance: 0.5,
                                   sources: [.uwb], uwbAt: at)
            }
            let out = g.apply(now: at, peers)
            t.advance(simSeconds: 1, contacts: out.map { ($0.pClose, $0.risk) },
                      doses: out.map { o in o.distance.map { DosePeer(id: o.id, distance: $0) } })
        }
        XCTAssertEqual(Set(t.sources.keys), ["id0", "id1"])
        XCTAssertEqual(t.probability, RiskEstimate.probability(["id0": .init(dose: U(0.5, 60), s: 0.97),
                                                                "id1": .init(dose: U(0.5, 60), s: 0.97)]), accuracy: 1e-12)
    }

    /// A risky peer beyond 6 ft (pClose 0, precisely ranged) still gets room-air dose when a top-2 slot is
    /// free, but never displaces a closer contact.
    func testFarContactFillsAFreeSlotOnly() {
        var g = ContactGuard()
        let at = Date(timeIntervalSince1970: 1_000_000)
        let far = ContactGuard.Input(id: "far", risk: .contagious, pClose: 0, distance: 8, sources: [.uwb], uwbAt: at)
        let near = (0..<2).map { ContactGuard.Input(id: "n\($0)", risk: .contagious, pClose: 0.9, distance: 1, sources: [.uwb], uwbAt: at) }
        XCTAssertEqual(g.apply(now: at, [far]).map(\.distance), [8])
        XCTAssertEqual(g.apply(now: at.addingTimeInterval(1), [far] + near).map(\.distance), [nil, 1, 1])
    }

    // MARK: ID rotation

    /// A phone rotates its ID every 15 min and Bluetooth alone can't link the IDs, so one person can count
    /// as two sources. Each gets half the dose; 1-(1-sλ(D/2))² > sλ(D) because λ is concave, so the phone
    /// slightly OVER-estimates vs a true per-person pair. 30 min at 1 m, tested positive: 4.9555% vs 4.9562%, +0.0007 percentage points.
    func testIDRotationSplitsOnePersonIntoTwoSources() {
        var one = ExposureTracker(), two = ExposureTracker()
        for m in 0..<30 {
            tick(&one, 60, "person", 1)
            tick(&two, 60, m < 15 ? "idA" : "idB", 1)
        }
        XCTAssertEqual(one.dose, two.dose, accuracy: 1e-15, "the total dose is the same")
        XCTAssertEqual(two.sources.count, 2)
        let lam = { (d: Double) in 1 - exp(-RiskEstimate.stage * d) }
        let D = one.dose
        XCTAssertEqual(one.probability, 0.02 + 0.98 * 0.97 * lam(D), accuracy: 1e-12)
        XCTAssertEqual(two.probability, 1 - 0.98 * pow(1 - 0.97 * lam(D / 2), 2), accuracy: 1e-12)
        let over = two.probability - one.probability
        XCTAssertGreaterThan(over, 0, "split IDs over-estimate")
        XCTAssertLessThan(over, 1e-4, "but only slightly")
        print("ID rotation: one ID p=\(one.probability), two IDs p=\(two.probability), over-estimate \(over)")
    }
}
