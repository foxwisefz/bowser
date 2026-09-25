import AppKit

/// Counts use of the main production app. Never reads keys, URLs or page content.
@MainActor
final class AppUsage {
    static let shared = AppUsage()
    static func eligible(bundleID: String?, channel: String?) -> Bool {
        bundleID == "com.foxwiseai.bowser" && channel != "staging"
            && ProcessInfo.processInfo.environment["BOWSER_TELEMETRY_DISABLED"] != "1"
    }
    private let enabled = eligible(bundleID: Bundle.main.bundleIdentifier,
                                   channel: Bundle.main.infoDictionary?["BowserChannel"] as? String)
    private var started = false
    private var activated = false
    private var lastDay: Int?
    private var monitor: Any?
    func start(activated: Bool) {
        guard enabled, !started else { return }
        started = true; self.activated = activated
        Task { await Telemetry.shared.recordUsage("app_open", phase: activated ? "activated" : "onboarding") }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            self?.becameActive()
            return event
        }
        becameActive()
    }
    func didActivate() {
        activated = true
        becameActive()
    }
    func enteredEmail() {
        guard enabled else { return }
        Task { await Telemetry.shared.recordUsage("onboarding_email_entered") }
    }
    func becameActive() {
        guard enabled, started, activated, NSApp.isActive else { return }
        let now = Date(), day = Int(floor(Date().timeIntervalSince1970 / 86400))
        guard lastDay != day else { return }
        lastDay = day
        Task { await Telemetry.shared.recordUsage("app_active", at: now) }
    }
}
