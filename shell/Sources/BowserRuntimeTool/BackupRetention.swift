import Foundation
import BackendRuntime

private struct RecoverySnapshot {
    let url: URL
    let created: TimeInterval
}

// Only updater-owned, completed snapshots participate. Leave unknown files,
// incomplete snapshots and symbolic links alone.
private func recoverySnapshots(_ root: URL) throws -> [RecoverySnapshot] {
    let backups = child(root, "backups")
    guard exists(backups) else { return [] }
    let fm = FileManager.default
    guard try fm.attributesOfItem(atPath: backups.path)[.type] as? FileAttributeType == .typeDirectory else {
        throw RuntimeFailure("Backups must be a directory, not a symbolic link")
    }
    return try fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).compactMap { url -> RecoverySnapshot? in
        // A long history can contain hundreds of large inventory dictionaries.
        // Retain only paths/dates, releasing each parsed manifest immediately.
        try autoreleasepool {
            let parts = url.lastPathComponent.split(separator: "-", maxSplits: 1)
            guard parts.count == 2, let timestamp = TimeInterval(parts[0]), timestamp.isFinite,
                  UUID(uuidString: String(parts[1])) != nil,
                  try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else { return nil }
            let metadata = child(url, "snapshot.json")
            guard let attributes = try? fm.attributesOfItem(atPath: metadata.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let document = try? readJSON(metadata), let format = document["format"] as? Int, [1, 2].contains(format),
                  let installation = document["installation"] as? Message,
                  let savedHome = installation["home"] as? String,
                  URL(fileURLWithPath: savedHome).resolvingSymlinksInPath().path == root.path,
                  let entries = document["entries"] as? [Message], !entries.isEmpty else { return nil }
            var payloads = Set<String>()
            for entry in entries {
                guard let payload = entry["payload"] as? String, let number = Int(payload), number >= 0,
                      payload == String(number), payloads.insert(payload).inserted,
                      entry["target"] is String, let hashes = entry["inventory"] as? [String: String], hashes["."] != nil else { return nil }
            }
            let created = document["created_at"] as? Double ?? (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? timestamp
            return RecoverySnapshot(url: url.resolvingSymlinksInPath(), created: created)
        }
    }.sorted { $0.created == $1.created ? $0.url.lastPathComponent > $1.url.lastPathComponent : $0.created > $1.created }
}

/// The caller holds updates/pending.lock, shared by backup, restore and cleanup.
/// A just-verified snapshot can skip redundant hashing during automatic pruning.
@discardableResult func pruneBackups(_ root: URL, apply: Bool, preserving: Set<URL> = [], verified: URL? = nil) throws -> Int {
    let snapshots = try recoverySnapshots(root)
    // Compare paths: Foundation directory URLs can differ only in a trailing
    // slash, and macOS also aliases /tmp and /private/tmp.
    let retained = Set(snapshots.prefix(3).map { $0.url.path }).union(preserving.map { $0.resolvingSymlinksInPath().path }).union(
        snapshots.filter { exists(child($0.url, ".keep")) }.map { $0.url.path })
    let obsolete = snapshots.filter { !retained.contains($0.url.path) }
    if !apply {
        for snapshot in snapshots { print("\(retained.contains(snapshot.url.path) ? "Keep" : "Remove"): \(snapshot.url.path)") }
    }
    guard apply, !obsolete.isEmpty else { return obsolete.count }
    // Manual cleanup must establish that the recent recovery points are still
    // intact before deleting anything. Automatic cleanup just made one itself.
    if let verified {
        guard snapshots.contains(where: { $0.url.path == verified.resolvingSymlinksInPath().path }),
              retained.contains(verified.resolvingSymlinksInPath().path) else {
            throw RuntimeFailure("New backup was not recognized; older backups were preserved")
        }
    } else {
        for snapshot in snapshots.prefix(3) {
            try autoreleasepool {
                let document = try readJSON(child(snapshot.url, "snapshot.json"))
                guard let entries = document["entries"] as? [Message], !entries.isEmpty else {
                    throw RuntimeFailure("Invalid retained backup: \(snapshot.url.path)")
                }
                for entry in entries {
                    guard let payload = entry["payload"] as? String, let number = Int(payload), number >= 0,
                          payload == String(number), let hashes = entry["inventory"] as? [String: String],
                          try inventory(child(snapshot.url, payload)) == hashes else {
                        throw RuntimeFailure("Retained backup failed verification; nothing removed: \(snapshot.url.path)")
                    }
                }
            }
        }
    }
    for snapshot in obsolete { try FileManager.default.removeItem(at: snapshot.url) }
    print("Removed \(obsolete.count) old recovery backups; kept \(retained.count).")
    return obsolete.count
}

func cleanupBackups(_ args: [String]) throws {
    guard args.count == 1 || (args.count == 2 && args[1] == "--apply"), args[0].hasPrefix("/") else {
        throw RuntimeFailure("cleanup-backups HOME [--apply] (default: preview)")
    }
    let root = URL(fileURLWithPath: args[0]).resolvingSymlinksInPath()
    let lock = try FileLock(child(root, "updates/pending.lock"), nonblocking: true)
    defer { withExtendedLifetime(lock) {} }
    try pruneBackups(root, apply: args.count == 2)
}
