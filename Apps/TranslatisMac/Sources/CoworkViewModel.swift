#if canImport(SwiftUI)
import SwiftUI
import Combine
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisArtifacts
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
import IntatisCowork
import IntatisSkills
import IntatisMCP
import IntatisTools
import IntatisSharedUI
import IntatisCodexRuntime

private actor ProviderRegistryBox {
    private var registry: ProviderRegistry
    /// GoalVerifier keeps the legacy first-resolvable-main freeze. Permission
    /// review has a separate immutable app-configured binding below.
    private var controlPlaneBinding: AgentInferenceBinding?
    private let permissionReviewerBinding: AgentInferenceBinding?

    init(_ registry: ProviderRegistry,
         controlPlaneBinding: AgentInferenceBinding?,
         permissionReviewerBinding: AgentInferenceBinding?) {
        self.registry = registry
        self.controlPlaneBinding = controlPlaneBinding
        self.permissionReviewerBinding = permissionReviewerBinding
    }

    func update(_ registry: ProviderRegistry) {
        self.registry = registry
    }

    func freezeControlPlaneBinding(
        _ binding: AgentInferenceBinding
    ) -> AgentInferenceBinding {
        if let controlPlaneBinding { return controlPlaneBinding }
        controlPlaneBinding = binding
        return binding
    }

    /// Resolves the exact revision before it is allowed to become the sticky
    /// control-plane route. A legacy/corrupt roster binding must remain
    /// replaceable by a later explicit rebind instead of poisoning the
    /// reviewer for the rest of the process lifetime.
    func freezeResolvableControlPlaneBinding(
        _ binding: AgentInferenceBinding
    ) async -> AgentInferenceBinding? {
        if let controlPlaneBinding {
            guard (try? await registry.agentInference(for: controlPlaneBinding)) != nil else {
                return nil
            }
            return controlPlaneBinding
        }
        guard (try? await registry.agentInference(for: binding)) != nil else {
            return nil
        }
        controlPlaneBinding = binding
        return binding
    }

    func resolvedInference(for agent: Agent) async throws -> ResolvedInferenceProfile {
        guard let binding = agent.agentInferenceBinding else {
            throw IntatisError.config(
                "configurationUnresolved: agent has no exact inference profile binding")
        }
        return try await registry.agentInference(for: binding)
    }

    func provider(for binding: AgentInferenceBinding) async throws -> ToolCallingProvider {
        try await registry.agentInference(for: binding).provider
    }

    func responsesRuntimeRoute(
        for binding: AgentInferenceBinding
    ) async throws -> ResponsesRuntimeRoute {
        try await registry.responsesRuntimeRoute(for: binding)
    }

    func codexRuntimeRoute(
        for binding: AgentInferenceBinding
    ) async throws -> ResolvedCodexRuntimeRoute {
        try await registry.codexRuntimeRoute(for: binding)
    }

    func controlPlaneProvider() async throws -> ToolCallingProvider {
        guard let controlPlaneBinding else {
            throw IntatisError.config(
                "configurationUnresolved: control-plane inference profile is not frozen")
        }
        return try await provider(for: controlPlaneBinding)
    }

    func controlPlaneModel(fallback: ModelID) -> ModelID {
        controlPlaneBinding?.modelID ?? fallback
    }

    func resolvablePermissionReviewerBinding() async
        -> AgentInferenceBinding? {
        guard let permissionReviewerBinding,
              (try? await registry.agentInference(
                  for: permissionReviewerBinding)) != nil else {
            return nil
        }
        return permissionReviewerBinding
    }

    func exactBindingIsResolvable(_ binding: AgentInferenceBinding) async -> Bool {
        (try? await registry.agentInference(for: binding)) != nil
    }

    func imageToolService() async -> ProviderImageGenerationToolService {
        ProviderImageGenerationToolService(registry: registry)
    }

}

private struct ResolvedCodexChildProfiles {
    let profiles: [CodexRuntimeChildProfile]
    let hostedWebSearchServices:
        [CodexRuntimeHostedWebSearchScope:
            any HostedWebSearchToolService]
}

/// Bridges a nonisolated permission request into the MainActor UI without
/// leaving a continuation behind when the requesting task is cancelled before
/// registration finishes. Resolution is lock-protected because cancellation
/// may race the MainActor approval action.
private final class CoworkPermissionWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PermissionApprovalResolution, Never>?
    private var resolution: PermissionApprovalResolution?

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resolution == nil
    }

    func install(_ continuation: CheckedContinuation<PermissionApprovalResolution, Never>) {
        let completed: PermissionApprovalResolution?
        lock.lock()
        if let resolution {
            completed = resolution
        } else {
            self.continuation = continuation
            completed = nil
        }
        lock.unlock()
        if let completed {
            continuation.resume(returning: completed)
        }
    }

    @discardableResult
    func resolve(_ resolution: PermissionApprovalResolution) -> Bool {
        let continuation: CheckedContinuation<PermissionApprovalResolution, Never>?
        lock.lock()
        guard self.resolution == nil else {
            lock.unlock()
            return false
        }
        self.resolution = resolution
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: resolution)
        return true
    }
}

struct CoworkGoalEditDraft: Equatable {
    var objective: String
    var successCriteria: String
    var constraints: String
    var tokenBudget: String
}

typealias CoworkDraftAttachment = IntatisComposerDraftAttachment

enum CoworkSessionLaunchMode: Sendable {
    case fresh
    case restored
}

/// Cowork's GUI runs in automatic-review mode. If that control plane is not
/// available, an ask-class tool must fail only that permission request; it must
/// never silently fall back to a manual sheet or prevent ordinary submission.
private struct CoworkUnavailableAutomaticPermissionResponder: PermissionResponder {
    var approvalMode: PermissionApprovalMode { .automaticReviewer }

    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        .deny
    }

    func requestResolution(
        _ request: PermissionRequestPayload
    ) async -> PermissionApprovalResolution {
        PermissionApprovalResolution(
            decision: .deny,
            reason: "Automatic permission review is unavailable; this tool request was denied without changing the submission.",
            risk: request.risk,
            source: .automaticReviewerFailure,
            failureKind: .controlPlaneShutdown,
            failureSource: .reviewerFailed)
    }
}

/// MainActor-owned latest-only fanout. It is intentionally not ObservableObject:
/// non-selected agents must not invalidate a window's transcript subtree.
@MainActor
private final class CoworkAgentThreadUpdateHub {
    private struct Subscription {
        let agentID: AgentID
        let continuation: AsyncStream<CoworkAgentThreadUpdate>.Continuation
    }

    private var subscriptions: [UUID: Subscription] = [:]
    private var revisions: [AgentID: UInt64] = [:]
    private var throughSeqByAgent: [AgentID: Int] = [:]

    func stream(for agentID: AgentID) -> AsyncStream<CoworkAgentThreadUpdate> {
        let id = UUID()
        let pair = AsyncStream<CoworkAgentThreadUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        subscriptions[id] = Subscription(
            agentID: agentID,
            continuation: pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.subscriptions.removeValue(forKey: id)
            }
        }
        return pair.stream
    }

    func publish(agentIDs: [AgentID], throughSeq: Int) {
        for agentID in Set(agentIDs) {
            revisions[agentID, default: 0] &+= 1
            throughSeqByAgent[agentID] = max(
                throughSeqByAgent[agentID] ?? -1,
                throughSeq)
            let update = CoworkAgentThreadUpdate(
                agentID: agentID,
                throughSeq: throughSeqByAgent[agentID] ?? throughSeq,
                revision: revisions[agentID] ?? 0)
            for subscription in subscriptions.values
                where subscription.agentID == agentID {
                subscription.continuation.yield(update)
            }
        }
    }
}

/// Drives a Cowork project session: user input defaults to the project `Main`
/// Codex thread, while native Codex subagents own delegated execution and
/// context. The view model folds App Server threads plus the shared Intatis
/// event log into the visible conversations, project summary, and agent roster.
@MainActor
final class CoworkViewModel: ObservableObject, PermissionResponder {
    private static let interruptedRunContinuationText =
        "Continue the task that the previous run did not finish. "
        + "First inspect the current workspace and existing tool results. "
        + "Complete only the remaining work, and do not repeat operations "
        + "that already succeeded."

    private struct CodexRootAuthority: Sendable {
        let settings: CoworkProjectSettings
        let mainAgentID: AgentID
        let binding: AgentInferenceBinding
        let permissionProfile: PermissionProfile
        let workspaceURL: URL
        let workspaceLease: WorkspaceLease
        let capabilityLease: CapabilityLease
        let agent: AgentAttachedPayload
    }

    @Published private(set) var agents: [CoworkAgentInfo] = []
    @Published private(set) var summary = CoworkStatusSummary()
    @Published private(set) var project = CoworkProjectInfo()
    @Published private(set) var goal: CoworkGoalCardInfo?
    @Published private(set) var workTasks = CoworkWorkTaskSummary()
    @Published private(set) var projectSettings: CoworkProjectSettings
    @Published var input: String = ""
    @Published private(set) var draftAttachments: [CoworkDraftAttachment] = []
    @Published private(set) var pendingMCPExternalContextCount = 0
    @Published private(set) var isAcceptingSubmission = false
    @Published private(set) var isWorking = false {
        didSet { refreshRuntimeBusy() }
    }
    @Published private(set) var isAgentWorkActive = false {
        didSet { refreshRuntimeBusy() }
    }
    @Published private(set) var isGoalContinuing = false {
        didSet { refreshRuntimeBusy() }
    }
    @Published private(set) var runtimeBusy = false
    @Published private(set) var isGoalRuntimeReady = false
    @Published var pendingPermission: PendingPermission?
    @Published private(set) var permissionNotice: PermissionResolutionNotice?
    @Published private(set) var pendingUserInput:
        IntatisUserInputPresentation?
    @Published private(set) var composerError: String?
    @Published private(set) var projectionError: String?
    @Published private(set) var sessionStorageWarning: String?
    @Published private(set) var needsPrimaryWorkspaceAuthorization = false
    @Published private(set) var addAgentStatus: CoworkAddAgentStatus = .idle
    @Published private(set) var permissionReviewerStatus: CoworkPermissionReviewerStatus = .disabled
    @Published private(set) var inferenceProfileOptions: [AppInferenceProfileOption]
    @Published private(set) var inferenceResolutionFailures: [String: String] = [:]
    @Published private var nextMainInferenceOption: AppInferenceProfileOption?

    #if canImport(AVFoundation)
    let voiceInput: ComposerVoiceInputController
    private var voiceInputObservation: AnyCancellable?
    #endif

    var isAutomaticPermissionReviewReady: Bool {
        switch permissionReviewerStatus {
        case .enabled, .degraded:
            return true
        case .disabled, .enabling, .fallback, .failed:
            return false
        }
    }

    var isMainInferenceReady: Bool {
        liveAgentInfo(named: projectSettings.mainAgentName)?
            .inferenceResolution == .resolved
    }

    var mainInferenceDisplayLabel: String {
        guard let main = liveAgentInfo(named: projectSettings.mainAgentName) else {
            return IntatisLocalization.format(
                "@%@ inference not attached",
                projectSettings.mainAgentName)
        }
        return main.inferenceDisplayLabel ?? IntatisLocalization.format(
            "@%@ inference unavailable",
            main.name)
    }

    /// Composer selection for the next submission hosted by `@main`.
    /// This intentionally does not mutate the live agent binding until the
    /// frozen submission reaches its FIFO execution boundary.
    var nextMainInferenceBinding: AgentInferenceBinding? {
        if let staged = nextMainInferenceOption,
           inferenceProfileOptions.contains(where: { $0.binding == staged.binding }) {
            return staged.binding
        }
        guard let live = agentInferenceBinding(name: projectSettings.mainAgentName),
              inferenceProfileOptions.contains(where: { $0.binding == live }) else {
            return nil
        }
        return live
    }

    var nextMainInferenceDisplayLabel: String {
        nextMainInferenceOption?.title ?? mainInferenceDisplayLabel
    }

    /// Project/roster mutations cannot cross an active invocation or Goal.
    /// The composer selector is intentionally independent from this fence.
    var isRuntimeMutationBlocked: Bool {
        isWorking
            || isGoalContinuing
            || isAgentWorkActive
            || hasActiveCodexChildWork
            || codexStartupTask != nil
    }

    var inferenceComposerError: String? {
        guard liveAgentInfo(named: projectSettings.mainAgentName) != nil,
              !isMainInferenceReady else {
            return nil
        }
        return IntatisLocalization.format(
            "@%@ needs an explicit, resolvable inference profile rebind before Cowork can run.",
            projectSettings.mainAgentName)
    }

    private let log: EventLog
    var mcpEventLog: EventLog { log }
    var mcpWorkspacePaths: [String] {
        projectSettings.workspaces.map(\.path)
    }
    var mcpArtifactStore: ArtifactStore {
        artifactStore
    }
    private let sessionNaming: SessionNamingService
    private let artifactStore: ArtifactStore
    private let composerAttachmentStore: IntatisComposerAttachmentStore
    private let submittedIntentStore: SubmittedIntentStore
    private let codexWorkTaskController: CodexWorkTaskController
    private let registryBox: ProviderRegistryBox
    private let permissionReviewerInferenceBinding:
        AgentInferenceBinding?
    private let permissionReviewerConfigurationError: String?
    private let mcpSnapshots:
        (@MainActor @Sendable () async throws
            -> MCPAgentRequestToolSnapshotSource)?
    private let codexMCPConfiguration:
        (@MainActor @Sendable (
            AgentID,
            CapabilityLeaseID,
            TaskID?
        ) async throws -> CodexRuntimeMCPConfiguration)?
    private let internalToolRegistryAugmenter:
        HostToolRegistryAugmenter?
    private var orchestrator: Orchestrator?
    private var goalRuntime: GoalRuntimeController?
    private var codexRuntime: CodexAppServerSession?
    private var codexRuntimeBinding: AgentInferenceBinding?
    private var codexStartupTask:
        Task<CodexAppServerSession, Error>?
    private var codexRuntimeGeneration: UInt64 = 0
    private var codexEventTask: Task<Void, Never>?
    private let codexUserInputPresenter = CodexUserInputPresenter()
    private var codexApprovalIDs:
        [RequestID: CodexRuntimeRequestID] = [:]
    private var codexApprovalActions:
        [RequestID: PermissionResponseAction] = [:]
    private var codexWriterLease: EventLogWriterLease?
    private var codexAllowsThreadCreation = false
    private var codexProjectionFailed = false
    private var codexRootThreadID: String?
    private var codexChildThreadsByID:
        [String: CodexRuntimeThreadDescriptor] = [:]
    private var codexChildThreadIDByAgentID: [AgentID: String] = [:]
    private var codexChildItemsByAgentID: [AgentID: [CodeItem]] = [:]
    private var codexChildItemIndicesByAgentID:
        [AgentID: [String: Int]] = [:]
    private var codexChildHistoryLoadedThreadIDs: Set<String> = []
    private var codexChildRosterPayloadByThreadID:
        [String: AgentAttachedPayload] = [:]
    private var codexChildParentAgentByThreadID:
        [String: AgentID] = [:]
    private var codexChildStatusByThreadID:
        [String: AgentState] = [:]
    private var codexChildTaskNameByThreadID: [String: String] = [:]
    private var codexDetachedChildThreadIDs: Set<String> = []
    private var codexChildProjectionGeneration = UUID()
    private var codexGoalSnapshot: CodexRuntimeGoalSnapshot?
    private var subscription: Task<Void, Never>?
    private var projectionPump:
        SessionProjectionPump<
            CoworkSessionProjectionState,
            ContinuousClock>?
    private var projectionCommitFence:
        SessionProjectionCommitFence?
    private var shutdownTask: Task<Void, Never>? {
        didSet { refreshRuntimeBusy() }
    }
    private var didStop = false
    private var isCancellingCurrentActivity = false
    private var permissionWaiters: [RequestID: CoworkPermissionWaiter] = [:]
    private var permissionQueue: [PendingPermission] = []
    private var suppressedPermissionRequestIDs: Set<RequestID> = []
    private var activeOperations: [UUID: Task<Void, Never>] = [:] {
        didSet { refreshRuntimeBusy() }
    }
    private var directOperationIDs: Set<UUID> = [] {
        didSet { refreshRuntimeBusy() }
    }
    private var directOperationDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private let agentThreadUpdateHub = CoworkAgentThreadUpdateHub()
    private var submissionQueue: [SubmissionID] = []
    private var submittedPayloads: [SubmissionID: UserMessagePayload] = [:]
    private var canonicalSubmissionIDs: Set<SubmissionID> = []
    private var submissionAttempts: [SubmissionID: Int] = [:]
    private var submissionRetryTasks: [SubmissionID: CoworkTaskView] = [:]
    private var restoredSubmissionIDs: Set<SubmissionID> = []
    private var outboxEntries: [SubmissionID: SubmittedIntentOutboxEntry] = [:]
    private var outboxThreadItemsByAgent: [AgentID: [CodeItem]] = [:]
    private var pendingMCPExternalContexts:
        [UntrustedExternalContext] = []
    private var pendingMCPExternalContextAgentID:
        AgentID?
    private var submissionDrainRunning = false
    private var retryableTasks: [String: CoworkTaskView] = [:]
    private var latestCoworkProjection = CoworkProjection()
    private var didRequestMainAgentAttach = false
    private var workspaceAccessLeases: [String: WorkspaceAccessLease] = [:]
    private var steadyPermissionReviewerStatus: CoworkPermissionReviewerStatus = .disabled
    private let launchMode: CoworkSessionLaunchMode
    let sessionID: SessionID

    init(sessionID: SessionID,
         log: EventLog,
         artifactStore: ArtifactStore,
         sessionNaming: SessionNamingService,
         registry: ProviderRegistry,
         inferenceProfileOptions: [AppInferenceProfileOption],
         permissionReviewerInferenceBinding:
            AgentInferenceBinding?,
         permissionReviewerConfigurationError: String? = nil,
         projectSettings: CoworkProjectSettings,
         launchMode: CoworkSessionLaunchMode = .restored,
         sessionStorageWarning: String? = nil,
         initialWorkspaceAccess: WorkspaceAccessLease? = nil,
         mcpSnapshots:
            (@MainActor @Sendable () async throws
                -> MCPAgentRequestToolSnapshotSource)?
                = nil,
         codexMCPConfiguration:
            (@MainActor @Sendable (
                AgentID,
                CapabilityLeaseID,
                TaskID?
            ) async throws -> CodexRuntimeMCPConfiguration)? = nil,
         internalToolRegistryAugmenter:
            HostToolRegistryAugmenter? = nil) {
        self.sessionID = sessionID
        self.log = log
        self.sessionNaming = sessionNaming
        self.artifactStore = artifactStore
        self.composerAttachmentStore = IntatisComposerAttachmentStore(
            store: artifactStore)
        self.submittedIntentStore = SubmittedIntentStore(log: log)
        self.codexWorkTaskController = CodexWorkTaskController(
            log: log,
            rootAgentID: AgentID(
                rawValue: projectSettings.mainAgentName))
        self.permissionReviewerInferenceBinding =
            permissionReviewerInferenceBinding
        self.permissionReviewerConfigurationError =
            permissionReviewerConfigurationError
        self.registryBox = ProviderRegistryBox(
            registry,
            controlPlaneBinding: nil,
            permissionReviewerBinding:
                permissionReviewerInferenceBinding)
        #if canImport(AVFoundation)
        self.voiceInput = ComposerVoiceInputController(registry: registry)
        #endif
        self.mcpSnapshots = mcpSnapshots
        self.codexMCPConfiguration = codexMCPConfiguration
        self.internalToolRegistryAugmenter = internalToolRegistryAugmenter
        self.inferenceProfileOptions = inferenceProfileOptions
        self.nextMainInferenceOption = nil
        self.projectSettings = projectSettings
        self.launchMode = launchMode
        self.sessionStorageWarning = sessionStorageWarning
        if let initialWorkspaceAccess {
            self.workspaceAccessLeases[initialWorkspaceAccess.canonicalPath] = initialWorkspaceAccess
        }
        self.project = Self.makeProjectInfo(
            sessionID: sessionID,
            settings: projectSettings,
            projection: CoworkProjection())
        #if canImport(AVFoundation)
        observeVoiceInput()
        #endif
        codexUserInputPresenter.onPresentationChange = { [weak self] in
            self?.pendingUserInput = $0
        }
    }

    deinit {
        subscription?.cancel()
        codexStartupTask?.cancel()
        codexEventTask?.cancel()
    }

    var hasActiveWork: Bool {
        isWorking
            || isAgentWorkActive
            || hasActiveCodexChildWork
            || isGoalContinuing
            || !activeOperations.isEmpty
            || !directOperationIDs.isEmpty
            || shutdownTask != nil
    }

    private var hasActiveCodexChildWork: Bool {
        guard !didStop else { return false }
        return codexChildThreadsByID.values.contains {
            Self.codexThreadIsWorking($0.status)
        }
    }

    private func refreshRuntimeBusy() {
        let nextValue = hasActiveWork
        guard runtimeBusy != nextValue else { return }
        runtimeBusy = nextValue
    }

    private var acceptsNewOperations: Bool {
        !didStop && shutdownTask == nil
    }

    private func beginDirectOperation() -> UUID? {
        guard acceptsNewOperations else { return nil }
        let operationID = UUID()
        directOperationIDs.insert(operationID)
        return operationID
    }

    private func finishDirectOperation(_ operationID: UUID) {
        guard directOperationIDs.remove(operationID) != nil,
              directOperationIDs.isEmpty else { return }
        let waiters = directOperationDrainWaiters
        directOperationDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForDirectOperationsToDrain() async {
        guard !directOperationIDs.isEmpty else { return }
        await withCheckedContinuation { continuation in
            directOperationDrainWaiters.append(continuation)
        }
    }

    func updateProviderRegistry(
        _ registry: ProviderRegistry,
        inferenceProfileOptions: [AppInferenceProfileOption]? = nil
    ) {
        guard acceptsNewOperations else { return }
        #if canImport(AVFoundation)
        voiceInput.updateProviderRegistry(registry)
        #endif
        let refreshedOptions = inferenceProfileOptions
        let approvedOptions = refreshedOptions ?? self.inferenceProfileOptions
        let bindings = approvedOptions.map(\.binding)
        let routingMetadata = approvedOptions.map {
            InferenceProfileRoutingMetadata(
                inferenceProfileID: $0.binding.inferenceProfileID,
                declaredCapabilities: $0.declaredCapabilities)
        }
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            await self.registryBox.update(registry)
            if self.isAgentWorkActive {
                self.codexRuntimeBinding = nil
            } else {
                await self.resetCodexRuntime()
            }
            await self.orchestrator?.updateAvailableInferenceProfiles(
                bindings,
                routingMetadata: routingMetadata,
                hostAuthorized: true)
            // Publish new menu entries only after Orchestrator has accepted the
            // same host-approved snapshot, so a newly visible choice cannot
            // race a stale admission catalog.
            if let refreshedOptions {
                if let staged = self.nextMainInferenceOption {
                    self.nextMainInferenceOption = refreshedOptions.first(where: {
                        $0.binding == staged.binding
                    })
                }
                self.inferenceProfileOptions = refreshedOptions
            }
            await self.refreshInferenceResolutionState()
        }
        activeOperations[operationID] = operation
    }

