import Foundation
import SwiftUI

/// The building heat the Map tab and the walk-in warning read. Starts from the copy built into the app, then
/// swaps in the laptop's newer file whenever one can be fetched (at launch, when the run changes, and every minute).
@MainActor
final class BuildingHeatStore: ObservableObject {
    static let shared = BuildingHeatStore()

    enum Source { case builtIn, live }

    @Published private(set) var heat: BuildingHeat?
    @Published private(set) var source = Source.builtIn
    /// A plain sentence about the last failed refresh; empty when fine.
    @Published private(set) var status = ""

    private let clock = SimClock.shared
    private var timer: Timer?
    private var lastRun: String
    /// The copy built into the app. Live files may only refresh numbers on top of it.
    private var bundled: BuildingHeat?

    private init() {
        lastRun = clock.runID
        if let url = Bundle.main.url(forResource: "building_heat", withExtension: "csv"),
           let data = try? Data(contentsOf: url), let h = try? BuildingHeat.parse(data) {
            heat = h
            bundled = h
            clock.adopt(h.timeRange)
        } else {
            status = "The built-in building data couldn't be read."
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    /// Same scheme, host and port as the saved heat map address; path heatmap/out/<run>/building_heat.csv.
    static func url(heatmapURL: String, runID: String) -> URL? {
        guard let src = URLComponents(string: heatmapURL), let scheme = src.scheme, let host = src.host, !runID.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = scheme; c.host = host; c.port = src.port
        c.path = "/heatmap/out/\(runID)/building_heat.csv"
        return c.url
    }

    /// Try the laptop. Failure keeps whatever is showing and sets a quiet, plain message.
    func refresh() async {
        let saved = UserDefaults.standard.string(forKey: "heatmapURL") ?? ""
        let run = clock.runID
        if run != lastRun { lastRun = run; if source == .live { source = .builtIn } }
        guard let url = Self.url(heatmapURL: saved, runID: run) else { status = ""; return }  // no laptop set: built-in is fine
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.httpMethod = "GET"
        do {
            let (stream, resp) = try await URLSession.shared.bytes(for: req)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                status = h.statusCode == 404 ? "The laptop has no building file for run \(run) yet." : "The laptop answered with an error (\(h.statusCode))."
                return
            }
            guard resp.expectedContentLength <= Int64(BuildingHeat.maxLiveBytes) else { status = "The laptop's building file is too big, so it was ignored."; return }
            var data = Data()
            for try await byte in stream {
                data.append(byte)
                if data.count > BuildingHeat.maxLiveBytes { status = "The laptop's building file is too big, so it was ignored."; return }
            }
            let parsed: BuildingHeat
            do { parsed = try BuildingHeat.parse(data) } catch { status = "That file isn't a building heat file, so it was ignored."; return }
            guard !parsed.snapshots.isEmpty else { status = "The laptop's building file is empty."; return }
            guard run == clock.runID else { return }  // the run changed while we were fetching
            guard let bundled, let merged = BuildingHeat.merged(bundled: bundled, live: parsed) else {
                status = "The laptop's building file doesn't match the buildings in this app, so it was ignored."; return
            }
            heat = merged; source = .live; status = ""
            clock.adopt(merged.timeRange)  // within the built-in range by construction
        } catch {
            status = PSickLoader.message(for: error).replacingOccurrences(of: "the campus model", with: "the live map")
        }
    }
}
