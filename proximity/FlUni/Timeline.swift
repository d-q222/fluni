import SwiftUI

// The pieces Today is drawn with: Lisa's tissue narrating in a speech bubble, and the "your day" side line
// (a time column, a rail of points, and the content beside each point).

// MARK: The tissue

/// How the tissue feels, from the state of the app. Each mood has its own drawing or marks, its own line.
enum TissueMood: Equatable {
    /// `careful`: nobody sick near you now, but today's estimate is elevated or high (same drawing as calm).
    case calm, careful, headsUp, alert, paused, sick

    /// The one kind line the tissue says. Calm and specific, never alarmist.
    var line: String {
        switch self {
        case .calm: return "Calm day. Nobody near you has said they feel sick, so I'm off duty."
        case .careful: return "Nobody sick near you right now. Earlier today still counts, so go easy on yourself."
        case .headsUp: return "Someone close by may be sick. A little space goes a long way."
        case .alert: return "Okay, eyes up. We'll handle this together, one step at a time."
        case .paused: return "I'm napping while detection is paused. Wake me whenever you're ready."
        case .sick: return "Rest is the whole job today. I'll keep count of the days."
        }
    }
}

/// Lisa's tissue with a speech bubble. Relaxed and gently bobbing when all is clear; alert marks when someone
/// nearby may be sick (sun) or after a close contact (fire); asleep while paused; in bed when you're sick.
/// Reduce Motion: no bob, no hop. VoiceOver hears the line only (the drawing is decoration).
struct TissueNarrator: View {
    let mood: TissueMood
    var stamp = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var bob = false
    @State private var hop = false

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xs))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: Space.xs))
        layout {
            figure
                .frame(width: stacked ? 96 : 118, height: stacked ? 84 : 112)
                .accessibilityHidden(true)
            SpeechBubble(text: mood.line, tail: stacked ? .top : .leading)
                // The tissue's aside stops growing at AX1, so at the largest sizes it doesn't push the day off screen.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .accessibilityIdentifier("tissue.says")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if !reduceMotion { bob = true } }
        .onChange(of: mood) { _, _ in
            guard !reduceMotion else { return }
            hop = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { hop = false }
        }
    }

    @ViewBuilder private var figure: some View {
        ZStack {
            switch mood {
            case .sick:
                Image("FeelingSick").resizable().scaledToFit()
                    .overlay(alignment: .bottomTrailing) {
                        if stamp {
                            Image("StampSelfReported").resizable().scaledToFit().frame(width: 58)
                                .rotationEffect(.degrees(-12)).offset(x: 10, y: 10)
                        }
                    }
            default:
                Image("Tissue").resizable().scaledToFit()
                    .padding(mood == .calm || mood == .careful ? 6 : 14)
                    .saturation(mood == .paused ? 0.35 : 1)
                    .opacity(mood == .paused ? 0.75 : 1)
                    .rotationEffect(.degrees(mood == .alert ? 6 : mood == .headsUp ? 3 : -4))
                    .offset(y: bob && (mood == .calm || mood == .careful) ? -3 : 0)
                    .animation(FlMotion.idle(reduceMotion), value: bob)
                    .scaleEffect(hop ? 1.08 : 1, anchor: .bottom)
                    .animation(FlMotion.bouncy(reduceMotion), value: hop)
                if mood == .alert || mood == .headsUp {
                    AlertMarks().stroke(mood == .alert ? Theme.fire : Theme.ember,
                                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .frame(width: 44, height: 26)
                        .offset(x: -30, y: -46)
                }
                if mood == .paused {
                    Text("z z z").font(.fluni(.voice)).foregroundStyle(Theme.ink2)
                        .rotationEffect(.degrees(-14)).offset(x: 34, y: -44)
                }
            }
        }
    }
}

