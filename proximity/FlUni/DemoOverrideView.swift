import SwiftUI

/// Developer only (Debug builds): the Demo override. While on, it replaces the live clock with a chosen sim time for
/// the persona, the map and the walk-in warning, and Today and Map show a "Demo time" badge. Reached from the
/// Developer screen's "Demo controls".
struct DemoOverrideScreen: View {
    @ObservedObject private var store = PSickStore.shared
    @ObservedObject private var clock = SimClock.shared
    @State private var runID = PSickLoader.runID

    var body: some View {
        List {
            Section {
                Toggle("Demo override", isOn: Binding(get: { clock.demoOn }, set: { clock.setDemo($0) }))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("demo.override")
                if clock.demoOn, let range = clock.range {
                    // The slider speaks the time as its value, so the visible text is not read twice.
                    Text(PSickFeed.clockText(clock.simTime)).monospacedDigit().accessibilityHidden(true)
                    Slider(value: $clock.demoTime, in: range.lowerBound...range.upperBound, step: 60)
                        .disabled(clock.follow)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Simulated time")
                        .accessibilityValue(PSickFeed.clockText(clock.simTime))
                        .accessibilityHint(clock.follow ? "Turn off Follow the map to move the time yourself" : "Swipe up or down to move one minute")
                    Toggle("Follow the map (2 simulated minutes per second)", isOn: $clock.follow)
                        .frame(minHeight: 44)
                }
            } header: { Text("Time").foregroundStyle(Theme.ink2) } footer: {
                Text("While on, this replaces the live time everywhere, saved across launches. Off: the phone's own clock decides.")
                    .foregroundStyle(Theme.ink2)
            }
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
            if let feed = store.feed {
                Section {
                    NavigationLink {
                        AgentList(agents: feed.agents, selection: $store.agent)
                    } label: {
                        LabeledContent("Student") { Text(store.agent.isEmpty ? "None" : store.agent).foregroundStyle(Theme.ink2) }
                    }
                } header: { Text("Play as").foregroundStyle(Theme.ink2) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.paper)
        .navigationTitle("Demo override")
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.feed == nil { await store.reload() } }
    }
}

/// The row in Developer > Demo controls that opens the screen.
struct DemoOverrideLink: View {
    @ObservedObject private var clock = SimClock.shared
    var body: some View {
        NavigationLink {
            DemoOverrideScreen()
        } label: {
            LabeledContent("Demo override") { Text(clock.demoOn ? "On" : "Off").foregroundStyle(.secondary) }
        }
        .accessibilityIdentifier("developer.demoOverride")
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
            // A rehearsal starts each building's 2-hour cooldown; clear it before the live demo.
            Button("Reset warnings") { monitor.resetCooldowns() }.frame(minHeight: 44)
        } footer: { Text("Changes the walk-in warning only. Nothing else uses it. Reset warnings so a rehearsal doesn't silence the live demo.").foregroundStyle(Theme.ink2) }
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
