import SwiftUI

/// "Your day so far" on Today: the buildings you spent time in over the last 24 hours, newest first, each with how
/// long, how many FlUni phones were near and whether any said they were sick; contact moments sit inline in red,
/// and a close contact opens in place with what to do. Built from the on-phone place log (PlaceLogStore) and the
/// Recent contacts store (ExposureHistoryStore) by Core/DayTimeline.swift. Nothing here leaves the phone.
struct DayTimelineSection: View {
    @ObservedObject var model: ProximityModel
    @ObservedObject var history: ExposureHistoryStore
    @ObservedObject private var places = PlaceLogStore.shared
    /// Close contacts the user closed (by start time); a close contact is open until then.
    @State private var closed: Set<Date> = []

    var body: some View {
        let now = Date()
        let episodes = history.episodes + (history.ongoing.map { [$0] } ?? [])
        let visits = places.log.visits
        let moments = DayTimeline.moments(episodes, visits: visits, now: now)
        let rows = DayTimeline.rows(visits: visits, current: places.log.current, moments: moments, now: now)
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Your day so far", note: now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
            if rows.isEmpty {
                Text("The campus buildings you spend time in today show up here, with how many FlUni phones were near you. Kept on this phone for 24 hours.")
                    .font(.fluni(.subheadline)).foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("day.empty")
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                TimelineRow(time: row.isNow ? "Now" : Self.clock(row.date), spokenTime: row.isNow ? "Now" : Self.spoken(row.date),
                            pin: row.isNow ? .now : .plain, alert: !row.moments.isEmpty, isLast: i == rows.count - 1) {
                    if let v = row.visit {
                        Text(v.name).font(.fredoka(18, relativeTo: .body, weight: .medium)).foregroundStyle(Theme.ink)
                        Text(detail(v, row: row)).font(.fluni(.subheadline)).foregroundStyle(Theme.ink2).padding(.top, 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(row.moments) { m in moment(m, first: row.visit == nil && m == row.moments.first) }
                }
            }
            if !episodes.isEmpty {
                NavigationLink { ExposureHistoryView(store: history) } label: {
                    HStack(spacing: 6) {
                        Text("Recent contacts, last 14 days")
                        Image(systemName: "chevron.right").font(.footnote.weight(.bold)).accessibilityHidden(true)
                    }
                    .font(.fluni(.subheadline, weight: .semibold)).underline()
                    .foregroundStyle(Theme.ink).frame(minHeight: 44)
                }
                .padding(.horizontal, 4)
                .accessibilityHint("Shows every close contact from the last 14 days")
                .accessibilityIdentifier("history.link")
            }
        }
    }

    /// "Since 6:41 pm, near 3 other FlUni phones. None of them sick." / "45 min, near up to 11 phones. All healthy."
    private func detail(_ v: PlaceVisit, row: DayTimeline.Row) -> String {
        let quiet = row.moments.isEmpty
        if row.isNow {
            let n = model.peers.count
            let sick = max(model.peers.filter { $0.risk != .none }.count, v.maxSick)
            let since = "Since \(Self.clockAmPm(v.start))"
            if n == 0 { return since + ". No other FlUni phones nearby." }
            var s = since + ", near \(n) other FlUni \(n == 1 ? "phone" : "phones")."
            if quiet { s += sick == 0 ? (n == 1 ? " Healthy." : " None of them sick.") : " \(sick) said they may be sick." }
            return s
        }
        let length = Self.duration(v.minutes)
        if v.maxPhones == 0 { return length + ". No other FlUni phones nearby." }
        var s = length + ", near up to \(v.maxPhones) \(v.maxPhones == 1 ? "phone" : "phones")."
        if quiet { s += v.maxSick == 0 ? (v.maxPhones == 1 ? " Healthy." : " All healthy.") : " \(v.maxSick) said they may be sick." }
        return s
    }

    private func moment(_ m: TimelineMoment, first: Bool) -> some View {
        let e = m.episode
        let ongoing = history.ongoing?.start == e.start
        let who = e.maxRisk == .contagious ? "said they tested positive." : "said they may be sick."
        var text = "\(Self.clockAmPm(e.start)). Someone within 6 ft \(who)"
        if m.kind == .headsUp {
            // Shown capped at the 15-minute mark ("15 of 15", never "49 of 15"); the model keeps the real minutes.
            let goal = ExposureTracker.closeContactMinutes
            text += ongoing ? " \(Int(min(model.exposure.minutes, goal))) of \(Int(goal)) min so far."
                : " About \(max(1, Int(e.durationMinutes.rounded()))) min."
        }
        let isOpen = m.kind == .closeContact && !closed.contains(m.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                AlertIcon().padding(.top, 2)
                Text(text).font(.nunito(15, relativeTo: .subheadline, weight: .semibold)).foregroundStyle(Theme.fireInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, first ? 0 : 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("day.moment")
            if m.kind == .closeContact {
                if isOpen {
                    CloseContactCard(start: e.start, end: ongoing ? nil : e.end) { closed.insert(m.id) }
                        .padding(.top, 10)
                } else {
                    Button("Close contact: what to do") { closed.remove(m.id) }
                        .font(.fluni(.subheadline, weight: .semibold)).underline()
                        .foregroundStyle(Theme.ink).frame(minHeight: 44)
                        .padding(.leading, 24)
                        .accessibilityIdentifier("closecontact.open")
                }
            }
        }
    }

    // MARK: Formatting

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }
    private static let hm = formatter("h:mm")
    private static let hma = formatter("h:mm a")

    /// "5:44" (the time column, as in the mockup).
    static func clock(_ d: Date) -> String { hm.string(from: d) }
    /// "8:13 pm".
    static func clockAmPm(_ d: Date) -> String { hma.string(from: d) }
    static func spoken(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    /// "45 min", "1 h 20 min", "2 h".
    static func duration(_ minutes: Double) -> String {
        let m = max(1, Int(minutes.rounded()))
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }
}

/// A close contact, opened in place: when, then the four steps, then Close.
struct CloseContactCard: View {
    let start: Date
    /// Nil while it is still going on.
    let end: Date?
    let onClose: () -> Void

    var body: some View {
        let when = end.map { "\(DayTimelineSection.clock(start)) to \(DayTimelineSection.clockAmPm($0))" }
            ?? "Since \(DayTimelineSection.clockAmPm(start))"
        VStack(alignment: .leading, spacing: 0) {
            Text("Close contact").font(.fredoka(18, relativeTo: .headline)).foregroundStyle(Theme.fireInk)
                .accessibilityAddTraits(.isHeader)
            Text("\(when), within 6 ft of someone who may be sick.")
                .font(.fluni(.footnote)).foregroundStyle(Theme.ink2).padding(.top, 2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(Advice.body(.closeContact).dropFirst().enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(i + 1)").font(.fredoka(13, relativeTo: .footnote))
                            .frame(width: 22, height: 22)
                            .background(Theme.sun, in: Circle())
                            .overlay(Circle().strokeBorder(Theme.ink, lineWidth: 1.5))
                            .accessibilityHidden(true)
                        Text(step).font(.fluni(.subheadline)).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Theme.ink)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 10)
            Button("Close", action: onClose)
                .font(.fluni(.subheadline, weight: .semibold)).underline()
                .foregroundStyle(Theme.ink).frame(minHeight: 44)
                .padding(.top, 4)
                .accessibilityHint("Folds the steps away")
                .accessibilityIdentifier("closecontact.close")
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("closecontact.card")
    }
}

/// "Your day so far" / "Your recovery": a Fredoka heading and a quiet note on the right (wraps under at large sizes).
struct SectionHeader: View {
    let title: String
    let note: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) { heading; Spacer(minLength: 10); caption }
            VStack(alignment: .leading, spacing: 2) { heading; caption }
        }
        .padding(.horizontal, 4)
        .padding(.top, 18).padding(.bottom, 8)
    }

