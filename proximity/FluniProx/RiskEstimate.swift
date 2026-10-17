import Foundation

/// "Your risk" estimate from nearby contacts. Same model as the web demo (model/infer.js DEFAULTS).
enum RiskEstimate {
    /// Chance of transmission per weighted contact-minute (infer.js `beta`).
    static let beta = 0.015
    /// Band edges on the probability: below `elevatedFrom` is low, from `highFrom` is high.
    static let elevatedFrom = 0.10
    static let highFrom = 0.25

    enum Band { case low, elevated, high }

    /// P = 1 - (1 - beta)^weightedMinutes. Bad input (negative, NaN) counts as zero minutes.
    static func probability(weightedMinutes m: Double, beta: Double = RiskEstimate.beta) -> Double {
        let minutes = m.isFinite ? max(m, 0) : 0
        return 1 - pow(1 - beta, minutes)
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
