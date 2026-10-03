import Foundation
import IntatisCore
import IntatisMCP
import IntatisProtocol

public enum MCPStdioLaunchPurpose: String, Equatable, Sendable {
    case isolatedTest
    case sessionConnect
}

/// Secret-free request submitted to the host's existing MCP control-plane
/// admission path. Creating this value does not authorize process launch.
public struct MCPStdioLaunchRequest: Sendable {
    public let operationID: MCPControlOperationID
    public let purpose: MCPStdioLaunchPurpose
    public let authority: MCPConnectionAuthority
    public let configuration: MCPStdioServerConfiguration
    public let workspaceLease: WorkspaceLease

    public init(
        operationID: MCPControlOperationID,
        purpose: MCPStdioLaunchPurpose,
        authority: MCPConnectionAuthority,
        configuration: MCPStdioServerConfiguration,
        workspaceLease: WorkspaceLease
    ) throws {
        guard authority.transport == .stdio,
              authority.server.serverID.rawValue.count > 0,
              authority.launchArtifactFingerprint
                == configuration.launchArtifact.fingerprint,
              authority.workspaceLeaseID == workspaceLease.id,
              authority.workspaceRootIdentityFingerprint != nil,
              let rootIdentity = workspaceLease.rootIdentity,
              rootIdentity.matchesCurrentDirectory(
                rootPath: workspaceLease.rootPath) else {
            throw MCPManagedPipeError.authorizationBindingMismatch
        }
        self.operationID = operationID
        self.purpose = purpose
        self.authority = authority
        self.configuration = configuration
        self.workspaceLease = workspaceLease
    }
}

/// Exact proof returned by the host after DeterministicPolicyGate, user/control
/// plane consent, lease validation, and secret resolution have succeeded.
///
/// The values themselves do not mint a launch ticket. Only
/// `MCPStdioLaunchTicketIssuer`, which invokes a host-injected authorization
/// closure, can construct the opaque ticket consumed by ManagedPipeProcess.
public struct MCPStdioHostAuthorization: Sendable {
    public let decisionID: String
    public let operationID: MCPControlOperationID
    public let authorityFingerprint: String
    public let launchArtifactFingerprint: String
    public let workspaceLeaseID: WorkspaceLeaseID
    public let expiresAt: Date
    public let resolvedEnvironment: [String: String]

    public init(
        decisionID: String,
        operationID: MCPControlOperationID,
        authorityFingerprint: String,
        launchArtifactFingerprint: String,
        workspaceLeaseID: WorkspaceLeaseID,
        expiresAt: Date,
        resolvedEnvironment: [String: String]
    ) {
        self.decisionID = decisionID
        self.operationID = operationID
        self.authorityFingerprint = authorityFingerprint
        self.launchArtifactFingerprint = launchArtifactFingerprint
        self.workspaceLeaseID = workspaceLeaseID
        self.expiresAt = expiresAt
        self.resolvedEnvironment = resolvedEnvironment
    }
}

public typealias MCPStdioHostLaunchAuthorizer =
    @Sendable (MCPStdioLaunchRequest) async throws -> MCPStdioHostAuthorization

/// The only public ticket-minting seam. This actor deliberately has no
/// allow/default branch: every ticket requires an injected host decision.
public actor MCPStdioLaunchTicketIssuer {
    private let authorize: MCPStdioHostLaunchAuthorizer
    private let maximumLifetime: TimeInterval

    public init(
        maximumLifetime: TimeInterval = 120,
        authorize: @escaping MCPStdioHostLaunchAuthorizer
    ) {
        self.maximumLifetime = min(max(maximumLifetime, 1), 600)
        self.authorize = authorize
    }

    public func issue(
        for request: MCPStdioLaunchRequest,
        now: Date = Date()
    ) async throws -> MCPAuthorizedStdioLaunchTicket {
        let authorization = try await authorize(request)
        guard !authorization.decisionID.isEmpty,
              authorization.decisionID.utf8.count <= 256,
              authorization.operationID == request.operationID,
              authorization.authorityFingerprint
                == request.authority.fingerprint,
              authorization.launchArtifactFingerprint
                == request.configuration.launchArtifact.fingerprint,
              authorization.workspaceLeaseID == request.workspaceLease.id,
              authorization.expiresAt > now,
              authorization.expiresAt.timeIntervalSince(now)
                <= maximumLifetime else {
            throw MCPManagedPipeError.authorizationBindingMismatch
        }
        try Self.validateResolvedEnvironment(
            authorization.resolvedEnvironment,
            configuration: request.configuration)
        return MCPAuthorizedStdioLaunchTicket(
            request: request,
            authorization: authorization)
    }

    private static func validateResolvedEnvironment(
        _ values: [String: String],
        configuration: MCPStdioServerConfiguration
    ) throws {
        let expectedNames = Set(configuration.environment.keys)
            .union(configuration.inheritedEnvironmentReferences.keys)
        guard Set(values.keys) == expectedNames else {
            throw MCPManagedPipeError.resolvedEnvironmentMismatch
        }
        for (name, configured) in configuration.environment {
            switch configured {
            case .literal(let expected):
                guard values[name] == expected else {
                    throw MCPManagedPipeError.resolvedEnvironmentMismatch
                }
            case .secret:
                guard let value = values[name], !value.isEmpty else {
                    throw MCPManagedPipeError.resolvedEnvironmentMismatch
                }
            }
        }
        for name in configuration.inheritedEnvironmentReferences.keys {
            guard let value = values[name], !value.isEmpty else {
                throw MCPManagedPipeError.resolvedEnvironmentMismatch
            }
        }
        guard values.values.allSatisfy({
            !$0.contains("\0") && $0.utf8.count <= 64 * 1_024
        }) else {
            throw MCPManagedPipeError.resolvedEnvironmentMismatch
        }
    }
}

/// Non-Codable, process-memory-only authorization. Its initializer is internal
/// so code outside IntatisMCPStdio cannot bypass the host issuer.
public struct MCPAuthorizedStdioLaunchTicket: Sendable {
    public let request: MCPStdioLaunchRequest
    let authorization: MCPStdioHostAuthorization

    init(
        request: MCPStdioLaunchRequest,
        authorization: MCPStdioHostAuthorization
    ) {
        self.request = request
        self.authorization = authorization
    }

    var resolvedSecretEnvironmentValues: [String] {
        let secretNames = Set(
            request.configuration.environment.compactMap { name, value in
                if case .secret = value { return name }
                return nil
            }
        ).union(request.configuration.inheritedEnvironmentReferences.keys)
        return secretNames.compactMap { authorization.resolvedEnvironment[$0] }
    }

    func registerResolvedSecretEnvironmentValues(
        with registrar: any MCPSecretRedactionRegistering
    ) {
        for value in resolvedSecretEnvironmentValues {
            registrar.registerMCPSecretRedactionValue(
                Data(value.utf8))
        }
    }
}
