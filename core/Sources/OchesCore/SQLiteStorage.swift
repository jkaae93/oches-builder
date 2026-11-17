import Foundation
import SQLite3

public enum StorageHealthState: Sendable, Equatable {
    case available
    case degraded(reason: String)
    case recoveryRequired(reason: String)
}

public enum StorageError: Error, Sendable, Equatable {
    case unavailable(String)
    case corrupt(String)
    case diskFull
    case busy
    case invalidMigration(String)
    case staleGeneration
    case versionConflict
    case idempotencyConflict
    case idempotencyExpired
    case cursorExpired
    case denied
    case invalidInput
    case notFound

    public var safeWireError: SafeWireError {
        switch self {
        case .unavailable, .busy, .diskFull, .corrupt, .invalidMigration:
            return SafeWireError(code: .unavailable, detail: nil)
        case .staleGeneration:
            return SafeWireError(code: .stale, detail: "STALE_GENERATION")
        case .versionConflict, .idempotencyConflict:
            return SafeWireError(code: .conflict, detail: nil)
        case .idempotencyExpired:
            return SafeWireError(code: .idempotencyExpired, detail: nil)
        case .cursorExpired:
            return SafeWireError(code: .cursorExpired, detail: nil)
        case .denied:
            return SafeWireError(code: .denied, detail: nil)
        case .invalidInput, .notFound:
            return SafeWireError(code: .invalidInput, detail: nil)
        }
    }
}

public struct EventCursor: Sendable, Equatable, Codable {
    public let workspaceID: String
    public let storeGeneration: String
    public let sequence: UInt64

    public init(workspaceID: String, storeGeneration: String, sequence: UInt64) {
        self.workspaceID = workspaceID
        self.storeGeneration = storeGeneration
        self.sequence = sequence
    }
}

public struct StoredEventRecord: Sendable, Equatable, Codable {
    public let sequence: UInt64
    public let eventID: String
    public let workspaceID: String
    public let storeGeneration: String
    public let objectID: String
    public let sourceID: String
    public let kind: String
    public let payloadJSON: String
    public let observedAt: Int64

    public init(
        sequence: UInt64,
        eventID: String,
        workspaceID: String,
        storeGeneration: String,
        objectID: String,
        sourceID: String,
        kind: String,
        payloadJSON: String,
        observedAt: Int64
    ) {
        self.sequence = sequence
        self.eventID = eventID
        self.workspaceID = workspaceID
        self.storeGeneration = storeGeneration
        self.objectID = objectID
        self.sourceID = sourceID
        self.kind = kind
        self.payloadJSON = payloadJSON
        self.observedAt = observedAt
    }
}

public struct NewEventRecord: Sendable, Equatable {
    public let eventID: String
    public let sourceID: String
    public let kind: String
    public let payloadJSON: String
    public let observedAt: Int64

    public init(eventID: String, sourceID: String, kind: String, payloadJSON: String, observedAt: Int64) {
        self.eventID = eventID
        self.sourceID = sourceID
        self.kind = kind
        self.payloadJSON = payloadJSON
        self.observedAt = observedAt
    }
}

public struct StateSnapshot: Sendable, Equatable {
    public let revision: RevisionRef
    public let ownerModule: String
    public let stateJSON: String
    public let eventCursor: EventCursor

