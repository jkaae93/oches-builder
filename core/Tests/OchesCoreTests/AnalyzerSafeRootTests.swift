import Foundation
import XCTest
@testable import OchesCore

final class AnalyzerSafeRootTests: XCTestCase {
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

    func testPathReplacementBeforeOpenNeverReadsOutside() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let target = root.appendingPathComponent("target")
        let outside = base.appendingPathComponent("outside")
        try Data("inside".utf8).write(to: target)
        try Data("outside-marker".utf8).write(to: outside)
        let scanner = try AnalyzerSafeRoot(rootPath: root.path)
        var replacementError: Error?
        XCTAssertThrowsError(try scanner.read(relativePath: "target", maximumBytes: 100, beforeFinalOpen: {
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
        let target = base.appendingPathComponent("target")
        try Data("inside".utf8).write(to: target)
        let scanner = try AnalyzerSafeRoot(rootPath: base.path)
        var mutationError: Error?
        XCTAssertThrowsError(try scanner.read(relativePath: "target", maximumBytes: 100, beforeFinalStat: {
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
