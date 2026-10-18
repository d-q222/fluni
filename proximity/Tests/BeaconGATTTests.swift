import CoreBluetooth
import XCTest
@testable import FluniProx

/// The GATT read must carry exactly the advert's 16 bytes, and the reader must not hammer peers.
final class BeaconGATTTests: XCTestCase {
    private let id11 = Data((0..<11).map { UInt8($0 + 0xA0) })
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testValueRoundTripsForEveryRisk() {
        for risk in Risk.allCases {
            let v = BeaconGATT.value(id: id11, risk: risk)
            XCTAssertEqual(v?.count, 16)
            let d = v.flatMap(BeaconGATT.decode)
            XCTAssertEqual(d?.id, id11.hex)
            XCTAssertEqual(d?.risk, risk)
        }
    }

    func testValueIsByteForByteTheAdvertPayload() {
        let advert = BLEBeacon.payload(id: id11, risk: .possible)!
        XCTAssertEqual(BeaconGATT.value(id: id11, risk: .possible), advert.data)
        XCTAssertEqual(Array(advert.data.prefix(5)), BLEBeacon.magic + [1])
    }

    func testWrongLengthIDsHaveNoPayload() {
        XCTAssertNil(BeaconGATT.value(id: Data(count: 10), risk: .none))
        XCTAssertNil(BeaconGATT.value(id: Data(count: 12), risk: .none))
    }

    func testDecodeRejectsBadValuesWithoutCrashing() {
        // CBUUID(data:) raises on these lengths, so decode must reject them first.
        for n in [0, 1, 2, 3, 4, 15, 17, 32] { XCTAssertNil(BeaconGATT.decode(Data(count: n)), "\(n) bytes") }
        var wrongMagic = BeaconGATT.value(id: id11, risk: .none)!
        wrongMagic[0] = 0x00
        XCTAssertNil(BeaconGATT.decode(wrongMagic))
        var badRisk = BeaconGATT.value(id: id11, risk: .none)!
        badRisk[4] = 9
        XCTAssertNil(BeaconGATT.decode(badRisk))
        // A slice (non-zero startIndex) still decodes.
        let padded = Data([0xFF]) + BeaconGATT.value(id: id11, risk: .contagious)!
        XCTAssertEqual(BeaconGATT.decode(padded.dropFirst())?.risk, .contagious)
    }

    func testReadAtOffset() {
        let v = BeaconGATT.value(id: id11, risk: .none)!
        XCTAssertEqual(BeaconGATT.slice(v, offset: 0), v)
        XCTAssertEqual(BeaconGATT.slice(v, offset: 5), Data(v.dropFirst(5)))
        XCTAssertEqual(BeaconGATT.slice(v, offset: 16), Data())
        XCTAssertNil(BeaconGATT.slice(v, offset: 17))
        XCTAssertNil(BeaconGATT.slice(v, offset: -1))
    }

    func testFixedUUIDsAreDistinctAndNotAPayload() {
        XCTAssertNotEqual(BeaconGATT.service, BeaconGATT.characteristic)
        XCTAssertNil(BLEBeacon.decode(BeaconGATT.service))
        XCTAssertNil(BLEBeacon.decode(BeaconGATT.characteristic))
    }

    // MARK: Connection rate limiter

    func testOneReadPerPeripheralPerInterval() {
        var l = ConnectLimiter()
        let p = UUID()
        XCTAssertTrue(l.tryBegin(p, at: t0))
        XCTAssertFalse(l.tryBegin(p, at: t0.addingTimeInterval(1)))  // still in flight
        l.end(p)
        XCTAssertFalse(l.tryBegin(p, at: t0.addingTimeInterval(19.9)))
        XCTAssertTrue(l.tryBegin(p, at: t0.addingTimeInterval(ConnectLimiter.minInterval)))
    }

    func testConcurrentConnectionsAreCapped() {
        var l = ConnectLimiter()
        let ps = (0 ..< ConnectLimiter.maxConcurrent + 1).map { _ in UUID() }
        for p in ps.dropLast() { XCTAssertTrue(l.tryBegin(p, at: t0)) }
        XCTAssertFalse(l.tryBegin(ps.last!, at: t0))
        l.end(ps[0])
        l.end(ps[0])  // ending twice is harmless
        XCTAssertTrue(l.tryBegin(ps.last!, at: t0))
        XCTAssertEqual(l.inFlight.count, ConnectLimiter.maxConcurrent)
    }

    func testBackwardsClockDoesNotLockAPeripheralOut() {
        var l = ConnectLimiter()
        let p = UUID()
        XCTAssertTrue(l.tryBegin(p, at: t0))
        l.end(p)
        XCTAssertTrue(l.tryBegin(p, at: t0.addingTimeInterval(-3600)))
    }

    func testStalePeripheralsArePruned() {
        var l = ConnectLimiter()
        for i in 0 ..< 50 {
            let p = UUID()
            XCTAssertTrue(l.tryBegin(p, at: t0.addingTimeInterval(Double(i) * 30)))
            l.end(p)
        }
        XCTAssertLessThanOrEqual(l.lastStart.count, 1)
        XCTAssertTrue(l.inFlight.isEmpty)
    }
}
