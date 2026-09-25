import AppKit
import SwiftUI
import XCTest
import BowserSurfaceKit
@testable import Bowser

@MainActor
final class OnboardingTests: XCTestCase {
    func testRegistrationUsesTermsWithoutSendingTrainingFlag() throws {
        let request = RegistrationRequest(requestID: UUID(), email: "fixture@example.com",
            termsVersion: "2026-09-22", acceptedAt: Date())
        let encoded = try JSONEncoder().encode(request)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["trainingConsent"])
        object["trainingConsent"] = false
        let old = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try JSONDecoder().decode(RegistrationRequest.self, from: old), request)
    }
    func testDeviceHardwareUUIDEncodingAndOldReceiptCompatibility() throws {
        var device = RegistrationDevice(model: "Mac14,5", architecture: "arm64", macOSVersion: "15.0", appVersion: "1", appBuild: "1")
        let old = try JSONEncoder().encode(device)
        XCTAssertNil(try JSONDecoder().decode(RegistrationDevice.self, from: old).hardwareUUID)
        device.hardwareUUID = "B80E7695-2FD2-47EA-A2D6-5431DF55D929"
        XCTAssertEqual(try JSONDecoder().decode(RegistrationDevice.self, from: JSONEncoder().encode(device)), device)
    }
    func testOnboardingStartsForAStateDirectoryWithoutASession() throws {
        let home = store().directory
        XCTAssertTrue(OnboardingStartup.needsSetup(home: home))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: home.appendingPathComponent("session.json"))
        XCTAssertTrue(OnboardingStartup.needsSetup(home: home), "A session file does not grant admission")
        let request = RegistrationRequest(requestID: UUID(), email: "fixture@example.com", termsVersion: "test", acceptedAt: Date())
        try RegistrationStore(directory: home).save(RegistrationReceipt(registrationID: "fixture", telemetryToken: "fixture-token", request: request))
        XCTAssertFalse(OnboardingStartup.needsSetup(home: home), "Admission survives offline launches without querying AI quota")
    }

    func testProductionRegistrationEndpoint() {
        XCTAssertEqual(RegistrationService().endpoint.absoluteString, "https://api.bowser.app/v1/registrations")
    }

    func testLocalRegistrationIntegration() async throws {
        guard ProcessInfo.processInfo.environment["BOWSER_LOCAL_REGISTRATION_TEST"] == "1" else {
            throw XCTSkip("Requires the local Phoenix server")
        }
        let base = URL(string: ProcessInfo.processInfo.environment["BOWSER_TEST_API_ENDPOINT"] ?? "http://127.0.0.1:8080")!
        let (data, response) = try await PrivateHTTP.send(URLRequest(url: base.appendingPathComponent("v1/setup")))
        XCTAssertEqual(response.statusCode, 200)
        let setup = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let model = OnboardingModel(policy: policy, store: store()) {
            try await RegistrationService(endpoint: base.appendingPathComponent("v1/registrations")).submit($0)
        }
        model.applySetup(setup)
        model.inviteCode = try XCTUnwrap(ProcessInfo.processInfo.environment["BOWSER_TEST_INVITE"])
        model.email = "swift-local-test@example.com"; model.acceptedTerms = true
        XCTAssertTrue(model.canSubmit)
        await model.submit()
        XCTAssertNil(model.error)
        XCTAssertFalse(try XCTUnwrap(model.receipt?.telemetryToken).isEmpty)
    }

    func testLocalServiceAllowsOnlyLoopbackPlainHTTP() {
        for address in ["http://127.0.0.1:8080/v1/setup", "http://localhost:8080/v1/registrations", "http://[::1]:8080/v1/setup", "https://api.bowser.app/v1/setup"] {
            XCTAssertTrue(BowserAPI.allows(URL(string: address)!))
        }
        for address in ["http://example.com/v1/setup", "http://localhost.example.com/v1/setup", "http://user:secret@localhost:8080/v1/setup", "ftp://localhost/file"] {
            XCTAssertFalse(BowserAPI.allows(URL(string: address)!))
        }
    }

    let policy = RegistrationPolicy(termsVersion: "test-terms",
        termsURL: URL(string: "https://example.invalid/terms")!)

    func store() -> RegistrationStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return RegistrationStore(directory: directory)
    }

    func testAllOnboardingStepsFitAndRender() async throws {
        _ = NSApplication.shared
        let model = OnboardingModel(policy: policy, store: store(), requestRecoveryCode: { _ in "fixture" }, waitlist: { _ in }) { _ in throw RegistrationFailure.invalidResponse }
        for step in OnboardingStep.allCases {
            model.email = "person@example.com"
            switch step {
            case .email: model.editEmail()
            case .invitation: model.continueWithEmail()
            case .code: model.enterInvite(); model.hostedAvailable = false; model.setupMessage = "Can’t reach Bowser’s invitation service. Please try again."
            case .recovery: await model.requestRecovery()
            case .thanks: await model.joinWaitlist()
            }
            let host = NSHostingView(rootView: OnboardingView(model: model, finished: {}))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host; window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.height, 600)
            XCTAssertLessThanOrEqual(host.fittingSize.width, 860)
            if ProcessInfo.processInfo.environment["BOWSER_ONBOARDING_PREVIEW"] == "1" {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/bowser-welcome-\(step.rawValue).png"))
            }
        }
    }

    func testEmailFirstBranchesAndWaitlistRetry() async {
        let service = FailingThenSuccessfulWaitlist()
        let model = OnboardingModel(policy: policy, store: store(), waitlist: { try await service.join($0) }) { _ in throw RegistrationFailure.invalidResponse }
        model.continueWithEmail(); XCTAssertEqual(model.step, .email)
        model.email = " person@example.com "; model.continueWithEmail()
        XCTAssertEqual(model.email, "person@example.com"); XCTAssertEqual(model.step, .invitation)
        model.enterInvite(); XCTAssertEqual(model.step, .code)
        model.backToInvitation(); await model.joinWaitlist()
        XCTAssertEqual(model.step, .invitation); XCTAssertNotNil(model.error)
        await model.joinWaitlist(); XCTAssertEqual(model.step, .thanks)
        model.editEmail(); model.email = "another@example.com"
        XCTAssertFalse(model.waitlistJoined); XCTAssertTrue(model.canJoinWaitlist)
    }
    actor FailingThenSuccessfulWaitlist {
        var attempts = 0
        func join(_ email: String) throws { attempts += 1; if attempts == 1 { throw URLError(.notConnectedToInternet) } }
    }
    func testVerifiedRecoveryPersistsOriginalConsentWithoutRegisteringAgain() async throws {
        let request = RegistrationRequest(requestID: UUID(), email: "person@example.com", termsVersion: "old-terms", acceptedAt: Date())
        let disk = store()
        let model = OnboardingModel(policy: policy, store: disk, requestRecoveryCode: { _ in "challenge" }, recover: { challenge, code, _ in
            XCTAssertEqual(challenge, "challenge"); XCTAssertEqual(code, "12345678")
            return RegistrationReceipt(registrationID: "restored", telemetryToken: "token", request: request)
        }) { _ in XCTFail("Recovery must not register again"); throw RegistrationFailure.invalidResponse }
        var finished = false; model.onFinish = { finished = true }
        model.email = "PERSON@example.com"; await model.requestRecovery()
        XCTAssertEqual(model.step, .recovery); XCTAssertFalse(model.canVerify)
        model.recoveryCode = "12345678"; await model.verifyRecovery()
        XCTAssertTrue(finished); XCTAssertEqual(try disk.load()?.request, request)
        XCTAssertEqual(model.receipt?.registrationID, "restored")
    }

    func testEmailOwnsInitialResponderBeforeAnyAsyncSetupCompletes() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = WelcomeEmailTextField(frame: NSRect(x: 20, y: 40, width: 240, height: 24))
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.initialFirstResponder === field)
        window.makeKeyAndOrderFront(nil)
        let editor = try XCTUnwrap(field.currentEditor())
        XCTAssertTrue(window.firstResponder === editor)
        let other = NSTextField(frame: NSRect(x: 20, y: 10, width: 240, height: 24))
        window.contentView?.addSubview(other)
        window.makeFirstResponder(other)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(window.firstResponder === other.currentEditor(), "Returning to window must not steal focus")
    }

    func testDevWelcomeLoadsBundledArtwork() throws {
        let image = try XCTUnwrap(OnboardingArtwork.image)
        XCTAssertGreaterThan(image.size.width, 64)
        XCTAssertTrue(NSImage(named: "BowserWelcome") === image)
    }

    func testHostedSetupRequiresBothPublishedTermsAndConfiguredProvider() {
        let model = OnboardingModel(policy: policy, store: store()) { _ in throw RegistrationFailure.invalidResponse }
        XCTAssertTrue(model.inviteCode.isEmpty)
        model.inviteCode = "fixture"
        model.email = "person@example.com"; model.acceptedTerms = true
        model.applySetup(["hostedAI": true])
        XCTAssertFalse(model.canSubmit)
        let missingTermsMessage = model.setupMessage
        model.applySetup(["termsVersion": "2026-09-15", "hostedAI": false])
        XCTAssertFalse(model.canSubmit)
        XCTAssertNotEqual(model.setupMessage, missingTermsMessage)
        model.applySetup(["termsVersion": "2026-09-15", "hostedAI": true, "limits": ["chat": 40]])
        XCTAssertFalse(model.canSubmit)
        model.acceptedTerms = true
        XCTAssertTrue(model.canSubmit)
        XCTAssertEqual(model.policy.termsVersion, "2026-09-15")
        XCTAssertNil(model.setupMessage)
    }

    func testInviteAndSuccessfulRegistrationAreRequiredToFinish() async {
        let model = OnboardingModel(policy: policy, store: store()) { _ in throw RegistrationFailure.inviteUnavailable }
        var finished = false
        model.onFinish = { finished = true }
        model.email = "person@example.com"; model.acceptedTerms = true
        model.finish()
        XCTAssertFalse(finished)
        XCTAssertFalse(model.canSubmit)
        model.inviteCode = "fixture"
        XCTAssertTrue(model.canSubmit)
        await model.submit()
        XCTAssertFalse(model.completed)
        XCTAssertFalse(finished)
        XCTAssertEqual(model.error, RegistrationFailure.inviteUnavailable.errorDescription)
    }

    func testJoiningWaitlistDoesNotActivateOrRequireHostedAI() async {
        let model = OnboardingModel(policy: policy, store: store(), waitlist: { email in
            XCTAssertEqual(email, "person@example.com")
        }) { _ in XCTFail("Waitlist must not register"); throw RegistrationFailure.invalidResponse }
        model.hostedAvailable = false
        model.email = " person@example.com "
        XCTAssertTrue(model.canJoinWaitlist)
        await model.joinWaitlist()
        XCTAssertTrue(model.waitlistJoined)
        XCTAssertFalse(model.completed)
        XCTAssertFalse(model.canJoinWaitlist)
    }

    func testEmailAndExplicitConsentAreBothRequired() async {
        let model = OnboardingModel(policy: policy, store: store()) { _ in
            XCTFail("Invalid forms must not submit"); throw RegistrationFailure.invalidResponse
        }
        XCTAssertFalse(model.acceptedTerms)
        for bad in ["", "a", "a@", "a@b", "a@@b.com", "a b@example.com", "a@example..com"] {
            model.email = bad; model.acceptedTerms = true
            XCTAssertFalse(model.canSubmit, bad)
            await model.submit()
        }
        model.inviteCode = "fixture"
        model.email = " Person+tag@example.com \n"
        model.acceptedTerms = false
        XCTAssertFalse(model.canSubmit)
        await model.submit()
        model.acceptedTerms = true
        XCTAssertTrue(model.canSubmit)
        XCTAssertEqual(OnboardingModel.normalizedEmail(model.email), "Person+tag@example.com")
    }

    func testRegistrationHandsOffAfterSavingReceiptAndClosingSetup() async throws {
        let disk = store()
        let model = OnboardingModel(policy: policy, store: disk) {
            RegistrationReceipt(registrationID: "registered", telemetryToken: "fixture-token", request: $0)
        }
        var events: [String] = []
        model.onFinish = { events.append("closed") }
        model.onRegistered = {
            XCTAssertNotNil(try? disk.load())
            events.append("guide")
        }
        model.inviteCode = "fixture"
        model.email = "person@example.com"
        await model.submit()
        XCTAssertTrue(events.isEmpty, "No handoff before Terms acceptance")
        model.acceptedTerms = true
        await model.submit()
        XCTAssertEqual(events, ["closed", "guide"])
        await model.submit()
        XCTAssertEqual(events, ["closed", "guide"], "Repeated submit must not open another guide")
    }

    func testSuccessfulResponsePersistsVersionedReceiptPrivately() async throws {
        let disk = store()
        let model = OnboardingModel(policy: policy, store: disk) {
            RegistrationReceipt(registrationID: "fixture-id", telemetryToken: "fixture-token", request: $0)
        }
        model.inviteCode = "fixture"
        model.email = " person@example.com "; model.acceptedTerms = true
        await model.submit()
        let receipt = try XCTUnwrap(model.receipt)
        XCTAssertEqual(receipt.request.email, "person@example.com")
        XCTAssertEqual(receipt.request.termsVersion, policy.termsVersion)
        XCTAssertEqual(try disk.load(), receipt)
        let mode = try FileManager.default.attributesOfItem(atPath: disk.file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertFalse(model.canSubmit)
        XCTAssertNil(model.error)
    }

    actor FailingThenSuccessfulService {
        var requests: [RegistrationRequest] = []
        func submit(_ request: RegistrationRequest) throws -> RegistrationReceipt {
            requests.append(request)
            if requests.count == 1 { throw RegistrationFailure.invalidResponse }
            return RegistrationReceipt(registrationID: "fixture", telemetryToken: "fixture-token", request: request)
        }
        func captured() -> [RegistrationRequest] { requests }
    }

    func testRetryKeepsDraftConsentAndIdempotencyIdentity() async throws {
        let disk = store(), service = FailingThenSuccessfulService()
        let model = OnboardingModel(policy: policy, store: disk) { try await service.submit($0) }
        model.inviteCode = "fixture"
        model.email = "person@example.com"; model.acceptedTerms = true
        await model.submit()
        XCTAssertNil(model.receipt)
        XCTAssertNil(try disk.load())
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.canSubmit)
        XCTAssertTrue(model.acceptedTerms)
        await model.submit()
        let sent = await service.captured()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0], sent[1])
        XCTAssertNotNil(model.receipt)
    }

    func testPendingRedemptionSurvivesRelaunch() async throws {
        let disk = store(), service = FailingThenSuccessfulService()
        let first = OnboardingModel(policy: policy, store: disk) { try await service.submit($0) }
        first.email = "person@example.com"; first.inviteCode = "fixture"; first.acceptedTerms = true
        await first.submit()
        XCTAssertNotNil(disk.loadPending())
        let retry = OnboardingModel(policy: policy, store: disk) { try await service.submit($0) }
        XCTAssertTrue(retry.canSubmit)
        await retry.submit()
        let sent = await service.captured()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0], sent[1])
        XCTAssertTrue(retry.completed)
        XCTAssertNil(disk.loadPending())
    }

    func testMismatchedReceiptCannotCompleteSetup() async throws {
        let disk = store()
        let model = OnboardingModel(policy: policy, store: disk) { request in
            let other = RegistrationRequest(requestID: UUID(), email: request.email,
                termsVersion: request.termsVersion, acceptedAt: request.acceptedAt)
            return RegistrationReceipt(registrationID: "wrong-request", telemetryToken: "fixture-token", request: other)
        }
        model.inviteCode = "fixture"
        model.email = "person@example.com"; model.acceptedTerms = true
        await model.submit()
        XCTAssertNil(model.receipt)
        XCTAssertNil(try disk.load())
        XCTAssertNotNil(model.error)
    }

    func testTransportRejectsInsecureEndpointWithoutSending() async {
        let request = RegistrationRequest(requestID: UUID(), email: "person@example.com",
            termsVersion: "test", acceptedAt: Date())
        do {
            _ = try await RegistrationService(endpoint: URL(string: "http://example.invalid/register")!).submit(request)
            XCTFail("Plain HTTP must not send registration data")
        } catch { }
    }

    func testRenderWelcomeAndReady() throws {
        guard let directory = ProcessInfo.processInfo.environment["BOWSER_ONBOARDING_RENDER"] else {
            throw XCTSkip("Optional native render")
        }
        _ = NSApplication.shared
        let model = OnboardingModel(policy: policy, store: store()) { _ in throw RegistrationFailure.invalidResponse }
        for populated in [false, true] {
            model.email = populated ? "person@example.com" : ""
            model.acceptedTerms = populated
            let view = NSHostingView(rootView: OnboardingView(model: model, finished: {}))
            view.frame = NSRect(x: 0, y: 0, width: 552, height: 520)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(populated ? "ready.png" : "welcome.png"))
        }
    }
}
