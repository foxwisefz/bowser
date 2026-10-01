import AppKit
import WebKit

/// Browser-owned search UI; WebKit owns matching, selection and scrolling.
@MainActor final class PageFindBar: NSVisualEffectView, NSSearchFieldDelegate {
    let field = NSSearchField()
    let status = NSTextField(labelWithString: "")
    private(set) var matchFound = false
    private weak var page: WKWebView?
    private var generation = 0
    private var pending: DispatchWorkItem?
    private var loading: NSKeyValueObservation?
    private var previous: NSButton!
    private var next: NSButton!
    var onClose: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.masksToBounds = true
        field.placeholderString = "Find in page"
        field.font = .systemFont(ofSize: 14)
        field.focusRingType = .none
        field.delegate = self
        field.setAccessibilityLabel("Find in page")
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.alignment = .right
        status.setContentHuggingPriority(.required, for: .horizontal)
        previous = button("chevron.up", "Previous match (⇧Return or ⇧⌘G)", #selector(previousMatch))
        next = button("chevron.down", "Next match (Return or ⌘G)", #selector(nextMatch))
        let close = button("xmark", "Close find (Esc)", #selector(closeFind))
        let divider = NSBox()
        divider.boxType = .separator
        let row = NSStackView(views: [field, status, previous, next, divider, close])
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 28),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            divider.heightAnchor.constraint(equalToConstant: 20),
            divider.widthAnchor.constraint(equalToConstant: 1)
        ])
        updateResult(nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    private func button(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.bezelStyle = .recessed
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    func present(for page: WKWebView) {
        let needsSearch = isHidden || self.page !== page
        if self.page !== page {
            clear()
            self.page = page
            loading = page.observe(\.isLoading, options: [.new]) { [weak self] page, _ in
                MainActor.assumeIsolated {
                    guard !page.isLoading, let self, !self.isHidden else { return }
                    self.search()
                }
            }
        }
        isHidden = false
        window?.makeFirstResponder(field)
        field.selectText(nil)
        if needsSearch { search() }
    }

    func dismiss() {
        clear()
        isHidden = true
        if let page { window?.makeFirstResponder(page) }
        page = nil
        loading = nil
    }

    private func clear() {
        generation += 1
        pending?.cancel()
        pending = nil
        page?.find("", configuration: WKFindConfiguration(), completionHandler: { _ in })
        updateResult(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        pending?.cancel()
        generation += 1 // Ignore replies for the previous query immediately.
        let work = DispatchWorkItem { [weak self] in self?.search() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    @objc private func previousMatch() { search(backwards: true) }
    @objc private func nextMatch() { search() }
    @objc private func closeFind() { onClose?() }

    func search(backwards: Bool = false) {
        pending?.cancel()
        pending = nil
        guard let page, !isHidden else { return }
        generation += 1
        let request = generation
        let query = field.stringValue
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        page.find(query, configuration: config) { [weak self, weak page] result in
            guard let self, self.generation == request, self.page === page, !self.isHidden else { return }
            self.updateResult(query.isEmpty ? nil : result.matchFound)
        }
    }

    private func updateResult(_ found: Bool?) {
        matchFound = found == true
        status.stringValue = found == false ? "No matches" : ""
        status.textColor = found == false ? .systemRed : .secondaryLabelColor
        previous.isEnabled = found == true
        next.isEnabled = found == true
        field.setAccessibilityHelp(found == false ? "No matches on this page" : "Return for next match, Shift Return for previous match")
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { onClose?(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            search(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            return true
        }
        return false
    }
}
