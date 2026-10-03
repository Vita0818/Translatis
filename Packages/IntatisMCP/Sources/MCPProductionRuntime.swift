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
import Logging
import MCP

// MARK: - Shipping host/platform boundary

/// The concrete Intatis product surface that owns an MCP runtime.
///
/// This is intentionally independent from `PlatformProfile`: the latter
/// describes the broader Agent product, while this value freezes the MCP
/// transport and credential boundary used to create one client generation.
public enum MCPProductHostProfile:
    String, Codable, Equatable, Hashable, Sendable {
    case macDeveloperID = "mac_developer_id"
    case macAppStore = "mac_app_store"
    case macCLI = "mac_cli"
    case linuxCLI = "linux_cli"

    public var supportsStdio: Bool {
        switch self {
        case .macDeveloperID, .macCLI, .linuxCLI:
            return true
        case .macAppStore:
            return false
        }
    }

    public var supportsStreamableHTTP: Bool { true }

    public var requiredSecretStorageClass: MCPSecretStorageClass {
        switch self {
        case .macDeveloperID, .macAppStore:
            return .macOSKeychain
        case .macCLI, .linuxCLI:
            return .encryptedCLIStore
        }
    }

    public func permits(_ transport: MCPTransportKind) -> Bool {
        switch transport {
        case .stdio:
            return supportsStdio
        case .streamableHTTP:
            return supportsStreamableHTTP
        }
    }
}

public enum MCPProductionRuntimeError:
    Error, Equatable, LocalizedError, Sendable {
    case definitionMissing(MCPServerReference)
    case definitionIdentityMismatch
    case transportUnavailable(
        host: MCPProductHostProfile,
        transport: MCPTransportKind
    )
    case stdioFactoryUnavailable
    case secretResolverUnavailable
    case secretStorageClassMismatch(
        expected: MCPSecretStorageClass,
        actual: MCPSecretStorageClass
    )
    case invalidResolvedSecret
    case oauthAuthorizationUnavailable
    case remoteTaskServicesUnavailable
    case lazyTransportNotConnected
    case lazyTransportAlreadyConnected
    case lazyTransportClosed
    case lazyTransportNegotiatedProtocolVersionChanged

    public var errorDescription: String? {
        switch self {
        case .definitionMissing:
            return "The exact MCP server revision is unavailable."
        case .definitionIdentityMismatch:
            return "The MCP server definition no longer matches the frozen connection identity."
        case .transportUnavailable(let host, let transport):
            return "MCP transport \(transport.rawValue) is unavailable for \(host.rawValue)."
        case .stdioFactoryUnavailable:
            return "This host has no managed stdio MCP transport factory."
        case .secretResolverUnavailable:
            return "This MCP connection requires a secure credential resolver."
        case .secretStorageClassMismatch(let expected, let actual):
            return "MCP credential storage \(actual.rawValue) is not valid for this host; expected \(expected.rawValue)."
        case .invalidResolvedSecret:
            return "The securely resolved MCP credential is invalid."
        case .oauthAuthorizationUnavailable:
            return "OAuth is configured but no exact OAuth authorization provider is available."
        case .remoteTaskServicesUnavailable:
            return "The standard-extended MCP profile requires durable remote task services."
        case .lazyTransportNotConnected:
            return "The MCP transport has not been connected."
        case .lazyTransportAlreadyConnected:
            return "The MCP transport generation is already connected."
        case .lazyTransportClosed:
            return "The MCP transport generation is closed."
        case .lazyTransportNegotiatedProtocolVersionChanged:
            return "The MCP transport generation cannot change its negotiated protocol version."
        }
    }
}

/// Resolves an opaque reference at the last responsible moment. Implementations
/// must use Keychain for App hosts and the encrypted owner-only store for CLI.
public typealias MCPProductionSecretResolver =
    @Sendable (MCPSecretReference) async throws -> Data

/// Builds the DeveloperID/CLI-only managed stdio transport. The closure is
/// absent from the App Store binary, so remote-only is a linkage property and
/// not merely a disabled button.
public typealias MCPProductionStdioTransportBuilder =
    @Sendable (
        MCPServerDefinition,
        MCPConnectionReuseIdentity,
        MCPConnectionGeneration
    ) async throws -> any Transport

/// Supplies an OAuth provider bound to the exact resource/account/generation.
public typealias MCPProductionOAuthProviderBuilder =
    @Sendable (
        MCPServerDefinition,
        MCPConnectionReuseIdentity,
        MCPConnectionGeneration
    ) async throws -> any MCPHTTPAuthorizationProviding

/// Callback/catalog services are frozen before initialize, so the client never
/// advertises a handler that was installed after capability negotiation.
public struct MCPProductionConnectionServices: Sendable {
    public let authorizedRoots: MCPAuthorizedRootsSnapshot?
    public let catalogNotificationSink:
        (any MCPCatalogNotificationSink)?
    public let callbackCapabilities: MCPClientCallbackCapabilities
    public let inboundServicesFactory:
        (any MCPClientInboundServicesFactory)?
    public let remoteTaskStatusSink: (any MCPRemoteTaskStatusSink)?
    public let remoteTaskServices: MCPProductionRemoteTaskServices?
    public let inboundNotificationSink:
        (any MCPInboundNotificationSink)?
    public let inboundNotificationPolicy:
        MCPInboundNotificationPolicy

    public init(
        authorizedRoots: MCPAuthorizedRootsSnapshot? = nil,
        catalogNotificationSink:
            (any MCPCatalogNotificationSink)? = nil,
        callbackCapabilities: MCPClientCallbackCapabilities = .none,
        inboundServicesFactory:
            (any MCPClientInboundServicesFactory)? = nil,
        remoteTaskStatusSink: (any MCPRemoteTaskStatusSink)? = nil,
        remoteTaskServices: MCPProductionRemoteTaskServices? = nil,
        inboundNotificationSink:
            (any MCPInboundNotificationSink)? = nil,
        inboundNotificationPolicy:
            MCPInboundNotificationPolicy = .init()
    ) {
        self.authorizedRoots = authorizedRoots
        self.catalogNotificationSink = catalogNotificationSink
        self.callbackCapabilities = callbackCapabilities
        self.inboundServicesFactory = inboundServicesFactory
        self.remoteTaskStatusSink = remoteTaskStatusSink
        self.remoteTaskServices = remoteTaskServices
        self.inboundNotificationSink =
            inboundNotificationSink
        self.inboundNotificationPolicy =
            inboundNotificationPolicy
    }

    public static let none = MCPProductionConnectionServices()
}

/// Durable host services required by one exact standard-extended connection
/// generation. The EventLog adapter and protected payload store remain
/// host-owned; the production factory owns and scopes the state machine.
public struct MCPProductionRemoteTaskServices: Sendable {
    public let events: any MCPBrokerEventSink
    public let payloadStore: any MCPBrokerPayloadStore
    public let policy: MCPTaskRuntimePolicy

    public init(
        events: any MCPBrokerEventSink,
        payloadStore: any MCPBrokerPayloadStore,
        policy: MCPTaskRuntimePolicy = .init()
    ) {
        self.events = events
        self.payloadStore = payloadStore
        self.policy = policy
    }
}

public typealias MCPProductionConnectionServicesProvider =
    @Sendable (
        MCPServerDefinition,
        MCPConnectionReuseIdentity,
        MCPConnectionGeneration
    ) throws -> MCPProductionConnectionServices

