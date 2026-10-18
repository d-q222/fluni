import Foundation

/// When Lisa's opening animation plays: every time the student opens FlUni, never while nobody can see it.
/// FlUni keeps running in the background (Bluetooth), and iOS often launches it there with no one looking,
/// so "once per launch" would almost never be seen. Instead it plays on the first time the app is on screen
/// after being in the background (or after a cold launch), and not when the student only pulls down
/// Notification Centre or Control Centre (active -> inactive -> active).
struct IntroGate {
    enum Phase { case active, inactive, background }

    /// A cold launch counts as coming from the background.
    private var due = true

    /// Feed every scene phase change (and the phase at first appearance). True means: start the intro now.
    mutating func phase(_ p: Phase) -> Bool {
        switch p {
        case .background: due = true; return false
        case .inactive: return false
        case .active:
            defer { due = false }
            return due
        }
    }
}
