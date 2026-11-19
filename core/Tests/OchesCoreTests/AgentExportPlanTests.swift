import Foundation
import XCTest
@testable import OchesCore

final class AgentExportPlanTests: XCTestCase {
    private func fixture() throws -> (ValidatedAgentDefinition, AgentExportBinding, [AgentFieldMapping]) {
        let data = Data(#"{"schemaVersion":{"major":1,"minor":0},"definitionId":"agent","revision":1,"role":"review","instructions":"inspect","inputs":[],"outputs":[],"tools":[],"permissions":[],"resourceLimits":{"maxDurationSeconds":60,"maxAttempts":1}}"#.utf8)
        let definition = try AgentDefinitionValidator.validate(data)
        let binding = AgentExportBinding(definitionRevision: RevisionRef(objectID: "arc04/definition/agent/1", storeGeneration: "g1", revision: "1"),
            definitionDigest: definition.digest, adapterVersion: "1", providerVersion: "1",
            capabilitySnapshotID: "snapshot", capabilityVersion: "1", targetPath: "/fixture/config", targetDigest: nil)
        let fields = ["schemaVersion", "definitionId", "revision", "role", "instructions", "inputs", "outputs", "tools", "permissions", "resourceLimits"]
        return (definition, binding, fields.map { AgentFieldMapping(field: $0, quality: .exact,
            targetField: $0, officialEvidence: "fixture-document-v1", experimentEvidence: "fixture-test-v1") })
    }

    func testStablePlanAndStaleProviderRejected() throws {
        let (definition, binding, mappings) = try fixture()
        let plan = try AgentExportPlan.build(definition: definition, binding: binding, mappings: mappings)
        XCTAssertEqual(plan.digest, try AgentExportPlan.build(definition: definition, binding: binding, mappings: mappings.reversed()).digest)
        XCTAssertNoThrow(try plan.revalidate(current: binding))
        let changed = AgentExportBinding(definitionRevision: binding.definitionRevision, definitionDigest: definition.digest,
            adapterVersion: "1", providerVersion: "2", capabilitySnapshotID: "snapshot", capabilityVersion: "1",
            targetPath: "/fixture/config", targetDigest: nil)
        XCTAssertThrowsError(try plan.revalidate(current: changed))
    }

    func testSafetyLossAndMissingEvidenceOrMappingRejected() throws {
        let (definition, binding, mappings) = try fixture()
        for quality in [AgentMappingQuality.lossy, .unknown, .unsupported] {
            let changed = mappings.map { $0.field == "permissions" ? AgentFieldMapping(field: "permissions", quality: quality,
                targetField: nil, officialEvidence: nil, experimentEvidence: nil) : $0 }
            XCTAssertThrowsError(try AgentExportPlan.build(definition: definition, binding: binding, mappings: changed))
        }
        XCTAssertThrowsError(try AgentExportPlan.build(definition: definition, binding: binding, mappings: Array(mappings.dropLast())))
        let unverified = mappings.map { AgentFieldMapping(field: $0.field, quality: .exact, targetField: $0.field,
            officialEvidence: "fixture", experimentEvidence: nil) }
        XCTAssertThrowsError(try AgentExportPlan.build(definition: definition, binding: binding, mappings: unverified))
    }

    func testPublishedSecondVersionUsesFirstStorageRevisionAndRejectsWrongObject() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AgentDefinitionRepository(store: try SQLiteStore(path: directory.appendingPathComponent("db").path,
            workspaceID: "ws", initialStoreGeneration: "gen"))
        let data = Data(#"{"schemaVersion":{"major":1,"minor":0},"definitionId":"agent","revision":2,"role":"review","instructions":"inspect","inputs":[],"outputs":[],"tools":[],"permissions":[],"resourceLimits":{"maxDurationSeconds":60,"maxAttempts":1}}"#.utf8)
        let published = try repository.save(data, actorID: "actor", requestID: "publish", nowEpochSeconds: 100)
        XCTAssertEqual(published.revision.revision, "1")
        let definition = try AgentDefinitionValidator.validate(data)
        let (_, _, mappings) = try fixture()
        func binding(_ revision: RevisionRef) -> AgentExportBinding {
            AgentExportBinding(definitionRevision: revision, definitionDigest: definition.digest,
                adapterVersion: "1", providerVersion: "1", capabilitySnapshotID: "snapshot", capabilityVersion: "1",
                targetPath: "/fixture/config", targetDigest: nil)
        }
        let plan = try repository.planExport(definitionID: "agent", definitionRevision: 2,
            binding: binding(published.revision), mappings: mappings)
        XCTAssertEqual(plan.binding.definitionRevision, published.revision)
        XCTAssertThrowsError(try repository.planExport(definitionID: "agent", definitionRevision: 1,
            binding: binding(published.revision), mappings: mappings))
        XCTAssertThrowsError(try AgentExportPlan.build(definition: definition,
            binding: binding(RevisionRef(objectID: "arc04/definition/other/2", storeGeneration: "gen", revision: "1")), mappings: mappings))
        XCTAssertThrowsError(try repository.planExport(definitionID: "agent", definitionRevision: 2,
            binding: binding(RevisionRef(objectID: published.revision.objectID, storeGeneration: "old", revision: "1")), mappings: mappings))
    }

    func testApprovedDocumentBindsExactOutputAndAbsentVersusEmptyTarget() throws {
        let (definition, binding, mappings) = try fixture()
        let plan = try AgentExportPlan.build(definition: definition, binding: binding, mappings: mappings)
        let proposed = Data("synthetic configuration\n".utf8)
        let document = try AgentExportDocument.prepare(plan: plan, previousContent: nil, proposedContent: proposed)
        XCTAssertNoThrow(try document.revalidate(currentBinding: binding, currentContent: nil, proposedContent: proposed))
        XCTAssertThrowsError(try document.revalidate(currentBinding: binding, currentContent: Data(), proposedContent: proposed))
        XCTAssertThrowsError(try document.revalidate(currentBinding: binding, currentContent: nil, proposedContent: Data("changed".utf8)))
        let other = try AgentExportDocument.prepare(plan: plan, previousContent: nil, proposedContent: Data("changed".utf8))
        XCTAssertNotEqual(document.approvalDigest, other.approvalDigest)
        let request = try document.approvalRequestBinding(planID: "plan")
        XCTAssertTrue(request.isValid(for: .configExportApply))
        XCTAssertEqual(request.targetFileVersions?[binding.targetPath], "ABSENT")
        XCTAssertEqual(request.agentDefinitionRevision, binding.definitionRevision)
        XCTAssertNotEqual(request.planDigest, try other.approvalRequestBinding(planID: "plan").planDigest)
        XCTAssertThrowsError(try document.approvalRequestBinding(planID: ""))
        XCTAssertThrowsError(try AgentExportDocument.prepare(plan: plan, previousContent: Data(), proposedContent: proposed))
        XCTAssertThrowsError(try AgentExportDocument.prepare(plan: plan, previousContent: nil, proposedContent: Data([0xff])))
        XCTAssertThrowsError(try AgentExportDocument.prepare(plan: plan, previousContent: nil, proposedContent: Data([0])))
        XCTAssertThrowsError(try AgentExportDocument.prepare(plan: plan, previousContent: nil, proposedContent: Data(repeating: 32, count: 262_145)))
    }

    func testApplyBindingIdentityIncludesTargetVersionAndExactUnicodeBytes() throws {
        let revision = RevisionRef(objectID: "definition", storeGeneration: "gen", revision: "1")
        func binding(_ path: String, _ version: String = "ABSENT") -> ApprovalBinding {
            ApprovalBinding(planID: "plan", planDigest: "digest", targetFileVersions: [path: version],
                agentDefinitionRevision: revision, adapterVersion: "1")
        }
        XCTAssertEqual(try binding("/fixture/config").canonicalApplyIdentity(), try binding("/fixture/config").canonicalApplyIdentity())
        XCTAssertNotEqual(try binding("/fixture/config").canonicalApplyIdentity(), try binding("/fixture/config", "hash").canonicalApplyIdentity())
        XCTAssertNotEqual(try binding("/fixture/\u{e9}").canonicalApplyIdentity(), try binding("/fixture/e\u{301}").canonicalApplyIdentity())
        XCTAssertThrowsError(try ApprovalBinding().canonicalApplyIdentity())
    }
}
