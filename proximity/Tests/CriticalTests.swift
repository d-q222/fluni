import CoreBluetooth
import XCTest
@testable import FluniProx

/// Deterministic SplitMix64 so every property loop is reproducible.
struct SplitMix: RandomNumberGenerator {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8(truncatingIfNeeded: next() >> 24) } }
}

private let garbage: [Double] = [.nan, .infinity, -.infinity, -1, -0.0, 0, 1e308, -1e308, 1e-320, 5, 1.83]

final class CriticalFusionTests: XCTestCase {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let sources = Source.allCases

    // S1: output finite and >= 0 for ANY input, including garbage distance/sigma.
    func testFuseFiniteNonNegativeForAnyInput() {
        var rng = SplitMix(1)
        for i in 0..<5000 {
            var rs: [Reading] = []
            for _ in 0...rng.int(4) {
                let src = sources[rng.int(3)]
                let d = rng.int(2) == 0 ? garbage[rng.int(garbage.count)] : rng.range(0, 30)
                let s = rng.int(2) == 0 ? garbage[rng.int(garbage.count)] : rng.range(0.01, 10)
                rs.append(Reading(source: src, distance: d, sigma: s, at: now.addingTimeInterval(-rng.range(0, 2))))
            }
            if let e = Fusion.fuse(rs, now: now) {
                XCTAssertTrue(e.distance.isFinite && e.distance >= 0, "S1 non-finite/negative distance \(e.distance) case \(i): \(rs)")
                XCTAssertTrue(e.sigma.isFinite && e.sigma >= 0, "S1 non-finite/negative sigma \(e.sigma) case \(i): \(rs)")
            }
        }
    }

    // S1: sigma = 0 alone must not give NaN/inf.
    func testSigmaZeroSingleReading() {
        for src in sources {
            if let e = Fusion.fuse([Reading(source: src, distance: 2, sigma: 0, at: now)], now: now) {
                XCTAssertTrue(e.distance.isFinite && e.sigma.isFinite, "S1 sigma 0 gave \(e)")
            }
        }
    }

    // S1: two sigma-0 readings disagreeing -> still finite.
    func testTwoZeroSigmaReadingsFinite() {
        if let e = Fusion.fuse([Reading(source: .uwb, distance: 1, sigma: 0, at: now),
                                Reading(source: .ble, distance: 3, sigma: 0, at: now)], now: now) {
            XCTAssertTrue(e.distance.isFinite && e.sigma.isFinite, "S1 two sigma-0 readings gave \(e)")
        }
    }

    // S1: garbage readings are ignored, not poisoning the valid ones.
    func testGarbageReadingsIgnored() {
        var rng = SplitMix(2)
        let bad: [(Double, Double)] = [(.nan, 1), (.infinity, 1), (-.infinity, 1), (-1, 1), (-5, 2),
                                       (2, .nan), (2, -1), (2, -.infinity), (.nan, .nan)]
        for i in 0..<500 {
            let valid = (0...rng.int(3)).map { _ in
                Reading(source: sources[rng.int(3)], distance: rng.range(0, 20), sigma: rng.range(0.1, 5), at: now)
            }
            var mixed = valid
            for _ in 0...rng.int(3) {
                let g = bad[rng.int(bad.count)]
                mixed.insert(Reading(source: sources[rng.int(3)], distance: g.0, sigma: g.1, at: now), at: rng.int(mixed.count + 1))
            }
            let clean = Fusion.fuse(valid, now: now)!
            guard let e = Fusion.fuse(mixed, now: now) else { XCTFail("S1 case \(i): nil with valid readings present"); continue }
            XCTAssertEqual(e.distance, clean.distance, accuracy: 1e-9, "S1 case \(i): garbage changed distance \(mixed)")
            XCTAssertEqual(e.sigma, clean.sigma, accuracy: 1e-9, "S1 case \(i): garbage changed sigma")
        }
    }

    // S1: all-garbage input yields nil or a finite estimate, never NaN.
    func testOnlyGarbageNilOrFinite() {
        let rs = [Reading(source: .uwb, distance: .nan, sigma: .nan, at: now),
                  Reading(source: .ble, distance: -4, sigma: -2, at: now)]
        if let e = Fusion.fuse(rs, now: now) {
            XCTAssertTrue(e.distance.isFinite && e.sigma.isFinite, "S1 only garbage gave \(e)")
        }
    }

    // S1: freshness boundary age == maxAge is fresh, just past is not.
    func testFreshnessBoundary() {
        for src in sources {
            let atLimit = Reading(source: src, distance: 1, sigma: 1, at: now.addingTimeInterval(-src.maxAge))
            let past = Reading(source: src, distance: 1, sigma: 1, at: now.addingTimeInterval(-src.maxAge - 0.001))
            XCTAssertNotNil(Fusion.fuse([atLimit], now: now), "S1 \(src) age == maxAge must be fresh")
            XCTAssertNil(Fusion.fuse([past], now: now), "S1 \(src) age just over maxAge must be stale")
        }
    }

