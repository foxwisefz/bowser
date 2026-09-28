import Foundation
import CryptoKit
import Darwin
import BackendRuntime

// Snapshots deliberately exclude ephemeral sockets, locks, logs and update
// machinery. Website data keeps its existing macOS identity across channels.
private let excludedState: Set<String> = ["app", "app.previous", "backend", "releases", "updates", "backups", "brain.log", "data-use.lock", "browser-instance.lock", "launch-waiting", "prod-runtime", "staging-runtime", "staging-runtime.previous", "native-modules", "favicons", "resurrect.jpg", "recovery", "recovery-38g2"]
private let legacyExcludedState: Set<String> = ["app", "app.previous", "backend", "releases", "updates", "backups", "brain.log", "data-use.lock", "browser-instance.lock"]
private let libraryAreas = ["WebKit", "HTTPStorages", "Application Support", "Preferences", "Preferences/ByHost"]
private let bundleID = "com.foxwiseai.bowser"

func stateItems(_ root: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter {
        !excludedState.contains($0.lastPathComponent) && !$0.lastPathComponent.hasSuffix(".sock")
    }
}

func backupTargets(_ manifest: Message) throws -> [URL] {
    let root = try home(manifest)
    var targets = try stateItems(root)
    let executables = try [field(manifest, "runtime"), field(manifest, "bundle")].flatMap { [$0.path, $0.appendingPathExtension("previous").path] }
    targets.removeAll { executables.contains($0.resolvingSymlinksInPath().path) }
    // Alternate homes (tests/dev) must never touch the owner's Library.
    if root.standardizedFileURL.path == child(FileManager.default.homeDirectoryForCurrentUser, ".bowser").standardizedFileURL.path {
        let library = child(FileManager.default.homeDirectoryForCurrentUser, "Library")
        for area in libraryAreas {
            let directory = child(library, area)
            if !exists(directory) { continue }
            targets += try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter {
                $0.lastPathComponent == bundleID || $0.lastPathComponent.hasPrefix(bundleID + ".")
            }
        }
        // macOS protects enumeration of Library/Cookies, but permits direct
        // lookup of this app's files. Derive saved-app identities from their
        // WebKit stores and inspect only those exact cookie paths. Modern
        // WebKit also uses HTTPStorages, collected above.
        let identities = Set([bundleID] + targets.filter {
            $0.deletingLastPathComponent().path == child(library, "WebKit").path
        }.map(\.lastPathComponent))
        for identity in identities {
            let cookies = child(library, "Cookies/" + identity + ".binarycookies")
            do {
                _ = try FileManager.default.attributesOfItem(atPath: cookies.path)
                targets.append(cookies)
            } catch {
                let failure = error as NSError
                guard failure.domain == NSCocoaErrorDomain && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(failure.code) else { throw error }
            }
        }

    }
    // Foundation directory enumeration returns /private/tmp, whereas its
    // symlink resolver returns /tmp. Normalize parents without dereferencing
    // a user-owned symbolic link at the leaf.
    targets = targets.map { $0.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent($0.lastPathComponent) }
    let stage = try field(manifest, "stage")
    return Set(targets.filter { exists($0) && $0.path != stage.path }.map(\.path)).sorted().map { URL(fileURLWithPath: $0) }
}

/// Hash the payload, including symbolic links without following them. Ignore
/// sockets and other transient special files even inside website data trees.
func inventory(_ root: URL) throws -> [String: String] {
    let fm = FileManager.default
    var result: [String: String] = [:]
    func visit(_ url: URL, _ relative: String) throws {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory:
            result[relative] = "directory"
            for item in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try visit(item, relative + "/" + item.lastPathComponent)
            }
        case .typeSymbolicLink:
            result[relative] = "link:" + (try fm.destinationOfSymbolicLink(atPath: url.path))
        case .typeRegular:
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            var hash = SHA256()
            while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
            result[relative] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        default: break
        }
    }
    try visit(root, ".")
    return result
}

func copySnapshot(_ source: URL, _ target: URL) throws {
    let fm = FileManager.default
    let type = try fm.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType
    if type == .typeDirectory {
        try mkdir(target)
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try copySnapshot(item, child(target, item.lastPathComponent))
        }
    } else if type == .typeRegular || type == .typeSymbolicLink {
        try fm.copyItem(at: source, to: target)
    }
}

