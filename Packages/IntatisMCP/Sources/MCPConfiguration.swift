#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisMCP requires CryptoKit or swift-crypto")
#endif
import Foundation
import IntatisProtocol

// MARK: - Secret-safe configuration values

/// The kind of secure backend that owns an MCP credential.
///
/// This is metadata only. The referenced value is never Codable and never
/// belongs in the catalog. Platform hosts must reject a storage class they
/// cannot securely implement (for example Keychain on a non-macOS CLI).
public enum MCPSecretStorageClass: String, Codable, Equatable, Hashable, Sendable {
    case macOSKeychain = "macos_keychain"
    case encryptedCLIStore = "encrypted_cli_store"
    case environment
    case hostOwned = "host_owned"
}

/// Opaque, secret-free pointer resolved by a dedicated host credential store.
public struct MCPSecretReference: Codable, Equatable, Hashable, Sendable {
    public let storageClass: MCPSecretStorageClass
    public let identifier: String
    public let sourceBindingFingerprint: String?

    public init(
        storageClass: MCPSecretStorageClass,
        identifier: String,
        sourceBindingFingerprint: String? = nil
    ) throws {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == identifier,
              (1...256).contains(identifier.utf8.count),
              !identifier.contains(where: \.isNewline),
              !MCPConfigurationValidation.hasKnownSecretPrefix(identifier) else {
            throw MCPConfigurationError.invalidSecretReference
        }
        if let sourceBindingFingerprint {
            guard MCPConfigurationValidation.isSHA256(sourceBindingFingerprint) else {
                throw MCPConfigurationError.invalidSecretReference
            }
        }
        self.storageClass = storageClass
        self.identifier = identifier
        self.sourceBindingFingerprint = sourceBindingFingerprint
    }
}

/// A catalog-safe value. Literal values are only accepted after conservative
/// secret screening; likely credentials must be converted to a reference.
public enum MCPConfiguredValue: Codable, Equatable, Hashable, Sendable {
    case literal(String)
    case secret(MCPSecretReference)

    public func validated(fieldName: String) throws -> MCPConfiguredValue {
        switch self {
        case .literal(let value):
            guard value.utf8.count <= MCPConfigurationLimits.maximumScalarBytes,
                  !value.contains("\0"),
                  !MCPConfigurationValidation.sensitiveName(fieldName),
                  !MCPConfigurationValidation.looksLikeSecret(value) else {
                throw MCPConfigurationError.secretMustUseReference(fieldName)
            }
            return self
        case .secret:
            return self
        }
    }
}

// MARK: - Policy and transport model

public struct MCPServerTimeouts: Codable, Equatable, Hashable, Sendable {
    public let startupMilliseconds: Int
    public let callMilliseconds: Int
    public let shutdownMilliseconds: Int

    public init(
        startupMilliseconds: Int = 30_000,
        callMilliseconds: Int = 60_000,
        shutdownMilliseconds: Int = 5_000
    ) throws {
        for value in [startupMilliseconds, callMilliseconds, shutdownMilliseconds] {
            guard (100...3_600_000).contains(value) else {
                throw MCPConfigurationError.invalidTimeout
            }
        }
        self.startupMilliseconds = startupMilliseconds
        self.callMilliseconds = callMilliseconds
        self.shutdownMilliseconds = shutdownMilliseconds
    }
}

public struct MCPApprovalPolicy: Codable, Equatable, Hashable, Sendable {
    public let serverDefault: MCPApprovalMode
    public let toolOverrides: [String: MCPApprovalMode]

    public init(
        serverDefault: MCPApprovalMode = .auto,
        toolOverrides: [String: MCPApprovalMode] = [:]
    ) throws {
        guard toolOverrides.count <= MCPConfigurationLimits.maximumPolicyEntries else {
            throw MCPConfigurationError.configurationTooLarge
        }
        for name in toolOverrides.keys {
            try MCPConfigurationValidation.validateRemoteName(name)
        }
        self.serverDefault = serverDefault
        self.toolOverrides = toolOverrides
    }

    public func effectiveMode(for toolName: String) -> MCPApprovalMode {
        toolOverrides[toolName] ?? serverDefault
    }

    /// Used when an import has more than one explicit policy source.
    /// Prompt is always-interactive and therefore the most restrictive MCP
    /// mode. This ordering never bypasses Intatis hard gates or leases.
    public static func mostRestrictive(
        _ lhs: MCPApprovalMode,
        _ rhs: MCPApprovalMode
    ) -> MCPApprovalMode {
        let rank: [MCPApprovalMode: Int] = [
            .approve: 0,
            .auto: 1,
            .writes: 2,
            .prompt: 3,
        ]
        return (rank[lhs] ?? Int.max) >= (rank[rhs] ?? Int.max) ? lhs : rhs
    }
}

