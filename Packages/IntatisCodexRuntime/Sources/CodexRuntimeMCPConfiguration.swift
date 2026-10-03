import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools
import IntatisMCP

/// Secret-safe projection of exact Intatis session MCP authority into the
/// pinned Codex App Server's native `[mcp_servers]` configuration surface.
///
/// This is configuration wiring only. Codex owns MCP discovery, calls,
/// approvals, resources, OAuth state, and transport lifecycle. Intatis does
/// not translate MCP tools into dynamic tools or retain a parallel client.
public struct CodexRuntimeMCPConfiguration: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    struct Server: Sendable {
        struct HTTP: Sendable {
            let url: String
            let bearerTokenEnvironmentVariable: String?
            let literalHeaders: [String: String]
            let environmentHeaders: [String: String]
            let oauthResource: String?
            let oauthClientID: String?
            let oauthScopes: [String]
        }

        let name: String
        let required: Bool
        let supportsParallelToolCalls: Bool
        let startupTimeoutSeconds: Double
        let toolTimeoutSeconds: Double
        let enabledTools: [String]?
        let disabledTools: [String]
        let defaultApprovalMode: MCPApprovalMode
        let toolApprovalModes: [String: MCPApprovalMode]
        let http: HTTP
    }

    let servers: [Server]
    let processEnvironment: [String: String]
    public let identity: String

    public static var empty: CodexRuntimeMCPConfiguration {
        CodexRuntimeMCPConfiguration(
            servers: [],
            processEnvironment: [:],
            identity: IntatisHostApplication.identity
                .namespacedIdentifier("codex-mcp.empty.v1"))
    }

    init(
        servers: [Server],
        processEnvironment: [String: String],
        identity: String
    ) {
        self.servers = servers
        self.processEnvironment = processEnvironment
        self.identity = identity
    }

    public var isEmpty: Bool { servers.isEmpty }
    public var serverNames: [String] { servers.map(\.name) }

    public var description: String {
        "CodexRuntimeMCPConfiguration(servers: \(servers.count), identity: \(identity))"
    }

    public var debugDescription: String { description }

    func renderedTOML() throws -> [String] {
        try renderedTOML(enabled: true)
    }

    private func renderedTOML(enabled: Bool) throws -> [String] {
        var lines: [String] = []
        let enabledValue = enabled ? "true" : "false"
        for server in servers.sorted(by: { $0.name < $1.name }) {
            let parallelValue = server.supportsParallelToolCalls
                ? "true"
                : "false"
            let table = "mcp_servers.\(try Self.tomlKey(server.name))"
            lines.append("[\(table)]")
            lines.append("url = \(try Self.tomlString(server.http.url))")
            lines.append("enabled = \(enabledValue)")
            lines.append("required = \(server.required ? "true" : "false")")
            lines.append(
                "startup_timeout_sec = \(Self.tomlNumber(server.startupTimeoutSeconds))")
            lines.append(
                "tool_timeout_sec = \(Self.tomlNumber(server.toolTimeoutSeconds))")
            lines.append(
                "supports_parallel_tool_calls = \(parallelValue)")
            lines.append(
                "default_tools_approval_mode = \(try Self.tomlString(server.defaultApprovalMode.rawValue))")
            if let enabledTools = server.enabledTools {
                lines.append(
                    "enabled_tools = \(try Self.tomlArray(enabledTools))")
            }
            if !server.disabledTools.isEmpty {
                lines.append(
                    "disabled_tools = \(try Self.tomlArray(server.disabledTools))")
            }
            if let bearer = server.http.bearerTokenEnvironmentVariable {
                lines.append(
                    "bearer_token_env_var = \(try Self.tomlString(bearer))")
            }
            if !server.http.literalHeaders.isEmpty {
                lines.append(
                    "http_headers = \(try Self.tomlInlineTable(server.http.literalHeaders))")
            }
            if !server.http.environmentHeaders.isEmpty {
                lines.append(
                    "env_http_headers = \(try Self.tomlInlineTable(server.http.environmentHeaders))")
            }
            if let resource = server.http.oauthResource {
                lines.append(
                    "oauth_resource = \(try Self.tomlString(resource))")
            }
            if !server.http.oauthScopes.isEmpty {
                lines.append(
                    "scopes = \(try Self.tomlArray(server.http.oauthScopes))")
            }
            lines.append("")
            if let clientID = server.http.oauthClientID {
                lines.append("[\(table).oauth]")
                lines.append(
                    "client_id = \(try Self.tomlString(clientID))")
                lines.append("")
            }
            for (tool, mode) in server.toolApprovalModes.sorted(by: {
                $0.key < $1.key
            }) {
                lines.append(
                    "[\(table).tools.\(try Self.tomlKey(tool))]")
                lines.append(
                    "approval_mode = \(try Self.tomlString(mode.rawValue))")
                lines.append("")
            }
        }
        return lines
    }

    /// Complete high-precedence official Codex role config used by Cowork
    /// descendants. Codex validates a role file before merging it, so each
    /// disabled entry retains the full secret-free server definition rather
    /// than relying on a partial table. Actual credentials remain only in the
    /// child process environment and a disabled server is not initialized.
    func renderedDisabledRoleOverlayTOML() throws -> [String] {
        try renderedTOML(enabled: false)
    }

    var disabledRoleOverlayValue: JSONValue {
        .object(Dictionary(uniqueKeysWithValues: servers.map { server in
            var value: [String: JSONValue] = [
                "url": .string(server.http.url),
                "enabled": .bool(false),
                "required": .bool(server.required),
                "startup_timeout_sec": .number(
                    server.startupTimeoutSeconds),
                "tool_timeout_sec": .number(
                    server.toolTimeoutSeconds),
                "supports_parallel_tool_calls": .bool(
                    server.supportsParallelToolCalls),
                "default_tools_approval_mode": .string(
                    server.defaultApprovalMode.rawValue),
            ]
            if let enabledTools = server.enabledTools {
                value["enabled_tools"] = .array(
                    enabledTools.map(JSONValue.string))
            }
            if !server.disabledTools.isEmpty {
                value["disabled_tools"] = .array(
                    server.disabledTools.map(JSONValue.string))
            }
            if let bearer = server.http
                .bearerTokenEnvironmentVariable {
                value["bearer_token_env_var"] = .string(bearer)
            }
            if !server.http.literalHeaders.isEmpty {
                value["http_headers"] = .object(
                    server.http.literalHeaders.mapValues(JSONValue.string))
            }
            if !server.http.environmentHeaders.isEmpty {
                value["env_http_headers"] = .object(
                    server.http.environmentHeaders
                        .mapValues(JSONValue.string))
            }
            if let resource = server.http.oauthResource {
                value["oauth_resource"] = .string(resource)
            }
            if !server.http.oauthScopes.isEmpty {
                value["scopes"] = .array(
                    server.http.oauthScopes.map(JSONValue.string))
            }
            if let clientID = server.http.oauthClientID {
                value["oauth"] = .object([
                    "client_id": .string(clientID),
                ])
            }
            if !server.toolApprovalModes.isEmpty {
                value["tools"] = .object(
                    server.toolApprovalModes.mapValues { mode in
                        .object([
                            "approval_mode": .string(mode.rawValue),
                        ])
                    })
            }
            return (server.name, .object(value))
        }))
    }

    private static func tomlString(_ value: String) throws -> String {
        let data = try JSONEncoder.intatisCodex.encode(value)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw CodexRuntimeError.malformedProtocol(
                "Codex MCP configuration contains invalid text")
        }
        return encoded
    }

    private static func tomlKey(_ value: String) throws -> String {
        try tomlString(value)
    }

    private static func tomlArray(_ values: [String]) throws -> String {
        "[" + (try values.map(tomlString)).joined(separator: ", ") + "]"
    }

    private static func tomlInlineTable(
        _ values: [String: String]
    ) throws -> String {
        let entries = try values.sorted(by: { $0.key < $1.key }).map {
            "\(try tomlKey($0.key)) = \(try tomlString($0.value))"
        }
        return "{ " + entries.joined(separator: ", ") + " }"
    }

    private static func tomlNumber(_ value: Double) -> String {
        value.rounded() == value
            ? String(Int(value))
            : String(value)
    }
}

