import CoreBluetooth
import SwiftUI

extension ProximityModel {
    /// The exposure Today shows: the live tracker (the preview hook's seeded one in DEBUG screenshots).
    var shownExposure: ExposureTracker {
        #if DEBUG
        if let e = PreviewHook.exposure { return e }
        #endif
        return exposure
    }
    /// The live risk estimate (ProximityModel.liveRisk, recomputed every tick). Every risk number on screen
    /// reads this, through RiskEstimate.liveText; never a cached or campus value.
    var shownRisk: Double {
        #if DEBUG
        if let e = PreviewHook.exposure { return e.probability }
        #endif
        return liveRisk
    }
    var shownPeerCount: Int {
        #if DEBUG
        if let n = PreviewHook.peerCount { return n }
        #endif
        return peers.count
    }
}

/// Today: Lisa's tissue says how things are, then your day as a line of places, newest first. "Now" at the
/// top with the one action ("I don't feel well"); earlier places below, with heads-ups and close contacts as
/// points on the side line. A close contact opens in place with what happened and the four steps.
/// While you're sick, Today becomes your stay-home track instead (StayHomeView).
struct TodayView: View {
    /// Not observed: it republishes every tick. The slow parts come through `feed`; only the live risk views watch it.
    let model: ProximityModel
    @ObservedObject var store: SelfReportStore
    @ObservedObject private var feed = ModelFeed.shared
    @ObservedObject private var history: ExposureHistoryStore
    @ObservedObject private var places = PlaceLogStore.shared
    @ObservedObject private var router = AppRouter.shared
    @State private var showHow = false
    @State private var showCalc = false
    @State private var report: ReportStart?
    /// The close contact opened in place (by its start time); nil = all folded.
    @State private var openMoment: Date?
    /// The close contact already acknowledged with "Got it", so it doesn't reopen by itself.
    @AppStorage("closeContactSeen") private var seenMoment: Double = 0
    /// One line when iOS settings would stop alerts while FlUni is closed.
    @State private var backgroundHint: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    init(model: ProximityModel, store: SelfReportStore) {
        self.model = model
        self.store = store
        _history = ObservedObject(wrappedValue: model.exposureHistory)
    }

    private var level: AlertLevel { feed.level }
    private var isSick: Bool { feed.myRisk != .none }

    private var mood: TissueMood {
        if isSick { return .sick }
        if feed.isPaused { return .paused }
        switch level {
        case .none: return .calm
        case .nearby: return .headsUp
        case .closeContact: return .alert
        }
    }

