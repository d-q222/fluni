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

/// Accumulates close-contact minutes with risky phones (summed across them, so ID rotation
/// does not reset it) over a rolling 24 h — the rule agreed with the heat map (WORKSTREAMS) —
/// and decides the alert level.
struct ExposureTracker: Equatable {
    static let closeContactMinutes = 15.0
    static let window = 24 * 3600.0  // simulated seconds, so the demo speed-up applies
    private(set) var minutes = 0.0
    /// Infection "dose" for the risk estimate: Σ sickness × distance tier × minutes (model/infer.js),
    /// over the same 24 h window. Separate from `minutes`, which drives the 15-min close-contact alert.
    private(set) var dose = 0.0
    private(set) var level = AlertLevel.none

    /// Simulated seconds since start, and per-simulated-minute totals (≤ 1440 buckets).
    private var clock = 0.0
    private var buckets: [Bucket] = []
    private struct Bucket: Equatable { var minute: Int; var minutes: Double; var dose: Double }

    /// `contacts`: (P(within 6 ft), their risk) for each peer seen this tick.
    /// `simSeconds`: elapsed time after the demo speed-up.
    /// Within the window minutes only grow: a backwards clock step (negative time), NaN/inf, or a
    /// pClose outside [0, 1] is ignored or clamped rather than allowed to erase or poison the total.
    /// `tiers`: each contact's distance-tier weight (Fusion.tierWeight), same order as `contacts`;
    /// without it the tier falls back to pClose.
    mutating func advance(simSeconds: Double, contacts: [(pClose: Double, risk: Risk)], tiers: [Double]? = nil) {
        let dt = simSeconds.isFinite ? min(max(simSeconds, 0), Self.window) : 0
        clock += dt
        var added = 0.0, addedDose = 0.0
        for (i, c) in contacts.enumerated() where c.pClose.isFinite && c.risk != .none {
            let p = min(max(c.pClose, 0), 1)
            added += dt / 60 * p * c.risk.weight
            let t = tiers.flatMap { i < $0.count && $0[i].isFinite ? min(max($0[i], 0), 1) : nil } ?? p
            addedDose += dt / 60 * t * c.risk.weight
        }
        if added > 0 || addedDose > 0 {
            let m = Int(clock / 60)
            if buckets.last?.minute == m {
                buckets[buckets.count - 1].minutes += added
                buckets[buckets.count - 1].dose += addedDose
            } else {
                buckets.append(Bucket(minute: m, minutes: added, dose: addedDose))
            }
            minutes += added
            dose += addedDose
        }
        // Expire whole minutes that fell out of the 24 h window.
        let oldest = Int((clock - Self.window) / 60)
        if let cut = buckets.firstIndex(where: { $0.minute > oldest }), cut > 0 {
            minutes -= buckets[..<cut].reduce(0) { $0 + $1.minutes }
            dose -= buckets[..<cut].reduce(0) { $0 + $1.dose }
            buckets.removeFirst(cut)
        } else if let last = buckets.last, last.minute <= oldest {
            buckets.removeAll()
        }
        if buckets.isEmpty { minutes = 0; dose = 0 }  // no float residue once everything expired
        // Hysteresis: warn at P >= 0.5, clear only below 0.3, so noisy BLE doesn't flicker the banner.
        let threshold = level == .nearby ? 0.3 : 0.5
        let riskyNearby = contacts.contains { $0.risk != .none && $0.pClose >= threshold }
        if minutes >= Self.closeContactMinutes - 1e-6 {  // float sums of many small ticks land a hair under 15
            level = .closeContact
        } else {
            level = riskyNearby ? .nearby : .none
        }
    }

    mutating func reset() { self = ExposureTracker() }
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
