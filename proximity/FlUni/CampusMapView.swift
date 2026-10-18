import SwiftUI
import MapKit

/// The built-in Map tab: a native map of the campus buildings, coloured by the file's heat, moving with the shared
/// sim clock. Totals only, never people. Buildings with no data are not drawn.
struct CampusMapView: View {
    @ObservedObject private var store = BuildingHeatStore.shared
    @ObservedObject private var clock = SimClock.shared
    @State private var position = MapCameraPosition.automatic
    @State private var selected: String?
    @State private var showDetailed = false
    @ObservedObject private var router = AppRouter.shared
    @State private var showList = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            let heat = store.heat
            let snap = heat?.state(at: clock.simTime)
            MapReader { proxy in
                Map(position: $position) {
                    ForEach(heat?.mappable ?? [], id: \.id) { b in
                        if let r = snap?.readings[b.id] {
                            let c = CLLocationCoordinate2D(latitude: b.lat!, longitude: b.lon!)
                            MapCircle(center: c, radius: b.radius)
                                .foregroundStyle(Self.color(r.heat).opacity(r.high ? 0.8 : 0.6))
                                .stroke(r.high ? Theme.fireInk : Theme.ink.opacity(b.id == selected ? 0.8 : 0.25), lineWidth: r.high ? 3 : (b.id == selected ? 2 : 1))
                            if r.high {
                                // Colour is not the only cue: high buildings also carry a warning mark.
                                Annotation("", coordinate: c, anchor: .center) {
                                    Image(systemName: "exclamationmark.triangle.fill").font(.caption.weight(.bold))
                                        .foregroundStyle(Theme.paper).padding(5)
                                        .background(Theme.fireInk, in: Circle())
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .accessibilityLabel("Campus map")
                .accessibilityHint("The circles can't be read aloud. Use Building list for the same information as text.")
                .transaction { t in if reduceMotion { t.animation = nil } }
                .onTapGesture { point in
                    guard let heat, let c = proxy.convert(point, from: .local) else { return }
                    selected = Self.hit(heat, snap, c)
                }
            }
            .overlay(alignment: .top) { chip(snap).padding(8) }
            .safeAreaInset(edge: .bottom) {
                let stack = VStack(spacing: 8) {
                    AlwaysLocationCard()
                    if let heat, let id = selected, let b = heat.buildings[id] { infoCard(b, snap?.readings[id]) }
                    legend
                }
                // At the largest text sizes the cards would cover the map, so they scroll in a capped area.
                Group {
                    if typeSize.isAccessibilitySize {
                        ScrollView { stack }.frame(maxHeight: 320).scrollBounceBehavior(.basedOnSize)
                    } else { stack }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showList = true } label: { Label("Building list", systemImage: "list.bullet").labelStyle(.iconOnly) }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityHint("Lists buildings with data, busiest first")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Open detailed map") { showDetailed = true }
                        .font(.fluni(.footnote, weight: .semibold))
                        .frame(minHeight: 44)
                        .accessibilityHint("Opens the full heat map")
                }
            }
            .sheet(isPresented: $showList) {
                BuildingListSheet(rows: Self.rows(heat, snap)) { id in selected = id; showList = false }
            }
            .sheet(isPresented: $showDetailed) {
                NavigationStack {
                    HeatmapView()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDetailed = false } } }
                }
            }
            .onReceive(router.dismissSheets) { showList = false; showDetailed = false }
            .onAppear { frame(); focusIfAsked() }
            .onChange(of: heat?.buildings.count) { _, _ in frame(); focusIfAsked() }
            .onChange(of: router.focusBuilding) { _, _ in focusIfAsked() }
            .task { await store.refresh() }
        }
    }

    // MARK: Pieces

    /// The only time on the map: "Now \u{00B7} updated 4:30 PM", the local time of the snapshot being shown.
    private func chip(_ snap: BuildingHeat.Snapshot?) -> some View {
        let text = snap.map { "Now \u{00B7} updated \(LiveClock.timeText($0.t))" } ?? "Now \u{00B7} no data yet"
        return VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.fluni(.subheadline, weight: .semibold)).monospacedDigit()
                .contentTransition(.identity)
                .accessibilityIdentifier("map.updated")
            DemoTimeBadge()
            // Laptop problems are a presenter's concern, not a student's.
            if SimClock.demoAvailable, !store.status.isEmpty {
                Text(store.status).font(.fluni(.caption)).foregroundStyle(Theme.ink2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Theme.ink)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.hairline))
        .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 340, alignment: .leading)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { swatches }
                VStack(alignment: .leading, spacing: 6) { swatches }
            }
            Text("Grey areas: not enough people to show").font(.fluni(.caption)).foregroundStyle(Theme.ink2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map key. Low, elevated or high chance of illness in a building. High buildings also have a warning mark. Grey areas: not enough people to show.")
    }

    @ViewBuilder private var swatches: some View {
        swatch(Theme.sage, "Low", false)
        swatch(Theme.sun, "Elevated", false)
        swatch(Theme.fire, "High", true)
    }

    /// The outline is ink-2 so each swatch clears 3:1 against the key's background (sage 2.0 and sun 1.4 alone do not).
    private func swatch(_ c: Color, _ t: String, _ warn: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 16, height: 16).overlay(Circle().stroke(Theme.ink2, lineWidth: warn ? 2 : 1))
            Text(t).font(.fluni(.footnote)).foregroundStyle(Theme.ink)
            if warn { Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(Theme.fireInk) }
        }
    }

    private func infoCard(_ b: BuildingHeat.Building, _ r: BuildingHeat.Reading?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(b.name).font(.fluni(.headline)).accessibilityAddTraits(.isHeader)
            if let r {
                Text("\(Int(r.people.rounded())) people, about \(Int(r.expectedSick.rounded())) may be sick").font(.fluni(.subheadline))
                Text(Self.advice(r.tier)).font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
            } else {
                Text("Not enough people to show right now.").font(.fluni(.subheadline))
            }
        }
        .foregroundStyle(Theme.ink)
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Close") { selected = nil }
    }

    // MARK: Helpers

    struct Row: Identifiable {
        let id: String, name: String, tier: BuildingHeat.Tier, people: Int, sick: Int
        var tierWord: String { tier == .high ? "High" : (tier == .elevated ? "Elevated" : "Low") }
        var spoken: String { "\(name), \(tierWord.lowercased()): about \(sick) of \(people) people may be sick" }
    }

    /// Buildings with data right now, busiest first.
    static func rows(_ heat: BuildingHeat?, _ snap: BuildingHeat.Snapshot?) -> [Row] {
        var out: [(heat: Double, row: Row)] = []
        for b in heat?.mappable ?? [] {
            guard let r = snap?.readings[b.id] else { continue }
            let row = Row(id: b.id, name: b.name, tier: r.tier, people: Int(r.people.rounded()), sick: Int(r.expectedSick.rounded()))
            out.append((r.heat, row))
        }
        out.sort { (x, y) -> Bool in
            if x.heat != y.heat { return x.heat > y.heat }
            return x.row.name < y.row.name
        }
        return out.map { $0.row }
    }

    /// Same words as the web map's `advice`.
    static func advice(_ t: BuildingHeat.Tier) -> String {
        switch t {
        case .low: return "Low. No action needed."
        case .elevated: return "Elevated. Wear a mask in crowded rooms and watch for symptoms."
        case .high: return "High. Consider getting tested at Vaden and staying home."
        }
    }

    static func color(_ heat: Double) -> Color {
        let c = BuildingHeat.rgb(heat: heat)
        return Color(red: c.r / 255, green: c.g / 255, blue: c.b / 255)
    }

    /// The drawn building nearest the tap, if the tap is within its circle or a finger's width of it.
    private static func hit(_ heat: BuildingHeat, _ snap: BuildingHeat.Snapshot?, _ c: CLLocationCoordinate2D) -> String? {
        var best: (String, Double)?
        for b in heat.mappable where snap?.readings[b.id] != nil {
            let d = BuildingHeat.haversine(c.latitude, c.longitude, b.lat!, b.lon!) - b.radius
            if best == nil || d < best!.1 { best = (b.id, d) }
        }
        guard let best else { return nil }
        return best.1 <= 60 ? best.0 : nil  // tiny circles at campus zoom: allow a near miss
    }

    /// A notification asked to show a building: centre on it and open its card (waits until the data has loaded).
    private func focusIfAsked() {
        guard let id = router.focusBuilding else { return }
        guard let heat = store.heat else { return }
        router.focusBuilding = nil
        guard let b = heat.buildings[id], let lat = b.lat, let lon = b.lon else { return }
        selected = id
        position = .region(MKCoordinateRegion(center: .init(latitude: lat, longitude: lon),
                                              span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)))
    }

    /// Centre the camera on the run's buildings.
    private func frame() {
        guard let b = store.heat?.mappable, !b.isEmpty else { return }
        let lats = b.map { $0.lat! }, lons = b.map { $0.lon! }
        let centre = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.004, (lats.max()! - lats.min()!) * 1.3), longitudeDelta: max(0.004, (lons.max()! - lons.min()!) * 1.3))
        position = .region(MKCoordinateRegion(center: centre, span: span))
    }
}

/// The map as text: every building with data, busiest first. Tapping one selects it on the map.
private struct BuildingListSheet: View {
    let rows: [CampusMapView.Row]
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if rows.isEmpty {
                    Text("No buildings have enough people to show right now.").foregroundStyle(Theme.ink2)
                }
                ForEach(rows) { r in
                    Button { pick(r.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                if r.tier == .high {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.fireInk).accessibilityHidden(true)
                                }
                                Text(r.name).font(.fluni(.headline))
                            }
                            Text("\(r.tierWord): about \(r.sick) of \(r.people) people may be sick")
                                .font(.fluni(.subheadline)).foregroundStyle(Theme.ink2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .foregroundStyle(Theme.ink)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(r.spoken)
                    .accessibilityHint("Shows this building on the map")
                    .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
            .navigationTitle("Buildings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
