import Foundation
import SwiftUI
import UIKit
import Combine

/// The one clock for the persona (P(sick)), the Map tab and the walk-in warning.
///
/// Students: always live. `simTime` is the device's local weekday and time of day mapped onto the run
/// (Core/LiveClock.swift), recomputed on a timer and whenever the system clock, time zone or date changes.
/// Debug builds only: the Demo override replaces the live time with a chosen sim time that can follow the map at
/// 2 sim minutes per real second. Release builds ignore any saved override.
@MainActor
final class SimClock: ObservableObject {
    static let shared = SimClock()
    static let simSecondsPerSecond = 120.0
    /// Demo override and demo speed exist in Debug builds only.
    static let demoAvailable: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// The moment everything reads: the live time, or the demo override while it is on.
    @Published private(set) var simTime: Double = 0
    /// The span of the loaded data (the persona file and the building file of this run), if any.
    @Published private(set) var range: ClosedRange<Double>?
    /// Stored under the same key PSickLoader reads, so both always agree.
    @Published var runID: String {
        didSet {
            let clean = runID.trimmingCharacters(in: .whitespaces)
            PSickLoader.runID = clean
            if clean != oldValue.trimmingCharacters(in: .whitespaces) { range = nil; refresh() }
        }
    }

    /// Demo override (Debug only, persisted): while on, `demoTime` replaces the live time.
    @Published private(set) var demoOn: Bool
    @Published var demoTime: Double { didSet { d.set(demoTime, forKey: "psickSimTime"); refresh() } }
    @Published var follow: Bool { didSet { d.set(follow, forKey: "psickFollow"); restartTimer() } }
    /// True only while an override is replacing the live time. Drives the "Demo time" badge.
    var demoActive: Bool { Self.demoAvailable && demoOn }

    private let d = UserDefaults.standard
    private var timer: Timer?
    private var bag: [AnyCancellable] = []

    private init() {
        runID = PSickLoader.runID
        let avail = Self.demoAvailable
        demoOn = avail && (d.object(forKey: "demoOn") as? Bool ?? false)
        demoTime = avail ? (d.object(forKey: "psickSimTime") as? Double ?? 0) : 0
        // With the override on, the map follows by default; after that the saved choice wins.
        follow = avail && (d.object(forKey: "psickFollow") as? Bool ?? true)
        refresh()
        restartTimer()
        // Reconcile with the system clock whenever it, the zone or the date changes, and when the app returns.
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [UIApplication.significantTimeChangeNotification, .NSSystemTimeZoneDidChange,
                                          .NSSystemClockDidChange, UIApplication.didBecomeActiveNotification]
        bag = names.map { n in nc.publisher(for: n).sink { [weak self] _ in Task { @MainActor in self?.refresh() } } }
    }

    /// Turn the override on (starting from the current live time) or off. No effect in Release builds.
    func setDemo(_ on: Bool) {
        guard Self.demoAvailable, on != demoOn else { return }
        if on, let live = liveTime() { demoTime = live }
        demoOn = on
        d.set(on, forKey: "demoOn")
        refresh()
        restartTimer()
    }

    /// A data file for this run covers `r`. The clock spans all of them.
    func adopt(_ r: ClosedRange<Double>?) {
        guard let r else { return }
        range = range.map { min($0.lowerBound, r.lowerBound)...max($0.upperBound, r.upperBound) } ?? r
        if let range, !(range ~= demoTime) { demoTime = range.lowerBound }
        refresh()
    }

    /// Where the device's clock lands in the run now, if a run is loaded.
    func liveTime(now: Date = Date()) -> Double? {
        guard let range else { return nil }
        return LiveClock.simTime(now: now, calendar: .autoupdatingCurrent, run: range)
    }

    private func refresh() {
        let t = demoActive ? demoTime : (liveTime() ?? 0)
        if t != simTime { simTime = t }
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
        let following = demoActive && follow
        let t = Timer(timeInterval: following ? 1 : 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.demoActive && self.follow {
                    guard let r = self.range else { return }
                    let next = self.demoTime + Self.simSecondsPerSecond
                    self.demoTime = next > r.upperBound ? r.lowerBound : next
                } else {
                    self.refresh()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)  // keeps ticking while a list scrolls
        timer = t
    }
}

/// A small "Demo time" tag, shown only while the demo override is replacing the live time.
struct DemoTimeBadge: View {
    @ObservedObject private var clock = SimClock.shared

    var body: some View {
        if clock.demoActive {
            Label("Demo time", systemImage: "clock.badge.exclamationmark")
                .font(.fluni(.caption, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Theme.sunWash, in: Capsule())
                .overlay(Capsule().stroke(Theme.ink2, lineWidth: 1))
                .accessibilityIdentifier("demo.badge")
        }
    }
}
