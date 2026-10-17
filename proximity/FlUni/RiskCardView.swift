import SwiftUI

/// The Today risk card: the phone's own estimate, plus the official campus-model number when a demo persona is set.
struct RiskCardView: View {
    let dose: Double
    let onHow: () -> Void
    @ObservedObject private var store = PSickStore.shared

    /// Same tiers as the map: low = sage, elevated = sun, high = fire. Text is ink, or fire-ink on fire.
    private static func fill(_ b: RiskEstimate.Band) -> Color {
        switch b {
        case .low: return Theme.sage.opacity(0.45)
        case .elevated: return Theme.sun.opacity(0.5)
        case .high: return Theme.fire.opacity(0.22)
        }
    }
    private static func textColor(_ b: RiskEstimate.Band) -> Color { b == .high ? Theme.fireInk : Theme.ink }
    /// Secondary text: ink-2 passes on sage and sun tints (5.1 and 5.6), fire-ink is safer on the fire tint.
    private static func noteColor(_ b: RiskEstimate.Band) -> Color { b == .high ? Theme.fireInk : Theme.ink2 }

    var body: some View {
        let p = RiskEstimate.probability(dose: dose)
        // The headline number sets the tier colour: the campus model's when there is one, else this phone's.
        let band = RiskEstimate.band(store.campusP ?? p)
        let text = Self.textColor(band)
        VStack(alignment: .leading, spacing: 8) {
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
                // Same number for colour and advice, so they can never disagree.
                Text(RiskEstimate.summary(store.campusP ?? p)).font(.fluni(.subheadline))
                Text("Based on time near other FlUni phones in the last 24 hours. It's an estimate, not a diagnosis.")
                    .font(.fluni(.footnote)).foregroundStyle(Self.noteColor(band))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("risk.card")
            Button(action: onHow) {
                Label("See how this is worked out", systemImage: "function")
                    .font(.fluni(.footnote, weight: .semibold)).foregroundStyle(Self.noteColor(band)).frame(minHeight: 44)
            }
            .accessibilityHint("Opens the numbers behind this estimate")
            .accessibilityIdentifier("risk.how")
        }
        .foregroundStyle(text)
        .card(fill: Self.fill(band))
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
                        .font(.footnote.monospaced()).frame(minHeight: 44)
                        .accessibilityLabel("Run name")
                    Button(store.loading ? "Loading\u{2026}" : "Load from the laptop") {
                        SimClock.shared.runID = runID
                        Task { await store.reload() }
                    }.disabled(store.loading).frame(minHeight: 44)
                    if !store.status.isEmpty { Text(store.status).font(.footnote).foregroundStyle(Theme.ink2) }
                } header: { Text("Model output").foregroundStyle(Theme.ink2) } footer: {
                    Text("Read from the same laptop as the map.").foregroundStyle(Theme.ink2)
                }
                PretendSection()
                if let feed = store.feed, let range = feed.timeRange {
                    Section {
                        NavigationLink {
                            AgentList(agents: feed.agents, selection: $store.agent)
                        } label: {
                            LabeledContent("Student") { Text(store.agent.isEmpty ? "None" : store.agent).foregroundStyle(Theme.ink2) }
                        }
                    } header: { Text("Play as").foregroundStyle(Theme.ink2) }
                    if !store.agent.isEmpty {
                        Section {
                            // The slider speaks the time as its value, so the visible text is not read twice.
                            Text(PSickFeed.clockText(store.simTime)).monospacedDigit().accessibilityHidden(true)
                            Slider(value: $store.simTime, in: range.lowerBound...range.upperBound, step: 60)
                                .disabled(store.follow)
                                .frame(minHeight: 44)
                                .accessibilityLabel("Simulated time")
                                .accessibilityValue(PSickFeed.clockText(store.simTime))
                                .accessibilityHint(store.follow ? "Turn off Follow the map to move the time yourself" : "Swipe up or down to move one minute")
                            Toggle("Follow the map (2 simulated minutes per second)", isOn: $store.follow)
                                .frame(minHeight: 44)
                        } header: { Text("Simulated time").foregroundStyle(Theme.ink2) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
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
            Button("None, use this phone only") { selection = ""; dismiss() }
                .accessibilityAddTraits(selection.isEmpty ? .isSelected : [])
            ForEach(shown, id: \.self) { a in
                Button { selection = a; dismiss() } label: {
                    HStack { Text(a).monospacedDigit(); Spacer(); if a == selection { Image(systemName: "checkmark").accessibilityHidden(true) } }
                }
                .accessibilityAddTraits(a == selection ? .isSelected : [])
            }
        }
        .foregroundStyle(Theme.ink)
        .searchable(text: $query, prompt: "Search students")
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
                LabeledContent("Pretend I'm at\u{2026}") {
                    Text(monitor.pretend.flatMap { heat.heat?.buildings[$0]?.name } ?? "Real location").foregroundStyle(Theme.ink2)
                }
            }
        } footer: { Text("Changes the walk-in warning only. Nothing else uses it.").foregroundStyle(Theme.ink2) }
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
                .accessibilityAddTraits(selection == nil ? .isSelected : [])
            ForEach(shown, id: \.id) { b in
                Button { selection = b.id; dismiss() } label: {
                    HStack { Text(b.name); Spacer(); if b.id == selection { Image(systemName: "checkmark").accessibilityHidden(true) } }
                }
                .accessibilityAddTraits(b.id == selection ? .isSelected : [])
            }
        }
        .foregroundStyle(Theme.ink)
        .searchable(text: $query, prompt: "Search buildings")
        .navigationTitle("Pretend I'm at\u{2026}")
    }
}
