import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools
import IntatisConversation

/// Durable WorkTask-card authority used by the Codex Cowork runtime.
///
/// This actor owns only the user-visible WorkTask graph. It does not create,
/// schedule, message, wait for, resume, or stop Codex agents and it never calls
/// the legacy Orchestrator/AgentLoop/MessageBus path.
public actor CodexWorkTaskController {
    private struct DurableState {
        var graph: WorkTaskGraph
        var linkedTaskByInvocationID: [TaskID: WorkTaskID]
    }

    private let log: EventLog
    private let rootAgentID: AgentID
    public let agentDirectory: CodexAgentTaskDirectory

    public init(
        log: EventLog,
        rootAgentID: AgentID,
        agentDirectory: CodexAgentTaskDirectory = CodexAgentTaskDirectory()
    ) {
        self.log = log
        self.rootAgentID = rootAgentID
        self.agentDirectory = agentDirectory
    }

    public func manager(
        for agentID: AgentID
    ) -> any WorkTaskManager {
        CodexScopedWorkTaskManager(
            controller: self,
            agentID: agentID,
            canManage: agentID == rootAgentID)
    }

    fileprivate func create(
        request: WorkTaskCreateRequest,
        canManage: Bool
    ) async throws -> WorkTaskDetail {
        var didCommit = false
        do {
            guard canManage else {
                throw IntatisError.permissionDenied(
                    "only the Cowork root may create WorkTask cards")
            }
            let title = request.title.trimmingCharacters(
                in: .whitespacesAndNewlines)
            let description = request.description.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !title.isEmpty, !description.isEmpty else {
                throw IntatisError.decoding(
                    "WorkTask title and description must be non-empty")
            }
            let proposed = WorkTask(
                title: title,
                description: description,
                acceptanceCriteria: request.acceptanceCriteria,
                expectedArtifacts: request.expectedArtifacts,
                priority: request.priority,
                dependsOn: request.dependsOn)
            _ = try await log.appendSessionStateTransaction { envelopes in
                var graph = try Self.state(from: envelopes).graph
                let admitted = try Self.value(graph.add(proposed))
                var events: [Event] = [
                    .workTaskCreated(WorkTaskCreatedPayload(task: admitted)),
                ]
                switch admitted.status {
                case .ready:
                    events.append(.workTaskReady(
                        WorkTaskReadyPayload(task: admitted)))
                case .blocked:
                    events.append(.workTaskBlocked(WorkTaskBlockedPayload(
                        task: admitted,
                        blocker: admitted.progressNote
                            ?? "dependency failed or was cancelled")))
                case .pending, .inProgress, .completed, .failed, .cancelled:
                    break
                }
                return events
            }
            didCommit = true
            let settled = try await currentState()
            guard let task = settled.graph.task(proposed.id) else {
                throw IntatisError.notFound(
                    "WorkTask \(proposed.id.rawValue)")
            }
            return Self.detail(task, graph: settled.graph)
        } catch let rejection as ToolExecutionRejectedWithoutSideEffect {
            throw rejection
        } catch {
            if didCommit { throw error }
            if error is WorkTaskGraphViolation
                || error is IntatisError {
                throw Self.preflightRejection(
                    operation: "task_create",
                    error: error)
            }
            throw error
        }
    }

    fileprivate func update(
        request: WorkTaskUpdateRequest,
        agentID: AgentID,
        canManage: Bool
    ) async throws -> WorkTaskDetail {
        var didCommit = false
        do {
            _ = try await log.appendSessionStateTransaction { envelopes in
                var state = try Self.state(from: envelopes)
                guard let current = state.graph.task(request.taskID) else {
                    throw IntatisError.notFound(
                        "WorkTask \(request.taskID.rawValue)")
                }
                let linkedTaskID = Self.linkedTaskID(
                    for: agentID,
                    state: state)
                let normalized = Self.normalized(
                    request,
                    current: current)
                if !canManage {
                    guard linkedTaskID == current.id else {
                        throw IntatisError.permissionDenied(
                            "a child may update only its linked WorkTask")
                    }
                    guard normalized.title == nil,
                          normalized.description == nil,
                          normalized.acceptanceCriteria == nil,
                          normalized.expectedArtifacts == nil,
                          normalized.dependsOn == nil,
                          normalized.priority == nil,
                          !normalized.isRetry,
                          normalized.status != .ready,
                          normalized.status != .cancelled else {
                        throw IntatisError.permissionDenied(
                            "a child cannot change the WorkTask contract, graph, priority, retry, or cancellation state")
                    }
                }
                if current.status == .inProgress {
                    guard normalized.title == nil,
                          normalized.description == nil,
                          normalized.acceptanceCriteria == nil,
                          normalized.expectedArtifacts == nil,
                          normalized.dependsOn == nil,
                          normalized.priority == nil else {
                        throw IntatisError.permissionDenied(
                            "an in-progress WorkTask contract, dependency graph, and priority are frozen")
                    }
                }
                guard Self.hasMutation(normalized) else {
                    throw IntatisError.decoding(
                        "task_update requires at least one changed field")
                }

                var proposed = current
                if let value = normalized.title { proposed.title = value }
                if let value = normalized.description {
                    proposed.description = value
                }
                if let value = normalized.acceptanceCriteria {
                    proposed.acceptanceCriteria = value
                }
                if let value = normalized.expectedArtifacts {
                    proposed.expectedArtifacts = value
                }
                if let value = normalized.dependsOn {
                    proposed.dependsOn = value
                }
                if let value = normalized.priority {
                    proposed.priority = value
                }
                if let value = normalized.progressNote {
                    proposed.progressNote = value
                }
                if let value = normalized.status {
                    proposed.status = value
                }
                if let value = normalized.result {
                    proposed.result = value
                }
                if let value = normalized.evidence {
                    proposed.evidence = value.map { $0.materialize() }
                }

                let updated = try Self.value(state.graph.update(
                    proposed,
                    expectedRevision: normalized.expectedRevision,
                    isRetry: normalized.isRetry,
                    recomputeReadinessAfterDependencyChange:
                        normalized.dependsOn != nil
                            && normalized.status == nil))
                var events = Self.mutationEvents(
                    previous: current,
                    next: updated)
                Self.reconcileDependents(
                    changedTaskID: updated.id,
                    graph: &state.graph,
                    events: &events)
                return events
            }
            didCommit = true
            let settled = try await currentState()
            guard let task = settled.graph.task(request.taskID) else {
                throw IntatisError.notFound(
                    "WorkTask \(request.taskID.rawValue)")
            }
            return Self.detail(task, graph: settled.graph)
        } catch let rejection as ToolExecutionRejectedWithoutSideEffect {
            throw rejection
        } catch {
            if didCommit { throw error }
            if error is WorkTaskGraphViolation
                || error is IntatisError {
                throw Self.preflightRejection(
                    operation: "task_update",
                    error: error,
                    taskID: request.taskID)
            }
            throw error
        }
    }

    fileprivate func get(
        taskID: WorkTaskID,
        agentID: AgentID,
        canManage: Bool
    ) async throws -> WorkTaskDetail {
        let state = try await currentState()
        guard let task = state.graph.task(taskID) else {
            throw IntatisError.notFound("WorkTask \(taskID.rawValue)")
        }
        guard canManage
                || Self.childCanRead(
                    taskID,
                    agentID: agentID,
                    state: state) else {
            throw IntatisError.permissionDenied(
                "WorkTask is outside the child agent's readable scope")
        }
        return Self.detail(task, graph: state.graph)
    }

    fileprivate func list(
        request: WorkTaskListRequest,
        agentID: AgentID,
        canManage: Bool
    ) async throws -> [WorkTaskDetail] {
        let state = try await currentState()
        let visible: [WorkTask]
        if canManage {
            visible = Array(state.graph.tasks.values)
        } else if let linked = Self.linkedTaskID(
            for: agentID,
            state: state),
                  let current = state.graph.task(linked) {
            let ids = Set([current.id] + current.dependsOn)
            visible = state.graph.tasks.values.filter {
                ids.contains($0.id)
            }
        } else {
            visible = []
        }
        return visible
            .filter {
                request.statuses.isEmpty
                    || request.statuses.contains($0.status)
            }
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id.rawValue < $1.id.rawValue
                }
                return $0.createdAt < $1.createdAt
            }
            .map { Self.detail($0, graph: state.graph) }
    }

    /// Host-only association of one verified Codex child identity with a
    /// WorkTask card. The model never supplies a thread id to this method.
    public func link(
        taskID: WorkTaskID,
        expectedRevision: Int,
        verifiedAgentID: AgentID
    ) async throws -> WorkTaskDetail {
        try await linkVerified(
            taskID: taskID,
            expectedRevision: expectedRevision,
            verifiedAgentID: verifiedAgentID)
    }

    fileprivate func link(
        taskID: WorkTaskID,
        expectedRevision: Int,
        agentTaskName: String,
        canManage: Bool
    ) async throws -> WorkTaskDetail {
        guard canManage else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "permission_denied",
                message: "only the Cowork root may link a WorkTask to a Codex child")
        }
        guard let agentID = await agentDirectory.resolve(
            taskName: agentTaskName) else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "codex_agent_not_found",
                message: "task_link_agent requires a canonical task name returned by a completed spawn_agent or list_agents call")
        }
        return try await link(
            taskID: taskID,
            expectedRevision: expectedRevision,
            verifiedAgentID: agentID)
    }

    /// Atomically links a verified App Server child using the current durable
    /// WorkTask revision. This host-only overload avoids a read/link race; the
    /// model still cannot supply or guess a Codex thread identity.
    public func link(
        taskID: WorkTaskID,
        verifiedAgentID: AgentID
    ) async throws -> WorkTaskDetail {
        try await linkVerified(
            taskID: taskID,
            expectedRevision: nil,
            verifiedAgentID: verifiedAgentID)
    }

    private func linkVerified(
        taskID: WorkTaskID,
        expectedRevision: Int?,
        verifiedAgentID: AgentID
    ) async throws -> WorkTaskDetail {
        let invocationID = Self.invocationID(for: verifiedAgentID)
        var didCommit = false
        do {
            let persisted = try await log.appendSessionStateTransaction { envelopes in
                var state = try Self.state(from: envelopes)
                guard let current = state.graph.task(taskID) else {
                    throw IntatisError.notFound(
                        "WorkTask \(taskID.rawValue)")
                }
                if state.linkedTaskByInvocationID[invocationID] == taskID,
                   current.latestInvocationIDs.contains(invocationID) {
                    return []
                }
                if let priorID = state.linkedTaskByInvocationID[invocationID],
                   priorID != taskID,
                   let prior = state.graph.task(priorID),
                   !prior.status.isTerminal {
                    throw IntatisError.permissionDenied(
                        "a Codex child may have only one active WorkTask association")
                }

                let linked: WorkTask
                if current.latestInvocationIDs.contains(invocationID) {
                    // Reusing a child after a prior terminal task records a new
                    // ordered link event without inventing a content revision.
                    linked = current
                } else {
                    var proposed = current
                    proposed.latestInvocationIDs.append(invocationID)
                    linked = try Self.value(state.graph.update(
                        proposed,
                        expectedRevision:
                            expectedRevision ?? current.revision))
                }
                return [.workTaskInvocationLinked(
                    WorkTaskInvocationLinkedPayload(
                        task: linked,
                        invocationID: invocationID))]
            }
            didCommit = !persisted.isEmpty
            let settled = try await currentState()
            guard let task = settled.graph.task(taskID) else {
                throw IntatisError.notFound(
                    "WorkTask \(taskID.rawValue)")
            }
            return Self.detail(task, graph: settled.graph)
        } catch let rejection as ToolExecutionRejectedWithoutSideEffect {
            throw rejection
        } catch {
            if didCommit { throw error }
            if error is WorkTaskGraphViolation
                || error is IntatisError {
                throw Self.preflightRejection(
                    operation: "task_link_agent",
                    error: error,
                    taskID: taskID)
            }
            throw error
        }
    }

    private func currentState() async throws -> DurableState {
        try Self.state(from: await log.replay())
    }

    private static func state(
        from envelopes: [Envelope]
    ) throws -> DurableState {
        let projection = CoworkProjection.build(from: envelopes)
        let graph = try Self.value(WorkTaskGraph.validating(
            Array(projection.workTasks.values)))
        var links: [TaskID: WorkTaskID] = [:]
        for envelope in envelopes {
            guard case .workTaskInvocationLinked(let payload) =
                    envelope.event else { continue }
            links[payload.invocationID] = payload.task.id
        }
        return DurableState(
            graph: graph,
            linkedTaskByInvocationID: links)
    }

    private static func invocationID(for agentID: AgentID) -> TaskID {
        TaskID(rawValue: "codex-agent:\(agentID.rawValue)")
    }

    private static func linkedTaskID(
        for agentID: AgentID,
        state: DurableState
    ) -> WorkTaskID? {
        state.linkedTaskByInvocationID[
            invocationID(for: agentID)]
    }

    private static func childCanRead(
        _ taskID: WorkTaskID,
        agentID: AgentID,
        state: DurableState
    ) -> Bool {
        guard let linkedID = linkedTaskID(for: agentID, state: state),
              let linked = state.graph.task(linkedID) else { return false }
        return taskID == linkedID || linked.dependsOn.contains(taskID)
    }

    private static func normalized(
        _ request: WorkTaskUpdateRequest,
        current: WorkTask
    ) -> WorkTaskUpdateRequest {
        var value = request
        if value.title == current.title { value.title = nil }
        if value.description == current.description {
            value.description = nil
        }
        if value.acceptanceCriteria == current.acceptanceCriteria {
            value.acceptanceCriteria = nil
        }
        if value.expectedArtifacts == current.expectedArtifacts {
            value.expectedArtifacts = nil
        }
        if value.dependsOn == current.dependsOn { value.dependsOn = nil }
        if value.priority == current.priority { value.priority = nil }
        return value
    }

    private static func hasMutation(_ request: WorkTaskUpdateRequest) -> Bool {
        request.title != nil
            || request.description != nil
            || request.acceptanceCriteria != nil
            || request.expectedArtifacts != nil
            || request.dependsOn != nil
            || request.priority != nil
            || request.progressNote != nil
            || request.status != nil
            || request.result != nil
            || request.evidence != nil
            || request.isRetry
    }

    private static func detail(
        _ task: WorkTask,
        graph: WorkTaskGraph
    ) -> WorkTaskDetail {
        let dependencies = task.dependsOn.compactMap { id in
            graph.task(id).map {
                WorkTaskDependencyView(taskID: $0.id, status: $0.status)
            }
        }
        let downstream = graph.tasks.values
            .filter { $0.dependsOn.contains(task.id) }
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .map(\.id)
        return WorkTaskDetail(
            task: task,
            dependencies: dependencies,
            downstreamTaskIDs: downstream,
            candidateResults: [])
    }

    private static func mutationEvents(
        previous: WorkTask,
        next: WorkTask
    ) -> [Event] {
        var events: [Event] = [
            .workTaskUpdated(WorkTaskUpdatedPayload(
                task: next,
                previousRevision: previous.revision)),
        ]
        if previous.dependsOn != next.dependsOn {
            events.append(.workTaskDependencyChanged(
                WorkTaskDependencyChangedPayload(
                    task: next,
                    previousDependencies: previous.dependsOn)))
        }
        for evidence in next.evidence where !previous.evidence.contains(evidence) {
            events.append(.workTaskEvidenceAdded(
                WorkTaskEvidenceAddedPayload(task: next, evidence: evidence)))
        }
        if previous.status != next.status {
            switch next.status {
            case .pending:
                break
            case .ready:
                events.append(.workTaskReady(
                    WorkTaskReadyPayload(task: next)))
            case .inProgress:
                events.append(.workTaskStarted(
                    WorkTaskStartedPayload(task: next)))
            case .blocked:
                events.append(.workTaskBlocked(WorkTaskBlockedPayload(
                    task: next,
                    blocker: next.progressNote ?? "WorkTask blocked")))
            case .completed:
                events.append(.workTaskCompleted(
                    WorkTaskCompletedPayload(task: next)))
            case .failed:
                events.append(.workTaskFailed(WorkTaskFailedPayload(
                    task: next,
                    error: next.result ?? next.progressNote
                        ?? "WorkTask failed")))
            case .cancelled:
                events.append(.workTaskCancelled(
                    WorkTaskCancelledPayload(
                        task: next,
                        reason: next.progressNote
                            ?? "WorkTask cancelled")))
            }
        } else if previous.progressNote != next.progressNote {
            events.append(.workTaskProgressed(
                WorkTaskProgressedPayload(task: next)))
        }
        return events
    }

    private static func reconcileDependents(
        changedTaskID: WorkTaskID,
        graph: inout WorkTaskGraph,
        events: inout [Event]
    ) {
        let dependentIDs = graph.tasks.values
            .filter {
                $0.dependsOn.contains(changedTaskID)
                    && !$0.status.isTerminal
                    && $0.status != .inProgress
            }
            .map(\.id)
            .sorted { $0.rawValue < $1.rawValue }
        for id in dependentIDs {
            guard let current = graph.task(id) else { continue }
            let target: (WorkTaskStatus, String?)?
            switch graph.readiness(of: id) {
            case .success(.ready)
                where current.status == .pending || current.status == .blocked:
                target = (.ready, nil)
            case .success(.waitingFor(let waiting))
                where current.status == .ready:
                target = (
                    .blocked,
                    "waiting for dependencies: "
                        + waiting.map(\.rawValue).sorted()
                            .joined(separator: ", "))
            case .success(.blockedBy(let blocked))
                where current.status == .pending || current.status == .ready:
                target = (
                    .blocked,
                    "dependency failed or was cancelled: "
                        + blocked.map(\.rawValue).sorted()
                            .joined(separator: ", "))
            default:
                target = nil
            }
            guard let target,
                  case .success(let changed) = graph.transition(
                    taskID: id,
                    to: target.0,
                    expectedRevision: current.revision,
                    progressNote: target.1) else { continue }
            if changed.status == .ready {
                events.append(.workTaskReady(
                    WorkTaskReadyPayload(task: changed)))
            } else {
                events.append(.workTaskBlocked(WorkTaskBlockedPayload(
                    task: changed,
                    blocker: target.1 ?? "dependency blocked")))
            }
        }
    }

    private static func preflightRejection(
        operation: String,
        error: Error,
        taskID: WorkTaskID? = nil
    ) -> ToolExecutionRejectedWithoutSideEffect {
        let code: String
        if let violation = error as? WorkTaskGraphViolation {
            code = violation.kind.rawValue
        } else if let value = error as? IntatisError {
            switch value {
            case .permissionDenied: code = "permission_denied"
            case .notFound: code = "not_found"
            case .decoding: code = "invalid_input"
            case .config: code = "invalid_state"
            case .provider: code = "provider_error"
            case .io: code = "io_error"
            case .cancelled: code = "cancelled"
            }
        } else {
            code = "preflight_rejected"
        }
        let suffix = taskID.map {
            " Refresh task \($0.rawValue) with task_get before retrying."
        } ?? " Confirm dependency IDs with task_get/task_list before retrying."
        return ToolExecutionRejectedWithoutSideEffect(
            code: code,
            message: "\(operation) rejected before its first WorkTask EventLog append: \(error.localizedDescription).\(suffix)")
    }

    private static func value<T>(
        _ result: Result<T, WorkTaskGraphViolation>
    ) throws -> T {
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}

