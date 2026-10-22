import AppKit
import BowserSurfaceKit

@MainActor final class CommandBar: NSObject {
    static let shared = CommandBar()
    typealias TabCandidate = CommandPaletteState.TabCandidate
    typealias Result = CommandPaletteState.Result
    static func suggestions(query: String, tabs: [TabCandidate], profile: String, active: UInt64?) -> [Result] {
        PaletteSuggestions.suggestions(query: query, tabs: tabs, profile: profile, active: active)
    }
    var results: [Result] { state.results }
    private let state = CommandPaletteState()
    private var context: BrowserScreenContext?
    private var panel: CommandBarPanel?
    private weak var target: BrowserWindowController?
    private var targetURL = ""
    private var historyQuery = ""
    private var historyTask: Task<Void, Never>?
    func show(for controller: BrowserWindowController, showCurrentURL: Bool = false) {
        guard SiteAppConfiguration.current == nil else { return }
        target = controller
        let panel = ensurePanel()
        panel.browserOwner = controller
        targetURL = controller.activeTab?.currentURLString ?? ""
        state.modScope.reset(url: targetURL, faviconPath: controller.activeTab?.faviconPath)
        state.query = showCurrentURL ? targetURL : ""; state.selected = 0
        state.profile = controller.profile.id; state.active = controller.activeTab?.webviewId
        historyQuery = ""; state.historyResults = []; historyTask?.cancel()
        state.placeholder = "Search the web, your history, or open tabs"
        state.refresh()
        guard let window = controller.window else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: window.frame.midX - size.width / 2,
            y: max(window.screen?.visibleFrame.minY ?? 0, window.frame.maxY - 100 - size.height)))
        panel.makeKeyAndOrderFront(nil)
        state.focus()
    }
    var isVisible: Bool { panel?.isVisible == true }

    /// Send the second physical shortcut straight to WebKit, bypassing Bowser's
    /// local event monitor and menu equivalents. Sites decide whether to handle it.
    @discardableResult
    func handShortcutToPage(_ event: NSEvent, for controller: BrowserWindowController) -> Bool {
        guard isVisible, target === controller, let window = controller.window,
              let page = controller.activeTab?.webView else { return false }
        hide()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(page)
        guard let forwarded = NSEvent.keyEvent(with: event.type, location: .zero,
            modifierFlags: event.modifierFlags, timestamp: event.timestamp,
            windowNumber: window.windowNumber, context: nil,
            characters: event.characters ?? "k", charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "k",
            isARepeat: false, keyCode: event.keyCode) else { return true }
        page.keyDown(with: forwarded)
        return true
    }

    func hide() { historyTask?.cancel(); state.modScope.freeze(); panel?.orderOut(nil) }
    func receiveScope(id: String, choice: String) {
        state.modScope.receive(id: id, choice: choice)
    }
    private func ensurePanel() -> CommandBarPanel {
        if let panel { return panel }
        let panel = CommandBarPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 94),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.backgroundColor = .clear; panel.isOpaque = false
        panel.hasShadow = true; panel.isReleasedWhenClosed = false
        panel.onDismiss = { [weak self] in self?.hide() }
        state.dismiss = { [weak self] in self?.hide() }
        state.choose = { [weak self] in self?.choose($0) }
        state.searchHistory = { [weak self] query in self?.searchHistory(query) }
        state.command = { [weak self] text in
            if let request = PaletteRequest(command: text) {
                let workspace = ModSmithWindow.shared
                workspace.model.targetWebview = self?.state.active
                workspace.model.targetURL = self?.targetURL ?? ""
                workspace.show(captureTarget: false)
                workspace.model.prepareNewDraft(request.draft,
                    scope: request.kind == "task" ? "site" : self?.state.modScope.selected ?? "site",
                    kind: request.kind, start: request.start)
                return
            }
            ChromeSurface.emit(["op": "event", "event": "omnibar_command", "text": text,
                "profile": self?.target?.profile.id ?? "default", "webview": self?.target?.activeTab?.webviewId ?? 0])
        }
        state.modScope.request = { id, text, host in
            BrainBridge.shared.send(["op": "event", "event": "modsmith_scope", "request_id": id, "text": text, "host": host])
        }
        state.commands = { [weak self] in ChromeSurface.commands(for: self?.target?.profile.id ?? "default") }
        state.tabs = {
            BrowserWindowController.all.flatMap { controller in controller.tabs.map {
                TabCandidate(id: $0.webviewId, title: $0.webView.title ?? "", url: $0.currentURLString ?? "",
                    profile: controller.profile.id, favicon: $0.faviconPath)
            } }
        }
        state.resize = { [weak panel] height in
            guard let panel else { return }; let frame = panel.frame
            panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: true)
        }
        let context = BrowserScreenContext(kind: "palette", model: state)
        self.context = context; BrowserScreenContext.contexts[context.id] = context
        let slot = NativeModuleSlot(fallback: CommandPaletteRenderer(state: state), kind: .surfaces)
        slot.setSnapshot(try! JSONSerialization.data(withJSONObject: ["screen": context.id]))
        panel.contentView = slot
        self.panel = panel
        return panel
    }
  func choose(_ result: Result) {
    guard let target else { return hide() }
    if let history = result.history {
      hide()
      (NSApp.delegate as? AppDelegate)?.openTab(url: history.url, activate: true, profile: target.profile.id)
      return
    }
    if let tab = result.tab {
      guard let controller = BrowserWindowController.host(of: tab.id),
        controller.profile.id == target.profile.id
      else {
        state.refresh()
        return
      }
      hide()
      controller.activateTab(id: tab.id)
      controller.window?.makeKeyAndOrderFront(nil)
    } else {
      hide()
      (NSApp.delegate as? AppDelegate)?.openTab(
        url: BrowserWindowController.normalize(result.query), activate: true,
        profile: target.profile.id)
    }
  }

    private func searchHistory(_ query: String) {
        let key = state.profile + "\n" + query
        guard historyQuery != key else { return }
        historyQuery = key; state.historyResults = []; historyTask?.cancel()
        guard query.count >= 2, !query.hasPrefix(":"), !query.hasPrefix("http") else { return }
        let profile = state.profile
        historyTask = Task {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            let found = await HistoryController.shared.search(profile: profile, query: query)
            guard !Task.isCancelled, self.historyQuery == key, self.state.profile == profile else { return }
            state.historyResults = found; state.refresh()
        }
    }

}
private final class CommandBarPanel: NSPanel, BrowserOwnedPanel {
  weak var browserOwner: BrowserWindowController?
  var onDismiss: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override func resignKey() {
    super.resignKey()
    onDismiss?()
  }
}
