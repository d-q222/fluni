import CoreBluetooth
import SwiftUI

/// The student's home screen (mockup v4, owner-approved 2026-10-18): Lisa's tissue saying one short line, a card with
/// only the live risk estimate and "I don't feel well" (a heads-up or close-contact strip above the number while
/// one is on), then the day so far. Someone who reported being sick sees the stay-home card and their recovery
/// instead, never "All clear" or a risk percentage. No IDs, no per-person distances (those live in the Developer
/// screen).
struct TodayView: View {
    /// Lisa's logo top left. Off for now (owner, v4); turning it on is this one line.
    static let showLogo = false

    @ObservedObject var model: ProximityModel
    @ObservedObject var store: SelfReportStore
    @State private var showHow = false
    @State private var showCalc = false
    @State private var showReport = false
    /// One line when iOS settings would stop alerts while FlUni is closed.
    @State private var backgroundHint: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    private var level: AlertLevel { model.exposure.level }
    private var sick: Bool { model.selfStatusOverridesRisk }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    banners
                    TissueHeader(line: line, pose: sick ? "PoseSick" : level == .none ? "PoseFine" : "PoseAlert", showLogo: Self.showLogo)
                    if sick {
                        // Someone who reported being sick never sees "All clear" or a risk percentage.
                        AtHomeCard(model: model, store: store)
                        RecoverySection(store: store, risk: model.myRisk)
                            .onAppear { store.reconcile(with: model) }
                    } else {
                        RiskHero(p: model.ownScore, level: level) { showReport = true }  // ownScore = liveRisk unless self-reported (then sick mode)
                        howLink
                        DayTimelineSection(model: model, history: model.exposureHistory)
                    }
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
            .tissueTabBarScrollRoom(alert: true)
            .background(Theme.paper)
            // Paper behind the status bar, so the card doesn't scroll through the clock (there is no navigation bar).
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 0).background(Theme.paper) }
            .navigationTitle("Today")
            .toolbar(.hidden, for: .navigationBar)  // the tissue's line is the header (mockup v4)
            .animation(reduceMotion ? nil : .default, value: level)
            .sheet(isPresented: $showHow) { HowItWorksSheet() }
            .sheet(isPresented: $showCalc) { CalculationSheet(minutes: model.exposure.minutes, dose: model.exposure.dose, p: model.liveRisk) }
            .sheet(isPresented: $showReport) { ReportSheet(kind: .symptoms, model: model, store: store) }
            .onAppear {
                checkBackground()
                PlaceLogStore.shared.attach(model)
                #if DEBUG
                PlaceLogStore.shared.startDemoDayFromLaunchArguments()  // -demoDay YES: a made-up day for the timeline
                #endif
            }
            .onChange(of: scenePhase) { _, p in if p == .active { checkBackground() } }
            .onReceive(AppRouter.shared.dismissSheets) { showHow = false; showCalc = false; showReport = false }
        }
    }

    /// The tissue's one line: calm, specific, never alarmist.
    private var line: String {
        if sick { return "Rest up." }
        if model.isPaused { return "Taking a break." }
        switch level {
        case .none: return "All calm nearby."
        case .nearby: return "I'm keeping watch."
        case .closeContact: return "What to do is below."
        }
    }

    /// Notes that only show when they apply (demo clock, pause, iOS settings, a busy building, odd signals, the
    /// Always-location ask).
    private var banners: some View {
        VStack(alignment: .leading, spacing: 12) {
            DemoTimeBadge()
            PausedBanner(model: model)
            if let backgroundHint {
                Label(backgroundHint, systemImage: "info.circle")
                    .font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            WalkInBanner(model: model)
            UnusualSignalsBanner(model: model)
            AlwaysLocationCard()  // step two of the location ask (BackgroundLocation.offersAlways); flu-offdetect
        }
    }

    private var howLink: some View {
        Button { showCalc = true } label: {
            HStack(spacing: 8) {
                if !typeSize.isAccessibilitySize {  // the mark only gets in the way at the largest sizes
                    Text("f(x)").font(.custom("Georgia-BoldItalic", size: 14, relativeTo: .footnote)).accessibilityHidden(true)
                }
                Text("How your risk estimate is worked out").font(.nunito(14, relativeTo: .footnote, weight: .semibold))
            }
            .underline()
            .foregroundStyle(Theme.ink2)
            .frame(minHeight: 44)
            .padding(.horizontal, 6)
        }
        .padding(.top, 2)
        .accessibilityHint("Opens the numbers behind this estimate")
        .accessibilityIdentifier("risk.how")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock").font(.footnote.weight(.semibold)).accessibilityHidden(true)
                Text("Your precise location never leaves this phone and is never seen by anyone.")
            }
            .font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
            .padding(.top, 14)
            .overlay(alignment: .top) { DashedRule() }
            Button { showHow = true } label: {
                Label("How FlUni works and what it shares", systemImage: "info.circle")
                    .font(.fluni(.footnote, weight: .semibold)).underline()
                    .foregroundStyle(Theme.ink2)
                    .frame(minHeight: 44)
            }
            .accessibilityHint("Opens a short explanation")
        }
        .padding(.horizontal, 4)
        .padding(.top, 26)
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
}

