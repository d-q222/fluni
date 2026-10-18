import CoreLocation
#if canImport(UIKit)
import UIKit
#endif

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

    /// FlUni sets this before start(): with Always, keep FlUni running off screen (BackgroundLocation). The harness
    /// has no location background mode and leaves it off.
    var keepsAppAlive = false
    /// The mode now in force (BackgroundLocation.Mode); the model rescans Bluetooth while it is `.keepAlive`.
    private(set) var mode = BackgroundLocation.Mode.off
    var onMode: ((BackgroundLocation.Mode) -> Void)?

    private let manager = CLLocationManager()
    private var paused = false
    private var relaxed = false
    private var active = true
    private var observing = false

    /// Stops location updates. Safe to call twice.
    func stop() {
        paused = true
        manager.stopUpdatingLocation()
        apply()
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
        observeAppState()
        apply()
        manager.startUpdatingLocation()
    }

    /// Brings the manager in line with BackgroundLocation for the current permission, pause and app state.
    private func apply() {
        let auth = BackgroundLocation.Auth(manager.authorizationStatus)
        let m = BackgroundLocation.mode(auth: auth, paused: paused, active: active, canKeepAlive: keepsAppAlive)
        if let set = BackgroundLocation.settings(m, auth: auth, relaxed: relaxed && rangesWithPeers, canKeepAlive: keepsAppAlive) {
            #if os(iOS)
            if manager.allowsBackgroundLocationUpdates != set.allowsBackground { manager.allowsBackgroundLocationUpdates = set.allowsBackground }
            if manager.showsBackgroundLocationIndicator != set.showsIndicator { manager.showsBackgroundLocationIndicator = set.showsIndicator }
            #endif
            if manager.desiredAccuracy != set.accuracy { manager.desiredAccuracy = set.accuracy }
            if manager.distanceFilter != set.distanceFilter { manager.distanceFilter = set.distanceFilter }
        } else {
            #if os(iOS)
            if manager.allowsBackgroundLocationUpdates { manager.allowsBackgroundLocationUpdates = false }
            #endif
        }
        if m != mode { mode = m; onMode?(m) }
    }

    private func observeAppState() {
        #if canImport(UIKit)
        guard !observing else { return }
        observing = true
        active = UIApplication.shared.applicationState != .background
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.active = false; self?.apply()
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.active = true; self?.apply()
        }
        #endif
    }

    /// While UWB is live, GPS ranging (sigma >= 3 m vs 0.1 m) barely moves the fused estimate, so ease off.
    /// Back to full rate when UWB drops, since GPS is then the fallback. Ignored unless `rangesWithPeers`:
    /// otherwise GPS isn't used for distance at all, and relaxing would only slow the building warnings.
    func setRelaxed(_ relaxed: Bool) {
        guard self.relaxed != relaxed else { return }
        self.relaxed = relaxed
        apply()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            onState?(m.accuracyAuthorization == .fullAccuracy ? "on" : "on (approximate only)")
            apply()  // Always may have just been granted (or taken back)
            if !paused { m.startUpdatingLocation() }
        case .denied, .restricted: onState?("not allowed"); apply()
        default: onState?("asking")
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !paused, let fix = locations.last, BackgroundLocation.usesFix(mode, horizontalAccuracy: fix.horizontalAccuracy) else { return }
        onFix?(fix)
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        onState?("error: \(error.localizedDescription)")
    }
}
