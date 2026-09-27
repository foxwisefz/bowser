import XCTest
import SwiftUI
import BowserSurfaceKit
@testable import Bowser

@MainActor final class ExternalProfilePickerTests: XCTestCase {
    let work = Profile(id: "work", name: "Work", tint: "#3e63dd", icon: "💼", uuid: nil)
    func testMultipleProfilesWaitAndRouteEntireBatchToChoice() {
        let model = ExternalProfilePickerModel(profiles: { [.defaultProfile, self.work] })
        var opened: [URL] = []; var selected: String?
        model.open = { opened = $0; selected = $1 }
        model.receive([URL(string: "https://example.com/one")!])
        model.receive([URL(string: "https://example.org/two")!])
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(model.linkCount, 2)
        model.choose("work")
        XCTAssertEqual(selected, "work")
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(model.linkCount, 0)
        model.choose("default")
        XCTAssertEqual(selected, "work")
    }
    func testSingleProfileOpensDirectlyAndFiltersUnsupportedURLs() {
        let model = ExternalProfilePickerModel(profiles: { [.defaultProfile] })
        var opened: [URL] = []
        model.open = { urls, id in opened = urls; XCTAssertEqual(id, "default") }
        model.receive([URL(string: "https://example.com")!, URL(string: "javascript:alert(1)")!])
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(model.linkCount, 0)
    }
    func testCancelAndDeletedProfileNeverFallBackToAnotherProfile() {
        var profiles = [Profile.defaultProfile, work]
        let model = ExternalProfilePickerModel(profiles: { profiles })
        model.open = { _, _ in XCTFail("Must not open") }
        model.receive([URL(string: "https://example.com")!])
        profiles = [.defaultProfile]
        model.choose("work")
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.linkCount, 1)
        model.cancel()
        model.choose("default")
        XCTAssertEqual(model.linkCount, 0)
    }
    func testArrowAndReturnOpenTheHighlightedProfile() async throws {
        _ = NSApplication.shared
        let model = ExternalProfilePickerModel(profiles: { [.defaultProfile, self.work] })
        model.receive([URL(string: "https://example.com")!])
        var chosen: String?
        model.open = { _, id in chosen = id }
        let context = BrowserScreenContext(kind: "external-profile", model: model)
        let view = NSHostingView(rootView: BrowserScreenRoot(context: context))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 378), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        for (characters, keyCode) in [("\u{F703}", UInt16(124)), ("\r", UInt16(36))] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(chosen, "work")
        chosen = nil
        model.receive([URL(string: "https://example.org")!])
        let shortcut = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19))
        XCTAssertTrue(window.performKeyEquivalent(with: shortcut))
        XCTAssertEqual(chosen, "work")
    }

    func testKeyboardSelectionWrapsAndSurvivesDeletedChoice() {
        let ids = ["default", "work", "reading"]
        XCTAssertEqual(ExternalProfileScreen.movedSelection("default", by: 1, ids: ids), "work")
        XCTAssertEqual(ExternalProfileScreen.movedSelection("reading", by: 1, ids: ids), "default")
        XCTAssertEqual(ExternalProfileScreen.movedSelection("default", by: -1, ids: ids), "reading")
        XCTAssertEqual(ExternalProfileScreen.movedSelection("deleted", by: 1, ids: ids), "work")
        XCTAssertNil(ExternalProfileScreen.movedSelection(nil, by: 1, ids: []))
        XCTAssertLessThan(ExternalProfilePicker.contentHeight(profileCount: 2), ExternalProfilePicker.contentHeight(profileCount: 4))
        XCTAssertEqual(ExternalProfilePicker.contentHeight(profileCount: 4), ExternalProfilePicker.contentHeight(profileCount: 20))
    }

    func testRenderPicker() throws {
        _ = NSApplication.shared
        let savedPortrait = SurfaceServices.shared.portrait
        defer { SurfaceServices.shared.portrait = savedPortrait }
        SurfaceServices.shared.portrait = { name, size in
            guard let character = ProfileCharacter(rawValue: name) else { return AnyView(EmptyView()) }
            return AnyView(ProfileCharacterPortrait(character: character, size: size))
        }
        let model = ExternalProfilePickerModel(profiles: { [.defaultProfile, self.work] })
        model.receive([URL(string: "https://example.com/private?token=secret")!])
        XCTAssertEqual(model.destination, "example.com")
        let height = ExternalProfilePicker.contentHeight(profileCount: model.choices.count)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let context = BrowserScreenContext(kind: "external-profile", model: model)
            let view = NSHostingView(rootView: BrowserScreenRoot(context: context))
            view.frame = NSRect(x: 0, y: 0, width: 430, height: height)
            view.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded()
            if let path = ProcessInfo.processInfo.environment["BOWSER_PROFILE_PICKER_RENDER"],
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let url = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("\(name).png")
                try bitmap.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }
}