/// Three short "eyes up" strokes above the tissue's head, drawn like D-2.
private struct AlertMarks: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.35)); p.addLine(to: CGPoint(x: r.minX + r.width * 0.22, y: r.maxY))
        p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX + r.width * 0.02, y: r.maxY * 0.92))
        p.move(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.3)); p.addLine(to: CGPoint(x: r.maxX - r.width * 0.2, y: r.maxY))
        return p
    }
}

/// A hand-feeling speech bubble: surface fill, ink outline, a tail toward the speaker. Shantell Sans, ink (14.3:1).
struct SpeechBubble: View {
    enum Tail { case leading, top }
    let text: String
    var tail: Tail = .leading

    var body: some View {
        Text(text)
            .font(.fluni(.voice))
            .foregroundStyle(Theme.ink)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            .background(BubbleShape(tail: tail).fill(Theme.surface))
            .overlay(BubbleShape(tail: tail).stroke(Theme.ink, style: StrokeStyle(lineWidth: Theme.stroke, lineJoin: .round)))
            .padding(tail == .leading ? .leading : .top, 12)
    }
}

/// A rounded box with a short curved tail. The tail sits outside the rect (the bubble pads for it).
struct BubbleShape: Shape {
    var tail: SpeechBubble.Tail

    func path(in r: CGRect) -> Path {
        var p = Path(roundedRect: r, cornerRadius: 18, style: .continuous)
        var t = Path()
        switch tail {
        case .leading:
            let y = r.minY + min(r.height * 0.62, r.height - 18)
            t.move(to: CGPoint(x: r.minX + 1, y: y - 9))
            t.addQuadCurve(to: CGPoint(x: r.minX - 12, y: y + 7), control: CGPoint(x: r.minX - 4, y: y + 2))
            t.addQuadCurve(to: CGPoint(x: r.minX + 1, y: y + 4), control: CGPoint(x: r.minX - 3, y: y + 7))
        case .top:
            let x = r.minX + 40
            t.move(to: CGPoint(x: x - 9, y: r.minY + 1))
            t.addQuadCurve(to: CGPoint(x: x - 16, y: r.minY - 12), control: CGPoint(x: x - 10, y: r.minY - 4))
            t.addQuadCurve(to: CGPoint(x: x + 5, y: r.minY + 1), control: CGPoint(x: x - 4, y: r.minY - 5))
        }
        p.addPath(t)
        return p
    }
}

// MARK: The side line

/// What a point on the line marks.
enum RailNode: Equatable {
    /// You, now: an ink ring with a dot.
    case now
    /// A place: a paper dot with an ink ring.
    case place
    /// A heads-up or close contact: a filled point in sun or fire, ink-2 ring.
    case moment(TimelineMoment.Kind)
    /// A day on the stay-home track: done (filled), today (now), or still to come (hollow, dashed line).
    case dayDone, dayAhead, dayLast
}

/// The stretch of line under a point, coloured by what happened there. Every colour also has words next to it.
enum RailLine: Equatable {
    case tone(DayTimeline.Tone)
    case recovering, ahead
    case none

    var color: Color {
        switch self {
        case .tone(.closeContact): return Theme.fire
        case .tone(.headsUp): return Theme.sun
        case .tone(.phones): return Theme.sage
        case .recovering: return Theme.ember
        default: return Theme.ink2.opacity(0.45)
        }
    }
    var dashed: Bool {
        switch self { case .tone(.quiet), .ahead: return true; default: return false }
    }
}

/// One row of the timeline: time on the left (stacked into the content at accessibility sizes), the point,
/// and the content. The line runs from this point down to the next one.
struct RailRow<Content: View>: View {
    var label: String? = nil
    var time: String? = nil
    let node: RailNode
    let line: RailLine
    /// Distance from the row's top to the centre of the point, to line it up with the first line of text.
    var nodeY: CGFloat = 14
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var timeWidth: CGFloat = 50

