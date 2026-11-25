import Foundation
import Darwin
import BackendRuntime

@MainActor
final class Generation {
    let runtime: URL
    let directory: URL
    var process: Process?
    var lifetimeWriter: FileHandle?
    var writer: Peer?
    var server: Listener?
    var attached = false
    var barriers = Set<Int>()
    init(_ runtime: URL, _ directory: URL) { self.runtime = runtime; self.directory = directory }
    func call(_ op: String, _ values: Message = [:]) async throws -> Message {
        var message = values; message["op"] = op
        return try await request(child(directory, "control.sock"), message, timeout: op == "freeze" ? 0.4 : 1)
    }
    func stop(killImmediately: Bool = false) async {
        if let process, process.isRunning {
            if killImmediately { kill(process.processIdentifier, SIGKILL) } else { process.terminate() }
            let end = ProcessInfo.processInfo.systemUptime + 3
            while process.isRunning && ProcessInfo.processInfo.systemUptime < end {
                await Task.detached { try? await Task.sleep(nanoseconds: 10_000_000) }.value
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            while process.isRunning { await Task.detached { try? await Task.sleep(nanoseconds: 10_000_000) }.value }
        }
        try? lifetimeWriter?.close(); lifetimeWriter = nil
        writer?.close(); writer = nil
        server?.close(); server = nil
        try? remove(directory)
    }
}

@MainActor
final class Host {
    let channel = UpdateChannel(ProcessInfo.processInfo.environment["BOWSER_UPDATE_CHANNEL"])
    let home: URL
    let root: URL
    var runtime: URL
    var active: Generation?
    var children: [Generation] = []
    var nativePeer: Peer?
    var hello: Message?
    var paused = false
    private let stopped: AsyncStream<Void>
    private let stopContinuation: AsyncStream<Void>.Continuation
    var quitting = false {
        didSet { if quitting { operation?.cancel(); stopContinuation.finish() } }
    }
    private struct RPC {
        let peer: Peer
        let id: Int
        let reply: String

        init?(_ message: Message, from peer: Peer) {
            guard let id = message["id"] as? Int else { return nil }
            switch message["op"] as? String {
            case "eval_js", "site_eval", "site_screenshot", "native_screenshot", "page_screenshot", "native_click", "website_layout":
                reply = "js_result"
            case "get_cookies": reply = "cookies_result"
            case "site_app_info": reply = "site_app_info"
            default: return nil
            }
            self.id = id
            self.peer = peer
        }

