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
/// does not reset it) and decides the alert level.
struct ExposureTracker: Equatable {
    static let closeContactMinutes = 15.0
    private(set) var minutes = 0.0
    private(set) var level = AlertLevel.none

    /// `contacts`: (P(within 6 ft), their risk) for each peer seen this tick.
    /// `simSeconds`: elapsed time after the demo speed-up.
    /// Minutes only ever grow: a backwards clock step (negative time), NaN/inf, or a pClose outside
    /// [0, 1] is ignored or clamped rather than allowed to erase or poison the total.
    mutating func advance(simSeconds: Double, contacts: [(pClose: Double, risk: Risk)]) {
        let dt = simSeconds.isFinite ? max(simSeconds, 0) : 0
        for c in contacts where c.pClose.isFinite && c.risk != .none {
            minutes += dt / 60 * min(max(c.pClose, 0), 1) * c.risk.weight
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

    mutating func reset() { self = ExposureTracker() }
}

enum Advice {
    static func title(_ level: AlertLevel) -> String {
        switch level {
        case .none: return ""
        case .nearby: return "Someone within 6 ft may be contagious"
        case .closeContact: return "Close contact with an infected person"
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
            return ["You've been within 6 ft of someone contagious for about 15 minutes.",
                    "Leave the room now, or move well away and put on a mask.",
                    "Wash your hands; avoid touching your face.",
                    "Watch for fever, cough or sore throat over the next 1–4 days.",
                    "If symptoms start, test and mark yourself as possibly sick in the app."]
        }
    }
}
