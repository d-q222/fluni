import Foundation

// Self-reported health: what the user said, how long to stay home, and how the status may change.
// Pure logic (no SwiftUI, no storage). Everything here stays on the phone; only `Record.risk` and the
// whole days since `dayZero` are ever broadcast (via ProximityModel.setMyStatus / setMyDayZero, so other
// phones can weight their dose by the illness stage). Symptoms, dates and test kinds are never sent.

enum Symptom: String, Codable, CaseIterable {
    case fever, cough, soreThroat, aches, fatigue, runnyNose

    var label: String {
        switch self {
        case .fever: return "Fever or chills"
        case .cough: return "Cough"
        case .soreThroat: return "Sore throat"
        case .aches: return "Body aches"
        case .fatigue: return "Fatigue"
        case .runnyNose: return "Runny or stuffy nose"
        }
    }
}

enum TestKind: String, Codable, CaseIterable {
    case rapid, pcr
    var label: String { self == .rapid ? "Rapid (home) test" : "PCR test" }
}

enum ReportError: Error, Equatable {
    case noSymptoms          // "I have symptoms" needs at least one symptom
    case dateInFuture        // onset or test date after today
    case notYetClearable     // contagious can't be cleared before the isolation period is over
}

/// Isolation guidance, all in one place. Modelled on CDC-style respiratory-virus guidance (2024
/// update): stay home and away from others until symptoms are improving AND you have been
/// fever-free for 24 hours without fever-reducing medicine; day 0 is the day symptoms start (or,
/// with no symptoms, the day of the positive test), day 1 the next day, and the conservative
/// 5-day minimum from the older guidance is what the app suggests. Not medical advice.
enum IsolationPolicy {
    /// Suggested minimum isolation: days 1...5 after day 0. The period is over at the start of day 6.
    static let days = 5
    /// Hours without a fever (and without fever-reducing medicine) before leaving home.
    static let feverFreeHours = 24.0
}

enum IsolationPhase: Equatable {
    case notIsolating
    /// `day` counts from day 0 (onset or positive-test day); `lastDay` is the last day of the minimum period.
    case inProgress(day: Int, lastDay: Date)
    /// Minimum period done. `feverFree == false` means a fever in the last 24 h still holds you at home.
    case periodOver(feverFree: Bool)
}

/// What the user told us. Persisted locally as JSON by the app.
struct SelfReportRecord: Codable, Equatable {
    var risk = Risk.none
    var symptoms: Set<Symptom> = []
    /// Start of the day symptoms began.
    var onset: Date?
    var positiveKind: TestKind?
    /// Start of the day of a positive test.
    var positiveDate: Date?
    /// Last moment the user said they had a fever (nil = none reported).
    var lastFeverAt: Date?
    var lastCheckIn: Date?

    /// Day 0 of isolation: the earlier of symptom onset and positive test.
    var dayZero: Date? { [onset, positiveDate].compactMap { $0 }.min() }
}

struct SelfReporter {
    /// Injected so day maths is testable across midnight and DST.
    var calendar: Calendar

    private func startOfDay(_ d: Date) -> Date { calendar.startOfDay(for: d) }

    private func validated(_ date: Date, now: Date) throws -> Date {
        let day = startOfDay(date)
        if day > startOfDay(now) { throw ReportError.dateInFuture }
        return day
    }

    // MARK: Reading state

    /// True when the last reported fever is at least 24 h ago (exactly 24 h counts), or none was reported.
    func isFeverFree(_ r: SelfReportRecord, now: Date) -> Bool {
        guard let f = r.lastFeverAt else { return true }
        return now.timeIntervalSince(f) >= IsolationPolicy.feverFreeHours * 3600
    }

    /// Whole calendar days since day 0 (day 0 = 0); nil with no status or no start date.
    func dayNumber(_ r: SelfReportRecord, now: Date) -> Int? {
        guard r.risk != .none, let zero = r.dayZero else { return nil }
        return calendar.dateComponents([.day], from: zero, to: startOfDay(now)).day
    }

    /// First moment the minimum period is over: the start of day 6 (calendar-day maths, so a 23 or 25 hour day doesn't shift it).
    func periodEnd(_ r: SelfReportRecord) -> Date? {
        guard let zero = r.dayZero else { return nil }
        return calendar.date(byAdding: .day, value: IsolationPolicy.days + 1, to: zero)
    }

    func phase(_ r: SelfReportRecord, now: Date) -> IsolationPhase {
        guard r.risk != .none, let end = periodEnd(r), let day = dayNumber(r, now: now) else { return .notIsolating }
        if now < end {
            let last = calendar.date(byAdding: .day, value: IsolationPolicy.days, to: r.dayZero!)!
            return .inProgress(day: day, lastDay: last)
        }
        return .periodOver(feverFree: isFeverFree(r, now: now))
    }

