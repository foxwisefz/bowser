import Foundation
import SQLite3
import Accelerate

/// Used by the repository actor and serial helper, each with its own connection.
/// No database work runs on the browser UI thread.
public final class HistoryStore {
    public static let budget: Int64 = 128 * 1024 * 1024
    public static let recordLimit = 10_000
    private var db: OpaquePointer?
    public let path: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(directory: URL, profile: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        path = directory.appendingPathComponent(HistoryRecord.digest(profile) + ".sqlite")
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw Failure.database }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        sqlite3_busy_timeout(db, 1500)
        try execute("PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON; PRAGMA cache_size=-2048; PRAGMA auto_vacuum=FULL; PRAGMA max_page_count=65536;")
        try execute("""
        CREATE TABLE IF NOT EXISTS records (
          id TEXT NOT NULL UNIQUE, url TEXT NOT NULL, title TEXT NOT NULL, text TEXT NOT NULL,
          appearance TEXT NOT NULL, seen REAL NOT NULL, image BLOB, embedding BLOB, image_embedding BLOB, model TEXT);
        CREATE INDEX IF NOT EXISTS recent ON records(seen);
        CREATE INDEX IF NOT EXISTS record_urls ON records(url,seen DESC);
        CREATE INDEX IF NOT EXISTS record_models ON records(model);
        CREATE TABLE IF NOT EXISTS visits (id TEXT PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL, host TEXT NOT NULL, seen REAL NOT NULL, preview BLOB);
        CREATE INDEX IF NOT EXISTS visits_recent ON visits(seen DESC);
        CREATE INDEX IF NOT EXISTS visits_urls ON visits(url);
        CREATE TABLE IF NOT EXISTS capacity_cleanup (
          id INTEGER PRIMARY KEY CHECK(id=1), removed INTEGER NOT NULL, last_removed REAL NOT NULL);
        CREATE VIRTUAL TABLE IF NOT EXISTS words USING fts5(title, text, appearance, url, content='records', content_rowid='rowid');
        CREATE TRIGGER IF NOT EXISTS records_ai AFTER INSERT ON records BEGIN
          INSERT INTO words(rowid,title,text,appearance,url) VALUES(new.rowid,new.title,new.text,new.appearance,new.url); END;
        CREATE TRIGGER IF NOT EXISTS records_ad AFTER DELETE ON records BEGIN
          INSERT INTO words(words,rowid,title,text,appearance,url) VALUES('delete',old.rowid,old.title,old.text,old.appearance,old.url); END;
        """)
        // Populate the normalized host once for content saved before visit logging.
        try transaction {
            let columns = try statement("PRAGMA table_info(records)")
            var hasHost = false
            while sqlite3_step(columns) == SQLITE_ROW { if string(columns, 1) == "host" { hasHost = true } }
            sqlite3_finalize(columns)
            if !hasHost {
                try execute("ALTER TABLE records ADD COLUMN host TEXT NOT NULL DEFAULT ''")
                let rows = try statement("SELECT id,url FROM records")
                var hosts: [(String, String)] = []
                while sqlite3_step(rows) == SQLITE_ROW { hosts.append((string(rows, 0), URL(string: string(rows, 1))?.host?.lowercased() ?? "")) }
                sqlite3_finalize(rows)
                let update = try statement("UPDATE records SET host=? WHERE id=?")
                defer { sqlite3_finalize(update) }
                for (id, host) in hosts { sqlite3_reset(update); bind(host, 1, update); bind(id, 2, update); try step(update) }
            }
        }
    }
    deinit { sqlite3_close(db) }
    public enum Failure: Error { case database, invalidRecord, invalidEmbedding }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.database }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Failure.database }
        return stmt
    }
    private func bind(_ text: String, _ index: Int32, _ stmt: OpaquePointer) { sqlite3_bind_text(stmt, index, text, -1, transient) }
    private func bind(_ data: Data?, _ index: Int32, _ stmt: OpaquePointer) {
        guard let data else { sqlite3_bind_null(stmt, index); return }
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), transient) }
    }
    private func string(_ stmt: OpaquePointer, _ index: Int32) -> String { sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? "" }
    private func data(_ stmt: OpaquePointer, _ index: Int32) -> Data? {
        guard let ptr = sqlite3_column_blob(stmt, index) else { return nil }
        return Data(bytes: ptr, count: Int(sqlite3_column_bytes(stmt, index)))
    }
    private func step(_ stmt: OpaquePointer) throws { guard sqlite3_step(stmt) == SQLITE_DONE else { throw Failure.database } }
    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try work(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func recordCleanup(_ removed: Int, now: Date) throws {
        guard removed > 0 else { return }
        let stmt = try statement("INSERT INTO capacity_cleanup(id,removed,last_removed) VALUES(1,?,?) ON CONFLICT(id) DO UPDATE SET removed=removed+excluded.removed,last_removed=excluded.last_removed")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(removed)); sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970); try step(stmt)
    }

    public func ingest(_ raw: HistoryRecord) throws {
        guard let record = raw.validated() else { throw Failure.invalidRecord }
        let stmt = try statement("INSERT INTO records(id,url,title,text,appearance,seen,image,host) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET seen=MAX(seen,excluded.seen)")
        defer { sqlite3_finalize(stmt) }
        bind(record.key, 1, stmt); bind(record.url, 2, stmt); bind(record.title, 3, stmt)
        bind(record.text, 4, stmt); bind(record.appearance, 5, stmt)
        sqlite3_bind_double(stmt, 6, record.seen.timeIntervalSince1970); bind(record.image, 7, stmt)
        bind(URL(string: record.url)?.host?.lowercased() ?? "", 8, stmt)
        try step(stmt)
    }
    public func prune(days: Int, now: Date = Date(), budget: Int64 = HistoryStore.budget, limit: Int = HistoryStore.recordLimit) throws {
        let expiration = now.addingTimeInterval(-Double(max(1, min(days, 365))) * 86400).timeIntervalSince1970
        try transaction {
            let expired = try statement("DELETE FROM records WHERE seen < ?")
            defer { sqlite3_finalize(expired) }
            sqlite3_bind_double(expired, 1, expiration); try step(expired)
            let expiredVisits = try statement("DELETE FROM visits WHERE seen < ?")
            defer { sqlite3_finalize(expiredVisits) }
            sqlite3_bind_double(expiredVisits, 1, expiration); try step(expiredVisits)
            // Expiration is a retention policy, not evidence that capacity was reached.
            let capacity = max(1, limit)
            let count = try statement("SELECT (SELECT COUNT(*) FROM records) + (SELECT COUNT(*) FROM visits)")
            defer { sqlite3_finalize(count) }
            guard sqlite3_step(count) == SQLITE_ROW else { throw Failure.database }
            if sqlite3_column_int64(count, 0) > capacity {
                try recordCleanup(removeOldest(keeping: capacity), now: now)
            }
        }
        // Include the FTS index and SQLite overhead in the physical cap; keep headroom
        // below max_page_count for the rollback journal and the next bounded insert.
        while try fileSize() > budget {
            var removed = 0
            try transaction {
                removed = try removeOldest(keeping: nil)
                try execute("INSERT INTO words(words) VALUES('optimize')")
                try recordCleanup(removed, now: now)
            }
            // Commit each batch so auto-vacuum can shrink the file before measuring it.
            if removed == 0 { break }
        }
    }
    private func removeOldest(keeping: Int?) throws -> Int {
        let order = keeping == nil ? "ORDER BY seen ASC LIMIT 128" : "ORDER BY seen DESC LIMIT -1 OFFSET ?"
        let rows = try statement("SELECT kind,rowid FROM (SELECT 0 AS kind,rowid,seen FROM records UNION ALL SELECT 1,rowid,seen FROM visits) \(order)")
        defer { sqlite3_finalize(rows) }
        if let keeping { sqlite3_bind_int64(rows, 1, Int64(keeping)) }
        var keys: [(Int32, Int64)] = []
        var result = sqlite3_step(rows)
        while result == SQLITE_ROW {
            keys.append((sqlite3_column_int(rows, 0), sqlite3_column_int64(rows, 1)))
            result = sqlite3_step(rows)
        }
        guard result == SQLITE_DONE else { throw Failure.database }
        let records = try statement("DELETE FROM records WHERE rowid=?"), visits = try statement("DELETE FROM visits WHERE rowid=?")
        defer { sqlite3_finalize(records); sqlite3_finalize(visits) }
        for (kind, id) in keys {
            let stmt = kind == 0 ? records : visits
            sqlite3_reset(stmt); sqlite3_bind_int64(stmt, 1, id); try step(stmt)
        }
        return keys.count
    }
    // URL.resourceValues caches file sizes. Recheck after each committed
    // auto-vacuum batch, without reading search-index or visit statistics.
    private func fileSize() throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    public func stats() throws -> HistoryStats {
        let stmt = try statement("SELECT COUNT(*), SUM(CASE WHEN model IS NULL OR model != ? THEN 1 ELSE 0 END) FROM records")
        defer { sqlite3_finalize(stmt) }; bind(HistoryModel.version, 1, stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw Failure.database }
        let cleanup = try statement("SELECT removed,last_removed FROM capacity_cleanup WHERE id=1")
        defer { sqlite3_finalize(cleanup) }
        let cleanupStep = sqlite3_step(cleanup)
        guard cleanupStep == SQLITE_ROW || cleanupStep == SQLITE_DONE else { throw Failure.database }
        let notice = cleanupStep == SQLITE_ROW ? HistoryCapacityCleanup(removedCount: Int(sqlite3_column_int64(cleanup, 0)), lastRemovedAt: Date(timeIntervalSince1970: sqlite3_column_double(cleanup, 1))) : nil
        let bytes = try fileSize()
        let visits = try statement("SELECT (SELECT COUNT(*) FROM visits), (SELECT MAX(seen) FROM visits)")
        defer { sqlite3_finalize(visits) }
        guard sqlite3_step(visits) == SQLITE_ROW else { throw Failure.database }
        let last = sqlite3_column_type(visits, 1) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(visits, 1))
        return HistoryStats(records: Int(sqlite3_column_int(stmt, 0)), bytes: bytes, pending: Int(sqlite3_column_int(stmt, 1)), capacityCleanup: notice, visits: Int(sqlite3_column_int(visits, 0)), lastVisit: last)
    }
    public func nextUnindexed() throws -> HistoryRecord? {
        let stmt = try statement("SELECT url,title,text,appearance,seen,image FROM records WHERE model IS NULL OR model != ? ORDER BY seen DESC LIMIT 1")
        defer { sqlite3_finalize(stmt) }; bind(HistoryModel.version, 1, stmt)
        return sqlite3_step(stmt) == SQLITE_ROW ? record(stmt) : nil
    }
    private func record(_ stmt: OpaquePointer) -> HistoryRecord {
        HistoryRecord(url: string(stmt, 0), title: string(stmt, 1), text: string(stmt, 2), appearance: string(stmt, 3), image: data(stmt, 5), seen: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)))
    }
    public static func normalized(_ values: [Float]) throws -> [Float] {
        guard values.count == HistoryModel.dimensions, values.allSatisfy(\.isFinite) else { throw Failure.invalidEmbedding }
        let norm = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0.0001 else { throw Failure.invalidEmbedding }
        return values.map { $0 / norm }
    }
    private static func vectorData(_ values: [Float]?) throws -> Data? {
        guard let values else { return nil }
        return try normalized(values).withUnsafeBytes { Data($0) }
    }
    public func setEmbedding(for record: HistoryRecord, text: [Float], image: [Float]?) throws {
        let textData = try Self.vectorData(text), imageData = try Self.vectorData(image)
        let stmt = try statement("UPDATE records SET embedding=?,image_embedding=?,model=? WHERE id=?")
        defer { sqlite3_finalize(stmt) }
        bind(textData, 1, stmt); bind(imageData, 2, stmt); bind(HistoryModel.version, 3, stmt); bind(record.key, 4, stmt); try step(stmt)
    }
    public func delete(key: String? = nil, host: String? = nil) throws {
        if host == nil, let key { return try delete(visits: [], records: [key]) }
        try transaction {
            if let host {
                let domain = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !domain.isEmpty else { return }
                let predicate = " WHERE host=? OR host LIKE ? ESCAPE '\\'"
                for table in ["records", "visits"] {
                    let stmt = try statement("DELETE FROM " + table + predicate)
                    defer { sqlite3_finalize(stmt) }
                    bind(domain, 1, stmt); bind("%." + Self.likeLiteral(domain), 2, stmt)
                    try step(stmt)
                }
            } else {
                try execute("DELETE FROM records; DELETE FROM capacity_cleanup; DELETE FROM visits;")
            }
            try execute("INSERT INTO words(words) VALUES('optimize')")
        }
    }
    public func search(_ query: String, embedding: [Float]?, limit: Int = 20) throws -> [HistoryHit] {
        let query = String(query.prefix(512)).trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            let stmt = try statement("SELECT url,title,text,appearance,seen,image,id FROM records ORDER BY seen DESC LIMIT ?")
            defer { sqlite3_finalize(stmt) }; sqlite3_bind_int(stmt, 1, Int32(limit))
            var hits: [HistoryHit] = []
            while sqlite3_step(stmt) == SQLITE_ROW { hits.append(HistoryHit(id: string(stmt, 6), record: record(stmt), score: 0)) }
            return hits
        }
        var candidates: [String: HistoryHit] = [:]
        let stops: Set<String> = ["the", "that", "this", "a", "an", "i", "was", "website", "page", "with", "about", "find", "me", "it", "of", "and", "to"]
        let terms = query.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && !stops.contains($0) }.prefix(20)
        if !terms.isEmpty {
            let match = terms.map { "\"" + $0 + "\"" }.joined(separator: " OR ")
            let stmt = try statement("SELECT r.url,r.title,r.text,r.appearance,r.seen,r.image,r.id FROM words JOIN records r ON r.rowid=words.rowid WHERE words MATCH ? ORDER BY bm25(words) LIMIT 80")
            defer { sqlite3_finalize(stmt) }; bind(match, 1, stmt)
            var rank = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = string(stmt, 6); rank += 1
                candidates[id] = HistoryHit(id: id, record: record(stmt), score: 1 / Double(40 + rank))
            }
        }
        if let embedding {
            let queryVector = try Self.normalized(embedding)
            let stmt = try statement("SELECT id,embedding,image_embedding FROM records WHERE model=?")
            defer { sqlite3_finalize(stmt) }; bind(HistoryModel.version, 1, stmt)
            var top: [(String, Float)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                var score: Float = -1
                for column: Int32 in [1, 2] {
                    guard let blob = data(stmt, column), blob.count == HistoryModel.dimensions * MemoryLayout<Float>.size else { continue }
                    var values = [Float](repeating: 0, count: HistoryModel.dimensions)
                    _ = values.withUnsafeMutableBytes { blob.copyBytes(to: $0) }
                    var dot: Float = 0
                    vDSP_dotpr(queryVector, 1, values, 1, &dot, vDSP_Length(values.count))
                    score = max(score, dot)
                }
                if score >= 0.3 { top.append((string(stmt, 0), score)) }
            }
            for (rank, item) in top.sorted(by: { $0.1 > $1.1 }).prefix(80).enumerated() {
                let contribution = 1.2 / Double(41 + rank)
                if candidates[item.0] != nil { candidates[item.0]!.score += contribution }
                else {
                    let row = try statement("SELECT url,title,text,appearance,seen,image FROM records WHERE id=?")
                    bind(item.0, 1, row)
                    if sqlite3_step(row) == SQLITE_ROW { candidates[item.0] = HistoryHit(id: item.0, record: record(row), score: contribution) }
                    sqlite3_finalize(row)
                }
            }
        }
        var urls = Set<String>()
        return candidates.values.sorted { $0.score == $1.score ? $0.record.seen > $1.record.seen : $0.score > $1.score }
            .filter { urls.insert($0.record.url).inserted }.prefix(limit).map { $0 }
    }

    /// A navigation identity is independent of the URL/content hash. Repeated visits
    /// survive deduplication of the much larger captured-content records.
    public func visit(id: String, record: HistoryRecord) throws {
        guard UUID(uuidString: id) != nil, let value = record.validated(requireContent: false), value.seen.timeIntervalSince1970.isFinite else { throw Failure.invalidRecord }
        let stmt = try statement("INSERT INTO visits(id,url,title,host,seen) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title WHERE visits.url=excluded.url")
        defer { sqlite3_finalize(stmt) }
        bind(id, 1, stmt); bind(value.url, 2, stmt); bind(value.title, 3, stmt)
        bind(URL(string: value.url)?.host?.lowercased() ?? "", 4, stmt)
        sqlite3_bind_double(stmt, 5, value.seen.timeIntervalSince1970); try step(stmt)
    }

    public func preview(id: String, data: Data) throws {
        guard data.count <= 64_000 else { throw Failure.invalidRecord }
        let stmt = try statement("UPDATE visits SET preview=? WHERE id=?")
        defer { sqlite3_finalize(stmt) }; bind(data, 1, stmt); bind(id, 2, stmt); try step(stmt)
    }

    public func deleteVisit(id: String) throws {
        try delete(visits: [id], records: [])
    }

    public func delete(visits: [String], records: [String]) throws {
        guard !visits.isEmpty || !records.isEmpty else { return }
        try transaction {
            // Remove associated content only when this was the last recorded visit.
            if !visits.isEmpty {
                let content = try statement("DELETE FROM records WHERE url=(SELECT url FROM visits WHERE id=?1) AND NOT EXISTS(SELECT 1 FROM visits v WHERE v.url=records.url AND v.id!=?1)")
                defer { sqlite3_finalize(content) }
                let visit = try statement("DELETE FROM visits WHERE id=?")
                defer { sqlite3_finalize(visit) }
                for id in visits {
                    sqlite3_reset(content); bind(id, 1, content); try step(content)
                    sqlite3_reset(visit); bind(id, 1, visit); try step(visit)
                }
            }
            if !records.isEmpty {
                let record = try statement("DELETE FROM records WHERE id=?")
                defer { sqlite3_finalize(record) }
                for id in records {
                    sqlite3_reset(record); bind(id, 1, record); try step(record)
                }
                try execute("INSERT INTO words(words) VALUES('optimize')")
            }
        }
    }

    private static func likeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    /// No model is loaded for browsing, date/site filtering, or ordinary text search.
    /// Content captured before visit logging is explicitly returned as saved content.
    public func browse(query: String = "", after: Date? = nil, before: Date? = nil, host: String = "", limit: Int = 60) throws -> [HistoryHit] {
        let query = String(query.prefix(512)).trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.prefix(20)
        let match = terms.isEmpty ? "\"\"" : terms.map { "\"\($0)\"" }.joined(separator: " OR ")
        let stmt = try statement("""
        WITH matching_urls AS (SELECT r.url FROM words JOIN records r ON r.rowid=words.rowid WHERE words MATCH ?1),
        items AS (
          SELECT v.id,v.url,v.title,COALESCE((SELECT r.text || char(10) || r.appearance FROM records r WHERE r.url=v.url ORDER BY r.seen DESC LIMIT 1),'') AS text,
            '' AS appearance,v.seen,v.preview AS image,1 AS is_visit,v.host
          FROM visits v
          WHERE ?2='' OR instr(lower(v.title || ' ' || v.url),lower(?2))>0 OR v.url IN matching_urls
          UNION ALL
          SELECT r.id,r.url,r.title,r.text,r.appearance,r.seen,r.image,0,r.host FROM records r
          WHERE NOT EXISTS(SELECT 1 FROM visits v WHERE v.url=r.url)
            AND r.rowid=(SELECT r2.rowid FROM records r2 WHERE r2.url=r.url ORDER BY r2.seen DESC LIMIT 1)
            AND (?2='' OR r.url IN matching_urls OR instr(lower(r.title || ' ' || r.url),lower(?2))>0)
        )
        SELECT url,title,text,appearance,seen,image,id,is_visit FROM items
        WHERE seen>=?3 AND seen<?4
          AND (?5='' OR host=?5 OR host LIKE ?6 ESCAPE '\\')
        ORDER BY seen DESC,id LIMIT ?7
        """)
        defer { sqlite3_finalize(stmt) }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        bind(match, 1, stmt); bind(query, 2, stmt)
        sqlite3_bind_double(stmt, 3, after?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude)
        sqlite3_bind_double(stmt, 4, before?.timeIntervalSince1970 ?? Double.greatestFiniteMagnitude)
        bind(host, 5, stmt); bind("%." + Self.likeLiteral(host), 6, stmt)
        sqlite3_bind_int(stmt, 7, Int32(max(1, min(limit, Self.recordLimit))))
        var values: [HistoryHit] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            values.append(HistoryHit(id: string(stmt, 6), record: record(stmt), score: 0, isVisit: sqlite3_column_int(stmt, 7) == 1))
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else { throw Failure.database }
        return values
    }
}
