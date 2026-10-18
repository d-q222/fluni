import SwiftUI

/// Shown on the Me tab while the user is possibly sick or contagious: which day of isolation it is,
/// what to do, and a gentle daily check-in. It only ever asks; it never changes the status by itself.
struct AtHomeCard: View {
    @ObservedObject var model: ProximityModel
    @ObservedObject var store: SelfReportStore
    @State private var blocked: String?

    var body: some View {
        let now = Date()
        let r = store.record
        let rep = store.reporter
        let phase = rep.phase(r, now: now)
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Label("At home", systemImage: "house.fill").font(.fluni(.headline))
                    Spacer()
                    dayText(phase)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label("At home", systemImage: "house.fill").font(.fluni(.headline))
                    dayText(phase)
                }
            }
            .foregroundStyle(Theme.ink)
            // Lisa's "feeling sick" tissue (design pass).
            Image("FeelingSick").resizable().scaledToFit().frame(maxHeight: 110)
                .frame(maxWidth: .infinity).accessibilityHidden(true)
                .overlay(alignment: .topTrailing) {
                    // Lisa's "Self-reported" stamp while the status comes from symptoms, not a test.
                    if r.positiveKind == nil && !r.symptoms.isEmpty {
                        Image("StampSelfReported").resizable().scaledToFit()
                            .frame(width: 64)
                            .rotationEffect(.degrees(-12))
                            .accessibilityLabel("Self-reported")
                    }
                }
            header(phase)
            if case .periodOver(let feverFree) = phase {
                periodOver(feverFree: feverFree)
            } else if rep.checkInDue(r, now: now) {
                checkIn
            }
            steps
        }
        .card(fill: Theme.surface2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("At home")
        .accessibilityIdentifier("athome.card")
        .alert("Can't change that yet", isPresented: Binding(get: { blocked != nil }, set: { if !$0 { blocked = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(blocked ?? "") }
    }

    @ViewBuilder private func dayText(_ phase: IsolationPhase) -> some View {
        if case .inProgress(let day, _) = phase {
            Text("Day \(day) of \(IsolationPolicy.days)").font(.fluni(.subheadline, weight: .semibold))
        }
    }

    @ViewBuilder private func header(_ phase: IsolationPhase) -> some View {
        switch phase {
        case .inProgress(let day, let last):
            ProgressView(value: Double(min(day, IsolationPolicy.days)), total: Double(IsolationPolicy.days))
                .tint(Theme.ink2).accessibilityHidden(true)
            Text("Stay home through \(last.formatted(.dateTime.weekday(.wide).month().day())), and until you've had no fever for \(Int(IsolationPolicy.feverFreeHours)) hours without fever-reducing medicine. Day 0 is the day your symptoms started or you tested positive.")
                .font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
        case .periodOver, .notIsolating:
            EmptyView()
        }
    }

    private func periodOver(feverFree: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if feverFree {
                Text("Your \(IsolationPolicy.days) days are up. How are you feeling?").font(.fluni(.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Your status stays the same until you change it.").font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
                Button("Set my status to healthy") {
                    do { try store.feelFine(model: model) } catch { blocked = "Rest a little longer first. You can update your status once you've been fever-free for \(Int(IsolationPolicy.feverFreeHours)) hours." }
                }.buttonStyle(PrimaryButtonStyle())
                Button("I'm still sick") { store.checkIn(stillSymptomatic: true, hasFever: false, model: model) }
                    .buttonStyle(.bordered).tint(Theme.ink).frame(minHeight: 44)
            } else {
                Text("You've had a fever in the last \(Int(IsolationPolicy.feverFreeHours)) hours.").font(.fluni(.body, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("Stay home until the fever has been gone for a full day without fever-reducing medicine. Then you can update your status.")
                    .font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
            }
        }
    }

    private var checkIn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Do you still have symptoms?").font(.fluni(.body, weight: .semibold)).foregroundStyle(Theme.ink)
            Button("Yes, still sick") { store.checkIn(stillSymptomatic: true, hasFever: false, model: model) }
                .buttonStyle(.bordered).tint(Theme.ink).frame(minHeight: 44)
            Button("Yes, and I have a fever") { store.checkIn(stillSymptomatic: true, hasFever: true, model: model) }
                .buttonStyle(.bordered).tint(Theme.ink).frame(minHeight: 44)
            Button("No, I feel better") { store.checkIn(stillSymptomatic: false, hasFever: false, model: model) }
                .buttonStyle(.bordered).tint(Theme.ink).frame(minHeight: 44)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What to do").font(.fluni(.subheadline, weight: .semibold)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            ForEach(AtHomeCard.advice, id: \.self) { line in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").accessibilityHidden(true)
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
                .font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
            }
        }
    }

    static let advice = [
        "Tell your RA and your professors that you're sick and staying home.",
        "Use Vaden Health Center for testing and care. Call ahead instead of walking in.",
        "If you have to go out, wear a mask and keep it short.",
        "Skip the dining halls. Ask a friend to bring food, or order takeout.",
    ]
}
