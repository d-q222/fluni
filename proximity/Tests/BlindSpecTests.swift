// Blind spec tests: written from the specification only (proximity/README.md, proximity/DEMO.md,
// WORKSTREAMS.md "Decisions", docs/PRD.md, docs/p-sick-format.md, docs/building-heat-format.md, and the
// other team's reference implementation of the shared risk rules in model/infer.js and heatmap/app.js),
// plus a signatures-only API digest. The implementation was not read. Every expected value below comes
// from the spec text cited in the comment above the test; behaviour the spec does not pin down is not
// asserted. A failing test here is a finding, not something to tune away.
//
// Updated after origin/main changed (still blind): the phone's risk estimate is Rio's formula (README "Risk
// estimate"), ContactGuard hardens against ID bursts, and README states Bluetooth accuracy as
// +-(70 % of distance + 0.3 m), +-(40 % + 0.3 m) once calibrated. Expected risk numbers were computed
// independently from model/infer.js `doseModel()` (node), never from the Swift implementation.

@testable import FluniProx
import CoreBluetooth
import XCTest

// MARK: - Helpers

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func la() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
}

private func localDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0, _ cal: Calendar = la()) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private func sim(_ iso: String) -> Double { PSickFeed.simSeconds(iso: iso)! }

/// One simulated nearby phone, as the README pipeline sees it: a (possibly rotating) beacon ID, a 3-level
/// risk, the ranging readings available at each moment, and the advert's RSSI.
private struct SimPeer {
    var id: (TimeInterval) -> String
    var risk: Risk
    var readings: (Date) -> [Reading]
    var rssi: Double?
    var active: (TimeInterval) -> Bool = { _ in true }
}

/// The foreground pipeline as README "How it works" describes it, composed from the pure types:
/// readings -> Fusion (1/sigma^2) -> P(within 6 ft) -> ContactGuard (anti-spoofing) -> ExposureTracker
/// (1 s timer, weighted minutes, 24 h window) -> AlertNotifier (heads-up, then close contact).
/// Runs at 1x demo speed, so sim time == wall time.
private struct Pipeline {
    var guardian = ContactGuard()
    var tracker = ExposureTracker()
    var notified = AlertLevel.none
    var notifications: [AlertLevel] = []
    var firstNearby: TimeInterval?
    var firstClose: TimeInterval?
    var elapsed: TimeInterval = 0

    mutating func step(_ peers: [SimPeer], dt: TimeInterval = 1) {
        elapsed += dt
        let now = t0.addingTimeInterval(elapsed)
        var inputs: [ContactGuard.Input] = []
        for p in peers where p.active(elapsed) {
            guard let e = Fusion.fuse(p.readings(now), now: now) else { continue }
            inputs.append(ContactGuard.Input(
                id: p.id(elapsed), risk: p.risk, pClose: Fusion.exposurePClose(e), distance: Fusion.isCoarseGPSOnly(e) ? nil : e.distance,
                rssi: p.rssi, sources: e.sources, uwbAt: e.sources.contains(.uwb) ? now : nil))
        }
        let out = guardian.apply(now: now, inputs)
        tracker.advance(simSeconds: dt, contacts: out.map { (pClose: $0.pClose, risk: $0.risk) }, doses: out.map { o in o.distance.map { DosePeer(id: o.id, distance: $0) } })
        let n = AlertNotifier.next(level: tracker.level, notified: notified)
        notified = n.notified
        if let x = n.notify { notifications.append(x) }
        if tracker.level >= .nearby, firstNearby == nil { firstNearby = elapsed }
        if tracker.level == .closeContact, firstClose == nil { firstClose = elapsed }
    }

    mutating func run(_ peers: [SimPeer], seconds: Int) {
        for _ in 0..<seconds { step(peers) }
    }
}

/// README channel table: UWB is "~10 cm".
private func uwbPeer(_ id: String, _ risk: Risk, meters: Double) -> SimPeer {
    SimPeer(id: { _ in id }, risk: risk,
            readings: { now in [Reading(source: .uwb, distance: meters, sigma: 0.1, at: now)] }, rssi: -60)
}

private func blePeer(_ id: String, _ risk: Risk, rssi: Double, active: @escaping (TimeInterval) -> Bool = { _ in true }) -> SimPeer {
    let cal = BLECalibrator()
    return SimPeer(id: { _ in id }, risk: risk, readings: { now in [cal.reading(rssi: rssi, at: now)] },
                   rssi: rssi, active: active)
}

/// Spec (README "Risk estimate"): p = 0.02, then per rotating ID p <- p + (1-p) * s * (1 - e^(-0.352 * dose)).
/// IDs are folded in the order given. Dose per second at d metres comes from infer.js (see `jsDosePerSecond`).
private func expectedP(_ sources: [(dose: Double, s: Double)]) -> Double {
    var p = 0.02
    for x in sources { p += (1 - p) * x.s * (1 - exp(-0.352 * x.dose)) }
    return p
}

/// infer.js `doseModel()({distance_m: d, duration_s: 900}) / 900`, computed with node (unit dose per second,
/// default room 50 m2 x 2.7 m, 2 ach, January indoor humidity). Distances in metres.
private let jsDose900: [Double: Double] = [
    0.5: 0.16986495140215704, 3: 0.007827914365119995, 1: 0.04486495140215703,
    10: 0.0036149514021570316, 0.3: 0.46616124769845335,
]

// MARK: - End-to-end glue scenarios

final class BlindPipelineTests: XCTestCase {

    // README "How it works" (Fusion, Exposure); WORKSTREAMS 2026-10-17 "Demo phone alerts follow the
    // proximity app" (immediate heads-up, close contact at 15 weighted minutes); DEMO.md 1:00 and 1:45.
    func testContagiousPeerAtHalfMetreByUWBBecomesCloseContactAt15Minutes() {
        var p = Pipeline()
        let peer = uwbPeer("peerA", .contagious, meters: 0.5)
        p.run([peer], seconds: 15 * 60 - 30)
        XCTAssertNotNil(p.firstNearby, "heads-up expected as soon as a contagious phone is probably within 6 ft")
        XCTAssertLessThanOrEqual(p.firstNearby ?? .infinity, 5, "heads-up should be immediate")
        XCTAssertNotEqual(p.tracker.level, .closeContact, "not yet 15 weighted minutes at 14.5 min")
        p.run([peer], seconds: 40)
        XCTAssertEqual(p.tracker.level, .closeContact, "15 weighted minutes within 6 ft of a contagious phone")
        XCTAssertEqual(p.tracker.minutes, 15.17, accuracy: 0.3)
        // README / DEMO: "ALERT nearby" within seconds, then "ALERT closeContact"; each once.
        XCTAssertEqual(p.notifications, [.nearby, .closeContact])
    }

    // README "Risk estimate": a contagious (tested positive, s = 0.97) peer 0.5 m away by UWB for 15 min.
    // Expected from infer.js: dose 0.169865, p = 0.075173 (Low: the new formula is far gentler at 0.5 m than the
    // old beta model, which gave ~22 %).
    func testRiskAfter15MinutesAtHalfMetreMatchesRioFormula() {
        var p = Pipeline()
        p.run([uwbPeer("peerA", .contagious, meters: 0.5)], seconds: 900)
        XCTAssertEqual(p.tracker.dose, jsDose900[0.5]!, accuracy: 1e-6)
        XCTAssertEqual(p.tracker.probability, 0.0751728192911298, accuracy: 1e-6)
        XCTAssertEqual(p.tracker.probability, expectedP([(jsDose900[0.5]!, 0.97)]), accuracy: 1e-6)
        XCTAssertEqual(RiskEstimate.band(p.tracker.probability), RiskEstimate.band(0.05), "7.5 % is Low")
        XCTAssertEqual(p.tracker.level, .closeContact, "the 15-weighted-minute alert is independent of the risk %")
    }

    // Same peer at 3 m by UWB for 15 min: not within 6 ft (no close contact) but inside 10 m, so it adds dose.
    // infer.js: dose 0.0078279, p = 0.0226157.
    func testRiskAfter15MinutesAtThreeMetres() {
        var p = Pipeline()
        p.run([uwbPeer("peerA", .contagious, meters: 3.0)], seconds: 900)
        XCTAssertEqual(p.tracker.dose, jsDose900[3]!, accuracy: 1e-6)
        XCTAssertEqual(p.tracker.probability, 0.0226157024771422, accuracy: 1e-6)
        XCTAssertNotEqual(p.tracker.level, .closeContact)
    }

    // README "Risk estimate": symptoms (Risk.possible) use s = 0.6. infer.js: p = 0.0541275 at 0.5 m for 15 min.
    func testRiskForSymptomsPeerUsesSixtyPercentEvidence() {
        var p = Pipeline()
        p.run([uwbPeer("peerS", .possible, meters: 0.5)], seconds: 900)
        XCTAssertEqual(p.tracker.dose, jsDose900[0.5]!, accuracy: 1e-6)
        XCTAssertEqual(p.tracker.probability, 0.05412751708729678, accuracy: 1e-6)
    }

