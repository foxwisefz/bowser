import AppKit
import SwiftUI
import BowserSurfaceKit
import XCTest
@testable import Bowser

@MainActor final class SurfaceScrollTests: XCTestCase {
    private func scroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.compactMap { scroll(in: $0) }.first
    }

    func testOverflowIsBoundedRetainsOffsetAndLastRowReceivesEvents() async throws {
        _ = NSApplication.shared
        var selected: String?
        func tree(_ count: Int) -> [String: Any] {
            let rows: [[String: Any]] = (1...count).map {
                ["t": "button", "key": "row-\($0)", "label": "Item \($0)", "event": "select", "payload": String($0), "height": 40.0]
            }
            return ["t": "vstack", "children": [
                ["t": "text", "value": "Fixed heading", "key": "header"],
                ["t": "scroll", "key": "items", "height": 240.0, "content": ["t": "vstack", "children": rows]],
                ["t": "button", "label": "Add item", "event": "add", "key": "footer"]]]
        }
        func root(_ count: Int) -> some View {
            SurfaceTreeView(surfaceId: "test-scroll", node: tree(count))
                .environment(\.surfaceDispatch, { selected = $0["value"] as? String })
        }
        let hosting = NSHostingView(rootView: root(60))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let viewport = try XCTUnwrap(scroll(in: hosting))
        let document = try XCTUnwrap(viewport.documentView)
        XCTAssertLessThanOrEqual(viewport.frame.height, 240)
        XCTAssertGreaterThan(document.frame.height, 2000)
        XCTAssertLessThanOrEqual(document.frame.width, viewport.contentSize.width + 1)
        viewport.contentView.scroll(to: NSPoint(x: 0, y: 500))
        viewport.reflectScrolledClipView(viewport.contentView)
        let offset = viewport.contentView.bounds.origin
        hosting.rootView = root(61)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(scroll(in: hosting) === viewport)
        XCTAssertEqual(viewport.contentView.bounds.origin.y, offset.y, accuracy: 1)
        viewport.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - viewport.contentView.bounds.height))
        viewport.reflectScrolledClipView(viewport.contentView)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(viewport.contentView.bounds.maxY, document.bounds.maxY, accuracy: 1)
        let point = document.convert(NSPoint(x: document.bounds.midX, y: document.bounds.maxY - 20), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        }
        XCTAssertEqual(selected, "61")
        hosting.rootView = root(2)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertLessThanOrEqual(viewport.contentView.bounds.origin.y, max(0, document.bounds.height - viewport.contentSize.height))
    }

    func testDefaultBoundAndHorizontalOverflow() async throws {
        _ = NSApplication.shared
        let node: [String: Any] = ["t": "scroll", "axis": "horizontal", "indicators": false,
            "content": ["t": "hstack", "children": (1...20).map { ["t": "text", "value": "Column \($0)", "width": 120.0] }]]
        let hosting = NSHostingView(rootView: SurfaceTreeView(surfaceId: "horizontal", node: node))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let viewport = try XCTUnwrap(scroll(in: hosting))
        let document = try XCTUnwrap(viewport.documentView)
        XCTAssertEqual(viewport.frame.height, 320, accuracy: 1)
        XCTAssertFalse(viewport.hasHorizontalScroller)
        XCTAssertGreaterThan(document.frame.width, 2000)
        viewport.contentView.scroll(to: NSPoint(x: document.bounds.width - viewport.contentSize.width, y: 0))
        viewport.reflectScrolledClipView(viewport.contentView)
        XCTAssertEqual(viewport.contentView.bounds.maxX, document.bounds.maxX, accuracy: 1)
    }
}