    private var moments: [TimelineMoment] {
        let h = history
        return DayTimeline.moments(h.episodes + (h.ongoing.map { [$0] } ?? []), visits: places.log.visits, now: Date())
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.l) {
                        header
                        notices
                        TissueNarrator(mood: mood, stamp: isSick && store.record.positiveKind == nil && !store.record.symptoms.isEmpty)
                        if isSick {
                            StayHomeView(model: model, store: store) { report = $0 }
                        } else {
                            timeline(proxy: proxy)
                            footer
                        }
                    }
                    .padding(.horizontal, Space.m)
                    .padding(.top, Space.xs)
                    .padding(.bottom, Space.l)
                }
                .onChange(of: router.closeContactRequest) { _, _ in openLatestCloseContact(proxy) }
                #if DEBUG
                .task {
                    guard let a = PreviewHook.scrollAnchor else { return }
                    try? await Task.sleep(for: .milliseconds(900))
                    proxy.scrollTo(a, anchor: .top)
                }
                #endif
                .onAppear { if router.closeContactRequest > 0 { openLatestCloseContact(proxy) } }
            }
            .contentMargins(.bottom, Space.xl, for: .scrollContent)
            .background(Theme.paper)
            .toolbar(.hidden, for: .navigationBar)
            .navigationTitle("Today")
            .animation(FlMotion.standard(reduceMotion), value: level)
            .animation(FlMotion.standard(reduceMotion), value: openMoment)
            .sheet(isPresented: $showHow) { HowItWorksSheet() }
            .sheet(item: $report) { ReportFlow(start: $0, model: model, store: store) }
            .sheet(isPresented: $showCalc) { CalculationSheet(model: model) }
            .onAppear(perform: checkBackground)
            .onChange(of: scenePhase) { _, p in if p == .active { checkBackground() } }
            .onReceive(AppRouter.shared.dismissSheets) { showHow = false; showCalc = false; report = nil }
            .task { places.attach(model) }
            .onChange(of: router.reportRequest) { _, _ in report = .choose }
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

    /// Open the newest close contact in place and bring it into view.
    private func openLatestCloseContact(_ proxy: ScrollViewProxy) {
        guard let m = moments.last(where: { $0.kind == .closeContact }) else { return }
        openMoment = m.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo("moment-\(m.id.timeIntervalSince1970)", anchor: .top) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Wordmark(size: 32)
            Spacer(minLength: Space.s)
            Text(Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.fluni(.note)).foregroundStyle(Theme.ink2)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .padding(.top, Space.xs)
    }

    /// Things about the app, above the tissue. Each shows nothing when it doesn't apply.
    @ViewBuilder private var notices: some View {
        let any = backgroundHint != nil || feed.unusualSignals || SimClock.shared.demoActive
        if any {
            VStack(alignment: .leading, spacing: Space.s) {
                DemoTimeBadge()
                if let backgroundHint {
                    Text(brand: backgroundHint, style: .footnote).font(.fluni(.fine)).foregroundStyle(Theme.ink).panel()
                }
                if feed.unusualSignals {
                    Text("Unusual Bluetooth signals nearby; alerts paused for a few minutes")
                        .font(.fluni(.fine)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .panel()
                        .accessibilityIdentifier("banner.unusualSignals")
                }
            }
        }
    }

    // MARK: Timeline

    private func timeline(proxy: ScrollViewProxy) -> some View {
        let moments = self.moments
        let current = places.log.current
        let entries = DayTimeline.entries(visits: places.log.visits, current: current, moments: moments, now: Date())
        let ccOpen = level == .closeContact && moments.contains { $0.kind == .closeContact && (openMoment == $0.id || autoOpen($0)) }
        let nowTone: DayTimeline.Tone = feed.isPaused ? .quiet : level == .closeContact ? .closeContact : level == .nearby ? .headsUp
            : current.map { DayTimeline.tone($0, moments: moments) } ?? (feed.peerCount > 0 ? .phones : .quiet)
        return VStack(alignment: .leading, spacing: 0) {
            RailRow(label: "Now", time: TimelineFormat.time(Date()), node: .now,
                    line: entries.isEmpty ? .none : .tone(nowTone), nodeY: 22) {
                NowBlock(model: model, place: current, onReport: { report = .choose }, onRisk: { showCalc = true },
                         hidesReport: ccOpen)
            }
            Color.clear.frame(height: 0).id("earlier")
            ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                let below: RailLine = {
                    guard i + 1 < entries.count else { return .none }
                    switch e {
                    case .place(_, let t): return .tone(t)
                    case .moment(let m): return .tone(m.kind == .closeContact ? .closeContact : .headsUp)
                    }
                }()
                switch e {
                case .place(let v, let tone):
                    RailRow(time: TimelineFormat.time(v.start), node: .place, line: below) { PlaceRow(visit: v, tone: tone) }
                case .moment(let m):
                    RailRow(time: TimelineFormat.time(m.episode.start), node: .moment(m.kind), line: below) {
                        if m.kind == .closeContact {
                            CloseContactMoment(moment: m, model: model, isOpen: openMoment == m.id || autoOpen(m),
                                               toggle: { openMoment = (openMoment == m.id || autoOpen(m)) ? nil : m.id },
                                               gotIt: { seenMoment = m.id.timeIntervalSince1970; openMoment = nil },
                                               report: { report = .choose }, how: { showCalc = true })
                        } else {
                            HeadsUpRow(moment: m)
                        }
                    }
                    .id("moment-\(m.id.timeIntervalSince1970)")
                }
            }
            if entries.isEmpty && current == nil {
                Text("Places you spend time in today show up here, newest first. Only building names, kept on this phone for 24 hours.")
                    .font(.fluni(.fine)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 0)
                    .padding(.top, Space.xs)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The newest close contact opens by itself while it's live and not yet acknowledged.
    private func autoOpen(_ m: TimelineMoment) -> Bool {
        level == .closeContact && openMoment == nil && seenMoment != m.id.timeIntervalSince1970
            && moments.last(where: { $0.kind == .closeContact })?.id == m.id
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Color.clear.frame(height: 0).id("footer")
            HandRule()
            RailLegend()
            Text("Places here are building names, kept on this phone for 24 hours. Your precise location never leaves this phone and is never seen by anyone.")
                .font(.fluni(.fine)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("today.privacy")
            Button { showHow = true } label: { Text("How it works and what's shared") }
                .buttonStyle(QuietLinkStyle())
                .accessibilityHint("Opens a short explanation")
        }
    }
}

// MARK: Now

/// The top of the line: where you are, the status in words, the numbers behind it, and the one action.
private struct NowBlock: View {
    let model: ProximityModel
    @ObservedObject private var feed = ModelFeed.shared
    let place: PlaceVisit?
    let onReport: () -> Void
    let onRisk: () -> Void
    var hidesReport = false

    private var level: AlertLevel { feed.level }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(place?.name ?? "On campus").font(.fluni(.display)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel("Now, \(place?.name ?? "on campus")")
                    .accessibilityIdentifier("today.now")
                status
            }
            if feed.isPaused {
                paused
            } else {
                if level == .nearby { headsUp }
                if level != .closeContact {
                    Text(detail).font(.fluni(.note)).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                WalkInBanner(model: model)
                MetricsStrip(minutes: feed.minutes, model: model, onRisk: onRisk)
            }
            if !hidesReport || feed.isPaused { reportButton }
        }
        .accessibilityElement(children: .contain)
    }

    private var statusWord: (String, Color, Color) {
        if feed.isPaused { return ("Paused", Theme.surface2, Theme.ink) }
        switch level {
        case .none: return ("All clear", Theme.sage, Theme.ink)
        case .nearby: return ("Heads-up", Theme.sun, Theme.ink)
        case .closeContact: return ("Close contact", Theme.fire, Theme.fireInk)
        }
    }

    private var status: some View {
        let (word, dot, ink) = statusWord
        return HStack(spacing: Space.xs) {
            Circle().fill(dot).frame(width: 13, height: 13).overlay(Circle().stroke(Theme.ink2, lineWidth: 1))
                .accessibilityHidden(true)
            Text(word).font(.fluni(.section)).foregroundStyle(ink)
                .accessibilityIdentifier("today.status")
        }
    }

    private var detail: String {
        let n = feed.peerCount
        let since = place.map { "Here since \(TimelineFormat.clock($0.start)), near " } ?? "Near "
        switch level {
        case .none:
            return n == 0 ? (place.map { "Here since \(TimelineFormat.clock($0.start)). No other FlUni phones nearby right now." }
                             ?? "No other FlUni phones nearby right now.")
                : "\(since)\(n) other \(n == 1 ? "phone" : "phones"). None of them sick."
        case .nearby:
            return "They're probably within 6 ft of you right now. About 15 minutes this close makes a close contact."
        case .closeContact:
            return "You've spent about 15 minutes within 6 ft of someone who may be sick."
        }
    }

    /// The heads-up state, drawn: the brief's line and its two pieces of advice, word for word.
    private var headsUp: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(Advice.title(.nearby)).font(.fluni(.lead)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("today.headsUp")
            ForEach(Advice.body(.nearby), id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Circle().fill(Theme.ink).frame(width: 6, height: 6).accessibilityHidden(true)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    Text(line).font(.fluni(.reading)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sun.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.radius))
        .accessibilityElement(children: .combine)
    }

    private var paused: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let p = feed.pauseState {
                Text("Detection is paused \(PauseSchedule.describe(p, calendar: .current, now: Date())). Your status isn't shared and close-contact time isn't counted.")
                    .font(.fluni(.note)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("banner.paused")
            }
            Button("Resume detection") { model.resume() }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("banner.resume")
                .accessibilityHint("Turns detection back on")
        }
    }

    @ViewBuilder private var reportButton: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if feed.isPaused {
                Button("I don't feel well", action: onReport).buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("today.reportSymptoms")
            } else {
                Button("I don't feel well", action: onReport).buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("today.reportSymptoms")
                    .accessibilityHint("Opens a short report. Takes about 20 seconds.")
                Text("Takes about 20 seconds. Nobody sees your symptoms.")
                    .font(.fluni(.fine)).foregroundStyle(Theme.ink2)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// "0 / 15 min close to someone sick" with fifteen ticks, and the live risk estimate beside it. Tapping the
/// estimate opens how it's worked out. Side by side, or stacked when large text needs the width.
private struct MetricsStrip: View {
    /// Whole close-contact minutes (ModelFeed): changes once a minute at most.
    let minutes: Int
    let model: ProximityModel
    let onRisk: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize >= .xxxLarge {
                VStack(alignment: .leading, spacing: Space.m) { minutesBlock; LiveRiskBlock(model: model, onRisk: onRisk) }
            } else {
                HStack(alignment: .top, spacing: Space.s) {
                    minutesBlock.frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(Theme.hairline).frame(width: 1).accessibilityHidden(true)
                    LiveRiskBlock(model: model, onRisk: onRisk).frame(width: 124, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Space.s)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var minutesBlock: some View {
        let goal = Int(ExposureTracker.closeContactMinutes)
        let filled = min(minutes, goal)
        let reached = minutes >= goal
        return VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(minutes)").font(.fluni(.figure)).foregroundStyle(reached ? Theme.fireInk : Theme.ink)
                Text("/ \(goal) min").font(.fluni(.time)).foregroundStyle(Theme.ink2)
            }
            HStack(spacing: 3) {
                ForEach(0..<goal, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i < filled ? (reached ? Theme.fireInk : Theme.ink2) : Theme.surface2)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.ink2.opacity(i < filled ? 0 : 0.35), lineWidth: 1))
                        .frame(height: 10)
                }
            }
            .frame(maxWidth: 210)
            .accessibilityHidden(true)
            Text("close to someone sick").font(.fluni(.fine)).foregroundStyle(Theme.ink2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Close-contact time")
        .accessibilityValue("\(minutes) of \(goal) minutes")
    }
}

/// The live risk estimate: the only part of Today that redraws every tick. Tapping it opens how it's worked out.
private struct LiveRiskBlock: View {
    @ObservedObject var model: ProximityModel
    let onRisk: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let risk = model.shownRisk
        let band = RiskEstimate.band(risk)
        let word = band == .low ? "low" : band == .elevated ? "elevated" : "high"
        Button(action: onRisk) {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(RiskEstimate.liveText(risk)).font(.fluni(.figure)).foregroundStyle(band == .low ? Theme.ink : Theme.fireInk)
                        .contentTransition(reduceMotion ? .identity : .numericText(value: risk))
                        .animation(FlMotion.number(reduceMotion), value: risk)
                    Text(word).font(.fluni(.note).weight(.semibold)).foregroundStyle(Theme.ink)
                }
                Text("risk estimate,\nlast 24 h").font(.fluni(.fine)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Why this number").font(.fluni(.fine).weight(.semibold)).foregroundStyle(Theme.ink2)
                    .underline(true, color: Theme.ink2.opacity(0.5))
            }
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your risk estimate, \(RiskEstimate.liveText(risk)), \(word)")
        .accessibilityHint("Opens how this estimate is worked out")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("risk.card")
    }
}

