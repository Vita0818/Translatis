#if canImport(SwiftUI)
import AppKit
import CryptoKit
import Foundation
import IntatisAgentKernel
import IntatisArtifacts
import IntatisConversation
import IntatisCore
import IntatisMCP
import IntatisProtocol

private actor MCPConversationResourceUpdateRelay:
    MCPSubscribedResourceUpdateSink
{
    private var continuations:
        [UUID:
            AsyncStream<MCPSubscribedResourceUpdate>
                .Continuation] = [:]
    private var isFinished = false

    func stream()
        -> AsyncStream<MCPSubscribedResourceUpdate>
    {
        isFinished = false
        let id = UUID()
        let (stream, continuation) =
            AsyncStream<MCPSubscribedResourceUpdate>
                .makeStream(
                    bufferingPolicy:
                        .bufferingNewest(32))
        continuations[id] = continuation
        continuation.onTermination = {
            [weak self] _ in
            Task {
                await self?.remove(id)
            }
        }
        return stream
    }

    func publishMCPResourceUpdate(
        _ update: MCPSubscribedResourceUpdate
    ) {
        guard !isFinished else { return }
        for continuation in
            continuations.values
        {
            continuation.yield(update)
        }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        let current =
            Array(continuations.values)
        continuations.removeAll()
        for continuation in current {
            continuation.finish()
        }
    }

    private func remove(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

/// Session/Agent-owned implementation behind the conversation MCP center.
/// Every method reconstructs an exact current authorization view before using
/// a retained route. UI catalog values are selectors, never capabilities.
actor MCPConversationRuntimeHost {
    typealias RuntimeProvider =
        @MainActor @Sendable () async throws
            -> MCPShippingSessionRuntime
    typealias AgentProvider =
        @MainActor @Sendable () async throws
            -> [MCPProductAgentDescriptor]
    typealias DispatchInputProvider =
        @MainActor @Sendable (
            MCPProductAgentDescriptor,
            MCPRuntimeActivationReason
        ) async throws -> MCPAgentDispatchInput
    typealias PromptInsertionHandler =
        @MainActor @Sendable (
            MCPPromptInsertion
        ) async throws -> Void
    typealias ExternalContextHandler =
        @MainActor @Sendable (
            [MCPUntrustedExternalContext],
            AgentID
        ) async throws -> Void

    private struct ExactView: Sendable {
        let runtime: MCPShippingSessionRuntime
        let descriptor: MCPProductAgentDescriptor
        let input: MCPAgentDispatchInput
        let prepared: MCPPreparedAgentDispatch
        let connectionSet: MCPConnectionSetSnapshot
        let resources: MCPAgentResourceCatalogView
        let prompts: MCPAgentPromptCatalogView
        let aliases: [MCPAttachmentID: String]
    }

    private struct PendingPrompt: Sendable {
        let preview: MCPPromptPreview
        let picker: MCPPromptPicker
        let selectedByAgentID: AgentID
    }

    private struct RemoteTaskRoute: Sendable {
        let connection: MCPConnectionSnapshot
        let grant: MCPGrant
        let workspaceLease: WorkspaceLease?
    }

    private struct RemoteTaskBatch: Sendable {
        let tasks: [MCPRemoteTaskSnapshot]
        let fence: MCPExternalOperationFence
    }

    private let sessionID: SessionID
    private let log: EventLog
    private let catalogStore: MCPServerCatalogStore
    private let artifactStore: ArtifactStore
    private let artifactSink:
        MCPArtifactStoreToolSink
    private let runtimeProvider: RuntimeProvider
    private let agentProvider: AgentProvider
    private let dispatchInputProvider:
        DispatchInputProvider
    private let promptInsertionHandler:
        PromptInsertionHandler
    private let externalContextHandler:
        ExternalContextHandler
    private let authorityVerifier:
        MCPEventLogExecutionAuthorityVerifier
    private let resourceUpdateRelay:
        MCPConversationResourceUpdateRelay
    private let subscriptions:
        MCPResourceSubscriptionManager
    private let completions:
        MCPCompletionController
    private var subscribedResourceIDs:
        Set<String> = []
    private var pendingPrompts:
        [String: PendingPrompt] = [:]

    init(
        sessionID: SessionID,
        log: EventLog,
        catalogStore: MCPServerCatalogStore,
        artifactStore: ArtifactStore,
        runtimeProvider:
            @escaping RuntimeProvider,
        agentProvider:
            @escaping AgentProvider,
        dispatchInputProvider:
            @escaping DispatchInputProvider,
        promptInsertionHandler:
            @escaping PromptInsertionHandler,
        externalContextHandler:
            @escaping ExternalContextHandler
    ) {
        self.sessionID = sessionID
        self.log = log
        self.catalogStore = catalogStore
        self.artifactStore = artifactStore
        artifactSink =
            MCPArtifactStoreToolSink(
                store: artifactStore)
        self.runtimeProvider = runtimeProvider
        self.agentProvider = agentProvider
        self.dispatchInputProvider =
            dispatchInputProvider
        self.promptInsertionHandler =
            promptInsertionHandler
        self.externalContextHandler =
            externalContextHandler
        let verifier =
            MCPEventLogExecutionAuthorityVerifier(
                log: log,
                catalogStore: catalogStore)
        authorityVerifier = verifier
        let updateRelay =
            MCPConversationResourceUpdateRelay()
        resourceUpdateRelay = updateRelay
        subscriptions =
            MCPResourceSubscriptionManager(
                sink: updateRelay,
                authorityVerifier:
                    verifier)
        completions =
            MCPCompletionController(
                authorityVerifier:
                    verifier)
    }

    nonisolated func contentHost()
        -> MCPConversationContentHost
    {
        MCPConversationContentHost(
            loadCatalog: { [self] in
                try await loadCatalog()
            },
            readResource: { [self] item, uri in
                try await readResource(
                    item,
                    requestedURI: uri)
            },
            setResourceSubscription: {
                [self] item, enabled in
                try await setResourceSubscription(
                    item,
                    enabled: enabled)
            },
            resourceUpdates: { [self] in
                await resourceUpdateRelay.stream()
            },
            previewPrompt: {
                [self] item, arguments in
                try await previewPrompt(
                    item,
                    arguments: arguments)
            },
            insertPrompt: { [self] preview in
                try await insertPrompt(preview)
            },
            stageServerInstructions: {
                [self] item in
                try await stageServerInstructions(
                    item)
            },
            complete: { [self] request in
                try await complete(request)
            },
            loadRemoteTasks: { [self] in
                try await loadRemoteTasks()
            },
            refreshRemoteTask: { [self] task in
                try await refreshRemoteTask(task)
            },
            cancelRemoteTask: { [self] task in
                try await cancelRemoteTask(task)
            },
            loadRemoteTaskResult: {
                [self] task in
                try await loadRemoteTaskResult(task)
            },
            loadCallActivity: { [self] in
                try await loadCallActivity()
            },
            openArtifact: { [self] artifactID in
                try await openArtifact(artifactID)
            },
            shutdown: { [self] in
                await shutdown()
            })
    }

    func shutdown() async {
        pendingPrompts.removeAll()
        subscribedResourceIDs.removeAll()
        await completions.shutdownAndDrain()
        await subscriptions.shutdownAndDrain()
        await resourceUpdateRelay.finish()
    }

    private func loadCatalog()
        async throws
        -> MCPConversationCatalogPresentation
    {
        let exact = try await exactView()
        let resourceItems =
            try exact.resources.servers.flatMap {
                server in
                try server.resources.map { resource in
                    try Self.resourceItem(
                        resource,
                        server: server,
                        sanitizer:
                            exact.runtime
                                .outputRedactor)
                }
            }
        let templateItems =
            try exact.resources.servers.flatMap {
                server in
                try server.resourceTemplates.map {
                    template in
                    try Self.templateItem(
                        template,
                        server: server,
                        sanitizer:
                            exact.runtime
                                .outputRedactor)
                }
            }
        let promptItems =
            exact.prompts.servers.flatMap {
                server in
                server.prompts.map { prompt in
                    Self.promptItem(
                        prompt,
                        server: server)
                }
            }
        let instructions:
            [MCPConversationServerInstructionsItem] =
            exact.connectionSet.connections
                .compactMap {
                    (
                        connection:
                            MCPConnectionSnapshot
                    )
                        -> MCPConversationServerInstructionsItem?
                    in
                    guard let frozen =
                            connection
                                .serverInstructions
                    else { return nil }
                    let authority =
                        connection.reuseIdentity
                            .authority
                    return MCPConversationServerInstructionsItem(
                        id:
                            Self.itemID(
                                kind:
                                    "instructions",
                                server:
                                    connection
                                        .bindingIdentity
                                        .server,
                                generation:
                                    connection
                                        .bindingIdentity
                                        .connectionGeneration,
                                fingerprint:
                                    MCPHostDigest
                                        .sha256([
                                            frozen.text,
                                            frozen
                                                .provenance
                                                .bindingID
                                                .rawValue,
                                        ])),
                        serverAlias:
                            exact.aliases[
                                authority
                                    .attachmentID]
                                ?? connection
                                    .bindingIdentity
                                    .server
                                    .serverID
                                    .rawValue,
                        server:
                            connection
                                .bindingIdentity
                                .server,
                        text: frozen.text,
                        provenance:
                            frozen.provenance,
                        authorityFingerprint:
                            authority.fingerprint,
                        connectionGeneration:
                            connection
                                .bindingIdentity
                                .connectionGeneration,
                        policyRevision:
                            authority
                                .attachmentPolicyRevision)
                }
                .sorted { lhs, rhs in
                    if lhs.serverAlias
                        != rhs.serverAlias {
                        return lhs.serverAlias
                            < rhs.serverAlias
                    }
                    return lhs.id < rhs.id
                }
        let liveIDs = Set(resourceItems.map(\.id))
        subscribedResourceIDs.formIntersection(
            liveIDs)
        return MCPConversationCatalogPresentation(
            snapshotID:
                exact.connectionSet.snapshotID,
            bindingID: exact.connectionSet.bindingID,
            agentID:
                exact.connectionSet.agentID,
            resources:
                resourceItems.sorted(
                    by: Self.resourceOrder),
            resourceTemplates:
                templateItems.sorted(
                    by: Self.templateOrder),
            prompts:
                promptItems.sorted(
                    by: Self.promptOrder),
            serverInstructions:
                instructions,
            subscribedResourceIDs:
                subscribedResourceIDs)
    }

    private func readResource(
        _ item: MCPConversationResourceItem,
        requestedURI: String
    ) async throws
        -> MCPConversationResourceReadPresentation
    {
        let exact = try await exactView()
        let server =
            try resolveResourceServer(
                item,
                in: exact.resources)
        let ordinary =
            server.resources.first {
                $0.identityFingerprint
                    == item.identityFingerprint
            }
        let template =
            server.resourceTemplates.first {
                $0.identityFingerprint
                    == item.identityFingerprint
            }
        guard ordinary != nil || template != nil else {
            throw MCPContentOperationError
                .staleRequest
        }
        if let ordinary,
           ordinary.uri != requestedURI {
            throw MCPContentOperationError
                .resourceNotGranted(
                    requestedURI)
        }
        try await authorityVerifier.verifyResource(
            server,
            workspaceLease:
                exact.input.workspaceLease)
        try server.policy.validateReadURI(
            requestedURI,
            authority:
                server.connection.reuseIdentity
                    .authority)
        let fence =
            MCPExternalOperationFence(
                request:
                    try MCPExternalOperationAuthorityRequest(
                        operation:
                            .readResource,
                        connection:
                            server.connection,
                        grant: server.grant,
                        workspaceLease:
                            exact.input
                                .workspaceLease,
                        target:
                            requestedURI),
                verifier:
                    authorityVerifier)
        let result =
            try await server.connection.route
                .readResource(
                    uri: requestedURI,
                    fence: fence)
        let provenance =
            Self.resourceProvenance(
                server.connection,
                uri: requestedURI,
                template: template != nil)
        let blocks =
            try await convertResourceContents(
                result.contents,
                provenance: provenance,
                sanitizer:
                    exact.runtime
                        .outputRedactor)
        try await fence.verifyBeforePublication()
        return MCPConversationResourceReadPresentation(
            serverAlias:
                server.policy.serverAlias,
            server:
                server.connection.bindingIdentity
                    .server,
            requestedURI: requestedURI,
            blocks: blocks,
            provenance: provenance)
    }

    private func setResourceSubscription(
        _ item: MCPConversationResourceItem,
        enabled: Bool
    ) async throws {
        let exact = try await exactView()
        let runtime = try await runtimeProvider()
        await runtime.installSubscriptionNotificationSink(
            subscriptions)
        let server =
            try resolveResourceServer(
                item,
                in: exact.resources)
        guard server.resources.contains(
            where: {
                $0.identityFingerprint
                    == item.identityFingerprint
                    && $0.uri == item.uri
            }) else {
            throw MCPContentOperationError
                .resourceNotGranted(item.uri)
        }
        try await authorityVerifier.verifyResource(
            server,
            workspaceLease:
                exact.input.workspaceLease)
        if enabled {
            try await subscriptions.subscribe(
                uri: item.uri,
                connection:
                    server.connection,
                grant: server.grant,
                workspaceLease:
                    exact.input
                        .workspaceLease)
            subscribedResourceIDs.insert(
                item.id)
        } else {
            await subscriptions.unsubscribe(
                server: item.server,
                generation:
                    item.connectionGeneration,
                uri: item.uri)
            subscribedResourceIDs.remove(
                item.id)
        }
    }

    private func previewPrompt(
        _ item: MCPConversationPromptItem,
        arguments: [String: String]
    ) async throws -> MCPPromptPreview {
        let exact = try await exactView()
        guard let server =
                exact.prompts.servers.first(
                    where: {
                        $0.connection.bindingIdentity
                            .server == item.server
                            && $0.connection
                                .bindingIdentity
                                .connectionGeneration
                                == item
                                    .connectionGeneration
                            && $0.prompts.contains(
                                where: {
                                    $0.identityFingerprint
                                        == item
                                            .identityFingerprint
                                        && $0.name
                                            == item.name
                                })
                    }) else {
            throw MCPContentOperationError
                .staleRequest
        }
        try await verifyPromptAuthority(
            server,
            input: exact.input)
        let picker =
            MCPPromptPicker(
                view: exact.prompts,
                authorityVerifier:
                    authorityVerifier,
                workspaceLease:
                    exact.input
                        .workspaceLease,
                sanitizer:
                    exact.runtime
                        .outputRedactor)
        let preview =
            try await picker.preview(
                serverAlias:
                    item.serverAlias,
                promptName: item.name,
                arguments: arguments,
                explicitUserAction: true)
        pendingPrompts[preview.previewID] =
            PendingPrompt(
                preview: preview,
                picker: picker,
                selectedByAgentID:
                    exact.descriptor.agentID)
        if pendingPrompts.count > 16 {
            let retained =
                pendingPrompts.keys.sorted()
                    .suffix(16)
            pendingPrompts =
                pendingPrompts.filter {
                    retained.contains($0.key)
                }
        }
        return preview
    }

    private func insertPrompt(
        _ preview: MCPPromptPreview
    ) async throws {
        guard let pending =
                pendingPrompts.removeValue(
                    forKey: preview.previewID),
              pending.preview == preview else {
            throw MCPContentOperationError
                .staleRequest
        }
        let insertion =
            try pending.picker
                .confirmInsertion(
                    preview: preview,
                    decision: .insert(
                        previewID:
                            preview.previewID,
                        confirmationDigest:
                            preview
                                .confirmationDigest),
                    requestID: .new(),
                    insertedMessageID: .new(),
                    selectedByAgentID:
                        pending
                            .selectedByAgentID)
        guard let insertion else {
            throw MCPContentOperationError
                .explicitUserConfirmationRequired
        }
        try await promptInsertionHandler(
            insertion)
    }

    private func stageServerInstructions(
        _ item:
            MCPConversationServerInstructionsItem
    ) async throws {
        let exact = try await exactView()
        let matches =
            exact.connectionSet.connections
                .filter { connection in
                    let binding =
                        connection.bindingIdentity
                    return binding.server
                            == item.server
                        && binding
                            .connectionGeneration
                            == item
                                .connectionGeneration
                        && connection.reuseIdentity
                            .authority.fingerprint
                            == item
                                .authorityFingerprint
                        && connection
                            .serverInstructions?
                            .text == item.text
                        && connection
                            .serverInstructions?
                            .provenance
                            == item.provenance
                        && connection.reuseIdentity
                            .authority
                            .attachmentPolicyRevision
                            == item
                                .policyRevision
                }
        guard matches.count == 1,
              let connection = matches.first
        else {
            throw MCPContentOperationError
                .staleRequest
        }
        let grant = try exactGrant(
            for: connection,
            capabilityLease:
                exact.prepared.capabilityLease)
        guard let context =
                try await MCPServerInstructionsMaterializer(
                    sanitizer:
                        exact.runtime
                            .outputRedactor)
                    .materialize(
                        visibility:
                            .externalContext(
                                policyRevision:
                                    item
                                        .policyRevision),
                        connection: connection,
                        grant: grant,
                        workspaceLease:
                            exact.input
                                .workspaceLease,
                        authorityVerifier:
                            authorityVerifier)
        else {
            throw MCPContentOperationError
                .staleRequest
        }
        try await externalContextHandler(
            [context],
            exact.descriptor.agentID)
    }

    private func complete(
        _ request:
            MCPConversationCompletionRequest
    ) async throws -> MCPCompletionSuggestions {
        let exact = try await exactView()
        guard let connection =
                exact.connectionSet.connections.first(
                    where: {
                        $0.bindingIdentity.server
                            == request.server
                    }),
              let alias =
                exact.aliases[
                    connection.reuseIdentity
                        .authority.attachmentID]
        else {
            throw MCPContentOperationError
                .staleRequest
        }
        return try await completions.complete(
            fieldID: request.fieldID,
            view: exact.connectionSet,
            capabilityLease:
                exact.prepared.capabilityLease,
            workspaceLease:
                exact.input.workspaceLease,
            serverAlias: alias,
            aliases: exact.aliases,
            reference: request.reference,
            argumentName:
                request.argumentName,
            argumentValue:
                request.argumentValue,
            context: request.context,
            sanitizerOverride:
                exact.runtime.outputRedactor)
    }

    private func loadRemoteTasks()
        async throws -> [MCPRemoteTaskSnapshot]
    {
        let exact = try await exactView()
        return try await withThrowingTaskGroup(
            of: RemoteTaskBatch.self
        ) { group in
            for connection in
                exact.connectionSet.connections
            {
                guard connection.bindingIdentity
                        .protocolProfile
                        == .standardExtended,
                      connection
                        .negotiatedCapabilities
                        .capabilities
                        .contains(.tasks),
                      connection
                        .negotiatedCapabilities
                        .remoteTaskList,
                      let grant =
                        try exactOptionalGrant(
                            for: connection,
                            capability:
                                .tasks,
                            capabilityLease:
                                exact.prepared
                                    .capabilityLease)
                else {
                    continue
                }
                let fence =
                    MCPExternalOperationFence(
                        request:
                            try MCPExternalOperationAuthorityRequest(
                                operation:
                                    .listRemoteTasks,
                                connection:
                                    connection,
                                grant: grant,
                                workspaceLease:
                                    exact.input
                                        .workspaceLease,
                                target:
                                    "remote_tasks_list"),
                        verifier:
                            authorityVerifier)
                group.addTask {
                    let tasks =
                        try await connection.route
                            .listRemoteTasks(
                                fence: fence)
                    return RemoteTaskBatch(
                        tasks: tasks,
                        fence: fence)
                }
            }
            var tasks:
                [MCPRemoteTaskSnapshot] = []
            for try await batch in group {
                try await batch.fence
                    .verifyBeforePublication()
                tasks.append(
                    contentsOf: batch.tasks)
            }
            return tasks.sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt
                        > $1.createdAt
                }
                return $0.taskID.rawValue
                    < $1.taskID.rawValue
            }
        }
    }

    private func refreshRemoteTask(
        _ task: MCPRemoteTaskSnapshot
    ) async throws -> MCPRemoteTaskSnapshot {
        let route =
            try await remoteTaskRoute(
                for: task,
                requires: \.remoteTaskGetAndResult)
        let fence =
            try remoteTaskFence(
                operation:
                    .refreshRemoteTask,
                task: task,
                route: route)
        let refreshed =
            try await route.connection.route
                .refreshRemoteTask(
                    task.taskID,
                    fence: fence)
        try await fence.verifyBeforePublication()
        return refreshed
    }

    private func cancelRemoteTask(
        _ task: MCPRemoteTaskSnapshot
    ) async throws -> MCPRemoteTaskSnapshot {
        let route =
            try await remoteTaskRoute(
                for: task,
                requires: \.remoteTaskCancel)
        let fence =
            try remoteTaskFence(
                operation:
                    .cancelRemoteTask,
                task: task,
                route: route)
        let cancelled =
            try await route.connection.route
                .cancelRemoteTask(
                    task.taskID,
                    fence: fence)
        try await fence.verifyBeforePublication()
        return cancelled
    }

    private func loadRemoteTaskResult(
        _ task: MCPRemoteTaskSnapshot
    ) async throws
        -> MCPConversationRemoteTaskResultPresentation
    {
        let route =
            try await remoteTaskRoute(
                for: task,
                requires: \.remoteTaskGetAndResult)
        let fence =
            try remoteTaskFence(
                operation:
                    .readRemoteTaskResult,
                task: task,
                route: route)
        let raw =
            try await route.connection.route
                .remoteTaskResult(
                    task.taskID,
                    fence: fence)
        let data =
            try MCPJSONSchema.canonicalData(raw)
        let rawText =
            String(decoding: data, as: UTF8.self)
        let outputRedactor =
            try await runtimeProvider()
                .outputRedactor
        let sanitized =
            try outputRedactor
                .sanitizeMCPText(rawText)
        var artifacts: [ArtifactID] = []
        let summary: String
        if sanitized.utf8.count
                <= 64 * 1_024 {
            summary = sanitized
        } else {
            let provenance =
                Self.taskProvenance(
                    task,
                    connection:
                        route.connection)
            let stored =
                try await artifactSink
                    .storeMCPToolArtifact(
                        Data(sanitized.utf8),
                        mimeType:
                            "application/json",
                        provenance:
                            provenance)
            artifacts = [stored.artifactID]
            summary =
                "The sanitized remote task result is stored as artifact \(stored.artifactID.rawValue)."
        }
        try await fence.verifyBeforePublication()
        return MCPConversationRemoteTaskResultPresentation(
            taskID: task.taskID,
            summary: summary,
            artifactIDs: artifacts,
            resultReference:
                task.resultReference)
    }

    private func loadCallActivity()
        async throws
        -> [MCPConversationCallPresentation]
    {
        let envelopes =
            try await log.replayChecked()
        let catalog =
            try await catalogStore.load()
        var calls:
            [String: (ToolCallPayload, Date)] = [:]
        var prepared:
            [String:
                (ToolExecutionPreparedPayload, Date)] = [:]
        var settled:
            [String:
                (ToolExecutionSettledPayload, Date)] = [:]
        var results:
            [String: ToolResultPayload] = [:]
        for envelope in envelopes {
            switch envelope.event {
            case .toolCall(let payload):
                calls[payload.toolCallId] =
                    (payload, envelope.ts)
            case .toolExecutionPrepared(
                    let payload):
                guard payload.authorization?
                    .mcp != nil else { continue }
                prepared[payload.executionID] =
                    (payload, envelope.ts)
            case .toolExecutionSettled(
                    let payload):
                guard payload.authorization?
                    .mcp != nil else { continue }
                settled[payload.executionID] =
                    (payload, envelope.ts)
            case .toolResult(let payload):
                results[payload.toolCallId] =
                    payload
            default:
                continue
            }
        }
        return prepared.values.compactMap {
            payload, startedAt in
            guard let authorization =
                    payload.authorization?.mcp
            else { return nil }
            let terminal =
                settled[payload.executionID]
            let result =
                results[payload.toolCallID]
            let call =
                calls[payload.toolCallID]?.0
            let alias =
                catalog.head(
                    for:
                        authorization.server
                            .serverID)?.alias
                    ?? authorization.server
                        .serverID.rawValue
            let state =
                terminal.map {
                    Self.callState(
                        $0.0.outcome)
                } ?? .running
            let artifacts =
                result?.structuredResult?
                    .content.compactMap(
                        \.artifactID) ?? []
            let sourceURIs =
                result?.structuredResult?
                    .content.compactMap(\.uri)
                    ?? []
            let duration =
                terminal.map {
                    max(
                        0,
                        Int(
                            $0.1.timeIntervalSince(
                                startedAt)
                                * 1_000))
                }
            let summary =
                result.map {
                    String(
                        $0.observation
                            .prefix(2_048))
                }
                ?? terminal?.0.reason
            return MCPConversationCallPresentation(
                id: payload.executionID,
                serverAlias: alias,
                server:
                    authorization.server,
                toolName:
                    authorization.remoteToolName,
                argumentSummary:
                    call.map {
                        String(
                            $0.args.prefix(2_048))
                    } ?? "Arguments were not retained.",
                approvalMode:
                    authorization
                        .effectiveApprovalMode,
                state: state,
                progressFraction: nil,
                progressSummary: nil,
                durationMilliseconds:
                    duration,
                resultSummary: summary,
                artifactIDs: artifacts,
                sourceURIs: sourceURIs,
                startedAt: startedAt)
        }.sorted {
            if $0.startedAt != $1.startedAt {
                return $0.startedAt
                    > $1.startedAt
            }
            return $0.id < $1.id
        }
    }

    private func openArtifact(
        _ artifactID: ArtifactID
    ) async throws {
        guard let ref =
                await artifactStore.ref(
                    for: artifactID) else {
            throw IntatisError.notFound(
                "artifact \(artifactID.rawValue)")
        }
        let url =
            artifactStore.absoluteURL(for: ref)
        let opened =
            await MainActor.run {
                NSWorkspace.shared.open(url)
            }
        guard opened else {
            throw IntatisError.io(
                "macOS could not open the selected artifact.")
        }
    }

    private func exactView()
        async throws -> ExactView
    {
        let descriptors =
            try await agentProvider()
                .filter {
                    !$0.isPermissionReviewer
                }
                .sorted {
                    if $0.isWorker != $1.isWorker {
                        return !$0.isWorker
                    }
                    if $0.agentID != $1.agentID {
                        return $0.agentID.rawValue
                            < $1.agentID.rawValue
                    }
                    return $0.capabilityLeaseID
                        .rawValue
                        < $1.capabilityLeaseID
                            .rawValue
                }
        guard let descriptor =
                descriptors.first else {
            throw IntatisError.permissionDenied(
                "No live Agent capability lease is available for MCP content.")
        }
        let input =
            try await dispatchInputProvider(
                descriptor,
                .explicitConnect)
        let runtime =
            try await runtimeProvider()
        let prepared =
            try await runtime.snapshots.prepare(
                for: input)
        guard let published =
                await runtime.owner
                    .latestPublishedSnapshot(
                        agentID:
                            descriptor.agentID) else {
            throw IntatisError.io(
                "No live MCP connection set is published for this Agent. Use Connect in MCP Project Settings first.")
        }
        let live =
            await runtime.owner
                .liveConnectionSnapshots()
        guard published.sessionID == sessionID,
              published.agentID
                == descriptor.agentID,
              published.connections.allSatisfy({
                  connection in
                  live.contains {
                      $0.bindingIdentity
                          == connection.bindingIdentity
                          && $0.reuseIdentity
                              == connection.reuseIdentity
                  }
              }) else {
            throw MCPContentOperationError
                .staleRequest
        }
        var requirements:
            [MCPConnectionReuseIdentity:
                MCPInvocationServerRequirement] = [:]
        for requirement in prepared.plan.servers {
            if requirements.updateValue(
                requirement,
                forKey: requirement.identity) != nil {
                throw MCPContentOperationError
                    .staleRequest
            }
        }
        let publishedMatchesPlan =
            published.connections.allSatisfy {
                requirements[
                    $0.reuseIdentity] != nil
            }
        let requiredConnectionsAreLive =
            prepared.plan.servers
                .filter(\.effectiveRequired)
                .allSatisfy { required in
                    published.connections.contains {
                        $0.reuseIdentity
                            == required.identity
                    }
                }
        guard publishedMatchesPlan,
              requiredConnectionsAreLive else {
            throw MCPContentOperationError
                .staleRequest
        }
        let resources =
            try MCPAgentResourceCatalogView.build(
                connectionSet: published,
                capabilityLease:
                    prepared.capabilityLease,
                policies:
                    prepared.resourcePolicies)
        let promptPolicies =
            try await makePromptPolicies(
                prepared: prepared,
                connections: published)
        let prompts =
            try MCPAgentPromptCatalogView.build(
                connectionSet: published,
                capabilityLease:
                    prepared.capabilityLease,
                policies: promptPolicies)
        var aliases: [MCPAttachmentID: String] = [:]
        let candidates =
            prepared.policies.map {
                ($0.attachmentID, $0.serverAlias)
            } + prepared.resourcePolicies.map {
                ($0.attachmentID, $0.serverAlias)
            } + promptPolicies.map {
                ($0.attachmentID, $0.serverAlias)
            }
        for (attachmentID, alias) in candidates {
            if let existing = aliases[attachmentID],
               existing != alias {
                throw MCPContentOperationError
                    .staleRequest
            }
            aliases[attachmentID] = alias
        }
        return ExactView(
            runtime: runtime,
            descriptor: descriptor,
            input: input,
            prepared: prepared,
            connectionSet: published,
            resources: resources,
            prompts: prompts,
            aliases: aliases)
    }

    private func makePromptPolicies(
        prepared: MCPPreparedAgentDispatch,
        connections: MCPConnectionSetSnapshot
    ) async throws -> [MCPPromptAccessPolicy] {
        let state =
            try await MCPDurableSessionState.load(
                from: log)
        let catalog =
            try await catalogStore.load()
        var policies:
            [MCPPromptAccessPolicy] = []
        for connection in connections.connections {
            let authority =
                connection.reuseIdentity.authority
            guard let attachment =
                    state.attachments[
                        authority.attachmentID],
                  attachment.server
                    == connection.reuseIdentity
                        .server,
                  let definition =
                    catalog.definition(
                        for: attachment.server)
            else {
                throw MCPContentOperationError
                    .staleRequest
            }
            let grants =
                prepared.capabilityLease.mcpGrants
                    .filter {
                        $0.attachmentID
                            == attachment
                                .attachmentID
                            && $0.server
                                == attachment.server
                            && $0.agentID
                                == connections
                                    .agentID
                            && $0.grants(.prompts)
                            && $0.isActive()
                    }
            guard !grants.isEmpty else {
                continue
            }
            guard grants.count == 1 else {
                throw MCPContentOperationError
                    .missingGrant(.prompts)
            }
            let alias =
                catalog.head(
                    for:
                        attachment.server
                            .serverID)?.alias
                    ?? attachment.server
                        .serverID.rawValue
            policies.append(
                try MCPPromptAccessPolicy(
                    server:
                        attachment.server,
                    attachmentID:
                        attachment.attachmentID,
                    serverAlias: alias,
                    serverFilter:
                        definition.configuration
                            .filters.prompts,
                    attachmentFilter:
                        attachment.policy.filter
                            .prompts,
                    policyFingerprint:
                        MCPHostDigest.sha256([
                            definition
                                .definitionFingerprint,
                            attachment.policy
                                .revision.rawValue,
                            grants[0]
                                .grantFingerprint,
                            "prompts",
                        ])))
        }
        return policies
    }

    private func resolveResourceServer(
        _ item: MCPConversationResourceItem,
        in view: MCPAgentResourceCatalogView
    ) throws -> MCPAgentResourceServerView {
        guard let server =
                view.servers.first(
                    where: {
                        $0.connection.bindingIdentity
                            .server == item.server
                            && $0.connection
                                .bindingIdentity
                                .connectionGeneration
                                == item
                                    .connectionGeneration
                            && $0.policy.serverAlias
                                == item.serverAlias
                    }) else {
            throw MCPContentOperationError
                .staleRequest
        }
        return server
    }

    private func remoteTaskRoute(
        for task: MCPRemoteTaskSnapshot,
        requires:
            KeyPath<
                MCPNegotiatedCapabilitySet,
                Bool
            >
    ) async throws -> RemoteTaskRoute {
        let exact = try await exactView()
        guard let connection =
                exact.connectionSet.connections.first(
                    where: {
                        $0.bindingIdentity.server
                            == task.authority.server
                            && $0.bindingIdentity
                                .connectionGeneration
                                == task.authority
                                    .connectionGeneration
                            && $0.reuseIdentity
                                .authority.fingerprint
                                == task.authority
                                    .authorityFingerprint
                    }) else {
            throw MCPContentOperationError
                .staleRequest
        }
        guard connection.bindingIdentity
                .protocolProfile
                == .standardExtended else {
            throw MCPTaskRuntimeError
                .unsupportedProfile
        }
        guard connection
                .negotiatedCapabilities
                .capabilities.contains(.tasks),
              connection
                .negotiatedCapabilities[
                    keyPath: requires]
        else {
            throw MCPTaskRuntimeError
                .capabilityMissing
        }
        let grant = try exactGrant(
            for: connection,
            capability: .tasks,
            capabilityLease:
                exact.prepared.capabilityLease)
        return RemoteTaskRoute(
            connection: connection,
            grant: grant,
            workspaceLease:
                exact.input.workspaceLease)
    }

    private func remoteTaskFence(
        operation: MCPExternalOperationKind,
        task: MCPRemoteTaskSnapshot,
        route: RemoteTaskRoute
    ) throws -> MCPExternalOperationFence {
        MCPExternalOperationFence(
            request:
                try MCPExternalOperationAuthorityRequest(
                    operation: operation,
                    connection:
                        route.connection,
                    grant: route.grant,
                    workspaceLease:
                        route.workspaceLease,
                    target:
                        task.taskID
                            .rawValue),
            verifier: authorityVerifier)
    }

    private func exactGrant(
        for connection: MCPConnectionSnapshot,
        capability: MCPGrantedCapability? = nil,
        capabilityLease: CapabilityLease
    ) throws -> MCPGrant {
        guard let grant =
                try exactOptionalGrant(
                    for: connection,
                    capability: capability,
                    capabilityLease:
                        capabilityLease)
        else {
            throw MCPContentOperationError
                .invalidExternalOperationAuthority
        }
        return grant
    }

    private func exactOptionalGrant(
        for connection: MCPConnectionSnapshot,
        capability: MCPGrantedCapability?,
        capabilityLease: CapabilityLease
    ) throws -> MCPGrant? {
        let authority =
            connection.reuseIdentity.authority
        let grants =
            capabilityLease.mcpGrants.filter {
                $0.attachmentID
                        == authority.attachmentID
                    && $0.server
                        == connection
                            .bindingIdentity.server
                    && $0.agentID
                        == authority.agentID
                    && $0.capabilityLeaseID
                        == capabilityLease.id
                    && $0.taskID
                        == capabilityLease.taskID
                    && $0.taskID
                        == authority
                            .capabilityTaskID
                    && $0.authorityFingerprint
                        == authority.fingerprint
                    && $0.revocationGeneration
                        == connection
                            .bindingIdentity
                            .revocationGeneration
                    && $0.isActive()
                    && capability.map(
                        $0.grants) ?? true
            }
        guard grants.count <= 1 else {
            throw MCPContentOperationError
                .invalidExternalOperationAuthority
        }
        return grants.first
    }

    private func verifyPromptAuthority(
        _ server: MCPAgentPromptServerView,
        input: MCPAgentDispatchInput
    ) async throws {
        let state =
            try await MCPDurableSessionState.load(
                from: log)
        let identity =
            server.connection.reuseIdentity
        let requirement =
            MCPConsentRequirement(identity: identity)
        guard state.attachments[
                identity.authority.attachmentID]?
                .server == identity.server,
              state.grants[server.grant.grantID]
                == server.grant,
              server.grant.grants(.prompts),
              server.grant.isActive(),
              state.consents.values.filter({
                  requirement.exactlyMatches($0)
              }).count == 1,
              input.capabilityLease.id
                == identity.authority
                    .capabilityLeaseID else {
            throw MCPContentOperationError
                .missingGrant(.prompts)
        }
        try await server.connection.route
            .revalidate(catalogKind: .prompts)
    }

    private func convertResourceContents(
        _ contents: [MCPRawResourceContent],
        provenance: MCPContentProvenance,
        sanitizer:
            any MCPToolResultSanitizer
    ) async throws -> [MCPConversationResourceBlock] {
        let limits = MCPResourceResultLimits()
        guard contents.count
                <= limits.maximumContents else {
            throw MCPContentOperationError
                .tooManyContents(
                    maximum:
                        limits.maximumContents)
        }

        // Validate and size every block before the first ArtifactStore write.
        // This prevents a later oversized/malformed block from leaving an
        // earlier orphaned artifact, and charges the larger of raw and
        // sanitized bytes when exact redaction expands text.
        var rawPreflightBytes = 0
        var safePreflightBytes = 0
        func addPreflight(
            _ count: Int,
            to total: inout Int
        ) throws {
            let (next, overflow) =
                total.addingReportingOverflow(count)
            guard !overflow,
                  next <= limits.maximumTotalBytes
            else {
                throw MCPContentOperationError
                    .contentTooLarge(
                        maximum:
                            limits.maximumTotalBytes)
            }
            total = next
        }
        for content in contents {
            try Self.validateReturnedURI(
                content.uri)
            let safeURI =
                try sanitizer
                    .sanitizeMCPText(
                        content.uri)
            let safeMIMEType =
                try Self.validateReturnedMIMEType(
                    content.mimeType,
                    sanitizer: sanitizer)
            try addPreflight(
                content.uri.utf8.count
                    + (content.mimeType?
                        .utf8.count ?? 0),
                to: &rawPreflightBytes)
            try addPreflight(
                safeURI.utf8.count
                    + (safeMIMEType?
                        .utf8.count ?? 0),
                to: &safePreflightBytes)
            if let text = content.text {
                let safeText =
                    try sanitizer
                        .sanitizeMCPText(text)
                try addPreflight(
                    text.utf8.count,
                    to: &rawPreflightBytes)
                try addPreflight(
                    safeText.utf8.count,
                    to: &safePreflightBytes)
            } else if let encoded =
                        content.base64,
                      let data =
                        Data(
                            base64Encoded:
                                encoded) {
                guard data.count
                        <= limits
                            .maximumBinaryBytesPerContent
                else {
                    throw MCPContentOperationError
                        .contentTooLarge(
                            maximum:
                                limits
                                    .maximumBinaryBytesPerContent)
                }
                try sanitizer
                    .validateMCPBinary(data)
                try addPreflight(
                    data.count,
                    to: &rawPreflightBytes)
                try addPreflight(
                    data.count,
                    to: &safePreflightBytes)
            } else {
                throw MCPContentOperationError
                    .malformedBinary
            }
        }

        var blocks:
            [MCPConversationResourceBlock] = []
        for (index, content) in
            contents.enumerated()
        {
            try Self.validateReturnedURI(
                content.uri)
            let safeURI =
                try sanitizer
                    .sanitizeMCPText(
                        content.uri)
            let safeMIMEType =
                try Self.validateReturnedMIMEType(
                    content.mimeType,
                    sanitizer: sanitizer)
            if let text = content.text {
                let data = Data(text.utf8)
                let sanitized =
                    try sanitizer
                        .sanitizeMCPText(text)
                let safeData =
                    Data(sanitized.utf8)
                if sanitized != text {
                    blocks.append(
                        MCPConversationResourceBlock(
                            id:
                                "\(index)-redacted",
                            kind: .redacted,
                            uri: safeURI,
                            mimeType:
                                safeMIMEType,
                            byteCount: data.count,
                            sha256:
                                Self.sha256(data),
                            text: nil,
                            artifactID: nil,
                            reason:
                                "Sensitive content was redacted."))
                } else if safeData.count
                            > limits
                                .maximumTextBytesPerContent {
                    try sanitizer
                        .validateMCPBinary(
                            safeData)
                    let stored =
                        try await artifactSink
                            .storeMCPToolArtifact(
                                safeData,
                                mimeType:
                                    safeMIMEType
                                        ?? "text/plain",
                                provenance:
                                    provenance)
                    blocks.append(
                        MCPConversationResourceBlock(
                            id:
                                "\(index)-artifact",
                            kind: .artifact,
                            uri: safeURI,
                            mimeType:
                                safeMIMEType,
                            byteCount:
                                stored.byteCount,
                            sha256:
                                stored.sha256,
                            text: nil,
                            artifactID:
                                stored.artifactID,
                            reason:
                                "Oversized text was stored as an artifact."))
                } else {
                    blocks.append(
                        MCPConversationResourceBlock(
                            id: "\(index)-text",
                            kind: .inlineText,
                            uri: safeURI,
                            mimeType:
                                safeMIMEType,
                            byteCount:
                                safeData.count,
                            sha256:
                                Self.sha256(
                                    safeData),
                            text: sanitized,
                            artifactID: nil,
                            reason: nil))
                }
            } else if let encoded =
                        content.base64 {
                guard let data =
                        Data(
                            base64Encoded:
                                encoded) else {
                    throw MCPContentOperationError
                        .malformedBinary
                }
                guard data.count
                        <= limits
                            .maximumBinaryBytesPerContent
                else {
                    throw MCPContentOperationError
                        .contentTooLarge(
                            maximum:
                                limits
                                    .maximumBinaryBytesPerContent)
                }
                try sanitizer
                    .validateMCPBinary(data)
                let stored =
                    try await artifactSink
                        .storeMCPToolArtifact(
                            data,
                            mimeType:
                                safeMIMEType,
                            provenance:
                                provenance)
                blocks.append(
                    MCPConversationResourceBlock(
                        id:
                            "\(index)-artifact",
                        kind: .artifact,
                        uri: safeURI,
                        mimeType:
                            safeMIMEType,
                        byteCount:
                            stored.byteCount,
                        sha256:
                            stored.sha256,
                        text: nil,
                        artifactID:
                            stored.artifactID,
                        reason:
                            "Binary content was stored as an artifact."))
            }
        }
        return blocks
    }

    private nonisolated static func validateReturnedMIMEType(
        _ value: String?,
        sanitizer:
            any MCPToolResultSanitizer
    ) throws -> String? {
        guard let value else { return nil }
        guard value.utf8.count <= 256,
              !value.contains("\0"),
              !value.contains(where: \.isNewline)
        else {
            throw MCPContentOperationError
                .contentTooLarge(
                    maximum: 256)
        }
        return try MCPOutputSanitization
            .requireUnchangedIdentifier(
                value,
                using: sanitizer)
    }

    private nonisolated static func resourceItem(
        _ resource: MCPRawResourceRecord,
        server: MCPAgentResourceServerView,
        sanitizer:
            any MCPToolResultSanitizer
    ) throws -> MCPConversationResourceItem {
        let binding =
            server.connection.bindingIdentity
        return MCPConversationResourceItem(
            id: itemID(
                kind: "resource",
                server: binding.server,
                generation:
                    binding.connectionGeneration,
                fingerprint:
                    resource.identityFingerprint),
            serverAlias:
                server.policy.serverAlias,
            server: binding.server,
            name:
                try sanitizer.sanitizeMCPText(
                    resource.name),
            title:
                try resource.title.map(
                    sanitizer.sanitizeMCPText),
            summary:
                try resource.summary.map(
                    sanitizer.sanitizeMCPText),
            uri:
                try MCPOutputSanitization
                    .requireUnchangedIdentifier(
                        resource.uri,
                        using: sanitizer),
            mimeType:
                try resource.mimeType.map {
                    try MCPOutputSanitization
                        .requireUnchangedIdentifier(
                            $0,
                            using: sanitizer)
                },
            size: resource.size,
            identityFingerprint:
                resource.identityFingerprint,
            connectionGeneration:
                binding.connectionGeneration,
            rawCatalogRevision:
                binding.rawCatalogRevision)
    }

    private nonisolated static func templateItem(
        _ template:
            MCPRawResourceTemplateRecord,
        server: MCPAgentResourceServerView,
        sanitizer:
            any MCPToolResultSanitizer
    ) throws -> MCPConversationResourceTemplateItem {
        let binding =
            server.connection.bindingIdentity
        return MCPConversationResourceTemplateItem(
            id: itemID(
                kind: "template",
                server: binding.server,
                generation:
                    binding.connectionGeneration,
                fingerprint:
                    template.identityFingerprint),
            serverAlias:
                server.policy.serverAlias,
            server: binding.server,
            name:
                try sanitizer.sanitizeMCPText(
                    template.name),
            title:
                try template.title.map(
                    sanitizer.sanitizeMCPText),
            summary:
                try template.summary.map(
                    sanitizer.sanitizeMCPText),
            uriTemplate:
                try MCPOutputSanitization
                    .requireUnchangedIdentifier(
                        template.uriTemplate,
                        using: sanitizer),
            mimeType:
                try template.mimeType.map {
                    try MCPOutputSanitization
                        .requireUnchangedIdentifier(
                            $0,
                            using: sanitizer)
                },
            identityFingerprint:
                template.identityFingerprint,
            connectionGeneration:
                binding.connectionGeneration,
            rawCatalogRevision:
                binding.rawCatalogRevision)
    }

    private nonisolated static func promptItem(
        _ prompt: MCPRawPromptRecord,
        server: MCPAgentPromptServerView
    ) -> MCPConversationPromptItem {
        let binding =
            server.connection.bindingIdentity
        return MCPConversationPromptItem(
            id: itemID(
                kind: "prompt",
                server: binding.server,
                generation:
                    binding.connectionGeneration,
                fingerprint:
                    prompt.identityFingerprint),
            serverAlias:
                server.policy.serverAlias,
            server: binding.server,
            name: prompt.name,
            title: prompt.title,
            summary: prompt.summary,
            arguments: prompt.arguments,
            identityFingerprint:
                prompt.identityFingerprint,
            connectionGeneration:
                binding.connectionGeneration,
            rawCatalogRevision:
                binding.rawCatalogRevision)
    }

    private nonisolated static func itemID(
        kind: String,
        server: MCPServerReference,
        generation: MCPConnectionGeneration,
        fingerprint: String
    ) -> String {
        MCPHostDigest.sha256([
            kind,
            server.serverID.rawValue,
            server.serverRevision.rawValue,
            generation.rawValue,
            fingerprint,
        ])
    }

    private nonisolated static func resourceOrder(
        _ lhs: MCPConversationResourceItem,
        _ rhs: MCPConversationResourceItem
    ) -> Bool {
        if lhs.serverAlias != rhs.serverAlias {
            return lhs.serverAlias
                < rhs.serverAlias
        }
        return lhs.name < rhs.name
    }

    private nonisolated static func templateOrder(
        _ lhs:
            MCPConversationResourceTemplateItem,
        _ rhs:
            MCPConversationResourceTemplateItem
    ) -> Bool {
        if lhs.serverAlias != rhs.serverAlias {
            return lhs.serverAlias
                < rhs.serverAlias
        }
        return lhs.name < rhs.name
    }

    private nonisolated static func promptOrder(
        _ lhs: MCPConversationPromptItem,
        _ rhs: MCPConversationPromptItem
    ) -> Bool {
        if lhs.serverAlias != rhs.serverAlias {
            return lhs.serverAlias
                < rhs.serverAlias
        }
        return lhs.name < rhs.name
    }

    private nonisolated static func resourceProvenance(
        _ connection: MCPConnectionSnapshot,
        uri: String,
        template: Bool
    ) -> MCPContentProvenance {
        let binding =
            connection.bindingIdentity
        return MCPContentProvenance(
            sourceKind:
                template
                    ? .resourceTemplate
                    : .resource,
            server: binding.server,
            connectionGeneration:
                binding.connectionGeneration,
            rawCatalogRevision:
                binding.rawCatalogRevision,
            agentCatalogViewRevision:
                binding
                    .agentCatalogViewRevision,
            bindingID: binding.bindingID,
            protocolProfile:
                binding.protocolProfile,
            maximumProtocolVersion:
                binding.maximumProtocolVersion,
            negotiatedProtocolVersion:
                binding
                    .negotiatedProtocolVersion,
            resourceURI: uri,
            accountReference:
                connection.reuseIdentity
                    .oauthAccountReference,
            environmentReference:
                connection.reuseIdentity
                    .environmentReference)
    }

    private nonisolated static func taskProvenance(
        _ task: MCPRemoteTaskSnapshot,
        connection: MCPConnectionSnapshot
    ) -> MCPContentProvenance {
        let binding =
            connection.bindingIdentity
        return MCPContentProvenance(
            sourceKind: .task,
            server: binding.server,
            connectionGeneration:
                binding.connectionGeneration,
            rawCatalogRevision:
                binding.rawCatalogRevision,
            agentCatalogViewRevision:
                binding
                    .agentCatalogViewRevision,
            bindingID: binding.bindingID,
            protocolProfile:
                binding.protocolProfile,
            maximumProtocolVersion:
                binding.maximumProtocolVersion,
            negotiatedProtocolVersion:
                binding
                    .negotiatedProtocolVersion,
            remoteName:
                task.operation.rawValue,
            accountReference:
                connection.reuseIdentity
                    .oauthAccountReference,
            environmentReference:
                connection.reuseIdentity
                    .environmentReference)
    }

    private nonisolated static func sha256(
        _ data: Data
    ) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private nonisolated static func validateReturnedURI(
        _ uri: String
    ) throws {
        guard uri.utf8.count
                <= MCPResourceCatalogLimits
                    .maximumURIBytes,
              !uri.contains("\0"),
              !uri.contains(where: \.isNewline),
              let components =
                URLComponents(string: uri),
              let scheme = components.scheme,
              !scheme.isEmpty,
              components.user == nil,
              components.password == nil else {
            throw MCPContentOperationError
                .unsafeURI(uri)
        }
    }

    private nonisolated static func callState(
        _ outcome: ToolExecutionOutcome
    ) -> MCPConversationCallState {
        switch outcome {
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .denied: return .denied
        }
    }
}
#endif
