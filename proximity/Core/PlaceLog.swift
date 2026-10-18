import Foundation

// The places on Today's timeline: which campus building you were in, when, and how many FlUni phones were
// around. Pure (no CoreLocation, no storage). It only ever holds a building id and its name, never a
// coordinate. FlUni keeps it in a small file on the phone for 24 hours; it is never sent anywhere.

/// One stay in one building.
struct PlaceVisit: Codable, Equatable, Identifiable {
    var buildingID: String
    var name: String
    var start: Date
    /// The last moment this phone was seen inside.
    var end: Date
    /// The most other FlUni phones nearby at once during the stay (a count; never who).
    var maxPhones: Int

    var id: Date { start }
    var minutes: Double { max(0, end.timeIntervalSince(start)) / 60 }
    /// Under 5 minutes reads as walking through rather than a stay.
    var isPassingThrough: Bool { minutes < PlaceLog.passThroughMinutes }
}

/// Builds visits from "I'm in building X now" observations (from GPS fixes in the app and from background
/// building entries).
///
/// - The same building seen again within `gap` extends the visit (this also rejoins it after a short GPS
///   flicker outside). Longer than that, e.g. the app was closed, and a new visit starts.
/// - A different building starts a new visit; "not in a building" ends the current one.
/// - Observations older than the newest visit's end (a clock step backwards) are ignored.
/// - Visits that ended more than 24 hours ago are dropped by `prune`.
struct PlaceLog: Codable, Equatable {
    static let retention: TimeInterval = 24 * 3600
    static let gap: TimeInterval = 10 * 60
    static let passThroughMinutes = 5.0

    /// Oldest first.
    private(set) var visits: [PlaceVisit] = []
    /// True while the newest visit is still going on.
    private(set) var isInside = false

    /// The visit going on now, if any.
    var current: PlaceVisit? { isInside ? visits.last : nil }

    /// `buildingID` nil means "not inside any known building". `phones` is the count of other FlUni phones nearby now.
    mutating func observe(buildingID: String?, name: String?, phones: Int, at now: Date) {
        if let last = visits.last, now < last.end { return }
        guard let id = buildingID else { isInside = false; return }
        let phones = max(0, phones)
        if var last = visits.last, last.buildingID == id, now.timeIntervalSince(last.end) <= Self.gap {
            last.end = now
            last.maxPhones = max(last.maxPhones, phones)
            visits[visits.count - 1] = last
            isInside = true
            return
        }
        visits.append(PlaceVisit(buildingID: id, name: name ?? id, start: now, end: now, maxPhones: phones))
        isInside = true
    }

    /// Nothing heard from inside for longer than the gap: the visit is over (the app was closed or asleep).
    mutating func expire(now: Date) {
        if isInside, let last = visits.last, now.timeIntervalSince(last.end) > Self.gap { isInside = false }
    }

    /// Drops visits that ended more than 24 hours ago (exactly 24 hours is kept).
    mutating func prune(now: Date) {
        visits.removeAll { now.timeIntervalSince($0.end) > Self.retention }
        if visits.isEmpty { isInside = false }
    }

    static func encode(_ log: PlaceLog) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return try e.encode(log)
    }

    /// Unreadable data gives an empty log rather than a crash.
    static func decode(_ data: Data) -> PlaceLog {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return (try? d.decode(PlaceLog.self, from: data)) ?? PlaceLog()
    }
}
