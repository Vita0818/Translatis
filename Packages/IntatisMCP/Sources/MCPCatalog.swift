import Foundation
import IntatisProtocol

// MARK: - Test-before-save staging

/// A secret-free challenge created for one exact canonical draft. Constructing
/// it performs validation only; it never starts a process or opens a socket.
public struct MCPConfigurationTestChallenge: Codable, Equatable, Hashable, Sendable {
    public let challengeID: String
    public let configurationFingerprint: String
    public let transportFingerprint: String

    init(
        challengeID: String,
        configurationFingerprint: String,
        transportFingerprint: String
    ) {
        self.challengeID = challengeID
        self.configurationFingerprint = configurationFingerprint
        self.transportFingerprint = transportFingerprint
    }
}

public enum MCPConfigurationTestTerminal: String, Codable, Equatable, Hashable, Sendable {
    case succeeded
    case failed
    case cancelled
    case timedOut = "timed_out"
}

/// Sanitized result asserted by the isolated Test runtime. No wire payload,
/// environment value, header, OAuth token, or server instructions are allowed.
public struct MCPConfigurationTestResult: Codable, Equatable, Hashable, Sendable {
    public let challenge: MCPConfigurationTestChallenge
    public let terminal: MCPConfigurationTestTerminal
    public let testedIdentityFingerprint: String
    public let completedAt: Date
    public let sanitizedReasonCode: String

    public init(
        challenge: MCPConfigurationTestChallenge,
        terminal: MCPConfigurationTestTerminal,
        testedIdentityFingerprint: String,
        completedAt: Date = Date(),
        sanitizedReasonCode: String
    ) throws {
        guard MCPConfigurationValidation.isSHA256(testedIdentityFingerprint),
              (1...128).contains(sanitizedReasonCode.utf8.count) else {
            throw MCPServerCatalogError.invalidTestResult
        }
        try MCPConfigurationValidation.validateIdentifier(
            sanitizedReasonCode,
            field: "test_reason")
        self.challenge = challenge
        self.terminal = terminal
        self.testedIdentityFingerprint = testedIdentityFingerprint
        self.completedAt = completedAt
        self.sanitizedReasonCode = sanitizedReasonCode
    }
}

/// One-useable proof that the exact staged configuration completed a
/// successful, isolated Test. The catalog checks all fields and expiry again
/// while holding its mutation lock.
public struct MCPConfigurationTestProof: Codable, Equatable, Hashable, Sendable {
    public let challengeID: String
    public let configurationFingerprint: String
    public let transportFingerprint: String
    public let testedIdentityFingerprint: String
    public let completedAt: Date
    public let validUntil: Date

    init(
        result: MCPConfigurationTestResult,
        validUntil: Date
    ) {
        challengeID = result.challenge.challengeID
        configurationFingerprint = result.challenge.configurationFingerprint
        transportFingerprint = result.challenge.transportFingerprint
        testedIdentityFingerprint = result.testedIdentityFingerprint
        completedAt = result.completedAt
        self.validUntil = validUntil
    }
}

/// Canonical draft plus its random Test challenge.
///
/// This value deliberately has no transport/client dependency and cannot
/// launch a server. A later runtime consumes `challenge`, performs an isolated
/// Test generation, and returns a `MCPConfigurationTestResult`.
public struct MCPConfigurationStaging:
    Equatable, Hashable, Sendable {
    public static let defaultProofLifetime: TimeInterval = 15 * 60

    public let configuration: MCPServerConfiguration
    public let challenge: MCPConfigurationTestChallenge

    public init(configuration: MCPServerConfiguration) throws {
        let canonical = try configuration.validatedCanonical()
        self.configuration = canonical
        challenge = MCPConfigurationTestChallenge(
            challengeID: UUID().uuidString.lowercased(),
            configurationFingerprint: canonical.canonicalFingerprint,
            transportFingerprint: canonical.transport.connectionFingerprint)
    }

    public func accept(
        _ result: MCPConfigurationTestResult,
        proofLifetime: TimeInterval = defaultProofLifetime
    ) throws -> MCPConfigurationTestProof {
        guard proofLifetime > 0, proofLifetime <= 24 * 60 * 60,
              result.terminal == .succeeded,
              result.challenge == challenge,
              result.testedIdentityFingerprint
                == expectedTestedIdentityFingerprint else {
            throw MCPServerCatalogError.testRequired
        }
        return MCPConfigurationTestProof(
            result: result,
            validUntil: result.completedAt.addingTimeInterval(proofLifetime))
    }

    public var expectedTestedIdentityFingerprint: String {
        switch configuration.transport {
        case .stdio(let stdio):
            return stdio.launchArtifact.fingerprint
        case .streamableHTTP(let http):
            return MCPConfigurationCanonical.sha256(
                Data(http.canonicalOrigin.utf8))
        }
    }

    public func validate(proof: MCPConfigurationTestProof, at now: Date) throws {
        guard proof.challengeID == challenge.challengeID,
              proof.configurationFingerprint == configuration.canonicalFingerprint,
              proof.transportFingerprint == configuration.transport.connectionFingerprint,
              proof.testedIdentityFingerprint == expectedTestedIdentityFingerprint,
              proof.completedAt <= now,
              now <= proof.validUntil else {
            throw MCPServerCatalogError.testRequired
        }
    }
}

