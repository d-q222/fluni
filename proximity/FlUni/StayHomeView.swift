import SwiftUI

/// Today while you're possibly sick or contagious (B-5): the stay-home plan as a 5-day track on the same side
/// line. Day 0 is the day it started (Core/SelfReport.swift's IsolationPolicy), then days 1 to 5; today's
/// point holds the one-tap check-in. It only ever asks; it never changes the status by itself. The risk of
/// catching something is hidden: it no longer applies.
struct StayHomeView: View {
    @ObservedObject var model: ProximityModel
    @ObservedObject var store: SelfReportStore
    let onReport: (ReportStart) -> Void
    @State private var blocked: String?

    private var cal: Calendar { store.reporter.calendar }

    var body: some View {
        let now = Date()
        let r = store.record
        let phase = store.reporter.phase(r, now: now)
        VStack(alignment: .leading, spacing: Space.l) {
            heading(phase: phase)
            if case .periodOver(let feverFree) = phase {
                PeriodOver(feverFree: feverFree, model: model, store: store, blocked: $blocked)
            } else {
                track(r, now: now)
            }
            advice
            Button { onReport(.choose) } label: { Text("Tested negative, or feeling well again?") }
                .buttonStyle(QuietLinkStyle())
                .accessibilityHint("Opens the report, where you can change your status")
                .accessibilityIdentifier("athome.update")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.athome")
        .alert("Can't change that yet", isPresented: Binding(get: { blocked != nil }, set: { if !$0 { blocked = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(blocked ?? "") }
    }

    private func heading(phase: IsolationPhase) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Staying home").font(.fluni(.heading)).foregroundStyle(Theme.ink2)
            if case .inProgress(let day, let last) = phase {
                Text("Day \(day) of \(IsolationPolicy.days)").font(Face.serif(46, .largeTitle)).monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("athome.day")
                Text("Home through \(last.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))")
                    .font(.fluni(.strong)).foregroundStyle(Theme.ink)
            } else {
                Text("Your \(IsolationPolicy.days) days are up").font(.fluni(.display)).foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                StatusSwatch(risk: model.myRisk)
                Text(model.myRisk == .contagious ? "Nearby phones see you as contagious" : "Nearby phones see you as possibly sick")
                    .font(.fluni(.note)).foregroundStyle(Theme.ink)
            }
            .padding(.top, Space.xxs)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: The track

    private func track(_ r: SelfReportRecord, now: Date) -> some View {
        let today = cal.startOfDay(for: now)
        let days = store.reporter.trackDays(r)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                let isToday = d.date == today
                let past = d.date < today
                let last = d.day == IsolationPolicy.days
                RailRow(label: isToday ? "Today" : nil, time: dayLabel(d.date),
                        node: isToday ? .now : past ? .dayDone : last ? .dayLast : .dayAhead,
                        line: last ? .none : (d.date < today ? .recovering : .ahead),
                        nodeY: isToday ? 16 : 12) {
                    if isToday {
                        TodayCheckIn(day: d.day, record: r, model: model, store: store)
                    } else {
                        dayRow(d.day, date: d.date, record: r, past: past, last: last)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func dayLabel(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated)) + " " + d.formatted(.dateTime.day())
    }

    private func dayRow(_ day: Int, date: Date, record r: SelfReportRecord, past: Bool, last: Bool) -> some View {
        let title: String
        var detail: String?
        if day == 0 {
            title = r.positiveDate.map { cal.isDate($0, inSameDayAs: date) } == true && r.symptoms.isEmpty ? "Day 0, tested positive" : "Day 0, symptoms started"
            let names = r.symptoms.sorted { $0.rawValue < $1.rawValue }.map { $0.label.lowercased() }
            detail = names.isEmpty ? r.positiveKind.map { "\($0.label)." } : names.joined(separator: ", ").capitalizedFirst + "."
        } else if last {
            title = "Day \(day), last day home"
            let out = cal.date(byAdding: .day, value: 1, to: date)!
            detail = "Out on \(out.formatted(.dateTime.weekday(.wide))), if you've had no fever for \(Int(IsolationPolicy.feverFreeHours)) hours."
        } else {
            title = "Day \(day)"
            detail = past ? nil : "Check in"
        }
        return VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title).font(.fluni(.strong)).foregroundStyle(Theme.ink)
            if let detail { Text(detail).font(.fluni(.note)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true) }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Advice

    private var advice: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("While you're home").font(.fluni(.section)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
            ForEach(Array(Self.advice.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Circle().fill(Theme.ink).frame(width: 6, height: 6).accessibilityHidden(true)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    Text(line).font(.fluni(.reading)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, Space.xs)
    }

    /// The first two word for word from the brief.
    static let advice = [
        "Tell your RA and your professors that you're sick and staying home.",
        "Use Vaden Health Center for testing and care. Call ahead instead of walking in.",
    ]
}

/// Today's point on the track: "How are you feeling?" with Better / The same / Worse as one tap. Once
/// answered it says so, and offers the one thing the fever rule needs to know.
private struct TodayCheckIn: View {
    let day: Int
    let record: SelfReportRecord
    @ObservedObject var model: ProximityModel
    @ObservedObject var store: SelfReportStore
    @State private var changing = false
    @State private var feverNoted = false

    var body: some View {
        let due = store.reporter.checkInDue(record, now: Date())
        VStack(alignment: .leading, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(day == 0 ? "Day 0, it started" : "Day \(day)").font(.fluni(.fine).weight(.semibold)).foregroundStyle(Theme.ink2)
                Text("How are you feeling?").font(.fluni(.lead)).foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                if due || changing {
                    Text("Today's check-in. One tap.").font(.fluni(.note)).foregroundStyle(Theme.ink2)
                }
            }
            if due || changing {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.xs) { answers }
                    VStack(spacing: Space.xs) { answers }
                }
            } else {
                answered
            }
            Text("Fever-free for 24 h without medicine? Then you can end your stay once day \(IsolationPolicy.days) is done.")
                .font(.fluni(.fine)).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var answers: some View {
        ForEach(Feeling.allCases, id: \.self) { f in
            Button(f.label) {
                store.checkIn(stillSymptomatic: true, hasFever: false, feeling: f, model: model)
                changing = false
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityIdentifier("checkin.\(f.rawValue)")
        }
    }

    private var answered: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(thanks).font(.fluni(.reading)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("checkin.done")
            HStack(spacing: Space.m) {
                Button("Change") { changing = true }.buttonStyle(QuietLinkStyle())
                if feverNoted {
                    Text("Fever noted.").font(.fluni(.note)).foregroundStyle(Theme.ink2)
                } else {
                    Button("I had a fever today") {
                        store.checkIn(stillSymptomatic: true, hasFever: true, feeling: record.lastFeeling, model: model)
                        feverNoted = true
                    }
                    .buttonStyle(QuietLinkStyle())
                    .accessibilityHint("Restarts the 24-hour fever-free clock")
                }
            }
        }
    }

    private var thanks: String {
        switch record.lastFeeling {
        case .better: return "Checked in: better. Glad to hear it. Keep resting."
        case .same: return "Checked in: the same. Rest, fluids, and check in again tomorrow."
        case .worse: return "Checked in: worse. If it keeps getting worse, call Vaden before you go in."
        case nil: return "You've checked in today."
        }
    }
}

/// The minimum period is over: ask, never assume.
private struct PeriodOver: View {
    let feverFree: Bool
    @ObservedObject var model: ProximityModel
    @ObservedObject var store: SelfReportStore
    @Binding var blocked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if feverFree {
                Text("How are you feeling?").font(.fluni(.lead)).accessibilityAddTraits(.isHeader)
                Text("Your status stays the same until you change it.").font(.fluni(.fine)).foregroundStyle(Theme.ink2)
                Button("Set my status to healthy") {
                    do { try store.feelFine(model: model) } catch { blocked = "Rest a little longer first. You can update your status once you've been fever-free for \(Int(IsolationPolicy.feverFreeHours)) hours." }
                }.buttonStyle(PrimaryButtonStyle())
                Button("I'm still sick") { store.checkIn(stillSymptomatic: true, hasFever: false, feeling: .same, model: model) }
                    .buttonStyle(SecondaryButtonStyle())
            } else {
                Text("You've had a fever in the last \(Int(IsolationPolicy.feverFreeHours)) hours.").font(.fluni(.heading))
                Text("Stay home until the fever has been gone for a full day without fever-reducing medicine. Then you can update your status.")
                    .font(.fluni(.fine)).foregroundStyle(Theme.ink2)
            }
        }
        .foregroundStyle(Theme.ink)
    }
}

/// You, while sick: a short line about the plan. The check-in itself lives on Today.
struct StayHomeSummary: View {
    @ObservedObject var model: ProximityModel
    @ObservedObject var store: SelfReportStore

    var body: some View {
        let phase = store.reporter.phase(store.record, now: Date())
        HStack(alignment: .center, spacing: Space.s) {
            Image("FeelingSick").resizable().scaledToFit().frame(width: 64).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                if case .inProgress(let day, let last) = phase {
                    Text("Staying home, day \(day) of \(IsolationPolicy.days)").font(.fluni(.heading))
                    Text("Home through \(last.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())). Your check-in is on Today.")
                        .font(.fluni(.note)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Your \(IsolationPolicy.days) days are up").font(.fluni(.heading))
                    Text("Today asks how you're feeling.").font(.fluni(.note)).foregroundStyle(Theme.ink2)
                }
                Button { AppRouter.shared.tab = .today } label: { Text("Check in on Today") }
                    .buttonStyle(QuietLinkStyle())
            }
        }
        .foregroundStyle(Theme.ink)
        .panel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("athome.card")
    }
}

/// A small disc in the status colour, outlined in ink so it reads on paper (sage and sun alone are under 3:1).
/// Always next to the status in words; colour is never the only cue.
struct StatusSwatch: View {
    let risk: Risk
    @ScaledMetric private var size: CGFloat
    init(risk: Risk, size: CGFloat = 12) { self.risk = risk; _size = ScaledMetric(wrappedValue: size, relativeTo: .subheadline) }

    var body: some View {
        Circle()
            .fill(risk == .contagious ? Theme.fire : risk == .possible ? Theme.sun : Theme.sage)
            .overlay(Circle().stroke(Theme.ink2, lineWidth: 1))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
