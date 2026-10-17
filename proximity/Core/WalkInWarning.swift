import Foundation

/// When to warn that the user is inside a high-illness building. Pure: callers feed in where the user is
/// (a building or nil), that building's current reading (nil = no data) and whether detection is paused.
///
/// - Banner: shown while inside a building whose current reading is high, and not paused.
/// - Notification: at most one per building per `cooldown`, counted from the last one posted. Leaving and
///   coming back inside the cooldown does not post again; a building that turns high while you are in it does.
/// - No data, not high or paused: no banner, no notification, and the cooldown is left alone.
struct WalkInWarning {
    static let cooldown: TimeInterval = 2 * 3600

    struct Outcome: Equatable {
        /// The building to show the banner for, if any.
        var bannerBuilding: BuildingHeat.Building?
        /// Post a notification now.
        var notify: Bool
    }

    /// Building id to the time its last notification was posted.
    private(set) var lastNotified: [String: Date]

    init(lastNotified: [String: Date] = [:]) { self.lastNotified = lastNotified }

    mutating func evaluate(now: Date, building: BuildingHeat.Building?, reading: BuildingHeat.Reading?, paused: Bool) -> Outcome {
        guard !paused, let b = building, let r = reading, r.high else { return Outcome(bannerBuilding: nil, notify: false) }
        if let last = lastNotified[b.id], now.timeIntervalSince(last) < Self.cooldown {
            return Outcome(bannerBuilding: b, notify: false)
        }
        lastNotified[b.id] = now
        return Outcome(bannerBuilding: b, notify: true)
    }

    static func message(for name: String) -> String { "\(name) has a lot of illness right now. Consider a mask, or a different spot." }
}
