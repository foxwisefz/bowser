import AppKit
import WebKit

/// Relays page messages (console.* taps and window.bowser.emit) to the brain.
/// Separate object so the user content controller never retains EngineView.
private final class PageRelay: NSObject, WKScriptMessageHandler {
    weak var view: EngineView?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let name = message.name
        let body = message.body
        let sender = message.webView
        MainActor.assumeIsolated {
            // Attribute by the message's own webView: when a popup shares
            // the opener's content controller, only ONE relay is registered
            // and it must credit whichever tab actually sent the message.
            guard let id = EngineView.live.first(where: { $0.value.webView === sender })?.key
                ?? view?.webviewId
            else { return }
            switch name {
            case "bowserEdited":
                EngineView.live[id]?.noteUserEdit()
            case "bowserScriptsReady":
                guard message.frameInfo.isMainFrame, let engine = EngineView.live[id],
                      let expected = body as? String, let url = message.frameInfo.request.url,
                      url.absoluteString == expected else { return }
                engine.dispatchModScripts(frame: message.frameInfo, url: url)
            case "bowserConsole":
                guard let dict = body as? [String: Any] else { return }
                BrainBridge.shared.send([
                    "op": "event", "event": "console", "webview": id,
                    "level": dict["level"] as? String ?? "log",
                    "message": dict["message"] as? String ?? "",
                ])
            case "bowserMediaWarm":
                guard message.frameInfo.isMainFrame,
                      let dict = body as? [String: Any],
                      dict["runtime"] as? String == MediaRecovery.runtime,
                      let engine = EngineView.live[id], !engine.didWarmMediaRecovery
                else { return }
                engine.didWarmMediaRecovery = true
                BrowserWindowController.host(of: id)?.warmTab(id: id, ms: 10_000)
            case "bowserEmit":
                // The page->brain duplex channel: whatever the page emits,
                // mods receive as {"event": "page", "payload": ...}.
                BrainBridge.shared.send([
                    "op": "event", "event": "page", "webview": id,
                    "payload": BrainBridge.jsonify(body),
                ])
            default:
                break
            }
        }
    }
}

/// The engine surface (ADR 0008): a WKWebView per tab. WebKit owns input,
/// rendering, and process isolation; this class owns identity, user content,
/// and event flow to the brain.
@MainActor
final class EngineView: NSView, WKNavigationDelegate, WKUIDelegate {
    private var navigationDiagnosticTrace = NavigationDiagnosticTrace()
    private let navigationNetwork = NavigationNetworkMonitor.shared
    private(set) static var live: [UInt64: EngineView] = [:]
    private static var nextId: UInt64 = 1

    var onTitleChange: ((String) -> Void)?
    var onURLChange: ((String) -> Void)?
    var onThemeColor: ((NSColor?) -> Void)?

    private(set) var webviewId: UInt64 = 0
    var onFaviconChange: (() -> Void)?
    private(set) var faviconPath: String?
    private var faviconGeneration = UUID()
    private var iconCandidates: [[String: Any]] = []
    private var faviconICNSPath: String?
    /// Last sampled page tint. Cached because a tab can be mounted long
    /// after it loaded, and the chrome has to catch up on the spot.
    private(set) var themeColor: NSColor?
    private(set) var webView: WKWebView

    private let pageRelay = PageRelay()
    fileprivate var didWarmMediaRecovery = false
    private var urlObservation: NSKeyValueObservation?
    private var mediaObservations: [NSKeyValueObservation] = []
    private var titleObservation: NSKeyValueObservation?
    private var loadingCover: PageLoadingView?
    private(set) var hasRenderedContent = false
    private(set) var observesRenderingProgress = false
    var isShowingLoadingCover: Bool { loadingCover != nil }
    private var currentScripts: [ModScript] = []
    private var currentStyles: [String] = []

    // The brain's last-pushed user content. set_user_content only reaches
    // webviews alive at push time — a tab opened later was born UNMODDED
    // (no site payloads, no mod scripts) until the next push
    // (bowser-browser-1af). New views seed from here instead.
    private(set) static var sharedScripts: [ModScript] = []
    private(set) static var sharedStyles: [String] = []
    private static var profileScripts: [String: [ModScript]] = [:]
    private static var profileStyles: [String: [String]] = [:]
    static func content(for profile: String) -> (scripts: [ModScript], styles: [String]) {
        (sharedScripts + (profileScripts[profile] ?? []), sharedStyles + (profileStyles[profile] ?? []))
    }

    /// Same nil/[] semantics as applyUserContent: nil leaves that kind
    /// untouched, [] clears it.
    static func rememberUserContent(scripts: [ModScript]?, styles: [String]?, profile: String? = nil) {
        if let profile {
            if let scripts { profileScripts[profile] = scripts }
            if let styles { profileStyles[profile] = styles }
            return
        }
        if let scripts { sharedScripts = scripts }
        if let styles { sharedStyles = styles }
    }

    static let consoleHook = """
    (function () {
      ["log", "warn", "error", "info"].forEach(function (level) {
        var original = console[level];
        console[level] = function () {
          try {
            window.webkit.messageHandlers.bowserConsole.postMessage({
              level: level,
              message: Array.prototype.map.call(arguments, String).join(" ")
            });
          } catch (e) {}
          return original.apply(console, arguments);
        };
      });
      window.bowser = {
        emit: function (payload) {
          return window.webkit.messageHandlers.bowserEmit.postMessage(payload);
        }
      };
    })();
    """