// Fingerprints include inode and nanosecond change time: restoring mtime after
// a same-size write cannot make changed data look unchanged.
private func fingerprint(_ url: URL) throws -> String {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw RuntimeFailure("Cannot stat backup source: \(url.path)") }
    return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
}

private func snapshotEntry(_ source: URL, _ copied: URL, previous: Message?) throws -> Message {
    let oldHashes = previous?["inventory"] as? [String: String] ?? [:]
    let oldStamps = previous?["source_fingerprints"] as? [String: String] ?? [:]
    var hashes: [String: String] = [:], stamps: [String: String] = [:]
    var reused = 0
    // Only WebKit's HTTP response cache is disposable. Keep IndexedDB, local
    // storage, service workers and CacheStorage (including offline app data).
    let isWebKit = source.deletingLastPathComponent().lastPathComponent == "WebKit" && source.lastPathComponent.hasPrefix(bundleID)
    func visit(_ from: URL, _ to: URL, _ relative: String) throws {
        let type = try FileManager.default.attributesOfItem(atPath: from.path)[.type] as? FileAttributeType
        if type == .typeDirectory {
            let parts = relative.split(separator: "/")
            if isWebKit && (relative == "./NetworkCache" || (parts.count == 4 && parts[1] == "WebsiteDataStore" && parts[3] == "NetworkCache")) { return }
            try mkdir(to); hashes[relative] = "directory"
            let before = try fingerprint(from)
            for item in try FileManager.default.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) {
                try visit(item, child(to, item.lastPathComponent), relative + "/" + item.lastPathComponent)
            }
            guard try fingerprint(from) == before else { throw RuntimeFailure("Backup source changed: \(from.path)") }
        } else if type == .typeRegular {
            let before = try fingerprint(from)
            // APFS creates an independent copy-on-write file, not a hard link.
            let cloned = clonefile(from.path, to.path, 0) == 0
            if !cloned { try FileManager.default.copyItem(at: from, to: to) }
            if cloned, oldStamps[relative] == before, let hash = oldHashes[relative], hash.count == 64 {
                hashes[relative] = hash; reused += 1
            } else {
                let original = try inventory(from)["."]
                guard try inventory(to)["."] == original else { throw RuntimeFailure("Backup verification failed: \(from.path)") }
                hashes[relative] = original
            }
            guard try fingerprint(from) == before else { throw RuntimeFailure("Backup source changed: \(from.path)") }
            stamps[relative] = before
        } else if type == .typeSymbolicLink {
            let link = try FileManager.default.destinationOfSymbolicLink(atPath: from.path)
            try FileManager.default.createSymbolicLink(atPath: to.path, withDestinationPath: link)
            hashes[relative] = "link:" + link
        }
    }
    try visit(source, copied, ".")
    return ["inventory": hashes, "source_fingerprints": stamps, "reused_checksums": reused]
}

@discardableResult func backup(_ manifest: Message) throws -> URL {
    let root = try home(manifest), backups = child(root, "backups")
    try mkdir(backups)
    let name = String(Int(Date().timeIntervalSince1970)) + "-" + UUID().uuidString
    let temporary = child(backups, "." + name), destination = child(backups, name)
    try mkdir(temporary)
    defer { try? remove(temporary) }
    // Completed snapshots only; a failed/in-progress snapshot is never a base.
    let candidates = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    let previous = candidates.lazy.compactMap { try? readJSON(child($0, "snapshot.json")) }.first
    let previousEntries = previous?["entries"] as? [Message] ?? []
    var entries: [Message] = []
    for target in try backupTargets(manifest) {
        let payload = String(entries.count)
        var entry = try snapshotEntry(target, child(temporary, payload), previous: previousEntries.first { $0["target"] as? String == target.path })
        guard !(entry["inventory"] as? [String: String] ?? [:]).isEmpty else { continue }
        entry["target"] = target.path; entry["payload"] = payload
        entries.append(entry)
    }
    try atomicJSON(child(temporary, "snapshot.json"), ["format": 2, "installation": manifest, "entries": entries])
    try FileManager.default.moveItem(at: temporary, to: destination)
    print("Verified recovery backup: \(destination.path)")
    return destination
}

