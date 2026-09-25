import AppKit
import XCTest
@testable import Bowser

@MainActor final class ToolbarNotchTests: XCTestCase {
    func testYieldTucksBothBarsAndReferenceNeverInterceptsClicks() throws {
        let controller = BrowserWindowController(profile: .defaultProfile)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let titlebar = try XCTUnwrap(window.standardWindowButton(.closeButton)?.superview)
        let notch = try XCTUnwrap(titlebar.subviews.compactMap { $0 as? ToolbarNotchView }.first { $0.onHover != nil })
        let profile = try XCTUnwrap(titlebar.subviews.compactMap { $0 as? ToolbarNotchView }.first { $0.onHover == nil })
        controller.setProfileIndicatorVisible(true)
        XCTAssertNil(profile.hitTest(NSPoint(x: profile.frame.midX, y: profile.frame.midY)))
        controller.setProfileIndicatorVisible(false, animated: false)
        XCTAssertFalse(profile.isHidden)
        let profileInset = titlebar.isFlipped ? profile.frame.minY : titlebar.bounds.height - profile.frame.maxY
        XCTAssertEqual(profileInset, -16, accuracy: 0.5)
        XCTAssertTrue(profile.frame.intersects(titlebar.bounds))
        controller.setToolbarIntent(visible: false, yielded: true)
        controller.setToolbarHovered(true)
        XCTAssertFalse(notch.isHidden)
        XCTAssertFalse(try XCTUnwrap(window.standardWindowButton(.closeButton)).isHidden)
        let controlsInset = titlebar.isFlipped ? notch.frame.minY : titlebar.bounds.height - notch.frame.maxY
        XCTAssertEqual(controlsInset, -16, accuracy: 0.5)
        XCTAssertTrue(notch.frame.intersects(titlebar.bounds))
        controller.setToolbarIntent(visible: true, yielded: false)
        XCTAssertFalse(notch.isHidden)
        XCTAssertFalse(try XCTUnwrap(window.standardWindowButton(.closeButton)).isHidden)
    }