    // README "Risk estimate": the dose of one source is not shared; "one person seen under two rotating IDs
    // counts as two sources". 450 s under each of two IDs at 0.5 m: infer.js doses 0.0849325 each, p = 0.0751976.
    func testRotatingIDMidContactCountsAsTwoSources() {
        var p = Pipeline()
        var peer = uwbPeer("x", .contagious, meters: 0.5)
        peer.id = { $0 <= 450 ? "rotA" : "rotB" }
        p.run([peer], seconds: 900)
        let half = jsDose900[0.5]! / 2
        XCTAssertEqual(p.tracker.dose, 2 * half, accuracy: 1e-6)
        XCTAssertEqual(p.tracker.probability, 0.07519755933909407, accuracy: 1e-6)
        XCTAssertEqual(p.tracker.sources.count, 2)
    }

    // README "Risk estimate": healthy peers add no dose; no contacts = the prior 0.02.
    func testPriorWithNoContactsAndHealthyPeersAddNothing() {
        let t = ExposureTracker()
        XCTAssertEqual(t.probability, 0.02, accuracy: 1e-12)
        XCTAssertEqual(t.dose, 0, accuracy: 1e-12)
        var p = Pipeline()
        p.run([uwbPeer("peerH", .none, meters: 0.3)], seconds: 600)
        XCTAssertEqual(p.tracker.probability, 0.02, accuracy: 1e-12)
        XCTAssertEqual(p.tracker.dose, 0, accuracy: 1e-12)
    }

    // README "Risk estimate": only d <= 10 m (inclusive) counts. 900 s at exactly 10.0 m adds the dose
    // 0.003614951 (p = 0.0212088); at 10.01 m nothing is added.
    func testDoseRangeBoundaryTenMetresInclusive() {
        var inside = ExposureTracker(), outside = ExposureTracker()
        for _ in 0..<900 {
            inside.advance(simSeconds: 1, contacts: [(pClose: 0, risk: .contagious)],
                           doses: [DosePeer(id: "a", distance: 10.0)])
            outside.advance(simSeconds: 1, contacts: [(pClose: 0, risk: .contagious)],
                            doses: [DosePeer(id: "a", distance: 10.01)])
        }
        XCTAssertEqual(inside.dose, jsDose900[10]!, accuracy: 1e-6)
        XCTAssertEqual(inside.probability, 0.0212088339653266, accuracy: 1e-6)
        XCTAssertEqual(outside.dose, 0, accuracy: 1e-12, "10.01 m is beyond Bluetooth range: no dose")
        XCTAssertEqual(outside.probability, 0.02, accuracy: 1e-12)
    }

    // README "Risk estimate": distance is clamped below at 0.3 m inside the dose (max(d, 0.3)).
    func testDoseDistanceFlooredAtThirtyCentimetres() {
        var near = ExposureTracker(), floor = ExposureTracker()
        for _ in 0..<900 {
            near.advance(simSeconds: 1, contacts: [(pClose: 1, risk: .contagious)], doses: [DosePeer(id: "a", distance: 0.1)])
            floor.advance(simSeconds: 1, contacts: [(pClose: 1, risk: .contagious)], doses: [DosePeer(id: "a", distance: 0.3)])
        }
        XCTAssertEqual(near.dose, jsDose900[0.3]!, accuracy: 1e-6)
        XCTAssertEqual(floor.dose, jsDose900[0.3]!, accuracy: 1e-6)
        XCTAssertEqual(floor.probability, 0.1638574429943885, accuracy: 1e-6)
    }

    // README "Risk estimate": "no estimate or coarse GPS alone adds nothing" to the dose.
    func testNoDoseWithoutDistanceEstimate() {
        var tr = ExposureTracker()
        for _ in 0..<600 { tr.advance(simSeconds: 1, contacts: [(pClose: 1, risk: .contagious)], doses: [nil]) }
        XCTAssertEqual(tr.dose, 0, accuracy: 1e-12)
        XCTAssertEqual(tr.probability, 0.02, accuracy: 1e-12)
        var p = Pipeline()
        let gps = SimPeer(id: { _ in "g" }, risk: .contagious,
                          readings: { now in [Reading(source: .gps, distance: 1, sigma: 15, at: now)] }, rssi: nil)
        p.run([gps], seconds: 600)
        XCTAssertEqual(p.tracker.dose, 0, accuracy: 1e-12, "coarse GPS alone adds nothing")
    }

    // README "Exposure": minutes += dt x P(<= 6 ft) x weight; 6 ft = 1.83 m. A peer at 3 m by UWB (+-10 cm)
    // is essentially never within 6 ft.
    func testSamePeerAtThreeMetresNeverAlerts() {
        var p = Pipeline()
        p.run([uwbPeer("peerA", .contagious, meters: 3.0)], seconds: 2 * 3600)
        XCTAssertNil(p.firstClose)
        XCTAssertNil(p.firstNearby, "P(within 6 ft) at 3 m +- 10 cm is ~0, below the 0.5 heads-up threshold")
        XCTAssertLessThan(p.tracker.minutes, 0.1)
        XCTAssertTrue(p.notifications.isEmpty)
    }

    // README channel table (Bluetooth LE beacon works on its own, +-50-70 %); README Run: `pair_test.sh ble`
    // (one channel only) still alerts; DEMO 1:00 (phones within 1 m). -50 dBm is phones side by side.
    func testBluetoothOnlyAtPlausibleRSSIAlertsAndReachesCloseContact() {
        var p = Pipeline()
        p.run([blePeer("peerB", .contagious, rssi: -50)], seconds: 30 * 60)
        XCTAssertNotNil(p.firstNearby, "BLE-only side by side should give the heads-up")
        XCTAssertLessThanOrEqual(p.firstNearby ?? .infinity, 10)
        XCTAssertNotNil(p.firstClose, "BLE-only side by side should reach close contact within 30 min (P >= 0.5)")
    }

    // Product rule (anti-spoofing): a burst of many new contagious IDs within a few minutes must not create a
    // close contact. 40 fake contagious IDs appear within 2 minutes and then all stay, BLE only, strong RSSI.
    func testSpoofBurstOfNewContagiousIDsNeverCreatesCloseContact() {
        var p = Pipeline()
        let spoofers = (0..<40).map { i in
            blePeer("spoof\(i)", .contagious, rssi: -45, active: { $0 >= Double(i) * 3 })
        }
        p.run(spoofers, seconds: 20 * 60)
        XCTAssertNil(p.firstClose, "a burst of 40 new contagious IDs within 2 min created a close contact at \(p.firstClose ?? -1) s")
        XCTAssertNotEqual(p.tracker.level, .closeContact)
    }

    // Same rule, sustained churn: a new contagious ID every 5 s, each visible for 60 s (12 new IDs a minute,
    // i.e. a burst in every few-minute window) for 20 minutes.
    func testSpoofChurnOfShortLivedContagiousIDsNeverCreatesCloseContact() {
        var p = Pipeline()
        let spoofers = (0..<240).map { i -> SimPeer in
            let start = Double(i) * 5
            return blePeer("churn\(i)", .contagious, rssi: -45, active: { $0 >= start && $0 < start + 60 })
        }
        p.run(spoofers, seconds: 20 * 60)
        XCTAssertNil(p.firstClose, "ID churn created a close contact at \(p.firstClose ?? -1) s")
    }

    // README "How it works": the random ID changes every 15 min; anti-spoofing rule: one real contagious
    // person for 15 sim-minutes must create a close contact. The ID rotates 7 min into the contact.
    func testIDRotationMidContactStillGivesCloseContactAt15Minutes() {
        var p = Pipeline()
        var peer = uwbPeer("x", .contagious, meters: 0.5)
        peer.id = { $0 < 420 ? "rotA" : "rotB" }
        p.run([peer], seconds: 15 * 60 + 30)
        XCTAssertNotNil(p.firstClose, "rotation mid-contact lost minutes: \(p.tracker.minutes) weighted min after 15.5 min")
    }

    // README "Exposure": weight 0.5 for possibly sick. 15 weighted minutes takes 30 real minutes.
    func testPossiblySickPeerCountsHalf() {
        var p = Pipeline()
        let peer = uwbPeer("peerP", .possible, meters: 0.5)
        p.run([peer], seconds: 20 * 60)
        XCTAssertEqual(p.tracker.minutes, 10, accuracy: 0.3)
        XCTAssertNotNil(p.firstNearby, "a possibly-sick phone within 6 ft is risky: heads-up expected")
        p.run([peer], seconds: 9 * 60)
        XCTAssertNotEqual(p.tracker.level, .closeContact, "29 min x 0.5 = 14.5 weighted minutes")
        p.run([peer], seconds: 90)
        XCTAssertEqual(p.tracker.level, .closeContact, "30.5 min x 0.5 = 15.25 weighted minutes")
    }

    // A healthy phone right next to you never alerts (README: weight 0 for healthy; product rule).
    func testHealthyPeerNeverAlerts() {
        var p = Pipeline()
        p.run([uwbPeer("peerH", .none, meters: 0.3)], seconds: 30 * 60)
        XCTAssertNil(p.firstNearby)
        XCTAssertEqual(p.tracker.minutes, 0, accuracy: 1e-9)
    }

    // WORKSTREAMS 2026-10-17 "GPS alone doesn't count as close contact": GPS-only evidence with error > 10 m
    // never adds close-contact minutes. GPS says 1 m apart, +-15 m.
    func testGPSOnlyWithCoarseErrorNeverAddsMinutes() {
        var p = Pipeline()
        let peer = SimPeer(id: { _ in "gpsPeer" }, risk: .contagious,
                           readings: { now in [Reading(source: .gps, distance: 1, sigma: 15, at: now)] }, rssi: nil)
        p.run([peer], seconds: 60 * 60)
        XCTAssertEqual(p.tracker.minutes, 0, accuracy: 1e-9)
        XCTAssertNil(p.firstClose)
    }

