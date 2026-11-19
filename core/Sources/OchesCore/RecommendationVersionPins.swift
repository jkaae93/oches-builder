import CryptoKit
import Foundation

struct RecommendationVersionPins {
    let digest: Data

    static func capture(profile: AnalyzerProfileDraft, profileRevision: RevisionRef,
                        snapshot: CapabilitySnapshot, registryVersions: [RevisionRef],
                        constraints: [RecommendationConstraint], requiredCapabilities: [CapabilityID] = []) throws -> RecommendationVersionPins {
        guard profileRevision.objectID.utf8.elementsEqual(("arc02/profile/" + profile.profileID).utf8),
              profile.workspaceRef.utf8.elementsEqual(snapshot.scope.workspaceID.utf8),
              registryVersions.count <= 1024 else { throw RecommendationConstraintError.invalidInput }
        _ = try RecommendationConstraintEvaluator.evaluate(constraints, facts: [:])
        func revision(_ value: RevisionRef) throws -> RawJSONValue {
            guard !value.objectID.isEmpty, !value.storeGeneration.isEmpty,
                  value.revision.first != "0", !value.revision.isEmpty,
                  value.revision.utf8.allSatisfy({ (48...57).contains($0) }), UInt64(value.revision) != nil
            else { throw RecommendationConstraintError.invalidInput }
            return .object([("id", .string(value.objectID)), ("generation", .string(value.storeGeneration)), ("revision", .string(value.revision))])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let profileHash = Data(SHA256.hash(data: try encoder.encode(profile)))
        let scopeData = try encoder.encode(snapshot.scope)
        let entries: [RawJSONValue] = snapshot.entries.keys.sorted { $0.rawValue < $1.rawValue }.map { identifier in
            let entry = snapshot.entries[identifier]!
            return .object([("key", .string(identifier.rawValue)), ("id", .string(entry.capabilityID.rawValue)),
                ("status", .string(entry.status.rawValue)), ("basis", .string(entry.basis.rawValue)),
                ("evidence", .string(entry.evidenceRef)), ("observedAt", .string(String(entry.observedAt)))])
        }
        let records: [RawJSONValue] = constraints.map { constraint in
            let fact: RawJSONValue
            switch constraint.value {
            case .boolean(let value): fact = .object([("boolean", .bool(value))])
            case .integer(let value): fact = .object([("integer", .string(String(value)))])
            case .text(let value): fact = .object([("text", .string(value))])
            }
            return .object([("id", .string(constraint.constraintID)), ("subject", .string(constraint.subject)),
                ("predicate", .string(constraint.predicate.rawValue)), ("value", fact), ("version", .string(constraint.version))])
        }
        let digest = try canonicalSHA256(.object([
            ("domain", .string("oches.recommendation.inputs.v1")), ("profile", try revision(profileRevision)),
            ("profileDigest", .string(profileHash.base64EncodedString())),
            ("snapshotID", .string(snapshot.snapshotID)), ("scope", .string(String(decoding: scopeData, as: UTF8.self))),
            ("entries", .array(entries)), ("snapshotTime", .string(String(snapshot.observedAt))),
            ("registry", .array(try registryVersions.map(revision))), ("constraints", .array(records)),
            ("requiredCapabilities", .array(requiredCapabilities.map(\.rawValue).sorted().map { .string($0) })),
            ("ruleVersion", .string(ArchitectureCandidateGenerator.version))
        ]))
        return RecommendationVersionPins(digest: digest)
    }
}

struct ArchitectureProposal {
    let pins: RecommendationVersionPins
    let createdAt: Int64
    let candidates: [ArchitectureCandidate]

    func validateFreshness(current: RecommendationVersionPins, now: Int64) throws {
        guard createdAt >= 0, now >= createdAt, now - createdAt < 86_400, pins.digest == current.digest
        else { throw TemplateValidationReportError.stale }
    }
}
