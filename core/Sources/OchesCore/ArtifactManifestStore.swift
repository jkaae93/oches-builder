import CryptoKit
import Darwin
import Foundation
import SQLite3

public enum ArtifactAccessStatus: String, Sendable, Equatable, Codable {
    case collected
    case missing
    case accessDenied
    case changedDuringRead
    case symlinkRejected
    case outsideRoot
}

public struct ArtifactManifestEntry: Sendable, Equatable, Codable {
    public let relativePath: String
    public let accessStatus: ArtifactAccessStatus
    public let blobDigest: String?
    public let byteLength: Int64?
    public let mtimeNanoseconds: Int64?
    public let collectedAt: Int64

    public init(
        relativePath: String,
        accessStatus: ArtifactAccessStatus,
        blobDigest: String?,
        byteLength: Int64?,
        mtimeNanoseconds: Int64?,
        collectedAt: Int64
    ) {
        self.relativePath = relativePath
        self.accessStatus = accessStatus
        self.blobDigest = blobDigest
        self.byteLength = byteLength
        self.mtimeNanoseconds = mtimeNanoseconds
        self.collectedAt = collectedAt
    }
}

public struct ArtifactManifestRecord: Sendable, Equatable, Codable {
    public let manifestID: String
    public let workspaceID: String
    public let runID: String
    public let taskID: String
    public let attemptID: String
    public let taskRevision: RevisionRef
    public let entries: [ArtifactManifestEntry]
    public let manifestDigest: String
    public let complete: Bool
    public let collectedAt: Int64

    public init(
        manifestID: String,
        workspaceID: String,
        runID: String,
        taskID: String,
        attemptID: String,
        taskRevision: RevisionRef,
        entries: [ArtifactManifestEntry],
        manifestDigest: String,
        complete: Bool,
        collectedAt: Int64
    ) {
        self.manifestID = manifestID
        self.workspaceID = workspaceID
        self.runID = runID
        self.taskID = taskID
        self.attemptID = attemptID
        self.taskRevision = taskRevision
        self.entries = entries
        self.manifestDigest = manifestDigest
        self.complete = complete
        self.collectedAt = collectedAt
    }
}

public enum ManifestIntegrityResult: Sendable, Equatable {
    case valid(manifest: ArtifactManifestRecord)
    case invalid(reason: String)
}

public enum WorkspaceDriftResult: Sendable, Equatable {
    case unchanged
    case mutated(paths: [String])
    case unknown(reason: String)
}

public final class ArtifactManifestStore: @unchecked Sendable {
    public static let maxArtifactBytes: Int = 16 * 1024 * 1024

    public let store: SQLiteStore
    public let blobRootURL: URL

