import SwiftUI

/// The stay-home card (mockup v4), on Today and Me while the user is possibly sick or contagious: which day of the
/// 5 it is, and the one-tap daily check-in. It only ever asks; it never changes the status by itself. The fever-free
/// rule still decides when staying home ends (SelfReporter.phase); it just isn't printed here (owner, v4).
struct AtHomeCard: View {
    @ObservedObject var model: ProximityModel
    @ObservedObject var store: SelfReportStore
    @State private var blocked: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let now = Date()
        let r = store.record
        let phase = store.reporter.phase(r, now: now)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Circle().fill(Theme.sun).overlay(Circle().strokeBorder(Theme.ink, lineWidth: 1.5))
                    .frame(width: 10, height: 10)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    .accessibilityHidden(true)
                Text(headline(phase)).font(.fredoka(19, relativeTo: .title3))
            }
            switch phase {
            case .inProgress(let day, _):
                Text("Day \(day) of \(IsolationPolicy.days)").font(.fredoka(40, relativeTo: .largeTitle)).tracking(-0.5)
                    .padding(.top, 8)
                    .accessibilityIdentifier("athome.day")
                checkIn(r, now: now)
            case .periodOver(let feverFree):
                periodOver(feverFree: feverFree).padding(.top, 10)
            case .notIsolating:
                EmptyView()
            }
        }
        .foregroundStyle(Theme.ink)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("At home")
        .accessibilityIdentifier("athome.card")
        .alert("Can't change that yet", isPresented: Binding(get: { blocked != nil }, set: { if !$0 { blocked = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(blocked ?? "") }
    }

    private func headline(_ phase: IsolationPhase) -> String {
        if case .periodOver(true) = phase { return "Your \(IsolationPolicy.days) days are up" }
        return "You're staying home"
    }

    /// "How are you feeling today?" Better / The same / Worse, one tap each (SelfReportStore.checkIn). Today's
    /// answer stays picked; a fever can be added after, since it restarts the 24-hour fever-free clock.
    private func checkIn(_ r: SelfReportRecord, now: Date) -> some View {
        let cal = Calendar.current
        // Only a one-tap answer counts (a report also stamps lastCheckIn, with no feeling).
        let today = r.lastFeeling != nil && (r.lastCheckIn.map { cal.isDate($0, inSameDayAs: now) } ?? false)
        let picked = today ? r.lastFeeling : nil
        let feverToday = r.lastFeverAt.map { cal.isDate($0, inSameDayAs: now) } ?? false
        let buttons = ForEach(Feeling.allCases, id: \.self) { f in
            Button { store.checkIn(stillSymptomatic: true, hasFever: false, feeling: f, model: model) } label: {
                Text(f.label).font(.fredoka(15, relativeTo: .subheadline))
            }
            .buttonStyle(ChunkyButtonStyle(fill: picked == f ? Theme.sun : Theme.surface, radius: 13, lift: 2, minHeight: 44))
            .accessibilityAddTraits(picked == f ? .isSelected : [])
            .accessibilityIdentifier("checkin.\(f.rawValue)")
        }
        return VStack(alignment: .leading, spacing: 0) {
            Text("How are you feeling today?").font(.nunito(16, relativeTo: .callout, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if typeSize.isAccessibilitySize {
                VStack(spacing: 10) { buttons }.padding(.top, 10)
            } else {
                HStack(spacing: 8) { buttons }.padding(.top, 10)
            }
            if today && !feverToday {
                Button("I had a fever today") { store.checkIn(stillSymptomatic: true, hasFever: true, feeling: r.lastFeeling, model: model) }
                    .font(.fluni(.footnote, weight: .semibold)).underline()
                    .foregroundStyle(Theme.ink2).frame(minHeight: 44)
                    .padding(.top, 6)
                    .accessibilityHint("Restarts the 24 hours without a fever you need before going out")
                    .accessibilityIdentifier("checkin.fever")
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { DashedRule() }
        .padding(.top, 14)
    }

    private func periodOver(feverFree: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if feverFree {
                Text("How are you feeling?").font(.fluni(.body, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Text("Your status stays the same until you change it.").font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
                Button("Set my status to healthy") {
                    do { try store.feelFine(model: model) } catch { blocked = "Rest a little longer first. You can update your status once you've been fever-free for \(Int(IsolationPolicy.feverFreeHours)) hours." }
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("I'm still sick") { store.checkIn(stillSymptomatic: true, hasFever: false, feeling: .same, model: model) }
                    .font(.fluni(.subheadline, weight: .semibold)).underline().frame(minHeight: 44)
            } else {
                Text("You've had a fever in the last \(Int(IsolationPolicy.feverFreeHours)) hours.").font(.fluni(.body, weight: .semibold))
                Text("Stay home until the fever has been gone for a full day without fever-reducing medicine. Then you can update your status.")
                    .font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
            }
        }
    }

    static let advice = [
        "Tell your RA and your professors that you're sick and staying home.",
        "Use Vaden Health Center for testing and care. Call ahead instead of walking in.",
    ]
}

/// Today in sick mode, under the stay-home card: the 5-day track (day markers in front of a dotted line), what you
/// reported and your last check-in, and the tips.
struct RecoverySection: View {
    @ObservedObject var store: SelfReportStore
    let risk: Risk

    private struct Entry: Identifiable {
        let date: Date
        let title: String
        var detail: String?
        /// The row that says what nearby phones see now.
        var sharing = false
        var id: String { title }
    }

    var body: some View {
        let r = store.record
        let now = Date()
        let track = store.reporter.trackDays(r)
        let items = entries(r, now: now)
        VStack(alignment: .leading, spacing: 0) {
            if let zero = r.dayZero {
                SectionHeader(title: "Your recovery", note: "Started \(zero.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))")
            }
            if !track.isEmpty { DayTrack(days: track, now: now).padding(.bottom, 16) }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, e in
                TimelineRow(time: Self.dayWord(e.date, now: now), spokenTime: e.date.formatted(.dateTime.weekday(.wide)),
                            isLast: i == items.count - 1) {
                    Text(e.title).font(.fredoka(18, relativeTo: .body, weight: .medium)).foregroundStyle(Theme.ink)
                    if let d = e.detail {
                        Text(d).font(.fluni(.subheadline)).foregroundStyle(Theme.ink2).padding(.top, 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(e.sharing ? "today.sharedStatus" : "")
                    }
                }
            }
            tips.padding(.top, 4)
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AtHomeCard.advice, id: \.self) { line in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(Theme.ember).overlay(Circle().strokeBorder(Theme.ink, lineWidth: 1.5))
                        .frame(width: 7, height: 7).padding(.top, 8).accessibilityHidden(true)
                    Text(line).font(.fluni(.subheadline)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
            VadenLink().padding(.leading, 17)
        }
        .padding(.horizontal, 4)
    }

    /// What the user told FlUni, newest first: the last check-in, a positive test, the symptoms.
    private func entries(_ r: SelfReportRecord, now: Date) -> [Entry] {
        var out: [Entry] = []
        if let c = r.lastCheckIn, let feeling = r.lastFeeling {  // a report also stamps lastCheckIn; only answers show
            let fever = r.lastFeverAt.map { Calendar.current.isDate($0, inSameDayAs: c) } ?? false
            out.append(Entry(date: c, title: "Checked in: \(feeling.label.lowercased())",
                             detail: fever ? "Had a fever." : nil))
        }
        if let d = r.positiveDate {
            out.append(Entry(date: d, title: "Tested positive", detail: r.positiveKind.map { "\($0.label)." }))
        }
        if let d = r.onset, !r.symptoms.isEmpty {
            let names = Symptom.allCases.filter { r.symptoms.contains($0) }.map { $0.label.lowercased() }
            let list = ListFormatter.localizedString(byJoining: names)
            out.append(Entry(date: d, title: "Symptoms started", detail: list.prefix(1).uppercased() + list.dropFirst() + "."))
        }
        out.sort { $0.date > $1.date }
        // What phones nearby see now, on the newest report (never on the check-in).
        let shared = risk == .contagious ? "Phones nearby see “tested positive”." : "Phones nearby only see “possibly sick”."
        if let i = out.firstIndex(where: { !$0.title.hasPrefix("Checked in") }) {
            out[i].detail = [out[i].detail, shared].compactMap { $0 }.joined(separator: " ")
            out[i].sharing = true
        } else {
            out.append(Entry(date: now, title: "You told FlUni you're sick", detail: shared, sharing: true))
        }
        return out
    }

    /// "Today", or the short weekday ("Thu").
    static func dayWord(_ d: Date, now: Date) -> String {
        Calendar.current.isDate(d, inSameDayAs: now) ? "Today" : d.formatted(.dateTime.weekday(.abbreviated))
    }
}

/// Vaden's number, tap to call, and its hours (flu-decide, owner ruling): under the stay-home tips on Today and
/// under the stay-home card on Me.
struct VadenLink: View {
    var body: some View {
        // Vaden: Mon-Fri 8:15 AM-5 PM, most Saturdays 11-3 in the academic year (vaden.stanford.edu/our-hours-contact-details).
        Link(destination: URL(string: "tel:6504982336")!) {
            Label("Vaden Health · (650) 498-2336 · Mon–Fri 8:15–5", systemImage: "phone.fill")
                .font(.fluni(.footnote, weight: .semibold)).foregroundStyle(Theme.ink)
                .frame(minHeight: 44, alignment: .leading)
        }
        .accessibilityLabel("Call Vaden Health Center, 650 498 2336. Open Monday to Friday 8:15 AM to 5 PM, most Saturdays 11 AM to 3 PM.")
        .accessibilityIdentifier("athome.vaden")
    }
}

/// Day 0 to day 5 as markers on a dotted line. Done days are sage, today is sun with a ring, the rest are paper.
/// The markers are drawn in front of the line, so it never runs through them.
struct DayTrack: View {
    let days: [(day: Int, date: Date)]
    let now: Date

    var body: some View {
        let cal = Calendar.current
        HStack(alignment: .top, spacing: 0) {
            ForEach(days, id: \.day) { d in
                let isToday = cal.isDate(d.date, inSameDayAs: now)
                let done = d.date < cal.startOfDay(for: now)
                VStack(spacing: 5) {
                    Circle().fill(done ? Theme.sage : isToday ? Theme.sun : Theme.paper)
                        .overlay(Circle().strokeBorder(Theme.ink, lineWidth: 2))
                        .frame(width: 20, height: 20)
                        .overlay { if isToday { Circle().strokeBorder(Theme.ink, lineWidth: 1.5).padding(-4.5) } }
                    Text("\(isToday ? "Today" : d.date.formatted(.dateTime.weekday(.abbreviated)))\n\(d.day == 0 ? "day 0" : "\(d.day)")")
                        .font(.nunito(12, relativeTo: .caption, weight: .semibold))
                        .foregroundStyle(isToday ? Theme.ink : Theme.ink2)
                        .multilineTextAlignment(.center)
                        .fixedSize()
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)  // six across: past this the labels collide (VoiceOver reads each in full)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Day \(d.day), \(d.date.formatted(.dateTime.weekday(.wide)))\(isToday ? ", today" : done ? ", done" : "")")
            }
        }
        .background(alignment: .top) {
            GeometryReader { g in
                let inset = g.size.width / CGFloat(2 * max(days.count, 1))
                Path { p in
                    p.move(to: CGPoint(x: inset, y: 10))
                    p.addLine(to: CGPoint(x: g.size.width - inset, y: 10))
                }
                .stroke(Theme.ink2, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 4).padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("athome.track")
    }
}