    // Product rule: close contact = 15 weighted minutes in a rolling 24 h of simulated time
    // (WORKSTREAMS "Demo phone alerts follow the proximity app"; heatmap/app.js EXPOSURE_WINDOW_MS).
    func testCloseContactExpiresAfter24Hours() {
        var p = Pipeline()
        p.run([uwbPeer("peerA", .contagious, meters: 0.5)], seconds: 16 * 60)
        XCTAssertEqual(p.tracker.level, .closeContact)
        for _ in 0..<(24 * 60 + 20) { p.tracker.advance(simSeconds: 60, contacts: []) }
        XCTAssertEqual(p.tracker.minutes, 0, accuracy: 0.1, "minutes older than 24 h must drop out")
        XCTAssertEqual(p.tracker.level, .none)
    }

    // Same rule, the window is rolling: 10 min, a 23 h gap, 6 min -> 16 in the last 24 h -> close contact;
    // once the first 10 min are older than 24 h only 6 remain -> no longer a close contact.
    func testRollingWindowAddsAcrossGapAndDropsOldMinutes() {
        var tr = ExposureTracker()
        for _ in 0..<600 { tr.advance(simSeconds: 1, contacts: [(pClose: 1, risk: .contagious)]) }
        for _ in 0..<(23 * 60 - 10) { tr.advance(simSeconds: 60, contacts: []) }
        for _ in 0..<360 { tr.advance(simSeconds: 1, contacts: [(pClose: 1, risk: .contagious)]) }
        XCTAssertEqual(tr.minutes, 16, accuracy: 0.2)
        XCTAssertEqual(tr.level, .closeContact)
        for _ in 0..<70 { tr.advance(simSeconds: 60, contacts: []) }   // now 24 h 16 min after the start
        XCTAssertEqual(tr.minutes, 6, accuracy: 0.2)
        XCTAssertNotEqual(tr.level, .closeContact)
    }

    // README "Background": a re-sighting within 5 min credits the whole gap at its latest P(<= 6 ft); a longer
    // gap credits nothing. Backgrounded phone, contagious peer seen every 3 min -> every gap credited.
    func testBackgroundSightingsEvery3MinutesAccrueToCloseContact() {
        var acc = SightingAccrual()
        var tr = ExposureTracker()
        var closeAt: TimeInterval?
        var t: TimeInterval = 0
        while t <= 30 * 60 {
            if let c = acc.observe("bg", at: t0 + t, pClose: 1, risk: .contagious, distance: 0.5) {
                tr.advance(simSeconds: c.seconds, contacts: [(pClose: c.pClose, risk: c.risk)], doses: [c.distance.map { DosePeer(id: "bg", distance: $0) }])
            }
            if t == 12 * 60 { XCTAssertNotEqual(tr.level, .closeContact, "only 12 min credited at t = 12 min") }
            if closeAt == nil, tr.level == .closeContact { closeAt = t }
            t += 180
        }
        XCTAssertEqual(tr.minutes, 30, accuracy: 0.01, "10 gaps of 3 min all credited")
        XCTAssertNotNil(closeAt)
        XCTAssertLessThanOrEqual(closeAt ?? .infinity, 18 * 60)
    }

    // Same section: sightings every 10 min (> 5 min gaps) credit nothing.
    func testBackgroundSightingsEvery10MinutesCreditNothing() {
        var acc = SightingAccrual()
        var tr = ExposureTracker()
        var t: TimeInterval = 0
        while t <= 60 * 60 {
            if let c = acc.observe("bg", at: t0 + t, pClose: 1, risk: .contagious, distance: 0.5) {
                XCTAssertEqual(c.seconds, 0, accuracy: 1e-9, "a 10-min gap must credit nothing")
                tr.advance(simSeconds: c.seconds, contacts: [(pClose: c.pClose, risk: c.risk)], doses: [c.distance.map { DosePeer(id: "bg", distance: $0) }])
            }
            t += 600
        }
        XCTAssertEqual(tr.minutes, 0, accuracy: 1e-9)
        XCTAssertNotEqual(tr.level, .closeContact)
    }
}

// MARK: - Fusion, freshness, P(close), GPS rule

final class BlindFusionTests: XCTestCase {

    // Product rule "Freshness": BLE 6 s, GPS 20 s. README "Fusion" (updated): a UWB reading keeps full weight for
    // 3 s, then stays usable to 6 s, so its maximum age is now 6 s (was 3 s).
    func testFreshnessPerSource() {
        XCTAssertEqual(Source.uwb.maxAge, 6)
        XCTAssertEqual(Source.ble.maxAge, 6)
        XCTAssertEqual(Source.gps.maxAge, 20)
    }

    // README "Fusion": fresh readings are averaged, weighted by 1/sigma^2.
    func testInverseVarianceAverage() {
        let r = [Reading(source: .uwb, distance: 0.5, sigma: 0.1, at: t0),
                 Reading(source: .ble, distance: 3.0, sigma: 1.5, at: t0)]
        let e = Fusion.fuse(r, now: t0)
        let w1 = 1 / 0.01, w2 = 1 / 2.25
        XCTAssertEqual(e?.distance ?? .nan, (w1 * 0.5 + w2 * 3.0) / (w1 + w2), accuracy: 0.005)
        XCTAssertEqual(Set(e?.sources ?? []), [.uwb, .ble])
    }

    // README "Fusion" (UWB dominates when present; BLE/GPS take over when it drops out) + freshness rule.
    func testStaleReadingsAreDropped() {
        let now = t0
        // README "Fusion" (updated): UWB keeps full weight to 3 s, usable to 6 s with sigma growing 1 m/s.
        // At 7 s it is gone, so only BLE (5 s old, fresh) remains; GPS at 21 s is stale (> 20 s).
        let r = [Reading(source: .uwb, distance: 0.5, sigma: 0.1, at: now - 7),
                 Reading(source: .ble, distance: 2.0, sigma: 1.0, at: now - 5),
                 Reading(source: .gps, distance: 9.0, sigma: 3.0, at: now - 21)]
        let e = Fusion.fuse(r, now: now)
        XCTAssertEqual(e?.sources, [.ble])
        XCTAssertEqual(e?.distance ?? .nan, 2.0, accuracy: 1e-6)
        // A UWB reading 4 s old is in its grace period: sigma 0.1 + 1 m/s x (4 - 3) s = 1.1, still fused.
        let g = Fusion.fuse([Reading(source: .uwb, distance: 0.5, sigma: 0.1, at: now - 4), r[1]], now: now)
        XCTAssertEqual(Set(g?.sources ?? []), [.uwb, .ble])
        let w1 = 1 / (1.1 * 1.1), w2 = 1.0
        XCTAssertEqual(g?.distance ?? .nan, (w1 * 0.5 + w2 * 2.0) / (w1 + w2), accuracy: 0.01)
        XCTAssertEqual(Fusion.fuse([Reading(source: .gps, distance: 5, sigma: 5, at: now - 19)], now: now)?.sources, [.gps])
        XCTAssertNil(Fusion.fuse([Reading(source: .uwb, distance: 0.5, sigma: 0.1, at: now - 10)], now: now))
        XCTAssertNil(Fusion.fuse([], now: now))
    }

    // Product rule: close contact is within 6 ft (1.83 m). README: "The result is P(within 6 ft)".
    func testPCloseIsProbabilityWithinSixFeet() {
        XCTAssertEqual(Fusion.closeDistance, 1.83, accuracy: 0.002)
        XCTAssertGreaterThan(Fusion.pClose(Estimate(distance: 0.5, sigma: 0.1, sources: [.uwb])), 0.99)
        XCTAssertLessThan(Fusion.pClose(Estimate(distance: 3.0, sigma: 0.1, sources: [.uwb])), 0.01)
        XCTAssertEqual(Fusion.pClose(Estimate(distance: 1.83, sigma: 0.3, sources: [.uwb])), 0.5, accuracy: 0.05)
        XCTAssertEqual(Fusion.normalCDF(0), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Fusion.normalCDF(1.959964), 0.975, accuracy: 1e-4)
    }

    // WORKSTREAMS 2026-10-17 "GPS alone doesn't count as close contact": error > 10 m never counts.
    func testCoarseGPSOnlyNeverCounts() {
        XCTAssertEqual(Fusion.maxGPSOnlySigma, 10)
        let coarse = Estimate(distance: 1, sigma: 15, sources: [.gps])
        XCTAssertTrue(Fusion.isCoarseGPSOnly(coarse))
        XCTAssertEqual(Fusion.exposurePClose(coarse), 0)
        XCTAssertFalse(Fusion.isCoarseGPSOnly(Estimate(distance: 1, sigma: 15, sources: [.gps, .ble])), "not GPS alone")
        XCTAssertFalse(Fusion.isCoarseGPSOnly(Estimate(distance: 1, sigma: 8, sources: [.gps])), "error <= 10 m")
        XCTAssertFalse(Fusion.isCoarseGPSOnly(Estimate(distance: 1, sigma: 10, sources: [.gps])), "rule is > 10 m")
        // A single GPS reading's error survives fusion, so "error > 10 m" is judged on the GPS error.
        let fused = Fusion.fuse([Reading(source: .gps, distance: 1, sigma: 15, at: t0)], now: t0)
        XCTAssertEqual(fused?.sigma ?? .nan, 15, accuracy: 1e-6)
        XCTAssertTrue(fused.map(Fusion.isCoarseGPSOnly) ?? false)
    }

