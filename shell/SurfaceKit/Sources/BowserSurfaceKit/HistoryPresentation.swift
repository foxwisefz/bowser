import Foundation

public struct HistorySearchItem: Equatable, Identifiable, Sendable {
    public let id: String
    public let url: String
    public let title: String
    public let snippet: String
    public let seen: Date
    public let image: Data?
    public let profile: String
    public let key: String
    public let isVisit: Bool
    public init(id: String, url: String, title: String, snippet: String, seen: Date, image: Data?, profile: String = "", key: String? = nil, isVisit: Bool = false) {
        self.id = id; self.url = url; self.title = title; self.snippet = snippet; self.seen = seen; self.image = image
        self.profile = profile; self.key = key ?? id; self.isVisit = isVisit
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
    var allProfiles: Bool { get set }
    var dateFilter: String { get set }
    var siteFilter: String { get set }
    var hasMore: Bool { get }
    var lastSaved: Date? { get }
    var searchError: String? { get }
    var recordingIssue: String? { get }
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
    func delete(_ items: [HistorySearchItem])
    func loadMore()
    func showSettings()
    func showBrowser()
    func clear()
    func saveExclusions()
}

public extension HistoryPresentation {
    var allProfiles: Bool { get { false } set {} }
    var dateFilter: String { get { "all" } set {} }
    var siteFilter: String { get { "" } set {} }
    var hasMore: Bool { false }
    var lastSaved: Date? { nil }
    var searchError: String? { nil }
    var recordingIssue: String? { nil }
    func delete(_ items: [HistorySearchItem]) { items.forEach { delete($0) } }
    func loadMore() {}
    func showSettings() {}
    func showBrowser() {}
}

public struct HistorySession: Identifiable, Sendable {
    public let id: String
    public let items: [HistorySearchItem]
    public var latest: Date { items[0].seen }
    public var earliest: Date { items[items.count - 1].seen }
    public var isVisit: Bool { items[0].isVisit }
    public var topic: String {
        var seen = Set<String>()
        return items.compactMap { URL(string: $0.url)?.host?.replacingOccurrences(of: "www.", with: "") }
            .filter { seen.insert($0).inserted }.prefix(3).joined(separator: " · ")
    }
    /// Stable time blocks; domain labels never move visits into invented sessions.
    public static func group(_ items: [HistorySearchItem], calendar: Calendar = .current) -> [Self] {
        var groups: [[HistorySearchItem]] = []
        for (_, profileItems) in Dictionary(grouping: items, by: \.profile) {
        var profileGroups: [[HistorySearchItem]] = []
        for item in profileItems.sorted(by: { $0.seen > $1.seen }) {
            if let index = profileGroups.indices.last, let previous = profileGroups[index].last,
               previous.profile == item.profile, previous.isVisit == item.isVisit,
               calendar.isDate(previous.seen, inSameDayAs: item.seen), previous.seen.timeIntervalSince(item.seen) < 30 * 60 {
                profileGroups[index].append(item)
            } else { profileGroups.append([item]) }
        }
        groups += profileGroups
        }
        return groups.map { Self(id: $0[0].id, items: $0) }.sorted { $0.latest > $1.latest }
    }
}
