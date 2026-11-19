import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import OchesCore

final class EvaluationObservabilityTests: XCTestCase {
    private func makeCleanObservations(
        boundaries: [ObservationBoundary] = [.processLifecycle, .fileReads, .fileWrites, .network, .approvals, .artifacts]
    ) -> [BoundaryObservationReport] {
        boundaries.map { boundary in
            BoundaryObservationReport(
                boundary: boundary,
                observerID: "independent-observer-1",
                productSourceID: "oches-runtime-core",
                observerIsolated: true,
                startMarkerRecorded: true,
                endMarkerRecorded: true,
                observedSequences: [1, 2, 3],
                droppedEventsCount: 0,
                collectorHealthy: true,
                samplingActive: false,
                unobservedChildProcesses: 0,
                violations: []
            )
        }
    }

    private func makeVerifiedSnapshot(workspaceID: String = "ws") -> (CapabilitySnapshot, CapabilityScope) {
        let scope = CapabilityScope(
            installationID: "installation",
            executableIdentity: "sha256:mock",
            cliVersion: "1.0.0",
            adapterVersion: "1.0.0",
            osVersionArch: "macOS-26.4-arm64",
            accountRef: "account",
            accountType: .apiKey,
            workspaceID: workspaceID,
            workspaceLocationAuthority: "local",
            workspaceTrust: true,
            clientID: "desktop-1",
            clientKind: "desktop",
            negotiatedProtocolMajorMinor: "1.0",
            policyVersion: 1
        )
        let entries = CapabilityID.allCases.map {
            CapabilityEntry(capabilityID: $0, status: .supported, basis: .verifiedInOches, evidenceRef: "eval-test", observedAt: 100)
        }
        return (CapabilitySnapshot(snapshotID: "snap-1", scope: scope, entries: entries, observedAt: 100), scope)
    }

    func testImmutableSnapshotCollectionRejectsSymlinkOutsideRootAndReadMutation() throws {
        let dir = try makeTempDirectory("artifact-snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let wsRoot = dir.appendingPathComponent("ws-root", isDirectory: true)
        let outsideFile = dir.appendingPathComponent("secret-outside.txt")
        let blobRoot = dir.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: wsRoot, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outsideFile)

        let cleanDir = wsRoot.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: cleanDir, withIntermediateDirectories: true)
        let cleanFile = cleanDir.appendingPathComponent("out.txt")
        try Data("artifact-v1".utf8).write(to: cleanFile)
        let linkFile = wsRoot.appendingPathComponent("escape-link.txt")
        try FileManager.default.createSymbolicLink(at: linkFile, withDestinationURL: outsideFile)

        let store = try SQLiteStore(path: dir.appendingPathComponent("db").path, workspaceID: "ws", initialStoreGeneration: "gen")
        let manifestStore = try ArtifactManifestStore(store: store, blobRootURL: blobRoot)
        let rev = RevisionRef(objectID: "arc07/run/r1/task/t1", storeGeneration: "gen", revision: "1")

        // 1. Clean immutable collection
        let cleanManifest = try manifestStore.collectImmutableSnapshot(
            manifestID: "man-clean", runID: "r1", taskID: "t1", attemptID: "att-1",
            taskRevision: rev, workspaceRoot: wsRoot, relativePaths: ["src/out.txt"], collectedAt: 100
        )
        XCTAssertTrue(cleanManifest.complete)
        XCTAssertEqual(cleanManifest.entries.first?.accessStatus, .collected)
        if case .valid(let verified) = try manifestStore.verifyManifestIntegrity(manifestID: "man-clean") {
            XCTAssertEqual(verified.manifestDigest, cleanManifest.manifestDigest)
        } else {
            XCTFail("Expected clean manifest to verify")
        }
        XCTAssertEqual(try manifestStore.compareManifestAgainstWorkspace(manifestID: "man-clean", workspaceRoot: wsRoot), .unchanged)

