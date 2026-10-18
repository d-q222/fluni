import SwiftUI

/// The Today risk card: the phone's own live estimate as the headline, always; the campus-model number (Debug
/// "Play as" persona only) is an extra line under it, never in its place.
struct RiskCardView: View {
    /// This phone's live estimate (ProximityModel.liveRisk); it changes every tick near someone sick.
    let p: Double
    /// Today's alert level: during a heads-up or close contact a low number doesn't say "No action needed".
    var alert: AlertLevel = .none
    let onHow: () -> Void
    @ObservedObject private var store = PSickStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Same tiers as the map: low = sage, elevated = sun, high = fire. Text is ink, or fire-ink on fire.
    private static func fill(_ b: RiskEstimate.Band) -> Color {
        switch b {
        case .low: return Theme.sage.opacity(0.45)
        case .elevated: return Theme.sun.opacity(0.5)
        case .high: return Theme.fire.opacity(0.22)
        }
    }
    private static func textColor(_ b: RiskEstimate.Band) -> Color { b == .high ? Theme.fireInk : Theme.ink }
    /// Secondary text: ink-2 passes on sage and sun tints (5.1 and 5.6), fire-ink is safer on the fire tint.
    private static func noteColor(_ b: RiskEstimate.Band) -> Color { b == .high ? Theme.fireInk : Theme.ink2 }

    var body: some View {
        // Colour and advice follow the live number the card leads with, so they can never disagree.
        let band = RiskEstimate.band(p)
        let text = Self.textColor(band)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your risk estimate").font(.fluni(.headline))
                Text(RiskEstimate.liveText(p)).font(.fluni(.largeTitle, weight: .bold)).monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText(value: p))
                    .animation(reduceMotion ? nil : .smooth, value: p)
                if let official = store.campusP {
                    Text("Campus model: \(RiskEstimate.percentText(official))")
                        .font(.fluni(.subheadline, weight: .semibold)).monospacedDigit()
                }
                Text(RiskEstimate.summary(p, alert: alert)).font(.fluni(.subheadline))
                Text("Based on the last 24 hours: time near each person, how close (closer counts much more), shared room air, and whether they reported symptoms or a positive test. It's an estimate, not a diagnosis.")
                    .font(.fluni(.footnote)).foregroundStyle(Self.noteColor(band))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("risk.card")
            Button(action: onHow) {
                Label("See how this is worked out", systemImage: "function")
                    .font(.fluni(.footnote, weight: .semibold)).foregroundStyle(Self.noteColor(band)).frame(minHeight: 44)
            }
            .accessibilityHint("Opens the numbers behind this estimate")
            .accessibilityIdentifier("risk.how")
        }
        .foregroundStyle(text)
        .card(fill: Self.fill(band))
        .task { if store.feed == nil, !store.agent.isEmpty { await store.reload() } }
    }
}
