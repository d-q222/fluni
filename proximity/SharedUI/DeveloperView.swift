import SwiftUI

struct DeveloperView: View {
    @ObservedObject var model: ProximityModel
    /// False when this is the harness's main screen rather than a sheet in FlUni.
    var showsDone = true
    /// FlUni's Demo override entry (it needs FlUni's clock, so the harness leaves it out).
    var demoOverride: AnyView?
    @Environment(\.dismiss) private var dismiss
    @State private var showLaptopMap = false

    var body: some View {
        NavigationStack {
            List {
                if model.exposure.level != .none { alertSection }
                meSection
                exposureSection
                peersSection
                demoSection
                #if DEBUG
                keepAwakeSection
                #endif
                statusSection
                Section { Button("Open detailed map (laptop)") { showLaptopMap = true } } footer: {
                    Text("The full heat map, served from a laptop on the same Wi-Fi. For the team, not students.")
                }
            }
            .sheet(isPresented: $showLaptopMap) {
                NavigationStack {
                    HeatmapView()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showLaptopMap = false } } }
                }
            }
            .navigationTitle("Developer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { if showsDone { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } }
            .animation(Motion.gentle, value: model.exposure.level)  // follows Reduce Motion
        }
    }

    private var alertSection: some View {
        let close = model.exposure.level == .closeContact
        return Section {
            VStack(alignment: .leading, spacing: 10) {
                Label(Advice.title(model.exposure.alert),
                      systemImage: close ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.title3.bold())
                ForEach(Advice.body(model.exposure.alert), id: \.self) { line in
                    Label(line, systemImage: "arrow.right.circle")
                        .font(.subheadline)
                        .labelStyle(AdviceLabelStyle())
                }
            }
            .foregroundStyle(.white)
            .padding(.vertical, 6)
            .listRowBackground(close ? Color.red : Color.orange)
            .accessibilityElement(children: .combine)
        }
    }

    private var meSection: some View {
        Section {
            Picker("My status", selection: $model.myRisk) {
                ForEach(Risk.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("My status")
        } footer: {
            Text("Shared anonymously with phones nearby: this status, days since onset, this phone's own score and a random ID (\(model.myID.hex.prefix(4))) that changes every 15 minutes. No name, no location.")
        }
    }

    private var exposureSection: some View {
        let mins = model.exposure.minutes
        let goal = ExposureTracker.closeContactMinutes
        let color: Color = mins >= goal ? .red : (mins > 0 ? .orange : .green)
        return Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%.0f", min(mins, 99)))
                        .font(.system(.largeTitle, design: .rounded).bold())
                        .monospacedDigit()
                    Text("of \(Int(goal)) min")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(mins >= goal ? "Close contact" : mins > 0 ? "\(Int((goal - mins).rounded(.up))) min to alert" : "No exposure")
                        .font(.subheadline.bold())
                        .foregroundStyle(color)
                }
                ProgressView(value: min(mins, goal), total: goal).tint(color)
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text("Time near someone risky")
        } footer: {
            Text(mins >= 60
                 ? "\(ExposureTracker.durationText(mins)) since your last 2-hour break. Counts time within 6 ft of phones marked sick; possibly sick counts half."
                 : mins > 0 ? "Counts time within 6 ft of phones marked sick; possibly sick counts half. Resets after 2 hours away from them."
                 : "No time near someone with symptoms or a positive test. Resets after 2 hours away from them.")
        }
    }

    private var peersSection: some View {
        Section("Nearby phones") {
            if model.peers.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for nearby Fluni phones…").foregroundStyle(.secondary)
                }
            }
            ForEach(model.peers) { PeerRow(peer: $0) }
        }
    }

    private var demoSection: some View {
        Section {
            DisclosureGroup("Demo controls") {
                if let demoOverride { demoOverride }
                Picker("Time speed", selection: $model.speed) {
                    Text("Real time").tag(1.0)
                    Text("10×").tag(10.0)
                    Text("60×").tag(60.0)
                }
                .pickerStyle(.segmented)
                ForEach(Source.allCases, id: \.self) { s in
                    Toggle("Use \(s.rawValue)", isOn: Binding(
                        get: { model.enabled.contains(s) },
                        set: { on in if on { model.enabled.insert(s) } else { model.enabled.remove(s) } }))
                }
                Button("Reset exposure", role: .destructive) { model.resetExposure() }
            }
        } footer: {
            if model.speed > 1 { Text("Time runs \(Int(model.speed))× faster: 15 minutes takes \(Int(15 * 60 / model.speed)) seconds.") }
        }
    }

    #if DEBUG
    private var keepAwakeSection: some View {
        Section {
            Toggle("Keep screen awake", isOn: $model.keepAwake)
                .accessibilityIdentifier("keepScreenAwake")
        } footer: {
            Text("Keeps UWB ranging: iOS only ranges while FlUni is on screen.")
        }
    }
    #endif

    private var statusSection: some View {
        Section("Radios") {
            ForEach(model.status.keys.sorted(), id: \.self) { k in
                let v = model.status[k] ?? ""
                LabeledContent {
                    Text(v)
                } label: {
                    Label(k, systemImage: "circle.fill")
                        .labelStyle(DotLabelStyle(color: DeveloperView.health(v)))
                }
            }
        }
    }

    /// Green when a radio is working, red when blocked, grey otherwise.
    static func health(_ s: String) -> Color {
        if ["not allowed", "off", "unsupported", "not supported", "error"].contains(where: s.contains) { return .red }
        if ["on", "ranging", "connected"].contains(where: s.contains) { return .green }
        return .gray
    }
}