        // Read-only blob permissions
        let blobDigest = try XCTUnwrap(cleanManifest.entries.first?.blobDigest)
        let blobPath = blobRoot.appendingPathComponent(blobDigest).path
        let attrs = try FileManager.default.attributesOfItem(atPath: blobPath)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o444)

        // 2. Post-evaluation workspace mutation detects drift while historical blob remains intact (X20)
        try Data("artifact-v2-mutated".utf8).write(to: cleanFile)
        XCTAssertEqual(
            try manifestStore.compareManifestAgainstWorkspace(manifestID: "man-clean", workspaceRoot: wsRoot),
            .mutated(paths: ["src/out.txt"])
        )
        if case .valid = try manifestStore.verifyManifestIntegrity(manifestID: "man-clean") {} else {
            XCTFail("Immutable historical snapshot should stay intact even after workspace file mutates")
        }

        // 3. Symlink and .. escape are rejected and mark manifest incomplete
        let badManifest = try manifestStore.collectImmutableSnapshot(
            manifestID: "man-bad-paths", runID: "r1", taskID: "t1", attemptID: "att-1",
            taskRevision: rev, workspaceRoot: wsRoot,
            relativePaths: ["src/out.txt", "escape-link.txt", "../secret-outside.txt"],
            collectedAt: 101
        )
        XCTAssertFalse(badManifest.complete)
        let byPath = Dictionary(uniqueKeysWithValues: badManifest.entries.map { ($0.relativePath, $0.accessStatus) })
        XCTAssertEqual(byPath["escape-link.txt"], .symlinkRejected)
        XCTAssertEqual(byPath["../secret-outside.txt"], .outsideRoot)
        if case .invalid = try manifestStore.verifyManifestIntegrity(manifestID: "man-bad-paths") {} else {
            XCTFail("Expected incomplete manifest to fail integrity verification")
        }

        // 4. Mid-read mutation yields changedDuringRead and incomplete manifest
        let raceManifest = try manifestStore.collectImmutableSnapshot(
            manifestID: "man-race", runID: "r1", taskID: "t1", attemptID: "att-1",
            taskRevision: rev, workspaceRoot: wsRoot, relativePaths: ["src/out.txt"],
            collectedAt: 102, injectChangeDuringReadForPath: "src/out.txt"
        )
        XCTAssertFalse(raceManifest.complete)
        XCTAssertEqual(raceManifest.entries.first?.accessStatus, .changedDuringRead)

        // 5. Tampering with stored blob fails integrity verification
        try FileManager.default.removeItem(atPath: blobPath)
        try Data("corrupted-blob-data".utf8).write(to: URL(fileURLWithPath: blobPath))
        if case .invalid(let reason) = try manifestStore.verifyManifestIntegrity(manifestID: "man-clean") {
            XCTAssertTrue(reason.contains("mismatch"))
        } else {
            XCTFail("Expected tampered blob to fail integrity check")
        }
    }

    func testObservationCompletenessPrecedenceV19() throws {
        let required: [ObservationBoundary] = [.processLifecycle, .fileReads, .fileWrites, .network]

        // 1. Clean complete independent observation
        let clean = try IndependentObservationVerifier.verify(
            trialID: "trial-clean",
            requiredBoundaries: required,
            reports: makeCleanObservations(boundaries: required)
        )
        XCTAssertEqual(clean.verdict, .completeNoViolations)
        XCTAssertTrue(clean.unknownBoundaries.isEmpty)

        // 2. Each completeness failure alone yields INDETERMINATE
        let incompleteVariants: [(String, BoundaryObservationReport)] = [
            ("sampling", BoundaryObservationReport(boundary: .network, observerID: "obs", productSourceID: "prod", observerIsolated: true, startMarkerRecorded: true, endMarkerRecorded: true, observedSequences: [1], droppedEventsCount: 0, collectorHealthy: true, samplingActive: true, unobservedChildProcesses: 0)),
            ("dropped", BoundaryObservationReport(boundary: .network, observerID: "obs", productSourceID: "prod", observerIsolated: true, startMarkerRecorded: true, endMarkerRecorded: true, observedSequences: [1], droppedEventsCount: 2, collectorHealthy: true, samplingActive: false, unobservedChildProcesses: 0)),
            ("seq-gap", BoundaryObservationReport(boundary: .network, observerID: "obs", productSourceID: "prod", observerIsolated: true, startMarkerRecorded: true, endMarkerRecorded: true, observedSequences: [1, 3], droppedEventsCount: 0, collectorHealthy: true, samplingActive: false, unobservedChildProcesses: 0)),
            ("missing-end", BoundaryObservationReport(boundary: .network, observerID: "obs", productSourceID: "prod", observerIsolated: true, startMarkerRecorded: true, endMarkerRecorded: false, observedSequences: [1], droppedEventsCount: 0, collectorHealthy: true, samplingActive: false, unobservedChildProcesses: 0)),
            ("unhealthy", BoundaryObservationReport(boundary: .network, observerID: "obs", productSourceID: "prod", observerIsolated: true, startMarkerRecorded: true, endMarkerRecorded: true, observedSequences: [1], droppedEventsCount: 0, collectorHealthy: false, samplingActive: false, unobservedChildProcesses: 0)),
            ("unobserved-child", BoundaryObservationReport(boundary: .network, observerID: "obs", productSourceID: "prod", observerIsolated: true, startMarkerRecorded: true, endMarkerRecorded: true, observedSequences: [1], droppedEventsCount: 0, collectorHealthy: true, samplingActive: false, unobservedChildProcesses: 1)),
            ("same-source", BoundaryObservationReport(boundary: .network, observerID: "prod", productSourceID: "prod", observerIsolated: true, startMarkerRecorded: true, endMarkerRecorded: true, observedSequences: [1], droppedEventsCount: 0, collectorHealthy: true, samplingActive: false, unobservedChildProcesses: 0)),
            ("not-isolated", BoundaryObservationReport(boundary: .network, observerID: "obs", productSourceID: "prod", observerIsolated: false, startMarkerRecorded: true, endMarkerRecorded: true, observedSequences: [1], droppedEventsCount: 0, collectorHealthy: true, samplingActive: false, unobservedChildProcesses: 0)),
        ]
        for (name, badNet) in incompleteVariants {
            let base = makeCleanObservations(boundaries: [.processLifecycle, .fileReads, .fileWrites]) + [badNet]
            let report = try IndependentObservationVerifier.verify(trialID: "trial-\(name)", requiredBoundaries: required, reports: base)
            XCTAssertEqual(report.verdict, .indeterminate, "Expected INDETERMINATE for \(name)")
            XCTAssertEqual(report.unknownBoundaries, [.network], "Expected .network in unknownBoundaries for \(name)")
        }

        // Missing required boundary -> INDETERMINATE
        let missing = try IndependentObservationVerifier.verify(
            trialID: "trial-missing",
            requiredBoundaries: required,
            reports: makeCleanObservations(boundaries: [.processLifecycle, .fileReads, .fileWrites])
        )
        XCTAssertEqual(missing.verdict, .indeterminate)
        XCTAssertEqual(missing.unknownBoundaries, [.network])

        // 3. Violation + missing/incomplete boundary simultaneously -> FAIL with unknownBoundaries preserved (V-19)
        let violationReport = BoundaryObservationReport(
            boundary: .fileReads,
            observerID: "obs",
            productSourceID: "prod",
            observerIsolated: true,
            startMarkerRecorded: true,
            endMarkerRecorded: true,
            observedSequences: [1],
            droppedEventsCount: 0,
            collectorHealthy: true,
            samplingActive: false,
            unobservedChildProcesses: 0,
            violations: [ObservedPolicyViolation(code: "FORBIDDEN_SECRET_READ", boundary: .fileReads, detail: "attempted read outside approved scope")]
        )
        let mixed = try IndependentObservationVerifier.verify(
            trialID: "trial-mixed",
            requiredBoundaries: required,
            reports: [
                makeCleanObservations(boundaries: [.processLifecycle])[0],
                violationReport,
                makeCleanObservations(boundaries: [.fileWrites])[0],
                // .network intentionally missing
            ]
        )
        XCTAssertEqual(mixed.verdict, .fail)
        XCTAssertEqual(mixed.violations.count, 1)
        XCTAssertEqual(mixed.unknownBoundaries, [.network])

        // 4. Sensitive token in violation detail rejected
        let leakedReport = BoundaryObservationReport(
            boundary: .fileReads,
            observerID: "obs",
            productSourceID: "prod",
            observerIsolated: true,
            startMarkerRecorded: true,
            endMarkerRecorded: true,
            observedSequences: [1],
            droppedEventsCount: 0,
            collectorHealthy: true,
            samplingActive: false,
            unobservedChildProcesses: 0,
            violations: [ObservedPolicyViolation(code: "LEAK", boundary: .fileReads, detail: "Bearer sk-ant-secret123")]
        )
        XCTAssertThrowsError(try IndependentObservationVerifier.verify(
            trialID: "trial-secret",
            requiredBoundaries: [.fileReads],
            reports: [leakedReport]
        )) { XCTAssertEqual($0 as? StorageError, .invalidInput) }
    }

    func testEvaluationEngineAtomicSchedulerBindingAndAntiReuseV11() throws {
        let dir = try makeTempDirectory("eval-engine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wsRoot = dir.appendingPathComponent("ws-root", isDirectory: true)
        let blobRoot = dir.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: wsRoot, withIntermediateDirectories: true)
        let outFile = wsRoot.appendingPathComponent("result.txt")
        try Data("clean-output".utf8).write(to: outFile)

        let store = try SQLiteStore(path: dir.appendingPathComponent("db").path, workspaceID: "ws", initialStoreGeneration: "gen")
        let enforcer = try AuthorizationEnforcer(store: store)
        let gate = try RuntimePrepareAndStartGate(store: store)
        let adapter = MockRuntimeAdapter()
        let manager = RuntimeSessionManager(store: store, gate: gate, adapter: adapter)
        let manifestStore = try ArtifactManifestStore(store: store, blobRootURL: blobRoot)
        let verdictStore = try EvaluationVerdictStore(store: store)
        let engine = EvaluationEngine(store: store, manifestStore: manifestStore, verdictStore: verdictStore, gate: gate)
        let repository = SchedulerRunRepository(store: store)
        let pins = Data(repeating: 1, count: 32)
        let (snap, scope) = makeVerifiedSnapshot(workspaceID: "ws")

        let tasks = [
            SchedulingTaskSnapshot(taskID: "task-a", workspaceID: "ws", state: .ready, attemptState: nil,
                enqueueSequence: 1, installationID: "installation", accountRef: "account", isolation: .supported, exclusiveResourceIDs: []),
            SchedulingTaskSnapshot(taskID: "task-b", workspaceID: "ws", state: .ready, attemptState: nil,
                enqueueSequence: 2, installationID: "installation", accountRef: "account", isolation: .supported, exclusiveResourceIDs: []),
            SchedulingTaskSnapshot(taskID: "task-c", workspaceID: "ws", state: .ready, attemptState: nil,
                enqueueSequence: 3, installationID: "installation", accountRef: "account", isolation: .supported, exclusiveResourceIDs: []),
            SchedulingTaskSnapshot(taskID: "task-d", workspaceID: "ws", state: .ready, attemptState: nil,
                enqueueSequence: 4, installationID: "installation", accountRef: "account", isolation: .supported, exclusiveResourceIDs: []),
        ]
        let deps = [TaskDependency(predecessor: "task-a", successor: "task-d")]
        let created = try repository.create(runID: "run-eval", tasks: tasks, dependencies: deps, inputPins: pins,
            actorID: "actor", requestID: "create-eval", now: 100)
        let reserved = try repository.reserve(runID: "run-eval", revision: created.revision, currentInputPins: pins,
            actorID: "actor", requestID: "reserve-eval", now: 101)
        var rev = reserved.revision

        func completeTask(_ taskID: String, idx: Int) throws -> PreparedTaskBinding {
            let prep = try repository.prepareAttempt(
                runID: "run-eval", revision: rev, taskID: taskID, currentInputPins: pins,
                callerScopes: [.runRequest], snapshot: snap, requestedScope: scope,
                executionRequestPayloadDigest: "payload-\(taskID)", gate: gate,
                actorID: "actor", requestID: "prep-\(taskID)", now: Int64(110 + idx * 10)
            )
            try enforcer.recordApproval(ApprovalRecord(
                approvalID: "app-\(taskID)", kind: .execution, subjectClientID: "desktop-1",
                decidedByActorID: "actor", workspaceID: "ws", normalizedTarget: wsRoot.path,
                allowedScopes: [.runRequest],
                binding: ApprovalBinding(
                    runID: "run-eval", taskRevision: prep.binding.taskRevision, preparedAttemptID: prep.binding.attemptID,
                    instanceRevision: prep.binding.instanceRevision, bindingDigest: prep.binding.bindingDigest,
                    capabilitySnapshotID: prep.binding.capabilitySnapshotID, executionRequestDigest: prep.binding.executionRequestDigest
                ),
                policyVersion: 1, issuedAt: 50, expiresAt: 5000, status: .approved
            ), decidedByTrustedUI: true)
            let start = try repository.startAttempt(
                runID: "run-eval", revision: prep.result.revision, taskID: taskID, currentInputPins: pins,
                clientID: "desktop-1", executionApprovalID: "app-\(taskID)", snapshot: snap, requestedScope: scope,
                manager: manager, actorID: "actor", requestID: "start-\(taskID)", now: Int64(111 + idx * 10)
            )
            _ = try manager.completeProcessNormally(attemptID: prep.binding.attemptID, nowEpochSeconds: Int64(112 + idx * 10))
            let obs = try repository.observeRuntime(
                runID: "run-eval", revision: start.result.revision, taskID: taskID,
                gate: gate, actorID: "actor", requestID: "obs-\(taskID)", now: Int64(113 + idx * 10)
            )
            rev = obs.revision
            return prep.binding
        }

        let bindA = try completeTask("task-a", idx: 1)
        let bindB = try completeTask("task-b", idx: 2)
        let bindC = try completeTask("task-c", idx: 3)

        let manA = try manifestStore.collectImmutableSnapshot(
            manifestID: "man-a", runID: "run-eval", taskID: "task-a", attemptID: bindA.attemptID,
            taskRevision: bindA.taskRevision, workspaceRoot: wsRoot, relativePaths: ["result.txt"], collectedAt: 200
        )
        let manB = try manifestStore.collectImmutableSnapshot(
            manifestID: "man-b", runID: "run-eval", taskID: "task-b", attemptID: bindB.attemptID,
            taskRevision: bindB.taskRevision, workspaceRoot: wsRoot, relativePaths: ["result.txt"], collectedAt: 201
        )
        let manC = try manifestStore.collectImmutableSnapshot(
            manifestID: "man-c", runID: "run-eval", taskID: "task-c", attemptID: bindC.attemptID,
            taskRevision: bindC.taskRevision, workspaceRoot: wsRoot, relativePaths: ["result.txt"], collectedAt: 202
        )

        let baseCriteria = EvaluationCriteriaSpec(
            criteriaID: "crit-1", criteriaVersion: "1.0", evaluatorID: "eval-core", evaluatorVersion: "1.0",
            policyVersion: 1, requiredBoundaries: [.processLifecycle, .fileReads, .fileWrites, .network],
            expectedArtifactDigests: ["result.txt": try XCTUnwrap(manA.entries.first?.blobDigest)],
            requireHumanReview: false
        )

        // 1. AUTO_MATCH_HUMAN_PENDING is NEVER PASS -> INDETERMINATE -> Blocked
        let pendingHumanCriteria = EvaluationCriteriaSpec(
            criteriaID: "crit-1", criteriaVersion: "1.0", evaluatorID: "eval-core", evaluatorVersion: "1.0",
            policyVersion: 1, requiredBoundaries: [.processLifecycle, .fileReads], requireHumanReview: true
        )
        let resB = try engine.evaluateAndApplyToScheduler(
            evaluationID: "ev-b-human", trialID: "trial-b", runID: "run-eval", revision: rev, taskID: "task-b",
            currentInputPins: pins, attemptID: bindB.attemptID, taskRevision: bindB.taskRevision, manifestID: manB.manifestID,
            criteria: pendingHumanCriteria, observations: makeCleanObservations(boundaries: [.processLifecycle, .fileReads]),
            actorID: "actor", requestID: "apply-b", now: 210
        )
        XCTAssertEqual(resB.evaluation.record.verdict, .indeterminate)
        XCTAssertTrue(resB.evaluation.humanReviewPending)
        rev = resB.transition.revision
        XCTAssertEqual(try repository.readRunState(runID: "run-eval").tasks.first(where: { $0.taskID == "task-b" })?.state, .blocked)

        // 2. Observed safety violation -> FAIL -> Failed
        var badObs = makeCleanObservations(boundaries: [.processLifecycle, .fileReads, .fileWrites])
        badObs.append(BoundaryObservationReport(
            boundary: .network, observerID: "independent-observer-1", productSourceID: "oches-runtime-core",
            observerIsolated: true, startMarkerRecorded: true, endMarkerRecorded: true, observedSequences: [1],
            droppedEventsCount: 0, collectorHealthy: true, samplingActive: false, unobservedChildProcesses: 0,
            violations: [ObservedPolicyViolation(code: "UNAUTHORIZED_EGRESS", boundary: .network, detail: "blocked external host attempt")]
        ))
        let resC = try engine.evaluateAndApplyToScheduler(
            evaluationID: "ev-c-fail", trialID: "trial-c", runID: "run-eval", revision: rev, taskID: "task-c",
            currentInputPins: pins, attemptID: bindC.attemptID, taskRevision: bindC.taskRevision, manifestID: manC.manifestID,
            criteria: baseCriteria, observations: badObs, actorID: "actor", requestID: "apply-c", now: 211
        )
        XCTAssertEqual(resC.evaluation.record.verdict, .fail)
        rev = resC.transition.revision
        XCTAssertEqual(try repository.readRunState(runID: "run-eval").tasks.first(where: { $0.taskID == "task-c" })?.state, .failed)

        // 3. Clean run -> PASS -> Succeeded atomically + unlocks dependent task-d
        let resA = try engine.evaluateAndApplyToScheduler(
            evaluationID: "ev-a-pass", trialID: "trial-a", runID: "run-eval", revision: rev, taskID: "task-a",
            currentInputPins: pins, attemptID: bindA.attemptID, taskRevision: bindA.taskRevision, manifestID: manA.manifestID,
            criteria: baseCriteria, observations: makeCleanObservations(boundaries: [.processLifecycle, .fileReads, .fileWrites, .network]),
            actorID: "actor", requestID: "apply-a", now: 212
        )
        XCTAssertEqual(resA.evaluation.record.verdict, .pass)
        rev = resA.transition.revision
        XCTAssertEqual(try repository.readRunState(runID: "run-eval").tasks.first(where: { $0.taskID == "task-a" })?.state, .succeeded)

        let reserveD = try repository.reserve(runID: "run-eval", revision: rev, currentInputPins: pins,
            actorID: "actor", requestID: "reserve-d", now: 213)
        let reservedMap = try JSONDecoder().decode([String: String].self, from: Data(reserveD.responseJSON.utf8))
        XCTAssertNotNil(reservedMap["task-d"])
        rev = reserveD.revision

        // 4. V-11: Presenting task-a's PASS for task-d rejects with StorageError.denied
        let prepD = try repository.prepareAttempt(
            runID: "run-eval", revision: rev, taskID: "task-d", currentInputPins: pins,
            callerScopes: [.runRequest], snapshot: snap, requestedScope: scope,
            executionRequestPayloadDigest: "payload-task-d", gate: gate, actorID: "actor", requestID: "prep-d", now: 214
        )
        try enforcer.recordApproval(ApprovalRecord(
            approvalID: "app-d", kind: .execution, subjectClientID: "desktop-1",
            decidedByActorID: "actor", workspaceID: "ws", normalizedTarget: wsRoot.path,
            allowedScopes: [.runRequest],
            binding: ApprovalBinding(
                runID: "run-eval", taskRevision: prepD.binding.taskRevision, preparedAttemptID: prepD.binding.attemptID,
                instanceRevision: prepD.binding.instanceRevision, bindingDigest: prepD.binding.bindingDigest,
                capabilitySnapshotID: prepD.binding.capabilitySnapshotID, executionRequestDigest: prepD.binding.executionRequestDigest
            ),
            policyVersion: 1, issuedAt: 50, expiresAt: 5000, status: .approved
        ), decidedByTrustedUI: true)
        let startD = try repository.startAttempt(
            runID: "run-eval", revision: prepD.result.revision, taskID: "task-d", currentInputPins: pins,
            clientID: "desktop-1", executionApprovalID: "app-d", snapshot: snap, requestedScope: scope,
            manager: manager, actorID: "actor", requestID: "start-d", now: 215
        )
        _ = try manager.completeProcessNormally(attemptID: prepD.binding.attemptID, nowEpochSeconds: 216)
        let obsD = try repository.observeRuntime(
            runID: "run-eval", revision: startD.result.revision, taskID: "task-d",
            gate: gate, actorID: "actor", requestID: "obs-d", now: 217
        )
        XCTAssertThrowsError(try repository.applyEvaluation(
            runID: "run-eval", revision: obsD.revision, taskID: "task-d", currentInputPins: pins,
            evaluationID: "ev-a-pass", artifactManifestID: manA.manifestID, artifactManifestDigest: manA.manifestDigest,
            criteriaID: "crit-1", criteriaVersion: "1.0", policyVersion: 1, expectedVerdict: .pass,
            actorID: "actor", requestID: "reuse-pass-on-d", now: 218
        )) { XCTAssertEqual($0 as? StorageError, .denied) }

        // 5. Mutating workspace file after task-a PASS flags drift without corrupting stored history
        try Data("mutated-after-pass".utf8).write(to: outFile)
        XCTAssertEqual(
            try manifestStore.compareManifestAgainstWorkspace(manifestID: manA.manifestID, workspaceRoot: wsRoot),
            .mutated(paths: ["result.txt"])
        )
    }

    func testPairedComparisonAggregatorPreservesIncompleteAndFlagsInvalidBatches() throws {
        let validEntries = [
            PairedTrialEntry(datasetVersion: "ds-1", fixtureID: "f1", repeatIndex: 1, environmentDigest: "env-1", baselineStatus: .pass, candidateStatus: .pass, baselineViolations: 0, candidateViolations: 0, baselineObservationComplete: true, candidateObservationComplete: true),
            PairedTrialEntry(datasetVersion: "ds-1", fixtureID: "f1", repeatIndex: 2, environmentDigest: "env-1", baselineStatus: .pass, candidateStatus: .fail, baselineViolations: 0, candidateViolations: 1, baselineObservationComplete: true, candidateObservationComplete: true),
            PairedTrialEntry(datasetVersion: "ds-1", fixtureID: "f2", repeatIndex: 1, environmentDigest: "env-1", baselineStatus: .fail, candidateStatus: .pass, baselineViolations: 0, candidateViolations: 0, baselineObservationComplete: true, candidateObservationComplete: true),
            PairedTrialEntry(datasetVersion: "ds-1", fixtureID: "f2", repeatIndex: 2, environmentDigest: "env-1", baselineStatus: .fail, candidateStatus: .fail, baselineViolations: 0, candidateViolations: 0, baselineObservationComplete: true, candidateObservationComplete: true),
            // Incomplete observation despite PASS status must stay in incompletePairs
            PairedTrialEntry(datasetVersion: "ds-1", fixtureID: "f3", repeatIndex: 1, environmentDigest: "env-1", baselineStatus: .pass, candidateStatus: .pass, baselineViolations: 0, candidateViolations: 0, baselineObservationComplete: false, candidateObservationComplete: true),
            PairedTrialEntry(datasetVersion: "ds-1", fixtureID: "f3", repeatIndex: 2, environmentDigest: "env-1", baselineStatus: .notRun, candidateStatus: .indeterminate, baselineViolations: 0, candidateViolations: 0, baselineObservationComplete: true, candidateObservationComplete: false),
        ]

        let summary = EvaluationEngine.aggregatePairedComparisons(expectedDatasetVersion: "ds-1", entries: validEntries)
        XCTAssertTrue(summary.validBatch)
        XCTAssertEqual(summary.totalScheduledPairs, 6)
        XCTAssertEqual(summary.bothPass, 1)
        XCTAssertEqual(summary.baselineOnlyPass, 1)
        XCTAssertEqual(summary.candidateOnlyPass, 1)
        XCTAssertEqual(summary.bothFail, 1)
        XCTAssertEqual(summary.incompletePairs, 2)
        XCTAssertEqual(summary.totalSafetyViolations, 1)
        XCTAssertEqual(summary.incompleteObservationTrials, 2)

        // Duplicate + dataset mismatch + environment drift invalidates batch
        let invalidEntries = validEntries + [
            PairedTrialEntry(datasetVersion: "ds-2", fixtureID: "f1", repeatIndex: 1, environmentDigest: "env-2", baselineStatus: .pass, candidateStatus: .pass, baselineViolations: 0, candidateViolations: 0, baselineObservationComplete: true, candidateObservationComplete: true),
        ]
        let invalidSummary = EvaluationEngine.aggregatePairedComparisons(expectedDatasetVersion: "ds-1", entries: invalidEntries)
        XCTAssertFalse(invalidSummary.validBatch)
        XCTAssertEqual(invalidSummary.invalidationReasons.count, 3)
    }
}
