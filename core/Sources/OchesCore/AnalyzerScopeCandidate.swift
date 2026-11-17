import Foundation

/// Describes a candidate scope only. Its digest is not an approval or identity
/// proof, and it must never grant access without the product authorization gate.
/// Device/inode are only bound to the currently open descriptor; they can be
/// reused and do not prove a pathname or identity across sessions or restarts.
struct AnalyzerScopeCandidate {
    struct Limits {
        let maximumEntries: Int
        let maximumTotalBytes: Int
        let maximumFileBytes: Int
        let maximumSeconds: Int
    }

    let workspaceID: String
    let root: AnalyzerSafeRoot.RootIdentity
    let policyVersion: String
    let excludedPaths: [String]
    let exceptionPaths: [String]
    let limits: Limits
    let digest: String

    /// Internal mechanics only. Calling this does not verify approval. A
    /// product gate must authorize this exact candidate before invoking it.
    func collectCandidateEvidence(using scanner: AnalyzerSafeRoot, isCancelled: () -> Bool = { false }) throws -> AnalyzerSafeRoot.EvidenceCollection {
        guard try scanner.rootIdentity() == root else { throw AnalyzerSafeRoot.AccessError.changedDuringRead }
        return try scanner.collectEvidence(userExcludedPaths: excludedPaths, exceptionPaths: exceptionPaths,
            maximumEntries: limits.maximumEntries, maximumTotalBytes: limits.maximumTotalBytes,
            maximumFileBytes: limits.maximumFileBytes, maximumSeconds: TimeInterval(limits.maximumSeconds),
            isCancelled: isCancelled)
    }

    func buildCandidateProfile(using scanner: AnalyzerSafeRoot, profileID: String, analyzerVersion: String,
                               analyzedAt: Date, roots: [String], userConstraints: [String],
                               isCancelled: () -> Bool = { false }) throws -> AnalyzerProfileDraft {
        let collection = try collectCandidateEvidence(using: scanner, isCancelled: isCancelled)
        return try AnalyzerProfileDraft.build(profileID: profileID, workspaceRef: workspaceID,
            analyzerVersion: analyzerVersion, analyzedAt: analyzedAt, roots: roots,
            exclusions: excludedPaths, userConstraints: userConstraints, collection: collection,
            scopeDigest: digest, exceptionPaths: exceptionPaths)
    }

    init(workspaceID: String, scanner: AnalyzerSafeRoot, policyVersion: String,
         excludedPaths: [String], exceptionPaths: [String] = [], limits: Limits) throws {
        guard !workspaceID.isEmpty, !workspaceID.utf8.contains(0),
              !policyVersion.isEmpty, !policyVersion.utf8.contains(0),
              (1...10_000).contains(limits.maximumEntries),
              (1...104_857_600).contains(limits.maximumTotalBytes),
              (1...1_048_576).contains(limits.maximumFileBytes),
              (1...300).contains(limits.maximumSeconds) else { throw AnalyzerSafeRoot.AccessError.invalidPath }
        var seen = Set<Data>()
        for path in excludedPaths {
            _ = try AnalyzerExclusions.classify(relativePath: path)
            guard seen.insert(Data(path.utf8)).inserted else { throw AnalyzerSafeRoot.AccessError.invalidPath }
        }
        let sorted = excludedPaths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        try AnalyzerExclusions.validateExceptions(exceptionPaths)
        let sortedExceptions = exceptionPaths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let identity = try scanner.rootIdentity()
        let canonical: RawJSONValue = .object([
            ("domain", .string("oches.analyzer.scope.v1")),
            ("workspace", .string(workspaceID)),
            ("rootDevice", .string(String(identity.device))),
            ("rootInode", .string(String(identity.inode))),
            ("policyVersion", .string(policyVersion)),
            ("excludedPaths", .array(sorted.map { .string($0) })),
            ("exceptionPaths", .array(sortedExceptions.map { .string($0) })),
            ("maximumEntries", .number(String(limits.maximumEntries))),
            ("maximumTotalBytes", .number(String(limits.maximumTotalBytes))),
            ("maximumFileBytes", .number(String(limits.maximumFileBytes))),
            ("maximumSeconds", .number(String(limits.maximumSeconds)))
        ])
        self.workspaceID = workspaceID
        self.root = identity
        self.policyVersion = policyVersion
        self.excludedPaths = sorted
        self.exceptionPaths = sortedExceptions
        self.limits = limits
        self.digest = try canonicalSHA256(canonical).map { String(format: "%02x", $0) }.joined()
    }
}
