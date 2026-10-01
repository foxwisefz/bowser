import AppKit
import SwiftUI
import XCTest
@testable import Bowser

@MainActor final class DockScrollTests: XCTestCase {
    func testOverflowHasScrollableContentAndCanReachLastTab() async throws {
        _ = NSApplication.shared
        let cursor = CursorModel()
        let items: [[String: Any]] = (1...60).map { ["id": String($0), "symbol": "globe", "active": $0 == 1] }
        let node: [String: Any] = ["t": "magnify_strip", "items": items, "size": 32.0, "spacing": 8.0,
            "header": ["t": "text", "text": "Profile"], "header_height": 82.0]
        let hosting = NSHostingView(rootView: SurfaceTreeView(surfaceId: "edge_dock", node: node, cursor: cursor))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 48, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(250))
        hosting.layoutSubtreeIfNeeded()
        func findScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.compactMap { findScroll($0) }.first
        }
        let scroll = try XCTUnwrap(findScroll(hosting))
        XCTAssertFalse(scroll.hasVerticalScroller, "Dock tabs must never show a vertical scrollbar")
        XCTAssertFalse(scroll.hasHorizontalScroller, "Dock tabs must never show a horizontal scrollbar")
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertLessThan(scroll.frame.height, 600 - 82)
        XCTAssertGreaterThan(document.frame.height, 2300)
        let restingHeight = document.frame.height
        cursor.point = CGPoint(x: 24, y: 300)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(document.frame.height, restingHeight, accuracy: 0.1,
                       "Hover must not change the scroll range")
        cursor.point = nil
        try await Task.sleep(for: .milliseconds(300))
        let bottom = document.bounds.height - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.bounds.maxY, accuracy: 1)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 1500)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        var updated = node
        updated["items"] = (1...60).map { ["id": String($0), "symbol": "globe", "active": $0 == 60] }
        hosting.rootView = SurfaceTreeView(surfaceId: "edge_dock", node: updated, cursor: cursor)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(scroll.contentView.bounds.maxY, 2350, "Activating the last tab must reveal it")
    }
}

@MainActor final class DockLensInteractionTests: XCTestCase {
    func testDisplacedTabReceivesClickAndRendersLens() async throws {
        _ = NSApplication.shared
        let cursor = CursorModel()
        var selected: String?
        let symbols = ["safari.fill", "envelope.fill", "star.fill", "globe", "bolt.fill", "music.note", "leaf.fill"]
        let items: [[String: Any]] = symbols.enumerated().map {
            ["id": String($0.offset), "symbol": $0.element, "active": $0.offset == 3]
        }
        let node: [String: Any] = ["items": items, "size": 32.0, "spacing": 8.0, "magnify": 1.4]
        let root = MagnifyStripView(surfaceId: "lens-test", node: node, emit: { _, value in selected = value as? String })
            .environmentObject(cursor)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 48, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        cursor.point = CGPoint(x: 24, y: 210)
        try await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        let lens = StripLens(focus: 210, strength: 1, radius: 100, magnification: 1.4)
        let row = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? (scale: CGFloat(1), offset: CGFloat(0)) : lens.row(center: 170, size: 32)
        // Click the enlarged upper edge, outside this row's resting hit box.
        let point = NSPoint(x: 24, y: 420 - (170 + row.offset - row.scale * 16 + 4))
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        XCTAssertEqual(selected, "2", "The displaced icon must keep its own click target")
        if let directory = ProcessInfo.processInfo.environment["BOWSER_SURFACE_RENDER"] {
            for (index, focus) in [CGFloat(130), 210, 290].enumerated() {
                cursor.point = CGPoint(x: 24, y: focus)
                try await Task.sleep(for: .milliseconds(400))
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("lens-\(index).png"))
            }
        }
    }
}
