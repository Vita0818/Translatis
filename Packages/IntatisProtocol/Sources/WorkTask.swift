import Foundation
import IntatisCore

/// Durable, user-visible work state. This is deliberately separate from the
/// execution-layer ``TaskStatus`` used by agent invocations.
public enum WorkTaskStatus: String, Codable, Sendable, Hashable {
    case pending
    case ready
    case inProgress = "in_progress"
    case blocked
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .pending, .ready, .inProgress, .blocked:
            return false
        }
    }

    /// Validates explicit state changes. `pending` and `ready` are still
    /// expected to be selected by the host after checking the dependency DAG.
    public func canTransition(to next: WorkTaskStatus,
                              isRetry: Bool = false) -> Bool {
        if self == next { return true }
        switch (self, next) {
        case (.pending, .ready),
             (.pending, .blocked),
             (.pending, .cancelled),
             (.ready, .inProgress),
             (.ready, .blocked),
             (.ready, .cancelled),
             (.inProgress, .completed),
             (.inProgress, .blocked),
             (.inProgress, .failed),
             (.inProgress, .cancelled),
             (.blocked, .ready),
             (.blocked, .failed),
             (.blocked, .cancelled):
            return true
        case (.failed, .ready), (.cancelled, .ready):
            return isRetry
        default:
            return false
        }
    }
}

public enum WorkTaskPriority: String, Codable, Sendable, Hashable, CaseIterable {
    case low
    case normal
    case high
    case critical
}

/// Evidence attached to an explicit WorkTask settlement.
public struct TaskEvidence: Codable, Sendable, Hashable {
    public var kind: String
    public var reference: String
    public var summary: String
    public var recordedAt: Date

    public init(kind: String,
                reference: String,
                summary: String,
                recordedAt: Date = Date()) {
        self.kind = kind
        self.reference = reference
        self.summary = summary
        self.recordedAt = recordedAt
    }
}

/// A stable unit in the user-visible plan. It can link to many execution-layer
/// invocations without deriving its completion state from any invocation.
public struct WorkTask: Codable, Sendable, Hashable, Identifiable {
    public var id: WorkTaskID

    public var title: String
    public var description: String
    public var acceptanceCriteria: [String]
    public var expectedArtifacts: [String]

    public var status: WorkTaskStatus
    public var priority: WorkTaskPriority
    public var dependsOn: [WorkTaskID]

    public var progressNote: String?
    public var result: String?
    public var evidence: [TaskEvidence]
    public var latestInvocationIDs: [TaskID]

    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var revision: Int

    public init(id: WorkTaskID = WorkTaskID.new(),
                title: String,
                description: String,
                acceptanceCriteria: [String] = [],
                expectedArtifacts: [String] = [],
                status: WorkTaskStatus = .pending,
                priority: WorkTaskPriority = .normal,
                dependsOn: [WorkTaskID] = [],
                progressNote: String? = nil,
                result: String? = nil,
                evidence: [TaskEvidence] = [],
                latestInvocationIDs: [TaskID] = [],
                createdAt: Date = Date(),
                updatedAt: Date? = nil,
                completedAt: Date? = nil,
                revision: Int = 0) {
        self.id = id
        self.title = title
        self.description = description
        self.acceptanceCriteria = acceptanceCriteria
        self.expectedArtifacts = expectedArtifacts
        self.status = status
        self.priority = priority
        self.dependsOn = Self.unique(dependsOn)
        self.progressNote = progressNote
        self.result = result
        self.evidence = evidence
        self.latestInvocationIDs = Self.unique(latestInvocationIDs)
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.completedAt = completedAt
        self.revision = revision
    }

    public var hasValidCompletionEvidence: Bool {
        guard status == .completed,
              let result,
              !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return acceptanceCriteria.isEmpty || !evidence.isEmpty
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }
}

public enum WorkTaskReadiness: Sendable, Hashable {
    case ready
    case waitingFor([WorkTaskID])
    case blockedBy([WorkTaskID])
}

