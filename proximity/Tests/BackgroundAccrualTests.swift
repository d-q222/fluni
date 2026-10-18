import XCTest
@testable import FluniProx

/// Exposure from sighting timestamps (background) must agree with the 1 s timer and never count a
/// second twice.
final class BackgroundAccrualTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    private func see(_ a: inout SightingAccrual, _ id: String, _ s: Double, p: Double = 1,
                     risk: Risk = .contagious, tier: Double = 1) -> AccrualCredit? {
        a.observe(id, at: at(s), pClose: p, risk: risk, tier: tier)
    }

    func testFirstSightingCreditsNothing() {
        var a = SightingAccrual()
        XCTAssertNil(see(&a, "a", 0))
        XCTAssertEqual(a.lastCreditedAt["a"], at(0))
    }

    func testGapExactlyAtMaxGapIsCredited() {
        var a = SightingAccrual()
        _ = see(&a, "a", 0)
        let c = see(&a, "a", SightingAccrual.maxGap, p: 0.8)
        XCTAssertEqual(c?.seconds, SightingAccrual.maxGap)
        XCTAssertEqual(c?.pClose, 0.8)
    }

    func testGapOverMaxGapCreditsNothingAndReanchors() {
        var a = SightingAccrual()
        _ = see(&a, "a", 0)
        XCTAssertNil(see(&a, "a", SightingAccrual.maxGap + 0.001))
        // Counting resumes from the re-sighting, not from the old one.
        XCTAssertEqual(see(&a, "a", SightingAccrual.maxGap + 10.001)?.seconds ?? 0, 10, accuracy: 1e-6)
    }

    func testClockGoingBackwardsCreditsNothingThenOnlyForward() {
        var a = SightingAccrual()
        _ = see(&a, "a", 100)
        XCTAssertNil(see(&a, "a", 40))               // clock stepped back 60 s
        XCTAssertNil(see(&a, "a", 40))               // same instant: zero gap
        XCTAssertEqual(see(&a, "a", 50)?.seconds, 10)  // from the new anchor, not from 100
    }

    func testGapIsCreditedAtTheLatestPCloseRiskAndTier() {
        var a = SightingAccrual()
        _ = see(&a, "a", 0, p: 0.1, risk: .possible, tier: 0.02)
        let c = see(&a, "a", 60, p: 0.9, risk: .contagious, tier: 0.6)
        XCTAssertEqual(c, AccrualCredit(id: "a", seconds: 60, pClose: 0.9, risk: .contagious, tier: 0.6))
    }

    func testGarbagePCloseAndTierAreClamped() {
        var a = SightingAccrual()
        _ = see(&a, "a", 0)
        XCTAssertEqual(see(&a, "a", 1, p: .nan, tier: .infinity)?.pClose, 0)
        XCTAssertEqual(see(&a, "a", 2, p: 7, tier: -3)?.pClose, 1)
        XCTAssertEqual(see(&a, "a", 3, p: 1, tier: -3)?.tier, 0)
    }

    func testSamePeerReSightedManyTimesQuicklyIsNotDoubleCounted() {
        var a = SightingAccrual()
        var total = 0.0
        for i in 0 ... 1000 { total += see(&a, "a", Double(i) * 0.01)?.seconds ?? 0 }
        XCTAssertEqual(total, 10, accuracy: 1e-6)  // exactly the span, however often it is seen
        // Duplicate timestamps (a burst of adverts in one instant) add nothing.
        XCTAssertNil(see(&a, "a", 10))
        XCTAssertNil(see(&a, "a", 10))
    }

    func testTwoOverlappingPeersEachGetTheirOwnIntervals() {
        var a = SightingAccrual()
        var byID: [String: Double] = [:]
        // a seen every 60 s, b every 60 s offset by 30 s: both present the whole time.
        for s in stride(from: 0.0, through: 240, by: 30) {
            let id = Int(s / 30) % 2 == 0 ? "a" : "b"
            if let c = see(&a, id, s) { byID[id, default: 0] += c.seconds }
        }
        XCTAssertEqual(byID["a"], 240)  // 0 → 240
        XCTAssertEqual(byID["b"], 180)  // 30 → 210
    }

    func testIDRotationMidGapStartsFreshAndNeverDoubleCounts() {
        var a = SightingAccrual()
        var total = 0.0
        for s in [0.0, 20, 40] { total += see(&a, "old", s)?.seconds ?? 0 }
        // The peer rotated at ~60 s; Bluetooth alone can't link the IDs.
        for s in [100.0, 120] { total += see(&a, "new", s)?.seconds ?? 0 }
        XCTAssertEqual(total, 40 + 20)  // the 60 s across the rotation isn't credited to anyone
        a.prune(now: at(40 + SightingAccrual.maxGap + 1))
        XCTAssertNil(a.lastCreditedAt["old"])
    }

    func testIDRotationLinkedByThePeerLinkCarriesTheGapOnce() {
        var a = SightingAccrual()
        _ = see(&a, "old", 0)
        _ = see(&a, "old", 40)
        a.rename(from: "old", to: "new")
        XCTAssertNil(a.lastCreditedAt["old"])
        XCTAssertEqual(see(&a, "new", 100)?.seconds, 60)  // 40 → 100, once
        XCTAssertNil(see(&a, "old", 101))                 // a late advert under the old ID starts fresh
    }

    func testResetForgetsEveryone() {
        var a = SightingAccrual()
        _ = see(&a, "a", 0)
        a.reset()
        XCTAssertNil(see(&a, "a", 10))
    }

    // MARK: Feeding ExposureTracker

    func testFeedSplitsLongCreditsExactlyAndKeepsTheRealPClose() {
        let c = AccrualCredit(id: "a", seconds: 250, pClose: 0.8, risk: .contagious, tier: 0.6)
        let f = AccrualFeed.contacts([c], wallSeconds: 100)
        XCTAssertEqual(f.contacts.count, 3)  // 2 whole + 0.5
        XCTAssertEqual(f.contacts[0].pClose, 0.8)
        XCTAssertEqual(f.contacts[2].pClose, 0.4, accuracy: 1e-12)
        XCTAssertEqual(f.tiers[2], 0.3, accuracy: 1e-12)
        XCTAssertEqual(f.contacts.reduce(0) { $0 + $1.pClose } * 100, 250 * 0.8, accuracy: 1e-9)
    }

    func testFeedDropsHealthyPeersAndBadWallTimes() {
        let ok = AccrualCredit(id: "a", seconds: 10, pClose: 1, risk: .contagious, tier: 1)
        let healthy = AccrualCredit(id: "b", seconds: 10, pClose: 1, risk: .none, tier: 1)
        XCTAssertEqual(AccrualFeed.contacts([healthy], wallSeconds: 10).contacts.count, 0)
        XCTAssertEqual(AccrualFeed.contacts([ok], wallSeconds: 0).contacts.count, 0)
        XCTAssertEqual(AccrualFeed.contacts([ok], wallSeconds: -5).contacts.count, 0)
        XCTAssertEqual(AccrualFeed.contacts([ok], wallSeconds: .nan).contacts.count, 0)
    }

    func testFeedEqualCreditAndWallIsOneContactUnchanged() {
        // The foreground steady state: credited one tick ago, so it's exactly what the old tick passed.
        let c = AccrualCredit(id: "a", seconds: 1.0000000001, pClose: 0.7, risk: .possible, tier: 0.6)
        let f = AccrualFeed.contacts([c], wallSeconds: 1)
        XCTAssertEqual(f.contacts.count, 1)
        XCTAssertEqual(f.contacts[0].pClose, 0.7)
        XCTAssertEqual(f.tiers, [0.6])
    }

    /// Background-style accrual: sightings minutes apart, two peers interleaved. The tracker's minutes and
    /// dose must equal Σ seconds × pClose × weight, while its clock only moves by real time.
    func testOverlappingBackgroundSightingsGiveExactMinutesAndDose() {
        var a = SightingAccrual()
        var e = ExposureTracker()
        var last = 0.0
        var expectMin = 0.0, expectDose = 0.0
        let events: [(String, Double, Double, Risk, Double)] = [  // id, time, pClose, risk, tier
            ("a", 0, 0.9, .contagious, 1), ("b", 30, 0.6, .possible, 0.6), ("a", 90, 0.9, .contagious, 1),
            ("b", 150, 0.6, .possible, 0.6), ("a", 200, 0.5, .contagious, 0.6), ("b", 460, 0.6, .possible, 0.6),
        ]
        for (id, s, p, r, t) in events {
            let w = s - last
            last = s
            var credits: [AccrualCredit] = []
            if let c = a.observe(id, at: at(s), pClose: p, risk: r, tier: t) {
                credits.append(c)
                expectMin += c.seconds / 60 * p * r.weight
                expectDose += c.seconds / 60 * t * r.weight
            }
            let f = AccrualFeed.contacts(credits, wallSeconds: w)
            e.advance(simSeconds: w, contacts: f.contacts, tiers: f.tiers)
        }
        // a: 0→90 at 0.9, 90→200 at 0.5. b: 30→150 at 0.6, then 310 s gap > maxGap: nothing.
        XCTAssertEqual(expectMin, 90.0 / 60 * 0.9 + 110.0 / 60 * 0.5 + 120.0 / 60 * 0.6 * 0.5, accuracy: 1e-9)
        XCTAssertEqual(e.minutes, expectMin, accuracy: 1e-9)
        XCTAssertEqual(e.dose, expectDose, accuracy: 1e-9)
    }

    /// The 24 h window runs on real time between sightings: a credit made a day earlier expires.
    func testWindowExpiresByRealTimeBetweenSightings() {
        var a = SightingAccrual()
        var e = ExposureTracker()
        _ = a.observe("a", at: at(0), pClose: 1, risk: .contagious, tier: 1)
        let c = a.observe("a", at: at(120), pClose: 1, risk: .contagious, tier: 1)!
        let f = AccrualFeed.contacts([c], wallSeconds: 120)
        e.advance(simSeconds: 120, contacts: f.contacts, tiers: f.tiers)
        XCTAssertEqual(e.minutes, 2, accuracy: 1e-9)
        e.advance(simSeconds: ExposureTracker.window, contacts: [])  // a day with no sightings
        XCTAssertEqual(e.minutes, 0)
    }

    /// The foreground path (a sighting every second) reaches the 15-minute close contact as before,
    /// give or take the first second (a first sighting has nothing before it to credit).
    func testOneSecondTicksReachCloseContactAtFifteenMinutes() {
        var a = SightingAccrual()
        var e = ExposureTracker()
        var reachedAt: Int?
        for s in 0 ... 1000 {
            var credits: [AccrualCredit] = []
            if let c = a.observe("a", at: at(Double(s)), pClose: 1, risk: .contagious, tier: 1) { credits.append(c) }
            let f = AccrualFeed.contacts(credits, wallSeconds: s == 0 ? 0 : 1)
            e.advance(simSeconds: s == 0 ? 0 : 1, contacts: f.contacts, tiers: f.tiers)
            if e.level == .closeContact && reachedAt == nil { reachedAt = s }
        }
        XCTAssertEqual(reachedAt, 900)
    }
}
