import Foundation
import Network

/// Loopback-only pages with controlled response delays and cache headers.
final class BrowserFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var port: UInt16?
    var origin: String? {
        lock.lock(); defer { lock.unlock() }
        return port.map { "http://127.0.0.1:\($0)" }
    }
    func requests(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }; return counts[path, default: 0]
    }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            lock.lock(); port = listener.port?.rawValue; lock.unlock()
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.receive(connection, data: Data())
        }
        listener.start(queue: .global())
    }
    func stop() { listener.cancel() }
    deinit { listener.cancel() }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] bytes, _, done, error in
            guard let self, let bytes, error == nil else { connection.cancel(); return }
            let data = data + bytes
            guard data.count < 65536 else { connection.cancel(); return }
            let request = String(decoding: data, as: UTF8.self)
            guard request.contains("\r\n\r\n") else {
                if !done { self.receive(connection, data: data) } else { connection.cancel() }
                return
            }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            lock.lock(); counts[path, default: 0] += 1; lock.unlock()
            let image = path == "/delayed-image"
            let body = image ? "<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20'><rect width='20' height='20' fill='red'/></svg>" : """
            <!doctype html><html><head><title>Browser fixture</title>
            <style>html { background:#203040;color:white } body { margin:24px } p { height:32px }</style></head>
            <body><h1>Ready to read</h1>\(path == "/slow-image" ? "<img src='/delayed-image'>" : "")
            \((0..<200).map { "<p>Row \($0)</p>" }.joined())</body></html>
            """
            let type = image ? "image/svg+xml" : "text/html"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: max-age=3600\r\nConnection: close\r\n\r\n\(body)"
            let delay = image ? 2.0 : path == "/slow" ? 0.5 : 0
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
