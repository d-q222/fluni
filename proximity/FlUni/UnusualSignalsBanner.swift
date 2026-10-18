import SwiftUI

/// Calm note on Today while ContactGuard has paused Bluetooth-only alerts. Shows nothing otherwise.
struct UnusualSignalsBanner: View {
    @ObservedObject var model: ProximityModel

    var body: some View {
        if model.unusualSignals {
            Text("Unusual Bluetooth signals nearby; alerts paused for a few minutes")
                .font(.fluni(.fine)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .panel()
                .accessibilityIdentifier("banner.unusualSignals")
        }
    }
}
