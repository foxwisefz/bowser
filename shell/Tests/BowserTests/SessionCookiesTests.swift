import XCTest
import WebKit
@testable import Bowser

final class SessionCookiesTests: XCTestCase {
    @MainActor func testCleanRestartPreservesSessionCookiesPerStoreAndConsumesSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("cookies.plist")
        defer { try? FileManager.default.removeItem(at: directory) }
        let personal = WKWebsiteDataStore.nonPersistent(), work = WKWebsiteDataStore.nonPersistent()
        func cookie(_ value: String, persistent: Bool = false) throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.domain: "restart.test", .path: "/", .name: "login", .value: value,
                .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE"]
            if persistent { properties[.expires] = Date().addingTimeInterval(3600) }
            return try XCTUnwrap(HTTPCookie(properties: properties))
        }
        await personal.httpCookieStore.setCookie(try cookie("personal"))
        await work.httpCookieStore.setCookie(try cookie("work"))
        let original = ["default": personal, "work-uuid": work]
        try await SessionCookies.save(to: file, stores: original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        let restoredPersonal = WKWebsiteDataStore.nonPersistent(), restoredWork = WKWebsiteDataStore.nonPersistent()
        try await SessionCookies.restore(from: file, stores: ["default": restoredPersonal, "work-uuid": restoredWork])
        let personalCookies = await restoredPersonal.httpCookieStore.allCookies()
        let workCookies = await restoredWork.httpCookieStore.allCookies()
        XCTAssertEqual(personalCookies.map(\.value), ["personal"])
        XCTAssertEqual(workCookies.map(\.value), ["work"])
        XCTAssertTrue(try XCTUnwrap(workCookies.first).isSessionOnly)
        XCTAssertTrue(try XCTUnwrap(workCookies.first).isSecure)
        XCTAssertTrue(try XCTUnwrap(workCookies.first).isHTTPOnly)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        // A later quit replaces the snapshot; logged-out cookies aren't resurrected.
        for cookie in await work.httpCookieStore.allCookies() { await work.httpCookieStore.delete(cookie) }
        await personal.httpCookieStore.setCookie(try cookie("persistent", persistent: true))
        try await SessionCookies.save(to: file, stores: original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let empty = WKWebsiteDataStore.nonPersistent()
        try await SessionCookies.restore(from: file, stores: ["default": empty, "work-uuid": empty])
        let emptyCookies = await empty.httpCookieStore.allCookies()
        XCTAssertTrue(emptyCookies.isEmpty)
    }

    @MainActor func testRestoreKeepsNewerCookiesAndDoesNotMoveDeletedProfileCookies() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("cookies.plist")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = WKWebsiteDataStore.nonPersistent(), destination = WKWebsiteDataStore.nonPersistent()
        for (store, value) in [(source, "old"), (destination, "new")] {
            await store.httpCookieStore.setCookie(try XCTUnwrap(HTTPCookie(properties: [.domain: "restart.test", .path: "/", .name: "login", .value: value])))
        }
        try await SessionCookies.save(to: file, stores: ["existing": source, "deleted-uuid": source])
        let newProfile = WKWebsiteDataStore.nonPersistent()
        try await SessionCookies.restore(from: file, stores: ["existing": destination, "new-uuid": newProfile])
        let cookies = await destination.httpCookieStore.allCookies(), newCookies = await newProfile.httpCookieStore.allCookies()
        XCTAssertEqual(cookies.map(\.value), ["new"])
        XCTAssertTrue(newCookies.isEmpty)
    }
}
