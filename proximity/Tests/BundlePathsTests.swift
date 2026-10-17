import XCTest
@testable import FluniProx

final class BundlePathsTests: XCTestCase {
    func testPlainPaths() {
        XCTAssertEqual(BundlePaths.resolve("/index.html"), "index.html")
        XCTAssertEqual(BundlePaths.resolve("/data/totals.json.gz"), "data/totals.json.gz")
        XCTAssertEqual(BundlePaths.resolve("/vendor//leaflet/./leaflet.js"), "vendor/leaflet/leaflet.js")
    }
    func testEmptyAndTrailingSlashGoToIndex() {
        XCTAssertEqual(BundlePaths.resolve(""), "index.html")
        XCTAssertEqual(BundlePaths.resolve("/"), "index.html")
        XCTAssertEqual(BundlePaths.resolve("/data/"), "data/index.html")
    }
    func testQueryAndFragmentIgnored() {
        XCTAssertEqual(BundlePaths.resolve("/index.html?clock=live"), "index.html")
        XCTAssertEqual(BundlePaths.resolve("/?clock=live"), "index.html")
        XCTAssertEqual(BundlePaths.resolve("/usermap.js#b=x"), "usermap.js")
    }
    func testTraversalRejected() {
        for p in ["/../secret", "/a/../../x", "/..", "/a/..", "../x", "/a/%2e%2e/x", "/%2E%2E/x", "/a%2F..%2Fb",
                  "/..%5Cx", "/a\\b", "/x%00.png"] {
            XCTAssertNil(BundlePaths.resolve(p), p)
        }
    }
    func testBadEncodingRejected() { XCTAssertNil(BundlePaths.resolve("/%zz")) }
    func testDoubleEncodedDotsStayLiteral() {
        // Decoded once only: "%252e%252e" becomes the literal name "%2e%2e", which is not a parent reference.
        XCTAssertEqual(BundlePaths.resolve("/%252e%252e/x"), "%2e%2e/x")
    }
    func testMimeTypes() {
        XCTAssertEqual(BundlePaths.mimeType(for: "index.html"), "text/html; charset=utf-8")
        XCTAssertEqual(BundlePaths.mimeType(for: "usermap.js"), "text/javascript; charset=utf-8")
        XCTAssertEqual(BundlePaths.mimeType(for: "a.css"), "text/css; charset=utf-8")
        XCTAssertEqual(BundlePaths.mimeType(for: "data/totals.json"), "application/json; charset=utf-8")
        XCTAssertEqual(BundlePaths.mimeType(for: "data/b.geojson"), "application/geo+json; charset=utf-8")
        XCTAssertEqual(BundlePaths.mimeType(for: "a.PNG"), "image/png")
        XCTAssertEqual(BundlePaths.mimeType(for: "a.webp"), "image/webp")
        XCTAssertEqual(BundlePaths.mimeType(for: "a.svg"), "image/svg+xml")
        XCTAssertEqual(BundlePaths.mimeType(for: "a.woff2"), "font/woff2")
        XCTAssertEqual(BundlePaths.mimeType(for: "data/totals.json.gz"), "application/gzip")
        XCTAssertEqual(BundlePaths.mimeType(for: "a.xyz"), "application/octet-stream")
        XCTAssertEqual(BundlePaths.mimeType(for: "noext"), "application/octet-stream")
    }
}
