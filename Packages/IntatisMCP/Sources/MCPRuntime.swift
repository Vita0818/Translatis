import Foundation
import IntatisCore
import IntatisProtocol

public struct MCPInvocationID: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func new() -> MCPInvocationID {
        MCPInvocationID(rawValue: IDGen.random(prefix: "mcpinvoke"))
    }
}

/// Lifecycle causes are explicit so restore/attach/retry can never accidentally
/// reach the connection factory.
public enum MCPRuntimeActivationReason:
    String, Codable, Equatable, Hashable, Sendable {
    case send
    case resume
    case explicitConnect = "explicit_connect"
    case coldRestore = "cold_restore"
    case restore
    case attach
    case retry
    case test
    case authenticate
    case refresh

    public var createsSessionLiveConnection: Bool {
        switch self {
        case .send, .resume, .explicitConnect:
            return true
        case .coldRestore, .restore, .attach, .retry, .test,
                .authenticate, .refresh:
            return false
        }
    }

    public var permitsProviderDispatch: Bool {
        self == .send || self == .resume
    }
}

/// One server in the active invocation view frozen before any startup work.
public struct MCPInvocationServerRequirement: Equatable, Sendable {
    public let identity: MCPConnectionReuseIdentity
    public let agentCatalogViewRevision: MCPAgentCatalogViewRevision
    public let revocationGeneration: MCPRevocationGeneration
    public let serverDefinitionRequired: Bool
    public let attachmentRequired: Bool
    public let callerFingerprint: String
    public let correlation: MCPEventCorrelation

    public init(
        identity: MCPConnectionReuseIdentity,
        agentCatalogViewRevision: MCPAgentCatalogViewRevision,
        revocationGeneration: MCPRevocationGeneration,
        serverDefinitionRequired: Bool,
        attachmentRequired: Bool,
        callerFingerprint: String,
        correlation: MCPEventCorrelation = .init()
    ) {
        self.identity = identity
        self.agentCatalogViewRevision = agentCatalogViewRevision
        self.revocationGeneration = revocationGeneration
        self.serverDefinitionRequired = serverDefinitionRequired
        self.attachmentRequired = attachmentRequired
        self.callerFingerprint = callerFingerprint
        self.correlation = correlation
    }

    /// An attachment may strengthen optional to required but never weaken an
    /// immutable required server definition.
    public var effectiveRequired: Bool {
        serverDefinitionRequired || attachmentRequired
    }
}

public struct MCPInvocationPlan: Equatable, Sendable {
    public let invocationID: MCPInvocationID
    public let sessionID: SessionID
    public let agentID: AgentID
    public let activationReason: MCPRuntimeActivationReason
    public let catalogPublication:
        MCPCatalogPublicationIdentity?
    public let servers: [MCPInvocationServerRequirement]

    public init(
        invocationID: MCPInvocationID = .new(),
        sessionID: SessionID,
        agentID: AgentID,
        activationReason: MCPRuntimeActivationReason,
        catalogPublication:
            MCPCatalogPublicationIdentity? = nil,
        servers: [MCPInvocationServerRequirement]
    ) {
        self.invocationID = invocationID
        self.sessionID = sessionID
        self.agentID = agentID
        self.activationReason = activationReason
        self.catalogPublication = catalogPublication
        self.servers = servers
    }
}

public struct MCPRequiredStartupFailure:
    Error, Equatable, LocalizedError, Sendable {
    public let invocationID: MCPInvocationID
    public let failures: [MCPServerStartupFailure]

    public init(
        invocationID: MCPInvocationID,
        failures: [MCPServerStartupFailure]
    ) {
        self.invocationID = invocationID
        self.failures = failures.filter(\.required).sorted {
            if $0.server.serverID.rawValue
                != $1.server.serverID.rawValue {
                return $0.server.serverID.rawValue
                    < $1.server.serverID.rawValue
            }
            return $0.attachmentID.rawValue
                < $1.attachmentID.rawValue
        }
    }

    /// Non-interactive CLI hosts use this exact non-zero terminal.
    public var cliExitCode: Int32 { 1 }

    /// A required failure is always classified before provider execution.
    public var providerDispatchMustRemainZero: Bool { true }

    public var errorDescription: String? {
        let names = failures.map {
            "\($0.server.serverID.rawValue): \($0.diagnostic.summary)"
        }.joined(separator: "; ")
        return "Required MCP startup failed for invocation \(invocationID): \(names)"
    }
}