    public init(store: SQLiteStore, blobRootURL: URL) throws {
        self.store = store
        self.blobRootURL = blobRootURL.standardizedFileURL
        try FileManager.default.createDirectory(
            at: self.blobRootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try initializeSchema()
    }

    private func initializeSchema() throws {
        try store.executeRawForTesting(
            """
            CREATE TABLE IF NOT EXISTS artifact_manifests (
                manifest_id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                run_id TEXT NOT NULL,
                task_id TEXT NOT NULL,
                attempt_id TEXT NOT NULL,
                task_revision_json TEXT NOT NULL,
                entries_json TEXT NOT NULL,
                manifest_digest TEXT NOT NULL,
                complete INTEGER NOT NULL,
                collected_at INTEGER NOT NULL
            );
            """
        )
    }

    public func collectImmutableSnapshot(
        manifestID: String,
        runID: String,
        taskID: String,
        attemptID: String,
        taskRevision: RevisionRef,
        workspaceRoot: URL,
        relativePaths: [String],
        collectedAt: Int64,
        injectChangeDuringReadForPath: String? = nil
    ) throws -> ArtifactManifestRecord {
        let requiredNonEmpty = [
            manifestID, runID, taskID, attemptID,
            taskRevision.objectID, taskRevision.storeGeneration, taskRevision.revision,
        ]
        guard requiredNonEmpty.allSatisfy({ !$0.isEmpty && !$0.utf8.contains(0) }),
              collectedAt >= 0 else {
            throw StorageError.invalidInput
        }
        var seen = Set<String>()
        for path in relativePaths {
            guard seen.insert(path).inserted else {
                throw StorageError.invalidInput
            }
        }

        let canonicalRoot = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
        let rootFD = open(canonicalRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            throw StorageError.unavailable("workspace root unavailable")
        }
        defer { close(rootFD) }

        let sortedPaths = relativePaths.sorted()
        var entries: [ArtifactManifestEntry] = []
        entries.reserveCapacity(sortedPaths.count)

        for relPath in sortedPaths {
            let entry = try collectSingleEntry(
                rootFD: rootFD,
                canonicalRoot: canonicalRoot,
                relativePath: relPath,
                collectedAt: collectedAt,
                injectChangeDuringRead: injectChangeDuringReadForPath == relPath
            )
            entries.append(entry)
        }

        let complete = !entries.isEmpty && entries.allSatisfy {
            $0.accessStatus == .collected && $0.blobDigest != nil
        }
        let manifestDigest = try Self.computeManifestDigest(
            manifestID: manifestID,
            workspaceID: store.workspaceID,
            runID: runID,
            taskID: taskID,
            attemptID: attemptID,
            taskRevision: taskRevision,
            entries: entries,
            complete: complete
        )
        let record = ArtifactManifestRecord(
            manifestID: manifestID,
            workspaceID: store.workspaceID,
            runID: runID,
            taskID: taskID,
            attemptID: attemptID,
            taskRevision: taskRevision,
            entries: entries,
            manifestDigest: manifestDigest,
            complete: complete,
            collectedAt: collectedAt
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let taskRevJSON = String(decoding: try encoder.encode(taskRevision), as: UTF8.self)
        let entriesJSON = String(decoding: try encoder.encode(entries), as: UTF8.self)

        try store.withConnectionLock { _ in
            try store.ensureAvailableForWrite()
            try store.execute("BEGIN IMMEDIATE")
            do {
                let stmt = try store.prepare(
                    """
                    INSERT INTO artifact_manifests (
                        manifest_id, workspace_id, run_id, task_id, attempt_id,
                        task_revision_json, entries_json, manifest_digest, complete, collected_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
                )
                defer { sqlite3_finalize(stmt) }
                try store.bindText(stmt, index: 1, value: record.manifestID)
                try store.bindText(stmt, index: 2, value: record.workspaceID)
                try store.bindText(stmt, index: 3, value: record.runID)
                try store.bindText(stmt, index: 4, value: record.taskID)
                try store.bindText(stmt, index: 5, value: record.attemptID)
                try store.bindText(stmt, index: 6, value: taskRevJSON)
                try store.bindText(stmt, index: 7, value: entriesJSON)
                try store.bindText(stmt, index: 8, value: record.manifestDigest)
                sqlite3_bind_int(stmt, 9, record.complete ? 1 : 0)
                sqlite3_bind_int64(stmt, 10, record.collectedAt)
                let rc = sqlite3_step(stmt)
                if (rc & 0xff) == SQLITE_CONSTRAINT {
                    throw StorageError.versionConflict
                }
                guard rc == SQLITE_DONE else {
                    throw store.mapSQLiteError(rc)
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
        return record
    }

    public func fetchManifest(manifestID: String) throws -> ArtifactManifestRecord {
        guard !manifestID.isEmpty, !manifestID.utf8.contains(0) else {
            throw StorageError.invalidInput
        }
        return try store.withConnectionLock { _ in
            let stmt = try store.prepare(
                """
                SELECT manifest_id, workspace_id, run_id, task_id, attempt_id,
                       task_revision_json, entries_json, manifest_digest, complete, collected_at
                FROM artifact_manifests WHERE manifest_id = ? AND workspace_id = ?
                """
            )
            defer { sqlite3_finalize(stmt) }
            try store.bindText(stmt, index: 1, value: manifestID)
            try store.bindText(stmt, index: 2, value: store.workspaceID)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { throw StorageError.notFound }
            guard rc == SQLITE_ROW else { throw store.mapSQLiteError(rc) }
            let taskRev = try JSONDecoder().decode(RevisionRef.self, from: Data(store.columnText(stmt, index: 5).utf8))
            let entries = try JSONDecoder().decode([ArtifactManifestEntry].self, from: Data(store.columnText(stmt, index: 6).utf8))
            return ArtifactManifestRecord(
                manifestID: store.columnText(stmt, index: 0),
                workspaceID: store.columnText(stmt, index: 1),
                runID: store.columnText(stmt, index: 2),
                taskID: store.columnText(stmt, index: 3),
                attemptID: store.columnText(stmt, index: 4),
                taskRevision: taskRev,
                entries: entries,
                manifestDigest: store.columnText(stmt, index: 7),
                complete: sqlite3_column_int(stmt, 8) != 0,
                collectedAt: sqlite3_column_int64(stmt, 9)
            )
        }
    }

    public func verifyManifestIntegrity(manifestID: String) throws -> ManifestIntegrityResult {
        let manifest = try fetchManifest(manifestID: manifestID)
        guard manifest.complete else {
            return .invalid(reason: "manifest incomplete")
        }
        let expectedDigest = try Self.computeManifestDigest(
            manifestID: manifest.manifestID,
            workspaceID: manifest.workspaceID,
            runID: manifest.runID,
            taskID: manifest.taskID,
            attemptID: manifest.attemptID,
            taskRevision: manifest.taskRevision,
            entries: manifest.entries,
            complete: manifest.complete
        )
        guard manifest.manifestDigest == expectedDigest else {
            return .invalid(reason: "manifest digest mismatch")
        }
        for entry in manifest.entries {
            guard entry.accessStatus == .collected,
                  let digest = entry.blobDigest,
                  let expectedLength = entry.byteLength else {
                return .invalid(reason: "entry \(entry.relativePath) not collected")
            }
            let blobURL = blobRootURL.appendingPathComponent(digest)
            guard let data = try? Data(contentsOf: blobURL) else {
                return .invalid(reason: "missing immutable blob for \(entry.relativePath)")
            }
            guard Int64(data.count) == expectedLength else {
                return .invalid(reason: "blob length mismatch for \(entry.relativePath)")
            }
            let actualHex = Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
            guard actualHex == digest else {
                return .invalid(reason: "blob content digest mismatch for \(entry.relativePath)")
            }
        }
        return .valid(manifest: manifest)
    }

    public func compareManifestAgainstWorkspace(manifestID: String, workspaceRoot: URL) throws -> WorkspaceDriftResult {
        let manifest = try fetchManifest(manifestID: manifestID)
        guard manifest.complete else {
            return .unknown(reason: "manifest incomplete")
        }
        let canonicalRoot = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
        let rootFD = open(canonicalRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            return .unknown(reason: "workspace root unavailable")
        }
        defer { close(rootFD) }

        var mutated: [String] = []
        for entry in manifest.entries {
            guard entry.accessStatus == .collected, let expectedDigest = entry.blobDigest else {
                return .unknown(reason: "entry \(entry.relativePath) not collected")
            }
            switch try readSafeFile(rootFD: rootFD, canonicalRoot: canonicalRoot, relativePath: entry.relativePath, injectChangeDuringRead: false) {
            case .success(_, let sha256Hex, _, _):
                if sha256Hex != expectedDigest {
                    mutated.append(entry.relativePath)
                }
            case .failure(let status, let reason):
                return .unknown(reason: "\(entry.relativePath): \(status.rawValue) (\(reason))")
            }
        }
        return mutated.isEmpty ? .unchanged : .mutated(paths: mutated)
    }

    private enum SafeReadOutcome {
        case success(bytes: Data, sha256Hex: String, byteLength: Int64, mtimeNanoseconds: Int64)
        case failure(status: ArtifactAccessStatus, reason: String)
    }

    private func collectSingleEntry(
        rootFD: Int32,
        canonicalRoot: URL,
        relativePath: String,
        collectedAt: Int64,
        injectChangeDuringRead: Bool
    ) throws -> ArtifactManifestEntry {
        switch try readSafeFile(
            rootFD: rootFD,
            canonicalRoot: canonicalRoot,
            relativePath: relativePath,
            injectChangeDuringRead: injectChangeDuringRead
        ) {
        case .success(let bytes, let sha256Hex, let byteLength, let mtimeNanoseconds):
            try persistImmutableBlob(bytes: bytes, sha256Hex: sha256Hex)
            return ArtifactManifestEntry(
                relativePath: relativePath,
                accessStatus: .collected,
                blobDigest: sha256Hex,
                byteLength: byteLength,
                mtimeNanoseconds: mtimeNanoseconds,
                collectedAt: collectedAt
            )
        case .failure(let status, _):
            return ArtifactManifestEntry(
                relativePath: relativePath,
                accessStatus: status,
                blobDigest: nil,
                byteLength: nil,
                mtimeNanoseconds: nil,
                collectedAt: collectedAt
            )
        }
    }

    private func readSafeFile(
        rootFD: Int32,
        canonicalRoot: URL,
        relativePath: String,
        injectChangeDuringRead: Bool
    ) throws -> SafeReadOutcome {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.utf8.contains(0) else {
            return .failure(status: .outsideRoot, reason: "invalid relative path")
        }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return .failure(status: .outsideRoot, reason: "path traversal rejected")
        }
        let candidateURL = canonicalRoot.appendingPathComponent(relativePath)

        var current = dup(rootFD)
        guard current >= 0 else {
            return .failure(status: .accessDenied, reason: "dup root failed")
        }
        defer { close(current) }

        for (index, part) in parts.enumerated() {
            let isLeaf = index == parts.count - 1
            var lstatInfo = stat()
            if fstatat(current, String(part), &lstatInfo, AT_SYMLINK_NOFOLLOW) != 0 {
                return .failure(status: mapErrno(errno), reason: "fstatat failed")
            }
            if (lstatInfo.st_mode & S_IFMT) == S_IFLNK {
                return .failure(status: .symlinkRejected, reason: "symlink component rejected")
            }
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (isLeaf ? O_NONBLOCK : O_DIRECTORY)
            let next = openat(current, String(part), flags)
            if next < 0 {
                return .failure(status: mapErrno(errno), reason: "openat failed")
            }
            close(current)
            current = next
        }

        guard AuthorizationEnforcer.canonicalPathWithinRoot(
            candidatePath: candidateURL.path,
            rootPath: canonicalRoot.path
        ) != nil else {
            return .failure(status: .outsideRoot, reason: "outside canonical root")
        }

        var before = stat()
        guard fstat(current, &before) == 0 else {
            return .failure(status: .accessDenied, reason: "fstat before read failed")
        }
        guard (before.st_mode & S_IFMT) == S_IFREG else {
            return .failure(status: .outsideRoot, reason: "not a regular file")
        }
        guard before.st_nlink == 1 else {
            return .failure(status: .outsideRoot, reason: "multiple hard links rejected")
        }
        guard before.st_size >= 0, before.st_size <= Self.maxArtifactBytes else {
            return .failure(status: .accessDenied, reason: "artifact size limit exceeded")
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= Self.maxArtifactBytes {
            let readCount = Darwin.read(current, &buffer, buffer.count)
            if readCount < 0 {
                if errno == EINTR { continue }
                return .failure(status: .accessDenied, reason: "read failed")
            }
            if readCount == 0 { break }
            data.append(contentsOf: buffer.prefix(readCount))
            if data.count > Self.maxArtifactBytes {
                return .failure(status: .accessDenied, reason: "artifact size limit exceeded")
            }
        }

        if injectChangeDuringRead {
            return .failure(status: .changedDuringRead, reason: "injected concurrent modification")
        }

        var after = stat()
        guard fstat(current, &after) == 0 else {
            return .failure(status: .changedDuringRead, reason: "fstat after read failed")
        }
        guard before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              Int64(data.count) == after.st_size else {
            return .failure(status: .changedDuringRead, reason: "file modified during read")
        }

        var pathStat = stat()
        guard lstat(candidateURL.path, &pathStat) == 0,
              pathStat.st_dev == after.st_dev,
              pathStat.st_ino == after.st_ino,
              (pathStat.st_mode & S_IFMT) == S_IFREG else {
            return .failure(status: .changedDuringRead, reason: "path replaced during read")
        }

        let hex = Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
        let mtimeNs = Int64(after.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(after.st_mtimespec.tv_nsec)
        return .success(bytes: data, sha256Hex: hex, byteLength: after.st_size, mtimeNanoseconds: mtimeNs)
    }

    private func mapErrno(_ err: Int32) -> ArtifactAccessStatus {
        switch err {
        case ENOENT, ENOTDIR:
            return .missing
        case ELOOP:
            return .symlinkRejected
        default:
            return .accessDenied
        }
    }

    private func persistImmutableBlob(bytes: Data, sha256Hex: String) throws {
        let dest = blobRootURL.appendingPathComponent(sha256Hex)
        if FileManager.default.fileExists(atPath: dest.path) {
            let existing = try Data(contentsOf: dest)
            let actualHex = Data(SHA256.hash(data: existing)).map { String(format: "%02x", $0) }.joined()
            guard actualHex == sha256Hex else {
                throw StorageError.corrupt("existing immutable blob digest mismatch")
            }
            return
        }
        let tempURL = blobRootURL.appendingPathComponent(".tmp-\(UUID().uuidString.lowercased())")
        try bytes.write(to: tempURL, options: .atomic)
        guard chmod(tempURL.path, 0o444) == 0 else {
            _ = try? FileManager.default.removeItem(at: tempURL)
            throw StorageError.unavailable("failed to mark blob read-only")
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            _ = try? FileManager.default.removeItem(at: tempURL)
            let existing = try Data(contentsOf: dest)
            let actualHex = Data(SHA256.hash(data: existing)).map { String(format: "%02x", $0) }.joined()
            guard actualHex == sha256Hex else {
                throw StorageError.corrupt("concurrent immutable blob digest mismatch")
            }
            return
        }
        try FileManager.default.moveItem(at: tempURL, to: dest)
    }

    static func computeManifestDigest(
        manifestID: String,
        workspaceID: String,
        runID: String,
        taskID: String,
        attemptID: String,
        taskRevision: RevisionRef,
        entries: [ArtifactManifestEntry],
        complete: Bool
    ) throws -> String {
        let sortedEntries = entries.sorted { $0.relativePath < $1.relativePath }
        let entryValues: [RawJSONValue] = sortedEntries.map { entry in
            .object([
                ("relativePath", .string(entry.relativePath)),
                ("accessStatus", .string(entry.accessStatus.rawValue)),
                ("blobDigest", entry.blobDigest.map(RawJSONValue.string) ?? .null),
                ("byteLength", entry.byteLength.map { .number(String($0)) } ?? .null),
                ("mtimeNanoseconds", entry.mtimeNanoseconds.map { .number(String($0)) } ?? .null),
                ("collectedAt", .number(String(entry.collectedAt))),
            ])
        }
        let digestData = try canonicalSHA256(.object([
            ("domain", .string("oches.artifact.manifest.v1")),
            ("manifestID", .string(manifestID)),
            ("workspaceID", .string(workspaceID)),
            ("runID", .string(runID)),
            ("taskID", .string(taskID)),
            ("attemptID", .string(attemptID)),
            ("taskRevision", .object([
                ("objectID", .string(taskRevision.objectID)),
                ("storeGeneration", .string(taskRevision.storeGeneration)),
                ("revision", .string(taskRevision.revision)),
            ])),
            ("complete", .bool(complete)),
            ("entries", .array(entryValues)),
        ]))
        return digestData.map { String(format: "%02x", $0) }.joined()
    }
}
