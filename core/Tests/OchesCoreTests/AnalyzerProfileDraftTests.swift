import Foundation
import XCTest
@testable import OchesCore

final class AnalyzerProfileDraftTests: XCTestCase {
    func testEvidenceAndPartialStateContainNoProjectContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("synthetic untrusted instructions".utf8).write(to: root.appendingPathComponent("main.swift"))
        try Data(repeating: 65, count: 100).write(to: root.appendingPathComponent("large.txt"))
        let scanner = try AnalyzerSafeRoot(rootPath: root.path)
        let collection = try scanner.collectEvidence(maximumTotalBytes: 1000, maximumFileBytes: 50)
        let draft = try AnalyzerProfileDraft.build(profileID: "p", workspaceRef: "w", analyzerVersion: "1", analyzedAt: Date(timeIntervalSince1970: 0), roots: ["root"], exclusions: ["defaults"], userConstraints: [], collection: collection)
        XCTAssertFalse(String(reflecting: draft).contains("synthetic untrusted instructions"))
        XCTAssertEqual(draft.state, .partial)
        XCTAssertTrue(draft.limitsReached.contains("file_limit"))
        XCTAssertEqual(draft.evidence.count, 1)
        XCTAssertEqual(draft.observations.first?.value, "swift")
        XCTAssertEqual(draft.observations.first?.evidencePath, "main.swift")
        XCTAssertTrue(draft.inferences.isEmpty)
        XCTAssertTrue(draft.uncertainties.contains("project_language_unknown"))
        XCTAssertTrue(draft.skipped.contains { $0.relativePath == "large.txt" && $0.reason == "file_limit" })
    }

    func testCancelledAndEmptyEvidenceAreNotInferred() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scanner = try AnalyzerSafeRoot(rootPath: root.path)
        let collection = try scanner.collectEvidence(isCancelled: { true })
        let draft = try AnalyzerProfileDraft.build(profileID: "p", workspaceRef: "w", analyzerVersion: "1", analyzedAt: Date(), roots: ["root"], exclusions: [], userConstraints: [], collection: collection)
        XCTAssertEqual(draft.state, .cancelled)
        XCTAssertTrue(draft.inferences.isEmpty)
        XCTAssertTrue(draft.uncertainties.contains("analysis_incomplete"))
    }
}
