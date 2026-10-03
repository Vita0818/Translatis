import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
@testable import IntatisCowork

private final class SchedulerProvider: ToolCallingProvider, @unchecked Sendable {
    private let chunks: [AgentChunk]
    private let lock = NSLock()
    private var capturedRequests: [AgentRequest] = []

    init(_ chunks: [AgentChunk] = [.textDelta("scheduled result"), .done(finishReason: "stop")]) {
        self.chunks = chunks
    }

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        capturedRequests.append(request)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private func schedulerLog() throws -> EventLog {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-scheduler-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    return try EventLog(session: SessionID(rawValue: "scheduler"), fileURL: url)
}

private func schedulerWorkspace() throws -> URL {
    let ws = FileManager.default.temporaryDirectory.appendingPathComponent("scheduler-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    return ws
}

private func schedulerTaskCompleted(_ events: [Envelope]) -> [TaskCompletedPayload] {
    events.compactMap {
        if case .taskCompleted(let payload) = $0.event { return payload }
        return nil
    }
}

private func schedulerUnitTask(_ id: String,
                               assignee: AgentID,
                               issuer: AgentID = AgentID(rawValue: "main"),
                               parentTaskID: TaskID? = nil,
                               input: String? = nil,
                               attempt: Int? = 1,
                               agentInferenceBinding: AgentInferenceBinding? = nil) -> ScheduledTask {
    let taskID = TaskID(rawValue: id)
    let contract = TaskContract(
        id: taskID,
        issuer: issuer,
        assignee: assignee,
        parentTaskID: parentTaskID,
        objective: "Objective for \(id)",
        roleHint: "scheduler test worker",
        expectedDeliverable: "scheduler test result",
        agentInferenceBinding: agentInferenceBinding)
    return ScheduledTask(
        contract: contract,
        input: input ?? contract.objective,
        rootTaskID: parentTaskID ?? taskID,
        parentTaskID: parentTaskID,
        issuer: issuer,
        assignee: assignee,
        causalParentID: parentTaskID,
        hopCount: 1,
        visitedAgents: [issuer, assignee],
        attempt: attempt)
}

private func schedulerInferenceBinding(_ profile: String,
                                       revision: String = "rev-1") -> AgentInferenceBinding {
    AgentInferenceBinding(
        inferenceProfileRef: InferenceProfileRef(
            inferenceProfileID: InferenceProfileID(rawValue: profile),
            inferenceProfileRevision: InferenceProfileRevision(rawValue: revision)),
        inferenceConnectionID: InferenceConnectionID(rawValue: "connection-\(profile)"),
        inferenceConnectionRevision: InferenceConnectionRevision(rawValue: "connection-rev-1"),
        modelID: ModelID(rawValue: "model-\(profile)"),
        variantID: "high",
        safeRouteLabel: "route-\(profile)",
        immutableDefinitionFingerprint: "fingerprint-\(profile)-\(revision)")
}

final class SchedulerMailboxTests: XCTestCase {
    private let main = AgentID(rawValue: "main")
    private let worker = AgentID(rawValue: "worker")

    private func makeOrchestrator(log: EventLog,
                                  workerProvider: SchedulerProvider = SchedulerProvider(),
                                  workerCoordinationDepth: Int = 0) async throws -> (Orchestrator, URL, URL) {
        let wsMain = try schedulerWorkspace()
        let wsWorker = try schedulerWorkspace()
        let worker = self.worker
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            agent.name == worker ? workerProvider : SchedulerProvider([.textDelta("main"), .done(finishReason: "stop")])
        }
        let mainAttached = await orch.attach(Agent(name: main, workspaceRoot: wsMain, model: ModelID(rawValue: "m"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orch.attach(Agent(name: worker, workspaceRoot: wsWorker, model: ModelID(rawValue: "m"),
                                                     profile: .reviewed,
                                                     coordinationDepth: workerCoordinationDepth))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)
        return (orch, wsMain, wsWorker)
    }

    func testDelegateTaskEnqueuesScheduledTaskAndMailboxReceivesIt() async throws {
        let log = try schedulerLog()
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }

        let queued = await orch.enqueueDelegatedTask(from: main, to: worker.rawValue, objective: "Inspect worker workspace.")

        let taskID = try XCTUnwrap(queued.taskID)
        let queuedIDs = await orch.queuedTasks().map(\.contract.id)
        let pendingTasks = await orch.mailbox(for: worker).pendingTasks
        let events = await log.replay()
        XCTAssertEqual(queuedIDs, [taskID])
        XCTAssertEqual(pendingTasks, [taskID])
        XCTAssertTrue(events.contains { if case .taskQueued = $0.event { return true } else { return false } })
    }

    func testListAgentsIncludesLeaseRolesAndCompactTaskStateWithoutTaskContent() async throws {
        let log = try schedulerLog()
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }

        let queued = await orch.enqueueDelegatedTask(
            from: main,
            to: worker.rawValue,
            objective: "Inspect /private/secret.swift.",
            roleHint: "sensitive worker",
            expectedDeliverable: "Return secret implementation details.")
        let taskID = try XCTUnwrap(queued.taskID)

        let listing = await orch.listForTool()
        XCTAssertTrue(listing.contains("@main · m · coordinator"))
        XCTAssertTrue(listing.contains("@worker · m · worker"))
        XCTAssertTrue(listing.contains("issued active \(taskID.rawValue):queued"))
        XCTAssertTrue(listing.contains("tasks \(taskID.rawValue):queued"))
        XCTAssertFalse(listing.contains("Inspect /private/secret.swift"))
        XCTAssertFalse(listing.contains("sensitive worker"))
        XCTAssertFalse(listing.contains("Return secret implementation details"))
    }

    func testSchedulerRunsTargetAgentIndependentlyAndRecordsResult() async throws {
        let log = try schedulerLog()
        let workerProvider = SchedulerProvider([.textDelta("worker done"), .done(finishReason: "stop")])
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log, workerProvider: workerProvider)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }
        let queued = await orch.enqueueDelegatedTask(from: main, to: worker.rawValue, objective: "Run worker task.")
        let taskID = try XCTUnwrap(queued.taskID)

