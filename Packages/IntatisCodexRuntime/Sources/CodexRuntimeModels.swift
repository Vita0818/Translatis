import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisPermission

public enum CodexRuntimeMode: String, Codable, Equatable, Sendable {
    case code
    case cowork

    func developerInstructions(
        hostApplicationIdentity: IntatisHostApplicationIdentity =
            IntatisHostApplication.identity,
        nativeCollaborationEnabled: Bool,
        businessToolsEnabled: Bool,
        sessionRenameEnabled: Bool
    ) -> String {
        let applicationName = hostApplicationIdentity.name
        let businessTools = businessToolsEnabled
            ? " \(applicationName) first-party business tools registered on this thread are the authoritative business-tool path: call them directly when they fit the task. Do not recreate an unavailable or failed registered business tool with shell scripts, Python, MCP, or another backend; report the exact failure instead."
            : ""
        let sessionRename = sessionRenameEnabled
            ? " Session naming: `rename_session` is the authoritative tool for renaming only this current Session. On the first user task for this Session, after completing the work and its verification or establishing a genuine blocker, and before returning the final response, the current root agent must call `rename_session` exactly once with a short, concrete title describing the task or result. Do not use a date, time, SessionID, or a generic placeholder such as `Session`. On later turns, call it only when the user explicitly asks to rename the Session."
            : ""
        switch self {
        case .code:
            return "You are the coding agent for \(hostApplicationIdentity.indefiniteArticle) \(applicationName) Code workspace. Work directly in the current workspace, use the runtime tools when needed, and report concrete results to the user.\(businessTools)\(sessionRename)"
        case .cowork:
            let rootOnlyRename = sessionRenameEnabled
                ? " This rename instruction applies only to the exact root @main. Descendants must never call `rename_session`, even if the shared dynamic-tool surface lists it. Treat `rename_session` as the last non-run-control tool call; after it succeeds, call `finish_run` or `stop_run` if the current run exposes one of those controls, then return the final response."
                : ""
            return "You are @main for \(hostApplicationIdentity.indefiniteArticle) \(applicationName) Cowork workspace. Own the user request end to end and use Codex collaboration tools when delegation materially helps. Before making a scheduling or child-profile choice, activate the bundled $cowork-agent-orchestration Skill. Child agents may use only the exact agent_type and workspace presets advertised by spawn_agent; never invent a model, provider, credential, request option, or path. WorkTask calls record user-visible cards only: wait for task_create and spawn_agent results in separate rounds, then use task_link_agent with the successful spawn's exact canonical task name when an explicit card association is useful. Report back through the native Codex control plane.\(businessTools)\(sessionRename)\(rootOnlyRename)"
        }
    }

    func baseInstructions(
        hostApplicationIdentity: IntatisHostApplicationIdentity
    ) -> String {
        "You are Codex, the coding agent embedded in \(hostApplicationIdentity.name). Collaborate with the user until the requested workspace task is genuinely handled. Use the runtime's tools and approval system directly, preserve existing user work, verify changes in proportion to risk, and report concrete outcomes."
    }
}

public enum CodexRuntimeApprovalReviewer: String, Codable, Equatable, Sendable {
    case user
    case automatic = "auto_review"
}

/// One flat function registered through the official experimental
/// `thread/start.dynamicTools` App Server extension. Intatis does not translate
/// this into MCP or a provider-specific tool shape; App Server owns that wire
/// projection and calls the client back through `item/tool/call`.
public struct CodexRuntimeDynamicToolSpec: Equatable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let deferLoading: Bool?

    public init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        deferLoading: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.deferLoading = deferLoading
    }

    var wireValue: JSONValue {
        var value: [String: JSONValue] = [
            "type": .string("function"),
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
        ]
        if let deferLoading {
            value["deferLoading"] = .bool(deferLoading)
        }
        return .object(value)
    }
}