public enum CodexRuntimeMCPProjector {
    public typealias SecretResolver = @Sendable (
        MCPSecretReference
    ) async throws -> Data

    /// The native Codex client exposes one connected server as one integrated
    /// surface. Its config can narrow tool names and approvals, but cannot
    /// reproduce the legacy client's independent capability-class switches.
    /// Requiring the complete grant prevents a tools-only grant from silently
    /// acquiring resource, prompt, callback, or task authority.
    public static let requiredNativeSurfaceCapabilities:
        Set<MCPGrantedCapability> = [
            .tools, .resources, .prompts, .completions,
            .logging, .progress, .subscriptions, .roots,
            .sampling, .elicitation, .tasks,
        ]

    /// Validates the authority shape that the pinned native Codex MCP client
    /// can preserve. Product grant entry points call the same function before
    /// persisting authority, while projection repeats it for old or forged
    /// EventLog state.
    public static func validateNativeSurfaceAuthority(
        capabilities: Set<MCPGrantedCapability>,
        expiresAt: Date?
    ) throws {
        guard capabilities == requiredNativeSurfaceCapabilities else {
            throw IntatisError.permissionDenied(
                "The attached MCP server has only a partial capability grant. Native Codex MCP requires the exact complete Interactive capability set.")
        }
        guard expiresAt == nil else {
            throw IntatisError.config(
                "Expiring MCP grants are not representable by native Codex MCP authority.")
        }
    }

