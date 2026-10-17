import XCTest
@testable import FluniProx

final class WebPolicyTests: XCTestCase {
    private let base = URL(string: "http://laptop.local:8000/heatmap/?embed=app")

    private func ok(_ s: String) -> Bool { WebPolicy.allows(URL(string: s), base: base) }

    func testSameHostAndPortAllowed() {
        XCTAssertTrue(ok("http://laptop.local:8000/heatmap/app.js"))
        XCTAssertTrue(ok("http://LAPTOP.local:8000/x"))
        XCTAssertTrue(ok("fluni://map/building/x"))
        XCTAssertTrue(ok("about:blank"))
    }

    func testEverythingElseCancelled() {
        XCTAssertFalse(ok("http://laptop.local:9000/"))                 // other port
        XCTAssertFalse(ok("http://laptop.local/"))                      // default port is not 8000
        XCTAssertFalse(ok("https://laptop.local:8000/"))                // other scheme
        XCTAssertFalse(ok("http://evil.com:8000/"))
        XCTAssertFalse(ok("http://laptop.local.evil.com:8000/"))
        XCTAssertFalse(ok("http://laptop.local:8000@evil.com/"))        // userinfo trick: host is evil.com
        XCTAssertFalse(ok("http://x:y@laptop.local:8000/"))
        XCTAssertFalse(ok("javascript:alert(1)"))
        XCTAssertFalse(ok("file:///etc/passwd"))
        XCTAssertFalse(ok("tel:911"))
        XCTAssertFalse(ok("mailto:a@b.c"))
        XCTAssertFalse(ok("data:text/html,hi"))
        XCTAssertFalse(WebPolicy.allows(nil, base: base))
        XCTAssertFalse(WebPolicy.allows(URL(string: "http://laptop.local:8000/"), base: nil))
    }

    func testDefaultPortsMatch() {
        let b = URL(string: "https://maps.example.com/heatmap/")
        XCTAssertTrue(WebPolicy.allows(URL(string: "https://maps.example.com:443/x"), base: b))
        XCTAssertFalse(WebPolicy.allows(URL(string: "http://maps.example.com/x"), base: b))
    }
}
