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
                        }
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .onTapGesture { point in
                    guard let heat, let c = proxy.convert(point, from: .local) else { return }
                    selected = Self.hit(heat, snap, c)
                }
            }
            .overlay(alignment: .top) { chip(snap != nil).padding(8) }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    AlwaysLocationCard()
                    if let heat, let id = selected, let b = heat.buildings[id] { infoCard(b, snap?.readings[id]) }
                    legend
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Open detailed map") { showDetailed = true }
                        .font(.fluni(.footnote, weight: .semibold))
                }
            }
            .sheet(isPresented: $showDetailed) {
                NavigationStack {
                    HeatmapView()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDetailed = false } } }
                }
            }
            .onAppear { frame(); focusIfAsked() }
            .onChange(of: heat?.buildings.count) { _, _ in frame(); focusIfAsked() }
            .onChange(of: router.focusBuilding) { _, _ in focusIfAsked() }
            .task { await store.refresh() }
        }
    }

    // MARK: Pieces

    private func chip(_ hasData: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Button { clock.follow.toggle() } label: {
                    Image(systemName: clock.follow ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }
                .accessibilityLabel(clock.follow ? "Pause time" : "Play time")
                VStack(alignment: .leading, spacing: 0) {
                    Text(PSickFeed.clockText(clock.simTime)).font(.fluni(.subheadline, weight: .semibold)).monospacedDigit()
                    Text(hasData ? (store.source == .live ? "Live from laptop" : "Built-in data") : "No data at this time")
                        .font(.fluni(.caption)).foregroundStyle(Theme.ink2)
                }
                Spacer(minLength: 0)
            }
            if !store.status.isEmpty {
                Text(store.status).font(.fluni(.caption)).foregroundStyle(Theme.ink2).padding(.leading, 54).padding(.bottom, 4)
            }
        }
        .foregroundStyle(Theme.ink)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.hairline))
        .frame(maxWidth: 340)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                swatch(Theme.sage, "Low")
                swatch(Theme.sun, "Elevated")
                swatch(Theme.fire, "High")
            }
            Text("Grey areas: not enough people to show").font(.fluni(.caption)).foregroundStyle(Theme.ink2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.hairline))
        .accessibilityElement(children: .combine)
    }

    private func swatch(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 14, height: 14).overlay(Circle().stroke(Theme.ink.opacity(0.25)))
            Text(t).font(.fluni(.footnote)).foregroundStyle(Theme.ink)
        }
    }

    private func infoCard(_ b: BuildingHeat.Building, _ r: BuildingHeat.Reading?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(b.name).font(.fluni(.headline))
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
    }

    // MARK: Helpers

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
