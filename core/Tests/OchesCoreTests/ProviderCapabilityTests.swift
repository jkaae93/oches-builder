import Foundation
import XCTest
@testable import OchesCore

final class ProviderCapabilityTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTempDirectory("provider-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testInstallationDiscoveryVersionChangeAccountStateAndZeroCredentialStorage() throws {
        let dbPath = tempDir.appendingPathComponent("provider.db").path
        let store = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
        let registry = try ProviderRegistryStore(store: store)

        let mockCLI = tempDir.appendingPathComponent("mock-claude")
        try "#!/bin/sh\necho 2.1.296\n".write(to: mockCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockCLI.path)

        let first = try registry.discoverAndRecordInstallation(
            installationID: "inst-claude-1",
            providerName: "claude",
            executableURL: mockCLI,
            cliVersion: "2.1.296",
            sourceBasis: "official-path",
            detectedAt: 1000
        )
        XCTAssertFalse(first.changedSincePrevious)

        // Binary modification detected as changedSincePrevious (stale trigger)
        try "#!/bin/sh\necho 2.1.297\n".write(to: mockCLI, atomically: true, encoding: .utf8)
        let second = try registry.discoverAndRecordInstallation(
            installationID: "inst-claude-1",
            providerName: "claude",
            executableURL: mockCLI,
            cliVersion: "2.1.297",
            sourceBasis: "official-path",
            detectedAt: 1005
        )
        XCTAssertTrue(second.changedSincePrevious)
        XCTAssertNotEqual(first.installation.executableSHA256, second.installation.executableSHA256)

        // Credentials / tokens / cookies strictly rejected in AccountReference and logs
        for secret in ["sk-ant-api03-secret", "Bearer eyJhbGciOi", "Cookie: session=abc", "api_key=12345"] {
            XCTAssertThrowsError(try registry.upsertAccountReference(AccountReference(
                accountRef: secret,
                providerName: "claude",
                installationID: "inst-claude-1",
                accountKind: .apiKey,
                authState: .authenticated,
                observedAt: 1010
            ))) { error in
                XCTAssertEqual(error as? ProviderError, .credentialExposureRejected("secret pattern rejected"))
            }
            XCTAssertThrowsError(try CredentialSanitizer.validateNoCredentials(secret))
        }

        // Opaque AccountReference & official AuthState transitions (no unknown -> authenticated/unsupported)
        let ref = AccountReference(
            accountRef: "acct-opaque-1",
            providerName: "claude",
            installationID: "inst-claude-1",
            accountKind: .subscription,
            authState: .loginRequired,
            observedAt: 1010
        )
        try registry.upsertAccountReference(ref)

        XCTAssertThrowsError(try registry.beginOfficialLogin(accountRef: "acct-opaque-1", explicitUserRequested: false, nowEpochSeconds: 1011)) { error in
            XCTAssertEqual(error as? ProviderError, .loginRequiresExplicitUserRequest)
        }
        let pending = try registry.beginOfficialLogin(accountRef: "acct-opaque-1", explicitUserRequested: true, nowEpochSeconds: 1012)
        XCTAssertEqual(pending.authState, .loginPending)

        // Failed official query moves state to .unknown, never .authenticated
        let failedQuery = try registry.refreshAuthStatus(accountRef: "acct-opaque-1", officialResult: .queryFailed, nowEpochSeconds: 1013)
        XCTAssertEqual(failedQuery.authState, .unknown)

        let authed = try registry.refreshAuthStatus(accountRef: "acct-opaque-1", officialResult: .authenticated, nowEpochSeconds: 1014)
        XCTAssertEqual(authed.authState, .authenticated)
    }

    private func makeScope(
        installationID: String = "inst-1",
        executableIdentity: String = "sha256:exec1",
        cliVersion: String = "2.1.296",
        adapterVersion: String = "1.0.0",
        osVersionArch: String = "macOS-26.4-arm64",
        accountRef: String = "acct-1",
        accountType: AccountKind = .apiKey,
        workspaceID: String = "ws-1",
        workspaceLocationAuthority: String = "local",
        workspaceTrust: Bool = true,
        clientID: String = "desktop-1",
        clientKind: String = "desktop",
        negotiatedProtocolMajorMinor: String = "1.0",
        policyVersion: UInt64 = 1
    ) -> CapabilityScope {
        CapabilityScope(
            installationID: installationID,
            executableIdentity: executableIdentity,
            cliVersion: cliVersion,
            adapterVersion: adapterVersion,
            osVersionArch: osVersionArch,
            accountRef: accountRef,
            accountType: accountType,
            workspaceID: workspaceID,
            workspaceLocationAuthority: workspaceLocationAuthority,
            workspaceTrust: workspaceTrust,
            clientID: clientID,
            clientKind: clientKind,
            negotiatedProtocolMajorMinor: negotiatedProtocolMajorMinor,
            policyVersion: policyVersion
        )
    }

    func testScopedCapabilityEvaluatorDocumentedUnknownStaleRemoteAndConcurrentIsolation() {
        let baseScope = makeScope()
        let entries: [CapabilityEntry] = CapabilityID.allCases.map { cap in
            CapabilityEntry(capabilityID: cap, status: .supported, basis: .verifiedInOches, evidenceRef: "ev-1", observedAt: 1000)
        }
        let snapshot = CapabilitySnapshot(snapshotID: "snap-1", scope: baseScope, entries: entries, observedAt: 1000)
        let evaluator = CapabilityEvaluator()

        // CV17: matching scope & verified capabilities -> supported
        XCTAssertEqual(
            evaluator.evaluate(snapshot: snapshot, requestedScope: baseScope, requiredCapabilities: [.providerInstall, .authOfficial, .runStart]),
            .supported
        )

        // CV01 / CV18: documented-only basis stays unknown & blocks execution
        let docOnlySnapshot = CapabilitySnapshot(
            snapshotID: "snap-doc",
            scope: baseScope,
            entries: [
                CapabilityEntry(capabilityID: .runStart, status: .supported, basis: .documented, evidenceRef: "https://docs", observedAt: 1000),
            ],
            observedAt: 1000
        )
        if case .unknown(let cap, _) = evaluator.evaluate(snapshot: docOnlySnapshot, requestedScope: baseScope, requiredCapabilities: [.runStart]) {
            XCTAssertEqual(cap, .runStart)
        } else {
            XCTFail("Expected documented-only capability to evaluate as .unknown")
        }

        // V-05: unknown required capability blocks start
        let unknownSnap = CapabilitySnapshot(
            snapshotID: "snap-unk",
            scope: baseScope,
            entries: [
                CapabilityEntry(capabilityID: .runStart, status: .unknown, basis: .experiment, evidenceRef: "exp-1", observedAt: 1000),
            ],
            observedAt: 1000
        )
        if case .unknown(let cap, _) = evaluator.evaluate(snapshot: unknownSnap, requestedScope: baseScope, requiredCapabilities: [.runStart]) {
            XCTAssertEqual(cap, .runStart)
        } else {
            XCTFail("Expected unknown required capability to block")
        }

        // Unsupported capability takes precedence over unknown
        let unsupportedSnap = CapabilitySnapshot(
            snapshotID: "snap-unsup",
            scope: baseScope,
            entries: [
                CapabilityEntry(capabilityID: .runStart, status: .unknown, basis: .experiment, evidenceRef: "exp-1", observedAt: 1000),
                CapabilityEntry(capabilityID: .permissionEnforce, status: .unsupported, basis: .experiment, evidenceRef: "exp-2", observedAt: 1000),
            ],
            observedAt: 1000
        )
        XCTAssertEqual(
            evaluator.evaluate(snapshot: unsupportedSnap, requestedScope: baseScope, requiredCapabilities: [.runStart, .permissionEnforce]),
            .unsupported(capability: .permissionEnforce)
        )

        // CV02 / CV11~CV15: changing any of the 14 scope axes makes snapshot STALE
        let mutatedScopes: [CapabilityScope] = [
            makeScope(installationID: "inst-2"),
            makeScope(executableIdentity: "sha256:exec2"),
            makeScope(cliVersion: "2.1.297"),
            makeScope(adapterVersion: "1.0.1"),
            makeScope(osVersionArch: "macOS-26.5-arm64"),
            makeScope(accountRef: "acct-2"),
            makeScope(accountType: .subscription),
            makeScope(workspaceID: "ws-2"),
            makeScope(workspaceLocationAuthority: "ssh://host"),
            makeScope(workspaceTrust: false),
            makeScope(clientID: "ext-1"),
            makeScope(clientKind: "chrome"),
            makeScope(negotiatedProtocolMajorMinor: "1.1"),
            makeScope(policyVersion: 2),
        ]
        for mutated in mutatedScopes {
            if case .stale = evaluator.evaluate(snapshot: snapshot, requestedScope: mutated, requiredCapabilities: [.runStart]) {
                // expected
            } else {
                XCTFail("Expected .stale when scope mutated to \(mutated)")
            }
        }

        // CV06: remote workspace with client.remoteWorkspace == unknown is blocked
        let remoteScope = makeScope(workspaceLocationAuthority: "ssh://remote-dev")
        var remoteEntries = entries.filter { $0.capabilityID != .clientRemoteWorkspace }
        remoteEntries.append(CapabilityEntry(capabilityID: .clientRemoteWorkspace, status: .unknown, basis: .experiment, evidenceRef: "exp", observedAt: 1000))
        let remoteSnap = CapabilitySnapshot(snapshotID: "snap-remote", scope: remoteScope, entries: remoteEntries, observedAt: 1000)
        if case .unknown(let cap, _) = evaluator.evaluate(snapshot: remoteSnap, requestedScope: remoteScope, requiredCapabilities: [.runStart]) {
            XCTAssertEqual(cap, .clientRemoteWorkspace)
        } else {
            XCTFail("Expected remote workspace unknown block")
        }

        // V-05: unverified concurrent account isolation blocks concurrent attempts
        var noIsoEntries = entries.filter { $0.capabilityID != .authAccountIsolation }
        noIsoEntries.append(CapabilityEntry(capabilityID: .authAccountIsolation, status: .unknown, basis: .experiment, evidenceRef: "exp", observedAt: 1000))
        let noIsoSnap = CapabilitySnapshot(snapshotID: "snap-iso", scope: baseScope, entries: noIsoEntries, observedAt: 1000)
        // Single active attempt permitted
        XCTAssertEqual(evaluator.evaluateConcurrentAccountIsolation(snapshot: noIsoSnap, requestedScope: baseScope, otherActiveAttemptCount: 0), .supported)
        // Concurrent second attempt blocked
        if case .unknown(let cap, _) = evaluator.evaluateConcurrentAccountIsolation(snapshot: noIsoSnap, requestedScope: baseScope, otherActiveAttemptCount: 1) {
            XCTAssertEqual(cap, .authAccountIsolation)
        } else {
            XCTFail("Expected concurrent isolation block")
        }
    }
}
