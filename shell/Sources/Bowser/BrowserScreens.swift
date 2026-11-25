import AppKit
import SwiftUI
import WebKit
import BowserSurfaceKit

struct ModSmithTurnCard: View {
    let turn: ModSmithTurn
    var assistantName = "ModSmith"
    @State var detailsExpanded = false
    private var notes: String { (turn.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(turn.role == "user" ? "You" : turn.role == "system" ? "Revision history" : turn.role == "activity" ? "Activity" : assistantName)
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let outcome = turn.outcomeLabel {
                    Text(outcome).font(.caption.weight(.medium))
                        .foregroundStyle(turn.status == "active" ? Color.green : Color.secondary)
                }
            }
            Text(turn.displayText).font(.system(size: 13)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let pause = turn.pauseExplanation {
                Text(pause).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !notes.isEmpty || !turn.reportedChecks.isEmpty {
                DisclosureGroup("Supporting details", isExpanded: $detailsExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        if !notes.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Notes and limitations").font(.caption.weight(.semibold))
                                Text(notes).font(.callout).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if !turn.reportedChecks.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Checks reported").font(.caption.weight(.semibold))
                                ForEach(Array(turn.reportedChecks.enumerated()), id: \.offset) { _, check in
                                    HStack(alignment: .top, spacing: 7) {
                                        Text("•")
                                        Text(check).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.font(.caption)
                                }
                            }
                        }
                    }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(turn.role == "user" ? Color.accentColor.opacity(0.07) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}

struct BrowserScreenRoot: View {
    @ObservedObject var context: BrowserScreenContext
    var body: some View {
        switch context.kind {
        case "external-profile": ExternalProfileScreen(context: context)
        case "permissions": PermissionsScreen(context: context)
        case "settings": SettingsScreen(context: context)
        case "history": HistoryScreen(context: context)
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
    @Environment(\.colorScheme) private var appearance

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 660
            HStack(spacing: 0) {
                if wide {
                    brand
                        .padding(28)
                        .frame(width: min(276, geometry.size.width * 0.35))
                        .frame(maxHeight: .infinity)
                        .background(brandBackground)
                    Divider()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: wide ? 20 : 14) {
                        if !wide {
                            HStack(spacing: 10) {
                                artwork.frame(width: 38, height: 38)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Bowser").font(.headline)
                                    Text("The browser that builds itself.").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            Divider()
                        }
                        if model.completed {
                            heading("You’re ready to browse")
                            primary("Open Bowser", enabled: true, action: model.finish)
                        } else {
                            stepContent
                            if let error = model.error {
                                Label(error, systemImage: "exclamationmark.circle")
                                    .font(.callout).foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if model.submitting {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(activity.wrappedValue).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 360, alignment: .leading)
                    .padding(.horizontal, wide ? 36 : 28)
                    .padding(.top, 36).padding(.bottom, 24)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: context.binding("showTerms", default: false)) {
            OnboardingTermsSheet(url: model.termsURL)
        }
    }

    private var artwork: some View {
        Group {
            if let image = NSImage(named: "BowserWelcome") {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }

    private var brand: some View {
        VStack(spacing: 0) {
            artwork.frame(width: 152, height: 152).padding(.bottom, 14)
            Text("Bowser").font(.system(size: 36, weight: .semibold, design: .rounded)).tracking(-1)
            Text("The browser that builds itself.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.top, 6)
        }
    }

    private var brandBackground: some View {
        let green = Color(red: 0.26, green: 0.55, blue: 0.44)
        return ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [green.opacity(appearance == .dark ? 0.23 : 0.14), green.opacity(0.02)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch model.step {
        case .email:
            heading("Get started", detail: "Enter your email to use an invite, request one, or restore access.")
            WelcomeInput(label: "Email address", placeholder: "you@example.com",
                         text: Binding(get: { model.email }, set: { model.email = $0 }),
                         enabled: !model.submitting, initiallyFocused: true, submit: model.continueWithEmail)
            primary("Continue", enabled: model.canContinue, action: model.continueWithEmail)
        case .invitation:
            heading("Your invitation")
            emailSummary
            VStack(spacing: 8) {
                primary("Enter invite code", enabled: !model.submitting, action: model.enterInvite)
                Button {
                    perform("Requesting your invite…") { await model.joinWaitlist() }
                } label: {
                    Text("Request an invite").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).controlSize(.large).disabled(!model.canJoinWaitlist)
            }
            Button("Restore existing access") {
                perform("Sending a verification code…") { await model.requestRecovery() }
            }.buttonStyle(.link).disabled(model.submitting)
        case .code:
            heading("Enter your invite code")
            emailSummary
            WelcomeInput(label: "Invite code", placeholder: "Paste your code",
                         text: Binding(get: { model.inviteCode }, set: { model.inviteCode = $0 }),
                         enabled: !model.submitting, initiallyFocused: true, submit: activate)
            HStack(spacing: 4) {
                Toggle("I agree to the", isOn: Binding(get: { model.acceptedTerms }, set: { model.acceptedTerms = $0 }))
                    .toggleStyle(.checkbox).disabled(model.submitting)
                    .accessibilityLabel("I agree to the Terms of Service")
                Button("Terms of Service") { context.binding("showTerms", default: false).wrappedValue = true }
                    .buttonStyle(.link)
            }
            if let status = model.setupMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Check again") { Task { await model.refreshSetup() } }.buttonStyle(.link).disabled(model.submitting)
                }
            }
            primary("Activate Bowser", enabled: model.canSubmit, action: activate)
            back
        case .recovery:
            heading("Check your inbox", detail: "Enter the 8-digit verification code we sent to this address.")
            emailSummary
            WelcomeInput(label: "Verification code", placeholder: "8-digit code",
                         text: Binding(get: { model.recoveryCode }, set: { model.recoveryCode = $0 }),
                         enabled: !model.submitting, initiallyFocused: true, submit: restore)
            primary("Restore access", enabled: model.canVerify, action: restore)
            HStack {
                back
                Spacer()
                Button("Send another code") {
                    perform("Sending a verification code…") { await model.requestRecovery() }
                }.buttonStyle(.link).disabled(model.submitting)
            }
        case .thanks:
            heading("You’re on the waitlist")
            VStack(alignment: .leading, spacing: 4) {
                Text("We’ll send your invite to").foregroundStyle(.secondary)
                Text(model.email).fontWeight(.medium).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            }
            primary("Use an invite code", enabled: true, action: model.enterInvite)
            Button("Change email", action: model.editEmail).buttonStyle(.link)
            Divider()
            Link("Want in sooner? Say hi to @tealtoronto ↗", destination: URL(string: "https://x.com/tealtoronto")!)
                .font(.callout)
        }
    }

    private var activity: Binding<String> { context.binding("welcomeActivity", default: "Working…") }

    private func perform(_ status: String, operation: @escaping @MainActor () async -> Void) {
        guard !model.submitting else { return }
        activity.wrappedValue = status
        Task { await operation() }
    }

    private func activate() {
        guard model.canSubmit else { return }
        perform("Activating Bowser…") { await model.submit() }
    }

    private func restore() {
        guard model.canVerify else { return }
        perform("Restoring access…") { await model.verifyRecovery() }
    }

    private var back: some View {
        Button(action: model.backToInvitation) { Label("Back", systemImage: "chevron.left") }
            .buttonStyle(.link).disabled(model.submitting)
    }

    private var emailSummary: some View {
        HStack(spacing: 8) {
            Image(systemName: "envelope").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(model.email).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 4)
            Button("Edit", action: model.editEmail).buttonStyle(.link).disabled(model.submitting)
                .accessibilityLabel("Edit email address")
        }
    }

    private func heading(_ title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 26, weight: .semibold)).tracking(-0.5)
                .accessibilityAddTraits(.isHeader)
            if let detail { Text(detail).font(.body).foregroundStyle(.secondary).lineSpacing(2) }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func primary(_ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!enabled)
        .keyboardShortcut(.defaultAction)
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
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.callout.weight(.medium))
            WelcomeTextInput(text: $text, focused: $focused, enabled: enabled,
                             placeholder: placeholder, label: label,
                             initiallyFocused: initiallyFocused, submit: submit)
                .frame(height: 20)
                .padding(.horizontal, 10).frame(height: 36)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(focused ? Color.accentColor : Color(nsColor: contrast == .increased ? .secondaryLabelColor : .separatorColor),
                                      lineWidth: focused ? 2 : 1)
                        .allowsHitTesting(false)
                }
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
    @ObservedObject private var profileServices = SurfaceServices.shared
    @State private var deletingPath: String?
    private var query: Binding<String> { context.binding("modsSearch", default: "") }
    private var filter: Binding<String> { context.binding("modsFilter", default: "all") }
    private var historyKind: Binding<String> { context.binding("requestHistoryKind", default: "task") }
    private var deletingTask: Bool { model.snapshot.projects.first(where: { $0.id == deletingProject })?.isTask == true }
    private var runningProject: ModSmithProject? {
        model.snapshot.projects.first(where: { $0.id == model.snapshot.running_project })
            ?? model.snapshot.projects.first(where: { $0.status == "working" })
    }
    private var listedProjects: [ModSmithProject] {
        model.snapshot.projects.filter { ($0.isTask ? "task" : "mod") == historyKind.wrappedValue && matches($0.name, scope: $0.scope, url: $0.url) }
    }
    private var guideBinding: Binding<Bool> { Binding(get: { model.instructionsOpen }, set: { model.instructionsOpen = $0 }) }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 0) {
                    header
                    Divider()
                    HSplitView {
                        buildContent.frame(minWidth: 540)
                        if geometry.size.width >= 1000 && model.instructionsOpen && model.project != nil {
                            usagePanel.frame(minWidth: 280, idealWidth: 330, maxWidth: 440)
                        }
                    }
                }
                .opacity(model.workspacePage == "overview" ? 0 : 1)
                .allowsHitTesting(model.workspacePage != "overview")
                .disabled(model.workspacePage == "overview")
                .accessibilityHidden(model.workspacePage == "overview")
                if model.workspacePage == "overview" { overview }
            }
            .sheet(isPresented: Binding(get: { geometry.size.width < 1000 && model.instructionsOpen && model.workspacePage != "overview" }, set: { if !$0 { model.instructionsOpen = false } })) {
                usagePanel.frame(width: 480, height: 540)
            }
        }
        .background {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [Color.purple.opacity(0.045), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .alert(deletingTask ? "Delete this task history?" : "Delete this mod?", isPresented: Binding(
            get: { deletingProject != nil || deletingPath != nil }, set: { if !$0 { deletingProject = nil; deletingPath = nil } }
        )) {
            Button(deletingTask ? "Delete history" : "Delete mod", role: .destructive) {
                if let id = deletingProject { model.action("delete", project: id, path: nil) }
                if let path = deletingPath { model.action("delete_existing", path: path) }
                deletingProject = nil; deletingPath = nil
            }
            Button("Cancel", role: .cancel) { deletingProject = nil; deletingPath = nil }
        } message: {
            Text(deletingTask ? "This removes the saved task conversation. Exported files and website actions stay as they are." : "This removes the mod’s files and all its ModSmith conversation and undo history. This can’t be undone. Website actions and saved mod data stay as they are.")
        }
        .onChange(of: historyKind.wrappedValue) { _, _ in filter.wrappedValue = "all" }
        .onChange(of: model.draft) { _, text in
            if model.project == nil && !model.isSiteApp { model.scopeChoice.update(text) }
        }
        .onAppear {
            if context.values["hasAppeared"] as? Bool != true { composerFocused = model.workspacePage != "overview"; context.values["hasAppeared"] = true }
        }
    }

    private var buildContent: some View {
        VStack(spacing: 0) { conversation; activeBuild; composer }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func matches(_ name: String, scope: String, url: String) -> Bool {
        let search = query.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard search.isEmpty || (name + " " + url).localizedCaseInsensitiveContains(search) else { return false }
        if filter.wrappedValue == "browser" { return scope == "browser" }
        if filter.wrappedValue == "site" {
            guard scope != "browser", let host = URL(string: model.targetURL)?.host,
                  let expected = URL(string: url)?.host else { return false }
            return host == expected || host.hasSuffix("." + expected)
        }
        return true
    }

    private var remainingMods: [ModSmithExisting] { historyKind.wrappedValue == "mod" ? model.snapshot.unrepresentedMods : [] }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Tasks & Mods").font(.largeTitle.weight(.semibold))
                Spacer()
                if !model.isSiteApp {
                    Menu {
                        ForEach(profileServices.profiles, id: \.id) { profile in
                            Button(profile.name) { model.action("profile", path: profile.id) }
                        }
                    } label: { Text(model.snapshot.workspace_profile?.name ?? "Profile") }
                }
                Button("New request", systemImage: "plus") {
                    model.instructionsOpen = false; model.action("new"); composerFocused = true
                }.buttonStyle(.borderedProminent)
            }
            HStack {
                Picker("History", selection: historyKind) {
                    Text("Tasks").tag("task")
                    Text("Mods").tag("mod")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                TextField(historyKind.wrappedValue == "task" ? "Search tasks" : "Search mods", text: query).textFieldStyle(.roundedBorder)
                if !model.isSiteApp {
                    Picker("Show", selection: filter) {
                        Text("All").tag("all")
                        Text("This website").tag("site")
                        if historyKind.wrappedValue == "mod" { Text("Across Bowser").tag("browser") }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: historyKind.wrappedValue == "task" ? 230 : 350)
                }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(listedProjects) { project in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                modIcon(project.favicon, fallback: project.scope == "browser" ? "macwindow" : "globe", size: 28)
                                Button { openHistory(project.id) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(project.name).font(.headline).lineLimit(2)
                                        Text("\(project.scopeLabel) · \(project.statusLabel)").font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                if !project.files.isEmpty { enabledControl(project) }
                                projectMenu(project)
                            }
                            HStack(spacing: 18) {
                                Button(project.isTask ? "View result" : "Build history") { openHistory(project.id) }
                                if !project.files.isEmpty { Button("How to use") { openHistory(project.id, guide: true) } }
                            }.buttonStyle(.link).padding(.leading, 40)
                        }.padding(.vertical, 18)
                        Divider()
                    }
                    ForEach(remainingMods.filter { matches($0.name, scope: $0.scope == "Across Bowser" ? "browser" : "site", url: "https://" + $0.scope) }) { mod in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                modIcon(mod.favicon, fallback: mod.scope == "Across Bowser" ? "macwindow" : "globe", size: 28)
                                Button { openExisting(mod.path) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(mod.name).font(.headline)
                                        Text("\(mod.scope) · Not yet verified").font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                Toggle(mod.enabled ? "On" : "Off", isOn: Binding(get: { mod.enabled }, set: { if $0 != mod.enabled { model.action("toggle_existing", path: mod.path) } }))
                                    .toggleStyle(.switch).fixedSize().disabled(model.snapshot.busy)
                                Menu {
                                    if !model.isSiteApp && profileServices.profiles.count > 1 {
                                        Menu("Copy to profile") {
                                            ForEach(profileServices.profiles.filter { $0.id != model.snapshot.workspace_profile?.id }, id: \.id) { profile in
                                                Button(profile.name) { model.action("copy_existing", project: mod.path, path: profile.id) }
                                            }
                                        }
                                    }
                                    Button("Delete mod…", role: .destructive) { deletingPath = mod.path }
                                } label: { Image(systemName: "ellipsis") }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24).disabled(model.snapshot.busy)
                            }
                            HStack(spacing: 18) {
                                Button("Build history") { openExisting(mod.path) }
                                Button("How to use") { openExisting(mod.path, guide: true) }
                            }.buttonStyle(.link).padding(.leading, 40)
                        }.padding(.vertical, 18)
                        Divider()
                    }
                    if listedProjects.isEmpty && remainingMods.isEmpty {
                        ContentUnavailableView(historyKind.wrappedValue == "task" ? "Do something with this page" : "Make Bowser yours", systemImage: "sparkles", description: Text(historyKind.wrappedValue == "task" ? "Run a task once. Its results and saved files will be here." : "Create a mod to change how a website or your browser works."))
                    } else if listedProjects.isEmpty && remainingMods.filter({ matches($0.name, scope: $0.scope == "Across Bowser" ? "browser" : "site", url: "https://" + $0.scope) }).isEmpty {
                        ContentUnavailableView("No matching results", systemImage: "magnifyingglass", description: Text("Try a different search or filter."))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = model.snapshot.error ?? model.connectionError { Text(error).foregroundStyle(.red) }
            if let notice = model.snapshot.notice { Text(notice).foregroundStyle(.secondary) }
            if model.snapshot.canStop { activeBuild }
        }.padding(28).background(Color(nsColor: .windowBackgroundColor))
    }

    private func openHistory(_ id: String, guide: Bool = false) {
        model.instructionsOpen = guide
        model.action("select", project: id)
    }
    private func openExisting(_ path: String, guide: Bool = false) {
        model.instructionsOpen = guide
        model.action("edit_existing", path: path)
    }
    private func enabledControl(_ project: ModSmithProject) -> some View {
        Toggle(project.enabled ? "On" : "Off", isOn: Binding(get: { project.enabled }, set: { if $0 != project.enabled { model.action("toggle", project: project.id) } }))
            .toggleStyle(.switch).fixedSize().disabled(model.snapshot.busy).accessibilityLabel("Enable \(project.name)")
    }
    private func projectMenu(_ project: ModSmithProject) -> some View {
        Menu {
            if project.isTask {
                Button("Run again on current page") { model.action("run_again", project: project.id) }
                Button("Make reusable…") { model.action("make_reusable", project: project.id) }
            }
            if !project.isTask && !model.isSiteApp && profileServices.profiles.count > 1 {
                Menu("Copy to profile") {
                    ForEach(profileServices.profiles.filter { $0.id != model.snapshot.workspace_profile?.id }, id: \.id) { profile in
                        Button(profile.name) { model.action("copy", project: project.id, path: profile.id) }
                    }
                }.disabled(project.files.isEmpty)
            }
            if project.canUndo {
                Button("Undo last change") { model.action("undo", project: project.id) }
                    .help("Restores mod files. Website actions and saved data stay as they are.")
            }
            Button(project.isTask ? "Delete history…" : "Delete mod…", role: .destructive) { deletingProject = project.id }
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24).disabled(model.snapshot.busy)
    }

    private var usagePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("How to use", systemImage: "book").font(.headline)
                Spacer()
                Button { model.instructionsOpen = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close instructions")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let guide = model.project?.usage {
                        Text(guide.entryPoint).font(.headline)
                        ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                            Text("\(index + 1). \(step)")
                        }
                        if !guide.tips.isEmpty { Text(guide.tips).foregroundStyle(.secondary) }
                    } else {
                        Text("No instructions yet").font(.headline)
                        Text("ModSmith can read this mod and write a guide to its controls.").foregroundStyle(.secondary)
                    }
                    Button(model.project?.usage == nil ? "Generate instructions" : "Update instructions", systemImage: "arrow.clockwise") { model.action("document") }
                        .disabled(model.snapshot.busy || model.project == nil)
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.primary.opacity(0.025))
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
        VStack(alignment: .leading, spacing: 12) {
            Button("Tasks & Mods", systemImage: "chevron.left") { composerFocused = false; model.action("overview") }.buttonStyle(.plain).foregroundStyle(.secondary)
            if let project = model.project {
                HStack(spacing: 12) {
                    modIcon(project.favicon, fallback: project.scope == "browser" ? "macwindow" : "globe")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name).font(.title2.weight(.semibold)).lineLimit(2)
                        Text("\(model.snapshot.workspace_profile?.name ?? "This app") · \(project.scopeLabel)").font(.caption).foregroundStyle(.secondary)
                        Text(project.isTask ? project.statusLabel : "Latest request: \(project.statusLabel)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !project.files.isEmpty {
                        Button("How to use", systemImage: "book") { model.instructionsOpen.toggle() }
                        enabledControl(project)
                    }
                    projectMenu(project)
                }
            } else {
                Text("What would you like to do?").font(.title.weight(.semibold))
                Picker("Keep this request", selection: Binding(get: { model.requestKind }, set: { model.action("choose_kind", path: $0) })) {
                    Text("Run once").tag("task")
                    Text("Keep as a mod").tag("mod")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 320).accessibilityIdentifier("request-kind")
                if model.requestKind == "task" {
                    Label(URL(string: model.targetURL)?.host ?? "Open a page to start", systemImage: "doc")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Work on this tab now. Temporary page changes last until navigation or a site refresh.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.isSiteApp { Label("Only this app", systemImage: "app") }
                else { ModScopeCards(choice: model.scopeChoice) }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resultAnchor: String {
        guard let project = model.project else { return "bottom" }
        if project.needsNextStep { return "required-input" }
        if project.canEnableAndTest { return "next-action" }
        return "bottom"
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
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
                                    } else if step.action == "repair" {
                                        Button("Try repair", systemImage: "wrench.and.screwdriver") { model.action("continue", project: project.id) }
                                            .buttonStyle(.borderedProminent).disabled(model.snapshot.busy)
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
                            Label(notice, systemImage: "info.circle")
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
                        ForEach(project.turns) { turn in turnView(turn).id(turn.id) }
                        if let files = project.artifacts, !files.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Saved files").font(.headline)
                                ForEach(files) { file in
                                    HStack {
                                        Image(systemName: "doc")
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(file.name).font(.callout.weight(.medium))
                                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button("Show in Finder") { model.action("reveal_file", path: file.path) }
                                    }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                        if project.isTask && project.status == "active" {
                            HStack {
                                Button("Run again on current page") { model.action("run_again", project: project.id) }
                                Button("Make reusable…") { model.action("make_reusable", project: project.id) }
                            }.disabled(model.snapshot.busy)
                        }
                        if project.canRetry {
                            Text(project.isTask ? "Your progress is saved. Resume to continue the task." : "Your request is saved. Try again to build the mod; you don’t need to retype it.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if project.status == "interrupted" || project.status == "restored" {
                            Text(project.summary).font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("START WITH AN IDEA").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                            ForEach(model.requestKind == "task" ? ["Export the table on this page as CSV", "Make this page easier to read"] : ["Always hide distractions on this site", "Add a button to export tables as CSV"], id: \.self) { example in
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
                        DisclosureGroup(model.project?.isTask == true ? "Activity" : "Activity details", isExpanded: context.binding("showDetails", default: false)) {
                            Text(model.snapshot.progress.joined(separator: "\n"))
                                .font(model.project?.isTask == true ? .callout : .system(size: 10, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.scrollTargetLayout().padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollPosition(id: context.binding("scroll:" + (model.project?.id ?? "new"), default: Optional<String>.none), anchor: .top)
            .onAppear {
                if let saved = context.values["scroll:" + (model.project?.id ?? "new")] as? String { proxy.scrollTo(saved, anchor: .top) }
            }
            .onChange(of: "\(model.project?.id ?? "new")|\(model.project?.turns.count ?? 0)|\(model.project?.status ?? "")") { previous, current in
                let projectChanged = previous.split(separator: "|").first != current.split(separator: "|").first
                if projectChanged, let saved = context.values["scroll:" + (model.project?.id ?? "new")] as? String {
                    proxy.scrollTo(saved, anchor: .top)
                } else { proxy.scrollTo(resultAnchor, anchor: resultAnchor == "bottom" ? .bottom : .top) }
            }
        }
    }

    private func turnView(_ turn: ModSmithTurn) -> some View {
        ModSmithTurnCard(turn: turn, assistantName: model.project?.isTask == true ? "Bowser" : "ModSmith")
    }

    @ViewBuilder private var activeBuild: some View {
        if model.snapshot.busy {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text(runningProject?.name ?? "Another request is running")
                        .font(.caption.weight(.semibold)).lineLimit(1)
                    Text(model.snapshot.stage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let profile = model.snapshot.running_profile {
                    profileIdentity(profile, caption: "Running in")
                }
                if let running = runningProject {
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
            if let notice = model.snapshot.notice { Text(notice).foregroundStyle(.secondary) }
            TextField(model.requestKind == "task" ? (model.project == nil ? "What would you like me to do?" : "Ask a follow-up…") : model.project == nil ? "Describe what you want to change…" : "What should we change next?", text: Binding(get: { model.draft }, set: { model.draft = $0 }), axis: .vertical)
                .textFieldStyle(.plain).lineLimit(3...6).focused($composerFocused)
                .padding(13).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            HStack {
                Text(model.snapshot.busy ? (model.requestKind == "task" ? "You can draft a follow-up while this runs." : "You can draft the next change.") : "⌘ Return to send")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let project = model.project {
                    if !model.snapshot.busy && project.canContinue && !project.canEnableAndTest && !project.needsNextStep {
                        Button(project.recoveryLabel) { model.action(project.recoveryAction, project: project.id) }
                            .accessibilityIdentifier("modsmith-continue")
                    }
                }
                if model.snapshot.busy {
                    Button(runningProject?.isTask == true ? "Stop task" : runningProject == nil ? "Stop request" : "Stop build", systemImage: "stop.fill", role: .destructive) {
                        model.action("cancel", project: model.snapshot.running_project ?? runningProject?.id)
                    }
                    .buttonStyle(.borderedProminent).tint(.red).fixedSize()
                    .disabled(!model.snapshot.canStop)
                    .help(model.snapshot.canStop ? (runningProject?.isTask == true ? "Stop the task and keep its progress and saved files" : "Stop generation, verification and repairs") : "A request is running in another app window. Stop it there.")
                    .accessibilityIdentifier("modsmith-stop-build")
                } else {
                    Button(model.requestKind == "task" ? (model.project == nil ? "Run task" : "Send follow-up") : model.project == nil ? "Create mod" : "Make changes", systemImage: "arrow.up") { model.submit() }
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
            } else if model.selected == "history" {
                    HistorySettingsScreen(context: model.historyContext)
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

struct HistoryScreen: View {
    @ObservedObject var context: BrowserScreenContext
    private var model: any HistoryPresentation { context.model as! any HistoryPresentation }
    @State private var selection: Set<String> = []
    @State private var preview: HistorySearchItem?
    @State private var pendingDeletion: [HistorySearchItem] = []
    @State private var showStatus = false
    @State private var showSiteFilter = false
    @State private var siteDraft = ""
    @State private var collapsed: Set<String> = []
    @State private var querySelection: TextSelection?
    @FocusState private var searching: Bool
    private var gallery: Bool { context.binding("historyGallery", default: false).wrappedValue }
    private var showTopics: Bool { context.binding("historySiteLabels", default: true).wrappedValue }
    private var filterIdentity: [String] { [model.selectedProfile, String(model.allProfiles), model.query, model.dateFilter, model.siteFilter] }
    private var filtered: Bool { !model.query.isEmpty || !model.siteFilter.isEmpty || model.dateFilter != "all" }
    private let dates = [("all", "All time"), ("today", "Today"), ("yesterday", "Yesterday"), ("week", "Last 7 days")]

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 680
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("History").font(.system(size: compact ? 29 : 34, weight: .bold)).accessibilityAddTraits(.isHeader)
                        statusButton
                    }
                    Spacer(minLength: 4)
                    profilePicker
                    Button { model.showSettings() } label: {
                        Image(systemName: "gearshape").frame(width: 26, height: 26)
                    }.buttonStyle(.borderless).accessibilityLabel("History settings").help("History settings")
                }
                .padding(.bottom, compact ? 14 : 20)
                if compact {
                    searchField
                    filterControls.padding(.top, 9)
                } else {
                    HStack(spacing: 12) { searchField; filterControls }
                }
                Divider().padding(.top, compact ? 13 : 20).padding(.bottom, 12)
                if !model.results.isEmpty { resultsToolbar }
                if !model.allProfiles, let warning = model.storageWarning {
                    Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
                }
                if let error = model.searchError, !model.results.isEmpty {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                        Spacer()
                        Button("Refresh") { model.search() }
                    }.padding(.vertical, 8)
                }
                if model.results.isEmpty { emptyState } else { collection }
            }
            .padding(.horizontal, compact ? 18 : 36).padding(.top, compact ? 18 : 26)
            .frame(maxWidth: 1080, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.search(); searching = true }
        .onReceive(context.focusSearchRequests) {
            searching = true
            let query = model.query
            querySelection = TextSelection(range: query.startIndex..<query.endIndex)
        }
        .onChange(of: filterIdentity) { _, _ in selection.removeAll(); collapsed.removeAll(); preview = nil }
        .onChange(of: model.results.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .alert("Delete \(pendingDeletion.count == 1 ? "this entry" : "these \(pendingDeletion.count) entries")?", isPresented: Binding(
            get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } }
        ), presenting: pendingDeletion) { entries in
            Button("Delete", role: .destructive) { model.delete(entries); selection.subtract(entries.map(\.id)) }
            Button("Cancel", role: .cancel) {}
        } message: { entries in
            let profiles = Set(entries.map(\.profile))
            let names = model.profiles.filter { profiles.contains($0.id) }.map(\.name).joined(separator: ", ")
            Text("This removes the selected history\(names.isEmpty ? "" : " from \(names)"). Deleting the last visit to a page also removes its saved content. This cannot be undone.")
        }
        .sheet(item: $preview) { previewSheet($0) }
    }

    private var profilePicker: some View {
        Menu {
            Picker("History profile", selection: Binding(get: { model.allProfiles ? "__all__" : model.selectedProfile }, set: { value in
                if value == "__all__" { model.allProfiles = true }
                else { model.allProfiles = false; model.selectedProfile = value }
            })) {
                ForEach(model.profiles) { Text($0.name).tag($0.id) }
                if model.profiles.count > 1 { Divider(); Text("All profiles").tag("__all__") }
            }.pickerStyle(.inline).labelsHidden()
        } label: {
            Label(model.allProfiles ? "All profiles" : model.profiles.first(where: { $0.id == model.selectedProfile })?.name ?? "Profile",
                  systemImage: model.allProfiles ? "person.2" : "person.crop.circle").lineLimit(1)
        }.frame(maxWidth: 175, alignment: .trailing).help("Choose a history profile")
    }

    private var statusButton: some View {
        let issue = !model.allProfiles && model.recordingIssue != nil
        let label: String = {
            if issue { return "Visits aren’t saving" }
            if !model.allProfiles && !model.enabled { return "Visit recording is off" }
            if let saved = model.lastSaved { return "Last saved \(saved.formatted(.relative(presentation: .named)))" }
            return model.allProfiles ? "History on this Mac" : "Waiting for the first visit"
        }()
        return Button { showStatus.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: issue ? "exclamationmark.triangle.fill" : "internaldrive")
                    .foregroundStyle(issue ? Color.orange : Color.secondary)
                Text(label).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.font(.callout).foregroundStyle(.secondary)
        }.buttonStyle(.plain).help("History recording and storage details")
            .popover(isPresented: $showStatus) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("History on this Mac").font(.headline)
                    if model.allProfiles {
                        Text("Recording and storage are managed separately for each profile.")
                    } else { Text(model.status); Text(model.storageText).foregroundStyle(.secondary) }
                    if let saved = model.lastSaved { Text("Last visit saved \(saved.formatted(date: .abbreviated, time: .standard))").foregroundStyle(.secondary) }
                }.font(.callout).padding(16).frame(width: 310, alignment: .leading)
            }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search history", text: Binding(get: { model.query }, set: { model.query = $0 }), selection: $querySelection)
                .textFieldStyle(.plain).font(.system(size: 15)).focused($searching)
                .accessibilityIdentifier("history-search").help("Search titles, websites and saved page content")
            if !model.query.isEmpty {
                Button { model.query = ""; searching = true } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
            } else {
                Text("⌘F").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }.padding(.horizontal, 12).frame(height: 38)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(searching ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.15), lineWidth: searching ? 1.5 : 1))
    }

    private var filterControls: some View {
        HStack(spacing: 9) {
            Menu {
                Picker("Date range", selection: Binding(get: { model.dateFilter }, set: { model.dateFilter = $0 })) {
                    ForEach(dates, id: \.0) { id, title in Text(title).tag(id) }
                }.pickerStyle(.inline).labelsHidden()
            } label: { Label(dates.first { $0.0 == model.dateFilter }?.1 ?? "All time", systemImage: "calendar") }
                .fixedSize().help("Filter by date")
            Button { siteDraft = model.siteFilter; showSiteFilter = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "globe")
                    Text(model.siteFilter.isEmpty ? "Website" : model.siteFilter).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
            }.frame(maxWidth: model.siteFilter.isEmpty ? nil : 165).help("Filter by website")
                .popover(isPresented: $showSiteFilter) { siteFilterPopover }
        }
    }

    private var siteFilterPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filter by website").font(.headline)
            TextField("example.com", text: $siteDraft).textFieldStyle(.roundedBorder).onSubmit(applySiteFilter)
            HStack {
                if !model.siteFilter.isEmpty { Button("Clear") { siteDraft = ""; applySiteFilter() } }
                Spacer(); Button("Apply", action: applySiteFilter).keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 260)
    }

    private func applySiteFilter() {
        let value = siteDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        model.siteFilter = URLComponents(string: value.contains("://") ? value : "https://" + value)?.host ?? value
        showSiteFilter = false
    }

    private var resultsToolbar: some View {
        HStack(spacing: 8) {
            if selection.isEmpty {
                Text(filtered ? "Results" : "Recent activity").font(.headline)
                if !model.results.isEmpty {
                    Text("\(model.results.count.formatted())\(model.hasMore ? "+" : "")").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("\(model.results.count) entries shown")
                }
                Spacer(minLength: 4)
                if filtered { Button("Reset", action: clearFilters).buttonStyle(.link).help("Clear search, date and website filters") }
                Picker("History layout", selection: context.binding("historyGallery", default: false)) {
                    Image(systemName: "list.bullet").tag(false).accessibilityLabel("List").help("List")
                    Image(systemName: "square.grid.2x2").tag(true).accessibilityLabel("Gallery").help("Gallery")
                }.labelsHidden().pickerStyle(.segmented).frame(width: 70)
                Menu {
                    Toggle("Show session websites", isOn: context.binding("historySiteLabels", default: true))
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Display options").help("Display options")
            } else {
                Text("\(selection.count) selected").font(.headline)
                Spacer()
                Button("Deselect all") { selection.removeAll() }.buttonStyle(.link)
                Button("Delete…", role: .destructive) { pendingDeletion = model.results.filter { selection.contains($0.id) } }
            }
        }.frame(minHeight: 28)
    }

    private func clearFilters() {
        model.query = ""; model.dateFilter = "all"; model.siteFilter = ""
        searching = true
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if let error = model.searchError {
                emptyMessage("History is unavailable", icon: "exclamationmark.triangle", detail: error)
                Button("Try again") { model.search() }
            } else if model.isSearching {
                ProgressView().controlSize(.small)
                Text("Searching history…").font(.callout).foregroundStyle(.secondary)
            } else if filtered {
                emptyMessage("No matching history", icon: "magnifyingglass", detail: "Try a different search, website or date range.")
                Button("Clear filters", action: clearFilters)
            } else if !model.allProfiles && !model.enabled {
                emptyMessage("No saved history", icon: "clock", detail: "Turn on recording to keep a searchable history for this profile on your Mac.")
                Button("Open History Settings") { model.showSettings() }.buttonStyle(.borderedProminent)
            } else {
                emptyMessage("No saved history yet", icon: "clock", detail: model.allProfiles ? "Visits appear here as profiles with recording enabled save pages." : "Pages you visit in this profile will appear here.")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 20)
    }

    private func emptyMessage(_ title: String, icon: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 27, weight: .regular)).foregroundStyle(.secondary).padding(.bottom, 5)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
        }
    }

    private var collection: some View {
        HistoryCollection(
            sessions: HistorySession.group(model.results), selection: selection, collapsed: collapsed, gallery: gallery,
            showTopics: showTopics, showProfiles: model.allProfiles, hasMore: model.hasMore, searchIdentity: filterIdentity,
            card: { item in
                AnyView(HistoryVisitCard(
                    item: item, gallery: gallery, selected: selection.contains(item.id),
                    profileName: model.allProfiles ? model.profiles.first(where: { $0.id == item.profile })?.name : nil,
                    select: { if !selection.insert(item.id).inserted { selection.remove(item.id) } },
                    inspect: { preview = item }, open: { model.open(item) }))
            }, header: { AnyView(sessionHeader($0)) },
            footer: { AnyView(Button("Load older history") { model.loadMore() }.disabled(model.isSearching).frame(maxWidth: .infinity)) }
        ).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sessionHeader(_ session: HistorySession) -> some View {
        let calendar = Calendar.current
        let day = calendar.isDateInToday(session.latest) ? "Today" : calendar.isDateInYesterday(session.latest)
            ? "Yesterday" : session.latest.formatted(date: .abbreviated, time: .omitted)
        let start = session.earliest.formatted(date: .omitted, time: .shortened)
        let end = session.latest.formatted(date: .omitted, time: .shortened)
        let interval = start == end ? start : "\(start)–\(end)"
        let time = session.isVisit ? interval : "Captured \(interval)"
        let count = session.items.count
        let unit = session.isVisit ? (count == 1 ? "visit" : "visits") : (count == 1 ? "saved page" : "saved pages")
        let folded = collapsed.contains(session.id)
        let allSelected = session.items.allSatisfy { selection.contains($0.id) }
        let topic = showTopics ? session.topic : ""

        return HStack(spacing: 10) {
            Button {
                if !collapsed.insert(session.id).inserted { collapsed.remove(session.id) }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: folded ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 12)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Text(day).font(.system(size: 16, weight: .semibold)).fixedSize()
                            Text(time).font(.callout).foregroundStyle(.secondary)
                        }
                        if !topic.isEmpty {
                            Text(topic).font(.caption).foregroundStyle(.secondary)
                        }
                    }.lineLimit(1)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(day), \(time), \(count) \(unit)")
            .accessibilityValue(folded ? "Collapsed" : "Expanded")
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Text("\(count) \(unit)").font(.caption).foregroundStyle(.secondary).fixedSize()
            Button(allSelected ? "Deselect" : "Select") {
                let ids = session.items.map(\.id)
                if allSelected { selection.subtract(ids) } else { selection.formUnion(ids) }
            }
            .font(.caption.weight(.medium)).buttonStyle(.borderless)
            .accessibilityLabel("\(allSelected ? "Deselect" : "Select") all \(count) \(unit) in this group")
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func previewSheet(_ item: HistorySearchItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                HistorySiteMark(site: item.historySite, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.historySite).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(item.isVisit ? "Visited" : "Captured") \(item.seen.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(item.historyTitle).font(.title2.weight(.semibold)).lineLimit(3).textSelection(.enabled)
            Text(item.url).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
            if let image = HistoryPreviewImages.load(item.image) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Saved preview of \(item.historyTitle)")
            } else {
                Label("No saved picture", systemImage: "photo")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !item.snippet.isEmpty {
                Divider()
                ScrollView {
                    Text(item.snippet).font(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.scrollBounceBehavior(.basedOnSize).frame(maxHeight: 120).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { preview = nil }.keyboardShortcut(.cancelAction)
                Button("Open page") {
                    model.open(item)
                    preview = nil
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(minWidth: 360, idealWidth: 500, maxWidth: 540)
    }
}

private extension HistorySearchItem {
    var historySite: String {
        let host = URL(string: url)?.host ?? url
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    var historyTitle: String { title.isEmpty ? historySite : title }
}

private struct HistorySiteMark: View {
    let site: String
    let size: CGFloat
    var body: some View {
        Text(site.prefix(1).uppercased())
            .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }
}

private struct HistoryVisitCard: View {
    let item: HistorySearchItem
    let gallery: Bool
    let selected: Bool
    let profileName: String?
    let select: () -> Void
    let inspect: () -> Void
    let open: () -> Void

    var body: some View {
        Group {
            if gallery { galleryCard } else { row }
        }
        .contextMenu {
            Button("Open page", action: open)
            Button("Show details", action: inspect)
            Divider()
            Button(selected ? "Deselect" : "Select", action: select)
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    if let image = HistoryPreviewImages.load(item.image) {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: 42, height: 34, alignment: .topLeading)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.09)))
                    } else {
                        HistorySiteMark(site: item.historySite, size: 34).frame(width: 42)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.historyTitle).font(.system(size: 14, weight: .medium))
                        Text(metadata).font(.caption).foregroundStyle(.secondary)
                    }.lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(item.url).accessibilityLabel("Open \(item.historyTitle), \(metadata)")
            Text(item.seen.formatted(date: .omitted, time: .shortened))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            Button(action: inspect) {
                Image(systemName: "info.circle").frame(width: 24, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Show details").accessibilityLabel("Show details for \(item.historyTitle)")
            selectionToggle
        }
        .padding(.horizontal, 8)
        .background(selected ? Color.accentColor.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .bottom) { Divider().padding(.leading, 62) }
    }

    private var galleryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: inspect) {
                Group {
                    if let image = HistoryPreviewImages.load(item.image) {
                        HistoryThumbnail(image: image)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 7) {
                                HistorySiteMark(site: item.historySite, size: 24)
                                Text("No saved picture").font(.caption).foregroundStyle(.secondary)
                            }
                            if !item.snippet.isEmpty {
                                Text(item.snippet).font(.callout).foregroundStyle(.secondary)
                                    .lineLimit(3).multilineTextAlignment(.leading)
                            }
                        }
                        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(nsColor: .controlBackgroundColor))
            .help("Show details").accessibilityLabel("Show details for \(item.historyTitle)")
            Divider()
            HStack(alignment: .top, spacing: 5) {
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.historyTitle).font(.system(size: 13, weight: .semibold))
                            .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                        Text(metadata).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(item.seen.formatted(date: .omitted, time: .shortened))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help(item.url)
                    .accessibilityLabel("Open \(item.historyTitle), \(metadata), \(item.seen.formatted(date: .omitted, time: .shortened))")
                selectionToggle
            }.padding(10)
        }
        .background(selected ? Color.accentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
            selected ? Color.accentColor : Color.primary.opacity(0.13), lineWidth: selected ? 2 : 1))
    }

