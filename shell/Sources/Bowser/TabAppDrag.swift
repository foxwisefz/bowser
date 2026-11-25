import AppKit
import CryptoKit
import Darwin
import Synchronization

enum TabAppBundle {
    static let installed = SavedAppRegistry(
        directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Bowser Apps"),
        bowser: Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL :
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Bowser.app"),
        icons: BowserPaths.home.appendingPathComponent("app-icons-v2"))

    @MainActor static func upgradeSavedApps(_ scope: SavedAppRegistry.Scope = .all) {
        // Only an installed browser manages the user's saved launchers. XCTest
        // and release probes also run this shell with their own bundle identity.
        guard Bundle.main.bundleIdentifier == "com.foxwiseai.bowser", SiteAppConfiguration.current == nil else { return }
        installed.request(scope)
    }

    static func iconKey(url: URL, profile: String) -> String {
        let scheme = url.scheme ?? "https"
        let defaultPort = scheme == "https" ? 443 : 80
        let port = url.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        let origin = "\(scheme)://\(url.host ?? "")" + port
        return digest(Data((profile + "\n" + origin).utf8))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The queue owns the refresh index. A filesystem lock per launcher also
/// coordinates explicit drag exports from other Bowser processes.
final class SavedAppRegistry: @unchecked Sendable {
    enum Scope: Hashable { case all, icon(String), bundle(URL) }
    typealias Signer = @Sendable (URL) throws -> Void
    let directory: URL
    private let bowser: URL
    private let icons: URL
    private let sign: Signer
    private let isRunning: @Sendable (String) -> Bool
    private let inspect: @Sendable (URL) -> Void
    private let queue = DispatchQueue(label: "bowser.saved-app-refresh", qos: .utility)
    private var pending = Set<Scope>()
    private var keysByBundle = [URL: String]()
    private var directoryStamp: timespec?

    init(directory: URL, bowser: URL, icons: URL, sign: @escaping Signer = signBundle,
         isRunning: @escaping @Sendable (String) -> Bool = { id in
             NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { !$0.isTerminated }
         }, inspect: @escaping @Sendable (URL) -> Void = { _ in }) {
        self.directory = directory.standardizedFileURL
        self.bowser = bowser
        self.icons = icons
        self.sign = sign
        self.isRunning = isRunning
        self.inspect = inspect
    }

    func request(_ scope: Scope) {
        queue.async {
            let first = self.pending.isEmpty
            self.pending.insert(scope)
            if first {
                self.queue.asyncAfter(deadline: .now() + .milliseconds(50)) { self.refreshPending() }
            }
        }
    }

    /// Drains pending notifications, including those in the coalescing window.
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { self.refreshPending(); continuation.resume() }
        }
    }

    private func refreshPending() {
        let scopes = pending
        pending.removeAll()
        guard !scopes.isEmpty else { return }
        let all = scopes.contains(.all)
        let keys = Set(scopes.compactMap { if case .icon(let key) = $0 { return key }; return nil })
        var targets = Set(scopes.compactMap { if case .bundle(let url) = $0 { return url.standardizedFileURL }; return nil })
        if all || !keys.isEmpty {
            var attrs = stat()
            guard stat(directory.path, &attrs) == 0 else { directoryStamp = nil; keysByBundle.removeAll(); return }
            let stamp = attrs.st_mtimespec
            if all || directoryStamp?.tv_sec != stamp.tv_sec || directoryStamp?.tv_nsec != stamp.tv_nsec {
                do {
                    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                    let bundles = Set(files.filter { $0.pathExtension == "app" }.map(\.standardizedFileURL))
                    keysByBundle = keysByBundle.filter { bundles.contains($0.key) }
                    for bundle in bundles where all || keysByBundle[bundle] == nil {
                        if all { targets.insert(bundle) }
                        else if let info = try? readInfo(bundle), let key = iconKey(info) { keysByBundle[bundle] = key }
                    }
                    directoryStamp = stamp
                } catch { NSLog("Bowser: cannot list saved apps: %@", error.localizedDescription) }
            }
            for (bundle, key) in keysByBundle where keys.contains(key) { targets.insert(bundle) }
        }
        for bundle in targets where bundle.deletingLastPathComponent().path == directory.path && bundle.pathExtension == "app" {
            do { try upgrade(bundle) }
            catch { NSLog("Bowser: site app upgrade failed: %@", error.localizedDescription) }
        }
    }

    // The Dock requests a file URL synchronously and only on demand. Return an
    // existing, fully signed app immediately, including during a staged update.
    func export(url: URL, profile: String, icon: URL? = nil) throws -> URL {
        let bundle = try destination(url: url, profile: profile)
        if FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path) {
            request(.bundle(bundle))
            return bundle
        }
        // A first export must materialize before the pasteboard callback returns.
        // It has its own worker so it never waits behind unrelated maintenance.
        let result = Mutex<Result<URL, Error>?>(nil)
        let work = DispatchWorkItem {
            let created = Result {
                try self.create(url: url, profile: profile, iconData: icon.flatMap { try? Data(contentsOf: $0) })
            }
            result.withLock { $0 = created }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
        work.wait()
        return try result.withLock { try $0!.get() }
    }

