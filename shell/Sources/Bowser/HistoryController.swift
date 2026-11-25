import AppKit
import WebKit
import Combine
import HistoryCore
import BowserSurfaceKit

private struct HistoryPreferences: Codable {
    var enabled = false
    var images = true
    var days = 90
    var exclusions: [String] = []
}

@MainActor final class HistoryController: NSObject, ObservableObject, HistoryPresentation, WKScriptMessageHandler {
    static let shared = HistoryController()
    private let directory: URL
    private var preferencesFile: URL { directory.appendingPathComponent("preferences.json") }
    private var preferences: [String: HistoryPreferences] = [:]
    private let worker: HistoryWorkerClient
    private let repository: HistoryRepository
    private struct Visit {
        var id = UUID().uuidString
        var url: String
        var title: String
        var seen = Date()
        var previewAttempted = false
        var savedTitle: String?
        var saving = false
        var retryAfter = Date.distantPast
    }
    private var visits: [UInt64: Visit] = [:]
    private var urlChanges: [UInt64: Task<Void, Never>] = [:]
    private var recordingErrors: [String: String] = [:]
    private var settingsError: String?
    var recordingIssue: String? { settingsError ?? recordingErrors[selectedProfile] }
    private var resultLimit = 60
    private var timer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var pressure: DispatchSourceMemoryPressure?
    private var memoryLimited = false
    private var wasResourceLimited = false
    private var retryAfter = Date.distantPast
    private var workerError: String?
    private var captureID: UInt64?
    private var captureURL = ""
    private var token = ""
    private var pending: [(String, HistoryRecord)] = []
    private var processing = false
    private var indexCounts: [String: Int] = [:]
    private var profileStats: [String: HistoryStats] = [:]
    private var suppressedPages: [UInt64: String] = [:]
    private var lastWork = Date.distantPast
    private var queryTask: Task<Void, Never>?
    private var revision = 0
    @Published var selectedProfile = "default" {
        didSet {
            excludedSites = settings.exclusions.joined(separator: "\n")
            presentStats()
            refreshStatus()
            search(clearResults: oldValue != selectedProfile)
        }
    }
    @Published var excludedSites = ""
    @Published var query = "" { didSet { search(clearResults: oldValue != query) } }
    @Published var allProfiles = false { didSet { search(clearResults: oldValue != allProfiles) } }
    @Published var dateFilter = "all" { didSet { search(clearResults: oldValue != dateFilter) } }
    @Published var siteFilter = "" { didSet { search(clearResults: oldValue != siteFilter) } }
    @Published private(set) var hasMore = false
    @Published private(set) var lastSaved: Date?
    @Published private(set) var searchError: String?
    @Published private(set) var results: [HistorySearchItem] = []
    @Published private(set) var isSearching = false
    @Published private(set) var status = "Enable history search to remember pages you visit."
    @Published private(set) var storageText = "Up to 128 MB and 10,000 items per profile."
    @Published private(set) var storageWarning: String?
    private var settings: HistoryPreferences { preferences[selectedProfile] ?? HistoryPreferences() }
    var profiles: [ProfileDisplay] {
        Profile.all.map { ProfileDisplay(id: $0.id, name: $0.name, draft: ProfileDraft(name: $0.name, character: $0.avatar, tint: $0.tint, icon: $0.icon)) }
    }
    var enabled: Bool { get { settings.enabled } set { change { $0.enabled = newValue }; if newValue { downloadModel() } } }
    var includeImages: Bool { get { settings.images } set { change { $0.images = newValue } } }
    var retentionDays: Int { get { settings.days } set { change { $0.days = max(1, min(365, newValue)) }; search() } }
    var isDownloading: Bool { HistoryModelDownload.shared.downloading }
    var modelReady: Bool { HistoryModelDownload.shared.ready }
    private override convenience init() { self.init(directory: BowserPaths.home.appendingPathComponent("history", isDirectory: true)) }
    init(directory: URL) {
        self.directory = directory
        worker = HistoryWorkerClient(directory: directory, model: HistoryModelDownload.file)
        repository = HistoryRepository(directory: directory)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("preferences.json")), let decoded = try? JSONDecoder().decode([String: HistoryPreferences].self, from: data) { preferences = decoded }
        super.init()
        for (profile, pref) in preferences where pref.enabled { indexCounts[profile] = 1 }
        excludedSites = settings.exclusions.joined(separator: "\n")
        HistoryModelDownload.shared.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let source = self.pressure else { return }
            self.memoryLimited = !source.data.contains(.normal)
            self.refresh()
        }
        source.resume(); pressure = source
        startTimerIfNeeded()
    }
    func attach(_ view: EngineView) {
        let controller = view.webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "bowserHistory", contentWorld: HistoryCapture.world)
        controller.add(self, contentWorld: HistoryCapture.world, name: "bowserHistory")
        startTimerIfNeeded()
    }
    private func startTimerIfNeeded() {
        guard timer == nil, preferences.values.contains(where: \.enabled) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
    private func change(_ mutate: (inout HistoryPreferences) -> Void) {
        objectWillChange.send()
        var value = settings; mutate(&value)
        var updated = preferences; updated[selectedProfile] = value
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(updated).write(to: preferencesFile, options: .atomic)
        } catch {
            settingsError = "History settings could not be saved. Your previous settings are still in use."
            refreshStatus(); return
        }
        preferences = updated; settingsError = nil
        revision += 1; pending.removeAll { $0.0 == selectedProfile }
        let profile = selectedProfile, generation = revision
        Task { await repository.invalidate(profile: profile, generation: generation) }
        if !value.enabled { visits = visits.filter { EngineView.live[$0.key]?.profileId != profile } }
        worker.stop(); workerError = nil; retryAfter = .distantPast
        stopCapture(); startTimerIfNeeded(); refresh()
    }
    func downloadModel() { HistoryModelDownload.shared.download() }
    func showSettings() { SettingsWindow.shared.show(select: "history") }
    func showBrowser() { (NSApp.delegate as? AppDelegate)?.openHistory(forProfile: selectedProfile) }
    var isResourceLimited: Bool {
        memoryLimited || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
        || CaptureMode.shared.isEnabled || EngineView.live.values.contains {
            $0.webView.cameraCaptureState != .none || $0.webView.microphoneCaptureState != .none
        }
    }
    func permits(profile: String, url: String) -> Bool {
        guard let pref = preferences[profile], pref.enabled else { return false }
        return HistoryPolicy.permits(url, exclusions: pref.exclusions)
    }
    func navigationChanged(_ view: EngineView) {
        urlChanges.removeValue(forKey: view.webviewId)?.cancel()
        if captureID == view.webviewId { stopCapture() }
        suppressedPages.removeValue(forKey: view.webviewId)
        recordVisit(view, committed: true)
    }
    func urlChanged(_ view: EngineView) {
        let id = view.webviewId
        urlChanges.removeValue(forKey: id)?.cancel()
        // KVO can precede isLoading/didStart. Wait for that delegate turn so
        // a provisional URL is not mistaken for a same-document navigation.
        urlChanges[id] = Task { [weak self, weak view] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, let view else { return }
            self.urlChanges.removeValue(forKey: id)
            self.recordVisit(view, allowURLChange: true)
        }
    }
    func forget(_ view: EngineView) {
        urlChanges.removeValue(forKey: view.webviewId)?.cancel()
        visits.removeValue(forKey: view.webviewId); suppressedPages.removeValue(forKey: view.webviewId)
    }
    func recordVisit(_ view: EngineView, committed: Bool = false, allowURLChange: Bool = false) {
        guard !view.isHistoryPage, (committed || (view.historyNavigationCommitted && !view.webView.isLoading)), view.webView.configuration.websiteDataStore.isPersistent,
              let url = view.webView.url?.absoluteString, permits(profile: view.profileId, url: url),
              suppressedPages[view.webviewId] != url else { return }
        if !committed, !allowURLChange, let previous = visits[view.webviewId], previous.url != url { return }
        suppressedPages.removeValue(forKey: view.webviewId)
        let loadedTitle = view.webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = String((loadedTitle.isEmpty ? URL(string: url)?.host ?? url : loadedTitle).prefix(240))
        var visit: Visit
        if !committed, let previous = visits[view.webviewId], previous.url == url {
            guard !previous.saving, Date() >= previous.retryAfter, previous.savedTitle != title else { return }
            visit = previous; visit.title = title
        } else { visit = Visit(url: url, title: title) }
        visit.saving = true
        visits[view.webviewId] = visit
        let profile = view.profileId, generation = revision, days = preferences[profile]?.days ?? 90, viewID = view.webviewId
        Task {
            do {
                let stats = try await repository.record(profile: profile, id: visit.id,
                    value: HistoryRecord(url: url, title: title, text: "", seen: visit.seen), days: days, generation: generation)
                if visits[viewID]?.id == visit.id { visits[viewID]?.saving = false; visits[viewID]?.savedTitle = stats == nil ? nil : title }
                guard revision == generation else { return }
                recordingErrors.removeValue(forKey: profile); updateStats(stats, profile: profile); refreshStatus()
                // The final title may arrive while the initial visit is being saved.
                if let current = EngineView.live[viewID], visits[viewID]?.id == visit.id { recordVisit(current) }
            } catch {
                if visits[viewID]?.id == visit.id { visits[viewID]?.saving = false; visits[viewID]?.retryAfter = Date().addingTimeInterval(30) }
                guard revision == generation else { return }
                recordingErrors[profile] = "Visits could not be saved. Check available disk space. Bowser will retry automatically."
                refreshStatus()
            }
        }
    }
    private var pauseReason: String? {
        if EngineView.live.values.contains(where: { $0.webView.cameraCaptureState != .none || $0.webView.microphoneCaptureState != .none }) { return "a camera or microphone is in use" }
        if CaptureMode.shared.isEnabled { return "screen capture mode is on" }
        if memoryLimited { return "memory pressure is high" }
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical { return "the Mac is under thermal pressure" }
        return nil
    }
    private func refreshStatus() {
        let message: String
        if let recordingIssue { message = recordingIssue }
        else if !enabled { message = "Visit recording is off for this profile. Saved history is still available." }
        else if let reason = pauseReason { message = "Visits keep saving. Content capture and visual search are paused because \(reason)." }
        else if isDownloading { message = "Visits keep saving. Downloading the visual search model." }
        else if let error = HistoryModelDownload.shared.error { message = error }
        else if let workerError { message = workerError }
        else { message = modelReady ? "Saving visits and page content on this Mac." : "Saving visits. Download the model to search by description and appearance." }
        if status != message { status = message }
    }
    func refresh() {
        let anyEnabled = preferences.values.contains(where: \.enabled)
        if !anyEnabled { timer?.invalidate(); timer = nil }
        let limited = isResourceLimited
        if limited { stopCapture(); pending.removeAll(); if !wasResourceLimited { worker.stop() } }
        wasResourceLimited = limited
        let browser = BrowserWindowController.all.first { $0.window?.isKeyWindow == true && $0.window?.isMiniaturized != true }
        let view = browser?.activeTab
        if let view { recordVisit(view) }
        if anyEnabled, !limited, NSApp.isActive, let view, !view.isSleeping, !view.isHistoryPage,
           suppressedPages[view.webviewId] != view.webView.url?.absoluteString,
           !view.webView.isLoading, view.webView.configuration.websiteDataStore.isPersistent,
           let url = view.webView.url?.absoluteString, permits(profile: view.profileId, url: url) {
            if captureID != view.webviewId || captureURL != url {
                stopCapture(); captureID = view.webviewId; captureURL = url; token = UUID().uuidString
                let expectedToken = token
                view.webView.evaluateJavaScript(HistoryCapture.script, in: nil, in: HistoryCapture.world) { [weak self, weak view] result in
                    guard let self, let view, self.token == expectedToken, case .success = result else { return }
                    view.webView.callAsyncJavaScript("globalThis.__bowserHistory?.start(token,images)",
                        arguments: ["token": expectedToken, "images": self.preferences[view.profileId]?.images ?? true], in: nil, in: HistoryCapture.world) { _ in }
                }
            }
        } else { stopCapture() }
        if !limited, let view { capturePreview(view) }
        refreshStatus()
        if !limited { drain() }
        if Date().timeIntervalSince(lastWork) > 30 && !processing && !isSearching { worker.stop() }
    }
    /// One bounded preview per committed page, only after it settles in the foreground.
    /// Calls, private pages, exclusions and visible editable/sensitive content skip it.
    private func capturePreview(_ view: EngineView) {
        guard NSApp.isActive, !view.isHistoryPage, !view.webView.isLoading, !view.isSleeping, view.window?.isKeyWindow == true,
              preferences[view.profileId]?.images == true, let visit = visits[view.webviewId],
              visit.savedTitle != nil,
              !visit.previewAttempted, Date().timeIntervalSince(visit.seen) >= 2,
              view.webView.url?.absoluteString == visit.url, permits(profile: view.profileId, url: visit.url),
              view.webView.bounds.width > 100, view.webView.bounds.height > 80 else { return }
        visits[view.webviewId]?.previewAttempted = true
        let generation = revision, profile = view.profileId, days = preferences[profile]?.days ?? 90
        view.webView.evaluateJavaScript(HistoryCapture.validatePreview, in: nil, in: HistoryCapture.world) { [weak self, weak view] result in
            guard let self, let view, case .success(let allowed as Bool) = result, allowed,
                  !self.isResourceLimited, self.revision == generation, self.visits[view.webviewId]?.id == visit.id,
                  view.webView.url?.absoluteString == visit.url, view.window?.isKeyWindow == true else { return }
            let configuration = HistoryCapture.previewConfiguration(bounds: view.webView.bounds, scale: view.window?.backingScaleFactor ?? 1)
            view.webView.takeSnapshot(with: configuration) { [weak self, weak view] image, _ in
                guard let self, let view, !self.isResourceLimited, self.revision == generation,
                      self.visits[view.webviewId]?.id == visit.id, view.webView.url?.absoluteString == visit.url,
                      let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.55]), data.count <= 64_000 else { return }
                Task {
                    do { let stats = try await self.repository.preview(profile: profile, id: visit.id, data: data, days: days, generation: generation); self.updateStats(stats, profile: profile) }
                    catch { self.workerError = "A page preview could not be saved. Visit history is still available." }
                }
            }
        }
    }
    private func stopCapture() {
        if let captureID, let view = EngineView.live[captureID] {
            view.webView.evaluateJavaScript("globalThis.__bowserHistory?.stop()", in: nil, in: HistoryCapture.world) { _ in }
        }
        captureID = nil; captureURL = ""; token = ""
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, !isResourceLimited,
              let id = captureID, let view = EngineView.live[id], message.webView === view.webView,
              BrowserWindowController.host(of: id)?.activeTab === view,
              let body = message.body as? [String: Any], body["token"] as? String == token,
              body["url"] as? String == captureURL, view.webView.url?.absoluteString == captureURL,
              permits(profile: view.profileId, url: captureURL),
              let records = body["records"] as? [[String: Any]], records.count <= 4 else { return }
        let profile = view.profileId, expected = token
        for raw in records {
            guard let url = raw["url"] as? String, let text = raw["text"] as? String,
                  HistoryPolicy.permits(url, exclusions: preferences[profile]?.exclusions ?? []) else { continue }
            let record = HistoryRecord(url: url, title: raw["title"] as? String ?? "", text: text, appearance: raw["appearance"] as? String ?? "")
            // An image without alt text has content only after its crop finishes.
            guard record.validated(requireContent: !(raw["image"] is [String: Any])) != nil else { continue }
            if preferences[profile]?.images == true, let rect = raw["image"] as? [String: Any], let src = rect["src"] as? String,
               let x = rect["x"] as? Double, let y = rect["y"] as? Double, let width = rect["width"] as? Double, let height = rect["height"] as? Double,
               [x,y,width,height].allSatisfy(\.isFinite), width >= 100, height >= 80, x >= 0, y >= 0,
               x+width <= view.webView.bounds.width, y+height <= view.webView.bounds.height {
                let configuration = WKSnapshotConfiguration()
                configuration.rect = CGRect(x: x, y: y, width: width, height: height)
                configuration.snapshotWidth = 384; configuration.afterScreenUpdates = false
                view.webView.callAsyncJavaScript(HistoryCapture.validateImage, arguments: ["rect": ["x": x, "y": y, "width": width, "height": height], "src": src], in: nil, in: HistoryCapture.world) { [weak self, weak view] validation in
                    guard let self, let view, self.token == expected, !self.isResourceLimited else { return }
                    guard case .success(let valid as Bool) = validation, valid else { self.enqueue(record, profile: profile); return }
                    view.webView.takeSnapshot(with: configuration) { [weak self] image, _ in
                    guard let self, self.token == expected, !self.isResourceLimited, self.permits(profile: profile, url: record.url) else { return }
                    var captured = record
                    if let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                       let bytes = NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.65]), bytes.count <= 128_000 { captured.image = bytes }
                    self.enqueue(captured, profile: profile)
                    }
                }
            } else { enqueue(record, profile: profile) }
        }
    }
    private func enqueue(_ record: HistoryRecord, profile: String) {
        guard record.validated() != nil, permits(profile: profile, url: record.url) else { return }
        if pending.count >= 16 { pending.removeFirst() }
        pending.append((profile, record)); drain()
    }
    private func drain() {
        guard !processing, !isResourceLimited, Date() >= retryAfter else { return }
        let next = pending.isEmpty ? nil : pending.removeFirst()
        let profile = next?.0 ?? indexCounts.first(where: { $0.value > 0 && preferences[$0.key]?.enabled == true })?.key
        guard let profile, preferences[profile]?.enabled == true, next != nil || modelReady else { return }
        let request = next.map { HistoryRequest("capture", profile: profile, record: $0.1, days: preferences[profile]?.days ?? 90) }
            ?? HistoryRequest("index", profile: profile, days: preferences[profile]?.days ?? 90)
        processing = true; lastWork = Date()
        let generation = revision
        Task {
            defer { processing = false; if !pending.isEmpty { drain() } }
            do {
                let response = try await worker.send(request)
                guard revision == generation else { return }
                if let error = response.error { workerError = error; retryAfter = Date().addingTimeInterval(60) }
                else { workerError = nil }
                updateStats(response.stats, profile: profile)
            } catch { if revision == generation && !isResourceLimited { workerError = "History indexing paused. It will retry automatically."; retryAfter = Date().addingTimeInterval(60) } }
        }
    }
    private func updateStats(_ stats: HistoryStats?, profile: String) {
        guard let stats else { return }
        indexCounts[profile] = stats.pending
        profileStats[profile] = stats
        guard selectedProfile == profile || allProfiles else { return }
        presentStats()
    }
    private func presentStats() {
        lastSaved = allProfiles ? profileStats.values.compactMap(\.lastVisit).max() : profileStats[selectedProfile]?.lastVisit
        guard let stats = profileStats[selectedProfile] else {
            storageText = "Up to 128 MB and 10,000 items per profile."; storageWarning = nil; return
        }
        storageText = "\((stats.visits ?? 0).formatted()) visits · \(stats.records.formatted()) content captures · \(ByteCountFormatter.string(fromByteCount: stats.bytes, countStyle: .memory)) of 128 MB · \(stats.pending) awaiting visual search"
        switch stats.capacityState {
        case .normal: storageWarning = nil
        case .nearLimit:
            storageWarning = "History is nearing its limit. The oldest items will be removed automatically at 128 MB or 10,000 items."
        case .trimmed(let cleanup):
            let count = cleanup.removedCount.formatted(), noun = cleanup.removedCount == 1 ? "item" : "items"
            storageWarning = "History reached its limit. \(count) older \(noun) removed in total to stay within 128 MB and 10,000 items. Last removal: \(cleanup.lastRemovedAt.formatted(date: .abbreviated, time: .shortened))."
        }
    }
    static func item(_ hit: HistoryHit, profile: String = "") -> HistorySearchItem {
        HistorySearchItem(id: profile + ":" + hit.id, url: hit.record.url, title: hit.record.title,
            snippet: String(hit.record.content.prefix(240)), seen: hit.record.seen, image: hit.record.image,
            profile: profile, key: hit.id, isVisit: hit.isVisit == true)
    }
    func search(profile: String, query: String) async -> [HistorySearchItem] {
        guard preferences[profile] != nil else { return [] }
        lastWork = Date()
        do {
            let (hits, stats) = try await repository.browse(profile: profile, query: query, limit: 20, days: preferences[profile]?.days ?? 90)
            updateStats(stats, profile: profile)
            var found = hits
            if !query.isEmpty, !isResourceLimited, modelReady {
                if let response = try? await worker.send(HistoryRequest("search", profile: profile, query: query, days: preferences[profile]?.days ?? 90)), response.error == nil {
                    let urls = Set(found.map { $0.record.url })
                    found += response.hits.filter { !urls.contains($0.record.url) }
                }
            }
            var seen = Set<String>()
            return found.filter { seen.insert($0.record.url).inserted && HistoryPolicy.permits($0.record.url, exclusions: preferences[profile]?.exclusions ?? []) }.prefix(20).map { Self.item($0, profile: profile) }
        } catch { searchError = "History could not be read. Your saved data has not been cleared."; return [] }
    }
    func search() {
        search(clearResults: false)
    }
    private func search(clearResults: Bool) {
        resultLimit = 60
        performSearch()
        if clearResults {
            results = []
            hasMore = false
        }
    }
    func loadMore() { resultLimit += 60; performSearch() }
    private func performSearch() {
        queryTask?.cancel()
        let profiles = allProfiles ? self.profiles.map(\.id) : [selectedProfile]
        let query = query, generation = revision, date = dateFilter, site = siteFilter, limit = resultLimit
        isSearching = true
        searchError = nil
        queryTask = Task {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let after: Date?
            switch date {
            case "today": after = today
            case "yesterday": after = calendar.date(byAdding: .day, value: -1, to: today)
            case "week": after = calendar.date(byAdding: .day, value: -6, to: today)
            default: after = nil
            }
            let before: Date? = date == "yesterday" ? today : nil
            var found: [HistorySearchItem] = []
            do {
                for profile in profiles {
                    let (hits, stats) = try await repository.browse(profile: profile, query: query, after: after, before: before, host: site, limit: limit + 1, days: preferences[profile]?.days ?? 90)
                    guard !Task.isCancelled, revision == generation else { return }
                    updateStats(stats, profile: profile)
                    found += hits.filter { HistoryPolicy.permits($0.record.url, exclusions: preferences[profile]?.exclusions ?? []) }.map { Self.item($0, profile: profile) }
                }
                found.sort { $0.seen > $1.seen }
                hasMore = found.count > limit
                results = Array(found.prefix(limit)); isSearching = false
                // Publish ordinary search first; semantic enrichment never blocks the list.
                if !query.isEmpty, !isResourceLimited, modelReady {
                    for profile in profiles {
                        guard !Task.isCancelled, !isResourceLimited else { return }
                        guard let response = try? await worker.send(HistoryRequest("search", profile: profile, query: query, days: preferences[profile]?.days ?? 90)), response.error == nil else { continue }
                        guard !Task.isCancelled, revision == generation else { return }
                        let urls = Set(found.filter { $0.profile == profile }.map(\.url))
                        let extra = response.hits.filter { hit in
                            let host = URL(string: hit.record.url)?.host ?? ""
                            return !urls.contains(hit.record.url) && (after == nil || hit.record.seen >= after!) && (before == nil || hit.record.seen < before!)
                                && (site.isEmpty || host == site || host.hasSuffix("." + site))
                                && HistoryPolicy.permits(hit.record.url, exclusions: preferences[profile]?.exclusions ?? [])
                        }.map { Self.item($0, profile: profile) }
                        found += extra
                        results = Array(found.prefix(limit))
                    }
                }
            } catch {
                guard !Task.isCancelled, revision == generation else { return }
                isSearching = false; searchError = "History could not be read. Retry to reconnect; your saved data has not been cleared."
            }
        }
    }
    func open(_ item: HistorySearchItem) {
        (NSApp.delegate as? AppDelegate)?.reopenHistoryPage(item.url, profile: item.profile.isEmpty ? selectedProfile : item.profile)
    }
    func delete(_ item: HistorySearchItem) { delete([item]) }
    func delete(_ items: [HistorySearchItem]) {
        revision += 1; worker.stop(); stopCapture(); pending.removeAll()
        let generation = revision
        let groups = Dictionary(grouping: items, by: { $0.profile.isEmpty ? selectedProfile : $0.profile })
        let ids = Set(items.map(\.key))
        for (id, visit) in visits.filter({ ids.contains($0.value.id) }) {
            suppressedPages[id] = visit.url; visits.removeValue(forKey: id)
        }
        Task {
            do {
                for (profile, items) in groups {
                    let stats = try await repository.delete(profile: profile, visits: items.filter(\.isVisit).map(\.key), records: items.filter { !$0.isVisit }.map(\.key), generation: generation)
                    updateStats(stats, profile: profile)
                }
                search()
            } catch { searchError = "Some selected history could not be deleted. Retry to finish." }
        }
    }
    func clear() {
        revision += 1; pending.removeAll { $0.0 == selectedProfile }
        for view in EngineView.live.values where view.profileId == selectedProfile {
            suppressedPages[view.webviewId] = view.webView.url?.absoluteString
        }
        worker.stop(); stopCapture()
        let profile = selectedProfile, generation = revision
        visits = visits.filter { EngineView.live[$0.key]?.profileId != profile }
        Task {
            do { let stats = try await repository.delete(profile: profile, all: true, generation: generation); updateStats(stats, profile: profile); search() }
            catch { searchError = "History could not be cleared. Your saved data remains available." }
        }
    }
    func saveExclusions() {
        let rules = HistoryPolicy.normalizedExclusions(excludedSites)
        change { $0.exclusions = rules }
        guard settings.exclusions == rules else { return }
        excludedSites = rules.joined(separator: "\n")
        let profile = selectedProfile, generation = revision
        Task {
            do {
                for host in rules { let stats = try await repository.delete(profile: profile, host: host, generation: generation); updateStats(stats, profile: profile) }
                search()
            } catch { searchError = "Excluded-site history could not be removed. Retry to finish." }
        }
    }
}
