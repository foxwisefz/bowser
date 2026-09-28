import AppKit
import WebKit
import XCTest
@testable import Bowser

@MainActor final class PageLoadingTests: XCTestCase {
    private final class VisibilityWindow: NSWindow {
        var visibleForTest = true
        override var occlusionState: NSWindow.OcclusionState { visibleForTest ? [.visible] : [] }
    }

    func testLoaderStopsWhenHiddenAndDetached() async throws {
        _ = NSApplication.shared
        let view = PageLoadingView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        view.loading = true
        XCTAssertFalse(view.isAnimating)
        // WindowServer can report every test window occluded on a locked desktop.
        let window = VisibilityWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try await wait { view.isAnimating }
        }
        window.visibleForTest = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertFalse(view.isAnimating)
        window.visibleForTest = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        view.isHidden = true
        XCTAssertFalse(view.isAnimating)
        view.isHidden = false
        view.loading = false
        XCTAssertFalse(view.isAnimating)
        view.loading = true
        view.removeFromSuperview()
        XCTAssertFalse(view.isAnimating)
    }

    func testRenderLoader() throws {
        guard let directory = ProcessInfo.processInfo.environment["BOWSER_LOADER_RENDER"] else {
            throw XCTSkip("Set BOWSER_LOADER_RENDER to render native loading states")
        }
        _ = NSApplication.shared
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let view = PageLoadingView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
            view.appearance = NSAppearance(named: appearance)
            view.loading = true
            view.layoutSubtreeIfNeeded()
            view.updateLayer()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("loader-\(name).png"))
        }
    }

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
