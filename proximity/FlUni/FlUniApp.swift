import SwiftUI
import UserNotifications

@main
/// FlUni, the student app. The test harness (Harness/) shares Core/ and SharedUI/ with it.
struct FlUniApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    private static let sharedModel = ProximityModel()
    @StateObject private var model = FlUniApp.sharedModel
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var started = false
    @StateObject private var router = AppRouter.shared
    @StateObject private var reportStore = SelfReportStore()
    @Environment(\.scenePhase) private var phase
    /// Lisa's opening animation, played each time the student opens FlUni (Core/IntroGate.swift); off for UI
    /// tests and unit-test hosts so they never wait on it.
    @State private var showIntro = false
    @State private var introGate = IntroGate()
    private let introAllowed: Bool

    init() {
        #if DEBUG
        // Test-only (XCUITest sets these environment variables; launch arguments can't trigger them). Debug builds only.
        let env = ProcessInfo.processInfo.environment
        if env["FLUNI_UITEST_RESET"] == "1" { SettingsView.eraseLocalData() }
        skipRadios = env["FLUNI_UITEST_NO_RADIOS"] == "1" || PreviewHook.prepare()  // preview: seeded state, radios off
        #else
        skipRadios = false
        #endif
        RouteInbox.handler = { AppRouter.shared.handle($0) }
        Self.styleNavigationBars()
        ModelFeed.shared.attach(FlUniApp.sharedModel)  // what screens draw from, without the per-tick churn  // also delivers a tap that cold-launched the app
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
        introAllowed = !skipRadios && !LaunchMode.isUnitTestHost
    }
    private let skipRadios: Bool  // test-only: UI tests never broadcast
    @State private var introRun = 0

    private func introPhase(_ p: ScenePhase) {
        let phase: IntroGate.Phase = p == .active ? .active : p == .background ? .background : .inactive
        guard introGate.phase(phase), introAllowed else { return }
        introRun += 1
        showIntro = true
    }

    private var needsOnboarding: Bool { !hasOnboarded && !LaunchMode.isUnitTestHost }

    var body: some Scene {
        WindowGroup {
            Group {
                if needsOnboarding {
                    OnboardingView { hasOnboarded = true; startOnce(); if started { model.resume() } }  // resume: radios are off after "Delete my data"
                } else {
                    TabView(selection: $router.tab) {
                        TodayView(model: model, store: reportStore)
                            .tabItem { Label("Today", systemImage: "calendar.day.timeline.left") }
                            .tag(AppRouter.Tab.today)
                            .accessibilityIdentifier("tab.today")
                        // The heat map team's real campus map, unchanged inside.
                        BundledMapView()
                            .background(Theme.paper.ignoresSafeArea())
                            .tabItem { Label("Campus", systemImage: "map") }
                            .tag(AppRouter.Tab.campus)
                            .accessibilityIdentifier("tab.campus")
                        YouView(model: model, store: reportStore)
                            .tabItem { Label("You", systemImage: "person") }
                            .tag(AppRouter.Tab.you)
                            .accessibilityIdentifier("tab.you")
                    }
                    .tint(Theme.ink)
                    .onAppear {
                        startOnce(); router.becomeReady()
                        #if DEBUG
                        model.startDemoPeerFromLaunchArguments()  // -demoPeer contagious@0.5: watch p climb live
                        #endif
                    }
                    // At the tab level, so the close contact opens on Today from whichever tab is open.
                    .onChange(of: model.exposure.level) { old, new in
                        if new == .closeContact && old < .closeContact { router.showCloseContact() }
                    }
                }
            }
            #if DEBUG
            .modifier(PreviewHookModifier(model: model, store: reportStore))
            #endif
            // Lisa's opening animation over whatever the first screen is (design pass).
            // A new id each time restarts it from the poster, however quickly the app came up.
            .overlay { if showIntro { LaunchIntro { showIntro = false }.id(introRun) } }
            .onAppear { introPhase(phase) }
            // Forced light: the campfire palette is only defined and contrast-checked on warm paper.
            .preferredColorScheme(.light)
            // Sheets, Done / Cancel and links use ink, not system blue (blue on paper is only 3.8:1).
            .tint(Theme.ink)
            // The app may be killed in the background: save an exposure that is still going on, so a relaunch continues it.
            .onChange(of: phase) { _, p in
                if p == .background { model.exposureHistory.saveOngoing() }
                introPhase(p)
            }
            // Debug builds only: the demo time speed survives relaunch. Release builds always run at 1x.
            .onChange(of: model.speed) { _, s in
                #if DEBUG
                UserDefaults.standard.set(s, forKey: "demoSpeed")
                #endif
            }
        }
    }

    /// Navigation titles in the Fraunces serif, ink on paper, so "You" and "Settings" match the rest.
    private static func styleNavigationBars() {
        let ink = UIColor(Theme.ink)
        let a = UINavigationBarAppearance()
        a.configureWithTransparentBackground()
        a.backgroundColor = UIColor(Theme.paper)
        if let large = UIFont(name: Face.serif, size: 34), let small = UIFont(name: Face.serif, size: 17) {
            a.largeTitleTextAttributes = [.font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: large), .foregroundColor: ink]
            a.titleTextAttributes = [.font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: small), .foregroundColor: ink]
        }
        let bar = UINavigationBar.appearance()
        bar.standardAppearance = a
        bar.compactAppearance = a
        let scrolled = a.copy()
        scrolled.configureWithDefaultBackground()
        scrolled.backgroundColor = UIColor(Theme.paper).withAlphaComponent(0.94)
        scrolled.largeTitleTextAttributes = a.largeTitleTextAttributes
        scrolled.titleTextAttributes = a.titleTextAttributes
        bar.standardAppearance = scrolled
        bar.scrollEdgeAppearance = a
    }

    private func startOnce() {
        // Unit tests run inside this app; don't start radios there.
        guard !LaunchMode.isUnitTestHost, !skipRadios else { return }
        Self.startDetection()
    }

    /// Idempotent (model.start() only runs once).
    private static func startDetection() {
        let model = sharedModel
        #if DEBUG
        // Debug builds obey the Mac tools' test arguments (-risk, -speed, ...) so phone tests need no taps. A test
        // launch keeps nothing: saved status, pause, self-report and history are neither read nor written.
        model.acceptsLaunchArguments = LaunchMode.isTestLaunch
        #else
        model.acceptsLaunchArguments = false  // the product ignores test launch arguments
        #endif
        #if DEBUG
        let saved = UserDefaults.standard.double(forKey: "demoSpeed")
        if saved > 1 { model.speed = saved }
        #endif
        model.worksInBackground = true  // Bluetooth background modes + state restoration (project.yml)
        model.start()
    }
}
