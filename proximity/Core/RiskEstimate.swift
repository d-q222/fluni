import Foundation

/// "Your risk" estimate from nearby phones: Rio's exposure formula (Baker et al., PNAS 2021;
/// exposure/flu_risk.py) as model/infer.js computes it, limited to what a phone knows.
///
/// The phone rule (agreed with the heat map team; their phone mock-up in heatmap/app.js does the same):
/// - per contact and tick, a peer at fused distance d (m) within Bluetooth range adds Rio's unit dose
///   for a source talking at peak, in the default room, indoors:
///   unitDose = q · B · (dt/3600) · (1/(nearFieldQ · max(d, 0.3)²) + 1/(V · loss));
/// - doses add up per peer ID over the rolling 24 h window (ExposureTracker);
/// - each ID's evidence level s is what it broadcasts (tested positive 0.97, symptoms 0.6), the
///   highest seen in the window;
/// - p starts at the prior and, per ID, p ← p + (1 − p) · s · (1 − e^(−stage · Σ unitDose)), where
///   stage is the illness average (a phone never knows the onset). No second-hand term, no recovery.
///
/// The constants are infer.js DEFAULTS; the derived ones (indoor RH, virus decay, V, loss) are computed
/// here with the same functions as infer.js. CrossCheckTests compares both with golden.json, made by
/// Tests/Fixtures/xcheck/make_golden.mjs from the real infer.js.
enum RiskEstimate {
    // MARK: infer.js DEFAULTS (keep in step with model/infer.js)

    /// Community baseline (`prior`).
    static let prior = 0.02
    /// A peer that says it might be sick (`selfReport`).
    static let selfReport = 0.6
    /// A peer that says it tested positive (`posTest`).
    static let posTest = 0.97
    /// Infectious quanta per hour at peak, talking-level (`quantaPeak`).
    static let quantaPeak = 10.0
    /// m³/h inhaled (`breathingRate`).
    static let breathingRate = 0.5
    /// m³/h dilution of the exhaled plume at 1 m, scaling with distance² (`nearFieldQ`).
    static let nearFieldQ = 30.0
    /// 1/h particle settling (`deposition`).
    static let deposition = 0.3
    /// The room when the contact has no known room (`defaultRoomM2`, `ceilingM`, `defaultAch`).
    static let defaultRoomM2 = 50.0
    static let ceilingM = 2.7
    static let defaultAch = 2.0
    /// Campus in January (`outdoorRH`, `outdoorTempC`, `indoorTempC`).
    static let outdoorRH = 60.0
    static let outdoorTempC = 10.0
    static let indoorTempC = 21.0
    /// Relative infectiousness by days since the source's symptom onset, -2...7 (`stageProfile`).
    static let stageProfile = [0.05, 0.3, 1.0, 0.9, 0.6, 0.35, 0.18, 0.08, 0.04, 0.02]
    /// Closest distance the near-field term uses (infer.js `Math.max(dist, 0.3)`).
    static let minDistance = 0.3

    // MARK: Phone-only

    /// Bluetooth range: a peer farther than this (fused distance, metres) adds no dose. Inclusive, as the
    /// heat map's phone mock-up (heatmap/app.js `BT_RANGE_M`, `d <= 10`): 10.0 counts, 10.01 doesn't.
    static let doseRange = 10.0

    // MARK: Derived, with infer.js's own functions

    /// Heated outdoor air keeps its water, so indoor RH is lower than outdoor in cold weather (Magnus;
    /// infer.js `indoorRH`).
    static func indoorRH(outdoorRH: Double, outdoorTempC: Double, indoorTempC: Double = 21) -> Double {
        if outdoorTempC >= indoorTempC { return outdoorRH }
        func sat(_ t: Double) -> Double { 6.112 * exp((17.62 * t) / (243.12 + t)) }
        return min(100, (outdoorRH * sat(outdoorTempC)) / sat(indoorTempC))
    }

    /// 1/h airborne inactivation of influenza vs relative humidity (Noti et al. 2013; infer.js `virusDecay`).
    static func virusDecay(rh: Double) -> Double {
        let low = log(1 / 0.75), high = log(1 / 0.2)
        if rh <= 25 { return low }
        if rh >= 45 { return high }
        return low + ((high - low) * (rh - 25)) / 20
    }

