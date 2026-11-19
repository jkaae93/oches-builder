import Foundation
import XCTest
@testable import OchesCore

final class PackagingAndMigrationTests: XCTestCase {
    func testInstallModeProtocolAndArtifactSignatureGates() throws {
        // P9 v1 bundled-only rule
        XCTAssertNoThrow(try PackagingAndMigrationManager.validateInstallMode(.bundledLocalDesktopAndCore))
        XCTAssertThrowsError(try PackagingAndMigrationManager.validateInstallMode(.standaloneCoreWithoutDesktop))
        XCTAssertThrowsError(try PackagingAndMigrationManager.validateInstallMode(.remoteDistribution))

        // W8 protocol negotiation
        let coreOffer = ProtocolOffer(major: 1, minimumMinor: 0, maximumMinor: 2, capabilities: ["noise-ik", "analyze"])
        let matching = try negotiateProtocol(
            local: coreOffer,
            remote: ProtocolOffer(major: 1, minimumMinor: 1, maximumMinor: 3, capabilities: ["noise-ik", "apply"])
        )
        XCTAssertEqual(matching.minor, 2)
        XCTAssertEqual(matching.capabilities, ["noise-ik"])
        XCTAssertThrowsError(
            try negotiateProtocol(
                local: coreOffer,
                remote: ProtocolOffer(major: 2, minimumMinor: 0, maximumMinor: 0, capabilities: [])
            )
        ) { error in
            XCTAssertEqual(error as? ProtocolNegotiationError, .versionUnsupported)
        }

        // Artifact digest & notarization check
        let payload = Data("signed-core-binary-v1".utf8)
        let digest = PackagingAndMigrationManager.sha256Hex(of: payload)
        let signedManifest = ReleaseArtifactManifest(
            artifactID: "com.oches.core",
            version: "0.1.0",
            platform: "macos-arm64",
            sha256Hex: digest,
            developerTeamID: "TEAM123456",
            notarized: true
        )
        XCTAssertEqual(
            try PackagingAndMigrationManager.verifyArtifactBytes(
                payload,
                manifest: signedManifest,
                expectedTeamID: "TEAM123456",
                channel: .releaseSignedAndNotarized
            ),
            digest
        )

        // Tampered binary fails
        XCTAssertThrowsError(
            try PackagingAndMigrationManager.verifyArtifactBytes(
                Data("tampered-core-binary".utf8),
                manifest: signedManifest,
                expectedTeamID: "TEAM123456",
                channel: .releaseSignedAndNotarized
            )
        )

        // Unnotarized release fails under release channel
        let unnotarized = ReleaseArtifactManifest(
            artifactID: "com.oches.core",
            version: "0.1.0",
            platform: "macos-arm64",
            sha256Hex: digest,
            developerTeamID: "TEAM123456",
            notarized: false
        )
        XCTAssertThrowsError(
            try PackagingAndMigrationManager.verifyArtifactBytes(
                payload,
                manifest: unnotarized,
                expectedTeamID: "TEAM123456",
                channel: .releaseSignedAndNotarized
            )
        ) { error in
            XCTAssertEqual(error as? PackagingError, .missingAppleNotarization)
        }
    }

    func testSQLiteUpgradeBackupRollbackAndOlderBinaryDowngradeBlock() throws {
        let dir = try makeTempDirectory()
        let dbURL = dir.appendingPathComponent("oches.sqlite")

        // Create and seed real SQLiteStore at schema_version = 2
        var storage: SQLiteStore? = try SQLiteStore(path: dbURL.path, workspaceID: "ws-pack")
        let req = TransitionRequest(
            actorID: "desktop",
            workspaceID: "ws-pack",
            operation: "seed",
            requestID: "req-seed-1",
            objectID: "obj-1",
            ownerModule: "Test",
            expectedRevision: nil,
            normalizedInput: .object([]),
            nextStateJSON: "{\"ok\":true}",
            events: [
                NewEventRecord(
                    eventID: "evt-1",
                    sourceID: "core",
                    kind: "Seeded",
                    payloadJSON: "{}",
                    observedAt: 1_000
                )
            ],
            responseJSON: "{\"ok\":true}",
            nowEpochSeconds: 1_000
        )
        _ = try storage?.commitTransition(req)
        storage = nil

        // Update blocked when Core process still owns DB
        XCTAssertThrowsError(
            _ = try PackagingAndMigrationManager.upgradeDatabase(
                at: dbURL,
                workspaceID: "ws-pack",
                targetSchemaVersion: 3,
                activeCoreOwnerPID: 9999,
                migrationStatements: ["CREATE TABLE migration_v3 (id TEXT PRIMARY KEY);"]
            )
        ) { error in
            XCTAssertEqual(error as? PackagingError, .coreOwnedByAnotherProcess(pid: 9999))
        }

        // Injected failure inside migration rolls back DB byte-identically to pre-upgrade backup
        _ = try PackagingAndMigrationManager.upgradeDatabase(
            at: dbURL,
            workspaceID: "ws-pack",
            targetSchemaVersion: 2,
            activeCoreOwnerPID: nil,
            migrationStatements: []
        )
        let preUpgradeDigest = PackagingAndMigrationManager.sha256Hex(of: try Data(contentsOf: dbURL))
        XCTAssertThrowsError(
            _ = try PackagingAndMigrationManager.upgradeDatabase(
                at: dbURL,
                workspaceID: "ws-pack",
                targetSchemaVersion: 3,
                activeCoreOwnerPID: nil,
                migrationStatements: [
                    "CREATE TABLE migration_v3 (id TEXT PRIMARY KEY);",
                    "THIS IS INVALID SQL TO INJECT FAILURE;",
                ]
            )
        ) { error in
            guard case .migrationRolledBack(let backupSHA, _) = error as? PackagingError else {
                return XCTFail("Expected migrationRolledBack, got \(error)")
            }
            XCTAssertEqual(backupSHA, preUpgradeDigest)
        }

        // Restored DB still opens cleanly at v2 with intact data
        let reopened = try SQLiteStore(path: dbURL.path, workspaceID: "ws-pack")
        let snapshot = try reopened.readSnapshot(workspaceID: "ws-pack", objectID: "obj-1")
        XCTAssertEqual(snapshot.stateJSON, "{\"ok\":true}")

        // Now perform a valid upgrade to v3 and confirm an older v2 binary refuses to open v3 DB
        let upgradeOutcome = try PackagingAndMigrationManager.upgradeDatabase(
            at: dbURL,
            workspaceID: "ws-pack",
            targetSchemaVersion: 3,
            activeCoreOwnerPID: nil,
            migrationStatements: ["CREATE TABLE migration_v3 (id TEXT PRIMARY KEY);"]
        )
        XCTAssertEqual(upgradeOutcome.previousSchemaVersion, 2)
        XCTAssertEqual(upgradeOutcome.newSchemaVersion, 3)

        XCTAssertThrowsError(
            try PackagingAndMigrationManager.verifyBinaryCanOpenDatabase(
                dbURL: dbURL,
                workspaceID: "ws-pack",
                binaryMaxSupportedSchemaVersion: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? PackagingError,
                .newerSchemaRequiresRecovery(databaseSchema: 3, binarySupported: 2)
            )
        }
    }

