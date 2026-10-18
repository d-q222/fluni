import Foundation

// Off-screen ranging (FlUni only): keeps distance samples flowing while a phone is locked or FlUni is in
// the background. Pure parts, so they are unit-testable; BLEBeacon drives them on its scan queue.
//
// Why: in the background iOS coalesces repeated adverts from one phone into a single discovery, and two
// locked iPhones rarely discover each other at all. A GATT connection that is already open survives the lock,
// though, and reading its RSSI is a CoreBluetooth event that wakes FlUni. So the scanner keeps a link open to
// up to `HeldLinks.maxHeld` nearby FlUni phones (opened while either phone is in the foreground, or after a
// background GATT read) and reads RSSI every `pollInterval`, re-reading the 16-byte payload every
// `rereadInterval` so ID rotations and status changes still show. Nothing new is exchanged: the payload is
// exactly the advert's (BeaconGATT).

/// The open links and what to do on each next. Keyed by CoreBluetooth's peripheral identifier.
struct HeldLinks: Equatable {
    /// Links held at once. Each costs both phones a little radio time; 4 covers a seminar table.
    static let maxHeld = 4
    /// RSSI reads per link while held. 2 s keeps a BLE reading fresh (`Source.ble.maxAge` 6 s) with 2-3
    /// samples in each 4 s median window, and wakes FlUni at most every 2 s per link.
    static let pollInterval: TimeInterval = 2
    /// Payload re-read: picks up the peer's 15-min ID rotation and a status change within 30 s, and lets
    /// a backgrounded peer rotate on time (a read wakes it, see BLEBeacon.onRead).
    static let rereadInterval: TimeInterval = 30
    /// A full table admits a new phone only if it is this much stronger than the weakest held one
    /// (about 2x closer under the log-distance model), so links go to the nearest phones without flapping.
    static let replaceMargin = 6.0
    /// Polled samples are ignored for an ID while adverts for it arrived within this long: in the
    /// foreground the advert path is denser and is what the BLE model was calibrated on.
    static let advertFresh: TimeInterval = 3
    /// After a held link drops, a pending connect waits this long for the phone to come back (iOS connect
    /// requests never time out on their own). Phones change Bluetooth address every ~15 min, after which the
    /// old one can't come back anyway.
    static let reconnectFor: TimeInterval = 600

    struct Link: Equatable {
        var id: String
        var risk: Risk
        var since: Date
        /// Last payload read.
        var readAt: Date
        /// Last RSSI or payload read issued (nil: none yet).
        var polledAt: Date?
        /// Latest RSSI seen for this phone (advert or connection); nil before the first.
        var rssi: Double?
    }

    private(set) var links: [UUID: Link] = [:]

    var count: Int { links.count }
    func link(_ p: UUID) -> Link? { links[p] }

    /// A payload read on `p` finished. Returns true when the link should stay open: it was already held
    /// (a re-read; ID and status are updated), or there is room and no other link already carries this ID
    /// (the same phone seen again under a new Bluetooth address). A changed ID is not linked to the old one
    /// anywhere in FlUni: the model sees a new ID, exactly as after a rotation heard over adverts.
    mutating func read(_ p: UUID, id: String, risk: Risk, rssi: Double?, at now: Date) -> Bool {
        if var l = links[p] {
            l.id = id
            l.risk = risk
            l.readAt = now
            if let rssi { l.rssi = rssi }
            links[p] = l
            return true
        }
        guard links.count < Self.maxHeld, !links.values.contains(where: { $0.id == id }) else { return false }
        links[p] = Link(id: id, risk: risk, since: now, readAt: now, rssi: rssi)
        return true
    }

    enum Admit: Equatable {
        case room
        /// Release this weaker link first.
        case replace(UUID)
        case full
    }

    /// Whether a phone heard at `rssi` (not yet held) may get a link. Ties go to the lowest identifier so
    /// the choice is deterministic.
    func admit(rssi: Double) -> Admit {
        guard links.count >= Self.maxHeld else { return .room }
        guard rssi.isFinite,
              let weakest = links.min(by: { a, b in
                  let ra = a.value.rssi ?? -.infinity, rb = b.value.rssi ?? -.infinity
                  return ra != rb ? ra < rb : a.key.uuidString < b.key.uuidString
              }) else { return .full }
        let weak = weakest.value.rssi ?? -.infinity
        return rssi >= weak + Self.replaceMargin ? .replace(weakest.key) : .full
    }

    enum Next: Equatable {
        case readRSSI
        case readPayload
        /// Nothing due yet; ask again after this many seconds.
        case wait(TimeInterval)
        /// Not held.
        case none
    }

    /// What to do on `p` now. A clock that stepped backwards past the last read or poll counts as due,
    /// so a link never stalls.
    func next(_ p: UUID, at now: Date) -> Next {
        guard let l = links[p] else { return .none }
        let sinceRead = now.timeIntervalSince(l.readAt)
        if sinceRead < 0 || sinceRead >= Self.rereadInterval { return .readPayload }
        if let t = l.polledAt {
            let since = now.timeIntervalSince(t)
            if since >= 0 && since < Self.pollInterval { return .wait(Self.pollInterval - since) }
        }
        return .readRSSI
    }

    /// A read (RSSI or payload) was issued on `p`.
    mutating func polled(_ p: UUID, at now: Date) { links[p]?.polledAt = now }

    /// Latest RSSI for `p` (from its adverts or the connection).
    mutating func heard(_ p: UUID, rssi: Double) {
        guard rssi.isFinite else { return }
        links[p]?.rssi = rssi
    }

    mutating func drop(_ p: UUID) { links[p] = nil }
    mutating func reset() { links.removeAll() }

    /// Whether a polled RSSI goes to the model: a real reading (CoreBluetooth reports 127 for "unavailable")
    /// and no advert for that ID in the last `advertFresh` seconds (a future advert time counts as stale).
    static func reports(rssi: Double, lastAdvert: Date?, now: Date) -> Bool {
        guard rssi.isFinite, rssi < 0, rssi > -110 else { return false }
        guard let a = lastAdvert else { return true }
        let age = now.timeIntervalSince(a)
        return !(age >= 0 && age < advertFresh)
    }
}

/// A Bluetooth distance resting on few RSSI samples gets a proportionally wider error, so P(within 6 ft)
/// stays honest when FlUni is off screen (no UWB, 2-3 polled samples per window instead of a dense advert
/// stream). Single BLE samples swing by about ±7 dB (field IQR 10 dB); a median of n independent samples has
/// an error shrinking about as 1/sqrt(n). The BLECalibrator sigmas were set on dense foreground windows, so a
/// window with at least `fullSamples` keeps them exactly and a thinner one is widened by sqrt(fullSamples / n).
enum OffScreenRSSI {
    /// One sample a second over the 4 s RSSIWindow. Foreground advert windows hold far more (up to 15).
    static let fullSamples = 4

    /// Multiplier on a BLE reading's sigma for a median of `samples` samples: 1 at `fullSamples` or more,
    /// sqrt(4 / n) below (2 for one sample). Zero or negative counts are treated as one.
    static func sigmaScale(samples: Int) -> Double {
        let n = max(samples, 1)
        return n >= fullSamples ? 1 : (Double(fullSamples) / Double(n)).squareRoot()
    }

    /// `r` with its sigma widened for `samples`; non-BLE readings are returned unchanged.
    static func widened(_ r: Reading, samples: Int) -> Reading {
        guard r.source == .ble else { return r }
        var w = r
        w.sigma = r.sigma * sigmaScale(samples: samples)
        return w
    }
}
