import XCTest
@testable import OchesCore

final class AnalyzerExclusionsTests: XCTestCase {
    func testCompiledRulesMatchReferenceAndHandleLargeLists() throws {
        let exclusions = (0..<10_000).map { "private/item\($0)" } + ["\u{00e9}"]
        let exceptions = (0..<10_000).map { ".git/item\($0)/allowed" }
        let rules = try AnalyzerExclusions.Compiled(userExcludedPaths: exclusions, exceptionPaths: exceptions)
        for path in ["private/item9999/a", "private/item10000/a", ".git/item9999/allowed", "e\u{0301}", "\u{00e9}"] {
            XCTAssertEqual(try rules.classify(path), try AnalyzerExclusions.classify(relativePath: path, userExcludedPaths: exclusions))
        }
        XCTAssertTrue(rules.isException(".git/item9999/allowed"))
        XCTAssertTrue(rules.leadsToException(".git/item9999"))
        XCTAssertFalse(rules.isException(".git/item9999/allowed/child"))
        XCTAssertFalse(rules.leadsToException(".git/item10000"))
    }

    func testUserRulesPreserveDistinctUnicodeByteSequences() throws {
        let composed = "\u{00e9}"
        let decomposed = "e\u{0301}"
        XCTAssertEqual(try AnalyzerExclusions.classify(relativePath: composed, userExcludedPaths: [composed, decomposed]), .userRule)
        XCTAssertEqual(try AnalyzerExclusions.classify(relativePath: decomposed, userExcludedPaths: [composed, decomposed]), .userRule)
        XCTAssertNil(try AnalyzerExclusions.classify(relativePath: decomposed, userExcludedPaths: [composed]))
    }

    func testDefaultsCoverRequiredCategoriesAndNestedPaths() throws {
        let cases: [(String, AnalyzerExclusion)] = [
            ("a/.env.local", .credentials), (".ssh/config", .credentials), ("a/id_ed25519", .credentials), ("a/key.pem", .credentials),
            ("a/.git/config", .versionControl), ("node_modules/pkg/x", .dependencies),
            ("build/out", .buildOutput), ("img/photo.JPG", .media), ("x/data.tar.gz", .archive),
            ("a/Foo.app/Contents/x", .bundle)
        ]
        for (path, expected) in cases { XCTAssertEqual(try AnalyzerExclusions.classify(relativePath: path), expected, path) }
        XCTAssertNil(try AnalyzerExclusions.classify(relativePath: "src/main.swift"))
    }

    func testExactUserExclusionsAndInvalidPaths() throws {
        XCTAssertEqual(try AnalyzerExclusions.classify(relativePath: "private/x", userExcludedPaths: ["private"]), .userRule)
        XCTAssertNil(try AnalyzerExclusions.classify(relativePath: "private-other/x", userExcludedPaths: ["private"]))
        for path in ["../x", "/tmp/x", "a//b", "a/./b", ""] {
            XCTAssertThrowsError(try AnalyzerExclusions.classify(relativePath: path), path)
        }
        XCTAssertThrowsError(try AnalyzerExclusions.classify(relativePath: "a", userExcludedPaths: ["../x"]))
        XCTAssertThrowsError(try AnalyzerExclusions.classify(relativePath: "a", userExcludedPaths: ["a", "../x"]))
    }
}