    private func destination(url: URL, profile: String) throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let key = TabAppBundle.digest(Data((profile + "\n" + url.absoluteString).utf8)).prefix(16)
        return directory.appendingPathComponent("\(host.replacingOccurrences(of: "/", with: "_"))-\(key).app", isDirectory: true)
    }

    func create(url: URL, profile: String, iconData: Data?) throws -> URL {
        let bundle = try destination(url: url, profile: profile)
        try withLock(bundle) {
            if FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path) { return }
            let staging = stagingBundle()
            defer { try? FileManager.default.removeItem(at: staging) }
            let id = TabAppBundle.digest(Data((profile + "\n" + url.absoluteString).utf8)).prefix(16)
            var info: [String: Any] = [
                "CFBundleName": url.host!, "CFBundleDisplayName": url.host!,
                "CFBundleIdentifier": "com.foxwiseai.bowser.site.\(id)",
                "CFBundleExecutable": "launch", "CFBundlePackageType": "APPL",
                "CFBundleIconFile": "SiteIcon.icns", "BowserSavedURL": url.absoluteString, "BowserProfile": profile
            ]
            try installEngine(in: staging, build: engineBuild(), info: &info)
            let key = TabAppBundle.iconKey(url: url, profile: profile)
            if let data = iconData ?? cachedIcon(key) { try installIcon(data, in: staging, info: &info) }
            try finishStaging(staging, info: info)
            try FileManager.default.moveItem(at: staging, to: bundle)
        }
        return bundle
    }

    private func stagingBundle() -> URL {
        directory.appendingPathComponent(".\(UUID().uuidString).app", isDirectory: true)
    }

    private func readInfo(_ bundle: URL) throws -> [String: Any]? {
        inspect(bundle)
        let data = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              (info["CFBundleIdentifier"] as? String)?.hasPrefix("com.foxwiseai.bowser.site.") == true,
              info["BowserSavedURL"] is String else { return nil }
        return info
    }

    private func iconKey(_ info: [String: Any]) -> String? {
        guard let url = (info["BowserSavedURL"] as? String).flatMap(URL.init(string:)) else { return nil }
        return TabAppBundle.iconKey(url: url, profile: info["BowserProfile"] as? String ?? "default")
    }

    private func cachedIcon(_ key: String) -> Data? { try? Data(contentsOf: icons.appendingPathComponent(key + ".icns")) }

    private func upgrade(_ bundle: URL) throws {
        try withLock(bundle) {
            guard var info = try readInfo(bundle), let id = info["CFBundleIdentifier"] as? String, let key = iconKey(info) else {
                keysByBundle.removeValue(forKey: bundle)
                return
            }
            keysByBundle[bundle] = key
            let build = try engineBuild()
            let engineChanged = info["BowserAppVersion"] as? Int != 2 || info["BowserEngineBuild"] as? String != build
            let icon = cachedIcon(key)
            let iconHash = icon.map(TabAppBundle.digest)
            let iconChanged = iconHash != nil && info["BowserIconHash"] as? String != iconHash
            guard engineChanged || iconChanged, !isRunning(id) else { return }
            // Follow only real bundle directories. A copied symlink would
            // point staging back at a live app while its contents are edited.
            for child in ["", "Contents", "Contents/MacOS", "Contents/Resources", "Contents/Frameworks"] {
                var attrs = stat()
                let path = child.isEmpty ? bundle.path : bundle.appendingPathComponent(child).path
                if lstat(path, &attrs) == 0, attrs.st_mode & S_IFMT != S_IFDIR { return }
            }
            let staging = stagingBundle()
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: bundle, to: staging)
            if engineChanged { try installEngine(in: staging, build: build, info: &info) }
            if iconChanged, let icon { try installIcon(icon, in: staging, info: &info, hash: iconHash) }
            try finishStaging(staging, info: info)
            // A launch may have occurred while codesign was running. The old
            // executable is never overwritten; Dock bookmarks retain the outer inode.
            guard !isRunning(id) else { return }
            let live = bundle.appendingPathComponent("Contents").path
            let ready = staging.appendingPathComponent("Contents").path
            guard renamex_np(ready, live, UInt32(RENAME_SWAP)) == 0 else { throw Self.posixError() }
        }
    }

    private func withLock(_ bundle: URL, _ body: () throws -> Void) throws {
        let locks = directory.appendingPathComponent(".locks")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let file = locks.appendingPathComponent(bundle.lastPathComponent + ".lock")
        let fd = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.posixError() }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { throw Self.posixError() }
        }
        try body()
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private func engineBuild() throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: bowser.appendingPathComponent("Contents/MacOS/Bowser").path)
        return "\(attrs[.size] ?? 0)-\(attrs[.modificationDate] ?? "")"
    }

    private func installEngine(in bundle: URL, build: String, info: inout [String: Any]) throws {
        for (source, target) in [("MacOS/Bowser", "MacOS/launch"), ("Frameworks/libBowserSurfaceKit.dylib", "Frameworks/libBowserSurfaceKit.dylib")] {
            let destination = bundle.appendingPathComponent("Contents/" + target)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: bowser.appendingPathComponent("Contents/" + source), to: destination)
        }
        info["BowserAppVersion"] = 2
        info["CFBundleVersion"] = "2"
        info["BowserEngineBuild"] = build
        info["BowserMainApp"] = bowser.path
        info["NSCameraUsageDescription"] = "Allow websites you approve to use your camera."
        info["NSMicrophoneUsageDescription"] = "Allow websites you approve to use your microphone."
    }

    private func installIcon(_ data: Data, in bundle: URL, info: inout [String: Any], hash: String? = nil) throws {
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try data.write(to: resources.appendingPathComponent("SiteIcon.icns"), options: .atomic)
        info["BowserIconHash"] = hash ?? TabAppBundle.digest(data)
    }

    private func finishStaging(_ staging: URL, info: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: staging.appendingPathComponent("Contents/Info.plist"), options: .atomic)
        try sign(staging)
    }

    static func signBundle(_ bundle: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--preserve-metadata=entitlements", bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableNotLoadable) }
    }
}
