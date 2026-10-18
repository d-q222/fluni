import CoreBluetooth
import Foundation

/// The background-visible half of the beacon (FlUni only). Pure parts, so they are unit-testable.
///
/// iOS moves a backgrounded app's advertised service UUIDs to an "overflow" area that only a scanner
/// looking for that exact UUID can match. The per-ID payload UUID (FLU1, risk, 11-byte ID) can't be
/// looked for, so it is invisible in the background. FlUni therefore also advertises one fixed service
/// UUID and serves the same 16 payload bytes from a read-only GATT characteristic under it.
///
/// Privacy is unchanged: a reader gets exactly what the advert carries (the rotating random ID and the
/// 3-level status), just over a short connection instead of in the advert.
enum BeaconGATT {
    /// Fixed FlUni service UUID (random, picked once). Advertised next to the payload UUID.
    static let service = CBUUID(string: "142C3940-E33C-4D62-BE25-1C4A883EE402")
    /// Read-only characteristic holding the 16 payload bytes.
    static let characteristic = CBUUID(string: "2F02CED2-60A0-41AC-A335-07D1603177E4")

    /// The characteristic value: the same 16 bytes as the advertised payload UUID.
    static func value(id: Data, risk: Risk) -> Data? {
        BLEBeacon.payload(id: id, risk: risk).map(bytes)
    }

    /// An owned copy of a UUID's bytes. CBUUID.data can point into the CBUUID's own storage, so it reads
    /// garbage once the UUID is released (seen in tests: `payload(...)!.data` gave 16, 0, 0, ...).
    static func bytes(_ uuid: CBUUID) -> Data {
        withExtendedLifetime(uuid) { Data(Array(uuid.data)) }
    }

    /// Decodes a characteristic value. Anything that isn't exactly 16 bytes is rejected before CBUUID
    /// sees it (CBUUID(data:) throws an Objective-C exception on other lengths).
    static func decode(_ value: Data) -> (id: String, risk: Risk)? {
        guard value.count == 16 else { return nil }
        return BLEBeacon.decode(CBUUID(data: Data(value)))
    }

    /// The bytes to answer a read at `offset` with (a long read asks again from an offset).
    /// nil means the offset is past the end.
    static func slice(_ value: Data, offset: Int) -> Data? {
        guard offset >= 0, offset <= value.count else { return nil }
        return Data(value.dropFirst(offset))
    }
}

/// Decides when the scanner may connect to a background advertiser to read its payload.
/// Each connection costs both phones battery and airtime, so: one read per peripheral per
/// `minInterval`, and at most `maxConcurrent` connections at once.
struct ConnectLimiter: Equatable {
    static let minInterval: TimeInterval = 20
    static let maxConcurrent = 3

    private(set) var lastStart: [UUID: Date] = [:]
    private(set) var inFlight: Set<UUID> = []

    /// True (and records the attempt) when a connection to `peripheral` may start now.
    /// A clock that went backwards doesn't lock a peripheral out: the attempt is allowed and re-anchored.
    mutating func tryBegin(_ peripheral: UUID, at now: Date) -> Bool {
        guard !inFlight.contains(peripheral), inFlight.count < Self.maxConcurrent else { return false }
        if let last = lastStart[peripheral] {
            let since = now.timeIntervalSince(last)
            if since >= 0 && since < Self.minInterval { return false }
        }
        lastStart[peripheral] = now
        inFlight.insert(peripheral)
        // Peripheral identifiers change as phones rotate their Bluetooth address; drop stale ones.
        lastStart = lastStart.filter { abs(now.timeIntervalSince($0.value)) < Self.minInterval || inFlight.contains($0.key) }
        return true
    }

    /// The connection ended (read, failed, timed out or dropped). Safe to call twice.
    mutating func end(_ peripheral: UUID) {
        inFlight.remove(peripheral)
    }

    mutating func reset() { self = ConnectLimiter() }
}
