import SwiftUI

/// Calm note on Today while ContactGuard has paused Bluetooth-only alerts. Shows nothing otherwise.
struct UnusualSignalsBanner: View {
    @ObservedObject var model: ProximityModel

    var body: some View {
        if model.unusualSignals {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.title3).accessibilityHidden(true)
                Text("Unusual Bluetooth signals nearby; alerts paused for a few minutes")
                    .font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.ink)
            .card(fill: Theme.sun.opacity(0.5))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("banner.unusualSignals")
        }
    }
}
