import XCTest
import WebKit
@testable import Bowser

@MainActor final class ModEmitTests: XCTestCase {
    private final class Receiver: NSObject, WKScriptMessageHandler {
        var count = 0
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            count += 1
        }
    }

    func testEmitDeliversThroughRegisteredBridge() async throws {
        let receiver = Receiver()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(receiver, name: "bowserEmit")
        let web = WKWebView(frame: .zero, configuration: configuration)
        _ = try await web.evaluateJavaScript(EngineView.consoleHook)
        _ = try await web.evaluateJavaScript("window.bowser.emit({kind:'fixture'}); true")
        for _ in 0..<50 {
            if receiver.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(receiver.count, 1)
    }

    func testEmitReportsMissingTransport() async throws {
        let web = WKWebView()
        _ = try await web.evaluateJavaScript(EngineView.consoleHook)
        do {
            _ = try await web.evaluateJavaScript("window.bowser.emit({kind:'fixture'})")
            XCTFail("Missing bridge must not silently report success")
        } catch {
            XCTAssertEqual((error as NSError).domain, WKError.errorDomain)
        }
    }
}
