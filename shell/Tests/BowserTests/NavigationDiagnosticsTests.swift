import XCTest
import AppKit
@testable import Bowser

final class NavigationDiagnosticsTests: XCTestCase {
    @MainActor func testDelegateFailurePersistsSanitizedRecord() async throws {
        guard let home = ProcessInfo.processInfo.environment["BOWSER_HOME"],
              home.hasPrefix("/tmp/bowser-nav-") else {
            throw XCTSkip("Run with an isolated /tmp/bowser-nav-* BOWSER_HOME")
        }
        _ = NSApplication.shared
        let engine = EngineView(frame: .zero)
        let file = BowserPaths.home.appendingPathComponent("diagnostics/navigation-failures.jsonl")
        let secret = "sensitive-search-and-cookie"
        engine.webView(engine.webView, didFail: nil, withError: NSError(
            domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: secret]))
        var text = ""
        for _ in 0..<100 {
            text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            if text.contains("after_commit") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(text.contains("after_commit"))
        XCTAssertTrue(text.contains("-1001"))
        XCTAssertFalse(text.contains(secret))
    }

    func testTimingNetworkChangesAndStaleNavigation() throws {
        var trace = NavigationDiagnosticTrace()
        let first = NSObject(), next = NSObject()
        trace.start(first, now: 100, network: .init(status: "satisfied"), revision: 2)
        trace.redirect(first)
        let failure = trace.failure(first, error: NSError(domain: NSURLErrorDomain, code: -1001),
            stage: "before_commit", now: 160, network: .init(status: "unsatisfied"), revision: 3)
        XCTAssertEqual(failure.elapsedMilliseconds, 60_000)
        XCTAssertEqual(failure.redirects, 1)
        XCTAssertEqual(failure.networkUpdates, 1)
        XCTAssertEqual(failure.networkAtStart.status, "satisfied")
        XCTAssertEqual(failure.networkAtFailure.status, "unsatisfied")
        trace.start(next, now: 165, network: .init(), revision: 4)
        let stale = trace.failure(first, error: NSError(domain: NSURLErrorDomain, code: -1001),
            stage: "before_commit", now: 170, network: .init(), revision: 4)
        XCTAssertNil(stale.elapsedMilliseconds)
        XCTAssertEqual(stale.networkAtStart.status, "unknown")
    }

    func testErrorSerializationExcludesPrivateDetails() throws {
        let secret = "https://user:password@example.com/search?q=private"
        let error = NSError(domain: NSURLErrorDomain, code: -1001, userInfo: [
            NSLocalizedDescriptionKey: secret, NSURLErrorFailingURLStringErrorKey: secret,
            NSUnderlyingErrorKey: NSError(domain: secret, code: 42)])
        let errors = NavigationDiagnosticError.chain(error)
        let json = String(decoding: try JSONEncoder().encode(errors), as: UTF8.self)
        XCTAssertFalse(json.contains("private")); XCTAssertFalse(json.contains("password"))
        XCTAssertEqual(errors.map(\.domain), [NSURLErrorDomain, "other"])
        XCTAssertEqual(errors.map(\.code), [-1001, 42])
    }

    @MainActor func testRealNavigationPersistsCorrelatedLifecycleAndResponse() async throws {
        guard ProcessInfo.processInfo.environment["BOWSER_HOME"]?.hasPrefix("/tmp/bowser-nav-") == true else {
            throw XCTSkip("Requires isolated diagnostics home")
        }
        _ = NSApplication.shared
        let server = try BrowserFixtureServer()
        defer { server.stop() }
        for _ in 0..<100 where server.origin == nil { try await Task.sleep(for: .milliseconds(20)) }
        let engine = EngineView(frame: .zero)
        engine.load(urlString: try XCTUnwrap(server.origin) + "/page")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let file = BowserPaths.home.appendingPathComponent("diagnostics/navigation-failures.jsonl")
        var records: [NavigationDiagnosticRecord] = []
        for _ in 0..<250 {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            records = text.split(separator: "\n").compactMap {
                try? decoder.decode(NavigationDiagnosticRecord.self, from: Data($0.utf8))
            }.filter { $0.webviewID == engine.webviewId }
            if records.contains(where: { $0.stage == "finished" }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let start = try XCTUnwrap(records.first { $0.stage == "started" })
        let response = try XCTUnwrap(records.first { $0.stage == "response" })
        let commit = try XCTUnwrap(records.first { $0.stage == "committed" })
        let finish = try XCTUnwrap(records.first { $0.stage == "finished" })
        XCTAssertEqual(response.httpStatus, 200)
        for record in [response, commit, finish] {
            XCTAssertEqual(record.navigationID, start.navigationID)
            XCTAssertEqual(record.profileID, engine.profileId)
            XCTAssertNotNil(record.elapsedMilliseconds)
        }
    }

    func testLifecycleCorrelationAndNewNavigationIsolation() throws {
        var trace = NavigationDiagnosticTrace()
        let first = NSObject(), next = NSObject()
        trace.start(first, now: 100, network: .init(status: "satisfied"), revision: 1)
        let start = trace.event(first, stage: "started", now: 100, network: .init(), revision: 1)
        let slow = trace.event(first, stage: "still_loading", now: 110, network: .init(), revision: 2)
        let response = trace.event(stage: "response", now: 112, network: .init(), revision: 2)
        let finish = trace.event(first, stage: "finished", now: 113, network: .init(), revision: 2)
        XCTAssertEqual(start.navigationID, slow.navigationID)
        XCTAssertEqual(slow.navigationID, response.navigationID)
        XCTAssertEqual(response.navigationID, finish.navigationID)
        XCTAssertEqual(slow.elapsedMilliseconds, 10_000)
        XCTAssertEqual(finish.elapsedMilliseconds, 13_000)
        XCTAssertEqual(slow.networkUpdates, 1)
        trace.start(next, now: 120, network: .init(), revision: 2)
        let stale = trace.event(first, stage: "finished", now: 121, network: .init(), revision: 2)
        XCTAssertNil(stale.elapsedMilliseconds)
        let current = trace.event(next, stage: "started", now: 120, network: .init(), revision: 2)
        XCTAssertNotEqual(start.navigationID, current.navigationID)
    }

    func testStreamErrorEvidenceUsesOnlyNumericFields() throws {
        let error = NSError(domain: NSURLErrorDomain, code: -1001, userInfo: [
            "_kCFStreamErrorDomainKey": 4, "_kCFStreamErrorCodeKey": -2102,
            "arbitrary": "private", NSLocalizedDescriptionKey: "private"])
        let chain = NavigationDiagnosticError.chain(error)
        XCTAssertEqual(chain.first?.streamErrorDomain, 4)
        XCTAssertEqual(chain.first?.streamErrorCode, -2102)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(chain), as: UTF8.self).contains("private"))
    }

    func testLogRotatesAndRestrictsPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for n in 1...3 { try NavigationDiagnosticLog.append(Data("{\"n\":\(n)}".utf8), directory: root, limit: 10) }
        let current = root.appendingPathComponent("navigation-failures.jsonl")
        let previous = root.appendingPathComponent("navigation-failures.previous.jsonl")
        XCTAssertEqual(try String(contentsOf: current, encoding: .utf8), "{\"n\":3}\n")
        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "{\"n\":2}\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: current.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
}
