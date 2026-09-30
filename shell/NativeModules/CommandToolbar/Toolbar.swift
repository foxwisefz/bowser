import AppKit
import QuartzCore

// ABI 1: bounded UTF-8 JSON snapshots, generation-tagged copied UTF-8 events,
// and one retained NSView pointer. No WebKit references or Swift values cross.
public typealias ToolbarEvent = @convention(c) @Sendable (UInt64, UnsafePointer<CChar>) -> Void
struct ToolbarButton: Decodable, Identifiable { let id: String; let title: String; let symbol: String? }
struct SiteMod: Decodable, Identifiable { let id: String; let title: String; let on: Bool }
struct ToolbarSnapshot: Decodable {
    let siteMods: [SiteMod]?
    let modWidth: Double?
    let permissionsAvailable: Bool?
    let capturing: Bool?
    let revealed: Bool
    let tint: [Double]?
    let colors: [String: String]
    let buttonStyle: String
    let cornerRadius: Double
    let showNavigation: Bool
    let buttons: [ToolbarButton]
}
struct ToolbarTheme {
    var colors: [String: String] = [:]
    var buttonStyle = "flat"
    var cornerRadius: CGFloat = 6
    var showNavigation = false
    func color(_ key: String) -> NSColor? {
        guard let hex = colors[key], hex.count == 7, hex.first == "#", let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255)/255, green: CGFloat((rgb >> 8) & 255)/255, blue: CGFloat(rgb & 255)/255, alpha: 1)
    }
}
@MainActor final class ToolbarControl: NSButton {
    var invoke: (() -> Void)?
    var fill: NSColor = .clear
    var border: NSColor?
    var radius: CGFloat = 6
    var beveled = false
    init(title: String, symbol: String? = nil, action: @escaping () -> Void) {
        invoke = action
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            imagePosition = .imageOnly
        }
        target = self; self.action = #selector(clicked)
        setAccessibilityLabel(title)
        toolTip = title
    }
    required init?(coder: NSCoder) { fatalError("init(title:)") }
    @objc private func clicked() { invoke?() }
    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.6, dy: 0.6), xRadius: radius, yRadius: radius)
        fill.setFill(); outline.fill()
        if let border {
            border.setStroke(); outline.lineWidth = beveled ? 2 : 1.2; outline.stroke()
            if beveled {
                NSGraphicsContext.saveGraphicsState()
                outline.addClip()
                NSGradient(starting: .white.withAlphaComponent(0.6), ending: .clear)?.draw(in: bounds, angle: -90)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        super.draw(dirtyRect)
    }
}

/// Fixed-height AppKit controls avoid SwiftUI graph construction and size probes
/// during the synchronous live-adoption transaction.
@MainActor final class ToolbarView: NSView {
    private let emit: (String) -> Void
    private var appliedSnapshot: Data?
    private var pendingSnapshot: ToolbarSnapshot?
    private var controls: [NSView] = []
    private let drag = ToolbarWindowDragView()
    private var tracking: NSTrackingArea?
    private var modsMenu = NSMenu()
    private var widths: [CGFloat] = []

