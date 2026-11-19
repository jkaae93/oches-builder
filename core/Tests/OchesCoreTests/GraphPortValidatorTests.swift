import XCTest
@testable import OchesCore

final class GraphPortValidatorTests: XCTestCase {
    func testTypedSourcesAndUnknownJSON() throws {
        func nodes(_ type: GraphPortType) -> [GraphPortNode] {
            [GraphPortNode(identifier: "producer", inputs: [], outputs: [GraphPort(identifier: "out", type: type, required: false)]),
             GraphPortNode(identifier: "consumer", inputs: [GraphPort(identifier: "in", type: type, required: true)], outputs: [])]
        }
        let target = GraphPortReference(node: "consumer", port: "in")
        let edge = GraphDataEdge(source: GraphPortReference(node: "producer", port: "out"), target: target)
        XCTAssertNoThrow(try GraphPortValidator.validate(nodes: nodes(.text), edges: [edge], externalInputs: []))
        XCTAssertThrowsError(try GraphPortValidator.validate(nodes: nodes(.json), edges: [edge], externalInputs: [])) {
            XCTAssertEqual($0 as? GraphPortError, .jsonCompatibilityUnknown)
        }
        XCTAssertThrowsError(try GraphPortValidator.validate(nodes: nodes(.text), edges: [edge, edge], externalInputs: []))
        XCTAssertThrowsError(try GraphPortValidator.validate(nodes: nodes(.text), edges: [edge], externalInputs: [target]))
        XCTAssertThrowsError(try GraphPortValidator.validate(nodes: nodes(.text), edges: [], externalInputs: []))
        XCTAssertNoThrow(try GraphPortValidator.validate(nodes: nodes(.text), edges: [], externalInputs: [target]))
        XCTAssertThrowsError(try GraphPortValidator.validate(nodes: nodes(.control), edges: [edge], externalInputs: []))
        let reversed = GraphDataEdge(source: target, target: GraphPortReference(node: "producer", port: "out"))
        XCTAssertThrowsError(try GraphPortValidator.validate(nodes: nodes(.text), edges: [reversed], externalInputs: []))
    }
}
