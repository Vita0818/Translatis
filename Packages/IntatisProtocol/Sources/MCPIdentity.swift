import Foundation
import IntatisCore

// MARK: - Stable MCP identities

/// Stable logical identity of a configured external MCP server.
public struct MCPServerID: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func new() -> MCPServerID {
        MCPServerID(rawValue: IDGen.random(prefix: "mcpserver"))
    }
}

/// Immutable revision of a server definition. A command, URL, credential
/// reference, environment reference, timeout, or transport-policy change must
/// produce a new value.
public struct MCPServerRevision: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// One real transport connection or one real managed local process.
public struct MCPConnectionGeneration: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func new() -> MCPConnectionGeneration {
        MCPConnectionGeneration(rawValue: IDGen.random(prefix: "mcpcnx"))
    }
}

/// A complete, validated, unfiltered catalog obtained from one server
/// generation.
public struct MCPRawCatalogRevision: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A catalog view derived for one Agent after server, attachment, and grant
/// policy has been applied.
public struct MCPAgentCatalogViewRevision: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Exact routing/tool snapshot shown to one provider dispatch.
public struct MCPBindingID: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func new() -> MCPBindingID {
        MCPBindingID(rawValue: IDGen.random(prefix: "mcpbind"))
    }
}

/// Monotonic authority generation changed whenever a grant, roots, network,
/// credential, catalog-staleness, or other restrictive boundary changes.
public struct MCPRevocationGeneration: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct MCPAttachmentID: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func new() -> MCPAttachmentID {
        MCPAttachmentID(rawValue: IDGen.random(prefix: "mcpattach"))
    }
}

public struct MCPGrantID: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func new() -> MCPGrantID {
        MCPGrantID(rawValue: IDGen.random(prefix: "mcpgrant"))
    }
}

public struct MCPConsentID: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func new() -> MCPConsentID {
        MCPConsentID(rawValue: IDGen.random(prefix: "mcpconsent"))
    }
}

public struct MCPControlOperationID: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func new() -> MCPControlOperationID {
        MCPControlOperationID(rawValue: IDGen.random(prefix: "mcpop"))
    }
}

public struct MCPRememberedApprovalID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> Self {
        .init(rawValue:
            "mcpapproval-\(UUID().uuidString.lowercased())")
    }
}

/// Host identity for a task created by a remote MCP server in response to an
/// Intatis request. This type is intentionally not interchangeable with a
/// client-hosted callback task.
public struct MCPRemoteServerTaskID: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func new() -> MCPRemoteServerTaskID {
        MCPRemoteServerTaskID(rawValue: IDGen.random(prefix: "mcpremote"))
    }
}

/// Host identity for a task that Intatis owns on behalf of a server callback
/// request. Keeping this distinct prevents accidental routing into the remote
/// task state machine or the Intatis/Cowork task graph.
public struct MCPClientHostedTaskID: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func new() -> MCPClientHostedTaskID {
        MCPClientHostedTaskID(rawValue: IDGen.random(prefix: "mcpclient"))
    }
}

public struct MCPResultReference: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func new() -> MCPResultReference {
        MCPResultReference(rawValue: IDGen.random(prefix: "mcpresult"))
    }
}

public struct MCPPolicyRevision: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Opaque, secret-free reference resolved by a dedicated credential backend.
/// It is intentionally not a token, username, e-mail address, or credential.
public struct MCPAccountReference: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Opaque identity of the selected runtime environment. It must not contain
/// resolved environment-variable values.
public struct MCPEnvironmentReference: TypedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct MCPServerReference: Codable, Equatable, Hashable, Sendable {
    public let serverID: MCPServerID
    public let serverRevision: MCPServerRevision

    public init(serverID: MCPServerID, serverRevision: MCPServerRevision) {
        self.serverID = serverID
        self.serverRevision = serverRevision
    }
}

// MARK: - Protocol profile and negotiation identity

