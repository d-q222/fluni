import Foundation

/// Pure rules that limit what a spoofed Bluetooth beacon can do to the exposure total.
/// Nothing authenticates a beacon, so these need no server and no product decision. Applied once per tick,
/// just before `ExposureTracker.advance`. Everything uses real time (`now`), which is clamped so a clock
/// that steps backwards never rewinds the state.
///
/// Rules and thresholds:
/// 1. Per-tick cap: only the top 2 risky contacts by pClose x risk weight count. One real person can't
///    give more than real time, and two real sick people beside you is the realistic maximum.
/// 2. Burst: more than `burstLimit` (4) IDs first seen as risky within `window` (5 min) raises `flagged`;
///    while flagged, Bluetooth-only contacts add nothing. A phone rotates its ID every 15 min, so normal
///    rotation adds at most 1 new ID per window and cannot trip it. Every ID first seen during a burst stays
///    suspect while it keeps showing up (and for `flipWindow` after), so its Bluetooth-only contacts never count,
///    even after the window has passed. `flagged` stays set while any suspect ID is around.
/// 3. Implausible signal (Bluetooth-only): RSSI above `maxRSSI` (-30 dBm) or a jump over `maxJump` (20 dB)
///    within `jumpWithin` (2 s) counts as not close for that tick. Field data: 0.3-0.8 m reads -60..-50 dBm,
///    the strongest at ~0.2 m was -42, so -30 leaves 12 dB margin; BLE noise is a few dB, so 20 dB is not noise.
/// 4. Risk flapping: a risk that reverses direction (up then down, or down then up) for one ID within
///    `flipWindow` (15 min) -> ID ignored. A real phone changes risk only when its user reports, and reports
///    escalate (healthy -> possibly sick -> tested positive) far more than they bounce; a one-way climb is fine.
/// 5. `corroborated` = a fresh UWB reading exists for the ID. Reported only; no rule requires it.
/// 6. Implausible score: a broadcast score is ignored (the contact falls back to its status level s) when the
///    status is healthy but the score is ≥ `maxScoreWithoutStatus` (0.9), or when it differs by more than
///    `maxScoreJump` (0.5) from any score the ID sent within `scoreJumpWithin` (1 min). A real phone's score
///    moves about 1 percentage point a minute at most; a report jumps it, but then the status carries the same
///    level. Rule 2 also counts an ID as risky when its score alone gives s ≥ selfReport (0.6), so a flood of
///    "healthy" IDs with high scores trips the burst rule too.
/// Rule 1 also caps the dose: at most `topContacts` sources keep their distance, ranked by what they add
/// (s · stage · unit dose at their distance), so a crowd of slightly exposed classmates (s from scores just
/// above the prior) can't push a sick person out, and many fake IDs can't add up.
/// A contact's `distance` (for the risk dose) is dropped (nil) whenever its pClose is zeroed by a rule, so
/// the same rules limit the dose. Rule 1 also lets a risky contact with a distance but pClose 0 (beyond
/// 6 ft, precisely ranged) fill a free top-2 slot for the dose; it ranks below every pClose > 0 contact,
/// so it never displaces one.
struct ContactGuard {
    static let topContacts = 2
    static let window: TimeInterval = 300
    static let burstLimit = 4
    static let maxRSSI = -30.0
    static let maxJump = 20.0
    static let jumpWithin: TimeInterval = 2
    static let flipWindow: TimeInterval = 900
    static let maxScoreWithoutStatus = 0.9
    static let maxScoreJump = 0.5
    static let scoreJumpWithin: TimeInterval = 60

    struct Input {
        var id: String
        var risk: Risk
        var pClose: Double
        /// Fused distance in metres for the risk dose; nil without an estimate or with coarse GPS only.
        var distance: Double?
        var rssi: Double? = nil
        var sources: [Source] = [.ble]
        var uwbAt: Date? = nil
        /// The peer's broadcast score (its own P), from its latest beacon; nil from an old FLU1 beacon.
        var score: Double? = nil
        /// Days since the peer's symptom onset or positive test, as it broadcasts them; nil = unknown.
        var days: Int? = nil
    }

    struct Output: Equatable {
        var id: String
        var risk: Risk
        var pClose: Double
        var distance: Double?
        var corroborated: Bool
        /// The score rule 6 let through; nil = unknown or ignored (s falls back to the status level).
        var score: Double? = nil
        var days: Int? = nil

        /// The evidence level this contact carries (RiskEstimate.sourceS).
        var s: Double { RiskEstimate.sourceS(status: risk, score: score) }
        /// The stage this contact's dose is weighted by (RiskEstimate.sourceStage).
        var stage: Double { RiskEstimate.sourceStage(status: risk, daysSinceOnset: days) }
    }

    /// True while an ID burst is in progress. The UI shows "unusual signals" while it is set.
    private(set) var flagged = false

    private var now = Date.distantPast
    private var firstRisky: [String: Date] = [:]
    private var lastSeen: [String: Date] = [:]
    private var suspect: Set<String> = []  // IDs first seen during a burst
    private var lastRSSI: [String: (rssi: Double, at: Date)] = [:]
    private var lastRisk: [String: Risk] = [:]
    private var lastRiskRose: [String: Bool] = [:]  // direction of each ID's last risk change
    private var flips: [String: [Date]] = [:]
    private var flipLogged: Set<String> = []
    private var scoreSeen: [String: [(score: Double, at: Date)]] = [:]
    private var scoreLogged: Set<String> = []

