import AppKit

/// AppKit owns the single titlebar, its material, traffic lights and fullscreen
/// behavior. Custom items retain the same views across tab and module changes.
@MainActor final class BrowserToolbar: NSObject, NSToolbarDelegate {
    static let controlsID = NSToolbarItem.Identifier("browser.controls")
    static let locationID = NSToolbarItem.Identifier("browser.location")
    static let profileID = NSToolbarItem.Identifier("browser.profile")

    // NSToolbar synchronizes item insertion/removal between matching identifiers,
    // even without customization. Each window owns its profile-specific items.
    let toolbar = NSToolbar(identifier: "BrowserToolbar." + UUID().uuidString)
    let location = BrowserLocationButton()
    private let controls: NSView
    private let profile: NSView
    private let loading: ToolbarLoadingLine
    private let editAddress: () -> Void
    private var controlsWidth: NSLayoutConstraint!

    init(controls: NSView, profile: NSView, loading: ToolbarLoadingLine,
         editAddress: @escaping () -> Void) {
        self.controls = controls; self.profile = profile; self.loading = loading
        self.editAddress = editAddress
        super.init()
        controls.translatesAutoresizingMaskIntoConstraints = false
        controlsWidth = controls.widthAnchor.constraint(equalToConstant: 202)
        NSLayoutConstraint.activate([controlsWidth, controls.heightAnchor.constraint(equalToConstant: 28)])
        location.isBordered = false
        location.font = .systemFont(ofSize: 13)
        location.lineBreakMode = .byTruncatingMiddle
        location.imagePosition = .imageLeading
        location.imageHugsTitle = true
        location.focusRingType = .exterior
        location.imageScaling = .scaleProportionallyDown
        location.target = self; location.action = #selector(openAddress)
        location.setAccessibilityLabel("Address and search")
        location.setAccessibilityHelp("Press to edit the address or search. Command L.")
        location.setAccessibilityIdentifier("browser.location")
        location.translatesAutoresizingMaskIntoConstraints = false
        let preferred = location.widthAnchor.constraint(equalToConstant: 480)
        preferred.priority = .defaultLow
        NSLayoutConstraint.activate([preferred, location.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            location.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            location.heightAnchor.constraint(equalToConstant: 28)])
        loading.translatesAutoresizingMaskIntoConstraints = false
        location.addSubview(loading)
        NSLayoutConstraint.activate([
            loading.leadingAnchor.constraint(equalTo: location.leadingAnchor, constant: 10),
            loading.trailingAnchor.constraint(equalTo: location.trailingAnchor, constant: -10),
            loading.bottomAnchor.constraint(equalTo: location.bottomAnchor, constant: -2),
            loading.heightAnchor.constraint(equalToConstant: 2)])
        profile.translatesAutoresizingMaskIntoConstraints = false
        profile.widthAnchor.constraint(lessThanOrEqualToConstant: 110).isActive = true
        profile.heightAnchor.constraint(equalToConstant: 24).isActive = true
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.locationID]
        updateLocation(url: nil, title: "", icon: nil)
    }

    @objc private func openAddress() { editAddress() }

    func setControlsWidth(_ width: CGFloat) {
        if controlsWidth.constant != width { controlsWidth.constant = width }
    }

    func setProfileVisible(_ visible: Bool) {
        let index = toolbar.items.firstIndex { $0.itemIdentifier == Self.profileID }
        guard visible != (index != nil) else { return }
        if visible {
            toolbar.insertItem(withItemIdentifier: Self.profileID, at: toolbar.items.count)
        } else if let index {
            toolbar.removeItem(at: index)
        }
    }

    func updateLocation(url: String?, title: String, icon: NSImage?) {
        let parsed = url.flatMap(URL.init(string:))
        let blank = (url ?? "").isEmpty || url == "about:blank"
        let symbol: String
        if blank {
            symbol = "magnifyingglass"
            location.title = "Search or enter an address"
        } else if url == EngineView.historyURL {
            symbol = "clock"
            location.title = "History"
        } else if let parsed, parsed.isFileURL {
            symbol = "doc"
            location.title = parsed.lastPathComponent.isEmpty ? parsed.path : parsed.lastPathComponent
        } else if let host = parsed?.host {
            symbol = "globe"
            let scheme = parsed?.scheme?.lowercased()
            let prefix = scheme == "https" ? "" : scheme.map { $0 + "://" } ?? ""
            location.title = prefix + host + (parsed?.port.map { ":\($0)" } ?? "")
        } else {
            symbol = "doc"
            location.title = parsed?.scheme == "data" ? "Data URL" : (url ?? title)
        }
        location.contentTintColor = blank ? .secondaryLabelColor : .labelColor
        location.toolTip = blank ? "Search or enter an address (⌘L)"
            : [title, url].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        location.setAccessibilityValue(blank ? "" : url)
        let favicon = symbol == "globe" ? icon?.copy() as? NSImage : nil
        let image = favicon ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        if favicon != nil { image?.size = NSSize(width: 16, height: 16) }
        location.image = image
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.controlsID, .flexibleSpace, Self.locationID, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [Self.profileID]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Self.controlsID: item.view = controls; item.label = "Browser controls"
        case Self.locationID: item.view = location; item.label = "Address and search"
        case Self.profileID: item.view = profile; item.label = "Profile"
        default: return nil
        }
        item.visibilityPriority = identifier == Self.locationID ? .high : .standard
        return item
    }
}

/// One native button owns the whole address target, including its focus ring.
/// The field-shaped background distinguishes it from the toolbar's commands.
@MainActor final class BrowserLocationButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private var hovered = false

    private var outline: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        if let window { hovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let path = outline
        let hover = hovered && window?.isKeyWindow == true
        NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.15 : hover ? 0.10 : 0.065).setFill()
        path.fill()
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        (highContrast ? NSColor.secondaryLabelColor : NSColor.separatorColor).setStroke()
        path.lineWidth = highContrast ? 1.5 : 0.5
        path.stroke()
        super.draw(dirtyRect)
    }

    override func drawFocusRingMask() { outline.fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}
