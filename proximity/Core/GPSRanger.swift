import CoreLocation

/// This phone's own GPS fix. FlUni keeps it on the phone (building warnings); only the harness sends it
/// to linked phones for GPS ranging tests. Never to a server.
final class GPSRanger: NSObject, CLLocationManagerDelegate {
    var onFix: ((CLLocation) -> Void)?
    var onState: ((String) -> Void)?

    /// True only when fixes are swapped with peers for ranging (harness). Then, and only then, a live
    /// UWB link makes GPS redundant and it may relax; FlUni's building warnings always get full rate.
    var rangesWithPeers = false {
        didSet { if !rangesWithPeers { setRelaxed(false) } }
    }

    private let manager = CLLocationManager()
    private var paused = false

    /// Stops location updates. Safe to call twice.
    func stop() {
        paused = true
        manager.stopUpdatingLocation()
    }

    /// Starts again after stop() (or for the first time, if the app launched paused).
    func resume() {
        paused = false
        start()
        locationManagerDidChangeAuthorization(manager)  // report the state again; it may not change on its own
    }

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // On foot, indoors and out. Without this, iOS may pause updates while it thinks we're still
        // (pausesLocationUpdatesAutomatically defaults to true) and, per Apple's docs, it is then up to
        // the app to restart them, so a walk into a building could go unseen.
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    /// While UWB is live, GPS ranging (sigma >= 3 m vs 0.1 m) barely moves the fused estimate, so ease off.
    /// Back to full rate when UWB drops, since GPS is then the fallback. Ignored unless `rangesWithPeers`:
    /// otherwise GPS isn't used for distance at all, and relaxing would only slow the building warnings.
    func setRelaxed(_ relaxed: Bool) {
        let acc = relaxed && rangesWithPeers ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyBest
        let relaxed = acc != kCLLocationAccuracyBest
        guard manager.desiredAccuracy != acc else { return }
        manager.desiredAccuracy = acc
        manager.distanceFilter = relaxed ? 5 : kCLDistanceFilterNone
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            onState?(m.accuracyAuthorization == .fullAccuracy ? "on" : "on (approximate only)")
            if !paused { m.startUpdatingLocation() }
        case .denied, .restricted: onState?("not allowed")
        default: onState?("asking")
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !paused, let fix = locations.last, fix.horizontalAccuracy >= 0 else { return }
        onFix?(fix)
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        onState?("error: \(error.localizedDescription)")
    }
}
