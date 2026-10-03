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

public struct MCPResourceAccessPolicy: Sendable {
    public let server: MCPServerReference
    public let attachmentID: MCPAttachmentID
    public let serverAlias: String
    public let serverFilter: MCPNameFilter
    public let attachmentFilter: MCPNameFilter
    public let allowedURISchemes: Set<String>
    public let workspaceLease: WorkspaceLease?
    public let risksNetwork: Bool
    public let networkOrigin: String?
    public let policyFingerprint: String

    public init(
        server: MCPServerReference,
        attachmentID: MCPAttachmentID,
        serverAlias: String,
        serverFilter: MCPNameFilter = .init(),
        attachmentFilter: MCPNameFilter = .init(),
        allowedURISchemes: Set<String> = ["file", "https"],
        workspaceLease: WorkspaceLease? = nil,
        risksNetwork: Bool,
        networkOrigin: String? = nil,
        policyFingerprint: String
    ) throws {
        guard !serverAlias.isEmpty,
              !serverAlias.contains("\0"),
              !allowedURISchemes.isEmpty,
              allowedURISchemes.allSatisfy({
                  $0 == $0.lowercased()
                      && $0.first?.isLetter == true
                      && $0.allSatisfy {
                          $0.isLetter || $0.isNumber
                              || $0 == "+" || $0 == "-" || $0 == "."
                      }
              }),
              !policyFingerprint.isEmpty else {
            throw MCPContentOperationError.invalidArguments(
                "invalid resource access policy")
        }
        self.server = server
        self.attachmentID = attachmentID
        self.serverAlias = serverAlias
        self.serverFilter = serverFilter
        self.attachmentFilter = attachmentFilter
        self.allowedURISchemes = allowedURISchemes
        self.workspaceLease = workspaceLease
        self.risksNetwork = risksNetwork
        self.networkOrigin = networkOrigin
        self.policyFingerprint = policyFingerprint
    }

    public func validateReadURI(
        _ uri: String,
        authority: MCPConnectionAuthority
    ) throws {
        try MCPRawCatalogValidation.validateURI(uri)
        guard let components = URLComponents(string: uri),
              let scheme = components.scheme?.lowercased(),
              allowedURISchemes.contains(scheme) else {
            throw MCPContentOperationError.unsafeURI(uri)
        }
        guard scheme == "file" else { return }
        guard let lease = workspaceLease,
              authority.workspaceLeaseID == lease.id,
              let identity = lease.rootIdentity,
              identity.matchesCurrentDirectory(rootPath: lease.rootPath),
              let url = URL(string: uri),
              url.isFileURL else {
            throw MCPContentOperationError.unsafeURI(uri)
        }
        let root = URL(fileURLWithPath: identity.canonicalPath)
            .standardizedFileURL
        let candidate = url.standardizedFileURL
        let rootPath = root.path.hasSuffix("/")
            ? root.path
            : root.path + "/"
        guard candidate.path == root.path
                || candidate.path.hasPrefix(rootPath) else {
            throw MCPContentOperationError.unsafeURI(uri)
        }
        let relative = String(candidate.path.dropFirst(rootPath.count))
        guard !PathConfinement.isSensitivePath(relative) else {
            throw MCPContentOperationError.unsafeURI(uri)
        }
    }
}

public struct MCPAgentResourceServerView: Sendable {
    public let connection: MCPConnectionSnapshot
    public let grant: MCPGrant
    public let policy: MCPResourceAccessPolicy
    public let resources: [MCPRawResourceRecord]
    public let resourceTemplates: [MCPRawResourceTemplateRecord]
}

public struct MCPAgentResourceCatalogView: Sendable {
    public let connectionSetSnapshotID: MCPConnectionSetSnapshotID
    public let bindingID: MCPBindingID
    public let agentID: AgentID
    public let servers: [MCPAgentResourceServerView]
    public let stableFingerprint: String

