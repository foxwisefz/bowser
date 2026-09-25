import AppKit
import XCTest
@testable import Bowser

@MainActor final class InstalledInstanceTests: XCTestCase {
    private func progress(_ phase: String, bundle: String, modified: Date? = nil) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("progress.json")
        try JSONSerialization.data(withJSONObject: ["phase": phase, "bundle": bundle, "stage": "/tmp/stage"]).write(to: file)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
        return file
    }

    private func cleanup(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func testCompletionWrittenAfterLaunchStartedRelaunches() throws {
        let started = Date().addingTimeInterval(-5)
        let file = try progress("complete", bundle: "/Applications/Bowser.app")
        defer { cleanup(file) }
        XCTAssertTrue(InstalledInstance.updateCompleted(for: URL(fileURLWithPath: "/Applications/Bowser.app"), since: started, progress: file))
    }

    func testStaleCompletionFromAnEarlierUpdateDoesNotRelaunch() throws {
        let started = Date()
        let file = try progress("complete", bundle: "/Applications/Bowser.app", modified: started.addingTimeInterval(-60))
        defer { cleanup(file) }
        XCTAssertFalse(InstalledInstance.updateCompleted(for: URL(fileURLWithPath: "/Applications/Bowser.app"), since: started, progress: file))
    }

    func testCompletionForAnotherBundleDoesNotRelaunch() throws {
        let started = Date().addingTimeInterval(-5)
        let file = try progress("complete", bundle: "/Applications/Bowser.app")
        defer { cleanup(file) }
        XCTAssertFalse(InstalledInstance.updateCompleted(for: URL(fileURLWithPath: "/Applications/Bowser-staging.app"), since: started, progress: file))
    }

    func testUnfinishedAndMissingProgressDoNotRelaunch() throws {
        let started = Date().addingTimeInterval(-5)
        let file = try progress("waiting", bundle: "/Applications/Bowser.app")
        defer { cleanup(file) }
        let bundle = URL(fileURLWithPath: "/Applications/Bowser.app")
        XCTAssertFalse(InstalledInstance.updateCompleted(for: bundle, since: started, progress: file))
        XCTAssertFalse(InstalledInstance.updateCompleted(for: bundle, since: started, progress: file.deletingLastPathComponent().appendingPathComponent("absent.json")))
    }
}
