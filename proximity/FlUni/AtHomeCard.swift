import SwiftUI

/// Today, while the user is possibly sick or contagious: the page becomes about staying home. Their status in plain
/// words, which day of isolation it is, one action (the daily check-in) and the practical steps. It only ever asks;
/// it never changes the status by itself. The risk of catching something is hidden: it no longer applies.
struct StayingHomeView: View {
    @ObservedObject var model: ProximityModel
    @ObservedObject var store: SelfReportStore
    @State private var blocked: String?
    @State private var updating = false

    var body: some View {
        let now = Date()
        let r = store.record
        let phase = store.reporter.phase(r, now: now)
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.m) {
                // Lisa's "feeling sick" tissue (design pass).
                Image("FeelingSick").resizable().scaledToFit().frame(maxHeight: 150)
                    .frame(maxWidth: .infinity).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(model.myRisk == .contagious ? "You tested positive" : "You've said you have symptoms")
                        .font(.fluni(.display)).accessibilityAddTraits(.isHeader)
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        StatusSwatch(risk: model.myRisk)
                        Text(model.myRisk == .contagious ? "Phones near you see: contagious." : "Phones near you see: possibly sick.")
                            .font(.fluni(.note))
                    }
                }
                .accessibilityElement(children: .combine)
                IsolationProgress(phase: phase)
                action(phase: phase, checkInDue: store.reporter.checkInDue(r, now: now))
            }
            .foregroundStyle(Theme.ink)
            .card()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("today.athome")

            AtHomeSteps()

            Button { AppRouter.shared.tab = .me } label: {
                Text("Tested negative, or feeling better? Update your status")
            }
            .buttonStyle(QuietLinkStyle())
            .accessibilityHint("Opens the Me tab")
        }
        .alert("Can't change that yet", isPresented: Binding(get: { blocked != nil }, set: { if !$0 { blocked = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(blocked ?? "") }
    }

    /// The one action for today: the check-in when it's due (or when asked for), else a way to answer it anyway.
    @ViewBuilder private func action(phase: IsolationPhase, checkInDue: Bool) -> some View {
        if case .periodOver(let feverFree) = phase {
            PeriodOver(feverFree: feverFree, model: model, store: store, blocked: $blocked)
        } else if checkInDue || updating {
            CheckIn(model: model, store: store) { updating = false }
        } else {
            Button("Update how I feel") { updating = true }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityHint("Asks whether you still have symptoms")
        }
    }
}

/// Me, while sick: a short summary of the same plan. The check-in itself lives on Today.
struct AtHomeCard: View {
    @ObservedObject var model: ProximityModel
    @ObservedObject var store: SelfReportStore

    var body: some View {
        let phase = store.reporter.phase(store.record, now: Date())
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.s) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("At home").font(.fluni(.heading)).accessibilityAddTraits(.isHeader)
                    Text("Your daily check-in is on Today.").font(.fluni(.note)).foregroundStyle(Theme.ink2)
                }
                Spacer(minLength: 0)
                Image("FeelingSick").resizable().scaledToFit().frame(width: 72).accessibilityHidden(true)
            }
            IsolationProgress(phase: phase)
            AtHomeSteps(compact: true)
            Button { AppRouter.shared.tab = .today } label: { Text("Check in on Today") }
                .buttonStyle(QuietLinkStyle())
        }
        .foregroundStyle(Theme.ink)
        .padding(Space.xxs)
        .panel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("At home")
        .accessibilityIdentifier("athome.card")
    }

    static let advice = [
        "Tell your RA and your professors that you're sick and staying home.",
        "Use Vaden Health Center for testing and care. Call ahead instead of walking in.",
        "If you have to go out, wear a mask and keep it short.",
        "Skip the dining halls. Ask a friend to bring food, or order takeout.",
    ]
}

/// "Day 2 of 5" with one drawn tick per day, the last day, and the fever rule.
private struct IsolationProgress: View {
    let phase: IsolationPhase

