import AppKit
import SwiftUI
import WebKit
import BowserSurfaceKit

struct BrowserScreenRoot: View {
    @ObservedObject var context: BrowserScreenContext
    var body: some View {
        switch context.kind {
        case "external-profile": ExternalProfileScreen(context: context)
        case "permissions": PermissionsScreen(context: context)
        case "settings": SettingsScreen(context: context)
        case "profiles": ProfilesScreen(context: context)
        case "modsmith": ModSmithScreen(context: context)
        case "onboarding": OnboardingScreen(context: context)
        default: EmptyView()
        }
    }
}

struct OnboardingScreen: View {
    @ObservedObject var context: BrowserScreenContext
    private var model: any OnboardingPresentation { context.model as! any OnboardingPresentation }
    private let mint = Color(red: 0.65, green: 0.97, blue: 0.79)

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    Image(nsImage: NSImage(named: "BowserWelcome") ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Bowser")!)
                        .resizable().frame(width: 46, height: 46)
                    Text("Bowser").font(.system(size: 23, weight: .bold, design: .rounded))
                }
                Spacer(minLength: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your web.").foregroundStyle(.white)
                    Text("Your rules.").foregroundStyle(mint)
                }.font(.system(size: 49, weight: .semibold, design: .rounded)).tracking(-2)
                Text("The browser that builds itself.")
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                Text("Describe what you want.\nBowser makes it happen.")
                    .font(.system(size: 16)).lineSpacing(5).foregroundStyle(.white.opacity(0.65))
                Spacer(minLength: 24)
                HStack(spacing: 8) {
                    Image(systemName: "sparkle")
                    Text("MADE FOR YOUR MAC. MADE TO BE YOURS.")
                        .font(.system(size: 10, weight: .semibold)).tracking(1)
                }.foregroundStyle(mint.opacity(0.85))
            }.padding(.vertical, 44).padding(.leading, 38).padding(.trailing, 24)
                .frame(width: 394, alignment: .leading)
            VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 22) {
                if model.step != .invitation && model.step != .thanks {
                HStack {
                    Text(model.step == .thanks ? "YOU’RE ON THE LIST" : "YOUR BOWSER STARTS HERE")
                        .font(.system(size: 11, weight: .semibold)).tracking(1.6).foregroundStyle(mint)
                    Spacer()
                    Text(model.step == .email ? "01" : model.step == .invitation ? "02" : "03")
                        .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                }
                }
                if model.completed {
                    title("You’re in.", detail: "A browser that feels like you starts with your first idea.")
                    primary("Open Bowser", enabled: true, action: model.finish)
                } else {
                    stepContent
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.system(size: 13)).foregroundStyle(Color(red: 1, green: 0.72, blue: 0.65))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(28).frame(width: 394, alignment: .leading)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.1)))
            if model.step == .thanks && !model.completed { earlyAccessNote }
            }
            .padding(.trailing, 36)
        }
        .frame(width: 860, height: 600)
        .foregroundStyle(.white)
        .background {
            ZStack {
                Color(red: 0.035, green: 0.065, blue: 0.075)
                RadialGradient(colors: [mint.opacity(0.16), .clear], center: .topLeading, startRadius: 10, endRadius: 580)
                RadialGradient(colors: [Color.cyan.opacity(0.07), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 460)
            }.ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: context.binding("showTerms", default: false)) {
            OnboardingTermsSheet(url: model.termsURL)
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch model.step {
        case .email:
            title("Make yourself\nat home.", detail: "Start with your email. We’re letting people in a few at a time.")
            WelcomeInput(label: "Email address", placeholder: "you@example.com",
                         text: Binding(get: { model.email }, set: { model.email = $0 }),
                         enabled: !model.submitting, initiallyFocused: true, submit: model.continueWithEmail)
            primary("Let’s go", enabled: model.canContinue, action: model.continueWithEmail)
        case .invitation:
            title("Got an invite?", detail: nil)
            emailSummary
            primary("I have an invite", enabled: !model.submitting, action: model.enterInvite)
            Button { Task { await model.joinWaitlist() } } label: {
                HStack { Text(model.submitting ? "Saving your place…" : "Request an invite"); Spacer(); Image(systemName: "arrow.up.right") }
                    .font(.system(size: 15, weight: .medium)).padding(.vertical, 8)
            }.buttonStyle(.plain).disabled(!model.canJoinWaitlist)
            Button("Restore existing access") { Task { await model.requestRecovery() } }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).disabled(model.submitting)
        case .code:
            title("Your invite.\nYour way in.", detail: nil)
            emailSummary
            WelcomeInput(label: "Invite code", placeholder: "Paste your code",
                         text: Binding(get: { model.inviteCode }, set: { model.inviteCode = $0 }),
                         enabled: !model.submitting, initiallyFocused: true) { Task { await model.submit() } }
            HStack(spacing: 4) {
                Toggle("I agree to the", isOn: Binding(get: { model.acceptedTerms }, set: { model.acceptedTerms = $0 }))
                    .toggleStyle(.checkbox).disabled(model.submitting)
                Button("Terms of Service") { context.binding("showTerms", default: false).wrappedValue = true }
                    .buttonStyle(.link).tint(mint)
            }.font(.system(size: 13))
            if let status = model.setupMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(status).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                    Button("Check again") { Task { await model.refreshSetup() } }.buttonStyle(.link).tint(mint).disabled(model.submitting)
                }
            }
            primary("Open my Bowser", enabled: model.canSubmit) { Task { await model.submit() } }
            Button("Back", action: model.backToInvitation).buttonStyle(.plain).foregroundStyle(.white.opacity(0.65)).disabled(model.submitting)
        case .recovery:
            title("Check your inbox.", detail: "Enter the 8-digit code we sent to verify your email and restore access.")
            emailSummary
            WelcomeInput(label: "Verification code", placeholder: "8-digit code",
                         text: Binding(get: { model.recoveryCode }, set: { model.recoveryCode = $0 }),
                         enabled: !model.submitting, initiallyFocused: true) { Task { await model.verifyRecovery() } }
            primary("Restore my Bowser", enabled: model.canVerify) { Task { await model.verifyRecovery() } }
            Button("Send another code") { Task { await model.requestRecovery() } }.buttonStyle(.plain).foregroundStyle(mint).disabled(model.submitting)
            Button("Back", action: model.backToInvitation).buttonStyle(.plain).foregroundStyle(.white.opacity(0.65)).disabled(model.submitting)
        case .thanks:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 30, weight: .light)).foregroundStyle(mint)
            title("You’re on the list.", detail: nil)
            VStack(alignment: .leading, spacing: 6) {
                Text("We’ll send your invite to")
                    .foregroundStyle(.white.opacity(0.7))
                Text(model.email).fontWeight(.medium).textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle)
            }.font(.system(size: 15))
            HStack(spacing: 20) {
                Button("Use invite code", action: model.enterInvite)
                Button("Change email", action: model.editEmail)
            }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
        }
    }

    private var earlyAccessNote: some View {
        HStack(spacing: 14) {
            Image(systemName: "bubble.left").font(.system(size: 18)).foregroundStyle(mint)
            VStack(alignment: .leading, spacing: 5) {
                Text("Want in sooner?").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                Link(destination: URL(string: "https://x.com/tealtoronto")!) {
                    HStack(spacing: 6) {
                        Text("Say hi to @tealtoronto")
                        Image(systemName: "arrow.up.right")
                    }.font(.system(size: 13, weight: .medium)).foregroundStyle(mint)
                }
            }
            Spacer(minLength: 0)
        }.padding(18).frame(width: 394, alignment: .leading)
            .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.07)))
    }

    private var emailSummary: some View {
        HStack(spacing: 8) {
            Text(model.email).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Edit", action: model.editEmail).buttonStyle(.plain).foregroundStyle(mint).disabled(model.submitting)
        }.font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
    }
    private func title(_ heading: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(heading).font(.system(size: 32, weight: .semibold, design: .rounded)).tracking(-1).fixedSize(horizontal: false, vertical: true)
            if let detail { Text(detail).font(.system(size: 15)).lineSpacing(4).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func primary(_ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(model.submitting ? "One moment…" : label)
                Spacer()
                if model.submitting { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.right") }
            }.font(.system(size: 15, weight: .semibold)).padding(.horizontal, 18).frame(height: 48)
                .foregroundStyle(Color(red: 0.035, green: 0.1, blue: 0.09))
                .background(mint.opacity(enabled ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).disabled(!enabled).keyboardShortcut(.defaultAction)
    }
}

private struct WelcomeInput: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let enabled: Bool
    var initiallyFocused = false
    let submit: () -> Void
    @State private var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.callout.weight(.medium))
            WelcomeTextInput(text: $text, focused: $focused, enabled: enabled,
                             placeholder: placeholder, label: label,
                             initiallyFocused: initiallyFocused, submit: submit)
                .frame(height: 20)
                .padding(.horizontal, 14).frame(height: 46)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(focused ? Color(red: 0.65, green: 0.97, blue: 0.79) : Color.white.opacity(0.18),
                                      lineWidth: focused ? 2 : 1)
                }
                .accessibilityLabel(label)
        }
    }
}

