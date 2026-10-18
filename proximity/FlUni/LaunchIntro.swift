import SwiftUI

/// Lisa's opening animation (design pass). When FlUni opens, her tissue-box poster fills the screen;
/// the tissue shrinks into the middle, opening a window onto the app, and then the swirls part like
/// curtains (top up, bottom down). About 1.3 s in all. With Reduce Motion it is a short cross-fade.
///
/// The three layers come from her two drawings (heatmap/assets/loading/): `IntroCenter` is the green
/// field and tissue box, `IntroSwirlTop` and `IntroSwirlBottom` are the swirls split where the opening
/// spans the full width. Stacked, they are exactly her poster. The overlay never takes taps and is
/// hidden from VoiceOver, so it can't get in the way of the app underneath.
struct LaunchIntro: View {
    let onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var open = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let moving = open && !reduceMotion
            ZStack {
                layer("IntroCenter", w, h)
                    .scaleEffect(moving ? 0.15 : 1)
                    .rotationEffect(.degrees(moving ? 20 : 0))
                    .opacity(open ? 0 : 1)
                    .animation(reduceMotion ? .easeOut(duration: 0.3)
                                            : .timingCurve(0.55, 0, 0.8, 0.2, duration: 0.5), value: open)
                layer("IntroSwirlTop", w, h)
                    .scaleEffect(moving ? 1.2 : 1)
                    .rotationEffect(.degrees(moving ? -12 : 0))
                    .offset(x: moving ? -w * 0.06 : 0, y: moving ? -h * 0.7 : 0)
                    .opacity(reduceMotion && open ? 0 : 1)
                    .animation(swirlAnimation, value: open)
                layer("IntroSwirlBottom", w, h)
                    .scaleEffect(moving ? 1.2 : 1)
                    .rotationEffect(.degrees(moving ? 10 : 0))
                    .offset(x: moving ? w * 0.06 : 0, y: moving ? h * 0.7 : 0)
                    .opacity(reduceMotion && open ? 0 : 1)
                    .animation(swirlAnimation, value: open)
            }
            .frame(width: w, height: h)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            // Hold the poster for a beat so the app has rendered underneath, then open.
            try? await Task.sleep(for: .milliseconds(450))
            open = true
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 350 : 1200))
            onDone()
        }
    }

    private var swirlAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.3) : .timingCurve(0.65, 0, 0.35, 1, duration: 0.85).delay(0.25)
    }

    /// All three layers are cropped the same way (fill the screen, centred), so they always line up.
    private func layer(_ name: String, _ w: CGFloat, _ h: CGFloat) -> some View {
        Image(name).resizable().scaledToFill().frame(width: w, height: h)
    }
}
