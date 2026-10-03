#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisMCP requires CryptoKit or swift-crypto")
#endif
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools

public enum MCPQualifiedToolNameError:
    Error, Equatable, LocalizedError, Sendable {
    case emptyAlias
    case invalidMaximumLength
    case collision(String)

    public var errorDescription: String? {
        switch self {
        case .emptyAlias:
            return "MCP server or tool alias is empty after normalization"
        case .invalidMaximumLength:
            return "MCP qualified tool-name limit is too small"
        case .collision(let name):
            return "more than one MCP tool maps to model-visible name '\(name)'"
        }
    }
}

public struct MCPQualifiedToolName:
    Codable, Equatable, Hashable, Sendable {
    public let value: String
    public let namespace: String
    public let toolAlias: String

    public init(
        serverAlias: String,
        remoteToolName: String,
        maximumLength: Int = 128
    ) throws {
        guard maximumLength >= 24 else {
            throw MCPQualifiedToolNameError.invalidMaximumLength
        }
        let normalizedServer = Self.normalize(serverAlias)
        let normalizedTool = Self.normalize(remoteToolName)
        guard !normalizedServer.isEmpty, !normalizedTool.isEmpty else {
            throw MCPQualifiedToolNameError.emptyAlias
        }
        let namespaceStem = try Self.bounded(
            "mcp__\(normalizedServer)",
            source: "namespace\u{1f}\(serverAlias)",
            maximumLength: min(62, maximumLength - 2))
        namespace = namespaceStem + "__"
        toolAlias = try Self.bounded(
            normalizedTool,
            source: "tool\u{1f}\(remoteToolName)",
            maximumLength: min(64, maximumLength))
        value = try Self.bounded(
            "\(namespace)\(toolAlias)",
            source: "qualified\u{1f}\(serverAlias)\u{1f}\(remoteToolName)",
            maximumLength: maximumLength)
    }

    private static func normalize(_ value: String) -> String {
        var result = ""
        var lastWasSeparator = false
        for scalar in value.unicodeScalars {
            let isAllowed = CharacterSet.alphanumerics.contains(scalar)
                || scalar == "_" || scalar == "-"
            if isAllowed {
                result.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                result.append("_")
                lastWasSeparator = true
            }
        }
        return result.trimmingCharacters(
            in: CharacterSet(charactersIn: "_-"))
    }

    private static func bounded(
        _ value: String,
        source: String,
        maximumLength: Int
    ) throws -> String {
        guard maximumLength >= 24 else {
            throw MCPQualifiedToolNameError.invalidMaximumLength
        }
        if value.count <= maximumLength { return value }
        let digest = SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let suffix = "__" + digest.prefix(16)
        return String(value.prefix(maximumLength - suffix.count)) + suffix
    }
}

public struct MCPToolBindingPolicy: Equatable, Sendable {
    public let server: MCPServerReference
    public let attachmentID: MCPAttachmentID
    public let serverAlias: String
    public let serverFilter: MCPNameFilter
    public let attachmentFilter: MCPNameFilter
    public let effectiveApprovalMode: MCPApprovalMode
    public let approvalDecision: MCPApprovalDecision
    public let approvalPolicySource: MCPApprovalPolicySource
    /// Exact immutable per-tool overrides from the server revision. They are
    /// resolved only after discovery identifies the remote tool name.
    public let toolApprovalOverrides: [String: MCPApprovalMode]
    public let serverDefaultApprovalMode: MCPApprovalMode?
    /// Session and Agent policy can only tighten a per-tool server override.
    public let attachmentApprovalMode: MCPApprovalMode?
    public let grantApprovalModeCeiling: MCPApprovalMode?
    public let sideEffect: SideEffect
    public let risksNetwork: Bool
    public let networkOrigin: String?
    public let supportsParallelCalls: Bool
    public let taskPreference: MCPTaskInvocationPreference
    public let taskTTLMilliseconds: Int?
    public let policyFingerprint: String

