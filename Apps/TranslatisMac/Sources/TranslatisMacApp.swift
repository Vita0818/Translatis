#if canImport(SwiftUI)
import SwiftUI
import Combine
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisConversation
import IntatisCoworkUI
import IntatisAgentKernel
import IntatisArtifacts
import IntatisTools
import IntatisMCP
import IntatisSharedUI
import IntatisKnowledge
import IntatisCodexRuntime
#if canImport(AppKit)
import AppKit
#endif

/// Wires process-wide provider configuration to the application-owned session
/// runtime registry. Window views only select which retained runtime to show.
@MainActor
final class AppEnvironment: ObservableObject {
    @Published private(set) var registry: ProviderRegistry
    @Published private(set) var providerCatalog: AppProviderCatalog
    @Published private(set) var inferenceProfileOptions: [AppInferenceProfileOption]
    @Published private(set) var inferenceCatalogError: String?
    @Published private(set) var chatSessionID: SessionID
    @Published private(set) var viewModel: ChatViewModel
    @Published private(set) var chatSessionError: String?
    @Published private(set) var projects: [ProjectFolderRecord]
    @Published private(set) var projectStoreError: String?
    @Published var needsAPIKey: Bool

    let runtimeManager: AppSessionRuntimeManager
    let mcp: AppMCPService
    private var chatRuntime: AppChatSessionRuntime
    private let secrets: ConfigSecretResolver
    private let inferenceCatalogStore: InferenceCatalogStore
    private var inferenceCatalogSnapshot: InferenceCatalogSnapshot?

    init(runtimeManager: AppSessionRuntimeManager) {
        PlatformProfile.current = AppConfig.platformProfile

        let initialProjects: [ProjectFolderRecord]
        let initialProjectStoreError: String?
        do {
            initialProjects = try ProjectFolderStore.load(
                root: AppConfig.appSupportDir()).projects
            initialProjectStoreError = nil
        } catch {
            initialProjects = []
            initialProjectStoreError = error.localizedDescription
        }

        self.runtimeManager = runtimeManager
        self.mcp = AppMCPService()
        self.secrets = ConfigSecretResolver()
        self.inferenceCatalogStore = InferenceCatalogStore(
            fileURL: AppConfig.appSupportDir()
                .appendingPathComponent("inference-catalog-v1.json"))
        self.inferenceCatalogSnapshot = nil
        self.inferenceProfileOptions = []
        self.inferenceCatalogError = nil
        self.providerCatalog = AppConfig.providerCatalog
        let initialRegistry = Self.makeProviderRegistry(
            resolver: secrets,
            inferenceCatalogSnapshot: nil)
        self.registry = initialRegistry
        let initialSession = AppConfig.recentSessions(kind: .chat).first?.id ?? AppConfig.defaultSession
        self.chatSessionID = initialSession
        let initialChatRuntime: AppChatSessionRuntime
        do {
            initialChatRuntime = try runtimeManager.chatRuntime(
                sessionID: initialSession,
                registry: initialRegistry)
        } catch {
            fatalError("Failed to open event log: \(error)")
        }
        self.chatRuntime = initialChatRuntime
        self.viewModel = initialChatRuntime.viewModel
        self.projects = initialProjects
        self.projectStoreError = initialProjectStoreError
        self.needsAPIKey = !Self.hasAPIKey(ref: AppConfig.selectedAPIKeyRef)

        Task { [weak self] in
            guard let self else { return }
            _ = try? await SessionProjectionStore.migrateLegacyDisplayName(
                in: self.chatRuntime.log,
                kind: .chat)
            await self.refreshInferenceCatalog()
        }
    }

    func startNewChatSession() {
        do {
            try switchChatSession(to: SessionID.new())
        } catch {
            chatSessionError = IntatisLocalization.format(
                "Could not start chat session: %@",
                error.localizedDescription)
        }
    }

    func resumeChatSession(_ session: AppSessionSummary) {
        do {
            try switchChatSession(to: session.id)
        } catch {
            chatSessionError = IntatisLocalization.format(
                "Could not resume chat session: %@",
                error.localizedDescription)
        }
    }

    func recentChatSessions() -> [AppSessionSummary] {
        AppConfig.recentSessions(kind: .chat)
    }

    @discardableResult
    func addProject(
        workspace: WorkspaceAccessLease,
        kind: SessionKind
    ) throws -> ProjectFolderRecord {
        let project = try ProjectFolderStore.add(
            root: AppConfig.appSupportDir(),
            kind: kind,
            path: workspace.canonicalPath)
        refreshProjects()
        return project
    }

    func removeProject(_ projectID: ProjectID) throws {
        try ProjectFolderStore.remove(
            root: AppConfig.appSupportDir(),
            projectID: projectID)
        refreshProjects()
    }

    func refreshProjects() {
        do {
            projects = try ProjectFolderStore.load(
                root: AppConfig.appSupportDir()).projects
            projectStoreError = nil
        } catch {
            projectStoreError = error.localizedDescription
        }
    }

    @discardableResult
    func startNewProjectChatSession(
        projectID: ProjectID
    ) throws -> ProjectConversationReference {
        try validateProjectFolder(
            projectID: projectID,
            expectedKind: .chat)
        let session = SessionID.new()
        let conversation = ProjectConversationReference(
            sessionID: session,
            kind: .chat)
        try associate(conversation, with: projectID)
        do {
            try switchChatSession(to: session)
            return conversation
        } catch {
            rollbackProjectConversation(conversation)
            throw error
        }
    }

    func removeProjectConversation(
        _ conversation: ProjectConversationReference
    ) throws {
        try ProjectFolderStore.removeConversation(
            root: AppConfig.appSupportDir(),
            conversation: conversation)
        refreshProjects()
    }

    func deleteChatSession(_ session: SessionID) async throws {
        guard !runtimeManager.isBusy(kind: .chat, sessionID: session) else {
            throw IntatisError.io(IntatisLocalization.string(
                "Wait for the Chat response to finish before deleting this session."))
        }
        if session == chatSessionID {
            let replacement = recentChatSessions()
                .first(where: { $0.id != session })?.id
                ?? SessionID.new()
            try switchChatSession(to: replacement)
        }
        try await runtimeManager.removeSession(
            kind: .chat,
            sessionID: session,
            reason: "Chat session deleted by user"
        ) {
            try SessionHistoryStore.deleteSession(
                root: AppConfig.appSupportDir(),
                session: session)
        }
    }

    func handleRemovedChatRuntime(sessionID: SessionID) {
        guard chatSessionID == sessionID else { return }
        let replacement = recentChatSessions()
            .first(where: { $0.id != sessionID })?.id
            ?? SessionID.new()
        do {
            try switchChatSession(to: replacement)
        } catch {
            chatSessionError = IntatisLocalization.format(
                "The removed Chat session could not be replaced: %@",
                error.localizedDescription)
        }
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let providerID = providerCatalog.selectedProvider?.id ?? "default"
        do {
            try AppConfig.writeEditableProviderConfig(
                catalog: providerCatalog,
                apiKeysByProviderID: [providerID: trimmed])
        } catch {
            return
        }
        secrets.cache(trimmed, for: .authFile(providerID: providerID))
        providerCatalog = AppConfig.providerCatalog
        needsAPIKey = false
        refreshProviderRegistry()
        scheduleInferenceCatalogRefresh()
    }