public enum MCPRuntimeError: Error, Equatable, LocalizedError {
    case stopped
    case wrongSession(expected: SessionID, actual: SessionID)
    case wrongAgent(expected: AgentID, actual: AgentID)
    case activationDoesNotCreateConnection(MCPRuntimeActivationReason)
    case activationDoesNotPermitProviderDispatch(
        MCPRuntimeActivationReason
    )
    case duplicateFrozenServer(
        server: MCPServerReference,
        attachmentID: MCPAttachmentID
    )
    case malformedRequirement(String)
    case noLiveGeneration(MCPAuthorityPoolKey)
    case admissionSettlementFailed(MCPDiagnosticSummary)
    case catalogPublicationUnavailable

    public var errorDescription: String? {
        switch self {
        case .stopped:
            return "MCP session runtime is stopped"
        case .wrongSession(let expected, let actual):
            return "MCP invocation belongs to session \(actual), expected \(expected)"
        case .wrongAgent(let expected, let actual):
            return "MCP authority belongs to Agent \(actual), expected \(expected)"
        case .activationDoesNotCreateConnection(let reason):
            return "MCP lifecycle action \(reason.rawValue) cannot create a session live connection"
        case .activationDoesNotPermitProviderDispatch(let reason):
            return "MCP lifecycle action \(reason.rawValue) cannot dispatch a provider request"
        case .duplicateFrozenServer(let server, let attachmentID):
            return "MCP invocation duplicates server \(server.serverID) attachment \(attachmentID)"
        case .malformedRequirement(let reason):
            return reason
        case .noLiveGeneration:
            return "MCP refresh/disconnect target has no live exact generation"
        case .admissionSettlementFailed(let diagnostic):
            return diagnostic.summary
        case .catalogPublicationUnavailable:
            return "The MCP invocation has no exact matching catalog/factory publication."
        }
    }
}

public enum MCPHistoricalConnectionStatus:
    String, Codable, Equatable, Hashable, Sendable {
    case disabled
    case setupRequired = "setup_required"
    case authRequired = "auth_required"
    case idle
    case ready
    case degraded
    case failed
    case interrupted
}

/// Secret-free replay facts. They are display/reconciliation evidence only and
/// never create an executable route.
public struct MCPColdRestoreRecord: Equatable, Sendable {
    public let server: MCPServerReference
    public let attachmentID: MCPAttachmentID
    public let historicalStatus: MCPHistoricalConnectionStatus
    public let lastGeneration: MCPConnectionGeneration?
    public let lastRawCatalogRevision: MCPRawCatalogRevision?
    public let diagnostic: MCPDiagnosticSummary?

    public init(
        server: MCPServerReference,
        attachmentID: MCPAttachmentID,
        historicalStatus: MCPHistoricalConnectionStatus,
        lastGeneration: MCPConnectionGeneration? = nil,
        lastRawCatalogRevision: MCPRawCatalogRevision? = nil,
        diagnostic: MCPDiagnosticSummary? = nil
    ) {
        self.server = server
        self.attachmentID = attachmentID
        self.historicalStatus = historicalStatus
        self.lastGeneration = lastGeneration
        self.lastRawCatalogRevision = lastRawCatalogRevision
        self.diagnostic = diagnostic
    }
}

public struct MCPColdRestoreState: Equatable, Sendable {
    public let sessionID: SessionID
    public let records: [MCPColdRestoreRecord]

    public init(
        sessionID: SessionID,
        records: [MCPColdRestoreRecord]
    ) {
        self.sessionID = sessionID
        self.records = records.sorted {
            if $0.server.serverID.rawValue
                != $1.server.serverID.rawValue {
                return $0.server.serverID.rawValue
                    < $1.server.serverID.rawValue
            }
            return $0.attachmentID.rawValue
                < $1.attachmentID.rawValue
        }
    }
}

public enum MCPRuntimeLifecycleState:
    String, Codable, Equatable, Sendable {
    case idle
    case quiescing
    case stopped
}

public struct MCPRuntimeShutdownReport: Equatable, Sendable {
    public let sessionID: SessionID
    public let connectionPool: MCPConnectionPoolShutdownReport
    public let admission: MCPControlPlaneAdmissionShutdownReport