// MARK: - Immutable catalog model

public struct MCPServerDefinition: Codable, Equatable, Hashable, Sendable {
    public let reference: MCPServerReference
    public let revisionOrdinal: UInt64
    public let configuration: MCPServerConfiguration
    public let definitionFingerprint: String

    init(
        configuration: MCPServerConfiguration,
        revisionOrdinal: UInt64
    ) {
        self.configuration = configuration
        self.revisionOrdinal = revisionOrdinal
        let serverDigest = MCPConfigurationCanonical.sha256(
            Data(configuration.serverID.rawValue.utf8))
        reference = MCPServerReference(
            serverID: configuration.serverID,
            serverRevision: MCPServerRevision(
                rawValue: "mcprev_\(serverDigest.prefix(16))_\(revisionOrdinal)"))
        definitionFingerprint = configuration.canonicalFingerprint
    }

    func validated() throws -> MCPServerDefinition {
        let canonical = try configuration.validatedCanonical()
        guard revisionOrdinal > 0 else {
            throw MCPServerCatalogError.catalogCorrupted
        }
        let rebuilt = MCPServerDefinition(
            configuration: canonical,
            revisionOrdinal: revisionOrdinal)
        guard rebuilt == self else {
            throw MCPServerCatalogError.catalogCorrupted
        }
        return rebuilt
    }

    /// Constructs an immutable revision used only by an isolated global Test.
    /// It is never published into the user's catalog by this operation.
    public static func isolatedTest(
        configuration: MCPServerConfiguration
    ) throws -> MCPServerDefinition {
        MCPServerDefinition(
            configuration: try configuration.validatedCanonical(),
            revisionOrdinal: 1)
    }
}

public struct MCPServerCatalogHead: Codable, Equatable, Hashable, Sendable {
    public let serverID: MCPServerID
    public let alias: String
    public let currentRevision: MCPServerRevision?
    public let disabled: Bool

    public init(
        serverID: MCPServerID,
        alias: String,
        currentRevision: MCPServerRevision?,
        disabled: Bool
    ) throws {
        try MCPConfigurationValidation.validateIdentifier(alias, field: "alias")
        self.serverID = serverID
        self.alias = alias
        self.currentRevision = currentRevision
        self.disabled = disabled
    }
}

public enum MCPTombstoneReason: String, Codable, Equatable, Hashable, Sendable {
    case userDelete = "user_delete"
    case sourceRemoved = "source_removed"
    case securityRevocation = "security_revocation"
    case migration
}

public struct MCPServerRevisionTombstone: Codable, Equatable, Hashable, Sendable {
    public let reference: MCPServerReference
    public let reason: MCPTombstoneReason
    public let tombstonedAt: Date

    public init(
        reference: MCPServerReference,
        reason: MCPTombstoneReason,
        tombstonedAt: Date = Date()
    ) {
        self.reference = reference
        self.reason = reason
        self.tombstonedAt = tombstonedAt
    }
}

/// Secret-free marker preventing an explicitly imported source from being
/// silently repeated. It does not grant, attach, connect, or retain a revision.
public struct MCPImportMarker: Codable, Equatable, Hashable, Sendable {
    public let sourceKind: MCPConfigurationSourceKind
    public let sourceFingerprint: String
    public let formatVersion: Int
    public let importedServerIDs: [MCPServerID]

    public init(
        sourceKind: MCPConfigurationSourceKind,
        sourceFingerprint: String,
        formatVersion: Int,
        importedServerIDs: [MCPServerID]
    ) throws {
        guard MCPConfigurationValidation.isSHA256(sourceFingerprint),
              formatVersion > 0 else {
            throw MCPServerCatalogError.invalidImportMarker
        }
        self.sourceKind = sourceKind
        self.sourceFingerprint = sourceFingerprint
        self.formatVersion = formatVersion
        self.importedServerIDs = Array(Set(importedServerIDs)).sorted {
            $0.rawValue < $1.rawValue
        }
    }
}

private struct MCPServerCatalogIntegrityPayload: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let definitions: [MCPServerDefinition]
    let heads: [MCPServerCatalogHead]
    let tombstones: [MCPServerRevisionTombstone]
    let importMarkers: [MCPImportMarker]
}

