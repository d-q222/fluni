import SwiftUI

/// Today while detection is paused. It takes the status's place (an "All clear" wouldn't be true while FlUni
/// isn't looking), so it's drawn as the hero: Lisa's paper box with a sun tint, and Resume as the one action.
/// Shows nothing otherwise.
struct PausedBanner: View {
    @ObservedObject var model: ProximityModel

    var body: some View {
        if let p = model.pauseState {
            VStack(alignment: .leading, spacing: Space.m) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Detection is paused").font(.fluni(.display)).accessibilityAddTraits(.isHeader)
                    Text("FlUni isn't sharing your status or counting close-contact time, \(PauseSchedule.describe(p, calendar: .current, now: Date())).")
                        .font(.fluni(.note)).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Button("Resume detection") { model.resume() }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("banner.resume")
                    .accessibilityHint("Turns detection back on")
            }
            .foregroundStyle(Theme.ink)
            .card(fill: Theme.sun.opacity(0.5))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("banner.paused")
        }
    }
}
