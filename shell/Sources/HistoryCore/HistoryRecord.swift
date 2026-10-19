import Foundation
import CryptoKit

public enum HistoryModel {
    public static let version = "embeddinggemma-2-440m-512-v1"
    public static let dimensions = 512
    public static let bytes: Int64 = 387_710_976
    public static let sha256 = "92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0"
    public static let url = URL(string: "https://huggingface.co/litert-community/embeddinggemma-2-text-vision-440m-litert-lm/resolve/e301f74d5551b0c2641bd5cb4652a76239d5c5f8/embeddinggemma-2-text-vision-440m.litertlm")!
    public static func query(_ text: String) -> String { "task: search result | query: " + String(text.prefix(512)) }
    public static func document(title: String, text: String) -> String {
        "title: \(title.isEmpty ? "none" : String(title.prefix(180))) | text: \(String(text.prefix(2400)))"
    }
}

public struct HistoryRecord: Codable, Sendable, Equatable {
    public var url: String
    public var title: String
    public var text: String
    public var appearance: String
    public var image: Data?
    public var seen: Date
    public init(url: String, title: String, text: String, appearance: String = "", image: Data? = nil, seen: Date = Date()) {
        self.url = url; self.title = title; self.text = text; self.appearance = appearance; self.image = image; self.seen = seen
    }
    public var content: String { [text, appearance].filter { !$0.isEmpty }.joined(separator: "\n") }
    public var key: String { Self.digest(url + "\n" + content + "\n" + (image.map { Self.digest($0) } ?? "")) }
    public static func digest(_ text: String) -> String { digest(Data(text.utf8)) }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public func validated(requireContent: Bool = true) -> Self? {
        guard let url = URL(string: url), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              self.url.utf8.count <= 4096, title.utf8.count <= 1000,
              text.utf8.count <= 12000, appearance.utf8.count <= 2000,
              (image?.count ?? 0) <= 128_000, !requireContent || !content.isEmpty || image != nil else { return nil }
        return self
    }
}

public struct HistoryHit: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var record: HistoryRecord
    public var score: Double
    public init(id: String, record: HistoryRecord, score: Double) { self.id = id; self.record = record; self.score = score }
}
public struct HistoryStats: Codable, Sendable {
    public var records: Int
    public var bytes: Int64
    public var pending: Int
    public init(records: Int, bytes: Int64, pending: Int) { self.records = records; self.bytes = bytes; self.pending = pending }
}
public struct HistoryRequest: Codable, Sendable {
    public var operation: String
    public var profile: String
    public var record: HistoryRecord?
    public var query: String?
    public var key: String?
    public var days: Int
    public init(_ operation: String, profile: String, record: HistoryRecord? = nil, query: String? = nil, key: String? = nil, days: Int = 90) {
        self.operation = operation; self.profile = profile; self.record = record; self.query = query; self.key = key; self.days = days
    }
}
public struct HistoryResponse: Codable, Sendable {
    public var hits: [HistoryHit] = []
    public var stats: HistoryStats?
    public var error: String?
    public var indexed: Bool = false
    public init() {}
}

public enum HistoryPolicy {
    public static func permits(_ raw: String, exclusions: [String]) -> Bool {
        guard let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return false }
        return !exclusions.contains { rule in
            let domain = rule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
        }
    }
    public static func normalizedExclusions(_ text: String) -> [String] {
        Array(Set(text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { value in
            let value = String(value).lowercased()
            let host = URL(string: value.contains("://") ? value : "https://" + value)?.host
            return host?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        })).sorted()
    }
}
