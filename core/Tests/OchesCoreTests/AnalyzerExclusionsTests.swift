import XCTest
@testable import OchesCore

final class AnalyzerExclusionsTests: XCTestCase {
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
