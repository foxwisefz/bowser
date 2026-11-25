import Darwin
import Foundation

/// Owns one connected socket. Its reader keeps using the descriptor until
/// finishReading(), which arranges the close after all writer work has stopped.
public final class SocketFrameWriter: @unchecked Sendable {
    public static let maximumPayloadBytes = 64 * 1024 * 1024
    private let fd: Int32
    private let queue = DispatchQueue(label: "bowser.socket.write")
    private let lock = NSLock()
    private let byteLimit: Int
    private let frameLimit: Int
    private var pendingBytes = 0
    private var pendingFrames = 0
    private var open = true
    private var readerFinished = false

    public init(fd: Int32, timeout: Int = 5,
                byteLimit: Int = maximumPayloadBytes + 4, frameLimit: Int = 1024) {
        self.fd = fd
        self.byteLimit = byteLimit
        self.frameLimit = frameLimit
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        var deadline = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout.size(ofValue: deadline)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    public var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return open
    }

    public func sendJSON(_ message: Message, options: JSONSerialization.WritingOptions = []) throws {
        guard JSONSerialization.isValidJSONObject(message) else { throw RuntimeFailure("invalid JSON message") }
        try send(JSONSerialization.data(withJSONObject: message, options: options))
    }

    /// Admission is synchronous and includes the frame currently blocked in
    /// write(). On overflow, disconnect so the peer can fail RPCs and resync.
    public func send(_ payload: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard open else { throw RuntimeFailure("socket disconnected") }
        guard payload.count <= Self.maximumPayloadBytes, payload.count + 4 <= byteLimit - pendingBytes,
              pendingFrames < frameLimit else {
            shutdownLocked()
            throw RuntimeFailure("socket write queue exceeded its frame or byte limit")
        }
        pendingBytes += payload.count + 4
        pendingFrames += 1
        queue.async {
            let success = self.isOpen && self.writeFrame(payload)
            self.lock.lock()
            self.pendingBytes -= payload.count + 4
            self.pendingFrames -= 1
            if !success { self.shutdownLocked() }
            self.lock.unlock()
        }
    }

    private func writeFrame(_ payload: Data) -> Bool {
        var size = UInt32(payload.count).bigEndian
        return withUnsafeBytes(of: &size) { header in
            payload.withUnsafeBytes { bytes in
                var parts = [
                    iovec(iov_base: UnsafeMutableRawPointer(mutating: header.baseAddress), iov_len: 4),
                    iovec(iov_base: UnsafeMutableRawPointer(mutating: bytes.baseAddress), iov_len: bytes.count),
                ]
                var written = 0
                while written < 4 + bytes.count {
                    let count: Int
                    if written < 4 {
                        parts[0].iov_base = UnsafeMutableRawPointer(mutating: header.baseAddress!.advanced(by: written))
                        parts[0].iov_len = 4 - written
                        count = writev(fd, &parts, 2)
                    } else {
                        let offset = written - 4
                        count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    }
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { return false }
                    written += count
                }
                return true
            }
        }
    }

    private func shutdownLocked() {
        guard open else { return }
        open = false
        shutdown(fd, SHUT_RDWR)
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        shutdownLocked()
    }

    public func finishReading() {
        lock.lock(); defer { lock.unlock() }
        guard !readerFinished else { return }
        readerFinished = true
        shutdownLocked()
        queue.async { [fd] in Darwin.close(fd) }
    }

    public func finishWrites() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    deinit {
        if !readerFinished { Darwin.close(fd) }
    }
}