        func fail() throws {
            try peer.send(["op": reply, "id": id, "ok": false, "value": "not_connected", "error": "not_connected"])
        }
    }
    private var requests: [Int: RPC] = [:]
    var serial = 0
    var operation: Task<Message, Error>?
    var buffer: [Message] = []
    var bufferBytes = 0
    var journalError: Error?
    var signals: [DispatchSourceSignal] = []
    init(_ home: URL, _ runtime: URL) throws {
        self.home = home; self.runtime = runtime; root = child(home, "backend")
        let signal = AsyncStream<Void>.makeStream()
        stopped = signal.stream; stopContinuation = signal.continuation
        try mkdir(root); chmod(root.path, 0o700)
    }
    func boot(_ runtime: URL) async throws -> Generation {
        let meta = try readJSON(child(runtime, "HANDOFF.json"))
        guard meta["protocol"] as? Int == 1, meta["state_schema"] as? Int == 5 else {
            throw RuntimeFailure("incompatible release; waiting for native restart")
        }
        let directory = child(root, "g" + String(UUID().uuidString.prefix(8)))
        try mkdir(directory)
        let gen = Generation(runtime, directory); children.append(gen)
        do {
            gen.server = try Listener(child(directory, "brain.sock")) { peer in
                Task { @MainActor in await self.backend(gen, peer) }
            }
            let process = Process()
            process.executableURL = child(runtime, "brain/bin/bowser_brain")
            process.arguments = ["eval", "BowserBrain.Handoff.run()"]
            var env = ProcessInfo.processInfo.environment
            env.merge(["BOWSER_HOME": home.path, "BOWSER_ROOT": runtime.path,
                       "BOWSER_RELAY_DIR": directory.path, "BOWSER_RELAY_PID": String(getpid()),
                       "BOWSER_RELAY_LIFETIME": "stdin",
                       "BOWSER_NO_SPAWN": "1", "RELEASE_DISTRIBUTION": "none", "RELEASE_TMP": child(directory, "tmp").path]) { _, new in new }
            process.environment = env
            let logPath = child(home, "brain.log")
            let logFD = Darwin.open(logPath.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard logFD >= 0 else { throw RuntimeFailure("cannot open brain log") }
            let log = FileHandle(fileDescriptor: logFD, closeOnDealloc: true)
            let lifetime = Pipe()
            gen.lifetimeWriter = lifetime.fileHandleForWriting
            process.standardInput = lifetime
            process.standardOutput = log; process.standardError = log
            try process.run(); gen.process = process
            try log.close()
            try await until(20) { exists(child(directory, "control.sock")) || !process.isRunning }
            let status = try await gen.call("status")
            guard status["schema"] as? Int == 5 else { throw RuntimeFailure("incompatible state schema") }
            return gen
        } catch {
            await gen.stop(); children.removeAll { $0 === gen }; throw error
        }
    }
    func backend(_ gen: Generation, _ peer: Peer) async {
        gen.writer?.close(); gen.writer = peer
        do {
            try peer.send(gen === active && hello != nil && !paused ? hello! : ["op": "handoff_attached"])
            for try await incoming in peer.messages {
                var message = incoming
                let op = message["op"] as? String ?? ""
                if op == "handoff_attached" { gen.attached = true; continue }
                if op == "handoff_barrier" { if let id = message["id"] as? Int { gen.barriers.remove(id) }; continue }
                guard gen === active, gen.writer === peer else { continue }
                if let rpc = RPC(message, from: peer) {
                    guard nativePeer != nil else { try rpc.fail(); continue }
                    serial += 1; requests[serial] = rpc; message["id"] = serial
                }
                if let nativePeer {
                    do { try nativePeer.send(message) }
                    catch { disconnectNative(nativePeer) }
                }
                if op == "quit_ready" { await nativePeer?.finishWrites(); quitting = true }
            }
        } catch { /* disconnect is handled below */ }
        peer.close()
        requests = requests.filter { $0.value.peer !== peer }
        let disconnected = gen.writer === peer
        if disconnected { gen.writer = nil }
        if disconnected && gen === active && !quitting && !paused {
            // Serialize replacement with updates; an update already in progress
            // will detect this disconnect at its next barrier/control request.
            if operation == nil {
                operation = Task { try await self.recover(gen); return [:] }
                _ = try? await operation?.value; operation = nil
            }
        }
    }
    func recover(_ failed: Generation) async throws {
        guard active === failed, !quitting else { return }
        do {
            paused = true
            await failed.stop(); children.removeAll { $0 === failed }
            let fresh = try await boot(failed.runtime); active = fresh
            _ = try await fresh.call("start")
            try await until(2) { fresh.writer != nil }
            if let hello { try fresh.writer?.send(hello) }
            _ = try drain()
        } catch { print("backend recovery failed: \(error)"); quitting = true; throw error }
    }
    func native() async {
        while !quitting && !Task.isCancelled {
            do {
                let peer = try Peer.connect(child(home, "brain.sock")); nativePeer = peer
                for try await incoming in peer.messages {
                    guard nativePeer === peer else { break }
                    var message = incoming
                    let op = message["op"] as? String ?? ""
                    if op == "hello" {
                        if message["webviews"] == nil, let tabs = message["tabs"] as? [Message] {
                            message["webviews"] = tabs.compactMap { $0["id"] as? Int }
                        }
                        hello = message
                    }
                    else if op == "event" { noteTab(message) }
                    if ["js_result", "cookies_result", "site_app_info"].contains(op), let id = message["id"] as? Int {
                        if let rpc = requests[id], rpc.reply == op {
                            requests.removeValue(forKey: id)
                            if rpc.peer === active?.writer {
                                message["id"] = rpc.id
                                do { try rpc.peer.send(message) }
                                catch { rpc.peer.close() }
                            }
                        }
                        continue
                    }
                    if paused {
                        buffer.append(message)
                        do {
                            var data = try encode(message); data.append(10); bufferBytes += data.count
                            guard bufferBytes <= 16 * 1024 * 1024 else { throw RuntimeFailure("handoff buffer limit exceeded") }
                            let fd = Darwin.open(child(root, "handoff.journal").path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
                            guard fd >= 0 else { throw RuntimeFailure("cannot write handoff journal") }
                            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                            try file.write(contentsOf: data); try file.synchronize(); try file.close()
                        } catch { journalError = error; operation?.cancel() }
                    } else if let writer = active?.writer {
                        do { try writer.send(message) }
                        catch { writer.close() }
                    }
                }
            } catch { /* native listener may not be ready yet */ }
            if let nativePeer { disconnectNative(nativePeer) }
            if !quitting { try? await Task.sleep(nanoseconds: 250_000_000) }
        }
    }
    private func disconnectNative(_ peer: Peer) {
        guard peer === nativePeer else { return }
        peer.close(); nativePeer = nil
        for rpc in requests.values where rpc.peer === active?.writer {
            do { try rpc.fail() }
            catch { rpc.peer.close() }
        }
        requests.removeAll()
    }
    func noteTab(_ message: Message) {
        guard let event = message["event"] as? String else { return }
        if event == "tab_activated" {
            hello?["active"] = message["webview"] as? Int
            return
        }
        guard ["tab_opened", "webview_closed", "url_changed", "title_changed"].contains(event),
              let id = message["webview"] as? Int, let state = hello else { return }
        var tabs = state["tabs"] as? [Message] ?? (state["webviews"] as? [Int] ?? []).map { ["id": $0] }
        switch event {
        case "tab_opened":
            let count = tabs.count
            let lastID = tabs.last?["id"] as? Int
            tabs.removeAll { $0["id"] as? Int == id }
            var tab = message.filter { ["url", "profile", "title", "favicon"].contains($0.key) }; tab["id"] = id; tabs.append(tab)
            if tabs.count == count && lastID == id { hello?["tabs"] = tabs; return }
        case "webview_closed":
            let count = tabs.count
            tabs.removeAll { $0["id"] as? Int == id }
            guard tabs.count != count else { return }
        default:
            guard let index = tabs.firstIndex(where: { $0["id"] as? Int == id }) else { return }
            let key = event == "url_changed" ? "url" : "title"; tabs[index][key] = message[key]
            hello?["tabs"] = tabs
            return
        }
        hello?["tabs"] = tabs
        hello?["webviews"] = tabs.compactMap { $0["id"] as? Int }
    }
    func drain() throws -> Int {
        guard let writer = active?.writer else { throw RuntimeFailure("active backend disconnected") }
        for message in buffer { try writer.send(message) }
        let count = buffer.count; buffer.removeAll(); bufferBytes = 0; paused = false
        do { try Data().write(to: child(root, "handoff.journal")) } catch { print("journal cleanup failed: \(error)") }
        return count
    }
    func update(_ candidateURL: URL) async throws -> Message {
        guard ProcessInfo.processInfo.environment["BOWSER_RUNTIME_PINNED"] != "1" else { throw RuntimeFailure("pinned runtime requires restart") }
        guard !quitting, let old = active, nativePeer != nil else { throw RuntimeFailure("browser is not ready") }
        let runtime = candidateURL.resolvingSymlinksInPath().standardizedFileURL
        guard runtime.deletingLastPathComponent() == child(home, channel.releases).resolvingSymlinksInPath().standardizedFileURL else {
            throw RuntimeFailure("release is outside the installed generations directory")
        }
        if runtime == old.runtime { return ["ok": true, "already_active": true] }
        _ = try await old.call("preflight")
        let candidate = try await boot(runtime)
        if quitting || Task.isCancelled { await candidate.stop(); children.removeAll { $0 === candidate }; throw CancellationError() }
        let started = ProcessInfo.processInfo.systemUptime
        paused = true; journalError = nil
        var committed = false
        do {
            serial += 1; let barrier = serial; old.barriers.insert(barrier)
            guard let writer = old.writer else { throw RuntimeFailure("old backend disconnected") }
            try writer.send(["op": "handoff_barrier", "id": barrier])
            try await until(0.3) { !old.barriers.contains(barrier) }
            let frozen = try await old.call("freeze")
            guard let snapshot = frozen["snapshot"] else { throw RuntimeFailure("missing frozen snapshot") }
            _ = try await candidate.call("restore", ["snapshot": snapshot])
            try await until(0.3) { candidate.attached }
            _ = try await candidate.call("status")
            if let journalError { throw journalError }
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - started < 0.8 else { throw RuntimeFailure("handoff exceeded its time budget") }
            try atomicJSON(child(home, channel.activePointer), ["runtime": runtime.path])
            active = candidate; committed = true
            await old.stop(killImmediately: true); children.removeAll { $0 === old }
            _ = try await candidate.call("commit")
            let count = try drain()
            let result: Message = ["ok": true, "handoff_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000, "buffered_events": count, "runtime": runtime.path]
            try atomicJSON(child(root, "last-update.json"), result)
            return result
        } catch {
            if !committed {
                await candidate.stop(killImmediately: true); children.removeAll { $0 === candidate }
                // Journal failures cancel the update. Rollback must run in a fresh
                // task so cancellation cannot abort resuming the old generation.
                let rollback = Task { @MainActor in
                    _ = try await old.call("resume"); self.active = old
                    let count = try self.drain()
                    try atomicJSON(child(self.root, "last-rollback.json"), ["rollback_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000, "buffered_events": count, "runtime": old.runtime.path])
                }
                do { try await rollback.value }
                catch { quitting = true; print("rollback failed: \(error)") }
            } else {
                // Authority already changed. Never replay into the retired VM.
                let recovery = Task { try await self.recover(candidate) }; _ = try? await recovery.value
            }
            throw error
        }
    }
    func control(_ peer: Peer) async {
        let deadline = Task { try? await Task.sleep(nanoseconds: 2_000_000_000); if !Task.isCancelled { peer.close() } }
        do {
            var iterator = peer.messages.makeAsyncIterator()
            guard let message = try await iterator.next() else { throw RuntimeFailure("empty control request") }
            deadline.cancel()
            let result: Message
            switch message["op"] as? String {
            case "status": result = ["ok": true, "pid": getpid(), "runtime": active?.runtime.path as Any? ?? NSNull(), "implementation": "swift", "channel": channel.rawValue, "live_updates": ProcessInfo.processInfo.environment["BOWSER_RUNTIME_PINNED"] != "1"]
            case "stop": quitting = true; result = ["ok": true]
            case "update":
                guard operation == nil else { throw RuntimeFailure("backend operation already in progress") }
                guard let path = message["runtime"] as? String else { throw RuntimeFailure("runtime required") }
                let task = Task { try await self.update(URL(fileURLWithPath: path)) }; operation = task
                defer { operation = nil }
                result = try await task.value
            default: throw RuntimeFailure("unknown operation")
            }
            try peer.send(result)
        } catch { try? peer.send(["ok": false, "error": String(describing: error)]) }
        deadline.cancel(); await peer.finishWrites(); peer.close()
    }
    func run() async throws {
        let dataLock = try FileLock(child(home, "data-use.lock"), nonblocking: true, shared: true)
        defer { withExtendedLifetime(dataLock) {} }
        guard let lock = try? FileLock(child(root, "owner.lock"), nonblocking: true) else { return }
        defer { withExtendedLifetime(lock) {} }
        // Events from a previous relay epoch have uncertain effects; never replay.
        try Data().write(to: child(root, "handoff.journal"))
        let endpoint = child(root, "host.sock"); try remove(endpoint)
        let server = try Listener(endpoint) { peer in Task { @MainActor in await self.control(peer) } }
        let nativeTask = Task { await self.native() }
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { Task { @MainActor in self.quitting = true } }
            source.resume(); signals.append(source)
        }
        let startup = Task<Message, Error> {
            let pointer = child(self.home, self.channel.activePointer)
            if ProcessInfo.processInfo.environment["BOWSER_RUNTIME_PINNED"] != "1", exists(pointer), let path = try readJSON(pointer)["runtime"] as? String { self.runtime = URL(fileURLWithPath: path) }
            self.active = try await self.boot(self.runtime)
            try await until(20) { self.hello != nil }
            _ = try await self.active!.call("start")
            return [:]
        }
        operation = startup
        var failure: Error?
        do {
            _ = try await startup.value; operation = nil
            for await _ in stopped { break }
        } catch { failure = error }
        quitting = true
        if let operation { operation.cancel(); _ = try? await operation.value }; operation = nil
        nativePeer?.close(); nativeTask.cancel(); await nativeTask.value
        for gen in children { await gen.stop() }
        children.removeAll(); server.close()
        signals.forEach { $0.cancel() }; signals.removeAll()
        if let failure { throw failure }
    }
}
