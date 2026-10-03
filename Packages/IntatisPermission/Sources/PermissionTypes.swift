import Foundation
import IntatisCore
import IntatisProtocol

/// Per-agent permission mode (ARCHITECTURE.md §6.4). Default is `.reviewed`;
/// hard DENY rules always win regardless of mode.
public enum PermissionProfile: String, Codable, Sendable {
    case manual
    case reviewed
    case autopilot
    case readOnly = "read_only"
    case locked
}

/// Neutral description of a proposed tool call — built by the kernel from the
/// `Tool` + args, so Permission never imports Tools (ARCHITECTURE.md §3.8).
public struct ToolCallContext: Sendable {
    public let toolName: String
    public let sideEffect: SideEffect
    public let touchedPaths: [String]
    public let risksNetwork: Bool
    public let rawArgs: String   // JSON arguments
    public let intent: PermissionIntent

    public init(toolName: String, sideEffect: SideEffect, touchedPaths: [String],
                risksNetwork: Bool, rawArgs: String,
                intent: PermissionIntent? = nil) {
        self.toolName = toolName
        self.sideEffect = sideEffect
        self.touchedPaths = touchedPaths
        self.risksNetwork = risksNetwork
        self.rawArgs = rawArgs
        self.intent = intent ?? .derived(
            toolName: toolName,
            sideEffect: sideEffect,
            touchedPaths: touchedPaths,
            risksNetwork: risksNetwork)
    }
}

/// Situational context for a decision.
public struct PermissionContext: Sendable {
    public let workspaceRoot: URL
    public let profile: PermissionProfile
    /// From `PlatformProfile.allowsShell` — false in the App Store sandbox build.
    public let allowsShell: Bool
    public let userGoal: String?
    public let agent: AgentID?

    public init(workspaceRoot: URL, profile: PermissionProfile, allowsShell: Bool,
                userGoal: String? = nil, agent: AgentID? = nil) {
        self.workspaceRoot = workspaceRoot
        self.profile = profile
        self.allowsShell = allowsShell
        self.userGoal = userGoal
        self.agent = agent
    }
}

/// Result of the deterministic gate (layer A).
/// - `deny` is final and can never be overridden by a reviewer.
/// - `allow` is explicitly safe (skip reviewer).
/// - `ask` must go to the active `PermissionResponder` (automatic reviewer
///   first in Cowork, then user fallback).
/// - `pass` means "gate has no objection" → reviewer (v0.3) or, with no reviewer
///   configured, the engine degrades it to `ask`.
public enum GateResult: Equatable, Sendable {
    case deny(reason: String, risk: RiskLevel)
    case ask(reason: String, risk: RiskLevel)
    case allow(reason: String, risk: RiskLevel)
    case pass(reason: String, risk: RiskLevel)
}

/// Final decision the kernel acts on.
public struct PermissionOutcome: Equatable, Sendable {
    public let decision: PermissionDecision   // allow / deny / askUser
    public let risk: RiskLevel
    public let reason: String
    public init(decision: PermissionDecision, risk: RiskLevel, reason: String) {
        self.decision = decision
        self.risk = risk
        self.reason = reason
    }
}

/// Preserves the exact layer-A result even when PermissionEngine adapts `pass`
/// to an in-engine reviewer verdict or to `ask_user` for a durable responder.
public struct PermissionEngineDecision: Equatable, Sendable {
    public let gate: GateResult
    public let outcome: PermissionOutcome
    /// `true` only when the in-engine model reviewer actually inspected this
    /// call. Downstream policy overlays may add an interaction after an allow,
    /// but must never reinterpret or bypass a reviewer deny/ask.
    public let reviewerConsulted: Bool

    public init(gate: GateResult,
                outcome: PermissionOutcome,
                reviewerConsulted: Bool = false) {
        self.gate = gate
        self.outcome = outcome
        self.reviewerConsulted = reviewerConsulted
    }
}

/// Layer B (v0.3). Only ever consulted for gate `pass` results; can narrow to
/// deny/ask but can never override a hard deny.
public protocol PermissionReviewer: Sendable {
    func review(_ call: ToolCallContext, _ context: PermissionContext,
                gateReason: String, risk: RiskLevel) async -> PermissionOutcome
}
