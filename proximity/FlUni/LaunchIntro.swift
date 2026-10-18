import SwiftUI
import UIKit

/// Lisa's opening animation (design pass), drawn frame by frame. When FlUni opens, her tissue-box
/// poster fills the screen; the tissue shrinks into the middle, opening a window onto the app, then her
/// hand-drawn swirl frames play (each one more worn away) while the whole swirl slowly turns, and the
/// last frame fades. About 1.1 s. With Reduce Motion it is a short cross-fade.
///
/// Layers (heatmap/assets/loading/): `IntroCenter` is the green field and tissue box; `IntroFrame1`...4
/// are her swirl frames with the white paint made see-through. Frame 1 + center is exactly her poster.
/// Frames switch with hard cuts, like hand animation; a cross-fade would let the app ghost through.
/// The overlay never takes taps and is hidden from VoiceOver.
///
/// `held`: show the still poster and wait. FlUniApp holds it while the app is not yet active (cold launch, and
/// from the moment it goes to the background, so the app-switcher snapshot and the first frame of a warm open
/// are the poster, never the app), then releases it to play from the start.
struct LaunchIntro: View {
    var held = false
    let onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 poster, 1...4 swirl frames, 5 finished.
    @State private var step = 0
    /// Frames 2-4, decoded off the main thread during the poster's hold (IntroArt).
    @State private var swirl: [Int: UIImage] = [:]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let turning = step >= 1 && !reduceMotion
            ZStack {
                ZStack {
                    ForEach(1...4, id: \.self) { i in
                        if let img = i == 1 ? Optional(IntroArt.shared.image("IntroFrame1")) : swirl[i] {
                            layer(img, w, h)
                                .opacity(visible(i) ? 1 : 0)
                                // Only the last frame fades out; the others cut.
                                .animation(i == 4 ? Animation.easeOut(duration: 0.16) : nil, value: step)
                        }
                    }
                }
                .rotationEffect(.degrees(turning ? 4 : 0))
                .scaleEffect(turning ? 1.15 : 1)
                .opacity(reduceMotion && step >= 5 ? 0 : 1)
                .animation(reduceMotion ? .easeOut(duration: 0.3) : .timingCurve(0.4, 0, 0.2, 1, duration: 0.75), value: turning || step >= 5)

                layer(IntroArt.shared.image("IntroCenter"), w, h)
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
        .task(id: held) { if !held { await play() } }
    }

    /// Frame 1 shows from the start (under the center it is the poster) until frame 2 takes over.
    private func visible(_ i: Int) -> Bool {
        if reduceMotion { return i == 1 && step < 5 }
        return i == max(step, 1) && step < 5
    }

    private func play() async {
        // Hold the poster for a beat so the app has rendered underneath; meanwhile decode frames 2-4 off the
        // main thread, so their hard cuts never wait on a decode. (The decode takes a few ms; the hold only
        // stretches if it somehow took longer than the hold itself.)
        async let frames = IntroArt.shared.swirlFrames(reduceMotion: reduceMotion)
        try? await Task.sleep(for: .milliseconds(450))
        swirl = await frames
        guard !Task.isCancelled else { return }
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
    private func layer(_ image: UIImage, _ w: CGFloat, _ h: CGFloat) -> some View {
        Image(uiImage: image).resizable().scaledToFill().frame(width: w, height: h)
    }
}

/// Lisa's intro layers, decoded ahead of time so drawing them never decodes on the main thread mid-animation.
/// The two poster layers (center + frame 1, ~4.8 MB each decoded) stay ready for every open; frames 2-4 are
/// decoded off the main thread while the poster holds and are only kept while the intro plays.
/// `UIImage.preparingForDisplay()` returns the same pixels, already decompressed, so the intro looks identical.
final class IntroArt: @unchecked Sendable {
    static let shared = IntroArt()
    private let lock = NSLock()
    private var poster: [String: UIImage] = [:]

    private init() {
        // Under memory pressure give the ~10 MB back; image(_:) decodes again on the next open.
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
                                               queue: nil) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.poster.removeAll(); self.lock.unlock()
        }
    }

    /// Starts decoding the poster on a background queue (FlUniApp calls this as launching finishes, before the
    /// first frame). Harmless to call more than once.
    func preparePoster() {
        DispatchQueue.global(qos: .userInteractive).async {
            DispatchQueue.concurrentPerform(iterations: 2) { i in _ = self.image(i == 0 ? "IntroCenter" : "IntroFrame1") }
        }
    }

    /// A poster layer, decoded. If the background decode hasn't finished, this decodes it here, so the poster is
    /// always complete on the first frame it appears in.
    func image(_ name: String) -> UIImage {
        lock.lock()
        if let i = poster[name] { lock.unlock(); return i }
        lock.unlock()
        let decoded = Self.decode(name)
        lock.lock(); defer { lock.unlock() }
        if let i = poster[name] { return i }
        poster[name] = decoded
        return decoded
    }

    /// Frames 2-4, decoded in parallel off the main thread. Under Reduce Motion they never show, so none.
    func swirlFrames(reduceMotion: Bool) async -> [Int: UIImage] {
        guard !reduceMotion else { return [:] }
        return await withTaskGroup(of: (Int, UIImage).self) { g in
            for i in 2...4 { g.addTask(priority: .userInitiated) { (i, Self.decode("IntroFrame\(i)")) } }
            var out: [Int: UIImage] = [:]
            for await (i, img) in g { out[i] = img }
            return out
        }
    }

    // MARK: The snapshot cover

    private var covers: [UIView] = []

    /// Puts the still poster over every window of the scene with UIKit, which draws before iOS takes the
    /// app-switcher snapshot (SwiftUI's own overlay only draws afterwards). Same layers, same crop as
    /// LaunchIntro's poster (fill the screen, centred), so it looks identical. Main thread.
    @MainActor func cover(_ scene: UIWindowScene) {
        uncover()
        for w in scene.windows where !w.isHidden {
            let v = UIView(frame: w.bounds)
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            v.isUserInteractionEnabled = false
            v.accessibilityElementsHidden = true
            for name in ["IntroFrame1", "IntroCenter"] {
                let iv = UIImageView(image: image(name))
                iv.frame = v.bounds
                iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                iv.contentMode = .scaleAspectFill
                iv.clipsToBounds = true
                v.addSubview(iv)
            }
            w.addSubview(v)
            covers.append(v)
        }
    }

    @MainActor func uncover() {
        covers.forEach { $0.removeFromSuperview() }
        covers.removeAll()
    }

    private static func decode(_ name: String) -> UIImage {
        guard let img = UIImage(named: name) else { return UIImage() }
        return img.preparingForDisplay() ?? img
    }
}
