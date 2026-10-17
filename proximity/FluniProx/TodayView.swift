import SwiftUI

/// The student's home screen: one calm status card, a gentle progress bar, a count. No IDs, no
/// per-person distances (those live in the Developer screen).
struct TodayView: View {
    @ObservedObject var model: ProximityModel
    @State private var showHow = false

    private var level: AlertLevel { model.exposure.level }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    minutesCard
                    nearbyCard
                    Button { showHow = true } label: {
                        Label("How this works and what's shared", systemImage: "info.circle")
                            .font(.fluni(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.ink2)
                            .frame(minHeight: 44)
                    }
                }
                .padding(16)
            }
            .background(Theme.paper)
            .navigationTitle("Today")
            .animation(.default, value: level)
            .sheet(isPresented: $showHow) { HowItWorksSheet() }
        }
    }

    // MARK: Status

    private var statusCard: some View {
        let s = Self.style(level)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(s.title).font(.fluni(.title2, weight: .bold))
                    Text(s.subtitle).font(.fluni(.subheadline))
                }
                Spacer(minLength: 0)
                if level == .none {
                    Image("Tissue").resizable().scaledToFit().frame(width: 56, height: 56).accessibilityHidden(true)
                } else {
                    Image(systemName: level == .closeContact ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.title).accessibilityHidden(true)
                }
            }
            if level != .none {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Advice.body(level), id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "arrow.right").font(.caption.bold()).accessibilityHidden(true)
                            Text(line).font(.fluni(.subheadline))
                        }
                    }
                }
            }
        }
        .foregroundStyle(s.text)
        .card(fill: s.fill)
        .accessibilityElement(children: .combine)
    }

    private static func style(_ level: AlertLevel) -> (title: String, subtitle: String, fill: Color, text: Color) {
        switch level {
        case .none:
            return ("All clear", "No one who might be contagious has been near you.", Theme.sage.opacity(0.45), Theme.ink)
        case .nearby:
            return ("Someone nearby may be contagious", "Here is what you can do right now.", Theme.sun.opacity(0.5), Theme.ink)
        case .closeContact:
            return ("Close contact", "You spent about 15 minutes near someone who may be contagious.", Theme.fire.opacity(0.22), Theme.fireInk)
        }
    }

    // MARK: Minutes

    private var minutesCard: some View {
        let mins = model.exposure.minutes
        let goal = ExposureTracker.closeContactMinutes
        let tint = mins >= goal ? Theme.fireInk : (mins > 0 ? Theme.ember : Theme.sage)
        let caption = mins >= goal ? "You've reached the 15-minute close-contact mark."
            : mins > 0 ? "About \(Int((goal - mins).rounded(.up))) more minutes would count as close contact."
            : "No time spent near anyone who might be contagious."
        return VStack(alignment: .leading, spacing: 10) {
            Text("Close-contact time").font(.fluni(.headline))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(min(mins, 99)))").font(.fluni(.largeTitle, weight: .bold)).monospacedDigit()
                Text("of \(Int(goal)) min").font(.fluni(.subheadline)).foregroundStyle(Theme.ink2)
            }
            ProgressView(value: min(mins, goal), total: goal).tint(tint)
            Text(caption).font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
        }
        .foregroundStyle(Theme.ink)
        .card()
        .accessibilityElement(children: .combine)
    }

    // MARK: Nearby

    private var nearbyCard: some View {
        let n = model.peers.count
        let text = n == 0 ? "No Fluni phones nearby" : n == 1 ? "1 Fluni phone nearby" : "\(n) Fluni phones nearby"
        return HStack(spacing: 12) {
            Image(systemName: "person.2.wave.2").font(.title3).foregroundStyle(Theme.ink2).accessibilityHidden(true)
            Text(text).font(.fluni(.body, weight: .semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.ink)
        .card()
        .accessibilityElement(children: .combine)
    }
}

struct HowItWorksSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    block("How it works",
                          "Your phone and other phones running Fluni notice each other over Bluetooth, and by ultra wideband where supported. Together they estimate whether you're within 6 feet. If someone who has marked themselves sick is close for about 15 minutes in total, you get a heads-up with advice.")
                    block("What your phone shares",
                          "Only a 3-level status (fine, symptoms, tested positive) and a random ID that changes every 15 minutes. No name, no phone number, no account.")
                    block("What it doesn't share",
                          "Your location is never sent to other people or to a server. Matching happens on your phone, and the map shows building totals, not people.")
                    block("Good to know",
                          "Fluni works while the app is open. It's a nudge, not a diagnosis: if you feel unwell or are worried, test and follow campus health guidance.")
                }
                .padding(20)
            }
            .background(Theme.paper)
            .navigationTitle("How this works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private func block(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.fluni(.headline))
            Text(body).font(.fluni(.body)).foregroundStyle(Theme.ink2)
        }
        .foregroundStyle(Theme.ink)
    }
}
