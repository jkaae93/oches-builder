import CryptoKit
import Foundation
import SQLite3

public enum InstallDistributionMode: String, Sendable, Equatable {
    case bundledLocalDesktopAndCore
    case standaloneCoreWithoutDesktop
    case remoteDistribution
}

public enum ReleaseVerificationChannel: String, Sendable, Equatable {
    case developmentUnsigned
    case releaseSignedAndNotarized
}

public enum PackagingError: Error, Sendable, Equatable {
    case unsupportedInstallMode(InstallDistributionMode)
    case digestMismatch(expected: String, actual: String)
    case missingDeveloperIDSignature
    case missingAppleNotarization
    case coreOwnedByAnotherProcess(pid: Int32)
    case newerSchemaRequiresRecovery(databaseSchema: Int32, binarySupported: Int32)
    case migrationRolledBack(backupSHA256: String, reason: String)
    case rollbackRestoreFailed(String)
    case insecureFilePermissions(path: String, mode: UInt16)
    case manifestPathMismatch(expected: String, actual: String)
    case hostBinaryMissing(path: String)
}

public struct ReleaseArtifactManifest: Sendable, Equatable, Codable {
    public let artifactID: String
    public let version: String
    public let platform: String
    public let sha256Hex: String
    public let developerTeamID: String?
    public let notarized: Bool

    public init(
        artifactID: String,
        version: String,
        platform: String,
        sha256Hex: String,
        developerTeamID: String?,
        notarized: Bool
    ) {
        self.artifactID = artifactID
        self.version = version
        self.platform = platform
        self.sha256Hex = sha256Hex.lowercased()
        self.developerTeamID = developerTeamID
        self.notarized = notarized
    }
}

public struct MigrationOutcome: Sendable, Equatable {
    public let previousSchemaVersion: Int32
    public let newSchemaVersion: Int32
    public let backupURL: URL
    public let backupSHA256Hex: String
}

public struct NativeHostRegistrationStatus: Sendable, Equatable {
    public let manifestSpec: NativeMessagingManifestSpec
    public let manifestSHA256Hex: String
    public let binarySHA256Hex: String
    public let combinedDigestHex: String
    public let requiresCoreReverification: Bool
}

public struct UninstallPlan: Sendable, Equatable {
    public let clientIDsToRevoke: [String]
    public let removeAppBundlePath: String
    public let removeNativeHostManifestPath: String
    public let workspaceDataPathsToDelete: [String]
    public let preservedWorkspaceDataPaths: [String]
    public let preservedProviderCredentialPaths: [String]
    public let touchesProviderCredentials: Bool
}

public enum PackagingAndMigrationManager {
    public static func validateInstallMode(_ mode: InstallDistributionMode) throws {
        // P9 frozen v1 rule: desktop-less Core and remote distribution are UNSUPPORTED.
        guard mode == .bundledLocalDesktopAndCore else {
            throw PackagingError.unsupportedInstallMode(mode)
        }
    }

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func verifyArtifactBytes(
        _ bytes: Data,
        manifest: ReleaseArtifactManifest,
        expectedTeamID: String,
        channel: ReleaseVerificationChannel
    ) throws -> String {
        let actualDigest = sha256Hex(of: bytes)
        guard actualDigest == manifest.sha256Hex else {
            throw PackagingError.digestMismatch(expected: manifest.sha256Hex, actual: actualDigest)
        }
        if channel == .releaseSignedAndNotarized {
            guard let teamID = manifest.developerTeamID,
                  !teamID.isEmpty,
                  teamID == expectedTeamID else {
                throw PackagingError.missingDeveloperIDSignature
            }
            guard manifest.notarized else {
                throw PackagingError.missingAppleNotarization
            }
        }
        return actualDigest
    }

    public static func verifyBinaryCanOpenDatabase(
        dbURL: URL,
        workspaceID: String,
        binaryMaxSupportedSchemaVersion: Int32
    ) throws -> Int32 {
        let currentSchema = try readSchemaVersion(dbURL: dbURL, workspaceID: workspaceID)
        if currentSchema > binaryMaxSupportedSchemaVersion {
            throw PackagingError.newerSchemaRequiresRecovery(
                databaseSchema: currentSchema,
                binarySupported: binaryMaxSupportedSchemaVersion
            )
        }
        return currentSchema
    }