    public static func project(
        catalog rawCatalog: MCPServerCatalog,
        attachments: [MCPServerAttachment],
        grants: [MCPGrant],
        consents: [MCPConsent],
        resolveSecret: @escaping SecretResolver
    ) async throws -> CodexRuntimeMCPConfiguration {
        let catalog = try rawCatalog.validated()
        var servers: [CodexRuntimeMCPConfiguration.Server] = []
        var processEnvironment: [String: String] = [:]
        var names: Set<String> = []
        var identityFields = [
            IntatisHostApplication.identity.temporaryPrefix(
                "codex-native-mcp/1"),
            catalog.contentDigest,
        ]

        for attachment in attachments.sorted(by: {
            $0.attachmentID.rawValue < $1.attachmentID.rawValue
        }) {
            let matching = grants.filter {
                $0.attachmentID == attachment.attachmentID
                    && $0.server == attachment.server
                    && $0.isActive()
            }
            guard !matching.isEmpty else { continue }
            guard matching.count == 1,
                  let grant = matching.first else {
                throw IntatisError.permissionDenied(
                    "More than one exact MCP grant is active for an attached server.")
            }
            try validateNativeSurfaceAuthority(
                capabilities: Set(grant.capabilities),
                expiresAt: grant.expiresAt)
            guard let definition = catalog.definition(
                    for: attachment.server),
                  definition.configuration.enabled,
                  !catalog.isTombstoned(attachment.server) else {
                if attachment.policy.required {
                    throw IntatisError.config(
                        "A required attached MCP server revision is unavailable.")
                }
                continue
            }
            let configuration = definition.configuration
            guard configuration.protocolProfile == .codexCompat,
                  configuration.maximumProtocolVersion
                    == MCPProtocolProfile.codexCompat
                        .defaultMaximumVersion else {
                throw IntatisError.config(
                    "The attached MCP server requests a protocol profile that the pinned Codex native configuration cannot freeze exactly.")
            }
            guard Set(configuration.requiredCapabilities).isSubset(
                    of: Set(grant.capabilities)) else {
                throw IntatisError.permissionDenied(
                    "The exact MCP grant does not include the server's required capabilities.")
            }
            let alias = catalog.head(
                for: attachment.server.serverID)?.alias
                ?? attachment.server.serverID.rawValue
            guard names.insert(alias).inserted else {
                throw IntatisError.config(
                    "Two attached MCP revisions resolve to the same native Codex server name.")
            }

            let consentRequirement = try exactConsentRequirement(
                definition: definition,
                attachment: attachment,
                grant: grant)
            let matchingConsents = consents.filter {
                consentRequirement.exactlyMatches($0)
            }
            guard matchingConsents.count == 1 else {
                throw IntatisError.permissionDenied(
                    matchingConsents.isEmpty
                        ? "The attached MCP server has no exact durable connect consent for this Agent grant."
                        : "More than one exact durable MCP connect consent is active.")
            }

            guard case .streamableHTTP(let http) = configuration.transport else {
                throw IntatisError.config(
                    "Local stdio MCP cannot yet be projected safely: the pinned Codex App Server has no official extension for \(IntatisHostApplication.identity.name)'s exact process and network-policy authority. Use an attached Streamable HTTP server or wait for that native extension.")
            }
            guard http.redirectPolicy == .sameOriginOnly,
                  http.proxyPolicy == .direct else {
                throw IntatisError.config(
                    "The attached MCP HTTP redirect or proxy policy is not representable by the pinned Codex native configuration.")
            }
            guard case .systemTrust = http.tlsPolicy else {
                throw IntatisError.config(
                    "The attached MCP TLS pin policy is not representable by the pinned Codex native configuration.")
            }

            var literalHeaders: [String: String] = [:]
            var environmentHeaders: [String: String] = [:]
            for (header, value) in http.headers.sorted(by: {
                $0.key < $1.key
            }) {
                switch value {
                case .literal(let literal):
                    literalHeaders[header] = literal
                case .secret(let reference):
                    let environmentName = secretEnvironmentName(
                        server: attachment.server,
                        field: "header:\(header)",
                        reference: reference)
                    let secret = try await resolveSecretString(
                        reference,
                        resolveSecret: resolveSecret,
                        forbidsNewlines: true)
                    try insertEnvironment(
                        secret,
                        name: environmentName,
                        into: &processEnvironment)
                    environmentHeaders[header] = environmentName
                }
            }

            var bearerEnvironment: String?
            if let reference = http.bearerTokenReference {
                let environmentName = secretEnvironmentName(
                    server: attachment.server,
                    field: "bearer",
                    reference: reference)
                let secret = try await resolveSecretString(
                    reference,
                    resolveSecret: resolveSecret,
                    forbidsNewlines: true)
                try insertEnvironment(
                    secret,
                    name: environmentName,
                    into: &processEnvironment)
                bearerEnvironment = environmentName
            }

            let oauth = http.oauth
            if let oauth, oauth.enabled {
                guard http.bearerTokenReference == nil,
                      oauth.clientSecretReference == nil,
                      oauth.accountReference == nil else {
                    throw IntatisError.config(
                        "This MCP OAuth authority belongs to the retired client runtime or needs a confidential client secret. Start a native Codex OAuth login for a public client instead; credentials are not translated between runtimes.")
                }
            }

            let toolFilter = intersection([
                configuration.filters.tools,
                attachment.policy.filter.tools,
                grant.filter.tools,
            ])
            let enabledTools = toolFilter.allowList.map { allowed in
                allowed.filter { !toolFilter.denyList.contains($0) }
            }
            let defaultApproval = MCPApprovalPolicy.mostRestrictive(
                MCPApprovalPolicy.mostRestrictive(
                    configuration.approvalPolicy.serverDefault,
                    attachment.policy.approvalMode),
                grant.approvalModeCeiling)
            var toolApprovalModes: [String: MCPApprovalMode] = [:]
            for (tool, serverMode) in configuration.approvalPolicy
                .toolOverrides
            {
                guard toolFilter.allows(tool) else { continue }
                toolApprovalModes[tool] = MCPApprovalPolicy.mostRestrictive(
                    MCPApprovalPolicy.mostRestrictive(
                        serverMode,
                        attachment.policy.approvalMode),
                    grant.approvalModeCeiling)
            }

            servers.append(CodexRuntimeMCPConfiguration.Server(
                name: alias,
                required: configuration.required
                    || attachment.policy.required,
                supportsParallelToolCalls:
                    configuration.parallelCalls,
                startupTimeoutSeconds:
                    Double(configuration.timeouts.startupMilliseconds)
                        / 1_000,
                toolTimeoutSeconds:
                    Double(configuration.timeouts.callMilliseconds)
                        / 1_000,
                enabledTools: enabledTools,
                disabledTools: toolFilter.denyList,
                defaultApprovalMode: defaultApproval,
                toolApprovalModes: toolApprovalModes,
                http: .init(
                    url: http.endpoint,
                    bearerTokenEnvironmentVariable: bearerEnvironment,
                    literalHeaders: literalHeaders,
                    environmentHeaders: environmentHeaders,
                    oauthResource: oauth?.enabled == true
                        ? oauth?.canonicalResource
                        : nil,
                    oauthClientID: oauth?.enabled == true
                        ? oauth?.clientID
                        : nil,
                    oauthScopes: oauth?.enabled == true
                        ? oauth?.scopes ?? []
                        : [])))
            identityFields.append(contentsOf: [
                attachment.attachmentID.rawValue,
                definition.definitionFingerprint,
                attachment.policy.revision.rawValue,
                grant.grantID.rawValue,
                grant.grantFingerprint,
                grant.revocationGeneration.rawValue,
                matchingConsents[0].consentID.rawValue,
            ])
        }

        guard processEnvironment.count
                <= MCPConfigurationLimits.maximumEnvironmentEntries else {
            throw IntatisError.config(
                "The projected native MCP environment exceeds its structural bound.")
        }
        let identity = servers.isEmpty
            ? CodexRuntimeMCPConfiguration.empty.identity
            : IntatisHostApplication.identity
                .namespacedIdentifier("codex-mcp.")
                + String(ToolRegistry.authorizationDigest(
                    identityFields.joined(separator: "\u{001F}"))
                    .prefix(32))
        return CodexRuntimeMCPConfiguration(
            servers: servers,
            processEnvironment: processEnvironment,
            identity: identity)
    }

