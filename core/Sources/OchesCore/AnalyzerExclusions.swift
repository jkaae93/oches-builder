import Foundation

/// Default content exclusions; this policy does not claim to identify all secrets.
/// Overrides must be path-specific and separately bound to a verified approval;
/// this internal classifier does not implement overrides.
enum AnalyzerExclusion: String, Sendable {
    case credentials, versionControl, dependencies, buildOutput, media, archive, bundle, userRule
}

struct AnalyzerExclusions {
    private static let versionControl: Set<String> = [".git", ".hg", ".svn"]
    private static let dependencies: Set<String> = ["node_modules", ".dart_tool", ".pub-cache", "vendor", "pods", ".venv", "venv", "__pycache__"]
    private static let builds: Set<String> = ["build", "dist", "target", ".next", ".gradle", "deriveddata", "coverage"]
    private static let credentialNames: Set<String> = [".env", ".ssh", ".aws", ".gnupg", ".kube", ".netrc", ".npmrc", ".pypirc", "id_rsa", "id_ed25519", "credentials", "credentials.json", "service-account.json"]
    private static let credentialExtensions: Set<String> = ["pem", "key", "p12", "pfx", "keystore", "jks"]
    private static let mediaExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "mp3", "wav", "mp4", "mov", "avi", "pdf"]
    private static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "bz2", "xz", "7z", "rar", "dmg", "iso"]
    private static let bundleExtensions: Set<String> = ["app", "framework", "bundle", "xcassets", "xcodeproj", "xcworkspace"]

    /// User rules are exact relative paths or subtree roots, never globs.
    static func classify(relativePath: String, userExcludedPaths: Set<String> = []) throws -> AnalyzerExclusion? {
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
