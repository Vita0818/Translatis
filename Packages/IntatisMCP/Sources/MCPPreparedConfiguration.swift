import Foundation
import IntatisProtocol

/// Exact identity of one complete global MCP catalog publication.
///
/// A generation alone is not sufficient because a corrupted or incorrectly
/// replaced file could otherwise present different bytes under the same
/// generation. Every plan, factory, and save therefore carries both values.
public struct MCPCatalogPublicationIdentity:
    Codable, Equatable, Hashable, Sendable
{
    public let generation: UInt64
    public let catalogFingerprint: String

    public init(
        generation: UInt64,
        catalogFingerprint: String
    ) throws {
        guard MCPConfigurationValidation.isSHA256(
            catalogFingerprint)
        else {
            throw MCPServerCatalogError.catalogCorrupted
        }
        self.generation = generation
        self.catalogFingerprint = catalogFingerprint
    }

    public init(catalog: MCPServerCatalog) {
        generation = catalog.generation
        catalogFingerprint = catalog.contentDigest
    }
}

/// Secret-free, one-use preparation challenge. It binds the UI/CLI draft,
/// predicted immutable revision, catalog snapshot, and isolated Test
/// challenge without retaining credentials.
public struct MCPPreparedConfigurationChallenge:
    Codable, Equatable, Hashable, Sendable
{
    public let challengeID: String
    public let preparationFingerprint: String
    public let configurationFingerprint: String
    public let plannedReference: MCPServerReference
    public let catalogPublication: MCPCatalogPublicationIdentity

    init(
        challengeID: String,
        preparationFingerprint: String,
        configurationFingerprint: String,
        plannedReference: MCPServerReference,
        catalogPublication: MCPCatalogPublicationIdentity
    ) {
        self.challengeID = challengeID
        self.preparationFingerprint = preparationFingerprint
        self.configurationFingerprint = configurationFingerprint
        self.plannedReference = plannedReference
        self.catalogPublication = catalogPublication
    }
}

/// A complete Test-before-Save plan made from exactly one catalog snapshot.
///
/// `definition` is the immutable definition that Save must publish. For an
/// unchanged, non-tombstoned configuration this may intentionally reuse an
/// existing revision; otherwise its ordinal is exactly maxOrdinal + 1 from
/// `catalogPublication`.
public struct MCPPreparedServerConfiguration:
    Equatable, Hashable, Sendable
{
    public let alias: String
    public let definition: MCPServerDefinition
    public let catalogPublication: MCPCatalogPublicationIdentity
    public let staging: MCPConfigurationStaging
    public let challenge: MCPPreparedConfigurationChallenge
    public let testOperationID: MCPControlOperationID

    public var expectedServerReference: MCPServerReference {
        definition.reference
    }

    public var preparationFingerprint: String {
        challenge.preparationFingerprint
    }

    public static func plan(
        alias: String,
        staging: MCPConfigurationStaging,
        catalog: MCPServerCatalog,
        operationID: MCPControlOperationID = .new()
    ) throws -> MCPPreparedServerConfiguration {
        let catalog = try catalog.validated()
        try MCPConfigurationValidation.validateIdentifier(
            alias,
            field: "alias")
        let configuration =
            try staging.configuration.validatedCanonical()

        if let aliasOwner = catalog.head(alias: alias),
           aliasOwner.serverID != configuration.serverID {
            throw MCPServerCatalogError.aliasConflict
        }
        if let serverHead = catalog.head(
            for: configuration.serverID),
           serverHead.alias != alias {
            throw MCPServerCatalogError.serverIDConflict
        }

        let reusable = catalog.definitions.first {
            $0.reference.serverID == configuration.serverID
                && $0.definitionFingerprint
                    == configuration.canonicalFingerprint
                && !catalog.isTombstoned($0.reference)
        }
        let definition: MCPServerDefinition
        if let reusable {
            definition = reusable
        } else {
            let maximumOrdinal = catalog.definitions
                .filter {
                    $0.reference.serverID
                        == configuration.serverID
                }
                .map(\.revisionOrdinal)
                .max() ?? 0
            guard maximumOrdinal < UInt64.max else {
                throw MCPServerCatalogError.generationOverflow
            }
            definition = MCPServerDefinition(
                configuration: configuration,
                revisionOrdinal: maximumOrdinal + 1)
        }

        let publication =
            MCPCatalogPublicationIdentity(catalog: catalog)
        let fingerprint = MCPConfigurationCanonical.sha256(
            Data([
                "mcp-prepared-configuration-v1",
                alias,
                String(publication.generation),
                publication.catalogFingerprint,
                definition.reference.serverID.rawValue,
                definition.reference.serverRevision.rawValue,
                String(definition.revisionOrdinal),
                definition.definitionFingerprint,
                staging.challenge.challengeID,
                staging.challenge.configurationFingerprint,
                staging.challenge.transportFingerprint,
                operationID.rawValue,
            ].joined(separator: "\u{1f}").utf8))
        let challenge = MCPPreparedConfigurationChallenge(
            challengeID: staging.challenge.challengeID,
            preparationFingerprint: fingerprint,
            configurationFingerprint:
                configuration.canonicalFingerprint,
            plannedReference: definition.reference,
            catalogPublication: publication)
        return MCPPreparedServerConfiguration(
            alias: alias,
            definition: definition,
            catalogPublication: publication,
            staging: staging,
            challenge: challenge,
            testOperationID: operationID)
    }

    public static func planBatch(
        _ drafts: [(alias: String, staging: MCPConfigurationStaging)],
        catalog: MCPServerCatalog
    ) throws -> [MCPPreparedServerConfiguration] {
        guard !drafts.isEmpty, drafts.count <= 10_000 else {
            throw MCPServerCatalogError.catalogTooLarge
        }
        let aliases = drafts.map(\.alias)
        let serverIDs = drafts.map {
            $0.staging.configuration.serverID
        }
        guard Set(aliases).count == aliases.count,
              Set(serverIDs).count == serverIDs.count
        else {
            throw MCPServerCatalogError.aliasConflict
        }
        // Every prediction is deliberately derived from the same snapshot.
        return try drafts.map {
            try plan(
                alias: $0.alias,
                staging: $0.staging,
                catalog: catalog)
        }
    }

    func validatePlan(against catalog: MCPServerCatalog) throws {
        guard catalogPublication
                == MCPCatalogPublicationIdentity(catalog: catalog)
        else {
            throw MCPServerCatalogError.compareAndSwapConflict(
                expected: catalogPublication.generation,
                actual: catalog.generation)
        }
        let rebuilt = try Self.plan(
            alias: alias,
            staging: staging,
            catalog: catalog,
            operationID: testOperationID)
        guard rebuilt == self else {
            throw MCPServerCatalogError.preparedPlanMismatch
        }
    }
}

