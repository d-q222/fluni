import SwiftUI
import UserNotifications

/// Detection on/off, what is shared, notifications, the map address, deleting local data, and About.
struct SettingsView: View {
    @ObservedObject var model: ProximityModel
    @AppStorage("heatmapURL") private var heatmapURL = ""
    @AppStorage("hasOnboarded") private var hasOnboarded = true
    @AppStorage(AppNotifications.detailsKey) private var lockScreenDetails = true
    @State private var notificationStatus: UNAuthorizationStatus?
    @State private var confirmDelete = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            detectionSection
            sharedSection
            notificationsSection
            BackgroundWarningsSection()
            mapSection
            dataSection
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.paper)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshNotifications() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshNotifications() } }
        }
        .confirmationDialog("Delete all data on this phone?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete my data", role: .destructive) { deleteEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears your saved status, recent contacts, map address and setup. FlUni will start over as if it were just installed.")
        }
    }

    // MARK: Detection

    private var detectionSection: some View {
        Section {
            Toggle("Detection", isOn: Binding(
                get: { !model.isPaused },
                set: { on in if on { model.resume() } else { model.pause(.untilResumed) } }))
            if let p = model.pauseState {
                Label("Paused \(PauseSchedule.describe(p, calendar: .current, now: Date()))", systemImage: "pause.circle")
                    .foregroundStyle(Theme.ink)
                Button("Turn detection back on") { model.resume() }
            }
            Menu {
                Button("For 1 hour") { model.pause(.oneHour) }
                Button("Until tomorrow") { model.pause(.untilTomorrow) }
                Button("Until I turn it back on") { model.pause(.untilResumed) }
            } label: {
                Label(model.isPaused ? "Change how long" : "Pause detection", systemImage: "clock")
            }
            .accessibilityIdentifier("settings.pause")
        } header: {
            Text("Detection").foregroundStyle(Theme.ink2)
        } footer: {
            Text(model.isPaused
                 ? "While paused, FlUni doesn't share your status, look for nearby phones or count close-contact time, so it can't warn you either."
                 : "Pausing stops FlUni's use of Bluetooth, precise distance sensing and location, and saves battery.").foregroundStyle(Theme.ink2)
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: What is shared

    private var sharedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Phones within Bluetooth range see exactly two things:").font(.fluni(.subheadline))
                Label("A random ID that changes every 15 minutes", systemImage: "arrow.triangle.2.circlepath")
                Label("A status with 3 levels: healthy, possibly sick, or contagious", systemImage: "circle.lefthalf.filled")
            }
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 6) {
                Label("Your precise location", systemImage: "location.slash").font(.fluni(.subheadline, weight: .semibold))
                Text(AlwaysLocationCopy.promise).font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
            }
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 6) {
                Text("Never shared").font(.fluni(.subheadline, weight: .semibold))
                Text("Your name, phone number, device name, account, or any history. Matching happens on your phone.")
                    .font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
            }
        } header: {
            Text("What FlUni shares").foregroundStyle(Theme.ink2)
        }
        .font(.fluni(.footnote))
        .foregroundStyle(Theme.ink)
        .listRowBackground(Theme.surface)
    }

    // MARK: Notifications

    private var notificationsSection: some View {
        Section {
            LabeledContent("Alerts") { Text(notificationText).foregroundStyle(Theme.ink2) }
            Toggle("Show details on lock screen", isOn: $lockScreenDetails)
            Button("Open iPhone Settings") {
                if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) }
            }
            .accessibilityHint("Opens the iPhone Settings app, where you can change notification permission")
        } header: {
            Text("Notifications").foregroundStyle(Theme.ink2)
        } footer: {
            Text("FlUni sends a notification when someone nearby may be sick or you have a close contact. The title is always just \"FlUni\". "
                 + "With details off, the message only says there is an update, so people looking at your lock screen learn nothing about your health.")
        }
        .listRowBackground(Theme.surface)
    }

    private var notificationText: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return "On"
        case .denied: return "Off"
        case .notDetermined: return "Not asked yet"
        default: return "Checking"
        }
    }

    private func refreshNotifications() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: Map

    private var mapSection: some View {
        Section {
            TextField("http://…", text: $heatmapURL)
                .keyboardType(.URL).textContentType(.URL)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityLabel("Map address")
                .frame(minHeight: 44)
        } header: {
            Text("Map address").foregroundStyle(Theme.ink2)
        } footer: {
            Text("Where the Map tab loads the campus heat map from.").foregroundStyle(Theme.ink2)
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: Delete

    private var dataSection: some View {
        Section {
            // System red is 3.3:1 on surface; fire-ink is 7.3.
            Button("Delete my data", role: .destructive) { confirmDelete = true }
                .foregroundStyle(Theme.fireInk)
                .frame(minHeight: 44)
                .accessibilityIdentifier("settings.delete")
        } footer: {
            Text("Removes everything FlUni saved on this phone. Nothing is stored on a server.").foregroundStyle(Theme.ink2)
        }
        .listRowBackground(Theme.surface)
    }

    private func deleteEverything() {
        hasOnboarded = false  // back to onboarding; set first so the view updates, the erase below removes the key
        heatmapURL = ""
        Self.eraseLocalData()
        model.forgetEverything()
    }

    /// Deletes the contents of Application Support (exposure history and anything else saved there)
    /// and the app's whole UserDefaults domain (status, map address, onboarding, pause).
    static func eraseLocalData(fileManager fm: FileManager = .default, defaults: UserDefaults = .standard,
                               domain: String? = Bundle.main.bundleIdentifier) {
        if let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
           let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for item in items { try? fm.removeItem(at: item) }
        }
        if let domain { defaults.removePersistentDomain(forName: domain) }
        defaults.synchronize()
    }

    // MARK: About

    private var aboutSection: some View {
        Section { 
            LabeledContent("Version") { Text(Self.version).foregroundStyle(Theme.ink2) }
            Text("Palette and illustrations: Lisa Zheng (lisaazheng)")
            Text("Map data © OpenStreetMap contributors")
        } header: {
            Text("About").foregroundStyle(Theme.ink2)
        }
        .font(.fluni(.footnote))
        .foregroundStyle(Theme.ink)
        .listRowBackground(Theme.surface)
    }

    private static var version: String {
        let i = Bundle.main.infoDictionary
        let v = i?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = i?["CFBundleVersion"] as? String
        return b.map { "\(v) (\($0))" } ?? v
    }
}
