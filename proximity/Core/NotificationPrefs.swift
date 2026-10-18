import Foundation
import UserNotifications

/// Which FlUni system notifications the student wants (Settings → Notifications). Every kind is on unless turned
/// off. These only control system notifications: the in-app tissue alert and Today's strip always show. Kept in
/// UserDefaults, so Delete my data (which erases the app's defaults domain) turns them all back on.
struct NotificationPrefs {
    var defaults: UserDefaults = .standard

    static func key(_ kind: NotificationKind) -> String { "notify.\(kind.rawValue)" }

    func allows(_ kind: NotificationKind) -> Bool { defaults.object(forKey: Self.key(kind)) as? Bool ?? true }

    func set(_ kind: NotificationKind, _ on: Bool) { defaults.set(on, forKey: Self.key(kind)) }
}

/// The one door for every FlUni system notification: the heads-up and close contact from the tick (foreground,
/// background wake-up or relaunch, all through UNPoster) and the walk-in warning (WalkInMonitor). A kind the
/// student turned off stops here. An allowed one is handed to iOS inside a background window, so a wake-up that
/// crosses a threshold can't be suspended halfway through posting it (flu-offdetect).
final class SystemNotifier {
    static let shared = SystemNotifier()

    typealias Deliver = (UNNotificationRequest, @escaping () -> Void) -> Void

    var prefs: NotificationPrefs
    private let deliver: Deliver

    init(prefs: NotificationPrefs = NotificationPrefs(), deliver: @escaping Deliver = SystemNotifier.toNotificationCenter) {
        self.prefs = prefs
        self.deliver = deliver
    }

    /// Posts unless the student turned `kind` off. Returns whether it was handed on.
    @discardableResult
    func post(_ kind: NotificationKind, content: @autoclosure () -> UNNotificationContent,
              identifier: String = UUID().uuidString) -> Bool {
        guard prefs.allows(kind) else { return false }
        let window = BackgroundWindow.begin("fluni.notify")
        deliver(UNNotificationRequest(identifier: identifier, content: content(), trigger: nil)) { window.end() }
        return true
    }

    static func toNotificationCenter(_ r: UNNotificationRequest, _ done: @escaping () -> Void) {
        UNUserNotificationCenter.current().add(r) { _ in done() }
    }
}