public struct MCPServerFilters: Codable, Equatable, Hashable, Sendable {
    public let tools: MCPNameFilter
    public let resources: MCPNameFilter
    public let prompts: MCPNameFilter
    public let completions: MCPNameFilter

    public init(
        tools: MCPNameFilter = .init(),
        resources: MCPNameFilter = .init(),
        prompts: MCPNameFilter = .init(),
        completions: MCPNameFilter = .init()
    ) throws {
        for filter in [tools, resources, prompts, completions] {
            let count = (filter.allowList?.count ?? 0) + filter.denyList.count
            guard count <= MCPConfigurationLimits.maximumPolicyEntries else {
                throw MCPConfigurationError.configurationTooLarge
            }
            for name in (filter.allowList ?? []) + filter.denyList {
                try MCPConfigurationValidation.validateRemoteName(name)
            }
        }
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
        self.completions = completions
    }
}

public enum MCPStdioNetworkPolicy: Codable, Equatable, Hashable, Sendable {
    case denied
    case exactOrigins([String])

    fileprivate func validated() throws -> MCPStdioNetworkPolicy {
        switch self {
        case .denied:
            return self
        case .exactOrigins(let origins):
            guard !origins.isEmpty,
                  origins.count <= MCPConfigurationLimits.maximumNetworkOrigins else {
                throw MCPConfigurationError.invalidNetworkPolicy
            }
            let canonical = try origins.map {
                try MCPConfigurationValidation.canonicalHTTPSOrigin($0)
            }
            return .exactOrigins(Array(Set(canonical)).sorted())
        }
    }
}

public struct MCPStdioServerConfiguration: Codable, Equatable, Hashable, Sendable {
    public let launchArtifact: LaunchArtifactIdentity
    public let arguments: [String]
    public let workingDirectory: String?
    public let environment: [String: MCPConfiguredValue]
    public let inheritedEnvironmentReferences: [String: MCPSecretReference]
    public let helperArtifacts: [LaunchArtifactIdentity]
    public let networkPolicy: MCPStdioNetworkPolicy

    public init(
        launchArtifact: LaunchArtifactIdentity,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: MCPConfiguredValue] = [:],
        inheritedEnvironmentReferences: [String: MCPSecretReference] = [:],
        helperArtifacts: [LaunchArtifactIdentity] = [],
        networkPolicy: MCPStdioNetworkPolicy = .denied
    ) throws {
        guard arguments.count <= MCPConfigurationLimits.maximumArguments,
              helperArtifacts.count <= MCPConfigurationLimits.maximumHelperArtifacts,
              environment.count + inheritedEnvironmentReferences.count
                <= MCPConfigurationLimits.maximumEnvironmentEntries else {
            throw MCPConfigurationError.configurationTooLarge
        }
        try MCPConfigurationValidation.validateLaunchArtifact(
            launchArtifact,
            mustContainExecutable: true)
        for helper in helperArtifacts {
            try MCPConfigurationValidation.validateLaunchArtifact(
                helper,
                mustContainExecutable: false)
        }
        for argument in arguments {
            guard argument.utf8.count <= MCPConfigurationLimits.maximumScalarBytes,
                  !argument.contains("\0") else {
                throw MCPConfigurationError.invalidArgument
            }
        }
        let canonicalWorkingDirectory = try workingDirectory.map {
            try MCPConfigurationValidation.canonicalAbsolutePath($0)
        }
        for (name, value) in environment {
            try MCPConfigurationValidation.validateEnvironmentName(name)
            _ = try value.validated(fieldName: name)
        }
        for name in inheritedEnvironmentReferences.keys {
            try MCPConfigurationValidation.validateEnvironmentName(name)
        }

        self.launchArtifact = launchArtifact
        self.arguments = arguments
        self.workingDirectory = canonicalWorkingDirectory
        self.environment = environment
        self.inheritedEnvironmentReferences = inheritedEnvironmentReferences
        self.helperArtifacts = helperArtifacts
        self.networkPolicy = try networkPolicy.validated()
    }

    public var executableCanonicalPath: String {
        launchArtifact.files.first(where: { $0.role == .executable })!.canonicalPath
    }
}

public enum MCPHTTPRedirectPolicy: String, Codable, Equatable, Hashable, Sendable {
    case deny
    case sameOriginOnly = "same_origin_only"
}

