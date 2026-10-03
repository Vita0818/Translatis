import Foundation
import IntatisAgentKernel
import IntatisConversation
import IntatisCore
import IntatisMCP
import IntatisMCPStdio
import IntatisProtocol
import IntatisProviders
import IntatisTools

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private enum MCPCLIProductRuntimeError:
    Error, LocalizedError, Sendable {
    case samplingDisabled
    case stdioContextMissing
    case stdioConsentMissing
    case stdioAttachmentMissing
    case explicitConsentConfirmationRequired

    var errorDescription: String? {
        switch self {
        case .samplingDisabled:
            return "MCP sampling is disabled for this CLI session."
        case .stdioContextMissing:
            return "The exact MCP stdio workspace lease is unavailable."
        case .stdioConsentMissing:
            return "The exact MCP stdio launch consent is unavailable."
        case .stdioAttachmentMissing:
            return "The exact MCP stdio attachment is unavailable."
        case .explicitConsentConfirmationRequired:
            return "Persisting an exact MCP launch/connect consent requires an explicit confirmation."
        }
    }
}

struct MCPCLIConsentConfirmation: Sendable {
    let confirmedAt: Date
    let callerFingerprint: String

    init(callerFingerprint: String) {
        confirmedAt = Date()
        self.callerFingerprint = callerFingerprint
    }
}

private func persistMCPCLIConnectionConsents(
    _ items: [MCPConnectionConsentChallengeItem],
    log: EventLog,
    actorAgentID: AgentID?
) async throws {
    let state = try await MCPDurableSessionState.load(
        from: log)
    var additions: [Event] = []
    for item in items {
        let matches = state.consents.values.filter {
            item.requirement.exactlyMatches($0)
        }
        guard matches.count <= 1 else {
            throw IntatisError.permissionDenied(
                "More than one exact MCP connection consent is active.")
        }
        guard matches.isEmpty else { continue }
        let requirement = item.requirement
        additions.append(.mcpConsentGranted(.init(
            consent: MCPConsent(
                kind: requirement.kind,
                server: requirement.server,
                attachmentID:
                    requirement.attachmentID,
                authorityFingerprint:
                    requirement.authorityFingerprint,
                launchArtifactFingerprint:
                    requirement
                        .launchArtifactFingerprint,
                accountReference:
                    requirement.accountReference,
                environmentReference:
                    requirement.environmentReference,
                policyRevision:
                    requirement.policyRevision),
            actorAgentID: actorAgentID)))
    }
    if !additions.isEmpty {
        _ = try await log.append(additions)
    }
}

private struct MCPCLIConfirmedConsentHandler:
    MCPConnectionConsentChallengeHandler
{
    let log: EventLog
    let sessionID: SessionID
    let agentID: AgentID
    let confirmation: MCPCLIConsentConfirmation

    func resolveConnectionConsent(
        _ challenge: MCPConnectionConsentChallenge
    ) async throws {
        guard challenge.sessionID == sessionID,
              challenge.agentID == agentID,
              !confirmation.callerFingerprint.isEmpty,
              Date().timeIntervalSince(
                confirmation.confirmedAt) <= 60 else {
            throw MCPCLIProductRuntimeError
                .explicitConsentConfirmationRequired
        }
        try await persistMCPCLIConnectionConsents(
            challenge.items,
            log: log,
            actorAgentID: agentID)
    }
}

/// Interactive Code/Cowork sessions install one process-owned handler. The
/// actor is also the prompt queue: simultaneous Cowork dispatches can never
/// interleave consent text or consume one another's answers.
private actor MCPCLIInteractiveConsentHandler:
    MCPConnectionConsentChallengeHandler
{
    let log: EventLog

    init(log: EventLog) {
        self.log = log
    }

    func resolveConnectionConsent(
        _ challenge: MCPConnectionConsentChallenge
    ) async throws {
        guard await log.sessionID == challenge.sessionID,
              !challenge.items.isEmpty,
              challenge.activationReason == .send
                || challenge.activationReason == .resume,
              challenge.items.allSatisfy({
                  $0.identity.authority.sessionID
                      == challenge.sessionID
                      && $0.identity.authority.agentID
                          == challenge.agentID
              }),
              isatty(STDIN_FILENO) == 1 else {
            throw MCPCLIProductRuntimeError
                .explicitConsentConfirmationRequired
        }

        out(
            "\nMCP \(challenge.activationReason.rawValue) requires exact connection consent for \(challenge.items.count) server(s):\n")
        for item in challenge.items {
            let identity = item.identity
            out(
                "  \(identity.server.serverID.rawValue)@\(identity.server.serverRevision.rawValue) transport=\(identity.transport.rawValue) consent=\(item.requirement.kind.rawValue)\n")
        }
        out(
            "Allow these exact MCP authorities for agent \(challenge.agentID.rawValue)? [y/N] ")
        let answer = readLine()?
            .trimmingCharacters(
                in: .whitespacesAndNewlines)
            .lowercased()
        guard answer == "y" || answer == "yes" else {
            throw IntatisError.permissionDenied(
                "The user declined the exact MCP connection consent.")
        }
        try await persistMCPCLIConnectionConsents(
            challenge.items,
            log: log,
            actorAgentID: challenge.agentID)
    }
}

