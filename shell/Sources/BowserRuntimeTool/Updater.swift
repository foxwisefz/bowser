import Foundation
import Darwin
import BackendRuntime

func command(_ executable: String, _ args: [String]) throws -> String {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}
func field(_ manifest: Message, _ key: String) throws -> URL {
    guard let path = manifest[key] as? String, path.hasPrefix("/") else { throw RuntimeFailure("missing absolute path: \(key)") }
    return URL(fileURLWithPath: path).resolvingSymlinksInPath()
}
func home(_ manifest: Message) throws -> URL {
    if let path = manifest["home"] as? String { return URL(fileURLWithPath: path).resolvingSymlinksInPath() }
    return try field(manifest, "runtime").deletingLastPathComponent()
}
/// Pids of launches parked at the data-lock gate. Stale markers from dead
/// launches are pruned here so a crashed launch can never block an update.
func waitingLaunches(_ root: URL) -> Set<Int32> {
    var pids: Set<Int32> = []
    for file in (try? FileManager.default.contentsOfDirectory(at: child(root, "launch-waiting"), includingPropertiesForKeys: nil)) ?? [] {
        guard let pid = Int32(file.lastPathComponent) else { continue }
        if kill(pid, 0) == 0 || errno == EPERM { pids.insert(pid) }
        else { try? FileManager.default.removeItem(at: file) }
    }
    return pids
}
func busy(_ manifest: Message, dataLocked: Bool = false) throws -> Bool {
    let root = try home(manifest)
    let owner = child(root, "backend/owner.lock")
    if exists(owner) {
        guard let lock = try? FileLock(owner, nonblocking: true) else { return true }
        withExtendedLifetime(lock) {}
    }
    // Browsers, saved apps and backends hold the data lock shared while they
    // use data; contention alone means the update must wait. Callers already
    // holding the exclusive lock skip the probe they would deadlock against.
    if !dataLocked {
        guard let probe = try? FileLock(child(root, "data-use.lock"), nonblocking: true) else { return true }
        withExtendedLifetime(probe) {}
    }
    // Builds that predate the locks never hold them, so still match running
    // process paths — but ignore launches parked at the gate for this update.
    let waiting = waitingLaunches(root)
    var roots = try [field(manifest, "bundle").path + "/", field(manifest, "runtime").path + "/",
                     (manifest["saved_apps"] as? String ?? child(FileManager.default.homeDirectoryForCurrentUser, "Applications/Bowser Apps").path) + "/",
                     child(root, "releases").path + "/"]
    if root.path == child(FileManager.default.homeDirectoryForCurrentUser, ".bowser").path {
        roots += ["/Applications/Bowser-prod.app/", "/Applications/Bowser-staging.app/", "/Applications/Bowser.app/", child(FileManager.default.homeDirectoryForCurrentUser, "Applications/Bowser.app").path + "/"]
    }
    return try command("/bin/ps", ["-axo", "pid=,comm="]).split(separator: "\n").contains { line in
        let text = line.drop(while: { $0 == " " })
        guard let split = text.firstIndex(of: " "), let pid = Int32(text[..<split]), !waiting.contains(pid) else { return false }
        let path = text[split...].drop(while: { $0 == " " })
        return roots.contains { path.hasPrefix($0) }
    }
}
func activate(_ manifest: Message) throws {
    var changed: [(URL, URL, Bool, URL)] = []
    do {
        for key in ["runtime", "bundle"] {
            let source = child(try field(manifest, "stage"), key)
            if !exists(source) { continue }
            let target = try field(manifest, key)
            let previous = target.appendingPathExtension("previous")
            try remove(previous)
            let existed = exists(target)
            if existed { try FileManager.default.moveItem(at: target, to: previous) }
            changed.append((target, previous, existed, source))
            try FileManager.default.moveItem(at: source, to: target)
        }
    } catch {
        for (target, previous, existed, source) in changed.reversed() {
            if exists(target) { try FileManager.default.moveItem(at: target, to: source) }
            if existed && exists(previous) { try FileManager.default.moveItem(at: previous, to: target) }
        }
        throw error
    }
}
func publish(_ pending: URL, _ supplied: Message, shellOnly: Bool, brainOnly: Bool, live: Bool = false) throws {
    var manifest = supplied
    manifest["backup_required"] = true
    manifest["live_allowed"] = live && !shellOnly && !brainOnly
    manifest["published_at"] = Date().timeIntervalSince1970
    let target = try field(manifest, "bundle")
    let incoming = child(try field(manifest, "stage"), "bundle")
    func staging(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: child(url, "Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Message else { return false }
        return info["BowserChannel"] as? String == "staging"
    }
    if ProcessInfo.processInfo.environment["BOWSER_OFFLINE_UPDATE"] == "1" || staging(target) != staging(incoming) {
        manifest["live_allowed"] = false
    }
    manifest["channel"] = staging(incoming) ? "staging" : "stable"
    let lock = try FileLock(pending.deletingPathExtension().appendingPathExtension("lock"))
    defer { withExtendedLifetime(lock) {} }
    let previous = exists(pending) ? try readJSON(pending) : nil
    if let previous {
        guard previous["runtime"] as? String == manifest["runtime"] as? String,
              previous["bundle"] as? String == manifest["bundle"] as? String else { throw RuntimeFailure("pending update targets differ") }
        if previous["backup_required"] as? Bool == true { manifest["backup_required"] = true }
        let old = try field(previous, "stage"), new = try field(manifest, "stage")
        if shellOnly && exists(child(old, "runtime/brain")) {
            try remove(child(new, "runtime/brain")); try FileManager.default.copyItem(at: child(old, "runtime/brain"), to: child(new, "runtime/brain"))
        }
        if brainOnly && exists(child(old, "bundle")) { try FileManager.default.copyItem(at: child(old, "bundle"), to: child(new, "bundle")) }
    }
    try atomicJSON(pending, manifest)
    if let previous, previous["stage"] as? String != manifest["stage"] as? String { try remove(field(previous, "stage")) }
}
func liveUpdate(_ manifest: inout Message) async throws -> Bool {
    let root = try home(manifest), endpoint = child(root, "backend/host.sock"), stage = child(try field(manifest, "stage"), "runtime")
    guard exists(endpoint), exists(child(stage, "HANDOFF.json")) else { return false }
    let channel = UpdateChannel(manifest["channel"] as? String)
    let status = (try? await request(endpoint, ["op": "status"])) ?? [:]
    guard UpdateChannel(status["channel"] as? String) == channel, status["live_updates"] as? Bool == true else {
        manifest["deferred_reason"] = "Running backend requires restart or belongs to another channel"
        return false
    }
    let runtime: URL
    if let existing = manifest["live_runtime"] as? String { runtime = URL(fileURLWithPath: existing) }
    else {
        let releases = child(root, channel.releases); try mkdir(releases)
        runtime = child(releases, UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        let temporary = runtime.appendingPathExtension("new")
        try FileManager.default.copyItem(at: stage, to: temporary)
        try FileManager.default.moveItem(at: temporary, to: runtime); manifest["live_runtime"] = runtime.path
    }
    do {
        _ = try await request(endpoint, ["op": "update", "runtime": runtime.path], timeout: 30)
        manifest.removeValue(forKey: "deferred_reason")
        manifest["backend_applied"] = true; print("Backend updated live; existing pages remain alive."); return true
    } catch { manifest["deferred_reason"] = String(describing: error); print("Live update deferred: \(error)"); return false }
}
func refreshWatcher(_ pending: URL) throws {
    let pending = pending.resolvingSymlinksInPath()
    let lock = try FileLock(pending.deletingPathExtension().appendingPathExtension("lock"))
    defer { withExtendedLifetime(lock) {} }
    let pids = try command("/usr/sbin/lsof", ["-t", pending.deletingPathExtension().appendingPathExtension("watcher.lock").path])
    for value in Set(pids.split(whereSeparator: { $0.isWhitespace })) {
        guard let pid = Int32(value), pid != getpid() else { continue }
        // Match the native executable and this exact home before signalling the lock holder.
        let args = try command("/bin/ps", ["-p", String(pid), "-o", "args="]).trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = child(pending.deletingLastPathComponent(), "apply-update").path + " " + pending.path + " --wait"
        if args == expected { kill(pid, SIGTERM); print("Retired previous pending-update watcher.") }
    }
}
func updateProgress(_ pending: URL, _ manifest: Message, _ phase: String, error: String? = nil) throws {
    _ = try field(manifest, "stage"); _ = try field(manifest, "bundle")
    // Identity must survive moving/removing the stage. Filesystem URL
    // canonicalization can change once those paths no longer exist.
    var state: Message = ["stage": manifest["stage"]!,
                          "bundle": manifest["bundle"]!, "phase": phase]
    if let error { state["error"] = error }
    try atomicJSON(pending.deletingLastPathComponent().appendingPathComponent("progress.json"), state)
}

func runUpdater(_ args: [String]) async throws {
    do { try await applyPendingUpdate(args) }
    catch {
        if let first = args.first, !args.contains("--refresh-watcher") {
            let pending = URL(fileURLWithPath: first)
            if let manifest = try? readJSON(pending) {
                try? updateProgress(pending, manifest, "failed", error: String(describing: error))
            }
        }
        throw error
    }
}

// Keep the probe in a synchronous scope: an async local can retain the lock
// across Task.sleep, preventing the restart coordinator from ever starting.
private func updatePollDelay(_ pending: URL) -> UInt64 {
    let lock = try? FileLock(child(pending.deletingLastPathComponent(), "restart.lock"), nonblocking: true)
    return withExtendedLifetime(lock) { lock == nil ? 250_000_000 : 2_000_000_000 }
}

private func applyPendingUpdate(_ args: [String]) async throws {
    guard let first = args.first else { throw RuntimeFailure("usage: apply-update PENDING [--wait|--refresh-watcher]") }
    let pending = URL(fileURLWithPath: first); try mkdir(pending.deletingLastPathComponent())
    if args.contains("--refresh-watcher") { try refreshWatcher(pending); return }
    guard let watcher = try? FileLock(pending.deletingPathExtension().appendingPathExtension("watcher.lock"), nonblocking: true) else { return }
    defer { withExtendedLifetime(watcher) {} }
    while true {
        do {
            let lock = try FileLock(pending.deletingPathExtension().appendingPathExtension("lock"))
            defer { withExtendedLifetime(lock) {} }
            guard exists(pending) else { return }
            var manifest = try readJSON(pending)
            try updateProgress(pending, manifest, "waiting")
            if try busy(manifest), manifest["live_allowed"] as? Bool == true, manifest["backend_applied"] as? Bool != true,
               Date().timeIntervalSince1970 - (manifest["live_attempt_at"] as? Double ?? 0) >= 60 {
                manifest["live_attempt_at"] = Date().timeIntervalSince1970
                _ = try await liveUpdate(&manifest); try atomicJSON(pending, manifest)
            }
            if try !busy(manifest) {
                if try !busy(manifest) {
                    // Every shell/saved app and backend holds this shared while
                    // running; acquisition closes the launch-vs-backup race.
                    guard let dataLock = try? FileLock(child(home(manifest), "data-use.lock"), nonblocking: true) else {
                        if !args.contains("--wait") { print("Bowser is using its data; update remains staged."); return }
                        continue
                    }
                    defer { withExtendedLifetime(dataLock) {} }
                    // The exclusive lock is authoritative from here on: every
                    // data user holds it shared, and launches that arrive now
                    // park at the gate without touching data. Re-checking busy
                    // would deadlock against those parked launches.
                    if manifest["backup_required"] as? Bool == true {
                        try updateProgress(pending, manifest, "backup")
                        try backup(manifest)
                    }
                    try updateProgress(pending, manifest, "installing")
                    try activate(manifest)
                    if manifest["backup_required"] as? Bool == true {
                        for kind in ["surfaces", "command-toolbar"] {
                            try remove(child(home(manifest), UpdateChannel(manifest["channel"] as? String).modules + "/" + kind + "/current"))
                        }
                    }
                    let root = try home(manifest)
                    let channel = UpdateChannel(manifest["channel"] as? String)
                    try remove(child(root, channel.activePointer))
                    for release in (try? FileManager.default.contentsOfDirectory(at: child(root, channel.releases), includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])) ?? [] {
                        let name = release.lastPathComponent, values = try release.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                        if name.count == 32 && name.allSatisfy({ "0123456789abcdef".contains($0) }) && values.isDirectory == true && values.isSymbolicLink != true { try remove(release) }
                    }
                    try remove(field(manifest, "stage"))
                    try updateProgress(pending, manifest, "complete")
                    try remove(pending)
                    print("Staged Bowser update activated. Ready for next launch."); return
                }
            }
        }
        if !args.contains("--wait") { print("Update staged; it will activate after Bowser and saved apps quit."); return }
        // Poll quickly only while the user-facing restart coordinator runs.
        try await Task.sleep(nanoseconds: updatePollDelay(pending))
    }
}
