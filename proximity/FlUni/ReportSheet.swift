import SwiftUI

enum ReportKind: String, Identifiable {
    case symptoms, positive, negative
    var id: String { rawValue }
}

/// The detail screen behind "I have symptoms", "I tested positive" and "I tested negative".
struct ReportSheet: View {
    let kind: ReportKind
    @ObservedObject var model: ProximityModel
    @ObservedObject var store: SelfReportStore
    @Environment(\.dismiss) private var dismiss

    @State private var picked: Set<Symptom> = []
    @State private var date = Date()
    @State private var test = TestKind.rapid
    @State private var confirmPositive = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch kind {
                    case .symptoms: symptomsBody
                    case .positive: testBody(question: "When did you test?")
                    case .negative: testBody(question: "When did you test?")
                    }
                    if let error { Text(error).font(.fluni(.footnote)).foregroundStyle(Theme.fireInk)
                        .accessibilityLabel("Problem: \(error)") }
                }
                .padding(16)
            }
            .background(Theme.paper)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .confirmationDialog("Tell nearby phones you tested positive?", isPresented: $confirmPositive, titleVisibility: .visible) {
                Button("Share that I tested positive", role: .destructive) { submit() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("FlUni phones near you will see \"contagious\" (nothing else about you) and may alert their owners. Staying home is the best thing you can do now.")
            }
        }
    }

    private var title: String {
        switch kind {
        case .symptoms: return "I have symptoms"
        case .positive: return "I tested positive"
        case .negative: return "I tested negative"
        }
    }

    // MARK: symptoms

    @ViewBuilder private var symptomsBody: some View {
        Text("What are you feeling?").font(.fluni(.headline)).foregroundStyle(Theme.ink)
            .accessibilityAddTraits(.isHeader)
        VStack(spacing: 8) {
            ForEach(Symptom.allCases, id: \.self) { s in
                let on = picked.contains(s)
                Button { if on { picked.remove(s) } else { picked.insert(s) } } label: {
                    HStack {
                        Text(s.label).font(.fluni(.body))
                        Spacer()
                        Image(systemName: on ? "checkmark.square.fill" : "square").accessibilityHidden(true)
                    }
                    .foregroundStyle(Theme.ink)
                    .frame(minHeight: 28)
                    .card(fill: on ? Theme.surface2 : Theme.surface)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
                .accessibilityIdentifier("symptom.\(s.rawValue)")
            }
        }
        DatePicker("When did it start?", selection: $date, in: ...Date(), displayedComponents: .date)
            .font(.fluni(.body)).foregroundStyle(Theme.ink)
            .frame(minHeight: 44)
        sharedBox("Any one symptom is enough. Phones near you will only see \"possibly sick\". Your symptoms, the date and your name are never shared. They stay on this phone.")
        Button("Set status to possibly sick") { submit() }
            .buttonStyle(PrimaryButtonStyle(fill: Theme.sun))
            .disabled(picked.isEmpty).opacity(picked.isEmpty ? 0.5 : 1)
            .accessibilityIdentifier("report.submit")
            .accessibilityHint(picked.isEmpty ? "Pick at least one symptom first" : "Shares \"possibly sick\" with phones near you")
    }

    // MARK: tests

    @ViewBuilder private func testBody(question: String) -> some View {
        Text("Which test did you take?").font(.fluni(.headline)).foregroundStyle(Theme.ink)
            .accessibilityAddTraits(.isHeader)
        Picker("Test type", selection: $test) {
            ForEach(TestKind.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        DatePicker(question, selection: $date, in: ...Date(), displayedComponents: .date)
            .font(.fluni(.body)).foregroundStyle(Theme.ink)
            .frame(minHeight: 44)
        if kind == .positive {
            sharedBox("Phones near you will see \"contagious\" and may warn their owners. The test type and date are never shared. They stay on this phone. A test is more reliable than symptoms alone, so nearby phones treat it as a stronger signal.")
            Button("Review and share") { confirmPositive = true }
                .buttonStyle(PrimaryButtonStyle(fill: Theme.fireInk, text: Theme.paper))
                .accessibilityIdentifier("report.submit")
                .accessibilityHint("Asks you to confirm before anything is shared")
        } else {
            sharedBox(negativeNote)
            Button("Save negative result") { submit() }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("report.submit")
        }
    }

    private var negativeNote: String {
        switch model.myRisk {
        case .possible: return "This sets you back to healthy. A single rapid negative test isn't conclusive, especially in the first days. If you still feel sick, test again in 1 to 2 days or visit Vaden."
        case .contagious: return "You tested positive earlier, so a negative test won't clear your status. It changes once your isolation period is over."
        case .none: return "You're already shown as healthy, so nothing changes. Nothing about the test is shared."
        }
    }

    private func sharedBox(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(Theme.ink2).accessibilityHidden(true)
            Text(text).font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
        }
        .card(fill: Theme.surface2)
        .accessibilityElement(children: .combine)
    }

    private func submit() {
        do {
            switch kind {
            case .symptoms: try store.symptoms(picked, onset: date, model: model)
            case .positive: try store.positive(test, date: date, model: model)
            case .negative: try store.negative(test, date: date, model: model)
            }
            dismiss()
        } catch ReportError.dateInFuture {
            error = "That date is in the future. Pick today or earlier."
        } catch ReportError.noSymptoms {
            error = "Pick at least one symptom."
        } catch {
            self.error = "Couldn't save that. Please try again."
        }
    }
}
