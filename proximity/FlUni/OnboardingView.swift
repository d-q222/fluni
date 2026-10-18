import SwiftUI

/// First launch: what the app does, what is and isn't shared, then explain each permission and only
/// then start the radios (which is what triggers the system prompts).
struct OnboardingView: View {
    let onFinish: () -> Void
    #if DEBUG
    @State private var page = PreviewHook.onboardingPage
    #else
    @State private var page = 0
    #endif
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
            .accessibilityIdentifier(page == 2 ? "onboarding.turnOn" : "onboarding.next")
            .accessibilityHint(page == 2 ? "Starts detection and asks for the permissions above" : "Goes to step \(page + 2) of 3")
            .padding(.horizontal, Space.m).padding(.bottom, Space.m)
        }
        .background(Theme.paper)
        .onAppear { UIPageControl.appearance().currentPageIndicatorTintColor = UIColor(Theme.ink)
                    UIPageControl.appearance().pageIndicatorTintColor = UIColor(Theme.ink.opacity(0.25)) }
    }

    private var page1: some View {
        slide(title: "Know when someone sick is near",
              text: "FlUni tells you if you've been close to a classmate who may be sick, and what to do about it. It also shows how busy and how risky buildings are on campus.") {
            // Lisa's tissue, large and a little tilted, hung off the right edge of the page.
            Image("Tissue").resizable().scaledToFit().frame(width: 200, height: 200)
                .rotationEffect(.degrees(-10))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .offset(x: Space.l)
                .accessibilityHidden(true)
        }
    }

    private var page2: some View {
        slide(title: "Private by design", text: nil) {
            EmptyView()
        } more: {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Phones nearby see only").font(.fluni(.heading))
                shared("A status with 3 levels: healthy, possibly sick or contagious")
                HandRule()
                shared("A random ID that changes every 15 minutes")
            }
            .foregroundStyle(Theme.ink)
            .card()
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Never shared").font(.fluni(.heading))
                Text("Your name, your location, your contacts. There's no account and no server tracking you.")
                    .font(.fluni(.reading)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Theme.ink)
            .accessibilityElement(children: .combine)
        }
    }

    private func shared(_ text: String) -> some View {
        Text(text).font(.fluni(.reading)).fixedSize(horizontal: false, vertical: true)
    }

    private var page3: some View {
        // Centred when it fits; scrolls at large text sizes instead of clipping.
        ViewThatFits(in: .vertical) {
            page3Content(spacers: true)
            ScrollView { page3Content(spacers: false).padding(.vertical, Space.l) }
        }
    }

    private func page3Content(spacers: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if spacers { Spacer(minLength: Space.s) }
            Text("Turn on detection")
                .accessibilityAddTraits(.isHeader).font(.fluni(.display)).foregroundStyle(Theme.ink)
            Text("iOS will ask for a few permissions. Here's why:").font(.fluni(.reading)).foregroundStyle(Theme.ink2)
                .padding(.bottom, Space.xs)
            perm("Bluetooth and local network", "to notice other FlUni phones close by.")
            HandRule()
            perm("Nearby Interaction", "for precise distance (is it 3 feet or 10?) on newer iPhones.")
            HandRule()
            perm("Location", "\(AlwaysLocationCopy.promise)")
            HandRule()
            perm("Notifications", "so you get a heads-up if you're near someone who may be sick.")
            if spacers { Spacer() }
        }
        .padding(.horizontal, Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func perm(_ title: String, _ why: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title).font(.fluni(.heading))
            Text(why).font(.fluni(.note)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func slide<Art: View, More: View>(title: String, text: String?, @ViewBuilder art: () -> Art,
                                              @ViewBuilder more: () -> More = { EmptyView() }) -> some View {
        let art = art(), more = more()
        return ViewThatFits(in: .vertical) {
            slideContent(title, text, art, more, spacers: true)
            ScrollView { slideContent(title, text, art, more, spacers: false).padding(.vertical, Space.l) }
        }
    }

    private func slideContent(_ title: String, _ text: String?, _ art: some View, _ more: some View, spacers: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if spacers { Spacer() }
            art
            Text(title).font(.fluni(.display)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let text { Text(text).font(.fluni(.reading)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true) }
            more
            if spacers { Spacer() }
        }
        .padding(.horizontal, Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