public typealias MCPProductionConfigurationTestWorkspaceProvider =
    @Sendable (
        MCPServerConfiguration
    ) async throws -> WorkspaceLease?

/// Runs the exact staged configuration in a non-session Test generation.
/// Test performs real initialize and full initial discovery, then drains the
/// generation. It neither publishes a catalog revision nor creates a reusable
/// session connection; only a matching successful result can become a proof.
public struct MCPProductionConfigurationTester: Sendable {
    private let hostProfile: MCPProductHostProfile
    private let clientVersion: String
    private let resolveSecret: MCPProductionSecretResolver?
    private let secretRedactionRegistrar:
        (any MCPSecretRedactionRegistering)?
    private let outputSanitizer:
        any MCPToolResultSanitizer
    private let buildStdio: MCPProductionStdioTransportBuilder?
    private let buildOAuth: MCPProductionOAuthProviderBuilder?
    private let services: MCPProductionConnectionServicesProvider
    private let testWorkspace:
        MCPProductionConfigurationTestWorkspaceProvider

    public init(
        hostProfile: MCPProductHostProfile,
        clientVersion: String,
        resolveSecret: MCPProductionSecretResolver? = nil,
        secretRedactionRegistrar:
            (any MCPSecretRedactionRegistering)? = nil,
        outputSanitizer:
            any MCPToolResultSanitizer =
                MCPConservativeToolResultSanitizer(),
        buildStdio: MCPProductionStdioTransportBuilder? = nil,
        buildOAuth: MCPProductionOAuthProviderBuilder? = nil,
        services:
            @escaping MCPProductionConnectionServicesProvider = {
                _, _, _ in .none
            },
        testWorkspace:
            @escaping
            MCPProductionConfigurationTestWorkspaceProvider = {
                _ in nil
            }
    ) {
        self.hostProfile = hostProfile
        self.clientVersion = clientVersion
        self.resolveSecret = resolveSecret
        self.secretRedactionRegistrar =
            secretRedactionRegistrar
        self.outputSanitizer = outputSanitizer
        self.buildStdio = buildStdio
        self.buildOAuth = buildOAuth
        self.services = services
        self.testWorkspace = testWorkspace
    }

    public func run(
        _ prepared: MCPPreparedServerConfiguration
    ) async throws -> MCPConfigurationTestResult {
        let staging = prepared.staging
        let definition = try prepared.definition.validated()
        guard definition.reference
                == prepared.expectedServerReference,
              definition.definitionFingerprint
                == prepared.challenge
                    .configurationFingerprint
        else {
            throw MCPServerCatalogError.preparedPlanMismatch
        }
        let catalog = try MCPServerCatalog.isolatedTest(
            definition: definition)
        let factory = try MCPProductionConnectionClientFactory(
            catalog: catalog,
            hostProfile: hostProfile,
            clientVersion: clientVersion,
            resolveSecret: resolveSecret,
            secretRedactionRegistrar:
                secretRedactionRegistrar,
            outputSanitizer:
                outputSanitizer,
            buildStdio: buildStdio,
            buildOAuth: buildOAuth,
            services: services)
        let policyRevision = MCPPolicyRevision(
            rawValue: "mcppolicy_isolated_test")
        let filter = MCPCatalogFilter(
            revision: policyRevision)
        let attachment = MCPServerAttachment(
            server: definition.reference,
            policy: MCPAttachmentPolicy(
                revision: policyRevision,
                required: true,
                approvalMode: .prompt,
                parallelCalls: false,
                filter: filter),
            source: .user)
        let workspaceLease = try await testWorkspace(
            staging.configuration)
        let runtimeFingerprint =
            MCPConfigurationCanonical.sha256(
                Data("isolated-mcp-test-runtime-v1".utf8))
        let workspacePolicyFingerprint =
            MCPConnectionIdentityBuilder
                .workspaceLeasePolicyFingerprint(
                    workspaceLease)
        let sandboxPolicyFingerprint =
            MCPConnectionIdentityBuilder
                .sandboxPolicyFingerprint(
                    hostProfile: hostProfile,
                    transport:
                        definition.configuration
                            .transport.kind,
                    sandboxProfileRevision:
                        policyRevision,
                    networkPolicyRevision:
                        policyRevision,
                    workspaceLeasePolicyFingerprint:
                        workspacePolicyFingerprint)
        let requirement = try MCPConnectionIdentityBuilder.build(
            definition: definition,
            inputs: MCPConnectionAuthorityInputs(
                sessionID: SessionID(
                    rawValue: "mcp_isolated_test"),
                agentID: AgentID(
                    rawValue: "mcp_test"),
                attachment: attachment,
                capabilityLeaseID: CapabilityLeaseID(
                    rawValue: "clease_mcp_isolated_test"),
                capabilityTaskID: nil,
                workspaceLeaseID: workspaceLease?.id,
                workspaceRootIdentityFingerprint:
                    workspaceLease?.rootIdentity.map {
                        MCPConfigurationCanonical.sha256(Data(
                            "\($0.canonicalPath)|\($0.deviceID)|\($0.fileID)"
                                .utf8))
                    },
                workspaceLeasePolicyFingerprint:
                    workspacePolicyFingerprint,
                accountReference:
                    definition.configuration.transport
                        .oauthAccountReference,
                rootsPolicyRevision: policyRevision,
                networkPolicyRevision: policyRevision,
                sandboxProfileRevision: policyRevision,
                sandboxPolicyFingerprint:
                    sandboxPolicyFingerprint,
                revocationGeneration:
                    MCPRevocationGeneration(
                        rawValue: "mcprevocation_isolated_test"),
                hostProfile: hostProfile,
                runtimeIdentityFingerprint:
                    runtimeFingerprint))
        let generation = MCPConnectionGeneration.new()
        let client = try factory.makeClient(
            identity: requirement.identity,
            generation: generation)
        let terminal: MCPConfigurationTestTerminal
        let reason: String
        do {
            _ = try await client.startup(
                profile:
                    staging.configuration.protocolProfile,
                maximumProtocolVersion:
                    staging.configuration
                        .maximumProtocolVersion)
            terminal = .succeeded
            reason = "initialize_and_discovery_succeeded"
        } catch is CancellationError {
            terminal = .cancelled
            reason = "test_cancelled"
        } catch MCPClientSessionError.initializeTimedOut(_) {
            terminal = .timedOut
            reason = "startup_timed_out"
        } catch {
            terminal = .failed
            reason = "initialize_or_discovery_failed"
        }
        await client.shutdownAndDrain(
            reason: "Isolated MCP configuration Test complete")
        return try MCPConfigurationTestResult(
            challenge: staging.challenge,
            terminal: terminal,
            testedIdentityFingerprint:
                staging.expectedTestedIdentityFingerprint,
            sanitizedReasonCode: reason)
    }
}

// MARK: - Lazy transport construction

