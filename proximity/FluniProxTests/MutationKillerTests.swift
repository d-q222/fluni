import CoreBluetooth
import XCTest
@testable import FluniProx

/// Tests added after mutation testing. Every expected value here is a literal from the spec
/// (README), never a constant read back from the code under test.
final class MutationKillerTests: XCTestCase {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func fresh(_ src: Source, age: Double, d: Double = 1, s: Double = 1) -> Bool {
        Fusion.fuse([Reading(source: src, distance: d, sigma: s, at: now.addingTimeInterval(-age))], now: now) != nil
    }

    // Spec: UWB 3 s, BLE 6 s, GPS 20 s. Literals, not `src.maxAge`, so a changed window is caught.
    func testFreshnessWindowsAreTheSpecLiterals() {
        for (src, limit) in [(Source.uwb, 3.0), (.ble, 6.0), (.gps, 20.0)] {
            XCTAssertTrue(fresh(src, age: limit), "\(src) at \(limit) s must be fresh")
            XCTAssertFalse(fresh(src, age: limit + 0.01), "\(src) past \(limit) s must be stale")
            XCTAssertFalse(fresh(src, age: limit + 1), "\(src) 1 s past the window must be stale")
        }
    }

    // Spec: readings up to 1 s in the future are tolerated (clock jitter), beyond that rejected.
    func testFutureToleranceIsOneSecond() {
        for src in Source.allCases {
            XCTAssertTrue(fresh(src, age: -0.9), "\(src) 0.9 s in the future must be accepted")
            XCTAssertTrue(fresh(src, age: -1.0), "\(src) exactly 1 s in the future must be accepted")
            XCTAssertFalse(fresh(src, age: -1.1), "\(src) 1.1 s in the future must be rejected")
            XCTAssertFalse(fresh(src, age: -5), "\(src) 5 s in the future must be rejected")
        }
    }

    // Spec: > 100 km is garbage; anything up to 100 km is a measurement.
    func testPlausibilityLimitIs100km() {
        XCTAssertTrue(fresh(.gps, age: 0, d: 50_000, s: 10), "50 km distance must be kept")
        XCTAssertTrue(fresh(.gps, age: 0, d: 100_000, s: 10), "exactly 100 km must be kept")
        XCTAssertFalse(fresh(.gps, age: 0, d: 150_000, s: 10), "150 km distance must be rejected")
        XCTAssertTrue(fresh(.gps, age: 0, d: 10, s: 50_000), "50 km sigma must be kept")
        XCTAssertFalse(fresh(.gps, age: 0, d: 10, s: 150_000), "150 km sigma must be rejected")
    }

    // Inverse-variance mean, checked against a hand-computed value (weights 1/0.01 and 1/0.04 -> 4:1).
    func testInverseVarianceWeightsExactly() {
        let e = Fusion.fuse([Reading(source: .uwb, distance: 1, sigma: 0.1, at: now),
                             Reading(source: .ble, distance: 6, sigma: 0.2, at: now)], now: now)!
        XCTAssertEqual(e.distance, 2.0, accuracy: 1e-9)                          // (4*1 + 1*6) / 5
        XCTAssertEqual(e.sigma, (1 / (100.0 + 25.0)).squareRoot(), accuracy: 1e-12)
        // Sub-centimetre sigmas are real UWB values and must still be weighted by 1/sigma^2 (16:1 here).
        let f = Fusion.fuse([Reading(source: .uwb, distance: 0, sigma: 0.001, at: now),
                             Reading(source: .ble, distance: 17, sigma: 0.004, at: now)], now: now)!
        XCTAssertEqual(f.distance, 1.0, accuracy: 1e-6)
    }

