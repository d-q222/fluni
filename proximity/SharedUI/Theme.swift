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
    /// System rounded, so it follows Dynamic Type. (Hanken Grotesk, the web font, is a variable TTF whose
    /// weights SwiftUI can't be verified to select without running the app, so it isn't bundled.)
    static func fluni(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .rounded, weight: weight)
    }
}

/// A flat card: surface fill, hairline border, 12 pt corners.
struct Card: ViewModifier {
    var fill: Color = Theme.surface
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.hairline, lineWidth: 1))
    }
}

extension View {
    func card(fill: Color = Theme.surface) -> some View { modifier(Card(fill: fill)) }
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
