import XCTest
@testable import FluniProx

/// Bluetooth-only ranging: median RSSI window and the phone's learned txPower prior.
final class BLESmoothingTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testMedianOddAndEven() {
        var w = RSSIWindow()
        XCTAssertEqual(w.add(-50, at: t0), -50)
        XCTAssertEqual(w.add(-60, at: t0 + 0.5), -55)            // even: mean of the middle two
        XCTAssertEqual(w.add(-52, at: t0 + 1), -52)             // odd: middle of -60, -52, -50
    }

    func testOneSpikeIsIgnored() {
        var w = RSSIWindow()
        for i in 0..<4 { _ = w.add(-55, at: t0 + Double(i) * 0.2) }
        XCTAssertEqual(w.add(-90, at: t0 + 1), -55, "a single deep fade must not move the estimate")
        XCTAssertEqual(w.add(-30, at: t0 + 1.2), -55, "nor a single hot sample")
    }

    func testWindowIsFourSecondsInclusive() {
        var w = RSSIWindow()
        _ = w.add(-40, at: t0)
        XCTAssertEqual(w.add(-60, at: t0 + 4), -50, "a sample exactly 4 s old still counts")
        XCTAssertEqual(w.add(-60, at: t0 + 4.001), -60, "older than 4 s is dropped")
        XCTAssertEqual(w.samples.count, 2)
    }

    func testAtMostFifteenSamples() {
        var w = RSSIWindow()
        for i in 0..<20 { _ = w.add(Double(-40 - i), at: t0 + Double(i) * 0.01) }
        XCTAssertEqual(w.samples.count, 15)
        XCTAssertEqual(w.samples.first?.rssi, -45, "the oldest five were dropped")
        XCTAssertEqual(w.lastAt!.timeIntervalSince(t0), 0.19, accuracy: 1e-9)
    }

    func testPriorStartsAtDefaultAndLearnsInExactSteps() {
        var p = TxPowerPrior()
        XCTAssertEqual(p.txPower, -59)
        XCTAssertFalse(p.isLearned)
        p.learn(-71); XCTAssertEqual(p.txPower, -65, accuracy: 1e-9)   // alpha 0.5
        p.learn(-65); XCTAssertEqual(p.txPower, -65, accuracy: 1e-9)
        p.learn(-61); XCTAssertEqual(p.txPower, -63, accuracy: 1e-9)
        p.learn(-53); XCTAssertEqual(p.txPower, -61, accuracy: 1e-9)   // from the 4th pair: alpha 0.2
        XCTAssertEqual(p.pairs, 4)
        XCTAssertTrue(p.isLearned)
    }

    func testPriorRejectsImplausible() {
        var p = TxPowerPrior()
        for bad in [Double.nan, .infinity, -101, -19, 0] { p.learn(bad) }
        XCTAssertEqual(p.txPower, -59)
        XCTAssertEqual(p.pairs, 0)
    }

    func testPriorRoundTripsThroughJSON() throws {
        var p = TxPowerPrior(); p.learn(-67)
        let back = try JSONDecoder().decode(TxPowerPrior.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
        XCTAssertEqual(back.txPower, -63, accuracy: 1e-9)
    }

    func testCalibratorFromPrior() {
        let fresh = BLECalibrator.fromPrior(TxPowerPrior())
        XCTAssertEqual(fresh.txPower, -59, "nothing learned: generic default")
        XCTAssertEqual(fresh.reading(rssi: -59, at: t0).sigma, 0.7 * 1 + 0.3, accuracy: 1e-9)

        var p = TxPowerPrior(); p.learn(-69)                            // learned: -64
        let c = BLECalibrator.fromPrior(p)
        XCTAssertEqual(c.txPower, -64, accuracy: 1e-9)
        XCTAssertFalse(c.isCalibrated, "a prior is not a per-pair calibration")
        XCTAssertEqual(c.distance(rssi: -64), 1, accuracy: 1e-9)
        XCTAssertEqual(c.reading(rssi: -64, at: t0).sigma, 0.55 * 1 + 0.3, accuracy: 1e-9,
                       "between uncalibrated (0.7) and calibrated (0.4)")
    }
}
