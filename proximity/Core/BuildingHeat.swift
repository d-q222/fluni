import Foundation

/// Building heat over sim time: a reader for `heatmap/out/<run_id>/building_heat.csv`
/// (contract: docs/building-heat-format.md). Pure, no SwiftUI, MapKit or networking.
///
/// Columns: t_iso,building_id,name,lat,lon,people,expected_sick,heat,high, optionally followed by
/// radius_m (metres; default 40 when the column or the value is absent). Totals only, never people.
///
/// Strictness: a wrong header throws. A bad row (wrong field count, bad time, bad number, heat outside
/// [0,1], high not 0/1, only one of lat/lon given, non-positive radius) is skipped and counted in `rejected`.
/// Empty lat and lon are allowed: the building has data but no geometry. A repeated (time, building) replaces
/// the earlier row. Rows may come in any order.
///
/// A building with no row in a snapshot has too few people (or none): that is NO DATA, never "safe".
struct BuildingHeat: Equatable {
    static let defaultRadius = 40.0
    static let header = "t_iso,building_id,name,lat,lon,people,expected_sick,heat,high"
    static let headerWithRadius = header + ",radius_m"

    enum ParseError: Error, Equatable { case empty, badHeader(String) }

    /// A live file bigger than this is refused (the bundled one is about 0.4 MB).
    static let maxLiveBytes = 5_000_000
    static let maxNameLength = 60

    /// Names come from files we don't control and end up in notifications: drop control, format (bidi,
    /// zero-width), line and paragraph separator characters, fold other whitespace to one space, cap the length.
    static func sanitizedName(_ raw: String) -> String {
        var out = ""
        var lastSpace = true  // also trims leading spaces
        for u in raw.unicodeScalars {
            let cat = u.properties.generalCategory
            if u == "\t" || u == "\n" || u == "\r" || cat == .spaceSeparator {
                if !lastSpace { out.unicodeScalars.append(" "); lastSpace = true }
                continue
            }
            switch cat {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: continue
            default: out.unicodeScalars.append(u); lastSpace = false
            }
        }
        let capped = String(out.prefix(maxNameLength))
        return capped.hasSuffix(" ") ? String(capped.dropLast()) : capped
    }

    /// Live data may only refresh heat, high, people and expected_sick of buildings the BUNDLED file already
    /// knows, within the bundled run's time range. Geometry, names and radii always come from the bundled file;
    /// unknown ids and out-of-range snapshots are dropped. Nil when nothing usable is left.
    static func merged(bundled: BuildingHeat, live: BuildingHeat) -> BuildingHeat? {
        guard let range = bundled.timeRange else { return nil }
        var out = bundled
        out.snapshots = live.snapshots.compactMap { snap in
            guard range ~= snap.t else { return nil }
            let known = snap.readings.filter { bundled.buildings[$0.key] != nil }
            return known.isEmpty ? nil : Snapshot(t: snap.t, readings: known)
        }
        out.rejected = live.rejected
        out.rowCount = live.rowCount
        return out.snapshots.isEmpty ? nil : out
    }

    struct Building: Equatable {
        let id: String
        let name: String
        /// Both nil when the file has no coordinates for it.
        let lat: Double?
        let lon: Double?
        let radius: Double
        var hasGeometry: Bool { lat != nil && lon != nil }
    }

    struct Reading: Equatable {
        let people: Double
        let expectedSick: Double
        let heat: Double
        let high: Bool
        var tier: Tier { BuildingHeat.tier(heat: heat, high: high) }
    }

    enum Tier: Int, Comparable {
        case low, elevated, high
        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    /// All rows with one `t_iso`.
    struct Snapshot: Equatable {
        let t: Double
        let readings: [String: Reading]
    }

    private(set) var buildings: [String: Building] = [:]
    /// Ascending by time.
    private(set) var snapshots: [Snapshot] = []
    private(set) var rejected = 0
    private(set) var rowCount = 0

    /// First and last snapshot time (sim seconds); nil if there are none.
    var timeRange: ClosedRange<Double>? {
        guard let f = snapshots.first, let l = snapshots.last else { return nil }
        return f.t...l.t
    }

    /// Buildings that can be placed on a map, by name.
    var mappable: [Building] { buildings.values.filter(\.hasGeometry).sorted { ($0.name, $0.id) < ($1.name, $1.id) } }

    // MARK: Queries

