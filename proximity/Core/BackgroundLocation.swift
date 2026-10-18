import CoreLocation
import Foundation

/// Reliable off-screen operation for students who grant Always location (product owner, 2026-10-17).
///
/// iOS keeps an app running in the background while it has standard location updates on and
/// `allowsBackgroundLocationUpdates` set. With Always, FlUni's own-location manager (GPSRanger) therefore
/// switches to coarse, rarely delivered updates when FlUni goes off screen: the app keeps running, so the 1 s
/// tick, the held-link RSSI polls and a periodic Bluetooth rescan keep detection going while locked. The blue
/// location indicator is shown, to be honest that location is in use. Without Always nothing changes.
/// Walk-in warnings still come from the building geofences (BuildingWatcher); coarse keep-alive fixes are never
/// used for them. Pure policy, so it is unit-testable.
enum BackgroundLocation {
    enum Auth: Equatable {
        case notDetermined, denied, whenInUse, always

        init(_ s: CLAuthorizationStatus) {
            switch s {
            case .authorizedAlways: self = .always
            case .authorizedWhenInUse: self = .whenInUse
            case .denied, .restricted: self = .denied
            default: self = .notDetermined
            }
        }
    }

    enum Mode: Equatable {
        /// Paused, or location not allowed: no updates.
        case off
        /// FlUni open, or no Always: best accuracy while open, exactly as before.
        case foreground
        /// Always and FlUni off screen: coarse continuous updates that keep FlUni running.
        case keepAlive
    }

    /// `active`: FlUni is on screen. `canKeepAlive`: the app declares the location background mode (FlUni; the
    /// harness does not, and setting allowsBackgroundLocationUpdates there would crash).
    static func mode(auth: Auth, paused: Bool, active: Bool, canKeepAlive: Bool) -> Mode {
        if paused || auth == .denied { return .off }
        if auth == .always && !active && canKeepAlive { return .keepAlive }
        return .foreground  // notDetermined too: updates start and iOS asks, as before
    }

    struct Settings: Equatable {
        var accuracy: CLLocationAccuracy
        var distanceFilter: CLLocationDistance
        var allowsBackground: Bool
        var showsIndicator: Bool
    }

    /// Keep-alive accuracy: cell and Wi-Fi only, no GPS radio. Enough to keep FlUni running; never used for
    /// building decisions (see `usesFix`).
    static let keepAliveAccuracy: CLLocationAccuracy = kCLLocationAccuracyThreeKilometers
    /// Keep-alive deliveries: only after ~500 m of movement, so a still phone wakes for location almost never.
    static let keepAliveDistanceFilter: CLLocationDistance = 500
    /// A fix coarser than this is never handed on while off screen (a walk-in decision needs a building-sized fix).
    static let maxOffScreenFixAccuracy: CLLocationAccuracy = 100
    /// While kept alive off screen, Bluetooth scanning restarts this often: iOS reports each phone once per
    /// background scan, so a restart lets phones that came near be discovered again.
    static let rescanInterval: TimeInterval = 10

    /// The CLLocationManager settings for a mode. `relaxed` is GPSRanger's UWB-is-live hint (harness only).
    /// With Always, background updates are allowed in the foreground too, so the switch on locking is seamless.
    static func settings(_ mode: Mode, auth: Auth, relaxed: Bool, canKeepAlive: Bool) -> Settings? {
        let bg = auth == .always && canKeepAlive
        switch mode {
        case .off: return nil
        case .foreground:
            return Settings(accuracy: relaxed ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyBest,
                            distanceFilter: relaxed ? 5 : kCLDistanceFilterNone, allowsBackground: bg, showsIndicator: bg)
        case .keepAlive:
            return Settings(accuracy: keepAliveAccuracy, distanceFilter: keepAliveDistanceFilter,
                            allowsBackground: true, showsIndicator: true)
        }
    }

    /// Whether a fix goes on to FlUni (walk-in warnings, harness GPS ranging). Invalid fixes never do; while kept
    /// alive off screen only building-sized ones do.
    static func usesFix(_ mode: Mode, horizontalAccuracy a: CLLocationAccuracy) -> Bool {
        guard a.isFinite, a >= 0, mode != .off else { return false }
        return mode == .keepAlive ? a <= maxOffScreenFixAccuracy : true
    }

    /// Restart Bluetooth scanning now? Only while kept alive; a clock that went backwards counts as due.
    static func shouldRescan(_ mode: Mode, last: Date?, now: Date) -> Bool {
        guard mode == .keepAlive else { return false }
        guard let last else { return true }
        let since = now.timeIntervalSince(last)
        return since < 0 || since >= rescanInterval
    }

    /// Whether to offer the Always step (AlwaysLocationCard): When In Use granted, onboarding done, not dismissed.
    /// Denied or undecided users are not nagged; Always users are done.
    static func offersAlways(auth: Auth, onboarded: Bool, dismissed: Bool) -> Bool {
        auth == .whenInUse && onboarded && !dismissed
    }
}
