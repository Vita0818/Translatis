#if canImport(SwiftUI)
import Foundation
import Combine
import IntatisCore
import IntatisProviders
import IntatisConversation
import IntatisArtifacts
import IntatisSharedUI
import IntatisMCP
import IntatisAgentKernel

struct AppSessionRuntimeKey: Hashable, Sendable {
    let kind: SessionKind
    let sessionID: SessionID

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind.rawValue == rhs.kind.rawValue && lhs.sessionID == rhs.sessionID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind.rawValue)
        hasher.combine(sessionID)
    }
}

struct AppSessionDisplayNameChange: Equatable, Sendable {
    let key: AppSessionRuntimeKey
    let displayName: String
    let settingsRevision: Int
    let projectedThroughSeq: Int
}

struct AppSessionActivitySettlement: Equatable, Sendable {
    let key: AppSessionRuntimeKey
}

enum AppSessionRuntimePresentationStatus: Equatable, Sendable {
    case opening
    case idle
    case running
    case removing

    var label: String? {
        switch self {
        case .opening:
            return "Opening"
        case .idle:
            return nil
        case .running:
            return "Running"
        case .removing:
            return "Stopping"
        }
    }

    var blocksDeletion: Bool {
        self != .idle
    }
}

struct AppSessionRuntimeStatusChange: Equatable, Sendable {
    let key: AppSessionRuntimeKey
    let status: AppSessionRuntimePresentationStatus?
}

enum AppSessionRuntimeManagerError: Error, LocalizedError {
    case quiescing
    case runtimeBusy(AppSessionRuntimeKey)
    case runtimeBeingRemoved(AppSessionRuntimeKey)

    var errorDescription: String? {
        switch self {
        case .quiescing:
            return "The application is stopping and cannot open another session runtime."
        case .runtimeBusy(let key):
            return "The \(key.kind.rawValue) session \(key.sessionID.rawValue) is still running. Stop it before deleting the session."
        case .runtimeBeingRemoved(let key):
            return "The \(key.kind.rawValue) session \(key.sessionID.rawValue) is being removed."
        }
    }
}

@MainActor
final class AppChatSessionRuntime {
    let sessionID: SessionID
    let log: EventLog
    let viewModel: ChatViewModel

    init(
        sessionID: SessionID,
        registry: ProviderRegistry,
        autoTitleCoordinator: ChatSessionAutoTitleCoordinator,
        onAutoTitleCommit: @escaping ChatSessionAutoTitleCommitHandler
    ) throws {
        let openedLog = try EventLog(
            session: sessionID,
            fileURL: AppConfig.sessionFile(sessionID))
        let store = try ArtifactStore(root: AppConfig.artifactsDir(sessionID))
        let autoTitleSession = autoTitleCoordinator.bind(
            sessionID: sessionID,
            log: openedLog,
            onCommit: onAutoTitleCommit)
        let model = ChatViewModel(
            log: openedLog,
            registry: registry,
            artifactStore: store,
            autoTitleSession: autoTitleSession)
        self.sessionID = sessionID
        self.log = openedLog
        self.viewModel = model
        updateProviderRegistry(registry)
    }

    var isBusy: Bool { viewModel.isBusy }

    func start() {
        viewModel.start()
    }

    func updateProviderRegistry(_ registry: ProviderRegistry) {
        viewModel.updateProviderRegistry(registry)
    }

    func shutdown(reason: String) async {
        await viewModel.shutdown(reason: reason)
    }
}

/// Process-owned registry for every live macOS session runtime.
///
/// Views retain only the runtime they are currently presenting. This manager
/// is the authoritative owner, so selecting another page/window never tears
/// down provider, tool, Goal, projection, or workspace state.
@MainActor
final class AppSessionRuntimeManager: ObservableObject {
    enum State: Equatable {
        case running
        case quiescing
        case stopped
    }

    private struct RuntimeEntry {
        var isBusy: @MainActor () -> Bool
        var shutdown: @MainActor (String) async -> Void
    }

