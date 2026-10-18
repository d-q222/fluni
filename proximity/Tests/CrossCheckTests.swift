import XCTest
@testable import FluniProx

/// Cross-checks the phone's maths and file readers against golden vectors made by the web team's JavaScript
/// (Fixtures/xcheck/make_golden.mjs -> golden.json; regenerate with `node make_golden.mjs`).
final class CrossCheckTests: XCTestCase {
    private static let dir = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/xcheck")

    private struct Golden: Decodable {
        struct Defaults: Decodable {
            let prior, selfReport, posTest, quantaPeak, breathingRate, nearFieldQ, deposition: Double
            let defaultRoomM2, ceilingM, defaultAch, outdoorRH, outdoorTempC, indoorTempC: Double
            let stageProfile: [Double]
        }
        struct Derived: Decodable {
            let indoorRH, virusDecay, roomVolume, roomLoss, roomFar, stage, btRangeM: Double
        }
        struct Decay: Decodable { let rh: Double; let decay: Double }
        struct RH: Decodable { let outdoorRH, outdoorTempC, indoorTempC, rh: Double }
        struct Dose: Decodable { let distance: Double; let seconds: Double; let dose: Double }
        struct Contact: Decodable { let distance: Double; let seconds: Double }
        struct Src: Decodable { let id: String; let s: Double; let contacts: [Contact] }
        struct Scenario: Decodable { let name: String; let sources: [Src]; let p: Double; let inferP: Double? }
        struct WebRef: Decodable { let agent: String; let atMin: Int; let sources: [Src]; let p: Double }
        struct Tier: Decodable { let p: Double; let tier: String; let advice: String }
        struct PQ: Decodable { let agent: String; let t_iso: String; let p: Double }
        struct Reading: Decodable { let people: Double; let expectedSick: Double; let heat: Double; let high: Bool }
        struct HQ: Decodable { let building: String; let t_iso: String; let reading: Reading? }
        let defaults: Defaults; let derived: Derived; let virusDecay: [Decay]; let indoorRH: [RH]
        let unitDose: [Dose]; let scenarios: [Scenario]; let webReference: WebRef
        let tiers: [Tier]; let psick: [PQ]; let heat: [HQ]
    }

    private func golden() throws -> Golden {
        try JSONDecoder().decode(Golden.self, from: Data(contentsOf: Self.dir.appendingPathComponent("golden.json")))
    }

    // MARK: Rio's dose and the phone's estimate (golden.json from the real model/infer.js)

    func testDefaultsAreInferJS() throws {
        let d = try golden().defaults
        XCTAssertEqual(RiskEstimate.prior, d.prior)
        XCTAssertEqual(RiskEstimate.selfReport, d.selfReport)
        XCTAssertEqual(RiskEstimate.posTest, d.posTest)
        XCTAssertEqual(RiskEstimate.quantaPeak, d.quantaPeak)
        XCTAssertEqual(RiskEstimate.breathingRate, d.breathingRate)
        XCTAssertEqual(RiskEstimate.nearFieldQ, d.nearFieldQ)
        XCTAssertEqual(RiskEstimate.deposition, d.deposition)
        XCTAssertEqual(RiskEstimate.defaultRoomM2, d.defaultRoomM2)
        XCTAssertEqual(RiskEstimate.ceilingM, d.ceilingM)
        XCTAssertEqual(RiskEstimate.defaultAch, d.defaultAch)
        XCTAssertEqual(RiskEstimate.outdoorRH, d.outdoorRH)
        XCTAssertEqual(RiskEstimate.outdoorTempC, d.outdoorTempC)
        XCTAssertEqual(RiskEstimate.indoorTempC, d.indoorTempC)
        XCTAssertEqual(RiskEstimate.stageProfile, d.stageProfile)
    }

