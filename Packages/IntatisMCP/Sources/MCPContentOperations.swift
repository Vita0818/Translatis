import Foundation
import IntatisCore
import IntatisProtocol

public enum MCPContentOperationError:
    Error, Equatable, LocalizedError, Sendable {
    case operationUnsupported
    case capabilityNotNegotiated(MCPGrantedCapability)
    case profileRequiresStandardExtended
    case missingGrant(MCPGrantedCapability)
    case ambiguousServer(String)
    case unknownServer(String)
    case cursorRequiresServer
    case cursorTooLarge
    case resourceNotGranted(String)
    case promptNotGranted(String)
    case completionNotGranted
    case invalidArguments(String)
    case unsafeURI(String)
    case contentTooLarge(maximum: Int)
    case tooManyContents(maximum: Int)
    case malformedBinary
    case staleRequest
    case explicitUserConfirmationRequired
    case artifactSinkRequired
    case authorityVerificationUnavailable
    case invalidExternalOperationAuthority

    public var errorDescription: String? {
        switch self {
        case .operationUnsupported:
            return "this exact MCP client generation does not implement the requested content operation"
        case .capabilityNotNegotiated(let capability):
            return "MCP capability '\(capability.rawValue)' was not negotiated"
        case .profileRequiresStandardExtended:
            return "this MCP operation requires the standard-extended profile"
        case .missingGrant(let capability):
            return "the Agent has no active \(capability.rawValue) MCP grant"
        case .ambiguousServer(let server):
            return "MCP server alias '\(server)' is ambiguous"
        case .unknownServer(let server):
            return "MCP server alias '\(server)' is not visible"
        case .cursorRequiresServer:
            return "an MCP cursor may only be used with its explicit server"
        case .cursorTooLarge:
            return "the MCP cursor exceeds its bounded size"
        case .resourceNotGranted(let uri):
            return "MCP resource '\(uri)' is absent from the frozen granted catalog"
        case .promptNotGranted(let prompt):
            return "MCP prompt '\(prompt)' is absent from the frozen granted catalog"
        case .completionNotGranted:
            return "MCP completion is not granted for this reference"
        case .invalidArguments(let reason):
            return "MCP content operation arguments are invalid: \(reason)"
        case .unsafeURI(let value):
            return "MCP resource URI is outside the allowed authority: \(value.prefix(128))"
        case .contentTooLarge(let maximum):
            return "MCP content exceeds \(maximum) bytes"
        case .tooManyContents(let maximum):
            return "MCP resource contains more than \(maximum) content blocks"
        case .malformedBinary:
            return "MCP resource contains malformed base64"
        case .staleRequest:
            return "a newer MCP content request superseded this request"
        case .explicitUserConfirmationRequired:
            return "server-provided prompt insertion requires explicit user confirmation"
        case .artifactSinkRequired:
            return "binary or oversized MCP resource content requires an ArtifactStore sink"
        case .authorityVerificationUnavailable:
            return "the MCP operation has no durable exact-authority verifier"
        case .invalidExternalOperationAuthority:
            return "the MCP operation does not match the exact current grant, task, workspace, sandbox, or connection authority"
        }
    }
}

/// Every conversation-facing MCP network request is checked against durable
/// authority immediately before dispatch and again before its result can be
/// published. The same immutable request value is used for both fences.
public enum MCPExternalOperationVerificationPhase:
    String, Codable, Equatable, Hashable, Sendable {
    case beforeRequest = "before_request"
    case beforePublication = "before_publication"
}

public enum MCPExternalOperationKind:
    String, Codable, Equatable, Hashable, Sendable {
    case listResources = "resources_list"
    case listResourceTemplates = "resource_templates_list"
    case readResource = "resource_read"
    case getPrompt = "prompt_get"
    case useServerInstructions =
        "server_instructions_use"
    case completePrompt = "completion_prompt"
    case completeResource = "completion_resource"
    case subscribeResource = "resource_subscribe"
    case unsubscribeResource = "resource_unsubscribe"
    case publishSubscribedResourceUpdate =
        "resource_update_publish"
    case listRemoteTasks = "remote_tasks_list"
    case refreshRemoteTask = "remote_task_refresh"
    case cancelRemoteTask = "remote_task_cancel"
    case readRemoteTaskResult = "remote_task_result"

    public var requiredCapabilities: Set<MCPGrantedCapability> {
        switch self {
        case .listResources, .listResourceTemplates, .readResource:
            return [.resources]
        case .getPrompt:
            return [.prompts]
        case .useServerInstructions:
            // Instructions are not a protocol capability. Their explicit
            // one-shot use still requires the exact active attachment grant,
            // consent, task, workspace, sandbox, and connection generation.
            return []
        case .completePrompt:
            return [.completions, .prompts]
        case .completeResource:
            return [.completions, .resources]
        case .subscribeResource, .unsubscribeResource,
             .publishSubscribedResourceUpdate:
            return [.resources, .subscriptions]
        case .listRemoteTasks, .refreshRemoteTask,
             .cancelRemoteTask, .readRemoteTaskResult:
            return [.tasks]
        }
    }
}

