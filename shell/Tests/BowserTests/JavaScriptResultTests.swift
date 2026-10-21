import Foundation
import WebKit
import XCTest
@testable import Bowser

final class JavaScriptResultTests: XCTestCase {
    func testJSONValuesAndSharedReferencesSurviveRoundTrip() throws {
        let shared: NSDictionary = ["text": "hello 🦊", "empty": NSNull(), "flag": true, "number": 12.5]
        let input: NSArray = [shared, shared, NSNull()]
        let value = try JavaScriptResult.convert(input)
        let data = try JSONSerialization.data(withJSONObject: value)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [Any])
        let first = try XCTUnwrap(decoded[0] as? [String: Any])
        XCTAssertEqual(first["text"] as? String, "hello 🦊")
        XCTAssertEqual(first["flag"] as? Bool, true)
        XCTAssertEqual(first["number"] as? Double, 12.5)
        XCTAssertTrue(first["empty"] is NSNull)
        XCTAssertTrue(decoded[2] is NSNull)
        XCTAssertEqual(decoded[0] as? NSDictionary, decoded[1] as? NSDictionary)
        XCTAssertTrue(try JavaScriptResult.convert(nil) is NSNull)
        XCTAssertTrue(try JavaScriptResult.convert(NSNull()) is NSNull)
    }

    func testCircularDictionaryArrayAndMixedGraphReturnErrors() {
        let dictionary = NSMutableDictionary()
        dictionary["self"] = dictionary
        defer { dictionary.removeAllObjects() }
        assertError(.circular, dictionary)

        let array = NSMutableArray()
        array.add(array)
        defer { array.removeAllObjects() }
        assertError(.circular, array)

        let parent = NSMutableDictionary()
        let child = NSMutableArray()
        parent["child"] = child
        child.add(parent)
        defer { child.removeAllObjects(); parent.removeAllObjects() }
        assertError(.circular, parent)
    }

    func testDepthLimitAndSharedGraphExpansionAreBounded() throws {
        var nested: AnyObject = NSNumber(value: 1)
        for _ in 0..<JavaScriptResult.maximumDepth { nested = NSArray(object: nested) }
        _ = try JavaScriptResult.convert(nested)
        assertError(.depth, NSArray(object: nested))
        assertError(.size, NSArray(array: Array(repeating: 0, count: JavaScriptResult.maximumValues)))

        // Only 20 distinct arrays, but more than a million values if expanded.
        var shared: AnyObject = NSNumber(value: 1)
        for _ in 0..<20 { shared = NSArray(objects: shared, shared) }
        assertError(.size, shared)
    }

    func testNonFiniteNumbersAndUnsupportedValuesReturnErrors() {
        for value in [Double.nan, .infinity, -.infinity] {
            assertError(.nonFinite, NSNumber(value: value))
        }
        assertError(.unsupported, NSDictionary(object: "value", forKey: NSNumber(value: 1)))
        assertError(.unsupported, NSObject())
    }

    func testReplyKeepsRoutingAndReportsConversionAndEvaluationFailures() throws {
        let circular = NSMutableDictionary()
        circular["self"] = circular
        defer { circular.removeAllObjects() }
        let reply = BrainBridge.javaScriptReply(.success(circular), id: 123, webview: 456)
        XCTAssertEqual(reply["op"] as? String, "js_result")
        XCTAssertEqual(reply["id"] as? Int, 123)
        XCTAssertEqual(reply["webview"] as? UInt64, 456)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["value"] as? String, JavaScriptResult.ConversionError.circular.localizedDescription)
        _ = try JSONSerialization.data(withJSONObject: reply)
        let error = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Script failed"])
        let failed = BrainBridge.javaScriptReply(.failure(error), id: 124, webview: 456)
        XCTAssertEqual(failed["ok"] as? Bool, false)
        XCTAssertEqual(failed["value"] as? String, "Script failed")
        let success = BrainBridge.javaScriptReply(.success(["value": 42]), id: 125, webview: 456)
        XCTAssertEqual(success["ok"] as? Bool, true)
        XCTAssertEqual((success["value"] as? [String: Int])?["value"], 42)
        let event = BrainBridge.pageEvent(circular, webview: 456)
        XCTAssertEqual(event["event"] as? String, "console")
        XCTAssertEqual(event["level"] as? String, "error")
        XCTAssertNil(event["payload"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(event))
        let validEvent = BrainBridge.pageEvent(["value": NSNull()], webview: 456)
        XCTAssertEqual(validEvent["event"] as? String, "page")
        XCTAssertTrue((validEvent["payload"] as? [String: Any])?["value"] is NSNull)
    }

    @MainActor
    func testRealWebKitCyclesFailAndSubsequentEvaluationsStillWork() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        let loaded = expectation(description: "isolated fixture loaded")
        let delegate = JavaScriptResultNavigationDelegate(loaded)
        web.navigationDelegate = delegate
        web.loadHTMLString("<html><body>JavaScript result fixture</body></html>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)

        let scripts = [
            "(()=>{const o={};o.self=o;return [o]})()",
            "(()=>{const a=[];a.push(a);return a})()",
            "(()=>{const o={};const a=[o];o.array=a;return o})()",
            "(()=>{let o={};for(let i=0;i<70;i++)o={child:o};return o})()"
        ]
        for world in [WKContentWorld.page, .defaultClient] {
            for async in [false, true] {
                for (index, script) in scripts.enumerated() {
                    let completed = expectation(description: "bounded result \(index)")
                    let callback: @MainActor @Sendable (Result<Any, Error>) -> Void = { result in
                        // Require WebKit to actually deliver the graph, so this
                        // test cannot pass merely because WebKit rejected it.
                        if case .failure(let error) = result { XCTFail(error.localizedDescription) }
                        let reply = BrainBridge.javaScriptReply(result, id: index, webview: 789)
                        XCTAssertEqual(reply["ok"] as? Bool, false)
                        let expected: JavaScriptResult.ConversionError = index == 3 ? .depth : .circular
                        XCTAssertEqual(reply["value"] as? String, expected.localizedDescription)
                        XCTAssertTrue(JSONSerialization.isValidJSONObject(reply))
                        completed.fulfill()
                    }
                    if async {
                        web.callAsyncJavaScript("return await Promise.resolve(\(script));", arguments: [:], in: nil, in: world, completionHandler: callback)
                    } else {
                        web.evaluateJavaScript(script, in: nil, in: world, completionHandler: callback)
                    }
                    await fulfillment(of: [completed], timeout: 10)
                }
            }
        }
        let healthy = try await web.evaluateJavaScript("({text:'still running', n:42, empty:null})")
        let value = try XCTUnwrap(try JavaScriptResult.convert(healthy) as? [String: Any])
        XCTAssertEqual(value["text"] as? String, "still running")
        XCTAssertEqual(value["n"] as? Int, 42)
        XCTAssertTrue(value["empty"] is NSNull)
    }

    private func assertError(_ expected: JavaScriptResult.ConversionError, _ value: Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try JavaScriptResult.convert(value), file: file, line: line) {
            XCTAssertEqual($0 as? JavaScriptResult.ConversionError, expected, file: file, line: line)
        }
    }
}

@MainActor
private final class JavaScriptResultNavigationDelegate: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation
    init(_ loaded: XCTestExpectation) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
}
