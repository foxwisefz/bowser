import Foundation
import Darwin
import HistoryCore

/// Pipe RPC is serialized on a utility queue, with a deadline and bounded reply.
/// Terminating this helper never touches WebKit or the backend runtime.
final class HistoryWorkerClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Bowser.history", qos: .utility)
    private let lock = NSLock()
    private var process: Process?
    private var generation = 0
    private var input: FileHandle?
    private var output: FileHandle?
    private var idleStop: DispatchWorkItem?
    private let directory: URL
    private let model: URL
    private let executableOverride: URL?
    init(directory: URL, model: URL, executable: URL? = nil) { self.directory = directory; self.model = model; self.executableOverride = executable }
    deinit { stop() }
    func stop() {
        stop(ifGeneration: nil)
    }
    private func stop(ifGeneration expected: Int?) {
        lock.lock()
        guard expected == nil || generation == expected else { lock.unlock(); return }
        let current = process; process = nil; generation += 1; lock.unlock()
        if current?.isRunning == true { current?.terminate() }
    }
    private func start(generation expected: Int) throws -> Process {
        lock.lock(); let current = process; let valid = generation == expected; lock.unlock()
        guard valid else { throw Failure.closed }
        if let current, current.isRunning { return current }
        let appWorker = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/BowserHistoryWorker")
        let developmentWorker = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("BowserHistoryWorker")
        let executable = executableOverride ?? (FileManager.default.isExecutableFile(atPath: appWorker.path) ? appWorker : developmentWorker)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure.unavailable }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable
        child.arguments = [directory.path, model.path]
        child.standardInput = stdin; child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        child.qualityOfService = .utility
        try child.run()
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        lock.lock()
        guard generation == expected else { lock.unlock(); child.terminate(); throw Failure.closed }
        process = child; lock.unlock()
        return child
    }
    enum Failure: Error { case unavailable, closed, invalidReply }
    func send(_ request: HistoryRequest) async throws -> HistoryResponse {
        let expected = lock.withLock { generation }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                idleStop?.cancel()
                defer {
                    let stop = DispatchWorkItem { [weak self] in self?.stop(ifGeneration: expected) }
                    idleStop = stop
                    queue.asyncAfter(deadline: .now() + 30, execute: stop)
                }
                do {
                    let child = try start(generation: expected)
                    let deadline = DispatchWorkItem { if child.isRunning { child.terminate() } }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 25, execute: deadline)
                    defer { deadline.cancel() }
                    var bytes = try JSONEncoder().encode(request); bytes.append(10)
                    try input?.write(contentsOf: bytes)
                    guard let output else { throw Failure.closed }
                    var reply = Data()
                    var buffer = [UInt8](repeating: 0, count: 8192)
                    // A single request is in flight, so each line has one owner.
                    while reply.last != 10 {
                        // FileHandle.read(upToCount:) can wait to fill the requested
                        // length on a pipe. POSIX read returns the available reply.
                        let count = Darwin.read(output.fileDescriptor, &buffer, buffer.count)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw Failure.closed }
                        reply.append(contentsOf: buffer.prefix(count))
                        guard reply.count <= 4_000_000 else { throw Failure.invalidReply }
                    }
                    let response = try JSONDecoder().decode(HistoryResponse.self, from: reply)
                    continuation.resume(returning: response)
                } catch { stop(ifGeneration: expected); continuation.resume(throwing: error) }
            }
        }
    }
}
