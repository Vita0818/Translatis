import XCTest
import IntatisCore
import IntatisPermission
import IntatisProtocol
@testable import IntatisAgentKernel

final class MCPApprovalInteractionPolicyTests: XCTestCase {
    func testNonMCPDecisionIsUnchanged() {
        let decision = engine(
            gate: .pass(reason: "review", risk: .medium),
            outcome: .init(
                decision: .askUser,
                risk: .medium,
                reason: "review"))
        XCTAssertEqual(
            MCPApprovalInteractionPolicy.decide(
                engineDecision: decision,
                authorization: authorization(mcp: nil),
                responderMode: .manual),
            decision.outcome)
    }

    func testHardGateDenyAndAskCannotBeBypassedByAnyMode() {
        for mode in MCPApprovalMode.allCasesForTests {
            let mcp = authorization(
                mode: mode,
                approvalDecision: .allow)
            let denied = engine(
                gate: .deny(reason: "hard deny", risk: .high),
                outcome: .init(
                    decision: .deny,
                    risk: .high,
                    reason: "hard deny"))
            XCTAssertEqual(
                MCPApprovalInteractionPolicy.decide(
                    engineDecision: denied,
                    authorization: mcp,
                    responderMode: .manual).decision,
                .deny)

            let asked = engine(
                gate: .ask(reason: "hard ask", risk: .high),
                outcome: .init(
                    decision: .askUser,
                    risk: .high,
                    reason: "hard ask"))
            XCTAssertEqual(
                MCPApprovalInteractionPolicy.decide(
                    engineDecision: asked,
                    authorization: mcp,
                    responderMode: .manual).decision,
                .askUser)
        }
    }

    func testReviewerAndAutomaticControlPlaneCannotBeBypassed() {
        let approve = authorization(
            mode: .approve,
            approvalDecision: .allow)
        let reviewerAsk = engine(
            gate: .pass(reason: "review", risk: .medium),
            outcome: .init(
                decision: .askUser,
                risk: .medium,
                reason: "reviewer asks"),
            reviewerConsulted: true)
        XCTAssertEqual(
            MCPApprovalInteractionPolicy.decide(
                engineDecision: reviewerAsk,
                authorization: approve,
                responderMode: .manual).decision,
            .askUser)

        let responderAsk = engine(
            gate: .pass(reason: "review", risk: .medium),
            outcome: .init(
                decision: .askUser,
                risk: .medium,
                reason: "control-plane review"))
        XCTAssertEqual(
            MCPApprovalInteractionPolicy.decide(
                engineDecision: responderAsk,
                authorization: approve,
                responderMode: .automaticReviewer).decision,
            .askUser)
    }

    func testPromptAlwaysAddsPerCallInteraction() {
        let result = MCPApprovalInteractionPolicy.decide(
            engineDecision: engine(
                gate: .pass(reason: "reviewed", risk: .medium),
                outcome: .init(
                    decision: .allow,
                    risk: .medium,
                    reason: "reviewed"),
                reviewerConsulted: true),
            authorization: authorization(
                mode: .prompt,
                approvalDecision: .askUser),
            responderMode: .manual)
        XCTAssertEqual(result.decision, .askUser)
    }

    func testWritesRequiresHostProvenReadOnlyDecision() {
        let unreviewedPass = engine(
            gate: .pass(reason: "review", risk: .medium),
            outcome: .init(
                decision: .askUser,
                risk: .medium,
                reason: "manual review"))
        XCTAssertEqual(
            MCPApprovalInteractionPolicy.decide(
                engineDecision: unreviewedPass,
                authorization: authorization(
                    mode: .writes,
                    approvalDecision: .askUser),
                responderMode: .manual).decision,
            .askUser)
        XCTAssertEqual(
            MCPApprovalInteractionPolicy.decide(
                engineDecision: unreviewedPass,
                authorization: authorization(
                    mode: .writes,
                    approvalDecision: .allow),
                responderMode: .manual).decision,
            .allow)
    }

    func testAutoOnlySkipsManualInteractionForExactRememberedAllow() {
        let unreviewedPass = engine(
            gate: .pass(reason: "review", risk: .medium),
            outcome: .init(
                decision: .askUser,
                risk: .medium,
                reason: "manual review"))
        XCTAssertEqual(
            MCPApprovalInteractionPolicy.decide(
                engineDecision: unreviewedPass,
                authorization: authorization(
                    mode: .auto,
                    approvalDecision: .askUser),
                responderMode: .manual).decision,
            .askUser)
        XCTAssertEqual(
            MCPApprovalInteractionPolicy.decide(
                engineDecision: unreviewedPass,
                authorization: authorization(
                    mode: .auto,
                    approvalDecision: .allow),
                responderMode: .manual).decision,
            .allow)
    }

