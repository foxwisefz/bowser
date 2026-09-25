import Foundation

/// Compressed, per-tab previews with a strict total byte budget. Never written to disk.
@MainActor final class TabPreviewCache {
    static let shared = TabPreviewCache()
    private let budget: Int
    private var entries: [UInt64: (url: String, data: Data)] = [:]
    private var order: [UInt64] = []
    private(set) var byteCount = 0

    init(budget: Int = 16 * 1024 * 1024) { self.budget = budget }

    func store(_ data: Data, for id: UInt64, url: String) {
        remove(id)
        guard data.count <= min(budget, 512 * 1024) else { return }
        while byteCount + data.count > budget, let oldest = order.first { remove(oldest) }
        entries[id] = (url, data)
        order.append(id)
        byteCount += data.count
    }

    func data(for id: UInt64, url: String) -> Data? {
        guard let entry = entries[id], entry.url == url else { return nil }
        return entry.data
    }

    func remove(_ id: UInt64) {
        if let entry = entries.removeValue(forKey: id) { byteCount -= entry.data.count }
        order.removeAll { $0 == id }
    }
}
