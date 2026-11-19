import Foundation
import Darwin
import XCTest
@testable import OchesCore

final class AgentApplyJournalTests: XCTestCase {
    func testOutcomeCommitFailureLeavesIntentRecoverableAsUnknown() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(path: directory.appendingPathComponent("db").path, workspaceID: "ws", initialStoreGeneration: "gen")
        let journal = AgentApplyJournal(store: store)
        let digest = Data(repeating: 9, count: 32)
        let intent = try journal.recordIntent(documentDigest: digest, actorID: "actor", requestID: "intent", now: 100)
        XCTAssertEqual(AgentConfigFileWriter.write(rootPath: directory.path, relativePath: "config", expected: nil,
            proposed: Data("fixture".utf8)), .applied)
        try store.executeRawForTesting("CREATE TRIGGER fail_apply_outcome BEFORE INSERT ON event_log BEGIN SELECT RAISE(ABORT, 'fixture'); END")
        XCTAssertThrowsError(try journal.recordOutcome(documentDigest: digest, outcome: .applied, intent: intent.revision,
            actorID: "actor", requestID: "outcome", now: 101))
        XCTAssertEqual(try store.readSnapshot(workspaceID: "ws", objectID: intent.revision.objectID).revision, intent.revision)
        try store.executeRawForTesting("DROP TRIGGER fail_apply_outcome")
        XCTAssertEqual(try journal.recover(documentDigest: digest, actorID: "actor", requestID: "recover", now: 102), .unknown)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("config")), Data("fixture".utf8))
    }

    func testProcessExitAfterIntentOrWriteRecoversUnknownWithoutRewriting() throws {
        let digest = Data(repeating: 7, count: 32)
        if let root = ProcessInfo.processInfo.environment["OCHES_APPLY_EXIT_ROOT"],
           let stage = ProcessInfo.processInfo.environment["OCHES_APPLY_EXIT_STAGE"] {
            let store = try SQLiteStore(path: root + "/db", workspaceID: "ws", initialStoreGeneration: "gen")
            _ = try AgentApplyJournal(store: store).recordIntent(documentDigest: digest,
                actorID: "actor", requestID: "intent", now: 100)
            if stage == "afterWrite" {
                guard AgentConfigFileWriter.write(rootPath: root, relativePath: "config", expected: nil,
                    proposed: Data("approved fixture".utf8)) == .applied else { _exit(72) }
            }
            _exit(71)
        }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for stage in ["afterIntent", "afterWrite"] {
            let root = directory.appendingPathComponent(stage)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            process.arguments = ["-XCTest", "OchesCoreTests.AgentApplyJournalTests/testProcessExitAfterIntentOrWriteRecoversUnknownWithoutRewriting",
                Bundle(for: AgentApplyJournalTests.self).bundlePath]
            var environment = ProcessInfo.processInfo.environment
            environment["OCHES_APPLY_EXIT_ROOT"] = root.path
            environment["OCHES_APPLY_EXIT_STAGE"] = stage
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 71)
            let journal = AgentApplyJournal(store: try SQLiteStore(path: root.appendingPathComponent("db").path, workspaceID: "ws"))
            XCTAssertEqual(try journal.recover(documentDigest: digest, actorID: "actor", requestID: "recover", now: 101), .unknown)
            let target = root.appendingPathComponent("config")
            if stage == "afterWrite" {
                XCTAssertEqual(try Data(contentsOf: target), Data("approved fixture".utf8))
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            }
            XCTAssertThrowsError(try journal.recordIntent(documentDigest: digest, actorID: "actor", requestID: "retry", now: 102))
        }
    }

    func testRestartQuarantinesIncompleteIntentWithoutReapplying() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("db").path
        let digest = Data(repeating: 1, count: 32)
        let journal = AgentApplyJournal(store: try SQLiteStore(path: path, workspaceID: "ws", initialStoreGeneration: "gen"))
        let intent = try journal.recordIntent(documentDigest: digest, actorID: "actor", requestID: "intent", now: 100)
        XCTAssertTrue(try journal.recordIntent(documentDigest: digest, actorID: "actor", requestID: "intent", now: 101).idempotentReplay)
        let reopened = AgentApplyJournal(store: try SQLiteStore(path: path, workspaceID: "ws", initialStoreGeneration: "ignored"))
        XCTAssertEqual(try reopened.recover(documentDigest: digest, actorID: "actor", requestID: "recover", now: 102), .unknown)
        XCTAssertEqual(try reopened.recover(documentDigest: digest, actorID: "actor", requestID: "recover-again", now: 103), .unknown)
        XCTAssertThrowsError(try reopened.recordOutcome(documentDigest: digest, outcome: .applied, intent: intent.revision,
            actorID: "actor", requestID: "late-success", now: 104))
        XCTAssertThrowsError(try reopened.recordIntent(documentDigest: digest, actorID: "actor", requestID: "retry", now: 105))
    }
}
