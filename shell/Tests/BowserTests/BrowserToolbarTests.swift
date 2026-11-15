import AppKit
import XCTest
@testable import Bowser

@MainActor final class BrowserToolbarTests: XCTestCase {
    func testNativeToolbarReservesPageSpaceAndKeepsControlsStable() async throws {
        let browser = BrowserWindowController(profile: .defaultProfile)
        let window = try XCTUnwrap(browser.window)
        defer { window.close() }
        let toolbar = try XCTUnwrap(window.toolbar)
        let presentation = try XCTUnwrap(toolbar.delegate as? BrowserToolbar)
        XCTAssertEqual(window.toolbarStyle, .unifiedCompact)
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(window.titlebarAppearsTransparent, "AppKit must draw its translucent titlebar material")
        window.makeKeyAndOrderFront(nil)
        for width: CGFloat in [1200, 640, 900] {
            window.setContentSize(NSSize(width: width, height: 500))
            try await Task.sleep(for: .milliseconds(120))
            let root = try XCTUnwrap(window.contentView?.superview)
            root.layoutSubtreeIfNeeded()
            let page = try XCTUnwrap(browser.activeTab)
            let pageFrame = page.convert(page.bounds, to: nil)
            let addressFrame = presentation.location.convert(presentation.location.bounds, to: nil)
            XCTAssertGreaterThanOrEqual(addressFrame.minY, pageFrame.maxY)
            XCTAssertGreaterThan(presentation.location.bounds.width, 100)
            XCTAssertTrue(toolbar.visibleItems?.contains { $0.itemIdentifier == BrowserToolbar.locationID } == true)
            XCTAssertTrue(toolbar.visibleItems?.contains { $0.itemIdentifier == BrowserToolbar.controlsID } == true)
            XCTAssertTrue(root.hitTest(root.convert(NSPoint(x: pageFrame.midX, y: pageFrame.maxY - 2), from: nil))?.isDescendant(of: page) == true,
                          "The website owns clicks at its top edge")
            let lights = [.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0)?.frame }
            for point in [NSPoint(x: 5, y: window.frame.height - 1), NSPoint(x: 400, y: 100)] {
                window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 0, pressure: 0)))
            }
            try await Task.sleep(for: .milliseconds(650))
            XCTAssertEqual(presentation.location.convert(presentation.location.bounds, to: nil), addressFrame)
            XCTAssertEqual([.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0)?.frame }, lights)
        }
        if ProcessInfo.processInfo.environment["BOWSER_TOOLBAR_PREVIEWS"] == "1" {
            let frame = try XCTUnwrap(window.contentView?.superview)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                frame.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: "/tmp/bowser-toolbar-\(name).png"))
            }
        }
    }

    func testLocationUpdatesAndProfileItemReturnsWithoutRebuildingControls() throws {
        let controls = NSView()
        var clicks = 0
        let presentation = BrowserToolbar(controls: controls, profile: NSView(), loading: ToolbarLoadingLine()) { clicks += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.toolbarStyle = .unifiedCompact
        window.toolbar = presentation.toolbar
        let initialControls = try XCTUnwrap(presentation.toolbar.items.first { $0.itemIdentifier == BrowserToolbar.controlsID }?.view)
        presentation.updateLocation(url: "https://example.com/a?b=2", title: "An example", icon: nil)
        XCTAssertEqual(presentation.location.title, "example.com")
        XCTAssertEqual(presentation.location.accessibilityValue() as? String, "https://example.com/a?b=2")
        presentation.location.performClick(nil)
        XCTAssertEqual(clicks, 1)
        for visible in [true, false, true, true, false] {
            presentation.setProfileVisible(visible)
            XCTAssertEqual(presentation.toolbar.items.filter { $0.itemIdentifier == BrowserToolbar.profileID }.count, visible ? 1 : 0)
            XCTAssertTrue(presentation.toolbar.items.first { $0.itemIdentifier == BrowserToolbar.controlsID }?.view === initialControls)
        }
    }
}
