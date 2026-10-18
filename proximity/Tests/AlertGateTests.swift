import XCTest
@testable import FluniProx

/// Notifications from a background wake-up follow the same rule as the foreground (flu-offdetect): one per
/// crossing up, no repeat inside a level's cooldown, escalation always notifies, de-escalation never does.
final class AlertGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func testCooldowns() {
        XCTAssertEqual(BackgroundAlert.nearbyCooldown, 1800)
        XCTAssertEqual(BackgroundAlert.closeContactCooldown, 43_200)
        XCTAssertEqual(BackgroundAlert.cooldown(.none), 0)
        XCTAssertEqual(BackgroundAlert.cooldown(.nearby), 1800)
        XCTAssertEqual(BackgroundAlert.cooldown(.closeContact), 43_200)
    }

    func testShouldNotifyTable() {
        let n = BackgroundAlert.shouldNotify
        XCTAssertTrue(n(.none, .nearby, nil, t0))
        XCTAssertTrue(n(.none, .closeContact, nil, t0))
        XCTAssertTrue(n(.nearby, .closeContact, nil, t0), "escalation (lastNotifiedAt is per level)")
        XCTAssertFalse(n(.nearby, .nearby, nil, t0), "no crossing")
        XCTAssertFalse(n(.closeContact, .nearby, nil, t0), "de-escalation")
        XCTAssertFalse(n(.closeContact, .none, nil, t0))
        XCTAssertFalse(n(.none, .none, nil, t0))
        XCTAssertFalse(n(.none, .nearby, at(-1799.999), t0), "inside the heads-up cooldown")
        XCTAssertTrue(n(.none, .nearby, at(-1800), t0), "cooldown over, exactly")
        XCTAssertFalse(n(.none, .closeContact, at(-43_199), t0))
        XCTAssertTrue(n(.none, .closeContact, at(-43_200), t0))
        XCTAssertTrue(n(.none, .nearby, at(5), t0), "a clock that went back past the last one doesn't block")
    }

    func testGateSequence() {
        var g = AlertGate()
        XCTAssertNil(g.step(.none, now: t0))
        XCTAssertEqual(g.step(.nearby, now: at(1)), .nearby, "crossing: exactly one")
        for s in 2 ... 50 { XCTAssertNil(g.step(.nearby, now: at(Double(s))), "no repeat every wake (\(s))") }
        XCTAssertNil(g.step(.none, now: at(60)))
        XCTAssertNil(g.step(.nearby, now: at(70)), "in and out of range inside 30 min: no second heads-up")
        XCTAssertEqual(g.step(.closeContact, now: at(80)), .closeContact, "escalation notifies at once")
        XCTAssertNil(g.step(.closeContact, now: at(81)))
        XCTAssertNil(g.step(.none, now: at(100)), "de-escalation never notifies")
        XCTAssertNil(g.step(.closeContact, now: at(200)), "close contact again inside 12 h: no")
        XCTAssertNil(g.step(.none, now: at(300)))
        XCTAssertEqual(g.step(.nearby, now: at(1 + 1800)), .nearby, "heads-up again once its cooldown is over")
        XCTAssertEqual(g.step(.closeContact, now: at(80 + 43_200)), .closeContact)
        XCTAssertEqual(g.lastNotifiedAt[.nearby], at(1801))
        XCTAssertEqual(g.lastNotifiedAt[.closeContact], at(43_280))
    }

    func testStraightToCloseContactSkipsTheHeadsUp() {
        var g = AlertGate()
        XCTAssertEqual(g.step(.closeContact, now: t0), .closeContact)
        XCTAssertNil(g.lastNotifiedAt[.nearby])
    }

    private final class Recorder: AlertPosting {
        var posted: [NotificationKind] = []
        func post(_ kind: NotificationKind) { posted.append(kind) }
    }

    /// A locked listener: only polled-link wake-ups every 2 s (median of 2 samples, BLE only, calibrated pair at
    /// 0.5 m), every third wake finds no fresh sample (so the heads-up level drops and climbs again), demo speed 60.
    /// The accrual crosses 15 weighted minutes: exactly one heads-up, then exactly one close contact, nothing after.
    func testBackgroundAccrualCrossingPostsOneCloseContact() {
        var cal = BLECalibrator()
        for _ in 0 ..< 5 { cal.observe(rssi: -59, trueDistance: 1) }
        let rec = Recorder()
        var gate = AlertGate(), accrual = SightingAccrual(), e = ExposureTracker()
        var last = t0, crossedAt: Double?
        for k in 0 ... 60 {
            let s = Double(k) * 2, now = at(s)
            let wall = now.timeIntervalSince(last)
            last = now
            var guarded: [ContactGuard.Output] = []
            if k % 3 != 2 {
                let r = OffScreenRSSI.widened(cal.reading(rssi: cal.txPower - 20 * log10(0.5), at: now), samples: 2)
                let est = Fusion.fuse([r], now: now)!
                guarded = [ContactGuard.Output(id: "sick", risk: .contagious, pClose: Fusion.exposurePClose(est),
                                               distance: Fusion.doseDistance(est), corroborated: false)]
            }
            ExposureTick.run(guarded: guarded, fresh: Set(guarded.map(\.id)), now: now, wall: wall, speed: 60,
                             accrues: true, accrual: &accrual, exposure: &e)
            let before = rec.posted.count
            gate.step(e.level, now: now, poster: rec)
            if rec.posted.count > before, rec.posted.last == .closeContact { crossedAt = s }
        }
        XCTAssertEqual(rec.posted, [.nearby, .closeContact])
        XCTAssertEqual(e.level, .closeContact)
        XCTAssertGreaterThanOrEqual(e.minutes, 15)
        // pClose = Φ((1.83 - 0.5) / ((0.4·0.5 + 0.3)·√2)) = 0.97001; credits 1.94, +3.88 (gap over a stale wake), 1.94, …
        XCTAssertEqual(crossedAt, 18, "17.46 min at 18 s; 13.58 at 14 s, and 16 s was a stale wake")
    }

    /// flu-expo (owner retest): a possibly-sick heads-up, then that person tests positive. The contagious heads-up
    /// notifies once at once (no 30 min wait) with the stronger wording; repeats and the weaker one keep the cooldown.
    func testPossiblySickToContagiousAlertsOnceWithoutWaitingForTheCooldown() {
        var t = ExposureTracker()
        t.advance(simSeconds: 1, contacts: [(1, .possible)])
        XCTAssertEqual(t.alert, .nearby)
        t.advance(simSeconds: 1, contacts: [(1, .contagious)])
        XCTAssertEqual(t.alert, .nearbyContagious)
        XCTAssertEqual(t.level, .nearby, "the episode level itself is unchanged")
        t.advance(simSeconds: 1, contacts: [(1, .possible)])
        XCTAssertEqual(t.alert, .nearby)
        XCTAssertTrue(AlertLevel.nearby < .nearbyContagious && AlertLevel.nearbyContagious < .closeContact)

        var g = AlertGate()
        XCTAssertEqual(g.step(.nearby, now: t0), .nearby)
        XCTAssertEqual(g.step(.nearbyContagious, now: t0.addingTimeInterval(60)), .nearby, "escalation alerts at once")
        XCTAssertNil(g.step(.nearby, now: t0.addingTimeInterval(120)))
        XCTAssertNil(g.step(.nearbyContagious, now: t0.addingTimeInterval(180)), "same level again: cooldown")
        XCTAssertNil(g.step(.none, now: t0.addingTimeInterval(240)))
        XCTAssertNil(g.step(.nearby, now: t0.addingTimeInterval(300)), "a weaker heads-up never follows a stronger one")
        XCTAssertEqual(g.step(.closeContact, now: t0.addingTimeInterval(360)), .closeContact)

        // The in-app alert: reading the possibly-sick one doesn't hide the contagious one; reading that covers both.
        var r = AlertGate()
        r.markRead(.nearby, now: t0)
        XCTAssertFalse(r.isRead(.nearbyContagious, now: t0.addingTimeInterval(60)))
        r.markRead(.nearbyContagious, now: t0.addingTimeInterval(60))
        XCTAssertTrue(r.isRead(.nearby, now: t0.addingTimeInterval(120)))

        XCTAssertEqual(Advice.title(.nearbyContagious), "Someone within 6 ft has tested positive")
        XCTAssertTrue(NotificationRoute.text(kind: .nearby, detailed: true, level: .nearbyContagious).body
            .hasPrefix("Someone within 6 ft has tested positive."))
        XCTAssertTrue(NotificationRoute.text(kind: .nearby, detailed: true).body.hasPrefix("Someone within 6 ft may be sick."))
    }
}
