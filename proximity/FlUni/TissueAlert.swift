import SwiftUI

/// Lisa's tissue alert (design pass; frames in heatmap/assets/tissue-alert/, same as the web phone mock).
///
/// Normally the tissue box in the tab bar is empty. When the phone raises an alert (someone within 6 ft
/// may be sick, or a close contact), a tissue pops out of the box on the Today tab and wiggles. Tapping
/// it plays her pull frames (hard cuts, like hand animation) until the tissue becomes a sheet of paper
/// with the alert on it. "Got it" puts it away until a different alert; after an all-clear, the next
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
            if isPopped {
                Image("TissueAlertPull0Rim").resizable().frame(width: w, height: h)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            Image(art).resizable().frame(width: w, height: h)
                .rotationEffect(.degrees(isPopped && wiggle && !reduceMotion ? 1.6 : 0), anchor: UnitPoint(x: 0.5, y: 0.88))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            if isPopped { popButton(w, h) }
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
        case .hidden, .popped: return "TissueAlertPull0Tissue"
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

    private func pull() {
        guard isPopped else { return }
        if reduceMotion { phase = .open; sheetFocused = true; return }
        Task { @MainActor in
            for i in 1...6 {
                phase = .pulling(i)
                try? await Task.sleep(for: .milliseconds(Self.frameMs))
            }
            withAnimation(.easeOut(duration: 0.2)) { phase = .open }
            sheetFocused = true
        }
    }

    /// The tap target over the popped tissue (its drawing spans 20...80% across, 75...88% down).
    private func popButton(_ w: CGFloat, _ h: CGFloat) -> some View {
        Button(action: pull) {
            Text("Pull me")
                .font(.fluni(.footnote, weight: .semibold))
                .foregroundStyle(Theme.fireInk)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().stroke(Theme.fireInk, lineWidth: 1.5))
                .rotationEffect(.degrees(-3))
                .frame(width: w * 0.6, height: h * 0.13)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: w * 0.2, y: h * 0.75)
        .accessibilityLabel(level == .closeContact ? "New close-contact alert" : "New heads-up alert")
        .accessibilityHint("Pulls out the tissue to read it")
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
