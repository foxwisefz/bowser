import AppKit
import CryptoKit

struct UpdateRelease: Codable, Equatable, Sendable {
    let version: String
    let build: String
    let minimumMacOS: Int
    let url: URL
    let bytes: Int64
    let sha256: String
    let expiresAt: Date

    static func verified(_ data: Data, publicKey: Data, currentBuild: String, osMajor: Int,
                         now: Date = Date()) throws -> Self? {
        struct Envelope: Decodable { let payload: Data; let signature: Data }
        guard data.count <= 16384 else { throw UpdateError.invalidRelease }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard key.isValidSignature(envelope.signature, for: envelope.payload) else { throw UpdateError.invalidRelease }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(Self.self, from: envelope.payload)
        guard let build = UInt64(release.build), let current = UInt64(currentBuild),
              release.version.count <= 64, !release.version.isEmpty,
              release.minimumMacOS >= 15, release.minimumMacOS <= osMajor,
              release.bytes > 0, release.bytes <= 1_073_741_824,
              release.url.scheme == "https", release.url.host == "assets.bowser.app", release.url.port == nil,
              release.url.user == nil, release.url.password == nil,
              release.url.absoluteString == "https://assets.bowser.app/releases/\(release.build)/Bowser.dmg",
              release.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              release.expiresAt > now else { throw UpdateError.invalidRelease }
        return build > current ? release : nil
    }
    func verifyFile(_ file: URL) throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == Int(bytes) else { throw UpdateError.invalidRelease }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else { throw UpdateError.invalidRelease }
    }
}

enum UpdateError: Error { case invalidRelease, unavailable, commandFailed }

final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let limit: Int64
    init(limit: Int64) { self.limit = limit }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