    private enum CoworkSlot {
        case creating(UUID, Task<CoworkViewModel, Error>)
        case ready(CoworkViewModel)
    }

    private enum MCPSlot {
        case creating(
            UUID,
            Task<MCPShippingSessionRuntime, Error>
        )
        case ready(MCPShippingSessionRuntime)
    }

    static let shared = AppSessionRuntimeManager()

    @Published private(set) var state: State = .running
    let runtimeRemoved = PassthroughSubject<AppSessionRuntimeKey, Never>()
    let sessionDisplayNameChanged = PassthroughSubject<AppSessionDisplayNameChange, Never>()
    let sessionActivitySettled = PassthroughSubject<AppSessionActivitySettlement, Never>()
    let sessionRuntimeStatusChanged = PassthroughSubject<AppSessionRuntimeStatusChange, Never>()
    private var chatRuntimes: [SessionID: AppChatSessionRuntime] = [:]
    private let chatAutoTitleCoordinator = ChatSessionAutoTitleCoordinator()
    private var codeRuntimes: [SessionID: CodeViewModel] = [:]
    private var coworkRuntimes: [SessionID: CoworkSlot] = [:]
    private var mcpRuntimes: [AppSessionRuntimeKey: MCPSlot] = [:]
    private var mcpConversationHosts:
        [AppSessionRuntimeKey:
            MCPConversationRuntimeHost] = [:]
    private var entries: [AppSessionRuntimeKey: RuntimeEntry] = [:]
    private var currentRegistry: ProviderRegistry?
    private var currentInferenceOptions: [AppInferenceProfileOption] = []
    private var runtimeActivityObservations: [AppSessionRuntimeKey: AnyCancellable] = [:]
    private var runtimeActivityStates: [AppSessionRuntimeKey: Bool] = [:]
    private var runtimeSettlementObservations: [AppSessionRuntimeKey: AnyCancellable] = [:]
    private var runtimeSettlementStates: [AppSessionRuntimeKey: Bool] = [:]
    private var runtimePresentationStatuses: [
        AppSessionRuntimeKey: AppSessionRuntimePresentationStatus
    ] = [:]
    private var sessionDisplayNameWatermarks = SessionDisplayNameWatermarks()
    private var removingKeys: Set<AppSessionRuntimeKey> = []
    private var shutdownBatch: BoundedSessionRuntimeShutdown?
    private(set) var shutdownReport: SessionRuntimeShutdownReport?
    #if DEBUG
    private var validationRuntimeObjects: [AppSessionRuntimeKey: AnyObject] = [:]
    #endif

    var acceptsNewRuntimes: Bool { state == .running }

    func chatRuntime(
        sessionID: SessionID,
        registry: ProviderRegistry
    ) throws -> AppChatSessionRuntime {
        guard state == .running else { throw AppSessionRuntimeManagerError.quiescing }
        let key = AppSessionRuntimeKey(kind: .chat, sessionID: sessionID)
        guard !removingKeys.contains(key) else {
            throw AppSessionRuntimeManagerError.runtimeBeingRemoved(key)
        }
        currentRegistry = registry
        if let existing = chatRuntimes[sessionID] {
            existing.updateProviderRegistry(registry)
            // `ChatViewModel.start()` is idempotent while subscribed and
            // retries a strict history snapshot after a transient replay
            // failure released its subscription slot.
            existing.start()
            return existing
        }
        let runtime = try AppChatSessionRuntime(
            sessionID: sessionID,
            registry: registry,
            autoTitleCoordinator: chatAutoTitleCoordinator,
            onAutoTitleCommit: { [weak self] commit in
                guard commit.kind == .chat else { return }
                await self?.publishSessionDisplayNameChange(
                    AppSessionDisplayNameChange(
                        key: AppSessionRuntimeKey(
                            kind: .chat,
                            sessionID: commit.sessionID),
                        displayName: commit.displayName,
                        settingsRevision: commit.settingsRevision,
                        projectedThroughSeq: commit.projectedThroughSeq))
            })
        chatRuntimes[sessionID] = runtime
        entries[key] = RuntimeEntry(
            isBusy: { runtime.isBusy },
            shutdown: { reason in await runtime.shutdown(reason: reason) })
        observeActivity(
            Publishers.CombineLatest3(
                runtime.viewModel.$isStreaming,
                runtime.viewModel.$imageGenerationState,
                runtime.viewModel.$isImportingAttachments)
                .map { isStreaming, generationState, isImportingAttachments in
                    isStreaming
                        || generationState.isRunning
                        || isImportingAttachments
                },
            key: key)
        runtime.start()
        return runtime
    }

