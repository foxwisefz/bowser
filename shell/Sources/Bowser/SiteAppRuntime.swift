import AppKit
import BackendRuntime
import Darwin
import WebKit

struct SiteAppConfiguration: Codable, Equatable {
    let url: URL
    let profile: String
    let identifier: String
    let mainApp: URL

    static let identifierPrefix = "com.foxwiseai.bowser.site."
    static let current = parse(Bundle.main.infoDictionary ?? [:])

    static func parse(_ info: [String: Any]) -> Self? {
        guard info["BowserAppVersion"] as? Int == 2,
              let value = info["BowserSavedURL"] as? String, let url = URL(string: value),
              ["http", "https"].contains(url.scheme ?? ""), url.host != nil,
              let id = info["CFBundleIdentifier"] as? String, id.hasPrefix(identifierPrefix),
              let app = info["BowserMainApp"] as? String else { return nil }
        return Self(url: url, profile: info["BowserProfile"] as? String ?? "default",
                    identifier: id, mainApp: URL(fileURLWithPath: app))
    }

    var home: URL {
        BowserPaths.home.appendingPathComponent("site-apps")
            .appendingPathComponent(identifier.replacingOccurrences(of: Self.identifierPrefix, with: ""))
    }
}

/// Each saved app owns this cache for its origin. The periodic check also notices
/// external edits, including writes in place and atomic replacements with the same size.
struct SiteAppModFiles {
    private struct Stamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds, modifiedNanos, changedSeconds, changedNanos: Int

        init?(_ file: URL) {
            var info = stat()
            guard stat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size <= SiteAppModFiles.byteLimit else { return nil }
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanos = info.st_ctimespec.tv_nsec
        }
    }

    private static let byteLimit = 200_000
    private let directory: URL
    private let origin: String
    private var cache: [URL: (stamp: Stamp, script: ModScript?)] = [:]

    init(configuration: SiteAppConfiguration, root: URL) {
        directory = root.appendingPathComponent(configuration.identifier)
        let url = configuration.url
        origin = "\(url.scheme ?? "https")://\(url.host ?? "")" + (url.port.map { ":\($0)" } ?? "")
    }

    mutating func scripts() -> [ModScript] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let candidates = files.filter { ["css", "js"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var next: [URL: (stamp: Stamp, script: ModScript?)] = [:]
        var scripts: [ModScript] = []
        for file in candidates {
            guard let stamp = Stamp(file) else { continue }
            if let entry = cache[file], entry.stamp == stamp {
                next[file] = entry
            } else {
                // Read at most one byte over the limit even if a writer grows the file
                // after stat. Retry transient reads on the next tick.
                guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
                defer { try? handle.close() }
                guard let data = try? handle.read(upToCount: Self.byteLimit + 1) ?? Data(),
                      data.count == stamp.size, Stamp(file) == stamp else { continue }
                next[file] = (stamp, String(data: data, encoding: .utf8).flatMap { script($0, css: file.pathExtension == "css") })
            }
            if let script = next[file]?.script { scripts.append(script) }
        }
        cache = next
        return scripts
    }

    private func script(_ content: String, css: Bool) -> ModScript? {
        if css {
            guard let encoded = try? JSONSerialization.data(withJSONObject: content, options: [.fragmentsAllowed]),
                  let literal = String(data: encoded, encoding: .utf8) else { return nil }
            let body = "const add=()=>{const s=document.createElement('style');s.textContent=\(literal);(document.head||document.documentElement).appendChild(s);};if(document.documentElement)add();else document.addEventListener('DOMContentLoaded',add,{once:true});"
            return ModScript(source: body, world: "isolated", origin: origin)
        }
        guard let world = ModScript.declaredWorld(content) else { return nil }
        return ModScript(source: content, world: world, origin: origin)
    }
}

