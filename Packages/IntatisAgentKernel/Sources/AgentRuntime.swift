import Foundation
import IntatisConversation
import IntatisCore
import IntatisPermission
import IntatisProtocol
import IntatisProviders
import IntatisSkills
import IntatisTools

/// Optional durable scope for one AgentLoop turn. Cowork hosts can supply a
/// scope explicitly for control-plane runs; ordinary task executions derive
/// missing invocation/agent identifiers inside AgentLoop.
public struct AgentExecutionScope: Equatable, Sendable {
    public var goalID: GoalID?
    public var continuationRunID: ContinuationRunID?
    public var workTaskID: WorkTaskID?
    public var invocationTaskID: TaskID?
    public var agentID: AgentID?

    public init(goalID: GoalID? = nil,
                continuationRunID: ContinuationRunID? = nil,
                workTaskID: WorkTaskID? = nil,
                invocationTaskID: TaskID? = nil,
                agentID: AgentID? = nil) {
        self.goalID = goalID
        self.continuationRunID = continuationRunID
        self.workTaskID = workTaskID
        self.invocationTaskID = invocationTaskID
        self.agentID = agentID
    }
}

/// Shared headless execution unit used by visible Code sessions and every
/// Cowork agent. UI/ViewModels own presentation; this type owns the common
/// request/tool/permission configuration that must not drift between modes.
public struct AgentRuntime: Sendable {
    public static let defaultCodeMaxIterations = 50
    public static let defaultCoworkMaxIterations = 64

    public let environment: RuntimeEnvironmentManifest
    public let registry: ToolRegistry
    public let engine: PermissionEngine
    public let allowsShell: Bool
    public let reasoningEffort: ReasoningEffort?
    public let includeUsage: Bool
    public let maxIterations: Int
    /// Exact model metadata frozen with this runtime. `.unspecified` resolves
    /// through the product-wide context-window fallback; callers must never
    /// infer a context window from a model identifier.
    public let modelContextPolicy: AgentModelContextPolicy

    public init(environment: RuntimeEnvironmentManifest,
                registry: ToolRegistry,
                engine: PermissionEngine = PermissionEngine(),
                allowsShell: Bool,
                reasoningEffort: ReasoningEffort? = nil,
                includeUsage: Bool = false,
                maxIterations: Int = AgentRuntime.defaultCodeMaxIterations,
                modelContextPolicy: AgentModelContextPolicy = .unspecified) {
        self.environment = environment
        self.registry = registry
        self.engine = engine
        self.allowsShell = allowsShell
        self.reasoningEffort = reasoningEffort
        self.includeUsage = includeUsage
        self.maxIterations = max(1, maxIterations)
        self.modelContextPolicy = modelContextPolicy
    }

    public static func code(registry: ToolRegistry = .standard(),
                            allowsShell: Bool,
                            reasoningEffort: ReasoningEffort? = nil,
                            includeUsage: Bool = false,
                            maxIterations: Int = AgentRuntime.defaultCodeMaxIterations,
                            modelContextPolicy: AgentModelContextPolicy = .unspecified) -> AgentRuntime {
        AgentRuntime(
            environment: .code,
            registry: registry,
            allowsShell: allowsShell,
            reasoningEffort: reasoningEffort,
            includeUsage: includeUsage,
            maxIterations: maxIterations,
            modelContextPolicy: modelContextPolicy)
    }

    public static func cowork(registry: ToolRegistry,
                              engine: PermissionEngine,
                              allowsShell: Bool,
                              reasoningEffort: ReasoningEffort? = nil,
                              includeUsage: Bool = false,
                              maxIterations: Int = AgentRuntime.defaultCoworkMaxIterations,
                              modelContextPolicy: AgentModelContextPolicy = .unspecified) -> AgentRuntime {
        AgentRuntime(
            environment: .cowork,
            registry: registry,
            engine: engine,
            allowsShell: allowsShell,
            reasoningEffort: reasoningEffort,
            includeUsage: includeUsage,
            maxIterations: maxIterations,
            modelContextPolicy: modelContextPolicy)
    }

    public func makeLoop(log: EventLog,
                         provider: ToolCallingProvider,
                         responder: PermissionResponder,
                         agent: Agent,
                         context: ContextBuilder? = nil,
                         shell: ShellRunner = ProcessShellRunner(),
                         terminal: (any TerminalSessionManaging)? = nil,
                         git: GitService = ProcessGitService(),
                         messenger: AgentMessenger? = nil,
                         agentManager: AgentManager? = nil,
                         workTaskManager: WorkTaskManager? = nil,
                         goalManager: GoalManager? = nil,
                         runController: RunController? = nil,
                         imageGenerator: ImageGenerationToolService? = nil,
                         imageResolver: AgentImageResolver? = nil,
                         sessionNaming: SessionNamingService? = nil,
                         capabilityLease: CapabilityLease? = nil,
                         workspaceLease: WorkspaceLease? = nil,
                         rootTaskID: TaskID? = nil,
                         taskAttempt: Int? = nil,
                         executionScope: AgentExecutionScope? = nil,
                         tokenBudgetMeter: AgentTokenBudgetMeter? = nil,
                         authorizationPreparer: ToolAuthorizationPreparer? = nil,
                         authorizationRevalidator: ToolAuthorizationRevalidator? = nil,
                         toolSnapshotProvider:
                            AgentRequestToolSnapshotProvider? = nil) -> AgentLoop {
        let supplied = context ?? ContextBuilder()
        let runtimeContext = ContextBuilder(
            systemPrompt: supplied.systemPrompt,
            taskContract: supplied.taskContract,
            contextBundle: supplied.contextBundle,
            skillSnapshot: supplied.skillSnapshot,
            runtimeEnvironment: environment,
            conversationHistoryPolicy: supplied.conversationHistoryPolicy)
        return AgentLoop(
            log: log,
            provider: provider,
            registry: registry,
            engine: engine,
            responder: responder,
            agent: agent,
            context: runtimeContext,
            allowsShell: allowsShell,
            shell: shell,
            terminal: terminal,
            git: git,
            messenger: messenger,
            agentManager: agentManager,
            workTaskManager: workTaskManager,
            goalManager: goalManager,
            runController: runController,
            imageGenerator: imageGenerator,
            imageResolver: imageResolver,
            sessionNaming: sessionNaming,
            reasoningEffort: reasoningEffort,
            includeUsage: includeUsage,
            modelContextPolicy: modelContextPolicy,
            maxIterations: maxIterations,
            capabilityLease: capabilityLease,
            workspaceLease: workspaceLease,
            rootTaskID: rootTaskID,
            taskAttempt: taskAttempt,
            executionScope: executionScope,
            tokenBudgetMeter: tokenBudgetMeter,
            authorizationPreparer: authorizationPreparer,
            authorizationRevalidator: authorizationRevalidator,
            toolSnapshotProvider: toolSnapshotProvider)
    }
}
