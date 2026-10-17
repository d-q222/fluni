import SwiftUI

/// First launch: what the app does, what is and isn't shared, then explain each permission and only
/// then start the radios (which is what triggers the system prompts).
struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                page1.tag(0)
                page2.tag(1)
                page3.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .never))

            Button(page == 2 ? "Turn on detection" : "Next") {
                if page == 2 { onFinish() }
                else if reduceMotion { page += 1 }
                else { withAnimation { page += 1 } }
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityHint(page == 2 ? "Starts detection and asks for the permissions above" : "Goes to step \(page + 2) of 3")
            .padding(.horizontal, 20).padding(.bottom, 20)
        }
        .background(Theme.paper)
        .onAppear { UIPageControl.appearance().currentPageIndicatorTintColor = UIColor(Theme.ink)
                    UIPageControl.appearance().pageIndicatorTintColor = UIColor(Theme.ink.opacity(0.25)) }
    }

    private var page1: some View {
        slide(title: "Know when someone sick is near",
              text: "FlUni tells you if you've been close to a classmate who may be sick, and what to do about it. It also shows how busy and how risky buildings are on campus.",
              art: AnyView(Image("Tissue").resizable().scaledToFit().frame(width: 140, height: 140).accessibilityHidden(true)))
    }

    private var page2: some View {
        slide(title: "Private by design",
              text: "Shared with phones nearby: a 3-level status (healthy, possibly sick or contagious) and a random ID that changes every 15 minutes.\n\nNot shared: your name, your location, your contacts. There's no account and no server tracking you.",
              art: AnyView(Image(systemName: "lock.shield").font(.system(size: 72)).foregroundStyle(Theme.ink2).accessibilityHidden(true)))
    }

    private var page3: some View {
        // Centred when it fits; scrolls at large text sizes instead of clipping.
        ViewThatFits(in: .vertical) {
            page3Content(spacers: true)
            ScrollView { page3Content(spacers: false).padding(.vertical, 24) }
        }
    }

    private func page3Content(spacers: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if spacers { Spacer(minLength: 12) }
            Text("Turn on detection")
                .accessibilityAddTraits(.isHeader).font(.fluni(.title, weight: .bold)).foregroundStyle(Theme.ink)
            Text("iOS will ask for a few permissions. Here's why:").font(.fluni(.body)).foregroundStyle(Theme.ink2)
            perm("antenna.radiowaves.left.and.right", "Bluetooth and local network", "to notice other FlUni phones close by.")
            perm("wave.3.right", "Nearby Interaction", "for precise distance (is it 3 feet or 10?) on newer iPhones.")
            perm("location", "Location", "only as a backup way to estimate distance. It never leaves your phone except to a nearby phone you're linked with.")
            perm("bell", "Notifications", "so you get a heads-up if you're near someone who may be sick.")
            if spacers { Spacer() }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func perm(_ icon: String, _ title: String, _ why: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Theme.ink2).frame(width: 30).accessibilityHidden(true)
            (Text(title).bold() + Text(" \(why)")).font(.fluni(.subheadline)).foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
    }

    private func slide(title: String, text: String, art: AnyView) -> some View {
        ViewThatFits(in: .vertical) {
            slideContent(title, text, art, spacers: true)
            ScrollView { slideContent(title, text, art, spacers: false).padding(.vertical, 24) }
        }
    }

    private func slideContent(_ title: String, _ text: String, _ art: AnyView, spacers: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if spacers { Spacer() }
            HStack { Spacer(); art; Spacer() }
            Text(title).font(.fluni(.title, weight: .bold)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(text).font(.fluni(.body)).foregroundStyle(Theme.ink2)
            if spacers { Spacer() }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
