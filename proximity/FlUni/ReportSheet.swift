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
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stamped = false   // Lisa's "Self-reported" stamp lands before the sheet closes

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
            .overlay { stampOverlay }
            // Closes 0.8 s after the stamp lands. A task, so it's cancelled if the sheet goes away first.
            .task(id: stamped) {
                guard stamped else { return }
                try? await Task.sleep(for: .milliseconds(800))
                if !Task.isCancelled { dismiss() }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .confirmationDialog("Tell nearby phones you tested positive?", isPresented: $confirmPositive, titleVisibility: .visible) {
                Button("Share that I tested positive", role: .destructive) { submit() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Phones near you will see \"contagious\" (nothing else about you) and may alert their owners. Staying home is the best thing you can do now.")
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
                Text("Tap every sticker that fits. One is enough.").font(.fluni(.note)).foregroundStyle(Theme.ink2)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.ink)
        // Two columns of tick boxes; one column when large text needs the width.
        LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: Space.xs), GridItem(.flexible())],
                  alignment: .leading, spacing: Space.xs) {
            ForEach(Symptom.allCases, id: \.self) { sticker($0) }
        }
        DatePicker("When did it start?", selection: $date, in: ...Date(), displayedComponents: .date)
            .font(.fluni(.heading)).foregroundStyle(Theme.ink)
            .frame(minHeight: 44)
        sharedBox("Phones near you will only see \"possibly sick\". Your symptoms, the date and your name are never shared. They stay on this phone.")
    }

    /// One control: Lisa's sticker for the symptom, with a tick box and the word under it. Picked = ink tick,
    /// a 2 pt ink edge and a slight tilt of the sticker (no tilt with Reduce Motion); never colour alone.
    private func sticker(_ s: Symptom) -> some View {
        let on = picked.contains(s)
        let lift = on && !reduceMotion
        return Button { if on { picked.remove(s) } else { picked.insert(s) } } label: {
            VStack(alignment: .leading, spacing: Space.xs) {
                Image(s.art).resizable().scaledToFit()
                    .frame(height: typeSize.isAccessibilitySize ? 96 : 72)
                    .rotationEffect(.degrees(lift ? -6 : 0))
                    .scaleEffect(lift ? 1.06 : 1)
                    .padding(Space.xxs)   // room for the tilt, so the drawing never clips
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Tick(on: on)
                    Text(s.label).font(on ? .fluni(.strong) : .fluni(.reading)).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(Space.s)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(on ? Theme.surface2 : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                .stroke(on ? Theme.ink : Theme.hairline, lineWidth: on ? Theme.selectedStroke : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.6), value: on)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(s.label)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("symptom.\(s.rawValue)")
    }

    /// Lisa's "Self-reported" stamp, pressed onto the sheet after a symptoms report is saved, large enough to read.
    private var stampOverlay: some View {
        ZStack {
            if stamped {
                Theme.paper.opacity(0.7).ignoresSafeArea().transition(.opacity)
                VStack(spacing: Space.s) {
                    Image("StampSelfReported").resizable().scaledToFit().frame(width: 220)
                        .rotationEffect(.degrees(reduceMotion ? 0 : -12))
                        .accessibilityHidden(true)
                    Text("Saved. Phones near you now see \"possibly sick\".").font(.fluni(.heading)).foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                }
                .padding(Space.l)
                .transition(reduceMotion ? .opacity : .scale(scale: 1.8).combined(with: .opacity))
                .accessibilityElement(children: .combine)
            }
        }
        .allowsHitTesting(false)
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
            case .symptoms:
                try store.symptoms(picked, onset: date, model: model)
                // Saved: the stamp shows for a moment, then the sheet closes (the .task above). Straight away with Reduce Motion.
                if reduceMotion { dismiss() } else { withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { stamped = true } }
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