public struct WorkTaskGraphViolation: Error, Codable, Sendable, Hashable,
    CustomStringConvertible {
    public enum Kind: String, Codable, Sendable, Hashable {
        case duplicateTaskID = "duplicate_task_id"
        case missingTask = "missing_task"
        case missingDependency = "missing_dependency"
        case selfDependency = "self_dependency"
        case cycleDetected = "cycle_detected"
        case staleRevision = "stale_revision"
        case invalidRevision = "invalid_revision"
        case immutableIdentity = "immutable_identity"
        case invalidStatusTransition = "invalid_status_transition"
        case dependenciesUnsatisfied = "dependencies_unsatisfied"
        case terminalDependency = "terminal_dependency"
        case missingCompletionResult = "missing_completion_result"
        case missingCompletionEvidence = "missing_completion_evidence"
    }

    public var kind: Kind
    public var message: String
    public var taskID: WorkTaskID?
    public var dependencyID: WorkTaskID?
    public var expectedRevision: Int?
    public var actualRevision: Int?

    public init(kind: Kind,
                message: String,
                taskID: WorkTaskID? = nil,
                dependencyID: WorkTaskID? = nil,
                expectedRevision: Int? = nil,
                actualRevision: Int? = nil) {
        self.kind = kind
        self.message = message
        self.taskID = taskID
        self.dependencyID = dependencyID
        self.expectedRevision = expectedRevision
        self.actualRevision = actualRevision
    }

    public var description: String { message }
}

/// Validates and mutates the durable planning DAG. The graph never treats an
/// execution-layer invocation result as WorkTask completion.
public struct WorkTaskGraph: Codable, Sendable, Hashable {
    public private(set) var tasks: [WorkTaskID: WorkTask]

    public init(tasks: [WorkTaskID: WorkTask] = [:]) {
        self.tasks = tasks
    }

    public func task(_ id: WorkTaskID) -> WorkTask? {
        tasks[id]
    }

    /// Constructs a graph from an unordered recovery snapshot without trapping
    /// on duplicate IDs or requiring dependencies to precede their consumers.
    public static func validating(_ snapshots: [WorkTask])
        -> Result<WorkTaskGraph, WorkTaskGraphViolation> {
        var values: [WorkTaskID: WorkTask] = [:]
        for task in snapshots {
            guard values[task.id] == nil else {
                return .failure(Self.violation(
                    .duplicateTaskID, task.id,
                    "work task id already exists: \(task.id.rawValue)"))
            }
            values[task.id] = task
        }
        let graph = WorkTaskGraph(tasks: values)
        if case .failure(let violation) = graph.validate() {
            return .failure(violation)
        }
        return .success(graph)
    }

    public func readiness(of taskID: WorkTaskID) -> Result<WorkTaskReadiness, WorkTaskGraphViolation> {
        guard let task = tasks[taskID] else {
            return .failure(Self.violation(.missingTask, taskID, "work task does not exist"))
        }
        var waiting: [WorkTaskID] = []
        var blocked: [WorkTaskID] = []
        for dependencyID in task.dependsOn {
            guard let dependency = tasks[dependencyID] else {
                return .failure(WorkTaskGraphViolation(
                    kind: .missingDependency,
                    message: "dependency does not exist: \(dependencyID.rawValue)",
                    taskID: taskID,
                    dependencyID: dependencyID))
            }
            switch dependency.status {
            case .completed:
                break
            case .failed, .cancelled:
                blocked.append(dependencyID)
            case .pending, .ready, .inProgress, .blocked:
                waiting.append(dependencyID)
            }
        }
        if !blocked.isEmpty { return .success(.blockedBy(blocked)) }
        if !waiting.isEmpty { return .success(.waitingFor(waiting)) }
        return .success(.ready)
    }

    /// Validates the entire Session-scoped graph, including identity
    /// consistency, references, and cycle freedom.
    public func validate() -> Result<Void, WorkTaskGraphViolation> {
        for (key, task) in tasks {
            guard key == task.id else {
                return .failure(Self.violation(
                    .immutableIdentity, key,
                    "dictionary key does not match work task id"))
            }
            if task.dependsOn.contains(task.id) {
                return .failure(WorkTaskGraphViolation(
                    kind: .selfDependency,
                    message: "work task cannot depend on itself",
                    taskID: task.id,
                    dependencyID: task.id))
            }
            guard task.revision >= 0 else {
                return .failure(WorkTaskGraphViolation(
                    kind: .invalidRevision,
                    message: "work task revision cannot be negative",
                    taskID: task.id,
                    actualRevision: task.revision))
            }
            if task.status == .completed {
                guard let result = task.result,
                      !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .failure(Self.violation(
                        .missingCompletionResult, task.id,
                        "completed work task requires a non-empty result"))
                }
                guard task.acceptanceCriteria.isEmpty || !task.evidence.isEmpty else {
                    return .failure(Self.violation(
                        .missingCompletionEvidence, task.id,
                        "completed work task with acceptance criteria requires evidence"))
                }
            }
            for dependencyID in task.dependsOn {
                guard tasks[dependencyID] != nil else {
                    return .failure(WorkTaskGraphViolation(
                        kind: .missingDependency,
                        message: "dependency does not exist: \(dependencyID.rawValue)",
                        taskID: task.id,
                        dependencyID: dependencyID))
                }
            }
        }