/// The close-contact moment's risk line, live: "Your risk estimate went from 2.0% to 8.0%. That is still low."
private struct LiveRiskLine: View {
    @ObservedObject var model: ProximityModel
    var body: some View {
        Text(RiskEstimate.changeLine(to: model.shownRisk)).font(.fluni(.note)).foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("closeContact.risk")
    }
}

// MARK: Earlier rows

private struct PlaceRow: View {
    let visit: PlaceVisit
    let tone: DayTimeline.Tone

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(visit.name).font(.fluni(.section)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.fluni(.note)).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let length = visit.isPassingThrough ? "Walked through" : TimelineFormat.duration(visit.minutes)
        let near = TimelineFormat.phones(visit.maxPhones)
        switch tone {
        case .closeContact: return "\(length), \(near), close contact here"
        case .headsUp: return "\(length), \(near), one heads-up"
        case .phones: return "\(length), \(near), all healthy"
        case .quiet: return "\(length), \(near)"
        }
    }
}

private struct HeadsUpRow: View {
    let moment: TimelineMoment

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(Advice.title(.nearby)).font(.fluni(.strong)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.fluni(.note)).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Heads-up. \(Advice.title(.nearby)). \(detail)")
    }

    private var detail: String {
        let m = TimelineFormat.duration(moment.episode.durationMinutes)
        return "Heads-up for about \(m)" + (moment.placeName.map { " at \($0)." } ?? ".")
    }
}

