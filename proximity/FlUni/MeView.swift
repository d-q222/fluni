import SwiftUI

/// Report how I feel, stay-home guidance while sick, plus the way into the Developer screen.
struct MeView: View {
    @ObservedObject var model: ProximityModel
    @ObservedObject var store: SelfReportStore
    @State private var sheet: ReportKind?
    @State private var blocked: String?
    #if DEBUG
    @State private var showDeveloper = false
    #endif

    @ScaledMetric(relativeTo: .title3) private var iconSize: CGFloat = 36

    private enum Choice: CaseIterable { case fine, symptoms, positive, negative }

    private struct Option {
        let title: String
        let detail: String
        let icon: String
        let tint: Color
    }

    private func option(_ c: Choice) -> Option {
        switch c {
        case .fine: return Option(title: "I feel fine", detail: "Phones near you see: healthy.", icon: "face.smiling", tint: Theme.sage)
        case .symptoms: return Option(title: "I have symptoms", detail: "Phones near you see: possibly sick. Time near you counts half toward their close contact.", icon: "thermometer.medium", tint: Theme.sun)
        case .positive: return Option(title: "I tested positive", detail: "Phones near you see: contagious, and may alert their owners.", icon: "cross.case", tint: Theme.fire)
        case .negative: return Option(title: "I tested negative", detail: "Sets you back to healthy if you were possibly sick. One rapid negative test isn't conclusive.", icon: "checkmark.shield", tint: Theme.sage)
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
                VStack(alignment: .leading, spacing: 12) {
                    if let n = store.notice {
                        Text(n).font(.fluni(.footnote)).foregroundStyle(Theme.ink).card(fill: Theme.surface2)
                    }
                    if model.myRisk != .none { AtHomeCard(model: model, store: store) }
                    Text("How are you doing?").font(.fluni(.title3, weight: .bold)).foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Choice.allCases, id: \.self) { row($0) }
                    since
                    Text("Only your status (healthy, possibly sick or contagious) and a random ID that changes every 15 minutes are shared with phones nearby. Symptoms, test details and dates stay on this phone. No name, no location.")
                        .font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
                        .padding(.top, 4)
                    NavigationLink { SettingsView(model: model) } label: {
                        Label("Settings", systemImage: "gearshape").font(.fluni(.body, weight: .semibold)).foregroundStyle(Theme.ink).frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("settings.row")
                    #if DEBUG
                    Button { showDeveloper = true } label: {
                        Text("Developer tools").font(.fluni(.footnote)).foregroundStyle(Theme.ink3).frame(minHeight: 44)
                    }
                    .accessibilityHint("For testing. Not needed day to day.")
                    .accessibilityIdentifier("developer.row")
                    .frame(maxWidth: .infinity)
                    #endif
                }
                .padding(16)
            }
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

    private func row(_ c: Choice) -> some View {
        let o = option(c)
        let selected = selected(c)
        return Button { tap(c) } label: {
            HStack(spacing: 12) {
                Image(systemName: o.icon).font(.title3).frame(width: iconSize, height: iconSize)
                    .background(o.tint.opacity(0.45), in: Circle()).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.title).font(.fluni(.body, weight: .semibold))
                    Text(o.detail).font(.fluni(.footnote)).foregroundStyle(Theme.ink2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : (c == .fine ? "circle" : "chevron.right"))
                    .foregroundStyle(selected ? Theme.ink : Theme.ink3).accessibilityHidden(true)
            }
            .foregroundStyle(Theme.ink)
            .card(fill: selected ? Theme.surface2 : Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(selected ? Theme.ink : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("report.\(c)")
        .accessibilityHint(c == .fine ? "Sets your status to healthy" : "Opens a short form")
    }

    @ViewBuilder private var since: some View {
        if let at = model.statusSetAt {
            Text("Status set \(at.formatted(date: .abbreviated, time: .shortened))")
                .font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
        } else {
            Text("You haven't set a status yet. Phones near you see \"healthy\".")
                .font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
        }
    }
}
