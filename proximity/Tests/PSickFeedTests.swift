import XCTest
@testable import FluniProx

final class PSickFeedTests: XCTestCase {
    private let h = "agent_id,t_iso,p_sick\n"
    private func t(_ s: String) -> Double { PSickFeed.simSeconds(iso: s)! }
    private func feed(_ body: String, header: String? = nil) throws -> PSickFeed { try PSickFeed.parse((header ?? h) + body) }

    func testEpochMapping() {
        XCTAssertEqual(t("1970-01-01T00:00:00"), 0)
        XCTAssertEqual(t("2026-01-08T00:00:00"), 1767830400)
        XCTAssertEqual(t("2024-02-29T12:00:30"), 1709208030)
        XCTAssertEqual(t("2026-01-08T00:00:00.5"), 1767830400.5)
        XCTAssertNil(PSickFeed.simSeconds(iso: "2026-01-08T00:00:00Z"))
        XCTAssertNil(PSickFeed.simSeconds(iso: "2026-13-08T00:00:00"))
        XCTAssertNil(PSickFeed.simSeconds(iso: "2026-01-08 00:00:00"))
    }

    func testBeforeFirstRowIsPrior() throws {
        let f = try feed("A1,2026-01-08T10:00:00,0.5\n")
        XCTAssertEqual(f.p(agent: "A1", at: t("2026-01-08T09:59:59")), 0.02)
        XCTAssertEqual(f.p(agent: "nobody", at: t("2030-01-01T00:00:00")), 0.02)
    }

    func testExactlyAtChangePointIsNewValue() throws {
        let f = try feed("A1,2026-01-08T10:00:00,0.5\nA1,2026-01-08T11:00:00,0.25\n")
        XCTAssertEqual(f.p(agent: "A1", at: t("2026-01-08T10:00:00")), 0.5)
        XCTAssertEqual(f.p(agent: "A1", at: t("2026-01-08T10:59:59")), 0.5)
        XCTAssertEqual(f.p(agent: "A1", at: t("2026-01-08T11:00:00")), 0.25)
        XCTAssertEqual(f.p(agent: "A1", at: t("2027-01-01T00:00:00")), 0.25)
    }

    func testAgentsAreIndependent() throws {
        let f = try feed("A1,2026-01-08T10:00:00,0.5\nA2,2026-01-08T09:00:00,0.1\n")
        XCTAssertEqual(f.agents, ["A1", "A2"])
        XCTAssertEqual(f.p(agent: "A1", at: t("2026-01-08T09:30:00")), 0.02)
        XCTAssertEqual(f.p(agent: "A2", at: t("2026-01-08T09:30:00")), 0.1)
        XCTAssertEqual(f.timeRange, t("2026-01-08T09:00:00")...t("2026-01-08T10:00:00"))
    }

    func testOutOfOrderTimesForAnAgentAreRejectedAndCounted() throws {
        let f = try feed("A1,2026-01-08T11:00:00,0.4\nA1,2026-01-08T10:00:00,0.9\nA1,2026-01-08T12:00:00,0.6\n")
        XCTAssertEqual(f.rejected, 1)
        XCTAssertEqual(f.rowCount, 2)
        XCTAssertEqual(f.p(agent: "A1", at: t("2026-01-08T10:30:00")), 0.02)
        XCTAssertEqual(f.p(agent: "A1", at: t("2026-01-08T11:30:00")), 0.4)
        XCTAssertEqual(f.p(agent: "A1", at: t("2026-01-08T12:00:00")), 0.6)
    }

    func testAgentsNeedNotBeContiguous() throws {
        let f = try feed("A1,2026-01-08T10:00:00,0.4\nA2,2026-01-08T10:00:00,0.1\nA1,2026-01-08T11:00:00,0.6\n")
        XCTAssertEqual(f.rejected, 0)
        XCTAssertEqual(f.p(agent: "A1", at: t("2026-01-08T11:00:00")), 0.6)
    }

    func testDuplicateTimestampLastRowWins() throws {
        let f = try feed("A1,2026-01-08T10:00:00,0.4\nA1,2026-01-08T10:00:00,0.7\n")
        XCTAssertEqual(f.rejected, 0)
        XCTAssertEqual(f.rowCount, 1)
        XCTAssertEqual(f.p(agent: "A1", at: t("2026-01-08T10:00:00")), 0.7)
    }

