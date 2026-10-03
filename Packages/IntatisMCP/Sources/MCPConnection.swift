import Foundation
import IntatisCore
import IntatisProtocol
import MCP

/// Exact slot key for the session-owned connection pool.
///
/// `MCPConnectionAuthority` includes the session and Agent identities, so the
/// default behavior cannot share a process/connection across Agents.
public struct MCPAuthorityPoolKey: Codable, Equatable, Hashable, Sendable {
    public let authority: MCPConnectionAuthority

    public init(authority: MCPConnectionAuthority) {
        self.authority = authority
    }
}

/// Every fact used by Codex-compatible positive connection reuse.
///
/// Some values are also represented inside `authority`. Keeping the explicit
/// fields is intentional: reuse is audited field-by-field and cannot collapse
/// into a comparison of an alias or one caller-supplied digest.
public struct MCPConnectionReuseIdentity:
    Codable, Equatable, Hashable, Sendable {
    public let server: MCPServerReference
    public let transport: MCPTransportKind
    public let transportConfigurationFingerprint: String
    public let authority: MCPConnectionAuthority
    public let oauthAccountReference: MCPAccountReference?
    public let environmentReference: MCPEnvironmentReference
    public let launchArtifactFingerprint: String?
    public let runtimeIdentityFingerprint: String
    /// Opaque transport-locator assertion input for Skill dependency
    /// preflight. The raw endpoint/executable never enters the provider-visible
    /// availability snapshot.
    public let skillDependencyLocatorFingerprint: String?

    public init(
        server: MCPServerReference,
        transport: MCPTransportKind,
        transportConfigurationFingerprint: String,
        authority: MCPConnectionAuthority,
        oauthAccountReference: MCPAccountReference?,
        environmentReference: MCPEnvironmentReference,
        launchArtifactFingerprint: String?,
        runtimeIdentityFingerprint: String,
        skillDependencyLocatorFingerprint:
            String? = nil
    ) {
        self.server = server
        self.transport = transport
        self.transportConfigurationFingerprint =
            transportConfigurationFingerprint
        self.authority = authority
        self.oauthAccountReference = oauthAccountReference
        self.environmentReference = environmentReference
        self.launchArtifactFingerprint = launchArtifactFingerprint
        self.runtimeIdentityFingerprint = runtimeIdentityFingerprint
        self.skillDependencyLocatorFingerprint =
            skillDependencyLocatorFingerprint
    }

    public var poolKey: MCPAuthorityPoolKey {
        MCPAuthorityPoolKey(authority: authority)
    }
}

public enum MCPConnectionReuseMismatch:
    String, Codable, Equatable, Hashable, Sendable {
    case serverIdentity = "server_identity"
    case serverConfigurationRevision = "server_configuration_revision"
    case transport
    case transportConfiguration = "transport_configuration"
    case authority
    case oauthAccount = "oauth_account"
    case environment
    case launchArtifact = "launch_artifact"
    case runtimeIdentity = "runtime_identity"
    case startupIncomplete = "startup_incomplete"
    case clientClosed = "client_closed"
}

public struct MCPConnectionReuseEvaluation: Equatable, Sendable {
    public let mismatches: [MCPConnectionReuseMismatch]

    public init(mismatches: [MCPConnectionReuseMismatch]) {
        self.mismatches = Array(Set(mismatches)).sorted {
            $0.rawValue < $1.rawValue
        }
    }

    public var canReuse: Bool { mismatches.isEmpty }
}

public enum MCPConnectionLifecycleState:
    String, Codable, Equatable, Sendable {
    case allocated
    case starting
    case initializing
    case discovering
    case ready
    case refreshing
    case stopping
    case closed
    case failed
    case retired
}

public struct MCPConnectionLifecycleSnapshot: Equatable, Sendable {
    public let generation: MCPConnectionGeneration
    public let state: MCPConnectionLifecycleState
    public let revocationGeneration: MCPRevocationGeneration
    public let negotiatedProtocolVersion: MCPNegotiatedProtocolVersion?
    public let rawCatalogRevision: MCPRawCatalogRevision?
    public let clientOpen: Bool

    public init(
        generation: MCPConnectionGeneration,
        state: MCPConnectionLifecycleState,
        revocationGeneration: MCPRevocationGeneration,
        negotiatedProtocolVersion: MCPNegotiatedProtocolVersion?,
        rawCatalogRevision: MCPRawCatalogRevision?,
        clientOpen: Bool
    ) {
        self.generation = generation
        self.state = state
        self.revocationGeneration = revocationGeneration
        self.negotiatedProtocolVersion = negotiatedProtocolVersion
        self.rawCatalogRevision = rawCatalogRevision
        self.clientOpen = clientOpen
    }
}

public enum MCPConnectionError: Error, Equatable, LocalizedError {
    case wrongSession(expected: SessionID, actual: SessionID)
    case poolStopped
    case invalidLifecycle(
        generation: MCPConnectionGeneration,
        state: MCPConnectionLifecycleState
    )
    case invalidNegotiatedProtocolVersion(
        selected: MCPProtocolVersion,
        maximum: MCPProtocolVersion
    )
    case generationRetired(MCPConnectionGeneration)
    case generationSuperseded(MCPConnectionGeneration)
    case staleGeneration(
        expected: MCPConnectionGeneration,
        actual: MCPConnectionGeneration
    )
    case staleRevocation(
        expected: MCPRevocationGeneration,
        actual: MCPRevocationGeneration
    )
    case staleCatalog(
        expected: MCPRawCatalogRevision,
        actual: MCPRawCatalogRevision?
    )
    case authorityMismatch
    case catalogFingerprintMismatch
    case catalogKindStale(MCPCatalogChangeKind)
    case clientClosed(MCPConnectionGeneration)
    case generationNotFound(MCPConnectionGeneration)