    func start() {
        guard !didStop, subscription == nil,
              shutdownTask == nil else { return }
        do {
            if codexWriterLease == nil {
                codexWriterLease = try log.acquireWriterLease()
            }
        } catch {
            projectionError = error.localizedDescription
            return
        }
        let projectionIdentity = SessionProjectionIdentity(
            sessionID: sessionID)
        let projectionPump = SessionProjectionPump<
            CoworkSessionProjectionState,
            ContinuousClock>(
                identity: projectionIdentity,
                clock: ContinuousClock())
        projectionCommitFence = SessionProjectionCommitFence(
            identity: projectionIdentity)
        self.projectionPump = projectionPump
        setPermissionReviewerStatus(.enabling)

        subscription = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let replayed = await self.log.replay()
                let initialReplay = try await projectionPump
                    .loadInitialReplay(replayed)
                let initialCowork = initialReplay.cowork
                    ?? CoworkProjection()
                self.restoreWorkspaceAccess(for: initialCowork)
                try await self.bootstrapCodexMainIfNeeded()

                let restored = await self.log.replay()
                let restoredCowork = CoworkProjection.build(
                    from: restored)
                self.codexAllowsThreadCreation =
                    restoredCowork.sessionSettings?.cowork?
                        .codexRuntimeGeneration
                        == CoworkSessionSettings
                            .currentCodexRuntimeGeneration
                    && !Self.containsAgentHistory(restored)
                let initial = try await projectionPump.synchronize(
                    with: restored,
                    markRestoredPermissionsNeedsRerun: true)
                self.commitProjectionSnapshot(initial)
                let stream = await self.log.stream(
                    from: (restored.last?.seq ?? -1) + 1)
                let publications = try await projectionPump.publications(
                    consuming: stream)

                // Restore the root and its verified descendants before the
                // window consumes live publications. The exact App Server may
                // automatically continue an already-active official Goal;
                // `turn/started` remains authoritative for that work state.
                do {
                    _ = try await self
                        .startCodexRuntimeForCurrentMain()
                    self.isGoalRuntimeReady = true
                    await self
                        .settleRestoredCodexChildDeliveriesAsUnknown()
                } catch {
                    let message = error.localizedDescription
                    self.projectionError = message
                    self.setPermissionReviewerStatus(.failed(message))
                }

                for await output in publications {
                    guard !Task.isCancelled else { break }
                    switch output {
                    case .snapshot(let snapshot):
                        self.commitProjectionSnapshot(snapshot)
                    case .failed(let failure):
                        guard self.projectionCommitFence?.identity
                            == projectionIdentity else { continue }
                        self.projectionError = failure.localizedDescription
                    }
                }
            } catch {
                guard self.projectionCommitFence?.identity
                    == projectionIdentity,
                      !Task.isCancelled else { return }
                let message = error.localizedDescription
                self.projectionError = message
                self.setPermissionReviewerStatus(.failed(message))
            }
        }
    }

    /// Retained temporarily only for a source-level/manual rollback. The
    /// shipping Cowork path above never creates the Swift Orchestrator.
    @available(*, unavailable, message: "Cowork uses Codex App Server")
    private func retainedLegacyOrchestratorStart() {
        guard !didStop, orchestrator == nil, shutdownTask == nil else { return }
        let projectionIdentity =
            SessionProjectionIdentity(
                sessionID: sessionID)
        let projectionPump =
            SessionProjectionPump<
                CoworkSessionProjectionState,
                ContinuousClock>(
                    identity: projectionIdentity,
                    clock: ContinuousClock())
        projectionCommitFence =
            SessionProjectionCommitFence(
                identity:
                    projectionIdentity)
        self.projectionPump =
            projectionPump
        setPermissionReviewerStatus(.enabling)
        let registryBox = registryBox
        let makeMCPSnapshots = mcpSnapshots
        let mcpLog = log
        let toolSnapshotProvider:
            Orchestrator.ToolSnapshotProvider?
        if let makeSource = makeMCPSnapshots {
            toolSnapshotProvider = {
                agent,
                capabilityLease,
                workspaceLease,
                baseRegistry,
                isResume,
                providerCapabilities,
                outputBudget in
                let state =
                    try await MCPDurableSessionState
                        .load(from: mcpLog)
                guard !state.attachments.isEmpty else {
                    return nil
                }
                guard let workspaceLease else {
                    throw IntatisError.config(
                        "MCP dispatch requires an exact workspace lease")
                }
                let source =
                    try await makeSource()
                return try await source.snapshot(
                    for: MCPAgentDispatchInput(
                        agentID: agent.name,
                        capabilityLease:
                            capabilityLease,
                        workspaceLease:
                            workspaceLease,
                        baseRegistry:
                            baseRegistry,
                        activationReason:
                            isResume
                                ? .resume
                                : .send),
                    providerCapabilities:
                        providerCapabilities,
                    turnResultBudget:
                        outputBudget)
            }
        } else {
            toolSnapshotProvider = nil
        }
        do {
            let runtime = try Orchestrator.runtime(
                log: log,
                allowsShell: PlatformProfile.current.allowsShell,
                responder: CoworkUnavailableAutomaticPermissionResponder(),
                executionPolicy: CoworkExecutionPolicy(tokenBudget: projectSettings.tokenBudget),
                skillRootAccess: AppConfig.skillRootAccess,
                availableInferenceProfiles: inferenceProfileOptions.map(\.binding),
                inferenceProfileRoutingMetadata: inferenceProfileOptions.map {
                    InferenceProfileRoutingMetadata(
                        inferenceProfileID: $0.binding.inferenceProfileID,
                        declaredCapabilities: $0.declaredCapabilities)
                },
                requiresInferenceBindings: true,
                imageGeneratorFor: { _ in await registryBox.imageToolService() },
                imageResolver: AgentImageResolution.resolver(
                    store: artifactStore),
                toolSnapshotProvider:
                    toolSnapshotProvider,
                internalToolRegistryAugmenter:
                    internalToolRegistryAugmenter,
                sessionNaming: sessionNaming,
                resolvedInferenceFor: { agent in
                    try await registryBox.resolvedInference(for: agent)
                })
            orchestrator = runtime
            let verifierFallbackModel = projectSettings.defaultInferenceProfileBinding?.modelID
                ?? inferenceProfileOptions.first?.binding.modelID
                ?? ModelID(rawValue: AppConfig.defaultModel)
            goalRuntime = GoalRuntimeController(
                sessionID: sessionID,
                log: log,
                orchestrator: runtime,
                verifierProvider: { try await registryBox.controlPlaneProvider() },
                verifierModel: {
                    await registryBox.controlPlaneModel(fallback: verifierFallbackModel)
                })
        } catch {
            let message = RuntimeErrorPresentation.message(for: error)
            projectionError = IntatisLocalization.format(
                "Cowork session could not start: %@",
                message)
            setPermissionReviewerStatus(.failed(message))
            return
        }
        subscription = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let replayed = await self.log.replay()
                let preRestore =
                    try await projectionPump
                        .loadInitialReplay(
                            replayed)
                let replayedCowork =
                    preRestore.cowork
                        ?? CoworkProjection()
                self.restoreWorkspaceAccess(
                    for: replayedCowork)
                await self.orchestrator?.restore(
                    from: replayedCowork)
                await self.refreshInferenceResolutionState()

                // Restore may durably reconcile stale control-plane state.
                // Build every projection on the non-MainActor pump from that
                // authoritative tail, then register the stream before
                // bootstrap can append additional admission events.
                let restored =
                    await self.log.replay()
                let initial =
                    try await projectionPump
                        .synchronize(
                            with: restored,
                            markRestoredPermissionsNeedsRerun:
                                true)
                if let restoredProjection =
                        initial.cowork {
                    self.restoreSubmittedIntentState(
                        from: restoredProjection,
                        marksUnfinishedAsInterrupted:
                            true)
                }
                await self.restoreSubmittedIntentOutbox()
                self.commitProjectionSnapshot(initial)
                let stream = await self.log.stream(
                    from:
                        (restored.last?.seq ?? -1)
                            + 1)
                let publications =
                    try await projectionPump
                        .publications(
                            consuming: stream)
                let initialCoworkProjection =
                    initial.cowork
                        ?? replayedCowork

                if self.launchMode == .fresh {
                    // Choosing the primary workspace is the explicit
                    // authorization for the fixed @main bootstrap. Do not ask
                    // a model to approve that same user choice a second time.
                    await self.bootstrapMainAgentIfNeeded(
                        existingProjection:
                            initialCoworkProjection,
                        allowsInitialSessionBootstrap:
                            true)
                    if let orchestrator =
                            self.orchestrator {
                        await self
                            .synchronizePermissionReviewerHealth(
                                using: orchestrator)
                    }
                } else {
                    // Restore @main from canonical settings and the
                    // session-owned bookmark before starting the reviewer.
                    await self.bootstrapMainAgentIfNeeded(
                        existingProjection:
                            initialCoworkProjection,
                        allowsInitialSessionBootstrap:
                            false)
                    // Data-plane/Goal recovery is independent from permission
                    // reviewer readiness. Until the reviewer is live, the
                    // fail-closed responder above denies only ask-class tools.
                    await self.resumeRuntimeIfReady()
                    await self.ensureAutomaticPermissionReview(
                        existingProjection:
                            self.latestCoworkProjection)
                }
                // Fresh-session registration may already include a healthy
                // reviewer, but data-plane readiness does not depend on it.
                await self.resumeRuntimeIfReady()
                for await output in publications {
                    guard !Task.isCancelled else {
                        break
                    }
                    switch output {
                    case .snapshot(let snapshot):
                        self.commitProjectionSnapshot(
                            snapshot)
                    case .failed(let failure):
                        guard self.projectionCommitFence?
                                .identity
                                == projectionIdentity else {
                            continue
                        }
                        self.projectionError =
                            failure.localizedDescription
                    }
                }
            } catch {
                guard self.projectionCommitFence?
                        .identity
                        == projectionIdentity,
                      !Task.isCancelled else {
                    return
                }
                self.projectionError =
                    error.localizedDescription
            }
        }
    }

    private func bootstrapCodexMainIfNeeded() async throws {
        let (projection, durableSettings) =
            try await checkedCodexRootProjection()
        if let durableSettings {
            _ = try await validatedCodexRootAuthority(
                projection: projection,
                settings: durableSettings)
            return
        }
        guard case .fresh = launchMode else {
            throw IntatisError.config(
                "This Cowork session has no durable current-generation Codex root registration. Create a new Cowork session; restored or partial sessions are not silently bootstrapped.")
        }

        let authority = try await makeCodexRootAuthority(
            settings: projectSettings,
            workspaceLeaseID: WorkspaceLeaseID(
                rawValue: "wlease_codex_main_\(sessionID.rawValue)"),
            workspaceID: WorkspaceID(
                rawValue: "workspace_codex_main_\(sessionID.rawValue)"),
            capabilityLeaseID: CapabilityLeaseID(
                rawValue: "clease_codex_main_\(sessionID.rawValue)"))
        let createdAt = Date()
        let workspaceMetadata = CoworkEventMetadata(
            agentID: authority.mainAgentID,
            workspaceID: authority.workspaceLease.workspaceID,
            workspaceLeaseID: authority.workspaceLease.id,
            scope: .workspace,
            createdAt: createdAt)
        let capabilityMetadata = CoworkEventMetadata(
            agentID: authority.mainAgentID,
            capabilityLeaseID: authority.capabilityLease.id,
            scope: .capability,
            createdAt: createdAt)
        let agentMetadata = CoworkEventMetadata(
            agentID: authority.mainAgentID,
            workspaceID: authority.workspaceLease.workspaceID,
            workspaceLeaseID: authority.workspaceLease.id,
            capabilityLeaseID: authority.capabilityLease.id,
            scope: .agent,
            createdAt: createdAt)
        let events: [Event] = [
            .sessionSettingsUpdated(SessionSettingsUpdatedPayload(
                revision: 1,
                changeKind: .created,
                kind: .cowork,
                cowork: authority.settings)),
            .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                agent: authority.mainAgentID,
                lease: authority.workspaceLease,
                metadata: workspaceMetadata)),
            .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                agent: authority.mainAgentID,
                lease: authority.capabilityLease,
                metadata: capabilityMetadata)),
            .agentAttached(AgentAttachedPayload(
                agent: authority.agent.agent,
                path: authority.agent.path,
                model: authority.agent.model,
                profile: projectSettings.defaultPermissionProfile,
                agentInferenceBinding:
                    authority.agent.agentInferenceBinding,
                metadata: agentMetadata)),
        ]
        guard try await log.appendIfEmptyChecked(events) != nil else {
            // Another process may have won the empty-session race. Accept only
            // the same complete authority baseline; partial state remains a
            // typed new-session requirement and is never repaired in place.
            _ = try await loadCodexRootAuthority()
            return
        }
        _ = try await SessionProjectionStore.rebuild(from: log)
    }

    private func checkedCodexRootProjection() async throws
        -> (CoworkProjection, CoworkProjectSettings?)
    {
        let replay = try await log.replayForProjectionChecked()
        guard replay.hasCompleteKnownHistory else {
            throw EventLogError.unsupportedEventTypes
        }
        let canonical = try SessionProjectionStore
            .canonicalSessionSettings(
                from: replay.envelopes,
                session: sessionID)
        if let canonical {
            guard canonical.kind == .cowork,
                  let settings = canonical.cowork else {
                throw IntatisError.config(
                    "The durable session settings are not a Cowork configuration.")
            }
            return (
                CoworkProjection.build(from: replay.envelopes),
                settings)
        }
        return (CoworkProjection.build(from: replay.envelopes), nil)
    }

    private func loadCodexRootAuthority() async throws
        -> CodexRootAuthority
    {
        let (projection, settings) =
            try await checkedCodexRootProjection()
        guard let settings else {
            throw IntatisError.config(
                "Cowork has no durable current-generation Codex root registration.")
        }
        return try await validatedCodexRootAuthority(
            projection: projection,
            settings: settings)
    }

    private func makeCodexRootAuthority(
        settings: CoworkProjectSettings,
        workspaceLeaseID: WorkspaceLeaseID,
        workspaceID: WorkspaceID,
        capabilityLeaseID: CapabilityLeaseID,
        agentInferenceBinding: AgentInferenceBinding? = nil
    ) async throws -> CodexRootAuthority {
        let main = AgentID(rawValue: settings.mainAgentName)
        guard settings.schemaVersion
                == CoworkSessionSettings.currentSchemaVersion,
              settings.sessionID == sessionID,
              settings.codexRuntimeGeneration
                == CoworkSessionSettings.currentCodexRuntimeGeneration,
              main == AgentID(rawValue: "main") else {
            throw IntatisError.config(
                "Cowork requires the exact current-generation @main session settings before Codex can start.")
        }
        let primaryWorkspaces = settings.workspaces.filter(\.isPrimary)
        guard primaryWorkspaces.count == 1,
              let primary = primaryWorkspaces.first,
              primary.agentName == nil
                || primary.agentName == main.rawValue,
              let defaultBinding = settings.defaultInferenceProfileBinding,
              settings.defaultModelID == nil
                || settings.defaultModelID
                    == defaultBinding.modelID.rawValue,
              let permissionProfile = PermissionProfile(
                rawValue: settings.defaultPermissionProfile),
              permissionProfile != .locked else {
            throw IntatisError.config(
                "Cowork requires one primary @main workspace, an exact Responses binding, and a Codex-representable permission profile.")
        }
        let binding = agentInferenceBinding ?? defaultBinding
        let storedWorkspace = URL(fileURLWithPath: primary.path)
            .standardizedFileURL
        guard let retainedWorkspace = retainWorkspaceAccess(
                forPath: storedWorkspace.path) else {
            needsPrimaryWorkspaceAuthorization = true
            throw IntatisError.permissionDenied(
                "The primary Cowork workspace capability must be authorized again before Codex can start.")
        }
        let workspaceURL = retainedWorkspace
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard workspaceURL.path == storedWorkspace.path else {
            throw IntatisError.config(
                "The durable primary workspace path is not the canonical authorized directory.")
        }
        let workspaceAccess: IntatisProtocol.WorkspaceAccess =
            permissionProfile == .readOnly ? .readOnly : .readWrite
        let workspaceLease = WorkspaceLease(
            id: workspaceLeaseID,
            workspaceID: workspaceID,
            rootPath: workspaceURL.path,
            access: workspaceAccess)
        guard workspaceLease.rootIdentity?
                .matchesCurrentDirectory(
                    rootPath: workspaceLease.rootPath) == true else {
            throw IntatisError.permissionDenied(
                "The primary Cowork workspace identity changed before root authority registration.")
        }
        let codexRoute = try await registryBox.codexRuntimeRoute(
            for: binding)
        let capabilityLease = CodexBusinessToolHost
            .rootBusinessCapabilityLease(
                id: capabilityLeaseID,
                workspaceAccess: workspaceAccess,
                includesSessionNaming: true,
                includesWorkTaskManagement: true,
                includesHostedWebSearch:
                    codexRoute.hostedWebSearch != nil,
                knowledgeCapabilities: codexKnowledgeCapabilities(
                    workspaceAccess: workspaceAccess))
        let agentMetadata = CoworkEventMetadata(
            agentID: main,
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            scope: .agent)
        return CodexRootAuthority(
            settings: settings,
            mainAgentID: main,
            binding: binding,
            permissionProfile: permissionProfile,
            workspaceURL: workspaceURL,
            workspaceLease: workspaceLease,
            capabilityLease: capabilityLease,
            agent: AgentAttachedPayload(
                agent: main,
                path: workspaceURL.path,
                model: binding.modelID,
                profile: permissionProfile.rawValue,
                agentInferenceBinding: binding,
                metadata: agentMetadata))
    }

    private func validatedCodexRootAuthority(
        projection: CoworkProjection,
        settings: CoworkProjectSettings
    ) async throws -> CodexRootAuthority {
        let main = AgentID(rawValue: settings.mainAgentName)
        guard let agent = projection.agentRoster[main] else {
            let detached = projection.historicalAgentRoster[main] != nil
            throw IntatisError.config(
                detached
                    ? "The durable @main identity is detached. Create a new Cowork session; Codex will not recreate it silently."
                    : "The current-generation Cowork session is missing its atomic @main root registration. Create a new Cowork session; partial startup state is not repaired in place.")
        }
        let workspaceCandidates = projection.workspaceLeaseAgents
            .compactMap { leaseID, agentID -> WorkspaceLease? in
                guard agentID == main,
                      let lease = projection.workspaceLeases[leaseID],
                      lease.taskID == nil else {
                    return nil
                }
                return lease
            }
        let capabilityCandidates = projection.capabilityLeaseAgents
            .compactMap { leaseID, agentID -> CapabilityLease? in
                guard agentID == main,
                      let lease = projection.capabilityLeases[leaseID],
                      lease.taskID == nil else {
                    return nil
                }
                return lease
            }
        guard workspaceCandidates.count == 1,
              capabilityCandidates.count == 1,
              let workspaceLease = workspaceCandidates.first,
              let capabilityLease = capabilityCandidates.first else {
            throw IntatisError.config(
                "The current-generation Cowork session is missing one exact @main workspace/capability lease pair. Create a new Cowork session; ambiguous or partial authority is not repaired in place.")
        }
        let expected = try await makeCodexRootAuthority(
            settings: settings,
            workspaceLeaseID: workspaceLease.id,
            workspaceID: workspaceLease.workspaceID,
            capabilityLeaseID: capabilityLease.id,
            agentInferenceBinding:
                agent.agentInferenceBinding)
        guard workspaceLease == expected.workspaceLease,
              capabilityLease == expected.capabilityLease,
              agent.path == expected.agent.path,
              agent.model == expected.agent.model,
              agent.profile == expected.agent.profile,
              agent.agentInferenceBinding == expected.binding,
              let metadata = agent.metadata,
              metadata.agentID == main,
              metadata.workspaceID == workspaceLease.workspaceID,
              metadata.workspaceLeaseID == workspaceLease.id,
              metadata.capabilityLeaseID == capabilityLease.id,
              metadata.scope == .agent else {
            throw IntatisError.permissionDenied(
                "The durable @main registration does not match its exact workspace, capability, profile, or inference authority.")
        }
        return CodexRootAuthority(
            settings: settings,
            mainAgentID: main,
            binding: expected.binding,
            permissionProfile: expected.permissionProfile,
            workspaceURL: expected.workspaceURL,
            workspaceLease: workspaceLease,
            capabilityLease: capabilityLease,
            agent: agent)
    }

    private func codexSession(
        for binding: AgentInferenceBinding
    ) async throws -> CodexAppServerSession {
        let rootAuthority = try await loadCodexRootAuthority()
        guard rootAuthority.binding == binding else {
            throw IntatisError.config(
                "The requested Codex route does not match the durable exact @main inference binding.")
        }
        if let codexRuntime,
           codexRuntimeBinding == binding {
            return codexRuntime
        }
        if let codexStartupTask,
           codexRuntimeBinding == binding {
            let generation = codexRuntimeGeneration
            let runtime = try await codexStartupTask.value
            guard codexRuntimeGeneration == generation else {
                await runtime.shutdown()
                throw CancellationError()
            }
            return runtime
        }
        if codexRuntime != nil || codexStartupTask != nil {
            guard !isAgentWorkActive else {
                throw CodexRuntimeError.alreadyRunning
            }
            await resetCodexRuntime()
        }
        let startupGeneration = codexRuntimeGeneration
        let resolvedRoute = try await registryBox.codexRuntimeRoute(
            for: binding)
        let route = resolvedRoute.responses
        let resolvedChildren = try await resolvedCodexChildProfiles()
        var hostedWebSearchServices =
            resolvedChildren.hostedWebSearchServices
        if let hostedWebSearch = resolvedRoute.hostedWebSearch {
            hostedWebSearchServices[.root] =
                ProviderHostedWebSearchToolService(
                    route: hostedWebSearch)
        }
        let workspaceURL = rootAuthority.workspaceURL
        let rootPermissionProfile = rootAuthority.permissionProfile
        let workspaceLease = rootAuthority.workspaceLease
        let mainAgentID = rootAuthority.mainAgentID
        let mainCapabilityLease = rootAuthority.capabilityLease
        let nativeMCP = try await codexMCPConfiguration?(
            mainAgentID,
            mainCapabilityLease.id,
            nil) ?? .empty
        let inheritedChildKnowledgeCapabilities =
            codexKnowledgeCapabilities(
                workspaceAccess: workspaceLease.access)
        let nativeSkills = AppConfig.skillRootAccess
            == .workspaceAndGlobal
            ? try CodexRuntimeSkillConfiguration.hostUserCodexHome()
            : .empty
        let businessToolHost = try CodexBusinessToolHost(
            sessionID: sessionID,
            agentID: mainAgentID,
            workspaceURL: workspaceURL,
            workspaceLease: workspaceLease,
            childProfiles: resolvedChildren.profiles,
            additionalRegistrations:
                CodexWorkTaskToolRegistry.registrations,
            registryAugmenter:
                internalToolRegistryAugmenter,
            workTaskManagerResolver: { [codexWorkTaskController] agentID in
                await codexWorkTaskController.manager(
                    for: agentID)
            },
            imageGenerator: await registryBox.imageToolService(),
            hostedWebSearchServices: hostedWebSearchServices,
            sessionNaming: sessionNaming,
            allowsShell: PlatformProfile.current.allowsShell,
            log: log,
            permissionResolver: { [weak self] request in
                guard let self else {
                    return PermissionApprovalResolution(
                        decision: .deny,
                        reason: "Cowork permission presenter is unavailable",
                        risk: request.risk,
                        source: .callerCancellation,
                        reviewStatus: .cancelled,
                        failureKind: .callerCancelled,
                        failureSource: .turnCancelled)
                }
                return await self.requestResolution(request)
            })
        let dynamicTools = try await businessToolHost.dynamicTools()
        guard codexRuntimeGeneration == startupGeneration else {
            _ = await dynamicTools.shutdown()
            throw CancellationError()
        }
        let configuration = CodexRuntimeConfiguration(
            sessionID: sessionID,
            mode: .cowork,
            workspaceURL: workspaceURL,
            runtimeRootURL: log.sessionDirectoryURL
                .appendingPathComponent(
                    "codex-runtime",
                    isDirectory: true),
            route: route,
            approvalReviewer: .automatic,
            reasoningEffort: route.reasoningEffort,
            allowsThreadCreation: codexAllowsThreadCreation,
            dynamicTools: dynamicTools,
            mcpConfiguration: nativeMCP,
            skillConfiguration: nativeSkills,
            childProfiles: resolvedChildren.profiles,
            requestUserInputHandler: { [weak self] request in
                guard let self else { throw CancellationError() }
                return try await self.presentCodexUserInput(request)
            },
            inheritedChildKnowledgeCapabilities:
                inheritedChildKnowledgeCapabilities,
            rootHostedWebSearchEnabled:
                resolvedRoute.hostedWebSearch != nil,
            rootPermissionProfile: rootPermissionProfile,
            pauseActiveGoalBeforeResume: true)
        codexRuntimeBinding = binding
        let task = Task { @MainActor [weak self] () throws
            -> CodexAppServerSession in
            guard let self else { throw CancellationError() }
            let runtime = CodexAppServerSession(
                configuration: configuration)
            self.codexProjectionFailed = false
            let events = await runtime.events()
            let eventTask = Task { @MainActor [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { return }
                    await self?.handleCodexEvent(event)
                }
            }
            self.codexEventTask = eventTask
            do {
                _ = try await runtime.start()
                try Task.checkCancellation()
                return runtime
            } catch {
                eventTask.cancel()
                await runtime.shutdown()
                throw error
            }
        }
        codexStartupTask = task
        do {
            let runtime = try await task.value
            guard codexRuntimeGeneration == startupGeneration else {
                await runtime.shutdown()
                throw CancellationError()
            }
            codexRuntime = runtime
            codexStartupTask = nil
            return runtime
        } catch {
            codexStartupTask = nil
            codexEventTask = nil
            codexRuntimeBinding = nil
            throw error
        }
    }

    private func presentCodexUserInput(
        _ request: CodexRuntimeUserInputRequest
    ) async throws -> CodexRuntimeUserInputResponse {
        let requesterName = request.agentID == nil
            ? projectSettings.mainAgentName
            : codexChildDisplayName(request.threadID)
        return try await codexUserInputPresenter.requestInput(
            request,
            requesterName: requesterName)
    }

    func submitUserInput(_ submission: IntatisUserInputSubmission) {
        guard !didStop else { return }
        codexUserInputPresenter.submit(submission)
    }

    private func resolvedCodexChildProfiles() async throws
        -> ResolvedCodexChildProfiles
    {
        var result: [CodexRuntimeChildProfile] = []
        var hostedWebSearchServices:
            [CodexRuntimeHostedWebSearchScope:
                any HostedWebSearchToolService] = [:]
        for profile in projectSettings.codexAgentProfiles.sorted(by: {
            $0.roleName < $1.roleName
        }) {
            guard let configured = configuredWorkspace(
                matching: profile.workspacePath),
                  let canonical = canonicalWorkspaceIdentity(
                    configured.path),
                  let access = workspaceAccessLeases[canonical] else {
                throw IntatisError.permissionDenied(
                    "Codex role @\(profile.roleName) does not have a live session-owned workspace capability.")
            }
            let sandbox: CodexRuntimeChildSandbox
            guard let permissionProfile = PermissionProfile(
                    rawValue: profile.permissionProfile) else {
                throw IntatisError.config(
                    "Codex role @\(profile.roleName) has an unknown permission profile.")
            }
            switch permissionProfile {
            case .autopilot, .reviewed, .manual:
                sandbox = .workspaceWrite
            case .readOnly:
                sandbox = .readOnly
            case .locked:
                throw IntatisError.config(
                    "Codex role @\(profile.roleName) uses the \(IntatisHostApplication.identity.name) locked profile, which the exact Codex custom-agent API cannot represent.")
            }
            let resolvedRoute = try await registryBox.codexRuntimeRoute(
                for: profile.inferenceBinding)
            let hostedWebSearchScope =
                CodexRuntimeHostedWebSearchScope.childRole(
                    profile.roleName)
            if let hostedWebSearch = resolvedRoute.hostedWebSearch {
                hostedWebSearchServices[hostedWebSearchScope] =
                    ProviderHostedWebSearchToolService(
                        route: hostedWebSearch)
            }
            result.append(CodexRuntimeChildProfile(
                roleName: profile.roleName,
                description: profile.description,
                workspaceURL: access.canonicalURL,
                route: resolvedRoute.responses,
                sandbox: sandbox,
                permissionProfile: permissionProfile,
                knowledgeCapabilities: codexKnowledgeCapabilities(
                    workspaceAccess: sandbox == .readOnly
                        ? .readOnly
                        : .readWrite),
                hostedWebSearchEnabled:
                    resolvedRoute.hostedWebSearch != nil))
        }
        return ResolvedCodexChildProfiles(
            profiles: result,
            hostedWebSearchServices: hostedWebSearchServices)
    }

    private func codexKnowledgeCapabilities(
        workspaceAccess: IntatisProtocol.WorkspaceAccess
    ) -> Set<ToolCapability> {
        var capabilities = internalToolRegistryAugmenter?
            .additionalCapabilities
            .intersection([.buildKnowledge, .searchKnowledge]) ?? []
        if workspaceAccess == .readOnly {
            capabilities.remove(.buildKnowledge)
        }
        return capabilities
    }

    private func resetCodexRuntime() async {
        codexRuntimeGeneration &+= 1
        codexUserInputPresenter.cancelAll()
        let startupTask = codexStartupTask
        startupTask?.cancel()
        codexStartupTask = nil
        codexEventTask?.cancel()
        let eventTask = codexEventTask
        codexEventTask = nil
        let runtime = codexRuntime
        codexRuntime = nil
        codexRuntimeBinding = nil
        codexApprovalIDs.removeAll()
        codexApprovalActions.removeAll()
        codexGoalSnapshot = nil
        goal = nil
        isGoalContinuing = false
        isGoalRuntimeReady = false
        await unregisterCodexWorkTaskAgents()
        clearCodexChildPresentation()
        await runtime?.shutdown()
        if let startupTask {
            _ = try? await startupTask.value
        }
        if let eventTask { await eventTask.value }
        codexEventTask?.cancel()
        let lateEventTask = codexEventTask
        codexEventTask = nil
        if let lateEventTask { await lateEventTask.value }
    }

    /// Native MCP config is process-frozen. Any durable authority mutation
    /// drains this generation before another turn can observe stale grants.
    func nativeMCPAuthorityDidChange() async {
        await resetCodexRuntime()
    }

    @discardableResult
    private func startCodexRuntimeForCurrentMain() async throws
        -> CodexAppServerSession
    {
        let main = AgentID(rawValue: projectSettings.mainAgentName)
        guard let binding = latestCoworkProjection.agentRoster[main]?
                .agentInferenceBinding
                ?? projectSettings.defaultInferenceProfileBinding else {
            throw IntatisError.config(
                "Cowork has no exact @main inference binding for Codex Runtime.")
        }
        return try await codexSession(for: binding)
    }

    private func codexImageURLs(
        for attachments: [CoworkDraftAttachment]
    ) async throws -> [URL] {
        var urls: [URL] = []
        urls.reserveCapacity(attachments.count)
        for attachment in attachments {
            guard attachment.mime.hasPrefix("image/") else {
                throw IntatisComposerAttachmentResolutionError.unsupported(
                    attachment.id,
                    mime: attachment.mime,
                    surface: "Codex Runtime")
            }
            guard let ref = await artifactStore.ref(
                for: attachment.id) else {
                throw IntatisComposerAttachmentResolutionError.missing(
                    attachment.id)
            }
            urls.append(artifactStore.absoluteURL(for: ref))
        }
        return urls
    }

    private func handleCodexEvent(
        _ event: CodexRuntimeEvent
    ) async {
        let main = AgentID(rawValue: projectSettings.mainAgentName)
        switch event {
        case .ready(let identity):
            codexRootThreadID = identity.threadID
            for child in codexChildThreadsByID.values.sorted(by: {
                $0.threadID < $1.threadID
            }) {
                await reconcileCodexChildRoster(child)
            }
            agents = agentPresentation(from: latestCoworkProjection)
            isGoalRuntimeReady = true
            setPermissionReviewerStatus(.enabled(
                AgentID(rawValue: "codex-auto-review")))
        case .turnStarted:
            isAgentWorkActive = true
        case .assistantDelta(let itemID, let text, let phase):
            _ = await appendCodexProjectionEvent(.messageDelta(
                MessageDeltaPayload(
                    messageId: MessageID(
                        rawValue: "codex:\(itemID)"),
                    role: .agent,
                    agent: main,
                    textDelta: text,
                    phase: phase)))
        case .assistantCompleted(let itemID, let text, let phase):
            _ = await appendCodexProjectionEvent(.messageCompleted(
                MessageCompletedPayload(
                    messageId: MessageID(
                        rawValue: "codex:\(itemID)"),
                    role: .agent,
                    agent: main,
                    text: text,
                    phase: phase)))
        case .reasoningDelta:
            break
        case .appServerEvent(var payload):
            payload.agent = main
            _ = await appendCodexProjectionEvent(
                .codexAppServerEvent(payload))
        case .itemStarted(let item):
            _ = await appendCodexProjectionEvent(.toolCall(ToolCallPayload(
                toolCallId: "codex:\(item.id)",
                agent: main,
                name: item.title,
                args: item.detail)))
        case .itemCompleted(let item):
            let observation = [item.status, item.detail]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            _ = await appendCodexProjectionEvent(.toolResult(ToolResultPayload(
                toolCallId: "codex:\(item.id)",
                observation: observation.isEmpty
                    ? "completed"
                    : observation,
                outcome: item.isFailure ? .failed : .succeeded,
                failureSource: item.isFailure ? .runtimeFailed : nil)))
        case .approvalRequested(let request):
            let localID = RequestID.new()
            codexApprovalIDs[localID] = request.requestID
            let requestingAgent = codexChildThreadsByID[request.threadID]?
                .agentID ?? main
            permissionQueue.append(PendingPermission(
                request: PermissionRequestPayload(
                    requestId: localID,
                    agent: requestingAgent,
                    tool: request.title,
                    args: "",
                    risk: .high,
                    reason: request.summary,
                    approvalMode: .manual),
                requestedSeq: -1))
            pendingPermission = permissionQueue.first
        case .approvalResolved(let runtimeID):
            guard let localID = codexApprovalIDs.first(where: {
                $0.value == runtimeID
            })?.key else { return }
            codexApprovalIDs.removeValue(forKey: localID)
            let action = codexApprovalActions.removeValue(forKey: localID)
            permissionQueue.removeAll { $0.id == localID }
            pendingPermission = permissionQueue.first
            if let action {
                let approved = action == .approve
                    || action == .approveAndRemember
                permissionNotice = PermissionResolutionNotice(
                    id: "codex:\(runtimeID.description)",
                    requestId: localID,
                    tool: "Codex Runtime",
                    decision: approved ? .allow : .deny,
                    risk: .high,
                    reason: approved
                        ? "Codex Runtime request approved by user"
                        : "Codex Runtime request declined by user",
                    source: .user,
                    action: action,
                    resolvedSeq: -1)
            }
        case .responsesUsage(let usage):
            _ = await appendCodexProjectionEvent(.responsesUsage(
                ResponsesUsagePayload(
                    turnID: TurnID(
                        rawValue: "codex:\(usage.turnID)"),
                    responseMessageID: usage.responseMessageItemID.map {
                        MessageID(rawValue: "codex:\($0)")
                    },
                    agentID: main,
                    inputTokens: usage.inputTokens,
                    cachedInputTokens: usage.cachedInputTokens,
                    cacheWriteInputTokens: usage.cacheWriteInputTokens,
                    outputTokens: usage.outputTokens,
                    reasoningOutputTokens: usage.reasoningOutputTokens,
                    totalTokens: usage.totalTokens,
                    durationMs: usage.durationMs)))
        case .goalUpdated(let snapshot):
            codexGoalSnapshot = snapshot
            goal = snapshot.map(Self.codexGoalPresentation)
            isGoalContinuing = snapshot?.status == "active"
        case .turnCompleted(let result):
            let outcome: TurnOutcome
            let failureSource: ExecutionFailureSource?
            switch result.status {
            case "completed":
                outcome = .completed
                failureSource = nil
            case "interrupted":
                outcome = .interrupted
                failureSource = .turnCancelled
            default:
                outcome = .failed
                failureSource = .runtimeFailed
            }
            _ = await appendCodexProjectionEvent(.turnOutcome(
                TurnOutcomePayload(
                    turnID: TurnID(
                        rawValue: "codex:\(result.turnID)"),
                    outcome: outcome,
                    failureSource: failureSource,
                    reason: result.succeeded
                        ? nil
                        : "Codex Runtime turn ended with status \(result.status).",
                    agentID: main)))
            isAgentWorkActive = false
            isWorking = false
            if !result.succeeded {
                composerError = result.errorMessage ?? result.status
            }
        case .runtimeError(let code, let message, let fatal):
            composerError = message
            if fatal || code != "codex_runtime" {
                _ = await appendCodexProjectionEvent(.error(ErrorPayload(
                    code: code,
                    message: fatal
                        ? "Codex Runtime became unavailable."
                        : "Codex Runtime reported a request failure.",
                    fatal: fatal)))
            }
            if fatal {
                isAgentWorkActive = false
                isWorking = false
                isGoalRuntimeReady = false
                isGoalContinuing = false
                codexGoalSnapshot = nil
                goal = nil
                setPermissionReviewerStatus(.failed(message))
                await unregisterCodexWorkTaskAgents()
                clearCodexChildPresentation()
                codexRuntime = nil
                codexStartupTask = nil
                codexEventTask = nil
            }
        case .child(let childEvent):
            await handleCodexChildEvent(childEvent)
        }
    }

    private func handleCodexChildEvent(
        _ event: CodexRuntimeChildEvent
    ) async {
        switch event {
        case .threadUpdated(let thread):
            codexChildThreadsByID[thread.threadID] = thread
            codexChildThreadIDByAgentID[thread.agentID] = thread.threadID
            await registerCodexWorkTaskAgent(thread)
            if codexRootThreadID != nil {
                await reconcileCodexChildRoster(thread)
            }
            agents = agentPresentation(from: latestCoworkProjection)
            refreshRuntimeBusy()
            publishCodexChildUpdate(thread.agentID)
        case .turnStarted(let threadID, _):
            await updateLocalCodexChildStatus(
                threadID: threadID,
                status: "active")
        case .assistantDelta(
            let threadID,
            _,
            let itemID,
            let text,
            let phase):
            guard let agentID = codexChildThreadsByID[threadID]?.agentID else {
                return
            }
            let id = codexChildMessageID(
                threadID: threadID,
                itemID: itemID)
            var item = codexChildItem(agentID: agentID, id: id)
                ?? CodeItem(
                    id: id,
                    kind: .agent,
                    title: "@\(codexChildDisplayName(threadID))",
                    body: "",
                    complete: false,
                    messagePhase: phase)
            item.body += text
            item.complete = false
            if let phase { item.messagePhase = phase }
            upsertCodexChildItem(item, agentID: agentID)
            _ = await appendCodexProjectionEvent(.messageDelta(
                MessageDeltaPayload(
                    messageId: MessageID(rawValue: id),
                    role: .agent,
                    agent: agentID,
                    textDelta: text,
                    phase: phase)))
        case .assistantCompleted(
            let threadID,
            _,
            let itemID,
            let text,
            let phase):
            guard let agentID = codexChildThreadsByID[threadID]?.agentID else {
                return
            }
            let id = codexChildMessageID(
                threadID: threadID,
                itemID: itemID)
            var item = codexChildItem(agentID: agentID, id: id)
                ?? CodeItem(
                    id: id,
                    kind: .agent,
                    title: "@\(codexChildDisplayName(threadID))",
                    body: text)
            item.body = text
            item.complete = true
            item.messagePhase = phase
            upsertCodexChildItem(item, agentID: agentID)
            _ = await appendCodexProjectionEvent(.messageCompleted(
                MessageCompletedPayload(
                    messageId: MessageID(rawValue: id),
                    role: .agent,
                    agent: agentID,
                    text: text,
                    phase: phase)))
        case .userMessage(
            let threadID,
            _,
            let itemID,
            let text):
            guard let agentID = codexChildThreadsByID[threadID]?.agentID else {
                return
            }
            upsertCodexChildItem(CodeItem(
                id: codexChildMessageID(
                    threadID: threadID,
                    itemID: itemID),
                kind: .user,
                title: "You → @\(codexChildDisplayName(threadID))",
                body: text,
                complete: true),
                agentID: agentID)
        case .reasoningDelta:
            break
        case .appServerEvent(let threadID, var payload):
            guard let agentID = codexChildThreadsByID[threadID]?.agentID else {
                return
            }
            payload.agent = agentID
            guard await appendCodexProjectionEvent(
                .codexAppServerEvent(payload)) else {
                return
            }
            let id = payload.eventID
            var fields: [String] = []
            if let itemType = payload.itemType {
                fields.append("type: \(itemType)")
            }
            if let phase = payload.phase {
                fields.append("phase: \(phase.rawValue)")
            }
            if let status = payload.status {
                fields.append("status: \(status)")
            }
            if let willRetry = payload.willRetry {
                fields.append("willRetry: \(willRetry)")
            }
            if let message = payload.message {
                fields.append(message)
            }
            if let details = payload.details {
                fields.append(details)
            }
            let fixedBody = fields.joined(separator: "\n")
            var item = codexChildItem(agentID: agentID, id: id)
                ?? CodeItem(
                    id: id,
                    kind: .runtimeEvent,
                    title: payload.method,
                    body: fixedBody,
                    complete: payload.textDelta == nil,
                    codexAppServerEvent: payload)
            if let delta = payload.textDelta {
                item.body += delta
                item.complete = false
            } else if !fixedBody.isEmpty {
                item.body = fixedBody
                item.complete = true
            }
            item.codexAppServerEvent = payload
            upsertCodexChildItem(
                item,
                agentID: agentID,
                publishes: payload.textDelta == nil)
        case .itemStarted(let threadID, _, let runtimeItem):
            guard let agentID = codexChildThreadsByID[threadID]?.agentID else {
                return
            }
            upsertCodexChildItem(
                codexCodeItem(
                    runtimeItem,
                    threadID: threadID,
                    complete: false),
                agentID: agentID)
            _ = await appendCodexProjectionEvent(.toolCall(
                ToolCallPayload(
                    toolCallId: codexChildRuntimeItemID(
                        threadID: threadID,
                        itemID: runtimeItem.id),
                    agent: agentID,
                    name: runtimeItem.title,
                    args: runtimeItem.detail)))
        case .itemCompleted(let threadID, _, let runtimeItem):
            guard let agentID = codexChildThreadsByID[threadID]?.agentID else {
                return
            }
            upsertCodexChildItem(
                codexCodeItem(
                    runtimeItem,
                    threadID: threadID,
                    complete: true),
                agentID: agentID)
            let observation = [runtimeItem.status, runtimeItem.detail]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            _ = await appendCodexProjectionEvent(.toolResult(
                ToolResultPayload(
                    toolCallId: codexChildRuntimeItemID(
                        threadID: threadID,
                        itemID: runtimeItem.id),
                    observation: observation.isEmpty
                        ? "completed"
                        : observation,
                    outcome: runtimeItem.isFailure
                        ? .failed
                        : .succeeded,
                    failureSource: runtimeItem.isFailure
                        ? .runtimeFailed
                        : nil)))
        case .responsesUsage(let threadID, let usage):
            guard let agentID = codexChildThreadsByID[threadID]?.agentID,
                  let messageID = usage.responseMessageItemID else {
                return
            }
            let id = codexChildMessageID(
                threadID: threadID,
                itemID: messageID)
            let payload = ResponsesUsagePayload(
                turnID: TurnID(
                    rawValue: "codex:\(usage.turnID)"),
                responseMessageID: MessageID(rawValue: id),
                agentID: agentID,
                inputTokens: usage.inputTokens,
                cachedInputTokens: usage.cachedInputTokens,
                cacheWriteInputTokens: usage.cacheWriteInputTokens,
                outputTokens: usage.outputTokens,
                reasoningOutputTokens: usage.reasoningOutputTokens,
                totalTokens: usage.totalTokens,
                durationMs: usage.durationMs)
            _ = await appendCodexProjectionEvent(.responsesUsage(payload))
            guard var item = codexChildItem(agentID: agentID, id: id) else {
                publishCodexChildUpdate(agentID)
                return
            }
            item.responsesUsage = ResponsesUsageSnapshot(
                id: "codex:\(threadID):\(usage.turnID):usage",
                payload: payload)
            upsertCodexChildItem(item, agentID: agentID)
        case .turnCompleted(let threadID, let result):
            await updateLocalCodexChildStatus(
                threadID: threadID,
                status: result.succeeded ? "idle" : result.status)
        }
    }

    private func codexChildDisplayName(_ threadID: String) -> String {
        codexChildThreadsByID[threadID]?.displayName
            ?? "agent-\(threadID.suffix(8))"
    }

    private func codexChildMessageID(
        threadID: String,
        itemID: String
    ) -> String {
        "codex:\(threadID):message:\(itemID)"
    }

    private func codexChildRuntimeItemID(
        threadID: String,
        itemID: String
    ) -> String {
        "codex:\(threadID):item:\(itemID)"
    }

    private func codexChildItem(
        agentID: AgentID,
        id: String
    ) -> CodeItem? {
        guard let index = codexChildItemIndicesByAgentID[agentID]?[id],
              let items = codexChildItemsByAgentID[agentID],
              items.indices.contains(index) else {
            return nil
        }
        return items[index]
    }

    private func upsertCodexChildItem(
        _ item: CodeItem,
        agentID: AgentID,
        publishes: Bool = true
    ) {
        var items = codexChildItemsByAgentID[agentID] ?? []
        var indices = codexChildItemIndicesByAgentID[agentID] ?? [:]
        if let index = indices[item.id], items.indices.contains(index) {
            items[index] = item
        } else {
            indices[item.id] = items.count
            items.append(item)
        }
        codexChildItemsByAgentID[agentID] = items
        codexChildItemIndicesByAgentID[agentID] = indices
        if publishes {
            publishCodexChildUpdate(agentID)
        }
    }

    private func mergeCodexChildHistory(
        _ history: CodexRuntimeThreadHistory,
        agentID: AgentID
    ) {
        var items: [CodeItem] = []
        var indices: [String: Int] = [:]
        for entry in history.items {
            let item: CodeItem
            switch entry {
            case .user(let id, _, let text):
                item = CodeItem(
                    id: codexChildMessageID(
                        threadID: history.threadID,
                        itemID: id),
                    kind: .user,
                    title: "You → @\(codexChildDisplayName(history.threadID))",
                    body: text,
                    complete: true)
            case .assistant(let id, _, let text, let phase, let complete):
                item = CodeItem(
                    id: codexChildMessageID(
                        threadID: history.threadID,
                        itemID: id),
                    kind: .agent,
                    title: "@\(codexChildDisplayName(history.threadID))",
                    body: text,
                    complete: complete,
                    messagePhase: phase)
            case .runtime(_, let runtimeItem):
                item = codexCodeItem(
                    runtimeItem,
                    threadID: history.threadID,
                    complete: true)
            }
            guard indices[item.id] == nil else { continue }
            indices[item.id] = items.count
            items.append(item)
        }
        let liveItems = codexChildItemsByAgentID[agentID] ?? []
        for liveItem in liveItems {
            if let index = indices[liveItem.id], items.indices.contains(index) {
                items[index] = preferredCodexChildItem(
                    items[index],
                    liveItem)
            } else {
                indices[liveItem.id] = items.count
                items.append(liveItem)
            }
        }
        codexChildItemsByAgentID[agentID] = items
        codexChildItemIndicesByAgentID[agentID] = indices
        codexChildHistoryLoadedThreadIDs.insert(history.threadID)
        publishCodexChildUpdate(agentID)
    }

    private func preferredCodexChildItem(
        _ lhs: CodeItem,
        _ rhs: CodeItem
    ) -> CodeItem {
        var preferred: CodeItem
        if rhs.submissionID != nil,
           lhs.submissionID == nil {
            preferred = rhs
        } else if lhs.complete != rhs.complete {
            preferred = lhs.complete ? lhs : rhs
        } else if rhs.body.count > lhs.body.count {
            preferred = rhs
        } else {
            preferred = lhs
        }
        if preferred.responsesUsage == nil {
            preferred.responsesUsage = lhs.responsesUsage
                ?? rhs.responsesUsage
        }
        if preferred.codexAppServerEvent == nil {
            preferred.codexAppServerEvent = lhs.codexAppServerEvent
                ?? rhs.codexAppServerEvent
        }
        return preferred
    }

    /// Codex thread/read supplies the authoritative ordered transcript. The
    /// EventLog contributes host audit/product rows and live callbacks may be
    /// newer than the read response. Merge by stable item ID, with a counted
    /// user-message key only for the unavoidable App Server/EventLog dual
    /// representation of the same direct input.
    private func mergeCodexChildPresentationItems(
        _ codexItems: [CodeItem],
        _ durableItems: [CodeItem]
    ) -> [CodeItem] {
        var result = codexItems
        var indices = Dictionary(
            uniqueKeysWithValues: result.enumerated().map {
                ($0.element.id, $0.offset)
            })
        var userIndicesByBody: [String: [Int]] = [:]
        for (index, item) in result.enumerated()
            where item.kind == .user {
            userIndicesByBody[item.body, default: []].append(index)
        }
        for durable in durableItems {
            if let index = indices[durable.id],
               result.indices.contains(index) {
                result[index] = preferredCodexChildItem(
                    result[index],
                    durable)
                continue
            }
            if durable.kind == .user,
               var candidates = userIndicesByBody[durable.body],
               let index = candidates.first,
               result.indices.contains(index) {
                candidates.removeFirst()
                userIndicesByBody[durable.body] = candidates
                result[index] = preferredCodexChildItem(
                    result[index],
                    durable)
                continue
            }
            indices[durable.id] = result.count
            result.append(durable)
        }
        return result
    }

    /// A local delivery attempt is not part of the Codex child transcript
    /// until App Server acknowledges it or thread/read proves it. Pending rows
    /// stay out of conversation presentation; rejected/unknown rows become an
    /// explicit local error instead of masquerading as child history.
    private func codexChildDeliveryPresentationItems(
        _ items: [CodeItem]
    ) -> [CodeItem] {
        items.map { source in
            guard source.kind == .user,
                  source.submissionID != nil else { return source }
            switch source.submissionStatus {
            case .completed:
                return source
            case .failed:
                return CodeItem(
                    id: source.id + ":delivery",
                    kind: .error,
                    title: source.submissionFailure?.code
                        == "child_message_delivery_unknown"
                        ? "Subagent message delivery unknown"
                        : "Subagent message not delivered",
                    body: source.submissionFailure?.message
                        ?? "The subagent message was not delivered.",
                    complete: true,
                    isFailure: true,
                    submissionID: source.submissionID)
            case .queued, .running, .none:
                return CodeItem(
                    id: source.id + ":delivery-pending",
                    kind: .note,
                    title: "Subagent message delivery pending",
                    body: "Waiting for Codex App Server delivery confirmation.",
                    complete: true,
                    submissionID: source.submissionID)
            case .cancelled:
                return CodeItem(
                    id: source.id + ":delivery-cancelled",
                    kind: .error,
                    title: "Subagent message delivery cancelled",
                    body: "Delivery was cancelled before it could be confirmed.",
                    complete: true,
                    isFailure: true,
                    submissionID: source.submissionID)
            }
        }
    }

    private func codexCodeItem(
        _ runtimeItem: CodexRuntimeItem,
        threadID: String,
        complete: Bool
    ) -> CodeItem {
        let kind: CodeItem.Kind
        switch runtimeItem.kind {
        case .collaboration, .subagent:
            kind = .agentToAgent
        case .plan, .reasoning:
            kind = .runtimeEvent
        case .command, .fileChange, .mcpTool, .dynamicTool,
             .webSearch, .image, .other:
            kind = .toolCall
        }
        return CodeItem(
            id: codexChildRuntimeItemID(
                threadID: threadID,
                itemID: runtimeItem.id),
            kind: kind,
            title: runtimeItem.title,
            body: runtimeItem.detail,
            complete: complete,
            isFailure: runtimeItem.isFailure)
    }

    /// Projects only App Server-verified descendants into the existing durable
    /// Cowork roster. The upstream thread ID is the identity; display names are
    /// presentation only and never establish membership.
    private func reconcileCodexChildRoster(
        _ thread: CodexRuntimeThreadDescriptor
    ) async {
        let agentID = thread.agentID
        let parentAgentID: AgentID? = {
            if thread.parentThreadID == codexRootThreadID {
                return AgentID(rawValue: projectSettings.mainAgentName)
            }
            return codexChildThreadsByID[thread.parentThreadID]?.agentID
        }()
        let metadata = CoworkEventMetadata(
            threadID: ThreadID(rawValue: thread.threadID),
            sender: parentAgentID,
            agentID: agentID,
            scope: .agent)

        if thread.isArchived || thread.status == "shutdown" {
            let wasAttached = codexChildRosterPayloadByThreadID[
                thread.threadID] != nil
                || latestCoworkProjection.agentRoster[agentID] != nil
            guard wasAttached,
                  !codexDetachedChildThreadIDs.contains(
                    thread.threadID) else {
                return
            }
            guard await appendCodexProjectionEvents([
                .agentDetached(AgentDetachedPayload(
                    agent: agentID,
                    reason: "Codex descendant thread archived",
                    metadata: metadata)),
            ]) else { return }
            codexDetachedChildThreadIDs.insert(thread.threadID)
            codexChildStatusByThreadID.removeValue(
                forKey: thread.threadID)
            return
        }

        codexDetachedChildThreadIDs.remove(thread.threadID)
        let proposed = await codexChildRosterPayload(
            for: thread,
            metadata: metadata)
        let current = codexChildRosterPayloadByThreadID[thread.threadID]
            ?? latestCoworkProjection.agentRoster[agentID]
        var events: [Event] = []
        if current.map({ !codexRosterFactsEqual($0, proposed) }) ?? true {
            var attached = proposed
            attached.previousAgentInferenceBinding = current?
                .agentInferenceBinding
            attached.inferenceBindingChangeReason = current == nil
                ? nil
                : "verified Codex descendant metadata changed"
            events.append(.agentAttached(attached))
        }
        if let parentAgentID,
           (codexChildParentAgentByThreadID[thread.threadID]
                ?? latestCoworkProjection.agentOwners[agentID])
                != parentAgentID {
            events.append(.agentSpawned(AgentSpawnedPayload(
                requestedBy: parentAgentID,
                agent: agentID,
                path: proposed.path,
                model: proposed.model,
                agentInferenceBinding: proposed.agentInferenceBinding,
                metadata: metadata)))
        }
        if let state = codexDurableAgentState(thread.status),
           (codexChildStatusByThreadID[thread.threadID]
                ?? latestCoworkProjection.agentStatuses[agentID])
                != state {
            events.append(.agentStatus(AgentStatusPayload(
                agent: agentID,
                state: state)))
        }
        if !events.isEmpty {
            guard await appendCodexProjectionEvents(events) else {
                return
            }
        }
        codexChildRosterPayloadByThreadID[thread.threadID] = proposed
        if let parentAgentID {
            codexChildParentAgentByThreadID[thread.threadID] = parentAgentID
        }
        if let state = codexDurableAgentState(thread.status) {
            codexChildStatusByThreadID[thread.threadID] = state
        }
    }

    /// Registers the exact canonical task name supplied by App Server for a
    /// verified descendant. This directory is only a host-owned lookup used by
    /// the explicit task_link_agent tool; no role, nickname, file name, or
    /// WorkTask text is interpreted as an association.
    private func registerCodexWorkTaskAgent(
        _ thread: CodexRuntimeThreadDescriptor
    ) async {
        let directory = await codexWorkTaskController.agentDirectory
        if thread.isArchived || thread.status == "shutdown" {
            if let previous = codexChildTaskNameByThreadID.removeValue(
                forKey: thread.threadID) {
                await directory.unregister(
                    taskName: previous,
                    verifiedAgentID: thread.agentID)
            }
            return
        }
        guard let taskName = thread.agentPath?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !taskName.isEmpty else { return }
        let previous = codexChildTaskNameByThreadID[thread.threadID]
        if previous == taskName { return }
        do {
            try await directory.replace(
                previousTaskName: previous,
                taskName: taskName,
                verifiedAgentID: thread.agentID)
            codexChildTaskNameByThreadID[thread.threadID] = taskName
        } catch {
            let message = IntatisLocalization.format(
                "Codex subagent @%@ has an ambiguous canonical task identity; WorkTask linking is disabled for it.",
                thread.displayName)
            composerError = message
            _ = await appendCodexProjectionEvent(.error(ErrorPayload(
                code: "codex_agent_task_identity_ambiguous",
                message: message,
                fatal: false)))
        }
    }

    private func unregisterCodexWorkTaskAgents() async {
        let directory = await codexWorkTaskController.agentDirectory
        for (threadID, taskName) in codexChildTaskNameByThreadID {
            guard let agentID = codexChildThreadsByID[threadID]?.agentID else {
                continue
            }
            await directory.unregister(
                taskName: taskName,
                verifiedAgentID: agentID)
        }
        codexChildTaskNameByThreadID.removeAll(keepingCapacity: false)
    }

    private struct EffectiveCodexRosterPreset {
        let path: String
        let model: ModelID
        let permissionProfile: String
        let inferenceBinding: AgentInferenceBinding
        let providerID: String
        let reasoningEffort: String?
    }

    private func codexChildRosterPayload(
        for thread: CodexRuntimeThreadDescriptor,
        metadata: CoworkEventMetadata
    ) async -> AgentAttachedPayload {
        let fallbackPath = thread.cwd.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty
            ? projectSettings.primaryWorkspace?.path
                ?? projectSettings.workspaces.first?.path
                ?? ""
            : URL(fileURLWithPath: thread.cwd)
                .standardizedFileURL.path
        let fallbackModel = thread.requestedModel.flatMap {
            $0.isEmpty ? nil : ModelID(rawValue: $0)
        } ?? ModelID(rawValue: "unknown")
        guard let preset = await effectiveCodexRosterPreset(
                for: thread,
                visited: []),
              codexThread(thread, matches: preset) else {
            return AgentAttachedPayload(
                agent: thread.agentID,
                path: fallbackPath,
                model: fallbackModel,
                profile: PermissionProfile.locked.rawValue,
                agentInferenceBinding: nil,
                metadata: metadata)
        }
        return AgentAttachedPayload(
            agent: thread.agentID,
            path: preset.path,
            model: preset.model,
            profile: preset.permissionProfile,
            agentInferenceBinding: preset.inferenceBinding,
            metadata: metadata)
    }

    private func effectiveCodexRosterPreset(
        for thread: CodexRuntimeThreadDescriptor,
        visited: Set<String>
    ) async -> EffectiveCodexRosterPreset? {
        guard !visited.contains(thread.threadID) else { return nil }
        var visited = visited
        visited.insert(thread.threadID)

        if let role = thread.agentRole {
            guard let profile = projectSettings.codexAgentProfiles
                    .first(where: { $0.roleName == role }),
                  let configuredPath = canonicalWorkspaceIdentity(
                    profile.workspacePath),
                  let route = try? await registryBox.responsesRuntimeRoute(
                    for: profile.inferenceBinding),
                  route.model == profile.inferenceBinding.modelID,
                  route.reasoningEffort == thread.reasoningEffort
                    || thread.reasoningEffort == nil else {
                // An explicit unknown or unresolvable role is never treated as
                // inheritance from its parent.
                return nil
            }
            return EffectiveCodexRosterPreset(
                path: configuredPath,
                model: profile.inferenceBinding.modelID,
                permissionProfile: profile.permissionProfile,
                inferenceBinding: profile.inferenceBinding,
                providerID: IntatisHostApplication.identity.fieldNameStem
                    + "_agent_" + role,
                reasoningEffort: route.reasoningEffort)
        }

        if thread.parentThreadID == codexRootThreadID {
            let main = AgentID(rawValue: projectSettings.mainAgentName)
            guard let binding = latestCoworkProjection.agentRoster[main]?
                    .agentInferenceBinding
                    ?? projectSettings.defaultInferenceProfileBinding,
                  let configuredPath = projectSettings.primaryWorkspace
                    .flatMap({ canonicalWorkspaceIdentity($0.path) }),
                  let route = try? await registryBox.responsesRuntimeRoute(
                    for: binding) else {
                return nil
            }
            return EffectiveCodexRosterPreset(
                path: configuredPath,
                model: binding.modelID,
                permissionProfile:
                    projectSettings.defaultPermissionProfile,
                inferenceBinding: binding,
                providerID: IntatisHostApplication.identity.fileNameStem,
                reasoningEffort: route.reasoningEffort)
        }

        guard let parent = codexChildThreadsByID[thread.parentThreadID] else {
            return nil
        }
        return await effectiveCodexRosterPreset(
            for: parent,
            visited: visited)
    }

    private func codexThread(
        _ thread: CodexRuntimeThreadDescriptor,
        matches preset: EffectiveCodexRosterPreset
    ) -> Bool {
        guard !thread.cwd.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty,
              let actualPath = canonicalWorkspaceIdentity(thread.cwd),
              actualPath == preset.path else {
            return false
        }
        if !thread.modelProvider.isEmpty,
           thread.modelProvider != preset.providerID {
            return false
        }
        if let requestedModel = thread.requestedModel,
           !requestedModel.isEmpty,
           requestedModel != preset.model.rawValue {
            return false
        }
        if let reasoningEffort = thread.reasoningEffort,
           reasoningEffort != preset.reasoningEffort {
            return false
        }
        return true
    }

    private func codexRosterFactsEqual(
        _ lhs: AgentAttachedPayload,
        _ rhs: AgentAttachedPayload
    ) -> Bool {
        lhs.agent == rhs.agent
            && lhs.path == rhs.path
            && lhs.model == rhs.model
            && lhs.profile == rhs.profile
            && lhs.agentInferenceBinding == rhs.agentInferenceBinding
    }

    private func codexDurableAgentState(
        _ status: String
    ) -> AgentState? {
        switch status {
        case "active", "running", "pendingInit":
            return .thinking
        case "systemError", "errored", "failed":
            return .blocked
        case "idle", "waiting", "completed", "notLoaded":
            return .idle
        default:
            return nil
        }
    }

    private func updateLocalCodexChildStatus(
        threadID: String,
        status: String
    ) async {
        guard let previous = codexChildThreadsByID[threadID] else { return }
        let updated = CodexRuntimeThreadDescriptor(
            threadID: previous.threadID,
            parentThreadID: previous.parentThreadID,
            sessionID: previous.sessionID,
            agentNickname: previous.agentNickname,
            agentRole: previous.agentRole,
            agentPath: previous.agentPath,
            name: previous.name,
            preview: previous.preview,
            cwd: previous.cwd,
            modelProvider: previous.modelProvider,
            requestedModel: previous.requestedModel,
            reasoningEffort: previous.reasoningEffort,
            serviceTier: previous.serviceTier,
            runtimeWorkspaceRoots: previous.runtimeWorkspaceRoots,
            isArchived: previous.isArchived,
            status: status,
            activeFlags: previous.activeFlags,
            canAcceptDirectInput: previous.canAcceptDirectInput,
            createdAt: previous.createdAt)
        codexChildThreadsByID[threadID] = updated
        await reconcileCodexChildRoster(updated)
        agents = agentPresentation(from: latestCoworkProjection)
        refreshRuntimeBusy()
        publishCodexChildUpdate(updated.agentID)
    }

    private func publishCodexChildUpdate(_ agentID: AgentID) {
        agentThreadUpdateHub.publish(
            agentIDs: [agentID],
            throughSeq: -1)
    }

    private static func codexThreadIsWorking(_ status: String) -> Bool {
        status == "active"
            || status == "running"
            || status == "pendingInit"
    }

    private static func codexAgentStatus(_ status: String) -> String {
        switch status {
        case "active", "running", "pendingInit":
            return "running"
        case "notLoaded":
            return "idle"
        case "shutdown":
            return "detached"
        case "systemError", "errored":
            return "failed"
        default:
            return status
        }
    }

    private func clearCodexChildPresentation() {
        codexRootThreadID = nil
        codexChildThreadsByID.removeAll(keepingCapacity: false)
        codexChildThreadIDByAgentID.removeAll(keepingCapacity: false)
        codexChildItemsByAgentID.removeAll(keepingCapacity: false)
        codexChildItemIndicesByAgentID.removeAll(keepingCapacity: false)
        codexChildHistoryLoadedThreadIDs.removeAll(keepingCapacity: false)
        codexChildRosterPayloadByThreadID.removeAll(keepingCapacity: false)
        codexChildParentAgentByThreadID.removeAll(keepingCapacity: false)
        codexChildStatusByThreadID.removeAll(keepingCapacity: false)
        codexChildTaskNameByThreadID.removeAll(keepingCapacity: false)
        codexDetachedChildThreadIDs.removeAll(keepingCapacity: false)
        codexChildProjectionGeneration = UUID()
        agents = agentPresentation(from: latestCoworkProjection)
        refreshRuntimeBusy()
    }

    @discardableResult
    private func appendCodexProjectionEvent(
        _ event: Event
    ) async -> Bool {
        await appendCodexProjectionEvents([event])
    }

    @discardableResult
    private func appendCodexProjectionEvents(
        _ events: [Event]
    ) async -> Bool {
        guard !events.isEmpty else { return true }
        guard !codexProjectionFailed else { return false }
        do {
            _ = try await log.append(events)
            return true
        } catch {
            codexProjectionFailed = true
            let message = IntatisLocalization.format(
                "Codex Runtime stopped because its \(IntatisHostApplication.identity.name) projection could not be persisted: %@",
                error.localizedDescription)
            composerError = message
            projectionError = message
            isAgentWorkActive = false
            isWorking = false
            let runtime = codexRuntime
            codexRuntime = nil
            codexRuntimeBinding = nil
            codexStartupTask = nil
            codexEventTask = nil
            await runtime?.shutdown()
            return false
        }
    }

    private func commitProjectionSnapshot(
        _ snapshot:
            CoworkSessionProjectionSnapshot
    ) {
        let commitStart =
            DispatchTime.now().uptimeNanoseconds
        var published = false
        defer {
            let commitEnd =
                DispatchTime.now()
                    .uptimeNanoseconds
            snapshot.projectionBatch?.finish(
                commitDurationNanoseconds:
                    commitEnd >= commitStart
                    ? commitEnd - commitStart
                    : 0,
                published: published)
        }
        guard projectionCommitFence?
                .accept(
                    identity:
                        snapshot.identity,
                    throughSeq:
                        snapshot.throughSeq)
                == true else {
            return
        }
        published = true

        if let barrier =
                snapshot.barrierEnvelope {
            observeProjectionBarrier(barrier)
        }
        let changedThreadAgents = IntatisExecutionTracePresentation.isEnabled
            ? snapshot.threadAgentIDs
            : snapshot.visibleThreadAgentIDs
        if !changedThreadAgents.isEmpty {
            agentThreadUpdateHub.publish(
                agentIDs: changedThreadAgents,
                throughSeq: snapshot.throughSeq)
        }
        if let permission =
                snapshot.permission {
            let nextPending =
                presentedPermission(
                    projected:
                        permission.latest)
            if nextPending != pendingPermission {
                pendingPermission = nextPending
            }
            let nextNotice =
                permission.latestResolved
            if nextNotice != permissionNotice {
                permissionNotice = nextNotice
            }
        }
        if let coworkProjection =
                snapshot.cowork,
           coworkProjection
                != latestCoworkProjection {
            applyCoworkProjection(
                coworkProjection)
        }
    }

    /// Reattaching a process-owned Cowork session to a window performs one
    /// idempotent latest-snapshot flush. The normal subscription remains live
    /// while the session is off-screen; this only closes the bounded trailing
    /// publication race and cannot overwrite a newer generation/sequence.
    func flushProjectionForPresentation() async {
        guard !didStop,
              let projectionPump,
              let snapshot =
                await projectionPump.flushNow() else {
            return
        }
        commitProjectionSnapshot(snapshot)
    }

    private func observeProjectionBarrier(
        _ envelope: Envelope
    ) {
        if case .permissionResolved(let payload) =
                envelope.event,
           let requestID = payload.requestId {
            suppressedPermissionRequestIDs
                .remove(requestID)
        }
        observeSubmittedIntentEvent(envelope)
    }

    func mcpProjectAgents()
        async throws -> [MCPProductAgentDescriptor]
    {
        let projection = latestCoworkProjection
        let main = AgentID(
            rawValue: projectSettings.mainAgentName)
        return projection.capabilityLeaseAgents
            .compactMap { leaseID, agentID in
                guard let lease =
                        projection.capabilityLeases[
                            leaseID],
                      projection.agentRoster[
                        agentID] != nil else {
                    return nil
                }
                let reviewer =
                    MCPReservedControlPlaneIdentity
                        .deniesMCP(agentID)
                let taskSuffix = lease.taskID.map {
                    " · task \($0.rawValue)"
                } ?? ""
                return MCPProductAgentDescriptor(
                    agentID: agentID,
                    displayName:
                        "\(agentID.rawValue)\(taskSuffix)",
                    parentAgentID:
                        projection.agentOwners[
                            agentID],
                    isWorker:
                        agentID != main,
                    isPermissionReviewer:
                        reviewer,
                    capabilityLeaseID:
                        lease.id,
                    taskID: lease.taskID,
                    supportsNativeCodexMCP:
                        agentID == main
                            && lease.taskID == nil,
                    mcpCapabilityCeiling:
                        reviewer
                            ? []
                            : CodexRuntimeMCPProjector
                                .requiredNativeSurfaceCapabilities)
            }
            .sorted {
                if $0.agentID != $1.agentID {
                    return $0.agentID.rawValue
                        < $1.agentID.rawValue
                }
                return $0.capabilityLeaseID.rawValue
                    < $1.capabilityLeaseID.rawValue
            }
    }

    func mcpDispatchInput(
        for descriptor:
            MCPProductAgentDescriptor,
        reason: MCPRuntimeActivationReason
    ) async throws -> MCPAgentDispatchInput {
        let projection = latestCoworkProjection
        guard !didStop,
              !descriptor.isPermissionReviewer,
              descriptor.supportsNativeCodexMCP,
              !MCPReservedControlPlaneIdentity
                .deniesMCP(
                    descriptor.agentID),
              projection.capabilityLeaseAgents[
                descriptor.capabilityLeaseID]
                == descriptor.agentID,
              var capabilityLease =
                projection.capabilityLeases[
                    descriptor.capabilityLeaseID],
              capabilityLease.taskID
                == descriptor.taskID else {
            throw IntatisError.permissionDenied(
                "The selected Cowork Agent capability lease is no longer active.")
        }
        let workspaceCandidates =
            projection.workspaceLeaseAgents
                .compactMap {
                    leaseID, agentID
                    -> WorkspaceLease? in
                    guard agentID
                            == descriptor.agentID,
                          let lease =
                            projection.workspaceLeases[
                                leaseID],
                          lease.taskID
                            == descriptor.taskID
                    else {
                        return nil
                    }
                    return lease
                }
        guard workspaceCandidates.count == 1,
              let workspaceLease =
                workspaceCandidates.first,
              workspaceLease.rootIdentity?
                .matchesCurrentDirectory(
                    rootPath:
                        workspaceLease.rootPath)
                == true else {
            throw IntatisError.permissionDenied(
                "The selected Cowork Agent does not have one exact live workspace lease.")
        }
        let durable =
            try await MCPDurableSessionState.load(
                from: log)
        capabilityLease.mcpGrants =
            durable.grants(
                agentID: descriptor.agentID,
                capabilityLeaseID:
                    descriptor
                        .capabilityLeaseID,
                taskID: descriptor.taskID)
        let workspaceRoot =
            URL(fileURLWithPath:
                    workspaceLease.rootPath)
                .standardizedFileURL
        let allowsShell =
            PlatformProfile.current.allowsShell
        let skillSnapshot =
            try await SkillCatalogService.shared.snapshot(
                configuration: .standard(
                    workspaceRoot: workspaceRoot,
                    access: AppConfig.skillRootAccess))
        return MCPAgentDispatchInput(
            agentID: descriptor.agentID,
            capabilityLease:
                capabilityLease,
            workspaceLease: workspaceLease,
            baseRegistry: skillSnapshot.augmenting(
                Orchestrator.toolRegistry(
                    for: capabilityLease,
                    agentID: descriptor.agentID,
                    includesTerminal:
                        allowsShell)),
            activationReason: reason)
    }

    func stop(reason: String = "Cowork session stopped") async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard !didStop else { return }
        didStop = true
        codexUserInputPresenter.cancelAll()
        if let projectionPump,
           let finalSnapshot =
                await projectionPump.finishAndFlush()
        {
            commitProjectionSnapshot(
                finalSnapshot)
        }
        let runningSubscription = subscription
        runningSubscription?.cancel()
        subscription = nil
        let runningOrchestrator = orchestrator
        let runningGoalRuntime = goalRuntime
        let runningCodexRuntime = codexRuntime
        let runningCodexStartup = codexStartupTask
        let runningCodexEvents = codexEventTask
        runningCodexStartup?.cancel()
        runningCodexEvents?.cancel()
        let runningOperations = Array(activeOperations.values)
        orchestrator = nil
        goalRuntime = nil
        codexRuntime = nil
        codexRuntimeBinding = nil
        codexStartupTask = nil
        codexEventTask = nil
        for operation in runningOperations { operation.cancel() }
        isWorking = false
        isAgentWorkActive = false
        isGoalContinuing = false
        isGoalRuntimeReady = false
        codexGoalSnapshot = nil
        goal = nil
        addAgentStatus = .idle
        setPermissionReviewerStatus(.disabled)
        let task = Task<Void, Never> {
            #if canImport(AVFoundation)
            await self.voiceInput.shutdown()
            #endif
            // Let the cancelled startup/stream task observe cancellation before
            // teardown touches the captured runtime. This prevents a stale
            // startup continuation from releasing the restore scheduler gate.
            if let runningSubscription { await runningSubscription.value }
            if let runningGoalRuntime {
                await runningGoalRuntime.shutdown()
            }
            await runningCodexRuntime?.shutdown()
            _ = try? await runningCodexStartup?.value
            if let runningCodexEvents {
                await runningCodexEvents.value
            }
            if let runningOrchestrator {
                await runningOrchestrator.cancelAll(reason: reason)
            }
            for operation in runningOperations { await operation.value }
            await self.waitForDirectOperationsToDrain()
        }
        shutdownTask = task
        await task.value
        await unregisterCodexWorkTaskAgents()
        activeOperations.removeAll()
        // Execution owns permission waits. Release any UI-only waiters only
        // after every data-plane task has observed cancellation and exited.
        for (requestID, waiter) in permissionWaiters {
            suppressedPermissionRequestIDs.insert(requestID)
            waiter.resolve(Self.cancelledPermissionResolution(
                reason: reason))
        }
        permissionWaiters.removeAll()
        permissionQueue.removeAll()
        codexApprovalIDs.removeAll()
        codexApprovalActions.removeAll()
        codexWriterLease?.release()
        codexWriterLease = nil
        if var pending = pendingPermission, pending.state.isActionable {
            pending.state = .expired
            pendingPermission = pending
        }
        for lease in workspaceAccessLeases.values { lease.release() }
        workspaceAccessLeases.removeAll()
        projectionPump = nil
        projectionCommitFence = nil
        shutdownTask = nil
    }

    private func restoreSubmittedIntentState(
        from projection: CoworkProjection,
        marksUnfinishedAsInterrupted: Bool
    ) {
        for intent in projection.submittedIntents {
            submittedPayloads[intent.id] = intent.payload
            canonicalSubmissionIDs.insert(intent.id)
            if let attempt = intent.attempt {
                submissionAttempts[intent.id] = attempt
            }
            if marksUnfinishedAsInterrupted,
               intent.status == .queued || intent.status == .running {
                restoredSubmissionIDs.insert(intent.id)
            }
        }
    }

    private func settleRestoredCodexChildDeliveriesAsUnknown() async {
        let events: [Event] = latestCoworkProjection.submittedIntents
            .compactMap { intent in
                guard intent.status == .queued || intent.status == .running,
                      let attempt = intent.attempt,
                      let target = intent.payload.to,
                      codexChildThreadIDByAgentID[target] != nil else {
                    return nil
                }
                return .submissionStatusChanged(
                    SubmissionStatusChangedPayload(
                        submissionID: intent.id,
                        status: .failed,
                        attempt: attempt,
                        failure: SubmissionFailure(
                            code: "child_message_delivery_unknown",
                            message: "Delivery was interrupted before confirmation. Read this subagent's Codex history before retrying the message.",
                            retryable: false)))
            }
        guard !events.isEmpty else { return }
        _ = await appendCodexProjectionEvents(events)
    }

    private func restoreSubmittedIntentOutbox() async {
        do {
            let document = try await submittedIntentStore.loadOutbox()
            outboxEntries = Dictionary(
                uniqueKeysWithValues: document.entries.compactMap { entry in
                    guard let id = entry.payload.submissionID else { return nil }
                    return (id, entry)
                })
            rebuildOutboxThreadItems(publishesChanges: true)
        } catch {
            composerError = IntatisLocalization.format(
                "The local submission outbox could not be read: %@",
                error.localizedDescription)
        }
    }

    private func observeSubmittedIntentEvent(_ envelope: Envelope) {
        switch envelope.event {
        case .userMessage(let payload):
            guard let id = payload.submissionID else { return }
            canonicalSubmissionIDs.insert(id)
            guard submittedPayloads[id] == nil else {
                rebuildOutboxThreadItems(publishesChanges: false)
                return
            }
            submittedPayloads[id] = payload
            // A canonical user row supersedes an owner-only outbox overlay.
            // The same snapshot already publishes the typed target agent.
            rebuildOutboxThreadItems(publishesChanges: false)
        case .submissionStatusChanged(let payload):
            submissionAttempts[payload.submissionID] = max(
                submissionAttempts[payload.submissionID] ?? 0,
                payload.attempt)
            if payload.status == .completed || payload.status == .cancelled {
                submissionQueue.removeAll { $0 == payload.submissionID }
            }
        default:
            break
        }
    }

    func agentThreadUpdates(
        for agentID: AgentID
    ) -> AsyncStream<CoworkAgentThreadUpdate> {
        agentThreadUpdateHub.stream(for: agentID)
    }

    func agentThreadSnapshot(
        agentID: AgentID
    ) async -> CoworkAgentThreadSnapshot {
        if let threadID = codexChildThreadIDByAgentID[agentID] {
            let durable = await projectionPump?
                .coworkAgentThreadSnapshot(
                    agentID: agentID,
                    showsExecutionTrace:
                        IntatisExecutionTracePresentation.isEnabled,
                    additionalItems: [])
            if !codexChildHistoryLoadedThreadIDs.contains(threadID),
               let runtime = codexRuntime {
                do {
                    let history = try await runtime.threadHistory(
                        threadID: threadID)
                    mergeCodexChildHistory(
                        history,
                        agentID: agentID)
                } catch {
                    composerError = error.localizedDescription
                }
            }
            let descriptor = codexChildThreadsByID[threadID]
            let items = mergeCodexChildPresentationItems(
                codexChildItemsByAgentID[agentID] ?? [],
                codexChildDeliveryPresentationItems(
                    durable?.items ?? []))
            return CoworkAgentThreadSnapshot(
                agentID: agentID,
                items: items,
                projectedThroughSeq: durable?.projectedThroughSeq
                    ?? projectionCommitFence?.throughSeq
                    ?? -1,
                projectionGeneration: codexChildProjectionGeneration,
                isAgentWorking: descriptor.map {
                    Self.codexThreadIsWorking($0.status)
                } ?? durable?.isAgentWorking ?? false)
        }
        let additionalItems = outboxThreadItemsByAgent[agentID] ?? []
        guard let projectionPump else {
            return CodeProjection().coworkAgentThreadSnapshot(
                agentID: agentID,
                showsExecutionTrace:
                    IntatisExecutionTracePresentation.isEnabled,
                additionalItems: additionalItems,
                projectedThroughSeq: -1,
                projectionGeneration: UUID(),
                isAgentWorking: false)
        }
        let projected = await projectionPump.coworkAgentThreadSnapshot(
            agentID: agentID,
            showsExecutionTrace: IntatisExecutionTracePresentation.isEnabled,
            additionalItems: additionalItems)
        let interruptedFailure = SubmissionFailure(
            code: "interrupted",
            message: IntatisLocalization.string(
                "This submission was queued or running when the previous runtime stopped. Retry explicitly to run it again."),
            retryable: true)
        let items = projected.items.map { item -> CodeItem in
            guard item.kind == .user,
                  let submissionID = item.submissionID,
                  restoredSubmissionIDs.contains(submissionID) else {
                return item
            }
            var interrupted = item
            interrupted.submissionStatus = .failed
            interrupted.submissionFailure = interruptedFailure
            interrupted.isFailure = true
            return interrupted
        }
        return CoworkAgentThreadSnapshot(
            agentID: projected.agentID,
            items: items,
            projectedThroughSeq: projected.projectedThroughSeq,
            projectionGeneration: projected.projectionGeneration,
            isAgentWorking: projected.isAgentWorking)
    }

    private func rebuildOutboxThreadItems(
        publishesChanges: Bool
    ) {
        let previous = outboxThreadItemsByAgent
        var next: [AgentID: [CodeItem]] = [:]
        for entry in outboxEntries.values.sorted(by: {
            $0.createdAt < $1.createdAt
        }) {
            guard let id = entry.payload.submissionID,
                  !canonicalSubmissionIDs.contains(id) else { continue }
            let failure = SubmissionFailure(
                code: "event_log_unavailable",
                message: entry.lastCanonicalError
                    ?? IntatisLocalization.string(
                        "The submission is safe in the local outbox but has not entered the session EventLog."),
                retryable: true)
            let item = CodeItem(
                id: id.rawValue,
                kind: .user,
                title: IntatisLocalization.string("You"),
                body: entry.payload.text,
                tags: entry.payload.tags ?? [],
                goal: entry.payload.goal,
                attachments: entry.payload.attachments ?? [],
                isFailure: true,
                submissionID: id,
                submissionStatus: .failed,
                submissionAttempt: nil,
                submissionFailure: failure)
            let agentID = entry.payload.to
                ?? AgentID(rawValue: projectSettings.mainAgentName)
            next[agentID, default: []].append(item)
        }
        guard next != previous else { return }
        outboxThreadItemsByAgent = next
        guard publishesChanges else { return }
        agentThreadUpdateHub.publish(
            agentIDs: Array(Set(previous.keys).union(next.keys)),
            throughSeq: projectionCommitFence?.throughSeq ?? -1)
    }

    private func publishSubmissionThreadChange(_ submissionID: SubmissionID) {
        guard let payload = submittedPayloads[submissionID]
                ?? outboxEntries[submissionID]?.payload else {
            return
        }
        let agentID = payload.to
            ?? AgentID(rawValue: projectSettings.mainAgentName)
        agentThreadUpdateHub.publish(
            agentIDs: [agentID],
            throughSeq: projectionCommitFence?.throughSeq ?? -1)
    }

    private func applyCoworkProjection(_ projection: CoworkProjection) {
        latestCoworkProjection = projection
        if let canonical = projection.sessionSettings?.cowork,
           canonical.sessionID == sessionID,
           canonical != projectSettings {
            projectSettings = canonical
        }
        let nextWorkTasks =
            Self.workTaskPresentation(
                from: projection)
        if nextWorkTasks != workTasks {
            workTasks = nextWorkTasks
        }
        let nextAgents =
            agentPresentation(
                from: projection)
        if nextAgents != agents {
            agents = nextAgents
        }

        let nextSummary = CoworkStatusSummary(
            activeCount: projection.activeTasks.count,
            runningCount: projection.runningTasks.count,
            completedCount: projection.completedTasks.count,
            failedCount: projection.failedTasks.count,
            pendingMailboxCount: projection.mailboxes.values.reduce(0) {
                $0 + $1.pendingMessages.count + $1.pendingTasks.count
            },
            completedMailboxCount: projection.mailboxes.values.reduce(0) {
                $0 + $1.completedTasks.count
            },
            workspaceLeaseCount: projection.workspaceLeases.count,
            capabilityLeaseCount: projection.capabilityLeases.count,
            runningTasks: projection.runningTasks.map(taskLine),
            failedTasks: projection.failedTasks.map(taskLine),
            recentCompletedTasks: projection.completedTasks.map(taskLine))
        if nextSummary != summary {
            summary = nextSummary
        }
        let nextProject = Self.makeProjectInfo(
            sessionID: sessionID,
            settings: projectSettings,
            projection: projection)
        if nextProject != project {
            project = nextProject
        }
        let retryable = projection.failedTasks + projection.cancelledTasks
        let nextRetryableTasks =
            Dictionary(
                uniqueKeysWithValues:
                    retryable.map {
                        ($0.id.rawValue, $0)
                    })
        if nextRetryableTasks != retryableTasks {
            retryableTasks =
                nextRetryableTasks
        }
        scheduleSubmissionDrain()
    }

    private func agentPresentation(from projection: CoworkProjection) -> [CoworkAgentInfo] {
        let liveAgentIDs = Set(projection.agentRoster.keys)
        let runningAgentIDs = Set(projection.tasks.values.compactMap { task in
            task.status == .running ? task.assignee : nil
        })
        let failedAgentIDs = Set(projection.tasks.values.compactMap { task in
            task.status == .failed ? task.assignee : nil
        })
        var workspaceLeaseCounts: [AgentID: Int] = [:]
        for agentID in projection.workspaceLeaseAgents.values {
            workspaceLeaseCounts[agentID, default: 0] += 1
        }
        var capabilityLeasesByAgent: [AgentID: [CapabilityLease]] = [:]
        for (leaseID, agentID) in projection.capabilityLeaseAgents {
            guard let lease = projection.capabilityLeases[leaseID] else { continue }
            capabilityLeasesByAgent[agentID, default: []].append(lease)
        }
        var inferenceOptionsByBinding: [AgentInferenceBinding: AppInferenceProfileOption] = [:]
        for option in inferenceProfileOptions where inferenceOptionsByBinding[option.binding] == nil {
            inferenceOptionsByBinding[option.binding] = option
        }

        var result = projection.historicalAgentsInCreationOrder
            .map { payload in
                let mailbox = projection.mailboxes[payload.agent] ?? CoworkMailboxView()
                let capabilityLeases = capabilityLeasesByAgent[payload.agent] ?? []
                let workspaceLeaseCount = workspaceLeaseCounts[payload.agent] ?? 0
                let capabilityLeaseCount = capabilityLeases.count
                let isMain = payload.agent.rawValue == projectSettings.mainAgentName
                let isReviewer = payload.agent == Orchestrator.automaticPermissionReviewerID
                let isAttached = liveAgentIDs.contains(payload.agent)
                let codexThread = codexChildThreadIDByAgentID[payload.agent]
                    .flatMap { codexChildThreadsByID[$0] }
                let binding = payload.agentInferenceBinding
                let inferenceOption = binding.flatMap { inferenceOptionsByBinding[$0] }
                let inferenceResolution: CoworkInferenceResolution
                if binding == nil {
                    inferenceResolution = codexThread == nil
                        ? .legacy
                        : .unresolved
                } else if inferenceResolutionFailures[payload.agent.rawValue] != nil {
                    inferenceResolution = .unresolved
                } else {
                    inferenceResolution = .resolved
                }
                let status: String
                if let codexThread {
                    status = Self.codexAgentStatus(codexThread.status)
                } else if !isAttached {
                    status = "detached"
                } else if runningAgentIDs.contains(payload.agent) {
                    status = "running"
                } else if let state = projection.agentStatuses[payload.agent] {
                    status = state.rawValue
                } else if !mailbox.pendingTasks.isEmpty {
                    status = "queued"
                } else if !mailbox.pendingMessages.isEmpty {
                    status = "mailbox"
                } else if failedAgentIDs.contains(payload.agent) {
                    status = "failed"
                } else {
                    status = "idle"
                }
                return CoworkAgentInfo(
                    id: payload.agent.rawValue,
                    name: codexThread?.displayName
                        ?? payload.agent.rawValue,
                    workspace: codexThread.flatMap {
                        $0.cwd.isEmpty ? nil : $0.cwd
                    } ?? payload.path,
                    model: codexThread?.requestedModel
                        ?? payload.model.rawValue,
                    permissionProfile: Self.permissionDescription(
                        payload.profile),
                    inferenceProfileLabel: inferenceOption?.title
                        ?? codexThread?.requestedModel,
                    inferenceProfileRef: binding?.inferenceProfileRef,
                    inferenceConnectionLabel: binding?.safeRouteLabel
                        ?? codexThread?.modelProvider,
                    inferenceVariant: inferenceOption?.variantTitle
                        ?? binding?.variantID
                        ?? codexThread.map {
                            [$0.reasoningEffort, $0.serviceTier]
                                .compactMap { $0 }
                                .joined(separator: " · ")
                        }.flatMap { $0.isEmpty ? nil : $0 },
                    inferenceResolution: inferenceResolution,
                    status: status,
                    role: isMain
                        ? "main"
                        : isReviewer
                            ? "reviewer"
                            : codexThread?.agentRole
                                ?? Self.role(for: capabilityLeases),
                    pendingTasks: mailbox.pendingTasks.count,
                    pendingMessages: mailbox.pendingMessages.count,
                    completedTasks: mailbox.completedTasks.count,
                    workspaceLease: workspaceLeaseCount > 0
                        ? IntatisLocalization.format(
                            "%lld workspace lease",
                            Int64(workspaceLeaseCount))
                        : nil,
                    capabilityLease: capabilityLeaseCount > 0
                        ? IntatisLocalization.format(
                            "%lld capability lease",
                            Int64(capabilityLeaseCount))
                        : nil,
                    isAttached: codexThread.map {
                        !$0.isArchived && $0.status != "shutdown"
                    } ?? isAttached,
                    canRemove: codexThread.map {
                        !$0.isArchived
                    } ?? (isAttached && !isMain && !isReviewer),
                    isConversationSelectable: !isReviewer)
            }
        let existingIDs = Set(result.map(\.id))
        for thread in codexChildThreadsByID.values.sorted(by: {
            let lhsCreated = $0.createdAt ?? Int.max
            let rhsCreated = $1.createdAt ?? Int.max
            if lhsCreated != rhsCreated {
                return lhsCreated < rhsCreated
            }
            return $0.threadID < $1.threadID
        }) where !existingIDs.contains(thread.agentID.rawValue) {
            let inferenceVariant = [
                thread.reasoningEffort,
                thread.serviceTier,
            ].compactMap { $0 }.joined(separator: " · ")
            result.append(CoworkAgentInfo(
                id: thread.agentID.rawValue,
                name: thread.displayName,
                workspace: thread.cwd.isEmpty
                    ? projectSettings.workspaces.first?.path ?? ""
                    : thread.cwd,
                model: thread.requestedModel
                    ?? thread.modelProvider,
                permissionProfile: "Codex",
                inferenceProfileLabel: thread.requestedModel,
                inferenceConnectionLabel: thread.modelProvider,
                inferenceVariant: inferenceVariant.isEmpty
                    ? nil
                    : inferenceVariant,
                inferenceResolution: .resolved,
                status: Self.codexAgentStatus(thread.status),
                role: thread.agentRole ?? "subagent",
                pendingTasks: 0,
                pendingMessages: 0,
                completedTasks: 0,
                workspaceLease: thread.runtimeWorkspaceRoots.isEmpty
                    ? nil
                    : IntatisLocalization.format(
                        "%lld workspace root",
                        Int64(thread.runtimeWorkspaceRoots.count)),
                capabilityLease: nil,
                isAttached: !thread.isArchived
                    && thread.status != "shutdown",
                canRemove: !thread.isArchived,
                isConversationSelectable: true))
        }
        return result
    }

    /// UI history and runtime routing deliberately use different membership
    /// tests. A detached identity remains in `agents` for transcript browsing,
    /// but every operational caller must pass through the live roster first.
    private func liveAgentInfo(named name: String) -> CoworkAgentInfo? {
        let agentID = AgentID(rawValue: name)
        guard latestCoworkProjection.agentRoster[agentID] != nil else {
            return nil
        }
        return agents.first(where: { $0.id == agentID.rawValue })
    }

    private func refreshInferenceResolutionState() async {
        guard let orchestrator else {
            inferenceResolutionFailures = [:]
            return
        }
        let failures = await orchestrator.inferenceResolutionFailures()
        inferenceResolutionFailures = Dictionary(uniqueKeysWithValues: failures.map {
            ($0.key.rawValue, $0.value)
        })
        agents = agentPresentation(from: latestCoworkProjection)
        scheduleSubmissionDrain()
    }

    private static func goalPresentation(
        from projection: CoworkProjection,
        controlsEnabled: Bool
    ) -> CoworkGoalCardInfo? {
        guard let goal = projection.currentGoal else { return nil }
        let audit = goal.latestAudit
        let proven = audit?.requirements.filter { $0.status == .proven }.count
        let auditSummary: String?
        if let audit {
            var parts = [audit.verdict.rawValue]
            if !audit.remainingWork.isEmpty {
                parts.append(IntatisLocalization.format(
                    "Remaining: %@",
                    audit.remainingWork.joined(separator: "; ")))
            }
            if let blocker = audit.blocker, !blocker.isEmpty {
                parts.append(IntatisLocalization.format("Blocker: %@", blocker))
            }
            auditSummary = parts.joined(separator: " · ")
        } else {
            auditSummary = nil
        }
        let runOrdinal = projection.continuationRuns.values
            .filter { $0.goalID == goal.id }
            .map(\.ordinal)
            .max()
        let canResume: Bool
        switch goal.status {
        case .paused, .blocked, .budgetLimited, .usageLimited:
            canResume = true
        case .active:
            canResume = goal.noProgressRuns >= 2
        case .completed:
            canResume = false
        }
        return CoworkGoalCardInfo(
            id: goal.id.rawValue,
            objective: goal.objective,
            status: goal.status.rawValue,
            activeElapsedSeconds: goal.activeElapsedSeconds,
            activeSince: goal.status == .active ? goal.updatedAt : nil,
            tokensUsed: goal.tokensUsed,
            tokenBudget: goal.tokenBudget,
            auditProvenCount: proven,
            auditRequirementCount: audit?.requirements.count,
            latestAuditSummary: auditSummary,
            currentRunOrdinal: runOrdinal,
            revision: goal.revision,
            canPause: controlsEnabled && goal.status == .active,
            canResume: controlsEnabled && canResume,
            canEdit: controlsEnabled && goal.status != .completed,
            canClear: controlsEnabled)
    }

    private static func codexGoalPresentation(
        _ goal: CodexRuntimeGoalSnapshot
    ) -> CoworkGoalCardInfo {
        CoworkGoalCardInfo(
            id: "codex:\(goal.threadID)",
            objective: goal.objective,
            status: goal.status,
            activeElapsedSeconds: Double(goal.timeUsedSeconds),
            activeSince: nil,
            tokensUsed: goal.tokensUsed,
            tokenBudget: goal.tokenBudget,
            auditProvenCount: nil,
            auditRequirementCount: nil,
            latestAuditSummary: nil,
            currentRunOrdinal: nil,
            revision: goal.updatedAt,
            canPause: goal.status == "active",
            canResume: goal.status == "paused"
                || goal.status == "blocked"
                || goal.status == "usageLimited"
                || goal.status == "budgetLimited",
            canEdit: goal.status != "complete",
            canClear: true)
    }

    private static func workTaskPresentation(from projection: CoworkProjection) -> CoworkWorkTaskSummary {
        let ordered = projection.workTasks.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.rawValue < rhs.id.rawValue
        }
        let lines = ordered.enumerated().map { index, task in
            let dependencies = task.dependsOn.map { dependencyID -> String in
                let status = projection.workTasks[dependencyID]?.status.rawValue ?? "missing"
                return "\(dependencyID.rawValue) [\(status)]"
            }
            let evidence = task.evidence.map {
                "\($0.kind) · \($0.reference) — \($0.summary)"
            }
            return CoworkWorkTaskLine(
                id: task.id.rawValue,
                ordinal: index + 1,
                title: task.title,
                detail: task.description,
                status: task.status.rawValue,
                dependencySummary: dependencies.isEmpty
                    ? nil : dependencies.joined(separator: ", "),
                statusReason: task.progressNote,
                acceptanceCriteria: task.acceptanceCriteria,
                result: task.result,
                evidence: evidence,
                linkedInvocationIDs: task.latestInvocationIDs.map(\.rawValue))
        }
        return CoworkWorkTaskSummary(tasks: lines)
    }

    private func taskLine(_ task: CoworkTaskView) -> CoworkTaskLine {
        let assignee = task.assignee.map { "@\($0.rawValue)" }
            ?? IntatisLocalization.string("Unassigned")
        let title = task.contract.map { "\(assignee) · \($0.roleHint)" } ?? assignee
        let detail = task.contract?.objective ?? task.report?.summary ?? task.error ?? task.result ?? ""
        return CoworkTaskLine(id: task.id.rawValue, title: title, detail: detail, status: task.status.rawValue)
    }

    private func restoreWorkspaceAccess(for projection: CoworkProjection) {
        for workspace in projectSettings.workspaces {
            _ = retainWorkspaceAccess(forPath: workspace.path)
        }
        for payload in projection.agentRoster.values {
            _ = retainWorkspaceAccess(forPath: payload.path)
        }
    }

    private func retainWorkspaceAccess(forPath path: String) -> URL? {
        let key = URL(fileURLWithPath: path)
            .standardizedFileURL
            .path
        if let existing = workspaceAccessLeases[key] {
            return existing.canonicalURL
        }
        do {
            guard let lease = try WorkspaceAccess.restoreAccess(
                forPath: path,
                in: sessionID) else { return nil }
            if let existing = workspaceAccessLeases[lease.canonicalPath] {
                lease.release()
                return existing.canonicalURL
            }
            workspaceAccessLeases[lease.canonicalPath] = lease
            return lease.canonicalURL
        } catch {
            sessionStorageWarning = IntatisLocalization.format(
                "Workspace access could not be read safely: %@",
                error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    private func adoptWorkspaceAccess(_ lease: WorkspaceAccessLease) -> URL {
        if let existing = workspaceAccessLeases[lease.canonicalPath] {
            lease.release()
            return existing.canonicalURL
        }
        workspaceAccessLeases[lease.canonicalPath] = lease
        return lease.canonicalURL
    }

    private func releaseWorkspaceAccess(forPath path: String) {
        let key = URL(fileURLWithPath: path)
            .standardizedFileURL
            .path
        workspaceAccessLeases.removeValue(forKey: key)?.release()
    }

    /// Resolves the UI candidate back to the current durable settings before
    /// any mutation. Exact stored-path matches are preferred; alias matching
    /// requires one unambiguous canonical identity. Callers must still check
    /// `isPrimary` and must not trust a stale `CoworkWorkspaceInfo.canRemove`.
    private func configuredWorkspace(
        matching candidate: String
    ) -> CoworkProjectWorkspace? {
        let storedCandidate = URL(fileURLWithPath: candidate)
            .standardizedFileURL
            .path
        if let exact = projectSettings.workspaces.first(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == storedCandidate
        }) {
            return exact
        }
        guard let candidateIdentity = canonicalWorkspaceIdentity(candidate) else {
            return nil
        }
        var match: CoworkProjectWorkspace?
        for workspace in projectSettings.workspaces {
            guard let identity = canonicalWorkspaceIdentity(workspace.path) else {
                return nil
            }
            guard identity == candidateIdentity else { continue }
            guard match == nil else { return nil }
            match = workspace
        }
        return match
    }

    /// Returns the canonical bookmark key only when no remaining settings or
    /// roster entry refers to the candidate directory. Any identity that
    /// cannot be proven is retained (fail closed).
    private func removableWorkspaceAccessPath(
        candidate: String,
        settings: CoworkProjectSettings,
        remainingAgents: [Agent]
    ) -> String? {
        guard let candidateIdentity = canonicalWorkspaceIdentity(candidate) else {
            return nil
        }
        let candidateStored = URL(fileURLWithPath: candidate).standardizedFileURL.path
        let remainingPaths = settings.workspaces.map(\.path)
            + remainingAgents.map { $0.workspaceRoot.path }
        for path in remainingPaths {
            if URL(fileURLWithPath: path).standardizedFileURL.path == candidateStored {
                return nil
            }
            guard let identity = canonicalWorkspaceIdentity(path) else {
                return nil
            }
            if identity == candidateIdentity { return nil }
        }
        return candidateIdentity
    }

    private func canonicalWorkspaceIdentity(_ path: String) -> String? {
        let stored = URL(fileURLWithPath: path).standardizedFileURL.path
        if let lease = workspaceAccessLeases[stored] {
            return lease.canonicalPath
        }
        return try? PathConfinement.canonicalExistingDirectory(
            URL(fileURLWithPath: path)).path
    }

    private func ensureAutomaticPermissionReview(existingProjection projection: CoworkProjection) async {
        guard let orchestrator else {
            setPermissionReviewerStatus(.failed(
                IntatisLocalization.string("Cowork session is not ready.")))
            return
        }
        setPermissionReviewerStatus(.enabling)
        let mainID = AgentID(rawValue: projectSettings.mainAgentName)
        let workspaceURL: URL
        guard let mainAgent = await orchestrator.agentList().first(where: {
            $0.name == mainID
        }) else {
            setPermissionReviewerStatus(.failed(
                IntatisLocalization.format(
                    "@%@ must be attached before automatic permission review can start.",
                    mainID.rawValue)))
            return
        }
        // GoalVerifier preserves its existing first-main freeze, but that
        // route neither supplies nor gates the permission reviewer. A legacy
        // main without an exact binding may leave Goal verification
        // unavailable while automatic permission review still starts from its
        // independently configured binding.
        if let mainBinding = mainAgent.agentInferenceBinding {
            _ = await registryBox
                .freezeResolvableControlPlaneBinding(mainBinding)
        }
        guard let permissionReviewerBinding = await registryBox
            .resolvablePermissionReviewerBinding() else {
            setPermissionReviewerStatus(.failed(
                permissionReviewerConfigurationError
                    ?? IntatisLocalization.string(
                        "The permission_reviewer_model exact inference profile is unavailable or incompatible.")))
            return
        }

        if let main = projection.agentRoster[mainID] {
            guard let restored = retainWorkspaceAccess(forPath: main.path) else {
                needsPrimaryWorkspaceAuthorization = true
                setPermissionReviewerStatus(.failed(
                    IntatisLocalization.string(
                        "Primary workspace access must be authorized again before automatic review can start.")))
                return
            }
            workspaceURL = restored
        } else if let workspace = projectSettings.primaryWorkspace {
            guard let restored = retainWorkspaceAccess(forPath: workspace.path) else {
                needsPrimaryWorkspaceAuthorization = true
                setPermissionReviewerStatus(.failed(
                    IntatisLocalization.string(
                        "Primary workspace access must be authorized again before automatic review can start.")))
                return
            }
            workspaceURL = restored
        } else {
            setPermissionReviewerStatus(.failed(
                IntatisLocalization.format(
                    "No primary workspace is available for @%@.",
                    Orchestrator.automaticPermissionReviewerID.rawValue)))
            return
        }

        let result = await orchestrator.enableAutomaticPermissionReview(
            model: permissionReviewerBinding.modelID,
            agentInferenceBinding: permissionReviewerBinding,
            workspaceRoot: workspaceURL)
        guard !Task.isCancelled, self.orchestrator != nil else {
            setPermissionReviewerStatus(.disabled)
            return
        }
        switch result {
        case .enabled(let reviewer), .alreadyEnabled(let reviewer):
            needsPrimaryWorkspaceAuthorization = false
            await synchronizePermissionReviewerHealth(
                using: orchestrator,
                reviewer: reviewer)
        case .failed(let message):
            setPermissionReviewerStatus(.failed(message))
        }
    }

    private func synchronizePermissionReviewerHealth(
        using orchestrator: Orchestrator,
        reviewer: AgentID = Orchestrator.automaticPermissionReviewerID
    ) async {
        guard self.orchestrator != nil else { return }
        guard let health = await orchestrator.automaticPermissionReviewHealth() else {
            setPermissionReviewerStatus(.disabled)
            return
        }
        switch health {
        case .healthy:
            setPermissionReviewerStatus(.enabled(reviewer))
        case .degraded(let reason):
            setPermissionReviewerStatus(.degraded(reason))
        case .shuttingDown:
            setPermissionReviewerStatus(.disabled)
        }
    }

    private func schedulePermissionReviewerHealthRefresh() {
        guard acceptsNewOperations, let orchestrator else { return }
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            await self.synchronizePermissionReviewerHealth(using: orchestrator)
        }
        activeOperations[operationID] = operation
    }

    func retryAutomaticPermissionReview() {
        guard acceptsNewOperations,
              permissionReviewerStatus.canRetry,
              let binding = nextMainInferenceBinding else { return }
        setPermissionReviewerStatus(.enabling)
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            do {
                _ = try await self.codexSession(for: binding)
            } catch {
                let message = error.localizedDescription
                self.composerError = message
                self.setPermissionReviewerStatus(.failed(message))
            }
        }
        activeOperations[operationID] = operation
    }

    @available(*, unavailable, message: "Cowork uses Codex auto_review")
    private func retainedLegacyRetryAutomaticPermissionReview() {
        guard acceptsNewOperations,
              permissionReviewerStatus.canRetry,
              orchestrator != nil else { return }
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            let mainID = AgentID(rawValue: self.projectSettings.mainAgentName)
            if !self.latestCoworkProjection.agentRoster.keys.contains(mainID) {
                await self.bootstrapMainAgentIfNeeded(
                    existingProjection: self.latestCoworkProjection,
                    allowsInitialSessionBootstrap: self.launchMode == .fresh)
            }
            let mainRegistered = await self.orchestrator?.agentList().contains {
                $0.name == mainID
            } ?? false
            guard self.latestCoworkProjection.agentRoster.keys.contains(mainID)
                    || mainRegistered else {
                return
            }
            await self.ensureAutomaticPermissionReview(existingProjection: self.latestCoworkProjection)
            await self.resumeRuntimeIfReady()
        }
        activeOperations[operationID] = operation
    }

    private func resumeRuntimeIfReady() async {
        guard let orchestrator,
              let goalRuntime else { return }
        let mainID = AgentID(rawValue: projectSettings.mainAgentName)
        guard await orchestrator.agentList().contains(where: { $0.name == mainID }) else {
            return
        }
        await refreshInferenceResolutionState()
        guard inferenceResolutionFailures[mainID.rawValue] == nil else {
            projectionError = IntatisLocalization.format(
                "@%@ has an unresolved inference profile. Rebind it before resuming Cowork.",
                mainID.rawValue)
            return
        }
        isGoalRuntimeReady = false
        goal = Self.goalPresentation(
            from: latestCoworkProjection,
            controlsEnabled: false)
        let recoverySafe = await goalRuntime.start()
        guard !Task.isCancelled,
              self.orchestrator === orchestrator,
              self.goalRuntime === goalRuntime else {
            return
        }
        guard recoverySafe else {
            let message = IntatisLocalization.string(
                "Goal recovery could not be completed safely. Pending Cowork work remains stopped; retry after resolving the persistence or cancellation error.")
            projectionError = message
            setPermissionReviewerStatus(.failed(message))
            return
        }
        // Goal startup may append a recovery checkpoint, audit, and the final
        // Phase-L pause before the already-created stream loop receives those
        // events. Synchronize the same projection actor with the durable tail
        // so the UI never exposes a stale active/Pause state after cold
        // recovery and no second projection truth is introduced.
        let postRecoveryReplay =
            await log.replay()
        if let projectionPump {
            do {
                let previouslyCommitted =
                    projectionCommitFence?
                        .throughSeq
                        ?? Int.min
                let snapshot =
                    try await projectionPump
                        .synchronize(
                            with:
                                postRecoveryReplay)
                for envelope in
                    postRecoveryReplay
                    where envelope.seq
                        > previouslyCommitted {
                    observeProjectionBarrier(
                        envelope)
                }
                commitProjectionSnapshot(
                    snapshot)
            } catch {
                projectionError =
                    error.localizedDescription
                return
            }
        }
        let resumedPendingTasks = await orchestrator.startNewTasksKeepingRestoredTasksPaused()
        guard resumedPendingTasks,
              !Task.isCancelled,
              self.orchestrator === orchestrator,
              self.goalRuntime === goalRuntime else {
            return
        }
        isGoalRuntimeReady = true
        projectionError = nil
        goal = Self.goalPresentation(
            from: latestCoworkProjection,
            controlsEnabled: true)
        scheduleSubmissionDrain()
    }

    private func bootstrapMainAgentIfNeeded(existingProjection projection: CoworkProjection,
                                            allowsInitialSessionBootstrap: Bool) async {
        guard !didRequestMainAgentAttach else { return }
        guard let orchestrator else { return }
        let mainID = AgentID(rawValue: projectSettings.mainAgentName)
        guard projection.agentRoster[mainID] == nil else { return }
        guard let workspace = projectSettings.primaryWorkspace else { return }
        guard let url = retainWorkspaceAccess(forPath: workspace.path) else {
            needsPrimaryWorkspaceAuthorization = true
            composerError = IntatisLocalization.format(
                "Primary workspace access must be authorized again before @%@ can be registered.",
                mainID.rawValue)
            setPermissionReviewerStatus(.failed(
                composerError ?? IntatisLocalization.string("Workspace access unavailable.")))
            return
        }
        guard let binding = projectSettings.defaultInferenceProfileBinding else {
            composerError = IntatisLocalization.format(
                "Choose a default inference profile before attaching @%@.",
                mainID.rawValue)
            return
        }
        didRequestMainAgentAttach = true
        let main = Agent(
            name: mainID,
            workspaceRoot: url,
            model: binding.modelID,
            agentInferenceBinding: binding,
            profile: projectSettings.defaultProfile,
            coordinationDepth: Agent.defaultCoordinationDepth)
        let attached: Bool
        if allowsInitialSessionBootstrap {
            guard let permissionReviewerInferenceBinding else {
                didRequestMainAgentAttach = false
                let message = permissionReviewerConfigurationError
                    ?? IntatisLocalization.string(
                        "Configure a resolvable permission_reviewer_model before creating Cowork.")
                composerError = message
                setPermissionReviewerStatus(.failed(message))
                return
            }
            switch await orchestrator.bootstrapFreshSession(
                main: main,
                settings: projectSettings,
                permissionReviewerModel:
                    permissionReviewerInferenceBinding.modelID,
                permissionReviewerInferenceBinding:
                    permissionReviewerInferenceBinding) {
            case .attached, .alreadyAttached:
                attached = true
            case .failed(let message):
                attached = false
                composerError = message
                setPermissionReviewerStatus(.failed(message))
            }
        } else {
            switch await orchestrator.restoreHistoricalMainAgent(
                main,
                settings: projectSettings,
                hostAuthorized: true) {
            case .attached, .alreadyAttached:
                attached = true
            case .failed(let message):
                attached = false
                composerError = message
            }
        }
        if attached {
            // GoalVerifier keeps the first exact, resolvable @main route. The
            // separately configured permission reviewer neither supplies nor
            // gates this best-effort freeze.
            _ = await registryBox
                .freezeResolvableControlPlaneBinding(binding)
            needsPrimaryWorkspaceAuthorization = false
            composerError = nil
        } else {
            // A transient persistence/profile failure must remain retryable.
            didRequestMainAgentAttach = false
        }
    }

    /// Re-establishes only the local security-scoped capability for the
    /// primary workspace. The selected folder must resolve to the exact path
    /// already recorded in canonical session settings; no prompt is sent to a
    /// model as part of this recovery.
    func reauthorizePrimaryWorkspace() {
        guard acceptsNewOperations,
              !isRuntimeMutationBlocked,
              let primary = projectSettings.primaryWorkspace,
              let selected = WorkspaceAccess.choose(
                prompt: IntatisLocalization.string("Reauthorize Primary Workspace")) else {
            return
        }
        guard WorkspaceAccess.selectedLease(selected, matchesStoredPath: primary.path) else {
            composerError = IntatisLocalization.format(
                "Choose the original primary workspace at %@.",
                primary.path)
            needsPrimaryWorkspaceAuthorization = true
            selected.release()
            return
        }
        do {
            try WorkspaceAccess.remember(selected.scopedURL, for: sessionID, isPrimary: true)
        } catch {
            composerError = IntatisLocalization.format(
                "Primary workspace authorization could not be saved: %@",
                error.localizedDescription)
            needsPrimaryWorkspaceAuthorization = true
            selected.release()
            return
        }
        _ = adoptWorkspaceAccess(selected)
        var canonicalSettings = projectSettings
        let legacyPath = URL(fileURLWithPath: primary.path).standardizedFileURL.path
        canonicalSettings.applyValidatedWorkspacePathMappings([
            legacyPath: selected.canonicalPath
        ])
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            if canonicalSettings != self.projectSettings {
                guard await self.updateProjectSettings(canonicalSettings) else {
                    self.needsPrimaryWorkspaceAuthorization = true
                    return
                }
            }
            self.needsPrimaryWorkspaceAuthorization = false
            self.didRequestMainAgentAttach = false
            self.composerError = nil
            await self.bootstrapMainAgentIfNeeded(
                existingProjection: self.latestCoworkProjection,
                allowsInitialSessionBootstrap: self.launchMode == .fresh)
            await self.ensureAutomaticPermissionReview(
                existingProjection: self.latestCoworkProjection)
            if self.isAutomaticPermissionReviewReady {
                self.sessionStorageWarning = nil
            }
            await self.resumeRuntimeIfReady()
        }
        activeOperations[operationID] = operation
    }

    @discardableResult
    func prepareAddAgent(name rawName: String) -> Bool {
        guard acceptsNewOperations else { return false }
        addAgentStatus = .validating
        switch validateNewAgentName(rawName) {
        case .success:
            return true
        case .failure(let message):
            addAgentStatus = .failed(message)
            return false
        }
    }

    func cancelAddAgentSelection() {
        guard acceptsNewOperations else { return }
        if addAgentStatus == .validating {
            addAgentStatus = .idle
        }
    }

    func resetAddAgentStatus() {
        guard acceptsNewOperations else { return }
        addAgentStatus = .idle
    }

    @discardableResult
    func updateProjectSettings(_ settings: CoworkProjectSettings) async -> Bool {
        guard acceptsNewOperations,
              !isRuntimeMutationBlocked else {
            composerError = IntatisLocalization.string(
                "Wait for all Codex root and subagent work to finish before changing project settings.")
            return false
        }
        guard let operationID = beginDirectOperation() else {
            composerError = IntatisLocalization.string(
                "The Cowork session is stopping and cannot change project settings.")
            return false
        }
        defer { finishDirectOperation(operationID) }
        guard let rootProfile = PermissionProfile(
                rawValue: settings.defaultPermissionProfile),
              rootProfile != .locked else {
            composerError = IntatisLocalization.string(
                "The selected root permission profile cannot be represented by the exact Codex Runtime.")
            return false
        }

        let priorSettings = projectSettings
        let rebuildsRuntime = codexRuntimeConfigurationDiffers(
            priorSettings,
            settings)
        let hadRuntime = codexRuntime != nil
            || codexStartupTask != nil
        isWorking = true
        defer { isWorking = false }

        if rebuildsRuntime, hadRuntime {
            await resetCodexRuntime()
        }
        let saved = await persistProjectSettings(settings)
        guard saved else {
            if rebuildsRuntime, hadRuntime {
                _ = try? await startCodexRuntimeForCurrentMain()
            }
            return false
        }
        guard rebuildsRuntime, hadRuntime else { return true }
        do {
            _ = try await startCodexRuntimeForCurrentMain()
            return true
        } catch {
            composerError = IntatisLocalization.format(
                "Settings were saved, but Codex Runtime could not be rebuilt safely: %@",
                error.localizedDescription)
            return false
        }
    }

    private func codexRuntimeConfigurationDiffers(
        _ lhs: CoworkProjectSettings,
        _ rhs: CoworkProjectSettings
    ) -> Bool {
        lhs.mainAgentName != rhs.mainAgentName
            || lhs.defaultPermissionProfile
                != rhs.defaultPermissionProfile
            || lhs.defaultInferenceProfileBinding
                != rhs.defaultInferenceProfileBinding
            || lhs.primaryWorkspace?.path != rhs.primaryWorkspace?.path
            || lhs.codexAgentProfiles != rhs.codexAgentProfiles
            || lhs.codexRuntimeGeneration != rhs.codexRuntimeGeneration
    }

    @discardableResult
    private func persistProjectSettings(_ settings: CoworkProjectSettings) async -> Bool {
        var normalized = settings
        normalized.schemaVersion = CoworkSessionSettings.currentSchemaVersion
        normalized.sessionID = sessionID
        // Runtime generation is an admission fact, not a mutable UI setting.
        // Preserve nil for legacy sessions and the exact durable generation for
        // current sessions; never migrate it while saving ordinary settings.
        normalized.codexRuntimeGeneration =
            projectSettings.codexRuntimeGeneration
        let trimmedMainAgentName = normalized.mainAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.mainAgentName = trimmedMainAgentName.isEmpty ? "main" : trimmedMainAgentName
        let canonicalSettings = normalized
        do {
            let currentAuthority = try await loadCodexRootAuthority()
            let sameIdentityTarget = try await makeCodexRootAuthority(
                settings: canonicalSettings,
                workspaceLeaseID:
                    currentAuthority.workspaceLease.id,
                workspaceID:
                    currentAuthority.workspaceLease.workspaceID,
                capabilityLeaseID:
                    currentAuthority.capabilityLease.id,
                agentInferenceBinding:
                    currentAuthority.binding)
            let rotatesRootAuthority =
                sameIdentityTarget.workspaceLease
                    != currentAuthority.workspaceLease
                || sameIdentityTarget.capabilityLease
                    != currentAuthority.capabilityLease
            let targetAuthority: CodexRootAuthority
            if rotatesRootAuthority {
                targetAuthority = try await makeCodexRootAuthority(
                    settings: canonicalSettings,
                    workspaceLeaseID: .new(),
                    workspaceID: .new(),
                    capabilityLeaseID: .new(),
                    agentInferenceBinding:
                        currentAuthority.binding)
            } else {
                targetAuthority = sameIdentityTarget
            }
            let sessionID = sessionID
            let mainID = AgentID(rawValue: canonicalSettings.mainAgentName)
            _ = try await log.appendSessionStateTransaction { envelopes in
                let current = try SessionProjectionStore
                    .canonicalSessionSettings(
                        from: envelopes,
                        session: sessionID)
                let projection = CoworkProjection.build(from: envelopes)
                let rootWorkspaceLeaseIDs = projection
                    .workspaceLeaseAgents.compactMap {
                        leaseID, agentID -> WorkspaceLeaseID? in
                        guard agentID == mainID,
                              projection.workspaceLeases[leaseID]?
                                .taskID == nil else {
                            return nil
                        }
                        return leaseID
                    }
                let rootCapabilityLeaseIDs = projection
                    .capabilityLeaseAgents.compactMap {
                        leaseID, agentID -> CapabilityLeaseID? in
                        guard agentID == mainID,
                              projection.capabilityLeases[leaseID]?
                                .taskID == nil else {
                            return nil
                        }
                        return leaseID
                    }
                guard current?.kind == .cowork,
                      current?.cowork == currentAuthority.settings,
                      let main = projection.agentRoster[mainID],
                      main == currentAuthority.agent,
                      rootWorkspaceLeaseIDs.count == 1,
                      rootWorkspaceLeaseIDs.first
                        == currentAuthority.workspaceLease.id,
                      projection.workspaceLeases[
                        currentAuthority.workspaceLease.id]
                        == currentAuthority.workspaceLease,
                      rootCapabilityLeaseIDs.count == 1,
                      rootCapabilityLeaseIDs.first
                        == currentAuthority.capabilityLease.id,
                      projection.capabilityLeases[
                        currentAuthority.capabilityLease.id]
                        == currentAuthority.capabilityLease else {
                    throw IntatisError.config(
                        "project settings cannot advance after the durable @main root authority changed")
                }
                var events: [Event] = []
                if current?.kind != .cowork
                    || current?.cowork != canonicalSettings {
                    let (revision, overflow) = (current?.revision ?? 0)
                        .addingReportingOverflow(1)
                    guard !overflow else {
                        throw IntatisError.config(
                            "session settings revision overflow")
                    }
                    events.append(.sessionSettingsUpdated(
                        SessionSettingsUpdatedPayload(
                            revision: revision,
                            previousRevision: current?.revision,
                            changeKind: .updated,
                            kind: .cowork,
                            displayName: current?.displayName,
                            cowork: canonicalSettings)))
                }
                if rotatesRootAuthority {
                    let changedAt = Date()
                    events.append(.capabilityLeaseRevoked(
                        CapabilityLeaseRevokedPayload(
                            agent: mainID,
                            leaseID:
                                currentAuthority.capabilityLease.id,
                            reason:
                                "Codex root authority changed with project settings",
                            metadata: CoworkEventMetadata(
                                agentID: mainID,
                                capabilityLeaseID:
                                    currentAuthority.capabilityLease.id,
                                scope: .capability,
                                createdAt: changedAt))))
                    events.append(.workspaceLeaseRevoked(
                        WorkspaceLeaseRevokedPayload(
                            agent: mainID,
                            leaseID:
                                currentAuthority.workspaceLease.id,
                            reason:
                                "Codex root workspace authority changed with project settings",
                            metadata: CoworkEventMetadata(
                                agentID: mainID,
                                workspaceID:
                                    currentAuthority.workspaceLease.workspaceID,
                                workspaceLeaseID:
                                    currentAuthority.workspaceLease.id,
                                scope: .workspace,
                                createdAt: changedAt))))
                    events.append(.workspaceLeaseGranted(
                        WorkspaceLeaseGrantedPayload(
                            agent: mainID,
                            lease: targetAuthority.workspaceLease,
                            metadata: CoworkEventMetadata(
                                agentID: mainID,
                                workspaceID:
                                    targetAuthority.workspaceLease.workspaceID,
                                workspaceLeaseID:
                                    targetAuthority.workspaceLease.id,
                                scope: .workspace,
                                createdAt: changedAt))))
                    events.append(.capabilityLeaseCreated(
                        CapabilityLeaseCreatedPayload(
                            agent: mainID,
                            lease: targetAuthority.capabilityLease,
                            metadata: CoworkEventMetadata(
                                agentID: mainID,
                                capabilityLeaseID:
                                    targetAuthority.capabilityLease.id,
                                scope: .capability,
                                createdAt: changedAt))))
                }
                let targetMetadata = targetAuthority.agent.metadata
                let metadataMatches = main.metadata?.agentID == mainID
                    && main.metadata?.workspaceID
                        == targetMetadata?.workspaceID
                    && main.metadata?.workspaceLeaseID
                        == targetMetadata?.workspaceLeaseID
                    && main.metadata?.capabilityLeaseID
                        == targetMetadata?.capabilityLeaseID
                    && main.metadata?.scope == .agent
                if main.profile != targetAuthority.agent.profile
                    || main.path != targetAuthority.agent.path
                    || main.model != targetAuthority.agent.model
                    || main.agentInferenceBinding
                        != targetAuthority.agent.agentInferenceBinding
                    || !metadataMatches {
                    events.append(.agentAttached(AgentAttachedPayload(
                        agent: main.agent,
                        path: targetAuthority.agent.path,
                        model: targetAuthority.agent.model,
                        profile: targetAuthority.agent.profile,
                        agentInferenceBinding:
                            targetAuthority.agent.agentInferenceBinding,
                        metadata: targetMetadata)))
                }
                return events
            }
            let document = try await SessionProjectionStore.rebuild(
                from: log)
            guard let canonical = document.coworkSettings else {
                composerError = IntatisLocalization.string(
                    "Session settings were persisted without a readable Cowork snapshot.")
                return false
            }
            projectSettings = canonical
            await orchestrator?.updateExecutionPolicy(
                CoworkExecutionPolicy(tokenBudget: canonical.tokenBudget))
            project = Self.makeProjectInfo(
                sessionID: sessionID,
                settings: canonical,
                projection: latestCoworkProjection)
            composerError = nil
            return true
        } catch {
            composerError = IntatisLocalization.format(
                "Session settings could not be saved: %@",
                error.localizedDescription)
            return false
        }
    }

    func removeAgent(name rawName: String) {
        guard acceptsNewOperations, !isRuntimeMutationBlocked else { return }
        let name = Self.normalizedAgentName(rawName)
        guard !name.isEmpty else { return }
        if let thread = codexChildThreadsByID.values.first(where: {
            $0.displayName == name && !$0.isArchived
        }) {
            guard let runtime = codexRuntime else {
                composerError = IntatisLocalization.string(
                    "The selected Codex subagent is not loaded in this Cowork session.")
                return
            }
            isWorking = true
            let operationID = UUID()
            let operation = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.isWorking = false
                    self.activeOperations.removeValue(forKey: operationID)
                }
                do {
                    try await runtime.archiveDescendantThread(
                        threadID: thread.threadID)
                    self.composerError = nil
                } catch {
                    self.composerError = error.localizedDescription
                }
            }
            activeOperations[operationID] = operation
            return
        }
        if projectSettings.codexAgentProfiles.contains(where: {
            $0.roleName == name
        }) {
            removeCodexAgentProfile(name: name)
            return
        }
        guard let orchestrator else { return }
        guard name != projectSettings.mainAgentName else {
            composerError = IntatisLocalization.format(
                "Cannot remove @%@.",
                projectSettings.mainAgentName)
            return
        }
        guard AgentID(rawValue: name) != Orchestrator.automaticPermissionReviewerID else {
            composerError = IntatisLocalization.format(
                "@%@ is reserved.",
                Orchestrator.automaticPermissionReviewerID.rawValue)
            return
        }
        isWorking = true
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            let projectedRosterPath = self.latestCoworkProjection
                .agentRoster[AgentID(rawValue: name)]?.path
            let wasAttached = await orchestrator.agentList().contains {
                $0.name == AgentID(rawValue: name)
            }
            let detached: Bool
            if wasAttached {
                detached = await orchestrator.detach(AgentID(rawValue: name))
            } else {
                detached = true
            }
            await self.synchronizePermissionReviewerHealth(using: orchestrator)
            guard detached else {
                self.composerError = IntatisLocalization.format(
                    "@%@ could not be removed; it may still have active tasks.",
                    name)
                self.isWorking = false
                return
            }
            // `agentList()` is read after the durable detach so it is the
            // authoritative live roster for capability reference checks.
            let remainingAgents = await orchestrator.agentList()
            let remainingRosterPaths = Set(remainingAgents.map {
                $0.workspaceRoot.standardizedFileURL.path
            })
            var settings = self.projectSettings
            var removedPaths = settings.workspaces
                .filter { $0.agentName == name && !$0.isPrimary }
                .map(\.path)
            if let rosterPath = projectedRosterPath,
               !removedPaths.contains(rosterPath) {
                removedPaths.append(rosterPath)
            }
            settings.removeWorkspaces(
                forAgent: name,
                retainingPaths: remainingRosterPaths)
            guard await self.persistProjectSettings(settings) else {
                // Detach is already durable. Retaining the capability is the
                // safe rollback when the settings transaction cannot advance.
                self.isWorking = false
                return
            }
            do {
                for path in removedPaths {
                    guard let removablePath = self.removableWorkspaceAccessPath(
                        candidate: path,
                        settings: settings,
                        remainingAgents: remainingAgents) else { continue }
                    try WorkspaceAccess.forget(path: removablePath, in: self.sessionID)
                    self.releaseWorkspaceAccess(forPath: removablePath)
                }
            } catch {
                self.composerError = IntatisLocalization.format(
                    "@%@ is detached, but its unreferenced workspace capability was retained because cleanup failed: %@",
                    name,
                    error.localizedDescription)
                self.isWorking = false
                return
            }
            self.isWorking = false
        }
        activeOperations[operationID] = operation
    }

    func removeCodexAgentProfile(name rawName: String) {
        guard acceptsNewOperations, !isRuntimeMutationBlocked else { return }
        let name = Self.normalizedAgentName(rawName)
        guard let profile = projectSettings.codexAgentProfiles.first(where: {
            $0.roleName == name
        }) else { return }
        isWorking = true
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isWorking = false
                self.activeOperations.removeValue(forKey: operationID)
            }
            do {
                let matchingThreads = self.codexChildThreadsByID.values
                    .filter {
                        !$0.isArchived
                            && $0.agentRole == profile.roleName
                    }
                if !matchingThreads.isEmpty {
                    guard let runtime = self.codexRuntime else {
                        throw CodexRuntimeError.notStarted
                    }
                    for thread in matchingThreads {
                        try await runtime.archiveDescendantThread(
                            threadID: thread.threadID)
                    }
                }
                var settings = self.projectSettings
                settings.removeCodexAgentProfile(
                    roleName: profile.roleName)
                settings.removeWorkspaces(
                    forAgent: profile.roleName)
                guard await self.persistProjectSettings(settings) else {
                    return
                }
                let remainingAgents = await self.orchestrator?
                    .agentList() ?? []
                if let removablePath = self.removableWorkspaceAccessPath(
                    candidate: profile.workspacePath,
                    settings: settings,
                    remainingAgents: remainingAgents) {
                    try WorkspaceAccess.forget(
                        path: removablePath,
                        in: self.sessionID)
                    self.releaseWorkspaceAccess(
                        forPath: removablePath)
                }
                await self.resetCodexRuntime()
                try await self.startCodexRuntimeForCurrentMain()
                self.composerError = nil
            } catch {
                self.composerError = error.localizedDescription
            }
        }
        activeOperations[operationID] = operation
    }

    func agentInferenceBinding(name rawName: String) -> AgentInferenceBinding? {
        let name = Self.normalizedAgentName(rawName)
        if let profile = projectSettings.codexAgentProfiles.first(where: {
            $0.roleName == name
        }) {
            return profile.inferenceBinding
        }
        if let thread = codexChildThreadsByID.values.first(where: {
            $0.displayName == name
        }),
           let role = thread.agentRole,
           let profile = projectSettings.codexAgentProfiles.first(where: {
               $0.roleName == role
           }) {
            return profile.inferenceBinding
        }
        return latestCoworkProjection.agentRoster[AgentID(rawValue: name)]?
            .agentInferenceBinding
    }

    func selectMainInferenceProfileForNextSubmission(
        _ binding: AgentInferenceBinding
    ) {
        guard acceptsNewOperations,
              let option = inferenceProfileOptions.first(where: {
                  $0.binding == binding
              }) else { return }
        nextMainInferenceOption = option
    }

    func rebindAgentInferenceProfile(
        name rawName: String,
        binding: AgentInferenceBinding
    ) {
        guard acceptsNewOperations, !isRuntimeMutationBlocked else { return }
        let name = Self.normalizedAgentName(rawName)
        guard !name.isEmpty else { return }
        if projectSettings.codexAgentProfiles.contains(where: {
            $0.roleName == name
        }) {
            rebindCodexAgentProfile(
                name: name,
                binding: binding)
            return
        }
        if let thread = codexChildThreadsByID.values.first(where: {
            $0.displayName == name
        }),
           let role = thread.agentRole,
           projectSettings.codexAgentProfiles.contains(where: {
               $0.roleName == role
           }) {
            rebindCodexAgentProfile(
                name: role,
                binding: binding)
            return
        }
        guard let orchestrator else { return }
        isWorking = true
        composerError = nil
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            let result = await orchestrator.rebindAgentInferenceProfile(
                agentID: AgentID(rawValue: name),
                binding: binding,
                hostAuthorized: true)
            switch result {
            case .rebound, .unchanged:
                await self.refreshInferenceResolutionState()
                if name == self.projectSettings.mainAgentName {
                    // A legacy/unresolved main may become the first usable
                    // GoalVerifier route after an explicit rebind. An already
                    // frozen verifier remains unchanged.
                    _ = await self.registryBox
                        .freezeResolvableControlPlaneBinding(binding)
                    if !self.isAutomaticPermissionReviewReady {
                        await self.ensureAutomaticPermissionReview(
                            existingProjection: self.latestCoworkProjection)
                    }
                }
                await self.resumeRuntimeIfReady()
            case .failed(let message):
                self.composerError = message
            }
            self.isWorking = false
        }
        activeOperations[operationID] = operation
    }

    private func rebindCodexAgentProfile(
        name: String,
        binding: AgentInferenceBinding
    ) {
        isWorking = true
        composerError = nil
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isWorking = false
                self.activeOperations.removeValue(forKey: operationID)
            }
            var settings = self.projectSettings
            guard let index = settings.codexAgentProfiles.firstIndex(where: {
                $0.roleName == name
            }) else { return }
            let previous = settings.codexAgentProfiles[index]
            settings.codexAgentProfiles[index] = CoworkCodexAgentProfile(
                roleName: previous.roleName,
                description: previous.description,
                workspacePath: previous.workspacePath,
                inferenceBinding: binding,
                permissionProfile: previous.permissionProfile,
                addedAt: previous.addedAt)
            guard await self.persistProjectSettings(settings) else { return }
            await self.resetCodexRuntime()
            do {
                try await self.startCodexRuntimeForCurrentMain()
                self.composerError = nil
            } catch {
                self.composerError = error.localizedDescription
            }
        }
        activeOperations[operationID] = operation
    }

    func removeWorkspace(path: String) {
        guard acceptsNewOperations,
              !isRuntimeMutationBlocked else { return }
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            guard let configuredWorkspace = self.configuredWorkspace(matching: path) else {
                self.composerError = IntatisLocalization.string(
                    "This workspace could not be matched safely to session settings.")
                return
            }
            guard !configuredWorkspace.isPrimary else {
                self.composerError = IntatisLocalization.string(
                    "The primary workspace cannot be removed.")
                return
            }
            let remainingAgents = await self.orchestrator?.agentList() ?? []
            var settings = self.projectSettings
            settings.removeWorkspace(path: configuredWorkspace.path)
            guard let removablePath = self.removableWorkspaceAccessPath(
                candidate: configuredWorkspace.path,
                settings: settings,
                remainingAgents: remainingAgents) else {
                self.composerError = IntatisLocalization.string(
                    "This workspace is still referenced by session settings or an attached agent.")
                return
            }
            guard await self.updateProjectSettings(settings) else { return }
            do {
                try WorkspaceAccess.forget(path: removablePath, in: self.sessionID)
                self.releaseWorkspaceAccess(forPath: removablePath)
            } catch {
                self.composerError = IntatisLocalization.format(
                    "The workspace metadata was removed, but its capability was retained because cleanup failed: %@",
                    error.localizedDescription)
                return
            }
        }
        activeOperations[operationID] = operation
    }

    func addProjectWorkspace(_ authorization: WorkspaceAccessLease) {
        guard acceptsNewOperations else {
            authorization.release()
            return
        }
        let path = authorization.canonicalPath
        let hadRememberedAccess: Bool
        do {
            hadRememberedAccess = try WorkspaceAccess.hasRememberedAccess(
                forPath: path,
                in: sessionID)
            try WorkspaceAccess.remember(authorization.scopedURL, for: sessionID)
        } catch {
            composerError = IntatisLocalization.format(
                "Workspace access could not be saved: %@",
                error.localizedDescription)
            authorization.release()
            return
        }
        var settings = projectSettings
        settings.upsertWorkspace(
            path: path,
            agentName: nil,
            isPrimary: false)
        let owningSessionID = sessionID
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else {
                if !hadRememberedAccess {
                    try? WorkspaceAccess.forget(path: path, in: owningSessionID)
                }
                authorization.release()
                return
            }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            guard await self.updateProjectSettings(settings) else {
                if !hadRememberedAccess {
                    try? WorkspaceAccess.forget(path: path, in: self.sessionID)
                }
                authorization.release()
                return
            }
            _ = self.adoptWorkspaceAccess(authorization)
        }
        activeOperations[operationID] = operation
    }

    func addAgent(name rawName: String, workspace authorization: WorkspaceAccessLease) {
        guard acceptsNewOperations, !isRuntimeMutationBlocked else {
            addAgentStatus = .failed(
                IntatisLocalization.string("Cowork session is not ready."))
            authorization.release()
            return
        }
        let normalizedName: String
        switch validateNewAgentName(rawName) {
        case .success(let name):
            normalizedName = name
        case .failure(let message):
            addAgentStatus = .failed(message)
            authorization.release()
            return
        }
        guard let binding = projectSettings.defaultInferenceProfileBinding else {
            addAgentStatus = .failed(IntatisLocalization.string(
                "Choose a default inference profile for new agents."))
            authorization.release()
            return
        }
        let workspacePath = authorization.canonicalPath
        let hadRememberedAccess: Bool
        do {
            hadRememberedAccess = try WorkspaceAccess.hasRememberedAccess(
                forPath: workspacePath,
                in: sessionID)
            try WorkspaceAccess.remember(authorization.scopedURL, for: sessionID)
        } catch {
            addAgentStatus = .failed(IntatisLocalization.format(
                "Workspace access could not be saved: %@",
                error.localizedDescription))
            authorization.release()
            return
        }
        addAgentStatus = .attaching(normalizedName)
        let owningSessionID = sessionID
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else {
                if !hadRememberedAccess {
                    try? WorkspaceAccess.forget(path: workspacePath, in: owningSessionID)
                }
                authorization.release()
                return
            }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            var settings = self.projectSettings
            settings.upsertWorkspace(
                path: workspacePath,
                agentName: normalizedName,
                isPrimary: false)
            settings.upsertCodexAgentProfile(
                CoworkCodexAgentProfile(
                    roleName: normalizedName,
                    description:
                        "Use for Cowork work assigned to the \(normalizedName) role in its user-approved workspace.",
                    workspacePath: workspacePath,
                    inferenceBinding: binding,
                    permissionProfile:
                        self.projectSettings.defaultPermissionProfile))
            guard await self.persistProjectSettings(settings) else {
                if !hadRememberedAccess {
                    try? WorkspaceAccess.forget(
                        path: workspacePath,
                        in: self.sessionID)
                }
                authorization.release()
                self.addAgentStatus = .failed(
                    self.composerError
                        ?? IntatisLocalization.string(
                            "The Codex custom-agent profile could not be saved."))
                return
            }
            _ = self.adoptWorkspaceAccess(authorization)
            await self.resetCodexRuntime()
            do {
                try await self.startCodexRuntimeForCurrentMain()
                self.addAgentStatus = .attached(normalizedName)
            } catch {
                self.addAgentStatus = .failed(
                    error.localizedDescription)
            }
        }
        activeOperations[operationID] = operation
    }

    func importDraftAttachments(_ urls: [URL]) {
        guard acceptsNewOperations, !urls.isEmpty else { return }
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            for url in urls {
                do {
                    let file = try IntatisComposerAttachmentFileReader.read(url)
                    let attachment = try await self.composerAttachmentStore
                        .preserve(file)
                    self.draftAttachments.append(attachment)
                } catch {
                    self.composerError = IntatisLocalization.format(
                        "Attachment %@ could not be preserved: %@",
                        url.lastPathComponent,
                        error.localizedDescription)
                }
            }
        }
        activeOperations[operationID] = operation
    }

    func removeDraftAttachment(_ id: ArtifactID) {
        guard acceptsNewOperations else { return }
        draftAttachments.removeAll { $0.id == id }
    }

    /// Records one confirmed server-prompt selection and stages its typed
    /// untrusted content for the next submission to that exact Agent.
    func acceptMCPPromptInsertion(
        _ insertion: MCPPromptInsertion
    ) async throws {
        guard acceptsNewOperations else {
            throw IntatisError.config(
                "The Cowork session is stopping.")
        }
        let selectedAgentID =
            insertion.event.selectedByAgentID
        if let existing =
                pendingMCPExternalContextAgentID,
           let selectedAgentID,
           existing != selectedAgentID {
            throw IntatisError.permissionDenied(
                "External MCP context for different agents cannot be combined in one submission.")
        }
        let candidate =
            pendingMCPExternalContexts
                + insertion.externalContexts.map {
                    $0.providerNeutralContext()
                }
        try Self.validateMCPExternalContexts(candidate)
        try await log.append(
            .mcpPromptInserted(insertion.event))
        pendingMCPExternalContexts = candidate
        pendingMCPExternalContextAgentID =
            pendingMCPExternalContextAgentID
                ?? selectedAgentID
        pendingMCPExternalContextCount = candidate.count
    }

    /// Stages another explicit MCP selection (for example server
    /// instructions) through the same one-shot user-context boundary.
    func stageMCPExternalContexts(
        _ contexts: [MCPUntrustedExternalContext],
        selectedByAgentID: AgentID? = nil
    ) throws {
        if let existing =
                pendingMCPExternalContextAgentID,
           let selectedByAgentID,
           existing != selectedByAgentID {
            throw IntatisError.permissionDenied(
                "External MCP context for different agents cannot be combined in one submission.")
        }
        let candidate =
            pendingMCPExternalContexts
                + contexts.map {
                    $0.providerNeutralContext()
                }
        try Self.validateMCPExternalContexts(candidate)
        pendingMCPExternalContexts = candidate
        pendingMCPExternalContextAgentID =
            pendingMCPExternalContextAgentID
                ?? selectedByAgentID
        pendingMCPExternalContextCount = candidate.count
    }

    func cancelPendingMCPExternalContexts() {
        pendingMCPExternalContexts.removeAll()
        pendingMCPExternalContextAgentID = nil
        pendingMCPExternalContextCount = 0
    }

    func reportAttachmentImportFailure(_ error: Error) {
        guard acceptsNewOperations else { return }
        composerError = IntatisLocalization.format(
            "Attachments could not be selected: %@",
            error.localizedDescription)
    }

    func send() {
        guard acceptsNewOperations,
              !isAcceptingSubmission else { return }
        #if canImport(AVFoundation)
        guard !voiceInput.isEngaged else { return }
        #endif
        guard pendingMCPExternalContexts.isEmpty else {
            composerError = IntatisLocalization.string(
                "Staged content from the retired \(IntatisHostApplication.identity.name) MCP client cannot be imported into a native Codex turn. Use an attached native MCP server directly, or cancel the staged context.")
            return
        }
        let originalInput = input
        let originalAttachments = draftAttachments
        let parsed: ParsedUserInput
        if originalInput.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty,
           !originalAttachments.isEmpty {
            parsed = ParsedUserInput(text: "")
        } else {
            switch GoalInputParser.parse(originalInput) {
            case .success(let value):
                parsed = value
            case .failure(.empty):
                return
            case .failure(let error):
                composerError = Self.presentationMessage(for: error)
                return
            }
        }
        let routeInput = parsed.isGoal ? parsed.text : originalInput
        let route = routeInput.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty
            ? CoworkMentionRoute(
                originalInput: routeInput,
                outcome: .send(
                    text: "",
                    target: AgentID(
                        rawValue: projectSettings.mainAgentName)))
            : routeProjectInput(routeInput)
        let text: String
        let target: AgentID
        let targetThreadID: String?
        switch route.outcome {
        case .blocked(let error):
            composerError = Self.presentationMessage(for: error)
            return
        case .send(let routedText, let requestedTarget):
            do {
                let resolved = try resolveCodexUserTarget(
                    requestedTarget)
                text = routedText
                target = resolved.agentID
                targetThreadID = resolved.threadID
            } catch {
                composerError = error.localizedDescription
                return
            }
        }
        let main = AgentID(rawValue: projectSettings.mainAgentName)
        if target == main, isAgentWorkActive {
            return
        }
        let binding: AgentInferenceBinding?
        if target == main {
            guard let selected = nextMainInferenceBinding else {
                composerError = IntatisLocalization.string(
                    "Choose one resolvable Responses model before sending to Codex Runtime.")
                return
            }
            binding = selected
        } else {
            binding = nil
        }

        if targetThreadID != nil,
           codexRuntime == nil {
            composerError = IntatisLocalization.string(
                "The selected Codex subagent is not loaded in this Cowork session.")
            return
        }
        if targetThreadID != nil,
           parsed.goal != nil {
            composerError = IntatisLocalization.string(
                "A Codex Goal belongs to @main. Send ordinary text when addressing a subagent directly.")
            return
        }

        let submissionID = SubmissionID.new()
        var payload = UserMessagePayload(
            text: text,
            attachments: originalAttachments.isEmpty
                ? nil
                : originalAttachments.map(\.id),
            to: target,
            tags: parsed.tags.isEmpty ? nil : parsed.tags,
            goal: parsed.goal,
            submissionID: submissionID,
            mainAgentInferenceBinding: binding,
            turnID: TurnID.new())
        // Intatis external contexts are rejected above; keep the durable
        // payload explicit rather than silently dropping staged data.
        payload.untrustedExternalContexts = nil
        beginCodexSubmission(
            payload: payload,
            text: text,
            target: target,
            targetThreadID: targetThreadID,
            binding: binding,
            goal: parsed.goal,
            attachments: originalAttachments,
            clearsDraftInput: originalInput,
            clearsDraftAttachments: originalAttachments)
    }

    private func beginCodexSubmission(
        payload: UserMessagePayload,
        text: String,
        target: AgentID,
        targetThreadID: String?,
        binding: AgentInferenceBinding?,
        goal: String?,
        attachments: [CoworkDraftAttachment],
        clearsDraftInput: String?,
        clearsDraftAttachments: [CoworkDraftAttachment]
    ) {
        guard let submissionID = payload.submissionID else {
            composerError = IntatisLocalization.string(
                "The Codex submission is missing its durable identity.")
            return
        }
        let main = AgentID(rawValue: projectSettings.mainAgentName)
        isAcceptingSubmission = true
        isWorking = true
        composerError = nil
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isAcceptingSubmission = false
                self.isWorking = false
                self.activeOperations.removeValue(forKey: operationID)
            }
            var didPersistSubmission = false
            var didPersistRootSubmission = false
            var didStartChildDelivery = false
            do {
                let durableRoot = try await self
                    .loadCodexRootAuthority()
                let currentMain = durableRoot.agent
                let currentBinding = currentMain
                    .agentInferenceBinding
                if let binding,
                   currentBinding != binding {
                    try await self.log.append(.agentAttached(
                        AgentAttachedPayload(
                            agent: main,
                            path: currentMain.path,
                            model: binding.modelID,
                            profile: self.projectSettings
                                .defaultPermissionProfile,
                            agentInferenceBinding: binding,
                            previousAgentInferenceBinding: currentBinding,
                            inferenceBindingChangeReason:
                                "selected for next Codex Runtime turn",
                            metadata: currentMain.metadata)))
                }
                try await self.log.append([
                    .userMessage(payload),
                    .submissionStatusChanged(
                        SubmissionStatusChangedPayload(
                            submissionID: submissionID,
                            status: .queued,
                            attempt: 1)),
                ])
                didPersistSubmission = true
                didPersistRootSubmission = targetThreadID == nil
                if didPersistRootSubmission {
                    self.submittedPayloads[submissionID] = payload
                    self.submissionAttempts[submissionID] = 1
                }
                if let clearsDraftInput,
                   self.input == clearsDraftInput {
                    self.input = ""
                }
                if self.draftAttachments.map(\.id)
                    == clearsDraftAttachments.map(\.id),
                   !clearsDraftAttachments.isEmpty {
                    self.draftAttachments = []
                }
                if target == main {
                    self.nextMainInferenceOption = nil
                }
                let runtime: CodexAppServerSession
                if let binding {
                    runtime = try await self.codexSession(
                        for: binding)
                } else if let active = self.codexRuntime {
                    runtime = active
                } else {
                    throw CodexRuntimeError.notStarted
                }
                let imageURLs = try await self.codexImageURLs(
                    for: attachments)
                let childHistoryBaseline: Set<String>?
                if let targetThreadID {
                    guard imageURLs.isEmpty else {
                        throw CodexRuntimeError.malformedProtocol(
                            "native Codex subagent messages do not accept image attachments")
                    }
                    try self.validateVerifiedCodexDescendant(
                        threadID: targetThreadID)
                    childHistoryBaseline = try? await runtime
                        .threadHistory(threadID: targetThreadID)
                        .userMessageIDs
                } else {
                    childHistoryBaseline = nil
                }
                self.codexAllowsThreadCreation = false
                try await self.log.append(.submissionStatusChanged(
                    SubmissionStatusChangedPayload(
                        submissionID: submissionID,
                        status: .running,
                        attempt: 1)))
                if let goal {
                    try await runtime.setGoal(
                        objective: goal,
                        tokenBudget: self.projectSettings.tokenBudget)
                } else if let targetThreadID {
                    didStartChildDelivery = true
                    try await self
                        .deliverMessageToVerifiedCodexDescendant(
                        runtime: runtime,
                        threadID: targetThreadID,
                        text: text,
                        submissionID: submissionID,
                        baselineUserMessageIDs: childHistoryBaseline)
                } else {
                    _ = try await runtime.runTurn(
                        text: text,
                        localImageURLs: imageURLs)
                }
                if didPersistRootSubmission {
                    do {
                        try await self.log.append(.submissionStatusChanged(
                            SubmissionStatusChangedPayload(
                                submissionID: submissionID,
                                status: .completed,
                                attempt: 1)))
                    } catch {
                        self.composerError = IntatisLocalization.format(
                            "The Codex turn finished, but completion could not be persisted: %@",
                            error.localizedDescription)
                        return
                    }
                }
                self.composerError = nil
            } catch {
                let cancelled = Task.isCancelled
                let message = RuntimeErrorPresentation.message(for: error)
                self.composerError = cancelled ? nil : message
                if didPersistSubmission,
                   didPersistRootSubmission || !didStartChildDelivery {
                    do {
                        if cancelled {
                            try await self.log.append(.submissionStatusChanged(
                                SubmissionStatusChangedPayload(
                                    submissionID: submissionID,
                                    status: .cancelled,
                                    attempt: 1)))
                        } else {
                            let retryable = RuntimeErrorPresentation
                                .recoveryAdvice(
                                    code: "codex_runtime",
                                    message: message)?.retryable ?? false
                            try await self.log.append(.submissionStatusChanged(
                                SubmissionStatusChangedPayload(
                                    submissionID: submissionID,
                                    status: .failed,
                                    attempt: 1,
                                    failure: SubmissionFailure(
                                        code: "codex_turn_failed",
                                        message: message,
                                        retryable: retryable))))
                        }
                    } catch {
                        self.composerError = IntatisLocalization.format(
                            "The Codex turn ended, but its retry state could not be persisted: %@",
                            error.localizedDescription)
                    }
                }
                if !cancelled, targetThreadID == nil {
                    _ = try? await self.log.append(.error(
                        RuntimeErrorPresentation.payload(
                            for: error,
                            fallbackCode: "codex_runtime")))
                }
            }
        }
        activeOperations[operationID] = operation
    }

    /// The only product-layer path for explicitly addressing a native Codex
    /// child. App Server routes it through native AgentControl/mailbox state;
    /// there is deliberately no root-model, Orchestrator, or MessageBus hop.
    private func validateVerifiedCodexDescendant(
        threadID: String
    ) throws {
        guard let descriptor = codexChildThreadsByID[threadID],
              codexChildThreadIDByAgentID[descriptor.agentID] == threadID,
              !descriptor.isArchived,
              descriptor.status != "shutdown" else {
            throw CodexRuntimeError.malformedProtocol(
                "subagent messaging requires a verified live Codex descendant")
        }
    }

    private func deliverMessageToVerifiedCodexDescendant(
        runtime: CodexAppServerSession,
        threadID: String,
        text: String,
        submissionID: SubmissionID,
        baselineUserMessageIDs: Set<String>?
    ) async throws {
        try validateVerifiedCodexDescendant(threadID: threadID)
        do {
            _ = try await runtime.sendMessage(
                toDescendantThreadID: threadID,
                text: text,
                triggerTurn: true)
        } catch {
            if Self.isUncertainCodexChildDelivery(error),
               let baselineUserMessageIDs,
               let readback = try? await runtime.threadHistory(
                    threadID: threadID),
               readback.containsNewUserMessage(
                    text,
                    excluding: baselineUserMessageIDs) {
                try await log.append(.submissionStatusChanged(
                    SubmissionStatusChangedPayload(
                        submissionID: submissionID,
                        status: .completed,
                        attempt: 1)))
                return
            }
            let failure: SubmissionFailure
            if Self.isUncertainCodexChildDelivery(error) {
                failure = SubmissionFailure(
                    code: "child_message_delivery_unknown",
                    message: "Delivery could not be confirmed. Read this subagent's Codex history before retrying the message.",
                    retryable: false)
            } else {
                failure = SubmissionFailure(
                    code: "child_message_rejected",
                    message: "Codex rejected this subagent message before delivery. Review the reason and explicitly send a new message: \(RuntimeErrorPresentation.message(for: error))",
                    retryable: false)
            }
            try await log.append(.submissionStatusChanged(
                SubmissionStatusChangedPayload(
                    submissionID: submissionID,
                    status: .failed,
                    attempt: 1,
                    failure: failure)))
            if failure.code == "child_message_delivery_unknown" {
                throw IntatisError.io(failure.message)
            }
            throw error
        }
        // Persistence is outside the delivery-error classifier. Once App
        // Server returned a submission ID, a local EventLog failure must never
        // be rewritten as a remote rejection.
        try await log.append(.submissionStatusChanged(
            SubmissionStatusChangedPayload(
                submissionID: submissionID,
                status: .completed,
                attempt: 1)))
    }

    private static func isUncertainCodexChildDelivery(
        _ error: Error
    ) -> Bool {
        if IntatisCancellation.isCancellationSignal(error) { return true }
        guard let error = error as? CodexRuntimeError else { return false }
        switch error {
        case .requestTimedOut, .processTerminated:
            return true
        case .malformedProtocol(let message):
            return message.contains("returned no submission id")
        default:
            return false
        }
    }

    /// Retained temporarily only for source-level/manual rollback. It has no
    /// callable production path after the Codex Runtime migration.
    @available(*, unavailable, message: "Cowork uses Codex App Server")
    private func retainedLegacySubmittedIntentSend() {
        guard acceptsNewOperations, !isAcceptingSubmission else { return }
        #if canImport(AVFoundation)
        guard !voiceInput.isEngaged else { return }
        #endif
        let originalInput = input
        let originalAttachments = draftAttachments
        let frozenExternalContexts =
            pendingMCPExternalContexts
        let frozenExternalContextAgentID =
            pendingMCPExternalContextAgentID
        let initialParsed: ParsedUserInput
        if originalInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !originalAttachments.isEmpty
                || !frozenExternalContexts.isEmpty {
            initialParsed = ParsedUserInput(text: "")
        } else {
            switch GoalInputParser.parse(originalInput) {
            case .success(let value):
                initialParsed = value
            case .failure(.empty):
                composerError = Self.presentationMessage(
                    for: CoworkMentionRouteError.emptyMessage)
                return
            case .failure(let error):
                composerError = Self.presentationMessage(for: error)
                return
            }
        }
        let routeInput = initialParsed.isGoal ? initialParsed.text : originalInput
        let route = routeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? CoworkMentionRoute(
                originalInput: routeInput,
                outcome: .send(
                    text: "",
                    target: AgentID(rawValue: projectSettings.mainAgentName)))
            : routeProjectInput(routeInput)
        switch route.outcome {
        case .blocked(let error):
            composerError = Self.presentationMessage(for: error)
            return
        case .send(let text, let target):
            if let frozenExternalContextAgentID,
               frozenExternalContextAgentID != target {
                composerError = IntatisLocalization.format(
                    "The selected MCP context belongs to @%@, but this message targets @%@.",
                    frozenExternalContextAgentID.rawValue,
                    target.rawValue)
                return
            }
            let finalParsed: ParsedUserInput
            switch GoalInputParser.parse(text) {
            case .success(let parsed) where parsed.isGoal:
                finalParsed = parsed
            case .failure(.missingGoal):
                composerError = Self.presentationMessage(
                    for: GoalInputParseError.missingGoal)
                return
            default:
                finalParsed = initialParsed.isGoal
                    ? ParsedUserInput(text: text, goal: text, tags: [ParsedUserInput.goalTag])
                    : ParsedUserInput(text: text)
            }
            let mainAgentID = AgentID(rawValue: projectSettings.mainAgentName)
            let isMainHostedSubmission = target == mainAgentID || finalParsed.goal != nil
            let frozenMainInferenceBinding: AgentInferenceBinding?
            if isMainHostedSubmission {
                guard let exactBinding = nextMainInferenceBinding else {
                    composerError = IntatisLocalization.format(
                        "Choose a resolvable model for the next @%@ message before sending.",
                        mainAgentID.rawValue)
                    return
                }
                frozenMainInferenceBinding = exactBinding
            } else {
                frozenMainInferenceBinding = nil
            }
            let payload = UserMessagePayload(
                text: finalParsed.text,
                attachments: originalAttachments.map(\.id),
                to: target,
                tags: finalParsed.tags.isEmpty ? nil : finalParsed.tags,
                goal: finalParsed.goal,
                submissionID: SubmissionID.new(),
                mainAgentInferenceBinding: frozenMainInferenceBinding,
                turnID: TurnID.new(),
                untrustedExternalContexts:
                    frozenExternalContexts.isEmpty
                        ? nil
                        : frozenExternalContexts)
            isAcceptingSubmission = true
            let operationID = UUID()
            let operation = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.isAcceptingSubmission = false
                    self.activeOperations.removeValue(forKey: operationID)
                }
                do {
                    let acceptance = try await self.submittedIntentStore.accept(payload: payload)
                    self.consumeMCPExternalContexts(
                        frozenExternalContexts)
                    guard let submissionID = payload.submissionID else { return }
                    // Clear only the exact draft that was frozen. Any text the
                    // user typed while persistence ran belongs to the next
                    // draft and must remain untouched.
                    if self.input == originalInput {
                        self.input = ""
                    }
                    if self.draftAttachments.map(\.id) == originalAttachments.map(\.id) {
                        self.draftAttachments = []
                    }
                    self.submittedPayloads[submissionID] = payload
                    self.submissionAttempts[submissionID] = 1
                    switch acceptance {
                    case .canonical(_, let cleanupWarning):
                        self.canonicalSubmissionIDs.insert(submissionID)
                        self.outboxEntries.removeValue(forKey: submissionID)
                        if !self.submissionQueue.contains(submissionID) {
                            self.submissionQueue.append(submissionID)
                        }
                        self.composerError = nil
                        if let cleanupWarning {
                            self.sessionStorageWarning = cleanupWarning
                        }
                        self.scheduleSubmissionDrain()
                    case .outbox(let entry, let canonicalError):
                        self.outboxEntries[submissionID] = entry
                        self.composerError = IntatisLocalization.format(
                            "Submission saved in the local outbox. Retry when the session EventLog is writable: %@",
                            canonicalError)
                        self.rebuildOutboxThreadItems(
                            publishesChanges: true)
                    }
                } catch {
                    // Neither canonical EventLog nor the owner-only outbox
                    // accepted the intent. Keep the original draft verbatim.
                    self.composerError = IntatisLocalization.format(
                        "The submission could not be preserved, so the draft was not cleared: %@",
                        error.localizedDescription)
                }
            }
            activeOperations[operationID] = operation
        }
    }

    #if canImport(AVFoundation)
    func toggleVoiceInput() {
        guard acceptsNewOperations else { return }
        if !voiceInput.isRecording {
            guard !isAcceptingSubmission else { return }
        }
        voiceInput.toggle { [weak self] transcript in
            guard let self else { return }
            self.input = ComposerVoiceDraft.appending(
                transcript: transcript,
                to: self.input)
        }
    }

    private func observeVoiceInput() {
        voiceInputObservation = voiceInput.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }
    #endif

    private func consumeMCPExternalContexts(
        _ frozen: [UntrustedExternalContext]
    ) {
        guard !frozen.isEmpty,
              pendingMCPExternalContexts
                .starts(with: frozen) else {
            return
        }
        pendingMCPExternalContexts.removeFirst(
            frozen.count)
        if pendingMCPExternalContexts.isEmpty {
            pendingMCPExternalContextAgentID = nil
        }
        pendingMCPExternalContextCount =
            pendingMCPExternalContexts.count
    }

    private static func containsAgentHistory(
        _ envelopes: [Envelope]
    ) -> Bool {
        envelopes.contains { envelope in
            switch envelope.event {
            case .userMessage, .messageDelta, .messageCompleted,
                 .toolCall, .toolResult, .patchProposed, .turnOutcome:
                return true
            default:
                return false
            }
        }
    }

    private static func validateMCPExternalContexts(
        _ contexts: [UntrustedExternalContext]
    ) throws {
        guard contexts.count <= 16 else {
            throw IntatisError.config(
                "A submission can include at most 16 external MCP context items.")
        }
        let encoded = try JSONEncoder().encode(contexts)
        guard encoded.count <= 512 * 1_024 else {
            throw IntatisError.config(
                "External MCP context exceeds the 512 KiB submission limit.")
        }
    }

    private func scheduleSubmissionDrain() {
        guard acceptsNewOperations,
              !submissionDrainRunning,
              !submissionQueue.isEmpty,
              orchestrator != nil,
              goalRuntime != nil else { return }
        submissionDrainRunning = true
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.submissionDrainRunning = false
                self.activeOperations.removeValue(forKey: operationID)
            }
            await self.drainSubmittedIntents()
        }
        activeOperations[operationID] = operation
    }

    private func drainSubmittedIntents() async {
        while !Task.isCancelled,
              !didStop,
              !submissionQueue.isEmpty {
            guard !isWorking,
                  !isGoalContinuing,
                  let orchestrator,
                  let goalRuntime else { return }
            let submissionID = submissionQueue[0]
            guard let payload = submittedPayloads[submissionID] else {
                submissionQueue.removeFirst()
                continue
            }
            let attempt = max(1, submissionAttempts[submissionID] ?? 1)
            let target = payload.to ?? AgentID(rawValue: projectSettings.mainAgentName)
            let mainAgentID = AgentID(rawValue: projectSettings.mainAgentName)
            let isMainHostedSubmission = target == mainAgentID || payload.goal != nil
            if payload.mainAgentInferenceBinding != nil, !isMainHostedSubmission {
                await settleSubmissionFailure(
                    submissionID: submissionID,
                    attempt: attempt,
                    code: "invalid_main_model_target",
                    message: "The composer model selection can only be applied to @\(mainAgentID.rawValue). Direct agent messages keep their own configured model.",
                    retryable: false)
                submissionQueue.removeFirst()
                continue
            }
            let frozenBindingCanRepairMain = target == mainAgentID
                && payload.mainAgentInferenceBinding != nil
            guard let targetAgent = liveAgentInfo(named: target.rawValue),
                  targetAgent.inferenceResolution == .resolved
                    || frozenBindingCanRepairMain else {
                await settleSubmissionFailure(
                    submissionID: submissionID,
                    attempt: attempt,
                    code: "route_unavailable",
                    message: "@\(target.rawValue) is not registered with a resolvable inference profile. Rebind or register it, then retry.",
                    retryable: true)
                submissionQueue.removeFirst()
                continue
            }
            // Runtime reconstruction may still be in progress, but route
            // failures are already knowable locally and should become an
            // actionable submission state instead of an indefinite spinner.
            guard isGoalRuntimeReady else {
                return
            }

            do {
                try await submittedIntentStore.appendStatus(
                    SubmissionStatusChangedPayload(
                        submissionID: submissionID,
                        status: .running,
                        attempt: attempt))
            } catch {
                composerError = IntatisLocalization.format(
                    "Submission %@ remains queued because its running state could not be persisted: %@",
                    submissionID.rawValue,
                    error.localizedDescription)
                return
            }

            isWorking = true
            isAgentWorkActive = true
            var didStartGoalContinuation = false
            let executionFailure: SubmissionFailure?
            if payload.goal != nil {
                if payload.attachments?.isEmpty == false {
                    executionFailure = SubmissionFailure(
                        code: "goal_attachments_unsupported",
                        message: "Goal submissions do not yet pass attachments to the Goal runtime. The submitted attachments remain preserved locally.",
                        retryable: false)
                } else {
                    let baseObjective = payload.goal ?? payload.text
                    let mainID = AgentID(rawValue: projectSettings.mainAgentName)
                    let objective = target == mainID
                        ? baseObjective
                        : "@\(target.rawValue): \(baseObjective)"
                    do {
                        _ = try await goalRuntime.createGoal(
                            objective: objective,
                            userMessage: payload)
                        // `createGoal` launches its continuation asynchronously.
                        // Close the FIFO gate immediately instead of waiting for
                        // the streamed projection to report the active run.
                        isGoalContinuing = true
                        didStartGoalContinuation = true
                        executionFailure = nil
                    } catch {
                        executionFailure = SubmissionFailure(
                            code: "goal_create_failed",
                            message: error.localizedDescription,
                            retryable: true)
                    }
                }
            } else {
                let result: OrchestratorSendResult
                if let retryTask = submissionRetryTasks[submissionID] {
                    result = await orchestrator.retry(
                        retryTask,
                        userMessage: payload,
                        recordUserMessage: false)
                    submissionRetryTasks.removeValue(forKey: submissionID)
                } else {
                    result = await goalRuntime.sendUserTurn(
                        payload.text,
                        to: target,
                        userMessage: payload,
                        recordUserMessage: false)
                }
                if let message = result.errorMessage {
                    executionFailure = await submissionExecutionFailure(
                        submissionID: submissionID,
                        message: message)
                } else {
                    executionFailure = nil
                }
            }
            await synchronizePermissionReviewerHealth(using: orchestrator)

            if let executionFailure {
                await settleSubmissionFailure(
                    submissionID: submissionID,
                    attempt: attempt,
                    code: executionFailure.code,
                    message: executionFailure.message,
                    retryable: executionFailure.retryable)
            } else {
                do {
                    try await submittedIntentStore.appendStatus(
                        SubmissionStatusChangedPayload(
                            submissionID: submissionID,
                            status: .completed,
                            attempt: attempt))
                    composerError = nil
                } catch {
                    // Remote work may already have completed. Never retry it
                    // automatically when the terminal status could not be
                    // persisted; the restored UI will require an explicit
                    // reconciliation/retry decision.
                    composerError = IntatisLocalization.format(
                        "Submission %@ finished, but completion could not be persisted: %@",
                        submissionID.rawValue,
                        error.localizedDescription)
                }
            }
            isWorking = false
            isAgentWorkActive = false
            if submissionQueue.first == submissionID {
                submissionQueue.removeFirst()
            } else {
                submissionQueue.removeAll { $0 == submissionID }
            }
            if didStartGoalContinuation { return }
        }
    }

    private func settleSubmissionFailure(
        submissionID: SubmissionID,
        attempt: Int,
        code: String,
        message: String,
        retryable: Bool
    ) async {
        let safeMessage = String(message.prefix(1_200))
        do {
            try await submittedIntentStore.appendStatus(
                SubmissionStatusChangedPayload(
                    submissionID: submissionID,
                    status: .failed,
                    attempt: attempt,
                    failure: SubmissionFailure(
                        code: code,
                        message: safeMessage,
                        retryable: retryable)))
            composerError = safeMessage
        } catch {
            composerError = IntatisLocalization.format(
                "Submission failed, and its retry state could not be persisted: %@",
                error.localizedDescription)
        }
    }

    func retrySubmission(_ submissionID: SubmissionID) {
        guard acceptsNewOperations, !isAcceptingSubmission else { return }
        isAcceptingSubmission = true
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            var handedOffToCodexContinuation = false
            defer {
                if !handedOffToCodexContinuation {
                    self.isAcceptingSubmission = false
                }
                self.activeOperations.removeValue(forKey: operationID)
            }
            do {
                if self.outboxEntries[submissionID] != nil {
                    let acceptance = try await self.submittedIntentStore.retryOutbox(id: submissionID)
                    switch acceptance {
                    case .canonical(let entry, let cleanupWarning):
                        self.canonicalSubmissionIDs.insert(submissionID)
                        self.outboxEntries.removeValue(forKey: submissionID)
                        self.submittedPayloads[submissionID] = entry.payload
                        self.submissionAttempts[submissionID] = 1
                        if !self.submissionQueue.contains(submissionID) {
                            self.submissionQueue.append(submissionID)
                        }
                        self.composerError = nil
                        if let cleanupWarning {
                            self.sessionStorageWarning = cleanupWarning
                        }
                        self.rebuildOutboxThreadItems(
                            publishesChanges: true)
                        self.scheduleSubmissionDrain()
                    case .outbox(let entry, let canonicalError):
                        self.outboxEntries[submissionID] = entry
                        self.composerError = IntatisLocalization.format(
                            "The submission is still safe in the local outbox: %@",
                            canonicalError)
                        self.rebuildOutboxThreadItems(
                            publishesChanges: true)
                    }
                    return
                }

                guard let payload = self.submittedPayloads[submissionID] else {
                    self.composerError = IntatisLocalization.string(
                        "This submission payload is no longer available for retry.")
                    return
                }
                let currentAttempt = max(
                    1,
                    self.submissionAttempts[submissionID] ?? 1)
                let task = try await self.canonicalSubmissionTask(
                    for: submissionID)
                let main = AgentID(
                    rawValue: self.projectSettings.mainAgentName)
                if task == nil,
                   (payload.to ?? main) == main,
                   payload.goal == nil {
                    guard let binding = payload.mainAgentInferenceBinding else {
                        self.composerError = IntatisLocalization.string(
                            "The failed Codex submission has no exact model binding to continue.")
                        return
                    }
                    let continuationID = SubmissionID.new()
                    let continuation = UserMessagePayload(
                        text: Self.interruptedRunContinuationText,
                        to: main,
                        submissionID: continuationID,
                        mainAgentInferenceBinding: binding,
                        turnID: TurnID.new())
                    handedOffToCodexContinuation = true
                    self.restoredSubmissionIDs.remove(submissionID)
                    self.publishSubmissionThreadChange(submissionID)
                    self.beginCodexSubmission(
                        payload: continuation,
                        text: Self.interruptedRunContinuationText,
                        target: main,
                        targetThreadID: nil,
                        binding: binding,
                        goal: nil,
                        attachments: [],
                        clearsDraftInput: nil,
                        clearsDraftAttachments: [])
                    return
                }
                let retryPlan = SubmittedIntentRetryPlanner.plan(
                    currentAttempt: currentAttempt,
                    task: task,
                    isRestoredSubmission:
                        self.restoredSubmissionIDs.contains(submissionID))
                let retryAttempt: Int
                let appendsQueuedStatus: Bool
                switch retryPlan {
                case .completed(let attempt):
                    try await self.submittedIntentStore.appendStatus(
                        SubmissionStatusChangedPayload(
                            submissionID: submissionID,
                            status: .completed,
                            attempt: attempt))
                    self.restoredSubmissionIDs.remove(submissionID)
                    self.composerError = nil
                    self.publishSubmissionThreadChange(submissionID)
                    return
                case .resumeRestoredTask(
                    let attempt,
                    let shouldAppendQueuedStatus):
                    guard let task else { return }
                    self.submissionRetryTasks[submissionID] = task
                    retryAttempt = attempt
                    appendsQueuedStatus = shouldAppendQueuedStatus
                case .retryTerminalTask(let attempt):
                    guard let task else { return }
                    if try await self.requiresFreshRun(for: task) {
                        try await self.enqueueInterruptedRunContinuation(
                            from: payload)
                        self.restoredSubmissionIDs.remove(submissionID)
                        self.publishSubmissionThreadChange(submissionID)
                        return
                    }
                    self.submissionRetryTasks[submissionID] = task
                    retryAttempt = attempt
                    appendsQueuedStatus = true
                case .retrySubmissionWithoutTask(let attempt):
                    retryAttempt = attempt
                    appendsQueuedStatus = true
                case .reject:
                    self.composerError = IntatisLocalization.string(
                        "This submission already has active or inconsistent task state and cannot be retried.")
                    return
                }
                if appendsQueuedStatus {
                    try await self.submittedIntentStore.appendStatus(
                        SubmissionStatusChangedPayload(
                            submissionID: submissionID,
                            status: .queued,
                            attempt: retryAttempt))
                }
                self.submissionAttempts[submissionID] = retryAttempt
                self.restoredSubmissionIDs.remove(submissionID)
                self.submittedPayloads[submissionID] = payload
                if !self.submissionQueue.contains(submissionID) {
                    self.submissionQueue.append(submissionID)
                }
                self.composerError = nil
                self.publishSubmissionThreadChange(submissionID)
                self.scheduleSubmissionDrain()
            } catch {
                self.composerError = IntatisLocalization.format(
                    "The submission could not be queued for retry: %@",
                    error.localizedDescription)
            }
        }
        activeOperations[operationID] = operation
    }

    private func canonicalSubmissionTask(
        for submissionID: SubmissionID
    ) async throws -> CoworkTaskView? {
        let projection = CoworkProjection.build(from: try await log.replayChecked())
        let matches = projection.tasks.values
            .filter {
                $0.contract?.kind == .root
                    && $0.contract?.submissionID == submissionID
            }
        guard matches.count <= 1 else {
            throw IntatisError.decoding(
                "submission \(submissionID.rawValue) is correlated with multiple root tasks")
        }
        return matches.first
    }

    private func requiresFreshRun(
        for task: CoworkTaskView
    ) async throws -> Bool {
        guard let runID = task.contract?.continuationRunID else {
            return false
        }
        let projection = CoworkProjection.build(
            from: try await log.replayChecked())
        guard !projection.ambiguousContinuationRunCloseClaimIDs
            .contains(runID) else {
            throw IntatisError.decoding(
                "continuation run \(runID.rawValue) has conflicting close claims")
        }
        guard let run = projection.continuationRuns[runID] else {
            throw IntatisError.decoding(
                "continuation run \(runID.rawValue) is missing from durable history")
        }
        guard run.status.isTerminal else {
            throw IntatisError.decoding(
                "continuation run \(runID.rawValue) is still \(run.status.rawValue)")
        }
        return true
    }

    private func enqueueInterruptedRunContinuation(
        from original: UserMessagePayload
    ) async throws {
        let mainAgentID = AgentID(
            rawValue: projectSettings.mainAgentName)
        let target = original.to ?? mainAgentID
        if target == mainAgentID,
           original.mainAgentInferenceBinding == nil {
            throw IntatisError.config(
                "The interrupted @\(mainAgentID.rawValue) submission has no exact model binding to carry into a fresh run.")
        }
        let submissionID = SubmissionID.new()
        let payload = UserMessagePayload(
            text: Self.interruptedRunContinuationText,
            to: target,
            submissionID: submissionID,
            mainAgentInferenceBinding:
                original.mainAgentInferenceBinding,
            turnID: TurnID.new())
        let acceptance = try await submittedIntentStore.accept(
            payload: payload)
        submittedPayloads[submissionID] = payload
        submissionAttempts[submissionID] = 1
        switch acceptance {
        case .canonical(_, let cleanupWarning):
            canonicalSubmissionIDs.insert(submissionID)
            outboxEntries.removeValue(forKey: submissionID)
            if !submissionQueue.contains(submissionID) {
                submissionQueue.append(submissionID)
            }
            composerError = nil
            if let cleanupWarning {
                sessionStorageWarning = cleanupWarning
            }
            scheduleSubmissionDrain()
        case .outbox(let entry, let canonicalError):
            outboxEntries[submissionID] = entry
            composerError = IntatisLocalization.format(
                "The continuation is safe in the local outbox: %@",
                canonicalError)
            rebuildOutboxThreadItems(publishesChanges: true)
        }
    }

    private func submissionExecutionFailure(
        submissionID: SubmissionID,
        message: String
    ) async -> SubmissionFailure {
        do {
            if let task = try await canonicalSubmissionTask(for: submissionID),
               let maxAttempts = task.contract?.maxAttempts,
               task.attempt >= maxAttempts {
                return SubmissionFailure(
                    code: "execution_attempts_exhausted",
                    message: message,
                    retryable: false)
            }
            return SubmissionFailure(
                code: "execution_failed",
                message: message,
                retryable: true)
        } catch {
            return SubmissionFailure(
                code: "submission_task_correlation_invalid",
                message: "\(message) Retry is disabled because the durable task correlation is ambiguous: \(error.localizedDescription)",
                retryable: false)
        }
    }

    func cancelCurrentActivity() {
        guard acceptsNewOperations,
              !isCancellingCurrentActivity,
              isAgentWorkActive || isGoalContinuing else {
            return
        }
        if let codexRuntime {
            isCancellingCurrentActivity = true
            composerError = IntatisLocalization.string(
                "Cancelling the current Codex Runtime turn…")
            let operationID = UUID()
            let operation = Task { @MainActor [weak self] in
                defer {
                    self?.isCancellingCurrentActivity = false
                    self?.activeOperations.removeValue(
                        forKey: operationID)
                }
                do {
                    try await codexRuntime.interruptCurrentTurn()
                    self?.composerError = nil
                } catch {
                    self?.composerError = error.localizedDescription
                }
            }
            activeOperations[operationID] = operation
            return
        }
        isCancellingCurrentActivity = true
        composerError = IntatisLocalization.string(
            "Cancelling the current Cowork task…")
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isCancellingCurrentActivity = false
                self.activeOperations.removeValue(forKey: operationID)
            }

            let hasActiveGoal = self.isGoalContinuing
                || self.goal?.normalizedStatus == "active"
            if hasActiveGoal {
                guard let goalRuntime = self.goalRuntime else {
                    self.composerError = IntatisLocalization.string(
                        "Cowork session is not ready.")
                    return
                }
                do {
                    _ = try await goalRuntime.pauseCurrentGoal()
                    self.composerError = nil
                } catch {
                    self.composerError = error.localizedDescription
                }
                return
            }

            guard let orchestrator = self.orchestrator else {
                self.composerError = IntatisLocalization.string(
                    "Cowork session is not ready.")
                return
            }
            await orchestrator.cancelActiveTasks(reason: "cancelled by user")
            await self.synchronizePermissionReviewerHealth(using: orchestrator)
            self.composerError = nil
        }
        activeOperations[operationID] = operation
    }

    func pauseGoal() {
        guard acceptsNewOperations, codexGoalSnapshot != nil else { return }
        performGoalAction { [weak self] in
            guard let self else { return }
            let runtime = try await self.codexRuntimeForGoalAction()
            try await runtime.setGoalStatus("paused")
        }
    }

    func resumeGoal() {
        guard acceptsNewOperations, codexGoalSnapshot != nil else { return }
        performGoalAction { [weak self] in
            guard let self else { return }
            let runtime = try await self.codexRuntimeForGoalAction()
            try await runtime.setGoalStatus("active")
        }
    }

    func currentGoalEditDraft() -> CoworkGoalEditDraft? {
        guard let codexGoalSnapshot else { return nil }
        return CoworkGoalEditDraft(
            objective: codexGoalSnapshot.objective,
            successCriteria: "",
            constraints: "",
            tokenBudget: codexGoalSnapshot.tokenBudget
                .map(String.init) ?? "")
    }

    @discardableResult
    func editGoal(objective: String,
                  successCriteria: String,
                  constraints: String,
                  tokenBudget: String) -> String? {
        let objective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else {
            return IntatisLocalization.string("A Goal objective is required.")
        }

        let budgetText = tokenBudget.trimmingCharacters(in: .whitespacesAndNewlines)
        let budgetUpdate: CodexRuntimeGoalBudgetUpdate
        if budgetText.isEmpty {
            budgetUpdate = .clear
        } else if let value = Int(budgetText), value > 0 {
            budgetUpdate = .set(value)
        } else {
            return IntatisLocalization.string(
                "Token budget must be a positive whole number, or left empty for no budget.")
        }

        guard acceptsNewOperations,
              codexGoalSnapshot != nil else {
            return IntatisLocalization.string(
                "The Codex thread Goal must be loaded before it can be edited.")
        }
        let parsedCriteria = Self.goalEditLines(successCriteria)
        let parsedConstraints = Self.goalEditLines(constraints)
        guard parsedCriteria.isEmpty,
              parsedConstraints.isEmpty else {
            return IntatisLocalization.string(
                "The Codex thread Goal supports an objective and token budget; success criteria and constraints are not official Codex Goal fields.")
        }
        performGoalAction { [weak self] in
            guard let self else { return }
            let runtime = try await self.codexRuntimeForGoalAction()
            try await runtime.updateGoal(
                objective: objective,
                tokenBudget: budgetUpdate)
        }
        return nil
    }

    func clearGoal() {
        guard acceptsNewOperations, codexGoalSnapshot != nil else { return }
        performGoalAction { [weak self] in
            guard let self else { return }
            let runtime = try await self.codexRuntimeForGoalAction()
            try await runtime.clearGoal()
        }
    }

    private func codexRuntimeForGoalAction() async throws
        -> CodexAppServerSession
    {
        if let codexRuntime { return codexRuntime }
        try await startCodexRuntimeForCurrentMain()
        guard let codexRuntime else {
            throw CodexRuntimeError.notStarted
        }
        return codexRuntime
    }

    private func performGoalAction(
        _ action: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        guard acceptsNewOperations else { return }
        composerError = nil
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            do {
                try await action()
            } catch {
                self.composerError = error.localizedDescription
            }
        }
        activeOperations[operationID] = operation
    }

    private static func goalEditLines(_ value: String) -> [String] {
        value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func routeProjectInput(_ input: String) -> CoworkMentionRoute {
        CoworkMentionRouter.routeSubmittedIntent(
            input: input,
            defaultTarget: AgentID(rawValue: projectSettings.mainAgentName))
    }

    private func resolveCodexUserTarget(
        _ requested: AgentID
    ) throws -> (agentID: AgentID, threadID: String?) {
        let main = AgentID(rawValue: projectSettings.mainAgentName)
        if requested == main
            || requested.rawValue.lowercased()
                == main.rawValue.lowercased() {
            return (main, nil)
        }

        let exact = codexChildThreadsByID.values.filter {
            $0.agentID == requested
                || $0.displayName == requested.rawValue
        }
        let candidates: [CodexRuntimeThreadDescriptor]
        if exact.isEmpty {
            let folded = requested.rawValue.lowercased()
            candidates = codexChildThreadsByID.values.filter {
                $0.agentID.rawValue.lowercased() == folded
                    || $0.displayName.lowercased() == folded
            }
        } else {
            candidates = exact
        }
        guard candidates.count == 1,
              let thread = candidates.first else {
            if candidates.count > 1 {
                throw IntatisError.config(
                    IntatisLocalization.format(
                        "More than one Codex subagent matches @%@; use the unique agent nickname shown by Codex.",
                        requested.rawValue))
            }
            throw IntatisError.config(
                IntatisLocalization.format(
                    "No active Codex subagent matches @%@.",
                    requested.rawValue))
        }
        guard !thread.isArchived,
              thread.status != "shutdown" else {
            throw IntatisError.config(
                IntatisLocalization.format(
                    "@%@ has ended and its conversation is read-only.",
                    thread.displayName))
        }
        return (thread.agentID, thread.threadID)
    }

    private static func presentationMessage(
        for error: GoalInputParseError
    ) -> String {
        switch error {
        case .empty:
            return IntatisLocalization.string("Enter a message.")
        case .missingGoal:
            return IntatisLocalization.string("Enter a goal after /goal.")
        }
    }

    private static func presentationMessage(
        for error: CoworkMentionRouteError
    ) -> String {
        switch error {
        case .noAgents:
            return IntatisLocalization.string(
                "Add an agent before sending a Cowork message.")
        case .emptyMessage:
            return IntatisLocalization.string("Enter a message before sending.")
        case .emptyMention:
            return IntatisLocalization.string("Type an agent name after @.")
        case .unknownMention(let name):
            return IntatisLocalization.format(
                "No attached agent matches @%@.",
                name)
        case .invalidMention(let name):
            return IntatisLocalization.format(
                "@%@ is not a valid agent name. Use ASCII letters, digits, '-' or '_'.",
                name)
        case .ambiguousMention(let name, let agents):
            return IntatisLocalization.format(
                "Ambiguous @%@: %@",
                name,
                agents.map { "@\($0.rawValue)" }.joined(separator: ", "))
        case .ambiguousDefault(let agents):
            return IntatisLocalization.format(
                "Use @Name to choose an agent: %@",
                agents.map { "@\($0.rawValue)" }.joined(separator: ", "))
        }
    }

    func retryFailedTask(id: String) {
        guard acceptsNewOperations, !isRuntimeMutationBlocked, let orchestrator else { return }
        guard let task = retryableTasks[id] else {
            composerError = IntatisLocalization.string(
                "This failed task is no longer retryable.")
            return
        }
        if let submissionID = task.contract?.submissionID {
            retrySubmission(submissionID)
            return
        }
        composerError = nil
        isWorking = true
        isAgentWorkActive = true
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeOperations.removeValue(forKey: operationID) }
            let result = await orchestrator.retry(task)
            await self.synchronizePermissionReviewerHealth(using: orchestrator)
            if let message = result.errorMessage {
                self.composerError = message
            }
            self.isWorking = false
            self.isAgentWorkActive = false
        }
        activeOperations[operationID] = operation
    }

    // MARK: PermissionResponder

    nonisolated func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        await requestResolution(request).decision
    }

    nonisolated func requestResolution(
        _ request: PermissionRequestPayload
    ) async -> PermissionApprovalResolution {
        let waiter = CoworkPermissionWaiter()
        return await withTaskCancellationHandler(operation: {
            if Task.isCancelled {
                waiter.resolve(Self.cancelledPermissionResolution(
                    reason: "Cowork turn cancelled before permission presentation"))
            }
            return await withCheckedContinuation { continuation in
                waiter.install(continuation)
                Task { @MainActor [weak self] in
                    guard let self else {
                        waiter.resolve(Self.cancelledPermissionResolution(
                            reason: "Cowork permission presenter is unavailable"))
                        return
                    }
                    self.registerPermission(request, waiter: waiter)
                }
            }
        }, onCancel: {
            waiter.resolve(Self.cancelledPermissionResolution(
                reason: "Cowork turn cancelled while awaiting permission"))
            Task { @MainActor [weak self] in
                self?.cancelPermission(request.requestId, waiter: waiter)
            }
        })
    }

    func resolvePermission(_ action: PermissionResponseAction) {
        guard acceptsNewOperations,
              let presented = pendingPermission,
              presented.state.isActionable else { return }
        let request = presented.request
        let requestID = request.requestId
        if let runtimeRequestID = codexApprovalIDs[requestID],
           let codexRuntime {
            if var pending = pendingPermission {
                pending.state = .resolving
                pendingPermission = pending
            }
            codexApprovalActions[requestID] = action
            let decision: CodexRuntimeApprovalDecision
            switch action {
            case .approve:
                decision = .accept
            case .approveAndRemember:
                decision = .acceptForSession
            case .decline:
                decision = .decline
            case .cancelTurn:
                decision = .cancel
            }
            Task { @MainActor [weak self] in
                do {
                    try await codexRuntime.resolveApproval(
                        requestID: runtimeRequestID,
                        decision: decision)
                } catch {
                    guard let self else { return }
                    self.codexApprovalActions.removeValue(
                        forKey: requestID)
                    if var pending = self.pendingPermission,
                       pending.id == requestID {
                        pending.state = .livePending
                        self.pendingPermission = pending
                    }
                    self.composerError = error.localizedDescription
                }
            }
            return
        }
        guard
              let waiter = permissionWaiters.removeValue(forKey: requestID) else {
            if pendingPermission?.state == .needsRerun {
                return
            }
            if var pending = pendingPermission {
                pending.state = .expired
                pendingPermission = pending
            }
            return
        }
        if var pending = pendingPermission {
            pending.state = .resolving
            pendingPermission = pending
        }
        suppressedPermissionRequestIDs.insert(requestID)
        waiter.resolve(Self.userPermissionResolution(action, request: request))
        permissionQueue.removeAll { $0.request.requestId == requestID }
        pendingPermission = permissionQueue.first
        restoreSteadyPermissionReviewerStatusIfPossible()
    }

    private func registerPermission(_ request: PermissionRequestPayload,
                                    waiter: CoworkPermissionWaiter) {
        guard acceptsNewOperations else {
            waiter.resolve(Self.cancelledPermissionResolution(
                reason: "Cowork session is stopping"))
            return
        }
        guard waiter.isPending else { return }
        let requestID = request.requestId
        if let previous = permissionWaiters.removeValue(forKey: requestID), previous !== waiter {
            previous.resolve(Self.cancelledPermissionResolution(
                reason: "Permission request identity was replaced"))
        }
        permissionQueue.removeAll { $0.request.requestId == requestID }
        guard waiter.isPending else { return }

        suppressedPermissionRequestIDs.remove(requestID)
        permissionWaiters[requestID] = waiter
        permissionQueue.append(PendingPermission(
            request: request,
            state: request.effectiveApprovalMode == .automaticReviewer
                ? .resolving
                : .livePending,
            requestedSeq: -1))
        if request.effectiveApprovalMode == .automaticReviewer {
            permissionReviewerStatus = .fallback(permissionFallbackReason)
            schedulePermissionReviewerHealthRefresh()
        }

        // Cancellation can resolve the waiter from a non-MainActor thread
        // between the first guard and registration. Remove it immediately if so;
        // the scheduled cancellation cleanup remains an idempotent fallback.
        guard waiter.isPending else {
            cancelPermission(requestID, waiter: waiter)
            return
        }
        pendingPermission = permissionQueue.first
    }

    private func cancelPermission(_ requestID: RequestID,
                                  waiter: CoworkPermissionWaiter) {
        suppressedPermissionRequestIDs.insert(requestID)
        if permissionWaiters[requestID] === waiter {
            permissionWaiters.removeValue(forKey: requestID)
        }
        permissionQueue.removeAll { $0.request.requestId == requestID }
        pendingPermission = permissionQueue.first
        restoreSteadyPermissionReviewerStatusIfPossible()
    }

    private nonisolated static func userPermissionResolution(
        _ action: PermissionResponseAction,
        request: PermissionRequestPayload
    ) -> PermissionApprovalResolution {
        switch action {
        case .approve, .approveAndRemember:
            return PermissionApprovalResolution(
                decision: .allow,
                action: action,
                reason:
                    action == .approveAndRemember
                        ? "Permission approved and exact MCP tool approval remembered by user"
                        : "Permission approved by user",
                risk: request.risk,
                source: .user)
        case .decline:
            return PermissionApprovalResolution(
                decision: .deny,
                action: .decline,
                reason: "Permission declined by user",
                risk: request.risk,
                source: .user,
                failureSource: .userDenied)
        case .cancelTurn:
            return PermissionApprovalResolution(
                decision: .deny,
                action: .cancelTurn,
                reason: "Turn cancelled by user",
                risk: request.risk,
                source: .user,
                failureSource: .userCancelled)
        }
    }

    private nonisolated static func cancelledPermissionResolution(
        reason: String
    ) -> PermissionApprovalResolution {
        PermissionApprovalResolution(
            decision: .deny,
            reason: reason,
            source: .callerCancellation,
            reviewStatus: .cancelled,
            failureKind: .callerCancelled,
            failureSource: .turnCancelled)
    }

    private func presentedPermission(projected: PendingPermission?) -> PendingPermission? {
        if let queued = permissionQueue.first {
            return queued
        }
        guard let projected,
              !suppressedPermissionRequestIDs.contains(projected.request.requestId) else {
            return nil
        }
        return projected
    }

    private func setPermissionReviewerStatus(_ status: CoworkPermissionReviewerStatus) {
        steadyPermissionReviewerStatus = status
        if permissionQueue.isEmpty {
            permissionReviewerStatus = status
        }
    }

    private var permissionFallbackReason: String {
        switch steadyPermissionReviewerStatus {
        case .enabled:
            return IntatisLocalization.string(
                "Automatic review unexpectedly left the automatic path; ask-class tools fail closed until it recovers.")
        case .failed(let reason):
            return IntatisLocalization.format(
                "Automatic review is unavailable (%@); ordinary submissions remain available, but ask-class tools fail closed.",
                reason)
        case .disabled:
            return IntatisLocalization.string(
                "Automatic review is disabled; ordinary submissions remain available, but ask-class tools fail closed.")
        case .enabling:
            return IntatisLocalization.string(
                "Automatic review is still starting; ordinary submissions remain available.")
        case .degraded(let reason):
            return reason
        case .fallback(let reason):
            return reason
        }
    }

    private func restoreSteadyPermissionReviewerStatusIfPossible() {
        guard permissionQueue.isEmpty else { return }
        permissionReviewerStatus = steadyPermissionReviewerStatus
    }

    private func validateNewAgentName(_ rawName: String) -> AgentNameValidation {
        let name = Self.normalizedAgentName(rawName)
        guard !name.isEmpty else {
            return .failure(IntatisLocalization.string("Enter an agent name."))
        }
        guard name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return .failure(IntatisLocalization.string(
                "Agent names cannot contain spaces."))
        }
        guard name.unicodeScalars.allSatisfy({ scalar in
            switch scalar.value {
            case 45, 48...57, 65...90, 95, 97...122:
                return true
            default:
                return false
            }
        }) else {
            return .failure(IntatisLocalization.string(
                "Agent names use ASCII letters, digits, '-' or '_'."))
        }
        let reserved = [
            projectSettings.mainAgentName,
            Orchestrator.automaticPermissionReviewerID.rawValue,
            "default",
            "enabled",
            "max_concurrent_threads_per_session",
            "max_threads",
            "max_depth",
            "default_subagent_model",
            "default_subagent_reasoning_effort",
            "job_max_runtime_seconds",
            "interrupt_message",
        ]
        if reserved.contains(where: {
            $0.lowercased() == name.lowercased()
        }) {
            return .failure(IntatisLocalization.format(
                "@%@ is reserved.",
                name))
        }
        let existing = latestCoworkProjection.agentRoster.keys.map(\.rawValue)
            + projectSettings.codexAgentProfiles.map(\.roleName)
            + codexChildThreadsByID.values.flatMap {
                [$0.displayName, $0.agentRole].compactMap { $0 }
            }
        if existing.contains(name) {
            return .failure(IntatisLocalization.format(
                "@%@ is already attached.",
                name))
        }
        if existing.contains(where: { $0.lowercased() == name.lowercased() }) {
            return .failure(IntatisLocalization.format(
                "@%@ conflicts with an attached agent name.",
                name))
        }
        return .success(name)
    }

    private static func normalizedAgentName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    }

    private func attachFailureStatus(agentName: String, events: [Envelope]) -> CoworkAddAgentStatus {
        if let denied = events.compactMap({ envelope -> WorkspaceLeaseDeniedPayload? in
            if case .workspaceLeaseDenied(let payload) = envelope.event, payload.agent?.rawValue == agentName {
                return payload
            }
            return nil
        }).last {
            return .denied(denied.reason)
        }
        if let denied = events.compactMap({ envelope -> PermissionResolvedPayload? in
            if case .permissionResolved(let payload) = envelope.event,
               payload.tool == "agent.attach",
               payload.decision == .deny {
                return payload
            }
            return nil
        }).last {
            return .denied(denied.reason)
        }
        if let error = events.compactMap({ envelope -> ErrorPayload? in
            if case .error(let payload) = envelope.event {
                return payload
            }
            return nil
        }).last {
            return .failed(error.message)
        }
        return .failed(IntatisLocalization.format(
            "Could not attach @%@.",
            agentName))
    }

    private static func makeProjectInfo(sessionID: SessionID,
                                        settings: CoworkProjectSettings,
                                        projection: CoworkProjection) -> CoworkProjectInfo {
        var workspacesByPath: [String: CoworkWorkspaceInfo] = [:]
        let mainName = settings.mainAgentName

        for workspace in settings.workspaces {
            let isPrimary = workspace.isPrimary || workspace.agentName == mainName
            workspacesByPath[workspace.path] = CoworkWorkspaceInfo(
                path: workspace.path,
                displayName: displayName(forPath: workspace.path),
                agentName: workspace.agentName,
                isPrimary: isPrimary,
                access: "configured",
                canRemove: !isPrimary)
        }

        let rosterByPath = Dictionary(grouping: projection.agentRoster.values) {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
        }
        for (path, payloads) in rosterByPath {
            let existing = workspacesByPath[path]
            let ordinaryPayloads = payloads
                .filter { $0.agent != Orchestrator.automaticPermissionReviewerID }
                .sorted { $0.agent.rawValue < $1.agent.rawValue }
            let isPrimary = existing?.isPrimary == true
                || ordinaryPayloads.contains { $0.agent.rawValue == mainName }
            let isShared = ordinaryPayloads.count > 1
            let solePayload = ordinaryPayloads.count == 1 ? ordinaryPayloads[0] : nil
            let agentName: String?
            if isShared {
                agentName = nil
            } else if let configuredOwner = existing?.agentName,
                      ordinaryPayloads.contains(where: {
                          $0.agent.rawValue == configuredOwner
                      }) {
                agentName = configuredOwner
            } else if existing == nil {
                agentName = solePayload?.agent.rawValue
            } else {
                // A project-level/shared settings entry must not acquire an
                // owner merely because one roster payload was projected last.
                agentName = nil
            }
            let access: String
            if isShared {
                access = "shared"
            } else if let payload = solePayload {
                access = accessDescription(for: payload.agent, in: projection)
            } else {
                access = existing?.access ?? "configured"
            }
            workspacesByPath[path] = CoworkWorkspaceInfo(
                path: path,
                displayName: displayName(forPath: path),
                agentName: agentName,
                isPrimary: isPrimary,
                access: access,
                canRemove: !isPrimary
                    && !isShared
                    && (agentName != nil || ordinaryPayloads.isEmpty))
        }

        let workspaces = workspacesByPath.values.sorted {
            if $0.isPrimary != $1.isPrimary { return $0.isPrimary && !$1.isPrimary }
            return $0.path < $1.path
        }

        return CoworkProjectInfo(
            sessionID: sessionID.rawValue,
            mainAgentName: mainName,
            defaultModel: defaultModelDescription(settings),
            defaultPermission: permissionDescription(settings.defaultPermissionProfile),
            tokenBudget: settings.tokenBudget.map {
                IntatisLocalization.format("%@ tok", formatNumber($0))
            },
            workspaces: workspaces)
    }

    private static func role(for leases: [CapabilityLease]) -> String {
        if leases.isEmpty { return "worker" }
        if leases.contains(where: { $0.tools.isEmpty }) {
            return "reviewer"
        }
        if leases.contains(where: { $0.tools.contains(.delegateTask) || $0.tools.contains(.attachWorkspace) }) {
            return "coordinator"
        }
        return "worker"
    }

    private static func accessDescription(for agent: AgentID, in projection: CoworkProjection) -> String {
        let access = projection.workspaceLeaseAgents
            .filter { $0.value == agent }
            .compactMap { projection.workspaceLeases[$0.key]?.access.rawValue }
            .sorted()
        return access.first ?? "configured"
    }

    private static func defaultModelDescription(_ settings: CoworkProjectSettings) -> String {
        let model = settings.defaultModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model, !model.isEmpty else {
            return IntatisLocalization.string("current model")
        }
        if let provider = settings.defaultProviderID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty {
            return "\(provider)/\(model)"
        }
        return model
    }

    private static func permissionDescription(_ rawValue: String) -> String {
        switch PermissionProfile(rawValue: rawValue) {
        case .some(.manual): return IntatisLocalization.string("manual")
        case .some(.reviewed): return IntatisLocalization.string("reviewed")
        case .some(.autopilot): return IntatisLocalization.string("autopilot")
        case .some(.readOnly): return IntatisLocalization.string("read only")
        case .some(.locked): return IntatisLocalization.string("locked")
        case .none: return rawValue
        }
    }

    private static func displayName(forPath path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func formatNumber(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

enum CoworkPermissionReviewerStatus: Equatable {
    case disabled
    case enabling
    case enabled(AgentID)
    case fallback(String)
    case degraded(String)
    case failed(String)

    var canRetry: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum CoworkAddAgentStatus: Equatable {
    case idle
    case validating
    case attaching(String)
    case attached(String)
    case denied(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .validating, .attaching:
            return true
        case .idle, .attached, .denied, .failed:
            return false
        }
    }

    var message: String? {
        switch self {
        case .idle:
            return nil
        case .validating:
            return IntatisLocalization.string("Validating agent…")
        case .attaching(let name):
            return IntatisLocalization.format("Attaching @%@…", name)
        case .attached(let name):
            return IntatisLocalization.format("@%@ attached.", name)
        case .denied(let reason):
            return IntatisLocalization.format("Permission denied: %@", reason)
        case .failed(let message):
            return message
        }
    }
}

private enum AgentNameValidation {
    case success(String)
    case failure(String)
}

private extension CodexRuntimeThreadHistory {
    var userMessageIDs: Set<String> {
        Set(items.compactMap { item in
            guard case .user(let id, _, _) = item else { return nil }
            return id
        })
    }

    func containsNewUserMessage(
        _ text: String,
        excluding baseline: Set<String>
    ) -> Bool {
        items.contains { item in
            guard case .user(let id, _, let candidate) = item else {
                return false
            }
            return !baseline.contains(id) && candidate == text
        }
    }
}
#endif