    init(generation: UInt64, event: @escaping ToolbarEvent) {
        emit = { text in text.withCString { event(generation, $0) } }
        super.init(frame: .zero)
        addSubview(drag)
    }
    required init?(coder: NSCoder) { fatalError("init(generation:)") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { emit("hover:1") }
    override func mouseExited(with event: NSEvent) { emit("hover:0") }
    override func layout() {
        if let snapshot = pendingSnapshot {
            pendingSnapshot = nil
            render(snapshot)
        }
        super.layout()
        drag.frame = bounds
        var x: CGFloat = 0
        for (control, width) in zip(controls, widths) {
            control.frame = NSRect(x: x, y: (bounds.height - 22) / 2, width: width, height: 22)
            x += width + 7
        }
    }
    @objc private func selectMod(_ item: NSMenuItem) {
        if let action = item.representedObject as? String { emit(action) }
    }
    private func append(_ control: NSView, width: CGFloat) {
        controls.append(control); widths.append(width); addSubview(control)
    }
    func apply(_ data: Data) -> Bool {
        if appliedSnapshot == data { return true }
        guard let value = try? JSONDecoder().decode(ToolbarSnapshot.self, from: data),
              value.buttons.count <= 128, (value.siteMods?.count ?? 0) <= 128,
              value.cornerRadius.isFinite, (0...12).contains(value.cornerRadius) else { return false }
        appliedSnapshot = data
        pendingSnapshot = value
        needsLayout = true
        return true
    }
    private func render(_ value: ToolbarSnapshot) {
        let theme = ToolbarTheme(colors: value.colors, buttonStyle: value.buttonStyle,
                                 cornerRadius: value.cornerRadius, showNavigation: value.showNavigation)
        var tint: NSColor?
        if let c = value.tint, c.count == 4, c.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
            tint = NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
        }
        for control in controls { control.removeFromSuperview() }
        controls.removeAll(); widths.removeAll()
        func button(_ title: String, _ symbol: String?, _ action: String, shortcut: String? = nil) -> ToolbarControl {
            let control = ToolbarControl(title: title, symbol: symbol) { [weak self] in
                if let shortcut { ShortcutGhost.show(shortcut) }
                self?.emit(action)
            }
            control.setAccessibilityIdentifier(action)
            control.contentTintColor = theme.color("button_foreground") ?? .secondaryLabelColor
            control.fill = theme.color("button_background") ?? .clear
            control.radius = theme.cornerRadius
            control.beveled = theme.buttonStyle == "beveled"
            if control.beveled { control.border = theme.color("border") ?? .darkGray }
            return control
        }
        let command = button("Command bar (⌘K)", nil, "command", shortcut: "⌘K")
        let descriptor = NSFont.systemFont(ofSize: 10.5, weight: .bold).fontDescriptor.withDesign(.rounded)
        command.attributedTitle = NSAttributedString(string: "⌘+K", attributes: [
            .font: descriptor.flatMap { NSFont(descriptor: $0, size: 10.5) } ?? NSFont.boldSystemFont(ofSize: 10.5),
            .kern: 0.8,
            .foregroundColor: theme.color("button_foreground") ?? (tint == nil ? NSColor.secondaryLabelColor : NSColor.white.withAlphaComponent(0.95))
        ])
        command.fill = theme.color("button_background") ?? tint ?? .controlBackgroundColor
        command.border = theme.color("accent") ?? NSColor(srgbRed: 0.83, green: 0.65, blue: 0.13, alpha: 0.95)
        command.beveled = false
        append(command, width: 50)
        let menuButton = button("Mods for this site", "puzzlepiece.extension", "site-mods")
        modsMenu = NSMenu(); modsMenu.autoenablesItems = false
        if (value.siteMods ?? []).isEmpty {
            let empty = NSMenuItem(title: "No mods for this site", action: nil, keyEquivalent: "")
            empty.isEnabled = false; modsMenu.addItem(empty)
        }
        for mod in value.siteMods ?? [] {
            let item = NSMenuItem(title: mod.title, action: #selector(selectMod), keyEquivalent: "")
            item.target = self; item.representedObject = "mod:site-mod:" + mod.id
            item.state = mod.on ? .on : .off; modsMenu.addItem(item)
        }
        modsMenu.addItem(.separator())
        let global = NSMenuItem(title: "Show global mods", action: #selector(selectMod), keyEquivalent: "")
        global.target = self; global.representedObject = "mod:global_mods"; modsMenu.addItem(global)
        menuButton.menu = modsMenu
        menuButton.invoke = { [weak self, weak menuButton] in
            guard let self, let menuButton else { return }
            self.modsMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: menuButton.bounds.minY), in: menuButton)
        }
        append(menuButton, width: 20)
        append(button("Back (⌘[)", "chevron.left", "back", shortcut: "⌘["), width: 20)
        append(button("Forward (⌘])", "chevron.right", "forward", shortcut: "⌘]"), width: 20)
        append(button("Reload this tab (⌘R)", "arrow.clockwise", "reload", shortcut: "⌘R"), width: 20)
        if value.revealed && !value.buttons.isEmpty {
            let scroll = NSScrollView()
            scroll.drawsBackground = false; scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
            let document = NSView(frame: NSRect(x: 0, y: 0, width: CGFloat(value.buttons.count) * 27 - 7, height: 22))
            for (index, mod) in value.buttons.enumerated() {
                let control = button(mod.title, mod.symbol ?? "puzzlepiece.extension", "mod:" + mod.id)
                control.frame = NSRect(x: CGFloat(index) * 27, y: 0, width: 20, height: 22)
                document.addSubview(control)
            }
            scroll.documentView = document
            let available = value.modWidth.flatMap { $0.isFinite ? $0 : nil } ?? 135
            append(scroll, width: min(CGFloat(value.buttons.count) * 27, min(135, max(0, available))))
        }
        if value.permissionsAvailable == true && value.capturing == true {
            let control = button("Website permissions", "record.circle.fill", "permissions")
            control.contentTintColor = .systemGreen
            control.toolTip = "Camera or microphone in use — website permissions"
            append(control, width: 24)
        }
    }
}
@_cdecl("bowser_toolbar_abi") public func toolbarABI() -> Int32 { 1 }
@_cdecl("bowser_toolbar_create") public func toolbarCreate(_ bytes: UnsafePointer<UInt8>, _ count: Int32, _ generation: UInt64, _ event: @escaping ToolbarEvent) -> UnsafeMutableRawPointer? {
    guard count > 0 && count <= 65536 else { return nil }
    let data = Data(bytes: bytes, count: Int(count))
    let address: UInt? = MainActor.assumeIsolated {
        let view = ToolbarView(generation: generation, event: event)
        guard view.apply(data) else { return nil }
        return UInt(bitPattern: Unmanaged.passRetained(view).toOpaque())
    }
    return address.flatMap(UnsafeMutableRawPointer.init(bitPattern:))
}
@_cdecl("bowser_toolbar_update") public func toolbarUpdate(_ pointer: UnsafeMutableRawPointer, _ bytes: UnsafePointer<UInt8>, _ count: Int32) -> Int32 {
    guard count > 0 && count <= 65536 else { return 0 }
    let address = UInt(bitPattern: pointer), data = Data(bytes: bytes, count: Int(count))
    return MainActor.assumeIsolated { Unmanaged<ToolbarView>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue().apply(data) ? 1 : 0 }
}
@_cdecl("bowser_toolbar_destroy") public func toolbarDestroy(_ pointer: UnsafeMutableRawPointer) {
    let address = UInt(bitPattern: pointer)
    MainActor.assumeIsolated {
        let object = Unmanaged<ToolbarView>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!)
        object.takeUnretainedValue().removeFromSuperview(); object.release()
    }
}

