import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools

/// Links a durable WorkTask card to an already-created native Codex child.
/// It never creates, starts, resumes, messages, or schedules an agent.
public struct TaskLinkAgentTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "task_link_agent",
        description: "Link one durable WorkTask card to an existing native Codex child using the canonical task name returned by a completed spawn_agent or list_agents call. This records product metadata only and never creates or schedules an agent.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "task_id": .object([
                    "type": .string("string"),
                    "minLength": .number(1),
                ]),
                "expected_revision": .object([
                    "type": .string("integer"),
                    "minimum": .number(0),
                ]),
                "agent_task_name": .object([
                    "type": .string("string"),
                    "minLength": .number(1),
                    "description": .string(
                        "Exact canonical task name from a successful native Codex agent result; never a planned name or thread id."),
                ]),
            ]),
            "required": .array([
                .string("task_id"),
                .string("expected_revision"),
                .string("agent_task_name"),
            ]),
            "additionalProperties": .bool(false),
        ]))

    private struct Args: Decodable {
        let taskID: String
        let expectedRevision: Int
        let agentTaskName: String

        enum CodingKeys: String, CodingKey {
            case taskID = "task_id"
            case expectedRevision = "expected_revision"
            case agentTaskName = "agent_task_name"
        }
    }

    public func permissionIntent(
        _ args: ToolArgs,
        workspaceRoot: URL
    ) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        return PermissionIntent(
            action: "task.link_agent",
            resources: [PermissionResource(
                kind: .task,
                value: value?.taskID ?? "unknown")],
            metadata: [
                "expectedRevision": .number(
                    Double(value?.expectedRevision ?? -1)),
                "agentTaskName": value.map {
                    .string(String($0.agentTaskName.prefix(256)))
                } ?? .null,
            ],
            dataEffects: [.none],
            controlEffects: [.updateTask],
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
                "task_id": value.taskID,
                "expected_revision": String(value.expectedRevision),
                "agent_task_name": value.agentTaskName,
            ])
    }

    public func execute(
        _ args: ToolArgs,
        in context: ToolContext
    ) async throws -> ToolObservation {
        let value = try args.decode(Args.self)
        guard let manager = context.workTaskManager
                as? any CodexWorkTaskAgentLinking else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "codex_work_task_link_unavailable",
                message: "task_link_agent rejected before mutation because this invocation has no host-bound Codex WorkTask linker")
        }
        let detail = try await manager.linkWorkTask(
            taskID: WorkTaskID(rawValue: value.taskID),
            expectedRevision: value.expectedRevision,
            agentTaskName: value.agentTaskName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return ToolObservation(text: String(
            decoding: try encoder.encode(detail),
            as: UTF8.self))
    }
}
