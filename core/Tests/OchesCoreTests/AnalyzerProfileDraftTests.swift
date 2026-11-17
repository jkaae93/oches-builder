import Foundation
import XCTest
@testable import OchesCore

final class AnalyzerProfileDraftTests: XCTestCase {
    func testDistinctUnicodePathsKeepSeparateUnreadReasons() throws {
        let first = "\u{00e9}"
        let second = "e\u{0301}"
        func entry(_ path: String) -> AnalyzerSafeRoot.PreviewEntry {
            AnalyzerSafeRoot.PreviewEntry(relativePath: path, kind: .regular, size: 1, device: 1, inode: 1, modifiedSeconds: 1, modifiedNanoseconds: 0, exclusion: nil, symbolicLinkTarget: nil)
        }
        let preview = AnalyzerSafeRoot.Preview(entries: [entry(first), entry(second)], partialReasons: [])
        let collection = AnalyzerSafeRoot.EvidenceCollection(preview: preview, files: [], unreadReasons: [Data(first.utf8): "file_limit", Data(second.utf8): "read_unavailable_or_changed"], partialReasons: ["read_incomplete"], cancelled: false)
        let draft = try AnalyzerProfileDraft.build(profileID: "p", workspaceRef: "w", analyzerVersion: "1", analyzedAt: Date(), roots: ["root"], exclusions: [], userConstraints: [], collection: collection)
        XCTAssertEqual(draft.skipped.first { $0.relativePath.utf8.elementsEqual(first.utf8) }?.reason, "file_limit")
        XCTAssertEqual(draft.skipped.first { $0.relativePath.utf8.elementsEqual(second.utf8) }?.reason, "read_unavailable_or_changed")
    }

    func testSkippedMetadataAndLinkTargetSurviveInProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 65, count: 20).write(to: root.appendingPathComponent("large.txt"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("outside").path, withDestinationPath: "/outside/secret")
        let scanner = try AnalyzerSafeRoot(rootPath: root.path)
        let collection = try scanner.collectEvidence(maximumFileBytes: 10)
        let draft = try AnalyzerProfileDraft.build(profileID: "p", workspaceRef: "w", analyzerVersion: "1", analyzedAt: Date(), roots: ["root"], exclusions: [], userConstraints: [], collection: collection)
        let skippedFile = try XCTUnwrap(draft.skipped.first { $0.relativePath == "large.txt" })
        let previewFile = try XCTUnwrap(collection.preview.entries.first { $0.relativePath == "large.txt" })
        XCTAssertEqual(skippedFile.reason, "file_limit")
        XCTAssertEqual(skippedFile.size, 20)
        XCTAssertEqual(skippedFile.modifiedSeconds, previewFile.modifiedSeconds)
        XCTAssertEqual(skippedFile.modifiedNanoseconds, previewFile.modifiedNanoseconds)
        let link = try XCTUnwrap(draft.skipped.first { $0.relativePath == "outside" })
        XCTAssertEqual(link.reason, "symbolic_link_not_followed")
        XCTAssertEqual(link.symbolicLinkTarget, "/outside/secret")
        XCTAssertFalse(draft.evidence.contains { $0.relativePath == "outside" })

        let interrupted = AnalyzerSafeRoot.EvidenceCollection(preview: collection.preview, files: [], unreadReasons: [:], partialReasons: ["cancelled"], cancelled: true)
        let partial = try AnalyzerProfileDraft.build(profileID: "p", workspaceRef: "w", analyzerVersion: "1", analyzedAt: Date(), roots: ["root"], exclusions: [], userConstraints: [], collection: interrupted)
        XCTAssertEqual(partial.skipped.first { $0.relativePath == "large.txt" }?.reason, "not_analyzed")
        XCTAssertEqual(partial.state, .cancelled)
    }

    func testEvidenceComparisonDetectsChangesButNeverClaimsFreshness() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.swift")
        try Data("first".utf8).write(to: file)
        let scanner = try AnalyzerSafeRoot(rootPath: root.path)
        let initial = try scanner.collectEvidence()
        let draft = try AnalyzerProfileDraft.build(profileID: "p", workspaceRef: "w", analyzerVersion: "1", analyzedAt: Date(), roots: ["root"], exclusions: [], userConstraints: [], collection: initial)
        XCTAssertEqual(draft.compareReadEvidence(with: try scanner.collectEvidence()), .indeterminate)
        try Data("other".utf8).write(to: file)
        XCTAssertEqual(draft.compareReadEvidence(with: try scanner.collectEvidence()), .changed(paths: ["main.swift"]))
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(draft.compareReadEvidence(with: try scanner.collectEvidence()), .indeterminate)
        XCTAssertEqual(draft.compareReadEvidence(with: try scanner.collectEvidence(isCancelled: { true })), .indeterminate)
    }

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
