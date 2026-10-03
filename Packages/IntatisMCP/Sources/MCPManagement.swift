import Foundation
import IntatisProtocol

public enum MCPServerSetupStatus:
    String, Codable, Equatable, Hashable, Sendable {
    case ready
    case disabled
    case setupRequired = "setup_required"
    case authRequired = "auth_required"
    case tombstoned
}

/// Stable, secret-free row shared by the native settings UI and CLI.
public struct MCPServerInventoryRecord:
    Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let alias: String
    public let serverID: MCPServerID
    public let currentRevision: MCPServerRevision?
    public let displayName: String
    public let transport: MCPTransportKind?
    public let protocolProfile: MCPProtocolProfile?
    public let maximumProtocolVersion: MCPProtocolVersion?
    public let enabled: Bool
    public let required: Bool
    public let approvalMode: MCPApprovalMode?
    public let parallelCalls: Bool
    public let setupStatus: MCPServerSetupStatus
    public let sourceKind: MCPConfigurationSourceKind?
    public let sourceLabel: String?

    public init(
        head: MCPServerCatalogHead,
        definition: MCPServerDefinition?,
        tombstoned: Bool
    ) {
        id = head.serverID.rawValue
        alias = head.alias
        serverID = head.serverID
        currentRevision = head.currentRevision
        displayName =
            definition?.configuration.displayName ?? head.alias
        transport = definition?.configuration.transport.kind
        protocolProfile =
            definition?.configuration.protocolProfile
        maximumProtocolVersion =
            definition?.configuration.maximumProtocolVersion
        enabled = !head.disabled
            && definition?.configuration.enabled == true
            && !tombstoned
        required = definition?.configuration.required ?? false
        approvalMode =
            definition?.configuration.approvalPolicy.serverDefault
        parallelCalls =
            definition?.configuration.parallelCalls ?? false
        if tombstoned {
            setupStatus = .tombstoned
        } else if head.disabled
                    || definition?.configuration.enabled == false {
            setupStatus = .disabled
        } else if definition == nil {
            setupStatus = .setupRequired
        } else if Self.hasOAuthWithoutAccount(definition) {
            setupStatus = .authRequired
        } else {
            setupStatus = .ready
        }
        sourceKind = definition?.configuration.provenance.sourceKind
        sourceLabel = definition?.configuration.provenance.sourceLabel
    }

    private static func hasOAuthWithoutAccount(
        _ definition: MCPServerDefinition?
    ) -> Bool {
        guard case .streamableHTTP(let http)? =
                definition?.configuration.transport,
              let oauth = http.oauth,
              oauth.enabled else {
            return false
        }
        return oauth.accountReference == nil
    }
}

public struct MCPDoctorFinding:
    Codable, Equatable, Hashable, Sendable {
    public enum Severity:
        String, Codable, Equatable, Hashable, Sendable {
        case info
        case warning
        case error
    }

    public let severity: Severity
    public let code: String
    public let serverID: MCPServerID?
    public let summary: String

    public init(
        severity: Severity,
        code: String,
        serverID: MCPServerID? = nil,
        summary: String
    ) {
        self.severity = severity
        self.code = code
        self.serverID = serverID
        self.summary = String(summary.prefix(512))
    }
}

public enum MCPManagementError:
    Error, Equatable, LocalizedError, Sendable {
    case serverNotFound(String)
    case currentRevisionMissing(MCPServerID)
    case configurationTestFailed(String)
    case unsupportedTransport(
        MCPTransportKind,
        MCPProductHostProfile
    )
    case concurrentCatalogMutation

    public var errorDescription: String? {
        switch self {
        case .serverNotFound(let value):
            return "MCP server '\(value)' was not found."
        case .currentRevisionMissing(let server):
            return "MCP server \(server.rawValue) has no current revision."
        case .configurationTestFailed(let code):
            return "MCP configuration Test failed (\(code))."
        case .unsupportedTransport(let transport, let host):
            return "MCP transport \(transport.rawValue) is unavailable for \(host.rawValue)."
        case .concurrentCatalogMutation:
            return "The MCP catalog changed repeatedly; reload before applying this operation."
        }
    }
}

