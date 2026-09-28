import AppKit
import XCTest
@testable import Bowser

@MainActor final class ShortcutWindowTests: XCTestCase {
    private final class OwnedPanel: NSPanel, BrowserOwnedPanel {
        weak var browserOwner: BrowserWindowController?
    }

    func testReceivingWindowWinsAndUtilityWindowsNeverFallThrough() throws {
        let first = BrowserWindowController(profile: .defaultProfile)
        let second = BrowserWindowController(profile: Profile(id: "shortcut-work", name: "Work", tint: nil, icon: nil, uuid: nil))
        let a = try XCTUnwrap(first.window), b = try XCTUnwrap(second.window)
        let utility = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        utility.isReleasedWhenClosed = false
        let panel = OwnedPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close(); utility.close(); a.close(); b.close() }
        XCTAssertTrue(AppDelegate.browserController(eventWindow: a, keyWindow: b, mainWindow: b) === first)
        XCTAssertTrue(AppDelegate.browserController(eventWindow: b, keyWindow: a, mainWindow: a) === second)
        XCTAssertNil(AppDelegate.browserController(eventWindow: utility, keyWindow: b, mainWindow: b))
        XCTAssertNil(AppDelegate.browserController(eventWindow: nil, keyWindow: utility, mainWindow: a))
        panel.browserOwner = first
        XCTAssertTrue(AppDelegate.browserController(eventWindow: panel, keyWindow: panel, mainWindow: b) === first)
        panel.browserOwner = second
        XCTAssertTrue(AppDelegate.browserController(eventWindow: panel, keyWindow: panel, mainWindow: a) === second)

        let app = AppDelegate()
        let a1 = try XCTUnwrap(first.activeTab), b1 = try XCTUnwrap(second.activeTab)
        let a2 = first.openTab(), b2 = second.openTab()
        func next(in window: NSWindow) throws -> NSEvent? {
            app.handleShortcut(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "]", charactersIgnoringModifiers: "]", isARepeat: false, keyCode: 30)))
        }
        XCTAssertNil(try next(in: a))
        XCTAssertTrue(first.activeTab === a1)
        XCTAssertTrue(second.activeTab === b2)
        XCTAssertNil(try next(in: b))
        XCTAssertTrue(second.activeTab === b1)
        XCTAssertTrue(first.activeTab === a1)
        XCTAssertNotNil(try next(in: utility))
        XCTAssertTrue(first.activeTab === a1)
        XCTAssertTrue(second.activeTab === b1)
        panel.browserOwner = first
        XCTAssertNil(try next(in: panel))
        XCTAssertTrue(first.activeTab === a2)
        XCTAssertTrue(second.activeTab === b1)
    }
}