/// Give AppKit the initial responder before the window opens, without waiting
/// for a later SwiftUI focus update or the asynchronous setup response.
struct WelcomeTextInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let enabled: Bool
    let placeholder: String
    let label: String
    let initiallyFocused: Bool
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WelcomeEmailTextField {
        let field = WelcomeEmailTextField()
        field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.placeholderString = placeholder
        field.setAccessibilityLabel(label)
        field.needsInitialFocus = initiallyFocused
        field.delegate = context.coordinator
        field.stringValue = text; field.isEnabled = enabled
        return field
    }
    func updateNSView(_ field: WelcomeEmailTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = enabled
        if field.stringValue != text, field.currentEditor() == nil { field.stringValue = text }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: WelcomeTextInput
        init(_ parent: WelcomeTextInput) { self.parent = parent }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) { parent.submit(); return true }
            return false
        }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func controlTextDidBeginEditing(_ notification: Notification) { setFocused(true) }
        func controlTextDidEndEditing(_ notification: Notification) { setFocused(false) }
        private func setFocused(_ value: Bool) {
            // Only the decorative outline is deferred; AppKit owns the caret now.
            DispatchQueue.main.async { [weak self] in self?.parent.focused = value }
        }
    }
}

final class WelcomeEmailTextField: NSTextField {
    var needsInitialFocus = true
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        guard needsInitialFocus, let window else { return }
        window.initialFirstResponder = self
        NotificationCenter.default.addObserver(self, selector: #selector(focusWhenReady),
            name: NSWindow.didBecomeKeyNotification, object: window)
        focusWhenReady()
    }
    @objc private func focusWhenReady() {
        guard needsInitialFocus, isEnabled, let window, window.isKeyWindow else { return }
        window.makeFirstResponder(self)
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { needsInitialFocus = false }
        return accepted
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}

struct OnboardingTermsSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var failed = false
    @State private var loading = true
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Terms of Service").font(.headline)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if failed {
                VStack(spacing: 12) {
                    Text("Couldn’t load the Terms. Check your connection and try again.")
                    Button("Try again") { failed = false; loading = true; attempt += 1 }
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                OnboardingTermsWebView(url: url, failed: $failed, loading: $loading).id(attempt)
            }
        }.frame(width: 510, height: 480)
    }
}

