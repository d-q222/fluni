import Foundation

/// The campus model's P(sick) per agent over sim time: a reader for `model/out/<run_id>/p_sick.csv`
/// (contract: docs/p-sick-format.md). Pure, no SwiftUI or networking.
///
/// Clock: `t_iso` is naive sim time (no zone). It is read as if it were UTC, only so it maps to a plain
/// number of seconds; the zone never matters because every time in the feed and every query uses the same
/// mapping. A value with a zone suffix (Z, +hh:mm) is rejected, since it would silently shift the clock.
///
/// Strictness: a wrong header throws. A bad row (wrong column count, bad time, p not a finite number in
/// [0,1], or time earlier than that agent's previous row) is skipped and counted in `rejected`.
/// A repeated timestamp for an agent replaces the earlier value (the later row wins).
struct PSickFeed: Equatable {
    static let prior = 0.02
    static let header = "agent_id,t_iso,p_sick"

    enum ParseError: Error, Equatable { case empty, badHeader(String) }

    /// Agent id to change points, ascending by time.
    private(set) var series: [String: [Point]] = [:]
    /// Rows skipped as malformed.
    private(set) var rejected = 0

    struct Point: Equatable { let t: Double; let p: Double }

    var agents: [String] { series.keys.sorted() }
    var rowCount: Int { series.values.reduce(0) { $0 + $1.count } }
    /// First and last change time across all agents, in sim seconds; nil if there are no rows.
    var timeRange: ClosedRange<Double>? {
        var lo = Double.infinity, hi = -Double.infinity
        for pts in series.values { if let f = pts.first, let l = pts.last { lo = min(lo, f.t); hi = max(hi, l.t) } }
        return lo <= hi ? lo...hi : nil
    }

    /// P for `agent` at sim time `t` (seconds, as from `simSeconds(iso:)`): the agent's last row with
    /// time <= t, else the prior (also for an unknown agent).
    func p(agent: String, at t: Double) -> Double {
        guard let pts = series[agent], !pts.isEmpty else { return Self.prior }
        var lo = 0, hi = pts.count   // first index with time > t
        while lo < hi {
            let mid = (lo + hi) / 2
            if pts[mid].t <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? Self.prior : pts[lo - 1].p
    }

    // MARK: Parsing

    static func parse(_ data: Data) throws -> PSickFeed {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        var feed = PSickFeed()
        var sawHeader = false
        var start = 0
        let n = bytes.count
        while start <= n {
            var end = start
            while end < n && bytes[end] != 0x0A { end += 1 }
            var lineEnd = end
            if lineEnd > start && bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            if lineEnd > start {
                if !sawHeader {
                    let h = String(decoding: bytes[start..<lineEnd], as: UTF8.self)
                    guard h == header else { throw ParseError.badHeader(h) }
                    sawHeader = true
                } else if !feed.addRow(bytes, start, lineEnd) {
                    feed.rejected += 1
                }
            }
            start = end + 1
        }
        guard sawHeader else { throw ParseError.empty }
        return feed
    }

    static func parse(_ text: String) throws -> PSickFeed { try parse(Data(text.utf8)) }

    private mutating func addRow(_ b: [UInt8], _ s: Int, _ e: Int) -> Bool {
        var commas: [Int] = []
        for i in s..<e where b[i] == 0x2C { commas.append(i) }
        guard commas.count == 2, commas[0] > s else { return false }
        let id = String(decoding: b[s..<commas[0]], as: UTF8.self)
        guard let t = Self.simSeconds(bytes: b[(commas[0] + 1)..<commas[1]]) else { return false }
        let pText = String(decoding: b[(commas[1] + 1)..<e], as: UTF8.self)
        guard let p = Double(pText), p.isFinite, p >= 0, p <= 1 else { return false }
        var pts = series[id] ?? []
        if let last = pts.last {
            if t < last.t { return false }
            if t == last.t { pts.removeLast() }
        }
        pts.append(Point(t: t, p: p))
        series[id] = pts
        return true
    }

    // MARK: Time

    /// "YYYY-MM-DDTHH:MM:SS" (optional fraction) as seconds since 1970, naive time read as UTC. Nil if malformed.
    static func simSeconds(iso: String) -> Double? { simSeconds(bytes: Array(iso.utf8)[...]) }

    private static func simSeconds(bytes b: ArraySlice<UInt8>) -> Double? {
        let a = Array(b)
        guard a.count >= 19, a[4] == 0x2D, a[7] == 0x2D, a[10] == 0x54, a[13] == 0x3A, a[16] == 0x3A else { return nil }
        func num(_ r: Range<Int>) -> Int? {
            var v = 0
            for i in r { guard a[i] >= 0x30, a[i] <= 0x39 else { return nil }; v = v * 10 + Int(a[i] - 0x30) }
            return v
        }
        guard let y = num(0..<4), let mo = num(5..<7), let d = num(8..<10),
              let h = num(11..<13), let mi = num(14..<16), let s = num(17..<19) else { return nil }
        guard (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, s < 60 else { return nil }
        var frac = 0.0
        if a.count > 19 {
            guard a[19] == 0x2E, a.count > 20 else { return nil }
            var scale = 0.1
            for i in 20..<a.count { guard a[i] >= 0x30, a[i] <= 0x39 else { return nil }; frac += Double(a[i] - 0x30) * scale; scale /= 10 }
        }
        // Days from civil (Howard Hinnant).
        let yy = mo <= 2 ? y - 1 : y
        let era = yy / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return Double(days * 86400 + h * 3600 + mi * 60 + s) + frac
    }

    /// Inverse of `simSeconds(iso:)`, for display: "2026-01-08 16:20".
    static func clockText(_ t: Double) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d MMM, HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}
