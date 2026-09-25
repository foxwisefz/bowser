import AppKit
import SwiftUI
import Darwin
import IOKit

struct RegistrationDevice: Codable, Equatable, Sendable {
    let model: String
    let architecture: String
    let macOSVersion: String
    let appVersion: String
    let appBuild: String
    var hardwareUUID: String? = nil

    private static func hardwareIdentifier() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString,
            kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { return nil }
        return UUID(uuidString: value)?.uuidString
    }

    static func current() -> Self {
        var length = 0
        sysctlbyname("hw.model", nil, &length, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(length, 1))
        let result = sysctlbyname("hw.model", &bytes, &length, nil, 0)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Self(model: result == 0 ? String(cString: bytes) : "unknown", architecture: "arm64",
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "development",
            hardwareUUID: hardwareIdentifier())
    }
}

struct RegistrationPolicy: Equatable, Sendable {
    let termsVersion: String
    let termsURL: URL
}

struct RegistrationRequest: Codable, Equatable, Sendable {
    let requestID: UUID
    let email: String
    let termsVersion: String
    let acceptedAt: Date
    var device: RegistrationDevice? = nil
    var inviteCode: String? = nil
}

struct RegistrationReceipt: Codable, Equatable, Sendable {
    let registrationID: String
    var telemetryToken: String? = nil
    let request: RegistrationRequest
}

enum RegistrationFailure: LocalizedError {
    case invalidResponse
    case inviteUnavailable
    case recoveryUnavailable, invalidRecoveryCode, registrationNotFound, recoveryRateLimited
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "We couldn’t finish activation. Check your connection and try again."
        case .recoveryUnavailable: "Email verification is unavailable right now. Please try again shortly."
        case .invalidRecoveryCode: "That code is incorrect or expired. Try again or request a new code."
        case .registrationNotFound: "This email hasn’t activated Bowser yet. Go back to enter an invite or request one."
        case .recoveryRateLimited: "Please wait a minute before requesting another code."
        case .inviteUnavailable: "That invite is invalid or has already been used. Check the code or join the waitlist."
        }
    }
}

enum OnboardingStartup {
    static func needsSetup(home: URL) -> Bool {
        guard let receipt = try? RegistrationStore(directory: home).load(),
              !receipt.registrationID.isEmpty, let token = receipt.telemetryToken, !token.isEmpty else { return true }
        return false
    }
}

enum BowserAPI {
    static var base: URL {
        URL(string: ProcessInfo.processInfo.environment["BOWSER_API_ENDPOINT"] ?? "https://api.bowser.app") ?? URL(string: "https://api.bowser.app")!
    }
    static var guide: URL {
        let local = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(base.host ?? "")
        return (local ? base : URL(string: "https://www.bowser.app")!).appendingPathComponent("learn")
    }
    static var terms: URL {
        ProcessInfo.processInfo.environment["BOWSER_API_ENDPOINT"] == nil
            ? URL(string: "https://bowser.app/terms.html")!
            : base.appendingPathComponent("terms.html")
    }
    static func allows(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil else { return false }
        return url.scheme == "https" ||
            (url.scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host ?? ""))
    }
}

/// First-run activation and effective Terms remain an explicit launch policy.
struct RegistrationService: Sendable {
    static let productionEndpoint = URL(string: "https://api.bowser.app/v1/registrations")!
    let endpoint: URL

    init(endpoint: URL = BowserAPI.base.appendingPathComponent("v1/registrations")) {
        self.endpoint = endpoint
    }