    // S1: far-future timestamps (clock skew) must not be fresh forever.
    func testFutureReadingsNotFreshForever() {
        for src in sources {
            for skew in [60.0, 3600, 86400, 1e9] {
                let r = Reading(source: src, distance: 1, sigma: 1, at: now.addingTimeInterval(skew))
                XCTAssertNil(Fusion.fuse([r], now: now), "S1 \(src) reading \(skew)s in the future counted as fresh")
            }
        }
    }

    // S1: a stale reading must never outvote a fresh one even with tiny sigma.
    func testStaleTinySigmaIgnored() {
        let e = Fusion.fuse([Reading(source: .uwb, distance: 0.1, sigma: 1e-6, at: now.addingTimeInterval(-6.5)),
                             Reading(source: .ble, distance: 5, sigma: 1, at: now)], now: now)!
        XCTAssertEqual(e.distance, 5, accuracy: 1e-9, "S1 stale UWB influenced result")
    }

    // S2: estimate within [min,max] of valid fresh distances; order invariance; precise reading never raises sigma.
    func testBoundsOrderAndSigmaMonotone() {
        var rng = SplitMix(3)
        for i in 0..<3000 {
            var rs: [Reading] = []
            for _ in 0...rng.int(5) {
                let src = sources[rng.int(3)]
                rs.append(Reading(source: src, distance: rng.range(0, 40), sigma: rng.range(0.01, 20),
                                  at: now.addingTimeInterval(-rng.range(0, 25))))
            }
            let fresh = rs.filter { now.timeIntervalSince($0.at) <= $0.source.maxAge }
            guard let e = Fusion.fuse(rs, now: now) else {
                XCTAssertTrue(fresh.isEmpty, "S2 case \(i): nil despite fresh readings"); continue
            }
            let lo = fresh.map(\.distance).min()!, hi = fresh.map(\.distance).max()!
            XCTAssertGreaterThanOrEqual(e.distance, lo - 1e-9, "S2 case \(i): below min")
            XCTAssertLessThanOrEqual(e.distance, hi + 1e-9, "S2 case \(i): above max")
            let sh = Fusion.fuse(rs.shuffled(using: &rng), now: now)!
            XCTAssertEqual(sh.distance, e.distance, accuracy: 1e-9, "S2 case \(i): order changed distance")
            XCTAssertEqual(sh.sigma, e.sigma, accuracy: 1e-9, "S2 case \(i): order changed sigma")
            XCTAssertEqual(Set(sh.sources), Set(e.sources), "S2 case \(i): order changed sources")
            let minSigma = fresh.map(\.sigma).min()!
            let extra = Reading(source: sources[rng.int(3)], distance: rng.range(0, 40), sigma: minSigma * rng.range(0.1, 0.99), at: now)
            let e2 = Fusion.fuse(rs + [extra], now: now)!
            XCTAssertLessThanOrEqual(e2.sigma, e.sigma + 1e-12, "S2 case \(i): more precise reading raised sigma")
            XCTAssertLessThanOrEqual(e2.sigma, extra.sigma + 1e-12, "S2 case \(i): fused sigma worse than best input")
        }
    }

    // S3: pClose in [0,1] for any estimate.
    func testPCloseIsProbability() {
        var rng = SplitMix(4)
        var ests = [Estimate]()
        for d in garbage + [0, 1.83, 1.8300001, 10] {
            for s in garbage + [0.001, 1, 100] {
                ests.append(Estimate(distance: d, sigma: s, sources: [.uwb]))
            }
        }
        for _ in 0..<2000 { ests.append(Estimate(distance: rng.range(0, 50), sigma: rng.range(0, 10), sources: [.ble])) }
        for e in ests {
            let p = Fusion.pClose(e)
            XCTAssertTrue(p >= 0 && p <= 1, "S3 pClose(\(e.distance), \(e.sigma)) = \(p) not in [0,1]")
        }
    }

    // S3: sigma 0 is a point estimate: 1 below the threshold, 0 above, still a probability at it.
    func testPCloseSigmaZeroStep() {
        XCTAssertEqual(Fusion.pClose(Estimate(distance: 1, sigma: 0, sources: [.uwb])), 1, "S3 sigma 0, d=1")
        XCTAssertEqual(Fusion.pClose(Estimate(distance: 3, sigma: 0, sources: [.uwb])), 0, "S3 sigma 0, d=3")
    }

