import XCTest
import HistoryCore
@testable import Bowser

final class HistoryWorkerClientTests: XCTestCase {
    func testCleanupNoticeCrossesHelperBoundaryAndClearResetsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-notice-client-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let store = try HistoryStore(directory: directory, profile: "test")
            for i in 0..<3 { try store.ingest(HistoryRecord(url: "https://fixture.test/\(i)", title: "Fixture", text: "Saved item \(i)")) }
            try store.prune(days: 90, limit: 1)
        }
        let shell = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let client = HistoryWorkerClient(directory: directory, model: directory.appendingPathComponent("absent-model"), executable: shell.appendingPathComponent(".build/debug/BowserHistoryWorker"))
        defer { client.stop() }
        let stats = try await client.send(HistoryRequest("stats", profile: "test"))
        XCTAssertEqual(stats.stats?.capacityCleanup?.removedCount, 2)
        client.stop()
        let restarted = try await client.send(HistoryRequest("stats", profile: "test"))
        XCTAssertEqual(restarted.stats?.capacityCleanup, stats.stats?.capacityCleanup)
        let other = try await client.send(HistoryRequest("stats", profile: "other"))
        XCTAssertNil(other.stats?.capacityCleanup)
        let cleared = try await client.send(HistoryRequest("delete", profile: "test"))
        XCTAssertNil(cleared.stats?.capacityCleanup)
    }
    func testPipeClientRoundTripRestartAndClearWithoutModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-client-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = shell.appendingPathComponent(".build/debug/BowserHistoryWorker")
        let client = HistoryWorkerClient(directory: directory, model: directory.appendingPathComponent("absent-model"), executable: executable)
        defer { client.stop() }
        let page = HistoryRecord(url: "https://fixture.test/origin", title: "A network service", text: "Global network", appearance: "orange accents")
        let captured = try await client.send(HistoryRequest("capture", profile: "test", record: page))
        XCTAssertNil(captured.error)
        let found = try await client.send(HistoryRequest("search", profile: "test", query: "orange website"))
        XCTAssertEqual(found.hits.first?.record.url, page.url)
        client.stop()
        let restarted = try await client.send(HistoryRequest("stats", profile: "test"))
        XCTAssertEqual(restarted.stats?.records, 1)
        _ = try await client.send(HistoryRequest("delete", profile: "test"))
        let cleared = try await client.send(HistoryRequest("search", profile: "test", query: "orange"))
        XCTAssertTrue(cleared.hits.isEmpty)
    }
}
