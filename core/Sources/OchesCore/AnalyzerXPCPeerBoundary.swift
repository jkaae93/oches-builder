import Foundation

/// The readiness endpoint contains no analysis or approval operation.
@objc protocol AnalyzerXPCReadinessProtocol {
    func readiness(withReply reply: @escaping (String) -> Void)
}

private final class AnalyzerXPCReadiness: NSObject, AnalyzerXPCReadinessProtocol {
    func readiness(withReply reply: @escaping (String) -> Void) { reply("unavailable") }
}

private func analyzerPeerRequirement(teamID: String, signingIdentifier: String) throws -> String {
    func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 46 || byte == 95
        }
    }
    guard valid(teamID), valid(signingIdentifier) else { throw XPCIdentityError.emptyIdentityClaim }
    return PeerIdentityRequirement(expectedTeamID: teamID, expectedSigningIdentifier: signingIdentifier).xpcRequirementString
}

/// Configures an actual incoming NSXPCConnection. The OS, not a caller-supplied
/// identity claim, enforces the peer requirement on messages. This is not an
/// authorization decision and does not establish a user's approval.
final class AnalyzerXPCPeerBoundary: NSObject, NSXPCListenerDelegate {
    private let expectedUID: uid_t
    private let requirement: String

    init(teamID: String, signingIdentifier: String, expectedUID: uid_t) throws {
        self.expectedUID = expectedUID
        self.requirement = try analyzerPeerRequirement(teamID: teamID, signingIdentifier: signingIdentifier)
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == expectedUID else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: AnalyzerXPCReadinessProtocol.self)
        connection.exportedObject = AnalyzerXPCReadiness()
        connection.resume()
        return true
    }
}

/// Readiness only. XPC validates incoming replies, so the first outgoing
/// message must not contain confidential data or carry authority.
final class AnalyzerXPCProbeClient {
    private let connection: NSXPCConnection

    init(endpoint: NSXPCListenerEndpoint, teamID: String, signingIdentifier: String) throws {
        let requirement = try analyzerPeerRequirement(teamID: teamID, signingIdentifier: signingIdentifier)
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: AnalyzerXPCReadinessProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
        self.connection = connection
    }

    func readiness(onError: @escaping (Error) -> Void, reply: @escaping (String) -> Void) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler(onError) as? AnalyzerXPCReadinessProtocol else {
            onError(XPCIdentityError.unauthenticatedRequestDenied)
            return
        }
        proxy.readiness(withReply: reply)
    }

    func invalidate() { connection.invalidate() }
    deinit { connection.invalidate() }
}
