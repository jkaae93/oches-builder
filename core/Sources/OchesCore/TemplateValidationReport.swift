import Foundation

enum TemplateValidationResult: String { case pass, fail, unknown }
enum TemplateValidationReportError: Error { case invalidBinding, stale }

struct TemplateValidationBinding {
    let instance: RevisionRef
    let definitions: [RevisionRef]
    let graphDigest: Data
    let schemaMajor: Int
    let schemaMinor: Int
    let capabilitySnapshotID: String
    let capabilityVersion: String
    let policyVersion: String
    let validatorVersion: String
    var exchangeDigest: Data? = nil

    func digest() throws -> Data {
        func valid(_ value: String) -> Bool { !value.isEmpty && !value.utf8.contains(0) && value.utf8.count <= 65_536 }
        func reference(_ revision: RevisionRef) throws -> RawJSONValue {
            guard valid(revision.objectID), valid(revision.storeGeneration),
                  !revision.revision.isEmpty, revision.revision.utf8.allSatisfy({ (48...57).contains($0) }),
                  revision.revision.first != "0", UInt64(revision.revision) != nil
            else { throw TemplateValidationReportError.invalidBinding }
            return .object([("id", .string(revision.objectID)), ("generation", .string(revision.storeGeneration)),
                ("revision", .string(revision.revision))])
        }
        guard graphDigest.count == 32, exchangeDigest == nil || exchangeDigest?.count == 32,
              definitions.count <= 1024, schemaMajor == 1, schemaMinor == 0,
              [capabilitySnapshotID, capabilityVersion, policyVersion, validatorVersion].allSatisfy(valid)
        else { throw TemplateValidationReportError.invalidBinding }
        var seen = Set<Data>()
        let sorted = definitions.sorted { $0.objectID.utf8.lexicographicallyPrecedes($1.objectID.utf8) }
        let references = try sorted.map { definition -> RawJSONValue in
            guard seen.insert(Data(definition.objectID.utf8)).inserted else { throw TemplateValidationReportError.invalidBinding }
            return try reference(definition)
        }
        return try canonicalSHA256(.object([
            ("domain", .string("oches.template.validation-binding.v1")), ("instance", try reference(instance)),
            ("definitions", .array(references)),
            ("graphDigest", .string(graphDigest.map { String(format: "%02x", $0) }.joined())),
            ("exchangeDigest", exchangeDigest.map { .string($0.map { String(format: "%02x", $0) }.joined()) } ?? .null),
            ("schemaMajor", .number(String(schemaMajor))), ("schemaMinor", .number(String(schemaMinor))),
            ("snapshot", .string(capabilitySnapshotID)), ("capabilityVersion", .string(capabilityVersion)),
            ("policyVersion", .string(policyVersion)), ("validatorVersion", .string(validatorVersion))
        ]))
    }
}

struct TemplateValidationReport {
    let bindingDigest: Data
    let observedAt: Int64
    let structural: TemplateValidationResult
    let capability: TemplateValidationResult
    let policy: TemplateValidationResult

    init(binding: TemplateValidationBinding, observedAt: Int64, structural: TemplateValidationResult,
         capability: TemplateValidationResult, policy: TemplateValidationResult) throws {
        guard observedAt >= 0 else { throw TemplateValidationReportError.invalidBinding }
        self.bindingDigest = try binding.digest()
        self.observedAt = observedAt
        self.structural = structural
        self.capability = capability
        self.policy = policy
    }

    func validateFreshness(current: TemplateValidationBinding, now: Int64) throws {
        guard now >= observedAt, now - observedAt < 86_400,
              try current.digest() == bindingDigest else { throw TemplateValidationReportError.stale }
    }
}
