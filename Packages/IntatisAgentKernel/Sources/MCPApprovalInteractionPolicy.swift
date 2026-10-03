import IntatisPermission
import IntatisProtocol

/// Applies the MCP-specific interaction mode only after the ordinary Intatis
/// deterministic gate and optional in-engine reviewer have run.
///
/// This layer cannot widen a hard gate result, a reviewer denial/request, or
/// the automatic-reviewer control-plane path. It only decides whether an
/// otherwise eligible MCP call needs an additional per-call interaction.
enum MCPApprovalInteractionPolicy {
    static func decide(
        engineDecision: PermissionEngineDecision,
        authorization: ResolvedToolAuthorization,
        responderMode: PermissionApprovalMode
    ) -> PermissionOutcome {
        guard let mcp = authorization.mcp else {
            return engineDecision.outcome
        }

        switch engineDecision.gate {
        case .deny, .ask:
            return engineDecision.outcome
        case .allow, .pass:
            break
        }

        guard engineDecision.outcome.decision != .deny else {
            return engineDecision.outcome
        }
        guard mcp.approvalDecision != .deny else {
            return PermissionOutcome(
                decision: .deny,
                risk: .high,
                reason: "MCP host policy denied this exact tool binding")
        }

        // An in-engine reviewer ask is a real reviewer decision, not the
        // ordinary manual adaptation of an unreviewed gate pass.
        if engineDecision.reviewerConsulted,
           engineDecision.outcome.decision == .askUser {
            return engineDecision.outcome
        }

        // Production Cowork deliberately uses the PermissionResponder as its
        // independent reviewer. Preserve the ask so every MCP mode still
        // traverses that control plane; `approve` is never blanket authority.
        if responderMode == .automaticReviewer,
           engineDecision.outcome.decision == .askUser {
            return engineDecision.outcome
        }

        switch mcp.effectiveApprovalMode {
        case .prompt:
            return PermissionOutcome(
                decision: .askUser,
                risk: engineDecision.outcome.risk,
                reason:
                    "MCP prompt mode requires approval for every exact call")

        case .writes:
            guard mcp.approvalDecision == .allow else {
                return PermissionOutcome(
                    decision: .askUser,
                    risk: engineDecision.outcome.risk,
                    reason:
                        "MCP writes mode requires approval because the host did not prove this exact tool read-only")
            }
            return allowedOutcome(
                from: engineDecision.outcome,
                reason:
                    "MCP writes mode accepted a host-proven read-only tool")

        case .auto:
            // An allow in auto is emitted only for an exact, still-live
            // remembered approval. Without it, normal gate/reviewer/manual
            // permission behavior remains authoritative.
            guard mcp.approvalDecision == .allow else {
                return engineDecision.outcome
            }
            return allowedOutcome(
                from: engineDecision.outcome,
                reason:
                    "exact remembered MCP auto approval matched")

        case .approve:
            return allowedOutcome(
                from: engineDecision.outcome,
                reason:
                    "MCP approve mode omitted only the MCP-specific prompt")
        }
    }

    private static func allowedOutcome(
        from outcome: PermissionOutcome,
        reason: String
    ) -> PermissionOutcome {
        PermissionOutcome(
            decision: .allow,
            risk: outcome.risk,
            reason: reason)
    }
}
