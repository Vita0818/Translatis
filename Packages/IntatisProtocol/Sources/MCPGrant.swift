import Foundation
import IntatisCore

public enum MCPApprovalMode: String, Codable, Equatable, Hashable, Sendable {
    case auto
    case prompt
    case writes
    case approve
}

public enum MCPGrantedCapability: String, Codable, Equatable, Hashable, Sendable {
    case tools
    case resources
    case prompts
    case completions
    case logging
    case progress
    case subscriptions
    case roots
    case sampling
    case elicitation
    case tasks
}

/// Stable allow/deny policy for one namespace. `allowList == nil` means the
/// namespace is not narrowed by an allow-list; deny always wins.
public struct MCPNameFilter: Codable, Equatable, Hashable, Sendable {
    public let allowList: [String]?
    public let denyList: [String]

    public init(allowList: [String]? = nil, denyList: [String] = []) {
        self.allowList = allowList.map(Self.normalized)
        self.denyList = Self.normalized(denyList)
    }

    public func allows(_ name: String) -> Bool {
        guard !denyList.contains(name) else { return false }
        return allowList?.contains(name) ?? true
    }

    private static func normalized(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }
}

/// Filter shared by immutable server policy, a session attachment, or an Agent
/// grant. Applying it never mutates the raw server catalog.
public struct MCPCatalogFilter: Codable, Equatable, Hashable, Sendable {
    public let revision: MCPPolicyRevision
    public let tools: MCPNameFilter
    public let resources: MCPNameFilter
    public let prompts: MCPNameFilter
    public let completions: MCPNameFilter

    public init(revision: MCPPolicyRevision,
                tools: MCPNameFilter = .init(),
                resources: MCPNameFilter = .init(),
                prompts: MCPNameFilter = .init(),
                completions: MCPNameFilter = .init()) {
        self.revision = revision
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
        self.completions = completions
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case tools
        case resources
        case prompts
        case completions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(
            MCPPolicyRevision.self,
            forKey: .revision)
        tools = try container.decodeIfPresent(
            MCPNameFilter.self,
            forKey: .tools) ?? .init()
        resources = try container.decodeIfPresent(
            MCPNameFilter.self,
            forKey: .resources) ?? .init()
        prompts = try container.decodeIfPresent(
            MCPNameFilter.self,
            forKey: .prompts) ?? .init()
        completions = try container.decodeIfPresent(
            MCPNameFilter.self,
            forKey: .completions)
            ?? MCPNameFilter(allowList: [])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(revision, forKey: .revision)
        try container.encode(tools, forKey: .tools)
        try container.encode(resources, forKey: .resources)
        try container.encode(prompts, forKey: .prompts)
        try container.encode(completions, forKey: .completions)
    }
}

public struct MCPAttachmentPolicy: Codable, Equatable, Hashable, Sendable {
    public let revision: MCPPolicyRevision
    public let required: Bool
    public let approvalMode: MCPApprovalMode
    public let parallelCalls: Bool
    public let filter: MCPCatalogFilter

    public init(revision: MCPPolicyRevision,
                required: Bool = false,
                approvalMode: MCPApprovalMode = .prompt,
                parallelCalls: Bool = false,
                filter: MCPCatalogFilter) {
        self.revision = revision
        self.required = required
        self.approvalMode = approvalMode
        self.parallelCalls = parallelCalls
        self.filter = filter
    }
}

public enum MCPAttachmentSource: String, Codable, Equatable, Hashable, Sendable {
    case user
    case projectConfiguration = "project_configuration"
    case importedMCPJSON = "imported_mcp_json"
    case importedClaudeJSON = "imported_claude_json"
    case migration
}

/// Durable, secret-free statement that a session uses an immutable server
/// revision. It does not itself create a connection.
public struct MCPServerAttachment: Codable, Equatable, Hashable, Sendable {
    public let attachmentID: MCPAttachmentID
    public let server: MCPServerReference
    public let policy: MCPAttachmentPolicy
    public let source: MCPAttachmentSource
    public let sourceFingerprint: String?

    public init(attachmentID: MCPAttachmentID = .new(),
                server: MCPServerReference,
                policy: MCPAttachmentPolicy,
                source: MCPAttachmentSource,
                sourceFingerprint: String? = nil) {
        self.attachmentID = attachmentID
        self.server = server
        self.policy = policy
        self.source = source
        self.sourceFingerprint = sourceFingerprint
    }
}

/// Exact per-Agent authority over one attached immutable server revision.
/// Absence of a grant is denial. Capabilities and names only narrow the server
/// and attachment policy; they never widen either one.
public struct MCPGrant: Codable, Equatable, Hashable, Sendable {
    public let grantID: MCPGrantID
    public let attachmentID: MCPAttachmentID
    public let server: MCPServerReference
    public let agentID: AgentID
    /// Exact live capability lease that may consume this grant. Legacy grants
    /// decode with nil and are retained for audit only; shipping projection
    /// never matches them to a new lease.
    public let capabilityLeaseID: CapabilityLeaseID?
    /// Optional exact task scope. A nil task is the explicit session-root
    /// scope used by Code/main, not a wildcard for arbitrary Cowork tasks.
    public let taskID: TaskID?
    public let capabilities: [MCPGrantedCapability]
    public let filter: MCPCatalogFilter
    public let approvalModeCeiling: MCPApprovalMode
    public let authorityFingerprint: String
    public let grantFingerprint: String
    public let revocationGeneration: MCPRevocationGeneration
    public let expiresAt: Date?