    /// Rule 6: the score to use for this sighting, or nil. Records every score heard, so a score that keeps
    /// bouncing stays ignored.
    private mutating func plausibleScore(_ p: Input, log: (String) -> Void) -> Double? {
        guard let sc = p.score, sc.isFinite, sc >= 0, sc <= 1 else { return nil }
        let recent = (scoreSeen[p.id] ?? []).filter {
            let age = now.timeIntervalSince($0.at)
            return age >= 0 && age <= Self.scoreJumpWithin
        }
        let bad = (p.risk == .none && sc >= Self.maxScoreWithoutStatus)
            || recent.contains { abs($0.score - sc) > Self.maxScoreJump }
        scoreSeen[p.id] = recent + [(sc, now)]
        if bad {
            if scoreLogged.insert(p.id).inserted { log("guard score implausible id=\(p.id.prefix(6)) ignored") }
            return nil
        }
        scoreLogged.remove(p.id)
        return sc
    }

    mutating func apply(now rawNow: Date, _ peers: [Input], log: (String) -> Void = { _ in }) -> [Output] {
        now = max(now, rawNow)
        prune()

        // Rule 4 and 2 bookkeeping.
        var ignored: Set<String> = []
        var scores: [String: Double] = [:]
        for p in peers {
            if let sc = plausibleScore(p, log: log) { scores[p.id] = sc }
            lastSeen[p.id] = now
            if let old = lastRisk[p.id], old != p.risk {
                let rose = p.risk.rawValue > old.rawValue
                if let prev = lastRiskRose[p.id], prev != rose { flips[p.id, default: []].append(now) }  // a reversal
                lastRiskRose[p.id] = rose
            }
            lastRisk[p.id] = p.risk
            flips[p.id] = flips[p.id]?.filter { now.timeIntervalSince($0) < Self.flipWindow }
            if !(flips[p.id]?.isEmpty ?? true) {
                ignored.insert(p.id)
                if flipLogged.insert(p.id).inserted { log("guard risk flip id=\(p.id.prefix(6)) ignored") }
            } else {
                flipLogged.remove(p.id)
            }
            let risky = p.risk != .none || RiskEstimate.sourceS(status: p.risk, score: scores[p.id]) >= RiskEstimate.selfReport
            if risky, firstRisky[p.id] == nil { firstRisky[p.id] = now }
        }
        let fresh = firstRisky.filter { now.timeIntervalSince($0.value) < Self.window }
        let burstNow = fresh.count > Self.burstLimit
        if burstNow {
            if suspect.isEmpty { log("guard burst ids=\(fresh.count)") }
            suspect.formUnion(fresh.keys)
        }
        flagged = !suspect.isEmpty

        // Rules 3 and 5, then rule 1 over what is left.
        var out: [Output] = []
        for p in peers {
            let uwbFresh = p.uwbAt.map { now.timeIntervalSince($0) < Source.uwb.maxAge && $0 <= now.addingTimeInterval(1) } ?? false
            let bleOnly = !uwbFresh && Set(p.sources) == [.ble]
            var pClose = p.pClose.isFinite ? min(max(p.pClose, 0), 1) : 0
            var distance = p.distance.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            var bad = ignored.contains(p.id) || (bleOnly && (burstNow || suspect.contains(p.id)))
            if let r = p.rssi, r.isFinite {
                if bleOnly {
                    if r > Self.maxRSSI { bad = true }
                    if let l = lastRSSI[p.id], now.timeIntervalSince(l.at) <= Self.jumpWithin,
                       abs(r - l.rssi) > Self.maxJump { bad = true }
                }
                lastRSSI[p.id] = (r, now)
            }
            if bad { pClose = 0; distance = nil }
            let days = p.days.flatMap { (0 ... BLEBeacon.maxDays).contains($0) ? $0 : nil }
            out.append(Output(id: p.id, risk: p.risk, pClose: pClose, distance: distance, corroborated: uwbFresh,
                              score: scores[p.id], days: days))
        }
        let keep = Set(out.indices.filter { out[$0].risk != .none && (out[$0].pClose > 0 || out[$0].distance != nil) }
            .sorted {
                let a = out[$0].pClose * out[$0].risk.weight, b = out[$1].pClose * out[$1].risk.weight
                return a != b ? a > b : out[$0].id < out[$1].id
            }.prefix(Self.topContacts))
        for i in out.indices where out[i].risk != .none && !keep.contains(i) { out[i].pClose = 0; out[i].distance = nil }
        // Rule 1 for the dose, over every source left with a distance (healthy peers without a score add none).
        let adds = { (o: Output) -> Double in o.s * o.stage * RiskEstimate.unitDose(distance: o.distance ?? .infinity, seconds: 1) }
        let doseKeep = Set(out.indices.filter { out[$0].distance != nil && out[$0].s > 0 }
            .sorted {
                let a = adds(out[$0]), b = adds(out[$1])
                return a != b ? a > b : out[$0].id < out[$1].id
            }.prefix(Self.topContacts))
        for i in out.indices where out[i].distance != nil && out[i].s > 0 && !doseKeep.contains(i) { out[i].distance = nil }
        return out
    }

    private mutating func prune() {
        // An ID is forgotten only once it has been gone for `flipWindow`; one that lingers is never "new" again.
        lastSeen = lastSeen.filter { now.timeIntervalSince($0.value) < Self.flipWindow }
        firstRisky = firstRisky.filter { lastSeen[$0.key] != nil }
        suspect = suspect.filter { lastSeen[$0] != nil }
        lastRSSI = lastRSSI.filter { now.timeIntervalSince($0.value.at) < Self.window }
        flips = flips.filter { $0.value.contains { now.timeIntervalSince($0) < Self.flipWindow } }
        scoreSeen = scoreSeen.filter { $0.value.contains { now.timeIntervalSince($0.at) <= Self.scoreJumpWithin } }
        scoreLogged = scoreLogged.filter { scoreSeen[$0] != nil }
        if lastRisk.count > 500 { lastRisk.removeAll() }
    }
}
