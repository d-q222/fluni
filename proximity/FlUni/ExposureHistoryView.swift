import SwiftUI

extension ExposureEpisode {
    private static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE h:mm a"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

    /// "Sat 2:10 pm · about 18 min near someone who tested positive · close contact"
    var summary: String {
        let who = maxRisk == .contagious ? "someone who tested positive" : "someone with symptoms"
        let mins = max(1, Int(durationMinutes.rounded()))
        var s = "\(Self.dayTime.string(from: start)) · about \(mins) min near \(who)"
        if isCloseContact { s += " · close contact" }
        return s
    }

    /// The same sentence without the middle dots, which VoiceOver reads as a pause at best.
    var spoken: String { summary.replacingOccurrences(of: " · ", with: ", ") }
}

/// The last 14 days of exposure episodes, newest first.
struct ExposureHistoryView: View {
    @ObservedObject var store: ExposureHistoryStore

    private var items: [ExposureEpisode] {
        (store.episodes + (store.ongoing.map { [$0] } ?? [])).sorted { $0.start > $1.start }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if items.isEmpty {
                    Text("No time near someone sick in the last 14 days.").font(.fluni(.body)).foregroundStyle(Theme.ink2)
                }
                ForEach(items) { e in
                    Text(e.summary).font(.fluni(.subheadline))
                        .foregroundStyle(e.isCloseContact ? Theme.fireInk : Theme.ink)
                        .accessibilityLabel(e.spoken)
                        .card(fill: e.isCloseContact ? Theme.fireWash : Theme.surface)
                }
                Text("Kept on this phone only, and removed after 14 days. It never leaves your phone.")
                    .font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
            }
            .padding(16)
        }
        .tissueTabBarScrollRoom(alert: true)
        .background(Theme.paper)
        .navigationTitle("Recent contacts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Full-screen, dismissible moment when the 15-minute close-contact mark is reached.
struct CloseContactSheet: View {
    var onDone: () -> Void
    @ScaledMetric(relativeTo: .title) private var iconSize: CGFloat = 44

    var body: some View {
        let lines = Advice.body(.closeContact)
        // Scrolls at large text sizes instead of clipping; "Got it" stays pinned at the bottom.
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "heart.text.square").font(.system(size: iconSize)).foregroundStyle(Theme.fireInk)
                .accessibilityHidden(true)
            Text("You were close to someone who may be sick")
                .accessibilityAddTraits(.isHeader)
                .font(.fluni(.title, weight: .bold)).foregroundStyle(Theme.ink)
            if let first = lines.first { Text(first).font(.fluni(.body)).foregroundStyle(Theme.ink2) }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(lines.dropFirst()), id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "checkmark.circle").foregroundStyle(Theme.fireInk).accessibilityHidden(true)
                        Text(line).font(.fluni(.body)).foregroundStyle(Theme.ink)
                    }
                }
            }
            .card()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            Button("Got it", action: onDone).buttonStyle(PrimaryButtonStyle())
                .accessibilityHint("Closes this message")
                .padding(.horizontal, 24).padding(.vertical, 12)
                .background(Theme.paper)
        }
        .background(Theme.paper.ignoresSafeArea())
    }
}