    func hasAPIKey(account: String) -> Bool {
        Self.hasAPIKey(ref: .authFile(providerID: account))
    }

    func hasAPIKey(for provider: AppProviderSettings) -> Bool {
        Self.hasAPIKey(ref: AppConfig.apiKeyRef(for: provider))
    }

    func saveSettings(catalog rawCatalog: AppProviderCatalog,
                      apiKeysByProviderID: [String: String]) throws {
        var catalog = AppConfig.normalizedCatalog(rawCatalog)
        var enteredAPIKeys: [String: String] = [:]
        for index in catalog.providers.indices {
            let provider = catalog.providers[index]
            let key = apiKeysByProviderID[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty else { continue }
            enteredAPIKeys[provider.id] = key
            catalog.providers[index].apiKeySource = nil
        }
        if !enteredAPIKeys.isEmpty {
            try AppConfig.writeEditableProviderConfig(
                catalog: catalog,
                apiKeysByProviderID: enteredAPIKeys)
            for (providerID, key) in enteredAPIKeys {
                secrets.cache(key, for: .authFile(providerID: providerID))
            }
        }
        AppConfig.providerCatalog = catalog
        providerCatalog = AppConfig.providerCatalog
        needsAPIKey = !Self.hasAPIKey(ref: catalog.selectedProvider.map(AppConfig.apiKeyRef(for:))
                                      ?? .authFile(providerID: "default"))

        refreshProviderRegistry()
        scheduleInferenceCatalogRefresh()
    }

    func selectProviderModel(providerID: String, modelID: String, variantID: String?) {
        let catalog = AppConfig.selectProviderModel(
            providerID: providerID,
            modelID: modelID,
            variantID: variantID)
        providerCatalog = catalog
        needsAPIKey = !Self.hasAPIKey(ref: catalog.selectedProvider.map(AppConfig.apiKeyRef(for:))
                                      ?? .authFile(providerID: "default"))
        refreshProviderRegistry()
        if inferenceCatalogSnapshot == nil {
            scheduleInferenceCatalogRefresh()
        }
    }

    func healthCheckSelectedProvider() async -> [ProviderHealthReport] {
        let options = ProviderHealthCheckOptions(timeoutSeconds: 15)
        let chat = await registry.healthCheck(role: .chat, options: options)
        let agent = await registry.healthCheck(role: .agent, options: options)
        return [chat, agent]
    }

    /// Build a fresh Code session bound to the chosen workspace folder.
    func makeCodeViewModel(workspace: WorkspaceAccessLease) throws -> CodeViewModel {
        let session = SessionID(rawValue: IDGen.random(prefix: "code"))
        return try makeCodeViewModel(session: session, workspace: workspace)
    }

    func makeProjectCodeViewModel(
        projectID: ProjectID
    ) throws -> CodeViewModel {
        let workspace = try projectWorkspaceAccess(
            projectID: projectID,
            expectedKind: .code)
        let session = SessionID(rawValue: IDGen.random(prefix: "code"))
        let conversation = ProjectConversationReference(
            sessionID: session,
            kind: .code)
        do {
            try associate(conversation, with: projectID)
        } catch {
            workspace.release()
            throw error
        }
        do {
            return try makeCodeViewModel(
                session: session,
                workspace: workspace)
        } catch {
            rollbackProjectConversation(conversation)
            throw error
        }
    }

    func makeCodeViewModel(session: SessionID,
                           workspace: WorkspaceAccessLease) throws -> CodeViewModel {
        if let existing = runtimeManager.cachedCodeRuntime(sessionID: session) {
            workspace.release()
            return existing
        }
        let hadRememberedAccess = try WorkspaceAccess.hasRememberedAccess(
            forPath: workspace.canonicalPath,
            in: session)
        do {
            try WorkspaceAccess.remember(
                workspace.scopedURL,
                for: session,
                isPrimary: true)
            let codeLog = try EventLog(session: session, fileURL: AppConfig.sessionFile(session))
            Task {
                _ = try? await SessionProjectionStore.migrateLegacyDisplayName(
                    in: codeLog,
                    kind: .code)
            }
            let runtime = CodeViewModel(
                sessionID: session,
                workspaceAccess: workspace,
                log: codeLog,
                artifactStore:
                    try ArtifactStore(
                        root:
                            AppConfig.artifactsDir(
                                session)),
                sessionNaming: makeSessionNamingService(log: codeLog, kind: .code),
                registry: registry,
                mcpSnapshots:
                    makeMCPSnapshotFactory(
                        kind: .code,
                        sessionID: session,
                        log: codeLog,
                        workspacePaths: [
                            workspace.canonicalPath,
                        ]),
                codexMCPConfiguration:
                    makeCodexMCPConfigurationFactory(
                        log: codeLog),
                internalToolRegistryAugmenter:
                    makeKnowledgeToolAugmenter(),
                initialConfigurationNotice:
                    knowledgeToolsConfigurationNotice())
            return try runtimeManager.registerCodeRuntime(runtime)
        } catch {
            if !hadRememberedAccess {
                try? WorkspaceAccess.forget(
                    path: workspace.canonicalPath,
                    in: session,
                    allowPrimaryRemoval: true)
            }
            workspace.release()
            throw error
        }
    }

    /// Build a fresh multi-agent Cowork project session bound to a primary workspace.
    func makeCoworkViewModel(primaryWorkspace: WorkspaceAccessLease) async throws -> CoworkViewModel {
        let session = SessionID(rawValue: IDGen.random(prefix: "cowork"))
        return try await makeCoworkViewModel(
            session: session,
            primaryWorkspace: primaryWorkspace)
    }

    func makeProjectCoworkViewModel(
        projectID: ProjectID
    ) async throws -> CoworkViewModel {
        let workspace = try projectWorkspaceAccess(
            projectID: projectID,
            expectedKind: .cowork)
        let session = SessionID(rawValue: IDGen.random(prefix: "cowork"))
        let conversation = ProjectConversationReference(
            sessionID: session,
            kind: .cowork)
        do {
            try associate(conversation, with: projectID)
        } catch {
            workspace.release()
            throw error
        }
        do {
            return try await makeCoworkViewModel(
                session: session,
                primaryWorkspace: workspace)
        } catch {
            rollbackProjectConversation(conversation)
            throw error
        }
    }

    private func makeCoworkViewModel(
        session: SessionID,
        primaryWorkspace: WorkspaceAccessLease
    ) async throws -> CoworkViewModel {
        guard let inferenceCatalogSnapshot else {
            primaryWorkspace.release()
            throw IntatisError.config(
                inferenceCatalogError ?? IntatisLocalization.string(
                    "Inference profiles are still loading. Try again in a moment."))
        }
        guard let selectedBinding = AppInferenceCatalogCompiler.selectedBinding(
            catalog: providerCatalog,
            snapshot: inferenceCatalogSnapshot) else {
            primaryWorkspace.release()
            throw IntatisError.config(IntatisLocalization.string(
                "Choose a resolvable default inference profile before creating Cowork."))
        }
        // Codex App Server owns automatic approval review and binds it to the
        // selected Responses model through its official model catalog. The
        // legacy Intatis permission_reviewer_model is not a Cowork startup
        // dependency on the new kernel.
        let permissionReviewerBinding: AgentInferenceBinding? = nil
        do {
            try WorkspaceAccess.remember(
                primaryWorkspace.scopedURL,
                for: session,
                isPrimary: true)
            let settings = CoworkProjectSettings.fresh(
                sessionID: session,
                primaryWorkspace: primaryWorkspace.canonicalURL,
                catalog: providerCatalog,
                defaultInferenceProfileBinding: selectedBinding)
            let coworkLog = try EventLog(session: session, fileURL: AppConfig.sessionFile(session))
            return try await runtimeManager.coworkRuntime(sessionID: session) { [self] in
                try makeCoworkViewModel(
                    session: session,
                    log: coworkLog,
                    projectSettings: settings,
                    launchMode: .fresh,
                    initialWorkspaceAccess: primaryWorkspace,
                    permissionReviewerInferenceBinding:
                        permissionReviewerBinding)
            }
        } catch {
            try? WorkspaceAccess.forget(
                path: primaryWorkspace.canonicalPath,
                in: session,
                allowPrimaryRemoval: true)
            primaryWorkspace.release()
            throw error
        }
    }

    func makeCoworkViewModel(session: SessionID) async throws -> CoworkViewModel {
        guard let inferenceCatalogSnapshot else {
            throw IntatisError.config(
                inferenceCatalogError ?? IntatisLocalization.string(
                    "Inference profiles are still loading. Try again in a moment."))
        }
        let permissionReviewerBinding: AgentInferenceBinding? = nil
        return try await runtimeManager.coworkRuntime(sessionID: session) { [self] in
        let coworkLog = try EventLog(session: session, fileURL: AppConfig.sessionFile(session))
        let legacyOwnedWorkspacePaths = CoworkProjectSettingsStore
            .legacyOwnedWorkspacePaths(sessionID: session)
        let loaded = await CoworkProjectSettingsStore.loadAndMigrate(
            sessionID: session,
            log: coworkLog,
            inferenceCatalogSnapshot: inferenceCatalogSnapshot)
        var projectSettings = loaded.settings
        var warning = loaded.warning
        do {
            let projection = try await SessionProjectionStore.rebuild(from: coworkLog)
            let migrationAlreadyCompleted = projection.completedMigrations.contains {
                $0.migrationID == SessionProjectionStore.legacyWorkspaceAccessMigrationID
            }
            if migrationAlreadyCompleted {
                // Older/interrupted Phase S builds could have persisted a
                // symbolic-link spelling in EventLog while correctly keying
                // the capability plist by the canonical directory. Repair
                // only aliases proven through a live session bookmark.
                let mappings = try WorkspaceAccess.validatedCanonicalPathMappings(
                    for: projectSettings.workspaces.map(\.path),
                    in: session)
                projectSettings = try await persistValidatedWorkspacePathMappings(
                    mappings,
                    settings: projectSettings,
                    log: coworkLog)
                // The marker is appended only after the session-owned file was
                // read back successfully. Retrying cleanup here closes the
                // crash window between that durable marker and UserDefaults
                // deletion without ever re-importing shared capabilities.
                WorkspaceAccess.clearLegacySessionStorage(for: session)
                if loaded.legacySettingsCleanupEligible {
                    CoworkProjectSettingsStore.clearLegacyStorage(sessionID: session)
                }
            } else {
                let migration = try WorkspaceAccess.migrateLegacyBookmarks(
                    for: session,
                    workspacePaths: projectSettings.workspaces.map(\.path),
                    primaryPath: projectSettings.primaryWorkspace?.path,
                    sharedLegacyPaths: legacyOwnedWorkspacePaths)
                if migration.didMigrate {
                    projectSettings = try await persistValidatedWorkspacePathMappings(
                        migration.canonicalPathsByStoredPath,
                        settings: projectSettings,
                        log: coworkLog)
                    _ = try await SessionProjectionStore.recordMigration(
                        in: coworkLog,
                        migrationID: SessionProjectionStore.legacyWorkspaceAccessMigrationID,
                        source: .legacyWorkspaceUserDefaults)
                    WorkspaceAccess.clearLegacySessionStorage(for: session)
                    if loaded.legacySettingsCleanupEligible {
                        CoworkProjectSettingsStore.clearLegacyStorage(sessionID: session)
                    }
                }
            }
        } catch {
            let message = IntatisLocalization.format(
                "Legacy workspace access remains in compatibility mode: %@",
                error.localizedDescription)
            warning = warning.map { "\($0) \(message)" } ?? message
        }
        return try makeCoworkViewModel(
            session: session,
            log: coworkLog,
            projectSettings: projectSettings,
            launchMode: .restored,
            sessionStorageWarning: warning,
            permissionReviewerInferenceBinding:
                permissionReviewerBinding)
        }
    }

    private func persistValidatedWorkspacePathMappings(
        _ mappings: [String: String],
        settings: CoworkProjectSettings,
        log: EventLog
    ) async throws -> CoworkProjectSettings {
        guard !mappings.isEmpty else { return settings }
        var canonical = settings
        canonical.applyValidatedWorkspacePathMappings(mappings)
        guard canonical != settings else { return settings }
        let document = try await SessionProjectionStore.updateSettings(
            in: log,
            kind: .cowork,
            coworkSettings: canonical,
            changeKind: .migrated)
        guard let persisted = document.coworkSettings else {
            throw IntatisError.io(
                "Canonical workspace aliases were not persisted in session settings.")
        }
        return persisted
    }

    private func makeCoworkViewModel(
        session: SessionID,
        log coworkLog: EventLog,
        projectSettings: CoworkProjectSettings,
        launchMode: CoworkSessionLaunchMode,
        sessionStorageWarning: String? = nil,
        initialWorkspaceAccess: WorkspaceAccessLease? = nil,
        permissionReviewerInferenceBinding:
            AgentInferenceBinding?
    ) throws -> CoworkViewModel {
        let artifactStore = try ArtifactStore(root: AppConfig.artifactsDir(session))
        let permissionReviewerConfigurationError: String? = nil
        let combinedStorageWarning = [
            sessionStorageWarning,
            knowledgeToolsConfigurationNotice(),
        ].compactMap { $0 }.joined(separator: " ")
        return CoworkViewModel(
            sessionID: session,
            log: coworkLog,
            artifactStore: artifactStore,
            sessionNaming: makeSessionNamingService(log: coworkLog, kind: .cowork),
            registry: registry,
            inferenceProfileOptions: inferenceProfileOptions,
            permissionReviewerInferenceBinding:
                permissionReviewerInferenceBinding,
            permissionReviewerConfigurationError:
                permissionReviewerConfigurationError,
            projectSettings: projectSettings,
            launchMode: launchMode,
            sessionStorageWarning:
                combinedStorageWarning.isEmpty
                    ? nil
                    : combinedStorageWarning,
            initialWorkspaceAccess: initialWorkspaceAccess,
            mcpSnapshots:
                makeMCPSnapshotFactory(
                    kind: .cowork,
                    sessionID: session,
                    log: coworkLog,
                    workspacePaths:
                        projectSettings.workspaces
                            .map(\.path)),
            codexMCPConfiguration:
                makeCodexMCPConfigurationFactory(
                    log: coworkLog),
            internalToolRegistryAugmenter:
                makeKnowledgeToolAugmenter())
    }

    private func configuredPermissionReviewerBinding(
        snapshot: InferenceCatalogSnapshot
    ) -> AgentInferenceBinding? {
        guard let reviewer = providerCatalog.permissionReviewerModel else {
            return nil
        }
        // The top-level role names a base provider/model profile. It never
        // borrows the mutable UI-selected variant or the current @main route.
        return AppInferenceCatalogCompiler.binding(
            providerID: reviewer.endpoint,
            modelID: reviewer.model.rawValue,
            variantID: nil,
            snapshot: snapshot)
    }

    private func makeKnowledgeToolAugmenter()
        -> HostToolRegistryAugmenter? {
        let configured = AppConfig.providerConfig()
        guard (try? ProviderRegistry.validateKnowledgeConfiguration(
            configured)) != nil else { return nil }
        let providerRegistry = registry
        let external = KnowledgeAccess.externalAuthorityProvider()
        return HostToolRegistryAugmenter(
            additionalCapabilities: [.buildKnowledge, .searchKnowledge]) { input in
                let models = try await providerRegistry.configuredKnowledgeModels()
                let embedding = try ProviderKnowledgeEmbeddingAdapter(
                    provider: models.embedding)
                let reranker = try ProviderKnowledgeRerankerAdapter(
                    provider: models.reranker)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                let host = try ModelDrivenKnowledgeToolHost(
                    embeddingProvider: embedding,
                    rerankerProvider: reranker,
                    authorityResolver: KnowledgeStoreAuthorityResolver(
                        externalProvider: external),
                    policy: KnowledgeSearchPolicy(
                        evaluationDate: formatter.string(from: Date())))
                return try await host.augment(input)
            }
    }

    private func knowledgeToolsConfigurationNotice() -> String? {
        do {
            try ProviderRegistry.validateKnowledgeConfiguration(
                AppConfig.providerConfig())
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    private func makeMCPSnapshotFactory(
        kind: SessionKind,
        sessionID: SessionID,
        log: EventLog,
        workspacePaths: [String]
    ) -> @MainActor @Sendable () async throws
        -> MCPAgentRequestToolSnapshotSource
    {
        { [weak self] in
            guard let self else {
                throw IntatisError.io(
                    "The application MCP runtime owner is unavailable.")
            }
            let runtime =
                try await self.mcpSessionRuntime(
                    kind: kind,
                    sessionID: sessionID,
                    log: log,
                    workspacePaths:
                        workspacePaths)
            return runtime.snapshots
        }
    }

    private func makeCodexMCPConfigurationFactory(
        log: EventLog
    ) -> @MainActor @Sendable (
        AgentID,
        CapabilityLeaseID,
        TaskID?
    ) async throws -> CodexRuntimeMCPConfiguration {
        { [mcp] agentID, capabilityLeaseID, taskID in
            try await mcp.codexRuntimeConfiguration(
                log: log,
                agentID: agentID,
                capabilityLeaseID: capabilityLeaseID,
                taskID: taskID)
        }
    }

    func mcpSessionRuntime(
        kind: SessionKind,
        sessionID: SessionID,
        log: EventLog,
        workspacePaths: [String]
    ) async throws -> MCPShippingSessionRuntime {
        let registry = self.registry
        let bindings = Set(
            inferenceProfileOptions.map(\.binding))
        let catalog = try await mcp.catalogStore.load()
        let allowedElicitationOrigins = Set<String>(
            catalog.heads.compactMap { head -> String? in
                guard !head.disabled,
                      let revision =
                        head.currentRevision,
                      let definition =
                        catalog.definition(
                            for:
                                MCPServerReference(
                                    serverID:
                                        head.serverID,
                                    serverRevision:
                                        revision)),
                      definition.configuration
                        .enabled,
                      case .streamableHTTP(
                        let configuration) =
                        definition.configuration
                            .transport
                else {
                    return nil
                }
                return configuration.canonicalOrigin
            })
        let runtimeIdentity =
            Self.mcpRuntimeIdentityFingerprint(
                kind: kind,
                sessionID: sessionID,
                workspacePaths: workspacePaths)
        let shipping =
            try await runtimeManager.mcpRuntime(
                kind: kind,
                sessionID: sessionID
            ) { [mcp] in
                let artifactStore =
                    try ArtifactStore(
                        root:
                            AppConfig.artifactsDir(
                                sessionID))
                return try await mcp
                    .makeShippingSessionRuntime(
                        sessionID: sessionID,
                        log: log,
                        artifactStore:
                            artifactStore,
                        runtimeIdentityFingerprint:
                            runtimeIdentity,
                        samplingPolicy:
                            MCPSamplingPolicy(
                                enabled:
                                    !bindings.isEmpty,
                                allowedInferenceBindings:
                                    bindings),
                        samplingInference:
                            MCPProviderSamplingInferenceService {
                                binding in
                                try await registry
                                    .agentInference(
                                        for: binding)
                            },
                        elicitationPolicy:
                            MCPElicitationPolicy(
                                formEnabled: true,
                                urlEnabled:
                                    !allowedElicitationOrigins
                                        .isEmpty,
                                allowedURLOrigins:
                                    allowedElicitationOrigins))
            }
        await mcp.synchronizeRuntimeObservation(
            sessionID: sessionID,
            owner: shipping.owner)
        return shipping
    }

    private static func mcpRuntimeIdentityFingerprint(
        kind: SessionKind,
        sessionID: SessionID,
        workspacePaths: [String]
    ) -> String {
        var fields = [
            IntatisHostApplication.identity.temporaryPrefix(
                "mac-mcp-runtime-v1"),
            kind.rawValue,
            sessionID.rawValue,
        ]
        for path in Set(workspacePaths).sorted() {
            let canonical =
                URL(fileURLWithPath: path)
                    .standardizedFileURL.path
            fields.append(canonical)
            fields.append(
                WorkspaceRootIdentity.capture(
                    rootPath: canonical).map {
                        MCPHostDigest
                            .workspaceRootIdentity($0)
                    } ?? "missing-root")
        }
        return MCPHostDigest.sha256(fields)
    }

    private func makeSessionNamingService(
        log: EventLog,
        kind: SessionKind
    ) -> EventLogSessionNamingService {
        let manager = runtimeManager
        return EventLogSessionNamingService(log: log, kind: kind) { commit in
            await manager.publishSessionDisplayNameChange(AppSessionDisplayNameChange(
                key: AppSessionRuntimeKey(
                    kind: commit.kind,
                    sessionID: commit.sessionID),
                displayName: commit.displayName,
                settingsRevision: commit.settingsRevision,
                projectedThroughSeq: commit.projectedThroughSeq))
        }
    }

    private func projectWorkspaceAccess(
        projectID: ProjectID,
        expectedKind: SessionKind
    ) throws -> WorkspaceAccessLease {
        let project = try projectRecord(
            projectID: projectID,
            expectedKind: expectedKind)
        guard let workspace = WorkspaceAccess.choose(
            prompt: IntatisLocalization.string("Choose Project Folder")) else {
            throw CancellationError()
        }
        guard workspace.canonicalPath == project.path else {
            workspace.release()
            throw IntatisError.io(IntatisLocalization.string(
                "Choose the exact folder registered for this project."))
        }
        return workspace
    }

    private func validateProjectFolder(
        projectID: ProjectID,
        expectedKind: SessionKind
    ) throws {
        let project = try projectRecord(
            projectID: projectID,
            expectedKind: expectedKind)
        let url = try PathConfinement.canonicalExistingDirectory(
            URL(fileURLWithPath: project.path, isDirectory: true))
        guard url.path == project.path else {
            throw ProjectFolderStoreError.invalidProject
        }
    }

    private func projectRecord(
        projectID: ProjectID,
        expectedKind: SessionKind
    ) throws -> ProjectFolderRecord {
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw ProjectFolderStoreError.projectNotFound
        }
        guard project.kind == expectedKind else {
            throw ProjectFolderStoreError.invalidProject
        }
        return project
    }

    private func associate(
        _ conversation: ProjectConversationReference,
        with projectID: ProjectID
    ) throws {
        _ = try ProjectFolderStore.associate(
            root: AppConfig.appSupportDir(),
            projectID: projectID,
            conversation: conversation)
        refreshProjects()
    }

    private func rollbackProjectConversation(
        _ conversation: ProjectConversationReference
    ) {
        do {
            try ProjectFolderStore.removeConversation(
                root: AppConfig.appSupportDir(),
                conversation: conversation)
            refreshProjects()
        } catch {
            projectStoreError = error.localizedDescription
        }
    }

    func recentCodeSessions() -> [AppSessionSummary] {
        AppConfig.recentSessions(kind: .code)
    }

    func recentCoworkSessions() -> [AppSessionSummary] {
        AppConfig.recentSessions(kind: .cowork)
    }

    private func switchChatSession(to session: SessionID) throws {
        let runtime = try runtimeManager.chatRuntime(
            sessionID: session,
            registry: registry)
        self.chatRuntime = runtime
        self.viewModel = runtime.viewModel
        self.chatSessionID = session
        self.chatSessionError = nil
        Task {
            _ = try? await SessionProjectionStore.migrateLegacyDisplayName(
                in: runtime.log,
                kind: .chat)
        }
    }

    private static func makeProviderRegistry(
        resolver: ConfigSecretResolver,
        inferenceCatalogSnapshot: InferenceCatalogSnapshot?
    ) -> ProviderRegistry {
        ProviderRegistry(
            config: AppConfig.providerConfig(),
            resolver: resolver,
            inferenceCatalogSnapshot: inferenceCatalogSnapshot)
    }

    private func refreshProviderRegistry() {
        secrets.clearCache()
        let updated = Self.makeProviderRegistry(
            resolver: secrets,
            inferenceCatalogSnapshot: inferenceCatalogSnapshot)
        registry = updated
        runtimeManager.updateProviderRegistry(
            updated,
            inferenceProfileOptions: inferenceProfileOptions)
    }

    private func scheduleInferenceCatalogRefresh() {
        Task { [weak self] in
            await self?.refreshInferenceCatalog()
        }
    }

    private func refreshInferenceCatalog() async {
        let sourceCatalog = providerCatalog
        do {
            let draft = try AppInferenceCatalogCompiler.compile(catalog: sourceCatalog)
            let snapshot = try await inferenceCatalogStore.reconcile(draft)
            guard sourceCatalog == providerCatalog else {
                scheduleInferenceCatalogRefresh()
                return
            }
            inferenceCatalogSnapshot = snapshot
            inferenceProfileOptions = AppInferenceCatalogCompiler.options(
                catalog: sourceCatalog,
                snapshot: snapshot)
            inferenceCatalogError = nil
            refreshProviderRegistry()
        } catch {
            // Keep a previously valid snapshot/registry alive for exact
            // bindings. Initial startup remains fail-closed until a valid
            // durable catalog can be loaded or reconciled.
            inferenceCatalogError = IntatisLocalization.format(
                "Versioned inference profiles are unavailable: %@",
                error.localizedDescription)
        }
    }

    private static func hasAPIKey(ref: KeychainRef) -> Bool {
        ConfigSecretResolver.exists(ref)
    }

}

// The shell lives in TranslatisMacRootView; root-owned session state feeds the
// reusable workspace home and session views below.

struct WorkspaceSessionHome: View {
    let title: String
    let subtitle: String
    let icon: String
    let primaryTitle: String
    let primarySystemImage: String
    let primaryShortcut: KeyEquivalent?
    let error: String?
    let sessionsTitle: String
    let sessions: [AppSessionSummary]
    let workspacePath: (SessionID) -> String?
    let onPrimary: () -> Void
    let onResume: (AppSessionSummary) -> Void
    @Environment(\.colorScheme) private var scheme

    init(title: String,
         subtitle: String,
         icon: String,
         primaryTitle: String,
         primarySystemImage: String,
         primaryShortcut: KeyEquivalent? = nil,
         error: String?,
         sessionsTitle: String,
         sessions: [AppSessionSummary],
         workspacePath: @escaping (SessionID) -> String?,
         onPrimary: @escaping () -> Void,
         onResume: @escaping (AppSessionSummary) -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.primaryTitle = primaryTitle
        self.primarySystemImage = primarySystemImage
        self.primaryShortcut = primaryShortcut
        self.error = error
        self.sessionsTitle = sessionsTitle
        self.sessions = sessions
        self.workspacePath = workspacePath
        self.onPrimary = onPrimary
        self.onResume = onResume
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = TranslatisMacScreenLayout(rawWidth: proxy.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TranslatisPageHeader(title: title, subtitle: subtitle)

                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: icon)
                            .font(IntatisTypography.system(size: 28, weight: .semibold))
                            .foregroundStyle(TranslatisTheme.accent(scheme))
                            .frame(width: 64, height: 64)
                        Text(primaryTitle)
                            .font(TranslatisType.title(20))
                            .foregroundStyle(TranslatisTheme.deepText(scheme))
                        primaryButton
                        if let error {
                            Text(error)
                                .font(TranslatisType.caption(12))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 620, alignment: .leading)
                    .translatisCard(cornerRadius: 22)

                    if !sessions.isEmpty {
                        RecentSessionList(
                            title: sessionsTitle,
                            sessions: sessions,
                            workspacePath: workspacePath,
                            actionTitle: IntatisLocalization.string("Resume"),
                            onAction: onResume)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.top, 26)
                .padding(.bottom, 30)
                .frame(maxWidth: layout.settingsMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private var primaryButton: some View {
        let button = Button(action: onPrimary) {
            Label(primaryTitle, systemImage: primarySystemImage)
                .font(TranslatisType.body(14, .semibold))
                .foregroundStyle(.primary)
        }
        .controlSize(.large)
        .intatisGlassButton(prominent: true)

        if let primaryShortcut {
            button.keyboardShortcut(primaryShortcut)
        } else {
            button
        }
    }
}

private struct RecentSessionList: View {
    let title: String
    let sessions: [AppSessionSummary]
    let workspacePath: (SessionID) -> String?
    let actionTitle: String
    let onAction: (AppSessionSummary) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(TranslatisType.caption(12, .semibold))
                .foregroundStyle(TranslatisTheme.softText(scheme))
            ForEach(sessions) { session in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.id.rawValue)
                            .font(TranslatisType.caption(12, .semibold))
                            .foregroundStyle(TranslatisTheme.deepText(scheme))
                            .lineLimit(1)
                        Text(metadata(for: session))
                            .font(TranslatisType.caption(11, .regular))
                            .foregroundStyle(TranslatisTheme.softText(scheme))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button(actionTitle) { onAction(session) }
                        .controlSize(.small)
                        .intatisGlassButton()
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(TranslatisTheme.separator(scheme), lineWidth: 1)
                }
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: 760, alignment: .leading)
    }

    private func metadata(for session: AppSessionSummary) -> String {
        let timestamp = session.updatedAt == .distantPast
            ? IntatisLocalization.string("Unknown date")
            : session.updatedAt.formatted(date: .abbreviated, time: .shortened)
        let workspace = workspacePath(session.id).map { " · \($0)" } ?? ""
        let count = session.eventCount == 1
            ? IntatisLocalization.string("1 event")
            : IntatisLocalization.format("%lld events", Int64(session.eventCount))
        return "\(count) · \(timestamp)\(workspace)"
    }
}

struct CodeSessionView: View {
    @ObservedObject var vm: CodeViewModel
    let sessionTitle: String
    let catalog: AppProviderCatalog
    let mcpProjectSettingsHost:
        MCPProjectSettingsHost
    let mcpContentHost:
        MCPConversationContentHost
    let onSelectModel: (String, String, String?) -> Void
    let onShowSessions: () -> Void
    let onNewSession: () -> Void
    @Binding var showsInspector: Bool
    @State private var showMCPProjectSettings =
        false
    @State private var showMCPContent = false
    @State private var showAttachmentImporter = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
            CodeShell(items: vm.items,
                      presentationScope: IntatisThreadPresentationScope(
                        kind: .code,
                        sessionID: vm.sessionID),
                      sessionTitle: sessionTitle,
                      thinkingScopeID: vm.sessionID.rawValue,
                  pending: vm.pendingPermission,
                  permissionNotice: vm.permissionNotice,
                  isWorking: vm.isWorking,
                  workspaceName: vm.workspaceName,
                  agentState: vm.agentState,
                  errorTexts: [
                    vm.voiceInput.errorText,
                    vm.composerError,
                  ].compactMap { $0 },
                  threadStyle: .translatisMac(scheme),
                  onShowSessions: onShowSessions,
                  onNewSession: onNewSession,
                  composerAccessory: AnyView(HStack(
                    alignment: .center,
                    spacing: IntatisComposerControlMetrics.rowSpacing
                  ) {
                    IntatisComposerModelControl(
                        catalog: catalog,
                        isBusy: vm.isWorking,
                        onSelectModel: onSelectModel)
                    MCPPendingExternalContextControl(
                        count:
                            vm.pendingMCPExternalContextCount,
                        onCancel: {
                            vm.cancelPendingMCPExternalContexts()
                        })
                    IntatisMacComposerAttachmentAccessory(
                        attachments: vm.draftAttachments,
                        accessibilityPrefix: "code",
                        isDisabled: vm.isWorking,
                        onAttach: {
                            showAttachmentImporter = true
                        },
                        onRemove: {
                            vm.removeDraftAttachment($0)
                        })
                  }),
                  composerTrailingAction:
                    IntatisThreadComposerSecondaryAction(
                        systemImage: vm.voiceInput.buttonSystemImage,
                        help: vm.voiceInput.buttonHelp,
                        isBusy: vm.voiceInput.showsProgress,
                        isDisabled: vm.voiceInput.isToggleDisabled
                            || (vm.isWorking
                                && !vm.voiceInput.isRecording),
                        blocksSubmission: vm.voiceInput.isEngaged,
                        action: { vm.toggleVoiceInput() }),
                  headerActions: [
                    IntatisThreadHeaderAction(
                        title: "MCP Content",
                        systemImage: "shippingbox.and.arrow.backward",
                        isIconOnly: true,
                        help: "Browse granted MCP resources, prompts, tasks, and calls",
                        accessibilityIdentifier: "code.mcp.content") {
                            showMCPContent = true
                        },
                    IntatisThreadHeaderAction(
                        title: "MCP Settings",
                        systemImage: "network.badge.shield.half.filled",
                        isIconOnly: true,
                        help: "Attach servers and manage exact Agent MCP grants",
                        accessibilityIdentifier: "code.mcp.settings") {
                            showMCPProjectSettings = true
                        },
                  ],
                  showsInspector: $showsInspector,
                  input: $vm.input,
                  onSend: { vm.send() },
                  onCancelCurrent: { vm.cancelCurrentTurn() },
                  onRetrySubmission: { vm.retrySubmission($0) },
                  onResolve: { vm.resolvePermission($0) },
                  pendingUserInput: vm.pendingUserInput,
                  onSubmitUserInput: { vm.submitUserInput($0) })
            .sheet(isPresented: $showMCPContent) {
                MCPConversationCenterSheet(host: mcpContentHost)
            }
            .sheet(
                isPresented:
                    $showMCPProjectSettings
            ) {
                NavigationStack {
                    MCPProjectSettingsView(
                        host:
                            mcpProjectSettingsHost)
                        .navigationTitle(
                            "MCP Project Settings")
                }
                .frame(
                    minWidth: 980,
                    minHeight: 680)
            }
            .intatisComposerAttachmentImport(
                isPresented: $showAttachmentImporter,
                onImport: { vm.importDraftAttachments($0) },
                onFailure: { vm.reportAttachmentImportFailure($0) })
    }

}