    private struct ConsentRequirement {
        let kind: MCPConsentKind
        let server: MCPServerReference
        let attachmentID: MCPAttachmentID
        let authorityFingerprint: String
        let launchArtifactFingerprint: String?
        let accountReference: MCPAccountReference?
        let environmentReference: MCPEnvironmentReference
        let policyRevision: MCPPolicyRevision

        func exactlyMatches(_ consent: MCPConsent) -> Bool {
            consent.kind == kind
                && consent.server == server
                && consent.attachmentID == attachmentID
                && consent.authorityFingerprint == authorityFingerprint
                && consent.launchArtifactFingerprint
                    == launchArtifactFingerprint
                && consent.accountReference == accountReference
                && consent.environmentReference == environmentReference
                && consent.policyRevision == policyRevision
        }
    }

    private static func exactConsentRequirement(
        definition: MCPServerDefinition,
        attachment: MCPServerAttachment,
        grant: MCPGrant
    ) throws -> ConsentRequirement {
        let launchArtifactFingerprint: String?
        let accountReference: MCPAccountReference?
        let kind: MCPConsentKind
        switch definition.configuration.transport {
        case .stdio(let stdio):
            kind = .launch
            launchArtifactFingerprint = stdio.launchArtifact.fingerprint
            accountReference = nil
        case .streamableHTTP(let http):
            kind = .connect
            launchArtifactFingerprint = nil
            accountReference = http.oauth?.accountReference
        }
        return ConsentRequirement(
            kind: kind,
            server: attachment.server,
            attachmentID: attachment.attachmentID,
            authorityFingerprint: grant.authorityFingerprint,
            launchArtifactFingerprint: launchArtifactFingerprint,
            accountReference: accountReference,
            environmentReference:
                definition.configuration.environmentReference,
            policyRevision: attachment.policy.revision)
    }

