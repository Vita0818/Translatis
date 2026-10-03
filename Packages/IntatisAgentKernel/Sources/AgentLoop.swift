import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
import IntatisMCP
import IntatisArtifacts

public typealias ToolAuthorizationRevalidator = @Sendable (
    ResolvedToolAuthorization
) async -> String?

/// Host preflight performed after schema validation but before the immutable
/// authorization snapshot is created. Cowork uses it to turn symbolic targets
/// such as delegate_task(to:auto) into concrete resources for review without
/// mutating the roster, leases, scheduler, or event log.
public struct ToolAuthorizationPreparationRequest: Sendable {
    public let authorizationID: String
    public let toolName: String
    public let normalizedArguments: String
    public let baseIntent: PermissionIntent
    public let invocation: ToolAuthorizationInvocationContext

    public init(authorizationID: String,
                toolName: String,
                normalizedArguments: String,
                baseIntent: PermissionIntent,
                invocation: ToolAuthorizationInvocationContext) {
        self.authorizationID = authorizationID
        self.toolName = toolName
        self.normalizedArguments = normalizedArguments
        self.baseIntent = baseIntent
        self.invocation = invocation
    }
}

/// Host-resolved authorization facts produced before the immutable registry
/// snapshot is created. `targetAgentInferenceBinding` is deliberately a
/// structured protocol value rather than free-form metadata so the exact
/// route/profile revision survives review and durable execution tickets.
public struct ToolAuthorizationPreparation: Sendable {
    public var intent: PermissionIntent
    public var targetAgentInferenceBinding: AgentInferenceBinding?

    public init(intent: PermissionIntent,
                targetAgentInferenceBinding: AgentInferenceBinding? = nil) {
        self.intent = intent
        self.targetAgentInferenceBinding = targetAgentInferenceBinding
    }
}

public typealias ToolAuthorizationPreparer = @Sendable (
    ToolAuthorizationPreparationRequest
) async throws -> ToolAuthorizationPreparation

/// Terminal failures produced by the agent loop itself, rather than by a
/// provider or tool. Callers can distinguish these from a successful (possibly
/// empty) final response without parsing an event-log message.
public enum AgentLoopError: Error, Sendable, Equatable, LocalizedError {
    case maxIterationsExceeded(limit: Int)
    case responseEndedWithoutCompletionMarker
    case completionExpectedToolCalls(finishReason: String)
    case incompleteFinishReason(String)
    case repeatedDeniedToolCall(tool: String)
    case invalidEvidenceCitation(String)
    case mediaOutputUnsupported(String)
    case mediaOutputInvalid(String)

    public var errorDescription: String? {
        switch self {
        case .maxIterationsExceeded(let limit):
            return "Agent exceeded the maximum of \(limit) tool iterations without reaching a final response."
        case .responseEndedWithoutCompletionMarker:
            return "Agent response ended without an explicit completion marker."
        case .completionExpectedToolCalls(let finishReason):
            return "Agent response finished with \(finishReason) but provided no tool calls."
        case .incompleteFinishReason(let finishReason):
            return "Agent response ended incompletely with finish reason \(finishReason)."
        case .repeatedDeniedToolCall(let tool):
            return "Agent repeatedly retried the identical denied tool call \(tool); the task was stopped to protect the automatic permission reviewer."
        case .invalidEvidenceCitation(let reason):
            return "Agent invocation contains an invalid knowledge evidence citation: \(reason)"
        case .mediaOutputUnsupported(let reason):
            return "Tool media cannot be delivered to the selected model route: \(reason)"
        case .mediaOutputInvalid(let reason):
            return "Tool media failed durable validation: \(reason)"
        }
    }
}

/// A typed, non-failure terminal used when a user explicitly cancels from a
/// permission prompt. It is distinct from a call-scoped decline and from an
/// arbitrary provider/runtime `CancellationError`.
public struct AgentTurnInterruptedError: Error, Sendable, Equatable, LocalizedError {
    public let reason: String
    public let failureSource: ExecutionFailureSource

    public init(reason: String,
                failureSource: ExecutionFailureSource = .userCancelled) {
        self.reason = reason
        self.failureSource = failureSource
    }

    public var errorDescription: String? { reason }
}

private struct ModelHistoryRecordingScope: Sendable {
    var turnID: TurnID
    var taskID: TaskID?
    var submissionID: SubmissionID
    var taskAttempt: Int
}

private struct AgentMaterializedImages: Sendable {
    var references: [ModelHistoryImageReference]
    var attachments: [ImageAttachment]
}

/// Request-local handoff between durable tool completion and the next provider
/// request. Keys include the TurnID so concurrent or retried invocations can
/// never consume another turn's function-call output.
private actor AgentToolOutputDeliveryLedger {
    private var messages: [String: [String: AgentMessage]] = [:]

    func record(
        _ message: AgentMessage,
        turnID: TurnID,
        callID: String
    ) {
        messages[turnID.rawValue, default: [:]][callID] = message
    }

    func take(turnID: TurnID, callID: String) -> AgentMessage? {
        let message = messages[turnID.rawValue]?[callID]
        messages[turnID.rawValue]?[callID] = nil
        if messages[turnID.rawValue]?.isEmpty == true {
            messages[turnID.rawValue] = nil
        }
        return message
    }

    func remove(turnID: TurnID) {
        messages[turnID.rawValue] = nil
    }
}

/// Per-AgentLoop circuit breaker. Policy/user/reviewer denials keep the normal
/// cached-denial behavior. A typed transient automatic-review infrastructure
/// failure may spend exactly one fresh review before the cache closes again.
private actor ToolDenialCircuitBreaker {
    private struct DenialState {
        var attempts: Int
        var permitsFreshReview: Bool
    }

    private var denials: [String: DenialState] = [:]

    func noteRepeatedAttempt(signature: String) -> Int? {
        guard var state = denials[signature] else { return nil }
        state.attempts += 1
        if state.permitsFreshReview {
            state.permitsFreshReview = false
            denials[signature] = state
            return nil
        }
        denials[signature] = state
        return state.attempts
    }

    func recordDenial(signature: String,
                      permitsOneFreshReview: Bool = false) {
        guard denials[signature] == nil else { return }
        denials[signature] = DenialState(
            attempts: 1,
            permitsFreshReview: permitsOneFreshReview)
    }
}

/// Resolves the kernel-side permission wait exactly once. The approval request
/// runs in its own task so cancelling an AgentLoop never depends on a responder
/// cooperatively returning from its UI/network wait.
private final class PermissionApprovalGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PermissionApprovalResolution, Error>?
    private var pendingResult: Result<PermissionApprovalResolution, Error>?
    private var approvalTask: Task<Void, Never>?
    private var isResolved = false

    func install(_ continuation: CheckedContinuation<PermissionApprovalResolution, Error>) {
        let result: Result<PermissionApprovalResolution, Error>?
        lock.lock()
        if let pendingResult {
            result = pendingResult
            self.pendingResult = nil
        } else {
            self.continuation = continuation
            result = nil
        }
        lock.unlock()
        if let result {
            continuation.resume(with: result)
        }
    }

    func setApprovalTask(_ task: Task<Void, Never>) {
        let shouldCancel: Bool
        lock.lock()
        if isResolved {
            shouldCancel = true
        } else {
            approvalTask = task
            shouldCancel = false
        }
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func resolve(_ result: Result<PermissionApprovalResolution, Error>) {
        let continuation: CheckedContinuation<PermissionApprovalResolution, Error>?
        let taskToCancel: Task<Void, Never>?
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        switch result {
        case .success:
            taskToCancel = nil
        case .failure:
            taskToCancel = approvalTask
        }
        approvalTask = nil
        lock.unlock()

        taskToCancel?.cancel()
        continuation?.resume(with: result)
    }

    func cancel() {
        resolve(.failure(CancellationError()))
    }
}

/// The single-agent tool loop (ARCHITECTURE.md §3.9, §6.1). It only orchestrates:
/// build context → stream model → for each tool call run the permission pipeline
/// → execute → feed the observation back → repeat until the model stops calling
/// tools. Every state change is appended to the event log.
public struct AgentLoop: Sendable {
    private let log: EventLog
    private let provider: ToolCallingProvider
    private let registry: ToolRegistry
    private let engine: PermissionEngine
    private let responder: PermissionResponder
    private let agent: Agent
    private let context: ContextBuilder
    private let allowsShell: Bool
    private let shell: ShellRunner
    private let terminal: (any TerminalSessionManaging)?
    private let git: GitService
    private let messenger: AgentMessenger?
    private let agentManager: AgentManager?
    private let workTaskManager: WorkTaskManager?
    private let goalManager: GoalManager?
    private let runController: RunController?
    private let imageGenerator: ImageGenerationToolService?
    private let imageResolver: AgentImageResolver?
    private let sessionNaming: SessionNamingService?
    private let reasoningEffort: ReasoningEffort?
    private let includeUsage: Bool
    private let modelContextPolicy: AgentModelContextPolicy
    private let maxIterations: Int
    private let capabilityLease: CapabilityLease?
    private let workspaceLease: WorkspaceLease?
    private let rootTaskID: TaskID?
    private let taskAttempt: Int?
    private let executionScope: AgentExecutionScope?
    private let tokenBudgetMeter: AgentTokenBudgetMeter?
    private let authorizationPreparer: ToolAuthorizationPreparer?
    private let authorizationRevalidator: ToolAuthorizationRevalidator?
    private let toolSnapshotProvider: AgentRequestToolSnapshotProvider?
    private let toolOutputDeliveryLedger = AgentToolOutputDeliveryLedger()

    public init(log: EventLog,
                provider: ToolCallingProvider,
                registry: ToolRegistry,
                engine: PermissionEngine,
                responder: PermissionResponder,
                agent: Agent,
                context: ContextBuilder = ContextBuilder(),
                allowsShell: Bool,
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
                reasoningEffort: ReasoningEffort? = nil,
                includeUsage: Bool = false,
                modelContextPolicy: AgentModelContextPolicy = .unspecified,
                maxIterations: Int = 50,
                capabilityLease: CapabilityLease? = nil,
                workspaceLease: WorkspaceLease? = nil,
                rootTaskID: TaskID? = nil,
                taskAttempt: Int? = nil,
                executionScope: AgentExecutionScope? = nil,
                tokenBudgetMeter: AgentTokenBudgetMeter? = nil,
                authorizationPreparer: ToolAuthorizationPreparer? = nil,
                authorizationRevalidator: ToolAuthorizationRevalidator? = nil,
                toolSnapshotProvider: AgentRequestToolSnapshotProvider? = nil) {
        self.log = log
        self.provider = provider
        self.registry = registry
        self.engine = engine
        self.responder = responder
        self.agent = agent
        self.context = context
        self.allowsShell = allowsShell
        self.shell = shell
        self.terminal = terminal
        self.git = git
        self.messenger = messenger
        self.agentManager = agentManager
        self.workTaskManager = workTaskManager
        self.goalManager = goalManager
        self.runController = runController
        self.imageGenerator = imageGenerator
        self.imageResolver = imageResolver
        self.sessionNaming = sessionNaming
        self.reasoningEffort = reasoningEffort
        self.includeUsage = includeUsage
        self.modelContextPolicy = modelContextPolicy
        self.maxIterations = maxIterations
        self.capabilityLease = capabilityLease
        self.workspaceLease = workspaceLease
        self.rootTaskID = rootTaskID
        self.taskAttempt = taskAttempt
        self.executionScope = executionScope
        self.tokenBudgetMeter = tokenBudgetMeter
        self.authorizationPreparer = authorizationPreparer
        self.authorizationRevalidator = authorizationRevalidator
        self.toolSnapshotProvider = toolSnapshotProvider
    }

