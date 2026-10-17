import SwiftUI
import WebKit

/// The heat map workstream's page (heatmap/), served from a laptop on the same network.
/// Serve the REPO ROOT (the page fetches ../sim and ../model):
///   cd fluni && python3 -m http.server 8000
/// then http://<laptop>.local:8000/heatmap/?embed=app — the user-facing map (embed implies the public view:
/// building totals, no people; full screen with a floating time chip and the legend at the bottom).
/// `embed=app` is appended if missing. Optional: &at=<minutes> &horizon=60.
/// Set it here or with -heatmapURL. The phone also needs internet (map tiles, Leaflet from cdnjs).
struct HeatmapView: View {
    @AppStorage("heatmapURL") private var url = ""
    @State private var draft = ""
    @State private var reloads = 0
    @State private var loadError: String?
    @State private var editing = false

    var body: some View {
        NavigationStack {
            Group {
                if let u = Self.embedURL(url) {
                    HeatWebView(url: u, error: $loadError).id(reloads)
                        .overlay(alignment: .top) {
                            if let e = loadError {
                                Label(e, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .padding(10)
                                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                                    .padding()
                            }
                        }
                } else {
                    ContentUnavailableView {
                        Label("No heat map yet", systemImage: "map")
                    } description: {
                        Text("On the laptop, in the fluni folder, run `python3 -m http.server 8000`, then enter http://<laptop>.local:8000/heatmap/?embed=app below. If .local doesn't resolve, use the laptop's IP address.")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if editing || URL(string: url)?.scheme == nil {
                HStack {
                    TextField("http://laptop.local:8000/heatmap/?embed=app", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(load)
                    Button("Load", action: load)
                }
                .padding(8)
                .background(.bar)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing.toggle() } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Map address")
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { draft = url }
        }
    }

    private func load() {
        loadError = nil
        url = draft.trimmingCharacters(in: .whitespaces)
        editing = false
        reloads += 1
    }

    /// The saved address with `embed=app` ensured (and the old `view=public` dropped: embed implies it).
    static func embedURL(_ s: String) -> URL? {
        guard var c = URLComponents(string: s), c.scheme != nil else { return nil }
        var items = (c.queryItems ?? []).filter { $0.name != "view" }
        if !items.contains(where: { $0.name == "embed" }) { items.append(URLQueryItem(name: "embed", value: "app")) }
        c.queryItems = items
        return c.url
    }
}

private struct HeatWebView: UIViewRepresentable {
    let url: URL
    @Binding var error: String?

    func makeCoordinator() -> Coordinator { Coordinator(error: $error) }

    func makeUIView(context: Context) -> WKWebView {
        let v = WKWebView()
        v.isInspectable = true  // Safari → Develop → <iPhone> shows the page's console
        v.navigationDelegate = context.coordinator
        v.load(URLRequest(url: url))
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {}

    /// Load failures used to be silent; show them and log them for the Mac console.
    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var error: String?
        init(error: Binding<String?>) { _error = error }

        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { report(e) }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { report(e) }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { error = nil }

        private func report(_ e: Error) {
            error = "Couldn't load the heat map: \(e.localizedDescription)"
            print("[fluni] heatmap load failed: \(e.localizedDescription)")
            fflush(stdout)
        }
    }
}
