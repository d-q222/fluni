import UIKit
import UserNotifications

/// Where a tapped notification's Route goes. The app sets `handler` at launch; a tap that arrives before that
/// (cold launch) waits in `pending` and is delivered as soon as the handler is set.
@MainActor
enum RouteInbox {
    static var pending: Route?
    static var handler: ((Route) -> Void)? {
        didSet { if let h = handler, let p = pending { pending = nil; h(p) } }
    }
    static func post(_ r: Route) {
        guard r != .ignore else { return }
        if let handler { handler(r) } else { pending = r }
    }
}

/// Notification wording, categories (quick actions) and the lock-screen setting.
enum AppNotifications {
    static let detailsKey = "showDetailsOnLockScreen"  // Settings toggle, default ON

    static var detailed: Bool { UserDefaults.standard.object(forKey: detailsKey) as? Bool ?? true }

    /// Content with category and a tiny userInfo: the kind, plus building_id for building warnings. Nothing else.
    static func content(kind: NotificationKind, buildingID: String? = nil, buildingName: String? = nil, sick: Bool = false) -> UNMutableNotificationContent {
        let t = NotificationRoute.text(kind: kind, detailed: detailed, buildingName: buildingName, sick: sick)
        let c = UNMutableNotificationContent()
        c.title = t.title
        c.body = t.body
        c.sound = .default
        c.categoryIdentifier = kind.categoryID
        c.userInfo = buildingID.map { ["kind": kind.rawValue, "building_id": $0] } ?? ["kind": kind.rawValue]
        return c
    }

    static func register() {
        func action(_ id: String, _ title: String) -> UNNotificationAction {
            UNNotificationAction(identifier: id, title: title, options: [.foreground])
        }
        let placeholder = "You have an update."
        func category(_ k: NotificationKind, _ actions: [UNNotificationAction]) -> UNNotificationCategory {
            UNNotificationCategory(identifier: k.categoryID, actions: actions, intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: placeholder, options: [.hiddenPreviewsShowTitle])
        }
        UNUserNotificationCenter.current().setNotificationCategories([
            category(.closeContact, [action(NotificationAction.reportSymptoms, "Report symptoms"),
                                     action(NotificationAction.seeAdvice, "See advice")]),
            category(.nearby, [UNNotificationAction(identifier: NotificationAction.gotIt, title: "Got it", options: [])]),
            category(.building, [action(NotificationAction.showOnMap, "Show on map")]),
        ])
    }
}

/// Shows alert banners even while the app is open (it usually is, during the demo), and routes taps.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        AppNotifications.register()
        return true
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let route = NotificationRoute.route(userInfo: response.notification.request.content.userInfo,
                                            actionIdentifier: response.actionIdentifier)
        Task { @MainActor in RouteInbox.post(route); done() }
    }
}
