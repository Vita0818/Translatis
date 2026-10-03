import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
@testable import IntatisCowork

private enum GoalRuntimeTestFailure: Error {
    case timedOut(String)
    case injectedCheckpointFailure
}

private final class RuntimeVerifierProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [String]
    private var index = 0

    init(_ responses: [String]) {
        self.responses = responses
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        let response = responses[min(index, responses.count - 1)]
        index += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(response))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }
}

private actor RuntimeSendRecorder {
    struct Call: Equatable, Sendable {
        var target: AgentID?
        var goalID: GoalID?
        var runID: ContinuationRunID?
        var recordUserMessage: Bool
    }

    private var values: [Call] = []

    func record(target: AgentID?,
                goalID: GoalID?,
                runID: ContinuationRunID?,
                recordUserMessage: Bool) {
        values.append(Call(
            target: target,
            goalID: goalID,
            runID: runID,
            recordUserMessage: recordUserMessage))
    }

    func calls() -> [Call] { values }
}

private actor RuntimeCancellationRecorder {
    private var reasons: [String] = []
    func record(_ reason: String) { reasons.append(reason) }
    func values() -> [String] { reasons }
}

private actor RuntimeGoalHookRecorder {
    enum Event: Equatable, Sendable {
        case send(GoalID, ContinuationRunID)
        case wait(GoalID, ContinuationRunID?)
        case consumeUsageLimit(GoalID, ContinuationRunID)
    }

    private var recordedEvents: [Event] = []

    func record(_ event: Event) {
        recordedEvents.append(event)
    }

    func events() -> [Event] { recordedEvents }
}

private actor RuntimeCallCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int { count }
}

private actor RuntimeAsyncBarrier {
    private var hasEntered = false
    private var isReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if !hasEntered {
            hasEntered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor RuntimeCheckpointPersistenceGate {
    private var rejectsCheckpoint = true

    func append(_ events: [Event], to log: EventLog) async throws {
        if rejectsCheckpoint, events.contains(where: { event in
            if case .continuationRunCheckpointed = event { return true }
            return false
        }) {
            throw GoalRuntimeTestFailure.injectedCheckpointFailure
        }
        try await log.append(events)
    }

    func allowCheckpoint() {
        rejectsCheckpoint = false
    }
}

private func runtimeLog(_ label: String) throws -> EventLog {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-goal-runtime-\(label)-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    return try EventLog(session: SessionID(rawValue: "goal-runtime-\(label)"), fileURL: file)
}

private func runtimeWorkspace(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "intatis-goal-runtime-workspace-\(label)-\(UUID().uuidString)",
            isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func runtimeJSON(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]), as: UTF8.self)
}

private func runtimeRequirement(id: String,
                                text: String,
                                status: String,
                                evidence: [[String: String]] = [],
                                gap: String? = nil) -> [String: Any] {
    [
        "id": id,
        "text": text,
        "status": status,
        "evidence": evidence,
        "gap": gap ?? NSNull(),
    ]
}

private func completeRuntimeAudit() -> String {
    let evidence = [[
        "kind": "tool_result",
        "reference": "tool-execution://focused-verification",
        "summary": "Focused verification passed.",
    ]]
    return runtimeJSON([
        "verdict": "complete",
        "requirements": [
            runtimeRequirement(
                id: "objective",
                text: "Finish feature",
                status: "proven",
                evidence: evidence),
            runtimeRequirement(
                id: "success_criterion_1",
                text: "Tests pass",
                status: "proven",
                evidence: evidence),
        ],
        "progress_made": true,
        "remaining_work": [],
        "blocker": NSNull(),
    ])
}

private func missingEvidenceCompletionAudit() -> String {
    runtimeJSON([
        "verdict": "complete",
        "requirements": [runtimeRequirement(
            id: "objective",
            text: "Need proof",
            status: "proven",
            evidence: [[
                "kind": "test",
                "reference": "test://invented",
                "summary": "Not authoritative.",
            ]])],
        "progress_made": true,
        "remaining_work": [],
        "blocker": NSNull(),
    ])
}

private func blockedRuntimeAudit() -> String {
    runtimeJSON([
        "verdict": "blocked_candidate",
        "requirements": [runtimeRequirement(
            id: "objective",
            text: "Wait for external approval",
            status: "unproven",
            gap: "Approval is unavailable")],
        "progress_made": true,
        "remaining_work": ["Obtain approval"],
        "blocker": "External approval unavailable",
    ])
}

private func continuingRuntimeAudit(objective: String) -> String {
    runtimeJSON([
        "verdict": "continue",
        "requirements": [runtimeRequirement(
            id: "objective",
            text: objective,
            status: "unproven",
            gap: "More work is required")],
        "progress_made": false,
        "remaining_work": ["More work is required"],
        "blocker": NSNull(),
    ])
}

private func waitForRuntimeProjection(
    _ log: EventLog,
    label: String,
    attempts: Int = 500,
    predicate: (CoworkProjection) -> Bool
) async throws -> CoworkProjection {
    for _ in 0..<attempts {
        let projection = CoworkProjection.build(from: await log.replay())
        if predicate(projection) { return projection }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw GoalRuntimeTestFailure.timedOut(label)
}

private func appendCompletedRuntimeValidationEvidence(
    log: EventLog,
    goalID: GoalID,
    runID: ContinuationRunID
) async -> Bool {
    let invocationID = TaskID.new()
    do {
        let contract = TaskContract(
            id: invocationID,
            kind: .root,
            issuer: nil,
            assignee: Orchestrator.mainAgentID,
            continuationRunID: runID,
            goalID: goalID,
            objective: "Run focused verification",
            roleHint: "verification runner",
            expectedDeliverable: "Durable verification output",
            replyMode: TaskReplyMode.none,
            maxAttempts: 1)
        let metadata = CoworkEventMetadata(
            taskID: invocationID,
            rootTaskID: invocationID,
            recipient: Orchestrator.mainAgentID,
            agentID: Orchestrator.mainAgentID,
            scope: .task)
        let prepared = ToolExecutionPreparedPayload(
            executionID: "focused-verification",
            taskID: invocationID,
            attempt: 1,
            toolCallID: "focused-verification-call",
            agent: Orchestrator.mainAgentID,
            tool: "git_status",
            sideEffect: .readOnly)
        try await log.append([
            .taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)),
            .taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)),
            .taskQueued(TaskQueuedPayload(
                contract: contract,
                rootTaskID: invocationID,
                assignee: Orchestrator.mainAgentID,
                hopCount: 0,
                visitedAgents: [Orchestrator.mainAgentID],
                attempt: 1,
                metadata: metadata)),
            .taskStarted(TaskStartedPayload(
                taskID: invocationID,
                agent: Orchestrator.mainAgentID,
                attempt: 1,
                metadata: metadata)),
            .toolExecutionPrepared(prepared),
            .toolResult(ToolResultPayload(
                toolCallId: prepared.toolCallID,
                observation: "Focused verification passed.")),
            .toolExecutionSettled(ToolExecutionSettledPayload(
                prepared: prepared,
                outcome: .succeeded)),
            .taskCompleted(TaskCompletedPayload(
                taskID: invocationID,
                agent: Orchestrator.mainAgentID,
                result: "Focused verification passed.",
                attempt: 1,
                metadata: metadata)),
        ])
        return true
    } catch {
        return false
    }
}

