#if canImport(SwiftUI)
import AppKit
import Foundation
import IntatisAgentKernel
import IntatisArtifacts
import IntatisConversation
import IntatisCore
import IntatisMCP
import IntatisProtocol
import IntatisTools

extension AppEnvironment {
    func mcpConversationContentHost(
        for viewModel: CodeViewModel
    ) -> MCPConversationContentHost {
        makeMCPConversationContentHost(
            kind: .code,
            sessionID: viewModel.sessionID,
            log: viewModel.mcpEventLog,
            artifactStore:
                viewModel.mcpArtifactStore,
            workspacePaths: {
                viewModel.mcpWorkspacePaths
            },
            agents: {
                try await viewModel.mcpProjectAgents()
                    .filter(\.supportsNativeCodexMCP)
            },
            dispatchInput: { descriptor, reason in
                try await viewModel.mcpDispatchInput(
                    for: descriptor,
                    reason: reason)
            },
            promptInsertion: { insertion in
                try await viewModel
                    .acceptMCPPromptInsertion(
                        insertion)
            },
            externalContext: {
                contexts, selectedByAgentID in
                guard selectedByAgentID
                        == AgentID(
                            rawValue: "Coder")
                else {
                    throw IntatisError
                        .permissionDenied(
                            "The selected MCP instructions belong to a different agent.")
                }
                try viewModel
                    .stageMCPExternalContexts(
                        contexts)
            })
    }

    func mcpConversationContentHost(
        for viewModel: CoworkViewModel
    ) -> MCPConversationContentHost {
        makeMCPConversationContentHost(
            kind: .cowork,
            sessionID: viewModel.sessionID,
            log: viewModel.mcpEventLog,
            artifactStore:
                viewModel.mcpArtifactStore,
            workspacePaths: {
                viewModel.mcpWorkspacePaths
            },
            agents: {
                try await viewModel.mcpProjectAgents()
                    .filter(\.supportsNativeCodexMCP)
            },
            dispatchInput: { descriptor, reason in
                try await viewModel.mcpDispatchInput(
                    for: descriptor,
                    reason: reason)
            },
            promptInsertion: { insertion in
                try await viewModel
                    .acceptMCPPromptInsertion(
                        insertion)
            },
            externalContext: {
                contexts, selectedByAgentID in
                try viewModel
                    .stageMCPExternalContexts(
                        contexts,
                        selectedByAgentID:
                            selectedByAgentID)
            })
    }

    private func makeMCPConversationContentHost(
        kind: SessionKind,
        sessionID: SessionID,
        log: EventLog,
        artifactStore: ArtifactStore,
        workspacePaths:
            @escaping @MainActor @Sendable () async
                -> [String],
        agents:
            @escaping @MainActor @Sendable () async throws
                -> [MCPProductAgentDescriptor],
        dispatchInput:
            @escaping @MainActor @Sendable (
                MCPProductAgentDescriptor,
                MCPRuntimeActivationReason
            ) async throws -> MCPAgentDispatchInput,
        promptInsertion:
            @escaping @MainActor @Sendable (
                MCPPromptInsertion
            ) async throws -> Void,
        externalContext:
            @escaping @MainActor @Sendable (
                [MCPUntrustedExternalContext],
                AgentID
            ) async throws -> Void
    ) -> MCPConversationContentHost {
        let service = mcp
        let host =
            runtimeManager
                .mcpConversationRuntimeHost(
                    kind: kind,
                    sessionID: sessionID
                ) { [weak self] in
                    MCPConversationRuntimeHost(
                        sessionID: sessionID,
                        log: log,
                        catalogStore:
                            service.catalogStore,
                        artifactStore:
                            artifactStore,
                        runtimeProvider: {
                            [weak self] in
                            guard let self else {
                                throw IntatisError.io(
                                    "The application MCP runtime owner is unavailable.")
                            }
                            return try await self
                                .mcpSessionRuntime(
                                    kind: kind,
                                    sessionID:
                                        sessionID,
                                    log: log,
                                    workspacePaths:
                                        await workspacePaths())
                        },
                        agentProvider: agents,
                        dispatchInputProvider:
                            dispatchInput,
                        promptInsertionHandler:
                            promptInsertion,
                        externalContextHandler:
                            externalContext)
                }
        return host.contentHost()
    }

    func mcpProjectSettingsHost(
        for viewModel: CodeViewModel
    ) -> MCPProjectSettingsHost {
        makeMCPProjectSettingsHost(
            kind: .code,
            sessionID: viewModel.sessionID,
            log: viewModel.mcpEventLog,
            workspacePaths: {
                viewModel.mcpWorkspacePaths
            },
            agents: {
                try await viewModel.mcpProjectAgents()
            },
            dispatchInput: { descriptor, reason in
                try await viewModel.mcpDispatchInput(
                    for: descriptor,
                    reason: reason)
            },
            authorityChanged: {
                await viewModel.nativeMCPAuthorityDidChange()
            })
    }

