import AppKit
import SwiftUI

/// Tracks the whole toolbar before controls commit to a click or open a menu.
struct ToolbarWindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolbarWindowDragView { ToolbarWindowDragView() }
    func updateNSView(_ view: ToolbarWindowDragView, context: Context) {}
}

final class ToolbarWindowDragView: NSView {
    static let regionIdentifier = NSUserInterfaceItemIdentifier("bowser.toolbar.controls")
    private var monitor: Any?
    private var down: NSEvent?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        down = nil
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handle(event) == nil
            }
            return consumed ? nil : event
        }
    }

    // The event monitor owns dragging; a plain click on empty space does nothing.
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}

    private func ownsHit(at point: NSPoint) -> Bool {
        // SwiftUI's background view can outgrow its native host. Its bounds
        // alone are not authority to intercept clicks elsewhere in the window.
        var ancestor: NSView? = self
        while let view = ancestor, view.identifier != Self.regionIdentifier { ancestor = view.superview }
        guard let region = ancestor, !region.isHiddenOrHasHiddenAncestor,
              region.visibleRect.contains(region.convert(point, from: nil)) else { return false }
        var root = region
        while true {
            guard root.alphaValue > 0.01 else { return false }
            guard let parent = root.superview else { break }
            root = parent
        }
        guard let hit = root.hitTest(root.convert(point, from: nil)) else { return false }
        return hit === region || hit.isDescendant(of: region)
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { down = nil; return event }
        switch event.type {
        case .leftMouseDown:
            down = nil
            guard !isHiddenOrHasHiddenAncestor, ownsHit(at: event.locationInWindow) else { return event }
            // This monitor consumes the down before NSWindow can activate itself.
            window.makeKeyAndOrderFront(nil)
            down = event
            return nil
        case .leftMouseDragged:
            guard let start = down else { return event }
            if hypot(event.locationInWindow.x - start.locationInWindow.x,
                     event.locationInWindow.y - start.locationInWindow.y) >= 5 {
                down = nil
                window.makeKeyAndOrderFront(nil)
                window.performDrag(with: start)
            }
            return nil
        case .leftMouseUp:
            guard let start = down else { return event }
            down = nil
            // Replay a normal click to the original controls. Queue its release
            // first because AppKit menus/buttons can enter a tracking loop on down.
            NSApp.postEvent(event, atStart: true)
            window.sendEvent(start)
            return nil
        case .keyDown where event.keyCode == 53 && down != nil:
            down = nil
            return nil
        default:
            return event
        }
    }
}
