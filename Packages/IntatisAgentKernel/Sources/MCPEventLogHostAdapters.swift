#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisAgentKernel requires CryptoKit or swift-crypto")
#endif
import Foundation
import IntatisConversation
import IntatisCore
import IntatisMCP
import IntatisProtocol
import IntatisProviders
import IntatisTools

/// EventLog-first projection used by shipping MCP App/CLI hosts.
///
/// The projection is intentionally rebuilt from complete-known history at
/// every authority-changing boundary. It is small, secret-free, and never
/// treats a UI cache or a global current selection as executable authority.
public struct MCPDurableSessionState: Sendable {
    public var attachments:
        [MCPAttachmentID: MCPServerAttachment]
    public var grants: [MCPGrantID: MCPGrant]
    public var consents: [MCPConsentID: MCPConsent]
    public var rememberedApprovals:
        [MCPRememberedApprovalID:
            MCPRememberedToolApproval]
    public var revocationGenerations:
        [MCPAttachmentID: MCPRevocationGeneration]
    public var revokedCapabilityLeaseIDs:
        Set<CapabilityLeaseID>
    public var revokedWorkspaceLeaseIDs:
        Set<WorkspaceLeaseID>
    public var rootsPolicyRevision:
        MCPPolicyRevision?
    public var networkPolicyRevision:
        MCPPolicyRevision?
    public var ambientRevocationGeneration:
        MCPRevocationGeneration?

    public init(
        attachments:
            [MCPAttachmentID: MCPServerAttachment] = [:],
        grants: [MCPGrantID: MCPGrant] = [:],
        consents: [MCPConsentID: MCPConsent] = [:],
        rememberedApprovals:
            [MCPRememberedApprovalID:
                MCPRememberedToolApproval] = [:],
        revocationGenerations:
            [MCPAttachmentID: MCPRevocationGeneration] = [:],
        revokedCapabilityLeaseIDs:
            Set<CapabilityLeaseID> = [],
        revokedWorkspaceLeaseIDs:
            Set<WorkspaceLeaseID> = [],
        rootsPolicyRevision:
            MCPPolicyRevision? = nil,
        networkPolicyRevision:
            MCPPolicyRevision? = nil,
        ambientRevocationGeneration:
            MCPRevocationGeneration? = nil
    ) {
        self.attachments = attachments
        self.grants = grants
        self.consents = consents
        self.rememberedApprovals =
            rememberedApprovals
        self.revocationGenerations = revocationGenerations
        self.revokedCapabilityLeaseIDs =
            revokedCapabilityLeaseIDs
        self.revokedWorkspaceLeaseIDs =
            revokedWorkspaceLeaseIDs
        self.rootsPolicyRevision =
            rootsPolicyRevision
        self.networkPolicyRevision =
            networkPolicyRevision
        self.ambientRevocationGeneration =
            ambientRevocationGeneration
    }

    public static func load(
        from log: EventLog
    ) async throws -> MCPDurableSessionState {
        let replay = try await log.replayForProjectionChecked()
        guard replay.hasCompleteKnownHistory else {
            throw EventLogError.unsupportedEventTypes
        }
        return project(replay.envelopes)
    }

    public static func project(
        _ envelopes: [Envelope]
    ) -> MCPDurableSessionState {
        var result = MCPDurableSessionState()
        for envelope in envelopes {
            switch envelope.event {
            case .mcpServerAttached(let payload):
                result.attachments[
                    payload.attachment.attachmentID] =
                    payload.attachment
            case .mcpServerDetached(let payload):
                result.attachments.removeValue(
                    forKey: payload.attachmentID)
                result.grants = result.grants.filter {
                    $0.value.attachmentID
                        != payload.attachmentID
                }
                result.consents = result.consents.filter {
                    $0.value.attachmentID
                        != payload.attachmentID
                }
                result.revocationGenerations[
                    payload.attachmentID] =
                    payload.revocationGeneration
            case .mcpAttachmentPolicyUpdated(let payload):
                if let previous = result.attachments[
                    payload.attachmentID] {
                    result.attachments[
                        payload.attachmentID] =
                        MCPServerAttachment(
                            attachmentID:
                                previous.attachmentID,
                            server: previous.server,
                            policy: payload.policy,
                            source: previous.source,
                            sourceFingerprint:
                                previous.sourceFingerprint)
                }
                result.revocationGenerations[
                    payload.attachmentID] =
                    payload.revocationGeneration
            case .mcpConsentGranted(let payload):
                result.consents[
                    payload.consent.consentID] =
                    payload.consent
            case .mcpConsentRevoked(let payload):
                result.consents.removeValue(
                    forKey: payload.consentID)
                result.revocationGenerations[
                    payload.attachmentID] =
                    payload.revocationGeneration
            case .mcpGrantGranted(let payload):
                result.grants[
                    payload.grant.grantID] =
                    payload.grant
            case .mcpGrantRevoked(let payload):
                result.grants.removeValue(
                    forKey: payload.grantID)
            case .mcpRememberedApprovalGranted(
                    let payload):
                result.rememberedApprovals[
                    payload.approval.approvalID] =
                    payload.approval
            case .mcpRememberedApprovalRevoked(
                    let payload):
                result.rememberedApprovals.removeValue(
                    forKey: payload.approvalID)
            case .capabilityLeaseCreated(let payload):
                result.revokedCapabilityLeaseIDs.remove(
                    payload.lease.id)
            case .capabilityLeaseRevoked(let payload):
                result.revokedCapabilityLeaseIDs.insert(
                    payload.leaseID)
            case .workspaceLeaseGranted(let payload):
                result.revokedWorkspaceLeaseIDs.remove(
                    payload.lease.id)
            case .workspaceLeaseRevoked(let payload):
                result.revokedWorkspaceLeaseIDs.insert(
                    payload.leaseID)
            case .mcpRootsPolicyUpdated(let payload):
                result.rootsPolicyRevision =
                    payload.revision
                result.ambientRevocationGeneration =
                    payload.revocationGeneration
            case .mcpNetworkPolicyUpdated(let payload):
                result.networkPolicyRevision =
                    payload.revision
                result.ambientRevocationGeneration =
                    payload.revocationGeneration
            default:
                break
            }
        }
        return result
    }

    public func grants(
        agentID: AgentID,
        capabilityLeaseID: CapabilityLeaseID,
        taskID: TaskID? = nil,
        at date: Date = Date()
    ) -> [MCPGrant] {
        guard !MCPReservedControlPlaneIdentity
                .deniesMCP(agentID),
              !revokedCapabilityLeaseIDs.contains(
                capabilityLeaseID) else {
            return []
        }
        // This projects the exact per-Agent capability lease. Attachment
        // membership is a separate authority layer: the dispatch planner
        // intersects these grants with `attachments`, and execution rechecks
        // both records from complete-known history before any external effect.
        return grants.values.filter {
            $0.agentID == agentID
                && $0.capabilityLeaseID
                    == capabilityLeaseID
                && $0.taskID == taskID
                && $0.isActive(at: date)
        }.sorted {
            $0.grantID.rawValue < $1.grantID.rawValue
        }
    }

    public func revocationGeneration(
        for attachment: MCPServerAttachment
    ) -> MCPRevocationGeneration {
        if let ambientRevocationGeneration {
            return ambientRevocationGeneration
        }
        if let value =
            revocationGenerations[attachment.attachmentID] {
            return value
        }
        return MCPRevocationGeneration(
            rawValue: "mcprevocation_"
                + MCPHostDigest.sha256([
                    attachment.attachmentID.rawValue,
                    attachment.server.serverID.rawValue,
                    attachment.server.serverRevision.rawValue,
                    attachment.policy.revision.rawValue,
                ]).prefix(24))
    }
}

public struct MCPEventLogBrokerEventSink:
    MCPBrokerEventSink, Sendable {
    public let log: EventLog

    public init(log: EventLog) {
        self.log = log
    }

    public func appendMCPBrokerEvent(
        _ event: Event
    ) async throws {
        _ = try await log.append(event)
    }

    public func appendMCPBrokerEvents(
        _ events: [Event]
    ) async throws {
        _ = try await log.append(events)
    }
}

public struct MCPEventLogExactConsentSource:
    MCPExactConsentSource, Sendable {
    public let log: EventLog

    public init(log: EventLog) {
        self.log = log
    }

    public func consent(
        matching requirement: MCPConsentRequirement
    ) async throws -> MCPConsent? {
        let state = try await MCPDurableSessionState.load(
            from: log)
        let matches = state.consents.values.filter {
            requirement.exactlyMatches($0)
        }.sorted {
            $0.consentID.rawValue < $1.consentID.rawValue
        }
        // More than one exact live consent is malformed durable authority,
        // not an opportunity to choose an arbitrary record.
        guard matches.count <= 1 else {
            throw IntatisError.permissionDenied(
                "More than one exact MCP connection consent is active.")
        }
        return matches.first
    }
}

/// Cross-process first-write/first-terminal adapter for MCP control actions.
public struct MCPEventLogControlPlaneAuditSink:
    MCPControlPlaneAuditSink, Sendable {
    public let log: EventLog

    public init(log: EventLog) {
        self.log = log
    }

    public func register(
        _ request: MCPControlPlaneAdmissionRequest
    ) async throws {
        let payload = MCPControlOperationRequestedPayload(
            operationID: request.operationID,
            kind: Self.kind(request.action),
            server: request.identity.server,
            attachmentID:
                request.identity.authority.attachmentID,
            authorityFingerprint:
                request.identity.authority.fingerprint,
            correlation: request.correlation)
        _ = try await log.appendSessionStateTransaction {
            history in
            var previous:
                MCPControlOperationRequestedPayload?
            var hasTerminal = false
            for envelope in history {
                switch envelope.event {
                case .mcpControlOperationRequested(let existing)
                    where existing.operationID
                        == request.operationID:
                    previous = existing
                case .mcpControlOperationSettled(let existing)
                    where existing.operationID
                        == request.operationID:
                    hasTerminal = true
                default:
                    break
                }
            }
            guard !hasTerminal else {
                throw MCPControlPlaneAdmissionError
                    .conflictingSettlement(
                        request.operationID)
            }
            if let previous {
                guard previous == payload else {
                    throw MCPControlPlaneAdmissionError
                        .duplicateOperation(
                            request.operationID)
                }
                return []
            }
            return [.mcpControlOperationRequested(payload)]
        }
    }

    public func settle(
        _ settlement: MCPControlPlaneAdmissionSettlement
    ) async throws {
        let payload = MCPControlOperationSettledPayload(
            operationID: settlement.operationID,
            kind: Self.kind(settlement.action),
            server: settlement.server,
            attachmentID: settlement.attachmentID,
            status: settlement.status,
            connectionGeneration:
                settlement.connectionGeneration,
            diagnostic: settlement.diagnostic)
        _ = try await log.appendSessionStateTransaction {
            history in
            var request:
                MCPControlOperationRequestedPayload?
            var previous:
                MCPControlOperationSettledPayload?
            for envelope in history {
                switch envelope.event {
                case .mcpControlOperationRequested(let existing)
                    where existing.operationID
                        == settlement.operationID:
                    request = existing
                case .mcpControlOperationSettled(let existing)
                    where existing.operationID
                        == settlement.operationID:
                    previous = existing
                default:
                    break
                }
            }
            guard let request,
                  request.kind == payload.kind,
                  request.server == payload.server,
                  request.attachmentID
                    == payload.attachmentID else {
                throw MCPControlPlaneAdmissionError
                    .unknownTicket(
                        settlement.operationID)
            }
            if let previous {
                guard previous == payload else {
                    throw MCPControlPlaneAdmissionError
                        .conflictingSettlement(
                            settlement.operationID)
                }
                return []
            }
            return [.mcpControlOperationSettled(payload)]
        }
    }

    private static func kind(
        _ action: MCPControlPlaneAction
    ) -> MCPControlOperationKind {
        switch action {
        case .test, .installProposal:
            return .test
        case .launch, .connect, .authenticate, .subscribe:
            return .connect
        case .refresh:
            return .refresh
        case .disconnect:
            return .disconnect
        }
    }
}

