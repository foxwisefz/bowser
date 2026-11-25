import Foundation
import CryptoKit
import HistoryCore

@MainActor final class HistoryModelDownload: ObservableObject {
    static let shared = HistoryModelDownload()
    static var directory: URL { BowserPaths.home.appendingPathComponent("models/history", isDirectory: true) }
    static var file: URL { directory.appendingPathComponent(HistoryModel.version + ".litertlm") }
    @Published private(set) var downloading = false
    @Published private(set) var ready = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private init() {
        ready = (try? Self.file.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(HistoryModel.bytes)
            && (try? String(contentsOf: Self.file.appendingPathExtension("verified"), encoding: .utf8)) == HistoryModel.sha256
    }
    func download() {
        guard !ready, !downloading else { return }
        downloading = true; error = nil
        let destination = Self.file
        task = Task {
            do {
                try await Task.detached(priority: .utility) {
                    let request = URLRequest(url: HistoryModel.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 300)
                    let (temporary, response) = try await URLSession.shared.download(for: request)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard (response as? HTTPURLResponse)?.statusCode == 200,
                          (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(HistoryModel.bytes) else { throw URLError(.badServerResponse) }
                    let handle = try FileHandle(forReadingFrom: temporary)
                    defer { try? handle.close() }
                    var hash = SHA256()
                    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
                    guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == HistoryModel.sha256 else { throw URLError(.cannotDecodeContentData) }
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    try HistoryModel.sha256.write(to: destination.appendingPathExtension("verified"), atomically: true, encoding: .utf8)
                }.value
                ready = true
            } catch { self.error = "The search model could not be downloaded. Check your connection and try again." }
            downloading = false; task = nil
            HistoryController.shared.refresh()
        }
    }
}