public typealias MCPConfigurationTestExecutor =
    @Sendable (
        MCPPreparedServerConfiguration
    ) async throws -> MCPConfigurationTestResult

public typealias MCPCatalogPublicationSink =
    @Sendable (MCPServerCatalog) async throws -> Void

public struct MCPPreparedSaveReceipt:
    Equatable, Sendable
{
    public let prepared:
        MCPPreparedServerConfiguration
    public let definition: MCPServerDefinition
    public let catalog: MCPServerCatalog

    public init(
        prepared: MCPPreparedServerConfiguration,
        definition: MCPServerDefinition,
        catalog: MCPServerCatalog
    ) {
        self.prepared = prepared
        self.definition = definition
        self.catalog = catalog
    }
}

/// One catalog/control service used by both product surfaces.
///
/// All writes remain CAS transactions in `MCPServerCatalogStore`. Add/edit/
/// duplicate/import candidates cannot be saved unless the exact immutable
/// draft has completed an isolated Test and produced a matching proof.
public actor MCPManagementService {
    public let hostProfile: MCPProductHostProfile

    private let catalogStore: MCPServerCatalogStore
    private let testJournal: MCPCatalogOperationJournalStore
    private let testExecutor: MCPConfigurationTestExecutor
    private let testHardGate:
        any MCPConfigurationTestHardGate
    private let catalogPublicationSink:
        MCPCatalogPublicationSink
    private let maximumCASAttempts = 4

    public init(
        catalogStore: MCPServerCatalogStore,
        testJournal: MCPCatalogOperationJournalStore,
        hostProfile: MCPProductHostProfile,
        testHardGate:
            (any MCPConfigurationTestHardGate)? = nil,
        catalogPublicationSink:
            MCPCatalogPublicationSink? = nil,
        testExecutor:
            @escaping MCPConfigurationTestExecutor
    ) {
        self.catalogStore = catalogStore
        self.testJournal = testJournal
        self.hostProfile = hostProfile
        self.testHardGate = testHardGate
            ?? MCPDeterministicConfigurationTestHardGate(
                hostProfile: hostProfile)
        self.catalogPublicationSink =
            catalogPublicationSink ?? {
                _ = try await
                    MCPProcessCatalogRuntimeRegistry
                        .shared.publish($0)
            }
        self.testExecutor = testExecutor
    }

    public func catalog() async throws -> MCPServerCatalog {
        try await catalogStore.load()
    }

    public func inventory() async throws
        -> [MCPServerInventoryRecord]
    {
        let catalog = try await catalogStore.load()
        return catalog.heads.map { head in
            let definition = currentDefinition(
                head: head,
                catalog: catalog)
            let tombstoned = definition.map {
                catalog.isTombstoned($0.reference)
            } ?? false
            return MCPServerInventoryRecord(
                head: head,
                definition: definition,
                tombstoned: tombstoned)
        }.sorted { $0.alias < $1.alias }
    }

    public func definition(
        serverOrAlias value: String
    ) async throws -> MCPServerDefinition {
        let catalog = try await catalogStore.load()
        return try resolveDefinition(value, catalog: catalog)
    }

    public func stage(
        _ configuration: MCPServerConfiguration
    ) throws -> MCPConfigurationStaging {
        guard hostProfile.permits(configuration.transport.kind) else {
            throw MCPManagementError.unsupportedTransport(
                configuration.transport.kind,
                hostProfile)
        }
        return try MCPConfigurationStaging(
            configuration: configuration)
    }

    /// Plans an exact immutable revision from one complete catalog snapshot.
    public func prepare(
        alias: String,
        configuration: MCPServerConfiguration
    ) async throws -> MCPPreparedServerConfiguration {
        guard hostProfile.permits(
            configuration.transport.kind)
        else {
            throw MCPManagementError.unsupportedTransport(
                configuration.transport.kind,
                hostProfile)
        }
        let snapshot = try await catalogStore.load()
        return try MCPPreparedServerConfiguration.plan(
            alias: alias,
            staging: MCPConfigurationStaging(
                configuration: configuration),
            catalog: snapshot)
    }

    /// Predicts every revision from the same snapshot. No item observes a
    /// sibling draft and Save later performs one whole-batch CAS.
    public func prepareBatch(
        _ drafts: [(
            alias: String,
            configuration: MCPServerConfiguration
        )]
    ) async throws -> [MCPPreparedServerConfiguration] {
        for draft in drafts {
            guard hostProfile.permits(
                draft.configuration.transport.kind)
            else {
                throw MCPManagementError.unsupportedTransport(
                    draft.configuration.transport.kind,
                    hostProfile)
            }
        }
        let snapshot = try await catalogStore.load()
        return try MCPPreparedServerConfiguration.planBatch(
            try drafts.map {
                (
                    alias: $0.alias,
                    staging: try MCPConfigurationStaging(
                        configuration: $0.configuration)
                )
            },
            catalog: snapshot)
    }

    public func test(
        _ prepared: MCPPreparedServerConfiguration,
        authorization: MCPConfigurationTestAuthorization
    ) async throws -> MCPConfigurationTestResult {
        guard hostProfile.permits(
            prepared.definition.configuration.transport.kind)
        else {
            throw MCPManagementError.unsupportedTransport(
                prepared.definition.configuration.transport.kind,
                hostProfile)
        }
        let record = try MCPGlobalTestOperationRecord(
            prepared: prepared,
            authorization: authorization)
        _ = try await testJournal.registerFirstWrite(record)

        let request = MCPPreparedConfigurationTestRequest(
            prepared: prepared,
            authorization: authorization)
        switch await testHardGate.evaluate(request) {
        case .allow:
            break
        case .deny(let reason):
            let denied = try MCPConfigurationTestResult(
                challenge: prepared.staging.challenge,
                terminal: .failed,
                testedIdentityFingerprint:
                    prepared.staging
                        .expectedTestedIdentityFingerprint,
                sanitizedReasonCode: reason)
            _ = try await testJournal.settleFirstTerminal(
                operationID: record.operationID,
                result: denied)
            throw MCPManagementError.configurationTestFailed(
                reason)
        }

        let result: MCPConfigurationTestResult
        do {
            result = try await testExecutor(prepared)
        } catch is CancellationError {
            result = try MCPConfigurationTestResult(
                challenge: prepared.staging.challenge,
                terminal: .cancelled,
                testedIdentityFingerprint:
                    prepared.staging
                        .expectedTestedIdentityFingerprint,
                sanitizedReasonCode: "test_cancelled")
        } catch {
            result = try MCPConfigurationTestResult(
                challenge: prepared.staging.challenge,
                terminal: .failed,
                testedIdentityFingerprint:
                    prepared.staging
                        .expectedTestedIdentityFingerprint,
                sanitizedReasonCode: "test_runtime_failed")
        }
        _ = try await testJournal.settleFirstTerminal(
            operationID: record.operationID,
            result: result)
        return result
    }

    @discardableResult
    public func savePrepared(
        _ prepared: MCPPreparedServerConfiguration,
        proof: MCPPreparedConfigurationTestProof
    ) async throws -> MCPServerDefinition {
        try await savePreparedReceipt(
            prepared,
            proof: proof).definition
    }

    /// Returns the exact post-CAS catalog bytes needed to activate an OAuth
    /// staged handle without racing a later catalog mutation.
    public func savePreparedReceipt(
        _ prepared: MCPPreparedServerConfiguration,
        proof: MCPPreparedConfigurationTestProof
    ) async throws -> MCPPreparedSaveReceipt {
        let saved = try await catalogStore.savePrepared(
            prepared,
            proof: proof)
        guard saved.definitions == [prepared.definition] else {
            throw MCPServerCatalogError.preparedPlanMismatch
        }
        try await catalogPublicationSink(saved.catalog)
        return MCPPreparedSaveReceipt(
            prepared: prepared,
            definition: prepared.definition,
            catalog: saved.catalog)
    }

    @discardableResult
    public func testAndSavePrepared(
        _ prepared: MCPPreparedServerConfiguration,
        authorization: MCPConfigurationTestAuthorization
    ) async throws -> MCPServerDefinition {
        let result = try await test(
            prepared,
            authorization: authorization)
        guard result.terminal == .succeeded else {
            throw MCPManagementError.configurationTestFailed(
                result.sanitizedReasonCode)
        }
        return try await savePrepared(
            prepared,
            proof: prepared.accept(result))
    }

    public func testAndSavePreparedReceipt(
        _ prepared: MCPPreparedServerConfiguration,
        authorization: MCPConfigurationTestAuthorization
    ) async throws -> (
        receipt: MCPPreparedSaveReceipt,
        proof: MCPPreparedConfigurationTestProof
    ) {
        let result = try await test(
            prepared,
            authorization: authorization)
        guard result.terminal == .succeeded else {
            throw MCPManagementError.configurationTestFailed(
                result.sanitizedReasonCode)
        }
        let proof = try prepared.accept(result)
        return (
            try await savePreparedReceipt(
                prepared,
                proof: proof),
            proof
        )
    }

    @discardableResult
    public func testAndSavePreparedBatch(
        _ prepared:
            [MCPPreparedServerConfiguration],
        authorization:
            MCPConfigurationTestAuthorization,
        importMarker: MCPImportMarker? = nil
    ) async throws -> [MCPServerDefinition] {
        var items: [MCPPreparedCatalogSaveItem] = []
        items.reserveCapacity(prepared.count)
        for item in prepared {
            let result = try await test(
                item,
                authorization: authorization)
            guard result.terminal == .succeeded else {
                throw MCPManagementError.configurationTestFailed(
                    result.sanitizedReasonCode)
            }
            items.append(MCPPreparedCatalogSaveItem(
                prepared: item,
                proof: try item.accept(result)))
        }
        let saved = try await catalogStore.savePreparedBatch(
            items,
            importMarker: importMarker)
        guard saved.definitions
                == prepared.map(\.definition)
        else {
            throw MCPServerCatalogError.preparedPlanMismatch
        }
        try await catalogPublicationSink(saved.catalog)
        return saved.definitions
    }

    @discardableResult
    public func setEnabled(
        serverOrAlias value: String,
        enabled: Bool
    ) async throws -> MCPServerCatalog {
        for attempt in 0..<maximumCASAttempts {
            let snapshot = try await catalogStore.load()
            let head = try resolveHead(value, catalog: snapshot)
            do {
                let updated = try await catalogStore.setDisabled(
                    serverID: head.serverID,
                    disabled: !enabled,
                    expectedGeneration: snapshot.generation)
                try await catalogPublicationSink(updated)
                return updated
            } catch MCPServerCatalogError.compareAndSwapConflict
                    where attempt + 1 < maximumCASAttempts {
                continue
            }
        }
        throw MCPManagementError.concurrentCatalogMutation
    }

    /// Logical delete is tombstone-first. Permanent purge remains a separate
    /// zero-reference operation owned by the global reference index.
    @discardableResult
    public func deleteCurrent(
        serverOrAlias value: String,
        reason: MCPTombstoneReason = .userDelete
    ) async throws -> MCPServerCatalog {
        for attempt in 0..<maximumCASAttempts {
            let snapshot = try await catalogStore.load()
            let definition = try resolveDefinition(
                value,
                catalog: snapshot)
            do {
                let updated = try await catalogStore.tombstone(
                    definition.reference,
                    reason: reason,
                    expectedGeneration: snapshot.generation)
                try await catalogPublicationSink(updated)
                return updated
            } catch MCPServerCatalogError.compareAndSwapConflict
                    where attempt + 1 < maximumCASAttempts {
                continue
            }
        }
        throw MCPManagementError.concurrentCatalogMutation
    }

    public func duplicateDraft(
        serverOrAlias value: String,
        newServerID: MCPServerID = .new(),
        displayName: String? = nil
    ) async throws -> MCPConfigurationStaging {
        let source = try await definition(serverOrAlias: value)
            .configuration
        let duplicated = try MCPServerConfiguration(
            serverID: newServerID,
            displayName: displayName
                ?? "\(source.displayName) Copy",
            enabled: source.enabled,
            required: source.required,
            requiredCapabilities:
                source.requiredCapabilities,
            protocolProfile: source.protocolProfile,
            maximumProtocolVersion:
                source.maximumProtocolVersion,
            approvalPolicy: source.approvalPolicy,
            parallelCalls: source.parallelCalls,
            timeouts: source.timeouts,
            filters: source.filters,
            transport: source.transport,
            environmentReference:
                source.environmentReference,
            provenance: try MCPConfigurationProvenance(
                sourceKind: .intatisUser,
                sourceLabel: "duplicated-mcp-server"))
        return try stage(duplicated)
    }

    public func importPreview(
        at explicitURL: URL,
        format: MCPImportFormat
    ) throws -> MCPImportParseResult {
        try MCPConfigurationImporter.parseExplicitFile(
            at: explicitURL,
            format: format)
    }

    public func exportSanitized(
        includeDisabled: Bool = true
    ) async throws -> Data {
        try MCPConfigurationExporter.sanitizedMCPJSON(
            catalog: await catalogStore.load(),
            includeDisabled: includeDisabled)
    }

    public func doctor() async throws -> [MCPDoctorFinding] {
        let catalog = try await catalogStore.load()
        var findings: [MCPDoctorFinding] = []
        for head in catalog.heads {
            guard let definition = currentDefinition(
                head: head,
                catalog: catalog) else {
                findings.append(MCPDoctorFinding(
                    severity: .error,
                    code: "current_revision_missing",
                    serverID: head.serverID,
                    summary:
                        "The catalog head has no resolvable immutable revision."))
                continue
            }
            if catalog.isTombstoned(definition.reference) {
                findings.append(MCPDoctorFinding(
                    severity: .info,
                    code: "revision_tombstoned",
                    serverID: head.serverID,
                    summary:
                        "The current revision is tombstoned and cannot create a new connection."))
            }
            if !hostProfile.permits(
                definition.configuration.transport.kind) {
                findings.append(MCPDoctorFinding(
                    severity: .error,
                    code: "transport_not_linked",
                    serverID: head.serverID,
                    summary:
                        "This product host does not link the configured transport."))
            }
            let references = secretReferences(
                definition.configuration.transport)
            for reference in references
                where reference.storageClass
                    != hostProfile.requiredSecretStorageClass {
                findings.append(MCPDoctorFinding(
                    severity: .error,
                    code: "credential_storage_mismatch",
                    serverID: head.serverID,
                    summary:
                        "A credential reference belongs to a different host storage class."))
            }
        }
        if findings.isEmpty {
            findings.append(MCPDoctorFinding(
                severity: .info,
                code: "catalog_healthy",
                summary:
                    "The MCP catalog passed structural, transport, and credential-reference checks."))
        }
        return findings
    }

    private func currentDefinition(
        head: MCPServerCatalogHead,
        catalog: MCPServerCatalog
    ) -> MCPServerDefinition? {
        guard let revision = head.currentRevision else {
            return nil
        }
        return catalog.definition(for: MCPServerReference(
            serverID: head.serverID,
            serverRevision: revision))
    }

    private func resolveHead(
        _ value: String,
        catalog: MCPServerCatalog
    ) throws -> MCPServerCatalogHead {
        guard let head = catalog.heads.first(where: {
            $0.alias == value || $0.serverID.rawValue == value
        }) else {
            throw MCPManagementError.serverNotFound(value)
        }
        return head
    }

    private func resolveDefinition(
        _ value: String,
        catalog: MCPServerCatalog
    ) throws -> MCPServerDefinition {
        let head = try resolveHead(value, catalog: catalog)
        guard let definition = currentDefinition(
            head: head,
            catalog: catalog) else {
            throw MCPManagementError.currentRevisionMissing(
                head.serverID)
        }
        return definition
    }

    private func secretReferences(
        _ transport: MCPTransportConfiguration
    ) -> [MCPSecretReference] {
        switch transport {
        case .stdio(let value):
            return value.environment.values.compactMap {
                if case .secret(let reference) = $0 {
                    return reference
                }
                return nil
            } + Array(
                value.inheritedEnvironmentReferences.values)
        case .streamableHTTP(let value):
            var references = value.headers.values.compactMap {
                if case .secret(let reference) = $0 {
                    return reference
                }
                return nil
            }
            if let bearer = value.bearerTokenReference {
                references.append(bearer)
            }
            if let clientSecret =
                    value.oauth?.clientSecretReference {
                references.append(clientSecret)
            }
            return references
        }
    }
}
