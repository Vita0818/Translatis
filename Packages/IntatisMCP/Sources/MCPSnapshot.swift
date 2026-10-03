import Foundation
import IntatisCore
import IntatisProtocol

/// Identity of one immutable connection-set publication.
///
/// A provider dispatch owns this snapshot until every tool call from that
/// response has settled. Publishing a later snapshot never mutates this one.
public struct MCPConnectionSetSnapshotID: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func new() -> MCPConnectionSetSnapshotID {
        MCPConnectionSetSnapshotID(
            rawValue: IDGen.random(prefix: "mcpcset"))
    }
}

public enum MCPPublishedCatalogItemKind: String, Codable, Hashable, Sendable {
    case tool
    case resource
    case resourceTemplate = "resource_template"
    case prompt
}

/// A secret-free identity record in a complete raw catalog publication.
///
/// The complete schema/payload remains owned by the later discovery layer.
/// W3 needs only enough immutable identity to prove that a route never swaps
/// from one publication to another.
public struct MCPPublishedCatalogItem: Codable, Equatable, Hashable, Sendable {
    public let kind: MCPPublishedCatalogItemKind
    public let remoteName: String
    public let identityFingerprint: String
    public let schemaHash: String?

    public init(
        kind: MCPPublishedCatalogItemKind,
        remoteName: String,
        identityFingerprint: String,
        schemaHash: String? = nil
    ) {
        self.kind = kind
        self.remoteName = remoteName
        self.identityFingerprint = identityFingerprint
        self.schemaHash = schemaHash
    }
}

public enum MCPCompleteCatalogSnapshotError: Error, Equatable, LocalizedError {
    case emptyCatalogFingerprint
    case emptyItemName(MCPPublishedCatalogItemKind)
    case emptyItemFingerprint(
        MCPPublishedCatalogItemKind,
        remoteName: String
    )
    case duplicateItem(
        MCPPublishedCatalogItemKind,
        remoteName: String
    )

    public var errorDescription: String? {
        switch self {
        case .emptyCatalogFingerprint:
            return "MCP complete catalog fingerprint is empty"
        case .emptyItemName(let kind):
            return "MCP \(kind.rawValue) catalog item has an empty name"
        case .emptyItemFingerprint(let kind, let remoteName):
            return "MCP \(kind.rawValue) catalog item '\(remoteName)' has an empty identity fingerprint"
        case .duplicateItem(let kind, let remoteName):
            return "MCP complete catalog contains duplicate \(kind.rawValue) item '\(remoteName)'"
        }
    }
}

/// A complete, already-validated raw catalog.
///
/// There is intentionally no incremental mutation API. Discovery builds one
/// value off to the side and the connection actor replaces its catalog with
/// this value in one actor-isolated assignment.
public struct MCPCompleteCatalogSnapshot: Codable, Equatable, Sendable {
    public let revision: MCPRawCatalogRevision
    public let catalogFingerprint: String
    public let items: [MCPPublishedCatalogItem]
    /// Full validated raw tool records published atomically with the identity
    /// index. Legacy identity-only test fixtures decode with an empty array.
    public let tools: [MCPRawToolRecord]
    /// Full validated raw resource, template, and prompt records. These arrays
    /// are part of the same immutable publication as `tools`; discovery never
    /// exposes a category page before every negotiated category has settled.
    public let resources: [MCPRawResourceRecord]
    public let resourceTemplates: [MCPRawResourceTemplateRecord]
    public let prompts: [MCPRawPromptRecord]

