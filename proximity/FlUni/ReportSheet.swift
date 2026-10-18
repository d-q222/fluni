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
    @State private var stamped = false   // Lisa's "Self-reported" stamp lands before the sheet closes
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

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
            .overlay { stampOverlay }
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
        Image("FeelingSick").resizable().scaledToFit().frame(maxHeight: 140)
            .frame(maxWidth: .infinity).accessibilityHidden(true)  // Lisa's illustration
        Text("What are you feeling?").font(.fluni(.headline)).foregroundStyle(Theme.ink)
            .accessibilityAddTraits(.isHeader)
        Text("Tap every sticker that fits.").font(.fluni(.subheadline)).foregroundStyle(Theme.ink2)
        // Sticker grid (design pass): one of Lisa's tissue drawings per symptom, always with its word.
        // Two columns, one at accessibility text sizes so labels never truncate.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: typeSize.isAccessibilitySize ? 1 : 2),
                  spacing: 10) {
            ForEach(Symptom.allCases, id: \.self) { s in sticker(s) }
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

    /// A symptom sticker. Picked = peach box, a check badge, and a small tilt; never colour alone, so it
    /// reads the same under Increase Contrast (flat cards) and Differentiate Without Color.
    private func sticker(_ s: Symptom) -> some View {
        let on = picked.contains(s)
        return Button { if on { picked.remove(s) } else { picked.insert(s) } } label: {
            VStack(spacing: 6) {
                Image(s.art).resizable().scaledToFit()
                    .frame(height: 76)
                    .rotationEffect(.degrees(on && !reduceMotion ? -5 : 0))
                    .scaleEffect(on && !reduceMotion ? 1.06 : 1)
                    .accessibilityHidden(true)
                Text(s.label).font(.fluni(.subheadline, weight: on ? .semibold : .regular))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 116)
            .overlay(alignment: .topTrailing) {
                if on {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Theme.paper, Theme.fireInk)
                        .font(.title3)
                        .accessibilityHidden(true)
                }
            }
            .card(on ? CardStyle.peach : CardStyle.paper)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.6), value: on)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(s.label)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("symptom.\(s.rawValue)")
    }

    /// Lisa's "Self-reported" stamp, thumped onto the sheet after a symptoms report is saved.
    /// Always in the hierarchy so the `if` inside the ZStack can animate its insertion.
    private var stampOverlay: some View {
        ZStack {
            if stamped {
                Theme.paper.opacity(0.6).ignoresSafeArea()
                    .transition(.opacity)
                Image("StampSelfReported").resizable().scaledToFit()
                    .frame(width: 220)
                    .rotationEffect(.degrees(-12))
                    .transition(reduceMotion ? .opacity : .scale(scale: 2.2).combined(with: .opacity))
                    .accessibilityLabel("Self-reported")
            }
        }
        .allowsHitTesting(false)
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
            case .symptoms:
                try store.symptoms(picked, onset: date, model: model)
                // Saved: show the stamp for a moment, then close (straight away with Reduce Motion).
                if reduceMotion { dismiss(); return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { stamped = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
                return
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

private extension Symptom {
    /// Lisa's drawing for each symptom (FlUni asset catalog; sources in heatmap/assets/illustrations/symptoms).
    var art: String {
        switch self {
        case .fever: return "SymptomFever"
        case .cough: return "SymptomCough"
        case .soreThroat: return "SymptomSoreThroat"
        case .aches: return "SymptomAches"
        case .fatigue: return "SymptomFatigue"
        case .runnyNose: return "SymptomRunnyNose"
        }
    }
}
