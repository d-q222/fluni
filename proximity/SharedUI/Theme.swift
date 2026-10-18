import SwiftUI

/// "Campfire" palette and shape tokens, from Lisa Zheng's (lisaazheng) heat map design pass.
/// The app is forced to light mode (see FluniProxApp): the palette is defined and contrast-checked
/// on warm paper only, and a status colour that changes meaning in a dark variant is worse than none.
///
/// Contrast (WCAG 2.x), every foreground/background pair the apps use. Body text needs 4.5, large text
/// and icons/graphics 3. Tints are the token at the opacity the views use, over paper/surface.
///
///   foreground   paper  surface surface2  sage45% sun50% fire22%  fire    sage    sun
///   ink          13.6   14.3    12.5      10.5    11.6   10.8     4.47*   7.3     9.9
///   ink-2         6.6    7.0     6.1       5.1     5.6    5.3     2.2     3.6     4.8
///   ink-3         5.2    5.5     4.8       4.0*    4.5*   4.2*    1.7     2.8     3.8
///   fire-ink      6.9    7.3     6.3       5.3     5.9    5.5     2.3     3.7     5.0
///   white         1.1    1.0     1.2       1.4     1.3    1.4     3.3     2.0     1.5
///
/// Failures found and fixed (old -> new):
///   - ink on fire (the "Review and share" button fill): 4.47 -> paper text on fire-ink fill, 6.9.
///   - ember / sage progress bar on surface (graphic, needs 3): 2.3 / 2.0 -> ink-2 on surface 7.0.
///   - system-blue Done/Cancel/links on paper: ~3.8 -> ink (13.6), via .tint(Theme.ink) in FlUniApp.
///   - ink-3 is used only on paper (5.2) and on surface2 (4.8); never on a tinted fill. Don't add it to
///     sage/sun/fire tints (starred cells fail).
///   - Risk card tiers (sage / sun / fire tint) use ink or fire-ink for text, ink-2 for notes (all >= 5.1).
///   - Second a11y pass (map, banners, location, Demo, history):
///       system-grey Form footers, headers and LabeledContent values on surface/paper: 3.3 / 3.1 -> ink-2, 7.0 / 6.6.
///       system-red "Delete my data" on surface: 3.3 -> fire-ink, 7.3.
///       map key swatches (sage 2.0, sun 1.4 on surface, graphic needs 3) -> 1-2 pt ink-2 outline, 7.0; fire is 3.2.
///       high-building map mark: paper icon on fire-ink disc, 6.9; fire-ink warning icon on surface, 7.3.
///       close-contact history row: fire-ink on fire 18% over card 6.0, ink-2 5.8 (fire 22% is 5.5).
///       peach box (WalkInBanner): ink only, 8.6. ink-2 4.2, ink-3 3.3 and fire-ink 4.4 stay banned there.
///   * = below 4.5 for body text; do not use that pair.
enum Theme {
    static let sage = Color(hex: 0xacbc8b)      // healthy
    static let sun = Color(hex: 0xebd187)
    static let ember = Color(hex: 0xe99569)
    static let fire = Color(hex: 0xdb6c59)      // infected / alert (fills, never small text)
    static let fireInk = Color(hex: 0x8e3a28)   // alert text, 6.9:1 on paper
    static let paper = Color(hex: 0xfaf4e8)     // background
    static let surface = Color(hex: 0xfffaf1)
    static let surface2 = Color(hex: 0xf4ead6)
    static let ink = Color(hex: 0x33241c)       // text
    static let ink2 = Color(hex: 0x6a5244)
    static let ink3 = Color(hex: 0x7a6152)
    static let hairline = Color(red: 0x33 / 255, green: 0x24 / 255, blue: 0x1c / 255, opacity: 0.12)
    static let radius: CGFloat = 12
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

extension Font {
    /// Lisa's type (design pass): Nunito for text, Fredoka for titles and big numbers, matching the web.
    /// Static instances bundled in FlUni/Fonts (SIL OFL) and listed under UIAppFonts. `relativeTo:` keeps
    /// Dynamic Type. Targets without the fonts (the test harness) fall back to SF Rounded.
    static func fluni(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        guard FluniType.available else { return .system(style, design: .rounded, weight: weight) }
        let size = FluniType.baseSize(style)
        switch style {
        case .largeTitle, .title, .title2, .title3:
            return .custom(weight == .regular ? "Fredoka-Medium" : "Fredoka-SemiBold", size: size, relativeTo: style)
        default:
            let w = (style == .headline && weight == .regular) ? .semibold : weight
            let name = w == .bold || w == .heavy || w == .black ? "Nunito-Bold"
                : (w == .semibold || w == .medium) ? "Nunito-SemiBold" : "Nunito-Regular"
            return .custom(name, size: size, relativeTo: style)
        }
    }
}

extension Font {
    /// Fredoka (titles, numbers) at a size the text styles don't have, still scaled with Dynamic Type like `style`.
    static func fredoka(_ size: CGFloat, relativeTo style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        guard FluniType.available else { return .system(style, design: .rounded, weight: weight) }
        return .custom(weight == .medium || weight == .regular ? "Fredoka-Medium" : "Fredoka-SemiBold", size: size, relativeTo: style)
    }