        let ran = await orch.runNextScheduledTask()
        XCTAssertTrue(ran)

        XCTAssertEqual(workerProvider.requests.count, 1)
        let recordOptional = await orch.executionRecord(taskID: taskID)
        let record = try XCTUnwrap(recordOptional)
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.result, "worker done")
        let completedMailboxTaskID = await orch.mailbox(for: worker).completedResults.first?.taskID
        XCTAssertEqual(completedMailboxTaskID, taskID)
        let events = await log.replay()
        XCTAssertTrue(events.contains { if case .taskStarted(let payload) = $0.event { return payload.taskID == taskID } else { return false } })
        XCTAssertTrue(events.contains { if case .taskCompleted(let payload) = $0.event { return payload.result == "worker done" } else { return false } })
    }

    func testCallerEqualsTargetIsRejectedBeforeScheduling() async throws {
        let log = try schedulerLog()
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }

        let queued = await orch.enqueueDelegatedTask(from: worker, to: worker.rawValue, objective: "self task")

        XCTAssertNil(queued.taskID)
        XCTAssertEqual(queued.message, "error: agent cannot delegate to itself")
        let queuedTasks = await orch.queuedTasks()
        XCTAssertTrue(queuedTasks.isEmpty)
    }

    func testImmediateABACycleIsRejected() async throws {
        let log = try schedulerLog()
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(
            log: log,
            workerCoordinationDepth: Agent.defaultCoordinationDepth)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }
        let first = await orch.enqueueDelegatedTask(from: main, to: worker.rawValue, objective: "A to B")
        let parentTaskID = try XCTUnwrap(first.taskID)

        let cycle = await orch.enqueueDelegatedTask(from: worker, to: main.rawValue, objective: "B back to A", parentTaskID: parentTaskID)

        XCTAssertNil(cycle.taskID)
        XCTAssertEqual(cycle.message, "error: delegation cycle rejected")
        let queued = await orch.queuedTasks()
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.contract.id, parentTaskID)
    }

    func testDelegateTaskReturnsTaskReportAfterAwaitingSchedulerResult() async throws {
        let log = try schedulerLog()
        let workerProvider = SchedulerProvider([.textDelta("awaited result"), .done(finishReason: "stop")])
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log, workerProvider: workerProvider)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }

        let result = await orch.delegateTask(from: main, to: worker.rawValue, objective: "Await this worker task.")

        XCTAssertTrue(result.contains("Task Report"))
        XCTAssertTrue(result.contains("status: completed"))
        XCTAssertTrue(result.contains("agent: @worker"))
        XCTAssertTrue(result.contains("summary: awaited result"))
        XCTAssertEqual(workerProvider.requests.count, 1)
        let remainingTasks = await orch.queuedTasks()
        let events = await log.replay()
        XCTAssertTrue(remainingTasks.isEmpty)
        XCTAssertEqual(schedulerTaskCompleted(events).first?.result, "awaited result")
    }

    func testMacOSIOSCounterScenarioRunsTwoWorkersThroughSchedulerEvents() async throws {
        let log = try schedulerLog()
        let macos = AgentID(rawValue: "macos-counter")
        let ios = AgentID(rawValue: "ios-counter")
        let wsMain = try schedulerWorkspace()
        let wsMacos = try schedulerWorkspace()
        let wsIOS = try schedulerWorkspace()
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsMacos)
            try? FileManager.default.removeItem(at: wsIOS)
        }
        let macosProvider = SchedulerProvider([.textDelta("macOS count: 4"), .done(finishReason: "stop")])
        let iosProvider = SchedulerProvider([.textDelta("iOS count: 7"), .done(finishReason: "stop")])
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            if agent.name == macos { return macosProvider }
            if agent.name == ios { return iosProvider }
            return SchedulerProvider([.textDelta("main"), .done(finishReason: "stop")])
        }
        let mainAttached = await orch.attach(Agent(name: main, workspaceRoot: wsMain, model: ModelID(rawValue: "m"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        let macosAttached = await orch.attach(Agent(name: macos, workspaceRoot: wsMacos, model: ModelID(rawValue: "m"),
                                                    profile: .reviewed))
        let iosAttached = await orch.attach(Agent(name: ios, workspaceRoot: wsIOS, model: ModelID(rawValue: "m"),
                                                  profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(macosAttached)
        XCTAssertTrue(iosAttached)

        let macosQueued = await orch.enqueueDelegatedTask(from: main, to: macos.rawValue,
                                                          objective: "Recursively count macOS Swift files only.")
        let iosQueued = await orch.enqueueDelegatedTask(from: main, to: ios.rawValue,
                                                        objective: "Recursively count iOS Swift files only.")
        XCTAssertNotNil(macosQueued.taskID)
        XCTAssertNotNil(iosQueued.taskID)

        await orch.runSchedulerUntilIdle()

        let completions = schedulerTaskCompleted(await log.replay())
        XCTAssertTrue(completions.contains { $0.agent == macos && $0.result == "macOS count: 4" })
        XCTAssertTrue(completions.contains { $0.agent == ios && $0.result == "iOS count: 7" })
        XCTAssertEqual(macosProvider.requests.count, 1)
        XCTAssertEqual(iosProvider.requests.count, 1)
    }

    func testSchedulerRejectsDuplicateTaskIDAndAllowsOnlyExactTerminalRetry() {
        let worker = AgentID(rawValue: "worker")
        let task = schedulerUnitTask("task_dedup", assignee: worker)
        var scheduler = AgentScheduler()

        XCTAssertEqual(scheduler.enqueue(task, mode: .newTask), .enqueued(task.contract.id))
        XCTAssertEqual(
            scheduler.enqueue(task, mode: .newTask),
            .rejected(task.contract.id, .duplicateQueued))
        XCTAssertEqual(scheduler.queuedTasks().map(\.contract.id), [task.contract.id])

        let claimed = scheduler.claimNext()
        XCTAssertEqual(claimed, task)
        XCTAssertTrue(scheduler.recordStarted(task: task))
        scheduler.recordFailed(task: task, error: "retry me")

        var changedTask = task
        changedTask.input = "changed input under the same task id"
        XCTAssertEqual(
            scheduler.enqueue(changedTask, mode: .retry),
            .rejected(task.contract.id, .retryTaskMismatch))
        XCTAssertEqual(
            scheduler.enqueue(task, mode: .retry),
            .rejected(task.contract.id, .retryAttemptMismatch))
        var retry = task
        retry.attempt = 2
        XCTAssertEqual(scheduler.enqueue(retry, mode: .retry), .retryReplaced(task.contract.id))
        XCTAssertEqual(scheduler.queuedTasks(), [retry])
    }

    func testSchedulerRetryAttemptMustBeMonotonicAndWithinContractLimit() {
        let worker = AgentID(rawValue: "worker")
        var task = schedulerUnitTask("task_retry_limit", assignee: worker)
        task.contract.maxAttempts = 2
        var scheduler = AgentScheduler()
        XCTAssertTrue(scheduler.enqueue(task, mode: .newTask).accepted)
        XCTAssertEqual(scheduler.claimNext(), task)
        XCTAssertTrue(scheduler.recordStarted(task: task))
        scheduler.recordFailed(task: task, error: "retry me")

        var skippedAttempt = task
        skippedAttempt.attempt = 3
        XCTAssertEqual(
            scheduler.enqueue(skippedAttempt, mode: .retry),
            .rejected(task.contract.id, .retryAttemptMismatch))
        var nextAttempt = task
        nextAttempt.attempt = 2
        XCTAssertEqual(scheduler.enqueue(nextAttempt, mode: .retry), .retryReplaced(task.contract.id))
        XCTAssertEqual(scheduler.claimNext(), nextAttempt)
        XCTAssertTrue(scheduler.recordStarted(task: nextAttempt))
        scheduler.recordFailed(task: nextAttempt, error: "still failing")
        var overLimit = nextAttempt
        overLimit.attempt = 3
        XCTAssertEqual(
            scheduler.enqueue(overLimit, mode: .retry),
            .rejected(task.contract.id, .retryAttemptLimitExceeded))
    }

    func testSchedulerRetryRejectsChangedInferenceBinding() {
        let worker = AgentID(rawValue: "worker")
        let originalBinding = schedulerInferenceBinding("profile-original")
        let task = schedulerUnitTask(
            "task_binding_retry",
            assignee: worker,
            agentInferenceBinding: originalBinding)
        var scheduler = AgentScheduler()
        XCTAssertEqual(scheduler.enqueue(task, mode: .newTask), .enqueued(task.contract.id))
        XCTAssertEqual(scheduler.claimNext(), task)
        XCTAssertTrue(scheduler.recordStarted(task: task))
        scheduler.recordFailed(task: task, error: "retry me")

        var changedBindingRetry = task
        changedBindingRetry.attempt = 2
        changedBindingRetry.contract.agentInferenceBinding = schedulerInferenceBinding("profile-changed")
        XCTAssertEqual(
            scheduler.enqueue(changedBindingRetry, mode: .retry),
            .rejected(task.contract.id, .retryTaskMismatch))

        var exactBindingRetry = task
        exactBindingRetry.attempt = 2
        XCTAssertEqual(
            scheduler.enqueue(exactBindingRetry, mode: .retry),
            .retryReplaced(task.contract.id))
        XCTAssertEqual(
            scheduler.queuedTask(taskID: task.contract.id)?.contract.agentInferenceBinding,
            originalBinding)
    }

    func testSchedulerClaimsAtMostOneTaskPerAgentButDifferentAgentsCanRunTogether() {
        let workerA = AgentID(rawValue: "worker-a")
        let workerB = AgentID(rawValue: "worker-b")
        let a1 = schedulerUnitTask("task_a1", assignee: workerA)
        let a2 = schedulerUnitTask("task_a2", assignee: workerA)
        let b1 = schedulerUnitTask("task_b1", assignee: workerB)
        var scheduler = AgentScheduler()
        scheduler.enqueue(a1)
        scheduler.enqueue(a2)
        scheduler.enqueue(b1)

        XCTAssertEqual(scheduler.claimNext(), a1)
        XCTAssertEqual(scheduler.claimNext(), b1, "busy worker-a must not block an idle worker-b")
        XCTAssertNil(scheduler.claimNext(), "worker-a's second task stays queued while worker-a is busy")
        XCTAssertTrue(scheduler.isAgentBusy(workerA))
        XCTAssertTrue(scheduler.isAgentBusy(workerB))
        XCTAssertEqual(scheduler.queuedTasks(), [a2])

        XCTAssertTrue(scheduler.recordStarted(task: a1))
        scheduler.recordCompleted(task: a1, result: "a1 done")
        XCTAssertFalse(scheduler.isAgentBusy(workerA))
        XCTAssertEqual(scheduler.claimNext(), a2)
        XCTAssertTrue(scheduler.isAgentBusy(workerA))
    }

    func testCancelAndRemoveOperateOnlyOnQueuedTasks() {
        let worker = AgentID(rawValue: "worker")
        let cancelled = schedulerUnitTask("task_cancelled", assignee: worker)
        let removed = schedulerUnitTask("task_removed", assignee: worker)
        var scheduler = AgentScheduler()
        scheduler.enqueue(cancelled)
        scheduler.enqueue(removed)

        XCTAssertEqual(scheduler.cancelQueuedTask(taskID: cancelled.contract.id), cancelled)
        XCTAssertEqual(scheduler.record(for: cancelled.contract.id)?.status, .cancelled)
        XCTAssertFalse(scheduler.mailbox(for: worker).pendingTasks.contains(cancelled.contract.id))
        XCTAssertEqual(scheduler.removeQueuedTask(taskID: removed.contract.id), removed)
        XCTAssertNil(scheduler.record(for: removed.contract.id))
        XCTAssertTrue(scheduler.queuedTasks().isEmpty)

        var retried = cancelled
        retried.attempt = 2
        XCTAssertEqual(scheduler.enqueue(retried, mode: .retry), .retryReplaced(cancelled.contract.id))
        let claimed = scheduler.claimNext()
        XCTAssertEqual(claimed, retried)
        XCTAssertNil(scheduler.cancelQueuedTask(taskID: cancelled.contract.id),
                     "claimed work needs cooperative executor cancellation")
        scheduler.recordCancelled(task: retried)
        XCTAssertFalse(scheduler.recordStarted(task: retried),
                       "a claimed task cancelled before start must not be resurrected")
        XCTAssertFalse(scheduler.isAgentBusy(worker))
    }

    func testSchedulerSnapshotRestoreRequeuesClaimedWorkAndPreservesMailbox() throws {
        let workerA = AgentID(rawValue: "worker-a")
        let workerB = AgentID(rawValue: "worker-b")
        let runningBinding = schedulerInferenceBinding("profile-running")
        let queuedBinding = schedulerInferenceBinding("profile-queued", revision: "rev-7")
        let running = schedulerUnitTask(
            "task_running",
            assignee: workerA,
            agentInferenceBinding: runningBinding)
        let queued = schedulerUnitTask(
            "task_queued",
            assignee: workerB,
            agentInferenceBinding: queuedBinding)
        let message = PendingAgentMessage(
            id: MessageID(rawValue: "msg_snapshot"),
            sender: workerB,
            recipient: workerA,
            content: "snapshot payload",
            kind: "request_information",
            taskID: running.contract.id,
            causalParentID: running.parentTaskID)
        var scheduler = AgentScheduler()
        scheduler.enqueue(running)
        scheduler.enqueue(queued)
        XCTAssertEqual(scheduler.claimNext(), running)
        XCTAssertTrue(scheduler.recordStarted(task: running))
        XCTAssertTrue(scheduler.enqueueMessage(message))

        let encoded = try JSONEncoder().encode(scheduler.snapshot())
        let decoded = try JSONDecoder().decode(AgentSchedulerSnapshot.self, from: encoded)
        var restored = AgentScheduler(snapshot: decoded)

        XCTAssertFalse(restored.isAgentBusy(workerA))
        XCTAssertEqual(restored.queuedTasks(), [running, queued])
        XCTAssertEqual(
            restored.queuedTask(taskID: running.contract.id)?.contract.agentInferenceBinding,
            runningBinding)
        XCTAssertEqual(
            restored.knownTask(taskID: queued.contract.id)?.contract.agentInferenceBinding,
            queuedBinding)
        XCTAssertEqual(restored.record(for: running.contract.id)?.status, .queued)
        XCTAssertEqual(restored.mailbox(for: workerA).pendingTasks, [running.contract.id])
        XCTAssertEqual(restored.peekMessage(for: workerA), message)
        XCTAssertEqual(restored.claimNext(), running)
    }

    func testMailboxPeekConsumeAcknowledgeAndDrainPreserveCausalMetadata() {
        let sender = AgentID(rawValue: "main")
        let recipient = AgentID(rawValue: "worker")
        let taskID = TaskID(rawValue: "task_mailbox")
        let first = PendingAgentMessage(
            id: MessageID(rawValue: "msg_1"),
            sender: sender,
            recipient: recipient,
            content: "first",
            kind: "send_message",
            taskID: taskID,
            causalParentID: TaskID(rawValue: "task_parent"))
        let second = PendingAgentMessage(
            id: MessageID(rawValue: "msg_2"),
            sender: sender,
            recipient: recipient,
            content: "second",
            kind: "reply_message",
            taskID: taskID,
            inReplyTo: first.id)
        var scheduler = AgentScheduler()

        XCTAssertTrue(scheduler.enqueueMessage(first))
        XCTAssertFalse(scheduler.enqueueMessage(first), "message identity is globally deduplicated")
        XCTAssertTrue(scheduler.enqueueMessage(second))
        XCTAssertEqual(scheduler.peekMessages(for: recipient), [first, second])
        XCTAssertEqual(scheduler.consumeNextMessage(for: recipient), first)
        XCTAssertEqual(scheduler.mailbox(for: recipient).pendingMessages, [second.id])
        XCTAssertTrue(scheduler.acknowledgeMessage(second.id, recipient: recipient))
        XCTAssertFalse(scheduler.acknowledgeMessage(second.id, recipient: recipient))
        XCTAssertTrue(scheduler.drainMessages(for: recipient).isEmpty)

        XCTAssertTrue(scheduler.enqueueMessage(first))
        XCTAssertTrue(scheduler.enqueueMessage(second))
        XCTAssertEqual(scheduler.drainMessages(for: recipient), [first, second])
        XCTAssertTrue(scheduler.mailbox(for: recipient).pendingMessages.isEmpty)
    }
}