    func cachedCodeRuntime(sessionID: SessionID) -> CodeViewModel? {
        codeRuntimes[sessionID]
    }

    /// Returns the process-owned MCP runtime for one exact Code/Cowork
    /// session. Views never retain or create connection pools directly.
    func mcpRuntime(
        kind: SessionKind,
        sessionID: SessionID,
        create: @escaping @MainActor () async throws
            -> MCPShippingSessionRuntime
    ) async throws -> MCPShippingSessionRuntime {
        guard kind.rawValue == SessionKind.code.rawValue
                || kind.rawValue == SessionKind.cowork.rawValue else {
            throw IntatisError.config(
                "MCP is available only to Code and Cowork sessions")
        }
        guard state == .running else {
            throw AppSessionRuntimeManagerError.quiescing
        }
        let key = AppSessionRuntimeKey(
            kind: kind,
            sessionID: sessionID)
        guard !removingKeys.contains(key) else {
            throw AppSessionRuntimeManagerError
                .runtimeBeingRemoved(key)
        }
        if let slot = mcpRuntimes[key] {
            switch slot {
            case .ready(let owner):
                return owner
            case .creating(let generation, let task):
                return try await finishMCPCreation(
                    key: key,
                    generation: generation,
                    task: task)
            }
        }
        let generation = UUID()
        let task = Task { @MainActor in
            try await create()
        }
        mcpRuntimes[key] = .creating(generation, task)
        return try await finishMCPCreation(
            key: key,
            generation: generation,
            task: task)
    }

    func cachedMCPRuntime(
        kind: SessionKind,
        sessionID: SessionID
    ) -> MCPShippingSessionRuntime? {
        let key = AppSessionRuntimeKey(
            kind: kind,
            sessionID: sessionID)
        guard case .ready(let owner)? = mcpRuntimes[key] else {
            return nil
        }
        return owner
    }

    func mcpConversationRuntimeHost(
        kind: SessionKind,
        sessionID: SessionID,
        create: @MainActor ()
            -> MCPConversationRuntimeHost
    ) -> MCPConversationRuntimeHost {
        let key = AppSessionRuntimeKey(
            kind: kind,
            sessionID: sessionID)
        if let existing =
                mcpConversationHosts[key] {
            return existing
        }
        let host = create()
        mcpConversationHosts[key] = host
        return host
    }

    private func finishMCPCreation(
        key: AppSessionRuntimeKey,
        generation: UUID,
        task: Task<MCPShippingSessionRuntime, Error>
    ) async throws -> MCPShippingSessionRuntime {
        do {
            let owner = try await task.value
            if case .ready(let existing)? = mcpRuntimes[key] {
                return existing
            }
            guard case .creating(let current, _)? =
                    mcpRuntimes[key],
                  current == generation,
                  state == .running,
                  !removingKeys.contains(key) else {
                _ = await owner.shutdown(
                    reason:
                        "Application lifecycle raced MCP runtime creation")
                throw AppSessionRuntimeManagerError.quiescing
            }
            mcpRuntimes[key] = .ready(owner)
            return owner
        } catch {
            if case .creating(let current, _)? =
                    mcpRuntimes[key],
               current == generation {
                mcpRuntimes.removeValue(forKey: key)
            }
            throw error
        }
    }