    /// Browser notches overlay the page without a full-width reserved band.
    static let pageTopInset: CGFloat = 0

    /// Invoke an ObjC setter taking a primitive (no KVC, no NSInvocation).
    private static func callPrivateSetter(_ target: NSObject, _ name: String, bool value: Bool) {
        let sel = Selector((name))
        guard target.responds(to: sel), let imp = target.method(for: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
        unsafeBitCast(imp, to: Fn.self)(target, sel, ObjCBool(value))
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, configuration: nil)
    }

    /// Popups (target=_blank) must be created with the configuration WebKit
    /// hands us in createWebViewWith — hence the injectable configuration.
    /// Which profile this webview belongs to (its window's). Popups arrive
    /// with WebKit's configuration — the opener's store — and their window
    /// is the opener's, so the id still matches the store.
    let profileId: String

    init(frame frameRect: NSRect, configuration external: WKWebViewConfiguration?, profile: Profile = .defaultProfile) {
        profileId = profile.id
        let configuration = external ?? {
            let c = WKWebViewConfiguration()
            // The profile's own cookies/logins/storage (default profile =
            // the default store, so pre-profile logins stay put).
            c.websiteDataStore = profile.dataStore
            return c
        }()
        // Media resume after a respawn needs programmatic play().
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // WKWebView disables HTML element fullscreen by default; Safari
        // enables it. Without this, a video's fullscreen button does nothing
        // (bowser-browser-cgt). Public API on macOS 12.3+.
        configuration.preferences.isElementFullscreenEnabled = true
        // macOS exposes PiP through WebKit's preferences SPI (not the iOS
        // configuration property). Guard the selector and avoid unsafe KVC.
        Self.callPrivateSetter(configuration.preferences, "_setAllowsPictureInPictureMediaPlayback:", bool: true)
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init(frame: frameRect)

        webviewId = Self.nextId
        Self.nextId += 1
        Self.live[webviewId] = self

        configureWebView()
    }

