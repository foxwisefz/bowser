import AppKit
import WebKit
import XCTest
@testable import Bowser

@MainActor final class FirstModPlaygroundTests: XCTestCase {
    func testChoicePageAndAllExercisesInWebKit() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let assets = root.appendingPathComponent("website/learn")
        let css = try String(contentsOf: assets.appendingPathComponent("learn.css"), encoding: .utf8)
        var js = try String(contentsOf: assets.appendingPathComponent("learn.js"), encoding: .utf8)
        let icon = try Data(contentsOf: root.appendingPathComponent("website/app-icon.webp")).base64EncodedString()
        js = js.replacingOccurrences(of: "/app-icon.webp", with: "data:image/webp;base64," + icon)
        let html = try String(contentsOf: assets.appendingPathComponent("index.html"), encoding: .utf8)
            .replacingOccurrences(of: "<link rel=\"stylesheet\" href=\"/learn/learn.css\">", with: "<style>\(css)</style>")
            .replacingOccurrences(of: "<script defer src=\"/learn/learn.js\"></script>", with: "")
            .replacingOccurrences(of: "/app-icon.webp", with: "data:image/webp;base64," + icon)
        for name in ["", "slopshop", "slopyapper", "quiet"] {
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 920), configuration: config)
            let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = web; window.makeKeyAndOrderFront(nil)
            defer { web.stopLoading(); window.close() }
            web.loadHTMLString(html, baseURL: URL(string: "https://playground.fixture/learn/\(name)"))
            for _ in 0..<100 {
                if (try? await web.evaluateJavaScript("document.getElementById('playground') !== null")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            _ = try await web.evaluateJavaScript(js)
            if name.isEmpty {
                let links = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('.exercise-card')).map(a=>a.getAttribute('href'))") as? [String]
                XCTAssertEqual(links, ["/learn/slopshop", "/learn/slopyapper", "/learn/quiet"])
            } else {
                let count = try await web.evaluateJavaScript("document.querySelectorAll('[data-product], [data-post]').length") as? Int
                XCTAssertEqual(count, 6)
                let separate = try await web.evaluateJavaScript("!document.querySelector('[data-demo-site]').contains(document.querySelector('[data-bowser-guide]'))") as? Bool
                XCTAssertEqual(separate, true)
                let guideVisible = try await web.evaluateJavaScript("document.querySelector('[data-panel=\"1\"]').hidden === false && document.getElementById('prompt').getBoundingClientRect().height > 0") as? Bool
                XCTAssertEqual(guideVisible, true)
                let dockSeparate = try await web.evaluateJavaScript("document.querySelector('.demo-stage').getBoundingClientRect().bottom <= document.querySelector('.coach').getBoundingClientRect().top") as? Bool
                XCTAssertEqual(dockSeparate, true)
                _ = try await web.evaluateJavaScript("Object.defineProperty(navigator,'clipboard',{value:{writeText:t=>{window.copiedPrompt=t;return Promise.resolve()}},configurable:true});document.getElementById('copy-prompt').click()")
                let copied = try await web.evaluateJavaScript("window.copiedPrompt") as? String
                let visiblePrompt = try await web.evaluateJavaScript("document.getElementById('prompt').value") as? String
                XCTAssertEqual(try XCTUnwrap(copied), visiblePrompt)
                _ = try await web.evaluateJavaScript("document.getElementById('mark-done').click()")
                let progress = try await web.evaluateJavaScript("localStorage.getItem('bowser-playground-\(name)')") as? String
                XCTAssertEqual(progress, "done")
                for state in ["working", "active", "failed", "interrupted"] {
                    _ = try await web.evaluateJavaScript("window.dispatchEvent(new CustomEvent('bowser-mod-progress',{detail:{status:'\(state)',label:'Fixture \(state)'}}))")
                    let visible = try await web.evaluateJavaScript("document.getElementById('build-status').textContent === 'Fixture \(state)' && !document.querySelector('[data-panel=\"2\"]').hidden") as? Bool
                    XCTAssertEqual(visible, true)
                }
                if name == "quiet" {
                    let distractions = try await web.evaluateJavaScript("document.querySelectorAll('.trending-panel,.subscription-promo,.suggested-accounts,.sponsored-banner,.floating-assistant').length") as? Int
                    XCTAssertEqual(distractions, 5)
                }
            }
            if !name.isEmpty { _ = try await web.evaluateJavaScript("document.querySelector('[data-step=\"1\"]').click()") }
            let overflow = try await web.evaluateJavaScript("document.documentElement.scrollWidth > innerWidth") as? Bool
            XCTAssertEqual(overflow, false)
            if ProcessInfo.processInfo.environment["BOWSER_GUIDE_PREVIEW"] == "1" {
                let shot = try await web.takeSnapshot(configuration: nil)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(shot.tiffRepresentation)))
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/bowser-guide-\(name.isEmpty ? "welcome" : name).png"))
            }
            web.frame.size.width = 480
            window.setContentSize(NSSize(width: 480, height: 920))
            try await Task.sleep(for: .milliseconds(30))
            let narrowOverflow = try await web.evaluateJavaScript("document.documentElement.scrollWidth > innerWidth") as? Bool
            XCTAssertEqual(narrowOverflow, false, name)
        }
    }
}
