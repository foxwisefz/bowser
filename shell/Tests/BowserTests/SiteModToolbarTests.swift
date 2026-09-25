import AppKit
import XCTest
@testable import Bowser

@MainActor final class SiteModToolbarTests: XCTestCase {
    func testCatalogFiltersBySiteAndProfileAndRetainsDisabledMods() {
        ChromeSurface.handle(["chrome": "set_site_mods", "mods": [
            ["id": "site|x.com|reader.css.off", "title": "reader.css", "host": "x.com", "profile": "work", "subdomains": false, "on": false],
            ["id": "mod|reader.ex", "title": "reader.ex", "host": "x.com", "profile": "default", "subdomains": true, "on": true]
        ]])
        defer { ChromeSurface.handle(["chrome": "set_site_mods", "mods": []]) }
        XCTAssertEqual(ChromeSurface.siteMods(for: "work", url: "https://x.com/home").map(\.on), [false])
        XCTAssertTrue(ChromeSurface.siteMods(for: "work", url: "https://www.x.com").isEmpty)
        XCTAssertEqual(ChromeSurface.siteMods(for: "default", url: "https://www.x.com").map(\.id), ["mod|reader.ex"])
        XCTAssertTrue(ChromeSurface.siteMods(for: "default", url: "https://notx.com").isEmpty)
        XCTAssertTrue(ChromeSurface.siteMods(for: "default", url: "about:blank").isEmpty)
        XCTAssertTrue(ChromeSurface.siteMods(for: "default", url: nil).isEmpty)
        ChromeSurface.handle(["chrome": "set_site_mods", "mods": []])
        XCTAssertTrue(ChromeSurface.siteMods(for: "default", url: "https://x.com").isEmpty)
    }
    func testSiteModsDropdownRendersWithoutOpeningSettings() throws {
        guard let path = ProcessInfo.processInfo.environment["BOWSER_NOTCH_MODULE"] else {
            throw XCTSkip("Set BOWSER_NOTCH_MODULE for real module rendering")
        }
        _ = NSApplication.shared
        let slot = NativeModuleSlot(fallback: NSView())
        slot.frame = NSRect(x: 0, y: 0, width: 500, height: 32)
        slot.setSnapshot(try JSONSerialization.data(withJSONObject: [
            "revealed": false, "modWidth": 0, "tint": NSNull(),
            "colors": [:], "buttonStyle": "flat", "cornerRadius": 6,
            "showNavigation": true, "buttons": [],
            "siteMods": [["id": "mod|reader.ex", "title": "reader.ex", "on": true],
                         ["id": "site|x.com|focus.css.off", "title": "focus.css", "on": false]]
        ]))
        XCTAssertTrue(slot.install(try NativeModuleLibrary(bundle: URL(fileURLWithPath: path), team: nil, bundled: true)))
        defer { slot.retire() }
        let canvas = NSView(frame: slot.frame)
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        canvas.addSubview(slot)
        canvas.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/bowser-site-mods-dropdown.png"))
    }

}
