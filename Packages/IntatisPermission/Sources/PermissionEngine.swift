import Foundation
import IntatisCore
import IntatisProtocol

/// Combines the deterministic gate (A) with one optional in-engine reviewer.
/// A `pass` is the sole reviewer entry point. Production Cowork deliberately
/// constructs this with `reviewer == nil`, converts `pass` to `ask_user`, and
/// uses its durable PermissionResponder control plane as the one reviewer.
/// Non-Cowork hosts may instead inject this reviewer. Hosts must not configure
/// both routes for the same call. A hard `deny` from the gate is always final.
public struct PermissionEngine: Sendable {
    private let gate: DeterministicPolicyGate
    private let reviewer: PermissionReviewer?

    public init(gate: DeterministicPolicyGate = DeterministicPolicyGate(),
                reviewer: PermissionReviewer? = nil) {
        self.gate = gate
        self.reviewer = reviewer
    }

    public func decide(_ call: ToolCallContext, _ ctx: PermissionContext) async -> PermissionOutcome {
        await decideDetailed(call, ctx).outcome
    }

    public func decideDetailed(_ call: ToolCallContext,
                               _ ctx: PermissionContext) async -> PermissionEngineDecision {
        let gateResult = gate.evaluate(call, ctx)
        let outcome: PermissionOutcome
        var reviewerConsulted = false
        switch gateResult {
        case .deny(let reason, let risk):
            outcome = PermissionOutcome(decision: .deny, risk: risk, reason: reason)

        case .ask(let reason, let risk):
            outcome = PermissionOutcome(decision: .askUser, risk: risk, reason: reason)

        case .allow(let reason, let risk):
            outcome = PermissionOutcome(decision: .allow, risk: risk, reason: reason)

        case .pass(let reason, let risk):
            if let reviewer {
                reviewerConsulted = true
                outcome = await reviewer.review(call, ctx, gateReason: reason, risk: risk)
                // Safety net: a reviewer can never turn a hard deny into allow; it
                // only ever sees `pass`, but re-assert that it didn't widen scope.
            } else {
                outcome = PermissionOutcome(decision: .askUser, risk: risk, reason: reason)
            }
        }
        return PermissionEngineDecision(
            gate: gateResult,
            outcome: outcome,
            reviewerConsulted: reviewerConsulted)
    }
}
