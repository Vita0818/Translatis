import Foundation
import IntatisCore
import IntatisProtocol

public struct CoworkTaskView: Codable, Equatable, Sendable, Identifiable {
    public var id: TaskID
    public var contract: TaskContract?
    public var status: TaskStatus
    public var rootTaskID: TaskID?
    public var parentTaskID: TaskID?
    public var issuer: AgentID?
    public var assignee: AgentID?
    public var result: String?
    public var error: String?
    public var report: TaskReportPayload?
    public var attempt: Int
    public var statusReason: String?

    public init(id: TaskID,
                contract: TaskContract? = nil,
                status: TaskStatus,
                rootTaskID: TaskID? = nil,
                parentTaskID: TaskID? = nil,
                issuer: AgentID? = nil,
                assignee: AgentID? = nil,
                result: String? = nil,
                error: String? = nil,
                report: TaskReportPayload? = nil,
                attempt: Int = 0,
                statusReason: String? = nil) {
        self.id = id
        self.contract = contract
        self.status = status
        self.rootTaskID = rootTaskID
        self.parentTaskID = parentTaskID
        self.issuer = issuer
        self.assignee = assignee
        self.result = result
        self.error = error
        self.report = report
        self.attempt = attempt
        self.statusReason = statusReason
    }
}

public struct CoworkMailboxView: Codable, Equatable, Sendable {
    public var pendingMessages: [MessageID]
    public var pendingTasks: [TaskID]
    public var completedTasks: [TaskID]

    public init(pendingMessages: [MessageID] = [],
                pendingTasks: [TaskID] = [],
                completedTasks: [TaskID] = []) {
        self.pendingMessages = pendingMessages
        self.pendingTasks = pendingTasks
        self.completedTasks = completedTasks
    }
}

/// Durable prepare/settle fold used by crash recovery. `settled == nil` means
/// the log cannot prove whether the executor completed before interruption.
public struct CoworkToolExecutionView: Identifiable, Equatable, Sendable {
    public var id: String { prepared.executionID }
    public var prepared: ToolExecutionPreparedPayload
    public var preparedSeq: Int
    public var settled: ToolExecutionSettledPayload?
    public var settledSeq: Int?
    /// Duplicate prepares or conflicting terminal settlements make an
    /// execution ID unsafe to interpret. The projection retains the first
    /// observed records for audit, but no terminal result may clear recovery
    /// gates once this flag is set.
    public var hasAmbiguousDurableHistory: Bool

    public init(prepared: ToolExecutionPreparedPayload,
                preparedSeq: Int,
                settled: ToolExecutionSettledPayload? = nil,
                settledSeq: Int? = nil,
                hasAmbiguousDurableHistory: Bool = false) {
        self.prepared = prepared
        self.preparedSeq = preparedSeq
        self.settled = settled
        self.settledSeq = settledSeq
        self.hasAmbiguousDurableHistory = hasAmbiguousDurableHistory
    }

    /// A settlement is authoritative for this projected execution only when it
    /// follows (or reconstructs) the exact durable prepare record. Reused IDs,
    /// reordered events, and mismatched payloads remain unresolved rather than
    /// borrowing a terminal outcome from another call.
    public var validatedSettlement: ToolExecutionSettledPayload? {
        guard !hasAmbiguousDurableHistory,
              let settled,
              let settledSeq,
              settledSeq >= preparedSeq,
              settled.prepared == prepared,
              !(settled.outcome == .succeeded
                && settled.effectDisposition == .notStarted) else { return nil }
        return settled
    }
}

/// Immutable accepted user payload plus its latest validated execution status.
/// Array order in ``CoworkProjection/submittedIntents`` is admission FIFO.
public struct CoworkSubmittedIntentView: Identifiable, Equatable, Sendable {
    public let id: SubmissionID
    public let payload: UserMessagePayload
    public let submittedSeq: Int
    public var status: SubmissionStatus?
    public var attempt: Int?
    public var failure: SubmissionFailure?

