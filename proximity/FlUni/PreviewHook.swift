#if DEBUG
import SwiftUI

/// Debug builds only: put the app in a known state for design screenshots, without radios.
///
///   SIMCTL_CHILD_FLUNI_PREVIEW_STATE=nearby SIMCTL_CHILD_FLUNI_PREVIEW_SCREEN=today xcrun simctl launch <udid> com.fluni.app
///
/// FLUNI_PREVIEW_STATE: allClear | nearby | closeContact | walkIn | paused | sick (= sickPossible) | sickPossible |
///   sickPositive | onboarding | riskElevated (about 18%) | riskHigh (about 45%)
/// FLUNI_PREVIEW_SCREEN: today (default) | you | campus | report (step 1) | symptoms (step 2) | positive | history |
///   settings | how | calc | onboarding1 | onboarding2 | onboarding3
///
/// Today's timeline is seeded with a realistic day through the real PlaceLog rules (observations every few minutes).
///
/// The local data is wiped at launch so every capture starts clean. The model's exposure is private to Core, so
/// Today reads `PreviewHook.exposure` / `peerCount` instead when set. The radios never start.
enum PreviewHook {
    enum State: String { case allClear, nearby, closeContact, walkIn, paused, sick, sickPossible, sickPositive, onboarding, riskElevated, riskHigh }

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
            // Reported yesterday evening, so today's check-in is still to do.
            record = try? r.reportSymptoms(SelfReportRecord(), symptoms: [.fever, .cough, .soreThroat], onset: now.addingTimeInterval(-2 * 86_400),
                                           now: Calendar.current.startOfDay(for: now).addingTimeInterval(-4 * 3600))
        case .sickPositive:
            record = try? r.reportPositive(SelfReportRecord(), kind: .rapid, date: now.addingTimeInterval(-86_400), now: now)
        default: record = nil
        }
        if let record, let url = SelfReportStore.defaultURL { SelfReportFile.save(record, to: url) }
        return true
    }

    /// Report step 2 with Fever and Cough picked, starting yesterday ("symptomsPicked", and "stamp", which saves it).
    static var pickSymptoms: Bool { state != nil && (screen == "symptomsPicked" || screen == "stamp") }
    static var autoSubmit: Bool { state != nil && screen == "stamp" }
    /// Today scrolls to this anchor once seeded: "earlier" (the rows under Now) or "footer".
    static var scrollAnchor: String? {
        guard state != nil else { return nil }
        if screen == "moment" { return "earlier" }
        return ["earlier", "footer"].contains(screen) ? screen : nil
    }

    static var onboardingPage: Int {
        switch screen { case "onboarding2": return 1; case "onboarding3": return 2; default: return 0 }
    }

    static let exposure: ExposureTracker? = {
        var t = ExposureTracker()
        switch state {
        case .nearby: t.advance(simSeconds: 6 * 60, contacts: [(0.8, .possible)], doses: [DosePeer(id: "a", distance: 1.2)])
        case .closeContact: t.advance(simSeconds: 18 * 60, contacts: [(0.95, .contagious)], doses: [DosePeer(id: "b", distance: 0.8)])
        case .riskElevated, .riskHigh:
            // Earlier time near someone who tested positive, mostly just outside 6 ft: the dose (and so the risk)
            // builds while close-contact minutes stay low. Stops at the target, then nobody is near now.
            let target = state == .riskHigh ? 0.45 : 0.18
            var n = 0
            while t.probability < target && n < 5000 {
                t.advance(simSeconds: 20, contacts: [(0.04, .contagious)], doses: [DosePeer(id: "c", distance: 1.6)])
                n += 1
            }
            t.advance(simSeconds: 0, contacts: [])
        case nil, .onboarding: return nil
        default: break
        }
        return t
    }()

    static var peerCount: Int? {
        switch state {
        case .allClear, .walkIn, .sick, .sickPossible, .sickPositive, .riskElevated, .riskHigh: return 3
        case .nearby: return 5
        case .closeContact: return 2
        default: return nil
        }
    }

    @MainActor static func seed(model: ProximityModel, store: SelfReportStore, router: AppRouter) {
        let now = Date()
        func episode(_ start: Date, minutes: Int, _ risk: Risk) {
            for m in 0..<minutes {
                model.exposureHistory.record(simSeconds: 60, contacts: [(0.95, risk)], at: start.addingTimeInterval(Double(m) * 60))
            }
            model.exposureHistory.finishOngoing(now: start.addingTimeInterval(Double(minutes) * 60))
        }
        func ongoing(minutes: Int, _ risk: Risk) {
            for m in 0..<minutes {
                model.exposureHistory.record(simSeconds: 60, contacts: [(0.9, risk)], at: now.addingTimeInterval(Double(m - minutes + 1) * 60))
            }
        }
        if state != .onboarding { seedDay(now: now) }
        switch state {
        case .nearby:
            episode(now.addingTimeInterval(-140 * 60), minutes: 4, .possible)
            ongoing(minutes: 6, .possible)
        case .riskElevated:
            episode(now.addingTimeInterval(-140 * 60), minutes: 5, .contagious)
        case .riskHigh:
            episode(now.addingTimeInterval(-240 * 60), minutes: 7, .contagious)
            episode(now.addingTimeInterval(-140 * 60), minutes: 6, .contagious)
        case .closeContact:
            episode(now.addingTimeInterval(-140 * 60), minutes: 4, .possible)
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
        case "you", "me": router.tab = .you
        case "campus", "map": router.tab = .campus
        case "moment": router.showCloseContact()
        default: break
        }
    }

    /// A morning on campus, oldest first: through the Quad, a lecture in Gates, lunch at Arrillaga, then Green Library now.
    @MainActor private static func seedDay(now: Date) {
        let places = PlaceLogStore.shared
        func stay(_ id: String, _ name: String, from: Double, to: Double, phones: Int) {
            var t = from
            while t <= to {
                places.debugObserve(id, name, phones: phones, at: now.addingTimeInterval(t * 60))
                t += 4
            }
            places.debugObserve(id, name, phones: phones, at: now.addingTimeInterval(to * 60))
            places.debugObserve(nil, nil, phones: 0, at: now.addingTimeInterval(to * 60 + 1))
        }
        stay("main-quad", "Main Quad", from: -292, to: -289, phones: 0)
        stay("gates", "Gates", from: -252, to: -172, phones: 4)
        stay("arrillaga", "Arrillaga Dining", from: -152, to: -107, phones: 11)
        var t = -95.0
        while t <= 0 { places.debugObserve("green-library", "Green Library", phones: peerCount ?? 3, at: now.addingTimeInterval(t * 60)); t += 4 }
        places.debugObserve("green-library", "Green Library", phones: peerCount ?? 3, at: now)
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
                if ["report", "symptoms", "symptomsPicked", "stamp", "positive", "history", "settings", "how", "calc"].contains(PreviewHook.screen) { shown = PreviewHook.screen }
            }
            .sheet(item: Binding(get: { shown.map(Shown.init) }, set: { shown = $0?.id })) { s in
                switch s.id {
                case "report": ReportFlow(start: .choose, model: model, store: store)
                case "symptoms", "symptomsPicked", "stamp": ReportFlow(start: .symptoms, model: model, store: store)
                case "positive": ReportFlow(start: .positive, model: model, store: store)
                case "history": NavigationStack { ExposureHistoryView(store: model.exposureHistory) }
                case "settings": NavigationStack { SettingsView(model: model) }
                case "how": HowItWorksSheet()
                default: CalculationSheet(model: model)
                }
            }
    }

    private struct Shown: Identifiable { let id: String }
}
#endif
