import Foundation

/// Close-contact time credited to one peer for the interval since it was last credited.
struct AccrualCredit: Equatable {
    var id: String
    /// Real seconds in [lastCreditedAt, now].
    var seconds: Double
    /// The peer's latest P(within 6 ft), clamped to [0, 1].
    var pClose: Double
    var risk: Risk
    /// The peer's latest distance-tier weight (Fusion.tierWeight), clamped to [0, 1].
    var tier: Double
}

/// Exposure from sighting timestamps rather than a 1 s timer, so it keeps accruing while iOS only
/// wakes FlUni now and then for a Bluetooth event.
///
/// Each peer remembers when it was last credited. When it is seen again (with a fresh distance
/// estimate) after a gap of at most `maxGap`, the whole gap [lastCreditedAt, now] is credited at its
/// latest pClose, risk and tier. A longer gap means it was probably gone, so nothing is credited.
/// Either way lastCreditedAt moves to now, so every second is credited at most once per ID, whether
/// the sighting came from the foreground timer or a background wake-up.
///
/// - The first sighting of an ID credits nothing (there is no earlier sighting to measure from).
/// - A clock that steps backwards credits nothing and re-anchors at the new time.
/// - An ID that rotates can't be linked over Bluetooth alone, so the new ID starts fresh (the gap
///   across the rotation is not credited). When the peer link does link them, `rename` carries the
///   old ID's time over so that gap is credited once.
struct SightingAccrual: Equatable {
    static let maxGap: TimeInterval = 5 * 60
    /// Accrual runs only when at least this much wall time has passed since the last run (keeps
    /// `AccrualFeed` small and back-to-back ticks from doing anything).
    static let minStep: TimeInterval = 0.5

    private(set) var lastCreditedAt: [String: Date] = [:]

    mutating func observe(_ id: String, at now: Date, pClose: Double, risk: Risk, tier: Double) -> AccrualCredit? {
        defer { lastCreditedAt[id] = now }
        guard let last = lastCreditedAt[id] else { return nil }
        let gap = now.timeIntervalSince(last)
        guard gap > 0, gap <= Self.maxGap else { return nil }
        return AccrualCredit(id: id, seconds: gap, pClose: Self.unit(pClose), risk: risk, tier: Self.unit(tier))
    }

    /// The peer link showed that `old` and `new` are the same phone: continue from the old ID's time.
    mutating func rename(from old: String, to new: String) {
        guard let t = lastCreditedAt.removeValue(forKey: old) else { return }
        lastCreditedAt[new] = max(t, lastCreditedAt[new] ?? t)
    }

    /// Forgets IDs that can no longer be credited.
    mutating func prune(now: Date) {
        lastCreditedAt = lastCreditedAt.filter { now.timeIntervalSince($0.value) <= Self.maxGap }
    }

    mutating func reset() { lastCreditedAt.removeAll() }

    private static func unit(_ x: Double) -> Double { x.isFinite ? min(max(x, 0), 1) : 0 }
}

/// Turns per-peer credits into one `ExposureTracker.advance` call, so the 15-minute rule, the 24 h
/// window and the dose stay exactly the tracker's own.
///
/// `advance(simSeconds: w, …)` moves the tracker's clock by w and credits every contact for w. A gap
/// credit can be longer than the wall time w since the previous accrual (another peer's sighting ran
/// the clock in between), so a credit of s seconds becomes ⌊s/w⌋ contacts at its pClose plus one at
/// pClose × the remainder (the tier is scaled the same way). Minutes and dose are linear in pClose
/// and tier, so the totals are exact while the clock moves by w only. Whole copies keep the real
/// pClose, so the "risky nearby" threshold still sees it.
enum AccrualFeed {
    static func contacts(_ credits: [AccrualCredit], wallSeconds w: Double)
        -> (contacts: [(pClose: Double, risk: Risk)], tiers: [Double]) {
        var contacts: [(pClose: Double, risk: Risk)] = []
        var tiers: [Double] = []
        guard w.isFinite, w > 0 else { return (contacts, tiers) }
        for c in credits where c.risk != .none && c.seconds.isFinite && c.seconds > 0 {
            let ratio = c.seconds / w
            let whole = Int((ratio + 1e-9).rounded(.down))
            for _ in 0 ..< whole {
                contacts.append((c.pClose, c.risk))
                tiers.append(c.tier)
            }
            let rest = ratio - Double(whole)
            if rest > 1e-9 {
                contacts.append((c.pClose * rest, c.risk))
                tiers.append(c.tier * rest)
            }
        }
        return (contacts, tiers)
    }
}
