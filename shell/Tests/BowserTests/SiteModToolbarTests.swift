import AppKit
import WebKit
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

    func testToolbarFollowsCatalogChangesOnTheSamePage() async throws {
        _ = NSApplication.shared
        let browser = BrowserWindowController(profile: .defaultProfile)
        defer { browser.window?.close() }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let tab = browser.openTab(configuration: config)
        tab.webView.loadHTMLString("<title>Toolbar fixture</title>", baseURL: URL(string: "https://www.reader.example/page"))
        for _ in 0..<200 where tab.webView.isLoading || tab.currentURLString == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(tab.currentURLString, "https://www.reader.example/page")
        let slot = try XCTUnwrap(browser.window?.toolbar?.items.first {
            $0.itemIdentifier == BrowserToolbar.controlsID
        }?.view as? NativeModuleSlot)
        func renderedMods() throws -> [[String: Any]] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: slot.snapshot) as? [String: Any])
            return try XCTUnwrap(object["siteMods"] as? [[String: Any]])
        }
        func entry(_ i: Int, matches: Bool) -> [String: Any] {
            ["id": "s\(i)", "title": "Reader \(i)", "host": matches ? "reader.example" : "elsewhere\(i).example",
             "profile": "default", "subdomains": true, "on": i.isMultiple(of: 2)]
        }
        let benchmark = ProcessInfo.processInfo.environment["BOWSER_PERF"] == "1"
        let count = benchmark ? 4096 : 8
        let matchStride = benchmark ? 32 : 2
        let catalog = (0..<count).map { entry($0, matches: $0.isMultiple(of: matchStride)) }
        ChromeSurface.handle(["chrome": "set_site_mods", "mods": catalog])
        defer { ChromeSurface.handle(["chrome": "set_site_mods", "mods": []]) }
        let before = try renderedMods()
        let matchingIDs = stride(from: 0, to: count, by: matchStride).map { "s\($0)" }
        XCTAssertEqual(before.compactMap { $0["id"] as? String }, matchingIDs)
        if benchmark {
            var samples: [Double] = []
            for _ in 0..<100 {
                let start = ProcessInfo.processInfo.systemUptime
                browser.syncModButtons()
                samples.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            }
            let sorted = samples.sorted()
            print("Toolbar refresh, 4096 site mods / 128 matches: p50=\(sorted[49]) ms, p95=\(sorted[94]) ms")
        }
        ChromeSurface.handle(["chrome": "set_site_mods", "mods": [entry(1, matches: true)]])
        let after = try renderedMods()
        XCTAssertEqual(after.compactMap { $0["id"] as? String }, ["s1"])
        XCTAssertEqual(after.first?["on"] as? Bool, false)
    }

}