    public init(
        revision: MCPRawCatalogRevision,
        catalogFingerprint: String,
        items: [MCPPublishedCatalogItem],
        tools: [MCPRawToolRecord] = [],
        resources: [MCPRawResourceRecord] = [],
        resourceTemplates: [MCPRawResourceTemplateRecord] = [],
        prompts: [MCPRawPromptRecord] = []
    ) throws {
        guard !catalogFingerprint.isEmpty else {
            throw MCPCompleteCatalogSnapshotError.emptyCatalogFingerprint
        }

        var seen: Set<CatalogItemKey> = []
        for item in items {
            guard !item.remoteName.isEmpty else {
                throw MCPCompleteCatalogSnapshotError.emptyItemName(item.kind)
            }
            guard !item.identityFingerprint.isEmpty else {
                throw MCPCompleteCatalogSnapshotError.emptyItemFingerprint(
                    item.kind,
                    remoteName: item.remoteName)
            }
            let key = CatalogItemKey(
                kind: item.kind,
                remoteName: item.remoteName)
            guard seen.insert(key).inserted else {
                throw MCPCompleteCatalogSnapshotError.duplicateItem(
                    item.kind,
                    remoteName: item.remoteName)
            }
        }

        let validatedTools = try tools.map { try $0.validated() }
        let validatedResources = try resources.map { try $0.validated() }
        let validatedTemplates = try resourceTemplates.map {
            try $0.validated()
        }
        let validatedPrompts = try prompts.map { try $0.validated() }
        if !validatedTools.isEmpty {
            let toolItems = items.filter { $0.kind == .tool }
            guard toolItems.count == validatedTools.count else {
                throw MCPToolCatalogError.completeSnapshotMismatch(
                    "tool identity and raw-record counts differ")
            }
            let indexed = Dictionary(
                uniqueKeysWithValues: toolItems.map {
                    ($0.remoteName, $0)
                })
            for tool in validatedTools {
                guard let item = indexed[tool.remoteName],
                      item.identityFingerprint
                        == tool.identityFingerprint,
                      item.schemaHash == tool.inputSchemaHash else {
                    throw MCPToolCatalogError.completeSnapshotMismatch(
                        "tool '\(tool.remoteName)' identity does not match its raw record")
                }
            }
        }
        try Self.validateRawRecords(
            kind: .resource,
            items: items,
            records: validatedResources.map {
                ($0.uri, $0.identityFingerprint)
            })
        try Self.validateRawRecords(
            kind: .resourceTemplate,
            items: items,
            records: validatedTemplates.map {
                ($0.uriTemplate, $0.identityFingerprint)
            })
        try Self.validateRawRecords(
            kind: .prompt,
            items: items,
            records: validatedPrompts.map {
                ($0.name, $0.identityFingerprint)
            })

        self.revision = revision
        self.catalogFingerprint = catalogFingerprint
        self.items = items.sorted(by: Self.itemPrecedes)
        self.tools = validatedTools.sorted {
            if $0.remoteName != $1.remoteName {
                return $0.remoteName < $1.remoteName
            }
            return $0.identityFingerprint < $1.identityFingerprint
        }
        self.resources = validatedResources.sorted {
            $0.uri < $1.uri
        }
        self.resourceTemplates = validatedTemplates.sorted {
            $0.uriTemplate < $1.uriTemplate
        }
        self.prompts = validatedPrompts.sorted {
            $0.name < $1.name
        }
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case catalogFingerprint
        case items
        case tools
        case resources
        case resourceTemplates
        case prompts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            revision: container.decode(
                MCPRawCatalogRevision.self,
                forKey: .revision),
            catalogFingerprint: container.decode(
                String.self,
                forKey: .catalogFingerprint),
            items: container.decode(
                [MCPPublishedCatalogItem].self,
                forKey: .items),
            tools: container.decodeIfPresent(
                [MCPRawToolRecord].self,
                forKey: .tools) ?? [],
            resources: container.decodeIfPresent(
                [MCPRawResourceRecord].self,
                forKey: .resources) ?? [],
            resourceTemplates: container.decodeIfPresent(
                [MCPRawResourceTemplateRecord].self,
                forKey: .resourceTemplates) ?? [],
            prompts: container.decodeIfPresent(
                [MCPRawPromptRecord].self,
                forKey: .prompts) ?? [])
    }

    private struct CatalogItemKey: Hashable {
        let kind: MCPPublishedCatalogItemKind
        let remoteName: String
    }

    private static func itemPrecedes(
        _ lhs: MCPPublishedCatalogItem,
        _ rhs: MCPPublishedCatalogItem
    ) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        if lhs.remoteName != rhs.remoteName {
            return lhs.remoteName < rhs.remoteName
        }
        if lhs.identityFingerprint != rhs.identityFingerprint {
            return lhs.identityFingerprint < rhs.identityFingerprint
        }
        return (lhs.schemaHash ?? "") < (rhs.schemaHash ?? "")
    }

    private static func validateRawRecords(
        kind: MCPPublishedCatalogItemKind,
        items: [MCPPublishedCatalogItem],
        records: [(String, String)]
    ) throws {
        guard !records.isEmpty else { return }
        let indexed = Dictionary(
            uniqueKeysWithValues: items
                .filter { $0.kind == kind }
                .map { ($0.remoteName, $0.identityFingerprint) })
        guard indexed.count == records.count else {
            throw MCPResourceCatalogError.completeSnapshotMismatch(
                "\(kind.rawValue) identity and raw-record counts differ")
        }
        for (name, fingerprint) in records {
            guard indexed[name] == fingerprint else {
                throw MCPResourceCatalogError.completeSnapshotMismatch(
                    "\(kind.rawValue) '\(name)' identity does not match its raw record")
            }
        }
    }
}

