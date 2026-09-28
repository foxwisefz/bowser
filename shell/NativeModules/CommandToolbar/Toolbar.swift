import AppKit
import SwiftUI
import QuartzCore

// ABI 1: bounded UTF-8 JSON snapshots, generation-tagged copied UTF-8 events,
// and one retained NSView pointer. No WebKit references or Swift values cross.
public typealias ToolbarEvent = @convention(c) @Sendable (UInt64, UnsafePointer<CChar>) -> Void
struct ToolbarButton: Decodable, Identifiable { let id: String; let title: String; let symbol: String? }
struct SiteMod: Decodable, Identifiable { let id: String; let title: String; let on: Bool }
struct ToolbarSnapshot: Decodable {
    let siteMods: [SiteMod]?
    let modWidth: Double?
    let permissionsAvailable: Bool?
    let capturing: Bool?
    let revealed: Bool
    let tint: [Double]?
    let colors: [String: String]
    let buttonStyle: String
    let cornerRadius: Double
    let showNavigation: Bool
    let buttons: [ToolbarButton]
}
struct ToolbarTheme {
    var colors: [String: String] = [:]
    var buttonStyle = "flat"
    var cornerRadius: CGFloat = 6
    var showNavigation = false
    func color(_ key: String) -> NSColor? {
        guard let hex = colors[key], hex.count == 7, hex.first == "#", let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255)/255, green: CGFloat((rgb >> 8) & 255)/255, blue: CGFloat(rgb & 255)/255, alpha: 1)
    }
}
@MainActor final class ToolbarModel: ObservableObject {
    var siteMods: [SiteMod] = []
    var modWidth: CGFloat = 135
    var permissionsAvailable = false
    var capturing = false
    @Published var revealed = false
    var theme = ToolbarTheme()
    var tint: NSColor?
    var buttons: [ToolbarButton] = []
    func apply(_ data: Data) -> Bool {
        guard let value = try? JSONDecoder().decode(ToolbarSnapshot.self, from: data),
              value.buttons.count <= 128, (value.siteMods?.count ?? 0) <= 128,
              value.cornerRadius.isFinite,
              (0...12).contains(value.cornerRadius) else { return false }
        objectWillChange.send()
        theme = ToolbarTheme(colors: value.colors, buttonStyle: value.buttonStyle, cornerRadius: value.cornerRadius, showNavigation: value.showNavigation)
        if let c = value.tint, c.count == 4, c.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
            tint = NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
        } else { tint = nil }
        siteMods = value.siteMods ?? []
        modWidth = min(135, max(0, value.modWidth ?? 135))
        permissionsAvailable = value.permissionsAvailable ?? false; capturing = value.capturing ?? false
        buttons = value.buttons; revealed = value.revealed
        return true
    }
}
@MainActor final class ToolbarView: NSHostingView<CommandToolbar> {
    let model: ToolbarModel
    init(model: ToolbarModel, generation: UInt64, event: @escaping ToolbarEvent) {
        self.model = model
        let emit: (String) -> Void = { text in text.withCString { event(generation, $0) } }
        super.init(rootView: CommandToolbar(model: model, openBar: { emit("command") }, goBack: { emit("back") }, goForward: { emit("forward") }, reload: { emit("reload") }, modClick: { emit("mod:" + $0) }, permissions: { emit("permissions") }, onHoverChanged: { emit($0 ? "hover:1" : "hover:0") }))
    }
    required init(rootView: CommandToolbar) { fatalError("use module_create") }
    required init?(coder: NSCoder) { fatalError("use module_create") }
}
@_cdecl("bowser_toolbar_abi") public func toolbarABI() -> Int32 { 1 }
@_cdecl("bowser_toolbar_create") public func toolbarCreate(_ bytes: UnsafePointer<UInt8>, _ count: Int32, _ generation: UInt64, _ event: @escaping ToolbarEvent) -> UnsafeMutableRawPointer? {
    guard count > 0 && count <= 65536 else { return nil }
    let data = Data(bytes: bytes, count: Int(count))
    let address: UInt? = MainActor.assumeIsolated {
        let model = ToolbarModel()
        guard model.apply(data) else { return nil }
        return UInt(bitPattern: Unmanaged.passRetained(ToolbarView(model: model, generation: generation, event: event)).toOpaque())
    }
    return address.flatMap(UnsafeMutableRawPointer.init(bitPattern:))
}
@_cdecl("bowser_toolbar_update") public func toolbarUpdate(_ pointer: UnsafeMutableRawPointer, _ bytes: UnsafePointer<UInt8>, _ count: Int32) -> Int32 {
    guard count > 0 && count <= 65536 else { return 0 }
    let address = UInt(bitPattern: pointer), data = Data(bytes: bytes, count: Int(count))
    return MainActor.assumeIsolated { Unmanaged<ToolbarView>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue().model.apply(data) ? 1 : 0 }
}
@_cdecl("bowser_toolbar_destroy") public func toolbarDestroy(_ pointer: UnsafeMutableRawPointer) {
    let address = UInt(bitPattern: pointer)
    MainActor.assumeIsolated {
        let object = Unmanaged<ToolbarView>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!)
        object.takeUnretainedValue().removeFromSuperview(); object.release()
    }
}
struct CommandToolbar: View {
    @ObservedObject var model: ToolbarModel
    private var theme: ToolbarTheme { model.theme }
    /// The window's profile tint — painted on the ⌘K keycap only (the
    /// owner's call: not the whole bar, not the command palette).
    private var tint: Color? { model.tint.map(Color.init(nsColor:)) }
    let openBar: () -> Void
    let goBack: () -> Void
    let goForward: () -> Void
    let reload: () -> Void
    let modClick: (String) -> Void
    let permissions: () -> Void
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button(action: { ShortcutGhost.show("⌘K"); openBar() }) {
                // Keycap-style badge: outlined, rounded face, like a
                // keyboard shortcut printed on the chrome.
                Text("⌘+K")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .kerning(0.8)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(theme.color("button_foreground").map { AnyShapeStyle(Color(nsColor: $0)) }
                        ?? (tint == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.95))))
                    .frame(width: 50, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .fill(theme.color("button_background").map { Color(nsColor: $0) }
                                  ?? tint ?? Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .strokeBorder(
                                theme.color("accent").map { Color(nsColor: $0) }
                                    ?? Color(red: 0.83, green: 0.65, blue: 0.13).opacity(0.95),
                                lineWidth: 1.2
                            )
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Command bar (⌘K)")
            .accessibilityIdentifier("command")
            Menu {
                if model.siteMods.isEmpty {
                    Text("No mods for this site")
                } else {
                    ForEach(model.siteMods) { mod in
                        Toggle(mod.title, isOn: Binding(
                            get: { mod.on },
                            set: { on in
                                if on != mod.on { modClick("site-mod:" + mod.id) }
                            }
                        ))
                    }
                }
                Divider()
                Button("Show global mods") { modClick("global_mods") }
            } label: {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Mods for this site")
            .accessibilityLabel("Mods for this site")
            // Revealed together with the window lights, same grace/fade.
            Group {
                clusterButton("chevron.left", shortcut: "⌘[", action: goBack)
                    .help("Back (⌘[)")
                clusterButton("chevron.right", shortcut: "⌘]", action: goForward)
                    .help("Forward (⌘])")
                clusterButton("arrow.clockwise", shortcut: "⌘R", action: reload)
                    .help("Reload this tab (⌘R)")
                if model.revealed && !model.buttons.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 7) {
                ForEach(model.buttons, id: \.id) { button in
                    clusterButton(button.symbol ?? "puzzlepiece.extension") {
                        modClick(button.id)
                    }
                    .help(button.title)
                }
                        }
                    }.scrollIndicators(.hidden)
                        .frame(width: min(CGFloat(model.buttons.count) * 27, model.modWidth), height: 22)
                }
            }
            if model.permissionsAvailable && model.capturing {
                Button(action: permissions) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(Color.green)
                        .font(.system(size: 12, weight: .medium)).frame(width: 24, height: 22)
                }.buttonStyle(.plain).help("Camera or microphone in use — website permissions")
                    .accessibilityLabel("Website permissions")
            }
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.15), value: model.revealed)
        .frame(maxHeight: .infinity)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ToolbarWindowDragHandle())
        .onHover { onHoverChanged($0) }
    }

    private func clusterButton(_ symbol: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: {
            if let shortcut { ShortcutGhost.show(shortcut) }
            action()
        }) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.color("button_foreground").map { Color(nsColor: $0) } ?? .secondary)
                .frame(width: 20,
                       height: theme.buttonStyle == "beveled" ? 22 : 20)
                .background {
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .fill(theme.color("button_background").map { Color(nsColor: $0) } ?? .clear)
                }
                .overlay {
                    if theme.buttonStyle == "beveled" {
                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .strokeBorder(LinearGradient(colors: [.white, Color(nsColor: theme.color("border") ?? .darkGray)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


/// A click-only reminder in its own non-interactive panel: toolbar clipping,
/// page navigation and revealing/hiding the controls cannot cut the ghost off.
@MainActor
private enum ShortcutGhost {
    private static weak var current: NSPanel?

    static func show(_ shortcut: String) {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseUp || event.type == .leftMouseDown,
              let owner = event.window else { return }
        if let current {
            current.parent?.removeChildWindow(current)
            current.close()
        }
        let point = owner.convertPoint(toScreen: event.locationInWindow)
        let size = NSSize(width: 66, height: 72)
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height - 6)
        if let screen = owner.screen {
            origin.x = min(max(origin.x, screen.visibleFrame.minX), screen.visibleFrame.maxX - size.width)
            origin.y = max(origin.y, screen.visibleFrame.minY)
        }
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
        panel.appearance = owner.effectiveAppearance
        let canvas = NSView(frame: NSRect(origin: .zero, size: size))
        canvas.wantsLayer = true
        canvas.setAccessibilityElement(false)
        let badge = NSTextField(labelWithString: shortcut)
        badge.alignment = .center
        badge.font = .monospacedSystemFont(ofSize: 17, weight: .medium)
        badge.textColor = .labelColor
        badge.frame = NSRect(x: 4, y: 42, width: 58, height: 26)
        badge.wantsLayer = true
        badge.drawsBackground = false
        badge.isBordered = false
        // Only the glyphs cast the halo; no badge fill, border or shadow box.
        let dark = owner.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        badge.textColor = dark
            ? NSColor(calibratedRed: 0.9, green: 0.97, blue: 1, alpha: 1)
            : NSColor(calibratedRed: 0.14, green: 0.3, blue: 0.58, alpha: 1)
        badge.layer?.masksToBounds = false
        badge.layer?.shadowColor = NSColor(calibratedRed: 0.35, green: 0.7, blue: 1, alpha: 1).cgColor
        badge.layer?.shadowOffset = .zero
        badge.layer?.shadowRadius = 7
        badge.layer?.shadowOpacity = 0.95
        badge.setAccessibilityElement(false)
        canvas.addSubview(badge)
        panel.contentView = canvas
        current = panel
        owner.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)

        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.12, 0.55, 1]
        fade.duration = 1.15
        badge.layer?.opacity = 0
        badge.layer?.add(fade, forKey: "shortcut-fade")
        if !reduced {
            let drift = CABasicAnimation(keyPath: "transform.translation.y")
            drift.fromValue = 0
            drift.toValue = -30
            drift.duration = 1.15
            drift.timingFunction = CAMediaTimingFunction(name: .easeOut)
            badge.layer?.add(drift, forKey: "shortcut-drift")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            panel.parent?.removeChildWindow(panel)
            panel.close()
        }
    }
}
