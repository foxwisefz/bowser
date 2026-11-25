import XCTest
import SwiftUI
import BowserSurfaceKit
@testable import Bowser

final class SurfaceStateTests: XCTestCase {
    @MainActor
    func testScreenDockIsIndependentAndAvailableAcrossSpaces() throws {
        let controller = BrowserWindowController(profile: .defaultProfile)
        let owner = try XCTUnwrap(controller.window)
        defer { owner.close() }
        let manager = SurfaceManager()
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let keyBefore = NSApp.keyWindow
        manager.handle(["surface": "show", "id": "space-dock-test", "kind": "edge", "attach": "screen",
                        "view": ["t": "text", "text": "Tabs"], "width": 48.0])
        defer { manager.handle(["surface": "close", "id": "space-dock-test"]) }
        let panel = try XCTUnwrap(NSApp.windows.first { !before.contains(ObjectIdentifier($0)) } as? NSPanel)
        XCTAssertNil(panel.parent)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(panel.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(NSApp.keyWindow === keyBefore)
    }

    @MainActor
    func testKeyedInsertionPreservesActualTextFieldFocus() throws {
        _ = NSApplication.shared
        let field: [String: Any] = ["t": "textfield", "key": "name", "event": "name", "value": "Reading"]
        let host = NSHostingView(rootView: SurfaceTreeView(surfaceId: "focus-test", node: ["t": "vstack", "children": [field]]))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        window.makeFirstResponder(editor)
        let responder = try XCTUnwrap(window.firstResponder)
        host.rootView = SurfaceTreeView(surfaceId: "focus-test", node: ["t": "vstack", "children": [
            ["t": "text", "key": "notice", "value": "New status"], field
        ]])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(window.firstResponder === responder)
        XCTAssertTrue(descendants(host).contains { $0 === editor })
    }

    @MainActor
    func testLegacyControlRefreshDoesNotEmitUserEvents() {
        _ = NSApplication.shared
        var events = 0
        let toggle = NSHostingView(rootView: SurfaceToggle(eventId: "switch", initial: false, payload: nil, label: "Switch", emit: { _, _ in events += 1 }))
        let color = NSHostingView(rootView: SurfaceColorPicker(eventId: "color", initialHex: "#ff0000", label: "Color", emit: { _, _ in events += 1 }))
        toggle.frame = NSRect(x: 0, y: 0, width: 200, height: 50)
        color.frame = toggle.frame
        toggle.layoutSubtreeIfNeeded(); color.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        toggle.rootView = SurfaceToggle(eventId: "switch", initial: true, payload: nil, label: "Switch", emit: { _, _ in events += 1 })
        color.rootView = SurfaceColorPicker(eventId: "color", initialHex: "#0000ff", label: "Color", emit: { _, _ in events += 1 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        XCTAssertEqual(events, 0)
    }

    @MainActor
    func testPopoverChoiceEditsEnclosingFormDraft() async throws {
        _ = NSApplication.shared
        let presentations = SurfaceServices.shared.presentations
        try autoreleasepool { try editChoiceInPopover(presentations: presentations) }
        let deadline = Date().addingTimeInterval(1)
        while SurfaceServices.shared.presentations != presentations, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(SurfaceServices.shared.presentations, presentations)
    }

    @MainActor private func editChoiceInPopover(presentations: Int) throws {
        let surface = "popover-binding-test"
        let model = SurfaceFormStore.shared.model(surface: surface, key: "form", initial: ["icon": "book"])
        let tree: [String: Any] = ["t": "form", "key": "form", "values": ["icon": "book"], "content": [
            "t": "popover", "key": "picker", "label": "Pick icon", "content_width": 260.0,
            "content": ["t": "input", "field": "icon", "kind": "choice", "options": [
                ["value": "star", "label": "Star", "symbol": "star"]
            ]]
        ]]
        let host = NSHostingView(rootView: SurfaceTreeView(surfaceId: surface, node: tree))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { model.reset(); window.close(); SurfaceFormStore.shared.remove(surface: surface) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        var presented: NSPopover?
        let observer = NotificationCenter.default.addObserver(forName: NSPopover.willShowNotification, object: nil, queue: .main) { notification in
            let popover = notification.object as? NSPopover
            MainActor.assumeIsolated { presented = popover }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try pressButton("Pick icon", in: host, at: NSPoint(x: 45, y: host.bounds.midY - 20))
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let popover = try XCTUnwrap(presented)
        // Dismiss the popover through AppKit so SwiftUI balances onAppear
        // after its content is released. Ordering out its window skips dismissal.
        defer { popover.close() }
        let popup = try XCTUnwrap(popover.contentViewController?.view.window)
        XCTAssertEqual(SurfaceServices.shared.presentations, presentations + 1)
        let content = try XCTUnwrap(popup.contentView)
        // Tahoe adds popover chrome around the requested content width.
        XCTAssertGreaterThanOrEqual(content.bounds.width, 260)
        let point = content.convert(NSPoint(x: 50, y: content.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popup.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            popup.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(model.values["icon"] as? String, "star")
        XCTAssertTrue(model.dirty)
    }

    @MainActor
    func testNativeSheetOpensAndDismissActionClosesIt() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: SurfaceTreeView(surfaceId: "sheet-test", node: [
            "t": "sheet", "key": "help", "label": "Help", "content_width": 300.0,
            "content": ["t": "action", "label": "Done", "action": "dismiss", "role": "primary"]
        ]))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try pressButton("Help", in: host)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let sheet = try XCTUnwrap(window.attachedSheet)
        let content = try XCTUnwrap(sheet.contentView)
        try pressButton("Done", in: content)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(window.attachedSheet)
    }

    @MainActor
    private func pressButton(_ label: String, in view: NSView, at location: NSPoint? = nil) throws {
        // Deliver real window events at the fixture action:
        // SwiftUI no longer promises an NSButton backing view on Tahoe.
        let window = try XCTUnwrap(view.window)
        view.layoutSubtreeIfNeeded()
        let point = view.convert(location ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1), "Cannot click \(label)")
            window.sendEvent(event)
        }
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