    public var errorDescription: String? {
        switch self {
        case .wrongSession(let expected, let actual):
            return "MCP connection belongs to session \(actual), expected \(expected)"
        case .poolStopped:
            return "MCP connection pool is stopped"
        case .invalidLifecycle(let generation, let state):
            return "MCP connection \(generation) is in invalid state \(state.rawValue)"
        case .invalidNegotiatedProtocolVersion(let selected, let maximum):
            return "MCP server selected protocol \(selected), above or outside maximum \(maximum)"
        case .generationRetired(let generation):
            return "MCP connection generation \(generation) was retired"
        case .generationSuperseded(let generation):
            return "MCP connection generation \(generation) was superseded"
        case .staleGeneration(let expected, let actual):
            return "MCP route generation \(expected) does not match \(actual)"
        case .staleRevocation(let expected, let actual):
            return "MCP route revocation generation \(expected) does not match \(actual)"
        case .staleCatalog(let expected, let actual):
            return "MCP route catalog \(expected) is stale (current: \(actual?.rawValue ?? "none"))"
        case .authorityMismatch:
            return "MCP route authority no longer matches"
        case .catalogFingerprintMismatch:
            return "MCP route catalog fingerprint no longer matches"
        case .catalogKindStale(let kind):
            return "MCP \(kind.rawValue) catalog is stale pending complete refresh"
        case .clientClosed(let generation):
            return "MCP client \(generation) is closed"
        case .generationNotFound(let generation):
            return "MCP connection generation \(generation) was not found"
        }
    }
}

/// Complete result of initialize + initialized + initial discovery.
public struct MCPConnectionStartupResult: Sendable {
    public let negotiatedProtocolVersion: MCPNegotiatedProtocolVersion
    public let negotiatedCapabilities: MCPNegotiatedCapabilitySet
    public let catalog: MCPCompleteCatalogSnapshot
    public let instructions:
        MCPExternalServerInstructions?

    public init(
        negotiatedProtocolVersion: MCPNegotiatedProtocolVersion,
        negotiatedCapabilities: MCPNegotiatedCapabilitySet = .none,
        catalog: MCPCompleteCatalogSnapshot,
        instructions:
            MCPExternalServerInstructions? = nil
    ) {
        self.negotiatedProtocolVersion = negotiatedProtocolVersion
        self.negotiatedCapabilities = negotiatedCapabilities
        self.catalog = catalog
        self.instructions = instructions
    }
}

/// Host-neutral client-generation seam.
///
/// Implementations may wrap stdio or Streamable HTTP, but they remain client
/// only. `shutdownAndDrain` must not return while work still owned by this
/// generation can deliver a result.
public protocol MCPConnectionClient: Sendable {
    func startup(
        profile: MCPProtocolProfile,
        maximumProtocolVersion: MCPProtocolVersion
    ) async throws -> MCPConnectionStartupResult
    func isOpen() async -> Bool
    func listToolsPage(cursor: String?) async throws -> MCPToolListPage
    func listResourcesPage(cursor: String?) async throws -> MCPResourceListPage
    func listResourceTemplatesPage(
        cursor: String?
    ) async throws -> MCPResourceTemplateListPage
    func readResource(uri: String) async throws -> MCPRawResourceReadResult
    func subscribeResource(uri: String) async throws
    func unsubscribeResource(uri: String) async throws
    func listPromptsPage(cursor: String?) async throws -> MCPPromptListPage
    func getPrompt(
        name: String,
        arguments: [String: String]
    ) async throws -> MCPRawPromptGetResult
    func complete(
        reference: MCPCompletionReference,
        argumentName: String,
        argumentValue: String,
        context: [String: String]
    ) async throws -> MCPCompletionResult
    func listRemoteTasks() async throws -> [MCPRemoteTaskSnapshot]
    func refreshRemoteTask(
        _ taskID: MCPRemoteServerTaskID,
        timeoutMilliseconds: Int?
    ) async throws -> MCPRemoteTaskSnapshot
    func cancelRemoteTask(
        _ taskID: MCPRemoteServerTaskID,
        timeoutMilliseconds: Int?
    ) async throws -> MCPRemoteTaskSnapshot
    func remoteTaskResult(
        _ taskID: MCPRemoteServerTaskID,
        timeoutMilliseconds: Int?
    ) async throws -> JSONValue
    func notifyRootsChanged() async throws
    func callTool(
        name: String,
        arguments: [String: JSONValue]
    ) async throws -> MCPRawToolCallResult
    func callToolTaskAugmented(
        name: String,
        arguments: [String: JSONValue],
        ttlMilliseconds: Int?,
        timeoutMilliseconds: Int
    ) async throws -> MCPTaskWire
    func callToolTaskAugmentedAndAwait(
        name: String,
        arguments: [String: JSONValue],
        ttlMilliseconds: Int?,
        originatingToolCallID: String?,
        timeoutMilliseconds: Int
    ) async throws -> MCPRawToolCallResult
    func shutdownAndDrain(reason: String) async
}

public extension MCPConnectionClient {
    func listToolsPage(cursor _: String?) async throws -> MCPToolListPage {
        throw MCPToolExecutionError.operationUnsupported
    }

    func listResourcesPage(
        cursor _: String?
    ) async throws -> MCPResourceListPage {
        throw MCPContentOperationError.operationUnsupported
    }

    func listResourceTemplatesPage(
        cursor _: String?
    ) async throws -> MCPResourceTemplateListPage {
        throw MCPContentOperationError.operationUnsupported
    }

    func readResource(uri _: String) async throws -> MCPRawResourceReadResult {
        throw MCPContentOperationError.operationUnsupported
    }

    func subscribeResource(uri _: String) async throws {
        throw MCPContentOperationError.operationUnsupported
    }

    func unsubscribeResource(uri _: String) async throws {
        throw MCPContentOperationError.operationUnsupported
    }

    func listPromptsPage(cursor _: String?) async throws -> MCPPromptListPage {
        throw MCPContentOperationError.operationUnsupported
    }

    func getPrompt(
        name _: String,
        arguments _: [String: String]
    ) async throws -> MCPRawPromptGetResult {
        throw MCPContentOperationError.operationUnsupported
    }

    func complete(
        reference _: MCPCompletionReference,
        argumentName _: String,
        argumentValue _: String,
        context _: [String: String]
    ) async throws -> MCPCompletionResult {
        throw MCPContentOperationError.operationUnsupported
    }

    func listRemoteTasks() async throws -> [MCPRemoteTaskSnapshot] {
        throw MCPTaskRuntimeError.capabilityMissing
    }

    func refreshRemoteTask(
        _ taskID: MCPRemoteServerTaskID,
        timeoutMilliseconds: Int?
    ) async throws -> MCPRemoteTaskSnapshot {
        throw MCPTaskRuntimeError.capabilityMissing
    }

