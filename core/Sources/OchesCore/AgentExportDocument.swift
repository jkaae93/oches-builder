import CryptoKit
import Foundation

enum AgentExportDocumentError: Error, Equatable {
    case invalidContent
    case targetChanged
    case contentChanged
}

struct AgentExportDocument {
    let plan: AgentExportPlan
    let previousContent: Data?
    let proposedContent: Data
    let proposedDigest: Data
    let approvalDigest: Data
    let rootIdentity: AnalyzerSafeRoot.RootIdentity?
    let rootSessionID: String?

    static func prepare(plan: AgentExportPlan, previousContent: Data?, proposedContent: Data,
                        rootIdentity: AnalyzerSafeRoot.RootIdentity? = nil, rootSessionID: String? = nil) throws -> AgentExportDocument {
        if let rootSessionID {
            guard rootIdentity != nil, UUID(uuidString: rootSessionID) != nil else { throw AgentExportDocumentError.invalidContent }
        }
        guard proposedContent.count <= 262_144,
              previousContent == nil || previousContent!.count <= 262_144,
              String(data: proposedContent, encoding: .utf8) != nil,
              previousContent == nil || String(data: previousContent!, encoding: .utf8) != nil,
              !proposedContent.contains(0), previousContent == nil || !previousContent!.contains(0)
        else { throw AgentExportDocumentError.invalidContent }
        let priorDigest = previousContent.map { Data(SHA256.hash(data: $0)) }
        guard priorDigest == plan.binding.targetDigest else { throw AgentExportDocumentError.targetChanged }
        let proposedDigest = Data(SHA256.hash(data: proposedContent))
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        let digest = try canonicalSHA256(.object([
            ("domain", .string("oches.agent.export-document.v1")),
            ("planDigest", .string(hex(plan.digest))),
            ("rootDevice", rootIdentity.map { .string(String($0.device)) } ?? .null),
            ("rootInode", rootIdentity.map { .string(String($0.inode)) } ?? .null),
            ("rootSessionID", rootSessionID.map { .string($0) } ?? .null),
            ("previousDigest", priorDigest.map { .string(hex($0)) } ?? .null),
            ("proposedDigest", .string(hex(proposedDigest))),
            ("proposedByteCount", .number(String(proposedContent.count)))
        ]))
        return AgentExportDocument(plan: plan, previousContent: previousContent, proposedContent: proposedContent,
            proposedDigest: proposedDigest, approvalDigest: digest, rootIdentity: rootIdentity, rootSessionID: rootSessionID)
    }

    func revalidate(currentBinding: AgentExportBinding, currentContent: Data?, proposedContent: Data) throws {
        try plan.revalidate(current: currentBinding)
        guard currentContent == previousContent else { throw AgentExportDocumentError.targetChanged }
        guard proposedContent == self.proposedContent else { throw AgentExportDocumentError.contentChanged }
    }

    func approvalRequestBinding(planID: String) throws -> ApprovalBinding {
        guard !planID.isEmpty, !planID.utf8.contains(0) else { throw AgentExportDocumentError.invalidContent }
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        return ApprovalBinding(planID: planID, planDigest: hex(approvalDigest),
            targetFileVersions: [plan.binding.targetPath: plan.binding.targetDigest.map(hex) ?? "ABSENT"],
            agentDefinitionRevision: plan.binding.definitionRevision, adapterVersion: plan.binding.adapterVersion)
    }
}
