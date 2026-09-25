import AppKit

let app = NSApplication.shared
guard InstalledInstance.acquire() else { exit(0) }
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
