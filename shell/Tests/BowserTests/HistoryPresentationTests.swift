import AppKit
import SwiftUI
import XCTest
import Darwin
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
    @Published var results = [HistorySearchItem(id: "one", url: "https://example.test/network", title: "Network security and performance", snippet: "Protect your applications and connect your network. White background; orange accents.", seen: Date(), image: nil)]
    var status = "History stays on this Mac. New content is indexed in the background."
    var storageText = "24 items · 180 KB of 128 MB · 0 awaiting semantic indexing"
    var storageWarning: String? = "History reached its limit. 128 older items removed in total to stay within 128 MB and 10,000 items. Last removal: 19 Oct 2026 at 11:00 AM."
    var isSearching = false
    var isDownloading = false
    var modelReady = true
    var lastSaved: Date? = Date()
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
    func testFullTimelineSettlesAfterScrollingAndResizing() async throws {
        _ = NSApplication.shared
        let model = HistoryFixture(); model.query = ""; model.storageWarning = nil
        let picture = NSImage(size: NSSize(width: 480, height: 320), flipped: false) { rect in
            NSColor.systemOrange.setFill(); rect.fill(); return true
        }
        let cg = try XCTUnwrap(picture.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let thumbnail = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [:]))
        let full = (0..<60).map { index in
            let age = index < 46 ? Double(index * 50) : index < 49 ? 14500 + Double(index) : 119400 + Double(index)
            return HistorySearchItem(id: String(index), url: "https://example.test/\(index)",
                title: index.isMultiple(of: 3) ? String(repeating: "A long page title ", count: 10) : "Page \(index)",
                snippet: "", seen: Date().addingTimeInterval(-age), image: index.isMultiple(of: 8) ? thumbnail : nil,
                profile: "work", isVisit: index < 46)
        }
        model.results = full
        let host = NSHostingView(rootView: LiveBrowserScreen(kind: "history", model: model))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1404, height: 972), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        for width in [1404, 820, 1100, 1404] {
            window.setContentSize(NSSize(width: width, height: 972))
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(scrollViews(host).first)
            let collection = try XCTUnwrap(scroll.documentView as? NSCollectionView)
            for cell in collection.visibleItems() {
                let path = try XCTUnwrap(collection.indexPath(for: cell))
                let attributes = try XCTUnwrap(collection.collectionViewLayout?.layoutAttributesForItem(at: path))
                XCTAssertLessThanOrEqual(attributes.frame.maxX, scroll.contentSize.width + 1, "Resizing must reflow cards within the viewport")
            }
        }
        let scroll = try XCTUnwrap(scrollViews(host).first)
        let collection = try XCTUnwrap(scroll.documentView as? NSCollectionView)
        XCTAssertGreaterThan(collection.visibleItems().count, 0)
        XCTAssertLessThan(collection.visibleItems().count, full.count, "Offscreen cards must be recycled rather than all mounted")
        for y in [800.0, 1600.0] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(200))
        }
        for _ in 0..<5 {
            // Filtering while deep in the timeline must safely shrink its
            // document, including when the old visible rows no longer exist.
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 1600)); scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(100))
            model.results = Array(full.prefix(1))
            try await Task.sleep(for: .milliseconds(100))
            model.results = full
            try await Task.sleep(for: .milliseconds(100))
        }
        func cpuTime() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let cpu = cpuTime()
        let start = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .milliseconds(500))
        let elapsed = ProcessInfo.processInfo.systemUptime - start, usedCPU = cpuTime() - cpu
        print("History settled: \(usedCPU) CPU seconds over \(elapsed) elapsed seconds")
        XCTAssertLessThan(elapsed, 1, "History must let the main run loop service other browser work")
        XCTAssertLessThan(usedCPU, 0.15, "A settled History screen must not continuously consume a CPU core")
    }
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
    func testVisualTimelineRendersAtBrowserSizes() async throws {
        _ = NSApplication.shared
        let model = HistoryFixture(); model.query = ""; model.storageWarning = nil
        let image = NSImage(size: NSSize(width: 480, height: 300), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            NSColor.systemOrange.setFill(); NSRect(x: 0, y: 245, width: 480, height: 55).fill()
            ("Network services" as NSString).draw(at: NSPoint(x: 25, y: 190), withAttributes: [.font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.black])
            ("A saved page preview" as NSString).draw(at: NSPoint(x: 25, y: 150), withAttributes: [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.gray])
            return true
        }
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let thumbnail = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [:]))
        model.results = []
        let titles = ["Network security and performance", "Designing a calmer browser", "A visit without a preview"]
        for index in 0..<7 {
            let title = titles[index % 3]
            let seconds = Double(index) * (index < 4 ? 240.0 : 900.0)
            let seen = Date().addingTimeInterval(-seconds)
            let picture: Data? = index % 3 == 2 ? nil : thumbnail
            let item = HistorySearchItem(id: String(index), url: "https://example.test/\(index)", title: title, snippet: "Saved page content.", seen: seen, image: picture, profile: "work", isVisit: true)
            model.results.append(item)
        }
        let context = BrowserScreenContext(kind: "history", model: model)
        let host = NSHostingView(rootView: HistoryScreen(context: context))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        for width in [1100, 820] {
            window.setContentSize(NSSize(width: width, height: 850))
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.width, Double(width))
            // Reused native cells receive their final width during AppKit layout;
            // let their SwiftUI text drawing commit before capturing the artifact.
            try await Task.sleep(for: .milliseconds(100))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/bowser-history-timeline-\(width).png"))
        }
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