struct OnboardingTermsWebView: NSViewRepresentable {
    let url: URL
    @Binding var failed: Bool
    @Binding var loading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let owner: OnboardingTermsWebView
        init(_ owner: OnboardingTermsWebView) { self.owner = owner }
        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) { owner.loading = false }
        func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail() }
        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail() }
        private func fail() { owner.loading = false; owner.failed = true }
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let destination = action.request.url,
                  destination.scheme == owner.url.scheme,
                  destination.host == owner.url.host,
                  destination.port == owner.url.port else { decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
        func webView(_ view: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
            if let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
                fail(); decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
    }
}

struct ModScopeCards: View {
    @ObservedObject var choice: ModScopeChoice
    var compact = false
    var onChoose: () -> Void = {}
    var body: some View {
        HStack(spacing: 12) {
            card("site", title: "This website", detail: choice.host ?? "Open a website first", icon: "globe", tint: .blue)
            card("browser", title: "Across Bowser", detail: "Browser-wide customization", icon: "macwindow", tint: .purple)
        }
    }
    private func card(_ scope: String, title: String, detail: String, icon: String, tint: Color) -> some View {
        let selected = choice.selected == scope
        return Button { choice.choose(scope); onChoose() } label: {
            VStack(alignment: .leading, spacing: compact ? 5 : 9) {
                HStack {
                    if scope == "site", let path = choice.faviconPath, let favicon = ImageCache.load(path) {
                        Image(nsImage: favicon).resizable().scaledToFit()
                            .frame(width: compact ? 18 : 24, height: compact ? 18 : 24)
                    } else {
                        Image(systemName: icon).font(.system(size: compact ? 16 : 22)).foregroundStyle(tint)
                    }
                    Spacer()
                    if choice.suggested == scope { Text("Suggested").font(.system(size: 9, weight: .medium)).foregroundStyle(tint) }
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? tint : Color.secondary.opacity(0.35))
                }
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail + (compact && scope == "site" && choice.host != nil ? " · includes subdomains" : "")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if !compact && scope == "site" { Text("Includes subdomains").font(.system(size: 10)).foregroundStyle(.secondary) }
                if !compact && scope == "browser" { Text("Across websites and browser UI").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            .padding(compact ? 12 : 16).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(selected ? 0.10 : 0.025), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? tint.opacity(0.6) : Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
            .disabled(scope == "site" && choice.host == nil)
            .accessibilityLabel("\(title), \(detail)\(scope == "site" ? ", includes subdomains" : "")")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct ModSmithScreen: View {
    @ObservedObject var context: BrowserScreenContext
    private var model: any ModSmithPresentation { context.model as! any ModSmithPresentation }
    @FocusState private var composerFocused: Bool
    @State private var deletingProject: String?
    private var showDetails: Bool {
        get { context.binding("showDetails", default: false).wrappedValue }
        nonmutating set { context.binding("showDetails", default: false).wrappedValue = newValue }
    }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                conversation
                activeBuild
                composer
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [Color.purple.opacity(0.045), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .alert("Delete this mod?", isPresented: Binding(
            get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } }
        )) {
            Button("Delete mod", role: .destructive) {
                if let id = deletingProject { model.action("delete", project: id, path: nil) }
                deletingProject = nil
            }
            Button("Cancel", role: .cancel) { deletingProject = nil }
        } message: {
            Text("This removes the mod’s files and all its ModSmith conversation and undo history. This can’t be undone. Website actions and saved mod data stay as they are.")
        }
        .onChange(of: model.draft) { _, text in
            if model.project == nil && !model.isSiteApp { model.scopeChoice.update(text) }
        }
        .onAppear {
            if context.values["hasAppeared"] as? Bool != true { composerFocused = true; context.values["hasAppeared"] = true }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("ModSmith", systemImage: "sparkles")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12).padding(.top, 8)
            if let profile = model.snapshot.workspace_profile {
                profileIdentity(profile, caption: "Profile")
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            } else if model.isSiteApp {
                Label("This app", systemImage: "app").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
            Button { model.action("new"); composerFocused = true } label: {
                Label("New mod", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.bordered).controlSize(.large)
            Text("MODS & HISTORY").font(.system(size: 10, weight: .semibold))
                .tracking(0.8).foregroundStyle(.secondary).padding(.horizontal, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(model.snapshot.projects) { project in
                        Button {
                            model.action("select", project: project.id)
                            composerFocused = true
                        } label: {
                            HStack(alignment: .top, spacing: 9) {
                                modIcon(project.favicon, fallback: project.scope == "browser" ? "macwindow" : "globe", size: 20)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(project.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    Text(project.files.isEmpty && project.status != "working" ? "Draft · saved chat" : project.statusLabel)
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.snapshot.selected == project.id ? Color.accentColor.opacity(0.13) : .clear,
                                            in: RoundedRectangle(cornerRadius: 9))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(model.snapshot.selected == project.id ? [.isSelected] : [])
                    }
                    ForEach((model.snapshot.available_mods ?? []).filter { mod in
                        !model.snapshot.projects.contains { $0.files.contains(mod.path) }
                    }) { mod in
                        Button {
                            model.action("edit_existing", path: mod.path)
                            composerFocused = true
                        } label: {
                            HStack(alignment: .top, spacing: 9) {
                                modIcon(mod.favicon, fallback: mod.scope == "Across Bowser" ? "macwindow" : "globe", size: 20)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(mod.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    Text("Open mod chat").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if model.snapshot.projects.isEmpty && (model.snapshot.available_mods ?? []).isEmpty {
                        Text("Your mods and saved conversations will appear here.")
                            .font(.callout).foregroundStyle(.secondary).padding(12)
                    }
                }
            }
            Text("One mod. One conversation.").font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 12)
        }.padding(12).frame(width: 210).frame(maxHeight: .infinity)
            .background(Color.primary.opacity(0.025))
    }

    @ViewBuilder private func modIcon(_ path: String?, fallback: String, size: CGFloat = 24) -> some View {
        if let path, let image = ImageCache.load(path) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: fallback).frame(width: size, height: size)
                .foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }

    private func profileIdentity(_ profile: ModSmithProfile, caption: String) -> some View {
        HStack(spacing: 8) {
            Group {
                if let character = profile.character {
                    SurfaceServices.shared.portrait(character, 26)
                } else if let icon = profile.icon {
                    Text(icon).font(.system(size: 22))
                } else {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 24)).foregroundStyle(.secondary)
                }
            }.frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(profile.name).font(.caption.weight(.semibold)).lineLimit(1)
            }
        }.accessibilityElement(children: .combine).help("\(caption): \(profile.name)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let project = model.project {
                Text(project.name).font(.system(size: 24, weight: .semibold, design: .rounded)).lineLimit(2)
            }
            if let project = model.project {
                HStack {
                    HStack(spacing: 6) {
                        modIcon(project.favicon, fallback: project.scope == "browser" ? "macwindow" : "globe", size: 16)
                        Text(project.scopeLabel)
                    }.font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(project.statusLabel).font(.caption.weight(.medium))
                }
                HStack {
                    Button("Delete mod", systemImage: "trash", role: .destructive) {
                        deletingProject = project.id
                    }.help("Delete this mod and its ModSmith history")
                    if project.canUndo {
                        Button("Undo last change", systemImage: "arrow.uturn.backward") { model.action("undo") }
                            .help("Restore mod files before: \(project.undoLabel ?? "last change"). Website actions and stored mod data are not reversed.")
                    }
                    if !project.files.isEmpty {
                        Spacer()
                        Toggle(project.enabled ? "Enabled" : "Disabled", isOn: Binding(
                            get: { project.enabled },
                            set: { if $0 != project.enabled { model.action("toggle") } }
                        )).toggleStyle(.switch).fixedSize()
                            .accessibilityIdentifier("modsmith-enabled")
                    }
                }.controlSize(.small).disabled(model.snapshot.busy)
                if project.canUndo {
                    Text("Undo restores mod files. Website actions and saved mod data stay as they are.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else if model.isSiteApp {
                Label("Only this app", systemImage: "app").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("What would you change?")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("Make a little change. Make it yours.").font(.callout).foregroundStyle(.secondary)
                    ModScopeCards(choice: model.scopeChoice)
                }

            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resultAnchor: String {
        guard let project = model.project else { return "bottom" }
        if project.needsNextStep { return "required-input" }
        if project.canEnableAndTest { return "next-action" }
        return project.status == "active" ? "completion" : "bottom"
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let project = model.project {
                        if project.needsNextStep {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(project.nextStep?.title ?? "The next step needs clarification")
                                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                                Text(project.nextStep?.detail ?? "This result didn’t record what you need to provide or do. Ask ModSmith to explain before proceeding.")
                                    .font(.callout).foregroundStyle(.secondary)
                                if let step = project.nextStep {
                                    if step.action == "reply" {
                                        if let options = step.options {
                                            ForEach(options) { option in
                                                Button {
                                                    model.action("answer", project: project.id, path: option.id)
                                                } label: {
                                                    HStack(spacing: 12) {
                                                        VStack(alignment: .leading, spacing: 4) {
                                                            Text(option.label).font(.callout.weight(.semibold))
                                                            Text(option.description).font(.caption).foregroundStyle(.secondary)
                                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                                    }.padding(12).contentShape(Rectangle())
                                                }.buttonStyle(.plain)
                                                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                                                    .disabled(model.snapshot.busy)
                                            }
                                        }
                                        Button(step.options == nil ? "Reply" : "Answer another way", systemImage: "text.bubble") { composerFocused = true }
                                            .buttonStyle(.bordered).disabled(model.snapshot.busy)
                                    } else if step.action == "resume" {
                                        Button("I’ve done this — resume", systemImage: "play.fill") { model.action("continue", project: project.id) }
                                            .buttonStyle(.borderedProminent).disabled(model.snapshot.busy)
                                    }
                                } else {
                                    Button("Clarify next step", systemImage: "questionmark.bubble") { model.action("clarify", project: project.id) }
                                        .buttonStyle(.borderedProminent).disabled(model.snapshot.busy)
                                }
                            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                                .id("required-input")
                        }
                        if let notice = project.repairNotice, !notice.isEmpty {
                            Label(notice, systemImage: "exclamationmark.shield")
                                .font(.callout).foregroundStyle(.orange)
                                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if project.canEnableAndTest && project.nextStep?.options == nil {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Enable your mod to test it", systemImage: "power")
                                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                                Text("Your mod is saved but switched off. Enable it so ModSmith can check how it works and fix any remaining issues.")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Enable & test", systemImage: "play.fill") {
                                    model.action("enable_and_test", project: project.id)
                                }.buttonStyle(.borderedProminent).disabled(model.snapshot.busy)
                                    .accessibilityIdentifier("modsmith-enable-and-test")
                            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                                .id("next-action")
                        }
                        if project.turns.isEmpty {
                            Text("What would you like to change about this mod?").font(.headline)
                            Text("Describe the next change below. Your existing files will be refined in place.").foregroundStyle(.secondary)
                        }
                        if project.status == "active" && project.enabled && !project.files.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(spacing: 12) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 32)).foregroundStyle(.green)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Your mod is ready").font(.system(size: 20, weight: .semibold, design: .rounded))
                                        Text(project.enabled ? "Enabled · \(project.scopeLabel)" : "Disabled · Turn it on above to try it")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                HStack(spacing: 12) {
                                    Button("Try it", systemImage: "arrow.up.right") { model.action("try") }
                                        .buttonStyle(.borderedProminent)
                                    Button("Make changes", systemImage: "square.and.pencil") { composerFocused = true }
                                    Spacer()
                                }.controlSize(.regular)
                            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.green.opacity(0.2)))
                                .id("completion")
                        }
                        if !project.files.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("How to use", systemImage: "book")
                                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                                if let guide = project.usage {
                                    Text(guide.entryPoint).font(.headline)
                                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                                        HStack(alignment: .top, spacing: 10) {
                                            Text("\(index + 1).").foregroundStyle(.secondary)
                                            Text(step).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    if !guide.tips.isEmpty { Text(guide.tips).font(.callout).foregroundStyle(.secondary) }
                                    Button("Update instructions", systemImage: "arrow.clockwise") { model.action("document") }
                                        .disabled(model.snapshot.busy)
                                } else {
                                    Text("Get a guide to this mod’s controls and how to use them.").foregroundStyle(.secondary)
                                    Button("Generate instructions", systemImage: "book") { model.action("document") }
                                        .buttonStyle(.borderedProminent).disabled(model.snapshot.busy)
                                }
                                Divider()
                                Text("Turn this mod on or off using Enabled above or Settings → Mods. To change it, describe what you want below. Select this mod in the sidebar to return to its guide and chat history.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
                                .textSelection(.enabled)
                        }
                        ForEach(project.turns) { turn in turnView(turn) }
                        if project.status == "interrupted" || project.status == "restored" {
                            Text(project.summary).font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("START WITH AN IDEA").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                            ForEach(["Hide distractions and leave only the main content", "Make this page easier to read"], id: \.self) { example in
                                Button { model.draft = example; composerFocused = true } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "sparkles").foregroundStyle(.purple)
                                        Text(example).font(.system(size: 13))
                                        Spacer()
                                        Image(systemName: "arrow.up.left").foregroundStyle(.secondary)
                                    }.padding(14).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(.plain)
                            }
                        }.padding(.vertical, 8)
                    }
                    if !model.snapshot.progress.isEmpty && model.project?.status == "working" {
                        DisclosureGroup("Activity details", isExpanded: context.binding("showDetails", default: false)) {
                            Text(model.snapshot.progress.joined(separator: "\n"))
                                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.project?.turns.count) { _, _ in
                proxy.scrollTo(resultAnchor, anchor: resultAnchor == "bottom" ? .bottom : .top)
            }
            .onChange(of: model.project?.status) { _, status in
                if resultAnchor != "bottom" { proxy.scrollTo(resultAnchor, anchor: .top) }
            }
            .onChange(of: model.snapshot.selected) { _, _ in
                proxy.scrollTo(resultAnchor, anchor: resultAnchor == "bottom" ? .bottom : .top)
            }
        }
    }

    private func turnView(_ turn: ModSmithTurn) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(turn.role == "user" ? "You" : turn.role == "system" ? "Revision history" : turn.role == "activity" ? "Activity" : "ModSmith")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(turn.displayText).font(.system(size: 13)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let notes = turn.notes, !notes.isEmpty {
                DisclosureGroup("Details and limitations") {
                    Text(notes).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            if let checks = turn.checks, turn.status != "failed", turn.status != "interrupted" {
                if checks.isEmpty {
                    Text("No verification reported.").font(.caption).foregroundStyle(.secondary)
                } else {
                    DisclosureGroup("Verification details") {
                        ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                            Text(check).font(.caption).foregroundStyle(.secondary)
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(turn.role == "user" ? Color.accentColor.opacity(0.07) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var activeBuild: some View {
        if model.snapshot.busy {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.snapshot.projects.first(where: { $0.status == "working" })?.name ?? "A build is running")
                        .font(.caption.weight(.semibold)).lineLimit(1)
                    Text(model.snapshot.stage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let profile = model.snapshot.running_profile {
                    profileIdentity(profile, caption: "Running in")
                }
                if let running = model.snapshot.projects.first(where: { $0.status == "working" }) {
                    if running.id != model.snapshot.selected {
                        Button("View") { model.action("select", project: running.id) }
                    }
                }
            }.controlSize(.small).padding(.horizontal, 18).padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.07))
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.connectionError ?? model.snapshot.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            TextField(model.project == nil ? "Describe what you want to change…" : "What should we change next?", text: Binding(get: { model.draft }, set: { model.draft = $0 }), axis: .vertical)
                .textFieldStyle(.plain).lineLimit(3...6).focused($composerFocused)
                .padding(13).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            HStack {
                Text(model.snapshot.busy ? "You can draft the next change." : "⌘ Return to send")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let project = model.project {
                    if !model.snapshot.busy && project.canContinue && !project.canEnableAndTest && !project.needsNextStep {
                        Button("Resume testing & fixes") { model.action("continue", project: project.id) }
                            .accessibilityIdentifier("modsmith-continue")
                    }
                }
                if model.snapshot.busy {
                    Button("Stop build", systemImage: "stop.fill", role: .destructive) {
                        model.action("cancel", project: model.snapshot.running_project ?? model.snapshot.projects.first(where: { $0.status == "working" })?.id)
                    }
                    .buttonStyle(.borderedProminent).tint(.red).fixedSize()
                    .disabled(!model.snapshot.canStop)
                    .help(model.snapshot.canStop ? "Stop generation, verification and repairs" : "A build is running in another app window. Stop it there.")
                    .accessibilityIdentifier("modsmith-stop-build")
                } else {
                    Button(model.project == nil ? "Create mod" : "Make changes", systemImage: "arrow.up") { model.submit() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.padding(18).background(.bar)
    }
}

struct SettingsScreen: View {
    @ObservedObject var context: BrowserScreenContext
    private var model: any SettingsPresentation { context.model as! any SettingsPresentation }

    var body: some View {
        Group {
            if model.selected == "websites" {
                PermissionsScreen(context: model.permissionsContext)
            } else if model.selected == "profiles" {
                ProfilesScreen(context: model.profilesContext)
            } else if let section = model.sections.first(where: { $0.id == model.selected }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if section.id == "settings" {
                            DefaultBrowserScreen(context: model.defaultContext)
                            SearchEngineSettings()
                        }
                        SurfaceTreeView(surfaceId: section.id, node: section.tree)
                            .id(section.id)
                    }
                    .padding(32)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            } else {
                ProgressView("Loading settings…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DefaultBrowserScreen: View {
    @ObservedObject var context: BrowserScreenContext
    private var model: any DefaultBrowserPresentation { context.model as! any DefaultBrowserPresentation }

    var body: some View {
        GroupBox("Default Browser") {
            HStack(spacing: 16) {
                Text(model.statusText)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isSetting {
                    ProgressView()
                        .controlSize(.small)
                } else if !model.isDefault {
                    Button("Set as Default Browser") { model.setDefault() }
                        .disabled(!model.canSetDefault)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
struct ProfilesScreen: View {
    @ObservedObject var context: BrowserScreenContext
    private var model: any ProfilesPresentation { context.model as! any ProfilesPresentation }
    @State private var confirmRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Keep your browsing separate.").font(.system(size: 15, weight: .semibold))
                Text("Each profile has its own windows, website logins, and site data.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                profileList
                Divider()
                if model.selectedDisplay != nil {
                    detail
                } else {
                    Text("Select a profile").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .padding(28)
        .sheet(isPresented: Binding(get: { model.isPresentingCreate }, set: { model.isPresentingCreate = $0 })) { NewProfileSheet(context: context) }
        .alert("Remove “\(model.selectedDisplay?.name ?? "profile")”?", isPresented: $confirmRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Profile", role: .destructive) { model.remove() }
        } message: {
            Text("Its saved website data will remain on this Mac. Any open windows will stay open until you close them.")
        }
    }

    private var profileList: some View {
        VStack(spacing: 0) {
            List(selection: Binding<String?>(get: { model.selectedID }, set: { id in
                guard let id, id != model.selectedID, model.confirmDiscardChanges() else { return }
                model.select(id)
            })) {
                ForEach(model.displayProfiles, id: \.id) { profile in
                    HStack(spacing: 10) {
                        ProfileIdentity(draft: profile.draft, size: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            if profile.id == "default" {
                                Text("Default").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .tag(profile.id)
                }
            }
            .listStyle(.inset)
            .disabled(model.isBusy)
            Divider()
            HStack(spacing: 0) {
                Button {
                    if model.confirmDiscardChanges() { model.clearError(); model.isPresentingCreate = true }
                } label: { Image(systemName: "plus").frame(width: 32, height: 26) }
                .help("Add profile").accessibilityLabel("Add profile")
                Divider().frame(height: 16)
                Button { confirmRemoval = true } label: { Image(systemName: "minus").frame(width: 32, height: 26) }
                    .disabled(model.selectedID == "default" || model.isBusy)
                    .help("Remove profile").accessibilityLabel("Remove profile")
                Spacer()
                Text("\(model.displayProfiles.count) \(model.displayProfiles.count == 1 ? "profile" : "profiles")")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.trailing, 8)
            }
            .buttonStyle(.borderless)
            .disabled(model.isBusy)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 190)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                ProfileIdentity(draft: model.draft, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.draft.trimmedName.isEmpty ? "Untitled profile" : model.draft.trimmedName)
                        .font(.system(size: 20, weight: .semibold)).lineLimit(1)
                    Text(model.selectedID == "default" ? "Your default browsing profile" : "A separate browsing profile")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Divider()
            ProfileSettingsFields(draft: Binding(get: { model.draft }, set: { model.draft = $0 }))
                .disabled(model.isBusy)
            Text("The character and color identify this profile’s windows. You can change them anytime.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let error = model.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            } else if let notice = model.notice {
                Text(notice).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                Button("Open Window") {
                    model.openWindow()
                }
                .disabled(model.isBusy)
                Spacer()
                if model.hasChanges {
                    Button("Revert") { model.revert() }.disabled(model.isBusy)
                }
                Button(model.isBusy ? "Saving…" : "Save Changes") { model.save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSave)
            }
            .controlSize(.regular)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ProfileIdentity: View {
    let draft: ProfileDraft
    let size: CGFloat
    var body: some View {
        Group {
            if let character = draft.character { SurfaceServices.shared.portrait(character.rawValue, size) }
            else if let emoji = draft.icon { Text(emoji).font(.system(size: size * 0.7)) }
            else { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary).frame(width: size, height: size) }
        }.frame(width: size, height: size)
    }
}

struct ProfileSettingsFields: View {
    @Binding var draft: ProfileDraft
    @State private var showCharacters = false
    private let colors = ["#e5484d", "#f76b15", "#d6a424", "#30a46c", "#12a594", "#3e63dd", "#8e4ec6", "#d6409f"]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 22) {
            GridRow {
                Text("Name:").gridColumnAlignment(.trailing)
                TextField("Profile name", text: $draft.name).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Profile name")
            }
            GridRow {
                Text("Character:")
                Button { showCharacters = true } label: {
                    HStack(spacing: 8) {
                        ProfileIdentity(draft: draft, size: 32)
                        Text(draft.character?.title ?? "Choose a character")
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }.padding(.vertical, 3).padding(.horizontal, 5)
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $showCharacters, arrowEdge: .bottom) {
                    NativeProfileCharacterChooser(selected: draft.character) { character in
                        draft.character = character
                        draft.icon = nil
                        showCharacters = false
                    }
                }
            }
            GridRow {
                Text("Color:")
                HStack(spacing: 7) {
                    ForEach(colors, id: \.self) { hex in
                        Button { draft.tint = hex } label: {
                            Circle().fill(Color(nsColor: screenColor(hex: hex)!))
                                .frame(width: 20, height: 20)
                                .overlay {
                                    if draft.tint == hex {
                                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                    }
                                }
                        }.buttonStyle(.plain)
                            .accessibilityLabel(colorName(hex))
                            .accessibilityValue(draft.tint == hex ? "Selected" : "Not selected")
                            .help(colorName(hex))
                    }
                    Divider().frame(height: 20)
                    ColorPicker("Custom color", selection: Binding(get: {
                        Color(nsColor: screenColor(hex: draft.tint) ?? .systemGray)
                    }, set: { draft.tint = SurfaceColorPickerHexBridge.hex(NSColor($0)) }), supportsOpacity: false)
                    .labelsHidden().fixedSize().help("Custom color")
                }
            }
        }
        .font(.system(size: 13))
    }

    private func colorName(_ hex: String) -> String {
        ["#e5484d": "Red", "#f76b15": "Orange", "#d6a424": "Yellow", "#30a46c": "Green",
         "#12a594": "Teal", "#3e63dd": "Blue", "#8e4ec6": "Purple", "#d6409f": "Pink"][hex] ?? "Color"
    }
}

struct NativeProfileCharacterChooser: View {
    let selected: ProfileCharacter?
    let choose: (ProfileCharacter) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a character").font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(68), spacing: 6), count: 6), spacing: 8) {
                ForEach(ProfileCharacter.allCases) { character in
                    Button { choose(character) } label: {
                        VStack(spacing: 4) {
                            SurfaceServices.shared.portrait(character.rawValue, 40)
                            Text(character.title).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(width: 68, height: 66)
                        .background(selected == character ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected == character ? Color.accentColor : .clear, lineWidth: 2))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(character.title)
                        .accessibilityValue(selected == character ? "Selected" : "Not selected")
                }
            }
        }.padding(18)
            .onAppear { SurfaceServices.shared.presentations += 1 }
            .onDisappear { SurfaceServices.shared.presentations = max(0, SurfaceServices.shared.presentations - 1) }
    }
}

struct NewProfileSheet: View {
    @ObservedObject var context: BrowserScreenContext
    private var model: any ProfilesPresentation { context.model as! any ProfilesPresentation }
    private var draft: ProfileDraft {
        get { context.binding("newProfileDraft", default: ProfileDraft.newProfile).wrappedValue }
        nonmutating set { context.binding("newProfileDraft", default: ProfileDraft.newProfile).wrappedValue = newValue }
    }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 16) {
                ProfileIdentity(draft: draft, size: 56)
                VStack(alignment: .leading, spacing: 7) {
                    Text("New Profile").font(.system(size: 20, weight: .semibold))
                    Text("Start fresh with separate website logins and site data. Your new profile opens in its own window.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            ProfileSettingsFields(draft: context.binding("newProfileDraft", default: ProfileDraft.newProfile)).disabled(model.isBusy)
            if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { model.clearError(); dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(model.isBusy)
                Button(model.isBusy ? "Creating…" : "Create Profile") { model.create(draft) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(draft.trimmedName.isEmpty || model.isBusy)
            }
        }
        .padding(28)
        .frame(width: 550)
        .interactiveDismissDisabled(model.isBusy)
    }
}

private func screenColor(hex: String?) -> NSColor? {
    guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
}

struct PermissionsScreen: View {
    @ObservedObject var context: BrowserScreenContext
    private var model: any PermissionsPresentation { context.model as! any PermissionsPresentation }
    @State private var confirmReset = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Website Permissions").font(.title2.weight(.semibold))
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.profiles, id: \.id) { profile in
                        PermissionProfileTab(profile: profile, selected: model.selectedProfile == profile.id) {
                            model.selectedProfile = profile.id
                        }
                    }
                }.padding(3)
            }
            .scrollIndicators(.automatic)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Profiles")
            HSplitView {
                List(selection: Binding(get: { model.selectedOrigin }, set: { model.selectedOrigin = $0 })) {
                    ForEach(model.sites, id: \.self) { Text($0).lineLimit(2).tag($0) }
                }.frame(minWidth: 190, idealWidth: 240)
                VStack(alignment: .leading, spacing: 18) {
                    if let origin = model.selectedOrigin {
                        Text(origin).font(.headline).textSelection(.enabled)
                        ForEach(model.controls) { control in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Label(control.title, systemImage: control.id == "camera" ? "video" : control.id == "microphone" ? "mic" : "bell")
                                    Spacer()
                                    Picker(control.title, selection: Binding(get: { control.choice }, set: { model.set(control.id, choice: $0) })) {
                                        Text("Ask").tag("ask"); Text("Allow").tag("allow"); Text("Block").tag("block")
                                    }.labelsHidden().frame(width: 110).disabled(!control.available)
                                }
                                Text(control.status).font(.caption).foregroundStyle(.secondary)
                                if control.active {
                                    HStack {
                                        Label("In use", systemImage: "circle.fill").foregroundStyle(.green)
                                        Button("Stop") { model.stop(control.id) }
                                    }.font(.caption)
                                }
                            }
                            Divider()
                        }
                        Button("Reset This Site to Ask") { model.resetSite() }
                    } else {
                        ContentUnavailableView("No permission exceptions", systemImage: "globe", description: Text("Sites appear here when you save an Allow or Block decision."))
                    }
                    Spacer(minLength: 0)
                }.padding(18).frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            HStack {
                if let error = model.error { Text(error).foregroundStyle(.red) }
                Spacer()
                Button("Reset All in This Profile…") { confirmReset = true }
            }
        }.padding(24)
        .alert("Reset this profile’s website permissions?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { model.resetProfile() }
        } message: { Text("Sites will ask again. Camera and microphone capture in this profile will stop.") }
    }
}

private struct PermissionProfileTab: View {
    let profile: SurfaceProfile
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false
    private var tint: Color { Color(nsColor: screenColor(hex: profile.tint) ?? .controlAccentColor) }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Group {
                    if let avatar = profile.avatar {
                        SurfaceServices.shared.portrait(avatar, 24)
                    } else if let icon = profile.icon {
                        Text(icon).font(.system(size: 21))
                    } else {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 22)).foregroundStyle(tint)
                    }
                }.frame(width: 24, height: 24)
                Text(profile.name).font(.system(size: 13, weight: selected ? .semibold : .medium)).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(selected ? tint.opacity(0.16) : Color.primary.opacity(hovering ? 0.07 : 0.03), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? tint.opacity(0.65) : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(profile.name) profile")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help("Website permissions for \(profile.name)")
    }
}

private struct SearchEngineSettings: View {
    @AppStorage("searchEngine") private var selection = "google"
    var body: some View {
        GroupBox("Search") {
            Picker("Default search engine", selection: $selection) {
                ForEach(SearchEngine.allCases, id: \.rawValue) { engine in
                    Text(engine.title).tag(engine.rawValue)
                }
            }.padding(.vertical, 6)
            Text("Used when you search from the command bar.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}


struct ExternalProfileScreen: View {
    @ObservedObject var context: BrowserScreenContext
    @FocusState private var keyboardFocused: Bool
    private var selectedID: String? {
        get {
            let saved = context.values["selectedProfile"] as? String
            return model.choices.contains(where: { $0.id == saved }) ? saved : model.choices.first?.id
        }
        nonmutating set { context.values["selectedProfile"] = newValue }
    }
    private func move(_ delta: Int) {
        selectedID = Self.movedSelection(selectedID, by: delta, ids: model.choices.map(\.id))
    }
    static func movedSelection(_ selected: String?, by delta: Int, ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        let index = ids.firstIndex(where: { $0 == selected }) ?? 0
        return ids[(index + delta % ids.count + ids.count) % ids.count]
    }
    private var model: any ExternalProfilePresentation { context.model as! any ExternalProfilePresentation }
    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("Where to?")
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                    Text(model.destination).lineLimit(1).truncationMode(.middle)
                    if model.linkCount > 1 { Text("+\(model.linkCount - 1)").fixedSize() }
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.primary.opacity(0.045), in: Capsule())
                .help(model.destination)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(Array(model.choices.enumerated()), id: \.element.id) { index, profile in
                            choice(profile, index: index).id(profile.id)
                        }
                    }.padding(5)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: CGFloat(max(1, (model.choices.count + 1) / 2)) * 160 - 2)
                .onChange(of: selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack(spacing: 5) {
                Text("← →")
                Text("Choose")
                Text("·").padding(.horizontal, 2)
                Text("↵ Open")
                Spacer()
                Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .help("Cancel (Esc)")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 5)
        }.padding(24).padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [Color.accentColor.opacity(0.045), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .focusable().focusEffectDisabled().focused($keyboardFocused)
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) {
            guard let selectedID else { return .ignored }
            model.choose(selectedID)
            return .handled
        }
        .onAppear { keyboardFocused = true }
    }

    @ViewBuilder private func choice(_ profile: ProfileDisplay, index: Int) -> some View {
        let tint = Color(nsColor: screenColor(hex: profile.draft.tint) ?? .controlAccentColor)
        let button = Button { model.choose(profile.id) } label: {
            VStack(spacing: 10) {
                ProfileIdentity(draft: profile.draft, size: 52)
                    .frame(width: 64, height: 64)
                    .background(tint.opacity(0.12), in: Circle())
                Text(profile.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    .frame(maxWidth: .infinity)
                Text(index < 9 ? "⌘\(index + 1)" : "Open")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).frame(height: 148)
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(ProfileChoiceStyle(selected: selectedID == profile.id, tint: tint))
            .accessibilityLabel("Open in \(profile.name)")
            .accessibilityAddTraits(selectedID == profile.id ? [.isSelected] : [])
        if index < 9 { button.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command) }
        else { button }
    }
}

private struct ProfileChoiceStyle: ButtonStyle {
    var selected = false
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        ProfileChoiceBody(configuration: configuration, selected: selected, tint: tint)
    }
    private struct ProfileChoiceBody: View {
        let configuration: Configuration
        let selected: Bool
        let tint: Color
        @State private var hovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            configuration.label
                .foregroundStyle(.primary)
                .background {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color(nsColor: .controlBackgroundColor))
                    RoundedRectangle(cornerRadius: 18)
                        .fill(LinearGradient(colors: [tint.opacity(selected ? 0.14 : 0.04), tint.opacity(selected ? 0.04 : 0.01)], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(selected ? tint.opacity(0.65) : Color.primary.opacity(hovered ? 0.18 : 0.08), lineWidth: selected ? 1.5 : 1))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "arrow.up.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? tint : Color.secondary.opacity(0.5))
                        .padding(12)
                }
                .shadow(color: tint.opacity(selected ? 0.1 : 0), radius: 4, y: 2)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .offset(y: hovered && !configuration.isPressed ? -2 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
                .onHover { hovered = $0 }
        }
    }
}
