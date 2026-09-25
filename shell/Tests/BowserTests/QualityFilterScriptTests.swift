import XCTest
import AppKit
import WebKit
@testable import Bowser

@MainActor final class QualityFilterScriptTests: XCTestCase {
    func testBrandFilterBoundsPageCollection() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("beam/example_mods/amazon_brand_filter.ex"), encoding: .utf8)
        let script = source.components(separatedBy: "@script \"\"\"")[1].components(separatedBy: "\"\"\"")[0]
        let web = WKWebView()
        let cards = (0..<200).map { "<div data-component-type='s-search-result' data-asin='\($0)'><h2>Fixture headphones</h2></div>" }.joined()
        let literal = String(data: try JSONSerialization.data(withJSONObject: [cards]), encoding: .utf8)!
        _ = try await web.evaluateJavaScript("document.body.innerHTML = \(literal)[0]; window.bowser={emit:v=>window.fixtureBatch=v};" + script)
        _ = try await web.evaluateJavaScript("window.__bowserBrandFilterCollect()")
        let count = try await web.evaluateJavaScript("window.fixtureBatch.items.length") as? Int
        XCTAssertEqual(count, 128)
    }

    func testBrandFilterAppliesKeepHideAndRejectsStaleContent() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("beam/example_mods/amazon_brand_filter.ex"), encoding: .utf8)
        let template = source.components(separatedBy: "    js = \"\"\"")[1].components(separatedBy: "\"\"\"")[0]
        let snapshots = "{\"a\":{\"title\":\"Alpha\",\"text\":\"Alpha\"},\"b\":{\"title\":\"Beta\",\"text\":\"Beta\"}}"
        func script(_ decisions: String) -> String {
            template.replacingOccurrences(of: "#{encoded}", with: decisions)
                .replacingOccurrences(of: "#{snapshots}", with: snapshots)
                .replacingOccurrences(of: "#{enabled}", with: "true")
        }
        let web = WKWebView()
        _ = try await web.evaluateJavaScript("document.body.innerHTML = `<div data-component-type='s-search-result' data-asin='a'><h2>Alpha</h2></div><div data-component-type='s-search-result' data-asin='b' style='display:flex'><h2>Beta</h2></div>`")
        let kept = try await web.evaluateJavaScript(script("{a:false,b:false}")) as? [String: Int]
        XCTAssertEqual(kept?["processed"], 2)
        XCTAssertEqual(kept?["hidden"], 0)
        let hidden = try await web.evaluateJavaScript(script("{a:false,b:true}")) as? [String: Int]
        XCTAssertEqual(hidden?["processed"], 2)
        XCTAssertEqual(hidden?["hidden"], 1)
        _ = try await web.evaluateJavaScript("document.querySelector('[data-asin=b] h2').textContent='Changed'")
        let stale = try await web.evaluateJavaScript(script("{a:false,b:true}")) as? [String: Int]
        XCTAssertEqual(stale?["processed"], 1)
        XCTAssertEqual(stale?["hidden"], 0)
        let restored = try await web.evaluateJavaScript("document.querySelector('[data-asin=b]').style.display") as? String
        XCTAssertEqual(restored, "flex")
    }

    func testXCoverPreservesLayoutAndCanBeRevealed() async throws { try await exercise(mode: "x") }
    func testAmazonCoverPreservesLayoutAndCanBeRevealed() async throws { try await exercise(mode: "amazon") }
    private func exercise(mode: String) async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let text = "Generic promotional filler repeated without concrete useful information."
        let content = mode == "x"
            ? "<article data-testid='tweet' style='height:200px'><a href='/person/status/123'>Author</a><div data-testid='tweetText'>\(text)</div></article>"
            : "<article data-component-type='s-search-result' data-asin='123' style='height:200px'><h2 data-testid='tweetText'>\(text)</h2></article>"
        web.loadHTMLString("<html><body>" + content + "</body></html>", baseURL: URL(string: mode == "x" ? "https://x.com/" : "https://www.amazon.com/s?k=fixture"))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.querySelector('article') !== null")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("beam/priv/quality-filter.js"), encoding: .utf8).replacingOccurrences(of: "__BOWSER_MODE__", with: "\"\(mode)\"")
        _ = try await web.evaluateJavaScript("window.bowser={emit:v=>window.lastBatch=v};" + source)
        let before = try await web.evaluateJavaScript("document.querySelector('article').getBoundingClientRect().height") as! Double
        let encoded = String(data: try JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!
        _ = try await web.evaluateJavaScript("window.__bowserQuality.apply('\(mode)','123',\(encoded)[0],true)")
        let result1 = try await web.evaluateJavaScript("document.querySelector('article').getBoundingClientRect().height") as? Double
        XCTAssertEqual(result1, before)
        let result2 = try await web.evaluateJavaScript("document.querySelector('article button').textContent") as? String
        XCTAssertEqual(result2, "Likely low-quality content · Show")
        _ = try await web.evaluateJavaScript("document.querySelector('article button').click()")
        let result3 = try await web.evaluateJavaScript("document.querySelector('[data-testid=tweetText]').style.visibility") as? String
        XCTAssertEqual(result3, "")
        _ = try await web.evaluateJavaScript("window.__bowserQuality.dispose()")
        // A late answer for the old content must not cover an edited post.
        _ = try await web.evaluateJavaScript(source)
        _ = try await web.evaluateJavaScript("document.querySelector('[data-testid=tweetText]').textContent='Useful firsthand details about a real experiment and its results.'")
        _ = try await web.evaluateJavaScript("window.__bowserQuality.apply('\(mode)','123',\(encoded)[0],true)")
        let lateCoverCount = try await web.evaluateJavaScript("document.querySelectorAll('article button').length") as? Int
        XCTAssertEqual(lateCoverCount, 0)
        _ = try await web.evaluateJavaScript("window.__bowserQuality.dispose()")
        let result4 = try await web.evaluateJavaScript("document.querySelectorAll('button').length") as? Int
        XCTAssertEqual(result4, 0)
    }
}