    /// Time to ask "are you better?": the minimum period is over and no recent fever. Never changes the status by itself.
    func shouldPromptToUpdate(_ r: SelfReportRecord, now: Date) -> Bool {
        phase(r, now: now) == .periodOver(feverFree: true)
    }

    /// The gentle daily "Still have symptoms?" is due once per calendar day while sick.
    func checkInDue(_ r: SelfReportRecord, now: Date) -> Bool {
        guard r.risk != .none else { return false }
        guard let last = r.lastCheckIn else { return true }
        return startOfDay(last) < startOfDay(now)
    }

    // MARK: Transitions (each returns the new record or throws; the input is never mutated)

    /// Fine from none/possible always; from contagious only once the period is over and fever-free.
    func reportFine(_ r: SelfReportRecord, now: Date) throws -> SelfReportRecord {
        if r.risk == .contagious && !shouldPromptToUpdate(r, now: now) { throw ReportError.notYetClearable }
        return SelfReportRecord()
    }

    /// Any symptom means at least possible. A reported positive stays contagious.
    func reportSymptoms(_ r: SelfReportRecord, symptoms: Set<Symptom>, onset: Date, now: Date) throws -> SelfReportRecord {
        if symptoms.isEmpty { throw ReportError.noSymptoms }
        let day = try validated(onset, now: now)
        var n = r
        n.risk = r.risk == .contagious ? .contagious : .possible
        n.symptoms = symptoms
        n.onset = day
        if symptoms.contains(.fever) { n.lastFeverAt = now }
        n.lastCheckIn = now
        return n
    }

    func reportPositive(_ r: SelfReportRecord, kind: TestKind, date: Date, now: Date) throws -> SelfReportRecord {
        let day = try validated(date, now: now)
        var n = r
        n.risk = .contagious
        n.positiveKind = kind
        n.positiveDate = day
        n.lastCheckIn = now
        return n
    }

    /// Clears `possible` only when the test is on or after symptom onset (an earlier negative says nothing
    /// about this illness). Never touches `contagious`: a negative after a positive doesn't undo it.
    func reportNegative(_ r: SelfReportRecord, kind: TestKind, date: Date, now: Date) throws -> SelfReportRecord {
        let day = try validated(date, now: now)
        guard r.risk == .possible else { return r }
        if let onset = r.onset, day < onset { return r }
        return SelfReportRecord()
    }

    /// The daily check-in. Fever resets the 24 h clock. "No symptoms" clears `possible`; contagious stays
    /// until the period is over (then `reportFine`).
    func checkIn(_ r: SelfReportRecord, stillSymptomatic: Bool, hasFever: Bool, now: Date) -> SelfReportRecord {
        guard r.risk != .none else { return r }
        if !stillSymptomatic && r.risk == .possible { return SelfReportRecord() }
        var n = r
        if stillSymptomatic && hasFever { n.lastFeverAt = now }
        n.lastCheckIn = now
        return n
    }

    /// Brings a stored record in line with the status the model actually holds (e.g. set before this
    /// feature existed, or changed in Developer tools). Never invents a stricter status.
    func reconciled(_ r: SelfReportRecord, risk: Risk, setAt: Date?) -> SelfReportRecord {
        if r.risk == risk { return r }
        if risk == .none { return SelfReportRecord() }
        return SelfReportRecord(risk: risk, onset: setAt.map(startOfDay), lastCheckIn: setAt)
    }
}

/// Where the self-report record lives: a JSON file (encrypted while the phone is locked), not UserDefaults.
enum SelfReportFile {
    static let oldDefaultsKey = "selfReportRecord"

    /// The saved record. If there is no file yet but the old UserDefaults entry exists, it is moved into the
    /// file and the old entry is deleted (only after the file was written). Nil when there is nothing saved.
    static func load(url: URL, defaults: UserDefaults) -> SelfReportRecord? {
        if let data = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(SelfReportRecord.self, from: data) { return r }
        guard let old = defaults.data(forKey: oldDefaultsKey) else { return nil }
        guard let r = try? JSONDecoder().decode(SelfReportRecord.self, from: old) else {
            defaults.removeObject(forKey: oldDefaultsKey)  // unreadable: don't keep health data around
            return nil
        }
        if save(r, to: url) { defaults.removeObject(forKey: oldDefaultsKey) }
        return r
    }

    @discardableResult
    static func save(_ r: SelfReportRecord, to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(r) else { return false }
        do { try data.write(to: url, options: [.atomic, .completeFileProtection]); return true } catch { return false }
    }
}
