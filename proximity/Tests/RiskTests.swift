import XCTest
@testable import FluniProx

/// The phone's "Your risk" must match model/infer.js: π = 1 − e^(−β·w·min), x ≤ xMax, p = 1 − (1 − prior)(1 − x).
final class RiskTests: XCTestCase {
    func testNoContactIsTheBaseline() {
        XCTAssertEqual(RiskEstimate.probability(dose: 0), RiskEstimate.prior, accuracy: 1e-12)
        XCTAssertEqual(RiskEstimate.probability(dose: -5), RiskEstimate.prior, accuracy: 1e-12)
        XCTAssertEqual(RiskEstimate.probability(dose: .nan), RiskEstimate.prior, accuracy: 1e-12)
    }

    func testOneContagiousContactMatchesInferJS() {
        // 15 min under 1 m with someone contagious (s = 1, w = 1), computed the infer.js way.
        let pi = 1 - exp(-0.015 * 1 * 15)
        let x = 1 - (1 - 0) * (1 - 1 * pi)
        let expected = 1 - (1 - 0.02) * (1 - min(x, 0.3))
        XCTAssertEqual(RiskEstimate.probability(dose: 15), expected, accuracy: 1e-12)
        XCTAssertEqual(RiskEstimate.probability(dose: 15), 0.2177, accuracy: 1e-3)  // ≈ 22%
    }

    func testContactTermIsCappedAtXMax() {
        XCTAssertEqual(RiskEstimate.contactTerm(dose: 10_000), 0.3, accuracy: 1e-12)
        XCTAssertEqual(RiskEstimate.probability(dose: .infinity), RiskEstimate.prior, accuracy: 1e-12, "inf is garbage, not max dose")
        XCTAssertEqual(RiskEstimate.probability(dose: 1e9), 1 - 0.98 * 0.7, accuracy: 1e-12)
    }

    func testMonotoneInDose() {
        var last = -1.0
        for d in stride(from: 0.0, through: 200, by: 0.5) {
            let p = RiskEstimate.probability(dose: d)
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
        // Contact alone is capped (xMax 0.3, prior 0.02 → at most 31.4%), so only reports can make it high.
        XCTAssertEqual(RiskEstimate.band(RiskEstimate.probability(dose: 1e9)), .elevated)
    }

    func testTierWeightsMatchInferJS() {
        func w(_ d: Double, _ s: Double = 0.1, _ src: [Source] = [.uwb]) -> Double {
            Fusion.tierWeight(Estimate(distance: d, sigma: s, sources: src))
        }
        XCTAssertEqual(w(0.3), 1); XCTAssertEqual(w(0.999), 1)
        XCTAssertEqual(w(1.0), 0.6); XCTAssertEqual(w(1.99), 0.6)
        XCTAssertEqual(w(2.0), 0.1); XCTAssertEqual(w(4.99), 0.1)
        XCTAssertEqual(w(5.0), 0.02); XCTAssertEqual(w(40), 0.02)
        XCTAssertEqual(w(0.5, 25, [.gps]), 0, "coarse GPS alone adds no dose")
        XCTAssertEqual(w(0.5, 5, [.gps]), 1, "good GPS still counts")
    }

    func testDoseUsesTiersAndExpiresWithTheWindow() {
        var t = ExposureTracker()
        // 10 sim-minutes: contagious at ~1.5 m (tier 0.6, pClose 0.6), and possibly-sick under 1 m (tier 1).
        for _ in 0..<10 {
            t.advance(simSeconds: 60, contacts: [(0.6, .contagious), (1, .possible)], tiers: [0.6, 1])
        }
        XCTAssertEqual(t.dose, 10 * (1 * 0.6 + 0.5 * 1), accuracy: 1e-9)
        XCTAssertEqual(t.minutes, 10 * (0.6 + 0.5), accuracy: 1e-9)
        t.advance(simSeconds: 24 * 3600 + 60, contacts: [])
        XCTAssertEqual(t.dose, 0)
        XCTAssertEqual(t.minutes, 0)
    }

    func testHealthyContactsAddNoDose() {
        var t = ExposureTracker()
        t.advance(simSeconds: 3600, contacts: [(1, .none)], tiers: [1])
        XCTAssertEqual(t.dose, 0)
    }
}
