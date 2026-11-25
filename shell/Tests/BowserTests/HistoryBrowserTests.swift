import AppKit
import WebKit
import XCTest
import HistoryCore
import BowserSurfaceKit
@testable import Bowser

@MainActor final class HistoryBrowserTests: XCTestCase {
    func testSettingsReusesAndRevealsHistoryInItsSelectedProfile() throws {
        _ = NSApplication.shared
        let app = AppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = app
        let profiles = Profile.all
        let model = HistoryController.shared
        let originalProfile = model.selectedProfile, originalScope = model.allProfiles
        defer {
            model.selectedProfile = originalProfile
            model.allProfiles = originalScope
            Profile.all = profiles
            NSApp.delegate = originalDelegate
        }
        let work = Profile(id: UUID().uuidString, name: "Work", tint: nil, icon: nil, uuid: UUID().uuidString)
        Profile.all = [.defaultProfile, work]
        let workBrowser = BrowserWindowController(profile: work)
        let personalBrowser = BrowserWindowController(profile: .defaultProfile)
        defer { workBrowser.window?.close(); personalBrowser.window?.close() }
        let workWindow = try XCTUnwrap(workBrowser.window)
        let personalWindow = try XCTUnwrap(personalBrowser.window)
        let historyTab = try XCTUnwrap(workBrowser.activeTab)
        historyTab.load(urlString: EngineView.historyURL)
        _ = workBrowser.openTab()
        let existingTabCount = workBrowser.tabs.count
        personalWindow.makeKeyAndOrderFront(nil)
        workWindow.orderOut(nil)

        model.selectedProfile = work.id
        model.allProfiles = true
        model.showBrowser()
        XCTAssertTrue(workWindow.isVisible)
        XCTAssertTrue(workBrowser.activeTab === historyTab)
        XCTAssertEqual(workBrowser.tabs.count, existingTabCount)
        XCTAssertEqual(personalBrowser.tabs.count, 1)
        XCTAssertEqual(model.selectedProfile, work.id)
        XCTAssertFalse(model.allProfiles)

        personalWindow.orderOut(nil)
        model.open(HistorySearchItem(id: "fixture", url: "about:blank", title: "", snippet: "", seen: Date(), image: nil, profile: "default"))
        XCTAssertTrue(personalWindow.isVisible)
        XCTAssertEqual(personalBrowser.tabs.count, 2)
        XCTAssertEqual(personalBrowser.activeTab.profileId, "default")
        XCTAssertTrue(workBrowser.activeTab === historyTab)
    }

