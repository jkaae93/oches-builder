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
    let limits: Limits
    let digest: String

    init(workspaceID: String, scanner: AnalyzerSafeRoot, policyVersion: String,
         excludedPaths: [String], limits: Limits) throws {
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
        let identity = try scanner.rootIdentity()
        let canonical: RawJSONValue = .object([
            ("domain", .string("oches.analyzer.scope.v1")),
            ("workspace", .string(workspaceID)),
            ("rootDevice", .string(String(identity.device))),
            ("rootInode", .string(String(identity.inode))),
            ("policyVersion", .string(policyVersion)),
            ("excludedPaths", .array(sorted.map { .string($0) })),
            ("maximumEntries", .number(String(limits.maximumEntries))),
            ("maximumTotalBytes", .number(String(limits.maximumTotalBytes))),
            ("maximumFileBytes", .number(String(limits.maximumFileBytes))),
            ("maximumSeconds", .number(String(limits.maximumSeconds)))
        ])
        self.workspaceID = workspaceID
        self.root = identity
        self.policyVersion = policyVersion
        self.excludedPaths = sorted
        self.limits = limits
        self.digest = try canonicalSHA256(canonical).map { String(format: "%02x", $0) }.joined()
    }
}
