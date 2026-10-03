import Foundation
import IntatisCore

/// Wraps an `Event` with the metadata needed for ordering, resume, and audit.
///
/// On the wire / on disk the shape is flat:
/// ```json
/// { "seq": 1421, "ts": "2026-06-11T09:14:22Z", "session": "sess_8f2a",
///   "v": 1, "type": "message_delta", "payload": { ... } }
/// ```
/// `seq` is monotonic per session and powers `session.resume { fromSeq }`.
public struct Envelope: Codable, Equatable, Sendable {
    public var seq: Int
    public var ts: Date
    public var session: SessionID
    /// Event schema version. Additive-only evolution (ARCHITECTURE.md §8 risk 7).
    public var v: Int
    public var event: Event

    public init(seq: Int, ts: Date = Date(), session: SessionID, v: Int = 1, event: Event) {
        self.seq = seq
        self.ts = ts
        self.session = session
        self.v = v
        self.event = event
    }

    private enum CodingKeys: String, CodingKey {
        case seq, ts, session, v, type, payload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        ts = try c.decode(Date.self, forKey: .ts)
        session = try c.decode(SessionID.self, forKey: .session)
        v = try c.decode(Int.self, forKey: .v)
        let tag = try c.decode(Event.TypeTag.self, forKey: .type)
        event = try Self.decodeEvent(tag, from: c)
    }