public struct MCPExternalOperationAuthorityRequest: Sendable {
    public let operationID: String
    public let operation: MCPExternalOperationKind
    public let identity: MCPConnectionReuseIdentity
    public let binding: MCPBindingIdentity
    public let grant: MCPGrant
    public let workspaceLease: WorkspaceLease?
    /// A secret-safe digest of the prompt name, URI, cursor, or remote task
    /// identity. Raw request values never enter authority diagnostics.
    public let targetFingerprint: String

    public init(
        operationID: String = UUID().uuidString.lowercased(),
        operation: MCPExternalOperationKind,
        connection: MCPConnectionSnapshot,
        grant: MCPGrant,
        workspaceLease: WorkspaceLease?,
        target: String
    ) throws {
        let identity = connection.reuseIdentity
        let authority = identity.authority
        let binding = connection.bindingIdentity
        let workspacePolicyFingerprint =
            MCPConnectionIdentityBuilder
                .workspaceLeasePolicyFingerprint(
                    workspaceLease)
        guard !operationID.isEmpty,
              operationID.utf8.count <= 512,
              authority.hasCurrentExecutionAuthority,
              binding.server == identity.server,
              binding.protocolProfile
                == authority.protocolProfile,
              binding.maximumProtocolVersion
                == authority.maximumProtocolVersion,
              grant.server == identity.server,
              grant.attachmentID
                == authority.attachmentID,
              grant.agentID == authority.agentID,
              grant.capabilityLeaseID
                == authority.capabilityLeaseID,
              grant.taskID == authority.capabilityTaskID,
              grant.authorityFingerprint
                == authority.fingerprint,
              grant.revocationGeneration
                == binding.revocationGeneration,
              grant.isActive(),
              operation.requiredCapabilities
                .allSatisfy(grant.grants),
              authority.workspaceLeaseID
                == workspaceLease?.id,
              authority.workspaceLeasePolicyFingerprint
                == workspacePolicyFingerprint,
              workspaceLease?.taskID
                == authority.capabilityTaskID
                    || workspaceLease == nil else {
            throw MCPContentOperationError
                .invalidExternalOperationAuthority
        }
        self.operationID = operationID
        self.operation = operation
        self.identity = identity
        self.binding = binding
        self.grant = grant
        self.workspaceLease = workspaceLease
        self.targetFingerprint =
            MCPRawCatalogHash.sha256(
                Data(target.utf8))
    }
}

public protocol MCPExternalOperationAuthorityVerifier:
    Sendable
{
    func verifyMCPExternalOperation(
        _ request: MCPExternalOperationAuthorityRequest,
        phase: MCPExternalOperationVerificationPhase
    ) async throws
}

/// An immutable double-fence passed all the way to the managed connection.
/// Omitting a verifier is deliberately not representable.
public struct MCPExternalOperationFence: Sendable {
    public let request:
        MCPExternalOperationAuthorityRequest
    private let verifier:
        any MCPExternalOperationAuthorityVerifier

    public init(
        request:
            MCPExternalOperationAuthorityRequest,
        verifier:
            any MCPExternalOperationAuthorityVerifier
    ) {
        self.request = request
        self.verifier = verifier
    }

    public func verifyBeforeRequest() async throws {
        try await verifier.verifyMCPExternalOperation(
            request,
            phase: .beforeRequest)
    }

    public func verifyBeforePublication() async throws {
        try await verifier.verifyMCPExternalOperation(
            request,
            phase: .beforePublication)
    }

    func validateExactRoute(
        identity: MCPConnectionReuseIdentity,
        binding: MCPBindingIdentity
    ) throws {
        guard request.identity == identity,
              request.binding == binding else {
            throw MCPConnectionError.authorityMismatch
        }
    }
}

public struct MCPRawResourceContent: Codable, Equatable, Sendable {
    public let uri: String
    public let mimeType: String?
    public let text: String?
    public let base64: String?

    public init(
        uri: String,
        mimeType: String? = nil,
        text: String? = nil,
        base64: String? = nil
    ) throws {
        try MCPRawCatalogValidation.validateURI(uri)
        guard (text == nil) != (base64 == nil) else {
            throw MCPContentOperationError.invalidArguments(
                "resource content must contain exactly one of text or blob")
        }
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
        self.base64 = base64
    }
}

public struct MCPRawResourceReadResult: Codable, Equatable, Sendable {
    public let contents: [MCPRawResourceContent]

    public init(contents: [MCPRawResourceContent]) {
        self.contents = contents
    }
}

public struct MCPRawPromptGetResult: Codable, Equatable, Sendable {
    public let description: String?
    /// Exact SDK-independent prompt messages. The prompt broker sanitizes all
    /// string leaves and never turns these values into system/developer roles.
    public let messages: [JSONValue]

    public init(
        description: String? = nil,
        messages: [JSONValue]
    ) {
        self.description = description
        self.messages = messages
    }
}

