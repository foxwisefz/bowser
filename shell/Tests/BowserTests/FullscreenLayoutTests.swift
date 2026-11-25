import AppKit
import WebKit
import XCTest
@testable import Bowser

@MainActor final class FullscreenLayoutTests: XCTestCase {
    func testPageAppearanceSurvivesMovingBetweenDifferentlyThemedWindows() async throws {
        let application = NSApplication.shared
        let originalAppearance = application.appearance
        application.appearance = NSAppearance(named: .aqua)
        defer { application.appearance = originalAppearance }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let engine = EngineView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let inline = NSWindow(contentRect: engine.frame, styleMask: .borderless, backing: .buffered, defer: false)
        let fullscreen = NSWindow(contentRect: engine.frame, styleMask: .borderless, backing: .buffered, defer: false)
        inline.isReleasedWhenClosed = false
        fullscreen.isReleasedWhenClosed = false
        inline.appearance = NSAppearance(named: .darkAqua)
        inline.contentView = engine
        inline.orderBack(nil)
        fullscreen.orderBack(nil)
        defer { engine.tearDown(); inline.close(); fullscreen.close() }

        engine.webView.loadHTMLString("""
            <video id="player"></video>
            <script>
            window.scheme = matchMedia('(prefers-color-scheme: dark)');
            window.schemeChanges = 0;
            scheme.addEventListener('change', () => { schemeChanges++; });
            </script>
            """, baseURL: nil)
        for _ in 0..<100 where engine.webView.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        func eval(_ script: String) async throws -> Int {
            let result: Int = try await withCheckedThrowingContinuation { continuation in
                engine.webView.evaluateJavaScript(script, in: nil, in: .page) {
                    continuation.resume(with: $0.map { $0 as? Int ?? -1 })
                }
            }
            return result
        }
        let initial = try await eval("Number(scheme.matches)")
        XCTAssertEqual(initial, 0, "Browser chrome must not override the page's application color scheme")

        // WebKit moves this same WKWebView into a window that inherits the app
        // appearance, rather than the browser's page-tinted chrome appearance.
        fullscreen.contentView?.addSubview(engine.webView)
        try await Task.sleep(for: .milliseconds(150))
        let during = try await eval("Number(scheme.matches)")
        XCTAssertEqual(during, initial)
        engine.addSubview(engine.webView)
        try await Task.sleep(for: .milliseconds(150))
        let changes = try await eval("schemeChanges")
        XCTAssertEqual(changes, 0, "Entering/exiting fullscreen must not spuriously change prefers-color-scheme")

        // Genuine appearance changes must still reach the page, including
        // while WebKit owns it in the fullscreen window.
        fullscreen.contentView?.addSubview(engine.webView)
        application.appearance = NSAppearance(named: .darkAqua)
        for _ in 0..<100 {
            if (try await eval("Number(scheme.matches)")) == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let dark = try await eval("Number(scheme.matches)")
        XCTAssertEqual(dark, 1)
        let actualChanges = try await eval("schemeChanges")
        XCTAssertEqual(actualChanges, 1)
    }

    func testInlineLayoutDoesNotResizeWebViewWhileWebKitOwnsIt() {
        let engine = EngineView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { engine.tearDown() }
        engine.layout()
        XCTAssertEqual(engine.webView.frame, engine.bounds)

        // WebKit installs a placeholder and moves the existing web view into
        // its fullscreen container. The original browser can still relayout.
        let fullscreen = NSView(frame: NSRect(x: 0, y: 0, width: 1800, height: 1100))
        fullscreen.addSubview(engine.webView)
        engine.webView.frame = fullscreen.bounds
        engine.frame.size = NSSize(width: 900, height: 700)
        engine.layout()
        XCTAssertEqual(engine.webView.frame, fullscreen.bounds)

        engine.addSubview(engine.webView)
        engine.layout()
        XCTAssertEqual(engine.webView.frame, engine.bounds)
    }
}
