import AppKit
import SwiftUI
import BowserSurfaceKit

struct PaletteRequest {
    let draft: String
    let kind: String
    let start: Bool

    init?(command: String) {
        let parts = command.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let name = parts.first, ["task", "new-task", "do", "do+", "new-mod"].contains(name) else { return nil }
        draft = parts.count == 2 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        kind = ["task", "new-task"].contains(name) ? "task" : "mod"
        start = !name.hasPrefix("new-") && !draft.isEmpty
    }
}

@MainActor enum PaletteSuggestions {
    typealias TabCandidate = CommandPaletteState.TabCandidate
    typealias Result = CommandPaletteState.Result
    private struct SearchEntry {
        let tab: TabCandidate
        let title: String
        let url: String
        let text: String
    }
    // Keep only the latest snapshot. Keystrokes reuse normalized strings;
    // changed titles, URLs, profiles, ordering or locale rebuild the index.
    private static var indexedTabs: [TabCandidate] = []
    private static var indexedLocale: Locale?
    private static var index: [SearchEntry] = []

    static func suggestions(query: String, tabs: [TabCandidate], profile: String, active: UInt64?) -> [Result] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.hasPrefix(":") else { return [] }
        let locale = Locale.current
        if indexedLocale != locale || indexedTabs != tabs {
            index = tabs.map { tab in
                let title = tab.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
                let url = tab.url.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
                return SearchEntry(tab: tab, title: title, url: url, text: title + " " + url)
            }
            indexedTabs = tabs
            indexedLocale = locale
        }
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        let tokens = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        // Scores have only three values. Preserve tab order within each score
        // and retain only the visible result limit instead of sorting all tabs.
        let limit = query.isEmpty ? 6 : 5
        var buckets = [[TabCandidate]](repeating: [], count: 3)
        for entry in index where entry.tab.profile == profile && (!query.isEmpty || entry.tab.id != active) {
            guard tokens.allSatisfy({ entry.text.contains($0) }) else { continue }
            let score = entry.title == needle || entry.url == needle ? 0
                : (entry.title.hasPrefix(needle) || (URL(string: entry.url)?.host ?? "").hasPrefix(needle) ? 1 : 2)
            if buckets[score].count < limit { buckets[score].append(entry.tab) }
        }
        var results = buckets.joined().prefix(limit).map { Result(tab: $0, query: query) }
        if !query.isEmpty { results.append(Result(tab: nil, query: query)) }
        return results
    }
    static func results(query: String, tabs: [TabCandidate], profile: String, active: UInt64?, commands: [String: String]) -> [Result] {
        let navigation = suggestions(query: query, tabs: tabs, profile: profile, active: active)
        let actions = actions(query: query, commands: commands)
        let exact = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        // Full action names are intentional; partial words still prefer tabs/search.
        let preferred = actions.filter { $0.query.lowercased() == ":" + exact }
        return preferred + navigation + actions.filter { $0.query.lowercased() != ":" + exact }
    }

    static func actions(query: String, commands: [String: String]) -> [Result] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(":"), text.contains(where: \.isWhitespace) { return [] }
        let needle = (text.hasPrefix(":") ? String(text.dropFirst()) : text).lowercased()
        let commands = commandLabels(commands)
        return commands.keys.sorted().filter { name in
            if needle.isEmpty { return ["settings", "mods", "task"].contains(name) }
            return name.lowercased().hasPrefix(needle) || (!text.hasPrefix(":") && (commands[name] ?? "").localizedCaseInsensitiveContains(needle))
        }.prefix(5).map { Result(tab: nil, query: ":" + $0) }
    }

    static func commandLabels(_ commands: [String: String]) -> [String: String] {
        commands.merging(["task": "Run a task…", "do": "Create a mod…", "do+": "Create a mod…"]) { _, builtIn in builtIn }
    }
}