    public init?(payload: UserMessagePayload,
                 submittedSeq: Int,
                 status: SubmissionStatus? = nil,
                 attempt: Int? = nil,
                 failure: SubmissionFailure? = nil) {
        guard let id = payload.submissionID else { return nil }
        self.id = id
        self.payload = payload
        self.submittedSeq = submittedSeq
        self.status = status
        self.attempt = attempt
        self.failure = failure
    }
}

public struct CoworkProjection: Equatable, Sendable {
    public private(set) var sessionSettings: SessionSettingsUpdatedPayload?
    public private(set) var completedSessionMigrations: [String: SessionStorageMigratedPayload] = [:]
    /// Accepted submitted intents in first-admission order. Duplicate
    /// `user_message` records carrying an existing identity are ignored.
    public private(set) var submittedIntents: [CoworkSubmittedIntentView] = []
    /// Execution-layer invocation views (legacy `TaskID` semantics).
    public private(set) var tasks: [TaskID: CoworkTaskView] = [:]
    /// Durable user-visible work plan, independent of invocation completion.
    public private(set) var workTasks: [WorkTaskID: WorkTask] = [:]
    public private(set) var goals: [GoalID: Goal] = [:]
    public private(set) var continuationRuns: [ContinuationRunID: ContinuationRun] = [:]
    /// First durable close claim per exact run. Conflicting later records are
    /// ignored by this rebuildable view; mutation paths use EventLog's locked
    /// compare-and-append and fail closed on ambiguous durable history.
    public private(set) var continuationRunCloseClaims:
        [ContinuationRunID: ContinuationRunCloseRequestedPayload] = [:]
    /// A second non-identical claim for one RunID makes the close history
    /// ambiguous. Presentation can retain the first fact, but any runtime
    /// restore/admission decision must fail closed.
    public private(set) var ambiguousContinuationRunCloseClaimIDs:
        Set<ContinuationRunID> = []
    public private(set) var currentGoalID: GoalID?
    /// Agents that are currently attached and may participate in runtime
    /// operations. Detach keeps the existing live-roster semantics so callers
    /// cannot accidentally route work to a historical identity.
    public private(set) var agentRoster: [AgentID: AgentAttachedPayload] = [:]
    /// Every agent identity durably admitted by this session, including agents
    /// that were later detached. The latest attached payload is retained so a
    /// replay can rebuild the history picker without a second persistence
    /// format; current operability must still be checked against `agentRoster`.
    public private(set) var historicalAgentRoster: [AgentID: AgentAttachedPayload] = [:]
    /// Stable first-admission order for the historical roster. Keeping this
    /// separately from the dictionary prevents live status/message changes
    /// from reordering the UI and avoids sorting the roster on every fold.
    public private(set) var historicalAgentOrder: [AgentID] = []
    public private(set) var mailboxes: [AgentID: CoworkMailboxView] = [:]
    public private(set) var rejectedDelegations: [DelegationRejectedPayload] = []
    public private(set) var workspaceLeases: [WorkspaceLeaseID: WorkspaceLease] = [:]
    public private(set) var capabilityLeases: [CapabilityLeaseID: CapabilityLease] = [:]
    public private(set) var workspaceLeaseAgents: [WorkspaceLeaseID: AgentID] = [:]
    public private(set) var capabilityLeaseAgents: [CapabilityLeaseID: AgentID] = [:]
    public private(set) var agentMessages: [AgentMessagePayload] = []
    public private(set) var agentStatuses: [AgentID: AgentState] = [:]
    public private(set) var agentOwners: [AgentID: AgentID] = [:]
    public private(set) var toolExecutions: [String: CoworkToolExecutionView] = [:]

    public init() {}

    public var historicalAgentsInCreationOrder: [AgentAttachedPayload] {
        historicalAgentOrder.compactMap { historicalAgentRoster[$0] }
    }

