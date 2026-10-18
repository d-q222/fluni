import SwiftUI
import CoreLocation

enum AlwaysLocationCopy {
    static let promise = "Your precise location never leaves this phone and is never seen by anyone. FlUni only uses it on your phone to warn you about busy buildings."
}

/// Step two of the location ask (While Using is granted in onboarding): explain first, then show the iOS prompt.
struct AlwaysLocationCard: View {
    @ObservedObject private var watcher = BuildingWatcher.shared
    @AppStorage("alwaysAskDismissed") private var dismissed = false
    @AppStorage("hasOnboarded") private var onboarded = false

    var body: some View {
        // Core/BackgroundLocation.swift: When In Use granted, onboarding done, not dismissed. Always now also keeps
        // detection and alerts running while the phone is locked (blue location indicator).
        if BackgroundLocation.offersAlways(auth: .init(watcher.status), onboarded: onboarded, dismissed: dismissed) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Get warned even when FlUni is closed", systemImage: "bell.badge").font(.fluni(.subheadline, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(AlwaysLocationCopy.promise).font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
                    Text("On the next screen, choose \u{201C}Change to Always Allow\u{201D}.").font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
                }
                .accessibilityElement(children: .combine)
                let notNow = Button("Not now") { dismissed = true }.frame(minHeight: 44)
                let turnOn = Button("Turn on warnings") { dismissed = true; watcher.requestAlways() }
                    .font(.fluni(.subheadline, weight: .semibold)).frame(minHeight: 44)
                    .accessibilityHint("Shows the iPhone location prompt")
                // Side by side, or stacked when large text would squeeze them.
                ViewThatFits(in: .horizontal) {
                    HStack { notNow; Spacer(); turnOn }
                    VStack(alignment: .leading, spacing: 0) { turnOn; notNow }
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
            // The default value colour is system grey (3.3:1 on surface); ink-2 is 7.0.
            LabeledContent("Warnings when closed") { Text(watcher.canWatchInBackground ? "On" : "Off").foregroundStyle(Theme.ink2) }
            if watcher.status == .authorizedWhenInUse {
                Button("Turn on warnings when closed") { watcher.requestAlways() }
                    .frame(minHeight: 44)
                    .accessibilityHint("Shows the iPhone location prompt")
            }
            if !watcher.canWatchInBackground {
                Button("Open iPhone Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) } }
                    .frame(minHeight: 44)
                    .accessibilityHint("Opens the iPhone Settings app, where you can change location permission")
            }
        } header: {
            Text("Building warnings").foregroundStyle(Theme.ink2)
        } footer: {
            Text(watcher.canWatchInBackground
                 ? AlwaysLocationCopy.promise
                 : "Warnings still work while FlUni is open. To get them when it's closed, open iPhone Settings, choose Location, and pick Always. " + AlwaysLocationCopy.promise)
                .foregroundStyle(Theme.ink2)
        }
        .listRowBackground(Theme.surface)
    }
}
