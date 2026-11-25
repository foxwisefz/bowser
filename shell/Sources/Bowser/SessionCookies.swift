import Foundation
import WebKit

/// WebKit persists expiring cookies, but drops session cookies when its process
/// exits. Carry those through a clean browser restart alongside restored tabs.
/// The snapshot is private to this browser home, keyed by store identity, and
/// consumed before navigation so an old login can never be replayed later.
@MainActor enum SessionCookies {
    static var file: URL { BowserPaths.home.appendingPathComponent("session-cookies/cookies.plist") }

    static func stores() -> [String: WKWebsiteDataStore] {
        Dictionary(Profile.all.map { profile in
            let key = profile.id == "default" ? "default" : Profile.storeUUID(id: profile.id, uuid: profile.uuid).uuidString
            return (key, profile.dataStore)
        }, uniquingKeysWith: { first, _ in first })
    }

    static func save(to file: URL = file, stores: [String: WKWebsiteDataStore]? = nil) async throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        var snapshot: [String: [[String: Any]]] = [:]
        for (id, store) in stores ?? Self.stores() {
            let cookies = await store.httpCookieStore.allCookies()
            snapshot[id] = cookies.filter(\.isSessionOnly).compactMap { cookie in
                cookie.properties.map { properties in
                    Dictionary(uniqueKeysWithValues: properties.map { key, value in
                        (key.rawValue, (value as? URL)?.absoluteString ?? value)
                    })
                }
            }
        }
        guard snapshot.values.contains(where: { !$0.isEmpty }) else { return }
        let data = try PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // The private directory protects the atomic temporary file as well.
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func restore(from file: URL = file, stores: [String: WKWebsiteDataStore]? = nil) async throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let data = try Data(contentsOf: file)
        // Consume even malformed snapshots rather than retrying stale credentials.
        try FileManager.default.removeItem(at: file)
        let snapshot = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [[String: Any]]] ?? [:]
        guard snapshot.values.contains(where: { !$0.isEmpty }) else { return }
        for (id, store) in stores ?? Self.stores() {
            guard let saved = snapshot[id], !saved.isEmpty else { continue }
            let existing = await store.httpCookieStore.allCookies()
            for properties in saved {
                let raw = Dictionary(uniqueKeysWithValues: properties.map { (HTTPCookiePropertyKey($0.key), $0.value) })
                guard let cookie = HTTPCookie(properties: raw), cookie.isSessionOnly,
                      !existing.contains(where: { $0.domain == cookie.domain && $0.path == cookie.path && $0.name == cookie.name }) else { continue }
                await store.httpCookieStore.setCookie(cookie)
            }
        }
    }
}
