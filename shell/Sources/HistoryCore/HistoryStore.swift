import Foundation
import SQLite3
import Accelerate

/// Owned by the serial helper process. No database work runs on the browser UI thread.
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
        CREATE TABLE IF NOT EXISTS capacity_cleanup (
          id INTEGER PRIMARY KEY CHECK(id=1), removed INTEGER NOT NULL, last_removed REAL NOT NULL);
        CREATE VIRTUAL TABLE IF NOT EXISTS words USING fts5(title, text, appearance, url, content='records', content_rowid='rowid');
        CREATE TRIGGER IF NOT EXISTS records_ai AFTER INSERT ON records BEGIN
          INSERT INTO words(rowid,title,text,appearance,url) VALUES(new.rowid,new.title,new.text,new.appearance,new.url); END;
        CREATE TRIGGER IF NOT EXISTS records_ad AFTER DELETE ON records BEGIN
          INSERT INTO words(words,rowid,title,text,appearance,url) VALUES('delete',old.rowid,old.title,old.text,old.appearance,old.url); END;
        """)
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
        let stmt = try statement("INSERT INTO records(id,url,title,text,appearance,seen,image) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET seen=MAX(seen,excluded.seen)")
        defer { sqlite3_finalize(stmt) }
        bind(record.key, 1, stmt); bind(record.url, 2, stmt); bind(record.title, 3, stmt)
        bind(record.text, 4, stmt); bind(record.appearance, 5, stmt)
        sqlite3_bind_double(stmt, 6, record.seen.timeIntervalSince1970); bind(record.image, 7, stmt)
        try step(stmt)
    }
    public func prune(days: Int, now: Date = Date(), budget: Int64 = HistoryStore.budget, limit: Int = HistoryStore.recordLimit) throws {
        let expiration = now.addingTimeInterval(-Double(max(1, min(days, 365))) * 86400).timeIntervalSince1970
        try transaction {
            let expired = try statement("DELETE FROM records WHERE seen < ?")
            defer { sqlite3_finalize(expired) }
            sqlite3_bind_double(expired, 1, expiration); try step(expired)
            // Expiration is a retention policy, not evidence that capacity was reached.
            let overflow = try statement("DELETE FROM records WHERE rowid IN (SELECT rowid FROM records ORDER BY seen DESC LIMIT -1 OFFSET ?)")
            defer { sqlite3_finalize(overflow) }
            sqlite3_bind_int(overflow, 1, Int32(max(1, limit))); try step(overflow)
            try recordCleanup(Int(sqlite3_changes(db)), now: now)
        }
        // Include the FTS index and SQLite overhead in the physical cap; keep headroom
        // below max_page_count for the rollback journal and the next bounded insert.
        while try stats().bytes > budget, try stats().records > 0 {
            var removed = 0
            try transaction {
                try execute("DELETE FROM records WHERE rowid IN (SELECT rowid FROM records ORDER BY seen LIMIT 128)")
                removed = Int(sqlite3_changes(db))
                try execute("INSERT INTO words(words) VALUES('optimize')")
                try recordCleanup(removed, now: now)
            }
            // Commit each batch so auto-vacuum can shrink the file before measuring it.
            if removed == 0 { break }
        }
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
        // URL.resourceValues caches file sizes on this long-lived URL. Read fresh
        // attributes after each write/auto-vacuum so the cap uses current usage.
        let bytes = (try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.int64Value ?? 0
        return HistoryStats(records: Int(sqlite3_column_int(stmt, 0)), bytes: bytes, pending: Int(sqlite3_column_int(stmt, 1)), capacityCleanup: notice)
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
        if let host {
            let stmt = try statement("SELECT id,url FROM records")
            var keys: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if !HistoryPolicy.permits(string(stmt, 1), exclusions: [host]) { keys.append(string(stmt, 0)) }
            }
            sqlite3_finalize(stmt)
            for key in keys { try delete(key: key) }
            return
        }
        try transaction {
            let stmt = try statement(key == nil ? "DELETE FROM records" : "DELETE FROM records WHERE id=?")
            defer { sqlite3_finalize(stmt) }
            if let key { bind(key, 1, stmt) }; try step(stmt)
            if key == nil { try execute("DELETE FROM capacity_cleanup") }
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
}