/// Deterministic shipping gate. It validates the exact host/session/root
/// authority before any secret read, process launch, or network operation.
public struct MCPProductControlPlaneHardGate:
    MCPControlPlaneHardGate, Sendable {
    public let sessionID: SessionID
    public let hostProfile: MCPProductHostProfile

    public init(
        sessionID: SessionID,
        hostProfile: MCPProductHostProfile
    ) {
        self.sessionID = sessionID
        self.hostProfile = hostProfile
    }

    public func evaluate(
        _ request: MCPControlPlaneAdmissionRequest
    ) async -> MCPControlPlaneHardGateDecision {
        let identity = request.identity
        guard request.sessionID == sessionID,
              identity.authority.sessionID == sessionID else {
            return .deny(.init(
                code: "mcp_wrong_session",
                summary:
                    "The MCP connection authority belongs to another session."))
        }
        guard identity.authority.hostPlatform
                == hostProfile.rawValue,
              hostProfile.permits(identity.transport) else {
            return .deny(.init(
                code: "mcp_transport_unavailable",
                summary:
                    "The selected MCP transport is unavailable on this host."))
        }
        guard identity.authority
                .hasCurrentExecutionAuthority else {
            return .deny(.init(
                code:
                    "mcp_legacy_authority",
                summary:
                    "The MCP connection authority predates the current task, workspace, and sandbox identity contract."))
        }
        if identity.transport == .stdio {
            guard identity.launchArtifactFingerprint != nil,
                  identity.authority.workspaceLeaseID != nil,
                  identity.authority
                    .workspaceRootIdentityFingerprint != nil,
                  identity.authority
                    .workspaceLeasePolicyFingerprint != nil,
                  identity.authority
                    .sandboxPolicyFingerprint != nil else {
                return .deny(.init(
                    code: "mcp_stdio_workspace_authority_missing",
                    summary:
                        "Local MCP launch requires an exact workspace lease and root identity."))
            }
        }
        guard identity.authority.fingerprint.utf8.count == 64,
              identity.runtimeIdentityFingerprint.utf8.count
                == 64 else {
            return .deny(.init(
                code: "mcp_identity_malformed",
                summary:
                    "The MCP connection identity is malformed."))
        }
        return .allow
    }
}

public struct MCPAgentDispatchInput: Sendable {
    public let agentID: AgentID
    public let capabilityLease: CapabilityLease
    public let workspaceLease: WorkspaceLease?
    public let baseRegistry: ToolRegistry
    public let activationReason: MCPRuntimeActivationReason

    public init(
        agentID: AgentID,
        capabilityLease: CapabilityLease,
        workspaceLease: WorkspaceLease?,
        baseRegistry: ToolRegistry,
        activationReason: MCPRuntimeActivationReason
    ) {
        self.agentID = agentID
        self.capabilityLease = capabilityLease
        self.workspaceLease = workspaceLease
        self.baseRegistry = baseRegistry
        self.activationReason = activationReason
    }
}

public struct MCPPreparedAgentDispatch: Sendable {
    public let plan: MCPInvocationPlan
    public let capabilityLease: CapabilityLease
    public let policies: [MCPToolBindingPolicy]
    public let resourcePolicies: [MCPResourceAccessPolicy]
    public let rememberedApprovals:
        [MCPRememberedToolApproval]

    public init(
        plan: MCPInvocationPlan,
        capabilityLease: CapabilityLease,
        policies: [MCPToolBindingPolicy],
        resourcePolicies: [MCPResourceAccessPolicy] = [],
        rememberedApprovals:
            [MCPRememberedToolApproval] = []
    ) {
        self.plan = plan
        self.capabilityLease = capabilityLease
        self.policies = policies
        self.resourcePolicies = resourcePolicies
        self.rememberedApprovals =
            rememberedApprovals
    }
}

/// Builds an invocation only from one complete EventLog projection, one
/// immutable global catalog snapshot, and the exact live Agent leases.
public struct MCPAgentDispatchPlanner: Sendable {
    public let sessionID: SessionID
    public let hostProfile: MCPProductHostProfile
    public let runtimeIdentityFingerprint: String
    public let log: EventLog
    public let catalogStore: MCPServerCatalogStore

    public init(
        sessionID: SessionID,
        hostProfile: MCPProductHostProfile,
        runtimeIdentityFingerprint: String,
        log: EventLog,
        catalogStore: MCPServerCatalogStore
    ) {
        self.sessionID = sessionID
        self.hostProfile = hostProfile
        self.runtimeIdentityFingerprint =
            runtimeIdentityFingerprint
        self.log = log
        self.catalogStore = catalogStore
    }

    public func prepare(
        _ input: MCPAgentDispatchInput
    ) async throws -> MCPPreparedAgentDispatch {
        try await prepare(
            input,
            catalog: try await catalogStore.load())
    }

    public func prepare(
        _ input: MCPAgentDispatchInput,
        catalog: MCPServerCatalog
    ) async throws -> MCPPreparedAgentDispatch {
        guard input.activationReason.permitsProviderDispatch
                || input.activationReason.createsSessionLiveConnection
        else {
            throw MCPRuntimeError
                .activationDoesNotPermitProviderDispatch(
                    input.activationReason)
        }
        let state = try await MCPDurableSessionState.load(
            from: log)
        let catalog = try catalog.validated()
        var capabilityLease = input.capabilityLease
        if let workspaceLeaseID =
                input.workspaceLease?.id,
           state.revokedWorkspaceLeaseIDs.contains(
                workspaceLeaseID) {
            throw IntatisError.permissionDenied(
                "The MCP workspace lease has been revoked.")
        }
        capabilityLease.mcpGrants = state.grants(
            agentID: input.agentID,
            capabilityLeaseID: input.capabilityLease.id,
            taskID: input.capabilityLease.taskID)
        var requirements:
            [MCPInvocationServerRequirement] = []
        var policies: [MCPToolBindingPolicy] = []
        var resourcePolicies: [MCPResourceAccessPolicy] = []
        for attachment in state.attachments.values.sorted(
            by: {
                $0.attachmentID.rawValue
                    < $1.attachmentID.rawValue
            }) {
            let matchingGrants =
                capabilityLease.mcpGrants.filter {
                    $0.attachmentID == attachment.attachmentID
                        && $0.server == attachment.server
                        && $0.agentID == input.agentID
                        && $0.capabilityLeaseID
                            == capabilityLease.id
                        && $0.taskID
                            == capabilityLease.taskID
                        && $0.isActive()
                }
            // An attachment is only configuration. It cannot start a process,
            // open a socket, advertise callbacks, or participate in the
            // required gate until this exact Agent lease has an active grant.
            guard !matchingGrants.isEmpty else { continue }
            guard matchingGrants.count == 1,
                  let grant = matchingGrants.first else {
                throw IntatisError.config(
                    "More than one exact MCP grant is active for attachment \(attachment.attachmentID.rawValue).")
            }
            guard let definition =
                    catalog.definition(
                        for: attachment.server),
                  definition.configuration.enabled,
                  !catalog.isTombstoned(
                    attachment.server) else {
                if attachment.policy.required {
                    throw IntatisError.config(
                        "Required MCP server revision \(attachment.server.serverID.rawValue) is unavailable.")
                }
                continue
            }
            let revocation =
                grant.revocationGeneration
            let rootFingerprint =
                input.workspaceLease?.rootIdentity.map {
                    MCPHostDigest.workspaceRootIdentity($0)
                }
            let workspacePolicyFingerprint =
                MCPConnectionIdentityBuilder
                    .workspaceLeasePolicyFingerprint(
                        input.workspaceLease)
            let rootsPolicyRevision =
                state.rootsPolicyRevision
                    ?? attachment.policy.filter
                        .revision
            let networkPolicyRevision =
                state.networkPolicyRevision
                    ?? attachment.policy.revision
            let sandboxProfileRevision =
                attachment.policy.revision
            let sandboxPolicyFingerprint =
                MCPConnectionIdentityBuilder
                    .sandboxPolicyFingerprint(
                        hostProfile:
                            hostProfile,
                        transport:
                            definition.configuration
                                .transport.kind,
                        sandboxProfileRevision:
                            sandboxProfileRevision,
                        networkPolicyRevision:
                            networkPolicyRevision,
                        workspaceLeasePolicyFingerprint:
                            workspacePolicyFingerprint)
            let requirement =
                try MCPConnectionIdentityBuilder.build(
                    definition: definition,
                    inputs: MCPConnectionAuthorityInputs(
                        sessionID: sessionID,
                        agentID: input.agentID,
                        attachment: attachment,
                        capabilityLeaseID:
                            capabilityLease.id,
                        capabilityTaskID:
                            capabilityLease.taskID,
                        workspaceLeaseID:
                            input.workspaceLease?.id,
                        workspaceRootIdentityFingerprint:
                            rootFingerprint,
                        workspaceLeasePolicyFingerprint:
                            workspacePolicyFingerprint,
                        accountReference:
                            definition.configuration.transport
                                .oauthAccountReference,
                        rootsPolicyRevision:
                            rootsPolicyRevision,
                        networkPolicyRevision:
                            networkPolicyRevision,
                        sandboxProfileRevision:
                            sandboxProfileRevision,
                        sandboxPolicyFingerprint:
                            sandboxPolicyFingerprint,
                        revocationGeneration: revocation,
                        hostProfile: hostProfile,
                        runtimeIdentityFingerprint:
                            runtimeIdentityFingerprint))
            requirements.append(requirement)
            let head = catalog.head(
                for: attachment.server.serverID)
            var effectiveApproval =
                definition.configuration.approvalPolicy
                    .serverDefault
            var approvalSource:
                MCPApprovalPolicySource =
                    .serverDefault
            let attachmentApproval =
                MCPApprovalPolicy.mostRestrictive(
                    effectiveApproval,
                    attachment.policy.approvalMode)
            if attachmentApproval
                    != effectiveApproval {
                effectiveApproval =
                    attachmentApproval
                approvalSource = .attachment
            }
            let grantApproval =
                MCPApprovalPolicy.mostRestrictive(
                    effectiveApproval,
                    grant.approvalModeCeiling)
            if grantApproval != effectiveApproval {
                effectiveApproval = grantApproval
                approvalSource = .agentGrant
            }
            policies.append(MCPToolBindingPolicy(
                server: attachment.server,
                attachmentID:
                    attachment.attachmentID,
                serverAlias:
                    head?.alias
                        ?? attachment.server.serverID.rawValue,
                serverFilter:
                    definition.configuration.filters.tools,
                attachmentFilter:
                    attachment.policy.filter.tools,
                effectiveApprovalMode:
                    effectiveApproval,
                approvalDecision:
                    effectiveApproval == .approve
                        ? .allow
                        : .askUser,
                approvalPolicySource:
                    approvalSource,
                toolApprovalOverrides:
                    definition.configuration.approvalPolicy
                        .toolOverrides,
                serverDefaultApprovalMode:
                    definition.configuration.approvalPolicy
                        .serverDefault,
                attachmentApprovalMode:
                    attachment.policy.approvalMode,
                grantApprovalModeCeiling:
                    grant.approvalModeCeiling,
                sideEffect: .destructive,
                risksNetwork:
                    definition.configuration.transport.kind
                        == .streamableHTTP,
                networkOrigin:
                    definition.configuration.transport
                        .canonicalNetworkOrigin,
                supportsParallelCalls:
                    attachment.policy.parallelCalls,
                policyFingerprint:
                    MCPHostDigest.sha256([
                        definition.definitionFingerprint,
                        attachment.policy.revision.rawValue,
                        effectiveApproval.rawValue,
                        grant.approvalModeCeiling.rawValue,
                    ])))
            if grant.grants(.resources) {
                resourcePolicies.append(
                    try MCPResourceAccessPolicy(
                        server: attachment.server,
                        attachmentID:
                            attachment.attachmentID,
                        serverAlias:
                            head?.alias
                                ?? attachment.server
                                    .serverID.rawValue,
                        serverFilter:
                            definition.configuration.filters
                                .resources,
                        attachmentFilter:
                            attachment.policy.filter.resources,
                        allowedURISchemes:
                            definition.configuration.transport.kind
                                == .stdio
                                ? ["file"]
                                : ["https"],
                        workspaceLease:
                            input.workspaceLease,
                        risksNetwork:
                            definition.configuration.transport.kind
                                == .streamableHTTP,
                        networkOrigin:
                            definition.configuration.transport
                                .canonicalNetworkOrigin,
                        policyFingerprint:
                            MCPHostDigest.sha256([
                                definition
                                    .definitionFingerprint,
                                attachment.policy.revision
                                    .rawValue,
                                grant.grantFingerprint,
                                "resources",
                            ])))
            }
        }
        return MCPPreparedAgentDispatch(
            plan: MCPInvocationPlan(
                sessionID: sessionID,
                agentID: input.agentID,
                activationReason:
                    input.activationReason,
                catalogPublication:
                    MCPCatalogPublicationIdentity(
                        catalog: catalog),
                servers: requirements),
            capabilityLease: capabilityLease,
            policies: policies,
            resourcePolicies: resourcePolicies,
            rememberedApprovals:
                state.rememberedApprovals.values
                    .filter { $0.isActive() }
                    .sorted {
                        $0.approvalID.rawValue
                            < $1.approvalID.rawValue
                    })
    }
}

