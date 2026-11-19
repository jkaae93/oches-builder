import Foundation
import XCTest
@testable import OchesCore

final class TemplateSharedFixtureTests: XCTestCase {
    private struct Case: Decodable { let name: String; let rawJSON: String; let coreValid: Bool }

    func testSharedStructuralAndSemanticCases() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cases", withExtension: "json", subdirectory: "Fixtures/template-exchange"))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        for item in cases {
            if item.coreValid {
                XCTAssertNoThrow(try TemplateGraphDecoder.decode(TemplateExchangeCandidate.parse(Data(item.rawJSON.utf8))), item.name)
            } else {
                XCTAssertThrowsError(try TemplateGraphDecoder.decode(TemplateExchangeCandidate.parse(Data(item.rawJSON.utf8))), item.name)
            }
        }
    }
}
