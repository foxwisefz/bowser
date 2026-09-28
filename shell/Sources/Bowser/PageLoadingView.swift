import AppKit
import QuartzCore

/// A flowing native canvas while WebKit has no page pixels. Never delays first paint.
final class PageLoadingView: NSView {
    private let visual = CALayer()
    private var clouds: [CAGradientLayer] = []
    private var ribbons: [CAGradientLayer] = []
    private var masks: [CAShapeLayer] = []
    var loading = false { didSet { updateMotion() } }
    var isAnimating: Bool { masks.first?.animation(forKey: "flow") != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Loading page")
        layer?.addSublayer(visual)
        for _ in 0..<3 {
            let cloud = CAGradientLayer()
            cloud.type = .radial
            cloud.startPoint = CGPoint(x: 0.5, y: 0.5)
            cloud.endPoint = CGPoint(x: 1, y: 1)
            cloud.locations = [0, 0.35, 1]
            visual.addSublayer(cloud)
            clouds.append(cloud)
            let ribbon = CAGradientLayer()
            ribbon.startPoint = CGPoint(x: 0, y: 0.2)
            ribbon.endPoint = CGPoint(x: 1, y: 0.8)
            ribbon.locations = [0, 0.25, 0.55, 0.8, 1]
            let mask = CAShapeLayer()
            ribbon.mask = mask
            visual.addSublayer(ribbon)
            ribbons.append(ribbon)
            masks.append(mask)
        }
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

    private func wave(_ index: Int, alternate: Bool) -> CGPath {
        let w = bounds.width, h = bounds.height
        let baseline = CGFloat(index) * 0.085 + 0.28
        let lift: CGFloat = alternate ? 0.24 : -0.12
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -w * 0.15, y: h * baseline))
        path.addCurve(to: CGPoint(x: w * 1.15, y: h * (baseline + 0.2)),
                      control1: CGPoint(x: w * 0.3, y: h * (baseline + 0.55 + lift)),
                      control2: CGPoint(x: w * 0.58, y: h * (baseline - 0.32 - lift)))
        path.addCurve(to: CGPoint(x: -w * 0.15, y: h * (baseline - 0.05)),
                      control1: CGPoint(x: w * 0.62, y: h * (baseline - 0.04 - lift)),
                      control2: CGPoint(x: w * 0.28, y: h * (baseline + 0.12 + lift)))
        path.closeSubpath()
        return path
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let resized = visual.bounds.size != bounds.size
        visual.frame = bounds
        for index in 0..<3 {
            clouds[index].frame = CGRect(x: bounds.width * (CGFloat(index) * 0.38 - 0.35),
                                         y: bounds.height * (index == 1 ? -0.2 : 0.05),
                                         width: bounds.width * 0.95, height: bounds.height * 0.95)
            ribbons[index].frame = visual.bounds
            masks[index].frame = visual.bounds
            masks[index].path = wave(index, alternate: false)
            if resized { masks[index].removeAllAnimations(); clouds[index].removeAllAnimations() }
        }
        CATransaction.commit()
        updateMotion()
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let violet = NSColor(srgbRed: 0.43, green: 0.26, blue: 0.96, alpha: 1)
        let cyan = NSColor(srgbRed: 0.02, green: 0.8, blue: 0.86, alpha: 1)
        let pink = NSColor(srgbRed: 0.95, green: 0.26, blue: 0.58, alpha: 1)
        let colors = [cyan, violet, pink]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = (dark
            ? NSColor(srgbRed: 0.035, green: 0.045, blue: 0.09, alpha: 1)
            : NSColor(srgbRed: 0.965, green: 0.97, blue: 0.99, alpha: 1)).cgColor
        for index in 0..<3 {
            let color = colors[index]
            clouds[index].colors = [color.withAlphaComponent(dark ? 0.32 : 0.18).cgColor,
                                     color.withAlphaComponent(dark ? 0.12 : 0.07).cgColor,
                                     color.withAlphaComponent(0).cgColor]
            ribbons[index].colors = [color.withAlphaComponent(0).cgColor,
                color.withAlphaComponent(dark ? 0.45 : 0.22).cgColor,
                colors[(index + 1) % 3].withAlphaComponent(dark ? 0.68 : 0.34).cgColor,
                colors[(index + 2) % 3].withAlphaComponent(dark ? 0.35 : 0.18).cgColor,
                color.withAlphaComponent(0).cgColor]
        }
        CATransaction.commit()
    }

    @objc private func updateMotion() {
        visual.isHidden = !loading
        let animate = loading && window?.occlusionState.contains(.visible) == true &&
            !isHiddenOrHasHiddenAncestor && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animate else {
            masks.forEach { $0.removeAllAnimations() }
            clouds.forEach { $0.removeAllAnimations() }
            return
        }
        guard !isAnimating, bounds.width > 0, bounds.height > 0 else { return }
        for index in 0..<3 {
            let flow = CABasicAnimation(keyPath: "path")
            flow.fromValue = wave(index, alternate: false)
            flow.toValue = wave(index, alternate: true)
            flow.duration = [2.6, 3.3, 4.1][index]
            flow.autoreverses = true
            flow.repeatCount = .infinity
            flow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            masks[index].add(flow, forKey: "flow")
            let drift = CABasicAnimation(keyPath: "transform.translation.x")
            drift.fromValue = -bounds.width * 0.08
            drift.toValue = bounds.width * 0.08
            drift.duration = [3.1, 4.2, 3.7][index]
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clouds[index].add(drift, forKey: "drift")
        }
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateMotion() }
    override func viewDidHide() { super.viewDidHide(); updateMotion() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateMotion() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
