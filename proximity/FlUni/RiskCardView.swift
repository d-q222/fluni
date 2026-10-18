import SwiftUI

/// The Today risk card: the phone's own estimate, plus the official campus-model number when a demo persona is set.
struct RiskCardView: View {
    let dose: Double
    let onHow: () -> Void
    @ObservedObject private var store = PSickStore.shared

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
        let p = RiskEstimate.probability(dose: dose)
        // The headline number sets the tier colour: the campus model's when there is one, else this phone's.
        let band = RiskEstimate.band(store.campusP ?? p)
        let text = Self.textColor(band)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                if let official = store.campusP {
                    Text("Campus model: \(RiskEstimate.percentText(official))")
                        .font(.fluni(.title2, weight: .bold)).monospacedDigit()
                    Text("This phone's estimate: \(RiskEstimate.percentText(p))")
                        .font(.fluni(.headline)).monospacedDigit()
                } else {
                    Text("Your risk estimate").font(.fluni(.headline))
                    Text(RiskEstimate.percentText(p)).font(.fluni(.largeTitle, weight: .bold)).monospacedDigit()
                }
                // Same number for colour and advice, so they can never disagree.
                Text(RiskEstimate.summary(store.campusP ?? p)).font(.fluni(.subheadline))
                Text("Based on time near other FlUni phones in the last 24 hours. It's an estimate, not a diagnosis.")
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
