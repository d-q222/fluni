import SwiftUI

/// Today: a calm note while the user is inside a building with a lot of illness. Nothing otherwise.
/// It's about a place, not about people near you, so Today shows it under the status rather than above it.
struct WalkInBanner: View {
    @ObservedObject var model: ProximityModel
    @ObservedObject private var monitor = WalkInMonitor.shared
    /// Dismissed for this building while the app is open. Only hides the note; the warning logic is untouched.
    @State private var dismissed: String?
    @ScaledMetric(relativeTo: .title3) private var iconSize: CGFloat = 28

    var body: some View {
        Group {
            if let b = monitor.banner, b.id != dismissed {
                // A heads-up, so Lisa's peach box. Ink is the only text colour that passes on peach (8.6; ink-2 is 4.2).
                HStack(alignment: .top, spacing: Space.s) {
                    Image(systemName: "building.2").font(.system(size: iconSize * 0.7, weight: .medium))
                        .frame(width: iconSize, height: iconSize)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("In this building").font(.fluni(.heading)).accessibilityAddTraits(.isHeader)
                        Text(WalkInWarning.message(for: b.name)).font(.fluni(.note))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    Button { dismissed = b.id } label: {
                        Image(systemName: "xmark").font(.fluni(.fine).weight(.bold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .padding(.top, -Space.s).padding(.trailing, -Space.s)
                    .accessibilityLabel("Dismiss")
                    .accessibilityHint("Hides this note about \(b.name)")
                }
                .foregroundStyle(Theme.ink)
                .card(.peach)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("banner.walkIn")
            }
        }
        .task { monitor.attach(model) }
    }
}