struct PeerRow: View {
    let peer: PeerState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(distanceText).font(.title2.bold()).monospacedDigit()
                    Text("Phone \(peer.id.prefix(4))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(peer.risk.label)
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(riskColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(riskColor)
            }
            HStack(spacing: 6) {
                ForEach(Source.allCases, id: \.self) { s in
                    let used = peer.estimate?.sources.contains(s) ?? false
                    Text(s.rawValue)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(used ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1), in: Capsule())
                        .foregroundStyle(used ? Color.accentColor : Color.secondary)
                        .accessibilityLabel("\(s.rawValue) \(used ? "in use" : "not in use")")
                }
                Spacer()
                if let e = peer.estimate, Fusion.isCoarseGPSOnly(e) {
                    Text("GPS only: too coarse")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                } else if peer.estimate != nil {
                    Text(peer.pClose >= 0.5 ? "Within 6 ft" : "Over 6 ft")
                        .font(.caption.bold())
                        .foregroundStyle(peer.pClose >= 0.5 ? .orange : .secondary)
                }
            }
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 2) {
                    if let e = peer.estimate {
                        Text(String(format: "Fused %.2f m ± %.2f · P(≤6 ft) %.0f%%", e.distance, e.sigma, peer.pClose * 100))
                    }
                    line("UWB", peer.uwb.map { String(format: "%.2f m", $0.distance) })
                    line("BLE", peer.rssi.map { rssi in
                        String(format: "%.0f dBm → %.1f m%@", rssi, peer.ble?.distance ?? 0,
                               peer.calibrator.isCalibrated ? " (UWB-calibrated)" : "")
                    })
                    line("GPS", peer.gps.map { String(format: "%.1f m ± %.0f", $0.distance, $0.sigma) })
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    private var distanceText: String {
        guard let e = peer.estimate else { return "Distance unknown" }
        let ft = e.distance * 3.281
        let lo = max(0, e.distance - e.sigma) * 3.281, hi = (e.distance + e.sigma) * 3.281
        // Coarse estimates (Bluetooth alone, GPS) get a range so the number isn't read as precise.
        if hi - lo >= 2 { return String(format: "≈ %.0f ft (%.0f–%.0f ft)", max(1, ft.rounded()), lo.rounded(), hi.rounded()) }
        return ft < 10 ? String(format: "%.0f ft away", max(1, ft.rounded())) : String(format: "~%.0f ft away", ft)
    }

    private var riskColor: Color {
        switch peer.risk {
        case .none: return .green
        case .possible: return .orange
        case .contagious: return .red
        }
    }

    private func line(_ name: String, _ value: String?) -> some View {
        Text("\(name)  \(value ?? "—")")
    }
}

/// Advice lines: small leading arrow, text wraps under itself.
private struct AdviceLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.caption)
            configuration.title
        }
    }
}

private struct DotLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.font(.system(size: 8)).foregroundStyle(color)
            configuration.title
        }
    }
}
