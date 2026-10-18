import SwiftUI

/// Lisa's tissue alert (design pass; frames in heatmap/assets/tissue-alert/, same as the web phone mock).
///
/// Normally the tissue box in the tab bar is empty. When the phone raises an alert (someone within 6 ft
/// may be sick, or a close contact), a tissue pops out of the box on the Today tab and sways gently. Dragging it
/// up pulls it out: her pull frames follow the finger (hard cuts, like hand animation), and letting go past
/// halfway finishes the pull until the tissue becomes a sheet of paper with the alert on it; before that it
/// slips back. VoiceOver gets the same as a button action. "Got it" (or dragging the sheet back down) plays the
/// pull in reverse and puts it away until a different alert; after an all-clear, the next alert pops again.
/// Reduce Motion skips the frames both ways.
///
/// Every layer is 650 x 1123 and covers the screen width from the top of the sheet down to the bottom of
/// the tab bar, so it lines up with the box in `TissueTabBar`. The layers only hold what differs from the
/// empty box. The alert also stays on the Today screen and in the notification, so nothing depends on
/// finding the tissue.
struct TissueAlert: View {
    let level: AlertLevel
    let visible: Bool
    /// flu-persist: whether this level's alert was already read (saved across relaunches), and how to record a read.
    var isRead: (AlertLevel) -> Bool = { _ in false }
    var onRead: (AlertLevel) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase { case hidden, popped, pulling(Int), open }
    @State private var phase: Phase = .hidden
    @State private var readLevel: AlertLevel? = nil
    /// Pull frame (1...6) while a finger drags the tissue up; nil when not dragging.
    @State private var dragFrame: Int?
    /// Pull frame (6...1) while a finger pushes the open sheet back down; nil when not dragging.
    @State private var pushFrame: Int?
    @AccessibilityFocusState private var sheetFocused: Bool

    private static let aspect: CGFloat = 650.0 / 1123.0
    private static let frameMs = 120 // Lisa: a little slower
    /// After the finger lets go past halfway, the frames it didn't reach play this fast, so the text is
    /// readable as soon as the paper is out.
    private static let finishMs = 45
    /// Where the tissue meets the slot in the tab bar's box, as a fraction of the layer's height (row 976 of 1123);
    /// the wiggle turns about it.
    private static let slotLine: CGFloat = 976.0 / 1123.0
    /// The front edge of that slot (row 988). Nothing in these layers is drawn below it: the box's own front
    /// (in `TissueTabBar`) is the only one, so no copy of the box from these frames can sit on top of it.
    private static let trimLine: CGFloat = 988.0 / 1123.0
    /// The popped tissue's wiggle: a gentle sway either side of upright, about its base in the slot.
    private static let wiggleDegrees = 0.4
    private static let wiggleSwing = 1.3 // seconds from one side to the other