    // S3: monotonically non-increasing in distance for fixed sigma.
    func testPCloseMonotoneInDistance() {
        for s in [0.0, 0.01, 0.5, 1, 3, 10, 100] {
            var prev = 2.0, bad: String? = nil
            for k in 0...800 {
                let d = Double(k) * 0.025
                let p = Fusion.pClose(Estimate(distance: d, sigma: s, sources: [.gps]))
                if p.isNaN || p > prev + 1e-12 { bad = "d=\(d) p=\(p) prev=\(prev)"; break }
                prev = p
            }
            XCTAssertNil(bad, "S3 pClose not monotone for sigma \(s): \(bad ?? "")")
        }
    }

    // S4: BLE distance finite and positive across RSSI range and txPower values.
    func testBLEDistanceFinitePositive() {
        for tx in [-100.0, -80, -59, -40, -20] {
            var cal = BLECalibrator(); cal.txPower = tx
            var r = -110.0
            while r <= 0 {
                let d = cal.distance(rssi: r)
                XCTAssertTrue(d.isFinite && d > 0, "S4 distance(\(r)) = \(d) at txPower \(tx)")
                r += 0.5
            }
        }
    }

    // S4: single outliers must not make txPower absurd.
    func testOutlierDoesNotMakeTxPowerAbsurd() {
        let outliers: [(Double, Double)] = [(-20, 10), (0, 100), (0, 10), (-20, 0.01), (-110, 0.06), (0, 1000), (-110, 0.5)]
        for (rssi, d) in outliers {
            var cal = BLECalibrator()
            cal.observe(rssi: rssi, trueDistance: d)
            XCTAssertTrue(cal.txPower >= -100 && cal.txPower <= -20, "S4 observe(\(rssi), \(d)) -> txPower \(cal.txPower)")
        }
    }

    // S4: one outlier in a stream of good samples.
    func testOutlierAmongGoodSamples() {
        var rng = SplitMix(5)
        var cal = BLECalibrator()
        for k in 0..<60 {
            let d = rng.range(0.5, 4)
            if k % 10 == 3 { cal.observe(rssi: -20, trueDistance: 10) }
            else { cal.observe(rssi: -65 - 20 * log10(d), trueDistance: d) }
            XCTAssertTrue(cal.txPower >= -100 && cal.txPower <= -20, "S4 txPower \(cal.txPower) absurd at step \(k)")
        }
    }

    // S4: garbage inputs (NaN/inf) must not poison txPower.
    func testGarbageObservationDoesNotPoison() {
        for (r, d) in [(Double.nan, 1.0), (-60, .nan), (-60, .infinity), (.infinity, 1), (-.infinity, 1)] {
            var cal = BLECalibrator()
            cal.observe(rssi: r, trueDistance: d)
            XCTAssertTrue(cal.txPower.isFinite, "S4 observe(\(r), \(d)) -> txPower \(cal.txPower)")
            cal.observe(rssi: -60, trueDistance: 1)
            XCTAssertTrue(cal.txPower.isFinite && cal.distance(rssi: -60).isFinite, "S4 poisoned permanently after observe(\(r), \(d))")
        }
    }

    // S4: noisy convergence within 2 dB after 50 samples.
    func testCalibrationConvergesWithNoise() {
        for (seed, truth) in [(UInt64(10), -70.0), (11, -50), (12, -85), (13, -59), (14, -65), (15, -40)] {
            var rng = SplitMix(seed)
            var cal = BLECalibrator()
            for _ in 0..<50 {
                let d = rng.range(0.5, 5)
                cal.observe(rssi: truth - 20 * log10(d) + rng.range(-4, 4), trueDistance: d)
            }
            XCTAssertEqual(cal.txPower, truth, accuracy: 2, "S4 seed \(seed) truth \(truth) not converged")
        }
    }

    // S4: isCalibrated flips at exactly 5 samples; too-close samples are not samples.
    func testCalibratedAtExactlyFive() {
        var cal = BLECalibrator()
        for k in 1...6 {
            cal.observe(rssi: -60, trueDistance: 1)
            XCTAssertEqual(cal.isCalibrated, k >= 5, "S4 isCalibrated wrong after \(k) samples")
        }
        var c2 = BLECalibrator()
        for _ in 0..<10 { c2.observe(rssi: -60, trueDistance: 0.01) }
        XCTAssertFalse(c2.isCalibrated, "S4 untrustworthy samples counted toward calibration")
        XCTAssertEqual(c2.txPower, BLECalibrator.defaultTxPower, "S4 txPower moved on rejected samples")
    }

    // S4: BLE reading sigma positive and finite across range.
    func testBLEReadingSigmaSane() {
        let cal = BLECalibrator()
        var r = -110.0
        while r <= 0 {
            let x = cal.reading(rssi: r, at: now)
            XCTAssertTrue(x.sigma.isFinite && x.sigma > 0 && x.distance.isFinite, "S4 bad reading at rssi \(r): \(x)")
            r += 1
        }
    }

