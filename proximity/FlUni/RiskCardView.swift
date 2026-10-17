import SwiftUI

/// The Today risk card: the phone's own estimate, plus the official campus-model number when a demo persona is set.
struct RiskCardView: View {
    let dose: Double
    let onHow: () -> Void
    @ObservedObject private var store = PSickStore.shared

    var body: some View {
        let p = RiskEstimate.probability(dose: dose)
        VStack(alignment: .leading, spacing: 8) {
            if let official = store.campusP {
                Text("Campus model: \(RiskEstimate.percentText(official))")
                    .font(.fluni(.title2, weight: .bold)).monospacedDigit()
                Text("This phone's estimate: \(RiskEstimate.percentText(p))")
                    .font(.fluni(.headline)).monospacedDigit()
            } else {
                Text("Your risk estimate").font(.fluni(.headline))
                Text(RiskEstimate.percentText(p)).font(.fluni(.largeTitle, weight: .bold)).monospacedDigit()
            }
            Text(RiskEstimate.summary(p)).font(.fluni(.subheadline))
            Text("An estimate from nearby contacts in the last 24 hours, not a diagnosis.")
                .font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
            Button(action: onHow) {
                Label("How is this calculated?", systemImage: "function")
                    .font(.fluni(.footnote, weight: .semibold)).foregroundStyle(Theme.ink2).frame(minHeight: 44)
            }
        }
        .foregroundStyle(Theme.ink)
        .card()
        .task { if store.feed == nil, !store.agent.isEmpty { await store.reload() } }
    }
}

/// Demo only: play a sim agent at a sim time, so the phone can show the campus model's number.
struct PSickDemoSheet: View {
    @ObservedObject private var store = PSickStore.shared
    @State private var runID = PSickLoader.runID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Run name", text: $runID).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    Button(store.loading ? "Loading\u{2026}" : "Load from laptop") {
                        SimClock.shared.runID = runID
                        Task { await store.reload() }
                    }.disabled(store.loading)
                    if !store.status.isEmpty { Text(store.status).font(.footnote).foregroundStyle(Theme.ink2) }
                } header: { Text("Model output") } footer: {
                    Text("Read from the same laptop as the map.")
                }
                PretendSection()
                if let feed = store.feed, let range = feed.timeRange {
                    Section("Pretend to be") {
                        NavigationLink {
                            AgentList(agents: feed.agents, selection: $store.agent)
                        } label: {
                            LabeledContent("Student", value: store.agent.isEmpty ? "None" : store.agent)
                        }
                    }
                    if !store.agent.isEmpty {
                        Section {
                            Text(PSickFeed.clockText(store.simTime)).monospacedDigit()
                            Slider(value: $store.simTime, in: range.lowerBound...range.upperBound, step: 60)
                                .disabled(store.follow)
                            Toggle("Follow the map (2 sim min per second)", isOn: $store.follow)
                        } header: { Text("Sim time") }
                    }
                }
            }
            .navigationTitle("Demo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { if store.feed == nil { await store.reload() } }
        }
    }
}

/// Searchable list, so a 500-agent run is usable.
private struct AgentList: View {
    let agents: [String]
    @Binding var selection: String
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let shown = query.isEmpty ? agents : agents.filter { $0.localizedCaseInsensitiveContains(query) }
        List {
            Button("None (this phone only)") { selection = ""; dismiss() }
            ForEach(shown, id: \.self) { a in
                Button { selection = a; dismiss() } label: {
                    HStack { Text(a).monospacedDigit(); Spacer(); if a == selection { Image(systemName: "checkmark") } }
                }
            }
        }
        .foregroundStyle(Theme.ink)
        .searchable(text: $query, prompt: "Search agent id")
        .navigationTitle("Student")
    }
}

/// Demo only: act as if standing in a building, for the walk-in warning (GPS is ignored for it).
private struct PretendSection: View {
    @ObservedObject private var monitor = WalkInMonitor.shared
    @ObservedObject private var heat = BuildingHeatStore.shared

    var body: some View {
        Section {
            NavigationLink {
                BuildingPicker(buildings: heat.heat?.mappable ?? [], selection: $monitor.pretend)
            } label: {
                LabeledContent("Pretend I'm at\u{2026}", value: monitor.pretend.flatMap { heat.heat?.buildings[$0]?.name } ?? "Real location")
            }
        } footer: { Text("Changes the walk-in warning only. Nothing else uses it.") }
    }
}

private struct BuildingPicker: View {
    let buildings: [BuildingHeat.Building]
    @Binding var selection: String?
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let shown = query.isEmpty ? buildings : buildings.filter { $0.name.localizedCaseInsensitiveContains(query) }
        List {
            Button("My real location") { selection = nil; dismiss() }
            ForEach(shown, id: \.id) { b in
                Button { selection = b.id; dismiss() } label: {
                    HStack { Text(b.name); Spacer(); if b.id == selection { Image(systemName: "checkmark") } }
                }
            }
        }
        .foregroundStyle(Theme.ink)
        .searchable(text: $query, prompt: "Search buildings")
        .navigationTitle("Pretend I'm at\u{2026}")
    }
}
