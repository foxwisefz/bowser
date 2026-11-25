import AppKit
import BackendRuntime
import Darwin
import XCTest
@testable import Bowser

private final class SocketFixture: @unchecked Sendable {
    // Ownership of local transfers to the reader or writer under test.
    let local: Int32
    let remote: Int32

    init() throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw RuntimeFailure("socketpair failed") }
        local = fds[0]
        remote = fds[1]
        var bytes: Int32 = 8192
        setsockopt(local, SOL_SOCKET, SO_SNDBUF, &bytes, socklen_t(MemoryLayout.size(ofValue: bytes)))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(remote, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }

    deinit { Darwin.close(remote) }

    func readBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let n = Darwin.read(remote, bytes.baseAddress!.advanced(by: offset), count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw RuntimeFailure("test peer disconnected or timed out") }
                offset += n
            }
        }
        return data
    }

    func readFrame() throws -> Data {
        let length = try readBytes(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length <= SocketFrameWriter.maximumPayloadBytes else { throw RuntimeFailure("invalid header") }
        return try readBytes(length)
    }
}

@MainActor
final class BrainBridgeTransportTests: XCTestCase {
    private func connect(_ bridge: BrainBridge) async throws -> SocketFixture {
        _ = NSApplication.shared
        let socket = try SocketFixture()
        let fd = socket.local
        Task.detached { bridge.serveConnection(fd) }
        let first = try await Task.detached { try socket.readFrame() }.value
        XCTAssertEqual(try json(first)["op"] as? String, "hello")
        return socket
    }

    func testAppKitCanEnqueueQuitBehindLargeReplyBeforeReceiverReads() async throws {
        let bridge = BrainBridge()
        let socket = try await connect(bridge)
        let watchdog = Task.detached {
            try await Task.sleep(for: .seconds(3))
            shutdown(socket.remote, SHUT_RDWR)
        }
        defer { watchdog.cancel() }
        let large = String(repeating: "A", count: 1 << 20)
        let start = ProcessInfo.processInfo.systemUptime
        bridge.send(["op": "js_result", "value": large])
        bridge.send(["op": "app_quit"])
        let duration = (ProcessInfo.processInfo.systemUptime - start) * 1000
        // The receiver can only start after both main-actor sends return.
        let received = try await Task.detached { try [socket.readFrame(), socket.readFrame()] }.value
        XCTAssertEqual(try json(received[0])["value"] as? String, large)
        XCTAssertEqual(try json(received[1])["op"] as? String, "app_quit")
        print("1 MiB JS reply and app_quit admitted in \(duration) ms with peer reads gated")
    }

    func testOverflowDisconnectsPartialFrameAndBoundsBytesAndFrameCount() async throws {
        let payload = Data(repeating: 0x53, count: 128 * 1024)
        for (bytes, frames) in [(payload.count + 4, 10), (payload.count * 2, 1)] {
            let socket = try SocketFixture()
            let writer = SocketFrameWriter(fd: socket.local, byteLimit: bytes, frameLimit: frames)
            defer { writer.finishReading() }
            try writer.send(payload)
            // Reading just the header ensures the frame is in flight and the
            // remainder cannot fit in the local socket's small send buffer.
            XCTAssertEqual(try socket.readBytes(4), Data([0, 2, 0, 0]))
            XCTAssertThrowsError(try writer.send(Data([1])))
            XCTAssertFalse(writer.isOpen)
            await writer.finishWrites()
            XCTAssertThrowsError(try socket.readBytes(payload.count))
            XCTAssertThrowsError(try writer.send(Data([2])))
        }
    }

    func testWriteTimeoutDisconnectsBeforeNextFrameAndInvalidJSONKeepsConnection() async throws {
        let socket = try SocketFixture()
        let writer = SocketFrameWriter(fd: socket.local, timeout: 1)
        defer { writer.finishReading() }
        XCTAssertThrowsError(try writer.sendJSON(["nested": [NSObject()]]))
        XCTAssertTrue(writer.isOpen)
        let payload = Data(repeating: 0x53, count: 128 * 1024)
        try writer.send(payload)
        try writer.send(Data([1]))
        XCTAssertEqual(try socket.readBytes(4), Data([0, 2, 0, 0]))
        await writer.finishWrites()
        XCTAssertFalse(writer.isOpen)
        XCTAssertThrowsError(try socket.readBytes(payload.count))
    }

    func testDeferredReplyCannotReachReplacementWithSameRequestID() async throws {
        let bridge = BrainBridge()
        let first = try await connect(bridge)
        let oldReply = bridge.replySender()
        shutdown(first.remote, SHUT_RDWR)
        let replacement = try await connect(bridge)
        oldReply(["op": "js_result", "id": 1, "value": "stale"])
        bridge.replySender()(["op": "js_result", "id": 1, "value": "current"])
        let reply = try await Task.detached { try replacement.readFrame() }.value
        XCTAssertEqual(try json(reply)["value"] as? String, "current")
    }

    func testFinalQuitAcknowledgementSurvivesImmediatePeerClose() async throws {
        _ = NSApplication.shared
        let bridge = BrainBridge()
        let socket = try SocketFixture()
        let ended = DispatchSemaphore(value: 0)
        let fd = socket.local
        DispatchQueue.global().async {
            bridge.serveConnection(fd)
            ended.signal()
        }
        let previous = BackendLifecycle.shared.quitAcknowledged
        BackendLifecycle.shared.quitAcknowledged = false
        defer { BackendLifecycle.shared.quitAcknowledged = previous }
        let payload = Data(#"{"op":"quit_ready"}"#.utf8)
        var size = UInt32(payload.count).bigEndian
        let frame = withUnsafeBytes(of: &size) { Data($0) } + payload
        XCTAssertEqual(frame.withUnsafeBytes { Darwin.write(socket.remote, $0.baseAddress!, $0.count) }, frame.count)
        shutdown(socket.remote, SHUT_RDWR)
        // Simulate a busy AppKit thread: the socket reader observes EOF before
        // the main actor handles the acknowledgement that preceded it.
        XCTAssertEqual(ended.wait(timeout: .now() + 3), .success)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertTrue(BackendLifecycle.shared.quitAcknowledged)
        XCTAssertFalse(bridge.isConnected)
    }
}
