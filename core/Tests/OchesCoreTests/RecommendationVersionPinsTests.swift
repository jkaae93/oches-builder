import Foundation
import XCTest
@testable import OchesCore

final class RecommendationVersionPinsTests: XCTestCase {
    func testProfileCapabilityAndConstraintsArePinnedAndExpire() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try AnalyzerProfileDraft.build(profileID: "profile", workspaceRef: "ws", analyzerVersion: "1",
            analyzedAt: Date(timeIntervalSince1970: 100), roots: [root.path], exclusions: [], userConstraints: [],
            collection: AnalyzerSafeRoot(rootPath: root.path).collectEvidence())
        let scope = CapabilityScope(installationID: "installation", executableIdentity: "binary", cliVersion: "1", adapterVersion: "1",
            osVersionArch: "macos-arm64", accountRef: "account", accountType: .unknown, workspaceID: "ws", workspaceLocationAuthority: "local",
            workspaceTrust: true, clientID: "desktop", clientKind: "desktop", negotiatedProtocolMajorMinor: "1.0", policyVersion: 1)
        func pins(_ revision: String, time: Int64 = 100) throws -> RecommendationVersionPins {
            try RecommendationVersionPins.capture(profile: profile,
                profileRevision: RevisionRef(objectID: "arc02/profile/profile", storeGeneration: "gen", revision: revision),
                snapshot: CapabilitySnapshot(snapshotID: "snapshot", scope: scope, entries: [], observedAt: time),
                registryVersions: [], constraints: [])
        }
        let original = try pins("1")
        let proposal = ArchitectureProposal(pins: original, createdAt: 100,
            candidates: try ArchitectureCandidateGenerator.generate(constraints: []))
        XCTAssertNoThrow(try proposal.validateFreshness(current: pins("1"), now: 101))
        XCTAssertThrowsError(try proposal.validateFreshness(current: pins("2"), now: 101))
        XCTAssertThrowsError(try proposal.validateFreshness(current: pins("1", time: 101), now: 101))
        XCTAssertThrowsError(try proposal.validateFreshness(current: original, now: 86_500))
        XCTAssertThrowsError(try proposal.validateFreshness(current: original, now: 99))
        let store = try SQLiteStore(path: root.appendingPathComponent("db").path, workspaceID: "ws", initialStoreGeneration: "gen")
        let profiles = AnalyzerProfileRepository(store: store)
        let saved = try profiles.save(profile, actorID: "actor", requestID: "save-profile", expectedRevision: nil, nowEpochSeconds: 100)
        let service = RecommendationService(profiles: profiles)
        for entries: [CapabilityEntry] in [[], [CapabilityEntry(capabilityID: .runResume, status: .supported,
            basis: .documented, evidenceRef: "documentation-only", observedAt: 100)]] {
            let evaluation = try service.propose(profileID: "profile", profileRevision: saved.revision,
                snapshot: CapabilitySnapshot(snapshotID: "snapshot", scope: scope, entries: entries, observedAt: 100),
                requestedScope: scope, registryVersions: [], constraints: [], requiredCapabilities: [.runResume], now: 101)
            XCTAssertEqual(evaluation.proposal.candidates.first?.pattern, .singleAgent)
            XCTAssertEqual(evaluation.assessments.first?.requirements, .unknown)
            XCTAssertTrue(evaluation.uncertainties.contains("execution_not_authorized"))
            XCTAssertEqual(evaluation.evidenceRefs, [saved.revision])
        }
    }
}
