import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A little extra background execution time (UIApplication.beginBackgroundTask) so work that a Bluetooth or
/// location wake-up started (a tick, posting a notification, waiting for a fix) finishes before iOS suspends
/// FlUni. `end()` is idempotent and safe from any thread; iOS's expiry handler ends it too. flu-offdetect.
final class BackgroundWindow {
    #if canImport(UIKit)
    private var id = UIBackgroundTaskIdentifier.invalid
    #endif
    private let lock = NSLock()

    static func begin(_ name: String) -> BackgroundWindow {
        let w = BackgroundWindow()
        #if canImport(UIKit)
        let start = {
            w.lock.lock(); defer { w.lock.unlock() }
            w.id = UIApplication.shared.beginBackgroundTask(withName: name) { w.end() }
        }
        if Thread.isMainThread { start() } else { DispatchQueue.main.sync(execute: start) }
        #endif
        return w
    }

    func end() {
        #if canImport(UIKit)
        lock.lock()
        let id = self.id
        self.id = .invalid
        lock.unlock()
        guard id != .invalid else { return }
        DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(id) }
        #endif
    }
}