    public var activeTasks: [CoworkTaskView] {
        tasks.values.filter { $0.status == .created || $0.status == .assigned || $0.status == .queued || $0.status == .running }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public var queuedTasks: [CoworkTaskView] {
        tasks.values.filter { $0.status == .queued }.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public var runningTasks: [CoworkTaskView] {
        tasks.values.filter { $0.status == .running }.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public var completedTasks: [CoworkTaskView] {
        tasks.values.filter { $0.status == .completed }.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public var failedTasks: [CoworkTaskView] {
        tasks.values.filter { $0.status == .failed }.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public var cancelledTasks: [CoworkTaskView] {
        tasks.values.filter { $0.status == .cancelled }.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public var currentGoal: Goal? {
        currentGoalID.flatMap { goals[$0] }
    }

    public var activeWorkTasks: [WorkTask] {
        workTasks.values
            .filter { !$0.status.isTerminal }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public var workTaskGraph: WorkTaskGraph {
        WorkTaskGraph(tasks: workTasks)
    }

    public var unresolvedToolExecutions: [CoworkToolExecutionView] {
        toolExecutions.values
            .filter { $0.validatedSettlement == nil }
            .sorted {
                if $0.preparedSeq == $1.preparedSeq { return $0.id < $1.id }
                return $0.preparedSeq < $1.preparedSeq
            }
    }

    public var unresolvedNonReplayableToolExecutions: [CoworkToolExecutionView] {
        unresolvedToolExecutions.filter {
            $0.prepared.blocksTaskReplay
        }
    }

    /// Non-replayable calls whose durable outcome still cannot establish
    /// whether the declared side effect happened. A legacy successful
    /// settlement is a known completed effect (and still blocks task replay),
    /// while legacy failed/cancelled/denied settlements remain uncertain.
    public var uncertainNonReplayableToolExecutions: [CoworkToolExecutionView] {
        toolExecutions.values
            .filter { execution in
                guard execution.prepared.blocksTaskReplay else {
                    return false
                }
                guard let settled = execution.validatedSettlement else {
                    return true
                }
                switch settled.effectDisposition {
                case .notStarted, .committed:
                    return false
                case .unknown:
                    return true
                case nil:
                    return settled.outcome != .succeeded
                }
            }
            .sorted {
                if $0.preparedSeq == $1.preparedSeq { return $0.id < $1.id }
                return $0.preparedSeq < $1.preparedSeq
            }
    }

    /// Every non-replayable executor boundary whose settlement does not prove
    /// `notStarted`. A settled success or legacy/unknown disposition remains
    /// blocking because
    /// replaying the enclosing task starts again from its first model/tool step.
    /// Only a validated settlement proving the side effect never started is exempt.
    public var startedNonReplayableToolExecutions: [CoworkToolExecutionView] {
        toolExecutions.values
            .filter { execution in
                guard execution.prepared.blocksTaskReplay else {
                    return false
                }
                guard let settled = execution.validatedSettlement else {
                    return true
                }
                return settled.effectDisposition != .notStarted
                    || settled.outcome == .succeeded
            }
            .sorted {
                if $0.preparedSeq == $1.preparedSeq { return $0.id < $1.id }
                return $0.preparedSeq < $1.preparedSeq
            }
    }

    public func startedNonReplayableToolExecutions(taskID: TaskID,
                                                    attempt: Int) -> [CoworkToolExecutionView] {
        startedNonReplayableToolExecutions.filter { execution in
            execution.prepared.taskID == taskID
                && (execution.prepared.attempt == nil || execution.prepared.attempt == attempt)
        }
    }

    public mutating func apply(_ envelope: Envelope) {
        switch envelope.event {
        case .sessionSettingsUpdated(let payload):
            guard payload.schemaVersion == SessionSettingsUpdatedPayload.currentSchemaVersion,
                  payload.kind == .cowork,
                  payload.revision > 0,
                  payload.cowork?.sessionID == envelope.session else { return }
            if let current = sessionSettings {
                let (expectedRevision, overflow) =
                    current.revision.addingReportingOverflow(1)
                guard payload.previousRevision == current.revision,
                      !overflow,
                      payload.revision == expectedRevision else { return }
            } else {
                guard payload.previousRevision == nil,
                      payload.revision == 1 else { return }
            }
            sessionSettings = payload
        case .sessionStorageMigrated(let payload):
            guard payload.schemaVersion == SessionStorageMigratedPayload.currentSchemaVersion,
                  !payload.migrationID.isEmpty else { return }
            if let current = completedSessionMigrations[payload.migrationID], current != payload {
                return
            }
            completedSessionMigrations[payload.migrationID] = payload
        case .userMessage(let payload):
            guard let submissionID = payload.submissionID,
                  !submittedIntents.contains(where: { $0.id == submissionID }) else { return }
            guard let submittedIntent = CoworkSubmittedIntentView(
                payload: payload,
                submittedSeq: envelope.seq) else { return }
            submittedIntents.append(submittedIntent)
        case .submissionStatusChanged(let payload):
            guard let index = submittedIntents.firstIndex(where: {
                $0.id == payload.submissionID
            }), SubmissionStatusFold.accepts(
                currentStatus: submittedIntents[index].status,
                currentAttempt: submittedIntents[index].attempt,
                next: payload)
            else { return }
            submittedIntents[index].status = payload.status
            submittedIntents[index].attempt = payload.attempt
            submittedIntents[index].failure = payload.failure
        case .agentAttached(let payload):
            agentRoster[payload.agent] = payload
            upsertHistoricalAgent(payload)
        case .agentSpawned(let payload):
            // `agentAttached` is the durable admission fact and may carry the
            // exact inference binding approved for this agent. New logs emit it
            // before `agentSpawned`; never let the later lifecycle event erase
            // that frozen identity. A spawn-only legacy log can still recover a
            // roster entry, but its historical inference route is unresolved.
            if agentRoster[payload.agent] == nil {
                let legacyAttached = AgentAttachedPayload(
                    agent: payload.agent,
                    path: payload.path,
                    model: payload.model,
                    profile: "reviewed",
                    agentInferenceBinding: nil,
                    metadata: payload.metadata)
                agentRoster[payload.agent] = legacyAttached
                upsertHistoricalAgent(legacyAttached)
            } else if historicalAgentRoster[payload.agent] == nil,
                      let attached = agentRoster[payload.agent] {
                upsertHistoricalAgent(attached)
            }
            if let requestedBy = payload.requestedBy ?? payload.metadata?.sender {
                agentOwners[payload.agent] = requestedBy
            }
        case .agentDetached(let payload):
            agentRoster.removeValue(forKey: payload.agent)
            agentStatuses.removeValue(forKey: payload.agent)
            agentOwners.removeValue(forKey: payload.agent)
        case .agentStatus(let payload):
            if let agent = payload.agent {
                agentStatuses[agent] = payload.state
            }
        case .agentMessage(let payload):
            agentMessages.append(payload)
            if let to = payload.to {
                var mailbox = mailboxes[to, default: CoworkMailboxView()]
                Self.appendUnique(payload.messageId, to: &mailbox.pendingMessages)
                mailboxes[to] = mailbox
            }
        case .agentMessageConsumed(let payload):
            mailboxes[payload.agent, default: CoworkMailboxView()].pendingMessages.removeAll { $0 == payload.messageID }
        case .agentMessageDiscarded(let payload):
            mailboxes[payload.agent, default: CoworkMailboxView()].pendingMessages.removeAll { $0 == payload.messageID }
        case .informationRequested(let payload):
            var mailbox = mailboxes[payload.to, default: CoworkMailboxView()]
            Self.appendUnique(payload.requestID, to: &mailbox.pendingMessages)
            mailboxes[payload.to] = mailbox
        case .informationReplied(let payload):
            var mailbox = mailboxes[payload.to, default: CoworkMailboxView()]
            Self.appendUnique(payload.replyID, to: &mailbox.pendingMessages)
            mailboxes[payload.to] = mailbox
        case .delegationApproved(let payload):
            upsertTask(payload.contract, status: .assigned)
        case .delegationRejected(let payload):
            rejectedDelegations.append(payload)
        case .taskCreated(let payload):
            upsertTask(payload.contract, status: .created)
        case .taskAssigned(let payload):
            upsertTask(payload.contract, status: .assigned)
        case .taskDelegated(let payload):
            upsertTask(payload.contract, status: tasks[payload.contract.id]?.status ?? .assigned)
        case .taskQueued(let payload):
            upsertTask(payload.contract, status: .queued,
                       rootTaskID: payload.rootTaskID,
                       parentTaskID: payload.parentTaskID,
                       issuer: payload.issuer,
                       assignee: payload.assignee,
                       attempt: payload.attempt,
                       statusReason: payload.reason,
                       clearOutcome: true)
            var mailbox = mailboxes[payload.assignee, default: CoworkMailboxView()]
            Self.appendUnique(payload.contract.id, to: &mailbox.pendingTasks)
            mailboxes[payload.assignee] = mailbox
        case .taskStarted(let payload):
            updateTask(payload.taskID, status: .running, assignee: payload.agent, attempt: payload.attempt)
            mailboxes[payload.agent, default: CoworkMailboxView()].pendingTasks.removeAll { $0 == payload.taskID }
        case .taskCompleted(let payload):
            updateTask(payload.taskID, status: .completed, assignee: payload.agent,
                       result: payload.result, report: payload.report, attempt: payload.attempt)
            mailboxes[payload.agent, default: CoworkMailboxView()].pendingTasks.removeAll { $0 == payload.taskID }
            var mailbox = mailboxes[payload.agent, default: CoworkMailboxView()]
            Self.appendUnique(payload.taskID, to: &mailbox.completedTasks)
            mailboxes[payload.agent] = mailbox
        case .taskFailed(let payload):
            updateTask(payload.taskID, status: .failed, assignee: payload.agent,
                       error: payload.error, report: payload.report, attempt: payload.attempt,
                       statusReason: payload.error)
            mailboxes[payload.agent, default: CoworkMailboxView()].pendingTasks.removeAll { $0 == payload.taskID }
        case .taskCancelled(let payload):
            updateTask(payload.taskID, status: .cancelled, assignee: payload.agent,
                       error: payload.reason, report: payload.report, attempt: payload.attempt,
                       statusReason: payload.reason)
            mailboxes[payload.agent, default: CoworkMailboxView()].pendingTasks.removeAll { $0 == payload.taskID }
        case .taskRejected(let payload):
            if let contract = payload.contract {
                upsertTask(contract, status: .failed,
                           rootTaskID: payload.metadata?.rootTaskID,
                           parentTaskID: payload.metadata?.parentTaskID,
                           issuer: payload.metadata?.issuer,
                           assignee: payload.assignee,
                           error: payload.reason)
            }
        case .workTaskCreated(let payload):
            applyWorkTaskSnapshot(payload.task)
        case .workTaskUpdated(let payload):
            applyWorkTaskSnapshot(
                payload.task,
                allowsDependencyReadinessRecompute: true)
        case .workTaskDependencyChanged(let payload):
            applyWorkTaskSnapshot(
                payload.task,
                allowsDependencyReadinessRecompute: true)
        case .workTaskReady(let payload):
            applyWorkTaskSnapshot(payload.task, isRetry: true, requiredStatus: .ready)
        case .workTaskStarted(let payload):
            applyWorkTaskSnapshot(payload.task, requiredStatus: .inProgress)
        case .workTaskProgressed(let payload):
            applyWorkTaskSnapshot(payload.task)
        case .workTaskBlocked(let payload):
            applyWorkTaskSnapshot(payload.task, requiredStatus: .blocked)
        case .workTaskCompleted(let payload):
            applyWorkTaskSnapshot(payload.task, requiredStatus: .completed)
        case .workTaskFailed(let payload):
            applyWorkTaskSnapshot(payload.task, requiredStatus: .failed)
        case .workTaskCancelled(let payload):
            applyWorkTaskSnapshot(payload.task, requiredStatus: .cancelled)
        case .workTaskInvocationLinked(let payload):
            applyWorkTaskSnapshot(payload.task)
        case .workTaskEvidenceAdded(let payload):
            applyWorkTaskSnapshot(payload.task)
        case .goalCreated(let payload):
            applyGoalSnapshot(payload.goal)
            if payload.goal.status != .completed,
               currentGoalID == nil || currentGoalID == payload.goal.id ||
               currentGoal?.status == .completed {
                currentGoalID = payload.goal.id
            }
        case .goalEdited(let payload):
            applyGoalSnapshot(payload.goal)
        case .goalPaused(let payload):
            applyGoalSnapshot(payload.goal, requiredStatus: .paused)
        case .goalResumed(let payload):
            applyGoalSnapshot(payload.goal, requiredStatus: .active)
            if goals[payload.goal.id]?.status == .active {
                currentGoalID = payload.goal.id
            }
        case .goalAuditCompleted(let payload):
            applyGoalSnapshot(payload.goal)
        case .goalContinuationScheduled(let payload):
            applyGoalSnapshot(payload.goal)
        case .goalProgressed(let payload):
            applyGoalSnapshot(payload.goal)
        case .goalBlocked(let payload):
            applyGoalSnapshot(payload.goal, requiredStatus: .blocked)
        case .goalBudgetLimited(let payload):
            applyGoalSnapshot(payload.goal, requiredStatus: .budgetLimited)
        case .goalUsageLimited(let payload):
            applyGoalSnapshot(payload.goal, requiredStatus: .usageLimited)
        case .goalCompleted(let payload):
            var completed = payload.goal
            if let payloadAudit = payload.audit {
                // A completion event has two legacy-compatible audit locations.
                // Accept either one, but reject contradictory snapshots rather
                // than choosing whichever proof is more permissive.
                if let embeddedAudit = completed.latestAudit,
                   embeddedAudit != payloadAudit {
                    return
                }
                completed.latestAudit = payloadAudit
            }
            applyGoalSnapshot(completed, requiredStatus: .completed)
        case .goalCleared(let payload):
            applyGoalSnapshot(payload.goal)
            if currentGoalID == payload.goal.id {
                currentGoalID = nil
            }
        case .continuationRunCreated(let payload):
            applyContinuationRunSnapshot(payload.run)
        case .continuationRunStarted(let payload):
            applyContinuationRunSnapshot(payload.run, requiredStatus: .running)
        case .continuationRunCheckpointed(let payload):
            applyContinuationRunSnapshot(payload.run, requiredStatus: .checkpointed)
        case .continuationRunCloseRequested(let payload):
            if let first = continuationRunCloseClaims[payload.runID] {
                if first != payload {
                    ambiguousContinuationRunCloseClaimIDs.insert(payload.runID)
                }
            } else {
                continuationRunCloseClaims[payload.runID] = payload
            }
        case .continuationRunCompleted(let payload):
            applyContinuationRunSnapshot(payload.run, requiredStatus: .completed)
        case .continuationRunInterrupted(let payload):
            applyContinuationRunSnapshot(payload.run, requiredStatus: .interrupted)
        case .continuationRunCancelled(let payload):
            applyContinuationRunSnapshot(payload.run, requiredStatus: .cancelled)
        case .workspaceLeaseGranted(let payload):
            workspaceLeases[payload.lease.id] = payload.lease
            if let agent = payload.agent {
                workspaceLeaseAgents[payload.lease.id] = agent
            }
        case .workspaceLeaseRevoked(let payload):
            workspaceLeases.removeValue(forKey: payload.leaseID)
            workspaceLeaseAgents.removeValue(forKey: payload.leaseID)
        case .capabilityLeaseCreated(let payload):
            capabilityLeases[payload.lease.id] = payload.lease
            if let agent = payload.agent {
                capabilityLeaseAgents[payload.lease.id] = agent
            }
        case .capabilityLeaseRevoked(let payload):
            capabilityLeases.removeValue(forKey: payload.leaseID)
            capabilityLeaseAgents.removeValue(forKey: payload.leaseID)
        case .toolExecutionPrepared(let payload):
            if var existing = toolExecutions[payload.executionID] {
                // An execution ID identifies exactly one durable attempt. A
                // second prepare cannot supersede the first, even when its
                // payload is byte-for-byte identical: the first executor may
                // already have committed before the duplicate was appended.
                existing.hasAmbiguousDurableHistory = true
                toolExecutions[payload.executionID] = existing
            } else {
                toolExecutions[payload.executionID] = CoworkToolExecutionView(
                    prepared: payload,
                    preparedSeq: envelope.seq)
            }
        case .toolExecutionSettled(let payload):
            var execution = toolExecutions[payload.executionID]
                ?? CoworkToolExecutionView(
                    prepared: payload.prepared,
                    preparedSeq: envelope.seq)
            if let firstSettlement = execution.settled {
                // Exact duplicate terminal records are idempotent. A different
                // second terminal record is ambiguous and must never overwrite
                // the first result or relax recovery/retry gates.
                if firstSettlement != payload {
                    execution.hasAmbiguousDurableHistory = true
                }
            } else {
                execution.settled = payload
                execution.settledSeq = envelope.seq
            }
            toolExecutions[payload.executionID] = execution
        case .messageDelta, .messageCompleted, .codexAppServerEvent,
             .modelHistoryItem, .modelHistoryCompacted, .error,
             .toolCall, .toolResult, .permissionRequest, .permissionResolved,
             .patchProposed, .agentAttachRequested,
             .agentSpawnRequested, .agentToAgentMessage, .workspaceLeaseRequested,
             .workspaceLeaseDenied, .permissionReview, .permissionReviewRequested,
             .permissionReviewSettled, .artifactAdded,
             .artifactProgress, .turnStats, .responsesUsage, .turnOutcome,
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
            break
        }
    }

    public static func build(from envelopes: [Envelope]) -> CoworkProjection {
        var projection = CoworkProjection()
        for envelope in envelopes {
            projection.apply(envelope)
        }
        return projection
    }

    private mutating func upsertHistoricalAgent(
        _ payload: AgentAttachedPayload
    ) {
        if historicalAgentRoster[payload.agent] == nil {
            historicalAgentOrder.append(payload.agent)
        }
        historicalAgentRoster[payload.agent] = payload
    }

    private mutating func upsertTask(_ contract: TaskContract,
                                     status: TaskStatus,
                                     rootTaskID: TaskID? = nil,
                                     parentTaskID: TaskID? = nil,
                                     issuer: AgentID? = nil,
                                     assignee: AgentID? = nil,
                                     result: String? = nil,
                                     error: String? = nil,
                                     report: TaskReportPayload? = nil,
                                     attempt: Int? = nil,
                                     statusReason: String? = nil,
                                     clearOutcome: Bool = false) {
        var view = tasks[contract.id] ?? CoworkTaskView(
            id: contract.id,
            contract: contract,
            status: status,
            rootTaskID: rootTaskID,
            parentTaskID: parentTaskID ?? contract.parentTaskID,
            issuer: issuer ?? contract.issuer,
            assignee: assignee ?? contract.assignee)
        view.contract = contract
        view.status = status
        view.rootTaskID = rootTaskID ?? view.rootTaskID
        view.parentTaskID = parentTaskID ?? view.parentTaskID ?? contract.parentTaskID
        view.issuer = issuer ?? view.issuer ?? contract.issuer
        view.assignee = assignee ?? view.assignee ?? contract.assignee
        if clearOutcome {
            view.result = nil
            view.error = nil
            view.report = nil
        } else {
            view.result = result ?? view.result
            view.error = error ?? view.error
            view.report = report ?? view.report
        }
        view.attempt = attempt ?? view.attempt
        view.statusReason = statusReason ?? (clearOutcome ? nil : view.statusReason)
        tasks[contract.id] = view
    }

    private mutating func updateTask(_ taskID: TaskID,
                                     status: TaskStatus,
                                     assignee: AgentID? = nil,
                                     result: String? = nil,
                                     error: String? = nil,
                                     report: TaskReportPayload? = nil,
                                     attempt: Int? = nil,
                                     statusReason: String? = nil) {
        var view = tasks[taskID] ?? CoworkTaskView(id: taskID, status: status, assignee: assignee)
        view.status = status
        view.assignee = assignee ?? view.assignee
        view.result = result ?? view.result
        view.error = error ?? view.error
        view.report = report ?? view.report
        view.attempt = attempt ?? view.attempt
        view.statusReason = statusReason ?? view.statusReason
        tasks[taskID] = view
    }

    /// Applies only monotonic, identity-preserving snapshots. Equal revisions
    /// are idempotent but cannot overwrite different content.
    private mutating func applyWorkTaskSnapshot(_ snapshot: WorkTask,
                                                isRetry: Bool = false,
                                                allowsDependencyReadinessRecompute: Bool = false,
                                                requiredStatus: WorkTaskStatus? = nil) {
        if let requiredStatus, snapshot.status != requiredStatus { return }
        if snapshot.status == .completed && !snapshot.hasValidCompletionEvidence { return }
        guard let current = workTasks[snapshot.id] else {
            workTasks[snapshot.id] = snapshot
            return
        }
        guard snapshot.id == current.id,
              snapshot.createdAt == current.createdAt,
              snapshot.revision >= current.revision else { return }
        if snapshot.revision == current.revision {
            if snapshot == current { workTasks[snapshot.id] = snapshot }
            return
        }
        let isStandardTransition = current.status.canTransition(
            to: snapshot.status,
            isRetry: isRetry)
        let isHostDerivedReadinessTransition = allowsDependencyReadinessRecompute
            && snapshot.dependsOn != current.dependsOn
            && Self.canHostRecomputeReadiness(from: current)
            && Self.snapshotMatchesDependencyReadiness(
                snapshot,
                existingTasks: workTasks)
        guard isStandardTransition || isHostDerivedReadinessTransition else { return }
        workTasks[snapshot.id] = snapshot
    }

    private static func canHostRecomputeReadiness(from task: WorkTask) -> Bool {
        task.status == .pending
            || task.status == .ready
            || (task.status == .blocked
                && (task.progressNote?.hasPrefix("waiting for dependencies:") == true
                    || task.progressNote?.hasPrefix("dependency failed or was cancelled:") == true
                    || task.progressNote?.hasPrefix("blocked by terminal dependencies:") == true))
    }

    private static func snapshotMatchesDependencyReadiness(
        _ snapshot: WorkTask,
        existingTasks: [WorkTaskID: WorkTask]
    ) -> Bool {
        var candidateTasks = existingTasks
        candidateTasks[snapshot.id] = snapshot
        switch WorkTaskGraph(tasks: candidateTasks).readiness(of: snapshot.id) {
        case .success(.ready):
            return snapshot.status == .ready
        case .success(.waitingFor):
            return snapshot.status == .pending
        case .success(.blockedBy):
            return snapshot.status == .blocked
        case .failure:
            return false
        }
    }

    private mutating func applyGoalSnapshot(_ snapshot: Goal,
                                            requiredStatus: GoalStatus? = nil) {
        if let requiredStatus, snapshot.status != requiredStatus { return }
        if snapshot.status == .completed,
           !snapshot.hasValidCompletionProof { return }
        guard let current = goals[snapshot.id] else {
            goals[snapshot.id] = snapshot
            return
        }
        guard snapshot.id == current.id,
              snapshot.sessionID == current.sessionID,
              snapshot.createdAt == current.createdAt,
              snapshot.revision >= current.revision else { return }
        if snapshot.revision == current.revision {
            if snapshot == current { goals[snapshot.id] = snapshot }
            return
        }
        guard current.status.canTransition(to: snapshot.status) else { return }
        goals[snapshot.id] = snapshot
    }

    private mutating func applyContinuationRunSnapshot(
        _ snapshot: ContinuationRun,
        requiredStatus: ContinuationRunStatus? = nil
    ) {
        if let requiredStatus, snapshot.status != requiredStatus { return }
        guard let current = continuationRuns[snapshot.id] else {
            continuationRuns[snapshot.id] = snapshot
            return
        }
        guard snapshot.id == current.id,
              snapshot.sessionID == current.sessionID,
              snapshot.goalID == current.goalID,
              snapshot.ordinal == current.ordinal,
              current.status.canTransition(to: snapshot.status) else {
            return
        }
        continuationRuns[snapshot.id] = snapshot
    }

    private static func appendUnique<T: Equatable>(_ value: T, to values: inout [T]) {
        if !values.contains(value) {
            values.append(value)
        }
    }
}
