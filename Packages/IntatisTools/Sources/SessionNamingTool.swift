import Foundation
import IntatisCore
import IntatisProtocol

public struct SessionRenameResult: Codable, Equatable, Sendable {
    public let previousName: String?
    public let name: String
    public let currentName: String
    public let revision: Int
    public let changed: Bool

    public init(previousName: String?,
                name: String,
                currentName: String,
                revision: Int,
                changed: Bool) {
        self.previousName = previousName
        self.name = name
        self.currentName = currentName
        self.revision = revision
        self.changed = changed
    }
}

/// Session-scoped host seam. Implementations must bind the target session when
/// constructing `ToolContext`; a model-authored session identifier is never accepted.
public protocol SessionNamingService: Sendable {
    func renameCurrentSession(to name: String,
                              operationID: String) async throws -> SessionRenameResult
}

public struct RenameSessionTool: Tool {
    public init() {}

    public static let canonicalPermission: String? = "session.rename"
    public static let descriptor = ToolDescriptor(
        name: "rename_session",
        description: "Rename the current session. The host binds the target session; no session ID is accepted.",
        sideEffect: .write,
        parameters: Schema.object(
            ["name": Schema.boundedString(minLength: 1, maxLength: 120)],
            required: ["name"])
    )

    private struct Args: Decodable {
        let name: String
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        PermissionIntent(
            action: "session.rename",
            resources: [PermissionResource(kind: .tool, value: "current_session")],
            dataEffects: [.none],
            controlEffects: [],
            risks: [.controlPlaneMutation],
            replayPolicy: .doNotReplay)
    }

    public func permissionActionPreview(_ args: ToolArgs) -> PermissionActionPreview? {
        guard let value = try? args.decode(Args.self) else { return nil }
        return PermissionActionPreview(
            kind: Self.descriptor.name,
            fields: ["nameCharacterCount": String(value.name.count)])
    }

    /// A session title is deliberately excluded from durable authorization
    /// fingerprints. The exact value remains request-local through execution,
    /// while the canonical settings event records the accepted display name.
    public func authorizationArgumentIdentity(_ args: ToolArgs) -> String {
        guard let value = try? args.decode(Args.self) else {
            return "current-session-name:invalid"
        }
        return "current-session-name:characters=\(value.name.count)"
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try args.decode(Args.self)
        guard let sessionNaming = context.sessionNaming else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "session_naming_unavailable",
                message: "Session naming is not available for this tool execution.")
        }
        guard let operationID = context.executionID, !operationID.isEmpty else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "missing_execution_id",
                message: "A durable execution ID is required to rename the current session.")
        }

        let result = try await sessionNaming.renameCurrentSession(
            to: value.name,
            operationID: operationID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        return ToolObservation(text: String(decoding: data, as: UTF8.self))
    }
}
