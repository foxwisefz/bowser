import Foundation
import Combine

/// Shared by the omnibar and creation screen. Suggestions never override a user's choice.
@MainActor public final class ModScopeChoice: ObservableObject {
    @Published public private(set) var selected = "site"
    @Published public private(set) var suggested: String?
    @Published public private(set) var checking = false
    @Published public private(set) var host: String?
    public private(set) var manual = false
    public var request: (String, String, String) -> Void = { _, _, _ in }
    private var generation: String?
    private var task: Task<Void, Never>?
    private var prompt = ""
    private var frozen = false
    public init() {}
    public var valid: Bool { selected == "browser" || host != nil }
    public func reset(url: String, selected: String = "site", manual: Bool = false) {
        cancel()
        let parsed = URL(string: url)
        host = ["http", "https"].contains(parsed?.scheme?.lowercased() ?? "") ? parsed?.host : nil
        self.selected = selected; self.manual = manual; suggested = nil; prompt = ""; frozen = false
    }
    public func choose(_ value: String) {
        guard ["site", "browser"].contains(value), value != "site" || host != nil else { return }
        cancel(); selected = value; suggested = nil; manual = true
    }
    public func update(_ text: String) {
        guard !frozen, text != prompt else { return }
        prompt = text; cancel(); suggested = nil
        guard !manual else { return }
        selected = "site"
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 4 else { return }
        let id = UUID().uuidString
        generation = id; checking = true
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, self.generation == id else { return }
            self.request(id, text, self.host ?? "")
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, self.generation == id else { return }
            self.cancel()
        }
    }
    public func receive(id: String, choice: String) {
        guard generation == id, !manual, !frozen else { return }
        cancel()
        guard ["site", "browser"].contains(choice), choice != "site" || host != nil else { return }
        selected = choice; suggested = choice
    }
    public func freeze() { frozen = true; cancel() }
    public func cancel() { task?.cancel(); task = nil; generation = nil; checking = false }
}