    static func joinWaitlist(email: String) async throws {
        let endpoint = BowserAPI.base.appendingPathComponent("v1/waitlist")
        guard BowserAPI.allows(endpoint) else { throw RegistrationFailure.invalidResponse }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["email": email])
        let (_, response) = try await PrivateHTTP.send(request)
        guard response.statusCode == 202 else { throw RegistrationFailure.invalidResponse }
    }

    static func requestRecovery(email: String) async throws -> String {
        let data = try await recoveryPost("v1/recovery", body: ["email": email])
        struct Challenge: Decodable { let challengeID: String }
        let id = try JSONDecoder().decode(Challenge.self, from: data).challengeID
        guard UUID(uuidString: id) != nil else { throw RegistrationFailure.invalidResponse }
        return id
    }
    static func verifyRecovery(challenge: String, code: String, requestID: UUID) async throws -> RegistrationReceipt {
        let data = try await recoveryPost("v1/recovery/verify", body: ["challengeID": challenge, "code": code, "requestID": requestID.uuidString])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RegistrationReceipt.self, from: data)
    }
    private static func recoveryPost(_ path: String, body: [String: String]) async throws -> Data {
        var request = URLRequest(url: BowserAPI.base.appendingPathComponent(path))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await PrivateHTTP.send(request)
        if response.statusCode == 429 { throw RegistrationFailure.recoveryRateLimited }
        if response.statusCode == 403 {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
            if json?["error"]?["code"] == "registration_not_found" { throw RegistrationFailure.registrationNotFound }
            throw RegistrationFailure.invalidRecoveryCode
        }
        guard (200..<300).contains(response.statusCode) else { throw RegistrationFailure.recoveryUnavailable }
        return data
    }

    func submit(_ registration: RegistrationRequest) async throws -> RegistrationReceipt {
        guard BowserAPI.allows(endpoint) else {
            throw RegistrationFailure.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(registration.requestID.uuidString, forHTTPHeaderField: "Idempotency-Key")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(registration)
        let (data, response) = try await PrivateHTTP.send(request)
        if response.statusCode == 403 { throw RegistrationFailure.inviteUnavailable }
        guard (200..<300).contains(response.statusCode) else { throw RegistrationFailure.invalidResponse }
        struct Response: Decodable { let registrationID: String; let telemetryToken: String? }
        let result = try JSONDecoder().decode(Response.self, from: data)
        guard !result.registrationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RegistrationFailure.invalidResponse
        }
        guard let token = result.telemetryToken, !token.isEmpty else { throw RegistrationFailure.invalidResponse }
        return RegistrationReceipt(registrationID: result.registrationID, telemetryToken: token, request: registration)
    }
}

struct RegistrationStore: Sendable {
    let directory: URL
    var file: URL { directory.appendingPathComponent("registration.json") }

    var pendingFile: URL { directory.appendingPathComponent("pending-registration.json") }
    func savePending(_ request: RegistrationRequest) throws { try write(JSONEncoder().encode(request), to: pendingFile) }
    func loadPending() -> RegistrationRequest? {
        guard let data = try? Data(contentsOf: pendingFile) else { return nil }
        return try? JSONDecoder().decode(RegistrationRequest.self, from: data)
    }
    func clearPending() { try? FileManager.default.removeItem(at: pendingFile) }

    func save(_ receipt: RegistrationReceipt) throws {
        try write(JSONEncoder().encode(receipt), to: file)
    }

    private func write(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func load() throws -> RegistrationReceipt? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(RegistrationReceipt.self, from: Data(contentsOf: file))
    }
}

@MainActor
enum OnboardingArtwork {
    static let image: NSImage? = {
        let url = Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            : Bundle.module.url(forResource: "AppIcon", withExtension: "png")
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        image.setName("BowserWelcome")
        return image
    }()
}

