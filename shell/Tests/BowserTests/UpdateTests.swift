import XCTest
import CryptoKit
import AppKit
import BowserSurfaceKit
@testable import Bowser

final class UpdateTests: XCTestCase {
    let key = Curve25519.Signing.PrivateKey()
    func envelope(build: String = "200", url: String? = nil, expiry: Date = Date().addingTimeInterval(3600), os: Int = 15) throws -> Data {
        let release = UpdateRelease(version: "test", build: build, minimumMacOS: os, url: URL(string: url ?? "https://assets.bowser.app/releases/\(build)/Bowser.dmg")!, bytes: 3,
            sha256: SHA256.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined(), expiresAt: expiry)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(release)
        return try JSONSerialization.data(withJSONObject: ["payload": payload.base64EncodedString(), "signature": key.signature(for: payload).base64EncodedString()])
    }
    func verify(_ data: Data, key supplied: Data? = nil) throws -> UpdateRelease? {
        try UpdateRelease.verified(data, publicKey: supplied ?? key.publicKey.rawRepresentation, currentBuild: "100", osMajor: 15)
    }
    func testSignedUpgradeRejectsWrongKeyTamperingExpiryAndWrongOrigin() throws {
        XCTAssertNotNil(try verify(envelope()))
        XCTAssertNil(try verify(envelope(build: "99")))
        XCTAssertNil(try verify(envelope(build: "100")))
        XCTAssertThrowsError(try verify(envelope(), key: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        for url in ["http://api.bowser.app/updates/Bowser.dmg", "https://evil.invalid/update", "https://assets.bowser.app/releases/999/Bowser.dmg", "https://assets.bowser.app/releases/200/Bowser.dmg?x=1", "https://api.bowser.app/updates/Bowser.dmg", "https://bowser.app/updates/Bowser.dmg", "https://www.bowser.app/updates/Bowser.dmg", "https://user@api.bowser.app/file"] {
            XCTAssertThrowsError(try verify(envelope(url: url)))
        }
        XCTAssertThrowsError(try verify(envelope(expiry: Date().addingTimeInterval(-1))))
        XCTAssertThrowsError(try verify(envelope(os: 99)))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: envelope()) as? [String: String])
        json["payload"] = Data("tampered".utf8).base64EncodedString()
        XCTAssertThrowsError(try verify(JSONSerialization.data(withJSONObject: json)))
    }
    func testImageHashAndSizeMustMatchSignedManifest() throws {
        let release = try XCTUnwrap(verify(envelope()))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file); XCTAssertNoThrow(try release.verifyFile(file))
        try Data("xyz".utf8).write(to: file); XCTAssertThrowsError(try release.verifyFile(file))
        try Data("abcd".utf8).write(to: file); XCTAssertThrowsError(try release.verifyFile(file))
    }
    func testPreparedBuildPreventsRepeatDownloadWithoutHidingNewerInstalledBuild() {
        XCTAssertEqual(AppUpdates.latestBuild("100", "200"), "200")
        XCTAssertEqual(AppUpdates.latestBuild("300", "200"), "300")
        XCTAssertEqual(AppUpdates.latestBuild("100", nil), "100")
        XCTAssertEqual(AppUpdates.latestBuild("100", "invalid"), "100")
    }

    func testDevelopmentCheckReadsFingerprintAndRejectsFailedOrMalformedResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = bin.appendingPathComponent("development-fingerprint")
        let expected = String(repeating: "a", count: 64)
        for (output, exitCode) in [(expected, 0), ("", 0), ("not-a-fingerprint", 0), (expected, 1)] {
            try "#!/bin/sh\nprintf '%s\\n' '\(output)'\nexit \(exitCode)\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            do {
                let actual = try await AppUpdates.developmentFingerprint(checkout: root.path)
                XCTAssertEqual(exitCode, 0)
                XCTAssertEqual(output, expected)
                XCTAssertEqual(actual, expected)
            } catch {
                XCTAssertTrue(exitCode != 0 || output != expected)
            }
        }
    }

    func testModulesPublishVerifiedCopiesAndLeavePointerOnVerificationFailure() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let app = home.appendingPathComponent("app.bundle")
        let build = String(repeating: "a", count: 32)
        for (name, identifier) in [("SurfaceRenderer", "surfaces"), ("CommandToolbar", "command-toolbar")] {
            let contents = app.appendingPathComponent("Contents/Resources/\(name).bundle/Contents")
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "com.foxwiseai.bowser." + identifier, "CFBundleVersion": build]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        // Real verification must reject the unsigned fixture before publishing anything.
        XCTAssertThrowsError(try UpdateInstaller.publishModules(from: app, home: home))
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent("native-modules/surfaces/current").path))
        var verified: [URL] = []
        try UpdateInstaller.publishModules(from: app, home: home) { verified.append($0) }
        XCTAssertEqual(verified.count, 4) // Source and copied generation for both modules.
        for kind in ["surfaces", "command-toolbar"] {
            let root = home.appendingPathComponent("native-modules/" + kind)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("current"), encoding: .utf8), build + "\n")
            XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent(build + ".bundle/Contents/Info.plist").path))
        }
        XCTAssertThrowsError(try UpdateInstaller.publishModules(from: app, home: home) { _ in throw UpdateError.invalidRelease })
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("native-modules/surfaces/current"), encoding: .utf8), build + "\n")
        verified = []
        try UpdateInstaller.publishModules(from: app, home: home) { verified.append($0) }
        XCTAssertEqual(verified.count, 4) // Retry validates existing immutable generations too.
        let staging = home.appendingPathComponent("staging.app")
        try fm.copyItem(at: app, to: staging)
        try PropertyListSerialization.data(fromPropertyList: ["BowserChannel": "staging"], format: .xml, options: 0)
            .write(to: staging.appendingPathComponent("Contents/Info.plist"))
        try UpdateInstaller.publishModules(from: staging, home: home) { _ in }
        for kind in ["surfaces", "command-toolbar"] {
            XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("native-modules/staging/" + kind + "/current"), encoding: .utf8), build + "\n")
            XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("native-modules/" + kind + "/current"), encoding: .utf8), build + "\n")
        }
    }

    @MainActor func testUpdateMenuTargetsTheUpdaterAndExposesItsAction() throws {
        _ = NSApplication.shared
        let updater = AppUpdates.shared
        let menus = NativeUIPresentation.menus(NativeMenuContext(target: NSObject(), siteHost: nil,
            targets: ["updates": updater], siteActions: []))
        let item = try XCTUnwrap(menus.main.items.first?.submenu?.items.first { $0.action == NSSelectorFromString("checkForUpdates:") })
        XCTAssertTrue(item.target === updater)
        XCTAssertTrue(updater.responds(to: try XCTUnwrap(item.action)))
        menus.main.items.first?.submenu?.update()
        XCTAssertTrue(item.isEnabled)
    }

    func testLiveCompletionRequiresMatchingHostAndActualComponentAdoption() {
        let host = String(repeating: "a", count: 64)
        func status(_ running: String? = nil, _ incoming: String? = nil,
                    backend: Bool = true, modules: Bool = true, age: Double = 120, live: Bool = true) -> PreparedUpdateStatus {
            PreparedUpdateStatus.evaluate(liveAllowed: live, runningHost: running, incomingHost: incoming,
                backendApplied: backend, modulesApplied: modules, age: age)
        }
        XCTAssertEqual(status(host, host), .live)
        XCTAssertEqual(status(host, host, live: false), .restart)
        XCTAssertEqual(status(), .restart) // Legacy releases cannot claim live completion.
        XCTAssertEqual(status("bad", "bad"), .restart)
        XCTAssertEqual(status(host, String(repeating: "b", count: 64)), .restart)
        XCTAssertEqual(status(host, host, backend: false), .restart)
        XCTAssertEqual(status(host, host, modules: false), .restart)
        XCTAssertEqual(status(host, host, modules: false, age: 10), .applying)
        XCTAssertEqual(status(host, host, backend: false, age: 10), .applying)
        XCTAssertEqual(status(host, host, age: 10), .live)
    }

}