    func testTuckMovesLeftControlsTogetherAndLeavesProfileInPlace() throws {
        let controller = BrowserWindowController(profile: .defaultProfile)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let titlebar = try XCTUnwrap(window.standardWindowButton(.closeButton)?.superview)
        let notch = try XCTUnwrap(titlebar.subviews.compactMap { $0 as? ToolbarNotchView }.first { $0.onHover != nil })
        let profile = try XCTUnwrap(titlebar.subviews.compactMap { $0 as? ToolbarNotchView }.first { $0.onHover == nil })
        controller.setToolbarVisible(true, animated: false)
        titlebar.layoutSubtreeIfNeeded()
        let profileFrame = profile.frame
        let revealedFrame = notch.frame
        for fraction: CGFloat in [0.35, 0.5, 0.65] {
            controller.toolbarHiddenFraction = fraction
            controller.setToolbarVisible(false, animated: false)
            let top = titlebar.isFlipped ? notch.frame.minY : titlebar.bounds.height - notch.frame.maxY
            XCTAssertEqual(top, -32 * fraction, accuracy: 0.5)
            XCTAssertEqual(profile.frame, profileFrame)
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                XCTAssertEqual(try XCTUnwrap(window.standardWindowButton(kind)).frame.midY, notch.frame.midY, accuracy: 0.5)
            }
        }
        controller.setToolbarVisible(true, animated: false)
        XCTAssertEqual(notch.frame, revealedFrame)
    }

    func testNotchExpandsTitleWithoutMovingWindowControls() async throws {
        let controller = BrowserWindowController(profile: .defaultProfile)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 500))
        window.makeKeyAndOrderFront(nil)
        controller.activeTab?.onTitleChange?("Designing a calmer browser — Bowser")
        let titlebar = try XCTUnwrap(window.standardWindowButton(.closeButton)?.superview)
        try await Task.sleep(for: .milliseconds(250))
        if let path = ProcessInfo.processInfo.environment["BOWSER_NOTCH_MODULE"] {
            let slot = try XCTUnwrap(titlebar.subviews.compactMap { $0 as? NativeModuleSlot }.first)
            XCTAssertTrue(slot.install(try NativeModuleLibrary(bundle: URL(fileURLWithPath: path), team: nil, bundled: true)))
        }
        controller.setToolbarVisible(true, animated: false)
        titlebar.layoutSubtreeIfNeeded()
        if ProcessInfo.processInfo.environment["BOWSER_CORNER_PROBE"] == "1" {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), "/tmp/bowser-corner-window.png"]
            try capture.run(); capture.waitUntilExit()
        }
        let notch = try XCTUnwrap(titlebar.subviews.compactMap { $0 as? ToolbarNotchView }.first { $0.onHover != nil })
        let viewport = try XCTUnwrap(notch.subviews.first { $0.identifier?.rawValue == "toolbarTitleViewport" })
        let title = try XCTUnwrap(viewport.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("calmer") })
        let icon = try XCTUnwrap(notch.subviews.compactMap { $0 as? NSImageView }.first { $0.accessibilityLabel() == "Active tab icon" })
        XCTAssertNotNil(icon.image)
        XCTAssertEqual(viewport.frame.width, 0)
        XCTAssertEqual(EngineView.pageTopInset, 0)
        let profileNotch = try XCTUnwrap(titlebar.subviews.compactMap { $0 as? ToolbarNotchView }.first { $0.onHover == nil })
        XCTAssertGreaterThan(profileNotch.frame.minX, notch.frame.maxX)
        let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
        // AppKit aligns constraint results to the backing pixel grid.
        let scale = closeButton.frame.height / 29
        XCTAssertEqual(notch.frame.height, 32, accuracy: 0.5)
        XCTAssertEqual(notch.frame.minX, 8, accuracy: 0.5)
        let topInset = titlebar.isFlipped ? notch.frame.minY : titlebar.bounds.height - notch.frame.maxY
        XCTAssertEqual(topInset, notch.frame.minX, accuracy: 0.5)
        XCTAssertEqual(notch.frame.midY, closeButton.frame.midY, accuracy: 0.5)
        XCTAssertEqual(closeButton.frame.minX - notch.frame.minX, 15 * scale + 4, accuracy: 0.5)
        let minimize = try XCTUnwrap(window.standardWindowButton(.miniaturizeButton))
        XCTAssertEqual(minimize.frame.midX - closeButton.frame.midX, 46 * scale, accuracy: 0.5)
        let collapsed = notch.frame
        let controls = [.closeButton, .miniaturizeButton, .zoomButton].map { window.standardWindowButton($0)!.frame }
        try render(titlebar, rect: titlebar.bounds, name: "collapsed")
        let textWidth = title.frame.width
        controller.setToolbarHovered(true)
        try await Task.sleep(for: .milliseconds(70))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let visible = try XCTUnwrap(notch.layer?.presentation())
            XCTAssertGreaterThan(visible.bounds.width, collapsed.width)
            XCTAssertLessThan(visible.bounds.width, notch.frame.width)
        }
        XCTAssertEqual(title.frame.width, textWidth)
        try await Task.sleep(for: .milliseconds(250))
        titlebar.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(notch.frame.width, collapsed.width + 100)
        XCTAssertGreaterThan(viewport.frame.width, 100)
        XCTAssertEqual([.closeButton, .miniaturizeButton, .zoomButton].map { window.standardWindowButton($0)!.frame }, controls)
        try render(titlebar, rect: titlebar.bounds, name: "expanded")
        window.setContentSize(NSSize(width: 400, height: 500))
        try await Task.sleep(for: .milliseconds(250))
        titlebar.layoutSubtreeIfNeeded()
        XCTAssertEqual([.closeButton, .miniaturizeButton, .zoomButton].map { window.standardWindowButton($0)!.frame }, controls)
        XCTAssertLessThanOrEqual(notch.frame.maxX, titlebar.bounds.width - 11)
        XCTAssertGreaterThanOrEqual(title.frame.width, 0)
        XCTAssertLessThanOrEqual(notch.frame.maxX + 8, profileNotch.frame.minX + 0.5)
    }

    func testRevealReversalAndResizeUseVisibleGeometry() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.close() }
        let view = ToolbarNotchView(frame: NSRect(x: 8, y: 8, width: 100, height: 32))
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(50))
        ToolbarRevealAnimation.perform(views: [view], animated: true) {
            view.setFrameSize(NSSize(width: 300, height: 32))
        }
        try await Task.sleep(for: .milliseconds(70))
        let expandingWidth = try XCTUnwrap(view.layer?.presentation()).bounds.width
        XCTAssertGreaterThan(expandingWidth, 100)
        XCTAssertLessThan(expandingWidth, 300)
        ToolbarRevealAnimation.perform(views: [view], animated: true) {
            view.setFrameSize(NSSize(width: 100, height: 32))
        }
        CATransaction.flush()
        let reversedWidth = try XCTUnwrap(view.layer?.presentation()).bounds.width
        XCTAssertEqual(reversedWidth, expandingWidth, accuracy: 2)
        try await Task.sleep(for: .milliseconds(70))
        let contractingWidth = try XCTUnwrap(view.layer?.presentation()).bounds.width
        XCTAssertLessThan(contractingWidth, expandingWidth)
        XCTAssertGreaterThan(contractingWidth, 100)
        ToolbarRevealAnimation.perform(views: [view], animated: false) {
            view.setFrameSize(NSSize(width: 80, height: 32))
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(try XCTUnwrap(view.layer?.presentation()).bounds.width, 80, accuracy: 0.5)
    }

    private func render(_ view: NSView, rect: NSRect, name: String) throws {
        guard ProcessInfo.processInfo.environment["BOWSER_NOTCH_PREVIEWS"] == "1" else { return }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/bowser-notch-\(name).png"))
    }
}