/// A synchronous host-owned liveness fence for one App Server business-tool
/// callback. The session invalidates it when the verified child leaves the
/// current tree or its effective workspace/permission binding changes. It is
/// never serialized or exposed to the model.
public final class CodexRuntimeDynamicToolExecutionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    public init() {}

    public var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }

    func invalidate() {
        lock.lock()
        valid = false
        lock.unlock()
    }
}

/// Host-owned selector for one already-resolved provider-hosted search
/// service. It never crosses the App Server wire and never lets the model
/// choose a provider, model, credential, or route.
public enum CodexRuntimeHostedWebSearchScope: Hashable, Sendable {
    case root
    case childRole(String)
}

public struct CodexRuntimeDynamicToolCall: Sendable {
    public let threadID: String
    public let turnID: String
    public let callID: String
    public let tool: String
    public let arguments: JSONValue
    /// Host-owned Intatis identity for a verified Codex descendant thread.
    /// Root-thread calls leave this nil so the business-tool host uses its
    /// configured root identity. This value never crosses the App Server wire.
    public let agentID: AgentID?
    /// Host-verified workspace selected from the root configuration or the
    /// exact configured Codex role. It never comes from model arguments.
    public let workspaceURL: URL?
    public let workspaceAccess: WorkspaceAccess?
    public let permissionProfile: PermissionProfile?
    /// Host-approved Knowledge capabilities for this exact verified caller.
    /// The App Server wire request cannot author or widen this value.
    public let knowledgeCapabilities: Set<ToolCapability>
    /// Exact host-owned service scope inherited from the verified root or
    /// custom-agent role. Nil means this caller has no hosted-search route.
    public let hostedWebSearchScope:
        CodexRuntimeHostedWebSearchScope?
    public let executionLease: CodexRuntimeDynamicToolExecutionLease?

    public init(
        threadID: String,
        turnID: String,
        callID: String,
        tool: String,
        arguments: JSONValue,
        agentID: AgentID? = nil,
        workspaceURL: URL? = nil,
        workspaceAccess: WorkspaceAccess? = nil,
        permissionProfile: PermissionProfile? = nil,
        knowledgeCapabilities: Set<ToolCapability> = [],
        hostedWebSearchScope:
            CodexRuntimeHostedWebSearchScope? = nil,
        executionLease: CodexRuntimeDynamicToolExecutionLease? = nil
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.callID = callID
        self.tool = tool
        self.arguments = arguments
        self.agentID = agentID
        self.workspaceURL = workspaceURL
        self.workspaceAccess = workspaceAccess
        self.permissionProfile = permissionProfile
        self.knowledgeCapabilities = knowledgeCapabilities
        self.hostedWebSearchScope = hostedWebSearchScope
        self.executionLease = executionLease
    }
}

public enum CodexRuntimeDynamicToolContentItem: Equatable, Sendable {
    case inputText(String)
    case inputImage(String)
    case inputAudio(String)

    var wireValue: JSONValue {
        switch self {
        case .inputText(let text):
            return .object([
                "type": .string("inputText"),
                "text": .string(text),
            ])
        case .inputImage(let imageURL):
            return .object([
                "type": .string("inputImage"),
                "imageUrl": .string(imageURL),
            ])
        case .inputAudio(let audioURL):
            return .object([
                "type": .string("inputAudio"),
                "audioUrl": .string(audioURL),
            ])
        }
    }
}

public struct CodexRuntimeDynamicToolResult: Equatable, Sendable {
    public let success: Bool
    public let contentItems: [CodexRuntimeDynamicToolContentItem]
    /// Host-only response semantic for a user choosing "Cancel Turn" at an
    /// Intatis business-tool permission prompt. It is never serialized into
    /// the App Server tool result.
    public let shouldInterruptTurn: Bool

    public init(
        success: Bool,
        contentItems: [CodexRuntimeDynamicToolContentItem],
        shouldInterruptTurn: Bool = false
    ) {
        self.success = success
        self.contentItems = contentItems
        self.shouldInterruptTurn = shouldInterruptTurn
    }

