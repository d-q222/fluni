import SwiftUI

/// Lisa's tissue-box tab bar (design pass; art in heatmap/assets/tabbar/). The box drawing already shows
/// all three tissues with her lettering; each tab is a button over its tissue holding the same tissue cut
/// out, so the selected one can lift (scaled up from its bottom edge, so it always covers the drawing
/// underneath). The bottom of the drawing runs under the home indicator; only the part above it takes
/// space from the screen (see `TissueTabBar.reserved`).
struct TissueTabBar: View {
    @Binding var selection: AppRouter.Tab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Width / height of bar.png.
    static let aspect: CGFloat = 3.0233
    /// Where each tissue sits in the drawing, as fractions of its width and height (from layout.json).
    private static let tabs: [(tab: AppRouter.Tab, art: String, label: String, id: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)] = [
        (.today, "TabTissueToday", "Today", "tab.today", 0.0, 0.3884, 0.2462, 0.6116),
        (.map, "TabTissueMap", "Map", "tab.map", 0.3438, 0.3349, 0.2985, 0.6651),
        (.me, "TabTissueMe", "Me", "tab.me", 0.7492, 0.3442, 0.2508, 0.6558),
    ]

    static var width: CGFloat { UIScreen.main.bounds.width }
    static var height: CGFloat { width / aspect }
    /// The home indicator's height; the drawing runs underneath it.
    static var homeIndicator: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets.bottom ?? 0
    }
    /// How far the drawing sits above the bottom edge, so the tissues' lettering clears the home indicator
    /// (with the drawing flush to the edge, "Today", "map" and "me" were partly hidden under it).
    static var lift: CGFloat { homeIndicator * 0.75 }
    /// Space the bar takes above the home indicator. Screens add this as a bottom inset.
    static var reserved: CGFloat { max(height - homeIndicator + lift, 0) }

    var body: some View {
        let w = Self.width, h = Self.height
        ZStack(alignment: .topLeading) {
            Image("TabBarBox").resizable().frame(width: w, height: h).accessibilityHidden(true)
            ForEach(Self.tabs, id: \.id) { t in
                let on = selection == t.tab
                Button { selection = t.tab } label: {
                    Image(t.art).resizable()
                        .frame(width: w * t.w, height: h * t.h)
                        .scaleEffect(on ? 1.12 : 1, anchor: .bottom)
                        .rotationEffect(.degrees(on && !reduceMotion ? -2 : 0), anchor: .bottom)
                        .shadow(color: Theme.ink.opacity(on ? 0.25 : 0), radius: 3, y: 3)
                        .saturation(on ? 1 : 0.85)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: w * t.x, y: h * t.y)
                .zIndex(on ? 1 : 0)
                .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.55), value: on)
                .accessibilityLabel(t.label)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier(t.id)
            }
        }
        .frame(width: w, height: h)
        // Paper under the lifted box, so nothing scrolls into view beneath it.
        .padding(.bottom, Self.lift)
        .background(alignment: .bottom) { Theme.paper.frame(height: Self.lift + h * 0.2).allowsHitTesting(false) }
        // Pin the drawing to the bottom of the screen, its base just under the home indicator.
        .frame(maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(edges: .bottom)
    }
}

extension View {
    /// One screen behind the tissue tab bar: kept alive, shown, tappable and accessible only while selected.
    func tissueTab(_ tab: AppRouter.Tab, selected: AppRouter.Tab) -> some View {
        let on = tab == selected
        return tissueTabBarInset()
            .opacity(on ? 1 : 0)
            .allowsHitTesting(on)
            .accessibilityHidden(!on)
            .zIndex(on ? 1 : 0)
    }

    /// Keeps a tab's content clear of the tissue tab bar.
    func tissueTabBarInset() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: TissueTabBar.reserved) }
    }
}
