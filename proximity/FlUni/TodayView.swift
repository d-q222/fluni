import CoreBluetooth
import SwiftUI

/// The student's home screen. One status at the top that answers "am I OK?" in two seconds, then the last
/// 24 hours as a short ledger, then recent contacts. No IDs, no per-person distances (those live in Developer).
/// While the user is possibly sick or contagious, Today becomes their stay-home plan instead (StayingHomeView).
struct TodayView: View {
    @ObservedObject var model: ProximityModel
    @ObservedObject var store: SelfReportStore
    @State private var showHow = false
    @State private var showCalc = false
    @State private var report: ReportKind?
    /// One line when iOS settings would stop alerts while FlUni is closed.
    @State private var backgroundHint: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

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
    private var isSick: Bool { model.myRisk != .none }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    notices
                    if isSick {
                        StayingHomeView(model: model, store: store)
                        DisclosureGroup {
                            ExposureHistorySection(store: model.exposureHistory, showsTitle: false).padding(.top, Space.xs)
                        } label: {
                            Text("Recent contacts").font(.fluni(.heading)).foregroundStyle(Theme.ink)
                        }
                        .tint(Theme.ink2)
                        .accessibilityHint("Shows your recent contacts, which can help when you tell people")
                    } else {
                        // Paused: the paused notice above is the status; "All clear" wouldn't be true.
                        if !model.isPaused { statusHero }
                        ledger
                        ExposureHistorySection(store: model.exposureHistory)
                    }
                    Button { showHow = true } label: { Text("How FlUni works and what it shares") }
                        .buttonStyle(QuietLinkStyle())
                        .accessibilityHint("Opens a short explanation")
                }
                .padding(.horizontal, Space.m)
                .padding(.bottom, Space.l)
            }
            .background(Theme.paper)
            .navigationTitle("Today")
            .animation(reduceMotion ? nil : .default, value: level)
            .sheet(isPresented: $showHow) { HowItWorksSheet() }
            .sheet(item: $report) { ReportSheet(kind: $0, model: model, store: store) }
            .onAppear(perform: checkBackground)
            .onChange(of: scenePhase) { _, p in if p == .active { checkBackground() } }
            .sheet(isPresented: $showCalc) { CalculationSheet(minutes: exposure.minutes, dose: exposure.dose) }
            .onReceive(AppRouter.shared.dismissSheets) { showHow = false; showCalc = false; report = nil }
        }
    }

    private func checkBackground() {
        let bt = CBManager.authorization
        if bt == .denied || bt == .restricted {
            backgroundHint = "Bluetooth is off for FlUni in iPhone Settings, so it can't notice nearby phones."
        } else if UIApplication.shared.backgroundRefreshStatus != .available {
            backgroundHint = "Background App Refresh is off, so nearby alerts may stop while FlUni is closed."
        } else {
            backgroundHint = nil
        }
    }

    // MARK: Notices

    /// Things about the app or the place, above the status. Each shows nothing when it doesn't apply.
    private var notices: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            DemoTimeBadge()
            PausedBanner(model: model)
            if let backgroundHint {
                Text(backgroundHint).font(.fluni(.fine)).foregroundStyle(Theme.ink)
                    .panel()
            }
            WalkInBanner(model: model)
            UnusualSignalsBanner(model: model)
        }
    }

    // MARK: Status

    /// The one thing that matters most, in Lisa's drawn box: paper with a sage tint when all is clear,
    /// her peach box (heads-up, ink text only) when someone nearby may be sick or it's a close contact.
    private var statusHero: some View {
        let s = Self.style(level)
        let steps = level == .closeContact ? Array(Advice.body(level).dropFirst()) : Advice.body(level)
        return VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .top, spacing: Space.s) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(s.title).font(.fluni(.display)).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("today.status")
                    Text(s.subtitle).font(.fluni(.note)).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                if level == .none && !typeSize.isAccessibilitySize {
                    // Lisa's tissue, big enough to be an illustration rather than a badge; tucked into the corner.
                    Image("Tissue").resizable().scaledToFit().frame(width: 92, height: 92)
                        .rotationEffect(.degrees(-8)).offset(x: 6, y: -10)
                        .accessibilityHidden(true)
                }
            }
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, line in
                        Step(number: i + 1, text: line)
                    }
                }
            }
            Button(level == .closeContact ? "I've started feeling sick" : "I don't feel well") { report = .symptoms }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityHint("Opens a short form to report symptoms")
                .accessibilityIdentifier("today.reportSymptoms")
        }
        .foregroundStyle(Theme.ink)
        .modifier(StatusBox(level: level, fill: s.fill))
        .accessibilityElement(children: .contain)
    }

    private static func style(_ level: AlertLevel) -> (title: String, subtitle: String, fill: Color) {
        switch level {
        case .none:
            return ("All clear", "Nobody nearby has reported symptoms or a positive test.", Theme.sage.opacity(0.45))
        case .nearby:
            return ("Someone nearby may be sick", "They're probably within 6 ft of you right now.", Theme.sun.opacity(0.5))
        case .closeContact:
            return ("Close contact", "You've spent about 15 minutes within 6 ft of someone who may be sick.", Theme.fire.opacity(0.22))
        }
    }

    // MARK: Ledger

    /// The last 24 hours as three plain lines on paper, split by Lisa's pencil rule. Not cards: it's a record.
    private var ledger: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Your last 24 hours").font(.fluni(.section)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
            minutesLine
            HandRule()
            RiskCardView(dose: exposure.dose) { showCalc = true }
            HandRule()
            nearbyLine
        }
    }

    private var minutesLine: some View {
        let mins = exposure.minutes
        let goal = ExposureTracker.closeContactMinutes
        let caption = mins >= goal ? "You've reached the \(Int(goal))-minute close-contact mark."
            : mins > 0 ? "About \(Int((goal - mins).rounded(.up))) more minutes would make this a close contact."
            : "No time near someone with symptoms or a positive test."
        return VStack(alignment: .leading, spacing: Space.xs) {
            LedgerLine(label: "Close-contact time") {
                (Text("\(Int(min(mins, 99)))").font(.fluni(.section)) + Text(" of \(Int(goal)) min").font(.fluni(.note)))
                    .monospacedDigit()
            }
            // ink-2 on paper for the bar (7:1); fire-ink once it's a close contact. Never sage or ember: under 3:1.
            ProgressView(value: min(mins, goal), total: goal).tint(mins >= goal ? Theme.fireInk : Theme.ink2)
                .accessibilityHidden(true)
            Text(caption).font(.fluni(.fine)).foregroundStyle(Theme.ink2)
        }
        .foregroundStyle(Theme.ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Close-contact time")
        .accessibilityValue("\(Int(mins)) of \(Int(goal)) minutes. \(caption)")
    }

    private var nearbyLine: some View {
        let n = peerCount
        return LedgerLine(label: "Other FlUni phones nearby") {
            Text(n == 0 ? "None" : "\(n)").font(.fluni(.section)).monospacedDigit()
        }
        .foregroundStyle(Theme.ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(n == 0 ? "No other FlUni phones nearby" : n == 1 ? "1 other FlUni phone nearby" : "\(n) other FlUni phones nearby")
    }
}

/// "Label ............ value": side by side, or stacked when large text would squeeze it.
struct LedgerLine<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(label).font(.fluni(.heading)).lineLimit(1)
                Spacer(minLength: Space.xs)
                value
            }
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(label).font(.fluni(.heading))
                value
            }
        }
    }
}

/// A numbered step. The number is set in a small drawn-feeling ring: order matters here (leave first, then wash).
struct Step: View {
    let number: Int
    let text: String
    @ScaledMetric(relativeTo: .body) private var ring: CGFloat = 26

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text("\(number)")
                .font(.fluni(.fine).weight(.bold)).monospacedDigit()
                .frame(width: ring, height: ring)
                .overlay(Circle().stroke(Theme.ink, lineWidth: Theme.stroke))
                .accessibilityHidden(true)
            Text(text).font(.fluni(.reading)).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(text)")
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
                          "FlUni works best while the app is open, and keeps checking over Bluetooth in the background, less often. It's a nudge, not a diagnosis. If you feel unwell or are worried, get tested and follow campus health guidance.")
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