    public init(revision: RevisionRef, ownerModule: String, stateJSON: String, eventCursor: EventCursor) {
        self.revision = revision
        self.ownerModule = ownerModule
        self.stateJSON = stateJSON
        self.eventCursor = eventCursor
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteStore: @unchecked Sendable {
    public static let currentSchemaVersion: Int32 = 1

    public let path: String
    public let workspaceID: String
    public private(set) var storeGeneration: String
    public private(set) var healthState: StorageHealthState = .available

    private var db: OpaquePointer?
    private let lock = NSLock()

    public init(
        path: String,
        workspaceID: String,
        initialStoreGeneration: String = UUID().uuidString.lowercased(),
        enforceDurabilityPragmas: Bool = true
    ) throws {
        guard !path.isEmpty, !workspaceID.isEmpty, !initialStoreGeneration.isEmpty else {
            throw StorageError.invalidInput
        }
        self.path = path
        self.workspaceID = workspaceID
        self.storeGeneration = initialStoreGeneration

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let openRC = sqlite3_open_v2(path, &handle, flags, nil)
        guard openRC == SQLITE_OK, let handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            if let handle { sqlite3_close(handle) }
            throw StorageError.unavailable(reason)
        }
        self.db = handle

        do {
            try configureAndVerifyPragmas(requireWALAndFull: enforceDurabilityPragmas)
            try runMigrationsAndLoadMeta()
        } catch {
            sqlite3_close(handle)
            self.db = nil
            throw error
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    public func readPragmaState() throws -> (journalMode: String, synchronous: Int32, foreignKeys: Int32) {
        lock.lock()
        defer { lock.unlock() }
        let journal = try querySingleString("PRAGMA journal_mode") ?? ""
        let sync = try querySingleInt32("PRAGMA synchronous") ?? -1
        let fk = try querySingleInt32("PRAGMA foreign_keys") ?? -1
        return (journal.lowercased(), sync, fk)
    }

    public func verifyIntegrity() throws -> StorageHealthState {
        lock.lock()
        defer { lock.unlock() }
        let integrityRows = try queryAllStrings("PRAGMA integrity_check")
        if integrityRows != ["ok"] {
            let reason = "integrity_check failed: \(integrityRows.joined(separator: "; "))"
            healthState = .recoveryRequired(reason: reason)
            return healthState
        }
        let fkRows = try queryForeignKeyViolations()
        if !fkRows.isEmpty {
            let reason = "foreign_key_check failed with \(fkRows.count) violation(s)"
            healthState = .recoveryRequired(reason: reason)
            return healthState
        }
        if case .recoveryRequired = healthState {
            healthState = .available
        }
        return healthState
    }

    public func readSnapshot(
        workspaceID: String,
        objectID: String,
        onAfterStateRead: (() -> Void)? = nil
    ) throws -> StateSnapshot {
        guard workspaceID == self.workspaceID else { throw StorageError.denied }
        guard !objectID.isEmpty else { throw StorageError.invalidInput }

        lock.lock()
        defer { lock.unlock() }

        try ensureAvailableForRead()
        try execute("BEGIN")
        do {
            let stateRow = try queryStateRow(workspaceID: workspaceID, objectID: objectID)
            onAfterStateRead?()
            let maxSeq = try queryMaxEventSequence(workspaceID: workspaceID)
            let currentGen = try queryStoreGeneration()
            try execute("COMMIT")

            guard let stateRow else { throw StorageError.notFound }
            let revision = RevisionRef(
                objectID: objectID,
                storeGeneration: currentGen,
                revision: String(stateRow.revision)
            )
            let cursor = EventCursor(workspaceID: workspaceID, storeGeneration: currentGen, sequence: maxSeq)
            return StateSnapshot(
                revision: revision,
                ownerModule: stateRow.ownerModule,
                stateJSON: stateRow.stateJSON,
                eventCursor: cursor
            )
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    public func listEvents(
        workspaceID: String,
        after cursor: EventCursor
    ) throws -> (events: [StoredEventRecord], nextCursor: EventCursor) {
        guard workspaceID == self.workspaceID, cursor.workspaceID == workspaceID else {
            throw StorageError.denied
        }

        lock.lock()
        defer { lock.unlock() }

        try ensureAvailableForRead()
        try execute("BEGIN")
        do {
            let currentGen = try queryStoreGeneration()
            guard cursor.storeGeneration == currentGen else {
                _ = try? execute("ROLLBACK")
                throw StorageError.staleGeneration
            }
            let minRetained = try queryMinRetainedSeq(workspaceID: workspaceID)
            guard cursor.sequence >= minRetained else {
                _ = try? execute("ROLLBACK")
                throw StorageError.cursorExpired
            }

            let stmt = try prepare(
                """
                SELECT seq, event_id, workspace_id, store_generation, object_id, source_id, kind, payload_json, observed_at
                FROM event_log
                WHERE workspace_id = ? AND seq > ?
                ORDER BY seq ASC
                """
            )
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, index: 1, value: workspaceID)
            sqlite3_bind_int64(stmt, 2, Int64(bitPattern: cursor.sequence))

            var events: [StoredEventRecord] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    let seq = UInt64(bitPattern: sqlite3_column_int64(stmt, 0))
                    let eventID = columnText(stmt, index: 1)
                    let ws = columnText(stmt, index: 2)
                    let gen = columnText(stmt, index: 3)
                    let obj = columnText(stmt, index: 4)
                    let src = columnText(stmt, index: 5)
                    let kind = columnText(stmt, index: 6)
                    let payload = columnText(stmt, index: 7)
                    let observedAt = sqlite3_column_int64(stmt, 8)
                    events.append(StoredEventRecord(
                        sequence: seq,
                        eventID: eventID,
                        workspaceID: ws,
                        storeGeneration: gen,
                        objectID: obj,
                        sourceID: src,
                        kind: kind,
                        payloadJSON: payload,
                        observedAt: observedAt
                    ))
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw mapSQLiteError(rc)
                }
            }
            let nextSeq = events.last?.sequence ?? cursor.sequence
            try execute("COMMIT")
            return (events, EventCursor(workspaceID: workspaceID, storeGeneration: currentGen, sequence: nextSeq))
        } catch let error as StorageError {
            _ = try? execute("ROLLBACK")
            throw error
        } catch {
            _ = try? execute("ROLLBACK")
            throw StorageError.unavailable("listEvents failed")
        }
    }

    public func executeRawForTesting(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute(sql)
    }

    public func setHealthStateForTesting(_ state: StorageHealthState) {
        lock.lock()
        defer { lock.unlock() }
        healthState = state
    }

    public func withConnectionLock<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw StorageError.unavailable("database closed") }
        return try body(db)
    }

