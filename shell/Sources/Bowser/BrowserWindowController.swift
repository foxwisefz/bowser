import BowserSurfaceKit
import AppKit
import SwiftUI
import WebKit

/// One window owns live tabs. Mods can mount selected tabs together in a
/// nested layout tree; detached tabs retain their DOM and navigation state.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    /// Every live window, in creation order. Strong: this is what owns them.
    let resourceID = UUID().uuidString
    private(set) static var all: [BrowserWindowController] = []

    /// The window holding a given webview, if any.
    static func host(of webviewId: UInt64) -> BrowserWindowController? {
        all.first { controller in controller.tabs.contains { $0.webviewId == webviewId } }
    }

    /// Every webview this window owns, in open order — mounted or not.
    private(set) var tabs: [EngineView] = []
    /// The focused tab; other panes may also be mounted. Closing the last tab closes the window.
    private(set) var activeTab: EngineView!

    /// The page area hosts one tab or a mod-defined website layout.
    private let container = ToolbarContainerView()
    private(set) var websiteLayout: WebsiteLayout?
    private var paneFocusMonitor: Any?
    private var band: BandScrimView!
    private var clusterHosting: NSHostingView<AnyView>?
    private var nativeToolbar: NativeModuleSlot?
    private let titleLabel = NSTextField(labelWithString: "")
    private let titleViewport = NSView()
    private var titleTextWidth: NSLayoutConstraint?
    private let notch = ToolbarNotchView()
    private let profileNotch = ToolbarNotchView()
    private let toolbarFavicon = NSImageView()
    private let profileIdentity = NSStackView()
    private var notchTitleWidth: NSLayoutConstraint?
    private var clusterWidth: NSLayoutConstraint?
    private var toolbarTop: NSLayoutConstraint?
    private var profileTop: NSLayoutConstraint?
    private var toolbarIntentObserver: ToolbarIntentObserver?
    private var profileIntentObserver: ToolbarIntentObserver?
    private(set) var isCaptureMode = false
    private var captureHiddenViews: [ObjectIdentifier: (view: NSView, hidden: Bool)] = [:]
    private var toolbarYielded = false
    private var toolbarIsVisible = true
    var toolbarHiddenFraction: CGFloat = 0.5 {
        didSet { setToolbarVisible(toolbarIsVisible, animated: false) }
    }
    /// The profile every tab of this window belongs to. Set once, right
    /// after the window exists and before its first tab is born.
    private(set) var profile: Profile = .defaultProfile
    private let profileBadge = NSTextField(labelWithString: "")
    private let profilePortrait = NSImageView()
    /// Hover reveals secondary toolbar actions; native window buttons stay put.
    private let reveal = ChromeReveal()
    private var revealHide: DispatchWorkItem?

    /// Windows of different profiles remember their frames separately (the
    /// default keeps the pre-profiles key).
    static func frameKey(for profile: Profile) -> String {
        profile.id == "default" ? "BowserWindowFrame" : "BowserWindowFrame." + profile.id
    }

    convenience init(profile requested: Profile? = nil) {
        let profile = requested ?? Profile.main
        let isSiteApp = SiteAppConfiguration.current != nil
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: isSiteApp ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey(for: profile)) {
            window.setFrame(NSRectFromString(saved), display: false)
        } else {
            window.center()
        }
        window.title = "Bowser"
        // The whole point: AppKit must never group our windows into tabs.
        // Without this, ⌘T/window-merge hands us a tab bar we then have to
        // fight — the whack-a-mole this bead exists to end.
        window.tabbingMode = .disallowed
        if !isSiteApp {
            window.toolbarStyle = .unifiedCompact
            // Let AppKit provide a taller titlebar and position its native buttons.
            // The transparent toolbar leaves the page visible between our two islands.
            window.toolbar = NSToolbar(identifier: "BrowserChromeSpacing")
        }
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = isSiteApp ? .visible : .hidden
        self.init(window: window)
        self.profile = profile

        window.delegate = self
        container.autoresizingMask = [.width, .height]
        window.contentView = container

        // Browser chrome overlays the page; there is no full-width toolbar band.
        let band = BandScrimView()
        band.isHidden = true
        self.band = band

        // The notch lives in the real titlebar, keeping native window controls
        // in place while its title expands to the right.
        if !isSiteApp {
        let fallback = NSHostingView(rootView: AnyView(clusterView()))
        let hosting = NativeModuleSlot(fallback: fallback)
        hosting.interactionInProgress = { TabDragPreview.shared.source != nil }
        hosting.onAction = { [weak self] event in self?.nativeToolbarAction(event) }
        nativeToolbar = hosting
        hosting.translatesAutoresizingMaskIntoConstraints = false
        if let titlebar = window.standardWindowButton(.closeButton)?.superview {
            notch.translatesAutoresizingMaskIntoConstraints = false
            notch.onHover = { [weak self] inside in self?.setToolbarHovered(inside) }
            titlebar.addSubview(notch, positioned: .below, relativeTo: nil)
            titlebar.addSubview(hosting)
            hosting.appearance = NSAppearance(named: .darkAqua)
            titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
            titleLabel.textColor = .white.withAlphaComponent(0.85)
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleLabel.alignment = .left
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.wantsLayer = true
            titleLabel.layer?.masksToBounds = true
            titleLabel.alphaValue = 0
            titleViewport.identifier = NSUserInterfaceItemIdentifier("toolbarTitleViewport")
            titleViewport.translatesAutoresizingMaskIntoConstraints = false
            titleViewport.wantsLayer = true
            titleViewport.layer?.masksToBounds = true
            notch.addSubview(titleViewport)
            titleViewport.addSubview(titleLabel)
            toolbarFavicon.translatesAutoresizingMaskIntoConstraints = false
            toolbarFavicon.imageScaling = .scaleProportionallyUpOrDown
            toolbarFavicon.contentTintColor = .white
            toolbarFavicon.setAccessibilityLabel("Active tab icon")
            notch.addSubview(toolbarFavicon)
            profileBadge.font = .systemFont(ofSize: 11, weight: .semibold)
            profileBadge.lineBreakMode = .byTruncatingTail
            profileBadge.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            profilePortrait.imageScaling = .scaleProportionallyUpOrDown
            profileIdentity.orientation = .horizontal
            profileIdentity.alignment = .centerY
            profileIdentity.spacing = 4
            profileIdentity.addArrangedSubview(profilePortrait)
            profileIdentity.addArrangedSubview(profileBadge)
            profileIdentity.translatesAutoresizingMaskIntoConstraints = false
            profileNotch.acceptsPointer = false
            profileNotch.translatesAutoresizingMaskIntoConstraints = false
            titlebar.addSubview(profileNotch, positioned: .below, relativeTo: nil)
            profileNotch.addSubview(profileIdentity)
            let titleWidth = titleViewport.widthAnchor.constraint(equalToConstant: 0)
            let textWidth = titleLabel.widthAnchor.constraint(equalToConstant: 220)
            titleTextWidth = textWidth
            let controlsWidth = hosting.widthAnchor.constraint(equalToConstant: 202)
            titleWidth.priority = .defaultHigh
            notchTitleWidth = titleWidth; clusterWidth = controlsWidth
            let lights = window.standardWindowButton(.zoomButton)!
            // Retain the reference button spacing inside concentric window insets.
            let scale = lights.frame.height / 29
            for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                guard let button = window.standardWindowButton(kind) else { continue }
                button.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    button.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor, constant: ToolbarCornerGeometry.inset + (15 + CGFloat(index) * 46) * scale + 4),
                    button.topAnchor.constraint(equalTo: notch.topAnchor, constant: (ToolbarCornerGeometry.height - lights.frame.height) / 2),
                    button.widthAnchor.constraint(equalToConstant: 29 * scale),
                    button.heightAnchor.constraint(equalToConstant: 29 * scale),
                ])
            }
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: lights.trailingAnchor, constant: 12),
                hosting.centerYAnchor.constraint(equalTo: lights.centerYAnchor),
                hosting.heightAnchor.constraint(equalToConstant: 24), controlsWidth,
                profileIdentity.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor, constant: -24),
                profileIdentity.leadingAnchor.constraint(equalTo: profileNotch.leadingAnchor, constant: 18),
                profileNotch.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor, constant: -ToolbarCornerGeometry.inset),
                profileNotch.heightAnchor.constraint(equalToConstant: ToolbarCornerGeometry.height),
                profileIdentity.centerYAnchor.constraint(equalTo: profileNotch.centerYAnchor),
                profileIdentity.widthAnchor.constraint(lessThanOrEqualToConstant: 110),
                profilePortrait.widthAnchor.constraint(equalToConstant: 20),
                profilePortrait.heightAnchor.constraint(equalToConstant: 20),
                toolbarFavicon.leadingAnchor.constraint(equalTo: hosting.trailingAnchor, constant: 8),
                toolbarFavicon.centerYAnchor.constraint(equalTo: lights.centerYAnchor),
                toolbarFavicon.widthAnchor.constraint(equalToConstant: 16),
                toolbarFavicon.heightAnchor.constraint(equalToConstant: 16),
                titleViewport.leadingAnchor.constraint(equalTo: toolbarFavicon.trailingAnchor, constant: 8),
                titleViewport.centerYAnchor.constraint(equalTo: lights.centerYAnchor),
                titleViewport.heightAnchor.constraint(equalToConstant: 24), titleWidth,
                titleLabel.leadingAnchor.constraint(equalTo: titleViewport.leadingAnchor),
                titleLabel.centerYAnchor.constraint(equalTo: titleViewport.centerYAnchor), textWidth,
                notch.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor, constant: ToolbarCornerGeometry.inset),
                notch.heightAnchor.constraint(equalToConstant: ToolbarCornerGeometry.height),
                notch.trailingAnchor.constraint(equalTo: titleViewport.trailingAnchor, constant: 12),
                notch.trailingAnchor.constraint(lessThanOrEqualTo: profileNotch.leadingAnchor, constant: -8),
                titleViewport.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            ])
            let top = notch.topAnchor.constraint(equalTo: titlebar.topAnchor, constant: ToolbarCornerGeometry.inset)
            toolbarTop = top
            top.isActive = true
            let identityTop = profileNotch.topAnchor.constraint(equalTo: titlebar.topAnchor, constant: ToolbarCornerGeometry.inset)
            profileTop = identityTop
            identityTop.isActive = true
            toolbarIntentObserver = ToolbarIntentObserver(window: window, target: { [weak self, weak window] in
                guard let self, let window else { return .zero }
                return NSRect(x: window.frame.minX + ToolbarCornerGeometry.inset,
                              y: window.frame.maxY - ToolbarCornerGeometry.inset - ToolbarCornerGeometry.height,
                              width: self.notch.frame.width, height: ToolbarCornerGeometry.height + ToolbarCornerGeometry.inset)
            }, interacting: { SurfaceServices.shared.hasInteractions }, changed: { [weak self] visible, yielded in
                self?.setToolbarIntent(visible: visible, yielded: yielded)
            })
            profileIntentObserver = ToolbarIntentObserver(window: window, mode: .reference, target: { [weak self, weak window] in
                guard let self, let window else { return .zero }
                let frame = window.convertToScreen(self.profileNotch.convert(self.profileNotch.bounds, to: nil))
                return NSRect(x: frame.minX,
                              y: window.frame.maxY - ToolbarCornerGeometry.inset - ToolbarCornerGeometry.height,
                              width: frame.width, height: ToolbarCornerGeometry.height)
            }, interacting: { false }, changed: { [weak self] visible, _ in
                self?.setProfileIndicatorVisible(visible)
            })
            band.isHidden = true

        }
        clusterHosting = fallback

        }
        refreshProfileBadge()

        let isFirstWindow = Self.all.isEmpty
        Self.all.append(self)
        ChromeSurface.register(self)
        CaptureMode.shared.register(self)

        // A window is never tabless: it arrives with its first webview.
        openTab(opener: (NSApp.delegate as? AppDelegate)?.currentWebviewId)

        // Freeze-frame resurrection (bowser-browser-9qr): the first window
        // of a fresh instance wears the previous life's last frame until
        // the restored active tab paints — respawn looks like a blink.
        if isFirstWindow { installResurrectOverlay() }

        // Continuous capture so the NEXT death has a fresh frame.
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isKeyWindow == true,
                      self.resurrectOverlay == nil,
                      let tab = self.activeTab else { return }
                tab.capturePreview()
            }
        }
    }

    // MARK: - Freeze-frame resurrection

    private var resurrectOverlay: ResurrectOverlayView?
    private var snapshotTimer: Timer?

    private func installResurrectOverlay() {
        guard let image = ResurrectFrame.loadImage() else { return }
        let overlay = ResurrectOverlayView(frame: container.bounds)
        overlay.image = image
        overlay.imageScaling = .scaleProportionallyUpOrDown
        overlay.imageAlignment = .alignCenter
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        overlay.autoresizingMask = [.width, .height]
        overlay.onDismiss = { [weak self] in self?.dismissResurrectOverlay() }
        container.addSubview(overlay, positioned: .above, relativeTo: band)
        resurrectOverlay = overlay
        // The frame must never outstay its welcome: if the restore is slow
        // or the paint signal is missed, drop it anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.dismissResurrectOverlay()
        }
    }

    /// Which webview's paint releases the freeze-frame: set by the brain's
    /// restore_done. Dismissing on any earlier paint shows the mid-restore
    /// double-switch (first tab loads urls[0] before activation).
    private var pendingRestorePaint: UInt64?

    /// This launch is a resurrection: a restore is incoming and nothing
    /// should pop over the freeze-frame (bowser-browser-xl8).
    var isResurrecting: Bool { resurrectOverlay != nil }

    func restoreDidComplete(id: UInt64) {
        guard resurrectOverlay != nil else { return }
        guard let view = tabs.first(where: { $0.webviewId == id }) else {
            dismissResurrectOverlay()
            return
        }
        if view.webView.isLoading {
            pendingRestorePaint = id
        } else {
            dismissResurrectOverlay()
        }
    }

    private func dismissResurrectOverlay() {
        guard let overlay = resurrectOverlay else { return }
        resurrectOverlay = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            overlay.animator().alphaValue = 0
        }, completionHandler: {
            overlay.removeFromSuperview()
        })
    }

    /// A webview finished painting; if it's the restore's designated active
    /// tab, the past can yield to the present.
    func engineDidPaint(_ view: EngineView) {
        if view.webviewId == pendingRestorePaint {
            pendingRestorePaint = nil
            dismissResurrectOverlay()
        }
    }

    static var orderedTabIDs: [UInt64] { all.flatMap { $0.tabs.map(\.webviewId) } }

    // MARK: - Tabs

    /// Create a webview owned by this window. It starts DETACHED — the state
    /// exists, nothing is on screen — and is mounted only if `activate`.
    @discardableResult
    func openTab(
        configuration: WKWebViewConfiguration? = nil,
        opener: UInt64? = nil,
        activate shouldActivate: Bool = true,
        append: Bool = false
    ) -> EngineView {
        // Born at the mount size so a background tab lays out for the real
        // viewport instead of loading into a 0×0 window.
        let view = EngineView(frame: container.pageArea.bounds, configuration: configuration, profile: profile)
        view.autoresizingMask = [.width, .height]
        wire(view)
        let anchor = activeTab.flatMap { active in tabs.firstIndex { $0 === active } }
        let coordinate = activeTab != nil && BrainBridge.shared.resources.shouldCoordinate
        tabs.insert(view, at: coordinate || append ? tabs.count : anchor.map { $0 + 1 } ?? tabs.count)

        // Emit BEFORE it can be mounted: consumers must see tab_opened
        // before the first tab_activated for this webview.
        var opened: [String: Any] = [
            "op": "event", "event": "tab_opened", "webview": view.webviewId,
        ]
        if let opener { opened["opener"] = opener } else { opened["opener"] = NSNull() }
        opened["profile"] = profile.id
        opened["order"] = Self.orderedTabIDs
        BrainBridge.shared.send(opened)

        if coordinate {
            _ = BrainBridge.shared.resources.request(["action":"opened", "tab":view.webviewId,
                "anchor":activeTab?.webviewId ?? 0, "activate":shouldActivate, "append":append])
        } else if shouldActivate { activate(view) }
        return view
    }

    /// Focus a visible pane, or mount a tab and leave the current arrangement.
    func activate(_ view: EngineView, focusPage: Bool = true) {
        guard tabs.contains(where: { $0 === view }) else { return }
        if BrainBridge.shared.resources.shouldCoordinate, activeTab != nil {
            _ = BrainBridge.shared.resources.request(["action":"activate", "tab":view.webviewId, "focus_page":focusPage]); return
        }
        if let layout = websiteLayout, !layout.ids.contains(view.webviewId) {
            detachWebsiteLayout()
            activeTab = nil
        }
        if activeTab !== view {
            if websiteLayout == nil {
                activeTab?.removeFromSuperview()
                view.frame = container.pageArea.bounds
                container.pageArea.addSubview(view)
            }
            activeTab = view
            container.webview = view.webviewId
            // The old first responder just left the hierarchy — hand the
            // keyboard to the page that's actually on screen.
            if focusPage { window?.makeFirstResponder(view.webView) }
            adoptChrome(from: view)
            syncModButtons()
            // Show the dock's reaction: collapsed edge surfaces slide out
            // for a beat so the active-icon bounce is visible.
            SurfaceManager.shared.pulseEdges()
            // Refresh the resurrect frame soon after the switch paints, so
            // a death right after a tab change resurrects the right tab.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak view] in
                guard let self, let view, view === self.activeTab,
                      self.resurrectOverlay == nil else { return }
                view.capturePreview()
            }
        }
        BrainBridge.shared.send([
            "op": "event", "event": "tab_activated", "webview": view.webviewId,
        ])
    }

    /// Commands act only on this window; no tab moves between profiles/windows.
    func applyWebsiteLayout(tree: [String: Any]) throws {
        let node = try WebsiteLayoutNode.parse(tree)
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.webviewId, $0) })
        guard node.ids.allSatisfy({ byID[$0] != nil }) else {
            throw layoutError("Layout leaves must reference tabs from this window")
        }
        let selected = node.ids.map { byID[$0]! }
        let focused = selected.first { $0 === activeTab } ?? selected[0]
        detachWebsiteLayout()
        activeTab?.removeFromSuperview()
        let layout = WebsiteLayout(frame: container.pageArea.bounds, node: node, views: byID)
        container.pageArea.addSubview(layout)
        websiteLayout = layout
        activeTab = nil
        activate(focused)
        paneFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.window { self.focusPane(at: event.locationInWindow) }
            }
            return event
        }
    }

    func focusPane(at point: NSPoint) {
        guard let layout = websiteLayout, let root = window?.contentView,
              let hit = root.hitTest(root.convert(point, from: nil)),
              let view = layout.views.first(where: { hit === $0 || hit.isDescendant(of: $0) }),
              activeTab !== view else { return }
        activate(view, focusPage: false)
    }

    private func detachWebsiteLayout() {
        if let paneFocusMonitor { NSEvent.removeMonitor(paneFocusMonitor) }
        paneFocusMonitor = nil
        guard let layout = websiteLayout else { return }
        for view in layout.views { view.removeFromSuperview() }
        layout.removeFromSuperview()
        websiteLayout = nil
    }

    func resetWebsiteLayout() {
        guard websiteLayout != nil, let active = activeTab else { return }
        detachWebsiteLayout()
        activeTab = nil
        activate(active)
    }

    func websiteLayoutState() -> [String: Any] {
        ["tabs": tabs.map { ["webview": $0.webviewId, "url": $0.currentURLString ?? ""] },
         "panes": websiteLayout?.ids ?? activeTab.map { [$0.webviewId] } ?? [],
         "tree": websiteLayout?.tree ?? activeTab.map { ["type": "webview", "webview": $0.webviewId] } ?? [:],
         "active": activeTab?.webviewId ?? 0]
    }

    func websiteLayoutCommand(_ message: [String: Any]) throws -> [String: Any] {
        guard SiteAppConfiguration.current == nil, message["profile"] as? String == profile.id else {
            throw layoutError("Website layouts require a browser window in the requesting profile")
        }
        switch message["action"] as? String {
        case "get": break
        case "reset": resetWebsiteLayout()
        case "set":
            guard let tree = message["tree"] as? [String: Any] else { throw layoutError("Provide a layout tree") }
            try applyWebsiteLayout(tree: tree)
        case "create_tab":
            guard let value = message["url"] as? String, let url = URL(string: value),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw layoutError("Provide an http or https website URL")
            }
            let view = openTab(opener: activeTab?.webviewId, activate: false)
            view.load(urlString: value)
            var state = websiteLayoutState()
            state["created"] = view.webviewId
            return state
        default: throw layoutError("Unknown website layout action")
        }
        return websiteLayoutState()
    }

    private func layoutError(_ message: String) -> NSError {
        NSError(domain: "Bowser.WebsiteLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Mount a background tab UNDER the active one for a short window, then
    /// unmount. Invisible to the user (the active tab fully covers it), but
    /// WebKit tracks view-in-window — not sibling occlusion — so the page
    /// gets rAF and media pipeline work. Enough for a media site to rebuild
    /// its stream after a respawn (bowser-browser-hj1); once audio plays,
    /// unmounting doesn't stop it.
    func warmTab(id: UInt64, ms: Int?) {
        guard let view = tabs.first(where: { $0.webviewId == id }),
              view !== activeTab, view.superview == nil
        else { return }
        view.frame = container.pageArea.bounds
        if let active = activeTab, active.superview === container.pageArea {
            container.pageArea.addSubview(view, positioned: .below, relativeTo: active)
        } else {
            container.pageArea.addSubview(view, positioned: .below, relativeTo: websiteLayout)
        }
        let duration = Self.warmDuration(ms)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(duration)) {
            [weak self, weak view] in
            guard let self, let view, view !== self.activeTab,
                  self.websiteLayout?.ids.contains(view.webviewId) != true else { return }
            view.removeFromSuperview()
        }
    }

    /// Warm window in ms: clamped so a bad op can't pin a hidden webview to
    /// the hierarchy forever (rendering cost) or blink it uselessly.
    static func warmDuration(_ requested: Int?) -> Int {
        min(max(requested ?? 8000, 1000), 30000)
    }

    /// ⌘⇧←/→: cycle the window's tab order, wrapping at the ends.
    func activateAdjacentTab(offset: Int) {
        if BrainBridge.shared.resources.shouldCoordinate, let active = activeTab {
            _ = BrainBridge.shared.resources.request(["action":"cycle", "tab":active.webviewId, "offset":offset]); return
        }
        guard tabs.count > 1, let active = activeTab,
              let index = tabs.firstIndex(where: { $0 === active })
        else { return }
        activate(tabs[Self.wrappedIndex(index + offset, count: tabs.count)])
    }

    static func wrappedIndex(_ index: Int, count: Int) -> Int {
        ((index % count) + count) % count
    }

    @discardableResult
    func activateTab(id: UInt64) -> Bool {
        guard let view = tabs.first(where: { $0.webviewId == id }) else { return false }
        activate(view)
        return true
    }

    /// Reorder without activating, reloading, or detaching any live page.
    @discardableResult
    func moveTab(id: UInt64, relativeTo target: UInt64, after: Bool) -> Bool {
        if BrainBridge.shared.resources.shouldCoordinate {
            guard id != target, tabs.contains(where: { $0.webviewId == id }), tabs.contains(where: { $0.webviewId == target }) else { return false }
            return BrainBridge.shared.resources.request(["action":"move", "tab":id, "target":target, "after":after])
        }
        guard id != target, let source = tabs.firstIndex(where: { $0.webviewId == id }),
              tabs.contains(where: { $0.webviewId == target }) else { return false }
        let view = tabs.remove(at: source)
        let destination = tabs.firstIndex(where: { $0.webviewId == target })!
        tabs.insert(view, at: destination + (after ? 1 : 0))
        BrainBridge.shared.send(["op": "event", "event": "tabs_reordered", "order": Self.orderedTabIDs])
        return true
    }

    /// Apply a validated controller decision without replacing any webview.
    func arrangeTabs(order: [UInt64], active: UInt64, focusPage: Bool) -> Bool {
        guard order.count == tabs.count, Set(order) == Set(tabs.map(\.webviewId)),
              let selected = tabs.first(where: { $0.webviewId == active }) else { return false }
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.webviewId, $0) })
        tabs = order.map { byID[$0]! }
        BrainBridge.shared.send(["op":"event", "event":"tabs_reordered", "order":Self.orderedTabIDs])
        // A command palette opened after a new-tab intent keeps its focus.
        activate(selected, focusPage: focusPage && !(window?.firstResponder is NSTextView && window?.firstResponder !== activeTab?.webView))
        return true
    }

    /// Close one tab. The window goes with the last one.
    func closeTab(_ view: EngineView, selecting preferred: UInt64? = nil) {
        if BrainBridge.shared.resources.shouldCoordinate {
            _ = BrainBridge.shared.resources.request(["action":"close", "tab":view.webviewId]); return
        }
        guard let index = tabs.firstIndex(where: { $0 === view }) else { return }
        let wasActive = activeTab === view
        let wasPane = websiteLayout?.ids.contains(view.webviewId) == true
        let remainingTree = wasPane ? (try? WebsiteLayoutNode.parse(websiteLayout!.tree))?.removing(view.webviewId) : nil
        if wasPane { detachWebsiteLayout() }
        tabs.remove(at: index)
        view.removeFromSuperview()
        view.tearDown()

        guard !tabs.isEmpty else {
            window?.close()
            return
        }
        if let preferred, wasActive { activeTab = tabs.first(where: { $0.webviewId == preferred }) }
        if let remainingTree {
            // The remaining IDs still belong to this window. Recompose without
            // reloading their pages, retaining dragged sizes from the snapshot.
            do { try applyWebsiteLayout(tree: remainingTree.json); return }
            catch { NSLog("Bowser: layout recomposition failed: %@", error.localizedDescription) }
        }
        if wasActive || wasPane || activeTab == nil || activeTab === view {
            let selected = activeTab.flatMap { active in tabs.first { $0 === active } } ?? tabs[min(index, tabs.count - 1)]
            activeTab = nil
            activate(selected)
        }
    }

    func closeTab(id: UInt64, selecting: UInt64? = nil) {
        guard let view = tabs.first(where: { $0.webviewId == id }) else { return }
        closeTab(view, selecting: selecting)
    }

    /// Window chrome follows the mounted tab only — background tabs are free
    /// to retitle and repaint themselves without touching what's on screen.
    private func wire(_ view: EngineView) {
        view.onTitleChange = { [weak self, weak view] title in
            guard let self, let view, self.activeTab === view else { return }
            self.applyTitle(title)
        }
        view.onURLChange = { [weak self, weak view] _ in
            guard let self, self.activeTab === view else { return }
            self.refreshToolbarFavicon()
            self.syncModButtons()
        }
        view.onFaviconChange = { [weak self, weak view] in
            guard let self, self.activeTab === view else { return }
            self.refreshToolbarFavicon()
        }
        view.onThemeColor = { [weak self, weak view] color in
            guard let self, let view, self.activeTab === view else { return }
            self.applyThemeColor(color)
        }
    }

    private func refreshProfileBadge() {
        profileBadge.stringValue = profile.label
        profileBadge.textColor = profile.color ?? .white
        profileBadge.isHidden = SiteAppConfiguration.current != nil || (profile.id == "default" && profile.icon == nil && profile.tint == nil && profile.avatar == nil)
        profilePortrait.image = profile.avatar?.image
        profilePortrait.isHidden = profileBadge.isHidden || profilePortrait.image == nil
        profilePortrait.toolTip = profile.avatar?.title
        profilePortrait.setAccessibilityLabel(profile.avatar.map { "\($0.title), \(profile.name) profile" })
    }

    /// The brain changed the profile list (edited in Settings): re-read our
    /// profile and repaint badge, title and tint without a new window.
    func profileDidChange() {
        profile = Profile.find(profile.id)
        refreshProfileBadge()
        syncModButtons()
        applyTitle(activeTab?.currentTitle ?? "")
        applyThemeColor(activeTab?.themeColor)
    }

    /// Hover changes only local toolbar appearance, never window ordering.
    /// Hide the native chrome only: never resize, reload or unmount the page.
    var captureChromeViews: [NSView] {
        [notch, profileNotch, nativeToolbar].compactMap { $0 } +
            [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }

    func setCaptureMode(_ enabled: Bool) {
        guard SiteAppConfiguration.current == nil else { return }
        let wasEnabled = isCaptureMode
        isCaptureMode = enabled
        if enabled {
            revealHide?.cancel()
            for view in captureChromeViews {
                let id = ObjectIdentifier(view)
                if captureHiddenViews[id] == nil { captureHiddenViews[id] = (view, view.isHidden) }
                // Immediate removal also removes hit targets and accessibility
                // controls; pointer activity cannot bring them back mid-capture.
                view.isHidden = true
            }
        } else {
            for entry in captureHiddenViews.values { entry.view.isHidden = entry.hidden }
            captureHiddenViews.removeAll()
            if wasEnabled {
                toolbarIntentObserver?.invalidatePresentation()
                profileIntentObserver?.invalidatePresentation()
            }
        }
    }

    func setToolbarHovered(_ shown: Bool) {
        guard !isCaptureMode else { return }
        if toolbarYielded { return }
        if !shown, notch.containsPointer { return }
        revealHide?.cancel()
        if shown { setToolbarVisible(true); reveal.lights = true; syncModButtons(animated: true) }
        else {
            let work = DispatchWorkItem { [weak self] in self?.reveal.lights = false; self?.syncModButtons(animated: true) }
            revealHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    func setToolbarIntent(visible: Bool, yielded: Bool) {
        guard !isCaptureMode else { return }
        toolbarYielded = yielded
        setToolbarVisible(visible)
    }

    func setToolbarVisible(_ visible: Bool, animated: Bool = true) {
        guard !isCaptureMode else { return }
        let visible = visible && !toolbarYielded
        toolbarIsVisible = visible
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
        let offset = visible ? ToolbarCornerGeometry.inset : -ToolbarCornerGeometry.height * min(0.75, max(0, toolbarHiddenFraction))
        guard toolbarTop?.constant != offset else { return }
        ToolbarRevealAnimation.perform(views: [notch, nativeToolbar].compactMap { $0 } + buttons,
            animated: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && window?.inLiveResize != true) {
            toolbarTop?.constant = offset
            notch.superview?.layoutSubtreeIfNeeded()
        }
    }

    func setProfileIndicatorVisible(_ visible: Bool, animated: Bool = true) {
        guard !isCaptureMode else { return }
        let offset = visible ? ToolbarCornerGeometry.inset : -ToolbarCornerGeometry.height * 0.5
        guard profileTop?.constant != offset else { return }
        ToolbarRevealAnimation.perform(views: [profileNotch],
            animated: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && window?.inLiveResize != true) {
            profileTop?.constant = offset
            profileNotch.superview?.layoutSubtreeIfNeeded()
        }
    }

    private func adoptChrome(from view: EngineView) {
        applyTitle(view.currentTitle)
        refreshToolbarFavicon()
        applyThemeColor(view.themeColor)
    }

    private func refreshToolbarFavicon() {
        let image = activeTab?.faviconPath.flatMap { NSImage(contentsOfFile: $0) }
        toolbarFavicon.image = image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "Website")
        toolbarFavicon.contentTintColor = image == nil ? .labelColor : nil
    }

    private func applyTitle(_ title: String) {
        let shown = title.isEmpty ? "Bowser" : title
        window?.title = profile.icon.map { "\($0) \(shown)" } ?? shown
        titleLabel.stringValue = title.isEmpty ? (activeTab?.currentURLString.flatMap(URL.init(string:))?.host ?? "New tab") : title
        titleLabel.toolTip = titleLabel.stringValue
    }

    private func applyThemeColor(_ pageColor: NSColor?) {
        guard let window else { return }
        // The band shows the PAGE's theme color through its scrim — the
        // profile tint lives on the ⌘K keycap only (owner's call).
        let color = ChromeSurface.theme(for: profile.id).color("background") ?? pageColor
        window.backgroundColor = color ?? .windowBackgroundColor
        if let color, let rgb = color.usingColorSpace(.sRGB) {
            let luminance =
                0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
            window.appearance = NSAppearance(named: luminance < 0.5 ? .darkAqua : .aqua)
        } else {
            window.appearance = nil
        }
    }

    // MARK: - Chrome

    private func clusterView() -> some View {
        CmdCluster(
            profileID: profile.id,
            siteMods: currentSiteMods,
            reveal: reveal,
            modWidth: max(0, (clusterWidth?.constant ?? 202) - 202),
            tint: profile.color.map { Color(nsColor: $0) },
            openBar: { [weak self] in
                guard let self else { return }
                CommandBar.shared.show(for: self)
            },
            goBack: { [weak self] in self?.activeTab?.webView.goBack() },
            goForward: { [weak self] in self?.activeTab?.webView.goForward() },
            reload: { [weak self] in self?.activeTab?.reloadPage() },
            modClick: { [weak self] id in self?.nativeToolbarAction("mod:" + id) },
            onHoverChanged: { [weak self] inside in self?.setToolbarHovered(inside) }
        )
    }

    func windowDidResize(_ notification: Notification) { syncModButtons() }

    func focusOmnibar() {
        CommandBar.shared.show(for: self)
    }

    @objc func focusOmnibarAction(_ sender: Any?) {
        focusOmnibar()
    }

    func loadURL(_ url: String) {
        activeTab?.load(urlString: url)
    }

    private var currentSiteMods: [ChromeSurface.SiteMod] {
        ChromeSurface.siteMods(for: profile.id, url: activeTab?.currentURLString)
    }
    /// Site mods are listed in a persistent toolbar dropdown.
    func syncModButtons(animated: Bool = false) {
        if isCaptureMode { setCaptureMode(true) }
        let expanded = reveal.lights
        let modCount = ChromeSurface.buttons(for: profile.id).count
        let modWidth = expanded ? min(CGFloat(modCount) * 27, min(135, max(0, (window?.frame.width ?? 800) - 520))) : 0
        let availableTitle = min(220, max(0, (window?.frame.width ?? 800) - 484 - modWidth))
        let targetWidth = expanded ? availableTitle : 0
        if notchTitleWidth?.constant != targetWidth || clusterWidth?.constant != 202 + modWidth || titleTextWidth?.constant != availableTitle {
            ToolbarRevealAnimation.perform(
                views: [notch, titleViewport, titleLabel, toolbarFavicon, nativeToolbar].compactMap { $0 },
                animated: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && window?.inLiveResize != true
            ) {
                clusterWidth?.constant = 202 + modWidth
                notchTitleWidth?.constant = targetWidth
                // A fixed text width lets the viewport reveal text without reflow.
                titleTextWidth?.constant = availableTitle
                titleLabel.alphaValue = expanded ? 1 : 0
                notch.superview?.layoutSubtreeIfNeeded()
            }
        }
        clusterHosting?.rootView = AnyView(clusterView())
        let theme = ChromeSurface.theme(for: profile.id)
        let tint = profile.color?.usingColorSpace(.sRGB)
        let payload: [String: Any] = [
            "revealed": reveal.lights, "modWidth": modWidth, "colors": theme.colors,
            "siteMods": currentSiteMods.prefix(128).map { ["id": $0.id, "title": $0.title, "on": $0.on] as [String: Any] },
            "tint": tint.map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent] } as Any? ?? NSNull(),
            "buttonStyle": theme.buttonStyle, "cornerRadius": theme.cornerRadius,
            "showNavigation": theme.showNavigation,
            "permissionsAvailable": true,
            "capturing": tabs.contains { $0.webView.cameraCaptureState != .none || $0.webView.microphoneCaptureState != .none },
            "buttons": ChromeSurface.buttons(for: profile.id).prefix(128).map { ["id": $0.id, "title": $0.title, "symbol": $0.symbol as Any? ?? NSNull()] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) { nativeToolbar?.setSnapshot(data) }
    }

    private func nativeToolbarAction(_ event: String) {
        switch event {
        case "permissions":
            let capturing = tabs.first { $0.webView.cameraCaptureState != .none || $0.webView.microphoneCaptureState != .none }
            SitePermissionsWindow.shared.open(engine: capturing ?? activeTab)
        case "command": focusOmnibar()
        case "back": activeTab?.webView.goBack()
        case "forward": activeTab?.webView.goForward()
        case "reload": activeTab?.reloadPage()
        case "hover:1": setToolbarHovered(true)
        case "hover:0": setToolbarHovered(false)
        default:
            guard event.hasPrefix("mod:") else { return }
            let id = String(event.dropFirst(4))
            if id.hasPrefix("site-mod:"),
               let mod = currentSiteMods.first(where: { $0.id == String(id.dropFirst(9)) }) {
                ChromeSurface.emit(["op": "event", "event": "surface", "surface": "mods",
                    "id": "toggle", "value": ["payload": mod.id, "on": !mod.on],
                    "webview": activeTab?.webviewId ?? 0, "profile": profile.id])
                return
            }
            guard ["mods", "global_mods"].contains(id) || ChromeSurface.buttons(for: profile.id).contains(where: { $0.id == id }) else { return }
            var message: [String: Any] = ["op": "event", "event": "chrome_click", "id": id]
            if ["mods", "global_mods"].contains(id) {
                message["webview"] = activeTab?.webviewId ?? 0
                message["profile"] = profile.id
            }
            ChromeSurface.emit(message)
        }
    }

    func syncToolbars() { container.setBars(ChromeSurface.toolbars(for: profile.id)) }

    func syncShellTheme() {
        let theme = ChromeSurface.theme(for: profile.id)
        band?.theme = theme
        container.theme = theme
        titleLabel.textColor = .white.withAlphaComponent(0.85)
        titleLabel.font = .systemFont(ofSize: theme.titleSize,
                                     weight: theme.buttonStyle == "beveled" ? .bold : .medium)
        applyThemeColor(activeTab?.themeColor)
        syncModButtons()
    }

    // Bare words search; things that look like URLs get https://.
    static func normalize(_ input: String, searchEngine: SearchEngine = .selected()) -> String {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let file = EngineView.localFileURL(input) { return file.absoluteString }
        if input.contains("://") { return input }
        if input.contains(".") && !input.contains(" ") { return "https://\(input)" }
        return searchEngine.searchURL(input)
    }

    // MARK: - NSWindowDelegate

    /// The traffic light (and performClose:) means Close Tab, just like ⌘W.
    /// Explicit Close Window and application teardown call close() directly.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard tabs.count > 1, let active = activeTab else { return true }
        closeTab(active)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        toolbarIntentObserver?.stop()
        profileIntentObserver?.stop()
        nativeToolbar?.retire()
        container.releaseLocalState()
        detachWebsiteLayout()
        ChromeSurface.unregister(self)
        Self.all.removeAll { $0 === self }
        CaptureMode.shared.refreshSharing()
        for tab in tabs { tab.tearDown() }
        tabs = []
        activeTab = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        (NSApp.delegate as? AppDelegate)?.rebuildModMenuItems()
        // Panels ride with the focused browser window (bowser-browser-fwz).
        if let window { SurfaceManager.shared.orderAllFront(parent: window) }
        // Same reveal as a tab switch: the dock slides out for a beat so the
        // switch to this window/profile shows its tabs.
        SurfaceManager.shared.pulseEdges()
        guard let id = activeTab?.webviewId else { return }
        BrainBridge.shared.send([
            "op": "event", "event": "tab_activated", "webview": id,
        ])
    }

    private func persistWindowState() {
        guard let window else { return }
        if !window.styleMask.contains(.fullScreen) {
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey(for: profile))
        }
    }

    func windowDidMove(_ notification: Notification) { persistWindowState() }
    func windowDidEndLiveResize(_ notification: Notification) { persistWindowState() }

    static func fullscreenKey(for profile: Profile) -> String { frameKey(for: profile) + ".fullscreen" }

    func restoreFullscreen() {
        let key = Self.fullscreenKey(for: profile)
        let saved = UserDefaults.standard.object(forKey: key) as? Bool
            ?? (profile.id == "default" && UserDefaults.standard.bool(forKey: "BowserWasFullscreen"))
        guard saved else { return }
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, !window.styleMask.contains(.fullScreen) else { return }
            window.toggleFullScreen(nil)
        }
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) { NativeModuleRuntime.toolbar.clearTransition(window); NativeModuleRuntime.surfaces.clearTransition(window) }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { NativeModuleRuntime.toolbar.clearTransition(window); NativeModuleRuntime.surfaces.clearTransition(window) }

    func windowDidEnterFullScreen(_ notification: Notification) {
        if isCaptureMode { setCaptureMode(true) }
        UserDefaults.standard.set(true, forKey: Self.fullscreenKey(for: profile))
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if isCaptureMode { setCaptureMode(true) }
        guard (NSApp.delegate as? AppDelegate)?.isTerminating != true else { return }
        UserDefaults.standard.set(false, forKey: Self.fullscreenKey(for: profile))
    }
}

