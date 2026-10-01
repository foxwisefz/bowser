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
        // Emerge from the clicked tab and drift inward, using the toolbar ghost's
        // glyphs, halo, fade curve and duration.
        let dx = owner.frame.midX - point.x, dy = owner.frame.midY - point.y
        let length = max(1, hypot(dx, dy))
        let direction = NSPoint(x: dx / length, y: dy / length)
        let center = NSPoint(x: point.x + direction.x * 42, y: point.y + direction.y * 42)
        let size = NSSize(width: 160, height: 110)
        let rect = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
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
        let canvas = NSView(frame: NSRect(origin: .zero, size: size))
        canvas.wantsLayer = true
        canvas.setAccessibilityElement(false)
        let glyph = NSTextField(labelWithString: action.label)
        glyph.font = .monospacedSystemFont(ofSize: 17, weight: .medium)
        glyph.alignment = .center
        glyph.frame = NSRect(x: 32, y: 42, width: 96, height: 26)
        glyph.wantsLayer = true
        glyph.drawsBackground = false
        glyph.isBordered = false
        let dark = owner.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        glyph.textColor = dark
            ? NSColor(calibratedRed: 0.9, green: 0.97, blue: 1, alpha: 1)
            : NSColor(calibratedRed: 0.14, green: 0.3, blue: 0.58, alpha: 1)
        glyph.layer?.masksToBounds = false
        glyph.layer?.shadowColor = NSColor(calibratedRed: 0.35, green: 0.7, blue: 1, alpha: 1).cgColor
        glyph.layer?.shadowOffset = .zero
        glyph.layer?.shadowRadius = 7
        glyph.layer?.shadowOpacity = 0.95
        glyph.setAccessibilityElement(false)
        canvas.addSubview(glyph)
        panel.contentView = canvas
        current = panel
        owner.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.12, 0.55, 1]
        fade.duration = 1.15
        glyph.layer?.opacity = 0
        glyph.layer?.add(fade, forKey: "shortcut-fade")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for (axis, value) in [("x", direction.x), ("y", direction.y)] {
                let drift = CABasicAnimation(keyPath: "transform.translation." + axis)
                drift.fromValue = 0
                drift.toValue = value * 30
                drift.duration = 1.15
                drift.timingFunction = CAMediaTimingFunction(name: .easeOut)
                glyph.layer?.add(drift, forKey: "shortcut-drift-" + axis)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            panel.parent?.removeChildWindow(panel)
            panel.close()
        }
    }
}
