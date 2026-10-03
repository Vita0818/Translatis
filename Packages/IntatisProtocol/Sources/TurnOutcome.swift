import Foundation
import IntatisCore

/// Stable identity of one model turn, independent from a durable Cowork task
/// or user submission. Legacy events predate this identity and therefore keep
/// their corresponding fields optional.
public struct TurnID: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func new() -> TurnID {
        TurnID(rawValue: IDGen.random(prefix: "turn"))
    }
}

/// Outward-facing classification shared by permission, tool-call, and turn
/// terminal records. This deliberately separates a user's explicit decline
/// from cancellation and keeps policy/reviewer/sandbox/runtime failures
/// machine-readable instead of requiring clients to parse diagnostic text.
public enum ExecutionFailureSource: String, Codable, Equatable, Sendable {
    case userDenied = "user_denied"
    case userCancelled = "user_cancelled"
    case turnCancelled = "turn_cancelled"
    case policyDenied = "policy_denied"
    case reviewerTimedOut = "reviewer_timed_out"
    case reviewerFailed = "reviewer_failed"
    case sandboxDenied = "sandbox_denied"
    case runtimeFailed = "runtime_failed"
}

/// Terminal outcome of one tool call when a `tool_result` is emitted.
/// Cancellation normally interrupts the enclosing turn without fabricating a
/// tool result, so it is represented by `TurnOutcome.interrupted` instead.
public enum ToolCallOutcome: String, Codable, Equatable, Sendable {
    case succeeded
    case denied
    case failed
}

/// Terminal outcome of one model turn.
public enum TurnOutcome: String, Codable, Equatable, Sendable {
    case completed
    case interrupted
    case failed
}

/// Exactly one terminal record should be written for a new turn. Correlation
/// fields other than `turnID` are optional so Chat, Code, and Cowork can share
/// the event without manufacturing identities that do not apply.
public struct TurnOutcomePayload: Codable, Equatable, Sendable {
    public var turnID: TurnID
    public var outcome: TurnOutcome
    public var failureSource: ExecutionFailureSource?
    /// Bounded, secret-scrubbed user-facing diagnostic. Writers own bounding
    /// and redaction before persistence.
    public var reason: String?
    public var submissionID: SubmissionID?
    public var taskID: TaskID?
    public var agentID: AgentID?

    public init(turnID: TurnID,
                outcome: TurnOutcome,
                failureSource: ExecutionFailureSource? = nil,
                reason: String? = nil,
                submissionID: SubmissionID? = nil,
                taskID: TaskID? = nil,
                agentID: AgentID? = nil) {
        self.turnID = turnID
        self.outcome = outcome
        self.failureSource = failureSource
        self.reason = reason
        self.submissionID = submissionID
        self.taskID = taskID
        self.agentID = agentID
    }
}