    // (The old distance-tier weight test is gone: the dose now uses the fused distance itself, see the
    // risk tests below.)

    // README channel table: Bluetooth RSSI is "+-(70 % of the distance + 0.3 m); +-(40 % + 0.3 m) once
    // calibrated against UWB". Read as the reading's sigma = fraction x distance + 0.3 m.
    func testBLEReadingUncertaintyIs70PercentPlus30cmThen40Percent() {
        var cal = BLECalibrator()
        XCTAssertFalse(cal.isCalibrated)
        for rssi in stride(from: -80.0, through: -45.0, by: 5) {
            let r = cal.reading(rssi: rssi, at: t0)
            XCTAssertEqual(r.source, .ble)
            XCTAssertEqual(r.at, t0)
            XCTAssertEqual(r.sigma, 0.7 * r.distance + 0.3, accuracy: 0.02, "uncalibrated, rssi \(rssi)")
        }
        XCTAssertGreaterThan(cal.distance(rssi: -80), cal.distance(rssi: -60), "weaker signal = farther")
        // Calibrate against UWB truth (a model phone at the default power).
        let n = cal.pathLossExponent
        for i in 0..<100 {
            let d = 0.5 + Double(i % 10) * 0.25
            cal.observe(rssi: BLECalibrator.defaultTxPower - 10 * n * log10(d), trueDistance: d)
        }
        XCTAssertTrue(cal.isCalibrated)
        for rssi in stride(from: -80.0, through: -45.0, by: 5) {
            let r = cal.reading(rssi: rssi, at: t0)
            XCTAssertEqual(r.sigma, 0.4 * r.distance + 0.3, accuracy: 0.02, "calibrated, rssi \(rssi)")
        }
    }

    // README "Fusion": while UWB is live it calibrates the Bluetooth model for that phone pair, so
    // Bluetooth-only ranging improves afterwards. Simulated phone that is 6 dB quieter than the default.
    func testUWBCalibrationImprovesBluetoothRanging() {
        var cal = BLECalibrator()
        let n = cal.pathLossExponent
        let trueTx = BLECalibrator.defaultTxPower - 6
        func rssi(at d: Double) -> Double { trueTx - 10 * n * log10(d) }
        let before = abs(cal.distance(rssi: rssi(at: 2)) - 2)
        for i in 0..<100 {
            let d = 0.5 + Double(i % 10) * 0.25
            cal.observe(rssi: rssi(at: d), trueDistance: d)
        }
        let after = abs(cal.distance(rssi: rssi(at: 2)) - 2)
        XCTAssertLessThan(after, before, "Bluetooth-only ranging should improve after UWB calibration")
        XCTAssertTrue(cal.isCalibrated)
    }

    // README "Fusion" (calibration carries over for that phone pair): a learned prior seeds the calibrator.
    func testTxPowerPriorSeedsCalibrator() {
        XCTAssertFalse(TxPowerPrior().isLearned)
        XCTAssertFalse(BLECalibrator().startedFromPrior)
        XCTAssertEqual(BLECalibrator().txPower, BLECalibrator.defaultTxPower)
        var prior = TxPowerPrior()
        prior.learn(BLECalibrator.defaultTxPower - 5)
        XCTAssertTrue(prior.isLearned)
        let c = BLECalibrator.fromPrior(prior)
        XCTAssertTrue(c.startedFromPrior)
        XCTAssertEqual(c.txPower, prior.txPower, accuracy: 1e-9)
    }

    // RSSIWindow: the spec says nothing about the smoother; only properties any smoother must have.
    func testRSSIWindowBasicProperties() {
        var w = RSSIWindow()
        var last = 0.0
        for i in 0..<10 { last = w.add(-60, at: t0 + Double(i)) }
        XCTAssertEqual(last, -60, accuracy: 1e-9, "a constant signal smooths to itself")
        XCTAssertEqual(w.lastAt, t0 + 9)
        let v = w.add(-40, at: t0 + 10)
        XCTAssertGreaterThanOrEqual(v, -60)
        XCTAssertLessThanOrEqual(v, -40)
    }
}

// MARK: - Exposure, alerts, background accrual, contact guard

final class BlindExposureTests: XCTestCase {

    // Product rules: 15 weighted minutes, 24 h; README "Risk tiers"/shared statuses; README "Exposure" weights.
    func testConstantsAndWeights() {
        XCTAssertEqual(ExposureTracker.closeContactMinutes, 15)
        XCTAssertEqual(ExposureTracker.window, 24 * 3600)
        XCTAssertEqual(Risk.contagious.weight, 1)
        XCTAssertEqual(Risk.possible.weight, 0.5)
        XCTAssertEqual(Risk.none.weight, 0)
        // README "Accessibility & copy": the three statuses are always "healthy", "possibly sick", "contagious".
        XCTAssertEqual(Risk.none.label.lowercased(), "healthy")
        XCTAssertEqual(Risk.possible.label.lowercased(), "possibly sick")
        XCTAssertEqual(Risk.contagious.label.lowercased(), "contagious")
    }

    // README "Exposure": minutes += dt x P(<= 6 ft) x weight.
    func testMinutesFormula() {
        var a = ExposureTracker(), b = ExposureTracker(), c = ExposureTracker()
        for _ in 0..<60 {
            a.advance(simSeconds: 1, contacts: [(pClose: 0.5, risk: .contagious)])
            b.advance(simSeconds: 1, contacts: [(pClose: 0.5, risk: .possible)])
            c.advance(simSeconds: 1, contacts: [(pClose: 1.0, risk: .none)])
        }
        XCTAssertEqual(a.minutes, 0.5, accuracy: 1e-6)
        XCTAssertEqual(b.minutes, 0.25, accuracy: 1e-6)
        XCTAssertEqual(c.minutes, 0, accuracy: 1e-9)
    }

    // Product rule "Nearby heads-up": at P(within 6 ft) >= 0.5, with hysteresis down to 0.3.
    func testNearbyHysteresis() {
        var tr = ExposureTracker()
        tr.advance(simSeconds: 1, contacts: [(pClose: 0.4, risk: .contagious)])
        XCTAssertEqual(tr.level, .none, "0.4 is below the 0.5 trigger")
        tr.advance(simSeconds: 1, contacts: [(pClose: 0.6, risk: .contagious)])
        XCTAssertEqual(tr.level, .nearby)
        tr.advance(simSeconds: 1, contacts: [(pClose: 0.35, risk: .contagious)])
        XCTAssertEqual(tr.level, .nearby, "hysteresis keeps the heads-up down to 0.3")
        tr.advance(simSeconds: 1, contacts: [(pClose: 0.2, risk: .contagious)])
        XCTAssertEqual(tr.level, .none, "below 0.3 the heads-up clears")
        var t2 = ExposureTracker()
        t2.advance(simSeconds: 1, contacts: [(pClose: 0.5, risk: .possible)])
        XCTAssertEqual(t2.level, .nearby, "possibly sick is risky too; >= 0.5 triggers")
        var t3 = ExposureTracker()
        t3.advance(simSeconds: 1, contacts: [(pClose: 1.0, risk: .none)])
        XCTAssertEqual(t3.level, .none, "a healthy phone is not risky")
    }

    // README Run / DEMO: B logs ALERT nearby, then ALERT closeContact, each once.
    func testAlertNotifierEscalatesOnce() {
        XCTAssertEqual(AlertNotifier.next(level: .nearby, notified: .none).notify, .nearby)
        XCTAssertEqual(AlertNotifier.next(level: .nearby, notified: .none).notified, .nearby)
        XCTAssertNil(AlertNotifier.next(level: .nearby, notified: .nearby).notify)
        XCTAssertEqual(AlertNotifier.next(level: .closeContact, notified: .nearby).notify, .closeContact)
        XCTAssertNil(AlertNotifier.next(level: .closeContact, notified: .closeContact).notify)
        XCTAssertNil(AlertNotifier.next(level: .none, notified: .none).notify)
    }

    // Product rule "Background accrual" + README "Background": gaps up to 5 min credited, longer ones not.
    func testSightingAccrualGapRule() {
        XCTAssertEqual(SightingAccrual.maxGap, 300)
        var a = SightingAccrual()
        let first = a.observe("p", at: t0, pClose: 0.8, risk: .contagious, distance: 0.5)
        XCTAssertEqual(first?.seconds ?? 0, 0, accuracy: 1e-9, "a first sighting has no gap to credit")
        let c = a.observe("p", at: t0 + 300, pClose: 0.7, risk: .contagious, distance: 0.5)
        XCTAssertEqual(c?.seconds ?? 0, 300, accuracy: 1e-9, "a 5-min gap is credited in full")
        XCTAssertEqual(c?.pClose ?? 0, 0.7, accuracy: 1e-9, "at its latest P(<= 6 ft)")
        let d = a.observe("p", at: t0 + 601, pClose: 0.7, risk: .contagious, distance: 0.5)
        XCTAssertEqual(d?.seconds ?? 0, 0, accuracy: 1e-9, "a 301-s gap credits nothing")
        let e = a.observe("p", at: t0 + 661, pClose: 0.7, risk: .contagious, distance: 0.5)
        XCTAssertEqual(e?.seconds ?? 0, 60, accuracy: 1e-9, "after a long gap, the next short gap counts again")
    }

