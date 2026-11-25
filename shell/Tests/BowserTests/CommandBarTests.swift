import AppKit
import XCTest
import BowserSurfaceKit

@testable import Bowser

final class CommandBarTests: XCTestCase {
  @MainActor func testLocationAndNewTabUseTheirCapturedTabWhileCommandSearchUsesItsWindow() throws {
    let owner = BrowserWindowController(profile: .defaultProfile)
    let otherWindow = BrowserWindowController(profile: .defaultProfile)
    defer { CommandBar.shared.hide(); otherWindow.window?.close(); owner.window?.close() }
    let bar = CommandBar.shared
    let page = try XCTUnwrap(owner.activeTab)
    let url = EngineView.historyURL
    owner.openLocationAction(nil)
    bar.choose(.init(tab: nil, query: url))
    XCTAssertTrue(owner.activeTab === page)
    XCTAssertEqual(page.currentURLString, url)
    XCTAssertEqual(owner.tabs.count, 1)

    let blank = owner.openTab(activate: false)
    bar.show(for: owner, invocation: .newTab(blank))
    bar.choose(.init(history: .init(id: "visit", url: url, title: "History", snippet: "", seen: Date(), image: nil), query: "visit"))
    XCTAssertTrue(owner.activeTab === blank)
    XCTAssertEqual(blank.currentURLString, url)
    XCTAssertEqual(owner.tabs.count, 2)

    bar.show(for: owner)
    bar.choose(.init(tab: nil, query: url))
    XCTAssertEqual(owner.tabs.count, 3)
    XCTAssertEqual(owner.activeTab?.currentURLString, url)
    XCTAssertEqual(otherWindow.tabs.count, 1)
  }

  @MainActor func testHistoryArrivalPreservesReturnTargetAndLocationPrioritizesTypedAddress() async throws {
    let state = CommandPaletteState()
    state.query = "studio"
    state.tabs = { [.init(id: 42, title: "Studio notes", url: "https://notes.example/studio", profile: "default")] }
    var chosen: CommandPaletteState.Result?
    state.choose = { chosen = $0 }
    let renderer = CommandPaletteRenderer(state: state)
    renderer.activateScreen()
    let field = try XCTUnwrap(renderer.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    XCTAssertTrue(renderer.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))
    let original = state.results[state.selected]
    XCTAssertNil(original.tab)
    state.historyResults = [.init(id: "archive", url: "https://archive.example/studio", title: "Studio archive", snippet: "", seen: Date(), image: nil)]
    state.refresh()
    XCTAssertEqual(state.results[state.selected], original)
    XCTAssertTrue(field.sendAction(field.action, to: field.target))
    XCTAssertEqual(chosen, original)

    state.opensInCurrentTab = true
    state.selected = 0
    state.results = []
    state.refresh()
    XCTAssertEqual(state.results.first, original)
    XCTAssertEqual(state.selected, 0)

    for width: CGFloat in [360, 640] {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = renderer
      state.resize = { [weak window] height in window?.setContentSize(NSSize(width: width, height: height)) }
      state.refresh()
      renderer.layoutSubtreeIfNeeded()
      let table = try XCTUnwrap(renderer.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView)
      XCTAssertGreaterThan(table.tableColumns[0].width, width - 52)
      if let directory = ProcessInfo.processInfo.environment["BOWSER_PALETTE_RENDER_DIR"] {
        let backdrop = NSWindow(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        window.center()
        backdrop.setFrame(window.frame.insetBy(dx: -40, dy: -40), display: false)
        backdrop.orderFront(nil)
        window.order(.above, relativeTo: backdrop.windowNumber)
        defer { window.orderOut(nil); backdrop.orderOut(nil) }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
          window.appearance = NSAppearance(named: appearance)
          backdrop.backgroundColor = name == "light" ? .white : .darkGray
          backdrop.display()
          let output = URL(fileURLWithPath: directory).appendingPathComponent("palette-\(Int(width))-\(name).png")
          try await writeWindowPreview(window, to: output)
        }
      }
      window.contentView = nil
    }
  }

