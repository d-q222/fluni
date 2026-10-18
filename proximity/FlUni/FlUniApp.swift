import SwiftUI
import UserNotifications

@main
/// FlUni, the student app. The test harness (Harness/) shares Core/ and SharedUI/ with it.
struct FlUniApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    private static let sharedModel = ProximityModel()
    /// Deliberately not observed here: the scene body holds the TabView, and observing the model redrew it (and
    /// rebuilt UIKit's tab bar) on every model change, i.e. every 1 s tick near someone sick. The views that show
    /// model state observe it themselves; ModelReactions below handles the app-level reactions.
    private var model: ProximityModel { Self.sharedModel }
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var started = false
    @StateObject private var router = AppRouter.shared
    @StateObject private var reportStore = SelfReportStore()
    private let introAllowed: Bool

    init() {
        UITabBar.appearance().isHidden = true  // Lisa's tissue box is the tab bar (AppRoot); no system bar, not even for VoiceOver
        #if DEBUG
        // Test-only (XCUITest sets these environment variables; launch arguments can't trigger them). Debug builds only.
        let env = ProcessInfo.processInfo.environment
        if env["FLUNI_UITEST_RESET"] == "1" { SettingsView.eraseLocalData() }
        skipRadios = env["FLUNI_UITEST_NO_RADIOS"] == "1"
        #else
        skipRadios = false
        #endif
        FluniType.styleNavigationBars()   // Fredoka titles (design pass)
        RouteInbox.handler = { AppRouter.shared.handle($0) }  // also delivers a tap that cold-launched the app
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

    var body: some Scene {
        WindowGroup {
            // The window's content is its own view, so the state it shows (tab, sheets, intro) redraws it reliably;
            // App-level @State/@StateObject changes don't always reach a WindowGroup's content (the tissue tabs
            // lifted but the screen didn't switch, and the intro never appeared).
            AppRoot(model: model, router: router, reportStore: reportStore, introAllowed: introAllowed,
                    startOnce: startOnce, afterOnboarding: { if started { model.resume() } })
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
        // Room-air term from the building this phone is in (its own fix; tools/make_building_rooms.py).
        if let url = Bundle.main.url(forResource: "building_rooms", withExtension: "csv"), let data = try? Data(contentsOf: url) {
            model.roomContext = RoomContext.parse(data)
        }
        model.start()
    }
}

/// The app-level reaction to the model, in a view of its own so only this empty view redraws on a model change.
/// Observes the model for the tissue alert only, so the scene body above stays unobserved (see `model`).
private struct TissueAlertHost: View {
    @ObservedObject var model: ProximityModel
    let onToday: Bool
    var body: some View {
        // flu-persist: "already read" lives in the model's saved alert state, so a relaunch doesn't pop it again.
        TissueAlert(level: model.exposure.level, visible: onToday && model.myRisk == .none,
                    isRead: { model.isAlertRead($0) }, onRead: { model.markAlertRead($0) })
    }
}

private struct ModelReactions: View {
    @ObservedObject var model: ProximityModel
    let onCloseContact: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: model.exposure.level) { old, new in
                if new == .closeContact && old < .closeContact { onCloseContact() }
            }
            // Debug builds only: the demo time speed survives relaunch. Release builds always run at 1x.
            .onChange(of: model.speed) { _, s in
                #if DEBUG
                UserDefaults.standard.set(s, forKey: "demoSpeed")
                #endif
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#if DEBUG
/// Debug only: `-perfTour YES` walks the app the way a person would (Map, Me, the report sheet open and closed,
/// back to Today) on a loop, so Instruments can record tab switches and sheets on a phone with nobody tapping.
/// Each step is a Points of Interest interval named after it. Pair it with `-skipOnboarding YES` (a test launch
/// keeps nothing) so the owner's data is never read or written.
@MainActor
enum PerfTour {
    static func startIfAsked(_ router: AppRouter) {
        guard UserDefaults.standard.bool(forKey: "perfTour") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))  // after the intro
            let steps: [(String, () -> Void)] = [
                ("tab map", { router.tab = .map }), ("tab me", { router.tab = .me }),
                ("sheet open", { router.sheet = .reportSymptoms }), ("sheet close", { router.sheet = nil }),
                ("tab today", { router.tab = .today }),
            ]
            for _ in 0 ..< 5 {
                for (name, step) in steps {
                    let s = Signposts.poi.beginInterval("tour", "\(name)")
                    step()
                    try? await Task.sleep(for: .seconds(1.5))
                    Signposts.poi.endInterval("tour", s)
                }
            }
            Signposts.poi.emitEvent("tour done")
        }
    }
}
#endif

/// Everything inside FlUni's window: onboarding or the tissue-tab screens, sheets, and Lisa's intro on every open.
private struct AppRoot: View {
    let model: ProximityModel
    @ObservedObject var router: AppRouter
    @ObservedObject var reportStore: SelfReportStore
    let introAllowed: Bool
    let startOnce: () -> Void
    let afterOnboarding: () -> Void
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @AppStorage(AppearanceChoice.key) private var appearanceRaw = AppearanceChoice.system.rawValue
    private var appearance: AppearanceChoice { AppearanceChoice(rawValue: appearanceRaw) ?? .system }
    @Environment(\.scenePhase) private var phase
    /// Lisa's opening animation, played each time the student opens FlUni (Core/IntroGate.swift); off for UI
    /// tests and unit-test hosts so they never wait on it.
    @State private var introGate = IntroGate()