    private func shutdownMCPRuntime(
        key: AppSessionRuntimeKey,
        reason: String
    ) async {
        if let host =
                mcpConversationHosts.removeValue(
                    forKey: key) {
            await host.shutdown()
        }
        guard let slot = mcpRuntimes.removeValue(
            forKey: key) else { return }
        switch slot {
        case .ready(let owner):
            _ = await owner.shutdown(reason: reason)
        case .creating(_, let creation):
            creation.cancel()
            if let owner = try? await creation.value {
                _ = await owner.shutdown(reason: reason)
            }
        }
    }

    func registerCodeRuntime(_ runtime: CodeViewModel) throws -> CodeViewModel {
        guard state == .running else {
            Task { @MainActor in
                await runtime.shutdown(reason: "Application shutdown raced Code session creation")
            }
            throw AppSessionRuntimeManagerError.quiescing
        }
        let key = AppSessionRuntimeKey(kind: .code, sessionID: runtime.sessionID)
        guard !removingKeys.contains(key) else {
            Task { @MainActor in
                await runtime.shutdown(reason: "Code session is being removed")
            }
            throw AppSessionRuntimeManagerError.runtimeBeingRemoved(key)
        }
        if let existing = codeRuntimes[runtime.sessionID] {
            Task { @MainActor in
                await runtime.shutdown(reason: "Duplicate Code session runtime")
            }
            return existing
        }
        if let currentRegistry {
            runtime.updateProviderRegistry(currentRegistry)
        }
        codeRuntimes[runtime.sessionID] = runtime
        entries[key] = RuntimeEntry(
            isBusy: { runtime.isWorking },
            shutdown: { reason in await runtime.shutdown(reason: reason) })
        observeActivity(runtime.$isWorking, key: key)
        runtime.start()
        return runtime
    }

    func coworkRuntime(
        sessionID: SessionID,
        create: @escaping @MainActor () async throws -> CoworkViewModel
    ) async throws -> CoworkViewModel {
        guard state == .running else { throw AppSessionRuntimeManagerError.quiescing }
        let key = AppSessionRuntimeKey(kind: .cowork, sessionID: sessionID)
        guard !removingKeys.contains(key) else {
            throw AppSessionRuntimeManagerError.runtimeBeingRemoved(key)
        }
        if let slot = coworkRuntimes[sessionID] {
            switch slot {
            case .ready(let runtime):
                return runtime
            case .creating(let generation, let task):
                return try await finishCoworkCreation(
                    sessionID: sessionID,
                    generation: generation,
                    task: task)
            }
        }

        let generation = UUID()
        let task = Task { @MainActor in try await create() }
        coworkRuntimes[sessionID] = .creating(generation, task)
        publishRuntimeStatus(
            key: key,
            status: .opening)
        return try await finishCoworkCreation(
            sessionID: sessionID,
            generation: generation,
            task: task)
    }

    private func finishCoworkCreation(
        sessionID: SessionID,
        generation: UUID,
        task: Task<CoworkViewModel, Error>
    ) async throws -> CoworkViewModel {
        do {
            let runtime = try await task.value
            if case .ready(let existing)? = coworkRuntimes[sessionID] {
                return existing
            }
            guard case .creating(let activeGeneration, _)? = coworkRuntimes[sessionID],
                  activeGeneration == generation,
                  state == .running else {
                await runtime.stop(reason: "Application shutdown raced Cowork session creation")
                throw AppSessionRuntimeManagerError.quiescing
            }
            if let currentRegistry {
                runtime.updateProviderRegistry(
                    currentRegistry,
                    inferenceProfileOptions: currentInferenceOptions)
            }
            let key = AppSessionRuntimeKey(kind: .cowork, sessionID: sessionID)
            coworkRuntimes[sessionID] = .ready(runtime)
            entries[key] = RuntimeEntry(
                isBusy: { runtime.hasActiveWork },
                shutdown: { reason in await runtime.stop(reason: reason) })
            observeActivity(runtime.$runtimeBusy, key: key)
            observeSettlement(
                Publishers.CombineLatest3(
                    runtime.$isWorking,
                    runtime.$isAgentWorkActive,
                    runtime.$isGoalContinuing)
                    .map { $0 || $1 || $2 },
                key: key)
            runtime.start()
            return runtime
        } catch {
            if case .creating(let activeGeneration, _)? = coworkRuntimes[sessionID],
               activeGeneration == generation {
                coworkRuntimes.removeValue(forKey: sessionID)
                publishRuntimeStatus(
                    key: AppSessionRuntimeKey(kind: .cowork, sessionID: sessionID),
                    status: nil)
            }
            throw error
        }
    }

