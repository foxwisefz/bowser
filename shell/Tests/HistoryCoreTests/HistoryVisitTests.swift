import XCTest
import SQLite3
@testable import HistoryCore

final class HistoryVisitTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("history-visits-" + UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func page(_ title: String, url: String = "https://example.test", seconds: Double = 0) -> HistoryRecord {
        HistoryRecord(url: url, title: title, text: "", seen: now.addingTimeInterval(seconds))
    }
    func testRepeatVisitsKeepTheirTimesAndPreviewsWhenContentDeduplicates() throws {
        let store = try HistoryStore(directory: root, profile: "work")
        let first = UUID().uuidString, second = UUID().uuidString
        try store.visit(id: first, record: page("Initial title"))
        try store.visit(id: second, record: page("Later visit", seconds: 600))
        try store.visit(id: first, record: page("Loaded title", seconds: 900))
        try store.preview(id: first, data: Data([1, 2, 3]))
        var content = page("Loaded title"); content.text = "Orange network services"
        try store.ingest(content); content.seen = now.addingTimeInterval(1000); try store.ingest(content)
        let reopened = try HistoryStore(directory: root, profile: "work")
        let hits = try reopened.browse()
        XCTAssertEqual(hits.map(\.id), [second, first])
        XCTAssertEqual(hits.map(\.record.seen), [now.addingTimeInterval(600), now])
        XCTAssertEqual(hits.last?.record.title, "Loaded title")
        XCTAssertEqual(hits.last?.record.image, Data([1, 2, 3]))
        XCTAssertTrue(hits.allSatisfy { $0.isVisit == true })
        XCTAssertEqual(try reopened.stats().lastVisit, now.addingTimeInterval(600))
        XCTAssertEqual(try reopened.stats().records, 1)
        XCTAssertEqual(try reopened.browse(query: "orange").count, 2)
    }
    func testBrowseFiltersDatesDomainsAndTitlesWithoutModelOrContent() throws {
        let store = try HistoryStore(directory: root, profile: "work")
        for (index, url) in ["https://example.test", "https://sub.example.test:8443/page", "https://notexample.test", "https://other.test"].enumerated() {
            try store.visit(id: UUID().uuidString, record: page("Page \(index)", url: url, seconds: Double(index * 60)))
        }
        XCTAssertEqual(try store.browse(limit: 2).map(\.record.title), ["Page 3", "Page 2"])
        XCTAssertEqual(try store.browse(host: "example.test").count, 2)
        XCTAssertEqual(try store.browse(after: now.addingTimeInterval(60), before: now.addingTimeInterval(120)).map(\.record.title), ["Page 1"])
        XCTAssertEqual(try store.browse(query: "Page 2").count, 1)
        XCTAssertEqual(try store.browse(query: "%' OR 1=1 --"), [])
        XCTAssertEqual(try store.browse(query: "\""), [])
        let personal = try HistoryStore(directory: root, profile: "personal")
        XCTAssertEqual(try personal.browse(), [])
        XCTAssertNil(try personal.stats().lastVisit)
    }
    func testSavedContentIsNotInventedAsAVisitAndRetainsSiteFiltering() throws {
        let store = try HistoryStore(directory: root, profile: "work")
        var content = page("Saved article", url: "https://sub.example.test:8443", seconds: 100)
        content.text = "Indexable text"
        try store.ingest(content)
        let hit = try XCTUnwrap(store.browse(host: "example.test").first)
        XCTAssertEqual(hit.isVisit, false)
        XCTAssertEqual(hit.record.seen, content.seen)
        XCTAssertNil(try store.stats().lastVisit)
        XCTAssertEqual(try store.browse(host: "ample.test"), [])
    }
    func testDeletingLastVisitRemovesItsContentAndDoesNotResurrectFromPreview() throws {
        let store = try HistoryStore(directory: root, profile: "work")
        let first = UUID().uuidString, second = UUID().uuidString
        try store.visit(id: first, record: page("First"))
        try store.visit(id: second, record: page("Second", seconds: 60))
        var content = page("Saved"); content.text = "Needle"; try store.ingest(content)
        try store.deleteVisit(id: first)
        XCTAssertEqual(try store.stats().records, 1)
        XCTAssertEqual(try store.browse().map(\.id), [second])
        try store.deleteVisit(id: second)
        try store.preview(id: second, data: Data([1]))
        XCTAssertEqual(try store.browse(), [])
        XCTAssertEqual(try store.stats().records, 0)
    }
    func testExclusionsAndClearRemoveVisitsAsWellAsCapturedContent() throws {
        let store = try HistoryStore(directory: root, profile: "work")
        for url in ["https://example.test", "https://sub.example.test", "https://notexample.test"] {
            var record = page("Saved", url: url)
            try store.visit(id: UUID().uuidString, record: record)
            record.text = "Contents"; try store.ingest(record)
        }
        try store.delete(host: "example.test")
        XCTAssertEqual(try store.stats().visits, 1)
        XCTAssertEqual(try store.stats().records, 1)
        try store.delete()
        XCTAssertEqual(try store.browse(), [])
        XCTAssertNil(try store.stats().lastVisit)
    }
    func testCapacityUsesCombinedLimitAndRemovesOldestAcrossBothKinds() throws {
        let store = try HistoryStore(directory: root, profile: "work")
        for i in 0..<6 {
            var record = page("Entry \(i)", url: "https://example.test/\(i)", seconds: Double(i))
            if i.isMultiple(of: 2) { try store.visit(id: UUID().uuidString, record: record) }
            else { record.text = "Content \(i)"; try store.ingest(record) }
        }
        try store.prune(days: 90, now: now, limit: 3)
        XCTAssertEqual(try store.browse().map(\.record.title), ["Entry 5", "Entry 4", "Entry 3"])
        XCTAssertEqual(try store.stats().capacityCleanup?.removedCount, 3)
        XCTAssertEqual(HistoryStats(records: 4500, bytes: 0, pending: 0, visits: 4500).capacityState, .nearLimit)
        try store.prune(days: 1, now: now.addingTimeInterval(2 * 86400))
        XCTAssertEqual(try store.stats().visits, 0)
        XCTAssertEqual(try store.stats().capacityCleanup?.removedCount, 3)
    }
    func testSelectionDeletionRollsBackEarlierVisitsWhenARecordDeleteFails() throws {
        let store = try HistoryStore(directory: root, profile: "work")
        let id = UUID().uuidString
        try store.visit(id: id, record: page("Visited"))
        var saved = page("Saved", url: "https://saved.test")
        saved.text = "Retained until deletion succeeds"
        try store.ingest(saved)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.path.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        let fail = "CREATE TRIGGER simulate_error BEFORE DELETE ON records BEGIN SELECT RAISE(ABORT, 'fixture'); END"
        XCTAssertEqual(sqlite3_exec(connection, fail, nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try store.delete(visits: [id], records: [saved.key]))
        XCTAssertEqual(Set(try store.browse().map(\.id)), [id, saved.key])
        XCTAssertEqual(sqlite3_exec(connection, "DROP TRIGGER simulate_error", nil, nil, nil), SQLITE_OK)
        try store.delete(visits: [id], records: [saved.key])
        XCTAssertTrue(try store.browse().isEmpty)
        XCTAssertTrue(try store.search("Retained", embedding: nil).isEmpty)
    }

    func testSiteDeletionNormalizesTheHostAndEscapesLikeWildcards() throws {
        let store = try HistoryStore(directory: root, profile: "work")
        for host in ["team_1.test", "sub.team_1.test", "teamX1.test"] {
            var row = page(host, url: "https://" + host)
            try store.visit(id: UUID().uuidString, record: row)
            row.text = "Test content"
            try store.ingest(row)
        }
        try store.delete(host: " TEAM_1.TEST ")
        XCTAssertEqual(try store.browse().map(\.record.title), ["teamX1.test"])
        XCTAssertEqual(try store.stats().records, 1)
    }

    func testLargeHistoryBrowseAndSiteDeletion() throws {
        let store = try HistoryStore(directory: root, profile: "bench")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.path.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let fixture = """
            BEGIN;
            WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<4500),
            pages AS (SELECT i, CASE WHEN i%9=0 THEN 'remove.example' ELSE 'keep.example' END AS host FROM n)
            INSERT INTO records(id,url,title,text,appearance,seen,image,host)
            SELECT 'p'||i,'https://'||host||'/'||i,'Fixture '||i,'Synthetic local page '||i,'',
                   unixepoch()-i,zeroblob(4096),host FROM pages;
            INSERT INTO visits(id,url,title,host,seen)
            SELECT printf('%08x-0000-4000-8000-%012x',rowid,rowid),url,title,host,seen FROM records;
            COMMIT;
            """
        XCTAssertEqual(sqlite3_exec(db, fixture, nil, nil, nil), SQLITE_OK)
        let benchmark = ProcessInfo.processInfo.environment["BOWSER_PERF"] == "1"
        var samples: [Double] = []
        for _ in 0..<(benchmark ? 25 : 1) {
            let start = ProcessInfo.processInfo.systemUptime
            try store.prune(days: 90)
            let hits = try store.browse()
            let stats = try store.stats()
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            XCTAssertEqual(hits.count, 60)
            XCTAssertEqual(stats.visits, 4500)
        }
        let start = ProcessInfo.processInfo.systemUptime
        try store.delete(host: "remove.example")
        let stats = try store.stats()
        let deletion = (ProcessInfo.processInfo.systemUptime - start) * 1000
        XCTAssertEqual(stats.visits, 4000)
        XCTAssertEqual(stats.records, 4000)
        if benchmark {
            samples.sort()
            print("History browse with retention and statistics (9,000 entries), p50=\(samples[12]) ms, p95=\(samples[23]) ms")
            print("History site deletion (1,000 entries), total=\(deletion) ms")
        }
    }
    func testDeletedGenerationRejectsLateWritesAndAllowsNewNavigation() async throws {
        let repository = HistoryRepository(directory: root)
        let id = UUID().uuidString
        let recent = HistoryRecord(url: "https://example.test", title: "Page", text: "")
        _ = try await repository.record(profile: "work", id: id, value: recent, days: 90, generation: 0)
        _ = try await repository.delete(profile: "work", all: true, generation: 1)
        let stale = try await repository.record(profile: "work", id: id, value: recent, days: 90, generation: 0)
        XCTAssertNil(stale)
        let (empty, _) = try await repository.browse(profile: "work")
        XCTAssertEqual(empty, [])
        let saved = try await repository.record(profile: "work", id: UUID().uuidString, value: recent, days: 90, generation: 1)
        XCTAssertEqual(saved?.visits, 1)
        await repository.invalidate(profile: "work", generation: 2)
        let paused = try await repository.record(profile: "work", id: UUID().uuidString, value: recent, days: 90, generation: 1)
        XCTAssertNil(paused)
    }
}