public struct MCPToolExposureBudget:
    Equatable, Sendable {
    public let maximumDirectTools: Int
    public let maximumDirectSchemaBytes: Int

    public init(
        maximumDirectTools: Int = 64,
        maximumDirectSchemaBytes: Int = 128 * 1_024
    ) {
        self.maximumDirectTools = max(
            1, maximumDirectTools)
        self.maximumDirectSchemaBytes = max(
            4_096, maximumDirectSchemaBytes)
    }
}

public enum MCPToolExposureMode:
    Equatable, Sendable {
    case direct
    case deferredSearch
}

public enum MCPToolExposureError:
    Error, Equatable, Sendable, LocalizedError {
    case toolSearchUnsupported(
        toolCount: Int,
        schemaBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .toolSearchUnsupported(
            let toolCount,
            let schemaBytes):
            return "The MCP catalog exceeds the direct exposure budget (\(toolCount) tools, \(schemaBytes) schema bytes), but the selected model/provider route does not support tool_search."
        }
    }
}

/// Turns an exact prepared connection set into the immutable registry/specs
/// consumed by one provider request.
public enum MCPAgentRequestToolSnapshotBuilder {
    public static func exposureMode(
        toolCount: Int,
        schemaBytes: Int,
        providerCapabilities:
            ToolCallingProviderCapabilities,
        exposureBudget:
            MCPToolExposureBudget = .init()
    ) throws -> MCPToolExposureMode {
        let exceedsBudget =
            toolCount
                > exposureBudget.maximumDirectTools
            || schemaBytes
                > exposureBudget
                    .maximumDirectSchemaBytes
        guard exceedsBudget else {
            return .direct
        }
        guard providerCapabilities
            .supportsToolSearch else {
            throw MCPToolExposureError
                .toolSearchUnsupported(
                    toolCount: toolCount,
                    schemaBytes: schemaBytes)
        }
        return .deferredSearch
    }

    public static func build(
        connectionSet: MCPConnectionSetSnapshot,
        baseRegistry: ToolRegistry,
        capabilityLease: CapabilityLease,
        policies: [MCPToolBindingPolicy],
        resourcePolicies:
            [MCPResourceAccessPolicy] = [],
        rememberedApprovals:
            [MCPRememberedToolApproval] = [],
        providerCapabilities:
            ToolCallingProviderCapabilities,
        resultConverter: MCPToolResultConverter = .init(),
        resourceConverter:
            MCPResourceContentConverter = .init(),
        providerRequestResultBudget:
            MCPToolResultAggregateBudget =
                MCPToolResultAggregateBudget(
                    scope: .providerRequest,
                    maximumBytes:
                        MCPToolResultAggregateLimits
                            .maximumProviderRequestBytes),
        turnResultBudget:
            MCPToolResultAggregateBudget =
                MCPToolResultAggregateBudget(
                    scope: .turn,
                    maximumBytes:
                        MCPToolResultAggregateLimits
                            .maximumTurnBytes),
        resourceAuthorityVerifier:
            any MCPExternalOperationAuthorityVerifier,
        workspaceLease: WorkspaceLease?,
        resourceLimits:
            MCPResourceResultLimits = .init(),
        toolExecutionPreflight:
            @escaping @Sendable (
                MCPToolBindingEntry
            ) async throws -> Void = { _ in },
        resourceExecutionPreflight:
            @escaping @Sendable (
                MCPAgentResourceServerView
            ) async throws -> Void = { _ in },
        exposureBudget: MCPToolExposureBudget = .init()
    ) throws -> AgentRequestToolSnapshot {
        let view = try MCPAgentToolCatalogView.build(
            connectionSet: connectionSet,
            capabilityLease: capabilityLease,
            policies: policies,
            rememberedApprovals:
                rememberedApprovals)
        let mcpAvailability =
            try MCPToolAvailabilitySnapshot.frozen(
                snapshotID: view.stableFingerprint,
                serverIdentifiers:
                    Set(view.entries.map {
                        $0.authorization.server.serverID.rawValue
                    }),
                toolIdentifiers:
                    Set(view.entries.map(\.qualifiedName.value)),
                dependencyIdentities:
                    Set(view.entries.compactMap { entry in
                        guard let fingerprint =
                                entry.connection.reuseIdentity
                                    .skillDependencyLocatorFingerprint
                        else {
                            return nil
                        }
                        return MCPServerDependencyIdentity(
                            serverID:
                                entry.authorization.server
                                    .serverID.rawValue,
                            transportLocatorFingerprint:
                                fingerprint)
                    }))
        let resourceView =
            try MCPAgentResourceCatalogView.build(
                connectionSet: connectionSet,
                capabilityLease: capabilityLease,
                policies: resourcePolicies)
        let scopedResultConverter =
            resultConverter.scoped(
                providerRequestBudget:
                    providerRequestResultBudget,
                turnBudget:
                    turnResultBudget)
        let scopedResourceConverter =
            resourceConverter.scoped(
                providerRequestBudget:
                    providerRequestResultBudget,
                turnBudget:
                    turnResultBudget)
        let resourceRegistry =
            MCPResourceToolRegistryBuilder.build(
                base: baseRegistry,
                view: resourceView,
                authorityVerifier:
                    resourceAuthorityVerifier,
                workspaceLease: workspaceLease,
                limits: resourceLimits,
                converter:
                    scopedResourceConverter,
                executionPreflight:
                    resourceExecutionPreflight)
        let schemaBytes = view.entries.reduce(0) {
            partial, entry in
            partial
                + entry.remoteTool.summary.utf8.count
                + ((try? JSONEncoder().encode(
                    entry.remoteTool.inputSchema).count)
                    ?? exposureBudget
                        .maximumDirectSchemaBytes)
        }
        let exposure = try exposureMode(
            toolCount: view.entries.count,
            schemaBytes: schemaBytes,
            providerCapabilities:
                providerCapabilities,
            exposureBudget: exposureBudget)
        if exposure == .deferredSearch {
            let searchable =
                MCPToolRegistryBuilder.buildSearchable(
                    base: resourceRegistry,
                    view: view,
                    resultConverter:
                        scopedResultConverter,
                    executionPreflight:
                        toolExecutionPreflight)
            return AgentRequestToolSnapshot(
                snapshotID:
                    connectionSet.snapshotID.rawValue,
                registry: searchable.registry,
                mcpAvailability: mcpAvailability)
        }
        let registry = MCPToolRegistryBuilder.build(
            base: resourceRegistry,
            view: view,
            resultConverter:
                scopedResultConverter,
            executionPreflight:
                toolExecutionPreflight)
        return AgentRequestToolSnapshot(
            snapshotID:
                connectionSet.snapshotID.rawValue,
            registry: registry,
            mcpAvailability: mcpAvailability)
    }
}