    public static func build(
        connectionSet: MCPConnectionSetSnapshot,
        capabilityLease: CapabilityLease,
        policies: [MCPResourceAccessPolicy]
    ) throws -> MCPAgentResourceCatalogView {
        let policiesByAttachment = Dictionary(
            uniqueKeysWithValues: policies.map {
                ($0.attachmentID, $0)
            })
        var result: [MCPAgentResourceServerView] = []
        var aliases: Set<String> = []

        for connection in connectionSet.connections {
            if connection.unavailableCatalogKinds.contains(.resources) {
                continue
            }
            let authority = connection.reuseIdentity.authority
            guard authority.hasCurrentExecutionAuthority,
                  authority.agentID == connectionSet.agentID,
                  authority.capabilityLeaseID == capabilityLease.id,
                  authority.capabilityTaskID
                    == capabilityLease.taskID else {
                throw MCPContentOperationError.missingGrant(.resources)
            }
            let grants = capabilityLease.mcpGrants.filter {
                $0.attachmentID == authority.attachmentID
                    && $0.server == connection.reuseIdentity.server
                    && $0.agentID == connectionSet.agentID
                    && $0.capabilityLeaseID == capabilityLease.id
                    && $0.taskID == capabilityLease.taskID
                    && $0.grants(.resources)
                    && $0.isActive()
            }
            // A tools-only connection is not a malformed resource view; it
            // simply contributes no model-visible resource server.
            guard !grants.isEmpty else { continue }
            guard grants.count == 1,
                  let grant = grants.first else {
                throw MCPContentOperationError.missingGrant(.resources)
            }
            guard let policy = policiesByAttachment[
                authority.attachmentID
            ], policy.server == connection.reuseIdentity.server else {
                throw MCPContentOperationError.missingGrant(.resources)
            }
            guard aliases.insert(policy.serverAlias).inserted else {
                throw MCPContentOperationError.ambiguousServer(
                    policy.serverAlias)
            }
            guard grant.authorityFingerprint == authority.fingerprint,
                  grant.revocationGeneration
                    == connection.bindingIdentity.revocationGeneration else {
                throw MCPContentOperationError.missingGrant(.resources)
            }
            if let workspaceLease = policy.workspaceLease {
                guard authority.workspaceLeaseID == workspaceLease.id else {
                    throw MCPContentOperationError.missingGrant(.resources)
                }
            }
            let resources = connection.catalog.resources.filter {
                Self.allows(
                    name: $0.name,
                    identity: $0.uri,
                    filters: [
                        policy.serverFilter,
                        policy.attachmentFilter,
                        grant.filter.resources,
                    ])
            }
            let templates = connection.catalog.resourceTemplates.filter {
                Self.allows(
                    name: $0.name,
                    identity: $0.uriTemplate,
                    filters: [
                        policy.serverFilter,
                        policy.attachmentFilter,
                        grant.filter.resources,
                    ])
            }
            result.append(MCPAgentResourceServerView(
                connection: connection,
                grant: grant,
                policy: policy,
                resources: resources,
                resourceTemplates: templates))
        }
        result.sort { $0.policy.serverAlias < $1.policy.serverAlias }
        let fingerprint = MCPResourceToolHash.hash(
            ["mcp-resource-view-v1",
             connectionSet.snapshotID.rawValue,
             connectionSet.bindingID.rawValue,
             capabilityLease.id.rawValue]
                + result.flatMap {
                    [
                        $0.policy.serverAlias,
                        $0.connection.catalog.catalogFingerprint,
                        $0.grant.grantFingerprint,
                        $0.policy.policyFingerprint,
                    ]
                    + $0.resources.map(\.identityFingerprint)
                    + $0.resourceTemplates.map(\.identityFingerprint)
                })
        return MCPAgentResourceCatalogView(
            connectionSetSnapshotID: connectionSet.snapshotID,
            bindingID: connectionSet.bindingID,
            agentID: connectionSet.agentID,
            servers: result,
            stableFingerprint: fingerprint)
    }

    private init(
        connectionSetSnapshotID: MCPConnectionSetSnapshotID,
        bindingID: MCPBindingID,
        agentID: AgentID,
        servers: [MCPAgentResourceServerView],
        stableFingerprint: String
    ) {
        self.connectionSetSnapshotID = connectionSetSnapshotID
        self.bindingID = bindingID
        self.agentID = agentID
        self.servers = servers
        self.stableFingerprint = stableFingerprint
    }

    private static func allows(
        name: String,
        identity: String,
        filters: [MCPNameFilter]
    ) -> Bool {
        filters.allSatisfy { filter in
            guard !filter.denyList.contains(name),
                  !filter.denyList.contains(identity) else {
                return false
            }
            guard let allowed = filter.allowList else { return true }
            return allowed.contains(name) || allowed.contains(identity)
        }
    }
}

public struct MCPResourceResultLimits: Equatable, Sendable {
    public let maximumPages: Int
    public let maximumItems: Int
    public let maximumContents: Int
    public let maximumTextBytesPerContent: Int
    public let maximumBinaryBytesPerContent: Int
    public let maximumTotalBytes: Int
    public let maximumCursorBytes: Int

    public init(
        maximumPages: Int = 1_024,
        maximumItems: Int = 10_000,
        maximumContents: Int = 256,
        maximumTextBytesPerContent: Int = 256 * 1_024,
        maximumBinaryBytesPerContent: Int = 16 * 1_024 * 1_024,
        maximumTotalBytes: Int = 32 * 1_024 * 1_024,
        maximumCursorBytes: Int = 4_096
    ) {
        self.maximumPages = maximumPages
        self.maximumItems = maximumItems
        self.maximumContents = maximumContents
        self.maximumTextBytesPerContent = maximumTextBytesPerContent
        self.maximumBinaryBytesPerContent = maximumBinaryBytesPerContent
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumCursorBytes = maximumCursorBytes
    }
}

public struct MCPResourceContentConverter: Sendable {
    public let limits: MCPResourceResultLimits
    private let sanitizer: any MCPToolResultSanitizer
    private let artifactSink: (any MCPToolArtifactSink)?
    private let providerRequestBudget:
        MCPToolResultAggregateBudget?
    private let turnBudget:
        MCPToolResultAggregateBudget?

    public init(
        limits: MCPResourceResultLimits = .init(),
        sanitizer: any MCPToolResultSanitizer =
            MCPConservativeToolResultSanitizer(),
        artifactSink: (any MCPToolArtifactSink)? = nil,
        providerRequestBudget:
            MCPToolResultAggregateBudget? = nil,
        turnBudget:
            MCPToolResultAggregateBudget? = nil
    ) {
        self.limits = limits
        self.sanitizer = sanitizer
        self.artifactSink = artifactSink
        self.providerRequestBudget =
            providerRequestBudget
        self.turnBudget = turnBudget
    }

    public func scoped(
        providerRequestBudget:
            MCPToolResultAggregateBudget,
        turnBudget:
            MCPToolResultAggregateBudget
    ) -> MCPResourceContentConverter {
        MCPResourceContentConverter(
            limits: limits,
            sanitizer: sanitizer,
            artifactSink: artifactSink,
            providerRequestBudget:
                providerRequestBudget,
            turnBudget: turnBudget)
    }

