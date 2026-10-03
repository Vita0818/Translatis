import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisConversation
import IntatisTools

/// Host-owned policy for durable Goal continuation. The blocked threshold is
/// intentionally clamped to the product contract's minimum of three runs.
public struct GoalRuntimePolicy: Equatable, Sendable {
    public var blockedRunThreshold: Int
    public var noProgressRunThreshold: Int
    public var maximumRunHistoryItems: Int
    public var verifierPolicy: GoalVerifierPolicy

    public init(blockedRunThreshold: Int = 3,
                noProgressRunThreshold: Int = 2,
                maximumRunHistoryItems: Int = 24,
                verifierPolicy: GoalVerifierPolicy = GoalVerifierPolicy()) {
        self.blockedRunThreshold = max(3, blockedRunThreshold)
        self.noProgressRunThreshold = max(1, noProgressRunThreshold)
        self.maximumRunHistoryItems = max(1, maximumRunHistoryItems)
        self.verifierPolicy = verifierPolicy
    }
}

public enum GoalRuntimeError: Error, Equatable, Sendable, LocalizedError {
    case emptyObjective
    case invalidBudget
    case currentGoalExists(GoalID)
    case noCurrentGoal
    case recoveryInProgress
    case staleGoalRevision(expected: Int, actual: Int)
    case invalidGoalTransition(String)
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .emptyObjective:
            return "A Goal objective is required."
        case .invalidBudget:
            return "A Goal token budget must be greater than zero."
        case .currentGoalExists(let id):
            return "Goal \(id.rawValue) is still current; complete or clear it before creating another Goal."
        case .noCurrentGoal:
            return "There is no current Goal."
        case .recoveryInProgress:
            return "Goal recovery or a durable stop is not complete; retry this action after the session is ready."
        case .staleGoalRevision(let expected, let actual):
            return "Goal revision changed (expected \(expected), actual \(actual))."
        case .invalidGoalTransition(let message), .persistence(let message):
            return message
        }
    }
}

