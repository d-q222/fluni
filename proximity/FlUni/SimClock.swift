import Foundation
import SwiftUI

/// The one sim clock for the persona (P(sick)), the Map tab and the walk-in warning: a sim time, "follow the map"
/// at 2 sim minutes per real second (looping over the run's range), and the run id. All three are persisted.
@MainActor
final class SimClock: ObservableObject {
    static let shared = SimClock()
    static let simSecondsPerSecond = 120.0

    @Published var simTime: Double { didSet { d.set(simTime, forKey: "psickSimTime") } }
    @Published var follow: Bool { didSet { d.set(follow, forKey: "psickFollow"); restartTimer() } }
    /// Stored under the same key PSickLoader reads, so both always agree.
    @Published var runID: String {
        didSet {
            let clean = runID.trimmingCharacters(in: .whitespaces)
            PSickLoader.runID = clean
            if clean != oldValue.trimmingCharacters(in: .whitespaces) { range = nil }
        }
    }
    /// The span of the loaded data (the persona file and the building file of this run), if any.
    @Published private(set) var range: ClosedRange<Double>?

    private let d = UserDefaults.standard
    private var timer: Timer?

    private init() {
        runID = PSickLoader.runID
        simTime = d.object(forKey: "psickSimTime") as? Double ?? 0
        // A fresh install starts with the map moving; after that the saved choice wins.
        follow = d.object(forKey: "psickFollow") as? Bool ?? true
        restartTimer()
    }

    /// A data file for this run covers `r`. The clock spans all of them; a time outside it jumps to the start.
    func adopt(_ r: ClosedRange<Double>?) {
        guard let r else { return }
        range = range.map { min($0.lowerBound, r.lowerBound)...max($0.upperBound, r.upperBound) } ?? r
        if let range, !(range ~= simTime) { simTime = range.lowerBound }
    }

    /// Delete my data: the default run, time zero, following the map.
    func forget() {
        runID = PSickLoader.defaultRunID
        range = nil
        simTime = 0
        follow = true
    }

    private func restartTimer() {
        timer?.invalidate(); timer = nil
        guard follow else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.range else { return }
                let next = self.simTime + Self.simSecondsPerSecond
                self.simTime = next > r.upperBound ? r.lowerBound : next
            }
        }
    }
}
