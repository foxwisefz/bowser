import AppKit
import BowserSurfaceKit

@MainActor final class CommandBar: NSObject {
    enum Invocation {
        case commands, location, newTab(EngineView)
    }
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
    private weak var destinationTab: EngineView?
    private var targetURL = ""
    private var historyQuery = ""
    private var historyTask: Task<Void, Never>?
    func show(for controller: BrowserWindowController, invocation: Invocation = .commands) {
        guard SiteAppConfiguration.current == nil, let window = controller.window else { return }
        target = controller
        let panel = ensurePanel()
        panel.browserOwner = controller
        let source: EngineView?
        switch invocation {
        case .commands:
            source = controller.activeTab
            destinationTab = nil
            state.query = ""
        case .location:
            source = controller.activeTab
            destinationTab = source
            let location = source?.currentURLString ?? ""
            state.query = location == "about:blank" ? "" : location
        case .newTab(let tab):
            source = tab
            destinationTab = tab
            state.query = ""
        }
        targetURL = source?.currentURLString ?? ""
        state.modScope.reset(url: targetURL, faviconPath: source?.faviconPath)
        state.opensInCurrentTab = destinationTab != nil
        state.selected = 0
        state.results = []
        state.profile = controller.profile.id; state.active = source?.webviewId
        historyQuery = ""; state.historyResults = []; historyTask?.cancel()
        state.placeholder = state.opensInCurrentTab ? "Search or enter an address" : "Search tabs, history, or the web"
        panel.fit(to: window, height: panel.frame.height)
        state.refresh()
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
            guard let panel, let window = panel.browserOwner?.window else { return }
            panel.fit(to: window, height: height)
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
      guard BrowserWindowController.all.contains(where: { $0 === target }) else { return }
      let url = result.history?.url ?? BrowserWindowController.normalize(result.query)
      if let destinationTab, target.tabs.contains(where: { $0 === destinationTab }) {
        if target.activeTab !== destinationTab { target.activate(destinationTab) }
        destinationTab.load(urlString: url)
      } else {
        target.openTab().load(urlString: url)
      }
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
  func fit(to owner: NSWindow, height: CGFloat) {
    let screen = owner.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? owner.frame
    let area = screen.insetBy(dx: 8, dy: 8)
    let width = min(640, area.width, max(320, owner.frame.width - 32))
    let height = min(height, area.height)
    let x = min(max(area.minX, owner.frame.midX - width / 2), area.maxX - width)
    let top = min(area.maxY, owner.frame.maxY - min(90, owner.frame.height * 0.14))
    setFrame(NSRect(x: x, y: max(area.minY, top - height), width: width, height: height), display: true)
  }
  override func resignKey() {
    super.resignKey()
    onDismiss?()
  }
}