@MainActor
final class SiteAppRuntime {
    static let shared = SiteAppRuntime()
    private var contentTimer: Timer?
    private var modFiles: SiteAppModFiles?
    private var inheritedScripts: [ModScript] = []
    private var profileScripts: [ModScript] = []
    private var profileStyles: [String] = []
    private var inheritedStyles: [String] = []
    private var appScripts: [ModScript] = []
    var modCount: Int { appScripts.count }
    private var loaded = false
    private var receivedBootstrap = false
    private var seededStorage = false
    private weak var controller: BrowserWindowController?

    func start(_ configuration: SiteAppConfiguration, controller: BrowserWindowController) {
        self.controller = controller
        modFiles = SiteAppModFiles(configuration: configuration, root: BowserPaths.home.appendingPathComponent("app-mods"))
        refreshMods(reload: false)
        contentTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { SiteAppRuntime.shared.refreshMods(reload: true) }
        }
        do {
            try FileManager.default.createDirectory(at: configuration.home, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(configuration).write(to: configuration.home.appendingPathComponent("app.json"), options: .atomic)
        } catch { NSLog("Bowser: site registration failed: %@", error.localizedDescription) }
        // Keep the main browser available to supply this profile's login and
        // mods. Do not activate it or steal focus from the saved app.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.foxwiseai.bowser").isEmpty {
            let options = NSWorkspace.OpenConfiguration()
            options.activates = false
            Task { @MainActor in
                do { _ = try await NSWorkspace.shared.openApplication(at: configuration.mainApp, configuration: options) }
                catch { NSLog("Bowser: main browser startup failed: %@", error.localizedDescription) }
            }
        }
        // The app's own persistent session remains usable if Bowser is down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.loadOnce() }
    }

    func bootstrap(_ message: [String: Any]) {
        guard let controller else { return }
        updateContent(message, reload: false)
        guard !receivedBootstrap else { return }
        receivedBootstrap = true
        loaded = true // reconnect must never navigate the app; a late FIRST bootstrap must apply
        if let storage = message["local_storage"] as? String,
           let script = Self.storageSeedScript(storage, url: SiteAppConfiguration.current?.url) {
            controller.activeTab.webView.configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            seededStorage = true
        }
        let store = controller.activeTab.webView.configuration.websiteDataStore.httpCookieStore
        let cookies = (message["cookies"] as? [[String: String]] ?? []).compactMap(Self.cookie)
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, let configuration = SiteAppConfiguration.current else { return }
            self.controller?.loadURL(configuration.url.absoluteString)
        }
    }

    func updateContent(_ message: [String: Any], reload: Bool) {
        if let profile = message["profile"] as? String {
            guard profile == SiteAppConfiguration.current?.profile else { return }
            if let scripts = ModScript.parseList(message["scripts"]) { profileScripts = scripts }
            if let styles = message["styles"] as? [String] { profileStyles = styles }
            applyContent(reload: reload)
            return
        }
        if let scripts = ModScript.parseList(message["profile_scripts"]) { profileScripts = scripts }
        if let styles = message["profile_styles"] as? [String] { profileStyles = styles }
        if let scripts = ModScript.parseList(message["scripts"]) { inheritedScripts = scripts }
        if let styles = message["styles"] as? [String] { inheritedStyles = styles }
        applyContent(reload: reload)
    }

    private func applyContent(reload: Bool) {
        let scripts = inheritedScripts + profileScripts + appScripts
        let styles = inheritedStyles + profileStyles
        EngineView.rememberUserContent(scripts: scripts, styles: styles)
        for view in EngineView.live.values {
            view.applyUserContent(scripts: scripts, styles: styles, reload: reload)
        }
    }

    private func refreshMods(reload: Bool) {
        guard let scripts = modFiles?.scripts(), scripts != appScripts else { return }
        appScripts = scripts
        applyContent(reload: reload)
    }

    func pageFinished(_ view: EngineView) {
        guard seededStorage, controller?.activeTab === view else { return }
        seededStorage = false
        // Remove the one-time login seed so logging out never resurrects it.
        view.applyUserContent(scripts: nil, styles: nil, reload: false)
    }

    nonisolated static func storageSeedScript(_ storage: String, url: URL?) -> String? {
        guard let url, let host = url.host,
              let data = storage.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: String], !values.isEmpty,
              let json = try? JSONSerialization.data(withJSONObject: ["origin": "\(url.scheme ?? "https")://\(host)" + (url.port.map { ":\($0)" } ?? ""), "values": values]),
              let literal = String(data: json, encoding: .utf8) else { return nil }
        return "(function(){const seed=\(literal); if(location.origin!==seed.origin)return; for(const [k,v] of Object.entries(seed.values)){if(localStorage.getItem(k)===null)localStorage.setItem(k,v);}})();"
    }

    private func loadOnce() {
        guard !loaded, let configuration = SiteAppConfiguration.current else { return }
        loaded = true
        controller?.loadURL(configuration.url.absoluteString)
    }

    nonisolated static func cookie(_ properties: [String: String]) -> HTTPCookie? {
        var values: [HTTPCookiePropertyKey: Any] = [:]
        for (key, value) in properties { values[HTTPCookiePropertyKey(key)] = value }
        if let seconds = properties[HTTPCookiePropertyKey.expires.rawValue].flatMap(Double.init) {
            values[.expires] = Date(timeIntervalSince1970: seconds)
        }
        return HTTPCookie(properties: values)
    }

    nonisolated static func matches(cookieDomain: String, host: String) -> Bool {
        let domain = cookieDomain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let host = host.lowercased()
        return host == domain || host.hasSuffix("." + domain)
    }
}

