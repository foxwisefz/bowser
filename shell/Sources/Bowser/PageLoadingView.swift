import AppKit
import QuartzCore

/// A composited native canvas while WebKit has no page pixels. Never delays first paint.
final class PageLoadingView: NSView {
    private let visual = CALayer()
    private let aura = CAGradientLayer()
    private let core = CAGradientLayer()
    private var ribbons: [CAGradientLayer] = []
    var loading = false { didSet { updateMotion() } }
    var isAnimating: Bool { ribbons.first?.animation(forKey: "orbit") != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Loading page")
        visual.bounds = CGRect(x: 0, y: 0, width: 160, height: 160)
        layer?.addSublayer(visual)

        aura.type = .radial
        aura.frame = visual.bounds
        aura.startPoint = CGPoint(x: 0.5, y: 0.5)
        aura.endPoint = CGPoint(x: 1, y: 1)
        aura.locations = [0, 0.3, 1]
        visual.addSublayer(aura)

        for index in 0..<3 {
            let ribbon = CAGradientLayer()
            ribbon.type = .conic
            ribbon.frame = CGRect(x: 43, y: 43, width: 74, height: 74)
            ribbon.startPoint = CGPoint(x: 0.5, y: 0.5)
            ribbon.endPoint = CGPoint(x: 1, y: 0.5)
            ribbon.locations = [0, 0.3, 0.65, 1]
            let mask = CAShapeLayer()
            mask.frame = ribbon.bounds
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 37, y: 5))
            path.addCurve(to: CGPoint(x: 69, y: 39), control1: CGPoint(x: 59, y: 0), control2: CGPoint(x: 75, y: 20))
            path.addCurve(to: CGPoint(x: 30, y: 66), control1: CGPoint(x: 62, y: 58), control2: CGPoint(x: 48, y: 73))
            path.addCurve(to: CGPoint(x: 37, y: 5), control1: CGPoint(x: 2, y: 59), control2: CGPoint(x: 4, y: 13))
            path.closeSubpath()
            mask.path = path
            mask.fillColor = NSColor.clear.cgColor
            mask.strokeColor = NSColor.white.cgColor
            mask.lineWidth = index == 0 ? 3 : 1.5
            ribbon.mask = mask
            ribbon.transform = CATransform3DMakeRotation(CGFloat(index) * 2.1, 0, 0, 1)
            ribbon.opacity = index == 0 ? 1 : 0.65
            visual.addSublayer(ribbon)
            ribbons.append(ribbon)
        }

        core.type = .radial
        core.frame = CGRect(x: 58, y: 58, width: 44, height: 44)
        core.cornerRadius = 22
        core.startPoint = CGPoint(x: 0.32, y: 0.28)
        core.endPoint = CGPoint(x: 1, y: 1)
        core.locations = [0, 0.38, 0.8, 1]
        visual.addSublayer(core)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateMotion),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateMotion),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        updateMotion()
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
        visual.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let violet = NSColor(srgbRed: 0.48, green: 0.32, blue: 1, alpha: 1)
        let cyan = NSColor(srgbRed: 0.08, green: 0.76, blue: 0.95, alpha: 1)
        let pink = NSColor(srgbRed: 0.95, green: 0.35, blue: 0.72, alpha: 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        aura.colors = [violet.withAlphaComponent(dark ? 0.22 : 0.12).cgColor,
                       cyan.withAlphaComponent(dark ? 0.07 : 0.04).cgColor, violet.withAlphaComponent(0).cgColor]
        core.colors = [NSColor.white.withAlphaComponent(0.95).cgColor, cyan.cgColor, violet.cgColor, pink.cgColor]
        ribbons.forEach { $0.colors = [cyan.cgColor, violet.cgColor, pink.cgColor, cyan.cgColor] }
        CATransaction.commit()
    }

    @objc private func updateMotion() {
        visual.isHidden = !loading
        let animate = loading && window != nil && window?.occlusionState.contains(.visible) == true &&
            !isHiddenOrHasHiddenAncestor && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animate else {
            ribbons.forEach { $0.removeAllAnimations() }
            aura.removeAllAnimations()
            return
        }
        guard !isAnimating else { return }
        for (index, ribbon) in ribbons.enumerated() {
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = Double(index) * 2.1
            rotation.toValue = Double(index) * 2.1 + (index == 1 ? -2 : 2) * Double.pi
            rotation.duration = [2.4, 3.8, 5.2][index]
            rotation.repeatCount = .infinity
            ribbon.add(rotation, forKey: "orbit")
        }
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 0.55
        breath.toValue = 1
        breath.duration = 1.6
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        aura.add(breath, forKey: "breath")
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateMotion() }
    override func viewDidHide() { super.viewDidHide(); updateMotion() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateMotion() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