struct CoworkSessionView: View {
    @ObservedObject var vm: CoworkViewModel
    let sessionTitle: String
    let catalog: AppProviderCatalog
    let mcpProjectSettingsHost:
        MCPProjectSettingsHost
    let mcpContentHost:
        MCPConversationContentHost
    let onShowSessions: () -> Void
    let onNewSession: () -> Void
    let onSessionDidBecomeReady: () -> Void
    @Binding var showsInspector: Bool

    var body: some View {
        IntatisCoworkContentView(
            state: contentState,
            threadSource: IntatisCoworkThreadSource(
                loadSnapshot: { [weak vm] agentID in
                    guard let vm else {
                        return .empty(agentID: agentID)
                    }
                    return await vm.agentThreadSnapshot(
                        agentID: agentID)
                },
                updates: { [weak vm] agentID in
                    guard let vm else {
                        return AsyncStream { $0.finish() }
                    }
                    return vm.agentThreadUpdates(
                        for: agentID)
                }),
            actions: contentActions,
            projectSettingsContent:
                AnyView(projectSettingsSheet),
            input: $vm.input,
            showsInspector: $showsInspector)
    }

    private var contentState: IntatisCoworkContentState {
        IntatisCoworkContentState(
            sessionID: vm.sessionID,
            sessionTitle: sessionTitle,
            agents: vm.agents,
            pendingPermission: vm.pendingPermission,
            permissionNotice: vm.permissionNotice,
            summary: vm.summary,
            project: vm.project,
            goal: vm.goal,
            workTasks: vm.workTasks,
            errorTexts: [
                vm.voiceInput.errorText,
                vm.composerError,
                vm.inferenceComposerError,
                vm.projectionError,
                vm.sessionStorageWarning,
            ].compactMap { $0 },
            isWorking:
                vm.isAgentWorkActive
                || vm.isGoalContinuing,
            isAcceptingSubmission:
                vm.isAcceptingSubmission,
            draftAttachments: vm.draftAttachments,
            inferenceOptions:
                vm.inferenceProfileOptions.map {
                    IntatisCoworkInferenceOption(
                        binding: $0.binding,
                        providerID: $0.providerID,
                        providerTitle: $0.providerTitle,
                        modelID: $0.modelID,
                        modelTitle: $0.modelTitle,
                        variantID: $0.variantID,
                        variantTitle: $0.variantTitle)
                },
            selectedInferenceBinding:
                vm.nextMainInferenceBinding,
            pendingMCPExternalContextCount:
                vm.pendingMCPExternalContextCount,
            voice: IntatisCoworkVoicePresentation(
                systemImage:
                    vm.voiceInput.buttonSystemImage,
                help: vm.voiceInput.buttonHelp,
                showsProgress:
                    vm.voiceInput.showsProgress,
                isToggleDisabled:
                    vm.voiceInput.isToggleDisabled,
                isRecording:
                    vm.voiceInput.isRecording,
                isEngaged:
                    vm.voiceInput.isEngaged),
            pendingUserInput: vm.pendingUserInput)
    }