/// A separate connection per saved app; it never competes with the BEAM
/// connection on the primary brain.sock. Main-browser session events stay
/// private to the primary browser; global page-mod updates reach each app.
@MainActor
final class SiteAppHub {
    static let shared = SiteAppHub()
    private var connections: [String: SiteAppConnection] = [:]
    private var connecting = Set<String>()
    private struct PendingEvaluation {
        let app: String
        let requestID: Int
        let reply: @MainActor ([String: Any]) -> Void
    }
    private var nextEvaluationID = 0
    private var pending: [Int: PendingEvaluation] = [:]
    private var launchObserver: NSObjectProtocol?
    private var retry: Timer?

    func start() {
        guard launchObserver == nil else { return }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, id.hasPrefix(SiteAppConfiguration.identifierPrefix) else { return }
            MainActor.assumeIsolated { self?.scan(launched: id) }
        }
        scan()
    }

    /// A registration and its Unix socket may remain on disk after a saved app
    /// quits. Only a running app can supply the other end of the connection.
    static func registrations(in root: URL, runningIDs: Set<String>, connectedIDs: Set<String>)
        -> (ready: [SiteAppConfiguration], waiting: Bool) {
        var ready: [SiteAppConfiguration] = []
        var waiting = false
        for id in runningIDs.subtracting(connectedIDs) where id.hasPrefix(SiteAppConfiguration.identifierPrefix) {
            let key = String(id.dropFirst(SiteAppConfiguration.identifierPrefix.count))
            guard !key.isEmpty, key != ".", key != "..", !key.contains("/") else { continue }
            let registration = root.appendingPathComponent(key).appendingPathComponent("app.json")
            guard let data = try? Data(contentsOf: registration),
                  let config = try? JSONDecoder().decode(SiteAppConfiguration.self, from: data),
                  config.identifier == id else {
                waiting = true
                continue
            }
            ready.append(config)
        }
        return (ready, waiting)
    }

    private func scheduleRetry() {
        guard retry == nil else { return }
        retry = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
    }

    private func scan(launched: String? = nil) {
        retry?.invalidate()
        retry = nil
        var running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if let launched { running.insert(launched) }
        let root = BowserPaths.home.appendingPathComponent("site-apps")
        let registrations = Self.registrations(in: root, runningIDs: running, connectedIDs: Set(connections.keys).union(connecting))
        if registrations.waiting { scheduleRetry() }
        for config in registrations.ready {
            let key = config.identifier
            connecting.insert(key)
            SiteAppConnection.connect(path: config.home.appendingPathComponent("brain.sock").path) { connection in
                self.connecting.remove(key)
                guard let connection else { self.scheduleRetry(); return }
                self.connections[key] = connection
                connection.onMessage = { [weak connection] message in
                    guard let connection else { return }
                    switch message["op"] as? String {
                    case "hello":
                        self.bootstrap(connection, configuration: config)
                        connection.send(["op": "request_icons"])
                    case "event" where message["event"] as? String == "icon_candidates":
                        var forwarded = message
                        forwarded["app"] = config.identifier
                        forwarded["profile"] = config.profile
                        BrainBridge.shared.send(forwarded)
                    case "event" where message["event"] as? String == "modsmith":
                        guard BrainBridge.shared.isConnected else {
                            connection.send(["op": "site_mod_status", "text": "Bowser is reconnecting. Your draft is kept; try again shortly."])
                            return
                        }
                        var forwarded = message
                        forwarded["app"] = ["id": config.identifier, "url": config.url.absoluteString, "profile": config.profile]
                        BrainBridge.shared.send(forwarded)
                    case "event" where message["event"] as? String == "site_mod_request":
                        guard let request = message["request"] as? String else { return }
                        guard BrainBridge.shared.isConnected else {
                            connection.send(["op": "site_mod_status", "text": "Bowser is reconnecting. Try again shortly."])
                            return
                        }
                        BrainBridge.shared.send(["op": "event", "event": "site_mod_request", "request": request,
                            "app": ["id": config.identifier, "url": config.url.absoluteString, "profile": config.profile]])
                    case "js_result":
                        guard let id = message["id"] as? Int, self.pending[id]?.app == key,
                              let request = self.pending.removeValue(forKey: id) else { return }
                        var response = message
                        response["id"] = request.requestID
                        request.reply(response)
                    default: break
                    }
                }
                connection.onClose = {
                    self.connections.removeValue(forKey: key)
                    self.scheduleRetry()
                    for id in self.pending.filter({ $0.value.app == key }).map(\.key) {
                        self.finishEval(id, error: "Saved app disconnected")
                    }
                }
                connection.startReading()
            }
        }
    }

    nonisolated static let storageExportScript = "return JSON.stringify(Object.fromEntries(Object.keys(localStorage).map(k => [k,localStorage.getItem(k)])))"

    private func bootstrap(_ connection: SiteAppConnection, configuration: SiteAppConfiguration) {
        let profile = Profile.find(configuration.profile)
        profile.dataStore.httpCookieStore.getAllCookies { cookies in
            MainActor.assumeIsolated {
                let selected = cookies.filter { SiteAppRuntime.matches(cookieDomain: $0.domain, host: configuration.url.host ?? "") }
                let properties: [[String: String]] = selected.map { cookie in
                    var result: [String: String] = [:]
                    for (key, value) in cookie.properties ?? [:] {
                        if let date = value as? Date { result[key.rawValue] = String(date.timeIntervalSince1970) }
                        else { result[key.rawValue] = String(describing: value) }
                    }
                    return result
                }
                let send: (String?) -> Void = { storage in
                    connection.send(["op": "site_bootstrap", "cookies": properties,
                                     "scripts": EngineView.sharedScripts.map(\.wire), "styles": EngineView.sharedStyles,
                                     "profile_scripts": Array(EngineView.content(for: profile.id).scripts.dropFirst(EngineView.sharedScripts.count)).map(\.wire),
                                     "profile_styles": Array(EngineView.content(for: profile.id).styles.dropFirst(EngineView.sharedStyles.count)),
                                     "local_storage": storage ?? "{}"])
                }
                if let source = EngineView.live.values.first(where: {
                    $0.profileId == profile.id && $0.webView.url?.host == configuration.url.host
                        && $0.webView.url?.scheme == configuration.url.scheme && $0.webView.url?.port == configuration.url.port
                }) {
                    // Sites such as Discord delete the page world's storage
                    // accessor. The isolated world still has the native one.
                    source.webView.callAsyncJavaScript(Self.storageExportScript, arguments: [:], in: nil, in: .defaultClient) { result in
                        switch result {
                        case .success(let value): send(value as? String)
                        case .failure(let error):
                            NSLog("Bowser: site login storage export failed: %@", error.localizedDescription)
                            send(nil)
                        }
                    }
                } else { send(nil) }
            }
        }
    }

    private func finishEval(_ id: Int, error: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.reply(["op": "js_result", "id": request.requestID, "ok": false, "value": error])
    }

    func route(_ message: [String: Any], reply: @escaping @MainActor ([String: Any]) -> Void) {
        guard let key = message["app"] as? String, let connection = connections[key] else {
            if ["site_eval", "site_screenshot"].contains(message["op"] as? String ?? ""), let id = message["id"] as? Int {
                reply(["op": "js_result", "id": id, "ok": false, "value": "Saved app is not running"])
            }
            return
        }
        if message["op"] as? String == "modsmith_state" {
            connection.send(message)
        } else if ["site_eval", "site_screenshot"].contains(message["op"] as? String ?? ""), let requestID = message["id"] as? Int {
            nextEvaluationID += 1
            let id = nextEvaluationID
            pending[id] = PendingEvaluation(app: key, requestID: requestID, reply: reply)
            if message["op"] as? String == "site_screenshot" {
                connection.send(["op": "page_screenshot", "webview": 0, "id": id, "max_width": message["max_width"] ?? 1280])
            } else {
                connection.send(["op": "eval_js", "webview": 0, "id": id, "code": message["code"] ?? ""])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.finishEval(id, error: "Saved app evaluation timed out") }
        } else {
            connection.send(["op": "site_mod_status", "text": message["text"] ?? ""])
        }
    }

    func requestIcons() {
        for connection in connections.values { connection.send(["op": "request_icons"]) }
    }

    func routeIcon(_ message: [String: Any]) {
        guard let key = message["app"] as? String else { return }
        connections[key]?.send(message)
    }

    func broadcastContent(_ message: [String: Any]) {
        for connection in connections.values { connection.send(message) }
    }
}

