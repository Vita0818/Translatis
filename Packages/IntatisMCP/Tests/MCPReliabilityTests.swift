import Foundation
import IntatisCore
import IntatisProtocol
import XCTest
@testable import IntatisMCP

final class MCPReliabilityTests: XCTestCase {
    func testExponentialBackoffIsJitteredBoundedAndDeterministic() {
        let policy = MCPReconnectPolicy(
            initialDelayMilliseconds: 100,
            maximumDelayMilliseconds: 1_000,
            multiplier: 2,
            jitterFraction: 0.25,
            maximumAttempts: 4)
        XCTAssertEqual(
            policy.delayMilliseconds(attempt: 1, entropy: -1),
            75)
        XCTAssertEqual(
            policy.delayMilliseconds(attempt: 1, entropy: 1),
            125)
        XCTAssertEqual(
            policy.delayMilliseconds(attempt: 3, entropy: 0),
            400)
        XCTAssertEqual(
            policy.delayMilliseconds(attempt: 20, entropy: 1),
            1_000)
    }

    func testReconnectNeverReplaysOperationAndStaleGenerationCannotSchedule() async throws {
        let policy = MCPReconnectPolicy(
            initialDelayMilliseconds: 100,
            maximumDelayMilliseconds: 1_000,
            multiplier: 2,
            jitterFraction: 0,
            maximumAttempts: 2)
        let controller = MCPReconnectController(policy: policy)
        let identity = reliabilityIdentity()
        let first = MCPConnectionGeneration(rawValue: "generation-1")
        try await controller.registerLiveIntent(
            identity: identity,
            generation: first,
            reason: .send)

        let uncertain = await controller.recordFailure(
            key: identity.poolKey,
            generation: first,
            kind: .executionUncertain)
        guard case .reconnectConnectionOnly(
            let attempt,
            let delay,
            let invocationMustFail,
            let terminal) = uncertain else {
            return XCTFail("execution uncertainty did not fence replay")
        }
        XCTAssertEqual(attempt, 1)
        XCTAssertEqual(delay, 100)
        XCTAssertTrue(invocationMustFail)
        XCTAssertEqual(terminal.code, "mcp_execution_uncertain")
        XCTAssertTrue(terminal.summary.contains("will not be replayed"))

        let stale = await controller.recordFailure(
            key: identity.poolKey,
            generation: MCPConnectionGeneration(
                rawValue: "retired-generation"),
            kind: .connectionLost)
        XCTAssertEqual(stale, .ignoreStaleGeneration)

        let connectionOnly = await controller.recordFailure(
            key: identity.poolKey,
            generation: first,
            kind: .connectionLost)
        guard case .reconnectConnectionOnly(
            let secondAttempt,
            let secondDelay,
            let secondMustFail,
            _) = connectionOnly else {
            return XCTFail("live connection loss did not back off")
        }
        XCTAssertEqual(secondAttempt, 2)
        XCTAssertEqual(secondDelay, 200)
        XCTAssertFalse(secondMustFail)

        let exhausted = await controller.recordFailure(
            key: identity.poolKey,
            generation: first,
            kind: .networkPartition)
        guard case .awaitExplicitActivation(let diagnostic) = exhausted else {
            return XCTFail("bounded attempts were not enforced")
        }
        XCTAssertEqual(diagnostic.code, "mcp_reconnect_exhausted")
        let snapshot = await controller.snapshot(key: identity.poolKey)
        XCTAssertNil(snapshot)
    }

    func testReadyResetAndHotReloadNeverReuseChangedIdentity() async throws {
        let controller = MCPReconnectController()
        let original = reliabilityIdentity()
        let generation = MCPConnectionGeneration(
            rawValue: "generation-ready")
        try await controller.registerLiveIntent(
            identity: original,
            generation: generation,
            reason: .explicitConnect)
        let ready = await controller.markReady(
            key: original.poolKey,
            generation: generation)
        XCTAssertTrue(ready)
        let readySnapshot = await controller.snapshot(
            key: original.poolKey)
        XCTAssertEqual(readySnapshot?.attempts, 0)
        XCTAssertEqual(readySnapshot?.ready, true)

        XCTAssertEqual(
            MCPHotReloadPolicy.action(
                current: original,
                replacement: original,
                currentGeneration: generation,
                liveActivationReason: .explicitConnect),
            .noChange)

        let replacement = reliabilityIdentity(
            serverRevision: "revision-2")
        XCTAssertEqual(
            MCPHotReloadPolicy.action(
                current: original,
                replacement: replacement,
                currentGeneration: generation,
                liveActivationReason: .send),
            .drainAndReconnectConnectionOnly(
                generation: generation))
        XCTAssertEqual(
            MCPHotReloadPolicy.action(
                current: original,
                replacement: replacement,
                currentGeneration: generation,
                liveActivationReason: nil),
            .drainAndWaitForExplicitActivation(
                generation: generation))

        let replacementGeneration = MCPConnectionGeneration(
            rawValue: "generation-replacement")
        try await controller.replaceAfterHotReload(
            oldKey: original.poolKey,
            newIdentity: replacement,
            newGeneration: replacementGeneration,
            reason: .explicitConnect)
        let oldSnapshot = await controller.snapshot(
            key: original.poolKey)
        let newSnapshot = await controller.snapshot(
            key: replacement.poolKey)
        XCTAssertNil(oldSnapshot)
        XCTAssertEqual(
            newSnapshot?.generation,
            replacementGeneration)
        XCTAssertFalse(newSnapshot?.ready ?? true)
    }

