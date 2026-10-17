import XCTest
@testable import FluniProx

final class LiveDataHardeningTests: XCTestCase {
    private let h = BuildingHeat.header + "\n"
    private func heat(_ body: String) throws -> BuildingHeat { try BuildingHeat.parse(h + body) }

    // MARK: names

    func testSanitizedNameStripsControlAndNewlines() {
        XCTAssertEqual(BuildingHeat.sanitizedName("Gates\nHall\r\n\t"), "Gates Hall")
        XCTAssertEqual(BuildingHeat.sanitizedName("A\u{0000}B\u{0007}C\u{001B}[31m"), "ABC[31m")
        XCTAssertEqual(BuildingHeat.sanitizedName("  a   b  "), "a b")
        XCTAssertEqual(BuildingHeat.sanitizedName("x\u{2028}y\u{2029}z"), "xyz")
    }

    func testSanitizedNameStripsBidiAndZeroWidth() {
        XCTAssertEqual(BuildingHeat.sanitizedName("abc\u{202E}def"), "abcdef")   // right-to-left override
        XCTAssertEqual(BuildingHeat.sanitizedName("a\u{200B}b\u{FEFF}c\u{2066}d"), "abcd")
    }

    func testSanitizedNameCapsLengthWithoutTrailingSpace() {
        let long = String(repeating: "a", count: 500)
        XCTAssertEqual(BuildingHeat.sanitizedName(long).count, BuildingHeat.maxNameLength)
        let spaced = String(repeating: "a", count: 59) + " " + "bbbb"
        XCTAssertEqual(BuildingHeat.sanitizedName(spaced), String(repeating: "a", count: 59))
        XCTAssertEqual(BuildingHeat.sanitizedName("\u{202E}\n"), "")
    }

    func testParseUsesSanitizedNameAndFallsBackToId() throws {
        let b = try heat("""
        2026-01-05T00:00:00,b1,"Evil\u{202E}\nName",37.4,-122.1,100,5.00,0.250,0
        2026-01-05T00:00:00,b2,"\u{200B}\u{202E}",37.4,-122.1,100,5.00,0.250,0

        """)
        XCTAssertEqual(b.buildings["b1"]?.name, "Evil Name")
        XCTAssertEqual(b.buildings["b2"]?.name, "b2")
    }

    // MARK: merge

    private let bundledText = """
    2026-01-05T00:00:00,b1,Real Hall,37.40,-122.10,100,5.00,0.250,0
    2026-01-05T01:00:00,b1,Real Hall,37.40,-122.10,100,5.00,0.250,0
    2026-01-05T02:00:00,b1,Real Hall,37.40,-122.10,100,5.00,0.250,0

    """

    func testMergeKeepsBundledGeometryAndNames() throws {
        let bundled = try heat(bundledText)
        let live = try BuildingHeat.parse(BuildingHeat.headerWithRadius + "\n2026-01-05T01:00:00,b1,Hacked,10.0,10.0,200,9.00,0.900,1,5000\n")
        let m = try XCTUnwrap(BuildingHeat.merged(bundled: bundled, live: live))
        XCTAssertEqual(m.buildings, bundled.buildings)
        XCTAssertEqual(m.buildings["b1"]?.name, "Real Hall")
        XCTAssertEqual(m.buildings["b1"]?.radius, 40)
        let r = try XCTUnwrap(m.reading("b1", at: PSickFeed.simSeconds(iso: "2026-01-05T01:00:00")!))
        XCTAssertTrue(r.high); XCTAssertEqual(r.heat, 0.9); XCTAssertEqual(r.people, 200)
    }

    func testMergeDropsUnknownIdsAndOutOfRangeTimes() throws {
        let bundled = try heat(bundledText)
        let live = try heat("""
        2026-01-05T01:00:00,b1,Real Hall,,,100,1.00,0.500,0
        2026-01-05T01:00:00,evil,Phantom,37.4,-122.1,100,1.00,0.900,1
        2099-01-01T00:00:00,b1,Real Hall,,,100,1.00,0.900,1
        2000-01-01T00:00:00,b1,Real Hall,,,100,1.00,0.900,1

        """)
        let m = try XCTUnwrap(BuildingHeat.merged(bundled: bundled, live: live))
        XCTAssertNil(m.buildings["evil"])
        XCTAssertEqual(m.snapshots.count, 1)
        XCTAssertNil(m.snapshots[0].readings["evil"])
        let range = try XCTUnwrap(m.timeRange), br = try XCTUnwrap(bundled.timeRange)
        XCTAssertTrue(br.contains(range.lowerBound) && br.contains(range.upperBound))
    }

    func testMergeNilWhenNothingUsable() throws {
        let bundled = try heat(bundledText)
        let onlyUnknown = try heat("2026-01-05T01:00:00,evil,P,37.4,-122.1,100,1.00,0.900,1\n")
        XCTAssertNil(BuildingHeat.merged(bundled: bundled, live: onlyUnknown))
        let late = try heat("2099-01-01T00:00:00,b1,R,,,100,1.00,0.900,1\n")
        XCTAssertNil(BuildingHeat.merged(bundled: bundled, live: late))
        XCTAssertNil(BuildingHeat.merged(bundled: BuildingHeat(), live: bundled))
    }

    func testResponseCapIsFiveMegabytes() {
        XCTAssertEqual(BuildingHeat.maxLiveBytes, 5_000_000)
    }
}