/// The close contact as a moment on the line (B-2): folded to one line once seen, or open in place with the
/// reason, the four steps word for word, the risk in context, and "Got it" / "I don't feel well".
private struct CloseContactMoment: View {
    let moment: TimelineMoment
    let model: ProximityModel
    let isOpen: Bool
    let toggle: () -> Void
    let gotIt: () -> Void
    let report: () -> Void
    let how: () -> Void

    private var e: ExposureEpisode { moment.episode }

    var body: some View {
        if isOpen { open } else { folded }
    }

    private var folded: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(Advice.title(.closeContact)).font(.fluni(.strong)).foregroundStyle(Theme.fireInk)
                    .multilineTextAlignment(.leading)
                Text("About \(TimelineFormat.duration(e.durationMinutes))\(moment.placeName.map { " at \($0)" } ?? ""). Show the steps again.")
                    .font(.fluni(.note)).foregroundStyle(Theme.ink2).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("today.closeContact")
    }

    private var reason: String {
        let who = e.maxRisk == .contagious ? "a phone whose owner reported a positive test" : "a phone whose owner reported symptoms"
        let place = moment.placeName.map { ", at \($0)" } ?? ""
        return "From \(TimelineFormat.clock(e.start)) to \(TimelineFormat.clock(e.end)) you were within 6 ft of \(who)\(place). About \(TimelineFormat.duration(e.durationMinutes))."
    }

    private var open: some View {
        let steps = Array(Advice.body(.closeContact).dropFirst())
        return VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(Advice.title(.closeContact)).font(.fluni(.lead)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(reason).font(.fluni(.reading)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Rectangle().fill(Theme.ink.opacity(0.15)).frame(height: 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, line in
                    Step(number: i + 1, text: line, strong: i == 0)
                }
            }
            LiveRiskLine(model: model)
            VStack(spacing: Space.s) { got; feel }
            Button("How we worked this out", action: how).buttonStyle(QuietLinkStyle())
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A light fire wash with a fire-ink edge (B-2): ink text on it is 12:1, fire-ink 7:1.
        .background(Theme.fire.opacity(0.16), in: RoundedRectangle(cornerRadius: 18))
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.fireInk, lineWidth: Theme.stroke))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.closeContact")
    }

    private var got: some View {
        Button("Got it", action: gotIt).buttonStyle(PrimaryButtonStyle())
            .accessibilityHint("Folds this into your timeline")
            .accessibilityIdentifier("closeContact.gotIt")
    }
    private var feel: some View {
        Button("I don't feel well", action: report).buttonStyle(SecondaryButtonStyle())
    }
}

