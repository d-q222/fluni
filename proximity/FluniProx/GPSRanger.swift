import CoreLocation

/// This phone's own GPS fix. The fix goes only to linked nearby phones, never to a server.
final class GPSRanger: NSObject, CLLocationManagerDelegate {
    var onFix: ((CLLocation) -> Void)?
    var onState: ((String) -> Void)?

    private let manager = CLLocationManager()

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
            m.startUpdatingLocation()
        case .denied, .restricted: onState?("not allowed")
        default: onState?("asking")
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last, fix.horizontalAccuracy >= 0 else { return }
        onFix?(fix)
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        onState?("error: \(error.localizedDescription)")
    }
}
