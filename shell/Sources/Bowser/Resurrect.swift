import AppKit
import WebKit

/// The shell snapshots the selected tab after a tab switch to
/// ~/.bowser/resurrect.jpg. A fresh instance can show a recent frame as a
/// full-window overlay from its very first paint, and crossfades to the
/// live page once the restored active tab finishes loading — an engine
/// death looks like a blink, not a blank window.
///
/// Captures are event-driven; normal browsing does not refresh the frame.
/// The freshness check discards stale frames. WKWebView.takeSnapshot is the capture path — unlike
/// CGWindowListCreateImage it needs no screen-recording permission and
/// captures the out-of-process web content reliably.
@MainActor
enum ResurrectFrame {
    static let freshnessSeconds: TimeInterval = 120

    static var fileURL: URL {
        (SiteAppConfiguration.current?.home ?? BowserPaths.home)
            .appendingPathComponent("resurrect.jpg")
    }

    /// Only a RECENT past is worth showing — a frame from hours ago
    /// (manual quit, closed laptop) would flash misleading content.
    static func shouldShow(fileDate: Date?, now: Date = Date()) -> Bool {
        guard let fileDate else { return false }
        return now.timeIntervalSince(fileDate) < freshnessSeconds
    }

    static func loadImage() -> NSImage? {
        let path = fileURL.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              shouldShow(fileDate: attrs[.modificationDate] as? Date)
        else { return nil }
        return NSImage(contentsOfFile: path)
    }

    private static var capturing = false

    /// Snapshot the webview and persist it. TIFF extraction happens in the
    /// completion; JPEG encoding and writing happen on a utility queue.
    static func capture(_ webView: WKWebView, onCapture: (@MainActor @Sendable (Data) -> Void)? = nil) {
        guard !capturing, webView.window != nil else { return }
        capturing = true
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        configuration.snapshotWidth = 1280
        webView.takeSnapshot(with: configuration) { image, _ in
            MainActor.assumeIsolated { capturing = false }
            guard let image, let tiff = image.tiffRepresentation else { return }
            let url = fileURL
            DispatchQueue.global(qos: .utility).async {
                guard let rep = NSBitmapImageRep(data: tiff),
                      let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
                else { return }
                try? jpeg.write(to: url, options: .atomic)
                Task { @MainActor in onCapture?(jpeg) }
            }
        }
    }
}

/// The overlay itself: swallows its first click (dismissing) so the user
/// can't interact with a frame of the past.
final class ResurrectOverlayView: NSImageView {
    var onDismiss: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }
}
