import SwiftUI
import Combine

/// Which tab is open and which sheet (if any) a tapped notification asked for. FlUniApp's TabView binds to it.
/// A Route that arrives before the UI exists (cold launch from a notification, or still on onboarding) waits
/// in `pending` until `becomeReady()` is called.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    enum Tab: Hashable { case today, campus, you }

    @Published var tab: Tab = .today
    /// Bumped to open the newest close contact in place on Today's timeline.
    @Published private(set) var closeContactRequest = 0
    /// Bumped to open the report sheet on Today.
    @Published private(set) var reportRequest = 0
    /// Building the Campus tab should centre on and open the card for; the map clears it once applied.
    @Published var focusBuilding: String?

    /// Fires when every open sheet must close (child views with their own sheets listen).
    let dismissSheets = PassthroughSubject<Void, Never>()

    private var ready = false
    private var pending: Route?

    func handle(_ route: Route) {
        guard ready else { pending = route; return }
        apply(route)
    }

    /// The main UI is on screen (onboarding done): apply any route that was waiting.
    func becomeReady() {
        ready = true
        if let p = pending { pending = nil; apply(p) }
    }

    /// The close contact opens in place on Today's timeline (B-2): close any sheet, go to Today, open it.
    func showCloseContact() {
        dismissSheets.send()
        tab = .today
        closeContactRequest += 1
    }

    /// "I don't feel well" from a notification: Today's report sheet, once any open sheet has gone.
    func showReport() {
        dismissSheets.send()
        tab = .today
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.reportRequest += 1 }
    }

    private func apply(_ route: Route) {
        switch route {
        case .openToday: tab = .today
        case .closeContact: showCloseContact()
        case .reportSymptoms: showReport()
        case .mapFocus(let id): dismissSheets.send(); tab = .campus; focusBuilding = id
        case .ignore: break
        }
    }
}
