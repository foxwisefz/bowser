import AppKit
import SwiftUI
import Combine

/// Stable state shared by host services and successive signed screen renderers.
@MainActor public final class BrowserScreenContext: ObservableObject {
    public static var contexts: [String: BrowserScreenContext] = [:]
    public let id = UUID().uuidString
    public let kind: String
    public let model: AnyObject
    @Published public var values: [String: Any] = [:]
    private var observation: AnyCancellable?
    public init<Model: ObservableObject>(kind: String, model: Model) where Model.ObjectWillChangePublisher == ObservableObjectPublisher {
        self.kind = kind; self.model = model
        observation = model.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }
    public func binding<Value>(_ key: String, default value: Value) -> Binding<Value> {
        Binding(get: { self.values[key] as? Value ?? value }, set: { self.values[key] = $0 })
    }
}

public enum OnboardingStep: String, CaseIterable { case email, invitation, code, recovery, thanks }

@MainActor public protocol OnboardingPresentation: AnyObject {
    var recoveryCode: String { get set }
    var canVerify: Bool { get }
    func requestRecovery() async
    func verifyRecovery() async
    var step: OnboardingStep { get }
    var canContinue: Bool { get }
    func continueWithEmail()
    func enterInvite()
    func editEmail()
    func backToInvitation()
    var inviteCode: String { get set }
    var joiningWaitlist: Bool { get set }
    var waitlistJoined: Bool { get }
    var canJoinWaitlist: Bool { get }
    func joinWaitlist() async
    func refreshSetup() async
    var hostedAvailable: Bool { get }
    var allowance: Int { get }
    var setupMessage: String? { get }
    var email: String { get set }
    var acceptedTerms: Bool { get set }
    var submitting: Bool { get }
    var error: String? { get }
    var completed: Bool { get }
    var termsURL: URL { get }
    var canSubmit: Bool { get }
    func submit() async
    func finish()
}

@MainActor public protocol ExternalProfilePresentation: AnyObject {
    var choices: [ProfileDisplay] { get }
    var destination: String { get }
    var linkCount: Int { get }
    var error: String? { get }
    func choose(_ id: String)
    func cancel()
}
