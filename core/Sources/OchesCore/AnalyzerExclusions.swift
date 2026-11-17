import Foundation

/// Default content exclusions; this policy does not claim to identify all secrets.
/// Overrides must be path-specific and separately bound to a verified approval.
enum AnalyzerExclusion: String, Sendable {
    case credentials, versionControl, dependencies, buildOutput, media, archive, bundle, userRule
}

struct AnalyzerExclusions {
    enum CompilationInterrupted: Error { case interrupted }
    /// Byte-indexed rules avoid rescanning the entire rule list per file.
    struct Compiled {
        private let excluded: Set<Data>
        private let exceptions: Set<Data>
        private let exceptionAncestors: Set<Data>

        init(userExcludedPaths: [String], exceptionPaths: [String], shouldStop: () -> Bool = { false }) throws {
            var excluded = Set<Data>()
            for path in userExcludedPaths {
                if shouldStop() { throw CompilationInterrupted.interrupted }
                _ = try AnalyzerExclusions.classify(relativePath: path)
                excluded.insert(Data(path.utf8))
            }
            var exceptions = Set<Data>()
            var ancestors = Set<Data>()
            for path in exceptionPaths {
                if shouldStop() { throw CompilationInterrupted.interrupted }
                _ = try AnalyzerExclusions.classify(relativePath: path)
                let bytes = Array(path.utf8)
                guard exceptions.insert(Data(bytes)).inserted else { throw AnalyzerSafeRoot.AccessError.invalidPath }
                for index in bytes.indices where bytes[index] == 47 {
                    ancestors.insert(Data(bytes[..<index]))
                }
            }
            self.excluded = excluded
            self.exceptions = exceptions
            self.exceptionAncestors = ancestors
        }

        func classify(_ path: String) throws -> AnalyzerExclusion? {
            let fallback = try AnalyzerExclusions.classify(relativePath: path)
            let bytes = Array(path.utf8)
            if excluded.contains(Data(bytes)) { return .userRule }
            for index in bytes.indices where bytes[index] == 47 {
                if excluded.contains(Data(bytes[..<index])) { return .userRule }
            }
            return fallback
        }

        func isException(_ path: String) -> Bool { exceptions.contains(Data(path.utf8)) }
        func leadsToException(_ path: String) -> Bool { exceptionAncestors.contains(Data(path.utf8)) }
    }

    static func validateExceptions(_ paths: [String]) throws {
        var seen = Set<Data>()
        for path in paths {
            _ = try classify(relativePath: path)
            guard seen.insert(Data(path.utf8)).inserted else { throw AnalyzerSafeRoot.AccessError.invalidPath }
        }
    }

    private static let versionControl: Set<String> = [".git", ".hg", ".svn"]
    private static let dependencies: Set<String> = ["node_modules", ".dart_tool", ".pub-cache", "vendor", "pods", ".venv", "venv", "__pycache__"]
    private static let builds: Set<String> = ["build", "dist", "target", ".next", ".gradle", "deriveddata", "coverage"]
    private static let credentialNames: Set<String> = [".env", ".ssh", ".aws", ".gnupg", ".kube", ".netrc", ".npmrc", ".pypirc", "id_rsa", "id_ed25519", "credentials", "credentials.json", "service-account.json"]
    private static let credentialExtensions: Set<String> = ["pem", "key", "p12", "pfx", "keystore", "jks"]
    private static let mediaExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "mp3", "wav", "mp4", "mov", "avi", "pdf"]
    private static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "bz2", "xz", "7z", "rar", "dmg", "iso"]
    private static let bundleExtensions: Set<String> = ["app", "framework", "bundle", "xcassets", "xcodeproj", "xcworkspace"]

    /// User rules are exact relative paths or subtree roots, never globs.
    static func classify(relativePath: String, userExcludedPaths: [String] = []) throws -> AnalyzerExclusion? {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"), !relativePath.utf8.contains(0), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw AnalyzerSafeRoot.AccessError.invalidPath }
        for rule in userExcludedPaths {
            let components = rule.split(separator: "/", omittingEmptySubsequences: false)
            guard !rule.hasPrefix("/"), !rule.utf8.contains(0), !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw AnalyzerSafeRoot.AccessError.invalidPath }
        }
        let pathBytes = Array(relativePath.utf8)
        for rule in userExcludedPaths {
            let ruleBytes = Array(rule.utf8)
            if pathBytes == ruleBytes || (pathBytes.starts(with: ruleBytes) && pathBytes.count > ruleBytes.count && pathBytes[ruleBytes.count] == 47) { return .userRule }
        }
        for part in parts {
            let name = String(part).lowercased()
            if versionControl.contains(name) { return .versionControl }
            if dependencies.contains(name) { return .dependencies }
            if builds.contains(name) { return .buildOutput }
            if credentialNames.contains(name) || name.hasPrefix(".env.") { return .credentials }
            let ext = name.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            if credentialExtensions.contains(ext) { return .credentials }
            if mediaExtensions.contains(ext) { return .media }
            if archiveExtensions.contains(ext) { return .archive }
            if bundleExtensions.contains(ext) { return .bundle }
        }
        return nil
    }
}
