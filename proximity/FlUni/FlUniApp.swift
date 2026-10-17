import SwiftUI
import UserNotifications

@main
/// FlUni, the student app. The test harness (Harness/) shares Core/ and SharedUI/ with it.
struct FlUniApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = ProximityModel()
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var started = false
    @StateObject private var router = AppRouter.shared
    @StateObject private var reportStore = SelfReportStore()
    @Environment(\.scenePhase) private var phase

    init() {
        #if DEBUG
        // Test-only (XCUITest sets these environment variables; launch arguments can't trigger them). Debug builds only.
        let env = ProcessInfo.processInfo.environment
        if env["FLUNI_UITEST_RESET"] == "1" { SettingsView.eraseLocalData() }
        skipRadios = env["FLUNI_UITEST_NO_RADIOS"] == "1"
        #else
        skipRadios = false
        #endif
        RouteInbox.handler = { AppRouter.shared.handle($0) }  // also delivers a tap that cold-launched the app
        // iOS may relaunch the app for a building entry; UI tests never start location work.
        if !skipRadios { BuildingWatcher.shared.start() }
    }
    private let skipRadios: Bool  // test-only: UI tests never broadcast

    private var needsOnboarding: Bool { !hasOnboarded && !LaunchMode.isUnitTestHost }

    var body: some Scene {
        WindowGroup {
            Group {
                if needsOnboarding {
                    OnboardingView { hasOnboarded = true; startOnce() }
                } else {
                    TabView(selection: $router.tab) {
                        TodayView(model: model)
                            .tabItem { Label("Today", systemImage: "sun.max") }
                            .tag(AppRouter.Tab.today)
                            .accessibilityIdentifier("tab.today")
                        CampusMapView()
                            .tabItem { Label("Map", systemImage: "map") }
                            .tag(AppRouter.Tab.map)
                            .accessibilityIdentifier("tab.map")
                        MeView(model: model)
                            .tabItem { Label("Me", systemImage: "person.crop.circle") }
                            .tag(AppRouter.Tab.me)
                            .accessibilityIdentifier("tab.me")
                    }
                    .tint(Theme.ink)
                    .onAppear { startOnce(); router.becomeReady() }
                    // At the tab level so the close-contact moment shows whichever tab is open.
                    .onChange(of: model.exposure.level) { old, new in
                        if new == .closeContact && old < .closeContact { router.sheet = .closeContact }
                    }
                    .fullScreenCover(isPresented: Binding(get: { router.sheet == .closeContact }, set: { if !$0 { router.sheet = nil } })) {
                        CloseContactSheet { router.sheet = nil }
                    }
                    .sheet(isPresented: Binding(get: { router.sheet == .reportSymptoms }, set: { if !$0 { router.sheet = nil } })) {
                        ReportSheet(kind: .symptoms, model: model, store: reportStore)
                    }
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
        guard !started, !LaunchMode.isUnitTestHost, !skipRadios else { return }
        started = true
        model.acceptsLaunchArguments = false  // the product ignores test launch arguments
        model.start()
    }
}