    public init(grantID: MCPGrantID = .new(),
                attachmentID: MCPAttachmentID,
                server: MCPServerReference,
                agentID: AgentID,
                capabilityLeaseID: CapabilityLeaseID,
                taskID: TaskID? = nil,
                capabilities: [MCPGrantedCapability],
                filter: MCPCatalogFilter,
                approvalModeCeiling: MCPApprovalMode,
                authorityFingerprint: String,
                grantFingerprint: String,
                revocationGeneration: MCPRevocationGeneration,
                expiresAt: Date? = nil) {
        self.grantID = grantID
        self.attachmentID = attachmentID
        self.server = server
        self.agentID = agentID
        self.capabilityLeaseID = capabilityLeaseID
        self.taskID = taskID
        self.capabilities = Array(Set(capabilities)).sorted { $0.rawValue < $1.rawValue }
        self.filter = filter
        self.approvalModeCeiling = approvalModeCeiling
        self.authorityFingerprint = authorityFingerprint
        self.grantFingerprint = grantFingerprint
        self.revocationGeneration = revocationGeneration
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case grantID
        case attachmentID
        case server
        case agentID
        case capabilityLeaseID
        case taskID
        case capabilities
        case filter
        case approvalModeCeiling
        case authorityFingerprint
        case grantFingerprint
        case revocationGeneration
        case expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self)
        grantID = try container.decode(
            MCPGrantID.self,
            forKey: .grantID)
        attachmentID = try container.decode(
            MCPAttachmentID.self,
            forKey: .attachmentID)
        server = try container.decode(
            MCPServerReference.self,
            forKey: .server)
        agentID = try container.decode(
            AgentID.self,
            forKey: .agentID)
        capabilityLeaseID = try container.decodeIfPresent(
            CapabilityLeaseID.self,
            forKey: .capabilityLeaseID)
        taskID = try container.decodeIfPresent(
            TaskID.self,
            forKey: .taskID)
        capabilities = try container.decode(
            [MCPGrantedCapability].self,
            forKey: .capabilities)
        filter = try container.decode(
            MCPCatalogFilter.self,
            forKey: .filter)
        approvalModeCeiling = try container.decode(
            MCPApprovalMode.self,
            forKey: .approvalModeCeiling)
        authorityFingerprint = try container.decode(
            String.self,
            forKey: .authorityFingerprint)
        grantFingerprint = try container.decode(
            String.self,
            forKey: .grantFingerprint)
        revocationGeneration = try container.decode(
            MCPRevocationGeneration.self,
            forKey: .revocationGeneration)
        expiresAt = try container.decodeIfPresent(
            Date.self,
            forKey: .expiresAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(
            keyedBy: CodingKeys.self)
        try container.encode(grantID, forKey: .grantID)
        try container.encode(
            attachmentID,
            forKey: .attachmentID)
        try container.encode(server, forKey: .server)
        try container.encode(agentID, forKey: .agentID)
        try container.encodeIfPresent(
            capabilityLeaseID,
            forKey: .capabilityLeaseID)
        try container.encodeIfPresent(
            taskID,
            forKey: .taskID)
        try container.encode(
            capabilities,
            forKey: .capabilities)
        try container.encode(filter, forKey: .filter)
        try container.encode(
            approvalModeCeiling,
            forKey: .approvalModeCeiling)
        try container.encode(
            authorityFingerprint,
            forKey: .authorityFingerprint)
        try container.encode(
            grantFingerprint,
            forKey: .grantFingerprint)
        try container.encode(
            revocationGeneration,
            forKey: .revocationGeneration)
        try container.encodeIfPresent(
            expiresAt,
            forKey: .expiresAt)
    }

    public func grants(_ capability: MCPGrantedCapability) -> Bool {
        capabilities.contains(capability)
    }

    public func isActive(at date: Date = Date()) -> Bool {
        expiresAt.map { date < $0 } ?? true
    }
}

/// Stable control-plane identities that are never eligible for MCP data-plane
/// grants, including when a forged durable event contains such a grant.
public enum MCPReservedControlPlaneIdentity {
    public static let permissionReviewer =
        AgentID(rawValue: "permission-reviewer")
    public static let goalVerifier =
        AgentID(rawValue: "goal-verifier")

    public static func deniesMCP(
        _ agentID: AgentID
    ) -> Bool {
        agentID == permissionReviewer
            || agentID == goalVerifier
    }
}

public enum MCPConsentKind: String, Codable, Equatable, Hashable, Sendable {
    case launch
    case connect
}

/// Exact durable consent for starting a local artifact or opening a remote
/// connection. Credential values and headers are deliberately absent.
public struct MCPConsent: Codable, Equatable, Hashable, Sendable {
    public let consentID: MCPConsentID
    public let kind: MCPConsentKind
    public let server: MCPServerReference
    public let attachmentID: MCPAttachmentID
    public let authorityFingerprint: String
    public let launchArtifactFingerprint: String?
    public let accountReference: MCPAccountReference?
    public let environmentReference: MCPEnvironmentReference
    public let policyRevision: MCPPolicyRevision

    public init(consentID: MCPConsentID = .new(),
                kind: MCPConsentKind,
                server: MCPServerReference,
                attachmentID: MCPAttachmentID,
                authorityFingerprint: String,
                launchArtifactFingerprint: String? = nil,
                accountReference: MCPAccountReference? = nil,
                environmentReference: MCPEnvironmentReference,
                policyRevision: MCPPolicyRevision) {
        self.consentID = consentID
        self.kind = kind
        self.server = server
        self.attachmentID = attachmentID
        self.authorityFingerprint = authorityFingerprint
        self.launchArtifactFingerprint = launchArtifactFingerprint
        self.accountReference = accountReference
        self.environmentReference = environmentReference
        self.policyRevision = policyRevision
    }
}
