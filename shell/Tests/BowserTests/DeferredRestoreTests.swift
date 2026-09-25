import AppKit
import WebKit
import XCTest
@testable import Bowser

@MainActor final class DeferredRestoreTests: XCTestCase {
    private func makeView() -> EngineView {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        return EngineView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
    }

    func testBackgroundRestoreKeepsURLWithoutNavigationAndLoadsWhenMounted() async throws {
        let view = makeView()
        defer { view.tearDown() }
        let url = "data:text/html,<title>Restored</title><p>Ready</p>"
        view.restore(urlString: url)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(view.currentURLString, url)
        XCTAssertEqual(view.pendingRestoreURL, url)
        XCTAssertNil(view.webView.url)
        XCTAssertFalse(view.webView.isLoading)
        let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        XCTAssertNil(view.pendingRestoreURL)
        XCTAssertNotNil(view.currentURLString)
        for _ in 0..<100 {
            if view.webView.title == "Restored" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(view.webView.title, "Restored")
    }

    func testExplicitNavigationReplacesDeferredRestore() {
        let view = makeView()
        defer { view.tearDown() }
        view.restore(urlString: "https://saved.example/")
        view.load(urlString: "data:text/html,Replacement")
        XCTAssertNil(view.pendingRestoreURL)
        XCTAssertEqual(view.currentURLString, "data:text/html,Replacement")
    }
}
