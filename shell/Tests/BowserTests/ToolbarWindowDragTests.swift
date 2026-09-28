import AppKit
import SwiftUI
import XCTest
@testable import Bowser

@MainActor final class ToolbarWindowDragTests: XCTestCase {
    private final class DragWindow: NSWindow {
        var dragCount = 0
        var activationCount = 0
        override func makeKeyAndOrderFront(_ sender: Any?) { activationCount += 1 }
        override func performDrag(with event: NSEvent) { dragCount += 1 }
    }

    func testMouseDownActivatesToolbarWindowBeforeItIsConsumed() throws {
        let window = DragWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 32),
                                styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = ToolbarWindowDragView(frame: NSRect(x: 0, y: 0, width: 340, height: 32))
        view.identifier = ToolbarWindowDragView.regionIdentifier
        window.contentView = view
        defer { window.close() }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 16),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertNil(view.handle(event))
        XCTAssertEqual(window.activationCount, 1)
        XCTAssertEqual(window.dragCount, 0)
    }

    func testFallbackDragsAcrossControlsAndPreservesClicks() async throws {
        _ = NSApplication.shared
        var commands = 0
        let toolbar = CmdCluster(profileID: "default", reveal: ChromeReveal(), tint: nil,
            openBar: { commands += 1 }, goBack: {}, goForward: {}, reload: {}, modClick: { _ in }, onHoverChanged: { _ in })
        try await checkDragRegions(NSHostingView(rootView: toolbar), commands: { commands })
    }

    func testPageAndOccludedChromeDragsAreNotIntercepted() throws {
        let window = DragWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = page
        let region = NSView(frame: NSRect(x: 20, y: 350, width: 200, height: 24))
        region.identifier = ToolbarWindowDragView.regionIdentifier
        page.addSubview(region)
        // Reproduce an oversized SwiftUI background extending down into the page.
        let drag = ToolbarWindowDragView(frame: NSRect(x: 0, y: -350, width: 500, height: 400))
        region.addSubview(drag)
        defer { window.close() }
        func gesture(_ point: NSPoint, consumed: Bool) throws {
            for (type, offset): (NSEvent.EventType, CGFloat) in [(.leftMouseDown, 0), (.leftMouseDragged, 10)] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type,
                    location: NSPoint(x: point.x + offset, y: point.y), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                XCTAssertEqual(drag.handle(event) == nil, consumed)
            }
        }
        try gesture(NSPoint(x: 50, y: 100), consumed: false)
        try gesture(NSPoint(x: 400, y: 360), consumed: false)
        XCTAssertEqual(window.dragCount, 0)
        try gesture(NSPoint(x: 50, y: 360), consumed: true)
        XCTAssertEqual(window.dragCount, 1)
        let overlay = NSView(frame: region.frame)
        page.addSubview(overlay, positioned: .above, relativeTo: region)
        try gesture(NSPoint(x: 50, y: 360), consumed: false)
        overlay.removeFromSuperview()
        region.alphaValue = 0
        try gesture(NSPoint(x: 50, y: 360), consumed: false)
        XCTAssertEqual(window.dragCount, 1)
    }

    func testNativeDragsAcrossControlsAndPreservesClicks() async throws {
        guard let path = ProcessInfo.processInfo.environment["BOWSER_TEST_TOOLBAR"] else {
            throw XCTSkip("Set BOWSER_TEST_TOOLBAR to the signed toolbar bundle")
        }
        _ = NSApplication.shared
        let library = try NativeModuleLibrary(bundle: URL(fileURLWithPath: path), team: "V7W5LP47U9", bundled: false)
        let slot = NativeModuleSlot(fallback: NSView())
        var commands = 0
        slot.onAction = { if $0 == "command" { commands += 1 } }
        slot.setSnapshot(try JSONSerialization.data(withJSONObject: [
            "revealed": true, "colors": [:], "buttonStyle": "flat", "cornerRadius": 6,
            "showNavigation": true, "buttons": []
        ]))
        XCTAssertTrue(slot.install(library))
        defer { slot.retire() }
        try await checkDragRegions(slot, commands: { commands })
    }

    private func checkDragRegions(_ view: NSView, commands: () -> Int) async throws {
        view.identifier = ToolbarWindowDragView.regionIdentifier
        let window = DragWindow(contentRect: NSRect(x: 100, y: 100, width: 340, height: 32),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        func send(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat = 16) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type,
                location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
        }
        // Blank space, command, menu, and all navigation controls.
        for (index, x) in [CGFloat(330), 25, 70, 110, 137, 164].enumerated() {
            try send(.leftMouseDown, x: x)
            try send(.leftMouseDragged, x: x + 2)
            XCTAssertEqual(window.dragCount, index, "Small pointer jitter must not start a drag")
            try send(.leftMouseDragged, x: x + 10)
            try send(.leftMouseUp, x: x + 10)
            XCTAssertEqual(window.dragCount, index + 1)
        }
        XCTAssertEqual(commands(), 0, "Dragging a command button must not activate it")
        try send(.leftMouseDown, x: 25)
        try send(.leftMouseDragged, x: 27)
        try send(.leftMouseUp, x: 27)
        // Deliver the release queued for the original button.
        if let release = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(release)
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(commands(), 1, "A normal command click must still work")
        XCTAssertEqual(window.dragCount, 6)
        try send(.leftMouseDown, x: 25)
        NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
        try send(.leftMouseUp, x: 25)
        XCTAssertEqual(commands(), 1, "Escape cancels a pending toolbar click")
        try send(.leftMouseDown, x: 360)
        try send(.leftMouseDragged, x: 370)
        try send(.leftMouseUp, x: 370)
        XCTAssertEqual(window.dragCount, 6, "Events outside the toolbar must remain untouched")
    }
}
