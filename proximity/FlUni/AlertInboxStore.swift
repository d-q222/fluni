import Foundation

/// Keeps the in-app alerts (Core/AlertInbox.swift) on this phone: a small JSON file in Application Support,
/// pruned to 24 hours, wiped by "Delete my data". Fed from the same places that post notifications: the model's
/// alert gate (ProximityModel.onAlert) and the walk-in warning (WalkInMonitor).
@MainActor
final class AlertInboxStore: ObservableObject {
    static let shared = AlertInboxStore()

    @Published private(set) var inbox = AlertInbox()
    private let url: URL?

    /// None on a test launch, so a test run neither reads nor writes the owner's alerts.
    nonisolated static var defaultURL: URL? {
        guard !LaunchMode.isTestLaunch else { return nil }
        return try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("alert-inbox.json")
    }

    init(url: URL? = AlertInboxStore.defaultURL) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url) { inbox = AlertInbox.decode(data) }
        inbox.prune(now: Date())
        NotificationCenter.default.addObserver(forName: SelfReportStore.didDeleteData, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.forget() }
        }
    }

    /// A notification of this kind was just posted (ProximityModel.onAlert).
    func alerted(_ kind: NotificationKind, now: Date = Date()) {
        update { $0.post(kind, at: now) }
    }

    /// A walk-in notification for this building was just posted.
    func walkedIn(buildingID: String, name: String, now: Date = Date()) {
        update { $0.post(.building, buildingID: buildingID, buildingName: name, at: now) }
    }

    func markRead(_ id: UUID) { update { $0.markRead(id) } }
    func markAllRead(_ kind: NotificationKind? = nil) { update { $0.markAllRead(kind) } }

    private func update(_ change: (inout AlertInbox) -> Void) {
        var i = inbox
        change(&i)
        i.prune(now: Date())
        guard i != inbox else { return }
        inbox = i
        if let url, let data = try? AlertInbox.encode(i) { try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen]) }
    }

    func forget() {
        inbox = AlertInbox()
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}