    public static func text(
        _ text: String,
        success: Bool = true,
        shouldInterruptTurn: Bool = false
    ) -> Self {
        Self(
            success: success,
            contentItems: [.inputText(text)],
            shouldInterruptTurn: shouldInterruptTurn)
    }

    var wireValue: JSONValue {
        .object([
            "success": .bool(success),
            "contentItems": .array(contentItems.map(\.wireValue)),
        ])
    }
}

public struct CodexRuntimeDynamicTools: Sendable {
    public typealias Handler = @Sendable (
        CodexRuntimeDynamicToolCall
    ) async -> CodexRuntimeDynamicToolResult
    public typealias ShutdownHandler = @Sendable () async -> Bool

    public let toolsetID: String
    public let specs: [CodexRuntimeDynamicToolSpec]
    private let handler: Handler
    private let shutdownHandler: ShutdownHandler?

    public init(
        toolsetID: String,
        specs: [CodexRuntimeDynamicToolSpec],
        handler: @escaping Handler,
        shutdownHandler: ShutdownHandler? = nil
    ) {
        self.toolsetID = toolsetID
        self.specs = specs
        self.handler = handler
        self.shutdownHandler = shutdownHandler
    }

    func execute(
        _ call: CodexRuntimeDynamicToolCall
    ) async -> CodexRuntimeDynamicToolResult {
        await handler(call)
    }

    /// Drains any host-owned resources retained by the dynamic-tool surface.
    /// App Server owns tool scheduling; this hook is only the matching client
    /// lifecycle edge for resources created while registering those tools.
    public func shutdown() async -> Bool {
        await shutdownHandler?() ?? true
    }

    func validate() throws {
        guard !toolsetID.isEmpty,
              toolsetID.count <= 256,
              toolsetID.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              !specs.isEmpty else {
            throw CodexRuntimeError.malformedProtocol(
                "dynamic tool registration is missing a bounded toolset id or specs")
        }
        var names: Set<String> = []
        for spec in specs {
            guard !spec.name.isEmpty,
                  spec.name.count <= 128,
                  spec.description.count <= 16_384,
                  case .object = spec.inputSchema,
                  spec.name.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }),
                  names.insert(spec.name).inserted else {
                throw CodexRuntimeError.malformedProtocol(
                    "dynamic tool registration contains an invalid or duplicate function")
            }
        }
    }

    func contains(tool name: String) -> Bool {
        specs.contains { $0.name == name }
    }
}

public enum CodexRuntimeChildSandbox: String, Sendable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
}

/// One official Codex custom-agent role materialized inside this session's
/// isolated CODEX_HOME. Routes remain in process memory; role files contain
/// only provider identifiers and secret-free model/workspace policy.
public struct CodexRuntimeChildProfile: Sendable {
    public let roleName: String
    public let description: String
    public let workspaceURL: URL
    public let route: ResponsesRuntimeRoute
    public let sandbox: CodexRuntimeChildSandbox
    public let permissionProfile: PermissionProfile
    /// Explicit host-owned Knowledge grant for children spawned with this
    /// preset. Only build/search capabilities are accepted by the runtime.
    public let knowledgeCapabilities: Set<ToolCapability>
    /// True only when this exact role has a matching host-bound search
    /// service. No provider or credential material enters the role file.
    public let hostedWebSearchEnabled: Bool

    public init(
        roleName: String,
        description: String,
        workspaceURL: URL,
        route: ResponsesRuntimeRoute,
        sandbox: CodexRuntimeChildSandbox,
        permissionProfile: PermissionProfile = .reviewed,
        knowledgeCapabilities: Set<ToolCapability> = [],
        hostedWebSearchEnabled: Bool = false
    ) {
        self.roleName = roleName
        self.description = description
        self.workspaceURL = workspaceURL
        self.route = route
        self.sandbox = sandbox
        self.permissionProfile = permissionProfile
        self.knowledgeCapabilities = knowledgeCapabilities
        self.hostedWebSearchEnabled = hostedWebSearchEnabled
    }
}

