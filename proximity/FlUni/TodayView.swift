import SwiftUI

/// The student's home screen: one calm status card, a gentle progress bar, a count. No IDs, no
/// per-person distances (those live in the Developer screen).
struct TodayView: View {
    @ObservedObject var model: ProximityModel
    @State private var showHow = false
    @State private var showCalc = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var level: AlertLevel { exposure.level }
    private var exposure: ExposureTracker {
        #if DEBUG
        if let e = PreviewHook.exposure { return e }
        #endif
        return model.exposure
    }
    private var peerCount: Int {
        #if DEBUG
        if let n = PreviewHook.peerCount { return n }
        #endif
        return model.peers.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    DemoTimeBadge()
                    PausedBanner(model: model)
                    WalkInBanner(model: model)
                    UnusualSignalsBanner(model: model)
                    if level == .nearby { NearbyBanner().transition(.opacity) }
                    statusCard
                    riskCard
                    minutesCard
                    nearbyCard
                    ExposureHistorySection(store: model.exposureHistory)
                    Button { showHow = true } label: {
                        Label("How FlUni works and what it shares", systemImage: "info.circle")
                            .font(.fluni(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.ink2)
                            .frame(minHeight: 44)
                    }
                    .accessibilityHint("Opens a short explanation")
                }
                .padding(16)
            }
            .background(Theme.paper)
            .navigationTitle("Today")
            .animation(reduceMotion ? nil : .default, value: level)
            .sheet(isPresented: $showHow) { HowItWorksSheet() }
            .sheet(isPresented: $showCalc) { CalculationSheet(minutes: exposure.minutes, dose: exposure.dose) }
        }
    }

    // MARK: Status

    private var statusCard: some View {
        let s = Self.style(level)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(s.title).font(.fluni(.title2, weight: .bold))
                    Text(s.subtitle).font(.fluni(.subheadline))
                }
                Spacer(minLength: 0)
                if level == .none {
                    Image("Tissue").resizable().scaledToFit().frame(width: 56, height: 56).accessibilityHidden(true)
                } else {
                    Image(systemName: level == .closeContact ? "exclamationmark.circle.fill" : "info.circle.fill")
                        .font(.title).accessibilityHidden(true)
                }
            }
            if level != .none {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Advice.body(level), id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "arrow.right").font(.caption.bold()).accessibilityHidden(true)
                            Text(line).font(.fluni(.subheadline))
                        }
                    }
                }
            }
        }
        .foregroundStyle(s.text)
        // All clear: paper box with a sage tint. Alerts: Lisa's peach box (ink text; fire-ink fails on peach).
        .modifier(StatusBox(level: level, fill: s.fill))
        .accessibilityElement(children: .combine)
    }

    private static func style(_ level: AlertLevel) -> (title: String, subtitle: String, fill: Color, text: Color) {
        switch level {
        case .none:
            return ("All clear", "Nobody nearby has reported symptoms or a positive test.", Theme.sage.opacity(0.45), Theme.ink)
        case .nearby:
            return ("Someone nearby may be sick", "A few things that help right now.", Theme.sun.opacity(0.5), Theme.ink)
        case .closeContact:
            return ("Close contact", "You spent about 15 minutes near someone who may be sick.", Theme.fire.opacity(0.22), Theme.ink)
        }
    }

    // MARK: Risk

    private var riskCard: some View {
        RiskCardView(dose: exposure.dose) { showCalc = true }
    }

    // MARK: Minutes

    private var minutesCard: some View {
        let mins = exposure.minutes
        let goal = ExposureTracker.closeContactMinutes
        let tint = mins >= goal ? Theme.fireInk : Theme.ink2
        let caption = mins >= goal ? "You've reached the \(Int(goal))-minute close-contact mark."
            : mins > 0 ? "About \(Int((goal - mins).rounded(.up))) more minutes would make this a close contact."
            : "No time near someone with symptoms or a positive test."
        return VStack(alignment: .leading, spacing: 10) {
            Text("Close-contact time").font(.fluni(.headline))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(min(mins, 99)))").font(.fluni(.largeTitle, weight: .bold)).monospacedDigit()
                Text("of \(Int(goal)) min").font(.fluni(.subheadline)).foregroundStyle(Theme.ink2)
            }
            ProgressView(value: min(mins, goal), total: goal).tint(tint).accessibilityHidden(true)
            Text(caption).font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
        }
        .foregroundStyle(Theme.ink)
        .card()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Close-contact time")
        .accessibilityValue("\(Int(mins)) of \(Int(goal)) minutes. \(caption)")
    }

    // MARK: Nearby

    private var nearbyCard: some View {
        let n = peerCount
        let text = n == 0 ? "No other FlUni phones nearby" : n == 1 ? "1 other FlUni phone nearby" : "\(n) other FlUni phones nearby"
        return HStack(spacing: 12) {
            Image(systemName: "person.2.wave.2").font(.title3).foregroundStyle(Theme.ink2).accessibilityHidden(true)
            Text(text).font(.fluni(.body, weight: .semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.ink)
        .card()
        .accessibilityElement(children: .combine)
    }
}

struct HowItWorksSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    block("How it works",
                          "Your phone and other phones running FlUni notice each other over Bluetooth, and with precise distance sensing on newer iPhones. Together they estimate whether you're within 6 feet. If someone with symptoms or who tested positive is close for about 15 minutes in total, you get a heads-up with advice.")
                    block("What your phone shares",
                          "Only a 3-level status (healthy, possibly sick or contagious) and a random ID that changes every 15 minutes. No name, no phone number, no account.")
                    block("What it doesn't share",
                          "Your location is never sent to other people or to a server. Matching happens on your phone, and the map shows building totals, not people.")
                    block("Good to know",
                          "FlUni works while the app is open. It's a nudge, not a diagnosis. If you feel unwell or are worried, get tested and follow campus health guidance.")
                }
                .padding(20)
            }
            .background(Theme.paper)
            .navigationTitle("How this works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private func block(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.fluni(.headline)).accessibilityAddTraits(.isHeader)
            Text(body).font(.fluni(.body)).foregroundStyle(Theme.ink2)
        }
        .foregroundStyle(Theme.ink)
    }
}

