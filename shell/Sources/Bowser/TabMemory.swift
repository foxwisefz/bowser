import AppKit
import WebKit

/// A conservative working-set limit; protected pages may exceed it.
@MainActor final class TabMemory {
    static let shared = TabMemory()
    private var timer: Timer?
    private var pressure: DispatchSourceMemoryPressure?
    private var sweeping = false

    func start() {
        guard timer == nil, SiteAppConfiguration.current == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in await Self.shared.sweep(underPressure: false) }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            Task { @MainActor in await Self.shared.sweep(underPressure: true) }
        }
        source.resume()
        pressure = source
    }

    func sweep(underPressure: Bool) async {
        guard !sweeping else { return }
        sweeping = true
        defer { sweeping = false }
        let views = EngineView.live.values.filter { !$0.isSleeping && $0.pendingRestoreURL == nil && $0.currentURLString != nil }
        let budget = underPressure ? 4 : 8
        guard views.count > budget else { return }
        let idle: TimeInterval = underPressure ? 120 : 300
        var released = 0
        for view in views.sorted(by: { $0.lastVisibleAt < $1.lastVisibleAt }) {
            guard released < min(2, views.count - budget) else { break }
            if Date().timeIntervalSince(view.lastVisibleAt) >= idle, await view.sleepIfSafe() {
                released += 1
            }
        }
    }

    static func allowsURL(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme), let host = url.host?.lowercased() else { return false }
        // Editors and conferencing apps can hold state outside ordinary form fields.
        let protected = ["docs.google.com", "meet.google.com", "teams.microsoft.com", "zoom.us",
                         "figma.com", "notion.so", "office.com", "office.live.com", "canva.com"]
        return !protected.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static let editTrackingScript = """
    for (const event of ['input', 'change', 'pointerdown', 'keydown']) {
      addEventListener(event, e => {
        if (e.isTrusted) window.webkit.messageHandlers.bowserEdited.postMessage(true);
      }, true);
    }
    """

    static func pageIsSafe(_ view: WKWebView) async -> Bool {
        await withCheckedContinuation { continuation in
            let result = SafetyResult(continuation)
            result.timeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { result.finish(false) }
            }
            view.requestMediaPlaybackState { state in
                guard state == .none, result.pending else { result.finish(false); return }
                view.evaluateJavaScript(safetyProbe, in: nil, in: .defaultClient) { evaluation in
                    if case .success(let value) = evaluation { result.finish(value as? Bool == true) }
                    else { result.finish(false) }
                }
            }
        }
    }

    private final class SafetyResult {
        private var continuation: CheckedContinuation<Bool, Never>?
        var timeout: Task<Void, Never>?
        var pending: Bool { continuation != nil }
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func finish(_ value: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel(); timeout = nil
            continuation.resume(returning: value)
        }
    }

    static let safetyProbe = """
    (() => {
      if (document.readyState !== 'complete') return false;
      if (document.querySelector('iframe,frame,[contenteditable]:not([contenteditable="false"]),audio,video')) return false;
      for (const e of document.querySelectorAll('input,textarea,select')) {
        if (e.files && e.files.length) return false;
        if ('defaultValue' in e && e.value !== e.defaultValue) return false;
        if ('defaultChecked' in e && e.checked !== e.defaultChecked) return false;
        if (e.options && [...e.options].some(o => o.selected !== o.defaultSelected)) return false;
      }
      return true;
    })()
    """
}
