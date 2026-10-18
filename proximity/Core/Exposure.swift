import Foundation

/// What a phone broadcasts about its own user. Kept to 3 levels on purpose (low-bit, like GAEN).
enum Risk: Int, Codable, CaseIterable {
    case none = 0, possible = 1, contagious = 2

    var label: String {
        switch self {
        case .none: return "Healthy"
        case .possible: return "Possibly sick"
        case .contagious: return "Contagious"
        }
    }

    /// How much an exposure minute to this person counts.
    var weight: Double {
        switch self {
        case .none: return 0
        case .possible: return 0.5
        case .contagious: return 1
        }
    }
}

enum AlertLevel: Int, Comparable, Codable {
    case none = 0, nearby = 1, closeContact = 2
    /// flu-expo: a heads-up with a contagious (tested positive) person in range. Above `nearby`, so going from
    /// possibly sick to contagious is a new, stronger alert; below close contact. Raw 3 keeps saved values; order by rank.
    case nearbyContagious = 3
    private var rank: Int {
        switch self {
        case .none: return 0
        case .nearby: return 1
        case .nearbyContagious: return 2
        case .closeContact: return 3
        }
    }
    /// Either heads-up (possibly sick or contagious nearby).
    var isHeadsUp: Bool { self == .nearby || self == .nearbyContagious }
    static func < (a: AlertLevel, b: AlertLevel) -> Bool { a.rank < b.rank }
}

/// When to send a notification for the alert level. The notified level follows the level down as well as up,
/// so a later nearby or close contact notifies again; it never notifies for the same or a lower level.
enum AlertNotifier {
    static func next(level: AlertLevel, notified: AlertLevel) -> (notified: AlertLevel, notify: AlertLevel?) {
        level > notified ? (level, level) : (level, nil)
    }
}

/// One contact's input to the risk dose: the peer's rotating ID, its fused distance in metres, the
/// share of the tick it covers (AccrualFeed splits a long background credit into whole ticks plus a part),
/// the peer's evidence level s and stage (nil: from the contact's status, illness-average stage) and the
/// room this phone is in.
struct DosePeer: Equatable {
    var id: String
    var distance: Double
    var share = 1.0
    var s: Double? = nil
    var stage: Double? = nil
    var room: RiskEstimate.Room = .standard
}

/// Counts close-contact minutes as one running episode, the campus model's rule: weighted minutes within 6 ft of
/// someone who may be sick keep adding up, and drop to exactly 0 once `episodeGap` (2 h) has passed since the
/// last such moment. Healthy peers neither add minutes nor keep the episode alive. Only the largest weight among
/// the peers in range counts at any moment (two sick people at once don't double-count), and the weight is the
/// peer's broadcast status only (1 contagious, 0.5 possibly sick). It decides the alert level. Alongside, it
/// keeps Rio's dose per peer ID over a rolling 24 h window for the risk estimate (RiskEstimate); that
/// stays as it was.
struct ExposureTracker: Equatable, Codable {
    static let closeContactMinutes = 15.0
    static let window = 24 * 3600.0  // simulated seconds, so the demo speed-up applies; the dose's window only
    /// The minutes reset to 0 after this long without a weighted moment (simulated seconds).
    static let episodeGap = 2 * 3600.0
    /// P(within 6 ft) at or above which a possibly-sick peer counts as in range, i.e. keeps the episode alive.
    static let inRangeP = 0.5
    /// Weighted minutes of the running episode.
    private(set) var minutes = 0.0
    /// `clock` at the end of the last weighted moment of the episode; nil when there is no episode (minutes 0).
    /// Missing in a state saved by the 24 h-window build: `migrated()` derives it from the buckets.
    private(set) var lastContact: Double?
    /// Rio's unit dose per peer ID (with its stage-weighted dose and highest evidence level s), over the 24 h window.
    /// Separate from `minutes`, which drives the 15-min close-contact alert.
    private(set) var sources: [String: RiskEstimate.Source] = [:]
    /// Σ unit dose over every ID in the window (shown to the user).
    private(set) var dose = 0.0
    /// The phone's risk estimate from `sources` (RiskEstimate.probability); the prior with no contacts.
    private(set) var probability = RiskEstimate.prior
    private(set) var level = AlertLevel.none
    /// flu-expo: a contagious peer is what keeps the heads-up up now (nil in a state saved before it existed).
    private var contagiousNearby: Bool?
    /// What the user is alerted to: `level`, with a heads-up upgraded to `.nearbyContagious` while someone who tested
    /// positive is in range. Drives notifications, the tissue alert and Today's strip; `level` keeps the episode rules.
    var alert: AlertLevel { level == .nearby && contagiousNearby == true ? .nearbyContagious : level }