    /// Sanitizes and accounts a model-facing resource catalog page that does
    /// not contain artifact-backed bodies. Cursors and every other string leaf
    /// cross the same exact-secret boundary as resource contents.
    public func convertInlineJSON(
        _ value: JSONValue
    ) throws -> ToolObservation {
        let sanitized =
            try MCPOutputSanitization
                .sanitizeJSON(
                    value,
                    using: sanitizer)
        let text = try Self.textJSON(
            sanitized)
        let byteCount = text.utf8.count
        try enforceTotal(byteCount)
        try MCPToolResultAggregateBudget
            .reserveAtomically(
                byteCount,
                providerRequest:
                    providerRequestBudget,
                turn: turnBudget)
        return ToolObservation(text: text)
    }

    public func convert(
        _ result: MCPRawResourceReadResult,
        serverAlias: String,
        requestedURI: String,
        provenance: MCPContentProvenance
    ) async throws -> ToolObservation {
        guard result.contents.count <= limits.maximumContents else {
            throw MCPContentOperationError.tooManyContents(
                maximum: limits.maximumContents)
        }
        let safeServerAlias =
            try sanitizer
                .sanitizeMCPText(serverAlias)
        let safeRequestedURI =
            try sanitizer
                .sanitizeMCPText(requestedURI)
        let rawBytes =
            try preflightTotalBytes(result)
        let sanitizedBytes =
            try preflightSanitizedTotalBytes(result)
        let reservedBytes =
            max(rawBytes, sanitizedBytes)
        try MCPToolResultAggregateBudget
            .reserveAtomically(
                reservedBytes,
                providerRequest:
                    providerRequestBudget,
                turn: turnBudget)
        var normal: [JSONValue] = []
        var hardened: [JSONValue] = []
        var total = 0

        for content in result.contents {
            try MCPRawCatalogValidation.validateURI(content.uri)
            let safeURI =
                try sanitizer
                    .sanitizeMCPText(
                        content.uri)
            let safeMIMEType =
                try validatedMimeType(
                    content.mimeType)
            if let text = content.text {
                let data = Data(text.utf8)
                let sanitized = try sanitizer.sanitizeMCPText(text)
                let safeData = Data(sanitized.utf8)
                total += safeURI.utf8.count
                    + (safeMIMEType?.utf8.count ?? 0)
                    + safeData.count
                try enforceTotal(total)
                if sanitized != text {
                    hardened.append(.object([
                        "uri": .string(safeURI),
                        "reason": .string("secret_redacted"),
                        "byteCount": .number(Double(data.count)),
                        "sha256": .string(
                            MCPRawCatalogHash.sha256(data)),
                    ]))
                } else if safeData.count
                            > limits.maximumTextBytesPerContent {
                    let artifact = try await store(
                        safeData,
                        mimeType: safeMIMEType ?? "text/plain",
                        provenance: provenance)
                    hardened.append(Self.artifactJSON(
                        artifact,
                        uri: safeURI,
                        mimeType: safeMIMEType,
                        reason: "oversized_text"))
                } else {
                    var fields: [String: JSONValue] = [
                        "uri": .string(safeURI),
                        "text": .string(sanitized),
                    ]
                    if let mimeType = safeMIMEType {
                        fields["mimeType"] = .string(mimeType)
                    }
                    normal.append(.object(fields))
                }
            } else if let encoded = content.base64 {
                guard let data = Data(base64Encoded: encoded) else {
                    throw MCPContentOperationError.malformedBinary
                }
                guard data.count <= limits.maximumBinaryBytesPerContent else {
                    throw MCPContentOperationError.contentTooLarge(
                        maximum: limits.maximumBinaryBytesPerContent)
                }
                total += safeURI.utf8.count
                    + (safeMIMEType?.utf8.count ?? 0)
                    + data.count
                try enforceTotal(total)
                let artifact = try await store(
                    data,
                    mimeType: safeMIMEType,
                    provenance: provenance)
                hardened.append(Self.artifactJSON(
                    artifact,
                    uri: safeURI,
                    mimeType: safeMIMEType,
                    reason: "binary_content"))
            }
        }

        if hardened.isEmpty {
            return ToolObservation(
                text: try Self.textJSON(.object([
                    "server": .string(safeServerAlias),
                    "uri": .string(safeRequestedURI),
                    "contents": .array(normal),
                ])))
        }
        return ToolObservation(
            text: try Self.textJSON(.object([
                "type": .string(IntatisHostApplication.identity
                    .fieldNameStem + "_mcp_resource_hardening"),
                "server": .string(safeServerAlias),
                "uri": .string(safeRequestedURI),
                "reason": .string("content_not_safe_for_inline_model_context"),
                "inlineContents": .array(normal),
                "hardenedContents": .array(hardened),
            ])),
            truncated: true)
    }

    private func enforceTotal(_ total: Int) throws {
        guard total <= limits.maximumTotalBytes else {
            throw MCPContentOperationError.contentTooLarge(
                maximum: limits.maximumTotalBytes)
        }
    }

    private func preflightTotalBytes(
        _ result: MCPRawResourceReadResult
    ) throws -> Int {
        var total = 0
        for content in result.contents {
            try MCPRawCatalogValidation
                .validateURI(content.uri)
            let metadataBytes =
                content.uri.utf8.count
                + (content.mimeType?.utf8.count ?? 0)
            let contentBytes: Int
            if let text = content.text {
                contentBytes = text.utf8.count
            } else if let encoded = content.base64,
                      let data = Data(
                        base64Encoded: encoded) {
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
                contentBytes = data.count
            } else {
                throw MCPContentOperationError
                    .malformedBinary
            }
            let (bytes, metadataOverflow) =
                metadataBytes.addingReportingOverflow(
                    contentBytes)
            guard !metadataOverflow else {
                throw MCPContentOperationError
                    .contentTooLarge(
                        maximum:
                            limits.maximumTotalBytes)
            }
            let (next, overflow) =
                total.addingReportingOverflow(bytes)
            guard !overflow else {
                throw MCPContentOperationError
                    .contentTooLarge(
                        maximum:
                            limits.maximumTotalBytes)
            }
            total = next
            try enforceTotal(total)
        }
        return total
    }