    private static func intersection(
        _ filters: [MCPNameFilter]
    ) -> MCPNameFilter {
        let allowLists = filters.compactMap(\.allowList)
        let allowed: [String]?
        if let first = allowLists.first {
            var result = Set(first)
            for values in allowLists.dropFirst() {
                result.formIntersection(values)
            }
            allowed = result.sorted()
        } else {
            allowed = nil
        }
        let denied = Set(filters.flatMap(\.denyList)).sorted()
        return MCPNameFilter(
            allowList: allowed,
            denyList: denied)
    }

    private static func secretEnvironmentName(
        server: MCPServerReference,
        field: String,
        reference: MCPSecretReference
    ) -> String {
        let material = [
            IntatisHostApplication.identity.temporaryPrefix(
                "codex-mcp-secret/1"),
            server.serverID.rawValue,
            server.serverRevision.rawValue,
            field,
            reference.storageClass.rawValue,
            reference.identifier,
            reference.sourceBindingFingerprint ?? "",
        ].joined(separator: "\u{001F}")
        return IntatisHostApplication.identity.environmentVariable("MCP")
            + "_"
            + ToolRegistry.authorizationDigest(material)
                .prefix(32).uppercased()
    }

    private static func resolveSecretString(
        _ reference: MCPSecretReference,
        resolveSecret: SecretResolver,
        forbidsNewlines: Bool
    ) async throws -> String {
        var data = try await resolveSecret(reference)
        defer { data.resetBytes(in: 0..<data.count) }
        guard !data.isEmpty,
              data.count <= MCPSecretStoreLimits.maximumSecretBytes,
              !data.contains(0),
              let value = String(data: data, encoding: .utf8),
              !forbidsNewlines
                || (!value.contains("\r") && !value.contains("\n")) else {
            throw IntatisError.config(
                "An MCP credential cannot be represented safely in the native Codex process environment.")
        }
        return value
    }

    private static func insertEnvironment(
        _ value: String,
        name: String,
        into environment: inout [String: String]
    ) throws {
        if let existing = environment[name], existing != value {
            throw IntatisError.config(
                "Two MCP credential references collide in the native process environment.")
        }
        environment[name] = value
    }
}