    // pClose against textbook normal-CDF values with the spec's 1.83 m written out.
    func testPCloseKnownValues() {
        func p(_ d: Double, _ s: Double) -> Double { Fusion.pClose(Estimate(distance: d, sigma: s, sources: [.uwb])) }
        XCTAssertEqual(p(1.83, 1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(p(0.83, 1), 0.841_344_746, accuracy: 1e-6)   // Phi(1)
        XCTAssertEqual(p(2.83, 1), 0.158_655_254, accuracy: 1e-6)   // Phi(-1)
        XCTAssertEqual(p(1.83 - 0.196, 0.1), 0.975_002_105, accuracy: 1e-6)  // Phi(1.96)
        XCTAssertEqual(p(1.82, 0), 1)
        XCTAssertEqual(p(1.84, 0), 0)
    }

    // Spec: GPS alone is gated only when sigma > 10 m (strictly).
    func testGPSOnlyGateIsStrictlyAbove10m() {
        for s in [5.0, 8.0, 10.0] {
            let e = Estimate(distance: 1, sigma: s, sources: [.gps])
            XCTAssertEqual(Fusion.exposurePClose(e), Fusion.pClose(e), "GPS sigma \(s) must count")
            XCTAssertGreaterThan(Fusion.exposurePClose(e), 0)
        }
        for s in [10.01, 12.0, 15.0] {
            XCTAssertEqual(Fusion.exposurePClose(Estimate(distance: 1, sigma: s, sources: [.gps])), 0, "GPS sigma \(s) must be gated")
        }
    }

    // BLE reading sigma = 0.7 d + 0.3 uncalibrated, 0.4 d + 0.3 calibrated (README).
    func testBLEReadingSigmaFormula() {
        var cal = BLECalibrator()
        let r = cal.reading(rssi: -79, at: now)                 // -59 default, n = 2 -> 10 m
        XCTAssertEqual(r.distance, 10, accuracy: 1e-9)
        XCTAssertEqual(r.sigma, 0.7 * 10 + 0.3, accuracy: 1e-9)
        for _ in 0..<5 { cal.observe(rssi: -59, trueDistance: 1) }
        XCTAssertEqual(cal.reading(rssi: -79, at: now).sigma, 0.4 * 10 + 0.3, accuracy: 1e-9)
    }

    // txPower EMA: alpha 0.5 for the first 5 samples, then 0.1. Implied txPower here is -70 every time.
    func testCalibrationEMAExactSteps() {
        var cal = BLECalibrator()
        var expected = -59.0
        for k in 1...7 {
            cal.observe(rssi: -70, trueDistance: 1)
            expected += (k <= 5 ? 0.5 : 0.1) * (-70 - expected)
            XCTAssertEqual(cal.txPower, expected, accuracy: 1e-9, "after \(k) samples")
        }
    }

    // Implausible samples are rejected: RSSI outside -110...0 dBm, or an implied 1-m power outside -100...-20.
    func testCalibrationRejectsImplausibleSamples() {
        for (rssi, d) in [(-115.0, 10.0),   // implied -95 would be in range, but -115 dBm is below the floor
                          (1.0, 0.07),      // positive RSSI; implied ~-22
                          (-90.0, 0.1),     // implied -110: below -100
                          (-35.0, 10.0)] {  // implied -15: above -20
            var cal = BLECalibrator()
            for _ in 0..<5 { cal.observe(rssi: rssi, trueDistance: d) }
            XCTAssertFalse(cal.isCalibrated, "rssi \(rssi) at \(d) m must be rejected")
            XCTAssertEqual(cal.txPower, -59, "rssi \(rssi) at \(d) m moved txPower")
        }
    }

    // Close-but-valid UWB distances (> 5 cm) are calibration samples.
    func testShortRangeSampleCounts() {
        var cal = BLECalibrator()
        for _ in 0..<5 { cal.observe(rssi: -79, trueDistance: 0.1) }   // implied -99, inside range
        XCTAssertTrue(cal.isCalibrated)
        XCTAssertNotEqual(cal.txPower, BLECalibrator.defaultTxPower)
    }

    // Haversine east-west: 0.001 deg of longitude at 60 N is ~55.6 m (cos 60 = 0.5).
    func testGPSLongitudeScalesWithLatitude() {
        let r = gpsReading(myLat: 60, myLon: 10, myAcc: 5, peerLat: 60, peerLon: 10.001, peerAcc: 5, at: now)
        XCTAssertEqual(r.distance, 55.6, accuracy: 0.2)
        let eq = gpsReading(myLat: 0, myLon: 10, myAcc: 5, peerLat: 0, peerLon: 10.001, peerAcc: 5, at: now)
        XCTAssertEqual(eq.distance, 111.2, accuracy: 0.2)
    }

    // Mean Earth radius 6371 km: 1 degree of latitude = 111.195 km.
    func testGPSEarthRadius() {
        let r = gpsReading(myLat: 10, myLon: 0, myAcc: 5, peerLat: 11, peerLon: 0, peerAcc: 5, at: now)
        XCTAssertEqual(r.distance, 111_195, accuracy: 20)
    }

    // |lat| > 90 from either phone is invalid input and must be discarded by fuse. Pairs sit next to the
    // pole so the bogus haversine is ~20 m (a far-off latitude would be dropped by the 100 km limit anyway).
    func testGPSLatitudeOutOfRangeDiscarded() {
        for (a, b) in [(90.0001, 89.9999), (89.9999, 90.0001), (-90.0001, -89.9999), (-89.9999, -90.0001)] {
            let r = gpsReading(myLat: a, myLon: 0, myAcc: 5, peerLat: b, peerLon: 0, peerAcc: 5, at: now)
            XCTAssertNil(Fusion.fuse([r], now: now), "lat \(a)/\(b) must be discarded")
        }
    }

    // accuracy 0 is a valid (perfect) fix, not "invalid".
    func testGPSZeroAccuracyIsValid() {
        let r = gpsReading(myLat: 37, myLon: -122, myAcc: 0, peerLat: 37, peerLon: -122, peerAcc: 0, at: now)
        XCTAssertEqual(r.distance, 0, accuracy: 1e-9)
        XCTAssertEqual(r.sigma, 3, accuracy: 1e-12)
    }

    // closeContact needs 15 minutes, not 14.9.
    func testJustUnderFifteenIsNotCloseContact() {
        var t = ExposureTracker()
        t.advance(simSeconds: 14.95 * 60, contacts: [(1, .contagious)])
        XCTAssertEqual(t.level, .nearby)
        t.advance(simSeconds: 0.05 * 60, contacts: [(1, .contagious)])
        XCTAssertEqual(t.level, .closeContact)
    }

    // Beacon magic is the ASCII bytes "FLU1" on the air (other phones/versions depend on it).
    func testBeaconMagicIsFLU1() {
        XCTAssertEqual(BLEBeacon.magic, Array("FLU1".utf8))
        let raw: [UInt8] = [0x46, 0x4C, 0x55, 0x31, 0x02] + Array(repeating: 0xAB, count: 11)
        let d = BLEBeacon.decode(CBUUID(data: Data(raw)))
        XCTAssertEqual(d?.risk, .contagious)
        XCTAssertEqual(d?.id, String(repeating: "ab", count: 11))
    }

    // Wire format: kind names are part of the protocol between phones; pin the JSON.
    func testWireKindAndKeyNames() throws {
        let gps = try JSONDecoder().decode(Wire.self, from: Data(#"{"kind":"gps","lat":1.5,"lon":2.5,"acc":3.5}"#.utf8))
        XCTAssertEqual(gps.kind, .gps); XCTAssertEqual(gps.lat, 1.5); XCTAssertEqual(gps.lon, 2.5); XCTAssertEqual(gps.acc, 3.5)
        let tok = try JSONDecoder().decode(Wire.self, from: Data(#"{"kind":"uwbToken","token":"AAH+/w=="}"#.utf8))
        XCTAssertEqual(tok.kind, .uwbToken); XCTAssertEqual(tok.token, Data([0, 1, 254, 255]))
        let hello = try JSONDecoder().decode(Wire.self, from: Data(#"{"kind":"hello","id":"ab","risk":1}"#.utf8))
        XCTAssertEqual(hello.kind, .hello); XCTAssertEqual(hello.id, "ab"); XCTAssertEqual(hello.risk, .possible)
        for (w, name) in [(Wire(kind: .hello), "hello"), (Wire(kind: .uwbToken), "uwbToken"), (Wire(kind: .gps), "gps")] {
            let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(w)) as? [String: Any]
            XCTAssertEqual(obj?["kind"] as? String, name)
        }
    }
}