    // S5: sigma >= 3 and finite for valid coordinates.
    func testGPSSigmaFloorAndFinite() {
        var rng = SplitMix(6)
        for i in 0..<2000 {
            let r = gpsReading(myLat: rng.range(-89, 89), myLon: rng.range(-180, 180), myAcc: rng.range(0, 30),
                               peerLat: rng.range(-89, 89), peerLon: rng.range(-180, 180), peerAcc: rng.range(0, 30), at: now)
            XCTAssertTrue(r.sigma >= 3 && r.sigma.isFinite, "S5 case \(i): sigma \(r.sigma)")
            XCTAssertTrue(r.distance.isFinite && r.distance >= 0 && r.distance <= 20_100_000, "S5 case \(i): distance \(r.distance)")
        }
    }

    // S5: identical points -> 0, including poles and extremes.
    func testGPSIdenticalPointsZero() {
        for (la, lo) in [(0.0, 0.0), (37.4, -122.1), (90, 0), (-90, 45), (0, 180), (0, -180), (89.9999, 179.9999)] {
            let r = gpsReading(myLat: la, myLon: lo, myAcc: 5, peerLat: la, peerLon: lo, peerAcc: 5, at: now)
            XCTAssertEqual(r.distance, 0, accuracy: 1e-6, "S5 identical point (\(la),\(lo)) distance \(r.distance)")
        }
    }

    // S5: antimeridian is short, not ~40000 km.
    func testGPSAntimeridian() {
        let r = gpsReading(myLat: 0, myLon: 179.9999, myAcc: 5, peerLat: 0, peerLon: -179.9999, peerAcc: 5, at: now)
        XCTAssertEqual(r.distance, 22.2, accuracy: 0.5, "S5 antimeridian distance \(r.distance) m")
        let r2 = gpsReading(myLat: 60, myLon: -179.99995, myAcc: 5, peerLat: 60, peerLon: 179.99995, peerAcc: 5, at: now)
        XCTAssertLessThan(r2.distance, 20, "S5 antimeridian at 60N gave \(r2.distance) m")
    }

    // S5: symmetric in the two phones.
    func testGPSSymmetric() {
        var rng = SplitMix(7)
        for i in 0..<1000 {
            let a = (rng.range(-89, 89), rng.range(-180, 180), rng.range(0, 30))
            let b = (rng.range(-89, 89), rng.range(-180, 180), rng.range(0, 30))
            let x = gpsReading(myLat: a.0, myLon: a.1, myAcc: a.2, peerLat: b.0, peerLon: b.1, peerAcc: b.2, at: now)
            let y = gpsReading(myLat: b.0, myLon: b.1, myAcc: b.2, peerLat: a.0, peerLon: a.1, peerAcc: a.2, at: now)
            XCTAssertEqual(x.distance, y.distance, accuracy: 1e-6 * max(1, x.distance), "S5 case \(i): asymmetric distance")
            XCTAssertEqual(x.sigma, y.sigma, accuracy: 1e-9, "S5 case \(i): asymmetric sigma")
        }
    }

    // S5: garbage input must not produce a confident close reading.
    func testGPSGarbageNotConfidentlyClose() {
        let nan = Double.nan
        // (myLat, myLon, myAcc, peerLat, peerLon, peerAcc, expected-garbage-label)
        let cases: [(Double, Double, Double, Double, Double, Double, String)] = [
            (nan, -122, 5, 37.0, -122, 5, "NaN lat"),
            (37, nan, 5, 37.0, -122, 5, "NaN lon"),
            (37, -122, 5, nan, nan, 5, "NaN peer"),
            (37, -122, -1, 37.00001, -122, -1, "acc -1 both (CoreLocation invalid)"),
            (37, -122, -1, 37.00001, -122, 5, "acc -1 mine"),
            (37, -122, nan, 37.00001, -122, nan, "acc NaN"),
            (37, -122, 5, 37.00001, -122, -1, "acc -1 peer"),
        ]
        for c in cases {
            let r = gpsReading(myLat: c.0, myLon: c.1, myAcc: c.2, peerLat: c.3, peerLon: c.4, peerAcc: c.5, at: now)
            if let e = Fusion.fuse([r], now: now) {
                XCTAssertLessThanOrEqual(Fusion.pClose(e), 0.5, "S5 \(c.6) yielded pClose \(Fusion.pClose(e)) (reading \(r))")
            }
        }
        // accuracy 1e9 => no information; must not be treated as confident either way.
        let r = gpsReading(myLat: 37, myLon: -122, myAcc: 1e9, peerLat: 37, peerLon: -122, peerAcc: 1e9, at: now)
        if let e = Fusion.fuse([r], now: now) {
            XCTAssertLessThanOrEqual(Fusion.pClose(e), 0.5 + 1e-3, "S5 acc 1e9 pClose \(Fusion.pClose(e))")
        }
    }
}

