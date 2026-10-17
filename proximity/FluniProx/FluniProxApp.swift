import SwiftUI
import UserNotifications

@main
struct FluniProxApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = ProximityModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView(model: model)
                    .tabItem { Label("Proximity", systemImage: "dot.radiowaves.left.and.right") }
                HeatmapView()
                    .tabItem { Label("Heat map", systemImage: "map") }
            }
                .onAppear {
                    // Unit tests run inside this app; don't start radios there.
                    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { model.start() }
                }
        }
    }
}

/// Shows alert banners even while the app is open (it usually is, during the demo).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
