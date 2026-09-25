import AppKit
import XCTest
@testable import Bowser

final class CaptureModeTests: XCTestCase {
    func testManualModeSurvivesSharingEnding() {
        var state = CaptureModeState()
        XCTAssertFalse(state.isEnabled)
        state.toggle()
        state.updateSharing(true)
        state.updateSharing(false)
        XCTAssertTrue(state.isEnabled)
        state.toggle()
        XCTAssertFalse(state.isEnabled)
    }

    func testAutomaticSharingRestoresChromeAndCanBeOverridden() {
        var state = CaptureModeState()
        state.updateSharing(true)
        XCTAssertTrue(state.isEnabled)
        state.updateSharing(false)
        XCTAssertFalse(state.isEnabled)
        state.updateSharing(true)
        state.toggle()
        XCTAssertFalse(state.isEnabled)
        state.updateSharing(true)
        XCTAssertFalse(state.isEnabled) // Don't fight an explicit exit.
        state.updateSharing(false)
        state.updateSharing(true)
        XCTAssertTrue(state.isEnabled) // A new sharing session can auto-enter.
    }

    @MainActor func testChromeStaysHiddenAcrossHoverAndRefreshAndRestoresExactly() throws {
        _ = NSApplication.shared
        let browser = BrowserWindowController(profile: .defaultProfile)
        defer { browser.window?.close() }
        let window = try XCTUnwrap(browser.window)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        let tab = try XCTUnwrap(browser.activeTab)
        let web = tab.webView
        let frame = web.frame
        let controls = browser.captureChromeViews
        XCTAssertEqual(controls.count, 6)
        let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        zoom.isHidden = true // Existing visibility must survive the round trip.
        let previous = controls.map(\.isHidden)
        browser.setCaptureMode(true)
        XCTAssertTrue(controls.allSatisfy(\.isHidden))
        browser.setToolbarIntent(visible: true, yielded: false)
        browser.setToolbarHovered(true)
        browser.setToolbarVisible(true)
        browser.setProfileIndicatorVisible(true)
        browser.syncModButtons()
        browser.profileDidChange()
        XCTAssertTrue(controls.allSatisfy(\.isHidden))
        XCTAssertTrue(browser.activeTab === tab)
        XCTAssertTrue(browser.activeTab.webView === web)
        XCTAssertEqual(web.frame, frame)
        browser.setCaptureMode(false)
        XCTAssertEqual(controls.map(\.isHidden), previous)
        XCTAssertFalse(browser.isCaptureMode)
        browser.setToolbarVisible(true, animated: false)
        XCTAssertFalse(controls[0].isHidden)
    }

    @MainActor func testMenuTogglesAllWindowsIncludingNewOnes() throws {
        _ = NSApplication.shared
        let mode = CaptureMode.shared
        if mode.isEnabled { mode.toggleCaptureMode() }
        let first = BrowserWindowController(profile: .defaultProfile)
        var second: BrowserWindowController?
        defer {
            if mode.isEnabled { mode.toggleCaptureMode() }
            second?.window?.close(); first.window?.close()
        }
        let menus = NativeUIPresentation.menus(NativeMenuContext(target: NSObject(), siteHost: nil,
            targets: ["capture": mode], siteActions: []))
        let viewMenu = try XCTUnwrap(menus.main.items.first { $0.submenu?.title == "View" }?.submenu)
        let item = try XCTUnwrap(viewMenu.items.first { $0.action == #selector(CaptureMode.toggleCaptureMode(_:)) })
        XCTAssertTrue(item.target === mode)
        XCTAssertEqual(item.keyEquivalent, "h")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertTrue(mode.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertTrue(first.isCaptureMode)
        second = BrowserWindowController(profile: .defaultProfile)
        XCTAssertTrue(try XCTUnwrap(second).captureChromeViews.allSatisfy(\.isHidden))
        XCTAssertTrue(mode.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)
        mode.toggleCaptureMode()
        XCTAssertFalse(first.isCaptureMode)
        XCTAssertFalse(try XCTUnwrap(second).isCaptureMode)
    }
}
