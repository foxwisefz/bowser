import AppKit
import BowserSurfaceKit
import XCTest
@testable import Bowser

@MainActor final class DockWindowVisibilityTests: XCTestCase {
    func testAutoHidePulseSurvivesContentUpdatesAndPointerExit() async throws {
        let controller = BrowserWindowController(profile: .defaultProfile)
        let window = try XCTUnwrap(controller.window)
        let manager = SurfaceManager()
        defer { manager.handle(["surface": "close", "id": "edge_dock"]); window.close() }
        window.makeKeyAndOrderFront(nil)
        manager.orderAllFront(parent: window)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let message: [String: Any] = ["surface": "show", "id": "edge_dock", "kind": "edge",
            "attach": "screen", "profile": "default", "width": 48.0,
            "view": ["t": "text", "text": "Tabs",
                     "dock_preferences": ["always_show": false, "reduce_motion": false]]]
        manager.handle(message)
        let panel = try XCTUnwrap(NSApp.windows.first { !before.contains(ObjectIdentifier($0)) } as? NSPanel)
        let hidden = panel.frame
        manager.pulseEdges(for: 3)
        let startingFrame = panel.frame
        manager.handle(message)
        XCTAssertEqual(panel.frame, startingFrame, "Content updates must not snap the reveal to its destination")
        manager.setEdgeRevealed("edge_dock", false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(panel.frame.minX, hidden.minX, "Pointer exit must not cancel a tab pulse")
        try await Task.sleep(for: .milliseconds(3000))
        if !NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) {
            XCTAssertEqual(panel.frame.minX, hidden.minX, accuracy: 0.5)
        }
    }

    func testDockSelectionRaisesOwningWindowBeforeBackendReply() throws {
        SurfaceHostServices.configure()
        let owner = BrowserWindowController(profile: .defaultProfile)
        let other = BrowserWindowController(profile: .defaultProfile)
        let window = try XCTUnwrap(owner.window)
        defer { window.close(); other.window?.close() }
        window.orderOut(nil)
        other.window?.makeKeyAndOrderFront(nil)
        let tab = try XCTUnwrap(owner.activeTab)
        SurfaceServices.shared.emit(["op": "event", "event": "surface", "surface": "edge_dock",
                                     "id": "select", "value": String(tab.webviewId)])
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(owner.pendingTabLesson, tab.webviewId)
        window.makeFirstResponder(nil)
        XCTAssertTrue(owner.activateTab(id: tab.webviewId))
        XCTAssertTrue(window.firstResponder === tab.webView)
    }

    func testReducedMotionSuppressesPulseButAllowsHoverAndAlwaysShow() throws {
        let controller = BrowserWindowController(profile: .defaultProfile)
        let window = try XCTUnwrap(controller.window)
        let manager = SurfaceManager()
        defer { manager.handle(["surface": "close", "id": "edge_dock"]); window.close() }
        window.makeKeyAndOrderFront(nil)
        manager.orderAllFront(parent: window)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        func show(always: Bool) {
            manager.handle(["surface": "show", "id": "edge_dock", "kind": "edge", "attach": "screen",
                "profile": "default", "width": 48.0,
                "view": ["t": "text", "text": "Tabs", "dock_preferences": ["always_show": always, "reduce_motion": true]]])
        }
        show(always: false)
        let panel = try XCTUnwrap(NSApp.windows.first { !before.contains(ObjectIdentifier($0)) } as? NSPanel)
        let hidden = panel.frame
        manager.pulseEdges(for: 0.01)
        XCTAssertEqual(panel.frame, hidden)
        manager.setEdgeRevealed("edge_dock", true)
        XCTAssertNotEqual(panel.frame, hidden)
        manager.setEdgeRevealed("edge_dock", false)
        XCTAssertEqual(panel.frame, hidden)
        show(always: true)
        let visible = panel.frame
        XCTAssertNotEqual(visible, hidden)
        manager.setEdgeRevealed("edge_dock", false)
        XCTAssertEqual(panel.frame, visible)
        show(always: false)
        XCTAssertEqual(panel.frame, hidden)
    }

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