public enum MCPHTTPProxyPolicy: String, Codable, Equatable, Hashable, Sendable {
    /// No proxy. libcurl clears proxy and no-proxy state explicitly, and the
    /// target socket is bound to the authorized resolver address set.
    case direct
    /// Explicitly delegates the network hop and target resolution to the
    /// configured/ambient proxy. The connected peer is the proxy, so target
    /// `CURLOPT_RESOLVE`/primary-address claims do not apply in this mode.
    case systemConfigured = "system_configured"
}

public enum MCPTLSPolicy: Codable, Equatable, Hashable, Sendable {
    case systemTrust
    /// Lowercase hexadecimal SHA-256 digests of the certificate's DER
    /// SubjectPublicKeyInfo. This is the standard libcurl
    /// `sha256//base64(SHA256(SPKI))` pin expressed as stable config hex.
    case pinnedPublicKeySHA256([String])

    fileprivate func validated() throws -> MCPTLSPolicy {
        switch self {
        case .systemTrust:
            return self
        case .pinnedPublicKeySHA256(let values):
            guard !values.isEmpty, values.count <= 16,
                  values.allSatisfy(MCPConfigurationValidation.isSHA256) else {
                throw MCPConfigurationError.invalidTLSPolicy
            }
            return .pinnedPublicKeySHA256(
                Array(Set(values.map {
                    $0.lowercased()
                })).sorted())
        }
    }
}

public struct MCPOAuthConfiguration: Codable, Equatable, Hashable, Sendable {
    public let enabled: Bool
    public let canonicalResource: String
    public let clientID: String?
    public let clientSecretReference: MCPSecretReference?
    public let scopes: [String]
    public let accountReference: MCPAccountReference?

    public init(
        enabled: Bool,
        canonicalResource: String,
        clientID: String? = nil,
        clientSecretReference: MCPSecretReference? = nil,
        scopes: [String] = [],
        accountReference: MCPAccountReference? = nil
    ) throws {
        let resource = try MCPConfigurationValidation.canonicalHTTPSURL(
            canonicalResource,
            allowPath: true)
        guard scopes.count <= 128,
              scopes.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 256
                    && !$0.contains(where: \.isWhitespace)
              }) else {
            throw MCPConfigurationError.invalidOAuthConfiguration
        }
        if let clientID {
            guard !clientID.isEmpty, clientID.utf8.count <= 512,
                  !clientID.contains("\0"),
                  !clientID.contains(where: \.isNewline) else {
                throw MCPConfigurationError.invalidOAuthConfiguration
            }
        }
        guard enabled || (clientID == nil && clientSecretReference == nil
            && scopes.isEmpty && accountReference == nil) else {
            throw MCPConfigurationError.invalidOAuthConfiguration
        }
        self.enabled = enabled
        self.canonicalResource = resource
        self.clientID = clientID
        self.clientSecretReference = clientSecretReference
        self.scopes = Array(Set(scopes)).sorted()
        self.accountReference = accountReference
    }
}

public struct MCPHTTPServerConfiguration: Codable, Equatable, Hashable, Sendable {
    public let endpoint: String
    public let canonicalOrigin: String
    /// Explicit development-only exception. Production remains HTTPS-only.
    /// When true, HTTP is still restricted to exact localhost/loopback hosts,
    /// direct transport, same-origin-or-deny redirects, no OAuth, and system
    /// trust (there is no TLS identity to pin).
    public let allowInsecureLoopbackDevelopmentHTTP: Bool
    public let headers: [String: MCPConfiguredValue]
    public let bearerTokenReference: MCPSecretReference?
    public let oauth: MCPOAuthConfiguration?
    public let redirectPolicy: MCPHTTPRedirectPolicy
    public let proxyPolicy: MCPHTTPProxyPolicy
    public let tlsPolicy: MCPTLSPolicy

