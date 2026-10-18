import Foundation
import SwiftUI
import Combine

/// Demo persona state: which sim agent this phone plays. Persisted. The time it is read at is the live time
/// (SimClock), or the Demo override while that is on. With no persona the app shows just its own estimate.
@MainActor
final class PSickStore: ObservableObject {
    static let shared = PSickStore()

    @Published private(set) var feed: PSickFeed?
    @Published private(set) var status = ""
    @Published private(set) var loading = false
    @Published var agent: String { didSet { d.set(agent, forKey: "psickAgent") } }
    var simTime: Double { clock.simTime }

    private let d = UserDefaults.standard
    private let clock = SimClock.shared
    private var bag: [AnyCancellable] = []

    private init() {
        // A persona is a demo tool: Release builds never use one.
        agent = SimClock.demoAvailable ? (d.string(forKey: "psickAgent") ?? "") : ""
        // Views watching the store (the risk card) redraw when the clock moves.
        bag = [clock.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }]
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
            clock.adopt(f.timeRange)
            status = f.rejected > 0 ? "Loaded; \(f.rejected) bad rows skipped." : ""
        } catch let e as PSickLoader.Failure { status = e.message } catch { status = error_(error) }
    }

    func clearPersona() { agent = "" }

    private func error_(_ e: Error) -> String { PSickLoader.message(for: e) }
}
