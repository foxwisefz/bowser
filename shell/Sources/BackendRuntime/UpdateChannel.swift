import Foundation

/// Channels share update policy, but never adopt each other's generations.
public enum UpdateChannel: String, Sendable {
    case stable, staging
    public init(_ value: String?) { self = value == "staging" ? .staging : .stable }
    public var activePointer: String { self == .staging ? "backend/active-staging.json" : "backend/active.json" }
    public var releases: String { self == .staging ? "releases/staging" : "releases" }
    public var modules: String { self == .staging ? "native-modules/staging" : "native-modules" }
}
