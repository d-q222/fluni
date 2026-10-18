import Foundation

/// What a FlUni notification is about. Raw values go in userInfo["kind"]; no IDs of people, no location.
enum NotificationKind: String, CaseIterable {
    case closeContact = "close_contact"
    case nearby = "nearby"
    case building = "building"

    /// UNNotificationCategory identifier for this kind.
    var categoryID: String { "fluni.\(rawValue)" }
}

/// Action identifiers registered on the categories.
enum NotificationAction {
    static let reportSymptoms = "fluni.action.report_symptoms"
    static let seeAdvice = "fluni.action.see_advice"
    static let gotIt = "fluni.action.got_it"
    static let showOnMap = "fluni.action.show_on_map"
    /// UNNotificationDefaultActionIdentifier / UNNotificationDismissActionIdentifier (kept literal so this file needs no UIKit).
    static let defaultTap = "com.apple.UNNotificationDefaultActionIdentifier"
    static let dismiss = "com.apple.UNNotificationDismissActionIdentifier"
}

/// Where the app goes after the user taps a notification or one of its quick actions.
enum Route: Equatable {
    case openToday                // just open the app (Today tab)
    case closeContact             // the close-contact sheet
    case reportSymptoms           // the symptoms report sheet
    case mapFocus(String)         // the Map tab, centred on this building id
    case ignore                   // do nothing (dismissed, "Got it", or something we don't understand)
}

enum NotificationRoute {
    /// Pure decision: userInfo plus the tapped action identifier gives a Route. Never crashes on junk.
    static func route(userInfo: [AnyHashable: Any], actionIdentifier: String) -> Route {
        if actionIdentifier == NotificationAction.dismiss { return .ignore }
        let kind = (userInfo["kind"] as? String).flatMap(NotificationKind.init(rawValue:))
        let building = buildingID(userInfo)

        if actionIdentifier == NotificationAction.defaultTap {
            switch kind {
            case .closeContact: return .closeContact
            case .building: return building.map(Route.mapFocus) ?? .openToday
            case .nearby, .none: return .openToday
            }
        }
        // A quick action only counts for the category it belongs to.
        switch (kind, actionIdentifier) {
        case (.closeContact, NotificationAction.reportSymptoms): return .reportSymptoms
        case (.closeContact, NotificationAction.seeAdvice): return .closeContact
        case (.nearby, NotificationAction.gotIt): return .ignore
        case (.building, NotificationAction.showOnMap): return building.map(Route.mapFocus) ?? .openToday
        default: return .ignore
        }
    }

    /// A plausible building id: a non-empty string of modest length.
    private static func buildingID(_ info: [AnyHashable: Any]) -> String? {
        guard let s = info["building_id"] as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.count > 64 ? nil : t
    }

    /// Lock-screen wording. The title is always just "FlUni" (iOS shows it even when previews are hidden); with details
    /// off the body says nothing about health. With details on, the body is the advice itself, the same lines as in
    /// the app, cut at a whole sentence so it fits a collapsed banner, with `more` added when anything was cut.
    /// `level`: for a heads-up, `.nearbyContagious` gives the stronger wording.
    static func text(kind: NotificationKind, detailed: Bool, buildingName: String? = nil, sick: Bool = false,
                     level: AlertLevel = .nearby) -> (title: String, body: String) {
        guard detailed else { return ("FlUni", "You have an update. Open FlUni to see it.") }
        switch kind {
        case .closeContact: return ("FlUni", fit(Advice.body(.closeContact)))  // its first line already says what happened
        case .nearby:
            let l: AlertLevel = level == .nearbyContagious ? .nearbyContagious : .nearby
            return ("FlUni", fit([Advice.title(l) + "."] + Advice.body(l)))
        case .building:
            return ("FlUni", fit([WalkInWarning.message(for: buildingName ?? "This building", sick: sick)]))
        }
    }

    /// About four lines of a collapsed banner on a 6.1-inch iPhone.
    static let bodyBudget = 180
    static let more = "Tap for more details."

    /// Whole sentences, in order, while they fit in `bodyBudget`; if any are left out, ends with `more`.
    /// The first sentence is always kept, even when it is long on its own.
    static func fit(_ sentences: [String]) -> String {
        if sentences.joined(separator: " ").count <= bodyBudget { return sentences.joined(separator: " ") }
        var kept: [String] = []
        for s in sentences {
            let next = (kept + [s, more]).joined(separator: " ")
            if !kept.isEmpty && next.count > bodyBudget { break }
            kept.append(s)
        }
        return (kept + [more]).joined(separator: " ")
    }
}