    public init(
        sessionID: SessionID,
        connectionPool: MCPConnectionPoolShutdownReport,
        admission: MCPControlPlaneAdmissionShutdownReport
    ) {
        self.sessionID = sessionID
        self.connectionPool = connectionPool
        self.admission = admission
    }

    public var fullyDrained: Bool {
        admission.unresolvedOperationIDs.isEmpty
    }
}

private enum MCPServerActivationOutcome: Sendable {
    case ready(MCPConnectionSnapshot)
    case failed(MCPServerStartupFailure)
}

/// Exact-session owner for all external MCP client connections.
///
/// This actor has no App, AgentKernel, Cowork, provider, EventLog, or UI
/// dependency. Hosts retain it at the same lifetime as their exact session and
/// inject durable admission/client seams.
public actor MCPRuntime {
    public nonisolated let sessionID: SessionID

    private let fixedFactory:
        (any MCPConnectionClientFactory)?
    private let catalogPublication:
        MCPProductionCatalogPublication?
    private let connectionPool: MCPConnectionPool
    private let admission: MCPControlPlaneAdmission
    private let outputSanitizer:
        any MCPToolResultSanitizer
    private var lifecycle: MCPRuntimeLifecycleState = .idle
    private var publicationOrdinal: UInt64 = 0
    private var latestSnapshot: MCPConnectionSetSnapshot?
    private var latestSnapshotsByAgent:
        [AgentID: MCPConnectionSetSnapshot] = [:]
    private var coldRestoreState: MCPColdRestoreState?
    private var shutdownTask: Task<MCPRuntimeShutdownReport, Never>?

    public init(
        sessionID: SessionID,
        factory: any MCPConnectionClientFactory,
        hardGate: any MCPControlPlaneHardGate,
        consentSource: any MCPExactConsentSource,
        auditSink: any MCPControlPlaneAuditSink,
        outputSanitizer:
            any MCPToolResultSanitizer =
                MCPConservativeToolResultSanitizer()
    ) {
        self.sessionID = sessionID
        fixedFactory = factory
        catalogPublication = nil
        connectionPool = MCPConnectionPool(sessionID: sessionID)
        self.outputSanitizer =
            outputSanitizer
        admission = MCPControlPlaneAdmission(
            sessionID: sessionID,
            hardGate: hardGate,
            consentSource: consentSource,
            auditSink: auditSink)
    }

    public init(
        sessionID: SessionID,
        catalogPublication:
            MCPProductionCatalogPublication,
        hardGate: any MCPControlPlaneHardGate,
        consentSource: any MCPExactConsentSource,
        auditSink: any MCPControlPlaneAuditSink,
        outputSanitizer:
            any MCPToolResultSanitizer =
                MCPConservativeToolResultSanitizer()
    ) {
        self.sessionID = sessionID
        fixedFactory = nil
        self.catalogPublication =
            catalogPublication
        connectionPool = MCPConnectionPool(
            sessionID: sessionID)
        self.outputSanitizer =
            outputSanitizer
        admission = MCPControlPlaneAdmission(
            sessionID: sessionID,
            hardGate: hardGate,
            consentSource: consentSource,
            auditSink: auditSink)
    }

    /// Replays secret-free facts only. This method cannot reach a connection
    /// factory, credential refresh, network transport, local process, or
    /// provider.
    public func reconcileColdRestore(
        _ state: MCPColdRestoreState
    ) throws {
        guard lifecycle == .idle else {
            throw MCPRuntimeError.stopped
        }
        guard state.sessionID == sessionID else {
            throw MCPRuntimeError.wrongSession(
                expected: sessionID,
                actual: state.sessionID)
        }
        coldRestoreState = state
    }

    public func restoredHistoricalState() -> MCPColdRestoreState? {
        coldRestoreState
    }

    public func lifecycleState() -> MCPRuntimeLifecycleState {
        lifecycle
    }

    /// Creates/reuses connections only for Send, Resume, or explicit Connect,
    /// performs the frozen required/optional aggregate gate, then atomically
    /// publishes one immutable connection-set snapshot.
    public func activate(
        _ plan: MCPInvocationPlan
    ) async throws -> MCPConnectionSetSnapshot {
        guard lifecycle == .idle else {
            throw MCPRuntimeError.stopped
        }
        guard plan.activationReason.createsSessionLiveConnection else {
            throw MCPRuntimeError.activationDoesNotCreateConnection(
                plan.activationReason)
        }
        try validateFrozenPlan(plan)

        // Local immutable copies are the active invocation view. Later host
        // attachment/grant/catalog changes cannot mutate this aggregate gate.
        let frozenServers = plan.servers
        let bindingID = MCPBindingID.new()
        let pool = connectionPool
        let admission = admission
        let factory:
            any MCPConnectionClientFactory
        if let catalogPublication {
            factory = try await catalogPublication
                .snapshot(
                    expected:
                        plan.catalogPublication)
                .factory
        } else if let fixedFactory {
            guard plan.catalogPublication == nil else {
                throw MCPRuntimeError
                    .catalogPublicationUnavailable
            }
            factory = fixedFactory
        } else {
            throw MCPRuntimeError
                .catalogPublicationUnavailable
        }
        let sessionID = sessionID
        let activationReason = plan.activationReason
        let outputSanitizer =
            outputSanitizer

        let outcomes = await withTaskGroup(
            of: MCPServerActivationOutcome.self,
            returning: [MCPServerActivationOutcome].self
        ) { group in
            for requirement in frozenServers {
                group.addTask {
                    await Self.activateOne(
                        requirement,
                        sessionID: sessionID,
                        activationReason: activationReason,
                        bindingID: bindingID,
                        pool: pool,
                        admission: admission,
                        factory: factory,
                        outputSanitizer:
                            outputSanitizer)
                }
            }
            var collected: [MCPServerActivationOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        var connections: [MCPConnectionSnapshot] = []
        var requiredFailures: [MCPServerStartupFailure] = []
        var optionalFailures: [MCPServerStartupFailure] = []
        for outcome in outcomes {
            switch outcome {
            case .ready(let connection):
                connections.append(connection)
            case .failed(let failure):
                if failure.required {
                    requiredFailures.append(failure)
                } else {
                    optionalFailures.append(failure)
                }
            }
        }

        // Session/app shutdown may enter while the actor is awaiting startup
        // children. Never publish a post-shutdown capability snapshot.
        guard lifecycle == .idle else {
            throw MCPRuntimeError.stopped
        }
        guard requiredFailures.isEmpty else {
            throw MCPRequiredStartupFailure(
                invocationID: plan.invocationID,
                failures: requiredFailures)
        }

        publicationOrdinal &+= 1
        let snapshot = MCPConnectionSetSnapshot(
            sessionID: sessionID,
            agentID: plan.agentID,
            bindingID: bindingID,
            publicationOrdinal: publicationOrdinal,
            connections: connections,
            optionalFailures: optionalFailures)
        latestSnapshot = snapshot
        latestSnapshotsByAgent[plan.agentID] =
            snapshot
        return snapshot
    }

    /// Provider-facing gate. The operation closure is unreachable when any
    /// frozen effective-required server fails.
    public func withPreparedProviderDispatch<T: Sendable>(
        _ plan: MCPInvocationPlan,
        operation: @escaping @Sendable (
            MCPConnectionSetSnapshot
        ) async throws -> T
    ) async throws -> T {
        guard plan.activationReason.permitsProviderDispatch else {
            throw MCPRuntimeError
                .activationDoesNotPermitProviderDispatch(
                    plan.activationReason)
        }
        let snapshot = try await activate(plan)
        try Task.checkCancellation()
        return try await operation(snapshot)
    }

    public func latestPublishedSnapshot() -> MCPConnectionSetSnapshot? {
        latestSnapshot
    }

    public func latestPublishedSnapshot(
        agentID: AgentID
    ) -> MCPConnectionSetSnapshot? {
        latestSnapshotsByAgent[agentID]
    }

    /// Returns a fresh route for one exact current generation without
    /// publishing it to a provider. Dynamic catalog refresh uses this instead
    /// of retaining a route whose raw-catalog revision becomes stale after the
    /// first successful replacement.
    public func currentConnectionSnapshot(
        identity: MCPConnectionReuseIdentity,
        generation: MCPConnectionGeneration
    ) async throws -> MCPConnectionSnapshot {
        guard lifecycle == .idle else {
            throw MCPRuntimeError.stopped
        }
        guard identity.authority.sessionID == sessionID else {
            throw MCPRuntimeError.wrongSession(
                expected: sessionID,
                actual: identity.authority.sessionID)
        }
        guard let published =
                latestSnapshotsByAgent[
                    identity.authority.agentID],
              let prior = published.connections.first(where: {
                  $0.reuseIdentity == identity
                    && $0.bindingIdentity
                        .connectionGeneration
                        == generation
              }) else {
            throw MCPRuntimeError
                .noLiveGeneration(identity.poolKey)
        }
        return try await connectionPool
            .makeCurrentSnapshot(
                identity: identity,
                generation: generation,
                bindingID: .new(),
                agentCatalogViewRevision:
                    prior.bindingIdentity
                        .agentCatalogViewRevision)
    }

    /// Immediately removes notified categories from every newly created
    /// provider view and republishes the affected Agent's complete immutable
    /// connection set under one fresh binding.
    @discardableResult
    public func markCatalogStaleAndRepublish(
        identity: MCPConnectionReuseIdentity,
        generation: MCPConnectionGeneration,
        revocationGeneration:
            MCPRevocationGeneration,
        kinds: Set<MCPCatalogChangeKind>
    ) async throws -> MCPConnectionSetSnapshot {
        guard lifecycle == .idle else {
            throw MCPRuntimeError.stopped
        }
        guard !kinds.isEmpty,
              identity.authority.sessionID
                == sessionID,
              latestSnapshotsByAgent[
                identity.authority.agentID]?
                .connections.contains(where: {
                    $0.reuseIdentity == identity
                        && $0.bindingIdentity
                            .connectionGeneration
                            == generation
                        && $0.bindingIdentity
                            .revocationGeneration
                            == revocationGeneration
                }) == true else {
            throw MCPRuntimeError
                .noLiveGeneration(identity.poolKey)
        }
        try await connectionPool.markCatalogStale(
            kinds,
            generation: generation,
            expectedRevocationGeneration:
                revocationGeneration)
        return try await republishAgentConnectionSet(
            agentID: identity.authority.agentID)
    }

    /// Publishes a privately staged complete catalog and the affected Agent's
    /// new provider snapshot as one runtime-owned state transition. Old
    /// snapshots remain immutable and their routes fail closed on raw-revision
    /// mismatch.
    @discardableResult
    public func publishDynamicCatalogAndRepublish(
        _ catalog: MCPCompleteCatalogSnapshot,
        identity: MCPConnectionReuseIdentity,
        generation: MCPConnectionGeneration,
        revocationGeneration:
            MCPRevocationGeneration,
        resultingUnavailableKinds:
            Set<MCPCatalogChangeKind> = []
    ) async throws -> MCPConnectionSetSnapshot {
        guard lifecycle == .idle else {
            throw MCPRuntimeError.stopped
        }
        guard identity.authority.sessionID
                == sessionID,
              latestSnapshotsByAgent[
                identity.authority.agentID]?
                .connections.contains(where: {
                    $0.reuseIdentity == identity
                        && $0.bindingIdentity
                            .connectionGeneration
                            == generation
                        && $0.bindingIdentity
                            .revocationGeneration
                            == revocationGeneration
                }) == true else {
            throw MCPRuntimeError
                .noLiveGeneration(identity.poolKey)
        }
        try await connectionPool.publishCompleteCatalog(
            catalog,
            generation: generation,
            expectedRevocationGeneration:
                revocationGeneration,
            resultingUnavailableKinds:
                resultingUnavailableKinds)
        return try await republishAgentConnectionSet(
            agentID: identity.authority.agentID)
    }

    /// User-requested Refresh operates only on an already-live exact
    /// generation. It never calls the client factory.
    @discardableResult
    public func refreshExisting(
        identity: MCPConnectionReuseIdentity,
        generation: MCPConnectionGeneration,
        revocationGeneration: MCPRevocationGeneration,
        callerFingerprint: String,
        correlation: MCPEventCorrelation = .init(),
        discoverCompleteCatalog:
            @escaping @Sendable () async throws
                -> MCPCompleteCatalogSnapshot
    ) async throws -> MCPCompleteCatalogSnapshot {
        guard lifecycle == .idle else {
            throw MCPRuntimeError.stopped
        }
        guard identity.authority.sessionID == sessionID else {
            throw MCPRuntimeError.wrongSession(
                expected: sessionID,
                actual: identity.authority.sessionID)
        }
        guard await connectionPool.currentGeneration(
            for: identity.poolKey) == generation else {
            throw MCPRuntimeError.noLiveGeneration(identity.poolKey)
        }

        let request = MCPControlPlaneAdmissionRequest(
            action: .refresh,
            sessionID: sessionID,
            identity: identity,
            revocationGeneration: revocationGeneration,
            callerFingerprint: callerFingerprint,
            directUserAction: true,
            correlation: correlation)
        let ticket = try await admission.begin(request)
        do {
            let catalog = try await discoverCompleteCatalog()
            try await connectionPool.publishCompleteCatalog(
                catalog,
                generation: generation,
                expectedRevocationGeneration: revocationGeneration)
            _ = try await republishAgentConnectionSet(
                agentID: identity.authority.agentID)
            try await admission.settle(
                ticket,
                status: .succeeded,
                connectionGeneration: generation)
            return catalog
        } catch {
            let diagnostic = Self.diagnostic(
                for: error,
                sanitizer: outputSanitizer)
            try? await admission.settle(
                ticket,
                status: .failed,
                connectionGeneration: generation,
                diagnostic: diagnostic)
            throw error
        }
    }

    /// Explicit disconnect is a user control-plane action and retires every
    /// generation in the exact authority slot.
    public func disconnect(
        identity: MCPConnectionReuseIdentity,
        replacementRevocationGeneration: MCPRevocationGeneration,
        callerFingerprint: String,
        correlation: MCPEventCorrelation = .init()
    ) async throws {
        guard lifecycle == .idle else {
            throw MCPRuntimeError.stopped
        }
        guard identity.authority.sessionID == sessionID else {
            throw MCPRuntimeError.wrongSession(
                expected: sessionID,
                actual: identity.authority.sessionID)
        }
        guard await connectionPool.currentGeneration(
            for: identity.poolKey) != nil else {
            throw MCPRuntimeError.noLiveGeneration(identity.poolKey)
        }

        let request = MCPControlPlaneAdmissionRequest(
            action: .disconnect,
            sessionID: sessionID,
            identity: identity,
            revocationGeneration:
                replacementRevocationGeneration,
            callerFingerprint: callerFingerprint,
            directUserAction: true,
            correlation: correlation)
        let ticket = try await admission.begin(request)
        await connectionPool.revoke(
            authorityKey: identity.poolKey,
            to: replacementRevocationGeneration,
            reason: "User disconnected MCP server")
        try await admission.settle(
            ticket,
            status: .succeeded)
    }

    /// Policy/lease/root/network/credential tightening immediately retires the
    /// old authority. It cannot create a replacement generation.
    public func revokeAuthority(
        _ authorityKey: MCPAuthorityPoolKey,
        to replacementRevocationGeneration: MCPRevocationGeneration,
        reason: String
    ) async {
        await connectionPool.revoke(
            authorityKey: authorityKey,
            to: replacementRevocationGeneration,
            reason: reason)
    }

    public func allConnectionGenerations()
        async -> [MCPConnectionGeneration] {
        await connectionPool.allGenerations()
    }

    public func liveConnectionSnapshots()
        async -> [MCPConnectionSnapshot]
    {
        await connectionPool.liveConnectionSnapshots()
    }

    /// Revokes every live authority slot whose exact immutable reference was
    /// disabled, tombstoned, removed, or replaced by a newer catalog head.
    public func revokeServerReferences(
        _ revocations:
            [MCPCatalogReferenceRevocation]
    ) async {
        guard !revocations.isEmpty else { return }
        let snapshots =
            await connectionPool.liveConnectionSnapshots()
        var byReference:
            [MCPServerReference:
                MCPCatalogReferenceRevocation] = [:]
        for revocation in revocations
            where byReference[revocation.reference] == nil
        {
            byReference[revocation.reference] =
                revocation
        }
        let targets = snapshots.compactMap {
            snapshot -> (
                MCPAuthorityPoolKey,
                MCPCatalogReferenceRevocation
            )? in
            guard let revocation =
                    byReference[
                        snapshot.reuseIdentity.server]
            else { return nil }
            return (
                snapshot.reuseIdentity.poolKey,
                revocation
            )
        }
        await withTaskGroup(of: Void.self) { group in
            for (key, revocation) in targets {
                group.addTask {
                    await self.connectionPool.revoke(
                        authorityKey: key,
                        to: revocation
                            .replacementGeneration,
                        reason:
                            "MCP catalog \(revocation.reason.rawValue)")
                }
            }
        }
    }

    /// Exact-session bounded-owner hook. The surrounding app/CLI supplies the
    /// outer deadline; this method itself waits for every client-owned drain.
    @discardableResult
    public func shutdownAndDrain(
        reason: String
    ) async -> MCPRuntimeShutdownReport {
        if let shutdownTask {
            let report = await shutdownTask.value
            lifecycle = .stopped
            return report
        }

        lifecycle = .quiescing
        let sessionID = sessionID
        let pool = connectionPool
        let admission = admission
        let task = Task {
            await admission.quiesce()
            async let poolReport = pool.shutdownAndDrain(reason: reason)
            async let admissionReport = admission.shutdown(reason: reason)
            return await MCPRuntimeShutdownReport(
                sessionID: sessionID,
                connectionPool: poolReport,
                admission: admissionReport)
        }
        shutdownTask = task
        let report = await task.value
        lifecycle = .stopped
        return report
    }

    private func republishAgentConnectionSet(
        agentID: AgentID
    ) async throws -> MCPConnectionSetSnapshot {
        guard lifecycle == .idle else {
            throw MCPRuntimeError.stopped
        }
        guard let prior =
                latestSnapshotsByAgent[agentID] else {
            throw MCPRuntimeError
                .malformedRequirement(
                    "No MCP provider snapshot is published for the affected Agent.")
        }
        let bindingID = MCPBindingID.new()
        var connections: [MCPConnectionSnapshot] = []
        connections.reserveCapacity(
            prior.connections.count)
        for old in prior.connections {
            try Task.checkCancellation()
            let refreshed = try await connectionPool
                .makeCurrentSnapshot(
                    identity: old.reuseIdentity,
                    generation:
                        old.bindingIdentity
                            .connectionGeneration,
                    bindingID: bindingID,
                    agentCatalogViewRevision:
                        old.bindingIdentity
                            .agentCatalogViewRevision)
            connections.append(refreshed)
        }
        guard lifecycle == .idle else {
            throw MCPRuntimeError.stopped
        }
        publicationOrdinal &+= 1
        let snapshot = MCPConnectionSetSnapshot(
            sessionID: sessionID,
            agentID: agentID,
            bindingID: bindingID,
            publicationOrdinal:
                publicationOrdinal,
            connections: connections,
            optionalFailures:
                prior.optionalFailures)
        latestSnapshot = snapshot
        latestSnapshotsByAgent[agentID] =
            snapshot
        return snapshot
    }

    private func validateFrozenPlan(
        _ plan: MCPInvocationPlan
    ) throws {
        guard plan.sessionID == sessionID else {
            throw MCPRuntimeError.wrongSession(
                expected: sessionID,
                actual: plan.sessionID)
        }

        struct FrozenServerKey: Hashable {
            let server: MCPServerReference
            let attachmentID: MCPAttachmentID
        }
        var seen: Set<FrozenServerKey> = []
        for requirement in plan.servers {
            let identity = requirement.identity
            guard identity.server == identity.authority.server else {
                throw MCPRuntimeError.malformedRequirement(
                    "MCP reuse identity server does not match authority server")
            }
            guard identity.transport == identity.authority.transport else {
                throw MCPRuntimeError.malformedRequirement(
                    "MCP reuse identity transport does not match authority transport")
            }
            guard identity.oauthAccountReference
                == identity.authority.accountReference else {
                throw MCPRuntimeError.malformedRequirement(
                    "MCP OAuth account does not match authority account")
            }
            guard identity.environmentReference
                == identity.authority.environmentReference else {
                throw MCPRuntimeError.malformedRequirement(
                    "MCP environment does not match authority environment")
            }
            guard identity.launchArtifactFingerprint
                == identity.authority.launchArtifactFingerprint else {
                throw MCPRuntimeError.malformedRequirement(
                    "MCP launch identity does not match authority launch identity")
            }
            guard identity.authority.sessionID == sessionID else {
                throw MCPRuntimeError.wrongSession(
                    expected: sessionID,
                    actual: identity.authority.sessionID)
            }
            guard identity.authority.agentID == plan.agentID else {
                throw MCPRuntimeError.wrongAgent(
                    expected: plan.agentID,
                    actual: identity.authority.agentID)
            }
            guard !identity.transportConfigurationFingerprint.isEmpty,
                  !identity.runtimeIdentityFingerprint.isEmpty,
                  !identity.authority.fingerprint.isEmpty,
                  !requirement.callerFingerprint.isEmpty else {
                throw MCPRuntimeError.malformedRequirement(
                    "MCP invocation requirement contains an empty exact identity fingerprint")
            }

            let key = FrozenServerKey(
                server: identity.server,
                attachmentID:
                    identity.authority.attachmentID)
            guard seen.insert(key).inserted else {
                throw MCPRuntimeError.duplicateFrozenServer(
                    server: identity.server,
                    attachmentID:
                        identity.authority.attachmentID)
            }
        }
    }

    private static func activateOne(
        _ requirement: MCPInvocationServerRequirement,
        sessionID: SessionID,
        activationReason: MCPRuntimeActivationReason,
        bindingID: MCPBindingID,
        pool: MCPConnectionPool,
        admission: MCPControlPlaneAdmission,
        factory: any MCPConnectionClientFactory,
        outputSanitizer:
            any MCPToolResultSanitizer
    ) async -> MCPServerActivationOutcome {
        let identity = requirement.identity
        let action: MCPControlPlaneAction =
            identity.transport == .stdio ? .launch : .connect
        let request = MCPControlPlaneAdmissionRequest(
            action: action,
            sessionID: sessionID,
            identity: identity,
            revocationGeneration:
                requirement.revocationGeneration,
            callerFingerprint: requirement.callerFingerprint,
            directUserAction:
                activationReason == .explicitConnect,
            correlation: requirement.correlation)

        var ticket: MCPControlPlaneAdmissionTicket?
        var acquisition: MCPConnectionAcquisition?
        var didSettle = false
        do {
            let admitted = try await admission.begin(request)
            ticket = admitted
            let acquired = try await pool.acquire(
                identity: identity,
                revocationGeneration:
                    requirement.revocationGeneration,
                factory: factory)
            acquisition = acquired
            if !acquired.reused {
                _ = try await acquired.connection.startup()
            }
            try await pool.confirmCurrentReady(acquired)
            let snapshot = try await acquired.connection.makeSnapshot(
                bindingID: bindingID,
                agentCatalogViewRevision:
                    requirement.agentCatalogViewRevision)
            try await admission.settle(
                admitted,
                status: .succeeded,
                connectionGeneration: acquired.generation)
            didSettle = true
            return .ready(snapshot)
        } catch {
            let failureDiagnostic = diagnostic(
                for: error,
                sanitizer: outputSanitizer)
            if let ticket, !didSettle {
                do {
                    try await admission.settle(
                        ticket,
                        status: .failed,
                        connectionGeneration: acquisition?.generation,
                        diagnostic: failureDiagnostic)
                } catch {
                    if let acquisition {
                        await pool.retire(
                            generation: acquisition.generation,
                            reason: "MCP admission settlement failed closed")
                    }
                    return .failed(
                        MCPServerStartupFailure(
                            server: identity.server,
                            attachmentID:
                                identity.authority.attachmentID,
                            required:
                                requirement.effectiveRequired,
                            code: "admission_settlement_failed",
                            diagnostic:
                                Self.diagnostic(
                                    for: error,
                                    sanitizer:
                                        outputSanitizer)))
                }
            }
            if let acquisition {
                await pool.retire(
                    generation: acquisition.generation,
                    reason: "MCP connection activation failed")
            }
            return .failed(
                MCPServerStartupFailure(
                    server: identity.server,
                    attachmentID:
                        identity.authority.attachmentID,
                    required: requirement.effectiveRequired,
                    code: errorCode(for: error),
                    diagnostic: failureDiagnostic))
        }
    }

    private static func errorCode(for error: Error) -> String {
        switch error {
        case let external
            as MCPSanitizedExternalError:
            return "mcp_remote_\(external.category.rawValue)"
        case is MCPControlPlaneAdmissionError:
            return "control_plane_admission_failed"
        case is MCPConnectionError:
            return "connection_startup_failed"
        case is CancellationError:
            return "cancelled"
        default:
            return "mcp_startup_failed"
        }
    }

    private static func diagnostic(
        for error: Error,
        sanitizer:
            any MCPToolResultSanitizer
    )
        -> MCPDiagnosticSummary {
        let raw =
            (error as? LocalizedError)?
                .errorDescription
            ?? String(
                describing:
                    type(of: error))
        let summary =
            (try? sanitizer
                .sanitizeMCPText(raw))
            ?? String(
                String(
                    describing:
                        type(of: error))
                    .prefix(512))
        return MCPDiagnosticSummary(
            code: errorCode(for: error),
            summary:
                String(summary.prefix(512)))
    }
}
