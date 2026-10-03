import Foundation
import IntatisCore
import IntatisProtocol

/// A message as the UI shows it — the result of folding events. Streaming deltas
/// accumulate into `text`; `isComplete` flips on `message_completed`.
public struct ChatMessageView: Identifiable, Equatable, Sendable {
    public let id: MessageID
    public var role: MessageRole
    public var agent: AgentID?
    public var text: String
    public var isComplete: Bool
    public var timestamp: Date?
    public var tags: [String]
    public var goal: String?
    public var recoveryAdvice: RuntimeRecoveryAdvice?
    public var citations: [MessageCitation]
    public var attachments: [ArtifactID]
    public var turnStats: TurnStatsSnapshot?

    public init(id: MessageID,
                role: MessageRole,
                agent: AgentID? = nil,
                text: String,
                isComplete: Bool,
                timestamp: Date? = nil,
                tags: [String] = [],
                goal: String? = nil,
                recoveryAdvice: RuntimeRecoveryAdvice? = nil,
                citations: [MessageCitation] = [],
                attachments: [ArtifactID] = [],
                turnStats: TurnStatsSnapshot? = nil) {
        self.id = id
        self.role = role
        self.agent = agent
        self.text = text
        self.isComplete = isComplete
        self.timestamp = timestamp
        self.tags = tags
        self.goal = goal
        self.recoveryAdvice = recoveryAdvice
        self.citations = citations
        self.attachments = attachments
        self.turnStats = turnStats
    }
}

/// Folds an event stream into renderable messages. The UI consumes *this*, never
/// raw model text (ARCHITECTURE.md §1.2 principle A / §3.11).
public struct ConversationProjection: Equatable, Sendable {
    private static let maximumPendingTurnStats = 64
    public private(set) var messages: [ChatMessageView] = []
    private var pendingTurnStatsByMessageID: [MessageID: TurnStatsSnapshot] = [:]

    public init() {}

    public mutating func apply(_ envelope: Envelope) {
        apply(
            envelope.event,
            timestamp: envelope.ts,
            turnStatsID: "\(envelope.session.rawValue):\(envelope.seq):turn_stats"
        ) { suffix in
            MessageID(rawValue: "msg_\(envelope.session.rawValue)_\(envelope.seq)_\(suffix)")
        }
    }

    public mutating func apply(_ event: Event) {
        apply(
            event,
            timestamp: nil,
            turnStatsID: "event:turn_stats"
        ) { _ in MessageID.new() }
    }

