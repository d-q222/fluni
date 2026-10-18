import Foundation

/// Close-contact time credited to one peer for the interval since it was last credited.
struct AccrualCredit: Equatable {
    var id: String
    /// Real seconds in [lastCreditedAt, now].
    var seconds: Double
    /// The peer's latest P(within 6 ft), clamped to [0, 1].
    var pClose: Double
    var risk: Risk
    /// The peer's latest fused distance in metres, for the risk dose; nil when it has none (no estimate,
    /// coarse GPS only, dropped by ContactGuard) or it is not a finite, non-negative number.
    var distance: Double?
    /// The peer's evidence level and stage from its latest sighting (ContactGuard.Output.s / .stage);
    /// nil = from `risk` with the illness-average stage.
    var s: Double? = nil
    var stage: Double? = nil

    /// The evidence level the dose uses.
    var level: Double { s ?? RiskEstimate.evidence(risk) }
}

/// Exposure from sighting timestamps rather than a 1 s timer, so it keeps accruing while iOS only
/// wakes FlUni now and then for a Bluetooth event.
///
/// Each peer remembers when it was last credited. When it is seen again (with a fresh distance
/// estimate) after a gap of at most `maxGap`, the whole gap [lastCreditedAt, now] is credited at its
/// latest pClose, risk and distance. A longer gap means it was probably gone, so nothing is credited.
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

    mutating func observe(_ id: String, at now: Date, pClose: Double, risk: Risk, distance: Double?,
                          s: Double? = nil, stage: Double? = nil) -> AccrualCredit? {
        defer { lastCreditedAt[id] = now }
        guard let last = lastCreditedAt[id] else { return nil }
        let gap = now.timeIntervalSince(last)
        guard gap > 0, gap <= Self.maxGap else { return nil }
        return AccrualCredit(id: id, seconds: gap, pClose: Self.unit(pClose), risk: risk,
                             distance: distance.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                             s: s.flatMap { $0.isFinite ? Self.unit($0) : nil },
                             stage: stage.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
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

/// Turns per-peer credits into one `ExposureTracker.advance` call, so the 15-minute rule, the 2 h
/// episode clock and the per-ID dose stay exactly the tracker's own.
///
/// `advance(simSeconds: w, …)` moves the tracker's clock by w and credits every contact for w. A gap
/// credit can be longer than the wall time w since the previous accrual (another peer's sighting ran
/// the clock in between), so a credit of s seconds becomes ⌊s/w⌋ contacts at its pClose plus one at
/// pClose × the remainder, whose dose covers that share of the tick (DosePeer.share). Minutes are linear
/// in pClose and the dose in time, so the totals are exact while the clock moves by w only. Whole copies
/// keep the real pClose, so the "risky nearby" threshold still sees it. Every copy carries the peer's ID,
/// distance, evidence level s, stage and this phone's room, so the dose lands on the right source.
/// A healthy-status peer whose score gives s > 0 is fed too: it adds dose but no minutes (weight 0).
enum AccrualFeed {
    static func contacts(_ credits: [AccrualCredit], wallSeconds w: Double, room: RiskEstimate.Room = .standard)
        -> (contacts: [(pClose: Double, risk: Risk)], doses: [DosePeer?]) {
        var contacts: [(pClose: Double, risk: Risk)] = []
        var doses: [DosePeer?] = []
        guard w.isFinite, w > 0 else { return (contacts, doses) }
        for c in credits where (c.risk != .none || c.level > 0) && c.seconds.isFinite && c.seconds > 0 {
            let ratio = c.seconds / w
            let whole = Int((ratio + 1e-9).rounded(.down))
            let dose = { (share: Double) in
                c.distance.map { DosePeer(id: c.id, distance: $0, share: share, s: c.s, stage: c.stage, room: room) }
            }
            for _ in 0 ..< whole {
                contacts.append((c.pClose, c.risk))
                doses.append(dose(1))
            }
            let rest = ratio - Double(whole)
            if rest > 1e-9 {
                contacts.append((c.pClose * rest, c.risk))
                doses.append(dose(rest))
            }
        }
        return (contacts, doses)
    }
}

/// The exposure step of `ProximityModel.tick`, without radios or UIKit, so tests drive the same code the
/// phone runs every second: credit each guarded peer that has a fresh estimate for [lastCreditedAt, now],
/// advance the tracker by the wall time × demo speed (minutes, per-ID dose and so p move on every tick, not
/// per minute), then set the heads-up level from everyone in range now (status only: a score never raises it).
enum ExposureTick {
    /// `wall`: seconds since the last accrual, already clamped by the caller. `accrues`: false for a
    /// back-to-back tick (under `SightingAccrual.minStep`), which only refreshes the heads-up level.
    /// `onCredit` sees each credit (the model logs background ones). Returns the contacts fed to the
    /// tracker when it accrued (for the exposure history), else nil.
    @discardableResult
    /// `room`: the air this phone is in now (RoomContext); the default room when unknown.
    static func run(guarded: [ContactGuard.Output], fresh: Set<String>, now: Date, wall: Double, speed: Double,
                    accrues: Bool, accrual: inout SightingAccrual, exposure e: inout ExposureTracker,
                    room: RiskEstimate.Room = .standard,
                    onCredit: (AccrualCredit) -> Void = { _ in }) -> [(pClose: Double, risk: Risk)]? {
        var fed: [(pClose: Double, risk: Risk)]?
        if accrues {
            var credits: [AccrualCredit] = []
            for g in guarded where fresh.contains(g.id) {
                guard let c = accrual.observe(g.id, at: now, pClose: g.pClose, risk: g.risk, distance: g.distance,
                                              s: g.s, stage: g.stage) else { continue }
                credits.append(c)
                onCredit(c)
            }
            accrual.prune(now: now)
            let feed = AccrualFeed.contacts(credits, wallSeconds: wall, room: room)
            e.advance(simSeconds: wall * speed, contacts: feed.contacts, doses: feed.doses)
            fed = feed.contacts
        }
        // The heads-up level from everyone in range now (adds nothing: zero seconds).
        e.advance(simSeconds: 0, contacts: guarded.map { ($0.pClose, $0.risk) })
        return fed
    }
}
