import AppKit
import SwiftUI
import Combine

@MainActor
final class ModSmithModel: ObservableObject, ModSmithPresentation {
    @Published var workspacePage = "overview"
    @Published var instructionsOpen = false
    var isSiteApp: Bool { SiteAppConfiguration.current != nil }
    @Published var snapshot = ModSmithSnapshot()
    @Published var draft = ""
    let scopeChoice = ModScopeChoice()
    private var choicesObserver: AnyCancellable?
    var scope: String {
        get { scopeChoice.selected }
        set { scopeChoice.choose(newValue) }
    }
    @Published var connectionError: String?
    @Published var targetURL = ""
    var targetFavicon: String? { targetWebview.flatMap { EngineView.live[$0]?.faviconPath } }
    var targetWebview: UInt64?
    private var deletingProjects: Set<String> = []
    private var drafts: [String: String] = [:]
    private var projectTargets: [String: UInt64] = [:]
    private var pending: (id: String, key: String, text: String)?
    var track: (TelemetryEvent) -> Void = { event in Task { await Telemetry.shared.record(event) } }
    var send: ([String: Any]) -> Void = { BrainBridge.shared.send($0) }
    var connected: () -> Bool = { BrainBridge.shared.isConnected }
    var project: ModSmithProject? { snapshot.projects.first { $0.id == snapshot.selected } }
    var key: String { snapshot.selected ?? newDraftKey }
    private var newDraftKey: String { snapshot.workspace_profile.map { "new:" + $0.id } ?? "new" }
    init() {
        choicesObserver = scopeChoice.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        scopeChoice.request = { [weak self] id, text, host in
            guard let self, self.connected() else { return }
            self.send(["op": "event", "event": "modsmith_scope", "request_id": id, "text": text, "host": host])
        }
    }

    func receive(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let incoming = try? JSONDecoder().decode(ModSmithSnapshot.self, from: data) else { return }
        for next in incoming.projects {
            guard !next.isTask, let previous = snapshot.projects.first(where: { $0.id == next.id }) else { continue }
            if previous.status == "working", next.status != "working" {
                let operation: TelemetryEvent.Operation = previous.files.isEmpty && previous.turns.filter({ $0.role == "user" }).count <= 1 ? .create : .refine
                track(.modsmith(operation, next.status == "active" ? .succeeded : next.status == "interrupted" ? .cancelled : .failed))
            } else if next.status == "restored", next.turns.count > previous.turns.count {
                track(.modsmith(.undo, .succeeded))
            }
        }
        drafts[key] = draft
        if let pending, incoming.accepted == pending.id {
            // Preserve anything typed after submission; clear only the accepted draft.
            if drafts[pending.key] == pending.text { drafts[pending.key] = "" }
            if let project = incoming.selected, let targetWebview { projectTargets[project] = targetWebview }
            self.pending = nil
        }
        for id in deletingProjects where !incoming.projects.contains(where: { $0.id == id }) {
            drafts.removeValue(forKey: id)
            projectTargets.removeValue(forKey: id)
        }
        deletingProjects = deletingProjects.filter { id in incoming.projects.contains { $0.id == id } }
        if incoming.error != nil { pending = nil; deletingProjects.removeAll() }
        LearnGuideProgress.shared.receive(incoming)
        if incoming.accepted != snapshot.accepted && incoming.accepted != nil { workspacePage = "history" }
        if let route = message["workspace_view"] as? String { workspacePage = route }
        if let old = snapshot.selected, incoming.selected != old, !incoming.projects.contains(where: { $0.id == old }), workspacePage == "history" { workspacePage = "overview" }
        if let url = message["target_url"] as? String { targetURL = url }
        if let webview = message["target_webview"] as? UInt64 { targetWebview = webview }
        snapshot = incoming
        draft = drafts[key] ?? ""
        connectionError = nil
    }

