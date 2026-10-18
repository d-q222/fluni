import SwiftUI

/// The Today risk card: the phone's own estimate, plus the official campus-model number when a demo persona is set.
struct RiskCardView: View {
    /// This phone's estimate (ExposureTracker.probability).
    let p: Double
    let onHow: () -> Void
    @ObservedObject private var store = PSickStore.shared

    /// Same tiers as the map: low = sage, elevated = sun, high = fire, as the tint behind the number.
    private static func fill(_ b: RiskEstimate.Band) -> Color {
        switch b {
        case .low: return Theme.sage.opacity(0.45)
        case .elevated: return Theme.sun.opacity(0.5)
        case .high: return Theme.fire.opacity(0.22)
        }
    }
    var body: some View {
        // The headline number sets the tier colour: the campus model's when there is one, else this phone's.
        let band = RiskEstimate.band(store.campusP ?? p)
        VStack(alignment: .leading, spacing: Space.xs) {
            VStack(alignment: .leading, spacing: Space.xs) {
                LedgerLine(label: "Your risk estimate") {
                    // The number sits on its tier tint (ink: 10.5 / 11.6 / 10.8:1); the summary below says the tier in words.
                    Text(RiskEstimate.percentText(store.campusP ?? p)).font(.fluni(.section)).monospacedDigit()
                        .padding(.horizontal, Space.s).padding(.vertical, 2)
                        .background(Self.fill(band), in: Capsule())
                }
                if let official = store.campusP {
                    Text("Campus model: \(RiskEstimate.percentText(official)) \u{00B7} This phone: \(RiskEstimate.percentText(p))")
                        .font(.fluni(.fine)).foregroundStyle(Theme.ink2).monospacedDigit()
                }
                // Same number for colour and advice, so they can never disagree.
                Text(RiskEstimate.summary(store.campusP ?? p)).font(.fluni(.note))
                Text("Based on the last 24 hours: time near each person, how close (closer counts much more), shared room air, and whether they reported symptoms or a positive test. It's an estimate, not a diagnosis.")
                    .font(.fluni(.fine)).foregroundStyle(Theme.ink2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("risk.card")
            Button(action: onHow) { Text("See how this is worked out") }
                .buttonStyle(QuietLinkStyle())
                .accessibilityHint("Opens the numbers behind this estimate")
                .accessibilityIdentifier("risk.how")
        }
        .foregroundStyle(Theme.ink)
        .task { if store.feed == nil, !store.agent.isEmpty { await store.reload() } }
    }
}
