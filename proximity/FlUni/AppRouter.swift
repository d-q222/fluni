import SwiftUI

/// Which tab is open and which sheet (if any) a tapped notification asked for. FlUniApp's TabView binds to it.
/// A Route that arrives before the UI exists (cold launch from a notification, or still on onboarding) waits
/// in `pending` until `becomeReady()` is called.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    enum Tab: Hashable { case today, map, me }
    enum Sheet: Identifiable { case closeContact, reportSymptoms; var id: Self { self } }

    @Published var tab: Tab = .today
    @Published var sheet: Sheet?
    /// Building the Map tab should centre on and open the card for; the map clears it once applied.
    @Published var focusBuilding: String?

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

    private func apply(_ route: Route) {
        switch route {
        case .openToday: tab = .today
        case .closeContact: sheet = .closeContact
        case .reportSymptoms: tab = .me; sheet = .reportSymptoms
        case .mapFocus(let id): sheet = nil; tab = .map; focusBuilding = id
        case .ignore: break
        }
    }
}
