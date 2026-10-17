import Foundation
import SwiftUI

/// Demo persona state: which sim agent this phone plays and at what sim time. Persisted.
/// Only the demo uses it; with no persona the app shows just its own estimate.
@MainActor
final class PSickStore: ObservableObject {
    static let shared = PSickStore()

    @Published private(set) var feed: PSickFeed?
    @Published private(set) var status = ""
    @Published private(set) var loading = false
    @Published var agent: String { didSet { d.set(agent, forKey: "psickAgent") } }
    @Published var simTime: Double { didSet { d.set(simTime, forKey: "psickSimTime") } }
    @Published var follow: Bool { didSet { d.set(follow, forKey: "psickFollow"); restartTimer() } }

    private let d = UserDefaults.standard
    private var timer: Timer?

    private init() {
        agent = d.string(forKey: "psickAgent") ?? ""
        simTime = d.object(forKey: "psickSimTime") as? Double ?? 0
        follow = d.bool(forKey: "psickFollow")
        restartTimer()
    }

    /// The official number, only with a persona set and the file loaded.
    var campusP: Double? {
        guard !agent.isEmpty, let feed, feed.agents.contains(agent) else { return nil }
        return feed.p(agent: agent, at: simTime)
    }

    func reload() async {
        loading = true; status = ""
        defer { loading = false }
        do {
            let f = try await PSickLoader.load()
            feed = f
            if let r = f.timeRange, !(r ~= simTime) { simTime = r.lowerBound }
            status = f.rejected > 0 ? "Loaded; \(f.rejected) bad rows skipped." : ""
        } catch let e as PSickLoader.Failure { status = e.message } catch { status = error_(error) }
    }

    func clearPersona() { agent = ""; follow = false }

    private func error_(_ e: Error) -> String { PSickLoader.message(for: e) }

    /// "Follow the map": 2 sim minutes per real second (the heat map embed's speed), looping at the end.
    private func restartTimer() {
        timer?.invalidate(); timer = nil
        guard follow else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.feed?.timeRange else { return }
                let next = self.simTime + 120
                self.simTime = next > r.upperBound ? r.lowerBound : next
            }
        }
    }
}
