import SwiftUI

/// Lisa's tissue alert (design pass; frames in heatmap/assets/tissue-alert/, same as the web phone mock).
///
/// Normally the tissue box in the tab bar is empty. When the phone raises an alert (someone within 6 ft
/// may be sick, or a close contact), a tissue pops out of the box on the Today tab and wiggles. Dragging it
/// up pulls it out: her pull frames follow the finger (hard cuts, like hand animation), and letting go past
/// halfway finishes the pull until the tissue becomes a sheet of paper with the alert on it; before that it
/// slips back. VoiceOver gets the same as a button action. "Got it" puts it away until a different alert; after an all-clear, the next
/// alert pops again. Reduce Motion skips straight to the sheet.
///
/// Every layer is 650 x 1123 and covers the screen width from the top of the sheet down to the bottom of
/// the tab bar, so it lines up with the box in `TissueTabBar`. The layers only hold what differs from the
/// empty box. The alert also stays on the Today screen and in the notification, so nothing depends on
/// finding the tissue.
struct TissueAlert: View {
    let level: AlertLevel
    let visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase { case hidden, popped, pulling(Int), open }
    @State private var phase: Phase = .hidden
    @State private var readLevel: AlertLevel? = nil
    @State private var wiggle = false
    /// Pull frame (1...6) while a finger drags the tissue up; nil when not dragging.
    @State private var dragFrame: Int?
    @AccessibilityFocusState private var sheetFocused: Bool

    private static let aspect: CGFloat = 650.0 / 1123.0
    private static let frameMs = 120 // Lisa: a little slower

    var body: some View {
        let w = TissueTabBar.width, h = w / Self.aspect
        ZStack(alignment: .topLeading) {
            if case .open = phase {
                // Dim the screen above the tab bar while the sheet is out.
                Theme.paper.opacity(0.72)
                    .frame(width: w, height: UIScreen.main.bounds.height - TissueTabBar.height)
                    .offset(y: h - UIScreen.main.bounds.height)
                    .onTapGesture {}   // swallow taps behind the sheet
            }
            // Popped: only the tissue wiggles, about its base; the box rim it pokes out of is a separate, still layer
            // (rotating one layer that held both shook the back of the box).
            Image(art).resizable().frame(width: w, height: h)
                .rotationEffect(.degrees(isPopped && dragFrame == nil && wiggle && !reduceMotion ? 1.0 : 0),
                                anchor: UnitPoint(x: 0.5, y: 0.92))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            // The rim goes ON TOP of the tissue, so the tissue's base tucks behind it and no gap opens at a bottom
            // corner while it wiggles.
            if isPopped && dragFrame == nil {
                Image("TissueAlertPull0Rim").resizable().frame(width: w, height: h)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            if isPopped { pullHandle(w, h) }
            if case .open = phase { note(w, h) }
        }
        .frame(width: w, height: h)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(edges: .bottom)
        .opacity(isShown ? 1 : 0)
        .allowsHitTesting(isShown)
        .onAppear(perform: sync)
        .onChange(of: level) { _, _ in sync() }
        .onChange(of: visible) { _, _ in sync() }
    }

    private var isShown: Bool { if case .hidden = phase { return false }; return true }
    private var isPopped: Bool { if case .popped = phase { return true }; return false }
    private var art: String {
        switch phase {
        case .hidden: return "TissueAlertPull0Tissue"
        case .popped: return dragFrame.map { "TissueAlertPull\($0)" } ?? "TissueAlertPull0Tissue"
        case .pulling(let i): return "TissueAlertPull\(i)"
        case .open: return "TissueAlertSheet"
        }
    }

    private func sync() {
        if level == .none { readLevel = nil }
        switch phase {
        case .pulling, .open:
            if !visible || level == .none { phase = .hidden }
        default:
            let want = visible && level != .none && level != readLevel
            phase = want ? .popped : .hidden
            if want && !reduceMotion {
                withAnimation(.easeInOut(duration: 0.18).repeatForever(autoreverses: true).delay(0.6)) { wiggle = true }
            }
        }
    }

    /// Finishes a pull from frame `from` (0 = not started), e.g. after the finger lets go past halfway.
    private func pull(from: Int = 0) {
        guard isPopped else { return }
        dragFrame = nil
        if reduceMotion { phase = .open; sheetFocused = true; return }
        Task { @MainActor in
            for i in max(1, from + 1)...6 {
                phase = .pulling(i)
                try? await Task.sleep(for: .milliseconds(Self.frameMs))
            }
            withAnimation(.easeOut(duration: 0.2)) { phase = .open }
            sheetFocused = true
        }
    }

    /// The drag target over the popped tissue (its drawing spans 20...80% across, 75...88% down). Upward drag
    /// distance picks the pull frame (one frame per `perFrame` points); past frame 3 on release, the pull finishes.
    private func pullHandle(_ w: CGFloat, _ h: CGFloat) -> some View {
        let perFrame = max(h * 0.04, 22)
        return VStack(spacing: 4) {
            Image(systemName: "chevron.up").font(.caption.weight(.bold))
            Text("Pull up").font(.fluni(.footnote, weight: .semibold))
        }
        .foregroundStyle(Theme.fireInk)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().stroke(Theme.fireInk, lineWidth: 1.5))
        .opacity(dragFrame == nil ? 1 : 0)
        .frame(width: w * 0.6, height: h * 0.16)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { v in
                    let up = max(0, -v.translation.height)
                    dragFrame = up < perFrame / 2 ? nil : min(6, max(1, Int(up / perFrame)))
                }
                .onEnded { v in
                    let up = max(0, -v.translation.height), fling = -v.predictedEndTranslation.height
                    let frame = min(6, Int(up / perFrame))
                    if frame >= 3 || fling > perFrame * 5 { pull(from: frame) }
                    else { withAnimation(.easeOut(duration: 0.15)) { dragFrame = nil } }
                }
        )
        .offset(x: w * 0.2, y: h * 0.73)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(level == .closeContact ? "New close-contact alert" : "New heads-up alert")
        .accessibilityHint("Pulls out the tissue to read it")
        .accessibilityAction { pull() }
        .accessibilityIdentifier("tissueAlert.pop")
    }

    /// The alert written on the sheet (its paper spans about 4...98% across, 1...81% down).
    private func note(_ w: CGFloat, _ h: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(level == .closeContact ? "CLOSE CONTACT" : "HEADS-UP")
                        .font(.fluni(.caption, weight: .bold)).tracking(0.8).foregroundStyle(Theme.fireInk)
                    Text(Advice.title(level)).font(.fluni(.title2, weight: .semibold)).foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Advice.body(level), id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").accessibilityHidden(true)
                            Text(line)
                        }
                        .font(.fluni(.subheadline)).foregroundStyle(Theme.ink)
                    }
                }
                .padding(8)
                // The sheet's colour, so her fold lines don't run through the words.
                .background(Color(hex: 0xf8e3aa).opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityFocused($sheetFocused)
            Button("Got it") { readLevel = level; withAnimation(.easeOut(duration: 0.15)) { phase = .hidden } }
                .buttonStyle(PrimaryButtonStyle(fill: Theme.ink, text: Theme.paper))
                .accessibilityIdentifier("tissueAlert.ok")
        }
        .frame(width: w * 0.65, height: h * 0.59, alignment: .top)
        .offset(x: w * 0.18, y: h * 0.12)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}
