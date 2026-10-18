import XCTest
@testable import FluniProx

/// Adversarial tests for everything the peer link accepts. Literals from the spec, not code constants.
final class LinkGuardTests: XCTestCase {
    let now = Date(timeIntervalSinceReferenceDate: 3_000_000)
    let goodID = "0123456789abcdef012345"  // 22 lowercase hex

    private func json(_ obj: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: obj) }

    // MARK: hello validation

    func testEphemeralIDExactly22LowercaseHex() {
        XCTAssertTrue(LinkGuard.isEphemeralID(goodID))
        XCTAssertTrue(LinkGuard.isEphemeralID(Data((0..<11).map { UInt8($0 * 23) }).hex))
        for bad in ["", "abcd", String(goodID.dropLast()), goodID + "0", goodID.uppercased(),
                    "0123456789abcdef01234g", "0123456789abcdef01234 ", " 123456789abcdef012345",
                    "0123456789abcdef01234\n", "0123456789abcdef01234é", "０123456789abcdef01234",
                    "0x23456789abcdef012345", "-123456789abcdef012345", "0123456789abcdef01234\u{0}"] {
            XCTAssertFalse(LinkGuard.isEphemeralID(bad), "accepted \(bad.debugDescription)")
        }
    }

    func testHelloRules() {
        XCTAssertNotNil(LinkGuard.decode(json(["kind": "hello", "id": goodID, "risk": 1])))
        XCTAssertNotNil(LinkGuard.decode(json(["kind": "hello", "id": goodID])), "risk is optional")
        XCTAssertNotNil(LinkGuard.decode(json(["kind": "hello", "id": goodID, "risk": 0, "ext": true])))
        XCTAssertNil(LinkGuard.decode(json(["kind": "hello"])), "missing id")
        XCTAssertNil(LinkGuard.decode(json(["kind": "hello", "id": "abcd", "risk": 1])), "short id")
        XCTAssertNil(LinkGuard.decode(json(["kind": "hello", "id": goodID.uppercased()])), "uppercase id")
        XCTAssertNil(LinkGuard.decode(json(["kind": "hello", "id": goodID, "risk": 7])), "unknown risk")
        XCTAssertNil(LinkGuard.decode(json(["kind": "hello", "id": goodID, "token": "AAEC"])), "foreign field")
        XCTAssertNil(LinkGuard.decode(json(["kind": "hello", "id": goodID, "lat": 1, "lon": 1, "acc": 1])))
        XCTAssertNil(LinkGuard.decode(json(["kind": "hello", "id": 12345])), "id of wrong type")
        XCTAssertNil(LinkGuard.decode(json(["kind": "nonsense", "id": goodID])), "unknown kind")
    }

    func testTokenAndGPSRules() {
        let token = Data(repeating: 7, count: 500).base64EncodedString()
        XCTAssertNotNil(LinkGuard.decode(json(["kind": "uwbToken", "token": token])))
        XCTAssertNil(LinkGuard.decode(json(["kind": "uwbToken"])))
        XCTAssertNil(LinkGuard.decode(json(["kind": "uwbToken", "token": ""])), "empty token")
        XCTAssertNil(LinkGuard.decode(json(["kind": "uwbToken", "token": token, "id": goodID])), "foreign field")
        XCTAssertNil(LinkGuard.decode(json(["kind": "uwbToken", "token": token, "ext": true])), "ext only on hello")
        XCTAssertNotNil(LinkGuard.decode(json(["kind": "gps", "lat": 37.4, "lon": -122.1, "acc": 6])))
        for (lat, lon, acc) in [(91.0, 0.0, 5.0), (-90.5, 0, 5), (0, 180.5, 5), (0, 0, -1), (0, 0, 200_000)] {
            XCTAssertNil(LinkGuard.decode(json(["kind": "gps", "lat": lat, "lon": lon, "acc": acc])), "\(lat),\(lon),\(acc)")
        }
        XCTAssertNil(LinkGuard.decode(json(["kind": "gps", "lat": 1, "lon": 1])), "missing acc")
    }

    func testValidationOfConstructedNonFiniteGPS() {
        for bad in [Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(LinkGuard.isValid(Wire(kind: .gps, lat: bad, lon: 0, acc: 1)))
            XCTAssertFalse(LinkGuard.isValid(Wire(kind: .gps, lat: 0, lon: bad, acc: 1)))
            XCTAssertFalse(LinkGuard.isValid(Wire(kind: .gps, lat: 0, lon: 0, acc: bad)))
        }
    }

    func testSizeCapIs4KB() {
        // A valid hello padded with an unknown key (which the decoder would otherwise ignore).
        func padded(to n: Int) -> Data {
            let base = json(["kind": "hello", "id": goodID, "pad": ""])
            let pad = String(repeating: "x", count: n - base.count)
            return json(["kind": "hello", "id": goodID, "pad": pad])
        }
        XCTAssertEqual(padded(to: 4096).count, 4096)
        XCTAssertNotNil(LinkGuard.decode(padded(to: 4096)), "exactly 4096 bytes is allowed")
        XCTAssertNil(LinkGuard.decode(padded(to: 4097)), "4097 bytes must be dropped before decoding")
        XCTAssertNil(LinkGuard.decode(Data(repeating: 0x7b, count: 1_000_000)))
        XCTAssertNil(LinkGuard.decode(Data()))
        XCTAssertNil(LinkGuard.decode(Data([0xff, 0xfe, 0x00])))
    }

    func testOversizedTokenRejected() {
        XCTAssertTrue(LinkGuard.isValid(Wire(kind: .uwbToken, token: Data(repeating: 1, count: 2048))))
        XCTAssertFalse(LinkGuard.isValid(Wire(kind: .uwbToken, token: Data(repeating: 1, count: 2049))))
    }

    // MARK: compatibility of the optional ext field

    /// The Wire struct as shipped before `ext` existed.
    private struct OldWire: Codable {
        enum Kind: String, Codable { case hello, uwbToken, gps }
        var kind: Kind
        var id: String?
        var risk: Risk?
        var token: Data?
        var lat: Double?
        var lon: Double?
        var acc: Double?
    }

    func testOldPeerDecodesNewHello() throws {
        let data = try JSONEncoder().encode(Wire(kind: .hello, id: goodID, risk: .possible, ext: true))
        let old = try JSONDecoder().decode(OldWire.self, from: data)
        XCTAssertEqual(old.kind, .hello)
        XCTAssertEqual(old.id, goodID)
        XCTAssertEqual(old.risk, .possible)
    }

    func testNewPeerDecodesOldHelloAsNoExtendedSupport() throws {
        let data = try JSONEncoder().encode(OldWire(kind: .hello, id: goodID, risk: .contagious))
        let w = try XCTUnwrap(LinkGuard.decode(data))
        XCTAssertNil(w.ext)
        XCTAssertFalse(LinkGuard.useExtendedDistance(mine: true, theirs: w.ext))
    }

    func testExtOmittedFromJSONWhenNil() throws {
        let data = try JSONEncoder().encode(Wire(kind: .hello, id: goodID, risk: .none))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(obj["ext"], "nil ext must not appear on the wire")
    }

    // MARK: capability negotiation

    func testExtendedOnlyWhenBothSupport() {
        let cases: [(Bool, Bool?, Bool)] = [(true, true, true), (true, false, false), (true, nil, false),
                                            (false, true, false), (false, false, false), (false, nil, false)]
        for (mine, theirs, want) in cases {
            XCTAssertEqual(LinkGuard.useExtendedDistance(mine: mine, theirs: theirs), want, "\(mine) \(String(describing: theirs))")
        }
    }

    func testNegotiationIsSymmetric() {
        for a in [true, false] {
            for b in [true, false] {
                XCTAssertEqual(LinkGuard.useExtendedDistance(mine: a, theirs: b),
                               LinkGuard.useExtendedDistance(mine: b, theirs: a))
            }
        }
    }

    // MARK: Bluetooth-heard window (link claims need Bluetooth corroboration)

    func testHeardOnBluetoothWindowIs30s() {
        XCTAssertFalse(LinkGuard.isHeardOnBluetooth(lastHeard: nil, now: now), "never heard")
        XCTAssertTrue(LinkGuard.isHeardOnBluetooth(lastHeard: now, now: now))
        XCTAssertTrue(LinkGuard.isHeardOnBluetooth(lastHeard: now.addingTimeInterval(-30), now: now))
        XCTAssertFalse(LinkGuard.isHeardOnBluetooth(lastHeard: now.addingTimeInterval(-30.01), now: now))
        XCTAssertFalse(LinkGuard.isHeardOnBluetooth(lastHeard: .distantPast, now: now))
        XCTAssertTrue(LinkGuard.isHeardOnBluetooth(lastHeard: now.addingTimeInterval(1), now: now), "1 s clock jitter")
        XCTAssertFalse(LinkGuard.isHeardOnBluetooth(lastHeard: now.addingTimeInterval(5), now: now), "future")
        XCTAssertFalse(LinkGuard.isHeardOnBluetooth(lastHeard: .distantFuture, now: now))
    }

    // MARK: rate limiter

    func testBurstThenRefill() {
        var r = RateLimiter(capacity: 20, perSecond: 5)
        for i in 0..<20 { XCTAssertTrue(r.allow(now: now), "burst message \(i)") }
        XCTAssertFalse(r.allow(now: now), "21st in the same instant")
        XCTAssertFalse(r.allow(now: now.addingTimeInterval(0.1)), "0.1 s refills half a token")
        XCTAssertTrue(r.allow(now: now.addingTimeInterval(0.2)), "0.2 s total refills one")
        XCTAssertFalse(r.allow(now: now.addingTimeInterval(0.2)))
    }

    func testRefillCappedAtCapacity() {
        var r = RateLimiter(capacity: 20, perSecond: 5)
        for _ in 0..<20 { _ = r.allow(now: now) }
        let later = now.addingTimeInterval(3600)
        var allowed = 0
        for _ in 0..<100 where r.allow(now: later) { allowed += 1 }
        XCTAssertEqual(allowed, 20, "an hour of silence must not bank more than one burst")
    }

    func testFloodIsCutToTheRefillRate() {
        var r = RateLimiter(capacity: 20, perSecond: 5)
        var allowed = 0
        for i in 0..<10_000 where r.allow(now: now.addingTimeInterval(Double(i) * 0.001)) { allowed += 1 }  // 1000/s for 10 s
        XCTAssertLessThanOrEqual(allowed, 20 + 50 + 1)
        XCTAssertGreaterThanOrEqual(allowed, 20 + 49)
    }

    func testBackwardsClockMintsNothing() {
        var r = RateLimiter(capacity: 20, perSecond: 5)
        for _ in 0..<20 { _ = r.allow(now: now) }
        XCTAssertFalse(r.allow(now: now.addingTimeInterval(-1000)), "clock stepped back")
        XCTAssertFalse(r.allow(now: now.addingTimeInterval(-999.9)), "0.1 s after the step: half a token")
        XCTAssertTrue(r.allow(now: now.addingTimeInterval(-999.7)), "refills normally from the new anchor")
    }

    func testDegenerateTimes() {
        var r = RateLimiter(capacity: 2, perSecond: 1)
        XCTAssertTrue(r.allow(now: .distantPast))
        XCTAssertTrue(r.allow(now: .distantFuture))
        XCTAssertTrue(r.allow(now: .distantFuture))
        XCTAssertFalse(r.allow(now: .distantFuture))
        XCTAssertLessThanOrEqual(r.tokens, 2)
    }

    func testLegitTrafficNeverLimited() {
        // A hello, a token and a GPS fix every 2 s plus token re-sends: well under the budget.
        var r = RateLimiter()
        for i in 0..<600 {
            let t = now.addingTimeInterval(Double(i) * 0.5)
            XCTAssertTrue(r.allow(now: t), "message \(i)")
        }
    }

    func testPeerCapIs8() { XCTAssertEqual(LinkGuard.maxPeers, 8) }
}

