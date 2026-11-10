import AppKit
import WebKit
import XCTest
@testable import Bowser

@MainActor final class WindowMetricsTests: XCTestCase {
    func testPageReadsActualWindowSizeAfterResizeAndReparenting() async throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let engine = EngineView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: engine.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 750), styleMask: .borderless, backing: .buffered, defer: false)
        for host in [window, other] { host.isReleasedWhenClosed = false }
        window.contentView = engine
        window.orderBack(nil)
        other.orderBack(nil)
        defer { engine.tearDown(); window.close(); other.close() }

        engine.webView.loadHTMLString("<html><body>Window metrics</body></html>", baseURL: nil)
        for _ in 0..<500 where engine.webView.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(engine.webView.isLoading)

        func check(_ host: NSWindow) async throws {
            let expected: [Double] = [host.frame.width, host.frame.height]
            var size: [Double] = []
            // Window updates reach WebKit's content process asynchronously.
            for _ in 0..<100 {
                size = try await withCheckedThrowingContinuation { continuation in
                    engine.webView.evaluateJavaScript("[window.outerWidth, window.outerHeight]", in: nil, in: .page) {
                        continuation.resume(with: $0.map { $0 as? [Double] ?? [] })
                    }
                }
                if size == expected { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(size, expected, "DOM window size must reflect the native host, including chrome")
        }

        try await check(window)
        window.setContentSize(NSSize(width: 920, height: 640))
        try await check(window)

        // Element fullscreen reparents the live WKWebView out of EngineView.
        other.contentView?.addSubview(engine.webView)
        engine.webView.frame = other.contentView!.bounds
        try await check(other)
        engine.addSubview(engine.webView)
        engine.layout()
        try await check(window)
    }

    func testDetachedTabUsesItsOwningWindowAndUnownedViewReturnsZero() throws {
        _ = NSApplication.shared
        let controller = BrowserWindowController(profile: .defaultProfile)
        defer { controller.window?.close() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = controller.openTab(configuration: configuration, activate: false)
        XCTAssertNil(tab.webView.window)
        let host = try XCTUnwrap(controller.window)
        var frame: CGRect?
        tab.webView(tab.webView, getWindowFrameWithCompletionHandler: { frame = $0 })
        XCTAssertEqual(frame, host.frame)

        let unowned = EngineView(frame: .zero, configuration: configuration)
        defer { unowned.tearDown() }
        unowned.webView(unowned.webView, getWindowFrameWithCompletionHandler: { frame = $0 })
        XCTAssertEqual(frame, .zero)
    }
}