    /// Simulated seconds since start, and per-simulated-minute totals (≤ 1440 buckets).
    private var clock = 0.0
    private var buckets: [Bucket] = []
    /// `minutes` is only read to migrate an old saved state (see `migrated()`); the running total is `minutes` above.
    private struct Bucket: Equatable, Codable { var minute: Int; var minutes: Double; var sources: [String: RiskEstimate.Source] }

    /// `contacts`: (P(within 6 ft), their risk) for each peer seen this tick.
    /// `simSeconds`: elapsed time after the demo speed-up.
    /// Within the window minutes only grow: a backwards clock step (negative time), NaN/inf, or a
    /// pClose outside [0, 1] is ignored or clamped rather than allowed to erase or poison the total.
    /// `doses`: each contact's peer ID and fused distance, same order as `contacts`; nil (or a missing
    /// entry) means no dose: no distance estimate, coarse GPS only, or dropped by ContactGuard.
    /// A peer adds dose only with an evidence level s > 0 (its status, or its score above the prior) and
    /// within RiskEstimate.doseRange; minutes count only peers whose status is possibly sick or positive.
    mutating func advance(simSeconds: Double, contacts: [(pClose: Double, risk: Risk)], doses: [DosePeer?]? = nil) {
        let dt = simSeconds.isFinite ? min(max(simSeconds, 0), Self.window) : 0
        clock += dt
        var perPeer: [String: Double] = [:]  // minutes this call per peer; copies of one ID (AccrualFeed) add up
        var added = 0.0  // largest per-peer total: only the strongest peer counts
        var inRange = false
        var addedDose: [String: RiskEstimate.Source] = [:]
        for (i, c) in contacts.enumerated() {
            if c.risk != .none, c.pClose.isFinite {
                let p = min(max(c.pClose, 0), 1)
                let key = doses.flatMap { i < $0.count ? $0[i]?.id : nil } ?? "#\(i)"
                perPeer[key, default: 0] += dt / 60 * p * c.risk.weight
                if p >= Self.inRangeP { inRange = true }
            }
            guard let ds = doses, i < ds.count, let x = ds[i] else { continue }
            let s = x.s ?? RiskEstimate.evidence(c.risk)
            guard s.isFinite, s > 0 else { continue }
            let stage = x.stage ?? RiskEstimate.stage
            let share = x.share.isFinite ? min(max(x.share, 0), 1) : 0
            let u = RiskEstimate.contactDose(distance: x.distance, seconds: dt * share, room: x.room)
            guard u > 0, stage.isFinite, stage >= 0 else { continue }
            addedDose[x.id, default: .init()].dose += u
            addedDose[x.id]!.weighted += stage * u
            addedDose[x.id]!.s = max(addedDose[x.id]!.s, min(s, 1))
        }
        added = perPeer.values.max() ?? 0
        if added > 0 || !addedDose.isEmpty {
            let m = Int(floor(clock / 60))
            if buckets.last?.minute == m {
                buckets[buckets.count - 1].minutes += added
                Self.merge(addedDose, into: &buckets[buckets.count - 1].sources)
            } else {
                buckets.append(Bucket(minute: m, minutes: added, sources: addedDose))
            }
            Self.merge(addedDose, into: &sources)
        }
        // The episode: the clock runs from the end of the last weighted moment. 2 h or more since it, with no
        // possibly-sick peer in range now, ends the episode (before this call's minutes are added). A call with
        // a peer in range moves that moment to now.
        if let last = lastContact, !inRange, clock - last >= Self.episodeGap {
            minutes = 0
            lastContact = nil
        }
        if added > 0 || inRange {
            minutes += added
            if inRange || lastContact == nil { lastContact = clock }
        }
        // Expire whole minutes of dose that fell out of the 24 h window. floor, not Int(): truncating toward zero
        // made a first-minute contact expire up to ~1.5 min early while the clock was just under 24 h.
        let oldest = Int(floor((clock - Self.window) / 60))
        var expired = false
        if let cut = buckets.firstIndex(where: { $0.minute > oldest }), cut > 0 {
            buckets.removeFirst(cut)
            expired = true
        } else if let last = buckets.last, last.minute <= oldest {
            buckets.removeAll()
            expired = true
        }
        if expired {  // rebuild the per-ID sums and the highest s from what is left
            sources = [:]
            for b in buckets { Self.merge(b.sources, into: &sources) }
        }
        if expired || !addedDose.isEmpty {
            dose = sources.values.reduce(0) { $0 + $1.dose }
            probability = RiskEstimate.probability(sources)
        }
        // Hysteresis: warn at P >= 0.5, clear only below 0.3, so noisy BLE doesn't flicker the banner.
        let threshold = level == .nearby ? 0.3 : 0.5
        let riskyNearby = contacts.contains { $0.risk != .none && $0.pClose >= threshold }
        contagiousNearby = contacts.contains { $0.risk == .contagious && $0.pClose >= threshold }
        if minutes >= Self.closeContactMinutes - 1e-6 {  // float sums of many small ticks land a hair under 15
            level = .closeContact
        } else {
            level = riskyNearby ? .nearby : .none
        }
    }

