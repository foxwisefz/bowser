import XCTest
import AppKit
import WebKit
@testable import Bowser

final class BrowserScreenshotTests: XCTestCase {
    @MainActor final class Navigation: NSObject, WKNavigationDelegate {
        let ready: XCTestExpectation
        init(_ ready: XCTestExpectation) { self.ready = ready }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready.fulfill() }
    }

    @MainActor func testPageCaptureReturnsViewportPixelsWithoutDesktopCapture() async throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        let window = NSWindow(contentRect: page.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFront(nil)
        defer { window.close() }
        let loaded = expectation(description: "fixture loaded")
        let navigation = Navigation(loaded)
        page.navigationDelegate = navigation
        page.loadHTMLString("<html><body style='margin:0;background:rgb(255,0,0);height:2000px'>Screenshot fixture</body></html>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        let result = try await BrowserScreenshot.page(page, maxWidth: 320)
        XCTAssertEqual(result["width"] as? Int, 320)
        XCTAssertEqual(result["height"] as? Int, 240)
        XCTAssertEqual(result["point_width"] as? Double, 640)
        XCTAssertEqual(result["capture"] as? String, "webkit")
        let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(result["image"] as? String)))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: bytes))
        let pixel = try XCTUnwrap(bitmap.colorAt(x: 160, y: 120)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(pixel.redComponent, 0.9)
        XCTAssertLessThan(pixel.blueComponent, 0.1)
    }
}
