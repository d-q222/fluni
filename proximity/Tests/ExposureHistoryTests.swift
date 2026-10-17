import XCTest
@testable import FluniProx

final class ExposureHistoryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Feeds `ticks` ticks of `dt` seconds with the same contacts; the clock is t0 + elapsed.
    private func feed(_ h: inout ExposureHistory, _ clock: inout Double, ticks: Int, dt: Double,
                      _ contacts: [(pClose: Double, risk: Risk)]) -> [ExposureEpisode] {
        var out: [ExposureEpisode] = []
        for _ in 0..<ticks {
            clock += dt
            out += h.advance(simSeconds: dt, contacts: contacts, at: t0.addingTimeInterval(clock))
        }
        return out
    }

    func testSimpleEpisodeExactValues() {
        var h = ExposureHistory(), c = 0.0
        XCTAssertEqual(feed(&h, &c, ticks: 18, dt: 60, [(1, .contagious)]), [])
        // 119 s of quiet is not enough; the episode is still open.
        XCTAssertEqual(feed(&h, &c, ticks: 119, dt: 1, []), [])
        XCTAssertNotNil(h.ongoing)
        // The 120th quiet second closes it.
        let done = feed(&h, &c, ticks: 1, dt: 1, [])
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done[0].start, t0)                              // first tick began at t0 (clock 60 minus dt 60)
        XCTAssertEqual(done[0].end, t0.addingTimeInterval(1080))       // 18 min, no 2-minute tail
        XCTAssertEqual(done[0].weightedMinutes, 18, accuracy: 1e-9)
        XCTAssertEqual(done[0].maxRisk, .contagious)
        XCTAssertTrue(done[0].isCloseContact)
        XCTAssertNil(h.ongoing)
    }

    func testGapOfExactly120SecondsEndsButOneSecondLessMerges() {
        // 119 s of quiet then risky again: ONE episode.
        var h = ExposureHistory(), c = 0.0
        _ = feed(&h, &c, ticks: 2, dt: 60, [(1, .contagious)])
        XCTAssertEqual(feed(&h, &c, ticks: 1, dt: 119, []), [])
        XCTAssertEqual(feed(&h, &c, ticks: 1, dt: 60, [(1, .contagious)]), [])
        let one = feed(&h, &c, ticks: 1, dt: 120, [])
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0].weightedMinutes, 3, accuracy: 1e-9)
        XCTAssertEqual(one[0].durationMinutes, 2 + 119.0 / 60 + 1, accuracy: 1e-9)

        // Exactly 120 s of quiet then risky again: TWO episodes.
        var g = ExposureHistory(); c = 0
        _ = feed(&g, &c, ticks: 2, dt: 60, [(1, .contagious)])
        let first = feed(&g, &c, ticks: 1, dt: 120, [])
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].weightedMinutes, 2, accuracy: 1e-9)
        _ = feed(&g, &c, ticks: 2, dt: 60, [(1, .contagious)])
        let second = feed(&g, &c, ticks: 1, dt: 120, [])
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].start, t0.addingTimeInterval(240))
    }

    func testSplitQuietTicksAccumulateToExactlyTwoMinutes() {
        var h = ExposureHistory(), c = 0.0
        _ = feed(&h, &c, ticks: 1, dt: 60, [(1, .contagious)])
        XCTAssertEqual(feed(&h, &c, ticks: 119, dt: 1, []), [])
        XCTAssertEqual(feed(&h, &c, ticks: 1, dt: 1, []).count, 1)
    }

    func testStartThresholdIsHalf() {
        var h = ExposureHistory(), c = 0.0
        _ = feed(&h, &c, ticks: 5, dt: 60, [(0.4999, .contagious)])
        XCTAssertNil(h.ongoing)
        _ = feed(&h, &c, ticks: 1, dt: 60, [(0.5, .contagious)])
        XCTAssertNotNil(h.ongoing)
        XCTAssertEqual(h.ongoing?.weightedMinutes ?? 0, 0.5, accuracy: 1e-9)  // 1 min x 0.5 x 1
    }

    func testHealthyPeerNeverStartsAnEpisode() {
        var h = ExposureHistory(), c = 0.0
        XCTAssertEqual(feed(&h, &c, ticks: 30, dt: 60, [(1, .none)]), [])
        XCTAssertNil(h.ongoing)
    }

    func testOverlappingPeersSumMinutesAndEpisodeStaysOpenAcrossHandover() {
        var h = ExposureHistory(), c = 0.0
        // A (contagious, p1) alone for 2 min, then A and B (possible, p0.8) for 2 min, then B alone 2 min.
        _ = feed(&h, &c, ticks: 2, dt: 60, [(1, .contagious)])
        _ = feed(&h, &c, ticks: 2, dt: 60, [(1, .contagious), (0.8, .possible)])
        _ = feed(&h, &c, ticks: 2, dt: 60, [(0.8, .possible)])
        let done = feed(&h, &c, ticks: 1, dt: 120, [])
        XCTAssertEqual(done.count, 1)
        // 2*1 + 2*(1 + 0.8*0.5) + 2*(0.8*0.5) = 2 + 2.8 + 0.8
        XCTAssertEqual(done[0].weightedMinutes, 5.6, accuracy: 1e-9)
        XCTAssertEqual(done[0].durationMinutes, 6, accuracy: 1e-9)
        XCTAssertEqual(done[0].maxRisk, .contagious)
    }

    func testRiskUpgradeMidEpisodeKeepsOneEpisodeWithMax() {
        var h = ExposureHistory(), c = 0.0
        _ = feed(&h, &c, ticks: 3, dt: 60, [(1, .possible)])
        XCTAssertEqual(h.ongoing?.maxRisk, .possible)
        _ = feed(&h, &c, ticks: 1, dt: 60, [(1, .contagious)])
        // Downgrade afterwards does not lower the max.
        _ = feed(&h, &c, ticks: 2, dt: 60, [(1, .possible)])
        let done = feed(&h, &c, ticks: 1, dt: 120, [])
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done[0].maxRisk, .contagious)
        XCTAssertEqual(done[0].weightedMinutes, 3 * 0.5 + 1 + 2 * 0.5, accuracy: 1e-9)  // 3.5
        XCTAssertFalse(done[0].isCloseContact)
    }

    func testRiskyPeerBelowThresholdDoesNotUpgradeMax() {
        var h = ExposureHistory(), c = 0.0
        _ = feed(&h, &c, ticks: 2, dt: 60, [(1, .possible), (0.4, .contagious)])
        XCTAssertEqual(h.ongoing?.maxRisk, .possible)
        // ...but its minutes still count: 2 * (0.5 + 0.4) = 1.8
        XCTAssertEqual(h.ongoing?.weightedMinutes ?? 0, 1.8, accuracy: 1e-9)
    }

    func testGarbageInput() {
        var h = ExposureHistory(), c = 0.0
        _ = feed(&h, &c, ticks: 1, dt: 60, [(1, .contagious)])
        // NaN / inf / negative dt count as zero: they neither add minutes nor end the episode.
        for bad in [Double.nan, .infinity, -.infinity, -500] {
            XCTAssertEqual(h.advance(simSeconds: bad, contacts: [], at: t0), [])
        }
        XCTAssertEqual(h.ongoing?.weightedMinutes ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(h.ongoing?.durationMinutes ?? -1, 1, accuracy: 1e-9)
        // Garbage pClose is ignored (NaN, inf) or clamped (>1, <0).
        XCTAssertEqual(h.advance(simSeconds: 60, contacts: [(.nan, .contagious), (.infinity, .contagious)], at: t0), [])
        XCTAssertEqual(h.ongoing?.weightedMinutes ?? -1, 1, accuracy: 1e-9)
        _ = h.advance(simSeconds: 60, contacts: [(7, .contagious), (-3, .contagious)], at: t0)
        XCTAssertEqual(h.ongoing?.weightedMinutes ?? -1, 2, accuracy: 1e-9)
        // Garbage only: nothing starts.
        var g = ExposureHistory()
        XCTAssertEqual(g.advance(simSeconds: .nan, contacts: [(.nan, .contagious)], at: t0), [])
        XCTAssertNil(g.ongoing)
        XCTAssertEqual(g.advance(simSeconds: -60, contacts: [(1, .contagious)], at: t0), [])
        XCTAssertNotNil(g.ongoing)                       // a risky tick opens one,
        XCTAssertEqual(g.finishOpen(), [])               // but zero minutes is not worth listing
    }

    func testFlickerUnderHalfAMinuteIsNotListed() {
        var h = ExposureHistory(), c = 0.0
        _ = feed(&h, &c, ticks: 29, dt: 1, [(1, .contagious)])
        XCTAssertEqual(feed(&h, &c, ticks: 1, dt: 120, []), [])
        _ = feed(&h, &c, ticks: 30, dt: 1, [(1, .contagious)])
        XCTAssertEqual(feed(&h, &c, ticks: 1, dt: 120, []).count, 1)
    }

    func testPruningBoundaryIsFourteenDaysInclusive() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func ep(endAgo: Double) -> ExposureEpisode {
            ExposureEpisode(start: now.addingTimeInterval(-endAgo - 600), end: now.addingTimeInterval(-endAgo),
                            weightedMinutes: 10, maxRisk: .contagious)
        }
        let day = 86400.0
        let kept = ExposureLog.pruned([ep(endAgo: 14 * day), ep(endAgo: 14 * day + 1), ep(endAgo: 13 * day), ep(endAgo: 0)], now: now)
        XCTAssertEqual(kept.map { now.timeIntervalSince($0.end) }, [14 * day, 13 * day, 0])  // oldest first
    }

    func testJSONRoundTripAndLiteral() throws {
        let a = ExposureEpisode(start: Date(timeIntervalSince1970: 1000), end: Date(timeIntervalSince1970: 2080),
                                weightedMinutes: 18.5, maxRisk: .contagious)
        let b = ExposureEpisode(start: Date(timeIntervalSince1970: 5000), end: Date(timeIntervalSince1970: 5300),
                                weightedMinutes: 2.25, maxRisk: .possible)
        let data = try ExposureLog.encode([a, b])
        XCTAssertEqual(ExposureLog.decode(data), [a, b])
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"[{"end":2080,"maxRisk":2,"start":1000,"weightedMinutes":18.5},{"end":5300,"maxRisk":1,"start":5000,"weightedMinutes":2.25}]"#)
        XCTAssertEqual(ExposureLog.decode(Data("not json".utf8)), [])
        XCTAssertEqual(ExposureLog.decode(Data()), [])
        XCTAssertEqual(ExposureLog.decode(Data("[]".utf8)), [])
    }

    func testCloseContactFlagAtFifteenWeightedMinutes() {
        func ep(_ m: Double) -> ExposureEpisode {
            ExposureEpisode(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1), weightedMinutes: m, maxRisk: .possible)
        }
        XCTAssertFalse(ep(14.99).isCloseContact)
        XCTAssertTrue(ep(15).isCloseContact)
    }
}