    public init(
        server: MCPServerReference,
        attachmentID: MCPAttachmentID,
        serverAlias: String,
        serverFilter: MCPNameFilter = .init(),
        attachmentFilter: MCPNameFilter = .init(),
        effectiveApprovalMode: MCPApprovalMode,
        approvalDecision: MCPApprovalDecision = .askUser,
        approvalPolicySource: MCPApprovalPolicySource = .hostPolicy,
        toolApprovalOverrides: [String: MCPApprovalMode] = [:],
        serverDefaultApprovalMode: MCPApprovalMode? = nil,
        attachmentApprovalMode: MCPApprovalMode? = nil,
        grantApprovalModeCeiling: MCPApprovalMode? = nil,
        sideEffect: SideEffect,
        risksNetwork: Bool,
        networkOrigin: String? = nil,
        supportsParallelCalls: Bool = false,
        taskPreference: MCPTaskInvocationPreference = .automatic,
        taskTTLMilliseconds: Int? = nil,
        policyFingerprint: String
    ) {
        self.server = server
        self.attachmentID = attachmentID
        self.serverAlias = serverAlias
        self.serverFilter = serverFilter
        self.attachmentFilter = attachmentFilter
        self.effectiveApprovalMode = effectiveApprovalMode
        self.approvalDecision = approvalDecision
        self.approvalPolicySource = approvalPolicySource
        self.toolApprovalOverrides = toolApprovalOverrides
        self.serverDefaultApprovalMode =
            serverDefaultApprovalMode
        self.attachmentApprovalMode = attachmentApprovalMode
        self.grantApprovalModeCeiling = grantApprovalModeCeiling
        self.sideEffect = sideEffect
        self.risksNetwork = risksNetwork
        self.networkOrigin = networkOrigin
        self.supportsParallelCalls = supportsParallelCalls
        self.taskPreference = taskPreference
        self.taskTTLMilliseconds = taskTTLMilliseconds
        self.policyFingerprint = policyFingerprint
    }

    public func approval(
        for remoteToolName: String
    ) -> (
        mode: MCPApprovalMode,
        decision: MCPApprovalDecision,
        source: MCPApprovalPolicySource
    ) {
        var mode: MCPApprovalMode
        var source: MCPApprovalPolicySource
        if let override =
                toolApprovalOverrides[remoteToolName] {
            // A per-tool value replaces the server default, then outer
            // attachment/grant layers may only tighten it.
            mode = override
            source = .toolOverride
        } else if let serverDefaultApprovalMode {
            mode = serverDefaultApprovalMode
            source = .serverDefault
        } else {
            mode = effectiveApprovalMode
            source = approvalPolicySource
        }
        if let attachmentApprovalMode {
            let tightened =
                MCPApprovalPolicy.mostRestrictive(
                    mode,
                    attachmentApprovalMode)
            if tightened != mode {
                mode = tightened
                source = .attachment
            }
        }
        if let grantApprovalModeCeiling {
            let tightened =
                MCPApprovalPolicy.mostRestrictive(
                    mode,
                    grantApprovalModeCeiling)
            if tightened != mode {
                mode = tightened
                source = .agentGrant
            }
        }
        return (
            mode,
            Self.decision(
                mode: mode,
                sideEffect: sideEffect,
                fallback: approvalDecision),
            source)
    }

    private static func decision(
        mode: MCPApprovalMode,
        sideEffect: SideEffect,
        fallback: MCPApprovalDecision
    ) -> MCPApprovalDecision {
        switch mode {
        case .approve:
            return .allow
        case .writes where sideEffect == .readOnly:
            return .allow
        case .auto, .prompt, .writes:
            // An exact remembered-auto decision, if any, is injected by the
            // host authorization projection. No other mode is remembered.
            return fallback == .deny ? .deny : .askUser
        }
    }
}

