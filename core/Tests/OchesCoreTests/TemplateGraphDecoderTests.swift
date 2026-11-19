import Foundation
import XCTest
@testable import OchesCore

final class TemplateGraphDecoderTests: XCTestCase {
    func testToolMemoryEvaluationAndApprovalDeclarations() throws {
        let cases: [(String, String, TemplateNodeKind)] = [
            ("tool", #""capability":"file.read","permissions":[]"#, .tool),
            ("memory", #""memoryRef":{"id":"memory","revision":"1"},"evidenceRefs":[{"id":"evidence","revision":"2"}]"#, .memory),
            ("evaluation", #""criteriaRef":{"id":"criteria","revision":"1"},"evaluatorRef":{"id":"evaluator","revision":"1"}"#, .evaluation),
            ("approval", #""action":"apply","scope":"workspace","targetRef":{"id":"target","revision":"1"},"expiresAfterSeconds":900"#, .approval)
        ]
        for (kind, fields, expected) in cases {
            let node = "{\"id\":\"node\",\"kind\":\"\(kind)\",\"label\":\"fixture\",\"inputs\":[],\"outputs\":[],\"requirements\":[],\(fields)}"
            let envelope = "{\"schemaVersion\":{\"major\":1,\"minor\":0},\"metadata\":{\"name\":\"fixture\",\"description\":\"\",\"tags\":[],\"useCases\":[]},\"nodes\":[\(node)],\"edges\":[],\"requirements\":{\"capabilities\":[],\"permissions\":[]}}"
            let graph = try TemplateGraphDecoder.decode(TemplateExchangeCandidate.parse(Data(envelope.utf8)))
            XCTAssertEqual(graph.nodes.first?.kind, expected)
            if kind == "memory" {
                XCTAssertEqual(graph.domainReferences.map(\.role), ["memory", "evidence"])
                XCTAssertEqual(graph.domainReferences.map(\.revision), ["1", "2"])
            }
            let invalid = envelope.replacingOccurrences(of: "\"requirements\":[]", with: "\"credential\":\"fixture\",\"requirements\":[]")
            XCTAssertThrowsError(try TemplateGraphDecoder.decode(TemplateExchangeCandidate.parse(Data(invalid.utf8))))
        }
    }

    func testTaskPayloadBoundsAndUnknownFields() throws {
        let task = #"{"id":"task","kind":"task","label":"Task","goal":"synthetic goal","inputs":[],"outputs":[],"resourceLimits":{"maxDurationSeconds":60,"maxRetries":3},"requirements":[]}"#
        let envelope = #"{"schemaVersion":{"major":1,"minor":0},"metadata":{"name":"fixture","description":"","tags":[],"useCases":[]},"nodes":[NODE],"edges":[],"requirements":{"capabilities":[],"permissions":[]}}"#
        func decode(_ node: String) throws -> DecodedTemplateGraph {
            try TemplateGraphDecoder.decode(TemplateExchangeCandidate.parse(Data(envelope.replacingOccurrences(of: "NODE", with: node).utf8)))
        }
        XCTAssertEqual(try decode(task).nodes.first?.kind, .task)
        for input in [task.replacingOccurrences(of: "\"maxRetries\":3", with: "\"maxRetries\":4"),
                      task.replacingOccurrences(of: "\"maxDurationSeconds\":60", with: "\"maxDurationSeconds\":86401"),
                      task.replacingOccurrences(of: "synthetic goal", with: " "),
                      task.replacingOccurrences(of: "\"goal\":", with: "\"accountRef\":\"private\",\"goal\":")] {
            XCTAssertThrowsError(try decode(input))
        }
    }

    private let sample = #"{"schemaVersion":{"major":1,"minor":0},"metadata":{"name":"fixture","description":"","tags":[],"useCases":[]},"nodes":[{"id":"agent","kind":"agent","label":"Agent","definition":{"schemaVersion":{"major":1,"minor":0},"definitionId":"definition","revision":1,"role":"review","instructions":"inspect","inputs":[],"outputs":[],"tools":[],"permissions":[],"resourceLimits":{"maxDurationSeconds":60,"maxAttempts":1}},"requirements":[]}],"edges":[],"requirements":{"capabilities":[],"permissions":[]}}"#

    func testAgentExchangeUsesDefinitionAndGraphValidation() throws {
        let graph = try TemplateGraphDecoder.decode(TemplateExchangeCandidate.parse(Data(sample.utf8)))
        XCTAssertEqual(graph.nodes.count, 1)
        XCTAssertEqual(graph.exchangeDigest, try TemplateExchangeCandidate.parse(Data(sample.utf8)).contentDigest)
        for text in [sample.replacingOccurrences(of: "\"label\":", with: "\"credential\":\"fixture\",\"label\":"),
                     sample.replacingOccurrences(of: "\"kind\":\"agent\"", with: "\"kind\":\"task\""),
                     sample.replacingOccurrences(of: "\"maxAttempts\":1", with: "\"maxAttempts\":0"),
                     sample.replacingOccurrences(of: "\"capabilities\":[]", with: "\"capabilities\":[{\"capability\":\"file.read\",\"required\":1}]"),
                     sample.replacingOccurrences(of: "\"permissions\":[]}", with: "\"permissions\":[{\"action\":\"read\",\"scope\":\"workspace\",\"approvalRequired\":false,\"extra\":true}]}")] {
            XCTAssertThrowsError(try TemplateGraphDecoder.decode(TemplateExchangeCandidate.parse(Data(text.utf8))))
        }
    }
}