// MARK: Header

/// Lisa's tissue, small, top right, saying one short line in a speech bubble. At accessibility text sizes the
/// tissue keeps quiet (the line would push the card off screen); VoiceOver still reads it.
struct TissueHeader: View {
    let line: String
    /// Lisa's companion pose (PoseFine, PoseAlert or PoseSick), a drawing that carries its own pose, so no tilt.
    let pose: String
    var showLogo = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            if showLogo {
                Image("Logo").resizable().scaledToFit().frame(height: 54).accessibilityLabel("FlUni")
            }
            Spacer(minLength: 8)
            if !typeSize.isAccessibilitySize {
                SpeechBubble(text: line).padding(.trailing, 3)
            }
            Image(pose).resizable().scaledToFit()
                .frame(maxWidth: pose == "PoseSick" ? 76 : 72, maxHeight: pose == "PoseAlert" ? 56 : pose == "PoseSick" ? 46 : 52)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 46)
        .padding(.bottom, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line)
        .accessibilityIdentifier("today.home")
    }
}

/// Lisa's hand-drawn speech bubble (bubble.png, 1987 x 434). The left cap and the right end with its tail keep their
/// shape; only the plain middle stretches with the text. The art is 34 pt tall, so 1 pt = 434/34 px.
struct SpeechBubble: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    private static let px: CGFloat = 434 / 34
    private static let left: CGFloat = 22, right: CGFloat = 80   // the caps, in points (280 and 1012 px of the art)

    private var art: Image {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        guard let ui = UIImage(named: "SpeechBubble", in: nil, compatibleWith: traits), let cg = ui.cgImage else { return Image("SpeechBubble") }
        return Image(uiImage: UIImage(cgImage: cg, scale: Self.px, orientation: .up))
    }

    var body: some View {
        Text(text)
            .font(.nunito(14, relativeTo: .subheadline, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .padding(.leading, Self.left + 7).padding(.trailing, Self.right)
            .padding(.top, 7).padding(.bottom, 10)
            .frame(minHeight: 34)
            .background(art.resizable(capInsets: EdgeInsets(top: 0, leading: 280 / Self.px, bottom: 0, trailing: 1012 / Self.px)))
    }
}

/// Lisa's two-frame scene (760 x 594) at the top of a card: the frames swap like a flipbook, about a second a cycle.
/// Reduce Motion holds frame 1. Decorative, so hidden from VoiceOver.
struct SceneFlip: View {
    let name: String   // SceneFine or SceneSick, + 1 / 2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 0.52)) { ctx in
            let second = !reduceMotion && Int(ctx.date.timeIntervalSinceReferenceDate / 0.52) % 2 == 1
            Image("\(name)\(second ? 2 : 1)").resizable().aspectRatio(760.0 / 594.0, contentMode: .fit)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.ink, lineWidth: 1.5))
        .padding(.top, 2).padding(.bottom, 8)
        .accessibilityHidden(true)
    }
}