    func updateProviderRegistry(
        _ registry: ProviderRegistry,
        inferenceProfileOptions: [AppInferenceProfileOption]
    ) {
        currentRegistry = registry
        currentInferenceOptions = inferenceProfileOptions
        for runtime in chatRuntimes.values {
            runtime.updateProviderRegistry(registry)
        }
        for runtime in codeRuntimes.values {
            runtime.updateProviderRegistry(registry)
        }
        for slot in coworkRuntimes.values {
            guard case .ready(let runtime) = slot else { continue }
            runtime.updateProviderRegistry(
                registry,
                inferenceProfileOptions: inferenceProfileOptions)
        }
    }

    func isBusy(kind: SessionKind, sessionID: SessionID) -> Bool {
        let key = AppSessionRuntimeKey(kind: kind, sessionID: sessionID)
        if case .creating? = coworkRuntimes[sessionID], kind.rawValue == SessionKind.cowork.rawValue {
            return true
        }
        return entries[key]?.isBusy() ?? false
    }

    func statusLabel(kind: SessionKind, sessionID: SessionID) -> String? {
        let key = AppSessionRuntimeKey(kind: kind, sessionID: sessionID)
        if state != .running,
           runtimePresentationStatuses[key] != nil {
            return "Stopping"
        }
        return runtimePresentationStatuses[key]?.label
    }

    func runtimeStatusSnapshot() -> [
        AppSessionRuntimeKey: AppSessionRuntimePresentationStatus
    ] {
        runtimePresentationStatuses
    }

    /// Publishes only the newest verified display-name projection for an exact
    /// session. Concurrent rename transactions can finish rebuilding their
    /// projections out of order, so revision and sequence form a per-key
    /// high-watermark before any window is notified.
    func publishSessionDisplayNameChange(_ change: AppSessionDisplayNameChange) {
        guard sessionDisplayNameWatermarks.accept(
            sessionID: change.key.sessionID,
            kind: change.key.kind,
            settingsRevision: change.settingsRevision,
            projectedThroughSeq: change.projectedThroughSeq
        ) else { return }
        sessionDisplayNameChanged.send(change)
    }

    /// Drains one exact runtime and deletes its durable session state while the
    /// same removal fence remains installed. The final notification is emitted
    /// only after the storage transaction has either committed or aborted, so
    /// another window cannot reopen the key between runtime shutdown and disk
    /// deletion.
    ///
    /// If storage deletion fails, the stopped runtime is still detached and all
    /// windows are notified after the abort. The durable session remains intact
    /// and can be opened again as a fresh runtime once this method returns.
    func removeSession(
        kind: SessionKind,
        sessionID: SessionID,
        reason: String,
        deleteStorage: @escaping @MainActor () throws -> Void
    ) async throws {
        let key = AppSessionRuntimeKey(kind: kind, sessionID: sessionID)
        guard removingKeys.insert(key).inserted else {
            throw AppSessionRuntimeManagerError.runtimeBeingRemoved(key)
        }
        defer { removingKeys.remove(key) }
        guard !isBusy(kind: kind, sessionID: sessionID) else {
            throw AppSessionRuntimeManagerError.runtimeBusy(key)
        }
        publishRuntimeStatus(key: key, status: .removing)
        switch kind {
        case .chat:
            if let runtime = chatRuntimes.removeValue(forKey: sessionID) {
                await runtime.shutdown(reason: reason)
            }
        case .code:
            if let runtime = codeRuntimes.removeValue(forKey: sessionID) {
                await runtime.shutdown(reason: reason)
            }
        case .cowork:
            if case .ready(let runtime)? = coworkRuntimes.removeValue(forKey: sessionID) {
                await runtime.stop(reason: reason)
            }
        }
        await shutdownMCPRuntime(key: key, reason: reason)

        let storageError: Error?
        do {
            try deleteStorage()
            storageError = nil
        } catch {
            storageError = error
        }

        entries.removeValue(forKey: key)
        runtimeActivityObservations.removeValue(forKey: key)?.cancel()
        runtimeActivityStates.removeValue(forKey: key)
        runtimeSettlementObservations.removeValue(forKey: key)?.cancel()
        runtimeSettlementStates.removeValue(forKey: key)
        sessionDisplayNameWatermarks.remove(
            sessionID: key.sessionID,
            kind: key.kind)
        publishRuntimeStatus(key: key, status: nil)
        runtimeRemoved.send(key)
        if let storageError {
            throw storageError
        }
    }

