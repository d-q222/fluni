import Foundation

/// Background geofence entries wait for a fresh GPS fix before anything is posted: the monitored circle is
/// bigger than the building (iOS needs ~100 m), so the real radius is checked against the fix.
/// Pure: BuildingWatcher keeps the `pending` dictionary and feeds in fixes.
enum GeofenceEntry {
    /// How long an entry waits for a fix. No fix in time means no notification.
    static let fixTimeout: TimeInterval = 10
    /// The monitored region is never smaller than this (smaller ones are unreliable); the real radius decides.
    static let minRegionRadius = 100.0

    static func regionRadius(for buildingRadius: Double, maximum: Double) -> Double {
        min(max(buildingRadius, minRegionRadius), maximum)
    }

    /// Ids from `pending` (id -> when the entry happened) that are still waiting and whose building really
    /// contains the fix (the same test as `BuildingHeat.inside`). A fix without a valid accuracy, or older than the timeout, confirms nothing.
    static func confirmed(pending: [String: Date], fixLat: Double, fixLon: Double, accuracy: Double, fixTime: Date,
                          now: Date, heat: BuildingHeat) -> [String] {
        guard accuracy >= 0, abs(now.timeIntervalSince(fixTime)) <= fixTimeout else { return [] }
        return pending.filter { id, at in
            guard now.timeIntervalSince(at) <= fixTimeout, let b = heat.buildings[id],
                  let lat = b.lat, let lon = b.lon else { return false }
            return BuildingHeat.haversine(fixLat, fixLon, lat, lon) <= b.radius
        }.map(\.key).sorted()
    }

    /// Drops entries that have waited longer than the timeout.
    static func pruned(_ pending: [String: Date], now: Date) -> [String: Date] {
        pending.filter { now.timeIntervalSince($0.value) <= fixTimeout }
    }
}
