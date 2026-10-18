import XCTest
@testable import FluniProx

/// Off-screen ranging (flu-offdetect): held GATT links polled for RSSI, the wider error a thin RSSI window
/// gets, and exposure that carries on unbroken from foreground to locked and back.
final class OffScreenRangingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    private let ids = (0 ..< 6).map { i in UUID(uuidString: "00000000-0000-0000-0000-00000000000\(i)")! }

    // MARK: Holding links

    func testConstants() {
        XCTAssertEqual(HeldLinks.maxHeld, 4)
        XCTAssertEqual(HeldLinks.pollInterval, 2)
        XCTAssertEqual(HeldLinks.rereadInterval, 30)
        XCTAssertEqual(HeldLinks.replaceMargin, 6)
        XCTAssertEqual(HeldLinks.advertFresh, 3)
        XCTAssertEqual(HeldLinks.reconnectFor, 600)
        // A polled link must keep a BLE reading fresh between polls.
        XCTAssertLessThan(HeldLinks.pollInterval * 2, Source.ble.maxAge + 0.001)
    }

    func testHoldsUpToMaxThenRefuses() {
        var h = HeldLinks()
        for i in 0 ..< 4 { XCTAssertTrue(h.read(ids[i], id: "id\(i)", risk: .none, rssi: -60, at: t0)) }
        XCTAssertFalse(h.read(ids[4], id: "id4", risk: .contagious, rssi: -40, at: t0))
        XCTAssertEqual(h.count, 4)
        XCTAssertNil(h.link(ids[4]))
    }

    func testRereadOfAHeldLinkUpdatesItEvenWhenFull() {
        var h = HeldLinks()
        for i in 0 ..< 4 { _ = h.read(ids[i], id: "id\(i)", risk: .none, rssi: -60, at: t0) }
        XCTAssertTrue(h.read(ids[2], id: "rotated", risk: .contagious, rssi: nil, at: at(30)))
        let l = h.link(ids[2])!
        XCTAssertEqual(l.id, "rotated")
        XCTAssertEqual(l.risk, .contagious)
        XCTAssertEqual(l.readAt, at(30))
        XCTAssertEqual(l.since, t0, "a re-read keeps the link's start")
        XCTAssertEqual(l.rssi, -60, "a re-read without RSSI keeps the last one")
        XCTAssertEqual(h.count, 4)
    }

    func testSamePhoneUnderANewAddressIsNotHeldTwice() {
        var h = HeldLinks()
        XCTAssertTrue(h.read(ids[0], id: "abc", risk: .contagious, rssi: -55, at: t0))
        XCTAssertFalse(h.read(ids[1], id: "abc", risk: .contagious, rssi: -55, at: at(1)))
        XCTAssertTrue(h.read(ids[1], id: "def", risk: .contagious, rssi: -55, at: at(1)))
        XCTAssertEqual(h.count, 2)
    }

    func testDropAndReset() {
        var h = HeldLinks()
        _ = h.read(ids[0], id: "a", risk: .none, rssi: -50, at: t0)
        _ = h.read(ids[1], id: "b", risk: .none, rssi: -50, at: t0)
        h.drop(ids[0])
        h.drop(ids[0])  // twice is harmless
        XCTAssertNil(h.link(ids[0]))
        XCTAssertEqual(h.count, 1)
        h.reset()
        XCTAssertEqual(h, HeldLinks())
    }

    // MARK: Admission (links go to the nearest phones)

    func testAdmitWithRoom() {
        var h = HeldLinks()
        XCTAssertEqual(h.admit(rssi: -99), .room)
        for i in 0 ..< 3 { _ = h.read(ids[i], id: "id\(i)", risk: .none, rssi: -50, at: t0) }
        XCTAssertEqual(h.admit(rssi: -99), .room)
    }

    func testFullTableReplacesWeakestOnlyBeyondMargin() {
        var h = HeldLinks()
        let rssis = [-50.0, -70, -62, -58]
        for i in 0 ..< 4 { _ = h.read(ids[i], id: "id\(i)", risk: .none, rssi: rssis[i], at: t0) }
        XCTAssertEqual(h.admit(rssi: -64), .replace(ids[1]), "exactly 6 dB stronger than the weakest (-70)")
        XCTAssertEqual(h.admit(rssi: -64.01), .full)
        XCTAssertEqual(h.admit(rssi: -40), .replace(ids[1]))
        XCTAssertEqual(h.admit(rssi: .nan), .full)
        XCTAssertEqual(h.admit(rssi: .infinity), .full)
    }

    func testAdvertsUpdateTheRankingAndTiesAreDeterministic() {
        var h = HeldLinks()
        for i in 0 ..< 4 { _ = h.read(ids[i], id: "id\(i)", risk: .none, rssi: -60, at: t0) }
        XCTAssertEqual(h.admit(rssi: -54), .replace(ids[0]), "a tie goes to the lowest identifier")
        h.heard(ids[0], rssi: -45)
        XCTAssertEqual(h.admit(rssi: -54), .replace(ids[1]))
        h.heard(ids[1], rssi: .nan)  // ignored
        XCTAssertEqual(h.link(ids[1])?.rssi, -60)
        h.heard(ids[5], rssi: -30)   // not held: no effect
        XCTAssertNil(h.link(ids[5]))
    }

    func testALinkWithNoRSSIYetIsTheWeakest() {
        var h = HeldLinks()
        for i in 0 ..< 3 { _ = h.read(ids[i], id: "id\(i)", risk: .none, rssi: -80, at: t0) }
        _ = h.read(ids[3], id: "id3", risk: .none, rssi: nil, at: t0)  // reconnected, not yet polled
        XCTAssertEqual(h.admit(rssi: -95), .replace(ids[3]))
    }

    // MARK: Poll cadence

    /// Date keeps about 1e-7 s at 2023 timestamps, so waits are compared to a microsecond.
    private func assertWait(_ n: HeldLinks.Next, _ s: Double, line: UInt = #line) {
        guard case .wait(let x) = n else { return XCTFail("\(n) is not a wait", line: line) }
        XCTAssertEqual(x, s, accuracy: 1e-6, line: line)
    }

    func testNextActionTimeline() {
        var h = HeldLinks()
        XCTAssertEqual(h.next(ids[0], at: t0), .none, "not held")
        _ = h.read(ids[0], id: "a", risk: .none, rssi: -60, at: t0)
        XCTAssertEqual(h.next(ids[0], at: t0), .readRSSI, "first sample at once")
        h.polled(ids[0], at: t0)
        assertWait(h.next(ids[0], at: at(0.5)), 1.5)
        assertWait(h.next(ids[0], at: at(1.999)), 0.001)
        XCTAssertEqual(h.next(ids[0], at: at(2)), .readRSSI)
        h.polled(ids[0], at: at(28.5))
        assertWait(h.next(ids[0], at: at(29.999)), 0.501)
        XCTAssertEqual(h.next(ids[0], at: at(30)), .readPayload, "re-read is due even inside the poll interval")
    }

    func testBackwardsClockNeverStallsALink() {
        var h = HeldLinks()
        _ = h.read(ids[0], id: "a", risk: .none, rssi: -60, at: at(100))
        XCTAssertEqual(h.next(ids[0], at: at(99)), .readPayload, "clock before the last read: read again")
        h.polled(ids[0], at: at(110))
        XCTAssertEqual(h.next(ids[0], at: at(105)), .readRSSI, "poll stamped in the future: poll now")
    }

    /// Drives the same chain BLEBeacon runs (answer arrives `lag` after each request, next poll queued
    /// `pollInterval` after the answer) and counts exactly what is read in two minutes.
    func testTwoMinutesOfPollingReadsExactlyThis() {
        var h = HeldLinks()
        _ = h.read(ids[0], id: "a", risk: .contagious, rssi: -60, at: t0)
        var t = 0.0, rssiReads = 0, payloadReads = 0
        var rssiTimes: [Double] = []
        let lag = 0.05
        while t < 120 {
            switch h.next(ids[0], at: at(t)) {
            case .readRSSI:
                h.polled(ids[0], at: at(t)); rssiReads += 1; rssiTimes.append(t)
                t += lag + HeldLinks.pollInterval
            case .readPayload:
                h.polled(ids[0], at: at(t)); payloadReads += 1
                _ = h.read(ids[0], id: "a", risk: .contagious, rssi: nil, at: at(t + lag))
                t += lag + HeldLinks.pollInterval
            case .wait(let s):
                t += s
            case .none:
                XCTFail("link vanished"); return
            }
        }
        XCTAssertEqual(payloadReads, 3)
        XCTAssertEqual(rssiReads, 56)
        // No two RSSI samples closer than the poll interval; none further apart than one interval plus a re-read.
        let gaps = zip(rssiTimes.dropFirst(), rssiTimes).map { $0 - $1 }
        XCTAssertEqual(gaps.min()!, HeldLinks.pollInterval + lag, accuracy: 1e-9)
        XCTAssertEqual(gaps.max()!, 2 * (HeldLinks.pollInterval + lag), accuracy: 1e-9)
        XCTAssertLessThan(gaps.max()!, Source.ble.maxAge, "the BLE reading never goes stale between samples")
    }

    // MARK: Which polled samples reach the model

    func testPolledSampleIsUsedOnlyWithoutFreshAdverts() {
        XCTAssertTrue(HeldLinks.reports(rssi: -60, lastAdvert: nil, now: t0))
        XCTAssertFalse(HeldLinks.reports(rssi: -60, lastAdvert: at(-2.999), now: t0), "adverts still flowing (foreground)")
        XCTAssertFalse(HeldLinks.reports(rssi: -60, lastAdvert: t0, now: t0))
        XCTAssertTrue(HeldLinks.reports(rssi: -60, lastAdvert: at(-3), now: t0))
        XCTAssertTrue(HeldLinks.reports(rssi: -60, lastAdvert: at(1), now: t0), "an advert stamped in the future is stale")
    }

    func testPolledSampleMustBeARealRSSI() {
        for bad in [127.0, 0, 5, -110, -200, .nan, -.infinity] {
            XCTAssertFalse(HeldLinks.reports(rssi: bad, lastAdvert: nil, now: t0), "\(bad)")
        }
        XCTAssertTrue(HeldLinks.reports(rssi: -109.9, lastAdvert: nil, now: t0))
        XCTAssertTrue(HeldLinks.reports(rssi: -0.1, lastAdvert: nil, now: t0))
    }

    // MARK: Honest error off screen

    func testSigmaScaleBySampleCount() {
        XCTAssertEqual(OffScreenRSSI.fullSamples, 4)
        XCTAssertEqual(OffScreenRSSI.sigmaScale(samples: 1), 2)
        XCTAssertEqual(OffScreenRSSI.sigmaScale(samples: 2), 2.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(OffScreenRSSI.sigmaScale(samples: 3), (4.0 / 3).squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(OffScreenRSSI.sigmaScale(samples: 4), 1)
        XCTAssertEqual(OffScreenRSSI.sigmaScale(samples: 15), 1, "a dense foreground window is unchanged")
        XCTAssertEqual(OffScreenRSSI.sigmaScale(samples: 0), 2)
        XCTAssertEqual(OffScreenRSSI.sigmaScale(samples: -3), 2)
    }

    func testWidenedOnlyTouchesBluetoothSigma() {
        let ble = Reading(source: .ble, distance: 1.5, sigma: 0.9, at: t0)
        let w = OffScreenRSSI.widened(ble, samples: 1)
        XCTAssertEqual(w.sigma, 1.8, accuracy: 1e-12)
        XCTAssertEqual(w.distance, 1.5)
        XCTAssertEqual(w.at, t0)
        XCTAssertEqual(OffScreenRSSI.widened(ble, samples: 9), ble)
        let uwb = Reading(source: .uwb, distance: 0.5, sigma: 0.1, at: t0)
        XCTAssertEqual(OffScreenRSSI.widened(uwb, samples: 1), uwb)
        let gps = Reading(source: .gps, distance: 8, sigma: 12, at: t0)
        XCTAssertEqual(OffScreenRSSI.widened(gps, samples: 1), gps)
    }

    /// Values computed independently (Python, erfc): a calibrated pair, median of 2 polled samples.
    func testWiderErrorPullsPCloseTowardHalfOnBothSides() {
        var cal = BLECalibrator()
        for _ in 0 ..< 5 { cal.observe(rssi: -59, trueDistance: 1) }
        XCTAssertTrue(cal.isCalibrated)
        func pClose(rssiForMetres d: Double, samples: Int) -> Double {
            let rssi = cal.txPower - 20 * log10(d)
            let r = OffScreenRSSI.widened(cal.reading(rssi: rssi, at: t0), samples: samples)
            return Fusion.exposurePClose(Fusion.fuse([r], now: t0)!)
        }
        XCTAssertEqual(pClose(rssiForMetres: 1, samples: 2), 0.799104425717208, accuracy: 1e-9)
        XCTAssertEqual(pClose(rssiForMetres: 3, samples: 2), 0.290630649965102, accuracy: 1e-9)
        XCTAssertEqual(pClose(rssiForMetres: 3, samples: 4), 0.21769543758573315, accuracy: 1e-9, "foreground unchanged")
    }

    // MARK: Exposure across foreground -> locked -> foreground

    private func output(_ readings: [Reading], now: Date) -> ContactGuard.Output? {
        guard let e = Fusion.fuse(readings, now: now) else { return nil }
        return ContactGuard.Output(id: "sick", risk: .contagious, pClose: Fusion.exposurePClose(e),
                                   distance: Fusion.doseDistance(e), corroborated: e.sources.contains(.uwb))
    }

    /// 60 s open with UWB at 0.5 m (1 s ticks), 120 s locked with only a polled link every 2 s (BLE at 1 m,
    /// uncalibrated, median of 2), 60 s open again. Every second is credited once, at the right pClose.
    func testExposureIsContinuousAcrossALock() {
        var accrual = SightingAccrual(), e = ExposureTracker()
        var last = t0, credited = 0.0
        func tick(_ s: Double, _ readings: [Reading]) {
            let now = at(s)
            let wall = now.timeIntervalSince(last)
            last = now
            let out = output(readings, now: now)
            ExposureTick.run(guarded: out.map { [$0] } ?? [], fresh: out == nil ? [] : ["sick"], now: now, wall: wall,
                             speed: 1, accrues: true, accrual: &accrual, exposure: &e) { credited += $0.seconds }
        }
        let cal = BLECalibrator()
        for s in 0 ... 60 { tick(Double(s), [Reading(source: .uwb, distance: 0.5, sigma: 0.1, at: at(Double(s)))]) }
        for s in stride(from: 62, through: 180, by: 2) {
            let ble = OffScreenRSSI.widened(cal.reading(rssi: cal.txPower, at: at(Double(s))), samples: 2)
            tick(Double(s), [ble])
        }
        for s in 181 ... 240 { tick(Double(s), [Reading(source: .uwb, distance: 0.5, sigma: 0.1, at: at(Double(s)))]) }
        XCTAssertEqual(credited, 240, accuracy: 1e-9, "every second from the first sighting, once")
        let pBG = 0.7213641044793042  // Φ(0.83 / (1.0 × √2))
        XCTAssertEqual(e.minutes, (60 + 120 * pBG + 60) / 60, accuracy: 1e-9)
    }

    /// The first locked sample arrives 15 s after the lock (no link held yet: one GATT read). Ticks in between
    /// have no fresh estimate and credit nothing; the sample then credits the whole 15 s, once.
    func testLateFirstSampleAfterLockCreditsTheGapOnce() {
        var accrual = SightingAccrual(), e = ExposureTracker()
        var last = t0, credits: [Double] = []
        func tick(_ s: Double, _ readings: [Reading]) {
            let now = at(s)
            let wall = now.timeIntervalSince(last)
            last = now
            let out = output(readings, now: now)
            ExposureTick.run(guarded: out.map { [$0] } ?? [], fresh: out == nil ? [] : ["sick"], now: now, wall: wall,
                             speed: 1, accrues: true, accrual: &accrual, exposure: &e) { credits.append($0.seconds) }
        }
        let uwbAt10 = Reading(source: .uwb, distance: 0.5, sigma: 0.1, at: at(10))
        for s in 0 ... 10 { tick(Double(s), [Reading(source: .uwb, distance: 0.5, sigma: 0.1, at: at(Double(s)))]) }
        tick(14, [uwbAt10])  // UWB grace: still usable at 4 s old
        tick(17, [uwbAt10])  // 7 s old: stale, no estimate, nothing credited
        XCTAssertEqual(credits.count, 11)
        let cal = BLECalibrator()
        tick(25, [OffScreenRSSI.widened(cal.reading(rssi: cal.txPower, at: at(25)), samples: 1)])
        XCTAssertEqual(credits.last!, 11, accuracy: 1e-9, "[14, 25] in one credit")
        XCTAssertEqual(credits.reduce(0, +), 25, accuracy: 1e-9)
        // UWB grace at 14 s: sigma 0.1 + 1 m/s × 1 s = 1.1 m at 0.5 m; then one sample at 1 m, sigma 1.0 × 2.
        let pGrace = 0.8866860392923388, pOne = 0.6609290484381688
        XCTAssertEqual(e.minutes, (10 + 4 * pGrace + 11 * pOne) / 60, accuracy: 1e-9)
    }

    func testLockLongerThanMaxGapCreditsNothingForTheGap() {
        var accrual = SightingAccrual(), e = ExposureTracker()
        var last = t0
        func tick(_ s: Double, _ r: Reading) {
            let now = at(s), wall = now.timeIntervalSince(last)
            last = now
            let out = output([r], now: now)!
            ExposureTick.run(guarded: [out], fresh: ["sick"], now: now, wall: wall, speed: 1, accrues: true,
                             accrual: &accrual, exposure: &e)
        }
        tick(0, Reading(source: .uwb, distance: 0.5, sigma: 0.1, at: at(0)))
        tick(1, Reading(source: .uwb, distance: 0.5, sigma: 0.1, at: at(1)))
        tick(1 + SightingAccrual.maxGap + 1, Reading(source: .uwb, distance: 0.5, sigma: 0.1, at: at(1 + SightingAccrual.maxGap + 1)))
        XCTAssertEqual(e.minutes, 1.0 / 60, accuracy: 1e-12, "only the first second; the 5 min+ gap is not guessed")
    }
}