/// Successful Test proof for one exact preparation. A plain configuration
/// proof cannot be upgraded to this value without the complete prepared plan.
public struct MCPPreparedConfigurationTestProof:
    Equatable, Hashable, Sendable
{
    public let preparedChallenge:
        MCPPreparedConfigurationChallenge
    public let configurationProof:
        MCPConfigurationTestProof

    init(
        preparedChallenge: MCPPreparedConfigurationChallenge,
        configurationProof: MCPConfigurationTestProof
    ) {
        self.preparedChallenge = preparedChallenge
        self.configurationProof = configurationProof
    }
}

public extension MCPPreparedServerConfiguration {
    func accept(
        _ result: MCPConfigurationTestResult,
        proofLifetime: TimeInterval =
            MCPConfigurationStaging.defaultProofLifetime
    ) throws -> MCPPreparedConfigurationTestProof {
        let proof = try staging.accept(
            result,
            proofLifetime: proofLifetime)
        return MCPPreparedConfigurationTestProof(
            preparedChallenge: challenge,
            configurationProof: proof)
    }

    func validate(
        proof: MCPPreparedConfigurationTestProof,
        at now: Date
    ) throws {
        guard proof.preparedChallenge == challenge else {
            throw MCPServerCatalogError.testRequired
        }
        try staging.validate(
            proof: proof.configurationProof,
            at: now)
    }
}

/// Explicit caller assertion used by global Test. It is not a consent and does
/// not survive the prepared challenge.
public struct MCPConfigurationTestAuthorization:
    Equatable, Hashable, Sendable
{
    public let directUserAction: Bool
    public let callerFingerprint: String

    public init(
        directUserAction: Bool,
        callerFingerprint: String
    ) throws {
        guard MCPConfigurationValidation.isSHA256(
            callerFingerprint)
        else {
            throw MCPServerCatalogError.invalidTestAuthorization
        }
        self.directUserAction = directUserAction
        self.callerFingerprint = callerFingerprint
    }
}

public struct MCPPreparedConfigurationTestRequest:
    Equatable, Sendable
{
    public let prepared: MCPPreparedServerConfiguration
    public let authorization: MCPConfigurationTestAuthorization

    public init(
        prepared: MCPPreparedServerConfiguration,
        authorization: MCPConfigurationTestAuthorization
    ) {
        self.prepared = prepared
        self.authorization = authorization
    }
}

public enum MCPConfigurationTestGateDecision:
    Equatable, Sendable
{
    case allow
    case deny(String)
}

public protocol MCPConfigurationTestHardGate: Sendable {
    func evaluate(
        _ request: MCPPreparedConfigurationTestRequest
    ) async -> MCPConfigurationTestGateDecision
}

/// Host-neutral deterministic gate that runs after durable registration and
/// before the Test executor can reach credentials, a process, or a socket.
public struct MCPDeterministicConfigurationTestHardGate:
    MCPConfigurationTestHardGate, Sendable
{
    public let hostProfile: MCPProductHostProfile

    public init(hostProfile: MCPProductHostProfile) {
        self.hostProfile = hostProfile
    }

    public func evaluate(
        _ request: MCPPreparedConfigurationTestRequest
    ) async -> MCPConfigurationTestGateDecision {
        guard request.authorization.directUserAction else {
            return .deny("direct_user_action_required")
        }
        guard hostProfile.permits(
            request.prepared.definition.configuration
                .transport.kind)
        else {
            return .deny("transport_not_permitted")
        }
        guard request.prepared.challenge
                .configurationFingerprint
                == request.prepared.definition
                    .definitionFingerprint
        else {
            return .deny("prepared_identity_mismatch")
        }
        return .allow
    }
}
