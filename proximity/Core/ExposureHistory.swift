import Foundation

/// One stretch of continuous exposure to a risky phone. Stored on the device only.
/// No peer IDs and no distances: just when, how much, and the worst status seen.
struct ExposureEpisode: Codable, Equatable, Identifiable {
    var start: Date
    var end: Date
    /// Σ dt/60 × pClose × risk weight over the episode (the same minutes the 15-min rule counts).
    var weightedMinutes: Double
    /// The highest status among the phones that were probably within 6 ft.
    var maxRisk: Risk

    var id: Date { start }
    var durationMinutes: Double { end.timeIntervalSince(start) / 60 }
    /// Same threshold as the live alert.
    var isCloseContact: Bool { weightedMinutes >= ExposureTracker.closeContactMinutes - 1e-6 }
}

/// Groups the per-tick contacts into episodes. Pure: feed it the same inputs as
/// `ExposureTracker.advance` plus the tick's Date.
///
/// - A tick is "risky" when any peer with a status above `.none` has pClose >= 0.5.
/// - An episode starts on a risky tick and ends once 2 simulated minutes pass with no risky tick.
/// - While open, risky ticks add dt/60 × pClose × weight for every risky peer (peers overlap by
///   summing, like the tracker). Quiet ticks add nothing.
/// - An episode's `end` is the end of its last risky tick, so the 2-minute tail is not included.
/// - Episodes under `minListedMinutes` weighted minutes are dropped (flicker, not an exposure).
struct ExposureHistory: Equatable {
    static let startPClose = 0.5
    static let gapSeconds = 120.0
    static let minListedMinutes = 0.5

    struct Open: Codable, Equatable {
        var start: Date
        var weighted = 0.0
        var maxRisk = Risk.none
        var elapsed = 0.0      // simulated seconds since start
        var lastRisky = 0.0    // `elapsed` at the end of the last risky tick
        var quiet = 0.0        // simulated seconds since the last risky tick
    }
    private var open: Open?

    /// The episode in progress in a form that can be saved (e.g. when the app goes to the background).
    var openSnapshot: Open? { open }

    /// Continue a saved episode after a relaunch. The time the app was away counts as quiet time, so the same
    /// 2-minute gap rule decides whether it carries on (returns []) or is over (returns the finished episode).
    mutating func restore(_ saved: Open, savedAt: Date, now: Date) -> [ExposureEpisode] {
        var o = saved
        let away = max(0, now.timeIntervalSince(savedAt))
        o.elapsed += away
        o.quiet += away
        if o.quiet >= Self.gapSeconds - 1e-6 { return Self.finish(o) }
        open = o
        return []
    }

    /// The episode in progress, if any (not yet finished or filtered).
    var ongoing: ExposureEpisode? {
        open.map { ExposureEpisode(start: $0.start, end: $0.start.addingTimeInterval($0.lastRisky),
                                   weightedMinutes: $0.weighted, maxRisk: $0.maxRisk) }
    }

    /// `simSeconds` is clamped to [0, 24 h]; NaN/inf count as 0. A pClose that is NaN is ignored,
    /// others are clamped to [0, 1]. `now` is the time at the END of the tick.
    mutating func advance(simSeconds: Double, contacts: [(pClose: Double, risk: Risk)], at now: Date) -> [ExposureEpisode] {
        let dt = simSeconds.isFinite ? min(max(simSeconds, 0), ExposureTracker.window) : 0
        var added = 0.0
        var worst = Risk.none
        var risky = false
        for c in contacts where c.pClose.isFinite && c.risk != .none {
            let p = min(max(c.pClose, 0), 1)
            added += dt / 60 * p * c.risk.weight
            if p >= Self.startPClose {
                risky = true
                if c.risk.rawValue > worst.rawValue { worst = c.risk }
            }
        }
        if risky {
            var o = open ?? Open(start: now.addingTimeInterval(-dt))
            o.elapsed += dt
            o.lastRisky = o.elapsed
            o.quiet = 0
            o.weighted += added
            if worst.rawValue > o.maxRisk.rawValue { o.maxRisk = worst }
            open = o
            return []
        }
        guard var o = open else { return [] }
        o.elapsed += dt
        o.quiet += dt
        if o.quiet >= Self.gapSeconds - 1e-6 {
            open = nil
            return Self.finish(o)
        }
        open = o
        return []
    }

    /// Ends the episode in progress (e.g. on reset), returning it if it is worth listing.
    mutating func finishOpen() -> [ExposureEpisode] {
        guard let o = open else { return [] }
        open = nil
        return Self.finish(o)
    }

    private static func finish(_ o: Open) -> [ExposureEpisode] {
        guard o.weighted >= minListedMinutes - 1e-9 else { return [] }
        return [ExposureEpisode(start: o.start, end: o.start.addingTimeInterval(o.lastRisky),
                                weightedMinutes: o.weighted, maxRisk: o.maxRisk)]
    }
}

