import SwiftUI
import CoreLocation

enum AlwaysLocationCopy {
    static let promise = "Your precise location never leaves this phone and is never seen by anyone. FlUni only uses it on your phone to warn you about busy buildings."
}

/// Step two of the location ask (While Using is granted in onboarding): explain first, then show the iOS prompt.
struct AlwaysLocationCard: View {
    @ObservedObject private var watcher = BuildingWatcher.shared
    @AppStorage("alwaysAskDismissed") private var dismissed = false

    var body: some View {
        if watcher.status == .authorizedWhenInUse && !dismissed {
            VStack(alignment: .leading, spacing: 8) {
                Label("Get warned even when FlUni is closed", systemImage: "bell.badge").font(.fluni(.subheadline, weight: .semibold))
                Text(AlwaysLocationCopy.promise).font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
                Text("On the next screen, choose \u{201C}Change to Always Allow\u{201D}.").font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
                HStack {
                    Button("Not now") { dismissed = true }.frame(minHeight: 44)
                    Spacer()
                    Button("Turn on") { dismissed = true; watcher.requestAlways() }
                        .font(.fluni(.subheadline, weight: .semibold)).frame(minHeight: 44)
                }.font(.fluni(.subheadline))
            }
            .foregroundStyle(Theme.ink)
            .card()
        }
    }
}

/// Settings: where background warnings stand, and how to change it.
struct BackgroundWarningsSection: View {
    @ObservedObject private var watcher = BuildingWatcher.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            LabeledContent("Warnings when closed", value: watcher.canWatchInBackground ? "On" : "Off")
            if watcher.status == .authorizedWhenInUse {
                Button("Turn on\u{2026}") { watcher.requestAlways() }
            }
            if !watcher.canWatchInBackground {
                Button("Open iOS Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) } }
            }
        } header: {
            Text("Building warnings")
        } footer: {
            Text(watcher.canWatchInBackground
                 ? AlwaysLocationCopy.promise
                 : "Warnings still work while FlUni is open. To get them when it's closed, open iOS Settings, choose Location, and pick Always. " + AlwaysLocationCopy.promise)
        }
        .listRowBackground(Theme.surface)
    }
}
