import AppKit
import WebKit
import XCTest
@testable import Bowser

@MainActor final class PageLoadingTests: XCTestCase {
    private final class VisibilityWindow: NSWindow {
        var visibleForTest = true
        override var occlusionState: NSWindow.OcclusionState { visibleForTest ? [.visible] : [] }
    }

    func testLineFollowsActiveTabAndStopsWhenNavigationStops() async throws {
        let server = try BrowserFixtureServer()
        defer { server.stop() }
        try await wait { server.origin != nil }
        let controller = BrowserWindowController(profile: .defaultProfile)
        defer { controller.window?.close() }
        let controls = try XCTUnwrap(controller.window?.toolbar?.items
            .first { $0.itemIdentifier == BrowserToolbar.controlsID }?.view as? NativeModuleSlot)
        func navigation() -> [String: Bool] {
            let snapshot = (try? JSONSerialization.jsonObject(with: controls.snapshot)) as? [String: Any]
            return snapshot?["navigation"] as? [String: Bool] ?? [:]
        }
        XCTAssertEqual(navigation()["canReload"], false)
        let first = try XCTUnwrap(controller.activeTab)
        first.load(urlString: try XCTUnwrap(server.origin) + "/slow-image")
        try await wait { controller.loadingLine.loading }
        try await wait { first.hasRenderedContent }
        XCTAssertEqual(navigation()["isLoading"], true)
        XCTAssertTrue(controller.loadingLine.loading, "Line continues while subresources load")
        let second = controller.openTab()
        XCTAssertEqual(navigation()["isLoading"], false)
        XCTAssertFalse(controller.loadingLine.loading, "Background loads do not animate the active tab")
        controller.activate(first)
        XCTAssertTrue(controller.loadingLine.loading)
        controls.onAction?("stop")
        try await wait { !controller.loadingLine.loading }
        XCTAssertTrue(controller.loadingLine.isHidden)
        let origin = try XCTUnwrap(server.origin)
        first.load(urlString: origin + "/page")
        try await wait { !first.webView.isLoading && navigation()["canGoBack"] == true }
        controls.onAction?("back")
        try await wait { navigation()["canGoForward"] == true }
        controller.activate(second)
        XCTAssertFalse(controller.loadingLine.loading)
        XCTAssertEqual(navigation()["canGoBack"], false)
        XCTAssertEqual(navigation()["canGoForward"], false)
    }

    func testLoaderStopsWhenHiddenAndDetached() async throws {
        _ = NSApplication.shared
        let view = ToolbarLoadingLine(frame: NSRect(x: 0, y: 0, width: 280, height: 2))
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

    func testReloadRetriesInitialNavigationStoppedBeforeCommit() async throws {
        let server = try BrowserFixtureServer()
        try await withPage(server: server) { view, origin in
            let destination = origin + "/slow"
            view.load(urlString: destination)
            try await wait("first request to reach the server") { server.requests("/slow") == 1 }
            view.webView.stopLoading()
            try await wait("cancelled provisional load to finish") { !view.webView.isLoading }
            XCTAssertNil(view.webView.backForwardList.currentItem)
            view.reloadPage()
            try await wait("retried request to reach the server") { server.requests("/slow") == 2 }
            try await wait("retried page to render") { view.hasRenderedContent && !view.webView.isLoading }
            XCTAssertEqual(view.webView.url?.absoluteString, destination)
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

    private func withPage(server fixture: BrowserFixtureServer? = nil,
                          _ body: @MainActor (EngineView, String) async throws -> Void) async throws {
        _ = NSApplication.shared
        let server = try fixture ?? BrowserFixtureServer()
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

    private func wait(_ state: String = "page state", file: StaticString = #filePath, line: UInt = #line,
                      _ condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(8)
        while !condition(), Date() < until { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out waiting for \(state)", file: file, line: line)
    }
}
