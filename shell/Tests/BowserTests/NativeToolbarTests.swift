import XCTest
import AppKit
@testable import Bowser

@MainActor final class NativeToolbarTests: XCTestCase {
    override func setUp() { super.setUp(); _ = NSApplication.shared }
    private func fixture() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["BOWSER_TEST_TOOLBAR"] else { throw XCTSkip("Set BOWSER_TEST_TOOLBAR to a signed real toolbar bundle") }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
    private var snapshot: Data {
        try! JSONSerialization.data(withJSONObject: ["revealed": true, "tint": NSNull(), "colors": [:], "buttonStyle": "flat", "cornerRadius": 6, "showNavigation": true, "buttons": [["id":"test", "title":"Test mod", "symbol":"star"]]])
    }
    func testMalformedMachORejected() {
        for data in [Data(), Data(repeating: 0, count: 64), Data([0xcf,0xfa,0xed,0xfe])] {
            XCTAssertThrowsError(try NativeModuleLibrary.validateMachO(data))
        }
    }
    func testSignatureIdentityAndSymlinkRejection() throws {
        let url = try fixture()
        _ = try NativeModuleLibrary.validate(url, team: "V7W5LP47U9", bundled: false)
        XCTAssertThrowsError(try NativeModuleLibrary.validate(url, team: "WRONGTEAM", bundled: false))
        XCTAssertThrowsError(try NativeModuleLibrary.validate(url, team: nil, bundled: false))
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        defer { try? FileManager.default.removeItem(at: link) }
        XCTAssertThrowsError(try NativeModuleLibrary.validate(link, team: "V7W5LP47U9", bundled: false))
    }
    func testDragDefersReplacementWithoutDiscardingCandidate() throws {
        let library = try NativeModuleLibrary(bundle: fixture(), team: "V7W5LP47U9", bundled: false)
        let slot = NativeModuleSlot(fallback: NSView())
        slot.setSnapshot(snapshot)
        slot.interactionInProgress = { true }
        XCTAssertFalse(slot.install(library)); XCTAssertNil(slot.build)
        slot.interactionInProgress = { false }
        XCTAssertTrue(slot.install(library)); XCTAssertEqual(slot.build, library.build)
        slot.retire()
    }
    func testTamperedPackageRejected() throws {
        let source = try fixture()
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let executable = copy.appendingPathComponent("Contents/MacOS/CommandToolbar")
        let file = try FileHandle(forWritingTo: executable)
        try file.seek(toOffset: 4096); try file.write(contentsOf: Data([0xff, 0xff, 0xff, 0xff])); try file.close()
        XCTAssertThrowsError(try NativeModuleLibrary.validate(copy, team: "V7W5LP47U9", bundled: false))
    }
    func testRealModuleKeepsHostSnapshotAndRetiresView() async throws {
        let library = try NativeModuleLibrary(bundle: fixture(), team: "V7W5LP47U9", bundled: false)
        let fallback = NSView()
        let slot = NativeModuleSlot(fallback: fallback)
        slot.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        let saved = snapshot
        slot.setSnapshot(saved)
        XCTAssertTrue(slot.install(library))
        XCTAssertEqual(slot.snapshot, saved)
        XCTAssertEqual(slot.build, library.build)
        XCTAssertNil(fallback.superview)
        weak var native = slot.subviews.first
        XCTAssertNotNil(native)
        slot.setSnapshot(snapshot)
        slot.retire()
        for _ in 0..<30 {
            if native == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(native)
        XCTAssertNil(slot.build)
    }
    func testAdoptionPhaseDiagnosticsAreOptInAndPreserveBehavior() throws {
        let library = try NativeModuleLibrary(bundle: fixture(), team: "V7W5LP47U9", bundled: false)
        for enabled in [false, true] {
            let slot = NativeModuleSlot(fallback: NSView())
            slot.recordsAdoptionTimings = enabled
            slot.setSnapshot(snapshot)
            XCTAssertTrue(slot.install(library))
            XCTAssertEqual(slot.build, library.build)
            if enabled {
                let phases = try XCTUnwrap(slot.lastAdoptionTimings as? [String: Double])
                XCTAssertEqual(Set(phases.keys), Set(["create_ms", "mount_ms", "update_ms", "retire_ms", "activate_ms", "layout_ms", "responder_ms"]))
                XCTAssertTrue(phases.values.allSatisfy { $0.isFinite && $0 >= 0 })
                XCTAssertTrue(slot.responds(to: NSSelectorFromString("lastAdoptionTimings")))
            } else {
                XCTAssertNil(slot.lastAdoptionTimings)
            }
            slot.retire()
        }
    }
    func testNativeControlsPreserveActionsMenusAndSnapshotUpdates() throws {
        let library = try NativeModuleLibrary(bundle: fixture(), team: "V7W5LP47U9", bundled: false)
        let slot = NativeModuleSlot(fallback: NSView())
        slot.frame = NSRect(x: 0, y: 0, width: 340, height: 32)
        let window = NSWindow(contentRect: slot.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = slot
        window.orderFront(nil)
        defer { window.close() }
        var actions: [String] = []
        slot.onAction = { actions.append($0) }
        var state: [String: Any] = ["revealed": true, "colors": [:], "buttonStyle": "flat",
            "cornerRadius": 6, "showNavigation": true, "modWidth": 40,
            "permissionsAvailable": true, "capturing": true,
            "siteMods": [["id": "site", "title": "Site toggle", "on": true]],
            "buttons": [["id": "one", "title": "First", "symbol": "star"],
                        ["id": "two", "title": "Second", "symbol": "star"]]]
        slot.setSnapshot(try JSONSerialization.data(withJSONObject: state))
        XCTAssertTrue(slot.install(library))
        defer { slot.retire() }
        slot.layoutSubtreeIfNeeded()
        if let path = ProcessInfo.processInfo.environment["BOWSER_TOOLBAR_PREVIEW"],
           let bitmap = slot.bitmapImageRepForCachingDisplay(in: slot.bounds) {
            slot.cacheDisplay(in: slot.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func control(_ id: String) throws -> NSButton {
            try XCTUnwrap(descendants(slot).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == id })
        }
        for action in ["command", "back", "forward", "reload", "mod:one", "mod:two", "permissions"] {
            try control(action).performClick(nil)
            XCTAssertEqual(actions.last, action)
        }
        let menu = try XCTUnwrap(try control("site-mods").menu)
        XCTAssertEqual(menu.items.first?.state, .on)
        menu.performActionForItem(at: 0)
        XCTAssertEqual(actions.last, "mod:site-mod:site")
        menu.performActionForItem(at: menu.items.count - 1)
        XCTAssertEqual(actions.last, "mod:global_mods")
        let scroll = try XCTUnwrap(descendants(slot).compactMap { $0 as? NSScrollView }.first)
        XCTAssertEqual(scroll.frame.width, 40)
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.width, scroll.frame.width)
        state["revealed"] = false; state["capturing"] = false
        slot.setSnapshot(try JSONSerialization.data(withJSONObject: state))
        slot.layoutSubtreeIfNeeded()
        let remaining = descendants(slot).compactMap { ($0 as? NSButton)?.accessibilityIdentifier() }
        XCTAssertFalse(remaining.contains("mod:one"))
        XCTAssertFalse(remaining.contains("permissions"))
        XCTAssertNoThrow(try control("command"))
        XCTAssertEqual(slot.build, library.build)
    }
    func testInvalidStateLeavesFallbackIntact() throws {
        let library = try NativeModuleLibrary(bundle: fixture(), team: "V7W5LP47U9", bundled: false)
        let fallback = NSView()
        let target = NativeModuleSlot(fallback: fallback)
        target.setSnapshot(Data("{}".utf8))
        XCTAssertFalse(target.install(library))
        XCTAssertTrue(fallback.superview === target)
        XCTAssertNil(target.build)
    }
    func testRetiredGenerationCannotDispatchCommands() {
        let slot = NativeModuleSlot(fallback: NSView()), runtime = NativeModuleRuntime.toolbar
        var actions: [String] = []
        slot.onAction = { actions.append($0) }
        let old = runtime.newGeneration(), next = runtime.newGeneration()
        runtime.authorize(old, slot: slot)
        runtime.deliver(old, "back")
        runtime.revoke(old); runtime.authorize(next, slot: slot)
        runtime.deliver(old, "reload"); runtime.deliver(next, "forward")
        XCTAssertEqual(actions, ["back", "forward"])
        runtime.revoke(next)
    }
}
