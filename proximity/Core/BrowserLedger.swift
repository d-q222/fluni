import Foundation

/// Decides when a retired MCNearbyServiceBrowser may be deallocated. Pure, so it is unit-testable.
///
/// Why this exists (crash of 2026-10-17, see PeerLink's type comment): stopping an MPC browser is what
/// crashes. `stopBrowsingForPeers` and `dealloc` both stop MPC's internal NSNetServiceBrowser from MPC's
/// own background queue while it is scheduled on the main run loop. CFNetwork then runs a deferred
/// `_BrowserCancel` on the main thread, and it sometimes finds freed memory (Apple bug r. 60399638, no
/// fix). So PeerLink never stops a browser and never deallocates one that may still be browsing. A
/// retired browser is parked instead: delegate cleared, still browsing (passively, with no identity on
/// the air), until MPC stops it itself when the app goes to the background. That stop has always
/// happened on every trip to the background, and none of today's 19 crashes followed one. The parked
/// browser is released `grace` seconds later, while the app is still in the background.
struct BrowserLedger {
    enum State: Equatable {
        case idle                  // never started: no search to cancel, safe to release
        case browsing              // started while the app was active
        case stoppedByMPC(Date)    // MPC stopped it when the app went to the background
    }

    /// Parked browsers allowed at once. Past this, new identities advertise but don't browse until the
    /// app has been to the background (each one costs a passive Bonjour browse). At the 15 min rotation,
    /// 24 is 6 hours of continuous foreground.
    static let cap = 24
    /// Time after MPC's own stop before release, so its deferred cancel has run.
    static let grace: TimeInterval = 5

    private(set) var states: [Int: State] = [:]
    private(set) var parked: Set<Int> = []
    private(set) var inBackground = false

    init(inBackground: Bool = false) { self.inBackground = inBackground }

    var parkedCount: Int { parked.count }
    /// False when one more parked browser would pass the cap, so a new browser shouldn't start.
    var canStartBrowser: Bool { !inBackground && parked.count < Self.cap }

    mutating func add(_ b: Int) { states[b] = .idle }

    /// Only while the app is active: MPC can't browse in the background, and a browser started there
    /// would never get MPC's own stop, so it could never be released.
    mutating func started(_ b: Int) {
        guard states[b] != nil, !inBackground else { return }
        states[b] = .browsing
    }

    /// Retires a browser. True if it may be released at once (it never started).
    mutating func park(_ b: Int) -> Bool {
        guard let s = states[b] else { return false }
        if s == .idle { states[b] = nil; return true }
        parked.insert(b)
        return false
    }

    /// MPC stops every browsing browser now (its own didEnterBackground handler).
    mutating func enteredBackground(at now: Date) {
        inBackground = true
        for (b, s) in states where s == .browsing { states[b] = .stoppedByMPC(now) }
    }

    /// MPC restarts the browsers it stopped (its own willEnterForeground handler).
    mutating func willEnterForeground() {
        inBackground = false
        for (b, s) in states { if case .stoppedByMPC = s { states[b] = .browsing } }
    }

    /// Parked browsers that may be deallocated now: stopped by MPC at least `grace` ago, app still in
    /// the background. Forgets them.
    mutating func releasable(at now: Date) -> [Int] {
        guard inBackground else { return [] }
        let out = parked.filter { b in
            if case .stoppedByMPC(let at)? = states[b] { return now.timeIntervalSince(at) >= Self.grace }
            return false
        }
        for b in out { parked.remove(b); states[b] = nil }
        return out.sorted()
    }
}
