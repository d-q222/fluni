import Foundation

/// "Your risk" estimate from nearby phones: Rio's exposure formula (Baker et al., PNAS 2021;
/// exposure/flu_risk.py) as model/infer.js computes it, limited to what a phone knows.
///
/// The phone rule (agreed with the heat map team; their phone mock-up in heatmap/app.js does the same):
/// - per contact and tick, a peer at fused distance d (m) within Bluetooth range adds Rio's unit dose
///   for a source talking at peak, in the default room, indoors:
///   unitDose = q · B · (dt/3600) · (1/(nearFieldQ · max(d, 0.3)²) + 1/(V · loss));
/// - doses add up per peer ID over the rolling 24 h window (ExposureTracker);
/// - each sighting carries the peer's evidence level s = max(status s, max(0, P_peer − prior)): the status
///   it broadcasts (tested positive 0.97, symptoms 0.6) or its own broadcast score P_peer above the prior
///   (`sourceS`), from the latest beacon heard for that ID; the tracker keeps the highest s seen in the window;
/// - each contact's dose is weighted by the peer's stage: `stageFactor` of the days since its symptom onset
///   (or positive test) when the peer broadcasts them, else the illness average `stage` (0.352);
/// - the room is this phone's own place (`Room`): the building it is in, outdoors, or the default room;
/// - p starts at the prior and, per ID, p ← p + (1 − p) · s · (1 − e^(−Σ stage · unitDose)).
///   No second-hand term, no recovery.
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
    /// Quanta per hour in a dorm room, where a case barely talks (`quietQuanta`).
    static let quietQuanta = 1.5
    /// Wind dilutes the plume this much more outdoors (`outdoorNearDilution`).
    static let outdoorNearDilution = 5.0

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

    /// The air this phone is in (infer.js `doseModel`'s room / indoor inputs). Built only from this phone's
    /// own place (RoomContext); nothing about it is broadcast.
    struct Room: Equatable {
        /// m³ (`volume_m3`); 0 outdoors.
        let volume: Double
        /// 1/h ventilation (`ventilation_ach`).
        let ach: Double
        /// A dorm room: quietQuanta instead of quantaPeak (infer.js: room_type starts with "dorm").
        let dorm: Bool
        let indoor: Bool
        /// 1/h ventilation + settling + virus decay (infer.js `mkRoom` loss).
        var loss: Double { ach + deposition + roomDecay }
        /// The shared-room-air term 1/(V · loss) (infer.js `room.far`); 0 outdoors.
        var far: Double { indoor ? 1 / (volume * loss) : 0 }

        /// infer.js `mkRoom` for a rooms.csv row: a missing or non-positive volume or ach falls back to
        /// the default room's (`v > 0 ? v : defRoom.volume`, `a > 0 ? a : defaultAch`).
        static func room(volume: Double, ach: Double, dorm: Bool) -> Room {
            Room(volume: volume.isFinite && volume > 0 ? volume : roomVolume,
                 ach: ach.isFinite && ach > 0 ? ach : defaultAch, dorm: dorm, indoor: true)
        }
        /// The room when the contact has no known room (`defRoom`).
        static let standard = Room(volume: roomVolume, ach: defaultAch, dorm: false, indoor: true)
        /// infer.js `indoor = false`: no shared-room term, the plume diluted outdoorNearDilution times more.
        static let outdoors = Room(volume: 0, ach: 0, dorm: false, indoor: false)
    }

    /// Rio's unit dose (infer.js `doseModel(params, rooms)(c)`) for `seconds` at `distance` metres in
    /// `room`; the default room unless the phone knows its place. Same arithmetic, in the same order, as infer.js.
    static func unitDose(distance: Double, seconds: Double, room: Room = .standard) -> Double {
        let d = max(distance, minDistance)
        let qNear = nearFieldQ * d * d * (room.indoor ? 1 : outdoorNearDilution)
        let quanta = room.indoor && room.dorm ? quietQuanta : quantaPeak
        return 1 * quanta * breathingRate * (seconds / 3600) * (1 / qNear + (room.indoor ? room.far : 0))
    }

    /// The dose one contact adds on the phone: `unitDose`, or 0 when the input is unusable (distance or
    /// seconds NaN, infinite or negative) or the peer is beyond `doseRange`.
    static func contactDose(distance: Double, seconds: Double, room: Room = .standard) -> Double {
        guard distance.isFinite, distance >= 0, distance <= doseRange,
              seconds.isFinite, seconds > 0 else { return 0 }
        return unitDose(distance: distance, seconds: seconds, room: room)
    }

    /// infer.js `stageFactor`: relative infectiousness `day` whole days after the source's symptom onset
    /// (or positive test); 0 outside -2...7.
    static func stageFactor(day: Int) -> Double {
        day < -2 || day > 7 ? 0 : stageProfile[day + 2]
    }

    /// The stage a contact with a peer uses: `stageFactor` of the days the peer broadcasts while it reports
    /// symptoms or a positive test (infer.js: a source with own evidence uses its onset), else the illness
    /// average (infer.js `stageMean`: no dated evidence, as for second-hand risk; and old builds).
    static func sourceStage(status: Risk, daysSinceOnset: Int?) -> Double {
        guard status != .none, let d = daysSinceOnset else { return stage }
        return stageFactor(day: d)
    }

    /// The evidence level s a peer's broadcast status carries (0 for healthy).
    static func evidence(_ risk: Risk) -> Double {
        switch risk {
        case .none: return 0
        case .possible: return selfReport
        case .contagious: return posTest
        }
    }

    /// A peer's evidence level s (infer.js `s_j`, Rio's P_j as a phone can know it): the larger of its
    /// broadcast status's level and its broadcast score above the prior. `score` nil (an old FLU1 beacon,
    /// or ContactGuard rejected it) or unusable leaves the status level.
    static func sourceS(status: Risk, score: Double?) -> Double {
        let e = evidence(status)
        guard let p = score, p.isFinite else { return e }
        return max(e, max(0, min(p, 1) - prior))
    }

    /// The lowest score a person's own status allows: tested positive 0.97, symptoms 0.6, else 0.
    static func statusFloor(_ status: Risk) -> Double { evidence(status) }

    /// This phone's own score: its estimate, never below its user's status floor (product owner 2026-10-17:
    /// someone who is infected must not read low).
    static func ownScore(liveRisk: Double, status: Risk) -> Double {
        max(liveRisk.isFinite ? min(max(liveRisk, 0), 1) : prior, statusFloor(status))
    }

    /// One source (rotating peer ID) over the window: its summed unit dose, its stage-weighted dose
    /// Σ stage · unitDose (infer.js pair dose) and its evidence level.
    struct Source: Equatable, Codable {
        var dose = 0.0
        var s = 0.0
        var weighted: Double

        init(dose: Double = 0, s: Double = 0, weighted: Double? = nil) {
            self.dose = dose
            self.s = s
            self.weighted = weighted ?? RiskEstimate.stage * dose
        }
    }

    /// p from the prior and each source: p ← p + (1 − p) · s · λ, λ = 1 − e^(−Σ stage · unitDose).
    /// Sources are folded in ID order so the result is deterministic. Unusable values count as nothing.
    static func probability(_ sources: [String: Source]) -> Double {
        var p = prior
        for id in sources.keys.sorted() {
            guard let src = sources[id], src.weighted.isFinite, src.weighted > 0, src.s.isFinite, src.s > 0 else { continue }
            let lambda = 1 - exp(-src.weighted)
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

/// This phone's own score and the value it broadcasts (product owner 2026-10-17: each phone broadcasts its
/// own percentage so others can use it; FlUni never shows it to them).
///
/// One-tick lag: the score broadcast during tick n is the ownScore computed at tick n − 1. A phone's estimate
/// at tick n already uses its peers' broadcast scores, so broadcasting it at once would let two phones feed
/// each other's current value back within the same tick; with the lag each phone only ever reads a value
/// its peer had computed before this tick (and s = P − prior means nobody can start an echo from the 2%
/// baseline).
struct OwnScoreLag: Equatable {
    /// max(estimate, status floor) as of the latest tick or status change: what the UI may show this user.
    private(set) var current: Double
    /// What the beacon carries: `current` as it was at the previous tick.
    private(set) var broadcast: Double

    /// `liveRisk`: the estimate to start from (the prior, or the one restored after a relaunch, RiskStateStore).
    init(liveRisk: Double = RiskEstimate.prior, status: Risk = .none) {
        current = RiskEstimate.ownScore(liveRisk: liveRisk, status: status)
        broadcast = current
    }

    /// The 1 s tick: last tick's score goes on the air, the new one becomes current.
    mutating func tick(liveRisk: Double, status: Risk) {
        broadcast = current
        current = RiskEstimate.ownScore(liveRisk: liveRisk, status: status)
    }

    /// The user changed their status between ticks: the shown score follows at once (an infected user never
    /// reads low, not even for a second). The broadcast score waits for the next tick; the beacon's status
    /// byte carries the new status right away, and a peer's s takes the larger of the two.
    mutating func statusChanged(liveRisk: Double, status: Risk) {
        current = RiskEstimate.ownScore(liveRisk: liveRisk, status: status)
    }
}

extension RiskEstimate {
    /// The days a phone broadcasts: whole calendar days from its user's day 0 (the earlier of symptom onset
    /// and positive test, SelfReportRecord.dayZero) to today, the same count as SelfReporter.dayNumber.
    /// nil (broadcast as "unknown") while healthy or without a day 0. Clamped to 0...14 (BLEBeacon.maxDays).
    static func daysSinceOnset(dayZero: Date?, status: Risk, now: Date, calendar: Calendar = .current) -> Int? {
        guard status != .none, let zero = dayZero,
              let d = calendar.dateComponents([.day], from: calendar.startOfDay(for: zero), to: calendar.startOfDay(for: now)).day
        else { return nil }
        return min(max(d, 0), BLEBeacon.maxDays)
    }
}
