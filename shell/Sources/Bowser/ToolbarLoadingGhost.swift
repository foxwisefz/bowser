import AppKit
import QuartzCore

/// Small, non-interactive loading companion in the active page's favicon slot.
final class ToolbarLoadingGhost: NSView {
    private let ghost = CAShapeLayer()
    var loading = false { didSet { isHidden = !loading; updateMotion() } }
    var isAnimating: Bool { ghost.animation(forKey: "float") != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Loading page")
        let shape = CGMutablePath()
        shape.move(to: CGPoint(x: 2, y: 2))
        shape.addLine(to: CGPoint(x: 2, y: 9))
        shape.addCurve(to: CGPoint(x: 14, y: 9), control1: CGPoint(x: 2, y: 17), control2: CGPoint(x: 14, y: 17))
        shape.addLine(to: CGPoint(x: 14, y: 2))
        for point in [CGPoint(x: 11, y: 4), CGPoint(x: 8, y: 2), CGPoint(x: 5, y: 4)] { shape.addLine(to: point) }
        shape.closeSubpath()
        shape.addEllipse(in: CGRect(x: 5, y: 8, width: 2, height: 3))
        shape.addEllipse(in: CGRect(x: 9, y: 8, width: 2, height: 3))
        ghost.path = shape
        ghost.fillRule = .evenOdd
        ghost.fillColor = NSColor.white.withAlphaComponent(0.9).cgColor
        layer?.addSublayer(ghost)
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
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    @objc private func updateMotion() {
        guard loading, window?.occlusionState.contains(.visible) == true,
              !isHiddenOrHasHiddenAncestor, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            ghost.removeAllAnimations()
            return
        }
        guard !isAnimating else { return }
        let bob = CABasicAnimation(keyPath: "transform.translation.y")
        bob.fromValue = -0.7; bob.toValue = 0.7
        bob.duration = 0.65; bob.autoreverses = true; bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ghost.add(bob, forKey: "float")
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateMotion() }
    override func viewDidHide() { super.viewDidHide(); updateMotion() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateMotion() }
}