/// SDK-independent MCP protocol version. Values are kept opaque on disk; the
/// MCP runtime owns validation and ordering.
public struct MCPProtocolVersion: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static let v2025_06_18 = MCPProtocolVersion(rawValue: "2025-06-18")
    public static let v2025_11_25 = MCPProtocolVersion(rawValue: "2025-11-25")

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct MCPNegotiatedProtocolVersion: Codable, Equatable, Hashable, Sendable {
    public let value: MCPProtocolVersion

    public init(_ value: MCPProtocolVersion) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(MCPProtocolVersion.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public enum MCPProtocolProfile: String, Codable, Equatable, Hashable, Sendable {
    case codexCompat = "codex-compat"
    case standardExtended = "standard-extended"

    public var defaultMaximumVersion: MCPProtocolVersion {
        switch self {
        case .codexCompat:
            return .v2025_06_18
        case .standardExtended:
            return .v2025_11_25
        }
    }
}

// MARK: - Launch artifact and connection authority

public enum MCPTransportKind: String, Codable, Equatable, Hashable, Sendable {
    case stdio
    case streamableHTTP = "streamable_http"
}

public enum MCPLaunchFileRole: String, Codable, Equatable, Hashable, Sendable {
    case executable
    case interpreter
    case script
    case packageEntrypoint = "package_entrypoint"
    case lockfile
    case helper
}

/// Secret-free, no-follow identity of one file participating in a launch.
public struct MCPLaunchFileIdentity: Codable, Equatable, Hashable, Sendable {
    public let role: MCPLaunchFileRole
    public let canonicalPath: String
    public let fileType: String
    public let ownerID: UInt64
    public let mode: UInt32
    public let deviceID: UInt64
    public let fileID: UInt64
    public let byteCount: UInt64
    public let sha256: String
    public let resolvedSymlinkPath: String?
    /// Bounded, non-certificate summary such as signing team and notarization
    /// status. Certificate bytes and full fingerprints do not belong here.
    public let codeSignatureSummary: String?

    public init(role: MCPLaunchFileRole,
                canonicalPath: String,
                fileType: String,
                ownerID: UInt64,
                mode: UInt32,
                deviceID: UInt64,
                fileID: UInt64,
                byteCount: UInt64,
                sha256: String,
                resolvedSymlinkPath: String? = nil,
                codeSignatureSummary: String? = nil) {
        self.role = role
        self.canonicalPath = canonicalPath
        self.fileType = fileType
        self.ownerID = ownerID
        self.mode = mode
        self.deviceID = deviceID
        self.fileID = fileID
        self.byteCount = byteCount
        self.sha256 = sha256
        self.resolvedSymlinkPath = resolvedSymlinkPath
        self.codeSignatureSummary = codeSignatureSummary
    }
}

/// Exact launch material approved for a local stdio server. The fingerprint is
/// produced by the host from the complete ordered component list.
public struct LaunchArtifactIdentity: Codable, Equatable, Hashable, Sendable {
    public let files: [MCPLaunchFileIdentity]
    public let fingerprint: String

    public init(files: [MCPLaunchFileIdentity], fingerprint: String) {
        self.files = files
        self.fingerprint = fingerprint
    }
}

/// All secret-free facts that determine whether a connection/process can be
/// shared. Equality of server aliases alone is never sufficient.
public struct MCPConnectionAuthority: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let server: MCPServerReference
    public let transport: MCPTransportKind
    public let protocolProfile: MCPProtocolProfile
    public let maximumProtocolVersion: MCPProtocolVersion
    public let sessionID: SessionID
    public let agentID: AgentID
    public let attachmentID: MCPAttachmentID
    public let capabilityLeaseID: CapabilityLeaseID
    public let capabilityTaskID: TaskID?
    public let workspaceLeaseID: WorkspaceLeaseID?
    public let workspaceRootIdentityFingerprint: String?
    public let workspaceLeasePolicyFingerprint: String?
    public let attachmentPolicyRevision: MCPPolicyRevision
    public let accountReference: MCPAccountReference?
    public let environmentReference: MCPEnvironmentReference
    public let launchArtifactFingerprint: String?
    public let rootsPolicyRevision: MCPPolicyRevision
    public let networkPolicyRevision: MCPPolicyRevision
    public let sandboxProfileRevision: MCPPolicyRevision
    public let sandboxPolicyFingerprint: String?
    public let hostPlatform: String
    public let fingerprint: String

    public init(schemaVersion: Int = currentSchemaVersion,
                server: MCPServerReference,
                transport: MCPTransportKind,
                protocolProfile: MCPProtocolProfile,
                maximumProtocolVersion: MCPProtocolVersion? = nil,
                sessionID: SessionID,
                agentID: AgentID,
                attachmentID: MCPAttachmentID,
                capabilityLeaseID: CapabilityLeaseID,
                capabilityTaskID: TaskID?,
                workspaceLeaseID: WorkspaceLeaseID? = nil,
                workspaceRootIdentityFingerprint: String? = nil,
                workspaceLeasePolicyFingerprint: String,
                attachmentPolicyRevision: MCPPolicyRevision,
                accountReference: MCPAccountReference? = nil,
                environmentReference: MCPEnvironmentReference,
                launchArtifactFingerprint: String? = nil,
                rootsPolicyRevision: MCPPolicyRevision,
                networkPolicyRevision: MCPPolicyRevision,
                sandboxProfileRevision: MCPPolicyRevision,
                sandboxPolicyFingerprint: String,
                hostPlatform: String,
                fingerprint: String) {
        self.schemaVersion = schemaVersion
        self.server = server
        self.transport = transport
        self.protocolProfile = protocolProfile
        self.maximumProtocolVersion = maximumProtocolVersion ?? protocolProfile.defaultMaximumVersion
        self.sessionID = sessionID
        self.agentID = agentID
        self.attachmentID = attachmentID
        self.capabilityLeaseID = capabilityLeaseID
        self.capabilityTaskID = capabilityTaskID
        self.workspaceLeaseID = workspaceLeaseID
        self.workspaceRootIdentityFingerprint = workspaceRootIdentityFingerprint
        self.workspaceLeasePolicyFingerprint =
            workspaceLeasePolicyFingerprint
        self.attachmentPolicyRevision = attachmentPolicyRevision
        self.accountReference = accountReference
        self.environmentReference = environmentReference
        self.launchArtifactFingerprint = launchArtifactFingerprint
        self.rootsPolicyRevision = rootsPolicyRevision
        self.networkPolicyRevision = networkPolicyRevision
        self.sandboxProfileRevision = sandboxProfileRevision
        self.sandboxPolicyFingerprint =
            sandboxPolicyFingerprint
        self.hostPlatform = hostPlatform
        self.fingerprint = fingerprint
    }

    public var hasCurrentExecutionAuthority: Bool {
        schemaVersion == Self.currentSchemaVersion
            && workspaceLeasePolicyFingerprint?
                .utf8.count == 64
            && sandboxPolicyFingerprint?
                .utf8.count == 64
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case server
        case transport
        case protocolProfile
        case maximumProtocolVersion
        case sessionID
        case agentID
        case attachmentID
        case capabilityLeaseID
        case capabilityTaskID
        case workspaceLeaseID
        case workspaceRootIdentityFingerprint
        case workspaceLeasePolicyFingerprint
        case attachmentPolicyRevision
        case accountReference
        case environmentReference
        case launchArtifactFingerprint
        case rootsPolicyRevision
        case networkPolicyRevision
        case sandboxProfileRevision
        case sandboxPolicyFingerprint
        case hostPlatform
        case fingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self)
        schemaVersion =
            try container.decodeIfPresent(
                Int.self,
                forKey: .schemaVersion) ?? 1
        server = try container.decode(
            MCPServerReference.self,
            forKey: .server)
        transport = try container.decode(
            MCPTransportKind.self,
            forKey: .transport)
        protocolProfile = try container.decode(
            MCPProtocolProfile.self,
            forKey: .protocolProfile)
        maximumProtocolVersion =
            try container.decodeIfPresent(
                MCPProtocolVersion.self,
                forKey:
                    .maximumProtocolVersion)
                ?? protocolProfile
                    .defaultMaximumVersion
        sessionID = try container.decode(
            SessionID.self,
            forKey: .sessionID)
        agentID = try container.decode(
            AgentID.self,
            forKey: .agentID)
        attachmentID = try container.decode(
            MCPAttachmentID.self,
            forKey: .attachmentID)
        capabilityLeaseID = try container.decode(
            CapabilityLeaseID.self,
            forKey: .capabilityLeaseID)
        capabilityTaskID =
            try container.decodeIfPresent(
                TaskID.self,
                forKey: .capabilityTaskID)
        workspaceLeaseID =
            try container.decodeIfPresent(
                WorkspaceLeaseID.self,
                forKey: .workspaceLeaseID)
        workspaceRootIdentityFingerprint =
            try container.decodeIfPresent(
                String.self,
                forKey:
                    .workspaceRootIdentityFingerprint)
        workspaceLeasePolicyFingerprint =
            try container.decodeIfPresent(
                String.self,
                forKey:
                    .workspaceLeasePolicyFingerprint)
        attachmentPolicyRevision =
            try container.decode(
                MCPPolicyRevision.self,
                forKey:
                    .attachmentPolicyRevision)
        accountReference =
            try container.decodeIfPresent(
                MCPAccountReference.self,
                forKey: .accountReference)
        environmentReference =
            try container.decode(
                MCPEnvironmentReference.self,
                forKey:
                    .environmentReference)
        launchArtifactFingerprint =
            try container.decodeIfPresent(
                String.self,
                forKey:
                    .launchArtifactFingerprint)
        rootsPolicyRevision = try container.decode(
            MCPPolicyRevision.self,
            forKey: .rootsPolicyRevision)
        networkPolicyRevision =
            try container.decode(
                MCPPolicyRevision.self,
                forKey:
                    .networkPolicyRevision)
        sandboxProfileRevision =
            try container.decode(
                MCPPolicyRevision.self,
                forKey:
                    .sandboxProfileRevision)
        sandboxPolicyFingerprint =
            try container.decodeIfPresent(
                String.self,
                forKey:
                    .sandboxPolicyFingerprint)
        hostPlatform = try container.decode(
            String.self,
            forKey: .hostPlatform)
        fingerprint = try container.decode(
            String.self,
            forKey: .fingerprint)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(
            keyedBy: CodingKeys.self)
        try container.encode(
            schemaVersion,
            forKey: .schemaVersion)
        try container.encode(server, forKey: .server)
        try container.encode(
            transport,
            forKey: .transport)
        try container.encode(
            protocolProfile,
            forKey: .protocolProfile)
        try container.encode(
            maximumProtocolVersion,
            forKey: .maximumProtocolVersion)
        try container.encode(
            sessionID,
            forKey: .sessionID)
        try container.encode(
            agentID,
            forKey: .agentID)
        try container.encode(
            attachmentID,
            forKey: .attachmentID)
        try container.encode(
            capabilityLeaseID,
            forKey: .capabilityLeaseID)
        try container.encodeIfPresent(
            capabilityTaskID,
            forKey: .capabilityTaskID)
        try container.encodeIfPresent(
            workspaceLeaseID,
            forKey: .workspaceLeaseID)
        try container.encodeIfPresent(
            workspaceRootIdentityFingerprint,
            forKey:
                .workspaceRootIdentityFingerprint)
        try container.encodeIfPresent(
            workspaceLeasePolicyFingerprint,
            forKey:
                .workspaceLeasePolicyFingerprint)
        try container.encode(
            attachmentPolicyRevision,
            forKey:
                .attachmentPolicyRevision)
        try container.encodeIfPresent(
            accountReference,
            forKey: .accountReference)
        try container.encode(
            environmentReference,
            forKey:
                .environmentReference)
        try container.encodeIfPresent(
            launchArtifactFingerprint,
            forKey:
                .launchArtifactFingerprint)
        try container.encode(
            rootsPolicyRevision,
            forKey: .rootsPolicyRevision)
        try container.encode(
            networkPolicyRevision,
            forKey: .networkPolicyRevision)
        try container.encode(
            sandboxProfileRevision,
            forKey: .sandboxProfileRevision)
        try container.encodeIfPresent(
            sandboxPolicyFingerprint,
            forKey:
                .sandboxPolicyFingerprint)
        try container.encode(
            hostPlatform,
            forKey: .hostPlatform)
        try container.encode(
            fingerprint,
            forKey: .fingerprint)
    }
}