    /// The latest snapshot with time <= t. Nil before the first one.
    func state(at t: Double) -> Snapshot? {
        var lo = 0, hi = snapshots.count  // first index with time > t
        while lo < hi {
            let mid = (lo + hi) / 2
            if snapshots[mid].t <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : snapshots[lo - 1]
    }

    /// The reading for one building at t; nil means no data (not "safe").
    func reading(_ id: String, at t: Double) -> Reading? { state(at: t)?.readings[id] }

    /// The closest building with geometry, and its distance in metres.
    func nearest(lat: Double, lon: Double) -> (building: Building, meters: Double)? {
        var best: (Building, Double)?
        for b in buildings.values {
            guard let blat = b.lat, let blon = b.lon else { continue }
            let d = Self.haversine(lat, lon, blat, blon)
            if best == nil || d < best!.1 || (d == best!.1 && b.id < best!.0.id) { best = (b, d) }
        }
        return best.map { (building: $0.0, meters: $0.1) }
    }

    /// The building whose circle holds the point (distance <= radius); the closest one if several do.
    func inside(lat: Double, lon: Double) -> Building? {
        var best: (Building, Double)?
        for b in buildings.values {
            guard let blat = b.lat, let blon = b.lon else { continue }
            let d = Self.haversine(lat, lon, blat, blon)
            guard d <= b.radius else { continue }
            if best == nil || d < best!.1 || (d == best!.1 && b.id < best!.0.id) { best = (b, d) }
        }
        return best?.0
    }

    // MARK: Maths

    static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    /// `high` is the file's own flag (past the legend midpoint). Below it, a quarter of the way up the scale
    /// (halfway from sage to sun) is where "Elevated" starts.
    static func tier(heat: Double, high: Bool) -> Tier {
        high ? .high : (heat >= 0.25 ? .elevated : .low)
    }

    /// The map's blend: sage (0) to sun (0.5) to fire (1), as 0...255 components. Same stops as heatmap/app.js.
    static func rgb(heat: Double) -> (r: Double, g: Double, b: Double) {
        let sage = (172.0, 188.0, 139.0), sun = (235.0, 209.0, 135.0), fire = (219.0, 108.0, 89.0)
        let h = min(1, max(0, heat))
        let (a, b, f) = h < 0.5 ? (sage, sun, h / 0.5) : (sun, fire, (h - 0.5) / 0.5)
        return (a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
    }

    // MARK: Parsing

    static func parse(_ data: Data) throws -> BuildingHeat {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        var out = BuildingHeat()
        var withRadius = false
        var sawHeader = false
        var byTime: [Double: [String: Reading]] = [:]
        var start = 0
        let n = bytes.count
        while start <= n {
            var end = start
            while end < n && bytes[end] != 0x0A { end += 1 }
            var lineEnd = end
            if lineEnd > start && bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            if lineEnd > start {
                let line = String(decoding: bytes[start..<lineEnd], as: UTF8.self)
                if !sawHeader {
                    guard line == header || line == headerWithRadius else { throw ParseError.badHeader(line) }
                    withRadius = line == headerWithRadius
                    sawHeader = true
                } else if let row = parseRow(line, withRadius: withRadius) {
                    out.rowCount += 1
                    byTime[row.t, default: [:]][row.building.id] = row.reading
                    if let old = out.buildings[row.building.id] {
                        // Keep the first coordinates and radius seen; fill in what was missing.
                        if !old.hasGeometry && row.building.hasGeometry { out.buildings[old.id] = row.building }
                    } else {
                        out.buildings[row.building.id] = row.building
                    }
                } else {
                    out.rejected += 1
                }
            }
            start = end + 1
        }
        guard sawHeader else { throw ParseError.empty }
        out.snapshots = byTime.keys.sorted().map { Snapshot(t: $0, readings: byTime[$0]!) }
        return out
    }

    static func parse(_ text: String) throws -> BuildingHeat { try parse(Data(text.utf8)) }

    private static func parseRow(_ line: String, withRadius: Bool) -> (t: Double, building: Building, reading: Reading)? {
        guard let f = fields(line), f.count == (withRadius ? 10 : 9) else { return nil }
        guard let t = PSickFeed.simSeconds(iso: f[0]), !f[1].isEmpty else { return nil }
        func num(_ s: String) -> Double? { Double(s).flatMap { $0.isFinite ? $0 : nil } }
        var lat: Double?, lon: Double?
        if f[3].isEmpty != f[4].isEmpty { return nil }
        if !f[3].isEmpty {
            guard let a = num(f[3]), let o = num(f[4]), abs(a) <= 90, abs(o) <= 180 else { return nil }
            lat = a; lon = o
        }
        guard let people = num(f[5]), people >= 0, let sick = num(f[6]), sick >= 0,
              let heat = num(f[7]), heat >= 0, heat <= 1, f[8] == "0" || f[8] == "1" else { return nil }
        var radius = defaultRadius
        if withRadius, !f[9].isEmpty {
            guard let r = num(f[9]), r > 0 else { return nil }
            radius = r
        }
        var name = sanitizedName(f[2])
        if name.isEmpty { name = sanitizedName(f[1]) }
        if name.isEmpty { name = "Building" }
        return (t, Building(id: f[1], name: name, lat: lat, lon: lon, radius: radius),
                Reading(people: people, expectedSick: sick, heat: heat, high: f[8] == "1"))
    }

    /// RFC 4180 style: a field may be quoted, with "" for a quote and commas inside. Nil on a broken quote.
    private static func fields(_ line: String) -> [String]? {
        var out: [String] = []
        var cur = ""
        var quoted = false, justClosed = false
        var it = line.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = it.next()
        while let c = pending {
            pending = it.next()
            if quoted {
                if c == "\"" {
                    if pending == "\"" { cur.unicodeScalars.append(c); pending = it.next() } else { quoted = false; justClosed = true }
                } else { cur.unicodeScalars.append(c) }
            } else if c == "," {
                out.append(cur); cur = ""; justClosed = false
            } else if c == "\"" {
                guard cur.isEmpty, !justClosed else { return nil }
                quoted = true
            } else {
                guard !justClosed else { return nil }
                cur.unicodeScalars.append(c)
            }
        }
        guard !quoted else { return nil }
        out.append(cur)
        return out
    }
}
