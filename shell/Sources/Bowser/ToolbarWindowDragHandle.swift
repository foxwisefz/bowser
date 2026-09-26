import AppKit
import SwiftUI

/// Tracks the whole toolbar before controls commit to a click or open a menu.
struct ToolbarWindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolbarWindowDragView { ToolbarWindowDragView() }
    func updateNSView(_ view: ToolbarWindowDragView, context: Context) {}
}

final class ToolbarWindowDragView: NSView {
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

    func handle(_ event: NSEvent) -> NSEvent? {
        guard let window else { down = nil; return event }
        switch event.type {
        case .leftMouseDown:
            down = nil
            guard event.window === window, !isHiddenOrHasHiddenAncestor,
                  visibleRect.contains(convert(event.locationInWindow, from: nil)) else { return event }
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
