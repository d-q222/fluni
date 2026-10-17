import SwiftUI
import UserNotifications

@main
/// FlUni, the student app. The test harness (Harness/) shares Core/ and SharedUI/ with it.
struct FlUniApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = ProximityModel()
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var started = false
    @State private var showCloseContact = false
    @Environment(\.scenePhase) private var phase

    init() { BuildingWatcher.shared.start() }  // iOS may relaunch the app for a building entry

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
                        CampusMapView()
                            .tabItem { Label("Map", systemImage: "map") }
                        MeView(model: model)
                            .tabItem { Label("Me", systemImage: "person.crop.circle") }
                    }
                    .tint(Theme.ink)
                    .onAppear(perform: startOnce)
                    // At the tab level so the close-contact moment shows whichever tab is open.
                    .onChange(of: model.exposure.level) { old, new in
                        if new == .closeContact && old < .closeContact { showCloseContact = true }
                    }
                    .fullScreenCover(isPresented: $showCloseContact) { CloseContactSheet { showCloseContact = false } }
                }
            }
            // Forced light: the campfire palette is only defined and contrast-checked on warm paper.
            .preferredColorScheme(.light)
            // Sheets, Done / Cancel and links use ink, not system blue (blue on paper is only 3.8:1).
            .tint(Theme.ink)
            // The app may be killed in the background: save an exposure that is still going on.
            .onChange(of: phase) { _, p in if p == .background { model.exposureHistory.finishOngoing() } }
        }
    }

    private func startOnce() {
        // Unit tests run inside this app; don't start radios there.
        guard !started, !LaunchMode.isUnitTestHost else { return }
        started = true
        model.acceptsLaunchArguments = false  // the product ignores test launch arguments
        model.sharesLocationWithPeers = false  // privacy promise: precise location never leaves the phone
        model.start()
    }
}
