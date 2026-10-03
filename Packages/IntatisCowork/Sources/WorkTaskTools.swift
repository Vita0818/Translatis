import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools

private let workTaskStringSchema: JSONValue = .object([
    "type": .string("string"),
    "minLength": .number(1),
])

private let workTaskStringArraySchema: JSONValue = .object([
    "type": .string("array"),
    "items": workTaskStringSchema,
])

private let workTaskEvidenceArraySchema: JSONValue = .object([
    "type": .string("array"),
    "items": .object([
        "type": .string("object"),
        "properties": .object([
            "kind": workTaskStringSchema,
            "reference": workTaskStringSchema,
            "summary": workTaskStringSchema,
        ]),
        "required": .array([.string("kind"), .string("reference"), .string("summary")]),
        "additionalProperties": .bool(false),
    ]),
])

private func encodeWorkTaskToolResult<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func joinedWorkTaskPreviewValues(_ values: [String]?) -> String {
    values?.joined(separator: ", ") ?? ""
}

private func missingWorkTaskManager(_ tool: String) -> ToolExecutionRejectedWithoutSideEffect {
    ToolExecutionRejectedWithoutSideEffect(
        code: "work_task_manager_unavailable",
        message: "\(tool) rejected before WorkTask execution started because this invocation has no host-bound WorkTask manager")
}

private func workTaskNamespaceHint(
    rawID: String,
    underlyingError: Error
) -> Error {
    let isNotFound: Bool
    if let error = underlyingError as? IntatisError,
       case .notFound = error {
        isNotFound = true
    } else if let violation = underlyingError as? WorkTaskGraphViolation,
              violation.kind == .missingTask {
        isNotFound = true
    } else {
        isNotFound = false
    }
    guard isNotFound,
          rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().hasPrefix("task_") else {
        return underlyingError
    }
    return ToolExecutionRejectedWithoutSideEffect(
        code: "work_task_id_required",
        message: "\(rawID) is an AgentInvocation TaskID, not a WorkTask ID. Use task_get or task_list to obtain the durable WorkTask ID (normally wt_…), then retry with its latest authoritative revision.")
}

public struct TaskCreateTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "task_create",
        description: "Create one durable WorkTask in the current Cowork Session. Returns the stable task_id, host-computed status, and revision. Use concise acceptance criteria and existing Session WorkTask dependencies; this is a control-plane change, not a workspace write.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "title": workTaskStringSchema,
                "description": workTaskStringSchema,
                "acceptance_criteria": workTaskStringArraySchema,
                "expected_artifacts": workTaskStringArraySchema,
                "depends_on": .object([
                    "type": .string("array"),
                    "items": workTaskStringSchema,
                    "description": .string("Existing durable WorkTask IDs confirmed by earlier successful task_create, task_get, or task_list results. Never reference a WorkTask that is only planned or created by another call in the same assistant response."),
                ]),
                "priority": .object([
                    "type": .string("string"),
                    "enum": .array(WorkTaskPriority.allCases.map { .string($0.rawValue) }),
                ]),
            ]),
            "required": .array([.string("title"), .string("description")]),
            "additionalProperties": .bool(false),
        ]))

    private struct Args: Decodable {
        var title: String
        var description: String
        var acceptanceCriteria: [String]?
        var expectedArtifacts: [String]?
        var dependsOn: [String]?
        var priority: WorkTaskPriority?

        enum CodingKeys: String, CodingKey {
            case title, description, priority
            case acceptanceCriteria = "acceptance_criteria"
            case expectedArtifacts = "expected_artifacts"
            case dependsOn = "depends_on"
        }
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        return PermissionIntent(
            action: "task.create",
            resources: [PermissionResource(kind: .task, value: "current-session")],
            metadata: [
                "title": value.map { .string(String($0.title.prefix(160))) } ?? .null,
                "dependencyCount": .number(Double(value?.dependsOn?.count ?? 0)),
            ],
            dataEffects: [.none],
            controlEffects: [.createTask],
            risks: [.controlPlaneMutation],
            replayPolicy: .doNotReplay)
    }

    public func permissionActionPreview(
        _ args: ToolArgs
    ) -> PermissionActionPreview? {
        guard let value = try? args.decode(Args.self) else { return nil }
        return PermissionActionPreview(
            kind: Self.descriptor.name,
            fields: [
                "title": value.title,
                "description": value.description,
                "acceptance_criteria": joinedWorkTaskPreviewValues(value.acceptanceCriteria),
                "expected_artifacts": joinedWorkTaskPreviewValues(value.expectedArtifacts),
                "depends_on": joinedWorkTaskPreviewValues(value.dependsOn),
                "priority": (value.priority ?? .normal).rawValue,
            ])
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try args.decode(Args.self)
        guard let manager = context.workTaskManager else {
            throw missingWorkTaskManager(Self.descriptor.name)
        }
        let request = WorkTaskCreateRequest(
            title: value.title,
            description: value.description,
            acceptanceCriteria: value.acceptanceCriteria ?? [],
            expectedArtifacts: value.expectedArtifacts ?? [],
            dependsOn: (value.dependsOn ?? []).map { WorkTaskID(rawValue: $0) },
            priority: value.priority ?? .normal)
        return ToolObservation(text: try encodeWorkTaskToolResult(
            await manager.createWorkTask(request)))
    }
}

