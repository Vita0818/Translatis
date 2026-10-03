import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools

private struct RunCloseArguments: Decodable {
    let reason: String
}

private func runCloseIntent(
    _ args: ToolArgs,
    outcome: ContinuationRunCloseOutcome
) -> PermissionIntent {
    let value = try? args.decode(RunCloseArguments.self)
    return PermissionIntent(
        action: "run.close.\(outcome.rawValue)",
        resources: [PermissionResource(kind: .task, value: "current_run")],
        metadata: [
            "outcome": .string(outcome.rawValue),
            "reasonLength": .number(Double(value?.reason.count ?? 0)),
        ],
        dataEffects: [.none],
        controlEffects: [.closeRun],
        risks: [.controlPlaneMutation],
        replayPolicy: .doNotReplay)
}

private func executeRunClose(
    _ args: ToolArgs,
    outcome: ContinuationRunCloseOutcome,
    context: ToolContext
) async throws -> ToolObservation {
    let value = try args.decode(RunCloseArguments.self)
    let reason = value.reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reason.isEmpty else {
        throw IntatisError.decoding("run close reason must not be empty")
    }
    guard let controller = context.runController else {
        throw IntatisError.io("run control is not available in this invocation")
    }
    let result = await controller.requestClose(outcome: outcome, reason: reason)
    if result.hasPrefix("error:") {
        throw IntatisError.io(String(result.dropFirst("error:".count)).trimmingCharacters(in: .whitespaces))
    }
    return ToolObservation(text: result)
}

public struct FinishRunTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "finish_run",
        description: "Declare the exact current Cowork run complete after the requested outcome is verified. \(IntatisHostApplication.identity.name) durably closes admission and drains remaining run-scoped work. The host binds all identifiers; supply only a concise reason.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "reason": .object([
                    "type": .string("string"),
                    "minLength": .number(1),
                    "maxLength": .number(1_000),
                ]),
            ]),
            "required": .array([.string("reason")]),
            "additionalProperties": .bool(false),
        ]))

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        runCloseIntent(args, outcome: .completed)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        try await executeRunClose(args, outcome: .completed, context: context)
    }
}

public struct StopRunTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "stop_run",
        description: "Stop the exact current Cowork run when no further useful progress is possible or a genuine blocker remains. \(IntatisHostApplication.identity.name) durably closes admission and drains remaining run-scoped work. The host binds all identifiers; supply only a concise reason.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "reason": .object([
                    "type": .string("string"),
                    "minLength": .number(1),
                    "maxLength": .number(1_000),
                ]),
            ]),
            "required": .array([.string("reason")]),
            "additionalProperties": .bool(false),
        ]))

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        runCloseIntent(args, outcome: .stopped)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        try await executeRunClose(args, outcome: .stopped, context: context)
    }
}
