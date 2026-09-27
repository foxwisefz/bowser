import AppKit
import XCTest
import BowserSurfaceKit

@testable import Bowser

final class CommandBarTests: XCTestCase {
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

  @MainActor func testNavigationStaysVisibleAndCommandsAreDiscoverable() {
    let tabs = (1...30).map { CommandBar.TabCandidate(id: UInt64($0), title: "Mail \($0)", url: "https://mail.test/\($0)", profile: "default") }
    let results = CommandBar.suggestions(query: "mail", tabs: tabs, profile: "default", active: nil)
    XCTAssertEqual(results.count, 6)
    XCTAssertEqual(results.last?.query, "mail")
    let commands = ["settings": "Settings", "mods": "Manage mods", "reload": "Reload page"]
    XCTAssertEqual(PaletteSuggestions.actions(query: ":set", commands: commands).map(\.query), [":settings"])
    XCTAssertEqual(PaletteSuggestions.actions(query: "reload", commands: commands).map(\.query), [":reload"])
    XCTAssertEqual(PaletteSuggestions.actions(query: "", commands: commands).count, 2)
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
    let button = try XCTUnwrap(renderer.subviews.compactMap { $0 as? NSButton }.first)
    button.performClick(nil)
    XCTAssertTrue(dismissed)
    XCTAssertEqual(command, "new-mod Add a notes sidebar")
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
