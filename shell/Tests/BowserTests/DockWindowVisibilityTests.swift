import AppKit
import XCTest
@testable import Bowser

@MainActor final class DockWindowVisibilityTests: XCTestCase {
    func testMinimizedProfileDockStaysHiddenThroughUpdatesAndReturnsOnRestore() async throws {
        let controller = BrowserWindowController(profile: .defaultProfile)
        let window = try XCTUnwrap(controller.window)
        let manager = SurfaceManager()
        let id = "minimize-dock-" + UUID().uuidString
        defer { manager.handle(["surface": "close", "id": id]); window.close() }
        window.makeKeyAndOrderFront(nil)
        manager.orderAllFront(parent: window)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let message: [String: Any] = ["surface": "show", "id": id, "kind": "edge", "attach": "screen",
                                     "profile": "default", "view": ["t": "text", "text": "Tabs"], "width": 48.0]
        manager.handle(message)
        let panel = try XCTUnwrap(NSApp.windows.first { !before.contains(ObjectIdentifier($0)) } as? NSPanel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertNil(panel.parent)
        window.miniaturize(nil)
        for _ in 0..<100 where !window.isMiniaturized { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(window.isMiniaturized)
        XCTAssertFalse(panel.isVisible)
        manager.handle(message)
        manager.pulseEdges(for: 0.01)
        manager.orderAllFront(parent: window)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertFalse(panel.isVisible)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        manager.orderAllFront(parent: window)
        XCTAssertFalse(window.isMiniaturized)
        XCTAssertTrue(panel.isVisible)
        XCTAssertNil(panel.parent)
    }

    func testMinimizingOtherProfileDoesNotHideFocusedProfilesDock() throws {
        let primary = BrowserWindowController(profile: .defaultProfile)
        let work = BrowserWindowController(profile: Profile(id: "dock-work", name: "Work", tint: nil, icon: nil, uuid: nil))
        let main = try XCTUnwrap(primary.window), other = try XCTUnwrap(work.window)
        let manager = SurfaceManager()
        let id = "other-dock-" + UUID().uuidString
        defer { manager.handle(["surface": "close", "id": id]); main.close(); other.close() }
        main.makeKeyAndOrderFront(nil)
        manager.orderAllFront(parent: main)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        manager.handle(["surface": "show", "id": id, "kind": "edge", "attach": "screen",
                        "profile": "default", "view": ["t": "text", "text": "Tabs"]])
        let panel = try XCTUnwrap(NSApp.windows.first { !before.contains(ObjectIdentifier($0)) } as? NSPanel)
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: other)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(AppDelegate.browserController(eventWindow: panel, keyWindow: panel, mainWindow: other) === primary)
        manager.orderAllFront(parent: other)
        XCTAssertFalse(panel.isVisible)
        manager.orderAllFront(parent: main)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(AppDelegate.browserController(eventWindow: panel, keyWindow: panel, mainWindow: other) === primary)
    }
}
