import Darwin
import Foundation
import XCTest
@testable import OchesCore

final class AnalyzerXPCPeerBoundaryTests: XCTestCase {
    private final class ControlObject: NSObject, AnalyzerXPCReadinessProtocol {
        func readiness(withReply reply: @escaping (String) -> Void) { reply("control") }
    }
    private final class ControlDelegate: NSObject, NSXPCListenerDelegate {
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            guard connection.effectiveUserIdentifier == getuid() else { return false }
            connection.exportedInterface = NSXPCInterface(with: AnalyzerXPCReadinessProtocol.self)
            connection.exportedObject = ControlObject()
            connection.resume()
            return true
        }
    }

    func testAnonymousXPCPositiveControl() throws {
        let delegate = ControlDelegate()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: AnalyzerXPCReadinessProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        let replied = expectation(description: "same-process XPC control replies")
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in XCTFail("control XPC failed") } as? AnalyzerXPCReadinessProtocol
        XCTAssertNotNil(proxy)
        proxy?.readiness { value in XCTAssertEqual(value, "control"); replied.fulfill() }
        wait(for: [replied], timeout: 5)
        withExtendedLifetime(delegate) {}
    }

    func testRequirementRejectsEmptyAndInjectionCharacters() throws {
        XCTAssertThrowsError(try AnalyzerXPCPeerBoundary(teamID: "", signingIdentifier: "com.example.app", expectedUID: getuid()))
        XCTAssertThrowsError(try AnalyzerXPCPeerBoundary(teamID: "TEAM\" or true", signingIdentifier: "com.example.app", expectedUID: getuid()))
        XCTAssertThrowsError(try AnalyzerXPCPeerBoundary(teamID: "TEAM", signingIdentifier: "com.example.\" or true", expectedUID: getuid()))
        XCTAssertNoThrow(try AnalyzerXPCPeerBoundary(teamID: "TEAM123", signingIdentifier: "com.example.app", expectedUID: getuid()))
    }

    func testClientRejectsReplyFromCoreWithMismatchedSignature() throws {
        let delegate = ControlDelegate()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        XCTAssertThrowsError(try AnalyzerXPCProbeClient(endpoint: listener.endpoint, teamID: "TEAM\" or true", signingIdentifier: "com.example.core"))
        let client = try AnalyzerXPCProbeClient(endpoint: listener.endpoint, teamID: "NONEXISTENTTEAM", signingIdentifier: "com.example.must.not.match")
        defer { client.invalidate() }
        let rejected = expectation(description: "untrusted core reply rejected")
        client.readiness(onError: { _ in rejected.fulfill() }, reply: { _ in XCTFail("untrusted Core replied") })
        wait(for: [rejected], timeout: 5)
        withExtendedLifetime(delegate) {}
    }

    func testServiceProbeRejectsInvalidServiceAndUnavailableService() throws {
        XCTAssertThrowsError(try AnalyzerXPCProbeClient(serviceName: "bad\"name", teamID: "TEAM", signingIdentifier: "com.example.core"))
        let client = try AnalyzerXPCProbeClient(serviceName: "com.oches.test.no-such-service", teamID: "TEAM", signingIdentifier: "com.example.core")
        defer { client.invalidate() }
        let rejected = expectation(description: "missing Core service fails closed")
        client.readiness(onError: { _ in rejected.fulfill() }, reply: { _ in XCTFail("missing service replied") })
        wait(for: [rejected], timeout: 5)
    }

    func testActualXPCRejectsPeerWithoutRequiredSignature() throws {
        let delegate = try AnalyzerXPCPeerBoundary(teamID: "NONEXISTENTTEAM", signingIdentifier: "com.example.must.not.match", expectedUID: getuid())
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: AnalyzerXPCReadinessProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        let rejected = expectation(description: "OS rejects mismatched signed peer")
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in rejected.fulfill() } as? AnalyzerXPCReadinessProtocol
        XCTAssertNotNil(proxy)
        proxy?.readiness { _ in XCTFail("untrusted XPC peer received a reply") }
        wait(for: [rejected], timeout: 5)
        withExtendedLifetime(delegate) {}
    }

    func testActualXPCRejectsOtherUID() throws {
        let otherUID: uid_t = getuid() == 0 ? 1 : 0
        let delegate = try AnalyzerXPCPeerBoundary(teamID: "NONEXISTENTTEAM", signingIdentifier: "com.example.must.not.match", expectedUID: otherUID)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: AnalyzerXPCReadinessProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        let rejected = expectation(description: "different UID rejected")
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in rejected.fulfill() } as? AnalyzerXPCReadinessProtocol
        XCTAssertNotNil(proxy)
        proxy?.readiness { _ in XCTFail("unexpected reply") }
        wait(for: [rejected], timeout: 5)
        withExtendedLifetime(delegate) {}
    }
}