final class GoalRuntimeControllerTests: XCTestCase {
    func testColdStartPausesCleanActiveGoalUntilExplicitResume() async throws {
        let log = try runtimeLog("cold-active-explicit-resume")
        let sessionID = await log.sessionID
        let goal = Goal(sessionID: sessionID, objective: "Wait for explicit Resume")
        try await log.append(.goalCreated(GoalCreatedPayload(goal: goal)))

        let sendCalls = RuntimeCallCounter()
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: goal.objective),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in
                await sendCalls.increment()
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return .sent
                } catch {
                    return .failed("stopped")
                }
            })

        let startupSafe = await controller.start()
        XCTAssertTrue(startupSafe)
        var projection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(projection.goals[goal.id]?.status, .paused)
        XCTAssertTrue(projection.continuationRuns.isEmpty)
        let startupSendCalls = await sendCalls.value()
        XCTAssertEqual(startupSendCalls, 0)
        XCTAssertEqual(verifier.callCount(), 0)

        _ = try await controller.resumeCurrentGoal()
        projection = try await waitForRuntimeProjection(log, label: "explicit cold resume") {
            $0.goals[goal.id]?.status == .active
                && $0.continuationRuns.values.contains {
                    $0.goalID == goal.id && $0.status == .running
                }
        }
        XCTAssertEqual(projection.goals[goal.id]?.status, .active)
        let resumedSendCalls = await sendCalls.value()
        XCTAssertEqual(resumedSendCalls, 1)
        await controller.shutdown()
    }

    func testColdStartAtTokenBudgetBecomesBudgetLimitedWithoutProvider() async throws {
        let log = try runtimeLog("cold-budget-limited")
        let sessionID = await log.sessionID
        let goal = Goal(
            sessionID: sessionID,
            objective: "Respect the durable budget",
            tokenBudget: 7,
            tokensUsed: 7)
        try await log.append(.goalCreated(GoalCreatedPayload(goal: goal)))

        let sendCalls = RuntimeCallCounter()
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: goal.objective),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in
                await sendCalls.increment()
                return .sent
            })

        let startupSafe = await controller.start()
        XCTAssertTrue(startupSafe)
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(projection.goals[goal.id]?.status, .budgetLimited)
        XCTAssertTrue(projection.continuationRuns.isEmpty)
        let sendCallCount = await sendCalls.value()
        XCTAssertEqual(sendCallCount, 0)
        XCTAssertEqual(verifier.callCount(), 0)
        await controller.shutdown()
    }

    func testColdStartPausePersistenceFailureFailsClosedWithoutProvider() async throws {
        let log = try runtimeLog("cold-pause-persistence-failure")
        let sessionID = await log.sessionID
        let goal = Goal(sessionID: sessionID, objective: "Fail closed on pause append")
        try await log.append(.goalCreated(GoalCreatedPayload(goal: goal)))

        let sendCalls = RuntimeCallCounter()
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: goal.objective),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in
                await sendCalls.increment()
                return .sent
            },
            eventAppender: { events in
                if events.contains(where: { event in
                    guard case .goalPaused = event else { return false }
                    return true
                }) {
                    throw GoalRuntimeTestFailure.injectedCheckpointFailure
                }
                try await log.append(events)
            })

        let startupSafe = await controller.start()
        XCTAssertFalse(startupSafe)
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(projection.goals[goal.id]?.status, .active)
        XCTAssertTrue(projection.continuationRuns.isEmpty)
        let sendCallCount = await sendCalls.value()
        XCTAssertEqual(sendCallCount, 0)
        XCTAssertEqual(verifier.callCount(), 0)
        await controller.shutdown()
    }

    func testPausedInterruptedRunBecomesInterruptedWithoutExecuting() async throws {
        let log = try runtimeLog("paused-interrupted-recovery")
        let sessionID = await log.sessionID
        let activeGoal = Goal(sessionID: sessionID, objective: "Remain paused after restart")
        let pausedGoal = try activeGoal.transitioning(
            to: .paused,
            expectedRevision: activeGoal.revision).get()
        let createdRun = ContinuationRun(
            sessionID: sessionID,
            goalID: activeGoal.id,
            ordinal: 1)
        let runningRun = try createdRun.transitioning(to: .running).get()
        try await log.append([
            .goalCreated(GoalCreatedPayload(goal: activeGoal)),
            .continuationRunCreated(ContinuationRunCreatedPayload(run: createdRun)),
            .continuationRunStarted(ContinuationRunStartedPayload(run: runningRun)),
            .goalPaused(GoalPausedPayload(goal: pausedGoal)),
        ])

        let cancellationCalls = RuntimeCallCounter()
        let sendCalls = RuntimeCallCounter()
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: activeGoal.objective),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in
                await sendCalls.increment()
                return .sent
            },
            cancelGoalInvocations: { goalID, runID, _, _ in
                XCTAssertEqual(goalID, activeGoal.id)
                XCTAssertEqual(runID, createdRun.id)
                await cancellationCalls.increment()
                return true
            })

        let startupSafe = await controller.start()
        XCTAssertTrue(startupSafe)

        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(projection.goals[activeGoal.id]?.status, .paused)
        XCTAssertEqual(projection.continuationRuns[createdRun.id]?.status, .interrupted)
        let cancellationCallCount = await cancellationCalls.value()
        let sendCallCount = await sendCalls.value()
        XCTAssertEqual(cancellationCallCount, 1)
        XCTAssertEqual(sendCallCount, 0)
        XCTAssertEqual(verifier.callCount(), 0)
        await controller.shutdown()
    }

    func testPausedInterruptedCancellationFailureKeepsStartupUnsafeAndDoesNotExecute() async throws {
        let log = try runtimeLog("paused-interrupted-cancel-failure")
        let sessionID = await log.sessionID
        let activeGoal = Goal(sessionID: sessionID, objective: "Fail closed while paused")
        let pausedGoal = try activeGoal.transitioning(
            to: .paused,
            expectedRevision: activeGoal.revision).get()
        let createdRun = ContinuationRun(
            sessionID: sessionID,
            goalID: activeGoal.id,
            ordinal: 1)
        let runningRun = try createdRun.transitioning(to: .running).get()
        try await log.append([
            .goalCreated(GoalCreatedPayload(goal: activeGoal)),
            .continuationRunCreated(ContinuationRunCreatedPayload(run: createdRun)),
            .continuationRunStarted(ContinuationRunStartedPayload(run: runningRun)),
            .goalPaused(GoalPausedPayload(goal: pausedGoal)),
        ])

        let cancellationCalls = RuntimeCallCounter()
        let sendCalls = RuntimeCallCounter()
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: activeGoal.objective),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in
                await sendCalls.increment()
                return .sent
            },
            cancelGoalInvocations: { goalID, runID, _, _ in
                XCTAssertEqual(goalID, activeGoal.id)
                XCTAssertEqual(runID, createdRun.id)
                await cancellationCalls.increment()
                return false
            })

        let startupSafe = await controller.start()
        XCTAssertFalse(startupSafe)

        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(projection.goals[activeGoal.id]?.status, .paused)
        XCTAssertEqual(projection.continuationRuns[createdRun.id]?.status, .running)
        let ordinaryTurn = await controller.sendUserTurn("must remain stopped")
        guard case .failed(let failure) = ordinaryTurn else {
            return XCTFail("An unsafe startup must reject ordinary Cowork turns")
        }
        XCTAssertTrue(failure.contains("incomplete"))
        do {
            _ = try await controller.pauseCurrentGoal()
            XCTFail("Goal mutations must remain gated after unsafe startup")
        } catch let error as GoalRuntimeError {
            XCTAssertEqual(error, .recoveryInProgress)
        }
        let cancellationCallCount = await cancellationCalls.value()
        let sendCallCount = await sendCalls.value()
        XCTAssertEqual(cancellationCallCount, 1)
        XCTAssertEqual(sendCallCount, 0)
        XCTAssertEqual(verifier.callCount(), 0)
        await controller.shutdown()
    }

    func testGoalControlsFailClosedWhileStartupRecoveryIsInProgress() async throws {
        let log = try runtimeLog("startup-control-gate")
        let sessionID = await log.sessionID
        let goal = Goal(sessionID: sessionID, objective: "Recover before controls")
        let createdRun = ContinuationRun(sessionID: sessionID, goalID: goal.id, ordinal: 1)
        let runningRun = try createdRun.transitioning(to: .running).get()
        try await log.append([
            .goalCreated(GoalCreatedPayload(goal: goal)),
            .continuationRunCreated(ContinuationRunCreatedPayload(run: createdRun)),
            .continuationRunStarted(ContinuationRunStartedPayload(run: runningRun)),
        ])

        let schedulerBarrier = RuntimeAsyncBarrier()
        let cancellationCalls = RuntimeCallCounter()
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: goal.objective),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            policy: GoalRuntimePolicy(noProgressRunThreshold: 1),
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in .sent },
            cancelGoalInvocations: { _, _, _, _ in
                await cancellationCalls.increment()
                await schedulerBarrier.wait()
                return true
            })

        let firstStartTask = Task { await controller.start() }
        await schedulerBarrier.waitUntilEntered()
        let secondStartTask = Task { await controller.start() }
        await Task.yield()

        do {
            _ = try await controller.pauseCurrentGoal()
            XCTFail("Pause must not commit while startup recovery is in progress")
        } catch let error as GoalRuntimeError {
            XCTAssertEqual(error, .recoveryInProgress)
        }
        do {
            _ = try await controller.editCurrentGoal(
                objective: "Changed too early",
                successCriteria: [],
                constraints: [],
                tokenBudget: nil)
            XCTFail("Edit must not commit while startup recovery is in progress")
        } catch let error as GoalRuntimeError {
            XCTAssertEqual(error, .recoveryInProgress)
        }
        do {
            try await controller.clearCurrentGoal(reason: "too early")
            XCTFail("Clear must not commit while startup recovery is in progress")
        } catch let error as GoalRuntimeError {
            XCTAssertEqual(error, .recoveryInProgress)
        }

        let beforeRelease = await log.replay()
        XCTAssertFalse(beforeRelease.contains { envelope in
            switch envelope.event {
            case .goalPaused, .goalEdited, .goalCleared:
                return true
            default:
                return false
            }
        })

        await schedulerBarrier.release()
        let firstStartupSafe = await firstStartTask.value
        let secondStartupSafe = await secondStartTask.value
        XCTAssertTrue(firstStartupSafe)
        XCTAssertTrue(secondStartupSafe)
        let cancellationCallCount = await cancellationCalls.value()
        XCTAssertEqual(cancellationCallCount, 1)
        await controller.shutdown()
    }


    func testPauseRacingDurableRootAdmissionCancelsBeforeProviderExecution() async throws {
        let log = try runtimeLog("pause-during-root-admission")
        let sessionID = await log.sessionID
        let workspace = try runtimeWorkspace("pause-during-root-admission")
        let taskProviderCalls = RuntimeCallCounter()
        let taskProvider = RuntimeVerifierProvider(["must not execute"])
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.deny)) { _ in
                await taskProviderCalls.increment()
                return taskProvider
            }
        let bootstrap = await orchestrator.bootstrapMainAgent(Agent(
            name: Orchestrator.mainAgentID,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "task-model"),
            profile: .readOnly,
            coordinationDepth: Agent.defaultCoordinationDepth))
        guard case .attached = bootstrap else {
            return XCTFail("Fixture could not bootstrap @main: \(bootstrap)")
        }

        let admissionBarrier = RuntimeAsyncBarrier()
        await orchestrator.setAdmissionEventAppender { event in
            if case .taskQueued(let payload) = event,
               payload.contract.kind == .root,
               payload.contract.goalID != nil {
                await admissionBarrier.wait()
            }
            try await log.append(event)
        }
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: "Pause during admission"),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            orchestrator: orchestrator,
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") })

        let goal = try await controller.createGoal(objective: "Pause during admission")
        await admissionBarrier.waitUntilEntered()
        let pauseTask = Task { try await controller.pauseCurrentGoal() }
        try await Task.sleep(nanoseconds: 20_000_000)
        await admissionBarrier.release()
        let paused = try await pauseTask.value

        XCTAssertEqual(paused.status, .paused)
        let taskProviderCallCount = await taskProviderCalls.value()
        XCTAssertEqual(taskProviderCallCount, 0)
        XCTAssertEqual(taskProvider.callCount(), 0)
        XCTAssertEqual(verifier.callCount(), 0)
        let events = await log.replay()
        let projection = CoworkProjection.build(from: events)
        XCTAssertEqual(projection.goals[goal.id]?.status, .paused)
        XCTAssertFalse(events.contains { envelope in
            guard case .taskStarted(let payload) = envelope.event,
                  projection.tasks[payload.taskID]?.contract?.goalID == goal.id else {
                return false
            }
            return true
        })
        XCTAssertTrue(events.contains { envelope in
            guard case .taskCancelled(let payload) = envelope.event,
                  projection.tasks[payload.taskID]?.contract?.goalID == goal.id else {
                return false
            }
            return true
        })
        await controller.shutdown()
    }

    func testPauseFailsClosedWhenCheckpointPersistenceFails() async throws {
        let log = try runtimeLog("pause-checkpoint-failure")
        let sessionID = await log.sessionID
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: "Checkpoint must persist"),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return .sent
                } catch {
                    return .failed("cancelled")
                }
            },
            eventAppender: { events in
                if events.contains(where: { event in
                    guard case .continuationRunCheckpointed = event else { return false }
                    return true
                }) {
                    throw GoalRuntimeTestFailure.injectedCheckpointFailure
                }
                try await log.append(events)
            })

        let goal = try await controller.createGoal(objective: "Checkpoint must persist")
        _ = try await waitForRuntimeProjection(log, label: "run before checkpoint failure") {
            $0.continuationRuns.values.contains {
                $0.goalID == goal.id && $0.status == .running
            }
        }

        do {
            _ = try await controller.pauseCurrentGoal()
            XCTFail("Pause must fail when its safe checkpoint cannot persist")
        } catch let error as GoalRuntimeError {
            guard case .persistence(let message) = error else {
                return XCTFail("Unexpected GoalRuntimeError: \(error)")
            }
            XCTAssertTrue(message.contains("could not be durably cancelled and checkpointed"))
        }

        // The failed stop remains pending. Retrying must attempt the durable
        // checkpoint again, not treat the missing in-memory task as success and
        // commit Pause over a still-running durable run.
        do {
            _ = try await controller.pauseCurrentGoal()
            XCTFail("A retry must also fail while checkpoint persistence is still unavailable")
        } catch let error as GoalRuntimeError {
            guard case .persistence = error else {
                return XCTFail("Unexpected GoalRuntimeError on retry: \(error)")
            }
        }

        let events = await log.replay()
        let projection = CoworkProjection.build(from: events)
        XCTAssertEqual(projection.goals[goal.id]?.status, .active)
        XCTAssertTrue(projection.continuationRuns.values.contains {
            $0.goalID == goal.id && $0.status == .running
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .goalPaused = envelope.event else { return false }
            return true
        })
        await controller.shutdown()
    }

    func testStartRetriesPendingStopBeforeReplayingOrLaunchingNewRun() async throws {
        let log = try runtimeLog("start-retries-pending-stop")
        let sessionID = await log.sessionID
        let persistenceGate = RuntimeCheckpointPersistenceGate()
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: "Retry durable stop before restart"),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return .sent
                } catch {
                    return .failed("cancelled")
                }
            },
            eventAppender: { events in
                try await persistenceGate.append(events, to: log)
            })

        let initialStartupSafe = await controller.start()
        XCTAssertTrue(initialStartupSafe)
        let goal = try await controller.createGoal(
            objective: "Retry durable stop before restart")
        let runningProjection = try await waitForRuntimeProjection(
            log,
            label: "initial run before pending stop") {
                $0.continuationRuns.values.contains {
                    $0.goalID == goal.id && $0.status == .running
                }
            }
        let initialRunID = try XCTUnwrap(runningProjection.continuationRuns.values.first {
            $0.goalID == goal.id && $0.status == .running
        }?.id)

        do {
            _ = try await controller.pauseCurrentGoal()
            XCTFail("Pause must fail while checkpoint persistence is unavailable")
        } catch let error as GoalRuntimeError {
            guard case .persistence = error else {
                return XCTFail("Unexpected GoalRuntimeError: \(error)")
            }
        }

        await persistenceGate.allowCheckpoint()
        let recoveredStartupSafe = await controller.start()
        XCTAssertTrue(recoveredStartupSafe)

        let events = await log.replay()
        let projection = CoworkProjection.build(from: events)
        XCTAssertNotEqual(projection.continuationRuns[initialRunID]?.status, .running)
        XCTAssertEqual(projection.goals[goal.id]?.status, .paused)
        let checkpointIndex = try XCTUnwrap(events.firstIndex { envelope in
            guard case .continuationRunCheckpointed(let payload) = envelope.event else {
                return false
            }
            return payload.run.id == initialRunID
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .continuationRunCreated(let payload) = envelope.event else {
                return false
            }
            return payload.run.goalID == goal.id && payload.run.id != initialRunID
        })
        let pauseIndex = try XCTUnwrap(events.firstIndex { envelope in
            guard case .goalPaused(let payload) = envelope.event else { return false }
            return payload.goal.id == goal.id
        })
        XCTAssertLessThan(checkpointIndex, pauseIndex)

        _ = try await controller.resumeCurrentGoal()
        let resumed = try await waitForRuntimeProjection(log, label: "explicit resume after pending stop") {
            $0.continuationRuns.values.contains {
                $0.goalID == goal.id && $0.id != initialRunID
            }
        }
        XCTAssertEqual(resumed.goals[goal.id]?.status, .active)
        await controller.shutdown()
    }

    func testClearPersistenceFailureRelaunchesStillActiveGoalAfterCheckpoint() async throws {
        let log = try runtimeLog("clear-persistence-relaunch")
        let sessionID = await log.sessionID
        let sendCalls = RuntimeCallCounter()
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: "Remain active when clear fails"),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in
                await sendCalls.increment()
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return .sent
                } catch {
                    return .failed("cancelled")
                }
            },
            eventAppender: { events in
                if events.contains(where: { event in
                    guard case .goalCleared = event else { return false }
                    return true
                }) {
                    throw GoalRuntimeTestFailure.injectedCheckpointFailure
                }
                try await log.append(events)
            })

        let goal = try await controller.createGoal(
            objective: "Remain active when clear fails")
        _ = try await waitForRuntimeProjection(log, label: "run before clear failure") {
            $0.continuationRuns.values.contains {
                $0.goalID == goal.id && $0.status == .running
            }
        }

        do {
            try await controller.clearCurrentGoal(reason: "injected clear failure")
            XCTFail("Clear must surface its persistence failure")
        } catch {
            // Expected: the run checkpoint is durable but goal_cleared is not.
        }

        let relaunched = try await waitForRuntimeProjection(
            log,
            label: "active Goal relaunch after clear failure") {
                $0.goals[goal.id]?.status == .active
                    && $0.continuationRuns.values.filter { $0.goalID == goal.id }.count >= 2
            }
        XCTAssertEqual(relaunched.goals[goal.id]?.status, .active)
        let relaunchedEvents = await log.replay()
        XCTAssertFalse(relaunchedEvents.contains { envelope in
            guard case .goalCleared = envelope.event else { return false }
            return true
        })
        let sendCallCount = await sendCalls.value()
        XCTAssertGreaterThanOrEqual(sendCallCount, 2)
        await controller.shutdown()
    }

    func testShutdownFencesClearFailureTailFromRelaunchingGoal() async throws {
        let log = try runtimeLog("shutdown-fences-clear-tail")
        let sessionID = await log.sessionID
        let clearPersistenceBarrier = RuntimeAsyncBarrier()
        let sendCalls = RuntimeCallCounter()
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: "Do not relaunch after shutdown"),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in
                await sendCalls.increment()
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return .sent
                } catch {
                    return .failed("cancelled")
                }
            },
            eventAppender: { events in
                if events.contains(where: { event in
                    if case .goalCleared = event { return true }
                    return false
                }) {
                    await clearPersistenceBarrier.wait()
                    throw GoalRuntimeTestFailure.injectedCheckpointFailure
                }
                try await log.append(events)
            })

        let startupSafe = await controller.start()
        XCTAssertTrue(startupSafe)
        let goal = try await controller.createGoal(
            objective: "Do not relaunch after shutdown")
        _ = try await waitForRuntimeProjection(log, label: "run before clear/shutdown race") {
            $0.continuationRuns.values.contains {
                $0.goalID == goal.id && $0.status == .running
            }
        }

        let clearTask = Task { () -> Bool in
            do {
                try await controller.clearCurrentGoal(reason: "injected clear failure")
                return false
            } catch {
                return true
            }
        }
        await clearPersistenceBarrier.waitUntilEntered()
        await controller.shutdown()
        await clearPersistenceBarrier.release()
        let clearFailed = await clearTask.value
        XCTAssertTrue(clearFailed)
        try await Task.sleep(nanoseconds: 30_000_000)

        let sendCallCount = await sendCalls.value()
        XCTAssertEqual(sendCallCount, 1)
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(
            projection.continuationRuns.values.filter { $0.goalID == goal.id }.count,
            1)
        XCTAssertEqual(projection.goals[goal.id]?.status, .active)
    }

    func testSendUserTurnAfterShutdownFailsWithoutAdmittingRunOrProvider() async throws {
        let log = try runtimeLog("send-after-shutdown")
        let sessionID = await log.sessionID
        let sendCalls = RuntimeCallCounter()
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: "must remain stopped"),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in
                await sendCalls.increment()
                return .sent
            })

        let startupSafe = await controller.start()
        XCTAssertTrue(startupSafe)
        await controller.shutdown()

        let result = await controller.sendUserTurn("must remain stopped")
        guard case .failed(let message) = result else {
            return XCTFail("A stopped runtime must reject a new ordinary turn")
        }
        XCTAssertTrue(message.contains("incomplete") || message.contains("stopped"))
        let sendCallCount = await sendCalls.value()
        XCTAssertEqual(sendCallCount, 0)
        XCTAssertEqual(verifier.callCount(), 0)
        let replayed = await log.replay()
        let projection = CoworkProjection.build(from: replayed)
        XCTAssertTrue(projection.continuationRuns.isEmpty)
    }

    func testShutdownDuringPauseCancellationDoesNotResumePendingInvocations() async throws {
        let log = try runtimeLog("shutdown-during-pause")
        let sessionID = await log.sessionID
        let cancellationBarrier = RuntimeAsyncBarrier()
        let resumeCalls = RuntimeCallCounter()
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: "Pause without waking after shutdown"),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return .sent
                } catch {
                    return .failed("cancelled by lifecycle control")
                }
            },
            resumePendingInvocations: {
                await resumeCalls.increment()
            },
            cancelGoalInvocations: { _, _, _, _ in
                await cancellationBarrier.wait()
                return true
            })

        let startupSafe = await controller.start()
        XCTAssertTrue(startupSafe)
        let goal = try await controller.createGoal(
            objective: "Pause without waking after shutdown")
        _ = try await waitForRuntimeProjection(log, label: "run before pause/shutdown race") {
            $0.continuationRuns.values.contains {
                $0.goalID == goal.id && $0.status == .running
            }
        }

        let pauseTask = Task { () -> Bool in
            do {
                _ = try await controller.pauseCurrentGoal()
                return true
            } catch {
                return false
            }
        }
        await cancellationBarrier.waitUntilEntered()
        let shutdownTask = Task { await controller.shutdown() }
        // Give shutdown a deterministic scheduling window to set its lifecycle
        // fence while Pause still owns the stop lock and cancellation is held.
        try await Task.sleep(nanoseconds: 30_000_000)
        await cancellationBarrier.release()

        let pauseSucceeded = await pauseTask.value
        await shutdownTask.value
        XCTAssertTrue(pauseSucceeded)
        let resumeCallCount = await resumeCalls.value()
        XCTAssertEqual(resumeCallCount, 0)
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertFalse(projection.continuationRuns.values.contains {
            $0.goalID == goal.id
                && ($0.status == .created || $0.status == .running)
        })
    }

    func testStartCancelsInterruptedActiveRunWithoutWakingSchedulerBeforeRecovery() async throws {
        let log = try runtimeLog("recovery-cancel-without-resume")
        let sessionID = await log.sessionID
        let goal = Goal(sessionID: sessionID, objective: "Recover after scheduler settles")
        let createdRun = ContinuationRun(sessionID: sessionID, goalID: goal.id, ordinal: 1)
        let runningRun = try createdRun.transitioning(to: .running).get()
        try await log.append([
            .goalCreated(GoalCreatedPayload(goal: goal)),
            .continuationRunCreated(ContinuationRunCreatedPayload(run: createdRun)),
            .continuationRunStarted(ContinuationRunStartedPayload(run: runningRun)),
        ])

        let hookRecorder = RuntimeGoalHookRecorder()
        let cancellationCalls = RuntimeCallCounter()
        let resumeCalls = RuntimeCallCounter()
        let verifier = RuntimeVerifierProvider([continuingRuntimeAudit(objective: goal.objective)])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            policy: GoalRuntimePolicy(noProgressRunThreshold: 1),
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in .sent },
            resumePendingInvocations: {
                await resumeCalls.increment()
            },
            waitForGoalSchedulerIdle: { goalID, runID in
                await hookRecorder.record(.wait(goalID, runID))
            },
            cancelGoalInvocations: { goalID, runID, _, _ in
                XCTAssertEqual(goalID, goal.id)
                XCTAssertEqual(runID, createdRun.id)
                await cancellationCalls.increment()
                return true
            })

        let startupSafe = await controller.start()
        XCTAssertTrue(startupSafe)
        let cancellationCallCount = await cancellationCalls.value()
        let resumeCallCount = await resumeCalls.value()
        let schedulerWaitEvents = await hookRecorder.events()
        XCTAssertEqual(cancellationCallCount, 1)
        XCTAssertEqual(resumeCallCount, 0)
        XCTAssertTrue(schedulerWaitEvents.isEmpty)

        let afterRelease = await log.replay()
        let afterProjection = CoworkProjection.build(from: afterRelease)
        XCTAssertEqual(afterProjection.continuationRuns[createdRun.id]?.status, .interrupted)
        XCTAssertEqual(afterProjection.goals[goal.id]?.status, .paused)
        XCTAssertEqual(afterProjection.continuationRuns.count, 1)
        XCTAssertEqual(verifier.callCount(), 0)
        XCTAssertTrue(afterRelease.contains { envelope in
            guard case .continuationRunInterrupted(let payload) = envelope.event else { return false }
            return payload.run.id == createdRun.id
                && payload.run.progressSummary == "Recovered after runtime interruption"
        })
        XCTAssertFalse(afterRelease.contains { envelope in
            if case .goalAuditCompleted = envelope.event { return true }
            return false
        })
        await controller.shutdown()
    }

    func testCancelledStartAfterRecoveryPauseReturnsUnsafeWithoutLaunching() async throws {
        let log = try runtimeLog("cancelled-start-after-pause")
        let sessionID = await log.sessionID
        let goal = Goal(
            sessionID: sessionID,
            objective: "Cancel startup after recovery pause")
        try await log.append(.goalCreated(GoalCreatedPayload(goal: goal)))

        let postRecoveryBarrier = RuntimeAsyncBarrier()
        let sendCalls = RuntimeCallCounter()
        let cancellationCalls = RuntimeCallCounter()
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: goal.objective),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in
                await sendCalls.increment()
                return .sent
            },
            cancelGoalInvocations: { cancelledGoalID, _, _, _ in
                XCTAssertEqual(cancelledGoalID, goal.id)
                await cancellationCalls.increment()
                return true
            },
            startupPostRecoveryHook: {
                await postRecoveryBarrier.wait()
            })

        let startTask = Task { await controller.start() }
        await postRecoveryBarrier.waitUntilEntered()
        let pausedProjection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(pausedProjection.goals[goal.id]?.status, .paused)
        XCTAssertTrue(pausedProjection.continuationRuns.isEmpty)
        let preCancelSendCalls = await sendCalls.value()
        XCTAssertEqual(preCancelSendCalls, 0)
        XCTAssertEqual(verifier.callCount(), 0)

        startTask.cancel()
        await postRecoveryBarrier.release()
        let startupSafe = await startTask.value
        XCTAssertFalse(startupSafe)

        let cancellationCallCount = await cancellationCalls.value()
        let finalSendCalls = await sendCalls.value()
        XCTAssertEqual(cancellationCallCount, 0)
        XCTAssertEqual(finalSendCalls, 0)
        let replayed = await log.replay()
        let projection = CoworkProjection.build(from: replayed)
        XCTAssertEqual(projection.goals[goal.id]?.status, .paused)
        XCTAssertTrue(projection.continuationRuns.isEmpty)
        await controller.shutdown()
    }

    func testEachNewGoalRunUsesMatchingScopedBarrier() async throws {
        let log = try runtimeLog("run-hook-order")
        let sessionID = await log.sessionID
        let hookRecorder = RuntimeGoalHookRecorder()
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: "Continue with carried Tasks"),
            continuingRuntimeAudit(objective: "Continue with carried Tasks"),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            policy: GoalRuntimePolicy(noProgressRunThreshold: 2),
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, goalID, runID, _ in
                guard let goalID, let runID else { return .failed("missing Goal run scope") }
                await hookRecorder.record(.send(goalID, runID))
                return .sent
            },
            waitForGoalSchedulerIdle: { goalID, runID in
                await hookRecorder.record(.wait(goalID, runID))
            })

        let created = try await controller.createGoal(
            objective: "Continue with carried Tasks")
        let projection = try await waitForRuntimeProjection(
            log,
            label: "two scoped Goal runs") {
                $0.goals[created.id]?.noProgressRuns == 2
            }
        let runs = projection.continuationRuns.values
            .filter { $0.goalID == created.id }
            .sorted { $0.ordinal < $1.ordinal }
        XCTAssertEqual(runs.count, 2)

        let expectedEvents: [RuntimeGoalHookRecorder.Event] = runs.flatMap { run in
            [
                .send(created.id, run.id),
                .wait(created.id, run.id),
            ]
        }
        let events = await hookRecorder.events()
        XCTAssertEqual(events, expectedEvents)
        await controller.shutdown()
    }

    func testProviderUsageLimitSkipsVerifierAndDurablyMarksGoalUsageLimited() async throws {
        let log = try runtimeLog("provider-usage-limit")
        let sessionID = await log.sessionID
        let hookRecorder = RuntimeGoalHookRecorder()
        let verifierFactoryCalls = RuntimeCallCounter()
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: "Do not invoke verifier"),
        ])
        let reason = "Provider account hard usage limit reached"
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            verifierProvider: {
                await verifierFactoryCalls.increment()
                return verifier
            },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, goalID, runID, _ in
                guard goalID != nil, runID != nil else {
                    return .failed("missing Goal run scope")
                }
                return .sent
            },
            consumeProviderUsageLimit: { goalID, runID in
                await hookRecorder.record(.consumeUsageLimit(goalID, runID))
                return reason
            })

        let created = try await controller.createGoal(
            objective: "Stop at provider usage limit")
        let projection = try await waitForRuntimeProjection(
            log,
            label: "durable provider usage limit") {
                $0.goals[created.id]?.status == .usageLimited
            }
        let limited = try XCTUnwrap(projection.goals[created.id])
        XCTAssertEqual(limited.status, .usageLimited)

        let run = try XCTUnwrap(projection.continuationRuns.values.first {
            $0.goalID == created.id
        })
        let hookEvents = await hookRecorder.events()
        XCTAssertEqual(hookEvents, [.consumeUsageLimit(created.id, run.id)])
        let factoryCallCount = await verifierFactoryCalls.value()
        XCTAssertEqual(factoryCallCount, 0)
        XCTAssertEqual(verifier.callCount(), 0)

        let persistedReasons = await log.replay().compactMap { envelope -> String? in
            guard case .goalUsageLimited(let payload) = envelope.event,
                  payload.goal.id == created.id else { return nil }
            return payload.reason
        }
        XCTAssertEqual(persistedReasons, [reason])
        await controller.shutdown()
    }

    func testRestoreProviderUsageLimitSettlesOriginalRunWithoutLaunchingNewWork() async throws {
        let log = try runtimeLog("restore-provider-usage-limit")
        let sessionID = await log.sessionID
        let goal = Goal(sessionID: sessionID, objective: "Stop restored Goal at usage limit")
        let createdRun = ContinuationRun(sessionID: sessionID, goalID: goal.id, ordinal: 1)
        let runningRun = try createdRun.transitioning(to: .running).get()
        let checkpointedRun = try runningRun.transitioning(to: .checkpointed).get()
        let taskID = TaskID.new()
        let contract = TaskContract(
            id: taskID,
            kind: .root,
            issuer: nil,
            assignee: Orchestrator.mainAgentID,
            continuationRunID: createdRun.id,
            goalID: goal.id,
            objective: "Consume the exhausted provider",
            roleHint: "root",
            expectedDeliverable: "Result",
            replyMode: TaskReplyMode.none,
            maxAttempts: 1)
        let metadata = CoworkEventMetadata(
            taskID: taskID,
            rootTaskID: taskID,
            agentID: Orchestrator.mainAgentID,
            assignee: Orchestrator.mainAgentID,
            scope: .task)
        let usageLimitReason = "Provider account hard usage limit reached"
        try await log.append([
            .goalCreated(GoalCreatedPayload(goal: goal)),
            .continuationRunCreated(ContinuationRunCreatedPayload(run: createdRun)),
            .continuationRunStarted(ContinuationRunStartedPayload(run: runningRun)),
            .continuationRunCheckpointed(ContinuationRunCheckpointedPayload(run: checkpointedRun)),
            .taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)),
            .taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)),
            .taskQueued(TaskQueuedPayload(
                contract: contract,
                rootTaskID: taskID,
                assignee: Orchestrator.mainAgentID,
                hopCount: 0,
                visitedAgents: [Orchestrator.mainAgentID],
                attempt: 1,
                metadata: metadata)),
            .taskStarted(TaskStartedPayload(
                taskID: taskID,
                agent: Orchestrator.mainAgentID,
                attempt: 1,
                metadata: metadata)),
            .taskFailed(TaskFailedPayload(
                taskID: taskID,
                agent: Orchestrator.mainAgentID,
                error: usageLimitReason,
                failureCode: .providerUsageLimit,
                attempt: 1,
                metadata: metadata)),
        ])

        let taskProviderFactoryCalls = RuntimeCallCounter()
        let taskProvider = RuntimeVerifierProvider(["unused task response"])
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.deny)) { _ in
                await taskProviderFactoryCalls.increment()
                return taskProvider
            }
        let durableProjection = CoworkProjection.build(from: await log.replay())
        await orchestrator.restore(from: durableProjection)

        let verifierFactoryCalls = RuntimeCallCounter()
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: goal.objective),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            orchestrator: orchestrator,
            verifierProvider: {
                await verifierFactoryCalls.increment()
                return verifier
            },
            verifierModel: { ModelID(rawValue: "verifier") })
        await controller.start()

        let events = await log.replay()
        let projection = CoworkProjection.build(from: events)
        XCTAssertEqual(projection.goals[goal.id]?.status, .usageLimited)
        XCTAssertEqual(projection.continuationRuns[createdRun.id]?.status, .completed)
        XCTAssertEqual(projection.continuationRuns.values.filter { $0.goalID == goal.id }.count, 1)
        let settlement = Array(events.suffix(3))
        XCTAssertEqual(settlement.map(\.seq), Array(settlement[0].seq...settlement[0].seq + 2))
        XCTAssertTrue({
            guard case .goalAuditCompleted(let payload) = settlement[0].event else { return false }
            return payload.goal.id == goal.id && payload.runID == createdRun.id
        }())
        XCTAssertTrue({
            guard case .continuationRunCompleted(let payload) = settlement[1].event else { return false }
            return payload.run.id == createdRun.id
        }())
        XCTAssertTrue({
            guard case .goalUsageLimited(let payload) = settlement[2].event else { return false }
            return payload.goal.id == goal.id && payload.reason == usageLimitReason
        }())
        let taskFactoryCallCount = await taskProviderFactoryCalls.value()
        let verifierFactoryCallCount = await verifierFactoryCalls.value()
        XCTAssertEqual(taskFactoryCallCount, 0)
        XCTAssertEqual(taskProvider.callCount(), 0)
        XCTAssertEqual(verifierFactoryCallCount, 0)
        XCTAssertEqual(verifier.callCount(), 0)
        await controller.shutdown()
    }

    func testPausedProviderUsageLimitSurvivesRestoreAndSettlesOnResume() async throws {
        let log = try runtimeLog("restore-paused-provider-usage-limit")
        let sessionID = await log.sessionID
        let activeGoal = Goal(sessionID: sessionID, objective: "Resume into durable usage limit")
        let pausedGoal = try activeGoal.transitioning(
            to: .paused,
            expectedRevision: activeGoal.revision).get()
        let createdRun = ContinuationRun(sessionID: sessionID, goalID: activeGoal.id, ordinal: 1)
        let runningRun = try createdRun.transitioning(to: .running).get()
        let checkpointedRun = try runningRun.transitioning(to: .checkpointed).get()
        let taskID = TaskID.new()
        let contract = TaskContract(
            id: taskID,
            kind: .root,
            issuer: nil,
            assignee: Orchestrator.mainAgentID,
            continuationRunID: createdRun.id,
            goalID: activeGoal.id,
            objective: "Observe exhausted provider",
            roleHint: "root",
            expectedDeliverable: "Result",
            replyMode: TaskReplyMode.none,
            maxAttempts: 1)
        let metadata = CoworkEventMetadata(
            taskID: taskID,
            rootTaskID: taskID,
            agentID: Orchestrator.mainAgentID,
            assignee: Orchestrator.mainAgentID,
            scope: .task)
        let reason = "Provider account hard usage limit reached while paused"
        try await log.append([
            .goalCreated(GoalCreatedPayload(goal: activeGoal)),
            .continuationRunCreated(ContinuationRunCreatedPayload(run: createdRun)),
            .continuationRunStarted(ContinuationRunStartedPayload(run: runningRun)),
            .continuationRunCheckpointed(ContinuationRunCheckpointedPayload(run: checkpointedRun)),
            .taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)),
            .taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)),
            .taskQueued(TaskQueuedPayload(
                contract: contract,
                rootTaskID: taskID,
                assignee: Orchestrator.mainAgentID,
                hopCount: 0,
                visitedAgents: [Orchestrator.mainAgentID],
                attempt: 1,
                metadata: metadata)),
            .taskStarted(TaskStartedPayload(
                taskID: taskID,
                agent: Orchestrator.mainAgentID,
                attempt: 1,
                metadata: metadata)),
            .taskFailed(TaskFailedPayload(
                taskID: taskID,
                agent: Orchestrator.mainAgentID,
                error: reason,
                failureCode: .providerUsageLimit,
                attempt: 1,
                metadata: metadata)),
            .goalPaused(GoalPausedPayload(goal: pausedGoal)),
        ])

        let taskProviderCalls = RuntimeCallCounter()
        let taskProvider = RuntimeVerifierProvider(["unused"])
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.deny)) { _ in
                await taskProviderCalls.increment()
                return taskProvider
            }
        await orchestrator.restore(from: CoworkProjection.build(from: await log.replay()))

        let verifierCalls = RuntimeCallCounter()
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: activeGoal.objective),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            orchestrator: orchestrator,
            verifierProvider: {
                await verifierCalls.increment()
                return verifier
            },
            verifierModel: { ModelID(rawValue: "verifier") })
        await controller.start()
        let restoredStatus = await controller.currentGoal()?.status
        XCTAssertEqual(restoredStatus, .paused)

        _ = try await controller.resumeCurrentGoal()
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(projection.goals[activeGoal.id]?.status, .usageLimited)
        XCTAssertEqual(projection.continuationRuns[createdRun.id]?.status, .completed)
        XCTAssertEqual(projection.continuationRuns.values.filter {
            $0.goalID == activeGoal.id
        }.count, 1)
        let taskProviderCallCount = await taskProviderCalls.value()
        let verifierCallCount = await verifierCalls.value()
        XCTAssertEqual(taskProviderCallCount, 0)
        XCTAssertEqual(verifierCallCount, 0)
        XCTAssertEqual(taskProvider.callCount(), 0)
        XCTAssertEqual(verifier.callCount(), 0)
        await controller.shutdown()
    }

    func testActiveContinuationRejectsOrdinaryTurnWithoutCreatingRun() async throws {
        let log = try runtimeLog("active-rejects-ordinary")
        let sessionID = await log.sessionID
        let schedulerBarrier = RuntimeAsyncBarrier()
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: "Keep the Goal run active"),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            policy: GoalRuntimePolicy(noProgressRunThreshold: 1),
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in .sent },
            waitForSchedulerIdle: { await schedulerBarrier.wait() })

        let goal = try await controller.createGoal(objective: "Keep the Goal run active")
        await schedulerBarrier.waitUntilEntered()

        let beforeTurn = await log.replay()
        let beforeProjection = CoworkProjection.build(from: beforeTurn)
        XCTAssertTrue(beforeProjection.continuationRuns.values.contains {
            $0.goalID == goal.id && $0.status == .running
        })
        XCTAssertFalse(beforeProjection.continuationRuns.values.contains { $0.goalID == nil })

        let result = await controller.sendUserTurn("unrelated ordinary turn")
        guard case .failed(let message) = result else {
            XCTFail("Expected an active Goal continuation to reject the ordinary turn")
            await schedulerBarrier.release()
            await controller.shutdown()
            return
        }
        XCTAssertTrue(message.contains("actively continuing"))

        let afterTurn = await log.replay()
        let afterProjection = CoworkProjection.build(from: afterTurn)
        XCTAssertEqual(afterTurn.count, beforeTurn.count)
        XCTAssertFalse(afterProjection.continuationRuns.values.contains { $0.goalID == nil })

        await schedulerBarrier.release()
        await controller.shutdown()
    }

    func testOrdinaryTurnPersistsRunLifecycleWithoutCreatingGoal() async throws {
        let log = try runtimeLog("ordinary")
        let sessionID = await log.sessionID
        let recorder = RuntimeSendRecorder()
        let verifier = RuntimeVerifierProvider([continuingRuntimeAudit(objective: "unused")])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, target, _, _, goalID, runID, recordUserMessage in
                await recorder.record(
                    target: target,
                    goalID: goalID,
                    runID: runID,
                    recordUserMessage: recordUserMessage)
                return .sent
            })

        let result = await controller.sendUserTurn("ordinary Cowork turn")
        XCTAssertEqual(result, .sent)
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertNil(projection.currentGoal)
        XCTAssertEqual(projection.continuationRuns.count, 1)
        let run = try XCTUnwrap(projection.continuationRuns.values.first)
        XCTAssertNil(run.goalID)
        XCTAssertEqual(run.ordinal, 0)
        XCTAssertEqual(run.status, .completed)
        let calls = await recorder.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(calls[0].goalID)
        XCTAssertEqual(calls[0].runID, run.id)
        XCTAssertTrue(calls[0].recordUserMessage)
    }

    func testCreateGoalRunsAndCompletesOnlyAfterEvidenceBackedVerifierAudit() async throws {
        let log = try runtimeLog("complete")
        let sessionID = await log.sessionID
        let recorder = RuntimeSendRecorder()
        let verifier = RuntimeVerifierProvider([completeRuntimeAudit()])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, target, _, _, goalID, runID, recordUserMessage in
                await recorder.record(
                    target: target,
                    goalID: goalID,
                    runID: runID,
                    recordUserMessage: recordUserMessage)
                guard let goalID, let runID,
                      await appendCompletedRuntimeValidationEvidence(
                        log: log,
                        goalID: goalID,
                        runID: runID) else {
                    return .failed("fixture could not persist evidence")
                }
                return .sent
            })

        let created = try await controller.createGoal(
            objective: "Finish feature",
            successCriteria: ["Tests pass"])
        let projection = try await waitForRuntimeProjection(
            log,
            label: "Goal completion") {
                $0.goals[created.id]?.status == .completed
            }
        let completed = try XCTUnwrap(projection.goals[created.id])
        XCTAssertTrue(completed.latestAudit?.isCompletionProof == true)
        XCTAssertEqual(projection.continuationRuns.values.filter { $0.goalID == created.id }.count, 1)
        XCTAssertTrue(projection.workTasks.isEmpty)
        let calls = await recorder.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].target, Orchestrator.mainAgentID)
        XCTAssertEqual(calls[0].goalID, created.id)
        XCTAssertFalse(calls[0].recordUserMessage)
    }

    func testMissingEvidenceDowngradesCompletionAndNoProgressGuardStopsAfterTwoRuns() async throws {
        let log = try runtimeLog("no-progress")
        let sessionID = await log.sessionID
        let verifier = RuntimeVerifierProvider([
            missingEvidenceCompletionAudit(),
            missingEvidenceCompletionAudit(),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            policy: GoalRuntimePolicy(noProgressRunThreshold: 2),
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in .sent })

        let created = try await controller.createGoal(objective: "Need proof")
        let projection = try await waitForRuntimeProjection(
            log,
            label: "no-progress guard") {
                $0.goals[created.id]?.noProgressRuns == 2
            }
        let current = try XCTUnwrap(projection.goals[created.id])
        XCTAssertEqual(current.status, .active)
        XCTAssertEqual(current.latestAudit?.verdict, .continue)
        XCTAssertFalse(current.latestAudit?.progressMade ?? true)
        XCTAssertTrue(current.latestAudit?.remainingWork.contains {
            $0.contains("authoritative evidence") || $0.contains("proof")
        } == true)
        XCTAssertEqual(projection.continuationRuns.values.filter {
            $0.goalID == created.id
        }.count, 2)
        try await Task.sleep(nanoseconds: 50_000_000)
        let stable = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(stable.continuationRuns.values.filter {
            $0.goalID == created.id
        }.count, 2)
    }

    func testSameBlockerMustRepeatForThreeCompletedRunsBeforeGoalBlocks() async throws {
        let log = try runtimeLog("blocked")
        let sessionID = await log.sessionID
        let verifier = RuntimeVerifierProvider([
            blockedRuntimeAudit(),
            blockedRuntimeAudit(),
            blockedRuntimeAudit(),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            policy: GoalRuntimePolicy(blockedRunThreshold: 3, noProgressRunThreshold: 2),
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in .sent })

        let created = try await controller.createGoal(objective: "Wait for external approval")
        let projection = try await waitForRuntimeProjection(
            log,
            label: "three-run blocker") {
                $0.goals[created.id]?.status == .blocked
            }
        let blocked = try XCTUnwrap(projection.goals[created.id])
        XCTAssertEqual(blocked.consecutiveBlockedRuns, 3)
        XCTAssertEqual(blocked.blockerFingerprint, "external approval unavailable")
        XCTAssertEqual(projection.continuationRuns.values.filter {
            $0.goalID == created.id && $0.status == .completed
        }.count, 3)
        let audits = await log.replay().compactMap { envelope -> GoalAuditCompletedPayload? in
            guard case .goalAuditCompleted(let payload) = envelope.event else { return nil }
            return payload.goal.id == created.id ? payload : nil
        }
        XCTAssertEqual(audits.map { $0.goal.consecutiveBlockedRuns }, [1, 2, 3])
    }

    func testPauseResumeReconcilesPriorCheckpointBeforeClearCheckpointsCurrentRun() async throws {
        let log = try runtimeLog("controls")
        let sessionID = await log.sessionID
        let cancellations = RuntimeCancellationRecorder()
        let verifier = RuntimeVerifierProvider([continuingRuntimeAudit(objective: "Long Goal")])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return .sent
                } catch {
                    return .failed("cancelled by host control")
                }
            },
            cancelActiveInvocations: { reason, _ in
                await cancellations.record(reason)
            })

        let created = try await controller.createGoal(objective: "Long Goal")
        _ = try await waitForRuntimeProjection(log, label: "first run start") {
            $0.continuationRuns.values.contains {
                $0.goalID == created.id && $0.status == .running
            }
        }
        let paused = try await controller.pauseCurrentGoal()
        XCTAssertEqual(paused.status, .paused)
        let resumed = try await controller.resumeCurrentGoal()
        XCTAssertEqual(resumed.status, .active)
        _ = try await waitForRuntimeProjection(log, label: "resumed run start") {
            $0.continuationRuns.values.filter { $0.goalID == created.id }.count >= 2
                && $0.continuationRuns.values.contains {
                    $0.goalID == created.id && $0.status == .running
                }
        }
        try await controller.clearCurrentGoal(reason: "user cleared")

        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertNil(projection.currentGoalID)
        let goalRuns = projection.continuationRuns.values.filter { $0.goalID == created.id }
        XCTAssertEqual(goalRuns.count, 2)
        XCTAssertEqual(goalRuns.filter { $0.status == .completed }.count, 1)
        XCTAssertEqual(goalRuns.filter { $0.status == .checkpointed }.count, 1)
        let auditedRunIDs = await log.replay().compactMap { envelope -> ContinuationRunID? in
            guard case .goalAuditCompleted(let payload) = envelope.event,
                  payload.goal.id == created.id else { return nil }
            return payload.runID
        }
        XCTAssertEqual(Set(auditedRunIDs), Set(goalRuns.filter {
            $0.status == .completed
        }.map(\.id)))
        let reasons = await cancellations.values()
        XCTAssertEqual(reasons.count, 2)
    }

    func testExplicitTokenBudgetTransitionsToBudgetLimited() async throws {
        let log = try runtimeLog("budget")
        let sessionID = await log.sessionID
        let verifier = RuntimeVerifierProvider([continuingRuntimeAudit(objective: "Budgeted Goal")])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, goalID, runID, _ in
                guard let goalID, let runID else { return .failed("missing scope") }
                _ = try? await log.append(.turnStats(TurnStatsPayload(
                    totalTokens: 5,
                    model: "worker",
                    goalID: goalID,
                    continuationRunID: runID,
                    agentID: Orchestrator.mainAgentID)))
                return .sent
            })

        let created = try await controller.createGoal(
            objective: "Budgeted Goal",
            tokenBudget: 5)
        let projection = try await waitForRuntimeProjection(
            log,
            label: "budget limit") {
                $0.goals[created.id]?.status == .budgetLimited
            }
        let limited = try XCTUnwrap(projection.goals[created.id])
        XCTAssertEqual(limited.tokenBudget, 5)
        XCTAssertGreaterThanOrEqual(limited.tokensUsed, 5)
        XCTAssertEqual(projection.continuationRuns.values.filter {
            $0.goalID == created.id
        }.count, 1)
    }

    func testRecoveryWithoutGoalOnlyAllowsUnresolvedTicketScopedToTerminalTask() async throws {
        let scenarios: [(
            label: String,
            recordsTask: Bool,
            recordsTerminalTask: Bool,
            ticketHasTaskID: Bool,
            preparedAttempt: Int?,
            terminalAttempt: Int?,
            terminalBeforePrepare: Bool,
            expectedStartupSafe: Bool
        )] = [
            ("terminal-task", true, true, true, 1, 1, false, true),
            ("nonterminal-task", true, false, true, 1, nil, false, false),
            ("missing-task", false, false, true, 1, nil, false, false),
            ("orphan-terminal", false, true, true, 1, 1, false, false),
            ("attempt-mismatch", true, true, true, 1, 2, false, false),
            ("terminal-before-prepare", true, true, true, 1, 1, true, false),
            ("legacy-attempt-missing", true, true, true, nil, 1, false, false),
            ("unscoped", false, false, false, 1, nil, false, false),
        ]

        for scenario in scenarios {
            let log = try runtimeLog("recover-no-goal-\(scenario.label)")
            let sessionID = await log.sessionID
            let taskID = TaskID(rawValue: "task-\(scenario.label)")
            let contract = TaskContract(
                id: taskID,
                kind: .root,
                issuer: nil,
                assignee: Orchestrator.mainAgentID,
                objective: "Historical task for \(scenario.label)",
                roleHint: "root",
                expectedDeliverable: "Historical result",
                replyMode: TaskReplyMode.none,
                maxAttempts: 1)
            let prepared = ToolExecutionPreparedPayload(
                executionID: "unresolved-\(scenario.label)",
                taskID: scenario.ticketHasTaskID ? taskID : nil,
                attempt: scenario.preparedAttempt,
                toolCallID: "call-\(scenario.label)",
                agent: Orchestrator.mainAgentID,
                tool: "write_file",
                sideEffect: .write,
                replayPolicy: .doNotReplay)
            var events: [Event] = []
            if scenario.recordsTask {
                events.append(.taskCreated(TaskCreatedPayload(contract: contract)))
            }
            let terminalEvent: Event? = scenario.recordsTerminalTask
                ? .taskFailed(TaskFailedPayload(
                    taskID: taskID,
                    agent: Orchestrator.mainAgentID,
                    error: "interrupted non-replayable tool call",
                    attempt: scenario.terminalAttempt))
                : nil
            if scenario.terminalBeforePrepare, let terminalEvent {
                events.append(terminalEvent)
            }
            events.append(.toolExecutionPrepared(prepared))
            if !scenario.terminalBeforePrepare, let terminalEvent {
                events.append(terminalEvent)
            }
            try await log.append(events)

            let sendCalls = RuntimeCallCounter()
            let verifier = RuntimeVerifierProvider([
                continuingRuntimeAudit(objective: "unused"),
            ])
            let controller = GoalRuntimeController(
                sessionID: sessionID,
                log: log,
                verifierProvider: { verifier },
                verifierModel: { ModelID(rawValue: "verifier") },
                sendOperation: { _, _, _, _, _, _, _ in
                    await sendCalls.increment()
                    return .sent
                })

            let startupSafe = await controller.start()
            XCTAssertEqual(startupSafe, scenario.expectedStartupSafe, scenario.label)

            let turnResult = await controller.sendUserTurn("new work after recovery")
            if scenario.expectedStartupSafe {
                XCTAssertEqual(turnResult, .sent, scenario.label)
            } else {
                guard case .failed(let message) = turnResult else {
                    await controller.shutdown()
                    XCTFail("\(scenario.label) must keep ordinary turns fail-closed")
                    continue
                }
                XCTAssertTrue(message.contains("incomplete"), scenario.label)
            }
            let sendCallCount = await sendCalls.value()
            XCTAssertEqual(sendCallCount, scenario.expectedStartupSafe ? 1 : 0, scenario.label)
            await controller.shutdown()
        }
    }

    func testRecoveryWithCurrentGoalRejectsSettledUnknownEffects() async throws {
        let cases: [(
            label: String,
            outcome: ToolExecutionOutcome,
            disposition: ToolExecutionEffectDisposition?
        )] = [
            ("explicit-unknown", .failed, .unknown),
            ("legacy-failed", .failed, nil),
            ("contradictory-success-not-started", .succeeded, .notStarted),
        ]

        for item in cases {
            let log = try runtimeLog("recover-goal-\(item.label)")
            let sessionID = await log.sessionID
            let goal = Goal(sessionID: sessionID, objective: "Do not resume unknown effects")
            let prepared = ToolExecutionPreparedPayload(
                executionID: "unknown-effect-\(item.label)",
                toolCallID: "unknown-call-\(item.label)",
                agent: Orchestrator.mainAgentID,
                tool: "write_file",
                sideEffect: .write,
                replayPolicy: .doNotReplay)
            try await log.append([
                .goalCreated(GoalCreatedPayload(goal: goal)),
                .toolExecutionPrepared(prepared),
                .toolExecutionSettled(ToolExecutionSettledPayload(
                    prepared: prepared,
                    outcome: item.outcome,
                    effectDisposition: item.disposition,
                    reason: "outcome cannot prove whether the write occurred")),
            ])

            let sendCalls = RuntimeCallCounter()
            let verifier = RuntimeVerifierProvider([
                continuingRuntimeAudit(objective: goal.objective),
            ])
            let controller = GoalRuntimeController(
                sessionID: sessionID,
                log: log,
                verifierProvider: { verifier },
                verifierModel: { ModelID(rawValue: "verifier") },
                sendOperation: { _, _, _, _, _, _, _ in
                    await sendCalls.increment()
                    return .sent
                })

            let startupSafe = await controller.start()
            let callCount = await sendCalls.value()
            XCTAssertFalse(startupSafe, item.label)
            XCTAssertEqual(callCount, 0, item.label)
            await controller.shutdown()
        }
    }

    func testInProcessGoalLaunchRejectsSettledUnknownEffects() async throws {
        let log = try runtimeLog("live-goal-unknown-effect")
        let sessionID = await log.sessionID
        let sendCalls = RuntimeCallCounter()
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: "Do not launch through unknown effects"),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in
                await sendCalls.increment()
                return .sent
            })
        let startupSafe = await controller.start()
        XCTAssertTrue(startupSafe)

        let goal = Goal(
            sessionID: sessionID,
            objective: "Do not launch through unknown effects")
        let prepared = ToolExecutionPreparedPayload(
            executionID: "live-goal-unknown-effect",
            toolCallID: "live-goal-unknown-call",
            agent: Orchestrator.mainAgentID,
            tool: "write_file",
            sideEffect: .write,
            replayPolicy: .doNotReplay)
        try await log.append([
            .goalCreated(GoalCreatedPayload(goal: goal)),
            .toolExecutionPrepared(prepared),
            .toolExecutionSettled(ToolExecutionSettledPayload(
                prepared: prepared,
                outcome: .failed,
                effectDisposition: .unknown,
                reason: "the side effect cannot be reconstructed")),
        ])

        try await Task.sleep(nanoseconds: 100_000_000)
        let sendCallCount = await sendCalls.value()
        let finalProjection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(sendCallCount, 0)
        XCTAssertTrue(finalProjection.continuationRuns.isEmpty)
        await controller.shutdown()
    }

    func testStartupRejectsCorruptedKnownEventInsteadOfTreatingItAsEmpty() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-goal-runtime-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events.jsonl")
        let sessionID = SessionID(rawValue: "goal-runtime-corrupt")
        let log = try EventLog(session: sessionID, fileURL: file)
        let malformedKnownEvent = #"{"seq":0,"ts":0,"session":"goal-runtime-corrupt","v":1,"type":"task_failed","payload":{}}"#
        try Data((malformedKnownEvent + "\n").utf8).write(to: file, options: .atomic)

        let sendCalls = RuntimeCallCounter()
        let verifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: "unused"),
        ])
        let controller = GoalRuntimeController(
            sessionID: sessionID,
            log: log,
            verifierProvider: { verifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in
                await sendCalls.increment()
                return .sent
            })

        let startupSafe = await controller.start()
        let callCount = await sendCalls.value()
        XCTAssertFalse(startupSafe)
        XCTAssertEqual(callCount, 0)
        await controller.shutdown()
    }

    func testStartupRejectsUnknownFutureEventsAndSequenceGaps() async throws {
        for scenario in ["unknown-future", "sequence-gap"] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "intatis-goal-runtime-\(scenario)-\(UUID().uuidString)",
                    isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("events.jsonl")
            let sessionID = SessionID(rawValue: "goal-runtime-\(scenario)")
            let log = try EventLog(session: sessionID, fileURL: file)
            _ = try await log.append(.userMessage(.init(text: "known prefix")))

            let nextSequence = scenario == "sequence-gap" ? 2 : 1
            let encoder = Envelope.makeEncoder()
            let placeholder = try encoder.encode(Envelope(
                seq: nextSequence,
                ts: Date(timeIntervalSince1970: Double(nextSequence)),
                session: sessionID,
                event: .userMessage(.init(text: "placeholder"))))
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: placeholder) as? [String: Any])
            if scenario == "unknown-future" {
                object["type"] = "future_goal_runtime_event"
                object["payload"] = ["futureField": true]
            }
            var raw = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            raw.append(0x0A)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: raw)
            try handle.close()

            let sendCalls = RuntimeCallCounter()
            let verifier = RuntimeVerifierProvider([
                continuingRuntimeAudit(objective: "unused"),
            ])
            let controller = GoalRuntimeController(
                sessionID: sessionID,
                log: log,
                verifierProvider: { verifier },
                verifierModel: { ModelID(rawValue: "verifier") },
                sendOperation: { _, _, _, _, _, _, _ in
                    await sendCalls.increment()
                    return .sent
                })

            let startupSafe = await controller.start()
            let sendCallCount = await sendCalls.value()
            XCTAssertFalse(startupSafe, scenario)
            XCTAssertEqual(sendCallCount, 0, scenario)
            await controller.shutdown()
        }
    }

    func testRecoveryInterruptsActiveRunButUnresolvedNonReplayableToolStopsRecovery() async throws {
        let activeLog = try runtimeLog("recover-active")
        let activeSession = await activeLog.sessionID
        let activeGoal = Goal(sessionID: activeSession, objective: "Recover active Goal")
        let createdRun = ContinuationRun(
            sessionID: activeSession,
            goalID: activeGoal.id,
            ordinal: 1)
        let runningRun = try createdRun.transitioning(to: .running).get()
        try await activeLog.append([
            .goalCreated(GoalCreatedPayload(goal: activeGoal)),
            .continuationRunCreated(ContinuationRunCreatedPayload(run: createdRun)),
            .continuationRunStarted(ContinuationRunStartedPayload(run: runningRun)),
        ])
        let activeVerifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: activeGoal.objective),
        ])
        let activeController = GoalRuntimeController(
            sessionID: activeSession,
            log: activeLog,
            verifierProvider: { activeVerifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, _, _, _, _, _, _ in
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return .sent
                } catch {
                    return .failed("stopped")
                }
            })
        let activeStartupSafe = await activeController.start()
        XCTAssertTrue(activeStartupSafe)
        let interruptedProjection = try await waitForRuntimeProjection(
            activeLog,
            label: "active recovery") {
                $0.continuationRuns[createdRun.id]?.status == .interrupted
                    && $0.goals[activeGoal.id]?.status == .paused
            }
        XCTAssertEqual(
            interruptedProjection.continuationRuns[createdRun.id]?.progressSummary,
            "Recovered after runtime interruption")
        XCTAssertEqual(interruptedProjection.continuationRuns.count, 1)
        XCTAssertEqual(activeVerifier.callCount(), 0)

        _ = try await activeController.resumeCurrentGoal()
        let resumedProjection = try await waitForRuntimeProjection(
            activeLog,
            label: "explicitly resumed active recovery") {
                $0.continuationRuns.values.contains {
                    $0.goalID == activeGoal.id && $0.id != createdRun.id
                        && $0.status == .running
                }
            }
        XCTAssertEqual(resumedProjection.goals[activeGoal.id]?.status, .active)
        await activeController.shutdown()

        let unsafeLog = try runtimeLog("recover-unsafe")
        let unsafeSession = await unsafeLog.sessionID
        let unsafeGoal = Goal(sessionID: unsafeSession, objective: "Unsafe recovery Goal")
        let unsafeCreatedRun = ContinuationRun(
            sessionID: unsafeSession,
            goalID: unsafeGoal.id,
            ordinal: 1)
        let unsafeRunningRun = try unsafeCreatedRun.transitioning(to: .running).get()
        let prepared = ToolExecutionPreparedPayload(
            executionID: "unresolved-write",
            toolCallID: "call-write",
            agent: Orchestrator.mainAgentID,
            tool: "write_file",
            sideEffect: .write,
            replayPolicy: .doNotReplay)
        try await unsafeLog.append([
            .goalCreated(GoalCreatedPayload(goal: unsafeGoal)),
            .continuationRunCreated(ContinuationRunCreatedPayload(run: unsafeCreatedRun)),
            .continuationRunStarted(ContinuationRunStartedPayload(run: unsafeRunningRun)),
            .toolExecutionPrepared(prepared),
        ])
        let unsafeRecorder = RuntimeSendRecorder()
        let unsafeVerifier = RuntimeVerifierProvider([
            continuingRuntimeAudit(objective: unsafeGoal.objective),
        ])
        let unsafeController = GoalRuntimeController(
            sessionID: unsafeSession,
            log: unsafeLog,
            verifierProvider: { unsafeVerifier },
            verifierModel: { ModelID(rawValue: "verifier") },
            sendOperation: { _, target, _, _, goalID, runID, recordUserMessage in
                await unsafeRecorder.record(
                    target: target,
                    goalID: goalID,
                    runID: runID,
                    recordUserMessage: recordUserMessage)
                return .sent
            })
        let unsafeStartupSafe = await unsafeController.start()
        XCTAssertFalse(unsafeStartupSafe)
        try await Task.sleep(nanoseconds: 100_000_000)
        let unsafeProjection = CoworkProjection.build(from: await unsafeLog.replay())
        XCTAssertEqual(unsafeProjection.continuationRuns[unsafeCreatedRun.id]?.status, .interrupted)
        XCTAssertEqual(unsafeProjection.continuationRuns.count, 1)
        XCTAssertTrue(unsafeProjection.unresolvedNonReplayableToolExecutions.count == 1)
        let unsafeCalls = await unsafeRecorder.calls()
        XCTAssertTrue(unsafeCalls.isEmpty)
        await unsafeController.shutdown()
    }
}
