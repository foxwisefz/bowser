import Foundation

public struct ModSmithTurn: Decodable, Identifiable {
    public let id: String
    public let role: String
    public let text: String
    public var status: String?
    public var notes: String?
    public var checks: [String]?
    public var displayText: String {
        text.replacingOccurrences(of: "NEEDS THE RESIDENT AGENT:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct ModSmithNextStep: Decodable {
    public let title: String
    public let detail: String
    public let action: String
}

public struct ModSmithUsage: Decodable {
    public let entryPoint: String
    public let steps: [String]
    public let tips: String
    enum CodingKeys: String, CodingKey { case entryPoint = "entry_point", steps, tips }
}

public struct ModSmithProject: Decodable, Identifiable {
    public let id: String
    public let name: String
    public let scope: String
    public let url: String
    public let status: String
    public let summary: String
    public let turns: [ModSmithTurn]
    public let files: [String]
    public let favicon: String?
    public let enabled: Bool
    public let canUndo: Bool
    public let undoLabel: String?
    public let nextStep: ModSmithNextStep?
    public let repairNotice: String?
    public let usage: ModSmithUsage?
    enum CodingKeys: String, CodingKey {
        case id, name, scope, url, status, summary, turns, files, enabled, favicon, usage
        case canUndo = "can_undo", undoLabel = "undo_label"
        case nextStep = "next_step", repairNotice = "repair_notice"
    }
    public var scopeLabel: String {
        switch scope {
        case "browser": return "Across Bowser"
        case "app": return "Only this app"
        default: return "\(URL(string: url)?.host ?? url) · includes subdomains"
        }
    }
    public var canContinue: Bool {
        ["partial", "needs_help", "failed", "interrupted"].contains(status)
    }
    public var canEnableAndTest: Bool {
        status != "working" && !enabled && !files.isEmpty
    }
    public var needsNextStep: Bool {
        (status == "needs_help" && !canEnableAndTest) || (canContinue && nextStep != nil)
    }
    public var statusLabel: String {
        if canEnableAndTest && ["needs_help", "disabled"].contains(status) { return "Disabled" }
        switch status {
        case "working": return "Working"
        case "partial": return "Unfinished"
        case "failed": return "Needs attention"
        case "needs_help": return "Needs your input"
        case "interrupted": return "Interrupted"
        case "restored": return files.isEmpty ? "Removed" : "Restored"
        case "ready": return "Ready to edit"
        default: return enabled ? "Active" : "Disabled"
        }
    }
}

public struct ModSmithExisting: Decodable, Identifiable {
    public let path: String
    public let name: String
    public let scope: String
    public let favicon: String?
    public let enabled: Bool
    public var id: String { path }
}

public struct ModSmithSnapshot: Decodable {
    public init() {}
    public var available_mods: [ModSmithExisting]? = nil
    public var projects: [ModSmithProject] = []
    public var selected: String?
    public var busy = false
    public var accepted: String?
    public var error: String?
    public var progress: [String] = []
    public var stage = "Inspecting page"
}

@MainActor public protocol ModSmithPresentation: AnyObject {
    var isSiteApp: Bool { get }
    var snapshot: ModSmithSnapshot { get }
    var draft: String { get set }
    var scope: String { get set }
    var scopeChoice: ModScopeChoice { get }
    var connectionError: String? { get }
    var targetURL: String { get }
    var project: ModSmithProject? { get }
    func action(_ action: String, project: String?, path: String?)
    func submit()
}
public extension ModSmithPresentation {
    func action(_ action: String, project: String? = nil, path: String? = nil) {
        self.action(action, project: project, path: path)
    }
}
