import Foundation

/// Pure rules that limit what a spoofed Bluetooth beacon can do to the exposure total.
/// Nothing authenticates a beacon, so these need no server and no product decision. Applied once per tick,
/// just before `ExposureTracker.advance`. Everything uses real time (`now`), which is clamped so a clock
/// that steps backwards never rewinds the state.
///
/// Rules and thresholds:
/// 1. Per-tick cap: only the top 2 risky contacts by pClose x risk weight count. One real person can't
///    give more than real time, and two real sick people beside you is the realistic maximum.
/// 2. Burst: more than `burstLimit` (4) IDs first seen as risky within `window` (5 min) raises `flagged`;
///    while flagged, Bluetooth-only contacts add nothing. A phone rotates its ID every 15 min, so normal
///    rotation adds at most 1 new ID per window and cannot trip it. Clears when the window has passed.
/// 3. Implausible signal (Bluetooth-only): RSSI above `maxRSSI` (-30 dBm) or a jump over `maxJump` (20 dB)
///    within `jumpWithin` (2 s) counts as not close for that tick. Field data: 0.3-0.8 m reads -60..-50 dBm,
///    the strongest at ~0.2 m was -42, so -30 leaves 12 dB margin; BLE noise is a few dB, so 20 dB is not noise.
/// 4. Risk flip: more than 1 risk change for one ID within `flipWindow` (15 min) -> ID ignored. A real phone
///    changes risk only when its user reports.
/// 5. `corroborated` = a fresh UWB reading exists for the ID. Reported only; no rule requires it.
struct ContactGuard {
    static let topContacts = 2
    static let window: TimeInterval = 300
    static let burstLimit = 4
    static let maxRSSI = -30.0
    static let maxJump = 20.0
    static let jumpWithin: TimeInterval = 2
    static let flipWindow: TimeInterval = 900

    struct Input {
        var id: String
        var risk: Risk
        var pClose: Double
        var tier: Double
        var rssi: Double? = nil
        var sources: [Source] = [.ble]
        var uwbAt: Date? = nil
    }

    struct Output: Equatable {
        var id: String
        var risk: Risk
        var pClose: Double
        var tier: Double
        var corroborated: Bool
    }

    /// True while an ID burst is in progress. The UI shows "unusual signals" while it is set.
    private(set) var flagged = false

    private var now = Date.distantPast
    private var firstRisky: [String: Date] = [:]
    private var lastRSSI: [String: (rssi: Double, at: Date)] = [:]
    private var lastRisk: [String: Risk] = [:]
    private var flips: [String: [Date]] = [:]
    private var flipLogged: Set<String> = []

    mutating func apply(now rawNow: Date, _ peers: [Input], log: (String) -> Void = { _ in }) -> [Output] {
        now = max(now, rawNow)
        prune()

        // Rule 4 and 2 bookkeeping.
        var ignored: Set<String> = []
        for p in peers {
            if let old = lastRisk[p.id], old != p.risk { flips[p.id, default: []].append(now) }
            lastRisk[p.id] = p.risk
            flips[p.id] = flips[p.id]?.filter { now.timeIntervalSince($0) < Self.flipWindow }
            if (flips[p.id]?.count ?? 0) > 1 {
                ignored.insert(p.id)
                if flipLogged.insert(p.id).inserted { log("guard risk flip id=\(p.id.prefix(6)) ignored") }
            } else {
                flipLogged.remove(p.id)
            }
            if p.risk != .none, firstRisky[p.id] == nil { firstRisky[p.id] = now }
        }
        let fresh = firstRisky.values.filter { now.timeIntervalSince($0) < Self.window }.count
        let wasFlagged = flagged
        flagged = fresh > Self.burstLimit
        if flagged && !wasFlagged { log("guard burst ids=\(fresh)") }

        // Rules 3 and 5, then rule 1 over what is left.
        var out: [Output] = []
        for p in peers {
            let uwbFresh = p.uwbAt.map { now.timeIntervalSince($0) < Source.uwb.maxAge && $0 <= now.addingTimeInterval(1) } ?? false
            let bleOnly = !uwbFresh && Set(p.sources) == [.ble]
            var pClose = p.pClose.isFinite ? min(max(p.pClose, 0), 1) : 0
            var tier = p.tier.isFinite ? min(max(p.tier, 0), 1) : 0
            var bad = ignored.contains(p.id) || (flagged && bleOnly)
            if let r = p.rssi, r.isFinite {
                if bleOnly {
                    if r > Self.maxRSSI { bad = true }
                    if let l = lastRSSI[p.id], now.timeIntervalSince(l.at) <= Self.jumpWithin,
                       abs(r - l.rssi) > Self.maxJump { bad = true }
                }
                lastRSSI[p.id] = (r, now)
            }
            if bad { pClose = 0; tier = 0 }
            out.append(Output(id: p.id, risk: p.risk, pClose: pClose, tier: tier, corroborated: uwbFresh))
        }
        let keep = Set(out.indices.filter { out[$0].risk != .none && out[$0].pClose > 0 }
            .sorted {
                let a = out[$0].pClose * out[$0].risk.weight, b = out[$1].pClose * out[$1].risk.weight
                return a != b ? a > b : out[$0].id < out[$1].id
            }.prefix(Self.topContacts))
        for i in out.indices where out[i].risk != .none && !keep.contains(i) { out[i].pClose = 0; out[i].tier = 0 }
        return out
    }

    private mutating func prune() {
        firstRisky = firstRisky.filter { now.timeIntervalSince($0.value) < Self.flipWindow }
        lastRSSI = lastRSSI.filter { now.timeIntervalSince($0.value.at) < Self.window }
        flips = flips.filter { $0.value.contains { now.timeIntervalSince($0) < Self.flipWindow } }
        if lastRisk.count > 500 { lastRisk.removeAll() }
    }
}
