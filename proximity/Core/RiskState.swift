import Foundation

/// Everything the live risk number and its alerts depend on, saved so that a relaunch (crash, memory purge,
/// iOS ending FlUni in the background) carries on from the same estimate instead of the 2% prior. On this phone
/// only: a small JSON file in Application Support, never sent anywhere.
///
/// - `exposure`: the tracker (the running close-contact episode: weighted minutes and the time of its last weighted
///   moment; the 24 h per-minute buckets and per-ID dose with s and stage; alert level). A state saved before the
///   episode rule has no last-contact time; `ExposureTracker.migrated()` derives it on decode.
/// - `gate`: when each alert level was last notified, so a relaunch doesn't notify the same alert again.
/// The own-score broadcast is max(estimate, status floor); the status is saved elsewhere (UserDefaults), so the
/// restored estimate is all it needs.
struct RiskState: Codable, Equatable {
    static let currentVersion = 1
    var version = RiskState.currentVersion
    /// Wall-clock time of the save; the gap to the next launch moves the episode's 2 h clock and the 24 h dose window on.
    var savedAt: Date
    var exposure: ExposureTracker
    var gate: AlertGate

    /// A clock up to this far behind the save (a network time correction) counts as no gap; further back, the
    /// file is treated as from the future and dropped.
    static let clockSkewTolerance: TimeInterval = 60

    /// The saved state moved on to `now`: the tracker's clock advances by the real time since the save, so
    /// the minutes reset if 2 h or more have passed since the last weighted moment, and dose older than 24 h expires, and nothing is credited for that gap (no contacts: the app wasn't
    /// running). The alert level is re-derived the same way (a heads-up needs someone in range now; a close
    /// contact stays while the episode's 15 minutes stand). nil when `now` is before the save (beyond the skew).
    func resumed(at now: Date) -> (exposure: ExposureTracker, gate: AlertGate)? {
        let gap = now.timeIntervalSince(savedAt)
        guard gap.isFinite, gap >= -Self.clockSkewTolerance else { return nil }
        var e = exposure
        e.advance(simSeconds: max(gap, 0), contacts: [])
        return (e, gate)
    }
}

/// The file format: JSON, dates as Foundation's reference-date seconds (exact round trip).
enum RiskStateFile {
    static func encode(_ s: RiskState) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(s)
    }

    /// nil for anything that isn't a plausible saved state: unreadable JSON, another version, or a tracker
    /// whose numbers `advance` could not have produced.
    static func decode(_ data: Data) -> RiskState? {
        guard var s = try? JSONDecoder().decode(RiskState.self, from: data),
              s.version == RiskState.currentVersion, s.savedAt.timeIntervalSinceReferenceDate.isFinite,
              s.exposure.migrated().isPlausible else { return nil }
        s.exposure = s.exposure.migrated()
        return s
    }
}

/// Reads the saved state once at launch and writes it: on every alert-level change, when FlUni goes to the
/// background, and otherwise at most every `saveInterval` while what the user can see changes. Writes are atomic.
final class RiskStateStore {
    static let saveInterval: TimeInterval = 30
    static let fileName = "risk-state.json"

    let url: URL?
    /// Successful writes (tests check the throttle).
    private(set) var writes = 0
    private var lastSaved: ExposureTracker?
    private var lastSavedAt: Date?
    /// False after the file existed but couldn't be read (e.g. still protected): don't overwrite what we couldn't see.
    private var writable = true
    private let log: (String) -> Void

    init(url: URL? = RiskStateStore.defaultURL, log: @escaping (String) -> Void = { print("[fluni] \($0)") }) {
        self.url = url
        self.log = log
    }

    /// None on a test launch or in the unit-test host, so those never read or write the owner's risk. Debug builds
    /// can opt a test launch in with `-keepRiskState YES` (for checking a relaunch with `-demoPeer`).
    static var defaultURL: URL? {
        #if DEBUG
        let keep = UserDefaults.standard.bool(forKey: "keepRiskState")
        #else
        let keep = false
        #endif
        return location(isTestLaunch: LaunchMode.isTestLaunch, isUnitTestHost: LaunchMode.isUnitTestHost, keepOnTestLaunch: keep)
    }

    static func location(isTestLaunch: Bool, isUnitTestHost: Bool, keepOnTestLaunch: Bool = false,
                         fileManager fm: FileManager = .default) -> URL? {
        guard !isUnitTestHost, !isTestLaunch || keepOnTestLaunch else { return nil }
        return try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(fileName)
    }

    /// The state to start from at `now`, or nil to start fresh: no file, or one that is corrupt, from another
    /// version or from the future (each logged once, here).
    func load(now: Date = Date()) -> (exposure: ExposureTracker, gate: AlertGate)? {
        guard let url else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            writable = false
            log("risk state unreadable, starting fresh and not overwriting it: \(error.localizedDescription)")
            return nil
        }
        guard let saved = RiskStateFile.decode(data) else {
            log("risk state rejected (corrupt), starting fresh")
            return nil
        }
        guard let r = saved.resumed(at: now) else {
            log("risk state rejected (saved \(Int(saved.savedAt.timeIntervalSince(now))) s in the future), starting fresh")
            return nil
        }
        lastSaved = r.exposure
        lastSavedAt = now
        log("risk restored p=\(r.exposure.probability) level=\(r.exposure.level) gap=\(Int(now.timeIntervalSince(saved.savedAt))) s")
        return r
    }

    /// Writes now. A fresh state (nothing in the window, nothing notified) removes the file instead.
    func save(_ e: ExposureTracker, gate: AlertGate, now: Date = Date()) {
        guard let url, writable else { return }
        lastSaved = e
        lastSavedAt = now
        if e.isEmpty && gate == AlertGate() {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            let data = try RiskStateFile.encode(RiskState(savedAt: now, exposure: e, gate: gate))
            // Readable after the first unlock since boot: iOS may relaunch FlUni in the background while locked.
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            writes += 1
        } catch {
            log("risk state not saved: \(error.localizedDescription)")
        }
    }

    /// Per tick: writes on `levelChanged`, otherwise only if what a view shows changed since the last write and
    /// `saveInterval` has passed (no per-second disk writes).
    func saveIfDue(_ e: ExposureTracker, gate: AlertGate, now: Date = Date(), levelChanged: Bool) {
        if !levelChanged {
            guard lastSaved.map({ !e.showsSame(as: $0) }) ?? !e.isEmpty else { return }
            if let t = lastSavedAt {
                let since = now.timeIntervalSince(t)
                if since >= 0 && since < Self.saveInterval { return }
            }
        }
        save(e, gate: gate, now: now)
    }

    /// Reset / Delete my data: remove the file and forget what was last written.
    func clear() {
        writable = true
        lastSaved = nil
        lastSavedAt = nil
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}
