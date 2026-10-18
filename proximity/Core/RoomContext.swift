import Foundation

/// The air this phone is in, for Rio's room term (RiskEstimate.Room): from this phone's own GPS fix and the
/// bundled FlUni/Resources/building_rooms.csv (tools/make_building_rooms.py: one representative room per sim
/// location, the row infer.js's doseModel reads for a contact in it). Pure; the fix never leaves the phone and
/// nothing here is broadcast.
///
/// Rules (conservative: an unsure answer is the default room, which is what infer.js uses for a contact
/// with no known room):
/// - no fix, a fix older than `maxFixAge`, or an unusable accuracy -> the default room;
/// - inside a location's circle (the nearest one, as BuildingHeat.inside) -> its room, or outdoors when the
///   location is an outdoor place (a quad, a plaza, the stadium);
/// - the whole accuracy circle outside every location's circle -> outdoors (infer.js `indoor = false`);
/// - otherwise (near an edge) -> the default room.
struct RoomContext: Equatable {
    static let maxFixAge: TimeInterval = 60
    static let header = "building_id,lat,lon,radius_m,room_id,volume_m3,ventilation_ach,room_type,indoor"

    struct Place: Equatable {
        let id: String
        let lat: Double
        let lon: Double
        let radius: Double
        let room: RiskEstimate.Room
    }

    private(set) var places: [Place] = []
    private(set) var rejected = 0

    var rooms: [String: RiskEstimate.Room] { Dictionary(places.map { ($0.id, $0.room) }, uniquingKeysWith: { a, _ in a }) }

    /// Rows with a bad coordinate or radius are skipped (counted in `rejected`). A missing or non-positive
    /// volume or ach falls back to the default room's, as infer.js's mkRoom does.
    static func parse(_ data: Data) -> RoomContext {
        var ctx = RoomContext()
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard lines.first.map(String.init)?.trimmingCharacters(in: .whitespaces) == header else { return ctx }
        for line in lines.dropFirst() {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 9, !f[0].isEmpty, let lat = Double(f[1]), let lon = Double(f[2]), let r = Double(f[3]),
                  lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180, r.isFinite, r > 0,
                  f[8] == "0" || f[8] == "1" else { ctx.rejected += 1; continue }
            let room: RiskEstimate.Room = f[8] == "1"
                ? .room(volume: Double(f[5]) ?? 0, ach: Double(f[6]) ?? 0, dorm: f[7].hasPrefix("dorm"))
                : .outdoors
            ctx.places.append(Place(id: f[0], lat: lat, lon: lon, radius: r, room: room))
        }
        return ctx
    }

    /// The room for a fix taken at `fixAt` with `accuracy` metres (CLLocation.horizontalAccuracy).
    func room(lat: Double, lon: Double, accuracy: Double, fixAt: Date, now: Date) -> RiskEstimate.Room {
        guard !places.isEmpty, lat.isFinite, lon.isFinite, accuracy.isFinite, accuracy >= 0 else { return .standard }
        let age = now.timeIntervalSince(fixAt)
        guard age >= -1, age <= Self.maxFixAge else { return .standard }
        var best: (place: Place, d: Double)?
        var clear = true  // accuracy circle outside every place
        for p in places {
            let d = BuildingHeat.haversine(lat, lon, p.lat, p.lon)
            if d - p.radius <= accuracy { clear = false }
            guard d <= p.radius else { continue }
            if best == nil || d < best!.d || (d == best!.d && p.id < best!.place.id) { best = (p, d) }
        }
        if let b = best { return b.place.room }
        return clear ? .outdoors : .standard
    }
}
