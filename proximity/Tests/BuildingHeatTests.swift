import XCTest
@testable import FluniProx

final class BuildingHeatTests: XCTestCase {
    private let h = BuildingHeat.header + "\n"
    private func t(_ s: String) -> Double { PSickFeed.simSeconds(iso: s)! }
    private func heat(_ body: String, header: String? = nil) throws -> BuildingHeat { try BuildingHeat.parse((header ?? h) + body) }

    func testQuotedCommaAndEscapedQuote() throws {
        let b = try heat("""
        2026-01-05T00:00:00,bld_1,"Gates, Computer Science",37.43,-122.17,100,5.00,0.250,0
        2026-01-05T00:00:00,bld_2,"The ""Old"" Union",37.42,-122.17,50,1.00,0.100,0

        """)
        XCTAssertEqual(b.rejected, 0)
        XCTAssertEqual(b.buildings["bld_1"]?.name, "Gates, Computer Science")
        XCTAssertEqual(b.buildings["bld_2"]?.name, "The \"Old\" Union")
        XCTAssertEqual(b.buildings["bld_1"]?.lat, 37.43)
    }

    func testBrokenQuoteIsRejectedNotCrash() throws {
        let b = try heat("2026-01-05T00:00:00,bld_1,\"Gates,37.43,-122.17,100,5.00,0.250,0\n2026-01-05T00:00:00,bld_2,X\"y,37.42,-122.17,50,1.00,0.100,0\n")
        XCTAssertEqual(b.rejected, 2)
        XCTAssertEqual(b.rowCount, 0)
    }

    func testCRLFAndBOM() throws {
        let text = "\u{FEFF}" + BuildingHeat.header + "\r\n2026-01-05T00:00:00,bld_1,Jerry,37.4,-122.1,450,9.00,0.235,0\r\n2026-01-05T00:15:00,bld_1,Jerry,37.4,-122.1,450,9.00,0.300,1\r\n"
        let b = try BuildingHeat.parse(text)
        XCTAssertEqual(b.rejected, 0)
        XCTAssertEqual(b.rowCount, 2)
        XCTAssertEqual(b.buildings["bld_1"]?.name, "Jerry")
        XCTAssertEqual(b.reading("bld_1", at: t("2026-01-05T00:15:00"))?.high, true)
    }

    func testBadHeaderAndEmpty() {
        XCTAssertThrowsError(try BuildingHeat.parse("a,b,c\n"))
        XCTAssertThrowsError(try BuildingHeat.parse(""))
        XCTAssertThrowsError(try BuildingHeat.parse("t_iso,building_id,name,lat,lon,people,expected_sick,heat\n"))
    }

    func testBadRowsCounted() throws {
        let b = try heat("""
        2026-01-05T00:00:00,bld_1,A,37.4,-122.1,10,1.00,0.5,1
        2026-01-05T00:00:00,bld_2,B,37.4,-122.1,10,1.00,1.5,1
        2026-01-05T00:00:00,bld_3,C,37.4,-122.1,10,1.00,0.5,2
        2026-01-05T00:00:00,bld_4,D,37.4,-122.1,10,1.00,0.5
        2026-01-05T00:00:00Z,bld_5,E,37.4,-122.1,10,1.00,0.5,0
        2026-01-05T00:00:00,bld_6,F,37.4,,10,1.00,0.5,0
        2026-01-05T00:00:00,bld_7,G,95,-122.1,10,1.00,0.5,0
        2026-01-05T00:00:00,bld_8,H,37.4,-122.1,x,1.00,0.5,0

        """)
        XCTAssertEqual(b.rowCount, 1)
        XCTAssertEqual(b.rejected, 7)
    }

    func testBeforeFirstSnapshotIsNoData() throws {
        let b = try heat("2026-01-05T10:00:00,bld_1,A,37.4,-122.1,100,5.00,0.250,0\n")
        XCTAssertNil(b.state(at: t("2026-01-05T09:59:59")))
        XCTAssertNil(b.reading("bld_1", at: t("2026-01-05T09:59:59")))
    }

