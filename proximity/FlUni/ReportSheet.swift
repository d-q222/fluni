import SwiftUI

/// Where the report sheet opens: the first question, or straight at one answer's details (from You).
enum ReportStart: String, Identifiable, Hashable {
    case choose, symptoms, positive, negative
    var id: String { rawValue }
}

/// "I don't feel well", as one sheet in two steps (C-6, then C-7 / D-6):
///   1. How are you feeling? I feel fine / I have symptoms / I tested positive / I tested negative.
///   2. The details: Lisa's symptom stickers and the day they started ("That makes today Day N"), or the test
///      and its date. Saving symptoms presses Lisa's SELF-REPORTED stamp onto the sheet, then it closes.
/// Nearby phones only ever see the 3-level status; symptoms, dates and test kinds stay on this phone.
struct ReportFlow: View {
    let start: ReportStart
    let model: ProximityModel
    @ObservedObject private var feed = ModelFeed.shared
    @ObservedObject var store: SelfReportStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var path: [ReportStart] = []
    @State private var stamped = false
    @State private var blocked: String?

    var body: some View {
        NavigationStack(path: $path) {
            ChooseStep(model: model, store: store, pick: pick)
                .navigationDestination(for: ReportStart.self) { step in
                    Group {
                        switch step {
                        case .symptoms: SymptomsStep(model: model, store: store, saved: saved)
                        case .positive, .negative: TestStep(positive: step == .positive, model: model, store: store, saved: { dismiss() })
                        case .choose: EmptyView()
                        }
                    }
                    .toolbar { close }  // every step can close the sheet, not only the first
                }
                .toolbar { close }
        }
        .tint(Theme.ink)
        .overlay { stampOverlay }
        .onAppear { if start != .choose && path.isEmpty { path = [start] } }
        // Closes a moment after the stamp lands. A task, so it's cancelled if the sheet goes away first.
        .task(id: stamped) {
            guard stamped else { return }
            var hold = 800
            #if DEBUG
            if PreviewHook.autoSubmit { hold = 60_000 }  // screenshots: keep the stamp on screen
            #endif
            try? await Task.sleep(for: .milliseconds(hold))
            if !Task.isCancelled { dismiss() }
        }
        .alert("Can't change that yet", isPresented: Binding(get: { blocked != nil }, set: { if !$0 { blocked = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(blocked ?? "") }
    }

    private var close: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.surface2).frame(width: 36, height: 36))
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("report.close")
        }
    }

    private func pick(_ s: ReportStart) {
        guard s == .choose else { path = [s]; return }
        // "I feel fine": nothing to fill in.
        if feed.myRisk == .none { dismiss(); return }
        do { try store.feelFine(model: model); dismiss() } catch {
            blocked = "You tested positive, so you stay marked contagious until your \(IsolationPolicy.days) days are up and you've had no fever for \(Int(IsolationPolicy.feverFreeHours)) hours. Today will ask you then."
        }
    }

    /// Saved: show the stamp for a moment, then close (straight away with Reduce Motion).
    private func saved() {
        if reduceMotion { dismiss(); return }
        withAnimation(FlMotion.stamp) { stamped = true }
    }

    /// Lisa's "Self-reported" stamp, thumped onto the sheet after a symptoms report is saved (her stamp moment,
    /// as she made it). Always in the hierarchy so the `if` inside the ZStack can animate its insertion.
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
                    .accessibilityIdentifier("report.stamp")
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: Step 1

private struct ChooseStep: View {
    let model: ProximityModel
    @ObservedObject private var feed = ModelFeed.shared
    @ObservedObject var store: SelfReportStore
    let pick: (ReportStart) -> Void

    private struct Choice {
        let id: ReportStart
        let title: String
        let detail: String
        let art: String?
        let shares: Risk?
    }

    private var choices: [Choice] {
        [Choice(id: .choose, title: "I feel fine", detail: feed.myRisk == .none ? "Nothing changes. Nearby phones see \"healthy\"." : "Sets you back to \"healthy\".", art: "Tissue", shares: Risk.none),
         Choice(id: .symptoms, title: "I have symptoms", detail: "Nearby phones see \"possibly sick\"", art: "SymptomCough", shares: .possible),
         Choice(id: .positive, title: "I tested positive", detail: "Rapid or PCR, plus the date", art: "StampSelfReported", shares: .contagious),
         Choice(id: .negative, title: "I tested negative", detail: "Clears \"possibly sick\" if the test came after your symptoms", art: nil, shares: nil)]
    }