    public init(
        endpoint: String,
        allowInsecureLoopbackDevelopmentHTTP: Bool = false,
        headers: [String: MCPConfiguredValue] = [:],
        bearerTokenReference: MCPSecretReference? = nil,
        oauth: MCPOAuthConfiguration? = nil,
        redirectPolicy: MCPHTTPRedirectPolicy = .sameOriginOnly,
        proxyPolicy: MCPHTTPProxyPolicy = .direct,
        tlsPolicy: MCPTLSPolicy = .systemTrust
    ) throws {
        guard headers.count <= MCPConfigurationLimits.maximumHeaderEntries else {
            throw MCPConfigurationError.configurationTooLarge
        }
        let canonicalEndpoint = try MCPConfigurationValidation.canonicalHTTPURL(
            endpoint,
            allowPath: true,
            allowInsecureLoopbackDevelopmentHTTP:
                allowInsecureLoopbackDevelopmentHTTP)
        let origin = try MCPConfigurationValidation.canonicalHTTPOrigin(
            canonicalEndpoint,
            allowInsecureLoopbackDevelopmentHTTP:
                allowInsecureLoopbackDevelopmentHTTP)
        for (name, value) in headers {
            try MCPConfigurationValidation.validateHeaderName(name)
            _ = try value.validated(fieldName: name)
        }
        if let oauth {
            guard URL(string: canonicalEndpoint)?
                    .scheme?.lowercased() == "https" else {
                throw MCPConfigurationError
                    .invalidOAuthConfiguration
            }
            let resourceOrigin = try MCPConfigurationValidation.canonicalHTTPSOrigin(
                oauth.canonicalResource)
            guard resourceOrigin == origin else {
                throw MCPConfigurationError.oauthResourceOriginMismatch
            }
        }
        if URL(string: canonicalEndpoint)?
                .scheme?.lowercased() == "http" {
            guard allowInsecureLoopbackDevelopmentHTTP,
                  proxyPolicy == .direct,
                  tlsPolicy == .systemTrust else {
                throw MCPConfigurationError.invalidEndpoint
            }
        }
        self.endpoint = canonicalEndpoint
        self.canonicalOrigin = origin
        self.allowInsecureLoopbackDevelopmentHTTP =
            allowInsecureLoopbackDevelopmentHTTP
        self.headers = headers
        self.bearerTokenReference = bearerTokenReference
        self.oauth = oauth
        self.redirectPolicy = redirectPolicy
        self.proxyPolicy = proxyPolicy
        self.tlsPolicy = try tlsPolicy.validated()
    }

    private enum CodingKeys: String, CodingKey {
        case endpoint
        case allowInsecureLoopbackDevelopmentHTTP
        case headers
        case bearerTokenReference
        case oauth
        case redirectPolicy
        case proxyPolicy
        case tlsPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self)
        try self.init(
            endpoint: container.decode(
                String.self,
                forKey: .endpoint),
            allowInsecureLoopbackDevelopmentHTTP:
                container.decodeIfPresent(
                    Bool.self,
                    forKey:
                        .allowInsecureLoopbackDevelopmentHTTP)
                    ?? false,
            headers: container.decodeIfPresent(
                [String: MCPConfiguredValue].self,
                forKey: .headers) ?? [:],
            bearerTokenReference:
                container.decodeIfPresent(
                    MCPSecretReference.self,
                    forKey:
                        .bearerTokenReference),
            oauth: container.decodeIfPresent(
                MCPOAuthConfiguration.self,
                forKey: .oauth),
            redirectPolicy:
                container.decodeIfPresent(
                    MCPHTTPRedirectPolicy.self,
                    forKey: .redirectPolicy)
                    ?? .sameOriginOnly,
            proxyPolicy:
                container.decodeIfPresent(
                    MCPHTTPProxyPolicy.self,
                    forKey: .proxyPolicy)
                    ?? .direct,
            tlsPolicy:
                container.decodeIfPresent(
                    MCPTLSPolicy.self,
                    forKey: .tlsPolicy)
                    ?? .systemTrust)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(
            keyedBy: CodingKeys.self)
        try container.encode(
            endpoint,
            forKey: .endpoint)
        try container.encode(
            allowInsecureLoopbackDevelopmentHTTP,
            forKey:
                .allowInsecureLoopbackDevelopmentHTTP)
        try container.encode(
            headers,
            forKey: .headers)
        try container.encodeIfPresent(
            bearerTokenReference,
            forKey:
                .bearerTokenReference)
        try container.encodeIfPresent(
            oauth,
            forKey: .oauth)
        try container.encode(
            redirectPolicy,
            forKey: .redirectPolicy)
        try container.encode(
            proxyPolicy,
            forKey: .proxyPolicy)
        try container.encode(
            tlsPolicy,
            forKey: .tlsPolicy)
    }
}

public enum MCPTransportConfiguration: Codable, Equatable, Hashable, Sendable {
    case stdio(MCPStdioServerConfiguration)
    case streamableHTTP(MCPHTTPServerConfiguration)

    public var kind: MCPTransportKind {
        switch self {
        case .stdio: return .stdio
        case .streamableHTTP: return .streamableHTTP
        }
    }