    /// Adds doses per ID and keeps the highest evidence level.
    private static func merge(_ add: [String: RiskEstimate.Source], into total: inout [String: RiskEstimate.Source]) {
        for (id, a) in add {
            total[id, default: .init()].dose += a.dose
            total[id]!.weighted += a.weighted
            total[id]!.s = max(total[id]!.s, a.s)
        }
    }

    mutating func reset() { self = ExposureTracker() }

    /// "X h Y min" for 60 minutes or more, else "N min".
    static func durationText(_ minutes: Double) -> String {
        let m = Int(max(minutes, 0))
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    /// Nothing in the window, no episode and no alert: the same as a fresh tracker apart from the clock.
    var isEmpty: Bool { buckets.isEmpty && minutes == 0 && level == .none }

    /// A tracker decoded from a state saved by the 24 h-window build has `minutes` (the last 24 h) but no
    /// `lastContact`. The episode is taken to have ended with the newest bucket that added minutes, so the 2 h
    /// rule applies from there; with no such bucket the minutes can't be placed and start at 0.
    func migrated() -> ExposureTracker {
        guard lastContact == nil, minutes > 0 else { return self }
        var e = self
        if let b = buckets.last(where: { $0.minutes > 0 }) {
            e.lastContact = min(Double(b.minute + 1) * 60, clock)
        } else {
            e.minutes = 0
        }
        if clock - (e.lastContact ?? clock) >= Self.episodeGap { e.minutes = 0; e.lastContact = nil }
        return e
    }

    /// A decoded tracker (RiskStateFile) is used only if it could have come from `advance`: finite, non-negative
    /// numbers, buckets in order inside the window, and totals that match the per-minute buckets and the sources.
    var isPlausible: Bool {
        func ok(_ x: Double) -> Bool { x.isFinite && x >= 0 }
        func okSource(_ s: RiskEstimate.Source) -> Bool { ok(s.dose) && ok(s.weighted) && ok(s.s) && s.s <= 1 }
        guard ok(clock), ok(dose), minutes.isFinite, minutes >= -1e-9, buckets.count <= 1441,
              lastContact.map({ ok($0) && $0 <= clock + 1e-6 }) ?? (minutes <= 1e-9),
              probability.isFinite, probability >= RiskEstimate.prior - 1e-12, probability <= 1,
              sources.values.allSatisfy(okSource) else { return false }
        let newest = Int(floor(clock / 60)), oldest = Int(floor((clock - Self.window) / 60))
        var prev = Int.min
        for b in buckets {
            guard b.minute > prev, b.minute > oldest, b.minute <= newest, ok(b.minutes),
                  b.sources.values.allSatisfy(okSource) else { return false }
            prev = b.minute
        }
        return abs(RiskEstimate.probability(sources) - probability) <= 1e-9
            && abs(sources.values.reduce(0) { $0 + $1.dose } - dose) <= 1e-9 * max(1, dose)
    }

    /// Same on screen: equal in everything a view can read. Unlike `==` it ignores the clock and the minute
    /// buckets, which move on every tick even with nobody around.
    func showsSame(as o: ExposureTracker) -> Bool {
        minutes == o.minutes && dose == o.dose && probability == o.probability && alert == o.alert && sources == o.sources
    }
}

enum Advice {
    static func title(_ level: AlertLevel) -> String {
        switch level {
        case .none: return ""
        case .nearby: return "Someone within 6 ft may be sick"
        case .nearbyContagious: return "Someone within 6 ft has tested positive"
        case .closeContact: return "You were close to someone who may be sick"
        }
    }

    static func body(_ level: AlertLevel) -> [String] {
        switch level {
        case .none:
            return []
        case .nearby:
            return ["Put 6 ft or more between you, or step outside.",
                    "Consider wearing a mask while you're here."]
        case .nearbyContagious:
            return ["Put 6 ft or more between you now, or step outside.",
                    "Wear a mask while you're here, and wash your hands."]
        case .closeContact:
            return ["You've spent about 15 minutes within 6 ft of someone who may be sick.",
                    "Leave the room now, or move well away and put on a mask.",
                    "Wash your hands; avoid touching your face.",
                    "Watch for fever, cough or sore throat over the next 1–4 days.",
                    "If symptoms start, get tested and report it in FlUni."]
        }
    }
}