    private func isCurrent(_ c: Choice) -> Bool { c.shares == feed.myRisk }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                StepHeader(step: 1, title: "How are you feeling?", subtitle: "Pick the one that fits. You can change it any time.")
                VStack(spacing: Space.s) {
                    ForEach(choices, id: \.title) { row($0) }
                }
            }
            .padding(.horizontal, Space.m).padding(.bottom, Space.l)
        }
        .safeAreaInset(edge: .bottom) {
            PrivacyNote(text: "Nearby phones only ever see one of three words: healthy, possibly sick or contagious. Never your symptoms or dates.")
                .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                .background(Theme.paper)
        }
        .background(Theme.paper)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ c: Choice) -> some View {
        let current = isCurrent(c)
        return Button { pick(c.id) } label: {
            HStack(spacing: Space.s) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Theme.surface2)
                    if let art = c.art {
                        Image(art).resizable().scaledToFit().padding(6)
                    } else {
                        Image(systemName: "checkmark.circle").font(.system(size: 26, weight: .regular)).foregroundStyle(Theme.ink)
                    }
                }
                .frame(width: 58, height: 58)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(c.title).font(.fluni(.strong))
                    Text(current ? "Your status now. " + c.detail : c.detail).font(.fluni(.note)).foregroundStyle(Theme.ink2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold)).foregroundStyle(Theme.ink2)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Theme.ink)
            .padding(Space.s)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(current ? Theme.ink : Theme.ink.opacity(0.18), lineWidth: current ? Theme.selectedStroke : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("choose.\(c.id == .choose ? "fine" : c.id.rawValue)")
    }
}

// MARK: Step 2: symptoms

private struct SymptomsStep: View {
    let model: ProximityModel
    @ObservedObject private var feed = ModelFeed.shared
    @ObservedObject var store: SelfReportStore
    let saved: () -> Void
    @State private var picked: Set<Symptom> = []
    @State private var onset = Calendar.current.startOfDay(for: Date())
    @State private var error: String?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var columns: [GridItem] {
        let n = typeSize >= .accessibility3 ? 1 : typeSize.isAccessibilitySize ? 2 : 3
        return Array(repeating: GridItem(.flexible(), spacing: Space.s), count: n)
    }

