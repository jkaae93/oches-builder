import Foundation
import XCTest
@testable import OchesCore

final class AnalyzerScopeCandidateTests: XCTestCase {
    func testBindingIncludesRootWorkspacePolicyLimitsAndExactPaths() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = parent.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let scanner = try AnalyzerSafeRoot(rootPath: root.path)
        let limits = AnalyzerScopeCandidate.Limits(maximumEntries: 10_000, maximumTotalBytes: 104_857_600, maximumFileBytes: 1_048_576, maximumSeconds: 300)
        func scope(_ ws: String = "ws", _ policy: String = "1", _ excluded: [String] = ["b", "a"], _ scanner: AnalyzerSafeRoot, _ limits: AnalyzerScopeCandidate.Limits) throws -> AnalyzerScopeCandidate {
            try AnalyzerScopeCandidate(workspaceID: ws, scanner: scanner, policyVersion: policy, excludedPaths: excluded, limits: limits)
        }
        let initial = try scope("ws", "1", ["b", "a"], scanner, limits)
        XCTAssertEqual(initial.digest, try scope("ws", "1", ["a", "b"], scanner, limits).digest)
        XCTAssertNotEqual(initial.digest, try scope("other", "1", ["a", "b"], scanner, limits).digest)
        XCTAssertNotEqual(initial.digest, try scope("ws", "2", ["a", "b"], scanner, limits).digest)
        XCTAssertNotEqual(initial.digest, try scope("ws", "1", ["a", "c"], scanner, limits).digest)
        let smaller = AnalyzerScopeCandidate.Limits(maximumEntries: 9_999, maximumTotalBytes: 104_857_600, maximumFileBytes: 1_048_576, maximumSeconds: 300)
        XCTAssertNotEqual(initial.digest, try scope("ws", "1", ["a", "b"], scanner, smaller).digest)
        let composed = "\u{00e9}"
        let decomposed = "e\u{0301}"
        XCTAssertNotEqual(try scope("ws", "1", [composed], scanner, limits).digest, try scope("ws", "1", [decomposed], scanner, limits).digest)
        XCTAssertThrowsError(try scope("ws", "1", ["a", "a"], scanner, limits))
        XCTAssertThrowsError(try scope("ws", "1", ["../secret"], scanner, limits))
        let invalid = AnalyzerScopeCandidate.Limits(maximumEntries: 10_001, maximumTotalBytes: 104_857_600, maximumFileBytes: 1_048_576, maximumSeconds: 300)
        XCTAssertThrowsError(try scope("ws", "1", [], scanner, invalid))
        try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let replacement = try AnalyzerSafeRoot(rootPath: root.path)
        XCTAssertNotEqual(initial.digest, try scope("ws", "1", ["a", "b"], replacement, limits).digest)
        XCTAssertEqual(initial.root, try scanner.rootIdentity())
    }
}
