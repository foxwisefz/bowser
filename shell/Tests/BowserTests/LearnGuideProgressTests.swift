import XCTest
@testable import Bowser

@MainActor final class LearnGuideProgressTests: XCTestCase {
    func testOnlyExactServiceExerciseURLsAreAllowed() {
        let base = URL(string: "http://127.0.0.1:8080")!
        XCTAssertTrue(LearnGuideProgress.isLearnPage(base.appendingPathComponent("learn/slopshop"), service: base))
        for url in ["http://127.0.0.1:9090/learn/slopshop", "https://evil.test/learn/slopshop", "http://127.0.0.1:8080/learn", "http://user@127.0.0.1:8080/learn/quiet"] {
            XCTAssertFalse(LearnGuideProgress.isLearnPage(URL(string: url)!, service: base))
        }
    }

    func testProgressBelongsToSubmittedProjectAndOmitsPrivateDetails() throws {
        let bridge = LearnGuideProgress()
        var updates: [[String: String]] = []
        bridge.deliver = { id, _, state in XCTAssertEqual(id, 7); updates.append(state) }
        bridge.begin(request: "request", webview: 7, url: BowserAPI.base.appendingPathComponent("learn/slopshop").absoluteString)
        XCTAssertEqual(updates.last?["status"], "working")
        func snapshot(_ status: String, accepted: String = "request", id: String = "project") throws -> ModSmithSnapshot {
            let data: [String: Any] = ["accepted": accepted, "selected": id, "busy": status == "working", "progress": ["private prompt"], "stage": "Checking the page", "projects": [["id": id, "name": "private name", "scope": "site", "url": "private URL", "status": status, "summary": "private summary", "turns": [], "files": [], "enabled": true, "can_undo": false]]]
            return try JSONDecoder().decode(ModSmithSnapshot.self, from: JSONSerialization.data(withJSONObject: data))
        }
        bridge.receive(try snapshot("active", accepted: "other", id: "other"))
        XCTAssertEqual(updates.count, 1)
        for status in ["working", "active", "failed", "interrupted"] {
            bridge.receive(try snapshot(status))
            XCTAssertEqual(updates.last?["status"], status)
            XCTAssertEqual(Set(updates.last!.keys), ["status", "label"])
            XCTAssertFalse(updates.last!.values.contains { $0.contains("private") })
        }
    }
}