    func cancelRemoteTask(
        _ taskID: MCPRemoteServerTaskID,
        timeoutMilliseconds: Int?
    ) async throws -> MCPRemoteTaskSnapshot {
        throw MCPTaskRuntimeError.capabilityMissing
    }

    func remoteTaskResult(
        _ taskID: MCPRemoteServerTaskID,
        timeoutMilliseconds: Int?
    ) async throws -> JSONValue {
        throw MCPTaskRuntimeError.capabilityMissing
    }

    func notifyRootsChanged() async throws {
        throw MCPContentOperationError.operationUnsupported
    }

    func callTool(
        name _: String,
        arguments _: [String: JSONValue]
    ) async throws -> MCPRawToolCallResult {
        throw MCPToolExecutionError.operationUnsupported
    }

    func callToolTaskAugmented(
        name _: String,
        arguments _: [String: JSONValue],
        ttlMilliseconds _: Int?,
        timeoutMilliseconds _: Int
    ) async throws -> MCPTaskWire {
        throw MCPTaskRuntimeError.capabilityMissing
    }

    func callToolTaskAugmentedAndAwait(
        name _: String,
        arguments _: [String: JSONValue],
        ttlMilliseconds _: Int?,
        originatingToolCallID _: String?,
        timeoutMilliseconds _: Int
    ) async throws -> MCPRawToolCallResult {
        throw MCPTaskRuntimeError.capabilityMissing
    }
}

/// Creates an unstarted client for one exact generation. Process launch or
/// network I/O belongs in `startup`, after control-plane admission succeeds.
public protocol MCPConnectionClientFactory: Sendable {
    func makeClient(
        identity: MCPConnectionReuseIdentity,
        generation: MCPConnectionGeneration
    ) throws -> any MCPConnectionClient
}

