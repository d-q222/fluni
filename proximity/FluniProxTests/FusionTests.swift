import CoreBluetooth
import XCTest
@testable import FluniProx

final class FusionTests: XCTestCase {
    let now = Date()

    func testUWBDominatesWhenPresent() {
        let e = Fusion.fuse([
            Reading(source: .uwb, distance: 0.5, sigma: 0.1, at: now),
            Reading(source: .ble, distance: 3.0, sigma: 2.0, at: now),
            Reading(source: .gps, distance: 8.0, sigma: 7.0, at: now),
        ], now: now)!
        XCTAssertEqual(e.distance, 0.5, accuracy: 0.05)
        XCTAssertLessThan(e.sigma, 0.1)
        XCTAssertEqual(e.sources.count, 3)
    }

    func testStaleReadingsDropOut() {
        let e = Fusion.fuse([
            Reading(source: .uwb, distance: 0.5, sigma: 0.1, at: now.addingTimeInterval(-10)),
            Reading(source: .ble, distance: 2.5, sigma: 1.0, at: now),
        ], now: now)!
        XCTAssertEqual(e.sources, [.ble])
        XCTAssertEqual(e.distance, 2.5, accuracy: 1e-9)
        XCTAssertNil(Fusion.fuse([Reading(source: .gps, distance: 1, sigma: 5, at: now.addingTimeInterval(-60))], now: now))
    }

    func testCombiningCoarseSourcesTightensTheError() {
        let ble = Reading(source: .ble, distance: 1.5, sigma: 1.0, at: now)
        let gps = Reading(source: .gps, distance: 4.0, sigma: 5.0, at: now)
        let both = Fusion.fuse([ble, gps], now: now)!
        XCTAssertLessThan(both.sigma, ble.sigma)
        XCTAssertGreaterThan(both.distance, ble.distance)
        XCTAssertLessThan(both.distance, 2.0)
    }

    func testPClose() {
        XCTAssertGreaterThan(Fusion.pClose(Estimate(distance: 0.5, sigma: 0.1, sources: [.uwb])), 0.99)
        XCTAssertLessThan(Fusion.pClose(Estimate(distance: 5, sigma: 0.1, sources: [.uwb])), 0.01)
        XCTAssertEqual(Fusion.pClose(Estimate(distance: Fusion.closeDistance, sigma: 3, sources: [.gps])), 0.5, accuracy: 1e-9)
    }

    func testCoarseGPSAloneDoesNotCountTowardExposure() {
        let gpsOnly = Estimate(distance: 1.0, sigma: 25, sources: [.gps])
        XCTAssertGreaterThan(Fusion.pClose(gpsOnly), 0.4)        // the raw probability is still reported
        XCTAssertEqual(Fusion.exposurePClose(gpsOnly), 0)         // but it can't drive the alert
        let goodGPS = Estimate(distance: 1.0, sigma: 5, sources: [.gps])  // e.g. outdoors, sky view
        XCTAssertEqual(Fusion.exposurePClose(goodGPS), Fusion.pClose(goodGPS))
        let fused = Estimate(distance: 1.0, sigma: 25, sources: [.ble, .gps])
        XCTAssertEqual(Fusion.exposurePClose(fused), Fusion.pClose(fused))
    }

    func testGateHoldsForSeveralGPSReadings() {
        // Found by mutation review: the gate compared sources == [.gps], so two GPS readings slipped past it.
        XCTAssertEqual(Fusion.exposurePClose(Estimate(distance: 1, sigma: 25, sources: [.gps, .gps])), 0)
        XCTAssertFalse(Fusion.isCoarseGPSOnly(Estimate(distance: 1, sigma: 25, sources: [])))
    }

    func testBLECalibrationLearnsFromUWB() {
        // This phone pair actually reads -70 dBm at 1 m, not the -59 default.
        var cal = BLECalibrator()
        XCTAssertGreaterThan(cal.distance(rssi: -70), 3)  // uncalibrated: badly overestimates
        for d in [0.5, 1.0, 2.0, 1.0, 0.7, 1.5, 1.2, 0.9] {
            cal.observe(rssi: -70 - 20 * log10(d), trueDistance: d)
        }
        XCTAssertTrue(cal.isCalibrated)
        XCTAssertEqual(cal.txPower, -70, accuracy: 1)
        XCTAssertEqual(cal.distance(rssi: -70), 1.0, accuracy: 0.15)
    }

    func testBLEDistanceMonotonic() {
        let cal = BLECalibrator()
        XCTAssertLessThan(cal.distance(rssi: -50), cal.distance(rssi: -70))
        XCTAssertEqual(cal.distance(rssi: BLECalibrator.defaultTxPower), 1, accuracy: 1e-9)
    }

    func testGPSDistance() {
        // 0.0001° latitude ≈ 11.1 m
        let r = gpsReading(myLat: 37.4275, myLon: -122.1697, myAcc: 5,
                           peerLat: 37.4276, peerLon: -122.1697, peerAcc: 5, at: now)
        XCTAssertEqual(r.distance, 11.1, accuracy: 0.2)
        XCTAssertEqual(r.sigma, 50.0.squareRoot(), accuracy: 1e-9)
    }

    func testBeaconRoundTrip() {
        let id = Data((0..<11).map { UInt8($0 * 17) })
        let uuid = CBUUID(data: Data(BLEBeacon.magic + [2]) + id)
        let decoded = BLEBeacon.decode(uuid)
        XCTAssertEqual(decoded?.id, id.hex)
        XCTAssertEqual(decoded?.risk, .contagious)
        XCTAssertNil(BLEBeacon.decode(CBUUID(string: "180D")))
    }
}