// MARK: The risk card

/// The top card: the phone's live estimate as the headline with a tiny band indicator, and "I don't feel well".
/// A heads-up or close contact adds a compact strip above the number. The campus-model number (Debug "Play as"
/// persona only) is an extra line, never in the live number's place.
struct RiskHero: View {
    /// This phone's live estimate (ProximityModel.liveRisk); it changes every tick near someone sick.
    let p: Double
    let level: AlertLevel
    let onUnwell: () -> Void
    @ObservedObject private var store = PSickStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if level != .none { AlertStrip(level: level).padding(.bottom, 6) } else { SceneFlip(name: "SceneFine") }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 14) { number; indicator }
                VStack(alignment: .leading, spacing: 4) { number; indicator }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Your risk estimate, \(RiskEstimate.liveText(p)), \(Self.bandWord(p))\(rose ? ", up from \(RiskEstimate.liveText(RiskEstimate.prior))" : "")")
            .accessibilityIdentifier("risk.card")
            if let official = store.campusP {
                Text("Campus model: \(RiskEstimate.percentText(official))")
                    .font(.fluni(.subheadline, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.ink2)
            }
            Button(action: onUnwell) {
                Text("I don't feel well").font(.fredoka(18, relativeTo: .headline))
            }
            .buttonStyle(ChunkyButtonStyle())
            .padding(.top, 10)
            .accessibilityHint("Report symptoms")
            .accessibilityIdentifier("today.unwell")
        }
        .foregroundStyle(Theme.ink)
        .card()
        .task { if store.feed == nil, !store.agent.isEmpty { await store.reload() } }
    }

    private var rose: Bool { p > RiskEstimate.prior && RiskEstimate.liveText(p) != RiskEstimate.liveText(RiskEstimate.prior) }

    private var number: some View {
        Text(RiskEstimate.liveText(p))
            .font(.fredoka(76, relativeTo: .largeTitle)).tracking(-2).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.6)
            .padding(.vertical, -6)  // the font's line box is taller than its figures (the mockup sets line-height 1)
            .contentTransition(reduceMotion ? .identity : .numericText(value: p))
            .animation(reduceMotion ? nil : .smooth, value: p)
    }

    private var indicator: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle().fill(Self.bandColor(p)).overlay(Circle().strokeBorder(Theme.ink, lineWidth: 1.5))
                .frame(width: 10, height: 10)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
            Text(Self.bandWord(p)).font(.nunito(17, relativeTo: .body, weight: .semibold))
            if rose {
                Text("up from \(RiskEstimate.liveText(RiskEstimate.prior))")
                    .font(.nunito(15, relativeTo: .subheadline)).foregroundStyle(Theme.ink2)
            }
        }
    }

    /// Same tiers as the map: low = sage, elevated = sun, high = fire.
    static func bandColor(_ p: Double) -> Color {
        switch RiskEstimate.band(p) {
        case .low: return Theme.sage
        case .elevated: return Theme.sun
        case .high: return Theme.fire
        }
    }

    static func bandWord(_ p: Double) -> String {
        switch RiskEstimate.band(p) {
        case .low: return "Low"
        case .elevated: return "Elevated"
        case .high: return "High"
        }
    }
}

/// The heads-up / close-contact strip inside the risk card: tinted, an (!) icon, the alert's title and its first step.
/// Ink only on the peach tints (as on Lisa's peach box).
struct AlertStrip: View {
    let level: AlertLevel

    var body: some View {
        let close = level == .closeContact
        // Advice.body(.closeContact) starts with the "about 15 minutes" sentence; its first step is the next line.
        let step = close ? Advice.body(level).dropFirst().first : Advice.body(level).first
        HStack(alignment: .top, spacing: 10) {
            Image("AlertBang").resizable().scaledToFit().frame(width: 26, height: 26).padding(.top, -1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Advice.title(level)).font(.fredoka(16, relativeTo: .headline))
                if let step { Text(step).font(.nunito(14, relativeTo: .subheadline)) }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(hex: close ? 0xe6a088 : 0xecbba0), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.ink, lineWidth: 1.5))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today.alert")
    }
}

