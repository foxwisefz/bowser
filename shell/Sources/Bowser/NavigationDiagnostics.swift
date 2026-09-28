import Foundation
import Network

/// Local evidence, not a diagnosis: a satisfied path does not prove the server is reachable.
struct NavigationNetworkSnapshot: Codable, Sendable {
    var status = "unknown"
    var interfaces: [String] = []
    var dns: Bool? = nil
    var expensive: Bool? = nil
    var constrained: Bool? = nil
}

@MainActor
final class NavigationNetworkMonitor {
    static let shared = NavigationNetworkMonitor()
    private let monitor = NWPathMonitor()
    private(set) var snapshot = NavigationNetworkSnapshot()
    private(set) var revision = 0
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = NavigationNetworkSnapshot(
                status: path.status == .satisfied ? "satisfied" : path.status == .unsatisfied ? "unsatisfied" : "requires_connection",
                interfaces: [NWInterface.InterfaceType.wifi, .wiredEthernet, .cellular, .loopback, .other]
                    .filter { path.usesInterfaceType($0) }.map { String(describing: $0) },
                dns: path.supportsDNS, expensive: path.isExpensive, constrained: path.isConstrained)
            Task { @MainActor [weak self] in
                self?.snapshot = snapshot
                self?.revision += 1
            }
        }
        monitor.start(queue: DispatchQueue(label: "bowser.navigation.network"))
    }
}

struct NavigationDiagnosticError: Codable {
    let domain: String
    let code: Int
    var streamErrorDomain: Int?
    var streamErrorCode: Int?
    static func chain(_ error: NSError) -> [Self] {
        var result: [Self] = []
        var current: NSError? = error
        while let item = current, result.count < 5 {
            // Arbitrary domains/descriptions/userInfo may contain private URL data.
            let known = [NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain,
                         "WKErrorDomain", "WebKitErrorDomain", "kCFErrorDomainCFNetwork", "kCFErrorDomainSystemConfiguration"]
            result.append(Self(domain: known.contains(item.domain) ? item.domain : "other", code: item.code,
                streamErrorDomain: (item.userInfo["_kCFStreamErrorDomainKey"] as? NSNumber)?.intValue,
                streamErrorCode: (item.userInfo["_kCFStreamErrorCodeKey"] as? NSNumber)?.intValue))
            current = item.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }
}

struct NavigationDiagnosticRecord: Codable {
    var timestamp = Date()
    var appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    var osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    var sessionID = NavigationDiagnosticLog.sessionID
    var webviewID: UInt64?
    var profileID: String?
    var isLoading: Bool?
    var estimatedProgress: Double?
    var httpStatus: Int?
    var visible: Bool?
    let navigationID: UUID
    let stage: String
    let elapsedMilliseconds: Int?
    let redirects: Int
    let networkAtStart: NavigationNetworkSnapshot
    let networkAtFailure: NavigationNetworkSnapshot
    let networkUpdates: Int
    let errors: [NavigationDiagnosticError]
}

/// Tracks by navigation identity so an older callback cannot borrow a newer load's timing.
struct NavigationDiagnosticTrace {
    private var id: ObjectIdentifier?
    private var recordID = UUID()
    private var started: TimeInterval?
    private var network = NavigationNetworkSnapshot()
    private var revision = 0
    private var redirects = 0
    mutating func start(_ navigation: AnyObject, now: TimeInterval, network: NavigationNetworkSnapshot, revision: Int) {
        id = ObjectIdentifier(navigation); recordID = UUID(); started = now
        self.network = network; self.revision = revision; redirects = 0
    }
    func isCurrent(_ navigation: AnyObject?) -> Bool {
        navigation.map { id == ObjectIdentifier($0) } ?? false
    }
    mutating func redirect(_ navigation: AnyObject) {
        if id == ObjectIdentifier(navigation) { redirects += 1 }
    }
    func event(_ navigation: AnyObject? = nil, stage: String, now: TimeInterval,
               network current: NavigationNetworkSnapshot, revision currentRevision: Int) -> NavigationDiagnosticRecord {
        let matches = navigation.map { id == ObjectIdentifier($0) } ?? (id != nil)
        return NavigationDiagnosticRecord(navigationID: matches ? recordID : UUID(), stage: stage,
            elapsedMilliseconds: matches ? started.map { Int(max(0, now - $0) * 1000) } : nil,
            redirects: matches ? redirects : 0, networkAtStart: matches ? network : NavigationNetworkSnapshot(),
            networkAtFailure: current, networkUpdates: matches ? max(0, currentRevision - revision) : 0,
            errors: [])
    }
    func failure(_ navigation: AnyObject?, error: NSError, stage: String, now: TimeInterval,
                 network current: NavigationNetworkSnapshot, revision currentRevision: Int) -> NavigationDiagnosticRecord {
        let matches = navigation.map { id == ObjectIdentifier($0) } ?? false
        return NavigationDiagnosticRecord(navigationID: matches ? recordID : UUID(), stage: stage,
            elapsedMilliseconds: matches ? started.map { Int(max(0, now - $0) * 1000) } : nil,
            redirects: matches ? redirects : 0, networkAtStart: matches ? network : NavigationNetworkSnapshot(),
            networkAtFailure: current, networkUpdates: matches ? max(0, currentRevision - revision) : 0,
            errors: NavigationDiagnosticError.chain(error))
    }
}

/// Serial, private, bounded files. No network uploads and no browsing URLs or text.
enum NavigationDiagnosticLog {
    static let sessionID = UUID()
    private static let queue = DispatchQueue(label: "bowser.navigation.diagnostics", qos: .utility)
    @MainActor static func record(_ record: NavigationDiagnosticRecord) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        let root = BowserPaths.home.appendingPathComponent("diagnostics")
        queue.async {
            do { try append(data, directory: root) }
            catch { NSLog("Bowser: could not persist navigation diagnostics") }
        }
    }
    static func append(_ data: Data, directory: URL, limit: Int = 262_144) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("navigation-failures.jsonl")
        var contents = (try? Data(contentsOf: file)) ?? Data()
        if contents.count + data.count + 1 > limit {
            let previous = directory.appendingPathComponent("navigation-failures.previous.jsonl")
            try contents.write(to: previous, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous.path)
            contents = Data()
        }
        contents.append(data); contents.append(0x0a)
        try contents.write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
