import Foundation

extension PeerState {
    /// What ContactGuard needs from a peer (kept out of ContactGuard.swift so that file stays pure).
    var guardInput: ContactGuard.Input {
        ContactGuard.Input(id: id, risk: risk, pClose: pClose,
                           distance: estimate.flatMap(Fusion.doseDistance),
                           rssi: rssi, sources: estimate?.sources ?? [], uwbAt: uwb?.at)
    }
}