final class CriticalExposureTests: XCTestCase {
    private func tick(_ t: inout ExposureTracker, _ s: Double, _ p: Double, _ r: Risk) {
        t.advance(simSeconds: s, contacts: [(p, r)])
    }

    // S6 (with the agreed rolling 24 h window): minutes are never NaN/inf/negative, even with garbage
    // inputs; within the first 24 h of simulated time they never decrease and closeContact is sticky.
    // A huge finite step (1e308 s, clamped to 24 h) legitimately expires everything, so after that
    // only finiteness is checked.
    func testMinutesMonotoneFiniteUnderGarbage() {
        var rng = SplitMix(20)
        let bad: [Double] = [.nan, .infinity, -.infinity, -5, -0.001, 1e308, -1e308, 7, 1.0000001]
        for trial in 0..<300 {
            var t = ExposureTracker()
            var prev = 0.0, wasClose = false, elapsed = 0.0
            for step in 0..<60 {
                let s = rng.int(3) == 0 ? bad[rng.int(bad.count)] : rng.range(0, 120)
                let cs: [(pClose: Double, risk: Risk)] = (0..<rng.int(4)).map { _ in
                    (rng.int(3) == 0 ? bad[rng.int(bad.count)] : rng.unit(), Risk.allCases[rng.int(3)])
                }
                t.advance(simSeconds: s, contacts: cs)
                elapsed += s.isFinite ? min(max(s, 0), ExposureTracker.window) : 0
                XCTAssertTrue(t.minutes.isFinite && t.minutes >= 0, "S6 trial \(trial) step \(step): minutes \(t.minutes) after sim=\(s) \(cs)")
                XCTAssertTrue(t.dose.isFinite && t.dose >= 0, "S6 trial \(trial) step \(step): dose \(t.dose)")
                guard elapsed < ExposureTracker.window - 60 else { break }  // window reached: expiry is allowed
                XCTAssertGreaterThanOrEqual(t.minutes, prev, "S6 trial \(trial) step \(step): minutes decreased after sim=\(s) \(cs)")
                if t.minutes.isFinite { prev = t.minutes } else { break }
                if wasClose { XCTAssertEqual(t.level, .closeContact, "S6 closeContact not sticky") }
                wasClose = t.level == .closeContact
            }
        }
    }

    // S6: negative time (clock stepped back) must not reduce minutes.
    func testNegativeSimSecondsIgnored() {
        var t = ExposureTracker()
        tick(&t, 300, 1, .contagious)
        tick(&t, -300, 1, .contagious)
        XCTAssertEqual(t.minutes, 5, accuracy: 1e-9, "S6 negative time changed minutes to \(t.minutes)")
    }

    // S6: pClose out of range is clamped/ignored.
    func testPCloseClamped() {
        var t = ExposureTracker()
        tick(&t, 60, 5, .contagious)
        XCTAssertLessThanOrEqual(t.minutes, 1 + 1e-9, "S6 pClose 5 counted \(t.minutes) min for 1 min")
        var u = ExposureTracker()
        tick(&u, 60, -3, .contagious)
        XCTAssertGreaterThanOrEqual(u.minutes, 0, "S6 negative pClose reduced minutes")
    }

    // S6: NaN pClose / inf time don't poison the accumulator.
    func testNaNAndInfDoNotPoison() {
        var t = ExposureTracker()
        tick(&t, 60, .nan, .contagious)
        tick(&t, 60, 1, .contagious)
        XCTAssertTrue(t.minutes.isFinite, "S6 NaN pClose poisoned minutes: \(t.minutes)")
        XCTAssertGreaterThanOrEqual(t.minutes, 1 - 1e-9, "S6 valid tick lost after NaN tick: \(t.minutes)")
        var u = ExposureTracker()
        tick(&u, .infinity, 1, .contagious)
        XCTAssertTrue(u.minutes.isFinite, "S6 infinite simSeconds -> minutes \(u.minutes)")
        var v = ExposureTracker()
        tick(&v, .nan, 1, .contagious)
        XCTAssertTrue(v.minutes.isFinite, "S6 NaN simSeconds -> minutes \(v.minutes)")
        tick(&v, 900, 1, .contagious)
        XCTAssertEqual(v.level, .closeContact, "S6 NaN tick permanently disabled alerting")
    }

    // S6: boundary is >=; exactly 15.0 triggers.
    func testExactlyFifteenTriggers() {
        var t = ExposureTracker()
        tick(&t, 900, 1, .contagious)
        XCTAssertEqual(t.minutes, 15.0, "S6 minutes != 15")
        XCTAssertEqual(t.level, .closeContact, "S6 exactly 15.0 min must be closeContact")
        var u = ExposureTracker()
        tick(&u, 899.9, 1, .contagious)
        XCTAssertNotEqual(u.level, .closeContact, "S6 14.998 min must not be closeContact")
        var w = ExposureTracker()
        tick(&w, 1800, 0.5, .contagious)  // 0.5 * 30 = 15
        XCTAssertEqual(w.level, .closeContact, "S6 pClose .5 for 30 min = 15 min")
    }