/// An execution route that points to one concrete client generation.
///
/// The route retains the old connection object deliberately. Revalidation can
/// reject it after refresh/revocation/close, but it can never look up and use a
/// newer connection or catalog on behalf of an old provider response.
public struct MCPPreparedConnectionRoute: Sendable {
    public let bindingIdentity: MCPBindingIdentity
    public let authorityFingerprint: String
    public let catalogFingerprint: String

    fileprivate let connection: MCPManagedConnection

    init(
        bindingIdentity: MCPBindingIdentity,
        authorityFingerprint: String,
        catalogFingerprint: String,
        connection: MCPManagedConnection
    ) {
        self.bindingIdentity = bindingIdentity
        self.authorityFingerprint = authorityFingerprint
        self.catalogFingerprint = catalogFingerprint
        self.connection = connection
    }

    /// Revalidates all mutable fences immediately before a later layer sends
    /// an operation to the client. It never resolves a replacement route.
    public func revalidate(
        catalogKind: MCPCatalogChangeKind? = .tools
    ) async throws {
        try await connection.revalidate(
            route: self,
            requiredCatalogKind: catalogKind)
    }

    public func listToolsPage(
        cursor: String?
    ) async throws -> MCPToolListPage {
        try await connection.listToolsPage(
            route: self,
            cursor: cursor)
    }

    /// Performs complete refresh discovery against this retained route.
    /// Publication remains owned by `MCPRuntime.refreshExisting`, which
    /// re-checks the current generation and revocation fence after discovery.
    public func discoverCompleteCatalogForRefresh(
        limits: MCPFullCatalogDiscoveryLimits = .init()
    ) async throws -> MCPCompleteCatalogSnapshot {
        try await connection
            .discoverCompleteCatalogForRefresh(
                route: self,
                limits: limits)
    }

    public func listResourcesPage(
        cursor: String?,
        fence: MCPExternalOperationFence
    ) async throws -> MCPResourceListPage {
        try await connection.listResourcesPage(
            route: self,
            cursor: cursor,
            fence: fence)
    }

    public func listResourceTemplatesPage(
        cursor: String?,
        fence: MCPExternalOperationFence
    ) async throws -> MCPResourceTemplateListPage {
        try await connection.listResourceTemplatesPage(
            route: self,
            cursor: cursor,
            fence: fence)
    }

    public func readResource(
        uri: String,
        fence: MCPExternalOperationFence
    ) async throws -> MCPRawResourceReadResult {
        try await connection.readResource(
            route: self,
            uri: uri,
            fence: fence)
    }

    public func subscribeResource(
        uri: String,
        fence: MCPExternalOperationFence
    ) async throws {
        try await connection.subscribeResource(
            route: self,
            uri: uri,
            fence: fence)
    }

