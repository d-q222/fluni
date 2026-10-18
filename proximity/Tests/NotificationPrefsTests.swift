import XCTest
import UserNotifications
@testable import FluniProx

/// The notification settings (Settings → Notifications) are enforced at SystemNotifier, the one door every system
/// notification goes through: the tick's heads-up and close contact (UNPoster, foreground or background wake) and
/// the walk-in warning. A muted kind never reaches iOS; the alert state (and so the in-app alert) moves on as before.
final class NotificationPrefsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        suite = "NotificationPrefsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// A notifier writing to test defaults and recording what it hands to iOS.
    private func notifier() -> (SystemNotifier, () -> [String]) {
        var delivered: [String] = []
        let n = SystemNotifier(prefs: NotificationPrefs(defaults: defaults)) { req, done in
            delivered.append(req.content.userInfo["kind"] as? String ?? "?")
            done()
        }
        return (n, { delivered })
    }

    private func content(_ kind: NotificationKind) -> UNNotificationContent {
        let c = UNMutableNotificationContent()
        c.userInfo = ["kind": kind.rawValue]
        return c
    }

    func testAllOnByDefault() {
        let p = NotificationPrefs(defaults: defaults)
        for k in NotificationKind.allCases { XCTAssertTrue(p.allows(k), "\(k)") }
    }

    func testKeysAreDistinctAndStable() {
        XCTAssertEqual(NotificationPrefs.key(.nearby), "notify.nearby")
        XCTAssertEqual(NotificationPrefs.key(.closeContact), "notify.close_contact")
        XCTAssertEqual(NotificationPrefs.key(.building), "notify.building")
    }

    /// Each kind on and off, alone: only that kind is muted.
    func testEachKindOnOff() {
        for off in NotificationKind.allCases {
            let (n, delivered) = notifier()
            n.prefs.set(off, false)
            for k in NotificationKind.allCases {
                XCTAssertEqual(n.post(k, content: content(k)), k != off, "\(k) with \(off) off")
            }
            XCTAssertEqual(delivered(), NotificationKind.allCases.filter { $0 != off }.map(\.rawValue))
            n.prefs.set(off, true)
            XCTAssertTrue(n.post(off, content: content(off)), "\(off) back on")
        }
    }

    /// A muted kind never builds its content (no wasted work on a background wake).
    func testMutedKindDoesNotBuildContent() {
        let (n, _) = notifier()
        n.prefs.set(.building, false)
        var built = false
        n.post(.building, content: { built = true; return UNMutableNotificationContent() }())
        XCTAssertFalse(built)
    }

    /// Delete my data erases the defaults domain: every kind is on again.
    func testErasingDefaultsTurnsEverythingBackOn() {
        let p = NotificationPrefs(defaults: defaults)
        for k in NotificationKind.allCases { p.set(k, false) }
        defaults.removePersistentDomain(forName: suite)
        for k in NotificationKind.allCases { XCTAssertTrue(p.allows(k), "\(k)") }
    }

    /// Foreground path: the tick's AlertGate step posts through UNPoster. Heads-up then close contact, each muted
    /// in turn. The gate's state moves on either way, so turning a kind back on doesn't replay an old alert.
    func testForegroundCrossingsRespectSettings() {
        for (nearby, close) in [(true, true), (false, true), (true, false), (false, false)] {
            let (n, delivered) = notifier()
            n.prefs.set(.nearby, nearby)
            n.prefs.set(.closeContact, close)
            let poster = UNPoster(notifier: n)
            var gate = AlertGate()
            gate.step(.nearby, now: t0, poster: poster)
            gate.step(.closeContact, now: t0.addingTimeInterval(900), poster: poster)
            var want: [String] = []
            if nearby { want.append("nearby") }
            if close { want.append("close_contact") }
            XCTAssertEqual(delivered(), want, "nearby=\(nearby) close=\(close)")
            XCTAssertEqual(gate.level, .closeContact)
            XCTAssertNotNil(gate.lastNotifiedAt[.nearby], "the cooldown runs even when muted")
            XCTAssertFalse(gate.isRead(.closeContact, now: t0.addingTimeInterval(900)), "the in-app alert still shows")
        }
    }

    /// Background path: a locked listener credited only on polled-link wake-ups (the same accrual as
    /// AlertGateTests), posting through UNPoster. Muting one kind leaves the other untouched.
    func testBackgroundAccrualRespectsSettings() {
        for muted in [nil, NotificationKind.nearby, .closeContact] {
            let (n, delivered) = notifier()
            for k in NotificationKind.allCases { n.prefs.set(k, k != muted) }  // one suite for the whole loop
            let poster = UNPoster(notifier: n)
            var cal = BLECalibrator()
            for _ in 0 ..< 5 { cal.observe(rssi: -59, trueDistance: 1) }
            var gate = AlertGate(), accrual = SightingAccrual(), e = ExposureTracker()
            var last = t0
            for k in 0 ... 60 {
                let now = t0.addingTimeInterval(Double(k) * 2)
                let wall = now.timeIntervalSince(last)
                last = now
                let r = OffScreenRSSI.widened(cal.reading(rssi: cal.txPower - 20 * log10(0.5), at: now), samples: 2)
                let est = Fusion.fuse([r], now: now)!
                let guarded = [ContactGuard.Output(id: "sick", risk: .contagious, pClose: Fusion.exposurePClose(est),
                                                   distance: Fusion.doseDistance(est), corroborated: false)]
                ExposureTick.run(guarded: guarded, fresh: ["sick"], now: now, wall: wall, speed: 60,
                                 accrues: true, accrual: &accrual, exposure: &e)
                gate.step(e.level, now: now, poster: poster)
            }
            XCTAssertEqual(e.level, .closeContact)
            let want = ["nearby", "close_contact"].filter { $0 != muted?.rawValue }
            XCTAssertEqual(delivered(), want, "muted=\(String(describing: muted))")
        }
    }

    /// Building warnings go through the same door (WalkInMonitor posts .building via SystemNotifier).
    func testBuildingWarningRespectsSetting() {
        let (n, delivered) = notifier()
        XCTAssertTrue(n.post(.building, content: content(.building), identifier: "walkin-x"))
        n.prefs.set(.building, false)
        XCTAssertFalse(n.post(.building, content: content(.building), identifier: "walkin-x"))
        XCTAssertEqual(delivered(), ["building"])
    }
}