/// Thread-safe registry read synchronously by the MCP connection factory.
/// The dispatch source registers the exact live workspace lease before
/// connection creation; callback capability advertisement is then frozen
/// together with that generation.
public final class MCPShippingConnectionServicesRegistry:
    @unchecked Sendable {
    private struct RegisteredAuthority {
        let identity: MCPConnectionReuseIdentity
        let workspaceLease: WorkspaceLease?
        let callbackCapabilities:
            MCPClientCallbackCapabilities
        let exposesRoots: Bool
        let exposesRemoteTasks: Bool
        let grantID: MCPGrantID
        let expiresAt: Date?
    }

    private let lock = NSLock()
    private var authorities:
        [MCPConnectionReuseIdentity: RegisteredAuthority] = [:]
    private var expiryTasks:
        [MCPConnectionReuseIdentity:
            Task<Void, Never>] = [:]
    private var expiryTokens:
        [MCPConnectionReuseIdentity:
            UUID] = [:]
    private var notificationRouters:
        [MCPConnectionGeneration:
            MCPGenerationCatalogNotificationRouter] = [:]
    private var notificationIdentities:
        [MCPConnectionGeneration:
            MCPConnectionReuseIdentity] = [:]
    private var dynamicCoordinators:
        [MCPConnectionGeneration:
            MCPDynamicCatalogCoordinator] = [:]
    private var subscriptionNotificationSink:
        (any MCPCatalogNotificationSink)?
    private var accepting = true
    private var shutdownDrainTask:
        Task<Void, Never>?
    private let events: any MCPBrokerEventSink
    private let payloadStore: any MCPBrokerPayloadStore
    private let sampling: MCPSamplingHostServices?
    private let elicitation: MCPElicitationHostServices?
    private let taskPolicy: MCPTaskRuntimePolicy
    public let inboundNotificationStore:
        MCPProductionInboundNotificationStore

    public init(
        events: any MCPBrokerEventSink,
        payloadStore: any MCPBrokerPayloadStore,
        sampling: MCPSamplingHostServices? = nil,
        elicitation: MCPElicitationHostServices? = nil,
        taskPolicy: MCPTaskRuntimePolicy = .init()
    ) {
        self.events = events
        self.payloadStore = payloadStore
        self.sampling = sampling
        self.elicitation = elicitation
        self.taskPolicy = taskPolicy
        inboundNotificationStore =
            MCPProductionInboundNotificationStore(
                events: events)
    }

    public func register(
        prepared: MCPPreparedAgentDispatch,
        workspaceLease: WorkspaceLease?,
        expiryHandler:
            @escaping @Sendable (
                MCPConnectionReuseIdentity,
                MCPRevocationGeneration
            ) async -> Void = { _, _ in }
    ) async throws {
        var expiryToDrain:
            [Task<Void, Never>] = []
        var routersToDrain:
            [MCPGenerationCatalogNotificationRouter] = []
        let canRegister = lock.withLock {
            accepting
        }
        guard canRegister else {
            throw IntatisError.permissionDenied(
                "The MCP callback services registry is shutting down.")
        }
        var next:
            [MCPConnectionReuseIdentity: RegisteredAuthority] = [:]
        for requirement in prepared.plan.servers {
            let identity = requirement.identity
            let authority = identity.authority
            guard authority.hasCurrentExecutionAuthority,
                  let workspacePolicyFingerprint =
                    authority
                        .workspaceLeasePolicyFingerprint,
                  authority.capabilityLeaseID
                    == prepared.capabilityLease.id,
                  authority.capabilityTaskID
                    == prepared.capabilityLease.taskID,
                  authority.workspaceLeaseID
                    == workspaceLease?.id,
                  workspaceLease == nil
                    || workspaceLease?.taskID
                        == authority.capabilityTaskID,
                  authority.workspaceLeasePolicyFingerprint
                    == MCPConnectionIdentityBuilder
                        .workspaceLeasePolicyFingerprint(
                            workspaceLease),
                  let hostProfile =
                    MCPProductHostProfile(
                        rawValue:
                            authority.hostPlatform),
                  authority.sandboxPolicyFingerprint
                    == MCPConnectionIdentityBuilder
                        .sandboxPolicyFingerprint(
                            hostProfile: hostProfile,
                            transport: identity.transport,
                            sandboxProfileRevision:
                                authority
                                    .sandboxProfileRevision,
                            networkPolicyRevision:
                                authority
                                    .networkPolicyRevision,
                            workspaceLeasePolicyFingerprint:
                                workspacePolicyFingerprint)
            else {
                throw IntatisError.permissionDenied(
                    "MCP callback services require current exact task, workspace, and sandbox authority.")
            }
            let grants =
                prepared.capabilityLease.mcpGrants.filter {
                    $0.attachmentID
                        == identity.authority.attachmentID
                        && $0.server == identity.server
                        && $0.agentID
                            == identity.authority.agentID
                        && $0.capabilityLeaseID
                            == identity.authority
                                .capabilityLeaseID
                        && $0.taskID
                            == prepared.capabilityLease.taskID
                        && $0.isActive()
                }
            guard grants.count == 1,
                  let grant = grants.first,
                  grant.authorityFingerprint
                    == identity.authority.fingerprint,
                  grant.revocationGeneration
                    == requirement.revocationGeneration else {
                throw IntatisError.permissionDenied(
                    "MCP callback services require one exact active Agent grant.")
            }
            let profile =
                identity.authority.protocolProfile
            let samplingEnabled =
                profile == .standardExtended
                && grant.grants(.sampling)
                && sampling?.policy.enabled == true
                && !(sampling?.policy
                    .allowedInferenceBindings.isEmpty ?? true)
            let formEnabled =
                grant.grants(.elicitation)
                && elicitation?.policy.formEnabled == true
            let URLEnabled =
                profile == .standardExtended
                && grant.grants(.elicitation)
                && elicitation?.policy.urlEnabled == true
            let tasksEnabled =
                profile == .standardExtended
                && grant.grants(.tasks)
                && samplingEnabled
                && formEnabled
            let capabilities =
                MCPClientCallbackCapabilities(
                    samplingTools:
                        samplingEnabled,
                    formElicitation:
                        formEnabled,
                    URLElicitation:
                        URLEnabled,
                    taskList: tasksEnabled,
                    taskCancel: tasksEnabled,
                    taskSampling: tasksEnabled,
                    taskElicitation: tasksEnabled)
            try capabilities.validate(for: profile)
            let exposesRoots =
                profile == .standardExtended
                && grant.grants(.roots)
                && workspaceLease != nil
            let registered = RegisteredAuthority(
                identity: identity,
                workspaceLease: workspaceLease,
                callbackCapabilities:
                    capabilities,
                exposesRoots: exposesRoots,
                exposesRemoteTasks:
                    profile == .standardExtended
                        && grant.grants(.tasks),
                grantID: grant.grantID,
                expiresAt: grant.expiresAt)
            guard next.updateValue(
                registered,
                forKey: identity) == nil else {
                throw IntatisError.config(
                    "Duplicate MCP callback authority was prepared.")
            }
        }
        try lock.withLock {
            guard accepting else {
                throw IntatisError.permissionDenied(
                    "The MCP callback services registry is shutting down.")
            }
            let scopeSessionID =
                prepared.plan.sessionID
            let scopeAgentID =
                prepared.plan.agentID
            let scopeCapabilityLeaseID =
                prepared.capabilityLease.id
            let stale = authorities.keys.filter {
                identity in
                identity.authority.sessionID
                        == scopeSessionID
                    && identity.authority.agentID
                        == scopeAgentID
                    && identity.authority
                        .capabilityLeaseID
                        == scopeCapabilityLeaseID
                    && next[identity] == nil
            }
            let staleSet = Set(stale)
            let staleGenerations =
                notificationIdentities.compactMap {
                    generation, identity in
                    staleSet.contains(identity)
                        ? generation
                        : nil
                }
            for identity in stale {
                authorities.removeValue(
                    forKey: identity)
                if let task =
                        expiryTasks.removeValue(
                            forKey: identity) {
                    expiryTokens.removeValue(
                        forKey: identity)
                    task.cancel()
                    expiryToDrain.append(task)
                }
            }
            for generation in staleGenerations {
                if let router =
                        notificationRouters
                            .removeValue(
                                forKey: generation) {
                    routersToDrain.append(router)
                }
                notificationIdentities
                    .removeValue(forKey: generation)
                dynamicCoordinators
                    .removeValue(forKey: generation)
            }
            for (identity, registered) in next {
                authorities[identity] = registered
                if let task =
                        expiryTasks.removeValue(
                            forKey: identity) {
                    expiryTokens.removeValue(
                        forKey: identity)
                    task.cancel()
                    expiryToDrain.append(task)
                }
                if let expiresAt =
                        registered.expiresAt {
                    let delay = max(
                        0,
                        expiresAt.timeIntervalSinceNow)
                    let replacement =
                        MCPRevocationGeneration(
                            rawValue:
                                "mcprevocation_expiry_"
                                    + MCPHostDigest.sha256([
                                        registered.grantID
                                            .rawValue,
                                        String(
                                            expiresAt
                                                .timeIntervalSince1970),
                                        identity.authority
                                            .fingerprint,
                                    ]).prefix(24))
                    let expiryToken = UUID()
                    expiryTokens[identity] =
                        expiryToken
                    expiryTasks[identity] = Task {
                    [weak self] in
                    do {
                        try await Task.sleep(
                            for: .seconds(delay))
                    } catch {
                        self?.finishExpiryTask(
                            identity: identity,
                            grantID:
                                registered.grantID,
                            expiresAt: expiresAt,
                            token: expiryToken)
                        return
                    }
                    guard let self,
                          self.retireExpired(
                            identity: identity,
                            grantID:
                                registered.grantID,
                            expiresAt: expiresAt,
                            token: expiryToken)
                    else {
                        self?.finishExpiryTask(
                            identity: identity,
                            grantID:
                                registered.grantID,
                            expiresAt: expiresAt,
                            token: expiryToken)
                        return
                    }
                    guard !Task.isCancelled,
                          self.isAccepting else {
                        self.finishExpiryTask(
                            identity: identity,
                            grantID:
                                registered.grantID,
                            expiresAt: expiresAt,
                            token: expiryToken)
                        return
                    }
                    await self
                        .retireNotificationRoutes(
                            identity: identity)
                    guard !Task.isCancelled,
                          self.isAccepting else {
                        self.finishExpiryTask(
                            identity: identity,
                            grantID:
                                registered.grantID,
                            expiresAt: expiresAt,
                            token: expiryToken)
                        return
                    }
                    await expiryHandler(
                        identity,
                        replacement)
                    self.finishExpiryTask(
                        identity: identity,
                        grantID:
                            registered.grantID,
                        expiresAt: expiresAt,
                        token: expiryToken)
                    }
                }
            }
        }
        await withTaskGroup(of: Void.self) {
            group in
            for task in expiryToDrain {
                group.addTask {
                    _ = await task.value
                }
            }
            for router in routersToDrain {
                group.addTask {
                    await router.retireAndDrain()
                }
            }
        }
    }

    private func retireExpired(
        identity: MCPConnectionReuseIdentity,
        grantID: MCPGrantID,
        expiresAt: Date,
        token: UUID
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let registered =
                authorities[identity],
              accepting,
              expiryTokens[identity]
                == token,
              registered.grantID == grantID,
              registered.expiresAt == expiresAt,
              expiresAt <= Date() else {
            return false
        }
        authorities.removeValue(
            forKey: identity)
        return true
    }

    private var isAccepting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepting
    }

    private func finishExpiryTask(
        identity: MCPConnectionReuseIdentity,
        grantID: MCPGrantID,
        expiresAt: Date,
        token: UUID
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard expiryTokens[identity]
                == token else {
            return
        }
        expiryTasks.removeValue(
            forKey: identity)
        expiryTokens.removeValue(
            forKey: identity)
    }

    private func retireNotificationRoutes(
        identity: MCPConnectionReuseIdentity
    ) async {
        let routers = lock.withLock {
            let generations =
                notificationIdentities.compactMap {
                    generation, value in
                    value == identity
                        ? generation
                        : nil
                }
            var removed:
                [MCPGenerationCatalogNotificationRouter] = []
            for generation in generations {
                if let router =
                        notificationRouters
                            .removeValue(
                                forKey: generation) {
                    removed.append(router)
                }
                notificationIdentities
                    .removeValue(forKey: generation)
                dynamicCoordinators
                    .removeValue(forKey: generation)
            }
            return removed
        }
        await withTaskGroup(of: Void.self) {
            group in
            for router in routers {
                group.addTask {
                    await router.retireAndDrain()
                }
            }
        }
    }

    public func retire(
        authorityKey: MCPAuthorityPoolKey
    ) async {
        let (expiry, routers) = lock.withLock {
            let targets = authorities.keys.filter {
                $0.poolKey == authorityKey
            }
            let generations =
                notificationIdentities.compactMap {
                    generation, identity in
                    identity.poolKey == authorityKey
                        ? generation
                        : nil
                }
            var expiry:
                [Task<Void, Never>] = []
            var routers:
                [MCPGenerationCatalogNotificationRouter] = []
            for identity in targets {
                authorities.removeValue(
                    forKey: identity)
                if let task =
                        expiryTasks.removeValue(
                            forKey: identity) {
                    expiryTokens.removeValue(
                        forKey: identity)
                    expiry.append(task)
                }
            }
            for generation in generations {
                if let router =
                        notificationRouters
                            .removeValue(
                                forKey:
                                    generation) {
                    routers.append(router)
                }
                notificationIdentities
                    .removeValue(forKey: generation)
                dynamicCoordinators
                    .removeValue(forKey: generation)
            }
            return (expiry, routers)
        }
        for task in expiry { task.cancel() }
        await withTaskGroup(of: Void.self) {
            group in
            for task in expiry {
                group.addTask {
                    _ = await task.value
                }
            }
            for router in routers {
                group.addTask {
                    await router.retireAndDrain()
                }
            }
        }
    }

    public func retire(
        attachmentID: MCPAttachmentID,
        agentID: AgentID? = nil
    ) async {
        let (expiry, routers) = lock.withLock {
            let targets = authorities.keys.filter {
                $0.authority.attachmentID
                        == attachmentID
                    && (agentID == nil
                        || $0.authority.agentID
                            == agentID)
            }
            let targetSet = Set(targets)
            let generations =
                notificationIdentities.compactMap {
                    generation, identity in
                    targetSet.contains(identity)
                        ? generation
                        : nil
                }
            var expiry:
                [Task<Void, Never>] = []
            var routers:
                [MCPGenerationCatalogNotificationRouter] = []
            for identity in targets {
                authorities.removeValue(
                    forKey: identity)
                if let task =
                        expiryTasks.removeValue(
                            forKey: identity) {
                    expiryTokens.removeValue(
                        forKey: identity)
                    expiry.append(task)
                }
            }
            for generation in generations {
                if let router =
                        notificationRouters
                            .removeValue(
                                forKey:
                                    generation) {
                    routers.append(router)
                }
                notificationIdentities
                    .removeValue(forKey: generation)
                dynamicCoordinators
                    .removeValue(forKey: generation)
            }
            return (expiry, routers)
        }
        for task in expiry { task.cancel() }
        await withTaskGroup(of: Void.self) {
            group in
            for task in expiry {
                group.addTask {
                    _ = await task.value
                }
            }
            for router in routers {
                group.addTask {
                    await router.retireAndDrain()
                }
            }
        }
    }

    public func workspaceLease(
        matching identity: MCPConnectionReuseIdentity
    ) -> WorkspaceLease? {
        lock.lock()
        defer { lock.unlock() }
        guard let registered = authorities[identity],
              registered.identity == identity,
              registered.exposesRoots
                || identity.transport == .stdio,
              let lease = registered.workspaceLease,
              lease.id
                == identity.authority.workspaceLeaseID else {
            return nil
        }
        return lease
    }

    public func provider()
        -> MCPProductionConnectionServicesProvider {
        { [self] definition, identity, generation in
            let profile =
                definition.configuration.protocolProfile
            let registered:
                RegisteredAuthority?
            let router:
                MCPGenerationCatalogNotificationRouter?
            let routerIdentity:
                MCPConnectionReuseIdentity?
            lock.lock()
            let isOpen = accepting
            registered = isOpen
                ? authorities[identity]
                : nil
            if isOpen, registered != nil {
                if let existing =
                        notificationRouters[
                            generation] {
                    router = existing
                    routerIdentity =
                        notificationIdentities[
                            generation]
                } else {
                    let created =
                        MCPGenerationCatalogNotificationRouter(
                            server: identity.server,
                            generation:
                                generation,
                            subscriptionSink:
                                subscriptionNotificationSink)
                    notificationRouters[
                        generation] = created
                    notificationIdentities[
                        generation] = identity
                    router = created
                    routerIdentity = identity
                }
            } else {
                router = nil
                routerIdentity = nil
            }
            lock.unlock()
            guard let registered,
                  let router,
                  routerIdentity == identity,
                  registered.identity == identity,
                  identity.authority
                    .hasCurrentExecutionAuthority,
                  identity.authority
                    .capabilityTaskID
                    == registered.identity
                        .authority
                        .capabilityTaskID,
                  identity.authority
                    .workspaceLeasePolicyFingerprint
                    == MCPConnectionIdentityBuilder
                        .workspaceLeasePolicyFingerprint(
                            registered
                                .workspaceLease)
            else {
                throw IntatisError.permissionDenied(
                    "No exact MCP callback authority is registered for this connection.")
            }
            let roots: MCPAuthorizedRootsSnapshot?
            if profile == .standardExtended,
               registered.exposesRoots,
               let lease = registered.workspaceLease {
                guard identity.authority.workspaceLeaseID
                        == lease.id else {
                    throw IntatisError.permissionDenied(
                        "The registered MCP roots lease does not match the connection authority.")
                }
                    roots = try MCPAuthorizedRootsSnapshot.exact(
                        workspaceLease: lease,
                        authority: identity.authority,
                        revocationGeneration:
                            MCPRevocationGeneration(
                                rawValue:
                                    "mcprevocation_callbacks_"
                                        + identity.authority
                                            .fingerprint
                                            .prefix(16)),
                        displayName:
                            URL(fileURLWithPath: lease.rootPath)
                                .lastPathComponent)
            } else {
                roots = profile == .standardExtended
                    ? .empty(
                        policyRevision:
                            identity.authority
                                .rootsPolicyRevision,
                        revocationGeneration:
                            MCPRevocationGeneration(
                                rawValue:
                                    "mcprevocation_callbacks_"
                                        + identity.authority
                                            .fingerprint
                                            .prefix(16)))
                    : nil
            }
            let factory:
                (any MCPClientInboundServicesFactory)?
            if registered.callbackCapabilities.isEmpty {
                factory = nil
            } else {
                factory = MCPBrokerInboundServicesFactory(
                    events: events,
                    payloadStore: payloadStore,
                    sampling: sampling,
                    elicitation: elicitation,
                    taskPolicy: taskPolicy)
            }
            return MCPProductionConnectionServices(
                authorizedRoots: roots,
                catalogNotificationSink:
                    router,
                callbackCapabilities:
                    registered.callbackCapabilities,
                inboundServicesFactory: factory,
                remoteTaskServices:
                    registered.exposesRemoteTasks
                        ? MCPProductionRemoteTaskServices(
                            events: events,
                            payloadStore: payloadStore,
                            policy: taskPolicy)
                        : nil,
                inboundNotificationSink:
                    inboundNotificationStore)
        }
    }

    /// Installs the dynamic refresh owner only after initialize + complete
    /// discovery produced a live exact-generation snapshot. Notifications that
    /// arrived earlier were bounded by the generation router and are replayed
    /// before this method returns.
    public func activateNotificationRoutes(
        for connectionSet:
            MCPConnectionSetSnapshot,
        owner: MCPSessionRuntimeOwner
    ) async throws -> MCPConnectionSetSnapshot {
        for connection in connectionSet.connections {
            let identity = connection.reuseIdentity
            let generation =
                connection.bindingIdentity
                    .connectionGeneration
            let revocation =
                connection.bindingIdentity
                    .revocationGeneration
            let (router, existing) = lock.withLock {
                if accepting,
                   notificationIdentities[generation]
                        == identity {
                    return (
                        notificationRouters[generation],
                        dynamicCoordinators[generation]
                    )
                }
                return (
                    Optional<MCPGenerationCatalogNotificationRouter>
                        .none,
                    Optional<MCPDynamicCatalogCoordinator>
                        .none
                )
            }
            guard let router else {
                throw IntatisError.permissionDenied(
                    "The exact MCP notification generation is not registered.")
            }
            if existing != nil { continue }

            let coordinator =
                MCPDynamicCatalogCoordinator(
                    server: identity.server,
                    generation: generation,
                    initialCatalog:
                        connection.catalog,
                    loadFullCatalog: {
                        let current =
                            try await owner
                                .currentConnectionSnapshot(
                                    identity:
                                        identity,
                                    generation:
                                        generation)
                        return try await current.route
                            .discoverCompleteCatalogForRefresh()
                    },
                    publishAtomically: {
                        catalog, remainingStale in
                        _ = try await owner
                            .publishDynamicCatalogAndRepublish(
                                catalog,
                                identity: identity,
                                generation: generation,
                                revocationGeneration:
                                    revocation,
                                resultingUnavailableKinds:
                                    remainingStale)
                    },
                    publishStale: { kinds in
                        guard !kinds.isEmpty else {
                            return
                        }
                        _ = try? await owner
                            .markCatalogStaleAndRepublish(
                                identity: identity,
                                generation: generation,
                                revocationGeneration:
                                    revocation,
                                kinds: kinds)
                    })
            let installed = lock.withLock {
                guard accepting,
                      notificationIdentities[generation]
                        == identity,
                      dynamicCoordinators[generation]
                        == nil else {
                    return false
                }
                dynamicCoordinators[
                    generation] =
                    coordinator
                return true
            }
            guard installed else {
                await coordinator.shutdownAndDrain()
                if !isAccepting {
                    throw IntatisError.permissionDenied(
                        "The MCP callback services registry is shutting down.")
                }
                continue
            }
            await router.installDynamicCatalogSink(
                coordinator)
        }
        return await owner.latestPublishedSnapshot(
            agentID: connectionSet.agentID)
            ?? connectionSet
    }

    /// Installs the conversation-owned exact subscription manager into every
    /// live generation router. Resource updates are never buffered before this
    /// installation.
    public func installSubscriptionNotificationSink(
        _ sink:
            (any MCPCatalogNotificationSink)?
    ) async {
        let routers:
            [MCPGenerationCatalogNotificationRouter]? =
                lock.withLock {
                    guard accepting else {
                        return nil
                    }
                    subscriptionNotificationSink =
                        sink
                    return Array(
                        notificationRouters.values)
                }
        guard let routers else {
            return
        }
        await withTaskGroup(of: Void.self) {
            group in
            for router in routers {
                group.addTask {
                    await router
                        .installSubscriptionSink(
                            sink)
                }
            }
        }
    }

    public func shutdownAndDrain() async {
        let drain = lock.withLock {
            if let existing =
                    shutdownDrainTask {
                return existing
            }
            accepting = false
            authorities.removeAll()
            let expiry = Array(
                expiryTasks.values)
            for task in expiry {
                task.cancel()
            }
            expiryTasks.removeAll()
            expiryTokens.removeAll()
            let routers = Array(
                notificationRouters.values)
            notificationRouters.removeAll()
            notificationIdentities.removeAll()
            dynamicCoordinators.removeAll()
            subscriptionNotificationSink = nil
            let task = Task {
                await withTaskGroup(of: Void.self) {
                    group in
                    for expiryTask in expiry {
                        group.addTask {
                            _ = await expiryTask
                                .value
                        }
                    }
                    for router in routers {
                        group.addTask {
                            await router
                                .retireAndDrain()
                        }
                    }
                }
            }
            shutdownDrainTask = task
            return task
        }
        _ = await drain.value
    }
}

