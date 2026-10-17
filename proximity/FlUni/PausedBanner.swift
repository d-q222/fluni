import SwiftUI

/// A small banner for Today while detection is paused. Shows nothing otherwise.
struct PausedBanner: View {
    @ObservedObject var model: ProximityModel

    var body: some View {
        if let p = model.pauseState {
            // Side by side normally; stacked when large text would squeeze the message.
            let message = VStack(alignment: .leading, spacing: 2) {
                Text("Detection is paused").font(.fluni(.subheadline, weight: .semibold))
                Text("FlUni isn't sharing your status or counting close-contact time, \(PauseSchedule.describe(p, calendar: .current, now: Date())).")
                    .font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
            }
            let resume = Button("Resume detection") { model.resume() }
                .accessibilityIdentifier("banner.resume")
                .font(.fluni(.subheadline, weight: .semibold))
                .frame(minWidth: 44, minHeight: 44)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Image(systemName: "pause.circle.fill").font(.title3).accessibilityHidden(true)
                    message
                    Spacer(minLength: 0)
                    resume
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "pause.circle.fill").font(.title3).accessibilityHidden(true)
                        message
                    }
                    resume
                }
            }
            .foregroundStyle(Theme.ink)
            .card(fill: Theme.sun.opacity(0.5))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("banner.paused")
        }
    }
}
