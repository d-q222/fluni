import Foundation
import Combine

/// The slow-changing parts of ProximityModel that Today and You draw from, published only when they change.
/// The model republishes every tick near someone sick (exposure, liveRisk); a screen observing it directly
/// would rebuild every second. Screens observe this instead, and only the small views that show the live
/// risk number (LiveRiskNumber, LiveRiskLine) observe the model itself.
@MainActor
final class ModelFeed: ObservableObject {
    static let shared = ModelFeed()

    @Published private(set) var level = AlertLevel.none
    /// Close-contact minutes, whole minutes (what the strip shows).
    @Published private(set) var minutes = 0
    @Published private(set) var peerCount = 0
    @Published private(set) var pauseState: PauseState?
    @Published private(set) var myRisk = Risk.none
    @Published private(set) var statusSetAt: Date?
    @Published private(set) var unusualSignals = false
    /// The live risk estimate's band (low / elevated / high): changes rarely, unlike the number.
    @Published private(set) var riskBand = RiskEstimate.Band.low
    var isPaused: Bool { pauseState != nil }

    private var bag: [AnyCancellable] = []
    private weak var model: ProximityModel?

    func attach(_ m: ProximityModel) {
        guard model == nil else { return }
        model = m
        let exposure: AnyPublisher<ExposureTracker, Never> = {
            #if DEBUG
            if let e = PreviewHook.exposure { return Just(e).eraseToAnyPublisher() }
            #endif
            // `exposure` isn't @Published; the model announces visible changes through objectWillChange (setExposure).
            // Read it once the change has landed (next main-queue turn).
            return m.objectWillChange.receive(on: DispatchQueue.main)
                .compactMap { [weak m] _ in m?.exposure }
                .prepend(m.exposure)
                .eraseToAnyPublisher()
        }()
        let peers: AnyPublisher<Int, Never> = {
            #if DEBUG
            if let n = PreviewHook.peerCount { return Just(n).eraseToAnyPublisher() }
            #endif
            return m.$peers.map(\.count).eraseToAnyPublisher()
        }()
        let risk: AnyPublisher<Double, Never> = {
            #if DEBUG
            if let e = PreviewHook.exposure { return Just(e.probability).eraseToAnyPublisher() }
            #endif
            return m.$liveRisk.eraseToAnyPublisher()
        }()
        bag = [
            risk.map(RiskEstimate.band).removeDuplicates().sink { [weak self] in self?.riskBand = $0 },
            exposure.map(\.level).removeDuplicates().sink { [weak self] in self?.level = $0 },
            exposure.map { Int(min($0.minutes, 99)) }.removeDuplicates().sink { [weak self] in self?.minutes = $0 },
            peers.removeDuplicates().sink { [weak self] in self?.peerCount = $0 },
            m.$pauseState.removeDuplicates().sink { [weak self] in self?.pauseState = $0 },
            m.$myRisk.removeDuplicates().sink { [weak self] in self?.myRisk = $0 },
            m.$statusSetAt.removeDuplicates().sink { [weak self] in self?.statusSetAt = $0 },
            m.$unusualSignals.removeDuplicates().sink { [weak self] in self?.unusualSignals = $0 },
        ]
    }
}