public struct MCPConnectionConsentChallengeItem:
    Equatable, Sendable
{
    public let identity: MCPConnectionReuseIdentity
    public let requirement: MCPConsentRequirement

    public init(identity: MCPConnectionReuseIdentity) {
        self.identity = identity
        requirement = MCPConsentRequirement(
            identity: identity)
    }
}

/// Provider-dispatch pause point. A host must visibly present every exact
/// item, obtain a direct decision, and durably append matching consents before
/// returning. The snapshot source re-reads EventLog and rejects a UI-only
/// answer, stale revision, or Test-only authorization.
public struct MCPConnectionConsentChallenge:
    Equatable, Sendable
{
    public let sessionID: SessionID
    public let agentID: AgentID
    public let activationReason:
        MCPRuntimeActivationReason
    public let items:
        [MCPConnectionConsentChallengeItem]

    public init(
        sessionID: SessionID,
        agentID: AgentID,
        activationReason:
            MCPRuntimeActivationReason,
        items:
            [MCPConnectionConsentChallengeItem]
    ) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.activationReason = activationReason
        self.items = items.sorted {
            if $0.identity.server.serverID
                != $1.identity.server.serverID {
                return $0.identity.server.serverID.rawValue
                    < $1.identity.server.serverID.rawValue
            }
            return $0.identity.server.serverRevision.rawValue
                < $1.identity.server.serverRevision.rawValue
        }
    }
}

