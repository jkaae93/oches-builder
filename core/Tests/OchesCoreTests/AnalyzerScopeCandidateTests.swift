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
        let exception = try AnalyzerScopeCandidate(workspaceID: "ws", scanner: scanner, policyVersion: "1", excludedPaths: ["a", "b"], exceptionPaths: [".env"], limits: limits)
        XCTAssertNotEqual(initial.digest, exception.digest)
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
        XCTAssertThrowsError(try initial.collectCandidateEvidence(using: replacement)) {
            XCTAssertEqual($0 as? AnalyzerSafeRoot.AccessError, .changedDuringRead)
        }
    }

    func testCandidateAppliesItsExactRulesAndLimitsToCollection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("allow".utf8).write(to: root.appendingPathComponent(".env"))
        try Data("other".utf8).write(to: root.appendingPathComponent("excluded"))
        let scanner = try AnalyzerSafeRoot(rootPath: root.path)
        let limits = AnalyzerScopeCandidate.Limits(maximumEntries: 100, maximumTotalBytes: 100, maximumFileBytes: 4, maximumSeconds: 10)
        let scope = try AnalyzerScopeCandidate(workspaceID: "ws", scanner: scanner, policyVersion: "1", excludedPaths: ["excluded"], exceptionPaths: [".env"], limits: limits)
        let result = try scope.collectCandidateEvidence(using: scanner)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertTrue(result.partialReasons.contains("file_limit"))
        XCTAssertEqual(result.unreadReasons[Data(".env".utf8)], "file_limit")
        XCTAssertTrue(result.preview.entries.contains { $0.relativePath == "excluded" && $0.exclusion == .userRule })
        let draft = try scope.buildCandidateProfile(using: scanner, profileID: "p", analyzerVersion: "1", analyzedAt: Date(), roots: ["root"], userConstraints: [])
        XCTAssertEqual(draft.scopeDigest, scope.digest)
        XCTAssertEqual(draft.exceptionPaths, [".env"])
        XCTAssertEqual(draft.exclusions, ["excluded"])
        let storeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = try SQLiteStore(path: storeDir.appendingPathComponent("db").path, workspaceID: "ws")
        let repo = AnalyzerProfileRepository(store: store)
        let saved = try repo.save(draft, actorID: "actor", requestID: "r", expectedRevision: nil, nowEpochSeconds: 1)
        XCTAssertEqual(try repo.load(profileID: "p", revision: saved.revision).scopeDigest, scope.digest)
        XCTAssertEqual(try repo.load(profileID: "p", revision: saved.revision).exceptionPaths, [".env"])
    }
}