    func mcpProjectSettingsHost(
        for viewModel: CoworkViewModel
    ) -> MCPProjectSettingsHost {
        makeMCPProjectSettingsHost(
            kind: .cowork,
            sessionID: viewModel.sessionID,
            log: viewModel.mcpEventLog,
            workspacePaths: {
                viewModel.mcpWorkspacePaths
            },
            agents: {
                try await viewModel.mcpProjectAgents()
            },
            dispatchInput: { descriptor, reason in
                try await viewModel.mcpDispatchInput(
                    for: descriptor,
                    reason: reason)
            },
            authorityChanged: {
                await viewModel.nativeMCPAuthorityDidChange()
            })
    }

    private func makeMCPProjectSettingsHost(
        kind: SessionKind,
        sessionID: SessionID,
        log: EventLog,
        workspacePaths:
            @escaping @MainActor @Sendable () async
                -> [String],
        agents:
            @escaping @MainActor @Sendable () async throws
                -> [MCPProductAgentDescriptor],
        dispatchInput:
            @escaping @MainActor @Sendable (
                MCPProductAgentDescriptor,
                MCPRuntimeActivationReason
            ) async throws -> MCPAgentDispatchInput,
        authorityChanged:
            @escaping @MainActor @Sendable () async -> Void
    ) -> MCPProjectSettingsHost {
        let service = mcp
        return MCPProjectSettingsHost.eventLogBacked(
            sessionID: sessionID,
            log: log,
            management: service.management,
            agents: {
                try await agents()
            },
            templates: {
                Self.mcpAccessTemplates()
            },
            resolveAuthorityFingerprint: {
                [weak self] attachment, descriptor, revocation in
                guard let self else {
                    throw IntatisError.io(
                        "The application MCP runtime owner is unavailable.")
                }
                let paths = await workspacePaths()
                let runtime = try await self.mcpSessionRuntime(
                    kind: kind,
                    sessionID: sessionID,
                    log: log,
                    workspacePaths: paths)
                let input = try await dispatchInput(
                    descriptor,
                    .explicitConnect)
                let state =
                    try await MCPDurableSessionState.load(
                        from: log)
                guard state.attachments[
                    attachment.attachmentID] == attachment else {
                    throw IntatisError.permissionDenied(
                        "The exact MCP attachment changed before the grant was saved.")
                }
                let catalog =
                    try await service.catalogStore.load()
                guard let definition =
                        catalog.definition(
                            for: attachment.server),
                      definition.configuration.enabled,
                      !catalog.isTombstoned(
                        attachment.server) else {
                    throw IntatisError.permissionDenied(
                        "The immutable MCP server revision is no longer executable.")
                }
                let rootFingerprint =
                    input.workspaceLease?.rootIdentity.map {
                        MCPHostDigest
                            .workspaceRootIdentity($0)
                    }
                let workspaceLeasePolicyFingerprint =
                    MCPConnectionIdentityBuilder
                        .workspaceLeasePolicyFingerprint(
                            input.workspaceLease)
                let sandboxPolicyFingerprint =
                    MCPConnectionIdentityBuilder
                        .sandboxPolicyFingerprint(
                            hostProfile:
                                service.hostProfile,
                            transport:
                                definition.configuration
                                    .transport.kind,
                            sandboxProfileRevision:
                                attachment.policy
                                    .revision,
                            networkPolicyRevision:
                                state
                                    .networkPolicyRevision
                                    ?? attachment
                                        .policy
                                        .revision,
                            workspaceLeasePolicyFingerprint:
                                workspaceLeasePolicyFingerprint)
                let runtimeIdentityFingerprint =
                    await runtime.snapshots.planner
                        .runtimeIdentityFingerprint
                let requirement =
                    try MCPConnectionIdentityBuilder.build(
                        definition: definition,
                        inputs:
                            MCPConnectionAuthorityInputs(
                                sessionID:
                                    sessionID,
                                agentID:
                                    descriptor
                                        .agentID,
                                attachment:
                                    attachment,
                                capabilityLeaseID:
                                    input
                                        .capabilityLease
                                        .id,
                                capabilityTaskID:
                                    input
                                        .capabilityLease
                                        .taskID,
                                workspaceLeaseID:
                                    input
                                        .workspaceLease?
                                        .id,
                                workspaceRootIdentityFingerprint:
                                    rootFingerprint,
                                workspaceLeasePolicyFingerprint:
                                    workspaceLeasePolicyFingerprint,
                                accountReference:
                                    definition
                                        .configuration
                                        .transport
                                        .oauthAccountReference,
                                rootsPolicyRevision:
                                    state
                                        .rootsPolicyRevision
                                        ?? attachment
                                            .policy
                                            .filter
                                            .revision,
                                networkPolicyRevision:
                                    state
                                        .networkPolicyRevision
                                        ?? attachment
                                            .policy
                                            .revision,
                                sandboxProfileRevision:
                                    attachment
                                        .policy
                                        .revision,
                                sandboxPolicyFingerprint:
                                    sandboxPolicyFingerprint,
                                revocationGeneration:
                                    revocation,
                                hostProfile:
                                    service
                                        .hostProfile,
                                runtimeIdentityFingerprint:
                                    runtimeIdentityFingerprint))
                return requirement.identity.authority
                    .fingerprint
            },
            explicitConnect: {
                [weak self] attachment, descriptor in
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
                            await workspacePaths())
                let input = try await dispatchInput(
                    descriptor,
                    .explicitConnect)
                let prepared =
                    try await runtime.snapshots.prepare(
                        for: input)
                guard prepared.plan.servers.contains(
                    where: {
                        $0.identity.authority
                            .attachmentID
                            == attachment.attachmentID
                            && $0.identity.server
                                == attachment.server
                    }) else {
                    throw IntatisError.permissionDenied(
                        "The selected Agent has no exact active grant for this MCP attachment.")
                }
                let snapshot =
                    try await runtime.snapshots.connect(
                        for: input)
                await service.synchronizeRuntimeObservation(
                    sessionID: sessionID,
                    owner: runtime.owner)
                return snapshot
            },
            disconnect: {
                [weak self] attachment in
                guard let self,
                      let runtime =
                        await self.runtimeManager
                            .cachedMCPRuntime(
                                kind: kind,
                                sessionID: sessionID)
                else {
                    return
                }
                let targets =
                    await runtime.owner
                        .liveConnectionSnapshots()
                        .filter {
                            $0.reuseIdentity.authority
                                .attachmentID
                                == attachment.attachmentID
                                && $0.reuseIdentity
                                    .server
                                    == attachment.server
                        }
                let replacement =
                    MCPRevocationGeneration(
                        rawValue:
                            IDGen.random(
                                prefix:
                                    "mcprevocation_disconnect"))
                var firstFailure: Error?
                for target in targets {
                    do {
                        try await runtime.disconnect(
                            identity:
                                target.reuseIdentity,
                            replacementRevocationGeneration:
                                replacement,
                            callerFingerprint:
                                MCPHostDigest.sha256([
                                    IntatisHostApplication.identity
                                        .temporaryPrefix(
                                            "mac-project-disconnect-v1"),
                                    sessionID.rawValue,
                                    target.reuseIdentity
                                        .authority.agentID.rawValue,
                                    target.reuseIdentity
                                        .authority.fingerprint,
                                    target.bindingIdentity
                                        .connectionGeneration.rawValue,
                                ]))
                    } catch {
                        if firstFailure == nil {
                            firstFailure = error
                        }
                    }
                }
                await service.synchronizeRuntimeObservation(
                    sessionID: sessionID,
                    owner: runtime.owner)
                if let firstFailure {
                    throw firstFailure
                }
            },
            refresh: {
                [weak self] attachment, descriptor in
                guard let self,
                      let runtime =
                        await self.runtimeManager
                            .cachedMCPRuntime(
                                kind: kind,
                                sessionID: sessionID)
                else {
                    throw MCPRuntimeError
                        .activationDoesNotCreateConnection(
                            .refresh)
                }
                let targets =
                    await runtime.owner
                        .liveConnectionSnapshots()
                        .filter {
                            $0.reuseIdentity.authority
                                .attachmentID
                                == attachment.attachmentID
                                && $0.reuseIdentity
                                    .server
                                    == attachment.server
                                && $0.reuseIdentity
                                    .authority.agentID
                                    == descriptor.agentID
                        }
                guard !targets.isEmpty else {
                    // Refresh is deliberately incapable of creating an idle
                    // attachment or replacement connection generation.
                    throw MCPRuntimeError
                        .activationDoesNotCreateConnection(
                            .refresh)
                }
                for target in targets {
                    _ = try await runtime
                        .refreshExisting(
                            identity:
                                target.reuseIdentity,
                            generation:
                                target.bindingIdentity
                                    .connectionGeneration,
                            revocationGeneration:
                                target.bindingIdentity
                                    .revocationGeneration,
                            callerFingerprint:
                                MCPHostDigest.sha256([
                                    IntatisHostApplication.identity
                                        .temporaryPrefix(
                                            "mac-project-refresh-v1"),
                                    sessionID.rawValue,
                                    descriptor.agentID.rawValue,
                                    target.reuseIdentity
                                        .authority.fingerprint,
                                    target.bindingIdentity
                                        .connectionGeneration.rawValue,
                                ]))
                }
                await service.synchronizeRuntimeObservation(
                    sessionID: sessionID,
                    owner: runtime.owner)
                guard let published =
                        await runtime.owner
                            .latestPublishedSnapshot(
                                agentID:
                                    descriptor.agentID)
                else {
                    throw MCPContentOperationError
                        .staleRequest
                }
                return published
            },
            rootAuthorities: {
                let descriptors =
                    try await agents()
                var roots:
                    [WorkspaceLeaseID:
                        MCPRootAuthoritySummary] = [:]
                for descriptor in descriptors
                    where !descriptor
                        .isPermissionReviewer
                {
                    let input =
                        try await dispatchInput(
                            descriptor,
                            .explicitConnect)
                    guard let lease =
                            input.workspaceLease,
                          let identity =
                            lease.rootIdentity,
                          identity
                            .matchesCurrentDirectory(
                                rootPath:
                                    lease.rootPath)
                    else {
                        throw IntatisError
                            .permissionDenied(
                                "An active Agent workspace lease has no current exact root identity.")
                    }
                    let summary =
                        MCPRootAuthoritySummary(
                            workspaceID:
                                lease.workspaceID,
                            workspaceLeaseID:
                                lease.id,
                            rootIdentityFingerprint:
                                MCPHostDigest
                                    .workspaceRootIdentity(
                                        identity),
                            access:
                                lease.access)
                    if let existing =
                            roots[lease.id],
                       existing != summary {
                        throw IntatisError.config(
                            "The same MCP workspace lease ID resolved to more than one root authority.")
                    }
                    roots[lease.id] = summary
                }
                return roots.values.sorted {
                    $0.workspaceLeaseID.rawValue
                        < $1.workspaceLeaseID.rawValue
                }
            },
            authorityChanged: {
                await authorityChanged()
            },
            inspect: {
                [weak self] in
                guard let self,
                      let runtime =
                        await self.runtimeManager
                            .cachedMCPRuntime(
                                kind: kind,
                                sessionID: sessionID)
                else {
                    return MCPProjectRuntimeInspection(
                        snapshot: nil,
                        metrics: MCPMetricsSnapshot(
                            counters: [:],
                            latencyBucketsMilliseconds: [],
                            latencyCounts: [],
                            overflowedSeries: 0),
                        diagnostics: [])
                }
                let candidates =
                    (try? await agents()) ?? []
                var snapshot:
                    MCPConnectionSetSnapshot?
                for descriptor in candidates
                    where !descriptor
                        .isPermissionReviewer
                {
                    if let exact =
                            await runtime.owner
                                .latestPublishedSnapshot(
                                    agentID:
                                        descriptor.agentID)
                    {
                        snapshot = exact
                        break
                    }
                }
                return MCPProjectRuntimeInspection(
                    snapshot: snapshot,
                    metrics:
                        await runtime.owner
                            .metricsSnapshot(),
                    diagnostics:
                        await runtime.owner
                            .diagnosticsSnapshot())
            })
    }

    private nonisolated static func mcpAccessTemplates()
        -> [MCPProductAgentAccessTemplate]
    {
        let unrestricted = MCPCatalogFilter(
            revision:
                MCPPolicyRevision(
                    rawValue:
                        "mcppolicy_template_unrestricted_v1"))
        return [
            MCPProductAgentAccessTemplate(
                id: "interactive-full-v1",
                name: "Interactive — complete MCP surface",
                capabilityCeiling:
                    Set(
                        MCPServerEditorCapabilities.all),
                approvalModeCeiling: .prompt,
                filter: unrestricted),
            MCPProductAgentAccessTemplate(
                id: "content-browser-v1",
                name: "Content — resources, prompts, completions",
                capabilityCeiling: [
                    .resources,
                    .prompts,
                    .completions,
                    .subscriptions,
                    .progress,
                    .logging,
                    .roots,
                ],
                approvalModeCeiling: .prompt,
                filter: unrestricted),
            MCPProductAgentAccessTemplate(
                id: "tools-and-tasks-v1",
                name: "Actions — tools and remote tasks",
                capabilityCeiling: [
                    .tools,
                    .tasks,
                    .progress,
                    .logging,
                ],
                approvalModeCeiling: .prompt,
                filter: unrestricted),
            MCPProductAgentAccessTemplate(
                id: "callbacks-v1",
                name: "Callbacks — sampling and elicitation",
                capabilityCeiling: [
                    .sampling,
                    .elicitation,
                    .tasks,
                    .progress,
                    .logging,
                ],
                approvalModeCeiling: .prompt,
                filter: unrestricted),
        ]
    }
}
#endif