    /// Runs the loop and returns the agent's explicitly completed final answer.
    /// Exhausting the iteration limit is a terminal error, not an empty success.
    @discardableResult
    public func send(_ userText: String,
                     images: [ImageAttachment] = [],
                     userMessage: UserMessagePayload? = nil,
                     recordUserMessage: Bool = true,
                     submissionID: SubmissionID? = nil) async throws -> String {
        guard images.isEmpty else {
            throw AgentLoopError.mediaOutputInvalid(
                "Code and Cowork user images require exact-session artifact IDs")
        }
        // A first attempt uses the identity frozen at the user submission
        // boundary. Whole-task Retry is a distinct turn and must not create a
        // second terminal outcome under the prior TurnID.
        let turnID = (taskAttempt ?? 1) == 1
            ? (userMessage?.turnID ?? TurnID.new())
            : TurnID.new()
        let effectiveSubmissionID =
            submissionID
            ?? userMessage?.submissionID
            ?? (
                context.runtimeEnvironment.mode == .code
                    && context.conversationHistoryPolicy == .conversation
                    && recordUserMessage
                    ? SubmissionID.new()
                    : nil
            )
        await toolOutputDeliveryLedger.remove(turnID: turnID)
        let start = Date()
        var firstTokenAt: Date?
        var usage: Usage?
        var turnStatsAppended = false

        do {
        let modelHistoryScope = try modelHistoryRecordingScope(
            turnID: turnID,
            effectiveSubmissionID: effectiveSubmissionID)
        var recoveredModelHistoryEvents: [Envelope]?
        if modelHistoryScope != nil
            || (
                context.runtimeEnvironment.mode == .cowork
                    && context.taskContract?.id != nil
            )
        {
            // A missing/corrupt/unknown event must not be confused with a
            // shorter model history. Verify a complete sequence-zero snapshot
            // before this run adds any new events or asks a provider to
            // continue the task.
            let replay = try await log.replayForProjectionChecked()
            guard replay.hasCompleteKnownHistory else {
                throw EventLogError.unsupportedEventTypes
            }
            recoveredModelHistoryEvents = replay.envelopes
        } else {
            recoveredModelHistoryEvents = nil
        }
        var acceptedCurrentUserMessage = userMessage
        if recordUserMessage {
            var durableUserMessage = userMessage ?? UserMessagePayload(text: userText)
            if durableUserMessage.submissionID == nil {
                durableUserMessage.submissionID = effectiveSubmissionID
            }
            if durableUserMessage.turnID == nil {
                durableUserMessage.turnID = turnID
            }
            let appended = try await log.append(.userMessage(durableUserMessage))
            recoveredModelHistoryEvents?.append(appended)
            acceptedCurrentUserMessage = durableUserMessage
        }
        var modelHistoryProjection = try await projectedModelHistoryState(
            currentSubmissionID: effectiveSubmissionID,
            recoveredEvents: recoveredModelHistoryEvents)
        var history: [AgentMessage]
        if let projected = modelHistoryProjection {
            let materialized = try await materializeModelHistory(projected)
            modelHistoryProjection = materialized
            history = materialized.messages
        } else {
            history = try await projectedHistory(
                recoveredEvents: recoveredModelHistoryEvents,
                excludingCurrentAndLaterSubmissionsFrom:
                    effectiveSubmissionID)
        }
        var currentUserImages: [ImageAttachment] = []
        var currentUserImageReferences: [ModelHistoryImageReference]?
        let mcpTurnResultBudget =
            MCPToolResultAggregateBudget(
                scope: .turn,
                maximumBytes:
                    MCPToolResultAggregateLimits
                        .maximumTurnBytes)
        // Citation authority is intentionally request-local. Previous tool
        // results may be visible in history, but their evidence IDs are never
        // admitted into a new turn's registry.
        var groundingEvidence = TurnGroundingEvidenceRegistry()
        // Stable Code/Cowork main-thread history must measure the exact tool
        // surface that the first ordinary provider request will receive. Freeze
        // that request-owned snapshot before pre-turn compaction, then consume
        // the same value on the first loop iteration. A snapshot-resolution
        // failure therefore stops before current-turn model-history items are
        // committed and cannot fall back to the base registry.
        var frozenRequestToolSnapshot: AgentRequestToolSnapshot?
        let explicitSkillNeedsMCPAvailability =
            context
                .explicitSkillActivationRequiresMCPAvailability(
                    in: userText)
        if modelHistoryScope != nil
            || explicitSkillNeedsMCPAvailability {
            frozenRequestToolSnapshot = try await resolveToolSnapshot(
                outputBudget: mcpTurnResultBudget)
        }
        if modelHistoryScope != nil,
           let projection = modelHistoryProjection {
            let preTurnContext = context.initialMessages(
                history: history,
                userText: userText,
                includeCurrentUser: false,
                includeCurrentTurnContext: false)
            guard let frozenRequestToolSnapshot else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    "model-history-preturn-tools",
                    "stable main-thread tool snapshot is missing")
            }
            let preTurnTools = try providerToolSpecs(
                for: frozenRequestToolSnapshot)
            if try shouldCompact(
                messages: preTurnContext,
                tools: preTurnTools)
            {
                let compacted = try await compactModelHistory(
                    projection: projection,
                    summaryHistory: preTurnContext,
                    contextualReplacementMessages: [],
                    tools: preTurnTools)
                usage = Usage.adding(usage, compacted.usage)
                modelHistoryProjection = compacted.projection
                history = compacted.projection.messages
                recoveredModelHistoryEvents?.append(compacted.envelope)
            }
        }
        let resolvedSkillActivation =
            context.resolveExplicitSkillActivation(
                in: userText,
                mcpAvailability:
                    frozenRequestToolSnapshot?
                        .mcpAvailability
                        ?? .unavailable)
        if let modelHistoryScope {
            guard let recoveredEvents = recoveredModelHistoryEvents else {
                throw AgentModelHistoryProjectionError.missingAcceptedSubmission(
                    modelHistoryScope.submissionID)
            }
            acceptedCurrentUserMessage = try Self.acceptedUserMessage(
                for: modelHistoryScope.submissionID,
                agentID: agent.name,
                expectedText: userText,
                preferredPayload: acceptedCurrentUserMessage,
                events: recoveredEvents)
            let acceptedAttachmentIDs =
                acceptedCurrentUserMessage?.attachments ?? []
            if acceptedAttachmentIDs.isEmpty {
                currentUserImages = []
                currentUserImageReferences = nil
            } else {
                let resolved = try await materializeImages(
                    artifactIDs: acceptedAttachmentIDs,
                    expectedReferences: nil,
                    purpose: "current user input")
                currentUserImageReferences = resolved.references
            }
            var durableItems: [Event] = []
            if let explicitSkillContext =
                resolvedSkillActivation.prompt
            {
                durableItems.append(.modelHistoryItem(.message(
                    itemID:
                        "model-history-context-skill:\(turnID.rawValue)",
                    turnID: turnID,
                    agent: agent.name,
                    taskID: modelHistoryScope.taskID,
                    submissionID: modelHistoryScope.submissionID,
                    taskAttempt: modelHistoryScope.taskAttempt,
                    role: .user,
                    content: explicitSkillContext,
                    messageClassification: .contextual)))
            }
            durableItems.append(.modelHistoryItem(.message(
                itemID: "model-history-user:\(turnID.rawValue)",
                turnID: turnID,
                agent: agent.name,
                taskID: modelHistoryScope.taskID,
                submissionID: modelHistoryScope.submissionID,
                taskAttempt: modelHistoryScope.taskAttempt,
                    role: .user,
                    content: userText,
                    attachmentIDs: acceptedCurrentUserMessage?.attachments,
                    imageReferences: currentUserImageReferences,
                    messageClassification: .realUser)))
            let appendedItems = try await log.append(durableItems)
            recoveredModelHistoryEvents?.append(contentsOf: appendedItems)
            let userItemID = "model-history-user:\(turnID.rawValue)"
            guard let canonicalUserItem = appendedItems.compactMap({ envelope
                -> ModelHistoryItemPayload? in
                guard case .modelHistoryItem(let payload) = envelope.event,
                      payload.itemID == userItemID else {
                    return nil
                }
                return payload
            }).first,
            canonicalUserItem.attachmentIDs
                == acceptedCurrentUserMessage?.attachments,
            canonicalUserItem.imageReferences
                == currentUserImageReferences else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    userItemID,
                    "committed user media binding differs from the admitted artifact set")
            }
            let canonicalAttachmentIDs =
                canonicalUserItem.attachmentIDs ?? []
            if canonicalAttachmentIDs.isEmpty {
                currentUserImages = []
                currentUserImageReferences = nil
            } else {
                let readback = try await materializeImages(
                    artifactIDs: canonicalAttachmentIDs,
                    expectedReferences: canonicalUserItem.imageReferences,
                    purpose: "committed current user input")
                currentUserImages = readback.attachments
                currentUserImageReferences = readback.references
            }
            if var projection = modelHistoryProjection {
                projection.latestAgentHistorySequence =
                    appendedItems.last?.seq
                        ?? projection.latestAgentHistorySequence
                projection.realUserMessages.append(
                    AgentModelHistoryRealUserMessage(
                        content: userText,
                        submissionID: modelHistoryScope.submissionID,
                        attachmentIDs: canonicalUserItem.attachmentIDs,
                        imageReferences:
                            canonicalUserItem.imageReferences))
                modelHistoryProjection = projection
            }
        }
        if modelHistoryScope == nil,
           let attachmentIDs = acceptedCurrentUserMessage?.attachments,
           !attachmentIDs.isEmpty {
            let resolved = try await materializeImages(
                artifactIDs: attachmentIDs,
                expectedReferences: nil,
                purpose: "current user input")
            currentUserImages = resolved.attachments
            currentUserImageReferences = resolved.references
        }
        try await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .thinking)))

        var convo = context.initialMessages(
            history: history,
            userText: userText,
            userImages: currentUserImages,
            externalContexts:
                acceptedCurrentUserMessage?
                    .untrustedExternalContexts
                    ?? [],
            resolvedSkillActivation:
                resolvedSkillActivation)
        let denialCircuitBreaker = ToolDenialCircuitBreaker()
        var usedToolCallIDs = Set<String>()
        var syntheticToolCallOrdinal = 0

        for iteration in 0..<maxIterations {
            try Task.checkCancellation()
            let toolSnapshot: AgentRequestToolSnapshot
            if let frozen = frozenRequestToolSnapshot {
                toolSnapshot = frozen
                frozenRequestToolSnapshot = nil
            } else {
                toolSnapshot = try await resolveToolSnapshot(
                    outputBudget: mcpTurnResultBudget)
            }
            let specs = try providerToolSpecs(for: toolSnapshot)
            var assistantText = ""
            var pendingToolCalls: [ToolCall] = []
            var responseUsage: Usage?
            var receivedCompletionMarker = false
            var finishReason: String?
            let assistantID = MessageID.new()
            let providerGenerationID = IDGen.random(
                prefix: "provider-generation")

            let providerMessages = try providerMessages(for: convo)
            try validateRequestImageLimits(messages: providerMessages)
            var request = AgentRequest(model: agent.model, messages: providerMessages, tools: specs,
                                       reasoningEffort: reasoningEffort, includeUsage: includeUsage,
                                       parallelToolCalls:
                                        specs.contains(where: \.supportsParallelCalls)
                                            ? true
                                            : nil)
            let estimatedInputTokens = Self.estimatedInputTokens(request: request)
            // Cowork always supplies its one session-lifetime meter, including
            // while enforcement is disabled. A disabled meter returns a
            // tracking-only reservation with no output ceiling, so enabling a
            // budget cannot overlook an old in-flight request. The reservation
            // stays bound to the same actor across live policy changes.
            var pendingBudgetReservation: AgentTokenBudgetReservation?
            if let tokenBudgetMeter {
                pendingBudgetReservation = try await tokenBudgetMeter.reserve(
                    estimatedInputTokens: estimatedInputTokens)
            } else {
                pendingBudgetReservation = nil
            }
            request.maxOutputTokens = pendingBudgetReservation?.maxOutputTokens
            do {
                for try await chunk in provider.stream(request) {
                    try Task.checkCancellation()
                    switch chunk {
                    case .textDelta(let d):
                        if firstTokenAt == nil { firstTokenAt = Date() }
                        assistantText += d
                        try await log.append(.messageDelta(
                            MessageDeltaPayload(
                                messageId: assistantID,
                                role: .agent,
                                agent: agent.name,
                                textDelta: d,
                                submissionID: effectiveSubmissionID)))
                    case .toolCalls(let calls):
                        pendingToolCalls.append(contentsOf: calls)
                    case .usage(let u):
                        responseUsage = Usage.merging(responseUsage, with: u)
                    case .done(let reason):
                        receivedCompletionMarker = true
                        finishReason = reason ?? finishReason
                    }
                }
                // Cancellation can arrive after the provider has ended normally
                // but before accounting. Keep this check inside the reservation
                // lifecycle so that path cannot strand reserved capacity.
                try Task.checkCancellation()
                let summedReportedTokens = (responseUsage?.promptTokens ?? 0)
                    + (responseUsage?.completionTokens ?? 0)
                let reportedTokens = responseUsage?.totalTokens
                    ?? (summedReportedTokens > 0 ? summedReportedTokens : nil)
                let estimatedTokens = Self.estimatedTokens(
                    request: request,
                    assistantText: assistantText,
                    toolCalls: pendingToolCalls)
                let accountedUsage = reportedTokens == nil
                    ? Usage(totalTokens: estimatedTokens)
                    : responseUsage
                usage = Usage.adding(usage, accountedUsage)
                if let reservation = pendingBudgetReservation,
                   let tokenBudgetMeter {
                    // Take ownership before the actor hop. `settle` removes the
                    // reservation even when it reports an overrun, so a thrown
                    // exhaustion error must not trigger a second settlement.
                    pendingBudgetReservation = nil
                    try await tokenBudgetMeter.settle(
                        reservation,
                        reportedTokens: reportedTokens,
                        estimatedTokens: estimatedTokens)
                }
            } catch {
                if let reservation = pendingBudgetReservation,
                   let tokenBudgetMeter {
                    pendingBudgetReservation = nil
                    let partialEstimate = Self.estimatedTokens(
                        request: request,
                        assistantText: assistantText,
                        toolCalls: pendingToolCalls)
                    let summedReportedTokens = (responseUsage?.promptTokens ?? 0)
                        + (responseUsage?.completionTokens ?? 0)
                    let partialReportedTokens = responseUsage?.totalTokens
                        ?? (summedReportedTokens > 0 ? summedReportedTokens : nil)
                    usage = Usage.adding(
                        usage,
                        partialReportedTokens == nil
                            ? Usage(totalTokens: partialEstimate)
                            : responseUsage)
                    _ = try? await tokenBudgetMeter.settle(
                        reservation,
                        reportedTokens: partialReportedTokens,
                        estimatedTokens: partialEstimate)
                }
                throw error
            }

            guard receivedCompletionMarker else {
                throw AgentLoopError.responseEndedWithoutCompletionMarker
            }
            pendingToolCalls = Self.uniquedToolCalls(
                pendingToolCalls,
                usedCallIDs: &usedToolCallIDs,
                syntheticOrdinal: &syntheticToolCallOrdinal)
            pendingToolCalls = Self.normalizedToolCallKinds(
                pendingToolCalls,
                registry: toolSnapshot.registry)
            let permissionSessionID = await log.sessionID
            let usesAutomaticSidecars =
                context.runtimeEnvironment.mode == .cowork
                && responder.approvalMode == .automaticReviewer
            let preparedPermissionToolCalls = pendingToolCalls.map { call in
                if usesAutomaticSidecars {
                    return AuthorizationSidecarCodec.prepare(
                        call,
                        sessionID: permissionSessionID,
                        turnID: turnID,
                        taskID: context.taskContract?.id,
                        providerGenerationID: providerGenerationID,
                        registrySnapshotID: toolSnapshot.snapshotID)
                }
                if AuthorizationSidecarCodec.containsReservedField(
                    in: call.arguments) {
                    return PreparedPermissionToolCall(
                        providerCall: call,
                        executableCall: nil,
                        modelAuthorizationContext: nil,
                        sidecarStatus: .malformed(.unexpectedField(
                            AuthorizationSidecarCodec.reservedFieldName)),
                        canonicalBusinessArgumentsDigest: nil,
                        sidecarDigest: nil,
                        binding: nil)
                }
                return PreparedPermissionToolCall(
                    providerCall: call,
                    executableCall: call,
                    modelAuthorizationContext: nil,
                    sidecarStatus: .missing,
                    canonicalBusinessArgumentsDigest: nil,
                    sidecarDigest: nil,
                    binding: nil)
            }
            // Durable history, authorization, and execution use only the
            // sidecar-free call. The same in-memory acting-model conversation
            // may retain a validated non-secret sidecar so a successful call
            // remains a correct formatting example on the next iteration.
            // Invalid sidecars are never copied into either view.
            let liveConversationToolCalls = preparedPermissionToolCalls.map(
                Self.liveConversationHistoryCall)
            pendingToolCalls = preparedPermissionToolCalls.map(
                Self.sidecarFreeHistoryCall)
            if pendingToolCalls.isEmpty,
               Self.finishReasonRequiresToolCalls(finishReason) {
                throw AgentLoopError.completionExpectedToolCalls(
                    finishReason: finishReason ?? "tool_calls")
            }
            if let finishReason,
               !Self.finishReasonIsSuccessful(finishReason) {
                throw AgentLoopError.incompleteFinishReason(finishReason)
            }
            do {
                try await groundingEvidence.validateCitations(
                    in: assistantText,
                    requireAtLeastOne: pendingToolCalls.isEmpty)
            } catch {
                throw AgentLoopError.invalidEvidenceCitation(
                    RuntimeErrorPresentation.message(for: error))
            }

            var completedResponseEvents: [Event] = []
            if !assistantText.isEmpty {
                try Task.checkCancellation()
                completedResponseEvents.append(.messageCompleted(
                    MessageCompletedPayload(
                        messageId: assistantID,
                        role: .agent,
                        agent: agent.name,
                        text: assistantText,
                        submissionID: effectiveSubmissionID)))
            }
            if let modelHistoryScope {
                if pendingToolCalls.isEmpty {
                    completedResponseEvents.append(.modelHistoryItem(.message(
                        itemID: "model-history-assistant:\(assistantID.rawValue)",
                        turnID: modelHistoryScope.turnID,
                        agent: agent.name,
                        taskID: modelHistoryScope.taskID,
                        submissionID: modelHistoryScope.submissionID,
                        taskAttempt: modelHistoryScope.taskAttempt,
                        role: .assistant,
                        content: assistantText)))
                } else {
                    completedResponseEvents.append(
                        .modelHistoryItem(.functionCallBatch(
                            itemID: "model-history-assistant:\(assistantID.rawValue)",
                            turnID: modelHistoryScope.turnID,
                            agent: agent.name,
                            taskID: modelHistoryScope.taskID,
                            submissionID: modelHistoryScope.submissionID,
                            taskAttempt: modelHistoryScope.taskAttempt,
                            content: assistantText.isEmpty ? nil : assistantText,
                            calls: try modelHistoryFunctionCalls(
                                pendingToolCalls,
                                registry: toolSnapshot.registry))))
                }
            }
            if pendingToolCalls.isEmpty {
                await appendTurnStats(
                    start: start,
                    firstTokenAt: firstTokenAt,
                    usage: usage,
                    turnID: turnID,
                    responseMessageID: assistantID)
                turnStatsAppended = true
                completedResponseEvents.append(.agentStatus(AgentStatusPayload(
                    agent: agent.name,
                    state: .idle)))
                completedResponseEvents.append(.turnOutcome(TurnOutcomePayload(
                    turnID: turnID,
                    outcome: .completed,
                    submissionID: effectiveSubmissionID,
                    taskID: context.taskContract?.id,
                    agentID: agent.name)))
                try Task.checkCancellation()
                // Final transcript/model-history publication and the
                // authoritative successful turn terminal are one EventLog
                // transaction.
                try await log.append(completedResponseEvents)
                await toolOutputDeliveryLedger.remove(turnID: turnID)
                return assistantText  // final answer
            }

            if !completedResponseEvents.isEmpty {
                try Task.checkCancellation()
                try await log.append(completedResponseEvents)
            }

            convo.append(.assistant(
                toolCalls: liveConversationToolCalls,
                content: assistantText.isEmpty ? nil : assistantText))
            let observations = try await runToolCalls(
                preparedPermissionToolCalls,
                turnID: turnID,
                denialCircuitBreaker: denialCircuitBreaker,
                modelHistoryScope: modelHistoryScope,
                registry: toolSnapshot.registry,
                mcpAvailability:
                    toolSnapshot.mcpAvailability)
            for (toolCall, observation) in zip(pendingToolCalls, observations) {
                try Task.checkCancellation()
                do {
                    try groundingEvidence.record(
                        toolName: toolCall.name,
                        observation: observation,
                        revalidator: toolSnapshot.registry
                            .registration(named: toolCall.name)?
                            .groundingEvidenceRevalidator)
                } catch {
                    throw AgentLoopError.invalidEvidenceCitation(
                        RuntimeErrorPresentation.message(for: error))
                }
                guard let delivered = await toolOutputDeliveryLedger.take(
                    turnID: turnID,
                    callID: toolCall.id),
                delivered.role == .tool,
                delivered.toolCallId == toolCall.id else {
                    throw AgentLoopError.mediaOutputInvalid(
                        "committed tool output was not materialized for call \(toolCall.id)")
                }
                convo.append(delivered)
            }
            // Resolve the exact tool surface for the next ordinary provider
            // request before deciding whether its input requires compaction.
            // The same request-owned snapshot is frozen for the next loop
            // iteration, so neither the trigger nor the 95% replacement
            // postcondition can race a dynamic catalog refresh. The final
            // allowed tool iteration has no continuation request to prepare.
            guard iteration + 1 < maxIterations else {
                continue
            }
            try Task.checkCancellation()
            let nextToolSnapshot = try await resolveToolSnapshot(
                outputBudget: mcpTurnResultBudget)
            let nextSpecs = try providerToolSpecs(for: nextToolSnapshot)
            frozenRequestToolSnapshot = nextToolSnapshot
            if modelHistoryScope != nil,
               var projection = modelHistoryProjection,
               try shouldCompact(messages: convo, tools: nextSpecs)
            {
                let replay = try await log.replayForProjectionChecked()
                guard replay.hasCompleteKnownHistory else {
                    throw EventLogError.unsupportedEventTypes
                }
                projection.latestAgentHistorySequence =
                    Self.latestModelHistorySequence(
                        agentID: agent.name,
                        events: replay.envelopes)
                let currentContexts =
                    context.currentTurnContextMessages(
                        userText: userText,
                        externalContexts:
                            acceptedCurrentUserMessage?
                                .untrustedExternalContexts
                                ?? [],
                        resolvedSkillActivation:
                            resolvedSkillActivation)
                let compacted = try await compactModelHistory(
                    projection: projection,
                    summaryHistory: convo,
                    contextualReplacementMessages:
                        currentContexts,
                    tools: nextSpecs)
                usage = Usage.adding(usage, compacted.usage)
                modelHistoryProjection = compacted.projection
                recoveredModelHistoryEvents?.append(compacted.envelope)
                // The replacement already contains the canonical current-turn
                // context and real user immediately before its final summary.
                // Rebuild only fresh trusted system/developer instructions.
                convo = context.initialMessages(
                    history: compacted.projection.messages,
                    userText: userText,
                    includeCurrentUser: false,
                    includeCurrentTurnContext: false)
            }
        }

        try Task.checkCancellation()
        await appendTurnStats(
            start: start,
            firstTokenAt: firstTokenAt,
            usage: usage,
            turnID: turnID)
        turnStatsAppended = true
        throw AgentLoopError.maxIterationsExceeded(limit: maxIterations)
        } catch {
            await toolOutputDeliveryLedger.remove(turnID: turnID)
            // AgentLoop owns the single terminal error event for failures that
            // occur after entering the loop. Callers should propagate/classify
            // the thrown error, not append a second copy of the same event.
            if !turnStatsAppended {
                await appendTurnStats(
                    start: start,
                    firstTokenAt: firstTokenAt,
                    usage: usage,
                    turnID: turnID)
            }
            let interruption = Self.turnInterruption(for: error)
            if interruption == nil {
                _ = try? await log.append(.error(Self.terminalErrorPayload(
                    for: error,
                    submissionID: effectiveSubmissionID)))
            }
            _ = try? await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .idle)))
            _ = try? await log.append(.turnOutcome(TurnOutcomePayload(
                turnID: turnID,
                outcome: interruption == nil ? .failed : .interrupted,
                failureSource: interruption?.failureSource ?? .runtimeFailed,
                reason: Self.boundedTurnReason(error.localizedDescription),
                submissionID: effectiveSubmissionID,
                taskID: context.taskContract?.id,
                agentID: agent.name)))
            throw error
        }
    }

    private func resolveToolSnapshot(
        outputBudget: MCPToolResultAggregateBudget
    ) async throws -> AgentRequestToolSnapshot {
        if let toolSnapshotProvider {
            return try await toolSnapshotProvider(
                provider.toolCallingCapabilities,
                outputBudget)
        }
        return AgentRequestToolSnapshot(registry: registry)
    }

    private func providerToolSpecs(
        for snapshot: AgentRequestToolSnapshot
    ) throws -> [ToolSpec] {
        let specs = snapshot.providerToolSpecs
            ?? context.toolSpecs(snapshot.registry)
        guard context.runtimeEnvironment.mode == .cowork,
              responder.approvalMode == .automaticReviewer else {
            return specs
        }
        return try AuthorizationSidecarCodec.decorate(specs)
    }

    /// Returns the exact request-owned message copy used for provider token
    /// estimation and dispatch. Durable/in-memory history remains sidecar-free;
    /// automatic Cowork decorates only deferred functions embedded in
    /// `tool_search_output` items.
    private func providerMessages(
        for messages: [AgentMessage]
    ) throws -> [AgentMessage] {
        guard context.runtimeEnvironment.mode == .cowork,
              responder.approvalMode == .automaticReviewer else {
            return messages
        }
        return try AuthorizationSidecarCodec
            .decorateProviderMessages(messages)
    }

    private func modelHistoryRecordingScope(
        turnID: TurnID,
        effectiveSubmissionID: SubmissionID?
    ) throws -> ModelHistoryRecordingScope? {
        if context.conversationHistoryPolicy == .conversation,
           context.runtimeEnvironment.mode == .code {
            guard let submissionID = effectiveSubmissionID else {
                // Host-only control probes may intentionally bypass durable
                // user-message recording. They keep the legacy ephemeral Code
                // behavior and cannot create a provenance-bearing checkpoint.
                return nil
            }
            return ModelHistoryRecordingScope(
                turnID: turnID,
                taskID: nil,
                submissionID: submissionID,
                taskAttempt: 1)
        }

        guard context.conversationHistoryPolicy == .coworkMainThread else {
            return nil
        }
        guard context.runtimeEnvironment.mode == .cowork,
              let contract = context.taskContract,
              contract.kind == .root,
              contract.issuer == nil,
              contract.assignee == agent.name,
              let submissionID = contract.submissionID,
              effectiveSubmissionID == submissionID else {
            throw AgentModelHistoryProjectionError.invalidItem(
                "model-history-user:\(turnID.rawValue)",
                "Cowork main-thread recording lacks one exact root task/submission/agent binding")
        }
        let attempt = taskAttempt ?? 1
        guard attempt >= 1 else {
            throw AgentModelHistoryProjectionError.invalidItem(
                "model-history-user:\(turnID.rawValue)",
                "taskAttempt must be one-based")
        }
        return ModelHistoryRecordingScope(
            turnID: turnID,
            taskID: contract.id,
            submissionID: submissionID,
            taskAttempt: attempt)
    }

    private func materializeImages(
        artifactIDs: [ArtifactID],
        expectedReferences: [ModelHistoryImageReference]?,
        purpose: String
    ) async throws -> AgentMaterializedImages {
        guard !artifactIDs.isEmpty else {
            guard expectedReferences?.isEmpty != false else {
                throw AgentLoopError.mediaOutputInvalid(
                    "\(purpose) has descriptors but no artifact IDs")
            }
            return AgentMaterializedImages(
                references: [],
                attachments: [])
        }
        guard let imageResolver else {
            throw AgentLoopError.mediaOutputInvalid(
                "\(purpose) requires the exact-session artifact resolver")
        }
        let resolved = try await imageResolver(artifactIDs)
        guard resolved.count == artifactIDs.count,
              zip(resolved, artifactIDs).allSatisfy({
                  $0.artifactID == $1
              }) else {
            throw AgentLoopError.mediaOutputInvalid(
                "\(purpose) resolved a different artifact set or order")
        }
        let references = resolved.map { image in
            ModelHistoryImageReference(
                artifactID: image.artifactID,
                mimeType: image.mimeType,
                byteCount: image.byteCount,
                sha256: image.sha256)
        }
        for reference in references {
            do {
                try reference.validate()
            } catch {
                throw AgentLoopError.mediaOutputInvalid(
                    "\(purpose) produced a non-canonical image descriptor")
            }
        }
        if let expectedReferences,
           references != expectedReferences {
            throw AgentLoopError.mediaOutputInvalid(
                "\(purpose) bytes no longer match the durable image descriptor")
        }
        return AgentMaterializedImages(
            references: references,
            attachments: resolved.map(\.attachment))
    }

    private func materializeModelHistory(
        _ projection: AgentModelHistoryProjection
    ) async throws -> AgentModelHistoryProjection {
        guard projection.messages.count == projection.imageBindings.count else {
            throw AgentModelHistoryProjectionError.invalidItem(
                "model-history-media",
                "projected image bindings are not aligned with provider messages")
        }

        var flattenedIDs: [ArtifactID] = []
        for binding in projection.imageBindings {
            switch binding {
            case .userVerified(let references),
                 .toolVerified(_, let references):
                flattenedIDs.append(contentsOf: references.map(\.artifactID))
            case .userLegacy(let artifactIDs):
                flattenedIDs.append(contentsOf: artifactIDs)
            case nil:
                continue
            }
        }
        guard !flattenedIDs.isEmpty else { return projection }

        let allImages = try await materializeImages(
            artifactIDs: flattenedIDs,
            expectedReferences: nil,
            purpose: "projected model history")
        var result = projection
        var offset = 0
        for index in result.messages.indices {
            guard let binding = result.imageBindings[index] else { continue }
            let count: Int
            let expected: [ModelHistoryImageReference]?
            switch binding {
            case .userVerified(let references):
                count = references.count
                expected = references
                guard result.messages[index].role == .user else {
                    throw AgentModelHistoryProjectionError.invalidItem(
                        "model-history-media-\(index)",
                        "user image binding is attached to a non-user message")
                }
            case .userLegacy(let artifactIDs):
                count = artifactIDs.count
                expected = nil
                guard result.messages[index].role == .user else {
                    throw AgentModelHistoryProjectionError.invalidItem(
                        "model-history-media-\(index)",
                        "legacy image binding is attached to a non-user message")
                }
            case .toolVerified(let callID, let references):
                count = references.count
                expected = references
                guard result.messages[index].role == .tool,
                      result.messages[index].toolCallId == callID else {
                    throw AgentModelHistoryProjectionError.invalidItem(
                        "model-history-media-\(index)",
                        "tool image binding does not match its function call")
                }
            }
            let end = offset + count
            guard end <= allImages.references.count else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    "model-history-media-\(index)",
                    "projected image binding exceeds the resolved artifact set")
            }
            let references = Array(allImages.references[offset..<end])
            if let expected, references != expected {
                throw AgentLoopError.mediaOutputInvalid(
                    "projected history bytes no longer match their durable descriptors")
            }
            guard result.messages[index].images.isEmpty else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    "model-history-media-\(index)",
                    "projected provider message already contains image wire data")
            }
            result.messages[index].images =
                Array(allImages.attachments[offset..<end])
            if case .userLegacy(let artifactIDs) = binding {
                result.imageBindings[index] = .userVerified(references)
                for userIndex in result.realUserMessages.indices
                where result.realUserMessages[userIndex].imageReferences == nil
                    && result.realUserMessages[userIndex].attachmentIDs
                        == artifactIDs
                {
                    result.realUserMessages[userIndex].imageReferences =
                        references
                }
            }
            offset = end
        }
        guard offset == allImages.references.count else {
            throw AgentModelHistoryProjectionError.invalidItem(
                "model-history-media",
                "resolved image set was not consumed exactly once")
        }
        return result
    }

    private func validateRequestImageLimits(
        messages: [AgentMessage]
    ) throws {
        let policy = ArtifactImageValidationPolicy()
        let capabilities = provider.toolCallingCapabilities
        if messages.contains(where: {
            $0.role != .tool && !$0.images.isEmpty
        }), !capabilities.supportsUserImageInput {
            throw AgentLoopError.mediaOutputUnsupported(
                "the exact provider route does not accept user images")
        }
        if messages.contains(where: {
            $0.role == .tool && !$0.images.isEmpty
        }), !capabilities.supportsFunctionOutputImageInput {
            throw AgentLoopError.mediaOutputUnsupported(
                "the exact provider route does not accept function-output images")
        }
        let images = messages.flatMap(\.images)
        guard images.count <= policy.maximumImageCount else {
            throw ArtifactImageResolutionError.tooManyImages(
                maximum: policy.maximumImageCount,
                actual: images.count)
        }
        var totalBytes = 0
        for image in images {
            guard image.url.hasPrefix("data:"),
                  let comma = image.url.firstIndex(of: ","),
                  image.url[..<comma].hasSuffix(";base64") else {
                throw AgentLoopError.mediaOutputInvalid(
                    "request images must use base64 data URLs")
            }
            let payload = image.url[image.url.index(after: comma)...]
            let maximumEncodedBytes =
                ((policy.maximumImageBytes + 2) / 3) * 4 + 2
            guard payload.utf8.count <= maximumEncodedBytes else {
                throw ArtifactImageResolutionError.imageByteLimitExceeded(
                    ArtifactID(rawValue: "request-image"),
                    maximumBytes: policy.maximumImageBytes)
            }
            guard let decoded = Data(base64Encoded: String(payload)) else {
                throw AgentLoopError.mediaOutputInvalid(
                    "request image data URL contains invalid base64")
            }
            let decodedBytes = decoded.count
            guard decodedBytes <= policy.maximumImageBytes else {
                throw ArtifactImageResolutionError.imageByteLimitExceeded(
                    ArtifactID(rawValue: "request-image"),
                    maximumBytes: policy.maximumImageBytes)
            }
            totalBytes += decodedBytes
            guard totalBytes <= policy.maximumTotalBytes else {
                throw ArtifactImageResolutionError.totalByteLimitExceeded(
                    maximumBytes: policy.maximumTotalBytes)
            }
        }
    }

    private func shouldCompact(
        messages: [AgentMessage],
        tools: [ToolSpec]
    ) throws -> Bool {
        guard context.conversationHistoryPolicy != .taskScoped,
              let limit =
                modelContextPolicy
                    .automaticCompactionTriggerTokens else {
            return false
        }
        let exactProviderMessages = try providerMessages(for: messages)
        return AgentTokenEstimator.approximateInputTokens(
            messages: exactProviderMessages,
            tools: tools) >= limit
    }

    private func compactModelHistory(
        projection: AgentModelHistoryProjection,
        summaryHistory: [AgentMessage],
        contextualReplacementMessages: [AgentMessage],
        tools: [ToolSpec]
    ) async throws -> (
        projection: AgentModelHistoryProjection,
        usage: Usage?,
        envelope: Envelope
    ) {
        let providerSummaryHistory = try providerMessages(
            for: summaryHistory)
        try validateRequestImageLimits(messages: providerSummaryHistory)
        let maximumReplacementInputTokens: Int?
        if let hardLimit =
            modelContextPolicy.hardUsableContextWindowTokens {
            let fixedPrefix = context.initialMessages(
                history: [],
                userText: "",
                includeCurrentUser: false,
                includeCurrentTurnContext: false)
            let reservedTokens =
                AgentTokenEstimator.approximateInputTokens(
                    messages: try providerMessages(
                        for: fixedPrefix
                            + contextualReplacementMessages),
                    tools: tools)
            let available = hardLimit - reservedTokens
            guard available > 0 else {
                throw AgentModelHistoryCompactionError
                    .replacementBudgetUnavailable(limit: hardLimit)
            }
            maximumReplacementInputTokens = available
        } else {
            maximumReplacementInputTokens = nil
        }

        let result = try await AgentModelHistoryCompactor(
            provider: provider,
            model: agent.model,
            reasoningEffort: reasoningEffort,
            includeUsage: includeUsage,
            tokenBudgetMeter: tokenBudgetMeter)
            .compact(
                history: providerSummaryHistory,
                realUserMessages: projection.realUserMessages,
                mediaAwareCheckpointRequired:
                    projection.latestCheckpoint?.payload.schemaVersion
                        == ModelHistoryCompactedPayload.mediaSchemaVersion,
                maximumReplacementInputTokens:
                    maximumReplacementInputTokens)

        var replacement = result.replacementHistory
        var providerHistory = result.providerHistory
        if !contextualReplacementMessages.isEmpty {
            guard let insertionIndex = replacement.lastIndex(where: {
                $0.messageClassification == .realUser
            }),
            contextualReplacementMessages.allSatisfy({
                $0.role == .user
                    && $0.content != nil
                    && $0.toolCalls == nil
                    && $0.toolCallId == nil
                    && $0.images.isEmpty
                    && $0.toolSearchOutput == nil
            }) else {
                throw AgentModelHistoryCompactionError
                    .invalidContextualReplacement
            }
            let contextualItems = contextualReplacementMessages.map {
                ModelHistoryReplacementItem(
                    itemID:
                        "model-history-compacted-context:\(UUID().uuidString.lowercased())",
                    kind: .message,
                    role: .user,
                    messageClassification: .contextual,
                    content: $0.content)
            }
            replacement.insert(
                contentsOf: contextualItems,
                at: insertionIndex)
            providerHistory.insert(
                contentsOf: contextualReplacementMessages,
                at: insertionIndex)
        }

        if let hardLimit =
            modelContextPolicy.hardUsableContextWindowTokens {
            let replacementRequestMessages =
                context.initialMessages(
                    history: providerHistory,
                    userText: "",
                    includeCurrentUser: false,
                    includeCurrentTurnContext: false)
            let estimated =
                AgentTokenEstimator.approximateInputTokens(
                    messages: try providerMessages(
                        for: replacementRequestMessages),
                    tools: tools)
            guard estimated <= hardLimit else {
                throw AgentModelHistoryCompactionError
                    .replacementExceedsUsableContext(
                        estimated: estimated,
                        limit: hardLimit)
            }
        }

        let windowNumber: UInt64
        let firstWindowID: String
        let previousWindowID: String
        if let latest = projection.latestCheckpoint {
            let (next, overflow) =
                latest.payload.windowNumber.addingReportingOverflow(1)
            guard !overflow else {
                throw AgentModelHistoryCompactionError
                    .windowNumberExhausted
            }
            windowNumber = next
            firstWindowID = latest.payload.firstWindowID
            previousWindowID = latest.payload.windowID
        } else {
            windowNumber = 1
            let initial = AgentModelHistoryWindowID.new()
            firstWindowID = initial
            previousWindowID = initial
        }
        var windowID = AgentModelHistoryWindowID.new()
        while windowID == previousWindowID
            || windowID == firstWindowID
        {
            windowID = AgentModelHistoryWindowID.new()
        }
        let checkpoint = ModelHistoryCompactedPayload(
            schemaVersion: result.checkpointSchemaVersion,
            agent: agent.name,
            message: result.message,
            replacementHistory: replacement,
            windowNumber: windowNumber,
            firstWindowID: firstWindowID,
            previousWindowID: previousWindowID,
            windowID: windowID)
        let envelope = try await log.appendModelHistoryCompaction(
            checkpoint,
            expectedLatestAgentHistorySeq:
                projection.latestAgentHistorySequence)
        guard case .modelHistoryCompacted(let committedCheckpoint) =
                envelope.event else {
            throw AgentModelHistoryProjectionError.invalidItem(
                "model-history-compacted:\(envelope.seq)",
                "compaction append did not return its canonical checkpoint")
        }
        let cursor = AgentModelHistoryCheckpointCursor(
            sequence: envelope.seq,
            payload: committedCheckpoint)
        var replacementProjection = try AgentModelHistoryProjector()
            .projectReplacementState(committedCheckpoint)
        replacementProjection.baseCheckpoint = cursor
        replacementProjection.latestCheckpoint = cursor
        replacementProjection.latestAgentHistorySequence = envelope.seq
        replacementProjection = try await materializeModelHistory(
            replacementProjection)
        return (
            replacementProjection,
            result.usage,
            envelope)
    }

    private static func latestModelHistorySequence(
        agentID: AgentID,
        events: [Envelope]
    ) -> Int? {
        events.compactMap { envelope -> Int? in
            switch envelope.event {
            case .modelHistoryItem(let payload)
                where payload.agent == agentID:
                return envelope.seq
            case .modelHistoryCompacted(let payload)
                where payload.agent == agentID:
                return envelope.seq
            default:
                return nil
            }
        }.max()
    }

    private static func acceptedUserMessage(
        for submissionID: SubmissionID,
        agentID: AgentID,
        expectedText: String,
        preferredPayload: UserMessagePayload?,
        events: [Envelope]
    ) throws -> UserMessagePayload {
        let candidates = events.compactMap { envelope -> UserMessagePayload? in
            guard case .userMessage(let payload) = envelope.event,
                  payload.submissionID == submissionID else {
                return nil
            }
            return payload
        }
        guard let durable = candidates.first else {
            throw AgentModelHistoryProjectionError.missingAcceptedSubmission(
                submissionID)
        }
        guard candidates.dropFirst().allSatisfy({ $0 == durable }),
              preferredPayload.map({ $0 == durable }) ?? true else {
            throw AgentModelHistoryProjectionError.conflictingAcceptedSubmission(
                submissionID)
        }
        guard durable.text == expectedText,
              durable.to == nil || durable.to == agentID else {
            throw AgentModelHistoryProjectionError.invalidItem(
                "model-history-user:\(submissionID.rawValue)",
                "provider input does not exactly match the accepted submission")
        }
        return durable
    }

    private static func turnInterruption(
        for error: Error
    ) -> (failureSource: ExecutionFailureSource, reason: String)? {
        if let interrupted = error as? AgentTurnInterruptedError {
            return (interrupted.failureSource, interrupted.reason)
        }
        if IntatisCancellation.isCurrentTaskCancellation(error) {
            return (.turnCancelled, "Turn cancelled")
        }
        return nil
    }

    private static func boundedTurnReason(_ reason: String) -> String {
        PermissionReviewTextSanitizer.sanitizeDiagnostic(
            reason,
            maxCharacters: 500).text
    }

    private static func finishReasonRequiresToolCalls(_ finishReason: String?) -> Bool {
        guard let finishReason else { return false }
        switch finishReason.lowercased() {
        case "tool_calls", "function_call":
            return true
        default:
            return false
        }
    }

    private static func finishReasonIsSuccessful(_ finishReason: String) -> Bool {
        switch finishReason.lowercased() {
        case "stop", "end_turn", "completed", "complete", "tool_calls", "function_call":
            return true
        default:
            return false
        }
    }

    private static func terminalErrorPayload(
        for error: Error,
        submissionID: SubmissionID? = nil
    ) -> ErrorPayload {
        if IntatisCancellation.isCancellationSignal(error) {
            return ErrorPayload(
                code: "runtime_failed",
                message: "The provider or runtime ended with an unexpected cancellation signal.",
                submissionID: submissionID)
        }
        if error is AgentExecutionBudgetError {
            return ErrorPayload(
                code: "token_budget_exhausted",
                message: error.localizedDescription,
                submissionID: submissionID)
        }
        if let imageError = error as? ArtifactImageResolutionError {
            return ErrorPayload(
                code: imageError.code,
                message: imageError.localizedDescription,
                submissionID: submissionID)
        }
        if let capabilityError =
            error as? ToolCallingProviderCapabilityError
        {
            let code: String
            switch capabilityError {
            case .toolSearchUnsupported:
                code = "tool_search_unsupported"
            case .userImageInputUnsupported:
                code = "user_image_input_unsupported"
            case .functionOutputImageInputUnsupported:
                code = "media_output_unsupported"
            }
            return ErrorPayload(
                code: code,
                message: capabilityError.localizedDescription,
                submissionID: submissionID)
        }
        guard let loopError = error as? AgentLoopError else {
            var payload = RuntimeErrorPresentation.payload(for: error, fallbackCode: "agent")
            payload.submissionID = submissionID
            return payload
        }
        let code: String
        switch loopError {
        case .maxIterationsExceeded:
            code = "max_iterations"
        case .responseEndedWithoutCompletionMarker:
            code = "incomplete_completion"
        case .completionExpectedToolCalls:
            code = "incomplete_tool_calls"
        case .incompleteFinishReason:
            code = "incomplete_response"
        case .repeatedDeniedToolCall:
            code = "repeated_denied_tool_call"
        case .invalidEvidenceCitation:
            code = "invalid_evidence_citation"
        case .mediaOutputUnsupported:
            code = "media_output_unsupported"
        case .mediaOutputInvalid:
            code = "media_output_invalid"
        }
        return ErrorPayload(
            code: code,
            message: loopError.localizedDescription,
            submissionID: submissionID)
    }

    private static func estimatedTokens(request: AgentRequest,
                                        assistantText: String,
                                        toolCalls: [ToolCall]) -> Int {
        AgentTokenEstimator.approximateTotalTokens(
            request: request,
            assistantText: assistantText,
            toolCalls: toolCalls)
    }

    private static func estimatedInputTokens(request: AgentRequest) -> Int {
        AgentTokenEstimator.approximateInputTokens(
            messages: request.messages,
            tools: request.tools)
    }

    private func workspaceLeaseFailure(intent: PermissionIntent,
                                       touchedPaths: [String]) -> String? {
        guard let lease = workspaceLease else { return nil }
        guard let rootIdentity = lease.rootIdentity else {
            return "workspace lease has no stable root identity; reattach the workspace"
        }
        guard rootIdentity.matchesCurrentDirectory(rootPath: lease.rootPath) else {
            return "workspace root changed after the lease was granted; reattach the workspace"
        }
        let leaseRoot = URL(fileURLWithPath: lease.rootPath).standardizedFileURL
        let agentRoot = agent.workspaceRoot.standardizedFileURL
        guard leaseRoot.path == agentRoot.path else {
            return "workspace lease root does not match the agent workspace"
        }
        if lease.access == .readOnly, !intent.isReadOnlyWorkspaceCompatible {
            return "workspace lease is read-only"
        }
        for path in touchedPaths {
            let resolved: URL
            do {
                resolved = try PathConfinement.resolve(path, within: leaseRoot)
            } catch {
                return "path is outside the workspace lease: \(path)"
            }
            let relative = Self.relativePath(resolved, root: leaseRoot)
            let mandatoryDenied = WorkspaceLease
                .mandatoryManagedStoreDeniedPatterns
            if (lease.deniedPatterns + mandatoryDenied).contains(where: {
                Self.path(relative.lowercased(), matches: $0.lowercased())
            }) {
                return "path is denied by the workspace lease: \(relative)"
            }
            let allowed = lease.allowedPathRules.contains { rule in
                rule.pattern == "." || Self.path(relative, matches: rule.pattern)
            }
            if !allowed {
                return "path is outside the workspace lease allow-list: \(relative)"
            }
        }
        return nil
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path != rootPath else { return "." }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func path(_ path: String, matches pattern: String) -> Bool {
        let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")
        let normalizedPattern = pattern.replacingOccurrences(of: "\\", with: "/")
        if !normalizedPattern.contains("/") {
            return normalizedPath.split(separator: "/").contains {
                glob(String($0), matches: normalizedPattern)
            }
        }
        return glob(normalizedPath, matches: normalizedPattern)
    }

    private static func glob(_ value: String, matches pattern: String) -> Bool {
        var expression = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    let afterStars = pattern.index(after: next)
                    if afterStars < pattern.endIndex, pattern[afterStars] == "/" {
                        // `**/name` also matches `name` at the workspace root.
                        expression += "(?:.*/)?"
                        index = pattern.index(after: afterStars)
                    } else {
                        expression += ".*"
                        index = afterStars
                    }
                    continue
                }
                expression += "[^/]*"
            } else if character == "?" {
                expression += "[^/]"
            } else {
                expression += NSRegularExpression.escapedPattern(for: String(character))
            }
            index = pattern.index(after: index)
        }
        expression += "$"
        guard let regex = try? NSRegularExpression(pattern: expression) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }

    private func appendTurnStats(
        start: Date,
        firstTokenAt: Date?,
        usage: Usage?,
        turnID: TurnID,
        responseMessageID: MessageID? = nil
    ) async {
        let now = Date()
        _ = try? await log.append(.turnStats(TurnStatsPayload(
            promptTokens: usage?.promptTokens,
            cachedPromptTokens: usage?.cachedPromptTokens,
            completionTokens: usage?.completionTokens,
            totalTokens: usage?.totalTokens,
            contextWindowTokens: usage?.contextWindowTokens,
            ttftMillis: firstTokenAt.map { Int($0.timeIntervalSince(start) * 1000) },
            totalMillis: Int(now.timeIntervalSince(start) * 1000),
            model: agent.model.rawValue,
            turnID: turnID,
            responseMessageID: responseMessageID,
            goalID: executionScope?.goalID ?? context.taskContract?.goalID,
            continuationRunID: executionScope?.continuationRunID ?? context.taskContract?.continuationRunID,
            workTaskID: executionScope?.workTaskID ?? context.taskContract?.workTaskID,
            invocationTaskID: executionScope?.invocationTaskID ?? rootTaskID ?? context.taskContract?.id,
            agentID: executionScope?.agentID ?? agent.name,
            agentInferenceBinding: context.taskContract?.agentInferenceBinding
                ?? agent.agentInferenceBinding)))
    }

    // MARK: - Tool execution with permission

    private func runToolCalls(
                              _ preparedCalls: [PreparedPermissionToolCall],
                              turnID: TurnID,
                              denialCircuitBreaker: ToolDenialCircuitBreaker,
                              modelHistoryScope: ModelHistoryRecordingScope?,
                              registry: ToolRegistry,
                              mcpAvailability:
                                MCPToolAvailabilitySnapshot) async throws
        -> [ToolObservation] {
        let parallelCollaborationTools = Set(["ask_agent", "delegate_task"])
        guard preparedCalls.count > 1,
              preparedCalls.allSatisfy({
                  parallelCollaborationTools.contains($0.providerCall.name)
              }) else {
            var results: [ToolObservation] = []
            results.reserveCapacity(preparedCalls.count)
            for preparedCall in preparedCalls {
                try Task.checkCancellation()
                let observation = try await runTool(
                    preparedCall,
                    turnID: turnID,
                    denialCircuitBreaker: denialCircuitBreaker,
                    modelHistoryScope: modelHistoryScope,
                    registry: registry,
                    mcpAvailability:
                        mcpAvailability)
                results.append(observation)
            }
            return results
        }

        return try await withThrowingTaskGroup(
            of: (Int, ToolObservation).self,
            returning: [ToolObservation].self
        ) { group in
            for (index, preparedCall) in preparedCalls.enumerated() {
                group.addTask {
                    let observation = try await runTool(
                        preparedCall,
                        turnID: turnID,
                        denialCircuitBreaker: denialCircuitBreaker,
                        modelHistoryScope: modelHistoryScope,
                        registry: registry,
                        mcpAvailability:
                            mcpAvailability)
                    return (index, observation)
                }
            }
            var indexed: [(Int, ToolObservation)] = []
            indexed.reserveCapacity(preparedCalls.count)
            for try await result in group { indexed.append(result) }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func appendingModelHistoryToolOutput(
        to events: [Event],
        toolCall: ToolCall,
        canonicalOutput: AgentCanonicalToolOutput,
        toolSearchOutput: ModelToolSearchOutput?,
        scope: ModelHistoryRecordingScope?
    ) -> [Event] {
        guard let scope else { return events }
        if toolCall.kind == .toolSearch {
            let output = toolSearchOutput
                ?? ModelToolSearchOutput(
                    execution: toolCall.execution ?? "client",
                    tools: [])
            return events + [.modelHistoryItem(.toolSearchOutput(
                itemID:
                    "model-history-output:\(scope.turnID.rawValue):\(toolCall.id)",
                turnID: scope.turnID,
                agent: agent.name,
                taskID: scope.taskID,
                submissionID: scope.submissionID,
                taskAttempt: scope.taskAttempt,
                callID: toolCall.id,
                status: output.status,
                execution: output.execution,
                tools: output.tools))]
        }
        return events + [.modelHistoryItem(.functionCallOutput(
            itemID: "model-history-output:\(scope.turnID.rawValue):\(toolCall.id)",
            turnID: scope.turnID,
            agent: agent.name,
            taskID: scope.taskID,
            submissionID: scope.submissionID,
            taskAttempt: scope.taskAttempt,
            callID: toolCall.id,
            output: canonicalOutput.output,
            imageReferences:
                canonicalOutput.imageReferences.isEmpty
                    ? nil
                    : canonicalOutput.imageReferences))]
    }

    private func appendToolCompletion(
        _ events: [Event],
        toolCall: ToolCall,
        observation: String,
        toolSearchOutput: ModelToolSearchOutput? = nil,
        modelHistoryScope: ModelHistoryRecordingScope?
    ) async throws {
        let turnID = events.compactMap { event -> TurnID? in
            guard case .toolResult(let payload) = event,
                  payload.toolCallId == toolCall.id else {
                return nil
            }
            return payload.turnID
        }.first ?? modelHistoryScope?.turnID

        if toolCall.kind == .toolSearch {
            let output = toolSearchOutput
                ?? ModelToolSearchOutput(
                    execution: toolCall.execution ?? "client",
                    tools: [])
            let canonical = AgentCanonicalToolOutput(
                output: "",
                imageReferences: [])
            let appended = try await log.append(
                appendingModelHistoryToolOutput(
                    to: events,
                    toolCall: toolCall,
                    canonicalOutput: canonical,
                    toolSearchOutput: output,
                    scope: modelHistoryScope))
            let committedOutput: ModelToolSearchOutput
            if modelHistoryScope != nil {
                guard let payload = appended.compactMap({ envelope
                    -> ModelHistoryItemPayload? in
                    guard case .modelHistoryItem(let payload) =
                            envelope.event,
                          payload.kind == .toolSearchOutput,
                          payload.callID == toolCall.id else {
                        return nil
                    }
                    return payload
                }).first,
                let durableOutput = payload.toolSearchOutput else {
                    throw AgentLoopError.mediaOutputInvalid(
                        "committed tool-search output is missing")
                }
                committedOutput = durableOutput
            } else {
                committedOutput = output
            }
            guard let turnID else {
                throw AgentLoopError.mediaOutputInvalid(
                    "committed tool-search output has no TurnID")
            }
            await toolOutputDeliveryLedger.record(
                .toolSearchOutput(
                    id: toolCall.id,
                    output: committedOutput),
                turnID: turnID,
                callID: toolCall.id)
            return
        }

        let proposedResults = events.compactMap { event
            -> ToolResultPayload? in
            guard case .toolResult(let payload) = event,
                  payload.toolCallId == toolCall.id else {
                return nil
            }
            return payload
        }
        guard proposedResults.count == 1,
              let proposedResult = proposedResults.first,
              proposedResult.observation == observation else {
            throw AgentLoopError.mediaOutputInvalid(
                "tool completion must contain one exact matching tool result")
        }

        let proposedOutput: AgentCanonicalToolOutput
        do {
            proposedOutput = try AgentCanonicalToolOutput.lower(
                structuredResult: proposedResult.structuredResult,
                legacyObservation: proposedResult.observation)
        } catch let loweringError as AgentToolOutputLoweringError {
            let fallback = AgentCanonicalToolOutput(
                output:
                    "[media delivery unavailable: \(loweringError.stableCode)]",
                imageReferences: [])
            _ = try await log.append(appendingModelHistoryToolOutput(
                to: events,
                toolCall: toolCall,
                canonicalOutput: fallback,
                toolSearchOutput: nil,
                scope: modelHistoryScope))
            switch loweringError {
            case .unsupportedMedia:
                throw AgentLoopError.mediaOutputUnsupported(
                    loweringError.localizedDescription)
            case .invalidBlock, .canonicalJSON:
                throw AgentLoopError.mediaOutputInvalid(
                    loweringError.localizedDescription)
            }
        }

        let appended = try await log.append(
            appendingModelHistoryToolOutput(
                to: events,
                toolCall: toolCall,
                canonicalOutput: proposedOutput,
                toolSearchOutput: nil,
                scope: modelHistoryScope))
        let committedResults = appended.compactMap { envelope
            -> ToolResultPayload? in
            guard case .toolResult(let payload) = envelope.event,
                  payload.toolCallId == toolCall.id else {
                return nil
            }
            return payload
        }
        guard committedResults.count == 1,
              let committedResult = committedResults.first else {
            throw AgentLoopError.mediaOutputInvalid(
                "committed completion lost its exact tool result")
        }
        guard committedResult.observation == proposedResult.observation,
              committedResult.structuredResult
                == proposedResult.structuredResult else {
            throw AgentLoopError.mediaOutputInvalid(
                "committed tool output differs from its completion batch")
        }
        let committedOutput: AgentCanonicalToolOutput
        do {
            committedOutput = try AgentCanonicalToolOutput.lower(
                structuredResult: committedResult.structuredResult,
                legacyObservation: committedResult.observation)
        } catch let loweringError as AgentToolOutputLoweringError {
            throw AgentLoopError.mediaOutputInvalid(
                "committed tool output cannot be lowered: \(loweringError.stableCode)")
        }
        var deliveryOutput = committedOutput
        if modelHistoryScope != nil {
            let durableOutputs = appended.compactMap { envelope
                -> ModelHistoryItemPayload? in
                guard case .modelHistoryItem(let payload) = envelope.event,
                      payload.kind == .functionCallOutput,
                      payload.callID == toolCall.id else {
                    return nil
                }
                return payload
            }
            guard durableOutputs.count == 1,
                  durableOutputs[0].output == committedOutput.output,
                  (durableOutputs[0].imageReferences ?? [])
                    == committedOutput.imageReferences,
                  let durableText = durableOutputs[0].output else {
                throw AgentLoopError.mediaOutputInvalid(
                    "durable function output is not bound to the canonical tool result")
            }
            deliveryOutput = AgentCanonicalToolOutput(
                output: durableText,
                imageReferences:
                    durableOutputs[0].imageReferences ?? [])
        }

        let attachments: [ImageAttachment]
        if deliveryOutput.imageReferences.isEmpty {
            attachments = []
        } else {
            guard provider.toolCallingCapabilities
                    .supportsFunctionOutputImageInput else {
                throw AgentLoopError.mediaOutputUnsupported(
                    "the exact provider route does not accept function-output images")
            }
            do {
                attachments = try await materializeImages(
                    artifactIDs:
                        deliveryOutput.imageReferences.map(\.artifactID),
                    expectedReferences:
                        deliveryOutput.imageReferences,
                    purpose: "tool output \(toolCall.id)")
                    .attachments
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AgentLoopError.mediaOutputInvalid(
                    RuntimeErrorPresentation.message(for: error))
            }
        }
        guard let turnID else {
            throw AgentLoopError.mediaOutputInvalid(
                "committed tool output has no TurnID")
        }
        await toolOutputDeliveryLedger.record(
            .tool(
                id: toolCall.id,
                content: deliveryOutput.output,
                images: attachments),
            turnID: turnID,
            callID: toolCall.id)
    }

    private func runTool(
                         _ preparedCall: PreparedPermissionToolCall,
                         turnID: TurnID,
                         denialCircuitBreaker: ToolDenialCircuitBreaker,
                         modelHistoryScope: ModelHistoryRecordingScope?,
                         registry: ToolRegistry,
                         mcpAvailability:
                            MCPToolAvailabilitySnapshot) async throws
        -> ToolObservation {
        try Task.checkCancellation()
        let toolCall = Self.sidecarFreeHistoryCall(preparedCall)

        if preparedCall.executableCall == nil,
           case .malformed(.unexpectedField(let field)) =
                preparedCall.sidecarStatus,
           field == AuthorizationSidecarCodec.reservedFieldName {
            let safeToolName = PermissionReviewTextSanitizer
                .sanitizeDiagnostic(
                    toolCall.name,
                    maxCharacters: 128).text
            try await appendDurableToolCall(
                toolCall,
                canonicalName: safeToolName,
                validatedArguments: nil,
                forceRedaction: true)
            let signature =
                "authorization-sidecar-mode-mismatch\u{001F}\(toolCall.name)"
            if let repeatedAttempt = await denialCircuitBreaker
                .noteRepeatedAttempt(signature: signature),
               repeatedAttempt >= 3 {
                throw AgentLoopError.repeatedDeniedToolCall(
                    tool: toolCall.name)
            }
            let message =
                "authorization_context_mode_mismatch: \(AuthorizationSidecarCodec.reservedFieldName) is host-reserved for Cowork automatic review and is not a business tool argument in this mode"
            try await appendToolCompletion(
                [.toolResult(ToolResultPayload(
                    toolCallId: toolCall.id,
                    observation: message,
                    outcome: .failed,
                    failureSource: .runtimeFailed,
                    turnID: turnID))],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: signature)
            return ToolObservation(text: message)
        }

        guard let registration = registry.registration(named: toolCall.name) else {
            let safeUnknownToolName = PermissionReviewTextSanitizer.sanitizeDiagnostic(
                toolCall.name,
                maxCharacters: 128).text
            try await appendDurableToolCall(
                toolCall,
                canonicalName: safeUnknownToolName,
                validatedArguments: nil,
                forceRedaction: true)
            let denialSignature = "unknown\u{001F}\(toolCall.name)\u{001F}\(toolCall.arguments.trimmingCharacters(in: .whitespacesAndNewlines))"
            if let repeatedAttempt = await denialCircuitBreaker.noteRepeatedAttempt(
                signature: denialSignature),
               repeatedAttempt >= 3 {
                throw AgentLoopError.repeatedDeniedToolCall(tool: toolCall.name)
            }
            let available = registry.descriptors().map(\.name).sorted().joined(separator: ", ")
            let message = available.isEmpty
                ? "unknown tool: \(safeUnknownToolName)"
                : "unknown tool: \(safeUnknownToolName). Available tools: \(available)"
            try await appendToolCompletion(
                [.toolResult(ToolResultPayload(
                    toolCallId: toolCall.id,
                    observation: message,
                    outcome: .failed,
                    failureSource: .runtimeFailed,
                    turnID: turnID))],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            return ToolObservation(text: message)
        }

        let descriptor = registration.descriptor
        let effectiveWorkspaceRoot = workspaceLease.map { URL(fileURLWithPath: $0.rootPath) }
            ?? agent.workspaceRoot
        let normalizedArguments: String
        switch normalizeToolArguments(
            toolCall.arguments,
            registration: registration,
            descriptor: descriptor) {
        case .valid(let arguments):
            normalizedArguments = arguments
            try await appendDurableToolCall(
                toolCall,
                canonicalName: descriptor.name,
                validatedArguments: arguments,
                forceRedaction: Self.redactsDurableArguments(for: descriptor.name))
        case .invalid(let message):
            let invalidObservation = registration
                .argumentValidationFailure(message: message)
                ?? ToolObservation(text: message)
            try await appendDurableToolCall(
                toolCall,
                canonicalName: descriptor.name,
                validatedArguments: nil,
                forceRedaction: true)
            let denialSignature = "invalid\u{001F}\(descriptor.name)\u{001F}\(toolCall.arguments.trimmingCharacters(in: .whitespacesAndNewlines))"
            if let repeatedAttempt = await denialCircuitBreaker.noteRepeatedAttempt(
                signature: denialSignature),
               repeatedAttempt >= 3 {
                throw AgentLoopError.repeatedDeniedToolCall(tool: descriptor.name)
            }
            try await appendToolCompletion(
                [.toolResult(ToolResultPayload(
                    toolCallId: toolCall.id,
                    observation: invalidObservation.text,
                    truncated: invalidObservation.truncated,
                    outcome: .failed,
                    failureSource: .runtimeFailed,
                    turnID: turnID,
                    structuredResult: invalidObservation.structuredResult,
                    provenance: invalidObservation.structuredResult?.content
                        .compactMap(\.provenance)
                        .first))],
                toolCall: toolCall,
                observation: invalidObservation.text,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            return invalidObservation
        }

        let args = ToolArgs(raw: normalizedArguments)
        let touchedPaths = registration.touchedPaths(args)
        let baseIntent = registration.permissionIntent(
            args,
            workspaceRoot: effectiveWorkspaceRoot)
        let risksNetwork = registration.risksNetwork(args)
        if descriptor.name == "rename_session",
           Self.sessionRenameContainsSecret(normalizedArguments) {
            let reason = "the proposed session name appears to contain a secret"
            let message = Self.permissionDeniedMessage(reason)
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        turnID: turnID,
                        toolCallID: toolCall.id,
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .high,
                        reason: reason,
                        intent: baseIntent,
                        source: .deterministicPolicy,
                        failureSource: .policyDenied)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .policyDenied,
                        turnID: turnID)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(
                signature: descriptor.name + "\u{001F}" + normalizedArguments)
            return ToolObservation(text: message)
        }
        let sessionID = await log.sessionID
        let authorizationInvocation = ToolAuthorizationInvocationContext(
            sessionID: sessionID,
            agent: agent.name,
            taskID: context.taskContract?.id,
            rootTaskID: rootTaskID,
            parentTaskID: context.taskContract?.parentTaskID,
            attempt: taskAttempt,
            toolCallID: toolCall.id,
            taskObjective: context.taskContract.map {
                String($0.objective.prefix(1_200))
            })
        let denialSignature = descriptor.name + "\u{001F}" + normalizedArguments
        if let repeatedAttempt = await denialCircuitBreaker.noteRepeatedAttempt(
            signature: denialSignature) {
            let reason = "identical tool call was already denied in this agent run"
            let message = Self.permissionDeniedMessage(reason)
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .medium,
                        reason: reason,
                        intent: baseIntent,
                        source: .deterministicPolicy,
                        failureSource: .policyDenied)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .policyDenied,
                        turnID: turnID)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            if repeatedAttempt >= 3 {
                throw AgentLoopError.repeatedDeniedToolCall(tool: descriptor.name)
            }
            return ToolObservation(text: message)
        }

        let authorizationID = IDGen.random(prefix: "tool-authorization")
        let preparation: ToolAuthorizationPreparation
        do {
            if let authorizationPreparer {
                preparation = try await authorizationPreparer(
                    ToolAuthorizationPreparationRequest(
                        authorizationID: authorizationID,
                        toolName: descriptor.name,
                        normalizedArguments: normalizedArguments,
                        baseIntent: baseIntent,
                        invocation: authorizationInvocation))
            } else {
                preparation = ToolAuthorizationPreparation(intent: baseIntent)
            }
        } catch {
            let reason = "authorization preflight failed: \(error.localizedDescription)"
            let message = Self.permissionDeniedMessage(reason)
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .high,
                        reason: reason,
                        intent: baseIntent,
                        source: .authorizationRevalidation,
                        failureKind: .authorizationSnapshotInvalid,
                        failureSource: .policyDenied)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .policyDenied,
                        turnID: turnID)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            return ToolObservation(text: message)
        }
        let intent = preparation.intent

        var authorization: ResolvedToolAuthorization
        do {
            authorization = try registry.resolveAuthorization(
                toolName: descriptor.name,
                intent: intent,
                risksNetwork: risksNetwork,
                normalizedArguments: normalizedArguments,
                authorizationID: authorizationID,
                invocation: authorizationInvocation,
                capabilityLease: capabilityLease,
                workspaceLease: workspaceLease,
                targetAgentInferenceBinding: preparation.targetAgentInferenceBinding)
        } catch {
            let reason = error.localizedDescription
            let message = Self.permissionDeniedMessage(reason)
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .high,
                        reason: reason,
                        intent: intent,
                        source: .authorizationRevalidation,
                        failureKind: .authorizationSnapshotInvalid,
                        failureSource: .policyDenied)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .policyDenied,
                        turnID: turnID)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(
                signature: descriptor.name + "\u{001F}" + normalizedArguments)
            return ToolObservation(text: message)
        }
        if let leaseFailure = workspaceLeaseFailure(
            intent: intent,
            touchedPaths: touchedPaths) {
            let message = Self.permissionDeniedMessage(leaseFailure)
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .high,
                        reason: leaseFailure,
                        intent: intent,
                        authorization: authorization,
                        source: .deterministicPolicy,
                        failureSource: .policyDenied)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .policyDenied,
                        turnID: turnID)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            return ToolObservation(text: message)
        }
        let callContext = ToolCallContext(
            toolName: descriptor.name,
            sideEffect: descriptor.sideEffect,
            touchedPaths: touchedPaths,
            risksNetwork: risksNetwork,
            rawArgs: normalizedArguments,
            intent: intent)
        let effectiveProfile: PermissionProfile = workspaceLease?.access == .readOnly
            ? .readOnly
            : agent.profile
        let permissionContext = PermissionContext(
            workspaceRoot: effectiveWorkspaceRoot,
            profile: effectiveProfile,
            allowsShell: allowsShell,
            agent: agent.name)

        let engineDecision = await engine.decideDetailed(callContext, permissionContext)
        authorization = authorization.withDeterministicGate(
            Self.gateSnapshot(engineDecision.gate))
        if context.runtimeEnvironment.mode == .cowork,
           responder.approvalMode == .automaticReviewer,
           engineDecision.reviewerConsulted {
            let reason =
                "cowork automatic review configuration invoked an in-engine reviewer; the bound control-plane review is required"
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        turnID: turnID,
                        toolCallID: toolCall.id,
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .high,
                        reason: reason,
                        intent: intent,
                        authorization: authorization,
                        source: .automaticReviewerFailure,
                        reviewStatus: .failed,
                        failureKind: .reviewerContractViolation,
                        failureSource: .reviewerFailed)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: reason,
                        outcome: .denied,
                        failureSource: .reviewerFailed,
                        turnID: turnID)),
                ],
                toolCall: toolCall,
                observation: reason,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(
                signature: denialSignature)
            return ToolObservation(text: reason)
        }
        let outcome = MCPApprovalInteractionPolicy.decide(
            engineDecision: engineDecision,
            authorization: authorization,
            responderMode: responder.approvalMode)
        if outcome.decision != .deny,
           let authorizationFailure = await authorizationRevalidationFailure(
            authorization,
            registry: registry,
            toolName: descriptor.name,
            normalizedArguments: normalizedArguments,
            intent: intent,
            risksNetwork: risksNetwork,
            invocation: authorizationInvocation
           ) {
            let message = Self.permissionDeniedMessage(authorizationFailure)
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .high,
                        reason: authorizationFailure,
                        intent: intent,
                        authorization: authorization,
                        source: .authorizationRevalidation,
                        failureKind: .authorizationSnapshotInvalid,
                        failureSource: .policyDenied)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .policyDenied,
                        turnID: turnID)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            return ToolObservation(text: message)
        }
        try Task.checkCancellation()
        var reviewInvocation: PermissionReviewInvocationInput?
        let needsAutomaticReviewEvidence = outcome.decision == .askUser
            && context.runtimeEnvironment.mode == .cowork
            && responder.approvalMode == .automaticReviewer
        if needsAutomaticReviewEvidence {
            if let sidecarFailure = Self.authorizationSidecarFailureMessage(
                preparedCall.sidecarStatus) {
                // The reviewer has not run. A missing or malformed sidecar is
                // an acting-model tool-input contract error, not a permission
                // denial or reviewer failure. Return an actionable tool result
                // and let a corrected call with the same business arguments
                // reach the reviewer without spending its denial fuse.
                try await appendToolCompletion(
                    [.toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: sidecarFailure,
                        outcome: .failed,
                        failureSource: .runtimeFailed,
                        turnID: turnID))],
                    toolCall: toolCall,
                    observation: sidecarFailure,
                    modelHistoryScope: modelHistoryScope)
                return ToolObservation(text: sidecarFailure)
            }
            let canonicalContext = preparedCall.modelAuthorizationContext
                .flatMap {
                    AuthorizationSidecarCodec
                        .canonicalAuthorizationContext($0)
                }
            let binding = preparedCall.binding
            let canonicalBusinessArgumentsDigest =
                ToolRegistry.authorizationDigest(normalizedArguments)
            let secretBearingBusinessArguments = descriptor.name == "write_stdin"
                || SecretScanner.containsSecret(normalizedArguments)
                || PermissionReviewTextSanitizer.containsSensitiveMaterial(
                    normalizedArguments)
            var evidenceFailure: String?
            var evidenceFailureKind:
                PermissionApprovalFailureKind =
                    .authorizationContextUnavailable
            if secretBearingBusinessArguments {
                evidenceFailure =
                    "review_input_secret_bearing: automatic review requires opaque credential references and cannot receive plaintext secret-bearing business arguments"
            } else if let canonicalContext,
                      let binding,
                      let sidecarDigest = binding.sidecarDigest,
                      binding.sessionID == sessionID,
                      binding.turnID == turnID,
                      binding.taskID == context.taskContract?.id,
                      binding.toolCallID == toolCall.id,
                      binding.toolName == descriptor.name,
                      binding.canonicalBusinessArgumentsDigest
                        == canonicalBusinessArgumentsDigest {
                reviewInvocation = PermissionReviewInvocationInput(
                    sessionID: binding.sessionID,
                    turnID: binding.turnID,
                    taskID: binding.taskID,
                    toolCallID: binding.toolCallID,
                    toolName: binding.toolName,
                    sourceGenerationID: binding.providerGenerationID,
                    toolSnapshotID: binding.registrySnapshotID,
                    canonicalBusinessArguments: normalizedArguments,
                    businessArgumentsDigest:
                        canonicalBusinessArgumentsDigest,
                    businessArgumentsCharacterCount:
                        normalizedArguments.count,
                    modelAuthorizationContextJSON: canonicalContext,
                    modelAuthorizationContextDigest: sidecarDigest)
                evidenceFailure = nil
            } else {
                evidenceFailure =
                    "authorization_context_binding_invalid: regenerate the exact business call; its sidecar could not be bound to this action"
                evidenceFailureKind = .authorizationSnapshotInvalid
            }

            if let evidenceFailure {
                try await appendToolCompletion(
                    [
                        .permissionResolved(PermissionResolvedPayload(
                            turnID: turnID,
                            toolCallID: toolCall.id,
                            tool: descriptor.name,
                            decision: .deny,
                            risk: outcome.risk,
                            reason: evidenceFailure,
                            intent: intent,
                            authorization: authorization,
                            source: .automaticReviewerFailure,
                            reviewStatus: .failed,
                            failureKind: evidenceFailureKind,
                            failureSource: .reviewerFailed)),
                        .toolResult(ToolResultPayload(
                            toolCallId: toolCall.id,
                            observation: evidenceFailure,
                            outcome: .denied,
                            failureSource: .reviewerFailed,
                            turnID: turnID)),
                    ],
                    toolCall: toolCall,
                    observation: evidenceFailure,
                    modelHistoryScope: modelHistoryScope)
                await denialCircuitBreaker.recordDenial(
                    signature: denialSignature,
                    permitsOneFreshReview: true)
                return ToolObservation(text: evidenceFailure)
            }
        }
        let executionID = IDGen.random(prefix: "tool-execution")
        let replayPolicy = intent.replayPolicy
        let settled = try await settle(outcome,
                                       descriptor: descriptor,
                                       toolCall: ToolCall(id: toolCall.id,
                                                          name: toolCall.name,
                                                          arguments: normalizedArguments),
                                       turnID: turnID,
                                       callContext: callContext,
                                       authorization: authorization,
                                       executionID: executionID,
                                       replayPolicy: replayPolicy,
                                       reviewInvocation: reviewInvocation)
        try Task.checkCancellation()

        guard settled.decision == .allow else {
            let message = Self.permissionDeniedMessage(settled.reason)
            try await appendToolCompletion(
                [.toolResult(ToolResultPayload(
                    toolCallId: toolCall.id,
                    observation: message,
                    outcome: .denied,
                    failureSource: settled.failureSource ?? .policyDenied,
                    turnID: turnID,
                    permissionRequestID: settled.requestID))],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(
                signature: denialSignature,
                permitsOneFreshReview: settled.permitsOneFreshReview)
            return ToolObservation(text: message)
        }

        if let authorizationFailure = await authorizationRevalidationFailure(
            authorization,
            registry: registry,
            toolName: descriptor.name,
            normalizedArguments: normalizedArguments,
            intent: intent,
            risksNetwork: risksNetwork,
            invocation: authorizationInvocation
        ) {
            let message = Self.permissionDeniedMessage(authorizationFailure)
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .high,
                        reason: authorizationFailure,
                        intent: intent,
                        authorization: authorization,
                        source: .authorizationRevalidation,
                        failureKind: .authorizationSnapshotInvalid,
                        failureSource: .policyDenied)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .policyDenied,
                        turnID: turnID)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            return ToolObservation(text: message)
        }

        // Permission review can be arbitrarily slow. Revalidate the pinned
        // workspace identity after that await boundary so an approved action
        // cannot be redirected into a replacement directory at the same path.
        if let leaseFailure = workspaceLeaseFailure(
            intent: intent,
            touchedPaths: callContext.touchedPaths) {
            let message = Self.permissionDeniedMessage(leaseFailure)
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .high,
                        reason: leaseFailure,
                        intent: intent,
                        authorization: authorization,
                        source: .authorizationRevalidation,
                        failureKind: .authorizationSnapshotInvalid,
                        failureSource: .policyDenied)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .policyDenied,
                        turnID: turnID)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            return ToolObservation(text: message)
        }

        try Task.checkCancellation()
        try await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .tool)))
        let prepared = ToolExecutionPreparedPayload(
            executionID: executionID,
            taskID: context.taskContract?.id,
            attempt: modelHistoryScope?.taskAttempt ?? taskAttempt,
            toolCallID: toolCall.id,
            agent: agent.name,
            tool: descriptor.name,
            sideEffect: descriptor.sideEffect,
            intent: intent,
            authorization: authorization,
            replayPolicy: replayPolicy)
        // This record is the durable boundary: if it cannot be written, the
        // executor is never invoked. An interrupted non-replayable call blocks
        // automatic replay of the old task attempt.
        try await log.append(.toolExecutionPrepared(prepared))

        if let authorizationFailure = await authorizationRevalidationFailure(
            authorization,
            registry: registry,
            toolName: descriptor.name,
            normalizedArguments: normalizedArguments,
            intent: intent,
            risksNetwork: risksNetwork,
            invocation: authorizationInvocation
        ) {
            let message = Self.permissionDeniedMessage(authorizationFailure)
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .high,
                        reason: authorizationFailure,
                        intent: intent,
                        authorization: authorization,
                        source: .authorizationRevalidation,
                        failureKind: .authorizationSnapshotInvalid,
                        failureSource: .policyDenied)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .policyDenied,
                        turnID: turnID)),
                    .toolExecutionSettled(ToolExecutionSettledPayload(
                        prepared: prepared,
                        outcome: .denied,
                        effectDisposition: .notStarted,
                        reason: authorizationFailure)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            return ToolObservation(text: message)
        }

        // The durable prepare append is another suspension point. Check once
        // more immediately before entering the executor. If the root changed,
        // settle the unused ticket explicitly; no side effect has run.
        if let leaseFailure = workspaceLeaseFailure(
            intent: intent,
            touchedPaths: callContext.touchedPaths) {
            let message = Self.permissionDeniedMessage(leaseFailure)
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .high,
                        reason: leaseFailure,
                        intent: intent,
                        authorization: authorization,
                        source: .authorizationRevalidation,
                        failureKind: .authorizationSnapshotInvalid,
                        failureSource: .policyDenied)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .policyDenied,
                        turnID: turnID)),
                    .toolExecutionSettled(ToolExecutionSettledPayload(
                        prepared: prepared,
                        outcome: .denied,
                        effectDisposition: .notStarted,
                        reason: leaseFailure)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            return ToolObservation(text: message)
        }

        let toolContext = ToolContext(workspaceRoot: effectiveWorkspaceRoot,
                                      workspaceLease: workspaceLease,
                                      shell: shell,
                                      terminal: terminal,
                                      git: git,
                                      messenger: messenger,
                                      agentManager: agentManager,
                                      workTaskManager: workTaskManager,
                                      goalManager: goalManager,
                                      runController: runController,
                                      imageGenerator: imageGenerator,
                                      sessionNaming: sessionNaming,
                                      executionID: executionID,
                                      mcpAvailability:
                                        mcpAvailability,
                                      authorization: authorization)
        let observation: ToolObservation
        do {
            try Task.checkCancellation()
        } catch is CancellationError {
            let message = "tool cancelled before execution started"
            try await appendToolCompletion(
                [
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .failed,
                        failureSource: .turnCancelled,
                        turnID: turnID)),
                    .toolExecutionSettled(ToolExecutionSettledPayload(
                        prepared: prepared,
                        outcome: .cancelled,
                        effectDisposition: .notStarted,
                        reason: message)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            throw CancellationError()
        }
        do {
            observation = try await registration.execute(args, in: toolContext)
        } catch is CancellationError {
            let message = "tool cancelled after execution started"
            try await appendToolCompletion(
                [
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .failed,
                        failureSource: .turnCancelled,
                        turnID: turnID)),
                    .toolExecutionSettled(ToolExecutionSettledPayload(
                        prepared: prepared,
                        outcome: .cancelled,
                        effectDisposition: .unknown,
                        reason: message)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            throw CancellationError()
        } catch let denial as WorkspaceSandboxDeniedError {
            let underlying = RuntimeErrorPresentation.message(for: denial)
            let message = "sandbox denied tool execution: \(underlying)"
            // The managed runner emits this type only for an attributable
            // wrapper-startup denial, before the target executable is entered.
            // That is a durable no-effect fact, but it is not a reason to
            // retry the command or widen its sandbox authority.
            try await appendToolCompletion(
                [
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .sandboxDenied,
                        turnID: turnID)),
                    .toolExecutionSettled(ToolExecutionSettledPayload(
                        prepared: prepared,
                        outcome: .denied,
                        effectDisposition: .notStarted,
                        reason: message)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            return ToolObservation(text: message)
        } catch let rejection as ToolExecutionRejectedWithoutSideEffect {
            let message = "tool error: \(rejection.message)"
            try await appendToolCompletion(
                [
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .failed,
                        failureSource: .runtimeFailed,
                        turnID: turnID)),
                    .toolExecutionSettled(ToolExecutionSettledPayload(
                        prepared: prepared,
                        outcome: .failed,
                        effectDisposition: .notStarted,
                        reason: message)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            return ToolObservation(text: message)
        } catch {
            let underlying = RuntimeErrorPresentation.message(for: error)
            let message = "tool error: \(underlying)"
            try await appendToolCompletion(
                [
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .failed,
                        failureSource: .runtimeFailed,
                        turnID: turnID)),
                    .toolExecutionSettled(ToolExecutionSettledPayload(
                        prepared: prepared,
                        outcome: .failed,
                        effectDisposition: .unknown,
                        reason: message)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            return ToolObservation(text: message)
        }

        if observation.structuredResult?.isError == true {
            let reason = "MCP server reported tool execution failure"
            try await appendToolCompletion(
                [
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: observation.text,
                        truncated: observation.truncated,
                        outcome: .failed,
                        failureSource: .runtimeFailed,
                        turnID: turnID,
                        structuredResult: observation.structuredResult,
                        provenance: observation.structuredResult?.content
                            .compactMap(\.provenance)
                            .first)),
                    .toolExecutionSettled(ToolExecutionSettledPayload(
                        prepared: prepared,
                        outcome: .failed,
                        effectDisposition: .unknown,
                        reason: reason)),
                ],
                toolCall: toolCall,
                observation: observation.text,
                modelHistoryScope: modelHistoryScope)
            // MCP `isError` is a typed tool failure, not proof that a remote
            // effect never crossed its commit boundary. The durable unknown
            // disposition prevents replay of that old execution while the
            // model can continue from the failed tool result in this turn.
            try Task.checkCancellation()
            return observation
        }

        var completionEvents: [Event] = []
        if let diff = observation.diff, let files = observation.changedFiles {
            completionEvents.append(.patchProposed(PatchProposedPayload(
                patchId: IDGen.random(prefix: "patch"), agent: agent.name, files: files, diff: diff)))
        }
        completionEvents.append(.toolResult(ToolResultPayload(
            toolCallId: toolCall.id,
            observation: observation.text,
            truncated: observation.truncated,
            outcome: .succeeded,
            turnID: turnID,
            structuredResult: observation.structuredResult,
            provenance: observation.structuredResult?.content
                .compactMap(\.provenance)
                .first)))
        completionEvents.append(.toolExecutionSettled(ToolExecutionSettledPayload(
            prepared: prepared,
            outcome: .succeeded,
            effectDisposition: .committed)))
        try await appendToolCompletion(
            completionEvents,
            toolCall: toolCall,
            observation: observation.text,
            toolSearchOutput: observation.toolSearchOutput,
            modelHistoryScope: modelHistoryScope)
        // Persist completed execution before surfacing a concurrent cancel.
        try Task.checkCancellation()
        return observation
    }

    /// Provider call IDs are opaque correlation keys, but some compatible
    /// endpoints omit them and the wire adapter historically falls back to
    /// `call_0` for each response. Keep a provider-supplied ID when it is unique
    /// within this AgentLoop turn; otherwise rewrite both the assistant call and
    /// its later tool output to one deterministic turn-local ID.
    private static func uniquedToolCalls(
        _ calls: [ToolCall],
        usedCallIDs: inout Set<String>,
        syntheticOrdinal: inout Int
    ) -> [ToolCall] {
        calls.map { call in
            if !call.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               usedCallIDs.insert(call.id).inserted {
                return call
            }

            var candidate: String
            repeat {
                candidate = "call_\(IntatisHostApplication.identity.fieldNameStem)_\(syntheticOrdinal)"
                syntheticOrdinal += 1
            } while !usedCallIDs.insert(candidate).inserted
            return ToolCall(
                id: candidate,
                name: call.name,
                arguments: call.arguments,
                kind: call.kind,
                namespace: call.namespace,
                status: call.status,
                execution: call.execution)
        }
    }

    /// The immutable request snapshot is authoritative for model-facing call
    /// kinds. This also upgrades a Chat-compatible `tool_search` function-call
    /// shape into the native history kind without trusting a mutable catalog.
    private static func normalizedToolCallKinds(
        _ calls: [ToolCall],
        registry: ToolRegistry
    ) -> [ToolCall] {
        calls.map { call in
            guard let descriptor =
                    registry.registration(named: call.name)?.descriptor else {
                return call
            }
            let kind: ToolCallKind = descriptor.modelSpecKind == .toolSearch
                ? .toolSearch
                : .function
            return ToolCall(
                id: call.id,
                name: call.name,
                arguments: call.arguments,
                kind: kind,
                namespace: call.namespace,
                status: call.status,
                execution: kind == .toolSearch
                    ? (call.execution ?? "client")
                    : call.execution)
        }
    }

    private static func sidecarFreeHistoryCall(
        _ prepared: PreparedPermissionToolCall
    ) -> ToolCall {
        if let executableCall = prepared.executableCall {
            return executableCall
        }
        let providerCall = prepared.providerCall
        return ToolCall(
            id: providerCall.id,
            name: providerCall.name,
            arguments: redactedArgumentsJSON,
            kind: providerCall.kind,
            namespace: providerCall.namespace,
            status: providerCall.status,
            execution: providerCall.execution)
    }

    /// Keeps a validated, non-secret same-generation sidecar only in the
    /// current acting model's in-memory conversation. Durable model history,
    /// EventLog, authorization identity, and the executor continue to use the
    /// stripped call above.
    private static func liveConversationHistoryCall(
        _ prepared: PreparedPermissionToolCall
    ) -> ToolCall {
        guard prepared.sidecarStatus == .valid,
              prepared.modelAuthorizationContext != nil,
              prepared.executableCall != nil else {
            return sidecarFreeHistoryCall(prepared)
        }
        return prepared.providerCall
    }

    private static func authorizationSidecarFailureMessage(
        _ status: AuthorizationSidecarStatus
    ) -> String? {
        switch status {
        case .valid:
            return nil
        case .missing:
            return "authorization_context_missing: include the required \(AuthorizationSidecarCodec.reservedFieldName) string in this exact business tool call"
        case .malformed:
            return "authorization_context_malformed: regenerate this exact business tool call with one nonempty \(AuthorizationSidecarCodec.reservedFieldName) string"
        case .oversized(let actualBytes, let maximumBytes):
            return "authorization_context_oversized: the complete context is \(actualBytes) bytes but this route allows \(maximumBytes); rewrite the complete string more concisely"
        case .secretBearing:
            return "authorization_context_secret_bearing: do not copy credentials or secret values; summarize them only as opaque references and regenerate the exact call"
        }
    }

    /// Builds the durable provider-history form before any tool in the
    /// assistant batch executes. The live request keeps the provider's exact
    /// arguments; restart history keeps exact canonical JSON only when it is
    /// schema-valid, bounded, and contains no scrubbed secret material.
    private func modelHistoryFunctionCalls(
        _ toolCalls: [ToolCall],
        registry: ToolRegistry
    ) throws -> [ModelHistoryFunctionCall] {
        var seenCallIDs = Set<String>()
        var result: [ModelHistoryFunctionCall] = []
        result.reserveCapacity(toolCalls.count)

        for call in toolCalls {
            let trimmedCallID = call.id.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !trimmedCallID.isEmpty,
                  seenCallIDs.insert(call.id).inserted else {
                throw AgentModelHistoryProjectionError.ambiguousCallID(
                    call.id)
            }

            guard let registration = registry.registration(named: call.name) else {
                let sanitizedName = PermissionReviewTextSanitizer
                    .sanitizeDiagnostic(call.name, maxCharacters: 128)
                    .text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(ModelHistoryFunctionCall(
                    callID: call.id,
                    name: sanitizedName.isEmpty ? "unknown_tool" : sanitizedName,
                    arguments: Self.redactedArgumentsJSON,
                    argumentsRedacted: true,
                    kind: call.kind == .toolSearch
                        ? .toolSearch
                        : .function,
                    namespace: call.namespace,
                    status: call.status,
                    execution: call.execution))
                continue
            }

            let descriptor = registration.descriptor
            let durableArguments: String
            let argumentsRedacted: Bool
            switch normalizeToolArguments(
                call.arguments,
                registration: registration,
                descriptor: descriptor)
            {
            case .valid(let canonical)
                where !Self.redactsDurableArguments(
                    for: descriptor.name):
                let sanitized = PermissionReviewTextSanitizer.sanitize(
                    canonical,
                    maxCharacters: 8_192)
                if sanitized.redacted || sanitized.truncated {
                    durableArguments = Self.redactedArgumentsJSON
                    argumentsRedacted = true
                } else {
                    durableArguments = canonical
                    argumentsRedacted = false
                }
            case .valid, .invalid:
                durableArguments = Self.redactedArgumentsJSON
                argumentsRedacted = true
            }
            result.append(ModelHistoryFunctionCall(
                callID: call.id,
                name: descriptor.name,
                arguments: durableArguments,
                argumentsRedacted: argumentsRedacted,
                kind: call.kind == .toolSearch
                    ? .toolSearch
                    : .function,
                namespace: call.namespace,
                status: call.status,
                execution: call.execution))
        }
        return result
    }

    /// Durable tool-call events are an audit/display surface, not a raw model
    /// argument store. Unknown or schema-invalid calls are never persisted
    /// verbatim. Inference-control calls are also fully redacted because even
    /// a valid string field could otherwise smuggle an endpoint, header,
    /// credential, or provider-native option into EventLog before the
    /// authorization layer rejects it. Other validated tools retain a bounded,
    /// secret-scrubbed display value while their exact identity is carried by
    /// the additive digest and character count.
    private func appendDurableToolCall(
        _ toolCall: ToolCall,
        canonicalName: String,
        validatedArguments: String?,
        forceRedaction: Bool
    ) async throws {
        let rawArguments = toolCall.arguments
        let displayArguments: String
        let redacted: Bool
        let durableDigest: String?
        if forceRedaction || validatedArguments == nil {
            displayArguments = Self.redactedArgumentsJSON
            redacted = true
            // Never turn rejected/inference-control secret material into an
            // offline verifier. A plain digest of low-entropy endpoints,
            // headers, or credentials is still sensitive.
            durableDigest = nil
        } else {
            let sanitized = PermissionReviewTextSanitizer.sanitize(
                validatedArguments!,
                maxCharacters: 8_192)
            displayArguments = sanitized.text
            redacted = sanitized.redacted || sanitized.truncated
            durableDigest = redacted
                ? nil
                : ToolRegistry.authorizationDigest(validatedArguments!)
        }
        try await log.append(.toolCall(ToolCallPayload(
            toolCallId: toolCall.id,
            agent: agent.name,
            name: canonicalName,
            args: displayArguments,
            argsDigest: durableDigest,
            argsCharacterCount: rawArguments.count,
            argsRedacted: redacted)))
    }

    private static func redactsDurableArguments(for toolName: String) -> Bool {
        toolName == "spawn_agent"
            || toolName == "rename_session"
            || toolName == "write_stdin"
            || toolName == "build_knowledge"
            || toolName == "search_knowledge"
    }

    private static func sessionRenameContainsSecret(_ normalizedArguments: String) -> Bool {
        struct Arguments: Decodable { var name: String }
        guard let data = normalizedArguments.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(Arguments.self, from: data) else {
            return false
        }
        return SecretScanner.containsSecret(arguments.name)
    }

    private enum ToolArgumentNormalization {
        case valid(String)
        case invalid(String)
    }

    private func invalidInputIntent(registration: ToolRegistration,
                                    descriptor: ToolDescriptor,
                                    rawArguments: String,
                                    workspaceRoot: URL) -> PermissionIntent {
        let args = ToolArgs(raw: rawArguments)
        var intent = registration.permissionIntent(
            args,
            workspaceRoot: workspaceRoot)
        guard intent.resources.isEmpty else { return intent }

        var paths = registration.touchedPaths(args)
        if paths.isEmpty,
           let data = rawArguments.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
           case .object(let object) = decoded,
           case .string(let path)? = object["path"],
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            paths = [path]
        }
        if !paths.isEmpty {
            let access: WorkspaceAccess = descriptor.sideEffect == .readOnly
                ? .readOnly
                : .readWrite
            intent.resources = paths.map {
                PermissionResource(kind: .workspacePath, value: $0, access: access)
            }
        }
        return intent
    }

    private func normalizeToolArguments(
        _ raw: String,
        registration: ToolRegistration,
        descriptor: ToolDescriptor
    ) -> ToolArgumentNormalization {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowsEmptyObject = requiredArguments(in: descriptor).isEmpty

        guard !trimmed.isEmpty else {
            if allowsEmptyObject {
                do {
                    try registration.validateArguments(ToolArgs(raw: "{}"))
                    return .valid("{}")
                } catch {
                    return .invalid(
                        "invalid tool input: arguments for \(descriptor.name) do not match the complete schema. \(RuntimeErrorPresentation.message(for: error))")
                }
            }
            return .invalid("invalid tool input: arguments for \(descriptor.name) must be a JSON object matching the tool schema; received empty arguments.")
        }

        guard let data = trimmed.data(using: .utf8) else {
            return .invalid("invalid tool input: arguments for \(descriptor.name) are not valid UTF-8.")
        }

        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            switch value {
            case .object(let object):
                if let message = validateToolArgumentObject(object, descriptor: descriptor) {
                    return .invalid(message)
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                guard let canonical = try? encoder.encode(JSONValue.object(object)) else {
                    return .invalid("invalid tool input: arguments for \(descriptor.name) could not be normalized.")
                }
                let normalized = String(decoding: canonical, as: UTF8.self)
                do {
                    try registration.validateArguments(
                        ToolArgs(raw: normalized))
                } catch {
                    return .invalid(
                        "invalid tool input: arguments for \(descriptor.name) do not match the complete schema. \(RuntimeErrorPresentation.message(for: error))")
                }
                return .valid(normalized)
            case .null where allowsEmptyObject:
                do {
                    try registration.validateArguments(ToolArgs(raw: "{}"))
                    return .valid("{}")
                } catch {
                    return .invalid(
                        "invalid tool input: arguments for \(descriptor.name) do not match the complete schema. \(RuntimeErrorPresentation.message(for: error))")
                }
            default:
                return .invalid("invalid tool input: arguments for \(descriptor.name) must be a JSON object matching the tool schema.")
            }
        } catch {
            return .invalid("invalid tool input: arguments for \(descriptor.name) must be valid JSON. \(RuntimeErrorPresentation.message(for: error))")
        }
    }

    private func validateToolArgumentObject(_ object: [String: JSONValue], descriptor: ToolDescriptor) -> String? {
        let required = Set(requiredArguments(in: descriptor))
        let missing = required
            .filter { object[$0] == nil }
            .sorted()
        if !missing.isEmpty {
            let fields = missing.joined(separator: ", ")
            return "invalid tool input: arguments for \(descriptor.name) are missing required field(s): \(fields)."
        }

        if rejectsAdditionalProperties(in: descriptor) {
            let allowed = Set(propertyNames(in: descriptor))
            let unknown = object.keys
                .filter { !allowed.contains($0) }
                .sorted()
            if !unknown.isEmpty {
                let fields = unknown.joined(separator: ", ")
                let allowedText = allowed.isEmpty
                    ? "no fields"
                    : allowed.sorted().joined(separator: ", ")
                return "invalid tool input: arguments for \(descriptor.name) contain unknown field(s): \(fields). Allowed fields: \(allowedText)."
            }
        }

        for (name, value) in object.sorted(by: { $0.key < $1.key }) {
            guard let propertySchema = propertySchema(named: name, in: descriptor),
                  let expected = propertyType(in: propertySchema) else { continue }
            if value == .null, !required.contains(name) { continue }
            if !matches(value, expectedType: expected) {
                return "invalid tool input: argument \(name) for \(descriptor.name) must be \(expected)."
            }
            if let message = numericConstraintViolation(value, schema: propertySchema, name: name, descriptor: descriptor) {
                return message
            }
            if let message = stringConstraintViolation(value, schema: propertySchema, name: name, descriptor: descriptor) {
                return message
            }
        }
        return nil
    }

    private func requiredArguments(in descriptor: ToolDescriptor) -> [String] {
        guard case .object(let schema) = descriptor.parameters,
              case .array(let required)? = schema["required"] else {
            return []
        }
        return required.compactMap { value in
            guard case .string(let name) = value else { return nil }
            return name
        }
    }

    private func propertyNames(in descriptor: ToolDescriptor) -> [String] {
        guard case .object(let schema) = descriptor.parameters,
              case .object(let properties)? = schema["properties"] else {
            return []
        }
        return Array(properties.keys)
    }

    private func rejectsAdditionalProperties(in descriptor: ToolDescriptor) -> Bool {
        guard case .object(let schema) = descriptor.parameters,
              case .bool(let value)? = schema["additionalProperties"] else {
            return false
        }
        return value == false
    }

    private func propertySchema(named name: String, in descriptor: ToolDescriptor) -> [String: JSONValue]? {
        guard case .object(let schema) = descriptor.parameters,
              case .object(let properties)? = schema["properties"],
              case .object(let propertySchema)? = properties[name] else {
            return nil
        }
        return propertySchema
    }

    private func propertyType(in propertySchema: [String: JSONValue]) -> String? {
        guard case .string(let type)? = propertySchema["type"] else { return nil }
        return type
    }

    private func numericConstraintViolation(_ value: JSONValue,
                                            schema: [String: JSONValue],
                                            name: String,
                                            descriptor: ToolDescriptor) -> String? {
        guard case .number(let number) = value else { return nil }
        if case .number(let minimum)? = schema["minimum"], number < minimum {
            return "invalid tool input: argument \(name) for \(descriptor.name) must be >= \(formatJSONNumber(minimum))."
        }
        if case .number(let maximum)? = schema["maximum"], number > maximum {
            return "invalid tool input: argument \(name) for \(descriptor.name) must be <= \(formatJSONNumber(maximum))."
        }
        return nil
    }

    private func stringConstraintViolation(_ value: JSONValue,
                                           schema: [String: JSONValue],
                                           name: String,
                                           descriptor: ToolDescriptor) -> String? {
        guard case .string(let string) = value else { return nil }
        if let minLength = integerSchemaValue("minLength", in: schema), string.count < minLength {
            return "invalid tool input: argument \(name) for \(descriptor.name) must have at least \(formatCharacterCount(minLength))."
        }
        if let maxLength = integerSchemaValue("maxLength", in: schema), string.count > maxLength {
            return "invalid tool input: argument \(name) for \(descriptor.name) must have at most \(formatCharacterCount(maxLength))."
        }
        return nil
    }

    private func integerSchemaValue(_ key: String, in schema: [String: JSONValue]) -> Int? {
        guard case .number(let number)? = schema[key],
              number.rounded(.towardZero) == number,
              number >= Double(Int.min),
              number <= Double(Int.max) else {
            return nil
        }
        return Int(number)
    }

    private func formatJSONNumber(_ value: Double) -> String {
        if value.rounded(.towardZero) == value,
           value >= Double(Int.min),
           value <= Double(Int.max) {
            return String(Int(value))
        }
        return String(value)
    }

    private func formatCharacterCount(_ count: Int) -> String {
        count == 1 ? "1 character" : "\(count) characters"
    }

    private func matches(_ value: JSONValue, expectedType: String) -> Bool {
        switch expectedType {
        case "string":
            if case .string = value { return true }
            return false
        case "integer":
            guard case .number(let number) = value else { return false }
            return number.rounded(.towardZero) == number
        case "number":
            if case .number = value { return true }
            return false
        case "boolean":
            if case .bool = value { return true }
            return false
        case "array":
            if case .array = value { return true }
            return false
        case "object":
            if case .object = value { return true }
            return false
        default:
            return true
        }
    }

    private struct SettledPermission: Sendable {
        var decision: PermissionDecision
        var reason: String
        var requestID: RequestID? = nil
        var failureSource: ExecutionFailureSource? = nil
        var approvalSource: PermissionApprovalSource? = nil
        var failureKind: PermissionApprovalFailureKind? = nil

        var permitsOneFreshReview: Bool {
            guard decision == .deny,
                  approvalSource == .automaticReviewerFailure else {
                return false
            }
            return failureKind == .providerFailure
                || failureKind == .reviewerTimedOut
        }
    }

    private func authorizationRevalidationFailure(
        _ authorization: ResolvedToolAuthorization,
        registry: ToolRegistry,
        toolName: String,
        normalizedArguments: String,
        intent: PermissionIntent,
        risksNetwork: Bool,
        invocation: ToolAuthorizationInvocationContext
    ) async -> String? {
        do {
            try registry.validateAuthorizationSnapshot(
                authorization,
                toolName: toolName,
                normalizedArguments: normalizedArguments,
                intent: intent,
                risksNetwork: risksNetwork,
                invocation: invocation,
                capabilityLease: capabilityLease,
                workspaceLease: workspaceLease)
        } catch {
            return error.localizedDescription
        }
        return await authorizationRevalidator?(authorization)
    }

    /// Permission reasons are stored without presentation text. Defensively
    /// normalize custom responders and injected revalidators at the final
    /// ToolResult boundary so the UI never shows repeated denial prefixes.
    private static func permissionDeniedMessage(_ rawReason: String) -> String {
        var reason = rawReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "permission denied:"
        while reason.lowercased().hasPrefix(prefix) {
            reason = String(reason.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return reason.isEmpty ? "permission denied" : "permission denied: \(reason)"
    }

    private static var redactedArgumentsJSON: String {
        let field = IntatisHostApplication.identity.redactedArgumentsFieldName
        return "{\"\(field)\":\"arguments_redacted\"}"
    }

    private static func gateSnapshot(_ result: GateResult) -> PermissionReviewGateSnapshot {
        let policyVersion = IntatisHostApplication.identity
            .namespacedIdentifier("deterministic-policy.v1")
        switch result {
        case .deny(let reason, let risk):
            return PermissionReviewGateSnapshot(
                decision: .deny, risk: risk, reason: reason,
                policyVersion: policyVersion)
        case .ask(let reason, let risk):
            return PermissionReviewGateSnapshot(
                decision: .ask, risk: risk, reason: reason,
                policyVersion: policyVersion)
        case .allow(let reason, let risk):
            return PermissionReviewGateSnapshot(
                decision: .allow, risk: risk, reason: reason,
                policyVersion: policyVersion)
        case .pass(let reason, let risk):
            return PermissionReviewGateSnapshot(
                decision: .pass, risk: risk, reason: reason,
                policyVersion: policyVersion)
        }
    }

    /// Emit the right audit events and, for `ask_user`, await the responder.
    private func settle(_ outcome: PermissionOutcome,
                        descriptor: ToolDescriptor,
                        toolCall: ToolCall,
                        turnID: TurnID,
                        callContext: ToolCallContext,
                        authorization: ResolvedToolAuthorization,
                        executionID: String,
                        replayPolicy: ToolExecutionReplayPolicy,
                        reviewInvocation:
                            PermissionReviewInvocationInput?) async throws -> SettledPermission {
        switch outcome.decision {
        case .allow, .deny:
            try await log.append(.permissionResolved(PermissionResolvedPayload(
                turnID: turnID,
                toolCallID: toolCall.id,
                tool: descriptor.name,
                decision: outcome.decision,
                risk: outcome.risk,
                reason: outcome.reason,
                intent: callContext.intent,
                authorization: authorization,
                source: .deterministicPolicy,
                failureSource: outcome.decision == .deny ? .policyDenied : nil)))
            return SettledPermission(
                decision: outcome.decision,
                reason: outcome.reason,
                failureSource: outcome.decision == .deny ? .policyDenied : nil)

        case .askUser:
            let requestID = RequestID.new()
            let boundedArguments = "digest=\(authorization.normalizedArgumentsDigest); characters=\(authorization.normalizedArgumentsCharacterCount)"
            let requestContext = permissionRequestContext(
                outcome: outcome,
                callContext: callContext,
                toolCall: toolCall,
                turnID: turnID,
                authorization: authorization,
                executionID: executionID,
                replayPolicy: replayPolicy,
                reviewInvocation: reviewInvocation)
            let request = PermissionRequestPayload(
                requestId: requestID, agent: agent.name, tool: descriptor.name,
                args: context.runtimeEnvironment.mode == .cowork
                    || Self.redactsDurableArguments(for: descriptor.name)
                    ? boundedArguments
                    : toolCall.arguments,
                risk: outcome.risk, reason: outcome.reason,
                context: requestContext,
                approvalMode: responder.approvalMode)
            try await log.append([
                .permissionRequest(request),
                .agentStatus(AgentStatusPayload(agent: agent.name, state: .blocked)),
            ])

            let resolution: PermissionApprovalResolution
            do {
                resolution = try await awaitPermissionApproval(
                    request,
                    invocation: reviewInvocation)
                try Task.checkCancellation()
            } catch is CancellationError {
                let cancelled = PermissionResolvedPayload(
                    requestId: requestID,
                    turnID: turnID,
                    toolCallID: toolCall.id,
                    tool: descriptor.name,
                    decision: .deny,
                    risk: outcome.risk,
                    reason: "permission request cancelled",
                    intent: callContext.intent,
                    authorization: authorization,
                    source: .callerCancellation,
                    reviewStatus: .cancelled,
                    failureKind: .callerCancelled,
                    failureSource: .turnCancelled)
                do {
                    _ = try await log.settlePermissionRequest(cancelled)
                } catch EventLogError.conflictingPermissionSettlement {
                    // Another terminal response may have won immediately
                    // before cancellation. Authorization delivery remains
                    // fenced by the thrown cancellation below.
                }
                throw CancellationError()
            }
            let userDecision: PermissionDecision = resolution.decision == .allow ? .allow : .deny
            let suppliedReason = resolution.reason?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedReason: String
            if let suppliedReason, !suppliedReason.isEmpty {
                resolvedReason = suppliedReason
            } else {
                resolvedReason = userDecision == .allow
                    ? "permission approved"
                    : outcome.reason
            }
            let failureSource = Self.permissionFailureSource(
                resolution,
                effectiveDecision: userDecision)
            let durableResolution = PermissionResolvedPayload(
                requestId: requestID,
                turnID: turnID,
                toolCallID: toolCall.id,
                tool: descriptor.name,
                decision: userDecision,
                risk: resolution.risk ?? outcome.risk,
                reason: resolvedReason,
                intent: callContext.intent,
                authorization: authorization,
                source: resolution.source,
                reviewTaskID: resolution.reviewTaskID,
                reviewStatus: resolution.reviewStatus,
                failureKind: resolution.failureKind,
                failureSource: failureSource,
                action: resolution.action)
            let settlement = try await log.settlePermissionRequest(durableResolution)
            if resolution.effectiveAction == .cancelTurn {
                throw AgentTurnInterruptedError(
                    reason: resolvedReason,
                    failureSource: failureSource ?? .userCancelled)
            }
            try await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .tool)))
            return SettledPermission(
                decision: settlement.resolution.decision,
                reason: settlement.resolution.reason,
                requestID: requestID,
                failureSource: settlement.resolution.failureSource,
                approvalSource: settlement.resolution.source,
                failureKind: settlement.resolution.failureKind)
        }
    }

    private static func permissionFailureSource(
        _ resolution: PermissionApprovalResolution,
        effectiveDecision: PermissionDecision
    ) -> ExecutionFailureSource? {
        if let failureSource = resolution.failureSource { return failureSource }
        if resolution.effectiveAction == .cancelTurn { return .userCancelled }
        if resolution.failureKind == .reviewerTimedOut { return .reviewerTimedOut }
        if resolution.failureKind != nil { return .reviewerFailed }
        guard effectiveDecision == .deny else { return nil }
        switch resolution.source {
        case .user:
            return .userDenied
        case .callerCancellation:
            return .userCancelled
        case .automaticReviewerFailure:
            return .reviewerFailed
        case .automaticReviewer, .deterministicPolicy, .authorizationRevalidation:
            return .policyDenied
        }
    }

    private func permissionRequestContext(outcome: PermissionOutcome,
                                          callContext: ToolCallContext,
                                          toolCall: ToolCall,
                                          turnID: TurnID,
                                          authorization: ResolvedToolAuthorization,
                                          executionID: String,
                                          replayPolicy: ToolExecutionReplayPolicy,
                                          reviewInvocation:
                                            PermissionReviewInvocationInput?) -> PermissionRequestContext {
        let contract = context.taskContract
        var lineage: [TaskID] = []
        if let rootTaskID { lineage.append(rootTaskID) }
        if let parentTaskID = contract?.parentTaskID,
           !lineage.contains(parentTaskID) {
            lineage.append(parentTaskID)
        }
        if let taskID = contract?.id,
           !lineage.contains(taskID) {
            lineage.append(taskID)
        }
        var relatedAgents = contract?.relatedAgents ?? []
        for candidate in [contract?.issuer, contract?.assignee].compactMap({ $0 })
            where !relatedAgents.contains(candidate) {
            relatedAgents.append(candidate)
        }
        let gateSnapshot: PermissionReviewGateSnapshot
        if let resolvedGate = authorization.deterministicGate {
            gateSnapshot = resolvedGate
        } else {
            let gateDecision: PermissionReviewGateDecision
            switch outcome.decision {
            case .allow: gateDecision = .allow
            case .deny: gateDecision = .deny
            case .askUser: gateDecision = .ask
            }
            gateSnapshot = PermissionReviewGateSnapshot(
                decision: gateDecision,
                risk: outcome.risk,
                reason: outcome.reason,
                policyVersion: IntatisHostApplication.identity
                    .namespacedIdentifier("deterministic-policy.v1"))
        }
        return PermissionRequestContext(
            turnID: turnID,
            taskID: contract?.id,
            rootTaskID: rootTaskID,
            parentTaskID: contract?.parentTaskID,
            attempt: taskAttempt,
            toolCallID: toolCall.id,
            normalizedArgs: "digest=\(authorization.normalizedArgumentsDigest); characters=\(authorization.normalizedArgumentsCharacterCount)",
            touchedPaths: callContext.touchedPaths,
            risksNetwork: callContext.risksNetwork,
            sideEffect: callContext.sideEffect,
            intent: callContext.intent,
            gate: gateSnapshot,
            capabilityLease: capabilityLease,
            workspaceLease: workspaceLease,
            taskContract: contract,
            causalContext: PermissionReviewCausalContext(
                userGoal: contract?.objective,
                issuer: contract?.issuer,
                assignee: contract?.assignee,
                taskLineage: lineage,
                relatedAgents: relatedAgents),
            reviewInvocationEvidence: reviewInvocation.map {
                PermissionReviewInvocationEvidenceMetadata(
                    sourceGenerationID: $0.sourceGenerationID,
                    toolSnapshotID: $0.toolSnapshotID,
                    modelAuthorizationContextDigest:
                        $0.modelAuthorizationContextDigest)
            },
            authorization: authorization,
            executionID: executionID,
            replayPolicy: replayPolicy.rawValue)
    }

    private func awaitPermissionApproval(
        _ request: PermissionRequestPayload,
        invocation: PermissionReviewInvocationInput?
    ) async throws -> PermissionApprovalResolution {
        let gate = PermissionApprovalGate()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                let approvalTask = Task {
                    let resolution: PermissionApprovalResolution
                    if let invocation {
                        resolution = await responder.requestResolution(
                            request,
                            invocation: invocation)
                    } else {
                        resolution = await responder.requestResolution(request)
                    }
                    gate.resolve(.success(resolution))
                }
                gate.setApprovalTask(approvalTask)
            }
        }, onCancel: {
            gate.cancel()
        })
    }

    private func projectedHistory(
        recoveredEvents: [Envelope]? = nil,
        excludingCurrentAndLaterSubmissionsFrom submissionID: SubmissionID? = nil
    ) async throws -> [AgentMessage] {
        switch context.conversationHistoryPolicy {
        case .taskScoped:
            return []
        case .coworkMainThread:
            return try await projectedModelHistoryState(
                currentSubmissionID: submissionID,
                recoveredEvents: recoveredEvents)?.messages ?? []
        case .conversation:
            if context.runtimeEnvironment.mode == .code,
               submissionID != nil {
                return try await projectedModelHistoryState(
                    currentSubmissionID: submissionID,
                    recoveredEvents: recoveredEvents)?.messages ?? []
            }
            return await priorHistory(
                recoveredEvents: recoveredEvents,
                excludingCurrentAndLaterSubmissionsFrom: submissionID)
        }
    }

    private func projectedModelHistoryState(
        currentSubmissionID: SubmissionID?,
        recoveredEvents: [Envelope]? = nil
    ) async throws -> AgentModelHistoryProjection? {
        let events: [Envelope]
        if let recoveredEvents {
            events = recoveredEvents
        } else {
            let replay = try await log.replayForProjectionChecked()
            guard replay.hasCompleteKnownHistory else {
                throw EventLogError.unsupportedEventTypes
            }
            events = replay.envelopes
        }
        switch context.conversationHistoryPolicy {
        case .coworkMainThread:
            guard context.runtimeEnvironment.mode == .cowork,
                  context.contextBundle != nil,
                  let currentTask = context.taskContract else {
                return nil
            }
            return try AgentModelHistoryProjector().projectState(
                agentID: agent.name,
                currentTask: currentTask,
                events: events)
        case .conversation:
            guard context.runtimeEnvironment.mode == .code,
                  let currentSubmissionID else {
                return nil
            }
            return try AgentModelHistoryProjector()
                .projectConversationState(
                    agentID: agent.name,
                    currentSubmissionID: currentSubmissionID,
                    events: events)
        case .taskScoped:
            return nil
        }
    }

    private func priorHistory(
        recoveredEvents: [Envelope]? = nil,
        excludingCurrentAndLaterSubmissionsFrom submissionID: SubmissionID? = nil
    ) async -> [AgentMessage] {
        // Cowork already performed a strict replay at the start of `send`.
        // Reuse that verified snapshot so a safety-sensitive run never falls
        // back to the compatibility replay that skips malformed records.
        let events: [Envelope]
        if let recoveredEvents {
            events = recoveredEvents
        } else {
            events = await log.replay()
        }
        let projectedEvents = Self.historyEvents(
            events,
            excludingCurrentAndLaterSubmissionsFrom: submissionID)
        let projection = ConversationProjection.build(from: projectedEvents)
        return projection.messages.compactMap { m in
            switch m.role {
            case .user:
                return .user(m.text)
            case .assistant, .agent:
                return m.isComplete ? .assistant(m.text) : nil
            case .system:
                return nil
            }
        }
    }

    /// A submitted intent is durable before it reaches AgentLoop. While an
    /// earlier turn runs, later intents may already be present in EventLog.
    /// Build model history by logical submission order instead of raw append
    /// order: exclude the current/later user turns and their correlated model
    /// output, while retaining a prior turn's response even when that response
    /// was appended after a later intent was accepted.
    private static func historyEvents(
        _ events: [Envelope],
        excludingCurrentAndLaterSubmissionsFrom submissionID: SubmissionID?
    ) -> [Envelope] {
        guard let submissionID,
              let currentAcceptedSeq = events.first(where: { envelope in
                  guard case .userMessage(let payload) = envelope.event else { return false }
                  return payload.submissionID == submissionID
              })?.seq else {
            return events
        }

        var acceptedSequenceBySubmission: [SubmissionID: Int] = [:]
        for envelope in events {
            guard case .userMessage(let payload) = envelope.event,
                  let id = payload.submissionID,
                  acceptedSequenceBySubmission[id] == nil else { continue }
            acceptedSequenceBySubmission[id] = envelope.seq
        }

        return events.filter { envelope in
            let correlatedSubmissionID: SubmissionID?
            switch envelope.event {
            case .userMessage(let payload):
                correlatedSubmissionID = payload.submissionID
            case .messageDelta(let payload):
                correlatedSubmissionID = payload.submissionID
            case .messageCompleted(let payload):
                correlatedSubmissionID = payload.submissionID
            case .error(let payload):
                correlatedSubmissionID = payload.submissionID
            default:
                correlatedSubmissionID = nil
            }
            guard let correlatedSubmissionID,
                  let acceptedSeq = acceptedSequenceBySubmission[correlatedSubmissionID] else {
                return true
            }
            return acceptedSeq < currentAcceptedSeq
        }
    }
}