public protocol CodexWorkTaskAgentLinking: WorkTaskManager {
    func linkWorkTask(
        taskID: WorkTaskID,
        expectedRevision: Int,
        agentTaskName: String
    ) async throws -> WorkTaskDetail
}

public actor CodexAgentTaskDirectory {
    private var agentsByTaskName: [String: AgentID] = [:]
    private var taskNameByAgent: [AgentID: String] = [:]

    public init() {}

    public func register(
        taskName: String,
        verifiedAgentID: AgentID
    ) throws {
        try replace(
            previousTaskName: taskNameByAgent[verifiedAgentID],
            taskName: taskName,
            verifiedAgentID: verifiedAgentID)
    }

    /// Validates the complete replacement before mutating either side of the
    /// one-to-one directory. A conflicting new path therefore cannot erase a
    /// previously valid mapping.
    public func replace(
        previousTaskName: String?,
        taskName: String,
        verifiedAgentID: AgentID
    ) throws {
        let normalized = taskName.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw IntatisError.config(
                "Codex task name is empty")
        }
        if let existing = agentsByTaskName[normalized],
           existing != verifiedAgentID {
            throw IntatisError.config(
                "Codex task name already belongs to another child")
        }
        let current = taskNameByAgent[verifiedAgentID]
        if let previousTaskName {
            let normalizedPrevious = previousTaskName.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard current == nil || current == normalizedPrevious else {
                throw IntatisError.config(
                    "Codex child task identity changed from an unexpected generation")
            }
        }
        if let current, current != normalized {
            agentsByTaskName.removeValue(forKey: current)
        }
        agentsByTaskName[normalized] = verifiedAgentID
        taskNameByAgent[verifiedAgentID] = normalized
    }

    public func unregister(taskName: String, verifiedAgentID: AgentID) {
        let normalized = taskName.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard agentsByTaskName[normalized] == verifiedAgentID else {
            return
        }
        agentsByTaskName.removeValue(forKey: normalized)
        if taskNameByAgent[verifiedAgentID] == normalized {
            taskNameByAgent.removeValue(forKey: verifiedAgentID)
        }
    }

    public func resolve(taskName: String) -> AgentID? {
        agentsByTaskName[taskName.trimmingCharacters(
            in: .whitespacesAndNewlines)]
    }
}

