import AppKit
import BowserSurfaceKit
import CoreGraphics
import Network
import WebKit
import XCTest
@testable import Bowser

private final class ResourceFixtureServer: @unchecked Sendable {
    let listener: NWListener
    private let lock = NSLock()
    private var ready = false
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }
    init(pdf: Data, resources: [String: (mime: String, bytes: Data)] = [:]) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            lock.lock(); ready = true; lock.unlock()
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { bytes, _, _, _ in
                let request = String(decoding: bytes ?? Data(), as: UTF8.self)
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let authorized = request.contains("pdf_session=allowed")
                var status = "200 OK", headers = "", type = "text/html"
                var body = Data("<html><body>Sign in</body></html>".utf8)
                if path == "/redirect" {
                    status = "302 Found"; headers = "Location: /document?dc=License\r\n"
                } else if path == "/media-redirect" {
                    status = "302 Found"; headers = "Location: /media/video?token=fixture\r\n"
                } else if path == "/wrapper" {
                    body = Data("<html><body><iframe src='data:application/pdf;base64,\(pdf.base64EncodedString())'></iframe></body></html>".utf8)
                } else if path == "/fake" {
                    type = "application/pdf"
                } else if ["/attachment", "/slow-attachment", "/broken-attachment"].contains(path) {
                    type = "video/mp4"; body = pdf
                    headers = "Content-Disposition: attachment; filename=recording.mp4\r\n"
                } else if path.hasPrefix("/document") && authorized {
                    type = "application/pdf"; body = pdf
                    headers = "Content-Disposition: inline; filename=license.pdf\r\n"
                } else if let resource = resources[path], authorized {
                    type = resource.mime; body = resource.bytes
                }
                let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n\(headers)Cache-Control: no-store\r\nConnection: close\r\n\r\n"
                if path == "/slow-attachment" || path == "/broken-attachment" {
                    let remainder = Data(body.dropFirst(1024))
                    connection.send(content: Data(head.utf8) + body.prefix(1024), completion: .contentProcessed { _ in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                            if path == "/broken-attachment" { connection.cancel() }
                            else { connection.send(content: remainder, completion: .contentProcessed { _ in connection.cancel() }) }
                        }
                    })
                    return
                }
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
    }
    deinit { listener.cancel() }
}

