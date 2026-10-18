import SwiftUI

/// Lisa's opening animation (design pass), drawn frame by frame. When FlUni opens, her tissue-box
/// poster fills the screen; the tissue shrinks into the middle, opening a window onto the app, then her
/// hand-drawn swirl frames play (each one more worn away) while the whole swirl slowly turns, and the
/// last frame fades. About 1.1 s. With Reduce Motion it is a short cross-fade.
///
/// Layers (heatmap/assets/loading/): `IntroCenter` is the green field and tissue box; `IntroFrame1`...4
/// are her swirl frames with the white paint made see-through. Frame 1 + center is exactly her poster.
/// Frames switch with hard cuts, like hand animation; a cross-fade would let the app ghost through.
/// The overlay never takes taps and is hidden from VoiceOver.
struct LaunchIntro: View {
    let onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 poster, 1...4 swirl frames, 5 finished.
    @State private var step = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let turning = step >= 1 && !reduceMotion
            ZStack {
                ZStack {
                    ForEach(1...4, id: \.self) { i in
                        layer("IntroFrame\(i)", w, h)
                            .opacity(visible(i) ? 1 : 0)
                            // Only the last frame fades out; the others cut.
                            .animation(i == 4 ? Animation.easeOut(duration: 0.16) : nil, value: step)
                    }
                }
                .rotationEffect(.degrees(turning ? 4 : 0))
                .scaleEffect(turning ? 1.15 : 1)
                .opacity(reduceMotion && step >= 5 ? 0 : 1)
                .animation(reduceMotion ? .easeOut(duration: 0.3) : .timingCurve(0.4, 0, 0.2, 1, duration: 0.75), value: turning || step >= 5)

                layer("IntroCenter", w, h)
                    .scaleEffect(turning ? 0.15 : 1)
                    .rotationEffect(.degrees(turning ? 20 : 0))
                    .opacity(step >= 1 ? 0 : 1)
                    .animation(reduceMotion ? .easeOut(duration: 0.3) : .timingCurve(0.55, 0, 0.8, 0.2, duration: 0.4), value: step >= 1)
            }
            .frame(width: w, height: h)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task { await play() }
    }

    /// Frame 1 shows from the start (under the center it is the poster) until frame 2 takes over.
    private func visible(_ i: Int) -> Bool {
        if reduceMotion { return i == 1 && step < 5 }
        return i == max(step, 1) && step < 5
    }

    private func play() async {
        // Hold the poster for a beat so the app has rendered underneath.
        try? await Task.sleep(for: .milliseconds(450))
        if reduceMotion {
            step = 5
            try? await Task.sleep(for: .milliseconds(350))
            onDone()
            return
        }
        // Timings in ms before each step: the tissue shrinks, then frames 2, 3, 4 at ~10 fps, then fade.
        for (wait, next) in [(0, 1), (250, 2), (100, 3), (100, 4), (130, 5)] {
            if wait > 0 { try? await Task.sleep(for: .milliseconds(wait)) }
            step = next
        }
        try? await Task.sleep(for: .milliseconds(250))
        onDone()
    }

    /// All layers are cropped the same way (fill the screen, centred), so they always line up.
    private func layer(_ name: String, _ w: CGFloat, _ h: CGFloat) -> some View {
        Image(name).resizable().scaledToFill().frame(width: w, height: h)
    }
}