public struct CodexScopedWorkTaskManager: CodexWorkTaskAgentLinking,
    Sendable
{
    private let controller: CodexWorkTaskController
    private let agentID: AgentID
    private let canManage: Bool

    fileprivate init(
        controller: CodexWorkTaskController,
        agentID: AgentID,
        canManage: Bool
    ) {
        self.controller = controller
        self.agentID = agentID
        self.canManage = canManage
    }

    public func createWorkTask(
        _ request: WorkTaskCreateRequest
    ) async throws -> WorkTaskDetail {
        try await controller.create(
            request: request,
            canManage: canManage)
    }

    public func updateWorkTask(
        _ request: WorkTaskUpdateRequest
    ) async throws -> WorkTaskDetail {
        try await controller.update(
            request: request,
            agentID: agentID,
            canManage: canManage)
    }

    public func getWorkTask(
        _ taskID: WorkTaskID
    ) async throws -> WorkTaskDetail {
        try await controller.get(
            taskID: taskID,
            agentID: agentID,
            canManage: canManage)
    }

    public func listWorkTasks(
        _ request: WorkTaskListRequest
    ) async throws -> [WorkTaskDetail] {
        try await controller.list(
            request: request,
            agentID: agentID,
            canManage: canManage)
    }

    public func linkWorkTask(
        taskID: WorkTaskID,
        expectedRevision: Int,
        agentTaskName: String
    ) async throws -> WorkTaskDetail {
        try await controller.link(
            taskID: taskID,
            expectedRevision: expectedRevision,
            agentTaskName: agentTaskName,
            canManage: canManage)
    }
}

public enum CodexWorkTaskToolRegistry {
    public static let registrations: [ToolRegistration] = [
        ToolRegistration(
            tool: TaskCreateTool(),
            grantingCapabilities: [.manageWorkTasks]),
        ToolRegistration(
            tool: TaskUpdateTool(),
            grantingCapabilities: [
                .manageWorkTasks,
                .updateBoundWorkTask,
            ]),
        ToolRegistration(
            tool: TaskGetTool(),
            grantingCapabilities: [
                .manageWorkTasks,
                .readWorkTasks,
            ]),
        ToolRegistration(
            tool: TaskListTool(),
            grantingCapabilities: [
                .manageWorkTasks,
                .readWorkTasks,
            ]),
        ToolRegistration(
            tool: TaskLinkAgentTool(),
            grantingCapabilities: [.manageWorkTasks]),
    ]
}
