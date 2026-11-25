import AppKit
import ScreenCaptureKit
import XCTest

/// Capture only a fixture window belonging to this test process, including
/// AppKit's composited titlebar and SwiftUI scroll view contents.
@MainActor
func writeWindowPreview(_ window: NSWindow, to url: URL) async throws {
    window.display()
    let content = try await SCShareableContent.currentProcess
    let target = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
    let configuration = SCStreamConfiguration()
    configuration.width = Int(window.frame.width * window.backingScaleFactor)
    configuration.height = Int(window.frame.height * window.backingScaleFactor)
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    let image = try await SCScreenshotManager.captureImage(
        contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
    let bitmap = NSBitmapImageRep(cgImage: image)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
}
