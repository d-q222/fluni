import XCTest
@testable import FluniProx

/// The phone's "Your risk" must match model/infer.js (Rio's formula): per source ID,
/// λ = 1 − e^(−stage·Σ unitDose), p ← p + (1 − p)·s·λ from the prior. Golden vectors: CrossCheckTests.
final class RiskTests: XCTestCase {
    private func p(dose: Double, s: Double = RiskEstimate.posTest) -> Double {
        RiskEstimate.probability(["a": .init(dose: dose, s: s)])
    }

    func testNoContactIsTheBaseline() {
        XCTAssertEqual(RiskEstimate.probability([:]), RiskEstimate.prior, accuracy: 1e-12)
        XCTAssertEqual(p(dose: 0), RiskEstimate.prior, accuracy: 1e-12)
        XCTAssertEqual(p(dose: -5), RiskEstimate.prior, accuracy: 1e-12)
        XCTAssertEqual(p(dose: .nan), RiskEstimate.prior, accuracy: 1e-12)
    }

    func testOneContagiousContactByHand() {
        // 15 min at 0.5 m with someone who tested positive, Rio's dose written out (infer.js DEFAULTS:
        // 10 quanta/h, 0.5 m³/h, near field 30·d², 50 m² × 2.7 m room, 2 ach + 0.3 settling + virus decay).
        let rh = 60 * (6.112 * exp(17.62 * 10 / (243.12 + 10))) / (6.112 * exp(17.62 * 21 / (243.12 + 21)))
        let decay = log(1 / 0.75) + (log(1 / 0.2) - log(1 / 0.75)) * (rh - 25) / 20
        let unit = 10 * 0.5 * (900.0 / 3600) * (1 / (30 * 0.5 * 0.5) + 1 / (135 * (2 + 0.3 + decay)))
        let expected = 0.02 + 0.98 * 0.97 * (1 - exp(-0.352 * unit))
        XCTAssertEqual(RiskEstimate.unitDose(distance: 0.5, seconds: 900), unit, accuracy: 1e-12)
        XCTAssertEqual(p(dose: unit), expected, accuracy: 1e-12)
        XCTAssertEqual(p(dose: unit), 0.0752, accuracy: 1e-4)  // ≈ 8%
    }

    func testContactAloneIsBoundedByTheEvidenceLevel() {
        // No cap any more: a huge dose from one positive source gives prior + (1 − prior)·0.97.
        XCTAssertEqual(p(dose: 1e9), 1 - 0.98 * (1 - 0.97), accuracy: 1e-12)
        XCTAssertEqual(p(dose: 1e9, s: RiskEstimate.selfReport), 1 - 0.98 * (1 - 0.6), accuracy: 1e-12)
        XCTAssertEqual(p(dose: .infinity), RiskEstimate.prior, accuracy: 1e-12, "inf is garbage, not max dose")
    }

    func testMonotoneInDose() {
        var last = -1.0
        for d in stride(from: 0.0, through: 200, by: 0.5) {
            let p = self.p(dose: d)
            XCTAssertGreaterThanOrEqual(p, last)
            XCTAssertTrue((0...1).contains(p))
            last = p
        }
    }

    func testPercentTextAndBands() {
        XCTAssertEqual(RiskEstimate.percentText(0), "0%")
        XCTAssertEqual(RiskEstimate.percentText(0.004), "<1%")
        XCTAssertEqual(RiskEstimate.percentText(0.2177), "22%")
        XCTAssertEqual(RiskEstimate.band(RiskEstimate.prior), .low)
        // Shared tiers with the map: elevated from 10%, high from 40%.
        XCTAssertEqual(RiskEstimate.band(0.0999), .low)
        XCTAssertEqual(RiskEstimate.band(0.10), .elevated)
        XCTAssertEqual(RiskEstimate.band(0.3999), .elevated)
        XCTAssertEqual(RiskEstimate.band(0.40), .high)
        // No cap: a long, close contact with someone who tested positive alone can make it high.
        XCTAssertEqual(RiskEstimate.band(p(dose: 1e9)), .high)
    }

    func testDoseDistanceDropsCoarseGPSOnly() {
        func d(_ x: Double, _ s: Double = 0.1, _ src: [Source] = [.uwb]) -> Double? {
            Fusion.doseDistance(Estimate(distance: x, sigma: s, sources: src))
        }
        XCTAssertEqual(d(0.3), 0.3); XCTAssertEqual(d(4.99), 4.99); XCTAssertEqual(d(40), 40)
        XCTAssertNil(d(0.5, 25, [.gps]), "coarse GPS alone adds no dose")
        XCTAssertEqual(d(0.5, 5, [.gps]), 0.5, "good GPS still counts")
        XCTAssertEqual(d(0.5, 25, [.gps, .ble]), 0.5, "GPS with Bluetooth is not GPS-only")
        XCTAssertNil(d(.nan)); XCTAssertNil(d(.infinity)); XCTAssertNil(d(-1))
    }

    func testDosePerIDAndExpiresWithTheWindow() {
        var t = ExposureTracker()
        // 10 sim-minutes: contagious at ~1.5 m (pClose 0.6), and possibly-sick at 0.5 m (pClose 1).
        for _ in 0..<10 {
            t.advance(simSeconds: 60, contacts: [(0.6, .contagious), (1, .possible)],
                      doses: [DosePeer(id: "c", distance: 1.5), DosePeer(id: "p", distance: 0.5)])
        }
        let c = RiskEstimate.unitDose(distance: 1.5, seconds: 600), q = RiskEstimate.unitDose(distance: 0.5, seconds: 600)
        XCTAssertEqual(t.sources["c"]?.dose ?? 0, c, accuracy: 1e-12)
        XCTAssertEqual(t.sources["p"]?.dose ?? 0, q, accuracy: 1e-12)
        XCTAssertEqual(t.sources["c"]?.s, 0.97); XCTAssertEqual(t.sources["p"]?.s, 0.6)
        XCTAssertEqual(t.dose, c + q, accuracy: 1e-12)
        XCTAssertEqual(t.probability, RiskEstimate.probability(["c": .init(dose: c, s: 0.97), "p": .init(dose: q, s: 0.6)]), accuracy: 1e-12)
        XCTAssertEqual(t.minutes, 10 * (0.6 + 0.5), accuracy: 1e-9)
        t.advance(simSeconds: 24 * 3600 + 60, contacts: [])
        XCTAssertEqual(t.dose, 0)
        XCTAssertEqual(t.sources, [:])
        XCTAssertEqual(t.probability, RiskEstimate.prior)
        XCTAssertEqual(t.minutes, 0)
    }

    func testHealthyContactsAddNoDose() {
        var t = ExposureTracker()
        t.advance(simSeconds: 3600, contacts: [(1, .none)], doses: [DosePeer(id: "h", distance: 0.5)])
        XCTAssertEqual(t.dose, 0)
        XCTAssertEqual(t.probability, RiskEstimate.prior)
    }
}