public protocol MCPConnectionConsentChallengeHandler:
    Sendable
{
    func resolveConnectionConsent(
        _ challenge: MCPConnectionConsentChallenge
    ) async throws
}

public enum MCPConnectionConsentChallengeError:
    Error, Equatable, LocalizedError, Sendable
{
    case handlerUnavailable
    case consentNotPersisted(
        MCPConsentRequirement)

    public var errorDescription: String? {
        switch self {
        case .handlerUnavailable:
            return "MCP connection requires explicit consent before provider dispatch, but this host has no consent UI."
        case .consentNotPersisted:
            return "The MCP connection consent was not durably persisted for the exact authority."
        }
    }
}

/// Execution-time durable fence for response-owned tool/resource snapshots.
/// A provider response can outlive a grant, policy, lease, root, or global
/// catalog mutation, so frozen visibility is revalidated immediately before
/// any remote operation starts.
public struct MCPEventLogExecutionAuthorityVerifier:
    MCPExternalOperationAuthorityVerifier, Sendable
{
    public let log: EventLog
    public let catalogStore: MCPServerCatalogStore

    public init(
        log: EventLog,
        catalogStore: MCPServerCatalogStore
    ) {
        self.log = log
        self.catalogStore = catalogStore
    }

    public func verifyTool(
        _ entry: MCPToolBindingEntry,
        workspaceLease: WorkspaceLease?
    ) async throws {
        try await verify(
            identity: entry.connection.reuseIdentity,
            binding: entry.connection.bindingIdentity,
            grant: entry.grant,
            capability: .tools,
            workspaceLease: workspaceLease)
        guard entry.authorization.grantID
                == entry.grant.grantID,
              entry.authorization.grantFingerprint
                == entry.grant.grantFingerprint,
              entry.authorization.authorityFingerprint
                == entry.connection.reuseIdentity
                    .authority.fingerprint,
              entry.authorization.revocationGeneration
                == entry.connection.bindingIdentity
                    .revocationGeneration else {
            throw IntatisError.permissionDenied(
                "The exact MCP tool authorization changed before execution.")
        }
    }

    public func verifyResource(
        _ server: MCPAgentResourceServerView,
        workspaceLease: WorkspaceLease?
    ) async throws {
        try await verify(
            identity: server.connection.reuseIdentity,
            binding: server.connection.bindingIdentity,
            grant: server.grant,
            capability: .resources,
            workspaceLease: workspaceLease)
    }

    public func verifyMCPExternalOperation(
        _ request:
            MCPExternalOperationAuthorityRequest,
        phase _:
            MCPExternalOperationVerificationPhase
    ) async throws {
        let capabilities = request.operation
            .requiredCapabilities.sorted(by: {
                $0.rawValue < $1.rawValue
            })
        if capabilities.isEmpty {
            try await verify(
                identity: request.identity,
                binding: request.binding,
                grant: request.grant,
                capability: nil,
                workspaceLease:
                    request.workspaceLease)
        } else {
            for capability in capabilities {
                try await verify(
                    identity: request.identity,
                    binding: request.binding,
                    grant: request.grant,
                    capability: capability,
                    workspaceLease:
                        request.workspaceLease)
            }
        }
    }

    private func verify(
        identity: MCPConnectionReuseIdentity,
        binding: MCPBindingIdentity,
        grant: MCPGrant,
        capability: MCPGrantedCapability?,
        workspaceLease: WorkspaceLease?
    ) async throws {
        let authority = identity.authority
        guard authority.hasCurrentExecutionAuthority,
              let workspacePolicyFingerprint =
                authority
                    .workspaceLeasePolicyFingerprint,
              let sandboxPolicyFingerprint =
                authority
                    .sandboxPolicyFingerprint,
              authority.capabilityTaskID == grant.taskID,
              grant.capabilityLeaseID
                == authority.capabilityLeaseID,
              MCPConnectionIdentityBuilder
                .workspaceLeasePolicyFingerprint(
                    workspaceLease)
                == workspacePolicyFingerprint,
              let hostProfile =
                MCPProductHostProfile(
                    rawValue:
                        authority.hostPlatform),
              MCPConnectionIdentityBuilder
                .sandboxPolicyFingerprint(
                    hostProfile: hostProfile,
                    transport: identity.transport,
                    sandboxProfileRevision:
                        authority
                            .sandboxProfileRevision,
                    networkPolicyRevision:
                        authority
                            .networkPolicyRevision,
                    workspaceLeasePolicyFingerprint:
                        workspacePolicyFingerprint)
                == sandboxPolicyFingerprint else {
            throw IntatisError.permissionDenied(
                "The MCP task, workspace, or sandbox execution authority is not current.")
        }
        let state = try await MCPDurableSessionState.load(
            from: log)
        guard let attachment =
                state.attachments[
                    identity.authority.attachmentID],
              attachment.server == identity.server,
              attachment.policy.revision
                == identity.authority
                    .attachmentPolicyRevision,
              !state.revokedCapabilityLeaseIDs.contains(
                identity.authority.capabilityLeaseID),
              let currentGrant =
                state.grants[grant.grantID],
              currentGrant == grant,
              currentGrant.capabilityLeaseID
                == identity.authority
                    .capabilityLeaseID,
              currentGrant.authorityFingerprint
                == identity.authority.fingerprint,
              currentGrant.revocationGeneration
                == binding.revocationGeneration,
              capability.map(currentGrant.grants)
                ?? true,
              currentGrant.isActive() else {
            throw IntatisError.permissionDenied(
                "The MCP grant, attachment, or revocation generation changed before execution.")
        }
        let consentRequirement =
            MCPConsentRequirement(identity: identity)
        let matchingConsents =
            state.consents.values.filter {
                consentRequirement.exactlyMatches($0)
            }
        guard matchingConsents.count == 1 else {
            throw IntatisError.permissionDenied(
                "The exact MCP connection consent changed before execution.")
        }

        if let expectedWorkspaceLeaseID =
                identity.authority.workspaceLeaseID {
            guard let workspaceLease,
                  workspaceLease.id
                    == expectedWorkspaceLeaseID,
                  workspaceLease.taskID
                    == identity.authority
                        .capabilityTaskID,
                  !state.revokedWorkspaceLeaseIDs.contains(
                    expectedWorkspaceLeaseID),
                  let rootIdentity =
                    workspaceLease.rootIdentity,
                  rootIdentity.matchesCurrentDirectory(
                    rootPath:
                        workspaceLease.rootPath),
                  MCPHostDigest.workspaceRootIdentity(
                    rootIdentity)
                    == identity.authority
                        .workspaceRootIdentityFingerprint
            else {
                throw IntatisError.permissionDenied(
                    "The MCP workspace lease or root identity changed before execution.")
            }
        } else if workspaceLease != nil {
            throw IntatisError.permissionDenied(
                "The MCP operation supplied a workspace lease that is outside the frozen authority.")
        }

        let catalog = try await catalogStore.load()
        guard let definition =
                catalog.definition(for: identity.server),
              definition.configuration.enabled,
              !catalog.isTombstoned(identity.server),
              definition.configuration.transport
                .connectionFingerprint
                == identity
                    .transportConfigurationFingerprint,
              definition.configuration
                .environmentReference
                == identity.environmentReference,
              definition.configuration.transport
                .oauthAccountReference
                == identity.oauthAccountReference,
              definition.configuration.transport
                .launchArtifactFingerprint
                == identity.launchArtifactFingerprint else {
            throw IntatisError.permissionDenied(
                "The MCP server revision is no longer an executable catalog authority.")
        }
    }
}