    private var heading: some View {
        Text(title).font(.fluni(.title2, weight: .semibold)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
    }
    private var caption: some View { Text(note).font(.fluni(.footnote)).foregroundStyle(Theme.ink2) }
}

/// One entry on a timeline: the time on the left, a pin on a rail, the content on the right. The rail runs down
/// to the next pin (fading out after the last); it turns ember where someone who may be sick was close.
struct TimelineRow<Content: View>: View {
    enum Pin { case plain, now }
    let time: String
    var spokenTime: String? = nil
    var pin = Pin.plain
    var alert = false
    var isLast = false
    @ViewBuilder let content: Content
    @ScaledMetric(relativeTo: .footnote) private var timeWidth: CGFloat = 50
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 2) {
            if stacked { timeText.padding(.leading, 28) }
            HStack(alignment: .top, spacing: 12) {
                if !stacked { timeText.frame(width: timeWidth, alignment: .trailing).padding(.top, 2) }
                rail
                VStack(alignment: .leading, spacing: 0) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 18)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    private var timeText: some View {
        Text(time).font(.nunito(14, relativeTo: .footnote, weight: .semibold)).monospacedDigit()
            .foregroundStyle(Theme.ink2)
            .accessibilityLabel(spokenTime ?? time)
    }

    private var rail: some View {
        let colour = alert ? Theme.ember : Theme.sage
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(isLast ? AnyShapeStyle(LinearGradient(colors: [colour, colour.opacity(0)], startPoint: .top, endPoint: .bottom))
                             : AnyShapeStyle(colour))
                .frame(width: 2)
                .padding(.top, 18).padding(.bottom, -4)
            ZStack {
                Circle().fill(pin == .plain && alert ? Theme.ember : Theme.paper)
                Circle().strokeBorder(Theme.ink, lineWidth: 2)
                if pin == .now { Circle().fill(alert ? Theme.ember : Theme.ink).padding(5) }
            }
            .frame(width: 16, height: 16)
            .padding(.top, 4)
        }
        .frame(width: 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(true)
    }
}
