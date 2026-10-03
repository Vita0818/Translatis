import Foundation
import IntatisCore

/// Exact, provider-agnostic `tokenUsage.last` values reported by the official
/// Codex App Server, paired with its turn duration when available.
///
/// The token fields preserve the App Server's native semantics. In
/// particular, `inputTokens` already includes cached input and must not be
/// reduced by `cachedInputTokens`. Context-window occupancy is intentionally
/// not represented here.
public struct ResponsesUsagePayload: Codable, Equatable, Sendable {
    public var turnID: TurnID
    public var responseMessageID: MessageID?
    public var agentID: AgentID?
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var cacheWriteInputTokens: Int
    public var outputTokens: Int
    public var reasoningOutputTokens: Int
    public var totalTokens: Int
    public var durationMs: Int?

    public init(
        turnID: TurnID,
        responseMessageID: MessageID? = nil,
        agentID: AgentID? = nil,
        inputTokens: Int,
        cachedInputTokens: Int,
        cacheWriteInputTokens: Int,
        outputTokens: Int,
        reasoningOutputTokens: Int,
        totalTokens: Int,
        durationMs: Int? = nil
    ) {
        self.turnID = turnID
        self.responseMessageID = responseMessageID
        self.agentID = agentID
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
        self.durationMs = durationMs
    }
}
