import Foundation

/// Lightweight database access stays independent of the disposable model process.
/// Actor isolation also orders deletes and navigation writes across UI tasks.
public actor HistoryRepository {
    private let directory: URL
    private var stores: [String: HistoryStore] = [:]
    private var generations: [String: Int] = [:]
    public init(directory: URL) { self.directory = directory }
    private func store(_ profile: String) throws -> HistoryStore {
        if let value = stores[profile] { return value }
        let value = try HistoryStore(directory: directory, profile: profile)
        stores[profile] = value
        return value
    }
    private func accepts(_ profile: String, generation: Int) -> Bool {
        guard generation >= generations[profile, default: 0] else { return false }
        generations[profile] = generation
        return true
    }
    public func invalidate(profile: String, generation: Int) { _ = accepts(profile, generation: generation) }
    public func record(profile: String, id: String, value: HistoryRecord, days: Int, generation: Int) throws -> HistoryStats? {
        guard accepts(profile, generation: generation) else { return nil }
        let store = try store(profile)
        try store.visit(id: id, record: value); try store.prune(days: days)
        return try store.stats()
    }
    public func preview(profile: String, id: String, data: Data, days: Int, generation: Int) throws -> HistoryStats? {
        guard accepts(profile, generation: generation) else { return nil }
        let store = try store(profile)
        try store.preview(id: id, data: data); try store.prune(days: days)
        return try store.stats()
    }
    public func browse(profile: String, query: String = "", after: Date? = nil, before: Date? = nil, host: String = "", limit: Int = 60, days: Int = 90) throws -> ([HistoryHit], HistoryStats) {
        let store = try store(profile)
        try store.prune(days: days)
        return (try store.browse(query: query, after: after, before: before, host: host, limit: limit), try store.stats())
    }
    public func delete(profile: String, visits: [String] = [], records: [String] = [], all: Bool = false, host: String? = nil, generation: Int) throws -> HistoryStats? {
        guard accepts(profile, generation: generation) else { return nil }
        let store = try store(profile)
        if all || host != nil { try store.delete(host: host) }
        else { try store.delete(visits: visits, records: records) }
        return try store.stats()
    }
}
