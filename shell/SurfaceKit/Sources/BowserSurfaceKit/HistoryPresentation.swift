import Foundation

public struct HistorySearchItem: Equatable, Identifiable, Sendable {
    public let id: String
    public let url: String
    public let title: String
    public let snippet: String
    public let seen: Date
    public let image: Data?
    public init(id: String, url: String, title: String, snippet: String, seen: Date, image: Data?) {
        self.id = id; self.url = url; self.title = title; self.snippet = snippet; self.seen = seen; self.image = image
    }
}
@MainActor public protocol HistoryPresentation: AnyObject {
    var profiles: [ProfileDisplay] { get }
    var selectedProfile: String { get set }
    var enabled: Bool { get set }
    var includeImages: Bool { get set }
    var retentionDays: Int { get set }
    var excludedSites: String { get set }
    var query: String { get set }
    var results: [HistorySearchItem] { get }
    var status: String { get }
    var storageText: String { get }
    var storageWarning: String? { get }
    var isSearching: Bool { get }
    var isDownloading: Bool { get }
    var modelReady: Bool { get }
    func downloadModel()
    func search()
    func open(_ item: HistorySearchItem)
    func delete(_ item: HistorySearchItem)
    func clear()
    func saveExclusions()
}
