import SwiftUI

/// Every animation in the redesigned screens, in one place, each returning nil under Reduce Motion.
/// (To be switched to SharedUI/Motion.swift's springs when that lands; the names match its roles.)
enum FlMotion {
    /// Small state flips: a sticker picked, a chip chosen, a press.
    static func quick(_ reduce: Bool) -> Animation? { reduce ? nil : .spring(response: 0.25, dampingFraction: 0.6) }
    /// A part of the screen changing: the status, the close contact opening in place.
    static func standard(_ reduce: Bool) -> Animation? { reduce ? nil : .snappy }
    /// The tissue's hop when its mood changes; the stamp landing.
    static func bouncy(_ reduce: Bool) -> Animation? { reduce ? nil : .spring(response: 0.3, dampingFraction: 0.5) }
    /// Lisa's stamp landing (her values from PR #4).
    static let stamp = Animation.spring(response: 0.3, dampingFraction: 0.55)
    /// The tissue's slow idle bob while all is clear.
    static func idle(_ reduce: Bool) -> Animation? { reduce ? nil : .easeInOut(duration: 2.4).repeatForever(autoreverses: true) }
    /// The live risk number ticking.
    static func number(_ reduce: Bool) -> Animation? { reduce ? nil : .smooth }
}