    static let roomRH = indoorRH(outdoorRH: outdoorRH, outdoorTempC: outdoorTempC, indoorTempC: indoorTempC)
    static let roomDecay = virusDecay(rh: roomRH)
    /// Default room volume V, m³ (infer.js `defaultRoomM2 * ceilingM`).
    static let roomVolume = defaultRoomM2 * ceilingM
    /// Default room loss rate, 1/h: ventilation + settling + virus decay (infer.js `mkRoom`).
    static let roomLoss = defaultAch + deposition + roomDecay
    /// The shared-room-air term 1/(V · loss) (infer.js `room.far`).
    static let roomFar = 1 / (roomVolume * roomLoss)
    /// Illness-average stage factor: the mean of stageProfile (infer.js `stageMean`, 0.352).
    static let stage = stageProfile.reduce(0, +) / Double(stageProfile.count)

    /// Rio's unit dose (infer.js `doseModel()(c)` with no rooms, indoors, quantaPeak) for `seconds` at
    /// `distance` metres. Same arithmetic, in the same order, as infer.js.
    static func unitDose(distance: Double, seconds: Double) -> Double {
        let d = max(distance, minDistance)
        let qNear = nearFieldQ * d * d * 1  // indoors: no outdoorNearDilution
        return 1 * quantaPeak * breathingRate * (seconds / 3600) * (1 / qNear + roomFar)
    }

    /// The dose one contact adds on the phone: `unitDose`, or 0 when the input is unusable (distance or
    /// seconds NaN, infinite or negative) or the peer is beyond `doseRange`.
    static func contactDose(distance: Double, seconds: Double) -> Double {
        guard distance.isFinite, distance >= 0, distance <= doseRange,
              seconds.isFinite, seconds > 0 else { return 0 }
        return unitDose(distance: distance, seconds: seconds)
    }

    /// The evidence level s a peer's broadcast status carries (0 for healthy).
    static func evidence(_ risk: Risk) -> Double {
        switch risk {
        case .none: return 0
        case .possible: return selfReport
        case .contagious: return posTest
        }
    }

    /// One source (rotating peer ID) over the window: its summed unit dose and its evidence level.
    struct Source: Equatable {
        var dose = 0.0
        var s = 0.0
    }

    /// p from the prior and each source: p ← p + (1 − p) · s · λ, λ = 1 − e^(−stage · dose).
    /// Sources are folded in ID order so the result is deterministic. Unusable values count as nothing.
    static func probability(_ sources: [String: Source]) -> Double {
        var p = prior
        for id in sources.keys.sorted() {
            guard let src = sources[id], src.dose.isFinite, src.dose > 0, src.s.isFinite, src.s > 0 else { continue }
            let lambda = 1 - exp(-stage * src.dose)
            p += (1 - p) * min(src.s, 1) * lambda
        }
        return p
    }

    // MARK: Display

    /// The shared risk tiers (heatmap/app.js TIERS, from the design pass): one set for the phone's
    /// advice, the risk card's colour and the map. Low < 10% (sage), Elevated 10–40% (sun), High ≥ 40% (fire).
    static let elevatedFrom = 0.10
    static let highFrom = 0.40

    enum Band { case low, elevated, high }

    static func band(_ p: Double) -> Band { p >= highFrom ? .high : (p >= elevatedFrom ? .elevated : .low) }

    /// Whole percent; "<1%" for small non-zero values, "0%" only for exactly zero.
    static func percentText(_ p: Double) -> String {
        if p <= 0 { return "0%" }
        let pct = (p * 100).rounded()
        return pct < 1 ? "<1%" : "\(Int(min(pct, 100)))%"
    }

    /// The live on-screen number: one decimal below 10%, so a 1 s tick near someone sick visibly moves it
    /// (2.0% → 2.1% → …); whole percent from 10% (as `percentText`). `percentText` stays the whole-percent
    /// text shared with the heat map (heatmap/app.js `percentText`).
    static func liveText(_ p: Double) -> String {
        if !(p > 0) { return "0%" }
        let tenths = (p * 1000).rounded() / 10
        return tenths < 10 ? String(format: "%.1f%%", tenths) : "\(Int(min((p * 100).rounded(), 100)))%"
    }

    static func summary(_ p: Double) -> String {
        switch band(p) {
        // Same words as the map's advice (heatmap/app.js `advice`).
        case .low: return "Low. No action needed."
        case .elevated: return "Elevated. Wear a mask in crowded rooms and watch for symptoms."
        case .high: return "High. Consider getting tested at Vaden and staying home."
        }
    }
}