    func testBOMAndCRLF() throws {
        let text = "\u{FEFF}agent_id,t_iso,p_sick\r\nA1,2026-01-08T10:00:00,0.5\r\nA1,2026-01-08T11:00:00,0.25\r\n\r\n"
        let f = try PSickFeed.parse(text)
        XCTAssertEqual(f.rejected, 0)
        XCTAssertEqual(f.rowCount, 2)
        XCTAssertEqual(f.p(agent: "A1", at: t("2026-01-08T11:00:00")), 0.25)
    }

    func testBadHeaderThrows() {
        XCTAssertThrowsError(try PSickFeed.parse("agent,t_iso,p_sick\nA1,2026-01-08T10:00:00,0.5\n")) {
            XCTAssertEqual($0 as? PSickFeed.ParseError, .badHeader("agent,t_iso,p_sick"))
        }
        XCTAssertThrowsError(try PSickFeed.parse("agent_id,t_iso\nA1,2026-01-08T10:00:00\n"))
        XCTAssertThrowsError(try PSickFeed.parse("")) { XCTAssertEqual($0 as? PSickFeed.ParseError, .empty) }
    }

    func testBadRowsRejectedNotCrashing() throws {
        let body = """
        A1,2026-01-08T10:00:00,NaN
        A1,2026-01-08T10:00:00,inf
        A1,2026-01-08T10:00:00,1.0001
        A1,2026-01-08T10:00:00,-0.1
        A1,2026-01-08T10:00:00
        A1,2026-01-08T10:00:00,0.5,extra
        ,2026-01-08T10:00:00,0.5
        A1,yesterday,0.5
        A1,2026-01-08T10:00:00Z,0.5
        A1,2026-01-08T10:00:00,abc
        A1,2026-01-08T10:00:00,1
        A2,2026-01-08T10:00:00,0

        """
        let f = try feed(body)
        XCTAssertEqual(f.rejected, 10)
        XCTAssertEqual(f.rowCount, 2)
        XCTAssertEqual(f.p(agent: "A1", at: t("2026-01-08T10:00:00")), 1)
        XCTAssertEqual(f.p(agent: "A2", at: t("2026-01-08T10:00:00")), 0)
    }

    func testHeaderOnlyIsEmptyFeed() throws {
        let f = try feed("")
        XCTAssertEqual(f.agents, [])
        XCTAssertNil(f.timeRange)
    }

    func testLargeFileParsesUnderOneSecond() throws {
        var s = h
        s.reserveCapacity(60_000 * 40)
        for a in 0..<100 {
            for i in 0..<600 {
                let mins = i * 5
                s += String(format: "A%04d,2026-01-%02dT%02d:%02d:00,%.4f\n", a, 8 + mins / 1440, (mins / 60) % 24, mins % 60, Double(i) / 700)
            }
        }
        let start = Date()
        let f = try PSickFeed.parse(s)
        let dt = Date().timeIntervalSince(start)
        XCTAssertEqual(f.rowCount, 60_000)
        XCTAssertEqual(f.rejected, 0)
        XCTAssertEqual(f.agents.count, 100)
        XCTAssertLessThan(dt, 1.0)
        XCTAssertEqual(f.p(agent: "A0099", at: t("2026-01-08T00:00:00")), 0)
    }

    /// Values read by eye from the CSV: A0000 line 2 (16:20 = 0.1154, next 16:40), A0003 line 44
    /// (17:05 = 0.0545, next 17:15 = 0.0670), A0001 first row 20:15 = 0.0327, A0009 last row 0.3689.
    func testRealSampleFile() throws {
        // Our own copy of model/out/influenza_none_n10_d14_s2_f1f772f6/p_sick.csv (that run is being retired).
        let fixtures = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let data = try Data(contentsOf: fixtures.appendingPathComponent("p_sick_f1f772f6.csv"))
        let f = try PSickFeed.parse(data)
        XCTAssertEqual(f.rejected, 0)
        XCTAssertEqual(f.rowCount, 136)
        XCTAssertEqual(f.agents, (0..<10).map { String(format: "A%04d", $0) })
        XCTAssertEqual(f.p(agent: "A0000", at: t("2026-01-08T16:39:59")), 0.1154)
        XCTAssertEqual(f.p(agent: "A0000", at: t("2026-01-08T16:40:00")), 0.1257)
        XCTAssertEqual(f.p(agent: "A0003", at: t("2026-01-08T17:14:00")), 0.0545)
        XCTAssertEqual(f.p(agent: "A0001", at: t("2026-01-08T20:14:59")), 0.02)
        XCTAssertEqual(f.p(agent: "A0001", at: t("2026-01-08T20:15:00")), 0.0327)
        XCTAssertEqual(f.p(agent: "A0009", at: t("2026-02-01T00:00:00")), 0.3689)
    }
}