public enum MCPCompletionReference:
    Codable, Equatable, Hashable, Sendable {
    case prompt(name: String)
    case resource(uriTemplate: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum Kind: String, Codable {
        case prompt
        case resource
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .prompt:
            self = .prompt(
                name: try container.decode(String.self, forKey: .value))
        case .resource:
            self = .resource(
                uriTemplate: try container.decode(
                    String.self,
                    forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .prompt(let name):
            try container.encode(Kind.prompt, forKey: .type)
            try container.encode(name, forKey: .value)
        case .resource(let uriTemplate):
            try container.encode(Kind.resource, forKey: .type)
            try container.encode(uriTemplate, forKey: .value)
        }
    }
}

public struct MCPCompletionResult: Codable, Equatable, Sendable {
    public let values: [String]
    public let total: Int?
    public let hasMore: Bool?

    public init(
        values: [String],
        total: Int? = nil,
        hasMore: Bool? = nil
    ) {
        self.values = values
        self.total = total
        self.hasMore = hasMore
    }
}

public enum MCPCatalogChangeKind:
    String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case tools
    case resources
    case prompts
}

public protocol MCPCatalogNotificationSink: Sendable {
    func catalogListChanged(
        server: MCPServerReference,
        generation: MCPConnectionGeneration,
        kind: MCPCatalogChangeKind
    ) async
    func subscribedResourceUpdated(
        server: MCPServerReference,
        generation: MCPConnectionGeneration,
        uri: String
    ) async
}

public extension MCPCatalogNotificationSink {
    func subscribedResourceUpdated(
        server _: MCPServerReference,
        generation _: MCPConnectionGeneration,
        uri _: String
    ) async {}
}

public struct MCPAuthorizedRoot: Codable, Equatable, Hashable, Sendable {
    public let uri: String
    public let name: String?
    public let workspaceLeaseID: WorkspaceLeaseID
    public let rootIdentityFingerprint: String
    public let access: WorkspaceAccess

    public init(
        uri: String,
        name: String?,
        workspaceLeaseID: WorkspaceLeaseID,
        rootIdentityFingerprint: String,
        access: WorkspaceAccess
    ) throws {
        guard let url = URL(string: uri),
              url.isFileURL,
              url.path.hasPrefix("/"),
              url.query == nil,
              url.fragment == nil,
              !rootIdentityFingerprint.isEmpty else {
            throw MCPContentOperationError.unsafeURI(uri)
        }
        self.uri = url.standardizedFileURL.absoluteString
        self.name = name
        self.workspaceLeaseID = workspaceLeaseID
        self.rootIdentityFingerprint = rootIdentityFingerprint
        self.access = access
    }
}

public struct MCPAuthorizedRootsSnapshot:
    Codable, Equatable, Hashable, Sendable {
    public let policyRevision: MCPPolicyRevision
    public let revocationGeneration: MCPRevocationGeneration
    public let roots: [MCPAuthorizedRoot]

    public init(
        policyRevision: MCPPolicyRevision,
        revocationGeneration: MCPRevocationGeneration,
        roots: [MCPAuthorizedRoot]
    ) {
        self.policyRevision = policyRevision
        self.revocationGeneration = revocationGeneration
        self.roots = roots.sorted { $0.uri < $1.uri }
    }

    public static func exact(
        workspaceLease: WorkspaceLease,
        authority: MCPConnectionAuthority,
        revocationGeneration: MCPRevocationGeneration,
        displayName: String? = nil
    ) throws -> MCPAuthorizedRootsSnapshot {
        guard authority.protocolProfile == .standardExtended,
              authority.workspaceLeaseID == workspaceLease.id,
              let identity = workspaceLease.rootIdentity,
              identity.matchesCurrentDirectory(
                rootPath: workspaceLease.rootPath) else {
            throw MCPContentOperationError.unsafeURI(
                workspaceLease.rootPath)
        }
        let fingerprint = MCPRawCatalogHash.sha256(
            Data([
                identity.canonicalPath,
                String(identity.deviceID),
                String(identity.fileID),
            ].joined(separator: "\u{1f}").utf8))
        guard authority.workspaceRootIdentityFingerprint == fingerprint else {
            throw MCPContentOperationError.unsafeURI(
                workspaceLease.rootPath)
        }
        let rootURL = URL(fileURLWithPath: identity.canonicalPath)
            .standardizedFileURL
        let root = try MCPAuthorizedRoot(
            uri: rootURL.absoluteString,
            name: displayName,
            workspaceLeaseID: workspaceLease.id,
            rootIdentityFingerprint: fingerprint,
            access: workspaceLease.access)
        return MCPAuthorizedRootsSnapshot(
            policyRevision: authority.rootsPolicyRevision,
            revocationGeneration: revocationGeneration,
            roots: [root])
    }

    public static func empty(
        policyRevision: MCPPolicyRevision,
        revocationGeneration: MCPRevocationGeneration
    ) -> MCPAuthorizedRootsSnapshot {
        .init(
            policyRevision: policyRevision,
            revocationGeneration: revocationGeneration,
            roots: [])
    }
}
