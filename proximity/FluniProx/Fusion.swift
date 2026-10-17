import Foundation

// Pure distance-fusion logic. No sensors here, so it is unit-testable on the simulator.

enum Source: String, CaseIterable {
    case uwb = "UWB", ble = "BLE", gps = "GPS"

    /// How long a reading stays usable.
    var maxAge: TimeInterval {
        switch self {
        case .uwb: return 3
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
            let s = max(r.sigma, 1e-9)  // avoids 1/0 for sigma 0 without degrading any real reading
            let w = 1 / (s * s)
            wSum += w
            dSum += w * r.distance
        }
        return Estimate(distance: max(0, dSum / wSum),
                        sigma: (1 / wSum).squareRoot(),
                        sources: fresh.map(\.source))
    }

    /// GPS alone indoors is ±10–30 m: it can't tell 2 m from 25 m, so on its own it must not count
    /// toward close-contact time (it would eventually flag everyone in the same building).
    static let maxGPSOnlySigma = 10.0

    /// P(within 6 ft) as used for exposure: 0 when the only evidence is coarse GPS.
    static func exposurePClose(_ e: Estimate) -> Double {
        isCoarseGPSOnly(e) ? 0 : pClose(e)
    }

    static func isCoarseGPSOnly(_ e: Estimate) -> Bool {
        e.sources == [.gps] && e.sigma > maxGPSOnlySigma
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

    func distance(rssi: Double) -> Double {
        pow(10, (txPower - rssi) / (10 * pathLossExponent))
    }

    /// BLE ranging is roughly multiplicative noise; calibration shrinks it.
    func reading(rssi: Double, at: Date) -> Reading {
        let d = distance(rssi: rssi)
        let rel = isCalibrated ? 0.4 : 0.7
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