    /// Atomically quiesces the registry, broadcasts shutdown to every retained
    /// runtime, and waits only until the monotonic deadline. A timed-out child
    /// is cancelled but deliberately not joined; process termination and the
    /// next cold-start reconciliation remain the final safety boundary.
    func shutdownAll(
        reason: String,
        deadline: SessionRuntimeShutdownDeadline = .after(.seconds(8))
    ) async -> SessionRuntimeShutdownReport {
        if let shutdownBatch {
            let report = await shutdownBatch.shutdown()
            shutdownReport = report
            state = .stopped
            return report
        }

        state = .quiescing
        var requests = entries.map { key, entry in
            SessionRuntimeStopRequest(
                identity: SessionRuntimeIdentity(
                    kind: key.kind,
                    sessionID: key.sessionID),
                stop: {
                    await entry.shutdown(reason)
                })
        }

        // MCP-only runtimes (for example a session explicitly connected from
        // Project Settings before its primary view opened) still participate
        // in the same bounded Command-Q drain. Keys that also own a primary
        // runtime are folded into that primary stop below.
        let mcpOnlyKeys =
            Set(mcpRuntimes.keys)
                .union(
                    mcpConversationHosts.keys)
        for key in mcpOnlyKeys where entries[key] == nil {
            requests.append(SessionRuntimeStopRequest(
                identity: SessionRuntimeIdentity(
                    kind: key.kind,
                    sessionID: key.sessionID),
                stop: { [weak self] in
                    await self?.shutdownMCPRuntime(
                        key: key,
                        reason: reason)
                }))
        }

        for (key, entry) in entries {
            guard mcpRuntimes[key] != nil
                    || mcpConversationHosts[key] != nil
            else { continue }
            if let index = requests.firstIndex(where: {
                $0.identity == SessionRuntimeIdentity(
                    kind: key.kind,
                    sessionID: key.sessionID)
            }) {
                requests[index] = SessionRuntimeStopRequest(
                    identity: SessionRuntimeIdentity(
                        kind: key.kind,
                        sessionID: key.sessionID),
                    stop: { [weak self] in
                        let primary = Task { @MainActor in
                            await entry.shutdown(reason)
                        }
                        let mcp = Task { @MainActor [weak self] in
                            await self?.shutdownMCPRuntime(
                                key: key,
                                reason: reason)
                        }
                        _ = await (primary.value, mcp.value)
                    })
            }
        }

        // A Cowork factory can be suspended in migration before a ViewModel is
        // published. Include that exact key in the same quit report and ensure
        // any late-created runtime is immediately drained instead of escaping
        // the quiescing fence.
        for (sessionID, slot) in coworkRuntimes {
            guard case .creating(_, let creation) = slot else { continue }
            let cleanup = Task { @MainActor in
                creation.cancel()
                if let runtime = try? await creation.value {
                    await runtime.stop(reason: reason)
                }
            }
            requests.append(SessionRuntimeStopRequest(
                identity: SessionRuntimeIdentity(
                    kind: .cowork,
                    sessionID: sessionID),
                stop: { await cleanup.value }))
        }

        let batch = BoundedSessionRuntimeShutdown(
            requests: requests,
            deadline: deadline)
        shutdownBatch = batch
        let report = await batch.shutdown()
        shutdownReport = report
        state = .stopped
        return report
    }

