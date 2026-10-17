import SwiftUI

/// "Campfire" palette and shape tokens, from Lisa Zheng's (lisaazheng) heat map design pass.
/// The app is forced to light mode (see FluniProxApp): the palette is defined and contrast-checked
/// on warm paper only, and a status colour that changes meaning in a dark variant is worse than none.
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.fluni(.headline))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.radius))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Test launches (the Mac tools in tools/, stress.py) pass these on the command line and read the
/// "[fluni]" stdout lines; they must start immediately with no onboarding.
enum LaunchMode {
    static let testKeys = ["-risk", "-speed", "-sources", "-encryption", "-inviteTimeout", "-rotate", "-riskAfter", "-skipOnboarding"]
    static var isTestLaunch: Bool { ProcessInfo.processInfo.arguments.contains { testKeys.contains($0) } }
    static var isUnitTestHost: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }
}
