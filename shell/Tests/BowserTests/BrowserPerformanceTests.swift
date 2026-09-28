import AppKit
import Darwin
import WebKit
import XCTest
@testable import Bowser

/// Opt-in release-build workloads. Budgets and reporting live in tests/performance.
@MainActor final class BrowserPerformanceTests: XCTestCase {
    private static var applicationPrepared = false
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BOWSER_PERF"] == "1")
        let home = try XCTUnwrap(ProcessInfo.processInfo.environment["BOWSER_HOME"])
        guard home.hasPrefix("/tmp/") || home.hasPrefix("/private/tmp/") else { throw NSError(domain: "Performance tests require a disposable home", code: 1) }
        _ = NSApplication.shared
        if !Self.applicationPrepared {
            NSApp.setActivationPolicy(.regular)
            NSApp.finishLaunching()
            Self.applicationPrepared = true
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private var cacheStore: WKWebsiteDataStore?
    override func tearDown() async throws {
        if let store = cacheStore {
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            cacheStore = nil
        }
    }

    private var samples: Int { 5 }
    private func configuration(_ store: WKWebsiteDataStore = .nonPersistent()) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration(); config.websiteDataStore = store; return config
    }
    private func record(_ name: String, _ value: Double) throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["BOWSER_PERF_RESULTS"])
        var data = try JSONSerialization.data(withJSONObject: ["metric": name, "value": value])
        data.append(0x0a)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: data)
    }
    private func timed(_ name: String, _ work: @MainActor () async throws -> Void) async throws {
        let start = ProcessInfo.processInfo.systemUptime
        try await work()
        try record(name, (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !predicate(), Date() < deadline {
            // Command-line XCTest has no NSApplication event loop. Deliver the
            // WindowServer visibility events that enable real WebKit frames.
            while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            NSApp.updateWindows()
            try await Task.sleep(for: .milliseconds(5))
        }
        guard predicate() else { throw NSError(domain: "Performance fixture timed out", code: 1) }
    }
    private func server() async throws -> BrowserFixtureServer {
        let server = try BrowserFixtureServer(); try await wait { server.origin != nil }; return server
    }

    func testNewTabAndManyDeferredTabs() async throws {
        let controller = BrowserWindowController(profile: .defaultProfile)
        controller.showWindow(nil)
        defer { controller.window?.close() }
        let store = WKWebsiteDataStore.nonPersistent()
        for _ in 0..<samples {
            var tab: EngineView?
            try await timed("new_tab_ms") {
                tab = controller.openTab(configuration: configuration(store))
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                XCTAssertTrue(controller.activeTab === tab)
                XCTAssertNotNil(tab?.window)
            }
            controller.closeTab(id: try XCTUnwrap(tab).webviewId)
        }
        for _ in 0..<3 {
            var deferred: [EngineView] = []
            try await timed("restore_100_tabs_ms") {
                for index in 0..<100 {
                    let tab = controller.openTab(configuration: configuration(store), activate: false, append: true)
                    tab.restore(urlString: "http://127.0.0.1:1/deferred/\(index)")
                    deferred.append(tab)
                }
            }
            XCTAssertEqual(deferred.count, 100)
            XCTAssertTrue(deferred.allSatisfy { $0.pendingRestoreURL != nil && $0.webView.url == nil && !$0.webView.isLoading })
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            XCTAssertEqual(status, KERN_SUCCESS)
            try record("host_rss_100_tabs_mb", Double(info.resident_size) / 1048576)
            for tab in deferred { controller.closeTab(id: tab.webviewId) }
        }
    }

    func testNavigationCacheAndDeferredActivation() async throws {
        let server = try await server(); defer { server.stop() }
        let origin = try XCTUnwrap(server.origin)
        let store = WKWebsiteDataStore(forIdentifier: UUID()); cacheStore = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.orderFront(nil)
        defer { window.close() }
        for index in 0...samples {
            let view = EngineView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration(store))
            defer { view.tearDown(); view.removeFromSuperview() }
            window.contentView = view
            let navigationStart = ProcessInfo.processInfo.systemUptime
            view.load(urlString: origin + "/cold-\(index)")
            try await wait { view.hasRenderedContent }
            let firstContent = (ProcessInfo.processInfo.systemUptime - navigationStart) * 1000
            try record(index == 0 ? "fresh_profile_first_content_ms" : "cold_navigation_first_content_ms", firstContent)
            try await wait { !view.webView.isLoading }
            // Collect only after the timed workload; never warm up or drop the
            // first fresh-store navigation to make its budget pass.
            let timing = try await view.webView.evaluateJavaScript("""
                JSON.stringify(performance.getEntriesByType('navigation').map(n => ({
                  fetchStart: n.fetchStart, domainLookupStart: n.domainLookupStart,
                  domainLookupEnd: n.domainLookupEnd, connectStart: n.connectStart,
                  connectEnd: n.connectEnd, requestStart: n.requestStart,
                  responseStart: n.responseStart, responseEnd: n.responseEnd,
                  domInteractive: n.domInteractive, loadEventEnd: n.loadEventEnd
                })))
                """) as? String ?? "unavailable"
            print("Cold navigation sample \(index + 1), webview \(view.webviewId): first-content=\(firstContent)ms; navigation timing=\(timing)")
            if index == 0 { continue }
            let cached = origin + "/cached-\(index)"
            view.load(urlString: cached)
            try await wait { !view.webView.isLoading && view.webView.url?.absoluteString == cached }
            let before = server.requests("/cached-\(index)")
            XCTAssertEqual(before, 1)
            let restored = EngineView(frame: view.bounds, configuration: configuration(store))
            defer { restored.tearDown(); restored.removeFromSuperview() }
            restored.restore(urlString: cached)
            XCTAssertNil(restored.webView.url)
            try await timed("cached_tab_first_content_ms") {
                window.contentView = restored
                try await wait { restored.hasRenderedContent }
            }
            try await wait { !restored.webView.isLoading }
            XCTAssertEqual(server.requests("/cached-\(index)"), before, "Cached workload must not silently become a network load")
        }
    }

    func testLoadedSwitchAndSleepingTabResume() async throws {
        let server = try await server(); defer { server.stop() }
        let origin = try XCTUnwrap(server.origin)
        let controller = BrowserWindowController(profile: .defaultProfile); controller.showWindow(nil)
        defer { controller.window?.close() }
        let store = WKWebsiteDataStore.nonPersistent()
        var tabs: [EngineView] = []
        for index in 0..<8 {
            let view = controller.openTab(configuration: configuration(store))
            view.load(urlString: origin + "/tab-\(index)")
            try await wait { view.hasRenderedContent && !view.webView.isLoading }
            tabs.append(view)
        }
        for index in 0..<30 {
            let target = tabs[index % tabs.count]
            try await timed("loaded_tab_switch_ms") {
                controller.activate(target)
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                XCTAssertTrue(controller.activeTab === target)
                XCTAssertTrue(target.hasRenderedContent)
            }
        }
        for target in tabs.prefix(samples) {
            controller.activate(tabs.last!)
            let slept = await target.sleepIfSafe()
            XCTAssertTrue(slept)
            let start = ProcessInfo.processInfo.systemUptime
            try await timed("sleeping_tab_mount_ms") {
                controller.activate(target)
                XCTAssertFalse(target.isSleeping)
                XCTAssertTrue(target.isShowingTabPreview || target.isShowingLoadingCover)
            }
            try await wait { target.hasRenderedContent }
            try record("sleeping_tab_first_content_ms", (ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
    }

    func testOmnibarAndScrollFrames() async throws {
        let candidates = (0..<1000).map { CommandBar.TabCandidate(id: UInt64($0 + 1), title: "Project \($0)", url: "https://example.invalid/project/\($0)", profile: "default") }
        for index in 0..<30 {
            try await timed("omnibar_query_1000_tabs_ms") {
                let results = CommandBar.suggestions(query: "Project \(index)", tabs: candidates, profile: "default", active: nil)
                XCTAssertFalse(results.isEmpty)
            }
        }
        let server = try await server(); defer { server.stop() }
        let view = EngineView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration())
        let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { view.tearDown(); window.close() }
        view.load(urlString: try XCTUnwrap(server.origin) + "/scroll")
        try await wait { view.hasRenderedContent && !view.webView.isLoading }
        window.center()
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        print("Performance scroll: visible=\(window.occlusionState.contains(.visible)), active=\(NSApp.isActive), hidden=\(NSApp.isHidden), frame=\(view.webView.frame)")
        let script = """
        return await new Promise((resolve, reject) => {
          const frames = []; let previous;
          const timeout = setTimeout(() => reject(new Error('Animation frames=' + frames.length + ', visibility=' + document.visibilityState + ', size=' + innerWidth + 'x' + innerHeight)), 10000);
          function frame(now) {
            if (previous !== undefined) frames.push(now - previous);
            previous = now; scrollBy(0, 20);
            if (frames.length === 120) { clearTimeout(timeout); resolve(frames); }
            else requestAnimationFrame(frame);
          }
          requestAnimationFrame(frame);
        });
        """
        var result: Result<Any, Error>?
        view.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result = $0 }
        try await wait { result != nil }
        let frames = try XCTUnwrap(try result?.get() as? [Double])
        XCTAssertEqual(frames.count, 120)
        for frame in frames { try record("scroll_frame_interval_ms", frame) }
    }

    func testNativeToolbarUpgrade() async throws {
        let paths = try ["BOWSER_PERF_TOOLBAR_A", "BOWSER_PERF_TOOLBAR_B"].map {
            try XCTUnwrap(ProcessInfo.processInfo.environment[$0])
        }
        let slot = NativeModuleSlot(fallback: NSView())
        slot.setSnapshot(try JSONSerialization.data(withJSONObject: ["revealed": true, "colors": [:], "buttonStyle": "flat", "cornerRadius": 6, "showNavigation": true, "buttons": []]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 32), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = slot; window.orderFront(nil)
        defer { slot.retire(); window.close() }
        // Live upgrade starts with the existing toolbar already mounted.
        XCTAssertTrue(slot.install(try NativeModuleLibrary(bundle: URL(fileURLWithPath: paths[0]), team: nil, bundled: true)))
        for index in 0...samples {
            try await timed("native_toolbar_upgrade_ms") {
                let library = try NativeModuleLibrary(bundle: URL(fileURLWithPath: paths[(index + 1) % 2]), team: nil, bundled: true)
                try await timed(index == 0 ? "native_toolbar_first_adopt_ms" : "native_toolbar_adopt_ms") {
                    XCTAssertTrue(slot.install(library))
                    XCTAssertEqual(slot.build, library.build)
                }
            }
        }
    }
}
