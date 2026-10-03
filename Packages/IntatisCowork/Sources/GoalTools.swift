import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools

private func encodeGoalToolResult<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

public struct GetGoalTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "get_goal",
        description: "Read the authoritative current durable Goal, including status, revision, explicit budget/usage, elapsed time, and latest audit. Returns null when no Goal exists.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "required": .array([]),
            "additionalProperties": .bool(false),
        ]))

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        PermissionIntent(
            action: "goal.get",
            resources: [PermissionResource(kind: .goal, value: "current")],
            dataEffects: [.read],
            replayPolicy: .safeToReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        guard let manager = context.goalManager else {
            return ToolObservation(text: "Goal management is not available in this session")
        }
        struct Response: Encodable { var goal: Goal? }
        return ToolObservation(text: try encodeGoalToolResult(
            Response(goal: await manager.currentGoal())))
    }
}

public struct UpdateGoalTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "update_goal",
        description: "Submit only a complete or blocked Goal status candidate using the current revision. The independent GoalVerifier audit and host authority remain final; this tool cannot create evidence, pause, resume, edit, clear, or change budgets. In Cowork it is exposed only to the exact @main agent.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "goal_id": .object(["type": .string("string"), "minLength": .number(1)]),
                "expected_revision": .object([
                    "type": .string("integer"),
                    "minimum": .number(0),
                ]),
                "status": .object([
                    "type": .string("string"),
                    "enum": .array([.string("complete"), .string("blocked")]),
                ]),
            ]),
            "required": .array([.string("expected_revision"), .string("status")]),
            "additionalProperties": .bool(false),
        ]))

    private struct Args: Decodable {
        var goalID: String?
        var expectedRevision: Int
        var status: String

        enum CodingKeys: String, CodingKey {
            case status
            case goalID = "goal_id"
            case expectedRevision = "expected_revision"
        }
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        return PermissionIntent(
            action: "goal.submit_verdict",
            resources: [PermissionResource(kind: .goal, value: value?.goalID ?? "current")],
            metadata: ["status": value.map { .string($0.status) } ?? .null],
            dataEffects: [.none],
            controlEffects: [.submitGoalVerdict],
            risks: [.controlPlaneMutation],
            replayPolicy: .doNotReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try args.decode(Args.self)
        guard let manager = context.goalManager else {
            return ToolObservation(text: "Goal management is not available in this session")
        }
        let goalID: GoalID
        if let raw = value.goalID {
            goalID = GoalID(rawValue: raw)
        } else if let current = try await manager.currentGoal() {
            goalID = current.id
        } else {
            throw IntatisError.notFound("no current Goal exists")
        }
        let status: GoalStatus = value.status == "complete" ? .completed : .blocked
        let goal = try await manager.transitionGoal(
            goalID,
            expectedRevision: value.expectedRevision,
            to: status)
        struct Response: Encodable { var goal: Goal }
        return ToolObservation(text: try encodeGoalToolResult(Response(goal: goal)))
    }
}
