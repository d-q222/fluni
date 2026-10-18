import SwiftUI

/// Today: a calm note while the user is inside a building with a lot of illness. Nothing otherwise.
struct WalkInBanner: View {
    @ObservedObject var model: ProximityModel
    @ObservedObject private var monitor = WalkInMonitor.shared

    var body: some View {
        Group {
            if let b = monitor.banner {
                // Ink is the only text colour that passes on the peach box (8.6; ink-2 is 4.2, fire-ink 4.4).
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "building.2.crop.circle").font(.title3).accessibilityHidden(true)
                    Text(WalkInWarning.message(for: b.name, sick: model.selfStatusOverridesRisk)).font(.fluni(.subheadline, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.ink)
                .card(.peach)
                .accessibilityElement(children: .combine)
            }
        }
        .task { monitor.attach(model) }
    }
}