    // README "Background": the 1 s timer goes through the same per-peer bookkeeping, so no second counts twice.
    func testTimerAndSightingsNeverDoubleCount() {
        var a = SightingAccrual()
        var total = 0.0
        for s in 0...600 {
            total += a.observe("p", at: t0 + Double(s), pClose: 1, risk: .contagious, distance: 0.5)?.seconds ?? 0
            if s == 300 { total += a.observe("p", at: t0 + 300.5, pClose: 1, risk: .contagious, distance: 0.5)?.seconds ?? 0 }
        }
        XCTAssertLessThanOrEqual(total, 600 + 1e-6, "more seconds credited than elapsed")
        XCTAssertGreaterThanOrEqual(total, 600 - SightingAccrual.minStep - 1e-6)
    }

    // README "How it works" (ID rotates every 15 min) + "Background": rotation must not break the gap.
    func testAccrualSurvivesIDRotation() {
        var a = SightingAccrual()
        _ = a.observe("A1", at: t0, pClose: 1, risk: .contagious, distance: 0.5)
        _ = a.observe("A1", at: t0 + 180, pClose: 1, risk: .contagious, distance: 0.5)
        a.rename(from: "A1", to: "A2")
        let c = a.observe("A2", at: t0 + 360, pClose: 1, risk: .contagious, distance: 0.5)
        XCTAssertEqual(c?.seconds ?? 0, 180, accuracy: 1e-9)
    }

    // README "Background": a credited gap goes into exposure at its P; the feed must credit the whole gap.
    func testAccrualFeedCreditsWholeGap() {
        let credits = [AccrualCredit(id: "p", seconds: 120, pClose: 1, risk: .contagious, distance: 0.5)]
        let fed = AccrualFeed.contacts(credits, wallSeconds: 60)
        var tr = ExposureTracker()
        tr.advance(simSeconds: 60, contacts: fed.contacts, doses: fed.doses)
        XCTAssertEqual(tr.minutes, 2, accuracy: 0.01, "120 s at P = 1, contagious = 2 weighted minutes")
    }
}

// MARK: - Risk tiers, advice, cross-team agreement

final class BlindRiskAgreementTests: XCTestCase {

    // README "Risk estimate" (constants from infer.js DEFAULTS), heatmap/app.js TIERS {elevated 0.1, high 0.4}.
    func testConstantsMatchModelAndHeatMap() {
        XCTAssertEqual(RiskEstimate.prior, 0.02)
        XCTAssertEqual(RiskEstimate.posTest, 0.97)
        XCTAssertEqual(RiskEstimate.selfReport, 0.6)
        XCTAssertEqual(RiskEstimate.quantaPeak, 10)
        XCTAssertEqual(RiskEstimate.breathingRate, 0.5)
        XCTAssertEqual(RiskEstimate.doseRange, 10)
        XCTAssertEqual(RiskEstimate.minDistance, 0.3)
        XCTAssertEqual(RiskEstimate.stage, 0.352, accuracy: 1e-9, "the illness-average stage factor")
        XCTAssertEqual(RiskEstimate.elevatedFrom, 0.1)
        XCTAssertEqual(RiskEstimate.highFrom, 0.4)
        XCTAssertEqual(PSickFeed.prior, 0.02)
    }

    // README "Risk estimate": unit dose values against infer.js doseModel (node), 15 min at each distance.
    func testUnitDoseMatchesInferJS() {
        for (d, dose) in jsDose900 {
            XCTAssertEqual(RiskEstimate.unitDose(distance: d, seconds: 900), dose, accuracy: 1e-9, "d = \(d)")
        }
        XCTAssertEqual(RiskEstimate.unitDose(distance: 0.5, seconds: 1), 0.00018873883489128562, accuracy: 1e-12)
    }

    // README "Risk estimate": p <- p + (1-p) s (1 - e^(-0.352 dose)) per ID; prior with none; evidence mapping.
    func testProbabilityFormula() {
        XCTAssertEqual(RiskEstimate.probability([:]), 0.02, accuracy: 1e-12)
        XCTAssertEqual(RiskEstimate.probability(["a": .init(dose: 0.5, s: 0.97)]),
                       expectedP([(0.5, 0.97)]), accuracy: 1e-9)
        XCTAssertEqual(RiskEstimate.probability(["a": .init(dose: 0.5, s: 0.6)]),
                       expectedP([(0.5, 0.6)]), accuracy: 1e-9)
        // Two sources fold one after the other (order does not matter for this formula).
        XCTAssertEqual(RiskEstimate.probability(["a": .init(dose: 0.169865, s: 0.97), "b": .init(dose: 0.007828, s: 0.6)]),
                       0.07669969037097955, accuracy: 1e-5)
        XCTAssertEqual(RiskEstimate.probability(["a": .init(dose: 0, s: 0.97)]), 0.02, accuracy: 1e-12)
        XCTAssertEqual(RiskEstimate.probability(["a": .init(dose: 1000, s: 0.97)]), 0.02 + 0.98 * 0.97, accuracy: 1e-9,
                       "huge dose saturates at prior + (1 - prior) * s")
        XCTAssertEqual(RiskEstimate.evidence(.contagious), 0.97)
        XCTAssertEqual(RiskEstimate.evidence(.possible), 0.6)
        XCTAssertEqual(RiskEstimate.evidence(.none), 0)
    }

    // Tier cut-offs at the dose level: a tested-positive source with dose 0.2494201 gives p = 0.0999, dose
    // 0.2500727 gives p = 0.1001 (Low / Elevated); doses 1.4495162 and 1.4505120 give 0.3999 / 0.4001
    // (Elevated / High). Doses solved by hand from the README formula.
    func testBandBoundariesViaDose() {
        func band(_ dose: Double) -> RiskEstimate.Band {
            RiskEstimate.band(RiskEstimate.probability(["a": .init(dose: dose, s: 0.97)]))
        }
        XCTAssertEqual(band(0.2494201089356225), RiskEstimate.band(0.05))
        XCTAssertEqual(band(0.2500727413967765), RiskEstimate.band(0.2))
        XCTAssertEqual(band(1.4495161552194507), RiskEstimate.band(0.2))
        XCTAssertEqual(band(1.4505119172664165), RiskEstimate.band(0.9))
    }

    // Product rule / heatmap/app.js riskTier: low < 10 %, elevated 10-40 %, high >= 40 %.
    func testBandBoundaries() {
        let low = RiskEstimate.band(0), elevated = RiskEstimate.band(0.2), high = RiskEstimate.band(0.9)
        XCTAssertNotEqual(low, elevated); XCTAssertNotEqual(elevated, high); XCTAssertNotEqual(low, high)
        XCTAssertEqual(RiskEstimate.band(0.0999), low)
        XCTAssertEqual(RiskEstimate.band(0.1), elevated)
        XCTAssertEqual(RiskEstimate.band(0.3999), elevated)
        XCTAssertEqual(RiskEstimate.band(0.4), high)
    }

    // heatmap/app.js advice(p) ("FlUni RiskEstimate.summary"): must be equal strings.
    func testSummaryEqualsHeatMapAdvice() {
        XCTAssertEqual(RiskEstimate.summary(0.05), "Low. No action needed.")
        XCTAssertEqual(RiskEstimate.summary(0.0999), "Low. No action needed.")
        XCTAssertEqual(RiskEstimate.summary(0.1), "Elevated. Wear a mask in crowded rooms and watch for symptoms.")
        XCTAssertEqual(RiskEstimate.summary(0.25), "Elevated. Wear a mask in crowded rooms and watch for symptoms.")
        XCTAssertEqual(RiskEstimate.summary(0.4), "High. Consider getting tested at Vaden and staying home.")
        XCTAssertEqual(RiskEstimate.summary(0.97), "High. Consider getting tested at Vaden and staying home.")
    }

    // heatmap/app.js percentText ("FlUni's RiskEstimate.percentText"): "0%" only for exactly zero, "<1%" for
    // small non-zero, otherwise whole percent capped at 100.
    func testPercentTextMatchesHeatMap() {
        XCTAssertEqual(RiskEstimate.percentText(0), "0%")
        XCTAssertEqual(RiskEstimate.percentText(0.004), "<1%")
        XCTAssertEqual(RiskEstimate.percentText(0.02), "2%")
        XCTAssertEqual(RiskEstimate.percentText(0.2174), "22%")
        XCTAssertEqual(RiskEstimate.percentText(0.314), "31%")
        XCTAssertEqual(RiskEstimate.percentText(1), "100%")
    }

    // heatmap/app.js ADVICE ("FlUni's Advice strings (proximity/Core/Exposure.swift)"); DEMO 1:00 and 1:45.
    func testAdviceStringsEqualHeatMap() {
        XCTAssertEqual(Advice.title(.nearby), "Someone within 6 ft may be sick")
        XCTAssertEqual(Advice.body(.nearby), ["Put 6 ft or more between you, or step outside.",
                                              "Consider wearing a mask while you're here."])
        XCTAssertEqual(Advice.title(.closeContact), "You were close to someone who may be sick")
        XCTAssertEqual(Advice.body(.closeContact), [
            "You've spent about 15 minutes within 6 ft of someone who may be sick.",
            "Leave the room now, or move well away and put on a mask.",
            "Wash your hands; avoid touching your face.",
            "Watch for fever, cough or sore throat over the next 1–4 days.",
            "If symptoms start, get tested and report it in FlUni.",
        ])
    }
}

