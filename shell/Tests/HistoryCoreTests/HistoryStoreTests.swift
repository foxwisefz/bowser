import XCTest
@testable import HistoryCore

final class HistoryStoreTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("history-test-" + UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func record(_ text: String, url: String = "https://example.test/post/1", appearance: String = "", seen: Date = Date()) -> HistoryRecord {
        HistoryRecord(url: url, title: "A visited page", text: text, appearance: appearance, seen: seen)
    }
    func testStyleSearchDeduplicationAndPersistence() throws {
        let store = try HistoryStore(directory: root, profile: "work")
        let page = record("Network services", appearance: "white background; orange accents")
        try store.ingest(page); try store.ingest(page)
        XCTAssertEqual(try store.stats().records, 1)
        XCTAssertEqual(try store.search("that orange website", embedding: nil).first?.record.url, page.url)
        let reopened = try HistoryStore(directory: root, profile: "work")
        XCTAssertEqual(try reopened.search("orange", embedding: nil).count, 1)
    }
    func testProfileIsolationAndSafePaths() throws {
        let work = try HistoryStore(directory: root, profile: "../../work")
        let personal = try HistoryStore(directory: root, profile: "personal")
        try work.ingest(record("Confidential quarterly results"))
        XCTAssertEqual(try personal.stats().records, 0)
        XCTAssertTrue(work.path.path.hasPrefix(root.path + "/"))
        XCTAssertEqual(try personal.search("Confidential", embedding: nil), [])
    }
    func testSeparateFeedItemsSurviveChangesAtSameURL() throws {
        let store = try HistoryStore(directory: root, profile: "default")
        try store.ingest(record("First post about solar power"))
        try store.ingest(record("Next post about gardening"))
        XCTAssertEqual(try store.stats().records, 2)
        XCTAssertTrue(try store.search("solar", embedding: nil).first!.record.text.contains("solar"))
    }
    func testImageOnlyRecordWaitsForImageBeforeStorage() throws {
        let store = try HistoryStore(directory: root, profile: "default")
        var page = record("")
        XCTAssertNotNil(page.validated(requireContent: false))
        XCTAssertNil(page.validated())
        XCTAssertThrowsError(try store.ingest(page))
        page.image = Data([1, 2, 3])
        try store.ingest(page)
        XCTAssertEqual(try store.stats().records, 1)
        page.url = "file:///private/data"
        XCTAssertNil(page.validated(requireContent: false))
    }
    func testRetentionAndCountBudget() throws {
        let store = try HistoryStore(directory: root, profile: "default")
        let now = Date()
        try store.ingest(record("Old content", seen: now.addingTimeInterval(-91 * 86400)))
        for i in 0..<5 { try store.ingest(record("Recent content \(i)", seen: now.addingTimeInterval(Double(i)))) }
        try store.prune(days: 90, now: now, limit: 3)
        XCTAssertEqual(try store.stats().records, 3)
        XCTAssertEqual(try store.search("Old", embedding: nil).count, 0)
    }
    func testSemanticAndImageVectorsParticipateWithoutKeywords() throws {
        let store = try HistoryStore(directory: root, profile: "default")
        let page = record("Completely different words")
        try store.ingest(page)
        var text = [Float](repeating: 0, count: 512); text[0] = 1
        var image = [Float](repeating: 0, count: 512); image[1] = 1
        try store.setEmbedding(for: page, text: text, image: image)
        XCTAssertEqual(try store.search("unrelated query", embedding: image).first?.record.url, page.url)
        XCTAssertEqual(try store.stats().pending, 0)
        XCTAssertThrowsError(try store.setEmbedding(for: page, text: [.nan], image: nil))
    }
    func testDeletingRemovesSearchAndPendingEmbeddings() throws {
        let store = try HistoryStore(directory: root, profile: "default")
        let page = record("Needle in history")
        try store.ingest(page); try store.delete(key: page.key)
        XCTAssertEqual(try store.search("Needle", embedding: nil), [])
        XCTAssertNil(try store.nextUnindexed())
        try store.ingest(page); try store.delete()
        XCTAssertEqual(try store.stats().records, 0)
    }
    func testExclusionsMatchDomainBoundariesAndDeleteSubdomains() throws {
        XCTAssertFalse(HistoryPolicy.permits("https://mail.example.com/a", exclusions: ["example.com"]))
        XCTAssertTrue(HistoryPolicy.permits("https://notexample.com/a", exclusions: ["example.com"]))
        XCTAssertFalse(HistoryPolicy.permits("file:///private/data", exclusions: []))
        XCTAssertFalse(HistoryPolicy.permits("https://user:secret@example.com", exclusions: []))
        let store = try HistoryStore(directory: root, profile: "default")
        try store.ingest(record("Private", url: "https://mail.example.com/a"))
        try store.ingest(record("Public", url: "https://other.test/a"))
        try store.delete(host: "example.com")
        XCTAssertEqual(try store.stats().records, 1)
        XCTAssertEqual(try store.search("Private", embedding: nil), [])
    }
}
