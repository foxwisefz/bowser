import AppKit
import SwiftUI
import BowserSurfaceKit

/// File export is lazy: moving within Bowser must not build/sign a saved app.
final class TabAppPasteboardProvider: NSObject, NSPasteboardItemDataProvider {
    var makeBundle: () throws -> URL
    private var bundle: URL?
    private(set) var failed = false
    init(makeBundle: @escaping () throws -> URL) { self.makeBundle = makeBundle }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .fileURL else { return }
        do {
            if bundle == nil { bundle = try makeBundle() }
            item.setString(bundle!.absoluteString, forType: .fileURL)
        } catch { failed = true; NSLog("Bowser: tab app drag failed: %@", error.localizedDescription) }
    }
}

final class TabAppDragView: NSView, NSDraggingSource, SurfaceTabDragSource, NSMenuDelegate {
    var isAuthorized: () -> Bool = { true }
    private var interaction: UUID?
    private func beginInteraction() {
        if interaction == nil { interaction = SurfaceServices.shared.beginInteraction() }
    }
    private func endInteraction() {
        if let interaction { SurfaceServices.shared.endInteraction(interaction) }; interaction = nil
    }
    static let tabType = NSPasteboard.PasteboardType("com.foxwiseai.bowser.tab")
    var webviewID: UInt64 = 0
    var select: () -> Void = {}
    private var down: NSEvent?
    private var dragged = false
    private(set) var draggedID: UInt64?
    private var provider: TabAppPasteboardProvider?
    private var insertionAfter: Bool?
    private var dragFrame: NSRect?
    private var cancelled = false
    private var closeGesture = false
    private var closeCue: NSPanel?
    private var closeIcon: NSImage?
    private var escapeMonitor: Any?
    private var scrollTimer: Timer?
    private var dragPoint: NSPoint?

