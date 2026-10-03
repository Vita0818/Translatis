import Foundation
import IntatisCore

// Event payloads for v0.3 (Cowork): multi-agent attach, agent messages,
// mediated agent-to-agent messages, and reviewer audit records.

public enum CoworkEventScope: String, Codable, Equatable, Sendable {
    case thread
    case task
    case agent
    case workspace
    case capability
}

public enum CoworkEventVisibility: String, Codable, Equatable, Sendable {
    case global
    case task
    case agent
    case privateAgent = "private_agent"
}

public struct CoworkEventMetadata: Codable, Equatable, Sendable {
    public var threadID: ThreadID?
    public var taskID: TaskID?
    public var rootTaskID: TaskID?
    public var parentTaskID: TaskID?
    public var sender: AgentID?
    public var recipient: AgentID?
    public var agentID: AgentID?
    public var issuer: AgentID?
    public var assignee: AgentID?
    public var workspaceID: WorkspaceID?
    public var workspaceLeaseID: WorkspaceLeaseID?
    public var capabilityLeaseID: CapabilityLeaseID?
    public var causalParentID: TaskID?
    public var scope: CoworkEventScope
    public var visibility: CoworkEventVisibility
    public var createdAt: Date

    public init(threadID: ThreadID? = nil,
                taskID: TaskID? = nil,
                rootTaskID: TaskID? = nil,
                parentTaskID: TaskID? = nil,
                sender: AgentID? = nil,
                recipient: AgentID? = nil,
                agentID: AgentID? = nil,
                issuer: AgentID? = nil,
                assignee: AgentID? = nil,
                workspaceID: WorkspaceID? = nil,
                workspaceLeaseID: WorkspaceLeaseID? = nil,
                capabilityLeaseID: CapabilityLeaseID? = nil,
                causalParentID: TaskID? = nil,
                scope: CoworkEventScope = .thread,
                visibility: CoworkEventVisibility = .global,
                createdAt: Date = Date()) {
        self.threadID = threadID
        self.taskID = taskID
        self.rootTaskID = rootTaskID
        self.parentTaskID = parentTaskID
        self.sender = sender
        self.recipient = recipient
        self.agentID = agentID
        self.issuer = issuer
        self.assignee = assignee
        self.workspaceID = workspaceID
        self.workspaceLeaseID = workspaceLeaseID
        self.capabilityLeaseID = capabilityLeaseID
        self.causalParentID = causalParentID
        self.scope = scope
        self.visibility = visibility
        self.createdAt = createdAt
    }
}

public struct AgentAttachRequestedPayload: Codable, Equatable, Sendable {
    public var agent: AgentID
    public var path: String
    public var model: ModelID
    public var profile: String
    /// Exact inference identity proposed for this admission. Nil identifies a
    /// legacy request that predates per-agent inference bindings.
    public var agentInferenceBinding: AgentInferenceBinding?
    public var metadata: CoworkEventMetadata?

    public init(agent: AgentID,
                path: String,
                model: ModelID,
                profile: String,
                agentInferenceBinding: AgentInferenceBinding? = nil,
                metadata: CoworkEventMetadata? = nil) {
        self.agent = agent
        self.path = path
        self.model = model
        self.profile = profile
        self.agentInferenceBinding = agentInferenceBinding
        self.metadata = metadata
    }
}

public struct AgentAttachedPayload: Codable, Equatable, Sendable {
    public var agent: AgentID
    public var path: String
    public var model: ModelID
    public var profile: String
    /// Durable inference identity of the admitted agent. Nil is preserved as a
    /// legacy/unresolved fact rather than being replaced by a current default.
    public var agentInferenceBinding: AgentInferenceBinding?
    /// Present only when this roster snapshot durably settles a host rebind.
    /// Keeping both identities in the same additive event makes replay and
    /// audit explicit without exposing any profile definition or secret.
    public var previousAgentInferenceBinding: AgentInferenceBinding?
    public var inferenceBindingChangeReason: String?
    public var metadata: CoworkEventMetadata?
    public init(agent: AgentID, path: String, model: ModelID, profile: String,
                agentInferenceBinding: AgentInferenceBinding? = nil,
                previousAgentInferenceBinding: AgentInferenceBinding? = nil,
                inferenceBindingChangeReason: String? = nil,
                metadata: CoworkEventMetadata? = nil) {
        self.agent = agent
        self.path = path
        self.model = model
        self.profile = profile
        self.agentInferenceBinding = agentInferenceBinding
        self.previousAgentInferenceBinding = previousAgentInferenceBinding
        self.inferenceBindingChangeReason = inferenceBindingChangeReason
        self.metadata = metadata
    }
}

