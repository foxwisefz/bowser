import AppKit
import WebKit
import BowserSurfaceKit
import XCTest
@testable import Bowser

@MainActor final class PageKeyboardTests: XCTestCase {
    private func event(_ text: String, flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: keyCode))
    }

    func testOnlyWebKitTextFallbackStopsBeforeWindowAlert() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let engine = EngineView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: configuration)
        let window = QuietKeyboardWindow(contentRect: engine.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = engine
        defer { engine.tearDown(); window.close() }
        XCTAssertTrue(window.makeFirstResponder(engine.webView))
        let tail = KeyboardTail()
        engine.nextResponder = tail
        for text in ["a", "A", "é", " ", "🙂"] {
            engine.keyDown(with: try event(text, window: window))
        }
        XCTAssertTrue(tail.keys.isEmpty, "Text already offered to WebKit must not reach the window beep")
        for (text, flags): (String, NSEvent.ModifierFlags) in [("k", .command), ("a", .control), ("\u{F702}", []), ("\r", []), ("\u{1b}", [])] {
            engine.keyDown(with: try event(text, flags: flags, window: window))
        }
        XCTAssertEqual(tail.keys, ["k", "a", "\u{F702}", "\r", "\u{1b}"])
        window.makeFirstResponder(nil)
        engine.keyDown(with: try event("z", window: window))
        XCTAssertEqual(tail.keys.last, "z", "Native responders retain their ordinary fallback")
    }

    func testTypingAndEditingAcrossRichPlainMultilineAndPasswordFields() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let engine = EngineView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: configuration)
        let window = QuietKeyboardWindow(contentRect: engine.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = engine
        defer { engine.tearDown(); window.close() }
        window.makeKeyAndOrderFront(nil)
        let previousMenu = NSApp.mainMenu
        NSApp.mainMenu = NativeUIPresentation.menus(NativeMenuContext(target: NSObject(), siteHost: nil, targets: [:], siteActions: [])).main
        defer { NSApp.mainMenu = previousMenu }
        // XCTest is not the foreground app. Resolve the real Edit menu's
        // target to this fixture, instead of depending on NSApp.keyWindow.
        let editMenu = try XCTUnwrap(NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Edit" })
        let selectAll = try XCTUnwrap(editMenu.items.first { $0.action == NSSelectorFromString("selectAll:") })
        selectAll.target = engine.webView
        XCTAssertTrue(engine.webView.responds(to: try XCTUnwrap(selectAll.action)))
        engine.webView.loadHTMLString("<html><body><div id='editor' contenteditable='true'><p><br></p></div><input id='plain'><textarea id='multiline'></textarea><input id='secret' type='password'></body></html>", baseURL: nil)
        var ready = false
        for _ in 0..<200 {
            ready = (try? await engine.webView.evaluateJavaScript("!!document.getElementById('editor')")) as? Bool == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(ready)
        window.makeFirstResponder(engine.webView)
        for id in ["editor", "plain", "multiline", "secret"] {
            _ = try await engine.webView.evaluateJavaScript("document.getElementById('\(id)').focus()")
            for (text, code): (String, UInt16) in [("a", 0), ("b", 11)] {
                window.sendEvent(try event(text, keyCode: code, window: window))
                try await Task.sleep(for: .milliseconds(100))
            }
            let read = "document.getElementById('\(id)')." + (id == "editor" ? "textContent" : "value")
            var value = try await engine.webView.evaluateJavaScript(read) as? String
            XCTAssertEqual(value, "ab", id)
            window.sendEvent(try event("\u{7f}", keyCode: 51, window: window))
            try await Task.sleep(for: .milliseconds(100))
            value = try await engine.webView.evaluateJavaScript(read) as? String
            XCTAssertEqual(value, "a", "Backspace: " + id)
            XCTAssertTrue(try XCTUnwrap(NSApp.mainMenu).performKeyEquivalent(with: try event("a", flags: .command, window: window)))
            try await Task.sleep(for: .milliseconds(100))
            window.sendEvent(try event("x", keyCode: 7, window: window))
            try await Task.sleep(for: .milliseconds(100))
            value = try await engine.webView.evaluateJavaScript(read) as? String
            XCTAssertEqual(value, "x", "Command-A replacement: " + id)
        }
        _ = try await engine.webView.evaluateJavaScript("document.getElementById('plain').focus()")
        window.sendEvent(try event("\t", keyCode: 48, window: window))
        try await Task.sleep(for: .milliseconds(100))
        let focused = try await engine.webView.evaluateJavaScript("document.activeElement.id") as? String
        XCTAssertEqual(focused, "multiline", "Tab retains website focus traversal")
        XCTAssertTrue(engine.hasUnsavedInteraction, "Edit tracking continues protecting drafts from tab unloading")
        XCTAssertTrue(window.unhandledKeys.isEmpty, "Unexpected keys reached the window fallback: \(window.unhandledKeys)")
    }
}

@MainActor private final class KeyboardTail: NSResponder {
    var keys: [String] = []
    override func keyDown(with event: NSEvent) { keys.append(event.characters ?? "") }
}

// Capture unexpected test fallbacks instead of playing the system alert.
@MainActor private final class QuietKeyboardWindow: NSWindow {
    var unhandledKeys: [String] = []
    override func keyDown(with event: NSEvent) { unhandledKeys.append(event.characters ?? "") }
}