    public func unsubscribeResource(
        uri: String,
        fence: MCPExternalOperationFence
    ) async throws {
        try await connection.unsubscribeResource(
            route: self,
            uri: uri,
            fence: fence)
    }

    public func listPromptsPage(
        cursor: String?
    ) async throws -> MCPPromptListPage {
        try await connection.listPromptsPage(
            route: self,
            cursor: cursor)
    }

    public func getPrompt(
        name: String,
        arguments: [String: String],
        fence: MCPExternalOperationFence
    ) async throws -> MCPRawPromptGetResult {
        try await connection.getPrompt(
            route: self,
            name: name,
            arguments: arguments,
            fence: fence)
    }

    public func complete(
        reference: MCPCompletionReference,
        argumentName: String,
        argumentValue: String,
        context: [String: String],
        fence: MCPExternalOperationFence
    ) async throws -> MCPCompletionResult {
        try await connection.complete(
            route: self,
            reference: reference,
            argumentName: argumentName,
            argumentValue: argumentValue,
            context: context,
            fence: fence)
    }

    public func listRemoteTasks(
        fence: MCPExternalOperationFence
    ) async throws
        -> [MCPRemoteTaskSnapshot]
    {
        try await connection.listRemoteTasks(
            route: self,
            fence: fence)
    }

    public func refreshRemoteTask(
        _ taskID: MCPRemoteServerTaskID,
        timeoutMilliseconds: Int? = nil,
        fence: MCPExternalOperationFence
    ) async throws -> MCPRemoteTaskSnapshot {
        try await connection.refreshRemoteTask(
            route: self,
            taskID: taskID,
            timeoutMilliseconds: timeoutMilliseconds,
            fence: fence)
    }

    public func cancelRemoteTask(
        _ taskID: MCPRemoteServerTaskID,
        timeoutMilliseconds: Int? = nil,
        fence: MCPExternalOperationFence
    ) async throws -> MCPRemoteTaskSnapshot {
        try await connection.cancelRemoteTask(
            route: self,
            taskID: taskID,
            timeoutMilliseconds: timeoutMilliseconds,
            fence: fence)
    }

    public func remoteTaskResult(
        _ taskID: MCPRemoteServerTaskID,
        timeoutMilliseconds: Int? = nil,
        fence: MCPExternalOperationFence
    ) async throws -> JSONValue {
        try await connection.remoteTaskResult(
            route: self,
            taskID: taskID,
            timeoutMilliseconds: timeoutMilliseconds,
            fence: fence)
    }

    public func notifyRootsChanged() async throws {
        try await connection.notifyRootsChanged(route: self)
    }

    /// Executes against the retained client generation only. This method
    /// never consults a current connection pool or resolves by alias/name.
    public func callTool(
        remoteName: String,
        arguments: [String: JSONValue]
    ) async throws -> MCPRawToolCallResult {
        try await connection.callTool(
            route: self,
            remoteName: remoteName,
            arguments: arguments)
    }

    public func callToolResolved(
        remoteName: String,
        arguments: [String: JSONValue],
        toolTaskSupport: MCPToolTaskSupport?,
        preference: MCPTaskInvocationPreference,
        ttlMilliseconds: Int?,
        originatingToolCallID: String?,
        timeoutMilliseconds: Int = 10 * 60 * 1_000
    ) async throws -> MCPRawToolCallResult {
        try await connection.callToolResolved(
            route: self,
            remoteName: remoteName,
            arguments: arguments,
            toolTaskSupport: toolTaskSupport,
            preference: preference,
            ttlMilliseconds: ttlMilliseconds,
            originatingToolCallID: originatingToolCallID,
            timeoutMilliseconds: timeoutMilliseconds)
    }
}