/// Shared hover state for the notch title and additional mod actions.
final class ChromeReveal: ObservableObject {
    @Published var lights = false
}

struct CmdCluster: View {
    let profileID: String
    var siteMods: [ChromeSurface.SiteMod] = []
    private var theme: ShellTheme { ChromeSurface.theme(for: profileID) }
    @ObservedObject var reveal: ChromeReveal
    var modWidth: CGFloat = 135
    /// The window's profile tint — painted on the ⌘K keycap only (the
    /// owner's call: not the whole bar, not the command palette).
    let tint: Color?
    let openBar: () -> Void
    let goBack: () -> Void
    let goForward: () -> Void
    let reload: () -> Void
    let modClick: (String) -> Void
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button(action: openBar) {
                // Keycap-style badge: outlined, rounded face, like a
                // keyboard shortcut printed on the chrome.
                Text("⌘+K")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .kerning(0.8)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(theme.color("button_foreground").map { AnyShapeStyle(Color(nsColor: $0)) }
                        ?? (tint == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.95))))
                    .frame(width: 50, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .fill(theme.color("button_background").map { Color(nsColor: $0) }
                                  ?? tint ?? Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .strokeBorder(
                                theme.color("accent").map { Color(nsColor: $0) }
                                    ?? Color(red: 0.83, green: 0.65, blue: 0.13).opacity(0.95),
                                lineWidth: 1.2
                            )
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Command bar (⌘K)")
            Menu {
                if siteMods.isEmpty {
                    Text("No mods for this site")
                } else {
                    ForEach(siteMods) { mod in
                        Toggle(mod.title, isOn: Binding(
                            get: { mod.on },
                            set: { on in
                                if on != mod.on { modClick("site-mod:" + mod.id) }
                            }
                        ))
                    }
                }
                Divider()
                Button("Show global mods") { modClick("global_mods") }
            } label: {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Mods for this site")
            .accessibilityLabel("Mods for this site")
            // Revealed together with the window lights, same grace/fade.
            Group {
                clusterButton("chevron.left", action: goBack)
                clusterButton("chevron.right", action: goForward)
                clusterButton("arrow.clockwise", action: reload)
                    .help("Reload this tab (⌘R)")
                if reveal.lights && !ChromeSurface.buttons(for: profileID).isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 7) {
                ForEach(ChromeSurface.buttons(for: profileID), id: \.id) { button in
                    clusterButton(button.symbol ?? "puzzlepiece.extension") {
                        modClick(button.id)
                    }
                    .help(button.title)
                }
                        }
                    }.scrollIndicators(.hidden)
                        .frame(width: modWidth, height: 22)
                }
            }
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.15), value: reveal.lights)
        .frame(maxHeight: .infinity)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ToolbarWindowDragHandle())
        .onHover { onHoverChanged($0) }
    }

    private func clusterButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.color("button_foreground").map { Color(nsColor: $0) } ?? .secondary)
                .frame(width: 20,
                       height: theme.buttonStyle == "beveled" ? 22 : 20)
                .background {
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .fill(theme.color("button_background").map { Color(nsColor: $0) } ?? .clear)
                }
                .overlay {
                    if theme.buttonStyle == "beveled" {
                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .strokeBorder(LinearGradient(colors: [.white, Color(nsColor: theme.color("border") ?? .darkGray)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Translucent adaptive wash over the page top; fully click-through so the
/// page under it stays interactive. Alpha is the transparency dial.
final class BandScrimView: NSView {
    var theme: ShellTheme = .native { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }


    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() {
        layer?.backgroundColor =
            (theme.color("background") ?? NSColor.windowBackgroundColor.withAlphaComponent(0.42)).cgColor
        layer?.borderColor = theme.color("border")?.cgColor
        layer?.borderWidth = theme.color("border") == nil ? 0 : 1
    }

    // Page content is transform-shifted below the band, so nothing
    // interactive lives under it — the band can own its clicks and act
    // as the window's drag handle. Edge margins stay free for the
    // window's resize zones (grabbing them here made the shell
    // unresizable from the top).
    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let margin: CGFloat = 7
        if local.y >= bounds.height - margin
            || local.x <= margin
            || local.x >= bounds.width - margin {
            return nil // let AppKit's edge-resize zones have it
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