/// Host-driven Goal lifecycle and continuation loop.
///
/// This actor is deliberately outside ``AgentLoop`` and ``Orchestrator``. It
/// observes durable Goal events, creates one ``ContinuationRun`` at a time,
/// waits for the scheduler barrier, and asks an independent no-tools verifier
/// whether the user's objective is actually proven complete.
public actor GoalRuntimeController {
    public static let verifierAgentID = AgentID(rawValue: "goal-verifier")

    private struct StopRequest: Sendable {
        var reason: String
        var checkpoint: Bool
        var runCloseSource: ContinuationRunCloseSource
    }

    private struct PendingStop: Sendable {
        var goalID: GoalID
        var runID: ContinuationRunID?
        var request: StopRequest
        var cancelInvocations: Bool
        var resumeDataPlaneOnSuccess: Bool
    }

    private struct GoalStateSignature: Equatable, Sendable {
        var invocationStates: [String]
        var remainingWork: Set<String>
    }

    private enum RunDisposition: Sendable {
        case continueGoal
        case stopGoal
        case stopped
    }

    private enum RecoveryDisposition: Sendable {
        case continueGoal
        case safeWithoutContinuation
        case failed
    }

    typealias SendOperation = @Sendable (
        String,
        AgentID?,
        [ImageAttachment],
        UserMessagePayload?,
        GoalID?,
        ContinuationRunID?,
        Bool
    ) async -> OrchestratorSendResult

    private let sessionID: SessionID
    private let log: EventLog
    private let eventAppender: @Sendable ([Event]) async throws -> Void
    private let goalAuthority: Orchestrator?
    private let policy: GoalRuntimePolicy
    private let verifierProvider: @Sendable () async throws -> ToolCallingProvider
    private let verifierModel: @Sendable () async -> ModelID
    private let sendOperation: SendOperation
    private let waitForSchedulerIdle: @Sendable () async -> Void
    private let cancelActiveInvocations:
        @Sendable (String, ContinuationRunCloseSource) async -> Void
    private let resumePendingInvocations: @Sendable () async -> Void
    private let waitForGoalSchedulerIdle: @Sendable (GoalID, ContinuationRunID?) async -> Void
    private let cancelGoalInvocations:
        @Sendable (
            GoalID,
            ContinuationRunID?,
            String,
            ContinuationRunCloseSource
        ) async -> Bool
    private let consumeProviderUsageLimit: @Sendable (GoalID, ContinuationRunID) async -> String?
    /// Internal-only deterministic seam for the post-launch startup
    /// cancellation window. Shipping construction always leaves it nil.
    private let startupPostRecoveryHook: (@Sendable () async -> Void)?

    private var eventWatcher: Task<Void, Never>?
    private var continuationTask: Task<Void, Never>?
    private var launchInProgress = false
    private var startupAttemptInProgress = false
    private var startupWaiters: [CheckedContinuation<Bool, Never>] = []
    private var startupRecoveryComplete = false
    private var shutdownRequested = false
    private var continuationGeneration = 0
    private var runningGoalID: GoalID?
    private var runningContinuationRunID: ContinuationRunID?
    private var stopRequests: [Int: StopRequest] = [:]
    private var stopSettlementFailures: [Int: String] = [:]
    private var pendingStop: PendingStop?
    private var stopLockHeld = false
    private var stopLockWaiters: [CheckedContinuation<Void, Never>] = []
    private var goalMutationLockHeld = false
    private var goalMutationLockWaiters: [CheckedContinuation<Void, Never>] = []
    private var verifierControlPlane: GoalVerifierControlPlane?
    private var verifierControlPlaneModel: ModelID?

    public init(sessionID: SessionID,
                log: EventLog,
                orchestrator: Orchestrator,
                policy: GoalRuntimePolicy = GoalRuntimePolicy(),
                verifierProvider: @escaping @Sendable () async throws -> ToolCallingProvider,
                verifierModel: @escaping @Sendable () async -> ModelID) {
        self.sessionID = sessionID
        self.log = log
        self.eventAppender = { events in try await log.append(events) }
        self.goalAuthority = orchestrator
        self.policy = policy
        self.verifierProvider = verifierProvider
        self.verifierModel = verifierModel
        self.sendOperation = { text, target, images, userMessage, goalID, runID,
            recordUserMessage in
            await orchestrator.send(
                text,
                to: target,
                images: images,
                userMessage: userMessage,
                goalID: goalID,
                continuationRunID: runID,
                recordUserMessage: recordUserMessage)
        }
        self.waitForSchedulerIdle = {
            await orchestrator.runSchedulerUntilIdle()
        }
        self.cancelActiveInvocations = { reason, source in
            await orchestrator.cancelActiveTasks(
                reason: reason,
                runCloseSource: source)
        }
        self.resumePendingInvocations = {
            await orchestrator.resumePendingTasks()
        }
        self.waitForGoalSchedulerIdle = { goalID, runID in
            await orchestrator.runSchedulerUntilIdle(
                goalID: goalID,
                continuationRunID: runID)
        }
        self.cancelGoalInvocations = { goalID, runID, reason, source in
            await orchestrator.cancelActiveTasks(
                goalID: goalID,
                continuationRunID: runID,
                reason: reason,
                resumePendingTasksOnSuccess: false,
                runCloseSource: source)
        }
        self.consumeProviderUsageLimit = { goalID, runID in
            await orchestrator.consumeProviderUsageLimitFailure(
                goalID: goalID,
                continuationRunID: runID)
        }
        self.startupPostRecoveryHook = nil
    }

    /// Internal seam used by focused tests without constructing a production
    /// Orchestrator. Production callers use the public initializer above.
    init(sessionID: SessionID,
         log: EventLog,
         policy: GoalRuntimePolicy = GoalRuntimePolicy(),
         verifierProvider: @escaping @Sendable () async throws -> ToolCallingProvider,
         verifierModel: @escaping @Sendable () async -> ModelID,
         sendOperation: @escaping SendOperation,
         waitForSchedulerIdle: @escaping @Sendable () async -> Void = {},
         cancelActiveInvocations:
            @escaping @Sendable (String, ContinuationRunCloseSource) async -> Void = { _, _ in },
         resumePendingInvocations: @escaping @Sendable () async -> Void = {},
         waitForGoalSchedulerIdle: (@Sendable (GoalID, ContinuationRunID?) async -> Void)? = nil,
         cancelGoalInvocations: (@Sendable (
            GoalID,
            ContinuationRunID?,
            String,
            ContinuationRunCloseSource
         ) async -> Bool)? = nil,
         consumeProviderUsageLimit: @escaping @Sendable (GoalID, ContinuationRunID) async -> String? = { _, _ in nil },
         startupPostRecoveryHook: (@Sendable () async -> Void)? = nil,
         eventAppender: (@Sendable ([Event]) async throws -> Void)? = nil) {
        self.sessionID = sessionID
        self.log = log
        self.eventAppender = eventAppender ?? { events in try await log.append(events) }
        self.goalAuthority = nil
        self.policy = policy
        self.verifierProvider = verifierProvider
        self.verifierModel = verifierModel
        self.sendOperation = sendOperation
        self.waitForSchedulerIdle = waitForSchedulerIdle
        self.cancelActiveInvocations = cancelActiveInvocations
        self.resumePendingInvocations = resumePendingInvocations
        self.waitForGoalSchedulerIdle = waitForGoalSchedulerIdle ?? { _, _ in
            await waitForSchedulerIdle()
        }
        self.cancelGoalInvocations = cancelGoalInvocations ?? { _, _, reason, source in
            await cancelActiveInvocations(reason, source)
            return true
        }
        self.consumeProviderUsageLimit = consumeProviderUsageLimit
        self.startupPostRecoveryHook = startupPostRecoveryHook
    }

    deinit {
        eventWatcher?.cancel()
        continuationTask?.cancel()
    }

    /// Starts durable event observation and reconciles any interrupted Goal.
    ///
    /// Process startup is deliberately recovery-only: an active Goal is
    /// cancelled/checkpointed, conservatively audited, and then durably paused.
    /// Only an explicit ``resumeCurrentGoal()`` may create the next
    /// continuation. This keeps reopening a session distinct from resuming it.
    /// Recovered unsafe tool executions keep the data plane fail closed.
    @discardableResult
    public func start() async -> Bool {
        // `start()` may be retried after a fail-closed persistence/cancellation
        // failure. A concurrent retry must not observe a half-recovered Goal or
        // authorize the host to resume its data plane.
        if startupAttemptInProgress {
            return await withCheckedContinuation { continuation in
                startupWaiters.append(continuation)
            }
        }
        if startupRecoveryComplete,
           !shutdownRequested,
           pendingStop == nil,
           !stopLockHeld,
           !goalMutationLockHeld { return true }
        guard !Task.isCancelled, !goalMutationLockHeld else { return false }
        startupAttemptInProgress = true
        startupRecoveryComplete = false
        shutdownRequested = false
        guard !launchInProgress else {
            return finishStartupAttempt(false)
        }
        launchInProgress = true
        // A failed pause/edit/clear/shutdown leaves a durable stop obligation
        // on this controller. Settle that obligation before replay can launch
        // a fresh continuation; otherwise a later Goal action could retry the
        // stale run while the newly launched run keeps executing. Startup
        // never authorizes a global scheduler wake -- the host does that only
        // after this method returns true.
        await acquireStopLock()
        if var pending = pendingStop {
            pending.resumeDataPlaneOnSuccess = false
            pendingStop = pending
            guard await retryPendingStop(pending) else {
                releaseStopLock()
                launchInProgress = false
                return finishStartupAttempt(false)
            }
        }
        releaseStopLock()
        let replayed: [Envelope]
        do {
            let replay = try await log.replayForProjectionChecked()
            guard replay.hasCompleteKnownHistory else { throw EventLogError.unsupportedEventTypes }
            replayed = replay.envelopes
        } catch {
            launchInProgress = false
            return finishStartupAttempt(false)
        }
        guard startupMayProceed else { return await abortStartupAttempt() }
        if eventWatcher == nil {
            let nextSequence = (replayed.last?.seq ?? -1) + 1
            let stream = await log.stream(from: nextSequence)
            eventWatcher = Task { [weak self] in
                for await envelope in stream {
                    guard !Task.isCancelled else { return }
                    await self?.handle(envelope)
                }
            }
        }
        let replayedProjection = CoworkProjection.build(from: replayed)
        var interruptedScopeSafe = true
        if let recoveredGoal = replayedProjection.currentGoal {
            // Startup never wakes the global scheduler to finish an interrupted
            // run. Exact run fences also cover late/non-cooperative children
            // that were durably admitted after an older run checkpointed.
            // Cancel every run owning nonterminal Goal work while restored
            // pending work remains stopped, then checkpoint/reconcile.
            let interruptedRunIDs: Set<ContinuationRunID> = Set(
                replayedProjection.continuationRuns.values
                .filter {
                    $0.goalID == recoveredGoal.id
                        && ($0.status == .created || $0.status == .running)
                }
                .map(\.id) + replayedProjection.tasks.values.compactMap { task in
                    guard task.status.isTerminal == false,
                          task.contract?.goalID == recoveredGoal.id else { return nil }
                    return task.contract?.continuationRunID
                })
            for runID in interruptedRunIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
                let cancelled = await cancelGoalInvocations(
                    recoveredGoal.id,
                    runID,
                    "Recovering \(recoveredGoal.status.rawValue) Goal; cancelling interrupted invocations before checkpoint",
                    .runtime)
                interruptedScopeSafe = interruptedScopeSafe && cancelled
            }
            let hasUnscopedGoalWork = replayedProjection.tasks.values.contains { task in
                task.status.isTerminal == false
                    && task.contract?.goalID == recoveredGoal.id
                    && task.contract?.continuationRunID == nil
            }
            if hasUnscopedGoalWork {
                interruptedScopeSafe = await cancelGoalInvocations(
                    recoveredGoal.id,
                    nil,
                    "Recovering \(recoveredGoal.status.rawValue) Goal; cancelling unscoped invocations before checkpoint",
                    .runtime)
                    && interruptedScopeSafe
            }
        }
        guard startupMayProceed else { return await abortStartupAttempt() }
        guard eventWatcher != nil else {
            launchInProgress = false
            return finishStartupAttempt(false)
        }
        let recoveredEvents: [Envelope]
        do {
            let replay = try await log.replayForProjectionChecked()
            guard replay.hasCompleteKnownHistory else { throw EventLogError.unsupportedEventTypes }
            recoveredEvents = replay.envelopes
        } catch {
            launchInProgress = false
            return finishStartupAttempt(false)
        }
        let recoveredProjection = CoworkProjection.build(from: recoveredEvents)
        let recoveryDisposition: RecoveryDisposition
        if interruptedScopeSafe {
            recoveryDisposition = await recoverInterruptedRunIfNeeded(
                from: recoveredProjection,
                events: recoveredEvents)
        } else {
            recoveryDisposition = .failed
        }
        let reconciledDisposition: RecoveryDisposition
        switch recoveryDisposition {
        case .continueGoal:
            reconciledDisposition = await reconcileCheckpointedRunsIfNeeded()
        case .safeWithoutContinuation, .failed:
            reconciledDisposition = recoveryDisposition
        }
        guard startupMayProceed else { return await abortStartupAttempt() }
        launchInProgress = false
        let startupDisposition: RecoveryDisposition
        if case .continueGoal = reconciledDisposition {
            startupDisposition = await pauseRecoveredActiveGoalIfNeeded()
            if let startupPostRecoveryHook {
                await startupPostRecoveryHook()
            }
            guard startupMayProceed else { return await abortStartupAttempt() }
        } else {
            startupDisposition = reconciledDisposition
        }
        if case .failed = startupDisposition {
            return finishStartupAttempt(false)
        }
        startupRecoveryComplete = true
        return finishStartupAttempt(true)
    }

    private func finishStartupAttempt(_ result: Bool) -> Bool {
        startupAttemptInProgress = false
        let waiters = startupWaiters
        startupWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: result) }
        return result
    }

    private var startupMayProceed: Bool {
        !shutdownRequested && !Task.isCancelled
    }

    private func abortStartupAttempt() async -> Bool {
        eventWatcher?.cancel()
        eventWatcher = nil
        startupRecoveryComplete = false
        launchInProgress = false
        if continuationTask != nil {
            _ = await stopAutomaticContinuation(
                reason: "Goal runtime startup was cancelled",
                checkpoint: true,
                cancelInvocations: true,
                resumeDataPlaneOnSuccess: false,
                runCloseSource: shutdownRequested ? .hostLifecycle : .runtime)
        }
        return finishStartupAttempt(false)
    }

    /// Stops automatic execution while preserving an active Goal for restart.
    /// The current run is checkpointed after active invocations are cancelled.
    public func shutdown() async {
        shutdownRequested = true
        eventWatcher?.cancel()
        eventWatcher = nil
        startupRecoveryComplete = false
        await stopAutomaticContinuation(
            reason: "Goal runtime stopped",
            checkpoint: true,
            cancelInvocations: true,
            resumeDataPlaneOnSuccess: false,
            runCloseSource: .hostLifecycle)
    }

    public func currentGoal() async -> Goal? {
        CoworkProjection.build(from: await log.replay()).currentGoal
    }

    @discardableResult
    public func createGoal(objective: String,
                           successCriteria: [String] = [],
                           constraints: [String] = [],
                           tokenBudget: Int? = nil,
                           userMessage: UserMessagePayload? = nil) async throws -> Goal {
        await acquireGoalMutationLock()
        defer { releaseGoalMutationLock() }
        guard !Task.isCancelled,
              !shutdownRequested,
              !launchInProgress,
              eventWatcher == nil || startupRecoveryComplete,
              pendingStop == nil else { throw GoalRuntimeError.recoveryInProgress }
        let objective = Self.compact(objective)
        guard !objective.isEmpty else { throw GoalRuntimeError.emptyObjective }
        if let tokenBudget, tokenBudget <= 0 { throw GoalRuntimeError.invalidBudget }

        let projection = CoworkProjection.build(from: await log.replay())
        if let current = projection.currentGoal, current.status != .completed {
            throw GoalRuntimeError.currentGoalExists(current.id)
        }
        let goal: Goal
        if let goalAuthority {
            goal = try await goalAuthority.createGoal(
                request: GoalCreateRequest(
                    objective: objective,
                    successCriteria: Self.cleaned(successCriteria),
                    constraints: Self.cleaned(constraints),
                    tokenBudget: tokenBudget),
                mainAgentInferenceBinding: userMessage?.mainAgentInferenceBinding)
        } else {
            goal = Goal(
                sessionID: sessionID,
                objective: objective,
                successCriteria: Self.cleaned(successCriteria),
                constraints: Self.cleaned(constraints),
                tokenBudget: tokenBudget,
                mainAgentInferenceBinding: userMessage?.mainAgentInferenceBinding)
            try await append(.goalCreated(GoalCreatedPayload(goal: goal)))
        }
        await launchCurrentGoalIfEligible(allowDuringGoalMutation: true)
        return goal
    }

    @discardableResult
    public func editCurrentGoal(objective: String,
                                successCriteria: [String],
                                constraints: [String],
                                tokenBudget: Int?) async throws -> Goal {
        await acquireGoalMutationLock()
        defer { releaseGoalMutationLock() }
        guard !Task.isCancelled,
              !shutdownRequested,
              !launchInProgress,
              eventWatcher == nil || startupRecoveryComplete else {
            throw GoalRuntimeError.recoveryInProgress
        }
        let objective = Self.compact(objective)
        guard !objective.isEmpty else { throw GoalRuntimeError.emptyObjective }
        if let tokenBudget, tokenBudget <= 0 { throw GoalRuntimeError.invalidBudget }

        var projection = CoworkProjection.build(from: await log.replay())
        guard let current = projection.currentGoal else { throw GoalRuntimeError.noCurrentGoal }
        let wasActive = current.status == .active
        if wasActive {
            let safelyStopped = await stopAutomaticContinuation(
                reason: "Goal edited by user",
                checkpoint: true,
                cancelInvocations: true)
            guard safelyStopped else {
                throw GoalRuntimeError.persistence(
                    "Goal edit was not committed because the active run could not be durably cancelled and checkpointed.")
            }
            projection = CoworkProjection.build(from: await log.replay())
        }
        guard let latest = projection.goals[current.id] else { throw GoalRuntimeError.noCurrentGoal }
        do {
            let edited: Goal
            if let goalAuthority {
                edited = try await goalAuthority.editGoal(
                    request: GoalEditRequest(
                        goalID: latest.id,
                        expectedRevision: latest.revision,
                        objective: objective,
                        successCriteria: Self.cleaned(successCriteria),
                        constraints: Self.cleaned(constraints),
                        tokenBudget: tokenBudget),
                    hostAuthorized: true)
            } else {
                switch latest.edited(
                    objective: objective,
                    successCriteria: Self.cleaned(successCriteria),
                    constraints: Self.cleaned(constraints),
                    tokenBudget: tokenBudget,
                    expectedRevision: latest.revision) {
                case .success(let value):
                    edited = value
                case .failure(let violation):
                    throw Self.runtimeError(violation)
                }
                try await append(.goalEdited(GoalEditedPayload(
                    goal: edited,
                    previousRevision: latest.revision)))
            }
            if edited.status == .active {
                await launchCurrentGoalIfEligible(allowDuringGoalMutation: true)
            }
            return edited
        } catch {
            // The checkpoint is durable but the edit is not. Durable Goal
            // state still wins, so active execution resumes only through the
            // normal checkpoint-reconcile gate.
            if latest.status == .active {
                await launchCurrentGoalIfEligible(allowDuringGoalMutation: true)
            }
            throw error
        }
    }

    @discardableResult
    public func pauseCurrentGoal() async throws -> Goal {
        await acquireGoalMutationLock()
        defer { releaseGoalMutationLock() }
        guard !Task.isCancelled,
              !shutdownRequested,
              !launchInProgress,
              eventWatcher == nil || startupRecoveryComplete else {
            throw GoalRuntimeError.recoveryInProgress
        }
        var projection = CoworkProjection.build(from: await log.replay())
        guard let current = projection.currentGoal else { throw GoalRuntimeError.noCurrentGoal }
        if current.status == .active {
            let safelyStopped = await stopAutomaticContinuation(
                reason: "Goal paused by user",
                checkpoint: true,
                cancelInvocations: true)
            guard safelyStopped else {
                throw GoalRuntimeError.persistence(
                    "Goal pause was not committed because the active run could not be durably cancelled and checkpointed.")
            }
            projection = CoworkProjection.build(from: await log.replay())
        }
        guard let latest = projection.goals[current.id] else { throw GoalRuntimeError.noCurrentGoal }
        do {
            let paused: Goal
            if let goalAuthority {
                paused = try await goalAuthority.transitionGoal(
                    latest.id,
                    expectedRevision: latest.revision,
                    to: .paused,
                    canSubmitVerdict: false,
                    hostAuthorized: true)
            } else {
                switch latest.transitioning(to: .paused, expectedRevision: latest.revision) {
                case .success(let value): paused = value
                case .failure(let violation): throw Self.runtimeError(violation)
                }
                try await append(.goalPaused(GoalPausedPayload(goal: paused)))
            }
            return paused
        } catch {
            if latest.status == .active {
                await launchCurrentGoalIfEligible(allowDuringGoalMutation: true)
            }
            throw error
        }
    }

    @discardableResult
    public func resumeCurrentGoal() async throws -> Goal {
        await acquireGoalMutationLock()
        defer { releaseGoalMutationLock() }
        guard !Task.isCancelled,
              !shutdownRequested,
              !launchInProgress,
              eventWatcher == nil || startupRecoveryComplete,
              pendingStop == nil else { throw GoalRuntimeError.recoveryInProgress }
        let projection = CoworkProjection.build(from: await log.replay())
        guard let current = projection.currentGoal else { throw GoalRuntimeError.noCurrentGoal }
        let resumed: Goal
        if let goalAuthority {
            resumed = try await goalAuthority.transitionGoal(
                current.id,
                expectedRevision: current.revision,
                to: .active,
                canSubmitVerdict: false,
                hostAuthorized: true,
                resetNoProgress: true)
        } else {
            switch current.transitioning(to: .active, expectedRevision: current.revision) {
            case .success(var value):
                value.noProgressRuns = 0
                resumed = value
            case .failure(let violation):
                throw Self.runtimeError(violation)
            }
            try await append(.goalResumed(GoalResumedPayload(goal: resumed)))
        }
        await launchCurrentGoalIfEligible(allowDuringGoalMutation: true)
        return resumed
    }

    public func clearCurrentGoal(reason: String? = nil) async throws {
        await acquireGoalMutationLock()
        defer { releaseGoalMutationLock() }
        guard !Task.isCancelled,
              !shutdownRequested,
              !launchInProgress,
              eventWatcher == nil || startupRecoveryComplete else {
            throw GoalRuntimeError.recoveryInProgress
        }
        let projection = CoworkProjection.build(from: await log.replay())
        guard let current = projection.currentGoal else { throw GoalRuntimeError.noCurrentGoal }
        let safelyStopped = await stopAutomaticContinuation(
            reason: reason ?? "Goal cleared by user",
            checkpoint: true,
            cancelInvocations: true)
        guard safelyStopped else {
            throw GoalRuntimeError.persistence(
                "Goal clear was not committed because the active run could not be durably cancelled and checkpointed.")
        }
        let latest = CoworkProjection.build(from: await log.replay()).goals[current.id] ?? current
        do {
            if let goalAuthority {
                try await goalAuthority.clearGoal(
                    latest.id,
                    expectedRevision: latest.revision,
                    hostAuthorized: true)
            } else {
                try await append(.goalCleared(GoalClearedPayload(goal: latest, reason: reason)))
            }
        } catch {
            // The run checkpoint is already durable. If clear itself fails,
            // the still-active Goal must re-enter the ordinary reconcile gate
            // instead of becoming silently inert.
            if latest.status == .active {
                await launchCurrentGoalIfEligible(allowDuringGoalMutation: true)
            }
            throw error
        }
    }

    /// Runs a normal Cowork user turn inside a durable run scope. Normal turns
    /// never create a Goal; Goal creation is a separate explicit host action.
    @discardableResult
    public func sendUserTurn(_ text: String,
                             to target: AgentID? = nil,
                             images: [ImageAttachment] = [],
                             userMessage: UserMessagePayload? = nil,
                             recordUserMessage: Bool = true) async -> OrchestratorSendResult {
        await acquireGoalMutationLock()
        defer { releaseGoalMutationLock() }
        guard !Task.isCancelled,
              !shutdownRequested,
              !launchInProgress,
              eventWatcher == nil || startupRecoveryComplete,
              pendingStop == nil else {
            return .failed("Goal recovery or a durable stop is incomplete; retry after the session is ready.")
        }
        let projection = CoworkProjection.build(from: await log.replay())
        guard !Task.isCancelled, !shutdownRequested else {
            return .failed("Cowork runtime stopped before turn admission.")
        }
        if continuationTask != nil,
           let current = projection.currentGoal,
           current.status == .active {
            return .failed(
                "Goal \(current.id.rawValue) is actively continuing; pause or clear it before sending an unrelated Cowork turn.")
        }
        let run = ContinuationRun(sessionID: sessionID, ordinal: 0)
        do {
            try await append(.continuationRunCreated(ContinuationRunCreatedPayload(run: run)))
            if Task.isCancelled || shutdownRequested {
                let interrupted = try run.transitioning(
                    to: .interrupted,
                    progressSummary: "Cowork runtime stopped before turn start").get()
                try await append(.continuationRunInterrupted(
                    ContinuationRunInterruptedPayload(
                        run: interrupted,
                        reason: "Cowork runtime stopped before turn start")))
                return .failed("Cowork runtime stopped before turn start.")
            }
            let started = try run.transitioning(to: .running).get()
            try await append(.continuationRunStarted(ContinuationRunStartedPayload(run: started)))
            if Task.isCancelled || shutdownRequested {
                let interrupted = try started.transitioning(
                    to: .interrupted,
                    progressSummary: "Cowork runtime stopped before provider dispatch").get()
                try await append(.continuationRunInterrupted(
                    ContinuationRunInterruptedPayload(
                        run: interrupted,
                        reason: "Cowork runtime stopped before provider dispatch")))
                return .failed("Cowork runtime stopped before provider dispatch.")
            }
            let result = await sendOperation(
                text,
                target,
                images,
                userMessage,
                nil,
                run.id,
                recordUserMessage)
            await waitForSchedulerIdle()
            let closeReplay = try await log.replayForProjectionChecked()
            guard closeReplay.hasCompleteKnownHistory else {
                throw EventLogError.incompleteEventHistory
            }
            let closeProjection = CoworkProjection.build(from: closeReplay.envelopes)
            guard closeProjection.ambiguousContinuationRunCloseClaimIDs.isEmpty else {
                throw EventLogError.conflictingContinuationRunCloseClaim
            }
            let closeClaim = closeProjection.continuationRunCloseClaims[run.id]
            switch result {
            case .sent:
                switch closeClaim?.requestedOutcome {
                case nil, .completed:
                    let completed = try started.transitioning(to: .completed).get()
                    try await append(.continuationRunCompleted(
                        ContinuationRunCompletedPayload(run: completed)))
                case .stopped, .cancelled:
                    let reason = closeClaim?.reason ?? "Cowork run cancelled"
                    let cancelled = try started.transitioning(
                        to: .cancelled,
                        progressSummary: reason).get()
                    try await append(.continuationRunCancelled(
                        ContinuationRunCancelledPayload(
                            run: cancelled,
                            reason: reason)))
                case .timedOut, .failed, .interrupted:
                    let reason = closeClaim?.reason ?? "Cowork run interrupted"
                    let interrupted = try started.transitioning(
                        to: .interrupted,
                        progressSummary: reason).get()
                    try await append(.continuationRunInterrupted(
                        ContinuationRunInterruptedPayload(
                            run: interrupted,
                            reason: reason)))
                }
            case .failed(let message):
                let interrupted = try started.transitioning(
                    to: .interrupted,
                    progressSummary: message).get()
                try await append(.continuationRunInterrupted(
                    ContinuationRunInterruptedPayload(run: interrupted, reason: message)))
            }
            await launchCurrentGoalIfEligible(allowDuringGoalMutation: true)
            return result
        } catch {
            let message = "Cowork run persistence failed: \(error.localizedDescription)"
            _ = try? await log.append(.error(ErrorPayload(code: "continuation_run", message: message)))
            // The provider may already have durably created a Goal while this
            // ordinary-run mutation lock was held. Its goalCreated watcher can
            // therefore observe the event but decline to launch. If settling
            // this enclosing run then fails, replay durable truth and give the
            // active Goal the same guarded launch opportunity before returning;
            // shutdown, cancellation, and pending-stop fences still win.
            let durableProjection = CoworkProjection.build(from: await log.replay())
            if durableProjection.currentGoal?.status == .active {
                await launchCurrentGoalIfEligible(allowDuringGoalMutation: true)
            }
            return .failed(message)
        }
    }

    // MARK: - Durable event observation

    private func handle(_ envelope: Envelope) async {
        // A cancelled stream may already have passed its local cancellation
        // check before shutdown. Lifecycle state is the final authority: stale
        // deliveries cannot relaunch or stop work after the runtime closed, and
        // recovery events are reconciled by `start()` rather than the watcher.
        guard startupRecoveryComplete else { return }
        switch envelope.event {
        case .goalCreated(let payload):
            guard payload.goal.sessionID == sessionID else { return }
            await launchCurrentGoalIfEligible()
        case .goalResumed(let payload):
            guard payload.goal.sessionID == sessionID else { return }
            await launchCurrentGoalIfEligible()
        case .goalEdited(let payload):
            guard payload.goal.sessionID == sessionID else { return }
            if payload.goal.status == .active, continuationTask == nil {
                await launchCurrentGoalIfEligible()
            }
        case .goalPaused(let payload):
            guard payload.goal.sessionID == sessionID,
                  runningGoalID == payload.goal.id,
                  await isLatestDurableGoalSnapshot(payload.goal) else { return }
            await stopAutomaticContinuation(
                reason: "Goal entered \(payload.goal.status.rawValue)",
                checkpoint: true,
                cancelInvocations: true,
                runCloseSource: .runtime)
        case .goalBlocked(let payload):
            guard payload.goal.sessionID == sessionID,
                  runningGoalID == payload.goal.id,
                  await isLatestDurableGoalSnapshot(payload.goal) else { return }
            await stopAutomaticContinuation(
                reason: "Goal entered \(payload.goal.status.rawValue)",
                checkpoint: true,
                cancelInvocations: true,
                runCloseSource: .runtime)
        case .goalBudgetLimited(let payload):
            guard payload.goal.sessionID == sessionID,
                  runningGoalID == payload.goal.id,
                  await isLatestDurableGoalSnapshot(payload.goal) else { return }
            await stopAutomaticContinuation(
                reason: "Goal entered \(payload.goal.status.rawValue)",
                checkpoint: true,
                cancelInvocations: true,
                runCloseSource: .runtime)
        case .goalUsageLimited(let payload):
            guard payload.goal.sessionID == sessionID,
                  runningGoalID == payload.goal.id,
                  await isLatestDurableGoalSnapshot(payload.goal) else { return }
            await stopAutomaticContinuation(
                reason: payload.reason ?? "Goal provider usage is limited",
                checkpoint: true,
                cancelInvocations: true,
                runCloseSource: .runtime)
        case .goalCompleted(let payload):
            guard payload.goal.sessionID == sessionID,
                  runningGoalID == payload.goal.id,
                  await isLatestDurableGoalSnapshot(payload.goal) else { return }
            await stopAutomaticContinuation(
                reason: "Goal entered \(payload.goal.status.rawValue)",
                checkpoint: true,
                cancelInvocations: false,
                runCloseSource: .runtime)
        case .goalCleared(let payload):
            guard payload.goal.sessionID == sessionID,
                  runningGoalID == payload.goal.id,
                  await isLatestDurableGoalClear(payload.goal) else { return }
            await stopAutomaticContinuation(
                reason: "Goal cleared",
                checkpoint: true,
                cancelInvocations: false,
                runCloseSource: .runtime)
        default:
            break
        }
    }

    private func isLatestDurableGoalSnapshot(_ snapshot: Goal) async -> Bool {
        let projection = CoworkProjection.build(from: await log.replay())
        guard projection.currentGoalID == snapshot.id,
              let current = projection.goals[snapshot.id] else { return false }
        return current.revision == snapshot.revision
            && current.status == snapshot.status
    }

    private func isLatestDurableGoalClear(_ snapshot: Goal) async -> Bool {
        let projection = CoworkProjection.build(from: await log.replay())
        guard projection.currentGoalID == nil,
              let cleared = projection.goals[snapshot.id] else { return false }
        return cleared.revision == snapshot.revision
    }

    private func recoverInterruptedRunIfNeeded(
        from projection: CoworkProjection,
        events: [Envelope]
    ) async -> RecoveryDisposition {
        let uncertainNonReplayable = projection.uncertainNonReplayableToolExecutions
        let interrupted = projection.continuationRuns.values
            .filter { $0.status == .created || $0.status == .running }
            .sorted { lhs, rhs in
                if lhs.ordinal == rhs.ordinal { return lhs.startedAt < rhs.startedAt }
                return lhs.ordinal < rhs.ordinal
            }
        for run in interrupted {
            do {
                let recovered = try run.transitioning(
                    to: .interrupted,
                    progressSummary: "Recovered after runtime interruption").get()
                try await append(.continuationRunInterrupted(
                    ContinuationRunInterruptedPayload(
                        run: recovered,
                        reason: "Recovered after runtime interruption")))
            } catch {
                await recordRuntimeError(
                    code: "goal_run_recovery",
                    message: "Could not interrupt recovered run \(run.id.rawValue): \(error.localizedDescription)")
                return .failed
            }
        }
        guard let goal = projection.currentGoal else {
            // A non-replayable executor outcome remains an audit/retry concern
            // for its owning task, but a durably terminal task cannot be replayed
            // by this Goal runtime. Keep fail-closed behavior for unscoped
            // tickets, missing task history, and every nonterminal task because
            // their execution scope cannot be proven inert.
            let allExecutionsAreConfinedToTerminalTasks = uncertainNonReplayable.allSatisfy {
                Self.isExecutionConfinedToTerminalTask(
                    $0,
                    projection: projection,
                    events: events)
            }
            return allExecutionsAreConfinedToTerminalTasks
                ? .safeWithoutContinuation
                : .failed
        }
        guard uncertainNonReplayable.isEmpty else { return .failed }
        return goal.status == .active ? .continueGoal : .safeWithoutContinuation
    }

    /// Converts a cold-restored active Goal into an explicit paused state after
    /// all interrupted runs and unaudited checkpoints have been reconciled.
    /// The exact revision is read from complete-known durable history and the
    /// authority CAS must succeed before startup can release the data plane.
    private func pauseRecoveredActiveGoalIfNeeded() async -> RecoveryDisposition {
        let projection: CoworkProjection
        do {
            let replay = try await log.replayForProjectionChecked()
            guard replay.hasCompleteKnownHistory else {
                throw EventLogError.unsupportedEventTypes
            }
            projection = CoworkProjection.build(from: replay.envelopes)
        } catch {
            return .failed
        }
        guard let current = projection.currentGoal else {
            return .safeWithoutContinuation
        }
        guard current.status == .active else {
            return .safeWithoutContinuation
        }
        let recoveredStatus: GoalStatus
        if let budget = current.tokenBudget, current.tokensUsed >= budget {
            // Startup previously reached this durable limit through the launch
            // gate. Recovery-only startup must preserve the same hard stop
            // without momentarily presenting the Goal as resumable.
            recoveredStatus = .budgetLimited
        } else {
            recoveredStatus = .paused
        }
        do {
            if let goalAuthority {
                _ = try await goalAuthority.transitionGoal(
                    current.id,
                    expectedRevision: current.revision,
                    to: recoveredStatus,
                    canSubmitVerdict: false,
                    hostAuthorized: true)
            } else {
                let recovered: Goal
                switch current.transitioning(
                    to: recoveredStatus,
                    expectedRevision: current.revision) {
                case .success(let value):
                    recovered = value
                case .failure(let violation):
                    throw Self.runtimeError(violation)
                }
                switch recoveredStatus {
                case .paused:
                    try await append(.goalPaused(GoalPausedPayload(goal: recovered)))
                case .budgetLimited:
                    try await append(.goalBudgetLimited(
                        GoalBudgetLimitedPayload(goal: recovered)))
                default:
                    preconditionFailure("Unexpected recovered Goal status")
                }
            }
            return .safeWithoutContinuation
        } catch {
            await recordRuntimeError(
                code: "goal_startup_pause",
                message: "Could not pause the recovered Goal: \(error.localizedDescription)")
            return .failed
        }
    }

    private static func isExecutionConfinedToTerminalTask(
        _ execution: CoworkToolExecutionView,
        projection: CoworkProjection,
        events: [Envelope]
    ) -> Bool {
        guard let taskID = execution.prepared.taskID,
              let preparedAttempt = execution.prepared.attempt,
              preparedAttempt > 0,
              let task = projection.tasks[taskID],
              let contract = task.contract,
              contract.id == taskID,
              task.status.isTerminal,
              task.attempt == preparedAttempt else { return false }

        let contractExistedBeforePrepare = events.contains { envelope in
            guard envelope.seq < execution.preparedSeq,
                  case .taskCreated(let payload) = envelope.event else {
                return false
            }
            return payload.contract == contract
        }
        guard contractExistedBeforePrepare else { return false }

        return events.contains { envelope in
            guard envelope.seq > execution.preparedSeq else { return false }
            switch envelope.event {
            case .taskCompleted(let payload):
                return payload.taskID == taskID && payload.attempt == preparedAttempt
            case .taskFailed(let payload):
                return payload.taskID == taskID && payload.attempt == preparedAttempt
            case .taskCancelled(let payload):
                return payload.taskID == taskID && payload.attempt == preparedAttempt
            default:
                return false
            }
        }
    }

    /// A checkpoint is a safe execution boundary but not a completed run. If a
    /// process stopped between checkpoint and atomic audit settlement, close
    /// that run conservatively before launching another one. This prevents
    /// orphaned checkpoints, double usage accounting, and lost durable provider
    /// hard-limit signals.
    private func reconcileCheckpointedRunsIfNeeded() async -> RecoveryDisposition {
        while true {
            let replayed: [Envelope]
            do {
                let replay = try await log.replayForProjectionChecked()
                guard replay.hasCompleteKnownHistory else {
                    throw EventLogError.unsupportedEventTypes
                }
                replayed = replay.envelopes
            } catch {
                return .failed
            }
            let projection = CoworkProjection.build(from: replayed)
            guard let currentGoal = projection.currentGoal else {
                return .safeWithoutContinuation
            }
            guard currentGoal.status == .active else { return .safeWithoutContinuation }
            let auditedRunIDs = Set(replayed.compactMap { envelope -> ContinuationRunID? in
                guard case .goalAuditCompleted(let payload) = envelope.event else { return nil }
                return payload.runID
            })
            let unauditedCheckpointedRuns = projection.continuationRuns.values
                .filter {
                    $0.goalID == currentGoal.id
                        && $0.status == .checkpointed
                        && !auditedRunIDs.contains($0.id)
                }
                .sorted(by: { lhs, rhs in
                    if lhs.ordinal == rhs.ordinal { return lhs.startedAt < rhs.startedAt }
                    return lhs.ordinal < rhs.ordinal
                })
            guard let checkpointed = unauditedCheckpointedRuns.first else {
                return .continueGoal
            }

            let usageReason = await consumeProviderUsageLimit(
                currentGoal.id,
                checkpointed.id)
            let reason = usageReason
                ?? "Recovered checkpoint had no durable Goal audit; continuing conservatively."
            let audit = Self.fallbackAudit(goal: currentGoal, reason: reason)
            let checkpointedAt = replayed.last(where: { envelope in
                switch envelope.event {
                case .continuationRunCheckpointed(let payload):
                    return payload.run.id == checkpointed.id
                default:
                    return false
                }
            })?.ts ?? checkpointed.startedAt
            let elapsed = max(0, checkpointedAt.timeIntervalSince(checkpointed.startedAt))
            let tokenDelta = Self.tokens(
                for: checkpointed.id,
                goalID: currentGoal.id,
                in: replayed)
            do {
                let settledGoal: Goal
                if let goalAuthority {
                    settledGoal = try await goalAuthority.settleGoalRunAudit(
                        audit,
                        goalID: currentGoal.id,
                        runID: checkpointed.id,
                        expectedRevision: currentGoal.revision,
                        tokenDelta: tokenDelta,
                        activeElapsedDelta: elapsed,
                        runProgressSummary: Self.auditSummary(audit),
                        usageLimitReason: usageReason,
                        blockedRunThreshold: policy.blockedRunThreshold).goal
                } else {
                    var audited = try currentGoal.applyingAudit(
                        audit,
                        expectedRevision: currentGoal.revision).get()
                    audited.tokensUsed = Self.saturatingAdd(
                        currentGoal.tokensUsed,
                        tokenDelta)
                    audited.activeElapsedSeconds += elapsed
                    Self.applyBlockerAccounting(to: &audited, audit: audit)
                    let completedRun = try checkpointed.transitioning(
                        to: .completed,
                        progressSummary: Self.auditSummary(audit)).get()
                    var events: [Event] = [
                        .goalAuditCompleted(GoalAuditCompletedPayload(
                            goal: audited,
                            audit: audit,
                            runID: checkpointed.id)),
                        .continuationRunCompleted(
                            ContinuationRunCompletedPayload(run: completedRun)),
                    ]
                    if let usageReason {
                        let limited = try audited.transitioning(
                            to: .usageLimited,
                            expectedRevision: audited.revision).get()
                        events.append(.goalUsageLimited(GoalUsageLimitedPayload(
                            goal: limited,
                            reason: usageReason)))
                        settledGoal = limited
                    } else {
                        settledGoal = audited
                    }
                    try await append(events)
                }
                if settledGoal.status != .active { return .safeWithoutContinuation }
            } catch {
                await recordRuntimeError(
                    code: "goal_checkpoint_reconcile",
                    message: "Could not settle recovered Goal run \(checkpointed.id.rawValue): \(error.localizedDescription)")
                return .failed
            }
        }
    }

    private func launchCurrentGoalIfEligible(
        allowDuringGoalMutation: Bool = false
    ) async {
        guard !shutdownRequested,
              !Task.isCancelled,
              pendingStop == nil,
              !stopLockHeld,
              (!goalMutationLockHeld || allowDuringGoalMutation),
              continuationTask == nil,
              !launchInProgress else { return }
        launchInProgress = true
        defer { launchInProgress = false }
        let initialProjection: CoworkProjection
        do {
            let replay = try await log.replayForProjectionChecked()
            guard replay.hasCompleteKnownHistory else {
                throw EventLogError.unsupportedEventTypes
            }
            initialProjection = CoworkProjection.build(from: replay.envelopes)
        } catch {
            return
        }
        guard !shutdownRequested,
              !Task.isCancelled,
              pendingStop == nil,
              !stopLockHeld,
              (!goalMutationLockHeld || allowDuringGoalMutation) else { return }
        guard initialProjection.uncertainNonReplayableToolExecutions.isEmpty,
              initialProjection.currentGoal?.status == .active else { return }
        // Pause/edit/shutdown can create a safe checkpoint without restarting
        // the process. Reconcile it through the same once-per-run settlement
        // gate used by crash recovery before any later continuation is launched.
        guard case .continueGoal = await reconcileCheckpointedRunsIfNeeded() else { return }
        guard !shutdownRequested,
              !Task.isCancelled,
              pendingStop == nil,
              !stopLockHeld,
              (!goalMutationLockHeld || allowDuringGoalMutation) else { return }
        let projection: CoworkProjection
        do {
            let replay = try await log.replayForProjectionChecked()
            guard replay.hasCompleteKnownHistory else {
                throw EventLogError.unsupportedEventTypes
            }
            projection = CoworkProjection.build(from: replay.envelopes)
        } catch {
            return
        }
        guard !shutdownRequested,
              !Task.isCancelled,
              pendingStop == nil,
              !stopLockHeld,
              (!goalMutationLockHeld || allowDuringGoalMutation),
              continuationTask == nil else { return }
        guard projection.uncertainNonReplayableToolExecutions.isEmpty,
              let goal = projection.currentGoal,
              goal.status == .active else { return }
        let isAccumulatingRequiredBlockerProof = goal.latestAudit?.verdict == .blockedCandidate
            && goal.consecutiveBlockedRuns == goal.noProgressRuns
            && goal.consecutiveBlockedRuns < policy.blockedRunThreshold
        guard goal.noProgressRuns < policy.noProgressRunThreshold
            || isAccumulatingRequiredBlockerProof else { return }
        if let budget = goal.tokenBudget, goal.tokensUsed >= budget {
            await markBudgetLimited(goal)
            return
        }

        continuationGeneration += 1
        let generation = continuationGeneration
        runningGoalID = goal.id
        continuationTask = Task { [weak self] in
            guard let self else { return }
            await self.runGoalLoop(goalID: goal.id, generation: generation)
            await self.continuationDidFinish(generation: generation)
        }
    }

    @discardableResult
    private func stopAutomaticContinuation(reason: String,
                                           checkpoint: Bool,
                                           cancelInvocations: Bool,
                                           resumeDataPlaneOnSuccess: Bool = true,
                                           runCloseSource: ContinuationRunCloseSource = .user) async -> Bool {
        await acquireStopLock()
        defer { releaseStopLock() }

        if var pending = pendingStop {
            // A shutdown retry must never inherit an earlier UI action's
            // request to wake unrelated pending work or mislabel a newly
            // successful host-lifecycle close as the earlier requester.
            pending.resumeDataPlaneOnSuccess =
                pending.resumeDataPlaneOnSuccess && resumeDataPlaneOnSuccess
            if runCloseSource == .hostLifecycle {
                pending.request.runCloseSource = .hostLifecycle
            }
            pendingStop = pending
            return await retryPendingStop(pending)
        }

        guard let task = continuationTask else {
            if let discovered = await discoverPendingStop(
                reason: reason,
                checkpoint: checkpoint,
                cancelInvocations: cancelInvocations,
                resumeDataPlaneOnSuccess: resumeDataPlaneOnSuccess,
                runCloseSource: runCloseSource) {
                pendingStop = discovered
                return await retryPendingStop(discovered)
            }
            return true
        }
        let generation = continuationGeneration
        let goalID = runningGoalID
        let runID = runningContinuationRunID
        let request = StopRequest(
            reason: reason,
            checkpoint: checkpoint,
            runCloseSource: runCloseSource)
        stopRequests[generation] = request
        task.cancel()
        var cancellationSucceeded = true
        if cancelInvocations {
            if let goalID {
                cancellationSucceeded = await cancelGoalInvocations(
                    goalID,
                    runID,
                    reason,
                    runCloseSource)
            } else {
                await cancelActiveInvocations(reason, runCloseSource)
            }
        }
        await task.value
        let settlementFailure = stopSettlementFailures.removeValue(forKey: generation)
        var effectiveGoalID = goalID
        var effectiveRunID = runID
        let durableProjection = CoworkProjection.build(from: await log.replay())
        effectiveGoalID = effectiveGoalID ?? durableProjection.currentGoalID
        let interruptedRuns: [ContinuationRun]
        if let effectiveGoalID {
            interruptedRuns = durableProjection.continuationRuns.values
                .filter {
                    $0.goalID == effectiveGoalID
                        && (effectiveRunID == nil || $0.id == effectiveRunID)
                        && ($0.status == .created || $0.status == .running)
                }
                .sorted { $0.ordinal < $1.ordinal }
            if effectiveRunID == nil, interruptedRuns.count == 1 {
                effectiveRunID = interruptedRuns[0].id
            }
        } else {
            interruptedRuns = []
        }
        // In-memory cancellation/failure bookkeeping is advisory. A Goal
        // mutation is safe only when replay proves the scoped run is no longer
        // created/running. This closes races with run-start, interruption, and
        // checkpoint persistence failures that can make the continuation task
        // exit without recording `stopSettlementFailures`.
        let stoppedSafely = cancellationSucceeded
            && settlementFailure == nil
            && interruptedRuns.isEmpty
        if continuationGeneration == generation {
            continuationTask = nil
            runningGoalID = nil
            runningContinuationRunID = nil
        }
        stopRequests[generation] = nil
        if stoppedSafely {
            pendingStop = nil
            if resumeDataPlaneOnSuccess,
               !shutdownRequested,
               !Task.isCancelled {
                await resumePendingInvocations()
            }
            return true
        }
        if let effectiveGoalID {
            let pending = PendingStop(
                goalID: effectiveGoalID,
                runID: effectiveRunID,
                request: request,
                cancelInvocations: cancelInvocations,
                resumeDataPlaneOnSuccess: resumeDataPlaneOnSuccess)
            pendingStop = pending
            // Retry immediately: transient cancellation/checkpoint failures can
            // still settle this user action, while persistent failures remain
            // recorded as a pending stop for the next attempt/start.
            return await retryPendingStop(pending)
        }
        return false
    }

    private func acquireStopLock() async {
        if !stopLockHeld {
            stopLockHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            stopLockWaiters.append(continuation)
        }
    }

    private func releaseStopLock() {
        if stopLockWaiters.isEmpty {
            stopLockHeld = false
        } else {
            stopLockWaiters.removeFirst().resume()
        }
    }

    private func acquireGoalMutationLock() async {
        if !goalMutationLockHeld {
            goalMutationLockHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            goalMutationLockWaiters.append(continuation)
        }
    }

    private func releaseGoalMutationLock() {
        if goalMutationLockWaiters.isEmpty {
            goalMutationLockHeld = false
        } else {
            goalMutationLockWaiters.removeFirst().resume()
        }
    }

    private func discoverPendingStop(reason: String,
                                     checkpoint: Bool,
                                     cancelInvocations: Bool,
                                     resumeDataPlaneOnSuccess: Bool,
                                     runCloseSource: ContinuationRunCloseSource) async -> PendingStop? {
        let projection = CoworkProjection.build(from: await log.replay())
        guard let goal = projection.currentGoal else { return nil }
        let interrupted = projection.continuationRuns.values.filter {
            $0.goalID == goal.id && ($0.status == .created || $0.status == .running)
        }
        let nonterminalTaskRunIDs: Set<ContinuationRunID> = Set(
            projection.tasks.values.compactMap { task in
            guard task.status.isTerminal == false,
                  task.contract?.goalID == goal.id else { return nil }
            return task.contract?.continuationRunID
        })
        let hasUnscopedNonterminalTask = projection.tasks.values.contains { task in
            task.status.isTerminal == false
                && task.contract?.goalID == goal.id
                && task.contract?.continuationRunID == nil
        }
        guard !interrupted.isEmpty
            || !nonterminalTaskRunIDs.isEmpty
            || hasUnscopedNonterminalTask else { return nil }
        let scopedRunIDs = Set(interrupted.map(\.id)).union(nonterminalTaskRunIDs)
        return PendingStop(
            goalID: goal.id,
            runID: !hasUnscopedNonterminalTask && scopedRunIDs.count == 1
                ? scopedRunIDs.first
                : nil,
            request: StopRequest(
                reason: reason,
                checkpoint: checkpoint,
                runCloseSource: runCloseSource),
            cancelInvocations: cancelInvocations,
            resumeDataPlaneOnSuccess: resumeDataPlaneOnSuccess)
    }

    private func retryPendingStop(_ pending: PendingStop) async -> Bool {
        if pending.cancelInvocations {
            let cancelled = await cancelGoalInvocations(
                pending.goalID,
                pending.runID,
                pending.request.reason,
                pending.request.runCloseSource)
            guard cancelled else {
                pendingStop = pending
                return false
            }
        }

        let projection = CoworkProjection.build(from: await log.replay())
        let interrupted = projection.continuationRuns.values
            .filter {
                $0.goalID == pending.goalID
                    && (pending.runID == nil || $0.id == pending.runID)
                    && ($0.status == .created || $0.status == .running)
            }
            .sorted { $0.ordinal < $1.ordinal }
        do {
            let events = try interrupted.map { run -> Event in
                if pending.request.checkpoint {
                    let checkpointed = try run.transitioning(
                        to: .checkpointed,
                        progressSummary: pending.request.reason).get()
                    return .continuationRunCheckpointed(
                        ContinuationRunCheckpointedPayload(run: checkpointed))
                }
                let cancelled = try run.transitioning(
                    to: .cancelled,
                    progressSummary: pending.request.reason).get()
                return .continuationRunCancelled(
                    ContinuationRunCancelledPayload(
                        run: cancelled,
                        reason: pending.request.reason))
            }
            if !events.isEmpty { try await append(events) }
        } catch {
            pendingStop = pending
            await recordRuntimeError(
                code: "goal_run_stop_retry",
                message: "Could not settle a previously stopped Goal run: \(error.localizedDescription)")
            return false
        }

        pendingStop = nil
        runningGoalID = nil
        runningContinuationRunID = nil
        if pending.resumeDataPlaneOnSuccess,
           !shutdownRequested,
           !Task.isCancelled {
            await resumePendingInvocations()
        }
        return true
    }

    private func continuationDidFinish(generation: Int) {
        guard continuationGeneration == generation else { return }
        continuationTask = nil
        runningGoalID = nil
        runningContinuationRunID = nil
        stopRequests[generation] = nil
    }

    // MARK: - Goal loop

    private func runGoalLoop(goalID: GoalID, generation: Int) async {
        while !Task.isCancelled, continuationGeneration == generation {
            let projection = CoworkProjection.build(from: await log.replay())
            guard projection.currentGoalID == goalID,
                  let goal = projection.goals[goalID],
                  goal.status == .active else { return }
            let isAccumulatingRequiredBlockerProof = goal.latestAudit?.verdict == .blockedCandidate
                && goal.consecutiveBlockedRuns == goal.noProgressRuns
                && goal.consecutiveBlockedRuns < policy.blockedRunThreshold
            if goal.noProgressRuns >= policy.noProgressRunThreshold,
               !isAccumulatingRequiredBlockerProof { return }
            if let budget = goal.tokenBudget, goal.tokensUsed >= budget {
                await markBudgetLimited(goal)
                return
            }
            let disposition = await performContinuation(
                for: goal,
                projection: projection,
                generation: generation)
            switch disposition {
            case .continueGoal:
                continue
            case .stopGoal, .stopped:
                return
            }
        }
    }

    private func performContinuation(for startingGoal: Goal,
                                     projection initialProjection: CoworkProjection,
                                     generation: Int) async -> RunDisposition {
        let ordinal = initialProjection.continuationRuns.values
            .filter { $0.goalID == startingGoal.id }
            .map(\.ordinal)
            .max().map { $0 + 1 } ?? 1
        let created = ContinuationRun(
            sessionID: sessionID,
            goalID: startingGoal.id,
            ordinal: ordinal)
        if continuationGeneration == generation, runningGoalID == startingGoal.id {
            runningContinuationRunID = created.id
        }
        let runStart = Date()
        var running: ContinuationRun
        do {
            try await append(.continuationRunCreated(
                ContinuationRunCreatedPayload(run: created)))
            running = try created.transitioning(to: .running).get()
            try await append(.continuationRunStarted(
                ContinuationRunStartedPayload(run: running)))
            try await append(.goalContinuationScheduled(
                GoalContinuationScheduledPayload(goal: startingGoal, runID: running.id)))
        } catch {
            await recordRuntimeError(
                code: "goal_run_start",
                message: "Could not start Goal run: \(error.localizedDescription)")
            return .stopGoal
        }

        if Task.isCancelled || continuationGeneration != generation {
            await settleStoppedRun(running, generation: generation)
            return .stopped
        }

        let runProjection = CoworkProjection.build(from: await log.replay())
        if Task.isCancelled || continuationGeneration != generation {
            await settleStoppedRun(running, generation: generation)
            return .stopped
        }
        let runGoal = runProjection.goals[startingGoal.id] ?? startingGoal
        let baseline = Self.signature(goal: runGoal, projection: runProjection)
        let prompt = Self.continuationPrompt(goal: runGoal, run: running)
        let inferenceBoundUserMessage = runGoal.mainAgentInferenceBinding.map { binding in
            UserMessagePayload(
                text: prompt,
                mainAgentInferenceBinding: binding)
        }
        let sendResult = await sendOperation(
            prompt,
            Orchestrator.mainAgentID,
            [],
            inferenceBoundUserMessage,
            startingGoal.id,
            running.id,
            false)
        await waitForGoalSchedulerIdle(startingGoal.id, running.id)

        if Task.isCancelled || continuationGeneration != generation {
            await settleStoppedRun(running, generation: generation)
            return .stopped
        }

        switch sendResult {
        case .sent:
            break
        case .failed(let message):
            do {
                let interrupted = try running.transitioning(
                    to: .interrupted,
                    progressSummary: message).get()
                try await append(.continuationRunInterrupted(
                    ContinuationRunInterruptedPayload(
                        run: interrupted,
                        reason: message)))
            } catch {
                await recordRuntimeError(
                    code: "goal_run_interrupt",
                    message: "Could not persist interrupted Goal run: \(error.localizedDescription)")
            }
            return .stopGoal
        }
        let checkpointed: ContinuationRun
        do {
            checkpointed = try running.transitioning(
                to: .checkpointed,
                progressSummary: "@main and required scheduled invocations reached the run barrier.").get()
            try await append(.continuationRunCheckpointed(
                ContinuationRunCheckpointedPayload(run: checkpointed)))
        } catch {
            await recordRuntimeError(
                code: "goal_run_checkpoint",
                message: "Could not checkpoint Goal run: \(error.localizedDescription)")
            return .stopGoal
        }

        if Task.isCancelled || continuationGeneration != generation {
            await settleStoppedRun(checkpointed, generation: generation)
            return .stopped
        }

        let verificationEvents = await log.replay()
        let beforeVerification = CoworkProjection.build(from: verificationEvents)
        let validationEvidence = Self.durableValidationEvidence(
            goalID: startingGoal.id,
            projection: beforeVerification,
            events: verificationEvents)
        let model = await verifierModel()
        let verificationStart = Date()
        let verification: GoalVerificationResult
        if let reason = await consumeProviderUsageLimit(startingGoal.id, running.id) {
            verification = GoalVerificationResult(
                audit: Self.fallbackAudit(goal: runGoal, reason: reason),
                failureKind: .usageLimit,
                reason: reason)
        } else {
            do {
                let verifier = try await verifier(for: model)
                verification = await verifier.verify(GoalVerificationInput(
                    goal: beforeVerification.goals[startingGoal.id] ?? startingGoal,
                    run: checkpointed,
                    runHistory: Self.runHistory(
                        goalID: startingGoal.id,
                        excluding: running.id,
                        projection: beforeVerification,
                        limit: policy.maximumRunHistoryItems),
                    validationEvidence: validationEvidence))
            } catch {
                let reason = "Goal verifier provider is unavailable: \(error.localizedDescription)"
                verification = GoalVerificationResult(
                    audit: Self.fallbackAudit(goal: startingGoal, reason: reason),
                    failureKind: .providerFailure,
                    reason: reason)
            }
        }
        if Task.isCancelled || continuationGeneration != generation {
            await settleStoppedRun(checkpointed, generation: generation)
            return .stopped
        }
        let verifierMillis = Self.milliseconds(since: verificationStart)
        await appendVerifierStats(
            verification.usage,
            model: model,
            runID: running.id,
            goalID: startingGoal.id,
            totalMillis: verifierMillis)

        if Task.isCancelled || continuationGeneration != generation {
            await settleStoppedRun(checkpointed, generation: generation)
            return .stopped
        }

        let afterVerification = CoworkProjection.build(from: await log.replay())
        guard let currentGoal = afterVerification.goals[startingGoal.id],
              currentGoal.status == .active else {
            await settleStoppedRun(checkpointed, generation: generation)
            return .stopped
        }
        var audit = verification.audit
        let finalSignature = Self.signature(goal: currentGoal, projection: afterVerification)
        let countableProgress = Self.hasCountableProgress(
            from: baseline,
            to: finalSignature,
            audit: audit,
            previousAudit: startingGoal.latestAudit)
        audit.progressMade = audit.progressMade && countableProgress

        let runTokens = Self.tokens(
            for: running.id,
            goalID: startingGoal.id,
            in: await log.replay())
        let elapsed = max(0, Date().timeIntervalSince(runStart))
        let usageLimitReason = verification.failureKind == .usageLimit
            ? (verification.reason ?? "Provider account usage limit reached")
            : nil
        let auditedGoal: Goal
        do {
            if let goalAuthority {
                let settlement = try await goalAuthority.settleGoalRunAudit(
                    audit,
                    goalID: currentGoal.id,
                    runID: running.id,
                    expectedRevision: currentGoal.revision,
                    tokenDelta: runTokens,
                    activeElapsedDelta: elapsed,
                    runProgressSummary: Self.auditSummary(audit),
                    usageLimitReason: usageLimitReason,
                    blockedRunThreshold: policy.blockedRunThreshold)
                auditedGoal = settlement.goal
            } else {
                let auditedSnapshot: Goal
                switch currentGoal.applyingAudit(audit, expectedRevision: currentGoal.revision) {
                case .success(var value):
                    value.tokensUsed = Self.saturatingAdd(currentGoal.tokensUsed, runTokens)
                    value.activeElapsedSeconds += elapsed
                    Self.applyBlockerAccounting(to: &value, audit: audit)
                    auditedSnapshot = value
                case .failure(let violation):
                    throw violation
                }
                let completedRun = try checkpointed.transitioning(
                    to: .completed,
                    progressSummary: Self.auditSummary(audit)).get()
                var terminalGoal = auditedSnapshot
                var events: [Event] = [
                    .goalAuditCompleted(GoalAuditCompletedPayload(
                        goal: auditedSnapshot,
                        audit: audit,
                        runID: running.id)),
                    .continuationRunCompleted(
                        ContinuationRunCompletedPayload(run: completedRun)),
                ]
                if audit.isCompletionProof(for: auditedSnapshot) {
                    terminalGoal = try auditedSnapshot.transitioning(
                        to: .completed,
                        expectedRevision: auditedSnapshot.revision,
                        audit: audit).get()
                    events.append(.goalCompleted(GoalCompletedPayload(
                        goal: terminalGoal,
                        audit: audit)))
                } else if let usageLimitReason {
                    terminalGoal = try auditedSnapshot.transitioning(
                        to: .usageLimited,
                        expectedRevision: auditedSnapshot.revision).get()
                    events.append(.goalUsageLimited(GoalUsageLimitedPayload(
                        goal: terminalGoal,
                        reason: usageLimitReason)))
                } else if audit.verdict == .blockedCandidate,
                          auditedSnapshot.consecutiveBlockedRuns >= policy.blockedRunThreshold {
                    terminalGoal = try auditedSnapshot.transitioning(
                        to: .blocked,
                        expectedRevision: auditedSnapshot.revision,
                        audit: audit).get()
                    events.append(.goalBlocked(GoalBlockedPayload(
                        goal: terminalGoal,
                        blocker: audit.blocker ?? "Repeated verified blocker")))
                } else if let budget = auditedSnapshot.tokenBudget,
                          auditedSnapshot.tokensUsed >= budget {
                    terminalGoal = try auditedSnapshot.transitioning(
                        to: .budgetLimited,
                        expectedRevision: auditedSnapshot.revision).get()
                    events.append(.goalBudgetLimited(
                        GoalBudgetLimitedPayload(goal: terminalGoal)))
                }
                try await append(events)
                auditedGoal = terminalGoal
            }
        } catch {
            await recordRuntimeError(
                code: "goal_audit_persistence",
                message: "Could not persist Goal audit/run settlement: \(error.localizedDescription)")
            return .stopGoal
        }

        if auditedGoal.status != .active {
            return .stopGoal
        }
        let isAccumulatingRequiredBlockerProof = audit.verdict == .blockedCandidate
            && auditedGoal.consecutiveBlockedRuns == auditedGoal.noProgressRuns
        if auditedGoal.noProgressRuns >= policy.noProgressRunThreshold,
           !isAccumulatingRequiredBlockerProof {
            try? await append(.goalProgressed(GoalProgressedPayload(
                goal: auditedGoal,
                runID: running.id,
                progressSummary: "Automatic continuation paused after repeated no-progress runs; waiting for user steering or external change.")))
            return .stopGoal
        }
        try? await append(.goalProgressed(GoalProgressedPayload(
            goal: auditedGoal,
            runID: running.id,
            progressSummary: Self.auditSummary(audit))))
        return .continueGoal
    }

    @discardableResult
    private func settleStoppedRun(_ run: ContinuationRun, generation: Int) async -> Bool {
        let request = stopRequests[generation]
            ?? StopRequest(
                reason: "Goal continuation cancelled",
                checkpoint: true,
                runCloseSource: .runtime)
        do {
            if request.checkpoint {
                let checkpointed = try run.transitioning(
                    to: .checkpointed,
                    progressSummary: request.reason).get()
                try await append(.continuationRunCheckpointed(
                    ContinuationRunCheckpointedPayload(run: checkpointed)))
            } else {
                switch request.runCloseSource {
                case .runtime, .hostLifecycle:
                    let interrupted = try run.transitioning(
                        to: .interrupted,
                        progressSummary: request.reason).get()
                    try await append(.continuationRunInterrupted(
                        ContinuationRunInterruptedPayload(
                            run: interrupted,
                            reason: request.reason)))
                case .mainAgent, .user:
                    let cancelled = try run.transitioning(
                        to: .cancelled,
                        progressSummary: request.reason).get()
                    try await append(.continuationRunCancelled(
                        ContinuationRunCancelledPayload(
                            run: cancelled,
                            reason: request.reason)))
                }
            }
            return true
        } catch {
            let message = "Could not settle stopped Goal run: \(error.localizedDescription)"
            stopSettlementFailures[generation] = message
            await recordRuntimeError(
                code: "goal_run_stop",
                message: message)
            return false
        }
    }

    private func markBudgetLimited(_ goal: Goal) async {
        guard goal.status == .active else { return }
        if let goalAuthority {
            do {
                _ = try await goalAuthority.transitionGoal(
                    goal.id,
                    expectedRevision: goal.revision,
                    to: .budgetLimited,
                    canSubmitVerdict: false,
                    hostAuthorized: true)
            } catch {
                await recordRuntimeError(code: "goal_budget", message: error.localizedDescription)
            }
            return
        }
        switch goal.transitioning(to: .budgetLimited, expectedRevision: goal.revision) {
        case .success(let limited):
            try? await append(.goalBudgetLimited(GoalBudgetLimitedPayload(goal: limited)))
        case .failure(let violation):
            await recordRuntimeError(code: "goal_budget", message: violation.message)
        }
    }

    // MARK: - Helpers

    private func append(_ event: Event) async throws {
        do {
            try await eventAppender([event])
        } catch {
            throw GoalRuntimeError.persistence(error.localizedDescription)
        }
    }

    private func append(_ events: [Event]) async throws {
        do {
            try await eventAppender(events)
        } catch {
            throw GoalRuntimeError.persistence(error.localizedDescription)
        }
    }

    private func recordRuntimeError(code: String, message: String) async {
        _ = try? await log.append(.error(ErrorPayload(code: code, message: message)))
    }

    private func appendVerifierStats(_ usage: Usage?,
                                     model: ModelID,
                                     runID: ContinuationRunID,
                                     goalID: GoalID,
                                     totalMillis: Int) async {
        guard usage != nil || totalMillis > 0 else { return }
        _ = try? await log.append(.turnStats(TurnStatsPayload(
            promptTokens: usage?.promptTokens,
            cachedPromptTokens: usage?.cachedPromptTokens,
            completionTokens: usage?.completionTokens,
            totalTokens: usage?.totalTokens,
            contextWindowTokens: usage?.contextWindowTokens,
            totalMillis: totalMillis,
            model: model.rawValue,
            goalID: goalID,
            continuationRunID: runID,
            agentID: Self.verifierAgentID)))
    }

    private static func runtimeError(_ violation: GoalMutationViolation) -> GoalRuntimeError {
        switch violation.kind {
        case .staleRevision:
            return .staleGoalRevision(
                expected: violation.expectedRevision ?? -1,
                actual: violation.actualRevision ?? -1)
        case .invalidStatusTransition, .invalidCompletionAudit, .invalidBudget:
            return .invalidGoalTransition(violation.message)
        }
    }

    private static func continuationPrompt(goal: Goal,
                                           run: ContinuationRun) -> String {
        var lines = [
            "Continue the durable user Goal below in \(IntatisHostApplication.identity.name) Cowork.",
            "Goal ID: \(goal.id.rawValue)",
            "Continuation run: \(run.id.rawValue) (#\(run.ordinal))",
            "Objective: \(goal.objective)",
        ]
        if !goal.successCriteria.isEmpty {
            lines.append("Success criteria:\n" + goal.successCriteria.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !goal.constraints.isEmpty {
            lines.append("Constraints:\n" + goal.constraints.map { "- \($0)" }.joined(separator: "\n"))
        }
        if let audit = goal.latestAudit {
            if !audit.remainingWork.isEmpty {
                lines.append("Latest verifier remaining work:\n" + audit.remainingWork.map { "- \($0)" }.joined(separator: "\n"))
            }
            if let blocker = audit.blocker { lines.append("Latest blocker candidate: \(blocker)") }
        }
        lines.append(
            "Continue with the existing Session tools and agents as needed. "
            + "Do not claim the Goal complete: synthesize the run and let the independent GoalVerifier decide after the scheduler barrier.")
        return lines.joined(separator: "\n\n")
    }

    private static func signature(goal: Goal,
                                  projection: CoworkProjection) -> GoalStateSignature {
        let invocationStates = projection.tasks.values
            .filter { $0.contract?.goalID == goal.id }
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .map {
            [
                $0.id.rawValue,
                $0.status.rawValue,
                String($0.attempt),
                compact($0.result ?? ""),
                compact($0.report?.summary ?? ""),
                compact($0.error ?? ""),
                compact($0.statusReason ?? ""),
            ].joined(separator: "|")
        }
        let remaining = Set(goal.latestAudit?.remainingWork.map(normalized) ?? [])
        return GoalStateSignature(
            invocationStates: invocationStates,
            remainingWork: remaining)
    }

    private static func hasCountableProgress(from before: GoalStateSignature,
                                             to after: GoalStateSignature,
                                             audit: GoalAuditSummary,
                                             previousAudit: GoalAuditSummary?) -> Bool {
        if before.invocationStates != after.invocationStates {
            return true
        }
        let newRemaining = Set(audit.remainingWork.map(normalized))
        let previousRemaining = Set(previousAudit?.remainingWork.map(normalized) ?? [])
        if !previousRemaining.isEmpty,
           newRemaining.isStrictSubset(of: previousRemaining) {
            return true
        }
        // Repeated independent confirmation is necessary to satisfy the
        // three-consecutive-run blocker rule before the no-progress guard stops.
        if audit.verdict == .blockedCandidate, compact(audit.blocker ?? "").isEmpty == false {
            return true
        }
        return false
    }

    private func verifier(for model: ModelID) async throws -> GoalVerifierControlPlane {
        if let verifierControlPlane,
           verifierControlPlaneModel == model {
            return verifierControlPlane
        }
        let provider = try await verifierProvider()
        let verifier = GoalVerifierControlPlane(
            provider: provider,
            model: model,
            policy: policy.verifierPolicy)
        verifierControlPlane = verifier
        verifierControlPlaneModel = model
        return verifier
    }

    private static func hasInterruptedRun(in projection: CoworkProjection) -> Bool {
        guard let goal = projection.currentGoal else { return false }
        return projection.continuationRuns.values.contains {
            $0.goalID == goal.id && ($0.status == .created || $0.status == .running)
        }
    }

    private static func applyBlockerAccounting(to goal: inout Goal,
                                               audit: GoalAuditSummary) {
        guard audit.verdict == .blockedCandidate,
              let blocker = audit.blocker,
              !compact(blocker).isEmpty else {
            goal.blockerFingerprint = nil
            goal.consecutiveBlockedRuns = 0
            return
        }
        let fingerprint = normalized(blocker)
        if goal.blockerFingerprint == fingerprint {
            goal.consecutiveBlockedRuns += 1
        } else {
            goal.blockerFingerprint = fingerprint
            goal.consecutiveBlockedRuns = 1
        }
    }

    private static func runHistory(goalID: GoalID,
                                   excluding runID: ContinuationRunID,
                                   projection: CoworkProjection,
                                   limit: Int) -> [String] {
        var entries: [(Date, String)] = []
        for run in projection.continuationRuns.values
        where run.goalID == goalID && run.id != runID {
            let text = "Run #\(run.ordinal) [\(run.status.rawValue)]: "
                + (run.progressSummary ?? "no summary")
            entries.append((run.startedAt, text))
        }
        for task in projection.tasks.values
        where task.contract?.goalID == goalID {
            let report = task.report?.summary ?? task.result ?? task.error ?? task.statusReason
            if let report {
                entries.append((task.report?.reportedAt ?? .distantPast,
                                "Invocation \(task.id.rawValue) [\(task.status.rawValue)]: \(report)"))
            }
        }
        return entries.sorted { $0.0 < $1.0 }.suffix(limit).map(\.1)
    }

    /// Builds Goal-completion evidence only from successful durable tool
    /// execution tickets tied to this Goal's AgentInvocations.
    private static func durableValidationEvidence(
        goalID: GoalID,
        projection: CoworkProjection,
        events: [Envelope]
    ) -> [TaskEvidence] {
        let eligibleTaskIDs = Set(projection.tasks.values.compactMap { task in
            task.contract?.goalID == goalID ? task.id : nil
        })
        guard !eligibleTaskIDs.isEmpty else { return [] }

        var toolResults: [String: (observation: String, recordedAt: Date)] = [:]
        var evidence: [TaskEvidence] = []
        var seenExecutionIDs: Set<String> = []
        for envelope in events {
            switch envelope.event {
            case .toolResult(let payload):
                toolResults[payload.toolCallId] = (payload.observation, envelope.ts)
            case .toolExecutionSettled(let payload):
                guard payload.outcome == .succeeded,
                      let taskID = payload.taskID,
                      eligibleTaskIDs.contains(taskID),
                      authoritativeValidationTools.contains(payload.tool),
                      seenExecutionIDs.insert(payload.executionID).inserted,
                      let result = toolResults[payload.toolCallID] else { continue }
                let observation = compact(result.observation)
                guard !observation.isEmpty else { continue }
                evidence.append(TaskEvidence(
                    kind: "tool_result",
                    reference: "tool-execution://\(payload.executionID)",
                    summary: compactEvidenceSummary("\(payload.tool): \(observation)"),
                    recordedAt: result.recordedAt))
            default:
                continue
            }
        }
        return evidence
    }

    private static let authoritativeValidationTools: Set<String> = [
        "read_file", "list_files", "search_text",
        "git_status", "git_diff", "git_diff_staged", "git_info",
        "git_recent_commits", "git_diff_base", "git_apply_patch_check",
        "inspect_pdf", "read_pdf",
        "read_docx", "continue_docx_read",
        "read_pptx", "continue_pptx_read",
        "read_xlsx", "continue_xlsx_read",
        "read_html", "continue_html_read",
        "read_epub", "continue_epub_read",
        "document_read", "document_ocr", // Historical tool-result compatibility only.
        "ocr_pdf",
        "compile_latex", "web_fetch", "browser_diagnostics",
        "browser_snapshot", "browser_screenshot", "browser_downloads",
        "browser_search",
    ]

    private static func compactEvidenceSummary(_ value: String) -> String {
        let value = compact(value)
        return value.count <= 1_000 ? value : String(value.prefix(1_000))
    }

    private static func fallbackAudit(goal: Goal, reason: String) -> GoalAuditSummary {
        let requirements = ([goal.objective] + goal.successCriteria + goal.constraints)
            .enumerated().map { index, text in
                GoalRequirementAudit(
                    id: "req_\(index + 1)",
                    text: text,
                    status: .unproven,
                    gap: reason)
            }
        return GoalAuditSummary(
            verdict: .continue,
            requirements: requirements,
            progressMade: false,
            remainingWork: [reason])
    }

    private static func auditSummary(_ audit: GoalAuditSummary) -> String {
        let proven = audit.requirements.filter { $0.status == .proven }.count
        let total = audit.requirements.count
        var summary = "GoalVerifier: \(audit.verdict.rawValue), \(proven)/\(total) requirements proven"
        if !audit.remainingWork.isEmpty {
            summary += "; remaining: " + audit.remainingWork.joined(separator: "; ")
        }
        if let blocker = audit.blocker { summary += "; blocker: \(blocker)" }
        return summary
    }

    private static func tokens(for runID: ContinuationRunID,
                               goalID: GoalID,
                               in envelopes: [Envelope]) -> Int {
        envelopes.reduce(into: 0) { total, envelope in
            guard case .turnStats(let stats) = envelope.event,
                  stats.goalID == goalID,
                  stats.continuationRunID == runID else { return }
            let reported = stats.totalTokens
                ?? Self.optionalAdd(stats.promptTokens, stats.completionTokens)
                ?? 0
            total = saturatingAdd(total, max(0, reported))
        }
    }

    private static func optionalAdd(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard lhs != nil || rhs != nil else { return nil }
        return saturatingAdd(lhs ?? 0, rhs ?? 0)
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private static func milliseconds(since date: Date) -> Int {
        let value = max(0, Date().timeIntervalSince(date) * 1_000)
        return value >= Double(Int.max) ? Int.max : Int(value.rounded())
    }

    private static func compact(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ value: String) -> String {
        compact(value).lowercased().split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func cleaned(_ values: [String]) -> [String] {
        values.map(compact).filter { !$0.isEmpty }
    }
}