    // S6: floating drift over many small ticks must still reach 15 min.
    func testManySmallTicksReachFifteen() {
        for (n, dt) in [(900, 1.0), (54000, 1.0 / 60), (9000, 0.1), (90000, 0.01), (9000, 0.1)] {
            var t = ExposureTracker()
            for _ in 0..<n { tick(&t, dt, 1, .contagious) }
            XCTAssertEqual(t.level, .closeContact, "S6 \(n) ticks of \(dt)s reached only \(t.minutes) min (drift)")
        }
        // possible-risk: 1800 ticks of 1s at weight 0.5 = 15 min
        var t = ExposureTracker()
        for _ in 0..<1800 { tick(&t, 1, 1, .possible) }
        XCTAssertEqual(t.level, .closeContact, "S6 1800 x 1s possible only \(t.minutes) min")
        // 0.3 pClose: 3000 x 1s = 15 min
        var u = ExposureTracker()
        for _ in 0..<3000 { tick(&u, 1, 0.3, .contagious) }
        XCTAssertEqual(u.level, .closeContact, "S6 3000 x 1s at p=.3 only \(u.minutes) min")
    }

    // S6: healthy contacts never add minutes, whatever pClose.
    func testHealthyNeverAdds() {
        var t = ExposureTracker()
        for p in [0, 0.5, 1, 5, -1, .nan, .infinity, -.infinity] {
            tick(&t, 600, p, .none)
            XCTAssertEqual(t.minutes, 0, "S6 healthy contact added minutes at pClose \(p)")
            XCTAssertEqual(t.level, .none, "S6 healthy contact raised level at pClose \(p)")
        }
        t.advance(simSeconds: 600, contacts: [(1, .none), (.nan, .none), (1, .none)])
        XCTAssertEqual(t.minutes, 0, "S6 healthy contacts added minutes")
    }

    // S6: persistence and reset.
    func testCloseContactPersistsAndResets() {
        var t = ExposureTracker()
        tick(&t, 900, 1, .contagious)
        for _ in 0..<5 { t.advance(simSeconds: 100, contacts: []) }
        XCTAssertEqual(t.level, .closeContact, "S6 closeContact lost when contacts vanished")
        tick(&t, 1, 0, .contagious)
        XCTAssertEqual(t.level, .closeContact, "S6 closeContact lost on far contact")
        t.reset()
        XCTAssertEqual(t.level, .none); XCTAssertEqual(t.minutes, 0, "S6 reset left minutes")
        XCTAssertEqual(t, ExposureTracker(), "S6 reset did not restore initial state")
    }

    // S6: hysteresis thresholds exactly.
    func testHysteresisBoundaries() {
        var t = ExposureTracker()
        tick(&t, 1, 0.4999999, .contagious); XCTAssertEqual(t.level, .none, "S6 entered nearby below 0.5")
        tick(&t, 1, 0.5, .contagious); XCTAssertEqual(t.level, .nearby, "S6 must enter nearby at exactly 0.5")
        tick(&t, 1, 0.3, .contagious); XCTAssertEqual(t.level, .nearby, "S6 exactly 0.3 must stay nearby")
        tick(&t, 1, 0.2999999, .contagious); XCTAssertEqual(t.level, .none, "S6 below 0.3 must leave nearby")
        for risk in [Risk.possible, .contagious] {
            var u = ExposureTracker()
            tick(&u, 1, 0.5, risk); XCTAssertEqual(u.level, .nearby, "S6 \(risk) at 0.5 must be nearby")
        }
    }

    // S6: with several risky contacts, the max drives the level; healthy contacts never do.
    func testHysteresisMaxOfContacts() {
        var t = ExposureTracker()
        t.advance(simSeconds: 1, contacts: [(0.45, .contagious), (0.49, .possible)])
        XCTAssertEqual(t.level, .none, "S6 two sub-0.5 contacts must not enter")
        t.advance(simSeconds: 1, contacts: [(0.1, .contagious), (0.6, .possible)])
        XCTAssertEqual(t.level, .nearby, "S6 max 0.6 must enter")
        t.advance(simSeconds: 1, contacts: [(0.35, .contagious), (0.1, .possible)])
        XCTAssertEqual(t.level, .nearby, "S6 max 0.35 must stay nearby")
        t.advance(simSeconds: 1, contacts: [(0.1, .contagious), (0.29, .possible), (0.99, .none)])
        XCTAssertEqual(t.level, .none, "S6 healthy 0.99 contact must not hold nearby")
        var u = ExposureTracker()
        u.advance(simSeconds: 1, contacts: [(1, .none), (1, .none)])
        XCTAssertEqual(u.level, .none, "S6 healthy contacts at p=1 must not enter")
    }

