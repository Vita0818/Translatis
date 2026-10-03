import Foundation
import IntatisCore
import IntatisPermission

/// Outcome of mediating one agent-to-agent message.
public enum ForwardingDecision: Equatable, Sendable {
    case forward(String)            // possibly redacted/summarized content
    case block(reason: String)
}

/// Optional model-backed forwarding reviewer (analogous to the permission
/// reviewer). v0.3 ships the deterministic `Mediator`; a model reviewer can be
/// injected later for the "summary vs raw source dump" judgement.
public protocol ForwardingReviewer: Sendable {
    func review(from: AgentID, to: AgentID, content: String) async -> ForwardingDecision
}

/// Governs what may cross between agents (ARCHITECTURE.md §6.5). Deterministic
/// hard rules first (secrets blocked, oversized raw dumps blocked), then an
/// optional reviewer. Default behavior forwards summaries, never raw file bytes.
public struct Mediator: Sendable {
    private let maxChars: Int
    private let reviewer: ForwardingReviewer?

    public init(maxChars: Int = 4000, reviewer: ForwardingReviewer? = nil) {
        self.maxChars = maxChars
        self.reviewer = reviewer
    }

    public func mediate(from: AgentID, to: AgentID, content: String) async -> ForwardingDecision {
        // 1. Hard rule: never forward secret-bearing content.
        if SecretScanner.containsSecret(content) {
            return .block(reason: "content appears to contain secrets")
        }
        // 2. Hard rule: block oversized raw dumps — force a summary.
        if content.count > maxChars {
            return .block(reason: "content too large to forward (\(content.count) chars); send a summary instead")
        }
        // 3. Contextual judgement, if a reviewer is configured.
        if let reviewer {
            return await reviewer.review(from: from, to: to, content: content)
        }
        return .forward(content)
    }
}
