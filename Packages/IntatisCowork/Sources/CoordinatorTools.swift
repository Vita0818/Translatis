import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools

/// Coordinator tools (ARCHITECTURE.md §7). They let an explicit lead agent build
/// and steer a small team of worker agents. Their structured PermissionIntent
/// separates control-plane admission from later workspace file operations.

/// Create + attach a new sub-agent bound to a folder.
public struct SpawnAgentTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "spawn_agent",
        description: "Create a new sub-agent bound to a folder so you can delegate work to it. "
            + "Give it a short name and an absolute folder path. Omit inference_profile_id to inherit "
            + "your exact profile revision; this is the recommended default. Choose an ID from "
            + "list_inference_profiles only when its host label/model/variant clearly fits the delegated work. "
            + "Set canCoordinate only when this sub-agent must manage lower-level agents. "
            + "New agents are read-only unless requestedAccess is explicitly read_write. "
            + "After spawning, assign work with delegate_task; the orchestrator recycles task-scoped agents when idle.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string"),
                                 "description": .string("short agent name, e.g. reviewer")]),
                "path": .object(["type": .string("string"),
                                 "description": .string("absolute path to the agent's workspace folder")]),
                "inference_profile_id": .object([
                    "type": .string("string"),
                    "description": .string("optional host-approved inference profile ID; recommended default is omission, which inherits your exact revision"),
                ]),
                "requestedAccess": .object([
                    "type": .string("string"),
                    "enum": .array([.string("read_only"), .string("read_write")]),
                    "description": .string("optional workspace ceiling; defaults to read_only"),
                ]),
                "canCoordinate": .object(["type": .string("boolean"),
                                           "description": .string("optional; true grants coordinator tools to this sub-agent")]),
            ]),
            "required": .array([.string("name"), .string("path")]),
            "additionalProperties": .bool(false),
        ])
    )

    struct Args: Decodable {
        let name: String
        let path: String
        let inferenceProfileID: String?
        let requestedAccess: WorkspaceAccess?
        let canCoordinate: Bool?

        private enum CodingKeys: String, CodingKey {
            case name, path, requestedAccess, canCoordinate
            case inferenceProfileID = "inference_profile_id"
        }
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        // The target is a workspace admission resource, not a file path that
        // this invocation reads or writes. The orchestrator separately
        // canonicalizes and assesses it before committing the admission.
        []
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        guard let value = try? args.decode(Args.self) else {
            return .derived(
                toolName: Self.descriptor.name,
                sideEffect: Self.descriptor.sideEffect,
                touchedPaths: [],
                risksNetwork: false)
        }
        let requestedAccess = value.requestedAccess ?? .readOnly
        let targetURL = URL(fileURLWithPath: (value.path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let targetIdentity = WorkspaceRootIdentity.capture(rootPath: targetURL.path)
        var risks: Set<PermissionRisk> = [.controlPlaneMutation, .capabilityGrant, .modelCost]
        if !PathConfinement.isWithin(targetURL.path, root: workspaceRoot) {
            risks.insert(.workspaceExpansion)
        }
        if requestedAccess == .readWrite {
            risks.insert(.workspaceMutation)
        }
        return PermissionIntent(
            action: "agent.spawn",
            resources: [
                PermissionResource(kind: .agent, value: value.name),
                PermissionResource(kind: .workspace, value: targetURL.path, access: requestedAccess),
            ],
            metadata: [
                // The Orchestrator replaces the optional catalog ID with an
                // exact host-approved binding after schema and catalog checks.
                "inferenceProfileSelectionRequested": .bool(
                    value.inferenceProfileID?.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty == false),
                "requestedAccess": .string(requestedAccess.rawValue),
                "canCoordinate": .bool(value.canCoordinate ?? false),
                "targetCanonicalPath": .string(targetURL.path),
                "targetDeviceID": targetIdentity.map {
                    .string(String($0.deviceID))
                } ?? .null,
                "targetFileID": targetIdentity.map {
                    .string(String($0.fileID))
                } ?? .null,
            ],
            dataEffects: [.none],
            controlEffects: [.createAgent, .attachWorkspace, .grantCapability],
            risks: risks,
            replayPolicy: .doNotReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let manager = context.agentManager else {
            throw IntatisError.io("agent management is not available in this session")
        }
        let result = await manager.spawnAgent(
            authorization: context.authorization,
            name: a.name,
            path: a.path,
            inferenceProfileID: a.inferenceProfileID,
            requestedAccess: a.requestedAccess ?? .readOnly,
            canCoordinate: a.canCoordinate ?? false)
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("spawned @") else {
            let message = trimmed.lowercased().hasPrefix("error:")
                ? String(trimmed.dropFirst("error:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                : trimmed
            throw IntatisError.io(message.isEmpty ? "agent spawn did not complete" : message)
        }
        return ToolObservation(text: trimmed)
    }
}

/// List the agents active in this conversation.
public struct ListAgentsTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "list_agents",
        description: "List active agents with name, model, coordinator/worker lease role, compact task state, and folder.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    )

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        PermissionIntent(
            action: "agent.list",
            resources: [PermissionResource(kind: .agent, value: "thread")],
            dataEffects: [.read],
            replayPolicy: .safeToReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        guard let manager = context.agentManager else {
            return ToolObservation(text: "agent management is not available in this session")
        }
        return ToolObservation(text: await manager.listAgents())
    }
}

/// Lists only host-approved, secret-free profile identities. It never exposes
/// endpoint URLs, credential references, headers, or raw request options.
public struct ListInferenceProfilesTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "list_inference_profiles",
        description: "List host-approved inference profile IDs, safe labels, models, variants, and configuration-declared capabilities for a new child agent. Capabilities are authoritative routing requirements when present; never infer a missing capability from a model name. Recommended default: omit inference_profile_id in spawn_agent to inherit your exact revision; choose another profile only when the listed facts clearly fit the delegated work.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ]))

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        PermissionIntent(
            action: "inference.profile.list",
            resources: [PermissionResource(kind: .agent, value: "host-approved-profiles")],
            dataEffects: [.read],
            replayPolicy: .safeToReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        guard let manager = context.agentManager else {
            return ToolObservation(text: "agent management is not available in this session")
        }
        return ToolObservation(text: await manager.listInferenceProfiles())
    }
}

/// Detach a sub-agent you no longer need.
public struct RemoveAgentTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "remove_agent",
        description: "Remove a sub-agent early. Completed task-scoped sub-agents are recycled automatically. You cannot remove @main.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string"),
                                 "description": .string("the agent name to remove")]),
            ]),
            "required": .array([.string("name")]),
            "additionalProperties": .bool(false),
        ])
    )

    struct Args: Decodable { let name: String }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let name = (try? args.decode(Args.self))?.name ?? "unknown"
        return PermissionIntent(
            action: "agent.remove",
            resources: [PermissionResource(kind: .agent, value: name)],
            dataEffects: [.none],
            controlEffects: [.removeAgent],
            risks: [.controlPlaneMutation],
            replayPolicy: .doNotReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let manager = context.agentManager else {
            return ToolObservation(text: "agent management is not available in this session")
        }
        let result = await manager.removeAgent(name: a.name)
        if result.lowercased().hasPrefix("error:") {
            throw IntatisError.io(String(result.dropFirst("error:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ToolObservation(text: result)
    }
}
