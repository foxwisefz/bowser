import XCTest
import BowserSurfaceKit

@MainActor final class ModScopeChoiceTests: XCTestCase {
    func testRecommendationManualOverrideAndStaleResponses() async throws {
        let choice = ModScopeChoice()
        choice.reset(url: "https://example.com/private?token=secret")
        var requests: [(String, String, String)] = []
        choice.request = { requests.append(($0, $1, $2)) }
        choice.update("Organize tabs")
        try await Task.sleep(for: .milliseconds(450))
        let first = try XCTUnwrap(requests.first)
        XCTAssertEqual(first.2, "example.com")
        choice.update("Hide sidebar")
        choice.receive(id: first.0, choice: "browser")
        XCTAssertEqual(choice.selected, "site")
        try await Task.sleep(for: .milliseconds(450))
        let second = try XCTUnwrap(requests.last)
        choice.receive(id: second.0, choice: "browser")
        XCTAssertEqual(choice.suggested, "browser")
        choice.choose("site")
        choice.update("Organize all tabs")
        choice.receive(id: second.0, choice: "browser")
        XCTAssertEqual(choice.selected, "site")
        XCTAssertTrue(choice.manual)
    }
    func testSubmissionFreezesSelectionAndTimeoutRetainsDefault() async throws {
        let choice = ModScopeChoice()
        choice.reset(url: "https://example.com")
        var id = ""
        choice.request = { requestID, _, _ in id = requestID }
        choice.update("Organize tabs")
        try await Task.sleep(for: .milliseconds(450))
        choice.freeze()
        choice.receive(id: id, choice: "browser")
        XCTAssertEqual(choice.selected, "site")
        choice.reset(url: "https://example.com")
        choice.update("Organize tabs")
        try await Task.sleep(for: .milliseconds(2500))
        XCTAssertFalse(choice.checking)
        choice.receive(id: id, choice: "browser")
        XCTAssertEqual(choice.selected, "site")
        choice.reset(url: "about:blank")
        XCTAssertFalse(choice.valid)
        choice.choose("browser")
        XCTAssertTrue(choice.valid)
    }
}
