import Foundation

// Pure distance-fusion logic. No sensors here, so it is unit-testable on the simulator.

enum Source: String, CaseIterable {
    case uwb = "UWB", ble = "BLE", gps = "GPS"

    /// How long a reading stays usable. UWB's last 3 s of it is a grace period with a growing error
    /// (see `Fusion.agedSigma`).
    var maxAge: TimeInterval {
        switch self {
        case .uwb: return 6
        case .ble: return 6
        case .gps: return 20
        }
    }
}

/// One distance estimate from one sensor: `distance` metres, 1-sigma error `sigma` metres.
struct Reading: Equatable {
    var source: Source
    var distance: Double
    var sigma: Double
    var at: Date
}

struct Estimate: Equatable {
    var distance: Double
    var sigma: Double
    var sources: [Source]
}

enum Fusion {
    /// 6 ft, the CDC close-contact distance.
    static let closeDistance = 1.83

    /// Beyond this (metres), a distance or error is a broken sensor, not a measurement; also keeps the sums finite.
    static let maxPlausible = 100_000.0

    /// Inverse-variance weighted mean of the fresh readings.
    /// A precise sensor (UWB) dominates; coarse ones (BLE, GPS) fill in when it drops out.
    /// Garbage (NaN/inf/negative) is dropped, and so is anything stamped more than 1 s in the future
    /// (a clock step must not keep a reading "fresh" forever).
    static func fuse(_ readings: [Reading], now: Date) -> Estimate? {
        let fresh = readings.filter { r in
            let age = now.timeIntervalSince(r.at)
            return age >= -1 && age <= r.source.maxAge
                && (0 ... maxPlausible).contains(r.distance) && (0 ... maxPlausible).contains(r.sigma)
        }
        guard !fresh.isEmpty else { return nil }
        var wSum = 0.0, dSum = 0.0
        for r in fresh {
            let s = max(agedSigma(r, age: now.timeIntervalSince(r.at)), 1e-9)  // avoids 1/0 for sigma 0
            let w = 1 / (s * s)
            wSum += w
            dSum += w * r.distance
        }
        return Estimate(distance: max(0, dSum / wSum),
                        sigma: (1 / wSum).squareRoot(),
                        sources: fresh.map(\.source))
    }

    /// UWB drops single frames and whole seconds (bodies in the way, a session re-run, the peer link
    /// reconnecting). Rather than snapping to Bluetooth (±10 dB, ~1.5x off) the moment it does, the last
    /// UWB distance keeps full weight for 3 s and then stays usable to 6 s (`Source.uwb.maxAge`) with its
    /// error growing 1 m/s, about a slow walk, so Bluetooth takes over smoothly. Other sources: unchanged.
    static let uwbFullTrust: TimeInterval = 3
    static let uwbGraceGrowth = 1.0  // metres of sigma per second past uwbFullTrust

    static func agedSigma(_ r: Reading, age: TimeInterval) -> Double {
        guard r.source == .uwb, age > uwbFullTrust else { return r.sigma }
        return r.sigma + uwbGraceGrowth * (age - uwbFullTrust)
    }

    /// GPS alone indoors is ±10–30 m: it can't tell 2 m from 25 m, so on its own it must not count
    /// toward close-contact time (it would eventually flag everyone in the same building).
    static let maxGPSOnlySigma = 10.0

    /// P(within 6 ft) as used for exposure: 0 when the only evidence is coarse GPS.
    static func exposurePClose(_ e: Estimate) -> Double {
        isCoarseGPSOnly(e) ? 0 : pClose(e)
    }

    static func isCoarseGPSOnly(_ e: Estimate) -> Bool {
        !e.sources.isEmpty && e.sources.allSatisfy { $0 == .gps } && e.sigma > maxGPSOnlySigma
    }

    /// Distance-tier weight for the risk dose, as in model/infer.js: <1 m → 1, 1–2 m → 0.6,
    /// 2–5 m → 0.1, farther (still in radio range, ~same room) → 0.02. Coarse GPS alone → 0.
    static func tierWeight(_ e: Estimate) -> Double {
        if isCoarseGPSOnly(e) || !e.distance.isFinite { return 0 }
        switch e.distance {
        case ..<1: return 1
        case ..<2: return 0.6
        case ..<5: return 0.1
        default: return 0.02
        }
    }

    /// P(true distance <= 6 ft) under a normal error model.
    static func pClose(_ e: Estimate) -> Double {
        guard e.distance.isFinite, e.sigma.isFinite else { return 0 }
        return normalCDF((closeDistance - e.distance) / max(e.sigma, 1e-6))
    }

    static func normalCDF(_ z: Double) -> Double {
        0.5 * erfc(-z / 2.squareRoot())
    }
}