final class PeerLinkBackoffTests: XCTestCase {
    // Spec: 0.5, 1, 2, 4, 4 ... s plus 0-0.5 s jitter; never negative, never above 4.5 s.
    func testBackoffSchedule() {
        for (failures, base) in [(0, 0.5), (1, 0.5), (2, 1.0), (3, 2.0), (4, 4.0), (5, 4.0), (50, 4.0), (Int.max, 4.0)] {
            for _ in 0..<50 {
                let b = PeerLink.backoff(failures)
                XCTAssertGreaterThanOrEqual(b, base, "failures \(failures)")
                XCTAssertLessThanOrEqual(b, base + 0.5, "failures \(failures)")
            }
        }
        XCTAssertGreaterThanOrEqual(PeerLink.backoff(-3), 0.5)
    }

    // A handshake that works takes 2.4-4.5 s in the field; the timeout must leave room for it.
    func testHandshakeTimeoutCoversFieldHandshakes() {
        let link = PeerLink()
        XCTAssertGreaterThanOrEqual(link.inviteTimeout, 5)
        XCTAssertLessThanOrEqual(link.inviteTimeout + PeerLink.watchdogSlack, 8, "a hung handshake blocks the phone; keep it short")
        XCTAssertGreaterThanOrEqual(PeerLink.minRestartGap, 5)
        XCTAssertGreaterThan(PeerLink.restartDelay, 0, "stop and start must not share a run-loop turn")
    }
}
