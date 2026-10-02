import AppKit

/// Ghosts float over website content, whose colors need not match macOS.
/// Opposite-color glyph edges keep them legible without a solid badge.
@MainActor enum ShortcutHintStyle {
    static func apply(to label: NSTextField, appearance: NSAppearance) {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ink = NSColor(calibratedRed: 0.08, green: 0.14, blue: 0.23, alpha: 1)
        let light = NSColor(calibratedRed: 0.95, green: 0.98, blue: 1, alpha: 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        label.attributedStringValue = NSAttributedString(string: label.stringValue, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 17, weight: .bold),
            .foregroundColor: dark ? light : ink,
            .strokeColor: dark ? ink : light,
            .strokeWidth: -3.0,
            .paragraphStyle: paragraph
        ])
        label.layer?.masksToBounds = false
        label.layer?.shadowColor = NSColor(calibratedRed: 0.35, green: 0.7, blue: 1, alpha: 1).cgColor
        label.layer?.shadowOffset = .zero
        label.layer?.shadowRadius = 7
        label.layer?.shadowOpacity = 0.95
    }
}