    /// Secret-free digest used as one component of the runtime's exact reuse
    /// predicate. It is not by itself connection authority.
    public var connectionFingerprint: String {
        MCPConfigurationCanonical.sha256(
            (try? MCPConfigurationCanonical.encode(self)) ?? Data())
    }
}

public enum MCPConfigurationSourceKind: String, Codable, Equatable, Hashable, Sendable {
    case intatisUser = "intatis_user"
    case importedMCPJSON = "imported_mcp_json"
    case importedClaudeJSON = "imported_claude_json"
    case contributorProposal = "contributor_proposal"
    case migration
}

public struct MCPConfigurationProvenance: Codable, Equatable, Hashable, Sendable {
    public let sourceKind: MCPConfigurationSourceKind
    /// Basename or a user-provided safe label; never an absolute private path.
    public let sourceLabel: String
    public let formatVersion: Int
    public let sourceFingerprint: String?

    public init(
        sourceKind: MCPConfigurationSourceKind,
        sourceLabel: String,
        formatVersion: Int = 1,
        sourceFingerprint: String? = nil
    ) throws {
        let label = (sourceLabel as NSString).lastPathComponent
        guard label == sourceLabel,
              (1...256).contains(label.utf8.count),
              !label.contains("\0"),
              formatVersion > 0 else {
            throw MCPConfigurationError.invalidProvenance
        }
        if let sourceFingerprint {
            guard MCPConfigurationValidation.isSHA256(sourceFingerprint) else {
                throw MCPConfigurationError.invalidProvenance
            }
        }
        self.sourceKind = sourceKind
        self.sourceLabel = label
        self.formatVersion = formatVersion
        self.sourceFingerprint = sourceFingerprint
    }
}

/// Complete immutable server configuration, before its content-addressed
/// `MCPServerRevision` is allocated.
public struct MCPServerConfiguration: Codable, Equatable, Hashable, Sendable {
    public let serverID: MCPServerID
    public let displayName: String
    public let enabled: Bool
    public let required: Bool
    public let requiredCapabilities: [MCPGrantedCapability]
    public let protocolProfile: MCPProtocolProfile
    public let maximumProtocolVersion: MCPProtocolVersion
    public let approvalPolicy: MCPApprovalPolicy
    public let parallelCalls: Bool
    public let timeouts: MCPServerTimeouts
    public let filters: MCPServerFilters
    public let transport: MCPTransportConfiguration
    public let environmentReference: MCPEnvironmentReference
    public let provenance: MCPConfigurationProvenance

    public init(
        serverID: MCPServerID,
        displayName: String,
        enabled: Bool = true,
        required: Bool = false,
        requiredCapabilities: [MCPGrantedCapability] = [],
        protocolProfile: MCPProtocolProfile = .codexCompat,
        maximumProtocolVersion: MCPProtocolVersion? = nil,
        approvalPolicy: MCPApprovalPolicy,
        parallelCalls: Bool = false,
        timeouts: MCPServerTimeouts,
        filters: MCPServerFilters,
        transport: MCPTransportConfiguration,
        environmentReference: MCPEnvironmentReference,
        provenance: MCPConfigurationProvenance
    ) throws {
        try MCPConfigurationValidation.validateIdentifier(
            serverID.rawValue,
            field: "server_id")
        let normalizedDisplayName = displayName.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard normalizedDisplayName == displayName,
              (1...256).contains(displayName.utf8.count),
              !displayName.contains("\0") else {
            throw MCPConfigurationError.invalidDisplayName
        }
        let capabilities = Array(Set(requiredCapabilities)).sorted {
            $0.rawValue < $1.rawValue
        }
        let maximum = maximumProtocolVersion ?? protocolProfile.defaultMaximumVersion
        try MCPConfigurationValidation.validate(
            profile: protocolProfile,
            maximumVersion: maximum,
            requiredCapabilities: capabilities)
        try MCPConfigurationValidation.validateIdentifier(
            environmentReference.rawValue,
            field: "environment_reference")

        self.serverID = serverID
        self.displayName = displayName
        self.enabled = enabled
        self.required = required
        self.requiredCapabilities = capabilities
        self.protocolProfile = protocolProfile
        self.maximumProtocolVersion = maximum
        self.approvalPolicy = approvalPolicy
        self.parallelCalls = parallelCalls
        self.timeouts = timeouts
        self.filters = filters
        self.transport = transport
        self.environmentReference = environmentReference
        self.provenance = provenance
    }

