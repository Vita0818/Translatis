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

private final class WorkTaskProvider: ToolCallingProvider, @unchecked Sendable {
    let result: String

    init(result: String = "candidate output") {
        self.result = result
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(result))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }
}

private actor WorkTaskPersistenceGate {
    private var didPause = false
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pauseOnce() async {
        guard !didPause else { return }
        didPause = true
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private func workTaskLog() throws -> EventLog {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-work-task-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    return try EventLog(session: SessionID(rawValue: "work-task"), fileURL: file)
}

private func workTaskWorkspace() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-work-task-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct UntrustedStaleWorkTaskManager: WorkTaskManager {
    func createWorkTask(_ request: WorkTaskCreateRequest) async throws -> WorkTaskDetail {
        throw WorkTaskGraphViolation(kind: .missingTask, message: "unused test operation")
    }

    func updateWorkTask(_ request: WorkTaskUpdateRequest) async throws -> WorkTaskDetail {
        throw WorkTaskGraphViolation(
            kind: .staleRevision,
            message: "expected revision \(request.expectedRevision), actual 4",
            taskID: request.taskID,
            expectedRevision: request.expectedRevision,
            actualRevision: 4)
    }

    func getWorkTask(_ taskID: WorkTaskID) async throws -> WorkTaskDetail {
        throw WorkTaskGraphViolation(kind: .missingTask, message: "unused test operation")
    }

    func listWorkTasks(_ request: WorkTaskListRequest) async throws -> [WorkTaskDetail] {
        throw WorkTaskGraphViolation(kind: .missingTask, message: "unused test operation")
    }
}

private struct NamespaceWorkTaskManager: WorkTaskManager {
    let detail: WorkTaskDetail

    func createWorkTask(_ request: WorkTaskCreateRequest) async throws -> WorkTaskDetail {
        detail
    }

    func updateWorkTask(_ request: WorkTaskUpdateRequest) async throws -> WorkTaskDetail {
        guard request.taskID == detail.task.id else {
            throw IntatisError.notFound("WorkTask \(request.taskID.rawValue)")
        }
        return detail
    }

    func getWorkTask(_ taskID: WorkTaskID) async throws -> WorkTaskDetail {
        guard taskID == detail.task.id else {
            throw IntatisError.notFound("WorkTask \(taskID.rawValue)")
        }
        return detail
    }

    func listWorkTasks(_ request: WorkTaskListRequest) async throws -> [WorkTaskDetail] {
        [detail]
    }
}

private enum WorkTaskRuntimeTestError: Error, Equatable {
    case lostAcknowledgementAfterAppend
}

final class WorkTaskRuntimeTests: XCTestCase {
    private let main = AgentID(rawValue: "main")
    private let worker = AgentID(rawValue: "worker")

    private func waitForAdmissionWaiter(
        on orchestrator: Orchestrator,
        attempts: Int = 10_000
    ) async -> Bool {
        for _ in 0..<attempts {
            if await orchestrator.admissionWaiterCountForTesting() > 0 {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func makeOrchestrator(
        workspace: URL,
        workerCoordinationDepth: Int = 0
    ) async throws -> (Orchestrator, EventLog) {
        let log = try workTaskLog()
        let provider = WorkTaskProvider()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        let mainAttached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "test"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(mainAttached)
        let workerAttached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "test"),
            profile: .reviewed,
            coordinationDepth: workerCoordinationDepth))
        XCTAssertTrue(workerAttached)
        return (orchestrator, log)
    }

    func testTaskCreateDescriptorIsSessionScopedAndHasNoOwnerField() throws {
        let descriptor = TaskCreateTool.descriptor
        XCTAssertTrue(descriptor.description.contains("current Cowork Session"))

        guard case .object(let schema) = descriptor.parameters,
              case .object(let properties)? = schema["properties"],
              case .object(let dependencies)? = properties["depends_on"],
              case .string(let dependencyDescription)? = dependencies["description"],
              case .array(let rawRequired)? = schema["required"] else {
            return XCTFail("task_create must expose a documented closed object schema")
        }

        let required = Set(rawRequired.compactMap { value -> String? in
            guard case .string(let name) = value else { return nil }
            return name
        })
        XCTAssertNil(properties["owner"])
        XCTAssertFalse(required.contains("owner"))
        XCTAssertTrue(dependencyDescription.contains("earlier successful task_create"))
        XCTAssertTrue(dependencyDescription.contains("same assistant response"))
    }

    func testMutatingWorkTaskToolsRejectMissingHostManagerAsNotStarted() async throws {
        let workspace = try workTaskWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let context = ToolContext(workspaceRoot: workspace)

        do {
            _ = try await TaskCreateTool().execute(
                ToolArgs(raw: #"{"title":"No manager","description":"Must fail closed"}"#),
                in: context)
            XCTFail("task_create must not report success without its host manager")
        } catch let rejection as ToolExecutionRejectedWithoutSideEffect {
            XCTAssertEqual(rejection.code, "work_task_manager_unavailable")
            XCTAssertTrue(rejection.message.contains("task_create rejected before WorkTask execution started"))
        }

        do {
            _ = try await TaskUpdateTool().execute(
                ToolArgs(raw: #"{"task_id":"wt_missing","expected_revision":1,"progress_note":"No manager"}"#),
                in: context)
            XCTFail("task_update must not report success without its host manager")
        } catch let rejection as ToolExecutionRejectedWithoutSideEffect {
            XCTAssertEqual(rejection.code, "work_task_manager_unavailable")
            XCTAssertTrue(rejection.message.contains("task_update rejected before WorkTask execution started"))
        }

        do {
            _ = try await BoundWorkTaskUpdateTool().execute(
                ToolArgs(raw: #"{"task_id":"wt_missing","expected_revision":1,"progress_note":"No manager"}"#),
                in: context)
            XCTFail("worker task_update must not report success without its host manager")
        } catch let rejection as ToolExecutionRejectedWithoutSideEffect {
            XCTAssertEqual(rejection.code, "work_task_manager_unavailable")
            XCTAssertTrue(rejection.message.contains("task_update rejected before WorkTask execution started"))
        }
    }

    func testWorkTaskPermissionPreviewsExposeBoundedSemanticFields() throws {
        let secret = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let createArgs = ToolArgs(raw: """
        {
          "title": "Create \(secret)",
          "description": "\(String(repeating: "x", count: 1_000))",
          "acceptance_criteria": ["tests pass"],
          "expected_artifacts": ["report"],
          "depends_on": ["wt_dependency"],
          "priority": "high"
        }
        """)
        let createPreview = try XCTUnwrap(
            TaskCreateTool().permissionActionPreview(createArgs))

        XCTAssertEqual(createPreview.kind, "task_create")
        XCTAssertNil(createPreview.fields["owner"])
        XCTAssertEqual(createPreview.fields["depends_on"], "wt_dependency")
        XCTAssertTrue(createPreview.redacted)
        XCTAssertTrue(createPreview.truncated)
        XCTAssertFalse(createPreview.fields.values.joined().contains(secret))

        let updateArgs = ToolArgs(raw: """
        {
          "task_id": "wt_exact",
          "expected_revision": 7,
          "status": "completed",
          "progress_note": "verified",
          "result": "done",
          "evidence": [{
            "kind": "test",
            "reference": "suite",
            "summary": "passed"
          }],
          "retry": false
        }
        """)
        let updatePreview = try XCTUnwrap(
            TaskUpdateTool().permissionActionPreview(updateArgs))

        XCTAssertEqual(updatePreview.kind, "task_update")
        XCTAssertEqual(updatePreview.fields["task_id"], "wt_exact")
        XCTAssertEqual(updatePreview.fields["expected_revision"], "7")
        XCTAssertEqual(updatePreview.fields["status"], "completed")
        XCTAssertEqual(updatePreview.fields["evidence_count"], "1")
        XCTAssertTrue(updatePreview.fields["changed_fields"]?.contains("progress_note") == true)
        XCTAssertTrue(updatePreview.fields["changed_fields"]?.contains("evidence") == true)
    }

    func testWorkTaskToolsExplainAgentInvocationNamespaceOnNotFound() async throws {
        let workspace = try workTaskWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let currentID = WorkTaskID(rawValue: "wt_current")
        let detail = WorkTaskDetail(task: WorkTask(
            id: currentID,
            title: "Current task",
            description: "Uses the current WorkTask namespace",
            status: .inProgress,
            revision: 4))
        let context = ToolContext(
            workspaceRoot: workspace,
            workTaskManager: NamespaceWorkTaskManager(detail: detail))

        let currentGet = try await TaskGetTool().execute(
            ToolArgs(raw: #"{"task_id":"wt_current"}"#),
            in: context)
        XCTAssertTrue(currentGet.text.contains("wt_current"))
        _ = try await TaskUpdateTool().execute(
            ToolArgs(raw: #"{"task_id":"wt_current","expected_revision":4,"progress_note":"still supported"}"#),
            in: context)

        do {
            _ = try await TaskGetTool().execute(
                ToolArgs(raw: #"{"task_id":"task_invocation_only"}"#),
                in: context)
            XCTFail("A missing AgentInvocation ID must receive the namespace hint.")
        } catch let rejection as ToolExecutionRejectedWithoutSideEffect {
            XCTAssertEqual(rejection.code, "work_task_id_required")
            XCTAssertTrue(rejection.message.contains("AgentInvocation TaskID"))
            XCTAssertTrue(rejection.message.contains("wt_"))
        }

        do {
            _ = try await TaskUpdateTool().execute(
                ToolArgs(raw: #"{"task_id":"task_invocation_only","expected_revision":1,"status":"completed","result":"wrong namespace"}"#),
                in: context)
            XCTFail("A missing AgentInvocation ID update must be proven no-effect.")
        } catch let rejection as ToolExecutionRejectedWithoutSideEffect {
            XCTAssertEqual(rejection.code, "work_task_id_required")
        }
    }

    func testTaskUpdateToolDoesNotInventNoEffectForArbitraryManager() async throws {
        let workspace = try workTaskWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let context = ToolContext(
            workspaceRoot: workspace,
            workTaskManager: UntrustedStaleWorkTaskManager())

        do {
            _ = try await TaskUpdateTool().execute(
                ToolArgs(raw: #"{"task_id":"task-stale-tool","expected_revision":3}"#),
                in: context)
            XCTFail("The manager's stale violation must propagate without an invented proof.")
        } catch let violation as WorkTaskGraphViolation {
            XCTAssertEqual(violation.kind, .staleRevision)
            XCTAssertEqual(violation.taskID, WorkTaskID(rawValue: "task-stale-tool"))
            XCTAssertEqual(violation.expectedRevision, 3)
            XCTAssertEqual(violation.actualRevision, 4)
        }
    }

    func testOrchestratorManagerProvesStaleRevisionBeforeMutation() async throws {
        let workspace = try workTaskWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (orchestrator, _) = try await makeOrchestrator(workspace: workspace)
        let created = try await orchestrator.createWorkTask(
            canManage: true,
            request: WorkTaskCreateRequest(
                title: "Authoritative stale boundary",
                description: "Prove the preflight graph is unchanged"))
        XCTAssertGreaterThan(created.task.revision, 0)

        let manager = OrchestratorWorkTaskManager(
            orchestrator: orchestrator,
            currentWorkTaskID: nil,
            canManage: true,
            canUpdateBound: false)
        let context = ToolContext(
            workspaceRoot: workspace,
            workTaskManager: manager)
        let rawArgs = #"{"task_id":"\#(created.task.id.rawValue)","expected_revision":0,"progress_note":"stale overwrite"}"#

        do {
            _ = try await TaskUpdateTool().execute(ToolArgs(raw: rawArgs), in: context)
            XCTFail("The authoritative stale update must provide a no-effect proof.")
        } catch let rejection as ToolExecutionRejectedWithoutSideEffect {
            XCTAssertEqual(rejection.code, "stale_revision")
            XCTAssertTrue(rejection.message.contains("without applying changes"))
            XCTAssertTrue(rejection.message.contains("current revision is \(created.task.revision)"))
            XCTAssertTrue(rejection.message.contains("Call task_get for task_id \"\(created.task.id.rawValue)\""))
        }

        let unchanged = try await orchestrator.getWorkTask(
            currentWorkTaskID: nil,
            canManage: true,
            taskID: created.task.id)
        XCTAssertEqual(unchanged.task, created.task)
    }

    func testWorkerCanCompleteBoundTaskWhenSnapshotRepeatsFrozenContractFields() async throws {
        let workspace = try workTaskWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (orchestrator, _) = try await makeOrchestrator(workspace: workspace)
        let created = try await orchestrator.createWorkTask(
            canManage: true,
            request: WorkTaskCreateRequest(
                title: "Count workspace files",
                description: "Return a verified count by extension",
                acceptanceCriteria: ["count every regular file"],
                expectedArtifacts: ["file-count summary"],
                priority: .normal))
        let started = try await orchestrator.updateWorkTask(
            currentWorkTaskID: nil,
            canManage: true,
            canUpdateBound: false,
            request: WorkTaskUpdateRequest(
                taskID: created.task.id,
                expectedRevision: created.task.revision,
                status: .inProgress))
        let manager = OrchestratorWorkTaskManager(
            orchestrator: orchestrator,
            currentWorkTaskID: started.task.id,
            canManage: false,
            canUpdateBound: true)
        let context = ToolContext(
            workspaceRoot: workspace,
            workTaskManager: manager)
        let rawArgs = """
        {
          "task_id": "\(started.task.id.rawValue)",
          "expected_revision": \(started.task.revision),
          "title": "Count workspace files",
          "description": "Return a verified count by extension",
          "acceptance_criteria": ["count every regular file"],
          "expected_artifacts": ["file-count summary"],
          "depends_on": [],
          "priority": "normal",
          "progress_note": "count reconciled",
          "status": "completed",
          "result": "251 regular files",
          "evidence": [{
            "kind": "workspace_scan",
            "reference": "workspace-root",
            "summary": "category totals reconcile to 251"
          }],
          "retry": false
        }
        """

        _ = try await TaskUpdateTool().execute(
            ToolArgs(raw: rawArgs),
            in: context)

        let completed = try await orchestrator.getWorkTask(
            currentWorkTaskID: nil,
            canManage: true,
            taskID: started.task.id)
        XCTAssertEqual(completed.task.status, .completed)
        XCTAssertEqual(completed.task.result, "251 regular files")
        XCTAssertEqual(completed.task.title, started.task.title)
        XCTAssertEqual(completed.task.description, started.task.description)
        XCTAssertEqual(completed.task.acceptanceCriteria, started.task.acceptanceCriteria)
        XCTAssertEqual(completed.task.expectedArtifacts, started.task.expectedArtifacts)
        XCTAssertEqual(completed.task.dependsOn, [])
        XCTAssertEqual(completed.task.priority, .normal)
        XCTAssertEqual(completed.task.revision, started.task.revision + 1)
    }

    func testManagerFrozenContractRejectionIsProvenNotStarted() async throws {
        let workspace = try workTaskWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (orchestrator, log) = try await makeOrchestrator(workspace: workspace)
        let created = try await orchestrator.createWorkTask(
            canManage: true,
            request: WorkTaskCreateRequest(
                title: "Frozen contract",
                description: "Keep the execution contract stable"))
        let started = try await orchestrator.updateWorkTask(
            currentWorkTaskID: nil,
            canManage: true,
            canUpdateBound: false,
            request: WorkTaskUpdateRequest(
                taskID: created.task.id,
                expectedRevision: created.task.revision,
                status: .inProgress))
        let manager = OrchestratorWorkTaskManager(
            orchestrator: orchestrator,
            currentWorkTaskID: nil,
            canManage: true,
            canUpdateBound: true)
        let beforeEvents = await log.replay()

        do {
            _ = try await manager.updateWorkTask(WorkTaskUpdateRequest(
                taskID: started.task.id,
                expectedRevision: started.task.revision,
                title: "Changed frozen title",
                status: .completed,
                result: "must not commit"))
            XCTFail("changing a frozen contract field must be rejected")
        } catch let rejection as ToolExecutionRejectedWithoutSideEffect {
            XCTAssertEqual(rejection.code, "permission_denied")
            XCTAssertTrue(rejection.message.contains("without applying changes"))
            XCTAssertTrue(rejection.message.contains("execution contract is frozen"))
        }

        let afterEvents = await log.replay()
        XCTAssertEqual(afterEvents, beforeEvents)
        let unchanged = try await orchestrator.getWorkTask(
            currentWorkTaskID: nil,
            canManage: true,
            taskID: started.task.id)
        XCTAssertEqual(unchanged.task, started.task)
    }

    func testPostAppendFailureIsNotMisclassifiedAsNoEffect() async throws {
        let workspace = try workTaskWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (orchestrator, log) = try await makeOrchestrator(workspace: workspace)
        let created = try await orchestrator.createWorkTask(
            canManage: true,
            request: WorkTaskCreateRequest(
                title: "Lost acknowledgement",
                description: "Persist before returning an error"))
        await orchestrator.setAdmissionEventsAppender { events in
            try await log.append(events)
            throw WorkTaskRuntimeTestError.lostAcknowledgementAfterAppend
        }
        let manager = OrchestratorWorkTaskManager(
            orchestrator: orchestrator,
            currentWorkTaskID: nil,
            canManage: true,
            canUpdateBound: true)

        do {
            _ = try await manager.updateWorkTask(WorkTaskUpdateRequest(
                taskID: created.task.id,
                expectedRevision: created.task.revision,
                progressNote: "durably appended"))
            XCTFail("the simulated lost acknowledgement must surface")
        } catch is ToolExecutionRejectedWithoutSideEffect {
            XCTFail("a post-append failure must remain side-effect-unknown")
        } catch let error as WorkTaskRuntimeTestError {
            XCTAssertEqual(error, .lostAcknowledgementAfterAppend)
        }

        let replayed = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(
            replayed.workTasks[created.task.id]?.revision,
            created.task.revision + 1)
        XCTAssertEqual(
            replayed.workTasks[created.task.id]?.progressNote,
            "durably appended")
    }

    func testCreatePostAppendFailureIsNotMisclassifiedAsNoEffect() async throws {
        let workspace = try workTaskWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (orchestrator, log) = try await makeOrchestrator(workspace: workspace)
        await orchestrator.setAdmissionEventsAppender { events in
            try await log.append(events)
            throw WorkTaskRuntimeTestError.lostAcknowledgementAfterAppend
        }
        let manager = OrchestratorWorkTaskManager(
            orchestrator: orchestrator,
            currentWorkTaskID: nil,
            canManage: true,
            canUpdateBound: true)

        do {
            _ = try await manager.createWorkTask(WorkTaskCreateRequest(
                title: "Create lost acknowledgement",
                description: "Persist before returning an error"))
            XCTFail("the simulated lost acknowledgement must surface")
        } catch is ToolExecutionRejectedWithoutSideEffect {
            XCTFail("a create failure after append must remain side-effect-unknown")
        } catch let error as WorkTaskRuntimeTestError {
            XCTAssertEqual(error, .lostAcknowledgementAfterAppend)
        }

        let replayed = CoworkProjection.build(from: await log.replay())
        let persisted = replayed.workTasks.values.first {
            $0.title == "Create lost acknowledgement"
        }
        XCTAssertNotNil(persisted)
    }

    func testConcurrentCreatesPreserveBothTasksAcrossPersistenceAwait() async throws {
        let workspace = try workTaskWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (orchestrator, log) = try await makeOrchestrator(workspace: workspace)
        let gate = WorkTaskPersistenceGate()
        await orchestrator.setAdmissionEventsAppender { events in
            if events.contains(where: { event in
                if case .workTaskCreated = event { return true }
                return false
            }) {
                await gate.pauseOnce()
            }
            try await log.append(events)
        }

        let first = Task {
            try await orchestrator.createWorkTask(
                canManage: true,
                request: WorkTaskCreateRequest(
                    title: "First concurrent task",
                    description: "Persist the first task"))
        }
        await gate.waitUntilEntered()
        let second = Task {
            try await orchestrator.createWorkTask(
                canManage: true,
                request: WorkTaskCreateRequest(
                    title: "Second concurrent task",
                    description: "Persist the second task"))
        }

        let secondIsSerialized = await waitForAdmissionWaiter(on: orchestrator)
        await gate.release()
        XCTAssertTrue(secondIsSerialized, "the second WorkTask create must wait on admission")
        _ = try await first.value
        _ = try await second.value

        let listed = try await orchestrator.listWorkTasks(
            currentWorkTaskID: nil,
            canManage: true,
            request: WorkTaskListRequest())
        XCTAssertEqual(Set(listed.map(\.task.title)), [
            "First concurrent task",
            "Second concurrent task",
        ])
    }

    func testInvocationSettlementDoesNotMutateIndependentWorkTask() async throws {
        let workspace = try workTaskWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (orchestrator, log) = try await makeOrchestrator(workspace: workspace)
        let created = try await orchestrator.createWorkTask(
            canManage: true,
            request: WorkTaskCreateRequest(
                title: "Settlement race",
                description: "Preserve optimistic revisions during settlement"))
        let gate = WorkTaskPersistenceGate()
        await orchestrator.setTaskLifecycleEventAppender { event in
            if case .taskCompleted = event {
                await gate.pauseOnce()
            }
            try await log.append(event)
        }

        let delegated = Task {
            await orchestrator.delegateTask(
                from: self.main,
                to: self.worker.rawValue,
                workTaskID: created.task.id)
        }
        await gate.waitUntilEntered()
        let settling = try await orchestrator.getWorkTask(
            currentWorkTaskID: nil,
            canManage: true,
            taskID: created.task.id)
        let concurrentUpdate = Task {
            try await orchestrator.updateWorkTask(
                currentWorkTaskID: nil,
                canManage: true,
                canUpdateBound: false,
                request: WorkTaskUpdateRequest(
                    taskID: settling.task.id,
                    expectedRevision: settling.task.revision,
                    progressNote: "manual update racing settlement"))
        }

        let updateIsSerialized = await waitForAdmissionWaiter(on: orchestrator)
        await gate.release()
        XCTAssertTrue(updateIsSerialized, "manual update must wait for invocation settlement")
        let response = await delegated.value
        XCTAssertTrue(response.contains("candidate output"))
        _ = try await concurrentUpdate.value

        let final = try await orchestrator.getWorkTask(
            currentWorkTaskID: nil,
            canManage: true,
            taskID: created.task.id)
        XCTAssertEqual(final.task.progressNote, "manual update racing settlement")
        XCTAssertEqual(final.candidateResults.map(\.result), ["candidate output"])
    }

    func testConcurrentAutoDelegationsAtomicallyReserveDistinctIdleWorkers() async throws {
        let workspace = try workTaskWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (orchestrator, log) = try await makeOrchestrator(workspace: workspace)
        let secondWorker = AgentID(rawValue: "worker-two")
        let didAttachSecondWorker = await orchestrator.attach(Agent(
            name: secondWorker,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "test"),
            profile: .reviewed,
            coordinationDepth: 0))
        XCTAssertTrue(didAttachSecondWorker)
        let firstWork = try await orchestrator.createWorkTask(
            canManage: true,
            request: WorkTaskCreateRequest(
                title: "Parallel first",
                description: "Run on one idle worker"))
        let secondWork = try await orchestrator.createWorkTask(
            canManage: true,
            request: WorkTaskCreateRequest(
                title: "Parallel second",
                description: "Run on another idle worker"))
        let gate = WorkTaskPersistenceGate()
        await orchestrator.setAdmissionEventsAppender { events in
            if events.contains(where: { event in
                if case .delegationApproved = event { return true }
                return false
            }) {
                await gate.pauseOnce()
            }
            try await log.append(events)
        }

        let first = Task {
            await orchestrator.delegateTask(
                from: self.main,
                to: "auto",
                workTaskID: firstWork.task.id)
        }
        await gate.waitUntilEntered()
        let second = Task {
            await orchestrator.delegateTask(
                from: self.main,
                to: "auto",
                workTaskID: secondWork.task.id)
        }
        let secondWaitsForAdmission = await waitForAdmissionWaiter(on: orchestrator)
        await gate.release()
        XCTAssertTrue(secondWaitsForAdmission)

        let responses = await [first.value, second.value]
        let agents = responses.compactMap { response -> String? in
            guard let marker = response.range(of: "agent_id=@") else { return nil }
            let value = response[marker.upperBound...].prefix { !$0.isWhitespace }
            return "agent_id=@\(value)"
        }
        XCTAssertEqual(Set(agents), ["agent_id=@worker", "agent_id=@worker-two"])
    }

    func testExplicitSettlementUnlocksDependentAndRejectsStaleRevision() async throws {
        let workspace = try workTaskWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (orchestrator, _) = try await makeOrchestrator(workspace: workspace)

        let first = try await orchestrator.createWorkTask(
            canManage: true,
            request: WorkTaskCreateRequest(
                title: "Implement",
                description: "Implement the bounded change"))
        XCTAssertEqual(first.task.status, .ready)

        let dependent = try await orchestrator.createWorkTask(
            canManage: true,
            request: WorkTaskCreateRequest(
                title: "Verify",
                description: "Verify after implementation",
                dependsOn: [first.task.id]))
        XCTAssertEqual(dependent.task.status, .pending)

        let started = try await orchestrator.updateWorkTask(
            currentWorkTaskID: nil,
            canManage: true,
            canUpdateBound: false,
            request: WorkTaskUpdateRequest(
                taskID: first.task.id,
                expectedRevision: first.task.revision,
                status: .inProgress))
        let completed = try await orchestrator.updateWorkTask(
            currentWorkTaskID: nil,
            canManage: true,
            canUpdateBound: false,
            request: WorkTaskUpdateRequest(
                taskID: first.task.id,
                expectedRevision: started.task.revision,
                status: .completed,
                result: "implemented"))
        XCTAssertEqual(completed.task.status, .completed)

        let unlocked = try await orchestrator.getWorkTask(
            currentWorkTaskID: nil,
            canManage: true,
            taskID: dependent.task.id)
        XCTAssertEqual(unlocked.task.status, .ready)

        do {
            _ = try await orchestrator.updateWorkTask(
                currentWorkTaskID: nil,
                canManage: true,
                canUpdateBound: false,
                request: WorkTaskUpdateRequest(
                    taskID: dependent.task.id,
                    expectedRevision: dependent.task.revision,
                    progressNote: "stale overwrite"))
            XCTFail("expected optimistic concurrency rejection")
        } catch let violation as WorkTaskGraphViolation {
            XCTAssertEqual(violation.kind, .staleRevision)
        }
    }

    func testDependencyReplanRecomputesUpdatedTaskReadinessInSameBatch() async throws {
        let workspace = try workTaskWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (orchestrator, log) = try await makeOrchestrator(workspace: workspace)

        let prerequisite = try await orchestrator.createWorkTask(
            canManage: true,
            request: WorkTaskCreateRequest(
                title: "Prerequisite",
                description: "Remain incomplete while the plan changes"))
        let waiting = try await orchestrator.createWorkTask(
            canManage: true,
            request: WorkTaskCreateRequest(
                title: "Initially waiting",
                description: "Remove the final dependency",
                dependsOn: [prerequisite.task.id]))
        XCTAssertEqual(waiting.task.status, .pending)

        let unblocked = try await orchestrator.updateWorkTask(
            currentWorkTaskID: nil,
            canManage: true,
            canUpdateBound: false,
            request: WorkTaskUpdateRequest(
                taskID: waiting.task.id,
                expectedRevision: waiting.task.revision,
                dependsOn: []))
        XCTAssertEqual(unblocked.task.status, .ready)

        let initiallyReady = try await orchestrator.createWorkTask(
            canManage: true,
            request: WorkTaskCreateRequest(
                title: "Initially ready",
                description: "Gain an incomplete dependency"))
        XCTAssertEqual(initiallyReady.task.status, .ready)
        let nowWaiting = try await orchestrator.updateWorkTask(
            currentWorkTaskID: nil,
            canManage: true,
            canUpdateBound: false,
            request: WorkTaskUpdateRequest(
                taskID: initiallyReady.task.id,
                expectedRevision: initiallyReady.task.revision,
                dependsOn: [prerequisite.task.id]))
        XCTAssertEqual(nowWaiting.task.status, .pending)
        XCTAssertTrue(nowWaiting.task.progressNote?.contains(prerequisite.task.id.rawValue) == true)

        let replayed = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(replayed.workTasks[waiting.task.id]?.status, .ready)
        XCTAssertEqual(replayed.workTasks[initiallyReady.task.id]?.status, .pending)
    }

    func testInProgressWorkTaskFreezesExecutionContractFields() async throws {
        let workspace = try workTaskWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (orchestrator, _) = try await makeOrchestrator(workspace: workspace)
        let created = try await orchestrator.createWorkTask(
            canManage: true,
            request: WorkTaskCreateRequest(
                title: "Frozen title",
                description: "Frozen description",
                acceptanceCriteria: ["frozen criterion"],
                expectedArtifacts: ["Sources/Frozen.swift"],
                priority: .normal))
        let started = try await orchestrator.updateWorkTask(
            currentWorkTaskID: nil,
            canManage: true,
            canUpdateBound: false,
            request: WorkTaskUpdateRequest(
                taskID: created.task.id,
                expectedRevision: created.task.revision,
                status: .inProgress))
        let mutations: [(String, WorkTaskUpdateRequest)] = [
            ("title", WorkTaskUpdateRequest(
                taskID: started.task.id,
                expectedRevision: started.task.revision,
                title: "Changed title")),
            ("description", WorkTaskUpdateRequest(
                taskID: started.task.id,
                expectedRevision: started.task.revision,
                description: "Changed description")),
            ("acceptance criteria", WorkTaskUpdateRequest(
                taskID: started.task.id,
                expectedRevision: started.task.revision,
                acceptanceCriteria: ["changed criterion"])),
            ("expected artifacts", WorkTaskUpdateRequest(
                taskID: started.task.id,
                expectedRevision: started.task.revision,
                expectedArtifacts: ["Sources/Changed.swift"])),
            ("dependencies", WorkTaskUpdateRequest(
                taskID: started.task.id,
                expectedRevision: started.task.revision,
                dependsOn: [WorkTaskID.new()])),
            ("priority", WorkTaskUpdateRequest(
                taskID: started.task.id,
                expectedRevision: started.task.revision,
                priority: .critical)),
        ]

        for (field, request) in mutations {
            do {
                _ = try await orchestrator.updateWorkTask(
                    currentWorkTaskID: nil,
                    canManage: true,
                    canUpdateBound: false,
                    request: request)
                XCTFail("in-progress mutation unexpectedly changed \(field)")
            } catch let error as IntatisError {
                guard case .permissionDenied(let message) = error else {
                    return XCTFail("\(field) returned the wrong error: \(error)")
                }
                XCTAssertTrue(message.contains("execution contract is frozen"), field)
            } catch {
                XCTFail("\(field) returned the wrong error: \(error)")
            }
        }

        let final = try await orchestrator.getWorkTask(
            currentWorkTaskID: nil,
            canManage: true,
            taskID: started.task.id)
        XCTAssertEqual(final.task.title, "Frozen title")
        XCTAssertEqual(final.task.description, "Frozen description")
        XCTAssertEqual(final.task.acceptanceCriteria, ["frozen criterion"])
        XCTAssertEqual(final.task.expectedArtifacts, ["Sources/Frozen.swift"])
        XCTAssertEqual(final.task.dependsOn, [])
        XCTAssertEqual(final.task.priority, .normal)
        XCTAssertEqual(final.task.revision, started.task.revision)
    }

    func testDelegatedInvocationProducesCandidateWithoutCompletingWorkTask() async throws {
        let workspace = try workTaskWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (orchestrator, log) = try await makeOrchestrator(workspace: workspace)
        let created = try await orchestrator.createWorkTask(
            canManage: true,
            request: WorkTaskCreateRequest(
                title: "Candidate",
                description: "Return a candidate result"))

        let response = await orchestrator.delegateTask(
            from: main,
            to: worker.rawValue,
            workTaskID: created.task.id)
        XCTAssertTrue(response.contains("work_task_id=\(created.task.id.rawValue)"))
        XCTAssertTrue(response.contains("candidate output"))

        let detail = try await orchestrator.getWorkTask(
            currentWorkTaskID: nil,
            canManage: true,
            taskID: created.task.id)
        XCTAssertEqual(detail.task.status, .inProgress)
        XCTAssertNil(detail.task.result)
        XCTAssertEqual(detail.candidateResults.map(\.result), ["candidate output"])
        XCTAssertEqual(detail.task.progressNote, "delegated to @worker")

        let events = await log.replay()
        XCTAssertTrue(events.contains {
            guard case .workTaskInvocationLinked(let payload) = $0.event else { return false }
            return payload.task.id == created.task.id
                && payload.task.latestInvocationIDs.contains(payload.invocationID)
        })
        XCTAssertFalse(events.contains {
            guard case .workTaskCompleted(let payload) = $0.event else { return false }
            return payload.task.id == created.task.id
        })
    }

    func testDelegationPreflightFailureWritesNoPartialFacts() async throws {
        let workspace = try workTaskWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (orchestrator, log) = try await makeOrchestrator(workspace: workspace)
        let prerequisite = try await orchestrator.createWorkTask(
            canManage: true,
            request: WorkTaskCreateRequest(
                title: "Unfinished prerequisite",
                description: "Remain incomplete"))
        let waiting = try await orchestrator.createWorkTask(
            canManage: true,
            request: WorkTaskCreateRequest(
                title: "Waiting task",
                description: "Must not be admitted early",
                dependsOn: [prerequisite.task.id]))
        XCTAssertEqual(waiting.task.status, .pending)
        let before = await log.replay()

        let response = await orchestrator.delegateTask(
            from: main,
            to: worker.rawValue,
            workTaskID: waiting.task.id)

        XCTAssertTrue(response.contains("not delegatable"))
        let after = await log.replay()
        XCTAssertEqual(after, before)
    }

    func testOverlappingWriteArtifactsRejectSecondConcurrentInvocation() async throws {
        let workspace = try workTaskWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (orchestrator, _) = try await makeOrchestrator(
            workspace: workspace,
            workerCoordinationDepth: Agent.defaultCoordinationDepth)
        let secondWorker = AgentID(rawValue: "worker-two")
        let secondWorkerAttached = await orchestrator.attach(Agent(
            name: secondWorker,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "test"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(secondWorkerAttached)
        let first = try await orchestrator.createWorkTask(
            canManage: true,
            request: WorkTaskCreateRequest(
                title: "First writer",
                description: "Edit the feature",
                expectedArtifacts: ["Sources/Feature"]))
        let second = try await orchestrator.createWorkTask(
            canManage: true,
            request: WorkTaskCreateRequest(
                title: "Second writer",
                description: "Edit one nested file",
                expectedArtifacts: ["Sources/Feature/File.swift"]))

        let admitted = await orchestrator.enqueueDelegatedTask(
            from: main,
            to: worker.rawValue,
            workTaskID: first.task.id,
            objective: first.task.description)
        XCTAssertNotNil(admitted.taskID)

        let rejected = await orchestrator.enqueueDelegatedTask(
            from: main,
            to: secondWorker.rawValue,
            workTaskID: second.task.id,
            objective: second.task.description)
        XCTAssertNil(rejected.taskID)
        XCTAssertTrue(rejected.message.contains("resource conflict"))
        XCTAssertTrue(rejected.message.contains(first.task.id.rawValue))
    }

    func testGlobArtifactDeclarationConflictsWorkspaceWide() async throws {
        let workspace = try workTaskWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (orchestrator, _) = try await makeOrchestrator(
            workspace: workspace,
            workerCoordinationDepth: Agent.defaultCoordinationDepth)
        let secondWorker = AgentID(rawValue: "glob-worker-two")
        let secondWorkerAttached = await orchestrator.attach(Agent(
            name: secondWorker,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "test"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(secondWorkerAttached)
        let globWriter = try await orchestrator.createWorkTask(
            canManage: true,
            request: WorkTaskCreateRequest(
                title: "Glob writer",
                description: "Edit Swift sources selected by a glob",
                expectedArtifacts: ["Sources/**/*.swift"]))
        let otherwiseDisjoint = try await orchestrator.createWorkTask(
            canManage: true,
            request: WorkTaskCreateRequest(
                title: "Disjoint writer",
                description: "Edit a documentation file",
                expectedArtifacts: ["Documentation/Guide.md"]))

        let admitted = await orchestrator.enqueueDelegatedTask(
            from: main,
            to: worker.rawValue,
            workTaskID: globWriter.task.id,
            objective: globWriter.task.description)
        XCTAssertNotNil(admitted.taskID)
        let rejected = await orchestrator.enqueueDelegatedTask(
            from: main,
            to: secondWorker.rawValue,
            workTaskID: otherwiseDisjoint.task.id,
            objective: otherwiseDisjoint.task.description)

        XCTAssertNil(rejected.taskID)
        XCTAssertTrue(rejected.message.contains("resource conflict"))
        XCTAssertTrue(rejected.message.contains("workspace-wide"))
        XCTAssertTrue(rejected.message.contains(globWriter.task.id.rawValue))
    }


    func testRestoreRejectsInvalidWorkTaskGraphAndFailsClosed() async throws {
        let log = try workTaskLog()
        let invalid = WorkTask(
            title: "Invalid recovered task",
            description: "References a dependency absent from the durable graph",
            dependsOn: [WorkTaskID.new()])
        try await log.append(.workTaskCreated(WorkTaskCreatedPayload(task: invalid)))
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in WorkTaskProvider() }

        await orchestrator.restore(from: CoworkProjection())

        do {
            _ = try await orchestrator.createWorkTask(
                canManage: true,
                request: WorkTaskCreateRequest(
                    title: "Must not be admitted",
                    description: "Recovery must fail closed"))
            XCTFail("invalid recovered WorkTaskGraph must reject new mutations")
        } catch let error as IntatisError {
            guard case .config(let message) = error else {
                return XCTFail("unexpected recovery error: \(error)")
            }
            XCTAssertTrue(message.contains("WorkTaskGraph recovery rejected"))
            XCTAssertTrue(message.contains("dependency does not exist"))
        }

        let events = await log.replay()
        XCTAssertTrue(events.contains { envelope in
            guard case .error(let payload) = envelope.event else { return false }
            return payload.code == "work_task_graph_restore_rejected"
        })
    }
}