/// All file/process work runs off the UI thread. Only a signed, hash-checked
/// image is mounted. The existing installer owns atomic publish and activation.
enum UpdateInstaller {
    static func run(_ executable: String, _ args: [String], allowFailure: Bool = false) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        if process.terminationStatus != 0 && !allowFailure { throw UpdateError.commandFailed }
    }
    /// Publishing does not load code. Each running host independently checks
    /// Team ID, ABI, dependencies and its module budget before swapping views.
    static func publishModules(from app: URL, home: URL,
                               verify: (URL) throws -> Void = { try run("/usr/bin/codesign", ["--verify", "--strict", $0.path]) }) throws {
        let fm = FileManager.default
        for (name, kind, identifier) in [
            ("SurfaceRenderer", "surfaces", "com.foxwiseai.bowser.surfaces"),
            ("CommandToolbar", "command-toolbar", "com.foxwiseai.bowser.command-toolbar")
        ] {
            let source = app.appendingPathComponent("Contents/Resources/\(name).bundle")
            let info = try Data(contentsOf: source.appendingPathComponent("Contents/Info.plist"))
            guard let metadata = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
                  metadata["CFBundleIdentifier"] as? String == identifier,
                  let build = metadata["CFBundleVersion"] as? String,
                  build.count == 32, build.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw UpdateError.invalidRelease }
            try verify(source)
            let root = home.appendingPathComponent("native-modules/" + kind)
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let target = root.appendingPathComponent(build + ".bundle")
            if !fm.fileExists(atPath: target.path) {
                let temporary = root.appendingPathComponent("stage-" + UUID().uuidString)
                defer { try? fm.removeItem(at: temporary) }
                try fm.copyItem(at: source, to: temporary)
                try verify(temporary)
                try fm.moveItem(at: temporary, to: target)
            } else {
                try verify(target)
            }
            try Data((build + "\n").utf8).write(to: root.appendingPathComponent("current"), options: .atomic)
        }
    }
    static func stage(_ image: URL, release: UpdateRelease, home: URL, bundle: URL) throws {
        try release.verifyFile(image)
        let fm = FileManager.default, root = home.appendingPathComponent("updates")
        guard fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else { throw UpdateError.unavailable }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent("download-" + UUID().uuidString)
        let mount = fm.temporaryDirectory.appendingPathComponent("bowser-update-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)
        var published = false
        defer {
            try? run("/usr/bin/hdiutil", ["detach", mount.path], allowFailure: true)
            try? fm.removeItem(at: mount)
            if !published { try? fm.removeItem(at: stage) }
        }
        try run("/usr/bin/hdiutil", ["attach", image.path, "-readonly", "-nobrowse", "-mountpoint", mount.path])
        let app = mount.appendingPathComponent("Bowser.app"), runtime = app.appendingPathComponent("Contents/Resources/runtime")
        guard let installed = Bundle(url: app), installed.bundleIdentifier == "com.foxwiseai.bowser",
              installed.infoDictionary?["CFBundleVersion"] as? String == release.build,
              installed.infoDictionary?["CFBundleShortVersionString"] as? String == release.version else { throw UpdateError.invalidRelease }
        for file in ["bin/bowser", "bin/apply-update", "bin/backend-host", "brain/bin/bowser_brain"] {
            guard fm.isExecutableFile(atPath: runtime.appendingPathComponent(file).path) else { throw UpdateError.invalidRelease }
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        try run("/usr/bin/ditto", [app.path, stage.appendingPathComponent("bundle").path])
        try run("/usr/bin/ditto", [runtime.path, stage.appendingPathComponent("runtime").path])
        // Invoke the helper under its dispatch name; watcher uses apply-update.
        let helper = stage.appendingPathComponent("BowserRuntimeTool")
        try fm.copyItem(at: runtime.appendingPathComponent("bin/apply-update"), to: helper)
        let pending = root.appendingPathComponent("pending.json")
        let live = installed.infoDictionary?["BowserLiveUpdates"] as? Int == 1
            && ProcessInfo.processInfo.environment["BOWSER_OFFLINE_UPDATE"] != "1"
            && Bundle(url: bundle)?.infoDictionary?["BowserChannel"] as? String != "staging"
        try run(helper.path, ["publish", pending.path, stage.path, home.appendingPathComponent("app").path, bundle.path, "0", "0"] + (live ? ["--live"] : []))
        published = true
        let next = root.appendingPathComponent("apply-update.new"), watcher = root.appendingPathComponent("apply-update")
        try? fm.removeItem(at: next)
        try fm.copyItem(at: helper, to: next)
        // rename(2) atomically replaces an existing watcher executable.
        guard rename(next.path, watcher.path) == 0 else { throw UpdateError.commandFailed }
        let agents = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist = agents.appendingPathComponent("com.foxwiseai.bowser.pending-update.plist")
        // Retire watcher jobs installed under previous bundle-identifier
        // prefixes; two agents racing one pending.json spawn duplicate watchers.
        for legacy in (try? fm.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil)) ?? [] {
            let name = legacy.lastPathComponent
            guard name.hasSuffix(".bowser.pending-update.plist"), name != plist.lastPathComponent else { continue }
            try run("/bin/launchctl", ["bootout", "gui/\(getuid())/" + name.dropLast(".plist".count)], allowFailure: true)
            try? fm.removeItem(at: legacy)
        }
        try run(helper.path, ["watcher-plist", plist.path, root.path])
        try run(watcher.path, [pending.path, "--refresh-watcher"])
        let domain = "gui/\(getuid())", label = domain + "/com.foxwiseai.bowser.pending-update"
        try run("/bin/launchctl", ["bootout", label], allowFailure: true)
        try run("/bin/launchctl", ["bootstrap", domain, plist.path])
        try run("/bin/launchctl", ["kickstart", label])
        if live {
            // Failure leaves the full release staged for restart; each host
            // independently admits and health-checks published generations.
            do { try publishModules(from: stage.appendingPathComponent("bundle"), home: home) }
            catch { NSLog("Live module publication deferred: %@", String(describing: error)) }
        }
    }
    static func download(_ release: UpdateRelease) async throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: UpdateDownloadDelegate(limit: release.bytes), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: release.url); request.timeoutInterval = 300
        let (temporary, response) = try await session.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.unavailable }
        let image = FileManager.default.temporaryDirectory.appendingPathComponent("bowser-" + UUID().uuidString + ".dmg")
        try FileManager.default.moveItem(at: temporary, to: image)
        do { try release.verifyFile(image); return image }
        catch { try? FileManager.default.removeItem(at: image); throw error }
    }
}

