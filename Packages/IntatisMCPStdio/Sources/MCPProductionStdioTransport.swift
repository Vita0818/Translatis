#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisMCPStdio requires CryptoKit or swift-crypto")
#endif
import Foundation
import IntatisCore
import IntatisMCP
import IntatisProtocol
import IntatisTools
import MCP

/// Exact host-owned workspace and purpose used to mint one managed stdio
/// generation. The context is process-memory-only and cannot be reconstructed
/// from the global catalog.
public struct MCPProductionStdioLaunchContext: Sendable {
    public let purpose: MCPStdioLaunchPurpose
    public let workspaceLease: WorkspaceLease

    public init(
        purpose: MCPStdioLaunchPurpose,
        workspaceLease: WorkspaceLease
    ) {
        self.purpose = purpose
        self.workspaceLease = workspaceLease
    }
}

public typealias MCPProductionStdioLaunchContextProvider =
    @Sendable (
        MCPServerDefinition,
        MCPConnectionReuseIdentity,
        MCPConnectionGeneration
    ) async throws -> MCPProductionStdioLaunchContext

/// Host-specific lease projection used only by a local MCP process.
///
/// Linux bubblewrap cannot safely preserve a mutable workspace while also
/// proving that case-insensitive credential paths remain hidden after the
/// launch-time scan. The MCP process therefore receives a distinct,
/// read-only, whole-workspace lease. The Agent's own lease is not modified.
public enum MCPProductionStdioWorkspaceLease {
    public static func derive(
        from agentLease: WorkspaceLease
    ) throws -> WorkspaceLease {
        guard let rootIdentity = agentLease.rootIdentity,
              rootIdentity.matchesCurrentDirectory(
                rootPath: agentLease.rootPath) else {
            throw MCPManagedPipeError.workspaceIdentityChanged
        }
        #if os(Linux)
        var denied = agentLease.deniedPatterns
        var seen = Set(denied.map { $0.lowercased() })
        for pattern in
                WorkspaceLease.mandatoryTerminalDeniedPatterns {
            if seen.insert(pattern.lowercased()).inserted {
                denied.append(pattern)
            }
        }
        return WorkspaceLease(
            id: WorkspaceLeaseID(
                rawValue: agentLease.id.rawValue + "_mcp_ro"),
            workspaceID: agentLease.workspaceID,
            taskID: agentLease.taskID,
            rootPath: agentLease.rootPath,
            rootIdentity: rootIdentity,
            access: .readOnly,
            allowedPathRules: [PathRule(pattern: ".")],
            deniedPatterns: denied,
            expiresAtTaskCompletion:
                agentLease.expiresAtTaskCompletion)
        #else
        return agentLease
        #endif
    }
}

/// Deterministic, least-authority workspace lease for a user-triggered global
/// stdio Test. Session connections never use this helper; they inject their
/// durable session WorkspaceLease instead.
public struct MCPIsolatedTestWorkspaceSelection:
    Equatable, Hashable, Sendable
{
    public enum Source:
        String, Codable, Equatable, Hashable, Sendable
    {
        case configuredWorkingDirectory =
            "configured_working_directory"
        case launchComponentParent =
            "launch_component_parent"
        case nativeExecutableParent =
            "native_executable_parent"
    }

    public let rootPath: String
    public let rootIdentity: WorkspaceRootIdentity
    public let source: Source
    /// Secret-free binding used by the isolated-Test WorkspaceLease IDs.
    /// It changes if either the launch closure or directory inode changes.
    public let bindingFingerprint: String

    public init(
        rootPath: String,
        rootIdentity: WorkspaceRootIdentity,
        source: Source,
        bindingFingerprint: String
    ) {
        self.rootPath = rootPath
        self.rootIdentity = rootIdentity
        self.source = source
        self.bindingFingerprint = bindingFingerprint
    }
}

