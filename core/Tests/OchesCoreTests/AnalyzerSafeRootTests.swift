import Foundation
import XCTest
@testable import OchesCore

final class AnalyzerSafeRootTests: XCTestCase {
    func testCancellationDuringRulePreparationReturnsPartialWithoutReading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not read".utf8).write(to: root.appendingPathComponent("visible"))
        let scanner = try AnalyzerSafeRoot(rootPath: root.path)
        let exclusions = (0..<1000).map { "excluded\($0)" }
        var checks = 0
        let result = try scanner.collectEvidence(userExcludedPaths: exclusions, isCancelled: { checks += 1; return checks > 20 })
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.partialReasons.contains("cancelled"))
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertTrue(result.preview.entries.isEmpty)
    }

    func testExactExceptionReadsOnlyRequestedFileAndUserExclusionWins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("permitted".utf8).write(to: root.appendingPathComponent(".git/sub/allowed"))
        try Data("private".utf8).write(to: root.appendingPathComponent(".git/sub/sibling"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(".git/sub/link").path, withDestinationPath: "/outside")
        let scanner = try AnalyzerSafeRoot(rootPath: root.path)
        let exceptions = [".git/sub/allowed", ".git/sub/link"]
        let result = try scanner.collectEvidence(exceptionPaths: exceptions)
        XCTAssertEqual(result.files.map(\.relativePath), [".git/sub/allowed"])
        XCTAssertFalse(result.preview.entries.contains { $0.relativePath == ".git/sub/sibling" })
        XCTAssertTrue(result.preview.entries.contains { $0.relativePath == ".git/sub/link" && $0.kind == .symbolicLink })
        let excluded = try scanner.collectEvidence(userExcludedPaths: [".git/sub"], exceptionPaths: exceptions)
        XCTAssertTrue(excluded.files.isEmpty)
        XCTAssertFalse(excluded.preview.entries.contains { $0.relativePath == ".git/sub/allowed" })
        XCTAssertThrowsError(try scanner.readEvidence(relativePath: ".git/sub/sibling", maximumBytes: 100, exceptionPaths: exceptions))
        XCTAssertThrowsError(try scanner.readEvidence(relativePath: ".git/sub/link", maximumBytes: 100, exceptionPaths: exceptions))
        let directoryOnly = try scanner.collectEvidence(exceptionPaths: [".git"])
        XCTAssertTrue(directoryOnly.files.isEmpty)
        XCTAssertFalse(directoryOnly.preview.entries.contains { $0.relativePath == ".git/sub/allowed" })
    }

    func testRegularFileAndEscapesAreRejected() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("safe".utf8).write(to: root.appendingPathComponent("safe.txt"))
        try Data("outside".utf8).write(to: base.appendingPathComponent("outside.txt"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: base.appendingPathComponent("outside.txt").path)
        let scanner = try AnalyzerSafeRoot(rootPath: root.path)
        XCTAssertEqual(try scanner.read(relativePath: "safe.txt", maximumBytes: 10), Data("safe".utf8))
        for path in ["../outside.txt", "/etc/passwd", "link", "./safe.txt", "safe.txt/../link"] {
            XCTAssertThrowsError(try scanner.read(relativePath: path, maximumBytes: 100), path)
        }
        XCTAssertThrowsError(try scanner.read(relativePath: "safe.txt", maximumBytes: 3)) {
            XCTAssertEqual($0 as? AnalyzerSafeRoot.AccessError, .limitExceeded)
        }
    }

    func testExclusionsApplyBeforeOpeningFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("synthetic".utf8).write(to: root.appendingPathComponent(".env"))
        try Data("synthetic".utf8).write(to: root.appendingPathComponent("private.txt"))
        let scanner = try AnalyzerSafeRoot(rootPath: root.path)
        var opened = false
        XCTAssertThrowsError(try scanner.read(relativePath: ".env", maximumBytes: 100, beforeFinalOpen: { opened = true })) {
            XCTAssertEqual($0 as? AnalyzerSafeRoot.AccessError, .excluded)
        }
        XCTAssertFalse(opened)
        XCTAssertThrowsError(try scanner.read(relativePath: "private.txt", maximumBytes: 100, userExcludedPaths: ["private.txt"])) {
            XCTAssertEqual($0 as? AnalyzerSafeRoot.AccessError, .excluded)
        }
    }

    func testPathReplacementBeforeOpenNeverReadsOutside() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let target = root.appendingPathComponent("sample.txt")
        let outside = base.appendingPathComponent("outside")
        try Data("inside".utf8).write(to: target)
        try Data("outside-marker".utf8).write(to: outside)
        let scanner = try AnalyzerSafeRoot(rootPath: root.path)
        var replacementError: Error?
        XCTAssertThrowsError(try scanner.read(relativePath: "sample.txt", maximumBytes: 100, beforeFinalOpen: {
            do {
                try FileManager.default.removeItem(at: target)
                try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: outside.path)
            } catch { replacementError = error }
        }))
        XCTAssertNil(replacementError)
    }

    func testMutationDuringReadDoesNotReturnBytes() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("sample.txt")
        try Data("inside".utf8).write(to: target)
        let scanner = try AnalyzerSafeRoot(rootPath: base.path)
        var mutationError: Error?
        XCTAssertThrowsError(try scanner.read(relativePath: "sample.txt", maximumBytes: 100, beforeFinalStat: {
            do { try Data("modified-content".utf8).write(to: target) } catch { mutationError = error }
        })) {
            XCTAssertEqual($0 as? AnalyzerSafeRoot.AccessError, .changedDuringRead)
        }
        XCTAssertNil(mutationError)
    }

    func testDirectoryLinkAndNonRegularFilesAreRejected() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("root")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("outside".utf8).write(to: outside.appendingPathComponent("x"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("dirlink").path, withDestinationPath: outside.path)
        let scanner = try AnalyzerSafeRoot(rootPath: root.path)
        XCTAssertThrowsError(try scanner.read(relativePath: "dirlink/x", maximumBytes: 100))
        XCTAssertThrowsError(try scanner.read(relativePath: "dirlink", maximumBytes: 100))
    }
}

