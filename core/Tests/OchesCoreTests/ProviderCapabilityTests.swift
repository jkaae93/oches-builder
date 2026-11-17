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
}