    public static func upgradeDatabase(
        at dbURL: URL,
        workspaceID: String,
        targetSchemaVersion: Int32,
        activeCoreOwnerPID: Int32?,
        migrationStatements: [String]
    ) throws -> MigrationOutcome {
        if let ownerPID = activeCoreOwnerPID {
            throw PackagingError.coreOwnedByAnotherProcess(pid: ownerPID)
        }

        let currentSchema = try readSchemaVersion(dbURL: dbURL, workspaceID: workspaceID)
        if currentSchema > targetSchemaVersion {
            throw PackagingError.newerSchemaRequiresRecovery(
                databaseSchema: currentSchema,
                binarySupported: targetSchemaVersion
            )
        }

        // Checkpoint WAL into main database file before taking binary backup snapshot.
        try checkpointDatabase(dbURL: dbURL)

        let backupURL = dbURL.appendingPathExtension("pre-upgrade.bak")
        let fm = FileManager.default
        if fm.fileExists(atPath: backupURL.path) {
            try fm.removeItem(at: backupURL)
        }
        let preUpgradeBytes = try Data(contentsOf: dbURL)
        try preUpgradeBytes.write(to: backupURL, options: .atomic)
        let backupDigest = sha256Hex(of: preUpgradeBytes)

        do {
            try applySchemaMigrationStatements(
                dbURL: dbURL,
                workspaceID: workspaceID,
                targetSchemaVersion: targetSchemaVersion,
                statements: migrationStatements
            )
            return MigrationOutcome(
                previousSchemaVersion: currentSchema,
                newSchemaVersion: targetSchemaVersion,
                backupURL: backupURL,
                backupSHA256Hex: backupDigest
            )
        } catch {
            // Restore byte-identical backup if migration fails.
            do {
                let backupData = try Data(contentsOf: backupURL)
                guard sha256Hex(of: backupData) == backupDigest else {
                    throw PackagingError.rollbackRestoreFailed("backup checksum changed unexpectedly")
                }
                for suffix in ["-wal", "-shm"] {
                    let aux = URL(fileURLWithPath: dbURL.path + suffix)
                    if fm.fileExists(atPath: aux.path) {
                        try fm.removeItem(at: aux)
                    }
                }
                try backupData.write(to: dbURL, options: .atomic)
            } catch let restoreError {
                throw PackagingError.rollbackRestoreFailed("\(restoreError)")
            }
            throw PackagingError.migrationRolledBack(
                backupSHA256: backupDigest,
                reason: "\(error)"
            )
        }
    }

    public static func verifyNativeHostRegistration(
        manifestURL: URL,
        hostBinaryURL: URL,
        expectedBinarySHA256: String?,
        previousCombinedDigestHex: String?
    ) throws -> NativeHostRegistrationStatus {
        let fm = FileManager.default
        guard fm.fileExists(atPath: hostBinaryURL.path) else {
            throw PackagingError.hostBinaryMissing(path: hostBinaryURL.path)
        }

        try assertSafePOSIXPermissions(url: manifestURL)
        try assertSafePOSIXPermissions(url: hostBinaryURL)

        let manifestBytes = try Data(contentsOf: manifestURL)
        let manifestSpec = try NativeMessagingManifestSpec.parseAndValidate(jsonData: manifestBytes)
        guard manifestSpec.path == hostBinaryURL.path else {
            throw PackagingError.manifestPathMismatch(expected: hostBinaryURL.path, actual: manifestSpec.path)
        }

        let binaryBytes = try Data(contentsOf: hostBinaryURL)
        let binaryDigest = sha256Hex(of: binaryBytes)
        if let expectedBinarySHA256, binaryDigest != expectedBinarySHA256.lowercased() {
            throw PackagingError.digestMismatch(expected: expectedBinarySHA256.lowercased(), actual: binaryDigest)
        }

        let manifestDigest = sha256Hex(of: manifestBytes)
        let combined = sha256Hex(of: Data("\(manifestDigest):\(binaryDigest)".utf8))
        let requiresReverify = previousCombinedDigestHex != nil && previousCombinedDigestHex != combined
        return NativeHostRegistrationStatus(
            manifestSpec: manifestSpec,
            manifestSHA256Hex: manifestDigest,
            binarySHA256Hex: binaryDigest,
            combinedDigestHex: combined,
            requiresCoreReverification: requiresReverify
        )
    }