public enum MCPToolBindingError:
    Error, Equatable, LocalizedError, Sendable {
    case wrongAgent
    case ambiguousPolicy(MCPAttachmentID)
    case missingPolicy(MCPAttachmentID)
    case missingGrant(MCPAttachmentID)
    case ambiguousGrant(MCPAttachmentID)
    case grantAuthorityMismatch
    case grantRevoked
    case capabilityLeaseMismatch
    case ambiguousRememberedApproval
    case catalogViewRevisionMismatch(
        expected: MCPAgentCatalogViewRevision,
        actual: MCPAgentCatalogViewRevision)
    case catalogHasNoRawTools(MCPRawCatalogRevision)
    case qualifiedNameCollision(String)

    public var errorDescription: String? {
        switch self {
        case .wrongAgent:
            return "MCP connection set and capability lease belong to different Agents"
        case .ambiguousPolicy(let attachment):
            return "MCP attachment \(attachment) has more than one frozen tool policy"
        case .missingPolicy(let attachment):
            return "MCP attachment \(attachment) has no frozen tool policy"
        case .missingGrant(let attachment):
            return "MCP attachment \(attachment) has no exact Agent tool grant"
        case .ambiguousGrant(let attachment):
            return "MCP attachment \(attachment) has more than one matching Agent grant"
        case .grantAuthorityMismatch:
            return "MCP grant authority does not match the connection"
        case .grantRevoked:
            return "MCP grant revocation generation is stale"
        case .capabilityLeaseMismatch:
            return "MCP connection authority does not match the active capability lease"
        case .ambiguousRememberedApproval:
            return "more than one exact MCP remembered approval is active"
        case .catalogViewRevisionMismatch(let expected, let actual):
            return "MCP Agent catalog view mismatch; expected \(expected), got \(actual)"
        case .catalogHasNoRawTools(let revision):
            return "MCP raw catalog \(revision) has tool identities but no complete raw records"
        case .qualifiedNameCollision(let name):
            return "MCP model-visible tool name collision: \(name)"
        }
    }
}

public struct MCPToolBindingEntry: Sendable {
    public let qualifiedName: MCPQualifiedToolName
    public let remoteTool: MCPRawToolRecord
    public let connection: MCPConnectionSnapshot
    public let grant: MCPGrant
    public let policy: MCPToolBindingPolicy
    public let authorization: MCPToolAuthorizationSnapshot
}

public struct MCPAgentToolCatalogView: Sendable {
    public let connectionSetSnapshotID: MCPConnectionSetSnapshotID
    public let bindingID: MCPBindingID
    public let agentID: AgentID
    public let entries: [MCPToolBindingEntry]
    public let stableFingerprint: String

    public static func deriveRevision(
        connection: MCPConnectionSnapshot,
        grant: MCPGrant,
        policy: MCPToolBindingPolicy
    ) -> MCPAgentCatalogViewRevision {
        MCPAgentCatalogViewRevision(
            rawValue: "mcpview_" + String(
                stableHash([
                    "mcp-agent-tool-view-v1",
                    connection.bindingIdentity.rawCatalogRevision.rawValue,
                    connection.catalog.catalogFingerprint,
                    grant.grantID.rawValue,
                    grant.grantFingerprint,
                    grant.filter.revision.rawValue,
                    grant.revocationGeneration.rawValue,
                    String(describing: policy.taskPreference),
                    policy.taskTTLMilliseconds.map(String.init) ?? "nil",
                    policy.policyFingerprint,
                ]).prefix(32)))
    }

