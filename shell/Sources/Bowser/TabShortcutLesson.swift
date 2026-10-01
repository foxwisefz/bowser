import AppKit

/// Small, persistent lessons: three spaced reminders, retired after shortcut use.
@MainActor enum TabShortcutLesson {
    enum Action: String {
        case previous, next, last
        var label: String {
            switch self {
            case .previous: return "Previous tab   ⌘⇧["
            case .next: return "Next tab   ⌘⇧]"
            case .last: return "Last focused tab   ⌃Tab"
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
    static func learned(_ action: Action, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: "tabLesson.\(action.rawValue).learned")
    }
    static func shouldShow(_ action: Action, now: TimeInterval = Date.timeIntervalSinceReferenceDate,
                           defaults: UserDefaults = .standard) -> Bool {
        let key = "tabLesson.\(action.rawValue)"
        guard !defaults.bool(forKey: key + ".learned"), defaults.integer(forKey: key + ".count") < 3,
              now - defaults.double(forKey: "tabLesson.lastShown") >= 60 else { return false }
        defaults.set(defaults.integer(forKey: key + ".count") + 1, forKey: key + ".count")
        defaults.set(now, forKey: "tabLesson.lastShown")
        return true
    }
    private static weak var current: NSPanel?
    static func show(_ action: Action, in owner: NSWindow) {
        guard owner.isVisible, shouldShow(action) else { return }
        if let current { current.parent?.removeChildWindow(current); current.close() }
        let rect = NSRect(x: owner.frame.midX - 150, y: owner.frame.midY - 24, width: 300, height: 48)
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
        panel.appearance = owner.effectiveAppearance
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: rect.size))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        let label = NSTextField(labelWithString: action.label)
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.alignment = .center
        label.frame = NSRect(x: 8, y: 14, width: 284, height: 22)
        effect.addSubview(label)
        panel.contentView = effect
        current = panel
        owner.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        // Static placement also respects Reduce Motion, without moving the page or focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            panel.parent?.removeChildWindow(panel)
            panel.close()
        }
    }
}
