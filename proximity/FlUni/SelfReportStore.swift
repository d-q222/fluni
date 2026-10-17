import Foundation

/// Keeps the user's self-report details on this phone only (UserDefaults, JSON) and applies the rules in
/// Core/SelfReport.swift. The only thing that leaves the phone is the 3-level status, through
/// ProximityModel.setMyStatus; symptoms, dates and test kinds are never broadcast.
final class SelfReportStore: ObservableObject {
    @Published private(set) var record: SelfReportRecord
    /// A one-line result of the last action ("Cleared", "Stays contagious", ...), shown on the Me tab.
    @Published var notice: String?

    let reporter: SelfReporter
    private let defaults: UserDefaults
    private static let key = "selfReportRecord"

    init(calendar: Calendar = .current, defaults: UserDefaults = .standard) {
        self.reporter = SelfReporter(calendar: calendar)
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let r = try? JSONDecoder().decode(SelfReportRecord.self, from: data) {
            record = r
        } else {
            record = SelfReportRecord()
        }
    }

    /// Call when the model's status may have changed behind our back (first appearance, Developer tools).
    func reconcile(with model: ProximityModel) {
        let r = reporter.reconciled(record, risk: model.myRisk, setAt: model.statusSetAt)
        if r != record { set(r) }
    }

    private func set(_ r: SelfReportRecord) {
        record = r
        if let data = try? JSONEncoder().encode(r) { defaults.set(data, forKey: Self.key) }
    }

    private func commit(_ r: SelfReportRecord, to model: ProximityModel) {
        set(r)
        if model.myRisk != r.risk { model.setMyStatus(r.risk) }
    }

    func feelFine(model: ProximityModel, now: Date = Date()) throws {
        commit(try reporter.reportFine(record, now: now), to: model)
        notice = nil
    }

    func symptoms(_ s: Set<Symptom>, onset: Date, model: ProximityModel, now: Date = Date()) throws {
        commit(try reporter.reportSymptoms(record, symptoms: s, onset: onset, now: now), to: model)
        notice = nil
    }

    func positive(_ kind: TestKind, date: Date, model: ProximityModel, now: Date = Date()) throws {
        commit(try reporter.reportPositive(record, kind: kind, date: date, now: now), to: model)
        notice = nil
    }

    func negative(_ kind: TestKind, date: Date, model: ProximityModel, now: Date = Date()) throws {
        let before = record
        let after = try reporter.reportNegative(record, kind: kind, date: date, now: now)
        commit(after, to: model)
        switch (before.risk, after.risk) {
        case (.possible, .none):
            notice = "Status set back to healthy. A negative test, especially a single rapid one, doesn't rule illness out: if symptoms continue or get worse, test again in 1 to 2 days or visit Vaden."
        case (.possible, _):
            notice = "That test was from before your symptoms started, so your status stays \"possibly sick\"."
        case (.contagious, _):
            notice = "You tested positive earlier, so you stay marked contagious until your isolation period is over."
        default:
            notice = "Nothing to change: you're already shown as healthy."
        }
    }

    func checkIn(stillSymptomatic: Bool, hasFever: Bool, model: ProximityModel, now: Date = Date()) {
        let before = record
        let after = reporter.checkIn(record, stillSymptomatic: stillSymptomatic, hasFever: hasFever, now: now)
        commit(after, to: model)
        if before.risk == .contagious && !stillSymptomatic {
            notice = "Glad you feel better. You stay marked contagious until your isolation period is over and you've had no fever for 24 hours."
        } else if after.risk == .none {
            notice = "Status set back to healthy. Take it easy for another day."
        } else {
            notice = nil
        }
    }
}