    func testFilteringRetiresPreviousResultsAndWeekIncludesTodayAndSixPriorDates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(directory: root, profile: "default")
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for age in [0, 6, 7] {
            let date = try XCTUnwrap(calendar.date(byAdding: .day, value: -age, to: today))
            let url = "https://day\(age).example.test"
            try store.visit(id: UUID().uuidString, record: HistoryRecord(url: url, title: "Day \(age)", text: "", seen: date))
        }
        let model = HistoryController(directory: root)
        func waitForResults() async throws {
            let deadline = Date().addingTimeInterval(5)
            while model.isSearching && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(model.isSearching)
            XCTAssertNil(model.searchError)
        }
        model.search()
        try await waitForResults()
        XCTAssertEqual(model.results.map(\.title), ["Day 0", "Day 6", "Day 7"])
        model.dateFilter = "week"
        XCTAssertTrue(model.results.isEmpty)
        try await waitForResults()
        XCTAssertEqual(model.results.map(\.title), ["Day 0", "Day 6"])
        model.siteFilter = "day6.example.test"
        XCTAssertTrue(model.results.isEmpty)
        try await waitForResults()
        XCTAssertEqual(model.results.map(\.title), ["Day 6"])
        model.query = "missing"
        XCTAssertTrue(model.results.isEmpty)
        model.query = "Day 6"
        try await waitForResults()
        XCTAssertEqual(model.results.map(\.title), ["Day 6"])
        model.selectedProfile = "other"
        XCTAssertTrue(model.results.isEmpty)
        try await waitForResults()
        XCTAssertTrue(model.results.isEmpty)
    }

    func testTimelineGroupsTimeBlocksIndependentlyForEachProfile() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        func item(_ id: String, _ minutes: Double, profile: String = "work", visit: Bool = true) -> HistorySearchItem {
            HistorySearchItem(id: id, url: "https://example.test", title: id, snippet: "", seen: day.addingTimeInterval(minutes * 60), image: nil, profile: profile, isVisit: visit)
        }
        let sessions = HistorySession.group([item("a", 100), item("b", 95, profile: "personal"), item("c", 90), item("d", 30), item("capture", 25, visit: false)], calendar: calendar)
        XCTAssertEqual(sessions.map { $0.items.map(\.id) }, [["a", "c"], ["b"], ["d"], ["capture"]])
        XCTAssertEqual(sessions.first?.topic, "example.test")
        let midnight = calendar.startOfDay(for: day)
        let aroundMidnight = [-1.0, 1.0].map { HistorySearchItem(id: String($0), url: "https://example.test", title: "", snippet: "", seen: midnight.addingTimeInterval($0), image: nil, isVisit: true) }
        XCTAssertEqual(HistorySession.group(aroundMidnight, calendar: calendar).count, 2)
    }

    func testHistoryIsANativeTabAndIgnoresOldWebKitNavigationCallbacks() async throws {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let engine = EngineView(frame: NSRect(x: 0, y: 0, width: 1000, height: 760), configuration: config)
        defer { engine.tearDown() }
        engine.load(urlString: EngineView.historyURL)
        XCTAssertTrue(engine.isHistoryPage)
        XCTAssertEqual(engine.currentURLString, "bowser://history")
        XCTAssertEqual(engine.currentTitle, "History")
        XCTAssertTrue(engine.webView.isHidden)
        engine.webView(engine.webView, didStartProvisionalNavigation: nil)
        engine.webView(engine.webView, didCommit: nil)
        engine.webView(engine.webView, didFinish: nil)
        engine.webView(engine.webView, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost))
        engine.reloadPage()
        XCTAssertTrue(engine.hasRenderedContent)
        XCTAssertFalse(engine.isShowingLoadingCover)
        let slept = await engine.sleepIfSafe()
        XCTAssertFalse(slept)
        engine.load(urlString: "about:blank")
        XCTAssertFalse(engine.isHistoryPage)
        XCTAssertFalse(engine.webView.isHidden)
        XCTAssertNotEqual(engine.currentURLString, EngineView.historyURL)
    }

    func testVisitsAndSearchContinueWhileCapturePausedAndBulkDeleteStaysDeleted() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-controller-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString
        let prefs: [String: Any] = [id: ["enabled": true, "images": false, "days": 90, "exclusions": []]]
        try JSONSerialization.data(withJSONObject: prefs).write(to: root.appendingPathComponent("preferences.json"))
        let controller = HistoryController(directory: root)
        controller.selectedProfile = id
        let profile = Profile(id: id, name: "Fixture", tint: nil, icon: nil, uuid: id)
        if !CaptureMode.shared.isEnabled { CaptureMode.shared.toggleCaptureMode() }
        defer { if CaptureMode.shared.isEnabled { CaptureMode.shared.toggleCaptureMode() } }
        XCTAssertTrue(controller.isResourceLimited)
        var engines: [EngineView] = []
        defer { engines.forEach { $0.tearDown() } }
        for index in 0..<2 {
            let config = WKWebViewConfiguration(); config.websiteDataStore = profile.dataStore
            let engine = EngineView(frame: .zero, configuration: config, profile: profile, historyController: controller)
            engines.append(engine)
            engine.webView.loadHTMLString("<title>Fixture \(index)</title><p>Readable</p>", baseURL: URL(string: "https://history.test/\(index)"))
            for _ in 0..<200 {
                if !engine.webView.isLoading, engine.webView.title == "Fixture \(index)" { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(engine.webView.title, "Fixture \(index)")
        }
        try await Task.sleep(for: .milliseconds(150))
        controller.search()
        for _ in 0..<100 { if !controller.isSearching { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(controller.results.count, 2)
        XCTAssertTrue(controller.results.allSatisfy(\.isVisit))
        XCTAssertEqual(Set(controller.results.map(\.title)), ["Fixture 0", "Fixture 1"])
        XCTAssertNotNil(controller.lastSaved)
        XCTAssertNil(controller.recordingIssue)
        let hits = await controller.search(profile: id, query: "Fixture 1")
        XCTAssertEqual(hits.count, 1)
        // A same-document navigation is a new visit, without a WebKit commit.
        _ = try await engines[0].webView.evaluateJavaScript("history.pushState({}, '', '/next');document.title='Next page'")
        try await Task.sleep(for: .milliseconds(250))
        controller.search()
        for _ in 0..<100 { if !controller.isSearching { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(controller.results.count, 3)
        XCTAssertEqual(controller.results.first?.title, "Next page")
        // Loading the same URL again must remain a distinct real visit.
        engines[1].webView.loadHTMLString("<title>Revisited page</title><p>Again</p>", baseURL: URL(string: "https://history.test/1"))
        for _ in 0..<200 {
            if !engines[1].webView.isLoading, engines[1].webView.title == "Revisited page" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(150))
        controller.search()
        for _ in 0..<100 { if !controller.isSearching { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(controller.results.count, 4)
        XCTAssertEqual(controller.results.filter { $0.url == "https://history.test/1" }.count, 2)
        controller.delete(controller.results)
        for _ in 0..<100 { if controller.results.isEmpty { break }; try await Task.sleep(for: .milliseconds(20)) }
        for engine in engines { controller.recordVisit(engine) }
        controller.search()
        for _ in 0..<100 { if !controller.isSearching { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(controller.results, [])
        XCTAssertNil(controller.lastSaved)
        controller.enabled = false
    }
}
