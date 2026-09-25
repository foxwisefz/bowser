import AppKit
import ImageIO
import UniformTypeIdentifiers

let source = NSImage(contentsOfFile: CommandLine.arguments[1])!
let directory = URL(fileURLWithPath: CommandLine.arguments[2])
for (size, name) in [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"),
                     (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"),
                     (256, "icon_256x256"), (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x")] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let side = CGFloat(size)
    NSGraphicsContext.current!.cgContext.clear(CGRect(x: 0, y: 0, width: side, height: side))
    source.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    let rect = NSRect(x: side * 0.27, y: side * 0.06, width: side * 0.7, height: side * 0.29)
    NSColor(calibratedRed: 1, green: 0.57, blue: 0.06, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: side * 0.06, yRadius: side * 0.06).fill()
    let style = NSMutableParagraphStyle(); style.alignment = .center
    ("STG" as NSString).draw(in: rect.offsetBy(dx: 0, dy: -side * 0.006), withAttributes: [
        .font: NSFont.systemFont(ofSize: side * 0.235, weight: .black), .foregroundColor: NSColor.black, .paragraphStyle: style
    ])
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
}
