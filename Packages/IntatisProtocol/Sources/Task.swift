import Foundation
import IntatisCore

public enum TaskKind: String, Codable, Sendable, Hashable {
    case root
    case agentInvocation = "agent_invocation"
    case mailboxDelivery = "mailbox_delivery"
    /// Synthetic control-plane contract used to audit an agent/workspace
    /// admission without scheduling it on the ordinary task data plane.
    case agentAdmission = "agent_admission"
}

public enum TaskStatus: String, Codable, Sendable, Hashable {
    case created
    case assigned
    case queued
    case running
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .created, .assigned, .queued, .running:
            return false
        }
    }

    /// The durable task state machine. A terminal task can only re-enter the
    /// queue through an explicit retry attempt; arbitrary projection rewrites
    /// are intentionally rejected by `TaskGraph.transition`.
    public func canTransition(to next: TaskStatus, isRetry: Bool = false) -> Bool {
        if self == next { return true }
        switch (self, next) {
        case (.created, .assigned),
             (.created, .queued),
             (.created, .cancelled),
             (.assigned, .queued),
             (.assigned, .cancelled),
             (.queued, .running),
             (.queued, .cancelled),
             (.running, .completed),
             (.running, .failed),
             (.running, .cancelled):
            return true
        case (.failed, .queued), (.cancelled, .queued):
            return isRetry
        default:
            return false
        }
    }
}

/// How a scheduled invocation is returned to its issuer. Optional on
/// `TaskContract` so logs written before this field existed remain decodable.
public enum TaskReplyMode: String, Codable, Sendable, Hashable {
    case none
    case answer
    case taskReport = "task_report"
}

public struct TaskContract: Codable, Sendable, Hashable {
    public var id: TaskID
    public var kind: TaskKind
    public var issuer: AgentID?
    public var assignee: AgentID
    public var parentTaskID: TaskID?
    /// Optional durable planning scope. Nil for legacy and unscoped invocations.
    public var workTaskID: WorkTaskID?
    public var continuationRunID: ContinuationRunID?
    public var goalID: GoalID?
    /// Stable user-submission identity for a root invocation admitted through
    /// the durable submitted-intent path. Optional for legacy and internally
    /// generated tasks.
    public var submissionID: SubmissionID?

    public var objective: String
    public var roleHint: String
    public var expectedDeliverable: String

    public var workspaceID: WorkspaceID?
    public var workspaceLeaseID: WorkspaceLeaseID?
    public var capabilityLeaseID: CapabilityLeaseID?
    /// Exact inference identity frozen when this invocation is admitted. It is
    /// optional only so task contracts written before per-agent inference
    /// bindings remain decodable; new Cowork invocations should always set it.
    public var agentInferenceBinding: AgentInferenceBinding?
    public var relatedAgents: [AgentID]
    public var relatedTasks: [TaskID]
    /// Exact durable mailbox items owned by this delivery invocation. Nil is
    /// reserved for legacy and non-mailbox contracts so existing JSONL stays
    /// decodable. New mailbox tasks freeze a bounded non-empty set at
    /// admission and never widen it while queued or retried.
    public var mailboxMessageIDs: [MessageID]?
    public var constraints: [String]
    public var replyMode: TaskReplyMode?
    public var executionTimeoutSeconds: Double?
    public var maxAttempts: Int?

    public init(id: TaskID = TaskID.new(),
                kind: TaskKind = .agentInvocation,
                issuer: AgentID?,
                assignee: AgentID,
                parentTaskID: TaskID? = nil,
                workTaskID: WorkTaskID? = nil,
                continuationRunID: ContinuationRunID? = nil,
                goalID: GoalID? = nil,
                submissionID: SubmissionID? = nil,
                objective: String,
                roleHint: String,
                expectedDeliverable: String,
                workspaceID: WorkspaceID? = nil,
                workspaceLeaseID: WorkspaceLeaseID? = nil,
                capabilityLeaseID: CapabilityLeaseID? = nil,
                agentInferenceBinding: AgentInferenceBinding? = nil,
                relatedAgents: [AgentID] = [],
                relatedTasks: [TaskID] = [],
                mailboxMessageIDs: [MessageID]? = nil,
                constraints: [String] = [],
                replyMode: TaskReplyMode? = nil,
                executionTimeoutSeconds: Double? = nil,
                maxAttempts: Int? = nil) {
        self.id = id
        self.kind = kind
        self.issuer = issuer
        self.assignee = assignee
        self.parentTaskID = parentTaskID
        self.workTaskID = workTaskID
        self.continuationRunID = continuationRunID
        self.goalID = goalID
        self.submissionID = submissionID
        self.objective = objective
        self.roleHint = roleHint
        self.expectedDeliverable = expectedDeliverable
        self.workspaceID = workspaceID
        self.workspaceLeaseID = workspaceLeaseID
        self.capabilityLeaseID = capabilityLeaseID
        self.agentInferenceBinding = agentInferenceBinding
        self.relatedAgents = relatedAgents
        self.relatedTasks = relatedTasks
        self.mailboxMessageIDs = mailboxMessageIDs
        self.constraints = constraints
        self.replyMode = replyMode
        self.executionTimeoutSeconds = executionTimeoutSeconds
        self.maxAttempts = maxAttempts
    }
}
