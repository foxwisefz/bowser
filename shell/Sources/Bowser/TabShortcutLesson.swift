import AppKit

/// Ghost shortcut hints shown on every applicable mouse-driven tab switch.
@MainActor enum TabShortcutLesson {
    enum Action: String {
        case previous, next, last
        var label: String {
            switch self {
            case .previous: return "⌘⇧["
            case .next: return "⌘⇧]"
            case .last: return "Control + Tab"
            }
        }
    }
    static let hintSize = NSSize(width: 208, height: 68)
    static func makeContent(_ action: Action, appearance: NSAppearance) -> NSView {
        let canvas = NSView(frame: NSRect(origin: .zero, size: hintSize))
        canvas.appearance = appearance
        canvas.wantsLayer = true
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        canvas.layer?.backgroundColor = (dark ? NSColor(calibratedWhite: 0.10, alpha: 0.97)
            : NSColor(calibratedWhite: 0.98, alpha: 0.97)).cgColor
        canvas.layer?.cornerRadius = 12
        canvas.layer?.borderWidth = 1
        canvas.layer?.borderColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.25).cgColor
        canvas.setAccessibilityElement(false)
        let glyph = NSTextField(labelWithString: action.label)
        glyph.font = .monospacedSystemFont(ofSize: 20, weight: .semibold)
        glyph.textColor = dark ? .white : .black
        glyph.alignment = .center
        glyph.frame = NSRect(x: 12, y: 10, width: 184, height: 27)
        glyph.setAccessibilityElement(false)
        canvas.addSubview(glyph)
        let title: String
        switch action {
        case .last: title = "Last active tab"
        case .next: title = "Next tab"
        case .previous: title = "Previous tab"
        }
        let caption = NSTextField(labelWithString: title)
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = dark ? NSColor(calibratedWhite: 0.85, alpha: 1) : NSColor(calibratedWhite: 0.25, alpha: 1)
        caption.alignment = .center
        caption.frame = NSRect(x: 12, y: 40, width: 184, height: 17)
        caption.setAccessibilityElement(false)
        canvas.addSubview(caption)
        return canvas
    }
    static func lesson(order: [UInt64], from: UInt64, to: UInt64, last: UInt64?) -> Action? {
        guard from != to, order.count > 1,
              let source = order.firstIndex(of: from), let target = order.firstIndex(of: to) else { return nil }
        if to == last { return .last }
        if target == (source + 1) % order.count { return .next }
        if target == (source + order.count - 1) % order.count { return .previous }
        return nil
    }
    private static weak var current: NSPanel?
    static func show(_ action: Action, in owner: NSWindow, from point: NSPoint) {
        guard owner.isVisible else { return }
        if let current { current.parent?.removeChildWindow(current); current.close() }
        // Keep the lesson beside the clicked tab, clear of the pointer and dock.
        let size = hintSize
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? owner.screen
        let visible = screen?.visibleFrame ?? owner.frame
        let right = point.x + 36
        let x = right + size.width <= visible.maxX ? right : point.x - 36 - size.width
        let rect = NSRect(x: min(max(x, visible.minX + 8), visible.maxX - size.width - 8),
                          y: min(max(point.y - size.height / 2, visible.minY + 8), visible.maxY - size.height - 8),
                          width: size.width, height: size.height)
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
        panel.appearance = owner.effectiveAppearance
        let canvas = makeContent(action, appearance: owner.effectiveAppearance)
        panel.contentView = canvas
        current = panel
        owner.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.04, 0.85, 1]
        fade.duration = 2.4
        canvas.layer?.opacity = 0
        canvas.layer?.add(fade, forKey: "shortcut-fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.45) {
            panel.parent?.removeChildWindow(panel)
            panel.close()
        }
    }
}