public struct CodexRuntimeConfiguration: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public let sessionID: SessionID
    public let mode: CodexRuntimeMode
    public let workspaceURL: URL
    public let runtimeRootURL: URL
    public let route: ResponsesRuntimeRoute
    public let approvalReviewer: CodexRuntimeApprovalReviewer
    public let reasoningEffort: String?
    public let executableOverride: URL?
    public let allowsThreadCreation: Bool
    public let dynamicTools: CodexRuntimeDynamicTools?
    public let mcpConfiguration: CodexRuntimeMCPConfiguration
    public let skillConfiguration: CodexRuntimeSkillConfiguration
    public let childProfiles: [CodexRuntimeChildProfile]
    /// Optional host presentation callback for Codex's built-in structured
    /// question flow. Its presence enables the official function in the one
    /// existing Code/Cowork mode; it is not a product-mode selector.
    public let requestUserInputHandler:
        CodexRuntimeUserInputHandler?
    /// Explicit host-owned Knowledge grant for descendants that omit an
    /// `agent_type` and inherit the current parent route/workspace.
    public let inheritedChildKnowledgeCapabilities: Set<ToolCapability>
    /// Root and roleless descendants may use the root's exact search service
    /// only when this host-owned flag is true.
    public let rootHostedWebSearchEnabled: Bool
    public let rootPermissionProfile: PermissionProfile
    /// On a persisted-thread start, convert an active official Codex Goal to
    /// paused before `thread/resume` can trigger its idle continuation.
    public let pauseActiveGoalBeforeResume: Bool
    /// Frozen host identity used for every product-owned runtime namespace,
    /// prompt, diagnostic, and generated config value in this session.
    public let hostApplicationIdentity: IntatisHostApplicationIdentity

    public init(
        sessionID: SessionID,
        mode: CodexRuntimeMode,
        workspaceURL: URL,
        runtimeRootURL: URL,
        route: ResponsesRuntimeRoute,
        approvalReviewer: CodexRuntimeApprovalReviewer = .automatic,
        reasoningEffort: String? = nil,
        executableOverride: URL? = nil,
        allowsThreadCreation: Bool = true,
        dynamicTools: CodexRuntimeDynamicTools? = nil,
        mcpConfiguration: CodexRuntimeMCPConfiguration = .empty,
        skillConfiguration: CodexRuntimeSkillConfiguration = .empty,
        childProfiles: [CodexRuntimeChildProfile] = [],
        requestUserInputHandler:
            CodexRuntimeUserInputHandler? = nil,
        inheritedChildKnowledgeCapabilities: Set<ToolCapability> = [],
        rootHostedWebSearchEnabled: Bool = false,
        rootPermissionProfile: PermissionProfile = .reviewed,
        pauseActiveGoalBeforeResume: Bool = false,
        hostApplicationIdentity: IntatisHostApplicationIdentity =
            IntatisHostApplication.identity
    ) {
        self.sessionID = sessionID
        self.mode = mode
        self.workspaceURL = workspaceURL
        self.runtimeRootURL = runtimeRootURL
        self.route = route
        self.approvalReviewer = approvalReviewer
        self.reasoningEffort = reasoningEffort
        self.executableOverride = executableOverride
        self.allowsThreadCreation = allowsThreadCreation
        self.dynamicTools = dynamicTools
        self.mcpConfiguration = mcpConfiguration
        self.skillConfiguration = skillConfiguration
        self.childProfiles = childProfiles
        self.requestUserInputHandler = requestUserInputHandler
        self.inheritedChildKnowledgeCapabilities =
            inheritedChildKnowledgeCapabilities
        self.rootHostedWebSearchEnabled = rootHostedWebSearchEnabled
        self.rootPermissionProfile = rootPermissionProfile
        self.pauseActiveGoalBeforeResume = pauseActiveGoalBeforeResume
        self.hostApplicationIdentity = hostApplicationIdentity
    }

    public var description: String {
        "CodexRuntimeConfiguration(session: <configured>, mode: \(mode.rawValue), workspace: <configured>, route: \(route), approvalReviewer: \(approvalReviewer.rawValue))"
    }

    public var debugDescription: String { description }
}