/// Process-memory registry for exact derived MCP workspace leases. It is
/// deliberately separate from Agent leases: Linux local MCP is always given a
/// distinct read-only lease, while the Agent may retain read-write authority.
private final class MCPCLIStdioWorkspaceRegistry:
    @unchecked Sendable {
    private let lock = NSLock()
    private var values: [WorkspaceLeaseID: WorkspaceLease] = [:]

    func register(_ lease: WorkspaceLease) {
        lock.lock()
        values[lease.id] = lease
        lock.unlock()
    }

    func lease(
        matching identity: MCPConnectionReuseIdentity
    ) -> WorkspaceLease? {
        lock.lock()
        defer { lock.unlock() }
        guard let id = identity.authority.workspaceLeaseID,
              let lease = values[id],
              lease.rootIdentity?.matchesCurrentDirectory(
                rootPath: lease.rootPath) == true else {
            return nil
        }
        return lease
    }
}

struct MCPCLIShippingRuntimeHandle: Sendable {
    let shipping: MCPShippingSessionRuntime
    let log: EventLog
    let sessionID: SessionID
    private let workspaceRegistry:
        MCPCLIStdioWorkspaceRegistry

    fileprivate init(
        shipping: MCPShippingSessionRuntime,
        log: EventLog,
        sessionID: SessionID,
        workspaceRegistry:
            MCPCLIStdioWorkspaceRegistry
    ) {
        self.shipping = shipping
        self.log = log
        self.sessionID = sessionID
        self.workspaceRegistry = workspaceRegistry
    }

    func preparedDispatch(
        agentID: AgentID,
        capabilityLease: CapabilityLease,
        workspaceLease: WorkspaceLease,
        baseRegistry: ToolRegistry,
        reason: MCPRuntimeActivationReason
    ) async throws -> (
        MCPPreparedAgentDispatch,
        WorkspaceLease
    ) {
        let mcpLease =
            try MCPProductionStdioWorkspaceLease
                .derive(from: workspaceLease)
        workspaceRegistry.register(mcpLease)
        let prepared =
            try await shipping.snapshots.prepare(
                for: MCPAgentDispatchInput(
                    agentID: agentID,
                    capabilityLease: capabilityLease,
                    workspaceLease: mcpLease,
                    baseRegistry: baseRegistry,
                    activationReason: reason))
        return (prepared, mcpLease)
    }

    func persistConfirmedConsents(
        for plan: MCPInvocationPlan,
        actorAgentID: AgentID?,
        confirmation: MCPCLIConsentConfirmation
    ) async throws {
        guard !confirmation.callerFingerprint.isEmpty,
              Date().timeIntervalSince(
                confirmation.confirmedAt) <= 60 else {
            throw MCPCLIProductRuntimeError
                .explicitConsentConfirmationRequired
        }
        try await persistMCPCLIConnectionConsents(
            plan.servers.map {
                MCPConnectionConsentChallengeItem(
                    identity: $0.identity)
            },
            log: log,
            actorAgentID: actorAgentID)
    }

    func connect(
        agentID: AgentID,
        capabilityLease: CapabilityLease,
        workspaceLease: WorkspaceLease,
        baseRegistry: ToolRegistry,
        confirmation: MCPCLIConsentConfirmation
    ) async throws -> MCPConnectionSetSnapshot {
        let mcpLease =
            try MCPProductionStdioWorkspaceLease
                .derive(from: workspaceLease)
        workspaceRegistry.register(mcpLease)
        return try await shipping.snapshots.connect(
            for: MCPAgentDispatchInput(
                agentID: agentID,
                capabilityLease: capabilityLease,
                workspaceLease: mcpLease,
                baseRegistry: baseRegistry,
                activationReason: .explicitConnect),
            consentHandler:
                MCPCLIConfirmedConsentHandler(
                    log: log,
                    sessionID: sessionID,
                    agentID: agentID,
                    confirmation: confirmation))
    }

