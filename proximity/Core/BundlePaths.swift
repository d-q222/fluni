import Foundation

/// Pure path and MIME resolution for the fluni://app/… scheme that serves the bundled map. No WebKit here, so it
/// is unit-tested on the host.
enum BundlePaths {
    /// The file to serve, relative to the bundle folder, or nil if the request must be refused (404).
    /// `urlPath` is a URL's path (a query or fragment is ignored). Percent-encoding is decoded once, then any
    /// ".." segment, backslash or NUL rejects the request; "." and empty segments are dropped.
    static func resolve(_ urlPath: String) -> String? {
        var raw = urlPath
        if let i = raw.firstIndex(where: { $0 == "?" || $0 == "#" }) { raw = String(raw[..<i]) }
        guard let decoded = raw.removingPercentEncoding else { return nil }
        if decoded.contains("\0") || decoded.contains("\\") { return nil }
        var parts: [Substring] = []
        for seg in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            if seg == ".." { return nil }
            if seg == "." { continue }
            parts.append(seg)
        }
        if parts.isEmpty || decoded.hasSuffix("/") { parts.append("index.html") }
        return parts.joined(separator: "/")
    }

    /// Content-Type for a path. .gz is served as raw gzip bytes (the page inflates it itself).
    static func mimeType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "geojson": return "application/geo+json; charset=utf-8"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "woff2": return "font/woff2"
        case "gz": return "application/gzip"
        default: return "application/octet-stream"
        }
    }
}