@MainActor final class ResourceDownloadTests: XCTestCase {
    private static let window: NSWindow = {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }()
    private func pdfBytes() throws -> Data {
        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 160, height: 160))
        context.endPDFPage(); context.closePDF()
        return bytes as Data
    }
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out", file: file, line: line)
        throw NSError(domain: "PDFTest", code: 1)
    }
    private func response(_ path: String, mime: String = "application/pdf", status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: path)!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": mime])!
    }
    func testMetadataAndValidation() throws {
        XCTAssertNotNil(ResourceDownload(response: response("https://example.test/getdoccopy?dc=License")))
        XCTAssertNil(ResourceDownload(response: response("https://example.test/file.pdf", mime: "text/html")))
        XCTAssertNil(ResourceDownload(response: response("https://example.test/file.pdf", status: 403)))
        let pdf = try XCTUnwrap(ResourceDownload(response: response("https://example.test/file.pdf")))
        XCTAssertEqual(pdf.filename("../../License"), "License.pdf")
        XCTAssertEqual(pdf.filename("License.PDF"), "License.PDF")
        XCTAssertEqual(pdf.filename(""), "download.pdf")
        XCTAssertNil(ResourceDownload(embeddedURL: "data:application/pdfx;base64,AAAA"))
    }

    func testAttachmentResponsePolicy() {
        for mime in ["video/mp4", "audio/mpeg", "image/png", "application/pdf", "text/plain", "text/html"] {
            for disposition in ["attachment", " AtTaChMeNt ; filename=clip.mp4", "inline; filename=attachment", ""] {
                let response = HTTPURLResponse(url: URL(string: "https://example.test/file")!, statusCode: 200,
                    httpVersion: nil, headerFields: ["Content-Type": mime, "Content-Disposition": disposition])!
                let expected: WKNavigationResponsePolicy = disposition.lowercased().contains("inline") || disposition.isEmpty ? .allow : .download
                XCTAssertEqual(EngineView.responsePolicy(response, canShowMIMEType: true), expected)
                XCTAssertEqual(EngineView.responsePolicy(response, canShowMIMEType: false), .download)
            }
        }
    }

    func testPlayableAttachmentDownloadsThroughNavigationDelegate() async throws {
        let bytes = Data("original attachment bytes".utf8)
        let server = try ResourceFixtureServer(pdf: bytes)
        defer { server.listener.cancel() }
        try await wait { server.isReady }
        let origin = "http://127.0.0.1:\(server.listener.port!.rawValue)"
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let engine = EngineView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: config)
        Self.window.contentView = engine
        defer { engine.tearDown(); engine.removeFromSuperview() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manager = NativeDownloads.shared, previousDirectory = manager.destinationDirectory
        manager.destinationDirectory = folder
        defer { manager.destinationDirectory = previousDirectory; try? FileManager.default.removeItem(at: folder) }
        engine.load(urlString: origin + "/html")
        try await wait { engine.webView.url?.path == "/html" && !engine.webView.isLoading }
        engine.load(urlString: origin + "/attachment")
        let destination = folder.appendingPathComponent("recording.mp4")
        try await wait { FileManager.default.fileExists(atPath: destination.path) && manager.snapshot.isEmpty }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(engine.webView.url?.path, "/html")
        XCTAssertNil(engine.downloadableResource)
    }

    func testDownloadPopupClosesWithVisibleProgressAndCompletionWhileRealPopupsSurvive() async throws {
        let bytes = Data(repeating: 42, count: 262144)
        let sourceServer = try ResourceFixtureServer(pdf: bytes), fileServer = try ResourceFixtureServer(pdf: bytes)
        defer { sourceServer.listener.cancel(); fileServer.listener.cancel() }
        try await wait { sourceServer.isReady && fileServer.isReady }
        let controller = BrowserWindowController(profile: .defaultProfile)
        defer { controller.window?.close() }
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let source = controller.openTab(configuration: config)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manager = NativeDownloads.shared, previousDirectory = manager.destinationDirectory
        manager.destinationDirectory = folder
        defer { manager.destinationDirectory = previousDirectory; try? FileManager.default.removeItem(at: folder) }
        source.load(urlString: "http://127.0.0.1:\(sourceServer.listener.port!.rawValue)/html")
        try await wait { source.webView.url?.path == "/html" && !source.webView.isLoading }
        let baseline = controller.tabs.count
        let fileOrigin = "http://127.0.0.1:\(fileServer.listener.port!.rawValue)"
        func open(_ path: String) async throws {
            _ = try await source.webView.callAsyncJavaScript("""
                const a = document.createElement('a'); a.href = url; a.download = ''; a.target = '_blank';
                document.body.append(a); a.click(); return true;
                """, arguments: ["url": fileOrigin + path], in: nil, contentWorld: .page)
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func activities() -> [DownloadActivityView] {
            descendants(controller.window!.contentView!).compactMap { $0 as? DownloadActivityView }
        }
        try await open("/slow-attachment")
        try await wait { activities().contains { $0.state == .downloading } && controller.tabs.count == baseline }
        let activity = try XCTUnwrap(activities().first)
        XCTAssertTrue(controller.activeTab === source)
        XCTAssertFalse(activity.progressBar.isHidden)
        XCTAssertTrue(activity.status.stringValue.contains("Downloading"))
        try await wait { if case .saved = activity.state { return true }; return false }
        XCTAssertEqual(activity.status.stringValue, "Download complete")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("recording.mp4")), bytes)
        XCTAssertEqual(controller.tabs.count, baseline)
        XCTAssertTrue(controller.activeTab === source)
        activity.dismissActivity()
        XCTAssertTrue(activities().isEmpty)

        try await open("/html")
        try await wait { controller.tabs.count == baseline + 1 && controller.activeTab?.webView.url?.path == "/html" && controller.activeTab?.webView.isLoading == false }
        let realPopup = try XCTUnwrap(controller.activeTab)
        XCTAssertFalse(realPopup === source)
        realPopup.load(urlString: fileOrigin + "/broken-attachment")
        try await wait { activities().contains { $0.state == .failed } }
        XCTAssertTrue(controller.tabs.contains { $0 === realPopup })
        XCTAssertTrue(controller.activeTab === realPopup)
        XCTAssertTrue(manager.snapshot.isEmpty)
    }

    func testDownloadActivityProgressConcurrentTransfersAndDismissal() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let first = DownloadActivityView(), second = DownloadActivityView()
        first.show(in: window); second.show(in: window)
        let progress = Progress(totalUnitCount: 1000); progress.completedUnitCount = 400
        first.start(filename: "recording.mp4", progress: progress)
        second.start(filename: "license.pdf", progress: nil)
        XCTAssertEqual(first.progressBar.doubleValue, 0.4, accuracy: 0.01)
        XCTAssertFalse(first.progressBar.isIndeterminate)
        XCTAssertTrue(second.progressBar.isIndeterminate)
        first.finish(.success(URL(fileURLWithPath: "/tmp/recording.mp4")))
        XCTAssertEqual(second.state, .downloading)
        window.contentView!.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(first.bounds.height, 40)
        XCTAssertGreaterThan(second.bounds.height, 40)
        if ProcessInfo.processInfo.environment["BOWSER_DOWNLOAD_PREVIEW"] != nil {
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(200))
            window.displayIfNeeded()
        }
        if let path = ProcessInfo.processInfo.environment["BOWSER_DOWNLOAD_PREVIEW"],
           let content = window.contentView,
           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        first.dismissActivity()
        XCTAssertNotNil(second.superview)
        second.finish(.failure(NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connection interrupted"])))
        XCTAssertEqual(second.state, .failed)
        XCTAssertTrue(second.status.stringValue.contains("Connection interrupted"))
        second.dismissActivity()
        XCTAssertTrue(window.contentView!.subviews.isEmpty)
    }

    func testAuthenticatedDownloadRedirectDuplicatesSaveAsAndInvalidResponses() async throws {
        _ = NSApplication.shared
        let bytes = try pdfBytes(), server = try ResourceFixtureServer(pdf: bytes)
        defer { server.listener.cancel() }
        try await wait { server.isReady }
        let origin = "http://127.0.0.1:\(server.listener.port!.rawValue)"
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let engine = EngineView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: config)
        Self.window.contentView = engine
        defer { engine.tearDown(); engine.removeFromSuperview() }
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "pdf_session", .value: "allowed"]))
        await config.websiteDataStore.httpCookieStore.setCookie(cookie)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = NativeDownloads(); manager.destinationDirectory = folder
        engine.load(urlString: origin + "/document?dc=License")
        try await wait { engine.downloadableResource != nil && !engine.webView.isLoading }
        XCTAssertEqual(engine.downloadableResource?.url.absoluteString, origin + "/document?dc=License")
        let previewURL = engine.webView.url

        func download(_ path: String, mode: NativeDownloads.Destination = .downloads) async throws -> Result<URL, Error> {
            let document = try XCTUnwrap(ResourceDownload(response: response(origin + path)))
            var result: Result<URL, Error>?
            manager.startResource(document, in: engine.webView, tab: engine.webviewId, profile: "test", destination: mode) { result = $0 }
            try await wait { result != nil }
            XCTAssertTrue(manager.snapshot.isEmpty)
            return try XCTUnwrap(result)
        }
        let first = try await download("/redirect").get()
        XCTAssertEqual(first.lastPathComponent, "license.pdf")
        XCTAssertEqual(try Data(contentsOf: first), bytes)
        let second = try await download("/redirect").get()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: second), bytes)
        XCTAssertEqual(engine.webView.url, previewURL)

        let chosen = folder.appendingPathComponent("chosen.pdf")
        try Data("original".utf8).write(to: chosen)
        manager.chooseDestination = { _, _, completion in completion(chosen) }
        let saved = try await download("/document", mode: .saveAs).get()
        XCTAssertEqual(saved, chosen)
        XCTAssertEqual(try Data(contentsOf: chosen), bytes)
        for path in ["/expired", "/fake"] {
            let result = try await download(path, mode: .saveAs)
            if case .success = result { XCTFail("Accepted a non-PDF response") }
            XCTAssertEqual(try Data(contentsOf: chosen), bytes)
        }

        var cancelled = false, unexpectedCompletion = false
        manager.chooseDestination = { _, _, completion in cancelled = true; completion(nil) }
        manager.startResource(try XCTUnwrap(engine.downloadableResource), in: engine.webView, tab: engine.webviewId,
                         profile: "test", destination: .saveAs) { _ in unexpectedCompletion = true }
        try await wait { cancelled && manager.snapshot.isEmpty }
        XCTAssertFalse(unexpectedCompletion)

        await config.websiteDataStore.httpCookieStore.deleteCookie(cookie)
        if case .success = try await download("/document") { XCTFail("Downloaded without the required session cookie") }
        engine.load(urlString: origin + "/html")
        try await wait { engine.webView.url?.path == "/html" && !engine.webView.isLoading }
        XCTAssertNil(engine.downloadableResource)
    }

    func testMenuAndCompletionNotice() throws {
        _ = NSApplication.shared
        let target = AppDelegate()
        let menus = NativeUIPresentation.menus(NativeMenuContext(target: target, siteHost: nil, targets: [:], siteActions: []))
        let file = try XCTUnwrap(menus.main.items.first { $0.submenu?.title == "File" }?.submenu)
        let item = try XCTUnwrap(file.items.first { $0.action == #selector(AppDelegate.saveResource(_:)) })
        XCTAssertEqual(item.keyEquivalent, "s")
        XCTAssertTrue(item.target === target)
        XCTAssertFalse(target.validateMenuItem(item))
        let activity = DownloadActivityView()
        activity.finish(.success(URL(fileURLWithPath: "/tmp/license.pdf")))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let buttons = descendants(activity).compactMap { $0 as? NSButton }
        XCTAssertTrue(buttons.contains { $0.title == "Show in Finder" && !$0.isHidden && $0.action != nil })
        XCTAssertTrue(buttons.contains { $0.action == #selector(DownloadActivityView.dismissActivity) })
        XCTAssertEqual(activity.status.stringValue, "Download complete")
    }

    func testWrappedDataPDFDownloadsOriginalBytesAndClearsOnNavigation() async throws {
        _ = NSApplication.shared
        let bytes = try pdfBytes(), server = try ResourceFixtureServer(pdf: bytes)
        defer { server.listener.cancel() }
        try await wait { server.isReady }
        let origin = "http://127.0.0.1:\(server.listener.port!.rawValue)"
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let engine = EngineView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: config)
        Self.window.contentView = engine
        defer { engine.tearDown(); engine.removeFromSuperview() }
        engine.load(urlString: origin + "/wrapper")
        try await wait { engine.downloadableResource != nil }
        let document = try XCTUnwrap(engine.downloadableResource)
        XCTAssertEqual(document.url.scheme, "data")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = NativeDownloads(); manager.destinationDirectory = folder
        var result: Result<URL, Error>?
        manager.startResource(document, in: engine.webView, tab: engine.webviewId, profile: "test", destination: .downloads) { result = $0 }
        try await wait { result != nil }
        let url = try XCTUnwrap(result).get()
        XCTAssertEqual(url.pathExtension, "pdf")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(engine.webView.url?.path, "/wrapper")
        engine.load(urlString: origin + "/html")
        try await wait { engine.webView.url?.path == "/html" && !engine.webView.isLoading }
        XCTAssertNil(engine.downloadableResource)
        engine.webView.goBack()
        try await wait { engine.webView.url?.path == "/wrapper" && engine.downloadableResource != nil }
    }

    func testOriginalDocumentFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["BOWSER_TEST_PDF_FIXTURE"] else {
            throw XCTSkip("Set BOWSER_TEST_PDF_FIXTURE to a local original PDF for byte-for-byte verification")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let document = try XCTUnwrap(ResourceDownload(embeddedURL: "data:application/pdf;base64," + bytes.base64EncodedString()))
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = NativeDownloads(); manager.destinationDirectory = folder
        var result: Result<URL, Error>?
        manager.startResource(document, in: webView, tab: 900, profile: "test", destination: .downloads) { result = $0 }
        try await wait { result != nil }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result).get()), bytes)
    }

    func testFormatsFilenamesAndResponseValidation() throws {
        for (mime, ext) in [("video/mp4", "mp4"), ("audio/mpeg", "mp3"), ("image/png", "png"),
                            ("text/plain", "txt"), ("application/json", "json"), ("image/svg+xml", "svg")] {
            let resource = try XCTUnwrap(ResourceDownload(response: response("https://example.test/resource?token=fixture", mime: mime, status: 206)))
            XCTAssertEqual(resource.filename("resource"), "resource." + ext)
            XCTAssertEqual(resource.filename("original." + ext), "original." + ext)
            XCTAssertEqual(resource.url.query, "token=fixture")
            XCTAssertTrue(resource.accepts(response("https://example.test/redirect", mime: mime)))
            XCTAssertFalse(resource.accepts(response("https://example.test/login", mime: "text/html")))
            XCTAssertFalse(resource.accepts(response("https://example.test/login", mime: "application/xhtml+xml")))
            XCTAssertFalse(resource.accepts(response("https://example.test/expired", mime: mime, status: 403)))
        }
        let video = try XCTUnwrap(ResourceDownload(response: response("https://example.test/video", mime: "video/mp4")))
        XCTAssertFalse(video.accepts(response("https://example.test/not-video", mime: "application/json")))
    }

    func testOriginalBytesAcrossFormatsWithSignedQueryAndCookies() async throws {
        let resources: [String: (mime: String, bytes: Data)] = [
            "/media/video?token=fixture": ("video/mp4", Data([0,0,0,24]) + Data("ftypisom\0\0\0\0isommp42".utf8)),
            "/media/audio": ("audio/mpeg", Data("ID3fixture-audio".utf8)),
            "/media/image": ("image/png", Data([137,80,78,71,13,10,26,10])),
            "/media/text": ("text/plain", Data("Original text\n".utf8)),
            "/media/json": ("application/json", Data("{\"original\":true}".utf8))
        ]
        let server = try ResourceFixtureServer(pdf: pdfBytes(), resources: resources)
        defer { server.listener.cancel() }
        try await wait { server.isReady }
        let origin = "http://127.0.0.1:\(server.listener.port!.rawValue)"
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "pdf_session", .value: "allowed"]))
        await config.websiteDataStore.httpCookieStore.setCookie(cookie)
        webView.load(URLRequest(url: URL(string: origin + "/html")!))
        try await wait { webView.url?.path == "/html" && !webView.isLoading }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = NativeDownloads(); manager.destinationDirectory = folder
        for path in resources.keys.sorted() {
            let fixture = resources[path]!
            let resource = try XCTUnwrap(ResourceDownload(response: response(origin + path, mime: fixture.mime)))
            var result: Result<URL, Error>?
            manager.startResource(resource, in: webView, tab: 900, profile: "test", destination: .downloads) { result = $0 }
            try await wait { result != nil }
            guard case .success(let saved) = result else {
                if case .failure(let error) = result {
                    let failure = error as NSError
                    XCTFail("Fixture \(fixture.mime) failed: \(failure.domain) \(failure.code) \(failure.localizedDescription)")
                }
                return
            }
            XCTAssertEqual(try Data(contentsOf: saved), fixture.bytes)
            XCTAssertFalse(saved.lastPathComponent.hasSuffix(".pdf"))
        }
        let video = try XCTUnwrap(ResourceDownload(response: response(origin + "/media-redirect", mime: "video/mp4")))
        var result: Result<URL, Error>?
        manager.startResource(video, in: webView, tab: 900, profile: "test", destination: .downloads) { result = $0 }
        try await wait { result != nil }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result).get()), resources["/media/video?token=fixture"]?.bytes)
        await config.websiteDataStore.httpCookieStore.deleteCookie(cookie)
        result = nil
        manager.startResource(video, in: webView, tab: 900, profile: "test", destination: .downloads) { result = $0 }
        try await wait { result != nil }
        if case .success = result { XCTFail("Saved an expired-session HTML response as media") }
        XCTAssertTrue(manager.snapshot.isEmpty)
    }

    func testOriginalRemoteResourceFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["BOWSER_TEST_RESOURCE_FIXTURE"] else {
            throw XCTSkip("Set BOWSER_TEST_RESOURCE_FIXTURE to private resource metadata for original-byte verification")
        }
        let fixture = try JSONDecoder().decode(RemoteFixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let resource = try XCTUnwrap(ResourceDownload(response: response(fixture.url, mime: fixture.mime)))
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let engine = EngineView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: config)
        Self.window.contentView = engine
        defer { engine.tearDown(); engine.removeFromSuperview() }
        engine.webView.loadHTMLString("<html><body>Resource source</body></html>", baseURL: resource.url)
        try await wait { engine.webView.url != nil && !engine.webView.isLoading }
        let sourceURL = engine.webView.url
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = NativeDownloads(); manager.destinationDirectory = folder
        var result: Result<URL, Error>?
        manager.startResource(resource, in: engine.webView, tab: engine.webviewId,
                              profile: "test", destination: .downloads) { result = $0 }
        try await wait { result != nil }
        guard case .success(let saved) = result else {
            XCTFail("Original remote resource download failed"); return
        }
        XCTAssertEqual(saved.pathExtension, "mp4")
        XCTAssertEqual(try Data(contentsOf: saved), try Data(contentsOf: URL(fileURLWithPath: fixture.expected_file)))
        XCTAssertTrue(engine.webView.url == sourceURL)
    }

    func testRemoteAttachmentFromNewWindowDownloadLink() async throws {
        guard let path = ProcessInfo.processInfo.environment["BOWSER_TEST_ATTACHMENT_FIXTURE"] else {
            throw XCTSkip("Set BOWSER_TEST_ATTACHMENT_FIXTURE for a private attachment reproduction")
        }
        let fixture = try JSONDecoder().decode(RemoteFixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let server = try ResourceFixtureServer(pdf: Data())
        defer { server.listener.cancel() }
        try await wait { server.isReady }
        let controller = BrowserWindowController(profile: .defaultProfile)
        defer { controller.window?.close() }
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let source = controller.openTab(configuration: config)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manager = NativeDownloads.shared, previousDirectory = manager.destinationDirectory
        manager.destinationDirectory = folder
        defer { manager.destinationDirectory = previousDirectory; try? FileManager.default.removeItem(at: folder) }
        source.load(urlString: "http://127.0.0.1:\(server.listener.port!.rawValue)/html")
        try await wait { source.webView.url?.path == "/html" && !source.webView.isLoading }
        let tabCount = controller.tabs.count
        _ = try await source.webView.callAsyncJavaScript("""
            const a = document.createElement('a'); a.href = url; a.download = ''; a.target = '_blank';
            a.textContent = 'Download file'; document.body.append(a); a.click(); return true;
            """, arguments: ["url": fixture.url], in: nil, contentWorld: .page)
        try await wait {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == false) && manager.snapshot.isEmpty
        }
        let saved = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(saved.pathExtension, "mp4")
        XCTAssertEqual(try Data(contentsOf: saved), try Data(contentsOf: URL(fileURLWithPath: fixture.expected_file)))
        XCTAssertEqual(source.webView.url?.path, "/html")
        XCTAssertEqual(controller.tabs.count, tabCount)
        XCTAssertTrue(controller.activeTab === source)
    }

    private struct RemoteFixture: Decodable {
        let url: String
        let mime: String
        let expected_file: String
    }
}
