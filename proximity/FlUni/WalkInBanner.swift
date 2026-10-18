import SwiftUI

/// Today: a calm note while the user is inside a building with a lot of illness. Nothing otherwise.
struct WalkInBanner: View {
    @ObservedObject var model: ProximityModel
    @ObservedObject private var monitor = WalkInMonitor.shared

    var body: some View {
        Group {
            if let b = monitor.banner {
                // A heads-up that isn't the main status: Lisa's peach as a flat strip.
                // Ink is the only text colour that passes on peach (8.6; ink-2 is 4.2, fire-ink 4.4).
                Text(WalkInWarning.message(for: b.name)).font(.fluni(.note).weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(Theme.ink)
                    .panel(.peach)
            }
        }
        .task { monitor.attach(model) }
    }
}
