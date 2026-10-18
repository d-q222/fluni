import XCTest
@testable import FluniProx

/// Cross-checks the phone's maths and file readers against golden vectors made by the web team's JavaScript
/// (Fixtures/xcheck/make_golden.mjs -> golden.json; regenerate with `node make_golden.mjs`).
final class CrossCheckTests: XCTestCase {
    private static let dir = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/xcheck")

    private struct Golden: Decodable {
        struct Risk: Decodable {
            struct Contact: Decodable { let tier: Int; let minutes: Double }
            let kind: String; let s: Double; let contacts: [Contact]
            let exactP: Double; let foldedDose: Double; let foldedP: Double
        }
        struct TierW: Decodable { let distance: Double; let weight: Double }
        struct Tier: Decodable { let p: Double; let tier: String; let advice: String }
        struct PQ: Decodable { let agent: String; let t_iso: String; let p: Double }
        struct Reading: Decodable { let people: Double; let expectedSick: Double; let heat: Double; let high: Bool }
        struct HQ: Decodable { let building: String; let t_iso: String; let reading: Reading? }
        let risk: [Risk]; let tierWeights: [TierW]; let tiers: [Tier]; let psick: [PQ]; let heat: [HQ]
    }

    private func golden() throws -> Golden {
        try JSONDecoder().decode(Golden.self, from: Data(contentsOf: Self.dir.appendingPathComponent("golden.json")))
    }

    /// Representative distance (metres) for each infer.js distance_tier 1...4.
    private func weight(tier: Int) -> Double {
        let d = [0.5, 1.5, 3.0, 8.0][tier - 1]
        return Fusion.tierWeight(Estimate(distance: d, sigma: 0.1, sources: [.uwb]))
    }

    func testTierWeightsMatchInferJS() throws {
        for w in try golden().tierWeights {
            let e = Estimate(distance: w.distance, sigma: 0.1, sources: [.uwb])
            XCTAssertEqual(Fusion.tierWeight(e), w.weight, "distance \(w.distance)")
        }
    }

    private func swiftP(_ r: Golden.Risk) -> (dose: Double, p: Double) {
        let dose = r.contacts.reduce(0.0) { $0 + r.s * weight(tier: $1.tier) * $1.minutes }
        return (dose, RiskEstimate.probability(dose: dose))
    }

    /// Fully contagious source (s = 1): exact to 1e-9.
    func testSingleContactSicknessOneMatchesInferJS() throws {
        let cases = try golden().risk.filter { $0.kind == "single" && $0.s == 1 }
        XCTAssertGreaterThanOrEqual(cases.count, 14)
        for r in cases {
            let (dose, p) = swiftP(r)
            XCTAssertEqual(dose, r.foldedDose, accuracy: 1e-9)
            XCTAssertEqual(p, r.exactP, accuracy: 1e-9, "tier \(r.contacts[0].tier), \(r.contacts[0].minutes) min")
        }
    }

    /// Half-contagious source (s = 0.5): infer.js gives x = s*(1-e^(-lam)); dose-sum gives 1-e^(-s*lam).
    /// These differ, so this is a real mismatch (reported as a finding), not tuned away.
    func testSingleContactSicknessHalfMatchesInferJS() throws {
        let cases = try golden().risk.filter { $0.kind == "single" && $0.s == 0.5 }
        XCTAssertGreaterThanOrEqual(cases.count, 14)
        for r in cases {
            XCTAssertEqual(swiftP(r).p, r.exactP, accuracy: 1e-9, "s 0.5, tier \(r.contacts[0].tier), \(r.contacts[0].minutes) min")
        }
    }

    /// Several contacts: the folded-dose approximation vs the exact infer.js fold. Measured worst gap is
    /// about 1.19 percentage points (s = 1, [tier1 15 min, tier2 30 min, tier3 60 min]); bound set at 2 pp.
    func testMultiContactWithinDocumentedBound() throws {
        let bound = 0.02
        let cases = try golden().risk.filter { $0.kind == "multi" }
        XCTAssertGreaterThanOrEqual(cases.count, 5)
        var worst = 0.0
        for r in cases {
            let (dose, p) = swiftP(r)
            XCTAssertEqual(dose, r.foldedDose, accuracy: 1e-9)
            XCTAssertEqual(p, r.foldedP, accuracy: 1e-9)
            worst = max(worst, abs(p - r.exactP))
        }
        print("CROSSCHECK max multi-contact gap: \(worst)")
        XCTAssertLessThanOrEqual(worst, bound)
    }

    func testTiersAndAdviceMatchApp() throws {
        for t in try golden().tiers {
            let band: String
            switch RiskEstimate.band(t.p) { case .low: band = "low"; case .elevated: band = "elevated"; case .high: band = "high" }
            XCTAssertEqual(band, t.tier, "p \(t.p)")
            XCTAssertEqual(RiskEstimate.summary(t.p), t.advice, "p \(t.p)")
        }
    }

    private func load<T>(_ name: String, _ parse: (Data) throws -> T) throws -> T {
        try parse(Data(contentsOf: Self.dir.appendingPathComponent(name)))
    }

    func testPSickLookupMatchesPAt() throws {
        let feed = try load("p_sick.csv", PSickFeed.parse)
        XCTAssertEqual(feed.rejected, 0)
        let qs = try golden().psick
        XCTAssertGreaterThanOrEqual(qs.count, 20)
        for q in qs {
            let t = try XCTUnwrap(PSickFeed.simSeconds(iso: q.t_iso))
            XCTAssertEqual(feed.p(agent: q.agent, at: t), q.p, "\(q.agent) at \(q.t_iso)")
        }
    }

    func testBuildingHeatMatchesWebReading() throws {
        let heat = try load("building_heat.csv", BuildingHeat.parse)
        XCTAssertEqual(heat.rejected, 0)
        let qs = try golden().heat
        XCTAssertGreaterThanOrEqual(qs.count, 20)
        XCTAssertGreaterThanOrEqual(qs.filter { $0.reading == nil }.count, 3)
        for q in qs {
            let t = try XCTUnwrap(PSickFeed.simSeconds(iso: q.t_iso))
            let got = heat.reading(q.building, at: t)
            let label = "\(q.building) at \(q.t_iso)"
            if let want = q.reading {
                let g = try XCTUnwrap(got, label)
                XCTAssertEqual(g.people, want.people, label)
                XCTAssertEqual(g.expectedSick, want.expectedSick, label)
                XCTAssertEqual(g.heat, want.heat, label)
                XCTAssertEqual(g.high, want.high, label)
            } else {
                XCTAssertNil(got, label)
            }
        }
    }

    /// precompute.mjs:470 writes high = (unrounded heat >= 0.5) but heat itself rounded to 3 decimals, so a
    /// row printed "0.500" with high=0 is legitimate (true heat 0.4995...0.5). Every other row must obey it.
    func testHighFlagIsHeatAtLeastHalfInEveryRow() throws {
        let heat = try load("building_heat.csv", BuildingHeat.parse)
        var n = 0, bad = 0
        for s in heat.snapshots { for (_, r) in s.readings {
            n += 1
            if r.high != (r.heat >= 0.5), !(r.heat == 0.5 && !r.high) { bad += 1 }
            XCTAssertTrue((0...1).contains(r.heat))
        } }
        XCTAssertGreaterThan(n, 1000)
        XCTAssertEqual(bad, 0, "\(bad) of \(n) rows have high != (heat >= 0.5)")
    }
}
