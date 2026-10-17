import CoreLocation

/// This phone's own GPS fix. The fix goes only to linked nearby phones, never to a server.
final class GPSRanger: NSObject, CLLocationManagerDelegate {
    var onFix: ((CLLocation) -> Void)?
    var onState: ((String) -> Void)?

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
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    /// While UWB is live, GPS (sigma >= 3 m vs 0.1 m) barely moves the fused estimate, so ease off.
    /// Back to full rate the moment UWB drops, since GPS is then the fallback.
    func setRelaxed(_ relaxed: Bool) {
        let acc = relaxed ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyBest
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