/// Each saved app owns a separate reader and a bounded, ordered writer.
final class SiteAppConnection: @unchecked Sendable {
    private let fd: Int32
    private let writer: SocketFrameWriter
    @MainActor var onMessage: (([String: Any]) -> Void)?
    @MainActor var onClose: (() -> Void)?
    private init(fd: Int32) {
        self.fd = fd
        writer = SocketFrameWriter(fd: fd)
    }

    nonisolated static func connect(path: String, completion: @escaping @MainActor @Sendable (SiteAppConnection?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard fd >= 0, path.utf8.count < capacity else {
                if fd >= 0 { close(fd) }
                DispatchQueue.main.async { completion(nil) }; return
            }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { target in
                    path.withCString { source in _ = strcpy(target, source) }
                }
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { close(fd); DispatchQueue.main.async { completion(nil) }; return }
            let connection = SiteAppConnection(fd: fd)
            DispatchQueue.main.async { completion(connection) }
        }
    }

    @MainActor func send(_ message: [String: Any]) {
        guard writer.isOpen else { return }
        do {
            try writer.sendJSON(message)
        } catch {
            NSLog("Bowser: could not send saved-app message: %@", String(describing: error))
        }
    }

    nonisolated func startReading() {
        DispatchQueue.global(qos: .utility).async {
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(self.fd, &chunk, chunk.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                buffer.append(contentsOf: chunk.prefix(n))
                while buffer.count >= 4 {
                    let count = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                    guard count <= SocketFrameWriter.maximumPayloadBytes else { self.finish(); return }
                    if buffer.count < count + 4 { break }
                    let data = buffer.subdata(in: 4..<(count + 4))
                    buffer.removeSubrange(0..<(count + 4))
                    DispatchQueue.main.async {
                        if let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            self.onMessage?(message)
                        }
                    }
                }
            }
            self.finish()
        }
    }

    nonisolated func disconnect() {
        writer.close()
    }

    private func finish() {
        writer.finishReading()
        DispatchQueue.main.async {
            self.onClose?()
            self.onMessage = nil
            self.onClose = nil
        }
    }
}
