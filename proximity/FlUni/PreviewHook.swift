#if DEBUG
import SwiftUI

/// Debug builds only: put the app in a known state for design screenshots, without radios.
///
///   SIMCTL_CHILD_FLUNI_PREVIEW_STATE=nearby SIMCTL_CHILD_FLUNI_PREVIEW_SCREEN=today xcrun simctl launch <udid> com.fluni.app
///
/// FLUNI_PREVIEW_STATE: allClear | nearby | closeContact | walkIn | paused | sick (= sickPossible) | sickPossible |
///   sickPositive | onboarding
/// FLUNI_PREVIEW_SCREEN: today (default) | me | closeSheet | report | positive | history | settings | how | calc |
///   onboarding1 | onboarding2 | onboarding3
///
/// The local data is wiped at launch so every capture starts clean. The model's exposure is private to Core, so
/// Today reads `PreviewHook.exposure` / `peerCount` instead when set. The radios never start.
enum PreviewHook {
    enum State: String { case allClear, nearby, closeContact, walkIn, paused, sick, sickPossible, sickPositive, onboarding }

    private static let env = ProcessInfo.processInfo.environment
    static let state = env["FLUNI_PREVIEW_STATE"].flatMap(State.init(rawValue:))
    static let screen = env["FLUNI_PREVIEW_SCREEN"] ?? "today"

    /// Called from FlUniApp.init. Returns true when a preview state is set (the radios must stay off).
    static func prepare() -> Bool {
        guard let state else { return false }
        SettingsView.eraseLocalData()
        UserDefaults.standard.set(state != .onboarding, forKey: "hasOnboarded")
        // The self-report record goes in before any SelfReportStore loads it (each store reads it once at init).
        let now = Date(), r = SelfReporter(calendar: .current)
        let record: SelfReportRecord?
        switch state {
        case .sick, .sickPossible:
            record = try? r.reportSymptoms(SelfReportRecord(), symptoms: [.fever, .cough, .soreThroat], onset: now.addingTimeInterval(-2 * 86_400), now: now)
        case .sickPositive:
            record = try? r.reportPositive(SelfReportRecord(), kind: .rapid, date: now.addingTimeInterval(-86_400), now: now)
        default: record = nil
        }
        if let record, let url = SelfReportStore.defaultURL { SelfReportFile.save(record, to: url) }
        return true
    }

    static var onboardingPage: Int {
        switch screen { case "onboarding2": return 1; case "onboarding3": return 2; default: return 0 }
    }

    static let exposure: ExposureTracker? = {
        var t = ExposureTracker()
        switch state {
        case .nearby: t.advance(simSeconds: 6 * 60, contacts: [(0.8, .possible)], doses: [DosePeer(id: "a", distance: 1.2)])
        case .closeContact: t.advance(simSeconds: 18 * 60, contacts: [(0.95, .contagious)], doses: [DosePeer(id: "b", distance: 0.8)])
        case nil, .onboarding: return nil
        default: break
        }
        return t
    }()

    static var peerCount: Int? {
        switch state {
        case .allClear, .walkIn, .sick, .sickPossible, .sickPositive: return 3
        case .nearby: return 5
        case .closeContact: return 2
        default: return nil
        }
    }

    @MainActor static func seed(model: ProximityModel, store: SelfReportStore, router: AppRouter) {
        let now = Date(), day = 86_400.0
        func episode(_ start: Date, minutes: Int, _ risk: Risk) {
            for m in 0..<minutes {
                model.exposureHistory.record(simSeconds: 60, contacts: [(0.95, risk)], at: start.addingTimeInterval(Double(m) * 60))
            }
            model.exposureHistory.finishOngoing(now: start.addingTimeInterval(Double(minutes) * 60))
        }
        switch state {
        case .nearby:
            episode(now.addingTimeInterval(-1.6 * day), minutes: 4, .possible)
        case .closeContact:
            episode(now.addingTimeInterval(-3 * day), minutes: 6, .possible)
            episode(now.addingTimeInterval(-25 * 60), minutes: 18, .contagious)
        case .walkIn:
            if let heat = BuildingHeatStore.shared.heat {
                let t = SimClock.shared.simTime
                WalkInMonitor.shared.pretend = heat.mappable.first { heat.reading($0.id, at: t)?.high == true }?.id
            }
        case .paused:
            model.pause(.oneHour)
        case .sick, .sickPossible: model.setMyStatus(.possible)
        case .sickPositive: model.setMyStatus(.contagious)
        default: break
        }
        switch screen {
        case "me": router.tab = .me
        case "closeSheet": router.sheet = .closeContact
        case "report": router.tab = .me; router.sheet = .reportSymptoms
        default: break
        }
    }
}

/// Presents the screen named by FLUNI_PREVIEW_SCREEN when it isn't a tab or a router sheet.
struct PreviewHookModifier: ViewModifier {
    let model: ProximityModel
    let store: SelfReportStore
    @State private var shown: String?
    @State private var seeded = false

    func body(content: Content) -> some View {
        content
            .task {
                guard PreviewHook.state != nil, !seeded else { return }
                seeded = true
                try? await Task.sleep(for: .milliseconds(300))
                PreviewHook.seed(model: model, store: store, router: AppRouter.shared)
                if ["positive", "history", "settings", "how", "calc"].contains(PreviewHook.screen) { shown = PreviewHook.screen }
            }
            .sheet(item: Binding(get: { shown.map(Shown.init) }, set: { shown = $0?.id })) { s in
                switch s.id {
                case "positive": ReportSheet(kind: .positive, model: model, store: store)
                case "history": NavigationStack { ExposureHistoryView(store: model.exposureHistory) }
                case "settings": NavigationStack { SettingsView(model: model) }
                case "how": HowItWorksSheet()
                default: let e = PreviewHook.exposure ?? model.exposure; CalculationSheet(minutes: e.minutes, dose: e.dose, p: e.probability)
                }
            }
    }

    private struct Shown: Identifiable { let id: String }
}
#endif
