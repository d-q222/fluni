import Foundation

/// "Your risk" estimate from nearby contacts, matching model/infer.js (DEFAULTS: beta, xMax, prior).
enum RiskEstimate {
    /// Transmission chance per distance-weighted contact-minute (infer.js `beta`).
    static let beta = 0.015
    /// Contact alone never pushes the contact term above this (infer.js `xMax`).
    static let xMax = 0.3
    /// Community baseline (infer.js `prior`).
    static let prior = 0.02
    /// Band edges on the probability: below `elevatedFrom` is low, from `highFrom` is high.
    static let elevatedFrom = 0.10
    static let highFrom = 0.25

    enum Band { case low, elevated, high }

    /// infer.js folds contacts as x ← 1 − (1 − x)(1 − s·π), π = 1 − e^(−β·w·min). Here all contacts arrive
    /// as one dose = Σ s·w·min, so x = 1 − e^(−β·dose): exact for one contagious contact, a close
    /// first-order match otherwise. Then x ≤ xMax and p = 1 − (1 − prior)(1 − x).
    /// Bad input (negative, NaN) counts as zero dose.
    static func contactTerm(dose: Double) -> Double {
        let d = dose.isFinite ? max(dose, 0) : 0
        return min(1 - exp(-beta * d), xMax)
    }

    static func probability(dose: Double) -> Double {
        1 - (1 - prior) * (1 - contactTerm(dose: dose))
    }

    static func band(_ p: Double) -> Band { p >= highFrom ? .high : (p >= elevatedFrom ? .elevated : .low) }

    /// Whole percent; "<1%" for small non-zero values, "0%" only for exactly zero.
    static func percentText(_ p: Double) -> String {
        if p <= 0 { return "0%" }
        let pct = (p * 100).rounded()
        return pct < 1 ? "<1%" : "\(Int(min(pct, 100)))%"
    }

    static func summary(_ p: Double) -> String {
        switch band(p) {
        case .low: return "Low. Little time near anyone who may be contagious."
        case .elevated: return "Elevated. Keep your distance and watch for symptoms."
        case .high: return "High. Consider testing if you develop symptoms."
        }
    }
}
