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
                        WalkInBanner(model: model)
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
                        WalkInBanner(model: model)
                        ledger
                        ExposureHistorySection(store: model.exposureHistory)
                    }
                    Button { showHow = true } label: { Text("How it works and what's shared") }
                        .buttonStyle(QuietLinkStyle())
                        .accessibilityHint("Opens a short explanation")
                }
                .padding(.horizontal, Space.m)
                .padding(.bottom, Space.l)
            }
            // Room to scroll the last line fully clear of the floating tab bar.
            .contentMargins(.bottom, Space.xl, for: .scrollContent)
            .background(Theme.paper)
            .navigationTitle("Today")
            .animation(reduceMotion ? nil : .default, value: level)
            .sheet(isPresented: $showHow) { HowItWorksSheet() }
            .sheet(item: $report) { ReportSheet(kind: $0, model: model, store: store) }
            .onAppear(perform: checkBackground)
            .onChange(of: scenePhase) { _, p in if p == .active { checkBackground() } }
            .sheet(isPresented: $showCalc) { CalculationSheet(minutes: exposure.minutes, dose: exposure.dose, p: exposure.probability) }
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
            return ("All clear", "Nobody near you has reported symptoms or a positive test.", Theme.sage.opacity(0.45))
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
            RiskCardView(p: exposure.probability) { showCalc = true }
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
        return LedgerLine(label: "Phones nearby with the app") {
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
            // Core's advice says "report it in FlUni"; in SF the name reads as "FIUni", so the step says "the app".
            Text(text.replacingOccurrences(of: "FlUni", with: "the app")).font(.fluni(.reading)).fixedSize(horizontal: false, vertical: true)
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
                VStack(alignment: .leading, spacing: Space.m) {
                    block("How it works",
                          "Your phone and other phones running the app notice each other over Bluetooth, and with precise distance sensing on newer iPhones. Together they estimate whether you're within 6 feet. If someone with symptoms or who tested positive is close for about 15 minutes in total, you get a heads-up with advice.")
                    HandRule()
                    block("What your phone shares",
                          "Only a 3-level status (healthy, possibly sick or contagious) and a random ID that changes every 15 minutes. No name, no phone number, no account.")
                    HandRule()
                    block("What it doesn't share",
                          "Your location is never sent to other people or to a server. Matching happens on your phone, and the map shows building totals, not people.")
                    HandRule()
                    block("Good to know",
                          "It works best while the app is open, and keeps checking over Bluetooth in the background, less often. It's a nudge, not a diagnosis. If you feel unwell or are worried, get tested and follow campus health guidance.")
                }
                .padding(.horizontal, Space.m).padding(.vertical, Space.l)
            }
            .background(Theme.paper)
            .navigationTitle("How this works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private func block(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(.fluni(.section)).accessibilityAddTraits(.isHeader)
            Text(body).font(.fluni(.reading)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.ink)
    }
}

/// Shows the real numbers behind the risk estimate.
struct CalculationSheet: View {
    let minutes: Double
    let dose: Double
    let p: Double
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PSickStore.shared

    var body: some View {
        let m = String(format: "%.1f", minutes)
        let d = String(format: "%.3f", dose)
        let pos = Int((RiskEstimate.posTest * 100).rounded()), sym = Int((RiskEstimate.selfReport * 100).rounded())
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    block("Close contact",
                          "Minutes within 6 ft of someone. They count in full if the person tested positive and half if they have symptoms. At \(Int(ExposureTracker.closeContactMinutes)) of these in a day, you get a close-contact alert.",
                          "You: \(m) of \(Int(ExposureTracker.closeContactMinutes))")
                    block("What adds to your risk",
                          "Time near each person, how close you were (closer counts much more), the room air you shared, and whether they reported symptoms or a positive test. Together these make your exposure dose. Phones up to about 10 m away (Bluetooth range) count.",
                          "Your exposure dose: \(d)")
                    block("The estimate",
                          "Each person's dose becomes a chance they passed flu on to you. Someone who reported a positive test counts at \(pos)%, someone with symptoms at \(sym)%. Those chances are added on top of a \(Int((RiskEstimate.prior * 100).rounded()))% everyday baseline. It's the same exposure formula as the campus model.",
                          "This phone's estimate: \(RiskEstimate.percentText(p))")
                    block("What counts",
                          "Only the last 24 hours. GPS alone doesn't count, because it's too coarse to tell 3 feet from 30. Bluetooth and precise distance sensing do.", nil)
                    block("Campus model vs this phone",
                          "The campus model is the official number, worked out from everyone's contacts, reports and tests, including second-hand risk (being near someone who was near someone sick) and the actual rooms. This phone's estimate uses only what this phone detected in the last 24 hours, assumes a standard classroom-sized room and an average day of illness, so the two can differ.",
                          store.campusP.map { "Campus model: \(RiskEstimate.percentText($0)) \u{00B7} This phone's estimate: \(RiskEstimate.percentText(p))" })
                    Text("This is an estimate to help you decide what to do. It isn't a diagnosis.")
                        .font(.fluni(.fine)).foregroundStyle(Theme.ink2)
                }
                .padding(.horizontal, Space.m).padding(.vertical, Space.l)
            }
            .background(Theme.paper)
            .navigationTitle("How is this calculated?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func block(_ title: String, _ body: String, _ numbers: String?) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(.fluni(.section)).accessibilityAddTraits(.isHeader)
            Text(body).font(.fluni(.reading)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            if let numbers {
                // Your own numbers, set apart as a quiet panel so they're easy to find again.
                Text(numbers).font(.fluni(.strong)).monospacedDigit().panel()
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
