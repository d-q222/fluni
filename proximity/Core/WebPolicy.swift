import Foundation

/// Which navigations the map web view may make. Pure, so it is tested on the host.
/// Only the configured heat map host and port (same scheme), the future `fluni://` custom scheme and
/// `about:blank` are allowed; everything else is cancelled and never handed to the system browser.
enum WebPolicy {
    static func allows(_ url: URL?, base: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "fluni" { return true }
        if url.absoluteString == "about:blank" { return true }
        guard let base, let bs = base.scheme?.lowercased(), scheme == bs,
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), let bh = base.host?.lowercased(), host == bh,
              url.user == nil, url.password == nil else { return false }
        func port(_ u: URL, _ s: String) -> Int { u.port ?? (s == "https" ? 443 : 80) }
        return port(url, scheme) == port(base, bs)
    }
}