    private var needsOnboarding: Bool { !hasOnboarded && !LaunchMode.isUnitTestHost }

    private func introPhase(_ p: ScenePhase) {
        let phase: IntroGate.Phase = p == .active ? .active : p == .background ? .background : .inactive
        guard introGate.phase(phase), introAllowed else { return }
        IntroController.shared.play()
    }

    var body: some View {
        Group {
            if needsOnboarding {
                OnboardingView { hasOnboarded = true; startOnce(); afterOnboarding() }  // resume: radios are off after "Delete my data"
            } else {
                // Lisa's tissue box is the tab bar. No system TabView: hidden under her drawing it still showed
                // its own Today/Map/Me buttons to VoiceOver and kept hers out of the accessibility tree. All three
                // screens stay alive (the map's web view isn't reloaded); only the selected one is visible,
                // tappable and accessible.
                // Only the map stays alive when hidden (its web view is slow to load). Today and Me are drawn only
                // while selected: their UIKit-hosted navigation stacks ignored SwiftUI opacity, so a hidden Today
                // stayed on top of the other tabs.
                // A real TabView manages each tab's navigation stack (a hand-made ZStack left Today's UIKit-hosted
                // stack on screen after switching). Its own bar is hidden (here and via UITabBar appearance, which
                // also takes it out of VoiceOver); Lisa's tissue box is drawn over it.
                TabView(selection: $router.tab) {
                    TodayView(model: model, store: reportStore).tag(AppRouter.Tab.today).toolbar(.hidden, for: .tabBar)  // scroll room: tissueTabBarScrollRoom
                    BundledMapView().tag(AppRouter.Tab.map).toolbar(.hidden, for: .tabBar).tissueTabBarInset()
                    MeView(model: model, store: reportStore).tag(AppRouter.Tab.me).toolbar(.hidden, for: .tabBar)  // scroll room: tissueTabBarScrollRoom
                }
                .overlay { TissueTabBar(selection: $router.tab) }
                // Lisa's tissue alert: pops out of the tab-bar box on Today for a new alert (TissueAlert.swift).
                .overlay { TissueAlertHost(model: model, onToday: router.tab == .today) }
                .tint(Theme.ink)
                .onAppear {
                    Signposts.poi.emitEvent("tabs on screen")
                    startOnce(); router.becomeReady()
                    #if DEBUG
                    model.startDemoPeerFromLaunchArguments()  // -demoPeer contagious@0.5: watch p climb live
                    PerfTour.startIfAsked(router)
                    // -keepAwake YES: the screen doesn't auto-lock while FlUni is open (Instruments needs it unlocked).
                    if UserDefaults.standard.bool(forKey: "keepAwake") { UIApplication.shared.isIdleTimerDisabled = true }
                    #endif
                }
                // At the tab level so the close-contact moment shows whichever tab is open.
                .background { ModelReactions(model: model, onCloseContact: { router.showCloseContact() }) }
                .fullScreenCover(isPresented: Binding(get: { router.sheet == .closeContact }, set: { if !$0 { router.sheet = nil } })) {
                    CloseContactSheet { router.sheet = nil }
                }
                .sheet(isPresented: Binding(get: { router.sheet == .reportSymptoms }, set: { if !$0 { router.sheet = nil } })) {
                    ReportSheet(kind: .symptoms, model: model, store: reportStore)
                }
            }
        }
        // Lisa's opening animation over whatever the first screen is (design pass).
        // A new id each time restarts it from the poster, however quickly the app came up.
        // UIKit's own lifecycle drives the intro: SwiftUI's scenePhase reported "inactive" here at launch and never
        // delivered the change to "active", so the intro never played. IntroGate ignores repeats.
        .onAppear { if UIApplication.shared.applicationState == .active { introPhase(.active) } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in introPhase(.active) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in introPhase(.background) }
        // Settings > Appearance: System / Light / Dark (the intro's own window follows it too: IntroController).
        .preferredColorScheme(appearance.colorScheme)
        // Sheets, Done / Cancel and links use ink, not system blue (blue on paper is only 3.8:1).
        .tint(Theme.ink)
        // The app may be killed in the background: save an exposure that is still going on, so a relaunch continues it.
        .onChange(of: phase) { _, p in
            if p == .background { model.exposureHistory.saveOngoing() }
            introPhase(p)
        }
    }
}

/// Plays Lisa's intro in its own window above everything (tab bar, sheets), not as a SwiftUI overlay: overlays on
/// the window's root under a TabView never appeared. Touches pass through to the app; the window goes when done.
@MainActor
final class IntroController {
    static let shared = IntroController()
    private var window: UIWindow?
    private var run = 0

    func play() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        run += 1
        let thisRun = run
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.isUserInteractionEnabled = false
        w.backgroundColor = .clear
        w.overrideUserInterfaceStyle = AppearanceChoice.saved.uiStyle  // follows Settings > Appearance
        let host = UIHostingController(rootView: LaunchIntro { [weak self] in self?.done(thisRun) })
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        window?.isHidden = true
        window = w
    }

    private func done(_ r: Int) {
        guard r == run else { return }
        window?.isHidden = true
        window = nil
    }
}