public struct AgentDetachedPayload: Codable, Equatable, Sendable {
    public var agent: AgentID
    public var reason: String?
    public var metadata: CoworkEventMetadata?
    public init(agent: AgentID, reason: String? = nil, metadata: CoworkEventMetadata? = nil) {
        self.agent = agent
        self.reason = reason
        self.metadata = metadata
    }
}

public struct AgentSpawnRequestedPayload: Codable, Equatable, Sendable {
    public var requestedBy: AgentID?
    public var agent: AgentID
    public var path: String
    public var model: ModelID?
    public var agentInferenceBinding: AgentInferenceBinding?
    public var metadata: CoworkEventMetadata?

    public init(requestedBy: AgentID? = nil,
                agent: AgentID,
                path: String,
                model: ModelID? = nil,
                agentInferenceBinding: AgentInferenceBinding? = nil,
                metadata: CoworkEventMetadata? = nil) {
        self.requestedBy = requestedBy
        self.agent = agent
        self.path = path
        self.model = model
        self.agentInferenceBinding = agentInferenceBinding
        self.metadata = metadata
    }
}

public struct AgentSpawnedPayload: Codable, Equatable, Sendable {
    public var requestedBy: AgentID?
    public var agent: AgentID
    public var path: String
    public var model: ModelID
    public var agentInferenceBinding: AgentInferenceBinding?
    public var metadata: CoworkEventMetadata?

    public init(requestedBy: AgentID? = nil,
                agent: AgentID,
                path: String,
                model: ModelID,
                agentInferenceBinding: AgentInferenceBinding? = nil,
                metadata: CoworkEventMetadata? = nil) {
        self.requestedBy = requestedBy
        self.agent = agent
        self.path = path
        self.model = model
        self.agentInferenceBinding = agentInferenceBinding
        self.metadata = metadata
    }
}

public struct AgentMessagePayload: Codable, Equatable, Sendable {
    public var agent: AgentID
    public var messageId: MessageID
    public var content: String
    public var from: AgentID?
    public var to: AgentID?
    public var kind: AgentCommunicationKind?
    public var taskID: TaskID?
    public var inReplyTo: MessageID?
    public var mediated: Bool?
    public var metadata: CoworkEventMetadata?
    public init(agent: AgentID, messageId: MessageID, content: String) {
        self.agent = agent
        self.messageId = messageId
        self.content = content
        self.from = nil
        self.to = nil
        self.kind = nil
        self.taskID = nil
        self.inReplyTo = nil
        self.mediated = nil
        self.metadata = nil
    }
    public init(from: AgentID,
                to: AgentID,
                content: String,
                kind: AgentCommunicationKind,
                messageId: MessageID = MessageID.new(),
                taskID: TaskID? = nil,
                inReplyTo: MessageID? = nil,
                mediated: Bool = true,
                metadata: CoworkEventMetadata? = nil) {
        self.agent = from
        self.messageId = messageId
        self.content = content
        self.from = from
        self.to = to
        self.kind = kind
        self.taskID = taskID
        self.inReplyTo = inReplyTo
        self.mediated = mediated
        self.metadata = metadata
    }
}

public enum AgentCommunicationKind: String, Codable, Sendable {
    case sendMessage = "send_message"
    case requestInformation = "request_information"
    case replyMessage = "reply_message"
}

public struct InformationRequestedPayload: Codable, Equatable, Sendable {
    public var requestID: MessageID
    /// Stable conversation root. The first request normally uses its own ID;
    /// every explicit follow-up retains that root while receiving a fresh
    /// requestID.
    public var conversationID: MessageID?
    /// Message that prompted this new request correlation. Nil starts a new
    /// conversation; a follow-up after a reply points at that reply ID.
    public var basedOn: MessageID?
    public var from: AgentID
    public var to: AgentID
    public var question: String
    public var mediated: Bool
    public var taskID: TaskID?
    public var metadata: CoworkEventMetadata?

    public init(requestID: MessageID = MessageID.new(),
                conversationID: MessageID? = nil,
                basedOn: MessageID? = nil,
                from: AgentID,
                to: AgentID,
                question: String,
                mediated: Bool,
                taskID: TaskID? = nil,
                metadata: CoworkEventMetadata? = nil) {
        self.requestID = requestID
        self.conversationID = conversationID
        self.basedOn = basedOn
        self.from = from
        self.to = to
        self.question = question
        self.mediated = mediated
        self.taskID = taskID
        self.metadata = metadata
    }
}

