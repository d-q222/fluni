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

enum AlertLevel: Int, Comparable {
    case none = 0, nearby = 1, closeContact = 2
    static func < (a: AlertLevel, b: AlertLevel) -> Bool { a.rawValue < b.rawValue }
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

/// Accumulates close-contact minutes with risky phones (summed across them, so ID rotation
/// does not reset it) over a rolling 24 h — the rule agreed with the heat map (WORKSTREAMS) —
/// and decides the alert level. Alongside, it keeps Rio's dose per peer ID over the same window for
/// the risk estimate (RiskEstimate).
struct ExposureTracker: Equatable {
    static let closeContactMinutes = 15.0
    static let window = 24 * 3600.0  // simulated seconds, so the demo speed-up applies
    private(set) var minutes = 0.0
    /// Rio's unit dose per peer ID (with its stage-weighted dose and highest evidence level s), over the 24 h window.
    /// Separate from `minutes`, which drives the 15-min close-contact alert.
    private(set) var sources: [String: RiskEstimate.Source] = [:]
    /// Σ unit dose over every ID in the window (shown to the user).
    private(set) var dose = 0.0
    /// The phone's risk estimate from `sources` (RiskEstimate.probability); the prior with no contacts.
    private(set) var probability = RiskEstimate.prior
    private(set) var level = AlertLevel.none

    /// Simulated seconds since start, and per-simulated-minute totals (≤ 1440 buckets).
    private var clock = 0.0
    private var buckets: [Bucket] = []
    private struct Bucket: Equatable { var minute: Int; var minutes: Double; var sources: [String: RiskEstimate.Source] }

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
        var added = 0.0
        var addedDose: [String: RiskEstimate.Source] = [:]
        for (i, c) in contacts.enumerated() {
            if c.risk != .none, c.pClose.isFinite {
                let p = min(max(c.pClose, 0), 1)
                added += dt / 60 * p * c.risk.weight
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
        if added > 0 || !addedDose.isEmpty {
            let m = Int(floor(clock / 60))
            if buckets.last?.minute == m {
                buckets[buckets.count - 1].minutes += added
                Self.merge(addedDose, into: &buckets[buckets.count - 1].sources)
            } else {
                buckets.append(Bucket(minute: m, minutes: added, sources: addedDose))
            }
            minutes += added
            Self.merge(addedDose, into: &sources)
        }
        // Expire whole minutes that fell out of the 24 h window. floor, not Int(): truncating toward zero
        // made a first-minute contact expire up to ~1.5 min early while the clock was just under 24 h.
        let oldest = Int(floor((clock - Self.window) / 60))
        var expired = false
        if let cut = buckets.firstIndex(where: { $0.minute > oldest }), cut > 0 {
            minutes -= buckets[..<cut].reduce(0) { $0 + $1.minutes }
            buckets.removeFirst(cut)
            expired = true
        } else if let last = buckets.last, last.minute <= oldest {
            buckets.removeAll()
            expired = true
        }
        if buckets.isEmpty { minutes = 0 }  // no float residue once everything expired
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

    /// Same on screen: equal in everything a view can read. Unlike `==` it ignores the clock and the minute
    /// buckets, which move on every tick even with nobody around.
    func showsSame(as o: ExposureTracker) -> Bool {
        minutes == o.minutes && dose == o.dose && probability == o.probability && level == o.level && sources == o.sources
    }
}

enum Advice {
    static func title(_ level: AlertLevel) -> String {
        switch level {
        case .none: return ""
        case .nearby: return "Someone within 6 ft may be sick"
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
        case .closeContact:
            return ["You've spent about 15 minutes within 6 ft of someone who may be sick.",
                    "Leave the room now, or move well away and put on a mask.",
                    "Wash your hands; avoid touching your face.",
                    "Watch for fever, cough or sore throat over the next 1–4 days.",
                    "If symptoms start, get tested and report it in FlUni."]
        }
    }
}
