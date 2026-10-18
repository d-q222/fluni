import SwiftUI
import UIKit

/// FlUni's named animations, so every screen moves the same way. Use these instead of `.default`, `.smooth`
/// or ad-hoc curves:
///
///     .animation(.motion(.gentle), value: band)          // follows Reduce Motion by itself (see below)
///     withMotion(.standard) { expanded.toggle() }
///     Text(RiskEstimate.liveText(p)).motionNumber(p)     // the live risk number's roll
///
/// Why springs: a spring is defined by its response, not by a frame count, so it is just as smooth at 120 Hz on a
/// ProMotion phone as at 60 Hz. When a change arrives mid-flight (the risk number updates every second; people tap
/// twice) a spring carries its current velocity into the new target, where a timed ease restarts with a jolt.
/// All of them are critically damped or close to it: a health app should feel calm, never bouncy.
///
/// Reduce Motion: each motion has a reduced form. Movement becomes instant or a short dissolve, and the number
/// changes in place instead of rolling. `.motion(_:)` and `withMotion` read the setting when called; in a view
/// body prefer the `.animation(_:value:)` modifier form below, which reads it from the environment.
struct Motion: Equatable, Sendable {
    let full: Animation
    /// What to use when Reduce Motion is on (nil = no animation).
    let reduced: Animation?

    /// UI feedback: toggles, selection, pressed and small reveals. 0.25 s, no overshoot, so it settles within
    /// ~30 frames at 120 Hz and never trails behind the finger. Reduce Motion: instant.
    static let quick = Motion(full: .spring(duration: 0.25, bounce: 0), reduced: nil)

    /// Sheets, cards expanding, content moving into place. 0.35 s with a hint of settle (bounce 0.08), close to
    /// the system sheet so custom expansion and sheets feel related. Reduce Motion: a 0.15 s dissolve-length ease.
    static let standard = Motion(full: .spring(duration: 0.35, bounce: 0.08), reduced: .easeInOut(duration: 0.15))

    /// State changes the person should notice without being startled: the risk band changing colour, a banner
    /// arriving, paused/active. Slower (0.6 s) and fully damped. Reduce Motion: a 0.2 s ease (colour and
    /// opacity still change softly; nothing travels).
    static let gentle = Motion(full: .spring(duration: 0.6, bounce: 0), reduced: .easeInOut(duration: 0.2))

    /// The live number's roll. 0.5 s, fully damped: it lands well before the next 1 s tick, and a tick that
    /// arrives early retargets the roll instead of restarting it. Pair with `numberTransition` (or use
    /// `motionNumber`). Reduce Motion: the digits change in place.
    static let number = Motion(full: .spring(duration: 0.5, bounce: 0), reduced: nil)

    /// The animation to use now, honouring the system Reduce Motion setting.
    var animation: Animation? { UIAccessibility.isReduceMotionEnabled ? reduced : full }

    func animation(reduceMotion: Bool) -> Animation? { reduceMotion ? reduced : full }

    /// The content transition for a number that changes (`.number`'s partner): digits roll toward the new value,
    /// or change in place under Reduce Motion.
    static func numberTransition(_ value: Double, reduceMotion: Bool) -> ContentTransition {
        reduceMotion ? .identity : .numericText(value: value)
    }
}

extension Animation {
    /// `.animation(.motion(.gentle), value: x)`. Reads Reduce Motion when the body runs.
    static func motion(_ m: Motion) -> Animation? { m.animation }
}

/// `withAnimation` for a Motion, honouring Reduce Motion.
@discardableResult
func withMotion<Result>(_ m: Motion, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(m.animation, body)
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let motion: Motion
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(motion.animation(reduceMotion: reduceMotion), value: value)
    }
}

private struct NumberModifier: ViewModifier {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .contentTransition(Motion.numberTransition(value, reduceMotion: reduceMotion))
            .animation(Motion.number.animation(reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// Animates changes to `value` with `motion`, following the environment's Reduce Motion.
    func animation<V: Equatable>(_ motion: Motion, value: V) -> some View {
        modifier(MotionModifier(motion: motion, value: value))
    }

    /// For a Text showing a changing number: the roll (`Motion.number` + numeric content transition), or an
    /// in-place change under Reduce Motion. Apply to the Text itself, keep `.monospacedDigit()` so the width
    /// doesn't jump.
    func motionNumber(_ value: Double) -> some View {
        modifier(NumberModifier(value: value))
    }
}