public struct TaskUpdateTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "task_update",
        description: "Patch a durable WorkTask (normally wt_…), never an AgentInvocation TaskID (task_…). Use task_get/task_list to obtain the WorkTask ID and its latest authoritative revision before updating. expected_revision is required; send only fields that must change and omit repeated contract fields. Workers may update progress/status/result/evidence only on the WorkTask bound to their current invocation and cannot change its contract. Do not redundantly settle an already-terminal WorkTask. Only an explicit completed update with a non-empty result, and evidence when acceptance criteria exist, settles a WorkTask. AgentInvocation completion alone never does.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "task_id": .object([
                    "type": .string("string"),
                    "minLength": .number(1),
                    "description": .string("Durable WorkTask ID, normally wt_…. Do not pass an AgentInvocation task_… ID."),
                ]),
                "expected_revision": .object([
                    "type": .string("integer"),
                    "minimum": .number(0),
                ]),
                "title": workTaskStringSchema,
                "description": workTaskStringSchema,
                "acceptance_criteria": workTaskStringArraySchema,
                "expected_artifacts": workTaskStringArraySchema,
                "depends_on": workTaskStringArraySchema,
                "priority": .object([
                    "type": .string("string"),
                    "enum": .array(WorkTaskPriority.allCases.map { .string($0.rawValue) }),
                ]),
                "progress_note": .object(["type": .string("string")]),
                "status": .object([
                    "type": .string("string"),
                    "enum": .array([
                        .string(WorkTaskStatus.inProgress.rawValue),
                        .string(WorkTaskStatus.blocked.rawValue),
                        .string(WorkTaskStatus.completed.rawValue),
                        .string(WorkTaskStatus.failed.rawValue),
                        .string(WorkTaskStatus.cancelled.rawValue),
                        .string(WorkTaskStatus.ready.rawValue),
                    ]),
                ]),
                "result": .object(["type": .string("string")]),
                "evidence": workTaskEvidenceArraySchema,
                "retry": .object(["type": .string("boolean")]),
            ]),
            "required": .array([.string("task_id"), .string("expected_revision")]),
            "additionalProperties": .bool(false),
        ]))

    private struct Args: Decodable {
        var taskID: String
        var expectedRevision: Int
        var title: String?
        var description: String?
        var acceptanceCriteria: [String]?
        var expectedArtifacts: [String]?
        var dependsOn: [String]?
        var priority: WorkTaskPriority?
        var progressNote: String?
        var status: WorkTaskStatus?
        var result: String?
        var evidence: [WorkTaskEvidenceInput]?
        var retry: Bool?

        enum CodingKeys: String, CodingKey {
            case title, description, priority, status, result, evidence, retry
            case taskID = "task_id"
            case expectedRevision = "expected_revision"
            case acceptanceCriteria = "acceptance_criteria"
            case expectedArtifacts = "expected_artifacts"
            case dependsOn = "depends_on"
            case progressNote = "progress_note"
        }
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        let cancelling = value?.status == .cancelled
        return PermissionIntent(
            action: cancelling ? "task.cancel" : "task.update",
            resources: [PermissionResource(kind: .task, value: value?.taskID ?? "unknown")],
            metadata: [
                "expectedRevision": .number(Double(value?.expectedRevision ?? -1)),
                "status": value?.status.map { .string($0.rawValue) } ?? .null,
                "retry": .bool(value?.retry ?? false),
            ],
            dataEffects: [.none],
            controlEffects: [cancelling ? .cancelTask : .updateTask],
            risks: [.controlPlaneMutation],
            replayPolicy: .doNotReplay)
    }

    public func permissionActionPreview(
        _ args: ToolArgs
    ) -> PermissionActionPreview? {
        guard let value = try? args.decode(Args.self) else { return nil }
        var changedFields: [String] = []
        if value.title != nil { changedFields.append("title") }
        if value.description != nil { changedFields.append("description") }
        if value.acceptanceCriteria != nil { changedFields.append("acceptance_criteria") }
        if value.expectedArtifacts != nil { changedFields.append("expected_artifacts") }
        if value.dependsOn != nil { changedFields.append("depends_on") }
        if value.priority != nil { changedFields.append("priority") }
        if value.progressNote != nil { changedFields.append("progress_note") }
        if value.status != nil { changedFields.append("status") }
        if value.result != nil { changedFields.append("result") }
        if value.evidence != nil { changedFields.append("evidence") }
        if value.retry != nil { changedFields.append("retry") }
        return PermissionActionPreview(
            kind: Self.descriptor.name,
            fields: [
                "task_id": value.taskID,
                "expected_revision": String(value.expectedRevision),
                "status": value.status?.rawValue ?? "unchanged",
                "changed_fields": changedFields.joined(separator: ", "),
                "progress_note": value.progressNote ?? "",
                "result": value.result ?? "",
                "evidence_count": String(value.evidence?.count ?? 0),
                "retry": String(value.retry ?? false),
            ])
    }

    static func decodeRequest(_ args: ToolArgs) throws -> WorkTaskUpdateRequest {
        let value = try args.decode(Args.self)
        return WorkTaskUpdateRequest(
            taskID: WorkTaskID(rawValue: value.taskID),
            expectedRevision: value.expectedRevision,
            title: value.title,
            description: value.description,
            acceptanceCriteria: value.acceptanceCriteria,
            expectedArtifacts: value.expectedArtifacts,
            dependsOn: value.dependsOn?.map { WorkTaskID(rawValue: $0) },
            priority: value.priority,
            progressNote: value.progressNote,
            status: value.status,
            result: value.result,
            evidence: value.evidence,
            isRetry: value.retry ?? false)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let request = try Self.decodeRequest(args)
        guard let manager = context.workTaskManager else {
            throw missingWorkTaskManager(Self.descriptor.name)
        }
        do {
            let detail = try await manager.updateWorkTask(request)
            return ToolObservation(text: try encodeWorkTaskToolResult(detail))
        } catch {
            throw workTaskNamespaceHint(
                rawID: request.taskID.rawValue,
                underlyingError: error)
        }
    }
}

