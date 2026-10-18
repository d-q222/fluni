import Foundation

// The in-app alerts: one entry for every alert notification FlUni posts (close contact, heads-up, walk-in), with
// the same title and body as the notification (NotificationRoute.text, details on), newest first, read or unread.
// Pure; FlUni keeps it in a small file on the phone for 24 hours. It's what an in-app alert view (an unread chip,
// Lisa's tissue-pull animation) binds to, so its unread count always matches the notifications that were sent.

extension NotificationKind: Codable {}

struct InboxAlert: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: NotificationKind
    let title: String
    let body: String
    let at: Date
    /// Walk-in alerts only: the building, for "Show on map".
    let buildingID: String?
    var read = false
}

struct AlertInbox: Codable, Equatable {
    static let retention: TimeInterval = 24 * 3600

    /// Newest first.
    private(set) var alerts: [InboxAlert] = []

    var unread: [InboxAlert] { alerts.filter { !$0.read } }
    var unreadCount: Int { alerts.reduce(0) { $0 + ($1.read ? 0 : 1) } }

    /// The kind of in-app alert a notified alert level is: a heads-up or a close contact. Nil for `.none`.
    static func kind(for level: AlertLevel) -> NotificationKind? {
        switch level {
        case .none: return nil
        case .nearby: return .nearby
        case .closeContact: return .closeContact
        }
    }

    /// Adds an alert with the notification's own words (details on). Returns its id.
    @discardableResult
    mutating func post(_ kind: NotificationKind, buildingID: String? = nil, buildingName: String? = nil,
                       at now: Date, id: UUID = UUID()) -> UUID {
        let t = NotificationRoute.text(kind: kind, detailed: true, buildingName: buildingName)
        let a = InboxAlert(id: id, kind: kind, title: t.title, body: t.body, at: now,
                           buildingID: kind == .building ? buildingID : nil)
        // Newest first; an alert stamped earlier than the newest (clock step back) still lands in time order.
        let i = alerts.firstIndex { $0.at <= now } ?? alerts.count
        alerts.insert(a, at: i)
        return a.id
    }

    /// The same decision that posts a notification (AlertNotifier.next): when it says notify, the inbox gets one too.
    /// Returns the new notified level to keep, exactly as AlertNotifier does.
    mutating func observe(level: AlertLevel, notified: AlertLevel, at now: Date) -> AlertLevel {
        let next = AlertNotifier.next(level: level, notified: notified)
        if let l = next.notify, let k = Self.kind(for: l) { post(k, at: now) }
        return next.notified
    }

    mutating func markRead(_ id: UUID) {
        guard let i = alerts.firstIndex(where: { $0.id == id }) else { return }
        alerts[i].read = true
    }

    /// Marks every alert of `kind` read (all of them with nil).
    mutating func markAllRead(_ kind: NotificationKind? = nil) {
        for i in alerts.indices where kind == nil || alerts[i].kind == kind { alerts[i].read = true }
    }

    /// Drops alerts older than 24 hours (exactly 24 hours is kept).
    mutating func prune(now: Date) {
        alerts.removeAll { now.timeIntervalSince($0.at) > Self.retention }
    }

    static func encode(_ inbox: AlertInbox) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return try e.encode(inbox)
    }

    /// Unreadable data gives an empty inbox rather than a crash.
    static func decode(_ data: Data) -> AlertInbox {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return (try? d.decode(AlertInbox.self, from: data)) ?? AlertInbox()
    }
}