    private func preflightSanitizedTotalBytes(
        _ result: MCPRawResourceReadResult
    ) throws -> Int {
        var total = 0
        for content in result.contents {
            try MCPRawCatalogValidation
                .validateURI(content.uri)
            let safeURI =
                try sanitizer
                    .sanitizeMCPText(
                        content.uri)
            let safeMIMEType =
                try validatedMimeType(
                    content.mimeType)
            let contentBytes: Int
            if let text = content.text {
                contentBytes =
                    try sanitizer
                        .sanitizeMCPText(text)
                        .utf8.count
            } else if let encoded = content.base64,
                      let data = Data(
                        base64Encoded: encoded) {
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
                try sanitizer.validateMCPBinary(data)
                contentBytes = data.count
            } else {
                throw MCPContentOperationError
                    .malformedBinary
            }
            let metadataBytes =
                safeURI.utf8.count
                + (safeMIMEType?.utf8.count ?? 0)
            let (bytes, metadataOverflow) =
                metadataBytes.addingReportingOverflow(
                    contentBytes)
            guard !metadataOverflow else {
                throw MCPContentOperationError
                    .contentTooLarge(
                        maximum:
                            limits.maximumTotalBytes)
            }
            let (next, overflow) =
                total.addingReportingOverflow(bytes)
            guard !overflow else {
                throw MCPContentOperationError
                    .contentTooLarge(
                        maximum:
                            limits.maximumTotalBytes)
            }
            total = next
            try enforceTotal(total)
        }
        return total
    }

    private func validatedMimeType(
        _ value: String?
    ) throws -> String? {
        guard let value else { return nil }
        guard value.utf8.count <= 256,
              !value.contains("\0"),
              !value.contains(where: \.isNewline) else {
            throw MCPContentOperationError
                .contentTooLarge(maximum: 256)
        }
        return try MCPOutputSanitization
            .requireUnchangedIdentifier(
                value,
                using: sanitizer)
    }

    private func store(
        _ data: Data,
        mimeType: String?,
        provenance: MCPContentProvenance
    ) async throws -> MCPStoredToolArtifact {
        guard let artifactSink else {
            throw MCPContentOperationError.artifactSinkRequired
        }
        try sanitizer.validateMCPBinary(data)
        let stored = try await artifactSink.storeMCPToolArtifact(
            data,
            mimeType: mimeType,
            provenance: provenance)
        guard stored.byteCount == data.count,
              stored.sha256 == MCPRawCatalogHash.sha256(data) else {
            throw MCPToolExecutionError.artifactWriteFailed
        }
        return stored
    }

    private static func artifactJSON(
        _ artifact: MCPStoredToolArtifact,
        uri: String,
        mimeType: String?,
        reason: String
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "uri": .string(uri),
            "reason": .string(reason),
            "artifactID": .string(artifact.artifactID.rawValue),
            "byteCount": .number(Double(artifact.byteCount)),
            "sha256": .string(artifact.sha256),
        ]
        if let mimeType { fields["mimeType"] = .string(mimeType) }
        return .object(fields)
    }

    static func textJSON(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPContentOperationError.invalidArguments(
                "JSON output is not UTF-8")
        }
        return text
    }
}

private enum MCPResourceToolOperation: Sendable {
    case listResources
    case listTemplates
    case readResource
}

private struct MCPResourceListArguments: Decodable {
    let server: String?
    let cursor: String?
}

private struct MCPResourceReadArguments: Decodable {
    let server: String
    let uri: String
}

public struct MCPModelResourceTool: Tool, Sendable {
    public static let descriptor = ToolDescriptor(
        name: "_mcp_resource_tool_requires_instance_registration",
        description: "MCP resource tools require an instance descriptor.",
        sideEffect: .network,
        parameters: .object([:]))

    private let operation: MCPResourceToolOperation
    private let view: MCPAgentResourceCatalogView
    private let limits: MCPResourceResultLimits
    private let converter: MCPResourceContentConverter
    private let authorityVerifier:
        any MCPExternalOperationAuthorityVerifier
    private let workspaceLease: WorkspaceLease?
    private let executionPreflight:
        @Sendable (
            MCPAgentResourceServerView
        ) async throws -> Void

    fileprivate init(
        operation: MCPResourceToolOperation,
        view: MCPAgentResourceCatalogView,
        limits: MCPResourceResultLimits,
        converter: MCPResourceContentConverter,
        authorityVerifier:
            any MCPExternalOperationAuthorityVerifier,
        workspaceLease: WorkspaceLease?,
        executionPreflight:
            @escaping @Sendable (
                MCPAgentResourceServerView
            ) async throws -> Void
    ) {
        self.operation = operation
        self.view = view
        self.limits = limits
        self.converter = converter
        self.authorityVerifier = authorityVerifier
        self.workspaceLease = workspaceLease
        self.executionPreflight = executionPreflight
    }

    public func risksNetwork(_ args: ToolArgs) -> Bool {
        guard let requested = try? args.decode(
            MCPResourceListArguments.self),
              let alias = requested.server else {
            return view.servers.contains { $0.policy.risksNetwork }
        }
        return view.servers.first {
            $0.policy.serverAlias == alias
        }?.policy.risksNetwork ?? true
    }