enum PreparedUpdateStatus: Equatable {
    case applying, live, restart

    static func evaluate(liveAllowed: Bool, runningHost: String?, incomingHost: String?,
                         backendApplied: Bool, modulesApplied: Bool, age: TimeInterval) -> Self {
        guard liveAllowed else { return .restart }
        let sameHost = runningHost.map { identity in
            identity.count == 64 && identity.allSatisfy { "0123456789abcdef".contains($0) } && identity == incomingHost
        } ?? false
        if sameHost && backendApplied && modulesApplied { return .live }
        // Let the watcher and idle renderer slots settle before offering restart.
        return age < 60 ? .applying : .restart
    }
}

@MainActor
final class AppUpdates: NSObject {
    static let shared = AppUpdates()
    private var busy = false
    private var timer: Timer?
    private var developmentBuild: Process?
    private var readyTimer: Timer?
    private var offeredStage: String?
    private var restartHelper: Process?
    private let runningHostIdentity = Bundle.main.infoDictionary?["BowserHostIdentity"] as? String
    private var noticedLiveStage: String?
    private var noticePanel: NSPanel?
    private var noticeTimer: Timer?

    private func preparedStatus(_ manifest: [String: Any], stage: String) -> PreparedUpdateStatus {
        guard manifest["live_allowed"] as? Bool == true else { return .restart }
        let app = URL(fileURLWithPath: stage).appendingPathComponent("bundle")
        let info = Bundle(url: app)?.infoDictionary
        var modulesApplied = true
        for (name, runtime) in [("SurfaceRenderer", NativeModuleRuntime.surfaces), ("CommandToolbar", NativeModuleRuntime.toolbar)] {
            let module = Bundle(url: app.appendingPathComponent("Contents/Resources/" + name + ".bundle"))
            if let build = module?.infoDictionary?["CFBundleVersion"] as? String {
                if !runtime.hasApplied(build: build) { modulesApplied = false }
            } else { modulesApplied = false }
        }
        let pointer = BowserPaths.home.appendingPathComponent("backend/active.json")
        let active = (try? Data(contentsOf: pointer)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let liveRuntime = manifest["live_runtime"] as? String
        return PreparedUpdateStatus.evaluate(liveAllowed: manifest["live_allowed"] as? Bool == true,
            runningHost: runningHostIdentity, incomingHost: info?["BowserHostIdentity"] as? String,
            backendApplied: manifest["backend_applied"] as? Bool == true && liveRuntime != nil && active?["runtime"] as? String == liveRuntime,
            modulesApplied: modulesApplied,
            age: Date().timeIntervalSince1970 - (manifest["published_at"] as? Double ?? 0))
    }

    private func showLiveNotice() {
        guard NSApp.isActive, let window = NSApp.mainWindow, let screen = window.screen else { return }
        noticeTimer?.invalidate()
        if let previous = noticePanel { previous.parent?.removeChildWindow(previous); previous.orderOut(nil) }
        let frame = NSRect(x: screen.visibleFrame.maxX - 290, y: screen.visibleFrame.minY + 24, width: 266, height: 64)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.ignoresMouseEvents = true
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        background.material = .hudWindow; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 16
        let label = NSTextField(labelWithString: "✓  Bowser updated")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.frame = NSRect(x: 24, y: 22, width: 220, height: 22)
        background.addSubview(label); panel.contentView = background
        window.addChildWindow(panel, ordered: .above); panel.orderFront(nil); noticePanel = panel
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { _ in
            MainActor.assumeIsolated {
                window.removeChildWindow(panel); panel.orderOut(nil)
                self.noticePanel = nil; self.noticeTimer = nil
            }
        }
    }

    @discardableResult private func offerPreparedUpdate(manual: Bool) -> Bool {
        guard SiteAppConfiguration.current == nil else { return false }
        let pending = BowserPaths.home.appendingPathComponent("updates/pending.json")
        guard let data = try? Data(contentsOf: pending),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let target = manifest["bundle"] as? String,
              URL(fileURLWithPath: target).resolvingSymlinksInPath() == Bundle.main.bundleURL.resolvingSymlinksInPath(),
              let stage = manifest["stage"] as? String else { return false }
        if let helper = restartHelper, helper.isRunning {
            if manual {
                NSRunningApplication(processIdentifier: helper.processIdentifier)?.activate(options: [.activateIgnoringOtherApps])
                message("An update is already in progress. The updater will reopen Bowser when it finishes.")
            }
            return true
        }
        let status = preparedStatus(manifest, stage: stage)
        if status == .applying {
            if manual { message("The update is being applied. You can keep browsing; any remaining changes will be ready on restart.") }
            return true
        }
        if status == .live {
            if manual { message("Bowser is up to date. This update was applied without restarting.") }
            else if noticedLiveStage != stage, NSApp.isActive { showLiveNotice(); noticedLiveStage = stage }
            return true
        }
        guard manual || offeredStage != stage else { return true }
        guard manual || (NSApp.isActive && NSApp.modalWindow == nil && NSEvent.pressedMouseButtons == 0) else { return true }
        offeredStage = stage
        let alert = NSAlert()
        let live = manifest["live_allowed"] as? Bool == true
        alert.messageText = live ? "Restart to finish updating" : "Update ready"
        alert.informativeText = live
            ? "Some changes need a restart. You can keep browsing and finish the update later. Your tabs will reopen automatically."
            : "Restart Bowser to install the prepared update. Your tabs will reopen automatically."
        alert.addButton(withTitle: "Update & Restart")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return true }
        do {
            let helper = Process()
            helper.executableURL = BowserPaths.home.appendingPathComponent("updates/apply-update")
            helper.arguments = [pending.path, "--restart-ui"]
            helper.standardInput = FileHandle.nullDevice
            let log = BowserPaths.home.appendingPathComponent("updates/restart.log")
            if !FileManager.default.fileExists(atPath: log.path) {
                FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let output = try FileHandle(forWritingTo: log)
            try output.seekToEnd()
            helper.standardOutput = output
            helper.standardError = output
            helper.terminationHandler = { process in
                try? output.close()
                Task { @MainActor in
                    self.restartHelper = nil
                    if process.terminationStatus != 0 {
                        self.offeredStage = nil
                        self.message("The updater couldn’t start. Your browser is still open. Try again; details are saved in " + log.path)
                    }
                }
            }
            try helper.run()
            restartHelper = helper
            offeredStage = stage
        } catch {
            offeredStage = nil
            message("Couldn’t open the updater: " + error.localizedDescription)
        }
        return true
    }
    func start() {
        if readyTimer == nil {
            readyTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                MainActor.assumeIsolated { _ = AppUpdates.shared.offerPreparedUpdate(manual: false) }
            }
        }
        _ = offerPreparedUpdate(manual: false)
        guard Bundle.main.infoDictionary?["BowserChannel"] as? String != "staging" else { return }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
                Task { @MainActor in AppUpdates.shared.start() }
            }
        }
        guard SiteAppConfiguration.current == nil,
              Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: "lastUpdateCheck") > 86400 else { return }
        Task { await check(manual: false) }
    }
    nonisolated static func latestBuild(_ installed: String, _ prepared: String?) -> String {
        guard let prepared, let value = UInt64(prepared), value > (UInt64(installed) ?? 0) else { return installed }
        return prepared
    }
    @objc func checkForUpdates(_ sender: Any? = nil) { Task { await check(manual: true) } }
    private func message(_ text: String) { NativeUIHost.alert("message", ["text": text]).runModal() }
    nonisolated static func developmentFingerprint(checkout: String) async throws -> String {
        try await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: checkout + "/bin/development-fingerprint")
            process.currentDirectoryURL = URL(fileURLWithPath: checkout)
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let fingerprint = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0,
                  fingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw UpdateError.unavailable
            }
            return fingerprint
        }.value
    }
    private func updateFromDevelopment() async {
        guard developmentBuild?.isRunning != true else { message("A staging build is already in progress."); return }
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard let checkout = Bundle.main.infoDictionary?["BowserDevelopmentCheckout"] as? String,
              FileManager.default.isExecutableFile(atPath: checkout + "/bin/install") else {
            message("The development checkout is unavailable. Run bin/staging update from your Bowser checkout."); return
        }
        let log = BowserPaths.home.appendingPathComponent("updates/staging-build.log")
        do {
            let fingerprint = try await Self.developmentFingerprint(checkout: checkout)
            if fingerprint == Bundle.main.infoDictionary?["BowserDevelopmentFingerprint"] as? String {
                message("You’re up to date. Staging matches your development checkout.")
                return
            }
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: checkout + "/bin/install")
            process.arguments = ["--staging"]
            process.currentDirectoryURL = URL(fileURLWithPath: checkout)
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["BOWSER_HOME"] = BowserPaths.home.path
            env["BOWSER_APP_DIR"] = BowserPaths.home.appendingPathComponent("staging-runtime").path
            env["BOWSER_BUNDLE_PATH"] = Bundle.main.bundleURL.path
            process.environment = env
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output; process.standardError = output
            process.terminationHandler = { process in
                try? output.close()
                Task { @MainActor in
                    if process.terminationStatus == 0 { _ = self.offerPreparedUpdate(manual: true) }
                    else { self.message("Couldn’t finish preparing the staging update. See " + log.path) }
                }
            }
            try process.run()
            developmentBuild = process
            message("Preparing a staging update. You can keep browsing; Bowser will let you know when it’s ready to restart.")
        } catch { message("Couldn’t start the staging build: " + error.localizedDescription) }
    }
    func check(manual: Bool) async {
        // A staged generation must not prevent discovery of a newer release.
        // This matters especially when a fully live update stays staged for days.
        if restartHelper?.isRunning == true { _ = offerPreparedUpdate(manual: manual); return }
        if Bundle.main.infoDictionary?["BowserChannel"] as? String == "staging" {
            if offerPreparedUpdate(manual: manual) { return }
            if manual { await updateFromDevelopment() }
            return
        }
        guard !busy else { if manual { message("An update check is already in progress.") }; return }
        guard let encoded = Bundle.main.infoDictionary?["BowserUpdatePublicKey"] as? String,
              let key = Data(base64Encoded: encoded), key.count == 32,
              let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else {
            if manual, !offerPreparedUpdate(manual: true) { message("Updates are not available for this build yet.") }; return
        }
        busy = true; defer { busy = false }
        do {
            var request = URLRequest(url: URL(string: "https://assets.bowser.app/updates/stable.json")!); request.timeoutInterval = 20
            let (data, response) = try await PrivateHTTP.send(request)
            guard response.statusCode == 200 else { throw UpdateError.unavailable }
            let pendingData = try? Data(contentsOf: BowserPaths.home.appendingPathComponent("updates/pending.json"))
            let pending = pendingData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let sameTarget = (pending?["bundle"] as? String).map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath() == Bundle.main.bundleURL.resolvingSymlinksInPath()
            } == true
            let preparedBuild = (sameTarget ? pending?["stage"] as? String : nil).flatMap {
                Bundle(url: URL(fileURLWithPath: $0).appendingPathComponent("bundle"))?.infoDictionary?["CFBundleVersion"] as? String
            }
            let release = try UpdateRelease.verified(data, publicKey: key, currentBuild: Self.latestBuild(build, preparedBuild),
                osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
            guard let release else {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                if manual {
                    if !offerPreparedUpdate(manual: true) { message("You’re up to date.") }
                }
                return
            }
            let home = BowserPaths.home, bundle = Bundle.main.bundleURL
            try await Task.detached {
                let image = try await UpdateInstaller.download(release)
                defer { try? FileManager.default.removeItem(at: image) }
                try UpdateInstaller.stage(image, release: release, home: home, bundle: bundle)
            }.value
            UserDefaults.standard.set(release.build, forKey: "preparedUpdateBuild")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
            _ = offerPreparedUpdate(manual: manual)
        } catch {
            if manual, !offerPreparedUpdate(manual: true) { message("Couldn’t prepare the update. Please try again later.") }
        }
    }
}