    #if DEBUG
    /// Returns the manager-owned validation runtime for an exact key, creating
    /// and registering it only once. The fixture view itself is deliberately
    /// window-owned, so closing every window proves that this registry—not a
    /// second static fixture store—keeps the runtime alive.
    func validationRuntime<Runtime: AnyObject & ObservableObject>(
        key: AppSessionRuntimeKey,
        create: @MainActor () -> Runtime,
        isBusy: @escaping @MainActor (Runtime) -> Bool,
        shutdown: @escaping @MainActor (Runtime, String) async -> Void
    ) -> Runtime {
        if let existing = validationRuntimeObjects[key] {
            guard let typed = existing as? Runtime else {
                preconditionFailure("Phase-L validation runtime type changed for \(key)")
            }
            return typed
        }
        precondition(state == .running, "Phase-L validation runtime registered after quiescing")
        precondition(entries[key] == nil, "Phase-L validation key collides with a production runtime")
        let runtime = create()
        validationRuntimeObjects[key] = runtime
        entries[key] = RuntimeEntry(
            isBusy: { isBusy(runtime) },
            shutdown: { reason in await shutdown(runtime, reason) })
        return runtime
    }
    #endif

    private func observeActivity<P: Publisher>(
        _ publisher: P,
        key: AppSessionRuntimeKey
    ) where P.Output == Bool, P.Failure == Never {
        runtimeActivityObservations[key] = publisher
            .removeDuplicates()
            .sink { [weak self] isActive in
                // All three runtime ViewModels are MainActor-bound, so their
                // @Published activity values arrive synchronously on MainActor.
                MainActor.assumeIsolated {
                    self?.runtimeActivityDidChange(
                        key: key,
                        isActive: isActive)
                }
            }
    }

    private func runtimeActivityDidChange(
        key: AppSessionRuntimeKey,
        isActive: Bool
    ) {
        guard entries[key] != nil else { return }
        let wasActive = runtimeActivityStates.updateValue(
            isActive,
            forKey: key)
        guard !removingKeys.contains(key) else { return }
        publishRuntimeStatus(
            key: key,
            status: isActive ? .running : .idle)
        if wasActive == true && !isActive,
           runtimeSettlementObservations[key] == nil {
            sessionActivitySettled.send(AppSessionActivitySettlement(key: key))
        }
    }

    private func observeSettlement<P: Publisher>(
        _ publisher: P,
        key: AppSessionRuntimeKey
    ) where P.Output == Bool, P.Failure == Never {
        runtimeSettlementObservations[key] = publisher
            .removeDuplicates()
            .sink { [weak self] isActive in
                MainActor.assumeIsolated {
                    self?.runtimeSettlementDidChange(
                        key: key,
                        isActive: isActive)
                }
            }
    }

    private func runtimeSettlementDidChange(
        key: AppSessionRuntimeKey,
        isActive: Bool
    ) {
        guard entries[key] != nil else { return }
        let wasActive = runtimeSettlementStates.updateValue(
            isActive,
            forKey: key)
        guard !removingKeys.contains(key) else { return }
        if wasActive == true && !isActive {
            sessionActivitySettled.send(AppSessionActivitySettlement(key: key))
        }
    }

    private func publishRuntimeStatus(
        key: AppSessionRuntimeKey,
        status: AppSessionRuntimePresentationStatus?
    ) {
        if removingKeys.contains(key),
           status != nil,
           status != .removing {
            return
        }
        guard runtimePresentationStatuses[key] != status else { return }
        if let status {
            runtimePresentationStatuses[key] = status
        } else {
            runtimePresentationStatuses.removeValue(forKey: key)
        }
        sessionRuntimeStatusChanged.send(AppSessionRuntimeStatusChange(
            key: key,
            status: status))
    }
}
#endif
