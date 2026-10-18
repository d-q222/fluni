import SwiftUI

/// Me (the third tab, lettered to match Lisa's tab art): what nearby phones see about you, how to change it, your recent contacts, pause, settings and
/// deleting your data. One page, in that order: the thing this tab exists for first.
struct YouView: View {
    let model: ProximityModel
    @ObservedObject private var feed = ModelFeed.shared
    /// The app's one self-report store, shared with Today (two copies of the same file could disagree).
    @ObservedObject var store: SelfReportStore
    @State private var report: ReportStart?
    @State private var blocked: String?
    @State private var choosePause = false
    @State private var confirmDelete = false
    @State private var showHow = false
    #if DEBUG
    @State private var showDeveloper = false
    #endif

    @ScaledMetric(relativeTo: .body) private var markSize: CGFloat = 22

    private enum Choice: CaseIterable { case fine, symptoms, positive, negative }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Me").font(.fluni(.display)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("you.title")
                        Spacer()
                        Wordmark(size: 22).accessibilityHidden(true)
                    }
                    .padding(.top, Space.s)
                    if let n = store.notice {
                        Text(n).font(.fluni(.fine)).foregroundStyle(Theme.ink).panel()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    seen
                    if feed.myRisk != .none { StayHomeSummary(model: model, store: store) }
                    choices
                    VStack(alignment: .leading, spacing: Space.s) {
                        sectionTitle("Recent contacts")
                        ExposureHistorySection(store: model.exposureHistory, showsTitle: false)
                    }
                    detection
                    more
                }
                .padding(.horizontal, Space.m)
                .padding(.bottom, Space.l)
            }
            .contentMargins(.bottom, Space.xl, for: .scrollContent)
            .background(Theme.paper)
            .navigationTitle("Me")
            .toolbar(.hidden, for: .navigationBar)
            #if DEBUG
            .sheet(isPresented: $showDeveloper) { DeveloperView(model: model, demoOverride: AnyView(DemoOverrideLink())) }
            #endif
            .sheet(item: $report) { ReportFlow(start: $0, model: model, store: store) }
            .sheet(isPresented: $showHow) { HowItWorksSheet() }
            .onReceive(AppRouter.shared.dismissSheets) {
                report = nil; showHow = false
                #if DEBUG
                showDeveloper = false
                #endif
            }
            .alert("Can't change that yet", isPresented: Binding(get: { blocked != nil }, set: { if !$0 { blocked = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(blocked ?? "") }
            .confirmationDialog("Pause detection", isPresented: $choosePause, titleVisibility: .visible) {
                Button("For 1 hour") { model.pause(.oneHour) }
                Button("Until tomorrow") { model.pause(.untilTomorrow) }
                Button("Until I turn it back on") { model.pause(.untilResumed) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(brand: "While paused, FlUni doesn't share your status, look for nearby phones or count close-contact time.")
            }
            .confirmationDialog("Delete all data on this phone?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete my data", role: .destructive) { SettingsView.deleteEverything(model: model) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears your saved status, recent contacts, today's places and setup. FlUni will start over as if it were just installed.")
            }
            .onAppear { store.reconcile(with: model) }
            .onChange(of: feed.myRisk) { _, _ in store.reconcile(with: model) }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.fluni(.section)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
    }

    // MARK: What phones see

    private var seen: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("What nearby phones see about you").font(.fluni(.note)).foregroundStyle(Theme.ink2)
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                StatusSwatch(risk: feed.myRisk, size: 18)
                Text(feed.myRisk == .contagious ? "Contagious" : feed.myRisk == .possible ? "Possibly sick" : "Healthy")
                    .font(.fluni(.display))
                    .accessibilityIdentifier("you.status")
            }
            Text("Also how many days ago it began (after a report), this phone's risk estimate and a random ID that changes every 15 minutes. Never your name, symptoms or location.")
                .font(.fluni(.note)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let at = feed.statusSetAt {
                Text("Since \(at.formatted(date: .abbreviated, time: .shortened))").font(.fluni(.fine)).foregroundStyle(Theme.ink2)
            }
        }
        .foregroundStyle(Theme.ink)
        .accessibilityElement(children: .combine)
    }

    // MARK: Report choices

    private var choices: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            sectionTitle("How are you feeling?")
            VStack(spacing: 0) {
                ForEach(Array(Choice.allCases.enumerated()), id: \.offset) { i, c in
                    if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    row(c)
                }
            }
            .padding(.horizontal, Space.s)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.ink.opacity(0.18), lineWidth: 1))
        }
    }

    private func option(_ c: Choice) -> (title: String, detail: String, shares: Risk?) {
        switch c {
        case .fine: return ("I feel fine", "Phones near you see: healthy.", Risk.none)
        case .symptoms: return ("I have symptoms", "Phones near you see: possibly sick.", .possible)
        case .positive: return ("I tested positive", "Phones near you see: contagious.", .contagious)
        case .negative: return ("I tested negative", "Clears \"possibly sick\". One rapid test isn't conclusive.", nil)
        }
    }

    private func selected(_ c: Choice) -> Bool {
        switch c {
        case .fine: return feed.myRisk == .none
        case .symptoms: return feed.myRisk == .possible
        case .positive: return feed.myRisk == .contagious
        case .negative: return false
        }
    }

    private func tap(_ c: Choice) {
        switch c {
        case .fine:
            guard feed.myRisk != .none else { return }
            do { try store.feelFine(model: model) } catch {
                blocked = "You tested positive, so you stay marked contagious until your \(IsolationPolicy.days) days are up and you've had no fever for \(Int(IsolationPolicy.feverFreeHours)) hours. Today will ask you then."
            }
        case .symptoms: report = .symptoms
        case .positive: report = .positive
        case .negative: report = .negative
        }
    }

    private func row(_ c: Choice) -> some View {
        let o = option(c)
        let on = selected(c)
        return Button { tap(c) } label: {
            HStack(alignment: .center, spacing: Space.s) {
                Group {
                    if let r = o.shares { StatusSwatch(risk: r) } else {
                        Circle().stroke(Theme.ink2, style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 12, height: 12)
                    }
                }
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(o.title).font(.fluni(.strong))
                    Text(o.detail).font(.fluni(.fine)).foregroundStyle(Theme.ink2).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if on || c == .fine {
                    Circle().stroke(Theme.ink, lineWidth: Theme.stroke)
                        .overlay { if on { Circle().fill(Theme.ink).padding(markSize * 0.25) } }
                        .frame(width: markSize, height: markSize)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold)).foregroundStyle(Theme.ink2)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(.vertical, Space.s)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("report.\(c)")
        .accessibilityHint(c == .fine ? "Sets your status to healthy" : "Opens a short form")
    }

    // MARK: Detection

    private var detection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            sectionTitle("Detection")
            if let p = feed.pauseState {
                Text("Paused \(PauseSchedule.describe(p, calendar: .current, now: Date())).").font(.fluni(.reading)).foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("you.pausedLine")
                Button("Turn detection back on") { model.resume() }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("you.resume")
                Button("Change how long") { choosePause = true }.buttonStyle(QuietLinkStyle())
            } else {
                Text("On. Pausing stops Bluetooth, distance sensing and location for a while, and saves battery.")
                    .font(.fluni(.note)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                Button("Pause detection") { choosePause = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("you.pause")
            }
        }
    }

    // MARK: More

    private var more: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink { SettingsView(model: model) } label: { linkRow("Settings") }
                .accessibilityIdentifier("settings.row")
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Button { showHow = true } label: { linkRow("How it works and what's shared") }
                .accessibilityIdentifier("you.how")
            Rectangle().fill(Theme.hairline).frame(height: 1)
            // fire-ink on paper, 6.9:1 (system red would be 3.3).
            Button { confirmDelete = true } label: {
                Text("Delete my data").font(.fluni(.strong)).foregroundStyle(Theme.fireInk)
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading).contentShape(Rectangle())
            }
            .accessibilityHint("Removes everything FlUni saved on this phone")
            .accessibilityIdentifier("you.delete")
            #if DEBUG
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Button { showDeveloper = true } label: {
                Text("Developer tools").font(.fluni(.fine)).foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .accessibilityHint("For testing. Not needed day to day.")
            .accessibilityIdentifier("developer.row")
            #endif
        }
        .buttonStyle(PressableStyle())
    }

    private func linkRow(_ s: String) -> some View {
        HStack {
            Text(s).font(.fluni(.strong))
            Spacer()
            Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold)).foregroundStyle(Theme.ink2)
                .accessibilityHidden(true)
        }
        .foregroundStyle(Theme.ink)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}
