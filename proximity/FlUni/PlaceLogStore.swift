import Foundation
import Combine

/// Keeps Today's place log (Core/PlaceLog.swift) on this phone: which campus building you were in and for how
/// long, as building names only, for 24 hours. A small JSON file in Application Support (encrypted while the
/// phone is locked). Never sent anywhere; "Delete my data" wipes it with the rest of Application Support.
///
/// Fed by the app's own GPS fix (the same one the walk-in warning uses, matched to a building on the phone)
/// and by background building entries from BuildingWatcher. Nearby phones are counted, never identified.
@MainActor
final class PlaceLogStore: ObservableObject {
    static let shared = PlaceLogStore()

    @Published private(set) var log = PlaceLog()

    private weak var model: ProximityModel?
    private var bag: [AnyCancellable] = []
    private var timer: Timer?
    private let url: URL?

    nonisolated static var defaultURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("place-log.json")
    }

    init(url: URL? = PlaceLogStore.defaultURL) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url) {
            log = PlaceLog.decode(data)
            log.prune(now: Date())
            log.expire(now: Date())
        }
        NotificationCenter.default.addObserver(forName: SelfReportStore.didDeleteData, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.forget() }
        }
    }

    /// Called once from Today: a fix or a change in nearby phones updates the visit; a minute timer ends a
    /// visit nobody confirmed and prunes the 24 hours.
    func attach(_ model: ProximityModel) {
        guard self.model == nil else { return }
        self.model = model
        bag = [
            model.$lastFix.sink { [weak self] _ in DispatchQueue.main.async { self?.sample() } },
            model.$peers.map(\.count).removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.sample() } },
        ]
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tidy() }
        }
    }

    /// The building this phone is in now, from the latest fix (nil outside every known building, or no fix).
    private func building() -> BuildingHeat.Building? {
        guard let model, !model.isPaused, let f = model.lastFix, f.horizontalAccuracy >= 0,
              Date().timeIntervalSince(f.timestamp) < PlaceLog.gap,
              let heat = BuildingHeatStore.shared.heat else { return nil }
        return heat.inside(lat: f.coordinate.latitude, lon: f.coordinate.longitude)
    }

    private func sample(now: Date = Date()) {
        guard let model, !model.isPaused, model.lastFix != nil else { return }
        let b = building()
        update { $0.observe(buildingID: b?.id, name: b?.name, phones: model.peers.count, at: now) }
    }

    /// A background building entry (BuildingWatcher via WalkInMonitor): the arrival is logged even though the
    /// app wasn't open. Its length is unknown until the app sees you there again.
    func entered(_ id: String, now: Date = Date()) {
        guard let b = BuildingHeatStore.shared.heat?.buildings[id] else { return }
        update { $0.observe(buildingID: b.id, name: b.name, phones: 0, at: now) }
    }

    private func tidy(now: Date = Date()) {
        update { $0.expire(now: now); $0.prune(now: now) }
        sample(now: now)
    }

    private func update(_ change: (inout PlaceLog) -> Void) {
        var l = log
        change(&l)
        guard l != log else { return }
        log = l
        if let url, let data = try? PlaceLog.encode(l) { try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen]) }
    }

    func forget() {
        log = PlaceLog()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    #if DEBUG
    /// Preview hook only: feed an observation through the real rules.
    func debugObserve(_ id: String?, _ name: String?, phones: Int, at t: Date) {
        update { $0.observe(buildingID: id, name: name, phones: phones, at: t) }
    }
    #endif
}