/// Complete eight-layer routing identity frozen for one provider response.
public struct MCPBindingIdentity: Codable, Equatable, Hashable, Sendable {
    public let protocolProfile: MCPProtocolProfile
    public let maximumProtocolVersion: MCPProtocolVersion
    public let negotiatedProtocolVersion: MCPNegotiatedProtocolVersion
    public let server: MCPServerReference
    public let connectionGeneration: MCPConnectionGeneration
    public let rawCatalogRevision: MCPRawCatalogRevision
    public let agentCatalogViewRevision: MCPAgentCatalogViewRevision
    public let bindingID: MCPBindingID
    public let revocationGeneration: MCPRevocationGeneration

    public init(protocolProfile: MCPProtocolProfile,
                maximumProtocolVersion: MCPProtocolVersion? = nil,
                negotiatedProtocolVersion: MCPNegotiatedProtocolVersion,
                server: MCPServerReference,
                connectionGeneration: MCPConnectionGeneration,
                rawCatalogRevision: MCPRawCatalogRevision,
                agentCatalogViewRevision: MCPAgentCatalogViewRevision,
                bindingID: MCPBindingID,
                revocationGeneration: MCPRevocationGeneration) {
        self.protocolProfile = protocolProfile
        self.maximumProtocolVersion = maximumProtocolVersion ?? protocolProfile.defaultMaximumVersion
        self.negotiatedProtocolVersion = negotiatedProtocolVersion
        self.server = server
        self.connectionGeneration = connectionGeneration
        self.rawCatalogRevision = rawCatalogRevision
        self.agentCatalogViewRevision = agentCatalogViewRevision
        self.bindingID = bindingID
        self.revocationGeneration = revocationGeneration
    }
}
