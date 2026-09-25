import AppKit
import BackendRuntime

func pinProductionRuntime(_ root: URL) throws {
    try mkdir(child(root, "backend"))
    let lock = try FileLock(child(root, "backend/owner.lock"), nonblocking: true)
    defer { withExtendedLifetime(lock) {} }
    let runtime = child(root, "prod-runtime")
    guard exists(child(runtime, "brain/bin/bowser_brain")) else { throw RuntimeFailure("The preserved production runtime is missing.") }
    try atomicJSON(child(root, "backend/active.json"), ["runtime": runtime.path])
}

/// A small guard around the preserved production executable. This also protects
/// older production builds that predate the shared-data/single-instance locks.
@MainActor func launchProduction() throws {
    let bundle = Bundle.main.bundleURL
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BOWSER_HOME"] ?? NSHomeDirectory() + "/.bowser")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    do {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.foxwiseai.bowser").contains(where: {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
        }) else { throw RuntimeFailure("Quit the other Bowser before opening prod.") }
        try mkdir(root)
        let dataLock = try FileLock(child(root, "data-use.lock"), nonblocking: true, shared: true)
        let browserLock = try FileLock(child(root, "browser-instance.lock"), nonblocking: true)
        try pinProductionRuntime(root)
        let process = Process()
        process.executableURL = child(bundle, "Contents/MacOS/Bowser")
        process.arguments = Array(CommandLine.arguments.dropFirst())
        process.environment = ProcessInfo.processInfo.environment.merging(["BOWSER_HOME": root.path]) { _, new in new }
        try process.run()
        process.waitUntilExit()
        withExtendedLifetime((dataLock, browserLock)) {}
    } catch {
        let alert = NSAlert()
        alert.messageText = "Couldn’t open Bowser Prod"
        alert.informativeText = String(describing: error)
        alert.runModal()
        throw error
    }
}
