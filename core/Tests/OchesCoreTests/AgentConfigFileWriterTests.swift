import Foundation
import XCTest
@testable import OchesCore

final class AgentConfigFileWriterTests: XCTestCase {
    func testBoundRootRejectsReplacementAndNeverWritesReplacementDirectory() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("root")
        let moved = directory.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let scanner = try AnalyzerSafeRoot(rootPath: root.path)
        let identity = try scanner.rootIdentity()
        let bound = try AgentConfigWriteRoot(rootPath: root.path, expectedIdentity: identity)
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertThrowsError(try AgentConfigWriteRoot(rootPath: root.path, expectedIdentity: identity))
        XCTAssertEqual(bound.write(relativePath: "config", expected: nil, proposed: Data("fixture".utf8)), .applied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("config").path))
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("config")), Data("fixture".utf8))
    }

    func testReplacementAndInPlaceMutationBeforeWriteAreRejected() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("config")
        let original = Data("original".utf8)
        let changed = Data("changed!".utf8)
        try original.write(to: target)
        var injected = false
        let result = AgentConfigFileWriter.write(rootPath: root.path, relativePath: "config", expected: original,
            proposed: Data("proposed".utf8), onStage: { stage in
                if stage == .beforeMutation {
                    injected = true
                    try! changed.write(to: target)
                }
                return true
            })
        XCTAssertTrue(injected)
        XCTAssertEqual(result, .conflict)
        XCTAssertEqual(try Data(contentsOf: target), changed)
        try original.write(to: target)
        let replaced = AgentConfigFileWriter.write(rootPath: root.path, relativePath: "config", expected: original,
            proposed: Data("proposed".utf8), onStage: { stage in
                if stage == .beforeMutation { try! changed.write(to: target, options: .atomic) }
                return true
            })
        XCTAssertEqual(replaced, .conflict)
        XCTAssertEqual(try Data(contentsOf: target), changed)
    }

    func testInjectedPostMutationFailuresNeverReportApplied() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let proposed = Data("proposed".utf8)
        let stages: [(AgentConfigFileWriter.Stage, AgentConfigWriteOutcome)] = [
            (.beforeMutation, .partial), (.afterWrite, .partial), (.beforeSync, .unknown), (.beforeVerification, .unknown)
        ]
        for (index, pair) in stages.enumerated() {
            XCTAssertEqual(AgentConfigFileWriter.write(rootPath: root.path, relativePath: "config-\(index)", expected: nil,
                proposed: proposed, onStage: { $0 != pair.0 }), pair.1)
        }
    }

    func testCreateUpdateConflictAndSymlinkDenial() throws {
        let root = try makeTempDirectory()
        let outside = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let original = Data("original configuration".utf8)
        let proposed = Data("new".utf8)
        XCTAssertEqual(AgentConfigFileWriter.write(rootPath: root.path, relativePath: "config", expected: nil, proposed: original), .applied)
        XCTAssertEqual(AgentConfigFileWriter.write(rootPath: root.path, relativePath: "config", expected: nil, proposed: proposed), .conflict)
        XCTAssertEqual(AgentConfigFileWriter.write(rootPath: root.path, relativePath: "config", expected: proposed, proposed: proposed), .conflict)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("config")), original)
        XCTAssertEqual(AgentConfigFileWriter.write(rootPath: root.path, relativePath: "config", expected: original, proposed: proposed), .applied)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("config")), proposed)
        try original.write(to: outside.appendingPathComponent("secret"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertEqual(AgentConfigFileWriter.write(rootPath: root.path, relativePath: "link/secret", expected: original, proposed: proposed), .unavailable)
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("secret")), original)
        XCTAssertEqual(AgentConfigFileWriter.write(rootPath: root.path, relativePath: "../secret", expected: nil, proposed: proposed), .unavailable)
    }
}