/// Same-process EventLog authority observer. Durable writes remain canonical;
/// this observer turns every authority-tightening event into an immediate
/// exact pool retirement so existing callback brokers and response-owned
/// routes cannot remain live until the next provider turn.
public actor MCPEventLogAuthorityRevocationObserver {
    private enum Scope {
        case attachment(
            MCPAttachmentID,
            AgentID?)
        case capabilityLease(CapabilityLeaseID)
        case workspaceLease(WorkspaceLeaseID)
        case all
    }

    private let log: EventLog
    private let owner: MCPSessionRuntimeOwner
    private let services:
        MCPShippingConnectionServicesRegistry
    private var task: Task<Void, Never>?

    public init(
        log: EventLog,
        owner: MCPSessionRuntimeOwner,
        services:
            MCPShippingConnectionServicesRegistry
    ) {
        self.log = log
        self.owner = owner
        self.services = services
    }

    public func start() async throws {
        guard task == nil else { return }
        let stream =
            try await log
                .streamFromCurrentDurableTail()
        task = Task { [weak self] in
            guard let self else { return }
            for await envelope in stream {
                if Task.isCancelled { return }
                await self.reconcile(envelope.event)
            }
        }
    }

    public func stop() async {
        task?.cancel()
        _ = await task?.result
        task = nil
    }

    /// Product mutation hosts may await this immediately after their atomic
    /// EventLog append instead of waiting for stream scheduling.
    public func reconcile(
        _ event: Event
    ) async {
        switch event {
        case .mcpServerDetached(let payload):
            await retire(
                .attachment(
                    payload.attachmentID,
                    nil),
                to: payload.revocationGeneration,
                reason: payload.reason.rawValue)
        case .mcpAttachmentPolicyUpdated(let payload):
            await retire(
                .attachment(
                    payload.attachmentID,
                    nil),
                to: payload.revocationGeneration,
                reason:
                    MCPPolicyChangeReason
                        .policyTightened.rawValue)
        case .mcpConsentRevoked(let payload):
            await retire(
                .attachment(
                    payload.attachmentID,
                    nil),
                to: payload.revocationGeneration,
                reason: payload.reason.rawValue)
        case .mcpGrantGranted(let payload):
            await retire(
                .attachment(
                    payload.grant.attachmentID,
                    payload.grant.agentID),
                to: payload.grant
                    .revocationGeneration,
                reason: "grant_generation_changed")
        case .mcpGrantRevoked(let payload):
            await retire(
                .attachment(
                    payload.attachmentID,
                    payload.agentID),
                to: payload.revocationGeneration,
                reason: payload.reason.rawValue)
        case .capabilityLeaseRevoked(let payload):
            await retire(
                .capabilityLease(payload.leaseID),
                to: Self.leaseRevocation(
                    "capability",
                    payload.leaseID.rawValue),
                reason:
                    MCPPolicyChangeReason
                        .leaseRevoked.rawValue)
        case .workspaceLeaseRevoked(let payload):
            await retire(
                .workspaceLease(payload.leaseID),
                to: Self.leaseRevocation(
                    "workspace",
                    payload.leaseID.rawValue),
                reason:
                    MCPPolicyChangeReason
                        .leaseRevoked.rawValue)
        case .mcpRootsPolicyUpdated(let payload):
            await retire(
                .all,
                to: payload.revocationGeneration,
                reason:
                    MCPPolicyChangeReason
                        .rootsChanged.rawValue,
                notifyRoots: true)
        case .mcpNetworkPolicyUpdated(let payload):
            await retire(
                .all,
                to: payload.revocationGeneration,
                reason:
                    MCPPolicyChangeReason
                        .networkChanged.rawValue)
        default:
            break
        }
    }

    private func retire(
        _ scope: Scope,
        to generation: MCPRevocationGeneration,
        reason: String,
        notifyRoots: Bool = false
    ) async {
        let snapshots =
            await owner.liveConnectionSnapshots()
        let targets = snapshots.filter { snapshot in
            let authority =
                snapshot.reuseIdentity.authority
            switch scope {
            case .attachment(
                    let attachmentID,
                    let agentID):
                return authority.attachmentID
                        == attachmentID
                    && (agentID == nil
                        || authority.agentID == agentID)
            case .capabilityLease(let leaseID):
                return authority.capabilityLeaseID
                    == leaseID
            case .workspaceLease(let leaseID):
                return authority.workspaceLeaseID
                    == leaseID
            case .all:
                return true
            }
        }
        let services = self.services
        let owner = self.owner
        await withTaskGroup(of: Void.self) { group in
            for snapshot in targets {
                group.addTask {
                    if notifyRoots {
                        try? await snapshot.route
                            .notifyRootsChanged()
                    }
                    let key =
                        snapshot.reuseIdentity.poolKey
                    await services.retire(
                        authorityKey: key)
                    await owner.revokeAuthority(
                        key,
                        to: generation,
                        reason: reason)
                }
            }
        }
    }

    private nonisolated static func leaseRevocation(
        _ kind: String,
        _ identifier: String
    ) -> MCPRevocationGeneration {
        MCPRevocationGeneration(
            rawValue:
                "mcprevocation_"
                    + MCPHostDigest.sha256([
                        "lease",
                        kind,
                        identifier,
                    ]).prefix(24))
    }
}

/// Process/session-owned source used directly by AgentLoop immediately before
/// every provider request.
public actor MCPAgentRequestToolSnapshotSource {
    public nonisolated let owner: MCPSessionRuntimeOwner
    public let planner: MCPAgentDispatchPlanner
    public let publication:
        MCPProductionCatalogPublication
    private let services:
        MCPShippingConnectionServicesRegistry
    private let processRegistry:
        MCPProcessCatalogRuntimeRegistry
    private let consentHandler:
        (any MCPConnectionConsentChallengeHandler)?
    private let resultConverter: MCPToolResultConverter
    private let resourceConverter:
        MCPResourceContentConverter
    private let resourceLimits:
        MCPResourceResultLimits
    private let exposureBudget: MCPToolExposureBudget
    private let executionVerifier:
        MCPEventLogExecutionAuthorityVerifier

    public init(
        owner: MCPSessionRuntimeOwner,
        planner: MCPAgentDispatchPlanner,
        publication:
            MCPProductionCatalogPublication,
        services:
            MCPShippingConnectionServicesRegistry,
        processRegistry:
            MCPProcessCatalogRuntimeRegistry =
                .shared,
        consentHandler:
            (any MCPConnectionConsentChallengeHandler)? = nil,
        resultConverter:
            MCPToolResultConverter = .init(),
        resourceConverter:
            MCPResourceContentConverter = .init(),
        resourceLimits:
            MCPResourceResultLimits = .init(),
        exposureBudget:
            MCPToolExposureBudget = .init()
    ) {
        self.owner = owner
        self.planner = planner
        self.publication = publication
        self.services = services
        self.processRegistry = processRegistry
        self.consentHandler = consentHandler
        self.resultConverter = resultConverter
        self.resourceConverter = resourceConverter
        self.resourceLimits = resourceLimits
        self.exposureBudget = exposureBudget
        executionVerifier =
            MCPEventLogExecutionAuthorityVerifier(
                log: planner.log,
                catalogStore: planner.catalogStore)
    }

    public func snapshot(
        for input: MCPAgentDispatchInput,
        providerCapabilities:
            ToolCallingProviderCapabilities,
        turnResultBudget:
            MCPToolResultAggregateBudget =
                MCPToolResultAggregateBudget(
                    scope: .turn,
                    maximumBytes:
                        MCPToolResultAggregateLimits
                            .maximumTurnBytes)
    ) async throws -> AgentRequestToolSnapshot {
        guard input.activationReason.permitsProviderDispatch else {
            throw MCPRuntimeError
                .activationDoesNotPermitProviderDispatch(
                    input.activationReason)
        }
        let prepared =
            try await preparePublished(input)
        try await ensureExactConnectionConsent(
            prepared,
            handler: nil)
        try await services.register(
            prepared: prepared,
            workspaceLease: input.workspaceLease,
            expiryHandler: {
                [owner] identity, generation in
                await owner.revokeAuthority(
                    identity.poolKey,
                    to: generation,
                    reason:
                        "MCP Agent grant expired")
            })
        let resultConverter = self.resultConverter
        let resourceConverter = self.resourceConverter
        let resourceLimits = self.resourceLimits
        let exposureBudget = self.exposureBudget
        let executionVerifier = self.executionVerifier
        let workspaceLease = input.workspaceLease
        let services = self.services
        let owner = self.owner
        let providerRequestResultBudget =
            MCPToolResultAggregateBudget(
                scope: .providerRequest,
                maximumBytes:
                    MCPToolResultAggregateLimits
                        .maximumProviderRequestBytes)
        return try await owner
            .withPreparedProviderDispatch(
                prepared.plan
            ) { connectionSet in
                let routedConnectionSet =
                    try await services
                        .activateNotificationRoutes(
                            for: connectionSet,
                            owner: owner)
                return try MCPAgentRequestToolSnapshotBuilder
                    .build(
                        connectionSet:
                            routedConnectionSet,
                        baseRegistry:
                            input.baseRegistry,
                        capabilityLease:
                            prepared.capabilityLease,
                        policies: prepared.policies,
                        resourcePolicies:
                            prepared.resourcePolicies,
                        rememberedApprovals:
                            prepared.rememberedApprovals,
                        providerCapabilities:
                            providerCapabilities,
                        resultConverter:
                            resultConverter,
                        resourceConverter:
                            resourceConverter,
                        providerRequestResultBudget:
                            providerRequestResultBudget,
                        turnResultBudget:
                            turnResultBudget,
                        resourceAuthorityVerifier:
                            executionVerifier,
                        workspaceLease:
                            workspaceLease,
                        resourceLimits:
                            resourceLimits,
                        toolExecutionPreflight: {
                            entry in
                            do {
                                try await executionVerifier
                                    .verifyTool(
                                        entry,
                                        workspaceLease:
                                            workspaceLease)
                            } catch {
                                throw ToolExecutionRejectedWithoutSideEffect(
                                    code:
                                        "mcp_authority_revoked",
                                    message:
                                        error.localizedDescription)
                            }
                        },
                        resourceExecutionPreflight: {
                            server in
                            try await executionVerifier
                                .verifyResource(
                                    server,
                                    workspaceLease:
                                        workspaceLease)
                        },
                        exposureBudget:
                            exposureBudget)
            }
    }

    public func connect(
        for input: MCPAgentDispatchInput,
        consentHandler override:
            (any MCPConnectionConsentChallengeHandler)? = nil
    ) async throws -> MCPConnectionSetSnapshot {
        guard input.activationReason
                == .explicitConnect else {
            throw MCPRuntimeError
                .activationDoesNotCreateConnection(
                    input.activationReason)
        }
        let prepared =
            try await preparePublished(input)
        try await ensureExactConnectionConsent(
            prepared,
            handler: override)
        try await services.register(
            prepared: prepared,
            workspaceLease: input.workspaceLease,
            expiryHandler: {
                [owner] identity, generation in
                await owner.revokeAuthority(
                    identity.poolKey,
                    to: generation,
                    reason:
                        "MCP Agent grant expired")
            })
        let connectionSet =
            try await owner.activate(
                prepared.plan)
        return try await services
            .activateNotificationRoutes(
                for: connectionSet,
                owner: owner)
    }

    public func prepare(
        for input: MCPAgentDispatchInput
    ) async throws -> MCPPreparedAgentDispatch {
        try await preparePublished(input)
    }

    private func preparePublished(
        _ input: MCPAgentDispatchInput
    ) async throws -> MCPPreparedAgentDispatch {
        let durableCatalog =
            try await planner.catalogStore.load()
        _ = try await processRegistry.publish(
            durableCatalog)
        let published =
            try await publication.snapshot()
        return try await planner.prepare(
            input,
            catalog: published.catalog)
    }

    private func ensureExactConnectionConsent(
        _ prepared: MCPPreparedAgentDispatch,
        handler override:
            (any MCPConnectionConsentChallengeHandler)?
    ) async throws {
        let source = MCPEventLogExactConsentSource(
            log: planner.log)
        var missing:
            [MCPConnectionConsentChallengeItem] = []
        for requirement in prepared.plan.servers {
            let item =
                MCPConnectionConsentChallengeItem(
                    identity: requirement.identity)
            guard try await source.consent(
                matching: item.requirement) == nil else {
                continue
            }
            missing.append(item)
        }
        guard !missing.isEmpty else { return }
        guard let handler =
                override ?? consentHandler else {
            throw MCPConnectionConsentChallengeError
                .handlerUnavailable
        }
        try await handler.resolveConnectionConsent(
            MCPConnectionConsentChallenge(
                sessionID: prepared.plan.sessionID,
                agentID: prepared.plan.agentID,
                activationReason:
                    prepared.plan.activationReason,
                items: missing))
        for item in missing {
            guard let consent =
                    try await source.consent(
                        matching: item.requirement),
                  item.requirement.exactlyMatches(
                    consent) else {
                throw MCPConnectionConsentChallengeError
                    .consentNotPersisted(
                        item.requirement)
            }
        }
    }
}

