import AppKit
import BowserSurfaceKit

enum PaletteSuggestions {
    typealias TabCandidate = CommandPaletteState.TabCandidate
    typealias Result = CommandPaletteState.Result
  static func suggestions(query: String, tabs: [TabCandidate], profile: String, active: UInt64?)
    -> [Result]
  {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.hasPrefix(":") else { return [] }
    let needle = query.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    let tokens = needle.split(whereSeparator: \.isWhitespace).map(String.init)
    let matches = tabs.enumerated().compactMap { index, tab -> (Int, Int, TabCandidate)? in
        guard tab.profile == profile, !query.isEmpty || tab.id != active else { return nil }
      let title = tab.title.folding(
        options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      let url = tab.url.folding(
        options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      guard tokens.allSatisfy({ (title + " " + url).contains($0) }) else { return nil }
      let score =
        title == needle || url == needle
        ? 0 : (title.hasPrefix(needle) || (URL(string: url)?.host ?? "").hasPrefix(needle) ? 1 : 2)
      return (score, index, tab)
    }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
    var results = matches.prefix(query.isEmpty ? 6 : 5).map { Result(tab: $0.2, query: query) }
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
        var commands = commands
        commands["do"] = "Create a mod"
        commands["do+"] = "Create a mod"
        return commands.keys.sorted().filter { name in
            if needle.isEmpty { return ["settings", "mods"].contains(name) }
            return name.lowercased().hasPrefix(needle) || (!text.hasPrefix(":") && (commands[name] ?? "").localizedCaseInsensitiveContains(needle))
        }.prefix(5).map { Result(tab: nil, query: ":" + $0) }
    }

}

@MainActor final class CommandPaletteRenderer: NSVisualEffectView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, BrowserScreenActivating {
    typealias Result = CommandPaletteState.Result
    let model: CommandPaletteState
    private let field = NSTextField()
    private let hint = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let createMod = NSButton(title: "Create a mod…", target: nil, action: nil)
    private let footer = NSTextField(labelWithString: "↑ ↓  Navigate      ↵  Open      esc  Dismiss")
    private let scroll = NSScrollView()
    private var results: [Result] = []
    private var inputHeight: NSLayoutConstraint!
    private var resultsTop: NSLayoutConstraint!
    init(state: CommandPaletteState) {
        self.model = state
        super.init(frame: .zero)
    let effect = self
    effect.material = .popover
    effect.state = .active
    effect.blendingMode = .behindWindow
    effect.maskImage = Self.roundedMask(radius: 14)
    effect.autoresizingMask = [.width, .height]

    field.cell?.wraps = true
    field.cell?.isScrollable = false
    field.lineBreakMode = .byWordWrapping
    field.maximumNumberOfLines = 0
    field.isBezeled = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 17)
    field.placeholderString = "Search the web, enter a URL, or find a tab"
    field.delegate = self
    field.target = self
    field.action = #selector(submitted)
    field.translatesAutoresizingMaskIntoConstraints = false

    hint.stringValue = "esc"
    hint.font = .systemFont(ofSize: 11, weight: .medium)
    hint.textColor = .secondaryLabelColor
    hint.translatesAutoresizingMaskIntoConstraints = false

    inputHeight = field.heightAnchor.constraint(equalToConstant: 24)
    inputHeight.isActive = true
    effect.addSubview(field)
    effect.addSubview(hint)
    NSLayoutConstraint.activate([
      field.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
      field.trailingAnchor.constraint(equalTo: hint.leadingAnchor, constant: -10),
      hint.widthAnchor.constraint(equalToConstant: 28),
      field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 18),
      hint.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
      hint.centerYAnchor.constraint(equalTo: field.centerYAnchor),
    ])
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result")))
    table.headerView = nil
    table.columnAutoresizingStyle = .noColumnAutoresizing
    table.rowHeight = 52
    table.intercellSpacing = .zero
    table.backgroundColor = .clear
    table.selectionHighlightStyle = .regular
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(resultClicked)
    table.setAccessibilityLabel("Search, tabs and actions")
    scroll.documentView = table
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.translatesAutoresizingMaskIntoConstraints = false
    effect.addSubview(scroll)
    resultsTop = scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 16)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8),
      scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
      resultsTop,
      scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -36),
    ])

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(footer)
        createMod.bezelStyle = .inline
        createMod.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        createMod.imagePosition = .imageLeading
        createMod.target = self
        createMod.action = #selector(createModClicked)
        createMod.translatesAutoresizingMaskIntoConstraints = false
        createMod.setAccessibilityIdentifier("palette-create-mod")
        effect.addSubview(createMod)
        NSLayoutConstraint.activate([
            createMod.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            createMod.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: createMod.leadingAnchor, constant: -16),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(state:)") }
    override func layout() {
        super.layout()
        table.tableColumns.first?.width = max(0, scroll.contentSize.width - 20)
    }
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
        field.stringValue = model.query
        field.placeholderString = model.placeholder
        updateMode()
    }
    private func hide() { model.dismiss() }
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

  func controlTextDidChange(_ obj: Notification) { model.selected = 0; updateMode() }

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
    refreshResults()
    model.query = field.stringValue
    field.font = .systemFont(ofSize: 17)
    field.textColor = .textColor
    styleEditor(font: .systemFont(ofSize: 17), color: .textColor)
    hint.stringValue = "esc"

  }


    private func refreshResults() {
        results = PaletteSuggestions.results(query: field.stringValue, tabs: model.tabs(), profile: model.profile, active: model.active, commands: model.commands())
        model.results = results
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes(IndexSet(integer: min(model.selected, results.count - 1)), byExtendingSelection: false) }
        scroll.isHidden = results.isEmpty
        let width = max(200, bounds.width > 0 ? bounds.width - 70 : 570)
        let text = field.stringValue.isEmpty ? " " : field.stringValue
        let measured = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 17)])
        let height = max(24, min(240, ceil(measured.height) + 6))
        inputHeight.constant = height
        model.resize(70 + height + CGFloat(min(results.count, 8)) * 52)
        updateFooter()
        needsLayout = true
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if results.indices.contains(table.selectedRow) { model.selected = table.selectedRow }
        updateFooter()
    }
    private func updateFooter() {
        let selected = results.indices.contains(table.selectedRow) ? results[table.selectedRow] : nil
        let action = selected?.tab != nil ? "Switch tab" : selected?.query.hasPrefix(":") == true ? "Run action" : "Open"
        footer.stringValue = "↑ ↓  Navigate      ↵  \(action)      esc  Dismiss"
    }
    @objc private func createModClicked() {
        let draft = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        hide()
        model.command("new-mod " + draft)
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
    let command = result.tab == nil && result.query.hasPrefix(":") ? String(result.query.dropFirst()) : nil
    let navigating = result.query.contains("://") || (result.query.contains(".") && !result.query.contains(" ")) || result.query.hasPrefix("/")
    let label = command.flatMap { model.commands()[$0] } ?? (result.tab != nil ? result.title : navigating ? "Go to \(result.query)" : "Search \(SearchEngine.selected().title) for “\(result.query)”")
    let title = NSTextField(labelWithString: label)
    title.font = .systemFont(ofSize: 13, weight: .medium)
    title.lineBreakMode = .byTruncatingTail
    let detail = NSTextField(labelWithString: command.map { ":" + $0 } ?? (result.tab?.url ?? "Open in a new tab"))
    let badge = NSTextField(labelWithString: command != nil ? "Action" : result.tab != nil ? "Open tab" : navigating ? "Website" : "Search")
    badge.font = .systemFont(ofSize: 10, weight: .medium)
    badge.textColor = .secondaryLabelColor
    badge.setContentCompressionResistancePriority(.required, for: .horizontal)
    badge.setContentHuggingPriority(.required, for: .horizontal)
    detail.font = .systemFont(ofSize: 11)
    detail.textColor = .secondaryLabelColor
    detail.lineBreakMode = .byTruncatingMiddle
    let icon = NSImageView()
    icon.image =
      result.tab?.favicon.flatMap { NSImage(contentsOfFile: $0) }
      ?? NSImage(
        systemSymbolName: command != nil ? "command" : result.tab == nil ? (navigating ? "arrow.up.right" : "magnifyingglass") : "globe",
        accessibilityDescription: nil)
    icon.imageScaling = .scaleProportionallyUpOrDown
    for view in [icon, title, detail, badge] {
      view.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(view)
    }
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
      icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 24),
      icon.heightAnchor.constraint(equalToConstant: 24),
      title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
      title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
      title.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -12),
      badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
      badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
      detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
    ])
    cell.textField = title
    cell.imageView = icon
    return cell
  }

  private func styleEditor(font: NSFont, color: NSColor) {
    guard let editor = field.currentEditor() as? NSTextView else { return }
    editor.font = font
    editor.textColor = color
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
    NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 7, yRadius: 7).fill()
  }
}
