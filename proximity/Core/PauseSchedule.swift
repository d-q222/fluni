import Foundation

/// How long the student asked detection to stay off.
enum PauseChoice: Equatable {
    case oneHour
    case untilTomorrow   // the next local midnight
    case untilResumed    // until the student turns it back on
}

/// A pause in effect. `until == nil` means "until I turn it back on". Persisted, so a pause survives a relaunch.
struct PauseState: Codable, Equatable {
    var since: Date
    var until: Date?
}

/// Pure timing rules for pausing, with the clock and calendar passed in so tests can attack them.
enum PauseSchedule {
    /// The longest legitimate pause is "until tomorrow" on a 25 h DST day; allow some slack.
    static let maxSpan: TimeInterval = 26 * 3600
    /// Small backwards steps (network time sync) are normal and must not end a pause.
    static let clockSkewTolerance: TimeInterval = 120

    /// When a pause started at `now` ends (nil = never on its own).
    static func until(_ choice: PauseChoice, from now: Date, calendar: Calendar) -> Date? {
        switch choice {
        case .oneHour:
            return now.addingTimeInterval(3600)
        case .untilTomorrow:
            // Calendar math, not +86400 s, so a 23 h or 25 h day still ends at midnight.
            let today = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(24 * 3600)
        case .untilResumed:
            return nil
        }
    }

    static func state(_ choice: PauseChoice, from now: Date, calendar: Calendar) -> PauseState {
        PauseState(since: now, until: until(choice, from: now, calendar: calendar))
    }

    /// True when detection should come back on by itself. An open-ended pause never ends on its own.
    /// If the clock was set back (now is before the pause began, or the end is further away than any
    /// pause can be) the end time can't be trusted, so detection resumes rather than staying off for
    /// a long time without the student knowing.
    static func shouldResume(_ p: PauseState, now: Date) -> Bool {
        guard let until = p.until else { return false }
        if now >= until { return true }
        if now < p.since.addingTimeInterval(-clockSkewTolerance) { return true }
        if until.timeIntervalSince(now) > maxSpan { return true }
        return false
    }

    /// Short text for the UI, e.g. "until 3:40 PM" or "until you turn it back on".
    static func describe(_ p: PauseState, calendar: Calendar, now: Date) -> String {
        guard let until = p.until else { return "until you turn it back on" }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = calendar.locale ?? .current
        f.dateStyle = calendar.isDate(until, inSameDayAs: now) ? .none : .short
        f.timeStyle = .short
        return "until " + f.string(from: until)
    }
}