/// The saved list: 14 days, JSON.
enum ExposureLog {
    static let retention = 14 * 24 * 3600.0

    /// Keeps episodes that ended within the last 14 days (exactly 14 days old is kept), oldest first.
    static func pruned(_ episodes: [ExposureEpisode], now: Date) -> [ExposureEpisode] {
        episodes.filter { now.timeIntervalSince($0.end) <= retention }.sorted { $0.start < $1.start }
    }

    static func encode(_ episodes: [ExposureEpisode]) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return try e.encode(episodes)
    }

    /// Unreadable data gives an empty list rather than a crash.
    static func decode(_ data: Data) -> [ExposureEpisode] {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return (try? d.decode([ExposureEpisode].self, from: data)) ?? []
    }
}

/// Owns the history on the device: runs the episode logic, saves finished episodes to a small JSON
/// file in Application Support, prunes old ones. Nothing leaves the phone.
final class ExposureHistoryStore: ObservableObject {
    @Published private(set) var episodes: [ExposureEpisode] = []
    @Published private(set) var ongoing: ExposureEpisode?
    private var history = ExposureHistory()
    private let url: URL?
    private var openURL: URL? { url?.deletingLastPathComponent().appendingPathComponent("exposure-open.json") }

    init(url: URL? = ExposureHistoryStore.defaultURL, now: Date = Date()) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url) {
            episodes = ExposureLog.pruned(ExposureLog.decode(data), now: now)
        }
        restoreOpen(now: now)
    }

    private struct SavedOpen: Codable { var open: ExposureHistory.Open; var savedAt: Date }

    /// None on a test launch, so a test run neither reads nor writes the owner's history.
    static var defaultURL: URL? {
        guard !LaunchMode.isTestLaunch else { return nil }
        return try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true).appendingPathComponent("exposure-history.json")
    }

    func record(simSeconds: Double, contacts: [(pClose: Double, risk: Risk)], at now: Date = Date()) {
        let done = history.advance(simSeconds: simSeconds, contacts: contacts, at: now)
        if !done.isEmpty { add(done, now: now) }
        if history.ongoing != ongoing { ongoing = history.ongoing }
        keepOpenSaved(now: now)
    }

    /// How often the episode in progress is saved while it runs.
    static let openSaveInterval = 15.0
    private var lastOpenSave: Date?

    /// The app is going to the background and may be killed: save the episode in progress instead of closing it,
    /// so a relaunch continues it. It is finished only when the 2-minute gap rule says so (see `restore`).
    func saveOngoing(now: Date = Date()) {
        guard let openURL else { return }
        guard let o = history.openSnapshot else { removeOpenFile(); return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let data = try? enc.encode(SavedOpen(open: o, savedAt: now)) {
            try? data.write(to: openURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            lastOpenSave = now
        }
    }

    /// A kill in the foreground (Xcode reinstalling, a crash, a UI test relaunching) never reaches `saveOngoing`,
    /// and the bug hunt lost the newest Recent contacts entry that way. So the open episode is also saved while it
    /// runs, at most every `openSaveInterval`; and the saved copy goes as soon as it finishes, so a relaunch can't
    /// restore an episode that is already in the log and list it twice.
    private func keepOpenSaved(now: Date) {
        if history.openSnapshot == nil {
            if lastOpenSave != nil { removeOpenFile() }
            return
        }
        if let last = lastOpenSave, abs(now.timeIntervalSince(last)) < Self.openSaveInterval { return }
        saveOngoing(now: now)
    }

    private func removeOpenFile() {
        if let openURL { try? FileManager.default.removeItem(at: openURL) }
        lastOpenSave = nil
    }

    private func restoreOpen(now: Date) {
        guard let openURL, let data = try? Data(contentsOf: openURL) else { return }
        try? FileManager.default.removeItem(at: openURL)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        guard let saved = try? dec.decode(SavedOpen.self, from: data) else { return }
        let done = history.restore(saved.open, savedAt: saved.savedAt, now: now)
        if !done.isEmpty { add(done, now: now) }
        ongoing = history.ongoing
    }

    /// Delete my data: forget everything in memory and on disk, so nothing can rewrite the file afterwards.
    func reset() {
        history = ExposureHistory()
        episodes = []
        ongoing = nil
        lastOpenSave = nil
        for u in [url, openURL] { if let u { try? FileManager.default.removeItem(at: u) } }
    }

    /// Closes the episode in progress (used by the reset button).
    func finishOngoing(now: Date = Date()) {
        let done = history.finishOpen()
        if !done.isEmpty { add(done, now: now) }
        ongoing = nil
        keepOpenSaved(now: now)  // drops the saved open copy
    }

    private func add(_ done: [ExposureEpisode], now: Date) {
        episodes = ExposureLog.pruned(episodes + done, now: now)
        if let url, let data = try? ExposureLog.encode(episodes) { try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen]) }
    }
}