/// A click-only reminder in its own non-interactive panel: toolbar clipping,
/// page navigation and revealing/hiding the controls cannot cut the ghost off.
@MainActor
private enum ShortcutGhost {
    private static weak var current: NSPanel?

    static func show(_ shortcut: String) {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseUp || event.type == .leftMouseDown,
              let owner = event.window else { return }
        if let current {
            current.parent?.removeChildWindow(current)
            current.close()
        }
        let point = owner.convertPoint(toScreen: event.locationInWindow)
        let size = NSSize(width: 66, height: 72)
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height - 6)
        if let screen = owner.screen {
            origin.x = min(max(origin.x, screen.visibleFrame.minX), screen.visibleFrame.maxX - size.width)
            origin.y = max(origin.y, screen.visibleFrame.minY)
        }
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
        panel.appearance = owner.effectiveAppearance
        let canvas = NSView(frame: NSRect(origin: .zero, size: size))
        canvas.wantsLayer = true
        canvas.setAccessibilityElement(false)
        let badge = NSTextField(labelWithString: shortcut)
        badge.alignment = .center
        badge.font = .monospacedSystemFont(ofSize: 17, weight: .medium)
        badge.textColor = .labelColor
        badge.frame = NSRect(x: 4, y: 42, width: 58, height: 26)
        badge.wantsLayer = true
        badge.drawsBackground = false
        badge.isBordered = false
        // Only the glyphs cast the halo; no badge fill, border or shadow box.
        let dark = owner.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        badge.textColor = dark
            ? NSColor(calibratedRed: 0.9, green: 0.97, blue: 1, alpha: 1)
            : NSColor(calibratedRed: 0.14, green: 0.3, blue: 0.58, alpha: 1)
        badge.layer?.masksToBounds = false
        badge.layer?.shadowColor = NSColor(calibratedRed: 0.35, green: 0.7, blue: 1, alpha: 1).cgColor
        badge.layer?.shadowOffset = .zero
        badge.layer?.shadowRadius = 7
        badge.layer?.shadowOpacity = 0.95
        badge.setAccessibilityElement(false)
        canvas.addSubview(badge)
        panel.contentView = canvas
        current = panel
        owner.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)

        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.12, 0.55, 1]
        fade.duration = 1.15
        badge.layer?.opacity = 0
        badge.layer?.add(fade, forKey: "shortcut-fade")
        if !reduced {
            let drift = CABasicAnimation(keyPath: "transform.translation.y")
            drift.fromValue = 0
            drift.toValue = -30
            drift.duration = 1.15
            drift.timingFunction = CAMediaTimingFunction(name: .easeOut)
            badge.layer?.add(drift, forKey: "shortcut-drift")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            panel.parent?.removeChildWindow(panel)
            panel.close()
        }
    }
}