    /// Nunito (text) at a size the text styles don't have, still scaled with Dynamic Type like `style`.
    static func nunito(_ size: CGFloat, relativeTo style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        guard FluniType.available else { return .system(style, design: .rounded, weight: weight) }
        let name = weight == .bold ? "Nunito-Bold" : (weight == .semibold || weight == .medium) ? "Nunito-SemiBold" : "Nunito-Regular"
        return .custom(name, size: size, relativeTo: style)
    }
}

enum FluniType {
    static let available = UIFont(name: "Nunito-Regular", size: 12) != nil && UIFont(name: "Fredoka-SemiBold", size: 12) != nil

    /// iOS's default (Large) Dynamic Type sizes, so custom fonts scale from the same base as the system ones.
    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline, .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        @unknown default: return 17
        }
    }

    /// Navigation titles ("Today", "Map", "Me") in Fredoka, scaled for Dynamic Type.
    static func styleNavigationBars() {
        guard available, let large = UIFont(name: "Fredoka-SemiBold", size: 34),
              let small = UIFont(name: "Fredoka-SemiBold", size: 17) else { return }
        let a = UINavigationBar.appearance()
        a.largeTitleTextAttributes = [.font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: large)]
        a.titleTextAttributes = [.font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: small)]
    }
}

/// Lisa's hand-drawn containers (heatmap/assets/containers), used as 9-slice images like the web's
/// `border-image: ... 34 30 80 64 fill / 9px 8px 21px 17px`. The PNGs are 960x579 px and used at scale 4
/// (240x144.75 pt), so the web's slice insets in image px become points by /4: top 34 -> 8.5,
/// trailing 30 -> 7.5, bottom 80 -> 20, leading 64 -> 16 (the web draws them at 9/8/21/17 css px, so
/// 4x gives the same border weight within a point).
///
/// Interior fills (sampled): paper fffbf4, peach ecbba0. Contrast of text on them:
///   paper: ink 14.4, ink-2 7.0, ink-3 5.6, fire-ink 7.3   (all pass 4.5)
///   peach: ink 8.6 (use ink only), ink-2 4.2*, ink-3 3.3*, fire-ink 4.4*   (* fail body text)
/// Under Increase Contrast or Differentiate Without Color the drawn box is replaced by a flat card
/// with a 1 pt ink border (14.3:1 / 8.6:1 text).
enum CardStyle {
    case paper, peach
    /// The harness target has no asset catalog, so it gets the flat card.
    var available: Bool { UIImage(named: self == .paper ? "BoxPaper" : "BoxPeach") != nil }
    /// actool rejects a "4x" scale, so the PNG sits in the catalog unscaled and is re-wrapped at scale 4 here.
    var image: Image {
        let name = self == .paper ? "BoxPaper" : "BoxPeach"
        guard let ui = UIImage(named: name), let cg = ui.cgImage else { return Image(name) }
        return Image(uiImage: UIImage(cgImage: cg, scale: 4, orientation: .up))
    }
    var flat: Color { self == .paper ? Theme.surface : Color(hex: 0xecbba0) }
}

/// A card drawn as Lisa's hand-drawn box. `fill` tints the inside of the box (risk tiers etc.).
struct Card: ViewModifier {
    var style: CardStyle = .paper
    var fill: Color? = nil
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    private static let cap = EdgeInsets(top: 8.5, leading: 16, bottom: 20, trailing: 7.5)
    private static let pad: CGFloat = 6   // breathing room inside the drawn edge

    func body(content: Content) -> some View {
        if contrast == .increased || differentiate || !style.available {
            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(fill ?? style.flat, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.ink, lineWidth: 1))
        } else {
            let c = Self.cap, p = Self.pad
            content
                .padding(EdgeInsets(top: c.top + p, leading: c.leading + p, bottom: c.bottom + p, trailing: c.trailing + p))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    ZStack {
                        style.image.resizable(capInsets: c, resizingMode: .stretch)
                        if let fill {
                            RoundedRectangle(cornerRadius: 6).fill(fill).padding(c)
                        }
                    }
                }
        }
    }
}

extension View {
    func card(_ style: CardStyle = .paper, fill: Color? = nil) -> some View { modifier(Card(style: style, fill: fill)) }
}

struct PrimaryButtonStyle: ButtonStyle {
    var fill: Color = Theme.sage
    var text: Color = Theme.ink
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.fluni(.headline))
            .foregroundStyle(text)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.radius))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// The home screen's chunky button (mockup v4): a fill, a 2 pt ink outline and an ink "shadow" under it that the
/// button sinks into when pressed. "I don't feel well" (sun) and the check-in answers (surface).
struct ChunkyButtonStyle: ButtonStyle {
    var fill: Color = Theme.sun
    var radius: CGFloat = 14
    var lift: CGFloat = 3
    var minHeight: CGFloat = 50

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.ink)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(fill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.ink, lineWidth: 2))
            .offset(y: configuration.isPressed ? lift : 0)
            .background(RoundedRectangle(cornerRadius: radius).fill(Theme.ink).offset(y: lift))
            .contentShape(Rectangle())
    }
}