    public func permissionIntent(
        _ args: ToolArgs,
        descriptor: ToolDescriptor,
        workspaceRoot _: URL
    ) -> PermissionIntent {
        var metadata: [String: JSONValue] = [
            "mcp_resource_operation": .string(descriptor.name),
            "mcp_binding_id": .string(view.bindingID.rawValue),
            "mcp_resource_view_fingerprint":
                .string(view.stableFingerprint),
        ]
        if let decoded = try? args.decode(MCPResourceReadArguments.self) {
            metadata["mcp_server"] = .string(decoded.server)
            metadata["mcp_resource_uri_digest"] =
                .string(MCPResourceToolHash.hash([decoded.uri]))
            metadata["mcp_resource_uri_characters"] =
                .number(Double(decoded.uri.count))
            if let scheme = URLComponents(string: decoded.uri)?
                    .scheme?.lowercased() {
                metadata["mcp_resource_uri_scheme"] =
                    .string(scheme)
            }
        } else if let decoded = try? args.decode(
            MCPResourceListArguments.self),
                  let server = decoded.server {
            metadata["mcp_server"] = .string(server)
        }
        return PermissionIntent(
            action: operation == .readResource
                ? "mcp.resource.read"
                : "mcp.resource.list",
            resources: [
                PermissionResource(
                    kind: .tool,
                    value: descriptor.name),
            ],
            metadata: metadata,
            dataEffects: risksNetwork(args) ? [.network] : [.read],
            risks: risksNetwork(args) ? [.networkAccess] : [],
            replayPolicy: .safeToReplay)
    }

    public func permissionActionPreview(
        _ args: ToolArgs,
        descriptor: ToolDescriptor
    ) -> PermissionActionPreview? {
        if let decoded = try? args.decode(
            MCPResourceReadArguments.self) {
            var fields = [
                "server": decoded.server,
                "resource_uri_digest":
                    MCPResourceToolHash.hash([decoded.uri]),
                "resource_uri_characters":
                    String(decoded.uri.count),
            ]
            if let scheme = URLComponents(string: decoded.uri)?
                    .scheme?.lowercased() {
                fields["resource_uri_scheme"] = scheme
            }
            return PermissionActionPreview(
                kind: descriptor.name,
                fields: fields)
        }
        if let decoded = try? args.decode(
            MCPResourceListArguments.self) {
            return PermissionActionPreview(
                kind: descriptor.name,
                fields: [
                    "server": decoded.server ?? "all_visible_servers",
                ])
        }
        return nil
    }

    public func execute(
        _ args: ToolArgs,
        in _: ToolContext
    ) async throws -> ToolObservation {
        switch operation {
        case .listResources:
            return try await list(args, templates: false)
        case .listTemplates:
            return try await list(args, templates: true)
        case .readResource:
            return try await read(args)
        }
    }

    private func list(
        _ args: ToolArgs,
        templates: Bool
    ) async throws -> ToolObservation {
        let decoded = try args.decode(MCPResourceListArguments.self)
        if let cursor = decoded.cursor {
            guard decoded.server != nil else {
                throw MCPContentOperationError.cursorRequiresServer
            }
            try validateCursor(cursor)
        }
        if let alias = decoded.server {
            let server = try resolve(alias)
            try ensureGrantActive(server)
            try await executionPreflight(server)
            if templates {
                let fence = try operationFence(
                    server,
                    operation: .listResourceTemplates,
                    target: decoded.cursor ?? "")
                let page = try await server.connection.route
                    .listResourceTemplatesPage(
                        cursor: decoded.cursor,
                        fence: fence)
                let values = page.templates.filter {
                    isAllowed(
                        name: $0.name,
                        identity: $0.uriTemplate,
                        server: server)
                }.map { $0.modelJSON(serverAlias: alias) }
                var payload: [String: JSONValue] = [
                    "server": .string(alias),
                    "resourceTemplates": .array(values),
                ]
                if let nextCursor = page.nextCursor {
                    try validateCursor(nextCursor)
                    payload["nextCursor"] = .string(nextCursor)
                }
                return try converter
                    .convertInlineJSON(
                        .object(payload))
            }
            let fence = try operationFence(
                server,
                operation: .listResources,
                target: decoded.cursor ?? "")
            let page = try await server.connection.route
                .listResourcesPage(
                    cursor: decoded.cursor,
                    fence: fence)
            let values = page.resources.filter {
                isAllowed(
                    name: $0.name,
                    identity: $0.uri,
                    server: server)
            }.map { $0.modelJSON(serverAlias: alias) }
            var payload: [String: JSONValue] = [
                "server": .string(alias),
                "resources": .array(values),
            ]
            if let nextCursor = page.nextCursor {
                try validateCursor(nextCursor)
                payload["nextCursor"] = .string(nextCursor)
            }
            return try converter
                .convertInlineJSON(
                    .object(payload))
        }

        let aggregate = await aggregateAll(templates: templates)
        var payload: [String: JSONValue] = [
            templates ? "resourceTemplates" : "resources":
                .array(aggregate.values),
        ]
        if !aggregate.failures.isEmpty {
            payload["failures"] = .array(aggregate.failures)
        }
        return try converter
            .convertInlineJSON(
                .object(payload))
    }