/// One real client generation and its revocation/catalog fences.
public actor MCPManagedConnection {
    public nonisolated let reuseIdentity: MCPConnectionReuseIdentity
    public nonisolated let generation: MCPConnectionGeneration

    private let client: any MCPConnectionClient
    private var lifecycle: MCPConnectionLifecycleState = .allocated
    private var revocationGeneration: MCPRevocationGeneration
    private var negotiatedProtocolVersion: MCPNegotiatedProtocolVersion?
    private var negotiatedCapabilities: MCPNegotiatedCapabilitySet = .none
    private var catalog: MCPCompleteCatalogSnapshot?
    private var instructions:
        MCPExternalServerInstructions?
    private var unavailableCatalogKinds: Set<MCPCatalogChangeKind> = []

    init(
        reuseIdentity: MCPConnectionReuseIdentity,
        generation: MCPConnectionGeneration,
        revocationGeneration: MCPRevocationGeneration,
        client: any MCPConnectionClient
    ) {
        self.reuseIdentity = reuseIdentity
        self.generation = generation
        self.revocationGeneration = revocationGeneration
        self.client = client
    }

    @discardableResult
    public func startup() async throws -> MCPConnectionStartupResult {
        guard reuseIdentity.authority.hasCurrentExecutionAuthority else {
            throw MCPConnectionError.authorityMismatch
        }
        guard lifecycle == .allocated else {
            if lifecycle == .ready,
               let negotiatedProtocolVersion,
               let catalog {
                guard await client.isOpen() else {
                    throw MCPConnectionError.clientClosed(generation)
                }
                return MCPConnectionStartupResult(
                    negotiatedProtocolVersion: negotiatedProtocolVersion,
                    negotiatedCapabilities: negotiatedCapabilities,
                    catalog: catalog,
                    instructions: instructions)
            }
            throw MCPConnectionError.invalidLifecycle(
                generation: generation,
                state: lifecycle)
        }

        let startupRevocation = revocationGeneration
        lifecycle = .starting
        lifecycle = .initializing

        do {
            let result = try await client.startup(
                profile: reuseIdentity.authority.protocolProfile,
                maximumProtocolVersion:
                    reuseIdentity.authority.maximumProtocolVersion)

            guard lifecycle == .initializing,
                  revocationGeneration == startupRevocation else {
                await client.shutdownAndDrain(
                    reason: "MCP startup generation retired before publication")
                throw MCPConnectionError.generationRetired(generation)
            }

            guard Self.isValid(
                selected: result.negotiatedProtocolVersion.value,
                maximum:
                    reuseIdentity.authority.maximumProtocolVersion) else {
                lifecycle = .failed
                throw MCPConnectionError.invalidNegotiatedProtocolVersion(
                    selected: result.negotiatedProtocolVersion.value,
                    maximum:
                        reuseIdentity.authority.maximumProtocolVersion)
            }
            let validatedInstructions =
                try Self.validatedInstructions(
                    result.instructions,
                    identity: reuseIdentity,
                    generation: generation)

            lifecycle = .discovering
            negotiatedProtocolVersion = result.negotiatedProtocolVersion
            negotiatedCapabilities = result.negotiatedCapabilities
            catalog = result.catalog
            instructions = validatedInstructions
            lifecycle = .ready
            return result
        } catch {
            if lifecycle != .retired && lifecycle != .stopping
                && lifecycle != .closed {
                lifecycle = .failed
                await client.shutdownAndDrain(
                    reason: "MCP connection startup failed")
            }
            throw error
        }
    }

    public func reuseEvaluation(
        requested: MCPConnectionReuseIdentity
    ) async -> MCPConnectionReuseEvaluation {
        var mismatches = Self.identityMismatches(
            current: reuseIdentity,
            requested: requested)

        guard lifecycle == .ready,
              negotiatedProtocolVersion != nil,
              catalog != nil else {
            mismatches.append(.startupIncomplete)
            return MCPConnectionReuseEvaluation(mismatches: mismatches)
        }

        let wasReady = lifecycle == .ready
        let open = await client.isOpen()
        guard wasReady, lifecycle == .ready else {
            mismatches.append(.startupIncomplete)
            return MCPConnectionReuseEvaluation(mismatches: mismatches)
        }
        if !open {
            mismatches.append(.clientClosed)
        }
        return MCPConnectionReuseEvaluation(mismatches: mismatches)
    }

    public func makeSnapshot(
        bindingID: MCPBindingID,
        agentCatalogViewRevision: MCPAgentCatalogViewRevision
    ) async throws -> MCPConnectionSnapshot {
        guard reuseIdentity.authority.hasCurrentExecutionAuthority else {
            throw MCPConnectionError.authorityMismatch
        }
        guard lifecycle == .ready,
              let negotiatedProtocolVersion,
              let catalog else {
            throw MCPConnectionError.invalidLifecycle(
                generation: generation,
                state: lifecycle)
        }
        guard await client.isOpen(), lifecycle == .ready else {
            throw MCPConnectionError.clientClosed(generation)
        }

        let bindingIdentity = MCPBindingIdentity(
            protocolProfile: reuseIdentity.authority.protocolProfile,
            maximumProtocolVersion:
                reuseIdentity.authority.maximumProtocolVersion,
            negotiatedProtocolVersion: negotiatedProtocolVersion,
            server: reuseIdentity.server,
            connectionGeneration: generation,
            rawCatalogRevision: catalog.revision,
            agentCatalogViewRevision: agentCatalogViewRevision,
            bindingID: bindingID,
            revocationGeneration: revocationGeneration)
        let route = MCPPreparedConnectionRoute(
            bindingIdentity: bindingIdentity,
            authorityFingerprint: reuseIdentity.authority.fingerprint,
            catalogFingerprint: catalog.catalogFingerprint,
            connection: self)
        return MCPConnectionSnapshot(
            reuseIdentity: reuseIdentity,
            bindingIdentity: bindingIdentity,
            negotiatedCapabilities: negotiatedCapabilities,
            catalog: catalog,
            route: route,
            serverInstructions:
                try makeInstructionsSnapshot(
                    binding: bindingIdentity),
            unavailableCatalogKinds: unavailableCatalogKinds)
    }

    private func makeInstructionsSnapshot(
        binding: MCPBindingIdentity
    ) throws -> MCPServerInstructionsSnapshot? {
        guard let instructions else { return nil }
        guard instructions.server == binding.server,
              instructions.generation
                == binding.connectionGeneration else {
            throw MCPConnectionError.staleGeneration(
                expected: instructions.generation,
                actual:
                    binding.connectionGeneration)
        }
        let provenance = MCPContentProvenance(
            sourceKind: .prompt,
            server: binding.server,
            connectionGeneration:
                binding.connectionGeneration,
            rawCatalogRevision:
                binding.rawCatalogRevision,
            agentCatalogViewRevision:
                binding.agentCatalogViewRevision,
            bindingID: binding.bindingID,
            protocolProfile:
                binding.protocolProfile,
            maximumProtocolVersion:
                binding.maximumProtocolVersion,
            negotiatedProtocolVersion:
                binding.negotiatedProtocolVersion,
            remoteName:
                "__server_instructions__",
            accountReference:
                reuseIdentity
                    .oauthAccountReference,
            environmentReference:
                reuseIdentity
                    .environmentReference)
        return MCPServerInstructionsSnapshot(
            text: instructions.text,
            provenance: provenance)
    }

    /// Publishes an already-complete catalog in one actor-isolated assignment.
    public func publishCompleteCatalog(
        _ replacement: MCPCompleteCatalogSnapshot,
        expectedGeneration: MCPConnectionGeneration,
        expectedRevocationGeneration: MCPRevocationGeneration,
        resultingUnavailableKinds:
            Set<MCPCatalogChangeKind> = []
    ) throws {
        guard expectedGeneration == generation else {
            throw MCPConnectionError.staleGeneration(
                expected: expectedGeneration,
                actual: generation)
        }
        guard expectedRevocationGeneration == revocationGeneration else {
            throw MCPConnectionError.staleRevocation(
                expected: expectedRevocationGeneration,
                actual: revocationGeneration)
        }
        guard lifecycle == .ready else {
            throw MCPConnectionError.invalidLifecycle(
                generation: generation,
                state: lifecycle)
        }

        lifecycle = .refreshing
        catalog = replacement
        unavailableCatalogKinds = resultingUnavailableKinds
        lifecycle = .ready
    }

    /// Explicit Refresh loader for the retained exact generation. Catalog
    /// staleness intentionally does not block the list operations whose sole
    /// purpose is replacing that stale catalog; every other authority,
    /// generation, revocation, lifecycle, and client-open fence still applies
    /// before and after the complete private staging pass.
    public func discoverCompleteCatalogForRefresh(
        route: MCPPreparedConnectionRoute,
        limits: MCPFullCatalogDiscoveryLimits = .init()
    ) async throws -> MCPCompleteCatalogSnapshot {
        try await revalidate(
            route: route,
            requiredCatalogKind: nil)
        let capabilities = negotiatedCapabilities
        let client = client
        let replacement =
            try await MCPFullCatalogDiscovery.discover(
                capabilities: capabilities,
                limits: limits,
                listToolsPage: {
                    try await client
                        .listToolsPage(cursor: $0)
                },
                listResourcesPage: {
                    try await client
                        .listResourcesPage(cursor: $0)
                },
                listResourceTemplatesPage: {
                    try await client
                        .listResourceTemplatesPage(
                            cursor: $0)
                },
                listPromptsPage: {
                    try await client
                        .listPromptsPage(cursor: $0)
                })
        try await revalidate(
            route: route,
            requiredCatalogKind: nil)
        return replacement
    }

    public func markCatalogStale(
        _ kinds: Set<MCPCatalogChangeKind>,
        expectedGeneration: MCPConnectionGeneration,
        expectedRevocationGeneration: MCPRevocationGeneration
    ) throws {
        guard expectedGeneration == generation else {
            throw MCPConnectionError.staleGeneration(
                expected: expectedGeneration,
                actual: generation)
        }
        guard expectedRevocationGeneration == revocationGeneration else {
            throw MCPConnectionError.staleRevocation(
                expected: expectedRevocationGeneration,
                actual: revocationGeneration)
        }
        guard lifecycle == .ready || lifecycle == .refreshing else {
            throw MCPConnectionError.invalidLifecycle(
                generation: generation,
                state: lifecycle)
        }
        unavailableCatalogKinds.formUnion(kinds)
    }

    public func revalidate(
        route: MCPPreparedConnectionRoute,
        requiredCatalogKind: MCPCatalogChangeKind? = .tools
    ) async throws {
        guard reuseIdentity.authority.hasCurrentExecutionAuthority else {
            throw MCPConnectionError.authorityMismatch
        }
        let binding = route.bindingIdentity
        guard binding.connectionGeneration == generation else {
            throw MCPConnectionError.staleGeneration(
                expected: binding.connectionGeneration,
                actual: generation)
        }
        guard binding.revocationGeneration == revocationGeneration else {
            throw MCPConnectionError.staleRevocation(
                expected: binding.revocationGeneration,
                actual: revocationGeneration)
        }
        guard route.authorityFingerprint
            == reuseIdentity.authority.fingerprint else {
            throw MCPConnectionError.authorityMismatch
        }
        guard binding.rawCatalogRevision == catalog?.revision else {
            throw MCPConnectionError.staleCatalog(
                expected: binding.rawCatalogRevision,
                actual: catalog?.revision)
        }
        guard route.catalogFingerprint == catalog?.catalogFingerprint else {
            throw MCPConnectionError.catalogFingerprintMismatch
        }
        if let requiredCatalogKind,
           unavailableCatalogKinds.contains(requiredCatalogKind) {
            throw MCPConnectionError.catalogKindStale(requiredCatalogKind)
        }
        guard lifecycle == .ready else {
            throw MCPConnectionError.invalidLifecycle(
                generation: generation,
                state: lifecycle)
        }
        let open = await client.isOpen()
        guard open, lifecycle == .ready else {
            throw MCPConnectionError.clientClosed(generation)
        }
    }

    public func listToolsPage(
        route: MCPPreparedConnectionRoute,
        cursor: String?
    ) async throws -> MCPToolListPage {
        try await revalidate(route: route, requiredCatalogKind: .tools)
        return try await client.listToolsPage(cursor: cursor)
    }

    public func listResourcesPage(
        route: MCPPreparedConnectionRoute,
        cursor: String?,
        fence: MCPExternalOperationFence
    ) async throws -> MCPResourceListPage {
        try await beginExternalOperation(
            route: route,
            fence: fence,
            operation: .listResources,
            requiredCatalogKind: .resources)
        let result = try await client.listResourcesPage(cursor: cursor)
        try await finishExternalOperation(
            route: route,
            fence: fence,
            requiredCatalogKind: .resources)
        return result
    }

    public func listResourceTemplatesPage(
        route: MCPPreparedConnectionRoute,
        cursor: String?,
        fence: MCPExternalOperationFence
    ) async throws -> MCPResourceTemplateListPage {
        try await beginExternalOperation(
            route: route,
            fence: fence,
            operation: .listResourceTemplates,
            requiredCatalogKind: .resources)
        let result =
            try await client.listResourceTemplatesPage(
                cursor: cursor)
        try await finishExternalOperation(
            route: route,
            fence: fence,
            requiredCatalogKind: .resources)
        return result
    }

    public func readResource(
        route: MCPPreparedConnectionRoute,
        uri: String,
        fence: MCPExternalOperationFence
    ) async throws -> MCPRawResourceReadResult {
        try await beginExternalOperation(
            route: route,
            fence: fence,
            operation: .readResource,
            requiredCatalogKind: .resources)
        let result = try await client.readResource(uri: uri)
        try await finishExternalOperation(
            route: route,
            fence: fence,
            requiredCatalogKind: .resources)
        return result
    }

    public func subscribeResource(
        route: MCPPreparedConnectionRoute,
        uri: String,
        fence: MCPExternalOperationFence
    ) async throws {
        try await beginExternalOperation(
            route: route,
            fence: fence,
            operation: .subscribeResource,
            requiredCatalogKind: .resources)
        try await client.subscribeResource(uri: uri)
        try await finishExternalOperation(
            route: route,
            fence: fence,
            requiredCatalogKind: .resources)
    }

    public func unsubscribeResource(
        route: MCPPreparedConnectionRoute,
        uri: String,
        fence: MCPExternalOperationFence
    ) async throws {
        try await beginExternalOperation(
            route: route,
            fence: fence,
            operation: .unsubscribeResource,
            requiredCatalogKind: .resources)
        try await client.unsubscribeResource(uri: uri)
        try await finishExternalOperation(
            route: route,
            fence: fence,
            requiredCatalogKind: .resources)
    }

    public func listPromptsPage(
        route: MCPPreparedConnectionRoute,
        cursor: String?
    ) async throws -> MCPPromptListPage {
        try await revalidate(route: route, requiredCatalogKind: .prompts)
        return try await client.listPromptsPage(cursor: cursor)
    }

    public func getPrompt(
        route: MCPPreparedConnectionRoute,
        name: String,
        arguments: [String: String],
        fence: MCPExternalOperationFence
    ) async throws -> MCPRawPromptGetResult {
        try await beginExternalOperation(
            route: route,
            fence: fence,
            operation: .getPrompt,
            requiredCatalogKind: .prompts)
        let result = try await client.getPrompt(
            name: name,
            arguments: arguments)
        try await finishExternalOperation(
            route: route,
            fence: fence,
            requiredCatalogKind: .prompts)
        return result
    }

    public func complete(
        route: MCPPreparedConnectionRoute,
        reference: MCPCompletionReference,
        argumentName: String,
        argumentValue: String,
        context: [String: String],
        fence: MCPExternalOperationFence
    ) async throws -> MCPCompletionResult {
        let requiredKind: MCPCatalogChangeKind
        let operation: MCPExternalOperationKind
        switch reference {
        case .prompt:
            requiredKind = .prompts
            operation = .completePrompt
        case .resource:
            requiredKind = .resources
            operation = .completeResource
        }
        try await beginExternalOperation(
            route: route,
            fence: fence,
            operation: operation,
            requiredCatalogKind: requiredKind)
        let result = try await client.complete(
            reference: reference,
            argumentName: argumentName,
            argumentValue: argumentValue,
            context: context)
        try await finishExternalOperation(
            route: route,
            fence: fence,
            requiredCatalogKind: requiredKind)
        return result
    }

    public func listRemoteTasks(
        route: MCPPreparedConnectionRoute,
        fence: MCPExternalOperationFence
    ) async throws -> [MCPRemoteTaskSnapshot] {
        try await beginExternalOperation(
            route: route,
            fence: fence,
            operation: .listRemoteTasks,
            requiredCatalogKind: nil)
        let result = try await client.listRemoteTasks()
        try await finishExternalOperation(
            route: route,
            fence: fence,
            requiredCatalogKind: nil)
        return result
    }

    public func refreshRemoteTask(
        route: MCPPreparedConnectionRoute,
        taskID: MCPRemoteServerTaskID,
        timeoutMilliseconds: Int? = nil,
        fence: MCPExternalOperationFence
    ) async throws -> MCPRemoteTaskSnapshot {
        try await beginExternalOperation(
            route: route,
            fence: fence,
            operation: .refreshRemoteTask,
            requiredCatalogKind: nil)
        let result = try await client.refreshRemoteTask(
            taskID,
            timeoutMilliseconds: timeoutMilliseconds)
        try await finishExternalOperation(
            route: route,
            fence: fence,
            requiredCatalogKind: nil)
        return result
    }

    public func cancelRemoteTask(
        route: MCPPreparedConnectionRoute,
        taskID: MCPRemoteServerTaskID,
        timeoutMilliseconds: Int? = nil,
        fence: MCPExternalOperationFence
    ) async throws -> MCPRemoteTaskSnapshot {
        try await beginExternalOperation(
            route: route,
            fence: fence,
            operation: .cancelRemoteTask,
            requiredCatalogKind: nil)
        let result = try await client.cancelRemoteTask(
            taskID,
            timeoutMilliseconds: timeoutMilliseconds)
        try await finishExternalOperation(
            route: route,
            fence: fence,
            requiredCatalogKind: nil)
        return result
    }

    public func remoteTaskResult(
        route: MCPPreparedConnectionRoute,
        taskID: MCPRemoteServerTaskID,
        timeoutMilliseconds: Int? = nil,
        fence: MCPExternalOperationFence
    ) async throws -> JSONValue {
        try await beginExternalOperation(
            route: route,
            fence: fence,
            operation: .readRemoteTaskResult,
            requiredCatalogKind: nil)
        let result = try await client.remoteTaskResult(
            taskID,
            timeoutMilliseconds: timeoutMilliseconds)
        try await finishExternalOperation(
            route: route,
            fence: fence,
            requiredCatalogKind: nil)
        return result
    }

    private func beginExternalOperation(
        route: MCPPreparedConnectionRoute,
        fence: MCPExternalOperationFence,
        operation: MCPExternalOperationKind,
        requiredCatalogKind: MCPCatalogChangeKind?
    ) async throws {
        try fence.validateExactRoute(
            identity: reuseIdentity,
            binding: route.bindingIdentity)
        guard fence.request.operation == operation else {
            throw MCPConnectionError.authorityMismatch
        }
        try await fence.verifyBeforeRequest()
        try await revalidate(
            route: route,
            requiredCatalogKind: requiredCatalogKind)
    }

    private func finishExternalOperation(
        route: MCPPreparedConnectionRoute,
        fence: MCPExternalOperationFence,
        requiredCatalogKind: MCPCatalogChangeKind?
    ) async throws {
        try await revalidate(
            route: route,
            requiredCatalogKind: requiredCatalogKind)
        try await fence.verifyBeforePublication()
    }

    public func notifyRootsChanged(
        route: MCPPreparedConnectionRoute
    ) async throws {
        try await revalidate(route: route, requiredCatalogKind: nil)
        try await client.notifyRootsChanged()
    }

    public func callTool(
        route: MCPPreparedConnectionRoute,
        remoteName: String,
        arguments: [String: JSONValue]
    ) async throws -> MCPRawToolCallResult {
        try await revalidate(route: route)
        return try await client.callTool(
            name: remoteName,
            arguments: arguments)
    }

    public func callToolResolved(
        route: MCPPreparedConnectionRoute,
        remoteName: String,
        arguments: [String: JSONValue],
        toolTaskSupport: MCPToolTaskSupport?,
        preference: MCPTaskInvocationPreference,
        ttlMilliseconds: Int?,
        originatingToolCallID: String?,
        timeoutMilliseconds: Int
    ) async throws -> MCPRawToolCallResult {
        try await revalidate(route: route)
        let decision = try MCPTaskAugmentationPolicy.decide(
            profile: reuseIdentity.authority.protocolProfile,
            serverSupportsToolCallTasks:
                negotiatedCapabilities.remoteTaskToolCall,
            toolTaskSupport: toolTaskSupport,
            preference: preference,
            requestedTTLMilliseconds: ttlMilliseconds)
        switch decision {
        case .ordinary:
            return try await client.callTool(
                name: remoteName,
                arguments: arguments)
        case .task(let ttl):
            return try await client.callToolTaskAugmentedAndAwait(
                name: remoteName,
                arguments: arguments,
                ttlMilliseconds: ttl,
                originatingToolCallID: originatingToolCallID,
                timeoutMilliseconds: timeoutMilliseconds)
        }
    }

    public func lifecycleSnapshot() async -> MCPConnectionLifecycleSnapshot {
        let open: Bool
        switch lifecycle {
        case .ready, .refreshing:
            open = await client.isOpen()
        default:
            open = false
        }
        return MCPConnectionLifecycleSnapshot(
            generation: generation,
            state: lifecycle,
            revocationGeneration: revocationGeneration,
            negotiatedProtocolVersion: negotiatedProtocolVersion,
            rawCatalogRevision: catalog?.revision,
            clientOpen: open)
    }

    public func retire(
        to replacementRevocationGeneration: MCPRevocationGeneration? = nil,
        reason: String
    ) async {
        if let replacementRevocationGeneration {
            revocationGeneration = replacementRevocationGeneration
        }
        guard lifecycle != .retired && lifecycle != .closed else { return }
        lifecycle = .retired
        await client.shutdownAndDrain(reason: reason)
    }

    public func shutdownAndDrain(reason: String) async {
        guard lifecycle != .closed else { return }
        if lifecycle != .retired {
            lifecycle = .stopping
        }
        await client.shutdownAndDrain(reason: reason)
        lifecycle = .closed
    }

    private static func identityMismatches(
        current: MCPConnectionReuseIdentity,
        requested: MCPConnectionReuseIdentity
    ) -> [MCPConnectionReuseMismatch] {
        var result: [MCPConnectionReuseMismatch] = []
        if current.server.serverID != requested.server.serverID {
            result.append(.serverIdentity)
        }
        if current.server.serverRevision
            != requested.server.serverRevision {
            result.append(.serverConfigurationRevision)
        }
        if current.transport != requested.transport {
            result.append(.transport)
        }
        if current.transportConfigurationFingerprint
            != requested.transportConfigurationFingerprint {
            result.append(.transportConfiguration)
        }
        if current.authority != requested.authority {
            result.append(.authority)
        }
        if current.oauthAccountReference
            != requested.oauthAccountReference {
            result.append(.oauthAccount)
        }
        if current.environmentReference
            != requested.environmentReference {
            result.append(.environment)
        }
        if current.launchArtifactFingerprint
            != requested.launchArtifactFingerprint {
            result.append(.launchArtifact)
        }
        if current.runtimeIdentityFingerprint
            != requested.runtimeIdentityFingerprint {
            result.append(.runtimeIdentity)
        }
        return result
    }

    private static func validatedInstructions(
        _ instructions:
            MCPExternalServerInstructions?,
        identity: MCPConnectionReuseIdentity,
        generation: MCPConnectionGeneration
    ) throws -> MCPExternalServerInstructions? {
        guard let instructions else {
            return nil
        }
        guard instructions.server
                == identity.server,
              instructions.generation
                == generation else {
            throw MCPConnectionError
                .authorityMismatch
        }
        let maximumBytes = 64 * 1_024
        guard instructions.text.utf8.count
                <= maximumBytes else {
            throw MCPContentOperationError
                .contentTooLarge(
                    maximum: maximumBytes)
        }
        let sanitized =
            try MCPConservativeToolResultSanitizer()
                .sanitizeMCPText(
                    instructions.text)
        guard sanitized.utf8.count
                <= maximumBytes else {
            throw MCPContentOperationError
                .contentTooLarge(
                    maximum: maximumBytes)
        }
        return MCPExternalServerInstructions(
            server: instructions.server,
            generation:
                instructions.generation,
            text: sanitized)
    }

    private static func isValid(
        selected: MCPProtocolVersion,
        maximum: MCPProtocolVersion
    ) -> Bool {
        guard isISODateVersion(selected.rawValue),
              isISODateVersion(maximum.rawValue) else {
            return false
        }
        return selected.rawValue <= maximum.rawValue
    }

    private static func isISODateVersion(_ value: String) -> Bool {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              pieces[0].count == 4,
              pieces[1].count == 2,
              pieces[2].count == 2,
              pieces.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let month = Int(pieces[1]),
              let day = Int(pieces[2]),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return false
        }
        return true
    }
}

