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
    private static var directory: URL { BowserPaths.home.appendingPathComponent("history", isDirectory: true) }
    private static var preferencesFile: URL { directory.appendingPathComponent("preferences.json") }
    private var preferences: [String: HistoryPreferences] = [:]
    private let worker = HistoryWorkerClient(directory: HistoryController.directory, model: HistoryModelDownload.file)
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
    private var suppressedPage: String?
    private var lastWork = Date.distantPast
    private var queryTask: Task<Void, Never>?
    private var revision = 0
    @Published var selectedProfile = "default" { didSet { excludedSites = settings.exclusions.joined(separator: "\n"); search() } }
    @Published var excludedSites = ""
    @Published var query = "" { didSet { search() } }
    @Published private(set) var results: [HistorySearchItem] = []
    @Published private(set) var isSearching = false
    @Published private(set) var status = "Enable history search to remember pages you visit."
    @Published private(set) var storageText = "Up to 128 MB and 10,000 items per profile."
    private var settings: HistoryPreferences { preferences[selectedProfile] ?? HistoryPreferences() }
    var profiles: [ProfileDisplay] {
        Profile.all.map { ProfileDisplay(id: $0.id, name: $0.name, draft: ProfileDraft(name: $0.name, character: $0.avatar, tint: $0.tint, icon: $0.icon)) }
    }
    var enabled: Bool { get { settings.enabled } set { change { $0.enabled = newValue }; if newValue { downloadModel() } } }
    var includeImages: Bool { get { settings.images } set { change { $0.images = newValue } } }
    var retentionDays: Int { get { settings.days } set { change { $0.days = max(1, min(365, newValue)) }; search() } }
    var isDownloading: Bool { HistoryModelDownload.shared.downloading }
    var modelReady: Bool { HistoryModelDownload.shared.ready }
    private override init() {
        if let data = try? Data(contentsOf: Self.preferencesFile), let decoded = try? JSONDecoder().decode([String: HistoryPreferences].self, from: data) { preferences = decoded }
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
        var value = settings; mutate(&value); preferences[selectedProfile] = value
        revision += 1; pending.removeAll { $0.0 == selectedProfile }
        worker.stop(); workerError = nil; retryAfter = .distantPast
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(preferences).write(to: Self.preferencesFile, options: .atomic)
        } catch { status = "History settings could not be saved." }
        stopCapture(); startTimerIfNeeded(); refresh()
    }
    func downloadModel() { HistoryModelDownload.shared.download() }
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
        if captureID == view.webviewId { stopCapture() }
        suppressedPage = nil
    }
    func refresh() {
        let anyEnabled = preferences.values.contains(where: \.enabled)
        if !anyEnabled { timer?.invalidate(); timer = nil }
        let limited = isResourceLimited
        if limited { stopCapture(); pending.removeAll(); if !wasResourceLimited { worker.stop() } }
        wasResourceLimited = limited
        let browser = BrowserWindowController.all.first { $0.window?.isKeyWindow == true && $0.window?.isMiniaturized != true }
        let view = browser?.activeTab
        let pageKey = view.map { "\($0.webviewId):\($0.webView.url?.absoluteString ?? "")" }
        if let pageKey, pageKey != suppressedPage { suppressedPage = nil }
        if anyEnabled, !limited, NSApp.isActive, let view, !view.isSleeping,
           pageKey != suppressedPage,
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
        if !enabled { status = "History search is off for this profile." }
        else if limited { status = "Capture and indexing paused during a call, sharing, or resource pressure." }
        else if isDownloading { status = "Downloading the 388 MB search model. Text search is already available." }
        else if let error = HistoryModelDownload.shared.error { status = error }
        else if let workerError { status = workerError }
        else { status = modelReady ? "History stays on this Mac. New content is indexed in the background." : "Text search is ready. Download the model for semantic and image search." }
        if !limited { drain() }
        if Date().timeIntervalSince(lastWork) > 30 && !processing && !isSearching { worker.stop() }
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
        Task {
            defer { processing = false; if !pending.isEmpty { drain() } }
            do {
                let response = try await worker.send(request)
                if let error = response.error { workerError = error; retryAfter = Date().addingTimeInterval(60) }
                else { workerError = nil }
                updateStats(response.stats, profile: profile)
            } catch { if !isResourceLimited { workerError = "History indexing paused. It will retry automatically."; retryAfter = Date().addingTimeInterval(60) } }
        }
    }
    private func updateStats(_ stats: HistoryStats?, profile: String) {
        guard let stats else { return }
        indexCounts[profile] = stats.pending
        guard selectedProfile == profile else { return }
        storageText = "\(stats.records) items · \(ByteCountFormatter.string(fromByteCount: stats.bytes, countStyle: .file)) of 128 MB · \(stats.pending) awaiting semantic indexing"
    }
    static func item(_ hit: HistoryHit) -> HistorySearchItem {
        HistorySearchItem(id: hit.id, url: hit.record.url, title: hit.record.title,
            snippet: String(hit.record.content.prefix(240)), seen: hit.record.seen, image: hit.record.image)
    }
    func search(profile: String, query: String) async -> [HistorySearchItem] {
        guard preferences[profile] != nil else { return [] }
        // Resource pressure pauses model execution, including interactive queries.
        guard !isResourceLimited else { return [] }
        lastWork = Date()
        do {
            let response = try await worker.send(HistoryRequest("search", profile: profile, query: query, days: preferences[profile]?.days ?? 90))
            updateStats(response.stats, profile: profile)
            if let error = response.error { status = error }
            return response.hits.filter { HistoryPolicy.permits($0.record.url, exclusions: preferences[profile]?.exclusions ?? []) }.map(Self.item)
        } catch { status = "History search is temporarily unavailable. Try again."; return [] }
    }
    func search() {
        queryTask?.cancel()
        let profile = selectedProfile, query = query, generation = revision
        isSearching = true
        queryTask = Task {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            let found = await search(profile: profile, query: query)
            guard !Task.isCancelled, selectedProfile == profile, self.query == query, revision == generation else { return }
            results = found; isSearching = false
        }
    }
    func open(_ item: HistorySearchItem) {
        (NSApp.delegate as? AppDelegate)?.openTab(url: item.url, activate: true, profile: selectedProfile)
    }
    func delete(_ item: HistorySearchItem) { mutate(HistoryRequest("delete", profile: selectedProfile, key: item.id)) }
    func clear() {
        revision += 1; pending.removeAll { $0.0 == selectedProfile }
        if let view = BrowserWindowController.all.first(where: { $0.profile.id == selectedProfile })?.activeTab {
            suppressedPage = "\(view.webviewId):\(view.webView.url?.absoluteString ?? "")"
        }
        stopCapture()
        results = []; mutate(HistoryRequest("delete", profile: selectedProfile))
    }
    func saveExclusions() {
        let rules = HistoryPolicy.normalizedExclusions(excludedSites)
        change { $0.exclusions = rules }
        excludedSites = rules.joined(separator: "\n")
        for host in rules { mutate(HistoryRequest("exclude", profile: selectedProfile, key: host)) }
    }
    private func mutate(_ request: HistoryRequest) {
        Task { do { let response = try await worker.send(request); if let error = response.error { status = error }; search() }
            catch { status = "History could not be updated. Try again." } }
    }
}
