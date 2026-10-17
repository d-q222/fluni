import SwiftUI
import WebKit

/// The heat map workstream's page (heatmap/), served from a laptop on the same network.
/// Serve the REPO ROOT (the page fetches ../sim and ../model):
///   cd fluni && python3 -m http.server 8000
/// then http://<laptop>.local:8000/heatmap/?view=public — the user-facing map (building totals, no people).
/// Set it here or with -heatmapURL. The phone also needs internet (map tiles, Leaflet from cdnjs).
struct HeatmapView: View {
    @AppStorage("heatmapURL") private var url = ""
    @State private var draft = ""
    @State private var reloads = 0
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let u = URL(string: url), u.scheme != nil {
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
                        Text("On the laptop, in the fluni folder, run `python3 -m http.server 8000`, then enter http://<laptop>.local:8000/heatmap/?view=public below. If .local doesn't resolve, use the laptop's IP address.")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    TextField("http://laptop.local:8000/heatmap/?view=public", text: $draft)
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
            .navigationTitle("Heat map")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { draft = url }
        }
    }

    private func load() {
        loadError = nil
        url = draft.trimmingCharacters(in: .whitespaces)
        reloads += 1
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