public struct MCPShippingSessionRuntime:
    Sendable {
    public let owner: MCPSessionRuntimeOwner
    public let publication:
        MCPProductionCatalogPublication
    public let services:
        MCPShippingConnectionServicesRegistry
    public let snapshots:
        MCPAgentRequestToolSnapshotSource
    public let authorityObserver:
        MCPEventLogAuthorityRevocationObserver
    public let processRegistry:
        MCPProcessCatalogRuntimeRegistry
    public let catalogStore:
        MCPServerCatalogStore
    /// Runtime-owned, process-memory-only sanitizer shared by every
    /// reader-facing MCP output surface for this exact session.
    public let outputRedactor:
        MCPResolvedSecretRedactor

    public init(
        owner: MCPSessionRuntimeOwner,
        publication:
            MCPProductionCatalogPublication,
        services:
            MCPShippingConnectionServicesRegistry,
        snapshots:
            MCPAgentRequestToolSnapshotSource,
        authorityObserver:
            MCPEventLogAuthorityRevocationObserver,
        processRegistry:
            MCPProcessCatalogRuntimeRegistry,
        catalogStore:
            MCPServerCatalogStore,
        outputRedactor:
            MCPResolvedSecretRedactor
    ) {
        self.owner = owner
        self.publication = publication
        self.services = services
        self.snapshots = snapshots
        self.authorityObserver =
            authorityObserver
        self.processRegistry = processRegistry
        self.catalogStore = catalogStore
        self.outputRedactor = outputRedactor
    }

    public static func make(
        sessionID: SessionID,
        hostProfile: MCPProductHostProfile,
        clientVersion: String,
        runtimeIdentityFingerprint: String,
        log: EventLog,
        catalogStore: MCPServerCatalogStore,
        services:
            MCPShippingConnectionServicesRegistry,
        resolveSecret:
            MCPProductionSecretResolver? = nil,
        buildStdio:
            MCPProductionStdioTransportBuilder? = nil,
        buildOAuth:
            MCPProductionOAuthProviderBuilder? = nil,
        processRegistry:
            MCPProcessCatalogRuntimeRegistry =
                .shared,
        consentHandler:
            (any MCPConnectionConsentChallengeHandler)? = nil,
        resultConverter:
            MCPToolResultConverter = .init(),
        resourceConverter:
            MCPResourceContentConverter = .init(),
        resourceLimits:
            MCPResourceResultLimits = .init(),
        exposureBudget:
            MCPToolExposureBudget = .init(),
        outputRedactor:
            MCPResolvedSecretRedactor = .init()
    ) async throws -> MCPShippingSessionRuntime {
        let catalog = try await catalogStore.load()
        let servicesProvider = services.provider()
        let publication =
            try MCPProductionCatalogPublication(
                initialCatalog: catalog
            ) { catalog in
                try MCPProductionConnectionClientFactory(
                    catalog: catalog,
                    hostProfile: hostProfile,
                    clientVersion: clientVersion,
                    resolveSecret: resolveSecret,
                    secretRedactionRegistrar:
                        outputRedactor,
                    outputSanitizer:
                        outputRedactor,
                    buildStdio: buildStdio,
                    buildOAuth: buildOAuth,
                    services: servicesProvider)
            }
        let owner = MCPSessionRuntimeOwner(
            sessionID: sessionID,
            catalogPublication: publication,
            hardGate:
                MCPProductControlPlaneHardGate(
                    sessionID: sessionID,
                    hostProfile: hostProfile),
            consentSource:
                MCPEventLogExactConsentSource(log: log),
            auditSink:
                MCPEventLogControlPlaneAuditSink(log: log),
            inboundNotificationSource:
                services.inboundNotificationStore,
            outputSanitizer:
                outputRedactor)
        await processRegistry.register(
            sessionID: sessionID,
            owner: owner,
            publication: publication,
            consentRevoker:
                MCPEventLogCatalogConsentRevoker(
                    log: log),
            catalogStore: catalogStore)
        let planner = MCPAgentDispatchPlanner(
            sessionID: sessionID,
            hostProfile: hostProfile,
            runtimeIdentityFingerprint:
                runtimeIdentityFingerprint,
            log: log,
            catalogStore: catalogStore)
        let snapshots =
            MCPAgentRequestToolSnapshotSource(
                owner: owner,
                planner: planner,
                publication: publication,
                services: services,
                processRegistry:
                    processRegistry,
                consentHandler:
                    consentHandler,
                resultConverter: resultConverter,
                resourceConverter:
                    resourceConverter,
                resourceLimits:
                    resourceLimits,
                exposureBudget: exposureBudget)
        let authorityObserver =
            MCPEventLogAuthorityRevocationObserver(
                log: log,
                owner: owner,
                services: services)
        try await authorityObserver.start()
        return MCPShippingSessionRuntime(
            owner: owner,
            publication: publication,
            services: services,
            snapshots: snapshots,
            authorityObserver:
                authorityObserver,
            processRegistry: processRegistry,
            catalogStore: catalogStore,
            outputRedactor: outputRedactor)
    }

    @discardableResult
    public func reloadCatalog()
        async throws
        -> MCPProcessCatalogPublicationReport
    {
        try await processRegistry.reloadCatalog(
            from: catalogStore)
    }

    public func installSubscriptionNotificationSink(
        _ sink:
            (any MCPCatalogNotificationSink)?
    ) async {
        await services
            .installSubscriptionNotificationSink(
                sink)
    }

    /// User-triggered full-catalog refresh for one exact live connection
    /// generation. The owner performs durable admission/audit and rejects a
    /// stale identity before using the existing route.
    public func refreshExisting(
        identity: MCPConnectionReuseIdentity,
        generation: MCPConnectionGeneration,
        revocationGeneration:
            MCPRevocationGeneration,
        callerFingerprint: String,
        correlation:
            MCPEventCorrelation = .init(),
        limits:
            MCPFullCatalogDiscoveryLimits = .init()
    ) async throws -> MCPCompleteCatalogSnapshot {
        try await owner.refreshExisting(
            identity: identity,
            generation: generation,
            revocationGeneration:
                revocationGeneration,
            callerFingerprint:
                callerFingerprint,
            correlation: correlation,
            limits: limits)
    }

    /// User-triggered disconnect. Callback/root/task services are retired even
    /// when terminal audit persistence throws after the route was fenced.
    public func disconnect(
        identity: MCPConnectionReuseIdentity,
        replacementRevocationGeneration:
            MCPRevocationGeneration,
        callerFingerprint: String,
        correlation:
            MCPEventCorrelation = .init()
    ) async throws {
        do {
            try await owner.disconnect(
                identity: identity,
                replacementRevocationGeneration:
                    replacementRevocationGeneration,
                callerFingerprint:
                    callerFingerprint,
                correlation: correlation)
        } catch {
            await services.retire(
                authorityKey:
                    identity.poolKey)
            throw error
        }
        await services.retire(
            authorityKey:
                identity.poolKey)
    }

    @discardableResult
    public func shutdown(
        reason: String
    ) async -> MCPRuntimeShutdownReport {
        await authorityObserver.stop()
        let report =
            await owner.shutdown(reason: reason)
        await services.shutdownAndDrain()
        await processRegistry.unregister(
            sessionID: owner.sessionID)
        outputRedactor
            .clearMCPSecretRedactionValues()
        return report
    }
}

public enum MCPHostDigest {
    public static func sha256(
        _ fields: [String]
    ) -> String {
        let material = fields.map {
            "\($0.utf8.count):\($0)"
        }.joined(separator: "|")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func workspaceRootIdentity(
        _ identity: WorkspaceRootIdentity
    ) -> String {
        SHA256.hash(data: Data([
            identity.canonicalPath,
            String(identity.deviceID),
            String(identity.fileID),
        ].joined(separator: "\u{1f}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private extension MCPTransportConfiguration {
    var canonicalNetworkOrigin: String? {
        guard case .streamableHTTP(let configuration) =
                self else {
            return nil
        }
        return configuration.canonicalOrigin
    }
}
