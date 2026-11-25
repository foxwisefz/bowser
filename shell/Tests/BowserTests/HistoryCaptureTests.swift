import AppKit
import WebKit
import XCTest
@testable import Bowser

@MainActor private final class HistoryRecorder: NSObject, WKScriptMessageHandler {
    var batches: [[String: Any]] = []
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { batches.append(body) }
    }
    var records: [[String: Any]] { batches.flatMap { $0["records"] as? [[String: Any]] ?? [] } }
}

@MainActor final class HistoryCaptureTests: XCTestCase {
    private func run(_ web: WKWebView, _ script: String, arguments: [String: Any] = [:], world: WKContentWorld = HistoryCapture.world) async throws -> Bool? {
        try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: world) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? Bool)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
    private func fixture() async throws -> (WKWebView, NSWindow, HistoryRecorder) {
        _ = NSApplication.shared
        let recorder = HistoryRecorder(), config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(recorder, contentWorld: HistoryCapture.world, name: "bowserHistory")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 550), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web; window.orderBack(nil)
        web.loadHTMLString("""
        <html><head><title>Fixture network page</title><style>.hidden{display:none}button{background:rgb(246,130,31)}</style></head>
        <body><article id="post"><p>First observed post about solar energy.</p><input value="secret-input"><div contenteditable>secret-draft</div><span class="hidden">secret-hidden</span><a rel="bookmark" href="/post/first">Open post</a></article><button>Orange network services</button><p style="visibility:hidden">secret-invisible</p><p style="opacity:0">secret-transparent</p></body></html>
        """, baseURL: URL(string: "https://fixture.test/feed"))
        for _ in 0..<200 {
            if !web.isLoading, (try? await web.evaluateJavaScript("document.title")) as? String == "Fixture network page" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await run(web, HistoryCapture.script)
        _ = try await run(web, "__bowserHistory.start('test',false)")
        return (web, window, recorder)
    }
    func testCapturesAppliedColorAndPermalinkButExcludesEditableAndHiddenText() async throws {
        let (web, window, recorder) = try await fixture()
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<100 { if recorder.records.count >= 2 { break }; try await Task.sleep(for: .milliseconds(30)) }
        let json = try String(decoding: JSONSerialization.data(withJSONObject: recorder.records), as: UTF8.self)
        XCTAssertTrue(json.contains("First observed post"), json)
        XCTAssertTrue(recorder.records.contains { ($0["url"] as? String) == "https://fixture.test/post/first" })
        XCTAssertTrue(json.contains("orange"), json)
        XCTAssertFalse(json.contains("secret-"), json)
        _ = web
    }
    func testRecycledFeedTextSurvivesAndStopDisconnectsObservers() async throws {
        let (web, window, recorder) = try await fixture()
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<100 { if !recorder.records.isEmpty { break }; try await Task.sleep(for: .milliseconds(30)) }
        _ = try await web.evaluateJavaScript("document.getElementById('post').innerHTML='<p>Second observed post about gardening.</p><a rel=bookmark href=/post/second>Open post</a>'")
        for _ in 0..<100 {
            if recorder.records.contains(where: { ($0["text"] as? String)?.contains("Second observed") == true }) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(recorder.records.contains { ($0["text"] as? String)?.contains("First observed") == true })
        XCTAssertTrue(recorder.records.contains { ($0["text"] as? String)?.contains("Second observed") == true })
        _ = try await run(web, "__bowserHistory.stop()")
        let count = recorder.records.count
        _ = try await web.evaluateJavaScript("document.getElementById('post').textContent='Must not be captured after pause'")
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(recorder.records.count, count)
    }
    func testInitialPictureWithoutAltTextCanBeCropped() async throws {
        let (web, window, recorder) = try await fixture()
        defer { window.orderOut(nil); window.contentView = nil }
        _ = try await run(web, "__bowserHistory.stop()")
        _ = try await run(web, """
        document.body.replaceChildren();
        const canvas=document.createElement('canvas');canvas.width=160;canvas.height=160;
        const ctx=canvas.getContext('2d');ctx.fillStyle='orange';ctx.fillRect(0,0,160,160);
        const image=new Image();image.src=canvas.toDataURL();await image.decode();document.body.append(image);
        """, world: .page)
        recorder.batches = []
        _ = try await run(web, "__bowserHistory.start('picture',true)")
        for _ in 0..<100 {
            if recorder.records.contains(where: { $0["image"] is [String: Any] }) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let picture = try XCTUnwrap(recorder.records.first { $0["image"] is [String: Any] })
        XCTAssertEqual(picture["text"] as? String, "")
        let rect = try XCTUnwrap(picture["image"] as? [String: Any])
        let valid = try await run(web, HistoryCapture.validateImage, arguments: ["rect": rect, "src": rect["src"]!])
        XCTAssertEqual(valid, true)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: rect["x"] as! Double, y: rect["y"] as! Double, width: rect["width"] as! Double, height: rect["height"] as! Double)
        configuration.snapshotWidth = 384
        let image = try await web.takeSnapshot(configuration: configuration)
        XCTAssertNotNil(image.tiffRepresentation)
    }
    func testPagePreviewSkipsEditableContentPasswordsVideoAndFrames() async throws {
        let (web, window, _) = try await fixture()
        defer { window.orderOut(nil); window.contentView = nil }
        let editable = try await run(web, "return " + HistoryCapture.validatePreview)
        XCTAssertEqual(editable, false)
        _ = try await web.evaluateJavaScript("document.body.innerHTML='<h1>Readable page</h1><input type=search>'")
        // Exercise visibility explicitly rather than depending on the frontmost app.
        _ = try await run(web, "Object.defineProperty(document,'visibilityState',{configurable:true,value:'hidden'})")
        let hidden = try await run(web, "return " + HistoryCapture.validatePreview)
        XCTAssertEqual(hidden, false)
        _ = try await run(web, "Object.defineProperty(document,'visibilityState',{configurable:true,value:'visible'})")
        let readable = try await run(web, "return " + HistoryCapture.validatePreview)
        XCTAssertEqual(readable, true)
        let configuration = HistoryCapture.previewConfiguration(bounds: web.bounds, scale: window.backingScaleFactor)
        let image = try await web.takeSnapshot(configuration: configuration)
        let pixels = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertLessThanOrEqual(pixels.width, 480, "The stored preview must stay bounded on Retina displays")
        for content in ["<input type=password style=display:none>", "<input value=private>", "<textarea>Draft</textarea>", "<video style=width:300px;height:200px></video>", "<iframe srcdoc=private></iframe>"] {
            _ = try await run(web, "document.body.innerHTML=content", arguments: ["content": content], world: .page)
            let allowed = try await run(web, "return " + HistoryCapture.validatePreview)
            XCTAssertEqual(allowed, false, content)
        }
    }
}