    public static func build(
        connectionSet: MCPConnectionSetSnapshot,
        capabilityLease: CapabilityLease,
        policies: [MCPToolBindingPolicy],
        rememberedApprovals:
            [MCPRememberedToolApproval] = [],
        at date: Date = Date()
    ) throws -> MCPAgentToolCatalogView {
        var policyByAttachment: [MCPAttachmentID: MCPToolBindingPolicy] = [:]
        for policy in policies {
            guard policyByAttachment.updateValue(
                policy,
                forKey: policy.attachmentID) == nil else {
                throw MCPToolBindingError.ambiguousPolicy(
                    policy.attachmentID)
            }
        }
        var entries: [MCPToolBindingEntry] = []
        var mappedNames: [String: (MCPServerReference, String)] = [:]

        for frozenConnection in connectionSet.connections {
            // A tools/list_changed notification invalidates model exposure
            // immediately. Existing prepared calls are fenced again by the
            // exact ManagedConnection route; new snapshots must expose none
            // until a complete replacement catalog is published.
            if frozenConnection.unavailableCatalogKinds.contains(.tools) {
                continue
            }
            let authority = frozenConnection.reuseIdentity.authority
            guard authority.agentID == connectionSet.agentID else {
                throw MCPToolBindingError.wrongAgent
            }
            guard authority.hasCurrentExecutionAuthority,
                  authority.capabilityLeaseID == capabilityLease.id,
                  authority.capabilityTaskID
                    == capabilityLease.taskID else {
                throw MCPToolBindingError.capabilityLeaseMismatch
            }
            guard let policy = policyByAttachment[authority.attachmentID],
                  policy.server == frozenConnection.reuseIdentity.server else {
                throw MCPToolBindingError.missingPolicy(
                    authority.attachmentID)
            }
            let matchingGrants = capabilityLease.mcpGrants.filter {
                $0.attachmentID == authority.attachmentID
                    && $0.server == frozenConnection.reuseIdentity.server
                    && $0.agentID == connectionSet.agentID
                    && $0.capabilityLeaseID
                        == capabilityLease.id
                    && $0.taskID
                        == capabilityLease.taskID
                    && $0.grants(.tools)
                    && $0.isActive(at: date)
            }
            guard !matchingGrants.isEmpty else {
                // Absence of a live exact grant is denial, not an implicit
                // attachment-wide grant. Control-plane Agents and new workers
                // therefore receive an empty view by default.
                continue
            }
            guard matchingGrants.count == 1,
                  let grant = matchingGrants.first else {
                throw MCPToolBindingError.ambiguousGrant(
                    authority.attachmentID)
            }
            guard grant.authorityFingerprint == authority.fingerprint else {
                throw MCPToolBindingError.grantAuthorityMismatch
            }
            guard grant.revocationGeneration
                    == frozenConnection.bindingIdentity
                        .revocationGeneration else {
                throw MCPToolBindingError.grantRevoked
            }
            let expectedView = deriveRevision(
                connection: frozenConnection,
                grant: grant,
                policy: policy)
            // The connection requirement is necessarily created before first
            // discovery, so its view revision is provisional. Rebind only this
            // retained snapshot after discovery; all transport/generation/raw
            // catalog/binding/revocation fences remain exact.
            let connection =
                frozenConnection
                    .rebindingAgentCatalogViewRevision(
                        expectedView)
            if connection.catalog.items.contains(where: {
                $0.kind == .tool
            }), connection.catalog.tools.isEmpty {
                throw MCPToolBindingError.catalogHasNoRawTools(
                    connection.catalog.revision)
            }

            for tool in connection.catalog.tools {
                guard policy.serverFilter.allows(tool.remoteName),
                      policy.attachmentFilter.allows(tool.remoteName),
                      grant.filter.tools.allows(tool.remoteName) else {
                    continue
                }
                let name = try MCPQualifiedToolName(
                    serverAlias: policy.serverAlias,
                    remoteToolName: tool.remoteName)
                let target = (connection.reuseIdentity.server, tool.remoteName)
                if let previous = mappedNames[name.value],
                   previous.0 != target.0 || previous.1 != target.1 {
                    throw MCPToolBindingError.qualifiedNameCollision(
                        name.value)
                }
                mappedNames[name.value] = target
                let binding = connection.bindingIdentity
                let approval = policy.approval(
                    for: tool.remoteName)
                let candidateAuthorization =
                    MCPToolAuthorizationSnapshot(
                    server: binding.server,
                    attachmentID: authority.attachmentID,
                    grantID: grant.grantID,
                    grantFingerprint: grant.grantFingerprint,
                    connectionGeneration: binding.connectionGeneration,
                    rawCatalogRevision: binding.rawCatalogRevision,
                    agentCatalogViewRevision:
                        binding.agentCatalogViewRevision,
                    bindingID: binding.bindingID,
                    remoteToolName: tool.remoteName,
                    schemaHash: tool.inputSchemaHash,
                    protocolProfile: binding.protocolProfile,
                    maximumProtocolVersion:
                        binding.maximumProtocolVersion,
                    negotiatedProtocolVersion:
                        binding.negotiatedProtocolVersion,
                    effectiveApprovalMode:
                        approval.mode,
                    approvalDecision: approval.decision,
                    approvalPolicySource:
                        approval.source,
                    accountReference:
                        connection.reuseIdentity.oauthAccountReference,
                    environmentReference:
                        connection.reuseIdentity.environmentReference,
                    authorityFingerprint: authority.fingerprint,
                    revocationGeneration:
                        binding.revocationGeneration)
                let rememberedMatches =
                    approval.mode == .auto
                        && approval.decision != .deny
                    ? rememberedApprovals.filter {
                        $0.exactlyMatches(
                            candidateAuthorization,
                            at: date)
                    }
                    : []
                guard rememberedMatches.count <= 1 else {
                    throw MCPToolBindingError
                        .ambiguousRememberedApproval
                }
                let authorization =
                    rememberedMatches.isEmpty
                    ? candidateAuthorization
                    : MCPToolAuthorizationSnapshot(
                        server:
                            candidateAuthorization.server,
                        attachmentID:
                            candidateAuthorization.attachmentID,
                        grantID:
                            candidateAuthorization.grantID,
                        grantFingerprint:
                            candidateAuthorization.grantFingerprint,
                        connectionGeneration:
                            candidateAuthorization.connectionGeneration,
                        rawCatalogRevision:
                            candidateAuthorization.rawCatalogRevision,
                        agentCatalogViewRevision:
                            candidateAuthorization
                                .agentCatalogViewRevision,
                        bindingID:
                            candidateAuthorization.bindingID,
                        remoteToolName:
                            candidateAuthorization.remoteToolName,
                        schemaHash:
                            candidateAuthorization.schemaHash,
                        protocolProfile:
                            candidateAuthorization.protocolProfile,
                        maximumProtocolVersion:
                            candidateAuthorization
                                .maximumProtocolVersion,
                        negotiatedProtocolVersion:
                            candidateAuthorization
                                .negotiatedProtocolVersion,
                        effectiveApprovalMode: .auto,
                        approvalDecision: .allow,
                        approvalPolicySource:
                            candidateAuthorization
                                .approvalPolicySource,
                        accountReference:
                            candidateAuthorization.accountReference,
                        environmentReference:
                            candidateAuthorization
                                .environmentReference,
                        authorityFingerprint:
                            candidateAuthorization
                                .authorityFingerprint,
                        revocationGeneration:
                            candidateAuthorization
                                .revocationGeneration)
                entries.append(MCPToolBindingEntry(
                    qualifiedName: name,
                    remoteTool: tool,
                    connection: connection,
                    grant: grant,
                    policy: policy,
                    authorization: authorization))
            }
        }

        entries.sort {
            if $0.qualifiedName.value != $1.qualifiedName.value {
                return $0.qualifiedName.value < $1.qualifiedName.value
            }
            return $0.remoteTool.identityFingerprint
                < $1.remoteTool.identityFingerprint
        }
        let fingerprint = stableHash(
            ["mcp-agent-tool-catalog-v1",
             connectionSet.snapshotID.rawValue,
             connectionSet.bindingID.rawValue,
             capabilityLease.id.rawValue]
                + entries.flatMap {
                    [
                        $0.qualifiedName.value,
                        $0.remoteTool.identityFingerprint,
                        $0.authorization.grantFingerprint,
                        $0.authorization.rawCatalogRevision.rawValue,
                        $0.authorization.agentCatalogViewRevision.rawValue,
                        $0.authorization.connectionGeneration.rawValue,
                        $0.authorization.revocationGeneration.rawValue,
                        $0.remoteTool.taskSupport?.rawValue ?? "forbidden",
                        String(describing: $0.policy.taskPreference),
                        $0.policy.taskTTLMilliseconds.map(String.init) ?? "nil",
                    ]
                })
        return MCPAgentToolCatalogView(
            connectionSetSnapshotID: connectionSet.snapshotID,
            bindingID: connectionSet.bindingID,
            agentID: connectionSet.agentID,
            entries: entries,
            stableFingerprint: fingerprint)
    }