public struct CodexRuntimeIdentity: Codable, Equatable, Sendable {
    public let threadID: String
    public let runtimeVersion: String
    public let mode: CodexRuntimeMode

    public init(
        threadID: String,
        runtimeVersion: String,
        mode: CodexRuntimeMode
    ) {
        self.threadID = threadID
        self.runtimeVersion = runtimeVersion
        self.mode = mode
    }
}

/// Safe App Server metadata for one verified descendant of the current Cowork
/// root. The upstream thread ID remains the join key; Intatis does not invent
/// a second scheduler identity or infer ancestry from display text.
public struct CodexRuntimeThreadDescriptor: Equatable, Sendable {
    public let threadID: String
    public let parentThreadID: String
    public let sessionID: String
    public let agentNickname: String?
    public let agentRole: String?
    public let agentPath: String?
    public let name: String?
    public let preview: String
    public let cwd: String
    public let modelProvider: String
    public let requestedModel: String?
    public let reasoningEffort: String?
    public let serviceTier: String?
    public let runtimeWorkspaceRoots: [String]
    public let isArchived: Bool
    public let status: String
    public let activeFlags: [String]
    public let canAcceptDirectInput: Bool?
    public let createdAt: Int?

    public init(
        threadID: String,
        parentThreadID: String,
        sessionID: String,
        agentNickname: String? = nil,
        agentRole: String? = nil,
        agentPath: String? = nil,
        name: String? = nil,
        preview: String = "",
        cwd: String = "",
        modelProvider: String = "",
        requestedModel: String? = nil,
        reasoningEffort: String? = nil,
        serviceTier: String? = nil,
        runtimeWorkspaceRoots: [String] = [],
        isArchived: Bool = false,
        status: String,
        activeFlags: [String] = [],
        canAcceptDirectInput: Bool? = nil,
        createdAt: Int? = nil
    ) {
        self.threadID = threadID
        self.parentThreadID = parentThreadID
        self.sessionID = sessionID
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.agentPath = agentPath
        self.name = name
        self.preview = preview
        self.cwd = cwd
        self.modelProvider = modelProvider
        self.requestedModel = requestedModel
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.runtimeWorkspaceRoots = runtimeWorkspaceRoots
        self.isArchived = isArchived
        self.status = status
        self.activeFlags = activeFlags
        self.canAcceptDirectInput = canAcceptDirectInput
        self.createdAt = createdAt
    }

    public var agentID: AgentID {
        AgentID(rawValue: "codex:\(threadID)")
    }

    public var displayName: String {
        let taskName = agentPath?.split(separator: "/").last.map(String.init)
        for candidate in [agentNickname, taskName, agentRole, name] {
            if let value = candidate?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return "agent-" + String(threadID.suffix(8))
    }
}

public enum CodexRuntimeTranscriptItem: Equatable, Sendable {
    case user(
        id: String,
        turnID: String,
        text: String)
    case assistant(
        id: String,
        turnID: String,
        text: String,
        phase: MessagePhase?,
        complete: Bool)
    case runtime(
        turnID: String,
        item: CodexRuntimeItem)
}

public struct CodexRuntimeThreadHistory: Equatable, Sendable {
    public let threadID: String
    public let items: [CodexRuntimeTranscriptItem]

    public init(
        threadID: String,
        items: [CodexRuntimeTranscriptItem]
    ) {
        self.threadID = threadID
        self.items = items
    }
}

public struct CodexRuntimeItem: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case command
        case fileChange
        case mcpTool
        case dynamicTool
        case collaboration
        case subagent
        case webSearch
        case image
        case plan
        case reasoning
        case other
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let detail: String
    public let status: String?
    public let isFailure: Bool
    public let relatedThreadIDs: [String]

