import AppKit
import BackendRuntime

/// The updater takes the exclusive data lock before backing up or replacing
/// anything. Saved apps share it; only one main browser may own the instance lock.
@MainActor enum InstalledInstance {
    private static var dataLock: FileLock?
    private static var instanceLock: FileLock?

    static func acquire() -> Bool {
        do {
            try mkdir(BowserPaths.home)
        } catch {
            return alert("Bowser’s data is unavailable", String(describing: error))
        }
        if let other = sibling() { return handoff(other) }
        return waitForLocks()
    }

    /// A second launch of the main browser activates the running one instead
    /// of failing; the running app and any updater already own the locks.
    private static func sibling() -> NSRunningApplication? {
        guard SiteAppConfiguration.current == nil, Bundle.main.bundleIdentifier == "com.foxwiseai.bowser" else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: "com.foxwiseai.bowser").first {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
        }
    }

    private static func handoff(_ other: NSRunningApplication) -> Bool {
        other.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        return false
    }

    private static func takeLocks() throws {
        dataLock = try FileLock(child(BowserPaths.home, "data-use.lock"), nonblocking: true, shared: true)
        do {
            if SiteAppConfiguration.current == nil {
                instanceLock = try FileLock(child(BowserPaths.home, "browser-instance.lock"), nonblocking: true)
            }
        } catch {
            dataLock = nil
            throw error
        }
    }

    /// A kill can leave the updater mid-backup holding the exclusive data
    /// lock. Wait at the gate instead of erroring: the update finishes, then
    /// this launch continues — or relaunches onto the freshly installed build.
    private static func waitForLocks() -> Bool {
        let started = Date()
        let marker = park()
        defer { if let marker { try? FileManager.default.removeItem(at: marker) } }
        var waited = false
        var window: NSWindow?
        var deadline = started.addingTimeInterval(120)
        while true {
            do {
                try takeLocks()
                window?.orderOut(nil)
                if waited, updateCompleted(for: Bundle.main.bundleURL, since: started) {
                    relaunch(Bundle.main.bundleURL)
                    return false
                }
                return true
            } catch {
                dataLock = nil
                instanceLock = nil
                waited = true
                if let other = sibling() {
                    window?.orderOut(nil)
                    return handoff(other)
                }
                if Date() >= deadline {
                    window?.orderOut(nil)
                    guard keepWaiting() else { return false }
                    deadline = Date().addingTimeInterval(120)
                } else {
                    if window == nil, Date() > started.addingTimeInterval(2) { window = showWaitWindow() }
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
                }
            }
        }
    }

    /// Registers this launch as parked at the gate so the updater's process
    /// scan ignores it; without the marker both sides would wait forever.
    private static func park() -> URL? {
        let directory = child(BowserPaths.home, "launch-waiting")
        let marker = child(directory, String(ProcessInfo.processInfo.processIdentifier))
        try? mkdir(directory)
        guard FileManager.default.createFile(atPath: marker.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
        return marker
    }

    /// progress.json survives the update, so only a completion written after
    /// this launch started waiting means the bundle was replaced under us.
    static func updateCompleted(for bundle: URL, since started: Date,
                                progress: URL = BowserPaths.home.appendingPathComponent("updates/progress.json")) -> Bool {
        guard let data = try? Data(contentsOf: progress),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              state["phase"] as? String == "complete",
              let target = state["bundle"] as? String,
              URL(fileURLWithPath: target).resolvingSymlinksInPath() == bundle.resolvingSymlinksInPath(),
              let modified = try? progress.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              modified > started else { return false }
        return true
    }

    /// The running process keeps the replaced build's code, so hand off to a
    /// fresh process rather than mix old code with migrated data.
    private static func relaunch(_ bundle: URL) {
        let path = bundle.path.replacingOccurrences(of: "'", with: "'\\''")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; exec /usr/bin/open '\(path)'"]
        try? process.run()
    }

    private static func showWaitWindow() -> NSWindow {
        let name = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Bowser"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Opening " + name
        window.isReleasedWhenClosed = false
        let label = NSTextField(wrappingLabelWithString: "Finishing an update or recovery…\n" + name + " will open automatically.")
        label.frame = NSRect(x: 24, y: 72, width: 352, height: 56)
        let spinner = NSProgressIndicator()
        spinner.frame = NSRect(x: 24, y: 40, width: 352, height: 16)
        spinner.style = .bar
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        window.contentView?.addSubview(label)
        window.contentView?.addSubview(spinner)
        window.center()
        window.orderFront(nil)
        return window
    }

    private static func keepWaiting() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Bowser’s data is still in use"
        alert.informativeText = "An update or recovery is taking longer than expected."
        alert.addButton(withTitle: "Keep Waiting")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func alert(_ message: String, _ detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
        return false
    }
}