    func testExactlyAtAndBetweenSnapshots() throws {
        let b = try heat("""
        2026-01-05T10:15:00,bld_1,A,37.4,-122.1,200,40.00,0.600,1
        2026-01-05T10:00:00,bld_1,A,37.4,-122.1,100,5.00,0.250,0

        """)
        XCTAssertEqual(b.snapshots.map(\.t), [t("2026-01-05T10:00:00"), t("2026-01-05T10:15:00")])
        XCTAssertEqual(b.reading("bld_1", at: t("2026-01-05T10:00:00")), .init(people: 100, expectedSick: 5, heat: 0.25, high: false))
        XCTAssertEqual(b.reading("bld_1", at: t("2026-01-05T10:14:59"))?.heat, 0.25)
        XCTAssertEqual(b.reading("bld_1", at: t("2026-01-05T10:15:00"))?.heat, 0.6)
        XCTAssertEqual(b.reading("bld_1", at: t("2030-01-01T00:00:00"))?.heat, 0.6)
    }

    func testMissingFromLatestSnapshotIsNoDataEvenIfEarlierPresent() throws {
        let b = try heat("""
        2026-01-05T10:00:00,bld_1,A,37.4,-122.1,100,5.00,0.250,0
        2026-01-05T10:00:00,bld_2,B,37.5,-122.1,100,5.00,0.250,0
        2026-01-05T10:15:00,bld_2,B,37.5,-122.1,100,6.00,0.300,0

        """)
        XCTAssertNotNil(b.reading("bld_1", at: t("2026-01-05T10:00:00")))
        XCTAssertNil(b.reading("bld_1", at: t("2026-01-05T10:20:00")))
        XCTAssertEqual(b.reading("bld_2", at: t("2026-01-05T10:20:00"))?.expectedSick, 6)
    }

    func testRadiusColumnAndDefault() throws {
        let b = try heat("2026-01-05T10:00:00,bld_1,A,37.4,-122.1,100,5.00,0.250,0,75.5\n2026-01-05T10:00:00,bld_2,B,37.5,-122.1,100,5.00,0.250,0,\n2026-01-05T10:00:00,bld_3,C,37.6,-122.1,100,5.00,0.250,0,-3\n",
                         header: BuildingHeat.headerWithRadius + "\n")
        XCTAssertEqual(b.buildings["bld_1"]?.radius, 75.5)
        XCTAssertEqual(b.buildings["bld_2"]?.radius, 40)
        XCTAssertNil(b.buildings["bld_3"])
        XCTAssertEqual(b.rejected, 1)
        XCTAssertEqual(try heat("2026-01-05T10:00:00,bld_1,A,37.4,-122.1,100,5.00,0.250,0\n").buildings["bld_1"]?.radius, 40)
    }

    func testEmptyLatLonHasDataButNoGeometry() throws {
        let b = try heat("2026-01-05T10:00:00,bld_1,Ghost,,,100,5.00,0.250,0\n2026-01-05T10:00:00,bld_2,B,37.4,-122.1,100,5.00,0.250,0\n")
        XCTAssertEqual(b.rejected, 0)
        XCTAssertNotNil(b.reading("bld_1", at: t("2026-01-05T10:00:00")))
        XCTAssertEqual(b.mappable.map(\.id), ["bld_2"])
        XCTAssertEqual(b.nearest(lat: 0, lon: 0)?.building.id, "bld_2")
        XCTAssertNil(b.inside(lat: 0, lon: 0))
    }