extension MCPPreparedConnectionRoute: Equatable {
    public static func == (
        lhs: MCPPreparedConnectionRoute,
        rhs: MCPPreparedConnectionRoute
    ) -> Bool {
        lhs.bindingIdentity == rhs.bindingIdentity
            && lhs.authorityFingerprint == rhs.authorityFingerprint
            && lhs.catalogFingerprint == rhs.catalogFingerprint
    }
}

/// Bounded, secret-scrubbed initialize instructions frozen to one exact
/// connection and Agent catalog view. This value is display-only by default;
/// model materialization requires an explicit user selection.
public struct MCPServerInstructionsSnapshot:
    Equatable, Sendable
{
    public let text: String
    public let provenance: MCPContentProvenance

    public init(
        text: String,
        provenance: MCPContentProvenance
    ) {
        self.text = text
        self.provenance = provenance
    }

    fileprivate func rebinding(
        _ binding: MCPBindingIdentity
    ) -> MCPServerInstructionsSnapshot {
        MCPServerInstructionsSnapshot(
            text: text,
            provenance: MCPContentProvenance(
                sourceKind:
                    provenance.sourceKind,
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
                    provenance.remoteName,
                resourceURI:
                    provenance.resourceURI,
                schemaHash:
                    provenance.schemaHash,
                accountReference:
                    provenance.accountReference,
                environmentReference:
                    provenance
                        .environmentReference))
    }
}

/// One exact server connection and raw catalog frozen into a provider request.
public struct MCPConnectionSnapshot: Equatable, Sendable {
    public let reuseIdentity: MCPConnectionReuseIdentity
    public let bindingIdentity: MCPBindingIdentity
    public let negotiatedCapabilities: MCPNegotiatedCapabilitySet
    public let catalog: MCPCompleteCatalogSnapshot
    public let route: MCPPreparedConnectionRoute
    public let serverInstructions:
        MCPServerInstructionsSnapshot?
    /// Categories invalidated by listChanged before a complete replacement
    /// revision is available. Builders must omit these categories from every
    /// newly-created provider request.
    public let unavailableCatalogKinds: Set<MCPCatalogChangeKind>

    public init(
        reuseIdentity: MCPConnectionReuseIdentity,
        bindingIdentity: MCPBindingIdentity,
        negotiatedCapabilities: MCPNegotiatedCapabilitySet = .none,
        catalog: MCPCompleteCatalogSnapshot,
        route: MCPPreparedConnectionRoute,
        serverInstructions:
            MCPServerInstructionsSnapshot? = nil,
        unavailableCatalogKinds: Set<MCPCatalogChangeKind> = []
    ) {
        self.reuseIdentity = reuseIdentity
        self.bindingIdentity = bindingIdentity
        self.negotiatedCapabilities = negotiatedCapabilities
        self.catalog = catalog
        self.route = route
        self.serverInstructions =
            serverInstructions
        self.unavailableCatalogKinds = unavailableCatalogKinds
    }

    /// Freezes the Agent-specific catalog view after the raw catalog has been
    /// discovered, while retaining this exact connection generation and raw
    /// catalog route.
    ///
    /// A first connection cannot know its Agent view revision before
    /// `initialize` + discovery because that revision includes the immutable
    /// raw catalog together with the exact grant and attachment policy. The
    /// runtime therefore starts with a non-authorizing provisional revision
    /// and calls this method immediately before publishing tools to a model.
    /// No current/global lookup occurs here: the retained managed connection,
    /// generation, raw catalog, binding, authority, and revocation fences all
    /// come from this snapshot.
    public func rebindingAgentCatalogViewRevision(
        _ revision: MCPAgentCatalogViewRevision
    ) -> MCPConnectionSnapshot {
        guard bindingIdentity.agentCatalogViewRevision != revision else {
            return self
        }
        let reboundBinding = MCPBindingIdentity(
            protocolProfile: bindingIdentity.protocolProfile,
            maximumProtocolVersion:
                bindingIdentity.maximumProtocolVersion,
            negotiatedProtocolVersion:
                bindingIdentity.negotiatedProtocolVersion,
            server: bindingIdentity.server,
            connectionGeneration:
                bindingIdentity.connectionGeneration,
            rawCatalogRevision:
                bindingIdentity.rawCatalogRevision,
            agentCatalogViewRevision: revision,
            bindingID: bindingIdentity.bindingID,
            revocationGeneration:
                bindingIdentity.revocationGeneration)
        let reboundRoute = MCPPreparedConnectionRoute(
            bindingIdentity: reboundBinding,
            authorityFingerprint:
                route.authorityFingerprint,
            catalogFingerprint:
                route.catalogFingerprint,
            connection: route.connection)
        return MCPConnectionSnapshot(
            reuseIdentity: reuseIdentity,
            bindingIdentity: reboundBinding,
            negotiatedCapabilities:
                negotiatedCapabilities,
            catalog: catalog,
            route: reboundRoute,
            serverInstructions:
                serverInstructions?
                    .rebinding(reboundBinding),
            unavailableCatalogKinds:
                unavailableCatalogKinds)
    }
}

