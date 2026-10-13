import AppKit
import SwiftUI
import XCTest
@testable import Bowser

@MainActor final class DockScrollTests: XCTestCase {
    func testReorderMarkerKeepsDropGeometryStable() async throws {
        _ = NSApplication.shared
        let items: [[String: Any]] = (1...5).map { index -> [String: Any] in
            let symbol = index == 1 ? "envelope.fill" : "globe"
            return ["id": String(index), "symbol": symbol, "active": index == 3]
        }
        let node: [String: Any] = ["t": "magnify_strip", "items": items, "size": 32.0, "spacing": 8.0]
        let hosting = NSHostingView(rootView: SurfaceTreeView(surfaceId: "edge_dock", node: node, cursor: CursorModel()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; window.orderFront(nil)
        defer { TabDragPreview.shared.finish(); window.orderOut(nil) }
        func rows(_ view: NSView) -> [TabAppDragView] {
            if let row = view as? TabAppDragView { return [row] }
            return view.subviews.flatMap { rows($0) }
        }
        try await Task.sleep(for: .milliseconds(300))
        let before = try XCTUnwrap(rows(hosting).first { $0.webviewID == 3 })
        let height = before.frame.height
        TabDragPreview.shared.source = 1
        TabDragPreview.shared.after = false
        TabDragPreview.shared.target = 3
        try await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        let expanded = try XCTUnwrap(rows(hosting).first { $0.webviewID == 3 })
        XCTAssertEqual(expanded.frame.height, height, accuracy: 1)
        if let path = ProcessInfo.processInfo.environment["BOWSER_DOCK_REORDER_RENDER"] {
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    func testContinuousDragThroughRenderedDockTracksBothSidesAndDropsAtEnd() async throws {
        SurfaceHostServices.configure()
        let browser = BrowserWindowController(profile: .defaultProfile)
        for _ in 0..<4 { _ = browser.openTab(activate: false) }
        let tabs = browser.tabs
        let items: [[String: Any]] = tabs.map { ["id": String($0.webviewId), "symbol": "globe"] }
        let node: [String: Any] = ["t": "magnify_strip", "items": items, "size": 32.0, "spacing": 8.0]
        let hosting = NSHostingView(rootView: SurfaceTreeView(surfaceId: "edge_dock", node: node, cursor: CursorModel()))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 64, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting; window.orderFront(nil)
        defer { TabDragPreview.shared.finish(); window.close(); browser.window?.close() }
        func rows(_ view: NSView) -> [TabAppDragView] {
            if let row = view as? TabAppDragView { return [row] }
            return view.subviews.flatMap { rows($0) }
        }
        try await Task.sleep(for: .milliseconds(300))
        let views = rows(hosting)
        let source = try XCTUnwrap(views.first { $0.webviewID == tabs[0].webviewId })
        let target = try XCTUnwrap(views.first { $0.webviewID == tabs[2].webviewId })
        let frame = target.convert(target.bounds, to: nil)
        func send(_ type: NSEvent.EventType, _ point: NSPoint) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        try send(.leftMouseDown, source.convert(NSPoint(x: 16, y: 16), to: nil))
        for offset: CGFloat in [8, -8, 8, -8] {
            let point = NSPoint(x: frame.midX, y: frame.midY + offset)
            try send(.leftMouseDragged, point)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(TabDragPreview.shared.target, tabs[2].webviewId)
            XCTAssertEqual(TabDragPreview.shared.after, offset < 0)
            XCTAssertEqual(target.convert(target.bounds, to: nil).midY, frame.midY, accuracy: 1)
        }
        let last = try XCTUnwrap(views.first { $0.webviewID == tabs[4].webviewId })
        let lastFrame = last.convert(last.bounds, to: nil)
        let end = NSPoint(x: lastFrame.midX, y: lastFrame.minY - 4)
        try send(.leftMouseDragged, end)
        XCTAssertEqual(TabDragPreview.shared.target, tabs[4].webviewId)
        XCTAssertTrue(TabDragPreview.shared.after)
        try send(.leftMouseUp, end)
        XCTAssertEqual(browser.tabs.map(\.webviewId), Array(tabs.dropFirst()).map(\.webviewId) + [tabs[0].webviewId])
    }

    func testHoldingDragAtScrollEdgeContinuesScrolling() async throws {
        let services = SurfaceServices.shared
        let snapshot = services.tabSnapshot
        let canMove = services.canMoveTab
        let move = services.moveTab
        let edge = services.edgeDragging
        services.tabSnapshot = { _ in SurfaceTabSnapshot(icon: nil, canExport: false) }
        services.canMoveTab = { $0 != $1 }
        services.moveTab = { _, _, _ in true }
        services.edgeDragging = { _ in }
        defer {
            services.tabSnapshot = snapshot; services.canMoveTab = canMove
            services.moveTab = move; services.edgeDragging = edge
        }
        let items: [[String: Any]] = (1...60).map { ["id": String($0), "symbol": "globe"] }
        let node: [String: Any] = ["t": "magnify_strip", "items": items, "size": 32.0, "spacing": 8.0]
        let hosting = NSHostingView(rootView: SurfaceTreeView(surfaceId: "edge_dock", node: node, cursor: CursorModel()))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 48, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting; window.orderFront(nil)
        defer { TabDragPreview.shared.finish(); window.close() }
        func find<T: NSView>(_ view: NSView, _ type: T.Type) -> T? {
            (view as? T) ?? view.subviews.compactMap { find($0, type) }.first
        }
        try await Task.sleep(for: .milliseconds(300))
        let source = try XCTUnwrap(find(hosting, TabAppDragView.self))
        let scroll = try XCTUnwrap(find(hosting, NSScrollView.self))
        let frame = scroll.convert(scroll.bounds, to: nil)
        func send(_ type: NSEvent.EventType, _ point: NSPoint) throws {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        }
        try send(.leftMouseDown, source.convert(NSPoint(x: 16, y: 16), to: nil))
        let edgePoint = NSPoint(x: frame.midX, y: frame.minY + 4)
        try send(.leftMouseDragged, edgePoint)
        let initial = scroll.contentView.bounds.minY
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, initial + 40,
            "Holding at the edge must reveal more tabs without further mouse movement")
        source.cancelOperation(nil)
        try send(.leftMouseUp, edgePoint)
        let stopped = scroll.contentView.bounds.minY
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(scroll.contentView.bounds.minY, stopped, accuracy: 1)
    }

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

@MainActor final class DockLensMotionTests: XCTestCase {
    func testActiveTabKeepsASeparateSilhouetteDuringSweepsAndExit() async throws {
        _ = NSApplication.shared
        let cursor = CursorModel()
        let count = 10
        func root(active: Int) -> some View {
            HStack(spacing: 0) {
                ForEach(0..<2) { column in
                    MagnifyStripView(surfaceId: "edge_dock",
                        node: ["items": (0..<count).map {
                            ["id": String($0), "symbol": "square.fill", "active": column == 0 && $0 == active] as [String: Any]
                        }, "size": 32.0, "spacing": 8.0, "magnify": 1.4], emit: { _, _ in })
                        .frame(width: 48)
                }
            }.environmentObject(cursor).accentColor(.blue).background(Color.black)
        }
        let hosting = NSHostingView(rootView: root(active: 3))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 96, height: 540),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        // Reverse direction before settling, then leave the strip abruptly.
        let targets: [CGFloat?] = [110, 190, 270, 350, 430, 350, 270, 190, 110, 430, 110, nil]
        var frame = 0
        for (index, target) in targets.enumerated() {
            if index.isMultiple(of: 3) { hosting.rootView = root(active: index.isMultiple(of: 2) ? 4 : 5) }
            cursor.point = target.map { CGPoint(x: 24, y: $0) }
            for _ in 0..<3 {
                try await Task.sleep(for: .milliseconds(16))
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                // Compare the neutral icon silhouettes, excluding the blue
                // selection outline. A collision merges adjacent runs.
                let scale = CGFloat(bitmap.pixelsHigh) / 540
                func silhouettes(column: Int) throws -> [Range<Int>] {
                    var runs: [Range<Int>] = []
                    var start: Int?
                    let x = bitmap.pixelsWide * (column * 2 + 1) / 4
                    for y in 0..<bitmap.pixelsHigh {
                        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        let bright = max(color.redComponent, color.greenComponent, color.blueComponent)
                        let dark = min(color.redComponent, color.greenComponent, color.blueComponent)
                        if bright * color.alphaComponent > 0.2 && bright - dark < 0.08 {
                            if start == nil { start = y }
                        } else if let lower = start {
                            runs.append(lower..<y); start = nil
                        }
                    }
                    if let start { runs.append(start..<bitmap.pixelsHigh) }
                    return runs.filter { CGFloat($0.count) > 12 * scale }
                }
                let selected = try silhouettes(column: 0)
                let reference = try silhouettes(column: 1)
                XCTAssertEqual(selected.count, count, "Overlapping icons at moving frame \(frame)")
                XCTAssertEqual(reference.count, count)
                for (selected, reference) in zip(selected, reference) {
                    XCTAssertEqual(CGFloat(selected.lowerBound), CGFloat(reference.lowerBound), accuracy: 2 * scale,
                        "Selection must not change tab motion at frame \(frame)")
                    XCTAssertEqual(CGFloat(selected.upperBound), CGFloat(reference.upperBound), accuracy: 2 * scale,
                        "Selection must not change tab size at frame \(frame)")
                }
                if let directory = ProcessInfo.processInfo.environment["BOWSER_SURFACE_RENDER"] {
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(String(format: "sweep-%03d.png", frame)))
                }
                frame += 1
            }
        }
    }
}
