import Foundation

/// Whether an alert level reached on a tick gets a notification (flu-offdetect). The same rule runs in the
/// foreground and on a background Bluetooth wake-up, so a locked phone notifies exactly like an open one:
/// - only a crossing upward notifies (AlertNotifier: none -> heads-up -> close contact; the notified level follows
///   the level down, so a later climb is a new crossing);
/// - a de-escalation never notifies;
/// - the same level is not notified again within its cooldown, so a peer drifting in and out of range (or a
///   wake-up every few seconds while locked) can't repeat the heads-up;
/// - an escalation to close contact always notifies, whatever the heads-up's cooldown;
/// - a clock that stepped backwards past the last notification doesn't block the next one.
enum BackgroundAlert {
    /// "Someone within 6 ft may be sick": at most once per 30 min.
    static let nearbyCooldown: TimeInterval = 30 * 60
    /// Close contact (15 weighted minutes): at most once per 12 h. The level stays up while the minutes are in
    /// the 24 h window, so this only matters if they drop below 15 and climb back.
    static let closeContactCooldown: TimeInterval = 12 * 3600

    static func cooldown(_ level: AlertLevel) -> TimeInterval {
        switch level {
        case .none: return 0
        case .nearby: return nearbyCooldown
        case .closeContact: return closeContactCooldown
        }
    }

    /// `previous`: the level last seen (not necessarily notified); `lastNotifiedAt`: when `new` was last notified.
    static func shouldNotify(previous: AlertLevel, new: AlertLevel, lastNotifiedAt: Date?, now: Date) -> Bool {
        guard AlertNotifier.next(level: new, notified: previous).notify != nil else { return false }
        guard let last = lastNotifiedAt else { return true }
        let since = now.timeIntervalSince(last)
        return since < 0 || since >= cooldown(new)
    }

    /// The notification kind for an alert level (none has none).
    static func kind(_ level: AlertLevel) -> NotificationKind? {
        switch level {
        case .none: return nil
        case .nearby: return .nearby
        case .closeContact: return .closeContact
        }
    }
}

/// Posts a FlUni notification. The app posts through UNUserNotificationCenter; tests record.
protocol AlertPosting: AnyObject {
    func post(_ kind: NotificationKind)
}

/// The per-phone alert state: last level seen and when each level was last notified. Saved with the exposure
/// (RiskStateStore), so a relaunch doesn't notify the same alert again.
struct AlertGate: Equatable, Codable {
    private(set) var level = AlertLevel.none
    private(set) var lastNotifiedAt: [AlertLevel: Date] = [:]
    /// When the user last read each level's in-app alert (the tissue's "Got it"). Saved too, so a relaunch, or the
    /// peer dropping out of range for a moment, doesn't pop an alert they have already read.
    private(set) var lastReadAt: [AlertLevel: Date] = [:]

    mutating func markRead(_ level: AlertLevel, now: Date) {
        if level != .none { lastReadAt[level] = now }
    }

    /// True while `level`'s alert was read within that level's notification cooldown (30 min heads-up, 12 h close
    /// contact): the same rule as notifications, so the in-app alert pops again exactly when a notification could.
    func isRead(_ level: AlertLevel, now: Date) -> Bool {
        guard level != .none else { return true }
        guard let t = lastReadAt[level] else { return false }
        let since = now.timeIntervalSince(t)
        return since >= 0 && since < BackgroundAlert.cooldown(level)
    }

    /// Feed the tracker's level after each tick. Returns the kind to notify, if any.
    mutating func step(_ new: AlertLevel, now: Date) -> NotificationKind? {
        defer { level = new }
        guard BackgroundAlert.shouldNotify(previous: level, new: new, lastNotifiedAt: lastNotifiedAt[new], now: now) else {
            return nil
        }
        lastNotifiedAt[new] = now
        return BackgroundAlert.kind(new)
    }

    /// Same, posting through `poster`.
    mutating func step(_ new: AlertLevel, now: Date, poster: AlertPosting) {
        if let k = step(new, now: now) { poster.post(k) }
    }
}