@MainActor final class CommandPaletteRenderer: NSVisualEffectView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, BrowserScreenActivating {
    typealias Result = CommandPaletteState.Result
    let model: CommandPaletteState
    private let field = NSTextField()
    private let searchIcon = NSImageView()
    private let dismissButton = NSButton()
    private let table = NSTableView()
    private let createMod = NSButton(title: "Create a mod…", target: nil, action: nil)
    private let runTask = NSButton(title: "Run a task…", target: nil, action: nil)
    private let footer = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let rule = NSBox()
    private var scopeCards: NSHostingView<ModScopeCards>!
    private var results: [Result] = []
    private var inputHeight: NSLayoutConstraint!
    private var footerTrailing: NSLayoutConstraint!
    private static let rowHeight: CGFloat = 46

    init(state: CommandPaletteState) {
        self.model = state
        super.init(frame: .zero)
        material = .popover
        self.state = .active
        blendingMode = .behindWindow
        maskImage = Self.roundedMask(radius: 16)
        autoresizingMask = [.width, .height]

        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        searchIcon.setAccessibilityElement(false)
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.setAccessibilityHelp("Use the arrow keys to select a result and Return to open it.")
        field.delegate = self
        field.target = self
        field.action = #selector(submitted)

        dismissButton.title = ""
        dismissButton.isBordered = false
        dismissButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        dismissButton.contentTintColor = .secondaryLabelColor
        dismissButton.target = self
        dismissButton.action = #selector(dismissClicked)
        dismissButton.toolTip = "Dismiss (Esc)"
        dismissButton.setAccessibilityLabel("Dismiss command bar")

        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result")))
        table.headerView = nil
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(resultClicked)
        table.setAccessibilityLabel("Search results")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        scopeCards = NSHostingView(rootView: ModScopeCards(choice: model.modScope, compact: true, onChoose: { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.field)
            self.updateFooter()
        }))
        scopeCards.isHidden = true

