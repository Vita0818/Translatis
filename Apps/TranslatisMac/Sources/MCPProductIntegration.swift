#if canImport(SwiftUI)
import AppKit
import Combine
import Foundation
import IntatisAgentKernel
import IntatisArtifacts
import IntatisConversation
import IntatisCore
import IntatisMCP
import IntatisProtocol
import IntatisSharedUI
import IntatisCodexRuntime
import SwiftUI
import IntatisMCPStdio

private struct MCPRejectingTestEventSink: MCPBrokerEventSink {
    func appendMCPBrokerEvent(_ event: Event) async throws {
        throw MCPTaskRuntimeError.persistenceFailed
    }

    func appendMCPBrokerEvents(_ events: [Event]) async throws {
        throw MCPTaskRuntimeError.persistenceFailed
    }
}

enum MCPServerEditorTransport: String, CaseIterable, Identifiable {
    case streamableHTTP
    case stdio

    var id: String { rawValue }
}

enum MCPServerEditorFileRole: String, CaseIterable, Identifiable {
    case executable
    case interpreter
    case script
    case packageEntrypoint
    case lockfile
    case helper

    var id: String { rawValue }

    var protocolRole: MCPLaunchFileRole {
        switch self {
        case .executable: return .executable
        case .interpreter: return .interpreter
        case .script: return .script
        case .packageEntrypoint: return .packageEntrypoint
        case .lockfile: return .lockfile
        case .helper: return .helper
        }
    }
}

struct MCPServerEditorKeyValue: Identifiable {
    let id: UUID
    var name: String
    var value: String
    var storesAsSecret: Bool
    var existingSecretReference: MCPSecretReference?

    init(
        id: UUID = UUID(),
        name: String = "",
        value: String = "",
        storesAsSecret: Bool = false,
        existingSecretReference:
            MCPSecretReference? = nil
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.storesAsSecret = storesAsSecret
        self.existingSecretReference =
            existingSecretReference
    }
}

struct MCPServerEditorLaunchFile: Identifiable {
    let id: UUID
    var role: MCPServerEditorFileRole
    var path: String

    init(
        id: UUID = UUID(),
        role: MCPServerEditorFileRole,
        path: String = ""
    ) {
        self.id = id
        self.role = role
        self.path = path
    }
}

struct MCPServerEditorToolApproval: Identifiable {
    let id: UUID
    var toolName: String
    var mode: MCPApprovalMode

    init(
        id: UUID = UUID(),
        toolName: String = "",
        mode: MCPApprovalMode = .prompt
    ) {
        self.id = id
        self.toolName = toolName
        self.mode = mode
    }
}

struct MCPServerEditorDraft: Identifiable {
    let id = UUID()
    var originalServerID: MCPServerID?
    var alias = ""
    var displayName = ""
    var enabled = true
    var required = false
    var requiredCapabilities:
        Set<MCPGrantedCapability> = []
    var protocolProfile = MCPProtocolProfile.codexCompat
    var maximumProtocolVersion =
        MCPProtocolVersion.v2025_11_25.rawValue
    var approvalMode = MCPApprovalMode.prompt
    var toolApprovalOverrides:
        [MCPServerEditorToolApproval] = []
    var environmentID = "mcpenv_app_default"
    var parallelCalls = false
    var startupMilliseconds = 30_000
    var callMilliseconds = 60_000
    var shutdownMilliseconds = 5_000

    var toolAllow = ""
    var toolDeny = ""
    var resourceAllow = ""
    var resourceDeny = ""
    var promptAllow = ""
    var promptDeny = ""
    var completionAllow = ""
    var completionDeny = ""

    var transport = MCPServerEditorTransport.streamableHTTP
    var endpoint = "https://"
    var headers: [MCPServerEditorKeyValue] = []
    var bearerEnabled = false
    var bearerToken = ""
    var existingBearerTokenReference:
        MCPSecretReference?
    var redirectPolicy =
        MCPHTTPRedirectPolicy.sameOriginOnly
    var proxyPolicy = MCPHTTPProxyPolicy.direct
    var tlsPublicKeyPins = ""
    var allowInsecureLoopbackDevelopmentHTTP =
        false
    var oauthEnabled = false
    var oauthResource = "https://"
    var oauthClientID = ""
    var oauthClientSecretEnabled = false
    var oauthClientSecret = ""
    var existingOAuthClientSecretReference:
        MCPSecretReference?
    var oauthScopes = ""
    var oauthAccountReference = ""

    var launchFiles: [MCPServerEditorLaunchFile] = [
        .init(role: .executable),
    ]
    var arguments = ""
    var workingDirectory = ""
    var environment: [MCPServerEditorKeyValue] = []
    var inheritedEnvironment:
        [MCPServerEditorKeyValue] = []
    var networkOrigins = ""

    var isEditing: Bool { originalServerID != nil }

    static func new(
        supportsStdio: Bool
    ) -> MCPServerEditorDraft {
        var value = MCPServerEditorDraft()
        value.transport = supportsStdio
            ? .streamableHTTP
            : .streamableHTTP
        return value
    }

    static func editing(
        alias: String,
        definition: MCPServerDefinition
    ) -> MCPServerEditorDraft {
        let configuration = definition.configuration
        var value = MCPServerEditorDraft()
        value.originalServerID = configuration.serverID
        value.alias = alias
        value.displayName = configuration.displayName
        value.enabled = configuration.enabled
        value.required = configuration.required
        value.requiredCapabilities = Set(
            configuration.requiredCapabilities)
        value.protocolProfile =
            configuration.protocolProfile
        value.maximumProtocolVersion =
            configuration.maximumProtocolVersion.rawValue
        value.approvalMode =
            configuration.approvalPolicy.serverDefault
        value.toolApprovalOverrides =
            configuration.approvalPolicy.toolOverrides
                .sorted { $0.key < $1.key }
                .map {
                    MCPServerEditorToolApproval(
                        toolName: $0.key,
                        mode: $0.value)
                }
        value.environmentID =
            configuration.environmentReference.rawValue
        value.parallelCalls = configuration.parallelCalls
        value.startupMilliseconds =
            configuration.timeouts.startupMilliseconds
        value.callMilliseconds =
            configuration.timeouts.callMilliseconds
        value.shutdownMilliseconds =
            configuration.timeouts.shutdownMilliseconds
        value.toolAllow = Self.lines(
            configuration.filters.tools.allowList)
        value.toolDeny = Self.lines(
            configuration.filters.tools.denyList)
        value.resourceAllow = Self.lines(
            configuration.filters.resources.allowList)
        value.resourceDeny = Self.lines(
            configuration.filters.resources.denyList)
        value.promptAllow = Self.lines(
            configuration.filters.prompts.allowList)
        value.promptDeny = Self.lines(
            configuration.filters.prompts.denyList)
        value.completionAllow = Self.lines(
            configuration.filters.completions.allowList)
        value.completionDeny = Self.lines(
            configuration.filters.completions.denyList)

        switch configuration.transport {
        case .streamableHTTP(let http):
            value.transport = .streamableHTTP
            value.endpoint = http.endpoint
            value.headers = http.headers.map {
                key, configured in
                switch configured {
                case .literal(let literal):
                    return MCPServerEditorKeyValue(
                        name: key,
                        value: literal)
                case .secret(let reference):
                    return MCPServerEditorKeyValue(
                        name: key,
                        storesAsSecret: true,
                        existingSecretReference: reference)
                }
            }.sorted { $0.name < $1.name }
            value.existingBearerTokenReference =
                http.bearerTokenReference
            value.bearerEnabled =
                http.bearerTokenReference != nil
            value.redirectPolicy = http.redirectPolicy
            value.proxyPolicy = http.proxyPolicy
            if case .pinnedPublicKeySHA256(let pins) =
                    http.tlsPolicy {
                value.tlsPublicKeyPins =
                    pins.joined(separator: "\n")
            }
            value.allowInsecureLoopbackDevelopmentHTTP =
                http.allowInsecureLoopbackDevelopmentHTTP
            if let oauth = http.oauth {
                value.oauthEnabled = oauth.enabled
                value.oauthResource =
                    oauth.canonicalResource
                value.oauthClientID = oauth.clientID ?? ""
                value.existingOAuthClientSecretReference =
                    oauth.clientSecretReference
                value.oauthClientSecretEnabled =
                    oauth.clientSecretReference != nil
                value.oauthScopes =
                    oauth.scopes.joined(separator: "\n")
                value.oauthAccountReference =
                    oauth.accountReference?.rawValue ?? ""
            }
        case .stdio(let stdio):
            value.transport = .stdio
            value.launchFiles = (
                stdio.launchArtifact.files
                    + stdio.helperArtifacts.flatMap(\.files)
            ).map {
                file in
                MCPServerEditorLaunchFile(
                    role: Self.editorRole(file.role),
                    path: file.resolvedSymlinkPath
                        ?? file.canonicalPath)
            }
            value.arguments =
                stdio.arguments.joined(separator: "\n")
            value.workingDirectory =
                stdio.workingDirectory ?? ""
            value.environment = stdio.environment.map {
                key, configured in
                switch configured {
                case .literal(let literal):
                    return MCPServerEditorKeyValue(
                        name: key,
                        value: literal)
                case .secret(let reference):
                    return MCPServerEditorKeyValue(
                        name: key,
                        storesAsSecret: true,
                        existingSecretReference: reference)
                }
            }.sorted { $0.name < $1.name }
            value.inheritedEnvironment =
                stdio.inheritedEnvironmentReferences.map {
                    name, reference in
                    MCPServerEditorKeyValue(
                        name: name,
                        storesAsSecret: true,
                        existingSecretReference:
                            reference)
                }.sorted { $0.name < $1.name }
            if case .exactOrigins(let origins) =
                    stdio.networkPolicy {
                value.networkOrigins =
                    origins.joined(separator: "\n")
            }
        }
        return value
    }

