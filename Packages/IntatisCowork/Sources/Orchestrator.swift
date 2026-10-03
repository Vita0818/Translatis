import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
import IntatisSkills

public enum OrchestratorSendResult: Equatable, Sendable {
    case sent
    case failed(String)

    public var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

public enum AutomaticPermissionReviewResult: Equatable, Sendable {
    case enabled(AgentID)
    case alreadyEnabled(AgentID)
    case failed(String)
}

private struct DelegationAuthorizationArguments: Decodable {
    var to: String?
    var workTaskID: WorkTaskID?
    var knowledgeAccess: DelegatedKnowledgeAccess?

    private enum CodingKeys: String, CodingKey {
        case to
        case workTaskID = "work_task_id"
        case knowledgeAccess = "knowledge_access"
    }
}

private struct SpawnAuthorizationArguments: Decodable {
    var inferenceProfileID: String?

    private enum CodingKeys: String, CodingKey {
        case inferenceProfileID = "inference_profile_id"
    }
}

/// Immutable executor-side snapshot for one already-reviewed delegation to an
/// already attached data-plane agent.
private struct AuthorizedDelegationAdmission: Sendable {
    var authorization: ResolvedToolAuthorization
    var target: AgentID
    var binding: AgentInferenceBinding?
    var targetFingerprint: String
    var knowledgeCapabilities: Set<ToolCapability>
    var workspaceAccess: WorkspaceAccess
}

public enum AutomaticPermissionReviewDisableResult: Equatable, Sendable {
    case disabled(AgentID)
    case alreadyDisabled
    case failed(String)
}

public enum CoworkSessionBootstrapResult: Equatable, Sendable {
    case attached(AgentID)
    case alreadyAttached(AgentID)
    case failed(String)
}

public enum AgentInferenceRebindResult: Equatable, Sendable {
    case rebound(AgentID, AgentInferenceBinding)
    case unchanged(AgentID, AgentInferenceBinding)
    case failed(String)
}

/// Secret-free, host-projected routing facts for one selectable inference
/// profile. This metadata is intentionally ephemeral: exact bindings remain
/// the durable authorization identity, while declared capabilities are used
/// only to help a coordinator choose an adequate child profile.
public struct InferenceProfileRoutingMetadata: Equatable, Sendable {
    public let inferenceProfileID: InferenceProfileID
    public let declaredCapabilities: [Capability]

    public init(
        inferenceProfileID: InferenceProfileID,
        declaredCapabilities: [Capability]
    ) {
        self.inferenceProfileID = inferenceProfileID
        let declared = Set(declaredCapabilities)
        self.declaredCapabilities = Capability.allCases.filter(
            declared.contains)
    }
}

public struct CoworkExecutionPolicy: Equatable, Sendable {
    public var maxConcurrentTasks: Int
    public var taskTimeoutSeconds: Double
    public var maxAttempts: Int
    public var tokenBudget: Int?

    public init(maxConcurrentTasks: Int = 4,
                taskTimeoutSeconds: Double = 3_600,
                maxAttempts: Int = 3,
                tokenBudget: Int? = nil) {
        self.maxConcurrentTasks = max(1, maxConcurrentTasks)
        self.taskTimeoutSeconds = max(0.01, taskTimeoutSeconds)
        self.maxAttempts = max(1, maxAttempts)
        self.tokenBudget = tokenBudget.flatMap { $0 > 0 ? $0 : nil }
    }

    public static let `default` = CoworkExecutionPolicy()
}

public enum CoworkTaskExecutionError: Error, Equatable, Sendable, LocalizedError {
    case timedOut(seconds: Double)
    case tokenBudgetExhausted(limit: Int)
    case cancelled(String)
    case invalidLease(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            let rendered = seconds.rounded() == seconds
                ? String(Int(seconds))
                : String(format: "%.2f", seconds)
            return "Task timed out after \(rendered) seconds."
        case .tokenBudgetExhausted(let limit):
            return "Cowork token budget of \(limit) tokens is exhausted."
        case .cancelled(let reason):
            return "Task cancelled: \(reason)"
        case .invalidLease(let reason):
            return "Task lease is invalid: \(reason)"
        }
    }
}

private enum ScheduledReplyFormat: Sendable {
    case answer
    case taskReport
}

private enum CommunicationOperation: Equatable, Sendable {
    case send
    case requestInformation
    case reply
}

private struct RootInvocationContext: Sendable {
    var images: [ImageAttachment]
    var userMessage: UserMessagePayload?
    var recordUserMessage: Bool
}

private struct AgentRunResult: Sendable {
    var output: String
    var presentedMessageIDs: [MessageID]
}

private struct TaskLeaseRenewal: Sendable {
    var contract: TaskContract
    var capabilityLease: CapabilityLease?
    var workspaceLease: WorkspaceLease?
}

private enum RetryAdmissionResult: Sendable {
    case admitted(TaskID)
    case rejected(String)
}

private struct PreparedMainInferenceRebind: Sendable {
    var previous: Agent
    var candidate: Agent
}

private enum MainInferencePreparation: Sendable {
    case unchanged
    case rebind(PreparedMainInferenceRebind)
    case failed(String)
}

private enum MainInferenceCommit: Sendable {
    case ready(Agent, Event?)
    case failed(String)
}

private enum RootTaskCreationResult: Sendable {
    case created(TaskID)
    case failed(String)
}

private enum CoworkTaskTimeoutRace<Value: Sendable>: Sendable {
    case operation(Value)
    case timeout
}

/// Provider and model-history limits from one exact resolver snapshot. Legacy
/// provider seams deliberately carry no context metadata.
private struct ResolvedAgentRuntimeInference: Sendable {
    let provider: ToolCallingProvider
    let modelContextPolicy: AgentModelContextPolicy
    let hostedWebSearch: ResolvedHostedWebSearchRoute?
}

/// Races one request-owned operation against its deadline, then joins both
/// children before returning. Operations must react to cancellation or at
/// least eventually unwind; a permanently synchronous blocker is deliberately
/// outside the provider contract because publishing a terminal task while it
/// still runs would make the execution result unknowable.
private func withTaskTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let boundedSeconds = max(0.001, seconds)
    try Task.checkCancellation()
    return try await withThrowingTaskGroup(
        of: CoworkTaskTimeoutRace<T>.self,
        returning: T.self
    ) { group in
        group.addTask {
            .operation(try await operation())
        }
        group.addTask {
            let nanos = UInt64(
                min(boundedSeconds, Double(UInt64.max) / 1_000_000_000)
                    * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanos)
            return .timeout
        }

        do {
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            // Leaving a task-group scope is a structured join. Explicitly
            // drain the losing child as well so the terminal task event cannot
            // be committed while provider/tool cleanup is still executing.
            while true {
                do {
                    guard try await group.next() != nil else { break }
                } catch is CancellationError {
                    // Expected for the cancelled timeout or operation child.
                } catch {
                    // The first terminal signal owns the race; a losing
                    // child's late failure cannot replace it.
                }
            }
            try Task.checkCancellation()
            switch first {
            case .operation(let value):
                return value
            case .timeout:
                throw CoworkTaskExecutionError.timedOut(seconds: boundedSeconds)
            }
        } catch {
            group.cancelAll()
            // A caller cancellation or provider failure must also wait for all
            // in-scope cleanup before it is observed by the scheduler.
            while true {
                do {
                    guard try await group.next() != nil else { break }
                } catch {
                    // Preserve the first observed error after all children end.
                }
            }
            throw error
        }
    }
}

/// Coordinates multiple agents over one shared event log (ARCHITECTURE.md §7).
/// Routes `@mentioned` user messages to the right agent, and mediates every
/// agent-to-agent exchange through the Message Bus. An `actor`, so concurrent /
/// reentrant agent runs serialize safely.
public actor Orchestrator {
    public typealias ToolSnapshotProvider =
        @Sendable (
            Agent,
            CapabilityLease,
            WorkspaceLease?,
            ToolRegistry,
            Bool,
            ToolCallingProviderCapabilities,
            AgentExternalToolOutputBudget
        ) async throws -> AgentRequestToolSnapshot?
    public static let mainAgentID = AgentID(rawValue: "main")
    public static let automaticPermissionReviewerID = AgentID(rawValue: "permission-reviewer")

    private struct GoalRunCancellationScope: Hashable, Sendable {
        var goalID: GoalID
        /// `nil` is a temporary Goal-wide fence used while an exact set of
        /// interrupted runs is being drained. It is removed only after durable
        /// cancellation succeeds; exact run tombstones remain permanently.
        var runID: ContinuationRunID?
    }

    private let log: EventLog
    /// Retained for the runtime lifetime. The public runtime initializer
    /// requires this lease so a second process cannot schedule the same session.
    private let writerLease: EventLogWriterLease?
    private var registry: AgentRegistry
    private let bus: MessageBus
    private let engine: PermissionEngine
    private let allowsShell: Bool
    /// Host policy for Skill discovery. Tests and sandboxed hosts default to
    /// workspace-only; Developer ID/CLI hosts must opt into global roots.
    private let skillRootAccess: SkillRootAccess
    private let terminal: ProcessTerminalSessionManager
    private let responder: PermissionResponder
    private var automaticPermissionResponder: AgentPermissionResponder?
    private var automaticPermissionReviewerAgentID: AgentID?
    private var automaticPermissionReviewDisabling: Bool
    private var automaticPermissionReviewRecoveryFailure: String?
    private var capabilityLeases: [CapabilityLeaseID: CapabilityLease]
    private var workspaceLeases: [WorkspaceLeaseID: WorkspaceLease]
    private var capabilityLeaseHistory: [CapabilityLeaseID: CapabilityLease]
    private var workspaceLeaseHistory: [WorkspaceLeaseID: WorkspaceLease]
    private var defaultCapabilityLeaseIDs: [AgentID: CapabilityLeaseID]
    private var defaultWorkspaceLeaseIDs: [AgentID: WorkspaceLeaseID]
    private var scheduler: AgentScheduler
    private var taskGraph: TaskGraph
    private var workTaskGraph: WorkTaskGraph
    /// Non-nil when durable WorkTask recovery failed global graph validation.
    /// The runtime keeps the planning graph empty and rejects its control plane
    /// until a subsequent restore observes a valid durable graph.
    private var workTaskRecoveryFailure: String?
    private var scheduledReplyTargets: [TaskID: AgentID]
    private var scheduledReplyFormats: [TaskID: ScheduledReplyFormat]
    /// Keeps delivery success distinct from a human-readable reply. In
    /// particular, a Mediator block must not become a successful ask_agent
    /// observation merely because it has explanatory text.
    private var scheduledReplyResults: [TaskID: AgentMessengerReply]
    private var spawnedAgentOwners: [AgentID: AgentID]
    /// Actor-reentrant `delegate_task(to: auto)` calls reserve their selected
    /// worker before mediation/admission awaits. This preserves true parallel
    /// dispatch instead of letting concurrent calls observe the same idle
    /// worker and serialize behind per-agent single flight.
    private var automaticDelegationReservations: Set<AgentID>
    private var executionPolicy: CoworkExecutionPolicy
    private var runningExecutions: [TaskID: Task<Void, Never>]
    private var resultWaiters: [TaskID: [CheckedContinuation<String?, Never>]]
    private var schedulerResultWaiterHookForTesting: (@Sendable (TaskID) -> Void)?
    private var idleWaiters: [CheckedContinuation<Void, Never>]
    private var rootInvocations: [TaskID: RootInvocationContext]
    private var cancellationReasons: [TaskID: String]
    /// Preserves who requested cancellation while a running provider/tool
    /// cooperatively unwinds. Without this, every cancelled root would be
    /// mislabeled as a runtime-originated run close.
    private var cancellationRunCloseSources:
        [TaskID: ContinuationRunCloseSource]
    /// In-process admission tombstones close the race between a Goal-scoped
    /// cancel snapshot and a root invocation that is still awaiting durable
    /// queue admission. ContinuationRun IDs are never reused, so tombstones can
    /// safely live for the session lifetime.
    private var cancelledGoalRunScopes: Set<GoalRunCancellationScope>
    /// First durable admission fence per exact ContinuationRun. Unlike the
    /// legacy Goal-only tombstone this also covers ordinary turns whose
    /// `goalID` is nil.
    private var continuationRunCloseClaims:
        [ContinuationRunID: ContinuationRunCloseRequestedPayload]
    /// A close request becomes an in-process admission tombstone before its
    /// EventLog CAS awaits. This lets the durable close fact be written before
    /// waiting for already-admitted communication/delegation to drain, while
    /// still preventing actor-reentrant work from crossing that boundary.
    private var continuationRunCloseInstallations: [ContinuationRunID: Int]
    private var providerUsageLimitFailures: [ContinuationRunID: (GoalID, String)]
    private var restoredPendingTaskIDs: Set<TaskID>
    private var consumedTokenCount: Int
    /// One actor for the full Cowork session lifetime. Its optional limit is
    /// reconfigured in place; it is never swapped when policy changes.
    private let tokenBudgetMeter: AgentTokenBudgetMeter
    private var schedulerSuspensionTokens: Set<UUID>
    /// Restore leaves this suspension held across host-side identity,
    /// permission-reviewer, and Goal recovery. Only an explicit
    /// `resumePendingTasks` releases it, so incidental attach/mailbox/policy
    /// operations cannot wake replayed work before recovery is safe.
    private var startupSchedulerSuspension: UUID?
    private var schedulerResumeRequested: Bool
    private var schedulerSuspended: Bool { !schedulerSuspensionTokens.isEmpty }
    private let reasoningEffort: ReasoningEffort?
    private let includeUsage: Bool
    private let maxSteps: Int
    /// Host-approved profiles that model-authored spawn requests may select.
    /// Existing agents/tasks always retain their exact binding revision.
    private var availableInferenceProfiles: [InferenceProfileID: AgentInferenceBinding]
    /// Safe, configuration-declared capabilities for the current host catalog.
    /// Missing metadata is never inferred from a vendor or model name.
    private var availableInferenceProfileRoutingMetadata:
        [InferenceProfileID: InferenceProfileRoutingMetadata]
    private let requiresInferenceBindings: Bool
    /// Shipping per-agent runtimes resolve one atomic route tuple. The
    /// Orchestrator, rather than each app, validates that tuple against the
    /// live Agent before exposing its provider to AgentLoop.
    private let resolvedInferenceFor: (@Sendable (Agent) async throws -> ResolvedInferenceProfile)?
    private let providerFor: @Sendable (Agent) async throws -> ToolCallingProvider
    private let imageGeneratorFor: @Sendable (Agent) async -> ImageGenerationToolService?
    private let imageResolver: AgentImageResolver?
    private let toolSnapshotProvider:
        ToolSnapshotProvider?
    /// Optional host-owned internal tools. IntatisCowork remains independent
    /// of every concrete implementation (including IntatisKnowledge).
    private let internalToolRegistryAugmenter:
        HostToolRegistryAugmenter?
    private let sessionNaming: SessionNamingService?
    /// Test-only failure injection that runs before the production atomic
    /// task-completed/message-consumed EventLog batch. It never substitutes
    /// for durable persistence.
    private var messageConsumptionPreflightForTesting:
        (@Sendable ([AgentMessageConsumedPayload]) async throws -> Void)?
    private var taskLifecycleEventAppender: (@Sendable (Event) async throws -> Void)?
    private var terminalPersistenceFailures: [TaskID: String]
    private var terminalCommitTaskIDs: Set<TaskID>
    private var taskStartGate: (@Sendable (TaskID) async -> Void)?
    private var cancelAllBeforeResumeHook: (@Sendable () async -> Void)?
    private var admissionEventAppender: (@Sendable (Event) async throws -> Void)?
    private var admissionEventsAppender: (@Sendable ([Event]) async throws -> Void)?
    private var admissionLocked: Bool
    private var admissionWaiters: [CheckedContinuation<Void, Never>]
    private var executionPolicyUpdateLocked: Bool
    private var executionPolicyUpdateWaiters: [CheckedContinuation<Void, Never>]
    private var executionPolicyUpdateInProgress: Bool

    /// Shipping constructor for legacy/session-wide provider routing. It
    /// atomically acquires and retains the process-level EventLog writer lease
    /// before any scheduler exists, but cannot enable exact per-agent bindings.
    public static func runtime(
        log: EventLog,
        mediator: Mediator = Mediator(),
        engine: PermissionEngine = PermissionEngine(),
        allowsShell: Bool,
        responder: PermissionResponder,
        reasoningEffort: ReasoningEffort? = nil,
        includeUsage: Bool = false,
        maxSteps: Int = AgentRuntime.defaultCoworkMaxIterations,
        executionPolicy: CoworkExecutionPolicy = .default,
        taskGraphPolicy: TaskGraphPolicy = .default,
        skillRootAccess: SkillRootAccess = .workspaceOnly,
        availableInferenceProfiles: [AgentInferenceBinding] = [],
        inferenceProfileRoutingMetadata: [InferenceProfileRoutingMetadata] = [],
        requiresInferenceBindings: Bool = false,
        imageGeneratorFor: @escaping @Sendable (Agent) async -> ImageGenerationToolService? = { _ in nil },
        imageResolver: AgentImageResolver? = nil,
        toolSnapshotProvider:
            ToolSnapshotProvider? = nil,
        internalToolRegistryAugmenter:
            HostToolRegistryAugmenter? = nil,
        sessionNaming: SessionNamingService? = nil,
        providerFor: @escaping @Sendable (Agent) async throws -> ToolCallingProvider
    ) throws -> Orchestrator {
        guard !requiresInferenceBindings else {
            throw IntatisError.config(
                "exact per-agent inference requires the atomic resolvedInferenceFor runtime constructor")
        }
        let writerLease = try log.acquireWriterLease()
        return Orchestrator(
            log: log,
            mediator: mediator,
            engine: engine,
            allowsShell: allowsShell,
            responder: responder,
            reasoningEffort: reasoningEffort,
            includeUsage: includeUsage,
            maxSteps: maxSteps,
            executionPolicy: executionPolicy,
            taskGraphPolicy: taskGraphPolicy,
            skillRootAccess: skillRootAccess,
            availableInferenceProfiles: availableInferenceProfiles,
            inferenceProfileRoutingMetadata: inferenceProfileRoutingMetadata,
            requiresInferenceBindings: requiresInferenceBindings,
            imageGeneratorFor: imageGeneratorFor,
            imageResolver: imageResolver,
            toolSnapshotProvider:
                toolSnapshotProvider,
            internalToolRegistryAugmenter:
                internalToolRegistryAugmenter,
            sessionNaming: sessionNaming,
            writerLease: writerLease,
            providerFor: providerFor)
    }

    /// Shipping constructor for exact per-agent inference. Each resolution
    /// must atomically carry the immutable binding, model, and provider. The
    /// Orchestrator revalidates all three fields at every admission/preflight
    /// and immediately before AgentLoop receives the provider.
    public static func runtime(
        log: EventLog,
        mediator: Mediator = Mediator(),
        engine: PermissionEngine = PermissionEngine(),
        allowsShell: Bool,
        responder: PermissionResponder,
        reasoningEffort: ReasoningEffort? = nil,
        includeUsage: Bool = false,
        maxSteps: Int = AgentRuntime.defaultCoworkMaxIterations,
        executionPolicy: CoworkExecutionPolicy = .default,
        taskGraphPolicy: TaskGraphPolicy = .default,
        skillRootAccess: SkillRootAccess = .workspaceOnly,
        availableInferenceProfiles: [AgentInferenceBinding] = [],
        inferenceProfileRoutingMetadata: [InferenceProfileRoutingMetadata] = [],
        requiresInferenceBindings: Bool = true,
        imageGeneratorFor: @escaping @Sendable (Agent) async -> ImageGenerationToolService? = { _ in nil },
        imageResolver: AgentImageResolver? = nil,
        toolSnapshotProvider:
            ToolSnapshotProvider? = nil,
        internalToolRegistryAugmenter:
            HostToolRegistryAugmenter? = nil,
        sessionNaming: SessionNamingService? = nil,
        resolvedInferenceFor: @escaping @Sendable (Agent) async throws -> ResolvedInferenceProfile
    ) throws -> Orchestrator {
        let writerLease = try log.acquireWriterLease()
        return Orchestrator(
            log: log,
            mediator: mediator,
            engine: engine,
            allowsShell: allowsShell,
            responder: responder,
            reasoningEffort: reasoningEffort,
            includeUsage: includeUsage,
            maxSteps: maxSteps,
            executionPolicy: executionPolicy,
            taskGraphPolicy: taskGraphPolicy,
            skillRootAccess: skillRootAccess,
            availableInferenceProfiles: availableInferenceProfiles,
            inferenceProfileRoutingMetadata: inferenceProfileRoutingMetadata,
            requiresInferenceBindings: requiresInferenceBindings,
            imageGeneratorFor: imageGeneratorFor,
            imageResolver: imageResolver,
            toolSnapshotProvider:
                toolSnapshotProvider,
            internalToolRegistryAugmenter:
                internalToolRegistryAugmenter,
            sessionNaming: sessionNaming,
            writerLease: writerLease,
            resolvedInferenceFor: resolvedInferenceFor,
            providerFor: { agent in
                try await resolvedInferenceFor(agent).provider
            })
    }

    /// Internal unlocked constructor for isolated `@testable` unit tests.
    /// Other package targets cannot bypass the process-level session writer
    /// lease; shipping callers must use `runtime`.
    init(log: EventLog,
                mediator: Mediator = Mediator(),
                engine: PermissionEngine = PermissionEngine(),
                allowsShell: Bool,
                responder: PermissionResponder,
                reasoningEffort: ReasoningEffort? = nil,
                includeUsage: Bool = false,
                maxSteps: Int = AgentRuntime.defaultCoworkMaxIterations,
                executionPolicy: CoworkExecutionPolicy = .default,
                taskGraphPolicy: TaskGraphPolicy = .default,
                skillRootAccess: SkillRootAccess = .workspaceOnly,
                availableInferenceProfiles: [AgentInferenceBinding] = [],
                inferenceProfileRoutingMetadata: [InferenceProfileRoutingMetadata] = [],
                requiresInferenceBindings: Bool = false,
                imageGeneratorFor: @escaping @Sendable (Agent) async -> ImageGenerationToolService? = { _ in nil },
                imageResolver: AgentImageResolver? = nil,
                toolSnapshotProvider:
                    ToolSnapshotProvider? = nil,
                internalToolRegistryAugmenter:
                    HostToolRegistryAugmenter? = nil,
                sessionNaming: SessionNamingService? = nil,
                writerLease: EventLogWriterLease? = nil,
                resolvedInferenceFor: (@Sendable (Agent) async throws -> ResolvedInferenceProfile)? = nil,
                providerFor: @escaping @Sendable (Agent) async throws -> ToolCallingProvider) {
        self.log = log
        self.writerLease = writerLease
        self.registry = AgentRegistry()
        self.bus = MessageBus(log: log, mediator: mediator)
        self.engine = engine
        self.allowsShell = allowsShell
        self.skillRootAccess = skillRootAccess
        self.terminal = ProcessTerminalSessionManager()
        self.responder = responder
        self.automaticPermissionResponder = nil
        self.automaticPermissionReviewerAgentID = nil
        self.automaticPermissionReviewDisabling = false
        self.automaticPermissionReviewRecoveryFailure = nil
        self.capabilityLeases = [:]
        self.workspaceLeases = [:]
        self.capabilityLeaseHistory = [:]
        self.workspaceLeaseHistory = [:]
        self.defaultCapabilityLeaseIDs = [:]
        self.defaultWorkspaceLeaseIDs = [:]
        self.scheduler = AgentScheduler()
        self.taskGraph = TaskGraph(policy: taskGraphPolicy)
        self.workTaskGraph = WorkTaskGraph()
        self.workTaskRecoveryFailure = nil
        self.scheduledReplyTargets = [:]
        self.scheduledReplyFormats = [:]
        self.scheduledReplyResults = [:]
        self.spawnedAgentOwners = [:]
        self.automaticDelegationReservations = []
        self.executionPolicy = executionPolicy
        self.runningExecutions = [:]
        self.resultWaiters = [:]
        self.schedulerResultWaiterHookForTesting = nil
        self.idleWaiters = []
        self.rootInvocations = [:]
        self.cancellationReasons = [:]
        self.cancellationRunCloseSources = [:]
        self.cancelledGoalRunScopes = []
        self.continuationRunCloseClaims = [:]
        self.continuationRunCloseInstallations = [:]
        self.providerUsageLimitFailures = [:]
        self.restoredPendingTaskIDs = []
        self.consumedTokenCount = 0
        self.tokenBudgetMeter = AgentTokenBudgetMeter(limit: executionPolicy.tokenBudget)
        self.schedulerSuspensionTokens = []
        self.startupSchedulerSuspension = nil
        self.schedulerResumeRequested = false
        self.reasoningEffort = reasoningEffort
        self.includeUsage = includeUsage || executionPolicy.tokenBudget != nil
        self.maxSteps = maxSteps
        let approvedInferenceProfiles = Dictionary(
            availableInferenceProfiles.map { ($0.inferenceProfileID, $0) },
            uniquingKeysWith: { _, newest in newest })
        self.availableInferenceProfiles = approvedInferenceProfiles
        self.availableInferenceProfileRoutingMetadata = Dictionary(
            inferenceProfileRoutingMetadata.compactMap { metadata in
                guard approvedInferenceProfiles[
                    metadata.inferenceProfileID
                ] != nil else {
                    return nil
                }
                return (metadata.inferenceProfileID, metadata)
            },
            uniquingKeysWith: { _, newest in newest })
        self.requiresInferenceBindings = requiresInferenceBindings
        self.resolvedInferenceFor = resolvedInferenceFor
        self.providerFor = providerFor
        self.imageGeneratorFor = imageGeneratorFor
        self.imageResolver = imageResolver
        self.toolSnapshotProvider =
            toolSnapshotProvider
        self.internalToolRegistryAugmenter =
            internalToolRegistryAugmenter
        self.sessionNaming = sessionNaming
        self.messageConsumptionPreflightForTesting = nil
        self.taskLifecycleEventAppender = nil
        self.terminalPersistenceFailures = [:]
        self.terminalCommitTaskIDs = []
        self.taskStartGate = nil
        self.cancelAllBeforeResumeHook = nil
        self.admissionEventAppender = nil
        self.admissionEventsAppender = nil
        self.admissionLocked = false
        self.admissionWaiters = []
        self.executionPolicyUpdateLocked = false
        self.executionPolicyUpdateWaiters = []
        self.executionPolicyUpdateInProgress = false
    }

    /// Resolves provider and model-history limits from the same exact profile
    /// snapshot, then proves that snapshot still describes this live Agent.
    /// Legacy provider seams deliberately return `.unspecified`; neither they
    /// nor callers without model metadata may guess a window from a model slug.
    private func resolvedRuntimeInference(
        for agent: Agent
    ) async throws -> ResolvedAgentRuntimeInference {
        guard let resolvedInferenceFor else {
            return ResolvedAgentRuntimeInference(
                provider: try await providerFor(agent),
                modelContextPolicy: .unspecified,
                hostedWebSearch: nil)
        }
        guard let binding = agent.agentInferenceBinding,
              binding.modelID == agent.model else {
            throw IntatisError.config(
                "configurationUnresolved: agent inference binding and model differ")
        }
        let resolved = try await resolvedInferenceFor(agent)
        guard resolved.binding == binding,
              resolved.model == agent.model else {
            throw IntatisError.config(
                "configurationUnresolved: resolved inference profile does not match the agent binding and model")
        }
        return ResolvedAgentRuntimeInference(
            provider: resolved.provider,
            modelContextPolicy: resolved.modelContextPolicy,
            hostedWebSearch: resolved.hostedWebSearch)
    }

    /// Provider-only compatibility view used by admission preflight paths.
    private func resolvedProvider(for agent: Agent) async throws -> ToolCallingProvider {
        try await resolvedRuntimeInference(for: agent).provider
    }

    /// Freezes the reviewer identity and exact inference binding while giving
    /// every permission-review generation a newly resolved provider wrapper.
    /// Capture only the resolver seams and immutable Agent value: capturing
    /// this Orchestrator would create a responder/control-plane retain cycle.
    private func permissionReviewProviderFactory(
        for agent: Agent
    ) -> PermissionReviewProviderFactory {
        let frozenAgent = agent
        let exactResolver = resolvedInferenceFor
        let legacyProviderFor = providerFor
        return {
            guard let exactResolver else {
                return try await legacyProviderFor(frozenAgent)
            }
            guard let binding = frozenAgent.agentInferenceBinding,
                  binding.modelID == frozenAgent.model else {
                throw IntatisError.config(
                    "configurationUnresolved: reviewer inference binding and model differ")
            }
            let resolved = try await exactResolver(frozenAgent)
            guard resolved.binding == binding,
                  resolved.model == frozenAgent.model else {
                throw IntatisError.config(
                    "configurationUnresolved: resolved reviewer profile does not match its frozen binding and model")
            }
            return resolved.provider
        }
    }

    @discardableResult
    public func attach(_ agent: Agent,
                       admissionIssuer: AgentID? = nil,
                       causalParentTaskID: TaskID? = nil) async -> Bool {
        let id = agent.name
        guard !requiresInferenceBindings || agent.agentInferenceBinding != nil else {
            try? await log.append(.error(ErrorPayload(
                code: "inference_profile_unresolved",
                message: "@\(id.rawValue) requires an exact inference profile binding")))
            return false
        }
        if let validationError = Self.agentNameValidationError(id.rawValue) {
            try? await log.append(.error(ErrorPayload(
                code: "invalid_agent_name",
                message: validationError)))
            return false
        }
        guard id != Self.automaticPermissionReviewerID else {
            try? await log.append(.error(ErrorPayload(
                code: "reserved_agent",
                message: "@\(id.rawValue) is reserved for automatic permission review")))
            return false
        }
        guard registry.agent(id) == nil else {
            try? await log.append(.error(ErrorPayload(code: "agent_exists",
                                                       message: "agent @\(id.rawValue) already exists")))
            return false
        }

        let assessment = assessWorkspaceAttach(agent.workspaceRoot)
        var proposedAgent = agent
        if let canonical = assessment.canonical {
            proposedAgent.workspaceRoot = canonical
        }
        if requiresInferenceBindings {
            do {
                // Exact resolution is a creation invariant, not a first-turn
                // best effort. This performs no model request; it only proves
                // that the immutable revision, capability, and lazy credential
                // can be resolved before any admission fact becomes durable.
                _ = try await resolvedProvider(for: proposedAgent)
            } catch {
                try? await log.append(.error(ErrorPayload(
                    code: "inference_profile_unresolved",
                    message: "@\(id.rawValue) exact inference profile revision is unavailable or incompatible")))
                return false
            }
        }
        // This is only the target profile's host-catalog snapshot. A direct
        // host attach may legitimately use a retained exact revision that is
        // not a future-agent choice, so nil is meaningful and must remain nil
        // throughout review/revalidation rather than being treated as a
        // fallback to the catalog's current entry.
        let reviewedCatalogBinding = proposedAgent.agentInferenceBinding.flatMap {
            availableInferenceProfiles[$0.inferenceProfileID]
        }
        // Freeze the exact leases before review. The same values are embedded in
        // the durable review task and committed after allow; regenerating them
        // after review would create an admission TOCTOU boundary.
        let proposedLeases = prepareDefaultLeases(for: proposedAgent)
        let requestID = RequestID.new()
        let admissionTaskID = TaskID.new()
        let admissionRootTaskID = causalParentTaskID.flatMap {
            taskGraph.node($0)?.rootTaskID
        } ?? causalParentTaskID ?? admissionTaskID
        let admissionAttempt = 1
        let assessedPath = proposedAgent.workspaceRoot.path
        let canCoordinate = proposedAgent.coordinationDepth > 0
        let admissionRole = canCoordinate ? "coordinator" : "worker"
        let admissionContract = TaskContract(
            id: admissionTaskID,
            kind: .agentAdmission,
            issuer: admissionIssuer,
            assignee: proposedAgent.name,
            parentTaskID: causalParentTaskID,
            objective: "Attach @\(proposedAgent.name.rawValue) to \(assessedPath) as a \(admissionRole).",
            roleHint: "agent workspace admission",
            expectedDeliverable: "Durably attach the agent with exactly the reviewed workspace and capability leases.",
            workspaceID: proposedLeases.workspace.workspaceID,
            workspaceLeaseID: proposedLeases.workspace.id,
            capabilityLeaseID: proposedLeases.capability.id,
            agentInferenceBinding: proposedAgent.agentInferenceBinding,
            relatedAgents: admissionIssuer.map { [$0] } ?? [],
            relatedTasks: causalParentTaskID.map { [$0] } ?? [],
            constraints: [
                "coordinationDepth=\(proposedAgent.coordinationDepth)",
                "canCoordinate=\(canCoordinate)",
                "persistentDefaultLeases=true",
            ],
            replyMode: TaskReplyMode.none,
            maxAttempts: 1)
        var admissionLineage = [admissionRootTaskID]
        if let causalParentTaskID, !admissionLineage.contains(causalParentTaskID) {
            admissionLineage.append(causalParentTaskID)
        }
        if !admissionLineage.contains(admissionTaskID) {
            admissionLineage.append(admissionTaskID)
        }
        let normalizedAttachArgs = attachArgs(
            agent: proposedAgent,
            canonicalPath: assessedPath,
            admissionTaskID: admissionTaskID,
            capabilityLease: proposedLeases.capability,
            workspaceLease: proposedLeases.workspace)
        let attachIntent = PermissionIntent(
            action: "workspace.attach",
            resources: [
                PermissionResource(kind: .agent, value: proposedAgent.name.rawValue),
                PermissionResource(
                    kind: .workspace,
                    value: assessedPath,
                    access: proposedLeases.workspace.access),
            ],
            metadata: [
                "model": .string(proposedAgent.model.rawValue),
                "canCoordinate": .bool(canCoordinate),
            ].merging(Self.inferenceMetadata(proposedAgent.agentInferenceBinding)) { _, profile in profile },
            dataEffects: [.none],
            controlEffects: [.attachWorkspace, .grantCapability],
            risks: [.controlPlaneMutation, .capabilityGrant, .workspaceExpansion],
            replayPolicy: .doNotReplay)
        let attachGate = PermissionReviewGateSnapshot(
            decision: assessment.canAskUser ? .ask : .deny,
            risk: assessment.risk,
            reason: assessment.reason,
            policyVersion: IntatisHostApplication.identity
                .namespacedIdentifier("workspace-admission.v1"))
        let attachAuthorization = ResolvedToolAuthorization(
            authorizationID: IDGen.random(prefix: "tool-authorization"),
            registryVersion: IntatisHostApplication.identity
                .namespacedIdentifier("cowork.admission.v1"),
            concreteToolID: IntatisHostApplication.identity
                .namespacedIdentifier("cowork.admission.v1")
                + "/agent.attach",
            descriptorFingerprint: ToolRegistry.authorizationDigest(
                "agent.attach|workspace.attach|v1"),
            toolName: "agent.attach",
            canonicalAction: attachIntent.action,
            requiredCapabilities: [],
            membership: .notRequired,
            capabilityLeaseID: proposedLeases.capability.id,
            capabilityTaskID: proposedLeases.capability.taskID,
            workspaceLeaseID: proposedLeases.workspace.id,
            workspaceAccess: proposedLeases.workspace.access,
            workspaceRootIdentity: proposedLeases.workspace.rootIdentity,
            invocation: ToolAuthorizationInvocationContext(
                sessionID: await log.sessionID,
                agent: proposedAgent.name,
                taskID: admissionTaskID,
                rootTaskID: admissionRootTaskID,
                parentTaskID: causalParentTaskID,
                attempt: admissionAttempt,
                toolCallID: "agent-attach:\(requestID.rawValue)",
                taskObjective: String(admissionContract.objective.prefix(1_200))),
            normalizedArgumentsDigest: ToolRegistry.authorizationDigest(normalizedAttachArgs),
            normalizedArgumentsCharacterCount: normalizedAttachArgs.count,
            intent: attachIntent,
            sideEffect: .write,
            risksNetwork: false,
            replayPolicy: .doNotReplay,
            deterministicGate: attachGate,
            capabilityLeaseFingerprint: ToolRegistry.authorizationFingerprint(
                proposedLeases.capability),
            workspaceID: proposedLeases.workspace.workspaceID,
            workspaceTaskID: proposedLeases.workspace.taskID,
            workspaceRootPath: proposedLeases.workspace.rootPath,
            workspaceLeaseFingerprint: ToolRegistry.authorizationFingerprint(
                proposedLeases.workspace),
            targetAgentInferenceBinding: proposedAgent.agentInferenceBinding)
        let request = PermissionRequestPayload(
            requestId: requestID,
            agent: proposedAgent.name,
            tool: "agent.attach",
            args: normalizedAttachArgs,
            risk: assessment.risk,
            reason: assessment.reason,
            context: PermissionRequestContext(
                taskID: admissionTaskID,
                rootTaskID: admissionRootTaskID,
                parentTaskID: causalParentTaskID,
                attempt: admissionAttempt,
                toolCallID: "agent-attach:\(requestID.rawValue)",
                normalizedArgs: normalizedAttachArgs,
                touchedPaths: [],
                risksNetwork: false,
                sideEffect: .write,
                intent: attachIntent,
                gate: attachGate,
                capabilityLease: proposedLeases.capability,
                workspaceLease: proposedLeases.workspace,
                taskContract: admissionContract,
                causalContext: PermissionReviewCausalContext(
                    userGoal: admissionContract.objective,
                    issuer: admissionIssuer,
                    assignee: proposedAgent.name,
                    taskLineage: admissionLineage,
                    relatedAgents: admissionContract.relatedAgents),
                authorization: attachAuthorization,
                executionID: "agent-admission:\(admissionTaskID.rawValue)",
                replayPolicy: ToolExecutionReplayPolicy.doNotReplay.rawValue))
        let agentMetadata = taskMetadata(
            contract: admissionContract,
            rootTaskID: admissionRootTaskID,
            parentTaskID: causalParentTaskID,
            sender: admissionIssuer,
            recipient: proposedAgent.name,
            scope: .agent,
            visibility: .global)
        let workspaceMetadata = taskMetadata(
            contract: admissionContract,
            rootTaskID: admissionRootTaskID,
            parentTaskID: causalParentTaskID,
            sender: admissionIssuer,
            recipient: proposedAgent.name,
            scope: .workspace,
            visibility: .global)
        let capabilityMetadata = taskMetadata(
            contract: admissionContract,
            rootTaskID: admissionRootTaskID,
            parentTaskID: causalParentTaskID,
            sender: admissionIssuer,
            recipient: proposedAgent.name,
            scope: .capability,
            visibility: .global)
        do {
            try await appendAdmissionEvents([
                .agentAttachRequested(AgentAttachRequestedPayload(
                    agent: proposedAgent.name,
                    path: assessedPath,
                    model: proposedAgent.model,
                    profile: proposedAgent.profile.rawValue,
                    metadata: agentMetadata)),
                .workspaceLeaseRequested(WorkspaceLeaseRequestedPayload(
                    agent: proposedAgent.name,
                    rootPath: assessedPath,
                    access: proposedLeases.workspace.access,
                    reason: assessment.reason,
                    metadata: workspaceMetadata)),
                .permissionRequest(request),
            ])
        } catch {
            try? await log.append(.error(ErrorPayload(
                code: "agent_attach_request_persistence_failed",
                message: error.localizedDescription)))
            return false
        }

        guard assessment.canAskUser else {
            try? await appendAdmissionEvents([
                .permissionResolved(PermissionResolvedPayload(
                    requestId: requestID, tool: "agent.attach", decision: .deny,
                    risk: assessment.risk, reason: assessment.reason, intent: attachIntent,
                    authorization: attachAuthorization,
                    source: .deterministicPolicy)),
                .workspaceLeaseDenied(WorkspaceLeaseDeniedPayload(
                    agent: proposedAgent.name,
                    rootPath: assessedPath,
                    reason: assessment.reason,
                    metadata: workspaceMetadata)),
            ])
            return false
        }

        let permissionResponder = activePermissionResponder()
        let reviewedResolution: PermissionApprovalResolution
        switch permissionResponder.approvalMode {
        case .manual:
            reviewedResolution = await permissionResponder.requestResolution(request)
        case .automaticReviewer:
            if let automaticResponder = permissionResponder as? AgentPermissionResponder {
                reviewedResolution = await automaticResponder
                    .requestHostAgentAdmissionResolution(request)
            } else {
                reviewedResolution = PermissionApprovalResolution(
                    decision: .deny,
                    reason: "automatic agent admission reviewer is unavailable",
                    risk: assessment.risk,
                    source: .automaticReviewerFailure,
                    reviewStatus: .failed,
                    failureKind: .authorizationContextUnavailable,
                    failureSource: .reviewerFailed)
            }
        }
        // A responder may finish concurrently with caller cancellation. Never
        // let a direct host admission path treat that stale allow as authority;
        // AgentLoop has its own equivalent post-review cancellation fence.
        let resolution: PermissionApprovalResolution
        if Task.isCancelled {
            resolution = PermissionApprovalResolution(
                decision: .deny,
                reason: "agent attach caller cancelled after permission review",
                risk: reviewedResolution.risk ?? assessment.risk,
                source: .callerCancellation,
                reviewTaskID: reviewedResolution.reviewTaskID,
                reviewStatus: .cancelled,
                failureKind: .callerCancelled)
        } else {
            resolution = reviewedResolution
        }
        guard resolution.decision == .allow else {
            let suppliedReason = resolution.reason?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let denialReason = (suppliedReason?.isEmpty == false ? suppliedReason : nil)
                ?? "permission denied workspace attach"
            try? await appendAdmissionEvents([
                .permissionResolved(PermissionResolvedPayload(
                    requestId: requestID, tool: "agent.attach", decision: .deny,
                    risk: resolution.risk ?? assessment.risk,
                    reason: denialReason, intent: attachIntent,
                    authorization: attachAuthorization,
                    source: resolution.source,
                    reviewTaskID: resolution.reviewTaskID,
                    reviewStatus: resolution.reviewStatus,
                    failureKind: resolution.failureKind)),
                .workspaceLeaseDenied(WorkspaceLeaseDeniedPayload(
                    agent: proposedAgent.name,
                    rootPath: assessedPath,
                    reason: denialReason,
                    metadata: workspaceMetadata)),
            ])
            return false
        }
        let suppliedApprovalReason = resolution.reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let approvalReason = (suppliedApprovalReason?.isEmpty == false
            ? suppliedApprovalReason
            : nil) ?? "permission approved workspace attach"

        // Permission review is an async boundary. Resolve the exact tuple
        // again after allow, then compare the target profile's live host
        // catalog snapshot after the await. The custom admission lock is not
        // held across resolver work, avoiding a resolver -> Orchestrator lock
        // cycle while still preventing a catalog mutation from crossing the
        // durable admission boundary.
        var catalogBindingBeforeResolution: AgentInferenceBinding?
        if requiresInferenceBindings {
            await acquireAdmissionLock()
            catalogBindingBeforeResolution = proposedAgent.agentInferenceBinding.flatMap {
                availableInferenceProfiles[$0.inferenceProfileID]
            }
            releaseAdmissionLock()
            do {
                _ = try await resolvedProvider(for: proposedAgent)
            } catch {
                await persistAttachAuthorizationRevalidationDenial(
                    requestID: requestID,
                    proposedAgent: proposedAgent,
                    assessedPath: assessedPath,
                    reason: "exact inference profile changed or became unavailable during permission review",
                    risk: resolution.risk ?? assessment.risk,
                    intent: attachIntent,
                    authorization: attachAuthorization,
                    workspaceMetadata: workspaceMetadata,
                    reviewResolution: resolution)
                return false
            }
        }

        await acquireAdmissionLock()
        if requiresInferenceBindings {
            let liveCatalogBinding = proposedAgent.agentInferenceBinding.flatMap {
                availableInferenceProfiles[$0.inferenceProfileID]
            }
            guard reviewedCatalogBinding == catalogBindingBeforeResolution,
                  catalogBindingBeforeResolution == liveCatalogBinding else {
                let reason = "host-approved inference profile changed during permission review"
                await persistAttachAuthorizationRevalidationDenial(
                    requestID: requestID,
                    proposedAgent: proposedAgent,
                    assessedPath: assessedPath,
                    reason: reason,
                    risk: resolution.risk ?? assessment.risk,
                    intent: attachIntent,
                    authorization: attachAuthorization,
                    workspaceMetadata: workspaceMetadata,
                    reviewResolution: resolution)
                releaseAdmissionLock()
                return false
            }
        }
        guard registry.agent(id) == nil else {
            try? await log.append(.permissionResolved(PermissionResolvedPayload(
                requestId: requestID, tool: "agent.attach", decision: .deny,
                risk: .medium, reason: "agent already exists", intent: attachIntent,
                authorization: attachAuthorization,
                source: .authorizationRevalidation,
                reviewTaskID: resolution.reviewTaskID)))
            releaseAdmissionLock()
            return false
        }
        let reviewedWorkspace = proposedLeases.workspace
        guard let reviewedIdentity = reviewedWorkspace.rootIdentity,
              reviewedIdentity.matchesCurrentDirectory(rootPath: reviewedWorkspace.rootPath) else {
            let reason = "workspace root identity changed during permission review"
            do {
                try await appendAdmissionEvents([
                    .permissionResolved(PermissionResolvedPayload(
                        requestId: requestID,
                        tool: "agent.attach",
                        decision: .deny,
                        risk: .high,
                        reason: reason,
                        intent: attachIntent,
                        authorization: attachAuthorization,
                        source: .authorizationRevalidation,
                        reviewTaskID: resolution.reviewTaskID)),
                    .workspaceLeaseDenied(WorkspaceLeaseDeniedPayload(
                        agent: proposedAgent.name,
                        rootPath: assessedPath,
                        reason: reason,
                        metadata: workspaceMetadata)),
                ])
            } catch {
                try? await log.append(.error(ErrorPayload(
                    code: "agent_attach_identity_denial_persistence_failed",
                    message: error.localizedDescription)))
            }
            releaseAdmissionLock()
            return false
        }
        // This check is the cancellation linearization point for durable host
        // admission. Cancellation observed after review but while exact
        // inference resolution or the admission lock was suspended must win;
        // once this check passes, the atomic append below owns the commit.
        if Task.isCancelled {
            let reason = "agent attach caller cancelled before durable admission"
            do {
                try await appendAdmissionEvents([
                    .permissionResolved(PermissionResolvedPayload(
                        requestId: requestID,
                        tool: "agent.attach",
                        decision: .deny,
                        risk: resolution.risk ?? assessment.risk,
                        reason: reason,
                        intent: attachIntent,
                        authorization: attachAuthorization,
                        source: .callerCancellation,
                        reviewTaskID: resolution.reviewTaskID,
                        reviewStatus: .cancelled,
                        failureKind: .callerCancelled)),
                    .workspaceLeaseDenied(WorkspaceLeaseDeniedPayload(
                        agent: proposedAgent.name,
                        rootPath: assessedPath,
                        reason: reason,
                        metadata: workspaceMetadata)),
                ])
            } catch {
                try? await log.append(.error(ErrorPayload(
                    code: "agent_attach_cancellation_denial_persistence_failed",
                    message: error.localizedDescription)))
            }
            releaseAdmissionLock()
            return false
        }
        do {
            try await appendAdmissionEvents([
                .permissionResolved(PermissionResolvedPayload(
                    requestId: requestID, tool: "agent.attach", decision: .allow,
                    risk: resolution.risk ?? assessment.risk,
                    reason: approvalReason,
                    intent: attachIntent,
                    authorization: attachAuthorization,
                    source: resolution.source,
                    reviewTaskID: resolution.reviewTaskID,
                    reviewStatus: resolution.reviewStatus,
                    failureKind: resolution.failureKind)),
                .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                    agent: proposedAgent.name,
                    lease: proposedLeases.workspace,
                    metadata: workspaceMetadata)),
                .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                    agent: proposedAgent.name,
                    lease: proposedLeases.capability,
                    metadata: capabilityMetadata)),
                .agentAttached(AgentAttachedPayload(
                    agent: proposedAgent.name, path: proposedAgent.workspaceRoot.path, model: proposedAgent.model,
                    profile: proposedAgent.profile.rawValue,
                    agentInferenceBinding: proposedAgent.agentInferenceBinding,
                    metadata: agentMetadata)),
            ])
        } catch {
            try? await log.append(.error(ErrorPayload(
                code: "agent_attach_admission_persistence_failed",
                message: error.localizedDescription)))
            releaseAdmissionLock()
            return false
        }
        registry.add(proposedAgent)
        commitDefaultLeases(proposedLeases, for: proposedAgent.name)
        releaseAdmissionLock()
        await enqueuePendingMailboxWakeIfNeeded(for: proposedAgent.name)
        return true
    }

    /// Establishes the fixed `@main` identity for a brand-new Cowork session.
    ///
    /// The caller's explicit primary-workspace selection is the authorization
    /// for this one bootstrap admission. This path is deliberately narrower
    /// than ordinary `attach`: it accepts only `@main`, only while both the
    /// durable session and runtime roster are empty, and still canonicalizes
    /// and rejects broad or sensitive workspace roots. Every later agent or
    /// workspace expansion continues through the normal permission flow.
    @discardableResult
    public func bootstrapMainAgent(_ agent: Agent) async -> CoworkSessionBootstrapResult {
        guard agent.name == Self.mainAgentID else {
            return .failed("Cowork session bootstrap only accepts @\(Self.mainAgentID.rawValue).")
        }
        if let validationError = Self.agentNameValidationError(agent.name.rawValue) {
            return .failed(validationError)
        }
        guard !requiresInferenceBindings || agent.agentInferenceBinding != nil else {
            return .failed("@main requires an exact inference profile binding.")
        }

        let assessment = assessWorkspaceAttach(agent.workspaceRoot)
        guard assessment.canAskUser, let canonical = assessment.canonical else {
            return .failed(assessment.reason)
        }
        var proposedAgent = agent
        proposedAgent.workspaceRoot = canonical
        if requiresInferenceBindings {
            do {
                _ = try await resolvedProvider(for: proposedAgent)
            } catch {
                return .failed("@main exact inference profile revision is unavailable or incompatible.")
            }
        }
        let reviewedCatalogBinding = proposedAgent.agentInferenceBinding.flatMap {
            availableInferenceProfiles[$0.inferenceProfileID]
        }
        let proposedLeases = prepareDefaultLeases(for: proposedAgent)

        // First wait for all earlier admissions to settle, then re-resolve the
        // exact route outside the custom lock. A second locked preflight below
        // verifies that neither the empty-session facts nor the target catalog
        // entry changed across that await. This closes the admission-wait race
        // without holding the lock across an external resolver.
        await acquireAdmissionLock()
        if registry.agent(Self.mainAgentID) != nil {
            releaseAdmissionLock()
            return .alreadyAttached(Self.mainAgentID)
        }
        guard registry.isEmpty else {
            releaseAdmissionLock()
            return .failed("Initial @main bootstrap requires an empty agent roster.")
        }
        do {
            guard try await log.isEmptyChecked() else {
                releaseAdmissionLock()
                return .failed("Initial @main bootstrap is only available for an empty Cowork session.")
            }
        } catch {
            releaseAdmissionLock()
            return .failed(
                "Initial @main bootstrap could not verify an empty Cowork event log: \(error.localizedDescription)")
        }
        let catalogBindingBeforeResolution = proposedAgent.agentInferenceBinding.flatMap {
            availableInferenceProfiles[$0.inferenceProfileID]
        }
        releaseAdmissionLock()

        if requiresInferenceBindings {
            do {
                _ = try await resolvedProvider(for: proposedAgent)
            } catch {
                return .failed(
                    "@main exact inference profile changed or became unavailable before durable admission.")
            }
        }

        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        if registry.agent(Self.mainAgentID) != nil {
            return .alreadyAttached(Self.mainAgentID)
        }
        guard registry.isEmpty else {
            return .failed("Initial @main bootstrap requires an empty agent roster.")
        }
        do {
            guard try await log.isEmptyChecked() else {
                return .failed("Initial @main bootstrap is only available for an empty Cowork session.")
            }
        } catch {
            return .failed(
                "Initial @main bootstrap could not verify an empty Cowork event log: \(error.localizedDescription)")
        }
        if requiresInferenceBindings {
            let liveCatalogBinding = proposedAgent.agentInferenceBinding.flatMap {
                availableInferenceProfiles[$0.inferenceProfileID]
            }
            guard reviewedCatalogBinding == catalogBindingBeforeResolution,
                  catalogBindingBeforeResolution == liveCatalogBinding else {
                return .failed("@main host-approved inference profile changed before durable admission.")
            }
        }

        let agentMetadata = CoworkEventMetadata(
            agentID: proposedAgent.name,
            workspaceID: proposedLeases.workspace.workspaceID,
            workspaceLeaseID: proposedLeases.workspace.id,
            capabilityLeaseID: proposedLeases.capability.id,
            scope: .agent)
        let workspaceMetadata = CoworkEventMetadata(
            agentID: proposedAgent.name,
            workspaceID: proposedLeases.workspace.workspaceID,
            workspaceLeaseID: proposedLeases.workspace.id,
            scope: .workspace)
        let capabilityMetadata = CoworkEventMetadata(
            agentID: proposedAgent.name,
            capabilityLeaseID: proposedLeases.capability.id,
            scope: .capability)

        do {
            try await appendAdmissionEvents([
                .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                    agent: proposedAgent.name,
                    lease: proposedLeases.workspace,
                    metadata: workspaceMetadata)),
                .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                    agent: proposedAgent.name,
                    lease: proposedLeases.capability,
                    metadata: capabilityMetadata)),
                .agentAttached(AgentAttachedPayload(
                    agent: proposedAgent.name,
                    path: proposedAgent.workspaceRoot.path,
                    model: proposedAgent.model,
                    profile: proposedAgent.profile.rawValue,
                    agentInferenceBinding: proposedAgent.agentInferenceBinding,
                    metadata: agentMetadata)),
            ])
        } catch {
            return .failed("Initial @main admission could not be persisted: \(error.localizedDescription)")
        }

        registry.add(proposedAgent)
        commitDefaultLeases(proposedLeases, for: proposedAgent.name)
        return .attached(proposedAgent.name)
    }

    /// Repairs a historical Cowork session whose canonical settings and
    /// workspace authorization survived but whose durable @main registration
    /// is missing. This is a host-control-plane recovery path: it never asks a
    /// model for permission and is unavailable for an empty/fresh session.
    /// The exact settings snapshot, inference binding, workspace identity, and
    /// absence of stale @main leases are revalidated immediately before the
    /// three registration events are appended atomically.
    @discardableResult
    public func restoreHistoricalMainAgent(
        _ agent: Agent,
        settings rawSettings: CoworkSessionSettings,
        hostAuthorized: Bool
    ) async -> CoworkSessionBootstrapResult {
        guard hostAuthorized else {
            return .failed("Historical @main recovery requires explicit host authorization.")
        }
        guard agent.name == Self.mainAgentID else {
            return .failed("Historical Cowork recovery only accepts @\(Self.mainAgentID.rawValue).")
        }
        if let validationError = Self.agentNameValidationError(agent.name.rawValue) {
            return .failed(validationError)
        }
        guard !requiresInferenceBindings || agent.agentInferenceBinding != nil else {
            return .failed("@main requires an exact inference profile binding.")
        }

        let sessionID = await log.sessionID
        var settings = rawSettings
        // Provider identifiers are non-canonical compatibility metadata and
        // are deliberately absent from EventLog settings snapshots.
        settings.defaultProviderID = nil
        let primaryWorkspaces = settings.workspaces.filter(\.isPrimary)
        guard settings.schemaVersion == CoworkSessionSettings.currentSchemaVersion,
              settings.sessionID == sessionID,
              settings.mainAgentName == Self.mainAgentID.rawValue,
              settings.defaultInferenceProfileBinding == agent.agentInferenceBinding,
              settings.defaultModelID == nil || settings.defaultModelID == agent.model.rawValue,
              settings.defaultPermissionProfile == agent.profile.rawValue,
              primaryWorkspaces.count == 1,
              let primary = primaryWorkspaces.first else {
            return .failed("Historical Cowork settings do not match the fixed @main registration.")
        }

        let assessment = assessWorkspaceAttach(agent.workspaceRoot)
        guard assessment.canAskUser, let canonical = assessment.canonical else {
            return .failed(assessment.reason)
        }
        guard URL(fileURLWithPath: primary.path).standardizedFileURL.resolvingSymlinksInPath()
                == canonical.standardizedFileURL.resolvingSymlinksInPath() else {
            return .failed("Historical Cowork settings do not match the authorized primary workspace.")
        }

        var proposedMain = agent
        proposedMain.workspaceRoot = canonical
        if requiresInferenceBindings {
            do {
                _ = try await resolvedProvider(for: proposedMain)
            } catch {
                return .failed("@main exact inference profile revision is unavailable or incompatible.")
            }
        }
        let reviewedCatalogBinding = proposedMain.agentInferenceBinding.flatMap {
            availableInferenceProfiles[$0.inferenceProfileID]
        }
        let proposedLeases = prepareDefaultLeases(for: proposedMain)

        await acquireAdmissionLock()
        if registry.agent(Self.mainAgentID) != nil {
            releaseAdmissionLock()
            return .alreadyAttached(Self.mainAgentID)
        }
        let catalogBindingBeforeResolution = proposedMain.agentInferenceBinding.flatMap {
            availableInferenceProfiles[$0.inferenceProfileID]
        }
        do {
            let envelopes = try await log.replayChecked()
            let canonicalSettings = try SessionProjectionStore.canonicalSessionSettings(
                from: envelopes,
                session: sessionID)
            let projection = CoworkProjection.build(from: envelopes)
            guard !envelopes.isEmpty,
                  canonicalSettings?.kind == .cowork,
                  canonicalSettings?.cowork.map({
                      Self.historicalRecoverySettingsMatch($0, settings)
                  }) == true,
                  projection.agentRoster[Self.mainAgentID] == nil,
                  !projection.workspaceLeaseAgents.values.contains(Self.mainAgentID),
                  !projection.capabilityLeaseAgents.values.contains(Self.mainAgentID) else {
                releaseAdmissionLock()
                return .failed("Historical @main recovery preconditions are not satisfied.")
            }
        } catch {
            releaseAdmissionLock()
            return .failed("Historical @main recovery could not verify the event log: \(error.localizedDescription)")
        }
        releaseAdmissionLock()

        if requiresInferenceBindings {
            do {
                _ = try await resolvedProvider(for: proposedMain)
            } catch {
                return .failed("@main exact inference profile changed before durable recovery.")
            }
        }

        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        if registry.agent(Self.mainAgentID) != nil {
            return .alreadyAttached(Self.mainAgentID)
        }
        if requiresInferenceBindings {
            let liveCatalogBinding = proposedMain.agentInferenceBinding.flatMap {
                availableInferenceProfiles[$0.inferenceProfileID]
            }
            guard reviewedCatalogBinding == catalogBindingBeforeResolution,
                  catalogBindingBeforeResolution == liveCatalogBinding else {
                return .failed("@main host-approved inference profile changed before durable recovery.")
            }
        }
        guard let reviewedIdentity = proposedLeases.workspace.rootIdentity,
              reviewedIdentity.matchesCurrentDirectory(rootPath: proposedLeases.workspace.rootPath) else {
            return .failed("The primary workspace identity changed before durable recovery.")
        }

        let agentMetadata = CoworkEventMetadata(
            agentID: proposedMain.name,
            workspaceID: proposedLeases.workspace.workspaceID,
            workspaceLeaseID: proposedLeases.workspace.id,
            capabilityLeaseID: proposedLeases.capability.id,
            scope: .agent)
        let workspaceMetadata = CoworkEventMetadata(
            agentID: proposedMain.name,
            workspaceID: proposedLeases.workspace.workspaceID,
            workspaceLeaseID: proposedLeases.workspace.id,
            scope: .workspace)
        let capabilityMetadata = CoworkEventMetadata(
            agentID: proposedMain.name,
            capabilityLeaseID: proposedLeases.capability.id,
            scope: .capability)
        let registrationEvents: [Event] = [
                .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                    agent: proposedMain.name,
                    lease: proposedLeases.workspace,
                    metadata: workspaceMetadata)),
                .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                    agent: proposedMain.name,
                    lease: proposedLeases.capability,
                    metadata: capabilityMetadata)),
                .agentAttached(AgentAttachedPayload(
                    agent: proposedMain.name,
                    path: proposedMain.workspaceRoot.path,
                    model: proposedMain.model,
                    profile: proposedMain.profile.rawValue,
                    agentInferenceBinding: proposedMain.agentInferenceBinding,
                    metadata: agentMetadata)),
        ]
        let recoverySettings = settings
        do {
            // The history predicate and the three-event append share the same
            // EventLog cross-process lock. A concurrent settings update can no
            // longer land between revalidation and registration.
            let persisted = try await log.appendSessionStateTransaction { envelopes in
                let canonicalSettings = try SessionProjectionStore.canonicalSessionSettings(
                    from: envelopes,
                    session: sessionID)
                let projection = CoworkProjection.build(from: envelopes)
                guard !envelopes.isEmpty,
                      canonicalSettings?.kind == .cowork,
                      canonicalSettings?.cowork.map({
                          Self.historicalRecoverySettingsMatch($0, recoverySettings)
                      }) == true,
                      projection.agentRoster[Self.mainAgentID] == nil,
                      !projection.workspaceLeaseAgents.values.contains(Self.mainAgentID),
                      !projection.capabilityLeaseAgents.values.contains(Self.mainAgentID) else {
                    throw IntatisError.config(
                        "Historical @main recovery state changed before durable registration.")
                }
                return registrationEvents
            }
            guard persisted.count == registrationEvents.count else {
                return .failed("Historical @main recovery did not commit its complete registration batch.")
            }
        } catch {
            return .failed("Historical @main recovery could not be persisted: \(error.localizedDescription)")
        }

        registry.add(proposedMain)
        commitDefaultLeases(proposedLeases, for: proposedMain.name)
        return .attached(proposedMain.name)
    }

    private static func historicalRecoverySettingsMatch(
        _ canonical: CoworkSessionSettings,
        _ requested: CoworkSessionSettings
    ) -> Bool {
        var canonical = canonical
        var requested = requested
        canonical.defaultProviderID = nil
        requested.defaultProviderID = nil
        // ISO-8601 EventLog encoding intentionally does not preserve
        // subsecond precision. `addedAt` is presentation metadata and cannot
        // authorize a workspace or inference route, so compare a stable form.
        canonical.workspaces = canonical.workspaces.map { workspace in
            var workspace = workspace
            workspace.addedAt = Date(timeIntervalSince1970: 0)
            return workspace
        }
        requested.workspaces = requested.workspaces.map { workspace in
            var workspace = workspace
            workspace.addedAt = Date(timeIntervalSince1970: 0)
            return workspace
        }
        return canonical == requested
    }

    /// Atomically establishes the complete local identity/settings baseline for
    /// a brand-new Cowork session. Registration is local durable state only;
    /// constructing the no-tools reviewer responder does not issue a model
    /// request. The host must supply the reviewer's model and exact inference
    /// binding explicitly; configuration compatibility is resolved before
    /// this boundary, so the bootstrap can never derive reviewer inference
    /// from @main. Their identities and leases remain distinct.
    @discardableResult
    public func bootstrapFreshSession(
        main agent: Agent,
        settings rawSettings: CoworkSessionSettings,
        permissionReviewerModel: ModelID,
        permissionReviewerInferenceBinding: AgentInferenceBinding?,
        reviewerPolicy: PermissionReviewControlPlanePolicy = PermissionReviewControlPlanePolicy()
    ) async -> CoworkSessionBootstrapResult {
        guard agent.name == Self.mainAgentID else {
            return .failed("Cowork session bootstrap only accepts @\(Self.mainAgentID.rawValue).")
        }
        if let validationError = Self.agentNameValidationError(agent.name.rawValue) {
            return .failed(validationError)
        }
        guard !requiresInferenceBindings || agent.agentInferenceBinding != nil else {
            return .failed("@main requires an exact inference profile binding.")
        }
        if let permissionReviewerInferenceBinding,
           permissionReviewerInferenceBinding.modelID
            != permissionReviewerModel {
            return .failed(
                "The permission reviewer model must match its exact inference profile binding.")
        }
        guard permissionReviewerInferenceBinding != nil else {
            return .failed("The permission reviewer requires an exact inference profile binding.")
        }
        let sessionID = await log.sessionID
        let primaryWorkspaces = rawSettings.workspaces.filter(\.isPrimary)
        guard rawSettings.schemaVersion == CoworkSessionSettings.currentSchemaVersion,
              rawSettings.sessionID == sessionID,
              rawSettings.mainAgentName == Self.mainAgentID.rawValue,
              rawSettings.defaultInferenceProfileBinding == agent.agentInferenceBinding,
              rawSettings.defaultModelID == nil || rawSettings.defaultModelID == agent.model.rawValue,
              rawSettings.defaultPermissionProfile == agent.profile.rawValue,
              primaryWorkspaces.count == 1,
              let primary = primaryWorkspaces.first else {
            return .failed("Initial Cowork settings do not match the fixed @main registration.")
        }

        let assessment = assessWorkspaceAttach(agent.workspaceRoot)
        guard assessment.canAskUser, let canonical = assessment.canonical else {
            return .failed(assessment.reason)
        }
        guard URL(fileURLWithPath: primary.path).standardizedFileURL.resolvingSymlinksInPath()
                == canonical.standardizedFileURL.resolvingSymlinksInPath() else {
            return .failed("Initial Cowork settings do not match the selected primary workspace.")
        }

        var proposedMain = agent
        proposedMain.workspaceRoot = canonical
        var settings = rawSettings
        settings.workspaces = settings.workspaces.map { workspace in
            guard workspace.isPrimary else { return workspace }
            var updated = workspace
            updated.path = canonical.path
            updated.agentName = Self.mainAgentID.rawValue
            return updated
        }
        let reviewer = Agent(
            name: Self.automaticPermissionReviewerID,
            workspaceRoot: canonical,
            model: permissionReviewerModel,
            agentInferenceBinding: permissionReviewerInferenceBinding,
            profile: .readOnly,
            coordinationDepth: 0)

        let reviewerProviderFactory = permissionReviewProviderFactory(for: reviewer)
        do {
            _ = try await resolvedProvider(for: proposedMain)
            _ = try await reviewerProviderFactory()
        } catch {
            return .failed("The exact @main/reviewer inference profile is unavailable or incompatible.")
        }
        let reviewedMainCatalogBinding = proposedMain.agentInferenceBinding.flatMap {
            availableInferenceProfiles[$0.inferenceProfileID]
        }
        let reviewedReviewerCatalogBinding = reviewer.agentInferenceBinding.flatMap {
            availableInferenceProfiles[$0.inferenceProfileID]
        }
        let mainLeases = prepareDefaultLeases(for: proposedMain)
        let reviewerWorkspaceLease = WorkspaceLease(
            rootPath: canonical.path,
            access: .readOnly)
        let reviewerCapabilityLease = CapabilityLease(
            tools: [],
            communication: .none,
            delegation: .none,
            expiresAtTaskCompletion: false)

        // Preserve the existing strict-empty double preflight. Settings are in
        // the eventual atomic batch, never written as a permissive prefix.
        await acquireAdmissionLock()
        guard registry.isEmpty,
              automaticPermissionResponder == nil,
              automaticPermissionReviewerAgentID == nil else {
            releaseAdmissionLock()
            return registry.agent(Self.mainAgentID) != nil
                ? .alreadyAttached(Self.mainAgentID)
                : .failed("Initial Cowork bootstrap requires an empty local roster.")
        }
        do {
            guard try await log.isEmptyChecked() else {
                releaseAdmissionLock()
                return .failed("Initial Cowork bootstrap is only available for an empty session.")
            }
        } catch {
            releaseAdmissionLock()
            return .failed("Initial Cowork bootstrap could not verify an empty event log: \(error.localizedDescription)")
        }
        let mainCatalogBindingBeforeResolution = proposedMain.agentInferenceBinding.flatMap {
            availableInferenceProfiles[$0.inferenceProfileID]
        }
        let reviewerCatalogBindingBeforeResolution = reviewer.agentInferenceBinding.flatMap {
            availableInferenceProfiles[$0.inferenceProfileID]
        }
        releaseAdmissionLock()

        do {
            _ = try await resolvedProvider(for: proposedMain)
            _ = try await resolvedProvider(for: reviewer)
        } catch {
            return .failed("The exact @main/reviewer inference profile changed before durable admission.")
        }

        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        guard registry.isEmpty,
              automaticPermissionResponder == nil,
              automaticPermissionReviewerAgentID == nil else {
            return registry.agent(Self.mainAgentID) != nil
                ? .alreadyAttached(Self.mainAgentID)
                : .failed("Initial Cowork bootstrap requires an empty local roster.")
        }
        do {
            guard try await log.isEmptyChecked() else {
                return .failed("Initial Cowork bootstrap is only available for an empty session.")
            }
        } catch {
            return .failed("Initial Cowork bootstrap could not verify an empty event log: \(error.localizedDescription)")
        }
        if requiresInferenceBindings {
            let liveMainCatalogBinding = proposedMain.agentInferenceBinding.flatMap {
                availableInferenceProfiles[$0.inferenceProfileID]
            }
            let liveReviewerCatalogBinding = reviewer.agentInferenceBinding.flatMap {
                availableInferenceProfiles[$0.inferenceProfileID]
            }
            guard reviewedMainCatalogBinding == mainCatalogBindingBeforeResolution,
                  mainCatalogBindingBeforeResolution == liveMainCatalogBinding else {
                return .failed(
                    "@main host-approved inference profile changed before durable admission.")
            }
            guard reviewedReviewerCatalogBinding == reviewerCatalogBindingBeforeResolution,
                  reviewerCatalogBindingBeforeResolution == liveReviewerCatalogBinding else {
                return .failed(
                    "The permission reviewer host-approved inference profile changed before durable admission.")
            }
        }
        guard let mainRootIdentity = mainLeases.workspace.rootIdentity,
              mainRootIdentity.matchesCurrentDirectory(rootPath: mainLeases.workspace.rootPath),
              let reviewerRootIdentity = reviewerWorkspaceLease.rootIdentity,
              reviewerRootIdentity.matchesCurrentDirectory(
                rootPath: reviewerWorkspaceLease.rootPath) else {
            return .failed("The selected workspace identity changed before durable bootstrap admission.")
        }

        let mainWorkspaceMetadata = CoworkEventMetadata(
            agentID: proposedMain.name,
            workspaceID: mainLeases.workspace.workspaceID,
            workspaceLeaseID: mainLeases.workspace.id,
            scope: .workspace)
        let mainCapabilityMetadata = CoworkEventMetadata(
            agentID: proposedMain.name,
            capabilityLeaseID: mainLeases.capability.id,
            scope: .capability)
        let mainAgentMetadata = CoworkEventMetadata(
            agentID: proposedMain.name,
            workspaceID: mainLeases.workspace.workspaceID,
            workspaceLeaseID: mainLeases.workspace.id,
            capabilityLeaseID: mainLeases.capability.id,
            scope: .agent)
        let reviewerWorkspaceMetadata = CoworkEventMetadata(
            agentID: reviewer.name,
            workspaceID: reviewerWorkspaceLease.workspaceID,
            workspaceLeaseID: reviewerWorkspaceLease.id,
            scope: .workspace)
        let reviewerCapabilityMetadata = CoworkEventMetadata(
            agentID: reviewer.name,
            capabilityLeaseID: reviewerCapabilityLease.id,
            scope: .capability)
        let reviewerAgentMetadata = CoworkEventMetadata(
            agentID: reviewer.name,
            workspaceID: reviewerWorkspaceLease.workspaceID,
            workspaceLeaseID: reviewerWorkspaceLease.id,
            capabilityLeaseID: reviewerCapabilityLease.id,
            scope: .agent)

        do {
            let persisted = try await appendFreshSessionAdmissionEventsIfEmpty([
                .sessionSettingsUpdated(SessionSettingsUpdatedPayload(
                    revision: 1,
                    changeKind: .created,
                    kind: .cowork,
                    cowork: settings)),
                .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                    agent: proposedMain.name,
                    lease: mainLeases.workspace,
                    metadata: mainWorkspaceMetadata)),
                .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                    agent: proposedMain.name,
                    lease: mainLeases.capability,
                    metadata: mainCapabilityMetadata)),
                .agentAttached(AgentAttachedPayload(
                    agent: proposedMain.name,
                    path: proposedMain.workspaceRoot.path,
                    model: proposedMain.model,
                    profile: proposedMain.profile.rawValue,
                    agentInferenceBinding: proposedMain.agentInferenceBinding,
                    metadata: mainAgentMetadata)),
                .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                    agent: reviewer.name,
                    lease: reviewerWorkspaceLease,
                    metadata: reviewerWorkspaceMetadata)),
                .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                    agent: reviewer.name,
                    lease: reviewerCapabilityLease,
                    metadata: reviewerCapabilityMetadata)),
                .agentAttached(AgentAttachedPayload(
                    agent: reviewer.name,
                    path: reviewer.workspaceRoot.path,
                    model: reviewer.model,
                    profile: reviewer.profile.rawValue,
                    agentInferenceBinding: reviewer.agentInferenceBinding,
                    metadata: reviewerAgentMetadata)),
            ])
            guard persisted else {
                return .failed("Initial Cowork bootstrap lost the empty-session race; no registration was committed.")
            }
        } catch {
            return .failed("Initial Cowork settings and registrations could not be persisted: \(error.localizedDescription)")
        }

        registry.add(proposedMain)
        commitDefaultLeases(mainLeases, for: proposedMain.name)
        registry.add(reviewer)
        workspaceLeases[reviewerWorkspaceLease.id] = reviewerWorkspaceLease
        capabilityLeases[reviewerCapabilityLease.id] = reviewerCapabilityLease
        defaultWorkspaceLeaseIDs[reviewer.name] = reviewerWorkspaceLease.id
        defaultCapabilityLeaseIDs[reviewer.name] = reviewerCapabilityLease.id
        automaticPermissionReviewerAgentID = reviewer.name
        automaticPermissionResponder = AgentPermissionResponder(
            log: log,
            reviewerAgent: reviewer,
            providerFactory: reviewerProviderFactory,
            fallback: responder,
            policy: reviewerPolicy)
        return .attached(proposedMain.name)
    }

    @discardableResult
    public func detach(_ name: AgentID, reason: String = "agent detached") async -> Bool {
        guard name != Self.mainAgentID else {
            try? await log.append(.error(ErrorPayload(code: "reserved_agent", message: "@main cannot be detached")))
            return false
        }
        guard name != Self.automaticPermissionReviewerID else {
            try? await log.append(.error(ErrorPayload(
                code: "reserved_agent",
                message: "@\(Self.automaticPermissionReviewerID.rawValue) is controlled by automatic review settings")))
            return false
        }
        guard registry.agent(name) != nil else { return false }
        guard !taskGraph.nodes.values.contains(where: {
            ($0.assignee == name || $0.issuer == name) && Self.isActiveTaskStatus($0.status)
        }) else {
            try? await log.append(.error(ErrorPayload(
                code: "agent_busy",
                message: "@\(name.rawValue) has active tasks; cancel them before detach")))
            return false
        }
        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        // Re-check after waiting for another admission mutation.
        guard registry.agent(name) != nil,
              !taskGraph.nodes.values.contains(where: {
                  ($0.assignee == name || $0.issuer == name) && Self.isActiveTaskStatus($0.status)
              }) else { return false }

        let capabilityLeaseID = defaultCapabilityLeaseIDs[name]
        let workspaceLeaseID = defaultWorkspaceLeaseIDs[name]
        var events: [Event] = []
        if let capabilityLeaseID {
            events.append(.capabilityLeaseRevoked(CapabilityLeaseRevokedPayload(
                agent: name,
                leaseID: capabilityLeaseID,
                reason: reason,
                metadata: CoworkEventMetadata(
                    agentID: name,
                    capabilityLeaseID: capabilityLeaseID,
                    scope: .capability))))
        }
        if let workspaceLeaseID {
            events.append(.workspaceLeaseRevoked(WorkspaceLeaseRevokedPayload(
                agent: name,
                leaseID: workspaceLeaseID,
                reason: reason,
                metadata: CoworkEventMetadata(
                    agentID: name,
                    workspaceLeaseID: workspaceLeaseID,
                    scope: .workspace))))
        }
        events.append(.agentDetached(AgentDetachedPayload(
            agent: name,
            reason: reason,
            metadata: CoworkEventMetadata(agentID: name, scope: .agent))))
        do {
            try await appendAdmissionEvents(events)
        } catch {
            try? await log.append(.error(ErrorPayload(
                code: "agent_detach_persistence_failed",
                message: "@\(name.rawValue): \(error.localizedDescription)")))
            return false
        }

        // Runtime state changes only after the complete revoke+detach batch is
        // durable. A failed write therefore cannot resurrect an agent on replay.
        registry.remove(name)
        spawnedAgentOwners.removeValue(forKey: name)
        if let capabilityLeaseID {
            defaultCapabilityLeaseIDs.removeValue(forKey: name)
            capabilityLeases.removeValue(forKey: capabilityLeaseID)
        }
        if let workspaceLeaseID {
            defaultWorkspaceLeaseIDs.removeValue(forKey: name)
            workspaceLeases.removeValue(forKey: workspaceLeaseID)
        }
        return true
    }

    public func agentNames() -> [AgentID] { registry.names }
    public func agentList() -> [Agent] { registry.all() }

    /// Resolves every data-plane binding without issuing a model request.
    /// Error details are intentionally collapsed so endpoint/credential
    /// configuration cannot leak into roster or UI state.
    public func inferenceResolutionFailures() async -> [AgentID: String] {
        var failures: [AgentID: String] = [:]
        for agent in registry.all() where agent.name != Self.automaticPermissionReviewerID {
            if requiresInferenceBindings, agent.agentInferenceBinding == nil {
                failures[agent.name] = "legacy session requires an explicit inference profile rebind"
                continue
            }
            do {
                _ = try await resolvedProvider(for: agent)
            } catch {
                failures[agent.name] = "exact inference profile revision is unavailable or incompatible"
            }
        }
        return failures
    }

    /// Replaces only the host-approved choices for future spawn/rebind
    /// operations. Existing agent and TaskContract bindings are exact values
    /// and are deliberately not rewritten.
    public func updateAvailableInferenceProfiles(
        _ profiles: [AgentInferenceBinding],
        routingMetadata: [InferenceProfileRoutingMetadata] = [],
        hostAuthorized: Bool
    ) async {
        guard hostAuthorized else { return }
        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        availableInferenceProfiles = Dictionary(
            profiles.map { ($0.inferenceProfileID, $0) },
            uniquingKeysWith: { _, newest in newest })
        availableInferenceProfileRoutingMetadata = Dictionary(
            routingMetadata.compactMap { metadata in
                guard availableInferenceProfiles[
                    metadata.inferenceProfileID
                ] != nil else {
                    return nil
                }
                return (metadata.inferenceProfileID, metadata)
            },
            uniquingKeysWith: { _, newest in newest })
    }

    /// Host-only, durable rebind. An active/queued invocation is a hard fence:
    /// a profile revision can change only between tasks, never mid-request or
    /// across an already-admitted retry.
    public func rebindAgentInferenceProfile(
        agentID: AgentID,
        binding: AgentInferenceBinding,
        hostAuthorized: Bool
    ) async -> AgentInferenceRebindResult {
        guard hostAuthorized else {
            return .failed("changing an inference profile is reserved for the user/host control plane")
        }
        guard agentID != Self.automaticPermissionReviewerID else {
            return .failed("the automatic permission reviewer uses a reserved control-plane binding")
        }
        guard availableInferenceProfiles[binding.inferenceProfileID] == binding else {
            return .failed("the selected inference profile revision is not in the host-approved catalog")
        }
        guard let current = registry.agent(agentID) else {
            return .failed("no agent named @\(agentID.rawValue)")
        }
        if current.agentInferenceBinding == binding {
            return .unchanged(agentID, binding)
        }
        guard !automaticDelegationReservations.contains(agentID) else {
            return .failed("@\(agentID.rawValue) is reserved by a reviewed delegation")
        }
        guard !taskGraph.nodes.values.contains(where: {
            $0.assignee == agentID && Self.isActiveTaskStatus($0.status)
        }), !scheduler.queuedTasks().contains(where: { $0.assignee == agentID }) else {
            return .failed("@\(agentID.rawValue) has an active or queued invocation")
        }

        var candidate = current
        candidate.model = binding.modelID
        candidate.agentInferenceBinding = binding
        do {
            _ = try await resolvedProvider(for: candidate)
        } catch {
            return .failed("the selected inference profile revision is unavailable or incompatible")
        }

        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        guard availableInferenceProfiles[binding.inferenceProfileID] == binding else {
            return .failed("the selected inference profile revision is no longer in the host-approved catalog")
        }
        guard let live = registry.agent(agentID),
              live.agentInferenceBinding == current.agentInferenceBinding,
              !automaticDelegationReservations.contains(agentID),
              !taskGraph.nodes.values.contains(where: {
                  $0.assignee == agentID && Self.isActiveTaskStatus($0.status)
              }), !scheduler.queuedTasks().contains(where: { $0.assignee == agentID }) else {
            return .failed("@\(agentID.rawValue) changed or became busy before rebind")
        }
        do {
            try await appendAdmissionEvent(.agentAttached(AgentAttachedPayload(
                agent: candidate.name,
                path: candidate.workspaceRoot.path,
                model: candidate.model,
                profile: candidate.profile.rawValue,
                agentInferenceBinding: candidate.agentInferenceBinding,
                previousAgentInferenceBinding: current.agentInferenceBinding,
                inferenceBindingChangeReason: "rebound by user/host control plane",
                metadata: CoworkEventMetadata(
                    agentID: candidate.name,
                    scope: .agent,
                    visibility: .global))))
        } catch {
            return .failed("the inference profile rebind could not be persisted")
        }
        registry.add(candidate)
        return .rebound(agentID, binding)
    }

    /// Resolves a composer-selected `@main` binding outside the admission
    /// lock. The returned snapshot is only a candidate: the lock-held commit
    /// path revalidates the catalog, live roster, and busy fences before it can
    /// be persisted beside the exact root/retry admission that consumes it.
    private func prepareMainInferenceForAdmission(
        _ binding: AgentInferenceBinding
    ) async -> MainInferencePreparation {
        guard availableInferenceProfiles[binding.inferenceProfileID] == binding else {
            return .failed(
                "the model selected for the next @main message is no longer in the host-approved catalog")
        }
        guard let current = registry.agent(Self.mainAgentID) else {
            return .failed("no agent named @\(Self.mainAgentID.rawValue)")
        }
        if current.agentInferenceBinding == binding {
            return .unchanged
        }
        var candidate = current
        candidate.model = binding.modelID
        candidate.agentInferenceBinding = binding
        do {
            _ = try await resolvedProvider(for: candidate)
        } catch {
            return .failed(
                "the model selected for the next @main message is unavailable or incompatible")
        }
        return .rebind(PreparedMainInferenceRebind(
            previous: current,
            candidate: candidate))
    }

    /// Lock-held half of next-main admission. A changed binding is returned
    /// with its durable event, but the live registry is not mutated here; the
    /// caller must append that event atomically with the root/retry admission
    /// and only then commit both in-memory states.
    private func mainInferenceCommit(
        required binding: AgentInferenceBinding,
        preparation: MainInferencePreparation
    ) -> MainInferenceCommit {
        guard availableInferenceProfiles[binding.inferenceProfileID] == binding,
              let live = registry.agent(Self.mainAgentID) else {
            return .failed(
                "the model selected for the next @main message is no longer available")
        }
        if live.agentInferenceBinding == binding,
           live.model == binding.modelID {
            return .ready(live, nil)
        }
        guard case .rebind(let prepared) = preparation,
              live.agentInferenceBinding == prepared.previous.agentInferenceBinding,
              live.model == prepared.previous.model,
              live.workspaceRoot.standardizedFileURL ==
                prepared.previous.workspaceRoot.standardizedFileURL,
              live.profile == prepared.previous.profile,
              live.coordinationDepth == prepared.previous.coordinationDepth,
              prepared.candidate.agentInferenceBinding == binding,
              prepared.candidate.model == binding.modelID,
              !automaticDelegationReservations.contains(Self.mainAgentID),
              !taskGraph.nodes.values.contains(where: {
                  $0.assignee == Self.mainAgentID && Self.isActiveTaskStatus($0.status)
              }),
              !scheduler.queuedTasks().contains(where: {
                  $0.assignee == Self.mainAgentID
              }) else {
            return .failed(
                "@main changed or became busy before the selected model could be admitted")
        }
        let event = Event.agentAttached(AgentAttachedPayload(
            agent: prepared.candidate.name,
            path: prepared.candidate.workspaceRoot.path,
            model: prepared.candidate.model,
            profile: prepared.candidate.profile.rawValue,
            agentInferenceBinding: prepared.candidate.agentInferenceBinding,
            previousAgentInferenceBinding: live.agentInferenceBinding,
            inferenceBindingChangeReason: "selected at Cowork Send boundary",
            metadata: CoworkEventMetadata(
                agentID: prepared.candidate.name,
                scope: .agent,
                visibility: .global)))
        return .ready(prepared.candidate, event)
    }

    public func automaticPermissionReviewEnabled() -> Bool {
        automaticPermissionResponder != nil && !automaticPermissionReviewDisabling
    }
    public func automaticPermissionReviewHealth() async -> PermissionReviewControlPlaneHealth? {
        guard let automaticPermissionResponder else { return nil }
        return await automaticPermissionResponder.health()
    }
    func capabilityLeaseList() -> [CapabilityLease] { Array(capabilityLeases.values) }
    func workspaceLeaseList() -> [WorkspaceLease] { Array(workspaceLeases.values) }
    func capabilityLease(id: CapabilityLeaseID) -> CapabilityLease? { capabilityLeases[id] }
    func workspaceLease(id: WorkspaceLeaseID) -> WorkspaceLease? { workspaceLeases[id] }
    func queuedTasks() -> [ScheduledTask] { scheduler.queuedTasks() }
    func executionRecord(taskID: TaskID) -> ExecutionRecord? { scheduler.record(for: taskID) }
    func mailbox(for agent: AgentID) -> AgentMailbox { scheduler.mailbox(for: agent) }
    func taskGraphSnapshot() -> TaskGraph { taskGraph }
    func taskGraphNode(_ taskID: TaskID) -> TaskNode? { taskGraph.node(taskID) }

    func setMessageConsumptionPreflightForTesting(
        _ preflight: (@Sendable ([AgentMessageConsumedPayload]) async throws -> Void)?
    ) {
        messageConsumptionPreflightForTesting = preflight
    }

    func setTaskLifecycleEventAppender(_ appender: (@Sendable (Event) async throws -> Void)?) {
        taskLifecycleEventAppender = appender
    }

    func setCancelAllBeforeResumeHook(_ hook: (@Sendable () async -> Void)?) {
        cancelAllBeforeResumeHook = hook
    }

    func terminalPersistenceFailure(taskID: TaskID) -> String? {
        terminalPersistenceFailures[taskID]
    }

    func setTaskStartGate(_ gate: (@Sendable (TaskID) async -> Void)?) {
        taskStartGate = gate
    }

    func setAdmissionEventAppender(_ appender: (@Sendable (Event) async throws -> Void)?) {
        admissionEventAppender = appender
    }

    /// Batch seam for tests that need to fail a multi-event admission
    /// transaction. The closure must provide all-or-nothing semantics, just as
    /// `EventLog.append(_:)` does in production.
    func setAdmissionEventsAppender(_ appender: (@Sendable ([Event]) async throws -> Void)?) {
        admissionEventsAppender = appender
    }

    @discardableResult
    public func enableAutomaticPermissionReview(model: ModelID,
                                                 agentInferenceBinding: AgentInferenceBinding? = nil,
                                                 workspaceRoot: URL,
                                                 name: AgentID = Orchestrator.automaticPermissionReviewerID,
                                                 policy: PermissionReviewControlPlanePolicy = PermissionReviewControlPlanePolicy()) async -> AutomaticPermissionReviewResult {
        guard automaticPermissionResponder == nil else {
            return .alreadyEnabled(automaticPermissionReviewerAgentID ?? name)
        }
        if let automaticPermissionReviewRecoveryFailure {
            return .failed(automaticPermissionReviewRecoveryFailure)
        }
        guard name == Self.automaticPermissionReviewerID else {
            return .failed("automatic permission reviewer must use @\(Self.automaticPermissionReviewerID.rawValue)")
        }
        guard registry.agent(name) == nil else {
            return .failed("@\(name.rawValue) already exists; the automatic reviewer identity is reserved")
        }
        guard !requiresInferenceBindings || agentInferenceBinding != nil else {
            return .failed("automatic permission reviewer requires an exact inference profile binding")
        }

        let assessment = assessWorkspaceAttach(workspaceRoot)
        guard assessment.canAskUser, let canonical = assessment.canonical else {
            return .failed(assessment.reason)
        }

        let reviewer = Agent(
            name: name,
            workspaceRoot: canonical,
            model: model,
            agentInferenceBinding: agentInferenceBinding,
            profile: .readOnly,
            coordinationDepth: 0)

        let reviewerProviderFactory = permissionReviewProviderFactory(for: reviewer)
        do {
            _ = try await reviewerProviderFactory()
        } catch {
            return .failed("automatic permission reviewer inference profile is unavailable or incompatible")
        }

        let workspaceLease = WorkspaceLease(rootPath: reviewer.workspaceRoot.path, access: .readOnly)
        let capabilityLease = CapabilityLease(
            tools: [],
            communication: .none,
            delegation: .none,
            expiresAtTaskCompletion: false)

        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        if let automaticPermissionReviewRecoveryFailure {
            return .failed(automaticPermissionReviewRecoveryFailure)
        }
        guard automaticPermissionResponder == nil, registry.agent(name) == nil else {
            return .failed("@\(name.rawValue) was attached while automatic review was being enabled")
        }
        do {
            try await appendAdmissionEvents([
                .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                    agent: reviewer.name,
                    lease: workspaceLease,
                    metadata: CoworkEventMetadata(
                        agentID: reviewer.name,
                        workspaceID: workspaceLease.workspaceID,
                        workspaceLeaseID: workspaceLease.id,
                        scope: .workspace))),
                .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                    agent: reviewer.name,
                    lease: capabilityLease,
                    metadata: CoworkEventMetadata(
                        agentID: reviewer.name,
                        capabilityLeaseID: capabilityLease.id,
                        scope: .capability))),
                .agentAttached(AgentAttachedPayload(
                    agent: reviewer.name,
                    path: reviewer.workspaceRoot.path,
                    model: reviewer.model,
                    profile: reviewer.profile.rawValue,
                    agentInferenceBinding: reviewer.agentInferenceBinding,
                    metadata: CoworkEventMetadata(agentID: reviewer.name, scope: .agent))),
            ])
        } catch {
            return .failed("automatic permission reviewer admission could not be persisted: \(error.localizedDescription)")
        }
        registry.add(reviewer)
        workspaceLeases[workspaceLease.id] = workspaceLease
        capabilityLeases[capabilityLease.id] = capabilityLease
        defaultWorkspaceLeaseIDs[reviewer.name] = workspaceLease.id
        defaultCapabilityLeaseIDs[reviewer.name] = capabilityLease.id
        automaticPermissionReviewerAgentID = reviewer.name
        automaticPermissionResponder = AgentPermissionResponder(
            log: log,
            reviewerAgent: reviewer,
            providerFactory: reviewerProviderFactory,
            fallback: responder,
            policy: policy)
        return .enabled(reviewer.name)
    }

    @discardableResult
    public func disableAutomaticPermissionReview() async -> AutomaticPermissionReviewDisableResult {
        guard automaticPermissionReviewerAgentID != nil else {
            return .alreadyDisabled
        }
        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        guard let reviewerID = automaticPermissionReviewerAgentID else {
            return .alreadyDisabled
        }
        guard !automaticPermissionReviewDisabling else {
            return .failed("automatic permission review disable is already in progress")
        }
        automaticPermissionReviewDisabling = true
        defer { automaticPermissionReviewDisabling = false }
        let responderToShutdown = automaticPermissionResponder
        await responderToShutdown?.quiesce(
            reason: "automatic permission review disabled")
        let capabilityLeaseID = defaultCapabilityLeaseIDs[reviewerID]
        let workspaceLeaseID = defaultWorkspaceLeaseIDs[reviewerID]
        var events: [Event] = []
        if let capabilityLeaseID {
            events.append(.capabilityLeaseRevoked(CapabilityLeaseRevokedPayload(
                agent: reviewerID,
                leaseID: capabilityLeaseID,
                reason: "automatic permission review disabled",
                metadata: CoworkEventMetadata(
                    agentID: reviewerID,
                    capabilityLeaseID: capabilityLeaseID,
                    scope: .capability))))
        }
        if let workspaceLeaseID {
            events.append(.workspaceLeaseRevoked(WorkspaceLeaseRevokedPayload(
                agent: reviewerID,
                leaseID: workspaceLeaseID,
                reason: "automatic permission review disabled",
                metadata: CoworkEventMetadata(
                    agentID: reviewerID,
                    workspaceLeaseID: workspaceLeaseID,
                    scope: .workspace))))
        }
        events.append(.agentDetached(AgentDetachedPayload(
            agent: reviewerID,
            reason: "automatic permission review disabled",
            metadata: CoworkEventMetadata(agentID: reviewerID, scope: .agent))))
        do {
            try await appendAdmissionEvents(events)
        } catch {
            await responderToShutdown?.resumeAfterFailedQuiesce()
            let message = "automatic permission review remains enabled because its detach audit could not be persisted: \(error.localizedDescription)"
            try? await log.append(.error(ErrorPayload(
                code: "automatic_review_disable_persistence_failed",
                message: message)))
            return .failed(message)
        }

        automaticPermissionResponder = nil
        automaticPermissionReviewerAgentID = nil
        registry.remove(reviewerID)
        if let capabilityLeaseID {
            defaultCapabilityLeaseIDs.removeValue(forKey: reviewerID)
            capabilityLeases.removeValue(forKey: capabilityLeaseID)
        }
        if let workspaceLeaseID {
            defaultWorkspaceLeaseIDs.removeValue(forKey: reviewerID)
            workspaceLeases.removeValue(forKey: workspaceLeaseID)
        }
        // Quiescence above is the authorization barrier; only the atomically
        // durable detach makes it irreversible.
        await responderToShutdown?.finalizeShutdown()
        return .disabled(reviewerID)
    }

    private static func validatedContinuationRunCloseClaims(
        from projection: CoworkProjection
    ) throws -> [ContinuationRunID: ContinuationRunCloseRequestedPayload] {
        guard projection.ambiguousContinuationRunCloseClaimIDs.isEmpty else {
            throw EventLogError.conflictingContinuationRunCloseClaim
        }
        return projection.continuationRunCloseClaims
    }

    public func restore(from _: CoworkProjection) async {
        if startupSchedulerSuspension == nil {
            startupSchedulerSuspension = suspendScheduler()
        }
        let restoreSuspension = suspendScheduler()
        // Restore owns the same mutation boundary as task_create,
        // task_update, delegation admission, and invocation settlement. Actor
        // isolation alone is insufficient because replay and persistence await.
        await acquireAdmissionLock()
        terminalPersistenceFailures.removeAll()
        terminalCommitTaskIDs.removeAll()
        cancellationReasons.removeAll()
        cancellationRunCloseSources.removeAll()
        cancelledGoalRunScopes.removeAll()
        continuationRunCloseClaims.removeAll()
        continuationRunCloseInstallations.removeAll()
        automaticDelegationReservations.removeAll()
        providerUsageLimitFailures.removeAll()
        automaticPermissionReviewRecoveryFailure = nil
        workTaskRecoveryFailure = nil
        var events: [Envelope]
        do {
            let replay = try await log.replayForProjectionChecked()
            guard replay.hasCompleteKnownHistory else {
                throw EventLogError.unsupportedEventTypes
            }
            events = replay.envelopes
        } catch {
            let message = "Cowork restore could not verify the durable event log: \(error.localizedDescription)"
            automaticPermissionReviewRecoveryFailure = message
            workTaskRecoveryFailure = message
            releaseAdmissionLock()
            resumeScheduler(suspension: restoreSuspension, ensureRunning: false)
            return
        }
        var projection = CoworkProjection.build(from: events)
        do {
            continuationRunCloseClaims = try Self.validatedContinuationRunCloseClaims(
                from: projection)
        } catch {
            let message = "Cowork restore found ambiguous ContinuationRun close history: \(error.localizedDescription)"
            automaticPermissionReviewRecoveryFailure = message
            workTaskRecoveryFailure = message
            releaseAdmissionLock()
            resumeScheduler(suspension: restoreSuspension, ensureRunning: false)
            return
        }
        let auditedRunIDs = Set(events.compactMap { envelope -> ContinuationRunID? in
            guard case .goalAuditCompleted(let payload) = envelope.event else { return nil }
            return payload.runID
        })
        for envelope in events {
            guard case .taskFailed(let payload) = envelope.event,
                  payload.failureCode == .providerUsageLimit,
                  let contract = projection.tasks[payload.taskID]?.contract,
                  let goalID = contract.goalID,
                  let runID = contract.continuationRunID,
                  projection.currentGoalID == goalID,
                  projection.goals[goalID]?.status != .completed,
                  !auditedRunIDs.contains(runID) else { continue }
            providerUsageLimitFailures[runID] = (goalID, payload.error)
        }
        // Planning state is restored before execution-layer reconciliation so
        // every recovered invocation can be checked against its durable
        // WorkTask/run/goal binding.
        switch validatedRestoredWorkTaskGraph(from: projection) {
        case .success(let restored):
            workTaskGraph = restored
        case .failure(let violation):
            await failClosedWorkTaskRestore(violation)
            releaseAdmissionLock()
            resumeScheduler(suspension: restoreSuspension, ensureRunning: false)
            return
        }
        let staleReviewerCapabilityLeaseIDs = projection.capabilityLeaseAgents
            .compactMap { $0.value == Self.automaticPermissionReviewerID ? $0.key : nil }
            .sorted { $0.rawValue < $1.rawValue }
        let staleReviewerWorkspaceLeaseIDs = projection.workspaceLeaseAgents
            .compactMap { $0.value == Self.automaticPermissionReviewerID ? $0.key : nil }
            .sorted { $0.rawValue < $1.rawValue }
        if projection.agentRoster[Self.automaticPermissionReviewerID] != nil
            || !staleReviewerCapabilityLeaseIDs.isEmpty
            || !staleReviewerWorkspaceLeaseIDs.isEmpty {
            var cleanupEvents: [Event] = staleReviewerCapabilityLeaseIDs.map { leaseID in
                .capabilityLeaseRevoked(CapabilityLeaseRevokedPayload(
                    agent: Self.automaticPermissionReviewerID,
                    leaseID: leaseID,
                    reason: "stale automatic permission reviewer recovered",
                    metadata: CoworkEventMetadata(
                        agentID: Self.automaticPermissionReviewerID,
                        capabilityLeaseID: leaseID,
                        scope: .capability)))
            }
            cleanupEvents.append(contentsOf: staleReviewerWorkspaceLeaseIDs.map { leaseID in
                .workspaceLeaseRevoked(WorkspaceLeaseRevokedPayload(
                    agent: Self.automaticPermissionReviewerID,
                    leaseID: leaseID,
                    reason: "stale automatic permission reviewer recovered",
                    metadata: CoworkEventMetadata(
                        agentID: Self.automaticPermissionReviewerID,
                        workspaceLeaseID: leaseID,
                        scope: .workspace)))
            })
            cleanupEvents.append(.agentDetached(AgentDetachedPayload(
                agent: Self.automaticPermissionReviewerID,
                reason: "stale automatic permission reviewer recovered",
                metadata: CoworkEventMetadata(
                    agentID: Self.automaticPermissionReviewerID,
                    scope: .agent))))
            do {
                try await appendAdmissionEvents(cleanupEvents)
                let replay = try await log.replayForProjectionChecked()
                guard replay.hasCompleteKnownHistory else {
                    throw EventLogError.unsupportedEventTypes
                }
                events = replay.envelopes
                projection = CoworkProjection.build(from: events)
                continuationRunCloseClaims = try Self.validatedContinuationRunCloseClaims(
                    from: projection)
                switch validatedRestoredWorkTaskGraph(from: projection) {
                case .success(let restored):
                    workTaskGraph = restored
                case .failure(let violation):
                    await failClosedWorkTaskRestore(violation)
                    releaseAdmissionLock()
                    resumeScheduler(suspension: restoreSuspension, ensureRunning: false)
                    return
                }
            } catch {
                let message = "stale automatic permission reviewer cleanup or replay verification failed: \(error.localizedDescription)"
                automaticPermissionReviewRecoveryFailure = message
                workTaskRecoveryFailure = message
                releaseAdmissionLock()
                resumeScheduler(suspension: restoreSuspension, ensureRunning: false)
                return
            }
        }
        // No later restore phase mutates WorkTaskGraph. Release before mailbox
        // reconciliation, which can take the admission lock for wake tasks.
        releaseAdmissionLock()
        var durableCapabilityGrants: [CapabilityLeaseID: CapabilityLease] = [:]
        var durableWorkspaceGrants: [WorkspaceLeaseID: WorkspaceLease] = [:]
        capabilityLeaseHistory = [:]
        workspaceLeaseHistory = [:]
        for envelope in events {
            switch envelope.event {
            case .capabilityLeaseCreated(let payload):
                durableCapabilityGrants[payload.lease.id] = payload.lease
            case .capabilityLeaseRevoked(let payload):
                if let lease = durableCapabilityGrants[payload.leaseID],
                   lease.expiresAtTaskCompletion {
                    capabilityLeaseHistory[payload.leaseID] = lease
                }
            case .workspaceLeaseGranted(let payload):
                durableWorkspaceGrants[payload.lease.id] = payload.lease
            case .workspaceLeaseRevoked(let payload):
                if let lease = durableWorkspaceGrants[payload.leaseID],
                   lease.expiresAtTaskCompletion {
                    workspaceLeaseHistory[payload.leaseID] = lease
                }
            default:
                break
            }
        }
        let allReferencedCapabilityLeaseIDs: Set<CapabilityLeaseID> = Set(
            projection.tasks.values.compactMap { $0.contract?.capabilityLeaseID })
        let referencedCapabilityLeaseIDs: Set<CapabilityLeaseID> = Set(projection.tasks.values.compactMap {
            guard $0.contract?.kind != .root else { return nil }
            return $0.contract?.capabilityLeaseID
        })
        let referencedWorkspaceLeaseIDs: Set<WorkspaceLeaseID> = Set(projection.tasks.values.compactMap {
            guard $0.contract?.kind != .root else { return nil }
            return $0.contract?.workspaceLeaseID
        })
        let activeCapabilityLeaseIDs: Set<CapabilityLeaseID> = Set(
            projection.activeTasks.compactMap { $0.contract?.capabilityLeaseID })
        let activeWorkspaceLeaseIDs: Set<WorkspaceLeaseID> = Set(
            projection.activeTasks.compactMap { $0.contract?.workspaceLeaseID })
        let restorableAgentIDs = Set(projection.agentRoster.keys).subtracting([Self.automaticPermissionReviewerID])

        capabilityLeases = projection.capabilityLeases.filter { id, lease in
            if activeCapabilityLeaseIDs.contains(id) { return true }
            guard lease.taskID == nil,
                  !referencedCapabilityLeaseIDs.contains(id),
                  let agentID = projection.capabilityLeaseAgents[id] else { return false }
            return restorableAgentIDs.contains(agentID)
        }
        for (id, lease) in capabilityLeases where lease.taskID == nil && lease.expiresAtTaskCompletion {
            var durableDefault = lease
            durableDefault.expiresAtTaskCompletion = false
            capabilityLeases[id] = durableDefault
        }
        workspaceLeases = projection.workspaceLeases.filter { id, lease in
            if activeWorkspaceLeaseIDs.contains(id) { return true }
            guard lease.taskID == nil,
                  !referencedWorkspaceLeaseIDs.contains(id),
                  let agentID = projection.workspaceLeaseAgents[id] else { return false }
            return restorableAgentIDs.contains(agentID)
        }

        for payload in projection.agentRoster.values {
            guard payload.agent != Self.automaticPermissionReviewerID else { continue }
            let profile = PermissionProfile(rawValue: payload.profile) ?? .reviewed
            let agentLeaseIDs: [CapabilityLeaseID] = projection.capabilityLeaseAgents.compactMap { entry in
                entry.value == payload.agent ? entry.key : nil
            }
            let candidateDefaultLeases: [CapabilityLease] = agentLeaseIDs.compactMap { leaseID in
                projection.capabilityLeases[leaseID]
            }
            let defaultLease = candidateDefaultLeases
                .filter { lease in
                    lease.taskID == nil && !referencedCapabilityLeaseIDs.contains(lease.id)
                }
                .sorted { lhs, rhs in
                    if payload.agent == Self.mainAgentID,
                       lhs.tools.contains(.renameSession) != rhs.tools.contains(.renameSession) {
                        return lhs.tools.contains(.renameSession)
                    }
                    return lhs.id.rawValue < rhs.id.rawValue
                }
                .first
            registry.add(Agent(
                name: payload.agent,
                workspaceRoot: URL(fileURLWithPath: payload.path),
                model: payload.model,
                agentInferenceBinding: payload.agentInferenceBinding,
                profile: profile,
                coordinationDepth: payload.agent == Self.mainAgentID
                    ? Agent.defaultCoordinationDepth
                    : defaultLease.map(Self.coordinationDepth) ?? 0))
        }

        defaultWorkspaceLeaseIDs = deterministicDefaultWorkspaceLeases(
            projection: projection,
            taskLeaseIDs: referencedWorkspaceLeaseIDs)
        defaultCapabilityLeaseIDs = deterministicDefaultCapabilityLeases(
            projection: projection,
            taskLeaseIDs: referencedCapabilityLeaseIDs)
        for agent in registry.all() where defaultCapabilityLeaseIDs[agent.name] == nil
            || defaultWorkspaceLeaseIDs[agent.name] == nil {
            let leases = prepareDefaultLeases(for: agent)
            do {
                try await appendAdmissionEvent(.workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                    agent: agent.name,
                    lease: leases.workspace,
                    metadata: CoworkEventMetadata(
                        agentID: agent.name,
                        workspaceID: leases.workspace.workspaceID,
                        workspaceLeaseID: leases.workspace.id,
                        scope: .workspace))))
                try await appendAdmissionEvent(.capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                    agent: agent.name,
                    lease: leases.capability,
                    metadata: CoworkEventMetadata(
                        agentID: agent.name,
                        capabilityLeaseID: leases.capability.id,
                        scope: .capability))))
                commitDefaultLeases(leases, for: agent.name)
            } catch {
                try? await log.append(.error(ErrorPayload(
                    code: "restore_default_lease_persistence_failed",
                    message: "@\(agent.name.rawValue): \(error.localizedDescription)")))
            }
        }
        await upgradeMainControlCapabilitiesIfNeeded(
            referencedLeaseIDs: allReferencedCapabilityLeaseIDs)
        await upgradeMailboxFollowupCapabilitiesIfNeeded(
            referencedLeaseIDs: allReferencedCapabilityLeaseIDs)
        spawnedAgentOwners = projection.agentOwners.filter { registry.agent($0.key) != nil }

        let durableTaskCreatedAt = events.reduce(into: [TaskID: Date]()) { result, envelope in
            guard case .taskCreated(let payload) = envelope.event,
                  result[payload.contract.id] == nil else { return }
            result[payload.contract.id] = envelope.ts
        }
        var nodes: [TaskID: TaskNode] = [:]
        for view in projection.tasks.values {
            guard let contract = view.contract else { continue }
            let recoveredStatus: TaskStatus = view.status == .running ? .queued : view.status
            nodes[view.id] = TaskNode(
                id: view.id,
                contract: contract,
                status: recoveredStatus,
                rootTaskID: view.rootTaskID ?? contract.parentTaskID ?? contract.id,
                parentTaskID: view.parentTaskID ?? contract.parentTaskID,
                issuer: view.issuer ?? contract.issuer,
                assignee: view.assignee ?? contract.assignee,
                createdAt: durableTaskCreatedAt[view.id] ?? .distantPast)
        }
        let edges = nodes.values.compactMap { node -> TaskEdge? in
            guard let parent = node.parentTaskID else { return nil }
            return TaskEdge(
                fromTaskID: parent,
                toTaskID: node.id,
                issuer: node.issuer,
                assignee: node.assignee,
                kind: .delegates)
        }
        taskGraph = TaskGraph(nodes: nodes, edges: edges, policy: taskGraph.policy)

        var queued: [ScheduledTask] = []
        var known: [TaskID: ScheduledTask] = [:]
        var records: [TaskID: ExecutionRecord] = [:]
        var recoveredMailboxes: [AgentID: AgentMailbox] = [:]
        var recoveryFailures: [(ScheduledTask, String)] = []
        let startedNonReplayable = projection.startedNonReplayableToolExecutions

        for view in projection.tasks.values.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            guard let contract = view.contract else { continue }
            let rootTaskID = view.rootTaskID ?? nodes[view.id]?.rootTaskID ?? contract.id
            let visited = taskGraph.causalAgentChain(to: view.id)
            let previousAttempt = max(1, view.attempt)
            let maxAttempts = contract.maxAttempts ?? executionPolicy.maxAttempts
            let exhaustedRunningAttempt = view.status == .running && previousAttempt >= maxAttempts
            let interruptedSideEffects = startedNonReplayable.filter { execution in
                guard execution.prepared.taskID == view.id else { return false }
                return execution.prepared.attempt == nil
                    || execution.prepared.attempt == previousAttempt
            }
            let replayBlocked = view.status == .running
                && !interruptedSideEffects.isEmpty
            let attempt = view.status == .running
                && !exhaustedRunningAttempt
                && !replayBlocked
                ? previousAttempt + 1
                : previousAttempt
            let recoveredCausalParentID: TaskID? = {
                if let parent = view.parentTaskID ?? contract.parentTaskID {
                    return parent
                }
                if contract.kind == .mailboxDelivery {
                    return contract.relatedTasks.first
                }
                return nil
            }()
            let scheduled = ScheduledTask(
                contract: contract,
                input: contract.objective,
                rootTaskID: rootTaskID,
                parentTaskID: view.parentTaskID ?? contract.parentTaskID,
                issuer: view.issuer ?? contract.issuer,
                assignee: view.assignee ?? contract.assignee,
                causalParentID: recoveredCausalParentID,
                hopCount: max(0, visited.count - 1),
                visitedAgents: visited,
                attempt: attempt)
            known[view.id] = scheduled

            let restoredStatus = view.status == .running ? TaskStatus.queued : view.status
            if view.status == .created || view.status == .assigned {
                recoveryFailures.append((
                    scheduled,
                    "task admission was interrupted before it reached the durable queue"))
            } else if replayBlocked {
                recoveryFailures.append((
                    scheduled,
                    "task was interrupted after a non-replayable tool call; start a new run"))
            } else if exhaustedRunningAttempt {
                recoveryFailures.append((scheduled, "task exceeded retry attempts during crash recovery"))
            } else if restoredStatus == .queued {
                queued.append(scheduled)
                restoredPendingTaskIDs.insert(view.id)
            }
            records[view.id] = ExecutionRecord(
                taskID: view.id,
                assignee: scheduled.assignee,
                status: restoredStatus,
                result: view.result,
                error: view.error,
                rootTaskID: rootTaskID,
                parentTaskID: scheduled.parentTaskID,
                hopCount: scheduled.hopCount,
                visitedAgents: visited,
                attempt: attempt)

            if let replyMode = contract.replyMode,
               replyMode != TaskReplyMode.none,
               let issuer = contract.issuer {
                scheduledReplyTargets[view.id] = issuer
                scheduledReplyFormats[view.id] = replyMode == .answer ? .answer : .taskReport
            }
        }
        taskGraph = TaskGraph(nodes: nodes, edges: edges, policy: taskGraph.policy)

        for (agent, mailboxView) in projection.mailboxes {
            let details = pendingMessageDetails(
                for: agent,
                pendingIDs: Set(mailboxView.pendingMessages),
                events: events)
            recoveredMailboxes[agent] = AgentMailbox(
                pendingMessages: mailboxView.pendingMessages,
                pendingTasks: mailboxView.pendingTasks,
                completedResults: [],
                pendingMessageDetails: details)
        }
        var durableQueued = queued.filter { projection.tasks[$0.contract.id]?.status != .running }
        for task in queued where projection.tasks[task.contract.id]?.status == .running {
            do {
                try await appendAdmissionEvent(.taskQueued(TaskQueuedPayload(
                    contract: task.contract,
                    rootTaskID: task.rootTaskID,
                    parentTaskID: task.parentTaskID,
                    issuer: task.issuer,
                    assignee: task.assignee,
                    causalParentID: task.causalParentID,
                    hopCount: task.hopCount,
                    visitedAgents: task.visitedAgents,
                    attempt: task.attempt,
                    reason: "requeued after interrupted execution",
                    metadata: taskMetadata(
                        contract: task.contract,
                        rootTaskID: task.rootTaskID,
                        parentTaskID: task.parentTaskID,
                        sender: task.issuer,
                        recipient: task.assignee))))
                durableQueued.append(task)
            } catch {
                restoredPendingTaskIDs.remove(task.contract.id)
                recoveryFailures.append((
                    task,
                    "interrupted task could not be durably requeued: \(error.localizedDescription)"))
            }
        }
        scheduler = AgentScheduler(snapshot: AgentSchedulerSnapshot(
            queuedTasks: durableQueued,
            claimedTasks: [],
            knownTasks: known,
            records: records,
            mailboxes: recoveredMailboxes))

        // A close claim is a permanent admission fence for its exact RunID.
        // Reconcile remaining recovered work before considering any mailbox
        // wake so a restart cannot resurrect the run.
        for claim in continuationRunCloseClaims.values.sorted(by: {
            $0.runID.rawValue < $1.runID.rawValue
        }) {
            _ = await drainClosedContinuationRun(
                claim,
                excludingTaskID: nil,
                resumeUnrelatedWork: false)
        }

        consumedTokenCount = Self.consumedTokenCount(in: events)
        await tokenBudgetMeter.reconfigure(
            tokenBudget: executionPolicy.tokenBudget,
            durableConsumed: consumedTokenCount)
        for (task, message) in recoveryFailures {
            let metadata = taskMetadata(
                contract: task.contract,
                rootTaskID: task.rootTaskID,
                parentTaskID: task.parentTaskID,
                sender: task.issuer,
                recipient: task.assignee)
            let report = Self.makeTaskReport(
                task: task,
                status: .failed,
                error: message,
                attempt: task.attempt)
            do {
                try await appendTaskLifecycleEvent(.taskFailed(TaskFailedPayload(
                    taskID: task.contract.id,
                    agent: task.assignee,
                    error: message,
                    report: report,
                    attempt: task.attempt,
                    metadata: metadata)))
            } catch {
                terminalPersistenceFailures[task.contract.id] =
                    "Task recovery failure could not be persisted: \(error.localizedDescription)"
                continue
            }
            scheduler.recordFailed(task: task, error: message)
            if var node = nodes[task.contract.id] {
                node.status = .failed
                nodes[task.contract.id] = node
            }
            await revokeTaskLeases(contract: task.contract, reason: "recovery attempts exhausted")
        }
        taskGraph = TaskGraph(nodes: nodes, edges: edges, policy: taskGraph.policy)
        for agentID in recoveredMailboxes.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            await enqueuePendingMailboxWakeIfNeeded(for: agentID)
        }
        // Mailbox reconciliation above may synthesize a new queued wake task.
        // It is still recovered work and must remain behind the same explicit
        // resume boundary as tasks replayed directly from EventLog.
        restoredPendingTaskIDs.formUnion(
            scheduler.queuedTasks().map { $0.contract.id })
        resumeScheduler(suspension: restoreSuspension, ensureRunning: false)
    }

    /// Atomically consumes one composer-frozen `@main` binding with the root
    /// task it belongs to. The optional rebind and created/assigned/queued task
    /// events share one EventLog transaction and one admission-lock hold, so no
    /// unrelated delegation can observe the new live binding first.
    private func admitNextMainRootTask(
        text: String,
        images: [ImageAttachment],
        userMessage: UserMessagePayload,
        goalID: GoalID?,
        continuationRunID: ContinuationRunID?,
        recordUserMessage: Bool
    ) async -> RootTaskCreationResult {
        guard let requiredBinding = userMessage.mainAgentInferenceBinding else {
            return .failed("The next @main submission has no frozen model binding.")
        }
        guard !Task.isCancelled,
              !isGoalRunCancellationRequested(
                  goalID: goalID,
                  continuationRunID: continuationRunID) else {
            return .failed("Goal continuation was cancelled before root task admission.")
        }
        let inferencePreparation = await prepareMainInferenceForAdmission(
            requiredBinding)
        if case .failed(let message) = inferencePreparation {
            return .failed(message)
        }

        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        guard !Task.isCancelled,
              !isGoalRunCancellationRequested(
                  goalID: goalID,
                  continuationRunID: continuationRunID) else {
            return .failed("Goal continuation was cancelled before root task admission.")
        }
        let agent: Agent
        let inferenceRebindEvent: Event?
        switch mainInferenceCommit(
            required: requiredBinding,
            preparation: inferencePreparation) {
        case .ready(let preparedAgent, let event):
            agent = preparedAgent
            inferenceRebindEvent = event
        case .failed(let message):
            return .failed(message)
        }
        guard let workspaceLeaseID = defaultWorkspaceLeaseIDs[agent.name],
              let workspaceLease = workspaceLeases[workspaceLeaseID],
              let capabilityLeaseID = defaultCapabilityLeaseIDs[agent.name],
              capabilityLeases[capabilityLeaseID] != nil else {
            return .failed("The @main default leases are unavailable.")
        }
        let contract = TaskContract(
            kind: .root,
            issuer: nil,
            assignee: agent.name,
            continuationRunID: continuationRunID,
            goalID: goalID,
            submissionID: userMessage.submissionID,
            objective: text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "Coordinate the cowork task.",
            roleHint: "root task coordinator",
            expectedDeliverable: "Coordinate assigned subtasks and synthesize the result.",
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLeaseID,
            capabilityLeaseID: capabilityLeaseID,
            agentInferenceBinding: requiredBinding,
            relatedAgents: agentVisibleNames(excluding: agent.name),
            replyMode: TaskReplyMode.none,
            executionTimeoutSeconds: executionPolicy.taskTimeoutSeconds,
            maxAttempts: executionPolicy.maxAttempts)
        let scheduled = ScheduledTask(
            contract: contract,
            input: text,
            rootTaskID: contract.id,
            parentTaskID: nil,
            issuer: nil,
            assignee: agent.name,
            causalParentID: nil,
            hopCount: 0,
            visitedAgents: [agent.name],
            attempt: 1)
        var preflightGraph = taskGraph
        guard case .success = preflightGraph.addRootTask(contract),
              preflightGraph.updateStatus(taskID: contract.id, status: .assigned) else {
            return .failed("The selected @main root task violates the task graph.")
        }
        var preflightScheduler = scheduler
        guard preflightScheduler.enqueue(scheduled, mode: .newTask).accepted else {
            return .failed("The selected @main root task is already queued.")
        }
        let metadata = taskMetadata(
            contract: contract,
            rootTaskID: contract.id,
            parentTaskID: nil,
            sender: nil,
            recipient: agent.name)
        var events: [Event] = []
        if let inferenceRebindEvent {
            events.append(inferenceRebindEvent)
        }
        events.append(.taskCreated(TaskCreatedPayload(
            contract: contract,
            metadata: metadata)))
        events.append(.taskAssigned(TaskAssignedPayload(
            contract: contract,
            metadata: metadata)))
        events.append(.taskQueued(TaskQueuedPayload(
            contract: contract,
            rootTaskID: contract.id,
            parentTaskID: nil,
            issuer: nil,
            assignee: agent.name,
            causalParentID: nil,
            hopCount: 0,
            visitedAgents: [agent.name],
            attempt: 1,
            reason: "user task admitted with frozen @main model",
            metadata: metadata)))
        do {
            try await appendAdmissionEvents(events)
        } catch {
            return .failed(
                "The selected @main root admission could not be persisted: \(error.localizedDescription)")
        }

        if inferenceRebindEvent != nil {
            registry.add(agent)
        }
        guard case .success = taskGraph.addRootTask(contract) else {
            return .failed("The selected @main root admission could not be committed after persistence.")
        }
        _ = taskGraph.updateStatus(taskID: contract.id, status: .assigned)
        if Task.isCancelled || isGoalRunCancellationRequested(
            goalID: goalID,
            continuationRunID: continuationRunID) {
            let persisted = await cancelUnqueuedRootTask(
                scheduled,
                reason: "Goal continuation was cancelled during durable root task admission")
            return .failed(persisted
                ? "Goal continuation was cancelled before root task execution."
                : "Goal continuation cancellation could not be persisted.")
        }
        guard scheduler.enqueue(scheduled, mode: .newTask).accepted else {
            return .failed("Root task scheduler commit failed after durable admission.")
        }
        rootInvocations[contract.id] = RootInvocationContext(
            images: images,
            userMessage: userMessage,
            recordUserMessage: recordUserMessage)
        _ = taskGraph.updateStatus(taskID: contract.id, status: .queued)
        return .created(contract.id)
    }

    private func awaitRootTaskCompletion(_ rootTaskID: TaskID) async -> OrchestratorSendResult {
        ensureSchedulerRunning()
        _ = await awaitSchedulerResult(rootTaskID)
        if let failure = terminalPersistenceFailures[rootTaskID] {
            return .failed(failure)
        }
        guard let record = scheduler.record(for: rootTaskID) else {
            return .failed("Root task ended without an execution record.")
        }
        switch record.status {
        case .completed:
            return .sent
        case .failed, .cancelled:
            return .failed(record.error ?? "Root task \(record.status.rawValue).")
        case .created, .assigned, .queued, .running:
            return .failed("Root task did not reach a terminal state.")
        }
    }

    /// Route a user message to the explicit target, or to the first attached agent
    /// only when the caller did not specify a target.
    @discardableResult
    public func send(_ text: String,
                     to: AgentID? = nil,
                     images: [ImageAttachment] = [],
                     userMessage: UserMessagePayload? = nil,
                     goalID: GoalID? = nil,
                     continuationRunID: ContinuationRunID? = nil,
                     recordUserMessage: Bool = true) async -> OrchestratorSendResult {
        guard !Task.isCancelled,
              !isGoalRunCancellationRequested(
                goalID: goalID,
                continuationRunID: continuationRunID) else {
            return .failed("Goal continuation was cancelled before root task admission.")
        }
        let agent: Agent
        if let to {
            guard to != Self.automaticPermissionReviewerID else {
                let message = "@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review."
                try? await log.append(.error(ErrorPayload(code: "reserved_agent", message: message)))
                return .failed(message)
            }
            guard let explicitTarget = registry.agent(to) else {
                try? await log.append(.error(ErrorPayload(
                    code: "no_such_agent",
                    message: "no attached agent named @\(to.rawValue)")))
                return .failed("No attached agent named @\(to.rawValue).")
            }
            agent = explicitTarget
        } else {
            let defaultTarget = registry.agent(Self.mainAgentID)
                ?? registry.all().first(where: { $0.name != Self.automaticPermissionReviewerID })
            guard let defaultTarget else {
                try? await log.append(.error(ErrorPayload(code: "no_agent", message: "no agent attached")))
                return .failed("No agent attached.")
            }
            agent = defaultTarget
        }
        if userMessage?.mainAgentInferenceBinding != nil {
            guard agent.name == Self.mainAgentID else {
                return .failed(
                    "The composer model selection is reserved for @\(Self.mainAgentID.rawValue).")
            }
            guard let userMessage else {
                return .failed("The next @main submission payload is unavailable.")
            }
            switch await admitNextMainRootTask(
                text: text,
                images: images,
                userMessage: userMessage,
                goalID: goalID,
                continuationRunID: continuationRunID,
                recordUserMessage: recordUserMessage) {
            case .created(let rootTaskID):
                return await awaitRootTaskCompletion(rootTaskID)
            case .failed(let message):
                return .failed(message)
            }
        }
        let rootCreation = await createRootTaskResult(
            assignee: agent.name,
            objective: text,
            roleHint: "root task coordinator",
            expectedDeliverable: "Coordinate assigned subtasks and synthesize the result.",
            goalID: goalID,
            continuationRunID: continuationRunID,
            submissionID: userMessage?.submissionID)
        let rootTaskID: TaskID
        switch rootCreation {
        case .created(let created):
            rootTaskID = created
        case .failed(let message):
            return .failed(message)
        }
        guard let rootNode = taskGraph.node(rootTaskID) else {
            return .failed("The admitted root task is unavailable.")
        }

        let scheduled = ScheduledTask(
            contract: rootNode.contract,
            input: text,
            rootTaskID: rootTaskID,
            parentTaskID: nil,
            issuer: nil,
            assignee: agent.name,
            causalParentID: nil,
            hopCount: 0,
            visitedAgents: [agent.name],
            attempt: 1)
        if Task.isCancelled || isGoalRunCancellationRequested(
            goalID: goalID,
            continuationRunID: continuationRunID) {
            _ = await cancelUnqueuedRootTask(
                scheduled,
                reason: "Goal continuation was cancelled before root task queue admission")
            return .failed("Goal continuation was cancelled before root task admission.")
        }
        await acquireAdmissionLock()
        if Task.isCancelled || isGoalRunCancellationRequested(
            goalID: goalID,
            continuationRunID: continuationRunID) {
            let persisted = await cancelUnqueuedRootTask(
                scheduled,
                reason: "Goal continuation was cancelled while waiting for root task queue admission")
            releaseAdmissionLock()
            return .failed(persisted
                ? "Goal continuation was cancelled before root task admission."
                : "Goal continuation cancellation could not be persisted.")
        }
        var preflightScheduler = scheduler
        guard preflightScheduler.enqueue(scheduled, mode: .newTask).accepted,
              taskGraph.node(rootTaskID)?.status == .assigned else {
            releaseAdmissionLock()
            return .failed("Root task was already queued.")
        }
        do {
            try await appendAdmissionEvent(.taskQueued(TaskQueuedPayload(
                contract: rootNode.contract,
                rootTaskID: rootTaskID,
                parentTaskID: nil,
                issuer: nil,
                assignee: agent.name,
                causalParentID: nil,
                hopCount: 0,
                visitedAgents: [agent.name],
                attempt: 1,
                reason: "user task admitted",
                metadata: taskMetadata(
                    contract: rootNode.contract,
                    rootTaskID: rootTaskID,
                    recipient: agent.name))))
        } catch {
            let message = "Root task queue could not be persisted: \(error.localizedDescription)"
            let report = Self.makeTaskReport(
                task: scheduled,
                status: .cancelled,
                error: message,
                attempt: scheduled.attempt)
            do {
                try await appendTaskLifecycleEvent(.taskCancelled(TaskCancelledPayload(
                    taskID: rootTaskID,
                    agent: agent.name,
                    reason: message,
                    report: report,
                    attempt: scheduled.attempt,
                    metadata: taskMetadata(
                        contract: rootNode.contract,
                        rootTaskID: rootTaskID,
                        recipient: agent.name))))
                _ = taskGraph.updateStatus(taskID: rootTaskID, status: .cancelled)
            } catch {
                terminalPersistenceFailures[rootTaskID] =
                    "Root task admission failure could not be persisted: \(error.localizedDescription)"
            }
            releaseAdmissionLock()
            return .failed(message)
        }
        if Task.isCancelled || isGoalRunCancellationRequested(
            goalID: goalID,
            continuationRunID: continuationRunID) {
            let persisted = await cancelUnqueuedRootTask(
                scheduled,
                reason: "Goal continuation was cancelled during durable root task admission")
            releaseAdmissionLock()
            return .failed(persisted
                ? "Goal continuation was cancelled before root task execution."
                : "Goal continuation cancellation could not be persisted.")
        }
        guard scheduler.enqueue(scheduled, mode: .newTask).accepted else {
            releaseAdmissionLock()
            return .failed("Root task scheduler commit failed after durable admission.")
        }
        rootInvocations[rootTaskID] = RootInvocationContext(
            images: images,
            userMessage: userMessage,
            recordUserMessage: recordUserMessage)
        _ = taskGraph.updateStatus(taskID: rootTaskID, status: .queued)
        releaseAdmissionLock()
        return await awaitRootTaskCompletion(rootTaskID)
    }

    @discardableResult
    public func retry(_ task: CoworkTaskView,
                      images: [ImageAttachment] = [],
                      userMessage: UserMessagePayload? = nil,
                      recordUserMessage: Bool = true) async -> OrchestratorSendResult {
        let requiredMainBinding = userMessage?.mainAgentInferenceBinding
        if let requiredMainBinding {
            guard (task.assignee ?? task.contract?.assignee) == Self.mainAgentID,
                  task.contract?.agentInferenceBinding == requiredMainBinding else {
                return .failed(
                    "The retry task does not match the model frozen by its @main submission.")
            }
        }
        let admittedTaskID: TaskID
        if restoredPendingTaskIDs.contains(task.id),
           scheduler.record(for: task.id)?.status == .queued {
            // The user explicitly chose Retry for a task recovered from a
            // previous process. Resume that exact durable task instead of
            // creating a second root or appending another user message.
            if let requiredMainBinding {
                guard let liveMain = registry.agent(Self.mainAgentID),
                      liveMain.agentInferenceBinding == requiredMainBinding,
                      liveMain.model == requiredMainBinding.modelID else {
                    return .failed(
                        "The restored @main task is queued with a different live model and cannot be resumed safely.")
                }
            }
            restoredPendingTaskIDs.remove(task.id)
            admittedTaskID = task.id
        } else {
            let inferencePreparation: MainInferencePreparation
            if let requiredMainBinding {
                inferencePreparation = await prepareMainInferenceForAdmission(
                    requiredMainBinding)
                if case .failed(let message) = inferencePreparation {
                    return .failed(message)
                }
            } else {
                inferencePreparation = .unchanged
            }
            switch await admitRetry(
                taskID: task.id,
                reason: "explicit retry",
                requiredMainInferenceBinding: requiredMainBinding,
                inferencePreparation: inferencePreparation) {
            case .admitted(let taskID):
                admittedTaskID = taskID
            case .rejected(let message):
                return .failed(message)
            }
        }
        rootInvocations[admittedTaskID] = RootInvocationContext(
            images: images,
            userMessage: userMessage,
            recordUserMessage: recordUserMessage)
        ensureSchedulerRunning()
        _ = await awaitSchedulerResult(admittedTaskID)
        if let failure = terminalPersistenceFailures[admittedTaskID] {
            return .failed(failure)
        }
        guard let record = scheduler.record(for: admittedTaskID) else {
            return .failed("Retry ended without an execution record.")
        }
        switch record.status {
        case .completed:
            return .sent
        case .failed, .cancelled:
            return .failed(record.error ?? "Task \(record.status.rawValue).")
        case .created, .assigned, .queued, .running:
            return .failed("Retried task did not reach a terminal state.")
        }
    }

    private func admitRetry(
        taskID: TaskID,
        reason: String,
        requiredMainInferenceBinding: AgentInferenceBinding? = nil,
        inferencePreparation: MainInferencePreparation = .unchanged
    ) async -> RetryAdmissionResult {
        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        guard let currentRecord = scheduler.record(for: taskID),
              currentRecord.status == .failed || currentRecord.status == .cancelled else {
            return .rejected("Only failed or cancelled tasks can be retried.")
        }
        guard let currentTask = scheduler.knownTask(taskID: taskID) else {
            return .rejected("This task cannot be retried because its scheduler state is missing.")
        }
        guard !isGoalRunCancellationRequested(
            goalID: currentTask.contract.goalID,
            continuationRunID: currentTask.contract.continuationRunID) else {
            return .rejected("Goal continuation cancellation is pending; this task cannot be retried.")
        }
        let assignee = currentTask.assignee
        guard assignee != Self.automaticPermissionReviewerID else {
            return .rejected("@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review.")
        }
        guard registry.agent(assignee) != nil else {
            return .rejected("No attached agent named @\(assignee.rawValue).")
        }
        let inferenceRebindAgent: Agent?
        let inferenceRebindEvent: Event?
        if let requiredMainInferenceBinding {
            guard assignee == Self.mainAgentID,
                  currentTask.contract.agentInferenceBinding == requiredMainInferenceBinding else {
                return .rejected(
                    "The retry task does not match the model frozen by its @main submission.")
            }
            switch mainInferenceCommit(
                required: requiredMainInferenceBinding,
                preparation: inferencePreparation) {
            case .ready(let agent, let event):
                inferenceRebindAgent = event == nil ? nil : agent
                inferenceRebindEvent = event
            case .failed(let message):
                return .rejected(message)
            }
        } else {
            inferenceRebindAgent = nil
            inferenceRebindEvent = nil
        }
        let maxAttempts = currentTask.contract.maxAttempts ?? executionPolicy.maxAttempts
        guard let currentAttempt = currentRecord.attempt,
              currentAttempt >= 1,
              currentAttempt < Int.max else {
            return .rejected("Task has an invalid current attempt \(String(describing: currentRecord.attempt)).")
        }
        if let replayBlockReason = await taskReplayBlockReason(
            taskID: taskID,
            attempt: currentAttempt
        ) {
            return .rejected(replayBlockReason)
        }
        let nextAttempt = currentAttempt + 1
        guard nextAttempt <= maxAttempts else {
            return .rejected("Task reached its maximum of \(maxAttempts) attempts.")
        }

        let renewal: TaskLeaseRenewal
        do {
            renewal = try await prepareTaskLeaseRenewal(currentTask.contract, assignee: assignee)
        } catch {
            return .rejected(error.localizedDescription)
        }
        let contract = renewal.contract
        let scheduled = ScheduledTask(
            contract: contract,
            input: currentTask.input,
            rootTaskID: currentTask.rootTaskID,
            parentTaskID: currentTask.parentTaskID,
            issuer: currentTask.issuer,
            assignee: assignee,
            causalParentID: currentTask.causalParentID,
            hopCount: currentTask.hopCount,
            visitedAgents: currentTask.visitedAgents,
            attempt: nextAttempt)
        var preflightScheduler = scheduler
        guard preflightScheduler.enqueue(scheduled, mode: .retry).accepted else {
            return .rejected("Task is already queued/running or is not retryable.")
        }
        var preflightGraph = taskGraph
        guard preflightGraph.replaceContract(contract),
              preflightGraph.updateStatus(taskID: contract.id, status: .queued, isRetry: true) else {
            return .rejected("Task state no longer permits retry.")
        }
        let queuedEvent = Event.taskQueued(TaskQueuedPayload(
                contract: contract,
                rootTaskID: scheduled.rootTaskID,
                parentTaskID: scheduled.parentTaskID,
                issuer: scheduled.issuer,
                assignee: scheduled.assignee,
                causalParentID: scheduled.causalParentID,
                hopCount: scheduled.hopCount,
                visitedAgents: scheduled.visitedAgents,
                attempt: nextAttempt,
                reason: reason,
                metadata: taskMetadata(
                    contract: contract,
                    rootTaskID: scheduled.rootTaskID,
                    parentTaskID: scheduled.parentTaskID,
                    sender: scheduled.issuer,
                    recipient: scheduled.assignee)))
        do {
            if let inferenceRebindEvent {
                try await appendAdmissionEvents([
                    inferenceRebindEvent,
                    queuedEvent,
                ])
            } else {
                try await appendAdmissionEvent(queuedEvent)
            }
        } catch {
            return .rejected("Retry admission could not be persisted: \(error.localizedDescription)")
        }
        if let inferenceRebindAgent {
            registry.add(inferenceRebindAgent)
        }
        commitTaskLeaseRenewal(renewal)
        guard taskGraph.replaceContract(contract),
              scheduler.enqueue(scheduled, mode: .retry).accepted,
              taskGraph.updateStatus(taskID: contract.id, status: .queued, isRetry: true) else {
            return .rejected("Retry admission could not be committed after persistence.")
        }
        return .admitted(contract.id)
    }

    private func taskReplayBlockReason(taskID: TaskID, attempt: Int) async -> String? {
        let events: [Envelope]
        do {
            let replay = try await log.replayForProjectionChecked()
            guard replay.hasCompleteKnownHistory else {
                throw EventLogError.unsupportedEventTypes
            }
            events = replay.envelopes
        } catch {
            return "retry denied because durable tool history could not be verified; start a new run: \(error.localizedDescription)"
        }
        let projection = CoworkProjection.build(from: events)
        let nonReplayable = projection.startedNonReplayableToolExecutions(
            taskID: taskID,
            attempt: attempt)
        guard !nonReplayable.isEmpty else { return nil }
        return "this task attempt crossed a non-replayable tool boundary; start a new run instead of retrying it"
    }

    @discardableResult
    public func cancel(taskID: TaskID, reason: String = "cancelled by user") async -> Bool {
        await cancel(
            taskID: taskID,
            reason: reason,
            runCloseSource: .user)
    }

    @discardableResult
    private func cancel(
        taskID: TaskID,
        reason: String,
        runCloseSource: ContinuationRunCloseSource
    ) async -> Bool {
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "cancelled by user"
        if let queued = scheduler.queuedTask(taskID: taskID) {
            return await cancelBeforeExecution(
                queued,
                reason: normalizedReason,
                runCloseSource: runCloseSource,
                wasClaimed: false)
        }
        if let claimed = scheduler.claimedTask(taskID: taskID),
           scheduler.record(for: taskID)?.status == .queued {
            return await cancelBeforeExecution(
                claimed,
                reason: normalizedReason,
                runCloseSource: runCloseSource,
                wasClaimed: true)
        }

        guard scheduler.record(for: taskID)?.status == .running else { return false }
        cancellationReasons[taskID] = normalizedReason
        cancellationRunCloseSources[taskID] = runCloseSource
        if let runningTask = scheduler.knownTask(taskID: taskID) {
            do {
                // Fence the exact RunID before asking the provider/tool stack
                // to unwind. This is the running-task counterpart of the
                // queued cancellation path and prevents a slow cleanup from
                // leaving mailbox/delegation admission open.
                _ = try await closeRootRunIfNeeded(
                    for: runningTask,
                    outcome: Self.cancellationRunOutcome(source: runCloseSource),
                    source: runCloseSource,
                    reason: normalizedReason)
            } catch {
                terminalPersistenceFailures[taskID] =
                    "Run closure could not be persisted before task cancellation: \(error.localizedDescription)"
                runningExecutions[taskID]?.cancel()
                return false
            }
        }
        runningExecutions[taskID]?.cancel()
        return true
    }

    private func cancelBeforeExecution(_ task: ScheduledTask,
                                       reason: String,
                                       runCloseSource: ContinuationRunCloseSource,
                                       wasClaimed: Bool) async -> Bool {
        let taskID = task.contract.id
        guard !terminalCommitTaskIDs.contains(taskID) else { return false }
        terminalCommitTaskIDs.insert(taskID)
        defer {
            terminalCommitTaskIDs.remove(taskID)
            ensureSchedulerRunning()
            notifyIdleIfNeeded()
        }

        do {
            _ = try await closeRootRunIfNeeded(
                for: task,
                outcome: Self.cancellationRunOutcome(source: runCloseSource),
                source: runCloseSource,
                reason: reason)
        } catch {
            terminalPersistenceFailures[taskID] =
                "Run closure could not be persisted before task cancellation: \(error.localizedDescription)"
            if wasClaimed {
                _ = scheduler.requeueClaimedTask(taskID: taskID)
            }
            completeResultWaiters(taskID)
            return false
        }

        let metadata = taskMetadata(
            contract: task.contract,
            rootTaskID: task.rootTaskID,
            parentTaskID: task.parentTaskID,
            sender: task.issuer,
            recipient: task.assignee)
        let report = Self.makeTaskReport(
            task: task,
            status: .cancelled,
            error: reason,
            attempt: task.attempt)
        do {
            try await appendTaskLifecycleEvent(.taskCancelled(TaskCancelledPayload(
                taskID: taskID,
                agent: task.assignee,
                reason: reason,
                report: report,
                attempt: task.attempt,
                metadata: metadata)))
        } catch {
            terminalPersistenceFailures[taskID] =
                "Task cancellation could not be persisted: \(error.localizedDescription)"
            if wasClaimed {
                _ = scheduler.requeueClaimedTask(taskID: taskID)
            }
            // The task remains durably non-terminal and retryable, but this
            // in-flight caller must fail closed instead of waiting forever for
            // a terminal scheduler record that could not be persisted.
            completeResultWaiters(taskID)
            try? await log.append(.error(ErrorPayload(
                code: "terminal_persistence_failed",
                message: "Could not persist cancellation for task \(taskID.rawValue): \(error.localizedDescription)")))
            return false
        }

        terminalPersistenceFailures.removeValue(forKey: taskID)

        if wasClaimed {
            runningExecutions[taskID]?.cancel()
            scheduler.recordCancelled(task: task, reason: reason)
        } else {
            guard scheduler.cancelQueuedTask(taskID: taskID, reason: reason) != nil else {
                return false
            }
        }
        _ = taskGraph.updateStatus(taskID: taskID, status: .cancelled)
        await storeScheduledReply(task: task, result: nil, report: report, error: reason)
        await revokeTaskLeases(contract: task.contract, reason: "task cancelled")
        await refreshConsumedTokenCount()
        rootInvocations.removeValue(forKey: taskID)
        completeResultWaiters(taskID)
        return true
    }

    /// Model-facing close boundary. The caller supplies no identity; the
    /// current invocation must be the exact @main root of a live run.
    func requestContinuationRunClose(
        currentTaskID: TaskID?,
        outcome: ContinuationRunCloseOutcome,
        reason: String
    ) async -> String {
        guard let currentTaskID,
              let node = taskGraph.node(currentTaskID),
              node.contract.kind == .root,
              node.contract.issuer == nil,
              node.contract.assignee == Self.mainAgentID,
              let runID = node.contract.continuationRunID else {
            return "error: run control is available only to the exact @main root invocation"
        }
        guard outcome == .completed || outcome == .stopped else {
            return "error: the model may request only completed or stopped run closure"
        }
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedReason.isEmpty else {
            return "error: run close reason must not be empty"
        }
        let durableReason = Self.durableRunCloseReason(normalizedReason)

        let request = ContinuationRunCloseRequestedPayload(
            sessionID: await log.sessionID,
            runID: runID,
            goalID: node.contract.goalID,
            submissionID: node.contract.submissionID,
            rootTaskID: currentTaskID,
            requestedOutcome: outcome,
            source: .mainAgent,
            reason: durableReason)
        do {
            let claim = try await installContinuationRunCloseClaim(request)
            guard claim.requestedOutcome == outcome,
                  claim.source == .mainAgent else {
                return "error: this run was already closed as \(claim.requestedOutcome.rawValue): \(claim.reason)"
            }
            let drained = await drainClosedContinuationRun(
                claim,
                excludingTaskID: currentTaskID,
                resumeUnrelatedWork: true)
            guard drained else {
                return "error: run admission is closed, but one or more run-scoped tasks or messages could not be durably drained"
            }
            return outcome == .completed
                ? "current run is durably closed as completed"
                : "current run is durably closed as stopped"
        } catch {
            return "error: run close could not be persisted: \(error.localizedDescription)"
        }
    }

    /// Installs the cross-process first-write claim before waiting for any
    /// already-entered admission path. The in-flight counter is itself an
    /// actor-local tombstone, so reentrant admission fails closed while the
    /// EventLog CAS is pending. Once durable, the claim replaces that temporary
    /// fence; only then do we wait for the old admission holder to leave.
    private func installContinuationRunCloseClaim(
        _ request: ContinuationRunCloseRequestedPayload
    ) async throws -> ContinuationRunCloseRequestedPayload {
        if let existing = continuationRunCloseClaims[request.runID] {
            return existing
        }

        continuationRunCloseInstallations[request.runID, default: 0] += 1
        defer {
            let remaining = (continuationRunCloseInstallations[request.runID] ?? 1) - 1
            if remaining > 0 {
                continuationRunCloseInstallations[request.runID] = remaining
            } else {
                continuationRunCloseInstallations.removeValue(forKey: request.runID)
            }
        }

        do {
            let result = try await log.claimContinuationRunClose(request)
            continuationRunCloseClaims[request.runID] = result.claim
            // The durable claim now fences all future admission. Wait for the
            // holder that predates it to observe that fence and settle before
            // the caller begins exact-run drain.
            await acquireAdmissionLock()
            releaseAdmissionLock()
            return result.claim
        } catch {
            throw error
        }
    }

    private func closeRootRunIfNeeded(
        for task: ScheduledTask,
        outcome: ContinuationRunCloseOutcome,
        source: ContinuationRunCloseSource,
        reason: String
    ) async throws -> ContinuationRunCloseRequestedPayload? {
        guard task.contract.kind == .root,
              task.contract.issuer == nil,
              let runID = task.contract.continuationRunID else { return nil }
        // A caller draining an already-closed run may cancel another queued
        // root in that same run. Reuse the installed fence without recursively
        // starting a second drain that could cancel the root currently
        // returning from finish_run/stop_run.
        if let existing = continuationRunCloseClaims[runID] {
            return existing
        }
        let request = ContinuationRunCloseRequestedPayload(
            sessionID: await log.sessionID,
            runID: runID,
            goalID: task.contract.goalID,
            submissionID: task.contract.submissionID,
            rootTaskID: task.contract.id,
            requestedOutcome: outcome,
            source: source,
            reason: Self.durableRunCloseReason(reason))
        let claim = try await installContinuationRunCloseClaim(request)
        let drained = await drainClosedContinuationRun(
            claim,
            excludingTaskID: task.contract.id,
            resumeUnrelatedWork: true)
        guard drained else {
            throw IntatisError.io(
                "run admission was closed, but exact-scope drain did not settle durably")
        }
        return claim
    }

    private static func durableRunCloseReason(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = PermissionReviewTextSanitizer.sanitizeDiagnostic(
            normalized,
            maxCharacters: 1_000).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "ContinuationRun closed" : safe
    }

    private func scheduledTaskIDs(
        continuationRunID: ContinuationRunID,
        excludingTaskID: TaskID?
    ) -> [TaskID] {
        let snapshot = scheduler.snapshot()
        var seen = Set<TaskID>()
        var ordered: [TaskID] = []
        for task in snapshot.queuedTasks + snapshot.claimedTasks
        where task.contract.continuationRunID == continuationRunID
            && task.contract.id != excludingTaskID {
            if seen.insert(task.contract.id).inserted {
                ordered.append(task.contract.id)
            }
        }
        for taskID in runningExecutions.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard taskID != excludingTaskID,
                  let task = snapshot.knownTasks[taskID],
                  task.contract.continuationRunID == continuationRunID,
                  seen.insert(taskID).inserted else { continue }
            ordered.append(taskID)
        }
        return ordered
    }

    private func discardPendingMessages(
        continuationRunID: ContinuationRunID,
        goalID: GoalID?,
        reason: String
    ) async -> Bool {
        var seen = Set<MessageID>()
        let messages = scheduler.snapshot().mailboxes.values
            .flatMap(\.pendingMessageDetails)
            .filter { message in
                guard seen.insert(message.id).inserted,
                      let causalTaskID = message.causalParentID ?? message.taskID,
                      let contract = taskGraph.node(causalTaskID)?.contract
                        ?? scheduler.knownTask(taskID: causalTaskID)?.contract else {
                    return false
                }
                return contract.continuationRunID == continuationRunID
            }
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id.rawValue < $1.id.rawValue
                }
                return $0.createdAt < $1.createdAt
            }
        return await persistDiscardedMessages(
            messages,
            goalID: goalID,
            continuationRunID: continuationRunID,
            reason: reason)
    }

    /// Drains only one exact RunID. The current root may be excluded so a
    /// successful finish_run/stop_run call can return to AgentLoop and allow a
    /// single final assistant response; all other run work is terminalized.
    private func drainClosedContinuationRun(
        _ claim: ContinuationRunCloseRequestedPayload,
        excludingTaskID: TaskID?,
        resumeUnrelatedWork: Bool
    ) async -> Bool {
        let suspension = suspendScheduler()
        await acquireAdmissionLock()
        releaseAdmissionLock()

        var succeeded = true
        var previousRemainder: [TaskID]?
        while true {
            let scoped = scheduledTaskIDs(
                continuationRunID: claim.runID,
                excludingTaskID: excludingTaskID)
            guard !scoped.isEmpty else { break }
            let executions = scoped.compactMap { runningExecutions[$0] }
            for taskID in scoped {
                let cancelled = await cancel(
                    taskID: taskID,
                    reason: "ContinuationRun closed: \(claim.reason)")
                succeeded = succeeded && cancelled
            }
            for execution in executions { await execution.value }
            let remainder = scheduledTaskIDs(
                continuationRunID: claim.runID,
                excludingTaskID: excludingTaskID)
            guard !remainder.isEmpty else { break }
            if remainder == previousRemainder, executions.isEmpty {
                succeeded = false
                break
            }
            previousRemainder = remainder
        }

        let scheduledIDs = Set(scheduledTaskIDs(
            continuationRunID: claim.runID,
            excludingTaskID: excludingTaskID))
        let graphOnlyNodes = taskGraph.nodes.values
            .filter {
                $0.id != excludingTaskID
                    && $0.contract.continuationRunID == claim.runID
                    && !$0.status.isTerminal
                    && !scheduledIDs.contains($0.id)
                    && runningExecutions[$0.id] == nil
            }
            .sorted { $0.id.rawValue < $1.id.rawValue }
        for node in graphOnlyNodes {
            let cancelled = await cancelUnqueuedRootTask(
                scheduledTask(for: node),
                reason: "ContinuationRun closed: \(claim.reason)",
                runCloseSource: claim.source)
            succeeded = succeeded && cancelled
        }

        let messagesDiscarded = await discardPendingMessages(
            continuationRunID: claim.runID,
            goalID: claim.goalID,
            reason: "ContinuationRun closed: \(claim.reason)")
        succeeded = succeeded && messagesDiscarded
        if taskGraph.nodes.values.contains(where: {
            $0.id != excludingTaskID
                && $0.contract.continuationRunID == claim.runID
                && !$0.status.isTerminal
        }) {
            succeeded = false
        }
        if !scheduledTaskIDs(
            continuationRunID: claim.runID,
            excludingTaskID: excludingTaskID).isEmpty {
            succeeded = false
        }
        resumeScheduler(
            suspension: suspension,
            ensureRunning: succeeded && resumeUnrelatedWork)
        notifyIdleIfNeeded()
        return succeeded
    }

    public func cancelAll(reason: String = "cowork session stopped") async {
        await cancelAll(
            reason: reason,
            shutdownPermissionReviewer: true,
            runCloseSource: .hostLifecycle)
    }

    /// Cancels queued and running data-plane work while keeping the reserved
    /// automatic permission reviewer available for the next user request.
    public func cancelActiveTasks(
        reason: String = "cowork task cancelled",
        runCloseSource: ContinuationRunCloseSource = .user
    ) async {
        await cancelAll(
            reason: reason,
            shutdownPermissionReviewer: false,
            runCloseSource: runCloseSource)
    }

    /// Cancels only data-plane work belonging to one Goal (and optionally one
    /// continuation run), preserving unrelated session work and the automatic
    /// permission reviewer.
    @discardableResult
    public func cancelActiveTasks(goalID: GoalID,
                                  continuationRunID: ContinuationRunID? = nil,
                                  reason: String = "Goal continuation cancelled",
                                  resumePendingTasksOnSuccess: Bool = true,
                                  runCloseSource: ContinuationRunCloseSource = .user) async -> Bool {
        let cancellationScope = GoalRunCancellationScope(
            goalID: goalID,
            runID: continuationRunID)
        cancelledGoalRunScopes.insert(cancellationScope)
        let schedulerSuspension = suspendScheduler()
        var cancellationSucceeded = true
        var preBarrierCloseRootID: TaskID?
        if let continuationRunID,
           continuationRunCloseClaims[continuationRunID] == nil,
           let rootNode = taskGraph.nodes.values
            .filter({ node in
                node.contract.kind == .root
                    && node.contract.issuer == nil
                    && node.contract.goalID == goalID
                    && node.contract.continuationRunID == continuationRunID
            })
            .sorted(by: { $0.id.rawValue < $1.id.rawValue })
            .first {
            preBarrierCloseRootID = rootNode.id
            do {
                _ = try await closeRootRunIfNeeded(
                    for: scheduledTask(for: rootNode),
                    outcome: Self.cancellationRunOutcome(source: runCloseSource),
                    source: runCloseSource,
                    reason: reason)
            } catch {
                cancellationSucceeded = false
                terminalPersistenceFailures[rootNode.id] =
                    "Run closure could not be persisted before scoped cancellation: \(error.localizedDescription)"
            }
        }
        // The close path above writes its first-winner claim before waiting for
        // an already-entered admission. If root admission was not yet visible,
        // the Goal/run tombstone still stops it; wait for that transaction and
        // install the claim from the now-durable root before draining tasks.
        await acquireAdmissionLock()
        releaseAdmissionLock()
        if preBarrierCloseRootID == nil,
           let continuationRunID,
           continuationRunCloseClaims[continuationRunID] == nil,
           let rootNode = taskGraph.nodes.values
            .filter({ node in
                node.contract.kind == .root
                    && node.contract.issuer == nil
                    && node.contract.goalID == goalID
                    && node.contract.continuationRunID == continuationRunID
            })
            .sorted(by: { $0.id.rawValue < $1.id.rawValue })
            .first {
            do {
                _ = try await closeRootRunIfNeeded(
                    for: scheduledTask(for: rootNode),
                    outcome: Self.cancellationRunOutcome(source: runCloseSource),
                    source: runCloseSource,
                    reason: reason)
            } catch {
                cancellationSucceeded = false
                terminalPersistenceFailures[rootNode.id] =
                    "Run closure could not be persisted before scoped cancellation: \(error.localizedDescription)"
            }
        }
        var attemptedTaskIDs = Set<TaskID>()
        var previousRemainder: [TaskID]?
        while true {
            let scoped = scopedScheduledTaskIDs(
                goalID: goalID,
                continuationRunID: continuationRunID)
            guard !scoped.isEmpty else { break }
            attemptedTaskIDs.formUnion(scoped)
            let executions = scoped.compactMap { runningExecutions[$0] }
            for taskID in scoped {
                _ = await cancel(
                    taskID: taskID,
                    reason: reason,
                    runCloseSource: runCloseSource)
            }
            for execution in executions { await execution.value }

            let remainder = scopedScheduledTaskIDs(
                goalID: goalID,
                continuationRunID: continuationRunID)
            guard !remainder.isEmpty else { break }
            // Persistence failure can leave an un-cancellable task in place.
            // Fail closed without spinning forever; `cancel` already emitted a
            // durable error and the scheduler remains suspended until below.
            if remainder == previousRemainder, executions.isEmpty {
                cancellationSucceeded = false
                break
            }
            previousRemainder = remainder
        }
        if attemptedTaskIDs.contains(where: { terminalPersistenceFailures[$0] != nil }) {
            cancellationSucceeded = false
        }
        // Admission can persist TaskCreated/TaskAssigned before queue commit.
        // If the compensating cancellation failed, the nonterminal node is not
        // visible to the scheduler snapshot. Retry those durable graph-only
        // cancellations explicitly so a transient persistence failure cannot
        // make this Goal/run permanently un-stoppable.
        let scheduledIDs = Set(scopedScheduledTaskIDs(
            goalID: goalID,
            continuationRunID: continuationRunID))
        let graphOnlyNodes = taskGraph.nodes.values
            .filter {
                Self.matchesScope(
                    $0.contract,
                    goalID: goalID,
                    continuationRunID: continuationRunID)
                    && !$0.status.isTerminal
                    && !scheduledIDs.contains($0.id)
                    && runningExecutions[$0.id] == nil
            }
            .sorted { $0.id.rawValue < $1.id.rawValue }
        for node in graphOnlyNodes {
            attemptedTaskIDs.insert(node.id)
            let cancelled = await cancelUnqueuedRootTask(
                scheduledTask(for: node),
                reason: reason,
                runCloseSource: runCloseSource)
            cancellationSucceeded = cancellationSucceeded && cancelled
        }
        let discardedScopedMessages = await discardPendingMessages(
            goalID: goalID,
            continuationRunID: continuationRunID,
            reason: reason)
        cancellationSucceeded = cancellationSucceeded && discardedScopedMessages
        let scopedGraphNodes = taskGraph.nodes.values.filter {
            Self.matchesScope(
                $0.contract,
                goalID: goalID,
                continuationRunID: continuationRunID)
        }
        if scopedGraphNodes.contains(where: { !$0.status.isTerminal })
            || scopedGraphNodes.contains(where: {
                terminalPersistenceFailures[$0.id] != nil
            }) {
            cancellationSucceeded = false
        }
        let finalRemainder = scopedScheduledTaskIDs(
            goalID: goalID,
            continuationRunID: continuationRunID)
        if !finalRemainder.isEmpty {
            cancellationSucceeded = false
        }
        if cancellationSucceeded, continuationRunID == nil {
            cancelledGoalRunScopes.remove(cancellationScope)
        }
        resumeScheduler(
            suspension: schedulerSuspension,
            ensureRunning: cancellationSucceeded && resumePendingTasksOnSuccess)
        notifyIdleIfNeeded()
        return cancellationSucceeded
    }

    private func cancelAll(reason: String,
                           shutdownPermissionReviewer: Bool,
                           runCloseSource: ContinuationRunCloseSource) async {
        let schedulerSuspension = suspendScheduler()
        let queuedIDs = scheduler.queuedTasks().map { $0.contract.id }
        let runningIDs = Array(runningExecutions.keys)
        for taskID in queuedIDs {
            _ = await cancel(
                taskID: taskID,
                reason: reason,
                runCloseSource: runCloseSource)
        }
        for taskID in runningIDs {
            _ = await cancel(
                taskID: taskID,
                reason: reason,
                runCloseSource: runCloseSource)
        }
        let executions = runningIDs.compactMap { runningExecutions[$0] }
        for execution in executions { await execution.value }
        if shutdownPermissionReviewer {
            await terminal.shutdown(reason: reason)
        } else {
            await terminal.terminateAll(reason: reason)
        }
        // The reviewer is part of the control plane for data-plane work. Keep
        // it alive until every cancelled execution has unwound its provider,
        // tool, and approval waiters; only then retire the session reviewer.
        if shutdownPermissionReviewer {
            await automaticPermissionResponder?.shutdown(reason: reason)
        }
        if let cancelAllBeforeResumeHook {
            await cancelAllBeforeResumeHook()
        }
        resumeScheduler(suspension: schedulerSuspension, ensureRunning: false)
        notifyIdleIfNeeded()
    }

    @discardableResult
    public func resumePendingTasks() -> Bool {
        guard !Task.isCancelled else { return false }
        restoredPendingTaskIDs.removeAll()
        if let startupSchedulerSuspension {
            self.startupSchedulerSuspension = nil
            resumeScheduler(
                suspension: startupSchedulerSuspension,
                ensureRunning: true)
            return true
        }
        if schedulerSuspended {
            schedulerResumeRequested = true
        } else {
            ensureSchedulerRunning()
        }
        return true
    }

    /// Releases the restore-time scheduler gate for newly admitted work while
    /// keeping tasks recovered from an earlier process explicitly paused.
    /// Opening a historical session uses this path; only a user-driven retry
    /// or resume may release `restoredPendingTaskIDs`.
    @discardableResult
    public func startNewTasksKeepingRestoredTasksPaused() -> Bool {
        guard !Task.isCancelled else { return false }
        if let startupSchedulerSuspension {
            self.startupSchedulerSuspension = nil
            resumeScheduler(
                suspension: startupSchedulerSuspension,
                ensureRunning: true)
            return true
        }
        if schedulerSuspended {
            schedulerResumeRequested = true
        } else {
            ensureSchedulerRunning()
        }
        return true
    }

    public func updateExecutionPolicy(_ policy: CoworkExecutionPolicy) async {
        await acquireExecutionPolicyUpdateLock()
        defer { releaseExecutionPolicyUpdateLock() }

        guard policy.tokenBudget != executionPolicy.tokenBudget else {
            executionPolicy = policy
            ensureSchedulerRunning()
            return
        }

        // Pause new scheduler admission while publishing policy + limit. The
        // structured timeout path drains its losing child before returning, so
        // it cannot leave a detached AgentLoop behind. We still need not drain
        // unrelated running executions here: every run uses this session's one
        // meter actor, which preserves their outstanding reservations across
        // reconfiguration.
        let schedulerSuspension = suspendScheduler()
        executionPolicyUpdateInProgress = true
        guard await refreshConsumedTokenCount() else {
            executionPolicyUpdateInProgress = false
            resumeScheduler(suspension: schedulerSuspension, ensureRunning: false)
            return
        }
        await tokenBudgetMeter.reconfigure(
            tokenBudget: policy.tokenBudget,
            durableConsumed: consumedTokenCount)
        executionPolicy = policy
        executionPolicyUpdateInProgress = false
        resumeScheduler(suspension: schedulerSuspension, ensureRunning: true)
    }

    /// Called by `BusMessenger` when `from` asks the agent named `toName`.
    func ask(from: AgentID, to toName: String, question: String, parentTaskID: TaskID? = nil) async -> String {
        switch await askResult(
            from: from,
            to: toName,
            question: question,
            parentTaskID: parentTaskID) {
        case .success(let result), .failure(let result):
            return result
        }
    }

    func askResult(from: AgentID,
                   to toName: String,
                   question: String,
                   parentTaskID: TaskID? = nil) async -> AgentMessengerReply {
        let queued = await enqueueAsk(from: from, to: toName, question: question, parentTaskID: parentTaskID)
        guard let taskID = queued.taskID else { return .failure(queued.message) }
        let result = await awaitSchedulerResult(taskID)
        guard let record = scheduler.record(for: taskID),
              record.status == .completed,
              result != nil else {
            return .failure(result ?? queued.message)
        }
        guard let reply = scheduledReplyResults[taskID] else {
            return .failure(
                "delegated task completed without a settled reply-delivery outcome")
        }
        return reply
    }

    func enqueueAsk(from: AgentID, to toName: String, question: String, parentTaskID: TaskID?) async -> (taskID: TaskID?, message: String) {
        let normalizedName = Self.normalizedAgentName(toName)
        let to = AgentID(rawValue: normalizedName)
        guard to != from else {
            try? await log.append(.error(ErrorPayload(code: "agent_self_call",
                                                       message: "agent cannot ask itself")))
            return (nil, "error: agent cannot ask itself")
        }
        guard to != Self.automaticPermissionReviewerID else {
            return (nil, "@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review")
        }
        guard registry.agent(to) != nil else { return (nil, "no such agent: \(toName)") }
        let queued = await enqueueDelegatedTask(
            from: from,
            to: to.rawValue,
            objective: question,
            roleHint: nil,
            expectedDeliverable: nil,
            parentTaskID: parentTaskID,
            replyMode: .answer)
        if let taskID = queued.taskID {
            scheduledReplyTargets[taskID] = from
            scheduledReplyFormats[taskID] = .answer
            ensureSchedulerRunning()
        }
        return queued
    }

    func sendMessage(from: AgentID, to toName: String, content: String, taskID: TaskID? = nil) async -> String {
        let normalizedName = Self.normalizedAgentName(toName)
        let to = AgentID(rawValue: normalizedName)
        guard to != from else { return "error: agent cannot message itself" }
        guard to != Self.automaticPermissionReviewerID else {
            return "@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review"
        }
        guard registry.agent(to) != nil else { return "no such agent: \(toName)" }
        if let cancellationFailure = communicationCancellationFailure(taskID: taskID) {
            return "error: \(cancellationFailure)"
        }
        if let failure = communicationFailure(from: from, to: to, taskID: taskID, operation: .send) {
            return "error: \(failure)"
        }

        await acquireAdmissionLock()
        if let cancellationFailure = communicationCancellationFailure(taskID: taskID) {
            releaseAdmissionLock()
            return "error: \(cancellationFailure)"
        }
        if let failure = communicationFailure(from: from, to: to, taskID: taskID, operation: .send) {
            releaseAdmissionLock()
            return "error: \(failure)"
        }
        guard let payload = await bus.sendMessage(from: from, to: to, content: content, taskID: taskID) else {
            releaseAdmissionLock()
            return "your message was blocked by the mediator"
        }
        let message = PendingAgentMessage(
            id: payload.messageId,
            sender: from,
            recipient: to,
            content: payload.content,
            kind: AgentCommunicationKind.sendMessage.rawValue,
            taskID: taskID,
            causalParentID: taskID,
            inReplyTo: payload.inReplyTo)
        _ = scheduler.enqueueMessage(message)
        if let cancellationFailure = await settleLateCancelledCommunication(
            message,
            taskID: taskID) {
            releaseAdmissionLock()
            return "error: \(cancellationFailure)"
        }
        releaseAdmissionLock()
        await enqueueMailboxWakeTask(
            sender: from,
            recipient: to,
            requestedMessageIDs: [message.id])
        return "sent message to @\(to.rawValue)"
    }

    func requestInformation(from: AgentID,
                            to toName: String,
                            question: String,
                            basedOn: String? = nil,
                            taskID: TaskID? = nil) async -> String {
        let normalizedName = Self.normalizedAgentName(toName)
        let to = AgentID(rawValue: normalizedName)
        guard to != from else { return "error: agent cannot request information from itself" }
        guard to != Self.automaticPermissionReviewerID else {
            return "@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review"
        }
        guard registry.agent(to) != nil else { return "no such agent: \(toName)" }
        if let cancellationFailure = communicationCancellationFailure(taskID: taskID) {
            return "error: \(cancellationFailure)"
        }
        if let failure = communicationFailure(
            from: from,
            to: to,
            taskID: taskID,
            operation: .requestInformation) {
            return "error: \(failure)"
        }

        await acquireAdmissionLock()
        if let cancellationFailure = communicationCancellationFailure(taskID: taskID) {
            releaseAdmissionLock()
            return "error: \(cancellationFailure)"
        }
        if let failure = communicationFailure(
            from: from,
            to: to,
            taskID: taskID,
            operation: .requestInformation) {
            releaseAdmissionLock()
            return "error: \(failure)"
        }
        let currentContract = taskContract(forCausalTaskID: taskID)
        let basedOnID = basedOn.map(MessageID.init(rawValue:))
        var conversationID: MessageID?
        if currentContract?.kind == .mailboxDelivery {
            guard let basedOnID,
                  currentContract?.mailboxMessageIDs?.contains(basedOnID) == true else {
                releaseAdmissionLock()
                return "error: a mailbox follow-up must set based_on to one frozen reply Message ID"
            }
            let history: [Envelope]
            do {
                history = try await completeKnownCommunicationHistory()
            } catch {
                releaseAdmissionLock()
                return "error: information follow-up could not verify durable history: \(error.localizedDescription)"
            }
            guard let previous = history.compactMap({ envelope -> InformationRepliedPayload? in
                guard case .informationReplied(let payload) = envelope.event,
                      payload.replyID == basedOnID else { return nil }
                return payload
            }).first,
                  previous.to == from,
                  previous.from == to,
                  let currentContract,
                  communicationScopeMatches(
                    currentContract,
                    causalTaskID: previous.taskID) else {
                releaseAdmissionLock()
                return "error: based_on is not an information reply from the exact target and run scope"
            }
            conversationID = previous.conversationID
                ?? previous.inReplyTo
                ?? previous.replyID
        } else if basedOnID != nil {
            releaseAdmissionLock()
            return "error: based_on is accepted only from a frozen mailbox reply"
        }
        let requestID = MessageID.new()
        guard let payload = await bus.requestInformation(
            from: from,
            to: to,
            question: question,
            taskID: taskID,
            requestID: requestID,
            conversationID: conversationID ?? requestID,
            basedOn: basedOnID) else {
            releaseAdmissionLock()
            return "your information request was blocked by the mediator"
        }
        let message = PendingAgentMessage(
            id: payload.requestID,
            sender: from,
            recipient: to,
            content: payload.question,
            kind: AgentCommunicationKind.requestInformation.rawValue,
            taskID: taskID,
            causalParentID: taskID,
            conversationID: payload.conversationID,
            basedOn: payload.basedOn)
        _ = scheduler.enqueueMessage(message)
        if let cancellationFailure = await settleLateCancelledCommunication(
            message,
            taskID: taskID) {
            releaseAdmissionLock()
            return "error: \(cancellationFailure)"
        }
        releaseAdmissionLock()
        await enqueueMailboxWakeTask(
            sender: from,
            recipient: to,
            requestedMessageIDs: [message.id])
        return "requested information from @\(to.rawValue) (request_id: \(payload.requestID.rawValue))"
    }

    func replyMessage(from: AgentID, to toName: String, content: String, inReplyTo: String?, taskID: TaskID? = nil) async -> String {
        let normalizedName = Self.normalizedAgentName(toName)
        let to = AgentID(rawValue: normalizedName)
        guard to != from else { return "error: agent cannot reply to itself" }
        guard to != Self.automaticPermissionReviewerID else {
            return "@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review"
        }
        guard registry.agent(to) != nil else { return "no such agent: \(toName)" }
        if let cancellationFailure = communicationCancellationFailure(taskID: taskID) {
            return "error: \(cancellationFailure)"
        }
        if let failure = communicationFailure(from: from, to: to, taskID: taskID, operation: .reply) {
            return "error: \(failure)"
        }

        await acquireAdmissionLock()
        if let cancellationFailure = communicationCancellationFailure(taskID: taskID) {
            releaseAdmissionLock()
            return "error: \(cancellationFailure)"
        }
        if let failure = communicationFailure(from: from, to: to, taskID: taskID, operation: .reply) {
            releaseAdmissionLock()
            return "error: \(failure)"
        }
        guard let rawReplyID = inReplyTo?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawReplyID.isEmpty else {
            releaseAdmissionLock()
            return "error: inReplyTo is required and must identify the frozen information request"
        }
        let requestID = MessageID(rawValue: rawReplyID)
        guard let currentContract = taskContract(forCausalTaskID: taskID),
              currentContract.kind == .mailboxDelivery,
              currentContract.mailboxMessageIDs?.contains(requestID) == true else {
            releaseAdmissionLock()
            return "error: reply_message may answer only an information request frozen into this mailbox invocation"
        }
        let history: [Envelope]
        do {
            history = try await completeKnownCommunicationHistory()
        } catch {
            releaseAdmissionLock()
            return "error: information reply could not verify durable history: \(error.localizedDescription)"
        }
        guard let request = history.compactMap({ envelope -> InformationRequestedPayload? in
            guard case .informationRequested(let payload) = envelope.event,
                  payload.requestID == requestID else { return nil }
            return payload
        }).first,
              request.to == from,
              request.from == to,
              communicationScopeMatches(
                currentContract,
                causalTaskID: request.taskID) else {
            releaseAdmissionLock()
            return "error: inReplyTo is not an information request from the exact target and run scope"
        }
        let priorReplies = history.compactMap { envelope -> InformationRepliedPayload? in
            guard case .informationReplied(let payload) = envelope.event,
                  payload.inReplyTo == requestID else { return nil }
            return payload
        }
        if let first = priorReplies.first {
            let historyIsConsistent = priorReplies.allSatisfy { $0 == first }
            guard historyIsConsistent else {
                releaseAdmissionLock()
                return "error: the information request has conflicting durable replies"
            }
            if first.from == from, first.to == to, first.content == content {
                releaseAdmissionLock()
                return "replied to @\(to.rawValue) (reply_id: \(first.replyID.rawValue), idempotent)"
            }
            releaseAdmissionLock()
            return "error: the information request already has a terminal reply"
        }
        guard let payload = await bus.replyMessage(
            from: from,
            to: to,
            content: content,
            inReplyTo: requestID,
            conversationID: request.conversationID ?? request.requestID,
            taskID: taskID) else {
            releaseAdmissionLock()
            return "your reply was blocked by the mediator"
        }
        let message = PendingAgentMessage(
            id: payload.replyID,
            sender: from,
            recipient: to,
            content: payload.content,
            kind: AgentCommunicationKind.replyMessage.rawValue,
            taskID: taskID,
            causalParentID: taskID,
            inReplyTo: payload.inReplyTo,
            conversationID: payload.conversationID)
        _ = scheduler.enqueueMessage(message)
        if let cancellationFailure = await settleLateCancelledCommunication(
            message,
            taskID: taskID) {
            releaseAdmissionLock()
            return "error: \(cancellationFailure)"
        }
        releaseAdmissionLock()
        await enqueueMailboxWakeTask(
            sender: from,
            recipient: to,
            requestedMessageIDs: [message.id])
        return "replied to @\(to.rawValue) (reply_id: \(payload.replyID.rawValue))"
    }

    private func enqueuePendingMailboxWakeIfNeeded(for recipient: AgentID,
                                                   fallbackSender: AgentID? = nil) async {
        guard let pendingMessage = scheduler.peekMessage(for: recipient) else { return }
        guard let wakeSender = pendingMessage.sender ?? fallbackSender,
              wakeSender != recipient else { return }
        await enqueueMailboxWakeTask(
            sender: wakeSender,
            recipient: recipient)
    }

    private func enqueueMailboxWakeTask(sender: AgentID,
                                        recipient: AgentID,
                                        requestedMessageIDs: [MessageID]? = nil) async {
        await acquireAdmissionLock()
        guard let target = registry.agent(recipient) else {
            releaseAdmissionLock()
            return
        }
        let messages: [PendingAgentMessage]
        switch await mailboxWakeDisposition(
            for: recipient,
            fallbackSender: sender,
            requestedMessageIDs: requestedMessageIDs) {
        case .alreadyScheduled:
            releaseAdmissionLock()
            ensureSchedulerRunning()
            return
        case .retry(let taskID):
            releaseAdmissionLock()
            if case .admitted = await admitRetry(
                taskID: taskID,
                reason: "automatic mailbox delivery retry") {
                ensureSchedulerRunning()
            }
            return
        case .exhausted, .ambiguous:
            releaseAdmissionLock()
            return
        case .admitNew(let pendingMessages):
            messages = pendingMessages
        }
        defer { releaseAdmissionLock() }
        guard let firstMessage = messages.first,
              let batchKey = mailboxDeliveryBatchKey(
                  for: firstMessage,
                  fallbackSender: sender) else { return }
        let causalTaskID = firstMessage.causalParentID ?? firstMessage.taskID
        let causalContract = causalTaskID.flatMap {
            taskGraph.node($0)?.contract ?? scheduler.knownTask(taskID: $0)?.contract
        }
        guard !isGoalRunCancellationRequested(
            goalID: batchKey.goalID,
            continuationRunID: batchKey.continuationRunID) else {
            return
        }

        let prepared = prepareMailboxDeliveryTask(
            issuer: batchKey.sender,
            assignee: target,
            messages: messages,
            authorityClass: batchKey.authorityClass,
            scopeContract: causalContract)
        let contract = prepared.contract
        var preflightGraph = taskGraph
        guard case .success(let admission) = preflightGraph.addRootTask(contract) else { return }
        let metadata = taskMetadata(
            contract: contract,
            rootTaskID: admission.rootTaskID,
            sender: batchKey.sender,
            recipient: recipient)
        let scheduled = ScheduledTask(
            contract: contract,
            input: contract.objective,
            rootTaskID: admission.rootTaskID,
            parentTaskID: nil,
            issuer: batchKey.sender,
            assignee: recipient,
            causalParentID: causalTaskID,
            hopCount: admission.hopCount,
            visitedAgents: admission.visitedAgents,
            attempt: 1)
        var preflightScheduler = scheduler
        guard preflightScheduler.enqueue(scheduled, mode: .newTask).accepted else { return }
        do {
            try await appendAdmissionEvents([
                .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                    agent: recipient,
                    lease: prepared.capabilityLease,
                    metadata: metadata)),
                .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                    agent: recipient,
                    lease: prepared.workspaceLease,
                    metadata: metadata)),
                .taskCreated(TaskCreatedPayload(
                    contract: contract,
                    metadata: metadata)),
                .taskAssigned(TaskAssignedPayload(
                    contract: contract,
                    metadata: metadata)),
                .taskQueued(TaskQueuedPayload(
                    contract: contract,
                    rootTaskID: admission.rootTaskID,
                    issuer: batchKey.sender,
                    assignee: recipient,
                    causalParentID: causalTaskID,
                    hopCount: admission.hopCount,
                    visitedAgents: admission.visitedAgents,
                    attempt: 1,
                    reason: "mailbox delivery",
                    metadata: metadata)),
            ])
        } catch {
            await persistUncommittedAdmissionCancellation(
                task: scheduled,
                reason: "mailbox wake admission could not be persisted: \(error.localizedDescription)",
                metadata: metadata)
            try? await log.append(.error(ErrorPayload(
                code: "mailbox_wake_admission_persistence_failed",
                message: error.localizedDescription)))
            return
        }
        guard case .success = taskGraph.addRootTask(contract) else { return }
        capabilityLeases[prepared.capabilityLease.id] = prepared.capabilityLease
        workspaceLeases[prepared.workspaceLease.id] = prepared.workspaceLease
        _ = taskGraph.updateStatus(taskID: contract.id, status: .assigned)
        guard scheduler.enqueue(scheduled, mode: .newTask).accepted else { return }
        _ = taskGraph.updateStatus(taskID: contract.id, status: .queued)
        ensureSchedulerRunning()
    }

    private func mailboxWakeDisposition(
        for recipient: AgentID,
        fallbackSender: AgentID,
        requestedMessageIDs: [MessageID]?
    ) async -> MailboxWakeDisposition {
        let requested = requestedMessageIDs.map(Set.init)
        let candidates = scheduler.peekMessages(for: recipient).filter { message in
            requested.map { $0.contains(message.id) } ?? true
        }
        guard !candidates.isEmpty else { return .exhausted }

        var scheduledTaskID: TaskID?
        var sawExhausted = false
        var sawAmbiguity = false
        for (index, message) in candidates.enumerated() {
            switch await mailboxMessageBinding(for: message) {
            case .alreadyScheduled(let taskID):
                scheduledTaskID = scheduledTaskID ?? taskID
            case .retry(let taskID):
                return .retry(taskID)
            case .exhausted:
                sawExhausted = true
            case .ambiguous:
                sawAmbiguity = true
            case .unbound:
                guard let key = mailboxDeliveryBatchKey(
                    for: message,
                    fallbackSender: fallbackSender) else {
                    sawAmbiguity = true
                    continue
                }
                var batch: [PendingAgentMessage] = []
                for candidate in candidates[index...] where batch.count < 8 {
                    guard mailboxDeliveryBatchKey(
                        for: candidate,
                        fallbackSender: fallbackSender) == key else {
                        continue
                    }
                    if case .unbound = await mailboxMessageBinding(for: candidate) {
                        batch.append(candidate)
                    }
                }
                if !batch.isEmpty { return .admitNew(batch) }
            }
        }
        if sawAmbiguity { return .ambiguous }
        if sawExhausted { return .exhausted }
        if let scheduledTaskID { return .alreadyScheduled(scheduledTaskID) }
        return .ambiguous
    }

    private func mailboxMessageBinding(
        for message: PendingAgentMessage
    ) async -> MailboxMessageBinding {
        let explicit = explicitMailboxTasks(for: message.id)
        if explicit.count > 1 { return .ambiguous }
        if let match = explicit.first {
            return await mailboxMessageBinding(
                task: match.task,
                record: match.record,
                legacy: false)
        }

        let legacy = matchingLegacyMailboxTasks(for: message)
        if legacy.count > 1 {
            if legacy.contains(where: {
                mailboxTaskAttemptIsExhausted($0.task, record: $0.record)
            }) {
                return .exhausted
            }
            return .ambiguous
        }
        guard let match = legacy.first else { return .unbound }
        if match.record?.status == .completed {
            // A successful legacy delivery that left the message pending may
            // migrate once to an exact MessageID-bound task, provided its
            // lineage never exhausted the bounded attempt budget.
            return .unbound
        }
        return await mailboxMessageBinding(
            task: match.task,
            record: match.record,
            legacy: true)
    }

    private func mailboxMessageBinding(
        task: ScheduledTask,
        record: ExecutionRecord?,
        legacy: Bool
    ) async -> MailboxMessageBinding {
        guard let record else { return .ambiguous }
        switch record.status {
        case .created, .assigned, .queued, .running:
            return .alreadyScheduled(task.contract.id)
        case .completed:
            return legacy ? .unbound : .exhausted
        case .failed, .cancelled:
            guard !mailboxTaskAttemptIsExhausted(task, record: record),
                  let attempt = record.attempt,
                  await taskReplayBlockReason(
                      taskID: task.contract.id,
                      attempt: attempt) == nil else {
                return .exhausted
            }
            return .retry(task.contract.id)
        }
    }

    private func explicitMailboxTasks(
        for messageID: MessageID
    ) -> [(task: ScheduledTask, record: ExecutionRecord?)] {
        let snapshot = scheduler.snapshot()
        return snapshot.knownTasks.values
            .filter {
                $0.contract.kind == .mailboxDelivery
                    && $0.contract.mailboxMessageIDs?.contains(messageID) == true
            }
            .sorted { $0.contract.id.rawValue < $1.contract.id.rawValue }
            .map { ($0, snapshot.records[$0.contract.id]) }
    }

    private func matchingLegacyMailboxTasks(
        for message: PendingAgentMessage
    ) -> [(task: ScheduledTask, record: ExecutionRecord?)] {
        let snapshot = scheduler.snapshot()
        let causalTaskID = message.causalParentID ?? message.taskID
        let causalContract = causalTaskID.flatMap {
            taskGraph.node($0)?.contract ?? snapshot.knownTasks[$0]?.contract
        }
        let expectedRelatedTasks = causalTaskID.map { [$0] } ?? []
        return snapshot.knownTasks.values
            .filter { task in
                task.contract.kind == .mailboxDelivery
                    && task.contract.mailboxMessageIDs == nil
                    && task.assignee == message.recipient
                    && task.issuer == message.sender
                    && task.causalParentID == causalTaskID
                    && task.contract.relatedTasks == expectedRelatedTasks
                    && task.contract.goalID == causalContract?.goalID
                    && task.contract.continuationRunID == causalContract?.continuationRunID
                    && {
                        guard let createdAt = taskGraph.node(task.contract.id)?.createdAt,
                              createdAt != .distantPast else { return true }
                        return createdAt >= message.createdAt
                    }()
            }
            .sorted { $0.contract.id.rawValue < $1.contract.id.rawValue }
            .map { ($0, snapshot.records[$0.contract.id]) }
    }

    private func mailboxTaskAttemptIsExhausted(
        _ task: ScheduledTask,
        record: ExecutionRecord?
    ) -> Bool {
        guard let attempt = record?.attempt else { return true }
        let maxAttempts = task.contract.maxAttempts ?? executionPolicy.maxAttempts
        return attempt >= maxAttempts
    }

    private func shouldAutomaticallyRetryMailboxTask(
        _ task: ScheduledTask
    ) async -> Bool {
        guard task.contract.kind == .mailboxDelivery,
              let record = scheduler.record(for: task.contract.id),
              record.status == .failed,
              !mailboxTaskAttemptIsExhausted(task, record: record),
              let attempt = record.attempt,
              !isGoalRunCancellationRequested(
                  goalID: task.contract.goalID,
                  continuationRunID: task.contract.continuationRunID) else {
            return false
        }
        let pending = scheduler.peekMessages(for: task.assignee)
        let hasPendingBinding: Bool
        if let exactIDs = task.contract.mailboxMessageIDs {
            let frozen = Set(exactIDs)
            hasPendingBinding = pending.contains { frozen.contains($0.id) }
        } else {
            hasPendingBinding = pending.contains { message in
                let lineage = matchingLegacyMailboxTasks(for: message)
                guard lineage.contains(where: { $0.task.contract.id == task.contract.id }) else {
                    return false
                }
                return !lineage.contains(where: {
                    mailboxTaskAttemptIsExhausted($0.task, record: $0.record)
                })
            }
        }
        guard hasPendingBinding else { return false }
        return await taskReplayBlockReason(
            taskID: task.contract.id,
            attempt: attempt) == nil
    }

    private func mailboxDeliveryBatchKey(
        for message: PendingAgentMessage,
        fallbackSender: AgentID
    ) -> MailboxDeliveryBatchKey? {
        let sender = message.sender ?? fallbackSender
        guard sender != message.recipient else { return nil }
        let causalTaskID = message.causalParentID ?? message.taskID
        let causalContract = causalTaskID.flatMap {
            taskGraph.node($0)?.contract ?? scheduler.knownTask(taskID: $0)?.contract
        }
        return MailboxDeliveryBatchKey(
            sender: sender,
            recipient: message.recipient,
            goalID: causalContract?.goalID,
            continuationRunID: causalContract?.continuationRunID,
            authorityClass: {
                switch message.kind {
                case AgentCommunicationKind.requestInformation.rawValue:
                    return .informationRequest
                case AgentCommunicationKind.replyMessage.rawValue:
                    return .informationReply
                default:
                    return .ordinaryMessage
                }
            }())
    }

    func createRootTask(assignee: AgentID,
                        objective: String,
                        roleHint: String = "root task coordinator",
                        expectedDeliverable: String = "Coordinate assigned subtasks and synthesize the result.",
                        goalID: GoalID? = nil,
                        continuationRunID: ContinuationRunID? = nil,
                        submissionID: SubmissionID? = nil) async -> TaskID? {
        switch await createRootTaskResult(
            assignee: assignee,
            objective: objective,
            roleHint: roleHint,
            expectedDeliverable: expectedDeliverable,
            goalID: goalID,
            continuationRunID: continuationRunID,
            submissionID: submissionID) {
        case .created(let taskID):
            return taskID
        case .failed:
            return nil
        }
    }

    private func createRootTaskResult(
        assignee: AgentID,
        objective: String,
        roleHint: String,
        expectedDeliverable: String,
        goalID: GoalID?,
        continuationRunID: ContinuationRunID?,
        submissionID: SubmissionID?
    ) async -> RootTaskCreationResult {
        guard assignee != Self.automaticPermissionReviewerID else {
            return .failed("@permission-reviewer cannot receive root tasks.")
        }
        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        guard let liveAgent = registry.agent(assignee),
              let workspaceLeaseID = defaultWorkspaceLeaseIDs[liveAgent.name],
              let workspaceLease = workspaceLeases[workspaceLeaseID],
              let capabilityLeaseID = defaultCapabilityLeaseIDs[liveAgent.name],
              capabilityLeases[capabilityLeaseID] != nil else {
            return .failed("The root task assignee or its default leases are unavailable.")
        }
        let agent = liveAgent
        let contract = TaskContract(
            kind: .root,
            issuer: nil,
            assignee: agent.name,
            continuationRunID: continuationRunID,
            goalID: goalID,
            submissionID: submissionID,
            objective: objective.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Coordinate the cowork task.",
            roleHint: roleHint,
            expectedDeliverable: expectedDeliverable,
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLeaseID,
            capabilityLeaseID: capabilityLeaseID,
            agentInferenceBinding: agent.agentInferenceBinding,
            relatedAgents: agentVisibleNames(excluding: agent.name),
            replyMode: TaskReplyMode.none,
            executionTimeoutSeconds: executionPolicy.taskTimeoutSeconds,
            maxAttempts: executionPolicy.maxAttempts)
        var preflightGraph = taskGraph
        switch preflightGraph.addRootTask(contract) {
        case .success:
            let metadata = taskMetadata(
                contract: contract,
                rootTaskID: contract.id,
                parentTaskID: nil,
                sender: contract.issuer,
                recipient: contract.assignee)
            let createdEvent = Event.taskCreated(TaskCreatedPayload(
                contract: contract,
                metadata: metadata))
            let assignedEvent = Event.taskAssigned(TaskAssignedPayload(
                contract: contract,
                metadata: metadata))
            do {
                try await appendAdmissionEvent(createdEvent)
                try await appendAdmissionEvent(assignedEvent)
            } catch {
                try? await log.append(.error(ErrorPayload(
                    code: "root_admission_persistence_failed",
                    message: error.localizedDescription)))
                return .failed(
                    "Root task admission could not be persisted: \(error.localizedDescription)")
            }
            guard case .success = taskGraph.addRootTask(contract) else {
                return .failed("Root task admission could not be committed after persistence.")
            }
            _ = taskGraph.updateStatus(taskID: contract.id, status: .assigned)
            return .created(contract.id)
        case .failure(let violation):
            try? await log.append(.error(ErrorPayload(
                code: "task_graph_rejected",
                message: violation.message)))
            try? await log.append(.taskRejected(TaskRejectedPayload(
                contract: contract,
                requester: contract.issuer,
                assignee: contract.assignee,
                objective: contract.objective,
                reason: violation.message,
                violationKind: violation.kind.rawValue,
                metadata: taskMetadata(contract: contract, rootTaskID: contract.id))))
            return .failed(violation.message)
        }
    }

    func delegateAuthorizedTask(
        from: AgentID,
        authorization: ResolvedToolAuthorization,
        executionID: String,
        to reviewedTarget: String,
        workTaskID: WorkTaskID? = nil,
        objective: String? = nil,
        roleHint: String? = nil,
        expectedDeliverable: String? = nil,
        parentTaskID: TaskID? = nil
    ) async -> String {
        guard authorization.toolName == "delegate_task",
              authorization.agent == from,
              authorization.taskID == parentTaskID,
              let authorizedTargetValue = authorization.intent.resources.first(where: {
                  $0.kind == .agent
              })?.value else {
            return "error: delegate_task authorization binding is invalid"
        }
        let target = AgentID(rawValue: Self.normalizedAgentName(reviewedTarget))
        guard target.rawValue == authorizedTargetValue,
              !target.rawValue.isEmpty,
              target.rawValue.lowercased() != "auto" else {
            return "error: delegate_task target differs from the reviewed authorization"
        }
        if let failure = authorizationRevalidationFailure(authorization) {
            return "error: \(failure)"
        }
        guard let delegatedKnowledgeGrant = Self.delegatedKnowledgeGrant(
            from: authorization) else {
            return "error: delegate_task Knowledge capability authorization is invalid"
        }

        let durableTask = workTaskID.flatMap { workTaskGraph.task($0) }
        if let workTaskID, durableTask == nil {
            return "error: no WorkTask named " + workTaskID.rawValue
        }
        let suppliedObjective = objective?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        guard let effectiveObjective = suppliedObjective ?? durableTask?.description.nilIfEmpty else {
            return "error: delegate_task requires a ready WorkTask or a non-empty unscoped objective"
        }

        guard !automaticDelegationReservations.contains(target) else {
            return "error: reviewed delegation target is already reserved by another invocation"
        }
        automaticDelegationReservations.insert(target)
        defer { automaticDelegationReservations.remove(target) }
        if let failure = authorizationRevalidationFailure(
            authorization,
            allowingDelegationReservationFor: target
        ) {
            return "error: \(failure)"
        }
        guard let existing = registry.agent(target) else {
            return "error: reviewed delegation target is no longer attached"
        }
        guard case .string(let targetFingerprint)? =
                authorization.intent.metadata["targetFingerprint"],
              delegationTargetFingerprint(existing) == targetFingerprint else {
            return "error: reviewed delegation target identity changed"
        }

        let authorizedAdmission = AuthorizedDelegationAdmission(
            authorization: authorization,
            target: target,
            binding: authorization.targetAgentInferenceBinding,
            targetFingerprint: targetFingerprint,
            knowledgeCapabilities: delegatedKnowledgeGrant.capabilities,
            workspaceAccess: delegatedKnowledgeGrant.workspaceAccess)

        let queued = await enqueueDelegatedTask(
            from: from,
            to: target.rawValue,
            workTaskID: workTaskID,
            objective: effectiveObjective,
            roleHint: roleHint,
            expectedDeliverable: expectedDeliverable ?? durableTask.map {
                $0.acceptanceCriteria.isEmpty
                    ? "Return a candidate result for WorkTask " + $0.id.rawValue + "."
                    : $0.acceptanceCriteria.joined(separator: "; ")
            },
            parentTaskID: parentTaskID,
            replyMode: .taskReport,
            authorizedAdmission: authorizedAdmission,
            invocationTaskID: Self.delegationInvocationTaskID(executionID))
        guard let taskID = queued.taskID else {
            return queued.message
        }
        scheduledReplyTargets[taskID] = from
        scheduledReplyFormats[taskID] = .taskReport
        ensureSchedulerRunning()
        let report = await awaitSchedulerResult(taskID) ?? queued.message
        let binding = workTaskID.map { " work_task_id=\($0.rawValue)" } ?? ""
        return "task_id=\(taskID.rawValue)\(binding) agent_id=@\(target.rawValue)\n\(report)"
    }

    func delegateTask(from: AgentID,
                      to requestedTarget: String?,
                      workTaskID: WorkTaskID? = nil,
                      objective: String? = nil,
                      roleHint: String? = nil,
                      expectedDeliverable: String? = nil,
                      parentTaskID: TaskID? = nil) async -> String {
        let durableTask = workTaskID.flatMap { workTaskGraph.task($0) }
        if let workTaskID, durableTask == nil {
            return "error: no WorkTask named " + workTaskID.rawValue
        }
        let suppliedObjective = objective?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        guard let effectiveObjective = suppliedObjective ?? durableTask?.description.nilIfEmpty else {
            return "error: delegate_task requires a ready WorkTask or a non-empty unscoped objective"
        }
        guard let resolution = await resolveDelegationTarget(
            requestedBy: from,
            requestedTarget: requestedTarget) else {
            return "error: no available attached delegation worker; spawn one in an earlier tool-call round"
        }
        let target = resolution.agent
        defer {
            if resolution.automaticallyReserved {
                automaticDelegationReservations.remove(target)
            }
        }
        let queued = await enqueueDelegatedTask(
            from: from,
            to: target.rawValue,
            workTaskID: workTaskID,
            objective: effectiveObjective,
            roleHint: roleHint,
            expectedDeliverable: expectedDeliverable ?? durableTask.map {
                $0.acceptanceCriteria.isEmpty
                    ? "Return a candidate result for WorkTask " + $0.id.rawValue + "."
                    : $0.acceptanceCriteria.joined(separator: "; ")
            },
            parentTaskID: parentTaskID,
            replyMode: .taskReport)
        guard let taskID = queued.taskID else {
            return queued.message
        }
        scheduledReplyTargets[taskID] = from
        scheduledReplyFormats[taskID] = .taskReport
        ensureSchedulerRunning()
        let report = await awaitSchedulerResult(taskID) ?? queued.message
        let binding = workTaskID.map { " work_task_id=\($0.rawValue)" } ?? ""
        return "task_id=\(taskID.rawValue)\(binding) agent_id=@\(target.rawValue)\n\(report)"
    }

    private func resolveDelegationTarget(requestedBy: AgentID,
                                         requestedTarget: String?) async -> (
        agent: AgentID,
        automaticallyReserved: Bool
    )? {
        guard let requester = registry.agent(requestedBy) else { return nil }
        let normalized = requestedTarget.map(Self.normalizedAgentName)
            .flatMap { $0.isEmpty || $0.lowercased() == "auto" ? nil : $0 }
        if let normalized {
            let requestedID = AgentID(rawValue: normalized)
            guard requestedID != Self.mainAgentID,
                  requestedID != Self.automaticPermissionReviewerID else { return nil }
            if let existing = registry.agent(requestedID),
               inferenceBindingIsReady(existing) {
                return (requestedID, false)
            }
            return nil
        }

        if let idle = registry.all()
            .filter({ candidate in
                candidate.name != requestedBy
                    && candidate.name != Self.mainAgentID
                    && candidate.name != Self.automaticPermissionReviewerID
                    && inferenceBindingIsReady(candidate)
                    && candidate.workspaceRoot.standardizedFileURL.path
                        == requester.workspaceRoot.standardizedFileURL.path
                    && !automaticDelegationReservations.contains(candidate.name)
                    && isAgentAvailableForDelegation(candidate.name)
            })
            .sorted(by: { $0.name.rawValue < $1.name.rawValue })
            .first {
            automaticDelegationReservations.insert(idle.name)
            return (idle.name, true)
        }
        return nil
    }

    private func isAgentAvailableForDelegation(_ agentID: AgentID) -> Bool {
        let mailbox = scheduler.mailbox(for: agentID)
        guard mailbox.pendingTasks.isEmpty, mailbox.pendingMessages.isEmpty else { return false }
        guard !scheduler.queuedTasks().contains(where: {
            $0.assignee == agentID || $0.issuer == agentID
        }) else { return false }
        return !taskGraph.nodes.values.contains { node in
            Self.isActiveTaskStatus(node.status)
                && (node.assignee == agentID || node.issuer == agentID)
        }
    }

    private static func delegationInvocationTaskID(_ executionID: String) -> TaskID {
        TaskID(rawValue: "task_delegate_" + executionID)
    }

    func enqueueDelegatedTask(from: AgentID,
                              to toName: String,
                              workTaskID: WorkTaskID? = nil,
                              objective: String,
                              roleHint: String? = nil,
                              expectedDeliverable: String? = nil,
                              parentTaskID: TaskID? = nil,
                              replyMode: TaskReplyMode = .taskReport) async -> (taskID: TaskID?, message: String) {
        await enqueueDelegatedTask(
            from: from,
            to: toName,
            workTaskID: workTaskID,
            objective: objective,
            roleHint: roleHint,
            expectedDeliverable: expectedDeliverable,
            parentTaskID: parentTaskID,
            replyMode: replyMode,
            authorizedAdmission: nil,
            invocationTaskID: nil)
    }

    private func enqueueDelegatedTask(
        from: AgentID,
        to toName: String,
        workTaskID: WorkTaskID? = nil,
        objective: String,
        roleHint: String? = nil,
        expectedDeliverable: String? = nil,
        parentTaskID: TaskID? = nil,
        replyMode: TaskReplyMode = .taskReport,
        authorizedAdmission: AuthorizedDelegationAdmission?,
        invocationTaskID: TaskID?
    ) async -> (taskID: TaskID?, message: String) {
        let normalizedName = Self.normalizedAgentName(toName)
        let to = AgentID(rawValue: normalizedName)
        guard to != Self.automaticPermissionReviewerID else {
            return (nil, "@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review")
        }
        guard let targetBeforeMediation = registry.agent(to) else {
            return (nil, "no such agent: \(toName)")
        }
        if let authorizedAdmission,
           let failure = finalDelegationAuthorizationFailure(
               authorizedAdmission,
               expectedFrom: from,
               expectedTaskID: parentTaskID,
               allowingReservationFor: to
           ) {
            return (nil, "error: \(failure)")
        }
        if let delegationFailure = delegationFailure(
            from: from,
            to: to,
            parentTaskID: parentTaskID) {
            return (nil, "error: \(delegationFailure)")
        }
        if authorizedAdmission != nil, requiresInferenceBindings {
            do {
                _ = try await resolvedProvider(for: targetBeforeMediation)
            } catch {
                return (nil, "error: selected inference profile revision is unavailable or incompatible")
            }
        }
        guard let mediatedObjective = await bus.mediate(
            from: from,
            to: to,
            content: objective) else {
            return (nil, "error: delegated task was blocked by the mediator")
        }

        // Mediation and exact provider resolution may suspend on external
        // actors. Keep them outside the admission lock, then repeat every
        // mutable-state check while holding the lock before the one EventLog
        // batch. Authorized calls retain their target reservation throughout.
        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        if workTaskID != nil, let workTaskRecoveryFailure {
            return (nil, "error: \(workTaskRecoveryFailure)")
        }
        guard let currentTarget = registry.agent(to) else {
            return (nil, "no such agent: \(toName)")
        }
        if let authorizedAdmission,
           let failure = finalDelegationAuthorizationFailure(
               authorizedAdmission,
               expectedFrom: from,
               expectedTaskID: parentTaskID,
               allowingReservationFor: to
           ) {
            return (nil, "error: \(failure)")
        }
        if let delegationFailure = delegationFailure(
            from: from,
            to: to,
            parentTaskID: parentTaskID) {
            return (nil, "error: \(delegationFailure)")
        }
        let boundWorkTask: WorkTask?
        if let workTaskID {
            guard let task = workTaskGraph.task(workTaskID) else {
                return (nil, "error: no WorkTask named \(workTaskID.rawValue)")
            }
            guard let callerLease = existingCapabilityLease(for: from, taskID: parentTaskID),
                  callerLease.tools.contains(.manageWorkTasks) else {
                return (nil, "error: the current capability lease cannot delegate durable WorkTasks")
            }
            boundWorkTask = task
        } else {
            boundWorkTask = nil
        }
        let resolvedInvocationTaskID = invocationTaskID ?? TaskID.new()
        if let existing = taskGraph.node(resolvedInvocationTaskID) {
            guard existing.contract.issuer == from,
                  existing.contract.assignee == to,
                  existing.contract.parentTaskID == parentTaskID,
                  existing.contract.workTaskID == workTaskID,
                  existing.contract.objective == mediatedObjective else {
                return (nil, "error: delegate execution identity is already bound to a different invocation")
            }
            return (
                existing.id,
                "task already admitted: \(existing.id.rawValue)")
        }
        if let task = boundWorkTask {
            guard task.status == .ready || task.status == .inProgress else {
                return (nil, "error: WorkTask \(task.id.rawValue) is \(task.status.rawValue), not delegatable")
            }
            switch workTaskGraph.readiness(of: task.id) {
            case .success(.ready):
                break
            case .success(.waitingFor(let dependencies)):
                return (nil, "error: WorkTask is waiting for dependencies: "
                    + dependencies.map(\.rawValue).sorted().joined(separator: ", "))
            case .success(.blockedBy(let dependencies)):
                return (nil, "error: WorkTask has terminal dependencies: "
                    + dependencies.map(\.rawValue).sorted().joined(separator: ", "))
            case .failure(let violation):
                return (nil, "error: \(violation.message)")
            }
            if let activeInvocationID = task.latestInvocationIDs.first(where: {
                guard let node = taskGraph.node($0) else { return false }
                return Self.isActiveTaskStatus(node.status)
            }) {
                return (nil, "error: WorkTask already has active invocation \(activeInvocationID.rawValue)")
            }
        }
        let prepared = prepareDelegatedTask(
            taskID: resolvedInvocationTaskID,
            issuer: from,
            assignee: currentTarget,
            workTask: boundWorkTask,
            objective: mediatedObjective,
            roleHint: roleHint,
            expectedDeliverable: expectedDeliverable,
            parentTaskID: parentTaskID,
            scopeContract: parentTaskID.flatMap {
                taskGraph.node($0)?.contract ?? scheduler.knownTask(taskID: $0)?.contract
            },
            replyMode: replyMode,
            additionalToolCapabilities:
                authorizedAdmission?.knowledgeCapabilities ?? [],
            workspaceAccessOverride:
                authorizedAdmission?.workspaceAccess)
        let contract = prepared.contract
        if let authorizedAdmission,
           contract.agentInferenceBinding != authorizedAdmission.binding {
            return (nil, "error: delegated task inference profile differs from the reviewed authorization")
        }
        if let authorizedAdmission {
            guard authorizedAdmission.knowledgeCapabilities.isSubset(
                    of: prepared.capabilityLease.tools),
                  prepared.workspaceLease.access
                    == authorizedAdmission.workspaceAccess else {
                return (nil, "error: delegated Knowledge lease differs from the reviewed authorization")
            }
        }
        guard !isGoalRunCancellationRequested(
            goalID: contract.goalID,
            continuationRunID: contract.continuationRunID) else {
            return (nil, "error: Goal continuation cancellation is pending")
        }
        if let boundWorkTask,
           let conflict = workTaskResourceConflict(
               candidate: boundWorkTask,
               target: currentTarget,
               capabilityLease: prepared.capabilityLease) {
            return (nil, "error: WorkTask resource conflict: \(conflict)")
        }

        let admission: TaskGraphAdmission
        var preflightGraph = taskGraph
        switch preflightGraph.addTask(contract) {
        case .success(let accepted):
            admission = accepted
        case .failure(let violation):
            return (nil, Self.delegationRejectionMessage(for: violation))
        }

        let metadata = taskMetadata(
            contract: contract,
            rootTaskID: admission.rootTaskID,
            parentTaskID: parentTaskID,
            sender: from,
            recipient: currentTarget.name)

        let scheduled = ScheduledTask(
            contract: contract,
            input: contract.objective,
            rootTaskID: admission.rootTaskID,
            parentTaskID: parentTaskID,
            issuer: from,
            assignee: currentTarget.name,
            causalParentID: parentTaskID,
            hopCount: admission.hopCount,
            visitedAgents: admission.visitedAgents,
            attempt: 1)
        var preflightScheduler = scheduler
        guard preflightScheduler.enqueue(scheduled, mode: .newTask).accepted,
              preflightGraph.updateStatus(taskID: contract.id, status: .assigned),
              preflightGraph.updateStatus(taskID: contract.id, status: .queued) else {
            return (nil, "error: scheduler rejected delegated task")
        }
        var preflightWorkTaskGraph = workTaskGraph
        var workTaskEvents: [Event] = []
        if let boundWorkTask {
            let taskToLink: WorkTask
            if boundWorkTask.status == .ready {
                switch preflightWorkTaskGraph.transition(
                    taskID: boundWorkTask.id,
                    to: .inProgress,
                    expectedRevision: boundWorkTask.revision,
                    progressNote: "delegated to @\(currentTarget.name.rawValue)") {
                case .success(let started):
                    taskToLink = started
                    workTaskEvents.append(
                        .workTaskStarted(WorkTaskStartedPayload(task: started)))
                case .failure(let violation):
                    return (nil, "error: WorkTask admission failed: \(violation.message)")
                }
            } else {
                taskToLink = boundWorkTask
            }
            let linked: WorkTask
            switch preflightWorkTaskGraph.linkInvocation(
                taskID: taskToLink.id,
                invocationID: contract.id,
                expectedRevision: taskToLink.revision) {
            case .success(let task):
                linked = task
            case .failure(let violation):
                return (nil, "error: WorkTask invocation link failed: \(violation.message)")
            }
            workTaskEvents.append(
                .workTaskInvocationLinked(WorkTaskInvocationLinkedPayload(
                    task: linked,
                    invocationID: contract.id)))
        }
        do {
            try await appendAdmissionEvents([
                .agentToAgentMessage(AgentToAgentMessagePayload(
                    from: from,
                    to: currentTarget.name,
                    content: mediatedObjective,
                    mediated: true)),
                .permissionReview(PermissionReviewPayload(
                    agent: from,
                    tool: "agent_forward",
                    reviewerModel: "mediator",
                    decision: .allow,
                    risk: .low,
                    reason: "forwarded after mediation")),
                .delegationApproved(DelegationApprovedPayload(
                    contract: contract,
                    metadata: metadata)),
                .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                    agent: currentTarget.name,
                    lease: prepared.capabilityLease,
                    metadata: metadata)),
                .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                    agent: currentTarget.name,
                    lease: prepared.workspaceLease,
                    metadata: metadata)),
                .taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)),
                .taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)),
                .taskDelegated(TaskDelegatedPayload(contract: contract, metadata: metadata)),
                .taskQueued(TaskQueuedPayload(
                    contract: contract,
                    rootTaskID: scheduled.rootTaskID,
                    parentTaskID: scheduled.parentTaskID,
                    issuer: scheduled.issuer,
                    assignee: scheduled.assignee,
                    causalParentID: scheduled.causalParentID,
                    hopCount: scheduled.hopCount,
                    visitedAgents: scheduled.visitedAgents,
                    attempt: 1,
                    reason: "delegation admitted",
                    metadata: metadata)),
            ] + workTaskEvents)
        } catch {
            return (nil, "error: delegated task admission could not be persisted")
        }
        taskGraph = preflightGraph
        scheduler = preflightScheduler
        capabilityLeases[prepared.capabilityLease.id] = prepared.capabilityLease
        workspaceLeases[prepared.workspaceLease.id] = prepared.workspaceLease
        workTaskGraph = preflightWorkTaskGraph
        return (contract.id, "task queued: \(contract.id.rawValue)")
    }

    // MARK: - Durable WorkTask control plane

    private func validatedRestoredWorkTaskGraph(
        from projection: CoworkProjection
    ) -> Result<WorkTaskGraph, WorkTaskGraphViolation> {
        WorkTaskGraph.validating(Array(projection.workTaskGraph.tasks.values))
    }

    private func failClosedWorkTaskRestore(_ violation: WorkTaskGraphViolation) async {
        let message = "WorkTaskGraph recovery rejected: \(violation.message)"
        workTaskGraph = WorkTaskGraph()
        workTaskRecoveryFailure = message
        try? await log.append(.error(ErrorPayload(
            code: "work_task_graph_restore_rejected",
            message: message)))
    }

    private func requireValidWorkTaskGraph() throws {
        if let workTaskRecoveryFailure {
            throw IntatisError.config(workTaskRecoveryFailure)
        }
    }

    private static func provenWorkTaskCreatePreflightRejection(
        _ error: Error
    ) -> ToolExecutionRejectedWithoutSideEffect {
        if let violation = error as? WorkTaskGraphViolation {
            return ToolExecutionRejectedWithoutSideEffect(
                code: violation.kind.rawValue,
                message: "task_create rejected without creating a WorkTask: \(violation.message). Confirm every depends_on ID through an earlier successful task_create, task_get, or task_list ToolResult, then retry in a later tool-call round.")
        }

        let code: String
        let recovery: String
        if let intatisError = error as? IntatisError {
            switch intatisError {
            case .permissionDenied:
                code = "permission_denied"
                recovery = "Use only a capability lease that can manage WorkTasks."
            case .notFound:
                code = "not_found"
                recovery = "Refresh the current Session WorkTask state before retrying."
            case .decoding:
                code = "invalid_create"
                recovery = "Correct the task_create arguments and retry."
            case .config:
                code = "invalid_state"
                recovery = "Refresh the current Session WorkTask state before retrying."
            case .provider:
                code = "provider_error"
                recovery = "Refresh the authoritative WorkTask state before retrying."
            case .io:
                code = "io_error"
                recovery = "Refresh the authoritative WorkTask state before retrying."
            case .cancelled:
                code = "cancelled"
                recovery = "Retry only if the current turn is still active."
            }
        } else {
            code = "preflight_rejected"
            recovery = "Refresh the authoritative WorkTask state before retrying."
        }
        return ToolExecutionRejectedWithoutSideEffect(
            code: code,
            message: "task_create rejected without creating a WorkTask: \(error.localizedDescription). \(recovery)")
    }

    func createWorkTask(canManage: Bool,
                        request: WorkTaskCreateRequest,
                        provePreflightRejectionHasNoEffect: Bool = false) async throws -> WorkTaskDetail {
        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }

        let preparedGraph: WorkTaskGraph
        let preparedEvents: [Event]
        let created: WorkTask
        do {
            guard canManage else {
                throw IntatisError.permissionDenied("the current capability lease cannot create WorkTasks")
            }
            let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let description = request.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !description.isEmpty else {
                throw IntatisError.decoding("WorkTask title and description must be non-empty")
            }
            try requireValidWorkTaskGraph()

            var preflight = workTaskGraph
            var proposed = WorkTask(
                title: title,
                description: description,
                acceptanceCriteria: request.acceptanceCriteria,
                expectedArtifacts: request.expectedArtifacts,
                status: .pending,
                priority: request.priority,
                dependsOn: request.dependsOn)
            switch preflight.add(proposed) {
            case .success:
                break
            case .failure(let violation):
                throw violation
            }

            var events: [Event] = [.workTaskCreated(WorkTaskCreatedPayload(task: proposed))]
            switch preflight.readiness(of: proposed.id) {
            case .success(.ready):
                switch preflight.transition(
                    taskID: proposed.id,
                    to: .ready,
                    expectedRevision: proposed.revision) {
                case .success(let ready):
                    proposed = ready
                    events.append(.workTaskReady(WorkTaskReadyPayload(task: ready)))
                case .failure(let violation):
                    throw violation
                }
            case .success(.waitingFor):
                break
            case .success(.blockedBy(let dependencyIDs)):
                let blocker = "dependency failed or was cancelled: "
                    + dependencyIDs.map(\.rawValue).sorted().joined(separator: ", ")
                switch preflight.transition(
                    taskID: proposed.id,
                    to: .blocked,
                    expectedRevision: proposed.revision,
                    progressNote: blocker) {
                case .success(let blocked):
                    proposed = blocked
                    events.append(.workTaskBlocked(WorkTaskBlockedPayload(
                        task: blocked,
                        blocker: blocker)))
                case .failure(let violation):
                    throw violation
                }
            case .failure(let violation):
                throw violation
            }
            preparedGraph = preflight
            preparedEvents = events
            created = proposed
        } catch {
            guard provePreflightRejectionHasNoEffect else {
                throw error
            }
            // This scope ends before the first EventLog append. Persistence
            // failures and lost acknowledgements below deliberately remain
            // side-effect-unknown and require reconciliation.
            throw Self.provenWorkTaskCreatePreflightRejection(
                error)
        }

        try await appendAdmissionEvents(preparedEvents)
        workTaskGraph = preparedGraph
        return workTaskDetail(created)
    }

    private static func normalizingRepeatedWorkTaskContractFields(
        _ request: WorkTaskUpdateRequest,
        against current: WorkTask
    ) -> WorkTaskUpdateRequest {
        var normalized = request
        if normalized.title == current.title {
            normalized.title = nil
        }
        if normalized.description == current.description {
            normalized.description = nil
        }
        if normalized.acceptanceCriteria == current.acceptanceCriteria {
            normalized.acceptanceCriteria = nil
        }
        if normalized.expectedArtifacts == current.expectedArtifacts {
            normalized.expectedArtifacts = nil
        }
        if normalized.dependsOn == current.dependsOn {
            normalized.dependsOn = nil
        }
        if normalized.priority == current.priority {
            normalized.priority = nil
        }
        return normalized
    }

    private static func provenWorkTaskUpdatePreflightRejection(
        _ error: Error,
        request: WorkTaskUpdateRequest
    ) -> ToolExecutionRejectedWithoutSideEffect {
        if let violation = error as? WorkTaskGraphViolation {
            if violation.kind == .staleRevision,
               violation.taskID == request.taskID,
               violation.expectedRevision == request.expectedRevision,
               let actualRevision = violation.actualRevision {
                return ToolExecutionRejectedWithoutSideEffect(
                    code: violation.kind.rawValue,
                    message: "task_update rejected without applying changes: expected_revision \(request.expectedRevision) is stale; the current revision is \(actualRevision). Call task_get for task_id \"\(request.taskID.rawValue)\", merge against the authoritative task state, then retry task_update using that revision as expected_revision.")
            }
            return ToolExecutionRejectedWithoutSideEffect(
                code: violation.kind.rawValue,
                message: "task_update rejected without applying changes: \(violation.message). Call task_get for task_id \"\(request.taskID.rawValue)\", then retry with the authoritative revision and only the fields that must change.")
        }

        let code: String
        if let intatisError = error as? IntatisError {
            switch intatisError {
            case .permissionDenied:
                code = "permission_denied"
            case .notFound:
                code = "not_found"
            case .decoding:
                code = "invalid_update"
            case .config:
                code = "invalid_state"
            case .provider:
                code = "provider_error"
            case .io:
                code = "io_error"
            case .cancelled:
                code = "cancelled"
            }
        } else {
            code = "preflight_rejected"
        }
        return ToolExecutionRejectedWithoutSideEffect(
            code: code,
            message: "task_update rejected without applying changes: \(error.localizedDescription). Call task_get for task_id \"\(request.taskID.rawValue)\", then retry with the authoritative revision and only the fields that must change.")
    }

    func updateWorkTask(currentWorkTaskID: WorkTaskID?,
                        canManage: Bool,
                        canUpdateBound: Bool,
                        request: WorkTaskUpdateRequest,
                        provePreflightRejectionHasNoEffect: Bool = false) async throws -> WorkTaskDetail {
        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }

        let preparedGraph: WorkTaskGraph
        let preparedEvents: [Event]
        let updatedTaskID = request.taskID
        do {
            try requireValidWorkTaskGraph()

            guard let current = workTaskGraph.task(request.taskID) else {
                throw IntatisError.notFound("WorkTask \(request.taskID.rawValue)")
            }
            let normalizedRequest =
                Self.normalizingRepeatedWorkTaskContractFields(
                    request,
                    against: current)
            if !canManage {
                guard canUpdateBound,
                      currentWorkTaskID == current.id else {
                    throw IntatisError.permissionDenied(
                        "workers may update only the WorkTask bound to their current AgentInvocation")
                }
                guard normalizedRequest.title == nil,
                      normalizedRequest.description == nil,
                      normalizedRequest.acceptanceCriteria == nil,
                      normalizedRequest.expectedArtifacts == nil,
                      normalizedRequest.dependsOn == nil,
                      normalizedRequest.priority == nil,
                      !normalizedRequest.isRetry,
                      normalizedRequest.status != .ready,
                      normalizedRequest.status != .cancelled else {
                    throw IntatisError.permissionDenied(
                        "workers cannot change WorkTask graph, priority, retry, or cancellation state")
                }
            }
            if current.status == .inProgress {
                var changedContractFields: [String] = []
                if normalizedRequest.title != nil {
                    changedContractFields.append("title")
                }
                if normalizedRequest.description != nil {
                    changedContractFields.append("description")
                }
                if normalizedRequest.acceptanceCriteria != nil {
                    changedContractFields.append("acceptance_criteria")
                }
                if normalizedRequest.expectedArtifacts != nil {
                    changedContractFields.append("expected_artifacts")
                }
                if normalizedRequest.dependsOn != nil {
                    changedContractFields.append("depends_on")
                }
                if normalizedRequest.priority != nil {
                    changedContractFields.append("priority")
                }
                guard changedContractFields.isEmpty else {
                    throw IntatisError.permissionDenied(
                        "in-progress WorkTask execution contract is frozen: "
                            + changedContractFields.joined(separator: ", "))
                }
            }

            let hasMutation = normalizedRequest.title != nil
                || normalizedRequest.description != nil
                || normalizedRequest.acceptanceCriteria != nil
                || normalizedRequest.expectedArtifacts != nil
                || normalizedRequest.dependsOn != nil
                || normalizedRequest.priority != nil
                || normalizedRequest.progressNote != nil
                || normalizedRequest.status != nil
                || normalizedRequest.result != nil
                || normalizedRequest.evidence != nil
                || normalizedRequest.isRetry
            guard hasMutation else {
                throw IntatisError.decoding("task_update requires at least one mutable field")
            }

            var proposed = current
            if let title = normalizedRequest.title { proposed.title = title }
            if let description = normalizedRequest.description { proposed.description = description }
            if let criteria = normalizedRequest.acceptanceCriteria {
                proposed.acceptanceCriteria = criteria
            }
            if let artifacts = normalizedRequest.expectedArtifacts {
                proposed.expectedArtifacts = artifacts
            }
            if let dependencies = normalizedRequest.dependsOn {
                proposed.dependsOn = dependencies
            }
            if let priority = normalizedRequest.priority {
                proposed.priority = priority
            }
            if let progressNote = normalizedRequest.progressNote {
                proposed.progressNote = progressNote
            }
            if let status = normalizedRequest.status {
                proposed.status = status
            }
            if let result = normalizedRequest.result {
                proposed.result = result
            }
            if let evidence = normalizedRequest.evidence {
                proposed.evidence = evidence.map { $0.materialize() }
            }

            var preflight = workTaskGraph
            let updated: WorkTask
            switch preflight.update(
                proposed,
                expectedRevision: normalizedRequest.expectedRevision,
                isRetry: normalizedRequest.isRetry,
                recomputeReadinessAfterDependencyChange:
                    normalizedRequest.dependsOn != nil
                        && normalizedRequest.status == nil) {
            case .success(let task):
                updated = task
            case .failure(let violation):
                throw violation
            }
            if updated.status == .ready {
                switch preflight.readiness(of: updated.id) {
                case .success(.ready):
                    break
                case .success(.waitingFor):
                    throw WorkTaskGraphViolation(
                        kind: .dependenciesUnsatisfied,
                        message: "WorkTask dependencies are not completed",
                        taskID: updated.id)
                case .success(.blockedBy):
                    throw WorkTaskGraphViolation(
                        kind: .terminalDependency,
                        message: "WorkTask has a failed or cancelled dependency",
                        taskID: updated.id)
                case .failure(let violation):
                    throw violation
                }
            }

            var events = workTaskMutationEvents(previous: current, next: updated)
            reconcileWorkTaskDependents(
                changedTaskID: updated.id,
                graph: &preflight,
                events: &events)
            preparedGraph = preflight
            preparedEvents = events
        } catch {
            guard provePreflightRejectionHasNoEffect else {
                throw error
            }
            // The catch scope ends before the first EventLog append. Only the
            // production WorkTask adapter opts into this proof; persistence
            // failures and lost acknowledgements below remain unresolved.
            throw Self.provenWorkTaskUpdatePreflightRejection(
                error,
                request: request)
        }

        try await appendAdmissionEvents(preparedEvents)
        workTaskGraph = preparedGraph
        guard let updated = preparedGraph.task(updatedTaskID) else {
            throw IntatisError.notFound("WorkTask \(updatedTaskID.rawValue)")
        }
        return workTaskDetail(updated)
    }

    func getWorkTask(currentWorkTaskID: WorkTaskID?,
                     canManage: Bool,
                     taskID: WorkTaskID) throws -> WorkTaskDetail {
        try requireValidWorkTaskGraph()
        guard let task = workTaskGraph.task(taskID) else {
            throw IntatisError.notFound("WorkTask \(taskID.rawValue)")
        }
        guard canReadWorkTask(
            task,
            currentWorkTaskID: currentWorkTaskID,
            canManage: canManage) else {
            throw IntatisError.permissionDenied("WorkTask is outside the caller's readable scope")
        }
        return workTaskDetail(task)
    }

    func listWorkTasks(currentWorkTaskID: WorkTaskID?,
                       canManage: Bool,
                       request: WorkTaskListRequest) throws -> [WorkTaskDetail] {
        try requireValidWorkTaskGraph()
        let visible: [WorkTask]
        if canManage {
            visible = Array(workTaskGraph.tasks.values)
        } else {
            guard let currentWorkTaskID,
                  let current = workTaskGraph.task(currentWorkTaskID) else { return [] }
            let visibleIDs = Set([current.id] + current.dependsOn)
            visible = workTaskGraph.tasks.values.filter { visibleIDs.contains($0.id) }
        }

        return visible
            .filter { request.statuses.isEmpty || request.statuses.contains($0.status) }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.id.rawValue < $1.id.rawValue }
                return $0.createdAt < $1.createdAt
            }
            .map(workTaskDetail)
    }

    private func canReadWorkTask(_ task: WorkTask,
                                 currentWorkTaskID: WorkTaskID?,
                                 canManage: Bool) -> Bool {
        if canManage { return true }
        guard let currentWorkTaskID,
              let current = workTaskGraph.task(currentWorkTaskID) else { return false }
        return task.id == current.id || current.dependsOn.contains(task.id)
    }

    private func workTaskDetail(_ task: WorkTask) -> WorkTaskDetail {
        let dependencies = task.dependsOn.compactMap { dependencyID -> WorkTaskDependencyView? in
            guard let dependency = workTaskGraph.task(dependencyID) else { return nil }
            return WorkTaskDependencyView(taskID: dependency.id, status: dependency.status)
        }
        let downstream = workTaskGraph.tasks.values
            .filter { $0.dependsOn.contains(task.id) }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.id.rawValue < $1.id.rawValue }
                return $0.createdAt < $1.createdAt
            }
            .map(\.id)
        let candidates = task.latestInvocationIDs.compactMap { invocationID -> WorkTaskCandidateResultView? in
            guard let result = scheduler.record(for: invocationID)?.result else { return nil }
            return WorkTaskCandidateResultView(
                invocationTaskID: invocationID,
                result: result,
                receivedAt: task.updatedAt)
        }
        return WorkTaskDetail(
            task: task,
            dependencies: dependencies,
            downstreamTaskIDs: downstream,
            candidateResults: candidates)
    }

    private func workTaskMutationEvents(previous: WorkTask, next: WorkTask) -> [Event] {
        var events: [Event] = [.workTaskUpdated(WorkTaskUpdatedPayload(
            task: next,
            previousRevision: previous.revision))]
        if previous.dependsOn != next.dependsOn {
            events.append(.workTaskDependencyChanged(WorkTaskDependencyChangedPayload(
                task: next,
                previousDependencies: previous.dependsOn)))
        }
        let addedEvidence = next.evidence.filter { !previous.evidence.contains($0) }
        events.append(contentsOf: addedEvidence.map {
            .workTaskEvidenceAdded(WorkTaskEvidenceAddedPayload(task: next, evidence: $0))
        })
        if previous.status != next.status {
            switch next.status {
            case .pending:
                break
            case .ready:
                events.append(.workTaskReady(WorkTaskReadyPayload(task: next)))
            case .inProgress:
                events.append(.workTaskStarted(WorkTaskStartedPayload(task: next)))
            case .blocked:
                events.append(.workTaskBlocked(WorkTaskBlockedPayload(
                    task: next,
                    blocker: next.progressNote ?? "WorkTask blocked")))
            case .completed:
                events.append(.workTaskCompleted(WorkTaskCompletedPayload(task: next)))
            case .failed:
                events.append(.workTaskFailed(WorkTaskFailedPayload(
                    task: next,
                    error: next.result ?? next.progressNote ?? "WorkTask failed")))
            case .cancelled:
                events.append(.workTaskCancelled(WorkTaskCancelledPayload(
                    task: next,
                    reason: next.progressNote ?? "WorkTask cancelled")))
            }
        } else if previous.progressNote != next.progressNote {
            events.append(.workTaskProgressed(WorkTaskProgressedPayload(task: next)))
        }
        return events
    }

    private func reconcileWorkTaskDependents(changedTaskID: WorkTaskID,
                                             graph: inout WorkTaskGraph,
                                             events: inout [Event]) {
        let dependentIDs = graph.tasks.values
            .filter { $0.dependsOn.contains(changedTaskID) && !$0.status.isTerminal }
            .map(\.id)
            .sorted { $0.rawValue < $1.rawValue }
        for dependentID in dependentIDs {
            guard let current = graph.task(dependentID),
                  current.status != .inProgress else {
                continue
            }
            let target: (WorkTaskStatus, String?)?
            switch graph.readiness(of: dependentID) {
            case .success(.ready) where current.status == .pending || current.status == .blocked:
                target = (.ready, nil)
            case .success(.waitingFor(let waiting)) where current.status == .ready:
                target = (.blocked, "waiting for dependencies: "
                    + waiting.map(\.rawValue).sorted().joined(separator: ", "))
            case .success(.blockedBy(let blocked)) where current.status == .pending || current.status == .ready:
                target = (.blocked, "dependency failed or was cancelled: "
                    + blocked.map(\.rawValue).sorted().joined(separator: ", "))
            default:
                target = nil
            }
            guard let target else { continue }
            switch graph.transition(
                taskID: dependentID,
                to: target.0,
                expectedRevision: current.revision,
                progressNote: target.1) {
            case .success(let changed):
                if changed.status == .ready {
                    events.append(.workTaskReady(WorkTaskReadyPayload(task: changed)))
                } else {
                    events.append(.workTaskBlocked(WorkTaskBlockedPayload(
                        task: changed,
                        blocker: target.1 ?? "dependency blocked")))
                }
            case .failure:
                continue
            }
        }
    }

    /// Rejects concurrent writers when their declared artifacts overlap. An
    /// empty or unsafe artifact declaration is an unknown write set and is
    /// therefore treated as workspace-wide for a write-capable invocation.
    private func workTaskResourceConflict(candidate: WorkTask,
                                          target: Agent,
                                          capabilityLease: CapabilityLease) -> String? {
        guard Self.hasWorkspaceMutationCapability(capabilityLease) else { return nil }
        let workspacePath = target.workspaceRoot.standardizedFileURL.path
        let candidatePaths = Self.normalizedExpectedArtifactPaths(candidate.expectedArtifacts)

        let activeWriters = workTaskGraph.tasks.values
            .filter { $0.id != candidate.id && $0.status == .inProgress }
            .sorted { $0.id.rawValue < $1.id.rawValue }
        for other in activeWriters {
            guard workTaskHasActiveWriter(other, inWorkspace: workspacePath) else { continue }
            let otherPaths = Self.normalizedExpectedArtifactPaths(other.expectedArtifacts)
            if candidatePaths == nil || otherPaths == nil {
                return "unknown write set overlaps active WorkTask \(other.id.rawValue) workspace-wide"
            }
            guard let candidatePaths, let otherPaths else { continue }
            for lhs in candidatePaths {
                for rhs in otherPaths where Self.pathComponentsOverlap(lhs, rhs) {
                    return "artifact paths overlap WorkTask \(other.id.rawValue): "
                        + lhs.joined(separator: "/") + " <-> " + rhs.joined(separator: "/")
                }
            }
        }
        return nil
    }

    private func workTaskHasActiveWriter(_ task: WorkTask, inWorkspace workspacePath: String) -> Bool {
        for invocationID in task.latestInvocationIDs {
            guard let node = taskGraph.node(invocationID),
                  Self.isActiveTaskStatus(node.status),
                  let agent = registry.agent(node.assignee),
                  agent.workspaceRoot.standardizedFileURL.path == workspacePath else { continue }
            if let leaseID = node.contract.capabilityLeaseID,
               let lease = capabilityLeases[leaseID],
               Self.hasWorkspaceMutationCapability(lease) {
                return true
            }
        }
        return false
    }

    private static func normalizedExpectedArtifactPaths(_ values: [String]) -> [[String]]? {
        guard !values.isEmpty else { return nil }
        var normalized: [[String]] = []
        for raw in values {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }
            // A glob is a pattern, not a provable bounded write set. Treat all
            // common glob metacharacters conservatively as workspace-wide.
            guard trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[]{}")) == nil else {
                return nil
            }
            let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
                .filter { $0 != "." }
            guard !components.isEmpty, !components.contains("..") else { return nil }
            normalized.append(components)
        }
        return normalized
    }

    private static func pathComponentsOverlap(_ lhs: [String], _ rhs: [String]) -> Bool {
        let sharedCount = min(lhs.count, rhs.count)
        return Array(lhs.prefix(sharedCount)) == Array(rhs.prefix(sharedCount))
    }

    // MARK: - Durable Goal control plane

    func createGoal(request: GoalCreateRequest,
                    mainAgentInferenceBinding: AgentInferenceBinding? = nil) async throws -> Goal {
        let objective = request.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else {
            throw IntatisError.decoding("Goal objective must be non-empty")
        }
        if let tokenBudget = request.tokenBudget, tokenBudget <= 0 {
            throw IntatisError.decoding("Goal token budget must be greater than zero")
        }
        let sessionID = await log.sessionID

        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        let projection = CoworkProjection.build(from: await log.replay())
        if let current = projection.currentGoal, !current.status.isTerminal {
            throw IntatisError.config(
                "a current Goal already exists: \(current.id.rawValue) (\(current.status.rawValue))")
        }
        let goal = Goal(
            sessionID: sessionID,
            objective: objective,
            successCriteria: request.successCriteria,
            constraints: request.constraints,
            tokenBudget: request.tokenBudget,
            mainAgentInferenceBinding: mainAgentInferenceBinding)
        try await appendAdmissionEvent(.goalCreated(GoalCreatedPayload(goal: goal)))
        return goal
    }

    func currentGoalSnapshot() async -> Goal? {
        CoworkProjection.build(from: await log.replay()).currentGoal
    }

    func editGoal(request: GoalEditRequest,
                  hostAuthorized: Bool) async throws -> Goal {
        guard hostAuthorized else {
            throw IntatisError.permissionDenied("Goal edits are reserved for the user/host control plane")
        }
        let objective = request.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else {
            throw IntatisError.decoding("Goal objective must be non-empty")
        }
        if let tokenBudget = request.tokenBudget, tokenBudget <= 0 {
            throw IntatisError.decoding("Goal token budget must be greater than zero")
        }

        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        let projection = CoworkProjection.build(from: await log.replay())
        guard projection.currentGoalID == request.goalID,
              let current = projection.goals[request.goalID] else {
            throw IntatisError.notFound("current Goal \(request.goalID.rawValue)")
        }
        let edited: Goal
        switch current.edited(
            objective: objective,
            successCriteria: request.successCriteria,
            constraints: request.constraints,
            tokenBudget: request.tokenBudget,
            expectedRevision: request.expectedRevision) {
        case .success(let value):
            edited = value
        case .failure(let violation):
            throw violation
        }
        try await appendAdmissionEvent(.goalEdited(GoalEditedPayload(
            goal: edited,
            previousRevision: current.revision)))
        return edited
    }

    func transitionGoal(_ goalID: GoalID,
                        expectedRevision: Int,
                        to status: GoalStatus,
                        canSubmitVerdict: Bool,
                        hostAuthorized: Bool,
                        resetNoProgress: Bool = false,
                        transitionReason: String? = nil) async throws -> Goal {
        if !hostAuthorized {
            guard canSubmitVerdict, status == .completed || status == .blocked else {
                throw IntatisError.permissionDenied(
                    "model Goal transitions are limited to complete or blocked verifier verdicts")
            }
        }

        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        let projection = CoworkProjection.build(from: await log.replay())
        guard projection.currentGoalID == goalID,
              let current = projection.goals[goalID] else {
            throw IntatisError.notFound("current Goal \(goalID.rawValue)")
        }
        if status == .blocked {
            guard current.latestAudit?.verdict == .blockedCandidate,
                  current.consecutiveBlockedRuns >= 3 else {
                throw IntatisError.permissionDenied(
                    "Goal blocked requires the same verified blocker across at least three completed runs")
            }
        }
        let transitioned: Goal
        switch current.transitioning(
            to: status,
            expectedRevision: expectedRevision,
            audit: current.latestAudit) {
        case .success(var value):
            if hostAuthorized, status == .active, resetNoProgress {
                value.noProgressRuns = 0
            }
            transitioned = value
        case .failure(let violation):
            throw violation
        }

        let event: Event
        switch status {
        case .active:
            event = .goalResumed(GoalResumedPayload(goal: transitioned))
        case .paused:
            event = .goalPaused(GoalPausedPayload(goal: transitioned))
        case .blocked:
            event = .goalBlocked(GoalBlockedPayload(
                goal: transitioned,
                blocker: transitioned.latestAudit?.blocker ?? "Goal verifier reported a blocker"))
        case .budgetLimited:
            event = .goalBudgetLimited(GoalBudgetLimitedPayload(goal: transitioned))
        case .usageLimited:
            event = .goalUsageLimited(GoalUsageLimitedPayload(
                goal: transitioned,
                reason: transitionReason))
        case .completed:
            event = .goalCompleted(GoalCompletedPayload(
                goal: transitioned,
                audit: transitioned.latestAudit))
        }
        try await appendAdmissionEvent(event)
        return transitioned
    }

    /// Applies one audit to one checkpointed run. This lower-level seam is used
    /// by focused authority tests; production continuation uses
    /// ``settleGoalRunAudit`` so audit, run settlement, and an optional Goal
    /// terminal transition share one durable batch.
    func applyGoalAudit(_ audit: GoalAuditSummary,
                        goalID: GoalID,
                        runID: ContinuationRunID,
                        expectedRevision: Int,
                        tokenDelta: Int,
                        activeElapsedDelta: Double) async throws -> Goal {
        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }

        let replayed = await log.replay()
        let projection = CoworkProjection.build(from: replayed)
        guard projection.currentGoalID == goalID,
              let current = projection.goals[goalID] else {
            throw IntatisError.notFound("current Goal \(goalID.rawValue)")
        }
        guard let run = projection.continuationRuns[runID],
              run.sessionID == current.sessionID,
              run.goalID == goalID,
              run.status == .checkpointed else {
            throw IntatisError.config(
                "Goal audit requires a checkpointed ContinuationRun owned by Goal \(goalID.rawValue)")
        }
        guard !Self.hasGoalAudit(runID: runID, in: replayed) else {
            throw IntatisError.config(
                "ContinuationRun \(runID.rawValue) already has a Goal audit")
        }

        let audited = try Self.goalByApplyingAudit(
            audit,
            to: current,
            expectedRevision: expectedRevision,
            tokenDelta: tokenDelta,
            activeElapsedDelta: activeElapsedDelta)
        try await appendAdmissionEvent(.goalAuditCompleted(GoalAuditCompletedPayload(
            goal: audited,
            audit: audit,
            runID: runID)))
        return audited
    }

    /// Atomically commits the only valid end of a Goal continuation run:
    /// verifier audit, completed run, and (when warranted) terminal Goal state.
    /// A run can be audited at most once and only after its checkpoint is
    /// durable, so one blocker confirmation can count at most once per run.
    func settleGoalRunAudit(_ audit: GoalAuditSummary,
                            goalID: GoalID,
                            runID: ContinuationRunID,
                            expectedRevision: Int,
                            tokenDelta: Int,
                            activeElapsedDelta: Double,
                            runProgressSummary: String,
                            usageLimitReason: String?,
                            blockedRunThreshold: Int) async throws -> (goal: Goal, run: ContinuationRun) {
        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }

        let replayed = await log.replay()
        let projection = CoworkProjection.build(from: replayed)
        guard projection.currentGoalID == goalID,
              let current = projection.goals[goalID],
              current.status == .active else {
            throw IntatisError.notFound("active current Goal \(goalID.rawValue)")
        }
        guard let checkpointed = projection.continuationRuns[runID],
              checkpointed.sessionID == current.sessionID,
              checkpointed.goalID == goalID,
              checkpointed.status == .checkpointed else {
            throw IntatisError.config(
                "Goal run settlement requires a checkpointed ContinuationRun owned by Goal \(goalID.rawValue)")
        }
        guard !Self.hasGoalAudit(runID: runID, in: replayed) else {
            throw IntatisError.config(
                "ContinuationRun \(runID.rawValue) already has a Goal audit")
        }

        let audited = try Self.goalByApplyingAudit(
            audit,
            to: current,
            expectedRevision: expectedRevision,
            tokenDelta: tokenDelta,
            activeElapsedDelta: activeElapsedDelta)
        let completedRun = try checkpointed.transitioning(
            to: .completed,
            progressSummary: runProgressSummary).get()
        var settledGoal = audited
        var events: [Event] = [
            .goalAuditCompleted(GoalAuditCompletedPayload(
                goal: audited,
                audit: audit,
                runID: runID)),
            .continuationRunCompleted(ContinuationRunCompletedPayload(run: completedRun)),
        ]

        if audit.isCompletionProof(for: audited) {
            settledGoal = try audited.transitioning(
                to: .completed,
                expectedRevision: audited.revision,
                audit: audit).get()
            events.append(.goalCompleted(GoalCompletedPayload(
                goal: settledGoal,
                audit: audit)))
        } else if let usageLimitReason {
            settledGoal = try audited.transitioning(
                to: .usageLimited,
                expectedRevision: audited.revision).get()
            events.append(.goalUsageLimited(GoalUsageLimitedPayload(
                goal: settledGoal,
                reason: usageLimitReason)))
        } else if audit.verdict == .blockedCandidate,
                  audited.consecutiveBlockedRuns >= max(3, blockedRunThreshold) {
            settledGoal = try audited.transitioning(
                to: .blocked,
                expectedRevision: audited.revision,
                audit: audit).get()
            events.append(.goalBlocked(GoalBlockedPayload(
                goal: settledGoal,
                blocker: audit.blocker ?? "Repeated verified blocker")))
        } else if let budget = audited.tokenBudget,
                  audited.tokensUsed >= budget {
            settledGoal = try audited.transitioning(
                to: .budgetLimited,
                expectedRevision: audited.revision).get()
            events.append(.goalBudgetLimited(GoalBudgetLimitedPayload(goal: settledGoal)))
        }

        try await appendAdmissionEvents(events)
        if usageLimitReason != nil {
            providerUsageLimitFailures = providerUsageLimitFailures.filter { $0.value.0 != goalID }
        } else {
            providerUsageLimitFailures.removeValue(forKey: runID)
        }
        return (settledGoal, completedRun)
    }

    private static func goalByApplyingAudit(_ audit: GoalAuditSummary,
                                            to current: Goal,
                                            expectedRevision: Int,
                                            tokenDelta: Int,
                                            activeElapsedDelta: Double) throws -> Goal {
        var value = try current.applyingAudit(
            audit,
            expectedRevision: expectedRevision).get()
        value.tokensUsed = saturatingAdd(current.tokensUsed, max(tokenDelta, 0))
        value.activeElapsedSeconds = current.activeElapsedSeconds
            + max(activeElapsedDelta, 0)
        if audit.verdict == .blockedCandidate,
           let blocker = audit.blocker,
           !blocker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fingerprint = normalizedGoalBlocker(blocker)
            if current.blockerFingerprint == fingerprint {
                value.consecutiveBlockedRuns = saturatingAdd(
                    current.consecutiveBlockedRuns,
                    1)
            } else {
                value.blockerFingerprint = fingerprint
                value.consecutiveBlockedRuns = 1
            }
        } else {
            value.blockerFingerprint = nil
            value.consecutiveBlockedRuns = 0
        }
        return value
    }

    private static func hasGoalAudit(runID: ContinuationRunID,
                                     in envelopes: [Envelope]) -> Bool {
        envelopes.contains { envelope in
            guard case .goalAuditCompleted(let payload) = envelope.event else { return false }
            return payload.runID == runID
        }
    }

    func clearGoal(_ goalID: GoalID,
                   expectedRevision: Int,
                   hostAuthorized: Bool) async throws {
        guard hostAuthorized else {
            throw IntatisError.permissionDenied("clearing a Goal is reserved for the user/host control plane")
        }
        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        let projection = CoworkProjection.build(from: await log.replay())
        guard projection.currentGoalID == goalID,
              let current = projection.goals[goalID] else {
            throw IntatisError.notFound("current Goal \(goalID.rawValue)")
        }
        guard current.revision == expectedRevision else {
            throw GoalMutationViolation(
                kind: .staleRevision,
                message: "expected revision \(expectedRevision), actual \(current.revision)",
                goalID: goalID,
                expectedRevision: expectedRevision,
                actualRevision: current.revision)
        }
        try await appendAdmissionEvent(.goalCleared(GoalClearedPayload(
            goal: current,
            reason: "cleared by user/host control plane")))
    }

    // MARK: - Coordinator tools (a lead agent spawns / lists / removes sub-agents)

    /// Create and attach a new sub-agent bound to `path`. Returns a status line
    /// the calling (coordinator) agent can read back.
    func spawnFromTool(requestedBy: AgentID,
                       currentTaskID: TaskID? = nil,
                       name: String,
                       path: String,
                       inferenceProfileID: String? = nil,
                       agentInferenceBinding: AgentInferenceBinding? = nil,
                       authorization: ResolvedToolAuthorization? = nil,
                       requestedAccess: WorkspaceAccess = .readOnly,
                       canCoordinate: Bool = false) async -> String {
        if let validationError = Self.agentNameValidationError(name) {
            return "error: \(validationError)"
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return "error: not a folder: \(url.path)"
        }
        let id = AgentID(rawValue: name)
        guard id != Self.automaticPermissionReviewerID else {
            return "error: @\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review"
        }
        guard let lease = existingCapabilityLease(for: requestedBy, taskID: currentTaskID),
              case .granted(let budget) = lease.delegation,
              lease.tools.contains(.attachWorkspace) else {
            return "error: spawning agents is not granted for the current task"
        }
        guard let parentWorkspaceLease = existingWorkspaceLease(
            for: requestedBy,
            taskID: currentTaskID) else {
            return "error: spawning agents requires an active workspace lease"
        }
        if requestedAccess == .readWrite,
           parentWorkspaceLease.access != .readWrite {
            return "error: a read-only workspace lease cannot grant read-write access to a child agent"
        }
        if canCoordinate, budget.maxDepth < 1 {
            return "error: coordinator spawning exceeds the delegation depth budget"
        }
        let activeAgentCount = registry.names.filter { $0 != Self.automaticPermissionReviewerID }.count
        guard activeAgentCount < taskGraph.policy.maxActiveAgentsPerThread else {
            return "error: active agent limit reached (\(taskGraph.policy.maxActiveAgentsPerThread))"
        }
        if registry.agent(id) != nil { return "error: an agent named @\(name) already exists" }
        if let authorization {
            guard authorization.toolName == "spawn_agent",
                  authorization.agent == requestedBy,
                  authorization.taskID == currentTaskID else {
                return "error: spawn_agent authorization binding is invalid"
            }
            if let failure = authorizationRevalidationFailure(authorization) {
                return "error: \(failure)"
            }
        }
        let selectedBinding = authorization?.targetAgentInferenceBinding
            ?? agentInferenceBinding
            ?? registry.agent(requestedBy)?.agentInferenceBinding
        if let inferenceProfileID,
           !inferenceProfileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           selectedBinding?.inferenceProfileID.rawValue != inferenceProfileID {
            return "error: spawn_agent profile differs from the reviewed authorization"
        }
        guard !requiresInferenceBindings || selectedBinding != nil else {
            return "error: spawn target has no exact inference profile binding"
        }
        guard let selectedModel = selectedBinding?.modelID
            ?? registry.agent(requestedBy)?.model else {
            return "error: spawning agent is not attached"
        }
        let assessment = assessWorkspaceAttach(url)
        guard assessment.canAskUser, let canonical = assessment.canonical else {
            return "error: \(assessment.reason)"
        }
        let coordinationDepth = canCoordinate ? max(1, min(Agent.defaultCoordinationDepth, budget.maxDepth)) : 0
        let proposedAgent = Agent(
            name: id,
            workspaceRoot: canonical,
            model: selectedModel,
            agentInferenceBinding: selectedBinding,
            profile: .reviewed,
            coordinationDepth: coordinationDepth)
        if requiresInferenceBindings {
            do {
                _ = try await resolvedProvider(for: proposedAgent)
            } catch {
                return "error: selected inference profile revision is unavailable or incompatible"
            }
        }
        let proposedLeases = prepareSpawnLeases(
            for: proposedAgent,
            parentCapabilityLease: lease,
            parentWorkspaceLease: parentWorkspaceLease,
            workspaceAccess: requestedAccess,
            canCoordinate: canCoordinate)
        let rootTaskID = currentTaskID.flatMap { taskGraph.node($0)?.rootTaskID } ?? currentTaskID
        let baseMetadata = CoworkEventMetadata(
            taskID: currentTaskID,
            rootTaskID: rootTaskID,
            parentTaskID: currentTaskID,
            sender: requestedBy,
            recipient: id,
            agentID: id,
            issuer: requestedBy,
            assignee: id,
            workspaceID: proposedLeases.workspace.workspaceID,
            workspaceLeaseID: proposedLeases.workspace.id,
            capabilityLeaseID: proposedLeases.capability.id,
            causalParentID: currentTaskID,
            scope: .agent,
            visibility: .global)
        let workspaceMetadata = CoworkEventMetadata(
            taskID: currentTaskID,
            rootTaskID: rootTaskID,
            parentTaskID: currentTaskID,
            sender: requestedBy,
            recipient: id,
            agentID: id,
            issuer: requestedBy,
            assignee: id,
            workspaceID: proposedLeases.workspace.workspaceID,
            workspaceLeaseID: proposedLeases.workspace.id,
            causalParentID: currentTaskID,
            scope: .workspace,
            visibility: .global)
        let capabilityMetadata = CoworkEventMetadata(
            taskID: currentTaskID,
            rootTaskID: rootTaskID,
            parentTaskID: currentTaskID,
            sender: requestedBy,
            recipient: id,
            agentID: id,
            issuer: requestedBy,
            assignee: id,
            capabilityLeaseID: proposedLeases.capability.id,
            causalParentID: currentTaskID,
            scope: .capability,
            visibility: .global)

        // `spawn_agent` has already passed AgentLoop schema/lease/permission and
        // has a durable tool execution ticket. The executor therefore performs
        // one atomic admission; it must not recursively call ordinary `attach`
        // and trigger a second PermissionEngine review for the same ToolCall.
        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        guard registry.agent(id) == nil else {
            return "error: an agent named @\(name) already exists"
        }
        if let authorization,
           let failure = authorizationRevalidationFailure(authorization) {
            return "error: \(failure)"
        }
        guard let rootIdentity = proposedLeases.workspace.rootIdentity,
              rootIdentity.matchesCurrentDirectory(rootPath: proposedLeases.workspace.rootPath) else {
            return "error: workspace root identity changed before spawn admission"
        }
        do {
            try await appendAdmissionEvents([
                .agentSpawnRequested(AgentSpawnRequestedPayload(
                    requestedBy: requestedBy,
                    agent: id,
                    path: canonical.path,
                    model: proposedAgent.model,
                    agentInferenceBinding: proposedAgent.agentInferenceBinding,
                    metadata: baseMetadata)),
                .agentAttachRequested(AgentAttachRequestedPayload(
                    agent: id,
                    path: canonical.path,
                    model: proposedAgent.model,
                    profile: proposedAgent.profile.rawValue,
                    agentInferenceBinding: proposedAgent.agentInferenceBinding,
                    metadata: baseMetadata)),
                .workspaceLeaseRequested(WorkspaceLeaseRequestedPayload(
                    agent: id,
                    rootPath: canonical.path,
                    access: proposedLeases.workspace.access,
                    reason: "spawn_agent ToolCall already approved",
                    metadata: workspaceMetadata)),
                .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                    agent: id,
                    lease: proposedLeases.workspace,
                    metadata: workspaceMetadata)),
                .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                    agent: id,
                    lease: proposedLeases.capability,
                    metadata: capabilityMetadata)),
                .agentAttached(AgentAttachedPayload(
                    agent: id,
                    path: canonical.path,
                    model: proposedAgent.model,
                    profile: proposedAgent.profile.rawValue,
                    agentInferenceBinding: proposedAgent.agentInferenceBinding,
                    metadata: baseMetadata)),
                .agentSpawned(AgentSpawnedPayload(
                    requestedBy: requestedBy,
                    agent: id,
                    path: canonical.path,
                    model: proposedAgent.model,
                    agentInferenceBinding: proposedAgent.agentInferenceBinding,
                    metadata: baseMetadata)),
            ])
        } catch {
            return "error: spawn admission could not be persisted: \(error.localizedDescription)"
        }
        registry.add(proposedAgent)
        commitDefaultLeases(proposedLeases, for: id)
        spawnedAgentOwners[id] = requestedBy
        let inference = proposedAgent.agentInferenceBinding.map {
            "profile \($0.inferenceProfileID.rawValue)@\($0.inferenceProfileRevision.rawValue)"
        } ?? "legacy model \(proposedAgent.model.rawValue)"
        return "spawned @\(name) · \(inference) · \(canCoordinate ? "coordinator" : "worker") · \(requestedAccess.rawValue) · \(canonical.path)"
    }

    /// One line per active agent, for the coordinator to read.
    func listForTool() -> String {
        let all = registry.all()
            .filter { $0.name != Self.automaticPermissionReviewerID }
            .sorted { $0.name.rawValue < $1.name.rawValue }
        guard !all.isEmpty else { return "(no agents)" }
        return all.map {
            let inference = $0.agentInferenceBinding.map { binding in
                let variant = binding.variantID.map { " variant=\($0)" } ?? ""
                return "profile=\(binding.inferenceProfileID.rawValue)@\(binding.inferenceProfileRevision.rawValue) connection=\(binding.inferenceConnectionID.rawValue)\(variant)"
            } ?? "profile=legacy-unresolved"
            return [
                "@\($0.name.rawValue)",
                $0.model.rawValue,
                agentListRole(for: $0),
                inference,
                agentListTaskState(for: $0.name),
                $0.workspaceRoot.path,
            ].joined(separator: " · ")
        }
            .joined(separator: "\n")
    }

    func listInferenceProfilesForTool() -> String {
        let profiles = availableInferenceProfiles.values.sorted {
            if $0.safeRouteLabel == $1.safeRouteLabel {
                return $0.inferenceProfileID.rawValue < $1.inferenceProfileID.rawValue
            }
            return ($0.safeRouteLabel ?? $0.inferenceProfileID.rawValue)
                < ($1.safeRouteLabel ?? $1.inferenceProfileID.rawValue)
        }
        guard !profiles.isEmpty else { return "(no host-approved inference profiles)" }
        return profiles.map { binding in
            let label = binding.safeRouteLabel ?? binding.inferenceProfileID.rawValue
            let variant = binding.variantID.map { " · variant \($0)" } ?? ""
            let capabilities = availableInferenceProfileRoutingMetadata[
                binding.inferenceProfileID
            ]?.declaredCapabilities.map(\.rawValue) ?? []
            let capabilitySummary = capabilities.isEmpty
                ? " · capabilities unspecified"
                : " · capabilities \(capabilities.joined(separator: ","))"
            return "\(binding.inferenceProfileID.rawValue) · \(label) · model \(binding.modelID.rawValue)\(variant)\(capabilitySummary)"
        }.joined(separator: "\n")
    }

    private func agentListRole(for agent: Agent) -> String {
        let lease = defaultCapabilityLeaseIDs[agent.name].flatMap { capabilityLeases[$0] }
        let canCoordinate = lease.map(Self.canCoordinate) ?? (agent.coordinationDepth > 0)
        return canCoordinate ? "coordinator" : "worker"
    }

    private func agentListTaskState(for agentID: AgentID) -> String {
        let assignedTasks = taskGraph.nodes.values
            .filter { $0.assignee == agentID }
            .sorted { $0.id.rawValue < $1.id.rawValue }
        let issuedActiveTasks = taskGraph.nodes.values
            .filter { $0.issuer == agentID && $0.assignee != agentID && Self.isActiveTaskStatus($0.status) }
            .sorted { $0.id.rawValue < $1.id.rawValue }
        let mailbox = scheduler.mailbox(for: agentID)

        var parts: [String] = []
        if assignedTasks.isEmpty {
            parts.append("tasks idle")
        } else {
            parts.append("tasks \(Self.compactTaskStates(assignedTasks))")
        }
        if !issuedActiveTasks.isEmpty {
            parts.append("issued active \(Self.compactTaskStates(issuedActiveTasks))")
        }
        if !mailbox.pendingMessages.isEmpty {
            parts.append("messages \(mailbox.pendingMessages.count)")
        }
        if mailbox.pendingTasks.count > assignedTasks.filter({ Self.isActiveTaskStatus($0.status) }).count {
            parts.append("queued mailbox \(mailbox.pendingTasks.count)")
        }
        return parts.joined(separator: ", ")
    }

    /// Detach a sub-agent. `@main` is protected so the user always keeps a coordinator.
    func removeFromTool(requestedBy: AgentID, currentTaskID: TaskID?, name: String) async -> String {
        guard let lease = existingCapabilityLease(for: requestedBy, taskID: currentTaskID),
              case .granted = lease.delegation,
              lease.tools.contains(.delegateTask) else {
            return "error: removing agents is not granted for the current task"
        }
        let id = AgentID(rawValue: name)
        guard registry.agent(id) != nil else { return "error: no agent named @\(name)" }
        if name == "main" { return "error: cannot remove @main" }
        if id == Self.automaticPermissionReviewerID {
            return "error: @\(Self.automaticPermissionReviewerID.rawValue) is controlled by /default"
        }
        guard requestedBy == Self.mainAgentID || spawnedAgentOwners[id] == requestedBy else {
            return "error: @\(requestedBy.rawValue) does not own @\(name)"
        }
        guard !taskGraph.nodes.values.contains(where: {
            ($0.assignee == id || $0.issuer == id) && Self.isActiveTaskStatus($0.status)
        }) else {
            return "error: @\(name) still has active tasks; cancel them before removal"
        }
        guard await detach(id) else {
            return "error: @\(name) could not be removed because its detach audit was not persisted"
        }
        return "removed @\(name)"
    }

    private func run(_ agent: Agent,
                     input: String,
                     images: [ImageAttachment] = [],
                     userMessage: UserMessagePayload? = nil,
                     recordUserMessage: Bool = true,
                     taskContract: TaskContract? = nil,
                     rootTaskID: TaskID? = nil,
                     taskAttempt: Int? = nil) async throws -> AgentRunResult {
        if requiresInferenceBindings {
            guard let liveBinding = agent.agentInferenceBinding else {
                throw IntatisError.config(
                    "configurationUnresolved: @\(agent.name.rawValue) has no exact inference profile binding")
            }
            guard let frozenBinding = taskContract?.agentInferenceBinding else {
                throw IntatisError.config(
                    "configurationUnresolved: task \(taskContract?.id.rawValue ?? "unknown") has no frozen inference profile binding")
            }
            guard frozenBinding == liveBinding else {
                throw IntatisError.config(
                    "configurationUnresolved: task and @\(agent.name.rawValue) inference profile revisions differ")
            }
        } else if let frozenBinding = taskContract?.agentInferenceBinding,
                  frozenBinding != agent.agentInferenceBinding {
            throw IntatisError.config(
                "configurationUnresolved: task and agent inference profile revisions differ")
        }
        var capabilityLease = try capabilityLease(
            for: agent,
            taskContract: taskContract)
        let workspaceLease = try workspaceLease(for: agent, taskContract: taskContract)
        let contextEvents = try await log.replayChecked()
        let durableMCP =
            MCPDurableSessionState.project(contextEvents)
        capabilityLease.mcpGrants =
            durableMCP.grants(
                agentID: agent.name,
                capabilityLeaseID:
                    capabilityLease.id,
                taskID: taskContract?.id)
        let runtimeInference =
            try await resolvedRuntimeInference(for: agent)
        let provider = runtimeInference.provider
        let messenger = BusMessenger(from: agent.name, currentTaskID: taskContract?.id, orchestrator: self)
        let manager = OrchestratorManager(
            orchestrator: self,
            requester: agent.name,
            currentTaskID: taskContract?.id)
        let workTaskManager = OrchestratorWorkTaskManager(
            orchestrator: self,
            currentWorkTaskID: taskContract?.workTaskID,
            canManage: capabilityLease.tools.contains(.manageWorkTasks),
            canUpdateBound: capabilityLease.tools.contains(.updateBoundWorkTask))
        let goalManager = OrchestratorGoalManager(
            orchestrator: self,
            canSubmitVerdict: agent.name == Self.mainAgentID
                && capabilityLease.tools.contains(.submitGoalVerdict))
        let skillSnapshot: SkillSnapshot?
        if let workspaceLease {
            let canonicalWorkspace =
                try PathConfinement.canonicalExistingDirectory(
                    agent.workspaceRoot)
            guard let rootIdentity = workspaceLease.rootIdentity,
                  rootIdentity.canonicalPath == canonicalWorkspace.path,
                  rootIdentity.matchesCurrentDirectory(
                    rootPath: canonicalWorkspace.path)
            else {
                throw CoworkTaskExecutionError.invalidLease(
                    "agent workspace does not match its reviewed workspace lease")
            }
            skillSnapshot = try await SkillCatalogService.shared.snapshot(
                configuration: .standard(
                    workspaceRoot: canonicalWorkspace,
                    access: skillRootAccess),
                catalogBudget:
                    runtimeInference.modelContextPolicy
                        .skillCatalogMetadataBudget)
        } else {
            // A legacy invocation without a reviewed workspace lease receives
            // no Skill visibility. Skill discovery is never used to create or
            // widen a workspace authority boundary.
            skillSnapshot = nil
        }
        let canControlRun = agent.name == Self.mainAgentID
            && taskContract?.kind == .root
            && taskContract?.issuer == nil
            && taskContract?.assignee == agent.name
            && taskContract?.continuationRunID != nil
        let hostedWebSearch = runtimeInference.hostedWebSearch.map {
            ProviderHostedWebSearchToolService(route: $0)
        }
        let baseToolRegistry = Self.toolRegistry(
            for: capabilityLease,
            agentID: agent.name,
            includesTerminal: allowsShell,
            canControlRun: canControlRun,
            hostedWebSearch: hostedWebSearch)
        let hostBaseRegistry =
            skillSnapshot?.augmenting(baseToolRegistry)
                ?? baseToolRegistry
        let internalToolLease:
            HostToolRegistryAugmentationLease?
        let toolRegistry: ToolRegistry
        if let augmenter = internalToolRegistryAugmenter,
           !augmenter.additionalCapabilities.isDisjoint(
               with: capabilityLease.tools)
        {
            guard let workspaceLease else {
                throw CoworkTaskExecutionError.invalidLease(
                    "internal tools require an exact workspace lease")
            }
            let mounted = try await augmenter.augment(
                HostToolRegistryAugmentationInput(
                    sessionID: await log.sessionID,
                    agentID: agent.name,
                    taskID: taskContract?.id,
                    capabilityLease: capabilityLease,
                    workspaceLease: workspaceLease,
                    baseRegistry: hostBaseRegistry))
            internalToolLease = mounted
            toolRegistry = mounted.registry
        } else {
            internalToolLease = nil
            toolRegistry = hostBaseRegistry
        }
        let imageGenerator = await imageGeneratorFor(agent)
        let allowedToolNames = toolRegistry.descriptors().map(\.name).sorted()
        let canCoordinate = Self.canCoordinate(capabilityLease)
        // Give the agent a prompt that matches its current task lease. A numeric
        // depth may still exist on old agents, but the lease decides tool exposure.
        let systemPrompt = ContextBuilder.coworkSystemPrompt(
            name: agent.name.rawValue, folder: agent.workspaceRoot.path,
            coordinationDepth: agent.coordinationDepth,
            canCoordinate: canCoordinate)
        let usesMainConversationHistory =
            agent.name == Self.mainAgentID
            && taskContract?.kind == .root
            && taskContract?.issuer == nil
            && taskContract?.assignee == agent.name
            && taskContract?.submissionID != nil
        let contextBundle = ContextProjector().project(
            agentID: agent.name,
            taskContract: taskContract,
            events: contextEvents,
            allowedToolNames: allowedToolNames,
            workspaceRoot: agent.workspaceRoot,
            projectsCompletedRootAnswersIntoConversation: usesMainConversationHistory)
        let runtime = AgentRuntime.cowork(
            registry: toolRegistry,
            engine: engine,
            allowsShell: allowsShell,
            // Bound profiles already contain the exact provider-native
            // reasoning/thinking options. Applying the session-wide typed
            // value here would overwrite that per-agent revision.
            reasoningEffort: agent.agentInferenceBinding == nil ? reasoningEffort : nil,
            includeUsage: includeUsage || executionPolicy.tokenBudget != nil,
            maxIterations: maxSteps,
            modelContextPolicy: usesMainConversationHistory
                ? runtimeInference.modelContextPolicy
                : .unspecified)
        let requestToolSnapshotProvider:
            AgentRequestToolSnapshotProvider?
        let requestCapabilityLease = capabilityLease
        if let provider = toolSnapshotProvider {
            let resumesContinuation =
                taskContract?.continuationRunID != nil
            requestToolSnapshotProvider = {
                providerCapabilities,
                outputBudget in
                if let snapshot = try await provider(
                    agent,
                    requestCapabilityLease,
                    workspaceLease,
                    toolRegistry,
                    resumesContinuation,
                    providerCapabilities,
                    outputBudget)
                {
                    return snapshot
                }
                return AgentRequestToolSnapshot(
                    registry: toolRegistry)
            }
        } else {
            requestToolSnapshotProvider = nil
        }
        let loop = runtime.makeLoop(
            log: log,
            provider: provider,
            responder: activePermissionResponder(),
            agent: agent,
            context: ContextBuilder(systemPrompt: systemPrompt,
                                    taskContract: taskContract,
                                    contextBundle: contextBundle,
                                    skillSnapshot: skillSnapshot,
                                    runtimeEnvironment: .cowork,
                                    conversationHistoryPolicy: usesMainConversationHistory
                                        ? .coworkMainThread
                                        : .taskScoped),
            terminal: terminal,
            messenger: messenger,
            agentManager: manager,
            workTaskManager: workTaskManager,
            goalManager: goalManager,
            runController: canControlRun
                ? OrchestratorRunController(
                    currentTaskID: taskContract?.id,
                    orchestrator: self)
                : nil,
            imageGenerator: imageGenerator,
            imageResolver: imageResolver,
            sessionNaming: agent.name == Self.mainAgentID ? sessionNaming : nil,
            capabilityLease: capabilityLease,
            workspaceLease: workspaceLease,
            rootTaskID: rootTaskID,
            taskAttempt: taskAttempt,
            executionScope: AgentExecutionScope(
                goalID: taskContract?.goalID,
                continuationRunID: taskContract?.continuationRunID,
                workTaskID: taskContract?.workTaskID,
                invocationTaskID: taskContract?.id,
                agentID: agent.name),
            tokenBudgetMeter: tokenBudgetMeter,
            authorizationPreparer: { [self] request in
                try await prepareAuthorization(request)
            },
            authorizationRevalidator: { [self] authorization in
                await toolExecutionAuthorizationRevalidationFailure(authorization)
            },
            toolSnapshotProvider:
                requestToolSnapshotProvider
        )
        do {
            let output = try await loop.send(
                input,
                images: images,
                userMessage: userMessage,
                recordUserMessage: recordUserMessage,
                submissionID: taskContract?.submissionID)
            if let internalToolLease {
                try await internalToolLease.closeRequiringDrain()
            }
            return AgentRunResult(
                output: output,
                presentedMessageIDs: contextBundle.directMessages.compactMap(\.messageID))
        } catch let runError {
            if let internalToolLease {
                do {
                    try await internalToolLease.closeRequiringDrain()
                } catch {
                    throw error
                }
            }
            throw runError
        }
    }

    private func prepareAuthorization(
        _ request: ToolAuthorizationPreparationRequest
    ) throws -> ToolAuthorizationPreparation {
        if request.toolName == "spawn_agent" {
            return try prepareSpawnAuthorization(request)
        }
        guard request.toolName == "delegate_task" else {
            return ToolAuthorizationPreparation(intent: request.baseIntent)
        }
        guard let requesterID = request.invocation.agent,
              let requester = registry.agent(requesterID) else {
            throw IntatisError.permissionDenied("delegating agent is not attached")
        }
        let arguments = try JSONDecoder().decode(
            DelegationAuthorizationArguments.self,
            from: Data(request.normalizedArguments.utf8))
        let knowledgeCapabilities = arguments.knowledgeAccess?.capabilities ?? []
        let requestedWorkspaceAccess = arguments.knowledgeAccess?.workspaceAccess
            ?? .readOnly
        if !knowledgeCapabilities.isEmpty {
            guard let augmenter = internalToolRegistryAugmenter,
                  knowledgeCapabilities.isSubset(
                    of: augmenter.additionalCapabilities),
                  let requesterLease = existingCapabilityLease(
                    for: requesterID,
                    taskID: request.invocation.taskID),
                  knowledgeCapabilities.isSubset(of: requesterLease.tools),
                  let requesterWorkspaceLease = existingWorkspaceLease(
                    for: requesterID,
                    taskID: request.invocation.taskID),
                  requestedWorkspaceAccess != .readWrite
                    || requesterWorkspaceLease.access == .readWrite else {
                throw IntatisError.permissionDenied(
                    "the requested delegated Knowledge capability is not available from the current exact leases")
            }
        }
        let suppliedTarget = arguments.to.map(Self.normalizedAgentName)
            .flatMap { value in
                value.isEmpty || value.lowercased() == "auto" ? nil : value
            }
        let targetWasExplicit = suppliedTarget != nil
        let target: AgentID
        let targetFingerprint: String
        let targetModel: ModelID
        let targetInferenceBinding: AgentInferenceBinding?
        let targetWorkspace: String

        if let suppliedTarget {
            let candidate = AgentID(rawValue: suppliedTarget)
            guard candidate != requesterID,
                  candidate != Self.mainAgentID,
                  candidate != Self.automaticPermissionReviewerID else {
                throw IntatisError.permissionDenied("requested delegation target is reserved")
            }
            guard let existing = registry.agent(candidate) else {
                throw IntatisError.notFound(
                    "delegation target is not attached; spawn it in an earlier tool-call round")
            }
            target = candidate
            targetFingerprint = delegationTargetFingerprint(existing)
            targetModel = existing.model
            targetInferenceBinding = existing.agentInferenceBinding
            targetWorkspace = existing.workspaceRoot.resolvingSymlinksInPath()
                .standardizedFileURL.path
        } else if let idle = registry.all()
            .filter({ candidate in
                candidate.name != requesterID
                    && candidate.name != Self.mainAgentID
                    && candidate.name != Self.automaticPermissionReviewerID
                    && inferenceBindingIsReady(candidate)
                    && candidate.workspaceRoot.standardizedFileURL.path
                        == requester.workspaceRoot.standardizedFileURL.path
                    && !automaticDelegationReservations.contains(candidate.name)
                    && isAgentAvailableForDelegation(candidate.name)
            })
            .sorted(by: { $0.name.rawValue < $1.name.rawValue })
            .first {
            target = idle.name
            targetFingerprint = delegationTargetFingerprint(idle)
            targetModel = idle.model
            targetInferenceBinding = idle.agentInferenceBinding
            targetWorkspace = idle.workspaceRoot.resolvingSymlinksInPath()
                .standardizedFileURL.path
        } else {
            throw IntatisError.notFound(
                "no available attached delegation worker; spawn one in an earlier tool-call round")
        }

        if let failure = delegationFailure(
            from: requesterID,
            to: target,
            parentTaskID: request.invocation.taskID) {
            throw IntatisError.permissionDenied(failure)
        }

        var intent = request.baseIntent
        intent.resources.removeAll { $0.kind == .agent }
        intent.resources.insert(
            PermissionResource(kind: .agent, value: target.rawValue),
            at: 0)
        intent.resources.removeAll { $0.kind == .workspace }
        intent.resources.append(PermissionResource(
            kind: .workspace,
            value: targetWorkspace,
            access: requestedWorkspaceAccess))
        if let knowledgeAccess = arguments.knowledgeAccess {
            intent.resources.append(PermissionResource(
                kind: .tool,
                value: "delegated_knowledge:\(knowledgeAccess.rawValue)",
                access: requestedWorkspaceAccess))
        }
        intent.metadata["targetWasExplicit"] = .bool(targetWasExplicit)
        intent.metadata["targetModel"] = .string(targetModel.rawValue)
        intent.metadata["targetWorkspace"] = .string(targetWorkspace)
        intent.metadata["requestedAccess"] = .string(
            requestedWorkspaceAccess.rawValue)
        intent.metadata["delegatedKnowledgeAccess"] = arguments.knowledgeAccess
            .map { .string($0.rawValue) } ?? .null
        intent.metadata["delegatedKnowledgeCapabilities"] = .array(
            knowledgeCapabilities
                .sorted { $0.rawValue < $1.rawValue }
                .map { .string($0.rawValue) })
        intent.metadata["canCoordinate"] = .bool(false)
        intent.metadata.removeValue(forKey: "mayCreateWorker")
        intent.metadata.merge(Self.inferenceMetadata(targetInferenceBinding)) { _, profile in profile }
        if let targetInferenceBinding,
           let catalogBinding = availableInferenceProfiles[
               targetInferenceBinding.inferenceProfileID
           ] {
            intent.metadata["targetInferenceCatalogFingerprint"] = .string(
                ToolRegistry.authorizationFingerprint(catalogBinding))
        } else {
            // `nil` is a meaningful snapshot for a retained historical
            // binding. A later host catalog insertion/removal is still a route
            // authorization change and must not cross this ToolCall.
            intent.metadata["targetInferenceCatalogFingerprint"] = .null
        }
        intent.metadata["targetFingerprint"] = .string(targetFingerprint)
        if requiresInferenceBindings, targetInferenceBinding == nil {
            throw IntatisError.permissionDenied(
                "delegation target has no exact inference profile binding")
        }
        return ToolAuthorizationPreparation(
            intent: intent,
            targetAgentInferenceBinding: targetInferenceBinding)
    }

    private func prepareSpawnAuthorization(
        _ request: ToolAuthorizationPreparationRequest
    ) throws -> ToolAuthorizationPreparation {
        guard let requesterID = request.invocation.agent,
              let requester = registry.agent(requesterID) else {
            throw IntatisError.permissionDenied("spawning agent is not attached")
        }
        let arguments = try JSONDecoder().decode(
            SpawnAuthorizationArguments.self,
            from: Data(request.normalizedArguments.utf8))
        let requestedProfileID = arguments.inferenceProfileID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let binding: AgentInferenceBinding?
        if let requestedProfileID, !requestedProfileID.isEmpty {
            let profileID = InferenceProfileID(rawValue: requestedProfileID)
            guard let approved = availableInferenceProfiles[profileID] else {
                throw IntatisError.permissionDenied(
                    "requested inference profile is not in the host-approved session catalog")
            }
            binding = approved
        } else {
            binding = requester.agentInferenceBinding
        }
        if requiresInferenceBindings, binding == nil {
            throw IntatisError.permissionDenied(
                "spawn target has no exact inference profile binding")
        }
        var intent = request.baseIntent
        intent.metadata.merge(Self.inferenceMetadata(binding)) { _, profile in profile }
        intent.metadata["profileSelection"] = .string(
            requestedProfileID?.isEmpty == false ? "explicit_host_catalog" : "inherit_parent_exact")
        return ToolAuthorizationPreparation(
            intent: intent,
            targetAgentInferenceBinding: binding)
    }

    private func delegationTargetFingerprint(_ agent: Agent) -> String {
        let capabilityLeaseID = defaultCapabilityLeaseIDs[agent.name]
        let workspaceLeaseID = defaultWorkspaceLeaseIDs[agent.name]
        return ToolRegistry.authorizationDigest([
            agent.name.rawValue,
            agent.workspaceRoot.resolvingSymlinksInPath().standardizedFileURL.path,
            agent.model.rawValue,
            agent.agentInferenceBinding.map(ToolRegistry.authorizationFingerprint) ?? "",
            agent.profile.rawValue,
            String(agent.coordinationDepth),
            capabilityLeaseID?.rawValue ?? "",
            capabilityLeaseID.flatMap { capabilityLeases[$0] }
                .map(ToolRegistry.authorizationFingerprint) ?? "",
            workspaceLeaseID?.rawValue ?? "",
            workspaceLeaseID.flatMap { workspaceLeases[$0] }
                .map(ToolRegistry.authorizationFingerprint) ?? "",
        ].joined(separator: "\u{001F}"))
    }

    private static func inferenceMetadata(
        _ binding: AgentInferenceBinding?
    ) -> [String: JSONValue] {
        guard let binding else {
            return ["targetInferenceProfile": .null]
        }
        return [
            "targetInferenceProfileID": .string(binding.inferenceProfileID.rawValue),
            "targetInferenceProfileRevision": .string(binding.inferenceProfileRevision.rawValue),
            "targetInferenceConnectionID": .string(binding.inferenceConnectionID.rawValue),
            "targetInferenceConnectionRevision": .string(binding.inferenceConnectionRevision.rawValue),
            "targetInferenceModel": .string(binding.modelID.rawValue),
            "targetInferenceVariant": binding.variantID.map(JSONValue.string) ?? .null,
            "targetInferenceRouteLabel": binding.safeRouteLabel.map(JSONValue.string) ?? .null,
            "targetInferenceTrustDomain": binding.trustDomain.map(JSONValue.string) ?? .null,
            "targetInferenceEgressClassification": binding.egressClassification.map(JSONValue.string) ?? .null,
            "targetInferenceFingerprint": .string(
                ToolRegistry.authorizationFingerprint(binding)),
        ]
    }

    /// Reconstructs the task-scoped Knowledge grant only from the immutable
    /// authorization metadata produced during delegate_task preparation. Any
    /// missing, duplicated, unknown, or internally inconsistent value fails
    /// closed instead of becoming an empty/default grant.
    private static func delegatedKnowledgeGrant(
        from authorization: ResolvedToolAuthorization
    ) -> (capabilities: Set<ToolCapability>, workspaceAccess: WorkspaceAccess)? {
        guard let accessValue = authorization.intent.metadata[
                "delegatedKnowledgeAccess"],
              let capabilitiesValue = authorization.intent.metadata[
                "delegatedKnowledgeCapabilities"],
              case .array(let rawCapabilities) = capabilitiesValue,
              case .string(let rawWorkspaceAccess)? =
                authorization.intent.metadata["requestedAccess"],
              let workspaceAccess = WorkspaceAccess(
                rawValue: rawWorkspaceAccess) else {
            return nil
        }
        let access: DelegatedKnowledgeAccess?
        switch accessValue {
        case .null:
            access = nil
        case .string(let raw):
            guard let parsed = DelegatedKnowledgeAccess(rawValue: raw) else {
                return nil
            }
            access = parsed
        default:
            return nil
        }
        var capabilities = Set<ToolCapability>()
        for value in rawCapabilities {
            guard case .string(let raw) = value,
                  let capability = ToolCapability(rawValue: raw),
                  capability == .buildKnowledge
                    || capability == .searchKnowledge,
                  capabilities.insert(capability).inserted else {
                return nil
            }
        }
        let expected = access?.capabilities ?? []
        let expectedWorkspaceAccess = access?.workspaceAccess ?? .readOnly
        guard capabilities == expected,
              workspaceAccess == expectedWorkspaceAccess else {
            return nil
        }
        return (capabilities, workspaceAccess)
    }

    /// Live actor-isolated lease check used immediately after review and again
    /// after the durable execution prepare boundary. A captured lease value is
    /// not enough: task completion, detach, or cancellation may revoke it while
    /// the reviewer is awaiting its provider.
    private func authorizationRevalidationFailure(
        _ authorization: ResolvedToolAuthorization,
        allowingDelegationReservationFor reservedTarget: AgentID? = nil
    ) -> String? {
        if let taskID = authorization.taskID,
           let runID = taskContract(forCausalTaskID: taskID)?.continuationRunID {
            if let claim = continuationRunCloseClaims[runID] {
                return "ContinuationRun is closed: \(claim.reason)"
            }
            if (continuationRunCloseInstallations[runID] ?? 0) > 0 {
                return "ContinuationRun close is being durably installed"
            }
        }
        if let binding = authorization.targetAgentInferenceBinding {
            guard case .string(let reviewedFingerprint)? =
                    authorization.intent.metadata["targetInferenceFingerprint"],
                  reviewedFingerprint == ToolRegistry.authorizationFingerprint(binding) else {
                return "target inference profile authorization fingerprint is missing or changed"
            }
        } else if requiresInferenceBindings,
                  authorization.toolName == "delegate_task"
                    || authorization.toolName == "spawn_agent" {
            return "target inference profile binding is missing from authorization"
        }
        if let failure = delegationInferenceCatalogAuthorizationFailure(authorization) {
            return failure
        }
        if authorization.capabilityLeaseID != nil
            || !authorization.requiredCapabilities.isEmpty
            || authorization.requiredCommunication != .none
            || authorization.requiredDelegation != .none {
            guard let leaseID = authorization.capabilityLeaseID,
                  let liveLease = capabilityLeases[leaseID] else {
                return "capability lease was revoked before tool execution"
            }
            let required = Set(authorization.requiredCapabilities)
            guard required.isEmpty || !required.isDisjoint(with: liveLease.tools) else {
                return "capability lease no longer grants the registered tool"
            }
            guard liveLease.taskID == authorization.capabilityTaskID else {
                return "capability lease task binding changed before tool execution"
            }
            guard authorization.capabilityLeaseFingerprint
                    == ToolRegistry.authorizationFingerprint(liveLease) else {
                return "capability lease grants changed before tool execution"
            }
            if let boundTaskID = liveLease.taskID,
               boundTaskID != authorization.taskID {
                return "capability lease belongs to a different task"
            }
        }

        if let workspaceLeaseID = authorization.workspaceLeaseID {
            guard let liveLease = workspaceLeases[workspaceLeaseID] else {
                return "workspace lease was revoked before tool execution"
            }
            guard liveLease.access == authorization.workspaceAccess else {
                return "workspace lease access changed before tool execution"
            }
            guard liveLease.workspaceID == authorization.workspaceID,
                  liveLease.taskID == authorization.workspaceTaskID,
                  liveLease.rootPath == authorization.workspaceRootPath else {
                return "workspace lease identity or task binding changed before tool execution"
            }
            guard liveLease.rootIdentity == authorization.workspaceRootIdentity else {
                return "workspace lease root identity changed before tool execution"
            }
            guard authorization.workspaceLeaseFingerprint
                    == ToolRegistry.authorizationFingerprint(liveLease) else {
                return "workspace lease path rules changed before tool execution"
            }
            if let boundTaskID = liveLease.taskID,
               boundTaskID != authorization.taskID {
                return "workspace lease belongs to a different task"
            }
            if let rootIdentity = liveLease.rootIdentity,
               !rootIdentity.matchesCurrentDirectory(rootPath: liveLease.rootPath) {
                return "workspace root identity changed before tool execution"
            }
        }
        return semanticAuthorizationFailure(
            authorization,
            allowingDelegationReservationFor: reservedTarget)
    }

    private func delegationInferenceCatalogAuthorizationFailure(
        _ authorization: ResolvedToolAuthorization
    ) -> String? {
        guard requiresInferenceBindings,
              authorization.toolName == "delegate_task",
              let binding = authorization.targetAgentInferenceBinding else {
            return nil
        }
        guard let reviewedCatalogFingerprint =
                authorization.intent.metadata["targetInferenceCatalogFingerprint"] else {
            return "delegation authorization has no inference catalog snapshot"
        }
        let liveCatalogBinding = availableInferenceProfiles[binding.inferenceProfileID]
        switch reviewedCatalogFingerprint {
        case .null:
            guard liveCatalogBinding == nil else {
                return "host-approved inference profile catalog changed before delegation admission"
            }
        case .string(let fingerprint):
            guard let liveCatalogBinding,
                  ToolRegistry.authorizationFingerprint(liveCatalogBinding) == fingerprint else {
                return "host-approved inference profile catalog changed before delegation admission"
            }
        default:
            return "delegation authorization inference catalog snapshot is invalid"
        }
        return nil
    }

    /// Final executor-side check for an already-reviewed delegation to an
    /// attached target.
    private func finalDelegationAuthorizationFailure(
        _ admission: AuthorizedDelegationAdmission,
        expectedFrom: AgentID,
        expectedTaskID: TaskID?,
        allowingReservationFor reservedTarget: AgentID
    ) -> String? {
        let authorization = admission.authorization
        guard authorization.toolName == "delegate_task",
              authorization.agent == expectedFrom,
              authorization.taskID == expectedTaskID,
              admission.target == reservedTarget,
              authorization.targetAgentInferenceBinding == admission.binding,
              let targetValue = authorization.intent.resources.first(where: {
                  $0.kind == .agent
              })?.value,
              AgentID(rawValue: Self.normalizedAgentName(targetValue)) == admission.target else {
            return "delegate_task authorization binding changed before task admission"
        }
        guard let knowledgeGrant = Self.delegatedKnowledgeGrant(
                from: authorization),
              knowledgeGrant.capabilities == admission.knowledgeCapabilities,
              knowledgeGrant.workspaceAccess == admission.workspaceAccess else {
            return "delegate_task Knowledge capability binding changed before task admission"
        }
        guard automaticDelegationReservations.contains(reservedTarget) else {
            return "reviewed delegation reservation was lost before task admission"
        }
        if let failure = authorizationRevalidationFailure(
            authorization,
            allowingDelegationReservationFor: reservedTarget
        ) {
            return failure
        }
        guard let currentTarget = registry.agent(admission.target),
              currentTarget.agentInferenceBinding == admission.binding,
              currentTarget.model == (admission.binding?.modelID ?? currentTarget.model),
              delegationTargetFingerprint(currentTarget) == admission.targetFingerprint else {
            return "reviewed delegation target route or identity changed before task admission"
        }
        guard case .string(let reviewedFingerprint)? =
                authorization.intent.metadata["targetFingerprint"],
              reviewedFingerprint == admission.targetFingerprint else {
            return "reviewed delegation target fingerprint changed before task admission"
        }
        return nil
    }

    /// The synchronous authorization checks above protect the live roster,
    /// leases, and host-approved profile set. Exact inference resolution is an
    /// async boundary of its own (for example, lazy credential lookup). Run it
    /// from AgentLoop's pre-execution revalidation hook so a suspended resolver
    /// cannot move the first failure past the durable tool-execution boundary.
    /// Re-run the synchronous checks after the await to close catalog/roster
    /// TOCTOU without holding the admission lock across external resolution.
    private func toolExecutionAuthorizationRevalidationFailure(
        _ authorization: ResolvedToolAuthorization
    ) async -> String? {
        if let failure = authorizationRevalidationFailure(authorization) {
            return failure
        }
        guard requiresInferenceBindings,
              authorization.toolName == "spawn_agent"
                || authorization.toolName == "delegate_task",
              let binding = authorization.targetAgentInferenceBinding else {
            return nil
        }
        guard let targetValue = authorization.intent.resources.first(where: {
            $0.kind == .agent
        })?.value else {
            return "target inference profile authorization has no concrete agent"
        }
        let targetID = AgentID(rawValue: Self.normalizedAgentName(targetValue))
        let candidate: Agent
        if let live = registry.agent(targetID) {
            guard live.agentInferenceBinding == binding,
                  live.model == binding.modelID else {
                return "target agent inference profile changed before tool execution"
            }
            candidate = live
        } else {
            if authorization.toolName == "delegate_task" {
                return "reviewed delegation target is no longer attached"
            }
            let workspacePath = authorization.intent.resources.first(where: {
                $0.kind == .workspace
            })?.value ?? {
                guard case .string(let value)? =
                    authorization.intent.metadata["targetWorkspace"] else {
                    return ""
                }
                return value
            }()
            guard !workspacePath.isEmpty else {
                return "target inference profile authorization has no concrete workspace"
            }
            candidate = Agent(
                name: targetID,
                workspaceRoot: URL(fileURLWithPath: workspacePath).standardizedFileURL,
                model: binding.modelID,
                agentInferenceBinding: binding,
                profile: .reviewed,
                coordinationDepth: 0)
        }
        do {
            _ = try await resolvedProvider(for: candidate)
        } catch {
            return "selected inference profile revision is unavailable or incompatible"
        }
        return authorizationRevalidationFailure(authorization)
    }

    private func semanticAuthorizationFailure(
        _ authorization: ResolvedToolAuthorization,
        allowingDelegationReservationFor reservedTarget: AgentID? = nil
    ) -> String? {
        guard let from = authorization.agent else {
            return "authorization snapshot has no requesting agent"
        }
        func targetAgent() -> AgentID? {
            guard let value = authorization.intent.resources.first(where: {
                $0.kind == .agent
            })?.value else { return nil }
            return AgentID(rawValue: Self.normalizedAgentName(value))
        }

        switch authorization.toolName {
        case "send_message", "request_information", "reply_message":
            guard let to = targetAgent() else {
                return "communication authorization has no concrete target agent"
            }
            guard registry.agent(to) != nil,
                  to != Self.automaticPermissionReviewerID else {
                return "communication target is not an attached task agent"
            }
            let operation: CommunicationOperation
            switch authorization.toolName {
            case "send_message": operation = .send
            case "request_information": operation = .requestInformation
            default: operation = .reply
            }
            return communicationFailure(
                from: from,
                to: to,
                taskID: authorization.taskID,
                operation: operation)

        case "ask_agent":
            guard let to = targetAgent(), registry.agent(to) != nil else {
                return "delegation target is not an attached agent"
            }
            return delegationFailure(
                from: from,
                to: to,
                parentTaskID: authorization.taskID)

        case "delegate_task":
            guard let target = targetAgent(),
                  !target.rawValue.isEmpty,
                  target.rawValue.lowercased() != "auto" else {
                return "delegation authorization has no concrete target agent"
            }
            guard target != from,
                  target != Self.mainAgentID,
                  target != Self.automaticPermissionReviewerID else {
                return "requested delegation target is reserved"
            }
            if let failure = delegationFailure(
                from: from,
                to: target,
                parentTaskID: authorization.taskID) {
                return failure
            }
            guard registry.agent(from) != nil else {
                return "delegating agent is not attached"
            }
            guard case .string(let reviewedWorkspace)? = authorization.intent.metadata["targetWorkspace"],
                  case .bool(let targetWasExplicit)? = authorization.intent.metadata["targetWasExplicit"] else {
                return "delegation authorization has no host target snapshot"
            }
            guard let existing = registry.agent(target) else {
                return "reviewed delegation target is no longer attached"
            }
            guard existing.agentInferenceBinding
                    == authorization.targetAgentInferenceBinding else {
                return "reviewed delegation target inference profile changed"
            }
            guard existing.workspaceRoot.resolvingSymlinksInPath()
                .standardizedFileURL.path == reviewedWorkspace else {
                return "reviewed delegation target workspace changed"
            }
            guard case .string(let reviewedFingerprint)? =
                authorization.intent.metadata["targetFingerprint"],
                delegationTargetFingerprint(existing) == reviewedFingerprint else {
                return "reviewed delegation target identity changed"
            }
            if !targetWasExplicit,
               automaticDelegationReservations.contains(target),
               reservedTarget != target {
                return "automatically selected delegation target is reserved by another invocation"
            }
            return nil

        case "spawn_agent":
            if let target = targetAgent() {
                if target == from { return "agent cannot spawn itself" }
                if target == Self.mainAgentID || target == Self.automaticPermissionReviewerID {
                    return "requested agent name is reserved"
                }
                if registry.agent(target) != nil { return "agent already exists" }
            }
            guard let path = authorization.intent.resources.first(where: {
                $0.kind == .workspace
            })?.value else {
                return "agent spawn authorization has no concrete workspace"
            }
            let assessment = assessWorkspaceAttach(URL(fileURLWithPath: path))
            guard assessment.canAskUser,
                  let canonical = assessment.canonical,
                  canonical.path == path else {
                return assessment.canAskUser
                    ? "agent spawn workspace must use its canonical reviewed path"
                    : assessment.reason
            }
            guard let currentIdentity = WorkspaceRootIdentity.capture(rootPath: path),
                  case .string(let reviewedDevice)? = authorization.intent.metadata["targetDeviceID"],
                  case .string(let reviewedFile)? = authorization.intent.metadata["targetFileID"],
                  String(currentIdentity.deviceID) == reviewedDevice,
                  String(currentIdentity.fileID) == reviewedFile else {
                return "agent spawn workspace identity changed before authorization"
            }
            guard let lease = existingCapabilityLease(
                for: from,
                taskID: authorization.taskID),
                case .granted(let budget) = lease.delegation,
                lease.tools.contains(.attachWorkspace) else {
                return "spawning agents is not granted for the current task"
            }
            let requestedAccess = authorization.intent.resources.first(where: {
                $0.kind == .workspace
            })?.access ?? .readOnly
            if requestedAccess == .readWrite,
               existingWorkspaceLease(for: from, taskID: authorization.taskID)?.access != .readWrite {
                return "a read-only workspace lease cannot grant read-write access to a child agent"
            }
            let canCoordinate: Bool
            if case .bool(let value)? = authorization.intent.metadata["canCoordinate"] {
                canCoordinate = value
            } else {
                canCoordinate = false
            }
            if canCoordinate, budget.maxDepth < 1 {
                return "coordinator spawning exceeds the delegation depth budget"
            }
            if case .string(let selection)? = authorization.intent.metadata["profileSelection"] {
                switch selection {
                case "inherit_parent_exact":
                    guard registry.agent(from)?.agentInferenceBinding
                            == authorization.targetAgentInferenceBinding else {
                        return "parent inference profile changed before spawn execution"
                    }
                case "explicit_host_catalog":
                    guard let binding = authorization.targetAgentInferenceBinding,
                          availableInferenceProfiles[binding.inferenceProfileID] == binding else {
                        return "host-approved inference profile changed before spawn execution"
                    }
                default:
                    return "agent spawn profile selection is invalid"
                }
            } else if requiresInferenceBindings {
                return "agent spawn authorization has no profile selection"
            }
            let activeAgentCount = registry.names.filter {
                $0 != Self.automaticPermissionReviewerID
            }.count
            guard activeAgentCount < taskGraph.policy.maxActiveAgentsPerThread else {
                return "active agent limit reached (\(taskGraph.policy.maxActiveAgentsPerThread))"
            }
            return nil

        case "remove_agent":
            guard let target = targetAgent() else {
                return "agent removal authorization has no concrete target"
            }
            if target == Self.mainAgentID || target == Self.automaticPermissionReviewerID {
                return "requested agent cannot be removed"
            }
            return registry.agent(target) == nil ? "agent does not exist" : nil

        default:
            return nil
        }
    }

    private static func normalizedAgentName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    }

    private static let maxAgentNameCharacters = 64

    private static func agentNameValidationError(_ raw: String) -> String? {
        guard !raw.isEmpty else { return "an agent name is required" }
        if raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "agent names cannot contain control characters"
        }
        if raw.contains(where: { $0.isWhitespace }) {
            return "agent names cannot contain whitespace"
        }
        guard raw.count <= maxAgentNameCharacters else {
            return "agent names cannot exceed \(maxAgentNameCharacters) characters"
        }
        guard let first = raw.unicodeScalars.first,
              isASCIIAlphaNumeric(first),
              raw.unicodeScalars.allSatisfy(isValidAgentNameScalar) else {
            return "agent names must start with an ASCII letter or digit and contain only ASCII letters, digits, '-' or '_'"
        }
        return nil
    }

    private static func isValidAgentNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIAlphaNumeric(scalar) || scalar.value == 45 || scalar.value == 95
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return false
        }
    }

    private func reverseLeaseAgents<ID: Hashable>(_ leaseAgents: [ID: AgentID]) -> [AgentID: ID] {
        var result: [AgentID: ID] = [:]
        for (leaseID, agent) in leaseAgents where result[agent] == nil {
            guard agent != Self.automaticPermissionReviewerID else { continue }
            result[agent] = leaseID
        }
        return result
    }

    private func deterministicDefaultCapabilityLeases(
        projection: CoworkProjection,
        taskLeaseIDs: Set<CapabilityLeaseID>
    ) -> [AgentID: CapabilityLeaseID] {
        var result: [AgentID: CapabilityLeaseID] = [:]
        let candidates = projection.capabilityLeaseAgents.compactMap {
            leaseID, agent -> (agent: AgentID, leaseID: CapabilityLeaseID, currentSurfaceScore: Int)? in
            guard agent != Self.automaticPermissionReviewerID,
                  let lease = projection.capabilityLeases[leaseID],
                  lease.taskID == nil,
                  !taskLeaseIDs.contains(leaseID),
                  capabilityLeases[leaseID] != nil else { return nil }
            var currentSurfaceScore = 0
            if lease.tools.contains(.replyMessage),
               lease.tools.contains(.requestInformation) {
                currentSurfaceScore += 1
            }
            if agent == Self.mainAgentID {
                currentSurfaceScore += [
                    ToolCapability.renameSession,
                    ToolCapability.submitGoalVerdict,
                    ToolCapability.controlRun,
                ].reduce(into: 0) { score, capability in
                    if lease.tools.contains(capability) { score += 1 }
                }
            }
            return (
                agent: agent,
                leaseID: leaseID,
                currentSurfaceScore: currentSurfaceScore)
        }.sorted {
            if $0.agent == $1.agent {
                if $0.currentSurfaceScore != $1.currentSurfaceScore {
                    return $0.currentSurfaceScore > $1.currentSurfaceScore
                }
                return $0.leaseID.rawValue < $1.leaseID.rawValue
            }
            return $0.agent.rawValue < $1.agent.rawValue
        }
        for candidate in candidates where result[candidate.agent] == nil {
            result[candidate.agent] = candidate.leaseID
        }
        return result
    }

    /// Old sessions can contain a perfectly valid @main default lease created
    /// before current main-only session/Goal controls existed. Upgrade that
    /// durable default without mutating its historical grant in place. Leases referenced by any task
    /// remain available to that frozen contract; an unreferenced default is
    /// revoked and replaced atomically.
    private func upgradeMainControlCapabilitiesIfNeeded(
        referencedLeaseIDs: Set<CapabilityLeaseID>
    ) async {
        let requiredCapabilities: Set<ToolCapability> = [
            .renameSession,
            .submitGoalVerdict,
            .controlRun,
        ]
        guard registry.agent(Self.mainAgentID) != nil,
              let oldID = defaultCapabilityLeaseIDs[Self.mainAgentID],
              let oldLease = capabilityLeases[oldID],
              oldLease.taskID == nil,
              !requiredCapabilities.isSubset(of: oldLease.tools) else { return }

        var upgraded = oldLease
        upgraded.id = CapabilityLeaseID.new()
        upgraded.taskID = nil
        upgraded.tools.formUnion(requiredCapabilities)
        upgraded.expiresAtTaskCompletion = false
        let revokeOld = !referencedLeaseIDs.contains(oldID)
        var events: [Event] = []
        if revokeOld {
            events.append(.capabilityLeaseRevoked(CapabilityLeaseRevokedPayload(
                agent: Self.mainAgentID,
                leaseID: oldID,
                reason: "replace legacy @main default with current main-only control capabilities",
                metadata: CoworkEventMetadata(
                    agentID: Self.mainAgentID,
                    capabilityLeaseID: oldID,
                    scope: .capability))))
        }
        events.append(.capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
            agent: Self.mainAgentID,
            lease: upgraded,
            metadata: CoworkEventMetadata(
                agentID: Self.mainAgentID,
                capabilityLeaseID: upgraded.id,
                scope: .capability))))

        do {
            try await appendAdmissionEvents(events)
        } catch {
            try? await log.append(.error(ErrorPayload(
                code: "restore_main_control_capability_upgrade_failed",
                message: error.localizedDescription)))
            return
        }
        if revokeOld {
            capabilityLeases[oldID] = nil
        }
        capabilityLeases[upgraded.id] = upgraded
        defaultCapabilityLeaseIDs[Self.mainAgentID] = upgraded.id
    }

    /// Legacy worker defaults predate correlation-safe information follow-ups.
    /// Adding requestInformation to a reply-only default does not itself grant
    /// initiation: normal worker invocations remain reply-only. It lets the
    /// host derive an exact-sender selectedAgents lease only for an information
    /// reply receipt, where based_on is also durably validated.
    private func upgradeMailboxFollowupCapabilitiesIfNeeded(
        referencedLeaseIDs: Set<CapabilityLeaseID>
    ) async {
        let candidates = defaultCapabilityLeaseIDs.keys.sorted {
            $0.rawValue < $1.rawValue
        }
        for agentID in candidates {
            guard agentID != Self.automaticPermissionReviewerID,
                  let oldID = defaultCapabilityLeaseIDs[agentID],
                  let oldLease = capabilityLeases[oldID],
                  oldLease.taskID == nil,
                  oldLease.tools.contains(.replyMessage),
                  !oldLease.tools.contains(.requestInformation) else { continue }
            switch oldLease.communication {
            case .none:
                continue
            case .replyOnly, .selectedAgents, .taskGroup, .anyAgentInThread:
                break
            }

            var upgraded = oldLease
            upgraded.id = CapabilityLeaseID.new()
            upgraded.taskID = nil
            upgraded.tools.insert(.requestInformation)
            upgraded.expiresAtTaskCompletion = false
            let revokeOld = !referencedLeaseIDs.contains(oldID)
            var events: [Event] = []
            if revokeOld {
                events.append(.capabilityLeaseRevoked(CapabilityLeaseRevokedPayload(
                    agent: agentID,
                    leaseID: oldID,
                    reason: "replace legacy default with correlation-safe mailbox follow-up capability",
                    metadata: CoworkEventMetadata(
                        agentID: agentID,
                        capabilityLeaseID: oldID,
                        scope: .capability))))
            }
            events.append(.capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                agent: agentID,
                lease: upgraded,
                metadata: CoworkEventMetadata(
                    agentID: agentID,
                    capabilityLeaseID: upgraded.id,
                    scope: .capability))))

            do {
                try await appendAdmissionEvents(events)
            } catch {
                try? await log.append(.error(ErrorPayload(
                    code: "restore_mailbox_followup_capability_upgrade_failed",
                    message: "@\(agentID.rawValue): \(error.localizedDescription)")))
                continue
            }
            if revokeOld {
                capabilityLeases[oldID] = nil
            }
            capabilityLeases[upgraded.id] = upgraded
            defaultCapabilityLeaseIDs[agentID] = upgraded.id
        }
    }

    private func deterministicDefaultWorkspaceLeases(
        projection: CoworkProjection,
        taskLeaseIDs: Set<WorkspaceLeaseID>
    ) -> [AgentID: WorkspaceLeaseID] {
        var result: [AgentID: WorkspaceLeaseID] = [:]
        let candidates = projection.workspaceLeaseAgents.compactMap { leaseID, agent -> (AgentID, WorkspaceLeaseID)? in
            guard agent != Self.automaticPermissionReviewerID,
                  let lease = projection.workspaceLeases[leaseID],
                  lease.taskID == nil,
                  !taskLeaseIDs.contains(leaseID),
                  workspaceLeases[leaseID] != nil else { return nil }
            return (agent, leaseID)
        }.sorted {
            if $0.0 == $1.0 { return $0.1.rawValue < $1.1.rawValue }
            return $0.0.rawValue < $1.0.rawValue
        }
        for (agent, leaseID) in candidates where result[agent] == nil {
            result[agent] = leaseID
        }
        return result
    }

    private func pendingMessageDetails(for agent: AgentID,
                                       pendingIDs: Set<MessageID>,
                                       events: [Envelope]) -> [PendingAgentMessage] {
        var details: [MessageID: PendingAgentMessage] = [:]
        for envelope in events {
            switch envelope.event {
            case .agentMessage(let payload):
                guard payload.to == agent, pendingIDs.contains(payload.messageId) else { continue }
                details[payload.messageId] = PendingAgentMessage(
                    id: payload.messageId,
                    sender: payload.from,
                    recipient: agent,
                    content: payload.content,
                    kind: payload.kind?.rawValue ?? "send_message",
                    taskID: payload.taskID,
                    causalParentID: payload.metadata?.causalParentID,
                    inReplyTo: payload.inReplyTo,
                    createdAt: payload.metadata?.createdAt ?? envelope.ts)
            case .informationRequested(let payload):
                guard payload.to == agent, pendingIDs.contains(payload.requestID) else { continue }
                details[payload.requestID] = PendingAgentMessage(
                    id: payload.requestID,
                    sender: payload.from,
                    recipient: agent,
                    content: payload.question,
                    kind: AgentCommunicationKind.requestInformation.rawValue,
                    taskID: payload.taskID,
                    causalParentID: payload.metadata?.causalParentID,
                    conversationID: payload.conversationID,
                    basedOn: payload.basedOn,
                    createdAt: payload.metadata?.createdAt ?? envelope.ts)
            case .informationReplied(let payload):
                guard payload.to == agent, pendingIDs.contains(payload.replyID) else { continue }
                details[payload.replyID] = PendingAgentMessage(
                    id: payload.replyID,
                    sender: payload.from,
                    recipient: agent,
                    content: payload.content,
                    kind: AgentCommunicationKind.replyMessage.rawValue,
                    taskID: payload.taskID,
                    causalParentID: payload.metadata?.causalParentID,
                    inReplyTo: payload.inReplyTo,
                    conversationID: payload.conversationID,
                    createdAt: payload.metadata?.createdAt ?? envelope.ts)
            default:
                break
            }
        }
        return pendingIDs.compactMap { details[$0] }.sorted { $0.createdAt < $1.createdAt }
    }

    private func activePermissionResponder() -> PermissionResponder {
        if automaticPermissionReviewDisabling {
            return responder
        }
        return automaticPermissionResponder ?? responder
    }

    private func agentVisibleNames(excluding excluded: AgentID) -> [AgentID] {
        registry.names.filter {
            guard $0 != excluded, $0 != Self.automaticPermissionReviewerID else {
                return false
            }
            return registry.agent($0).map(inferenceBindingIsReady) ?? false
        }
    }

    private func inferenceBindingIsReady(_ agent: Agent) -> Bool {
        !requiresInferenceBindings || agent.agentInferenceBinding != nil
    }

    private func prepareMailboxDeliveryTask(
        issuer: AgentID,
        assignee: Agent,
        messages: [PendingAgentMessage],
        authorityClass: MailboxDeliveryAuthorityClass,
        scopeContract: TaskContract?
    ) -> PreparedDelegatedTask {
        let taskID = TaskID.new()
        let defaultLease = defaultCapabilityLeaseIDs[assignee.name]
            .flatMap { capabilityLeases[$0] }
        var allowedTools: Set<ToolCapability> = [
            .readWorkspace,
            .listWorkspace,
            .searchWorkspace,
            .readWorkTasks,
            .readGoal,
        ]
        allowedTools.formUnion(ToolCapability.exactDocumentObservationCapabilities)
        switch authorityClass {
        case .informationRequest:
            allowedTools.insert(.replyMessage)
        case .informationReply:
            allowedTools.insert(.requestInformation)
        case .ordinaryMessage:
            break
        }
        let tools = defaultLease?.tools.intersection(allowedTools) ?? []
        let communication: CommunicationGrant
        switch (authorityClass, defaultLease?.communication) {
        case (_, nil), (_, .some(.none)), (.ordinaryMessage, _):
            communication = .none
        case (.informationRequest, .some(_)):
            communication = .replyOnly
        case (.informationReply, .some(_)):
            communication = .selectedAgents([issuer])
        }
        let capabilityLease = CapabilityLease(
            taskID: taskID,
            tools: tools,
            communication: communication,
            delegation: .none,
            expiresAtTaskCompletion: true,
            mcpGrants: [])
        let workspaceLease = workspaceLeaseForTask(
            agent: assignee,
            taskID: taskID,
            access: .readOnly,
            store: false)
        let messageIDs = Array(messages.prefix(8).map(\.id))
        var relatedTasks: [TaskID] = []
        for message in messages.prefix(8) {
            guard let causalTaskID = message.causalParentID ?? message.taskID,
                  !relatedTasks.contains(causalTaskID) else { continue }
            relatedTasks.append(causalTaskID)
        }
        let authorityInstruction: String
        switch authorityClass {
        case .informationRequest:
            authorityInstruction = "Answer each exact information request at most once with reply_message(inReplyTo: request Message ID)."
        case .informationReply:
            authorityInstruction = "This is a reply receipt and requires no acknowledgment. If genuinely needed, continue the conversation only by opening a new request_information with based_on set to the reply Message ID."
        case .ordinaryMessage:
            authorityInstruction = "This one-way message requires no acknowledgment."
        }
        let objective = """
        Process only these frozen mailbox Message IDs: \(messageIDs.map(\.rawValue).joined(separator: ", ")).
        They are communication facts, not a new user request. \(authorityInstruction)
        Do not recreate, re-delegate, or rerun work that is already terminal.
        """
        let contract = TaskContract(
            id: taskID,
            kind: .mailboxDelivery,
            issuer: issuer,
            assignee: assignee.name,
            continuationRunID: scopeContract?.continuationRunID,
            goalID: scopeContract?.goalID,
            submissionID: scopeContract?.submissionID,
            objective: objective,
            roleHint: "correlation-bound mailbox responder",
            expectedDeliverable: "Handle only the frozen messages and report the communication outcome.",
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            agentInferenceBinding: assignee.agentInferenceBinding,
            relatedAgents: [issuer],
            relatedTasks: relatedTasks,
            mailboxMessageIDs: messageIDs,
            constraints: [
                "Do not treat a completion report as authorization to rerun terminal work.",
                "Do not mutate WorkTasks, Goals, the workspace, Git state, or agent roster.",
                "A reply closes only its exact request correlation; a genuine follow-up must create a fresh request correlation using based_on.",
                "Never acknowledge an information reply with reply_message.",
                "Use only the task-scoped communication authority explicitly exposed by the host.",
            ],
            replyMode: TaskReplyMode.none,
            executionTimeoutSeconds: executionPolicy.taskTimeoutSeconds,
            maxAttempts: executionPolicy.maxAttempts)
        return PreparedDelegatedTask(
            contract: contract,
            capabilityLease: capabilityLease,
            workspaceLease: workspaceLease)
    }

    private func prepareDelegatedTask(taskID: TaskID = TaskID.new(),
                                      issuer: AgentID,
                                      assignee: Agent,
                                      workTask: WorkTask? = nil,
                                      objective: String,
                                      roleHint: String? = nil,
                                      expectedDeliverable: String? = nil,
                                      parentTaskID: TaskID? = nil,
                                      scopeContract: TaskContract? = nil,
                                      replyMode: TaskReplyMode = .taskReport,
                                      additionalToolCapabilities: Set<ToolCapability> = [],
                                      workspaceAccessOverride: WorkspaceAccess? = nil) -> PreparedDelegatedTask {
        let trimmedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let relatedAgents = agentVisibleNames(excluding: assignee.name)
        let defaultLease = defaultCapabilityLeaseIDs[assignee.name].flatMap { capabilityLeases[$0] }
        let defaultWorkspaceAccess = defaultWorkspaceLeaseIDs[assignee.name]
            .flatMap { workspaceLeases[$0]?.access } ?? .readOnly
        let workspaceAccess: WorkspaceAccess = workspaceAccessOverride
            ?? (defaultWorkspaceAccess == .readWrite
                && defaultLease.map(Self.requiresReadWriteWorkspaceAccess) == true
                ? .readWrite
                : .readOnly)
        var capabilityLease = defaultLease
            ?? CapabilityLease.worker(taskID: taskID, workspaceAccess: workspaceAccess)
        capabilityLease.tools.formUnion(additionalToolCapabilities)
        if assignee.name != Self.mainAgentID {
            capabilityLease.tools.remove(.submitGoalVerdict)
            capabilityLease.tools.remove(.renameSession)
            capabilityLease.tools.remove(.controlRun)
        }
        capabilityLease.id = CapabilityLeaseID.new()
        capabilityLease.taskID = taskID
        capabilityLease.expiresAtTaskCompletion = true
        let workspaceLease = workspaceLeaseForTask(
            agent: assignee,
            taskID: taskID,
            access: workspaceAccess,
            store: false)
        let contract = TaskContract(
            id: taskID,
            issuer: issuer,
            assignee: assignee.name,
            parentTaskID: parentTaskID,
            workTaskID: workTask?.id,
            continuationRunID: scopeContract?.continuationRunID,
            goalID: scopeContract?.goalID,
            submissionID: scopeContract?.submissionID,
            objective: trimmedObjective.isEmpty ? "Answer the assigned task." : trimmedObjective,
            roleHint: roleHint?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? Self.defaultRoleHint(for: assignee.name, objective: trimmedObjective),
            expectedDeliverable: expectedDeliverable?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "Answer the assigned task clearly and concisely.",
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            agentInferenceBinding: assignee.agentInferenceBinding,
            relatedAgents: relatedAgents,
            relatedTasks: [],
            constraints: Self.canCoordinate(capabilityLease) ? [] : Self.defaultWorkerConstraints,
            replyMode: replyMode,
            executionTimeoutSeconds: executionPolicy.taskTimeoutSeconds,
            maxAttempts: executionPolicy.maxAttempts)
        return PreparedDelegatedTask(
            contract: contract,
            capabilityLease: capabilityLease,
            workspaceLease: workspaceLease)
    }

    @discardableResult
    private func createDefaultLeases(for agent: Agent) -> (capability: CapabilityLease, workspace: WorkspaceLease) {
        let leases = prepareDefaultLeases(for: agent)
        commitDefaultLeases(leases, for: agent.name)
        return leases
    }

    private func prepareDefaultLeases(
        for agent: Agent,
        workspaceAccess: WorkspaceAccess = .readWrite,
        grantWorkerWriteCapabilities: Bool = false
    ) -> (capability: CapabilityLease, workspace: WorkspaceLease) {
        let workspaceLease = WorkspaceLease(rootPath: agent.workspaceRoot.path, access: workspaceAccess)
        var capabilityLease: CapabilityLease = agent.coordinationDepth > 0
            ? .coordinator(workspaceAccess: workspaceAccess)
            : .worker(workspaceAccess: grantWorkerWriteCapabilities ? workspaceAccess : .readOnly)
        if let augmenter = internalToolRegistryAugmenter,
           agent.name == Self.mainAgentID {
            capabilityLease.tools.formUnion(
                augmenter.additionalCapabilities)
        }
        if agent.name == Self.mainAgentID {
            capabilityLease.tools.insert(.renameSession)
            capabilityLease.tools.insert(.submitGoalVerdict)
            capabilityLease.tools.insert(.controlRun)
        } else {
            capabilityLease.tools.remove(.submitGoalVerdict)
            capabilityLease.tools.remove(.renameSession)
            capabilityLease.tools.remove(.controlRun)
        }
        capabilityLease.expiresAtTaskCompletion = false
        return (capabilityLease, workspaceLease)
    }

    /// Tool-spawned agents receive a monotonic derivation of the caller's
    /// authority. In particular, a child coordinator never receives a fresh
    /// default delegation depth or a tool/communication grant absent from its
    /// parent lease.
    private func prepareSpawnLeases(
        for agent: Agent,
        parentCapabilityLease: CapabilityLease,
        parentWorkspaceLease: WorkspaceLease,
        workspaceAccess: WorkspaceAccess,
        canCoordinate: Bool
    ) -> (capability: CapabilityLease, workspace: WorkspaceLease) {
        let workspaceLease = WorkspaceLease(
            rootPath: agent.workspaceRoot.path,
            access: workspaceAccess,
            allowedPathRules: parentWorkspaceLease.allowedPathRules,
            deniedPatterns: parentWorkspaceLease.deniedPatterns,
            expiresAtTaskCompletion: false)

        let baseline = canCoordinate
            ? CapabilityLease.coordinator(workspaceAccess: workspaceAccess)
            : CapabilityLease.worker(
                workspaceAccess: workspaceAccess == .readWrite ? .readWrite : .readOnly)
        let baselineTools = baseline.tools
        var tools = baselineTools.intersection(parentCapabilityLease.tools)
        tools.remove(.submitGoalVerdict)
        tools.remove(.renameSession)
        tools.remove(.controlRun)

        let communication: CommunicationGrant
        if canCoordinate {
            communication = parentCapabilityLease.communication
        } else {
            switch parentCapabilityLease.communication {
            case .none:
                communication = .none
            default:
                communication = .replyOnly
            }
        }

        let delegation: DelegationGrant
        if canCoordinate,
           case .granted(let parentBudget) = parentCapabilityLease.delegation {
            delegation = .granted(DelegationBudget(
                maxTasks: max(0, parentBudget.maxTasks - 1),
                maxDepth: max(0, parentBudget.maxDepth - 1)))
        } else {
            delegation = .none
        }

        let capabilityLease = CapabilityLease(
            tools: tools,
            communication: communication,
            delegation: delegation,
            expiresAtTaskCompletion: false)
        return (capabilityLease, workspaceLease)
    }

    private func commitDefaultLeases(
        _ leases: (capability: CapabilityLease, workspace: WorkspaceLease),
        for agent: AgentID
    ) {
        workspaceLeases[leases.workspace.id] = leases.workspace
        defaultWorkspaceLeaseIDs[agent] = leases.workspace.id
        capabilityLeases[leases.capability.id] = leases.capability
        defaultCapabilityLeaseIDs[agent] = leases.capability.id
    }

    private func workspaceLeaseForTask(agent: Agent,
                                       taskID: TaskID,
                                       access: WorkspaceAccess,
                                       store: Bool = true) -> WorkspaceLease {
        if let leaseID = defaultWorkspaceLeaseIDs[agent.name],
           let defaultLease = workspaceLeases[leaseID] {
            var taskLease = WorkspaceLease(
                workspaceID: defaultLease.workspaceID,
                taskID: taskID,
                rootPath: defaultLease.rootPath,
                rootIdentity: defaultLease.rootIdentity,
                access: access,
                allowedPathRules: defaultLease.allowedPathRules,
                deniedPatterns: defaultLease.deniedPatterns,
                expiresAtTaskCompletion: true)
            // `WorkspaceLease.init` captures when passed nil for new grants;
            // derivation must preserve a legacy/missing identity as nil so the
            // execution boundary fails closed instead of blessing a swapped root.
            taskLease.rootIdentity = defaultLease.rootIdentity
            if store {
                workspaceLeases[taskLease.id] = taskLease
            }
            return taskLease
        }

        var taskLease = WorkspaceLease(
            taskID: taskID,
            rootPath: agent.workspaceRoot.path,
            access: access,
            expiresAtTaskCompletion: true)
        taskLease.rootIdentity = nil
        if store {
            workspaceLeases[taskLease.id] = taskLease
        }
        return taskLease
    }

    private func capabilityLease(for agent: Agent,
                                 taskContract: TaskContract?) throws -> CapabilityLease {
        if let taskContract {
            guard let leaseID = taskContract.capabilityLeaseID else {
                throw CoworkTaskExecutionError.invalidLease(
                    "task \(taskContract.id.rawValue) has no capability lease")
            }
            guard let lease = capabilityLeases[leaseID] else {
                throw CoworkTaskExecutionError.invalidLease(
                    "capability lease \(leaseID.rawValue) is missing or revoked")
            }
            if let boundTaskID = lease.taskID,
               boundTaskID != taskContract.id {
                throw CoworkTaskExecutionError.invalidLease(
                    "capability lease belongs to task \(boundTaskID.rawValue)")
            }
            return Self.mainScopedCapabilityLease(lease, for: agent.name)
        }
        if let leaseID = defaultCapabilityLeaseIDs[agent.name],
           let lease = capabilityLeases[leaseID] {
            return Self.mainScopedCapabilityLease(lease, for: agent.name)
        }
        var lease = CapabilityLease.worker()
        if let augmenter = internalToolRegistryAugmenter,
           agent.name == Self.mainAgentID {
            lease.tools.formUnion(
                augmenter.additionalCapabilities)
        }
        lease.expiresAtTaskCompletion = false
        capabilityLeases[lease.id] = lease
        defaultCapabilityLeaseIDs[agent.name] = lease.id
        return lease
    }

    private static func mainScopedCapabilityLease(_ lease: CapabilityLease,
                                                  for agentID: AgentID) -> CapabilityLease {
        guard agentID != mainAgentID else { return lease }
        var scoped = lease
        scoped.tools.remove(.submitGoalVerdict)
        scoped.tools.remove(.renameSession)
        scoped.tools.remove(.controlRun)
        return scoped
    }

    private func workspaceLease(for agent: Agent,
                                taskContract: TaskContract?) throws -> WorkspaceLease? {
        if let taskContract {
            guard let leaseID = taskContract.workspaceLeaseID else {
                throw CoworkTaskExecutionError.invalidLease(
                    "task \(taskContract.id.rawValue) has no workspace lease")
            }
            guard let lease = workspaceLeases[leaseID] else {
                throw CoworkTaskExecutionError.invalidLease(
                    "workspace lease \(leaseID.rawValue) is missing or revoked")
            }
            if let boundTaskID = lease.taskID,
               boundTaskID != taskContract.id {
                throw CoworkTaskExecutionError.invalidLease(
                    "workspace lease belongs to task \(boundTaskID.rawValue)")
            }
            if let workspaceID = taskContract.workspaceID,
               workspaceID != lease.workspaceID {
                throw CoworkTaskExecutionError.invalidLease(
                    "workspace lease does not match the task workspace")
            }
            guard let rootIdentity = lease.rootIdentity else {
                throw CoworkTaskExecutionError.invalidLease(
                    "workspace lease has no reviewed root identity")
            }
            guard rootIdentity.matchesCurrentDirectory(rootPath: lease.rootPath) else {
                throw CoworkTaskExecutionError.invalidLease(
                    "workspace root identity changed after the lease was granted")
            }
            return lease
        }
        if let leaseID = defaultWorkspaceLeaseIDs[agent.name],
           let lease = workspaceLeases[leaseID] {
            guard let rootIdentity = lease.rootIdentity else {
                throw CoworkTaskExecutionError.invalidLease(
                    "default workspace lease has no reviewed root identity")
            }
            guard rootIdentity.matchesCurrentDirectory(rootPath: lease.rootPath) else {
                throw CoworkTaskExecutionError.invalidLease(
                    "default workspace root identity changed after the lease was granted")
            }
            return lease
        }
        return nil
    }

    private func existingCapabilityLease(for agentID: AgentID, taskID: TaskID?) -> CapabilityLease? {
        if let taskID {
            guard let node = taskGraph.node(taskID), node.assignee == agentID else { return nil }
            let contract = node.contract
            guard let leaseID = contract.capabilityLeaseID,
                  let lease = capabilityLeases[leaseID],
                  lease.taskID == nil || lease.taskID == taskID else { return nil }
            return lease
        }
        if let leaseID = defaultCapabilityLeaseIDs[agentID] {
            return capabilityLeases[leaseID]
        }
        return nil
    }

    private func existingWorkspaceLease(for agentID: AgentID,
                                        taskID: TaskID?) -> WorkspaceLease? {
        if let taskID {
            guard let node = taskGraph.node(taskID), node.assignee == agentID else { return nil }
            let contract = node.contract
            guard let leaseID = contract.workspaceLeaseID,
                  let lease = workspaceLeases[leaseID],
                  lease.taskID == nil || lease.taskID == taskID else { return nil }
            return lease
        }
        if let leaseID = defaultWorkspaceLeaseIDs[agentID] {
            return workspaceLeases[leaseID]
        }
        return nil
    }

    private func delegationFailure(from: AgentID,
                                   to: AgentID,
                                   parentTaskID: TaskID?) -> String? {
        guard from != to else { return "agent cannot delegate to itself" }
        guard let lease = existingCapabilityLease(for: from, taskID: parentTaskID) else {
            return "delegation lease unavailable"
        }
        guard lease.tools.contains(.delegateTask) else {
            return "delegation tool capability is not granted for the current task"
        }
        guard case .granted(let budget) = lease.delegation else {
            return "delegation is not granted for the current task"
        }
        let issuedCount = taskGraph.nodes.values.filter { node in
            node.issuer == from && node.parentTaskID == parentTaskID
        }.count
        guard issuedCount < budget.maxTasks else {
            return "delegation task budget exhausted (\(budget.maxTasks))"
        }
        let relativeDepth: Int
        if let leaseTaskID = lease.taskID,
           let parentTaskID {
            relativeDepth = max(1, taskGraph.depth(of: parentTaskID) - taskGraph.depth(of: leaseTaskID) + 1)
        } else {
            relativeDepth = 1
        }
        guard relativeDepth <= budget.maxDepth else {
            return "delegation depth budget exhausted (\(budget.maxDepth))"
        }
        return nil
    }

    private func communicationFailure(from: AgentID,
                                      to: AgentID,
                                      taskID: TaskID?,
                                      operation: CommunicationOperation) -> String? {
        guard let lease = existingCapabilityLease(for: from, taskID: taskID) else {
            return "communication lease unavailable"
        }
        let requiredCapability: ToolCapability
        switch operation {
        case .send:
            requiredCapability = .sendMessage
        case .requestInformation:
            requiredCapability = .requestInformation
        case .reply:
            requiredCapability = .replyMessage
        }
        guard lease.tools.contains(requiredCapability) else {
            return "communication tool capability is not granted for the current task"
        }
        switch lease.communication {
        case .none:
            return "communication is not granted for the current task"
        case .replyOnly:
            guard operation == .reply else {
                return "the current lease allows replies only"
            }
            guard let taskID,
                  let issuer = taskGraph.node(taskID)?.issuer else {
                return "reply-only communication requires an assigning task"
            }
            if issuer != to {
                return "reply-only lease may only contact the assigning agent"
            }
            return nil
        case .selectedAgents(let agents):
            return agents.contains(to) ? nil : "target agent is outside the communication lease"
        case .taskGroup:
            guard let taskID,
                  let rootTaskID = taskGraph.node(taskID)?.rootTaskID,
                  taskGraph.nodes.values.contains(where: { $0.rootTaskID == rootTaskID && $0.assignee == to }) else {
                return "target agent is outside the task group"
            }
            return nil
        case .anyAgentInThread:
            return nil
        }
    }

    private func taskMetadata(contract: TaskContract,
                              rootTaskID: TaskID? = nil,
                              parentTaskID: TaskID? = nil,
                              sender: AgentID? = nil,
                              recipient: AgentID? = nil,
                              scope: CoworkEventScope = .task,
                              visibility: CoworkEventVisibility = .task) -> CoworkEventMetadata {
        CoworkEventMetadata(
            taskID: contract.id,
            rootTaskID: rootTaskID,
            parentTaskID: parentTaskID ?? contract.parentTaskID,
            sender: sender,
            recipient: recipient,
            agentID: contract.assignee,
            issuer: contract.issuer,
            assignee: contract.assignee,
            workspaceID: contract.workspaceID,
            workspaceLeaseID: contract.workspaceLeaseID,
            capabilityLeaseID: contract.capabilityLeaseID,
            causalParentID: parentTaskID ?? contract.parentTaskID,
            scope: scope,
            visibility: visibility)
    }

    @discardableResult
    func runNextScheduledTask() async -> Bool {
        let excludedTaskIDs = terminalCommitTaskIDs
            .union(Set(terminalPersistenceFailures.keys))
            .union(restoredPendingTaskIDs)
        guard let task = scheduler.claimNext(excluding: excludedTaskIDs) else { return false }
        let execution = launchClaimedTask(task)
        await execution.value
        return true
    }

    private func launchClaimedTask(_ task: ScheduledTask) -> Task<Void, Never> {
        if let existing = runningExecutions[task.contract.id] {
            return existing
        }
        let execution = Task {
            await self.executeClaimedTask(task)
        }
        runningExecutions[task.contract.id] = execution
        return execution
    }

    private func ensureSchedulerRunning() {
        guard !schedulerSuspended else { return }
        let concurrencyLimit = max(1, executionPolicy.maxConcurrentTasks)
        let excludedTaskIDs = terminalCommitTaskIDs
            .union(Set(terminalPersistenceFailures.keys))
            .union(restoredPendingTaskIDs)
        while runningExecutions.count < concurrencyLimit,
              let task = scheduler.claimNext(excluding: excludedTaskIDs) {
            _ = launchClaimedTask(task)
        }
        notifyIdleIfNeeded()
    }

    private func executeClaimedTask(_ task: ScheduledTask) async {
        let taskID = task.contract.id
        let metadata = taskMetadata(
            contract: task.contract,
            rootTaskID: task.rootTaskID,
            parentTaskID: task.parentTaskID,
            sender: task.issuer,
            recipient: task.assignee)
        if let taskStartGate {
            await taskStartGate(taskID)
        }
        guard scheduler.record(for: taskID)?.status == .queued else {
            executionDidFinish(taskID)
            return
        }
        guard !terminalCommitTaskIDs.contains(taskID) else {
            runningExecutions.removeValue(forKey: taskID)
            return
        }
        // A Goal/run tombstone remains an execution-time fence if a prior
        // durable cancellation failed and left the task queued. Unrelated
        // scheduler wakes must never dispatch that task to its provider.
        if isGoalRunCancellationRequested(
            goalID: task.contract.goalID,
            continuationRunID: task.contract.continuationRunID) {
            let closeSource = task.contract.continuationRunID
                .flatMap { continuationRunCloseClaims[$0]?.source }
                ?? .user
            _ = await cancelBeforeExecution(
                task,
                reason: "Goal continuation cancellation is pending",
                runCloseSource: closeSource,
                wasClaimed: true)
            executionDidFinish(taskID)
            return
        }
        do {
            try await appendTaskLifecycleEvent(.taskStarted(TaskStartedPayload(
                taskID: taskID,
                agent: task.assignee,
                attempt: task.attempt,
                metadata: metadata)))
        } catch {
            if terminalCommitTaskIDs.contains(taskID)
                || scheduler.record(for: taskID)?.status.isTerminal == true {
                runningExecutions.removeValue(forKey: taskID)
                return
            }
            await finishFailedTask(
                task,
                message: "Task start could not be persisted: \(error.localizedDescription)",
                metadata: metadata)
            executionDidFinish(taskID)
            return
        }
        // `appendTaskLifecycleEvent` is an actor reentrancy point. A scoped
        // cancellation may have installed a Goal/run tombstone and attempted
        // to cancel this still-queued claim while `taskStarted` was being
        // persisted. Revalidate every execution fence before committing the
        // scheduler transition: even a failed `taskCancelled` persistence
        // attempt must never allow the original claim to reach its provider.
        guard scheduler.record(for: taskID)?.status == .queued,
              !terminalCommitTaskIDs.contains(taskID),
              terminalPersistenceFailures[taskID] == nil,
              !isGoalRunCancellationRequested(
                goalID: task.contract.goalID,
                continuationRunID: task.contract.continuationRunID) else {
            executionDidFinish(taskID)
            return
        }
        guard scheduler.recordStarted(task: task) else {
            if scheduler.record(for: taskID)?.status.isTerminal != true {
                await finishFailedTask(
                    task,
                    message: "durable task start could not be committed to scheduler state",
                    metadata: metadata)
            }
            executionDidFinish(taskID)
            return
        }
        guard taskGraph.updateStatus(taskID: taskID, status: .running) else {
            let metadata = taskMetadata(
                contract: task.contract,
                rootTaskID: task.rootTaskID,
                parentTaskID: task.parentTaskID,
                sender: task.issuer,
                recipient: task.assignee)
            await finishFailedTask(
                task,
                message: "invalid task state transition to running",
                metadata: metadata)
            executionDidFinish(taskID)
            return
        }

        var completedSuccessfully = false

        if let limit = executionPolicy.tokenBudget,
           consumedTokenCount >= limit {
            await finishFailedTask(
                task,
                message: CoworkTaskExecutionError.tokenBudgetExhausted(limit: limit).localizedDescription,
                metadata: metadata)
            executionDidFinish(taskID)
            return
        }

        guard let agent = registry.agent(task.assignee) else {
            let message = "scheduled task assignee is not attached: @\(task.assignee.rawValue)"
            await finishFailedTask(task, message: message, metadata: metadata)
            executionDidFinish(taskID)
            return
        }

        let invocation = rootInvocations[taskID]
        let timeout = task.contract.executionTimeoutSeconds ?? executionPolicy.taskTimeoutSeconds
        do {
            let runResult = try await withTaskTimeout(seconds: timeout) { [self] in
                try await run(
                    agent,
                    input: task.input,
                    images: invocation?.images ?? [],
                    userMessage: invocation?.userMessage,
                    recordUserMessage: invocation?.recordUserMessage
                        ?? (task.contract.submissionID == nil),
                    taskContract: task.contract,
                    rootTaskID: task.rootTaskID,
                    taskAttempt: task.attempt)
            }
            let result = runResult.output
            try Task.checkCancellation()
            if let cancellationReason = cancellationReasons[taskID] {
                throw CoworkTaskExecutionError.cancelled(cancellationReason)
            }
            completedSuccessfully = await finishCompletedTask(
                task,
                result: result,
                presentedMessageIDs: Set(runResult.presentedMessageIDs),
                metadata: metadata)
        } catch {
            // A provider is allowed to report CancellationError as its own
            // runtime failure. It is a task cancellation only when this exact
            // scheduler execution was cancelled or an explicit reason was
            // installed by the cancellation path.
            if Task.isCancelled
                || cancellationReasons[taskID] != nil
                || error is AgentTurnInterruptedError {
                let reason = cancellationReasons[taskID]
                    ?? (error as? AgentTurnInterruptedError)?.reason
                    ?? "execution cancelled"
                await finishCancelledTask(task, reason: reason, metadata: metadata)
            } else {
                let usageLimit = error as? ProviderUsageLimitError
                let durableMessage = RuntimeErrorPresentation.message(for: error)
                let runCloseOutcome: ContinuationRunCloseOutcome
                switch error as? CoworkTaskExecutionError {
                case .timedOut?:
                    runCloseOutcome = .timedOut
                default:
                    runCloseOutcome = .failed
                }
                let failurePersisted = await finishFailedTask(
                    task,
                    message: durableMessage,
                    metadata: metadata,
                    failureCode: usageLimit == nil ? nil : .providerUsageLimit,
                    runCloseOutcome: runCloseOutcome)
                if failurePersisted,
                   usageLimit != nil,
                   let goalID = task.contract.goalID,
                   let runID = task.contract.continuationRunID {
                    providerUsageLimitFailures[runID] = (
                        goalID,
                        durableMessage)
                }
            }
        }
        executionDidFinish(taskID, resumeScheduler: false)
        if completedSuccessfully {
            await enqueuePendingMailboxWakeIfNeeded(for: task.assignee, fallbackSender: task.issuer)
        } else if task.contract.kind == .mailboxDelivery,
                  scheduler.record(for: taskID)?.status == .failed {
            if await shouldAutomaticallyRetryMailboxTask(task) {
                _ = await admitRetry(taskID: taskID, reason: "automatic mailbox delivery retry")
            } else {
                // An exhausted or quarantined poison message must not prevent
                // a later, unrelated pending MessageID from receiving its own
                // bounded delivery task.
                await enqueuePendingMailboxWakeIfNeeded(
                    for: task.assignee,
                    fallbackSender: task.issuer)
            }
        }
        ensureSchedulerRunning()
        notifyIdleIfNeeded()
    }

    public func runSchedulerUntilIdle() async {
        ensureSchedulerRunning()
        if !hasRunnableScheduledWork() {
            await recycleIdleToolSpawnedAgents(reason: "scheduled tasks drained; auto-recycled idle tool-spawned agent")
            return
        }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
        await recycleIdleToolSpawnedAgents(reason: "scheduled tasks drained; auto-recycled idle tool-spawned agent")
    }

    /// Waits only for invocations owned by one Goal/run scope. Unrelated
    /// Cowork work cannot hold a Goal verifier barrier open indefinitely.
    public func runSchedulerUntilIdle(goalID: GoalID,
                                      continuationRunID: ContinuationRunID? = nil) async {
        ensureSchedulerRunning()
        while hasScheduledWork(goalID: goalID, continuationRunID: continuationRunID) {
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(nanoseconds: 20_000_000)
            } catch {
                return
            }
        }
    }

    /// Returns the structured provider/account hard-limit signal observed by
    /// this run, or an earlier unsettled run of the same Goal. The durable
    /// atomic Goal/run settlement consumes it only after persistence succeeds;
    /// no free-form error text is classified here.
    func consumeProviderUsageLimitFailure(goalID: GoalID,
                                          continuationRunID: ContinuationRunID) -> String? {
        if let failure = providerUsageLimitFailures[continuationRunID],
           failure.0 == goalID {
            return failure.1
        }
        return providerUsageLimitFailures
            .filter { $0.value.0 == goalID }
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .first?.value.1
    }

    private func hasScheduledWork(goalID: GoalID,
                                  continuationRunID: ContinuationRunID?) -> Bool {
        let snapshot = scheduler.snapshot()
        if (snapshot.queuedTasks + snapshot.claimedTasks).contains(where: {
            terminalPersistenceFailures[$0.contract.id] == nil
                &&
            Self.matchesScope(
                $0.contract,
                goalID: goalID,
                continuationRunID: continuationRunID)
        }) {
            return true
        }
        return runningExecutions.keys.contains { taskID in
            guard let task = snapshot.knownTasks[taskID] else { return false }
            return Self.matchesScope(
                task.contract,
                goalID: goalID,
                continuationRunID: continuationRunID)
        }
    }

    private func scopedScheduledTaskIDs(
        goalID: GoalID,
        continuationRunID: ContinuationRunID?
    ) -> [TaskID] {
        let snapshot = scheduler.snapshot()
        var seen = Set<TaskID>()
        var ordered: [TaskID] = []
        for task in snapshot.queuedTasks + snapshot.claimedTasks
        where Self.matchesScope(
            task.contract,
            goalID: goalID,
            continuationRunID: continuationRunID) {
            if seen.insert(task.contract.id).inserted {
                ordered.append(task.contract.id)
            }
        }
        for taskID in runningExecutions.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let task = snapshot.knownTasks[taskID],
                  Self.matchesScope(
                    task.contract,
                    goalID: goalID,
                    continuationRunID: continuationRunID),
                  seen.insert(taskID).inserted else { continue }
            ordered.append(taskID)
        }
        return ordered
    }

    private static func matchesScope(_ contract: TaskContract,
                                     goalID: GoalID,
                                     continuationRunID: ContinuationRunID?) -> Bool {
        guard contract.goalID == goalID else { return false }
        return continuationRunID == nil || contract.continuationRunID == continuationRunID
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private static func normalizedGoalBlocker(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func finishCompletedTask(_ task: ScheduledTask,
                                     result: String,
                                     presentedMessageIDs: Set<MessageID>,
                                     metadata: CoworkEventMetadata) async -> Bool {
        await terminal.terminate(
            taskID: task.contract.id,
            reason: "task completed")
        let consumptions = deliveredMessageConsumptions(
            for: task,
            presentedMessageIDs: presentedMessageIDs)
        let report = Self.makeTaskReport(
            task: task,
            status: .completed,
            result: result,
            attempt: task.attempt)
        let lifecycleEvent = Event.taskCompleted(TaskCompletedPayload(
                taskID: task.contract.id,
                agent: task.assignee,
                result: result,
                report: report,
                attempt: task.attempt,
                metadata: metadata))
        do {
            if !consumptions.isEmpty,
               let messageConsumptionPreflightForTesting {
                try await messageConsumptionPreflightForTesting(
                    consumptions.map(\.payload))
            }
            try await persistInvocationSettlement(
                lifecycleEvent,
                additionalEvents: consumptions.map {
                    .agentMessageConsumed($0.payload)
                })
        } catch {
            let message = "Task completion could not be persisted: \(error.localizedDescription)"
            _ = await finishFailedTask(task, message: message, metadata: metadata)
            return false
        }

        terminalPersistenceFailures.removeValue(forKey: task.contract.id)
        acknowledgeDeliveredMessages(consumptions, recipient: task.assignee)
        await storeScheduledReply(task: task, result: result, report: report, error: nil)
        // Publish the terminal scheduler record only after the typed reply
        // delivery outcome exists. Otherwise an actor-reentrant late waiter can
        // observe `record.result` while Mediator delivery is still pending and
        // incorrectly turn a later block into ask_agent success.
        scheduler.recordCompleted(task: task, result: result)
        _ = taskGraph.updateStatus(taskID: task.contract.id, status: .completed)
        await revokeTaskLeases(contract: task.contract, reason: "task completed")
        await refreshConsumedTokenCount()
        completeResultWaiters(task.contract.id)
        await recycleToolSpawnedAgentIfIdle(
            task.assignee,
            reason: "task \(task.contract.id.rawValue) completed; auto-recycled tool-spawned agent")
        return true
    }

    @discardableResult
    private func finishFailedTask(_ task: ScheduledTask,
                                  message: String,
                                  metadata: CoworkEventMetadata,
                                  failureCode: TaskFailureCode? = nil,
                                  runCloseOutcome: ContinuationRunCloseOutcome = .failed) async -> Bool {
        do {
            _ = try await closeRootRunIfNeeded(
                for: task,
                outcome: runCloseOutcome,
                source: .runtime,
                reason: message)
        } catch {
            await recordTerminalPersistenceFailure(task: task, error: error)
            return false
        }
        await terminal.terminate(
            taskID: task.contract.id,
            reason: "task failed")
        let report = Self.makeTaskReport(
            task: task,
            status: .failed,
            error: message,
            attempt: task.attempt)
        let lifecycleEvent = Event.taskFailed(TaskFailedPayload(
                taskID: task.contract.id,
                agent: task.assignee,
                error: message,
                failureCode: failureCode,
                report: report,
                attempt: task.attempt,
                metadata: metadata))
        do {
            try await persistInvocationSettlement(
                lifecycleEvent)
        } catch {
            await recordTerminalPersistenceFailure(task: task, error: error)
            return false
        }

        terminalPersistenceFailures.removeValue(forKey: task.contract.id)
        await storeScheduledReply(task: task, result: nil, report: report, error: message)
        scheduler.recordFailed(task: task, error: message)
        commitFailedTaskGraphState(taskID: task.contract.id)
        await revokeTaskLeases(contract: task.contract, reason: "task failed")
        await refreshConsumedTokenCount()
        completeResultWaiters(task.contract.id)
        return true
    }

    private func commitFailedTaskGraphState(taskID: TaskID) {
        if taskGraph.updateStatus(taskID: taskID, status: .failed) { return }
        guard let status = taskGraph.node(taskID)?.status,
              !status.isTerminal else { return }
        if status == .created {
            _ = taskGraph.updateStatus(taskID: taskID, status: .assigned)
        }
        if taskGraph.node(taskID)?.status == .assigned {
            _ = taskGraph.updateStatus(taskID: taskID, status: .queued)
        }
        if taskGraph.node(taskID)?.status == .queued {
            _ = taskGraph.updateStatus(taskID: taskID, status: .running)
        }
        _ = taskGraph.updateStatus(taskID: taskID, status: .failed)
    }

    @discardableResult
    private func finishCancelledTask(_ task: ScheduledTask,
                                     reason: String,
                                     metadata: CoworkEventMetadata) async -> Bool {
        let runCloseSource = cancellationRunCloseSources[task.contract.id] ?? .runtime
        do {
            _ = try await closeRootRunIfNeeded(
                for: task,
                outcome: Self.cancellationRunOutcome(source: runCloseSource),
                source: runCloseSource,
                reason: reason)
        } catch {
            await recordTerminalPersistenceFailure(task: task, error: error)
            return false
        }
        await terminal.terminate(
            taskID: task.contract.id,
            reason: reason)
        let report = Self.makeTaskReport(
            task: task,
            status: .cancelled,
            error: reason,
            attempt: task.attempt)
        let lifecycleEvent = Event.taskCancelled(TaskCancelledPayload(
                taskID: task.contract.id,
                agent: task.assignee,
                reason: reason,
                report: report,
                attempt: task.attempt,
                metadata: metadata))
        do {
            try await persistInvocationSettlement(
                lifecycleEvent)
        } catch {
            await recordTerminalPersistenceFailure(task: task, error: error)
            return false
        }

        terminalPersistenceFailures.removeValue(forKey: task.contract.id)
        await storeScheduledReply(task: task, result: nil, report: report, error: reason)
        scheduler.recordCancelled(task: task, reason: reason)
        _ = taskGraph.updateStatus(taskID: task.contract.id, status: .cancelled)
        await revokeTaskLeases(contract: task.contract, reason: "task cancelled")
        await refreshConsumedTokenCount()
        completeResultWaiters(task.contract.id)
        return true
    }

    private func appendTaskLifecycleEvent(_ event: Event) async throws {
        if let taskLifecycleEventAppender {
            try await taskLifecycleEventAppender(event)
        } else {
            try await log.append(event)
        }
    }

    private func appendTaskLifecycleEvents(_ events: [Event]) async throws {
        guard !events.isEmpty else { return }
        if let taskLifecycleEventAppender {
            for event in events {
                try await taskLifecycleEventAppender(event)
            }
        } else {
            try await log.append(events)
        }
    }

    /// Persists execution settlement without mutating the independently
    /// managed WorkTask bound to the invocation.
    private func persistInvocationSettlement(
        _ lifecycleEvent: Event,
        additionalEvents: [Event] = []
    ) async throws {
        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }

        var events = [lifecycleEvent]
        events.append(contentsOf: additionalEvents)
        try await appendTaskLifecycleEvents(events)
    }

    /// Closes an already-durable attach request after its exact inference
    /// authorization becomes stale. Failure to persist this denial remains
    /// fail-closed: the caller never commits leases or adds the agent.
    private func persistAttachAuthorizationRevalidationDenial(
        requestID: RequestID,
        proposedAgent: Agent,
        assessedPath: String,
        reason: String,
        risk: RiskLevel,
        intent: PermissionIntent,
        authorization: ResolvedToolAuthorization,
        workspaceMetadata: CoworkEventMetadata,
        reviewResolution: PermissionApprovalResolution
    ) async {
        do {
            try await appendAdmissionEvents([
                .permissionResolved(PermissionResolvedPayload(
                    requestId: requestID,
                    tool: "agent.attach",
                    decision: .deny,
                    risk: risk,
                    reason: reason,
                    intent: intent,
                    authorization: authorization,
                    source: .authorizationRevalidation,
                    reviewTaskID: reviewResolution.reviewTaskID,
                    reviewStatus: reviewResolution.reviewStatus,
                    failureKind: .authorizationSnapshotInvalid)),
                .workspaceLeaseDenied(WorkspaceLeaseDeniedPayload(
                    agent: proposedAgent.name,
                    rootPath: assessedPath,
                    reason: reason,
                    metadata: workspaceMetadata)),
            ])
        } catch {
            try? await log.append(.error(ErrorPayload(
                code: "agent_attach_authorization_denial_persistence_failed",
                message: error.localizedDescription)))
        }
    }

    private func appendAdmissionEvent(_ event: Event) async throws {
        if let admissionEventAppender {
            try await admissionEventAppender(event)
        } else {
            try await log.append(event)
            if Self.affectsSessionProjection(event) {
                _ = try? await SessionProjectionStore.refresh(from: log)
            }
        }
    }

    private func appendAdmissionEvents(_ events: [Event]) async throws {
        guard !events.isEmpty else { return }
        if let admissionEventsAppender {
            try await admissionEventsAppender(events)
        } else {
            // The real EventLog holds one cross-process lock for the entire
            // admission/revoke transaction. Do not fall back to the per-event
            // test seam here: doing so would make failure injection capable of
            // producing a state that production explicitly forbids.
            try await log.append(events)
            if events.contains(where: Self.affectsSessionProjection) {
                _ = try? await SessionProjectionStore.refresh(from: log)
            }
        }
    }

    private func appendFreshSessionAdmissionEventsIfEmpty(_ events: [Event]) async throws -> Bool {
        guard !events.isEmpty else { return true }
        if let admissionEventsAppender {
            // Test seams are required to emulate an all-or-nothing successful
            // fresh admission. Cross-instance empty-log races are covered by
            // the production EventLog primitive directly.
            try await admissionEventsAppender(events)
            return true
        }
        guard try await log.appendIfEmptyChecked(events) != nil else {
            return false
        }
        if events.contains(where: Self.affectsSessionProjection) {
            _ = try? await SessionProjectionStore.refresh(from: log)
        }
        return true
    }

    private static func affectsSessionProjection(_ event: Event) -> Bool {
        switch event {
        case .sessionSettingsUpdated, .sessionStorageMigrated,
             .agentAttached, .agentDetached,
             .workspaceLeaseGranted, .workspaceLeaseRevoked,
             .capabilityLeaseCreated, .capabilityLeaseRevoked:
            return true
        default:
            return false
        }
    }

    private func persistUncommittedAdmissionCancellation(
        task: ScheduledTask,
        reason: String,
        metadata: CoworkEventMetadata
    ) async {
        let report = Self.makeTaskReport(
            task: task,
            status: .cancelled,
            error: reason,
            attempt: task.attempt)
        try? await appendTaskLifecycleEvent(.taskCancelled(TaskCancelledPayload(
            taskID: task.contract.id,
            agent: task.assignee,
            reason: reason,
            report: report,
            attempt: task.attempt,
            metadata: metadata)))
    }

    @discardableResult
    private func cancelUnqueuedRootTask(_ task: ScheduledTask,
                                        reason: String,
                                        runCloseSource: ContinuationRunCloseSource? = nil) async -> Bool {
        if let runCloseSource {
            do {
                _ = try await closeRootRunIfNeeded(
                    for: task,
                    outcome: Self.cancellationRunOutcome(source: runCloseSource),
                    source: runCloseSource,
                    reason: reason)
            } catch {
                terminalPersistenceFailures[task.contract.id] =
                    "Run closure could not be persisted before root task cancellation: \(error.localizedDescription)"
                completeResultWaiters(task.contract.id)
                return false
            }
        }
        let metadata = taskMetadata(
            contract: task.contract,
            rootTaskID: task.rootTaskID,
            parentTaskID: task.parentTaskID,
            sender: task.issuer,
            recipient: task.assignee)
        let report = Self.makeTaskReport(
            task: task,
            status: .cancelled,
            error: reason,
            attempt: task.attempt)
        do {
            try await appendTaskLifecycleEvent(.taskCancelled(TaskCancelledPayload(
                taskID: task.contract.id,
                agent: task.assignee,
                reason: reason,
                report: report,
                attempt: task.attempt,
                metadata: metadata)))
        } catch {
            terminalPersistenceFailures[task.contract.id] =
                "Root task cancellation could not be persisted: \(error.localizedDescription)"
            completeResultWaiters(task.contract.id)
            return false
        }
        terminalPersistenceFailures.removeValue(forKey: task.contract.id)
        _ = taskGraph.updateStatus(taskID: task.contract.id, status: .cancelled)
        await revokeTaskLeases(contract: task.contract, reason: "task cancelled before queue admission")
        rootInvocations.removeValue(forKey: task.contract.id)
        completeResultWaiters(task.contract.id)
        return true
    }

    private static func cancellationRunOutcome(
        source: ContinuationRunCloseSource
    ) -> ContinuationRunCloseOutcome {
        switch source {
        case .runtime, .hostLifecycle:
            return .interrupted
        case .mainAgent, .user:
            return .cancelled
        }
    }

    private func scheduledTask(for node: TaskNode) -> ScheduledTask {
        let lineage = Self.uniqueAgents([node.issuer, node.assignee].compactMap { $0 })
        return ScheduledTask(
            contract: node.contract,
            input: node.contract.objective,
            rootTaskID: node.rootTaskID,
            parentTaskID: node.parentTaskID,
            issuer: node.issuer,
            assignee: node.assignee,
            causalParentID: node.parentTaskID,
            hopCount: max(0, taskGraph.depth(of: node.id)),
            visitedAgents: lineage,
            attempt: scheduler.record(for: node.id)?.attempt ?? 1)
    }

    private func isGoalRunCancellationRequested(
        goalID: GoalID?,
        continuationRunID: ContinuationRunID?
    ) -> Bool {
        if let continuationRunID,
           continuationRunCloseClaims[continuationRunID] != nil
            || (continuationRunCloseInstallations[continuationRunID] ?? 0) > 0 {
            return true
        }
        guard let goalID else { return false }
        if cancelledGoalRunScopes.contains(GoalRunCancellationScope(
            goalID: goalID,
            runID: nil)) {
            return true
        }
        guard let continuationRunID else { return false }
        return cancelledGoalRunScopes.contains(GoalRunCancellationScope(
            goalID: goalID,
            runID: continuationRunID))
    }

    private func acquireAdmissionLock() async {
        if !admissionLocked {
            admissionLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            admissionWaiters.append(continuation)
        }
    }

    private func releaseAdmissionLock() {
        if admissionWaiters.isEmpty {
            admissionLocked = false
        } else {
            admissionWaiters.removeFirst().resume()
        }
    }

    /// Internal observability for deterministic admission serialization tests.
    func admissionWaiterCountForTesting() -> Int {
        admissionWaiters.count
    }

    @discardableResult
    private func suspendScheduler() -> UUID {
        let token = UUID()
        schedulerSuspensionTokens.insert(token)
        return token
    }

    private func resumeScheduler(suspension token: UUID, ensureRunning: Bool) {
        guard schedulerSuspensionTokens.remove(token) != nil else { return }
        if ensureRunning {
            schedulerResumeRequested = true
        }
        guard schedulerSuspensionTokens.isEmpty else { return }
        let shouldEnsureRunning = schedulerResumeRequested
        schedulerResumeRequested = false
        if shouldEnsureRunning {
            ensureSchedulerRunning()
        }
    }

    private func acquireExecutionPolicyUpdateLock() async {
        if !executionPolicyUpdateLocked {
            executionPolicyUpdateLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            executionPolicyUpdateWaiters.append(continuation)
        }
    }

    private func releaseExecutionPolicyUpdateLock() {
        if executionPolicyUpdateWaiters.isEmpty {
            executionPolicyUpdateLocked = false
        } else {
            executionPolicyUpdateWaiters.removeFirst().resume()
        }
    }

    /// Internal observability for deterministic scheduler/budget regression
    /// tests. Production callers configure through `updateExecutionPolicy`.
    func isExecutionPolicyUpdateInProgress() -> Bool {
        executionPolicyUpdateInProgress
    }

    /// Internal visibility for regressions that must prove a timed-out detached
    /// AgentLoop cannot lose or duplicate its reservation across policy changes.
    func tokenBudgetSnapshotForTesting() async -> (
        limit: Int?,
        consumed: Int,
        reserved: Int,
        remaining: Int?
    ) {
        await tokenBudgetMeter.snapshot()
    }

    private func recordTerminalPersistenceFailure(task: ScheduledTask, error: Error) async {
        let message = "Task terminal state could not be persisted: \(error.localizedDescription)"
        try? await log.append(.error(ErrorPayload(
            code: "terminal_persistence_failed",
            message: "Task \(task.contract.id.rawValue): \(message)")))
        terminalPersistenceFailures[task.contract.id] = message
        _ = scheduler.releaseClaim(taskID: task.contract.id)
        completeResultWaiters(task.contract.id)
    }

    private func storeScheduledReply(task: ScheduledTask,
                                     result: String?,
                                     report: TaskReportPayload,
                                     error: String?) async {
        let explicitTarget = scheduledReplyTargets.removeValue(forKey: task.contract.id)
        let replyMode = task.contract.replyMode ?? .taskReport
        let replyTarget = explicitTarget ?? (replyMode == .none ? nil : task.contract.issuer)
        let explicitFormat = scheduledReplyFormats.removeValue(forKey: task.contract.id)
        guard let replyTarget else { return }
        let format = explicitFormat ?? (replyMode == .answer ? .answer : .taskReport)
        scheduledReplyResults[task.contract.id] = await deliverScheduledReply(
            format: format,
            from: task.assignee,
            to: replyTarget,
            result: result,
            report: report,
            error: error)
    }

    private func executionDidFinish(_ taskID: TaskID, resumeScheduler: Bool = true) {
        runningExecutions.removeValue(forKey: taskID)
        rootInvocations.removeValue(forKey: taskID)
        cancellationReasons.removeValue(forKey: taskID)
        cancellationRunCloseSources.removeValue(forKey: taskID)
        restoredPendingTaskIDs.remove(taskID)
        if resumeScheduler {
            ensureSchedulerRunning()
            notifyIdleIfNeeded()
        }
    }

    private func notifyIdleIfNeeded() {
        guard !hasRunnableScheduledWork() else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func hasRunnableScheduledWork() -> Bool {
        !runningExecutions.isEmpty
            || scheduler.queuedTasks().contains {
                terminalPersistenceFailures[$0.contract.id] == nil
                    && !restoredPendingTaskIDs.contains($0.contract.id)
            }
    }

    private func completeResultWaiters(_ taskID: TaskID) {
        guard let waiters = resultWaiters.removeValue(forKey: taskID) else { return }
        let value = terminalResult(for: taskID)
        for waiter in waiters { waiter.resume(returning: value) }
    }

    private func terminalResult(for taskID: TaskID) -> String? {
        if let failure = terminalPersistenceFailures[taskID] {
            return "error: \(failure)"
        }
        guard let record = scheduler.record(for: taskID), record.status.isTerminal else { return nil }
        return scheduledReplyResults[taskID].map { reply in
            switch reply {
            case .success(let value), .failure(let value): value
            }
        }
            ?? record.result
            ?? record.error.map { "error: \($0)" }
            ?? (record.status == .cancelled ? "error: task cancelled" : nil)
    }

    private func deliveredMessageConsumptions(
        for task: ScheduledTask,
        presentedMessageIDs: Set<MessageID>
    ) -> [(message: PendingAgentMessage, payload: AgentMessageConsumedPayload)] {
        let eligibleMessageIDs: Set<MessageID>
        if task.contract.kind == .mailboxDelivery,
           let frozenMessageIDs = task.contract.mailboxMessageIDs {
            eligibleMessageIDs = presentedMessageIDs.intersection(frozenMessageIDs)
        } else {
            eligibleMessageIDs = presentedMessageIDs
        }
        return scheduler.peekMessages(for: task.assignee).compactMap { message in
            guard eligibleMessageIDs.contains(message.id) else { return nil }
            return (message, AgentMessageConsumedPayload(
                messageID: message.id,
                agent: task.assignee,
                taskID: task.contract.id,
                metadata: CoworkEventMetadata(
                    taskID: task.contract.id,
                    rootTaskID: task.rootTaskID,
                    parentTaskID: task.parentTaskID,
                    sender: message.sender,
                    recipient: task.assignee,
                    agentID: task.assignee,
                    causalParentID: message.causalParentID,
                    scope: .agent,
                    visibility: .privateAgent)))
        }
    }

    private func acknowledgeDeliveredMessages(
        _ settlements: [(message: PendingAgentMessage, payload: AgentMessageConsumedPayload)],
        recipient: AgentID
    ) {
        for settlement in settlements {
            _ = scheduler.acknowledgeMessage(
                settlement.message.id,
                recipient: recipient)
        }
    }

    /// Settles stale mailbox entries when their owning Goal/run is cancelled.
    /// They were never successfully presented, so this uses the dedicated
    /// discard event rather than falsifying an `agent_message_consumed` audit.
    private func discardPendingMessages(goalID: GoalID,
                                        continuationRunID: ContinuationRunID?,
                                        reason: String) async -> Bool {
        var seen = Set<MessageID>()
        let messages = scheduler.snapshot().mailboxes.values
            .flatMap(\.pendingMessageDetails)
            .filter { message in
                guard seen.insert(message.id).inserted,
                      let causalTaskID = message.causalParentID ?? message.taskID,
                      let contract = taskGraph.node(causalTaskID)?.contract
                        ?? scheduler.knownTask(taskID: causalTaskID)?.contract else {
                    return false
                }
                return Self.matchesScope(
                    contract,
                    goalID: goalID,
                    continuationRunID: continuationRunID)
            }
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id.rawValue < $1.id.rawValue
                }
                return $0.createdAt < $1.createdAt
            }
        return await persistDiscardedMessages(
            messages,
            goalID: goalID,
            continuationRunID: continuationRunID,
            reason: reason)
    }

    private func persistDiscardedMessages(
        _ messages: [PendingAgentMessage],
        goalID: GoalID?,
        continuationRunID: ContinuationRunID?,
        reason: String
    ) async -> Bool {
        guard !messages.isEmpty else { return true }

        let events = messages.map { message in
            Event.agentMessageDiscarded(AgentMessageDiscardedPayload(
                messageID: message.id,
                agent: message.recipient,
                reason: reason,
                taskID: message.taskID,
                goalID: goalID,
                continuationRunID: continuationRunID,
                metadata: CoworkEventMetadata(
                    taskID: message.taskID,
                    sender: message.sender,
                    recipient: message.recipient,
                    agentID: message.recipient,
                    causalParentID: message.causalParentID,
                    scope: .task,
                    visibility: .privateAgent)))
        }
        do {
            try await appendAdmissionEvents(events)
        } catch {
            try? await log.append(.error(ErrorPayload(
                code: "mailbox_cancellation_settlement_failed",
                message: "Could not discard cancelled Goal mailbox messages: \(error.localizedDescription)")))
            return false
        }
        for message in messages {
            _ = scheduler.acknowledgeMessage(
                message.id,
                recipient: message.recipient)
        }
        return true
    }

    private func taskContract(forCausalTaskID taskID: TaskID?) -> TaskContract? {
        guard let taskID else { return nil }
        return taskGraph.node(taskID)?.contract
            ?? scheduler.knownTask(taskID: taskID)?.contract
    }

    private func completeKnownCommunicationHistory() async throws -> [Envelope] {
        let replay = try await log.replayForProjectionChecked()
        guard replay.hasCompleteKnownHistory else {
            throw EventLogError.incompleteEventHistory
        }
        return replay.envelopes
    }

    private static func sameCommunicationScope(
        _ lhs: TaskContract,
        _ rhs: TaskContract
    ) -> Bool {
        lhs.goalID == rhs.goalID
            && lhs.continuationRunID == rhs.continuationRunID
            && lhs.submissionID == rhs.submissionID
    }

    private func communicationScopeMatches(
        _ current: TaskContract,
        causalTaskID: TaskID?
    ) -> Bool {
        if let origin = taskContract(forCausalTaskID: causalTaskID) {
            return Self.sameCommunicationScope(current, origin)
        }
        // Legacy and host-direct information requests may have no causal task.
        // Accept only that exact nil shape into an equally unscoped mailbox
        // delivery. A nonnil but unknown task ID must remain fail closed.
        return causalTaskID == nil
            && current.goalID == nil
            && current.continuationRunID == nil
            && current.submissionID == nil
    }

    private func communicationCancellationFailure(taskID: TaskID?) -> String? {
        if Task.isCancelled {
            return "communication was cancelled"
        }
        let contract = taskContract(forCausalTaskID: taskID)
        guard isGoalRunCancellationRequested(
            goalID: contract?.goalID,
            continuationRunID: contract?.continuationRunID) else {
            return nil
        }
        if let runID = contract?.continuationRunID,
           let claim = continuationRunCloseClaims[runID] {
            return "ContinuationRun is closed: \(claim.reason)"
        }
        return "Goal continuation cancellation is pending"
    }

    /// `MessageBus` persists before returning. If cancellation installs a
    /// Goal/run tombstone (or cancels the caller) during that await, close the
    /// newly durable mailbox entry with an equally durable discard before the
    /// admission lock is released. This prevents a non-cooperative provider
    /// from reviving a cancelled run after restore.
    private func settleLateCancelledCommunication(
        _ message: PendingAgentMessage,
        taskID: TaskID?
    ) async -> String? {
        guard let failure = communicationCancellationFailure(taskID: taskID) else {
            return nil
        }
        let contract = taskContract(forCausalTaskID: taskID)
        let settled = await persistDiscardedMessages(
            [message],
            goalID: contract?.goalID,
            continuationRunID: contract?.continuationRunID,
            reason: failure)
        if settled { return failure }
        return "\(failure); mailbox discard could not be persisted"
    }

    private func revokeTaskLeases(contract: TaskContract, reason: String) async {
        var events: [Event] = []
        var capabilityToRevoke: (CapabilityLeaseID, CapabilityLease)?
        var workspaceToRevoke: (WorkspaceLeaseID, WorkspaceLease)?
        if let leaseID = contract.capabilityLeaseID,
           let lease = capabilityLeases[leaseID],
           lease.expiresAtTaskCompletion {
            capabilityToRevoke = (leaseID, lease)
            events.append(.capabilityLeaseRevoked(CapabilityLeaseRevokedPayload(
                agent: contract.assignee,
                leaseID: leaseID,
                reason: reason,
                metadata: taskMetadata(contract: contract))))
        }
        if let leaseID = contract.workspaceLeaseID,
           let lease = workspaceLeases[leaseID],
           lease.expiresAtTaskCompletion {
            workspaceToRevoke = (leaseID, lease)
            events.append(.workspaceLeaseRevoked(WorkspaceLeaseRevokedPayload(
                agent: contract.assignee,
                leaseID: leaseID,
                reason: reason,
                metadata: taskMetadata(contract: contract))))
        }
        guard !events.isEmpty else { return }
        do {
            try await appendAdmissionEvents(events)
        } catch {
            // Keeping the leases in memory is the safe failure mode. The task is
            // already terminal, so they cannot authorize another execution, and
            // replay will drop terminal task-scoped leases.
            try? await log.append(.error(ErrorPayload(
                code: "task_lease_revoke_persistence_failed",
                message: "Task \(contract.id.rawValue): \(error.localizedDescription)")))
            return
        }
        if let (leaseID, lease) = capabilityToRevoke {
            capabilityLeaseHistory[leaseID] = lease
            capabilityLeases.removeValue(forKey: leaseID)
        }
        if let (leaseID, lease) = workspaceToRevoke {
            workspaceLeaseHistory[leaseID] = lease
            workspaceLeases.removeValue(forKey: leaseID)
        }
    }

    private func prepareTaskLeaseRenewal(_ original: TaskContract,
                                         assignee: AgentID) async throws -> TaskLeaseRenewal {
        guard registry.agent(assignee) != nil else {
            throw CoworkTaskExecutionError.invalidLease("task assignee @\(assignee.rawValue) is not attached")
        }
        guard let originalCapabilityLeaseID = original.capabilityLeaseID else {
            throw CoworkTaskExecutionError.invalidLease(
                "task \(original.id.rawValue) has no capability lease")
        }
        guard let originalWorkspaceLeaseID = original.workspaceLeaseID else {
            throw CoworkTaskExecutionError.invalidLease(
                "task \(original.id.rawValue) has no workspace lease")
        }

        if defaultCapabilityLeaseIDs[assignee] == originalCapabilityLeaseID,
           defaultWorkspaceLeaseIDs[assignee] == originalWorkspaceLeaseID,
           let capability = capabilityLeases[originalCapabilityLeaseID],
           let workspace = workspaceLeases[originalWorkspaceLeaseID],
           capability.taskID == nil,
           workspace.taskID == nil,
           !capability.expiresAtTaskCompletion,
           !workspace.expiresAtTaskCompletion {
            guard let rootIdentity = workspace.rootIdentity,
                  rootIdentity.matchesCurrentDirectory(rootPath: workspace.rootPath) else {
                throw CoworkTaskExecutionError.invalidLease(
                    "persistent workspace lease root identity is missing or changed")
            }
            return TaskLeaseRenewal(
                contract: original,
                capabilityLease: nil,
                workspaceLease: nil)
        }
        var contract = original
        guard let previousCapability = capabilityLeaseHistory[originalCapabilityLeaseID] else {
            throw CoworkTaskExecutionError.invalidLease(
                "capability lease \(originalCapabilityLeaseID.rawValue) is missing without renewal history")
        }
        guard previousCapability.taskID == original.id,
              previousCapability.expiresAtTaskCompletion else {
            throw CoworkTaskExecutionError.invalidLease(
                "capability lease renewal history is not task-scoped")
        }
        let createdCapabilityLease = CapabilityLease(
            taskID: contract.id,
            tools: previousCapability.tools,
            communication: previousCapability.communication,
            delegation: previousCapability.delegation,
            expiresAtTaskCompletion: true)
        contract.capabilityLeaseID = createdCapabilityLease.id

        guard let previousWorkspace = workspaceLeaseHistory[originalWorkspaceLeaseID] else {
            throw CoworkTaskExecutionError.invalidLease(
                "workspace lease \(originalWorkspaceLeaseID.rawValue) is missing without renewal history")
        }
        guard previousWorkspace.taskID == original.id,
              previousWorkspace.expiresAtTaskCompletion else {
            throw CoworkTaskExecutionError.invalidLease(
                "workspace lease renewal history is not task-scoped")
        }
        guard let previousRootIdentity = previousWorkspace.rootIdentity,
              previousRootIdentity.matchesCurrentDirectory(rootPath: previousWorkspace.rootPath) else {
            throw CoworkTaskExecutionError.invalidLease(
                "workspace lease renewal root identity is missing or changed")
        }
        let createdWorkspaceLease = WorkspaceLease(
            workspaceID: previousWorkspace.workspaceID,
            taskID: contract.id,
            rootPath: previousWorkspace.rootPath,
            rootIdentity: previousRootIdentity,
            access: previousWorkspace.access,
            allowedPathRules: previousWorkspace.allowedPathRules,
            deniedPatterns: previousWorkspace.deniedPatterns,
            expiresAtTaskCompletion: true)
        contract.workspaceLeaseID = createdWorkspaceLease.id
        contract.workspaceID = createdWorkspaceLease.workspaceID
        let metadata = taskMetadata(contract: contract)
        try await appendAdmissionEvents([
            .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                agent: assignee,
                lease: createdCapabilityLease,
                metadata: metadata)),
            .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                agent: assignee,
                lease: createdWorkspaceLease,
                metadata: metadata)),
        ])
        return TaskLeaseRenewal(
            contract: contract,
            capabilityLease: createdCapabilityLease,
            workspaceLease: createdWorkspaceLease)
    }

    private func commitTaskLeaseRenewal(_ renewal: TaskLeaseRenewal) {
        if let lease = renewal.capabilityLease {
            capabilityLeases[lease.id] = lease
        }
        if let lease = renewal.workspaceLease {
            workspaceLeases[lease.id] = lease
        }
    }

    @discardableResult
    private func refreshConsumedTokenCount() async -> Bool {
        let events: [Envelope]
        do {
            events = try await log.replayChecked()
        } catch {
            workTaskRecoveryFailure =
                "Cowork token usage could not be verified from the durable event log: \(error.localizedDescription)"
            return false
        }
        consumedTokenCount = Self.consumedTokenCount(in: events)
        return true
    }

    private static func consumedTokenCount(in events: [Envelope]) -> Int {
        events.reduce(into: 0) { total, envelope in
            guard case .turnStats(let payload) = envelope.event else { return }
            total = saturatingAdd(total, payload.totalTokens
                ?? ((payload.promptTokens ?? 0) + (payload.completionTokens ?? 0))
            )
        }
    }

    private func deliverScheduledReply(format: ScheduledReplyFormat,
                                       from: AgentID,
                                       to: AgentID,
                                       result: String?,
                                       report: TaskReportPayload,
                                       error: String?) async -> AgentMessengerReply {
        switch format {
        case .answer:
            let content = result ?? error.map { "error: \($0)" } ?? Self.formattedTaskReport(report)
            if let forwarded = await bus.deliver(from: from, to: to, content: content) {
                return .success(forwarded)
            }
            return .failure(error.map { "error: \($0)" }
                ?? "delegated task completed, but the result was blocked by the mediator; ask @\(from.rawValue) for a shorter summary")
        case .taskReport:
            let content = Self.formattedTaskReport(report)
            if let forwarded = await bus.deliver(from: from, to: to, content: content) {
                return .success(forwarded)
            }
            return .failure(
                "delegated task finished, but the task report was blocked by the mediator; ask @\(from.rawValue) for a shorter summary")
        }
    }

    private func recycleIdleToolSpawnedAgents(reason: String) async {
        let candidates = spawnedAgentOwners.keys.sorted { $0.rawValue < $1.rawValue }
        for agentID in candidates {
            await recycleToolSpawnedAgentIfIdle(agentID, reason: reason)
        }
    }

    private func recycleToolSpawnedAgentIfIdle(_ agentID: AgentID, reason: String) async {
        guard agentID != Self.mainAgentID,
              agentID != Self.automaticPermissionReviewerID,
              spawnedAgentOwners[agentID] != nil,
              registry.agent(agentID) != nil,
              isAgentIdleForRecycle(agentID) else {
            return
        }
        await detach(agentID, reason: reason)
    }

    private func isAgentIdleForRecycle(_ agentID: AgentID) -> Bool {
        guard taskGraph.nodes.values.contains(where: { $0.assignee == agentID }) else {
            return false
        }
        let mailbox = scheduler.mailbox(for: agentID)
        guard mailbox.pendingTasks.isEmpty, mailbox.pendingMessages.isEmpty else {
            return false
        }
        if scheduler.queuedTasks().contains(where: { $0.assignee == agentID || $0.issuer == agentID }) {
            return false
        }
        return !taskGraph.nodes.values.contains { node in
            Self.isActiveTaskStatus(node.status) && (node.assignee == agentID || node.issuer == agentID)
        }
    }

    func awaitSchedulerResult(_ taskID: TaskID) async -> String? {
        if terminalPersistenceFailures[taskID] != nil {
            return terminalResult(for: taskID)
        }
        if let record = scheduler.record(for: taskID), record.status.isTerminal {
            return terminalResult(for: taskID)
        }
        ensureSchedulerRunning()
        return await withCheckedContinuation { continuation in
            resultWaiters[taskID, default: []].append(continuation)
            schedulerResultWaiterHookForTesting?(taskID)
        }
    }

    func setSchedulerResultWaiterHookForTesting(
        _ hook: (@Sendable (TaskID) -> Void)?
    ) {
        schedulerResultWaiterHookForTesting = hook
    }

    private func causalMetadata(issuer: AgentID,
                                assignee: AgentID,
                                parentTaskID: TaskID?) -> (rootTaskID: TaskID?, hopCount: Int, visitedAgents: [AgentID], rejected: Bool) {
        guard let parentTaskID,
              let parent = scheduler.record(for: parentTaskID) else {
            return (nil, 1, Self.uniqueAgents([issuer, assignee]), false)
        }
        if parent.visitedAgents.contains(assignee) {
            return (parent.rootTaskID ?? parentTaskID, parent.hopCount + 1, parent.visitedAgents, true)
        }
        var visited = parent.visitedAgents
        visited.append(assignee)
        return (parent.rootTaskID ?? parentTaskID, parent.hopCount + 1, Self.uniqueAgents(visited), false)
    }

    private static func uniqueAgents(_ agents: [AgentID]) -> [AgentID] {
        var seen = Set<AgentID>()
        var result: [AgentID] = []
        for agent in agents where !seen.contains(agent) {
            seen.insert(agent)
            result.append(agent)
        }
        return result
    }

    private static func makeTaskReport(task: ScheduledTask,
                                       status: TaskStatus,
                                       result: String? = nil,
                                       error: String? = nil,
                                       attempt: Int? = nil) -> TaskReportPayload {
        let detail = nonEmptyTrimmed(result).map { truncate($0, maxCharacters: 2_000) }
        let errorText = nonEmptyTrimmed(error).map { truncate($0, maxCharacters: 1_000) }
        let summarySource = detail ?? errorText ?? defaultSummary(status: status, agent: task.assignee)
        return TaskReportPayload(
            taskID: task.contract.id,
            agent: task.assignee,
            status: status,
            objective: task.contract.objective,
            expectedDeliverable: task.contract.expectedDeliverable,
            summary: summaryLine(from: summarySource, status: status),
            detail: detail,
            error: errorText,
            attempt: attempt)
    }

    private static func formattedTaskReport(_ report: TaskReportPayload) -> String {
        var lines: [String] = [
            "Task Report",
            "task: \(report.taskID.rawValue)",
            "status: \(report.status.rawValue)",
            "agent: @\(report.agent.rawValue)",
            "objective: \(report.objective)",
            "expected deliverable: \(report.expectedDeliverable)",
            "summary: \(report.summary)",
        ]
        if let error = report.error {
            lines.append("error: \(error)")
        }
        if let detail = report.detail, detail != report.summary {
            lines.append("detail:")
            lines.append(detail)
        }
        return lines.joined(separator: "\n")
    }

    private static func summaryLine(from text: String, status: TaskStatus) -> String {
        let firstLine = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return truncate(firstLine ?? defaultSummary(status: status, agent: nil), maxCharacters: 500)
    }

    private static func defaultSummary(status: TaskStatus, agent: AgentID?) -> String {
        let actor = agent.map { " by @\($0.rawValue)" } ?? ""
        switch status {
        case .completed:
            return "Task completed\(actor)."
        case .failed:
            return "Task failed\(actor)."
        case .created, .assigned, .queued, .running, .cancelled:
            return "Task status is \(status.rawValue)\(actor)."
        }
    }

    private static func nonEmptyTrimmed(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func truncate(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let index = text.index(text.startIndex, offsetBy: maxCharacters)
        return String(text[..<index]) + "..."
    }

    private static func compactTaskStates(_ nodes: [TaskNode], limit: Int = 4) -> String {
        let visible = nodes.prefix(limit).map { "\($0.id.rawValue):\($0.status.rawValue)" }
        guard nodes.count > limit else {
            return visible.joined(separator: ",")
        }
        return (visible + ["+\(nodes.count - limit) more"]).joined(separator: ",")
    }

    private static func isActiveTaskStatus(_ status: TaskStatus) -> Bool {
        switch status {
        case .created, .assigned, .queued, .running:
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }

    private static func delegationRejectionMessage(for violation: TaskGraphViolation) -> String {
        switch violation.kind {
        case .selfDelegation:
            return "error: agent cannot delegate to itself"
        case .cycleDetected:
            return "error: delegation cycle rejected"
        case .duplicateTask:
            return violation.existingTaskID.map { "error: duplicate task rejected: \($0.rawValue)" }
                ?? "error: duplicate task rejected"
        case .maxDepthExceeded:
            return "error: task depth limit exceeded"
        case .maxDelegationHopsExceeded:
            return "error: delegation hop limit exceeded"
        case .maxTasksPerRootExceeded:
            return "error: task limit exceeded"
        case .maxActiveAgentsExceeded:
            return "error: active agent limit exceeded"
        case .missingParentTask:
            return "error: parent task not found"
        case .duplicateTaskID:
            return "error: duplicate task id"
        }
    }

    public static func toolRegistry(for lease: CapabilityLease,
                                    agentID: AgentID? = nil,
                                    includesTerminal: Bool = true,
                                    canControlRun: Bool = false,
                                    hostedWebSearch:
                                        (any HostedWebSearchToolService)? = nil)
        -> ToolRegistry
    {
        var registrations: [ToolRegistration] = []
        func register(
            _ tools: [any Tool],
            granting capabilities: Set<ToolCapability>,
            communication: ToolCommunicationRequirement = .none,
            delegation: ToolDelegationRequirement = .none
        ) {
            registrations.append(contentsOf: tools.map {
                ToolRegistration(
                    tool: $0,
                    grantingCapabilities: capabilities,
                    requiredCommunication: communication,
                requiredDelegation: delegation)
            })
        }
        func registerDocumentTool(
            _ tool: any Tool,
            exactCapability: ToolCapability,
            legacyCapability: ToolCapability? = nil
        ) {
            if lease.tools.contains(exactCapability) {
                register([tool], granting: [exactCapability])
            } else if let legacyCapability,
                      lease.tools.contains(legacyCapability) {
                register([tool], granting: [legacyCapability])
            }
        }
        if lease.tools.contains(.readWorkspace) {
            register([ReadFileTool()], granting: [.readWorkspace])
        }
        if lease.tools.contains(.readPDF) {
            register([InspectPDFTool(), ReadPDFTool()], granting: [.readPDF])
        }
        registerDocumentTool(
            ReadDOCXTool(), exactCapability: .readDOCX, legacyCapability: .documentRead)
        registerDocumentTool(
            ContinueDOCXReadTool(),
            exactCapability: .continueDOCXRead,
            legacyCapability: .documentRead)
        registerDocumentTool(
            ReadPPTXTool(), exactCapability: .readPPTX, legacyCapability: .documentRead)
        registerDocumentTool(
            ContinuePPTXReadTool(),
            exactCapability: .continuePPTXRead,
            legacyCapability: .documentRead)
        registerDocumentTool(
            ReadXLSXTool(), exactCapability: .readXLSX, legacyCapability: .documentRead)
        registerDocumentTool(
            ContinueXLSXReadTool(),
            exactCapability: .continueXLSXRead,
            legacyCapability: .documentRead)
        registerDocumentTool(
            ReadHTMLTool(), exactCapability: .readHTML, legacyCapability: .documentRead)
        registerDocumentTool(
            ContinueHTMLReadTool(),
            exactCapability: .continueHTMLRead,
            legacyCapability: .documentRead)
        registerDocumentTool(
            ReadEPUBTool(), exactCapability: .readEPUB, legacyCapability: .documentRead)
        registerDocumentTool(
            ContinueEPUBReadTool(),
            exactCapability: .continueEPUBRead,
            legacyCapability: .documentRead)
        registerDocumentTool(
            OCRPDFTool(), exactCapability: .ocrPDF, legacyCapability: .documentOCR)
        registerDocumentTool(
            PDFRenderPageTool(),
            exactCapability: .pdfRenderPage,
            legacyCapability: .documentRender)
        for capability in ToolCapability.exactDocumentExportCapabilities
            .sorted(by: { $0.rawValue < $1.rawValue })
        {
            let grantingCapability: ToolCapability?
            if lease.tools.contains(capability) {
                grantingCapability = capability
            } else if lease.tools.contains(.documentExportPDF) {
                grantingCapability = .documentExportPDF
            } else {
                grantingCapability = nil
            }
            if let grantingCapability,
               let registration = ExactDocumentToolCatalog.exportRegistration(
                   named: capability.rawValue,
                   grantingCapabilities: [grantingCapability]) {
                registrations.append(registration)
            }
        }
        for capability in ToolCapability.exactDocumentWriteCapabilities
            .sorted(by: { $0.rawValue < $1.rawValue })
        {
            let grantingCapability: ToolCapability?
            if lease.tools.contains(capability) {
                grantingCapability = capability
            } else if lease.tools.contains(.documentWrite) {
                grantingCapability = .documentWrite
            } else {
                grantingCapability = nil
            }
            if let grantingCapability,
               let registration = ExactDocumentToolCatalog.writeRegistration(
                   named: capability.rawValue,
                   grantingCapabilities: [grantingCapability]) {
                registrations.append(registration)
            }
        }
        if lease.tools.contains(.listWorkspace) {
            register([ListFilesTool()], granting: [.listWorkspace])
        }
        if lease.tools.contains(.searchWorkspace) {
            register([SearchTextTool()], granting: [.searchWorkspace])
        }
        if lease.tools.contains(.applyPatch) {
            // One lease capability deliberately exposes two concrete editing
            // tools. Keep that alias here in the same entries used for model
            // schemas, host authorization, and executor lookup.
            register([WriteFileTool(), ApplyPatchTool()], granting: [.applyPatch])
        }
        // `run_shell` remains unavailable. The two managed terminal tools use
        // an OS-enforced WorkspaceLease sandbox and an owner-bound process
        // session instead.
        if includesTerminal, lease.tools.contains(.runShell) {
            register(
                [ExecCommandTool(), WriteStdinTool()],
                granting: [.runShell])
        }
        // Keep the legacy alias for read-only Git inspection.
        if lease.tools.contains(.gitControl) || lease.tools.contains(.runShell) {
            register([
                GitStatusTool(), GitDiffTool(), GitInfoTool(),
                GitRecentCommitsTool(), GitDiffBaseTool(),
            ], granting: [.gitControl, .runShell])
        }
        if lease.tools.contains(.gitControl) {
            register([
                GitStagedDiffTool(), GitBranchTool(), GitCreateBranchTool(),
                GitStageTool(), GitUnstageTool(), GitCommitTool(),
                GitApplyPatchCheckTool(), GitApplyPatchTool(), GitStagePatchTool(),
                GitUnstagePatchTool(), GitRevertPatchTool(), GitWorktreeListTool(),
                GitWorktreeCreateTool(), GitWorktreeRemoveTool(), GitSwitchBranchTool(),
            ], granting: [.gitControl])
        }
        if lease.tools.contains(.gitRemote) {
            register([
                GitRemotesTool(), GitFetchTool(), GitPullFastForwardTool(),
                GitPushTool(),
            ], granting: [.gitRemote])
        }
        if lease.tools.contains(.compileLaTeX) {
            register([CompileLaTeXTool()], granting: [.compileLaTeX])
        }
        if lease.tools.contains(.generateMedia) {
            register([GenerateImageTool(), EditImageTool()], granting: [.generateMedia])
        }
        if lease.tools.contains(.hostedWebSearch),
           let hostedWebSearch {
            register(
                [HostedWebSearchTool(service: hostedWebSearch)],
                granting: [.hostedWebSearch])
        }
        if lease.tools.contains(.browseWeb) {
            register([
                WebFetchTool(), BrowserDiagnosticsTool(), BrowserProfilesTool(),
                BrowserProfileDeleteTool(), BrowserHistoryTool(), BrowserNavigateTool(),
                BrowserSnapshotTool(), BrowserHandoffTool(), BrowserReloadTool(),
                BrowserBackTool(), BrowserForwardTool(), BrowserClickTool(),
                BrowserTypeTool(), BrowserSubmitTool(), BrowserSelectOptionTool(),
                BrowserPressKeyTool(), BrowserScrollTool(), BrowserWaitTool(),
                BrowserScreenshotTool(), BrowserUploadFileTool(), BrowserDownloadTool(),
                BrowserDownloadsTool(), BrowserSearchTool(),
            ], granting: [.browseWeb])
        }
        if lease.tools.contains(.manageWorkTasks) {
            register([
                TaskCreateTool(), TaskUpdateTool(), TaskGetTool(), TaskListTool(),
            ], granting: [.manageWorkTasks])
        } else {
            if lease.tools.contains(.updateBoundWorkTask) {
                register([BoundWorkTaskUpdateTool()], granting: [.updateBoundWorkTask])
            }
            if lease.tools.contains(.readWorkTasks) {
                register([TaskGetTool(), TaskListTool()], granting: [.readWorkTasks])
            }
        }
        if lease.tools.contains(.readGoal) {
            register([GetGoalTool()], granting: [.readGoal])
        }
        // Production invocations always supply an identity, so the terminal
        // Goal control is exposed only to exact @main. `nil` remains a narrow
        // construction seam for the isolated verifier/tool-registry tests.
        if (agentID == nil || agentID == mainAgentID),
           lease.tools.contains(.submitGoalVerdict) {
            register([UpdateGoalTool()], granting: [.submitGoalVerdict])
        }
        if agentID == mainAgentID, lease.tools.contains(.renameSession) {
            register([RenameSessionTool()], granting: [.renameSession])
        }
        if canControlRun,
           agentID == mainAgentID,
           lease.tools.contains(.controlRun) {
            register(
                [FinishRunTool(), StopRunTool()],
                granting: [.controlRun])
        }
        let canInitiateCommunication: Bool
        switch lease.communication {
        case .selectedAgents, .taskGroup, .anyAgentInThread:
            canInitiateCommunication = true
        case .none, .replyOnly:
            canInitiateCommunication = false
        }
        let canReply: Bool
        switch lease.communication {
        case .none:
            canReply = false
        case .replyOnly, .selectedAgents, .taskGroup, .anyAgentInThread:
            canReply = true
        }
        let hasDelegationGrant: Bool
        switch lease.delegation {
        case .granted:
            hasDelegationGrant = true
        case .none:
            hasDelegationGrant = false
        }

        if lease.tools.contains(.requestInformation), canInitiateCommunication {
            register(
                [RequestInformationTool()],
                granting: [.requestInformation],
                communication: .initiate)
        }
        if lease.tools.contains(.delegateTask), hasDelegationGrant {
            register(
                [AskAgentTool()],
                granting: [.delegateTask],
                delegation: .granted)
        }
        if lease.tools.contains(.sendMessage), canInitiateCommunication {
            register(
                [SendMessageTool()],
                granting: [.sendMessage],
                communication: .initiate)
        }
        if lease.tools.contains(.replyMessage), canReply {
            register(
                [ReplyMessageTool()],
                granting: [.replyMessage],
                communication: .reply)
        }
        if lease.tools.contains(.delegateTask), hasDelegationGrant {
            register(
                [DelegateTaskTool()],
                granting: [.delegateTask],
                delegation: .granted)
        }
        if hasDelegationGrant, lease.tools.contains(.attachWorkspace) {
            register(
                [SpawnAgentTool(), ListInferenceProfilesTool()],
                granting: [.attachWorkspace],
                delegation: .granted)
        }
        if lease.tools.contains(.delegateTask), hasDelegationGrant {
            register(
                [ListAgentsTool(), RemoveAgentTool()],
                granting: [.delegateTask],
                delegation: .granted)
        }
        return ToolRegistry(
            registrations: registrations,
            registryVersion: IntatisHostApplication.identity
                .namespacedIdentifier("cowork.v5"))
    }

    private static func canCoordinate(_ lease: CapabilityLease) -> Bool {
        guard case .granted = lease.delegation else { return false }
        return lease.tools.contains(.delegateTask)
            || lease.tools.contains(.attachWorkspace)
    }

    private static func coordinationDepth(_ lease: CapabilityLease) -> Int {
        guard case .granted(let budget) = lease.delegation,
              canCoordinate(lease) else { return 0 }
        return max(1, min(Agent.defaultCoordinationDepth, budget.maxDepth + 1))
    }

    static func hasWorkspaceMutationCapability(_ lease: CapabilityLease) -> Bool {
        let documentMutations = ToolCapability.exactDocumentMutationCapabilities.union([
            .documentRender,
            .documentExportPDF,
            .documentWrite,
        ])
        return !lease.tools.isDisjoint(with: documentMutations.union([
            .applyPatch,
            .compileLaTeX,
            .generateMedia,
            .gitControl,
        ]))
    }

    /// A document reader or OCR engine may need a managed helper process, but
    /// process execution does not itself require workspace mutation authority.
    /// Only capabilities that can persist user-visible output require RW.
    static func requiresReadWriteWorkspaceAccess(_ lease: CapabilityLease) -> Bool {
        hasWorkspaceMutationCapability(lease)
            || lease.tools.contains(.buildKnowledge)
    }

    private static let defaultWorkerConstraints: [String] = [
        "Complete only the assigned task.",
        "Do not re-run the global task decomposition.",
        "Do not create, remove, or coordinate other agents.",
        "If you need help, report the need to the assigning agent or user.",
    ]

    private static func defaultRoleHint(for assignee: AgentID, objective: String) -> String {
        let name = assignee.rawValue.lowercased()
        let lowerObjective = objective.lowercased()
        if name.contains("macos"), name.contains("counter"), lowerObjective.contains("swift") {
            return "macOS Swift file counter"
        }
        if name.contains("ios"), name.contains("counter"), lowerObjective.contains("swift") {
            return "iOS Swift file counter"
        }
        let parts = assignee.rawValue
            .split { "-_ .".contains($0) }
            .map { displayRoleToken(String($0)) }
        return parts.isEmpty ? "assigned task worker" : parts.joined(separator: " ")
    }

    private static func displayRoleToken(_ token: String) -> String {
        switch token.lowercased() {
        case "macos": return "macOS"
        case "ios": return "iOS"
        case "swift": return "Swift"
        default: return token
        }
    }
}

private enum MailboxDeliveryAuthorityClass: Sendable, Hashable {
    case ordinaryMessage
    case informationRequest
    case informationReply
}

private struct MailboxDeliveryBatchKey: Sendable, Hashable {
    var sender: AgentID
    var recipient: AgentID
    var goalID: GoalID?
    var continuationRunID: ContinuationRunID?
    var authorityClass: MailboxDeliveryAuthorityClass
}

private enum MailboxWakeDisposition: Sendable {
    case alreadyScheduled(TaskID)
    case retry(TaskID)
    case admitNew([PendingAgentMessage])
    case exhausted
    case ambiguous
}

private enum MailboxMessageBinding: Sendable {
    case alreadyScheduled(TaskID)
    case retry(TaskID)
    case unbound
    case exhausted
    case ambiguous
}

private struct PreparedDelegatedTask: Sendable {
    var contract: TaskContract
    var capabilityLease: CapabilityLease
    var workspaceLease: WorkspaceLease
}

private struct WorkspaceAttachAssessment: Sendable {
    var canonical: URL?
    var canAskUser: Bool
    var risk: RiskLevel
    var reason: String
}

private func assessWorkspaceAttach(_ url: URL) -> WorkspaceAttachAssessment {
    do {
        let canonical = try PathConfinement.canonicalExistingDirectory(url)
        if isDeniedWorkspaceRoot(canonical) {
            return WorkspaceAttachAssessment(
                canonical: canonical,
                canAskUser: false,
                risk: .high,
                reason: "workspace path is too broad or system-sensitive: \(canonical.path)")
        }
        return WorkspaceAttachAssessment(
            canonical: canonical,
            canAskUser: true,
            risk: .medium,
            reason: "attach new agent workspace: \(canonical.path)")
    } catch {
        return WorkspaceAttachAssessment(
            canonical: nil,
            canAskUser: false,
            risk: .high,
            reason: error.localizedDescription)
    }
}

private func isDeniedWorkspaceRoot(_ url: URL) -> Bool {
    let path = url.path
    let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
    if path == "/" || path == "/Users" || path == "/var" || path == "/private/var" || path == home {
        return true
    }
    let deniedPrefixes = [
        "/System", "/Library", "/bin", "/sbin", "/usr", "/etc", "/private/etc",
        "/var/db", "/var/root", "/private/var/db", "/private/var/root",
        home + "/.ssh", home + "/Library/Keychains",
    ]
    return deniedPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
}

private func attachArgs(agent: Agent,
                        canonicalPath: String,
                        admissionTaskID: TaskID,
                        capabilityLease: CapabilityLease,
                        workspaceLease: WorkspaceLease) -> String {
    var object: [String: Any] = [
        "agent": agent.name.rawValue,
        "path": canonicalPath,
        "model": agent.model.rawValue,
        "profile": agent.profile.rawValue,
        "coordinationDepth": agent.coordinationDepth,
        "canCoordinate": agent.coordinationDepth > 0,
        "admissionTaskID": admissionTaskID.rawValue,
        "capabilityLeaseID": capabilityLease.id.rawValue,
        "workspaceLeaseID": workspaceLease.id.rawValue,
        "workspaceAccess": workspaceLease.access.rawValue,
        "capabilities": capabilityLease.tools.map(\.rawValue).sorted(),
    ]
    if let binding = agent.agentInferenceBinding {
        object["inferenceProfileID"] = binding.inferenceProfileID.rawValue
        object["inferenceProfileRevision"] = binding.inferenceProfileRevision.rawValue
        object["inferenceConnectionID"] = binding.inferenceConnectionID.rawValue
        object["inferenceConnectionRevision"] = binding.inferenceConnectionRevision.rawValue
        object["inferenceBindingFingerprint"] = ToolRegistry.authorizationFingerprint(binding)
    }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        return "{}"
    }
    return String(decoding: data, as: UTF8.self)
}

/// Per-agent messenger handed to each agent's loop; binds `from` and routes
/// through the orchestrator (and thus the mediated bus).
struct BusMessenger: AgentMessenger {
    let from: AgentID
    let currentTaskID: TaskID?
    let orchestrator: Orchestrator

    func ask(to agent: String, question: String) async -> AgentMessengerReply {
        await orchestrator.askResult(
            from: from,
            to: agent,
            question: question,
            parentTaskID: currentTaskID)
    }

    func sendMessage(to agent: String, content: String) async -> String {
        await orchestrator.sendMessage(from: from, to: agent, content: content, taskID: currentTaskID)
    }

    func requestInformation(to agent: String,
                            question: String,
                            basedOn: String?) async -> String {
        await orchestrator.requestInformation(
            from: from,
            to: agent,
            question: question,
            basedOn: basedOn,
            taskID: currentTaskID)
    }

    func replyMessage(to agent: String, content: String, inReplyTo: String) async -> String {
        await orchestrator.replyMessage(from: from, to: agent, content: content, inReplyTo: inReplyTo, taskID: currentTaskID)
    }

    func delegateTask(authorization: ResolvedToolAuthorization,
                      executionID: String,
                      to agent: String?,
                      workTaskID: WorkTaskID?,
                      objective: String?,
                      roleHint: String?,
                      expectedDeliverable: String?) async throws -> String {
        guard let agent else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "delegation_target_missing",
                message: "delegate_task was rejected before admission because authorization has no concrete target")
        }
        let result = await orchestrator.delegateAuthorizedTask(
            from: from,
            authorization: authorization,
            executionID: executionID,
            to: agent,
            workTaskID: workTaskID,
            objective: objective,
            roleHint: roleHint,
            expectedDeliverable: expectedDeliverable,
            parentTaskID: currentTaskID)
        guard result.hasPrefix("task_id=") else {
            let message = result.hasPrefix("error:")
                ? String(result.dropFirst("error:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                : result
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "delegation_not_started",
                message: message.isEmpty
                    ? "delegate_task was rejected before admission"
                    : message)
        }
        return result
    }
}

/// Invocation-bound adapter used only when the tool registry has already
/// proven this is the exact @main root of a ContinuationRun.
struct OrchestratorRunController: RunController {
    let currentTaskID: TaskID?
    let orchestrator: Orchestrator

    func requestClose(outcome: ContinuationRunCloseOutcome,
                      reason: String) async -> String {
        await orchestrator.requestContinuationRunClose(
            currentTaskID: currentTaskID,
            outcome: outcome,
            reason: reason)
    }
}

/// Coordinator seam handed to each agent's loop; routes lifecycle calls through
/// the orchestrator actor (and thus its registry + event log).
struct OrchestratorManager: AgentManager {
    let orchestrator: Orchestrator
    let requester: AgentID
    let currentTaskID: TaskID?

    func spawnAgent(authorization: ResolvedToolAuthorization?,
                    name: String,
                    path: String,
                    inferenceProfileID: String?,
                    requestedAccess: WorkspaceAccess,
                    canCoordinate: Bool) async -> String {
        await orchestrator.spawnFromTool(
            requestedBy: requester,
            currentTaskID: currentTaskID,
            name: name,
            path: path,
            inferenceProfileID: inferenceProfileID,
            authorization: authorization,
            requestedAccess: requestedAccess,
            canCoordinate: canCoordinate)
    }
    func listAgents() async -> String { await orchestrator.listForTool() }
    func listInferenceProfiles() async -> String {
        await orchestrator.listInferenceProfilesForTool()
    }
    func removeAgent(name: String) async -> String {
        await orchestrator.removeFromTool(
            requestedBy: requester,
            currentTaskID: currentTaskID,
            name: name)
    }
}

/// Capability- and invocation-scoped adapter for the model-facing WorkTask
/// tools. Keeping the authority context here prevents callers from widening
/// their own read or mutation scope through tool arguments.
struct OrchestratorWorkTaskManager: WorkTaskManager {
    let orchestrator: Orchestrator
    let currentWorkTaskID: WorkTaskID?
    let canManage: Bool
    let canUpdateBound: Bool

    func createWorkTask(_ request: WorkTaskCreateRequest) async throws -> WorkTaskDetail {
        try await orchestrator.createWorkTask(
            canManage: canManage,
            request: request,
            // Only the production adapter opts into Orchestrator's concrete
            // proof that this rejection happened before its first WorkTask
            // EventLog append. Arbitrary WorkTaskManager implementations are
            // not trusted to make the same claim.
            provePreflightRejectionHasNoEffect: true)
    }

    func updateWorkTask(_ request: WorkTaskUpdateRequest) async throws -> WorkTaskDetail {
        try await orchestrator.updateWorkTask(
            currentWorkTaskID: currentWorkTaskID,
            canManage: canManage,
            canUpdateBound: canUpdateBound,
            request: request,
            // This adapter owns the concrete no-effect proof boundary:
            // Orchestrator classifies only failures raised before its first
            // EventLog append. Arbitrary WorkTaskManager implementations are
            // not trusted to make the same claim.
            provePreflightRejectionHasNoEffect: true)
    }

    func getWorkTask(_ taskID: WorkTaskID) async throws -> WorkTaskDetail {
        try await orchestrator.getWorkTask(
            currentWorkTaskID: currentWorkTaskID,
            canManage: canManage,
            taskID: taskID)
    }

    func listWorkTasks(_ request: WorkTaskListRequest) async throws -> [WorkTaskDetail] {
        try await orchestrator.listWorkTasks(
            currentWorkTaskID: currentWorkTaskID,
            canManage: canManage,
            request: request)
    }
}

/// Goal tool authority is bound by the host, never inferred from model text.
/// Model runtimes can read the current projection and, with a dedicated
/// verifier lease, submit a terminal candidate. Goal creation and user-owned
/// edit/pause/resume/clear operations stay host-only.
private struct OrchestratorGoalManager: GoalManager {
    let orchestrator: Orchestrator
    let canSubmitVerdict: Bool

    func currentGoal() async throws -> Goal? {
        await orchestrator.currentGoalSnapshot()
    }

    func editGoal(_ request: GoalEditRequest) async throws -> Goal {
        try await orchestrator.editGoal(request: request, hostAuthorized: false)
    }

    func transitionGoal(_ goalID: GoalID,
                        expectedRevision: Int,
                        to status: GoalStatus) async throws -> Goal {
        try await orchestrator.transitionGoal(
            goalID,
            expectedRevision: expectedRevision,
            to: status,
            canSubmitVerdict: canSubmitVerdict,
            hostAuthorized: false)
    }

    func clearGoal(_ goalID: GoalID, expectedRevision: Int) async throws {
        try await orchestrator.clearGoal(
            goalID,
            expectedRevision: expectedRevision,
            hostAuthorized: false)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