    private func read(_ args: ToolArgs) async throws -> ToolObservation {
        let decoded = try args.decode(MCPResourceReadArguments.self)
        let server = try resolve(decoded.server)
        try ensureGrantActive(server)
        try await executionPreflight(server)
        guard server.resources.contains(where: {
            $0.uri == decoded.uri
        }) else {
            throw MCPContentOperationError.resourceNotGranted(decoded.uri)
        }
        try server.policy.validateReadURI(
            decoded.uri,
            authority: server.connection.reuseIdentity.authority)
        let fence = try operationFence(
            server,
            operation: .readResource,
            target: decoded.uri)
        let result = try await server.connection.route.readResource(
            uri: decoded.uri,
            fence: fence)
        let binding = server.connection.bindingIdentity
        let provenance = MCPContentProvenance(
            sourceKind: .resource,
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
            resourceURI: decoded.uri,
            accountReference:
                server.connection.reuseIdentity.oauthAccountReference,
            environmentReference:
                server.connection.reuseIdentity.environmentReference)
        let observation = try await converter.convert(
            result,
            serverAlias: decoded.server,
            requestedURI: decoded.uri,
            provenance: provenance)
        // Conversion can spill to the ArtifactStore after the transport
        // returns. Re-check the same immutable authority at the final
        // model-visible publication edge.
        try await fence.verifyBeforePublication()
        return observation
    }

    private func aggregateAll(
        templates: Bool
    ) async -> (values: [JSONValue], failures: [JSONValue]) {
        await withTaskGroup(
            of: (String, Result<[JSONValue], Error>).self
        ) { group in
            for server in view.servers {
                group.addTask {
                    do {
                        try ensureGrantActive(server)
                        try await executionPreflight(server)
                        if templates {
                            let values = try await allTemplates(server)
                                .map {
                                    $0.modelJSON(
                                        serverAlias:
                                            server.policy.serverAlias)
                                }
                            return (
                                server.policy.serverAlias,
                                .success(values))
                        }
                        let values = try await allResources(server)
                            .map {
                                $0.modelJSON(
                                    serverAlias:
                                        server.policy.serverAlias)
                            }
                        return (
                            server.policy.serverAlias,
                            .success(values))
                    } catch {
                        return (
                            server.policy.serverAlias,
                            .failure(error))
                    }
                }
            }
            var results: [
                (String, Result<[JSONValue], Error>)
            ] = []
            for await result in group { results.append(result) }
            results.sort { $0.0 < $1.0 }
            var values: [JSONValue] = []
            var failures: [JSONValue] = []
            for (alias, result) in results {
                switch result {
                case .success(let pageValues):
                    values.append(contentsOf: pageValues)
                case .failure(let error):
                    failures.append(.object([
                        "server": .string(alias),
                        "code": .string("server_list_failed"),
                        "message": .string(
                            String(Self.safeReason(error).prefix(512))),
                    ]))
                }
            }
            return (values, failures)
        }
    }

    private func allResources(
        _ server: MCPAgentResourceServerView
    ) async throws -> [MCPRawResourceRecord] {
        var cursor: String?
        var seen: Set<String> = []
        var values: [MCPRawResourceRecord] = []
        var pages = 0
        repeat {
            try await executionPreflight(server)
            pages += 1
            guard pages <= limits.maximumPages else {
                throw MCPResourceCatalogError.tooManyPages(
                    maximum: limits.maximumPages)
            }
            let fence = try operationFence(
                server,
                operation: .listResources,
                target: cursor ?? "")
            let page = try await server.connection.route
                .listResourcesPage(
                    cursor: cursor,
                    fence: fence)
            values.append(contentsOf: page.resources.filter {
                isAllowed(
                    name: $0.name,
                    identity: $0.uri,
                    server: server)
            })
            guard values.count <= limits.maximumItems else {
                throw MCPResourceCatalogError.tooManyItems(
                    kind: "resources",
                    maximum: limits.maximumItems)
            }
            cursor = page.nextCursor
            if let cursor {
                try validateCursor(cursor)
                guard seen.insert(cursor).inserted else {
                    throw MCPResourceCatalogError.cursorCycle(cursor)
                }
            }
        } while cursor != nil
        return values
    }

    private func allTemplates(
        _ server: MCPAgentResourceServerView
    ) async throws -> [MCPRawResourceTemplateRecord] {
        var cursor: String?
        var seen: Set<String> = []
        var values: [MCPRawResourceTemplateRecord] = []
        var pages = 0
        repeat {
            try await executionPreflight(server)
            pages += 1
            guard pages <= limits.maximumPages else {
                throw MCPResourceCatalogError.tooManyPages(
                    maximum: limits.maximumPages)
            }
            let fence = try operationFence(
                server,
                operation: .listResourceTemplates,
                target: cursor ?? "")
            let page = try await server.connection.route
                .listResourceTemplatesPage(
                    cursor: cursor,
                    fence: fence)
            values.append(contentsOf: page.templates.filter {
                isAllowed(
                    name: $0.name,
                    identity: $0.uriTemplate,
                    server: server)
            })
            guard values.count <= limits.maximumItems else {
                throw MCPResourceCatalogError.tooManyItems(
                    kind: "resource_templates",
                    maximum: limits.maximumItems)
            }
            cursor = page.nextCursor
            if let cursor {
                try validateCursor(cursor)
                guard seen.insert(cursor).inserted else {
                    throw MCPResourceCatalogError.cursorCycle(cursor)
                }
            }
        } while cursor != nil
        return values
    }

    private func resolve(
        _ alias: String
    ) throws -> MCPAgentResourceServerView {
        let matches = view.servers.filter {
            $0.policy.serverAlias == alias
        }
        guard !matches.isEmpty else {
            throw MCPContentOperationError.unknownServer(alias)
        }
        guard matches.count == 1, let match = matches.first else {
            throw MCPContentOperationError.ambiguousServer(alias)
        }
        return match
    }