/// Capability-projected model surface for an ordinary worker. The stable
/// provider-facing name is preserved, while manager-only contract and graph
/// fields are absent from the schema and therefore fail before authorization.
struct BoundWorkTaskUpdateTool: Tool {
    init() {}

    static let descriptor = ToolDescriptor(
        name: "task_update",
        description: "Update only the WorkTask bound to your current AgentInvocation. Use task_get to obtain its latest authoritative revision, then send only progress_note, a permitted status transition, result, or evidence. The host verifies the current invocation binding, revision, and status transition. Contract fields, dependencies, priority, retry, and cancellation are manager-only.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "task_id": .object([
                    "type": .string("string"),
                    "minLength": .number(1),
                    "description": .string("Durable WorkTask ID, normally wt_…. Do not pass an AgentInvocation task_… ID."),
                ]),
                "expected_revision": .object([
                    "type": .string("integer"),
                    "minimum": .number(0),
                ]),
                "progress_note": .object(["type": .string("string")]),
                "status": .object([
                    "type": .string("string"),
                    "enum": .array([
                        .string(WorkTaskStatus.inProgress.rawValue),
                        .string(WorkTaskStatus.blocked.rawValue),
                        .string(WorkTaskStatus.completed.rawValue),
                        .string(WorkTaskStatus.failed.rawValue),
                    ]),
                ]),
                "result": .object(["type": .string("string")]),
                "evidence": workTaskEvidenceArraySchema,
            ]),
            "required": .array([.string("task_id"), .string("expected_revision")]),
            "additionalProperties": .bool(false),
        ]))

    func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        TaskUpdateTool().permissionIntent(args, workspaceRoot: workspaceRoot)
    }

    func permissionActionPreview(
        _ args: ToolArgs
    ) -> PermissionActionPreview? {
        TaskUpdateTool().permissionActionPreview(args)
    }

    func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        try await TaskUpdateTool().execute(args, in: context)
    }
}

