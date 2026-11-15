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
    let location = NSButton(title: "New tab", target: nil, action: nil)
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
        location.bezelStyle = .rounded
        location.font = .systemFont(ofSize: 13)
        location.lineBreakMode = .byTruncatingTail
        location.imagePosition = .imageLeading
        location.imageScaling = .scaleProportionallyDown
        location.target = self; location.action = #selector(openAddress)
        location.setAccessibilityLabel("Address and search")
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
        location.title = parsed?.host ?? (title.isEmpty ? "Search or enter website name" : title)
        location.toolTip = [title, url].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        location.setAccessibilityValue(url ?? title)
        let image = (icon?.copy() as? NSImage) ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        image?.size = NSSize(width: 16, height: 16)
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