public struct InformationRepliedPayload: Codable, Equatable, Sendable {
    public var replyID: MessageID
    public var inReplyTo: MessageID?
    public var conversationID: MessageID?
    public var from: AgentID
    public var to: AgentID
    public var content: String
    public var mediated: Bool
    public var taskID: TaskID?
    public var metadata: CoworkEventMetadata?

    public init(replyID: MessageID = MessageID.new(),
                inReplyTo: MessageID? = nil,
                conversationID: MessageID? = nil,
                from: AgentID,
                to: AgentID,
                content: String,
                mediated: Bool,
                taskID: TaskID? = nil,
                metadata: CoworkEventMetadata? = nil) {
        self.replyID = replyID
        self.inReplyTo = inReplyTo
        self.conversationID = conversationID
        self.from = from
        self.to = to
        self.content = content
        self.mediated = mediated
        self.taskID = taskID
        self.metadata = metadata
    }
}

/// Durable acknowledgement that a mailbox item was projected into an agent
/// invocation. The original message remains append-only; replay removes only
/// its pending marker.
public struct AgentMessageConsumedPayload: Codable, Equatable, Sendable {
    public var messageID: MessageID
    public var agent: AgentID
    public var taskID: TaskID?
    public var metadata: CoworkEventMetadata?

    public init(messageID: MessageID,
                agent: AgentID,
                taskID: TaskID? = nil,
                metadata: CoworkEventMetadata? = nil) {
        self.messageID = messageID
        self.agent = agent
        self.taskID = taskID
        self.metadata = metadata
    }
}

/// Durable cancellation settlement for a mailbox item that must never be
/// presented after its owning Goal/run has stopped. This is distinct from
/// `agent_message_consumed`, which is reserved for messages actually projected
/// into a successfully completed agent invocation.
public struct AgentMessageDiscardedPayload: Codable, Equatable, Sendable {
    public var messageID: MessageID
    public var agent: AgentID
    public var reason: String
    public var taskID: TaskID?
    public var goalID: GoalID?
    public var continuationRunID: ContinuationRunID?
    public var metadata: CoworkEventMetadata?

    public init(messageID: MessageID,
                agent: AgentID,
                reason: String,
                taskID: TaskID? = nil,
                goalID: GoalID? = nil,
                continuationRunID: ContinuationRunID? = nil,
                metadata: CoworkEventMetadata? = nil) {
        self.messageID = messageID
        self.agent = agent
        self.reason = reason
        self.taskID = taskID
        self.goalID = goalID
        self.continuationRunID = continuationRunID
        self.metadata = metadata
    }
}

public struct DelegationApprovedPayload: Codable, Equatable, Sendable {
    public var contract: TaskContract
    public var reason: String
    public var metadata: CoworkEventMetadata?

    public init(contract: TaskContract,
                reason: String = "delegation approved",
                metadata: CoworkEventMetadata? = nil) {
        self.contract = contract
        self.reason = reason
        self.metadata = metadata
    }
}

public struct DelegationRejectedPayload: Codable, Equatable, Sendable {
    public var requester: AgentID
    public var assignee: AgentID?
    public var objective: String
    public var reason: String
    public var violationKind: String?
    public var metadata: CoworkEventMetadata?

    public init(requester: AgentID,
                assignee: AgentID? = nil,
                objective: String,
                reason: String,
                violationKind: String? = nil,
                metadata: CoworkEventMetadata? = nil) {
        self.requester = requester
        self.assignee = assignee
        self.objective = objective
        self.reason = reason
        self.violationKind = violationKind
        self.metadata = metadata
    }
}

public struct TaskDelegatedPayload: Codable, Equatable, Sendable {
    public var contract: TaskContract
    public var issuer: AgentID?
    public var assignee: AgentID
    public var metadata: CoworkEventMetadata?

    public init(contract: TaskContract, metadata: CoworkEventMetadata? = nil) {
        self.contract = contract
        self.issuer = contract.issuer
        self.assignee = contract.assignee
        self.metadata = metadata
    }
}

public struct WorkspaceLeaseRequestedPayload: Codable, Equatable, Sendable {
    public var agent: AgentID?
    public var workspaceID: WorkspaceID?
    public var workspaceLeaseID: WorkspaceLeaseID?
    public var rootPath: String
    public var access: WorkspaceAccess
    public var reason: String
    public var metadata: CoworkEventMetadata?