    var body: some View {
        let r = store.reporter
        let day = r.dayCount(from: onset, now: Date())
        let last = r.lastDay(from: onset)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                StepHeader(step: 2, title: "What's going on?", subtitle: nil)
                Text("Tap the stickers that fit. One is plenty.").font(.fluni(.voice)).foregroundStyle(Theme.ink2)
                    .padding(.top, -Space.m)
                LazyVGrid(columns: columns, spacing: Space.s) {
                    ForEach(Symptom.allCases, id: \.self) { sticker($0) }
                }
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("When did it start?").font(.fluni(.heading)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                    DayChips(date: $onset)
                    Text("That makes today Day \(day). Home through \(last.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).")
                        .font(.fluni(.note)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("report.dayLine")
                }
                if let error { Text(error).font(.fluni(.note).weight(.semibold)).foregroundStyle(Theme.fireInk) }
            }
            .padding(.horizontal, Space.m).padding(.bottom, Space.l)
        }
        .footer {
            VStack(alignment: .leading, spacing: Space.s) {
                PrivacyNote(text: "Nearby phones will only see \"possibly sick\". Never which stickers you picked.")
                Button("Report and start staying home") { submit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(picked.isEmpty)
                    .accessibilityIdentifier("report.submit")
                    .accessibilityHint(picked.isEmpty ? "Pick at least one sticker first" : "Shares \"possibly sick\" with phones near you")
            }
            .padding(.horizontal, Space.m).padding(.top, Space.s).padding(.bottom, Space.xs)
            .background(Theme.paper)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .background(Theme.paper)
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        .onAppear {
            guard PreviewHook.pickSymptoms else { return }
            picked = [.fever, .cough]
            onset = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
            if PreviewHook.autoSubmit { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { submit() } }
        }
        #endif
    }

    /// One sticker: Lisa's drawing and its word. Picked = a 2.5 pt ink edge, an ink tick badge and a small tilt
    /// (no tilt with Reduce Motion). Never colour alone; unpicked words stay full ink.
    private func sticker(_ s: Symptom) -> some View {
        let on = picked.contains(s)
        let tilt = on && !reduceMotion
        return Button { if on { picked.remove(s) } else { picked.insert(s) } } label: {
            VStack(spacing: Space.xs) {
                Image(s.art).resizable().scaledToFit()
                    .frame(height: typeSize.isAccessibilitySize ? 96 : 70)
                    .accessibilityHidden(true)
                Text(s.short).font(on ? .fluni(.strong) : .fluni(.reading)).foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Space.s).padding(.horizontal, Space.xs)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(on ? Theme.surface : Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(on ? Theme.ink : Theme.ink.opacity(0.22), lineWidth: on ? 2.5 : 1.25))
            .overlay(alignment: .topTrailing) {
                if on {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(Theme.paper)
                        .frame(width: 26, height: 26).background(Circle().fill(Theme.ink))
                        .offset(x: 6, y: -6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .rotationEffect(.degrees(tilt ? -2.5 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .animation(FlMotion.quick(reduceMotion), value: on)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(s.label)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("symptom.\(s.rawValue)")
    }

    private func submit() {
        do {
            try store.symptoms(picked, onset: onset, model: model)
            saved()
        } catch ReportError.dateInFuture {
            error = "That date is in the future. Pick today or earlier."
        } catch ReportError.noSymptoms {
            error = "Pick at least one sticker."
        } catch {
            self.error = "Couldn't save that. Please try again."
        }
    }
}

// MARK: Step 2: a test

private struct TestStep: View {
    let positive: Bool
    let model: ProximityModel
    @ObservedObject private var feed = ModelFeed.shared
    @ObservedObject var store: SelfReportStore
    let saved: () -> Void
    @State private var test = TestKind.rapid
    @State private var date = Calendar.current.startOfDay(for: Date())
    @State private var confirm = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                StepHeader(step: 2, title: positive ? "I tested positive" : "I tested negative", subtitle: nil)
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Which test?").font(.fluni(.heading)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                    ForEach(TestKind.allCases, id: \.self) { k in
                        Button { test = k } label: {
                            HStack(spacing: Space.s) {
                                Radio(on: test == k)
                                Text(k.label).font(test == k ? .fluni(.strong) : .fluni(.reading))
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(Theme.ink)
                            .padding(Space.s)
                            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(test == k ? Theme.ink : Theme.ink.opacity(0.18), lineWidth: test == k ? 2 : 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityAddTraits(test == k ? [.isSelected, .isButton] : .isButton)
                        .accessibilityIdentifier("test.\(k.rawValue)")
                    }
                }
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("When did you test?").font(.fluni(.heading)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                    DayChips(date: $date)
                }
                if let error { Text(error).font(.fluni(.note).weight(.semibold)).foregroundStyle(Theme.fireInk) }
            }
            .padding(.horizontal, Space.m).padding(.bottom, Space.l)
        }
        .footer {
            VStack(alignment: .leading, spacing: Space.s) {
                PrivacyNote(text: positive
                    ? "Nearby phones will see \"contagious\" and may warn their owners. The test and its date stay on this phone."
                    : negativeNote)
                Button(positive ? "Review and share" : "Save negative result") { positive ? (confirm = true) : submit() }
                    .buttonStyle(PrimaryButtonStyle(fill: positive ? Theme.fireInk : Theme.ink))
                    .accessibilityIdentifier("report.submit")
                    .accessibilityHint(positive ? "Asks you to confirm before anything is shared" : "")
            }
            .padding(.horizontal, Space.m).padding(.top, Space.s).padding(.bottom, Space.xs)
            .background(Theme.paper)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .background(Theme.paper)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Tell nearby phones you tested positive?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Share that I tested positive", role: .destructive) { submit() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Phones near you will see \"contagious\" (nothing else about you) and may alert their owners. Staying home is the best thing you can do now.")
        }
    }

    private var negativeNote: String {
        switch feed.myRisk {
        case .possible: return "This sets you back to healthy. One rapid negative test isn't conclusive, especially early on. If you still feel sick, test again in 1 to 2 days or visit Vaden."
        case .contagious: return "You tested positive earlier, so a negative test won't clear your status. It changes once your 5 days are over."
        case .none: return "You're already shown as healthy, so nothing changes. Nothing about the test is shared."
        }
    }

    private func submit() {
        do {
            if positive { try store.positive(test, date: date, model: model) } else { try store.negative(test, date: date, model: model) }
            saved()
        } catch ReportError.dateInFuture {
            error = "That date is in the future. Pick today or earlier."
        } catch {
            self.error = "Couldn't save that. Please try again."
        }
    }
}

// MARK: Shared pieces

/// The step's privacy note and action, pinned above the home indicator. Its text stops growing at AX1: at AX5
/// the pinned bar would otherwise cover most of the screen and leave the stickers no room to scroll.
private struct Footer<F: View>: ViewModifier {
    let footer: F
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) { footer.dynamicTypeSize(...DynamicTypeSize.accessibility1) }
    }
}

private extension View {
    func footer<F: View>(@ViewBuilder _ f: () -> F) -> some View { modifier(Footer(footer: f())) }
}

/// "Step 1 of 2" in sentence case, then the question in the serif.
private struct StepHeader: View {
    let step: Int
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Step \(step) of 2").font(.fluni(.note).weight(.semibold)).foregroundStyle(Theme.ink2)
            Text(title).font(.fluni(.display)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).font(.fluni(.reading)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("report.title")
    }
}

/// Today / Yesterday / the day before by name / Earlier (a date picker). Selected = ink fill, paper text.
private struct DayChips: View {
    @Binding var date: Date
    @State private var earlier = false
    private let cal = Calendar.current

    private var days: [(String, Date)] {
        let today = cal.startOfDay(for: Date())
        let d1 = cal.date(byAdding: .day, value: -1, to: today)!
        let d2 = cal.date(byAdding: .day, value: -2, to: today)!
        return [("Today", today), ("Yesterday", d1), (d2.formatted(.dateTime.weekday(.abbreviated)), d2)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.xs) { chips }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.xs), GridItem(.flexible())], alignment: .leading, spacing: Space.xs) { chips }
            }
            if earlier {
                DatePicker("Pick the day", selection: $date, in: ...Date(), displayedComponents: .date)
                    .font(.fluni(.reading)).foregroundStyle(Theme.ink)
                    .frame(minHeight: 44)
            }
        }
    }

    @ViewBuilder private var chips: some View {
        ForEach(days, id: \.1) { label, d in
            chip(label, on: !earlier && cal.isDate(date, inSameDayAs: d)) { earlier = false; date = d }
        }
        chip("Earlier", on: earlier) { earlier = true; date = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: Date()))! }
    }

    private func chip(_ label: String, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(label).font(.fluni(on ? .strong : .reading))
                .foregroundStyle(on ? Theme.paper : Theme.ink)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Space.m)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(Capsule().fill(on ? Theme.ink : Theme.surface))
                .overlay(Capsule().stroke(Theme.ink.opacity(on ? 1 : 0.35), lineWidth: 1.25))
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("day.\(label)")
    }
}

/// A quiet panel with a lock: what is and isn't shared.
private struct PrivacyNote: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: "lock").font(.system(.footnote, weight: .semibold)).foregroundStyle(Theme.ink).accessibilityHidden(true)
            Text(text).font(.fluni(.fine)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
        }
        .panel()
        .accessibilityElement(children: .combine)
    }
}

private struct Radio: View {
    let on: Bool
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 22
    var body: some View {
        Circle().stroke(Theme.ink, lineWidth: Theme.stroke)
            .overlay { if on { Circle().fill(Theme.ink).padding(size * 0.24) } }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A press state for custom-drawn buttons: a slight dip, nothing else.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

extension Symptom {
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

    /// The word under a sticker; VoiceOver reads the full label.
    var short: String {
        switch self {
        case .fever: return "Fever"
        case .cough: return "Cough"
        case .soreThroat: return "Sore throat"
        case .aches: return "Aches"
        case .fatigue: return "Fatigue"
        case .runnyNose: return "Runny nose"
        }
    }
}