    private var contentActions:
        IntatisCoworkContentActions
    {
        IntatisCoworkContentActions(
            onShowSessions: onShowSessions,
            onNewSession: onNewSession,
            onSessionDidBecomeReady:
                onSessionDidBecomeReady,
            onSelectInference: {
                vm.selectMainInferenceProfileForNextSubmission(
                    $0)
            },
            onCancelPendingMCPContext: {
                vm.cancelPendingMCPExternalContexts()
            },
            onImportAttachments: {
                vm.importDraftAttachments($0)
            },
            onAttachmentImportFailure: {
                vm.reportAttachmentImportFailure($0)
            },
            onRemoveAttachment: {
                vm.removeDraftAttachment($0)
            },
            onToggleVoice: {
                vm.toggleVoiceInput()
            },
            onSend: {
                vm.send()
            },
            onCancelCurrent: {
                vm.cancelCurrentActivity()
            },
            onResolvePermission: {
                vm.resolvePermission($0)
            },
            onRemoveAgent: {
                vm.removeAgent(name: $0)
            },
            onRetryTask: {
                vm.retryFailedTask(id: $0)
            },
            onRetrySubmission: {
                vm.retrySubmission($0)
            },
            onPauseGoal: {
                vm.pauseGoal()
            },
            onResumeGoal: {
                vm.resumeGoal()
            },
            goalEditDraft: {
                guard let draft =
                    vm.currentGoalEditDraft()
                else { return nil }
                return IntatisCoworkGoalEditDraft(
                    objective: draft.objective,
                    successCriteria:
                        draft.successCriteria,
                    constraints: draft.constraints,
                    tokenBudget: draft.tokenBudget)
            },
            onSaveGoal: {
                objective,
                successCriteria,
                constraints,
                tokenBudget in
                vm.editGoal(
                    objective: objective,
                    successCriteria: successCriteria,
                    constraints: constraints,
                    tokenBudget: tokenBudget)
            },
            onClearGoal: {
                vm.clearGoal()
            },
            onSubmitUserInput: {
                vm.submitUserInput($0)
            })
    }