public struct MCPConnectionAcquisition: Sendable {
    public let connection: MCPManagedConnection
    public let generation: MCPConnectionGeneration
    public let reused: Bool
    public let replacementReasons: [MCPConnectionReuseMismatch]

    init(
        connection: MCPManagedConnection,
        generation: MCPConnectionGeneration,
        reused: Bool,
        replacementReasons: [MCPConnectionReuseMismatch]
    ) {
        self.connection = connection
        self.generation = generation
        self.reused = reused
        self.replacementReasons = replacementReasons
    }
}

public struct MCPConnectionPoolShutdownReport: Equatable, Sendable {
    public let drainedGenerations: [MCPConnectionGeneration]

    public init(drainedGenerations: [MCPConnectionGeneration]) {
        self.drainedGenerations = drainedGenerations.sorted {
            $0.rawValue < $1.rawValue
        }
    }
}

/// Session-owned, authority-keyed connection pool.
public actor MCPConnectionPool {
    public nonisolated let sessionID: SessionID

    private var acceptingConnections = true
    private var currentByAuthority:
        [MCPAuthorityPoolKey: MCPConnectionGeneration] = [:]
    private var allByGeneration:
        [MCPConnectionGeneration: MCPManagedConnection] = [:]

    public init(sessionID: SessionID) {
        self.sessionID = sessionID
    }

    public func acquire(
        identity: MCPConnectionReuseIdentity,
        revocationGeneration: MCPRevocationGeneration,
        factory: any MCPConnectionClientFactory
    ) async throws -> MCPConnectionAcquisition {
        guard acceptingConnections else {
            throw MCPConnectionError.poolStopped
        }
        // Schema-v1 authorities remain decodable for audit/replay only. They
        // did not bind the exact capability task, complete workspace policy,
        // or effective sandbox policy and therefore can never open or reuse a
        // live server generation.
        guard identity.authority.hasCurrentExecutionAuthority else {
            throw MCPConnectionError.authorityMismatch
        }
        guard identity.authority.sessionID == sessionID else {
            throw MCPConnectionError.wrongSession(
                expected: sessionID,
                actual: identity.authority.sessionID)
        }

        let key = identity.poolKey
        while true {
            let observedGeneration = currentByAuthority[key]
            var replacementReasons: [MCPConnectionReuseMismatch] = []

            if let observedGeneration,
               let existing = allByGeneration[observedGeneration] {
                let evaluation = await existing.reuseEvaluation(
                    requested: identity)
                guard currentByAuthority[key] == observedGeneration else {
                    continue
                }
                if evaluation.canReuse {
                    return MCPConnectionAcquisition(
                        connection: existing,
                        generation: observedGeneration,
                        reused: true,
                        replacementReasons: [])
                }
                replacementReasons = evaluation.mismatches
            }

            let generation = MCPConnectionGeneration.new()
            let client = try factory.makeClient(
                identity: identity,
                generation: generation)
            let connection = MCPManagedConnection(
                reuseIdentity: identity,
                generation: generation,
                revocationGeneration: revocationGeneration,
                client: client)
            let replacedGeneration = currentByAuthority.updateValue(
                generation,
                forKey: key)
            allByGeneration[generation] = connection

            if let replacedGeneration,
               replacedGeneration != generation,
               let replaced = allByGeneration[replacedGeneration] {
                await replaced.retire(
                    reason: "MCP exact reuse predicate did not match")
            }

            guard currentByAuthority[key] == generation else {
                await connection.retire(
                    reason: "MCP connection lost concurrent pool generation race")
                throw MCPConnectionError.generationSuperseded(generation)
            }
            return MCPConnectionAcquisition(
                connection: connection,
                generation: generation,
                reused: false,
                replacementReasons: replacementReasons)
        }
    }

    public func confirmCurrentReady(
        _ acquisition: MCPConnectionAcquisition
    ) async throws {
        let key = acquisition.connection.reuseIdentity.poolKey
        guard currentByAuthority[key] == acquisition.generation else {
            await acquisition.connection.retire(
                reason: "MCP connection was superseded before ready publication")
            throw MCPConnectionError.generationSuperseded(
                acquisition.generation)
        }
        let lifecycle = await acquisition.connection.lifecycleSnapshot()
        guard lifecycle.state == .ready, lifecycle.clientOpen else {
            throw MCPConnectionError.invalidLifecycle(
                generation: acquisition.generation,
                state: lifecycle.state)
        }
    }

    public func connection(
        generation: MCPConnectionGeneration
    ) -> MCPManagedConnection? {
        allByGeneration[generation]
    }

    public func makeCurrentSnapshot(
        identity: MCPConnectionReuseIdentity,
        generation: MCPConnectionGeneration,
        bindingID: MCPBindingID,
        agentCatalogViewRevision:
            MCPAgentCatalogViewRevision
    ) async throws -> MCPConnectionSnapshot {
        guard acceptingConnections else {
            throw MCPConnectionError.poolStopped
        }
        guard let connection =
                allByGeneration[generation],
              connection.reuseIdentity == identity,
              currentByAuthority[identity.poolKey]
                == generation else {
            throw MCPConnectionError
                .generationSuperseded(generation)
        }
        return try await connection.makeSnapshot(
            bindingID: bindingID,
            agentCatalogViewRevision:
                agentCatalogViewRevision)
    }

    public func publishCompleteCatalog(
        _ catalog: MCPCompleteCatalogSnapshot,
        generation: MCPConnectionGeneration,
        expectedRevocationGeneration: MCPRevocationGeneration,
        resultingUnavailableKinds:
            Set<MCPCatalogChangeKind> = []
    ) async throws {
        guard acceptingConnections else {
            throw MCPConnectionError.poolStopped
        }
        guard let connection = allByGeneration[generation] else {
            throw MCPConnectionError.generationNotFound(generation)
        }
        let key = connection.reuseIdentity.poolKey
        guard currentByAuthority[key] == generation else {
            throw MCPConnectionError.generationSuperseded(generation)
        }
        try await connection.publishCompleteCatalog(
            catalog,
            expectedGeneration: generation,
            expectedRevocationGeneration: expectedRevocationGeneration,
            resultingUnavailableKinds: resultingUnavailableKinds)
    }

    public func markCatalogStale(
        _ kinds: Set<MCPCatalogChangeKind>,
        generation: MCPConnectionGeneration,
        expectedRevocationGeneration: MCPRevocationGeneration
    ) async throws {
        guard acceptingConnections else {
            throw MCPConnectionError.poolStopped
        }
        guard let connection = allByGeneration[generation] else {
            throw MCPConnectionError.generationNotFound(generation)
        }
        let key = connection.reuseIdentity.poolKey
        guard currentByAuthority[key] == generation else {
            throw MCPConnectionError.generationSuperseded(generation)
        }
        try await connection.markCatalogStale(
            kinds,
            expectedGeneration: generation,
            expectedRevocationGeneration: expectedRevocationGeneration)
    }

    public func revoke(
        authorityKey: MCPAuthorityPoolKey,
        to revocationGeneration: MCPRevocationGeneration,
        reason: String
    ) async {
        currentByAuthority.removeValue(forKey: authorityKey)
        let targets = allByGeneration.values.filter {
            $0.reuseIdentity.poolKey == authorityKey
        }
        await withTaskGroup(of: Void.self) { group in
            for connection in targets {
                group.addTask {
                    await connection.retire(
                        to: revocationGeneration,
                        reason: reason)
                }
            }
        }
    }

    public func retire(
        generation: MCPConnectionGeneration,
        reason: String
    ) async {
        guard let connection = allByGeneration[generation] else { return }
        let key = connection.reuseIdentity.poolKey
        if currentByAuthority[key] == generation {
            currentByAuthority.removeValue(forKey: key)
        }
        await connection.retire(reason: reason)
    }

    public func currentGeneration(
        for authorityKey: MCPAuthorityPoolKey
    ) -> MCPConnectionGeneration? {
        currentByAuthority[authorityKey]
    }

    public func allGenerations() -> [MCPConnectionGeneration] {
        allByGeneration.keys.sorted { $0.rawValue < $1.rawValue }
    }

    /// All currently ready authority slots, including multiple Agents
    /// attached to the same server revision. This is an observation snapshot;
    /// it never collapses by server ID.
    public func liveConnectionSnapshots()
        async -> [MCPConnectionSnapshot]
    {
        let generations = Set(
            currentByAuthority.values).sorted {
                $0.rawValue < $1.rawValue
            }
        var result: [MCPConnectionSnapshot] = []
        result.reserveCapacity(generations.count)
        for generation in generations {
            guard let connection =
                    allByGeneration[generation]
            else { continue }
            let digest =
                MCPConfigurationCanonical.sha256(
                    Data([
                        connection.reuseIdentity
                            .authority.fingerprint,
                        generation.rawValue,
                    ].joined(separator: "\u{1f}").utf8))
            if let snapshot = try? await connection
                .makeSnapshot(
                    bindingID: .new(),
                    agentCatalogViewRevision:
                        MCPAgentCatalogViewRevision(
                            rawValue:
                                "mcpcatalogview_live_"
                                    + digest.prefix(24)))
            {
                result.append(snapshot)
            }
        }
        return result.sorted {
            if $0.reuseIdentity.authority.agentID
                != $1.reuseIdentity.authority.agentID {
                return $0.reuseIdentity.authority.agentID
                    .rawValue
                    < $1.reuseIdentity.authority.agentID
                        .rawValue
            }
            if $0.reuseIdentity.server.serverID
                != $1.reuseIdentity.server.serverID {
                return $0.reuseIdentity.server.serverID
                    .rawValue
                    < $1.reuseIdentity.server.serverID
                        .rawValue
            }
            return $0.bindingIdentity
                .connectionGeneration.rawValue
                < $1.bindingIdentity
                    .connectionGeneration.rawValue
        }
    }

    @discardableResult
    public func shutdownAndDrain(
        reason: String
    ) async -> MCPConnectionPoolShutdownReport {
        acceptingConnections = false
        currentByAuthority.removeAll()
        let connections = Array(allByGeneration.values)
        let generations = connections.map(\.generation)
        await withTaskGroup(of: Void.self) { group in
            for connection in connections {
                group.addTask {
                    await connection.shutdownAndDrain(reason: reason)
                }
            }
        }
        return MCPConnectionPoolShutdownReport(
            drainedGenerations: generations)
    }
}
