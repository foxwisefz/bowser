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