    /// A failed/cancelled drag is not automatically a request to close a tab.
    static func shouldRemove(closing: Bool, operation: NSDragOperation, cancelled: Bool, mouseButtons: Int,
                             exportFailed: Bool, point: NSPoint, dock: NSRect?) -> Bool {
        guard closing, operation.isEmpty, !cancelled, mouseButtons & 1 == 0, !exportFailed,
              let dock else { return false }
        return !dock.insetBy(dx: -64, dy: -32).contains(point)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([Self.tabType])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, interaction != nil { cancelled = true; finishDrag() }
        super.viewWillMove(toWindow: newWindow)
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { closeMenu() }
    func closeMenu() -> NSMenu? {
        guard isAuthorized(), SurfaceServices.shared.tabSnapshot(webviewID) != nil else { return nil }
        let menu = NSMenu()
        menu.delegate = self
        let close = menu.addItem(withTitle: "Close Tab", action: #selector(closeFromMenu), keyEquivalent: "")
        close.target = self
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        return menu
    }
    func menuWillOpen(_ menu: NSMenu) { beginInteraction() }
    func menuDidClose(_ menu: NSMenu) { endInteraction() }
    @objc func closeFromMenu() {
        guard isAuthorized() else { return }
        _ = SurfaceServices.shared.closeTab(webviewID)
    }
    override func mouseDown(with event: NSEvent) {
        guard isAuthorized() else { return }; beginInteraction(); down = event; dragged = false
    }
    override func mouseUp(with event: NSEvent) {
        defer { down = nil; endInteraction() }
        if dragged && closeGesture {
            let point = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            updateReorder(at: point)
            let preview = TabDragPreview.shared
            let destination = cancelled ? nil : preview.target
            let after = preview.after
            let remove = Self.shouldRemove(closing: true, operation: [], cancelled: cancelled,
                mouseButtons: 0, exportFailed: false, point: point, dock: dragFrame)
            let id = draggedID
            finishDrag()
            if let id, let destination, isAuthorized() {
                _ = SurfaceServices.shared.moveTab(id, destination, after)
            } else if remove, let id, SurfaceServices.shared.closeTab(id) {
                TabDustEffect.show(at: point)
            }
        } else if !dragged, down != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { select() }
    }
    override func mouseDragged(with event: NSEvent) {
        if dragged && closeGesture {
            let point = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            dragPoint = point
            updateReorder(at: point)
            updateCloseCue(at: point)
            return
        }
        guard !dragged, let down,
              hypot(event.locationInWindow.x - down.locationInWindow.x,
                    event.locationInWindow.y - down.locationInWindow.y) >= 5,
              let tab = SurfaceServices.shared.tabSnapshot(webviewID) else { return }
        dragged = true
        draggedID = webviewID
        TabDragPreview.shared.source = webviewID
        dragFrame = window?.frame
        cancelled = false
        // Ordinary drags reorder inside the dock and close outside it.
        closeGesture = !event.modifierFlags.contains(.option)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancelOperation(nil) }
            return event
        }
        let icon = tab.icon
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        if closeGesture {
            closeIcon = icon
            // Keep this entirely in AppKit mouse tracking: no drag pasteboard,
            // file promise, URL or drop operation is offered to another app.
            SurfaceServices.shared.edgeDragging(true)
            let point = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            dragPoint = point
            updateReorder(at: point)
            updateCloseCue(at: point)
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrollDuringDrag() }
            }
            scrollTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            return
        }
        let pasteboard = NSPasteboardItem()
        pasteboard.setString(String(webviewID), forType: Self.tabType)
        if tab.canExport {
            let id = webviewID
            let provider = TabAppPasteboardProvider { try SurfaceServices.shared.exportTab(id) }
            self.provider = provider
            pasteboard.setDataProvider(provider, forTypes: [.fileURL])
        }
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        item.setDraggingFrame(bounds, contents: icon)
        SurfaceServices.shared.edgeDragging(true)
        let session = beginDraggingSession(with: [item], event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move] : [.copy, .link, .generic]
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finishDrag()
    }

    override func cancelOperation(_ sender: Any?) {
        cancelled = true
        scrollTimer?.invalidate(); scrollTimer = nil
        TabDragPreview.shared.target = nil
        closeCue?.orderOut(nil)
    }

    private func updateReorder(at point: NSPoint) {
        let preview = TabDragPreview.shared
        guard !cancelled, isAuthorized(), let id = draggedID, let window,
              let root = window.contentView else { preview.target = nil; return }
        guard window.frame.insetBy(dx: -64, dy: -32).contains(point) else {
            preview.target = nil; return
        }
        func rows(in view: NSView) -> [(TabAppDragView, NSRect)] {
            guard !view.isHidden else { return [] }
            if let row = view as? TabAppDragView, row !== self,
               !row.bounds.intersection(row.visibleRect).isEmpty, row.isAuthorized(),
               SurfaceServices.shared.canMoveTab(id, row.webviewID) {
                return [(row, window.convertToScreen(row.convert(row.bounds.intersection(row.visibleRect), to: nil)))]
            }
            return view.subviews.flatMap { rows(in: $0) }
        }
        guard let (row, frame) = rows(in: root).min(by: {
            abs($0.1.midY - point.y) < abs($1.1.midY - point.y)
        }) else { preview.target = nil; return }
        // Stable rows let the pointer cross a midpoint in either direction,
        // including the space between icons, without chasing an animated gap.
        preview.after = point.y < frame.midY
        preview.target = row.webviewID
    }

    private func scrollDuringDrag() {
        guard !cancelled, isAuthorized(), let point = dragPoint, let window,
              window.frame.insetBy(dx: -64, dy: -32).contains(point),
              let scroll = enclosingScrollView, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let bounds = clip.bounds
        guard document.bounds.height > bounds.height else { return }
        let local = clip.convert(window.convertPoint(fromScreen: point), from: nil)
        let edge: CGFloat = 28
        let step: CGFloat
        if local.y < bounds.minY + edge {
            step = -min(10, max(2, (bounds.minY + edge - local.y) / 3))
        } else if local.y > bounds.maxY - edge {
            step = min(10, max(2, (local.y - bounds.maxY + edge) / 3))
        } else { return }
        let y = min(max(document.bounds.minY, bounds.minY + step), document.bounds.maxY - bounds.height)
        guard y != bounds.minY else { return }
        clip.scroll(to: NSPoint(x: bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
        scroll.layoutSubtreeIfNeeded()
        updateReorder(at: point)
    }

    private func finishDrag() {
        scrollTimer?.invalidate(); scrollTimer = nil
        dragPoint = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        endInteraction()
        closeCue?.close()
        closeCue = nil
        closeIcon = nil
        down = nil
        draggedID = nil
        closeGesture = false
        TabDragPreview.shared.finish()
        provider = nil
        dragFrame = nil
        SurfaceServices.shared.edgeDragging(false)
    }

    private func updateCloseCue(at point: NSPoint) {
        guard !cancelled else { return }
        let ready = Self.shouldRemove(closing: true, operation: [], cancelled: false,
            mouseButtons: 0, exportFailed: false, point: point, dock: dragFrame)
        let panel = closeCue ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 170, height: 36),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        if closeCue == nil {
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            closeCue = panel
        }
        panel.contentView = NSHostingView(rootView: TabDragCue(icon: closeIcon, closing: ready))
        if ready {
            // The icon stays under the pointer; the label floats above it,
            // like the macOS Dock's removal cue.
            panel.setFrame(NSRect(x: point.x - 60, y: point.y - 24, width: 120, height: 84), display: true)
        } else {
            let x = dragFrame?.midX ?? point.x
            panel.setFrame(NSRect(x: x - 20, y: point.y - 20, width: 40, height: 40), display: true)
        }
        panel.orderFrontRegardless()
    }

    private func sourceID(_ sender: NSDraggingInfo) -> UInt64? {
        guard let source = sender.draggingSource as? any SurfaceTabDragSource,
              let id = source.draggedID, id != webviewID,
              isAuthorized(), SurfaceServices.shared.canMoveTab(id, webviewID) else { return nil }
        return id
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sourceID(sender) != nil else { clearInsertion(); return [] }
        // NSView's origin is bottom-left; the lower half inserts after this row.
        // Keep the chosen edge stable while its expanded drop gap is hovered.
        if insertionAfter == nil {
            insertionAfter = convert(sender.draggingLocation, from: nil).y < bounds.midY
            TabDragPreview.shared.after = insertionAfter == true
            TabDragPreview.shared.target = webviewID
        }
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearInsertion() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { sourceID(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearInsertion() }
        guard let id = sourceID(sender), let after = insertionAfter else { return false }
        return SurfaceServices.shared.moveTab(id, webviewID, after)
    }
    private func clearInsertion() {
        insertionAfter = nil
        TabDragPreview.shared.clear(target: webviewID)
    }
}


/// A Dock-style caption above the dragged tab, with room for its soft shadow.
struct TabDragCue: View {
    let icon: NSImage?
    let closing: Bool

    var body: some View {
        VStack(spacing: 10) {
            if closing {
                Text("Close tab")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .fixedSize()
                    .padding(.horizontal, 13)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.45), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
            }
            if let icon {
                Image(nsImage: icon).resizable().scaledToFit()
                    .frame(width: 32, height: 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}