    var body: some View {
        if case .inProgress(let day, let last) = phase {
            VStack(alignment: .leading, spacing: Space.xs) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) { dayLabel(day); Spacer(minLength: 0); until(last) }
                    VStack(alignment: .leading, spacing: Space.xxs) { dayLabel(day); until(last) }
                }
                HStack(spacing: Space.xxs) {
                    ForEach(1...IsolationPolicy.days, id: \.self) { d in
                        Capsule().fill(d <= day ? Theme.ink2 : Color.clear)
                            .overlay(Capsule().stroke(Theme.ink2, lineWidth: 1))
                            .frame(height: 8)
                    }
                }
                .accessibilityHidden(true)
                Text("Stay home until you've also had no fever for \(Int(IsolationPolicy.feverFreeHours)) hours without fever-reducing medicine. Day 0 is the day your symptoms started or you tested positive.")
                    .font(.fluni(.fine)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Theme.ink)
        }
    }

    private func dayLabel(_ day: Int) -> some View {
        Text("Day \(day) of \(IsolationPolicy.days)").font(.fluni(.section)).monospacedDigit()
    }

    private func until(_ last: Date) -> some View {
        Text("Home through \(last.formatted(.dateTime.weekday(.wide).month().day()))").font(.fluni(.note))
    }
}

/// "What to do": the four practical steps, as a list on paper split by Lisa's pencil rule.
private struct AtHomeSteps: View {
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? Space.xs : Space.s) {
            Text("What to do").font(.fluni(compact ? .heading : .section)).accessibilityAddTraits(.isHeader)
            ForEach(Array(AtHomeCard.advice.enumerated()), id: \.offset) { i, line in
                if !compact && i > 0 { HandRule() }
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Circle().fill(Theme.pencil.opacity(0.7)).frame(width: 6, height: 6).accessibilityHidden(true)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    Text(line).font(.fluni(compact ? .fine : .reading)).foregroundStyle(compact ? Theme.ink2 : Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundStyle(Theme.ink)
    }
}

/// The gentle daily question. Three plain answers, all equal: none of them is the "right" one.
private struct CheckIn: View {
    @ObservedObject var model: ProximityModel
    @ObservedObject var store: SelfReportStore
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Do you still have symptoms?").font(.fluni(.heading)).accessibilityAddTraits(.isHeader)
            answer("Yes, still sick") { store.checkIn(stillSymptomatic: true, hasFever: false, model: model) }
            answer("Yes, and I have a fever") { store.checkIn(stillSymptomatic: true, hasFever: true, model: model) }
            answer("No, I feel better") { store.checkIn(stillSymptomatic: false, hasFever: false, model: model) }
        }
    }

    private func answer(_ title: String, _ act: @escaping () -> Void) -> some View {
        Button(title) { act(); done() }.buttonStyle(SecondaryButtonStyle())
    }
}

/// The minimum period is over: ask, never assume.
private struct PeriodOver: View {
    let feverFree: Bool
    @ObservedObject var model: ProximityModel
    @ObservedObject var store: SelfReportStore
    @Binding var blocked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if feverFree {
                Text("Your \(IsolationPolicy.days) days are up. How are you feeling?").font(.fluni(.heading))
                    .accessibilityAddTraits(.isHeader)
                Text("Your status stays the same until you change it.").font(.fluni(.fine)).foregroundStyle(Theme.ink2)
                Button("Set my status to healthy") {
                    do { try store.feelFine(model: model) } catch { blocked = "Rest a little longer first. You can update your status once you've been fever-free for \(Int(IsolationPolicy.feverFreeHours)) hours." }
                }.buttonStyle(PrimaryButtonStyle())
                Button("I'm still sick") { store.checkIn(stillSymptomatic: true, hasFever: false, model: model) }
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

/// A small disc in the status colour, outlined in ink so it reads on paper (sage and sun alone are under 3:1).
/// Always next to the status in words; colour is never the only cue.
struct StatusSwatch: View {
    let risk: Risk
    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(risk == .contagious ? Theme.fire : risk == .possible ? Theme.sun : Theme.sage)
            .overlay(Circle().stroke(Theme.ink2, lineWidth: 1))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
