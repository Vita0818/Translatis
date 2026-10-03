import Foundation
import IntatisCore

/// Per-turn statistics emitted after the model finishes a reply: token usage
/// (when the endpoint reports it), time-to-first-token, and total wall time.
/// `promptTokens` doubles as the context-window occupancy for the turn.
public struct TurnStatsPayload: Codable, Equatable, Sendable {
    public var promptTokens: Int?
    public var cachedPromptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    public var contextWindowTokens: Int?
    public var ttftMillis: Int?
    public var totalMillis: Int?
    public var model: String?
    /// Stable turn identity and the final visible reply produced by that turn.
    /// Both fields are additive so legacy statistics remain decodable. A nil
    /// response identity means the statistics are not safe to attach to a
    /// transcript row (for example, a control-plane-only request).
    public var turnID: TurnID?
    public var responseMessageID: MessageID?
    /// Optional durable execution scope. These identifiers are additive so old
    /// turn_stats events remain decodable and ordinary Chat/Code turns may
    /// continue to omit Cowork-only layers.
    public var goalID: GoalID?
    public var continuationRunID: ContinuationRunID?
    public var workTaskID: WorkTaskID?
    public var invocationTaskID: TaskID?
    public var agentID: AgentID?
    /// Secret-free exact inference identity for per-profile usage, latency, and
    /// failure attribution. Nil keeps legacy Chat/Code/Cowork events decodable.
    public var agentInferenceBinding: AgentInferenceBinding?
    public init(promptTokens: Int? = nil,
                cachedPromptTokens: Int? = nil,
                completionTokens: Int? = nil,
                totalTokens: Int? = nil,
                contextWindowTokens: Int? = nil,
                ttftMillis: Int? = nil,
                totalMillis: Int? = nil,
                model: String? = nil,
                turnID: TurnID? = nil,
                responseMessageID: MessageID? = nil,
                goalID: GoalID? = nil,
                continuationRunID: ContinuationRunID? = nil,
                workTaskID: WorkTaskID? = nil,
                invocationTaskID: TaskID? = nil,
                agentID: AgentID? = nil,
                agentInferenceBinding: AgentInferenceBinding? = nil) {
        self.promptTokens = promptTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.contextWindowTokens = contextWindowTokens
        self.ttftMillis = ttftMillis
        self.totalMillis = totalMillis
        self.model = model
        self.turnID = turnID
        self.responseMessageID = responseMessageID
        self.goalID = goalID
        self.continuationRunID = continuationRunID
        self.workTaskID = workTaskID
        self.invocationTaskID = invocationTaskID
        self.agentID = agentID
        self.agentInferenceBinding = agentInferenceBinding
    }
}