    static func entries(
        _ text: String
    ) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map {
                $0.trimmingCharacters(
                    in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    private static func lines(
        _ values: [String]?
    ) -> String {
        values?.joined(separator: "\n") ?? ""
    }

    private static func lines(
        _ values: [String]
    ) -> String {
        values.joined(separator: "\n")
    }

    private static func editorRole(
        _ role: MCPLaunchFileRole
    ) -> MCPServerEditorFileRole {
        switch role {
        case .executable: return .executable
        case .interpreter: return .interpreter
        case .script: return .script
        case .packageEntrypoint: return .packageEntrypoint
        case .lockfile: return .lockfile
        case .helper: return .helper
        }
    }
}

/// Frozen editor transaction. The prepared plan owns the exact predicted
/// revision/catalog CAS challenge; `createdSecrets` are removed unless that
/// same plan commits successfully.
struct MCPServerEditorPreparedSession: Sendable {
    let prepared: MCPPreparedServerConfiguration
    let createdSecrets: [MCPSecretReference]
}

struct MCPProductLiveConnection: Identifiable, Sendable {
    let id: String
    let sessionID: SessionID
    let agentID: AgentID
    let publishedAt: Date
    let connection: MCPConnectionSnapshot
}

struct MCPProductRuntimeObservation: Sendable {
    let sessionID: SessionID
    /// Complete current ready-authority set from the session owner. This is
    /// not the owner's latest per-Agent publication, which would lose other
    /// Agents in the same Cowork session.
    let connections: [MCPConnectionSnapshot]
    let metrics: MCPMetricsSnapshot
    let diagnostics: [MCPDiagnosticSummary]
    let observedAt: Date
}

private struct MCPAppServerReferenceUsageSource:
    MCPServerReferenceDurableUsageSource, Sendable
{
    let root: URL

    func durableSessionIDs(
        referencing reference: MCPServerReference
    ) async throws -> [SessionID] {
        let summaries =
            SessionActivityHistoryStore.recentSessions(
                root: root,
                kind: .code)
            + SessionActivityHistoryStore.recentSessions(
                root: root,
                kind: .cowork)
        var matches: [SessionID] = []
        for summary in summaries {
            try Task.checkCancellation()
            let log = try EventLog(
                session: summary.id,
                fileURL: SessionHistoryStore.sessionFile(
                    root: root,
                    session: summary.id))
            let state =
                try await MCPDurableSessionState
                    .load(from: log)
            if state.attachments.values.contains(
                where: { $0.server == reference })
            {
                matches.append(summary.id)
            }
        }
        return Array(Set(matches)).sorted {
            $0.rawValue < $1.rawValue
        }
    }
}

@MainActor
final class AppMCPService: ObservableObject {
    @Published private(set) var inventory:
        [MCPServerInventoryRecord] = []
    @Published private(set) var doctorFindings:
        [MCPDoctorFinding] = []
    @Published private(set) var oauthAccounts:
        [MCPAppOAuthAccountSummary] = []
    @Published private(set) var liveConnections:
        [String: MCPProductLiveConnection] = [:]
    @Published private(set) var runtimeObservations:
        [SessionID: MCPProductRuntimeObservation] = [:]
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?
    @Published var lastResult: String?

    let hostProfile: MCPProductHostProfile
    let secretStore: MCPKeychainSecretStore
    let management: MCPManagementService
    let interactionCenter: MCPInteractionCenter
    let oauthCoordinator: MCPAppOAuthCoordinator
    let catalogStore: MCPServerCatalogStore

    private let oauthAccountsStore: MCPAppOAuthAccountStore
    private let resolveSecret: MCPProductionSecretResolver
    private let stdioTransportBuilder:
        MCPProductionStdioTransportBuilder

    init() {
        hostProfile = .macDeveloperID
        let support = AppConfig.appSupportDir()
        let precommitVerifier:
            any MCPPreparedDefinitionPrecommitVerifier =
                MCPStdioPreparedDefinitionPrecommitVerifier()
        catalogStore = MCPServerCatalogStore(
            fileURL: support.appendingPathComponent(
                MCPServerCatalogStore.fileName),
            precommitVerifier: precommitVerifier)
        let journal = MCPCatalogOperationJournalStore(
            fileURL: support.appendingPathComponent(
                MCPCatalogOperationJournalStore.fileName))
        let secrets = MCPKeychainSecretStore()
        secretStore = secrets
        let resolve: MCPProductionSecretResolver = {
            try await secrets.resolve($0)
        }
        resolveSecret = resolve
        interactionCenter = MCPInteractionCenter()
        let accounts = MCPAppOAuthAccountStore(
            fileURL: support.appendingPathComponent(
                MCPAppOAuthAccountStore.fileName))
        oauthAccountsStore = accounts
        let oauthHost = MCPAppOAuthCoordinator(
            secretStore: secrets,
            accounts: accounts,
            revocationHandler: { reference, _ in
                try await MCPProcessCatalogRuntimeRegistry.shared
                    .revokeCredentialAuthority(reference)
            })
        oauthCoordinator = oauthHost
        let buildOAuth = oauthHost.providerBuilder()
        let payloads = MCPSecretBackedBrokerPayloadStore(
            secretStore: secrets)
        let testServices:
            MCPProductionConnectionServicesProvider = {
                _, _, _ in
                MCPProductionConnectionServices(
                    remoteTaskServices:
                        MCPProductionRemoteTaskServices(
                            events: MCPRejectingTestEventSink(),
                            payloadStore: payloads))
            }
        let testOutputRedactor =
            MCPResolvedSecretRedactor()

        let issuer = MCPStdioLaunchTicketIssuer {
            request in
            guard request.purpose == .isolatedTest else {
                throw MCPManagedPipeError
                    .authorizationBindingMismatch
            }
            let environment =
                try await MCPStdioEnvironmentResolver.resolve(
                    request.configuration,
                    secretResolver: resolve)
            return MCPStdioHostAuthorization(
                decisionID:
                    IDGen.random(prefix: "mcpdecision"),
                operationID: request.operationID,
                authorityFingerprint:
                    request.authority.fingerprint,
                launchArtifactFingerprint:
                    request.configuration.launchArtifact
                        .fingerprint,
                workspaceLeaseID:
                    request.workspaceLease.id,
                expiresAt:
                    Date().addingTimeInterval(30),
                resolvedEnvironment: environment)
        }
        let stdioFactory =
            MCPManagedStdioProductionFactory(
                ticketIssuer: issuer,
                secretRedactionRegistrar:
                    testOutputRedactor
            ) { definition, identity, _ in
                try MCPIsolatedTestWorkspace.context(
                    definition: definition,
                    identity: identity)
            }
        stdioTransportBuilder =
            stdioFactory.transportBuilder()
        let tester = MCPProductionConfigurationTester(
            hostProfile: .macDeveloperID,
            clientVersion: ProcessInfo.processInfo.processName,
            resolveSecret: resolve,
            secretRedactionRegistrar:
                testOutputRedactor,
            outputSanitizer:
                testOutputRedactor,
            buildStdio: stdioTransportBuilder,
            buildOAuth: buildOAuth,
            services: testServices,
            testWorkspace: {
                try MCPIsolatedTestWorkspace.lease(for: $0)
            })
        management = MCPManagementService(
            catalogStore: catalogStore,
            testJournal: journal,
            hostProfile: hostProfile,
            testExecutor: { try await tester.run($0) })
        Task { [weak self] in
            await self?.reload()
        }
    }

    func reload() async {
        do {
            async let inventory = management.inventory()
            async let findings = management.doctor()
            async let accounts = oauthCoordinator.summaries()
            self.inventory = try await inventory
            doctorFindings = try await findings
            oauthAccounts = try await accounts
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var oauthProviderBuilder:
        MCPProductionOAuthProviderBuilder
    {
        oauthCoordinator.providerBuilder()
    }

    /// Projects only the exact durable root-Agent authority into Codex's
    /// official native MCP configuration. The resolved secret values remain
    /// request-owned process environment entries; neither this service nor
    /// the runtime writes them into config.toml or EventLog.
    func codexRuntimeConfiguration(
        log: EventLog,
        agentID: AgentID,
        capabilityLeaseID: CapabilityLeaseID,
        taskID: TaskID? = nil
    ) async throws -> CodexRuntimeMCPConfiguration {
        let state = try await MCPDurableSessionState.load(from: log)
        let grants = state.grants(
            agentID: agentID,
            capabilityLeaseID: capabilityLeaseID,
            taskID: taskID)
        guard !MCPReservedControlPlaneIdentity.deniesMCP(agentID) else {
            throw IntatisError.permissionDenied(
                "Control-plane Agents cannot receive native Codex MCP authority.")
        }
        return try await CodexRuntimeMCPProjector.project(
            catalog: try await catalogStore.load(),
            attachments: Array(state.attachments.values),
            grants: grants,
            consents: Array(state.consents.values),
            resolveSecret: resolveSecret)
    }

    func setOAuthRevocationHandler(
        _ handler:
            MCPAppOAuthCoordinator.RevocationHandler?
    ) async {
        await oauthCoordinator.setRevocationHandler(handler)
    }

    func isSignedIn(
        _ record: MCPServerInventoryRecord
    ) -> Bool {
        guard let revision = record.currentRevision else {
            return false
        }
        return oauthAccounts.contains {
            $0.server == MCPServerReference(
                serverID: record.serverID,
                serverRevision: revision)
                && $0.active
        }
    }

    func login(
        _ record: MCPServerInventoryRecord,
        allowDynamicClientRegistration: Bool
    ) async {
        await perform {
            let definition =
                try await self.management.definition(
                    serverOrAlias:
                        record.serverID.rawValue)
            _ = try await self.oauthCoordinator.login(
                definition: definition,
                allowDynamicClientRegistration:
                    allowDynamicClientRegistration,
                present: { [interactionCenter = self.interactionCenter] presentation in
                    await interactionCenter.presentOAuth(
                        presentation)
                })
            return "Signed in to \(record.alias)."
        }
    }

    func logout(
        _ record: MCPServerInventoryRecord
    ) async {
        await perform {
            let definition =
                try await self.management.definition(
                    serverOrAlias:
                        record.serverID.rawValue)
            try await self.oauthCoordinator.logout(
                definition: definition)
            return "Signed out of \(record.alias); matching live connection generations were revoked."
        }
    }

    /// Builds the exact process-owned MCP client runtime used by Code/Cowork.
    ///
    /// Stdio launch tickets are issued by the session PermissionEngine and
    /// WorkspaceLease, not by Settings.
    func makeShippingSessionRuntime(
        sessionID: SessionID,
        log: EventLog,
        artifactStore: ArtifactStore,
        runtimeIdentityFingerprint: String,
        samplingPolicy: MCPSamplingPolicy,
        samplingInference:
            any MCPSamplingInferenceService,
        elicitationPolicy: MCPElicitationPolicy
    ) async throws -> MCPShippingSessionRuntime {
        let outputRedactor =
            MCPResolvedSecretRedactor()
        let baseSecretResolver =
            self.resolveSecret
        let runtimeSecretResolver:
            MCPProductionSecretResolver = {
                reference in
                let value =
                    try await baseSecretResolver(
                        reference)
                outputRedactor
                    .registerMCPSecretRedactionValue(
                        value)
                return value
            }
        let events = MCPEventLogBrokerEventSink(log: log)
        let payloads = MCPSecretBackedBrokerPayloadStore(
            secretStore: secretStore)
        let services = MCPShippingConnectionServicesRegistry(
            events: events,
            payloadStore: payloads,
            sampling: MCPSamplingHostServices(
                policy: samplingPolicy,
                reviewer: MCPAppSamplingReviewService(
                    center: interactionCenter),
                inference: samplingInference),
            elicitation: MCPElicitationHostServices(
                policy: elicitationPolicy,
                reviewer: MCPAppElicitationReviewService(
                    center: interactionCenter)))
        let issuer = MCPStdioLaunchTicketIssuer {
            request in
            guard request.purpose == .sessionConnect,
                  request.authority.sessionID
                    == sessionID,
                  request.workspaceLease.rootIdentity?
                    .matchesCurrentDirectory(
                        rootPath:
                            request.workspaceLease
                                .rootPath)
                    == true else {
                throw MCPManagedPipeError
                    .authorizationBindingMismatch
            }
            let state =
                try await MCPDurableSessionState.load(
                    from: log)
            guard state.attachments.values.contains(
                where: {
                    $0.attachmentID
                        == request.authority
                            .attachmentID
                        && $0.server
                            == request.authority.server
                }) else {
                throw IntatisError.permissionDenied(
                    "The exact MCP stdio attachment is no longer active.")
            }
            let matchingConsents =
                state.consents.values.filter {
                    $0.kind == .launch
                        && $0.server
                            == request.authority.server
                        && $0.attachmentID
                            == request.authority
                                .attachmentID
                        && $0.authorityFingerprint
                            == request.authority
                                .fingerprint
                        && $0.launchArtifactFingerprint
                            == request.configuration
                                .launchArtifact
                                .fingerprint
                        && $0.environmentReference
                            == request.authority
                                .environmentReference
                        && $0.policyRevision
                            == request.authority
                                .attachmentPolicyRevision
                }
            guard matchingConsents.count == 1 else {
                throw IntatisError.permissionDenied(
                    "The exact MCP stdio launch consent is missing or ambiguous.")
            }
            let environment =
                try await MCPStdioEnvironmentResolver
                    .resolve(
                        request.configuration,
                        secretResolver:
                            runtimeSecretResolver)
            return MCPStdioHostAuthorization(
                decisionID:
                    IDGen.random(
                        prefix: "mcpdecision"),
                operationID: request.operationID,
                authorityFingerprint:
                    request.authority.fingerprint,
                launchArtifactFingerprint:
                    request.configuration
                        .launchArtifact.fingerprint,
                workspaceLeaseID:
                    request.workspaceLease.id,
                expiresAt:
                    Date().addingTimeInterval(30),
                resolvedEnvironment: environment)
        }
        let stdioFactory =
            MCPManagedStdioProductionFactory(
                ticketIssuer: issuer,
                secretRedactionRegistrar:
                    outputRedactor
            ) { _, identity, _ in
                guard let lease =
                        services.workspaceLease(
                            matching: identity),
                      lease.rootIdentity?
                        .matchesCurrentDirectory(
                            rootPath:
                                lease.rootPath)
                        == true else {
                    throw IntatisError
                        .permissionDenied(
                            "The exact MCP stdio workspace lease is unavailable.")
                }
                return MCPProductionStdioLaunchContext(
                    purpose: .sessionConnect,
                    workspaceLease: lease)
            }
        let buildStdio:
            MCPProductionStdioTransportBuilder? =
                stdioFactory.transportBuilder()
        let consentHandler =
            MCPAppConnectionConsentHandler(
                log: log,
                catalogStore: catalogStore,
                center: interactionCenter)
        let artifactSink =
            MCPArtifactStoreToolSink(
                store: artifactStore)
        return try await MCPShippingSessionRuntime.make(
            sessionID: sessionID,
            hostProfile: hostProfile,
            clientVersion: ProcessInfo.processInfo.processName,
            runtimeIdentityFingerprint:
                runtimeIdentityFingerprint,
            log: log,
            catalogStore: catalogStore,
            services: services,
            resolveSecret:
                runtimeSecretResolver,
            buildStdio: buildStdio,
            buildOAuth: oauthProviderBuilder,
            consentHandler: consentHandler,
            resultConverter:
                MCPToolResultConverter(
                    sanitizer: outputRedactor,
                    artifactSink: artifactSink),
            resourceConverter:
                MCPResourceContentConverter(
                    sanitizer: outputRedactor,
                    artifactSink: artifactSink),
            outputRedactor: outputRedactor)
    }

    func addHTTP(
        alias: String,
        displayName: String,
        endpoint: String,
        bearerToken: String,
        required: Bool,
        profile: MCPProtocolProfile,
        approvalMode: MCPApprovalMode
    ) async {
        await perform {
            let trimmedSecret = bearerToken.trimmingCharacters(
                in: .whitespacesAndNewlines)
            let secretReference = try await trimmedSecret.isEmpty
                ? nil
                : self.secretStore.store(
                    Data(trimmedSecret.utf8))
            do {
                let configuration =
                    try MCPServerConfiguration(
                        serverID: .new(),
                        displayName: displayName,
                        enabled: true,
                        required: required,
                        protocolProfile: profile,
                        approvalPolicy:
                            MCPApprovalPolicy(
                                serverDefault:
                                    approvalMode),
                        timeouts: MCPServerTimeouts(),
                        filters: MCPServerFilters(),
                        transport: .streamableHTTP(
                            try MCPHTTPServerConfiguration(
                                endpoint: endpoint,
                                bearerTokenReference:
                                    secretReference)),
                        environmentReference:
                            MCPEnvironmentReference(
                                rawValue:
                                    "mcpenv_app_default"),
                        provenance:
                            MCPConfigurationProvenance(
                                sourceKind: .intatisUser,
                                sourceLabel:
                                    "native-settings"))
                let prepared =
                    try await self.management.prepare(
                    alias: alias,
                    configuration: configuration)
                _ = try await self.management
                    .testAndSavePrepared(
                        prepared,
                        authorization:
                            try Self.testAuthorization(
                                prepared))
            } catch {
                if let secretReference {
                    try? await self.secretStore.remove(
                        secretReference)
                }
                throw error
            }
            return "MCP server tested and saved."
        }
    }

    func editorDraft(
        for record: MCPServerInventoryRecord
    ) async throws -> MCPServerEditorDraft {
        let definition = try await management.definition(
            serverOrAlias: record.serverID.rawValue)
        return .editing(
            alias: record.alias,
            definition: definition)
    }

    @discardableResult
    func save(
        _ draft: MCPServerEditorDraft
    ) async -> Bool {
        var succeeded = false
        await perform {
            var createdSecrets:
                [MCPSecretReference] = []
            do {
                let configuration =
                    try await self.configuration(
                        from: draft,
                        createdSecrets: &createdSecrets)
                guard configuration.transport
                        .oauthConfiguration == nil else {
                    throw IntatisError.permissionDenied(
                        "OAuth drafts must be frozen and signed in before their exact prepared revision can be tested and saved.")
                }
                let prepared =
                    try await self.management.prepare(
                    alias: draft.alias,
                    configuration: configuration)
                _ = try await self.management
                    .testAndSavePrepared(
                        prepared,
                        authorization:
                            try Self.testAuthorization(
                                prepared))
                succeeded = true
                return draft.isEditing
                    ? "Tested and saved a new immutable revision for \(draft.alias)."
                    : "Tested and saved \(draft.alias)."
            } catch {
                for reference in createdSecrets {
                    try? await self.secretStore.remove(reference)
                }
                throw error
            }
        }
        return succeeded
    }

    /// Freezes an OAuth draft to one predicted immutable revision and obtains
    /// an inactive token bound to that preparation. The browser action is
    /// explicit; no Test or Save happens here.
    func prepareAndLogin(
        _ draft: MCPServerEditorDraft
    ) async -> MCPServerEditorPreparedSession? {
        guard !isWorking else { return nil }
        isWorking = true
        errorMessage = nil
        lastResult = nil
        var createdSecrets: [MCPSecretReference] = []
        do {
            let configuration =
                try await self.configuration(
                    from: draft,
                    createdSecrets: &createdSecrets)
            guard configuration.transport
                    .oauthConfiguration != nil else {
                throw IntatisError.config(
                    "This draft does not configure OAuth.")
            }
            let prepared =
                try await management.prepare(
                    alias: draft.alias,
                    configuration: configuration)
            do {
                try await oauthCoordinator.loginStaged(
                    prepared: prepared,
                    allowDynamicClientRegistration: true,
                    present: {
                        [interactionCenter] presentation in
                        await interactionCenter.presentOAuth(
                            presentation)
                    })
            } catch {
                await oauthCoordinator.discardStagedLogin(
                    prepared: prepared)
                throw error
            }
            let session =
                MCPServerEditorPreparedSession(
                    prepared: prepared,
                    createdSecrets: createdSecrets)
            lastResult =
                "Signed in for the frozen revision \(prepared.expectedServerReference.serverRevision.rawValue). Test & Save will use only this exact preparation."
            isWorking = false
            return session
        } catch {
            for reference in createdSecrets {
                try? await secretStore.remove(reference)
            }
            errorMessage = error.localizedDescription
            isWorking = false
            return nil
        }
    }

    /// Tests, compare-and-swap publishes, and activates OAuth for the exact
    /// frozen preparation. Any pre-publication failure removes the staged
    /// token and newly-created secret references.
    func testSaveAndActivate(
        _ session: MCPServerEditorPreparedSession
    ) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        errorMessage = nil
        lastResult = nil
        do {
            let tested = try await management.test(
                session.prepared,
                authorization:
                    try Self.testAuthorization(
                        session.prepared))
            guard tested.terminal == .succeeded else {
                throw MCPManagementError
                    .configurationTestFailed(
                        tested.sanitizedReasonCode)
            }
            let proof =
                try session.prepared.accept(tested)
            let receipt =
                try await management.savePreparedReceipt(
                    session.prepared,
                    proof: proof)
            _ = try await oauthCoordinator
                .activateStagedLogin(
                    prepared: session.prepared,
                    proof: proof,
                    publishedCatalog:
                        receipt.catalog)
            lastResult =
                "Tested, saved, and activated OAuth for \(session.prepared.alias) at the exact immutable revision \(session.prepared.expectedServerReference.serverRevision.rawValue)."
            await reload()
            isWorking = false
            return true
        } catch {
            await oauthCoordinator.discardStagedLogin(
                prepared: session.prepared)
            // A CAS receipt may already have installed the definition before a
            // later account-metadata failure. Retain references whenever the
            // catalog now proves the exact revision is published; otherwise
            // they remain transaction-owned and are removed.
            let published =
                (try? await catalogStore.load()
                    .definition(
                        for: session.prepared
                            .expectedServerReference))
                    == session.prepared.definition
            if !published {
                for reference in session.createdSecrets {
                    try? await secretStore.remove(reference)
                }
            }
            errorMessage = error.localizedDescription
            await reload()
            isWorking = false
            return false
        }
    }

    func discardPreparedEditorSession(
        _ session: MCPServerEditorPreparedSession
    ) async {
        await oauthCoordinator.discardStagedLogin(
            prepared: session.prepared)
        for reference in session.createdSecrets {
            try? await secretStore.remove(reference)
        }
    }

    func synchronizeRuntimeObservation(
        sessionID: SessionID,
        owner: MCPSessionRuntimeOwner
    ) async {
        async let connections =
            owner.liveConnectionSnapshots()
        async let metrics =
            owner.metricsSnapshot()
        async let diagnostics =
            owner.diagnosticsSnapshot()
        let completeConnections = await connections
        let now = Date()
        runtimeObservations[sessionID] =
            MCPProductRuntimeObservation(
                sessionID: sessionID,
                connections: completeConnections,
                metrics: await metrics,
                diagnostics: await diagnostics,
                observedAt: now)
        // Replace exactly this session's complete set. Retired authorities
        // disappear naturally; another Agent in the same session is retained
        // because it is present in `liveConnectionSnapshots()`.
        var updated = liveConnections.filter {
            $0.value.sessionID != sessionID
        }
        for connection in completeConnections {
            let server = connection.bindingIdentity.server
            let agentID =
                connection.reuseIdentity.authority.agentID
            let id = [
                sessionID.rawValue,
                agentID.rawValue,
                server.serverID.rawValue,
                server.serverRevision.rawValue,
                connection.bindingIdentity
                    .connectionGeneration.rawValue,
                connection.reuseIdentity.authority
                    .fingerprint,
            ].joined(separator: "\u{1f}")
            updated[id] =
                MCPProductLiveConnection(
                    id: id,
                    sessionID: sessionID,
                    agentID: agentID,
                    publishedAt: now,
                    connection: connection)
        }
        liveConnections = updated
    }

    func clearRuntimeObservation(
        sessionID: SessionID
    ) {
        runtimeObservations.removeValue(forKey: sessionID)
        liveConnections = liveConnections.filter {
            $0.value.sessionID != sessionID
        }
    }

    func liveConnections(
        for serverID: MCPServerID,
        revision: MCPServerRevision? = nil
    ) -> [MCPProductLiveConnection] {
        liveConnections.values.filter {
            let server =
                $0.connection.bindingIdentity.server
            return server.serverID == serverID
                && (revision.map {
                    server.serverRevision == $0
                } ?? true)
        }.sorted {
            if $0.publishedAt != $1.publishedAt {
                return $0.publishedAt > $1.publishedAt
            }
            if $0.sessionID != $1.sessionID {
                return $0.sessionID.rawValue
                    < $1.sessionID.rawValue
            }
            if $0.agentID != $1.agentID {
                return $0.agentID.rawValue
                    < $1.agentID.rawValue
            }
            return $0.id < $1.id
        }
    }

    private func configuration(
        from draft: MCPServerEditorDraft,
        createdSecrets:
            inout [MCPSecretReference]
    ) async throws -> MCPServerConfiguration {
        let filters = try MCPServerFilters(
            tools: Self.filter(
                allow: draft.toolAllow,
                deny: draft.toolDeny),
            resources: Self.filter(
                allow: draft.resourceAllow,
                deny: draft.resourceDeny),
            prompts: Self.filter(
                allow: draft.promptAllow,
                deny: draft.promptDeny),
            completions: Self.filter(
                allow: draft.completionAllow,
                deny: draft.completionDeny))
        let toolApprovalOverrides =
            try Self.toolApprovalOverrides(
                draft.toolApprovalOverrides)
        let transport: MCPTransportConfiguration
        switch draft.transport {
        case .streamableHTTP:
            let values = try await configuredValues(
                draft.headers,
                createdSecrets: &createdSecrets)
            let bearer: MCPSecretReference?
            if draft.bearerEnabled {
                bearer = try await storeSecretIfNeeded(
                    draft.bearerToken,
                    existing:
                        draft.existingBearerTokenReference,
                    createdSecrets: &createdSecrets)
                guard bearer != nil else {
                    throw MCPConfigurationError
                        .invalidSecretReference
                }
            } else {
                bearer = nil
            }
            let oauth: MCPOAuthConfiguration?
            if draft.oauthEnabled {
                let accountText =
                    draft.oauthAccountReference
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines)
                let clientSecret: MCPSecretReference?
                if draft.oauthClientSecretEnabled {
                    clientSecret =
                        try await storeSecretIfNeeded(
                            draft.oauthClientSecret,
                            existing: draft
                                .existingOAuthClientSecretReference,
                            createdSecrets: &createdSecrets)
                    guard clientSecret != nil else {
                        throw MCPConfigurationError
                            .invalidSecretReference
                    }
                } else {
                    clientSecret = nil
                }
                oauth = try MCPOAuthConfiguration(
                    enabled: true,
                    canonicalResource:
                        draft.oauthResource,
                    clientID:
                        Self.nilIfEmpty(
                            draft.oauthClientID),
                    clientSecretReference:
                        clientSecret,
                    scopes:
                        MCPServerEditorDraft.entries(
                            draft.oauthScopes),
                    accountReference:
                        accountText.isEmpty
                            ? nil
                            : MCPAccountReference(
                                rawValue: accountText))
            } else {
                oauth = nil
            }
            let tlsPins = MCPServerEditorDraft.entries(
                draft.tlsPublicKeyPins)
            transport = .streamableHTTP(
                try MCPHTTPServerConfiguration(
                    endpoint: draft.endpoint,
                    allowInsecureLoopbackDevelopmentHTTP:
                        draft
                            .allowInsecureLoopbackDevelopmentHTTP,
                    headers: values,
                    bearerTokenReference: bearer,
                    oauth: oauth,
                    redirectPolicy: draft.redirectPolicy,
                    proxyPolicy: draft.proxyPolicy,
                    tlsPolicy:
                        tlsPins.isEmpty
                            ? .systemTrust
                            : .pinnedPublicKeySHA256(
                                tlsPins)))
        case .stdio:
            let launchInputs = draft.launchFiles
                .filter {
                    !$0.path.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty
                }
                .map {
                    MCPLaunchArtifactInput(
                        role: $0.role.protocolRole,
                        path: $0.path)
                }
            let primaryInputs = launchInputs.filter {
                $0.role != .helper
            }
            let helperInputs = launchInputs.filter {
                $0.role == .helper
            }
            let artifact =
                try MCPLaunchArtifactIdentityVerifier
                    .captureBeforeSave(primaryInputs)
            let helperArtifacts = try helperInputs.map {
                try MCPLaunchArtifactIdentityVerifier
                    .captureHelpersBeforeSave([$0])
            }
            let environment = try await configuredValues(
                draft.environment,
                createdSecrets: &createdSecrets)
            let inheritedEnvironment =
                try await configuredSecretReferences(
                    draft.inheritedEnvironment,
                    createdSecrets: &createdSecrets)
            let origins =
                MCPServerEditorDraft.entries(
                    draft.networkOrigins)
            transport = .stdio(
                try MCPStdioServerConfiguration(
                    launchArtifact: artifact,
                    arguments:
                        MCPServerEditorDraft.entries(
                            draft.arguments),
                    workingDirectory:
                        Self.nilIfEmpty(
                            draft.workingDirectory),
                    environment: environment,
                    inheritedEnvironmentReferences:
                        inheritedEnvironment,
                    helperArtifacts:
                        helperArtifacts,
                    networkPolicy:
                        origins.isEmpty
                            ? .denied
                            : .exactOrigins(origins)))
        }
        return try MCPServerConfiguration(
            serverID: draft.originalServerID ?? .new(),
            displayName: draft.displayName,
            enabled: draft.enabled,
            required: draft.required,
            requiredCapabilities:
                Array(draft.requiredCapabilities),
            protocolProfile: draft.protocolProfile,
            maximumProtocolVersion:
                MCPProtocolVersion(
                    rawValue:
                        draft.maximumProtocolVersion),
            approvalPolicy: MCPApprovalPolicy(
                serverDefault: draft.approvalMode,
                toolOverrides:
                    toolApprovalOverrides),
            parallelCalls: draft.parallelCalls,
            timeouts: MCPServerTimeouts(
                startupMilliseconds:
                    draft.startupMilliseconds,
                callMilliseconds:
                    draft.callMilliseconds,
                shutdownMilliseconds:
                    draft.shutdownMilliseconds),
            filters: filters,
            transport: transport,
            environmentReference:
                MCPEnvironmentReference(
                    rawValue:
                        draft.environmentID
                            .trimmingCharacters(
                                in:
                                    .whitespacesAndNewlines)),
            provenance: MCPConfigurationProvenance(
                sourceKind: .intatisUser,
                sourceLabel: draft.isEditing
                    ? "native-settings-edit"
                    : "native-settings"))
    }

    private func configuredValues(
        _ rows: [MCPServerEditorKeyValue],
        createdSecrets:
            inout [MCPSecretReference]
    ) async throws -> [String: MCPConfiguredValue] {
        var result: [String: MCPConfiguredValue] = [:]
        for row in rows {
            let name = row.name.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !name.isEmpty, result[name] == nil else {
                throw MCPConfigurationError
                    .configurationTooLarge
            }
            if row.storesAsSecret {
                guard let reference =
                        try await storeSecretIfNeeded(
                            row.value,
                            existing:
                                row.existingSecretReference,
                            createdSecrets:
                                &createdSecrets) else {
                    throw MCPConfigurationError
                        .invalidSecretReference
                }
                result[name] = .secret(reference)
            } else {
                result[name] = try MCPConfiguredValue
                    .literal(row.value)
                    .validated(fieldName: name)
            }
        }
        return result
    }

    private func configuredSecretReferences(
        _ rows: [MCPServerEditorKeyValue],
        createdSecrets:
            inout [MCPSecretReference]
    ) async throws -> [String: MCPSecretReference] {
        var result: [String: MCPSecretReference] = [:]
        for row in rows {
            let name = row.name.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  result[name] == nil,
                  let reference =
                    try await storeSecretIfNeeded(
                        row.value,
                        existing:
                            row.existingSecretReference,
                        createdSecrets:
                            &createdSecrets) else {
                throw MCPConfigurationError
                    .invalidSecretReference
            }
            result[name] = reference
        }
        return result
    }

    private func storeSecretIfNeeded(
        _ plaintext: String,
        existing: MCPSecretReference?,
        createdSecrets:
            inout [MCPSecretReference]
    ) async throws -> MCPSecretReference? {
        let data = Data(plaintext.utf8)
        guard !data.isEmpty else { return existing }
        let reference = try await secretStore.store(data)
        createdSecrets.append(reference)
        return reference
    }

    private static func filter(
        allow: String,
        deny: String
    ) -> MCPNameFilter {
        let allowed =
            MCPServerEditorDraft.entries(allow)
        return MCPNameFilter(
            allowList:
                allowed.isEmpty ? nil : allowed,
            denyList:
                MCPServerEditorDraft.entries(deny))
    }

    private static func toolApprovalOverrides(
        _ rows: [MCPServerEditorToolApproval]
    ) throws -> [String: MCPApprovalMode] {
        var result: [String: MCPApprovalMode] = [:]
        for row in rows {
            let name = row.toolName.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  result[name] == nil else {
                throw MCPConfigurationError
                    .invalidRemoteName
            }
            result[name] = row.mode
        }
        // Reuse the canonical model validator for name/count limits.
        _ = try MCPApprovalPolicy(
            serverDefault: .prompt,
            toolOverrides: result)
        return result
    }

    private static func nilIfEmpty(
        _ value: String
    ) -> String? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func testAuthorization(
        _ prepared: MCPPreparedServerConfiguration
    ) throws -> MCPConfigurationTestAuthorization {
        try MCPConfigurationTestAuthorization(
            directUserAction: true,
            callerFingerprint:
                MCPHostDigest.sha256([
                    IntatisHostApplication.identity.temporaryPrefix(
                        "mac-editor-test-v1"),
                    prepared.preparationFingerprint,
                ]))
    }

    func test(_ record: MCPServerInventoryRecord) async {
        await perform {
            let definition =
                try await self.management.definition(
                    serverOrAlias: record.serverID.rawValue)
            let prepared =
                try await self.management.prepare(
                    alias: record.alias,
                    configuration:
                        definition.configuration)
            let result = try await self.management.test(
                prepared,
                authorization:
                    try Self.testAuthorization(
                        prepared))
            guard result.terminal == .succeeded else {
                throw MCPManagementError
                    .configurationTestFailed(
                        result.sanitizedReasonCode)
            }
            return "Test succeeded for \(record.alias)."
        }
    }

    func setEnabled(
        _ record: MCPServerInventoryRecord,
        enabled: Bool
    ) async {
        await perform {
            _ = try await self.management.setEnabled(
                serverOrAlias:
                    record.serverID.rawValue,
                enabled: enabled)
            return enabled
                ? "Enabled \(record.alias)."
                : "Disabled \(record.alias)."
        }
    }

    func duplicate(
        _ record: MCPServerInventoryRecord
    ) async {
        await perform {
            let staging =
                try await self.management.duplicateDraft(
                    serverOrAlias:
                        record.serverID.rawValue)
            let alias = try await self.availableAlias(
                base: "\(record.alias)-copy")
            let prepared =
                try await self.management.prepare(
                alias: alias,
                configuration:
                    staging.configuration)
            _ = try await self.management
                .testAndSavePrepared(
                    prepared,
                    authorization:
                        try Self.testAuthorization(
                            prepared))
            return "Duplicated as \(alias)."
        }
    }

    func delete(_ record: MCPServerInventoryRecord) async {
        await perform {
            _ = try await self.management.deleteCurrent(
                serverOrAlias:
                    record.serverID.rawValue)
            return "Deleted \(record.alias)."
        }
    }

    func referenceUsage(
        _ record: MCPServerInventoryRecord
    ) async throws -> MCPServerReferenceUsage {
        guard let revision = record.currentRevision else {
            throw MCPManagementError.currentRevisionMissing(
                record.serverID)
        }
        let reference = MCPServerReference(
            serverID: record.serverID,
            serverRevision: revision)
        return try await MCPProcessCatalogRuntimeRegistry
            .shared.referenceUsage(
                reference,
                durableSource:
                    MCPAppServerReferenceUsageSource(
                        root: AppConfig.appSupportDir()))
    }

    func exportCatalog(to url: URL) async {
        await perform {
            let data = try await self.management
                .exportSanitized()
            try data.write(to: url, options: .atomic)
            return "Exported a secret-free MCP catalog."
        }
    }

    private func availableAlias(base: String) async throws -> String {
        let aliases = Set(
            try await management.inventory().map(\.alias))
        if !aliases.contains(base) { return base }
        for index in 2...10_000 {
            let candidate = "\(base)-\(index)"
            if !aliases.contains(candidate) {
                return candidate
            }
        }
        throw MCPManagementError.concurrentCatalogMutation
    }

    func perform(
        _ operation: @escaping @MainActor () async throws
            -> String
    ) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        lastResult = nil
        do {
            lastResult = try await operation()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }
}

struct IntatisMCPSettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var selection: MCPServerID?
    @State private var editor: MCPServerEditorDraft?
    @State private var deleteTarget:
        MCPServerInventoryRecord?
    @State private var deleteUsage:
        MCPServerReferenceUsage?
    @State private var showsDoctor = false
    @State private var showsImport = false

    private var selectedRecord:
        MCPServerInventoryRecord?
    {
        env.mcp.inventory.first {
            $0.serverID == selection
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HSplitView {
                inventory
                    .frame(
                        minWidth: 250,
                        idealWidth: 290,
                        maxWidth: 360)
                Group {
                    if let selectedRecord {
                        MCPServerDetailView(
                            record: selectedRecord,
                            onEdit: {
                                loadEditor(selectedRecord)
                            },
                            onDelete: {
                                prepareDelete(
                                    selectedRecord)
                            })
                    } else {
                        ContentUnavailableView(
                            "Select an MCP server",
                            systemImage:
                                "externaldrive.connected.to.line.below",
                            description: Text(
                                "Choose a server to inspect its immutable configuration, live catalog, access, activity, and diagnostics."))
                    }
                }
                .frame(
                    minWidth: 460,
                    maxWidth: .infinity,
                    maxHeight: .infinity)
            }
            .frame(minHeight: 620)
            status
        }
        .padding(18)
        .translatisCard(cornerRadius: 20)
        .task {
            await env.mcp.reload()
            selectFirstIfNeeded()
        }
        .onChange(of: env.mcp.inventory.map(\.serverID)) {
            _, _ in selectFirstIfNeeded()
        }
        .sheet(item: $editor) { draft in
            MCPServerEditorSheet(initialDraft: draft)
                .environmentObject(env)
        }
        .sheet(isPresented: $showsImport) {
            MCPImportServerSheet()
                .environmentObject(env)
        }
        .sheet(isPresented: $showsDoctor) {
            MCPDoctorSheet()
                .environmentObject(env)
        }
        .alert(
            "Delete MCP Server?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: {
                    if !$0 {
                        deleteTarget = nil
                        deleteUsage = nil
                    }
                }),
            presenting: deleteTarget
        ) { server in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await env.mcp.delete(server) }
            }
        } message: { server in
            if let deleteUsage {
                Text(
                    "\(server.alias) will be disabled and its current immutable revision tombstoned. \(deleteUsage.liveAuthorityCount) live connection authorities will be drained, and \(deleteUsage.durableSessionIDs.count) Code/Cowork sessions currently reference this revision. Those sessions retain secret-free history and must detach or attach another tested revision before reconnecting.")
            } else {
                Text(
                    "\(server.alias) will be disabled and its current immutable revision tombstoned. Existing session authority and audit history are retained.")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("External MCP servers")
                    .font(TranslatisType.body(14, .semibold))
                if env.mcp.hostProfile.supportsStdio {
                    Text(
                        "Streamable HTTP and permission-gated managed stdio")
                        .font(TranslatisType.caption(12, .regular))
                        .foregroundStyle(.secondary)
                } else {
                    Text(
                        "Streamable HTTP only; this App Store build does not link the stdio transport")
                        .font(TranslatisType.caption(12, .regular))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                showsDoctor = true
            } label: {
                Label("Doctor", systemImage: "stethoscope")
            }
            Button {
                showsImport = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            Button {
                exportCatalog()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            Button {
                editor = .new(
                    supportsStdio:
                        env.mcp.hostProfile.supportsStdio)
            } label: {
                Label("Add Server", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var inventory: some View {
        List(selection: $selection) {
            ForEach(env.mcp.inventory) { server in
                MCPServerInventoryRow(
                    server: server,
                    liveConnections:
                        env.mcp.liveConnections(
                            for: server.serverID,
                            revision:
                                server.currentRevision),
                    signedIn:
                        env.mcp.isSignedIn(server))
                    .tag(server.serverID)
            }
        }
        .overlay {
            if env.mcp.inventory.isEmpty {
                ContentUnavailableView(
                    "No MCP servers",
                    systemImage:
                        "externaldrive.badge.plus",
                    description: Text(
                        "Add or explicitly import a server configuration. Every draft is tested before its immutable revision is saved."))
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let result = env.mcp.lastResult {
            Label(result, systemImage: "checkmark.circle.fill")
                .font(TranslatisType.caption(12, .semibold))
                .foregroundStyle(.green)
        }
        if let error = env.mcp.errorMessage {
            Label(error, systemImage: "exclamationmark.octagon.fill")
                .font(TranslatisType.caption(12, .regular))
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private func selectFirstIfNeeded() {
        guard selection == nil
                || !env.mcp.inventory.contains(
                    where: { $0.serverID == selection })
        else { return }
        selection = env.mcp.inventory.first?.serverID
    }

    private func loadEditor(
        _ record: MCPServerInventoryRecord
    ) {
        Task {
            do {
                editor = try await env.mcp.editorDraft(
                    for: record)
            } catch {
                env.mcp.errorMessage =
                    error.localizedDescription
            }
        }
    }

    private func prepareDelete(
        _ record: MCPServerInventoryRecord
    ) {
        Task {
            do {
                let usage =
                    try await env.mcp
                        .referenceUsage(record)
                deleteUsage = usage
                deleteTarget = record
            } catch {
                env.mcp.errorMessage =
                    error.localizedDescription
            }
        }
    }

    private func exportCatalog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "mcp.json"
        panel.canCreateDirectories = true
        TranslatisMacProcessDiagnostics.shared
            .setKnownModalPresented(true)
        defer {
            TranslatisMacProcessDiagnostics.shared
                .setKnownModalPresented(false)
        }
        guard panel.runModal() == .OK,
              let url = panel.url else { return }
        Task { await env.mcp.exportCatalog(to: url) }
    }
}

private struct MCPServerInventoryRow: View {
    let server: MCPServerInventoryRecord
    let liveConnections:
        [MCPProductLiveConnection]
    let signedIn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName:
                server.transport == .stdio
                    ? "terminal"
                    : "network")
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.displayName)
                    .font(IntatisTypography.system(.body, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(server.alias)
                    Text("·")
                    Text(setupLabel)
                    if !liveConnections.isEmpty {
                        Text("·")
                        Text(
                            "\(liveConnections.count) live")
                            .foregroundStyle(.green)
                    }
                    if signedIn {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .accessibilityLabel("Signed in")
                    }
                }
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if server.required {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Required")
            }
        }
        .padding(.vertical, 3)
    }

    private var setupLabel: LocalizedStringKey {
        switch server.setupStatus {
        case .ready: return "Ready"
        case .disabled: return "Disabled"
        case .setupRequired: return "Setup required"
        case .authRequired: return "Sign-in required"
        case .tombstoned: return "Tombstoned"
        }
    }
}

private enum MCPServerDetailTab:
    String, CaseIterable, Identifiable {
    case overview
    case tools
    case resources
    case prompts
    case access
    case activity
    case diagnostics

    var id: String { rawValue }
}

private struct MCPServerDetailView: View {
    @EnvironmentObject private var env: AppEnvironment
    let record: MCPServerInventoryRecord
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var tab = MCPServerDetailTab.overview
    @State private var definition: MCPServerDefinition?
    @State private var loadError: String?

    private var liveConnections:
        [MCPProductLiveConnection]
    {
        env.mcp.liveConnections(
            for: record.serverID,
            revision: record.currentRevision)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("Server detail", selection: $tab) {
                Text("Overview").tag(MCPServerDetailTab.overview)
                Text("Tools").tag(MCPServerDetailTab.tools)
                Text("Resources").tag(MCPServerDetailTab.resources)
                Text("Prompts").tag(MCPServerDetailTab.prompts)
                Text("Access").tag(MCPServerDetailTab.access)
                Text("Activity").tag(MCPServerDetailTab.activity)
                Text("Diagnostics").tag(MCPServerDetailTab.diagnostics)
            }
            .pickerStyle(.segmented)
            .padding(12)
            Divider()
            ScrollView {
                detail
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
        }
        .task(id:
            "\(record.serverID.rawValue)|\(record.currentRevision?.rawValue ?? "")"
        ) {
            do {
                definition = try await env.mcp.management
                    .definition(
                        serverOrAlias:
                            record.serverID.rawValue)
                loadError = nil
            } catch {
                definition = nil
                loadError = error.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName:
                record.transport == .stdio
                    ? "terminal.fill"
                    : "network")
                .font(IntatisTypography.system(.title2))
                .frame(width: 34, height: 34)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(record.displayName)
                    .font(IntatisTypography.system(.title3, bold: true))
                Text(
                    "\(record.alias) · \(record.serverID.rawValue)")
                    .font(IntatisTypography.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Test") {
                Task { await env.mcp.test(record) }
            }
            Button("Edit", action: onEdit)
            Menu {
                if definition?.configuration.transport
                    .oauthConfiguration != nil {
                    if env.mcp.isSignedIn(record) {
                        Button("Sign Out") {
                            Task {
                                await env.mcp.logout(record)
                            }
                        }
                    } else {
                        Button("Sign In…") {
                            Task {
                                await env.mcp.login(
                                    record,
                                    allowDynamicClientRegistration:
                                        true)
                            }
                        }
                    }
                    Divider()
                }
                Button(
                    record.enabled ? "Disable" : "Enable"
                ) {
                    Task {
                        await env.mcp.setEnabled(
                            record,
                            enabled: !record.enabled)
                    }
                }
                Button("Duplicate") {
                    Task {
                        await env.mcp.duplicate(record)
                    }
                }
                Divider()
                Button(
                    "Delete",
                    role: .destructive,
                    action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(16)
        .disabled(env.mcp.isWorking)
    }

    @ViewBuilder
    private var detail: some View {
        if let loadError {
            Label(loadError, systemImage: "exclamationmark.octagon")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        } else {
            switch tab {
            case .overview:
                overview
            case .tools:
                catalogList(
                    rows: { live in
                        live.connection.catalog.tools.map {
                            ($0.remoteName, $0.summary,
                             $0.taskSupport?.rawValue)
                        }
                    },
                    empty: "No tools are present in the current live catalog.")
            case .resources:
                catalogList(
                    rows: { live in
                        live.connection.catalog.resources.map {
                            ($0.title ?? $0.name, $0.uri,
                             $0.mimeType)
                        }
                    },
                    empty: "No resources are present in the current live catalog.")
            case .prompts:
                catalogList(
                    rows: { live in
                        live.connection.catalog.prompts.map {
                            ($0.title ?? $0.name,
                             $0.summary ?? $0.name,
                             "\($0.arguments.count) arguments")
                        }
                    },
                    empty: "No prompts are present in the current live catalog.")
            case .access:
                access
            case .activity:
                activity
            case .diagnostics:
                diagnostics
            }
        }
    }

    @ViewBuilder
    private var overview: some View {
        if let definition {
            let configuration = definition.configuration
            VStack(alignment: .leading, spacing: 14) {
                MCPDetailGroup("Configuration") {
                    MCPDetailLine(
                        "Immutable revision",
                        definition.reference.serverRevision.rawValue)
                    MCPDetailLine(
                        "Transport",
                        configuration.transport.kind.rawValue)
                    MCPDetailLine(
                        "Protocol profile",
                        configuration.protocolProfile.rawValue)
                    MCPDetailLine(
                        "Maximum protocol",
                        configuration.maximumProtocolVersion.rawValue)
                    MCPDetailLine(
                        "Default approval",
                        configuration.approvalPolicy.serverDefault.rawValue)
                    MCPDetailLine(
                        "Required",
                        configuration.required ? "Yes" : "No")
                    MCPDetailLine(
                        "Parallel calls",
                        configuration.parallelCalls ? "Enabled" : "Disabled")
                    MCPDetailLine(
                        "Source",
                        configuration.provenance.sourceKind.rawValue)
                }
                MCPDetailGroup("Setup and install") {
                    MCPSetupGuidanceBody(
                        profile: env.mcp.hostProfile,
                        transport:
                            configuration.transport.kind)
                }
                if liveConnections.isEmpty {
                    MCPEmptyLiveState()
                } else {
                    ForEach(liveConnections) { live in
                        MCPDetailGroup("Live generation") {
                            MCPDetailLine(
                                "Session", live.sessionID.rawValue)
                            MCPDetailLine(
                                "Agent", live.agentID.rawValue)
                            MCPDetailLine(
                                "Connection generation",
                                live.connection.bindingIdentity
                                    .connectionGeneration.rawValue)
                            MCPDetailLine(
                                "Negotiated protocol",
                                live.connection.bindingIdentity
                                    .negotiatedProtocolVersion.value.rawValue)
                            MCPDetailLine(
                                "Catalog revision",
                                live.connection.catalog.revision.rawValue)
                            MCPDetailLine(
                                "Catalog fingerprint",
                                live.connection.catalog
                                    .catalogFingerprint)
                            MCPDetailLine(
                                "Authority fingerprint",
                                live.connection.reuseIdentity
                                    .authority.fingerprint)
                            capabilitySummary(
                                live.connection
                                    .negotiatedCapabilities)
                        }
                    }
                }
                if case .streamableHTTP(let http) =
                        configuration.transport {
                    MCPDetailGroup("Network and account") {
                        MCPDetailLine(
                            "Endpoint", http.endpoint)
                        MCPDetailLine(
                            "Exact origin", http.canonicalOrigin)
                        MCPDetailLine(
                            "Redirects", http.redirectPolicy.rawValue)
                        MCPDetailLine(
                            "Proxy", http.proxyPolicy.rawValue)
                        MCPDetailLine(
                            "Account",
                            http.oauth?.accountReference?.rawValue
                                ?? "No OAuth account reference")
                    }
                }
            }
        } else {
            ProgressView()
        }
    }

    private func capabilitySummary(
        _ value: MCPNegotiatedCapabilitySet
    ) -> some View {
        MCPDetailLine(
            "Negotiated capabilities",
            [
                value.capabilities.contains(.tools) ? "tools" : nil,
                value.capabilities.contains(.resources) ? "resources" : nil,
                value.capabilities.contains(.prompts) ? "prompts" : nil,
                value.capabilities.contains(.completions) ? "completions" : nil,
                value.capabilities.contains(.logging) ? "logging" : nil,
                value.capabilities.contains(.roots) ? "roots" : nil,
                value.capabilities.contains(.sampling) ? "sampling" : nil,
                value.capabilities.contains(.elicitation) ? "elicitation" : nil,
                value.capabilities.contains(.tasks) ? "tasks" : nil,
            ].compactMap { $0 }.joined(separator: ", "))
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Global inventory does not grant any Agent access. Attach this exact immutable revision in a Code or Cowork project, then grant capabilities per Agent in Project Settings.")
                .foregroundStyle(.secondary)
            if liveConnections.isEmpty {
                MCPEmptyLiveState()
            } else {
                ForEach(liveConnections) { live in
                    MCPDetailGroup("Effective connection authority") {
                        MCPDetailLine(
                            "Currently published for",
                            "\(live.sessionID.rawValue) / \(live.agentID.rawValue)")
                        MCPDetailLine(
                            "Authority fingerprint",
                            live.connection.reuseIdentity
                                .authority.fingerprint)
                        MCPDetailLine(
                            "Attachment",
                            live.connection.reuseIdentity.authority
                                .attachmentID.rawValue)
                        MCPDetailLine(
                            "CapabilityLease",
                            live.connection.reuseIdentity.authority
                                .capabilityLeaseID.rawValue)
                        MCPDetailLine(
                            "WorkspaceLease",
                            live.connection.reuseIdentity.authority
                                .workspaceLeaseID?.rawValue
                                ?? "None")
                    }
                }
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 10) {
            let observations = env.mcp.runtimeObservations.values
                .filter { observation in
                    observation.connections.contains {
                        $0.bindingIdentity.server.serverID
                            == record.serverID
                    }
                }
                .sorted {
                    $0.observedAt > $1.observedAt
                }
            if observations.isEmpty {
                Text(
                    "No process-local live activity is published for this server. Durable session activity remains in each session EventLog.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(observations, id: \.sessionID) {
                    observation in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(observation.sessionID.rawValue)
                            .font(IntatisTypography.system(.body, design: .monospaced))
                        Text(
                            "\(observation.metrics.counters.values.reduce(0, +)) bounded metric events · observed \(observation.observedAt.formatted())")
                            .font(IntatisTypography.system(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                }
            }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 9) {
            let global = env.mcp.doctorFindings.filter {
                $0.serverID == nil
                    || $0.serverID == record.serverID
            }
            ForEach(Array(global.enumerated()), id: \.offset) {
                _, finding in
                MCPDiagnosticRow(
                    code: finding.code,
                    summary: finding.summary,
                    severity: finding.severity)
            }
            let liveDiagnostics =
                env.mcp.runtimeObservations.values
                    .filter { observation in
                        observation.connections.contains {
                                $0.bindingIdentity.server
                                    .serverID
                                    == record.serverID
                            }
                    }
                    .flatMap(\.diagnostics)
            ForEach(liveDiagnostics, id: \.self) {
                diagnostic in
                MCPDiagnosticRow(
                    code: diagnostic.code,
                    summary: diagnostic.summary,
                    severity: .warning)
            }
            if global.isEmpty
                && liveDiagnostics.isEmpty {
                Label(
                    "No bounded diagnostics are currently reported.",
                    systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        }
    }

    private func catalogList(
        rows:
            @escaping (
                MCPProductLiveConnection
            ) -> [(String, String, String?)],
        empty: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if liveConnections.isEmpty {
                MCPEmptyLiveState()
            } else {
                ForEach(liveConnections) { live in
                    let catalogRows = rows(live)
                    GroupBox {
                        VStack(
                            alignment: .leading,
                            spacing: 8)
                        {
                            if catalogRows.isEmpty {
                                Text(empty)
                                    .foregroundStyle(
                                        .secondary)
                            } else {
                                ForEach(
                                    Array(
                                        catalogRows
                                            .enumerated()),
                                    id: \.offset
                                ) { _, row in
                                    VStack(
                                        alignment: .leading,
                                        spacing: 3)
                                    {
                                        HStack {
                                            Text(row.0)
                                                .font(
                                                    IntatisTypography.system(
                                                        .body,
                                                        weight: .semibold))
                                            Spacer()
                                            if let badge =
                                                    row.2 {
                                                Text(badge)
                                                    .font(
                                                        IntatisTypography.system(
                                                            .caption2))
                                                    .padding(
                                                        .horizontal,
                                                        6)
                                                    .padding(
                                                        .vertical,
                                                        2)
                                                    .background(
                                                        .quaternary,
                                                        in: Capsule())
                                            }
                                        }
                                        Text(row.1)
                                            .font(IntatisTypography.system(.caption))
                                            .foregroundStyle(
                                                .secondary)
                                            .textSelection(
                                                .enabled)
                                    }
                                    if row.0
                                        != catalogRows.last?.0 {
                                        Divider()
                                    }
                                }
                            }
                        }
                    } label: {
                        Text(
                            "\(live.sessionID.rawValue) / \(live.agentID.rawValue) · \(live.connection.bindingIdentity.connectionGeneration.rawValue)")
                            .font(IntatisTypography.system(.caption, design: .monospaced))
                    }
                }
            }
        }
    }
}

private struct MCPEmptyLiveState: View {
    var body: some View {
        Label {
            Text(
                "No live generation is published for this immutable revision. Test does not create a reusable session connection; Connect, Send, Resume, or Retry must explicitly activate one.")
        } icon: {
            Image(systemName: "bolt.slash")
        }
        .foregroundStyle(.secondary)
    }
}

private struct MCPSetupGuidanceBody: View {
    let profile: MCPProductHostProfile
    let transport: MCPTransportKind

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch (profile, transport) {
            case (.macAppStore, .stdio):
                Label(
                    "Managed stdio is not linked into this App Store build. Use an HTTPS Streamable HTTP endpoint or install the Developer ID build.",
                    systemImage: "xmark.shield")
                    .foregroundStyle(.orange)
            case (.macAppStore, .streamableHTTP):
                guidanceStep(
                    1,
                    "Obtain the server's HTTPS Streamable HTTP endpoint from its operator.")
                guidanceStep(
                    2,
                    "Enter credentials as Keychain-backed bearer, header, or OAuth references; never paste them into ordinary configuration values.")
                guidanceStep(
                    3,
                    "Run Test & Save, then attach the immutable revision to a Code or Cowork session.")
                Text(
                    "This App Store build is remote-only by linkage and cannot launch a local MCP executable.")
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.secondary)
            case (.macDeveloperID, .stdio),
                 (.macCLI, .stdio):
                guidanceStep(
                    1,
                    "Install the MCP server using its trusted publisher's instructions outside \(IntatisHostApplication.identity.name).")
                guidanceStep(
                    2,
                    "Select every absolute executable, interpreter, script, package entrypoint, lockfile, and helper used by the launch closure.")
                guidanceStep(
                    3,
                    "Add only the required arguments and environment entries; store sensitive values as Keychain references.")
                guidanceStep(
                    4,
                    "Run Test & Save. \(IntatisHostApplication.identity.name) captures and revalidates the exact launch artifacts before every managed start.")
                Text(
                    "\(IntatisHostApplication.identity.name) does not run an install command, arbitrary shell string, or an unverified executable on behalf of this form.")
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.secondary)
            case (.linuxCLI, .stdio):
                guidanceStep(
                    1,
                    "Install the server and bubblewrap (bwrap) through the trusted system package channel.")
                guidanceStep(
                    2,
                    "Run \(IntatisHostApplication.identity.commandName) mcp doctor and resolve every bwrap or launch-artifact error.")
                guidanceStep(
                    3,
                    "Add the exact executable and launch closure, then run \(IntatisHostApplication.identity.commandName) mcp test before attaching it.")
                Text(
                    "Linux stdio fails closed when bwrap is unavailable; there is no unsandboxed fallback.")
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.orange)
            case (.macDeveloperID, .streamableHTTP),
                 (.macCLI, .streamableHTTP),
                 (.linuxCLI, .streamableHTTP):
                guidanceStep(
                    1,
                    "Obtain the server's canonical HTTPS Streamable HTTP endpoint from its operator.")
                guidanceStep(
                    2,
                    "Configure the exact redirect, proxy, network-origin, and credential policy.")
                guidanceStep(
                    3,
                    "Run Test & Save, then attach and grant the immutable revision in the target session.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func guidanceStep(
        _ number: Int,
        _ text: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(IntatisTypography.system(.caption, bold: true))
                .frame(width: 20, height: 20)
                .background(
                    Color.accentColor.opacity(0.15),
                    in: Circle())
            Text(text)
        }
    }
}

private struct MCPDetailGroup<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
        }
    }
}

private struct MCPDetailLine: View {
    let label: LocalizedStringKey
    let value: String

    init(
        _ label: LocalizedStringKey,
        _ value: String
    ) {
        self.label = label
        self.value = value
    }

    var body: some View {
        LabeledContent {
            Text(value)
                .font(IntatisTypography.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        } label: {
            Text(label)
        }
    }
}

private struct MCPDiagnosticRow: View {
    let code: String
    let summary: String
    let severity: MCPDoctorFinding.Severity

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                Text(code)
                    .font(IntatisTypography.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName:
                severity == .error
                    ? "xmark.octagon"
                    : severity == .warning
                        ? "exclamationmark.triangle"
                        : "info.circle")
        }
        .foregroundStyle(
            severity == .error
                ? .red
                : severity == .warning
                    ? .orange
                    : .primary)
    }
}

private struct MCPDoctorSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if env.mcp.doctorFindings.isEmpty {
                    Label(
                        "No catalog or credential-reference issues were found.",
                        systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                ForEach(
                    Array(env.mcp.doctorFindings.enumerated()),
                    id: \.offset
                ) { _, finding in
                    MCPDiagnosticRow(
                        code: finding.code,
                        summary: finding.summary,
                        severity: finding.severity)
                }
            }
            .navigationTitle("MCP Doctor")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 420)
    }
}

private struct MCPServerEditorSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MCPServerEditorDraft
    @State private var section = EditorSection.connection
    @State private var preparedSession:
        MCPServerEditorPreparedSession?

    private enum EditorSection: String, CaseIterable, Identifiable {
        case connection
        case policy
        case filters

        var id: String { rawValue }
    }

    init(initialDraft: MCPServerEditorDraft) {
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Editor section", selection: $section) {
                    Text("Connection").tag(EditorSection.connection)
                    Text("Policy").tag(EditorSection.policy)
                    Text("Filters").tag(EditorSection.filters)
                }
                .pickerStyle(.segmented)
                .padding()
                Divider()
                Form {
                    switch section {
                    case .connection:
                        connectionForm
                    case .policy:
                        policyForm
                    case .filters:
                        filtersForm
                    }
                }
                .formStyle(.grouped)
                .disabled(preparedSession != nil)
            }
            .navigationTitle(
                draft.isEditing
                    ? "Edit MCP Server"
                    : "Add MCP Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancelEditor()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack {
                        if draft.oauthEnabled,
                           preparedSession == nil {
                            Button("Freeze & Sign In…") {
                                let value = draft
                                Task {
                                    preparedSession =
                                        await env.mcp
                                            .prepareAndLogin(
                                                value)
                                }
                            }
                        }
                        Button("Test & Save") {
                            if let preparedSession {
                                Task {
                                    let saved =
                                        await env.mcp
                                            .testSaveAndActivate(
                                                preparedSession)
                                    self.preparedSession =
                                        nil
                                    if saved {
                                        dismiss()
                                    }
                                }
                            } else {
                                let value = draft
                                Task {
                                    if await env.mcp
                                        .save(value) {
                                        dismiss()
                                    }
                                }
                            }
                        }
                        .disabled(
                            !isSaveable
                                || env.mcp.isWorking
                                || (draft.oauthEnabled
                                    && preparedSession
                                        == nil))
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 700)
        .interactiveDismissDisabled(
            preparedSession != nil
                || env.mcp.isWorking)
        .onChange(of: draft.endpoint) {
            endpoint in
            if !Self
                .isInsecureLoopbackDevelopmentEndpoint(
                    endpoint) {
                draft
                    .allowInsecureLoopbackDevelopmentHTTP =
                    false
            }
        }
        .onDisappear {
            guard let preparedSession else {
                return
            }
            self.preparedSession = nil
            Task {
                await env.mcp
                    .discardPreparedEditorSession(
                        preparedSession)
            }
        }
    }

    @ViewBuilder
    private var connectionForm: some View {
        Section("Identity") {
            TextField("Alias", text: $draft.alias)
                .disabled(draft.isEditing)
            TextField(
                "Display name",
                text: $draft.displayName)
            Toggle("Enabled", isOn: $draft.enabled)
            Picker("Transport", selection: $draft.transport) {
                Text("Streamable HTTP")
                    .tag(
                        MCPServerEditorTransport
                            .streamableHTTP)
                Text("Managed stdio")
                    .tag(MCPServerEditorTransport.stdio)
            }
            .pickerStyle(.segmented)
        }
        if draft.transport == .streamableHTTP {
            httpForm
        } else {
            stdioForm
        }
        Section("Setup and install") {
            MCPSetupGuidanceBody(
                profile: env.mcp.hostProfile,
                transport:
                    draft.transport
                        == .streamableHTTP
                        ? .streamableHTTP
                        : .stdio)
        }
    }

    @ViewBuilder
    private var httpForm: some View {
        Section("Streamable HTTP") {
            TextField(
                "HTTPS endpoint",
                text: $draft.endpoint)
            if Self
                .isInsecureLoopbackDevelopmentEndpoint(
                    draft.endpoint) {
                Toggle(
                    "Allow insecure loopback HTTP for development",
                    isOn:
                        $draft
                            .allowInsecureLoopbackDevelopmentHTTP)
                if draft
                    .allowInsecureLoopbackDevelopmentHTTP {
                    Text(
                        "Development only. Plain HTTP is accepted only for this exact loopback endpoint; OAuth, redirects, proxies, and non-loopback hosts remain blocked.")
                        .font(IntatisTypography.system(.caption))
                        .foregroundStyle(.orange)
                }
            }
            Picker(
                "Redirect policy",
                selection: $draft.redirectPolicy
            ) {
                Text("Deny")
                    .tag(MCPHTTPRedirectPolicy.deny)
                Text("Same origin only")
                    .tag(
                        MCPHTTPRedirectPolicy
                            .sameOriginOnly)
            }
            Picker(
                "Proxy policy",
                selection: $draft.proxyPolicy
            ) {
                Text("Direct")
                    .tag(MCPHTTPProxyPolicy.direct)
                Text("System configured")
                    .tag(
                        MCPHTTPProxyPolicy
                            .systemConfigured)
            }
            MCPMultilineField(
                title:
                    "TLS SPKI SHA-256 pins, lowercase hex; one per line",
                text: $draft.tlsPublicKeyPins)
            Text(
                "Leave pins empty to use system trust only. Each pin is SHA-256 over the certificate DER SubjectPublicKeyInfo and is enforced by the production libcurl transport.")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(.secondary)
        }
        MCPKeyValueEditor(
            title: "Headers",
            rows: $draft.headers,
            valueLabel: "Header value")
        Section("Bearer authorization") {
            Toggle(
                "Use bearer token",
                isOn: $draft.bearerEnabled)
            if draft.bearerEnabled {
                SecureField(
                    draft.existingBearerTokenReference == nil
                        ? "Bearer token"
                        : "New token (leave empty to retain the Keychain reference)",
                    text: $draft.bearerToken)
                Text(
                    "The token is written to Keychain and only its opaque reference is saved.")
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        Section("OAuth 2.1") {
            Toggle(
                "Enable OAuth",
                isOn: $draft.oauthEnabled)
            if draft.oauthEnabled {
                TextField(
                    "Protected resource URL",
                    text: $draft.oauthResource)
                TextField(
                    "Client ID (optional)",
                    text: $draft.oauthClientID)
                Toggle(
                    "Use client secret",
                    isOn:
                        $draft.oauthClientSecretEnabled)
                if draft.oauthClientSecretEnabled {
                    SecureField(
                        draft.existingOAuthClientSecretReference == nil
                            ? "Client secret"
                            : "New client secret (leave empty to retain the Keychain reference)",
                        text:
                            $draft.oauthClientSecret)
                }
                TextField(
                    "Opaque account reference",
                    text:
                        $draft.oauthAccountReference)
                MCPMultilineField(
                    title: "Scopes, one per line",
                    text: $draft.oauthScopes)
                Text(
                    "Freeze & Sign In predicts one exact immutable revision and binds the inactive token to that revision and catalog challenge. The authorization origin, resource, account, and scopes are shown before the browser opens; only the matching Test proof and catalog save can activate it.")
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.secondary)
                if let preparedSession {
                    LabeledContent(
                        "Frozen OAuth revision",
                        value:
                            preparedSession.prepared
                                .expectedServerReference
                                .serverRevision.rawValue)
                    Text(
                        "Editing is locked until Test & Save succeeds or you cancel this prepared transaction.")
                        .font(IntatisTypography.system(.caption))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var stdioForm: some View {
        Section("Exact launch closure") {
            ForEach($draft.launchFiles) { $file in
                HStack {
                    Picker("Role", selection: $file.role) {
                        ForEach(
                            MCPServerEditorFileRole.allCases
                        ) { role in
                            Text(role.rawValue)
                                .tag(role)
                        }
                    }
                    .frame(width: 180)
                    TextField(
                        "Absolute file path",
                        text: $file.path)
                    if draft.launchFiles.count > 1 {
                        Button(role: .destructive) {
                            draft.launchFiles.removeAll {
                                $0.id == file.id
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                    }
                }
            }
            Button("Add launch file") {
                draft.launchFiles.append(
                    .init(role: .script))
            }
            Text(
                "Test captures every listed executable, interpreter, script, package entrypoint, lockfile, and helper with no-follow identity checks. Save and launch reverify the same closure. macOS rejects helper-process authority because it cannot prove descendant process-group containment; exact helper execution is available only in the guarded Linux CLI runtime.")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(.secondary)
        }
        Section("Process") {
            MCPMultilineField(
                title: "Arguments, one per line",
                text: $draft.arguments)
            TextField(
                "Working directory (optional)",
                text: $draft.workingDirectory)
        }
        MCPKeyValueEditor(
            title: "Environment",
            rows: $draft.environment,
            valueLabel: "Environment value")
        MCPSecretReferenceEditor(
            title: "Compatibility env_vars",
            rows: $draft.inheritedEnvironment)
        Section("Network") {
            MCPMultilineField(
                title:
                    "Exact HTTPS origins, one per line; leave empty to deny network",
                text: $draft.networkOrigins)
            Text(
                "Managed stdio remains inside the permission, workspace, sandbox, and durable execution boundaries of the direct-distribution macOS product.")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var policyForm: some View {
        Section("Protocol") {
            Picker(
                "Protocol profile",
                selection: $draft.protocolProfile
            ) {
                Text("codex-compat")
                    .tag(MCPProtocolProfile.codexCompat)
                Text("standard-extended")
                    .tag(
                        MCPProtocolProfile
                            .standardExtended)
            }
            TextField(
                "Maximum protocol version",
                text: $draft.maximumProtocolVersion)
            Text(
                "codex-compat provides the conservative client surface. standard-extended enables the full negotiated roots, sampling, elicitation, subscription, completion, and task client features when their real host services are installed.")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(.secondary)
        }
        Section("Default authority") {
            TextField(
                "Environment identity",
                text: $draft.environmentID)
            Text(
                "Changing this stable identity forces a new exact connection generation and invalidates older remembered authority.")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(.secondary)
            Toggle(
                "Required by default",
                isOn: $draft.required)
            Toggle(
                "Allow parallel calls",
                isOn: $draft.parallelCalls)
            Picker(
                "Default approval",
                selection: $draft.approvalMode
            ) {
                Text("Prompt")
                    .tag(MCPApprovalMode.prompt)
                Text("Writes")
                    .tag(MCPApprovalMode.writes)
                Text("Auto")
                    .tag(MCPApprovalMode.auto)
                Text("Approve")
                    .tag(MCPApprovalMode.approve)
            }
            ForEach(
                $draft.toolApprovalOverrides
            ) { $override in
                HStack {
                    TextField(
                        "Exact tool name",
                        text: $override.toolName)
                    Picker(
                        "Approval",
                        selection: $override.mode
                    ) {
                        Text("Prompt")
                            .tag(MCPApprovalMode.prompt)
                        Text("Writes")
                            .tag(MCPApprovalMode.writes)
                        Text("Auto")
                            .tag(MCPApprovalMode.auto)
                        Text("Approve")
                            .tag(MCPApprovalMode.approve)
                    }
                    .labelsHidden()
                    Button(role: .destructive) {
                        draft.toolApprovalOverrides
                            .removeAll {
                                $0.id == override.id
                            }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                }
            }
            Button("Add exact tool approval override") {
                draft.toolApprovalOverrides.append(
                    .init())
            }
            Text(
                "Each override is bound to one exact remote tool name. Duplicate or empty names fail closed when the draft is tested.")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(.secondary)
        }
        Section("Required capabilities") {
            ForEach(
                MCPServerEditorCapabilities.all,
                id: \.self
            ) { capability in
                Toggle(
                    capability.rawValue,
                    isOn: Binding(
                        get: {
                            draft.requiredCapabilities
                                .contains(capability)
                        },
                        set: { enabled in
                            if enabled {
                                draft.requiredCapabilities
                                    .insert(capability)
                            } else {
                                draft.requiredCapabilities
                                    .remove(capability)
                            }
                        }))
            }
        }
        Section("Timeouts") {
            Stepper(
                "Startup: \(draft.startupMilliseconds) ms",
                value: $draft.startupMilliseconds,
                in: 100...3_600_000,
                step: 1_000)
            Stepper(
                "Call: \(draft.callMilliseconds) ms",
                value: $draft.callMilliseconds,
                in: 100...3_600_000,
                step: 1_000)
            Stepper(
                "Shutdown: \(draft.shutdownMilliseconds) ms",
                value: $draft.shutdownMilliseconds,
                in: 100...3_600_000,
                step: 500)
        }
        Section {
            Text(
                "Test & Save performs a real isolated initialize and complete negotiated discovery for this exact draft. Only the matching proof may commit a new immutable catalog revision.")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(.secondary)
        }
    }

    private var filtersForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(
                "Allow lists narrow a namespace when non-empty; deny lists always win. Session attachment and Agent grant filters can only narrow these server limits further.")
                .foregroundStyle(.secondary)
            MCPFilterEditor(
                title: "Tools",
                allow: $draft.toolAllow,
                deny: $draft.toolDeny)
            MCPFilterEditor(
                title: "Resources",
                allow: $draft.resourceAllow,
                deny: $draft.resourceDeny)
            MCPFilterEditor(
                title: "Prompts",
                allow: $draft.promptAllow,
                deny: $draft.promptDeny)
            MCPFilterEditor(
                title: "Completions",
                allow: $draft.completionAllow,
                deny: $draft.completionDeny)
        }
    }

    private var isSaveable: Bool {
        !draft.alias.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty
            && !draft.displayName.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty
            && (draft.transport != .streamableHTTP
                || URL(string: draft.endpoint) != nil)
    }

    private static func
        isInsecureLoopbackDevelopmentEndpoint(
            _ rawValue: String
        ) -> Bool
    {
        guard let components =
                URLComponents(
                    string:
                        rawValue.trimmingCharacters(
                            in:
                                .whitespacesAndNewlines)),
              components.scheme?
                .lowercased() == "http",
              let host =
                components.host?
                    .lowercased()
        else {
            return false
        }
        return host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
    }

    private func cancelEditor() {
        guard let preparedSession else {
            dismiss()
            return
        }
        self.preparedSession = nil
        Task {
            await env.mcp
                .discardPreparedEditorSession(
                    preparedSession)
            dismiss()
        }
    }
}

enum MCPServerEditorCapabilities {
    static let all: [MCPGrantedCapability] = [
        .tools, .resources, .prompts, .completions,
        .logging, .progress, .subscriptions, .roots,
        .sampling, .elicitation, .tasks,
    ]
}

private struct MCPKeyValueEditor: View {
    let title: LocalizedStringKey
    @Binding var rows: [MCPServerEditorKeyValue]
    let valueLabel: LocalizedStringKey

    var body: some View {
        Section(title) {
            ForEach($rows) { $row in
                HStack {
                    TextField("Name", text: $row.name)
                        .frame(minWidth: 140)
                    if row.storesAsSecret {
                        SecureField(
                            row.existingSecretReference == nil
                                ? "Secret value"
                                : "New secret (empty retains Keychain reference)",
                            text: $row.value)
                    } else {
                        TextField(
                            valueLabel,
                            text: $row.value)
                    }
                    Toggle(
                        "Secret",
                        isOn: $row.storesAsSecret)
                        .toggleStyle(.checkbox)
                    Button(role: .destructive) {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                }
            }
            Button("Add value") {
                rows.append(.init())
            }
            Text(
                "Secret rows are stored in Keychain. Literal rows pass conservative secret screening before they can be saved.")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(.secondary)
        }
    }
}

private struct MCPSecretReferenceEditor: View {
    let title: LocalizedStringKey
    @Binding var rows: [MCPServerEditorKeyValue]

    var body: some View {
        Section(title) {
            ForEach($rows) { $row in
                HStack {
                    TextField(
                        "Environment name",
                        text: $row.name)
                        .frame(minWidth: 140)
                    SecureField(
                        row.existingSecretReference == nil
                            ? "Secret value"
                            : "New secret (empty retains Keychain reference)",
                        text: $row.value)
                    Button(role: .destructive) {
                        rows.removeAll {
                            $0.id == row.id
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                }
            }
            Button("Add env_vars SecretRef") {
                rows.append(
                    .init(storesAsSecret: true))
            }
            Text(
                "These compatibility environment names never read the ambient process environment. Each value is an explicit Keychain SecretRef and is injected only into the exact authorized stdio generation.")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(.secondary)
        }
    }
}

private struct MCPMultilineField: View {
    let title: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(IntatisTypography.system(.body, design: .monospaced))
                .frame(minHeight: 72)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary))
        }
    }
}

struct MCPFilterEditor: View {
    let title: LocalizedStringKey
    @Binding var allow: String
    @Binding var deny: String

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                MCPMultilineField(
                    title: "Allow, one exact name per line",
                    text: $allow)
                MCPMultilineField(
                    title: "Deny, one exact name per line",
                    text: $deny)
            }
        } label: {
            Text(title)
        }
    }
}

private extension MCPTransportConfiguration {
    var oauthConfiguration: MCPOAuthConfiguration? {
        guard case .streamableHTTP(let http) = self else {
            return nil
        }
        return http.oauth
    }
}
#endif