    init(
        connectionSetSnapshotID: MCPConnectionSetSnapshotID,
        bindingID: MCPBindingID,
        agentID: AgentID,
        entries: [MCPToolBindingEntry],
        stableFingerprint: String
    ) {
        self.connectionSetSnapshotID = connectionSetSnapshotID
        self.bindingID = bindingID
        self.agentID = agentID
        self.entries = entries
        self.stableFingerprint = stableFingerprint
    }
}

public struct DynamicMCPTool: Tool, Sendable {
    public static let descriptor = ToolDescriptor(
        name: "_dynamic_mcp_tool_requires_instance_registration",
        description: "Dynamic MCP tools require an instance descriptor.",
        sideEffect: .destructive,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ]))

    private let entry: MCPToolBindingEntry
    private let resultConverter: MCPToolResultConverter
    private let executionPreflight:
        @Sendable (MCPToolBindingEntry) async throws -> Void

    public init(
        entry: MCPToolBindingEntry,
        resultConverter: MCPToolResultConverter,
        executionPreflight:
            @escaping @Sendable (
                MCPToolBindingEntry
            ) async throws -> Void = { _ in }
    ) {
        self.entry = entry
        self.resultConverter = resultConverter
        self.executionPreflight = executionPreflight
    }

    public func risksNetwork(_ args: ToolArgs) -> Bool {
        entry.policy.risksNetwork
    }

    public func permissionIntent(
        _ args: ToolArgs,
        descriptor: ToolDescriptor,
        workspaceRoot _: URL
    ) -> PermissionIntent {
        var resources = [
            PermissionResource(
                kind: .tool,
                value: descriptor.name),
        ]
        if let origin = entry.policy.networkOrigin {
            resources.append(PermissionResource(kind: .url, value: origin))
        }
        var metadata: [String: JSONValue] = [
            "mcp_server_id": .string(
                entry.authorization.server.serverID.rawValue),
            "mcp_server_revision": .string(
                entry.authorization.server.serverRevision.rawValue),
            "mcp_remote_tool": .string(
                entry.authorization.remoteToolName),
            "mcp_schema_hash": .string(
                entry.authorization.schemaHash),
            "mcp_authority": .string(
                entry.authorization.authorityFingerprint),
        ]
        if let account = entry.authorization.accountReference {
            metadata["mcp_account_reference"] = .string(account.rawValue)
        }
        return PermissionIntent(
            action: "mcp.tool.call",
            resources: resources,
            metadata: metadata,
            dataEffects: entry.policy.risksNetwork
                ? [.network]
                : [.execute],
            risks: entry.policy.risksNetwork
                ? [.networkAccess]
                : [.processExecution],
            replayPolicy: .doNotReplay)
    }

    public func execute(
        _ args: ToolArgs,
        in context: ToolContext
    ) async throws -> ToolObservation {
        guard context.authorization?.mcp == entry.authorization else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "mcp_authorization_mismatch",
                message: "exact MCP authorization is absent or changed")
        }
        let value: JSONValue
        do {
            value = try args.decode(JSONValue.self)
            try MCPJSONSchema.validate(
                value,
                against: entry.remoteTool.inputSchema)
        } catch {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "mcp_input_schema_invalid",
                message: error.localizedDescription)
        }
        guard case .object(let object) = value else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "mcp_input_not_object",
                message: "MCP tool arguments must be one JSON object")
        }

        let result: MCPRawToolCallResult
        do {
            try await executionPreflight(entry)
            result = try await entry.connection.route.callToolResolved(
                remoteName: entry.remoteTool.remoteName,
                arguments: object,
                toolTaskSupport: entry.remoteTool.taskSupport,
                preference: entry.policy.taskPreference,
                ttlMilliseconds: entry.policy.taskTTLMilliseconds,
                originatingToolCallID: context.executionID)
        } catch let error
            as ToolExecutionRejectedWithoutSideEffect {
            throw error
        } catch let error as MCPToolExecutionError {
            switch error {
            case .executionUncertain:
                throw error
            default:
                throw ToolExecutionRejectedWithoutSideEffect(
                    code: "mcp_call_not_started",
                    message: error.localizedDescription)
            }
        } catch let error as MCPConnectionError {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "mcp_route_stale",
                message: error.localizedDescription)
        } catch let error as MCPTaskAugmentationError {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "mcp_task_augmentation_rejected",
                message: error.localizedDescription)
        } catch let error as MCPTaskRuntimeError {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "mcp_task_not_started",
                message: error.localizedDescription)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MCPToolExecutionError.executionUncertain(
                String(error.localizedDescription.prefix(512)))
        }

        let binding = entry.connection.bindingIdentity
        let provenance = MCPContentProvenance(
            sourceKind: .tool,
            server: binding.server,
            connectionGeneration: binding.connectionGeneration,
            rawCatalogRevision: binding.rawCatalogRevision,
            agentCatalogViewRevision:
                binding.agentCatalogViewRevision,
            bindingID: binding.bindingID,
            protocolProfile: binding.protocolProfile,
            maximumProtocolVersion:
                binding.maximumProtocolVersion,
            negotiatedProtocolVersion:
                binding.negotiatedProtocolVersion,
            remoteName: entry.remoteTool.remoteName,
            schemaHash: entry.remoteTool.inputSchemaHash,
            accountReference:
                entry.connection.reuseIdentity.oauthAccountReference,
            environmentReference:
                entry.connection.reuseIdentity.environmentReference)
        return try await resultConverter.convert(
            result,
            outputSchema: entry.remoteTool.outputSchema,
            outputSchemaHash: entry.remoteTool.outputSchemaHash,
            provenance: provenance)
    }
}

