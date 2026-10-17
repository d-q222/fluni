import SwiftUI

/// The test harness (com.fluni.proxtest): the same Core as FlUni, started at once with the
/// developer view in front. The Mac tools in tools/ launch it with test arguments and read its
/// "[fluni]" log lines; the unit tests run inside it.
@main
struct FluniProxApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = ProximityModel()
    @State private var started = false

    var body: some Scene {
        WindowGroup {
            TabView {
                DeveloperView(model: model, showsDone: false)
                    .tabItem { Label("Proximity", systemImage: "dot.radiowaves.left.and.right") }
                HeatmapView()
                    .tabItem { Label("Heat map", systemImage: "map") }
            }
            .preferredColorScheme(.light)
            .onAppear {
                guard !started, !LaunchMode.isUnitTestHost else { return }
                started = true
                model.start()
            }
        }
    }
}