/// A numbered step. The number sits in a drawn-feeling ring: order matters here (leave first, then wash).
/// "FlUni" in the step is set in the wordmark serif, so it never reads "FIUni".
struct Step: View {
    let number: Int
    let text: String
    var strong = false
    @ScaledMetric(relativeTo: .body) private var ring: CGFloat = 26

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text("\(number)")
                .font(Face.serif(15, .subheadline)).monospacedDigit()
                .foregroundStyle(strong ? Theme.paper : Theme.ink)
                .frame(width: ring, height: ring)
                .background(Circle().fill(strong ? Theme.ink : Color.clear))
                .overlay(Circle().stroke(Theme.ink, lineWidth: Theme.stroke))
                .accessibilityHidden(true)
            Text(brand: text).font(strong ? .fluni(.strong) : .fluni(.reading)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(text)")
    }
}

// MARK: Sheets

struct HowItWorksSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    block("How it works",
                          "Your phone and other phones running FlUni notice each other over Bluetooth, and with precise distance sensing on newer iPhones. Together they estimate whether you're within 6 feet. If someone with symptoms or who tested positive is close for about 15 minutes in total, you get a heads-up with advice.")
                    HandRule()
                    block("What your phone shares",
                          "Only a 3-level status (healthy, possibly sick or contagious) and a random ID that changes every 15 minutes. No name, no phone number, no account.")
                    HandRule()
                    block("What stays on your phone",
                          "Your precise location never leaves this phone and is never seen by anyone. Today's timeline keeps building names and times on this phone for 24 hours, then forgets them. Matching happens on your phone, and the map shows building totals, not people.")
                    HandRule()
                    block("Good to know",
                          "It works best while FlUni is open, and keeps checking over Bluetooth in the background, less often. It's a nudge, not a diagnosis. If you feel unwell or are worried, get tested and follow campus health guidance.")
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
            Text(brand: body).font(.fluni(.reading)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.ink)
    }
}

/// The real numbers behind the risk estimate, live while open.
struct CalculationSheet: View {
    @ObservedObject var model: ProximityModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PSickStore.shared

    var body: some View {
        let e = model.shownExposure
        let p = model.shownRisk
        let m = String(format: "%.1f", e.minutes)
        let d = String(format: "%.3f", e.dose)
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
                          "This phone's estimate: \(RiskEstimate.liveText(p))")
                    block("What counts",
                          "Only the last 24 hours. GPS alone doesn't count, because it's too coarse to tell 3 feet from 30. Bluetooth and precise distance sensing do.", nil)
                    block("Campus model and this phone",
                          "The campus model is worked out from everyone's contacts, reports and tests, including second-hand risk and the actual rooms. This phone's estimate uses only what this phone detected in the last 24 hours, so the two can differ.",
                          store.campusP.map { "For comparison, campus model: \(RiskEstimate.percentText($0))" })
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
                Text(numbers).font(.fluni(.strong)).monospacedDigit().panel()
            }
        }
        .foregroundStyle(Theme.ink)
    }
}