    public init(
        id: String,
        kind: Kind,
        title: String,
        detail: String = "",
        status: String? = nil,
        isFailure: Bool = false,
        relatedThreadIDs: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.status = status
        self.isFailure = isFailure
        self.relatedThreadIDs = relatedThreadIDs
    }
}

public enum CodexRuntimeApprovalKind: String, Equatable, Sendable {
    case command
    case fileChange
    case permissions
}

public struct CodexRuntimeRequestID: Hashable, Equatable, Sendable,
    CustomStringConvertible
{
    let wireValue: JSONValue
    public let description: String

    init?(wireValue: JSONValue) {
        switch wireValue {
        case .string(let value):
            self.wireValue = wireValue
            self.description = value
        case .number(let value):
            guard value.isFinite,
                  value.rounded() == value,
                  value >= Double(Int64.min),
                  value < Double(Int64.max) else {
                return nil
            }
            self.wireValue = wireValue
            self.description = String(Int64(value))
        default:
            return nil
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(description)
    }
}

public struct CodexRuntimeApprovalRequest: Equatable, Sendable {
    public let requestID: CodexRuntimeRequestID
    public let kind: CodexRuntimeApprovalKind
    public let threadID: String
    public let turnID: String
    public let itemID: String
    public let title: String
    public let summary: String
    let requestedPermissions: JSONValue?

    init(
        requestID: CodexRuntimeRequestID,
        kind: CodexRuntimeApprovalKind,
        threadID: String,
        turnID: String,
        itemID: String,
        title: String,
        summary: String,
        requestedPermissions: JSONValue? = nil
    ) {
        self.requestID = requestID
        self.kind = kind
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.title = title
        self.summary = summary
        self.requestedPermissions = requestedPermissions
    }
}

/// One exact selectable option from Codex's built-in
/// `request_user_input` function. Intatis does not define or translate this
/// schema; the fixed App Server owns the model-facing tool.
public struct CodexRuntimeUserInputOption: Equatable, Sendable {
    public let label: String
    public let description: String

    public init(label: String, description: String) {
        self.label = label
        self.description = description
    }
}

/// One question delivered by the official
/// `item/tool/requestUserInput` App Server request.
public struct CodexRuntimeUserInputQuestion: Equatable, Sendable {
    public let id: String
    public let header: String
    public let question: String
    public let options: [CodexRuntimeUserInputOption]
    public let allowsOther: Bool
    public let isSecret: Bool

    public init(
        id: String,
        header: String,
        question: String,
        options: [CodexRuntimeUserInputOption],
        allowsOther: Bool,
        isSecret: Bool
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.allowsOther = allowsOther
        self.isSecret = isSecret
    }
}

/// A host-bound request for user input. `agentID` is nil for the root and is
/// populated only after App Server ancestry proves a Cowork descendant.
public struct CodexRuntimeUserInputRequest: Equatable, Sendable {
    public let requestID: CodexRuntimeRequestID
    public let threadID: String
    public let turnID: String
    public let itemID: String
    public let agentID: AgentID?
    public let questions: [CodexRuntimeUserInputQuestion]
    public let autoResolutionMilliseconds: Int?

    public init(
        requestID: CodexRuntimeRequestID,
        threadID: String,
        turnID: String,
        itemID: String,
        agentID: AgentID?,
        questions: [CodexRuntimeUserInputQuestion],
        autoResolutionMilliseconds: Int?
    ) {
        self.requestID = requestID
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.agentID = agentID
        self.questions = questions
        self.autoResolutionMilliseconds = autoResolutionMilliseconds
    }
}

/// Exact question-id to selected/free-form answer mapping returned to the
/// App Server. The session validates completeness, option membership, bounds,
/// and secret safety before serialization.
public struct CodexRuntimeUserInputResponse: Equatable, Sendable {
    public let answers: [String: [String]]

    public init(answers: [String: [String]]) {
        self.answers = answers
    }

    var wireValue: JSONValue {
        .object([
            "answers": .object(answers.mapValues { values in
                .object([
                    "answers": .array(values.map(JSONValue.string)),
                ])
            }),
        ])
    }
}

/// Host callback for Codex's built-in structured question flow. Supplying
/// this callback enables the official tool in the existing Code/Cowork mode;
/// nil keeps the feature disabled and fail-closed without creating a second
/// product mode or a replacement dynamic tool.
public typealias CodexRuntimeUserInputHandler = @Sendable (
    CodexRuntimeUserInputRequest
) async throws -> CodexRuntimeUserInputResponse

public enum CodexRuntimeApprovalDecision: String, Equatable, Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel
}

