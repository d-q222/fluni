import SwiftUI

/// A small banner for Today while detection is paused. Shows nothing otherwise.
struct PausedBanner: View {
    @ObservedObject var model: ProximityModel

    var body: some View {
        if let p = model.pauseState {
            HStack(spacing: 10) {
                Image(systemName: "pause.circle.fill").font(.title3).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Detection paused").font(.fluni(.subheadline, weight: .semibold))
                    Text("Nothing is shared and exposure isn't counted, \(PauseSchedule.describe(p, calendar: .current, now: Date())).")
                        .font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
                }
                Spacer(minLength: 0)
                Button("Resume") { model.resume() }
                    .font(.fluni(.subheadline, weight: .semibold))
                    .frame(minHeight: 44)
            }
            .foregroundStyle(Theme.ink)
            .card(fill: Theme.sun.opacity(0.5))
            .accessibilityElement(children: .contain)
        }
    }
}
