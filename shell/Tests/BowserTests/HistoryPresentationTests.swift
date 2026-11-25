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
    @Published var siteFilter = ""
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
        let history = HistoryFixture()
        history.enabled = enabled
        if !enabled {
            history.modelReady = false
            history.status = "Visit recording is off for this profile. Saved history is still available."
        }
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
            let age = index < 4 ? Double(index * 50) : index < 50 ? 7200 + Double(index * 50) : 119400 + Double(index)
            return HistorySearchItem(id: String(index), url: "https://example.test/\(index)",
                title: index.isMultiple(of: 3) ? String(repeating: "A long page title ", count: 10) : "Page \(index)",
                snippet: "", seen: Date().addingTimeInterval(-age), image: index.isMultiple(of: 8) ? thumbnail : nil,
                profile: "work", isVisit: index < 50)
        }
        model.results = full
        var screenContext: BrowserScreenContext?
        let host = NSHostingView(rootView: LiveBrowserScreen(kind: "history", model: model, onCreateContext: { screenContext = $0 }))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1404, height: 972), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        if let path = ProcessInfo.processInfo.environment["BOWSER_TEST_SCREEN_MODULE"] {
            try await Task.sleep(for: .milliseconds(100))
            func slots(_ view: NSView) -> [NativeModuleSlot] {
                (view as? NativeModuleSlot).map { [$0] } ?? view.subviews.flatMap(slots)
            }
            let slot = try XCTUnwrap(slots(host).first)
            let library = try NativeModuleLibrary(bundle: URL(fileURLWithPath: path), team: nil, bundled: true, kind: .surfaces)
            window.makeFirstResponder(nil)
            XCTAssertTrue(slot.install(library))
        }
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
        let context = try XCTUnwrap(screenContext)
        for gallery in [true, false] {
            let firstCell = try XCTUnwrap(collection.visibleItems().filter { $0.view.frame.intersects(collection.visibleRect) }
                .min { ($0.view.frame.minY, $0.view.frame.minX) < ($1.view.frame.minY, $1.view.frame.minX) })
            let anchor = try XCTUnwrap(collection.indexPath(for: firstCell))
            context.values["historyGallery"] = gallery
            try await Task.sleep(for: .milliseconds(180))
            let newFrame = try XCTUnwrap(collection.collectionViewLayout?.layoutAttributesForItem(at: anchor)).frame
            XCTAssertTrue(newFrame.intersects(collection.visibleRect), "Changing layout should keep the entry being read on screen")
            let layout = try XCTUnwrap(collection.collectionViewLayout)
            var all: [NSCollectionViewLayoutAttributes] = []
            for section in 0..<collection.numberOfSections {
                for item in 0..<collection.numberOfItems(inSection: section) {
                    let path = IndexPath(item: item, section: section)
                    all.append(try XCTUnwrap(layout.layoutAttributesForItem(at: path)))
                }
            }
            for y in [0, newFrame.minY, newFrame.maxY, layout.collectionViewContentSize.height + 1] {
                let rect = NSRect(x: 10, y: y, width: 345, height: 200)
                XCTAssertEqual(layout.layoutAttributesForElements(in: rect).map(\.indexPath),
                               all.filter { $0.frame.intersects(rect) }.map(\.indexPath))
            }
        }
        for _ in 0..<5 {
            // Filtering while deep in the timeline must safely shrink its
            // document, including when the old visible rows no longer exist.
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 1600)); scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(100))
            model.siteFilter = "example.test"
            try await Task.sleep(for: .milliseconds(100))
            model.results = Array(full.prefix(1))
            try await Task.sleep(for: .milliseconds(100))
            model.siteFilter = ""
            try await Task.sleep(for: .milliseconds(100))
            model.results = full
            try await Task.sleep(for: .milliseconds(100))
        }
        let headers = collection.visibleItems().filter { collection.indexPath(for: $0)?.item == 0 }.map(\.view)
        XCTAssertFalse(headers.isEmpty)
        for (index, header) in headers.enumerated() {
            for other in headers.dropFirst(index + 1) {
                XCTAssertFalse(header.frame.intersects(other.frame), "Recycled session headers must not leave overlapping views behind")
            }
        }
        try await savePreview(window, name: "after-filter")
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
        let model = HistoryFixture()
        model.storageWarning = nil
        model.query = ""
        let lastVisit = Date.now.addingTimeInterval(-180)
        let pages: [(site: String, title: String, snippet: String, minutes: Int, color: NSColor?)] = [
            ("fieldnotes.example", "Walking the West Highland Way", "A field guide to the trail from Milngavie to Fort William.", 0, .systemGreen),
            ("maps.example", "Loch Lomond and the Trossachs", "Walking routes, ferry crossings and viewpoints.", 6, nil),
            ("rail.example", "Glasgow to Fort William by train", "The West Highland Line follows the shore of Loch Long.", 17, .systemIndigo),
            ("museum.example", "The collection in focus", "Studies in paper, colour and form.", 88, .systemOrange),
            ("archive.example", "A pocket guide to letterpress", "A printer’s notes on setting the first line of type.", 94, nil),
            ("library.example", "Books on type and lettering", "From the design reading room.", 111, nil),
            ("journal.example", "A weekend on the west coast", "Notes from the road.", 1410, nil)
        ]
        model.results = try pages.enumerated().map { index, page in
            let picture = try page.color.map { try thumbnail(title: page.title, site: page.site, accent: $0) }
            return HistorySearchItem(id: String(index), url: "https://" + page.site + "/read/\(index)",
                title: page.title, snippet: page.snippet, seen: lastVisit.addingTimeInterval(Double(-page.minutes * 60)),
                image: picture, profile: "work", isVisit: index < 6)
        }
        model.lastSaved = model.results.first?.seen
        let context = BrowserScreenContext(kind: "history", model: model)
        let host = NSHostingView(rootView: HistoryScreen(context: context))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "History"
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }

        func collectionView(in view: NSView) -> NSCollectionView? {
            if let collection = view as? NSCollectionView { return collection }
            return view.subviews.lazy.compactMap { collectionView(in: $0) }.first
        }
        for (width, gallery, appearance, name) in [
            (1080, false, NSAppearance.Name.aqua, "list"),
            (1080, true, .aqua, "gallery"),
            (480, false, .darkAqua, "compact-dark")
        ] {
            context.values["historyGallery"] = gallery
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: width, height: 760))
            try await Task.sleep(for: .milliseconds(220))
            host.layoutSubtreeIfNeeded()
            let collection = try XCTUnwrap(collectionView(in: host))
            let layout = try XCTUnwrap(collection.collectionViewLayout)
            let first = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))).frame
            let second = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0))).frame
            XCTAssertTrue(gallery ? first.minY == second.minY : first.maxY <= second.minY)
            XCTAssertEqual(host.bounds.width, Double(width))
            XCTAssertLessThanOrEqual(first.maxX, collection.bounds.width + 1)
            try await savePreview(window, name: name)
        }
        model.results = []
        model.enabled = false
        context.objectWillChange.send()
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertNil(collectionView(in: host))
        try await savePreview(window, name: "recording-off")
    }

    private func thumbnail(title: String, site: String, accent: NSColor) throws -> Data {
        let image = NSImage(size: NSSize(width: 480, height: 240), flipped: false) { rect in
            NSColor(white: 0.97, alpha: 1).setFill()
            rect.fill()
            accent.withAlphaComponent(0.16).setFill()
            NSRect(x: 0, y: 78, width: 480, height: 162).fill()
            let ink = NSColor(white: 0.13, alpha: 1)
            (site.uppercased() as NSString).draw(at: NSPoint(x: 22, y: 213), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: ink,
            ])
            (title as NSString).draw(in: NSRect(x: 21, y: 88, width: 436, height: 95), withAttributes: [
                .font: NSFont(name: "Georgia", size: 32) ?? NSFont.systemFont(ofSize: 32), .foregroundColor: ink,
            ])
            NSColor(white: 0.68, alpha: 1).setFill()
            for (index, width) in [319, 395, 260].enumerated() {
                NSRect(x: 23, y: 55 - 11 * index, width: width, height: 2).fill()
            }
            return true
        }
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [:]))
    }

    private func savePreview(_ window: NSWindow, name: String) async throws {
        if let path = ProcessInfo.processInfo.environment["BOWSER_HISTORY_PREVIEWS"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await writeWindowPreview(window, to: directory.appendingPathComponent(name + ".png"))
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
        try await savePreview(window, name: enabled ? "settings-on" : "settings-off")
    }
}