    private mutating func apply(_ event: Event,
                                timestamp: Date?,
                                turnStatsID: String,
                                syntheticID: (String) -> MessageID) {
        switch event {
        case .userMessage(let p):
            messages.append(ChatMessageView(id: syntheticID("user"),
                                            role: .user,
                                            text: p.text,
                                            isComplete: true,
                                            timestamp: timestamp,
                                            tags: p.tags ?? [],
                                            goal: p.goal,
                                            attachments: p.attachments ?? []))

        case .messageDelta(let p):
            if let i = messages.firstIndex(where: { $0.id == p.messageId }) {
                messages[i].text += p.textDelta
                if messages[i].timestamp == nil {
                    messages[i].timestamp = timestamp
                }
            } else {
                messages.append(ChatMessageView(id: p.messageId, role: p.role, agent: p.agent,
                                                text: p.textDelta, isComplete: false,
                                                timestamp: timestamp,
                                                turnStats: takePendingTurnStats(
                                                    for: p.messageId)))
            }

        case .messageCompleted(let p):
            if let i = messages.firstIndex(where: { $0.id == p.messageId }) {
                messages[i].text = p.text
                messages[i].isComplete = true
                messages[i].citations = p.citations ?? []
                if messages[i].timestamp == nil {
                    messages[i].timestamp = timestamp
                }
            } else {
                messages.append(ChatMessageView(id: p.messageId, role: p.role, agent: p.agent,
                                                text: p.text, isComplete: true,
                                                timestamp: timestamp,
                                                citations: p.citations ?? [],
                                                turnStats: takePendingTurnStats(
                                                    for: p.messageId)))
            }

        case .turnStats(let payload):
            applyTurnStats(TurnStatsSnapshot(
                id: turnStatsID,
                payload: payload))

        case .error(let p):
            markCurrentPartialMessageStopped(with: p)
            messages.append(ChatMessageView(id: syntheticID("error"), role: .system,
                                            text: "⚠️ \(p.message)", isComplete: true,
                                            timestamp: timestamp,
                                            recoveryAdvice: RuntimeErrorPresentation.recoveryAdvice(for: p)))

        case .artifactAdded(let p):
            messages.append(ChatMessageView(id: syntheticID("artifact"), role: .system,
                                            text: "📎 \(p.kind) artifact" + (p.prompt.map { ": \($0)" } ?? ""),
                                            isComplete: true,
                                            timestamp: timestamp))

        case .sessionSettingsUpdated, .sessionStorageMigrated, .submissionStatusChanged,
             .codexAppServerEvent,
             .modelHistoryItem, .modelHistoryCompacted,
             .toolCall, .toolResult, .toolExecutionPrepared, .toolExecutionSettled,
             .permissionRequest, .permissionResolved, .patchProposed, .agentStatus,
             .agentAttached, .agentAttachRequested, .agentDetached, .agentSpawnRequested, .agentSpawned,
             .agentMessage, .agentMessageConsumed, .agentMessageDiscarded,
             .agentToAgentMessage, .permissionReview,
             .permissionReviewRequested, .permissionReviewSettled,
             .informationRequested, .informationReplied,
             .delegationApproved, .delegationRejected, .taskDelegated,
             .workspaceLeaseRequested, .workspaceLeaseGranted, .workspaceLeaseDenied, .workspaceLeaseRevoked,
             .capabilityLeaseCreated, .capabilityLeaseRevoked,
             .taskCreated, .taskAssigned, .taskQueued, .taskStarted, .taskCompleted, .taskFailed, .taskCancelled, .taskRejected,
             .workTaskCreated, .workTaskUpdated, .workTaskDependencyChanged,
             .workTaskReady, .workTaskStarted, .workTaskProgressed, .workTaskBlocked,
             .workTaskCompleted, .workTaskFailed, .workTaskCancelled,
             .workTaskInvocationLinked, .workTaskEvidenceAdded,
             .goalCreated, .goalEdited, .goalPaused, .goalResumed, .goalAuditCompleted,
             .goalContinuationScheduled, .goalProgressed, .goalBlocked,
             .goalBudgetLimited, .goalUsageLimited, .goalCompleted, .goalCleared,
             .continuationRunCreated, .continuationRunStarted, .continuationRunCheckpointed,
             .continuationRunCloseRequested,
             .continuationRunCompleted, .continuationRunInterrupted, .continuationRunCancelled,
             .artifactProgress, .responsesUsage, .turnOutcome,
             .mcpServerAttached, .mcpServerDetached, .mcpAttachmentPolicyUpdated,
             .mcpConsentGranted, .mcpConsentRevoked,
             .mcpControlOperationRequested, .mcpControlOperationSettled,
             .mcpGrantGranted, .mcpGrantRevoked,
             .mcpRememberedApprovalGranted,
             .mcpRememberedApprovalRevoked,
             .mcpRootsPolicyUpdated, .mcpNetworkPolicyUpdated, .mcpPromptInserted,
             .mcpSamplingRequested, .mcpSamplingDecided, .mcpSamplingSettled,
             .mcpElicitationRequested, .mcpElicitationDecided, .mcpElicitationSettled,
             .mcpRemoteTaskRequested, .mcpRemoteTaskMapped,
             .mcpRemoteTaskStateChanged, .mcpRemoteTaskSettled,
             .mcpClientTaskRequested, .mcpClientTaskStateChanged, .mcpClientTaskSettled,
             .mcpConnectionTerminal, .mcpCatalogTerminal, .mcpExecutionUncertain,
             .mcpRequestProgress:
            break   // tool/permission/agent/task/progress/stats events are not shown in the chat text view
        }
    }

    /// Convenience: build a full projection from a sequence of envelopes.
    public static func build(from envelopes: [Envelope]) -> ConversationProjection {
        var p = ConversationProjection()
        for e in envelopes { p.apply(e) }
        return p
    }

    private mutating func markCurrentPartialMessageStopped(with payload: ErrorPayload) {
        guard let index = messages.indices.last else { return }
        guard !messages[index].isComplete else { return }
        switch messages[index].role {
        case .assistant, .agent:
            messages[index].recoveryAdvice = RuntimeErrorPresentation.partialResponseAdvice(for: payload)
        case .user, .system:
            break
        }
    }

    private mutating func applyTurnStats(_ stats: TurnStatsSnapshot) {
        guard stats.hasDisplayableMetrics,
              let messageID = stats.responseMessageID else { return }
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            guard messages[index].role == .assistant
                    || messages[index].role == .agent,
                  messages[index].turnStats == nil else { return }
            messages[index].turnStats = stats
        } else if pendingTurnStatsByMessageID[messageID] == nil,
                  pendingTurnStatsByMessageID.count
                    < Self.maximumPendingTurnStats {
            pendingTurnStatsByMessageID[messageID] = stats
        }
    }

    private mutating func takePendingTurnStats(
        for messageID: MessageID
    ) -> TurnStatsSnapshot? {
        pendingTurnStatsByMessageID.removeValue(forKey: messageID)
    }
}

/// Shared validation for the additive submission-status folds. The EventLog is
/// append-only, so malformed or stale status records are ignored rather than
/// allowed to regress a user-visible submission.
enum SubmissionStatusFold {
    static func accepts(currentStatus: SubmissionStatus?,
                        currentAttempt: Int?,
                        next: SubmissionStatusChangedPayload) -> Bool {
        guard next.attempt > 0 else { return false }
        guard let currentAttempt else {
            return next.attempt == 1 && next.status == .queued
        }
        guard next.attempt >= currentAttempt else { return false }
        if next.attempt > currentAttempt {
            return next.attempt == currentAttempt + 1 && next.status == .queued
        }
        guard let currentStatus else { return true }
        guard next.status != currentStatus else { return false }

        switch currentStatus {
        case .queued:
            return next.status == .running || next.status.isTerminal
        case .running:
            return next.status.isTerminal
        case .completed, .failed, .cancelled:
            return false
        }
    }
}