@MainActor
final class OnboardingModel: ObservableObject, OnboardingPresentation {
    var completed: Bool { receipt != nil }
    @Published var recoveryCode = ""
    private var recoveryChallenge: String?
    private var recoveryRequest = UUID()
    private let requestRecoveryCode: @Sendable (String) async throws -> String
    private let recover: @Sendable (String, String, UUID) async throws -> RegistrationReceipt
    var canVerify: Bool { !submitting && recoveryChallenge != nil && recoveryCode.trimmingCharacters(in: .whitespacesAndNewlines).range(of: #"^\d{8}$"#, options: .regularExpression) != nil }
    func requestRecovery() async {
        guard canContinue else { return }
        submitting = true; error = nil
        defer { submitting = false }
        do {
            recoveryChallenge = try await requestRecoveryCode(Self.normalizedEmail(email)!)
            recoveryCode = ""; recoveryRequest = UUID(); step = .recovery
        } catch { self.error = (error as? RegistrationFailure)?.errorDescription ?? "Couldn’t send a code. Check your connection and try again." }
    }
    func verifyRecovery() async {
        guard canVerify, let challenge = recoveryChallenge else { return }
        submitting = true; error = nil
        defer { submitting = false }
        do {
            let result = try await recover(challenge, recoveryCode.trimmingCharacters(in: .whitespacesAndNewlines), recoveryRequest)
            guard result.request.email.lowercased() == Self.normalizedEmail(email)?.lowercased(),
                  !result.registrationID.isEmpty, let token = result.telemetryToken, !token.isEmpty else { throw RegistrationFailure.invalidResponse }
            try store.save(result); store.clearPending(); receipt = result
            finish()
            await Telemetry.shared.start(token: token)
            AppUsage.shared.didActivate()
        } catch { self.error = (error as? RegistrationFailure)?.errorDescription ?? "Couldn’t restore access. Please try again." }
    }
    @Published private(set) var step: OnboardingStep = .email
    var canContinue: Bool { !submitting && Self.normalizedEmail(email) != nil }
    func continueWithEmail() {
        guard canContinue, let value = Self.normalizedEmail(email) else { return }
        email = value; error = nil; step = .invitation
        AppUsage.shared.enteredEmail()
    }
    func enterInvite() {
        guard canContinue else { return }
        joiningWaitlist = false; error = nil; step = .code
    }
    func editEmail() {
        guard !submitting else { return }
        error = nil; recoveryChallenge = nil; recoveryCode = ""; step = .email
    }
    func backToInvitation() {
        guard !submitting else { return }
        error = nil; step = .invitation
    }
    @Published var inviteCode = ""
    @Published var joiningWaitlist = false
    @Published private(set) var waitlistJoined = false
    var canJoinWaitlist: Bool { !submitting && !waitlistJoined && Self.normalizedEmail(email) != nil }
    private let waitlist: @Sendable (String) async throws -> Void
    @Published var hostedAvailable = true
    @Published var allowance = 40
    @Published var setupMessage: String?
    var termsURL: URL { policy.termsURL }
    var onFinish: () -> Void = {}
    var onRegistered: () -> Void = {}
    func finish() { if completed { onFinish() } }
    @Published var email = "" {
        didSet {
            if email != oldValue { waitlistJoined = false; acceptedTerms = false }
        }
    }
    @Published var acceptedTerms = false
    @Published private(set) var submitting = false
    @Published private(set) var error: String?
    @Published private(set) var receipt: RegistrationReceipt?
    var policy: RegistrationPolicy
    private let store: RegistrationStore
    private let register: @Sendable (RegistrationRequest) async throws -> RegistrationReceipt
    private var pending: RegistrationRequest?
    private let device: RegistrationDevice

    init(policy: RegistrationPolicy, store: RegistrationStore, device: RegistrationDevice = .current(),
         requestRecoveryCode: @escaping @Sendable (String) async throws -> String = { try await RegistrationService.requestRecovery(email: $0) },
         recover: @escaping @Sendable (String, String, UUID) async throws -> RegistrationReceipt = { try await RegistrationService.verifyRecovery(challenge: $0, code: $1, requestID: $2) },
         waitlist: @escaping @Sendable (String) async throws -> Void = { try await RegistrationService.joinWaitlist(email: $0) },
         register: @escaping @Sendable (RegistrationRequest) async throws -> RegistrationReceipt) {
        _ = OnboardingArtwork.image
        self.policy = policy; self.store = store; self.register = register
        self.device = device
        self.waitlist = waitlist
        self.requestRecoveryCode = requestRecoveryCode; self.recover = recover
        if let request = store.loadPending() {
            pending = request; email = request.email; inviteCode = request.inviteCode ?? ""
            acceptedTerms = request.termsVersion == policy.termsVersion
            step = .code
        }
    }

    func applySetup(_ setup: [String: Any]) {
        hostedAvailable = false
        guard let version = setup["termsVersion"] as? String,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setupMessage = "Invitations aren’t ready on our server yet. Please try again shortly."
            return
        }
        guard setup["hostedAI"] as? Bool == true else {
            setupMessage = "Our AI service is temporarily unavailable. Your invite can be used when service returns."
            return
        }
        if policy.termsVersion != version { acceptedTerms = pending?.termsVersion == version }
        policy = RegistrationPolicy(termsVersion: version, termsURL: policy.termsURL)
        allowance = (setup["limits"] as? [String: Int])?["chat"] ?? 40
        hostedAvailable = true
        setupMessage = nil
    }

    nonisolated static func normalizedEmail(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 254, !value.contains(where: { $0.isWhitespace }),
              value.range(of: #"^[^@<>]+@[^@<>.]+(?:\.[^@<>.]+)+$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    var canSubmit: Bool {
        guard !submitting && !completed else { return false }
        return hostedAvailable && Self.normalizedEmail(email) != nil && acceptedTerms && !normalizedInvite.isEmpty
    }
    private var normalizedInvite: String { inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }

    func joinWaitlist() async {
        guard canJoinWaitlist, let email = Self.normalizedEmail(email) else { return }
        submitting = true; error = nil
        defer { submitting = false }
        do {
            try await waitlist(email)
            waitlistJoined = true; joiningWaitlist = true; step = .thanks
        }
        catch { self.error = "Couldn’t join the waitlist. Check your connection and try again." }
    }

    func refreshSetup() async {
        hostedAvailable = false
        setupMessage = "Checking invitation availability…"
        do {
            var request = URLRequest(url: BowserAPI.base.appendingPathComponent("v1/setup"))
            request.timeoutInterval = 10
            guard BowserAPI.allows(request.url!) else { throw RegistrationFailure.invalidResponse }
            let (data, response) = try await PrivateHTTP.send(request)
            guard response.statusCode == 200,
                  let setup = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  setup["inviteRequired"] as? Bool == true else { throw RegistrationFailure.invalidResponse }
            applySetup(setup)
        } catch { setupMessage = "Can’t reach Bowser’s invitation service. Please try again." }
    }

    func submit() async {
        guard canSubmit else { return }
        guard let email = Self.normalizedEmail(email) else { return }
        submitting = true; error = nil
        defer { submitting = false }
        if pending?.email != email || pending?.termsVersion != policy.termsVersion || pending?.inviteCode != normalizedInvite {
            pending = RegistrationRequest(requestID: UUID(), email: email,
                termsVersion: policy.termsVersion, acceptedAt: Date(),
                device: device, inviteCode: normalizedInvite)
        }
        guard let request = pending else { return }
        do {
            try store.savePending(request)
            let result = try await register(request)
            guard result.request == request, !result.registrationID.isEmpty,
                  let token = result.telemetryToken, !token.isEmpty else { throw RegistrationFailure.invalidResponse }
            try store.save(result)
            store.clearPending()
            receipt = result
            finish()
            onRegistered()
            Task {
                await Telemetry.shared.start(token: result.telemetryToken)
                AppUsage.shared.didActivate()
                await Telemetry.shared.record(.registration(id: result.request.requestID))
            }
        } catch {
            // Never echo server bodies, URLs, emails or credentials into error text.
            self.error = (error as? RegistrationFailure)?.errorDescription ?? "We couldn’t finish activation. Check your connection and try again."
        }
    }
}

struct OnboardingView: View {
    let model: OnboardingModel
    let finished: () -> Void
    var body: some View {
        LiveBrowserScreen(kind: "onboarding", model: model)
            .ignoresSafeArea()
            .onAppear { model.onFinish = finished }
    }
}

@MainActor final class OnboardingWindow {
    static let shared = OnboardingWindow()
    private var window: NSWindow?
    func show(onActivated: @escaping () -> Void = {}) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let model = OnboardingModel(policy: RegistrationPolicy(termsVersion: "", termsURL: BowserAPI.terms),
            store: RegistrationStore(directory: BowserPaths.home)) { try await RegistrationService().submit($0) }
        model.onRegistered = { (NSApp.delegate as? AppDelegate)?.openFirstModGuide(nil) }
        model.hostedAvailable = false
        model.setupMessage = "Checking invitation availability…"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Welcome to Bowser"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NSColor(red: 0.035, green: 0.065, blue: 0.075, alpha: 1)
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(model: model) { [weak self] in
            self?.window?.close(); self?.window = nil
            onActivated()
        })
        self.window = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate()
        Task { await model.refreshSetup() }
    }
}
