import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools

public struct SendMessageTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "send_message",
        description: "Send a message to another attached agent without creating a task.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "to": .object(["type": .string("string"), "description": .string("target agent name")]),
                "content": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("to"), .string("content")]),
            "additionalProperties": .bool(false),
        ])
    )

    struct Args: Decodable { let to: String; let content: String }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        return PermissionIntent(
            action: "agent.message",
            resources: [PermissionResource(kind: .agent, value: value?.to ?? "unknown")],
            metadata: ["contentLength": .number(Double(value?.content.count ?? 0))],
            dataEffects: [.none],
            controlEffects: [.message],
            risks: [.controlPlaneMutation],
            replayPolicy: .doNotReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let messenger = context.messenger else {
            throw IntatisError.io("agent messaging is not available in this session")
        }
        return try Self.checked(
            await messenger.sendMessage(to: a.to, content: a.content),
            successPrefix: "sent message to @")
    }
}

public struct RequestInformationTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "request_information",
        description: "Ask another attached agent for information without creating a delegated task.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "to": .object(["type": .string("string"), "description": .string("target agent name")]),
                "question": .object(["type": .string("string")]),
                "based_on": .object([
                    "type": .string("string"),
                    "description": .string("required reply Message ID when this is an explicit follow-up from a mailbox receipt"),
                ]),
            ]),
            "required": .array([.string("to"), .string("question")]),
            "additionalProperties": .bool(false),
        ])
    )

    struct Args: Decodable {
        let to: String
        let question: String
        let basedOn: String?

        enum CodingKeys: String, CodingKey {
            case to, question
            case basedOn = "based_on"
        }
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        return PermissionIntent(
            action: "information.request",
            resources: [PermissionResource(kind: .agent, value: value?.to ?? "unknown")],
            metadata: [
                "questionLength": .number(Double(value?.question.count ?? 0)),
                "basedOn": value?.basedOn.map(JSONValue.string) ?? .null,
            ],
            dataEffects: [.none],
            controlEffects: [.message],
            risks: [.controlPlaneMutation],
            replayPolicy: .doNotReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let messenger = context.messenger else {
            throw IntatisError.io("agent messaging is not available in this session")
        }
        return try Self.checked(
            await messenger.requestInformation(
                to: a.to,
                question: a.question,
                basedOn: a.basedOn),
            successPrefix: "requested information from @")
    }
}

public struct ReplyMessageTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "reply_message",
        description: "Answer one exact frozen information request without creating a task. This closes only that request correlation; it is not an acknowledgment tool.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "to": .object(["type": .string("string"), "description": .string("target agent name")]),
                "content": .object(["type": .string("string")]),
                "inReplyTo": .object(["type": .string("string"), "description": .string("exact information request Message ID")]),
            ]),
            "required": .array([.string("to"), .string("content"), .string("inReplyTo")]),
            "additionalProperties": .bool(false),
        ])
    )

    struct Args: Decodable { let to: String; let content: String; let inReplyTo: String }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        var metadata: [String: JSONValue] = [
            "contentLength": .number(Double(value?.content.count ?? 0)),
        ]
        if let replyID = value?.inReplyTo { metadata["inReplyTo"] = .string(replyID) }
        return PermissionIntent(
            action: "information.reply",
            resources: [PermissionResource(kind: .agent, value: value?.to ?? "unknown")],
            metadata: metadata,
            dataEffects: [.none],
            controlEffects: [.message],
            risks: [.controlPlaneMutation],
            replayPolicy: .doNotReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let messenger = context.messenger else {
            throw IntatisError.io("agent messaging is not available in this session")
        }
        return try Self.checked(await messenger.replyMessage(
            to: a.to,
            content: a.content,
            inReplyTo: a.inReplyTo),
            successPrefix: "replied to @")
    }
}

/// Optional, explicitly reviewed Knowledge authority attached to one delegated
/// task. Omission is the default and grants no Knowledge tools. The value is
/// intentionally task-scoped rather than a mutation of the worker's durable
/// default lease.
enum DelegatedKnowledgeAccess: String, Codable, Sendable {
    case search
    case build
    case buildAndSearch = "build_and_search"

    var capabilities: Set<ToolCapability> {
        switch self {
        case .search:
            return [.searchKnowledge]
        case .build:
            return [.buildKnowledge]
        case .buildAndSearch:
            return [.buildKnowledge, .searchKnowledge]
        }
    }

    var workspaceAccess: WorkspaceAccess {
        capabilities.contains(.buildKnowledge) ? .readWrite : .readOnly
    }
}

