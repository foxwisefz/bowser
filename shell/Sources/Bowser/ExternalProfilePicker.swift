import AppKit
import SwiftUI
import BowserSurfaceKit

@MainActor
final class ExternalProfilePickerModel: ObservableObject, ExternalProfilePresentation {
    @Published private(set) var urls: [URL] = []
    @Published var error: String?
    private let profiles: () -> [Profile]
    var open: ([URL], String) -> Void = { _, _ in }
    var dismiss: () -> Void = {}
    init(profiles: @escaping () -> [Profile] = { Profile.all }) { self.profiles = profiles }
    var choices: [ProfileDisplay] {
        profiles().map { ProfileDisplay(id: $0.id, name: $0.name, draft: ProfileDraft($0)) }
    }
    var destination: String {
        guard let url = urls.first else { return "" }
        return url.isFileURL ? url.lastPathComponent : (url.host ?? "Website")
    }
    var linkCount: Int { urls.count }
    func receive(_ incoming: [URL]) {
        let incoming = AppDelegate.webURLs(from: incoming)
        guard !incoming.isEmpty else { return }
        urls.append(contentsOf: incoming)
        error = nil
        if profiles().count == 1, let profile = profiles().first { choose(profile.id) }
    }
    func choose(_ id: String) {
        guard profiles().contains(where: { $0.id == id }) else {
            error = "That profile is no longer available. Choose another profile."
            return
        }
        guard !urls.isEmpty else { return }
        let pending = urls
        urls.removeAll()
        dismiss()
        open(pending, id)
    }
    func cancel() { urls.removeAll(); error = nil; dismiss() }
}

@MainActor
final class ExternalProfilePicker: NSWindowController, NSWindowDelegate {
    let model = ExternalProfilePickerModel()
    init(open: @escaping ([URL], String) -> Void) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 440),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Open link in Bowser"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: LiveBrowserScreen(kind: "external-profile", model: model))
        model.open = open
        model.dismiss = { [weak self] in self?.window?.orderOut(nil) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func receive(_ urls: [URL]) {
        model.receive(urls)
        guard model.linkCount > 0 else { return }
        window?.setContentSize(NSSize(width: 430, height: Self.contentHeight(profileCount: model.choices.count)))
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
    static func contentHeight(profileCount: Int) -> CGFloat {
        226 + CGFloat(min(4, max(1, profileCount))) * 76
    }
    func windowWillClose(_ notification: Notification) { model.cancel() }
}
