import SwiftUI
import UserNotifications

@main
/// FlUni, the student app. The test harness (Harness/) shares Core/ and SharedUI/ with it.
struct FlUniApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = ProximityModel()
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var started = false

    private var needsOnboarding: Bool { !hasOnboarded && !LaunchMode.isUnitTestHost }

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
        model.acceptsLaunchArguments = false  // the product ignores test launch arguments
        model.start()
    }
}
