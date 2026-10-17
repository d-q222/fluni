import SwiftUI

/// Today: a calm note while the user is inside a building with a lot of illness. Nothing otherwise.
struct WalkInBanner: View {
    @ObservedObject var model: ProximityModel
    @ObservedObject private var monitor = WalkInMonitor.shared

    var body: some View {
        Group {
            if let b = monitor.banner {
                HStack(spacing: 10) {
                    Image(systemName: "building.2.crop.circle").font(.title3).accessibilityHidden(true)
                    Text(WalkInWarning.message(for: b.name)).font(.fluni(.subheadline, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.fireInk)
                .card(fill: Theme.fire.opacity(0.18))
                .accessibilityElement(children: .combine)
            }
        }
        .task { monitor.attach(model) }
    }
}