    /// Re-runs every invariant after decoding untrusted catalog bytes and
    /// returns the unique canonical value used for hashing.
    public func validatedCanonical() throws -> MCPServerConfiguration {
        try MCPServerConfiguration(
            serverID: serverID,
            displayName: displayName,
            enabled: enabled,
            required: required,
            requiredCapabilities: requiredCapabilities,
            protocolProfile: protocolProfile,
            maximumProtocolVersion: maximumProtocolVersion,
            approvalPolicy: MCPApprovalPolicy(
                serverDefault: approvalPolicy.serverDefault,
                toolOverrides: approvalPolicy.toolOverrides),
            parallelCalls: parallelCalls,
            timeouts: MCPServerTimeouts(
                startupMilliseconds: timeouts.startupMilliseconds,
                callMilliseconds: timeouts.callMilliseconds,
                shutdownMilliseconds: timeouts.shutdownMilliseconds),
            filters: MCPServerFilters(
                tools: filters.tools,
                resources: filters.resources,
                prompts: filters.prompts,
                completions: filters.completions),
            transport: try transport.validatedCanonical(),
            environmentReference: environmentReference,
            provenance: MCPConfigurationProvenance(
                sourceKind: provenance.sourceKind,
                sourceLabel: provenance.sourceLabel,
                formatVersion: provenance.formatVersion,
                sourceFingerprint: provenance.sourceFingerprint))
    }

    public var canonicalFingerprint: String {
        MCPConfigurationCanonical.sha256(
            (try? MCPConfigurationCanonical.encode(self)) ?? Data())
    }
}

private extension MCPTransportConfiguration {
    func validatedCanonical() throws -> MCPTransportConfiguration {
        switch self {
        case .stdio(let value):
            return .stdio(try MCPStdioServerConfiguration(
                launchArtifact: value.launchArtifact,
                arguments: value.arguments,
                workingDirectory: value.workingDirectory,
                environment: value.environment,
                inheritedEnvironmentReferences: value.inheritedEnvironmentReferences,
                helperArtifacts: value.helperArtifacts,
                networkPolicy: value.networkPolicy))
        case .streamableHTTP(let value):
            return .streamableHTTP(try MCPHTTPServerConfiguration(
                endpoint: value.endpoint,
                allowInsecureLoopbackDevelopmentHTTP:
                    value
                        .allowInsecureLoopbackDevelopmentHTTP,
                headers: value.headers,
                bearerTokenReference: value.bearerTokenReference,
                oauth: value.oauth,
                redirectPolicy: value.redirectPolicy,
                proxyPolicy: value.proxyPolicy,
                tlsPolicy: value.tlsPolicy))
        }
    }
}

// MARK: - Validation

public enum MCPConfigurationError: Error, LocalizedError, Equatable, Sendable {
    case invalidIdentifier(String)
    case invalidDisplayName
    case invalidSecretReference
    case secretMustUseReference(String)
    case invalidTimeout
    case invalidArgument
    case invalidEnvironmentName
    case invalidHeaderName
    case invalidRemoteName
    case invalidLaunchArtifact
    case invalidPath
    case invalidEndpoint
    case invalidNetworkPolicy
    case invalidTLSPolicy
    case invalidOAuthConfiguration
    case oauthResourceOriginMismatch
    case invalidProtocolProfile
    case invalidProvenance
    case configurationTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            return "An MCP configuration identifier is invalid."
        case .invalidDisplayName:
            return "The MCP server display name is invalid."
        case .invalidSecretReference:
            return "The MCP secret reference is invalid."
        case .secretMustUseReference:
            return "A likely secret must be stored by reference."
        case .invalidTimeout:
            return "An MCP timeout is outside the supported bound."
        case .invalidArgument:
            return "An MCP process argument is invalid."
        case .invalidEnvironmentName:
            return "An MCP environment-variable name is invalid."
        case .invalidHeaderName:
            return "An MCP HTTP header name is invalid."
        case .invalidRemoteName:
            return "An MCP catalog name is invalid."
        case .invalidLaunchArtifact:
            return "The MCP launch artifact identity is invalid."
        case .invalidPath:
            return "An MCP filesystem path is not canonical and absolute."
        case .invalidEndpoint:
            return "The MCP endpoint must be canonical HTTPS, or an explicitly enabled development-only HTTP loopback URL."
        case .invalidNetworkPolicy:
            return "The MCP network policy is invalid."
        case .invalidTLSPolicy:
            return "The MCP TLS policy is invalid."
        case .invalidOAuthConfiguration:
            return "The MCP OAuth configuration is invalid."
        case .oauthResourceOriginMismatch:
            return "The MCP OAuth resource is outside the configured origin."
        case .invalidProtocolProfile:
            return "The MCP protocol profile, maximum version, or required capability is invalid."
        case .invalidProvenance:
            return "The MCP configuration provenance is invalid."
        case .configurationTooLarge:
            return "The MCP configuration exceeds a bounded limit."
        }
    }
}