    /// The derived constants come from Swift's ports of indoorRH / virusDecay / mkRoom, not hardcoded.
    func testDerivedConstantsMatchInferJS() throws {
        let g = try golden().derived
        let pairs: [(String, Double, Double)] = [
            ("indoorRH", RiskEstimate.roomRH, g.indoorRH), ("virusDecay", RiskEstimate.roomDecay, g.virusDecay),
            ("V", RiskEstimate.roomVolume, g.roomVolume), ("loss", RiskEstimate.roomLoss, g.roomLoss),
            ("1/(V loss)", RiskEstimate.roomFar, g.roomFar), ("stage", RiskEstimate.stage, g.stage),
            ("Bluetooth range", RiskEstimate.doseRange, g.btRangeM),
        ]
        var worst = 0.0
        for (name, swift, js) in pairs {
            XCTAssertEqual(swift, js, accuracy: 1e-9, name)
            worst = max(worst, abs(swift - js))
            print("CROSSCHECK \(name): Swift \(swift) JS \(js)")
        }
        print("CROSSCHECK max |Swift - JS| derived: \(worst)")
    }

    func testVirusDecayAndIndoorRHMatchInferJS() throws {
        let g = try golden()
        XCTAssertGreaterThanOrEqual(g.virusDecay.count, 10)
        for c in g.virusDecay { XCTAssertEqual(RiskEstimate.virusDecay(rh: c.rh), c.decay, accuracy: 1e-12, "rh \(c.rh)") }
        XCTAssertGreaterThanOrEqual(g.indoorRH.count, 6)
        for c in g.indoorRH {
            XCTAssertEqual(RiskEstimate.indoorRH(outdoorRH: c.outdoorRH, outdoorTempC: c.outdoorTempC, indoorTempC: c.indoorTempC),
                           c.rh, accuracy: 1e-12, "\(c.outdoorRH)% at \(c.outdoorTempC) C")
        }
    }

    func testUnitDoseMatchesInferJS() throws {
        let cases = try golden().unitDose
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        XCTAssertTrue(cases.contains { $0.distance < 0.3 }, "the 0.3 m floor must be exercised")
        var worst = 0.0
        for c in cases {
            let u = RiskEstimate.unitDose(distance: c.distance, seconds: c.seconds)
            XCTAssertEqual(u, c.dose, accuracy: 1e-9, "\(c.distance) m, \(c.seconds) s")
            XCTAssertEqual(u / c.dose, 1, accuracy: 1e-12, "relative, \(c.distance) m, \(c.seconds) s")
            XCTAssertEqual(RiskEstimate.contactDose(distance: c.distance, seconds: c.seconds), u, "within 10 m")
            worst = max(worst, abs(u - c.dose))
        }
        print("CROSSCHECK max |Swift - JS| unitDose: \(worst)")
    }

    /// Plays a source's contacts through ExposureTracker the way the phone does: 60 s ticks.
    private func track(_ sources: [Golden.Src], into t: inout ExposureTracker) {
        for src in sources {
            let risk: Risk = src.s == RiskEstimate.posTest ? .contagious : .possible
            XCTAssertEqual(RiskEstimate.evidence(risk), src.s)
            for c in src.contacts {
                var left = c.seconds
                while left > 0 {
                    let dt = min(60, left)
                    t.advance(simSeconds: dt, contacts: [(pClose: 1, risk: risk)], doses: [DosePeer(id: src.id, distance: c.distance)])
                    left -= dt
                }
            }
        }
    }

    /// p through the real tracker vs the JS phone rule, and vs the real inferRisk (stage set to the illness
    /// average, recovery off; make_golden.mjs checks the two JS numbers agree to 1e-12).
    func testScenariosThroughTheTrackerMatchInferJS() throws {
        let cases = try golden().scenarios
        XCTAssertGreaterThanOrEqual(cases.count, 50)
        XCTAssertTrue(cases.contains { $0.sources.count > 1 }, "multi-source")
        XCTAssertTrue(cases.contains { $0.sources.contains { $0.s == 0.6 } } && cases.contains { $0.sources.contains { $0.s == 0.97 } })
        var worst = 0.0
        for c in cases {
            var t = ExposureTracker()
            track(c.sources, into: &t)
            XCTAssertEqual(t.probability, c.p, accuracy: 1e-9, c.name)
            worst = max(worst, abs(t.probability - c.p))
            if let ip = c.inferP {
                XCTAssertEqual(t.probability, ip, accuracy: 1e-9, "vs inferRisk: \(c.name)")
                worst = max(worst, abs(t.probability - ip))
            }
        }
        print("CROSSCHECK max |Swift - JS| p: \(worst)")
        let none = try XCTUnwrap(cases.first { $0.sources.isEmpty })
        XCTAssertEqual(ExposureTracker().probability, none.p)
        XCTAssertEqual(none.p, RiskEstimate.prior)
    }