    // S6: demo speed-up arithmetic: contributions add exactly across simultaneous contacts.
    func testSimultaneousContactsAdd() {
        var t = ExposureTracker()
        t.advance(simSeconds: 300, contacts: [(1, .contagious), (1, .contagious), (1, .contagious)])
        XCTAssertEqual(t.minutes, 15, accuracy: 1e-9, "S6 three contacts x 5 min")
        XCTAssertEqual(t.level, .closeContact)
    }
}

final class CriticalBeaconWireTests: XCTestCase {
    // S7: any 16-byte UUID with a mutated magic byte is rejected.
    func testWrongMagicRejectedExhaustively() {
        var rng = SplitMix(30)
        for pos in 0..<4 {
            for v in 0...255 where UInt8(v) != BLEBeacon.magic[pos] {
                var b = BLEBeacon.magic + [1] + rng.bytes(11)
                b[pos] = UInt8(v)
                XCTAssertNil(BLEBeacon.decode(CBUUID(data: Data(b))), "S7 magic byte \(pos)=\(v) accepted")
            }
        }
        for i in 0..<2000 {
            var b = rng.bytes(16)
            if Array(b[0..<4]) == BLEBeacon.magic { b[Int(rng.int(4))] ^= 0x01 }
            XCTAssertNil(BLEBeacon.decode(CBUUID(data: Data(b))), "S7 random non-magic uuid \(i) accepted")
        }
    }

    // S7: risk byte outside 0...2 rejected; 0...2 accepted.
    func testRiskByteRange() {
        let id = Data(repeating: 0xAB, count: 11)
        for rb in 0...255 {
            let d = BLEBeacon.decode(CBUUID(data: Data(BLEBeacon.magic + [UInt8(rb)]) + id))
            if rb <= 2 { XCTAssertEqual(d?.risk.rawValue, rb, "S7 risk byte \(rb) not decoded") }
            else { XCTAssertNil(d, "S7 risk byte \(rb) accepted") }
        }
    }

    // S7: 11-byte IDs round-trip, including edge and random IDs.
    func testIDRoundTrip() {
        var rng = SplitMix(31)
        var ids: [[UInt8]] = [Array(repeating: 0, count: 11), Array(repeating: 0xFF, count: 11)]
        ids += (0..<400).map { _ in rng.bytes(11) }
        for (i, id) in ids.enumerated() {
            for risk in Risk.allCases {
                let uuid = CBUUID(data: Data(BLEBeacon.magic + [UInt8(risk.rawValue)] + id))
                let d = BLEBeacon.decode(uuid)
                XCTAssertEqual(d?.id, Data(id).hex, "S7 id \(i) round-trip failed")
                XCTAssertEqual(d?.risk, risk, "S7 id \(i) risk mismatch")
                XCTAssertEqual(d?.id.count, 22, "S7 id hex must be 22 chars")
            }
        }
    }

    // S7: hex is lowercase, 2 chars/byte, equals %02x for all bytes; also on slices (non-zero startIndex).
    func testHexMatchesPrintf() {
        for v in 0...255 {
            XCTAssertEqual(Data([UInt8(v)]).hex, String(format: "%02x", v), "S7 hex wrong for byte \(v)")
        }
        var rng = SplitMix(32)
        for _ in 0..<300 {
            let b = rng.bytes(rng.int(40))
            let expect = b.map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(Data(b).hex, expect, "S7 hex wrong for \(b)")
            let padded = Data([1, 2, 3] + b)
            XCTAssertEqual(padded[3...].hex, expect, "S7 hex wrong on slice")
        }
    }

    // S7: hex of all 256 bytes in one buffer is lowercase.
    func testHexAllBytesLowercase() {
        let h = Data((0...255).map { UInt8($0) }).hex
        XCTAssertEqual(h.count, 512)
        XCTAssertEqual(h, h.lowercased(), "S7 hex has uppercase")
    }

    // ---- S8 ----
    private func decode(_ s: String) throws -> Wire { try JSONDecoder().decode(Wire.self, from: Data(s.utf8)) }

    func testMalformedJSONThrows() {
        for s in ["", "{", "}", "not json", "null", "[]", "[1,2]", "42", "\"hello\"", "{\"kind\":", "{\"kind\":\"hello\"",
                  "{'kind':'hello'}", "{\"kind\":\"hello\"}}", "\u{0}"] {
            XCTAssertThrowsError(try decode(s), "S8 malformed JSON accepted: \(s.debugDescription)")
        }
        XCTAssertThrowsError(try JSONDecoder().decode(Wire.self, from: Data()), "S8 empty data accepted")
        XCTAssertThrowsError(try JSONDecoder().decode(Wire.self, from: Data([0xFF, 0xFE, 0x00])), "S8 binary garbage accepted")
    }

