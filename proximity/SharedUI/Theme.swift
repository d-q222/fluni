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
    /// The stroke colour of Lisa's drawn boxes (sampled), for the hand-drawn rule. Decorative only, never text.
    static let pencil = Color(hex: 0x8a4e4a)

    // MARK: Shape
    /// One corner for every flat shape (buttons, fields, quiet panels, chips). Drawn boxes bring their own.
    static let radius: CGFloat = 12
    /// Strokes: `hairline` 1 pt between rows; 1.5 pt ink on secondary buttons and unchecked boxes;
    /// 2 pt ink marks the selected choice. No shadows anywhere: depth comes from Lisa's drawn edge.
    static let stroke: CGFloat = 1.5
    static let selectedStroke: CGFloat = 2
}

/// Spacing: a 4-pt grid. Use the names, not numbers.
///   xxs 4  inside a line (icon to text)      s 12  between rows of a group
///   xs  8  label to its value / note         m 16  page gutter, inside panels
///   l  24  between groups on a screen        xl 32 before a new part of the screen
enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
}

/// Surfaces, and what each one means. One hero per screen; everything else sits on paper.
///   paper          the page. Lists, numbers and prose sit straight on it, split by `HandRule` or hairlines.
///   drawn paper    `.card()`: the one thing that matters most on a screen (Today's status, a sheet's lead).
///   drawn peach    `.card(.peach)`: a heads-up that asks you to act (someone nearby, close contact). Ink text only.
///   tint in a box  `.card(fill:)`: sage = fine, sun = take care, fire 22% = act now. Only inside the hero.
///   quiet panel    `.panel()`: surface2, radius 12, no stroke. Asides: what is shared, privacy, banners.
///   peach strip    `.panel(.peach)`: a short heads-up that isn't the hero (walk-in).
enum Surface {}

/// Type roles. System rounded so Dynamic Type works; pick a role, never a raw size.
enum TextRole {
    /// Today's status, a sheet's lead headline. largeTitle bold.
    case display
    /// Screen part titles ("Recent contacts", "What to do"). title3 bold, a header for VoiceOver.
    case section
    /// Card titles, row titles, the question being asked. headline.
    case heading
    /// Reading text. body.
    case reading
    /// Row titles that are also the tap target. body semibold.
    case strong
    /// Supporting text under a heading. subheadline.
    case note
    /// Fine print: privacy lines, timestamps. footnote.
    case fine
    /// Numbers that are the point (minutes, %, day). largeTitle bold, tabular.
    case figure
}

extension Font {
    static func fluni(_ role: TextRole) -> Font {
        switch role {
        case .display: return .system(.largeTitle, design: .rounded, weight: .bold)
        case .section: return .system(.title3, design: .rounded, weight: .bold)
        case .heading: return .system(.headline, design: .rounded, weight: .semibold)
        case .reading: return .system(.body, design: .rounded)
        case .strong: return .system(.body, design: .rounded, weight: .semibold)
        case .note: return .system(.subheadline, design: .rounded)
        case .fine: return .system(.footnote, design: .rounded)
        case .figure: return .system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit()
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

extension Font {
    /// System rounded, so it follows Dynamic Type. (Hanken Grotesk, the web font, is a variable TTF whose
    /// weights SwiftUI can't be verified to select without running the app, so it isn't bundled.)
    static func fluni(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .rounded, weight: weight)
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

/// A flat quiet panel (see `Surface`): surface2, or Lisa's peach as a flat strip.
struct Panel: ViewModifier {
    var style: CardStyle = .paper
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .padding(Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style == .peach ? style.flat : Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay {
                if contrast == .increased { RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.ink, lineWidth: 1) }
            }
    }
}

extension View {
    func panel(_ style: CardStyle = .paper) -> some View { modifier(Panel(style: style)) }
}

/// A hand-drawn rule, cut at runtime from the top edge of Lisa's paper box (no new art). The cream fill is
/// keyed out so only her pencil line is left. Decorative: hidden from VoiceOver. Plain hairline elsewhere.
struct HandRule: View {
    var body: some View {
        Group {
            if let image = Self.image {
                Image(uiImage: image).resizable().foregroundStyle(Theme.pencil.opacity(0.55)).frame(height: 4)
            } else {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
        }
        .accessibilityHidden(true)
    }

    private static let image: UIImage? = {
        // Box top edge in image px (960x579 PNG): the straight run between the two rounded corners.
        guard let cg = UIImage(named: "BoxPaper")?.cgImage?.cropping(to: CGRect(x: 150, y: 0, width: 700, height: 18)) else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let made: CGImage? = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            let p = buf.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: p.count, by: 4) {
                let a = Double(p[i + 3])
                guard a > 0 else { continue }
                let lum = (Double(p[i]) + Double(p[i + 1]) + Double(p[i + 2])) / 3 * 255 / a   // un-premultiply
                let ink = min(max((225 - lum) / 120, 0), 1) * a / 255                         // dark pencil -> opaque
                p[i] = 0; p[i + 1] = 0; p[i + 2] = 0; p[i + 3] = UInt8(ink * 255)
            }
            return ctx.makeImage()
        }
        return made.map { UIImage(cgImage: $0, scale: 4, orientation: .up).withRenderingMode(.alwaysTemplate) }
    }()
}

/// The one filled action per state.
struct PrimaryButtonStyle: ButtonStyle {
    var fill: Color = Theme.sage
    var text: Color = Theme.ink
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.fluni(.heading))
            .foregroundStyle(text)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Space.m).padding(.vertical, Space.xs)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.radius))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Second choice next to a primary: ink outline on clear, same size and corner.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.fluni(.heading))
            .foregroundStyle(Theme.ink)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Space.m).padding(.vertical, Space.xs)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(configuration.isPressed ? Theme.surface2 : .clear, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.ink, lineWidth: Theme.stroke))
    }
}

/// A text-only way onward ("See the last 14 days"): ink-2 semibold, underlined, 44 pt tall.
struct QuietLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.fluni(.note).weight(.semibold))
            .foregroundStyle(Theme.ink2)
            .underline(true, color: Theme.ink2.opacity(0.5))
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