    func testApproveSkipsOnlyUnreviewedManualMCPPrompt() {
        let result = MCPApprovalInteractionPolicy.decide(
            engineDecision: engine(
                gate: .pass(reason: "review", risk: .medium),
                outcome: .init(
                    decision: .askUser,
                    risk: .medium,
                    reason: "manual review")),
            authorization: authorization(
                mode: .approve,
                approvalDecision: .allow),
            responderMode: .manual)
        XCTAssertEqual(result.decision, .allow)
    }

    func testExplicitMCPPolicyDenyIsTerminal() {
        let result = MCPApprovalInteractionPolicy.decide(
            engineDecision: engine(
                gate: .allow(reason: "safe", risk: .low),
                outcome: .init(
                    decision: .allow,
                    risk: .low,
                    reason: "safe")),
            authorization: authorization(
                mode: .approve,
                approvalDecision: .deny),
            responderMode: .manual)
        XCTAssertEqual(result.decision, .deny)
        XCTAssertEqual(result.risk, .high)
    }

    private func engine(
        gate: GateResult,
        outcome: PermissionOutcome,
        reviewerConsulted: Bool = false
    ) -> PermissionEngineDecision {
        PermissionEngineDecision(
            gate: gate,
            outcome: outcome,
            reviewerConsulted: reviewerConsulted)
    }

    private func authorization(
        mode: MCPApprovalMode,
        approvalDecision: MCPApprovalDecision
    ) -> ResolvedToolAuthorization {
        authorization(
            mcp: MCPToolAuthorizationSnapshot(
                server: MCPServerReference(
                    serverID: MCPServerID(rawValue: "server-fixture"),
                    serverRevision:
                        MCPServerRevision(rawValue: "revision-fixture")),
                attachmentID: MCPAttachmentID(
                    rawValue: "attachment-fixture"),
                grantID: MCPGrantID(rawValue: "grant-fixture"),
                grantFingerprint: "grant-fingerprint",
                connectionGeneration: MCPConnectionGeneration(
                    rawValue: "generation-fixture"),
                rawCatalogRevision: MCPRawCatalogRevision(
                    rawValue: "catalog-fixture"),
                agentCatalogViewRevision:
                    MCPAgentCatalogViewRevision(
                        rawValue: "view-fixture"),
                bindingID: MCPBindingID(rawValue: "binding-fixture"),
                remoteToolName: "write",
                schemaHash: "schema-fingerprint",
                protocolProfile: .codexCompat,
                negotiatedProtocolVersion:
                    MCPNegotiatedProtocolVersion(.v2025_06_18),
                effectiveApprovalMode: mode,
                approvalDecision: approvalDecision,
                approvalPolicySource: .serverDefault,
                environmentReference: MCPEnvironmentReference(
                    rawValue: "environment-fixture"),
                authorityFingerprint: "authority-fingerprint",
                revocationGeneration: MCPRevocationGeneration(
                    rawValue: "revocation-fixture")))
    }

    private func authorization(
        mcp: MCPToolAuthorizationSnapshot?
    ) -> ResolvedToolAuthorization {
        ResolvedToolAuthorization(
            authorizationID: "authorization-fixture",
            registryVersion: "registry-fixture",
            concreteToolID: "tool-fixture",
            descriptorFingerprint: "descriptor-fingerprint",
            toolName: "mcp__fixture__write",
            canonicalAction: "mcp.tool.call",
            requiredCapabilities: [],
            membership: .notRequired,
            capabilityLeaseID: nil,
            capabilityTaskID: nil,
            workspaceLeaseID: nil,
            workspaceAccess: nil,
            workspaceRootIdentity: nil,
            normalizedArgumentsDigest: "arguments-fingerprint",
            normalizedArgumentsCharacterCount: 2,
            intent: PermissionIntent(
                action: "mcp.tool.call",
                resources: [
                    .init(
                        kind: .tool,
                        value: "mcp__fixture__write"),
                ],
                dataEffects: [.destructive],
                replayPolicy:
                    .doNotReplay),
            sideEffect: .destructive,
            risksNetwork: true,
            replayPolicy:
                .doNotReplay,
            mcp: mcp)
    }
}

private extension MCPApprovalMode {
    static let allCasesForTests: [MCPApprovalMode] = [
        .auto, .prompt, .writes, .approve,
    ]
}