    func snapshot(
        agentID: AgentID,
        capabilityLease: CapabilityLease,
        workspaceLease: WorkspaceLease,
        baseRegistry: ToolRegistry,
        reason: MCPRuntimeActivationReason,
        providerCapabilities:
            ToolCallingProviderCapabilities,
        turnResultBudget:
            AgentExternalToolOutputBudget,
        consentConfirmation:
            MCPCLIConsentConfirmation?
    ) async throws -> AgentRequestToolSnapshot {
        let (prepared, mcpLease) =
            try await preparedDispatch(
                agentID: agentID,
                capabilityLease: capabilityLease,
                workspaceLease: workspaceLease,
                baseRegistry: baseRegistry,
                reason: reason)
        if let consentConfirmation {
            try await persistConfirmedConsents(
                for: prepared.plan,
                actorAgentID: agentID,
                confirmation: consentConfirmation)
        }
        // Re-plan at the immediately following dispatch boundary. A concurrent
        // authority change can only make the just-granted consent stale and
        // fail closed; it cannot widen the invocation.
        return try await shipping.snapshots.snapshot(
            for: MCPAgentDispatchInput(
                agentID: agentID,
                capabilityLease: capabilityLease,
                workspaceLease: mcpLease,
                baseRegistry: baseRegistry,
                activationReason: reason),
            providerCapabilities:
                providerCapabilities,
            turnResultBudget:
                turnResultBudget)
    }

    func liveConnectionSnapshots()
        async -> [MCPConnectionSnapshot] {
        await shipping.owner.liveConnectionSnapshots()
    }

    @discardableResult
    func reloadCatalog()
        async throws
        -> MCPProcessCatalogPublicationReport {
        try await shipping.reloadCatalog()
    }

    func refresh(
        connection: MCPConnectionSnapshot,
        callerFingerprint: String
    ) async throws -> MCPCompleteCatalogSnapshot {
        try await shipping.refreshExisting(
            identity: connection.reuseIdentity,
            generation:
                connection.bindingIdentity
                    .connectionGeneration,
            revocationGeneration:
                connection.bindingIdentity
                    .revocationGeneration,
            callerFingerprint: callerFingerprint)
    }

    func disconnect(
        connection: MCPConnectionSnapshot,
        callerFingerprint: String
    ) async throws {
        try await shipping.disconnect(
            identity: connection.reuseIdentity,
            replacementRevocationGeneration:
                MCPRevocationGeneration(
                    rawValue: IDGen.random(
                        prefix: "mcprevocation")),
            callerFingerprint: callerFingerprint)
    }

    @discardableResult
    func shutdown(reason: String) async
        -> MCPRuntimeShutdownReport {
        await shipping.shutdown(reason: reason)
    }
}