/// Shows the real numbers behind the risk estimate.
struct CalculationSheet: View {
    let minutes: Double
    let dose: Double
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PSickStore.shared

    var body: some View {
        let p = RiskEstimate.probability(dose: dose)
        let x = RiskEstimate.contactTerm(dose: dose)
        let m = String(format: "%.1f", minutes)
        let d = String(format: "%.1f", dose)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    block("Close contact",
                          "Minutes within 6 ft of someone. They count in full if the person tested positive and half if they have symptoms. At \(Int(ExposureTracker.closeContactMinutes)) of these in a day, FlUni tells you it's a close contact.",
                          "You: \(m) of \(Int(ExposureTracker.closeContactMinutes))")
                    block("Closeness-weighted time",
                          "The same minutes, but closer counts more: under 1 m ×1, 1–2 m ×0.6, 2–5 m ×0.1, farther in the room ×0.02.",
                          "You: \(d) weighted minutes")
                    block("The estimate",
                          "The contact part is x = 1 \u{2212} e^(\u{2212}\(RiskEstimate.beta) × dose), at most \(Int(RiskEstimate.xMax * 100))%. Then P = 1 \u{2212} \(1 - RiskEstimate.prior) × (1 \u{2212} x), where \(Int(RiskEstimate.prior * 100))% is the everyday baseline. Same model as the campus map.",
                          "x = \(RiskEstimate.percentText(x)), so P = \(RiskEstimate.percentText(p))")
                    block("What counts",
                          "Only the last 24 hours. GPS alone doesn't count indoors, because it's too coarse to tell 3 feet from 30. Bluetooth and precise distance sensing do.", nil)
                    block("Campus model vs this phone",
                          "The campus model is the official number, worked out from everyone's contacts, reports and tests, including second-hand risk (being near someone who was near someone sick). This phone's estimate uses only what this phone detected in the last 24 hours, in a simplified form of the same formula, so the two can differ.",
                          store.campusP.map { "Campus model: \(RiskEstimate.percentText($0)) \u{00B7} This phone: \(RiskEstimate.percentText(p))" })
                    Text("This is an estimate to help you decide what to do. It isn't a diagnosis.")
                        .font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
                }
                .padding(20)
            }
            .background(Theme.paper)
            .navigationTitle("How is this calculated?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func block(_ title: String, _ body: String, _ numbers: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.fluni(.headline))
            Text(body).font(.fluni(.body)).foregroundStyle(Theme.ink2)
            if let numbers {
                Text(numbers).font(.fluni(.subheadline, weight: .semibold)).monospacedDigit()
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.radius))
            }
        }
        .foregroundStyle(Theme.ink)
    }
}

/// Paper box with a tint for "all clear"; peach box for alerts.
private struct StatusBox: ViewModifier {
    let level: AlertLevel
    let fill: Color
    func body(content: Content) -> some View {
        if level == .none { content.card(fill: fill) } else { content.card(.peach) }
    }
}
