import Foundation

/// An in-memory candidate, not an approved or durably saved Profile. A revision
/// is assigned only by the storage transaction that actually commits a profile.
struct AnalyzerProfileDraft: Codable {
    enum State: String, Codable { case complete, partial, cancelled }
    enum EvidenceComparison: Equatable {
        case changed(paths: [String])
        case indeterminate
    }
    struct Evidence: Codable {
        let relativePath: String
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let sha256: String
    }
    struct Observation: Codable {
        let kind: String
        let value: String
        let evidencePath: String
    }
    struct Inference: Codable {
        let value: String
        let evidencePaths: [String]
    }
    struct Skipped: Codable {
        let relativePath: String
        let reason: String
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let symbolicLinkTarget: String?
    }

    let profileID: String
    let workspaceRef: String
    let analyzerVersion: String
    let analyzedAt: Date
    let roots: [String]
    let exclusions: [String]
    /// Scope candidate metadata, not proof of authorization.
    let scopeDigest: String?
    let exceptionPaths: [String]?
    let observations: [Observation]
    let inferences: [Inference]
    let evidence: [Evidence]
    let skipped: [Skipped]
    let uncertainties: [String]
    let limitsReached: [String]
    let userConstraints: [String]
    let state: State

    /// Detects changes to previously read files present in both snapshots.
    /// The caller must first establish that both snapshots use the same
    /// authorized root and scope; this internal comparison cannot verify that.
    /// Matching evidence cannot establish freshness: scope identity, unread
    /// files and concurrent changes still require a verified reanalysis flow.
    func compareReadEvidence(with collection: AnalyzerSafeRoot.EvidenceCollection) -> EvidenceComparison {
        var current: [Data: AnalyzerSafeRoot.FileEvidence] = [:]
        for file in collection.files {
            let key = Data(file.relativePath.utf8)
            guard current[key] == nil else { return .indeterminate }
            current[key] = file
        }
        var seen = Set<Data>()
        var changed: [String] = []
        for old in evidence {
            let key = Data(old.relativePath.utf8)
            guard seen.insert(key).inserted else { return .indeterminate }
            guard let new = current[key] else { continue }
            if old.size != new.size || old.modifiedSeconds != new.modifiedSeconds ||
                old.modifiedNanoseconds != new.modifiedNanoseconds || old.sha256 != new.sha256 {
                changed.append(old.relativePath)
            }
        }
        return changed.isEmpty ? .indeterminate : .changed(paths: changed.sorted())
    }

    /// Does not perform I/O, decide permissions, transmit data, or persist.
    static func build(profileID: String, workspaceRef: String, analyzerVersion: String,
                      analyzedAt: Date, roots: [String], exclusions: [String],
                      userConstraints: [String], collection: AnalyzerSafeRoot.EvidenceCollection,
                      scopeDigest: String? = nil, exceptionPaths: [String]? = nil) throws -> AnalyzerProfileDraft {
        guard !profileID.isEmpty, !workspaceRef.isEmpty, !analyzerVersion.isEmpty,
              !roots.isEmpty, roots.allSatisfy({ !$0.isEmpty }) else { throw AnalyzerSafeRoot.AccessError.invalidPath }
        let evidence = collection.files.map {
            Evidence(relativePath: $0.relativePath, size: $0.size, modifiedSeconds: $0.modifiedSeconds,
                     modifiedNanoseconds: $0.modifiedNanoseconds, sha256: $0.sha256)
        }
        let extensions = ["swift", "dart", "py", "js", "ts", "rs", "go", "java", "kt"]
        let observations: [Observation] = evidence.compactMap { item in
            let name = item.relativePath.split(separator: "/").last.map(String.init) ?? ""
            let ext = name.split(separator: ".").last.map { String($0).lowercased() } ?? ""
            guard extensions.contains(ext), name.contains(".") else { return nil }
            return Observation(kind: "source_extension", value: ext, evidencePath: item.relativePath)
        }
        // Extension observations do not prove build configuration or primary language.
        let inferences: [Inference] = []
        let readPaths = Set(collection.files.map { Data($0.relativePath.utf8) })
        let skipped = collection.preview.entries.compactMap { entry -> Skipped? in
            let reason: String
            if let exclusion = entry.exclusion { reason = "excluded_" + exclusion.rawValue }
            else if let unread = collection.unreadReasons[Data(entry.relativePath.utf8)] { reason = unread }
            else if entry.kind == .symbolicLink { reason = "symbolic_link_not_followed" }
            else if entry.kind == .other { reason = "unsupported_file_type" }
            else if entry.kind == .regular && !readPaths.contains(Data(entry.relativePath.utf8)) { reason = "not_analyzed" }
            else { return nil }
            return Skipped(relativePath: entry.relativePath, reason: reason, size: entry.size,
                           modifiedSeconds: entry.modifiedSeconds, modifiedNanoseconds: entry.modifiedNanoseconds,
                           symbolicLinkTarget: entry.symbolicLinkTarget)
        }
        let limits = collection.partialReasons.filter { ["entry_limit", "time_limit", "depth_limit", "file_limit", "total_limit"].contains($0) }.sorted()
        var uncertainties = ["secret_detection_incomplete", "project_language_unknown", "freshness_unverified"]
        if !collection.partialReasons.isEmpty { uncertainties.append("analysis_incomplete") }
        let state: State = collection.cancelled ? .cancelled : collection.partialReasons.isEmpty ? .complete : .partial
        return AnalyzerProfileDraft(profileID: profileID, workspaceRef: workspaceRef, analyzerVersion: analyzerVersion,
                                    analyzedAt: analyzedAt, roots: roots, exclusions: exclusions, scopeDigest: scopeDigest,
                                    exceptionPaths: exceptionPaths, observations: observations,
                                    inferences: inferences, evidence: evidence, skipped: skipped, uncertainties: uncertainties,
                                    limitsReached: limits, userConstraints: userConstraints, state: state)
    }
}