    /// Authorization-bearing events are decoded on a small, dedicated call
    /// path. Keeping them out of the monolithic event switch prevents the
    /// maximum stack frame for every other payload family from being live
    /// while Foundation recursively decodes an authorization snapshot.
    private static func decodeEvent(
        _ tag: Event.TypeTag,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Event {
        switch tag {
        case .toolExecutionPrepared,
             .toolExecutionSettled,
             .permissionRequest,
             .permissionResolved,
             .permissionReviewRequested,
             .permissionReviewSettled:
            return try decodeAuthorizationEvent(tag, from: container)
        default:
            return try decodeRemainingEvent(tag, from: container)
        }
    }

    private static func decodeAuthorizationEvent(
        _ tag: Event.TypeTag,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Event {
        switch tag {
        case .toolExecutionPrepared:
            return .toolExecutionPrepared(
                try container.decode(
                    ToolExecutionPreparedPayload.self,
                    forKey: .payload))
        case .toolExecutionSettled:
            return .toolExecutionSettled(
                try container.decode(
                    ToolExecutionSettledPayload.self,
                    forKey: .payload))
        case .permissionRequest:
            return .permissionRequest(
                try container.decode(
                    PermissionRequestPayload.self,
                    forKey: .payload))
        case .permissionResolved:
            return .permissionResolved(
                try container.decode(
                    PermissionResolvedPayload.self,
                    forKey: .payload))
        case .permissionReviewRequested:
            return .permissionReviewRequested(
                try container.decode(
                    PermissionReviewRequestedPayload.self,
                    forKey: .payload))
        case .permissionReviewSettled:
            return .permissionReviewSettled(
                try container.decode(
                    PermissionReviewSettledPayload.self,
                    forKey: .payload))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription:
                    "Event type is not authorization-bearing")
        }
    }

    private static func decodeRemainingEvent(
        _ tag: Event.TypeTag,
        from c: KeyedDecodingContainer<CodingKeys>
    ) throws -> Event {
        switch tag {
        case .sessionSettingsUpdated:
            return .sessionSettingsUpdated(try c.decode(SessionSettingsUpdatedPayload.self, forKey: .payload))
        case .sessionStorageMigrated:
            return .sessionStorageMigrated(try c.decode(SessionStorageMigratedPayload.self, forKey: .payload))
        case .userMessage:
            return .userMessage(try c.decode(UserMessagePayload.self, forKey: .payload))
        case .submissionStatusChanged:
            return .submissionStatusChanged(try c.decode(SubmissionStatusChangedPayload.self, forKey: .payload))
        case .messageDelta:
            return .messageDelta(try c.decode(MessageDeltaPayload.self, forKey: .payload))
        case .messageCompleted:
            return .messageCompleted(try c.decode(MessageCompletedPayload.self, forKey: .payload))
        case .codexAppServerEvent:
            return .codexAppServerEvent(
                try c.decode(
                    CodexAppServerEventPayload.self,
                    forKey: .payload))
        case .modelHistoryItem:
            return .modelHistoryItem(try c.decode(ModelHistoryItemPayload.self, forKey: .payload))
        case .modelHistoryCompacted:
            return .modelHistoryCompacted(
                try c.decode(
                    ModelHistoryCompactedPayload.self,
                    forKey: .payload))
        case .error:
            return .error(try c.decode(ErrorPayload.self, forKey: .payload))
        case .toolCall:
            return .toolCall(try c.decode(ToolCallPayload.self, forKey: .payload))
        case .toolResult:
            return .toolResult(try c.decode(ToolResultPayload.self, forKey: .payload))
        case .toolExecutionPrepared:
            return .toolExecutionPrepared(try c.decode(ToolExecutionPreparedPayload.self, forKey: .payload))
        case .toolExecutionSettled:
            return .toolExecutionSettled(try c.decode(ToolExecutionSettledPayload.self, forKey: .payload))
        case .permissionRequest:
            return .permissionRequest(try c.decode(PermissionRequestPayload.self, forKey: .payload))
        case .permissionResolved:
            return .permissionResolved(try c.decode(PermissionResolvedPayload.self, forKey: .payload))
        case .patchProposed:
            return .patchProposed(try c.decode(PatchProposedPayload.self, forKey: .payload))
        case .agentStatus:
            return .agentStatus(try c.decode(AgentStatusPayload.self, forKey: .payload))
        case .agentAttached:
            return .agentAttached(try c.decode(AgentAttachedPayload.self, forKey: .payload))
        case .agentAttachRequested:
            return .agentAttachRequested(try c.decode(AgentAttachRequestedPayload.self, forKey: .payload))
        case .agentDetached:
            return .agentDetached(try c.decode(AgentDetachedPayload.self, forKey: .payload))
        case .agentSpawnRequested:
            return .agentSpawnRequested(try c.decode(AgentSpawnRequestedPayload.self, forKey: .payload))
        case .agentSpawned:
            return .agentSpawned(try c.decode(AgentSpawnedPayload.self, forKey: .payload))
        case .agentMessage:
            return .agentMessage(try c.decode(AgentMessagePayload.self, forKey: .payload))
        case .agentMessageConsumed:
            return .agentMessageConsumed(try c.decode(AgentMessageConsumedPayload.self, forKey: .payload))
        case .agentMessageDiscarded:
            return .agentMessageDiscarded(try c.decode(AgentMessageDiscardedPayload.self, forKey: .payload))
        case .agentToAgentMessage:
            return .agentToAgentMessage(try c.decode(AgentToAgentMessagePayload.self, forKey: .payload))
        case .informationRequested:
            return .informationRequested(try c.decode(InformationRequestedPayload.self, forKey: .payload))
        case .informationReplied:
            return .informationReplied(try c.decode(InformationRepliedPayload.self, forKey: .payload))
        case .delegationApproved:
            return .delegationApproved(try c.decode(DelegationApprovedPayload.self, forKey: .payload))
        case .delegationRejected:
            return .delegationRejected(try c.decode(DelegationRejectedPayload.self, forKey: .payload))
        case .taskDelegated:
            return .taskDelegated(try c.decode(TaskDelegatedPayload.self, forKey: .payload))
        case .workspaceLeaseRequested:
            return .workspaceLeaseRequested(try c.decode(WorkspaceLeaseRequestedPayload.self, forKey: .payload))
        case .workspaceLeaseGranted:
            return .workspaceLeaseGranted(try c.decode(WorkspaceLeaseGrantedPayload.self, forKey: .payload))
        case .workspaceLeaseDenied:
            return .workspaceLeaseDenied(try c.decode(WorkspaceLeaseDeniedPayload.self, forKey: .payload))
        case .workspaceLeaseRevoked:
            return .workspaceLeaseRevoked(try c.decode(WorkspaceLeaseRevokedPayload.self, forKey: .payload))
        case .capabilityLeaseCreated:
            return .capabilityLeaseCreated(try c.decode(CapabilityLeaseCreatedPayload.self, forKey: .payload))
        case .capabilityLeaseRevoked:
            return .capabilityLeaseRevoked(try c.decode(CapabilityLeaseRevokedPayload.self, forKey: .payload))
        case .permissionReview:
            return .permissionReview(try c.decode(PermissionReviewPayload.self, forKey: .payload))
        case .permissionReviewRequested:
            return .permissionReviewRequested(try c.decode(PermissionReviewRequestedPayload.self, forKey: .payload))
        case .permissionReviewSettled:
            return .permissionReviewSettled(try c.decode(PermissionReviewSettledPayload.self, forKey: .payload))
        case .taskCreated:
            return .taskCreated(try c.decode(TaskCreatedPayload.self, forKey: .payload))
        case .taskAssigned:
            return .taskAssigned(try c.decode(TaskAssignedPayload.self, forKey: .payload))
        case .taskQueued:
            return .taskQueued(try c.decode(TaskQueuedPayload.self, forKey: .payload))
        case .taskStarted:
            return .taskStarted(try c.decode(TaskStartedPayload.self, forKey: .payload))
        case .taskCompleted:
            return .taskCompleted(try c.decode(TaskCompletedPayload.self, forKey: .payload))
        case .taskFailed:
            return .taskFailed(try c.decode(TaskFailedPayload.self, forKey: .payload))
        case .taskCancelled:
            return .taskCancelled(try c.decode(TaskCancelledPayload.self, forKey: .payload))
        case .taskRejected:
            return .taskRejected(try c.decode(TaskRejectedPayload.self, forKey: .payload))
        case .workTaskCreated:
            return .workTaskCreated(try c.decode(WorkTaskCreatedPayload.self, forKey: .payload))
        case .workTaskUpdated:
            return .workTaskUpdated(try c.decode(WorkTaskUpdatedPayload.self, forKey: .payload))
        case .workTaskDependencyChanged:
            return .workTaskDependencyChanged(try c.decode(WorkTaskDependencyChangedPayload.self, forKey: .payload))
        case .workTaskReady:
            return .workTaskReady(try c.decode(WorkTaskReadyPayload.self, forKey: .payload))
        case .workTaskStarted:
            return .workTaskStarted(try c.decode(WorkTaskStartedPayload.self, forKey: .payload))
        case .workTaskProgressed:
            return .workTaskProgressed(try c.decode(WorkTaskProgressedPayload.self, forKey: .payload))
        case .workTaskBlocked:
            return .workTaskBlocked(try c.decode(WorkTaskBlockedPayload.self, forKey: .payload))
        case .workTaskCompleted:
            return .workTaskCompleted(try c.decode(WorkTaskCompletedPayload.self, forKey: .payload))
        case .workTaskFailed:
            return .workTaskFailed(try c.decode(WorkTaskFailedPayload.self, forKey: .payload))
        case .workTaskCancelled:
            return .workTaskCancelled(try c.decode(WorkTaskCancelledPayload.self, forKey: .payload))
        case .workTaskInvocationLinked:
            return .workTaskInvocationLinked(try c.decode(WorkTaskInvocationLinkedPayload.self, forKey: .payload))
        case .workTaskEvidenceAdded:
            return .workTaskEvidenceAdded(try c.decode(WorkTaskEvidenceAddedPayload.self, forKey: .payload))
        case .goalCreated:
            return .goalCreated(try c.decode(GoalCreatedPayload.self, forKey: .payload))
        case .goalEdited:
            return .goalEdited(try c.decode(GoalEditedPayload.self, forKey: .payload))
        case .goalPaused:
            return .goalPaused(try c.decode(GoalPausedPayload.self, forKey: .payload))
        case .goalResumed:
            return .goalResumed(try c.decode(GoalResumedPayload.self, forKey: .payload))
        case .goalAuditCompleted:
            return .goalAuditCompleted(try c.decode(GoalAuditCompletedPayload.self, forKey: .payload))
        case .goalContinuationScheduled:
            return .goalContinuationScheduled(try c.decode(GoalContinuationScheduledPayload.self, forKey: .payload))
        case .goalProgressed:
            return .goalProgressed(try c.decode(GoalProgressedPayload.self, forKey: .payload))
        case .goalBlocked:
            return .goalBlocked(try c.decode(GoalBlockedPayload.self, forKey: .payload))
        case .goalBudgetLimited:
            return .goalBudgetLimited(try c.decode(GoalBudgetLimitedPayload.self, forKey: .payload))
        case .goalUsageLimited:
            return .goalUsageLimited(try c.decode(GoalUsageLimitedPayload.self, forKey: .payload))
        case .goalCompleted:
            return .goalCompleted(try c.decode(GoalCompletedPayload.self, forKey: .payload))
        case .goalCleared:
            return .goalCleared(try c.decode(GoalClearedPayload.self, forKey: .payload))
        case .continuationRunCreated:
            return .continuationRunCreated(try c.decode(ContinuationRunCreatedPayload.self, forKey: .payload))
        case .continuationRunStarted:
            return .continuationRunStarted(try c.decode(ContinuationRunStartedPayload.self, forKey: .payload))
        case .continuationRunCheckpointed:
            return .continuationRunCheckpointed(try c.decode(ContinuationRunCheckpointedPayload.self, forKey: .payload))
        case .continuationRunCloseRequested:
            return .continuationRunCloseRequested(try c.decode(ContinuationRunCloseRequestedPayload.self, forKey: .payload))
        case .continuationRunCompleted:
            return .continuationRunCompleted(try c.decode(ContinuationRunCompletedPayload.self, forKey: .payload))
        case .continuationRunInterrupted:
            return .continuationRunInterrupted(try c.decode(ContinuationRunInterruptedPayload.self, forKey: .payload))
        case .continuationRunCancelled:
            return .continuationRunCancelled(try c.decode(ContinuationRunCancelledPayload.self, forKey: .payload))
        case .artifactAdded:
            return .artifactAdded(try c.decode(ArtifactAddedPayload.self, forKey: .payload))
        case .artifactProgress:
            return .artifactProgress(try c.decode(ArtifactProgressPayload.self, forKey: .payload))
        case .mcpServerAttached:
            return .mcpServerAttached(try c.decode(MCPServerAttachedPayload.self, forKey: .payload))
        case .mcpServerDetached:
            return .mcpServerDetached(try c.decode(MCPServerDetachedPayload.self, forKey: .payload))
        case .mcpAttachmentPolicyUpdated:
            return .mcpAttachmentPolicyUpdated(try c.decode(MCPAttachmentPolicyUpdatedPayload.self, forKey: .payload))
        case .mcpConsentGranted:
            return .mcpConsentGranted(try c.decode(MCPConsentGrantedPayload.self, forKey: .payload))
        case .mcpConsentRevoked:
            return .mcpConsentRevoked(try c.decode(MCPConsentRevokedPayload.self, forKey: .payload))
        case .mcpControlOperationRequested:
            return .mcpControlOperationRequested(try c.decode(MCPControlOperationRequestedPayload.self, forKey: .payload))
        case .mcpControlOperationSettled:
            return .mcpControlOperationSettled(try c.decode(MCPControlOperationSettledPayload.self, forKey: .payload))
        case .mcpGrantGranted:
            return .mcpGrantGranted(try c.decode(MCPGrantGrantedPayload.self, forKey: .payload))
        case .mcpGrantRevoked:
            return .mcpGrantRevoked(try c.decode(MCPGrantRevokedPayload.self, forKey: .payload))
        case .mcpRememberedApprovalGranted:
            return .mcpRememberedApprovalGranted(
                try c.decode(
                    MCPRememberedApprovalGrantedPayload.self,
                    forKey: .payload))
        case .mcpRememberedApprovalRevoked:
            return .mcpRememberedApprovalRevoked(
                try c.decode(
                    MCPRememberedApprovalRevokedPayload.self,
                    forKey: .payload))
        case .mcpRootsPolicyUpdated:
            return .mcpRootsPolicyUpdated(try c.decode(MCPRootsPolicyUpdatedPayload.self, forKey: .payload))
        case .mcpNetworkPolicyUpdated:
            return .mcpNetworkPolicyUpdated(try c.decode(MCPNetworkPolicyUpdatedPayload.self, forKey: .payload))
        case .mcpPromptInserted:
            return .mcpPromptInserted(try c.decode(MCPPromptInsertedPayload.self, forKey: .payload))
        case .mcpSamplingRequested:
            return .mcpSamplingRequested(try c.decode(MCPSamplingRequestedPayload.self, forKey: .payload))
        case .mcpSamplingDecided:
            return .mcpSamplingDecided(try c.decode(MCPSamplingDecidedPayload.self, forKey: .payload))
        case .mcpSamplingSettled:
            return .mcpSamplingSettled(try c.decode(MCPSamplingSettledPayload.self, forKey: .payload))
        case .mcpElicitationRequested:
            return .mcpElicitationRequested(try c.decode(MCPElicitationRequestedPayload.self, forKey: .payload))
        case .mcpElicitationDecided:
            return .mcpElicitationDecided(try c.decode(MCPElicitationDecidedPayload.self, forKey: .payload))
        case .mcpElicitationSettled:
            return .mcpElicitationSettled(try c.decode(MCPElicitationSettledPayload.self, forKey: .payload))
        case .mcpRemoteTaskRequested:
            return .mcpRemoteTaskRequested(try c.decode(MCPRemoteTaskRequestedPayload.self, forKey: .payload))
        case .mcpRemoteTaskMapped:
            return .mcpRemoteTaskMapped(try c.decode(MCPRemoteTaskMappedPayload.self, forKey: .payload))
        case .mcpRemoteTaskStateChanged:
            return .mcpRemoteTaskStateChanged(try c.decode(MCPRemoteTaskStateChangedPayload.self, forKey: .payload))
        case .mcpRemoteTaskSettled:
            return .mcpRemoteTaskSettled(try c.decode(MCPRemoteTaskSettledPayload.self, forKey: .payload))
        case .mcpClientTaskRequested:
            return .mcpClientTaskRequested(try c.decode(MCPClientTaskRequestedPayload.self, forKey: .payload))
        case .mcpClientTaskStateChanged:
            return .mcpClientTaskStateChanged(try c.decode(MCPClientTaskStateChangedPayload.self, forKey: .payload))
        case .mcpClientTaskSettled:
            return .mcpClientTaskSettled(try c.decode(MCPClientTaskSettledPayload.self, forKey: .payload))
        case .mcpConnectionTerminal:
            return .mcpConnectionTerminal(try c.decode(MCPConnectionTerminalPayload.self, forKey: .payload))
        case .mcpCatalogTerminal:
            return .mcpCatalogTerminal(try c.decode(MCPCatalogTerminalPayload.self, forKey: .payload))
        case .mcpExecutionUncertain:
            return .mcpExecutionUncertain(try c.decode(MCPExecutionUncertainPayload.self, forKey: .payload))
        case .mcpRequestProgress:
            return .mcpRequestProgress(try c.decode(MCPRequestProgressPayload.self, forKey: .payload))
        case .turnStats:
            return .turnStats(try c.decode(TurnStatsPayload.self, forKey: .payload))
        case .responsesUsage:
            return .responsesUsage(try c.decode(ResponsesUsagePayload.self, forKey: .payload))
        case .turnOutcome:
            return .turnOutcome(try c.decode(TurnOutcomePayload.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seq, forKey: .seq)
        try c.encode(ts, forKey: .ts)
        try c.encode(session, forKey: .session)
        try c.encode(v, forKey: .v)
        try c.encode(event.type, forKey: .type)
        switch event {
        case .sessionSettingsUpdated(let p): try c.encode(p, forKey: .payload)
        case .sessionStorageMigrated(let p): try c.encode(p, forKey: .payload)
        case .userMessage(let p):        try c.encode(p, forKey: .payload)
        case .submissionStatusChanged(let p): try c.encode(p, forKey: .payload)
        case .messageDelta(let p):       try c.encode(p, forKey: .payload)
        case .messageCompleted(let p):   try c.encode(p, forKey: .payload)
        case .codexAppServerEvent(let p):
            try c.encode(p, forKey: .payload)
        case .modelHistoryItem(let p):   try c.encode(p, forKey: .payload)
        case .modelHistoryCompacted(let p):
            try c.encode(p, forKey: .payload)
        case .error(let p):              try c.encode(p, forKey: .payload)
        case .toolCall(let p):           try c.encode(p, forKey: .payload)
        case .toolResult(let p):         try c.encode(p, forKey: .payload)
        case .toolExecutionPrepared(let p): try c.encode(p, forKey: .payload)
        case .toolExecutionSettled(let p): try c.encode(p, forKey: .payload)
        case .permissionRequest(let p):  try c.encode(p, forKey: .payload)
        case .permissionResolved(let p): try c.encode(p, forKey: .payload)
        case .patchProposed(let p):      try c.encode(p, forKey: .payload)
        case .agentStatus(let p):        try c.encode(p, forKey: .payload)
        case .agentAttached(let p):       try c.encode(p, forKey: .payload)
        case .agentAttachRequested(let p): try c.encode(p, forKey: .payload)
        case .agentDetached(let p):       try c.encode(p, forKey: .payload)
        case .agentSpawnRequested(let p): try c.encode(p, forKey: .payload)
        case .agentSpawned(let p):        try c.encode(p, forKey: .payload)
        case .agentMessage(let p):        try c.encode(p, forKey: .payload)
        case .agentMessageConsumed(let p): try c.encode(p, forKey: .payload)
        case .agentMessageDiscarded(let p): try c.encode(p, forKey: .payload)
        case .agentToAgentMessage(let p): try c.encode(p, forKey: .payload)
        case .informationRequested(let p): try c.encode(p, forKey: .payload)
        case .informationReplied(let p):   try c.encode(p, forKey: .payload)
        case .delegationApproved(let p):   try c.encode(p, forKey: .payload)
        case .delegationRejected(let p):   try c.encode(p, forKey: .payload)
        case .taskDelegated(let p):        try c.encode(p, forKey: .payload)
        case .workspaceLeaseRequested(let p): try c.encode(p, forKey: .payload)
        case .workspaceLeaseGranted(let p):   try c.encode(p, forKey: .payload)
        case .workspaceLeaseDenied(let p):    try c.encode(p, forKey: .payload)
        case .workspaceLeaseRevoked(let p):   try c.encode(p, forKey: .payload)
        case .capabilityLeaseCreated(let p):  try c.encode(p, forKey: .payload)
        case .capabilityLeaseRevoked(let p):  try c.encode(p, forKey: .payload)
        case .permissionReview(let p):    try c.encode(p, forKey: .payload)
        case .permissionReviewRequested(let p): try c.encode(p, forKey: .payload)
        case .permissionReviewSettled(let p): try c.encode(p, forKey: .payload)
        case .taskCreated(let p):          try c.encode(p, forKey: .payload)
        case .taskAssigned(let p):         try c.encode(p, forKey: .payload)
        case .taskQueued(let p):           try c.encode(p, forKey: .payload)
        case .taskStarted(let p):          try c.encode(p, forKey: .payload)
        case .taskCompleted(let p):        try c.encode(p, forKey: .payload)
        case .taskFailed(let p):           try c.encode(p, forKey: .payload)
        case .taskCancelled(let p):        try c.encode(p, forKey: .payload)
        case .taskRejected(let p):         try c.encode(p, forKey: .payload)
        case .workTaskCreated(let p):       try c.encode(p, forKey: .payload)
        case .workTaskUpdated(let p):       try c.encode(p, forKey: .payload)
        case .workTaskDependencyChanged(let p): try c.encode(p, forKey: .payload)
        case .workTaskReady(let p):         try c.encode(p, forKey: .payload)
        case .workTaskStarted(let p):       try c.encode(p, forKey: .payload)
        case .workTaskProgressed(let p):    try c.encode(p, forKey: .payload)
        case .workTaskBlocked(let p):       try c.encode(p, forKey: .payload)
        case .workTaskCompleted(let p):     try c.encode(p, forKey: .payload)
        case .workTaskFailed(let p):        try c.encode(p, forKey: .payload)
        case .workTaskCancelled(let p):     try c.encode(p, forKey: .payload)
        case .workTaskInvocationLinked(let p): try c.encode(p, forKey: .payload)
        case .workTaskEvidenceAdded(let p): try c.encode(p, forKey: .payload)
        case .goalCreated(let p):           try c.encode(p, forKey: .payload)
        case .goalEdited(let p):            try c.encode(p, forKey: .payload)
        case .goalPaused(let p):            try c.encode(p, forKey: .payload)
        case .goalResumed(let p):           try c.encode(p, forKey: .payload)
        case .goalAuditCompleted(let p):    try c.encode(p, forKey: .payload)
        case .goalContinuationScheduled(let p): try c.encode(p, forKey: .payload)
        case .goalProgressed(let p):        try c.encode(p, forKey: .payload)
        case .goalBlocked(let p):           try c.encode(p, forKey: .payload)
        case .goalBudgetLimited(let p):     try c.encode(p, forKey: .payload)
        case .goalUsageLimited(let p):      try c.encode(p, forKey: .payload)
        case .goalCompleted(let p):         try c.encode(p, forKey: .payload)
        case .goalCleared(let p):           try c.encode(p, forKey: .payload)
        case .continuationRunCreated(let p): try c.encode(p, forKey: .payload)
        case .continuationRunStarted(let p): try c.encode(p, forKey: .payload)
        case .continuationRunCheckpointed(let p): try c.encode(p, forKey: .payload)
        case .continuationRunCloseRequested(let p): try c.encode(p, forKey: .payload)
        case .continuationRunCompleted(let p): try c.encode(p, forKey: .payload)
        case .continuationRunInterrupted(let p): try c.encode(p, forKey: .payload)
        case .continuationRunCancelled(let p): try c.encode(p, forKey: .payload)
        case .artifactAdded(let p):       try c.encode(p, forKey: .payload)
        case .artifactProgress(let p):    try c.encode(p, forKey: .payload)
        case .mcpServerAttached(let p): try c.encode(p, forKey: .payload)
        case .mcpServerDetached(let p): try c.encode(p, forKey: .payload)
        case .mcpAttachmentPolicyUpdated(let p): try c.encode(p, forKey: .payload)
        case .mcpConsentGranted(let p): try c.encode(p, forKey: .payload)
        case .mcpConsentRevoked(let p): try c.encode(p, forKey: .payload)
        case .mcpControlOperationRequested(let p): try c.encode(p, forKey: .payload)
        case .mcpControlOperationSettled(let p): try c.encode(p, forKey: .payload)
        case .mcpGrantGranted(let p): try c.encode(p, forKey: .payload)
        case .mcpGrantRevoked(let p): try c.encode(p, forKey: .payload)
        case .mcpRememberedApprovalGranted(let p):
            try c.encode(p, forKey: .payload)
        case .mcpRememberedApprovalRevoked(let p):
            try c.encode(p, forKey: .payload)
        case .mcpRootsPolicyUpdated(let p): try c.encode(p, forKey: .payload)
        case .mcpNetworkPolicyUpdated(let p): try c.encode(p, forKey: .payload)
        case .mcpPromptInserted(let p): try c.encode(p, forKey: .payload)
        case .mcpSamplingRequested(let p): try c.encode(p, forKey: .payload)
        case .mcpSamplingDecided(let p): try c.encode(p, forKey: .payload)
        case .mcpSamplingSettled(let p): try c.encode(p, forKey: .payload)
        case .mcpElicitationRequested(let p): try c.encode(p, forKey: .payload)
        case .mcpElicitationDecided(let p): try c.encode(p, forKey: .payload)
        case .mcpElicitationSettled(let p): try c.encode(p, forKey: .payload)
        case .mcpRemoteTaskRequested(let p): try c.encode(p, forKey: .payload)
        case .mcpRemoteTaskMapped(let p): try c.encode(p, forKey: .payload)
        case .mcpRemoteTaskStateChanged(let p): try c.encode(p, forKey: .payload)
        case .mcpRemoteTaskSettled(let p): try c.encode(p, forKey: .payload)
        case .mcpClientTaskRequested(let p): try c.encode(p, forKey: .payload)
        case .mcpClientTaskStateChanged(let p): try c.encode(p, forKey: .payload)
        case .mcpClientTaskSettled(let p): try c.encode(p, forKey: .payload)
        case .mcpConnectionTerminal(let p): try c.encode(p, forKey: .payload)
        case .mcpCatalogTerminal(let p): try c.encode(p, forKey: .payload)
        case .mcpExecutionUncertain(let p): try c.encode(p, forKey: .payload)
        case .mcpRequestProgress(let p): try c.encode(p, forKey: .payload)
        case .turnStats(let p):           try c.encode(p, forKey: .payload)
        case .responsesUsage(let p):      try c.encode(p, forKey: .payload)
        case .turnOutcome(let p):         try c.encode(p, forKey: .payload)
        }
    }
}

public extension Envelope {
    /// Canonical encoder/decoder for the event log and the wire protocol.
    /// ISO-8601 dates on both sides so round-trips are stable.
    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
