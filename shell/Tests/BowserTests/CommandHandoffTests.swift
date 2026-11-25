import AppKit
import WebKit
import XCTest
@testable import Bowser

@MainActor final class CommandHandoffTests: XCTestCase {
    func testSecondCommandKReachesPageAndCommandLStaysInBrowser() async throws {
        let host = BrowserWindowController(profile: .defaultProfile)
        defer { CommandBar.shared.hide(); host.window?.close() }
        let window = try XCTUnwrap(host.window)
        window.makeKeyAndOrderFront(nil)
        let page = try XCTUnwrap(host.activeTab?.webView)
        page.loadHTMLString("""
        <html><body><input id="search"><script>
        window.handoffs = [];
        document.addEventListener('keydown', e => {
          if (e.metaKey && e.key.toLowerCase() === 'k') {
            e.preventDefault();
            window.handoffs.push({key:e.key, trusted:e.isTrusted});
            document.querySelector('input').focus();
          }
        });
        </script></body></html>
        """, baseURL: nil)
        try await wait { !page.isLoading }
        let app = AppDelegate()
        func key(_ value: String, repeatKey: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: NSApp.keyWindow?.windowNumber ?? window.windowNumber, context: nil,
                characters: value, charactersIgnoringModifiers: value, isARepeat: repeatKey,
                keyCode: value == "k" ? 40 : 37))
        }
        XCTAssertNil(app.handleShortcut(try key("k")))
        XCTAssertTrue(CommandBar.shared.isVisible)
        XCTAssertNil(app.handleShortcut(try key("k", repeatKey: true)))
        XCTAssertTrue(CommandBar.shared.isVisible, "Holding the key does not hand off")
        XCTAssertNil(app.handleShortcut(try key("l")))
        XCTAssertTrue(CommandBar.shared.isVisible, "Command-L continues editing Bowser's command bar")
        XCTAssertNil(app.handleShortcut(try key("k")))
        XCTAssertFalse(CommandBar.shared.isVisible)
        let deadline = Date().addingTimeInterval(5)
        while (try await page.evaluateJavaScript("window.handoffs.length") as? Int) != 1 {
            if Date() > deadline { XCTFail("The site did not receive Command-K"); return }
            try await Task.sleep(for: .milliseconds(30))
        }
        let trusted = try await page.evaluateJavaScript("window.handoffs[0].trusted") as? Bool
        XCTAssertEqual(trusted, true)
        let focused = try await page.evaluateJavaScript("document.activeElement.id") as? String
        XCTAssertEqual(focused, "search")
        XCTAssertNil(app.handleShortcut(try key("k")))
        XCTAssertTrue(CommandBar.shared.isVisible, "Next invocation opens Bowser again")
    }

    func testHandoffCannotTargetAnotherWindow() throws {
        let first = BrowserWindowController(profile: .defaultProfile)
        let second = BrowserWindowController(profile: .defaultProfile)
        defer { CommandBar.shared.hide(); first.window?.close(); second.window?.close() }
        CommandBar.shared.show(for: first)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: second.window!.windowNumber,
            context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        XCTAssertFalse(CommandBar.shared.handShortcutToPage(event, for: second))
        XCTAssertTrue(CommandBar.shared.isVisible)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            if Date() > deadline { XCTFail("Page load timed out"); return }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
}