public enum MCPIsolatedTestWorkspace {
    /// Selects one explicit, least-authority root without scanning PATH or the
    /// filesystem for likely projects.
    ///
    /// 1. A configured working directory is authoritative.
    /// 2. Otherwise one unambiguous script/package-entrypoint parent is used.
    /// 3. A native executable parent is only the final fallback.
    ///
    /// Multiple script/package components in different directories require an
    /// explicit working directory. Inferring a broad common ancestor could
    /// silently grant substantially more filesystem authority.
    public static func selection(
        for configuration: MCPServerConfiguration
    ) throws -> MCPIsolatedTestWorkspaceSelection? {
        guard case .stdio(let stdio) = configuration.transport else {
            return nil
        }

        let root: URL
        let source: MCPIsolatedTestWorkspaceSelection.Source
        if let workingDirectory = stdio.workingDirectory {
            root = URL(fileURLWithPath: workingDirectory)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            source = .configuredWorkingDirectory
        } else {
            let componentParents = Set<String>(
                stdio.launchArtifact.files.compactMap {
                    guard $0.role == .script
                            || $0.role == .packageEntrypoint
                    else {
                        return nil
                    }
                    return URL(
                        fileURLWithPath: $0.canonicalPath)
                        .deletingLastPathComponent()
                        .resolvingSymlinksInPath()
                        .standardizedFileURL.path
                })
            if componentParents.count == 1,
               let parent = componentParents.first {
                root = URL(fileURLWithPath: parent)
                source = .launchComponentParent
            } else if componentParents.count > 1 {
                throw MCPManagedPipeError
                    .ambiguousTestWorkspaceRoot
            } else {
                root = URL(
                    fileURLWithPath:
                        stdio.executableCanonicalPath)
                    .deletingLastPathComponent()
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                source = .nativeExecutableParent
            }
        }

        guard let identity = WorkspaceRootIdentity.capture(
            rootPath: root.path),
              identity.canonicalPath == root.path else {
            throw MCPManagedPipeError.workspaceUnavailable
        }
        let binding = SHA256.hash(data: Data([
            "mcp-isolated-test-workspace-v2",
            stdio.launchArtifact.fingerprint,
            identity.canonicalPath,
            String(identity.deviceID),
            String(identity.fileID),
            source.rawValue,
        ].joined(separator: "\u{1f}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return MCPIsolatedTestWorkspaceSelection(
            rootPath: root.path,
            rootIdentity: identity,
            source: source,
            bindingFingerprint: binding)
    }

    public static func lease(
        for configuration: MCPServerConfiguration
    ) throws -> WorkspaceLease? {
        guard let selection = try self.selection(
            for: configuration)
        else {
            return nil
        }
        return WorkspaceLease(
            id: WorkspaceLeaseID(
                rawValue:
                    "wlease_mcptest_\(selection.bindingFingerprint.prefix(24))"),
            workspaceID: WorkspaceID(
                rawValue:
                    "ws_mcptest_\(selection.bindingFingerprint.prefix(24))"),
            rootPath: selection.rootPath,
            rootIdentity: selection.rootIdentity,
            access: .readOnly,
            allowedPathRules: [PathRule(pattern: ".")],
            deniedPatterns:
                WorkspaceLease.defaultDeniedPatterns,
            expiresAtTaskCompletion: true)
    }

    public static func context(
        definition: MCPServerDefinition,
        identity: MCPConnectionReuseIdentity
    ) throws -> MCPProductionStdioLaunchContext {
        guard let lease = try self.lease(
            for: definition.configuration),
              identity.authority.workspaceLeaseID == lease.id else {
            throw MCPManagedPipeError.authorizationBindingMismatch
        }
        return MCPProductionStdioLaunchContext(
            purpose: .isolatedTest,
            workspaceLease: lease)
    }
}

public enum MCPStdioEnvironmentResolver {
    public static func resolve(
        _ configuration: MCPStdioServerConfiguration,
        secretResolver: MCPProductionSecretResolver
    ) async throws -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in configuration.environment {
            switch value {
            case .literal(let literal):
                result[name] = literal
            case .secret(let reference):
                result[name] = try decode(
                    await secretResolver(reference))
            }
        }
        for (name, reference) in
                configuration.inheritedEnvironmentReferences {
            result[name] = try decode(
                await secretResolver(reference))
        }
        return result
    }

    private static func decode(_ data: Data) throws -> String {
        guard !data.isEmpty,
              data.count <= MCPSecretStoreLimits.maximumSecretBytes,
              let value = String(data: data, encoding: .utf8),
              !value.contains("\0") else {
            throw MCPProductionRuntimeError.invalidResolvedSecret
        }
        return value
    }
}

/// Direct-distribution macOS/CLI implementation of the transport-builder seam
/// consumed by `MCPProductionConnectionClientFactory`.
///
/// The iOS subset never links this module. Every launch still requires the
/// shared control-plane admission to have begun, an exact live workspace lease,
/// and a fresh ticket from `MCPStdioLaunchTicketIssuer`.
public struct MCPManagedStdioProductionFactory: Sendable {
    private let ticketIssuer: MCPStdioLaunchTicketIssuer
    private let context:
        MCPProductionStdioLaunchContextProvider
    private let limits: MCPManagedPipeLimits
    private let secretRedactionRegistrar:
        (any MCPSecretRedactionRegistering)?

    public init(
        ticketIssuer: MCPStdioLaunchTicketIssuer,
        limits: MCPManagedPipeLimits = .init(),
        secretRedactionRegistrar:
            (any MCPSecretRedactionRegistering)? = nil,
        context:
            @escaping MCPProductionStdioLaunchContextProvider
    ) {
        self.ticketIssuer = ticketIssuer
        self.limits = limits
        self.secretRedactionRegistrar =
            secretRedactionRegistrar
        self.context = context
    }

    public func transportBuilder()
        -> MCPProductionStdioTransportBuilder {
        let ticketIssuer = ticketIssuer
        let context = context
        let limits = limits
        let secretRedactionRegistrar =
            secretRedactionRegistrar
        return { definition, identity, generation in
            guard case .stdio(let configuration) =
                    definition.configuration.transport,
                  identity.transport == .stdio,
                  identity.server == definition.reference,
                  identity.authority.server == definition.reference,
                  identity.authority.launchArtifactFingerprint
                    == configuration.launchArtifact.fingerprint else {
                throw MCPProductionRuntimeError
                    .definitionIdentityMismatch
            }
            let launchContext = try await context(
                definition,
                identity,
                generation)
            let request = try MCPStdioLaunchRequest(
                operationID: .new(),
                purpose: launchContext.purpose,
                authority: identity.authority,
                configuration: configuration,
                workspaceLease: launchContext.workspaceLease)
            let ticket = try await ticketIssuer.issue(for: request)
            if let secretRedactionRegistrar {
                ticket.registerResolvedSecretEnvironmentValues(
                    with: secretRedactionRegistrar)
            }
            let process = try await ManagedPipeProcess.launch(
                ticket: ticket,
                limits: limits)
            if let secretRedactionRegistrar {
                await process
                    .registerGatewayDiagnosticRedactionValues(
                        with: secretRedactionRegistrar)
            }
            return process
        }
    }
}
