import Foundation
import IntatisCore
import IntatisProtocol

// MARK: - WorkTask control-plane seam

/// Tool-facing evidence input. `recordedAt` is host-owned so a model cannot
/// forge when evidence entered the durable WorkTask projection.
public struct WorkTaskEvidenceInput: Codable, Equatable, Sendable {
    public var kind: String
    public var reference: String
    public var summary: String

    public init(kind: String, reference: String, summary: String) {
        self.kind = kind
        self.reference = reference
        self.summary = summary
    }

    public func materialize(recordedAt: Date = Date()) -> TaskEvidence {
        TaskEvidence(
            kind: kind,
            reference: reference,
            summary: summary,
            recordedAt: recordedAt)
    }
}

public struct WorkTaskCreateRequest: Equatable, Sendable {
    public var title: String
    public var description: String
    public var acceptanceCriteria: [String]
    public var expectedArtifacts: [String]
    public var dependsOn: [WorkTaskID]
    public var priority: WorkTaskPriority

    public init(title: String,
                description: String,
                acceptanceCriteria: [String] = [],
                expectedArtifacts: [String] = [],
                dependsOn: [WorkTaskID] = [],
                priority: WorkTaskPriority = .normal) {
        self.title = title
        self.description = description
        self.acceptanceCriteria = acceptanceCriteria
        self.expectedArtifacts = expectedArtifacts
        self.dependsOn = dependsOn
        self.priority = priority
    }
}

public struct WorkTaskUpdateRequest: Equatable, Sendable {
    public var taskID: WorkTaskID
    public var expectedRevision: Int
    public var title: String?
    public var description: String?
    public var acceptanceCriteria: [String]?
    public var expectedArtifacts: [String]?
    public var dependsOn: [WorkTaskID]?
    public var priority: WorkTaskPriority?
    public var progressNote: String?
    public var status: WorkTaskStatus?
    public var result: String?
    public var evidence: [WorkTaskEvidenceInput]?
    public var isRetry: Bool

    public init(taskID: WorkTaskID,
                expectedRevision: Int,
                title: String? = nil,
                description: String? = nil,
                acceptanceCriteria: [String]? = nil,
                expectedArtifacts: [String]? = nil,
                dependsOn: [WorkTaskID]? = nil,
                priority: WorkTaskPriority? = nil,
                progressNote: String? = nil,
                status: WorkTaskStatus? = nil,
                result: String? = nil,
                evidence: [WorkTaskEvidenceInput]? = nil,
                isRetry: Bool = false) {
        self.taskID = taskID
        self.expectedRevision = expectedRevision
        self.title = title
        self.description = description
        self.acceptanceCriteria = acceptanceCriteria
        self.expectedArtifacts = expectedArtifacts
        self.dependsOn = dependsOn
        self.priority = priority
        self.progressNote = progressNote
        self.status = status
        self.result = result
        self.evidence = evidence
        self.isRetry = isRetry
    }
}

public struct WorkTaskListRequest: Equatable, Sendable {
    public var statuses: Set<WorkTaskStatus>

    public init(statuses: Set<WorkTaskStatus> = []) {
        self.statuses = statuses
    }
}

public struct WorkTaskDependencyView: Codable, Equatable, Sendable {
    public var taskID: WorkTaskID
    public var status: WorkTaskStatus

    public init(taskID: WorkTaskID, status: WorkTaskStatus) {
        self.taskID = taskID
        self.status = status
    }
}

public struct WorkTaskCandidateResultView: Codable, Equatable, Sendable {
    public var invocationTaskID: TaskID
    public var result: String
    public var receivedAt: Date

    public init(invocationTaskID: TaskID,
                result: String,
                receivedAt: Date = Date()) {
        self.invocationTaskID = invocationTaskID
        self.result = result
        self.receivedAt = receivedAt
    }
}

/// Stable model-visible projection returned by task_get/list. The durable
/// WorkTask remains authoritative; invocation output is reported separately as
/// a candidate and never changes `task.status` by itself.
public struct WorkTaskDetail: Codable, Equatable, Sendable {
    public var task: WorkTask
    public var dependencies: [WorkTaskDependencyView]
    public var downstreamTaskIDs: [WorkTaskID]
    public var candidateResults: [WorkTaskCandidateResultView]

    public init(task: WorkTask,
                dependencies: [WorkTaskDependencyView] = [],
                downstreamTaskIDs: [WorkTaskID] = [],
                candidateResults: [WorkTaskCandidateResultView] = []) {
        self.task = task
        self.dependencies = dependencies
        self.downstreamTaskIDs = downstreamTaskIDs
        self.candidateResults = candidateResults
    }
}

/// A narrow dependency-inversion seam. IntatisTools defines the model-facing
/// calls, while Cowork owns authority checks, DAG mutation, EventLog writes,
/// and projection/recovery state.
public protocol WorkTaskManager: Sendable {
    func createWorkTask(_ request: WorkTaskCreateRequest) async throws -> WorkTaskDetail
    func updateWorkTask(_ request: WorkTaskUpdateRequest) async throws -> WorkTaskDetail
    func getWorkTask(_ taskID: WorkTaskID) async throws -> WorkTaskDetail
    func listWorkTasks(_ request: WorkTaskListRequest) async throws -> [WorkTaskDetail]
}

// MARK: - Goal control-plane seam

public struct GoalCreateRequest: Equatable, Sendable {
    public var objective: String
    public var successCriteria: [String]
    public var constraints: [String]
    public var tokenBudget: Int?

    public init(objective: String,
                successCriteria: [String] = [],
                constraints: [String] = [],
                tokenBudget: Int? = nil) {
        self.objective = objective
        self.successCriteria = successCriteria
        self.constraints = constraints
        self.tokenBudget = tokenBudget
    }
}

public struct GoalEditRequest: Equatable, Sendable {
    public var goalID: GoalID
    public var expectedRevision: Int
    public var objective: String
    public var successCriteria: [String]
    public var constraints: [String]
    public var tokenBudget: Int?

    public init(goalID: GoalID,
                expectedRevision: Int,
                objective: String,
                successCriteria: [String],
                constraints: [String],
                tokenBudget: Int? = nil) {
        self.goalID = goalID
        self.expectedRevision = expectedRevision
        self.objective = objective
        self.successCriteria = successCriteria
        self.constraints = constraints
        self.tokenBudget = tokenBudget
    }
}

public protocol GoalManager: Sendable {
    func currentGoal() async throws -> Goal?
    func editGoal(_ request: GoalEditRequest) async throws -> Goal
    func transitionGoal(_ goalID: GoalID,
                        expectedRevision: Int,
                        to status: GoalStatus) async throws -> Goal
    func clearGoal(_ goalID: GoalID, expectedRevision: Int) async throws
}