public enum MCPToolRegistryBuilder {
    public static func registryVersion(
        base: ToolRegistry,
        view: MCPAgentToolCatalogView,
        deferLoading: Bool = false
    ) -> String {
        IntatisHostApplication.identity
            .namespacedIdentifier("mcp.registry.v1.") + stableHash([
            base.registryVersion,
            view.connectionSetSnapshotID.rawValue,
            view.bindingID.rawValue,
            view.stableFingerprint,
            deferLoading ? "deferred" : "direct",
        ])
    }

    public static func build(
        base: ToolRegistry,
        view: MCPAgentToolCatalogView,
        resultConverter: MCPToolResultConverter,
        deferLoading: Bool = false,
        executionPreflight:
            @escaping @Sendable (
                MCPToolBindingEntry
            ) async throws -> Void = { _ in }
    ) -> ToolRegistry {
        let version = registryVersion(
            base: base,
            view: view,
            deferLoading: deferLoading)
        let registrations = view.entries.map { entry in
            let tool = DynamicMCPTool(
                entry: entry,
                resultConverter: resultConverter,
                executionPreflight: executionPreflight)
            let descriptor = ToolDescriptor(
                name: entry.qualifiedName.value,
                description: entry.remoteTool.summary,
                sideEffect: entry.policy.sideEffect,
                parameters: entry.remoteTool.inputSchema,
                strict: false,
                deferLoading: deferLoading ? true : nil,
                // Output schemas are retained on the exact registration and
                // validated after tools/call. They are not model input.
                outputSchema: nil,
                supportsParallelCalls:
                    entry.policy.supportsParallelCalls)
            return ToolRegistration(
                descriptor: descriptor,
                tool: tool,
                canonicalPermission: "mcp.tool.call",
                mcpAuthorization: entry.authorization,
                argumentValidator: { args in
                    let value = try args.decode(JSONValue.self)
                    try MCPJSONSchema.validate(
                        value,
                        against: entry.remoteTool.inputSchema)
                })
        }
        return base.adding(
            registrations: registrations,
            registryVersion: version)
    }
}

func stableHash(_ fields: [String]) -> String {
    let material = fields.map {
        "\($0.utf8.count):\($0)"
    }.joined()
    return SHA256.hash(data: Data(material.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}