        var visiting: Set<WorkTaskID> = []
        var visited: Set<WorkTaskID> = []
        func visit(_ id: WorkTaskID) -> WorkTaskGraphViolation? {
            if visiting.contains(id) {
                return WorkTaskGraphViolation(
                    kind: .cycleDetected,
                    message: "work task dependency cycle detected at \(id.rawValue)",
                    taskID: id)
            }
            if visited.contains(id) { return nil }
            visiting.insert(id)
            for dependencyID in tasks[id]?.dependsOn ?? [] {
                if let violation = visit(dependencyID) { return violation }
            }
            visiting.remove(id)
            visited.insert(id)
            return nil
        }
        for id in tasks.keys {
            if let violation = visit(id) { return .failure(violation) }
        }
        return .success(())
    }

    @discardableResult
    public mutating func add(_ task: WorkTask) -> Result<WorkTask, WorkTaskGraphViolation> {
        guard tasks[task.id] == nil else {
            return .failure(Self.violation(
                .duplicateTaskID, task.id,
                "work task id already exists: \(task.id.rawValue)"))
        }
        guard task.revision == 0 else {
            return .failure(WorkTaskGraphViolation(
                kind: .invalidRevision,
                message: "new work task must start at revision 0",
                taskID: task.id,
                expectedRevision: 0,
                actualRevision: task.revision))
        }
        guard task.status == .pending || task.status == .ready else {
            return .failure(Self.violation(
                .invalidStatusTransition, task.id,
                "new work task must start pending or ready"))
        }
        var candidate = self
        candidate.tasks[task.id] = task
        if case .failure(let violation) = candidate.validate() {
            return .failure(violation)
        }
        var admitted = task
        switch candidate.readiness(of: task.id) {
        case .success(.ready):
            admitted.status = .ready
        case .success(.waitingFor):
            admitted.status = .pending
        case .success(.blockedBy(let dependencies)):
            admitted.status = .blocked
            admitted.progressNote = "blocked by terminal dependencies: "
                + dependencies.map(\.rawValue).joined(separator: ", ")
        case .failure(let violation):
            return .failure(violation)
        }
        tasks[admitted.id] = admitted
        return .success(admitted)
    }

    /// Replaces mutable fields using optimistic concurrency. The graph owns the
    /// revision increment and rejects identity rebinding.
    @discardableResult
    public mutating func update(_ proposed: WorkTask,
                                expectedRevision: Int,
                                isRetry: Bool = false,
                                recomputeReadinessAfterDependencyChange: Bool = false,
                                updatedAt: Date = Date()) -> Result<WorkTask, WorkTaskGraphViolation> {
        guard let current = tasks[proposed.id] else {
            return .failure(Self.violation(.missingTask, proposed.id, "work task does not exist"))
        }
        guard current.revision == expectedRevision else {
            return .failure(WorkTaskGraphViolation(
                kind: .staleRevision,
                message: "expected revision \(expectedRevision), actual \(current.revision)",
                taskID: proposed.id,
                expectedRevision: expectedRevision,
                actualRevision: current.revision))
        }
        guard proposed.id == current.id,
              proposed.createdAt == current.createdAt else {
            return .failure(Self.violation(
                .immutableIdentity, proposed.id,
                "id and createdAt are immutable"))
        }
        var next = proposed
        next.dependsOn = Self.unique(next.dependsOn)
        next.latestInvocationIDs = Self.unique(next.latestInvocationIDs)
        next.revision = current.revision + 1
        next.updatedAt = updatedAt
        if next.status == .completed {
            guard let result = next.result,
                  !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(Self.violation(
                    .missingCompletionResult, next.id,
                    "completed work task requires a non-empty result"))
            }
            guard next.acceptanceCriteria.isEmpty || !next.evidence.isEmpty else {
                return .failure(Self.violation(
                    .missingCompletionEvidence, next.id,
                    "completed work task with acceptance criteria requires evidence"))
            }
            next.completedAt = next.completedAt ?? updatedAt
        } else if !next.status.isTerminal {
            next.completedAt = nil
        }

        var candidate = self
        candidate.tasks[next.id] = next
        if case .failure(let violation) = candidate.validate() {
            return .failure(violation)
        }
        let hostDerivedReadiness = recomputeReadinessAfterDependencyChange
            && next.dependsOn != current.dependsOn
            && (current.status == .pending
                || current.status == .ready
                || (current.status == .blocked
                    && Self.hasDependencyGeneratedProgressNote(current.progressNote)))
        if hostDerivedReadiness {
            switch candidate.readiness(of: next.id) {
            case .success(.ready):
                next.status = .ready
                if Self.hasDependencyGeneratedProgressNote(next.progressNote) {
                    next.progressNote = nil
                }
            case .success(.waitingFor(let dependencies)):
                next.status = .pending
                next.progressNote = "waiting for dependencies: "
                    + dependencies.map(\.rawValue).sorted().joined(separator: ", ")
            case .success(.blockedBy(let dependencies)):
                next.status = .blocked
                next.progressNote = "dependency failed or was cancelled: "
                    + dependencies.map(\.rawValue).sorted().joined(separator: ", ")
            case .failure(let violation):
                return .failure(violation)
            }
            candidate.tasks[next.id] = next
        }
        guard hostDerivedReadiness
            || current.status.canTransition(to: next.status, isRetry: isRetry) else {
            return .failure(Self.violation(
                .invalidStatusTransition, proposed.id,
                "invalid status transition \(current.status.rawValue) -> \(next.status.rawValue)"))
        }
        if next.status == .ready || next.status == .inProgress {
            switch candidate.readiness(of: next.id) {
            case .success(.ready):
                break
            case .success(.waitingFor):
                return .failure(Self.violation(
                    .dependenciesUnsatisfied, next.id,
                    "work task dependencies are not completed"))
            case .success(.blockedBy):
                return .failure(Self.violation(
                    .terminalDependency, next.id,
                    "work task has a failed or cancelled dependency"))
            case .failure(let violation):
                return .failure(violation)
            }
        }
        tasks[next.id] = next
        return .success(next)
    }

    private static func hasDependencyGeneratedProgressNote(_ note: String?) -> Bool {
        guard let note else { return false }
        return note.hasPrefix("waiting for dependencies:")
            || note.hasPrefix("dependency failed or was cancelled:")
            || note.hasPrefix("blocked by terminal dependencies:")
    }

    @discardableResult
    public mutating func transition(taskID: WorkTaskID,
                                    to status: WorkTaskStatus,
                                    expectedRevision: Int,
                                    isRetry: Bool = false,
                                    progressNote: String? = nil,
                                    result: String? = nil,
                                    evidence: [TaskEvidence]? = nil,
                                    updatedAt: Date = Date()) -> Result<WorkTask, WorkTaskGraphViolation> {
        guard var proposed = tasks[taskID] else {
            return .failure(Self.violation(.missingTask, taskID, "work task does not exist"))
        }
        if status == .ready {
            switch readiness(of: taskID) {
            case .success(.ready):
                break
            case .success(.waitingFor):
                return .failure(Self.violation(
                    .dependenciesUnsatisfied, taskID,
                    "work task dependencies are not completed"))
            case .success(.blockedBy):
                return .failure(Self.violation(
                    .terminalDependency, taskID,
                    "work task has a failed or cancelled dependency"))
            case .failure(let violation):
                return .failure(violation)
            }
        }
        proposed.status = status
        if let progressNote { proposed.progressNote = progressNote }
        if let result { proposed.result = result }
        if let evidence { proposed.evidence = evidence }
        return update(
            proposed,
            expectedRevision: expectedRevision,
            isRetry: isRetry,
            updatedAt: updatedAt)
    }

    @discardableResult
    public mutating func updateDependencies(taskID: WorkTaskID,
                                            dependsOn: [WorkTaskID],
                                            expectedRevision: Int,
                                            updatedAt: Date = Date()) -> Result<WorkTask, WorkTaskGraphViolation> {
        guard var proposed = tasks[taskID] else {
            return .failure(Self.violation(.missingTask, taskID, "work task does not exist"))
        }
        proposed.dependsOn = dependsOn
        return update(
            proposed,
            expectedRevision: expectedRevision,
            recomputeReadinessAfterDependencyChange: true,
            updatedAt: updatedAt)
    }

    @discardableResult
    public mutating func linkInvocation(taskID: WorkTaskID,
                                        invocationID: TaskID,
                                        expectedRevision: Int,
                                        updatedAt: Date = Date()) -> Result<WorkTask, WorkTaskGraphViolation> {
        guard var proposed = tasks[taskID] else {
            return .failure(Self.violation(.missingTask, taskID, "work task does not exist"))
        }
        if !proposed.latestInvocationIDs.contains(invocationID) {
            proposed.latestInvocationIDs.append(invocationID)
        }
        return update(proposed, expectedRevision: expectedRevision, updatedAt: updatedAt)
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func violation(_ kind: WorkTaskGraphViolation.Kind,
                                  _ taskID: WorkTaskID?,
                                  _ message: String) -> WorkTaskGraphViolation {
        WorkTaskGraphViolation(kind: kind, message: message, taskID: taskID)
    }
}
