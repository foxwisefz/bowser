import XCTest
@testable import Bowser

final class TelemetryTests: XCTestCase {
    @MainActor
    func testUsageExcludesDevelopmentStagingAndSavedApps() {
        XCTAssertFalse(AppUsage.eligible(bundleID: nil, channel: nil))
        XCTAssertFalse(AppUsage.eligible(bundleID: "com.foxwiseai.bowser", channel: "staging"))
        XCTAssertFalse(AppUsage.eligible(bundleID: "com.foxwiseai.bowser.site.0123456789abcdef", channel: nil))
    }
    func testUsageIdentitySurvivesRelaunchAndActivityRequiresAuthentication() async throws {
        let dir = directory(), endpoint = URL(string: "http://127.0.0.1:8080/v1/events")!
        let client = Telemetry(directory: dir, endpoint: endpoint) { _ in 503 }
        await client.recordUsage("app_open", phase: "onboarding")
        await client.recordUsage("app_active")
        let before = await client.pending()
        XCTAssertEqual(before.count, 1)
        let restored = Telemetry(directory: dir, endpoint: endpoint) { _ in 503 }
        await restored.start(token: "fixture")
        await restored.recordUsage("app_open", phase: "activated")
        let date = Date()
        await restored.recordUsage("app_active", at: date)
        await restored.recordUsage("app_active", at: date)
        await restored.recordUsage("app_active", at: date.addingTimeInterval(86400))
        let events = await restored.pending()
        XCTAssertEqual(events.filter { $0.name == "app_active" }.count, 2)
        let opens = events.filter { $0.name == "app_open" }
        XCTAssertEqual(opens.count, 2)
        XCTAssertEqual(opens[0].properties["installationID"], opens[1].properties["installationID"])
        XCTAssertNotNil(UUID(uuidString: opens[0].properties["installationID"] ?? ""))
    }
    func testExpiredAuthenticationNeverDowngradesActivityToAnonymous() async throws {
        let capture = Capture()
        let client = Telemetry(directory: directory(), endpoint: URL(string: "https://example.invalid")) { await capture.send($0) }
        await client.start(token: "expired")
        await capture.rejectAuthentication()
        await client.recordUsage("app_active")
        await client.flush()
        let requests = await capture.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer expired")
        await capture.succeed()
        await client.start(token: "restored")
        let pending = await client.pending()
        XCTAssertTrue(pending.isEmpty)
    }
    func testSavedAppsUseSeparateQueues() {
        let home = URL(fileURLWithPath: "/tmp/fixture")
        let main = Telemetry.queueDirectory(home: home, bundleID: "com.foxwiseai.bowser")
        let first = Telemetry.queueDirectory(home: home, bundleID: "com.foxwiseai.bowser.site.0123456789abcdef")
        let second = Telemetry.queueDirectory(home: home, bundleID: "com.foxwiseai.bowser.site.1123456789abcdef")
        XCTAssertNotEqual(main, first)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Telemetry.queueDirectory(home: home, bundleID: "../../private"), main)
    }
    actor Capture {
        var status = 503
        var requests: [URLRequest] = []
        func send(_ request: URLRequest) -> Int { requests.append(request); return status }
        func succeed() { status = 202 }
        func rejectAuthentication() { status = 401 }
        func bodies() -> [Data] { requests.compactMap(\.httpBody) }
    }
    func directory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    func testRetryKeepsIDsAndPersistsOnlyAllowedFields() async throws {
        let capture = Capture(), dir = directory()
        let client = Telemetry(directory: dir, endpoint: URL(string: "https://example.invalid/v1/events")) { await capture.send($0) }
        let event = TelemetryEvent.modsmith(.refine, .failed)
        await client.record(event)
        let before = await client.pending()
        XCTAssertEqual(before, [event])
        let restored = Telemetry(directory: dir, endpoint: nil)
        let disk = await restored.pending()
        XCTAssertEqual(disk, before)
        await capture.succeed(); await client.flush()
        let after = await client.pending()
        XCTAssertTrue(after.isEmpty)
        let bodies = await capture.bodies()
        XCTAssertEqual(bodies.count, 2)
        for body in bodies {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let events = try XCTUnwrap(json["events"] as? [[String: Any]])
            XCTAssertEqual(events[0]["eventID"] as? String, event.eventID.uuidString)
            let properties = try XCTUnwrap(events[0]["properties"] as? [String: String])
            XCTAssertEqual(Set(properties.keys), ["operation", "outcome", "failureCategory", "appVersion", "appBuild"])
        }
    }
    func testQueueBoundAndInvalidOrDisabledEventsNeverSend() async {
        let client = Telemetry(directory: directory(), endpoint: URL(string: "https://example.invalid")) { _ in 503 }
        for _ in 0..<110 { await client.record(.crash(.native)) }
        let queued = await client.pending(); XCTAssertEqual(queued.count, 100)
        await client.record(TelemetryEvent(eventID: UUID(), name: "page_view", occurredAt: Date(), properties: ["url": "private"]))
        let unchanged = await client.pending(); XCTAssertEqual(unchanged.count, 100)
        let disabled = Telemetry(directory: directory(), endpoint: nil) { _ in XCTFail("Disabled sender"); return 202 }
        await disabled.record(.crash(.native)); let empty = await disabled.pending(); XCTAssertTrue(empty.isEmpty)
    }
}
