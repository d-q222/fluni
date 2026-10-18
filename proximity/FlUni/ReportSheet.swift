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
                VStack(alignment: .leading, spacing: Space.l) {
                    switch kind {
                    case .symptoms: symptomsBody
                    case .positive: testBody(question: "When did you test?")
                    case .negative: testBody(question: "When did you test?")
                    }
                    if let error { Text(error).font(.fluni(.note).weight(.semibold)).foregroundStyle(Theme.fireInk)
                        .accessibilityLabel("Problem: \(error)") }
                }
                .padding(.horizontal, Space.m).padding(.top, Space.m).padding(.bottom, Space.l)
            }
            // The one action stays in reach: no scrolling past the form to find it.
            .safeAreaInset(edge: .bottom) {
                submitButton
                    .padding(.horizontal, Space.m).padding(.top, Space.s).padding(.bottom, Space.xs)
                    .background(Theme.paper)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
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

    @ViewBuilder private var submitButton: some View {
        switch kind {
        case .symptoms:
            Button("Set status to possibly sick") { submit() }
                .buttonStyle(PrimaryButtonStyle(fill: Theme.sun))
                .disabled(picked.isEmpty).opacity(picked.isEmpty ? 0.5 : 1)
                .accessibilityIdentifier("report.submit")
                .accessibilityHint(picked.isEmpty ? "Pick at least one symptom first" : "Shares \"possibly sick\" with phones near you")
        case .positive:
            Button("Review and share") { confirmPositive = true }
                .buttonStyle(PrimaryButtonStyle(fill: Theme.fireInk, text: Theme.paper))
                .accessibilityIdentifier("report.submit")
                .accessibilityHint("Asks you to confirm before anything is shared")
        case .negative:
            Button("Save negative result") { submit() }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("report.submit")
        }
    }

    // MARK: symptoms

    @ViewBuilder private var symptomsBody: some View {
        HStack(alignment: .bottom, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("What are you feeling?").font(.fluni(.section)).accessibilityAddTraits(.isHeader)
                Text("Pick any that fit. One is enough.").font(.fluni(.note)).foregroundStyle(Theme.ink2)
            }
            Spacer(minLength: 0)
            Image("FeelingSick").resizable().scaledToFit().frame(width: 96)
                .accessibilityHidden(true)  // Lisa's illustration
        }
        .foregroundStyle(Theme.ink)
        // Two columns of tick boxes; one column when large text needs the width.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Space.xs)], alignment: .leading, spacing: Space.xs) {
            ForEach(Symptom.allCases, id: \.self) { s in
                let on = picked.contains(s)
                Button { if on { picked.remove(s) } else { picked.insert(s) } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Tick(on: on)
                        Text(s.label).font(.fluni(.reading)).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, Space.s).padding(.vertical, Space.s)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .background(on ? Theme.surface2 : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                        .stroke(on ? Theme.ink : Theme.hairline, lineWidth: on ? Theme.selectedStroke : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
                .accessibilityIdentifier("symptom.\(s.rawValue)")
            }
        }
        DatePicker("When did it start?", selection: $date, in: ...Date(), displayedComponents: .date)
            .font(.fluni(.heading)).foregroundStyle(Theme.ink)
            .frame(minHeight: 44)
        sharedBox("Phones near you will only see \"possibly sick\". Your symptoms, the date and your name are never shared. They stay on this phone.")
    }

    // MARK: tests

    @ViewBuilder private func testBody(question: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Which test did you take?").font(.fluni(.section)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Picker("Test type", selection: $test) {
                ForEach(TestKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        DatePicker(question, selection: $date, in: ...Date(), displayedComponents: .date)
            .font(.fluni(.heading)).foregroundStyle(Theme.ink)
            .frame(minHeight: 44)
        if kind == .positive {
            sharedBox("Phones near you will see \"contagious\" and may warn their owners. The test type and date are never shared. They stay on this phone. A test is more reliable than symptoms alone, so nearby phones treat it as a stronger signal.")
        } else {
            sharedBox(negativeNote)
        }
    }

    private var negativeNote: String {
        switch model.myRisk {
        case .possible: return "This sets you back to healthy. A single rapid negative test isn't conclusive, especially in the first days. If you still feel sick, test again in 1 to 2 days or visit Vaden."
        case .contagious: return "You tested positive earlier, so a negative test won't clear your status. It changes once your isolation period is over."
        case .none: return "You're already shown as healthy, so nothing changes. Nothing about the test is shared."
        }
    }

    /// What is and isn't shared, as a quiet panel: an aside, not the point of the form.
    private func sharedBox(_ text: String) -> some View {
        Text(text).font(.fluni(.fine)).foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .panel()
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

/// A drawn-style tick box: ink outline, filled ink with a paper tick when on.
private struct Tick: View {
    let on: Bool
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(on ? Theme.ink : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.ink, lineWidth: Theme.stroke))
            .overlay { if on { Image(systemName: "checkmark").font(.system(size: size * 0.6, weight: .bold)).foregroundStyle(Theme.paper) } }
            .frame(width: size, height: size)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            .accessibilityHidden(true)
    }
}
