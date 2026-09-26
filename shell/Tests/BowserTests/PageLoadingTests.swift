import AppKit
import WebKit
import XCTest
@testable import Bowser

@MainActor final class PageLoadingTests: XCTestCase {
    func testInitialAndSlowResponseAreCoveredUntilContentRenders() async throws {
        try await withPage { view, origin in
            XCTAssertTrue(view.isShowingLoadingCover)
            view.load(urlString: origin + "/slow")
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(view.isShowingLoadingCover, "No white webview while waiting for response headers")
            try await wait { view.hasRenderedContent }
            XCTAssertFalse(view.isShowingLoadingCover)
        }
    }

    func testUsableContentIsRevealedBeforeSlowImagesFinish() async throws {
        try await withPage { view, origin in
            XCTAssertTrue(view.observesRenderingProgress, "WebKit rendering milestone must be supported")
            view.load(urlString: origin + "/slow-image")
            try await wait { view.hasRenderedContent }
            XCTAssertFalse(view.isShowingLoadingCover)
            XCTAssertTrue(view.webView.isLoading, "Do not wait for slow subresources to show the page")
        }
    }

    func testTimeoutShowsErrorInsteadOfLeavingLoadingCover() async throws {
        try await withPage { view, origin in
            view.load(urlString: origin + "/slow")
            view.webView.stopLoading()
            view.webView(view.webView, didFailProvisionalNavigation: nil,
                withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
            try await wait { view.hasRenderedContent }
            XCTAssertFalse(view.isShowingLoadingCover)
            XCTAssertEqual(view.currentURLString, origin + "/slow")
            let text = try await view.webView.evaluateJavaScript("document.body.innerText") as? String
            XCTAssertTrue(text?.contains("This page didn’t load") == true)
        }
    }

    func testFocusedLoadedPageStaysVisibleWhileNextResponseIsStalled() async throws {
        try await withPage { view, origin in
            view.load(urlString: origin + "/page")
            try await wait { view.hasRenderedContent && !view.webView.isLoading }
            view.load(urlString: origin + "/slow")
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertFalse(view.isShowingLoadingCover, "Keep the current page while the next response is pending")
            XCTAssertTrue(view.hasRenderedContent)
            try await wait { !view.webView.isLoading }
            XCTAssertFalse(view.isShowingLoadingCover)
        }
    }

    private func withPage(_ body: @MainActor (EngineView, String) async throws -> Void) async throws {
        _ = NSApplication.shared
        let server = try BrowserFixtureServer()
        defer { server.stop() }
        try await wait { server.origin != nil }
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view = EngineView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view; window.orderFront(nil)
        defer { view.tearDown(); window.close() }
        try await body(view, try XCTUnwrap(server.origin))
    }

    private func wait(_ condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(8)
        while !condition(), Date() < until { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out waiting for page state")
    }
}