    func action(_ action: String, project id: String? = nil, path: String? = nil) {
        if action == "choose_kind", let path { scopeChoice.chooseKind(path); return }
        if action == "reveal_file", let path, project?.artifacts?.contains(where: { $0.path == path }) == true {
            guard FileManager.default.fileExists(atPath: path) else { connectionError = "This export was moved or deleted."; return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return
        }
        if ["run_again", "make_reusable"].contains(action), let project, project.isTask,
           let original = project.turns.first(where: { $0.role == "user" })?.text {
            guard !snapshot.busy else { return }
            if action == "run_again", let webview = (NSApp.delegate as? AppDelegate)?.currentWebviewId,
               let view = EngineView.live[webview] {
                targetWebview = webview; targetURL = view.currentURLString ?? ""
            }
            if action == "make_reusable" { targetURL = project.url; targetWebview = projectTargets[project.id] ?? targetWebview }
            let text = action == "make_reusable"
                ? "Create a reusable mod for this task: \(original)\nPrevious result (context only; verify the new mod): \(project.summary)"
                : original
            prepareNewDraft(text, kind: action == "make_reusable" ? "mod" : "task", start: action == "run_again")
            return
        }
        if action == "overview" { workspacePage = "overview"; return }
        if action == "open" { workspacePage = "overview" }
        if ["new", "select", "edit_existing"].contains(action) {
            workspacePage = action == "new" ? "new" : "history"
        }
        if action == "profile", let path {
            guard let profile = ProfileSettingsModel.shared.profiles.first(where: { $0.id == path }) else { return }
            let controller = BrowserWindowController.all.first { $0.profile.id == path }
                ?? BrowserWindowController(profile: profile)
            controller.window?.makeKeyAndOrderFront(nil)
            targetWebview = controller.activeTab?.webviewId
            targetURL = controller.activeTab?.currentURLString ?? ""
            workspacePage = "overview"
            var event: [String: Any] = ["op": "event", "event": "modsmith", "action": "open"]
            if let targetWebview { event["webview"] = targetWebview }
            send(event)
            ModSmithWindow.shared.show(captureTarget: false)
            return
        }
        if action == "try" {
            let stored = project.flatMap { projectTargets[$0.id] }
            let matching = BrowserWindowController.all.flatMap(\.tabs).first { tab in
                guard let project else { return false }
                return tab.currentURLString == project.url
            }?.webviewId
            if let webview = stored ?? matching ?? (project?.scope == "browser" ? targetWebview : nil),
               let controller = BrowserWindowController.host(of: webview) {
                controller.activateTab(id: webview)
                controller.window?.makeKeyAndOrderFront(nil)
            } else {
                connectionError = "The original tab is closed. Open the mod’s website to try it."
            }
            return
        }
        if action == "new" { scopeChoice.reset(url: targetURL, faviconPath: targetFavicon) }
        guard connected() else { connectionError = "Connecting to Bowser. Your draft is saved here; try again shortly."; return }
        var message: [String: Any] = ["op": "event", "event": "modsmith", "action": action]
        if let id = id ?? snapshot.selected { message["project"] = id }
        if action == "cancel", let run = snapshot.running_run {
            message["run"] = run
            message["project"] = snapshot.running_project
        }
        if action == "open", let targetWebview { message["webview"] = targetWebview }
        if let path { message[action == "copy" ? "destination" : "path"] = path }
        if action == "copy_existing" {
            message.removeValue(forKey: "project")
            message["path"] = id
            message["destination"] = path
        }
        if action == "delete", let id = id ?? snapshot.selected { deletingProjects.insert(id) }
        send(message)
    }

    func prepareNewDraft(_ text: String, scope: String = "site", kind: String = "mod", start: Bool = false) {
        workspacePage = "new"
        instructionsOpen = false
        drafts[key] = draft
        snapshot.selected = nil
        drafts[newDraftKey] = text
        draft = text
        scopeChoice.reset(url: targetURL, selected: scope, manual: start, faviconPath: targetFavicon, kind: kind, manualKind: true)
        if start && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            submit()
        } else {
            action("new")
            scopeChoice.reset(url: targetURL, selected: scope, manual: scope == "browser", faviconPath: targetFavicon, kind: kind, manualKind: true)
            scopeChoice.update(text)
        }
    }

    func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, pending == nil else { return }
        guard !snapshot.busy else { connectionError = "Another request is running. Your draft is saved; send it when that finishes."; return }
        if project == nil && !isSiteApp && !(requestKind == "task" ? scopeChoice.host != nil : scopeChoice.valid) {
            connectionError = requestKind == "task" ? "Open a website to run this task." : "Open a website or choose Across Bowser."; return
        }
        guard connected() else { connectionError = "Connecting to Bowser. Your draft is saved here; try again shortly."; return }
        scopeChoice.freeze()
        let requestID = UUID().uuidString
        pending = (requestID, key, draft)
        var message: [String: Any] = ["op": "event", "event": "modsmith", "action": "submit", "text": text,
                                      "scope": requestKind == "task" ? "site" : scope, "kind": requestKind, "request_id": requestID, "url": targetURL]
        if let id = snapshot.selected { message["project"] = id }
        if let id = targetWebview { message["webview"] = id }
        if requestKind == "mod" { LearnGuideProgress.shared.begin(request: requestID, webview: targetWebview, url: targetURL) }
        send(message)
    }
}

@MainActor
final class ModSmithWindow: NSObject {
    static let shared = ModSmithWindow()
    let model = ModSmithModel()
    private var window: NSWindow?

    @objc func open(_ sender: Any? = nil) {
        show()
        model.action("open")
    }

    func show(captureTarget: Bool = true) {
        if captureTarget {
        model.targetWebview = (NSApp.delegate as? AppDelegate)?.currentWebviewId
        model.targetURL = SiteAppConfiguration.current?.url.absoluteString
            ?? BrowserWindowController.all.first(where: { $0.window?.isMainWindow == true })?.activeTab?.currentURLString
            ?? EngineView.live[(NSApp.delegate as? AppDelegate)?.currentWebviewId ?? 0]?.currentURLString ?? ""
            if model.project == nil { model.scopeChoice.reset(url: model.targetURL, faviconPath: model.targetFavicon) }
        }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Tasks & Mods"
            w.subtitle = "Ask Bowser"
            w.minSize = NSSize(width: 880, height: 520)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("ModSmithWorkspace")
            w.contentView = NSHostingView(rootView: LiveBrowserScreen(kind: "modsmith", model: model))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func receive(_ message: [String: Any]) {
        model.receive(message)
        if message["show"] as? Bool == true { show(captureTarget: false) }
    }
}

struct ModSmithRootView: View {
    let model: ModSmithModel
    var body: some View { LiveBrowserScreen(kind: "modsmith", model: model) }
}