    // MARK: - Internal helpers

    func ensureAvailableForRead() throws {
        if case .recoveryRequired(let reason) = healthState {
            throw StorageError.corrupt(reason)
        }
    }

    func ensureAvailableForWrite() throws {
        switch healthState {
        case .available:
            return
        case .degraded(let reason):
            throw StorageError.unavailable(reason)
        case .recoveryRequired(let reason):
            throw StorageError.corrupt(reason)
        }
    }

    private func configureAndVerifyPragmas(requireWALAndFull: Bool) throws {
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA synchronous = FULL")
        try execute("PRAGMA busy_timeout = 5000")
        _ = try querySingleString("PRAGMA journal_mode = WAL")

        let journal = (try querySingleString("PRAGMA journal_mode") ?? "").lowercased()
        let sync = try querySingleInt32("PRAGMA synchronous") ?? -1
        let fk = try querySingleInt32("PRAGMA foreign_keys") ?? -1

        if requireWALAndFull {
            guard journal == "wal" else {
                healthState = .unavailableReason("journal_mode is \(journal), expected wal")
                throw StorageError.unavailable("journal_mode must be wal, got \(journal)")
            }
            guard sync == 2 else {
                healthState = .unavailableReason("synchronous is \(sync), expected FULL(2)")
                throw StorageError.unavailable("synchronous must be FULL(2), got \(sync)")
            }
        }
        guard fk == 1 else {
            throw StorageError.unavailable("foreign_keys must be ON(1), got \(fk)")
        }
    }

    private func runMigrationsAndLoadMeta() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute(
                """
                CREATE TABLE IF NOT EXISTS workspace_meta (
                    workspace_id TEXT PRIMARY KEY,
                    store_generation TEXT NOT NULL,
                    schema_version INTEGER NOT NULL
                )
                """
            )