    /// The heat map team's reference (A0005 at ?at=5700 on the default run: "This phone's estimate: 3%").
    func testWebPhoneMockReferenceA0005() throws {
        let r = try golden().webReference
        XCTAssertEqual(r.agent, "A0005"); XCTAssertEqual(r.atMin, 5700)
        XCTAssertFalse(r.sources.isEmpty)
        var t = ExposureTracker()
        track(r.sources, into: &t)
        XCTAssertEqual(t.probability, r.p, accuracy: 1e-9)
        XCTAssertEqual(RiskEstimate.percentText(t.probability), "3%")
    }

    func testTiersAndAdviceMatchApp() throws {
        for t in try golden().tiers {
            let band: String
            switch RiskEstimate.band(t.p) { case .low: band = "low"; case .elevated: band = "elevated"; case .high: band = "high" }
            XCTAssertEqual(band, t.tier, "p \(t.p)")
            XCTAssertEqual(RiskEstimate.summary(t.p), t.advice, "p \(t.p)")
        }
    }

    private func load<T>(_ name: String, _ parse: (Data) throws -> T) throws -> T {
        try parse(Data(contentsOf: Self.dir.appendingPathComponent(name)))
    }

    func testPSickLookupMatchesPAt() throws {
        let feed = try load("p_sick.csv", PSickFeed.parse)
        XCTAssertEqual(feed.rejected, 0)
        let qs = try golden().psick
        XCTAssertGreaterThanOrEqual(qs.count, 20)
        for q in qs {
            let t = try XCTUnwrap(PSickFeed.simSeconds(iso: q.t_iso))
            XCTAssertEqual(feed.p(agent: q.agent, at: t), q.p, "\(q.agent) at \(q.t_iso)")
        }
    }

    func testBuildingHeatMatchesWebReading() throws {
        let heat = try load("building_heat.csv", BuildingHeat.parse)
        XCTAssertEqual(heat.rejected, 0)
        let qs = try golden().heat
        XCTAssertGreaterThanOrEqual(qs.count, 20)
        XCTAssertGreaterThanOrEqual(qs.filter { $0.reading == nil }.count, 3)
        for q in qs {
            let t = try XCTUnwrap(PSickFeed.simSeconds(iso: q.t_iso))
            let got = heat.reading(q.building, at: t)
            let label = "\(q.building) at \(q.t_iso)"
            if let want = q.reading {
                let g = try XCTUnwrap(got, label)
                XCTAssertEqual(g.people, want.people, label)
                XCTAssertEqual(g.expectedSick, want.expectedSick, label)
                XCTAssertEqual(g.heat, want.heat, label)
                XCTAssertEqual(g.high, want.high, label)
            } else {
                XCTAssertNil(got, label)
            }
        }
    }

    /// precompute.mjs:470 writes high = (unrounded heat >= 0.5) but heat itself rounded to 3 decimals, so a
    /// row printed "0.500" with high=0 is legitimate (true heat 0.4995...0.5). Every other row must obey it.
    func testHighFlagIsHeatAtLeastHalfInEveryRow() throws {
        let heat = try load("building_heat.csv", BuildingHeat.parse)
        var n = 0, bad = 0
        for s in heat.snapshots { for (_, r) in s.readings {
            n += 1
            if r.high != (r.heat >= 0.5), !(r.heat == 0.5 && !r.high) { bad += 1 }
            XCTAssertTrue((0...1).contains(r.heat))
        } }
        XCTAssertGreaterThan(n, 1000)
        XCTAssertEqual(bad, 0, "\(bad) of \(n) rows have high != (heat >= 0.5)")
    }
}