extension MCPCLIContext {
    func makeShippingRuntime(
        log: EventLog,
        workspaceRoot: URL,
        allowsInteractiveConsent: Bool = false
    ) async throws -> MCPCLIShippingRuntimeHandle {
        let sessionID = await log.sessionID
        let catalog = try await catalogStore.load()
        let durable =
            try await MCPDurableSessionState.load(
                from: log)
        let attachedServers = Set(
            durable.attachments.values.map(\.server))
        if catalog.definitions.contains(where: {
            attachedServers.contains($0.reference)
                && configurationUsesSecret(
                    $0.configuration)
        }) {
            try await unlockSecrets(
                createIfMissing: false)
        }
        let workspaceRegistry =
            MCPCLIStdioWorkspaceRegistry()
        let outputRedactor =
            MCPResolvedSecretRedactor()
        let baseSecretResolver =
            self.resolveSecret
        let runtimeSecretResolver:
            MCPProductionSecretResolver = {
                reference in
                let value =
                    try await baseSecretResolver(
                        reference)
                outputRedactor
                    .registerMCPSecretRedactionValue(
                        value)
                return value
            }
        let issuer = MCPStdioLaunchTicketIssuer {
            request in
            guard request.purpose == .sessionConnect,
                  request.authority.sessionID == sessionID,
                  request.workspaceLease.rootIdentity?
                    .matchesCurrentDirectory(
                        rootPath:
                            request.workspaceLease.rootPath)
                    == true else {
                throw MCPManagedPipeError
                    .authorizationBindingMismatch
            }
            let state =
                try await MCPDurableSessionState.load(
                    from: log)
            guard state.attachments.values.contains(
                where: {
                    $0.attachmentID
                        == request.authority.attachmentID
                        && $0.server
                            == request.authority.server
                }) else {
                throw MCPCLIProductRuntimeError
                    .stdioAttachmentMissing
            }
            let matchingConsents =
                state.consents.values.filter {
                    $0.kind == .launch
                        && $0.server
                            == request.authority.server
                        && $0.attachmentID
                            == request.authority
                                .attachmentID
                        && $0.authorityFingerprint
                            == request.authority
                                .fingerprint
                        && $0.launchArtifactFingerprint
                            == request.configuration
                                .launchArtifact
                                .fingerprint
                        && $0.environmentReference
                            == request.authority
                                .environmentReference
                        && $0.policyRevision
                            == request.authority
                                .attachmentPolicyRevision
                }
            guard matchingConsents.count == 1 else {
                throw MCPCLIProductRuntimeError
                    .stdioConsentMissing
            }
            let environment =
                try await MCPStdioEnvironmentResolver.resolve(
                    request.configuration,
                    secretResolver:
                        runtimeSecretResolver)
            return MCPStdioHostAuthorization(
                decisionID: IDGen.random(
                    prefix: "mcpdecision"),
                operationID: request.operationID,
                authorityFingerprint:
                    request.authority.fingerprint,
                launchArtifactFingerprint:
                    request.configuration
                        .launchArtifact.fingerprint,
                workspaceLeaseID:
                    request.workspaceLease.id,
                expiresAt:
                    Date().addingTimeInterval(30),
                resolvedEnvironment: environment)
        }
        let stdio =
            MCPManagedStdioProductionFactory(
                ticketIssuer: issuer,
                secretRedactionRegistrar:
                    outputRedactor
            ) { _, identity, _ in
                guard let lease =
                        workspaceRegistry.lease(
                            matching: identity) else {
                    throw MCPCLIProductRuntimeError
                        .stdioContextMissing
                }
                return MCPProductionStdioLaunchContext(
                    purpose: .sessionConnect,
                    workspaceLease: lease)
            }
        let events = MCPEventLogBrokerEventSink(
            log: log)
        let payloads =
            MCPSecretBackedBrokerPayloadStore(
                secretStore: secretStore)
        let services =
            MCPShippingConnectionServicesRegistry(
                events: events,
                payloadStore: payloads,
                sampling: MCPSamplingHostServices(
                    policy: MCPSamplingPolicy(),
                    reviewer:
                        MCPDenyAllSamplingReviewService(),
                    inference:
                        MCPProviderSamplingInferenceService {
                            _ in
                            throw MCPCLIProductRuntimeError
                                .samplingDisabled
                        }),
                elicitation: MCPElicitationHostServices(
                    policy: MCPElicitationPolicy(),
                    reviewer:
                        MCPDenyAllElicitationReviewService()))
        let rootIdentity =
            WorkspaceRootIdentity.capture(
                rootPath:
                    workspaceRoot.standardizedFileURL.path)
        let runtimeFingerprint =
            MCPHostDigest.sha256([
                IntatisHostApplication.identity.temporaryPrefix(
                    "cli-mcp-runtime-v1"),
                sessionID.rawValue,
                workspaceRoot.standardizedFileURL.path,
                rootIdentity.map {
                    MCPHostDigest.workspaceRootIdentity($0)
                } ?? "missing-root",
            ])
        let artifactSink =
            try MCPArtifactStoreToolSink(
                root: root
                    .appendingPathComponent(
                        "sessions",
                        isDirectory: true)
                    .appendingPathComponent(
                        sessionID.rawValue,
                        isDirectory: true)
                    .appendingPathComponent(
                        "artifacts",
                        isDirectory: true))
        let shipping =
            try await MCPShippingSessionRuntime.make(
                sessionID: sessionID,
                hostProfile: hostProfile,
                clientVersion: IntatisHostApplication.identity
                    .temporaryPrefix("cli"),
                runtimeIdentityFingerprint:
                    runtimeFingerprint,
                log: log,
                catalogStore: catalogStore,
                services: services,
                resolveSecret:
                    runtimeSecretResolver,
                buildStdio: stdio.transportBuilder(),
                buildOAuth: oauth.providerBuilder(),
                consentHandler:
                    allowsInteractiveConsent
                    ? MCPCLIInteractiveConsentHandler(
                        log: log)
                    : nil,
                resultConverter:
                    MCPToolResultConverter(
                        sanitizer: outputRedactor,
                        artifactSink: artifactSink),
                resourceConverter:
                    MCPResourceContentConverter(
                        sanitizer: outputRedactor,
                        artifactSink: artifactSink),
                outputRedactor: outputRedactor)
        return MCPCLIShippingRuntimeHandle(
            shipping: shipping,
            log: log,
            sessionID: sessionID,
            workspaceRegistry: workspaceRegistry)
    }
}
