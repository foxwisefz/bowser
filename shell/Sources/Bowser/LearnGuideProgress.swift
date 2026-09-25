import Foundation
import WebKit

/// One-way status delivery to the exact Learn tab that submitted a mod request.
@MainActor final class LearnGuideProgress {
    static let shared = LearnGuideProgress()
    private var requestID: String?
    private var projectID: String?
    private var targetID: UInt64?
    private var targetURL: URL?
    private var latest: [String: String]?
    var deliver: (UInt64, URL, [String: String]) -> Void = { id, url, status in
        guard let view = EngineView.live[id], view.webView.url == url else { return }
        view.webView.callAsyncJavaScript("window.dispatchEvent(new CustomEvent('bowser-mod-progress', {detail: status}))", arguments: ["status": status], in: nil, in: .page) { _ in }
    }

    static func isLearnPage(_ url: URL, service: URL = BowserAPI.base) -> Bool {
        url.scheme == service.scheme && url.host == service.host && url.port == service.port
            && url.user == nil && url.password == nil
            && ["/learn/slopshop", "/learn/slopyapper", "/learn/quiet"].contains(url.path)
    }

    func begin(request: String, webview: UInt64?, url: String) {
        guard let webview, let url = URL(string: url), Self.isLearnPage(url) else { return }
        requestID = request; projectID = nil; targetID = webview; targetURL = url
        publish(status: "working", label: "Sending your request…")
    }

    func receive(_ snapshot: ModSmithSnapshot) {
        guard let requestID else { return }
        if snapshot.accepted == requestID, projectID == nil { projectID = snapshot.selected }
        guard let projectID, let project = snapshot.projects.first(where: { $0.id == projectID }) else {
            if snapshot.error != nil { publish(status: "failed", label: "Couldn’t start. Open ModSmith for details and retry.") }
            return
        }
        switch project.status {
        case "working":
            let stages = ["Making changes", "Checking the page", "Inspecting and building"]
            publish(status: "working", label: stages.contains(snapshot.stage) ? snapshot.stage + "…" : "Building your mod…")
        case "active": publish(status: "active", label: "Your mod is ready. Try the page above.")
        case "interrupted": publish(status: "interrupted", label: "Creation stopped. You can continue in ModSmith.")
        case "failed", "partial", "needs_help": publish(status: "failed", label: "Your mod needs attention. Open ModSmith to review and continue.")
        default: break
        }
    }

    func replay(to view: EngineView) {
        guard view.webviewId == targetID, view.webView.url == targetURL,
              let targetURL, let latest else { return }
        deliver(view.webviewId, targetURL, latest)
    }

    private func publish(status: String, label: String) {
        guard let targetID, let targetURL else { return }
        let value = ["status": status, "label": label]
        latest = value
        deliver(targetID, targetURL, value)
    }
}
