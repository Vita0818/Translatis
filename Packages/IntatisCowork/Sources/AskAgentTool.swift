import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools

/// The only way one agent can reach another. It carries a question (a summary,
/// not raw files) through the injected `AgentMessenger`, which routes via the
/// mediated Message Bus. It creates and executes a durable task, so it is a
/// write operation even though it does not directly mutate workspace files.
public struct AskAgentTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "ask_agent",
        description: "Ask another attached agent a question. Provide a concise summary or interface "
            + "question, never raw file contents. Returns their answer.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "to": .object(["type": .string("string"), "description": .string("target agent name")]),
                "question": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("to"), .string("question")]),
            "additionalProperties": .bool(false),
        ])
    )

    struct Args: Decodable { let to: String; let question: String }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        return PermissionIntent(
            action: "task.ask",
            resources: [
                PermissionResource(kind: .agent, value: value?.to ?? "unknown"),
                PermissionResource(kind: .task, value: "new"),
            ],
            metadata: ["questionLength": .number(Double(value?.question.count ?? 0))],
            dataEffects: [.none],
            controlEffects: [.createTask, .message],
            risks: [.controlPlaneMutation, .modelCost],
            replayPolicy: .doNotReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let messenger = context.messenger else {
            throw IntatisError.io("agent messaging is not available in this session")
        }
        switch await messenger.ask(to: a.to, question: a.question) {
        case .success(let answer):
            return ToolObservation(text: answer)
        case .failure(let failure):
            let normalized = failure.lowercased().hasPrefix("error:")
                ? String(failure.dropFirst("error:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                : failure.trimmingCharacters(in: .whitespacesAndNewlines)
            throw IntatisError.io(normalized.isEmpty
                ? "agent request did not complete"
                : normalized)
        }
    }
}
