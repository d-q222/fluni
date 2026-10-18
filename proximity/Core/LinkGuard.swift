import Foundation

/// Pure checks for the peer link: what a message may contain, how fast a peer may send, when UWB's
/// extended-distance mode is on, and when a hello's ID is trusted. No radios, so it is unit-testable.
///
/// The link is unauthenticated by design (anonymous peers), so everything arriving on it is untrusted.
enum LinkGuard {
    /// Real messages are well under 1 KB (a hello is ~60 bytes, an archived NIDiscoveryToken a few
    /// hundred). Anything bigger is a bug or an attack and is dropped before JSON decoding.
    static let maxMessageBytes = 4096
    static let maxTokenBytes = 2048
    /// Linked phones per identity. Bounds MPC sessions and NISessions a flood of peers can make us hold.
    static let maxPeers = 8
    /// A hello's ID is used (UWB and GPS readings attributed to it) only if Bluetooth heard it this recently.
    static let bluetoothWindow: TimeInterval = 30

    /// The ephemeral ID as the beacon carries it: 11 bytes as exactly 22 lowercase hex digits.
    static func isEphemeralID(_ s: String) -> Bool {
        s.utf8.count == 22 && s.utf8.allSatisfy { (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0) }
    }

    /// Size cap, then decode, then per-kind validation. nil = drop the message.
    static func decode(_ data: Data) -> Wire? {
        guard data.count <= maxMessageBytes, let w = try? JSONDecoder().decode(Wire.self, from: data),
              isValid(w) else { return nil }
        return w
    }

    /// Each kind carries exactly its own fields. Unknown JSON keys are ignored by the decoder, which is
    /// what lets a newer build add optional fields (like `ext`) without breaking older ones.
    static func isValid(_ w: Wire) -> Bool {
        switch w.kind {
        case .hello:
            guard let id = w.id, isEphemeralID(id) else { return false }
            return w.token == nil && w.lat == nil && w.lon == nil && w.acc == nil
        case .uwbToken:
            guard let t = w.token, (1 ... maxTokenBytes).contains(t.count) else { return false }
            return w.id == nil && w.risk == nil && w.ext == nil && w.lat == nil && w.lon == nil && w.acc == nil
        case .gps:
            guard let lat = w.lat, let lon = w.lon, let acc = w.acc, lat.isFinite, lon.isFinite, acc.isFinite,
                  abs(lat) <= 90, abs(lon) <= 180, (0 ... 100_000).contains(acc) else { return false }
            return w.id == nil && w.risk == nil && w.ext == nil && w.token == nil
        }
    }

    /// UWB extended-distance mode only when both phones support it. A peer that doesn't send the field
    /// (an older build) counts as not supporting it. Symmetric, so both phones reach the same answer.
    static func useExtendedDistance(mine: Bool, theirs: Bool?) -> Bool { mine && theirs == true }

    /// True if Bluetooth heard the ID within the window (and the time isn't implausibly in the future).
    /// A link-only claim to an ID is never trusted: anyone nearby can open a link and say anything.
    static func isHeardOnBluetooth(lastHeard: Date?, now: Date) -> Bool {
        guard let t = lastHeard else { return false }
        let age = now.timeIntervalSince(t)
        return age >= -1 && age <= bluetoothWindow
    }
}

/// Token bucket: bursts up to `capacity` messages, refilling `perSecond`. Legitimate traffic is a
/// hello per connect/rotation, a token per (re)start and a GPS fix every 10 s (harness), so the
/// defaults leave ample room and only a flood is cut.
struct RateLimiter: Equatable {
    let capacity: Double
    let perSecond: Double
    private(set) var tokens: Double
    private var last: Date?

    init(capacity: Double = 20, perSecond: Double = 5) {
        self.capacity = capacity
        self.perSecond = perSecond
        tokens = capacity
    }

    /// Refill for the time since the last call (never for a clock that went backwards), then spend one.
    mutating func allow(now: Date) -> Bool {
        if let l = last {
            let dt = now.timeIntervalSince(l)
            if dt.isFinite, dt > 0 { tokens = min(capacity, tokens + dt * perSecond) }
        }
        last = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
