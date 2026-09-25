import AppKit

/// Screen-coordinate pointer prediction. A nearby slow approach works too;
/// motion parallel to the toolbar or away from it must not open the chrome.
struct ToolbarPointerIntent {
    enum Mode { case controls, reference }
    var mode: Mode = .controls
    init(mode: Mode = .controls) { self.mode = mode }
    private var closestDistance: CGFloat?
    private var approachTime: TimeInterval = -.infinity
    private var edgeSince: TimeInterval?
    private var referenceLastNear: TimeInterval = -.infinity
    private(set) var yielded = false
    private var previous: (point: NSPoint, time: TimeInterval)?
    private var lastIntent: TimeInterval = -.infinity
    private(set) var revealed = false

    mutating func update(point: NSPoint, time: TimeInterval, target: NSRect,
                         active: Bool, interacting: Bool = false) -> Bool {
        // Keep a useful baseline even with 120–1000 Hz mice; replacing it on
        // every tiny sample would prevent the velocity gate from ever firing.
        defer {
            if !active { previous = nil }
            else if previous == nil || time - previous!.time >= 0.008 { previous = (point, time) }
        }
        guard active else {
            revealed = false; yielded = false; closestDistance = nil; edgeSince = nil
            lastIntent = -.infinity; referenceLastNear = -.infinity
            if mode == .reference { revealed = true; return true }
            return false
        }
        func distance(_ point: NSPoint) -> CGFloat {
            hypot(max(target.minX - point.x, 0, point.x - target.maxX),
                  max(target.minY - point.y, 0, point.y - target.maxY))
        }
        if mode == .reference {
            var approaching = false
            if let previous {
                let dt = time - previous.time
                if dt >= 0.008, dt < 0.2 {
                    let predicted = NSPoint(x: point.x + (point.x - previous.point.x) * 0.12 / dt,
                                            y: point.y + (point.y - previous.point.y) * 0.12 / dt)
                    approaching = distance(point) < 120 && distance(predicted) < 24 && distance(point) < distance(previous.point)
                }
            }
            let near = target.insetBy(dx: -24, dy: -24).contains(point)
            let lingering = yielded && target.insetBy(dx: -48, dy: -48).contains(point)
            if near || approaching || lingering { referenceLastNear = time }
            yielded = time - referenceLastNear < 0.35
            revealed = !yielded
            return revealed
        }
        if yielded {
            // Keep the page reachable through the old toolbar footprint. Only
            // leaving the area or deliberately dwelling at the top resets it.
            let atEdge = point.y >= target.maxY - 3 && point.y <= target.maxY + 1
                && point.x >= target.minX && point.x <= target.maxX
            if atEdge { if edgeSince == nil { edgeSince = time } }
            else { edgeSince = nil }
            if interacting || edgeSince.map({ time - $0 >= 0.35 }) == true {
                yielded = false; closestDistance = nil; lastIntent = time
            } else if !target.insetBy(dx: -80, dy: -140).contains(point) {
                yielded = false; closestDistance = nil; lastIntent = -.infinity
            } else { revealed = false; return false }
        }
        let near = target.insetBy(dx: -14, dy: -22).contains(point)
        var approaching = false
        if let previous {
            let dt = time - previous.time
            if dt >= 0.008, dt < 0.2 {
                let vx = (point.x - previous.point.x) / dt
                let vy = (point.y - previous.point.y) / dt
                let distance = target.minY - point.y
                if vy > 70, distance > 0, distance < 180 {
                    let arrival = distance / vy
                    let projectedX = point.x + vx * arrival
                    approaching = arrival < 0.24 && projectedX >= target.minX - 18
                        && projectedX <= target.maxX + 18
                }
            }
        }
        let currentDistance = distance(point)
        if interacting {
            closestDistance = nil
        } else if let closestDistance, revealed, time - approachTime < 0.8,
                  currentDistance >= closestDistance + 12,
                  target.insetBy(dx: -60, dy: -100).contains(point) {
            yielded = true; revealed = false; edgeSince = nil
            return false
        } else if near || approaching {
            if closestDistance == nil || time - approachTime >= 0.8 {
                closestDistance = currentDistance
            } else {
                closestDistance = min(closestDistance!, currentDistance)
            }
            approachTime = time
        }
        if near || approaching || interacting { lastIntent = time }
        revealed = time - lastIntent < 0.55
        return revealed
    }
}

/// Observe native input without consuming it. Geometry stays anchored to the
/// revealed pill, so moving the pill never causes enter/exit feedback loops.
@MainActor final class ToolbarIntentObserver {
    private weak var window: NSWindow?
    private let target: @MainActor () -> NSRect
    private let interacting: @MainActor () -> Bool
    private let changed: @MainActor (Bool, Bool) -> Void
    private var monitor: Any?
    private var outsideMonitor: Any?
    private var activationObservers: [NSObjectProtocol] = []
    private var settle: DispatchWorkItem?
    private var intent = ToolbarPointerIntent()
    private var lastReveal: Bool?
    private var lastYield: Bool?
    private var point = NSEvent.mouseLocation
    private var menuTracking = false

    init(window: NSWindow, mode: ToolbarPointerIntent.Mode = .controls, target: @escaping @MainActor () -> NSRect,
         interacting: @escaping @MainActor () -> Bool, changed: @escaping @MainActor (Bool, Bool) -> Void) {
        intent.mode = mode
        self.window = window; self.target = target
        self.interacting = interacting; self.changed = changed
        window.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged,
            .rightMouseDown, .rightMouseDragged, .otherMouseDown, .otherMouseDragged]) { [weak self] event in
            guard let self, let window = event.window else { return event }
            self.point = window.convertPoint(toScreen: event.locationInWindow)
            self.update()
            return event
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.point = NSEvent.mouseLocation
            self?.update()
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            activationObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.point = NSEvent.mouseLocation
                    self?.update()
                }
            })
        }
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            let tracking = name == NSMenu.didBeginTrackingNotification
            activationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.menuTracking = tracking
                    self?.update()
                }
            })
        }
        update()
    }

    private func update() {
        guard let window else { return }
        settle?.cancel()
        let visible = intent.update(point: point, time: ProcessInfo.processInfo.systemUptime,
            target: target(), active: NSApp.isActive && window.isKeyWindow && window.isVisible,
            interacting: interacting() || (menuTracking || NSEvent.pressedMouseButtons != 0) && intent.revealed)
        if lastReveal != visible || lastYield != intent.yielded {
            lastReveal = visible; lastYield = intent.yielded; changed(visible, intent.yielded)
        }
        if visible || intent.yielded {
            let work = DispatchWorkItem { [weak self] in self?.update() }
            settle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.56, execute: work)
        }
    }

    /// The owner temporarily suppressed presentation (for capture). Force the
    /// next pointer sample to reconcile it even if the intent did not change.
    func invalidatePresentation() {
        lastReveal = nil; lastYield = nil
    }

    func stop() {
        settle?.cancel(); settle = nil
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }; outsideMonitor = nil
        for observer in activationObservers { NotificationCenter.default.removeObserver(observer) }
        activationObservers = []
    }
    isolated deinit { stop() }
}
