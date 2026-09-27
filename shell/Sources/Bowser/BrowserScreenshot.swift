import AppKit
import WebKit

/// Captures only views owned by Bowser; never requests desktop recording access.
@MainActor
enum BrowserScreenshot {
    static func page(_ webView: WKWebView, maxWidth: Int = 1280) async throws -> [String: Any] {
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { throw failure("Page has no drawable viewport") }
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.snapshotWidth = NSNumber(value: min(max(320, maxWidth), 1920))
        let image = try await webView.takeSnapshot(configuration: config)
        return try encode(image, size: webView.bounds.size, maxWidth: maxWidth,
                          metadata: ["target": "page", "coordinates": "Viewport points from top-left", "capture": "webkit"])
    }

    private static func encode(_ image: NSImage, size: NSSize, maxWidth: Int, metadata: [String: Any]) throws -> [String: Any] {
        let scale = min(1, CGFloat(min(max(320, maxWidth), 1920)) / max(size.width, size.height))
        let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw failure("Cannot allocate screenshot")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count <= 4_000_000 else {
            throw failure("Screenshot is too large; request a smaller max_width")
        }
        return metadata.merging(["image": png.base64EncodedString(), "mimeType": "image/png",
            "width": width, "height": height, "point_width": Double(size.width), "point_height": Double(size.height),
            "scale": Double(scale)], uniquingKeysWith: { _, new in new })
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Bowser.Screenshot", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