/// Converts BLE RSSI to metres with the log-distance path-loss model,
///   rssi = txPower - 10 n log10(d),
/// and learns `txPower` (RSSI at 1 m) for this phone pair whenever UWB gives the true distance.
struct BLECalibrator: Equatable {
    static let defaultTxPower = -59.0
    var txPower = defaultTxPower
    var pathLossExponent = 2.0
    private(set) var samples = 0

    var isCalibrated: Bool { samples >= 5 }
    /// Started from this phone's learned prior (see TxPowerPrior) rather than the generic default.
    private(set) var startedFromPrior = false

    /// A new peer starts from what this phone has learned about other phones, if anything.
    static func fromPrior(_ prior: TxPowerPrior) -> BLECalibrator {
        var c = BLECalibrator()
        if prior.isLearned { c.txPower = prior.txPower; c.startedFromPrior = true }
        return c
    }

    func distance(rssi: Double) -> Double {
        pow(10, (txPower - rssi) / (10 * pathLossExponent))
    }

    /// BLE ranging is roughly multiplicative noise; calibration shrinks it.
    func reading(rssi: Double, at: Date) -> Reading {
        let d = distance(rssi: rssi)
        let rel = isCalibrated ? 0.4 : (startedFromPrior ? 0.55 : 0.7)
        return Reading(source: .ble, distance: d, sigma: rel * d + 0.3, at: at)
    }

    /// Plausible RSSI-at-1-m range for phones; anything outside is a bad sample, not a calibration.
    static let txPowerRange = -100.0 ... -20.0

    mutating func observe(rssi: Double, trueDistance: Double) {
        guard rssi.isFinite, (-110 ... 0).contains(rssi), trueDistance.isFinite, trueDistance > 0.05 else { return }
        let implied = rssi + 10 * pathLossExponent * log10(trueDistance)
        guard Self.txPowerRange.contains(implied) else { return }
        let alpha = samples < 5 ? 0.5 : 0.1
        txPower += alpha * (implied - txPower)
        samples += 1
    }
}

/// This phone's learned RSSI-at-1-m for other phones, from every UWB-calibrated pair. Kept across ID
/// rotations and launches so Bluetooth-only ranging (UWB off, or in the background) starts calibrated.
/// Field data (1069 UWB/BLE pairs, 3 iPhones) put the best single value near -61 dBm, with pairs
/// spreading from about -49 to -71, which is why per-phone learning beats any fixed default.
struct TxPowerPrior: Codable, Equatable {
    var txPower = BLECalibrator.defaultTxPower
    private(set) var pairs = 0
    var isLearned: Bool { pairs >= 1 }

    /// Fold in one calibrated pair's txPower; implausible values are ignored.
    mutating func learn(_ calibrated: Double) {
        guard calibrated.isFinite, BLECalibrator.txPowerRange.contains(calibrated) else { return }
        txPower += (pairs < 3 ? 0.5 : 0.2) * (calibrated - txPower)
        pairs += 1
    }
}

/// Median RSSI over the last few seconds for one beacon. Single samples swing by ±10 dB (bodies,
/// orientation, reflections; measured 0.3–0.8 m apart: -60 to -50 dBm interquartile), and a median
/// ignores the spikes an average lets through.
struct RSSIWindow: Equatable {
    static let span: TimeInterval = 4
    static let maxSamples = 15
    struct Sample: Equatable { var rssi: Double; var at: Date }
    private(set) var samples: [Sample] = []
    var lastAt: Date? { samples.last?.at }

    /// Adds a sample and returns the current median.
    mutating func add(_ rssi: Double, at t: Date) -> Double {
        samples.append(Sample(rssi: rssi, at: t))
        samples.removeAll { t.timeIntervalSince($0.at) > Self.span }
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
        let s = samples.map(\.rssi).sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

/// GPS gives each phone's own fix; distance error combines both accuracy radii.
/// The peer's fix arrives over the network, so it is untrusted: invalid input (NaN, |lat| > 90,
/// accuracy < 0 = CoreLocation's "invalid") yields a NaN distance, which `fuse` discards.
func gpsReading(myLat: Double, myLon: Double, myAcc: Double,
                peerLat: Double, peerLon: Double, peerAcc: Double, at: Date) -> Reading {
    let valid = [myLat, myLon, myAcc, peerLat, peerLon, peerAcc].allSatisfy(\.isFinite)
        && abs(myLat) <= 90 && abs(peerLat) <= 90 && myAcc >= 0 && peerAcc >= 0
    guard valid else { return Reading(source: .gps, distance: .nan, sigma: .nan, at: at) }
    let r = 6_371_000.0
    let dLat = (peerLat - myLat) * .pi / 180
    let dLon = (peerLon - myLon) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2)
        + cos(myLat * .pi / 180) * cos(peerLat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
    let d = 2 * r * atan2(a.squareRoot(), (1 - a).squareRoot())
    return Reading(source: .gps, distance: d,
                   sigma: max(3, (myAcc * myAcc + peerAcc * peerAcc).squareRoot()), at: at)
}