    func testNativeHostPermissionsSwapDetectionAndUninstallPlan() throws {
        let dir = try makeTempDirectory()
        let hostBin = dir.appendingPathComponent("oches-native-host")
        let manifestURL = dir.appendingPathComponent("com.oches.builder.host.json")
        let binaryV1 = Data("#!/bin/sh\necho v1\n".utf8)
        try binaryV1.write(to: hostBin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hostBin.path)

        let manifest = NativeMessagingManifestSpec(
            name: "com.oches.builder.host",
            description: "Oches Native Host",
            path: hostBin.path,
            type: "stdio",
            allowedOrigins: ["chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"]
        )
        try (try manifest.encodeCanonicalJSON()).write(to: manifestURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifestURL.path)

        let digestV1 = PackagingAndMigrationManager.sha256Hex(of: binaryV1)
        let reg1 = try PackagingAndMigrationManager.verifyNativeHostRegistration(
            manifestURL: manifestURL,
            hostBinaryURL: hostBin,
            expectedBinarySHA256: digestV1,
            previousCombinedDigestHex: nil
        )
        XCTAssertFalse(reg1.requiresCoreReverification)

        // Swapping host binary flips requiresCoreReverification == true and catches old digest mismatch
        let binaryV2 = Data("#!/bin/sh\necho v2\n".utf8)
        try binaryV2.write(to: hostBin)
        XCTAssertThrowsError(
            try PackagingAndMigrationManager.verifyNativeHostRegistration(
                manifestURL: manifestURL,
                hostBinaryURL: hostBin,
                expectedBinarySHA256: digestV1,
                previousCombinedDigestHex: reg1.combinedDigestHex
            )
        )
        let reg2 = try PackagingAndMigrationManager.verifyNativeHostRegistration(
            manifestURL: manifestURL,
            hostBinaryURL: hostBin,
            expectedBinarySHA256: PackagingAndMigrationManager.sha256Hex(of: binaryV2),
            previousCombinedDigestHex: reg1.combinedDigestHex
        )
        XCTAssertTrue(reg2.requiresCoreReverification)

        // World-writable binary rejected
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: hostBin.path)
        XCTAssertThrowsError(
            try PackagingAndMigrationManager.verifyNativeHostRegistration(
                manifestURL: manifestURL,
                hostBinaryURL: hostBin,
                expectedBinarySHA256: nil,
                previousCombinedDigestHex: nil
            )
        ) { error in
            guard case .insecureFilePermissions = error as? PackagingError else {
                return XCTFail("Expected insecureFilePermissions")
            }
        }

        // Uninstall plan separates revocation/app removal from opt-in workspace purge and never deletes Provider logins
        let defaultPlan = PackagingAndMigrationManager.planUninstall(
            clientIDs: ["desktop-1", "chrome-1"],
            appBundlePath: "/Applications/Oches.app",
            nativeHostManifestPath: manifestURL.path,
            workspaceDataPaths: ["/Users/kaae/Library/Application Support/Oches/db"],
            providerCredentialPaths: ["/Users/kaae/.claude", "/Users/kaae/.codex"],
            userConfirmedDataPurge: false
        )
        XCTAssertTrue(defaultPlan.workspaceDataPathsToDelete.isEmpty)
        XCTAssertEqual(defaultPlan.preservedWorkspaceDataPaths.count, 1)
        XCTAssertFalse(defaultPlan.touchesProviderCredentials)
        XCTAssertEqual(defaultPlan.preservedProviderCredentialPaths, ["/Users/kaae/.claude", "/Users/kaae/.codex"])
    }
}
