import Foundation
import IntatisCore

/// Recovery contract for a tool execution that was prepared durably before the
/// executor was invoked. Only explicitly replay-safe observations may be run
/// again automatically after an interrupted attempt.
public enum ToolExecutionReplayPolicy: String, Codable, Equatable, Sendable {
    case safeToReplay = "safe_to_replay"
    case doNotReplay = "do_not_replay"

    public static func conservative(for sideEffect: SideEffect,
                                    tool: String) -> ToolExecutionReplayPolicy {
        guard sideEffect == .readOnly,
              !nonReplayableToolNames.contains(tool) else {
            return .doNotReplay
        }
        return .safeToReplay
    }

    private static let nonReplayableToolNames: Set<String> = [
        "ask_agent",
        "send_message",
        "request_information",
        "reply_message",
        "delegate_task",
        "spawn_agent",
        "remove_agent",
        "finish_run",
        "stop_run",
    ]
}

public enum ToolExecutionOutcome: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
    case denied
}

/// Whether the declared side effect crossed its durable mutation boundary.
/// Missing values come from legacy events. A legacy success still proves the
/// call completed (and remains non-replayable); missing disposition on every
/// failed, cancelled, or denied outcome must be treated as unknown.
public enum ToolExecutionEffectDisposition: String, Codable, Equatable, Sendable {
    /// The executor may have been entered, but the declared side effect is
    /// proven not to have started.
    case notStarted = "not_started"
    /// The declared side effect is known to have committed.
    case committed
    /// The executor outcome cannot prove whether the side effect occurred.
    case unknown
}

/// Written immediately before invoking a tool executor. A prepared event with
/// no matching settled event is evidence that a crash may have interrupted an
/// execution. Callers must consult `replayPolicy` before retrying the task.
public struct ToolExecutionPreparedPayload: Codable, Equatable, Sendable {
    public var executionID: String
    public var taskID: TaskID?
    public var attempt: Int?
    public var toolCallID: String
    public var agent: AgentID?
    public var tool: String
    public var sideEffect: SideEffect
    public var intent: PermissionIntent?
    public var authorization: ResolvedToolAuthorization?
    public var replayPolicy: ToolExecutionReplayPolicy

    public init(executionID: String,
                taskID: TaskID? = nil,
                attempt: Int? = nil,
                toolCallID: String,
                agent: AgentID? = nil,
                tool: String,
                sideEffect: SideEffect,
                intent: PermissionIntent? = nil,
                authorization: ResolvedToolAuthorization? = nil,
                replayPolicy: ToolExecutionReplayPolicy? = nil) {
        self.executionID = executionID
        self.taskID = taskID
        self.attempt = attempt
        self.toolCallID = toolCallID
        self.agent = agent
        self.tool = tool
        self.sideEffect = sideEffect
        self.intent = intent
        self.authorization = authorization
        self.replayPolicy = replayPolicy ?? .conservative(for: sideEffect, tool: tool)
    }

    /// A durable prepare record is the point after which the executor may have
    /// run. Replaying the *whole task* would therefore repeat this call even
    /// when a later settled record proves that the call succeeded. Only tools
    /// explicitly classified as safe-to-replay may be crossed by task replay.
    public var blocksTaskReplay: Bool {
        replayPolicy == .doNotReplay
    }
}

/// Written after the tool result has been made durable. Metadata is repeated so
/// a replay remains diagnosable even if a damaged log is missing the prepare
/// record; normal logs still pair records by `executionID`.
public struct ToolExecutionSettledPayload: Codable, Equatable, Sendable {
    public var executionID: String
    public var taskID: TaskID?
    public var attempt: Int?
    public var toolCallID: String
    public var agent: AgentID?
    public var tool: String
    public var sideEffect: SideEffect
    public var intent: PermissionIntent?
    public var authorization: ResolvedToolAuthorization?
    public var replayPolicy: ToolExecutionReplayPolicy
    public var outcome: ToolExecutionOutcome
    public var effectDisposition: ToolExecutionEffectDisposition?
    public var reason: String?

    public init(executionID: String,
                taskID: TaskID? = nil,
                attempt: Int? = nil,
                toolCallID: String,
                agent: AgentID? = nil,
                tool: String,
                sideEffect: SideEffect,
                intent: PermissionIntent? = nil,
                authorization: ResolvedToolAuthorization? = nil,
                replayPolicy: ToolExecutionReplayPolicy? = nil,
                outcome: ToolExecutionOutcome,
                effectDisposition: ToolExecutionEffectDisposition? = nil,
                reason: String? = nil) {
        self.executionID = executionID
        self.taskID = taskID
        self.attempt = attempt
        self.toolCallID = toolCallID
        self.agent = agent
        self.tool = tool
        self.sideEffect = sideEffect
        self.intent = intent
        self.authorization = authorization
        self.replayPolicy = replayPolicy ?? .conservative(for: sideEffect, tool: tool)
        self.outcome = outcome
        self.effectDisposition = effectDisposition
        self.reason = reason
    }

    public init(prepared: ToolExecutionPreparedPayload,
                outcome: ToolExecutionOutcome,
                effectDisposition: ToolExecutionEffectDisposition? = nil,
                reason: String? = nil) {
        self.init(
            executionID: prepared.executionID,
            taskID: prepared.taskID,
            attempt: prepared.attempt,
            toolCallID: prepared.toolCallID,
            agent: prepared.agent,
            tool: prepared.tool,
            sideEffect: prepared.sideEffect,
            intent: prepared.intent,
            authorization: prepared.authorization,
            replayPolicy: prepared.replayPolicy,
            outcome: outcome,
            effectDisposition: effectDisposition,
            reason: reason)
    }

    public var prepared: ToolExecutionPreparedPayload {
        ToolExecutionPreparedPayload(
            executionID: executionID,
            taskID: taskID,
            attempt: attempt,
            toolCallID: toolCallID,
            agent: agent,
            tool: tool,
            sideEffect: sideEffect,
            intent: intent,
            authorization: authorization,
            replayPolicy: replayPolicy)
    }
}