/// Whole, atomically published global catalog snapshot.
public struct MCPServerCatalog: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generation: UInt64
    public let definitions: [MCPServerDefinition]
    public let heads: [MCPServerCatalogHead]
    public let tombstones: [MCPServerRevisionTombstone]
    public let importMarkers: [MCPImportMarker]
    public let contentDigest: String

    init(
        generation: UInt64,
        definitions: [MCPServerDefinition],
        heads: [MCPServerCatalogHead],
        tombstones: [MCPServerRevisionTombstone],
        importMarkers: [MCPImportMarker]
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.generation = generation
        self.definitions = definitions.sorted(by: Self.definitionOrder)
        self.heads = heads.sorted { $0.serverID.rawValue < $1.serverID.rawValue }
        self.tombstones = tombstones.sorted {
            Self.referenceKey($0.reference) < Self.referenceKey($1.reference)
        }
        self.importMarkers = importMarkers.sorted {
            if $0.sourceKind != $1.sourceKind {
                return $0.sourceKind.rawValue < $1.sourceKind.rawValue
            }
            return $0.sourceFingerprint < $1.sourceFingerprint
        }
        let payload = MCPServerCatalogIntegrityPayload(
            schemaVersion: schemaVersion,
            generation: generation,
            definitions: self.definitions,
            heads: self.heads,
            tombstones: self.tombstones,
            importMarkers: self.importMarkers)
        contentDigest = MCPConfigurationCanonical.sha256(
            try MCPConfigurationCanonical.encode(payload))
    }

    public static var empty: MCPServerCatalog {
        // This construction has no failing user input.
        try! MCPServerCatalog(
            generation: 0,
            definitions: [],
            heads: [],
            tombstones: [],
            importMarkers: [])
    }

    /// Secret-free one-definition catalog for an isolated Test generation.
    /// Saving still requires the resulting exact challenge proof through
    /// `MCPServerCatalogStore`; this helper cannot bypass Test-before-save.
    public static func isolatedTest(
        definition: MCPServerDefinition
    ) throws -> MCPServerCatalog {
        let checked = try definition.validated()
        return try MCPServerCatalog(
            generation: 0,
            definitions: [checked],
            heads: [
                try MCPServerCatalogHead(
                    serverID: checked.reference.serverID,
                    alias: checked.configuration.serverID.rawValue,
                    currentRevision:
                        checked.reference.serverRevision,
                    disabled: false),
            ],
            tombstones: [],
            importMarkers: [])
    }

    public func definition(
        for reference: MCPServerReference
    ) -> MCPServerDefinition? {
        definitions.first { $0.reference == reference }
    }

    public func head(for serverID: MCPServerID) -> MCPServerCatalogHead? {
        heads.first { $0.serverID == serverID }
    }

    public func head(alias: String) -> MCPServerCatalogHead? {
        heads.first { $0.alias == alias }
    }

    public func isTombstoned(_ reference: MCPServerReference) -> Bool {
        tombstones.contains { $0.reference == reference }
    }

    /// Resolves only a currently enabled, non-tombstoned revision. Historical
    /// lookup uses `definition(for:)` instead.
    public func definitionForNewConnection(
        serverID: MCPServerID
    ) throws -> MCPServerDefinition {
        guard let head = head(for: serverID),
              !head.disabled,
              let revision = head.currentRevision else {
            throw MCPServerCatalogError.serverDisabled
        }
        let reference = MCPServerReference(
            serverID: serverID,
            serverRevision: revision)
        guard !isTombstoned(reference),
              let definition = definition(for: reference),
              definition.configuration.enabled else {
            throw MCPServerCatalogError.revisionTombstoned
        }
        return definition
    }

    public func validated() throws -> MCPServerCatalog {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MCPServerCatalogError.unsupportedSchemaVersion
        }
        guard MCPConfigurationValidation.isSHA256(contentDigest) else {
            throw MCPServerCatalogError.catalogCorrupted
        }
        let validatedDefinitions = try definitions.map { try $0.validated() }
        guard Set(validatedDefinitions.map {
                  Self.referenceKey($0.reference)
              }).count
                == validatedDefinitions.count,
              Set(heads.map(\.serverID)).count == heads.count,
              Set(heads.map(\.alias)).count == heads.count,
              Set(tombstones.map { Self.referenceKey($0.reference) }).count
                == tombstones.count else {
            throw MCPServerCatalogError.catalogCorrupted
        }
        let definitionKeys = Set(validatedDefinitions.map {
            Self.referenceKey($0.reference)
        })
        for head in heads {
            try MCPConfigurationValidation.validateIdentifier(head.alias, field: "alias")
            if let revision = head.currentRevision {
                let key = Self.referenceKey(MCPServerReference(
                    serverID: head.serverID,
                    serverRevision: revision))
                guard definitionKeys.contains(key) else {
                    throw MCPServerCatalogError.catalogCorrupted
                }
            }
        }
        guard tombstones.allSatisfy({
            definitionKeys.contains(Self.referenceKey($0.reference))
        }) else {
            throw MCPServerCatalogError.catalogCorrupted
        }
        let rebuilt = try MCPServerCatalog(
            generation: generation,
            definitions: validatedDefinitions,
            heads: heads,
            tombstones: tombstones,
            importMarkers: importMarkers)
        guard rebuilt == self else {
            throw MCPServerCatalogError.catalogCorrupted
        }
        return rebuilt
    }

    static func referenceKey(_ reference: MCPServerReference) -> String {
        "\(reference.serverID.rawValue)\u{1f}\(reference.serverRevision.rawValue)"
    }

    static func definitionOrder(
        _ lhs: MCPServerDefinition,
        _ rhs: MCPServerDefinition
    ) -> Bool {
        if lhs.reference.serverID != rhs.reference.serverID {
            return lhs.reference.serverID.rawValue < rhs.reference.serverID.rawValue
        }
        return lhs.revisionOrdinal < rhs.revisionOrdinal
    }
}