/// Typed, bounded failure retained for an optional server or returned as part
/// of an aggregate required-startup failure.
public struct MCPServerStartupFailure: Equatable, Sendable {
    public let server: MCPServerReference
    public let attachmentID: MCPAttachmentID
    public let required: Bool
    public let code: String
    public let diagnostic: MCPDiagnosticSummary

    public init(
        server: MCPServerReference,
        attachmentID: MCPAttachmentID,
        required: Bool,
        code: String,
        diagnostic: MCPDiagnosticSummary
    ) {
        self.server = server
        self.attachmentID = attachmentID
        self.required = required
        self.code = code
        self.diagnostic = diagnostic
    }
}

/// Atomic provider-dispatch publication.
///
/// `connections` contains only ready servers from the frozen invocation view.
/// Optional failures remain visible as diagnostics but contribute no tools.
public struct MCPConnectionSetSnapshot: Equatable, Sendable {
    public let snapshotID: MCPConnectionSetSnapshotID
    public let sessionID: SessionID
    public let agentID: AgentID
    public let bindingID: MCPBindingID
    public let publicationOrdinal: UInt64
    public let connections: [MCPConnectionSnapshot]
    public let optionalFailures: [MCPServerStartupFailure]

    public init(
        snapshotID: MCPConnectionSetSnapshotID = .new(),
        sessionID: SessionID,
        agentID: AgentID,
        bindingID: MCPBindingID,
        publicationOrdinal: UInt64,
        connections: [MCPConnectionSnapshot],
        optionalFailures: [MCPServerStartupFailure] = []
    ) {
        self.snapshotID = snapshotID
        self.sessionID = sessionID
        self.agentID = agentID
        self.bindingID = bindingID
        self.publicationOrdinal = publicationOrdinal
        self.connections = connections.sorted(by: Self.connectionPrecedes)
        self.optionalFailures = optionalFailures.sorted(
            by: Self.failurePrecedes)
    }

    private static func connectionPrecedes(
        _ lhs: MCPConnectionSnapshot,
        _ rhs: MCPConnectionSnapshot
    ) -> Bool {
        let left = lhs.reuseIdentity
        let right = rhs.reuseIdentity
        if left.server.serverID.rawValue != right.server.serverID.rawValue {
            return left.server.serverID.rawValue
                < right.server.serverID.rawValue
        }
        if left.server.serverRevision.rawValue
            != right.server.serverRevision.rawValue {
            return left.server.serverRevision.rawValue
                < right.server.serverRevision.rawValue
        }
        return left.authority.attachmentID.rawValue
            < right.authority.attachmentID.rawValue
    }

    private static func failurePrecedes(
        _ lhs: MCPServerStartupFailure,
        _ rhs: MCPServerStartupFailure
    ) -> Bool {
        if lhs.server.serverID.rawValue != rhs.server.serverID.rawValue {
            return lhs.server.serverID.rawValue
                < rhs.server.serverID.rawValue
        }
        return lhs.attachmentID.rawValue < rhs.attachmentID.rawValue
    }
}
