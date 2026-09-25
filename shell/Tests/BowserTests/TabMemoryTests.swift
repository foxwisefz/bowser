import AppKit
import Network
import WebKit
import XCTest
@testable import Bowser

private final class MemoryPageServer: @unchecked Sendable {
    let listener: NWListener
    private let lock = NSLock()
    private var ready = false
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { request, _, _, _ in
                var body = "<html><head><title>Memory fixture</title></head><body><input id='draft'><p style='height:3000px'>Content</p></body></html>"
                let requestText = String(decoding: request ?? Data(), as: UTF8.self)
                let missing = requestText.contains(" /missing")
                if missing { body = requestText.contains(" /missing-empty ") ? "" : "<html><head><title>Site error</title></head><body>Custom missing page</body></html>" }
                let status = missing ? "404 Not Found" : "200 OK"
                let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            self.lock.lock(); self.ready = true; self.lock.unlock()
        }
        listener.start(queue: .global())
    }
    deinit { listener.cancel() }
}

@MainActor final class TabMemoryTests: XCTestCase {
    private static let server = try? MemoryPageServer()
    private static let dataStore = WKWebsiteDataStore.nonPersistent()
    private static let fixtureWindow: NSWindow = {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }()
    func testEmptyHTTPFailureShowsExplanationAndPreservesSiteErrorPages() async throws {
        let server = try XCTUnwrap(Self.server)
        let view = try await loadedView(server)
        defer { view.tearDown(); view.removeFromSuperview() }
        Self.fixtureWindow.contentView = view
        let origin = "http://127.0.0.1:\(try XCTUnwrap(server.listener.port?.rawValue))"
        for (path, expected) in [("/missing-empty", "HTTP 404"), ("/missing-custom", "Custom missing page")] {
            view.load(urlString: origin + path)
            var text = ""
            for _ in 0..<250 {
                text = (try? await view.webView.evaluateJavaScript("document.body?.innerText || ''")) as? String ?? ""
                if !view.webView.isLoading && text.contains(expected) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(text.contains(expected), text)
            XCTAssertEqual(view.currentURLString, origin + path)
            if path == "/missing-custom" { XCTAssertFalse(text.contains("Try again")) }
        }
    }

    func testTimeoutPreservesDestinationAndBothRetryActionsLoadThePage() async throws {
        let server = try XCTUnwrap(Self.server)
        let view = try await loadedView(server)
        Self.fixtureWindow.contentView = view
        defer { view.tearDown(); view.removeFromSuperview() }
        let origin = "http://127.0.0.1:\(try XCTUnwrap(server.listener.port?.rawValue))"
        for retryLink in [false, true] {
            let destination = origin + (retryLink ? "/retry-link" : "/retry-reload")
            view.load(urlString: destination)
            view.webView.stopLoading()
            var observed: [String] = []
            view.onURLChange = { observed.append($0) }
            view.webView(view.webView, didFailProvisionalNavigation: nil,
                withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
            var href: String?
            for _ in 0..<250 {
                href = (try? await view.webView.evaluateJavaScript("document.querySelector('a')?.href")) as? String
                if !view.webView.isLoading && href == destination { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(href, destination)
            XCTAssertEqual(view.currentURLString, destination)
            XCTAssertFalse(observed.contains("about:blank"))
            if retryLink {
                _ = try await view.webView.evaluateJavaScript("document.querySelector('a').click()")
            } else {
                view.reloadPage()
            }
            try await waitForPage(view)
            XCTAssertEqual(view.webView.url?.absoluteString, destination)
            XCTAssertEqual(view.currentURLString, destination)
        }
    }

    func testPreviewCacheBoundsAndURLIdentity() {
        let cache = TabPreviewCache(budget: 10)
        cache.store(Data(repeating: 1, count: 6), for: 1, url: "first")
        cache.store(Data(repeating: 2, count: 6), for: 2, url: "second")
        XCTAssertNil(cache.data(for: 1, url: "first"))
        XCTAssertNil(cache.data(for: 2, url: "wrong"))
        XCTAssertEqual(cache.byteCount, 6)
        cache.store(Data(repeating: 3, count: 3), for: 2, url: "new")
        XCTAssertEqual(cache.byteCount, 3)
        cache.remove(2)
        XCTAssertEqual(cache.byteCount, 0)
        cache.store(Data(count: 11), for: 3, url: "large")
        XCTAssertEqual(cache.byteCount, 0)
    }

    func testTwoIndependentLoads() async throws {
        for _ in 0..<2 {
            let server = try XCTUnwrap(Self.server)
            let view = try await loadedView(server)
            view.tearDown()
        }
    }
    private func loadedView(_ server: MemoryPageServer, path: String = "/first") async throws -> EngineView {
        _ = NSApplication.shared
        for _ in 0..<100 {
            if server.isReady { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.dataStore
        let view = EngineView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: config)
        let window = Self.fixtureWindow
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.removeFromSuperview() }
        view.load(urlString: "http://127.0.0.1:\(port)\(path)")
        try await waitForPage(view)
        return view
    }
    private func waitForPage(_ view: EngineView) async throws {
        for _ in 0..<750 {
            if !view.webView.isLoading, view.webView.title == "Memory fixture" { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Fixture page did not load: URL=\(String(describing: view.webView.url)), title=\(String(describing: view.webView.title)), loading=\(view.webView.isLoading)")
    }

    func testSleepReleasesWebViewAndWakePreservesTabAndHistory() async throws {
        let server = try XCTUnwrap(Self.server)
        let view = try await loadedView(server)
        defer { view.tearDown() }
        let first = try XCTUnwrap(view.currentURLString)
        let second = first.replacingOccurrences(of: "/first", with: "/second")
        view.load(urlString: second)
        try await waitForPage(view)
        XCTAssertEqual(view.webView.backForwardList.backList.count, 1)
        let id = view.webviewId
        weak var old = view.webView
        let slept = await view.sleepIfSafe()
        XCTAssertTrue(slept)
        XCTAssertTrue(view.isSleeping)
        XCTAssertNotNil(view.inspectionUnavailableReason)
        XCTAssertEqual(view.currentURLString, second)
        XCTAssertEqual(view.currentTitle, "Memory fixture")
        XCTAssertTrue(EngineView.live[id] === view)
        for _ in 0..<100 {
            if old == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(old, "Sleeping must release the original page view")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let preview = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        TabPreviewCache.shared.store(preview, for: id, url: second)
        let window = Self.fixtureWindow
        window.isReleasedWhenClosed = false
        defer { view.removeFromSuperview() }
        window.contentView = view
        XCTAssertTrue(view.isShowingTabPreview, "Cached pixels must appear synchronously on selection")
        try await waitForPage(view)
        XCTAssertFalse(view.isShowingTabPreview)
        XCTAssertFalse(view.isSleeping)
        XCTAssertNil(view.inspectionUnavailableReason)
        XCTAssertEqual(view.webviewId, id)
        XCTAssertEqual(view.webView.url?.absoluteString, second)
        XCTAssertEqual(view.webView.backForwardList.backItem?.url.absoluteString, first)
    }

    func testVisibleAndEditedPagesAreNotUnloaded() async throws {
        let server = try XCTUnwrap(Self.server)
        let view = try await loadedView(server)
        defer { view.tearDown() }
        let window = Self.fixtureWindow
        window.isReleasedWhenClosed = false
        defer { view.removeFromSuperview() }
        window.contentView = view
        let visible = await view.sleepIfSafe()
        XCTAssertFalse(visible)
        view.removeFromSuperview()
        _ = try await view.webView.evaluateJavaScript("document.getElementById('draft').value = 'unsaved'")
        let edited = await view.sleepIfSafe()
        XCTAssertFalse(edited)
        XCTAssertFalse(view.isSleeping)
        view.noteUserEdit()
        _ = try await view.webView.evaluateJavaScript("document.getElementById('draft').value = ''")
        let interacted = await view.sleepIfSafe()
        XCTAssertFalse(interacted)
    }

    func testEditorsAndConferencingHostsStayProtected() {
        for host in ["docs.google.com", "meet.google.com", "app.zoom.us", "figma.com"] {
            XCTAssertFalse(TabMemory.allowsURL(URL(string: "https://\(host)/")!))
        }
        XCTAssertTrue(TabMemory.allowsURL(URL(string: "https://example.com/article")!))
    }

    func testMediaFramesAndEditableContentPreventUnloading() async throws {
        let server = try XCTUnwrap(Self.server)
        let view = try await loadedView(server)
        defer { view.tearDown() }
        for html in ["<audio></audio>", "<video></video>", "<iframe></iframe>", "<div contenteditable='true'>Draft</div>"] {
            _ = try await view.webView.callAsyncJavaScript("document.body.innerHTML = html", arguments: ["html": html], in: nil, contentWorld: .page)
            let slept = await view.sleepIfSafe()
            XCTAssertFalse(slept)
            XCTAssertFalse(view.isSleeping)
        }
    }
}
