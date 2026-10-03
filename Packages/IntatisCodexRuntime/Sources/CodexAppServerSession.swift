import Foundation
import IntatisCore
import IntatisProtocol
import IntatisPermission
import IntatisTools
import IntatisProviders

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Thin owner for one official `codex app-server` process and one durable
/// Codex thread. The upstream runtime remains authoritative for agent-loop,
/// tools, sandboxing, approval review, context, and subagents.
public actor CodexAppServerSession {
    public static let pinnedRuntimeVersion =
        CodexRuntimeExecutable.pinnedVersion

    private typealias ResponseContinuation =
        CheckedContinuation<JSONValue, Error>
    private typealias TurnContinuation =
        CheckedContinuation<CodexRuntimeTurnResult, Error>

    private struct PendingResponse {
        let method: String
        let continuation: ResponseContinuation
        let timeoutTask: Task<Void, Never>
    }

    private struct PendingDynamicToolCall {
        let threadID: String
        let turnID: String
        let callID: String
        let executionLease: CodexRuntimeDynamicToolExecutionLease
        let task: Task<Void, Never>
    }

    private struct PendingUserInputRequest {
        let request: CodexRuntimeUserInputRequest
        let task: Task<Void, Never>
    }

    private struct DescendantExecutionPolicy: Equatable {
        let workspaceURL: URL
        let workspaceAccess: WorkspaceAccess
        let permissionProfile: PermissionProfile
        let knowledgeCapabilities: Set<ToolCapability>
        let hostedWebSearchScope:
            CodexRuntimeHostedWebSearchScope?
    }

    private enum DescendantInferenceSelection {
        case root
        case configured(CodexRuntimeChildProfile)
    }

    private struct BufferedChildNotification: Sendable {
        let method: String
        let params: JSONValue
    }

    private struct ResponsesUsageBreakdown {
        let inputTokens: Int
        let cachedInputTokens: Int
        let cacheWriteInputTokens: Int
        let outputTokens: Int
        let reasoningOutputTokens: Int
        let totalTokens: Int
    }

    private struct ThreadItemKey: Hashable {
        let threadID: String
        let itemID: String
    }

    private struct ThreadTurnKey: Hashable {
        let threadID: String
        let turnID: String
    }

    private let configuration: CodexRuntimeConfiguration
    private let storage: CodexRuntimeStorage
    private var processLease: CodexRuntimeProcessLease?
    private var process: Process?
    private var standardInput: FileHandle?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var stdoutBuffer = Data()
    private var stderrDiagnostic = ""
    private var nextRequestID = 1
    private var pendingResponses: [Int: PendingResponse] = [:]
    private var pendingApprovals:
        [CodexRuntimeRequestID: CodexRuntimeApprovalRequest] = [:]
    private var pendingDynamicToolCalls:
        [CodexRuntimeRequestID: PendingDynamicToolCall] = [:]
    private var pendingUserInputRequests:
        [CodexRuntimeRequestID: PendingUserInputRequest] = [:]
    private var pendingDescendantVerifications:
        [CodexRuntimeRequestID: Task<Void, Never>] = [:]
    private var pendingApprovalVerifications:
        [CodexRuntimeRequestID: Task<Void, Never>] = [:]
    private var pendingUserInputVerifications:
        [CodexRuntimeRequestID: Task<Void, Never>] = [:]
    private var pendingChildNotificationVerifications:
        [String: Task<Void, Never>] = [:]
    private var bufferedChildNotifications:
        [String: [BufferedChildNotification]] = [:]
    private var turnWaiters: [String: [TurnContinuation]] = [:]
    private var terminalTurns: [String: CodexRuntimeTurnResult] = [:]
    private var terminalTurnOrder: [String] = []
    private var emittedTurnStarts: Set<String> = []
    private var assistantMessagePhases: [String: MessagePhase] = [:]
    private var pendingResponsesUsage:
        (turnID: String, usage: ResponsesUsageBreakdown)?
    private var finalAnswerItemIDByTurnID: [String: String] = [:]
    private var fallbackAnswerItemIDByTurnID: [String: String] = [:]
    private var eventContinuations:
        [UUID: AsyncStream<CodexRuntimeEvent>.Continuation] = [:]
    private var runtimeIdentity: CodexRuntimeIdentity?
    /// The persisted join record identifies the expected root while
    /// `thread/resume` is still in flight. It classifies replayed
    /// notifications only; it never authorizes a tool or descendant before
    /// the resume response confirms the same ThreadID.
    private var pendingRootThreadID: String?
    /// Host-owned identities for Codex threads that the pinned runtime has
    /// declared as descendants of this session's root thread. The map is the
    /// only path by which a non-root thread can invoke an Intatis dynamic tool.
    private var descendantThreads:
        [String: CodexRuntimeThreadDescriptor] = [:]
    private var childAssistantMessagePhases:
        [ThreadItemKey: MessagePhase] = [:]
    private var childActiveTurnIDs: [String: String] = [:]
    private var childPendingResponsesUsage:
        [ThreadTurnKey: ResponsesUsageBreakdown] = [:]
    private var childFinalAnswerItemIDs: [ThreadTurnKey: String] = [:]
    private var childFallbackAnswerItemIDs: [ThreadTurnKey: String] = [:]
    private var childProviderIDs: [String: String] = [:]
    private var childProviderEnvironmentKeys: [String: String] = [:]
    private var childProfileURLs: [String: URL] = [:]
    private var needsDescendantRefresh = false
    private var hasPersistedThreadRecord = false
    private var activeTurnID: String?
    /// Remembers the process/protocol terminal across the narrow interval
    /// between a successful `turn/start` response and `waitForTurn` registering
    /// its continuation. Without this, an exit in that interval can leave the
    /// late waiter suspended forever after all existing waiters were drained.
    private var terminalSessionError: CodexRuntimeError?
    private var isStarting = false
    private var isShuttingDown = false
    private var isStoppingProcess = false
    private var isFailingEventBuffer = false
    private var deferredProcessRetirement: Task<Void, Never>?

    public init(configuration: CodexRuntimeConfiguration) {
        self.configuration = configuration
        self.storage = CodexRuntimeStorage(
            rootURL: configuration.runtimeRootURL,
            hostApplicationIdentity:
                configuration.hostApplicationIdentity)
    }

    public func events() -> AsyncStream<CodexRuntimeEvent> {
        let streamID = UUID()
        return AsyncStream(
            bufferingPolicy: .bufferingOldest(4_096)
        ) { continuation in
            eventContinuations[streamID] = continuation
            if let runtimeIdentity {
                continuation.yield(.ready(runtimeIdentity))
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(streamID) }
            }
        }
    }

    public func currentIdentity() -> CodexRuntimeIdentity? {
        runtimeIdentity
    }

    public func currentTurnID() -> String? {
        activeTurnID
    }

    public func descendantThreadDescriptors()
        -> [CodexRuntimeThreadDescriptor]
    {
        descendantThreads.values.sorted {
            let lhsCreated = $0.createdAt ?? Int.max
            let rhsCreated = $1.createdAt ?? Int.max
            if lhsCreated != rhsCreated {
                return lhsCreated < rhsCreated
            }
            return $0.threadID < $1.threadID
        }
    }

    public func threadHistory(
        threadID: String
    ) async throws -> CodexRuntimeThreadHistory {
        guard isAuthorizedThread(threadID) else {
            throw CodexRuntimeError.malformedProtocol(
                "thread/read targeted a thread outside the current Cowork tree")
        }
        let result = try await request(
            method: "thread/read",
            params: .object([
                "threadId": .string(threadID),
                "includeTurns": .bool(true),
            ]))
        guard let thread = result.objectValue?["thread"]?.objectValue,
              thread["id"]?.stringValue == threadID else {
            throw CodexRuntimeError.malformedProtocol(
                "thread/read returned a different or missing thread")
        }
        return try threadHistory(from: thread)
    }

    public func currentGoal() async throws -> CodexRuntimeGoalSnapshot? {
        guard let identity = runtimeIdentity else {
            throw CodexRuntimeError.notStarted
        }
        let result = try await request(
            method: "thread/goal/get",
            params: .object([
                "threadId": .string(identity.threadID),
            ]))
        guard let object = result.objectValue else {
            throw CodexRuntimeError.malformedProtocol(
                "thread/goal/get returned a non-object response")
        }
        if object["goal"] == nil || object["goal"] == .null {
            return nil
        }
        return try goalSnapshot(
            from: object["goal"],
            expectedThreadID: identity.threadID)
    }

    /// A new Intatis process must not turn a persisted active Goal into an
    /// implicit provider request. Use Codex's own durable Goal API before the
    /// resume lifecycle; a later explicit user Resume sets it active again.
    private func pauseActiveGoalBeforeThreadResume(
        threadID: String
    ) async throws {
        let currentResult = try await request(
            method: "thread/goal/get",
            params: .object([
                "threadId": .string(threadID),
            ]))
        guard let currentObject = currentResult.objectValue else {
            throw CodexRuntimeError.malformedProtocol(
                "thread/goal/get returned a non-object response before resume")
        }
        guard currentObject["goal"] != nil,
              currentObject["goal"] != .null else {
            return
        }
        let current = try goalSnapshot(
            from: currentObject["goal"],
            expectedThreadID: threadID)
        guard current.status == "active" else { return }

        let pausedResult = try await request(
            method: "thread/goal/set",
            params: .object([
                "threadId": .string(threadID),
                "status": .string("paused"),
            ]))
        let paused = try goalSnapshot(
            from: pausedResult.objectValue?["goal"],
            expectedThreadID: threadID)
        guard paused.status == "paused" else {
            throw CodexRuntimeError.malformedProtocol(
                "thread/goal/set did not pause the active Goal before resume")
        }
    }

    /// Sends an explicit host message through Codex's native V2 agent control
    /// plane. Routing is resolved entirely inside App Server/AgentControl; no
    /// root-model or provider request chooses the target.
    @discardableResult
    public func sendMessage(
        toDescendantThreadID threadID: String,
        text: String,
        triggerTurn: Bool = true
    ) async throws -> String {
        guard let identity = runtimeIdentity else {
            throw CodexRuntimeError.notStarted
        }
        guard let descriptor = descendantThreads[threadID],
              !descriptor.isArchived,
              descriptor.status != "shutdown" else {
            throw CodexRuntimeError.malformedProtocol(
                "subagent message targeted an unknown or ended descendant")
        }
        guard !text.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty else {
            throw CodexRuntimeError.malformedProtocol(
                "subagent message must not be empty")
        }
        let result = try await request(
            method: "thread/subagent/message",
            params: .object([
                "threadId": .string(identity.threadID),
                "targetThreadId": .string(threadID),
                "message": .string(text),
                "triggerTurn": .bool(triggerTurn),
            ]))
        guard let submissionID = result.objectValue?["submissionId"]?
                .stringValue,
              !submissionID.isEmpty else {
            throw CodexRuntimeError.malformedProtocol(
                "thread/subagent/message returned no submission id")
        }
        return submissionID
    }

    /// Archives one verified native child thread through the official App
    /// Server lifecycle. Its rollout remains readable and is rediscovered by
    /// the archived descendant query on the next session restore.
    public func archiveDescendantThread(threadID: String) async throws {
        guard runtimeIdentity != nil else {
            throw CodexRuntimeError.notStarted
        }
        guard descendantThreads[threadID] != nil else {
            throw CodexRuntimeError.malformedProtocol(
                "thread/archive targeted a thread outside the current Cowork tree")
        }
        _ = try await request(
            method: "thread/archive",
            params: .object([
                "threadId": .string(threadID),
            ]))
        invalidatePendingDynamicToolCalls(for: threadID)
        guard let previous = descendantThreads[threadID] else { return }
        registerDescendant(CodexRuntimeThreadDescriptor(
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
            isArchived: true,
            status: "shutdown",
            activeFlags: [],
            canAcceptDirectInput: false,
            createdAt: previous.createdAt))
    }

    @discardableResult
    public func reapplyConfiguredChildProfile(
        threadID: String
    ) async throws -> CodexRuntimeThreadDescriptor {
        guard let descriptor = descendantThreads[threadID],
              let role = descriptor.agentRole,
              configuration.childProfiles.contains(where: {
                  $0.roleName == role
              }) else {
            throw CodexRuntimeError.malformedProtocol(
                "the selected descendant has no configured Codex role")
        }
        return try await refreshDescendantMetadata(
            threadID: threadID,
            refreshMetadata: true)
    }

    private func turnInput(
        text: String,
        localImageURLs: [URL]
    ) throws -> [JSONValue] {
        let normalized = text.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !normalized.isEmpty || !localImageURLs.isEmpty else {
            throw CodexRuntimeError.malformedProtocol(
                "a turn requires text or an image")
        }
        var input: [JSONValue] = []
        if !normalized.isEmpty {
            input.append(.object([
                "type": .string("text"),
                "text": .string(text),
            ]))
        }
        for imageURL in localImageURLs {
            guard imageURL.isFileURL,
                  imageURL.path.hasPrefix("/") else {
                throw CodexRuntimeError.malformedProtocol(
                    "local image inputs require absolute file URLs")
            }
            input.append(.object([
                "type": .string("localImage"),
                "path": .string(imageURL.standardizedFileURL.path),
            ]))
        }
        return input
    }

    private func descendantInferenceSelection(
        for descriptor: CodexRuntimeThreadDescriptor,
        visited: Set<String> = []
    ) -> DescendantInferenceSelection? {
        guard !visited.contains(descriptor.threadID),
              let rootThreadID = runtimeIdentity?.threadID else {
            return nil
        }
        var visited = visited
        visited.insert(descriptor.threadID)
        if let role = descriptor.agentRole {
            guard let profile = configuration.childProfiles.first(where: {
                $0.roleName == role
            }) else { return nil }
            return .configured(profile)
        }
        if descriptor.parentThreadID == rootThreadID {
            return .root
        }
        guard let parent = descendantThreads[
            descriptor.parentThreadID] else { return nil }
        return descendantInferenceSelection(
            for: parent,
            visited: visited)
    }

    private func refreshDescendantMetadata(
        threadID: String,
        refreshMetadata: Bool = false
    ) async throws -> CodexRuntimeThreadDescriptor {
        guard let existing = descendantThreads[threadID] else {
            throw CodexRuntimeError.malformedProtocol(
                "metadata refresh targeted an unknown descendant thread")
        }
        guard !existing.isArchived else { return existing }
        guard let selection = descendantInferenceSelection(for: existing) else {
            throw CodexRuntimeError.malformedProtocol(
                "the descendant inference preset cannot be proven from its parent chain")
        }
        let targetModel: String
        let targetProvider: String
        let targetWorkspace: String
        let targetReasoningEffort: String?
        let targetSandbox: String
        let usesConfiguredProfile: Bool
        switch selection {
        case .root:
            targetModel = configuration.route.model.rawValue
            targetProvider = configuration.hostApplicationIdentity
                .fileNameStem
            targetWorkspace = configuration.workspaceURL
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
            targetReasoningEffort = configuration.reasoningEffort
                ?? configuration.route.reasoningEffort
            targetSandbox = configuration.rootPermissionProfile == .readOnly
                ? CodexRuntimeChildSandbox.readOnly.rawValue
                : CodexRuntimeChildSandbox.workspaceWrite.rawValue
            usesConfiguredProfile = false
        case .configured(let profile):
            guard let providerID = childProviderIDs[profile.roleName] else {
                throw CodexRuntimeError.malformedProtocol(
                    "the configured descendant provider was not materialized")
            }
            targetModel = profile.route.model.rawValue
            targetProvider = providerID
            targetWorkspace = profile.workspaceURL
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
            targetReasoningEffort = profile.route.reasoningEffort
            targetSandbox = profile.sandbox.rawValue
            usesConfiguredProfile = true
        }
        let profileNeedsRefresh = usesConfiguredProfile
            && (existing.requestedModel != targetModel
                || existing.modelProvider != targetProvider
                || existing.cwd != targetWorkspace
                || existing.reasoningEffort != targetReasoningEffort)
        if !refreshMetadata,
           !profileNeedsRefresh,
           existing.canAcceptDirectInput != nil {
            return existing
        }

        var resumeParameters = threadLifecycleParameters(
            includeDynamicTools: false)
        resumeParameters["threadId"] = .string(threadID)
        resumeParameters["excludeTurns"] = .bool(true)
        resumeParameters["model"] = .string(targetModel)
        resumeParameters["modelProvider"] = .string(targetProvider)
        resumeParameters["cwd"] = .string(targetWorkspace)
        resumeParameters["sandbox"] = .string(targetSandbox)
        if usesConfiguredProfile {
            resumeParameters["runtimeWorkspaceRoots"] = .array([
                .string(targetWorkspace),
            ])
        }
        var runtimeConfig = resumeParameters["config"]?.objectValue ?? [:]
        if !configuration.mcpConfiguration.isEmpty {
            runtimeConfig["mcp_servers"] = configuration
                .mcpConfiguration.disabledRoleOverlayValue
        }
        if let targetReasoningEffort {
            runtimeConfig["model_reasoning_effort"] = .string(
                targetReasoningEffort)
        } else {
            runtimeConfig.removeValue(forKey: "model_reasoning_effort")
        }
        resumeParameters["config"] = .object(runtimeConfig)
        let result = try await request(
            method: "thread/resume",
            params: .object(resumeParameters))
        guard let rootThreadID = runtimeIdentity?.threadID,
              let object = result.objectValue,
              let thread = object["thread"]?.objectValue,
              thread["id"]?.stringValue == threadID,
              let base = threadDescriptor(
                from: thread,
                rootThreadID: rootThreadID),
              base.parentThreadID == existing.parentThreadID,
              base.sessionID == rootThreadID else {
            throw CodexRuntimeError.malformedProtocol(
                "thread/resume returned a different or unauthorized descendant")
        }
        let runtimeRoots = object["runtimeWorkspaceRoots"]?.arrayValue?
            .compactMap(\.stringValue)
            .map { bounded(redact($0), limit: 4_096) } ?? []
        registerDescendant(CodexRuntimeThreadDescriptor(
            threadID: base.threadID,
            parentThreadID: base.parentThreadID,
            sessionID: base.sessionID,
            agentNickname: base.agentNickname,
            agentRole: base.agentRole,
            agentPath: base.agentPath,
            name: base.name,
            preview: base.preview,
            cwd: bounded(
                redact(object["cwd"]?.stringValue ?? base.cwd),
                limit: 4_096),
            modelProvider: bounded(
                redact(object["modelProvider"]?.stringValue
                    ?? base.modelProvider),
                limit: 256),
            requestedModel: object["model"]?.stringValue.map {
                bounded(redact($0), limit: 256)
            },
            reasoningEffort: object["reasoningEffort"]?.stringValue.map {
                bounded(redact($0), limit: 128)
            },
            serviceTier: object["serviceTier"]?.stringValue.map {
                bounded(redact($0), limit: 128)
            },
            runtimeWorkspaceRoots: runtimeRoots,
            isArchived: false,
            status: base.status,
            activeFlags: base.activeFlags,
            canAcceptDirectInput: base.canAcceptDirectInput,
            createdAt: base.createdAt))
        guard let loaded = descendantThreads[threadID] else {
            throw CodexRuntimeError.malformedProtocol(
                "thread/resume did not retain the verified descendant")
        }
        return loaded
    }

    @discardableResult
    public func start() async throws -> CodexRuntimeIdentity {
        if let runtimeIdentity { return runtimeIdentity }
        guard process == nil, !isStarting, !isShuttingDown else {
            throw CodexRuntimeError.alreadyRunning
        }
        isStarting = true
        defer { isStarting = false }
        isFailingEventBuffer = false
        terminalSessionError = nil
        clearChildPresentationState()
        stdoutBuffer.removeAll(keepingCapacity: false)
        stderrDiagnostic = ""

        guard configuration.rootPermissionProfile != .locked else {
            throw CodexRuntimeError.malformedProtocol(
                "the \(configuration.hostApplicationIdentity.name) locked profile cannot be represented by this Codex runtime")
        }
        try configuration.dynamicTools?.validate()
        try storage.prepare()
        if configuration.mode == .cowork {
            try storage.installCoworkSkill()
        }
        try storage.rejectPersistedShellSnapshots()
        let childProviders = try validatedChildProfileProviders()
        childProviderIDs = childProviders.providerIDs
        childProviderEnvironmentKeys = childProviders.environmentKeys
        processLease = try CodexRuntimeProcessLease(
            url: storage.processLockURL)
        do {
            childProfileURLs = try storage.writeChildProfiles(
                configuration.childProfiles,
                providerIDs: childProviderIDs,
                mcpConfiguration: configuration.mode == .cowork
                    ? configuration.mcpConfiguration
                    : .empty)
            try storage.writeAgentRegistry(
                configuration.childProfiles,
                profileURLs: childProfileURLs,
                mcpConfiguration:
                    configuration.mcpConfiguration)
            try storage.writeModelCatalog(
                modelID: configuration.route.model.rawValue,
                baseInstructions: configuration.mode.baseInstructions(
                    hostApplicationIdentity:
                        configuration.hostApplicationIdentity),
                reasoningEffort: configuration.reasoningEffort,
                multiAgentEnabled: nativeCollaborationEnabled,
                additionalModels: configuration.childProfiles.map {
                    (
                        modelID: $0.route.model.rawValue,
                        reasoningEffort: $0.route.reasoningEffort)
                })
            let executable = try CodexRuntimeExecutable.locate(
                override: configuration.executableOverride)
            let version = try CodexRuntimeExecutable.verifiedVersion(
                at: executable)
            try launchProcess(executableURL: executable)

            _ = try await request(
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string(configuration
                            .hostApplicationIdentity.fileNameStem),
                        "title": .string(configuration
                            .hostApplicationIdentity.name),
                        "version": .string("0.55"),
                    ]),
                    "capabilities": .object([
                        // `dynamicTools` and descendant-thread filters are
                        // official experimental App Server extensions in the
                        // pinned runtime. Cowork needs both to restore the
                        // exact native subagent tree; no private rollout scan
                        // substitutes for this capability.
                        "experimentalApi": .bool(
                            configuration.dynamicTools != nil
                                || nativeCollaborationEnabled),
                    ]),
                ]))

            if !configuration.skillConfiguration.isEmpty {
                _ = try await request(
                    method: "skills/extraRoots/set",
                    params: .object([
                        "extraRoots": .array(
                            configuration.skillConfiguration.wirePaths),
                    ]))
            }

            let workspacePath = configuration.workspaceURL
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
            let result: JSONValue
            let resumedThreadID: String?
            if let record = try storage.readRecord() {
                guard record.mode == configuration.mode,
                      record.workspacePath == workspacePath else {
                    throw CodexRuntimeError.unsafeRuntimeStorage
                }
                guard record.dynamicToolsetID
                        == effectiveRuntimeToolsetID else {
                    // The pinned protocol can register dynamic tools only on
                    // thread/start. Do not resume a thread under a different
                    // business-tool surface or simulate migration locally.
                    throw CodexRuntimeError.threadMigrationRequired
                }
                pendingRootThreadID = record.threadID
                if configuration.pauseActiveGoalBeforeResume {
                    try await pauseActiveGoalBeforeThreadResume(
                        threadID: record.threadID)
                }
                var params = threadLifecycleParameters(
                    includeDynamicTools: false)
                params["threadId"] = .string(record.threadID)
                result = try await request(
                    method: "thread/resume",
                    params: .object(params))
                resumedThreadID = record.threadID
            } else {
                guard configuration.allowsThreadCreation else {
                    throw CodexRuntimeError.threadMigrationRequired
                }
                result = try await request(
                    method: "thread/start",
                    params: .object(threadLifecycleParameters(
                        includeDynamicTools: true)))
                resumedThreadID = nil
            }

            let threadID = try Self.threadID(from: result)
            if let resumedThreadID,
               resumedThreadID != threadID {
                throw CodexRuntimeError.malformedProtocol(
                    "thread/resume returned a different thread id")
            }
            hasPersistedThreadRecord = resumedThreadID != nil
            let identity = CodexRuntimeIdentity(
                threadID: threadID,
                runtimeVersion: version,
                mode: configuration.mode)
            runtimeIdentity = identity
            pendingRootThreadID = nil
            if resumedThreadID != nil,
               nativeCollaborationEnabled {
                try await refreshDescendantThreads()
                try replayBufferedChildNotificationsAfterResume()
            }
            emit(.ready(identity))
            return identity
        } catch {
            await stopProcess(after: error)
            throw error
        }
    }

    /// Starts a turn and returns as soon as App Server accepts it. Completion
    /// continues through the event stream.
    @discardableResult
    public func startTurn(
        text: String,
        localImageURLs: [URL] = []
    ) async throws -> String {
        guard let identity = runtimeIdentity else {
            throw CodexRuntimeError.notStarted
        }
        guard activeTurnID == nil else {
            throw CodexRuntimeError.alreadyRunning
        }
        let input = try turnInput(
            text: text,
            localImageURLs: localImageURLs)

        var params: [String: JSONValue] = [
            "threadId": .string(identity.threadID),
            "input": .array(input),
            "clientUserMessageId": .string(UUID().uuidString.lowercased()),
            "cwd": .string(configuration.workspaceURL.path),
            "model": .string(configuration.route.model.rawValue),
            "approvalsReviewer": .string(
                configuration.approvalReviewer.rawValue),
        ]
        if let reasoningEffort = configuration.reasoningEffort,
           !reasoningEffort.isEmpty {
            params["effort"] = .string(reasoningEffort)
        }
        let result = try await request(
            method: "turn/start",
            params: .object(params))
        guard let turn = result.objectValue?["turn"]?.objectValue,
              let turnID = turn["id"]?.stringValue,
              !turnID.isEmpty else {
            throw CodexRuntimeError.malformedProtocol(
                "turn/start response is missing turn.id")
        }
        if terminalTurns[turnID] == nil {
            activeTurnID = turnID
            emitTurnStartedIfNeeded(turnID)
        }
        try persistThreadRecordIfNeeded(identity)
        return turnID
    }

    /// Runs one accepted turn to its official terminal notification.
    public func runTurn(
        text: String,
        localImageURLs: [URL] = []
    ) async throws -> CodexRuntimeTurnResult {
        let turnID = try await startTurn(
            text: text,
            localImageURLs: localImageURLs)
        let result = try await withTaskCancellationHandler {
            try await waitForTurn(turnID)
        } onCancel: {
            Task { try? await self.interruptTurn(turnID: turnID) }
        }
        // App Server attaches this client to internally spawned threads, but
        // it does not emit `thread/started` for that attach. Rebuild the
        // verified descendant map from the official thread store when a
        // collaboration item named a child that no prior notification proved.
        // Roster identity never depends on model-authored names or private
        // rollout files.
        if nativeCollaborationEnabled, needsDescendantRefresh {
            try await refreshDescendantThreads()
            needsDescendantRefresh = false
        }
        return result
    }

    public func waitForTurn(
        _ turnID: String
    ) async throws -> CodexRuntimeTurnResult {
        if let result = terminalTurns[turnID] {
            return try Self.validated(result)
        }
        if let terminalSessionError {
            throw terminalSessionError
        }
        guard process != nil, runtimeIdentity != nil else {
            throw CodexRuntimeError.notStarted
        }
        return try await withCheckedThrowingContinuation { continuation in
            turnWaiters[turnID, default: []].append(continuation)
        }
    }

    public func interruptCurrentTurn() async throws {
        guard let activeTurnID else {
            throw CodexRuntimeError.noActiveTurn
        }
        try await interruptTurn(turnID: activeTurnID)
    }

    public func interruptTurn(turnID: String) async throws {
        guard let identity = runtimeIdentity else {
            throw CodexRuntimeError.notStarted
        }
        try await interruptTurn(
            threadID: identity.threadID,
            turnID: turnID)
    }

    private func interruptTurn(
        threadID: String,
        turnID: String
    ) async throws {
        _ = try await request(
            method: "turn/interrupt",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ]),
            timeoutSeconds: 5)
    }

    public func setGoal(
        objective: String,
        tokenBudget: Int? = nil
    ) async throws {
        guard let identity = runtimeIdentity else {
            throw CodexRuntimeError.notStarted
        }
        let objective = objective.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !objective.isEmpty else {
            throw CodexRuntimeError.malformedProtocol(
                "a Codex goal requires a nonempty objective")
        }
        var params: [String: JSONValue] = [
            "threadId": .string(identity.threadID),
            "objective": .string(objective),
            "status": .string("active"),
        ]
        if let tokenBudget {
            guard tokenBudget > 0 else {
                throw CodexRuntimeError.malformedProtocol(
                    "a Codex goal token budget must be positive")
            }
            params["tokenBudget"] = .number(Double(tokenBudget))
        }
        let result = try await request(
            method: "thread/goal/set",
            params: .object(params))
        _ = try goalSnapshot(
            from: result.objectValue?["goal"],
            expectedThreadID: identity.threadID)
        try persistThreadRecordIfNeeded(identity)
    }

    /// Edits the current official Goal without changing its status or
    /// implicitly resuming a paused/blocked Goal.
    public func updateGoal(
        objective: String,
        tokenBudget: CodexRuntimeGoalBudgetUpdate = .keep
    ) async throws {
        guard let identity = runtimeIdentity else {
            throw CodexRuntimeError.notStarted
        }
        let objective = objective.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !objective.isEmpty else {
            throw CodexRuntimeError.malformedProtocol(
                "a Codex goal requires a nonempty objective")
        }
        var params: [String: JSONValue] = [
            "threadId": .string(identity.threadID),
            "objective": .string(objective),
        ]
        switch tokenBudget {
        case .keep:
            break
        case .clear:
            params["tokenBudget"] = .null
        case .set(let value):
            guard value > 0 else {
                throw CodexRuntimeError.malformedProtocol(
                    "a Codex goal token budget must be positive")
            }
            params["tokenBudget"] = .number(Double(value))
        }
        let result = try await request(
            method: "thread/goal/set",
            params: .object(params))
        _ = try goalSnapshot(
            from: result.objectValue?["goal"],
            expectedThreadID: identity.threadID)
        try persistThreadRecordIfNeeded(identity)
    }

    public func setGoalStatus(_ status: String) async throws {
        guard let identity = runtimeIdentity else {
            throw CodexRuntimeError.notStarted
        }
        guard [
            "active", "paused", "blocked", "usageLimited",
            "budgetLimited", "complete",
        ].contains(status) else {
            throw CodexRuntimeError.malformedProtocol(
                "unsupported Codex goal status")
        }
        let result = try await request(
            method: "thread/goal/set",
            params: .object([
                "threadId": .string(identity.threadID),
                "status": .string(status),
            ]))
        _ = try goalSnapshot(
            from: result.objectValue?["goal"],
            expectedThreadID: identity.threadID)
        try persistThreadRecordIfNeeded(identity)
    }

    public func clearGoal() async throws {
        guard let identity = runtimeIdentity else {
            throw CodexRuntimeError.notStarted
        }
        let result = try await request(
            method: "thread/goal/clear",
            params: .object([
                "threadId": .string(identity.threadID),
            ]))
        guard case .some(.bool(_)) = result.objectValue?["cleared"] else {
            throw CodexRuntimeError.malformedProtocol(
                "thread/goal/clear response is missing cleared")
        }
    }

    private func persistThreadRecordIfNeeded(
        _ identity: CodexRuntimeIdentity
    ) throws {
        guard !hasPersistedThreadRecord else { return }
        let workspacePath = configuration.workspaceURL
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        try storage.writeRecord(
            threadID: identity.threadID,
            mode: configuration.mode,
            workspacePath: workspacePath,
            dynamicToolsetID: effectiveRuntimeToolsetID)
        hasPersistedThreadRecord = true
    }

    /// The pinned App Server exposes structured input only when the host
    /// supplies a callback. Include that presentation capability in the
    /// persisted thread surface so a pre-UI thread cannot be resumed after
    /// the callback becomes available.
    private var effectiveRuntimeToolsetID: String? {
        Self.runtimeToolsetIdentity(
            dynamicToolsetID: configuration.dynamicTools?.toolsetID,
            requestUserInputEnabled:
                configuration.requestUserInputHandler != nil,
            hostApplicationIdentity:
                configuration.hostApplicationIdentity)
    }

    static func runtimeToolsetIdentity(
        dynamicToolsetID: String?,
        requestUserInputEnabled: Bool,
        hostApplicationIdentity: IntatisHostApplicationIdentity =
            .intatis
    ) -> String? {
        guard requestUserInputEnabled else { return dynamicToolsetID }
        let material = [
            dynamicToolsetID ?? "<none>",
            "request-user-input.v1",
        ].joined(separator: "\u{001F}")
        return hostApplicationIdentity
            .namespacedIdentifier("codex-session.")
            + String(ToolRegistry.authorizationDigest(material).prefix(24))
    }

    public func resolveApproval(
        requestID: CodexRuntimeRequestID,
        decision: CodexRuntimeApprovalDecision
    ) throws {
        guard let request = pendingApprovals[requestID] else {
            throw CodexRuntimeError.requestNotPending
        }
        let result: JSONValue
        switch request.kind {
        case .command, .fileChange:
            result = .object([
                "decision": .string(decision.rawValue),
            ])
        case .permissions:
            let permissions: JSONValue
            switch decision {
            case .accept, .acceptForSession:
                permissions = request.requestedPermissions
                    ?? .object([:])
            case .decline, .cancel:
                permissions = .object([:])
            }
            result = .object([
                "permissions": permissions,
                "scope": .string(
                    decision == .acceptForSession ? "session" : "turn"),
            ])
        }
        try sendResponse(id: requestID.wireValue, result: result)
        pendingApprovals.removeValue(forKey: requestID)
        emit(.approvalResolved(requestID))
        if request.kind == .permissions,
           decision == .cancel,
           !request.turnID.isEmpty {
            Task {
                try? await self.interruptTurn(
                    threadID: request.threadID,
                    turnID: request.turnID)
            }
        }
    }

    public func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        let dynamicToolTasks = pendingDynamicToolCalls.values.map(\.task)
        let userInputTasks = pendingUserInputRequests.values.map(\.task)
        let verificationTasks = Array(
            pendingDescendantVerifications.values)
            + Array(pendingApprovalVerifications.values)
            + Array(pendingUserInputVerifications.values)
            + Array(pendingChildNotificationVerifications.values)
        for task in dynamicToolTasks { task.cancel() }
        for task in userInputTasks { task.cancel() }
        for task in verificationTasks { task.cancel() }
        if let activeTurnID,
           let identity = runtimeIdentity,
           process != nil {
            _ = try? await request(
                method: "turn/interrupt",
                params: .object([
                    "threadId": .string(identity.threadID),
                    "turnId": .string(activeTurnID),
                ]),
                timeoutSeconds: 5)
        }
        for task in dynamicToolTasks { await task.value }
        for task in userInputTasks { await task.value }
        for task in verificationTasks { await task.value }
        await stopProcess(after: nil)
        if await configuration.dynamicTools?.shutdown() == false {
            emit(.runtimeError(
                code: "dynamic_tool_shutdown",
                message: "A registered business-tool resource did not drain cleanly during runtime shutdown.",
                fatal: false))
        }
        finishEventStreams()
    }

    private func validatedChildProfileProviders() throws -> (
        providerIDs: [String: String],
        environmentKeys: [String: String]
    ) {
        guard configuration.mode == .cowork
                || configuration.childProfiles.isEmpty else {
            throw CodexRuntimeError.malformedProtocol(
                "Codex child profiles are available only in Cowork mode")
        }
        let reservedRoleNames: Set<String> = [
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
        var names: Set<String> = []
        var foldedNames: Set<String> = []
        let sorted = configuration.childProfiles.sorted {
            $0.roleName < $1.roleName
        }
        var providerIDs: [String: String] = [:]
        var environmentKeys: [String: String] = [:]
        let allowedKnowledgeCapabilities: Set<ToolCapability> = [
            .buildKnowledge,
            .searchKnowledge,
        ]
        guard configuration.inheritedChildKnowledgeCapabilities
                .isSubset(of: allowedKnowledgeCapabilities),
              configuration.rootPermissionProfile != .readOnly
                || !configuration.inheritedChildKnowledgeCapabilities
                    .contains(.buildKnowledge) else {
            throw CodexRuntimeError.malformedProtocol(
                "the inherited Codex child Knowledge policy exceeds its host-approved workspace access")
        }
        let advertisesHostedWebSearch = configuration.dynamicTools?
            .contains(tool: HostedWebSearchTool.descriptor.name) == true
        guard !configuration.rootHostedWebSearchEnabled
                || advertisesHostedWebSearch else {
            throw CodexRuntimeError.malformedProtocol(
                "the root hosted-search service is not present in the registered dynamic-tool surface")
        }
        for profile in sorted {
            let name = profile.roleName
            guard !name.isEmpty,
                  name.count <= 64,
                  !reservedRoleNames.contains(name),
                  name.unicodeScalars.allSatisfy({ scalar in
                      switch scalar.value {
                      case 45, 48...57, 65...90, 95, 97...122:
                          return true
                      default:
                          return false
                      }
                  }),
                  names.insert(name).inserted,
                  foldedNames.insert(name.lowercased()).inserted else {
                throw CodexRuntimeError.malformedProtocol(
                    "Codex child profile names must be unique ASCII role identifiers")
            }
            let description = profile.description.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !description.isEmpty,
                  description.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                        || $0.value == 10 || $0.value == 9
                  }) else {
                throw CodexRuntimeError.malformedProtocol(
                    "a Codex child profile requires nonempty role instructions")
            }
            let workspace = profile.workspaceURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
            var isDirectory: ObjCBool = false
            guard workspace.isFileURL,
                  workspace.path.hasPrefix("/"),
                  FileManager.default.fileExists(
                    atPath: workspace.path,
                    isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw CodexRuntimeError.malformedProtocol(
                    "a Codex child profile workspace is not an existing absolute directory")
            }
            guard profile.knowledgeCapabilities.isSubset(
                    of: allowedKnowledgeCapabilities),
                  profile.sandbox != .readOnly
                    || !profile.knowledgeCapabilities
                        .contains(.buildKnowledge) else {
                throw CodexRuntimeError.malformedProtocol(
                    "a Codex child Knowledge policy exceeds its host-approved workspace access")
            }
            guard !profile.hostedWebSearchEnabled
                    || advertisesHostedWebSearch else {
                throw CodexRuntimeError.malformedProtocol(
                    "a Codex child hosted-search service is not present in the registered dynamic-tool surface")
            }
            providerIDs[name] = childProviderID(roleName: name)
            environmentKeys[name] = childProviderEnvironmentKey(
                roleName: name)
        }
        return (providerIDs, environmentKeys)
    }

    func threadLifecycleParameters(
        includeDynamicTools: Bool = true
    ) -> [String: JSONValue] {
        let hostIdentity = configuration.hostApplicationIdentity
        let rootProviderID = hostIdentity.fileNameStem
        let rootProviderEnvironmentKey = hostIdentity.environmentVariable(
            "CODEX_PROVIDER_TOKEN")
        func providerValue(
            route: ResponsesRuntimeRoute,
            environmentKey: String,
            displayName: String
        ) -> JSONValue {
            var provider: [String: JSONValue] = [
                "name": .string(displayName),
                "base_url": .string(route.baseURL.absoluteString),
                "env_key": .string(environmentKey),
                "wire_api": .string("responses"),
                "requires_openai_auth": .bool(false),
                "supports_websockets": .bool(false),
            ]
            if !route.queryParameters.isEmpty {
                provider["query_params"] = .object(
                    route.queryParameters.mapValues(JSONValue.string))
            }
            if let providerOptions = route.providerOptions {
                provider["intatis_responses_provider"] = .object(
                    providerOptions)
            }
            return .object(provider)
        }
        var modelProviders: [String: JSONValue] = [
            rootProviderID: providerValue(
                route: configuration.route,
                environmentKey: rootProviderEnvironmentKey,
                displayName: hostIdentity.name + " Responses"),
        ]
        var agentRoles: [String: JSONValue] = [:]
        for profile in configuration.childProfiles.sorted(by: {
            $0.roleName < $1.roleName
            }) {
            let providerID = childProviderIDs[profile.roleName]
                ?? childProviderID(roleName: profile.roleName)
            let environmentKey = childProviderEnvironmentKeys[
                profile.roleName]
                ?? childProviderEnvironmentKey(
                    roleName: profile.roleName)
            let configURL = childProfileURLs[profile.roleName]
                ?? storage.childProfileURL(roleName: profile.roleName)
            modelProviders[providerID] = providerValue(
                route: profile.route,
                environmentKey: environmentKey,
                displayName: hostIdentity.name + " " + profile.roleName)
            agentRoles[profile.roleName] = .object([
                "description": .string(profile.description),
                "config_file": .string(configURL.path),
                "nickname_candidates": .array([
                    .string(profile.roleName),
                ]),
            ])
        }
        if configuration.mode == .cowork,
           !configuration.mcpConfiguration.isEmpty {
            let configURL = childProfileURLs["default"]
                ?? storage.defaultChildProfileURL
            agentRoles["default"] = .object([
                "description": .string(
                    "Inherit the parent route and workspace with descendant MCP disabled."),
                "config_file": .string(configURL.path),
            ])
        }
        var features: [String: JSONValue] = [
            // 0.145.0 snapshots the App Server process environment before
            // the tool-level filter, which would persist provider tokens.
            "shell_snapshot": .bool(false),
            // Intatis exposes one Code/Cowork product mode. Supplying the
            // official host callback makes Codex's built-in structured
            // question tool available in that mode; no Plan/Default product
            // selector or replacement dynamic tool is introduced.
            "default_mode_request_user_input": .bool(
                configuration.requestUserInputHandler != nil),
        ]
        if configuration.mode == .cowork {
            let workspacePresets = Dictionary(
                uniqueKeysWithValues: configuration.childProfiles.map { profile in
                    let path = profile.workspaceURL
                        .resolvingSymlinksInPath()
                        .standardizedFileURL.path
                    return (
                        profile.roleName,
                        JSONValue.object([
                            "cwd": .string(path),
                            "workspace_roots": .array([.string(path)]),
                            "description": .string(profile.description),
                            "sandbox": .string(profile.sandbox.rawValue),
                        ]))
                })
            // V2 exposes collaboration as ordinary Responses function tools
            // under the explicit derived `flat_tools` extension. Keep this
            // provider-agnostic exact shape instead of guessing from a URL or
            // translating the tools in an adapter.
            var multiAgentV2: [String: JSONValue] = [
                "enabled": .bool(true),
                "flat_tools": .bool(true),
                "hide_spawn_agent_metadata": .bool(false),
                // Child inference is selected only through host-materialized
                // agent roles. The model cannot improvise a raw model or
                // reasoning override outside the user's approved profiles.
                "expose_spawn_agent_model_overrides": .bool(false),
            ]
            if !workspacePresets.isEmpty {
                multiAgentV2["intatis_agent_workspaces"] = .object(
                    workspacePresets)
            }
            features["multi_agent_v2"] = .object(multiAgentV2)
        }
        var excludedShellEnvironment = ["INTATIS_*"]
        let hostEnvironmentPattern = hostIdentity.environmentPrefix + "_*"
        if hostEnvironmentPattern != "INTATIS_*" {
            excludedShellEnvironment.append(hostEnvironmentPattern)
        }
        excludedShellEnvironment.append("CODEX_HOME")
        var runtimeConfig: [String: JSONValue] = [
            "model": .string(configuration.route.model.rawValue),
            "model_provider": .string(rootProviderID),
            "model_catalog_json": .string(
                storage.modelCatalogURL.path),
            "model_providers": .object(modelProviders),
            "analytics": .object([
                "enabled": .bool(false),
            ]),
            // App Server otherwise defaults to cached hosted search and adds
            // a provider tool even though Intatis did not request or configure
            // one for this route.
            "web_search": .string("disabled"),
            "features": .object(features),
            "shell_environment_policy": .object([
                "inherit": .string("core"),
                "ignore_default_excludes": .bool(false),
                "exclude": .array(
                    excludedShellEnvironment.map(JSONValue.string)),
            ]),
        ]
        if !agentRoles.isEmpty {
            runtimeConfig["agents"] = .object(agentRoles)
        }
        var parameters: [String: JSONValue] = [
            "cwd": .string(configuration.workspaceURL.path),
            "model": .string(configuration.route.model.rawValue),
            "modelProvider": .string(rootProviderID),
            "approvalPolicy": .string("on-request"),
            "approvalsReviewer": .string(
                configuration.approvalReviewer.rawValue),
            "sandbox": .string(
                configuration.rootPermissionProfile == .readOnly
                    ? "read-only"
                    : "workspace-write"),
            "developerInstructions": .string(
                configuration.mode.developerInstructions(
                    hostApplicationIdentity: hostIdentity,
                    nativeCollaborationEnabled:
                        nativeCollaborationEnabled,
                    businessToolsEnabled:
                        configuration.dynamicTools != nil,
                    sessionRenameEnabled:
                        configuration.dynamicTools?.contains(
                            tool: RenameSessionTool.descriptor.name)
                            == true)),
            "baseInstructions": .string(
                configuration.mode.baseInstructions(
                    hostApplicationIdentity: hostIdentity)),
            "ephemeral": .bool(false),
            "config": .object(runtimeConfig),
        ]
        if configuration.mode == .cowork {
            var seen: Set<String> = []
            let roots = ([configuration.workspaceURL]
                + configuration.childProfiles.map(\.workspaceURL))
                .map {
                    $0.resolvingSymlinksInPath()
                        .standardizedFileURL.path
                }
                .filter { seen.insert($0).inserted }
            parameters["runtimeWorkspaceRoots"] = .array(
                roots.map(JSONValue.string))
        }
        if includeDynamicTools,
           let dynamicTools = configuration.dynamicTools {
            parameters["dynamicTools"] = .array(
                dynamicTools.specs.map(\.wireValue))
        }
        return parameters
    }

    private var nativeCollaborationEnabled: Bool {
        configuration.mode == .cowork
    }

    private func launchProcess(executableURL: URL) throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executableURL
        process.arguments = [
            "app-server", "--stdio", "--strict-config",
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = storage.homeURL.path
        environment[configuration.hostApplicationIdentity
            .environmentVariable("CODEX_PROVIDER_TOKEN")] =
            configuration.route.bearerToken
        for profile in configuration.childProfiles.sorted(by: {
            $0.roleName < $1.roleName
        }) {
            let key = childProviderEnvironmentKeys[profile.roleName]
                ?? childProviderEnvironmentKey(
                    roleName: profile.roleName)
            environment[key] = profile.route.bearerToken
        }
        for (key, value) in configuration.mcpConfiguration
            .processEnvironment
        {
            environment[key] = value
        }
        process.environment = environment

        let stdoutStream = Self.byteStream(
            from: output.fileHandleForReading)
        let stderrStream = Self.byteStream(
            from: error.fileHandleForReading)
        process.terminationHandler = { [weak self] terminated in
            Task {
                await self?.processDidTerminate(
                    status: terminated.terminationStatus)
            }
        }
        do {
            try process.run()
        } catch {
            throw CodexRuntimeError.processLaunchFailed(
                error.localizedDescription)
        }
        self.process = process
        self.standardInput = input.fileHandleForWriting
        stdoutTask = Task { [weak self] in
            for await data in stdoutStream {
                guard !Task.isCancelled else { return }
                await self?.consumeStdout(data)
            }
        }
        stderrTask = Task { [weak self] in
            for await data in stderrStream {
                guard !Task.isCancelled else { return }
                await self?.consumeStderr(data)
            }
        }
    }

    private func childProviderID(roleName: String) -> String {
        configuration.hostApplicationIdentity.fieldNameStem
            + "_agent_" + roleName
    }

    private func childProviderEnvironmentKey(
        roleName: String
    ) -> String {
        let digest = ToolRegistry.authorizationDigest(roleName)
            .prefix(20)
            .uppercased()
        return configuration.hostApplicationIdentity.environmentVariable(
            "CODEX_PROVIDER_TOKEN_AGENT_\(digest)")
    }

    private func request(
        method: String,
        params: JSONValue,
        timeoutSeconds: UInt64 = 30
    ) async throws -> JSONValue {
        guard process?.isRunning == true,
              standardInput != nil else {
            throw CodexRuntimeError.notStarted
        }
        let requestID = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(
                    nanoseconds: timeoutSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.timeoutRequest(requestID)
            }
            pendingResponses[requestID] = PendingResponse(
                method: method,
                continuation: continuation,
                timeoutTask: timeoutTask)
            do {
                try writeJSON(.object([
                    "id": .number(Double(requestID)),
                    "method": .string(method),
                    "params": params,
                ]))
            } catch {
                pendingResponses.removeValue(
                    forKey: requestID)?.timeoutTask.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendResponse(
        id: JSONValue,
        result: JSONValue
    ) throws {
        try writeJSON(.object([
            "id": id,
            "result": result,
        ]))
    }

    private func timeoutRequest(_ requestID: Int) {
        guard let pending = pendingResponses.removeValue(
            forKey: requestID) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(
            throwing: CodexRuntimeError.requestTimedOut(
                pending.method))
    }

    private func sendErrorResponse(
        id: JSONValue,
        message: String
    ) throws {
        try writeJSON(.object([
            "id": id,
            "error": .object([
                "code": .number(-32_601),
                "message": .string(message),
            ]),
        ]))
    }

    private func writeJSON(_ value: JSONValue) throws {
        guard let standardInput else {
            throw CodexRuntimeError.notStarted
        }
        var data = try JSONEncoder.intatisCodex.encode(value)
        data.append(0x0A)
        do {
            try standardInput.write(contentsOf: data)
        } catch {
            throw CodexRuntimeError.processLaunchFailed(
                "could not write to App Server: \(error.localizedDescription)")
        }
    }

    private func consumeStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)
        let maximumBufferedBytes = 16 * 1_024 * 1_024
        guard stdoutBuffer.count <= maximumBufferedBytes else {
            failProtocol("one JSON-RPC line exceeded 16 MiB")
            return
        }
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = Data(stdoutBuffer[..<newline])
            stdoutBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                let value = try JSONDecoder().decode(
                    JSONValue.self,
                    from: line)
                try handleIncoming(value)
            } catch {
                failProtocol(error.localizedDescription)
                return
            }
        }
    }

    private func consumeStderr(_ data: Data) {
        guard let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return }
        let redacted = redact(value)
        stderrDiagnostic = CodexRuntimeExecutable.boundedDiagnostic(
            stderrDiagnostic + redacted)
    }

    private func handleIncoming(_ value: JSONValue) throws {
        guard let object = value.objectValue else {
            throw CodexRuntimeError.malformedProtocol(
                "top-level message is not an object")
        }
        if let method = object["method"]?.stringValue {
            if let id = object["id"] {
                try handleServerRequest(
                    id: id,
                    method: method,
                    params: object["params"] ?? .object([:]))
            } else {
                try handleNotification(
                    method: method,
                    params: object["params"] ?? .object([:]))
            }
            return
        }
        guard let idValue = object["id"],
              let requestID = idValue.integralIntValue,
              let pending = pendingResponses.removeValue(
                forKey: requestID) else {
            throw CodexRuntimeError.malformedProtocol(
                "response has no matching request id")
        }
        pending.timeoutTask.cancel()
        if let error = object["error"]?.objectValue {
            let code = error["code"]?.integralIntValue
            let message = redact(
                error["message"]?.stringValue
                    ?? "unknown App Server error")
            pending.continuation.resume(throwing: CodexRuntimeError.serverError(
                code: code,
                message: bounded(message)))
        } else {
            pending.continuation.resume(
                returning: object["result"] ?? .null)
        }
    }

    private func handleServerRequest(
        id: JSONValue,
        method: String,
        params: JSONValue
    ) throws {
        guard let requestID = CodexRuntimeRequestID(wireValue: id),
              let object = params.objectValue else {
            throw CodexRuntimeError.malformedProtocol(
                "server request has an invalid id or params")
        }
        if object["threadId"]?.stringValue == runtimeIdentity?.threadID {
            emitAppServerEvent(method: method, params: params)
        }
        if method == "item/tool/requestUserInput" {
            try beginUserInputRequest(
                id: id,
                requestID: requestID,
                object: object)
            return
        }
        if method == "item/tool/call" {
            try beginDynamicToolCall(
                id: id,
                requestID: requestID,
                object: object)
            return
        }
        guard let requestThreadID = object["threadId"]?.stringValue,
              !requestThreadID.isEmpty else {
            let message = "\(configuration.hostApplicationIdentity.name) rejected a server request without a thread identity."
            try sendErrorResponse(
                id: requestID.wireValue,
                message: message)
            return
        }
        if !isAuthorizedThread(requestThreadID) {
            guard nativeCollaborationEnabled,
                  requestThreadID != runtimeIdentity?.threadID,
                  !hasPendingServerRequest(requestID) else {
                let message = "\(configuration.hostApplicationIdentity.name) rejected a server request from a thread outside the current Cowork tree."
                try sendErrorResponse(id: id, message: message)
                emit(.runtimeError(
                    code: "unrelated_app_server_thread",
                    message: message,
                    fatal: false))
                return
            }
            let task = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.verifyDescendantAndBeginApprovalRequest(
                    id: id,
                    requestID: requestID,
                    method: method,
                    object: object,
                    threadID: requestThreadID)
            }
            pendingApprovalVerifications[requestID] = task
            return
        }
        try beginVerifiedApprovalRequest(
            requestID: requestID,
            method: method,
            object: object,
            requestThreadID: requestThreadID)
    }

    private func beginUserInputRequest(
        id: JSONValue,
        requestID: CodexRuntimeRequestID,
        object: [String: JSONValue]
    ) throws {
        guard !hasPendingServerRequest(requestID) else {
            throw CodexRuntimeError.malformedProtocol(
                "duplicate live server request id")
        }
        guard let threadID = object["threadId"]?.stringValue,
              !threadID.isEmpty else {
            try sendErrorResponse(
                id: id,
                message: "The structured question has no thread identity.")
            return
        }
        if isAuthorizedThread(threadID) {
            try beginVerifiedUserInputRequest(
                requestID: requestID,
                object: object,
                threadID: threadID)
            return
        }
        guard nativeCollaborationEnabled,
              threadID != runtimeIdentity?.threadID else {
            let message = "The structured question came from a thread outside the current \(configuration.hostApplicationIdentity.name) Cowork tree."
            try sendErrorResponse(id: id, message: message)
            emit(.runtimeError(
                code: "unrelated_user_input_thread",
                message: message,
                fatal: false))
            return
        }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.verifyDescendantAndBeginUserInputRequest(
                id: id,
                requestID: requestID,
                object: object,
                threadID: threadID)
        }
        pendingUserInputVerifications[requestID] = task
    }

    private func beginVerifiedUserInputRequest(
        requestID: CodexRuntimeRequestID,
        object: [String: JSONValue],
        threadID: String
    ) throws {
        guard isAuthorizedThread(threadID) else {
            let message = "The structured question came from a thread outside the current \(configuration.hostApplicationIdentity.name) Cowork tree."
            try sendErrorResponse(id: requestID.wireValue, message: message)
            emit(.runtimeError(
                code: "unrelated_user_input_thread",
                message: message,
                fatal: false))
            return
        }
        guard let handler = configuration.requestUserInputHandler else {
            let message = "Structured user questions are not connected to a host presenter for this session."
            try sendErrorResponse(id: requestID.wireValue, message: message)
            emit(.runtimeError(
                code: "request_user_input_unavailable",
                message: message,
                fatal: false))
            return
        }
        let request: CodexRuntimeUserInputRequest
        do {
            request = try userInputRequest(
                requestID: requestID,
                object: object,
                threadID: threadID)
        } catch {
            let message = "Codex supplied an invalid or unsafe structured question."
            try sendErrorResponse(id: requestID.wireValue, message: message)
            emit(.runtimeError(
                code: "invalid_request_user_input",
                message: message,
                fatal: false))
            return
        }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performUserInputRequest(
                requestID: requestID,
                request: request,
                handler: handler)
        }
        pendingUserInputRequests[requestID] = PendingUserInputRequest(
            request: request,
            task: task)
    }

    private func verifyDescendantAndBeginUserInputRequest(
        id: JSONValue,
        requestID: CodexRuntimeRequestID,
        object: [String: JSONValue],
        threadID: String
    ) async {
        do {
            try await verifyAndRegisterDescendantChain(
                endingAt: threadID)
            guard pendingUserInputVerifications.removeValue(
                    forKey: requestID) != nil else { return }
            try beginVerifiedUserInputRequest(
                requestID: requestID,
                object: object,
                threadID: threadID)
        } catch is CancellationError {
            pendingUserInputVerifications.removeValue(forKey: requestID)
            try? sendErrorResponse(
                id: id,
                message: "The descendant identity check was cancelled before structured-question presentation.")
        } catch {
            pendingUserInputVerifications.removeValue(forKey: requestID)
            let message = "The structured-question requester could not be proven to belong to this \(configuration.hostApplicationIdentity.name) Cowork thread."
            try? sendErrorResponse(id: id, message: message)
            emit(.runtimeError(
                code: "unverified_user_input_thread",
                message: message,
                fatal: false))
        }
    }

    private func performUserInputRequest(
        requestID: CodexRuntimeRequestID,
        request: CodexRuntimeUserInputRequest,
        handler: @escaping CodexRuntimeUserInputHandler
    ) async {
        do {
            let response = try await handler(request)
            try Task.checkCancellation()
            try validateUserInputResponse(response, for: request)
            guard let pending = pendingUserInputRequests[requestID],
                  pending.request == request else { return }
            try sendResponse(
                id: requestID.wireValue,
                result: response.wireValue)
            pendingUserInputRequests.removeValue(forKey: requestID)
        } catch is CancellationError {
            pendingUserInputRequests.removeValue(forKey: requestID)
        } catch {
            guard pendingUserInputRequests.removeValue(
                    forKey: requestID) != nil else { return }
            let message = "The structured question could not be completed by the host."
            do {
                try sendErrorResponse(
                    id: requestID.wireValue,
                    message: message)
            } catch {
                failProtocol(error.localizedDescription)
                return
            }
            emit(.runtimeError(
                code: "request_user_input_failed",
                message: message,
                fatal: false))
        }
    }

    private func userInputRequest(
        requestID: CodexRuntimeRequestID,
        object: [String: JSONValue],
        threadID: String
    ) throws -> CodexRuntimeUserInputRequest {
        guard let turnID = object["turnId"]?.stringValue,
              !turnID.isEmpty,
              let itemID = object["itemId"]?.stringValue,
              !itemID.isEmpty,
              let questionValues = object["questions"]?.arrayValue,
              (1...3).contains(questionValues.count) else {
            throw CodexRuntimeError.malformedProtocol(
                "request_user_input is missing its turn, item, or questions")
        }
        let autoResolutionMilliseconds: Int?
        if object["autoResolutionMs"] == nil
            || object["autoResolutionMs"] == .null {
            autoResolutionMilliseconds = nil
        } else {
            guard let value = object["autoResolutionMs"]?.integralIntValue,
                  (60_000...240_000).contains(value) else {
                throw CodexRuntimeError.malformedProtocol(
                    "request_user_input has an invalid auto-resolution window")
            }
            autoResolutionMilliseconds = value
        }

        var questionIDs: Set<String> = []
        let questions = try questionValues.map { value
            -> CodexRuntimeUserInputQuestion in
            guard let question = value.objectValue,
                  let id = question["id"]?.stringValue,
                  Self.isSafeUserInputIdentifier(id),
                  questionIDs.insert(id).inserted,
                  let header = question["header"]?.stringValue,
                  Self.isSafeUserInputText(
                    header,
                    maximumCharacters: 12),
                  let prompt = question["question"]?.stringValue,
                  Self.isSafeUserInputText(
                    prompt,
                    maximumCharacters: 2_048),
                  let optionValues = question["options"]?.arrayValue,
                  (2...3).contains(optionValues.count) else {
                throw CodexRuntimeError.malformedProtocol(
                    "request_user_input contains an invalid question")
            }
            let isOther: Bool
            if case .bool(let value)? = question["isOther"] {
                isOther = value
            } else if question["isOther"] == nil {
                isOther = false
            } else {
                throw CodexRuntimeError.malformedProtocol(
                    "request_user_input contains an invalid Other flag")
            }
            let isSecret: Bool
            if case .bool(let value)? = question["isSecret"] {
                isSecret = value
            } else if question["isSecret"] == nil {
                isSecret = false
            } else {
                throw CodexRuntimeError.malformedProtocol(
                    "request_user_input contains an invalid secret flag")
            }
            guard !isSecret else {
                throw CodexRuntimeError.malformedProtocol(
                    "secret questions are not accepted")
            }
            var labels: Set<String> = []
            let options = try optionValues.map { value
                -> CodexRuntimeUserInputOption in
                guard let option = value.objectValue,
                      let label = option["label"]?.stringValue,
                      Self.isSafeUserInputText(
                        label,
                        maximumCharacters: 128),
                      (1...5).contains(label.split(
                        whereSeparator: { $0.isWhitespace }).count),
                      labels.insert(label).inserted,
                      let description = option["description"]?.stringValue,
                      Self.isSafeUserInputText(
                        description,
                        maximumCharacters: 1_024) else {
                    throw CodexRuntimeError.malformedProtocol(
                        "request_user_input contains an invalid option")
                }
                return CodexRuntimeUserInputOption(
                    label: label,
                    description: description)
            }
            return CodexRuntimeUserInputQuestion(
                id: id,
                header: header,
                question: prompt,
                options: options,
                allowsOther: isOther,
                isSecret: false)
        }
        let agentID = threadID == runtimeIdentity?.threadID
            ? nil
            : descendantThreads[threadID]?.agentID
        return CodexRuntimeUserInputRequest(
            requestID: requestID,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            agentID: agentID,
            questions: questions,
            autoResolutionMilliseconds: autoResolutionMilliseconds)
    }

    private func validateUserInputResponse(
        _ response: CodexRuntimeUserInputResponse,
        for request: CodexRuntimeUserInputRequest
    ) throws {
        let questionsByID = Dictionary(
            uniqueKeysWithValues: request.questions.map { ($0.id, $0) })
        guard Set(response.answers.keys) == Set(questionsByID.keys) else {
            throw CodexRuntimeError.malformedProtocol(
                "the user-input response does not answer the exact questions")
        }
        for (id, answers) in response.answers {
            guard let question = questionsByID[id],
                  answers.count == 1,
                  let answer = answers.first,
                  Self.isSafeUserInputText(
                    answer,
                    maximumCharacters: 4_096) else {
                throw CodexRuntimeError.malformedProtocol(
                    "the user-input response contains an invalid answer")
            }
            let labels = Set(question.options.map(\.label))
            guard labels.contains(answer) || question.allowsOther else {
                throw CodexRuntimeError.malformedProtocol(
                    "the user-input response is not one of the offered options")
            }
        }
    }

    private static func isSafeUserInputIdentifier(
        _ value: String
    ) -> Bool {
        guard !value.isEmpty,
              value.count <= 64,
              let first = value.unicodeScalars.first,
              (97...122).contains(first.value),
              value.unicodeScalars.allSatisfy({ scalar in
                  (97...122).contains(scalar.value)
                    || (48...57).contains(scalar.value)
                    || scalar.value == 95
              }) else {
            return false
        }
        return true
    }

    private static func isSafeUserInputText(
        _ value: String,
        maximumCharacters: Int
    ) -> Bool {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == value,
              value.count <= maximumCharacters,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              !SecretScanner.containsSecret(value) else {
            return false
        }
        return true
    }

    private func hasPendingServerRequest(
        _ requestID: CodexRuntimeRequestID
    ) -> Bool {
        pendingApprovals[requestID] != nil
            || pendingDynamicToolCalls[requestID] != nil
            || pendingUserInputRequests[requestID] != nil
            || pendingDescendantVerifications[requestID] != nil
            || pendingApprovalVerifications[requestID] != nil
            || pendingUserInputVerifications[requestID] != nil
    }

    private func handleResolvedServerRequest(
        _ requestID: CodexRuntimeRequestID
    ) {
        if pendingApprovals.removeValue(forKey: requestID) != nil {
            emit(.approvalResolved(requestID))
        }
        pendingUserInputRequests.removeValue(
            forKey: requestID)?.task.cancel()
        pendingUserInputVerifications.removeValue(
            forKey: requestID)?.cancel()
    }

    private func beginVerifiedApprovalRequest(
        requestID: CodexRuntimeRequestID,
        method: String,
        object: [String: JSONValue],
        requestThreadID: String
    ) throws {
        guard isAuthorizedThread(requestThreadID) else {
            let message = "\(configuration.hostApplicationIdentity.name) rejected a server request from a thread outside the current Cowork tree."
            try sendErrorResponse(id: requestID.wireValue, message: message)
            emit(.runtimeError(
                code: "unrelated_app_server_thread",
                message: message,
                fatal: false))
            return
        }
        if method == "currentTime/read" {
            let seconds = floor(Date().timeIntervalSince1970)
            try sendResponse(
                id: requestID.wireValue,
                result: .object([
                    "currentTimeAt": .number(seconds),
                ]))
            return
        }
        let kind: CodexRuntimeApprovalKind
        let title: String
        let summary: String
        let requestedPermissions: JSONValue?
        switch method {
        case "item/commandExecution/requestApproval":
            kind = .command
            title = "Codex command"
            summary = object["reason"]?.stringValue
                ?? object["command"]?.stringValue
                ?? "Codex requests permission to run a command."
            requestedPermissions = nil
        case "item/fileChange/requestApproval":
            kind = .fileChange
            title = "Codex file change"
            summary = object["reason"]?.stringValue
                ?? "Codex requests permission to modify workspace files."
            requestedPermissions = nil
        case "item/permissions/requestApproval":
            kind = .permissions
            title = "Codex permissions"
            summary = object["reason"]?.stringValue
                ?? "Codex requests additional runtime permissions."
            requestedPermissions = object["permissions"]
        default:
            let message =
                "\(configuration.hostApplicationIdentity.name) does not expose the App Server interaction '\(method)' in this first runtime version."
            try sendErrorResponse(
                id: requestID.wireValue,
                message: message)
            emit(.runtimeError(
                code: "unsupported_app_server_request",
                message: message,
                fatal: false))
            return
        }
        let request = CodexRuntimeApprovalRequest(
            requestID: requestID,
            kind: kind,
            threadID: requestThreadID,
            turnID: object["turnId"]?.stringValue ?? "",
            itemID: object["itemId"]?.stringValue ?? "",
            title: title,
            summary: bounded(redact(summary), limit: 8_192),
            requestedPermissions: requestedPermissions)
        guard !hasPendingServerRequest(requestID) else {
            throw CodexRuntimeError.malformedProtocol(
                "duplicate live server request id")
        }
        pendingApprovals[requestID] = request
        emit(.approvalRequested(request))
    }

    private func verifyDescendantAndBeginApprovalRequest(
        id: JSONValue,
        requestID: CodexRuntimeRequestID,
        method: String,
        object: [String: JSONValue],
        threadID: String
    ) async {
        do {
            try await verifyAndRegisterDescendantChain(
                endingAt: threadID)
            guard pendingApprovalVerifications.removeValue(
                    forKey: requestID) != nil else { return }
            try beginVerifiedApprovalRequest(
                requestID: requestID,
                method: method,
                object: object,
                requestThreadID: threadID)
        } catch is CancellationError {
            pendingApprovalVerifications.removeValue(forKey: requestID)
            try? sendErrorResponse(
                id: id,
                message: "The descendant identity check was cancelled before approval presentation.")
        } catch {
            pendingApprovalVerifications.removeValue(forKey: requestID)
            let message = "The approval requester could not be proven to belong to this \(configuration.hostApplicationIdentity.name) Cowork thread."
            try? sendErrorResponse(id: id, message: message)
            emit(.runtimeError(
                code: "unverified_approval_thread",
                message: message,
                fatal: false))
        }
    }

    private func isAuthorizedThread(_ threadID: String) -> Bool {
        threadID == runtimeIdentity?.threadID
            || descendantThreads[threadID] != nil
    }

    private func beginDynamicToolCall(
        id: JSONValue,
        requestID: CodexRuntimeRequestID,
        object: [String: JSONValue]
    ) throws {
        guard !hasPendingServerRequest(requestID) else {
            throw CodexRuntimeError.malformedProtocol(
                "duplicate live server request id")
        }
        guard let dynamicTools = configuration.dynamicTools else {
            try sendDynamicToolFailure(
                id: id,
                message: "\(configuration.hostApplicationIdentity.name) did not register client-executed tools for this thread.")
            return
        }
        if let namespace = object["namespace"],
           namespace != .null {
            try sendDynamicToolFailure(
                id: id,
                message: "\(configuration.hostApplicationIdentity.name) registers first-party business tools as flat App Server functions, not namespaces.")
            return
        }
        guard let threadID = object["threadId"]?.stringValue,
              let turnID = object["turnId"]?.stringValue,
              let callID = object["callId"]?.stringValue,
              let tool = object["tool"]?.stringValue,
              let arguments = object["arguments"],
              !threadID.isEmpty,
              !turnID.isEmpty,
              !callID.isEmpty,
              !tool.isEmpty else {
            try sendDynamicToolFailure(
                id: id,
                message: "The App Server dynamic-tool request is missing its thread, turn, call, tool, or arguments field.")
            return
        }
        let actingAgentID: AgentID?
        let toolWorkspaceURL: URL
        let toolWorkspaceAccess: WorkspaceAccess
        let toolPermissionProfile: PermissionProfile
        let toolKnowledgeCapabilities: Set<ToolCapability>
        let toolHostedWebSearchScope:
            CodexRuntimeHostedWebSearchScope?
        let executionLease = CodexRuntimeDynamicToolExecutionLease()
        if threadID == runtimeIdentity?.threadID {
            actingAgentID = nil
            toolWorkspaceURL = configuration.workspaceURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
            toolWorkspaceAccess = configuration.rootPermissionProfile
                == .readOnly ? .readOnly : .readWrite
            toolPermissionProfile = configuration.rootPermissionProfile
            toolKnowledgeCapabilities = []
            toolHostedWebSearchScope = configuration
                .rootHostedWebSearchEnabled ? .root : nil
        } else if let descendant = descendantThreads[threadID] {
            actingAgentID = descendant.agentID
            guard let policy = descendantExecutionPolicy(
                for: descendant) else {
                try sendDynamicToolFailure(
                    id: id,
                    message: "The Codex subagent workspace or inherited permission binding does not match its verified parent chain.")
                return
            }
            toolWorkspaceURL = policy.workspaceURL
            toolWorkspaceAccess = policy.workspaceAccess
            toolPermissionProfile = policy.permissionProfile
            toolKnowledgeCapabilities = policy.knowledgeCapabilities
            toolHostedWebSearchScope = policy.hostedWebSearchScope
        } else {
            guard nativeCollaborationEnabled else {
                try sendDynamicToolFailure(
                    id: id,
                    message: "The dynamic-tool caller is not a verified descendant of this \(configuration.hostApplicationIdentity.name) Cowork thread.")
                return
            }
            let task = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.verifyDescendantAndBeginDynamicToolCall(
                    id: id,
                    requestID: requestID,
                    object: object,
                    threadID: threadID)
            }
            pendingDescendantVerifications[requestID] = task
            return
        }
        guard dynamicTools.contains(tool: tool) else {
            try sendDynamicToolFailure(
                id: id,
                message: "Unknown registered business tool: \(bounded(redact(tool), limit: 128)).")
            return
        }

        let call = CodexRuntimeDynamicToolCall(
            threadID: threadID,
            turnID: turnID,
            callID: callID,
            tool: tool,
            arguments: arguments,
            agentID: actingAgentID,
            workspaceURL: toolWorkspaceURL,
            workspaceAccess: toolWorkspaceAccess,
            permissionProfile: toolPermissionProfile,
            knowledgeCapabilities: toolKnowledgeCapabilities,
            hostedWebSearchScope: toolHostedWebSearchScope,
            executionLease: executionLease)
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performDynamicToolCall(
                requestID: requestID,
                call: call)
        }
        pendingDynamicToolCalls[requestID] = PendingDynamicToolCall(
            threadID: threadID,
            turnID: turnID,
            callID: callID,
            executionLease: executionLease,
            task: task)
    }

    /// A newly spawned child can issue its first App Server dynamic-tool
    /// request before the client has observed a roster notification. Prove
    /// the complete parent chain through the official `thread/read` API, then
    /// re-enter the normal exact-thread authorization path. No display name,
    /// role text, or model-authored identifier can establish this authority.
    private func verifyDescendantAndBeginDynamicToolCall(
        id: JSONValue,
        requestID: CodexRuntimeRequestID,
        object: [String: JSONValue],
        threadID: String
    ) async {
        do {
            try await verifyAndRegisterDescendantChain(
                endingAt: threadID)
            guard pendingDescendantVerifications.removeValue(
                    forKey: requestID) != nil,
                  descendantThreads[threadID] != nil else {
                return
            }
            try beginDynamicToolCall(
                id: id,
                requestID: requestID,
                object: object)
        } catch is CancellationError {
            pendingDescendantVerifications.removeValue(forKey: requestID)
            try? sendDynamicToolFailure(
                id: id,
                message: "The descendant identity check was cancelled before tool execution.")
        } catch {
            pendingDescendantVerifications.removeValue(forKey: requestID)
            let message = "The dynamic-tool caller could not be proven to belong to this \(configuration.hostApplicationIdentity.name) Cowork thread."
            try? sendDynamicToolFailure(id: id, message: message)
            emit(.runtimeError(
                code: "unverified_dynamic_tool_thread",
                message: message,
                fatal: false))
        }
    }

    private func verifyAndRegisterDescendantChain(
        endingAt threadID: String
    ) async throws {
        guard nativeCollaborationEnabled,
              let rootThreadID = runtimeIdentity?.threadID,
              threadID != rootThreadID else {
            throw CodexRuntimeError.malformedProtocol(
                "descendant verification requires a non-root Cowork thread")
        }
        var currentThreadID = threadID
        var visited: Set<String> = []
        var unregistered: [CodexRuntimeThreadDescriptor] = []
        while currentThreadID != rootThreadID,
              descendantThreads[currentThreadID] == nil {
            try Task.checkCancellation()
            guard visited.insert(currentThreadID).inserted else {
                throw CodexRuntimeError.malformedProtocol(
                    "thread/read returned a cyclic descendant chain")
            }
            let result = try await request(
                method: "thread/read",
                params: .object([
                    "threadId": .string(currentThreadID),
                    "includeTurns": .bool(false),
                ]))
            guard let thread = result.objectValue?["thread"]?.objectValue,
                  thread["id"]?.stringValue == currentThreadID,
                  let descriptor = threadDescriptor(
                    from: thread,
                    rootThreadID: rootThreadID),
                  descriptor.threadID == currentThreadID,
                  descriptor.sessionID == rootThreadID,
                  descriptor.parentThreadID != descriptor.threadID else {
                throw CodexRuntimeError.malformedProtocol(
                    "thread/read did not return a valid Cowork descendant")
            }
            unregistered.append(descriptor)
            currentThreadID = descriptor.parentThreadID
        }
        guard currentThreadID == rootThreadID
                || descendantThreads[currentThreadID] != nil else {
            throw CodexRuntimeError.malformedProtocol(
                "thread/read descendant chain does not reach this Cowork root")
        }
        for descriptor in unregistered.reversed() {
            registerDescendant(descriptor)
        }
        guard descendantThreads[threadID] != nil else {
            throw CodexRuntimeError.malformedProtocol(
                "verified descendant was not admitted to the current Cowork tree")
        }
    }

    private func descendantExecutionPolicy(
        for descendant: CodexRuntimeThreadDescriptor
    ) -> DescendantExecutionPolicy? {
        guard let rootThreadID = runtimeIdentity?.threadID else { return nil }
        var current = descendant
        var visited: Set<String> = []
        while true {
            guard visited.insert(current.threadID).inserted else { return nil }
            let policy: DescendantExecutionPolicy
            if let role = current.agentRole {
                guard let profile = configuration.childProfiles.first(where: {
                    $0.roleName == role
                }) else {
                    // An explicit role that was not materialized by this host
                    // is not equivalent to inheritance.
                    return nil
                }
                let workspace = profile.workspaceURL
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                policy = DescendantExecutionPolicy(
                    workspaceURL: workspace,
                    workspaceAccess: profile.sandbox == .readOnly
                        ? .readOnly
                        : .readWrite,
                    permissionProfile: profile.permissionProfile,
                    knowledgeCapabilities:
                        profile.knowledgeCapabilities,
                    hostedWebSearchScope:
                        profile.hostedWebSearchEnabled
                            ? .childRole(profile.roleName)
                            : nil)
            } else if current.parentThreadID == rootThreadID {
                let workspace = configuration.workspaceURL
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                policy = DescendantExecutionPolicy(
                    workspaceURL: workspace,
                    workspaceAccess:
                        configuration.rootPermissionProfile == .readOnly
                            ? .readOnly
                            : .readWrite,
                    permissionProfile: configuration.rootPermissionProfile,
                    knowledgeCapabilities: configuration
                        .inheritedChildKnowledgeCapabilities,
                    hostedWebSearchScope: configuration
                        .rootHostedWebSearchEnabled ? .root : nil)
            } else {
                guard let parent = descendantThreads[
                    current.parentThreadID] else { return nil }
                current = parent
                continue
            }

            guard !descendant.cwd.isEmpty else { return nil }
            let canonicalActual = URL(fileURLWithPath: descendant.cwd)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard canonicalActual.path == policy.workspaceURL.path else {
                return nil
            }
            return policy
        }
    }

    private func performDynamicToolCall(
        requestID: CodexRuntimeRequestID,
        call: CodexRuntimeDynamicToolCall
    ) async {
        guard let dynamicTools = configuration.dynamicTools else { return }
        let result = await dynamicTools.execute(call)
        guard let pending = pendingDynamicToolCalls[requestID],
              pending.threadID == call.threadID,
              pending.turnID == call.turnID,
              pending.callID == call.callID else {
            return
        }
        pendingDynamicToolCalls.removeValue(forKey: requestID)
        do {
            try sendResponse(
                id: requestID.wireValue,
                result: result.wireValue)
        } catch {
            failProtocol(error.localizedDescription)
            return
        }
        if result.shouldInterruptTurn {
            Task { [weak self] in
                try? await self?.interruptTurn(
                    threadID: call.threadID,
                    turnID: call.turnID)
            }
        }
    }

    private func invalidatePendingDynamicToolCalls(
        for threadID: String
    ) {
        for pending in pendingDynamicToolCalls.values
            where pending.threadID == threadID {
            pending.executionLease.invalidate()
        }
    }

    private func cancelPendingUserInputRequests(
        for threadID: String
    ) {
        let requestIDs = pendingUserInputRequests.compactMap {
            requestID, pending in
            pending.request.threadID == threadID ? requestID : nil
        }
        for requestID in requestIDs {
            guard let pending = pendingUserInputRequests.removeValue(
                    forKey: requestID) else { continue }
            pending.task.cancel()
            try? sendErrorResponse(
                id: requestID.wireValue,
                message: "The structured-question caller changed identity before the user answered.")
        }
    }

    private func sendDynamicToolFailure(
        id: JSONValue,
        message: String
    ) throws {
        try sendResponse(
            id: id,
            result: CodexRuntimeDynamicToolResult.text(
                bounded(redact(message), limit: 8_192),
                success: false).wireValue)
    }

    private func handleNotification(
        method: String,
        params: JSONValue
    ) throws {
        let object = params.objectValue ?? [:]
        if method == "thread/started" {
            registerDescendantThreadIfAuthorized(object["thread"])
        }
        if let threadID = Self.notificationThreadID(
            method: method,
           object: object),
           let rootThreadID = runtimeIdentity?.threadID
                ?? pendingRootThreadID,
           threadID != rootThreadID {
            guard descendantThreads[threadID] != nil else {
                try bufferUnverifiedChildNotification(
                    method: method,
                    params: params,
                    threadID: threadID)
                return
            }
            try handleChildNotification(
                method: method,
                params: params,
                object: object,
                threadID: threadID)
            return
        }
        emitAppServerEvent(method: method, params: params)
        switch method {
        case "turn/started":
            if let turnID = object["turn"]?.objectValue?["id"]?.stringValue {
                activeTurnID = turnID
                pendingResponsesUsage = nil
                emitTurnStartedIfNeeded(turnID)
            }
        case "item/agentMessage/delta":
            guard let itemID = object["itemId"]?.stringValue,
                  let text = object["delta"]?.stringValue else { return }
            emit(.assistantDelta(
                itemID: itemID,
                text: redact(text),
                phase: assistantMessagePhases[itemID]))
        case "item/reasoning/summaryTextDelta",
             "item/reasoning/textDelta":
            guard let itemID = object["itemId"]?.stringValue,
                  let text = object["delta"]?.stringValue else { return }
            emit(.reasoningDelta(
                itemID: itemID,
                text: redact(text)))
        case "item/started":
            if let item = object["item"] {
                updateDescendantsFromCollaborationItem(item)
            }
            if let itemObject = object["item"]?.objectValue,
               itemObject["type"]?.stringValue == "agentMessage",
               let itemID = itemObject["id"]?.stringValue {
                if let phase = Self.messagePhase(
                    itemObject["phase"]?.stringValue) {
                    assistantMessagePhases[itemID] = phase
                }
            } else if let item = object["item"],
                      let parsed = runtimeItem(from: item) {
                emit(.itemStarted(parsed))
            }
        case "item/completed":
            guard let item = object["item"] else { return }
            updateDescendantsFromCollaborationItem(item)
            if let itemObject = item.objectValue,
               itemObject["type"]?.stringValue == "agentMessage",
               let itemID = itemObject["id"]?.stringValue,
               let text = itemObject["text"]?.stringValue {
                let phase = Self.messagePhase(
                    itemObject["phase"]?.stringValue)
                    ?? assistantMessagePhases[itemID]
                assistantMessagePhases.removeValue(forKey: itemID)
                emit(.assistantCompleted(
                    itemID: itemID,
                    text: redact(text),
                    phase: phase))
                if let turnID = object["turnId"]?.stringValue
                    ?? activeTurnID {
                    switch phase {
                    case .finalAnswer:
                        finalAnswerItemIDByTurnID[turnID] = itemID
                    case nil:
                        fallbackAnswerItemIDByTurnID[turnID] = itemID
                    case .commentary:
                        break
                    }
                }
            } else if let parsed = runtimeItem(from: item) {
                emit(.itemCompleted(parsed))
            }
        case "thread/tokenUsage/updated":
            try recordResponsesUsage(object)
        case "thread/goal/updated":
            guard let rootThreadID = runtimeIdentity?.threadID
                    ?? pendingRootThreadID else { return }
            emit(.goalUpdated(try goalSnapshot(
                from: object["goal"],
                expectedThreadID: rootThreadID)))
        case "thread/goal/cleared":
            emit(.goalUpdated(nil))
        case "turn/completed":
            guard let turn = object["turn"]?.objectValue,
                  let turnID = turn["id"]?.stringValue,
                  let status = turn["status"]?.stringValue else { return }
            let durationMs = try optionalNonnegativeInt(
                turn["durationMs"],
                field: "turn/completed turn.durationMs")
            let message = turn["error"]?.objectValue?["message"]?
                .stringValue.map { bounded(redact($0)) }
            emitResponsesUsageIfPresent(
                turnID: turnID,
                durationMs: durationMs)
            completeTurn(CodexRuntimeTurnResult(
                turnID: turnID,
                status: status,
                errorMessage: message))
        case "serverRequest/resolved":
            guard let idValue = object["requestId"],
                  let requestID = CodexRuntimeRequestID(
                    wireValue: idValue) else { return }
            handleResolvedServerRequest(requestID)
        case "error":
            let error = object["error"]?.objectValue
            let message = error?["message"]?.stringValue
                ?? "Codex Runtime reported an unknown error."
            guard case .bool(let willRetry)? = object["willRetry"] else {
                throw CodexRuntimeError.malformedProtocol(
                    "App Server error notification is missing willRetry")
            }
            if !willRetry {
                emit(.runtimeError(
                    code: "codex_runtime",
                    message: safeDiagnostic(message, limit: 1_024),
                    fatal: false))
            }
        case "model/rerouted":
            let fromModel = object["fromModel"]?.stringValue ?? ""
            let toModel = object["toModel"]?.stringValue ?? ""
            let reason = object["reason"]?.stringValue ?? "unknown"
            guard !fromModel.isEmpty, !toModel.isEmpty else {
                throw CodexRuntimeError.malformedProtocol(
                    "model/rerouted is missing its exact model identity")
            }
            throw CodexRuntimeError.malformedProtocol(
                "The exact model route changed from \(safeIdentity(fromModel)) to \(safeIdentity(toModel)) (\(safeIdentity(reason))). \(configuration.hostApplicationIdentity.name) does not accept implicit model rerouting.")
        default:
            break
        }
    }

    private func bufferUnverifiedChildNotification(
        method: String,
        params: JSONValue,
        threadID: String
    ) throws {
        let existingCount = bufferedChildNotifications.values.reduce(0) {
            $0 + $1.count
        }
        guard bufferedChildNotifications.count < 32
                || bufferedChildNotifications[threadID] != nil,
              bufferedChildNotifications[threadID, default: []].count < 256,
              existingCount < 4_096 else {
            throw CodexRuntimeError.malformedProtocol(
                "unverified child notification buffer exceeded its structural bound")
        }
        bufferedChildNotifications[threadID, default: []].append(
            BufferedChildNotification(
                method: method,
                params: params))
        // App Server can replay descendant notifications before a persisted
        // root resume has returned. Keep them bounded until that exact root is
        // confirmed instead of racing ancestry reads against the handshake.
        guard runtimeIdentity != nil else { return }
        startChildNotificationVerificationIfNeeded(threadID: threadID)
    }

    private func startChildNotificationVerificationIfNeeded(
        threadID: String
    ) {
        guard pendingChildNotificationVerifications[threadID] == nil else {
            return
        }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.verifyAndReplayChildNotifications(
                threadID: threadID)
        }
        pendingChildNotificationVerifications[threadID] = task
    }

    private func replayBufferedChildNotificationsAfterResume() throws {
        for threadID in bufferedChildNotifications.keys.sorted() {
            guard descendantThreads[threadID] != nil else {
                startChildNotificationVerificationIfNeeded(
                    threadID: threadID)
                continue
            }
            let buffered = bufferedChildNotifications.removeValue(
                forKey: threadID) ?? []
            for notification in buffered {
                try handleChildNotification(
                    method: notification.method,
                    params: notification.params,
                    object: notification.params.objectValue ?? [:],
                    threadID: threadID)
            }
        }
    }

    private func verifyAndReplayChildNotifications(
        threadID: String
    ) async {
        do {
            try await verifyAndRegisterDescendantChain(
                endingAt: threadID)
            guard pendingChildNotificationVerifications.removeValue(
                    forKey: threadID) != nil else { return }
            let buffered = bufferedChildNotifications.removeValue(
                forKey: threadID) ?? []
            for notification in buffered {
                try Task.checkCancellation()
                try handleChildNotification(
                    method: notification.method,
                    params: notification.params,
                    object: notification.params.objectValue ?? [:],
                    threadID: threadID)
            }
        } catch is CancellationError {
            pendingChildNotificationVerifications.removeValue(
                forKey: threadID)
            bufferedChildNotifications.removeValue(forKey: threadID)
        } catch {
            pendingChildNotificationVerifications.removeValue(
                forKey: threadID)
            bufferedChildNotifications.removeValue(forKey: threadID)
            emit(.runtimeError(
                code: "unverified_child_notification_thread",
                message: "A child event was discarded because its thread could not be proven to belong to this Cowork root.",
                fatal: false))
        }
    }

    private func handleChildNotification(
        method: String,
        params: JSONValue,
        object: [String: JSONValue],
        threadID: String
    ) throws {
        let turnID = object["turnId"]?.stringValue
            ?? object["turn"]?.objectValue?["id"]?.stringValue
            ?? childActiveTurnIDs[threadID]
        if let payload = appServerEventPayload(
            method: method,
            params: params,
            fallbackTurnID: turnID) {
            var childPayload = payload
            childPayload.agent = descendantThreads[threadID]?.agentID
            emit(.child(.appServerEvent(
                threadID: threadID,
                payload: childPayload)))
        }

        switch method {
        case "error":
            guard case .bool(_)? = object["willRetry"],
                  object["error"]?.objectValue?["message"]?.stringValue != nil else {
                throw CodexRuntimeError.malformedProtocol(
                    "child App Server error notification is malformed")
            }
        case "model/rerouted":
            let fromModel = object["fromModel"]?.stringValue ?? ""
            let toModel = object["toModel"]?.stringValue ?? ""
            let reason = object["reason"]?.stringValue ?? "unknown"
            guard !fromModel.isEmpty, !toModel.isEmpty else {
                throw CodexRuntimeError.malformedProtocol(
                    "child model/rerouted is missing its exact model identity")
            }
            throw CodexRuntimeError.malformedProtocol(
                "A Codex child model route changed from \(safeIdentity(fromModel)) to \(safeIdentity(toModel)) (\(safeIdentity(reason))). \(configuration.hostApplicationIdentity.name) does not accept implicit model rerouting.")
        case "thread/status/changed":
            updateDescendantStatus(
                threadID: threadID,
                value: object["status"])
        case "thread/archived":
            updateDescendantArchived(
                threadID: threadID,
                isArchived: true)
        case "thread/unarchived":
            updateDescendantArchived(
                threadID: threadID,
                isArchived: false)
        case "thread/closed", "thread/deleted":
            updateDescendantStatus(
                threadID: threadID,
                value: .object(["type": .string("shutdown")]))
        case "turn/started":
            guard let turnID = object["turn"]?.objectValue?["id"]?
                .stringValue else { return }
            childActiveTurnIDs[threadID] = turnID
            emit(.child(.turnStarted(
                threadID: threadID,
                turnID: turnID)))
        case "item/agentMessage/delta":
            guard let itemID = object["itemId"]?.stringValue,
                  let text = object["delta"]?.stringValue else { return }
            let key = ThreadItemKey(
                threadID: threadID,
                itemID: itemID)
            emit(.child(.assistantDelta(
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                text: redact(text),
                phase: childAssistantMessagePhases[key])))
        case "item/reasoning/summaryTextDelta",
             "item/reasoning/textDelta":
            guard let itemID = object["itemId"]?.stringValue,
                  let text = object["delta"]?.stringValue else { return }
            emit(.child(.reasoningDelta(
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                text: redact(text))))
        case "item/started":
            guard let value = object["item"],
                  let item = value.objectValue,
                  let itemID = item["id"]?.stringValue else { return }
            updateDescendantsFromCollaborationItem(value)
            if item["type"]?.stringValue == "agentMessage" {
                if let phase = Self.messagePhase(
                    item["phase"]?.stringValue) {
                    childAssistantMessagePhases[ThreadItemKey(
                        threadID: threadID,
                        itemID: itemID)] = phase
                }
            } else if let parsed = runtimeItem(from: value) {
                emit(.child(.itemStarted(
                    threadID: threadID,
                    turnID: turnID,
                    item: parsed)))
            }
        case "item/completed":
            guard let value = object["item"],
                  let item = value.objectValue,
                  let itemID = item["id"]?.stringValue,
                  let type = item["type"]?.stringValue else { return }
            updateDescendantsFromCollaborationItem(value)
            switch type {
            case "agentMessage":
                guard let text = item["text"]?.stringValue else { return }
                let key = ThreadItemKey(
                    threadID: threadID,
                    itemID: itemID)
                let phase = Self.messagePhase(item["phase"]?.stringValue)
                    ?? childAssistantMessagePhases.removeValue(forKey: key)
                emit(.child(.assistantCompleted(
                    threadID: threadID,
                    turnID: turnID,
                    itemID: itemID,
                    text: redact(text),
                    phase: phase)))
                if let turnID {
                    let turnKey = ThreadTurnKey(
                        threadID: threadID,
                        turnID: turnID)
                    switch phase {
                    case .finalAnswer:
                        childFinalAnswerItemIDs[turnKey] = itemID
                    case nil:
                        childFallbackAnswerItemIDs[turnKey] = itemID
                    case .commentary:
                        break
                    }
                }
            case "userMessage":
                emit(.child(.userMessage(
                    threadID: threadID,
                    turnID: turnID,
                    itemID: itemID,
                    text: userMessageText(
                        item["content"]?.arrayValue ?? []))))
            default:
                if let parsed = runtimeItem(from: value) {
                    emit(.child(.itemCompleted(
                        threadID: threadID,
                        turnID: turnID,
                        item: parsed)))
                }
            }
        case "thread/tokenUsage/updated":
            let usage = try responsesUsageBreakdown(from: object)
            childPendingResponsesUsage[ThreadTurnKey(
                threadID: threadID,
                turnID: usage.turnID)] = usage.usage
        case "turn/completed":
            guard let turn = object["turn"]?.objectValue,
                  let completedTurnID = turn["id"]?.stringValue,
                  let status = turn["status"]?.stringValue else { return }
            let durationMs = try optionalNonnegativeInt(
                turn["durationMs"],
                field: "turn/completed turn.durationMs")
            emitChildResponsesUsageIfPresent(
                threadID: threadID,
                turnID: completedTurnID,
                durationMs: durationMs)
            if childActiveTurnIDs[threadID] == completedTurnID {
                childActiveTurnIDs.removeValue(forKey: threadID)
            }
            let completedUserInputIDs = pendingUserInputRequests.compactMap {
                requestID, pending in
                pending.request.threadID == threadID
                    && pending.request.turnID == completedTurnID
                    ? requestID
                    : nil
            }
            for requestID in completedUserInputIDs {
                pendingUserInputRequests.removeValue(
                    forKey: requestID)?.task.cancel()
            }
            childAssistantMessagePhases = childAssistantMessagePhases.filter {
                $0.key.threadID != threadID
            }
            let message = turn["error"]?.objectValue?["message"]?
                .stringValue.map { bounded(redact($0)) }
            emit(.child(.turnCompleted(
                threadID: threadID,
                result: CodexRuntimeTurnResult(
                    turnID: completedTurnID,
                    status: status,
                    errorMessage: message))))
            if let role = descendantThreads[threadID]?.agentRole,
               configuration.childProfiles.contains(where: {
                   $0.roleName == role
               }) {
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        _ = try await self.refreshDescendantMetadata(
                            threadID: threadID,
                            refreshMetadata: true)
                    } catch {
                        await self.reportDescendantMetadataRefreshFailure()
                    }
                }
            }
        case "serverRequest/resolved":
            guard let idValue = object["requestId"],
                  let requestID = CodexRuntimeRequestID(
                    wireValue: idValue) else { return }
            handleResolvedServerRequest(requestID)
        default:
            break
        }
    }

    private func registerDescendantThreadIfAuthorized(
        _ value: JSONValue?
    ) {
        guard nativeCollaborationEnabled,
              let rootThreadID = runtimeIdentity?.threadID,
              let thread = value?.objectValue,
              let threadID = thread["id"]?.stringValue,
              let parentThreadID = thread["parentThreadId"]?.stringValue,
              !threadID.isEmpty,
              !parentThreadID.isEmpty,
              threadID != rootThreadID,
              parentThreadID == rootThreadID
                || descendantThreads[parentThreadID] != nil else {
            return
        }
        registerDescendant(
            threadDescriptor(
                from: thread,
                rootThreadID: rootThreadID))
    }

    private func reportDescendantMetadataRefreshFailure() {
        emit(.runtimeError(
            code: "codex_descendant_metadata",
            message: "Codex Runtime could not refresh one verified child profile after its turn completed.",
            fatal: false))
    }

    private func refreshDescendantThreads() async throws {
        guard nativeCollaborationEnabled,
              let rootThreadID = runtimeIdentity?.threadID else {
            return
        }
        var candidates: [String: CodexRuntimeThreadDescriptor] = [:]
        for archived in [false, true] {
            var cursor: String?
            repeat {
                var params: [String: JSONValue] = [
                    "ancestorThreadId": .string(rootThreadID),
                    "archived": .bool(archived),
                    "limit": .number(100),
                    "sourceKinds": .array([
                        .string("subAgent"),
                        .string("subAgentReview"),
                        .string("subAgentCompact"),
                        .string("subAgentThreadSpawn"),
                        .string("subAgentOther"),
                        .string("unknown"),
                    ]),
                ]
                if let cursor {
                    params["cursor"] = .string(cursor)
                }
                let result = try await request(
                    method: "thread/list",
                    params: .object(params))
                guard let object = result.objectValue,
                      let data = object["data"]?.arrayValue else {
                    throw CodexRuntimeError.malformedProtocol(
                        "thread/list descendants response is missing data")
                }
                for value in data {
                    guard let thread = value.objectValue,
                          let descriptor = threadDescriptor(
                            from: thread,
                            rootThreadID: rootThreadID,
                            isArchived: archived) else {
                        throw CodexRuntimeError.malformedProtocol(
                            "thread/list returned a malformed descendant thread")
                    }
                    guard candidates[descriptor.threadID] == nil else {
                        throw CodexRuntimeError.malformedProtocol(
                            "thread/list returned a duplicate descendant thread")
                    }
                    candidates[descriptor.threadID] = descriptor
                }
                if case .string(let next)? = object["nextCursor"],
                   !next.isEmpty {
                    cursor = next
                } else if object["nextCursor"] == nil
                            || object["nextCursor"] == .null {
                    cursor = nil
                } else {
                    throw CodexRuntimeError.malformedProtocol(
                        "thread/list returned an invalid nextCursor")
                }
            } while cursor != nil
        }

        var remaining = candidates
        var madeProgress = true
        while !remaining.isEmpty, madeProgress {
            madeProgress = false
            for descriptor in remaining.values.sorted(by: {
                let lhsCreated = $0.createdAt ?? Int.max
                let rhsCreated = $1.createdAt ?? Int.max
                if lhsCreated != rhsCreated {
                    return lhsCreated < rhsCreated
                }
                return $0.threadID < $1.threadID
            }) {
                guard descriptor.parentThreadID == rootThreadID
                        || descendantThreads[descriptor.parentThreadID] != nil else {
                    continue
                }
                registerDescendant(descriptor)
                remaining.removeValue(forKey: descriptor.threadID)
                madeProgress = true
            }
        }
        guard remaining.isEmpty else {
            throw CodexRuntimeError.malformedProtocol(
                "thread/list descendants contain an unverified parent chain")
        }
        for threadID in descendantThreads.values
            .filter({ !$0.isArchived })
            .sorted(by: {
                let lhsCreated = $0.createdAt ?? Int.max
                let rhsCreated = $1.createdAt ?? Int.max
                if lhsCreated != rhsCreated {
                    return lhsCreated < rhsCreated
                }
                return $0.threadID < $1.threadID
            })
            .map(\.threadID) {
            _ = try await refreshDescendantMetadata(
                threadID: threadID,
                refreshMetadata: true)
        }
    }

    private func registerDescendant(
        _ descriptor: CodexRuntimeThreadDescriptor?
    ) {
        guard nativeCollaborationEnabled,
              let descriptor,
              let rootThreadID = runtimeIdentity?.threadID,
              descriptor.threadID != rootThreadID,
              descriptor.sessionID == rootThreadID,
              descriptor.parentThreadID == rootThreadID
                || descendantThreads[descriptor.parentThreadID] != nil else {
            return
        }
        let previous = descendantThreads[descriptor.threadID]
        let merged = mergeThreadDescriptor(
            previous: previous,
            incoming: descriptor)
        guard previous != merged else { return }
        if let previous,
           previous.parentThreadID != merged.parentThreadID
            || previous.agentRole != merged.agentRole
            || previous.cwd != merged.cwd
            || previous.isArchived != merged.isArchived
            || (previous.status != "shutdown"
                && merged.status == "shutdown") {
            invalidatePendingDynamicToolCalls(
                for: merged.threadID)
            cancelPendingUserInputRequests(
                for: merged.threadID)
        }
        descendantThreads[merged.threadID] = merged
        emit(.child(.threadUpdated(merged)))
    }

    private func mergeThreadDescriptor(
        previous: CodexRuntimeThreadDescriptor?,
        incoming: CodexRuntimeThreadDescriptor
    ) -> CodexRuntimeThreadDescriptor {
        guard let previous else { return incoming }
        return CodexRuntimeThreadDescriptor(
            threadID: incoming.threadID,
            parentThreadID: incoming.parentThreadID,
            sessionID: incoming.sessionID,
            agentNickname: incoming.agentNickname
                ?? previous.agentNickname,
            agentRole: incoming.agentRole ?? previous.agentRole,
            agentPath: incoming.agentPath ?? previous.agentPath,
            name: incoming.name ?? previous.name,
            preview: incoming.preview.isEmpty
                ? previous.preview
                : incoming.preview,
            cwd: incoming.cwd.isEmpty ? previous.cwd : incoming.cwd,
            modelProvider: incoming.modelProvider.isEmpty
                ? previous.modelProvider
                : incoming.modelProvider,
            requestedModel: incoming.requestedModel
                ?? previous.requestedModel,
            reasoningEffort: incoming.reasoningEffort
                ?? previous.reasoningEffort,
            serviceTier: incoming.serviceTier
                ?? previous.serviceTier,
            runtimeWorkspaceRoots: incoming.runtimeWorkspaceRoots.isEmpty
                ? previous.runtimeWorkspaceRoots
                : incoming.runtimeWorkspaceRoots,
            isArchived: incoming.isArchived,
            status: incoming.status,
            activeFlags: incoming.activeFlags,
            canAcceptDirectInput: incoming.canAcceptDirectInput
                ?? previous.canAcceptDirectInput,
            createdAt: incoming.createdAt ?? previous.createdAt)
    }

    private func threadDescriptor(
        from thread: [String: JSONValue],
        rootThreadID: String,
        isArchived: Bool = false
    ) -> CodexRuntimeThreadDescriptor? {
        guard let threadID = thread["id"]?.stringValue,
              let parentThreadID = thread["parentThreadId"]?.stringValue,
              !threadID.isEmpty,
              !parentThreadID.isEmpty else {
            return nil
        }
        let statusObject = thread["status"]?.objectValue
        let status = statusObject?["type"]?.stringValue
            ?? thread["status"]?.stringValue
            ?? "notLoaded"
        let flags = statusObject?["activeFlags"]?.arrayValue?
            .compactMap(\.stringValue) ?? []
        let canAcceptDirectInput: Bool?
        if case .bool(let value)? = thread["canAcceptDirectInput"] {
            canAcceptDirectInput = value
        } else {
            canAcceptDirectInput = nil
        }
        let threadSpawn = thread["source"]?.objectValue?["subAgent"]?
            .objectValue?["thread_spawn"]?.objectValue
        let agentPath = thread["agentPath"]?.stringValue
            ?? threadSpawn?["agent_path"]?.stringValue
        return CodexRuntimeThreadDescriptor(
            threadID: bounded(threadID, limit: 512),
            parentThreadID: bounded(parentThreadID, limit: 512),
            // App Server's `sessionId` is the descendant's own rollout
            // session, not the Cowork tree root. Membership is established by
            // the relationship-filtered list or the fully verified parent
            // chain, so the host projection binds that proven root here.
            sessionID: bounded(rootThreadID, limit: 512),
            agentNickname: thread["agentNickname"]?.stringValue.map {
                bounded(redact($0), limit: 128)
            },
            agentRole: thread["agentRole"]?.stringValue.map {
                bounded(redact($0), limit: 128)
            } ?? threadSpawn?["agent_role"]?.stringValue.map {
                bounded(redact($0), limit: 128)
            },
            agentPath: agentPath.map {
                bounded(redact($0), limit: 512)
            },
            name: thread["name"]?.stringValue.map {
                bounded(redact($0), limit: 256)
            },
            preview: bounded(
                redact(thread["preview"]?.stringValue ?? ""),
                limit: 2_048),
            cwd: bounded(
                redact(thread["cwd"]?.stringValue ?? ""),
                limit: 4_096),
            modelProvider: bounded(
                redact(thread["modelProvider"]?.stringValue ?? ""),
                limit: 256),
            isArchived: isArchived,
            status: bounded(status, limit: 128),
            activeFlags: flags.map { bounded($0, limit: 128) },
            canAcceptDirectInput: canAcceptDirectInput,
            createdAt: thread["createdAt"]?.integralIntValue)
    }

    private func updateDescendantsFromCollaborationItem(
        _ value: JSONValue
    ) {
        guard let rootThreadID = runtimeIdentity?.threadID,
              let object = value.objectValue,
              object["type"]?.stringValue == "collabAgentToolCall" else {
            return
        }
        let model = object["model"]?.stringValue.map {
            bounded(redact($0), limit: 256)
        }
        let effort = object["reasoningEffort"]?.stringValue.map {
            bounded(redact($0), limit: 128)
        }
        let states = object["agentsStates"]?.objectValue ?? [:]
        let receiverThreadIDs = object["receiverThreadIds"]?.arrayValue?
            .compactMap(\.stringValue) ?? []
        if receiverThreadIDs.contains(where: {
            descendantThreads[$0] == nil
        }) {
            needsDescendantRefresh = true
        }
        for threadID in receiverThreadIDs {
            guard let previous = descendantThreads[threadID] else { continue }
            let state = states[threadID]?.objectValue
            let status = state?["status"]?.stringValue
                ?? previous.status
            registerDescendant(CodexRuntimeThreadDescriptor(
                threadID: previous.threadID,
                parentThreadID: previous.parentThreadID,
                sessionID: rootThreadID,
                agentNickname: previous.agentNickname,
                agentRole: previous.agentRole,
                agentPath: previous.agentPath,
                name: previous.name,
                preview: previous.preview,
                cwd: previous.cwd,
                modelProvider: previous.modelProvider,
                requestedModel: model ?? previous.requestedModel,
                reasoningEffort: effort ?? previous.reasoningEffort,
                serviceTier: previous.serviceTier,
                runtimeWorkspaceRoots: previous.runtimeWorkspaceRoots,
                isArchived: previous.isArchived,
                status: bounded(status, limit: 128),
                activeFlags: previous.activeFlags,
                canAcceptDirectInput: previous.canAcceptDirectInput,
                createdAt: previous.createdAt))
        }
    }

    private func updateDescendantStatus(
        threadID: String,
        value: JSONValue?
    ) {
        guard let previous = descendantThreads[threadID] else { return }
        let object = value?.objectValue
        let status = object?["type"]?.stringValue
            ?? value?.stringValue
            ?? previous.status
        let flags = object?["activeFlags"]?.arrayValue?
            .compactMap(\.stringValue) ?? []
        registerDescendant(CodexRuntimeThreadDescriptor(
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
            status: bounded(status, limit: 128),
            activeFlags: flags.map { bounded($0, limit: 128) },
            canAcceptDirectInput: previous.canAcceptDirectInput,
            createdAt: previous.createdAt))
    }

    private func updateDescendantArchived(
        threadID: String,
        isArchived: Bool
    ) {
        guard let previous = descendantThreads[threadID] else { return }
        registerDescendant(CodexRuntimeThreadDescriptor(
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
            isArchived: isArchived,
            status: isArchived ? "shutdown" : previous.status,
            activeFlags: isArchived ? [] : previous.activeFlags,
            canAcceptDirectInput: isArchived
                ? false
                : previous.canAcceptDirectInput,
            createdAt: previous.createdAt))
    }

    private static func notificationThreadID(
        method: String,
        object: [String: JSONValue]
    ) -> String? {
        if let threadID = object["threadId"]?.stringValue {
            return threadID
        }
        if method.hasPrefix("thread/"),
           let threadID = object["thread"]?.objectValue?["id"]?
            .stringValue {
            return threadID
        }
        return nil
    }

    private func recordResponsesUsage(
        _ object: [String: JSONValue]
    ) throws {
        let parsed = try responsesUsageBreakdown(from: object)
        guard let rootThreadID = runtimeIdentity?.threadID
                ?? pendingRootThreadID,
              rootThreadID == parsed.threadID else {
            throw CodexRuntimeError.malformedProtocol(
                "thread/tokenUsage/updated reported a different thread id")
        }
        // App Server can replay persisted thread usage during resume. It is
        // still emitted as an app-server event, but only a notification for
        // this session's exact active turn may be attached to a new reply.
        guard activeTurnID == parsed.turnID else { return }
        pendingResponsesUsage = (
            turnID: parsed.turnID,
            usage: parsed.usage)
    }

    private func responsesUsageBreakdown(
        from object: [String: JSONValue]
    ) throws -> (
        threadID: String,
        turnID: String,
        usage: ResponsesUsageBreakdown
    ) {
        guard let threadID = object["threadId"]?.stringValue,
              !threadID.isEmpty,
              let turnID = object["turnId"]?.stringValue,
              !turnID.isEmpty,
              let tokenUsage = object["tokenUsage"]?.objectValue,
              let last = tokenUsage["last"]?.objectValue else {
            throw CodexRuntimeError.malformedProtocol(
                "thread/tokenUsage/updated is missing threadId, turnId, "
                    + "tokenUsage, or tokenUsage.last")
        }
        return (
            threadID: threadID,
            turnID: turnID,
            usage: ResponsesUsageBreakdown(
                inputTokens: try requiredNonnegativeInt(
                    last,
                    field: "inputTokens"),
                cachedInputTokens: try requiredNonnegativeInt(
                    last,
                    field: "cachedInputTokens"),
                cacheWriteInputTokens: try requiredNonnegativeInt(
                    last,
                    field: "cacheWriteInputTokens"),
                outputTokens: try requiredNonnegativeInt(
                    last,
                    field: "outputTokens"),
                reasoningOutputTokens: try requiredNonnegativeInt(
                    last,
                    field: "reasoningOutputTokens"),
                totalTokens: try requiredNonnegativeInt(
                    last,
                    field: "totalTokens")))
    }

    private func requiredNonnegativeInt(
        _ object: [String: JSONValue],
        field: String
    ) throws -> Int {
        guard let value = object[field]?.integralIntValue,
              value >= 0 else {
            throw CodexRuntimeError.malformedProtocol(
                "thread/tokenUsage/updated tokenUsage.last.\(field) "
                    + "is not a nonnegative integer")
        }
        return value
    }

    private func optionalNonnegativeInt(
        _ value: JSONValue?,
        field: String
    ) throws -> Int? {
        guard let value else { return nil }
        if case .null = value { return nil }
        guard let result = value.integralIntValue,
              result >= 0 else {
            throw CodexRuntimeError.malformedProtocol(
                "\(field) is not a nonnegative integer or null")
        }
        return result
    }

    private func emitResponsesUsageIfPresent(
        turnID: String,
        durationMs: Int?
    ) {
        guard let pendingResponsesUsage,
              pendingResponsesUsage.turnID == turnID else {
            finalAnswerItemIDByTurnID.removeValue(forKey: turnID)
            fallbackAnswerItemIDByTurnID.removeValue(forKey: turnID)
            return
        }
        self.pendingResponsesUsage = nil
        let usage = pendingResponsesUsage.usage
        let responseMessageItemID = finalAnswerItemIDByTurnID.removeValue(
            forKey: turnID)
            ?? fallbackAnswerItemIDByTurnID.removeValue(forKey: turnID)
        fallbackAnswerItemIDByTurnID.removeValue(forKey: turnID)
        emit(.responsesUsage(CodexRuntimeResponsesUsage(
            turnID: turnID,
            responseMessageItemID: responseMessageItemID,
            inputTokens: usage.inputTokens,
            cachedInputTokens: usage.cachedInputTokens,
            cacheWriteInputTokens: usage.cacheWriteInputTokens,
            outputTokens: usage.outputTokens,
            reasoningOutputTokens: usage.reasoningOutputTokens,
            totalTokens: usage.totalTokens,
            durationMs: durationMs)))
    }

    private func emitChildResponsesUsageIfPresent(
        threadID: String,
        turnID: String,
        durationMs: Int?
    ) {
        let key = ThreadTurnKey(
            threadID: threadID,
            turnID: turnID)
        guard let usage = childPendingResponsesUsage.removeValue(
            forKey: key) else {
            childFinalAnswerItemIDs.removeValue(forKey: key)
            childFallbackAnswerItemIDs.removeValue(forKey: key)
            return
        }
        let responseMessageItemID = childFinalAnswerItemIDs.removeValue(
            forKey: key)
            ?? childFallbackAnswerItemIDs.removeValue(forKey: key)
        childFallbackAnswerItemIDs.removeValue(forKey: key)
        emit(.child(.responsesUsage(
            threadID: threadID,
            usage: CodexRuntimeResponsesUsage(
                turnID: turnID,
                responseMessageItemID: responseMessageItemID,
                inputTokens: usage.inputTokens,
                cachedInputTokens: usage.cachedInputTokens,
                cacheWriteInputTokens: usage.cacheWriteInputTokens,
                outputTokens: usage.outputTokens,
                reasoningOutputTokens: usage.reasoningOutputTokens,
                totalTokens: usage.totalTokens,
                durationMs: durationMs))))
    }

    /// Emits only the bounded scalar presentation fields from official App
    /// Server notifications associated with the active turn. Full payloads,
    /// command output, arguments, paths, and transport details never enter
    /// this stream or EventLog.
    private func emitAppServerEvent(
        method: String,
        params: JSONValue
    ) {
        guard let payload = appServerEventPayload(
            method: method,
            params: params,
            fallbackTurnID: activeTurnID) else {
            return
        }
        emit(.appServerEvent(payload))
    }

    private func appServerEventPayload(
        method: String,
        params: JSONValue,
        fallbackTurnID: String?
    ) -> CodexAppServerEventPayload? {
        guard method != "item/agentMessage/delta" else {
            return nil
        }
        let object = params.objectValue ?? [:]
        let item = object["item"]?.objectValue
        let turn = object["turn"]?.objectValue
        let run = object["run"]?.objectValue
        let itemID = object["itemId"]?.stringValue
            ?? item?["id"]?.stringValue
            ?? object["targetItemId"]?.stringValue
            ?? object["reviewId"]?.stringValue
            ?? run?["id"]?.stringValue
        let responseID = object["responseId"]?.stringValue
        let threadID = object["threadId"]?.stringValue
            ?? object["thread"]?.objectValue?["id"]?.stringValue
        let turnID = object["turnId"]?.stringValue
            ?? turn?["id"]?.stringValue
            ?? ((method == "warning" || method == "guardianWarning")
                ? fallbackTurnID
                : nil)
        // Preserve a bounded method-only projection even for official
        // session-level notifications that carry no thread or turn identity.
        // The semantic reducer decides whether they belong in the default
        // transcript; the backend trace must not silently lose them.
        let itemType = item?["type"]?.stringValue
            ?? (method.hasPrefix("item/autoApprovalReview/")
                ? "approvalReview"
                : nil)
        let directStatus = item?["status"]?.stringValue
            ?? turn?["status"]?.stringValue
            ?? object["status"]?.stringValue
            ?? object["status"]?.objectValue?["type"]?.stringValue
            ?? run?["status"]?.stringValue
            ?? (method == "item/autoApprovalReview/started"
                ? "inProgress"
                : method == "item/autoApprovalReview/completed"
                    ? "completed"
                    : nil)
        let status: String?
        if let directStatus {
            status = directStatus
        } else if method == "mcpServer/oauthLogin/completed",
                  case .bool(let success)? = object["success"] {
            status = success ? "completed" : "failed"
        } else if method == "model/safetyBuffering/updated",
                  case .bool(let buffering)? = object["showBufferingUi"] {
            status = buffering ? "inProgress" : "completed"
        } else if method == "turn/plan/updated" {
            let planStatuses = object["plan"]?.arrayValue?.compactMap {
                $0.objectValue?["status"]?.stringValue
            } ?? []
            if planStatuses.contains("inProgress") {
                status = "inProgress"
            } else if !planStatuses.isEmpty,
                      planStatuses.allSatisfy({ $0 == "completed" }) {
                status = "completed"
            } else {
                status = planStatuses.isEmpty ? nil : "pending"
            }
        } else {
            status = nil
        }
        let phase = Self.messagePhase(item?["phase"]?.stringValue)
        let textDelta: String?
        switch method {
        case "item/reasoning/summaryTextDelta",
             "item/reasoning/textDelta",
             "item/plan/delta":
            textDelta = object["delta"]?.stringValue.map {
                bounded(redact($0), limit: 65_536)
            }
        default:
            textDelta = nil
        }

        let error = object["error"]?.objectValue
        let message: String?
        let details: String?
        switch method {
        case "error":
            message = error?["message"]?.stringValue.map {
                safeDiagnostic($0, limit: 1_024)
            }
            details = error?["additionalDetails"]?.stringValue.map {
                safeDiagnostic($0, limit: 2_048)
            }
        case "warning", "guardianWarning",
             "item/mcpToolCall/progress":
            message = object["message"]?.stringValue.map {
                safeDiagnostic($0, limit: 1_024)
            }
            details = nil
        case "deprecationNotice", "configWarning":
            message = object["summary"]?.stringValue.map {
                safeDiagnostic($0, limit: 1_024)
            }
            details = object["details"]?.stringValue.map {
                safeDiagnostic($0, limit: 2_048)
            }
        case "mcpServer/startupStatus/updated",
             "mcpServer/oauthLogin/completed":
            message = object["name"]?.stringValue.map {
                safeDiagnostic($0, limit: 512)
            }
            details = (object["error"]?.stringValue
                ?? object["failureReason"]?.stringValue).map {
                    safeDiagnostic($0, limit: 1_024)
                }
        case "turn/plan/updated":
            message = object["explanation"]?.stringValue.map {
                safeDiagnostic($0, limit: 2_048)
            }
            details = nil
        case "model/safetyBuffering/updated":
            let reasons = object["reasons"]?.arrayValue?
                .compactMap(\.stringValue)
                .prefix(8)
                .joined(separator: ", ") ?? ""
            message = reasons.isEmpty
                ? nil
                : safeDiagnostic(reasons, limit: 1_024)
            details = nil
        case "hook/started", "hook/completed":
            message = run?["statusMessage"]?.stringValue.map {
                safeDiagnostic($0, limit: 1_024)
            }
            details = nil
        default:
            message = nil
            details = nil
        }
        let willRetry: Bool?
        if method == "error",
           case .bool(let value)? = object["willRetry"] {
            willRetry = value
        } else {
            willRetry = nil
        }
        let fromModel = method == "model/rerouted"
            ? object["fromModel"]?.stringValue.map(safeIdentity)
            : nil
        let toModel = method == "model/rerouted"
            ? object["toModel"]?.stringValue.map(safeIdentity)
            : nil
        let reason = method == "model/rerouted"
            ? object["reason"]?.stringValue.map(safeIdentity)
            : nil

        let identity = itemID ?? responseID ?? turnID ?? threadID ?? "session"
        return CodexAppServerEventPayload(
            eventID: bounded(
                "codex-app-server:\(method):\(identity)",
                limit: 1_024),
            method: bounded(method, limit: 256),
            threadID: threadID.map { bounded($0, limit: 512) },
            turnID: turnID.map { bounded($0, limit: 512) },
            itemID: itemID.map { bounded($0, limit: 512) },
            itemType: itemType.map { bounded($0, limit: 256) },
            status: status.map { bounded($0, limit: 256) },
            phase: phase,
            textDelta: textDelta,
            message: message,
            details: details,
            willRetry: willRetry,
            fromModel: fromModel,
            toModel: toModel,
            reason: reason)
    }

    private func safeDiagnostic(_ value: String, limit: Int) -> String {
        PermissionReviewTextSanitizer.sanitizeDiagnostic(
            redact(value),
            maxCharacters: limit).text
    }

    private func safeIdentity(_ value: String) -> String {
        PermissionReviewTextSanitizer.sanitize(
            value,
            maxCharacters: 256).text
    }

    private static func messagePhase(_ rawValue: String?) -> MessagePhase? {
        rawValue.flatMap(MessagePhase.init(rawValue:))
    }

    private func runtimeItem(from value: JSONValue) -> CodexRuntimeItem? {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue,
              let type = object["type"]?.stringValue else {
            return nil
        }
        let status = object["status"]?.stringValue
        let failure = status == "failed" || status == "declined"
        switch type {
        case "commandExecution":
            return CodexRuntimeItem(
                id: id,
                kind: .command,
                title: "command",
                detail: "",
                status: status,
                isFailure: failure)
        case "fileChange":
            let files = Self.fileChangePaths(
                from: object["changes"])
            return CodexRuntimeItem(
                id: id,
                kind: .fileChange,
                title: "file changes",
                detail: files.isEmpty
                    ? ""
                    : "\(files.count) file change(s)",
                status: status,
                isFailure: failure)
        case "mcpToolCall":
            let server = object["server"]?.stringValue ?? "MCP"
            let tool = object["tool"]?.stringValue ?? "tool"
            return CodexRuntimeItem(
                id: id,
                kind: .mcpTool,
                title: "\(server) · \(tool)",
                status: status,
                isFailure: failure)
        case "dynamicToolCall":
            return CodexRuntimeItem(
                id: id,
                kind: .dynamicTool,
                title: object["tool"]?.stringValue ?? "tool",
                status: status,
                isFailure: failure)
        case "collabAgentToolCall", "collabToolCall":
            let related = object["receiverThreadIds"]?.arrayValue?
                .compactMap(\.stringValue) ?? []
            return CodexRuntimeItem(
                id: id,
                kind: .collaboration,
                title: object["tool"]?.stringValue ?? "collaboration",
                detail: "",
                status: status,
                isFailure: failure,
                relatedThreadIDs: related)
        case "subAgentActivity":
            let threadID = object["agentThreadId"]?.stringValue
            return CodexRuntimeItem(
                id: id,
                kind: .subagent,
                title: object["kind"]?.stringValue ?? "subagent",
                detail: "",
                status: nil,
                relatedThreadIDs: threadID.map { [$0] } ?? [])
        case "webSearch":
            return CodexRuntimeItem(
                id: id,
                kind: .webSearch,
                title: "web search",
                detail: "",
                status: status,
                isFailure: failure)
        case "imageGeneration", "imageView":
            return CodexRuntimeItem(
                id: id,
                kind: .image,
                title: "image",
                detail: "",
                status: status,
                isFailure: failure)
        case "plan":
            return CodexRuntimeItem(
                id: id,
                kind: .plan,
                title: "plan",
                detail: "",
                status: status,
                isFailure: failure)
        case "reasoning":
            return CodexRuntimeItem(
                id: id,
                kind: .reasoning,
                title: "reasoning",
                status: status,
                isFailure: failure)
        case "userMessage", "agentMessage":
            return nil
        default:
            return CodexRuntimeItem(
                id: id,
                kind: .other,
                title: type,
                status: status,
                isFailure: failure)
        }
    }

    private func threadHistory(
        from thread: [String: JSONValue]
    ) throws -> CodexRuntimeThreadHistory {
        guard let threadID = thread["id"]?.stringValue,
              isAuthorizedThread(threadID),
              let turns = thread["turns"]?.arrayValue else {
            throw CodexRuntimeError.malformedProtocol(
                "thread/read returned a malformed or unauthorized history")
        }
        var result: [CodexRuntimeTranscriptItem] = []
        var seenItemIDs: Set<String> = []
        for turnValue in turns {
            guard let turn = turnValue.objectValue,
                  let turnID = turn["id"]?.stringValue,
                  !turnID.isEmpty,
                  let items = turn["items"]?.arrayValue else {
                throw CodexRuntimeError.malformedProtocol(
                    "thread/read returned a malformed turn")
            }
            for value in items {
                guard let object = value.objectValue,
                      let itemID = object["id"]?.stringValue,
                      !itemID.isEmpty,
                      let type = object["type"]?.stringValue,
                      seenItemIDs.insert(itemID).inserted else {
                    throw CodexRuntimeError.malformedProtocol(
                        "thread/read returned a malformed or duplicate item")
                }
                switch type {
                case "userMessage":
                    let text = userMessageText(
                        object["content"]?.arrayValue ?? [])
                    result.append(.user(
                        id: itemID,
                        turnID: turnID,
                        text: text))
                case "agentMessage":
                    guard let text = object["text"]?.stringValue else {
                        throw CodexRuntimeError.malformedProtocol(
                            "thread/read agentMessage is missing text")
                    }
                    result.append(.assistant(
                        id: itemID,
                        turnID: turnID,
                        text: redact(text),
                        phase: Self.messagePhase(
                            object["phase"]?.stringValue),
                        complete: true))
                default:
                    if let item = runtimeItem(from: value) {
                        result.append(.runtime(
                            turnID: turnID,
                            item: item))
                    }
                }
            }
        }
        return CodexRuntimeThreadHistory(
            threadID: threadID,
            items: result)
    }

    private func goalSnapshot(
        from value: JSONValue?,
        expectedThreadID: String
    ) throws -> CodexRuntimeGoalSnapshot {
        guard let object = value?.objectValue,
              object["threadId"]?.stringValue == expectedThreadID,
              let objective = object["objective"]?.stringValue,
              let status = object["status"]?.stringValue,
              [
                  "active", "paused", "blocked", "usageLimited",
                  "budgetLimited", "complete",
              ].contains(status),
              let tokensUsed = object["tokensUsed"]?.integralIntValue,
              tokensUsed >= 0,
              let timeUsedSeconds = object["timeUsedSeconds"]?
                .integralIntValue,
              timeUsedSeconds >= 0,
              let createdAt = object["createdAt"]?.integralIntValue,
              let updatedAt = object["updatedAt"]?.integralIntValue else {
            throw CodexRuntimeError.malformedProtocol(
                "Codex thread Goal is missing required fields")
        }
        let tokenBudget: Int?
        if object["tokenBudget"] == nil
            || object["tokenBudget"] == .null {
            tokenBudget = nil
        } else if let value = object["tokenBudget"]?.integralIntValue,
                  value > 0 {
            tokenBudget = value
        } else {
            throw CodexRuntimeError.malformedProtocol(
                "Codex thread Goal has an invalid token budget")
        }
        return CodexRuntimeGoalSnapshot(
            threadID: expectedThreadID,
            objective: bounded(redact(objective), limit: 32_768),
            status: status,
            tokenBudget: tokenBudget,
            tokensUsed: tokensUsed,
            timeUsedSeconds: timeUsedSeconds,
            createdAt: createdAt,
            updatedAt: updatedAt)
    }

    private func userMessageText(_ content: [JSONValue]) -> String {
        var parts: [String] = []
        var attachmentCount = 0
        for value in content {
            guard let object = value.objectValue else { continue }
            switch object["type"]?.stringValue {
            case "text":
                if let text = object["text"]?.stringValue,
                   !text.isEmpty {
                    parts.append(redact(text))
                }
            case "image", "localImage", "audio", "localAudio", "skill":
                attachmentCount += 1
            default:
                continue
            }
        }
        if attachmentCount > 0 {
            parts.append("[\(attachmentCount) attachment(s)]")
        }
        return parts.joined(separator: "\n")
    }

    private func completeTurn(_ result: CodexRuntimeTurnResult) {
        if activeTurnID == result.turnID {
            activeTurnID = nil
        }
        for pending in pendingDynamicToolCalls.values
            where pending.turnID == result.turnID {
            pending.task.cancel()
        }
        let completedUserInputIDs = pendingUserInputRequests.compactMap {
            requestID, pending in
            pending.request.threadID == runtimeIdentity?.threadID
                && pending.request.turnID == result.turnID
                ? requestID
                : nil
        }
        for requestID in completedUserInputIDs {
            pendingUserInputRequests.removeValue(
                forKey: requestID)?.task.cancel()
        }
        assistantMessagePhases.removeAll(keepingCapacity: true)
        let clearedApprovalIDs = pendingApprovals.compactMap {
            requestID, request in
            request.turnID == result.turnID ? requestID : nil
        }
        for requestID in clearedApprovalIDs {
            pendingApprovals.removeValue(forKey: requestID)
            emit(.approvalResolved(requestID))
        }
        terminalTurns[result.turnID] = result
        terminalTurnOrder.append(result.turnID)
        while terminalTurnOrder.count > 8 {
            let removed = terminalTurnOrder.removeFirst()
            terminalTurns.removeValue(forKey: removed)
        }
        emit(.turnCompleted(result))
        let waiters = turnWaiters.removeValue(forKey: result.turnID) ?? []
        for waiter in waiters {
            do {
                waiter.resume(returning: try Self.validated(result))
            } catch {
                waiter.resume(throwing: error)
            }
        }
    }

    private static func validated(
        _ result: CodexRuntimeTurnResult
    ) throws -> CodexRuntimeTurnResult {
        guard result.succeeded else {
            throw CodexRuntimeError.turnFailed(
                result.errorMessage ?? result.status)
        }
        return result
    }

    private func emitTurnStartedIfNeeded(_ turnID: String) {
        guard emittedTurnStarts.insert(turnID).inserted else { return }
        emit(.turnStarted(turnID))
    }

    private func emit(_ event: CodexRuntimeEvent) {
        var dropped = false
        for continuation in eventContinuations.values {
            if case .dropped = continuation.yield(event) {
                dropped = true
            }
        }
        guard dropped, !isFailingEventBuffer else { return }
        isFailingEventBuffer = true
        let error = CodexRuntimeError.malformedProtocol(
            "the App Server event consumer exceeded its 4096-event buffer")
        for continuation in eventContinuations.values {
            _ = continuation.yield(.runtimeError(
                code: "codex_event_backpressure",
                message: error.localizedDescription,
                fatal: true))
            continuation.finish()
        }
        eventContinuations.removeAll()
        Task {
            await self.stopProcess(after: error)
            self.finishEventStreams()
        }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func finishEventStreams() {
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll()
    }

    private func processDidTerminate(status: Int32) {
        guard process != nil else { return }
        // `stopProcess` retains both the Process object and the session flock
        // until it has observed an actual exit. Its polling path owns cleanup
        // while this flag is set, so the termination callback must not release
        // the lock early or emit a second terminal error.
        guard !isStoppingProcess else { return }
        let error = CodexRuntimeError.processTerminated(
            status,
            bounded(redact(stderrDiagnostic), limit: 2_048))
        terminalSessionError = error
        process = nil
        standardInput = nil
        runtimeIdentity = nil
        pendingRootThreadID = nil
        clearChildPresentationState()
        processLease?.release()
        processLease = nil
        stdoutTask?.cancel()
        stderrTask?.cancel()
        stdoutTask = nil
        stderrTask = nil
        let responses = pendingResponses.values
        pendingResponses.removeAll()
        for pending in responses {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: error)
        }
        let waiters = turnWaiters.values.flatMap { $0 }
        turnWaiters.removeAll()
        for continuation in waiters {
            continuation.resume(throwing: error)
        }
        let approvalIDs = Array(pendingApprovals.keys)
        pendingApprovals.removeAll()
        for requestID in approvalIDs {
            emit(.approvalResolved(requestID))
        }
        cancelPendingDynamicToolCalls()
        activeTurnID = nil
        clearTurnPresentationState()
        if !isShuttingDown {
            emit(.runtimeError(
                code: "codex_runtime_exited",
                message: error.localizedDescription,
                fatal: true))
            finishEventStreams()
        }
    }

    private func stopProcess(after error: Error?) async {
        // Actor reentrancy allows shutdown to arrive while a protocol-failure
        // stop is sleeping. The first stop remains authoritative and retains
        // the process lease until exit; later calls only need their caller to
        // finish its own UI/event lifecycle.
        guard !isStoppingProcess else { return }
        isStoppingProcess = true
        let terminationError: CodexRuntimeError
        if let codexError = error as? CodexRuntimeError {
            terminationError = codexError
        } else if let error {
            terminationError = .processLaunchFailed(
                safeDiagnostic(error.localizedDescription, limit: 1_024))
        } else {
            terminationError = .notStarted
        }
        terminalSessionError = terminationError
        let responses = pendingResponses.values
        pendingResponses.removeAll()
        for pending in responses {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: terminationError)
        }
        let waiters = turnWaiters.values.flatMap { $0 }
        turnWaiters.removeAll()
        for continuation in waiters {
            continuation.resume(throwing: terminationError)
        }
        let approvalIDs = Array(pendingApprovals.keys)
        pendingApprovals.removeAll()
        for requestID in approvalIDs {
            emit(.approvalResolved(requestID))
        }
        cancelPendingDynamicToolCalls()
        activeTurnID = nil
        clearTurnPresentationState()
        runtimeIdentity = nil
        pendingRootThreadID = nil
        clearChildPresentationState()
        stdoutTask?.cancel()
        stderrTask?.cancel()
        stdoutTask = nil
        stderrTask = nil
        try? standardInput?.close()
        standardInput = nil
        let runningProcess = process
        if let runningProcess, runningProcess.isRunning {
            runningProcess.terminate()
            var exited = await waitForProcessExit(runningProcess)
            if !exited {
                Self.forceTerminate(runningProcess)
                exited = await waitForProcessExit(runningProcess)
            }
            if !exited {
                // A process in an uninterruptible kernel state must continue
                // holding the CODEX_HOME flock. Retire it in a self-retaining
                // background task instead of claiming shutdown completed and
                // allowing a second owner into the same session directory.
                beginDeferredProcessRetirement(runningProcess)
                return
            }
        }
        finishStoppedProcess(runningProcess)
    }

    private func waitForProcessExit(
        _ runningProcess: Process
    ) async -> Bool {
        for _ in 0..<100 {
            if !runningProcess.isRunning { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return !runningProcess.isRunning
    }

    private static func forceTerminate(_ runningProcess: Process) {
        let pid = runningProcess.processIdentifier
        guard pid > 0 else { return }
        #if canImport(Darwin)
        _ = Darwin.kill(pid, SIGKILL)
        #elseif canImport(Glibc)
        _ = Glibc.kill(pid, SIGKILL)
        #elseif canImport(Musl)
        _ = Musl.kill(pid, SIGKILL)
        #else
        runningProcess.terminate()
        #endif
    }

    private func beginDeferredProcessRetirement(
        _ runningProcess: Process
    ) {
        deferredProcessRetirement = Task { [self] in
            while runningProcess.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            finishStoppedProcess(runningProcess)
        }
    }

    private func finishStoppedProcess(_ runningProcess: Process?) {
        if let runningProcess,
           let process,
           process !== runningProcess {
            return
        }
        process = nil
        isStoppingProcess = false
        processLease?.release()
        processLease = nil
        deferredProcessRetirement = nil
    }

    private func failProtocol(_ message: String) {
        let error = CodexRuntimeError.malformedProtocol(
            bounded(redact(message)))
        emit(.runtimeError(
            code: "codex_protocol",
            message: error.localizedDescription,
            fatal: true))
        Task {
            await self.stopProcess(after: error)
            self.finishEventStreams()
        }
    }

    private func clearTurnPresentationState() {
        assistantMessagePhases.removeAll(keepingCapacity: true)
        pendingResponsesUsage = nil
        finalAnswerItemIDByTurnID.removeAll(keepingCapacity: true)
        fallbackAnswerItemIDByTurnID.removeAll(keepingCapacity: true)
    }

    private func clearChildPresentationState() {
        descendantThreads.removeAll(keepingCapacity: false)
        needsDescendantRefresh = false
        childAssistantMessagePhases.removeAll(keepingCapacity: false)
        childActiveTurnIDs.removeAll(keepingCapacity: false)
        childPendingResponsesUsage.removeAll(keepingCapacity: false)
        childFinalAnswerItemIDs.removeAll(keepingCapacity: false)
        childFallbackAnswerItemIDs.removeAll(keepingCapacity: false)
        bufferedChildNotifications.removeAll(keepingCapacity: false)
    }

    private func cancelPendingDynamicToolCalls() {
        let calls = pendingDynamicToolCalls.values
        pendingDynamicToolCalls.removeAll()
        let userInputs = pendingUserInputRequests.values
        pendingUserInputRequests.removeAll()
        let verifications = pendingDescendantVerifications.values
        pendingDescendantVerifications.removeAll()
        let approvalVerifications = pendingApprovalVerifications.values
        pendingApprovalVerifications.removeAll()
        let userInputVerifications =
            pendingUserInputVerifications.values
        pendingUserInputVerifications.removeAll()
        let notificationVerifications =
            pendingChildNotificationVerifications.values
        pendingChildNotificationVerifications.removeAll()
        for call in calls {
            call.executionLease.invalidate()
            call.task.cancel()
        }
        for request in userInputs { request.task.cancel() }
        for verification in verifications { verification.cancel() }
        for verification in approvalVerifications {
            verification.cancel()
        }
        for verification in userInputVerifications {
            verification.cancel()
        }
        for verification in notificationVerifications {
            verification.cancel()
        }
        bufferedChildNotifications.removeAll(keepingCapacity: false)
    }

    private func redact(_ value: String) -> String {
        var redacted = value
        for secret in [configuration.route.bearerToken]
            + configuration.childProfiles.map(\.route.bearerToken)
            where !secret.isEmpty {
            redacted = redacted.replacingOccurrences(
                of: secret,
                with: "<redacted>")
        }
        return redacted
    }

    private func bounded(_ value: String, limit: Int = 32_768) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "…"
    }

    private static func threadID(from result: JSONValue) throws -> String {
        guard let threadID = result.objectValue?["thread"]?
            .objectValue?["id"]?.stringValue,
              !threadID.isEmpty else {
            throw CodexRuntimeError.malformedProtocol(
                "thread response is missing thread.id")
        }
        return threadID
    }

    private static func fileChangePaths(
        from value: JSONValue?
    ) -> [String] {
        (value?.arrayValue ?? []).compactMap { change in
            guard let object = change.objectValue else { return nil }
            return object["path"]?.stringValue
                ?? object["file"]?.stringValue
        }
    }

    private static func byteStream(
        from handle: FileHandle
    ) -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { readable in
                let data = readable.availableData
                if data.isEmpty {
                    readable.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var integralIntValue: Int? {
        guard case .number(let value) = self,
              value.isFinite,
              value.rounded() == value,
              value >= Double(Int.min),
              value <= Double(Int.max) else { return nil }
        return Int(value)
    }
}
