import SwiftUI

/// Report how I feel, stay-home guidance while sick, plus the way into the Developer screen.
struct MeView: View {
    @ObservedObject var model: ProximityModel
    /// The app's one self-report store, shared with Today (two copies of the same file could disagree).
    @ObservedObject var store: SelfReportStore
    @State private var sheet: ReportKind?
    @State private var blocked: String?
    #if DEBUG
    @State private var showDeveloper = false
    #endif

    @ScaledMetric(relativeTo: .body) private var markSize: CGFloat = 22

    private enum Choice: CaseIterable { case fine, symptoms, positive, negative }

    private struct Option {
        let title: String
        let detail: String
        /// The status this choice shares, drawn as its swatch; nil for "tested negative" (not a status of its own).
        let shares: Risk?
    }

    private func option(_ c: Choice) -> Option {
        switch c {
        case .fine: return Option(title: "I feel fine", detail: "Phones near you see: healthy.", shares: Risk.none)
        case .symptoms: return Option(title: "I have symptoms", detail: "Phones near you see: possibly sick. Time near you counts half toward their close contact.", shares: .possible)
        case .positive: return Option(title: "I tested positive", detail: "Phones near you see: contagious, and may alert their owners.", shares: .contagious)
        case .negative: return Option(title: "I tested negative", detail: "Sets you back to healthy if you were possibly sick. One rapid negative test isn't conclusive.", shares: nil)
        }
    }

    private func selected(_ c: Choice) -> Bool {
        switch c {
        case .fine: return model.myRisk == .none
        case .symptoms: return model.myRisk == .possible
        case .positive: return model.myRisk == .contagious
        case .negative: return false
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    if let n = store.notice {
                        Text(n).font(.fluni(.fine)).foregroundStyle(Theme.ink).panel()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    statusHeader
                    if model.myRisk != .none { AtHomeCard(model: model, store: store) }
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("How are you doing?").font(.fluni(.section)).foregroundStyle(Theme.ink)
                            .accessibilityAddTraits(.isHeader)
                        // One drawn box holding the four choices as rows, rather than four boxes.
                        VStack(spacing: 0) {
                            ForEach(Array(Choice.allCases.enumerated()), id: \.offset) { i, c in
                                if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                                row(c)
                            }
                        }
                        .card()
                    }
                    Text("Only your status (healthy, possibly sick or contagious) and a random ID that changes every 15 minutes are shared with phones nearby. Symptoms, test details and dates stay on this phone. No name, no location.")
                        .font(.fluni(.fine)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .panel()
                    VStack(spacing: 0) {
                        NavigationLink { SettingsView(model: model) } label: {
                            HStack {
                                Text("Settings").font(.fluni(.strong))
                                Spacer()
                                Image(systemName: "chevron.right").font(.fluni(.fine).weight(.semibold)).foregroundStyle(Theme.ink2)
                                    .accessibilityHidden(true)
                            }
                            .foregroundStyle(Theme.ink)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("settings.row")
                        HandRule()
                        #if DEBUG
                        Button { showDeveloper = true } label: {
                            Text("Developer tools").font(.fluni(.fine)).foregroundStyle(Theme.ink3)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .accessibilityHint("For testing. Not needed day to day.")
                        .accessibilityIdentifier("developer.row")
                        #endif
                    }
                }
                .padding(.horizontal, Space.m)
                .padding(.bottom, Space.l)
            }
            .contentMargins(.bottom, Space.xl, for: .scrollContent)
            .background(Theme.paper)
            .navigationTitle("Me")
            #if DEBUG
            .sheet(isPresented: $showDeveloper) { DeveloperView(model: model, demoOverride: AnyView(DemoOverrideLink())) }
            #endif
            .sheet(item: $sheet) { ReportSheet(kind: $0, model: model, store: store) }
            .onReceive(AppRouter.shared.dismissSheets) {
                sheet = nil
                #if DEBUG
                showDeveloper = false
                #endif
            }
            .alert("Can't change that yet", isPresented: Binding(get: { blocked != nil }, set: { if !$0 { blocked = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(blocked ?? "") }
            .onAppear { store.reconcile(with: model) }
            .onChange(of: model.myRisk) { _ in store.reconcile(with: model) }
        }
    }

    private func tap(_ c: Choice) {
        switch c {
        case .fine:
            guard model.myRisk != .none else { return }
            do { try store.feelFine(model: model) } catch {
                blocked = "You tested positive, so you stay marked contagious until your \(IsolationPolicy.days) days are up and you've had no fever for \(Int(IsolationPolicy.feverFreeHours)) hours. The At home card will check in with you then."
            }
        case .symptoms: sheet = .symptoms
        case .positive: sheet = .positive
        case .negative: sheet = .negative
        }
    }

    /// What nearby phones see right now: the fact this tab exists for, set large.
    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Phones near you see").font(.fluni(.note)).foregroundStyle(Theme.ink2)
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                StatusSwatch(risk: model.myRisk, size: 18)
                Text(model.myRisk == .contagious ? "contagious" : model.myRisk == .possible ? "possibly sick" : "healthy")
                    .font(.fluni(.display))
            }
            since
        }
        .foregroundStyle(Theme.ink)
        .accessibilityElement(children: .combine)
    }

    private func row(_ c: Choice) -> some View {
        let o = option(c)
        let selected = selected(c)
        return Button { tap(c) } label: {
            HStack(alignment: .top, spacing: Space.s) {
                Group {
                    if let r = o.shares { StatusSwatch(risk: r) } else {
                        Circle().stroke(Theme.ink2, style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 12, height: 12)
                    }
                }
                .frame(height: 22)   // centres the mark on the title's first line
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(o.title).font(.fluni(.strong))
                    Text(o.detail).font(.fluni(.fine)).foregroundStyle(Theme.ink2).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                trailing(c, selected: selected).frame(height: 22)
            }
            .foregroundStyle(Theme.ink)
            .padding(.vertical, Space.s)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("report.\(c)")
        .accessibilityHint(c == .fine ? "Sets your status to healthy" : "Opens a short form")
    }

    /// A drawn-style radio: an ink ring, filled with an ink dot when this is your status. Choices that open
    /// a form show a chevron instead until chosen.
    @ViewBuilder private func trailing(_ c: Choice, selected: Bool) -> some View {
        if selected || c == .fine {
            Circle().stroke(Theme.ink, lineWidth: Theme.stroke)
                .overlay { if selected { Circle().fill(Theme.ink).padding(markSize * 0.25) } }
                .frame(width: markSize, height: markSize)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "chevron.right").font(.fluni(.fine).weight(.semibold)).foregroundStyle(Theme.ink2)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var since: some View {
        if let at = model.statusSetAt {
            Text("Since \(at.formatted(date: .abbreviated, time: .shortened))")
                .font(.fluni(.fine)).foregroundStyle(Theme.ink2)
        } else {
            Text("You haven't set a status yet, so it's \"healthy\".")
                .font(.fluni(.fine)).foregroundStyle(Theme.ink2)
        }
    }
}