        footer.font = .systemFont(ofSize: 11, weight: .medium)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, symbol, action, identifier) in [
            (createMod, "sparkles", #selector(createModClicked), "palette-create-mod"),
            (runTask, "play.circle", #selector(runTaskClicked), "palette-run-task")
        ] {
            button.bezelStyle = .push
            button.controlSize = .small
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.symbolConfiguration = .init(pointSize: 11, weight: .medium)
            button.imagePosition = .imageLeading
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(identifier)
        }
        createMod.toolTip = "Build a reusable mod from this request"
        runTask.toolTip = "Run this request once on the current page"
        rule.boxType = .separator
        let headerRule = NSBox()
        headerRule.boxType = .separator
        for view: NSView in [field, searchIcon, dismissButton, scroll, scopeCards, footer, createMod, runTask, rule, headerRule] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        inputHeight = field.heightAnchor.constraint(equalToConstant: 26)
        footerTrailing = footer.trailingAnchor.constraint(lessThanOrEqualTo: runTask.leadingAnchor, constant: -8)
        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            searchIcon.widthAnchor.constraint(equalToConstant: 22),
            searchIcon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -8),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            inputHeight,
            dismissButton.widthAnchor.constraint(equalToConstant: 26),
            dismissButton.heightAnchor.constraint(equalToConstant: 26),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            dismissButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            headerRule.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            headerRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: headerRule.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: rule.topAnchor, constant: -6),
            scopeCards.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            scopeCards.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            scopeCards.topAnchor.constraint(equalTo: headerRule.bottomAnchor, constant: 8),
            scopeCards.heightAnchor.constraint(equalToConstant: 100),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -38),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            createMod.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            createMod.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            runTask.trailingAnchor.constraint(equalTo: createMod.leadingAnchor, constant: -10),
            runTask.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            footerTrailing,
            footer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(state:)") }
    func activateScreen() {
        model.refresh = { [weak self] in self?.refresh() }
        model.focus = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.field)
            self.field.currentEditor()?.selectAll(nil)
        }
        refresh()
    }
    private func refresh() {
        if field.stringValue != model.query { field.stringValue = model.query }
        field.placeholderString = model.placeholder
        updateMode()
    }
    private func hide() { model.dismiss() }
    @objc private func dismissClicked() { hide() }
    private func choose(_ result: Result) {
        if result.tab == nil, result.query.hasPrefix(":") {
            hide(); model.command(String(result.query.dropFirst()))
        } else { model.choose(result) }
    }
  @objc private func submitted() {
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if results.indices.contains(table.selectedRow) {
      choose(results[table.selectedRow])
      return
    }
    guard !text.isEmpty else { return hide() }

    hide()
    if text.hasPrefix(":") { model.command(String(text.dropFirst())) }
    else { model.choose(Result(tab: nil, query: text)) }
  }

  func controlTextDidChange(_ obj: Notification) {
    model.selected = 0
    model.results = []
    if let prompt = modPrompt { model.modScope.update(prompt) } else { model.modScope.cancel() }
    updateMode()
  }
  private var request: PaletteRequest? {
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix(":") else { return nil }
    return PaletteRequest(command: String(text.dropFirst()))
  }
  private var modPrompt: String? { request.flatMap { $0.kind == "mod" ? $0.draft : nil } }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(NSResponder.cancelOperation(_:)) {
      hide()
      return true
    }
    if selector == #selector(NSResponder.moveDown(_:))
      || selector == #selector(NSResponder.moveUp(_:))
    {
      guard !results.isEmpty else { return true }
      let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
      let index = max(0, min(results.count - 1, table.selectedRow + delta))
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      table.scrollRowToVisible(index)
      model.selected = index
      return true
    }
    return false
  }

  private func updateMode() {
    model.query = field.stringValue
    field.setAccessibilityLabel(model.placeholder)
    let symbol: String
    if request?.kind == "task" { symbol = "play.circle" }
    else if modPrompt != nil { symbol = "sparkles" }
    else { symbol = model.opensInCurrentTab ? "globe" : "magnifyingglass" }
    searchIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    refreshResults()
  }

    private func refreshResults() {
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // History arrives after the first keystroke results. Keep Return attached to
        // the same destination even when a new match moves its row farther down.
        let previous = model.results.indices.contains(model.selected) ? model.results[model.selected] : nil
        if !query.hasPrefix(":") { model.searchHistory(field.stringValue) }
        results = request != nil ? [] : PaletteSuggestions.results(query: query, tabs: model.tabs(), profile: model.profile, active: model.active, commands: model.commands())
        if !query.hasPrefix(":") {
            let openURLs = Set(results.compactMap { $0.tab?.url })
            let history = model.historyResults.filter { !openURLs.contains($0.url) }.prefix(3).map { Result(history: $0, query: query) }
            let insertion = results.firstIndex { $0.tab == nil && !$0.query.hasPrefix(":") } ?? results.endIndex
            results.insert(contentsOf: history, at: insertion)
            if model.opensInCurrentTab, let direct = results.firstIndex(where: { $0.tab == nil && $0.history == nil && $0.query == query }) {
                let result = results.remove(at: direct)
                results.insert(result, at: 0)
            }
        }
        let selection = previous.flatMap { results.firstIndex(of: $0) } ?? model.selected
        model.results = results
        table.reloadData()
        if !results.isEmpty {
            let row = min(max(0, selection), results.count - 1)
            model.selected = row
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        scroll.isHidden = results.isEmpty
        scopeCards.isHidden = modPrompt == nil
        createMod.isHidden = request != nil
        runTask.isHidden = request != nil
        footerTrailing.isActive = request == nil
        rule.isHidden = results.isEmpty && modPrompt == nil
        let width = max(120, bounds.width > 0 ? bounds.width - 98 : 542)
        let text = field.stringValue.isEmpty ? " " : field.stringValue
        let measured = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: field.font ?? NSFont.systemFont(ofSize: 18)])
        let height = max(26, min(240, ceil(measured.height) + 6))
        inputHeight.constant = height
        let contentHeight = modPrompt != nil ? 116 : CGFloat(min(results.count, 8)) * Self.rowHeight
        model.resize(78 + height + contentHeight)
        updateFooter()
        needsLayout = true
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if results.indices.contains(table.selectedRow) { model.selected = table.selectedRow }
        updateFooter()
    }
    private func updateFooter() {
        let selected = results.indices.contains(table.selectedRow) ? results[table.selectedRow] : nil
        let action = selected?.tab != nil ? "Switch tab" : (selected?.query ?? field.stringValue).hasPrefix(":") ? "Run command" : "Open"
        if request?.kind == "task" {
            footer.stringValue = model.modScope.host != nil ? "This page only · ↵ Run once" : "Open a website to run a task"
            return
        }
        if modPrompt != nil {
            footer.stringValue = model.modScope.valid ? "Choose where it applies · ↵ Create mod" : "Choose Across Bowser, or open a website"
            return
        }
        footer.stringValue = bounds.width >= 520 ? "↑↓  Select      ↵  \(action)" : "↵  \(action)"
    }
    @objc private func createModClicked() {
        let draft = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        hide()
        model.command("new-mod " + draft)
    }
    @objc private func runTaskClicked() {
        let draft = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        hide()
        model.command("new-task " + draft)
    }
    @objc private func resultClicked() {
        guard results.indices.contains(table.clickedRow) else { return }
        choose(results[table.clickedRow])
    }
  func numberOfRows(in tableView: NSTableView) -> Int { results.count }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    CommandResultRow()
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let result = results[row]
    let cell = NSTableCellView()
    let command = result.tab == nil && result.history == nil && result.query.hasPrefix(":") ? String(result.query.dropFirst()) : nil
    let titleText: String
    let detailText: String
    let symbol: String
    if let tab = result.tab {
        symbol = "macwindow.on.rectangle"
        titleText = result.title
        detailText = tab.url.isEmpty ? "Open tab" : "Open tab · \(Self.displayAddress(tab.url))"
    } else if let history = result.history {
        symbol = "clock.arrow.circlepath"
        titleText = result.title
        let site = URL(string: history.url)?.host ?? Self.displayAddress(history.url)
        detailText = ["History", site, history.snippet].filter { !$0.isEmpty }.joined(separator: " · ")
    } else if let command {
        symbol = "command"
        titleText = PaletteSuggestions.commandLabels(model.commands())[command] ?? command
        detailText = "Command · :\(command)"
    } else {
        let value = result.query
        let file = value.hasPrefix("/") || value.hasPrefix("~/") || value.lowercased().hasPrefix("file://")
        let address = file || value.contains("://") || (value.contains(".") && !value.contains(" "))
        symbol = file ? "doc" : address ? "globe" : "magnifyingglass"
        titleText = value
        let destination = model.opensInCurrentTab ? "this tab" : "a new tab"
        detailText = address ? "Open in \(destination)" : "Search \(SearchEngine.selected().title) in \(destination)"
    }
    let title = NSTextField(labelWithString: titleText)
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    title.lineBreakMode = .byTruncatingTail
    let detail = NSTextField(labelWithString: detailText)
    detail.font = .systemFont(ofSize: 11)
    detail.textColor = .secondaryLabelColor
    detail.lineBreakMode = .byTruncatingTail
    let icon = NSImageView()
    icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
    icon.image = result.history?.image.flatMap { NSImage(data: $0) }
        ?? result.tab?.favicon.flatMap { NSImage(contentsOfFile: $0) }
        ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    icon.imageScaling = .scaleProportionallyUpOrDown
    for view in [icon, title, detail] {
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
    }
    NSLayoutConstraint.activate([
        icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
        icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        icon.widthAnchor.constraint(equalToConstant: 20),
        icon.heightAnchor.constraint(equalToConstant: 20),
        title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
        title.bottomAnchor.constraint(equalTo: cell.centerYAnchor),
        title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
        detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
        detail.topAnchor.constraint(equalTo: cell.centerYAnchor, constant: 2),
        detail.trailingAnchor.constraint(equalTo: title.trailingAnchor)
    ])
    cell.textField = title
    cell.imageView = icon
    cell.setAccessibilityLabel("\(titleText), \(detailText)")
    return cell
  }

  private static func displayAddress(_ url: String) -> String {
    if url.hasPrefix("https://") { return String(url.dropFirst(8)) }
    if url.hasPrefix("http://") { return String(url.dropFirst(7)) }
    return url
  }

  private static func roundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }
}

private final class CommandResultRow: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8)
    NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
    outline.fill()
    if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
        NSColor.controlAccentColor.setStroke()
        outline.stroke()
    }
  }
}
