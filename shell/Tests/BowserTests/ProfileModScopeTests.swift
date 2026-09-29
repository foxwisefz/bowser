import XCTest
import AppKit
@testable import Bowser

final class ProfileModScopeTests: XCTestCase {
    @MainActor func testPanelsStayWithTheirProfileWithoutRecreatingThem() throws {
        let primary = BrowserWindowController(profile: .defaultProfile)
        let work = BrowserWindowController(profile: Profile(id: "scope-work", name: "Work", tint: nil, icon: nil, uuid: nil))
        defer { primary.window?.close(); work.window?.close() }
        let main = try XCTUnwrap(primary.window)
        let other = try XCTUnwrap(work.window)
        main.makeKeyAndOrderFront(nil)
        SurfaceManager.shared.orderAllFront(parent: main)
        let id = "scope-test-" + UUID().uuidString
        defer { SurfaceManager.shared.handle(["surface": "close", "id": id]) }
        let before = Set(NSApp.windows.map(\.windowNumber))
        SurfaceManager.shared.handle(["surface": "show", "id": id, "profile": "default", "title": "Scoped panel", "view": ["t": "text", "text": "Default only"]])
        let panel = try XCTUnwrap(NSApp.windows.first { !before.contains($0.windowNumber) && $0 is NSPanel })
        XCTAssertTrue(panel.isVisible)
        SurfaceManager.shared.orderAllFront(parent: other)
        XCTAssertFalse(panel.isVisible)
        SurfaceManager.shared.orderAllFront(parent: main)
        XCTAssertTrue(panel.isVisible)
    }

    @MainActor func testToolbarRefreshStillAppliesChangedControls() throws {
        let controller = BrowserWindowController(profile: .defaultProfile)
        defer { controller.window?.close() }
        func findSlot(_ view: NSView) -> NativeModuleSlot? {
            if let slot = view as? NativeModuleSlot, slot.kind == .commandToolbar { return slot }
            return view.subviews.lazy.compactMap { findSlot($0) }.first
        }
        let root = try XCTUnwrap(controller.window?.contentView?.superview)
        let slot = try XCTUnwrap(findSlot(root))
        controller.syncModButtons()
        let original = slot.snapshot
        controller.syncModButtons()
        XCTAssertEqual(slot.snapshot, original)
        let id = "toolbar-refresh-" + UUID().uuidString
        defer { ChromeSurface.handle(["chrome": "remove_button", "id": id, "profile": "default"]) }
        ChromeSurface.handle(["chrome": "add_button", "id": id, "title": "New control", "profile": "default"])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: slot.snapshot) as? [String: Any])
        let buttons = try XCTUnwrap(payload["buttons"] as? [[String: Any]])
        XCTAssertTrue(buttons.contains { $0["id"] as? String == id })
        XCTAssertNotEqual(slot.snapshot, original)
    }

    @MainActor func testChromeAndFutureTabScriptsAreProfileScoped() {
        ChromeSurface.handle(["chrome": "add_button", "id": "scope-button", "title": "Work", "profile": "scope-work"])
        defer { ChromeSurface.handle(["chrome": "remove_button", "id": "scope-button", "profile": "scope-work"]) }
        XCTAssertTrue(ChromeSurface.buttons(for: "scope-work").contains { $0.id == "scope-button" })
        XCTAssertFalse(ChromeSurface.buttons(for: "default").contains { $0.id == "scope-button" })
        EngineView.rememberUserContent(scripts: ["window.scopeWork = true"], styles: [], profile: "scope-work")
        defer { EngineView.rememberUserContent(scripts: [], styles: [], profile: "scope-work") }
        XCTAssertTrue(EngineView.content(for: "scope-work").scripts.contains("window.scopeWork = true"))
        XCTAssertFalse(EngineView.content(for: "default").scripts.contains("window.scopeWork = true"))
    }
}
