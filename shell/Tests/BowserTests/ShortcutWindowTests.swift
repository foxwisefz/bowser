import AppKit
import XCTest
@testable import Bowser

@MainActor final class ShortcutWindowTests: XCTestCase {
    func testLessonChoiceAndProgressiveRetirement() {
        XCTAssertEqual(TabShortcutLesson.lesson(order: [1, 2, 3, 4], from: 2, to: 3, last: 1), .next)
        XCTAssertEqual(TabShortcutLesson.lesson(order: [1, 2, 3, 4], from: 2, to: 1, last: 1), .last)
        XCTAssertEqual(TabShortcutLesson.lesson(order: [1, 2, 3, 4], from: 1, to: 4, last: nil), .previous)
        XCTAssertNil(TabShortcutLesson.lesson(order: [1, 2, 3, 4], from: 1, to: 3, last: nil))
        let name = "TabLessonsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(TabShortcutLesson.shouldShow(.next, now: 100, defaults: defaults))
        XCTAssertFalse(TabShortcutLesson.shouldShow(.last, now: 110, defaults: defaults))
        XCTAssertTrue(TabShortcutLesson.shouldShow(.next, now: 200, defaults: defaults))
        XCTAssertTrue(TabShortcutLesson.shouldShow(.next, now: 300, defaults: defaults))
        XCTAssertFalse(TabShortcutLesson.shouldShow(.next, now: 400, defaults: defaults))
        TabShortcutLesson.learned(.last, defaults: defaults)
        XCTAssertFalse(TabShortcutLesson.shouldShow(.last, now: 500, defaults: defaults))
    }

    func testLastFocusedTabIsWindowLocalAndSkipsClosedTab() throws {
        let host = BrowserWindowController(profile: .defaultProfile)
        defer { host.window?.close() }
        let a = try XCTUnwrap(host.activeTab)
        let b = host.openTab()
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .control, timestamp: 0, windowNumber: host.window!.windowNumber,
            context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        XCTAssertNil(AppDelegate().handleShortcut(event))
        XCTAssertTrue(host.activeTab === a)
        host.activateLastFocusedTab()
        XCTAssertTrue(host.activeTab === b)
        host.closeTab(a)
        host.activateLastFocusedTab()
        XCTAssertTrue(host.activeTab === b)
    }

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
