import AppKit
import SwiftUI
import XCTest
import BowserSurfaceKit
@testable import Bowser

@MainActor private final class HistoryFixture: ObservableObject, HistoryPresentation {
    var profiles = [ProfileDisplay(id: "work", name: "Work", draft: .newProfile)]
    var selectedProfile = "work"
    var enabled = true
    var includeImages = true
    var retentionDays = 90
    var excludedSites = ""
    var query = "orange website"
    var results = [HistorySearchItem(id: "one", url: "https://example.test/network", title: "Network security and performance", snippet: "Protect your applications and connect your network. White background; orange accents.", seen: Date(), image: nil)]
    var status = "History stays on this Mac. New content is indexed in the background."
    var storageText = "24 items · 180 KB of 128 MB · 0 awaiting semantic indexing"
    var storageWarning: String? = "History reached its limit. 128 older items removed in total to stay within 128 MB and 10,000 items. Last removal: 19 Oct 2026 at 11:00 AM."
    var isSearching = false
    var isDownloading = false
    var modelReady = true
    func downloadModel() {}
    func search() {}
    func open(_ item: HistorySearchItem) {}
    func delete(_ item: HistorySearchItem) {}
    func clear() {}
    func saveExclusions() {}
}
@MainActor private final class HistorySettingsFixture: ObservableObject, SettingsPresentation {
    var sections = [SettingsSection(id: "history", title: "History", order: 0, tree: [:])]
    var selected: String? = "history"
    let historyContext: BrowserScreenContext
    init(enabled: Bool = true) {
        let history = HistoryFixture(); history.enabled = enabled
        historyContext = BrowserScreenContext(kind: "history", model: history)
    }
    var permissionsContext: BrowserScreenContext { historyContext }
    var profilesContext: BrowserScreenContext { historyContext }
    var defaultContext: BrowserScreenContext { historyContext }
}
@MainActor final class HistoryPresentationTests: XCTestCase {
    func testHistoryResultsRemainDistinctFromWebSearchAndUseSavedURL() {
        _ = NSApplication.shared
        let state = CommandPaletteState()
        state.query = "orange website"; state.historyResults = HistoryFixture().results
        let view = CommandPaletteRenderer(state: state)
        view.frame = CGRect(x: 0, y: 0, width: 640, height: 300)
        view.activateScreen()
        XCTAssertEqual(state.results.first?.history?.url, "https://example.test/network")
        XCTAssertEqual(state.results.first?.title, "Network security and performance")
        XCTAssertNil(state.results.last?.history)
    }
    func testHistorySettingsRenderAtMinimumWindowSize() async throws {
        try await renderSettings(enabled: true, name: "collapsed")
        try await renderSettings(enabled: false, name: "expanded")
    }
    private func renderSettings(enabled: Bool, name: String) async throws {
        _ = NSApplication.shared
        let context = BrowserScreenContext(kind: "settings", model: HistorySettingsFixture(enabled: enabled))
        let host = NSHostingView(rootView: SettingsScreen(context: context).background(Color(nsColor: .windowBackgroundColor)))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.size, NSSize(width: 820, height: 600))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/bowser-history-warning-\(name).png"))
    }
}