  @MainActor func testLocationShortcutSelectsCurrentURLAndSearchStartsEmpty() throws {
    let controller = BrowserWindowController(profile: .defaultProfile)
    defer { CommandBar.shared.hide(); controller.window?.close() }
    let app = AppDelegate()
    func press(_ key: String, code: UInt16) throws -> NSTextView {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: .command, timestamp: 0, windowNumber: controller.window!.windowNumber,
        context: nil, characters: key, charactersIgnoringModifiers: key,
        isARepeat: false, keyCode: code))
      XCTAssertNil(app.handleShortcut(event))
      let panel = try XCTUnwrap(NSApp.windows.first {
        $0 is NSPanel && $0.isVisible && ($0 as? BrowserOwnedPanel)?.browserOwner === controller
      })
      return try XCTUnwrap(panel.firstResponder as? NSTextView)
    }
    let url = "https://example.test/document?name=a%20b&download=1#section"
    try XCTUnwrap(controller.activeTab).restore(urlString: url)
    let editor = try press("l", code: 37)
    XCTAssertEqual(editor.string, url)
    XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: (url as NSString).length))
    CommandBar.shared.hide()
    XCTAssertEqual(try press("k", code: 40).string, "")
    CommandBar.shared.hide()
    let next = controller.openTab()
    next.restore(urlString: "https://other.test/new-path")
    XCTAssertEqual(try press("l", code: 37).string, "https://other.test/new-path")
    CommandBar.shared.hide()
    let blank = controller.openTab()
    blank.restore(urlString: "about:blank")
    XCTAssertEqual(try press("l", code: 37).string, "")
  }

  @MainActor func testDefaultResultsContainSwitchableTabsFromOnlyThisProfile() {
    let tabs = [
      CommandBar.TabCandidate(
        id: 1, title: "Active", url: "https://active.test", profile: "default"),
      CommandBar.TabCandidate(id: 2, title: "Work", url: "https://work.test", profile: "work"),
      CommandBar.TabCandidate(id: 3, title: "Mail", url: "https://mail.test", profile: "default"),
    ]
    XCTAssertEqual(
      CommandBar.suggestions(query: "", tabs: tabs, profile: "default", active: 1).compactMap {
        $0.tab?.id
      }, [3])
  }

  @MainActor func testOpenTabsRankAboveNavigationAndMatchTitleOrURL() {
    let tabs = [
      CommandBar.TabCandidate(
        id: 1, title: "Team notes", url: "https://example.test/mail", profile: "default"),
      CommandBar.TabCandidate(id: 2, title: "Mail", url: "https://inbox.test", profile: "default"),
      CommandBar.TabCandidate(
        id: 3, title: "Unrelated", url: "https://other.test", profile: "default"),
    ]
    let results = CommandBar.suggestions(query: "MAIL", tabs: tabs, profile: "default", active: nil)
    XCTAssertEqual(results.compactMap { $0.tab?.id }, [2, 1])
    XCTAssertNil(results.last?.tab)
    XCTAssertEqual(results.last?.query, "MAIL")
    XCTAssertEqual(
      CommandBar.suggestions(query: "MAIL", tabs: tabs, profile: "default", active: 2).first?.tab?.id,
      2)
    XCTAssertEqual(
      CommandBar.suggestions(query: "team example", tabs: tabs, profile: "default", active: nil)
        .first?.tab?.id, 1)
    XCTAssertTrue(
      CommandBar.suggestions(query: ":mods", tabs: tabs, profile: "default", active: nil).isEmpty)
  }

  @MainActor func testSearchIndexTracksChangedTabsAndKeepsAccentAndRankingSemantics() {
    func tab(_ id: UInt64, _ title: String, _ url: String, _ profile: String = "default") -> CommandBar.TabCandidate {
      .init(id: id, title: title, url: url, profile: profile)
    }
    func ids(_ query: String, _ tabs: [CommandBar.TabCandidate]) -> [UInt64] {
      CommandBar.suggestions(query: query, tabs: tabs, profile: "default", active: nil).compactMap { $0.tab?.id }
    }
    let original = [tab(1, "Café notes", "https://notes.test"),
                    tab(2, "Other", "https://cafe.test"),
                    tab(3, "Café", "https://exact.test"),
                    tab(4, "Café secret", "https://work.test", "work")]
    XCTAssertEqual(ids("CAFE", original), [3, 1, 2])
    XCTAssertEqual(ids("cafe notes", original), [1])
    XCTAssertEqual(ids("CAFE", original), [3, 1, 2])
    let changed = [tab(2, "Changed", "https://changed.test"), original[0]]
    XCTAssertEqual(ids("cafe", changed), [1])
    XCTAssertEqual(ids("changed", changed), [2])
    XCTAssertEqual(ids("cafe", []), [])
    let emptyFields = [tab(1, "Named", "https://one.test"), tab(2, "", "https://two.test"), tab(3, "New tab", "")]
    XCTAssertEqual(ids("", emptyFields), [2, 3, 1])
    XCTAssertEqual(CommandBar.suggestions(query: "", tabs: emptyFields, profile: "default", active: 2).compactMap { $0.tab?.id }, [3, 1])
    let many = (1...10).map { tab(UInt64($0), "Mail item", "https://example.test/\($0)") }
        + [tab(11, "Mail", "https://exact.test")]
    XCTAssertEqual(ids("mail", many), [11, 1, 2, 3, 4])
    XCTAssertEqual(ids("mail", Array(many.reversed())), [11, 10, 9, 8, 7])
  }

  @MainActor func testNavigationStaysVisibleAndCommandsAreDiscoverable() {
    let tabs = (1...30).map { CommandBar.TabCandidate(id: UInt64($0), title: "Mail \($0)", url: "https://mail.test/\($0)", profile: "default") }
    let results = CommandBar.suggestions(query: "mail", tabs: tabs, profile: "default", active: nil)
    XCTAssertEqual(results.count, 6)
    XCTAssertEqual(results.last?.query, "mail")
    let commands = ["settings": "Settings", "mods": "Manage mods", "reload": "Reload page"]
    XCTAssertEqual(PaletteSuggestions.actions(query: ":set", commands: commands).map(\.query), [":settings"])
    XCTAssertEqual(PaletteSuggestions.actions(query: "reload", commands: commands).map(\.query), [":reload"])
    XCTAssertEqual(PaletteSuggestions.actions(query: "", commands: commands).map(\.query), [":mods", ":settings", ":task"])
  }

  @MainActor func testExactActionIsSelectedAndEnterRunsIt() throws {
    let state = CommandPaletteState()
    state.query = "settings"
    state.commands = { ["settings": "Settings", "mods": "Manage mods"] }
    var command: String?
    state.command = { command = $0 }
    state.choose = { _ in XCTFail("Settings must not become a web search") }
    let renderer = CommandPaletteRenderer(state: state)
    renderer.activateScreen()
    XCTAssertEqual(state.results.first?.query, ":settings")
    let field = try XCTUnwrap(renderer.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    XCTAssertTrue(field.sendAction(field.action, to: field.target))
    XCTAssertEqual(command, "settings")
    state.opensInCurrentTab = true
    state.results = []
    state.selected = 0
    var search: String?
    state.choose = { search = $0.query }
    command = nil
    state.refresh()
    XCTAssertEqual(state.results.first?.query, "settings")
    XCTAssertTrue(field.sendAction(field.action, to: field.target))
    XCTAssertNil(command)
    XCTAssertEqual(search, "settings")
    state.query = ":settings"
    state.refresh()
    XCTAssertEqual(state.results.first?.query, ":settings")
    XCTAssertTrue(field.sendAction(field.action, to: field.target))
    XCTAssertEqual(command, "settings")
    XCTAssertTrue(PaletteSuggestions.actions(query: ":settings custom value", commands: state.commands()).isEmpty)
    let partial = PaletteSuggestions.results(query: "sett", tabs: [], profile: "default", active: nil, commands: state.commands())
    XCTAssertEqual(partial.first?.query, "sett")
  }

  @MainActor func testLongPromptWrapsAndExpandsInput() throws {
    let state = CommandPaletteState()
    var height: CGFloat = 0
    state.resize = { height = $0 }
    let renderer = CommandPaletteRenderer(state: state)
    renderer.frame.size = NSSize(width: 640, height: 94)
    renderer.activateScreen()
    let shortHeight = height
    state.query = String(repeating: "Hide exaggerated headphone claims and keep concrete specifications. ", count: 8)
    state.refresh()
    let field = try XCTUnwrap(renderer.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    XCTAssertTrue(field.cell?.wraps == true)
    XCTAssertEqual(field.lineBreakMode, .byWordWrapping)
    XCTAssertGreaterThan(height, shortHeight + 80)
    XCTAssertEqual(field.stringValue, state.query)
  }

  @MainActor func testDoIsRecognizedWithoutBackendCommands() throws {
    for query in [":do", ":do+"] {
      let state = CommandPaletteState()
      state.query = query
      state.commands = { ["profile": "Window in a profile", "settings": "Settings window"] }
      var command: String?
      state.command = { command = $0 }
      let renderer = CommandPaletteRenderer(state: state)
      renderer.activateScreen()
      XCTAssertTrue(state.results.isEmpty) // The scope cards replace command suggestions.
      let field = try XCTUnwrap(renderer.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
      XCTAssertTrue(field.sendAction(field.action, to: field.target))
      XCTAssertEqual(command, String(query.dropFirst()))
    }
  }

  @MainActor func testModPromptSubmitsVisibleScopeWithoutWaitingForSuggestion() throws {
    let state = CommandPaletteState()
    state.modScope.reset(url: "https://example.com")
    state.modScope.choose("browser")
    state.query = ":do Add a tab organizer"
    var submitted: String?
    state.command = { submitted = $0 }
    state.dismiss = { state.modScope.freeze() }
    let renderer = CommandPaletteRenderer(state: state)
    renderer.frame.size = NSSize(width: 640, height: 204)
    renderer.activateScreen()
    let field = try XCTUnwrap(renderer.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    XCTAssertTrue(field.sendAction(field.action, to: field.target))
    XCTAssertEqual(submitted, "do Add a tab organizer")
    XCTAssertEqual(state.modScope.selected, "browser")
    if let directory = ProcessInfo.processInfo.environment["BOWSER_MODSMITH_RENDER"],
       let bitmap = renderer.bitmapImageRepForCachingDisplay(in: renderer.bounds) {
      renderer.layoutSubtreeIfNeeded()
      renderer.cacheDisplay(in: renderer.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("omnibar-scope.png"))
    }
  }

  @MainActor func testCreateModButtonPreservesTypedRequest() throws {
    let state = CommandPaletteState()
    state.query = "Add a notes sidebar"
    var command: String?
    var dismissed = false
    state.command = { command = $0 }
    state.dismiss = { dismissed = true }
    let renderer = CommandPaletteRenderer(state: state)
    renderer.activateScreen()
    let button = try XCTUnwrap(renderer.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "palette-create-mod" })
    button.performClick(nil)
    XCTAssertTrue(dismissed)
    XCTAssertEqual(command, "new-mod Add a notes sidebar")
  }

  func testTaskCommandsDistinguishDraftsFromImmediateRunsAndPreserveModCommands() throws {
    for (command, kind, start, draft) in [
      ("task Export this table\nas CSV", "task", true, "Export this table\nas CSV"),
      ("task", "task", false, ""),
      ("new-task Export this table", "task", false, "Export this table"),
      ("do Add a sidebar", "mod", true, "Add a sidebar"),
      ("do+ Change the sidebar", "mod", true, "Change the sidebar"),
      ("new-mod Add a sidebar", "mod", false, "Add a sidebar")
    ] {
      let request = try XCTUnwrap(PaletteRequest(command: command))
      XCTAssertEqual(request.kind, kind)
      XCTAssertEqual(request.start, start)
      XCTAssertEqual(request.draft, draft)
    }
    for command in ["tasks", "taskboard open", "settings", "https://example.com/task"] {
      XCTAssertNil(PaletteRequest(command: command))
    }
  }

  @MainActor func testTaskActionIsDiscoverableAndTaskPromptSubmitsWithoutSearch() throws {
    for query in ["task", ":task", ":task Export this table as CSV"] {
      let state = CommandPaletteState()
      state.modScope.reset(url: "https://example.com/report")
      state.query = query
      var command: String?
      state.command = { command = $0 }
      state.choose = { _ in XCTFail("A task must not navigate or search") }
      let renderer = CommandPaletteRenderer(state: state)
      renderer.activateScreen()
      if query == "task" {
        XCTAssertEqual(state.results.first?.query, ":task")
        let cell = try XCTUnwrap(renderer.tableView(NSTableView(), viewFor: nil, row: 0) as? NSTableCellView)
        XCTAssertEqual(cell.textField?.stringValue, "Run a task…")
      } else {
        XCTAssertTrue(state.results.isEmpty)
      }
      let field = try XCTUnwrap(renderer.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
      XCTAssertTrue(field.sendAction(field.action, to: field.target))
      XCTAssertEqual(command, query.hasPrefix(":") ? String(query.dropFirst()) : query)
    }
  }

  @MainActor func testRunTaskButtonPreservesTypedRequestAndNavigationDefault() throws {
    let state = CommandPaletteState()
    state.query = "Export this table as CSV"
    var command: String?
    var dismissed = false
    state.command = { command = $0 }
    state.dismiss = { dismissed = true }
    let renderer = CommandPaletteRenderer(state: state)
    renderer.frame.size = NSSize(width: 640, height: 146)
    renderer.activateScreen()
    XCTAssertEqual(state.results.first?.query, state.query)
    let button = try XCTUnwrap(renderer.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "palette-run-task" })
    XCTAssertFalse(button.isHidden)
    if let path = ProcessInfo.processInfo.environment["BOWSER_TASK_COMMAND_RENDER"] {
      renderer.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(renderer.bitmapImageRepForCachingDisplay(in: renderer.bounds))
      renderer.cacheDisplay(in: renderer.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
    button.performClick(nil)
    XCTAssertTrue(dismissed)
    XCTAssertEqual(command, "new-task Export this table as CSV")
  }

  @MainActor func testCommandBarTaskUsesPageCapturedWhenPaletteOpened() throws {
    let controller = BrowserWindowController(profile: .defaultProfile)
    let workspace = ModSmithWindow.shared.model
    let originalSend = workspace.send
    let originalConnected = workspace.connected
    defer {
      CommandBar.shared.hide()
      controller.window?.close()
      NSApp.windows.first { $0.title == "Tasks & Mods" }?.close()
      workspace.send = originalSend
      workspace.connected = originalConnected
    }
    workspace.send = { _ in }
    workspace.connected = { true }
    let target = try XCTUnwrap(controller.activeTab)
    target.restore(urlString: "https://example.com/report")
    CommandBar.shared.show(for: controller)
    // An unrelated tab change must not redirect the pending request.
    controller.openTab().restore(urlString: "https://other.test/")
    let panel = try XCTUnwrap(NSApp.windows.first { $0 is NSPanel && ($0 as? BrowserOwnedPanel)?.browserOwner === controller })
    func findButton(_ view: NSView) -> NSButton? {
      if let button = view as? NSButton, button.accessibilityIdentifier() == "palette-run-task" { return button }
      return view.subviews.lazy.compactMap(findButton).first
    }
    try XCTUnwrap(findButton(try XCTUnwrap(panel.contentView))).performClick(nil)
    XCTAssertEqual(workspace.requestKind, "task")
    XCTAssertEqual(workspace.targetWebview, target.webviewId)
    XCTAssertEqual(workspace.targetURL, "https://example.com/report")
    XCTAssertNil(workspace.snapshot.selected)
  }

  @MainActor func testChoosingTabPreservesWebviewAndDoesNotOpenDuplicate() async throws {
    let controller = BrowserWindowController(profile: .defaultProfile)
    defer {
      CommandBar.shared.hide()
      controller.window?.close()
    }
    let original = try XCTUnwrap(controller.activeTab)
    let second = controller.openTab()
    second.webView.loadHTMLString(
      "<title>Inbox · Mail</title><p>Fixture</p>", baseURL: URL(string: "https://mail.example"))
    let third = controller.openTab()
    third.webView.loadHTMLString(
      "<title>Project notes</title><p>Fixture</p>", baseURL: URL(string: "https://notes.example"))
    for _ in 0..<100 {
      if third.webView.title == "Project notes" && second.webView.title == "Inbox · Mail" { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    controller.activateTab(id: original.webviewId)
    let existing = Set(NSApp.windows.map(\.windowNumber))
    CommandBar.shared.show(for: controller)
    let result = try XCTUnwrap(CommandBar.shared.results.first { $0.tab?.id == second.webviewId })
    if let path = ProcessInfo.processInfo.environment["BOWSER_COMMAND_RENDER"],
      let panel = NSApp.windows.first(where: {
        !existing.contains($0.windowNumber) && $0 is NSPanel
      }),
      let view = panel.contentView
    {
      view.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
        to: URL(fileURLWithPath: path))
    }
    let count = controller.tabs.count
    CommandBar.shared.choose(result)
    XCTAssertTrue(controller.activeTab === second)
    XCTAssertEqual(controller.tabs.count, count)
  }
}
