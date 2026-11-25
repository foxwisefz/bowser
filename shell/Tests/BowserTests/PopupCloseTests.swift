import AppKit
import WebKit
import XCTest
@testable import Bowser

@MainActor final class PopupCloseTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }

    func testScriptedPopupCloseReturnsToOpenerAndPreservesBackgroundSelection() async throws {
        _ = NSApplication.shared
        let controller = BrowserWindowController(profile: .defaultProfile)
        defer { controller.window?.close() }
        let opener = try XCTUnwrap(controller.activeTab)
        opener.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        opener.webView.loadHTMLString("<html><body>Opener</body></html>", baseURL: URL(string: "https://popup.test"))
        try await wait { !opener.webView.isLoading }
        let baseline = controller.tabs.count
        for background in [false, true] {
            _ = try await opener.webView.evaluateJavaScript("window.open('about:blank'); true")
            try await wait { controller.tabs.count == baseline + 1 }
            let popup = try XCTUnwrap(controller.tabs.first { $0 !== opener })
            try await wait { !popup.webView.isLoading }
            XCTAssertTrue(controller.activeTab === popup)
            let hasOpener = try await popup.webView.evaluateJavaScript("!!window.opener") as? Bool
            XCTAssertEqual(hasOpener, true)
            // Simulate an auth result delivered before the popup closes.
            _ = try await popup.webView.evaluateJavaScript("window.opener.authResult = 'complete'; true")
            let other = controller.openTab()
            if !background { controller.activate(popup) }
            _ = try? await popup.webView.evaluateJavaScript("window.close()")
            try await wait { !controller.tabs.contains { $0 === popup } }
            XCTAssertTrue(controller.activeTab === (background ? other : opener))
            XCTAssertNil(EngineView.live[popup.webviewId])
            let result = try await opener.webView.evaluateJavaScript("window.authResult") as? String
            XCTAssertEqual(result, "complete")
            controller.closeTab(other, selecting: opener.webviewId)
        }
    }
}