// MARK: - Feeds, building heat, live clock, walk-in warning

final class BlindFeedTests: XCTestCase {

    private let heatCSV = """
    t_iso,building_id,name,lat,lon,people,expected_sick,heat,high,radius_m
    2026-01-10T16:30:00,bld_1,"Green Library, East",37.4269,-122.1670,200,12.5,0.81,1,60
    2026-01-10T16:30:00,bld_2,Tresidder,,,50,0.5,0.1,0,
    2026-01-10T16:30:00,bld_3,Old Union,37.4250,-122.1700,100,1.0,0.2,0,40
    2026-01-10T16:45:00,bld_1,"Green Library, East",37.4269,-122.1670,250,20,0.9,1,60
    2026-01-10T16:45:00,bld_3,Old Union,37.4250,-122.1700,120,1.5,0.25,0,40
    2026-01-10T17:00:00,bld_1,"Green Library, East",37.4269,-122.1670,100,1,0.1,0,60

    """

    // docs/p-sick-format.md: change points; last row with t_iso <= t; before the first row, the prior 0.02.
    func testPSickFeedChangePoints() throws {
        let csv = "agent_id,t_iso,p_sick\nA0001,2026-01-05T10:00:00,0.1000\nA0001,2026-01-05T12:00:00,0.5000\nA0002,2026-01-06T00:00:00,0.9700\n"
        let f = try PSickFeed.parse(csv)
        XCTAssertEqual(PSickFeed.header, "agent_id,t_iso,p_sick")
        XCTAssertEqual(Set(f.agents), ["A0001", "A0002"])
        XCTAssertEqual(f.rowCount, 3)
        XCTAssertEqual(f.p(agent: "A0001", at: sim("2026-01-05T09:00:00")), 0.02, accuracy: 1e-9)
        XCTAssertEqual(f.p(agent: "A0001", at: sim("2026-01-05T10:00:00")), 0.1, accuracy: 1e-9)
        XCTAssertEqual(f.p(agent: "A0001", at: sim("2026-01-05T11:59:00")), 0.1, accuracy: 1e-9)
        XCTAssertEqual(f.p(agent: "A0001", at: sim("2026-01-05T12:00:00")), 0.5, accuracy: 1e-9)
        XCTAssertEqual(f.p(agent: "A0001", at: sim("2026-01-09T00:00:00")), 0.5, accuracy: 1e-9)
        XCTAssertEqual(f.p(agent: "A0002", at: sim("2026-01-05T23:59:00")), 0.02, accuracy: 1e-9)
        XCTAssertEqual(f.p(agent: "A9999", at: sim("2026-01-06T00:00:00")), 0.02, accuracy: 1e-9)
        XCTAssertEqual(sim("2026-01-05T10:01:00") - sim("2026-01-05T10:00:00"), 60, accuracy: 1e-9)
        XCTAssertEqual(sim("2026-01-06T00:00:00") - sim("2026-01-05T00:00:00"), 86400, accuracy: 1e-9)
    }

    // docs/building-heat-format.md: columns, quoted names, empty lat/lon, snapshots (latest t_iso <= t),
    // missing building = "no data", high = heat >= 0.5.
    func testBuildingHeatParseAndSnapshots() throws {
        XCTAssertEqual(BuildingHeat.header, "t_iso,building_id,name,lat,lon,people,expected_sick,heat,high")
        XCTAssertEqual(BuildingHeat.headerWithRadius, "t_iso,building_id,name,lat,lon,people,expected_sick,heat,high,radius_m")
        let h = try BuildingHeat.parse(heatCSV)
        XCTAssertEqual(h.buildings["bld_1"]?.name, "Green Library, East")
        XCTAssertEqual(h.buildings["bld_1"]?.radius ?? 0, 60, accuracy: 1e-9)
        XCTAssertNil(h.buildings["bld_2"]?.lat)
        XCTAssertEqual(h.buildings["bld_2"]?.hasGeometry, false)
        XCTAssertFalse(h.mappable.contains { $0.id == "bld_2" })
        XCTAssertTrue(h.mappable.contains { $0.id == "bld_1" })
        XCTAssertNil(h.state(at: sim("2026-01-10T16:29:00")))
        XCTAssertEqual(h.state(at: sim("2026-01-10T16:55:00"))?.t ?? .nan, sim("2026-01-10T16:45:00"), accuracy: 1e-6)
        let r = h.reading("bld_1", at: sim("2026-01-10T16:55:00"))
        XCTAssertEqual(r?.people ?? 0, 250, accuracy: 1e-9)
        XCTAssertEqual(r?.expectedSick ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(r?.high, true)
        XCTAssertNil(h.reading("bld_2", at: sim("2026-01-10T16:55:00")), "absent from the snapshot = no data")
        XCTAssertEqual(h.reading("bld_3", at: sim("2026-01-10T16:55:00"))?.high, false)
        XCTAssertEqual(BuildingHeat.tier(heat: 0.9, high: true), .high)
        XCTAssertEqual(BuildingHeat.tier(heat: 0.0, high: false), .low)
        XCTAssertNotEqual(BuildingHeat.tier(heat: 0.3, high: false), .high)
    }

    // Geometry needed for "Warn users when they enter such a location" (PRD 2.2): great-circle metres.
    func testHaversineAndInside() throws {
        XCTAssertEqual(BuildingHeat.haversine(37, -122, 38, -122), 111_195, accuracy: 600)
        let h = try BuildingHeat.parse(heatCSV)
        XCTAssertEqual(h.inside(lat: 37.4271, lon: -122.1670)?.id, "bld_1", "22 m from a 60 m-radius building")
        XCTAssertNil(h.inside(lat: 37.4369, lon: -122.1670), "1.1 km away")
        XCTAssertEqual(h.nearest(lat: 37.4271, lon: -122.1670)?.building.id, "bld_1")
    }

    // docs/building-heat-format.md "Which moment is 'now'": worked example (default run starts Monday
    // 2026-01-05; Saturday 4:55 pm -> 2026-01-10 16:55, the 16:45 row).
    func testLiveClockWorkedExample() throws {
        let cal = la()
        let now = localDate(2026, 10, 17, 16, 55, cal)   // a Saturday
        XCTAssertEqual(cal.component(.weekday, from: now), 7)
        let run = sim("2026-01-05T00:00:00")...sim("2026-01-18T23:55:00")
        let t = LiveClock.simTime(now: now, calendar: cal, run: run)
        XCTAssertEqual(t, sim("2026-01-10T16:55:00"), accuracy: 1, "first run day with the same weekday")
        let h = try BuildingHeat.parse(heatCSV)
        XCTAssertEqual(h.state(at: t)?.t ?? .nan, sim("2026-01-10T16:45:00"), accuracy: 1e-6)
    }

    // Same section, rules 3 and 4: weekday missing -> day (daysSinceMonday mod runDays); clamp to first/last step.
    func testLiveClockShortRunFallbackAndClamp() {
        let cal = la()
        let run = sim("2026-01-05T08:00:00")...sim("2026-01-06T20:00:00")   // Mon 08:00 - Tue 20:00, 2 days
        // Saturday: 5 mod 2 = 1 -> Tuesday.
        XCTAssertEqual(LiveClock.simTime(now: localDate(2026, 10, 17, 12, 0, cal), calendar: cal, run: run),
                       sim("2026-01-06T12:00:00"), accuracy: 1)
        // Sunday: 6 mod 2 = 0 -> Monday.
        XCTAssertEqual(LiveClock.simTime(now: localDate(2026, 10, 18, 10, 0, cal), calendar: cal, run: run),
                       sim("2026-01-05T10:00:00"), accuracy: 1)
        // Monday 07:00 is before the first step -> clamp.
        XCTAssertEqual(LiveClock.simTime(now: localDate(2026, 10, 19, 7, 0, cal), calendar: cal, run: run),
                       sim("2026-01-05T08:00:00"), accuracy: 1)
        // Tuesday 21:00 is after the last step -> clamp.
        XCTAssertEqual(LiveClock.simTime(now: localDate(2026, 10, 20, 21, 0, cal), calendar: cal, run: run),
                       sim("2026-01-06T20:00:00"), accuracy: 1)
    }

    // Product rule "Walk-in warning: at most once per building per 2 h"; DEMO 3:00 (banner text; the same
    // building only notifies once per cool-down, the banner still shows); building-heat-format (high flag).
    // Glue: device clock -> LiveClock -> snapshot -> inside() -> reading -> WalkInWarning.
    func testWalkInWarningGlueAndCooldown() throws {
        XCTAssertEqual(WalkInWarning.cooldown, 2 * 3600)
        let cal = la()
        let h = try BuildingHeat.parse(heatCSV)
        let run = sim("2026-01-05T00:00:00")...sim("2026-01-18T23:55:00")
        let device = localDate(2026, 10, 17, 16, 50, cal)
        let t = LiveClock.simTime(now: device, calendar: cal, run: run)
        let b = h.inside(lat: 37.4270, lon: -122.1670)
        XCTAssertEqual(b?.id, "bld_1")
        let r = b.flatMap { h.reading($0.id, at: t) }
        var w = WalkInWarning()
        let first = w.evaluate(now: device, building: b, reading: r, paused: false)
        XCTAssertEqual(first.bannerBuilding?.id, "bld_1")
        XCTAssertTrue(first.notify)
        let again = w.evaluate(now: device + 30 * 60, building: b, reading: r, paused: false)
        XCTAssertEqual(again.bannerBuilding?.id, "bld_1", "the banner still shows during the cool-down")
        XCTAssertFalse(again.notify)
        XCTAssertFalse(w.evaluate(now: device + 119 * 60, building: b, reading: r, paused: false).notify)
        XCTAssertTrue(w.evaluate(now: device + 121 * 60, building: b, reading: r, paused: false).notify)
        // Another high building notifies on its own cool-down.
        var w2 = WalkInWarning()
        _ = w2.evaluate(now: device, building: b, reading: r, paused: false)
        let other = BuildingHeat.Reading(people: 300, expectedSick: 30, heat: 0.95, high: true)
        let b3 = h.buildings["bld_3"]
        XCTAssertTrue(w2.evaluate(now: device + 60, building: b3, reading: other, paused: false).notify)
    }

    // Same rule: no warning for a building that is not high, for "no data", or while detection is paused.
    func testWalkInWarningNegativeCases() throws {
        let h = try BuildingHeat.parse(heatCSV)
        let t = sim("2026-01-10T16:50:00")
        var w = WalkInWarning()
        let calm = w.evaluate(now: t0, building: h.buildings["bld_3"], reading: h.reading("bld_3", at: t), paused: false)
        XCTAssertNil(calm.bannerBuilding); XCTAssertFalse(calm.notify)
        let noData = w.evaluate(now: t0, building: h.buildings["bld_2"], reading: nil, paused: false)
        XCTAssertNil(noData.bannerBuilding); XCTAssertFalse(noData.notify)
        let nowhere = w.evaluate(now: t0, building: nil, reading: nil, paused: false)
        XCTAssertNil(nowhere.bannerBuilding); XCTAssertFalse(nowhere.notify)
        let paused = w.evaluate(now: t0, building: h.buildings["bld_1"], reading: h.reading("bld_1", at: t), paused: true)
        XCTAssertFalse(paused.notify, "DEMO 4:15: paused = detection stops")
    }

    // DEMO 3:00 and heatmap/app.js walk-in card: "<Building> has a lot of illness right now. Consider a mask,
    // or a different spot."
    func testWalkInMessage() {
        XCTAssertEqual(WalkInWarning.message(for: "Green Library"),
                       "Green Library has a lot of illness right now. Consider a mask, or a different spot.")
    }
}

// MARK: - Self report, pause, history

final class BlindPersonalTests: XCTestCase {

