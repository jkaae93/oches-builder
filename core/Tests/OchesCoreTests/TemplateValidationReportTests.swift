import Foundation
import XCTest
@testable import OchesCore

final class TemplateValidationReportTests: XCTestCase {
    func testFullExchangeChangeCannotReuseSameStructuralReport() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cases", withExtension: "json", subdirectory: "Fixtures/template-exchange"))
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let raw = try XCTUnwrap(cases.first?["rawJSON"] as? String)
        let original = try TemplateExchangeCandidate.parse(Data(raw.utf8))
        let graph = try TemplateGraphDecoder.decode(original)
        let digest = try TemplateStructuralReport.graphDigest(nodes: graph.nodes, relations: graph.relations, externalInputs: graph.externalInputs)
        var binding = TemplateValidationBinding(instance: RevisionRef(objectID: "instance", storeGeneration: "gen", revision: "1"),
            definitions: [], graphDigest: digest, schemaMajor: 1, schemaMinor: 0,
            capabilitySnapshotID: "snapshot", capabilityVersion: "1", policyVersion: "1", validatorVersion: "1")
        XCTAssertThrowsError(try TemplateStructuralReport.validate(candidate: original, binding: binding, observedAt: 100))
        binding.exchangeDigest = original.contentDigest
        let report = try TemplateStructuralReport.validate(candidate: original, binding: binding, observedAt: 100)
        let changed = try TemplateExchangeCandidate.parse(Data(raw.replacingOccurrences(of: "inspect", with: "changed instructions").utf8))
        let changedGraph = try TemplateGraphDecoder.decode(changed)
        XCTAssertEqual(digest, try TemplateStructuralReport.graphDigest(nodes: changedGraph.nodes, relations: changedGraph.relations, externalInputs: changedGraph.externalInputs))
        XCTAssertThrowsError(try TemplateStructuralReport.validate(candidate: changed, binding: binding, observedAt: 101))
        binding.exchangeDigest = changed.contentDigest
        XCTAssertThrowsError(try report.validateFreshness(current: binding, now: 101))
    }

    func testStructuralReportUsesValidatedGraphDigestWithoutClaimingSupport() throws {
        let nodes = [TemplateGraphNode(kind: .task, ports: GraphPortNode(identifier: "task", inputs: [], outputs: []))]
        let digest = try TemplateStructuralReport.graphDigest(nodes: nodes, relations: [], externalInputs: [])
        func binding(_ graphDigest: Data) -> TemplateValidationBinding {
            TemplateValidationBinding(instance: RevisionRef(objectID: "instance", storeGeneration: "gen", revision: "1"),
                definitions: [], graphDigest: graphDigest, schemaMajor: 1, schemaMinor: 0,
                capabilitySnapshotID: "snapshot", capabilityVersion: "1", policyVersion: "1", validatorVersion: "1")
        }
        let report = try TemplateStructuralReport.validate(nodes: nodes, relations: [], externalInputs: [], binding: binding(digest), observedAt: 100)
        XCTAssertEqual(report.structural, .pass)
        XCTAssertEqual(report.capability, .unknown)
        XCTAssertEqual(report.policy, .unknown)
        XCTAssertThrowsError(try TemplateStructuralReport.validate(nodes: nodes, relations: [], externalInputs: [],
            binding: binding(Data(repeating: 0, count: 32)), observedAt: 100))
    }

    func testVersionAndTimeChangesInvalidateReport() throws {
        func binding(_ revision: String = "1", policy: String = "1", snapshot: String = "snapshot") -> TemplateValidationBinding {
            TemplateValidationBinding(instance: RevisionRef(objectID: "instance", storeGeneration: "gen", revision: revision),
                definitions: [RevisionRef(objectID: "definition", storeGeneration: "gen", revision: "1")],
                graphDigest: Data(repeating: 1, count: 32), schemaMajor: 1, schemaMinor: 0,
                capabilitySnapshotID: snapshot, capabilityVersion: "1", policyVersion: policy, validatorVersion: "1")
        }
        let report = try TemplateValidationReport(binding: binding(), observedAt: 100, structural: .pass, capability: .unknown, policy: .unknown)
        XCTAssertNoThrow(try report.validateFreshness(current: binding(), now: 86_499))
        XCTAssertEqual(report.capability, .unknown)
        for current in [binding("2"), binding(policy: "2"), binding(snapshot: "new")] {
            XCTAssertThrowsError(try report.validateFreshness(current: current, now: 101))
        }
        XCTAssertThrowsError(try report.validateFreshness(current: binding(), now: 86_500))
        XCTAssertThrowsError(try report.validateFreshness(current: binding(), now: 99))
        XCTAssertThrowsError(try binding("01").digest())
    }
}
