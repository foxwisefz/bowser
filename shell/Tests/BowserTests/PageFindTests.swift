import AppKit
import WebKit
import XCTest
@testable import Bowser

@MainActor final class PageFindTests: XCTestCase {
    func testNativeMatchingNoResultsAndTabDismissal() async throws {
        let host = BrowserWindowController(profile: .defaultProfile)
        defer { host.window?.close() }
        host.window?.makeKeyAndOrderFront(nil)
        let page = try XCTUnwrap(host.activeTab?.webView)
        page.loadHTMLString("<html><body><h1>Find your way</h1><p>Orchard apple</p><p>Another APPLE</p></body></html>", baseURL: nil)
        try await wait { !page.isLoading }
        host.showFindInPage()
        let bar = try XCTUnwrap(host.pageFindBar)
        XCTAssertFalse(bar.isHidden)
        bar.field.stringValue = "apple"
        bar.search()
        try await wait { bar.matchFound }
        bar.search(backwards: true)
        try await wait { bar.matchFound }
        bar.field.stringValue = "not present anywhere"
        bar.search()
        try await wait { bar.status.stringValue == "No matches" }
        XCTAssertFalse(bar.matchFound)
        // A stale reply must not replace the current query's result.
        bar.field.stringValue = "apple"
        bar.search()
        bar.field.stringValue = "missing phrase"
        bar.search()
        try await wait { bar.status.stringValue == "No matches" }
        bar.field.stringValue = ""
        bar.search()
        try await wait { bar.status.stringValue.isEmpty }
        XCTAssertFalse(bar.matchFound)
        _ = host.openTab()
        XCTAssertTrue(bar.isHidden)
        host.showFindInPage()
        XCTAssertFalse(bar.isHidden)
        bar.dismiss()
        XCTAssertTrue(bar.isHidden)
    }

    func testCommandFAndEscapeUseReceivingWindow() throws {
        let first = BrowserWindowController(profile: .defaultProfile)
        let second = BrowserWindowController(profile: .defaultProfile)
        defer { first.window?.close(); second.window?.close() }
        let app = AppDelegate()
        func event(_ key: String, code: UInt16, flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: first.window!.windowNumber, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
        }
        XCTAssertNil(app.handleShortcut(try event("f", code: 3, flags: .command)))
        XCTAssertFalse(try XCTUnwrap(first.pageFindBar).isHidden)
        XCTAssertNil(second.pageFindBar)
        XCTAssertNil(app.handleShortcut(try event("\u{1b}", code: 53, flags: [])))
        XCTAssertTrue(try XCTUnwrap(first.pageFindBar).isHidden)
    }

    func testRenderFindBar() throws {
        guard let path = ProcessInfo.processInfo.environment["BOWSER_FIND_RENDER"] else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: .aqua)
        let bar = PageFindBar(frame: NSRect(x: 30, y: 26, width: 420, height: 48))
        bar.field.stringValue = "design"
        window.contentView?.addSubview(bar)
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            if Date() > deadline { XCTFail("Find operation timed out"); return }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
}