    private let reporter = SelfReporter(calendar: la())

    // Product rule "Isolation": 5 days from symptom onset or positive test, plus 24 h fever-free.
    func testIsolationConstants() {
        XCTAssertEqual(IsolationPolicy.days, 5)
        XCTAssertEqual(IsolationPolicy.feverFreeHours, 24)
    }

    // README "Me": "I have symptoms" -> possibly sick; "I tested positive" -> contagious; digest ReportError.
    func testReportsSetStatus() throws {
        let now = localDate(2026, 10, 12)
        let s = try reporter.reportSymptoms(SelfReportRecord(), symptoms: [.cough], onset: now - 86400, now: now)
        XCTAssertEqual(s.risk, .possible)
        let p = try reporter.reportPositive(SelfReportRecord(), kind: .rapid, date: now, now: now)
        XCTAssertEqual(p.risk, .contagious)
        XCTAssertThrowsError(try reporter.reportSymptoms(SelfReportRecord(), symptoms: [], onset: now, now: now)) {
            XCTAssertEqual($0 as? ReportError, .noSymptoms)
        }
        XCTAssertThrowsError(try reporter.reportPositive(SelfReportRecord(), kind: .pcr, date: now + 2 * 86400, now: now)) {
            XCTAssertEqual($0 as? ReportError, .dateInFuture)
        }
        XCTAssertThrowsError(try reporter.reportSymptoms(SelfReportRecord(), symptoms: [.fever], onset: now + 2 * 86400, now: now)) {
            XCTAssertEqual($0 as? ReportError, .dateInFuture)
        }
    }

    // Product rule: a negative test never clears "tested positive".
    func testNegativeNeverClearsPositive() throws {
        let d = localDate(2026, 10, 12)
        let p = try reporter.reportPositive(SelfReportRecord(), kind: .pcr, date: d, now: d)
        let now = d + 86400
        if let n = try? reporter.reportNegative(p, kind: .rapid, date: now, now: now) {
            XCTAssertEqual(n.risk, .contagious)
            XCTAssertNotNil(n.positiveDate)
        }
    }

    // Product rule "Isolation": inside the 5 days the status can't be cleared; after 5 days and 24 h without
    // fever it can; with a fever in the last 24 h it can't. Exact day-5/day-6 boundary deliberately avoided.
    func testIsolationClearing() throws {
        let d = localDate(2026, 10, 12)
        let p = try reporter.reportPositive(SelfReportRecord(), kind: .pcr, date: d, now: d)
        XCTAssertEqual(reporter.phase(SelfReportRecord(), now: d), .notIsolating)
        if case .inProgress = reporter.phase(p, now: d + 2 * 86400) {} else {
            XCTFail("2 days after a positive test isolation is in progress, got \(reporter.phase(p, now: d + 2 * 86400))")
        }
        XCTAssertThrowsError(try reporter.reportFine(p, now: d + 3 * 86400)) {
            XCTAssertEqual($0 as? ReportError, .notYetClearable)
        }
        let late = d + 7 * 86400
        XCTAssertEqual(reporter.phase(p, now: late), .periodOver(feverFree: true))
        XCTAssertEqual(try reporter.reportFine(p, now: late).risk, .none)
        let feverish = reporter.checkIn(p, stillSymptomatic: true, hasFever: true, now: late - 2 * 3600)
        XCTAssertEqual(reporter.phase(feverish, now: late), .periodOver(feverFree: false))
        XCTAssertThrowsError(try reporter.reportFine(feverish, now: late)) {
            XCTAssertEqual($0 as? ReportError, .notYetClearable)
        }
    }

    // Product rule "Isolation": 24 h fever-free.
    func testFeverFree() throws {
        let now = localDate(2026, 10, 20)
        var r = SelfReportRecord()
        XCTAssertTrue(reporter.isFeverFree(r, now: now))
        r.lastFeverAt = now - 23 * 3600
        XCTAssertFalse(reporter.isFeverFree(r, now: now))
        r.lastFeverAt = now - 25 * 3600
        XCTAssertTrue(reporter.isFeverFree(r, now: now))
        // A fever reported at a check-in during isolation starts the 24 h clock. (What a check-in does on a
        // record that isn't isolating is not specified, so it isn't asserted.)
        let pos = try reporter.reportPositive(SelfReportRecord(), kind: .pcr, date: now - 2 * 86400, now: now - 2 * 86400)
        let c = reporter.checkIn(pos, stillSymptomatic: true, hasFever: true, now: now)
        XCTAssertEqual(c.lastFeverAt, now)
        XCTAssertFalse(reporter.isFeverFree(c, now: now + 23 * 3600))
    }