    private func configureWebView() {
        pageRelay.view = self
        registerRelay()
        currentScripts = Self.content(for: profileId).scripts
        currentStyles = Self.content(for: profileId).styles
        rebuildUserScripts()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // Full Safari impersonation: WKWebView's default UA lacks the
        // "Version/x Safari/x" suffix and sites like YouTube Music sniff it.
        webView.customUserAgent = SafariUserAgent.current
        webView.frame = bounds
        addSubview(webView)
        hasRenderedContent = false
        showLoadingCover(loading: false)
        // WebKit's first visually nonempty layout is earlier than didFinish:
        // a slow image must not hide an otherwise usable page. Guard this SPI
        // and use didFinish as the fallback; never call primitive setters via KVC.
        let selector = NSSelectorFromString("_setObservedRenderingProgressEvents:")
        if webView.responds(to: selector), let implementation = webView.method(for: selector) {
            typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
            unsafeBitCast(implementation, to: Setter.self)(webView, selector, 1 << 1)
            observesRenderingProgress = true
        }

        urlObservation = webView.observe(\.url) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self, self.pendingRestoreURL == nil, let url = self.failedNavigationURL ?? view.url?.absoluteString else { return }
                self.onURLChange?(url)
                BrainBridge.shared.send([
                    "op": "event", "event": "url_changed",
                    "webview": self.webviewId, "url": url,
                ])
            }
        }
        mediaObservations = [webView.observe(\.cameraCaptureState) { [weak self] _, _ in
            Task { @MainActor in if let self { BrowserWindowController.host(of: self.webviewId)?.syncModButtons() } }
        }, webView.observe(\.microphoneCaptureState) { [weak self] _, _ in
            Task { @MainActor in if let self { BrowserWindowController.host(of: self.webviewId)?.syncModButtons() } }
        }]
        titleObservation = webView.observe(\.title) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self, self.pendingRestoreURL == nil else { return }
                let title = view.title ?? ""
                SiteAppBadge.shared.updateTitle(title, id: self.webviewId, url: view.url)
                self.onTitleChange?(title)
                BrainBridge.shared.send([
                    "op": "event", "event": "title_changed",
                    "webview": self.webviewId, "title": title,
                ])
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private let externalNavigation = ExternalNavigationConsent()

    private(set) var pendingRestoreURL: String?
    private var sleepingInteractionState: Any?
    private var sleepingTitle: String?
    private(set) var lastVisibleAt = Date()
    private(set) var hasUnsavedInteraction = false
    private var hasSubmittedForm = false
    var isSleeping: Bool { sleepingInteractionState != nil }
    var currentTitle: String { sleepingTitle ?? webView.title ?? "" }
    private var requestedURL: String?
    private var failedNavigationURL: String?
    var currentURLString: String? { pendingRestoreURL ?? failedNavigationURL ?? webView.url?.absoluteString ?? requestedURL }

    /// Restored background pages keep their identity without starting a load.
    /// Mounting in a window (selection, split pane, or explicit warming) resumes it.
    func restore(urlString: String) {
        guard window == nil else { load(urlString: urlString); return }
        pendingRestoreURL = urlString
        showCachedFavicon(for: URL(string: urlString))
        onURLChange?(urlString)
        BrainBridge.shared.send(["op": "event", "event": "url_changed",
                                 "webview": webviewId, "url": urlString])
        let title = URL(string: urlString)?.host ?? urlString
        onTitleChange?(title)
        BrainBridge.shared.send(["op": "event", "event": "title_changed",
                                 "webview": webviewId, "title": title])
    }

    override func keyDown(with event: NSEvent) {
        // WebKit can insert text in a JS editor yet return the key as unhandled.
        // Its async replay then bubbles here and NSWindow would beep. This is
        // only the fallback AFTER WebKit; never resend it or intercept input.
        if let responder = window?.firstResponder as? NSView,
           responder === webView || responder.isDescendant(of: webView),
           event.modifierFlags.intersection([.command, .control]).isEmpty,
           let text = event.characters, !text.isEmpty,
           text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) {
            return
        }
        super.keyDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lastVisibleAt = Date()
        if window != nil { _ = resumePageIfNeeded() }
        else { dismissTabPreview() }
    }

    @discardableResult func resumePageIfNeeded() -> Bool {
        if let interaction = sleepingInteractionState {
            showTabPreview()
            sleepingInteractionState = nil
            sleepingTitle = nil
            pendingRestoreURL = nil
            webView.interactionState = interaction
            return true
        } else if let url = pendingRestoreURL {
            load(urlString: url)
            return true
        }
        return false
    }

    func reloadPage() {
        if let url = failedNavigationURL { load(urlString: url) }
        else if !resumePageIfNeeded() { webView.reload() }
    }

    var inspectionUnavailableReason: String? {
        pendingRestoreURL == nil ? nil : "tab_unloaded: activate the tab and wait for load_status 2 before inspecting it"
    }

    private var tabPreview: ResurrectOverlayView?
    var isShowingTabPreview: Bool { tabPreview != nil }

    /// Reuse the startup capture; only compressed bytes remain for inactive tabs.
    func capturePreview() {
        guard pendingRestoreURL == nil, tabPreview == nil, !webView.isLoading,
              let url = currentURLString else { return }
        ResurrectFrame.capture(webView) { [weak self] data in
            guard let self, Self.live[self.webviewId] === self,
                  self.currentURLString == url else { return }
            TabPreviewCache.shared.store(data, for: self.webviewId, url: url)
        }
    }

    private func showTabPreview() {
        guard window != nil, let url = currentURLString,
              let data = TabPreviewCache.shared.data(for: webviewId, url: url),
              let image = NSImage(data: data) else { return }
        dismissTabPreview()
        let overlay = ResurrectOverlayView(frame: bounds)
        overlay.image = image
        overlay.imageScaling = .scaleProportionallyUpOrDown
        overlay.imageAlignment = .alignTopLeft
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        overlay.onDismiss = { [weak self] in self?.dismissTabPreview() }
        addSubview(overlay, positioned: .above, relativeTo: webView)
        tabPreview = overlay
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak overlay] in
            guard let self, let overlay, self.tabPreview === overlay else { return }
            self.dismissTabPreview()
        }
    }

    private func dismissTabPreview() {
        tabPreview?.removeFromSuperview()
        tabPreview = nil
    }

    private func showLoadingCover(loading: Bool = true) {
        if loadingCover == nil {
            let cover = PageLoadingView(frame: bounds)
            cover.autoresizingMask = [.width, .height]
            addSubview(cover, positioned: .above, relativeTo: webView)
            loadingCover = cover
        }
        loadingCover?.loading = loading
    }

    @objc(_webView:renderingProgressDidChange:)
    func renderingProgress(_ sender: WKWebView, didChange events: UInt) {
        guard sender === webView, events & (1 << 1) != 0, sender.url != nil else { return }
        revealPageContent()
    }

    private func revealPageContent() {
        hasRenderedContent = true
        loadingCover?.removeFromSuperview()
        loadingCover = nil
        dismissTabPreview()
        BrowserWindowController.host(of: webviewId)?.engineDidPaint(self)
    }

    func noteUserEdit() { hasUnsavedInteraction = true }

    private var canSleep: Bool {
        guard SiteAppConfiguration.current == nil, window == nil,
              !isSleeping, pendingRestoreURL == nil, !hasUnsavedInteraction, !hasSubmittedForm,
              !webView.isLoading, webView.cameraCaptureState == .none,
              webView.microphoneCaptureState == .none,
              let url = webView.url, TabMemory.allowsURL(url),
              !NativeDownloads.shared.snapshot.contains(where: { $0["tab"] as? UInt64 == webviewId }),
              !Self.live.values.contains(where: {
                  $0 !== self && $0.webView.configuration.userContentController === webView.configuration.userContentController
              }) else { return false }
        return true
    }

    /// Release only pages whose current native and document state is safe to reload.
    func sleepIfSafe() async -> Bool {
        guard canSleep else { return false }
        let original = webView
        let url = original.url
        guard await TabMemory.pageIsSafe(original),
              canSleep, webView === original, original.url == url,
              let interaction = original.interactionState else { return false }
        sleepingInteractionState = interaction
        sleepingTitle = original.title
        pendingRestoreURL = currentURLString
        requestedURL = currentURLString
        let configuration = original.configuration
        let zoom = original.pageZoom
        urlObservation = nil; titleObservation = nil; mediaObservations = []
        original.navigationDelegate = nil; original.uiDelegate = nil
        original.stopLoading()
        original.removeFromSuperview()
        webView = WKWebView(frame: bounds, configuration: configuration)
        configureWebView()
        webView.pageZoom = zoom
        return true
    }

    // MARK: Commands

    static func localFileURL(_ input: String) -> URL? {
        let path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") || path.hasPrefix("~/") else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    func load(urlString: String) {
        dismissTabPreview()
        TabPreviewCache.shared.remove(webviewId)
        guard let url = Self.localFileURL(urlString) ?? URL(string: urlString) else { return }
        sleepingInteractionState = nil
        sleepingTitle = nil
        pendingRestoreURL = nil
        requestedURL = url.absoluteString
        if !hasRenderedContent { showLoadingCover() }
        failedNavigationURL = nil
        showCachedFavicon(for: url)
        // file:// needs explicit read access to the containing directory or
        // WebKit sandboxes sibling resources — a local page's <video>, css,
        // and images silently fail to load (bowser-browser-vus). Grant the
        // whole directory so a self-contained local page works like it does
        // in Safari.
        if url.isFileURL {
            // Read access is granted to the file's DIRECTORY, computed from
            // the bare path so a #fragment (reveal.js slide anchors etc.)
            // can't corrupt the directory resolution.
            let dir = URL(fileURLWithPath: url.path).deletingLastPathComponent()
            webView.loadFileURL(url, allowingReadAccessTo: dir)
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    @objc func goBack(_ sender: Any?) { webView.goBack() }
    @objc func goForward(_ sender: Any?) { webView.goForward() }

    /// One zoom step (View menu / ⌘+ ⌘− ⌘0): 0.1 per step, clamped to
    /// 0.5–3.0; direction 0 resets to Actual Size.
    static func steppedZoom(_ current: Double, direction: Int) -> Double {
        guard direction != 0 else { return 1.0 }
        let next = ((current + Double(direction) * 0.1) * 10).rounded() / 10
        return min(max(next, 0.5), 3.0)
    }

    func zoom(direction: Int) {
        webView.pageZoom = Self.steppedZoom(Double(webView.pageZoom), direction: direction)
    }

    /// nil = leave that kind untouched; [] = clear. Applies on reload.
    func applyUserContent(scripts: [ModScript]?, styles: [String]?, reload: Bool) {
        let changed = (scripts != nil && scripts != currentScripts) || (styles != nil && styles != currentStyles)
        if let scripts { currentScripts = scripts }
        if let styles { currentStyles = styles }
        rebuildUserScripts()
        if reload && changed { webView.reload() }
    }

    fileprivate func dispatchModScripts(frame: WKFrameInfo, url: URL) {
        // Verify the WebKit-supplied security origin as well as the request URL.
        let origin = frame.securityOrigin
        guard origin.host.lowercased() == (url.host?.lowercased() ?? ""), origin.protocol == url.scheme else { return }
        for script in currentScripts where script.matches(url) {
            guard let code = ModScript.guardedSource(script.source) else { continue }
            webView.callAsyncJavaScript(code,
                arguments: ["expectedURL": url.absoluteString],
                in: frame, in: script.contentWorld) { _ in }
        }
    }

    static let mediaResumeWindowSeconds = 120
    static let mediaHook = MediaRecovery.script

    private func rebuildUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: TabMemory.editTrackingScript,
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        if SiteAppConfiguration.current != nil {
            controller.addUserScript(WKUserScript(source: SiteAppBadge.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            controller.addUserScript(WKUserScript(source: SiteAppNotifications.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        controller.addUserScript(WKUserScript(
            source: Self.consoleHook,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: Self.mediaHook,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        for css in currentStyles {
            guard let encoded = try? JSONSerialization.data(withJSONObject: [css]),
                  let literal = String(data: encoded, encoding: .utf8)
            else { continue }
            let injector = """
            (function () {
              var s = document.createElement("style");
              s.textContent = \(literal)[0];
              (document.head || document.documentElement).appendChild(s);
            })();
            """
            controller.addUserScript(WKUserScript(
                source: injector, injectionTime: .atDocumentEnd, forMainFrameOnly: true
            ))
        }
        // Only the dispatcher is registered with WebKit. Site source remains
        // native until the loaded frame's origin has been checked.
        controller.addUserScript(WKUserScript(source: ModScript.ready,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: ModScript.dispatchWorld))
        controller.addUserScript(WKUserScript(source: Self.consoleHook,
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: ModScript.isolatedWorld))
    }

    /// ITP partitions third-party iframe cookies, so embedded players
    /// (a YouTube embed on a third-party site) can't see the owner's login and
    /// demand sign-in (bowser-browser-yll). One owner, one machine: switch
    /// tracking prevention off on the shared store. SPI via KVC
    /// (_setResourceLoadStatisticsEnabled:), guarded so an OS that drops it
    /// degrades to a no-op instead of crashing. Returns whether it took.
    @discardableResult
    static func disableTrackingPrevention(on store: WKWebsiteDataStore = .default()) -> Bool {
        guard store.responds(to: NSSelectorFromString("_setResourceLoadStatisticsEnabled:")) else {
            NSLog("Bowser: ITP SPI missing — third-party embeds may demand sign-in")
            return false
        }
        store.setValue(false, forKey: "resourceLoadStatisticsEnabled")
        return true
    }

    /// Popups arrive with the OPENER's configuration — its controller
    /// already has these handlers, and a duplicate add() throws an uncaught
    /// NSException: every target=_blank link click aborted the app
    /// (bowser-browser-pi1). Remove-before-add is idempotent, and PageRelay
    /// attributes by message.webView so a shared controller still credits
    /// the right tab.
    private func registerRelay() {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "bowserEdited", contentWorld: .defaultClient)
        controller.add(pageRelay, contentWorld: .defaultClient, name: "bowserEdited")
        controller.removeScriptMessageHandler(forName: "bowserConsole")
        controller.removeScriptMessageHandler(forName: "bowserEmit")
        controller.removeScriptMessageHandler(forName: "bowserMediaWarm")
        controller.removeScriptMessageHandler(forName: "bowserScriptsReady", contentWorld: ModScript.dispatchWorld)
        controller.removeScriptMessageHandler(forName: "bowserConsole", contentWorld: ModScript.isolatedWorld)
        controller.removeScriptMessageHandler(forName: "bowserEmit", contentWorld: ModScript.isolatedWorld)
        controller.add(pageRelay, name: "bowserConsole")
        controller.add(pageRelay, name: "bowserEmit")
        controller.add(pageRelay, name: "bowserMediaWarm")
        controller.add(pageRelay, contentWorld: ModScript.dispatchWorld, name: "bowserScriptsReady")
        controller.add(pageRelay, contentWorld: ModScript.isolatedWorld, name: "bowserConsole")
        controller.add(pageRelay, contentWorld: ModScript.isolatedWorld, name: "bowserEmit")
        if SiteAppConfiguration.current != nil {
            controller.removeScriptMessageHandler(forName: "bowserBadge", contentWorld: .page)
            controller.addScriptMessageHandler(SiteAppBadge.shared, contentWorld: .page, name: "bowserBadge")
            controller.removeScriptMessageHandler(forName: "bowserNotifications", contentWorld: .page)
            controller.addScriptMessageHandler(SiteAppNotifications.shared, contentWorld: .page, name: "bowserNotifications")
        }
    }

    func tearDown() {
        loadingCover?.removeFromSuperview()
        loadingCover = nil
        dismissTabPreview()
        TabPreviewCache.shared.remove(webviewId)
        stopMediaCapture()
        SiteAppBadge.shared.clear(id: webviewId)
        EngineView.live.removeValue(forKey: webviewId)
        BrainBridge.shared.send([
            "op": "event", "event": "webview_closed", "webview": webviewId,
        ])
        urlObservation = nil
        titleObservation = nil
        mediaObservations = []
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "bowserEdited", contentWorld: .defaultClient)
        controller.removeScriptMessageHandler(forName: "bowserConsole")
        controller.removeScriptMessageHandler(forName: "bowserEmit")
        controller.removeScriptMessageHandler(forName: "bowserMediaWarm")
        controller.removeScriptMessageHandler(forName: "bowserScriptsReady", contentWorld: ModScript.dispatchWorld)
        controller.removeScriptMessageHandler(forName: "bowserConsole", contentWorld: ModScript.isolatedWorld)
        controller.removeScriptMessageHandler(forName: "bowserEmit", contentWorld: ModScript.isolatedWorld)
        // A sibling sharing this controller (popup lineage) must keep
        // receiving page messages after this tab dies.
        EngineView.live.values
            .first(where: { $0.webView.configuration.userContentController === controller })?
            .registerRelay()
    }

    // MARK: WKNavigationDelegate

    /// What a click on a link should do to the tab strip.
    enum TabIntent {
        /// Navigate the tab that was clicked in — the ordinary case.
        case sameTab
        /// Open a new tab, leave the user where they are (⌘+click).
        case backgroundTab
        /// Open a new tab and switch to it (⌘⇧+click).
        case foregroundTab
    }

    /// ⌘+click = new tab behind, ⌘⇧+click = new tab in front — the same
    /// contract every mac browser ships (bowser-browser-0ia). Pure so it can
    /// be tested without an event loop: WebKit hands us these two facts and
    /// nothing else matters. Only a link ACTIVATION counts — ⌘ is also held
    /// for ⌘R and ⌘←, and a reload must never spawn a tab.
    static func linkClickIntent(
        navigationType: WKNavigationType,
        modifierFlags: NSEvent.ModifierFlags
    ) -> TabIntent {
        NavigationPolicy.shared.intent(type: navigationType, modifiers: modifierFlags)
    }

    nonisolated static func shouldOpenExternally(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return !["about", "blob", "data", "file", "http", "https", "javascript"].contains(scheme)
    }

    // A ⌘+click reaches us as an ordinary main-frame navigation: WebKit
    // carries the modifiers but has no opinion about tabs, so without this
    // the link just replaced the page the user meant to keep.
    //
    // The decisionHandler MUST keep its `@MainActor @Sendable` attributes.
    // This is an OPTIONAL protocol requirement, so a signature that doesn't
    // match the SDK's exactly isn't a compile error — it just stops being the
    // witness, gets no @objc thunk, and WebKit's respondsToSelector: check
    // silently skips it. Costed an hour: the method existed, was never called
    // (bowser-browser-0ia).
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if let method = navigationAction.request.httpMethod, !["GET", "HEAD"].contains(method) {
            hasSubmittedForm = true
        }
        if Self.shouldOpenExternally(navigationAction.request.url),
           let url = navigationAction.request.url {
            decisionHandler(.cancel)
            guard navigationAction.sourceFrame.isMainFrame, let window = webView.window else { return }
            let origin = navigationAction.sourceFrame.securityOrigin
            let source = origin.host.isEmpty ? "This page" : origin.host
            externalNavigation.request(url: url, source: source, window: window)
            return
        }
        // `<a download>` and app-scheme links ask WebKit to download rather
        // than navigate (bowser-browser-9ew).
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        let intent = Self.linkClickIntent(
            navigationType: navigationAction.navigationType,
            modifierFlags: navigationAction.modifierFlags
        )
        // targetFrame == nil means WebKit is already on its way to
        // createWebViewWith (target=_blank, window.open) — that path owns the
        // tab, and intercepting here too would open two.
        guard intent != .sameTab,
              navigationAction.targetFrame != nil,
              let url = navigationAction.request.url,
              let host = BrowserWindowController.host(of: webviewId)
                ?? (NSApp.delegate as? AppDelegate)?.currentController
        else {
            if navigationAction.targetFrame?.isMainFrame == true,
               let url = navigationAction.request.url,
               failedNavigationURL == nil || navigationAction.navigationType != .other {
                requestedURL = url.absoluteString
                failedNavigationURL = nil
            }
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        let view = host.openTab(opener: webviewId, activate: intent == .foregroundTab)
        view.load(urlString: url.absoluteString)
    }

    // A response WebKit can't display (a binary, a file with Content-
    // Disposition: attachment) becomes a download instead of a blank page.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse,
           response.statusCode >= 400, response.expectedContentLength == 0,
           let url = response.url {
            decisionHandler(.cancel)
            let detail = response.statusCode == 404
                ? "This page was not found (HTTP 404). The website returned an empty response."
                : "The website returned HTTP \(response.statusCode) with an empty response."
            showLoadFailure(url: url.absoluteString, message: detail)
            return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        NativeDownloads.shared.attach(download, tab: webviewId, profile: profileId)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        NativeDownloads.shared.attach(download, tab: webviewId, profile: profileId)
    }

    static func uniqueDownloadURL(_ suggested: String) -> URL { NativeDownloads.uniqueURL(suggested) }

    // MARK: - File picker (Safari parity)

    /// `<input type="file">` and the "Choose file" button do NOTHING in a
    /// WKWebView until the app runs the open panel itself (like fullscreen,
    /// downloads and AV1 before it — bowser-browser-fry family).
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        // WK_SWIFT_UI_ACTOR in the SDK: the handler MUST be @MainActor
        // @Sendable or this is not the protocol witness — the compiler only
        // says "nearly matches" and WebKit silently never calls it.
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canCreateDirectories = false
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    private var cancelMediaPermission: (() -> Void)?

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        let requested = SitePermissionKey.origin(origin)
        guard cancelMediaPermission == nil, let window,
              SitePermissionKey.validRequest(top: SitePermissionKey.origin(webView.url), request: requested,
                  frame: SitePermissionKey.origin(frame.securityOrigin)), let requested else {
            decisionHandler(.deny); return
        }
        let kinds: [String]
        switch type {
        case .camera: kinds = ["camera"]
        case .microphone: kinds = ["microphone"]
        case .cameraAndMicrophone: kinds = ["camera", "microphone"]
        @unknown default: decisionHandler(.deny); return
        }
        let store = SitePermissionStore.shared
        let decision = store.mediaDecision(profile: profileId, origin: requested, kinds: kinds)
        guard decision == .prompt else { decisionHandler(decision); return }
        let revision = store.revision
        let alert = NativeUIHost.alert("media-permission", ["origin": requested, "devices": kinds.joined(separator: " and ")])
        var resolved = false
        let finish: (WKPermissionDecision) -> Void = { [weak self] value in
            guard !resolved else { return }; resolved = true
            self?.cancelMediaPermission = nil
            decisionHandler(value)
        }
        cancelMediaPermission = { [weak window] in
            finish(.deny)
            if let window { window.endSheet(alert.window, returnCode: .abort) }
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard !resolved else { return }
            guard let self, EngineView.live[self.webviewId] === self, self.window != nil,
                  SitePermissionKey.origin(webView.url) == requested, store.revision == revision else {
                finish(.deny); return
            }
            switch response {
            case .alertFirstButtonReturn: finish(.grant)
            case .alertSecondButtonReturn:
                do { try store.set(profile: self.profileId, origin: requested, kinds: kinds, decision: "allow"); finish(.grant) }
                catch { finish(.deny) }
            case .alertThirdButtonReturn:
                try? store.set(profile: self.profileId, origin: requested, kinds: kinds, decision: "block")
                finish(.deny)
            default: finish(.deny)
            }
        }
    }

    func stopMediaCapture() {
        cancelMediaPermission?()
        webView.setCameraCaptureState(.none, completionHandler: nil)
        webView.setMicrophoneCaptureState(.none, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if !hasRenderedContent { showLoadingCover() }
        if failedNavigationURL == nil, let navigation {
            navigationDiagnosticTrace.start(navigation, now: ProcessInfo.processInfo.systemUptime,
                network: navigationNetwork.snapshot, revision: navigationNetwork.revision)
        }
        cancelMediaPermission?()
        faviconGeneration = UUID()
        iconCandidates = []
        guard failedNavigationURL == nil else { return }
        BrainBridge.shared.send([
            "op": "event", "event": "load_status", "webview": webviewId, "status": 0,
        ])
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if let navigation { navigationDiagnosticTrace.redirect(navigation) }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hasRenderedContent = false
        showLoadingCover()
        hasUnsavedInteraction = false
        SiteAppBadge.shared.clear(id: webviewId)
        didWarmMediaRecovery = false
        // Recheck after redirects; never show the previous origin's icon.
        showCachedFavicon(for: webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        revealPageContent()
        guard failedNavigationURL == nil else {
            BrowserWindowController.host(of: webviewId)?.engineDidPaint(self)
            return
        }
        BrainBridge.shared.send([
            "op": "event", "event": "load_status", "webview": webviewId, "status": 2,
        ])
        // The freeze-frame overlay yields once the on-screen tab has real
        // pixels again (bowser-browser-9qr).
        BrowserWindowController.host(of: webviewId)?.engineDidPaint(self)
        sampleThemeColor()
        captureFavicon()
        SiteAppRuntime.shared.pageFinished(self)
        LearnGuideProgress.shared.replay(to: self)
    }

    // A load that dies before commit used to vanish: the KVO url had already
    // told the brain the new URL, the webview stayed on about:blank, and the
    // session re-persisted a tab that never existed (bowser-browser-p7l).
    // Failures now emit load_status 3 and paint an inline error page whose
    // baseURL is the failed URL — the tab shows what went wrong, and the
    // brain's mirror stays consistent with what's on screen.
    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleLoadFailure(error, navigation: navigation, provisional: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(error, navigation: navigation, provisional: false)
    }

    private func handleLoadFailure(_ error: Error, navigation: WKNavigation?, provisional: Bool) {
        let nsError = error as NSError
        guard Self.shouldShowErrorPage(domain: nsError.domain, code: nsError.code) else { return }
        NavigationDiagnosticLog.record(navigationDiagnosticTrace.failure(navigation, error: nsError,
            stage: provisional ? "before_commit" : "after_commit", now: ProcessInfo.processInfo.systemUptime,
            network: navigationNetwork.snapshot, revision: navigationNetwork.revision))
        dismissTabPreview()
        let failedURL = Self.navigationFailureURL(nsError, requested: requestedURL, current: webView.url?.absoluteString)
        NSLog("Bowser: navigation failed for webview \(webviewId): \(nsError.domain) \(nsError.code)")
        if provisional {
            showLoadFailure(url: failedURL, message: nsError.localizedDescription)
        } else {
            // Preserve the pixels of a page that already committed.
            BrainBridge.shared.send([
                "op": "event", "event": "load_status", "webview": webviewId, "status": 3,
                "url": failedURL, "error": nsError.localizedDescription,
            ])
        }
    }

    static func navigationFailureURL(_ error: NSError, requested: String?, current: String?) -> String {
        let candidates = [error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
                          (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString,
                          requested, current]
        return candidates.compactMap { $0 }.first { !$0.isEmpty && $0 != "about:blank" } ?? ""
    }

    private func showLoadFailure(url: String, message: String) {
        failedNavigationURL = url
        // The synthetic document can report about:blank; retain the actual
        // destination in the address bar, session and both retry entry points.
        if !url.isEmpty {
            onURLChange?(url)
            BrainBridge.shared.send(["op": "event", "event": "url_changed", "webview": webviewId, "url": url])
        }
        BrainBridge.shared.send([
            "op": "event", "event": "load_status", "webview": webviewId, "status": 3,
            "url": url, "error": message,
        ])
        webView.loadHTMLString(Self.errorPageHTML(url: url, message: message), baseURL: URL(string: url))
    }

    /// Cancellation (-999) means a newer load won the race; WebKit 102 means
    /// the navigation became a download or app handoff. Everything else left
    /// the user staring at a blank tab.
    static func shouldShowErrorPage(domain: String, code: Int) -> Bool {
        if domain == NSURLErrorDomain && code == NSURLErrorCancelled { return false }
        if domain == "WebKitErrorDomain" && code == 102 { return false }
        return true
    }

    static func errorPageHTML(url: String, message: String) -> String {
        let safeURL = htmlEscape(url)
        let safeMessage = htmlEscape(message)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
          :root { color-scheme: light dark; }
          body { font: 15px -apple-system, sans-serif; display: flex;
                 min-height: 90vh; align-items: center; justify-content: center; }
          main { max-width: 34em; text-align: center; }
          h1 { font-size: 1.2em; }
          .url { word-break: break-all; opacity: 0.7; }
        </style></head><body><main>
          <h1>This page didn&rsquo;t load</h1>
          <p class="url">\(safeURL)</p>
          <p>\(safeMessage)</p>
          <p><a href="\(safeURL)">Try again</a></p>
        </main></body></html>
        """
    }

    static func htmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Favicon pipeline

    func showCachedFavicon(for url: URL?, root: URL = BowserPaths.home) {
        guard let url, ["http", "https"].contains(url.scheme), url.host != nil else {
            faviconICNSPath = nil
            announceFavicon("")
            return
        }
        let base = root.appendingPathComponent("app-icons-v2/" + TabAppBundle.iconKey(url: url, profile: profileId))
        let png = base.appendingPathExtension("png").path
        let icns = base.appendingPathExtension("icns").path
        faviconICNSPath = FileManager.default.fileExists(atPath: icns) ? icns : nil
        announceFavicon(FileManager.default.fileExists(atPath: png) ? png : "")
    }

    // Use the page's network context first: a separate URLSession can fail
    // even when WebKit loads the icon. Decode SVG, ICO and raster candidates
    // with WebKit, trying the next on failure. No page content is changed.
    nonisolated static let pageFaviconProbe = WebsiteIcon.probe

    func captureFavicon() {
        guard let pageURL = webView.url, pageURL.host != nil else { return }
        let generation = faviconGeneration
        webView.callAsyncJavaScript(Self.pageFaviconProbe, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            guard let self, self.faviconGeneration == generation, self.webView.url == pageURL else { return }
            if case .success(let value) = result, let candidates = value as? [[String: Any]], !candidates.isEmpty {
                self.iconCandidates = candidates
                self.resendIconCandidates()
            }
        }
    }

    func resendIconCandidates() {
        guard let url = webView.url else { return }
        guard !iconCandidates.isEmpty else { captureFavicon(); return }
        faviconGeneration = UUID()
        BrainBridge.shared.send(["op": "event", "event": "icon_candidates", "webview": webviewId,
            "generation": faviconGeneration.uuidString, "url": url.absoluteString, "profile": profileId,
            "candidates": iconCandidates,
            "profile_badge": (Profile.find(profileId).avatar?.image ?? NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil))?.tiffRepresentation?.base64EncodedString() ?? ""])
    }

    var appIconData: Data? {
        faviconICNSPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
    }

    func acceptIcon(_ message: [String: Any]) {
        guard message["generation"] as? String == faviconGeneration.uuidString,
              message["url"] as? String == webView.url?.absoluteString,
              let path = message["path"] as? String, let icns = message["icns"] as? String else { return }
        let cache = BowserPaths.home.appendingPathComponent("favicons/tiles-v2").standardizedFileURL.path + "/"
        guard URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(cache),
              URL(fileURLWithPath: icns).standardizedFileURL.path.hasPrefix(cache) else { return }
        faviconICNSPath = icns
        iconCandidates = [] // Rediscover on reconnect instead of retaining decoded image payloads.
        announceFavicon(path)
        if let config = SiteAppConfiguration.current, let url = webView.url,
           TabAppBundle.iconKey(url: config.url, profile: config.profile) == TabAppBundle.iconKey(url: url, profile: profileId) {
            NSApp.applicationIconImage = NSImage(contentsOfFile: path)
        }
    }

    private func announceFavicon(_ path: String) {
        faviconPath = path
        onFaviconChange?()
        BrainBridge.shared.send([
            "op": "event", "event": "favicon_changed",
            "webview": webviewId, "path": path,
        ])
    }

    // Safari-style chrome tinting: prefer the page's theme-color meta,
    // fall back to its background; normalize via a computed style so any
    // CSS color form comes back as rgb()/rgba().
    private static let themeProbe = """
    (function () {
      // The chrome band sits directly above the page top — match what's
      // actually rendered there: the topmost element's effective background.
      var c = "";
      var el = document.elementFromPoint(window.innerWidth / 2, 2);
      while (el && el !== document.documentElement) {
        var bg = getComputedStyle(el).backgroundColor;
        if (bg && bg !== "rgba(0, 0, 0, 0)" && !/rgba\\(.*, 0\\)$/.test(bg)) { c = bg; break; }
        el = el.parentElement;
      }
      if (!c) {
        var m = document.querySelector('meta[name="theme-color"]');
        c = (m && m.content) || "";
      }
      if (!c) {
        c = getComputedStyle(document.body).backgroundColor;
        if (!c || c === "rgba(0, 0, 0, 0)")
          c = getComputedStyle(document.documentElement).backgroundColor;
      }
      var d = document.createElement("div");
      d.style.color = c;
      document.body.appendChild(d);
      var out = getComputedStyle(d).color;
      d.remove();
      return out;
    })()
    """

    private func sampleThemeColor() {
        webView.evaluateJavaScript(Self.themeProbe) { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.themeColor = Self.parseCSSColor(value as? String)
                self.onThemeColor?(self.themeColor)
            }
        }
    }

    static func parseCSSColor(_ css: String?) -> NSColor? {
        guard let css else { return nil }
        let numbers = css
            .replacingOccurrences(of: "rgba(", with: "")
            .replacingOccurrences(of: "rgb(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count >= 3 else { return nil }
        if numbers.count >= 4, numbers[3] == 0 { return nil }
        return NSColor(
            srgbRed: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255, alpha: 1
        )
    }

    // The chrome/engine split, delivered by WebKit: a page crash kills only
    // Apple's WebContent process. Reload and move on; the window never blinks.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard pendingRestoreURL == nil else { return }
        Task { await Telemetry.shared.record(.crash(.native)) }
        NSLog("Bowser: WebContent process died for webview \(webviewId) — reloading")
        reloadPage()
    }

    // MARK: WKUIDelegate

    // target=_blank / window.open: open a real tab, with opener lineage.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // The popup belongs to the window this page lives in, not to
        // whatever happens to be key.
        guard let host = BrowserWindowController.host(of: webviewId)
            ?? (NSApp.delegate as? AppDelegate)?.currentController
        else { return nil }
        // A plain window.open lands in front, but ⌘+click keeps the same
        // stay-put promise it has on an ordinary link.
        let intent = Self.linkClickIntent(
            navigationType: navigationAction.navigationType,
            modifierFlags: navigationAction.modifierFlags
        )
        let view = host.openTab(
            configuration: configuration, opener: webviewId,
            activate: intent != .backgroundTab
        )
        return view.webView
    }
}