            let existingMeta = try queryWorkspaceMeta(workspaceID: workspaceID)
            if let existingMeta {
                if existingMeta.schemaVersion > Self.currentSchemaVersion {
                    _ = try? execute("ROLLBACK")
                    throw StorageError.invalidMigration(
                        "database schema_version \(existingMeta.schemaVersion) exceeds supported \(Self.currentSchemaVersion)"
                    )
                }
                self.storeGeneration = existingMeta.storeGeneration
            } else {
                let stmt = try prepare(
                    "INSERT INTO workspace_meta (workspace_id, store_generation, schema_version) VALUES (?, ?, ?)"
                )
                defer { sqlite3_finalize(stmt) }
                try bindText(stmt, index: 1, value: workspaceID)
                try bindText(stmt, index: 2, value: storeGeneration)
                sqlite3_bind_int(stmt, 3, Self.currentSchemaVersion)
                let rc = sqlite3_step(stmt)
                guard rc == SQLITE_DONE else { throw mapSQLiteError(rc) }
            }

            try execute(
                """
                CREATE TABLE IF NOT EXISTS operational_state (
                    object_id TEXT PRIMARY KEY,
                    workspace_id TEXT NOT NULL,
                    owner_module TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    state_json TEXT NOT NULL,
                    updated_at INTEGER NOT NULL,
                    FOREIGN KEY(workspace_id) REFERENCES workspace_meta(workspace_id)
                );
                CREATE TABLE IF NOT EXISTS event_log (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    event_id TEXT NOT NULL UNIQUE,
                    workspace_id TEXT NOT NULL,
                    store_generation TEXT NOT NULL,
                    object_id TEXT NOT NULL,
                    source_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    observed_at INTEGER NOT NULL,
                    FOREIGN KEY(workspace_id) REFERENCES workspace_meta(workspace_id)
                );
                CREATE TABLE IF NOT EXISTS event_retention_meta (
                    workspace_id TEXT PRIMARY KEY,
                    min_retained_seq INTEGER NOT NULL DEFAULT 0,
                    FOREIGN KEY(workspace_id) REFERENCES workspace_meta(workspace_id)
                );
                CREATE TABLE IF NOT EXISTS idempotency_records (
                    actor_id TEXT NOT NULL,
                    workspace_id TEXT NOT NULL,
                    operation TEXT NOT NULL,
                    request_id TEXT NOT NULL,
                    input_digest TEXT NOT NULL,
                    response_json TEXT,
                    result_revision INTEGER,
                    result_cursor INTEGER,
                    created_at INTEGER NOT NULL,
                    expires_at INTEGER NOT NULL,
                    tombstoned INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(actor_id, workspace_id, operation, request_id),
                    FOREIGN KEY(workspace_id) REFERENCES workspace_meta(workspace_id)
                );
                """
            )
            let retStmt = try prepare(
                "INSERT OR IGNORE INTO event_retention_meta (workspace_id, min_retained_seq) VALUES (?, 0)"
            )
            defer { sqlite3_finalize(retStmt) }
            try bindText(retStmt, index: 1, value: workspaceID)
            let retRC = sqlite3_step(retStmt)
            guard retRC == SQLITE_DONE else { throw mapSQLiteError(retRC) }