    public static func planUninstall(
        clientIDs: [String],
        appBundlePath: String,
        nativeHostManifestPath: String,
        workspaceDataPaths: [String],
        providerCredentialPaths: [String],
        userConfirmedDataPurge: Bool
    ) -> UninstallPlan {
        UninstallPlan(
            clientIDsToRevoke: clientIDs,
            removeAppBundlePath: appBundlePath,
            removeNativeHostManifestPath: nativeHostManifestPath,
            workspaceDataPathsToDelete: userConfirmedDataPurge ? workspaceDataPaths : [],
            preservedWorkspaceDataPaths: userConfirmedDataPurge ? [] : workspaceDataPaths,
            preservedProviderCredentialPaths: providerCredentialPaths,
            touchesProviderCredentials: false
        )
    }

    private static func assertSafePOSIXPermissions(url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let perm = (attrs[.posixPermissions] as? NSNumber)?.uint16Value else {
            return
        }
        // Reject group-writable (0o020) or world-writable (0o002) Host files/manifests.
        if (perm & 0o022) != 0 {
            throw PackagingError.insecureFilePermissions(path: url.path, mode: perm)
        }
    }

    private static func openSQLite(dbURL: URL, flags: Int32) throws -> OpaquePointer {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(dbURL.path, &db, flags, nil)
        guard rc == SQLITE_OK, let opened = db else {
            if let db { sqlite3_close(db) }
            throw StorageError.unavailable("sqlite3_open_v2 failed (\(rc))")
        }
        return opened
    }

    private static func readSchemaVersion(dbURL: URL, workspaceID: String) throws -> Int32 {
        let db = try openSQLite(dbURL: dbURL, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT schema_version FROM workspace_meta WHERE workspace_id = ?",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK, let prepared = stmt else {
            throw StorageError.corrupt("missing workspace_meta table")
        }
        defer { sqlite3_finalize(prepared) }
        _ = workspaceID.withCString { cStr in
            sqlite3_bind_text(prepared, 1, cStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sqlite3_step(prepared) == SQLITE_ROW else {
            throw StorageError.corrupt("workspace_meta row not found for \(workspaceID)")
        }
        return sqlite3_column_int(prepared, 0)
    }

    private static func checkpointDatabase(dbURL: URL) throws {
        let db = try openSQLite(dbURL: dbURL, flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(db) }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, &errMsg)
        if let errMsg { sqlite3_free(errMsg) }
        guard rc == SQLITE_OK else {
            throw StorageError.unavailable("wal_checkpoint failed (\(rc))")
        }
    }

    private static func applySchemaMigrationStatements(
        dbURL: URL,
        workspaceID: String,
        targetSchemaVersion: Int32,
        statements: [String]
    ) throws {
        let db = try openSQLite(dbURL: dbURL, flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(db) }

        func execSQL(_ sql: String) throws {
            var errMsg: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
            if rc != SQLITE_OK {
                let msg = errMsg.map { String(cString: $0) } ?? "sqlite error \(rc)"
                if let errMsg { sqlite3_free(errMsg) }
                throw StorageError.invalidMigration(msg)
            }
        }

        try execSQL("BEGIN IMMEDIATE;")
        do {
            for sql in statements {
                try execSQL(sql)
            }
            var upd: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "UPDATE workspace_meta SET schema_version = ? WHERE workspace_id = ?",
                -1,
                &upd,
                nil
            ) == SQLITE_OK, let stmt = upd else {
                throw StorageError.invalidMigration("prepare schema update failed")
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, targetSchemaVersion)
            _ = workspaceID.withCString { cStr in
                sqlite3_bind_text(stmt, 2, cStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StorageError.invalidMigration("step schema update failed")
            }
            try execSQL("COMMIT;")
        } catch {
            _ = try? execSQL("ROLLBACK;")
            throw error
        }
    }
}
