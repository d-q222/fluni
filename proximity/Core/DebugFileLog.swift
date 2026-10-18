import Foundation
#if canImport(UIKit)
import UIKit
#endif

#if DEBUG
/// Debug test launches only (flu-offdetect): mirrors the "[fluni]" lines, time-stamped, to
/// Library/Caches/fluni-test.log so a phone can be measured while it is locked, when the devicectl console tunnel
/// is gone. Read it afterwards with
///   devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier com.fluni.app \
///     --source Library/Caches/fluni-test.log --destination <file>
/// Also logs the app and lock state ("state …"), so each line can be attributed to foreground, background or
/// locked. Caches survive the lock (no complete file protection) and hold nothing of the owner's.
final class DebugFileLog {
    static let shared = DebugFileLog()
    private let queue = DispatchQueue(label: "fluni.debuglog")
    private var handle: FileHandle?
    private var observers: [NSObjectProtocol] = []

    /// Starts a fresh file. Called once, on a test launch.
    func start(log: @escaping (String) -> Void) {
        guard handle == nil, let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("fluni-test.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        #if canImport(UIKit)
        let nc = NotificationCenter.default
        let states: [(Notification.Name, String)] = [
            (UIApplication.didEnterBackgroundNotification, "state background"),
            (UIApplication.willEnterForegroundNotification, "state foreground"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "state locked"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "state unlocked"),
        ]
        observers = states.map { name, line in nc.addObserver(forName: name, object: nil, queue: .main) { _ in log(line) } }
        let app = UIApplication.shared
        log("state at start: \(app.applicationState == .active ? "active" : app.applicationState == .background ? "background" : "inactive")"
            + (app.isProtectedDataAvailable ? "" : " locked"))
        #endif
    }

    func append(_ s: String) {
        guard handle != nil else { return }
        let line = String(format: "%.2f ", Date().timeIntervalSince1970) + s + "\n"
        queue.async { self.handle?.write(Data(line.utf8)) }
    }
}
#endif