public struct CodexRuntimeTurnResult: Equatable, Sendable {
    public let turnID: String
    public let status: String
    public let errorMessage: String?

    public init(
        turnID: String,
        status: String,
        errorMessage: String? = nil
    ) {
        self.turnID = turnID
        self.status = status
        self.errorMessage = errorMessage
    }

    public var succeeded: Bool { status == "completed" }
}

/// Exact `tokenUsage.last` values from the App Server's public
/// `thread/tokenUsage/updated` notification, paired with the official turn
/// duration when that turn completes.
public struct CodexRuntimeResponsesUsage: Equatable, Sendable {
    public let turnID: String
    public let responseMessageItemID: String?
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let cacheWriteInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int
    public let totalTokens: Int
    public let durationMs: Int?

    public init(
        turnID: String,
        responseMessageItemID: String?,
        inputTokens: Int,
        cachedInputTokens: Int,
        cacheWriteInputTokens: Int,
        outputTokens: Int,
        reasoningOutputTokens: Int,
        totalTokens: Int,
        durationMs: Int?
    ) {
        self.turnID = turnID
        self.responseMessageItemID = responseMessageItemID
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
        self.durationMs = durationMs
    }
}

public struct CodexRuntimeGoalSnapshot: Equatable, Sendable {
    public let threadID: String
    public let objective: String
    public let status: String
    public let tokenBudget: Int?
    public let tokensUsed: Int
    public let timeUsedSeconds: Int
    public let createdAt: Int
    public let updatedAt: Int