    func testMetricsHaveBoundedCardinalityAndNoRawServerLabels() async {
        let metrics = MCPRuntimeMetrics(maximumSeries: 8)
        for index in 0..<100 {
            let server = MCPServerReference(
                serverID: MCPServerID(
                    rawValue: "secret-server-\(index)"),
                serverRevision: MCPServerRevision(
                    rawValue: "revision-\(index)"))
            await metrics.record(
                server: server,
                operation: .toolCall,
                outcome: .succeeded,
                latencyMilliseconds: index)
        }
        let snapshot = await metrics.snapshot()
        XCTAssertEqual(snapshot.counters.count, 8)
        XCTAssertEqual(snapshot.overflowedSeries, 92)
        XCTAssertEqual(
            snapshot.latencyCounts.reduce(0, +),
            100)
        XCTAssertTrue(snapshot.counters.keys.allSatisfy {
            $0.serverBucket.count == 16
                && !$0.serverBucket.contains("secret-server")
        })
    }

    func testDiagnosticsRedactSecretsURLsPathsAndBoundUTF8() {
        let secret = "sk-fixture-secret-value"
        let diagnostic = MCPBoundedDiagnostics.summarize(
            code: .transport,
            message:
                "Bearer bearer-token api_key=visible \(secret) https://user:pass@example.test/path?access_token=leak&x=1 /Users/alice/private/file " + String(repeating: "界", count: 400),
            exactRedactions: [secret],
            maximumUTF8Bytes: 256)
        XCTAssertEqual(diagnostic.code, "mcp_transport")
        XCTAssertLessThanOrEqual(
            diagnostic.summary.utf8.count,
            256)
        XCTAssertFalse(diagnostic.summary.contains("bearer-token"))
        XCTAssertFalse(diagnostic.summary.contains("visible"))
        XCTAssertFalse(diagnostic.summary.contains(secret))
        XCTAssertFalse(diagnostic.summary.contains("user:pass"))
        XCTAssertFalse(diagnostic.summary.contains("leak"))
        XCTAssertFalse(diagnostic.summary.contains("/Users/alice"))
        XCTAssertTrue(diagnostic.summary.contains("[redacted]"))
        XCTAssertTrue(diagnostic.summary.contains("[path]"))
    }

    func testRestoreRetryAndAttachCannotRegisterReconnectIntent() async {
        let controller = MCPReconnectController()
        let identity = reliabilityIdentity()
        for reason in [
            MCPRuntimeActivationReason.coldRestore,
            .restore,
            .attach,
            .retry,
            .test,
            .authenticate,
            .refresh,
        ] {
            do {
                try await controller.registerLiveIntent(
                    identity: identity,
                    generation: MCPConnectionGeneration(
                        rawValue: "blocked-\(reason.rawValue)"),
                    reason: reason)
                XCTFail("\(reason.rawValue) created a live generation")
            } catch {
                XCTAssertEqual(
                    error as? MCPRuntimeError,
                    .activationDoesNotCreateConnection(reason))
            }
        }
        let snapshot = await controller.snapshot(
            key: identity.poolKey)
        XCTAssertNil(snapshot)
    }
}

private func reliabilityIdentity(
    serverRevision: String = "revision-1"
) -> MCPConnectionReuseIdentity {
    let sessionID = SessionID(rawValue: "session-reliability")
    let agentID = AgentID(rawValue: "agent-reliability")
    let server = MCPServerReference(
        serverID: MCPServerID(rawValue: "server-reliability"),
        serverRevision: MCPServerRevision(
            rawValue: serverRevision))
    let authority = MCPConnectionAuthority(
        server: server,
        transport: .streamableHTTP,
        protocolProfile: .standardExtended,
        sessionID: sessionID,
        agentID: agentID,
        attachmentID: MCPAttachmentID(
            rawValue: "attachment-reliability"),
        capabilityLeaseID: CapabilityLeaseID(
            rawValue: "capability-reliability"),
        capabilityTaskID: nil,
        workspaceLeaseID: WorkspaceLeaseID(
            rawValue: "workspace-reliability"),
        workspaceRootIdentityFingerprint: "root-reliability",
        workspaceLeasePolicyFingerprint:
            String(repeating: "a", count: 64),
        attachmentPolicyRevision: MCPPolicyRevision(
            rawValue: "attachment-policy"),
        accountReference: MCPAccountReference(
            rawValue: "account-reliability"),
        environmentReference: MCPEnvironmentReference(
            rawValue: "environment-reliability"),
        launchArtifactFingerprint: nil,
        rootsPolicyRevision: MCPPolicyRevision(
            rawValue: "roots-policy"),
        networkPolicyRevision: MCPPolicyRevision(
            rawValue: "network-policy"),
        sandboxProfileRevision: MCPPolicyRevision(
            rawValue: "sandbox-policy"),
        sandboxPolicyFingerprint:
            String(repeating: "b", count: 64),
        hostPlatform: "test",
        fingerprint: "authority-\(serverRevision)")
    return MCPConnectionReuseIdentity(
        server: server,
        transport: .streamableHTTP,
        transportConfigurationFingerprint:
            "transport-\(serverRevision)",
        authority: authority,
        oauthAccountReference: MCPAccountReference(
            rawValue: "account-reliability"),
        environmentReference: MCPEnvironmentReference(
            rawValue: "environment-reliability"),
        launchArtifactFingerprint: nil,
        runtimeIdentityFingerprint: "runtime-reliability")
}
