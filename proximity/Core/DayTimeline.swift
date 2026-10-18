import Foundation

// Today's "Your day so far" timeline, built from what the phone already keeps: place visits (PlaceLog) and exposure
// episodes (ExposureHistory). Pure, so the rules are testable.

/// A point on the timeline where someone who may be sick was close.
struct TimelineMoment: Equatable, Identifiable {
    enum Kind: Equatable { case headsUp, closeContact }
    let episode: ExposureEpisode
    let kind: Kind
    /// The building you were in when it started, if a visit covers it.
    let placeName: String?
    var id: Date { episode.start }
}

enum DayTimeline {
    static let window: TimeInterval = 24 * 3600
    /// A moment this close to a visit's edges still counts as in that building (GPS fixes are a few seconds apart).
    static let placeSlack: TimeInterval = 60

    /// One row: a place with the moments that happened there, or a moment away from any known building.
    struct Row: Equatable, Identifiable {
        /// Nil for a moment that no visit covers.
        var visit: PlaceVisit?
        /// The visit going on now (shown as "Now").
        var isNow = false
        /// Oldest first.
        var moments: [TimelineMoment] = []
        var date: Date { visit?.start ?? moments.first?.episode.start ?? .distantPast }
        var id: Date { date }
    }

    /// Episodes (finished plus the ongoing one) that ended in the last 24 hours, oldest first, each labelled:
    /// a close contact when it alone reached 15 weighted minutes, or when the running total crossed 15 during it;
    /// otherwise a heads-up. Like the live count (ExposureTracker), the total starts again from 0 after
    /// `episodeGap` (2 h) with nobody sick close by.
    static func moments(_ episodes: [ExposureEpisode], visits: [PlaceVisit], now: Date) -> [TimelineMoment] {
        let goal = ExposureTracker.closeContactMinutes - 1e-6
        var seen = Set<Date>()
        let recent = episodes
            .filter { now.timeIntervalSince($0.end) <= window && $0.start <= now }
            .sorted { $0.start < $1.start }
            .filter { seen.insert($0.start).inserted }
        var total = 0.0
        var lastEnd: Date?
        return recent.map { e in
            if let l = lastEnd, e.start.timeIntervalSince(l) >= ExposureTracker.episodeGap { total = 0 }
            lastEnd = max(lastEnd ?? e.end, e.end)
            let before = total
            total += e.weightedMinutes
            let crossed = before < goal && total >= goal
            let kind: TimelineMoment.Kind = (e.isCloseContact || crossed) ? .closeContact : .headsUp
            return TimelineMoment(episode: e, kind: kind, placeName: place(at: e.start, in: visits)?.name)
        }
    }

    /// The visit covering `t` (with a minute of slack at each edge); the latest one if several do.
    static func place(at t: Date, in visits: [PlaceVisit]) -> PlaceVisit? {
        visits.last { $0.start.addingTimeInterval(-placeSlack) <= t && t <= $0.end.addingTimeInterval(placeSlack) }
    }

    /// The rows, newest first: every visit of the last 24 hours (a pass-through under 5 minutes only when something
    /// happened there or it is going on now), each with the moments that started during it, and a row of its own
    /// for a moment no visit covers.
    static func rows(visits: [PlaceVisit], current: PlaceVisit?, moments: [TimelineMoment], now: Date) -> [Row] {
        let recent = visits.filter { now.timeIntervalSince($0.end) <= window }
        var rows = recent.map { Row(visit: $0, isNow: $0 == current) }
        for m in moments {
            if let v = place(at: m.episode.start, in: recent), let i = rows.lastIndex(where: { $0.visit == v }) {
                rows[i].moments.append(m)
            } else {
                rows.append(Row(moments: [m]))
            }
        }
        return rows
            .filter { $0.isNow || !$0.moments.isEmpty || !($0.visit?.isPassingThrough ?? false) }
            .sorted { $0.date > $1.date }
    }
}