            try execute("COMMIT")
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    private func queryWorkspaceMeta(workspaceID: String) throws -> (storeGeneration: String, schemaVersion: Int32)? {
        let stmt = try prepare("SELECT store_generation, schema_version FROM workspace_meta WHERE workspace_id = ?")
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: workspaceID)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW {
            return (columnText(stmt, index: 0), sqlite3_column_int(stmt, 1))
        } else if rc == SQLITE_DONE {
            return nil
        }
        throw mapSQLiteError(rc)
    }

    private func queryStoreGeneration() throws -> String {
        if let meta = try queryWorkspaceMeta(workspaceID: workspaceID) {
            self.storeGeneration = meta.storeGeneration
            return meta.storeGeneration
        }
        throw StorageError.corrupt("missing workspace_meta")
    }

    private func queryStateRow(workspaceID: String, objectID: String) throws -> (ownerModule: String, revision: UInt64, stateJSON: String)? {
        let stmt = try prepare(
            "SELECT owner_module, revision, state_json FROM operational_state WHERE workspace_id = ? AND object_id = ?"
        )
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: workspaceID)
        try bindText(stmt, index: 2, value: objectID)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW {
            let owner = columnText(stmt, index: 0)
            let rev = UInt64(bitPattern: sqlite3_column_int64(stmt, 1))
            let json = columnText(stmt, index: 2)
            return (owner, rev, json)
        } else if rc == SQLITE_DONE {
            return nil
        }
        throw mapSQLiteError(rc)
    }

    private func queryMaxEventSequence(workspaceID: String) throws -> UInt64 {
        let stmt = try prepare("SELECT COALESCE(MAX(seq), 0) FROM event_log WHERE workspace_id = ?")
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: workspaceID)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW else { throw mapSQLiteError(rc) }
        return UInt64(bitPattern: sqlite3_column_int64(stmt, 0))
    }

    private func queryMinRetainedSeq(workspaceID: String) throws -> UInt64 {
        let stmt = try prepare("SELECT COALESCE(min_retained_seq, 0) FROM event_retention_meta WHERE workspace_id = ?")
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: workspaceID)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW {
            return UInt64(bitPattern: sqlite3_column_int64(stmt, 0))
        } else if rc == SQLITE_DONE {
            return 0
        }
        throw mapSQLiteError(rc)
    }

    func execute(_ sql: String) throws {
        guard let db else { throw StorageError.unavailable("database closed") }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let text = errMsg.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errMsg)
            throw mapSQLiteError(rc, message: text)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw StorageError.unavailable("database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw mapSQLiteError(rc)
        }
        return stmt
    }

    func bindText(_ stmt: OpaquePointer, index: Int32, value: String) throws {
        let rc = sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
        guard rc == SQLITE_OK else { throw mapSQLiteError(rc) }
    }

    func columnText(_ stmt: OpaquePointer, index: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cStr)
    }

    func querySingleString(_ sql: String) throws -> String? {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW {
            return columnText(stmt, index: 0)
        } else if rc == SQLITE_DONE {
            return nil
        }
        throw mapSQLiteError(rc)
    }

    func querySingleInt32(_ sql: String) throws -> Int32? {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0)
        } else if rc == SQLITE_DONE {
            return nil
        }
        throw mapSQLiteError(rc)
    }

    private func queryAllStrings(_ sql: String) throws -> [String] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var rows: [String] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                rows.append(columnText(stmt, index: 0))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw mapSQLiteError(rc)
            }
        }
        return rows
    }

    private func queryForeignKeyViolations() throws -> [String] {
        let stmt = try prepare("PRAGMA foreign_key_check")
        defer { sqlite3_finalize(stmt) }
        var violations: [String] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                let table = columnText(stmt, index: 0)
                let rowid = sqlite3_column_int64(stmt, 1)
                let parent = columnText(stmt, index: 2)
                violations.append("\(table)[\(rowid)]->\(parent)")
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw mapSQLiteError(rc)
            }
        }
        return violations
    }

    func mapSQLiteError(_ code: Int32, message: String? = nil) -> StorageError {
        let base = code & 0xff
        let msg = message ?? (db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error \(code)")
        switch base {
        case SQLITE_FULL:
            healthState = .degraded(reason: "SQLITE_FULL: \(msg)")
            return .diskFull
        case SQLITE_IOERR:
            healthState = .degraded(reason: "SQLITE_IOERR: \(msg)")
            return .unavailable(msg)
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            healthState = .recoveryRequired(reason: "SQLITE_CORRUPT: \(msg)")
            return .corrupt(msg)
        case SQLITE_BUSY, SQLITE_LOCKED:
            return .busy
        default:
            return .unavailable(msg)
        }
    }
}

private extension StorageHealthState {
    static func unavailableReason(_ reason: String) -> StorageHealthState {
        .degraded(reason: reason)
    }
}