    var body: some View {
        let w = TissueTabBar.width, h = w / Self.aspect
        ZStack(alignment: .topLeading) {
            // The paper moves as one piece: the art, the "Pull up" handle and the alert written on the sheet share
            // one frame and one rotation, so nothing on it stands still while it sways.
            // The sway is computed from the clock (not a phaseAnimator: its animation also cross-faded the frame
            // swaps inside it, so the pull and the put-back blurred instead of cutting).
            TimelineView(.animation(paused: !wiggling)) { clock in
                ZStack(alignment: .topLeading) {
                    Image(art).resizable().frame(width: w, height: h)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    if isPopped { pullHandle(w, h) }
                    if case .open = phase { note(w, h) }
                }
                .frame(width: w, height: h, alignment: .topLeading)
                .rotationEffect(.degrees(wiggling ? Self.sway(at: clock.date) : 0), anchor: UnitPoint(x: 0.5, y: Self.slotLine))
            }
            // Trim after the rotation, so a swaying corner can't dip below the slot either.
            .mask(alignment: .top) { Rectangle().frame(width: w, height: h * Self.trimLine) }
            // The rim goes ON TOP of the tissue, so the tissue's base tucks behind it while it wiggles.
            if (isPopped && dragFrame == nil) || isPulling(0) {
                Image("TissueAlertPull0Rim").resizable().frame(width: w, height: h)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .frame(width: w, height: h)
        // Dim the screen around the box while the sheet is out: everything but the box drawing itself, so no
        // undimmed strip is left between a straight dim edge and the box's sloping top. A background, so it
        // can't change the layer's size: as a child of the ZStack it made the stack taller than the frame,
        // which centred everything and lifted the sheet's copy of the box top about 20 pt above the real box.
        .background(alignment: .bottom) {
            if case .open = phase, pushFrame == nil {
                Theme.paper.opacity(0.72)
                    .overlay(alignment: .bottom) {
                        Image("TabBarBox").resizable().frame(width: w, height: TissueTabBar.height).blendMode(.destinationOut)
                    }
                    .compositingGroup()
                    .frame(width: w, height: UIScreen.main.bounds.height)
                    .contentShape(Rectangle())
                    .onTapGesture {}   // swallow taps behind the sheet
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(edges: .bottom)
        .opacity(isShown ? 1 : 0)
        .allowsHitTesting(isShown)
        .onAppear(perform: sync)
        .onChange(of: level) { _, _ in sync() }
        .onChange(of: visible) { _, _ in sync() }
    }

    /// How far the popped tissue (top of its drawing at row 854 of 1123) rises above the tab bar's frame.
    static var poppedRise: CGFloat {
        max(TissueTabBar.width / aspect * (1 - 854.0 / 1123.0) - TissueTabBar.height, 0)
    }

    /// Degrees of sway at a moment: a slow sine, one side to the other every `wiggleSwing` seconds.
    private static func sway(at date: Date) -> Double {
        sin(date.timeIntervalSinceReferenceDate * .pi / wiggleSwing) * wiggleDegrees
    }

    private var wiggling: Bool { isPopped && dragFrame == nil && !reduceMotion }
    private var isShown: Bool { if case .hidden = phase { return false }; return true }
    private var isPopped: Bool { if case .popped = phase { return true }; return false }
    private func isPulling(_ i: Int) -> Bool { if case .pulling(i) = phase { return true }; return false }
    private var art: String {
        switch phase {
        case .hidden: return "TissueAlertPull0Tissue"
        case .popped: return dragFrame.map { "TissueAlertPull\($0)" } ?? "TissueAlertPull0Tissue"
        case .pulling(let i): return i == 0 ? "TissueAlertPull0Tissue" : "TissueAlertPull\(i)"
        case .open: return pushFrame.map { "TissueAlertPull\($0)" } ?? "TissueAlertSheet"
        }
    }

    private func sync() {
        if level == .none { readLevel = nil }
        switch phase {
        case .pulling, .open:
            if !visible || level == .none { phase = .hidden }
        default:
            let want = visible && level != .none && level != readLevel && !isRead(level)  // flu-persist: isRead
            phase = want ? .popped : .hidden
        }
    }

    /// Finishes a pull from frame `from` (0 = not started), e.g. after the finger lets go past halfway.
    private func pull(from: Int = 0) {
        guard isPopped else { return }
        dragFrame = nil
        if reduceMotion { phase = .open; sheetFocused = true; return }
        Task { @MainActor in
            // Only the frames the finger didn't reach, quickly; none if it reached the last one. `stride`, not a
            // closed range, so from 6 plays nothing. Then the sheet and its text at once, no fade.
            for i in stride(from: max(1, from + 1), through: 6, by: 1) {
                phase = .pulling(i)
                try? await Task.sleep(for: .milliseconds(Self.finishMs))
            }
            phase = .open
            sheetFocused = true
        }
    }

    /// The pull in reverse, at the pull's own frame rate with hard cuts: from the sheet (or the frame a push
    /// down reached) back through the frames to the tissue in the box, then away (it has been read).
    private func putBack(from: Int = 7) {
        guard case .open = phase else { return }
        readLevel = level
        pushFrame = nil
        if reduceMotion { phase = .hidden; return }
        Task { @MainActor in
            for i in stride(from: min(from, 7) - 1, through: 0, by: -1) {
                phase = .pulling(i)
                try? await Task.sleep(for: .milliseconds(Self.frameMs))
            }
            if isPulling(0) { phase = .hidden }
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
                    // A fling counts only after a real pull (a frame's worth), so a quick nudge snaps back.
                    if frame >= 3 || (frame >= 1 && fling > perFrame * 5) { pull(from: frame) }
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

    /// The alert written on the sheet (its paper spans about 4...98% across, 1...81% down). It never scrolls: when
    /// the whole advice doesn't fit (long close-contact advice, large text), the sheet keeps the title and as many
    /// lines as fit, and says the rest is on Today, one tap ("Got it") away. VoiceOver always hears all of it.
    private func note(_ w: CGFloat, _ h: CGFloat) -> some View {
        let lines = Advice.body(level)
        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .vertical) {
                ForEach(Array(stride(from: lines.count, through: 0, by: -1)), id: \.self) { n in
                    noteText(Array(lines.prefix(n)), more: n < lines.count)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(([level == .closeContact ? "Close contact" : "Heads-up", Advice.title(level)] + lines).joined(separator: ". "))
            .accessibilityFocused($sheetFocused)
            // Got it closes at once (no reverse, no fade; the owner asked) and records the alert as read, saved
            // across a relaunch. Dragging the sheet down still runs the pull in reverse.
            Button("Got it") { readLevel = level; onRead(level); phase = .hidden }
                .buttonStyle(PrimaryButtonStyle(fill: Theme.ink, text: Theme.paper))
                .accessibilityIdentifier("tissueAlert.ok")
        }
        // Hide only the words while pushing: the frame keeps its content shape, so the drag keeps going.
        .opacity(pushFrame == nil ? 1 : 0)
        .frame(width: w * 0.65, height: h * 0.59, alignment: .top)
        .contentShape(Rectangle())
        // Dragging the sheet down pushes it back in: frames follow the finger, like the pull.
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { v in
                    let down = max(0, v.translation.height), perFrame = max(h * 0.04, 22)
                    pushFrame = down < perFrame / 2 ? nil : max(1, 6 - Int(down / perFrame))
                }
                .onEnded { v in
                    let perFrame = max(h * 0.04, 22)
                    let frame = max(1, 6 - Int(max(0, v.translation.height) / perFrame))
                    if frame <= 3 || (frame <= 5 && v.predictedEndTranslation.height > perFrame * 5) { putBack(from: frame) }
                    else { pushFrame = nil }
                }
        )
        .offset(x: w * 0.18, y: h * 0.12)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func noteText(_ lines: [String], more: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(level == .closeContact ? "CLOSE CONTACT" : "HEADS-UP")
                .font(.fluni(.caption, weight: .bold)).tracking(0.8).foregroundStyle(Theme.fireInk)
            Text(Advice.title(level)).font(.fluni(.title2, weight: .semibold)).foregroundStyle(Theme.ink)
                .minimumScaleFactor(lines.isEmpty ? 0.5 : 1)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                    Text(line)
                }
                .font(.fluni(.subheadline)).foregroundStyle(Theme.ink)
            }
            if more {
                Text("More advice on Today.").font(.fluni(.footnote, weight: .semibold)).foregroundStyle(Theme.ink2)
            }
        }
        .padding(8)
        // The sheet's colour, so her fold lines don't run through the words.
        .background(Color(hex: 0xf8e3aa).opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
    }
}
