import XCTest
@testable import FluniProx

/// The UWB grace period: full weight for 3 s, usable to 6 s with sigma growing 1 m/s. Expected values
/// are literals from the spec, not constants read back from the code.
final class UWBGraceTests: XCTestCase {
    let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

    private func uwb(_ d: Double, sigma: Double = 0.1, age: Double) -> Reading {
        Reading(source: .uwb, distance: d, sigma: sigma, at: now.addingTimeInterval(-age))
    }

    func testSigmaUnchangedForThreeSeconds() {
        for age in [-1.0, 0, 0.1, 1, 2.999, 3] {
            XCTAssertEqual(Fusion.agedSigma(uwb(1, age: age), age: age), 0.1, accuracy: 1e-12, "age \(age)")
        }
    }

    func testSigmaGrowsOneMetrePerSecondAfterThree() {
        XCTAssertEqual(Fusion.agedSigma(uwb(1, age: 3.5), age: 3.5), 0.6, accuracy: 1e-9)
        XCTAssertEqual(Fusion.agedSigma(uwb(1, age: 4), age: 4), 1.1, accuracy: 1e-9)
        XCTAssertEqual(Fusion.agedSigma(uwb(1, age: 6), age: 6), 3.1, accuracy: 1e-9)
    }

    func testSigmaMonotoneInAge() {
        var last = 0.0
        for i in 0...600 {
            let age = Double(i) / 100
            let s = Fusion.agedSigma(uwb(1, age: age), age: age)
            XCTAssertGreaterThanOrEqual(s, last, "age \(age)")
            last = s
        }
    }

    func testOtherSourcesNeverAged() {
        for src in [Source.ble, .gps] {
            let r = Reading(source: src, distance: 2, sigma: 0.7, at: now)
            XCTAssertEqual(Fusion.agedSigma(r, age: 5.9), 0.7)
            XCTAssertEqual(Fusion.agedSigma(r, age: 19), 0.7)
        }
    }

    func testOneDroppedFrameDoesNotSnapToBluetooth() {
        // UWB 0.5 m, 3.2 s old (sigma 0.3); Bluetooth 1.5x off at 0.75 m, uncalibrated sigma 0.825.
        let ble = Reading(source: .ble, distance: 0.75, sigma: 0.825, at: now)
        let e = Fusion.fuse([uwb(0.5, age: 3.2), ble], now: now)!
        XCTAssertEqual(e.sources, [.uwb, .ble])
        XCTAssertLessThan(e.distance, 0.55, "UWB should still dominate just after the 3 s mark")
    }

    func testBluetoothTakesOverByEndOfGrace() {
        let ble = Reading(source: .ble, distance: 3, sigma: 0.5, at: now)
        let e = Fusion.fuse([uwb(0.5, age: 5.9), ble], now: now)!
        XCTAssertGreaterThan(e.distance, 2.8, "at 5.9 s (sigma 3.0) Bluetooth must dominate")
    }

    func testGoneAfterSixSeconds() {
        XCTAssertNotNil(Fusion.fuse([uwb(0.5, age: 6)], now: now))
        XCTAssertNil(Fusion.fuse([uwb(0.5, age: 6.001)], now: now))
        XCTAssertNil(Fusion.fuse([uwb(0.5, age: 1e9)], now: now))
    }

    func testGraceWidensUncertaintySoPCloseFalls() {
        let fresh = Fusion.pClose(Fusion.fuse([uwb(1.5, age: 0)], now: now)!)
        let aged = Fusion.pClose(Fusion.fuse([uwb(1.5, age: 5)], now: now)!)
        XCTAssertGreaterThan(fresh, 0.99)
        XCTAssertLessThan(aged, 0.6, "an old reading must not keep a near-certain close contact")
        XCTAssertGreaterThan(aged, 0.5, "1.5 m is still more likely within 6 ft than not")
    }

    func testAdversarialSigmaInputs() {
        // A zero-sigma reading stays finite and in range at every age.
        for age in stride(from: 0.0, through: 6, by: 0.25) {
            let e = Fusion.fuse([uwb(1, sigma: 0, age: age)], now: now)!
            XCTAssertTrue(e.distance.isFinite && e.sigma.isFinite, "age \(age)")
            XCTAssertEqual(e.distance, 1, accuracy: 1e-9)
        }
        // Garbage is still dropped, grace or not.
        XCTAssertNil(Fusion.fuse([uwb(.nan, age: 4)], now: now))
        XCTAssertNil(Fusion.fuse([uwb(1, sigma: .infinity, age: 4)], now: now))
        XCTAssertNil(Fusion.fuse([uwb(-1, age: 4)], now: now))
    }
}