func restoreBackup(_ snapshot: URL) throws {
    let document = try readJSON(child(snapshot, "snapshot.json"))
    guard let format = document["format"] as? Int, [1, 2].contains(format), let manifest = document["installation"] as? Message,
          let entries = document["entries"] as? [Message] else { throw RuntimeFailure("Invalid backup") }
    let root = try home(manifest)
    guard snapshot.deletingLastPathComponent().resolvingSymlinksInPath().path == child(root, "backups").resolvingSymlinksInPath().path else {
        throw RuntimeFailure("Backup must be in this installation’s backups directory")
    }
    let updateLock = try FileLock(child(root, "updates/pending.lock"), nonblocking: true)
    let dataLock = try FileLock(child(root, "data-use.lock"), nonblocking: true)
    defer { withExtendedLifetime((updateLock, dataLock)) {} }
    guard try !busy(manifest, dataLocked: true) else { throw RuntimeFailure("Quit Bowser and all saved apps before recovery") }
    guard !exists(child(root, "updates/pending.json")) else { throw RuntimeFailure("An update is pending; cancel it with bin/staging cancel before recovery") }
    // Validate every byte and target before writing anything. This command is
    // local recovery; snapshots do not supply arbitrary execution instructions.
    let current = try backupTargets(manifest)
    let library = child(FileManager.default.homeDirectoryForCurrentUser, "Library")
    func allowed(_ url: URL) throws -> Bool {
        if try url.path == field(manifest, "runtime").path || url.path == field(manifest, "bundle").path { return format == 1 }
        if url.deletingLastPathComponent().path == root.path && !(format == 1 ? legacyExcludedState : excludedState).contains(url.lastPathComponent) && !url.lastPathComponent.hasSuffix(".sock") { return true }
        if root.path != child(FileManager.default.homeDirectoryForCurrentUser, ".bowser").path { return false }
        if format == 1, ["/Applications/Bowser.app", "/Applications/Bowser-prod.app", "/Applications/Bowser-staging.app"].contains(url.path) { return true }
        if format == 1, url.path == child(FileManager.default.homeDirectoryForCurrentUser, "Applications/Bowser Apps").path { return true }
        return (libraryAreas + ["Cookies"]).contains { url.deletingLastPathComponent().path == child(library, $0).path } &&
            (url.lastPathComponent == bundleID || url.lastPathComponent.hasPrefix(bundleID + "."))
    }
    var restored: [(URL, URL)] = []
    var seen = Set<String>()
    for entry in entries {
        guard let path = entry["target"] as? String, let payload = entry["payload"] as? String,
              payload == String(Int(payload) ?? -1), let hashes = entry["inventory"] as? [String: String],
              seen.insert(path).inserted else { throw RuntimeFailure("Invalid backup entry") }
        let target = URL(fileURLWithPath: path).standardizedFileURL
        guard try allowed(target), try inventory(child(snapshot, payload)) == hashes else { throw RuntimeFailure("Backup verification failed: \(path)") }
        restored.append((target, child(snapshot, payload)))
    }
    // Keep a new recovery point before rewinding. Backups are never pruned
    // automatically, including the original production build.
    try backup(manifest)
    var swaps: [(URL, URL, Bool)] = []
    do {
        for target in Set(current + restored.map(\.0)).sorted(by: { $0.path < $1.path }) {
            let old = target.appendingPathExtension("recovery-" + UUID().uuidString)
            let next = target.appendingPathExtension("restore-" + UUID().uuidString)
            defer { try? remove(next) }
            if let source = restored.first(where: { $0.0 == target })?.1 { try copySnapshot(source, next) }
            let existed = exists(target)
            if existed { try FileManager.default.moveItem(at: target, to: old) }
            swaps.append((target, old, existed))
            if exists(next) { try FileManager.default.moveItem(at: next, to: target) }
        }
        // A distribution app can contain an older bundled runtime while a
        // compatible backend was updated live. The snapshot's external runtime
        // is the one that last used these data; keep it authoritative on launch.
        if format == 1 {
            try mkdir(child(root, "backend"))
            let channel = UpdateChannel(manifest["channel"] as? String)
            try atomicJSON(child(root, channel.activePointer), ["runtime": field(manifest, "runtime").path])
        }
    } catch {
        for (target, old, existed) in swaps.reversed() {
            try remove(target)
            if existed { try FileManager.default.moveItem(at: old, to: target) }
        }
        throw error
    }
    for (_, old, _) in swaps { try remove(old) }
    print(format == 1 ? "Restored build and data. Open Bowser normally." : "Restored user data. Installed apps and runtimes are unchanged.")
}
