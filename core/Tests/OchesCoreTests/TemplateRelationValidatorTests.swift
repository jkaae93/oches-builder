import XCTest
@testable import OchesCore

final class TemplateRelationValidatorTests: XCTestCase {
    func testDependencyAndDataValidationAreIntegrated() throws {
        func node(_ identifier: String, dataType: GraphPortType = .text, kind: TemplateNodeKind = .task) -> TemplateGraphNode {
            TemplateGraphNode(kind: kind, ports: GraphPortNode(identifier: identifier,
                inputs: [GraphPort(identifier: "start", type: .control, required: false),
                         GraphPort(identifier: "input", type: dataType, required: false)],
                outputs: [GraphPort(identifier: "done", type: .control, required: false),
                          GraphPort(identifier: "output", type: dataType, required: false)]))
        }
        func dependency(_ source: String, _ target: String) -> TemplateGraphRelation {
            TemplateGraphRelation(kind: .dependency, source: source, target: target, sourcePort: "done", targetPort: "start")
        }
        let flow = TemplateGraphRelation(kind: .data, source: "a", target: "c", sourcePort: "output", targetPort: "input")
        let nodes = [node("a"), node("b"), node("c")]
        let order = [dependency("a", "b"), dependency("b", "c")]
        XCTAssertNoThrow(try TemplateRelationValidator.validate(nodes: nodes, relations: order + [flow], externalInputs: []))
        XCTAssertThrowsError(try TemplateRelationValidator.validate(nodes: nodes, relations: [flow], externalInputs: [])) {
            XCTAssertEqual($0 as? TaskDependencyError, .missingDataOrder)
        }
        XCTAssertThrowsError(try TemplateRelationValidator.validate(nodes: nodes, relations: order + [dependency("c", "a")], externalInputs: [])) {
            XCTAssertEqual($0 as? TaskDependencyError, .cycle)
        }
        let wrongControl = TemplateGraphRelation(kind: .dependency, source: "a", target: "b", sourcePort: "output", targetPort: "input")
        XCTAssertThrowsError(try TemplateRelationValidator.validate(nodes: nodes, relations: [wrongControl], externalInputs: []))
        XCTAssertThrowsError(try TemplateRelationValidator.validate(nodes: [node("a", kind: .agent), node("b")], relations: [dependency("a", "b")], externalInputs: []))
        XCTAssertThrowsError(try TemplateRelationValidator.validate(nodes: [node("a"), node("b"), node("c", dataType: .artifactRef)], relations: order + [flow], externalInputs: [])) {
            XCTAssertEqual($0 as? GraphPortError, .portMismatch)
        }
        XCTAssertThrowsError(try TemplateRelationValidator.validate(nodes: [node("a", dataType: .json), node("b"), node("c", dataType: .json)], relations: order + [flow], externalInputs: [])) {
            XCTAssertEqual($0 as? GraphPortError, .jsonCompatibilityUnknown)
        }
    }

    func testReferenceKindsAndDirectionAndAmbiguousRole() throws {
        let kinds: [(String, TemplateNodeKind)] = [("task", .task), ("agent", .agent), ("otherAgent", .agent),
            ("tool", .tool), ("memory", .memory), ("evaluation", .evaluation), ("approval", .approval)]
        let nodes = kinds.map { TemplateGraphNode(kind: $0.1, ports: GraphPortNode(identifier: $0.0, inputs: [], outputs: [])) }
        func relation(_ kind: TemplateRelationKind, _ source: String, _ target: String) -> TemplateGraphRelation {
            TemplateGraphRelation(kind: kind, source: source, target: target, sourcePort: nil, targetPort: nil)
        }
        let valid = [relation(.roleBinding, "task", "agent"), relation(.toolRef, "agent", "tool"),
            relation(.memoryRef, "task", "memory"), relation(.evaluationRef, "task", "evaluation"), relation(.approvalRef, "task", "approval")]
        XCTAssertNoThrow(try TemplateRelationValidator.validate(nodes: nodes, relations: valid, externalInputs: []))
        XCTAssertThrowsError(try TemplateRelationValidator.validate(nodes: nodes, relations: valid + [relation(.roleBinding, "task", "otherAgent")], externalInputs: []))
        XCTAssertThrowsError(try TemplateRelationValidator.validate(nodes: nodes, relations: [relation(.toolRef, "tool", "agent")], externalInputs: []))
        XCTAssertThrowsError(try TemplateRelationValidator.validate(nodes: nodes, relations: [valid[0], valid[0]], externalInputs: []))
        XCTAssertThrowsError(try TemplateRelationValidator.validate(nodes: nodes, relations: [relation(.memoryRef, "task", "missing")], externalInputs: []))
    }
}