    private func ensureGrantActive(
        _ server: MCPAgentResourceServerView
    ) throws {
        guard server.grant.isActive(),
              server.grant.grants(.resources),
              server.grant.revocationGeneration
                == server.connection.bindingIdentity
                    .revocationGeneration else {
            throw MCPContentOperationError.missingGrant(.resources)
        }
    }

    private func operationFence(
        _ server: MCPAgentResourceServerView,
        operation: MCPExternalOperationKind,
        target: String
    ) throws -> MCPExternalOperationFence {
        MCPExternalOperationFence(
            request:
                try MCPExternalOperationAuthorityRequest(
                    operation: operation,
                    connection: server.connection,
                    grant: server.grant,
                    workspaceLease: workspaceLease,
                    target: target),
            verifier: authorityVerifier)
    }

    private func isAllowed(
        name: String,
        identity: String,
        server: MCPAgentResourceServerView
    ) -> Bool {
        Self.filterAllows(
            server.policy.serverFilter,
            name: name,
            identity: identity)
            && Self.filterAllows(
                server.policy.attachmentFilter,
                name: name,
                identity: identity)
            && Self.filterAllows(
                server.grant.filter.resources,
                name: name,
                identity: identity)
    }

    private static func filterAllows(
        _ filter: MCPNameFilter,
        name: String,
        identity: String
    ) -> Bool {
        guard !filter.denyList.contains(name),
              !filter.denyList.contains(identity) else {
            return false
        }
        guard let allowed = filter.allowList else { return true }
        return allowed.contains(name) || allowed.contains(identity)
    }

    private func validateCursor(_ cursor: String) throws {
        guard !cursor.isEmpty,
              cursor.utf8.count <= limits.maximumCursorBytes,
              !cursor.contains("\0"),
              !cursor.contains(where: \.isNewline) else {
            throw MCPContentOperationError.cursorTooLarge
        }
    }

    private static func safeReason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? String(describing: type(of: error))
    }
}

public enum MCPResourceToolRegistryBuilder {
    public static let listResourcesName = "list_mcp_resources"
    public static let listResourceTemplatesName =
        "list_mcp_resource_templates"
    public static let readResourceName = "read_mcp_resource"

    public static let listSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "server": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional MCP server name. Omit to aggregate all visible servers."),
            ]),
            "cursor": .object([
                "type": .string("string"),
                "description": .string(
                    "Opaque pagination cursor valid only for the specified server."),
            ]),
        ]),
        "additionalProperties": .bool(false),
    ])

    public static let readSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "server": .object([
                "type": .string("string"),
                "description": .string("MCP server name."),
            ]),
            "uri": .object([
                "type": .string("string"),
                "description": .string(
                    "URI of a resource from the current granted MCP catalog."),
            ]),
        ]),
        "required": .array([
            .string("server"),
            .string("uri"),
        ]),
        "additionalProperties": .bool(false),
    ])

    public static func build(
        base: ToolRegistry,
        view: MCPAgentResourceCatalogView,
        authorityVerifier:
            any MCPExternalOperationAuthorityVerifier,
        workspaceLease: WorkspaceLease?,
        limits: MCPResourceResultLimits = .init(),
        converter: MCPResourceContentConverter,
        executionPreflight:
            @escaping @Sendable (
                MCPAgentResourceServerView
            ) async throws -> Void = { _ in }
    ) -> ToolRegistry {
        guard !view.servers.isEmpty else { return base }
        let descriptors: [
            (MCPResourceToolOperation, ToolDescriptor, String)
        ] = [
            (
                .listResources,
                ToolDescriptor(
                    name: listResourcesName,
                    description:
                        "List resources exposed by connected MCP servers.",
                    sideEffect: .network,
                    parameters: listSchema,
                    strict: false,
                    deferLoading: nil,
                    outputSchema: nil,
                    supportsParallelCalls: true),
                "mcp.resource.list"
            ),
            (
                .listTemplates,
                ToolDescriptor(
                    name: listResourceTemplatesName,
                    description:
                        "List resource templates exposed by connected MCP servers.",
                    sideEffect: .network,
                    parameters: listSchema,
                    strict: false,
                    deferLoading: nil,
                    outputSchema: nil,
                    supportsParallelCalls: true),
                "mcp.resource.list"
            ),
            (
                .readResource,
                ToolDescriptor(
                    name: readResourceName,
                    description:
                        "Read one resource from a named MCP server.",
                    sideEffect: .network,
                    parameters: readSchema,
                    strict: false,
                    deferLoading: nil,
                    outputSchema: nil,
                    supportsParallelCalls: true),
                "mcp.resource.read"
            ),
        ]
        let registrations = descriptors.map {
            operation, descriptor, permission in
            ToolRegistration(
                descriptor: descriptor,
                tool: MCPModelResourceTool(
                    operation: operation,
                    view: view,
                    limits: limits,
                    converter: converter,
                    authorityVerifier:
                        authorityVerifier,
                    workspaceLease: workspaceLease,
                    executionPreflight:
                        executionPreflight),
                canonicalPermission: permission,
                mcpResourceAuthorizationResolver: { args in
                    try MCPResourceInvocationAuthorization
                        .snapshot(
                            operation: operation,
                            descriptor: descriptor,
                            args: args,
                            view: view)
                },
                argumentValidator: { args in
                    switch operation {
                    case .listResources, .listTemplates:
                        _ = try args.decode(
                            MCPResourceListArguments.self)
                    case .readResource:
                        _ = try args.decode(
                            MCPResourceReadArguments.self)
                    }
                })
        }
        let version = IntatisHostApplication.identity
            .namespacedIdentifier("mcp.resources.v1.")
            + MCPResourceToolHash.hash([
                base.registryVersion,
                view.connectionSetSnapshotID.rawValue,
                view.bindingID.rawValue,
                view.stableFingerprint,
            ])
        return base.adding(
            registrations: registrations,
            registryVersion: version)
    }
}