    public init(agent: AgentID? = nil,
                workspaceID: WorkspaceID? = nil,
                workspaceLeaseID: WorkspaceLeaseID? = nil,
                rootPath: String,
                access: WorkspaceAccess,
                reason: String,
                metadata: CoworkEventMetadata? = nil) {
        self.agent = agent
        self.workspaceID = workspaceID
        self.workspaceLeaseID = workspaceLeaseID
        self.rootPath = rootPath
        self.access = access
        self.reason = reason
        self.metadata = metadata
    }
}

public struct WorkspaceLeaseGrantedPayload: Codable, Equatable, Sendable {
    public var agent: AgentID?
    public var lease: WorkspaceLease
    public var metadata: CoworkEventMetadata?

    public init(agent: AgentID? = nil,
                lease: WorkspaceLease,
                metadata: CoworkEventMetadata? = nil) {
        self.agent = agent
        self.lease = lease
        self.metadata = metadata
    }
}

public struct WorkspaceLeaseDeniedPayload: Codable, Equatable, Sendable {
    public var agent: AgentID?
    public var workspaceID: WorkspaceID?
    public var workspaceLeaseID: WorkspaceLeaseID?
    public var rootPath: String
    public var reason: String
    public var metadata: CoworkEventMetadata?

    public init(agent: AgentID? = nil,
                workspaceID: WorkspaceID? = nil,
                workspaceLeaseID: WorkspaceLeaseID? = nil,
                rootPath: String,
                reason: String,
                metadata: CoworkEventMetadata? = nil) {
        self.agent = agent
        self.workspaceID = workspaceID
        self.workspaceLeaseID = workspaceLeaseID
        self.rootPath = rootPath
        self.reason = reason
        self.metadata = metadata
    }
}

public struct WorkspaceLeaseRevokedPayload: Codable, Equatable, Sendable {
    public var agent: AgentID?
    public var leaseID: WorkspaceLeaseID
    public var reason: String
    public var metadata: CoworkEventMetadata?

    public init(agent: AgentID? = nil,
                leaseID: WorkspaceLeaseID,
                reason: String,
                metadata: CoworkEventMetadata? = nil) {
        self.agent = agent
        self.leaseID = leaseID
        self.reason = reason
        self.metadata = metadata
    }
}

public struct CapabilityLeaseCreatedPayload: Codable, Equatable, Sendable {
    public var agent: AgentID?
    public var lease: CapabilityLease
    public var metadata: CoworkEventMetadata?

    public init(agent: AgentID? = nil,
                lease: CapabilityLease,
                metadata: CoworkEventMetadata? = nil) {
        self.agent = agent
        self.lease = lease
        self.metadata = metadata
    }
}

public struct CapabilityLeaseRevokedPayload: Codable, Equatable, Sendable {
    public var agent: AgentID?
    public var leaseID: CapabilityLeaseID
    public var reason: String
    public var metadata: CoworkEventMetadata?

    public init(agent: AgentID? = nil,
                leaseID: CapabilityLeaseID,
                reason: String,
                metadata: CoworkEventMetadata? = nil) {
        self.agent = agent
        self.leaseID = leaseID
        self.reason = reason
        self.metadata = metadata
    }
}

/// A message routed between two agents. Always mediated through the Message Bus
/// and always logged (ARCHITECTURE.md §7, §6.5). `content` is the post-mediation
/// (redacted/summarized) text — raw file bytes never appear here.
public struct AgentToAgentMessagePayload: Codable, Equatable, Sendable {
    public var from: AgentID
    public var to: AgentID
    public var content: String
    public var mediated: Bool
    public init(from: AgentID, to: AgentID, content: String, mediated: Bool) {
        self.from = from
        self.to = to
        self.content = content
        self.mediated = mediated
    }
}

/// Audit record of an automatic permission decision or mediated agent exchange.
public struct PermissionReviewPayload: Codable, Equatable, Sendable {
    public var agent: AgentID?
    public var tool: String
    public var reviewerModel: String
    public var decision: PermissionDecision
    public var risk: RiskLevel
    public var reason: String
    public init(agent: AgentID? = nil, tool: String, reviewerModel: String,
                decision: PermissionDecision, risk: RiskLevel, reason: String) {
        self.agent = agent
        self.tool = tool
        self.reviewerModel = reviewerModel
        self.decision = decision
        self.risk = risk
        self.reason = reason
    }
}
