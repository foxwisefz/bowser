import AppKit
import QuartzCore

/// Indeterminate loading line beneath the top-left toolbar. Never intercepts page input.
final class ToolbarLoadingLine: NSView {
    private let sweep = CAGradientLayer()
    var loading = false { didSet { isHidden = !loading; updateMotion() } }
    var isAnimating: Bool { sweep.animation(forKey: "sweep") != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Loading page")
        layer?.masksToBounds = true
        layer?.cornerRadius = 1
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        sweep.colors = [NSColor.systemCyan.withAlphaComponent(0).cgColor,
                        NSColor.systemCyan.cgColor, NSColor.white.cgColor,
                        NSColor.systemCyan.withAlphaComponent(0).cgColor]
        sweep.locations = [0, 0.3, 0.65, 1]
        layer?.addSublayer(sweep)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateMotion),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateMotion),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sweep.removeAllAnimations()
        let width = bounds.width * 0.35
        sweep.frame = CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
        CATransaction.commit()
        updateMotion()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    @objc private func updateMotion() {
        guard loading, window?.occlusionState.contains(.visible) == true,
              !isHiddenOrHasHiddenAncestor, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            sweep.removeAllAnimations()
            return
        }
        guard !isAnimating, bounds.width > 0 else { return }
        let motion = CABasicAnimation(keyPath: "transform.translation.x")
        let distance = (bounds.width - sweep.bounds.width) / 2
        motion.fromValue = -distance; motion.toValue = distance
        motion.duration = 0.85; motion.autoreverses = true; motion.repeatCount = .infinity
        motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweep.add(motion, forKey: "sweep")
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateMotion() }
    override func viewDidHide() { super.viewDidHide(); updateMotion() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateMotion() }
}