public enum MCPConfigurationLimits {
    public static let maximumScalarBytes = 64 * 1024
    public static let maximumArguments = 1_024
    public static let maximumEnvironmentEntries = 1_024
    public static let maximumHeaderEntries = 256
    public static let maximumPolicyEntries = 10_000
    public static let maximumHelperArtifacts = 128
    public static let maximumNetworkOrigins = 256
}

enum MCPConfigurationCanonical {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum MCPConfigurationValidation {
    static let protocolOrder = [
        "2024-11-05",
        "2025-03-26",
        "2025-06-18",
        "2025-11-25",
    ]

    static func validateIdentifier(_ value: String, field: String) throws {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        guard (1...256).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw MCPConfigurationError.invalidIdentifier(field)
        }
    }

    static func validateRemoteName(_ value: String) throws {
        guard (1...512).contains(value.utf8.count),
              !value.contains("\0"),
              !value.contains(where: \.isNewline) else {
            throw MCPConfigurationError.invalidRemoteName
        }
    }

    static func validateEnvironmentName(_ value: String) throws {
        guard let first = value.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first),
              value.unicodeScalars.dropFirst().allSatisfy({
                  CharacterSet.alphanumerics
                    .union(CharacterSet(charactersIn: "_")).contains($0)
              }),
              value.utf8.count <= 256 else {
            throw MCPConfigurationError.invalidEnvironmentName
        }
    }

    static func validateHeaderName(_ value: String) throws {
        let token = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard !value.isEmpty, value.utf8.count <= 256,
              value.unicodeScalars.allSatisfy(token.contains) else {
            throw MCPConfigurationError.invalidHeaderName
        }
    }

    static func validateLaunchArtifact(
        _ artifact: LaunchArtifactIdentity,
        mustContainExecutable: Bool
    ) throws {
        guard !artifact.files.isEmpty,
              artifact.files.count <= 256,
              isSHA256(artifact.fingerprint),
              !mustContainExecutable
                || artifact.files.filter({ $0.role == .executable }).count == 1 else {
            throw MCPConfigurationError.invalidLaunchArtifact
        }
        for file in artifact.files {
            guard (try? canonicalAbsolutePath(file.canonicalPath)) == file.canonicalPath,
                  isSHA256(file.sha256),
                  !file.fileType.isEmpty,
                  file.fileType.utf8.count <= 128 else {
                throw MCPConfigurationError.invalidLaunchArtifact
            }
            if let resolved = file.resolvedSymlinkPath {
                guard (try? canonicalAbsolutePath(resolved)) == resolved else {
                    throw MCPConfigurationError.invalidLaunchArtifact
                }
            }
        }
    }

    static func canonicalAbsolutePath(_ value: String) throws -> String {
        guard value.hasPrefix("/"), !value.contains("\0") else {
            throw MCPConfigurationError.invalidPath
        }
        let standardized = URL(fileURLWithPath: value).standardizedFileURL.path
        guard standardized == value || standardized + "/" == value else {
            throw MCPConfigurationError.invalidPath
        }
        return standardized
    }

    static func canonicalHTTPSOrigin(_ value: String) throws -> String {
        let canonical = try canonicalHTTPSURL(
            value,
            allowPath: true)
        return try canonicalOrigin(
            canonical,
            expectedScheme: "https")
    }

    static func canonicalHTTPOrigin(
        _ value: String,
        allowInsecureLoopbackDevelopmentHTTP:
            Bool
    ) throws -> String {
        let canonical = try canonicalHTTPURL(
            value,
            allowPath: true,
            allowInsecureLoopbackDevelopmentHTTP:
                allowInsecureLoopbackDevelopmentHTTP)
        guard let components = URLComponents(string: canonical),
              let scheme =
                components.scheme?.lowercased()
        else {
            throw MCPConfigurationError.invalidEndpoint
        }
        return try canonicalOrigin(
            canonical,
            expectedScheme: scheme)
    }

    static func canonicalHTTPSURL(_ value: String, allowPath: Bool) throws -> String {
        try canonicalHTTPURL(
            value,
            allowPath: allowPath,
            allowInsecureLoopbackDevelopmentHTTP:
                false)
    }

    static func canonicalHTTPURL(
        _ value: String,
        allowPath: Bool,
        allowInsecureLoopbackDevelopmentHTTP:
            Bool
    ) throws -> String {
        guard value.utf8.count <= 8 * 1024,
              var components = URLComponents(string: value),
              let scheme =
                components.scheme?.lowercased(),
              (scheme == "https"
                    && !allowInsecureLoopbackDevelopmentHTTP)
                || (scheme == "http"
                    && allowInsecureLoopbackDevelopmentHTTP),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw MCPConfigurationError.invalidEndpoint
        }
        let normalizedHost = host.lowercased()
            .trimmingCharacters(
                in: CharacterSet(
                    charactersIn: "[]"))
        if scheme == "http" {
            guard isExactDevelopmentLoopbackHost(
                normalizedHost) else {
                throw MCPConfigurationError.invalidEndpoint
            }
        }
        components.scheme = scheme
        components.host = normalizedHost.contains(":")
            ? "[\(normalizedHost)]"
            : normalizedHost
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80)
        {
            components.port = nil
        }
        if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
        guard allowPath || components.percentEncodedPath == "/",
              let decodedPath = components.percentEncodedPath.removingPercentEncoding,
              !decodedPath.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0 == "." || $0 == ".." }),
              let result = components.string else {
            throw MCPConfigurationError.invalidEndpoint
        }
        return result
    }

    private static func canonicalOrigin(
        _ canonicalURL: String,
        expectedScheme: String
    ) throws -> String {
        guard var components =
                URLComponents(
                    string: canonicalURL),
              components.scheme?.lowercased()
                == expectedScheme,
              let host = components.host,
              !host.isEmpty else {
            throw MCPConfigurationError.invalidEndpoint
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        let defaultPort =
            expectedScheme == "https" ? 443 : 80
        if components.port == defaultPort {
            components.port = nil
        }
        guard let origin = components.string else {
            throw MCPConfigurationError.invalidEndpoint
        }
        return origin.hasSuffix("/")
            ? String(origin.dropLast())
            : origin
    }

    static func isExactDevelopmentLoopbackHost(
        _ host: String
    ) -> Bool {
        let normalized = host.lowercased()
            .trimmingCharacters(
                in: CharacterSet(
                    charactersIn: "[]"))
        return normalized == "localhost"
            || normalized == "127.0.0.1"
            || normalized == "::1"
    }

    static func validate(
        profile: MCPProtocolProfile,
        maximumVersion: MCPProtocolVersion,
        requiredCapabilities: [MCPGrantedCapability]
    ) throws {
        guard let maximumIndex = protocolOrder.firstIndex(of: maximumVersion.rawValue),
              let profileIndex = protocolOrder.firstIndex(
                  of: profile.defaultMaximumVersion.rawValue),
              maximumIndex <= profileIndex else {
            throw MCPConfigurationError.invalidProtocolProfile
        }
        if profile == .codexCompat {
            let extendedOnly: Set<MCPGrantedCapability> = [
                .prompts, .completions, .roots, .sampling, .tasks,
            ]
            guard Set(requiredCapabilities).isDisjoint(with: extendedOnly) else {
                throw MCPConfigurationError.invalidProtocolProfile
            }
        }
        if requiredCapabilities.contains(.tasks),
           maximumVersion != .v2025_11_25 {
            throw MCPConfigurationError.invalidProtocolProfile
        }
    }

    static func sensitiveName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return [
            "authorization", "proxy-authorization", "cookie", "set-cookie",
            "token", "secret", "password", "passwd", "api_key", "apikey",
            "private_key", "credential",
        ].contains { normalized.contains($0) }
    }

    static func looksLikeSecret(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if hasKnownSecretPrefix(lower) {
            return true
        }
        // Long opaque strings are not safe catalog literals.
        if trimmed.utf8.count >= 32,
           !trimmed.contains(" "),
           trimmed.unicodeScalars.allSatisfy({
               CharacterSet.alphanumerics
                   .union(CharacterSet(charactersIn: "-_=+/.")).contains($0)
           }) {
            return true
        }
        return false
    }

    static func hasKnownSecretPrefix(_ value: String) -> Bool {
        let lower = value.lowercased()
        return [
            "-----begin ", "sk-", "xoxb-", "xoxp-", "ghp_", "github_pat_",
            "akia", "bearer ", "basic ",
        ].contains(where: { lower.hasPrefix($0) })
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdef").contains($0)
            }
    }
}