extension AnalyzerSafeRootTests {
    func testPreviewSkipsExcludedDirectoriesAndLinksAndIsRepeatable() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("root")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("a".utf8).write(to: root.appendingPathComponent("src/main.swift"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".git/config"))
        try Data("outside".utf8).write(to: outside.appendingPathComponent("marker"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: outside.path)
        let scanner = try AnalyzerSafeRoot(rootPath: root.path)
        for _ in 0..<2 {
            let preview = try scanner.preview()
            let paths = Set(preview.entries.map(\.relativePath))
            XCTAssertTrue(paths.contains("src/main.swift"))
            XCTAssertTrue(paths.contains(".git"))
            XCTAssertFalse(paths.contains(".git/config"))
            XCTAssertFalse(paths.contains("link/marker"))
            XCTAssertTrue(preview.entries.contains { $0.relativePath == "link" && $0.kind == .symbolicLink && $0.symbolicLinkTarget == outside.path })
            XCTAssertTrue(preview.partialReasons.isEmpty)
        }
        let limited = try scanner.preview(maximumEntries: 1)
        XCTAssertEqual(limited.entries.count, 1)
        XCTAssertTrue(limited.partialReasons.contains("entry_limit"))
    }
}

extension AnalyzerSafeRootTests {
    func testEvidenceContainsHashNotContentsAndEnforcesLimits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("abc".utf8).write(to: root.appendingPathComponent("sample.txt"))
        try Data(repeating: 1, count: 20).write(to: root.appendingPathComponent("large.txt"))
        try Data("synthetic".utf8).write(to: root.appendingPathComponent(".env"))
        let scanner = try AnalyzerSafeRoot(rootPath: root.path)
        let result = try scanner.collectEvidence(maximumTotalBytes: 100, maximumFileBytes: 10)
        let evidence = try XCTUnwrap(result.files.first { $0.relativePath == "sample.txt" })
        XCTAssertEqual(evidence.size, 3)
        XCTAssertEqual(evidence.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(result.unreadReasons[Data("large.txt".utf8)], "file_limit")
        XCTAssertTrue(result.partialReasons.contains("file_limit"))
        XCTAssertFalse(result.files.contains { $0.relativePath == ".env" })
        let cancelled = try scanner.collectEvidence(isCancelled: { true })
        XCTAssertTrue(cancelled.cancelled)
        XCTAssertTrue(cancelled.files.isEmpty)
        XCTAssertTrue(cancelled.preview.entries.isEmpty)
    }

    func testReplacedRegularFileAndAggregateLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("one.txt")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: root.appendingPathComponent("two.txt"))
        let scanner = try AnalyzerSafeRoot(rootPath: root.path)
        let preview = try scanner.preview()
        let entry = try XCTUnwrap(preview.entries.first { $0.relativePath == "one.txt" })
        try FileManager.default.moveItem(at: first, to: root.appendingPathComponent("original.txt"))
        try Data("new".utf8).write(to: first)
        XCTAssertThrowsError(try scanner.readEvidence(relativePath: "one.txt", maximumBytes: 100, expectedDevice: entry.device, expectedInode: entry.inode)) {
            XCTAssertEqual($0 as? AnalyzerSafeRoot.AccessError, .changedDuringRead)
        }
        let limited = try scanner.collectEvidence(maximumTotalBytes: 4, maximumFileBytes: 4)
        XCTAssertEqual(limited.files.count, 1)
        XCTAssertTrue(limited.partialReasons.contains("total_limit"))
    }

    func testFailedReadAccountsBytesAndCancellationStopsNextChunk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.txt")
        try Data(repeating: 65, count: 32_768).write(to: file)
        let scanner = try AnalyzerSafeRoot(rootPath: root.path)
        var bytesRead = 0
        var cancel = false
        XCTAssertThrowsError(try scanner.readEvidence(relativePath: "sample.txt", maximumBytes: 32_768, onBytesRead: { bytesRead += $0; cancel = true }, shouldStop: { cancel }))
        XCTAssertEqual(bytesRead, 16_384)
        bytesRead = 0
        XCTAssertThrowsError(try scanner.readEvidence(relativePath: "sample.txt", maximumBytes: 32_768, beforeFinalStat: { try? Data("changed".utf8).write(to: file) }, onBytesRead: { bytesRead += $0 }))
        XCTAssertEqual(bytesRead, 32_768)
    }

    func testOutsideHardLinkIsNotRead() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.linkItem(at: outside, to: root.appendingPathComponent("alias.txt"))
        let scanner = try AnalyzerSafeRoot(rootPath: root.path)
        XCTAssertThrowsError(try scanner.read(relativePath: "alias.txt", maximumBytes: 100)) {
            XCTAssertEqual($0 as? AnalyzerSafeRoot.AccessError, .multipleHardLinks)
        }
    }
}
