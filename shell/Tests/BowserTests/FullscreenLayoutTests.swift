import AppKit
import XCTest
@testable import Bowser

@MainActor final class FullscreenLayoutTests: XCTestCase {
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
