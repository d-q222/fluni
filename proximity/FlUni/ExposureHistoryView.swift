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
}

/// "Recent contacts" on Today: the latest few, and a link to the full 14 days. Local only.
struct ExposureHistorySection: View {
    @ObservedObject var store: ExposureHistoryStore

    private var items: [ExposureEpisode] {
        (store.episodes + (store.ongoing.map { [$0] } ?? [])).sorted { $0.start > $1.start }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent contacts").font(.fluni(.headline)).accessibilityAddTraits(.isHeader)
            if items.isEmpty {
                Text("No time near someone sick in the last 14 days.").font(.fluni(.subheadline)).foregroundStyle(Theme.ink2)
            } else {
                ForEach(items.prefix(3)) { Text($0.summary).font(.fluni(.subheadline)).foregroundStyle(Theme.ink2) }
                NavigationLink {
                    ExposureHistoryView(store: store)
                } label: {
                    Label("See the last 14 days", systemImage: "chevron.right")
                        .font(.fluni(.footnote, weight: .semibold)).foregroundStyle(Theme.ink2).frame(minHeight: 44)
                }
                .accessibilityHint("Shows every close contact from the last 14 days")
            }
        }
        .foregroundStyle(Theme.ink)
        .card()
        .accessibilityElement(children: .contain)
    }
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
                        .accessibilityLabel(e.summary.replacingOccurrences(of: " · ", with: ", "))
                        .card(fill: e.isCloseContact ? Theme.fire.opacity(0.18) : Theme.surface)
                }
                Text("Kept on this phone only, and removed after 14 days. It never leaves your phone.")
                    .font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
            }
            .padding(16)
        }
        .background(Theme.paper)
        .navigationTitle("Recent contacts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Gentle heads-up on Today while someone who may be sick is probably within 6 ft.
struct NearbyBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "figure.walk").font(.title3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(Advice.title(.nearby)).font(.fluni(.subheadline, weight: .semibold))
                Text(Advice.body(.nearby).joined(separator: " ")).font(.fluni(.footnote))
            }
        }
        .foregroundStyle(Theme.ink)
        .card(fill: Theme.sun.opacity(0.5))
        .accessibilityElement(children: .combine)
    }
}

/// Full-screen, dismissible moment when the 15-minute close-contact mark is reached.
struct CloseContactSheet: View {
    var onDone: () -> Void

    var body: some View {
        let lines = Advice.body(.closeContact)
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 0)
            Image(systemName: "heart.text.square").font(.system(size: 44)).foregroundStyle(Theme.fireInk)
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
            Spacer(minLength: 0)
            Button("Got it", action: onDone).buttonStyle(PrimaryButtonStyle())
                .accessibilityHint("Closes this message")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper.ignoresSafeArea())
    }
}
