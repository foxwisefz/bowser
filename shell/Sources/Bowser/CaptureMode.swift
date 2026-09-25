import AppKit

/// Manual capture lasts until toggled off or the app quits. Automatic detection
/// is deliberately limited to the public SharePlay window-sharing signal.
struct CaptureModeState {
    private(set) var manual = false
    private(set) var sharing = false
    private var dismissedSharing = false
    var isEnabled: Bool { manual || (sharing && !dismissedSharing) }

    mutating func updateSharing(_ active: Bool) {
        sharing = active
        if !active { dismissedSharing = false }
    }

    mutating func toggle() {
        if isEnabled {
            manual = false
            dismissedSharing = sharing
        } else {
            manual = true
        }
    }
}

@MainActor
final class CaptureMode: NSObject, NSMenuItemValidation {
    static let shared = CaptureMode()
    private var state = CaptureModeState()
    private var timer: Timer?
    var isEnabled: Bool { state.isEnabled }

    func register(_ browser: BrowserWindowController) {
        if timer == nil {
            // Read-only AppKit state; no screen capture or Accessibility access.
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSharing() }
            }
        }
        refreshSharing()
        browser.setCaptureMode(isEnabled)
    }

    func refreshSharing() {
        let before = isEnabled
        state.updateSharing(BrowserWindowController.all.contains { $0.window?.hasActiveWindowSharingSession == true })
        if before != isEnabled { apply() }
        if BrowserWindowController.all.isEmpty { timer?.invalidate(); timer = nil }
    }

    @objc func toggleCaptureMode(_ sender: Any? = nil) {
        state.toggle()
        apply()
    }

    private func apply() {
        if isEnabled { CommandBar.shared.hide() }
        for browser in BrowserWindowController.all { browser.setCaptureMode(isEnabled) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(toggleCaptureMode(_:)) else { return false }
        item.state = isEnabled ? .on : .off
        return true
    }
}