/// The (!) mark: a filled circle with an exclamation stroke.
struct AlertIcon: View {
    var size: CGFloat = 16
    var fill = Theme.ember
    var stroke = Theme.fireInk

    var body: some View {
        Canvas { ctx, s in
            let k = s.width / 16
            let circle = Path(ellipseIn: CGRect(x: k, y: k, width: 14 * k, height: 14 * k))
            ctx.fill(circle, with: .color(fill))
            ctx.stroke(circle, with: .color(stroke), lineWidth: 1.6 * k)
            var bang = Path()
            bang.move(to: CGPoint(x: 8 * k, y: 4.2 * k)); bang.addLine(to: CGPoint(x: 8 * k, y: 8.8 * k))
            bang.move(to: CGPoint(x: 8 * k, y: 11.3 * k)); bang.addLine(to: CGPoint(x: 8 * k, y: 11.5 * k))
            ctx.stroke(bang, with: .color(Theme.ink), style: StrokeStyle(lineWidth: 1.9 * k, lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A 1.5 pt dashed hairline across the full width (the mockup's dividers).
struct DashedRule: View {
    var body: some View {
        Line().stroke(Color(hex: 0xe4d8c2), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .frame(height: 1.5)
            .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in r: CGRect) -> Path { Path { $0.move(to: CGPoint(x: 0, y: r.midY)); $0.addLine(to: CGPoint(x: r.maxX, y: r.midY)) } }
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
                          "A 3-level status (healthy, possibly sick or contagious), how many days ago your symptoms or positive test began, this phone's risk estimate and a random ID that changes every 15 minutes. Other FlUni phones use them for their own estimate and never show them, but a Bluetooth scanner can read them. No name, no phone number, no account.")
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
    let p: Double
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PSickStore.shared

    var body: some View {
        let m = String(format: "%.1f", minutes)
        let d = String(format: "%.3f", dose)
        let pos = Int((RiskEstimate.posTest * 100).rounded()), sym = Int((RiskEstimate.selfReport * 100).rounded())
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    block("Close contact",
                          "Minutes within 6 ft of someone. They count in full if the person tested positive and half if they have symptoms. The minutes keep adding up and reset to zero only after 2 hours away from anyone like that. At \(Int(ExposureTracker.closeContactMinutes)) of them, FlUni tells you it's a close contact.",
                          "You: \(m) of \(Int(ExposureTracker.closeContactMinutes))")
                    block("What adds to your risk",
                          "Time near each person, how close you were (closer counts much more), the room air you shared, and whether they reported symptoms or a positive test. Together these make your exposure dose. Phones up to about 10 m away (Bluetooth range) count.",
                          "Your exposure dose: \(d)")
                    block("The estimate",
                          "Each person's dose becomes a chance they passed flu on to you. Someone who reported a positive test counts at \(pos)%, someone with symptoms at \(sym)%. Those chances are added on top of a \(Int((RiskEstimate.prior * 100).rounded()))% everyday baseline. It's the same exposure formula as the campus model.",
                          "This phone's estimate: \(RiskEstimate.liveText(p))")
                    block("What counts",
                          "Close-contact minutes run until 2 hours pass with nobody like that nearby; your exposure dose counts the last 24 hours. GPS alone doesn't count, because it's too coarse to tell 3 feet from 30. Bluetooth and precise distance sensing do.", nil)
                    block("Campus model vs this phone",
                          "The campus model is the official number, worked out from everyone's contacts, reports and tests, including second-hand risk (being near someone who was near someone sick) and the actual rooms. This phone's estimate uses only what this phone detected, assumes a standard classroom-sized room and an average day of illness, so the two can differ.",
                          store.campusP.map { "Campus model: \(RiskEstimate.percentText($0)) \u{00B7} This phone's estimate: \(RiskEstimate.liveText(p))" })
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
