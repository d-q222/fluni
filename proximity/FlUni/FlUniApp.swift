import SwiftUI
import UserNotifications

@main
/// FlUni, the student app. The test harness (Harness/) shares Core/ and SharedUI/ with it.
struct FlUniApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    private static let sharedModel = ProximityModel()
    @StateObject private var model = FlUniApp.sharedModel
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var showCloseContact = false
    @Environment(\.scenePhase) private var phase

    init() {
        // Test-only (XCUITest sets these environment variables; launch arguments can't trigger them).
        let env = ProcessInfo.processInfo.environment
        if env["FLUNI_UITEST_RESET"] == "1" { SettingsView.eraseLocalData() }
        skipRadios = env["FLUNI_UITEST_NO_RADIOS"] == "1"
        // iOS may relaunch the app for a building entry; UI tests never start location work.
        if !skipRadios { BuildingWatcher.shared.start() }
        // iOS can also relaunch FlUni in the background for a Bluetooth event after it ended it. No window
        // appears then, so start detection as soon as launching finishes rather than on first appearance.
        if !skipRadios, !LaunchMode.isUnitTestHost {
            NotificationCenter.default.addObserver(forName: UIApplication.didFinishLaunchingNotification,
                                                   object: nil, queue: nil) { _ in
                // Posted on the main thread (queue nil runs it right there).
                MainActor.assumeIsolated {
                    if UserDefaults.standard.bool(forKey: "hasOnboarded") { FlUniApp.startDetection() }
                }
            }
        }
    }
    private let skipRadios: Bool  // test-only: UI tests never broadcast

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
                            .accessibilityIdentifier("tab.today")
                        CampusMapView()
                            .tabItem { Label("Map", systemImage: "map") }
                            .accessibilityIdentifier("tab.map")
                        MeView(model: model)
                            .tabItem { Label("Me", systemImage: "person.crop.circle") }
                            .accessibilityIdentifier("tab.me")
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
        guard !LaunchMode.isUnitTestHost, !skipRadios else { return }
        Self.startDetection()
    }

    /// Idempotent (model.start() only runs once).
    private static func startDetection() {
        let model = sharedModel
        model.acceptsLaunchArguments = false  // the product ignores test launch arguments
        model.sharesLocationWithPeers = false  // privacy promise: precise location never leaves the phone
        model.worksInBackground = true  // Bluetooth background modes + state restoration (project.yml)
        model.start()
    }
}
