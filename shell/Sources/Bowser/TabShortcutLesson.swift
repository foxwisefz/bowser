import AppKit

/// Ghost shortcut hints shown on every applicable mouse-driven tab switch.
@MainActor enum TabShortcutLesson {
    enum Action: String {
        case previous, next, last
        var label: String {
            switch self {
            case .previous: return "⌘⇧["
            case .next: return "⌘⇧]"
            case .last: return "⌃⇥"
            }
        }
    }
    static let hintSize = NSSize(width: 128, height: 64)
    static func makeContent(_ action: Action, appearance: NSAppearance) -> NSView {
        let canvas = NSView(frame: NSRect(origin: .zero, size: hintSize))
        canvas.appearance = appearance
        canvas.wantsLayer = true
        canvas.setAccessibilityElement(false)
        let glyph = NSTextField(labelWithString: action.label)
        glyph.frame = NSRect(x: 12, y: 18, width: 104, height: 28)
        glyph.wantsLayer = true
        ShortcutHintStyle.apply(to: glyph, appearance: appearance, size: 20)
        glyph.layer?.shadowRadius = 4
        glyph.layer?.shadowOpacity = 0.5
        glyph.setAccessibilityElement(false)
        canvas.addSubview(glyph)
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
        let right = point.x + 12
        let x = right + size.width <= visible.maxX ? right : point.x - 12 - size.width
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
        fade.keyTimes = [0, 0.05, 0.75, 1]
        fade.duration = 1.8
        canvas.layer?.opacity = 0
        canvas.layer?.add(fade, forKey: "shortcut-fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.85) {
            panel.parent?.removeChildWindow(panel)
            panel.close()
        }
    }
}