public struct DelegateTaskTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "delegate_task",
        description: "Run one ready durable WorkTask by ID. The WorkTask remains the source of truth, "
            + "and the invocation report is only a candidate result until task_update explicitly settles it. "
            + "Unscoped calls may provide objective instead. 'to' must name an attached agent; if omitted or 'auto', \(IntatisHostApplication.identity.name) selects an available attached worker. "
            + "Create an agent in an earlier tool-call round when no suitable worker exists. knowledge_access may explicitly grant only this task search, build, or build_and_search Knowledge tools. Returns invocation task_id, agent_id, and the mediated Task Report.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "to": .object(["type": .string("string"), "description": .string("target agent name")]),
                "work_task_id": .object(["type": .string("string"), "description": .string("ready durable WorkTask ID")]),
                "objective": .object(["type": .string("string"), "description": .string("unscoped invocation objective")]),
                "role_hint": .object(["type": .string("string")]),
                "expected_deliverable": .object(["type": .string("string")]),
                "knowledge_access": .object([
                    "type": .string("string"),
                    "enum": .array([
                        .string("search"),
                        .string("build"),
                        .string("build_and_search"),
                    ]),
                    "description": .string("optional task-scoped Knowledge capability grant"),
                ]),
            ]),
            "required": .array([]),
            "additionalProperties": .bool(false),
        ])
    )

    struct Args: Decodable {
        let to: String?
        let workTaskID: WorkTaskID?
        let objective: String?
        let roleHint: String?
        let expectedDeliverable: String?
        let knowledgeAccess: DelegatedKnowledgeAccess?

        enum CodingKeys: String, CodingKey {
            case to
            case workTaskID = "work_task_id"
            case objective
            case roleHint = "role_hint"
            case expectedDeliverable = "expected_deliverable"
            case knowledgeAccess = "knowledge_access"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            to = try container.decodeIfPresent(String.self, forKey: .to)
            workTaskID = try container.decodeIfPresent(WorkTaskID.self, forKey: .workTaskID)
            objective = try container.decodeIfPresent(String.self, forKey: .objective)
            roleHint = try container.decodeIfPresent(String.self, forKey: .roleHint)
            expectedDeliverable = try container.decodeIfPresent(String.self, forKey: .expectedDeliverable)
            knowledgeAccess = try container.decodeIfPresent(
                DelegatedKnowledgeAccess.self,
                forKey: .knowledgeAccess)
        }
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        var resources = [
            PermissionResource(kind: .agent, value: value?.to ?? "auto"),
            PermissionResource(kind: .task, value: value?.workTaskID?.rawValue ?? "new"),
            PermissionResource(
                kind: .workspace,
                value: workspaceRoot.standardizedFileURL.path,
                access: value?.knowledgeAccess?.workspaceAccess ?? .readOnly),
        ]
        if let knowledgeAccess = value?.knowledgeAccess {
            resources.append(PermissionResource(
                kind: .tool,
                value: "delegated_knowledge:\(knowledgeAccess.rawValue)",
                access: knowledgeAccess.workspaceAccess))
        }
        return PermissionIntent(
            action: "task.delegate",
            resources: resources,
            metadata: [
                "objectiveLength": .number(Double(value?.objective?.count ?? 0)),
                "roleHint": value?.roleHint.map(JSONValue.string) ?? .null,
                "knowledgeAccess": value?.knowledgeAccess
                    .map { .string($0.rawValue) } ?? .null,
            ],
            dataEffects: [.none],
            controlEffects: [.delegateTask, .grantCapability],
            risks: [.controlPlaneMutation, .capabilityGrant, .modelCost],
            replayPolicy: .doNotReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let messenger = context.messenger else {
            throw IntatisError.io("agent delegation is not available in this session")
        }
        guard a.workTaskID != nil
                || !(a.objective?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
            throw IntatisError.decoding("delegate_task requires work_task_id or an unscoped objective")
        }
        guard let authorization = context.authorization,
              authorization.toolName == Self.descriptor.name,
              let concreteTarget = authorization.intent.resources.first(where: {
                  $0.kind == .agent
              })?.value,
              !concreteTarget.isEmpty,
              concreteTarget.lowercased() != "auto" else {
            throw IntatisError.permissionDenied(
                "delegate_task requires a concrete host-resolved target authorization")
        }
        guard let executionID = context.executionID,
              !executionID.isEmpty else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "delegation_execution_id_missing",
                message: "delegate_task was rejected before admission because its durable execution identity is unavailable")
        }
        return try Self.checked(try await messenger.delegateTask(
            authorization: authorization,
            executionID: executionID,
            to: concreteTarget,
            workTaskID: a.workTaskID,
            objective: a.objective,
            roleHint: a.roleHint,
            expectedDeliverable: a.expectedDeliverable),
            successPrefix: "task_id=")
    }
}

private extension Tool {
    static func checked(_ result: String, successPrefix: String) throws -> ToolObservation {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(successPrefix) else {
            let message = trimmed.lowercased().hasPrefix("error:")
                ? String(trimmed.dropFirst("error:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                : trimmed
            throw IntatisError.io(message.isEmpty ? "tool operation did not complete" : message)
        }
        return ToolObservation(text: trimmed)
    }
}