/// A transport generation whose security-sensitive material is resolved only
/// after control-plane admission has succeeded and SDK `connect()` begins.
///
/// The connection factory remains synchronous as required by `MCPRuntime`, but
/// neither Keychain/encrypted-store access, local process launch, nor network
/// I/O occurs during `makeClient`.
public actor MCPLazyClientTransport:
    NegotiatedProtocolVersionTransport
{
    private enum NegotiatedVersionForwardingState {
        case none
        case pending(String)
        case forwarding(String)
        case applied(String)
        case failed(String, any Error)
    }

    public nonisolated let logger: Logger

    private let build:
        @Sendable () async throws -> any Transport
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation:
        AsyncThrowingStream<Data, Error>.Continuation
    private var transport: (any Transport)?
    private var receiveTask: Task<Void, Never>?
    private var connecting = false
    private var closed = false
    private var negotiatedVersionForwarding:
        NegotiatedVersionForwardingState = .none
    private var negotiatedVersionForwardingWaiters:
        [CheckedContinuation<Void, any Error>] = []

    public init(
        label: String,
        build: @escaping @Sendable () async throws -> any Transport
    ) {
        logger = Logger(
            label: label,
            factory: { _ in SwiftLogNoOpLogHandler() })
        self.build = build
        var continuation:
            AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    public func connect() async throws {
        guard !closed else {
            throw MCPProductionRuntimeError.lazyTransportClosed
        }
        guard transport == nil, !connecting else {
            throw MCPProductionRuntimeError.lazyTransportAlreadyConnected
        }
        connecting = true
        do {
            let created = try await build()
            try Task.checkCancellation()
            try await created.connect()
            guard !closed else {
                await created.disconnect()
                throw MCPProductionRuntimeError.lazyTransportClosed
            }
            transport = created
            connecting = false
            let continuation = continuation
            receiveTask = Task {
                do {
                    for try await frame in await created.receive() {
                        try Task.checkCancellation()
                        continuation.yield(frame)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        } catch {
            connecting = false
            continuation.finish(throwing: error)
            throw error
        }
    }

    public func send(_ data: Data) async throws {
        guard !closed else {
            throw MCPProductionRuntimeError.lazyTransportClosed
        }
        guard let transport else {
            throw MCPProductionRuntimeError.lazyTransportNotConnected
        }
        try await forwardNegotiatedVersionIfNeeded(
            to: transport)
        guard !closed else {
            throw MCPProductionRuntimeError.lazyTransportClosed
        }
        try await transport.send(data)
    }

    /// The SDK negotiates against this lazy boundary, while Streamable HTTP's
    /// session/header state lives in the concrete transport built at connect.
    /// Cache the selected version synchronously, then make the immediately
    /// following send wait until the exact concrete transport has accepted it.
    /// This preserves `initialize response -> version update ->
    /// notifications/initialized` even across the lazy actor boundary.
    public func updateNegotiatedProtocolVersion(
        _ value: String
    ) throws {
        guard !closed else {
            throw MCPProductionRuntimeError.lazyTransportClosed
        }
        guard transport != nil else {
            throw MCPProductionRuntimeError.lazyTransportNotConnected
        }
        switch negotiatedVersionForwarding {
        case .none:
            negotiatedVersionForwarding = .pending(value)
        case .pending(let existing),
                .forwarding(let existing),
                .applied(let existing),
                .failed(let existing, _):
            guard existing == value else {
                throw MCPProductionRuntimeError
                    .lazyTransportNegotiatedProtocolVersionChanged
            }
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    public func disconnect() async {
        guard !closed else { return }
        closed = true
        receiveTask?.cancel()
        if let transport {
            await transport.disconnect()
        }
        _ = await receiveTask?.result
        receiveTask = nil
        transport = nil
        continuation.finish()
    }

    private func forwardNegotiatedVersionIfNeeded(
        to transport: any Transport
    ) async throws {
        switch negotiatedVersionForwarding {
        case .none, .applied:
            return
        case .failed(_, let error):
            throw error
        case .forwarding:
            try await withCheckedThrowingContinuation {
                continuation in
                negotiatedVersionForwardingWaiters
                    .append(continuation)
            }
        case .pending(let value):
            guard let versioned =
                    transport as?
                        any NegotiatedProtocolVersionTransport
            else {
                negotiatedVersionForwarding =
                    .applied(value)
                return
            }
            negotiatedVersionForwarding =
                .forwarding(value)
            do {
                try await versioned
                    .updateNegotiatedProtocolVersion(
                        value)
                negotiatedVersionForwarding =
                    .applied(value)
                settleNegotiatedVersionForwardingWaiters(
                    with: .success(()))
            } catch {
                negotiatedVersionForwarding =
                    .failed(value, error)
                settleNegotiatedVersionForwardingWaiters(
                    with: .failure(error))
                throw error
            }
        }
    }

    private func settleNegotiatedVersionForwardingWaiters(
        with result: Result<Void, any Error>
    ) {
        let waiters =
            negotiatedVersionForwardingWaiters
        negotiatedVersionForwardingWaiters
            .removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }
}

// MARK: - Exact production client factory

/// Concrete transport/client factory shared by the macOS App and CLI hosts.
///
/// The factory is built from one immutable global-catalog snapshot. A later
/// catalog publication creates a new factory/runtime view; it cannot mutate a
/// client or binding already retained by an invocation.
public struct MCPProductionConnectionClientFactory:
    MCPConnectionClientFactory, Sendable {
    public let hostProfile: MCPProductHostProfile
    public let catalogGeneration: UInt64

    private let definitions:
        [MCPServerReference: MCPServerDefinition]
    private let resolveSecret: MCPProductionSecretResolver?
    private let secretRedactionRegistrar:
        (any MCPSecretRedactionRegistering)?
    private let outputSanitizer:
        any MCPToolResultSanitizer
    private let buildStdio: MCPProductionStdioTransportBuilder?
    private let buildOAuth: MCPProductionOAuthProviderBuilder?
    private let services: MCPProductionConnectionServicesProvider
    private let clientVersion: String
    private let stdioToolCatalogCache:
        MCPStdioToolCatalogCache

    public init(
        catalog: MCPServerCatalog,
        hostProfile: MCPProductHostProfile,
        clientVersion: String,
        resolveSecret: MCPProductionSecretResolver? = nil,
        secretRedactionRegistrar:
            (any MCPSecretRedactionRegistering)? = nil,
        outputSanitizer:
            any MCPToolResultSanitizer =
                MCPConservativeToolResultSanitizer(),
        buildStdio: MCPProductionStdioTransportBuilder? = nil,
        buildOAuth: MCPProductionOAuthProviderBuilder? = nil,
        stdioToolCatalogCache:
            MCPStdioToolCatalogCache = .shared,
        services:
            @escaping MCPProductionConnectionServicesProvider = {
                _, _, _ in .none
            }
    ) throws {
        let validated = try catalog.validated()
        self.hostProfile = hostProfile
        self.catalogGeneration = validated.generation
        definitions = Dictionary(
            uniqueKeysWithValues: validated.definitions.map {
                ($0.reference, $0)
            })
        self.clientVersion = clientVersion
        self.resolveSecret = resolveSecret
        self.secretRedactionRegistrar =
            secretRedactionRegistrar
        self.outputSanitizer = outputSanitizer
        self.buildStdio = buildStdio
        self.buildOAuth = buildOAuth
        self.stdioToolCatalogCache = stdioToolCatalogCache
        self.services = services
    }

    public func makeClient(
        identity: MCPConnectionReuseIdentity,
        generation: MCPConnectionGeneration
    ) throws -> any MCPConnectionClient {
        guard let definition = definitions[identity.server] else {
            throw MCPProductionRuntimeError.definitionMissing(
                identity.server)
        }
        try validate(definition: definition, identity: identity)
        let connectionServices = try services(
            definition,
            identity,
            generation)
        let remoteTaskManager: MCPRemoteTaskManager?
        let remoteTaskStatusSink: (any MCPRemoteTaskStatusSink)?
        if definition.configuration.protocolProfile == .standardExtended {
            if let taskServices =
                    connectionServices.remoteTaskServices {
                let authority = MCPRemoteTaskAuthority(
                    server: definition.reference,
                    connectionGeneration: generation,
                    authorityFingerprint:
                        identity.authority.fingerprint)
                let manager = MCPRemoteTaskManager(
                    authority: authority,
                    profile: .standardExtended,
                    supportsGetAndResult: false,
                    supportsCancel: false,
                    policy: taskServices.policy,
                    events: taskServices.events,
                    payloadStore: taskServices.payloadStore)
                let callbackAuthority = MCPCallbackAuthorityContext(
                    server: definition.reference,
                    connectionGeneration: generation,
                    authorityFingerprint:
                        identity.authority.fingerprint,
                    profile: .standardExtended)
                remoteTaskManager = manager
                remoteTaskStatusSink = try MCPRemoteTaskStatusRelay(
                    expectedAuthority: callbackAuthority,
                    manager: manager,
                    authority: authority)
            } else {
                remoteTaskManager = nil
                remoteTaskStatusSink = nil
            }
        } else {
            remoteTaskManager = nil
            remoteTaskStatusSink =
                connectionServices.remoteTaskStatusSink
        }
        let transport = MCPLazyClientTransport(
            label: IntatisHostApplication.identity
                .keychainService(
                    "mcp.lazy.\(identity.server.serverID.rawValue)")
        ) {
            try await makeTransport(
                definition: definition,
                identity: identity,
                generation: generation)
        }
        let session = MCPClientSession(
            configuration: MCPClientSessionConfiguration(
                server: definition.reference,
                generation: generation,
                profile: definition.configuration.protocolProfile,
                maximumProtocolVersion:
                    definition.configuration.maximumProtocolVersion,
                requiredCapabilities:
                    Set(definition.configuration.requiredCapabilities),
                startupTimeoutMilliseconds:
                    definition.configuration.timeouts.startupMilliseconds,
                callTimeoutMilliseconds:
                    definition.configuration.timeouts.callMilliseconds,
                clientVersion: clientVersion,
                authorizedRoots: connectionServices.authorizedRoots,
                catalogNotificationSink:
                    connectionServices.catalogNotificationSink,
                callbackCapabilities:
                    connectionServices.callbackCapabilities,
                callbackAuthorityFingerprint:
                    connectionServices.callbackCapabilities.isEmpty
                        && remoteTaskStatusSink == nil
                        && connectionServices
                            .inboundNotificationSink == nil
                        ? nil
                        : identity.authority.fingerprint,
                inboundServicesFactory:
                    connectionServices.inboundServicesFactory,
                remoteTaskStatusSink:
                    remoteTaskStatusSink,
                outputSanitizer:
                    outputSanitizer,
                inboundNotificationSink:
                    connectionServices.inboundNotificationSink,
                inboundNotificationPolicy:
                    connectionServices.inboundNotificationPolicy),
            transport: transport)
        let cacheContext = MCPStdioToolCatalogCacheKey(
            identity: identity,
            profile: definition.configuration.protocolProfile,
            maximumProtocolVersion:
                definition.configuration.maximumProtocolVersion)
            .map {
                MCPStdioToolCatalogCacheContext(
                    cache: stdioToolCatalogCache,
                    key: $0)
            }
        return MCPClientSessionConnectionClient(
            session: session,
            remoteTaskManager: remoteTaskManager,
            toolCatalogCache: cacheContext)
    }

    private func validate(
        definition: MCPServerDefinition,
        identity: MCPConnectionReuseIdentity
    ) throws {
        let configuration = definition.configuration
        guard identity.server == definition.reference,
              identity.transport == configuration.transport.kind,
              identity.transportConfigurationFingerprint
                == configuration.transport.connectionFingerprint,
              identity.authority.server == definition.reference,
              identity.authority.transport == configuration.transport.kind,
              identity.authority.protocolProfile
                == configuration.protocolProfile,
              identity.authority.maximumProtocolVersion
                == configuration.maximumProtocolVersion,
              identity.environmentReference
                == configuration.environmentReference,
              identity.authority.environmentReference
                == configuration.environmentReference,
              identity.launchArtifactFingerprint
                == configuration.transport.launchArtifactFingerprint,
              identity.authority.launchArtifactFingerprint
                == configuration.transport.launchArtifactFingerprint,
              identity.oauthAccountReference
                == configuration.transport.oauthAccountReference,
              identity.authority.accountReference
                == configuration.transport.oauthAccountReference else {
            throw MCPProductionRuntimeError.definitionIdentityMismatch
        }
        guard hostProfile.permits(identity.transport) else {
            throw MCPProductionRuntimeError.transportUnavailable(
                host: hostProfile,
                transport: identity.transport)
        }
    }

    private func makeTransport(
        definition: MCPServerDefinition,
        identity: MCPConnectionReuseIdentity,
        generation: MCPConnectionGeneration
    ) async throws -> any Transport {
        switch definition.configuration.transport {
        case .stdio:
            guard hostProfile.supportsStdio else {
                throw MCPProductionRuntimeError.transportUnavailable(
                    host: hostProfile,
                    transport: .stdio)
            }
            guard let buildStdio else {
                throw MCPProductionRuntimeError
                    .stdioFactoryUnavailable
            }
            return try await buildStdio(
                definition,
                identity,
                generation)

        case .streamableHTTP(let configuration):
            var headers: [String: String] = [:]
            for (name, value) in configuration.headers {
                headers[name] = try await resolvedString(value)
            }

            let authorization: any MCPHTTPAuthorizationProviding
            if configuration.oauth?.enabled == true {
                guard let buildOAuth else {
                    throw MCPProductionRuntimeError
                        .oauthAuthorizationUnavailable
                }
                authorization = try await buildOAuth(
                    definition,
                    identity,
                    generation)
            } else if let reference =
                        configuration.bearerTokenReference {
                authorization = try MCPStaticBearerAuthorization(
                    token: try await resolvedSecret(reference))
            } else {
                authorization = MCPNoHTTPAuthorization()
            }

            return try MCPStreamableHTTPTransport(
                configuration: configuration,
                generation: generation,
                resolvedHeaders: headers,
                authorizationProvider: authorization,
                secretRedactionRegistrar:
                    secretRedactionRegistrar,
                requestTimeoutMilliseconds:
                    definition.configuration.timeouts.callMilliseconds,
                shutdownTimeoutMilliseconds:
                    definition.configuration.timeouts.shutdownMilliseconds,
                egressAuthorizer:
                    MCPExactOriginEgressPolicy(
                        allowsLoopback:
                            configuration
                                .allowInsecureLoopbackDevelopmentHTTP
                                && URL(
                                    string:
                                        configuration.endpoint)?
                                    .scheme?
                                    .lowercased() == "http"))
        }
    }

    private func resolvedString(
        _ value: MCPConfiguredValue
    ) async throws -> String {
        switch value {
        case .literal(let value):
            return value
        case .secret(let reference):
            let data = try await resolvedSecret(reference)
            guard let value = String(data: data, encoding: .utf8),
                  !value.contains("\0"),
                  !value.contains(where: \.isNewline) else {
                throw MCPProductionRuntimeError.invalidResolvedSecret
            }
            return value
        }
    }

    private func resolvedSecret(
        _ reference: MCPSecretReference
    ) async throws -> Data {
        guard reference.storageClass
                == hostProfile.requiredSecretStorageClass else {
            throw MCPProductionRuntimeError.secretStorageClassMismatch(
                expected: hostProfile.requiredSecretStorageClass,
                actual: reference.storageClass)
        }
        guard let resolveSecret else {
            throw MCPProductionRuntimeError
                .secretResolverUnavailable
        }
        let data = try await resolveSecret(reference)
        guard !data.isEmpty,
              data.count <= MCPSecretStoreLimits.maximumSecretBytes else {
            throw MCPProductionRuntimeError.invalidResolvedSecret
        }
        secretRedactionRegistrar?
            .registerMCPSecretRedactionValue(data)
        return data
    }
}

public extension MCPTransportConfiguration {
    var launchArtifactFingerprint: String? {
        if case .stdio(let configuration) = self {
            return configuration.launchArtifact.fingerprint
        }
        return nil
    }

    var oauthAccountReference: MCPAccountReference? {
        if case .streamableHTTP(let configuration) = self {
            return configuration.oauth?.accountReference
        }
        return nil
    }
}

// MARK: - Shared exact-session owner

public enum MCPSessionRuntimeOwnerState:
    String, Codable, Equatable, Sendable {
    case active
    case quiescing
    case stopped
}

/// Lifecycle object retained by the App process registry or one CLI command.
/// Views/command parsers never own raw connections.
public actor MCPSessionRuntimeOwner {
    public nonisolated let sessionID: SessionID
    public let runtime: MCPRuntime

    private var state: MCPSessionRuntimeOwnerState = .active
    private var shutdownTask: Task<MCPRuntimeShutdownReport, Never>?
    private let reconnectController: MCPReconnectController
    private let metrics: MCPRuntimeMetrics
    private let inboundNotificationSource:
        (any MCPInboundNotificationSnapshotSource)?
    private var diagnostics: [MCPDiagnosticSummary] = []
    private let maximumDiagnostics = 128
    private var liveActivationReasons:
        [MCPAuthorityPoolKey: MCPRuntimeActivationReason] = [:]

    public init(
        sessionID: SessionID,
        factory: any MCPConnectionClientFactory,
        hardGate: any MCPControlPlaneHardGate,
        consentSource: any MCPExactConsentSource,
        auditSink: any MCPControlPlaneAuditSink,
        reconnectPolicy: MCPReconnectPolicy = .init(),
        metrics: MCPRuntimeMetrics = MCPRuntimeMetrics(),
        inboundNotificationSource:
            (any MCPInboundNotificationSnapshotSource)? = nil,
        outputSanitizer:
            any MCPToolResultSanitizer =
                MCPConservativeToolResultSanitizer()
    ) {
        self.sessionID = sessionID
        reconnectController = MCPReconnectController(
            policy: reconnectPolicy)
        self.metrics = metrics
        self.inboundNotificationSource =
            inboundNotificationSource
        runtime = MCPRuntime(
            sessionID: sessionID,
            factory: factory,
            hardGate: hardGate,
            consentSource: consentSource,
            auditSink: auditSink,
            outputSanitizer:
                outputSanitizer)
    }

    public init(
        sessionID: SessionID,
        catalogPublication:
            MCPProductionCatalogPublication,
        hardGate: any MCPControlPlaneHardGate,
        consentSource: any MCPExactConsentSource,
        auditSink: any MCPControlPlaneAuditSink,
        reconnectPolicy: MCPReconnectPolicy = .init(),
        metrics: MCPRuntimeMetrics = MCPRuntimeMetrics(),
        inboundNotificationSource:
            (any MCPInboundNotificationSnapshotSource)? = nil,
        outputSanitizer:
            any MCPToolResultSanitizer =
                MCPConservativeToolResultSanitizer()
    ) {
        self.sessionID = sessionID
        reconnectController = MCPReconnectController(
            policy: reconnectPolicy)
        self.metrics = metrics
        self.inboundNotificationSource =
            inboundNotificationSource
        runtime = MCPRuntime(
            sessionID: sessionID,
            catalogPublication: catalogPublication,
            hardGate: hardGate,
            consentSource: consentSource,
            auditSink: auditSink,
            outputSanitizer:
                outputSanitizer)
    }

    public func lifecycleState() -> MCPSessionRuntimeOwnerState {
        state
    }

    public func activate(
        _ plan: MCPInvocationPlan
    ) async throws -> MCPConnectionSetSnapshot {
        guard state == .active else {
            throw MCPRuntimeError.stopped
        }
        let started = ContinuousClock.now
        do {
            let snapshot = try await runtime.activate(plan)
            await registerLiveConnections(
                snapshot,
                reason: plan.activationReason)
            for connection in snapshot.connections {
                await metrics.record(
                    server: connection.bindingIdentity.server,
                    operation: .connect,
                    outcome: .succeeded,
                    latencyMilliseconds: Self.elapsedMilliseconds(
                        since: started))
            }
            return snapshot
        } catch let failure as MCPRequiredStartupFailure {
            for item in failure.failures {
                await metrics.record(
                    server: item.server,
                    operation: .connect,
                    outcome: .failed,
                    latencyMilliseconds: Self.elapsedMilliseconds(
                        since: started))
                retainDiagnostic(item.diagnostic)
            }
            throw failure
        } catch {
            retainDiagnostic(MCPBoundedDiagnostics.summarize(
                code: .transport,
                message: (error as? LocalizedError)?.errorDescription
                    ?? String(describing: type(of: error))))
            throw error
        }
    }

    public func withPreparedProviderDispatch<T: Sendable>(
        _ plan: MCPInvocationPlan,
        operation: @escaping @Sendable (
            MCPConnectionSetSnapshot
        ) async throws -> T
    ) async throws -> T {
        guard state == .active else {
            throw MCPRuntimeError.stopped
        }
        guard plan.activationReason.permitsProviderDispatch else {
            throw MCPRuntimeError.activationDoesNotPermitProviderDispatch(
                plan.activationReason)
        }
        let snapshot = try await activate(plan)
        try Task.checkCancellation()
        return try await operation(snapshot)
    }

    /// User-triggered Refresh of one already-live exact generation. It uses
    /// the retained route only to stage a complete raw catalog; `MCPRuntime`
    /// performs durable admission and the one-shot atomic publication.
    @discardableResult
    public func refreshExisting(
        identity: MCPConnectionReuseIdentity,
        generation: MCPConnectionGeneration,
        revocationGeneration:
            MCPRevocationGeneration,
        callerFingerprint: String,
        correlation:
            MCPEventCorrelation = .init(),
        limits:
            MCPFullCatalogDiscoveryLimits = .init()
    ) async throws -> MCPCompleteCatalogSnapshot {
        guard state == .active else {
            throw MCPRuntimeError.stopped
        }
        let live = await runtime.liveConnectionSnapshots()
        guard let snapshot = live.first(where: {
            $0.reuseIdentity == identity
                && $0.bindingIdentity
                    .connectionGeneration
                    == generation
        }) else {
            throw MCPRuntimeError
                .noLiveGeneration(identity.poolKey)
        }
        let route = snapshot.route
        let started = ContinuousClock.now
        do {
            let catalog = try await runtime.refreshExisting(
                identity: identity,
                generation: generation,
                revocationGeneration:
                    revocationGeneration,
                callerFingerprint:
                    callerFingerprint,
                correlation: correlation
            ) {
                try await route
                    .discoverCompleteCatalogForRefresh(
                        limits: limits)
            }
            await metrics.record(
                server: identity.server,
                operation: .catalog,
                outcome: .succeeded,
                latencyMilliseconds:
                    Self.elapsedMilliseconds(
                        since: started))
            return catalog
        } catch {
            await metrics.record(
                server: identity.server,
                operation: .catalog,
                outcome: .failed,
                latencyMilliseconds:
                    Self.elapsedMilliseconds(
                        since: started))
            retainDiagnostic(
                MCPBoundedDiagnostics.summarize(
                    code: .runtime,
                    message:
                        Self.safeMessage(error)))
            throw error
        }
    }

    /// User-triggered Disconnect for one exact authority slot. Runtime
    /// admission/audit settles the operation; reconnect intent is retired even
    /// if terminal persistence fails after the route was already fenced.
    public func disconnect(
        identity: MCPConnectionReuseIdentity,
        replacementRevocationGeneration:
            MCPRevocationGeneration,
        callerFingerprint: String,
        correlation:
            MCPEventCorrelation = .init()
    ) async throws {
        guard state == .active else {
            throw MCPRuntimeError.stopped
        }
        do {
            try await runtime.disconnect(
                identity: identity,
                replacementRevocationGeneration:
                    replacementRevocationGeneration,
                callerFingerprint:
                    callerFingerprint,
                correlation: correlation)
        } catch {
            await reconnectController.retire(
                key: identity.poolKey)
            liveActivationReasons.removeValue(
                forKey: identity.poolKey)
            throw error
        }
        await reconnectController.retire(
            key: identity.poolKey)
        liveActivationReasons.removeValue(
            forKey: identity.poolKey)
    }

    public func reconcileColdRestore(
        _ restore: MCPColdRestoreState
    ) async throws {
        guard state == .active else {
            throw MCPRuntimeError.stopped
        }
        try await runtime.reconcileColdRestore(restore)
    }

    public func shutdown(
        reason: String
    ) async -> MCPRuntimeShutdownReport {
        if let shutdownTask {
            return await shutdownTask.value
        }
        state = .quiescing
        let runtime = runtime
        let task = Task {
            await runtime.shutdownAndDrain(reason: reason)
        }
        shutdownTask = task
        let report = await task.value
        for key in liveActivationReasons.keys {
            await reconnectController.retire(key: key)
        }
        liveActivationReasons.removeAll()
        state = .stopped
        return report
    }

    /// Records a live-generation failure and, when policy permits, creates only
    /// a replacement connection generation. No operation closure, request
    /// bytes, tool arguments, resource URI, prompt, or task payload is accepted
    /// by this API, so an uncertain operation cannot be replayed accidentally.
    public func recoverConnectionGeneration(
        failed requirement: MCPInvocationServerRequirement,
        generation: MCPConnectionGeneration,
        kind: MCPReconnectFailureKind,
        entropy: Double = 0
    ) async -> MCPReconnectDirective {
        let key = requirement.identity.poolKey
        let directive = await reconnectController.recordFailure(
            key: key,
            generation: generation,
            kind: kind,
            entropy: entropy)
        switch directive {
        case .ignoreStaleGeneration:
            return directive
        case .awaitExplicitActivation(let diagnostic):
            liveActivationReasons.removeValue(forKey: key)
            retainDiagnostic(diagnostic)
            await metrics.record(
                server: requirement.identity.server,
                operation: .connect,
                outcome: .failed,
                latencyMilliseconds: 0)
            return directive
        case .reconnectConnectionOnly(
                _,
                let delayMilliseconds,
                _,
                let diagnostic):
            retainDiagnostic(diagnostic)
            await metrics.record(
                server: requirement.identity.server,
                operation: .connect,
                outcome: kind == .executionUncertain
                    ? .uncertain
                    : .failed,
                latencyMilliseconds: 0)
            guard state == .active,
                  let activationReason =
                    liveActivationReasons[key] else {
                return .awaitExplicitActivation(
                    MCPDiagnosticSummary(
                        code: "mcp_reconnect_not_live",
                        summary:
                            "MCP connection recovery requires a prior explicit live activation."))
            }
            do {
                try await Task.sleep(
                    for: .milliseconds(delayMilliseconds))
                try Task.checkCancellation()
                let plan = MCPInvocationPlan(
                    sessionID: sessionID,
                    agentID:
                        requirement.identity.authority.agentID,
                    activationReason: activationReason,
                    servers: [requirement])
                // The returned snapshot is deliberately not exposed to the
                // failed operation. It is eligible only for a later provider
                // invocation that freezes its own new binding.
                _ = try await activate(plan)
            } catch {
                retainDiagnostic(MCPBoundedDiagnostics.summarize(
                    code: .transport,
                    message:
                        "MCP connection-only recovery failed: \(Self.safeMessage(error))"))
            }
            return directive
        }
    }

    /// Applies the exact identity hot-reload policy, drains the old authority,
    /// and optionally creates a replacement connection generation. As with
    /// reconnect, this method cannot replay a prior MCP operation.
    public func applyHotReload(
        current: MCPInvocationServerRequirement,
        replacement: MCPInvocationServerRequirement,
        currentGeneration: MCPConnectionGeneration
    ) async -> MCPHotReloadAction {
        let key = current.identity.poolKey
        let liveReason = liveActivationReasons[key]
        let action = MCPHotReloadPolicy.action(
            current: current.identity,
            replacement: replacement.identity,
            currentGeneration: currentGeneration,
            liveActivationReason: liveReason)
        switch action {
        case .noChange:
            return action
        case .drainAndWaitForExplicitActivation:
            await runtime.revokeAuthority(
                key,
                to: replacement.revocationGeneration,
                reason: "MCP configuration hot reload")
            await reconnectController.retire(key: key)
            liveActivationReasons.removeValue(forKey: key)
        case .drainAndReconnectConnectionOnly:
            await runtime.revokeAuthority(
                key,
                to: replacement.revocationGeneration,
                reason: "MCP configuration hot reload")
            await reconnectController.retire(key: key)
            liveActivationReasons.removeValue(forKey: key)
            if let liveReason, state == .active {
                do {
                    let snapshot = try await activate(MCPInvocationPlan(
                        sessionID: sessionID,
                        agentID:
                            replacement.identity.authority.agentID,
                        activationReason: liveReason,
                        servers: [replacement]))
                    if let connection = snapshot.connections.first {
                        try? await reconnectController
                            .replaceAfterHotReload(
                                oldKey: key,
                                newIdentity: replacement.identity,
                                newGeneration:
                                    connection.bindingIdentity
                                        .connectionGeneration,
                                reason: liveReason)
                    }
                } catch {
                    retainDiagnostic(MCPBoundedDiagnostics.summarize(
                        code: .configuration,
                        message:
                            "MCP hot reload drained the previous generation, but replacement initialization failed: \(Self.safeMessage(error))"))
                }
            }
        }
        return action
    }

    public func metricsSnapshot() async -> MCPMetricsSnapshot {
        await metrics.snapshot()
    }

    public func liveConnectionSnapshots()
        async -> [MCPConnectionSnapshot]
    {
        await runtime.liveConnectionSnapshots()
    }

    public func currentConnectionSnapshot(
        identity: MCPConnectionReuseIdentity,
        generation: MCPConnectionGeneration
    ) async throws -> MCPConnectionSnapshot {
        guard state == .active else {
            throw MCPRuntimeError.stopped
        }
        return try await runtime.currentConnectionSnapshot(
            identity: identity,
            generation: generation)
    }

    @discardableResult
    public func markCatalogStaleAndRepublish(
        identity: MCPConnectionReuseIdentity,
        generation: MCPConnectionGeneration,
        revocationGeneration:
            MCPRevocationGeneration,
        kinds: Set<MCPCatalogChangeKind>
    ) async throws -> MCPConnectionSetSnapshot {
        guard state == .active else {
            throw MCPRuntimeError.stopped
        }
        return try await runtime
            .markCatalogStaleAndRepublish(
                identity: identity,
                generation: generation,
                revocationGeneration:
                    revocationGeneration,
                kinds: kinds)
    }

    @discardableResult
    public func publishDynamicCatalogAndRepublish(
        _ catalog: MCPCompleteCatalogSnapshot,
        identity: MCPConnectionReuseIdentity,
        generation: MCPConnectionGeneration,
        revocationGeneration:
            MCPRevocationGeneration,
        resultingUnavailableKinds:
            Set<MCPCatalogChangeKind>
    ) async throws -> MCPConnectionSetSnapshot {
        guard state == .active else {
            throw MCPRuntimeError.stopped
        }
        return try await runtime
            .publishDynamicCatalogAndRepublish(
                catalog,
                identity: identity,
                generation: generation,
                revocationGeneration:
                    revocationGeneration,
                resultingUnavailableKinds:
                    resultingUnavailableKinds)
    }

    public func latestPublishedSnapshot(
        agentID: AgentID
    ) async -> MCPConnectionSetSnapshot? {
        await runtime.latestPublishedSnapshot(
            agentID: agentID)
    }

    public func revokeAuthority(
        _ authorityKey: MCPAuthorityPoolKey,
        to replacementRevocationGeneration:
            MCPRevocationGeneration,
        reason: String
    ) async {
        await runtime.revokeAuthority(
            authorityKey,
            to: replacementRevocationGeneration,
            reason: reason)
        await reconnectController.retire(
            key: authorityKey)
        liveActivationReasons.removeValue(
            forKey: authorityKey)
    }

    public func revokeServerReferences(
        _ revocations:
            [MCPCatalogReferenceRevocation]
    ) async {
        let references = Set(
            revocations.map(\.reference))
        await runtime.revokeServerReferences(
            revocations)
        for key in liveActivationReasons.keys
            where references.contains(
                key.authority.server)
        {
            await reconnectController.retire(key: key)
            liveActivationReasons.removeValue(
                forKey: key)
        }
    }

    public func diagnosticsSnapshot() async -> [MCPDiagnosticSummary] {
        guard let inboundNotificationSource else {
            return diagnostics
        }
        let inbound =
            await inboundNotificationSource
                .inboundDiagnosticsSnapshot()
        let merged = diagnostics + inbound
        return merged.count <= maximumDiagnostics
            ? merged
            : Array(merged.suffix(maximumDiagnostics))
    }

    private func registerLiveConnections(
        _ snapshot: MCPConnectionSetSnapshot,
        reason: MCPRuntimeActivationReason
    ) async {
        for connection in snapshot.connections {
            let identity = connection.reuseIdentity
            let generation =
                connection.bindingIdentity.connectionGeneration
            do {
                try await reconnectController.registerLiveIntent(
                    identity: identity,
                    generation: generation,
                    reason: reason)
                _ = await reconnectController.markReady(
                    key: identity.poolKey,
                    generation: generation)
                liveActivationReasons[identity.poolKey] = reason
            } catch {
                retainDiagnostic(MCPBoundedDiagnostics.summarize(
                    code: .runtime,
                    message:
                        "MCP reconnect state was not registered: \(Self.safeMessage(error))"))
            }
        }
    }

    private func retainDiagnostic(
        _ diagnostic: MCPDiagnosticSummary
    ) {
        diagnostics.append(diagnostic)
        if diagnostics.count > maximumDiagnostics {
            diagnostics.removeFirst(
                diagnostics.count - maximumDiagnostics)
        }
    }

    private nonisolated static func elapsedMilliseconds(
        since instant: ContinuousClock.Instant
    ) -> Int {
        let duration = instant.duration(to: .now)
        let components = duration.components
        let seconds = components.seconds > Int64(Int.max / 1_000)
            ? Int.max
            : Int(components.seconds) * 1_000
        let milliseconds =
            Int(components.attoseconds / 1_000_000_000_000_000)
        return max(0, seconds + milliseconds)
    }

    private nonisolated static func safeMessage(
        _ error: Error
    ) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? String(describing: type(of: error))
    }
}

// MARK: - Exact identity construction

public struct MCPConnectionAuthorityInputs: Sendable {
    public let sessionID: SessionID
    public let agentID: AgentID
    public let attachment: MCPServerAttachment
    public let capabilityLeaseID: CapabilityLeaseID
    public let capabilityTaskID: TaskID?
    public let workspaceLeaseID: WorkspaceLeaseID?
    public let workspaceRootIdentityFingerprint: String?
    public let workspaceLeasePolicyFingerprint:
        String
    public let accountReference: MCPAccountReference?
    public let rootsPolicyRevision: MCPPolicyRevision
    public let networkPolicyRevision: MCPPolicyRevision
    public let sandboxProfileRevision: MCPPolicyRevision
    public let sandboxPolicyFingerprint: String
    public let revocationGeneration: MCPRevocationGeneration
    public let hostProfile: MCPProductHostProfile
    public let runtimeIdentityFingerprint: String

    public init(
        sessionID: SessionID,
        agentID: AgentID,
        attachment: MCPServerAttachment,
        capabilityLeaseID: CapabilityLeaseID,
        capabilityTaskID: TaskID?,
        workspaceLeaseID: WorkspaceLeaseID? = nil,
        workspaceRootIdentityFingerprint: String? = nil,
        workspaceLeasePolicyFingerprint: String,
        accountReference: MCPAccountReference? = nil,
        rootsPolicyRevision: MCPPolicyRevision,
        networkPolicyRevision: MCPPolicyRevision,
        sandboxProfileRevision: MCPPolicyRevision,
        sandboxPolicyFingerprint: String,
        revocationGeneration: MCPRevocationGeneration,
        hostProfile: MCPProductHostProfile,
        runtimeIdentityFingerprint: String
    ) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.attachment = attachment
        self.capabilityLeaseID = capabilityLeaseID
        self.capabilityTaskID =
            capabilityTaskID
        self.workspaceLeaseID = workspaceLeaseID
        self.workspaceRootIdentityFingerprint =
            workspaceRootIdentityFingerprint
        self.workspaceLeasePolicyFingerprint =
            workspaceLeasePolicyFingerprint
        self.accountReference = accountReference
        self.rootsPolicyRevision = rootsPolicyRevision
        self.networkPolicyRevision = networkPolicyRevision
        self.sandboxProfileRevision = sandboxProfileRevision
        self.sandboxPolicyFingerprint =
            sandboxPolicyFingerprint
        self.revocationGeneration = revocationGeneration
        self.hostProfile = hostProfile
        self.runtimeIdentityFingerprint = runtimeIdentityFingerprint
    }
}

public enum MCPConnectionIdentityBuilder {
    public static func build(
        definition: MCPServerDefinition,
        inputs: MCPConnectionAuthorityInputs
    ) throws -> MCPInvocationServerRequirement {
        guard inputs.attachment.server == definition.reference else {
            throw MCPProductionRuntimeError.definitionIdentityMismatch
        }
        guard inputs.workspaceLeasePolicyFingerprint
                .utf8.count == 64,
              inputs.sandboxPolicyFingerprint
                .utf8.count == 64 else {
            throw MCPProductionRuntimeError
                .definitionIdentityMismatch
        }
        let configuration = definition.configuration
        // Skill dependency metadata intentionally accepts a narrower transport
        // subset than the MCP runtime. Unsupported-but-valid runtime
        // configurations (for example explicitly enabled development
        // loopback HTTP) carry no supported locator assertion and therefore
        // fail Skill preflight closed without preventing the MCP connection
        // itself from starting.
        let skillDependencyLocatorFingerprint: String?
        switch configuration.transport {
        case .streamableHTTP(let http):
            skillDependencyLocatorFingerprint =
                try? MCPDependencyLocatorFingerprint
                    .streamableHTTP(http.endpoint)
        case .stdio(let stdio):
            skillDependencyLocatorFingerprint =
                try? MCPDependencyLocatorFingerprint
                    .stdio(
                        stdio.executableCanonicalPath)
        }
        let authorityFingerprint = digest([
            definition.reference.serverID.rawValue,
            definition.reference.serverRevision.rawValue,
            inputs.sessionID.rawValue,
            inputs.agentID.rawValue,
            inputs.attachment.attachmentID.rawValue,
            inputs.capabilityLeaseID.rawValue,
            inputs.capabilityTaskID?
                .rawValue ?? "none",
            inputs.workspaceLeaseID?.rawValue ?? "none",
            inputs.workspaceRootIdentityFingerprint ?? "none",
            inputs.workspaceLeasePolicyFingerprint,
            inputs.accountReference?.rawValue ?? "none",
            configuration.environmentReference.rawValue,
            inputs.attachment.policy.revision.rawValue,
            inputs.rootsPolicyRevision.rawValue,
            inputs.networkPolicyRevision.rawValue,
            inputs.sandboxProfileRevision.rawValue,
            inputs.sandboxPolicyFingerprint,
            inputs.revocationGeneration.rawValue,
            inputs.hostProfile.rawValue,
        ])
        let authority = MCPConnectionAuthority(
            server: definition.reference,
            transport: configuration.transport.kind,
            protocolProfile: configuration.protocolProfile,
            maximumProtocolVersion:
                configuration.maximumProtocolVersion,
            sessionID: inputs.sessionID,
            agentID: inputs.agentID,
            attachmentID: inputs.attachment.attachmentID,
            capabilityLeaseID: inputs.capabilityLeaseID,
            capabilityTaskID:
                inputs.capabilityTaskID,
            workspaceLeaseID: inputs.workspaceLeaseID,
            workspaceRootIdentityFingerprint:
                inputs.workspaceRootIdentityFingerprint,
            workspaceLeasePolicyFingerprint:
                inputs
                    .workspaceLeasePolicyFingerprint,
            attachmentPolicyRevision:
                inputs.attachment.policy.revision,
            accountReference: inputs.accountReference,
            environmentReference:
                configuration.environmentReference,
            launchArtifactFingerprint:
                configuration.transport.launchArtifactFingerprint,
            rootsPolicyRevision: inputs.rootsPolicyRevision,
            networkPolicyRevision: inputs.networkPolicyRevision,
            sandboxProfileRevision:
                inputs.sandboxProfileRevision,
            sandboxPolicyFingerprint:
                inputs.sandboxPolicyFingerprint,
            hostPlatform: inputs.hostProfile.rawValue,
            fingerprint: authorityFingerprint)
        let identity = MCPConnectionReuseIdentity(
            server: definition.reference,
            transport: configuration.transport.kind,
            transportConfigurationFingerprint:
                configuration.transport.connectionFingerprint,
            authority: authority,
            oauthAccountReference:
                configuration.transport.oauthAccountReference,
            environmentReference:
                configuration.environmentReference,
            launchArtifactFingerprint:
                configuration.transport.launchArtifactFingerprint,
            runtimeIdentityFingerprint:
                inputs.runtimeIdentityFingerprint,
            skillDependencyLocatorFingerprint:
                skillDependencyLocatorFingerprint)
        let viewDigest = digest([
            inputs.attachment.policy.revision.rawValue,
            inputs.agentID.rawValue,
            inputs.revocationGeneration.rawValue,
        ])
        let viewRevision = MCPAgentCatalogViewRevision(
            rawValue: "mcpview_\(viewDigest.prefix(24))")
        return MCPInvocationServerRequirement(
            identity: identity,
            agentCatalogViewRevision: viewRevision,
            revocationGeneration: inputs.revocationGeneration,
            serverDefinitionRequired: configuration.required,
            attachmentRequired: inputs.attachment.policy.required,
            callerFingerprint: digest([
                inputs.agentID.rawValue,
                inputs.capabilityLeaseID.rawValue,
                inputs.capabilityTaskID?
                    .rawValue ?? "none",
                inputs.workspaceLeasePolicyFingerprint,
                inputs.sandboxPolicyFingerprint,
                inputs.runtimeIdentityFingerprint,
            ]),
            correlation: MCPEventCorrelation(
                agentID: inputs.agentID))
    }

    private static func digest(_ components: [String]) -> String {
        let bytes = components
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
        return SHA256.hash(data: Data(bytes.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Canonical identity of the complete WorkspaceLease policy used by MCP.
    /// Ordering of path rules and denied patterns is normalized because those
    /// collections are policy sets; the sensitive-path floor is always
    /// included even if a caller supplies an older/empty denied list.
    public static func workspaceLeasePolicyFingerprint(
        _ lease: WorkspaceLease?
    ) -> String {
        guard let lease else {
            return digest([
                "mcp-workspace-policy-v2",
                "none",
            ])
        }
        let root = lease.rootIdentity.map {
            [
                $0.canonicalPath,
                String($0.deviceID),
                String($0.fileID),
            ].joined(separator: "\u{1f}")
        } ?? "missing-root-identity"
        let allowed = Array(
            Set(lease.allowedPathRules.map(\.pattern)))
            .sorted()
        let denied = Array(Set(
            lease.deniedPatterns
                + WorkspaceLease
                    .mandatoryTerminalDeniedPatterns))
            .sorted()
        return digest([
            "mcp-workspace-policy-v2",
            lease.id.rawValue,
            lease.workspaceID.rawValue,
            lease.taskID?.rawValue ?? "none",
            lease.rootPath,
            root,
            lease.access.rawValue,
            allowed.joined(separator: "\u{1e}"),
            denied.joined(separator: "\u{1e}"),
            lease.expiresAtTaskCompletion
                ? "expires"
                : "persistent",
        ])
    }

    /// Identity of the sandbox policy inputs applied to this connection.
    /// A host changing transport/network/workspace constraints necessarily
    /// creates a different sandbox identity and therefore a new generation.
    public static func sandboxPolicyFingerprint(
        hostProfile: MCPProductHostProfile,
        transport: MCPTransportKind,
        sandboxProfileRevision:
            MCPPolicyRevision,
        networkPolicyRevision:
            MCPPolicyRevision,
        workspaceLeasePolicyFingerprint:
            String
    ) -> String {
        digest([
            "mcp-sandbox-policy-v2",
            hostProfile.rawValue,
            transport.rawValue,
            sandboxProfileRevision.rawValue,
            networkPolicyRevision.rawValue,
            workspaceLeasePolicyFingerprint,
        ])
    }
}
