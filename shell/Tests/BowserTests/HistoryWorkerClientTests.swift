import XCTest
import HistoryCore
@testable import Bowser

final class HistoryWorkerClientTests: XCTestCase {
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
