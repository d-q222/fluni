import SwiftUI
import WebKit
import os

/// FlUni's Map tab: the heat map team's offline user map, bundled in the app (Resources/app-bundle/) and served
/// to a locked-down web view over fluni://app/. It never touches the network, location or the sim.
struct BundledMapView: View {
    @ObservedObject private var router = AppRouter.shared
    @State private var showFocus = false

    var body: some View {
        Group {
            if BundledMap.indexExists {
                BundledMapWebView().ignoresSafeArea(edges: .bottom)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "map").font(.largeTitle).foregroundStyle(Theme.ink2).accessibilityHidden(true)
                    Text("The map isn't available").font(.fluni(.headline, weight: .semibold))
                    Text(brand: "This copy of FlUni is missing its map. Reinstalling the app should fix it.")
                        .font(.fluni(.subheadline)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.paper)
            }
        }
        // "Show on map" from a notification: the web map has no focus hook, so open that building's card natively.
        .onAppear { if router.focusBuilding != nil { showFocus = true } }
        .onChange(of: router.focusBuilding) { _, id in if id != nil { showFocus = true } }
        .sheet(isPresented: $showFocus) {
            VStack(spacing: 0) {
                HStack { Spacer(); Button("Done") { showFocus = false }.frame(minWidth: 44, minHeight: 44) }.padding(.horizontal)
                CampusMapView()
            }
        }
    }
}

enum BundledMap {
    static let rootURL = Bundle.main.resourceURL?.appendingPathComponent("app-bundle", isDirectory: true)
    static var indexExists: Bool {
        guard let r = rootURL else { return false }
        return FileManager.default.fileExists(atPath: r.appendingPathComponent("index.html").path)
    }
}

/// Serves fluni://app/<path> from the app-bundle folder. Unknown or escaping paths are a 404.
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL
    init(root: URL) { self.root = root.standardizedFileURL }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "app", let rel = BundlePaths.resolve(url.path) else {
            return reply(task, status: 404, type: "text/plain", body: Data("Not found".utf8))
        }
        let file = root.appendingPathComponent(rel).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            return reply(task, status: 404, type: "text/plain", body: Data("Not found".utf8))
        }
        // .json.gz goes out as raw gzip bytes (no Content-Encoding): usermap.js inflates it with DecompressionStream
        // and falls back to data/totals.json if that fails.
        reply(task, status: 200, type: BundlePaths.mimeType(for: rel), body: data)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func reply(_ task: WKURLSchemeTask, status: Int, type: String, body: Data) {
        let headers = ["Content-Type": type, "Content-Length": String(body.count), "Cache-Control": "no-store"]
        guard let url = task.request.url,
              let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            task.didFailWithError(URLError(.badURL)); return
        }
        task.didReceive(resp)
        task.didReceive(body)
        task.didFinish()
    }
}

private struct BundledMapWebView: UIViewRepresentable {
    func makeCoordinator() -> Guard { Guard() }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.loading = Signposts.poi.beginInterval("map load")
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        if let root = BundledMap.rootURL { cfg.setURLSchemeHandler(BundleSchemeHandler(root: root), forURLScheme: "fluni") }
        // Belt and braces: the page cannot even ask for a position.
        let noGeo = "Object.defineProperty(navigator,'geolocation',{value:undefined,configurable:false});"
        cfg.userContentController.addUserScript(WKUserScript(source: noGeo, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = UIColor(Theme.paper)
        web.scrollView.backgroundColor = UIColor(Theme.paper)
        web.allowsLinkPreview = false
        web.accessibilityLabel = "Campus heat map"
        #if DEBUG
        web.isInspectable = true
        #endif
        if let url = URL(string: "fluni://app/index.html?clock=live") { web.load(URLRequest(url: url)) }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    /// Denies everything except fluni://app, and all geolocation, media capture and new windows.
    final class Guard: NSObject, WKNavigationDelegate, WKUIDelegate {
        /// From creating the web view to the page's load event (Points of Interest "map load").
        var loading: OSSignpostIntervalState?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let s = loading { Signposts.poi.endInterval("map load", s); loading = nil }
            #if DEBUG
            pollDrawn(webView, tries: 0)
            #endif
        }
        #if DEBUG
        /// Debug only, for Instruments: usermap.js hides #status once the data is loaded and drawn ("map drawn").
        private func pollDrawn(_ web: WKWebView, tries: Int) {
            guard tries < 300 else { return }
            web.evaluateJavaScript("document.getElementById('status')?.hidden === true") { [weak self, weak web] r, _ in
                guard let self, let web else { return }
                if (r as? Bool) == true { Signposts.poi.emitEvent("map drawn"); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { self.pollDrawn(web, tries: tries + 1) }
            }
        }
        #endif
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let u = action.request.url
            decisionHandler(u?.scheme == "fluni" && u?.host == "app" ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
        func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }
    }
}
