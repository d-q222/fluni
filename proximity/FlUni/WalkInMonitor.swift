import Foundation
import CoreLocation
import Combine
import UserNotifications

/// Runs the walk-in warning (Core/WalkInWarning.swift) against the user's place and the building heat:
/// in the foreground from the app's own GPS fix (or the Demo's "Pretend I'm at\u{2026}"), and in the background
/// from BuildingWatcher's region entries. One WalkInWarning, so one cooldown, covers both.
@MainActor
final class WalkInMonitor: ObservableObject {
    static let shared = WalkInMonitor()

    /// The building to show the calm banner for on Today; nil when there is nothing to say.
    @Published private(set) var banner: BuildingHeat.Building?
    /// Demo only: building id to use instead of GPS (for the warning only).
    @Published var pretend: String? { didSet { evaluate() } }

    private weak var model: ProximityModel?
    private let clock = SimClock.shared
    private let store = BuildingHeatStore.shared
    private var warning: WalkInWarning
    private var bag: [AnyCancellable] = []
    private var pending = false
    private static let key = "walkInLastNotified"

    private init() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        warning = WalkInWarning(lastNotified: saved.mapValues { Date(timeIntervalSince1970: $0) })
    }

    /// Called once from Today. Everything that can change the answer schedules a re-check.
    func attach(_ model: ProximityModel) {
        guard self.model == nil else { return }
        self.model = model
        bag = [
            model.$lastFix.sink { [weak self] _ in self?.schedule() },
            model.$pauseState.sink { [weak self] p in self?.schedule(); BuildingWatcher.shared.sync(paused: p != nil) },  // fires before the value is stored
            clock.$simTime.sink { [weak self] _ in self?.schedule() },
            store.$heat.sink { [weak self] _ in self?.schedule(); BuildingWatcher.shared.sync() },
        ]
        schedule()
    }

    private var paused: Bool {
        if let model { return model.isPaused }
        return Self.pausedOnDisk
    }

    /// The saved pause, for a background launch before any model exists.
    static var pausedOnDisk: Bool {
        guard let data = UserDefaults.standard.data(forKey: "pauseState"),
              let p = try? JSONDecoder().decode(PauseState.self, from: data) else { return false }
        return !PauseSchedule.shouldResume(p, now: Date())
    }

    private func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in self?.pending = false; self?.evaluate() }  // values have settled
    }

    private func place() -> BuildingHeat.Building? {
        guard let heat = store.heat else { return nil }
        if let id = pretend { return heat.buildings[id] }
        guard let f = model?.lastFix, f.horizontalAccuracy >= 0 else { return nil }
        return heat.inside(lat: f.coordinate.latitude, lon: f.coordinate.longitude)
    }

    private func evaluate() {
        let b = place()
        let reading = b.flatMap { store.heat?.reading($0.id, at: clock.simTime) }
        let o = warning.evaluate(now: Date(), building: b, reading: reading, paused: paused)
        if banner != o.bannerBuilding { banner = o.bannerBuilding }
        if o.notify, let b = o.bannerBuilding { post(b); save() }
    }

    /// A background region entry for building `id`: same rules, same cooldown.
    func enteredRegion(_ id: String) {
        guard let b = store.heat?.buildings[id] else { return }
        PlaceLogStore.shared.entered(id)  // Today's timeline: the arrival, kept on this phone for 24 h
        let reading = store.heat?.reading(id, at: clock.simTime)
        let o = warning.evaluate(now: Date(), building: b, reading: reading, paused: paused)
        if o.notify { post(b); save() }
    }

    /// Forget every walk-in cooldown, in memory and on disk (Delete my data, and the Demo's "Reset warnings").
    func resetCooldowns() {
        warning.resetCooldowns()
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    /// Delete my data: cooldowns, the demo "pretend" place and the banner.
    func forgetEverything() {
        resetCooldowns()
        pretend = nil
        banner = nil
    }

    private func save() {
        UserDefaults.standard.set(warning.lastNotified.mapValues { $0.timeIntervalSince1970 }, forKey: Self.key)
    }

    /// Same source as Today's stay-home mode (ProximityModel.selfStatusOverridesRisk). A background region wake
    /// may run before Today attached the model, so fall back to the saved report, then to the status the model
    /// restores at launch: the report file has complete protection and can't be read while the phone is locked.
    private var isSick: Bool {
        if let model { return model.selfStatusOverridesRisk }
        if let url = SelfReportStore.defaultURL, let r = SelfReportFile.load(url: url, defaults: .standard) { return r.risk != .none }
        return (Risk(rawValue: UserDefaults.standard.integer(forKey: "savedStatus")) ?? .none) != .none
    }

    private func post(_ b: BuildingHeat.Building) {
        // SystemNotifier: honours the "Busy buildings" setting and keeps a background region wake alive while posting.
        SystemNotifier.shared.post(.building, content: AppNotifications.content(kind: .building, buildingID: b.id,
                                                                                buildingName: b.name, sick: isSick),
                                   identifier: "walkin-\(b.id)")
    }
}