    public init(
        threadID: String,
        objective: String,
        status: String,
        tokenBudget: Int?,
        tokensUsed: Int,
        timeUsedSeconds: Int,
        createdAt: Int,
        updatedAt: Int
    ) {
        self.threadID = threadID
        self.objective = objective
        self.status = status
        self.tokenBudget = tokenBudget
        self.tokensUsed = tokensUsed
        self.timeUsedSeconds = timeUsedSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Exact three-state update required by the App Server Goal API. Omitting the
/// field keeps an existing budget; JSON null clears it; a positive integer
/// replaces it.
public enum CodexRuntimeGoalBudgetUpdate: Equatable, Sendable {
    case keep
    case clear
    case set(Int)
}

public enum CodexRuntimeEvent: Equatable, Sendable {
    case ready(CodexRuntimeIdentity)
    case turnStarted(String)
    case assistantDelta(
        itemID: String,
        text: String,
        phase: MessagePhase?)
    case assistantCompleted(
        itemID: String,
        text: String,
        phase: MessagePhase?)
    case reasoningDelta(itemID: String, text: String)
    case appServerEvent(CodexAppServerEventPayload)
    case itemStarted(CodexRuntimeItem)
    case itemCompleted(CodexRuntimeItem)
    case approvalRequested(CodexRuntimeApprovalRequest)
    case approvalResolved(CodexRuntimeRequestID)
    case responsesUsage(CodexRuntimeResponsesUsage)
    case goalUpdated(CodexRuntimeGoalSnapshot?)
    case turnCompleted(CodexRuntimeTurnResult)
    case runtimeError(code: String, message: String, fatal: Bool)
    case child(CodexRuntimeChildEvent)
}

public enum CodexRuntimeChildEvent: Equatable, Sendable {
    case threadUpdated(CodexRuntimeThreadDescriptor)
    case turnStarted(threadID: String, turnID: String)
    case assistantDelta(
        threadID: String,
        turnID: String?,
        itemID: String,
        text: String,
        phase: MessagePhase?)
    case assistantCompleted(
        threadID: String,
        turnID: String?,
        itemID: String,
        text: String,
        phase: MessagePhase?)
    case userMessage(
        threadID: String,
        turnID: String?,
        itemID: String,
        text: String)
    case reasoningDelta(
        threadID: String,
        turnID: String?,
        itemID: String,
        text: String)
    case appServerEvent(
        threadID: String,
        payload: CodexAppServerEventPayload)
    case itemStarted(threadID: String, turnID: String?, item: CodexRuntimeItem)
    case itemCompleted(threadID: String, turnID: String?, item: CodexRuntimeItem)
    case responsesUsage(threadID: String, usage: CodexRuntimeResponsesUsage)
    case turnCompleted(threadID: String, result: CodexRuntimeTurnResult)
}

public enum CodexRuntimeError: Error, Equatable, Sendable, LocalizedError {
    case executableUnavailable
    case incompatibleRuntime(expected: String, actual: String)
    case incompatibleRuntimeDerivation(expected: String, actual: String)
    case unsafeRuntimeStorage
    case shellSnapshotStoragePresent
    case processLaunchFailed(String)
    case processTerminated(Int32, String)
    case malformedProtocol(String)
    case serverError(code: Int?, message: String)
    case notStarted
    case alreadyRunning
    case runtimeAlreadyActive
    case noActiveTurn
    case requestNotPending
    case requestTimedOut(String)
    case threadMigrationRequired
    case turnFailed(String)

    public var errorDescription: String? {
        let hostIdentity = IntatisHostApplication.identity
        switch self {
        case .executableUnavailable:
            return "Codex Runtime 0.145.0-intatis.4 is not bundled or available. The shipping \(hostIdentity.name) app requires its matching architecture runtime inside the sealed App; development hosts may use an explicit \(hostIdentity.environmentVariable("CODEX_RUNTIME")) path."
        case .incompatibleRuntime(let expected, let actual):
            return "Codex Runtime version mismatch. \(hostIdentity.name) requires \(expected), but found \(actual)."
        case .incompatibleRuntimeDerivation(let expected, let actual):
            return "Codex Runtime derivation mismatch. \(hostIdentity.name) requires \(expected), but found \(actual)."
        case .unsafeRuntimeStorage:
            return "The Codex Runtime session directory is not a safe owner-only directory."
        case .shellSnapshotStoragePresent:
            return "This session's isolated Codex home contains shell snapshots from an older configuration. Start a new session; \(hostIdentity.name) will not load or delete files that may contain credentials."
        case .processLaunchFailed(let message):
            return "Codex Runtime could not start: \(message)"
        case .processTerminated(let status, let diagnostic):
            let suffix = diagnostic.isEmpty ? "" : " — \(diagnostic)"
            return "Codex Runtime exited with status \(status)\(suffix)"
        case .malformedProtocol(let message):
            return "Codex Runtime returned malformed protocol data: \(message)"
        case .serverError(let code, let message):
            let prefix = code.map { "Codex Runtime RPC error \($0)" }
                ?? "Codex Runtime RPC error"
            return "\(prefix): \(message)"
        case .notStarted:
            return "Codex Runtime is not started."
        case .alreadyRunning:
            return "A Codex Runtime turn is already running."
        case .runtimeAlreadyActive:
            return "Another \(hostIdentity.name) process already owns this session's Codex Runtime."
        case .noActiveTurn:
            return "There is no active Codex Runtime turn to interrupt."
        case .requestNotPending:
            return "The Codex Runtime approval request is no longer pending."
        case .requestTimedOut(let method):
            return "Codex Runtime did not answer \(method) before the request deadline."
        case .threadMigrationRequired:
            return "This Code/Cowork session was not created with the exact current Codex Runtime and business-tool surface. Start a new session; \(hostIdentity.name) does not migrate, reinterpret, or silently replace an older thread."
        case .turnFailed(let message):
            return "Codex Runtime turn failed: \(message)"
        }
    }
}