    // The status persists (README: "when the status was set"; DEMO: only "Delete my data" undoes a positive).
    func testSelfReportFileRoundTrip() throws {
        let d = Date(timeIntervalSince1970: 1_790_000_000)
        let r = try reporter.reportPositive(SelfReportRecord(), kind: .pcr, date: d, now: d)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blind-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(SelfReportFile.save(r, to: url))
        let suite = "blind-\(UUID().uuidString)"
        XCTAssertEqual(SelfReportFile.load(url: url, defaults: UserDefaults(suiteName: suite)!), r)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    // Product rule "Pause options: 1 h, until tomorrow, until resumed"; digest: untilTomorrow = next local midnight.
    func testPauseSchedule() {
        let cal = la()
        let now = localDate(2026, 10, 17, 23, 30, cal)
        XCTAssertEqual(PauseSchedule.until(.oneHour, from: now, calendar: cal), now + 3600)
        XCTAssertEqual(PauseSchedule.until(.untilTomorrow, from: now, calendar: cal), localDate(2026, 10, 18, 0, 0, cal))
        let early = localDate(2026, 10, 17, 0, 10, cal)
        XCTAssertEqual(PauseSchedule.until(.untilTomorrow, from: early, calendar: cal), localDate(2026, 10, 18, 0, 0, cal))
        XCTAssertNil(PauseSchedule.until(.untilResumed, from: now, calendar: cal))
        let hour = PauseSchedule.state(.oneHour, from: now, calendar: cal)
        XCTAssertEqual(hour.since, now)
        XCTAssertFalse(PauseSchedule.shouldResume(hour, now: now + 59 * 60))
        XCTAssertTrue(PauseSchedule.shouldResume(hour, now: now + 61 * 60))
        let forever = PauseSchedule.state(.untilResumed, from: now, calendar: cal)
        XCTAssertFalse(PauseSchedule.shouldResume(forever, now: now + 20 * 3600), "until resumed = until the student turns it back on")
    }

    // Product rule "Exposure history keeps 14 days"; heatmap/app.js episode line (' · close contact' when
    // weighted >= 15).
    func testExposureLogRetentionAndEpisodeFlags() throws {
        XCTAssertEqual(ExposureLog.retention, 14 * 86400)
        let now = t0
        let old = ExposureEpisode(start: now - 15 * 86400 - 600, end: now - 15 * 86400, weightedMinutes: 20, maxRisk: .contagious)
        let recent = ExposureEpisode(start: now - 86400 - 600, end: now - 86400, weightedMinutes: 10, maxRisk: .possible)
        XCTAssertEqual(ExposureLog.pruned([old, recent], now: now), [recent])
        XCTAssertTrue(old.isCloseContact)
        XCTAssertFalse(recent.isCloseContact)
        XCTAssertEqual(recent.durationMinutes, 10, accuracy: 1e-9)
        XCTAssertEqual(ExposureLog.decode(try ExposureLog.encode([old, recent])), [old, recent])
        XCTAssertEqual(ExposureLog.decode(Data("not json".utf8)), [])
    }

    // README "Exposure" weighting applied to the history: 20 min next to a contagious phone is one
    // close-contact episode of ~20 weighted minutes; the same with a possibly-sick phone is ~10, not close.
    func testExposureHistoryEpisodes() {
        func episodes(_ risk: Risk) -> [ExposureEpisode] {
            var h = ExposureHistory()
            var out: [ExposureEpisode] = []
            for s in 1...1200 { out += h.advance(simSeconds: 1, contacts: [(pClose: 1.0, risk: risk)], at: t0 + Double(s)) }
            for s in 1201...1500 { out += h.advance(simSeconds: 1, contacts: [], at: t0 + Double(s)) }
            out += h.finishOpen()
            return out
        }
        let c = episodes(.contagious)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.first?.weightedMinutes ?? 0, 20, accuracy: 0.5)
        XCTAssertEqual(c.first?.maxRisk, .contagious)
        XCTAssertEqual(c.first?.isCloseContact, true)
        XCTAssertGreaterThanOrEqual(c.first?.durationMinutes ?? 0, 19)
        XCTAssertLessThanOrEqual(c.first?.durationMinutes ?? 99, 26)
        let p = episodes(.possible)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p.first?.weightedMinutes ?? 0, 10, accuracy: 0.5)
        XCTAssertEqual(p.first?.maxRisk, .possible)
        XCTAssertEqual(p.first?.isCloseContact, false)
    }
}

// MARK: - Beacon, GATT, background connects, routing, web, bundle, geofence, launch

final class BlindPlumbingTests: XCTestCase {

    // README channel table: one 128-bit UUID = "FLU1", risk, 11-byte ID; GATT serves "the same 16 bytes".
    func testBeaconPayloadLayout() throws {
        let id = Data((1...11).map { UInt8($0) })
        var riskBytes: Set<UInt8> = []
        for risk in Risk.allCases {
            let v = try XCTUnwrap(BeaconGATT.value(id: id, risk: risk))
            let b = [UInt8](v)
            XCTAssertEqual(b.count, 16)
            XCTAssertEqual(Array(b[0..<4]), Array("FLU1".utf8))
            XCTAssertEqual(Array(b[5..<16]), [UInt8](id))
            riskBytes.insert(b[4])
            XCTAssertEqual(BeaconGATT.decode(v)?.risk, risk)
        }
        XCTAssertEqual(riskBytes.count, 3, "the risk byte distinguishes the three levels")
        XCTAssertNil(BeaconGATT.value(id: Data(repeating: 1, count: 10), risk: .none), "ID must be 11 bytes")
        let other = BeaconGATT.value(id: Data(repeating: 9, count: 11), risk: .none)!
        let same = BeaconGATT.value(id: id, risk: .none)!
        XCTAssertNotEqual(BeaconGATT.decode(other)?.id, BeaconGATT.decode(same)?.id)
        XCTAssertNil(BeaconGATT.decode(Data(repeating: 0, count: 16)), "no FLU1 prefix")
        XCTAssertNil(BeaconGATT.decode(Data(same.prefix(15))), "too short")
    }

    // README channel table: fixed service and read-only characteristic UUIDs.
    func testGATTUUIDs() {
        XCTAssertEqual(BeaconGATT.service.uuidString.uppercased(), "142C3940-E33C-4D62-BE25-1C4A883EE402")
        XCTAssertEqual(BeaconGATT.characteristic.uuidString.uppercased(), "2F02CED2-60A0-41AC-A335-07D1603177E4")
    }

    // README "Background": at most once per 20 s per peripheral and 3 connections at a time.
    func testConnectLimiter() {
        XCTAssertEqual(ConnectLimiter.minInterval, 20)
        XCTAssertEqual(ConnectLimiter.maxConcurrent, 3)
        var l = ConnectLimiter()
        let p = (0..<5).map { _ in UUID() }
        XCTAssertTrue(l.tryBegin(p[0], at: t0)); l.end(p[0])
        XCTAssertFalse(l.tryBegin(p[0], at: t0 + 5), "within 20 s of the last connect")
        XCTAssertTrue(l.tryBegin(p[0], at: t0 + 21)); l.end(p[0])
        XCTAssertTrue(l.tryBegin(p[1], at: t0 + 100))
        XCTAssertTrue(l.tryBegin(p[2], at: t0 + 100))
        XCTAssertTrue(l.tryBegin(p[3], at: t0 + 100))
        XCTAssertFalse(l.tryBegin(p[4], at: t0 + 100), "a 4th concurrent connection")
        l.end(p[1])
        XCTAssertTrue(l.tryBegin(UUID(), at: t0 + 101))
    }

    // Digest doc comment on Route.ignore: dismissed, "Got it", or something we don't understand -> do nothing.
    func testNotificationRouteIgnores() {
        XCTAssertEqual(NotificationRoute.route(userInfo: [:], actionIdentifier: NotificationAction.dismiss), .ignore)
        XCTAssertEqual(NotificationRoute.route(userInfo: [:], actionIdentifier: NotificationAction.gotIt), .ignore)
        XCTAssertEqual(NotificationRoute.route(userInfo: [:], actionIdentifier: "com.example.unknown"), .ignore)
        XCTAssertEqual(Set(NotificationKind.allCases.map(\.categoryID)).count, NotificationKind.allCases.count)
    }

    // README "Map tab" / DEMO step 3: the page and the model/heat files are served by the same laptop server.
    func testWebPolicySameOrigin() {
        let base = URL(string: "http://laptop.local:8000/heatmap/?embed=app")!
        XCTAssertTrue(WebPolicy.allows(base, base: base))
        XCTAssertTrue(WebPolicy.allows(URL(string: "http://laptop.local:8000/model/out/r/p_sick.csv"), base: base))
        XCTAssertFalse(WebPolicy.allows(nil, base: base))
        let b80 = URL(string: "http://laptop.local/heatmap/")!
        XCTAssertTrue(WebPolicy.allows(URL(string: "http://laptop.local:80/heatmap/x.js"), base: b80), "default port")
    }

    // No spec text; universal: a bundled-file resolver must not let ".." escape, and MIME types are standard.
    func testBundlePaths() {
        for p in ["/../../etc/passwd", "/heatmap/../../secret", "/%2e%2e/%2e%2e/etc/passwd"] {
            let r = BundlePaths.resolve(p)
            XCTAssertFalse(r?.contains("..") ?? false, "\(p) -> \(r ?? "nil")")
            XCTAssertFalse(r?.contains("etc/passwd") ?? false, "\(p) -> \(r ?? "nil")")
        }
        XCTAssertTrue(BundlePaths.mimeType(for: "a/index.html").hasPrefix("text/html"))
        XCTAssertTrue(BundlePaths.mimeType(for: "a/app.js").contains("javascript"))
        XCTAssertTrue(BundlePaths.mimeType(for: "a/totals.json").hasPrefix("application/json"))
        XCTAssertTrue(BundlePaths.mimeType(for: "a/style.css").hasPrefix("text/css"))
        XCTAssertTrue(BundlePaths.mimeType(for: "a/x.png").hasPrefix("image/png"))
        XCTAssertTrue(BundlePaths.mimeType(for: "a/x.svg").hasPrefix("image/svg+xml"))
    }

    // README "Background" table (building warnings via geofences); building-heat-format radius_m.
    func testGeofenceRadiusAndPrune() {
        XCTAssertEqual(GeofenceEntry.regionRadius(for: 10_000, maximum: 200), 200, accuracy: 1e-9)
        for r in [5.0, 40, 60, 150] {
            let g = GeofenceEntry.regionRadius(for: r, maximum: 200)
            XCTAssertLessThanOrEqual(g, 200)
            XCTAssertGreaterThanOrEqual(g, min(r, 200), "the region must cover the building")
        }
        let pending = ["old": t0 - GeofenceEntry.fixTimeout - 1, "new": t0]
        XCTAssertEqual(Set(GeofenceEntry.pruned(pending, now: t0).keys), ["new"])
    }

    // README "Test launches skip onboarding": the flags that mark a test launch.
    func testLaunchModeTestKeys() {
        let keys = Set(LaunchMode.testKeys.map { $0.hasPrefix("-") ? String($0.dropFirst()) : String($0) })
        XCTAssertEqual(keys, ["risk", "speed", "sources", "encryption", "inviteTimeout", "rotate", "riskAfter", "skipOnboarding"])
    }
}