/// Exact zero-reference observation supplied by the session/runtime reference
/// index. Catalog generation binding prevents an unrelated mutation from using
/// stale proof.
public struct MCPZeroReferenceProof: Codable, Equatable, Hashable, Sendable {
    public let reference: MCPServerReference
    public let catalogGeneration: UInt64
    public let durableReferenceCount: Int
    public let liveReferenceCount: Int
    public let observedAt: Date

    public init(
        reference: MCPServerReference,
        catalogGeneration: UInt64,
        durableReferenceCount: Int,
        liveReferenceCount: Int,
        observedAt: Date = Date()
    ) throws {
        guard durableReferenceCount >= 0, liveReferenceCount >= 0 else {
            throw MCPServerCatalogError.invalidReferenceProof
        }
        self.reference = reference
        self.catalogGeneration = catalogGeneration
        self.durableReferenceCount = durableReferenceCount
        self.liveReferenceCount = liveReferenceCount
        self.observedAt = observedAt
    }

    public var provesZeroReferences: Bool {
        durableReferenceCount == 0 && liveReferenceCount == 0
    }
}

public enum MCPServerCatalogError: Error, LocalizedError, Equatable, Sendable {
    case catalogIO
    case commitUncertain
    case catalogTooLarge
    case catalogCorrupted
    case unsupportedSchemaVersion
    case compareAndSwapConflict(expected: UInt64, actual: UInt64)
    case testRequired
    case invalidTestResult
    case aliasConflict
    case serverIDConflict
    case revisionNotFound
    case revisionTombstoned
    case serverDisabled
    case invalidImportMarker
    case invalidReferenceProof
    case revisionStillReferenced
    case purgeRequiresTombstone
    case generationOverflow
    case preparedPlanMismatch
    case invalidTestAuthorization
    case launchArtifactPrecommitVerifierRequired

    public var errorDescription: String? {
        switch self {
        case .catalogIO:
            return "The MCP catalog could not be read or written safely."
        case .commitUncertain:
            return "The MCP catalog may have committed, but durability could not be verified."
        case .catalogTooLarge:
            return "The MCP catalog exceeds its bounded size."
        case .catalogCorrupted:
            return "The MCP catalog is corrupted or failed integrity validation."
        case .unsupportedSchemaVersion:
            return "The MCP catalog schema is newer than this client."
        case .compareAndSwapConflict:
            return "The MCP catalog changed concurrently."
        case .testRequired:
            return "The exact MCP configuration must pass Test before saving."
        case .invalidTestResult:
            return "The MCP Test result is invalid."
        case .aliasConflict:
            return "The MCP server alias already belongs to another server."
        case .serverIDConflict:
            return "The MCP server identity conflicts with the catalog."
        case .revisionNotFound:
            return "The MCP server revision does not exist."
        case .revisionTombstoned:
            return "The MCP server revision is tombstoned."
        case .serverDisabled:
            return "The MCP server is disabled."
        case .invalidImportMarker:
            return "The MCP import marker is invalid."
        case .invalidReferenceProof:
            return "The MCP zero-reference proof is invalid or stale."
        case .revisionStillReferenced:
            return "The MCP server revision still has durable or live references."
        case .purgeRequiresTombstone:
            return "Only a tombstoned MCP server revision can be purged."
        case .generationOverflow:
            return "The MCP catalog generation cannot advance safely."
        case .preparedPlanMismatch:
            return "The prepared MCP definition does not match the exact catalog snapshot."
        case .invalidTestAuthorization:
            return "The MCP configuration Test authorization is invalid."
        case .launchArtifactPrecommitVerifierRequired:
            return "The host must verify the tested MCP launch artifact before saving a stdio definition."
        }
    }
}
