import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
import IntatisTools
@testable import IntatisCowork

private final class GoalManagerProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private let responses: [[AgentChunk]]

    init(responses: [[AgentChunk]]) {
        self.responses = responses
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        let response = responses[min(index, responses.count - 1)]
        index += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in response {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }
}

private actor GoalAdmissionBatchRecorder {
    private var batches: [[Event]] = []

    func append(_ events: [Event], to log: EventLog) async throws {
        batches.append(events)
        _ = try await log.append(events)
    }

    func snapshot() -> [[Event]] {
        batches
    }
}

private func goalManagerLog() throws -> EventLog {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-goal-manager-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    return try EventLog(session: SessionID(rawValue: "goal-manager"), fileURL: file)
}

private func goalManagerWorkspace() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-goal-manager-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class GoalManagerRuntimeTests: XCTestCase {
    private let main = AgentID(rawValue: "main")

    func testGoalMutationsReplayAndParallelCurrentGoalIsRejected() async throws {
        let log = try goalManagerLog()
        let provider = GoalManagerProvider(responses: [[.done(finishReason: "stop")]])
        let firstRuntime = Orchestrator(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.deny)) { _ in provider }
        let created = try await firstRuntime.createGoal(
            request: GoalCreateRequest(
                objective: "Original objective",
                successCriteria: ["Verified"]))

        do {
            _ = try await firstRuntime.createGoal(
                request: GoalCreateRequest(objective: "Parallel objective"))
            XCTFail("expected parallel current Goal rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("current Goal already exists"))
        }

        let edited = try await firstRuntime.editGoal(
            request: GoalEditRequest(
                goalID: created.id,
                expectedRevision: created.revision,
                objective: "Edited objective",
                successCriteria: ["Verified"],
                constraints: ["Stay local"]),
            hostAuthorized: true)
        let paused = try await firstRuntime.transitionGoal(
            created.id,
            expectedRevision: edited.revision,
            to: .paused,
            canSubmitVerdict: false,
            hostAuthorized: true)

        let recoveredRuntime = Orchestrator(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.deny)) { _ in provider }
        let recovered = await recoveredRuntime.currentGoalSnapshot()
        XCTAssertEqual(recovered?.id, paused.id)
        XCTAssertEqual(recovered?.objective, paused.objective)
        XCTAssertEqual(recovered?.status, paused.status)
        XCTAssertEqual(recovered?.revision, paused.revision)

        let resumed = try await recoveredRuntime.transitionGoal(
            created.id,
            expectedRevision: paused.revision,
            to: .active,
            canSubmitVerdict: false,
            hostAuthorized: true)
        try await recoveredRuntime.clearGoal(
            created.id,
            expectedRevision: resumed.revision,
            hostAuthorized: true)
        let currentAfterClear = await recoveredRuntime.currentGoalSnapshot()
        XCTAssertNil(currentAfterClear)

        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertNil(projection.currentGoalID)
        XCTAssertEqual(projection.goals[created.id]?.objective, "Edited objective")
        XCTAssertEqual(projection.goals[created.id]?.status, .active)
    }

    func testGoalAuditAuthorityRejectsStaleWritesAndRequiresThreeMatchingBlockers() async throws {
        let log = try goalManagerLog()
        let provider = GoalManagerProvider(responses: [[.done(finishReason: "stop")]])
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.deny)) { _ in provider }
        let created = try await orchestrator.createGoal(
            request: GoalCreateRequest(objective: "Wait for the external dependency"))
        func checkpointedRun(ordinal: Int) async throws -> ContinuationRun {
            let createdRun = ContinuationRun(
                sessionID: created.sessionID,
                goalID: created.id,
                ordinal: ordinal)
            try await log.append(.continuationRunCreated(
                ContinuationRunCreatedPayload(run: createdRun)))
            let running = try createdRun.transitioning(to: .running).get()
            try await log.append(.continuationRunStarted(
                ContinuationRunStartedPayload(run: running)))
            let checkpointed = try running.transitioning(to: .checkpointed).get()
            try await log.append(.continuationRunCheckpointed(
                ContinuationRunCheckpointedPayload(run: checkpointed)))
            return checkpointed
        }

        func completeRun(_ run: ContinuationRun) async throws {
            let completed = try run.transitioning(to: .completed).get()
            try await log.append(.continuationRunCompleted(
                ContinuationRunCompletedPayload(run: completed)))
        }

        func blockerAudit() -> GoalAuditSummary {
            GoalAuditSummary(
                verdict: .blockedCandidate,
                requirements: [GoalRequirementAudit(
                    id: "objective",
                    text: created.objective,
                    status: .unproven,
                    gap: "External service is unavailable")],
                progressMade: false,
                remainingWork: ["Retry after the service recovers"],
                blocker: "External service is unavailable")
        }

        let firstRun = try await checkpointedRun(ordinal: 1)
        let first = try await orchestrator.applyGoalAudit(
            blockerAudit(),
            goalID: created.id,
            runID: firstRun.id,
            expectedRevision: created.revision,
            tokenDelta: 7,
            activeElapsedDelta: 1.5)
        XCTAssertEqual(first.tokensUsed, 7)
        XCTAssertEqual(first.activeElapsedSeconds, 1.5, accuracy: 0.001)
        XCTAssertEqual(first.noProgressRuns, 1)
        XCTAssertEqual(first.consecutiveBlockedRuns, 1)
        let eventCountAfterFirstAudit = await log.replay().count
        do {
            _ = try await orchestrator.applyGoalAudit(
                blockerAudit(),
                goalID: created.id,
                runID: firstRun.id,
                expectedRevision: first.revision,
                tokenDelta: 100,
                activeElapsedDelta: 100)
            XCTFail("the same run must not be audited twice")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already has a Goal audit"))
        }
        let afterDuplicateAudit = await log.replay()
        XCTAssertEqual(afterDuplicateAudit.count, eventCountAfterFirstAudit)
        let goalAfterDuplicateAudit = await orchestrator.currentGoalSnapshot()
        XCTAssertEqual(goalAfterDuplicateAudit?.revision, first.revision)
        XCTAssertEqual(goalAfterDuplicateAudit?.tokensUsed, 7)
        XCTAssertEqual(goalAfterDuplicateAudit?.consecutiveBlockedRuns, 1)
        try await completeRun(firstRun)

        let secondRun = try await checkpointedRun(ordinal: 2)
        do {
            _ = try await orchestrator.applyGoalAudit(
                blockerAudit(),
                goalID: created.id,
                runID: secondRun.id,
                expectedRevision: created.revision,
                tokenDelta: 100,
                activeElapsedDelta: 100)
            XCTFail("expected stale Goal audit rejection")
        } catch let violation as GoalMutationViolation {
            XCTAssertEqual(violation.kind, .staleRevision)
        }
        let afterStaleWrite = await orchestrator.currentGoalSnapshot()
        XCTAssertEqual(afterStaleWrite?.revision, first.revision)
        XCTAssertEqual(afterStaleWrite?.tokensUsed, 7)

        do {
            _ = try await orchestrator.transitionGoal(
                created.id,
                expectedRevision: first.revision,
                to: .blocked,
                canSubmitVerdict: true,
                hostAuthorized: true)
            XCTFail("one blocker audit must not terminally block a Goal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("at least three"))
        }

        let second = try await orchestrator.applyGoalAudit(
            blockerAudit(),
            goalID: created.id,
            runID: secondRun.id,
            expectedRevision: first.revision,
            tokenDelta: 8,
            activeElapsedDelta: 2)
        try await completeRun(secondRun)
        let thirdRun = try await checkpointedRun(ordinal: 3)
        let third = try await orchestrator.applyGoalAudit(
            blockerAudit(),
            goalID: created.id,
            runID: thirdRun.id,
            expectedRevision: second.revision,
            tokenDelta: 9,
            activeElapsedDelta: 2.5)
        XCTAssertEqual(third.tokensUsed, 24)
        XCTAssertEqual(third.activeElapsedSeconds, 6, accuracy: 0.001)
        XCTAssertEqual(third.noProgressRuns, 3)
        XCTAssertEqual(third.consecutiveBlockedRuns, 3)

        let blocked = try await orchestrator.transitionGoal(
            created.id,
            expectedRevision: third.revision,
            to: .blocked,
            canSubmitVerdict: true,
            hostAuthorized: true)
        XCTAssertEqual(blocked.status, .blocked)
        XCTAssertEqual(blocked.consecutiveBlockedRuns, 3)
    }

    func testSettleGoalRunAuditPersistsCompletionAsOneOrderedBatch() async throws {
        let log = try goalManagerLog()
        let provider = GoalManagerProvider(responses: [[.done(finishReason: "stop")]])
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.deny)) { _ in provider }
        let goal = try await orchestrator.createGoal(
            request: GoalCreateRequest(objective: "Prove the durable Goal is complete"))
        let createdRun = ContinuationRun(
            sessionID: goal.sessionID,
            goalID: goal.id,
            ordinal: 1)
        try await log.append(.continuationRunCreated(
            ContinuationRunCreatedPayload(run: createdRun)))
        let runningRun = try createdRun.transitioning(to: .running).get()
        try await log.append(.continuationRunStarted(
            ContinuationRunStartedPayload(run: runningRun)))
        let checkpointedRun = try runningRun.transitioning(
            to: .checkpointed,
            progressSummary: "All required work reached the barrier").get()
        try await log.append(.continuationRunCheckpointed(
            ContinuationRunCheckpointedPayload(run: checkpointedRun)))

        let audit = GoalAuditSummary(
            verdict: .complete,
            requirements: [GoalRequirementAudit(
                id: "objective",
                text: goal.objective,
                status: .proven,
                evidence: [TaskEvidence(
                    kind: "test",
                    reference: "GoalManagerRuntimeTests",
                    summary: "The durable completion requirement was verified")])],
            progressMade: true,
            remainingWork: [],
            blocker: nil)
        XCTAssertTrue(audit.isCompletionProof(for: goal))

        let recorder = GoalAdmissionBatchRecorder()
        await orchestrator.setAdmissionEventsAppender { events in
            try await recorder.append(events, to: log)
        }
        let settled = try await orchestrator.settleGoalRunAudit(
            audit,
            goalID: goal.id,
            runID: checkpointedRun.id,
            expectedRevision: goal.revision,
            tokenDelta: 13,
            activeElapsedDelta: 2.5,
            runProgressSummary: "GoalVerifier: complete",
            usageLimitReason: nil,
            blockedRunThreshold: 3)

        XCTAssertEqual(settled.goal.status, .completed)
        XCTAssertTrue(settled.goal.status.isTerminal)
        XCTAssertTrue(settled.goal.hasValidCompletionProof)
        XCTAssertEqual(settled.goal.tokensUsed, 13)
        XCTAssertEqual(settled.run.status, .completed)
        XCTAssertTrue(settled.run.status.isTerminal)

        let batches = await recorder.snapshot()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].map(\.type), [
            .goalAuditCompleted,
            .continuationRunCompleted,
            .goalCompleted,
        ])

        let replayed = await log.replay()
        let settlementEvents = Array(replayed.suffix(3))
        XCTAssertEqual(settlementEvents.map { $0.event.type }, [
            .goalAuditCompleted,
            .continuationRunCompleted,
            .goalCompleted,
        ])
        XCTAssertEqual(
            settlementEvents.map(\.seq),
            Array(settlementEvents[0].seq ... settlementEvents[0].seq + 2))
        let projection = CoworkProjection.build(from: replayed)
        XCTAssertEqual(projection.goals[goal.id]?.status, .completed)
        XCTAssertEqual(projection.continuationRuns[checkpointedRun.id]?.status, .completed)
    }

    func testLegacyDelegationAndCausalMailboxWakeInheritParentGoalRunScope() async throws {
        let log = try goalManagerLog()
        let mainWorkspace = try goalManagerWorkspace()
        let workerWorkspace = try goalManagerWorkspace()
        defer {
            try? FileManager.default.removeItem(at: mainWorkspace)
            try? FileManager.default.removeItem(at: workerWorkspace)
        }
        let worker = AgentID(rawValue: "worker")
        let provider = GoalManagerProvider(responses: [[
            .textDelta("scoped work complete"),
            .done(finishReason: "stop"),
        ]])
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.allow)) { _ in provider }
        let mainAttached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: mainWorkspace,
            model: ModelID(rawValue: "test"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: workerWorkspace,
            model: ModelID(rawValue: "test"),
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)

        let goal = try await orchestrator.createGoal(
            request: GoalCreateRequest(objective: "Keep every child inside this run"))
        let createdRun = ContinuationRun(
            sessionID: goal.sessionID,
            goalID: goal.id,
            ordinal: 1)
        try await log.append(.continuationRunCreated(
            ContinuationRunCreatedPayload(run: createdRun)))
        let runningRun = try createdRun.transitioning(to: .running).get()
        try await log.append(.continuationRunStarted(
            ContinuationRunStartedPayload(run: runningRun)))
        let parentIDValue = await orchestrator.createRootTask(
            assignee: main,
            objective: "Coordinate scoped compatibility work",
            goalID: goal.id,
            continuationRunID: runningRun.id)
        let parentID = try XCTUnwrap(parentIDValue)

        let legacyChild = await orchestrator.enqueueDelegatedTask(
            from: main,
            to: worker.rawValue,
            objective: "Legacy delegated child without a WorkTask",
            parentTaskID: parentID,
            replyMode: .none)
        XCTAssertNotNil(legacyChild.taskID)
        let messageResult = await orchestrator.sendMessage(
            from: main,
            to: worker.rawValue,
            content: "Handle this causal mailbox message",
            taskID: parentID)
        XCTAssertEqual(messageResult, "sent message to @worker")

        await orchestrator.runSchedulerUntilIdle()
        let taskContracts = await log.replay().compactMap { envelope -> TaskContract? in
            guard case .taskCreated(let payload) = envelope.event else { return nil }
            return payload.contract
        }
        let childID = try XCTUnwrap(legacyChild.taskID)
        let childContract = try XCTUnwrap(taskContracts.first { $0.id == childID })
        XCTAssertNil(childContract.workTaskID)
        XCTAssertEqual(childContract.parentTaskID, parentID)
        XCTAssertEqual(childContract.goalID, goal.id)
        XCTAssertEqual(childContract.continuationRunID, runningRun.id)

        let mailboxContract = try XCTUnwrap(taskContracts.first {
            $0.kind == .mailboxDelivery && $0.relatedTasks.contains(parentID)
        })
        XCTAssertEqual(mailboxContract.goalID, goal.id)
        XCTAssertEqual(mailboxContract.continuationRunID, runningRun.id)
    }

    func testScopedRecoveryCancellationDoesNotWakeUnrelatedRestoredTask() async throws {
        let log = try goalManagerLog()
        let workspace = try goalManagerWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sessionID = await log.sessionID
        let goal = Goal(sessionID: sessionID, objective: "Recover without global scheduler wake")
        let createdRun = ContinuationRun(sessionID: sessionID, goalID: goal.id, ordinal: 1)
        let runningRun = try createdRun.transitioning(to: .running).get()
        let scopedTaskID = TaskID.new()
        let unrelatedTaskID = TaskID.new()
        let scoped = TaskContract(
            id: scopedTaskID,
            kind: .root,
            issuer: nil,
            assignee: main,
            continuationRunID: runningRun.id,
            goalID: goal.id,
            objective: "Interrupted Goal work",
            roleHint: "root",
            expectedDeliverable: "result",
            replyMode: TaskReplyMode.none,
            maxAttempts: 1)
        let unrelated = TaskContract(
            id: unrelatedTaskID,
            kind: .root,
            issuer: nil,
            assignee: main,
            objective: "Unrelated restored work",
            roleHint: "root",
            expectedDeliverable: "result",
            replyMode: TaskReplyMode.none,
            maxAttempts: 1)
        func metadata(for contract: TaskContract) -> CoworkEventMetadata {
            CoworkEventMetadata(
                taskID: contract.id,
                rootTaskID: contract.id,
                agentID: main,
                assignee: main,
                scope: .task)
        }
        func taskEvents(for contract: TaskContract) -> [Event] {
            let metadata = metadata(for: contract)
            return [
                .taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)),
                .taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)),
                .taskQueued(TaskQueuedPayload(
                    contract: contract,
                    rootTaskID: contract.id,
                    assignee: main,
                    hopCount: 0,
                    visitedAgents: [main],
                    attempt: 1,
                    metadata: metadata)),
            ]
        }
        var events: [Event] = [
            .agentAttached(AgentAttachedPayload(
                agent: main,
                path: workspace.path,
                model: ModelID(rawValue: "test"),
                profile: PermissionProfile.readOnly.rawValue)),
            .goalCreated(GoalCreatedPayload(goal: goal)),
            .continuationRunCreated(ContinuationRunCreatedPayload(run: createdRun)),
            .continuationRunStarted(ContinuationRunStartedPayload(run: runningRun)),
        ]
        events.append(contentsOf: taskEvents(for: scoped))
        events.append(contentsOf: taskEvents(for: unrelated))
        try await log.append(events)

        let provider = GoalManagerProvider(responses: [[
            .textDelta("unrelated work completed"),
            .done(finishReason: "stop"),
        ]])
        let restored = Orchestrator(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.allow)) { _ in provider }
        await restored.restore(from: CoworkProjection.build(from: await log.replay()))

        // Runtime policy and mailbox/control-plane updates are allowed during
        // recovery, but none may release the persistent startup scheduler gate.
        await restored.updateExecutionPolicy(.default)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(provider.callCount(), 0)
        let queuedWhileRecoveryIsSuspended = await restored.queuedTasks()
        XCTAssertEqual(
            Set(queuedWhileRecoveryIsSuspended.map(\.contract.id)),
            Set([scopedTaskID, unrelatedTaskID]))

        let cancelled = await restored.cancelActiveTasks(
            goalID: goal.id,
            continuationRunID: runningRun.id,
            reason: "startup recovery",
            resumePendingTasksOnSuccess: false)
        XCTAssertTrue(cancelled)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(provider.callCount(), 0)
        let queuedBeforeResume = await restored.queuedTasks()
        XCTAssertEqual(queuedBeforeResume.map(\.contract.id), [unrelatedTaskID])

        await restored.resumePendingTasks()
        await restored.runSchedulerUntilIdle()
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(projection.tasks[scopedTaskID]?.status, .cancelled)
        // The minimal restored fixture has no executable default leases, so the
        // unrelated task fails closed once explicitly resumed. Its transition
        // from queued proves the host resume, rather than scoped cancellation,
        // was what woke the scheduler.
        XCTAssertEqual(projection.tasks[unrelatedTaskID]?.status, .failed)
    }

    func testScopedCancellationDiscardsOldRunMailboxAndRestoreWakesOnlyNewRunMessage() async throws {
        let log = try goalManagerLog()
        let workspace = try goalManagerWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let worker = AgentID(rawValue: "worker")
        let sessionID = await log.sessionID
        let goal = Goal(sessionID: sessionID, objective: "Recover the newest continuation only")
        let oldCreatedRun = ContinuationRun(
            sessionID: sessionID,
            goalID: goal.id,
            ordinal: 1)
        let oldRunningRun = try oldCreatedRun.transitioning(to: .running).get()
        let oldRootID = TaskID(rawValue: "old-scoped-root")
        let oldRoot = TaskContract(
            id: oldRootID,
            kind: .root,
            issuer: nil,
            assignee: main,
            continuationRunID: oldRunningRun.id,
            goalID: goal.id,
            objective: "Interrupted old continuation",
            roleHint: "root",
            expectedDeliverable: "old result",
            replyMode: TaskReplyMode.none,
            maxAttempts: 1)
        let oldMetadata = CoworkEventMetadata(
            taskID: oldRootID,
            rootTaskID: oldRootID,
            agentID: main,
            assignee: main,
            scope: .task)
        let oldMessageID = MessageID(rawValue: "old-run-message")
        try await log.append([
            .agentAttached(AgentAttachedPayload(
                agent: main,
                path: workspace.path,
                model: ModelID(rawValue: "test"),
                profile: PermissionProfile.readOnly.rawValue)),
            .agentAttached(AgentAttachedPayload(
                agent: worker,
                path: workspace.path,
                model: ModelID(rawValue: "test"),
                profile: PermissionProfile.readOnly.rawValue)),
            .goalCreated(GoalCreatedPayload(goal: goal)),
            .continuationRunCreated(ContinuationRunCreatedPayload(run: oldCreatedRun)),
            .continuationRunStarted(ContinuationRunStartedPayload(run: oldRunningRun)),
            .taskCreated(TaskCreatedPayload(contract: oldRoot, metadata: oldMetadata)),
            .taskAssigned(TaskAssignedPayload(contract: oldRoot, metadata: oldMetadata)),
            .taskQueued(TaskQueuedPayload(
                contract: oldRoot,
                rootTaskID: oldRootID,
                assignee: main,
                hopCount: 0,
                visitedAgents: [main],
                attempt: 1,
                metadata: oldMetadata)),
            .agentMessage(AgentMessagePayload(
                from: main,
                to: worker,
                content: "stale work from the old continuation",
                kind: .sendMessage,
                messageId: oldMessageID,
                taskID: oldRootID,
                metadata: CoworkEventMetadata(
                    taskID: oldRootID,
                    rootTaskID: oldRootID,
                    sender: main,
                    recipient: worker,
                    agentID: worker,
                    causalParentID: oldRootID,
                    scope: .task,
                    visibility: .privateAgent))),
        ])

        let firstProvider = GoalManagerProvider(responses: [[
            .textDelta("must remain behind startup gate"),
            .done(finishReason: "stop"),
        ]])
        let firstRuntime = Orchestrator(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.allow)) { _ in firstProvider }
        await firstRuntime.restore(from: CoworkProjection.build(from: await log.replay()))

        let cancelled = await firstRuntime.cancelActiveTasks(
            goalID: goal.id,
            continuationRunID: oldRunningRun.id,
            reason: "replace interrupted continuation",
            resumePendingTasksOnSuccess: false)
        XCTAssertTrue(cancelled)
        XCTAssertEqual(firstProvider.callCount(), 0)

        let afterCancellation = await log.replay()
        let discarded = afterCancellation.compactMap { envelope -> AgentMessageDiscardedPayload? in
            guard case .agentMessageDiscarded(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(discarded.map(\.messageID), [oldMessageID])
        XCTAssertEqual(discarded.first?.agent, worker)
        XCTAssertEqual(discarded.first?.taskID, oldRootID)
        XCTAssertEqual(discarded.first?.goalID, goal.id)
        XCTAssertEqual(discarded.first?.continuationRunID, oldRunningRun.id)
        let consumedAfterCancellation = afterCancellation.compactMap { envelope -> MessageID? in
            guard case .agentMessageConsumed(let payload) = envelope.event else { return nil }
            return payload.messageID
        }
        XCTAssertFalse(consumedAfterCancellation.contains(oldMessageID))
        let cancelledProjection = CoworkProjection.build(from: afterCancellation)
        XCTAssertFalse(
            cancelledProjection.mailboxes[worker]?.pendingMessages.contains(oldMessageID) ?? false)

        let oldCheckpointedRun = try oldRunningRun.transitioning(to: .checkpointed).get()
        let newCreatedRun = ContinuationRun(
            sessionID: sessionID,
            goalID: goal.id,
            ordinal: 2)
        let newRunningRun = try newCreatedRun.transitioning(to: .running).get()
        let newRootID = TaskID(rawValue: "new-scoped-root")
        let newRoot = TaskContract(
            id: newRootID,
            kind: .root,
            issuer: nil,
            assignee: main,
            continuationRunID: newRunningRun.id,
            goalID: goal.id,
            objective: "Continue with fresh work",
            roleHint: "root",
            expectedDeliverable: "new result",
            replyMode: TaskReplyMode.none,
            maxAttempts: 1)
        let newMetadata = CoworkEventMetadata(
            taskID: newRootID,
            rootTaskID: newRootID,
            agentID: main,
            assignee: main,
            scope: .task)
        let newMessageID = MessageID(rawValue: "new-run-message")
        try await log.append([
            .continuationRunCheckpointed(
                ContinuationRunCheckpointedPayload(run: oldCheckpointedRun)),
            .continuationRunCreated(ContinuationRunCreatedPayload(run: newCreatedRun)),
            .continuationRunStarted(ContinuationRunStartedPayload(run: newRunningRun)),
            .taskCreated(TaskCreatedPayload(contract: newRoot, metadata: newMetadata)),
            .taskAssigned(TaskAssignedPayload(contract: newRoot, metadata: newMetadata)),
            .taskQueued(TaskQueuedPayload(
                contract: newRoot,
                rootTaskID: newRootID,
                assignee: main,
                hopCount: 0,
                visitedAgents: [main],
                attempt: 1,
                metadata: newMetadata)),
            .agentMessage(AgentMessagePayload(
                from: main,
                to: worker,
                content: "fresh work for the new continuation",
                kind: .sendMessage,
                messageId: newMessageID,
                taskID: newRootID,
                metadata: CoworkEventMetadata(
                    taskID: newRootID,
                    rootTaskID: newRootID,
                    sender: main,
                    recipient: worker,
                    agentID: worker,
                    causalParentID: newRootID,
                    scope: .task,
                    visibility: .privateAgent))),
        ])

        let secondProvider = GoalManagerProvider(responses: [[
            .textDelta("must remain behind startup gate"),
            .done(finishReason: "stop"),
        ]])
        let secondRuntime = Orchestrator(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.allow)) { _ in secondProvider }
        await secondRuntime.restore(from: CoworkProjection.build(from: await log.replay()))

        let finalProjection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(finalProjection.mailboxes[worker]?.pendingMessages, [newMessageID])
        let queuedMailboxDeliveries = await secondRuntime.queuedTasks().filter {
            $0.contract.kind == .mailboxDelivery && $0.assignee == worker
        }
        XCTAssertEqual(queuedMailboxDeliveries.count, 1)
        XCTAssertEqual(queuedMailboxDeliveries.first?.contract.goalID, goal.id)
        XCTAssertEqual(
            queuedMailboxDeliveries.first?.contract.continuationRunID,
            newRunningRun.id)
        XCTAssertEqual(queuedMailboxDeliveries.first?.contract.relatedTasks, [newRootID])
        XCTAssertEqual(secondProvider.callCount(), 0)
    }
}
