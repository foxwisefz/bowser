import AppKit
import WebKit
import UniformTypeIdentifiers

/// Downloads and pending WebKit completions outlive their tab and controller.
@MainActor final class NativeDownloads: NSObject, WKDownloadDelegate {
    static let shared = NativeDownloads()
    enum Destination { case downloads, saveAs }
    @MainActor private final class ResourceSave {
        let resource: ResourceDownload
        let mode: Destination
        weak var window: NSWindow?
        let completed: ((Result<URL, Error>) -> Void)?
        var temporaryDirectory: URL?
        var panel: NSSavePanel?
        var cancelled = false
        let activity: DownloadActivityView?
        init(resource: ResourceDownload, mode: Destination, window: NSWindow?, completed: ((Result<URL, Error>) -> Void)?) {
            self.resource = resource; self.mode = mode; self.window = window; self.completed = completed
            activity = completed == nil ? DownloadActivityView() : nil
        }
    }
    private struct Record {
        let tab: UInt64
        let profile: String
        let download: WKDownload?
        var destination: URL?
        var suggested = ""
        var completion: ((URL?) -> Void)?
        var save: ResourceSave?
        var activity: DownloadActivityView?
    }
    var destinationDirectory: URL?
    private var records: [String: Record] = [:]
    /// A destination chooser may be supplied by integration tests without opening a sheet.
    var chooseDestination: ((String, NSWindow?, @escaping (URL?) -> Void) -> Void)?
    var snapshot: [[String: Any]] {
        records.keys.sorted().map { id in
            let r = records[id]!
            return ["id":id, "tab":r.tab, "profile":r.profile, "suggested":r.suggested, "awaiting_destination":r.completion != nil]
        }
    }
    func attach(_ download: WKDownload, tab: UInt64, profile: String, window: NSWindow? = nil) {
        let activity = DownloadActivityView()
        let window = window ?? BrowserWindowController.host(of: tab)?.window
        activity.show(in: window)
        if let store = download.webView?.configuration.websiteDataStore, let request = download.originalRequest {
            activity.onRetry = { [weak self, weak window] in
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = store
                let source = WKWebView(frame: .zero, configuration: configuration)
                source.startDownload(using: request) { [weak self, source] retried in
                    _ = source // Keep the originating store alive through admission.
                    self?.attach(retried, tab: tab, profile: profile, window: window)
                }
            }
        }
        let id = UUID().uuidString
        records[id] = Record(tab: tab, profile: profile, download: download, activity: activity)
        activity.onCancel = { [weak self] in self?.cancel(id) }
        download.delegate = self
    }
    func startResource(_ resource: ResourceDownload, in webView: WKWebView, tab: UInt64,
                       profile: String, destination: Destination,
                       completed: ((Result<URL, Error>) -> Void)? = nil, window: NSWindow? = nil) {
        let window = window ?? webView.window
        let save = ResourceSave(resource: resource, mode: destination, window: window, completed: completed)
        let store = webView.configuration.websiteDataStore
        save.activity?.onRetry = { [weak self, weak window] in
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = store
            let source = WKWebView(frame: .zero, configuration: configuration)
            self?.startResource(resource, in: source, tab: tab, profile: profile,
                                destination: destination, window: window)
        }
        save.activity?.show(in: save.window)
        var request = URLRequest(url: resource.url)
        request.mainDocumentURL = resource.url
        let id = UUID().uuidString
        save.activity?.onCancel = { [weak self, weak save] in
            save?.cancelled = true
            self?.cancel(id)
        }
        webView.startDownload(using: request) { [self, webView] download in
            _ = webView
            guard !save.cancelled else { download.cancel(nil); return }
            records[id] = Record(tab: tab, profile: profile, download: download, save: save, activity: save.activity)
            download.delegate = self
        }
    }
    func stage(id: String, tab: UInt64, profile: String, suggested: String, completion: @escaping (URL?) -> Void) {
        if records[id] == nil { records[id] = Record(tab: tab, profile: profile, download: nil) }
        records[id]?.suggested = suggested
        records[id]?.completion = completion
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard let id = records.first(where: { $0.value.download === download })?.key, let record = records[id] else { completionHandler(nil); return }
        if let save = record.save {
            guard save.resource.accepts(response) else {
                records.removeValue(forKey: id)
                completionHandler(nil)
                report(.failure(NSError(domain: "BowserDownload", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "The website did not return the expected file. Your session or download link may have expired; reopen it and try again."])), for: save)
                return
            }
            let filename = save.resource.filename(suggestedFilename)
            stage(id: id, tab: record.tab, profile: record.profile, suggested: filename, completion: completionHandler)
            if save.mode == .downloads {
                selectDestination(id, destination: Self.uniqueURL(filename, directory: destinationDirectory,
                    reserved: Set(records.values.compactMap(\.destination))))
            } else {
                let choose: (URL?) -> Void = { [self] url in selectDestination(id, destination: url) }
                if let chooseDestination { chooseDestination(filename, save.window, choose) }
                else {
                    let panel = NSSavePanel()
                    if let type = save.resource.contentType { panel.allowedContentTypes = [type] }
                    panel.nameFieldStringValue = filename
                    panel.directoryURL = destinationDirectory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    save.panel = panel
                    let done: (NSApplication.ModalResponse) -> Void = { response in
                        save.panel = nil
                        choose(response == .OK ? panel.url : nil)
                    }
                    if let window = save.window { panel.beginSheetModal(for: window, completionHandler: done) }
                    else { panel.begin(completionHandler: done) }
                }
            }
            return
        }
        stage(id: id, tab: record.tab, profile: record.profile, suggested: suggestedFilename, completion: completionHandler)
        record.activity?.start(filename: Self.safeFilename(suggestedFilename), progress: download.progress)
        if BrainBridge.shared.resources.shouldCoordinate {
            if !BrainBridge.shared.resources.request(["action":"download_destination", "download":id]) {
                records[id]?.completion = nil; completionHandler(nil)
            }
        } else {
            _ = choose(["download":id, "profile":record.profile, "filename":Self.safeFilename(suggestedFilename)])
        }
    }
    private func selectDestination(_ id: String, destination: URL?) {
        guard var record = records[id], let save = record.save, let completion = record.completion else { return }
        guard let destination else { cancelDestination(id); return }
        do {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("bowser-download-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            save.temporaryDirectory = temporary
            record.destination = destination; record.completion = nil; records[id] = record
            record.activity?.start(filename: destination.lastPathComponent, progress: record.download?.progress)
            completion(temporary.appendingPathComponent("resource.download"))
        } catch {
            records.removeValue(forKey: id)
            completion(nil)
            report(.failure(error), for: save)
        }
    }
    func choose(_ command: [String: Any]) -> Bool {
        guard let id = command["download"] as? String, var record = records[id],
              record.save == nil,
              command["profile"] as? String == record.profile, let completion = record.completion,
              let filename = command["filename"] as? String, filename == Self.safeFilename(filename) else { return false }
        let destination = Self.uniqueURL(filename, directory: destinationDirectory, reserved: Set(records.values.compactMap(\.destination)))
        record.completion = nil; record.destination = destination; records[id] = record
        record.activity?.start(filename: destination.lastPathComponent, progress: record.download?.progress)
        BrainBridge.shared.send(["op":"event", "event":"download", "download":id,
                                 "webview":record.tab, "profile":record.profile, "state":"started", "filename":destination.lastPathComponent])
        completion(destination)
        return true
    }
    func downloadDidFinish(_ download: WKDownload) { finish(download, state: "finished", error: nil) }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        finish(download, state: "failed", error: error.localizedDescription)
    }
    private func finish(_ download: WKDownload, state: String, error: String?) {
        guard let id = records.first(where: { $0.value.download === download })?.key,
              let record = records.removeValue(forKey: id) else { return }
        if let save = record.save {
            record.completion?(nil)
            save.panel?.cancel(nil)
            defer {
                if let directory = save.temporaryDirectory { try? FileManager.default.removeItem(at: directory) }
            }
            do {
                if let error { throw NSError(domain: "BowserDownload", code: 3, userInfo: [NSLocalizedDescriptionKey: error]) }
                guard let temporary = save.temporaryDirectory?.appendingPathComponent("resource.download"),
                      var destination = record.destination else { return }
                try save.resource.validateFile(temporary)
                if save.mode == .downloads {
                    destination = Self.uniqueURL(destination.lastPathComponent, directory: destination.deletingLastPathComponent(),
                                                 reserved: Set(records.values.compactMap(\.destination)))
                }
                if save.mode == .saveAs && FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else { try FileManager.default.moveItem(at: temporary, to: destination) }
                report(.success(destination), for: save)
            } catch { report(.failure(error), for: save) }
            return
        }
        var message: [String: Any] = ["op":"event", "event":"download", "download":id,
            "webview":record.tab, "profile":record.profile, "state":state]
        if let error { message["error"] = error }
        if let error {
            if let destination = record.destination { try? FileManager.default.removeItem(at: destination) }
            record.activity?.finish(.failure(NSError(domain: "BowserDownload", code: 3,
                userInfo: [NSLocalizedDescriptionKey: error])))
        } else if let destination = record.destination {
            record.activity?.finish(.success(destination))
        }
        BrainBridge.shared.send(message)
    }
    private func report(_ result: Result<URL, Error>, for save: ResourceSave) {
        if let completed = save.completed { completed(result) }
        else { save.activity?.finish(result) }
    }
    func cancel(_ id: String) {
        guard let record = records.removeValue(forKey: id) else { return }
        record.save?.cancelled = true
        record.activity?.onCancel = nil
        record.completion?(nil)
        record.save?.panel?.cancel(nil)
        record.activity?.dismissActivity()
        record.download?.cancel { _ in
            if let directory = record.save?.temporaryDirectory {
                try? FileManager.default.removeItem(at: directory)
            } else if record.save == nil, let destination = record.destination {
                // WebKit leaves the partial file after cancellation. Its destination
                // was reserved for this transfer; remove it only after writing stops.
                try? FileManager.default.removeItem(at: destination)
            }
        }
        record.save?.completed?(.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        BrainBridge.shared.send(["op":"event", "event":"download", "download":id,
            "webview":record.tab, "profile":record.profile, "state":"cancelled"])
    }

    func cancelDestination(_ id: String) {
        guard let record = records.removeValue(forKey: id) else { return }
        record.completion?(nil)
        record.save?.panel?.cancel(nil)
        record.activity?.dismissActivity()
        if let directory = record.save?.temporaryDirectory { try? FileManager.default.removeItem(at: directory) }
    }
    nonisolated static func safeFilename(_ suggested: String) -> String {
        let value = (suggested.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            .components(separatedBy: .controlCharacters).joined()
        return value.isEmpty || value == "." || value == ".." ? "download" : String(value.prefix(180))
    }
    static func uniqueURL(_ suggested: String, directory: URL? = nil, reserved: Set<URL> = []) -> URL {
        let dir = directory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        var url = dir.appendingPathComponent(safeFilename(suggested))
        let ext = url.pathExtension, base = url.deletingPathExtension().lastPathComponent
        var n = 1
        while reserved.contains(url) || FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}
