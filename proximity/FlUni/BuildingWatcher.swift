import Foundation
import CoreLocation

/// Background walk-in warnings without continuous GPS: with "Always" location it watches the nearest few
/// buildings as geofences (iOS wakes the app on entry) and re-picks them on significant location change.
/// The location is used on this phone only, to decide whether to warn. Nothing here is sent anywhere.
/// Off when location isn't "Always", or while detection is paused.
@MainActor
final class BuildingWatcher: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = BuildingWatcher()
    static let maxRegions = 20  // iOS allows 20 per app

    @Published private(set) var status: CLAuthorizationStatus
    private let manager = CLLocationManager()
    /// Region entries waiting for a fresh fix (building id -> when). Main actor only.
    private var pendingEntries: [String: Date] = [:]

    private override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.pausesLocationUpdatesAutomatically = true
    }

    /// Call at launch, also when iOS relaunches the app for a region entry.
    func start() { sync() }

    /// The second step of the two-step ask: only useful once While Using has been granted.
    func requestAlways() { manager.requestAlwaysAuthorization() }

    var canWatchInBackground: Bool { status == .authorizedAlways }

    /// Bring monitoring in line with permission and pause state. A pause subscriber fires before the new value
    /// is stored, so it passes the new state in `paused`; other callers read the saved one.
    func sync(paused: Bool? = nil) {
        status = manager.authorizationStatus
        let isPaused = paused ?? WalkInMonitor.pausedOnDisk
        guard status == .authorizedAlways, !isPaused, let heat = BuildingHeatStore.shared.heat else {
            pendingEntries = [:]
            manager.stopMonitoringSignificantLocationChanges()
            manager.stopMonitoringVisits()  // flu-offdetect
            for r in manager.monitoredRegions { manager.stopMonitoring(for: r) }
            return
        }
        manager.startMonitoringSignificantLocationChanges()
        // flu-offdetect: visits (arriving at or leaving a place) relaunch FlUni after it was terminated, like
        // significant changes, and FlUniApp restarts Bluetooth detection on any launch. That is the only way
        // detection comes back after a swipe-away without the student opening FlUni: iOS does not relaunch a
        // force-quit app for Bluetooth (TN3115). Visit data is not stored or used; it only wakes the app.
        manager.startMonitoringVisits()
        if let here = manager.location { pick(heat, near: here) } else { manager.requestLocation() }
    }

    private func pick(_ heat: BuildingHeat, near here: CLLocation) {
        let ranked = heat.mappable.sorted {
            here.distance(from: CLLocation(latitude: $0.lat!, longitude: $0.lon!)) < here.distance(from: CLLocation(latitude: $1.lat!, longitude: $1.lon!))
        }.prefix(Self.maxRegions)
        let ids = Set(ranked.map(\.id))
        let maxR = manager.maximumRegionMonitoringDistance
        // Regions left over from an older, smaller size are replaced.
        for r in manager.monitoredRegions {
            let want = ranked.first { $0.id == r.identifier }.map { GeofenceEntry.regionRadius(for: $0.radius, maximum: maxR) }
            if !ids.contains(r.identifier) || (r as? CLCircularRegion).map({ $0.radius != want }) == true { manager.stopMonitoring(for: r) }
        }
        let have = Set(manager.monitoredRegions.map(\.identifier))
        for b in ranked where !have.contains(b.id) {
            let r = CLCircularRegion(center: .init(latitude: b.lat!, longitude: b.lon!),
                                     radius: GeofenceEntry.regionRadius(for: b.radius, maximum: maxR), identifier: b.id)
            r.notifyOnEntry = true; r.notifyOnExit = false
            manager.startMonitoring(for: r)  // didDetermineState then reports if we are already inside
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in self.sync() }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard self.status == .authorizedAlways, !WalkInMonitor.pausedOnDisk,
                  let heat = BuildingHeatStore.shared.heat, let here = locations.last else { return }
            self.confirmEntries(heat, with: here)
            self.pick(heat, near: here)
        }
    }

    /// The region is bigger than the building: post only if the fresh fix is inside the real circle.
    private func confirmEntries(_ heat: BuildingHeat, with fix: CLLocation) {
        let now = Date()
        pendingEntries = GeofenceEntry.pruned(pendingEntries, now: now)
        guard !pendingEntries.isEmpty else { return }
        let ids = GeofenceEntry.confirmed(pending: pendingEntries, fixLat: fix.coordinate.latitude, fixLon: fix.coordinate.longitude,
                                          accuracy: fix.horizontalAccuracy, fixTime: fix.timestamp, now: now, heat: heat)
        for id in ids { pendingEntries[id] = nil; WalkInMonitor.shared.enteredRegion(id) }
    }

    /// An entry or "already inside" report: ask for a fresh fix; with none within ~10 s nothing is posted.
    private func entered(_ id: String) {
        guard status == .authorizedAlways, !WalkInMonitor.pausedOnDisk else { return }
        pendingEntries[id] = Date()
        manager.requestLocation()
        DispatchQueue.main.asyncAfter(deadline: .now() + GeofenceEntry.fixTimeout + 1) { [weak self] in
            guard let self else { return }
            self.pendingEntries = GeofenceEntry.pruned(self.pendingEntries, now: Date())
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard state == .inside else { return }
        let id = region.identifier
        Task { @MainActor in self.entered(id) }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didEnterRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in self.entered(id) }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.pendingEntries = [:] }  // no fix, no notification
    }
}
