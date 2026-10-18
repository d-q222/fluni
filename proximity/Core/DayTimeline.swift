import Foundation

// Today's "your day" timeline, built from what the phone already keeps: place visits (PlaceLog) and exposure
// episodes (ExposureHistory). Pure, so the rules are testable.

/// A point on the side line where someone who may be sick was close.
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

    /// How a stretch of the side line is coloured: what happened during that visit. Ordered, so the worst wins.
    enum Tone: Int, Comparable {
        case quiet = 0, phones, headsUp, closeContact
        static func < (a: Tone, b: Tone) -> Bool { a.rawValue < b.rawValue }
    }

    enum Entry: Equatable, Identifiable {
        case place(PlaceVisit, Tone)
        case moment(TimelineMoment)
        var date: Date {
            switch self {
            case .place(let v, _): return v.start
            case .moment(let m): return m.episode.start
            }
        }
        var id: String {
            switch self {
            case .place(let v, _): return "p\(v.start.timeIntervalSince1970)"
            case .moment(let m): return "m\(m.episode.start.timeIntervalSince1970)"
            }
        }
    }

    /// Episodes (finished plus the ongoing one) that ended in the last 24 hours, oldest first, each labelled:
    /// a close contact when it alone reached 15 weighted minutes, or when the running total over the window
    /// crossed 15 during it (the same mark the live alert uses); otherwise a heads-up.
    static func moments(_ episodes: [ExposureEpisode], visits: [PlaceVisit], now: Date) -> [TimelineMoment] {
        let goal = ExposureTracker.closeContactMinutes - 1e-6
        var seen = Set<Date>()
        let recent = episodes
            .filter { now.timeIntervalSince($0.end) <= window && $0.start <= now }
            .sorted { $0.start < $1.start }
            .filter { seen.insert($0.start).inserted }
        var total = 0.0
        return recent.map { e in
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

    /// The worst thing that happened during a visit: a close contact, a heads-up, phones nearby, or nothing.
    static func tone(_ v: PlaceVisit, moments: [TimelineMoment]) -> Tone {
        var tone: Tone = v.maxPhones > 0 ? .phones : .quiet
        for m in moments where m.episode.start <= v.end.addingTimeInterval(placeSlack)
            && m.episode.end >= v.start.addingTimeInterval(-placeSlack) {
            tone = max(tone, m.kind == .closeContact ? .closeContact : .headsUp)
        }
        return tone
    }

    /// The rows under "Now", newest first: earlier visits and every moment in the last 24 hours. The visit
    /// going on now is left out (it is the "Now" row).
    static func entries(visits: [PlaceVisit], current: PlaceVisit?, moments: [TimelineMoment], now: Date) -> [Entry] {
        let places = visits
            .filter { $0 != current && now.timeIntervalSince($0.end) <= window }
            .map { Entry.place($0, tone($0, moments: moments)) }
        let points = moments.map(Entry.moment)
        return (places + points).sorted { $0.date > $1.date }
    }
}

extension RiskEstimate {
    /// The close-contact moment's line about risk, in context: from the everyday baseline to the live estimate,
    /// then what that band means. "Your risk estimate went from 2.0% to 8.0%. That is still low." Same live text as the headline number.
    static func changeLine(to p: Double) -> String {
        let from = liveText(prior), to = liveText(p)
        let start = from == to ? "Your risk estimate is \(to), the everyday baseline." : "Your risk estimate went from \(from) to \(to)."
        switch band(p) {
        case .low: return start + " That is still low."
        case .elevated: return start + " That is elevated, so wear a mask in crowded rooms and watch for symptoms."
        case .high: return start + " That is high. Consider getting tested at Vaden and staying home."
        }
    }
}