private enum MCPResourceInvocationAuthorization {
    static func snapshot(
        operation: MCPResourceToolOperation,
        descriptor: ToolDescriptor,
        args: ToolArgs,
        view: MCPAgentResourceCatalogView
    ) throws -> MCPResourceInvocationAuthorizationSnapshot {
        let requestedAlias: String?
        let requestedURI: String?
        let selected: [MCPAgentResourceServerView]
        switch operation {
        case .listResources, .listTemplates:
            let decoded = try args.decode(
                MCPResourceListArguments.self)
            if decoded.cursor != nil, decoded.server == nil {
                throw MCPContentOperationError.cursorRequiresServer
            }
            requestedAlias = decoded.server
            requestedURI = nil
            if let alias = decoded.server {
                selected = [try resolve(alias, in: view)]
            } else {
                selected = view.servers
            }
        case .readResource:
            let decoded = try args.decode(
                MCPResourceReadArguments.self)
            try MCPRawCatalogValidation.validateURI(decoded.uri)
            let server = try resolve(decoded.server, in: view)
            guard server.resources.contains(where: {
                $0.uri == decoded.uri
            }) else {
                throw MCPContentOperationError
                    .resourceNotGranted(decoded.uri)
            }
            try server.policy.validateReadURI(
                decoded.uri,
                authority:
                    server.connection.reuseIdentity.authority)
            requestedAlias = decoded.server
            requestedURI = decoded.uri
            selected = [server]
        }

        guard !selected.isEmpty else {
            throw MCPContentOperationError.missingGrant(.resources)
        }
        let routes = try selected.map(route)
            .sorted {
                if $0.serverAlias != $1.serverAlias {
                    return $0.serverAlias < $1.serverAlias
                }
                if $0.server.serverID != $1.server.serverID {
                    return $0.server.serverID.rawValue
                        < $1.server.serverID.rawValue
                }
                return $0.grantID.rawValue
                    < $1.grantID.rawValue
            }
        let uriComponents = requestedURI.flatMap {
            URLComponents(string: $0)
        }
        return MCPResourceInvocationAuthorizationSnapshot(
            operation: descriptor.name,
            requestedServerAlias: requestedAlias,
            requestedResourceURIDigest:
                requestedURI.map {
                    MCPResourceToolHash.hash([$0])
                },
            requestedResourceURICharacterCount:
                requestedURI?.count,
            requestedResourceURIScheme:
                uriComponents?.scheme?.lowercased(),
            routes: routes)
    }

    private static func resolve(
        _ alias: String,
        in view: MCPAgentResourceCatalogView
    ) throws -> MCPAgentResourceServerView {
        let matches = view.servers.filter {
            $0.policy.serverAlias == alias
        }
        guard !matches.isEmpty else {
            throw MCPContentOperationError.unknownServer(alias)
        }
        guard matches.count == 1,
              let match = matches.first else {
            throw MCPContentOperationError.ambiguousServer(alias)
        }
        return match
    }

    private static func route(
        _ server: MCPAgentResourceServerView
    ) throws -> MCPResourceAuthorizationRouteSnapshot {
        let authority =
            server.connection.reuseIdentity.authority
        let binding = server.connection.bindingIdentity
        let grant = server.grant
        guard authority.hasCurrentExecutionAuthority,
              grant.isActive(),
              grant.grants(.resources),
              grant.capabilityLeaseID
                == authority.capabilityLeaseID,
              grant.taskID
                == authority.capabilityTaskID,
              grant.agentID == authority.agentID,
              grant.attachmentID == authority.attachmentID,
              grant.server == authority.server,
              grant.authorityFingerprint
                == authority.fingerprint,
              grant.revocationGeneration
                == binding.revocationGeneration,
              binding.server == authority.server else {
            throw MCPContentOperationError.missingGrant(.resources)
        }
        return MCPResourceAuthorizationRouteSnapshot(
            server: binding.server,
            serverAlias: server.policy.serverAlias,
            attachmentID: authority.attachmentID,
            grantID: grant.grantID,
            grantFingerprint: grant.grantFingerprint,
            agentID: authority.agentID,
            capabilityLeaseID: authority.capabilityLeaseID,
            capabilityTaskID:
                authority.capabilityTaskID,
            workspaceLeaseID: authority.workspaceLeaseID,
            connectionGeneration:
                binding.connectionGeneration,
            rawCatalogRevision: binding.rawCatalogRevision,
            agentCatalogViewRevision:
                binding.agentCatalogViewRevision,
            bindingID: binding.bindingID,
            protocolProfile: binding.protocolProfile,
            maximumProtocolVersion:
                binding.maximumProtocolVersion,
            negotiatedProtocolVersion:
                binding.negotiatedProtocolVersion,
            accountReference:
                server.connection.reuseIdentity
                    .oauthAccountReference,
            environmentReference:
                server.connection.reuseIdentity
                    .environmentReference,
            authorityFingerprint: authority.fingerprint,
            revocationGeneration:
                binding.revocationGeneration,
            resourcePolicyFingerprint:
                server.policy.policyFingerprint)
    }
}

enum MCPResourceToolHash {
    static func hash(_ fields: [String]) -> String {
        let material = fields.map {
            "\($0.utf8.count):\($0)"
        }.joined()
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