    func testUnknownOrWrongKindThrows() {
        for s in ["{\"kind\":\"bogus\"}", "{\"kind\":\"HELLO\"}", "{\"kind\":\"\"}", "{\"kind\":1}", "{\"kind\":null}",
                  "{\"kind\":[\"hello\"]}", "{}", "{\"id\":\"a\",\"risk\":1}"] {
            XCTAssertThrowsError(try decode(s), "S8 bad kind accepted: \(s)")
        }
    }

    func testWrongTypesThrow() {
        for s in ["{\"kind\":\"hello\",\"id\":5}", "{\"kind\":\"hello\",\"id\":[\"a\"]}", "{\"kind\":\"hello\",\"risk\":\"1\"}",
                  "{\"kind\":\"hello\",\"risk\":1.5}", "{\"kind\":\"hello\",\"risk\":true}",
                  "{\"kind\":\"gps\",\"lat\":\"37\"}", "{\"kind\":\"gps\",\"lon\":[1]}", "{\"kind\":\"gps\",\"acc\":{}}",
                  "{\"kind\":\"uwbToken\",\"token\":5}", "{\"kind\":\"uwbToken\",\"token\":\"%%%not-base64%%%\"}",
                  "{\"kind\":\"uwbToken\",\"token\":[1,2,3]}"] {
            XCTAssertThrowsError(try decode(s), "S8 wrong type accepted: \(s)")
        }
    }

    // S8: out-of-range risk raw value fails to decode.
    func testOutOfRangeRiskThrows() {
        for r in [3, 9, -1, 100, 2147483647, -2147483648] {
            XCTAssertThrowsError(try decode("{\"kind\":\"hello\",\"id\":\"ab\",\"risk\":\(r)}"), "S8 risk \(r) accepted")
        }
        for r in 0...2 { XCTAssertNoThrow(try decode("{\"kind\":\"hello\",\"id\":\"ab\",\"risk\":\(r)}"), "S8 risk \(r) rejected") }
    }

    // S8: mutated valid payloads and random bytes never crash (throwing is fine).
    func testFuzzDoesNotCrash() throws {
        var rng = SplitMix(33)
        let seed = try JSONEncoder().encode(Wire(kind: .hello, id: "abcd", risk: .possible, token: Data([1, 2]), lat: 1, lon: 2, acc: 3))
        for _ in 0..<2000 {
            var b = [UInt8](seed)
            for _ in 0...rng.int(4) { b[rng.int(b.count)] = UInt8(truncatingIfNeeded: rng.next()) }
            _ = try? JSONDecoder().decode(Wire.self, from: Data(b))
            _ = try? JSONDecoder().decode(Wire.self, from: Data(rng.bytes(rng.int(64))))
            _ = try? JSONDecoder().decode(Wire.self, from: Data(b.prefix(rng.int(b.count))))
        }
    }

    // S8: round trip keeps every field, for each kind and with all fields populated.
    func testRoundTripAllFields() throws {
        var rng = SplitMix(34)
        for kind in [Wire.Kind.hello, .uwbToken, .gps] {
            for risk in Risk.allCases {
                let w = Wire(kind: kind, id: "id-\(rng.int(1000))ü☃", risk: risk, token: Data(rng.bytes(rng.int(300))),
                             lat: rng.range(-90, 90), lon: rng.range(-180, 180), acc: rng.range(0, 1e4))
                let r = try JSONDecoder().decode(Wire.self, from: JSONEncoder().encode(w))
                XCTAssertEqual(r.kind, w.kind, "S8 kind lost"); XCTAssertEqual(r.id, w.id, "S8 id lost")
                XCTAssertEqual(r.risk, w.risk, "S8 risk lost"); XCTAssertEqual(r.token, w.token, "S8 token lost")
                XCTAssertEqual(r.lat, w.lat, "S8 lat lost"); XCTAssertEqual(r.lon, w.lon, "S8 lon lost")
                XCTAssertEqual(r.acc, w.acc, "S8 acc lost")
            }
        }
        let bare = try JSONDecoder().decode(Wire.self, from: JSONEncoder().encode(Wire(kind: .gps)))
        XCTAssertNil(bare.id); XCTAssertNil(bare.risk); XCTAssertNil(bare.token)
        XCTAssertNil(bare.lat); XCTAssertNil(bare.lon); XCTAssertNil(bare.acc)
    }

    // S8: empty-string id and empty token survive (not collapsed to nil).
    func testEmptyValuesSurvive() throws {
        let r = try JSONDecoder().decode(Wire.self, from: JSONEncoder().encode(Wire(kind: .hello, id: "", risk: Risk.none, token: Data())))
        XCTAssertEqual(r.id, "", "S8 empty id lost"); XCTAssertEqual(r.token, Data(), "S8 empty token lost")
        XCTAssertEqual(r.risk, Risk.none, "S8 risk .none lost")
    }
}