public struct TaskGetTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "task_get",
        description: "Read one authoritative durable WorkTask (normally wt_…), including dependency states, downstream tasks, linked AgentInvocations, candidate results, evidence, and revision. Do not pass an AgentInvocation task_… ID.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "task_id": .object([
                    "type": .string("string"),
                    "minLength": .number(1),
                    "description": .string("Durable WorkTask ID, normally wt_…. Do not pass an AgentInvocation task_… ID."),
                ]),
            ]),
            "required": .array([.string("task_id")]),
            "additionalProperties": .bool(false),
        ]))

    private struct Args: Decodable {
        var taskID: String
        enum CodingKeys: String, CodingKey { case taskID = "task_id" }
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        return PermissionIntent(
            action: "task.get",
            resources: [PermissionResource(kind: .task, value: value?.taskID ?? "unknown")],
            dataEffects: [.read],
            replayPolicy: .safeToReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try args.decode(Args.self)
        guard let manager = context.workTaskManager else {
            return ToolObservation(text: "WorkTask management is not available in this session")
        }
        do {
            return ToolObservation(text: try encodeWorkTaskToolResult(
                await manager.getWorkTask(WorkTaskID(rawValue: value.taskID))))
        } catch {
            throw workTaskNamespaceHint(
                rawID: value.taskID,
                underlyingError: error)
        }
    }
}

public struct TaskListTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "task_list",
        description: "List the authoritative WorkTask projection for the current Cowork Session in stable creation order. Use this instead of guessing state from old chat text. status is an optional filter.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "status": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string(WorkTaskStatus.pending.rawValue),
                            .string(WorkTaskStatus.ready.rawValue),
                            .string(WorkTaskStatus.inProgress.rawValue),
                            .string(WorkTaskStatus.blocked.rawValue),
                            .string(WorkTaskStatus.completed.rawValue),
                            .string(WorkTaskStatus.failed.rawValue),
                            .string(WorkTaskStatus.cancelled.rawValue),
                        ]),
                    ]),
                ]),
            ]),
            "required": .array([]),
            "additionalProperties": .bool(false),
        ]))

    private struct Args: Decodable {
        var status: [WorkTaskStatus]?
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        return PermissionIntent(
            action: "task.list",
            resources: [PermissionResource(kind: .task, value: "current-session")],
            dataEffects: [.read],
            replayPolicy: .safeToReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try args.decode(Args.self)
        guard let manager = context.workTaskManager else {
            return ToolObservation(text: "WorkTask management is not available in this session")
        }
        let request = WorkTaskListRequest(
            statuses: Set(value.status ?? []))
        struct Response: Encodable { var tasks: [WorkTaskDetail] }
        return ToolObservation(text: try encodeWorkTaskToolResult(
            Response(tasks: await manager.listWorkTasks(request))))
    }
}
