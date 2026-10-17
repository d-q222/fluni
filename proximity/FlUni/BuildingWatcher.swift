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

    /// Bring monitoring in line with permission and pause state.
    func sync() {
        status = manager.authorizationStatus
        guard status == .authorizedAlways, !WalkInMonitor.pausedOnDisk, let heat = BuildingHeatStore.shared.heat else {
            manager.stopMonitoringSignificantLocationChanges()
            for r in manager.monitoredRegions { manager.stopMonitoring(for: r) }
            return
        }
        manager.startMonitoringSignificantLocationChanges()
        if let here = manager.location { pick(heat, near: here) } else { manager.requestLocation() }
    }

    private func pick(_ heat: BuildingHeat, near here: CLLocation) {
        let ranked = heat.mappable.sorted {
            here.distance(from: CLLocation(latitude: $0.lat!, longitude: $0.lon!)) < here.distance(from: CLLocation(latitude: $1.lat!, longitude: $1.lon!))
        }.prefix(Self.maxRegions)
        let ids = Set(ranked.map(\.id))
        for r in manager.monitoredRegions where !ids.contains(r.identifier) { manager.stopMonitoring(for: r) }
        let have = Set(manager.monitoredRegions.map(\.identifier))
        for b in ranked where !have.contains(b.id) {
            let r = CLCircularRegion(center: .init(latitude: b.lat!, longitude: b.lon!),
                                     radius: min(b.radius, manager.maximumRegionMonitoringDistance), identifier: b.id)
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
            self.pick(heat, near: here)
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard state == .inside else { return }
        let id = region.identifier
        Task { @MainActor in WalkInMonitor.shared.enteredRegion(id) }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didEnterRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in WalkInMonitor.shared.enteredRegion(id) }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