    var body: some View {
        let ax = typeSize.isAccessibilitySize
        HStack(alignment: .top, spacing: Space.xs) {
            if !ax {
                VStack(alignment: .trailing, spacing: 2) {
                    if let label { Text(label).font(.fluni(.fine).weight(.semibold)).foregroundStyle(Theme.ink) }
                    if let time { Text(time).font(.fluni(.time)).foregroundStyle(Theme.ink2) }
                }
                .frame(width: timeWidth, alignment: .trailing)
                .padding(.top, max(0, nodeY - 9))
                .accessibilityHidden(true)
            }
            rail.frame(width: 26)
            VStack(alignment: .leading, spacing: Space.xs) {
                if ax, label != nil || time != nil {
                    Text([label, time].compactMap { $0 }.joined(separator: ", "))
                        .font(.fluni(.time)).foregroundStyle(Theme.ink2)
                        .accessibilityHidden(true)
                }
                content
            }
            .padding(.bottom, line == .none ? 0 : Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var rail: some View {
        ZStack(alignment: .top) {
            if line != .none {
                LineSegment()
                    .stroke(line.color, style: StrokeStyle(lineWidth: line.dashed ? 2 : 4, lineCap: .butt, dash: line.dashed ? [3, 4] : []))
                    .frame(width: 4)
                    .padding(.top, nodeY)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            point.frame(height: nodeY * 2, alignment: .center)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var point: some View {
        switch node {
        case .now:
            Circle().stroke(Theme.ink, lineWidth: 2.5).frame(width: 22, height: 22)
                .overlay(Circle().fill(Theme.ink).frame(width: 9, height: 9))
                .background(Circle().fill(Theme.paper))
        case .place, .dayAhead:
            Circle().fill(Theme.paper).frame(width: 15, height: 15)
                .overlay(Circle().stroke(Theme.ink, lineWidth: 2))
        case .moment(let k):
            Circle().fill(k == .closeContact ? Theme.fire : Theme.sun).frame(width: 17, height: 17)
                .overlay(Circle().stroke(Theme.ink2, lineWidth: 1.5))
                .overlay { if k == .closeContact { Circle().fill(Theme.paper).frame(width: 5, height: 5) } }
        case .dayDone:
            Circle().fill(Theme.ember).frame(width: 18, height: 18)
                .overlay(Circle().stroke(Theme.ink2, lineWidth: 1.5))
                .overlay(Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.ink))
        case .dayLast:
            Circle().fill(Theme.sage).frame(width: 18, height: 18)
                .overlay(Circle().stroke(Theme.ink, lineWidth: 2))
        }
    }
}

private struct LineSegment: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        return p
    }
}

/// The key under the timeline: each colour said in words, with an ink-2 outline so even sun reads (graphic 3:1).
struct RailLegend: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.m) { items }
            VStack(alignment: .leading, spacing: Space.xs) { items }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Line colours: green, near other phones. Yellow, a heads-up. Red, a close contact.")
    }

    @ViewBuilder private var items: some View {
        item(Theme.sage, "near phones")
        item(Theme.sun, "heads-up")
        item(Theme.fire, "close contact")
    }

    private func item(_ c: Color, _ s: String) -> some View {
        HStack(spacing: Space.xs) {
            Capsule().fill(c).frame(width: 22, height: 8).overlay(Capsule().stroke(Theme.ink2, lineWidth: 1))
            Text(s).font(.fluni(.fine)).foregroundStyle(Theme.ink)
        }
    }
}

// MARK: Formatting

enum TimelineFormat {
    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm"
        return f.string(from: d)
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        f.amSymbol = "am"; f.pmSymbol = "pm"
        return f.string(from: d)
    }

    /// "45 min", "1 h 20 min".
    static func duration(_ minutes: Double) -> String {
        let m = max(1, Int(minutes.rounded()))
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    static func phones(_ n: Int) -> String {
        n == 0 ? "no phones near" : n == 1 ? "near 1 phone" : "near up to \(n) phones"
    }
}
