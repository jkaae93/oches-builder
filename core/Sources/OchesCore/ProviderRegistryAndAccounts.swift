import CryptoKit
import Foundation
import SQLite3

public enum ProviderError: Error, Sendable, Equatable {
    case invalidInput(String)
    case credentialExposureRejected(String)
    case installationNotFound
    case accountNotFound
    case loginRequiresExplicitUserRequest
    case storageFailure(String)

    public var safeWireError: SafeWireError {
        switch self {
        case .invalidInput, .credentialExposureRejected, .installationNotFound, .accountNotFound:
            return SafeWireError(code: .invalidInput, detail: nil)
        case .loginRequiresExplicitUserRequest:
            return SafeWireError(code: .approvalRequired, detail: nil)
        case .storageFailure:
            return SafeWireError(code: .unavailable, detail: nil)
        }
    }
}

public enum AccountAuthState: String, Sendable, Equatable, Codable {
    case unknown = "Unknown"
    case loginRequired = "LoginRequired"
    case loginPending = "LoginPending"
    case authenticated = "Authenticated"
}

public enum AccountKind: String, Sendable, Equatable, Codable {
    case apiKey = "API_KEY"
    case subscription = "SUBSCRIPTION"
    case unknown = "UNKNOWN"
}

public struct ProviderInstallation: Sendable, Equatable, Codable {
    public let installationID: String
    public let providerName: String
    public let executablePath: String
    public let executableSHA256: String
    public let cliVersion: String
    public let detectedAt: Int64
    public let sourceBasis: String

    public init(
        installationID: String,
        providerName: String,
        executablePath: String,
        executableSHA256: String,
        cliVersion: String,
        detectedAt: Int64,
        sourceBasis: String
    ) {
        self.installationID = installationID
        self.providerName = providerName
        self.executablePath = executablePath
        self.executableSHA256 = executableSHA256
        self.cliVersion = cliVersion
        self.detectedAt = detectedAt
        self.sourceBasis = sourceBasis
    }
}

public struct AccountReference: Sendable, Equatable, Codable {
    public let accountRef: String
    public let providerName: String
    public let installationID: String
    public let accountKind: AccountKind
    public let authState: AccountAuthState
    public let observedAt: Int64

    public init(
        accountRef: String,
        providerName: String,
        installationID: String,
        accountKind: AccountKind,
        authState: AccountAuthState,
        observedAt: Int64
    ) {
        self.accountRef = accountRef
        self.providerName = providerName
        self.installationID = installationID
        self.accountKind = accountKind
        self.authState = authState
        self.observedAt = observedAt
    }
}

public struct CredentialSanitizer: Sendable {
    private static let forbiddenMarkers: [String] = [
        "sk-",
        "ant-",
        "bearer ",
        "cookie:",
        "set-cookie:",
        "api_key=",
        "apikey=",
        "access_token=",
        "refresh_token=",
        "session_token=",
        "x-api-key",
        "authorization:",
    ]

    public static func validateNoCredentials(_ text: String) throws {
        let lower = text.lowercased()
        for marker in forbiddenMarkers where lower.contains(marker) {
            throw ProviderError.credentialExposureRejected("secret pattern rejected")
        }
    }
}

public enum OfficialAuthQueryResult: Sendable, Equatable {
    case authenticated
    case loginRequired
    case queryFailed
}

public final class ProviderRegistryStore: @unchecked Sendable {
    public let store: SQLiteStore

    public init(store: SQLiteStore) throws {
        self.store = store
        try initializeSchema()
    }

    private func initializeSchema() throws {
        try store.executeRawForTesting(
            """
            CREATE TABLE IF NOT EXISTS provider_installations (
                installation_id TEXT PRIMARY KEY,
                provider_name TEXT NOT NULL,
                executable_path TEXT NOT NULL,
                executable_sha256 TEXT NOT NULL,
                cli_version TEXT NOT NULL,
                detected_at INTEGER NOT NULL,
                source_basis TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS account_references (
                account_ref TEXT PRIMARY KEY,
                provider_name TEXT NOT NULL,
                installation_id TEXT NOT NULL,
                account_kind TEXT NOT NULL,
                auth_state TEXT NOT NULL,
                observed_at INTEGER NOT NULL,
                FOREIGN KEY(installation_id) REFERENCES provider_installations(installation_id)
            );
            """
        )
    }

