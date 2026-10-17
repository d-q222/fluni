import CoreBluetooth
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Broadcasts and hears anonymous beacons. The whole payload rides in one 128-bit service UUID:
///   bytes 0-3  "FLU1" magic
///   byte  4    risk level
///   bytes 5-15 ephemeral ID (rotates)
/// No connection is needed, so risk status gets through even if the peer link is down.
/// Foreground only: iOS hides service UUIDs from scanners while the app is in the background.
final class BLEBeacon: NSObject, CBPeripheralManagerDelegate, CBCentralManagerDelegate {
    static let magic: [UInt8] = [0x46, 0x4C, 0x55, 0x31]

    /// (ephemeral ID hex, risk, smoothed RSSI)
    var onSighting: ((String, Risk, Double) -> Void)?
    var onState: ((String) -> Void)?

    private var peripheral: CBPeripheralManager!
    private var central: CBCentralManager!
    private var payload: CBUUID?
    private let scanQueue = DispatchQueue(label: "fluni.ble.scan")  // keeps the advert flood off the main thread
    private var smoothed: [String: (rssi: Double, at: Date)] = [:]  // scanQueue only
    private var lastPrune = Date()
    private let pauseLock = NSLock()
    private var _paused = false
    private var paused: Bool {
        get { pauseLock.lock(); defer { pauseLock.unlock() }; return _paused }
        set { pauseLock.lock(); _paused = newValue; pauseLock.unlock() }
    }

    /// Stops advertising and scanning. Safe to call twice. Radios stay allocated; resume() restarts them.
    func stop() {
        paused = true
        peripheral?.stopAdvertising()
        scanQueue.sync {
            central?.stopScan()
            smoothed.removeAll()
        }
    }

    /// Starts again after stop() (or for the first time, if the app launched paused).
    func resume() {
        guard peripheral != nil else { paused = false; start(); return }
        paused = false
        onState?("advertiser \(peripheral.state.name)")
        onState?("scanner \(central.state.name)")
        restartAdvertising()
        scanQueue.async { self.restartScan() }
    }

    func start() {
        peripheral = CBPeripheralManager(delegate: self, queue: nil)
        central = CBCentralManager(delegate: self, queue: scanQueue)
        // Radios can be left idle or stale after a trip through the background or a Bluetooth toggle.
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.restartAdvertising()
            self?.scanQueue.async { self?.restartScan() }
        }
        #endif
    }

    private func restartScan() {
        guard !paused, let central, central.state == .poweredOn else { return }
        central.stopScan()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func peripheralManagerDidStartAdvertising(_ p: CBPeripheralManager, error: Error?) {
        guard error != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.restartAdvertising() }
    }

    func advertise(id: Data, risk: Risk) {
        guard id.count == 11 else { return }
        payload = CBUUID(data: Data(Self.magic + [UInt8(risk.rawValue)]) + id.prefix(11))
        restartAdvertising()
    }

    static func decode(_ uuid: CBUUID) -> (id: String, risk: Risk)? {
        let d = uuid.data
        guard d.count == 16 else { return nil }
        // Check the magic in place; most adverts on a busy campus aren't ours.
        let b = d.startIndex
        guard d[b] == magic[0], d[b + 1] == magic[1], d[b + 2] == magic[2], d[b + 3] == magic[3],
              let risk = Risk(rawValue: Int(d[b + 4])) else { return nil }
        return (d[(b + 5)...].hex, risk)
    }

    private func restartAdvertising() {
        guard !paused, let peripheral, peripheral.state == .poweredOn, let payload else { return }
        peripheral.stopAdvertising()
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [payload]])
    }

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        onState?("advertiser \(p.state.name)")
        restartAdvertising()
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        let s = "scanner \(c.state.name)"
        DispatchQueue.main.async { self.onState?(s) }
        restartScan()
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard !paused, let hit = uuids.lazy.compactMap(Self.decode).first else { return }
        let raw = rssi.doubleValue
        guard raw < 0, raw > -110 else { return }  // 127 = unavailable
        // Exponential moving average: single BLE samples swing by several dB.
        let now = Date()
        let s = smoothed[hit.id].map { 0.7 * $0.rssi + 0.3 * raw } ?? raw
        smoothed[hit.id] = (s, now)
        if now.timeIntervalSince(lastPrune) > 30 {  // rotated IDs would otherwise pile up
            lastPrune = now
            smoothed = smoothed.filter { now.timeIntervalSince($0.value.at) < 30 }
        }
        DispatchQueue.main.async { self.onSighting?(hit.id, hit.risk, s) }
    }
}

extension CBManagerState {
    var name: String {
        switch self {
        case .poweredOn: return "on"
        case .poweredOff: return "off"
        case .unauthorized: return "not allowed"
        case .unsupported: return "unsupported"
        default: return "starting"
        }
    }
}

extension Data {
    var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8](); out.reserveCapacity(count * 2)
        for b in self { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 15)]) }
        return String(decoding: out, as: UTF8.self)
    }
}
