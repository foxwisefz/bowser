import Foundation
import Synchronization
import XCTest
@testable import Bowser

final class SavedAppRegistryTests: XCTestCase {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var directory: URL { root.appendingPathComponent("Launchers") }
        var bowser: URL { root.appendingPathComponent("Engine.app") }
        var icons: URL { root.appendingPathComponent("Icons") }
        var source: URL { bowser.appendingPathComponent("Contents/MacOS/Bowser") }
        init() throws {
            let library = bowser.appendingPathComponent("Contents/Frameworks/libBowserSurfaceKit.dylib")
            for folder in [icons, source.deletingLastPathComponent(), library.deletingLastPathComponent()] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: source)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: library)
        }
        func changeEngine() throws {
            try FileManager.default.removeItem(at: source)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: source)
        }
        func verify(_ bundle: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["--verify", "--strict", bundle.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
    }

    @MainActor func testRefreshCoalescesAndOpensOnlyMatchingLaunchers() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspected = Mutex<[URL]>([])
        let signatures = Mutex(0)
        let registry = SavedAppRegistry(directory: fixture.directory, bowser: fixture.bowser, icons: fixture.icons,
            sign: { bundle in
                try SavedAppRegistry.signBundle(bundle)
                signatures.withLock { $0 += 1 }
            }, isRunning: { _ in false }, inspect: { bundle in
                XCTAssertFalse(Thread.isMainThread)
                inspected.withLock { $0.append(bundle) }
            })
        var matches = Set<URL>()
        for i in 0..<24 {
            if i == 12 { try fixture.changeEngine() }
            let page = URL(string: "https://site\(i < 3 ? 0 : i).test/page/\(i)")!
            let profile = i == 2 ? "personal" : "work"
            let bundle = try registry.export(url: page, profile: profile)
            if i < 2 { matches.insert(bundle) }
        }
        signatures.withLock { $0 = 0 }
        let clock = ContinuousClock()
        let start = clock.now
        registry.request(.all)
        let submission = start.duration(to: clock.now)
        await registry.flush()
        let elapsed = start.duration(to: clock.now)
        XCTAssertEqual(signatures.withLock { $0 }, 12)
        XCTAssertEqual(inspected.withLock { $0.count }, 24)
        inspected.withLock { $0.removeAll() }
        let currentStart = clock.now
        registry.request(.all)
        let currentSubmission = currentStart.duration(to: clock.now)
        await registry.flush()
        let currentElapsed = currentStart.duration(to: clock.now)
        XCTAssertEqual(inspected.withLock { $0.count }, 24)
        XCTAssertEqual(signatures.withLock { $0 }, 12)
        inspected.withLock { $0.removeAll() }
        let key = TabAppBundle.iconKey(url: URL(string: "https://site0.test:443/another")!, profile: "work")
        try Data("icns-fixture".utf8).write(to: fixture.icons.appendingPathComponent(key + ".icns"))
        let iconStart = clock.now
        for _ in 0..<100 { registry.request(.icon(key)) }
        let iconSubmission = iconStart.duration(to: clock.now)
        await registry.flush()
        XCTAssertEqual(inspected.withLock { $0.count }, matches.count)
        XCTAssertEqual(Set(inspected.withLock { $0 }), matches)
        XCTAssertEqual(signatures.withLock { $0 }, 14)
        for app in matches { try fixture.verify(app) }
        print("24 saved launchers (12 stale) main submission \(submission), worker completion \(elapsed); "
            + "24 current submission \(currentSubmission), completion \(currentElapsed); "
            + "100 same-origin notifications submission \(iconSubmission), inspected 2 launchers")
    }

    @MainActor func testFailedSigningAndRelaunchDuringSigningLeavePinnedAppIntact() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        enum Mode { case normal, fail, pause }
        let mode = Mutex(Mode.normal)
        let running = Mutex(false)
        let signing = expectation(description: "staged candidate reached codesign")
        let resume = DispatchSemaphore(value: 0)
        let registry = SavedAppRegistry(directory: fixture.directory, bowser: fixture.bowser, icons: fixture.icons,
            sign: { bundle in
                XCTAssertFalse(Thread.isMainThread)
                try SavedAppRegistry.signBundle(bundle)
                switch mode.withLock({ $0 }) {
                case .normal: break
                case .fail: throw CocoaError(.executableNotLoadable)
                case .pause:
                    signing.fulfill()
                    XCTAssertEqual(resume.wait(timeout: .now() + 5), .success)
                }
            }, isRunning: { _ in running.withLock { $0 } })
        let page = URL(string: "https://pin.test/")!
        let bundle = try registry.export(url: page, profile: "work")
        let live = bundle.appendingPathComponent("Contents/MacOS/launch")
        let originalBinary = try Data(contentsOf: live)
        let originalInfo = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        let originalInode = try FileManager.default.attributesOfItem(atPath: bundle.path)[.systemFileNumber] as? NSNumber
        try fixture.changeEngine()
        mode.withLock { $0 = .fail }
        registry.request(.bundle(bundle))
        await registry.flush()
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")), originalInfo)
        XCTAssertEqual(try Data(contentsOf: live), originalBinary)
        try fixture.verify(bundle)

        mode.withLock { $0 = .pause }
        registry.request(.bundle(bundle))
        await fulfillment(of: [signing], timeout: 5)
        XCTAssertEqual(try registry.export(url: page, profile: "work"), bundle)
        XCTAssertEqual(try Data(contentsOf: live), originalBinary)
        running.withLock { $0 = true }
        resume.signal()
        await registry.flush()
        XCTAssertEqual(try Data(contentsOf: live), originalBinary)
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")), originalInfo)
        try fixture.verify(bundle)

        running.withLock { $0 = false }
        mode.withLock { $0 = .normal }
        registry.request(.bundle(bundle))
        await registry.flush()
        XCTAssertNotEqual(try Data(contentsOf: live), originalBinary)
        let newInode = try FileManager.default.attributesOfItem(atPath: bundle.path)[.systemFileNumber] as? NSNumber
        XCTAssertNotNil(originalInode)
        XCTAssertEqual(originalInode, newInode)
        try fixture.verify(bundle)
    }

    func testConcurrentFirstExportsFromIndependentRegistriesSignOnce() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let signed = Mutex(0)
        let signer: SavedAppRegistry.Signer = { bundle in
            try SavedAppRegistry.signBundle(bundle)
            signed.withLock { $0 += 1 }
        }
        let a = SavedAppRegistry(directory: fixture.directory, bowser: fixture.bowser, icons: fixture.icons, sign: signer)
        let b = SavedAppRegistry(directory: fixture.directory, bowser: fixture.bowser, icons: fixture.icons, sign: signer)
        let page = URL(string: "https://race.test/page")!
        let paths = try await withThrowingTaskGroup(of: URL.self) { group in
            for registry in [a, b] { group.addTask { try registry.export(url: page, profile: "work") } }
            var results = [URL]()
            for try await path in group { results.append(path) }
            return results
        }
        await a.flush()
        await b.flush()
        XCTAssertEqual(Set(paths).count, 1)
        XCTAssertEqual(signed.withLock { $0 }, 1)
        try fixture.verify(try XCTUnwrap(paths.first))
    }
}