    func testRadiusBoundary() throws {
        let lat = 37.4210814, lon = -122.1736733
        let plat = 37.4214414, plon = -122.1736733  // roughly 40 m north
        let d = BuildingHeat.haversine(lat, lon, plat, plon)
        XCTAssertEqual(d, 40.03, accuracy: 0.05)
        func make(_ r: Double) throws -> BuildingHeat {
            try heat("2026-01-05T10:00:00,bld_1,A,\(lat),\(lon),100,5.00,0.250,0,\(r)\n", header: BuildingHeat.headerWithRadius + "\n")
        }
        XCTAssertEqual(try make(d).inside(lat: plat, lon: plon)?.id, "bld_1")             // exactly on the edge
        XCTAssertEqual(try make(d - 0.001).inside(lat: plat, lon: plon)?.id, nil)         // a hair outside
        XCTAssertEqual(try make(d + 0.001).inside(lat: plat, lon: plon)?.id, "bld_1")
        XCTAssertEqual(try make(d).nearest(lat: plat, lon: plon)?.meters ?? 0, d, accuracy: 1e-9)
    }

    func testInsidePicksClosestOfOverlapping() throws {
        let b = try heat("2026-01-05T10:00:00,far,Far,37.42100,-122.17,1,1.00,0.1,0\n2026-01-05T10:00:00,near,Near,37.42110,-122.17,1,1.00,0.1,0\n")
        XCTAssertEqual(b.inside(lat: 37.42108, lon: -122.17)?.id, "near")
    }

    func testColourEndpointsAndTiers() {
        XCTAssertTrue(BuildingHeat.rgb(heat: 0) == (172, 188, 139))
        XCTAssertTrue(BuildingHeat.rgb(heat: 0.5) == (235, 209, 135))
        XCTAssertTrue(BuildingHeat.rgb(heat: 1) == (219, 108, 89))
        XCTAssertEqual(BuildingHeat.tier(heat: 0.2, high: false), .low)
        XCTAssertEqual(BuildingHeat.tier(heat: 0.25, high: false), .elevated)
        XCTAssertEqual(BuildingHeat.tier(heat: 0.5, high: true), .high)
    }

    // MARK: The bundled file

    func testBundledFile() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FlUni/Resources/building_heat.csv")
        let b = try BuildingHeat.parse(try Data(contentsOf: url))
        XCTAssertEqual(b.rejected, 0)
        XCTAssertEqual(b.rowCount, 4507)
        XCTAssertEqual(b.snapshots.count, 1344)
        XCTAssertEqual(b.buildings.count, 32)
        XCTAssertEqual(b.mappable.count, 32)
        XCTAssertEqual(b.timeRange, t("2026-01-05T00:00:00")...t("2026-01-18T23:45:00"))
        // 2026-01-05T00:00:00,bld_232805707,Jerry,37.4210814,-122.1736733,450,9.00,0.235,0
        XCTAssertEqual(b.reading("bld_232805707", at: t("2026-01-05T00:00:00")), .init(people: 450, expectedSick: 9, heat: 0.235, high: false))
        XCTAssertEqual(b.buildings["bld_232805707"]?.name, "Jerry")
        XCTAssertEqual(b.buildings["bld_232805707"]?.lat, 37.4210814)
        XCTAssertEqual(b.buildings["bld_232805707"]?.radius, 40)
        // 2026-01-08T15:15:00,bld_232805707,Jerry,...,100,64.20,0.628,1
        XCTAssertEqual(b.reading("bld_232805707", at: t("2026-01-08T15:20:00")), .init(people: 100, expectedSick: 64.2, heat: 0.628, high: true))
        // 2026-01-08T15:15:00,bld_232841883,Encina Commons,...,250,38.50,0.487,0
        XCTAssertEqual(b.reading("bld_232841883", at: t("2026-01-08T15:15:00")), .init(people: 250, expectedSick: 38.5, heat: 0.487, high: false))
        // 2026-01-18T23:45:00,bld_1169967277,Breer Library,...,100,26.60,0.404,0
        XCTAssertEqual(b.reading("bld_1169967277", at: t("2026-01-19T08:00:00"))?.heat, 0.404)
        // Jerry is at the spot itself.
        XCTAssertEqual(b.inside(lat: 37.4210814, lon: -122.1736733)?.id, "bld_232805707")
    }
}
