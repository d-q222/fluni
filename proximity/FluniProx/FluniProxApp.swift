import SwiftUI
import UserNotifications

@main
struct FluniProxApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = ProximityModel()
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var started = false

    /// Test launches (Mac tools) and the unit-test host never see onboarding.
    private var needsOnboarding: Bool { !hasOnboarded && !LaunchMode.isTestLaunch && !LaunchMode.isUnitTestHost }

    var body: some Scene {
        WindowGroup {
            Group {
                if needsOnboarding {
                    OnboardingView { hasOnboarded = true; startOnce() }
                } else {
                    TabView {
                        TodayView(model: model)
                            .tabItem { Label("Today", systemImage: "sun.max") }
                        HeatmapView()
                            .tabItem { Label("Map", systemImage: "map") }
                        MeView(model: model)
                            .tabItem { Label("Me", systemImage: "person.crop.circle") }
                    }
                    .tint(Theme.ink)
                    .onAppear(perform: startOnce)
                }
            }
            // Forced light: the campfire palette is only defined and contrast-checked on warm paper.
            .preferredColorScheme(.light)
        }
    }

    private func startOnce() {
        // Unit tests run inside this app; don't start radios there.
        guard !started, !LaunchMode.isUnitTestHost else { return }
        started = true
        model.start()
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