    private var projectSettingsSheet: some View {
        TabView {
            CoworkProjectSettingsSheet(
                vm: vm,
                catalog: catalog,
                inferenceProfileOptions:
                    vm.inferenceProfileOptions,
                onAddWorkspace: {
                    if let url = WorkspaceAccess.choose(
                        prompt:
                            IntatisLocalization.string(
                                "Choose Project Workspace"))
                    {
                        vm.addProjectWorkspace(url)
                    }
                })
                .tabItem {
                    Label(
                        "Project",
                        systemImage: "folder")
                }
            NavigationStack {
                MCPProjectSettingsView(
                    host:
                        mcpProjectSettingsHost,
                    contentHost:
                        mcpContentHost)
                    .navigationTitle(
                        "MCP Project Settings")
            }
            .tabItem {
                Label(
                    "MCP",
                    systemImage:
                        "network.badge.shield.half.filled")
            }
        }
        .frame(minWidth: 980, minHeight: 680)
    }
}
#if canImport(AppKit)
@MainActor
final class TranslatisApplicationDelegate: NSObject, NSApplicationDelegate {
    private var terminationTask: Task<Void, Never>?
    #if TRANSLATIS_RENDERER_VALIDATION
    private var rendererValidationWindowController:
        NSWindowController?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        TranslatisMacProcessDiagnostics.shared.start(
            application: NSApplication.shared)
        #if TRANSLATIS_RENDERER_VALIDATION
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-TranslatisRendererFixture"),
              let rawSeconds = Self.argumentValue(
                  after: "-TranslatisRendererFixtureAutoExitSeconds"),
              let seconds = Double(rawSeconds),
              (1...300).contains(seconds)
        else { return }
        let finalizeFixtureResult =
            RendererFixtureResultLifecycle.configure(
            arguments: arguments)
        _ = NSApplication.shared.setActivationPolicy(
            .regular)
        let controller = NSHostingController(
            rootView:
                RendererFixtureView(
                    arguments: arguments))
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 1_280,
                height: 900),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
            ],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.title =
            "Translatis Renderer Validation"
        window.center()
        let windowController =
            NSWindowController(
                window: window)
        rendererValidationWindowController =
            windowController
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(
            ignoringOtherApps: true)

        // Keep watchdog auto-exit independent of SwiftUI view-task lifetime.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            _ = finalizeFixtureResult?()
            NSApplication.shared.terminate(nil)
        }
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TranslatisMacProcessDiagnostics.shared.beginTermination()
        #if TRANSLATIS_RENDERER_VALIDATION
        // The offline renderer fixture never creates AppEnvironment or session runtimes.
        // Let its watchdog-owned auto-exit complete inside the containment window
        // instead of paying the production runtime-drain deadline.
        if ProcessInfo.processInfo.arguments.contains("-TranslatisRendererFixture") {
            RendererFixtureResultLifecycle.sealForExit()
            return .terminateNow
        }
        #endif
        let manager = AppSessionRuntimeManager.shared
        if manager.state == .stopped {
            return .terminateNow
        }
        guard terminationTask == nil else { return .terminateLater }
        let deadline: SessionRuntimeShutdownDeadline
        #if DEBUG
        if let raw = Self.argumentValue(after: "-TranslatisShutdownDeadlineMilliseconds"),
           let milliseconds = Int64(raw), milliseconds >= 0 {
            deadline = .after(.milliseconds(milliseconds))
        } else {
            deadline = .after(.seconds(8))
        }
        #else
        deadline = .after(.seconds(8))
        #endif
        terminationTask = Task { @MainActor [weak self] in
            _ = await manager.shutdownAll(
                reason: "Application quit requested",
                deadline: deadline)
            sender.reply(toApplicationShouldTerminate: true)
            self?.terminationTask = nil
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        TranslatisMacProcessDiagnostics.shared.beginTermination()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private static func argumentValue(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
#endif

@main
struct TranslatisMacApp: App {
    #if canImport(AppKit)
    @NSApplicationDelegateAdaptor(TranslatisApplicationDelegate.self)
    private var applicationDelegate
    #endif

    init() {
        try! IntatisHostApplication.configure(name: "Translatis")
        IntatisTypography.prepareJetBrainsMonoTypography()
    }

    private var launchAppearance: ColorScheme? {
        #if DEBUG || TRANSLATIS_RENDERER_VALIDATION
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-TranslatisAppearanceDark") { return .dark }
        if arguments.contains("-TranslatisAppearanceLight") { return .light }
        #endif
        return nil
    }

    #if DEBUG
    private var launchesCoworkAgentConversationFixture: Bool {
        ProcessInfo.processInfo.arguments.contains(
            "-TranslatisCoworkAgentConversationFixture")
            || Bundle.main.bundleIdentifier?.hasSuffix(
                ".CoworkAgentConversationFixture") == true
    }

    private var launchesRequestUserInputFixture: Bool {
        ProcessInfo.processInfo.arguments.contains(
            "-TranslatisRequestUserInputFixture")
            || Bundle.main.bundleIdentifier?.hasSuffix(
                ".RequestUserInputFixture") == true
    }

    private var launchesMessageFooterFixture: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(
            ".MessageFooterFixture") == true
    }

    private var documentSelectionFixtureStage: String? {
        let identifier = Bundle.main.bundleIdentifier
        if identifier?.hasSuffix(".DocumentSelectionFixture") == true {
            return "code-selection"
        }
        if identifier?.hasSuffix(".DocumentSelectionTableFixture") == true {
            return "table"
        }
        if identifier?.hasSuffix(".DocumentSelectionFullFixture") == true {
            return "full-static"
        }
        return nil
    }

    private var messageFooterFixtureArguments: [String] {
        return ProcessInfo.processInfo.arguments + [
            "-TranslatisRendererFixtureStage",
            "message-footer",
        ]
    }
    private var documentSelectionFixtureArguments: [String] {
        guard let documentSelectionFixtureStage else {
            return ProcessInfo.processInfo.arguments
        }
        return ProcessInfo.processInfo.arguments + [
            "-TranslatisRendererFixtureStage",
            documentSelectionFixtureStage,
        ]
    }
    #endif

    var body: some Scene {
        WindowGroup {
            #if DEBUG || TRANSLATIS_RENDERER_VALIDATION
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-TranslatisPhaseLLifecycleFixture") {
                PhaseLSessionLifecycleFixtureView()
                    .preferredColorScheme(launchAppearance)
            } else if ProcessInfo.processInfo.arguments.contains("-TranslatisPhaseCPermissionFixture") {
                PhaseCPermissionFixtureView()
                    .preferredColorScheme(launchAppearance)
            } else if launchesRequestUserInputFixture {
                RequestUserInputFixtureView()
                    .preferredColorScheme(launchAppearance ?? .light)
            } else if launchesCoworkAgentConversationFixture {
                CoworkAgentConversationFixtureView()
                    .preferredColorScheme(launchAppearance)
            } else if launchesMessageFooterFixture {
                RendererFixtureView(
                    arguments: messageFooterFixtureArguments)
                    .preferredColorScheme(launchAppearance)
            } else if documentSelectionFixtureStage != nil {
                RendererFixtureView(
                    arguments: documentSelectionFixtureArguments)
                    .preferredColorScheme(launchAppearance)
            } else if ProcessInfo.processInfo.arguments.contains("-TranslatisRendererFixture") {
                RendererFixtureView()
                    .preferredColorScheme(launchAppearance)
            } else {
                TranslatisProductionRootView(launchAppearance: launchAppearance)
            }
            #else
            if ProcessInfo.processInfo.arguments.contains("-TranslatisRendererFixture") {
                // The validation-only AppDelegate owns the single deterministic
                // NSHostingController fixture window. Keeping this scene inert
                // avoids running the exact workload twice while preserving the
                // normal Debug fixture scene unchanged.
                Color.clear
                    .accessibilityIdentifier(
                        "renderer.validation.host.placeholder")
                    .preferredColorScheme(launchAppearance)
            } else {
                TranslatisProductionRootView(launchAppearance: launchAppearance)
            }
            #endif
            #else
            TranslatisProductionRootView(launchAppearance: launchAppearance)
            #endif
        }
        .defaultSize(width: 1100, height: 760)
    }
}

@MainActor
private struct TranslatisProductionRootView: View {
    @StateObject private var env: AppEnvironment
    let launchAppearance: ColorScheme?

    init(launchAppearance: ColorScheme?) {
        self.launchAppearance = launchAppearance
        _env = StateObject(wrappedValue: AppEnvironment(runtimeManager: .shared))
    }

    var body: some View {
        TranslatisMacRootView(runtimeManager: env.runtimeManager)
            .environmentObject(env)
            .font(IntatisTypography.globalFont)
            .preferredColorScheme(launchAppearance)
    }
}
#else
// Non-Apple platforms (e.g. Linux CI building the whole package): provide a
// trivial entry point so the executable target still links.
@main
struct TranslatisMacApp {
    static func main() {
        print("TranslatisMac is a macOS SwiftUI app and only runs on macOS.")
    }
}
#endif
