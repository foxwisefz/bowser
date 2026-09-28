import AppKit
import BackendRuntime

/// Background restart coordinator, outside the app bundle being replaced.
/// UI is reserved for failures and quit prompts that need user attention.
@MainActor final class UpdateWindow: NSObject {
    let pending: URL
    let manifest: Message
    let bundle: URL
    let stage: URL
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 215),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let label = NSTextField(wrappingLabelWithString: "Closing Bowser…")
    let spinner = NSProgressIndicator()
    let stop = NSButton(title: "Stop Waiting", target: nil, action: nil)
    var savedApps: [URL] = []
    var timer: Timer?
    var opening = false
    let started = Date()

    init(pending: URL, manifest: Message) throws {
        self.pending = pending; self.manifest = manifest
        bundle = try field(manifest, "bundle"); stage = try field(manifest, "stage")
        super.init()
    }

    func start() {
        window.title = "Updating " + bundle.deletingPathExtension().lastPathComponent
        window.isReleasedWhenClosed = false
        label.frame = NSRect(x: 28, y: 110, width: 384, height: 68)
        spinner.frame = NSRect(x: 28, y: 85, width: 384, height: 16)
        spinner.style = .bar; spinner.isIndeterminate = true; spinner.startAnimation(nil)
        window.contentView?.addSubview(label); window.contentView?.addSubview(spinner)
        stop.frame = NSRect(x: 285, y: 24, width: 130, height: 32)
        stop.bezelStyle = .rounded; stop.target = self; stop.action = #selector(stopWaiting)
        window.contentView?.addSubview(stop)
        window.center()
        // Use AppKit's normal quit request: no signals or forced termination.
        let saved = manifest["saved_apps"] as? String
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Bowser Apps").path
        let sharedHome = (try? home(manifest)) == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bowser").resolvingSymlinksInPath()
        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let url = app.bundleURL?.resolvingSymlinksInPath() else { continue }
            let shared = sharedHome && ["/Applications/Bowser.app", "/Applications/Bowser-staging.app", "/Applications/Bowser-prod.app"].contains(url.path)
            if url == bundle || url.path.hasPrefix(saved + "/") || shared {
                if url.path.hasPrefix(saved + "/") { savedApps.append(url) }
                _ = app.terminate()
            }
        }
        let pendingPath = pending.path
        Task.detached { try? await runUpdater([pendingPath, "--wait"]) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    @objc func stopWaiting() { NSApp.terminate(nil) }

    func poll() {
        guard !opening else { return }
        if let current = try? readJSON(pending), current["stage"] as? String != manifest["stage"] as? String {
            fail("A newer update replaced this one. Open Check for Updates in Bowser to restart with the latest update.")
            return
        }
        let progress = try? readJSON(pending.deletingLastPathComponent().appendingPathComponent("progress.json"))
        let matches = progress?["stage"] as? String == manifest["stage"] as? String && progress?["bundle"] as? String == manifest["bundle"] as? String
        let phase = progress?["phase"] as? String
        if !exists(pending), !matches || phase != "complete" {
            fail("The pending update was cancelled. Bowser has not been restarted.")
            return
        }
        guard matches else { return }
        stop.isEnabled = phase == "waiting"
        if phase != "waiting" { window.orderOut(nil) }
        switch phase {
        case "backup": label.stringValue = "Backing up and verifying your data…\nBowser will reopen automatically."
        case "installing": label.stringValue = "Installing the update…\nBowser will reopen automatically."
        case "complete":
            guard !exists(pending) else { return }
            opening = true; timer?.invalidate()
            label.stringValue = "Reopening Bowser…"
            NSWorkspace.shared.openApplication(at: bundle, configuration: .init()) { _, error in
                Task { @MainActor in
                    if let error { self.fail(error.localizedDescription) }
                    else {
                        do {
                            for url in self.savedApps {
                                let configuration = NSWorkspace.OpenConfiguration()
                                configuration.activates = false
                                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                            }
                            NSApp.terminate(nil)
                        } catch { self.fail(error.localizedDescription) }
                    }
                }
            }
        case "failed": fail(progress?["error"] as? String ?? "The update could not finish.")
        default:
            if phase == "waiting", Date().timeIntervalSince(started) > 15, !window.isVisible {
                label.stringValue = "Waiting for Bowser and saved apps to close.\nSave any unfinished work or answer their quit prompts."
                window.title = "Finish closing Bowser"
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func fail(_ detail: String) {
        fputs("updater failure: \(detail)\n", stderr)
        timer?.invalidate(); spinner.stopAnimation(nil)
        label.stringValue = "The update could not finish."
        let alert = NSAlert(); alert.messageText = "Couldn’t finish updating Bowser"
        alert.informativeText = detail
        alert.addButton(withTitle: "Close")
        window.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal(); NSApp.terminate(nil)
    }
}

@MainActor func runUpdateWindow(_ args: [String]) throws {
    guard let first = args.first else { throw RuntimeFailure("missing pending update") }
    let pending = URL(fileURLWithPath: first).resolvingSymlinksInPath()
    let manifest = try readJSON(pending)
    // One coordinator per home; never duplicate shutdown or relaunch requests.
    let lock = try FileLock(pending.deletingLastPathComponent().appendingPathComponent("restart.lock"), nonblocking: true)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if args.contains("--offer") {
        let alert = NSAlert(); alert.messageText = "Update ready"
        let bundle = try field(manifest, "bundle")
        alert.icon = NSImage(contentsOf: bundle.appendingPathComponent("Contents/Resources/AppIcon.icns"))
        alert.informativeText = bundle.deletingPathExtension().lastPathComponent + " and its saved apps will close, back up your data, install the update, and reopen. Save unfinished work before restarting."
        alert.addButton(withTitle: "Restart Now"); alert.addButton(withTitle: "Later")
        app.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    let current = try readJSON(pending)
    guard try field(current, "bundle") == field(manifest, "bundle") else {
        throw RuntimeFailure("The prepared update changed apps; check for updates again.")
    }
    let controller = try UpdateWindow(pending: pending, manifest: current)
    controller.start()
    withExtendedLifetime((controller, lock)) { app.run() }
}