    private var metadata: String {
        if let profileName { return "\(item.historySite) · \(profileName)" }
        return item.historySite
    }

    private var selectionToggle: some View {
        Toggle("Select \(item.historyTitle)", isOn: Binding(get: { selected }, set: { _ in select() }))
            .toggleStyle(.checkbox).labelsHidden().controlSize(.regular)
            .help(selected ? "Deselect entry" : "Select entry")
    }
}

@MainActor private enum HistoryPreviewImages {
    static let cache: NSCache<NSData, NSImage> = {
        let cache = NSCache<NSData, NSImage>()
        cache.countLimit = 96
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    static func load(_ data: Data?) -> NSImage? {
        guard let data else { return nil }
        let key = data as NSData
        if let image = cache.object(forKey: key) { return image }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key, cost: max(data.count, Int(image.size.width * image.size.height * 4)))
        return image
    }
}

private struct HistoryThumbnail: View {
    let image: NSImage
    var body: some View {
        GeometryReader { size in
            Image(nsImage: image).resizable()
                .frame(width: size.size.width, height: size.size.width * image.size.height / max(1, image.size.width))
                .frame(width: size.size.width, height: size.size.height, alignment: .top).clipped()
                .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}

private struct HistorySettingsScreen: View {
    @ObservedObject var context: BrowserScreenContext
    private var model: any HistoryPresentation { context.model as! any HistoryPresentation }
    @State private var clearTarget: ProfileDisplay?
    private var currentProfile: ProfileDisplay? { model.profiles.first { $0.id == model.selectedProfile } }
    private var draftKey: String { "excludedWebsitesDraft:" + model.selectedProfile }
    private var exclusions: Binding<String> { context.binding(draftKey, default: model.excludedSites) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("History").font(.title.weight(.semibold))
                Spacer()
                Picker("Profile", selection: Binding(get: { model.selectedProfile }, set: { model.selectedProfile = $0 })) {
                    ForEach(model.profiles) { Text($0.name).tag($0.id) }
                }.frame(maxWidth: 210, alignment: .trailing)
                Button("Open History", systemImage: "arrow.up.forward.square") { model.showBrowser() }
            }
            .padding(.horizontal, 26).padding(.vertical, 18)
            Divider()
            Form {
                if let warning = model.storageWarning {
                    Label {
                        Text(warning).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
                recordingSection
                exclusionsSection
                storageSection
                if let error = model.searchError {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout)
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { model.search() }
        .onChange(of: model.selectedProfile) { _, _ in clearTarget = nil }
        .alert(
            "Clear history for “\(clearTarget?.name ?? "")”?",
            isPresented: Binding(get: { clearTarget != nil }, set: { if !$0 { clearTarget = nil } }),
            presenting: clearTarget
        ) { profile in
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) {
                if model.selectedProfile == profile.id { model.clear() }
            }
        } message: { _ in
            Text("All visits, page previews, saved content, and search data for this profile will be permanently deleted.")
        }
    }

    private var recordingSection: some View {
        Section("Recording") {
            Toggle(isOn: Binding(get: { model.enabled }, set: { model.enabled = $0 })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Record browsing history").fontWeight(.medium)
                    hint("Save visits, visible page text, and colors on this Mac. Private windows and editable fields are excluded.")
                    if !model.modelReady && !model.isDownloading {
                        hint("Turning on recording downloads a 388 MB search model shared by all profiles.")
                    }
                    hint("Older items are permanently deleted after \(model.retentionDays) days or when this profile exceeds 128 MB or 10,000 items, whichever comes first.")
                }.padding(.vertical, 2)
            }
            Toggle("Include page previews and pictures", isOn: Binding(get: { model.includeImages }, set: { model.includeImages = $0 }))
            HStack(spacing: 12) {
                if model.isDownloading { ProgressView().controlSize(.small) }
                hint(model.status)
                Spacer(minLength: 12)
                if !model.modelReady && !model.isDownloading {
                    Button("Download Search Model") { model.downloadModel() }
                }
            }
        }
        .toggleStyle(.switch)
    }

    private var exclusionsSection: some View {
        Section("Excluded websites") {
            VStack(alignment: .leading, spacing: 8) {
                hint("Saving this list removes existing history for these websites and their subdomains, and excludes future visits.")
                TextField("Websites", text: exclusions, prompt: Text("example.com, mail.example.org"), axis: .vertical)
                    .labelsHidden().textFieldStyle(.roundedBorder).lineLimit(1...4)
                    .accessibilityLabel("Excluded websites")
                HStack {
                    hint("Separate websites with commas or new lines.")
                    Spacer()
                    Button("Save Exclusions") {
                        model.excludedSites = exclusions.wrappedValue
                        model.saveExclusions()
                        if model.recordingIssue == nil { context.values[draftKey] = nil }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(exclusions.wrappedValue == model.excludedSites && model.recordingIssue == nil && model.searchError == nil)
                }
            }.padding(.vertical, 3)
        }
    }

    private var storageSection: some View {
        Section("Storage") {
            Picker("Keep history for", selection: Binding(get: { model.retentionDays }, set: { model.retentionDays = $0 })) {
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("1 year").tag(365)
            }
            HStack(spacing: 16) {
                hint(model.storageText)
                Spacer()
                Button("Clear History…", role: .destructive) { clearTarget = currentProfile }
                    .disabled(currentProfile == nil)
            }
        }
    }

    private func hint(_ value: String) -> some View {
        Text(value).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