    public static func computeExecutableSHA256(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    public func discoverAndRecordInstallation(
        installationID: String,
        providerName: String,
        executableURL: URL,
        cliVersion: String,
        sourceBasis: String,
        detectedAt: Int64
    ) throws -> (installation: ProviderInstallation, changedSincePrevious: Bool) {
        try CredentialSanitizer.validateNoCredentials(installationID)
        try CredentialSanitizer.validateNoCredentials(providerName)
        try CredentialSanitizer.validateNoCredentials(executableURL.path)
        try CredentialSanitizer.validateNoCredentials(cliVersion)
        try CredentialSanitizer.validateNoCredentials(sourceBasis)

        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ProviderError.invalidInput("executable not found or not executable")
        }

        let sha256 = try Self.computeExecutableSHA256(at: executableURL)
        let existing = try? fetchInstallation(installationID: installationID)
        let changed = existing != nil && (existing?.executableSHA256 != sha256 || existing?.cliVersion != cliVersion || existing?.executablePath != executableURL.path)

        let installation = ProviderInstallation(
            installationID: installationID,
            providerName: providerName,
            executablePath: executableURL.path,
            executableSHA256: sha256,
            cliVersion: cliVersion,
            detectedAt: detectedAt,
            sourceBasis: sourceBasis
        )

        try store.withConnectionLock { _ in
            try store.execute("BEGIN IMMEDIATE")
            do {
                let stmt = try store.prepare(
                    """
                    INSERT OR REPLACE INTO provider_installations (
                        installation_id, provider_name, executable_path, executable_sha256, cli_version, detected_at, source_basis
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """
                )
                defer { sqlite3_finalize(stmt) }
                try store.bindText(stmt, index: 1, value: installation.installationID)
                try store.bindText(stmt, index: 2, value: installation.providerName)
                try store.bindText(stmt, index: 3, value: installation.executablePath)
                try store.bindText(stmt, index: 4, value: installation.executableSHA256)
                try store.bindText(stmt, index: 5, value: installation.cliVersion)
                sqlite3_bind_int64(stmt, 6, installation.detectedAt)
                try store.bindText(stmt, index: 7, value: installation.sourceBasis)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw ProviderError.storageFailure("insert installation failed")
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
        return (installation, changed)
    }

    public func fetchInstallation(installationID: String) throws -> ProviderInstallation {
        try store.withConnectionLock { _ in
            let stmt = try store.prepare(
                "SELECT installation_id, provider_name, executable_path, executable_sha256, cli_version, detected_at, source_basis FROM provider_installations WHERE installation_id = ?"
            )
            defer { sqlite3_finalize(stmt) }
            try store.bindText(stmt, index: 1, value: installationID)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw ProviderError.installationNotFound
            }
            return ProviderInstallation(
                installationID: store.columnText(stmt, index: 0),
                providerName: store.columnText(stmt, index: 1),
                executablePath: store.columnText(stmt, index: 2),
                executableSHA256: store.columnText(stmt, index: 3),
                cliVersion: store.columnText(stmt, index: 4),
                detectedAt: sqlite3_column_int64(stmt, 5),
                sourceBasis: store.columnText(stmt, index: 6)
            )
        }
    }

    public func upsertAccountReference(_ ref: AccountReference) throws {
        try CredentialSanitizer.validateNoCredentials(ref.accountRef)
        try CredentialSanitizer.validateNoCredentials(ref.providerName)
        try CredentialSanitizer.validateNoCredentials(ref.installationID)

        _ = try fetchInstallation(installationID: ref.installationID)
        try store.withConnectionLock { _ in
            try store.execute("BEGIN IMMEDIATE")
            do {
                let stmt = try store.prepare(
                    """
                    INSERT OR REPLACE INTO account_references (
                        account_ref, provider_name, installation_id, account_kind, auth_state, observed_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """
                )
                defer { sqlite3_finalize(stmt) }
                try store.bindText(stmt, index: 1, value: ref.accountRef)
                try store.bindText(stmt, index: 2, value: ref.providerName)
                try store.bindText(stmt, index: 3, value: ref.installationID)
                try store.bindText(stmt, index: 4, value: ref.accountKind.rawValue)
                try store.bindText(stmt, index: 5, value: ref.authState.rawValue)
                sqlite3_bind_int64(stmt, 6, ref.observedAt)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw ProviderError.storageFailure("upsert account reference failed")
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
    }

    public func fetchAccountReference(accountRef: String) throws -> AccountReference {
        try store.withConnectionLock { _ in
            let stmt = try store.prepare(
                "SELECT account_ref, provider_name, installation_id, account_kind, auth_state, observed_at FROM account_references WHERE account_ref = ?"
            )
            defer { sqlite3_finalize(stmt) }
            try store.bindText(stmt, index: 1, value: accountRef)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw ProviderError.accountNotFound
            }
            return AccountReference(
                accountRef: store.columnText(stmt, index: 0),
                providerName: store.columnText(stmt, index: 1),
                installationID: store.columnText(stmt, index: 2),
                accountKind: AccountKind(rawValue: store.columnText(stmt, index: 3)) ?? .unknown,
                authState: AccountAuthState(rawValue: store.columnText(stmt, index: 4)) ?? .unknown,
                observedAt: sqlite3_column_int64(stmt, 5)
            )
        }
    }

    public func beginOfficialLogin(accountRef: String, explicitUserRequested: Bool, nowEpochSeconds: Int64) throws -> AccountReference {
        guard explicitUserRequested else {
            throw ProviderError.loginRequiresExplicitUserRequest
        }
        let existing = try fetchAccountReference(accountRef: accountRef)
        let updated = AccountReference(
            accountRef: existing.accountRef,
            providerName: existing.providerName,
            installationID: existing.installationID,
            accountKind: existing.accountKind,
            authState: .loginPending,
            observedAt: nowEpochSeconds
        )
        try upsertAccountReference(updated)
        return updated
    }

    public func refreshAuthStatus(accountRef: String, officialResult: OfficialAuthQueryResult, nowEpochSeconds: Int64) throws -> AccountReference {
        let existing = try fetchAccountReference(accountRef: accountRef)
        let nextState: AccountAuthState
        switch officialResult {
        case .authenticated:
            nextState = .authenticated
        case .loginRequired:
            nextState = .loginRequired
        case .queryFailed:
            nextState = .unknown
        }
        let updated = AccountReference(
            accountRef: existing.accountRef,
            providerName: existing.providerName,
            installationID: existing.installationID,
            accountKind: existing.accountKind,
            authState: nextState,
            observedAt: nowEpochSeconds
        )
        try upsertAccountReference(updated)
        return updated
    }
}
