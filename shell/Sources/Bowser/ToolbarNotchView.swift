import AppKit

/// The compact native toolbar window measures about 20pt at its outer corner.
/// Equal 8pt insets and a 12pt continuous inner radius keep the curves concentric.
enum ToolbarCornerGeometry {
    static let outerRadius: CGFloat = 20
    static let inset: CGFloat = 8
    static let radius = outerRadius - inset
    static let height: CGFloat = 32
}

/// Tracks the whole notch, including the native window controls and title.
final class ToolbarNotchView: NSView {
    var acceptsPointer = true
    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsPointer ? super.hitTest(point) : nil
    }
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    var containsPointer: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        // Core Animation supplies Apple's continuous curve, not a circular arc.
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = min(ToolbarCornerGeometry.radius, min(bounds.width, bounds.height) / 2)
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// Update real geometry immediately; animate only its presentation. Resizing
/// cancels the presentation, and interrupted hovers start from the visible frame.
@MainActor enum ToolbarRevealAnimation {
    static func perform(views: [NSView], animated: Bool, changes: () -> Void) {
        let layers = views.compactMap(\.layer)
        let starts = layers.map { layer in
            let visible = layer.presentation() ?? layer
            return (visible.bounds, visible.position, visible.opacity)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers {
            for key in ["bounds", "position", "opacity"] {
                layer.removeAnimation(forKey: "toolbarReveal." + key)
            }
        }
        changes()
        if animated {
            for (layer, start) in zip(layers, starts) {
                let values: [(String, Any, Any)] = [
                    ("bounds", NSValue(rect: start.0), NSValue(rect: layer.bounds)),
                    ("position", NSValue(point: start.1), NSValue(point: layer.position)),
                    ("opacity", start.2, layer.opacity),
                ]
                for (key, from, to) in values {
                    let animation = CABasicAnimation(keyPath: key)
                    animation.fromValue = from
                    animation.toValue = to
                    animation.duration = 0.28
                    animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                    layer.add(animation, forKey: "toolbarReveal." + key)
                }
            }
        }
        CATransaction.commit()
    }
}
