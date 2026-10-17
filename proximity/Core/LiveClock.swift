import Foundation

/// The shared "now" rule (docs/building-heat-format.md, "Which moment is 'now'"): the device's local weekday and
/// time of day, mapped onto a run day. Pure, no UI, no stored state, so a clock change (time zone, DST, the system
/// clock jumping either way) just means calling it again with the new `Date`.
///
/// Sim times are seconds as in `PSickFeed.simSeconds(iso:)`: naive local time read as UTC. The calendar's time zone
/// is the device's, which is how "local" gets in.
enum LiveClock {
    private static let day = 86_400.0

    /// `run` is the first and last step of the data. Run day 0 starts at the local midnight of the first step.
    /// 1. Same weekday: the first run day with the device's weekday, at the device's time of day.
    /// 2. No such weekday (a run shorter than 7 days): run day `daysSinceMonday mod runDays`.
    /// 3. Clamp to `run`.
    /// DST: the wall clock is what is read, so on a spring-forward day the skipped hour is skipped here too, and on a
    /// fall-back day the repeated hour is read twice (the result steps back an hour once).
    static func simTime(now: Date, calendar: Calendar, run: ClosedRange<Double>) -> Double {
        let c = calendar.dateComponents([.weekday, .hour, .minute, .second, .nanosecond], from: now)
        let sinceMonday = ((c.weekday ?? 2) + 5) % 7  // Calendar: 1 = Sunday ... 7 = Saturday
        let seconds = Double((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0))
        let timeOfDay = min(seconds + Double(c.nanosecond ?? 0) / 1e9, day - 0.001)

        let startDay = (run.lowerBound / day).rounded(.down)  // days since 1970-01-01
        let runDays = max(1, Int((run.upperBound / day).rounded(.down) - startDay) + 1)
        // 1970-01-01 was a Thursday (3 days after Monday).
        let startSinceMonday = ((Int(startDay) + 3) % 7 + 7) % 7
        var k = (sinceMonday - startSinceMonday + 7) % 7
        if k >= runDays { k = sinceMonday % runDays }
        return min(max((startDay + Double(k)) * day + timeOfDay, run.lowerBound), run.upperBound)
    }

    /// "4:30 PM" or "16:30" by the user's locale. `t` is a sim time (naive local), so it is formatted as is.
    static func timeText(_ t: Double, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = locale
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}
