import CoreBluetooth
import XCTest
@testable import FluniProx

final class BeaconAndWireTests: XCTestCase {
    private let id11 = Data((0..<11).map { UInt8($0 + 1) })

    func testDecodeRejectsWrongMagic() {
        let uuid = CBUUID(data: Data([0x58, 0x4C, 0x55, 0x31, 1]) + id11)
        XCTAssertNil(BLEBeacon.decode(uuid))
    }

    func testDecodeRejectsShortUUIDs() {
        XCTAssertNil(BLEBeacon.decode(CBUUID(string: "180D")))      // 2 bytes
        XCTAssertNil(BLEBeacon.decode(CBUUID(data: Data(BLEBeacon.magic))))  // 4 bytes
    }

    func testDecodeRejectsInvalidRiskByte() {
        XCTAssertNil(BLEBeacon.decode(CBUUID(data: Data(BLEBeacon.magic + [7]) + id11)))
    }

    func testAllRisksRoundTrip() {
        for risk in Risk.allCases {
            let d = BLEBeacon.decode(CBUUID(data: Data(BLEBeacon.magic + [UInt8(risk.rawValue)]) + id11))
            XCTAssertEqual(d?.risk, risk)
            XCTAssertEqual(d?.id, id11.hex)
        }
    }

    func testHexLookupTable() {
        XCTAssertEqual(Data([0x00]).hex, "00")
        XCTAssertEqual(Data([0xff]).hex, "ff")
        XCTAssertEqual(Data([0x0a, 0xb0, 0x1f, 0xf0]).hex, "0ab01ff0")
        XCTAssertEqual(Data().hex, "")
    }

    private func roundTrip(_ w: Wire) throws -> Wire {
        try JSONDecoder().decode(Wire.self, from: JSONEncoder().encode(w))
    }

    func testWireHelloRoundTrip() throws {
        let w = try roundTrip(Wire(kind: .hello, id: "abcd", risk: .possible))
        XCTAssertEqual(w.kind, .hello)
        XCTAssertEqual(w.id, "abcd")
        XCTAssertEqual(w.risk, .possible)
        XCTAssertNil(w.token)
    }

    func testWireUWBTokenRoundTrip() throws {
        let bytes = Data([0, 1, 2, 254, 255])
        let w = try roundTrip(Wire(kind: .uwbToken, token: bytes))
        XCTAssertEqual(w.kind, .uwbToken)
        XCTAssertEqual(w.token, bytes)
    }

    func testWireGPSRoundTrip() throws {
        let w = try roundTrip(Wire(kind: .gps, lat: 37.4275, lon: -122.1697, acc: 6.5))
        XCTAssertEqual(w.kind, .gps)
        XCTAssertEqual(w.lat, 37.4275)
        XCTAssertEqual(w.lon, -122.1697)
        XCTAssertEqual(w.acc, 6.5)
    }

    func testRiskEncodesAsIntRawValue() throws {
        let data = try JSONEncoder().encode(Wire(kind: .hello, id: "x", risk: .contagious))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["risk"] as? Int, 2)
    }
}

final class ExposureGapTests: XCTestCase {
    func testSimultaneousContactsDoNotSum() {
        var t = ExposureTracker()
        t.advance(simSeconds: 450, contacts: [(1, .contagious), (1, .contagious)])
        XCTAssertEqual(t.minutes, 7.5, accuracy: 1e-9)
        XCTAssertEqual(t.level, .nearby)
    }

    func testMixedRisksWeighted() {
        var t = ExposureTracker()
        t.advance(simSeconds: 600, contacts: [(1, .contagious), (1, .possible), (1, .none)])
        XCTAssertEqual(t.minutes, 10, accuracy: 1e-9)  // the largest weight in range counts: max(10, 5, 0)
        XCTAssertEqual(t.level, .nearby)
    }

    func testLevelDropsToNoneWhenRiskyPeerLeaves() {
        var t = ExposureTracker()
        t.advance(simSeconds: 60, contacts: [(1, .contagious)])
        XCTAssertEqual(t.level, .nearby)
        t.advance(simSeconds: 1, contacts: [])
        XCTAssertEqual(t.level, .none)
        XCTAssertEqual(t.minutes, 1, accuracy: 1e-9)  // accumulated minutes are kept
    }
    func testNearbyHysteresis() {
        var t = ExposureTracker()
        func tick(_ p: Double) { t.advance(simSeconds: 1, contacts: [(p, .contagious)]) }
        tick(0.6); XCTAssertEqual(t.level, .nearby)
        tick(0.4); XCTAssertEqual(t.level, .nearby)   // stays until below 0.3
        tick(0.2); XCTAssertEqual(t.level, .none)
        tick(0.4); XCTAssertEqual(t.level, .none)     // re-entry needs 0.5
        XCTAssertLessThan(t.minutes, 15)
    }

}

final class FusionGapTests: XCTestCase {
    let now = Date()

    func testGPSOnlyFarButUncertain() {
        let e = Fusion.fuse([Reading(source: .gps, distance: 8, sigma: 14, at: now)], now: now)!
        let p = Fusion.pClose(e)
        XCTAssertGreaterThan(p, 0.2)
        XCTAssertLessThan(p, 0.5)
    }

    func testCalibratedBLEHasSmallerSigma() {
        var cal = BLECalibrator()
        let before = cal.reading(rssi: -65, at: now)
        for _ in 0..<5 { cal.observe(rssi: BLECalibrator.defaultTxPower, trueDistance: 1) }  // keeps txPower at -59
        XCTAssertTrue(cal.isCalibrated)
        let after = cal.reading(rssi: -65, at: now)
        XCTAssertEqual(after.distance, before.distance, accuracy: 1e-9)
        XCTAssertLessThan(after.sigma, before.sigma)
    }

    func testGPSSigmaFloor() {
        let r = gpsReading(myLat: 37, myLon: -122, myAcc: 0.5,
                           peerLat: 37, peerLon: -122, peerAcc: 0.5, at: now)
        XCTAssertEqual(r.sigma, 3, accuracy: 1e-12)
    }
}
