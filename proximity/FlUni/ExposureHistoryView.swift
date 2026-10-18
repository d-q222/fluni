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

    /// "Sat 2:10 pm", the left column of a contact row.
    var when: String { Self.dayTime.string(from: start) }

    /// "About 18 min near someone who tested positive", the right column.
    var what: String {
        let who = maxRisk == .contagious ? "someone who tested positive" : "someone with symptoms"
        return "About \(max(1, Int(durationMinutes.rounded()))) min near \(who)"
    }
}

/// One contact as a line in a log: when on the left in a fixed column, what on the right, and a fire-ink
/// "Close contact" mark when it reached 15 minutes. Stacks at large text sizes.
struct ContactRow: View {
    let episode: ExposureEpisode
    @ScaledMetric(relativeTo: .footnote) private var whenWidth: CGFloat = 84

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(episode.when).font(.fluni(.fine)).monospacedDigit().foregroundStyle(Theme.ink2)
                    .frame(width: whenWidth, alignment: .leading)
                detail
            }
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(episode.when).font(.fluni(.fine)).monospacedDigit().foregroundStyle(Theme.ink2)
                detail
            }
        }
        .foregroundStyle(Theme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(episode.spoken)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(episode.what).font(.fluni(.note)).fixedSize(horizontal: false, vertical: true)
            if episode.isCloseContact {
                // fire-ink on fire 18% over paper: 6.0:1.
                Text("Close contact").font(.fluni(.fine).weight(.semibold)).foregroundStyle(Theme.fireInk)
                    .padding(.horizontal, Space.xs).padding(.vertical, 2)
                    .background(Theme.fire.opacity(0.18), in: Capsule())
            }
        }
    }
}

/// "Recent contacts" on Today: the latest few, and a link to the full 14 days. Local only.
struct ExposureHistorySection: View {
    @ObservedObject var store: ExposureHistoryStore
    var showsTitle = true

    private var items: [ExposureEpisode] {
        (store.episodes + (store.ongoing.map { [$0] } ?? [])).sorted { $0.start > $1.start }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if showsTitle {
                Text("Recent contacts").font(.fluni(.section)).accessibilityAddTraits(.isHeader)
            }
            if items.isEmpty {
                EmptyContacts(compact: true)
            } else {
                ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { i, e in
                    if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    ContactRow(episode: e)
                }
                NavigationLink {
                    ExposureHistoryView(store: store)
                } label: {
                    Text("See the last 14 days")
                }
                .buttonStyle(QuietLinkStyle())
                .accessibilityHint("Shows every close contact from the last 14 days")
            }
        }
        .foregroundStyle(Theme.ink)
        .accessibilityElement(children: .contain)
    }
}

/// Nothing to show: Lisa's tissue, resting, and one calm sentence.
private struct EmptyContacts: View {
    var compact = false

    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            Image("Tissue").resizable().scaledToFit().frame(width: compact ? 48 : 72).opacity(0.9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("No one sick nearby lately").font(.fluni(.heading))
                Text("No time near someone with symptoms or a positive test in the last 14 days.")
                    .font(.fluni(.fine)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(Theme.ink)
        .accessibilityElement(children: .combine)
    }
}

/// The last 14 days of exposure episodes, newest first, as a log grouped by day.
struct ExposureHistoryView: View {
    @ObservedObject var store: ExposureHistoryStore

    private var items: [ExposureEpisode] {
        (store.episodes + (store.ongoing.map { [$0] } ?? [])).sorted { $0.start > $1.start }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s) {
                if items.isEmpty {
                    EmptyContacts().padding(.vertical, Space.l)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { i, e in
                    if i > 0 { HandRule() }
                    ContactRow(episode: e)
                }
                Text("Kept on this phone only, and removed after 14 days. It never leaves your phone.")
                    .font(.fluni(.fine)).foregroundStyle(Theme.ink)
                    .panel()
                    .padding(.top, Space.m)
            }
            .padding(Space.m)
        }
        .background(Theme.paper)
        .navigationTitle("Recent contacts")
        .navigationBarTitleDisplayMode(.inline)
    }
}
