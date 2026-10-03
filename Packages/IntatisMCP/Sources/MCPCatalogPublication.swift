import Foundation
import IntatisCore
import IntatisProtocol

public enum MCPCatalogPublicationError:
    Error, Equatable, LocalizedError, Sendable
{
    case stalePublication(
        expected: MCPCatalogPublicationIdentity,
        actual: MCPCatalogPublicationIdentity
    )
    case generationRegressed(expectedAtLeast: UInt64, actual: UInt64)
    case conflictingGeneration(UInt64)
    case registrationMissing(SessionID)

    public var errorDescription: String? {
        switch self {
        case .stalePublication:
            return "The MCP invocation plan and connection factory belong to different catalog publications."
        case .generationRegressed:
            return "The observed MCP catalog generation regressed."
        case .conflictingGeneration:
            return "Different MCP catalog bytes were observed under the same generation."
        case .registrationMissing:
            return "The MCP session runtime is not registered for catalog publication."
        }
    }
}

public struct MCPPublishedConnectionFactory: Sendable {
    public let catalog: MCPServerCatalog
    public let publication:
        MCPCatalogPublicationIdentity
    public let factory:
        any MCPConnectionClientFactory

    public init(
        catalog: MCPServerCatalog,
        factory: any MCPConnectionClientFactory
    ) {
        self.catalog = catalog
        publication = MCPCatalogPublicationIdentity(
            catalog: catalog)
        self.factory = factory
    }
}

public typealias MCPProductionFactoryBuilder =
    @Sendable (MCPServerCatalog) throws
        -> any MCPConnectionClientFactory

/// One session's atomic catalog/factory publication.
///
/// A publication is constructed in full before the single actor assignment.
/// Callers retain the returned value, so a later publication cannot swap the
/// factory or catalog underneath an in-flight invocation.
public actor MCPProductionCatalogPublication {
    private let buildFactory:
        MCPProductionFactoryBuilder
    private var current:
        MCPPublishedConnectionFactory

    public init(
        initialCatalog: MCPServerCatalog,
        buildFactory:
            @escaping MCPProductionFactoryBuilder
    ) throws {
        let checked = try initialCatalog.validated()
        self.buildFactory = buildFactory
        current = MCPPublishedConnectionFactory(
            catalog: checked,
            factory: try buildFactory(checked))
    }

    public func snapshot(
        expected:
            MCPCatalogPublicationIdentity? = nil
    ) throws -> MCPPublishedConnectionFactory {
        if let expected,
           expected != current.publication {
            throw MCPCatalogPublicationError
                .stalePublication(
                    expected: expected,
                    actual: current.publication)
        }
        return current
    }

    @discardableResult
    public func publish(
        _ catalog: MCPServerCatalog
    ) throws -> MCPPublishedConnectionFactory {
        let checked = try catalog.validated()
        let identity =
            MCPCatalogPublicationIdentity(catalog: checked)
        if identity == current.publication {
            return current
        }
        guard identity.generation
                >= current.publication.generation
        else {
            throw MCPCatalogPublicationError
                .generationRegressed(
                    expectedAtLeast:
                        current.publication.generation,
                    actual: identity.generation)
        }
        guard identity.generation
                != current.publication.generation
        else {
            throw MCPCatalogPublicationError
                .conflictingGeneration(identity.generation)
        }
        let replacement = MCPPublishedConnectionFactory(
            catalog: checked,
            factory: try buildFactory(checked))
        current = replacement
        return replacement
    }
}

public struct MCPCatalogReferenceRevocation:
    Equatable, Hashable, Sendable
{
    public let reference: MCPServerReference
    public let reason: MCPPolicyChangeReason
    public let replacementGeneration:
        MCPRevocationGeneration

    public init(
        reference: MCPServerReference,
        reason: MCPPolicyChangeReason,
        replacementGeneration:
            MCPRevocationGeneration
    ) {
        self.reference = reference
        self.reason = reason
        self.replacementGeneration =
            replacementGeneration
    }
}

public struct MCPCatalogPublicationDiff:
    Equatable, Sendable
{
    public let previous:
        MCPCatalogPublicationIdentity
    public let current:
        MCPCatalogPublicationIdentity
    public let addedReferences:
        [MCPServerReference]
    public let revocations:
        [MCPCatalogReferenceRevocation]

    public init(
        previous: MCPServerCatalog,
        current: MCPServerCatalog
    ) {
        self.previous =
            MCPCatalogPublicationIdentity(catalog: previous)
        self.current =
            MCPCatalogPublicationIdentity(catalog: current)
        let oldReferences = Set(
            previous.definitions.map(\.reference))
        let newReferences = Set(
            current.definitions.map(\.reference))
        addedReferences = newReferences
            .subtracting(oldReferences)
            .sorted(by: Self.referenceOrder)

        var reasons:
            [MCPServerReference: MCPPolicyChangeReason] =
                [:]
        for tombstone in current.tombstones
            where !previous.isTombstoned(
                tombstone.reference)
        {
            reasons[tombstone.reference] =
                .serverTombstoned
        }
        for oldHead in previous.heads {
            guard let oldRevision =
                    oldHead.currentRevision
            else { continue }
            let oldReference = MCPServerReference(
                serverID: oldHead.serverID,
                serverRevision: oldRevision)
            guard let newHead = current.head(
                for: oldHead.serverID)
            else {
                reasons[oldReference] =
                    .catalogStale
                continue
            }
            if newHead.disabled {
                reasons[oldReference] =
                    current.isTombstoned(oldReference)
                        ? .serverTombstoned
                        : .serverDisabled
            } else if newHead.currentRevision
                        != oldRevision {
                reasons[oldReference] =
                    .catalogStale
            }
        }
        for removed in oldReferences
            .subtracting(newReferences)
        {
            reasons[removed] = .catalogStale
        }
        revocations = reasons.map {
            reference, reason in
            let digest =
                MCPConfigurationCanonical.sha256(
                    Data([
                        "mcp-catalog-publication-revocation-v1",
                        reference.serverID.rawValue,
                        reference.serverRevision.rawValue,
                        String(current.generation),
                        current.contentDigest,
                        reason.rawValue,
                    ].joined(separator: "\u{1f}").utf8))
            return MCPCatalogReferenceRevocation(
                reference: reference,
                reason: reason,
                replacementGeneration:
                    MCPRevocationGeneration(
                        rawValue:
                            "mcprevocation_"
                                + digest.prefix(32)))
        }.sorted {
            Self.referenceOrder(
                $0.reference,
                $1.reference)
        }
    }

    private static func referenceOrder(
        _ lhs: MCPServerReference,
        _ rhs: MCPServerReference
    ) -> Bool {
        if lhs.serverID != rhs.serverID {
            return lhs.serverID.rawValue
                < rhs.serverID.rawValue
        }
        return lhs.serverRevision.rawValue
            < rhs.serverRevision.rawValue
    }
}

/// EventLog-backed hosts implement this seam with one atomic append of every
/// still-live matching consent revocation.
public protocol MCPCatalogConsentRevoker: Sendable {
    func revokeConsents(
        _ revocations:
            [MCPCatalogReferenceRevocation]
    ) async throws
}

public protocol MCPServerReferenceDurableUsageSource:
    Sendable
{
    func durableSessionIDs(
        referencing reference: MCPServerReference
    ) async throws -> [SessionID]
}

public struct MCPServerReferenceUsage:
    Equatable, Sendable
{
    public let reference: MCPServerReference
    public let durableSessionIDs: [SessionID]
    public let liveAuthorityCount: Int

    public init(
        reference: MCPServerReference,
        durableSessionIDs: [SessionID],
        liveAuthorityCount: Int
    ) {
        self.reference = reference
        self.durableSessionIDs =
            Array(Set(durableSessionIDs)).sorted {
                $0.rawValue < $1.rawValue
            }
        self.liveAuthorityCount =
            max(0, liveAuthorityCount)
    }
}

public struct MCPProcessCatalogPublicationReport:
    Equatable, Sendable
{
    public let publication:
        MCPCatalogPublicationIdentity
    public let sessionDiffs:
        [SessionID: MCPCatalogPublicationDiff]

    public init(
        publication: MCPCatalogPublicationIdentity,
        sessionDiffs:
            [SessionID: MCPCatalogPublicationDiff]
    ) {
        self.publication = publication
        self.sessionDiffs = sessionDiffs
    }
}

/// Process-wide exact broadcast registry. It is also the bounded
/// cross-process observation seam: each registered session polls the durable
/// owner-only catalog at a fixed interval and republishes a newer complete
/// generation through this actor.
public actor MCPProcessCatalogRuntimeRegistry {
    public static let shared =
        MCPProcessCatalogRuntimeRegistry()

    private struct Entry: Sendable {
        let owner: MCPSessionRuntimeOwner
        let publication:
            MCPProductionCatalogPublication
        let consentRevoker:
            (any MCPCatalogConsentRevoker)?
        let catalogStore:
            MCPServerCatalogStore?
    }

    private var entries: [SessionID: Entry] = [:]
    private var observationTasks:
        [SessionID: Task<Void, Never>] = [:]
    // Actor isolation alone is not sufficient here because `publish` awaits
    // each session publication and owner drain, and actor methods are
    // reentrant across those suspension points. This turnstile preserves one
    // total generation order for process-wide publication.
    private var publicationTurnOccupied = false
    private var publicationTurnWaiters:
        [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func register(
        sessionID: SessionID,
        owner: MCPSessionRuntimeOwner,
        publication:
            MCPProductionCatalogPublication,
        consentRevoker:
            (any MCPCatalogConsentRevoker)? = nil,
        catalogStore:
            MCPServerCatalogStore? = nil,
        observationIntervalMilliseconds: Int = 1_000
    ) {
        observationTasks.removeValue(
            forKey: sessionID)?.cancel()
        entries[sessionID] = Entry(
            owner: owner,
            publication: publication,
            consentRevoker: consentRevoker,
            catalogStore: catalogStore)
        guard let catalogStore else { return }
        let interval = min(
            60_000,
            max(100, observationIntervalMilliseconds))
        observationTasks[sessionID] = Task {
            [weak self, weak owner] in
            while !Task.isCancelled {
                guard let self, let owner else { return }
                if await owner.lifecycleState() == .stopped {
                    await self.unregister(
                        sessionID: sessionID)
                    return
                }
                do {
                    let catalog =
                        try await catalogStore.load()
                    _ = try await self.publish(catalog)
                } catch {
                    // A failed observation never installs partial bytes.
                    // The next bounded tick retries the durable snapshot.
                }
                do {
                    try await Task.sleep(
                        for: .milliseconds(interval))
                } catch {
                    return
                }
            }
        }
    }

    public func unregister(sessionID: SessionID) {
        entries.removeValue(forKey: sessionID)
        observationTasks.removeValue(
            forKey: sessionID)?.cancel()
    }

    @discardableResult
    public func publish(
        _ catalog: MCPServerCatalog
    ) async throws
        -> MCPProcessCatalogPublicationReport
    {
        await acquirePublicationTurn()
        defer { releasePublicationTurn() }

        let checked = try catalog.validated()
        // Freeze registry membership for this publication. `register` and
        // `unregister` may run while this method awaits another actor; using
        // the captured entries keeps publication, route retirement, and
        // consent revocation targeted at the same session owners.
        let publicationEntries = entries
        var diffs:
            [SessionID: MCPCatalogPublicationDiff] = [:]

        // Each session constructs and atomically commits a whole
        // catalog/factory pair before any new dispatch can select it.
        for (sessionID, entry) in publicationEntries {
            let previous =
                try await entry.publication.snapshot()
            let published =
                try await entry.publication.publish(checked)
            let diff = MCPCatalogPublicationDiff(
                previous: previous.catalog,
                current: published.catalog)
            diffs[sessionID] = diff
        }

        // Route fences are applied before durable consent revocation errors
        // are surfaced, so a persistence fault still fails closed in memory.
        await withTaskGroup(of: Void.self) { group in
            for (sessionID, diff) in diffs
                where !diff.revocations.isEmpty
            {
                guard let entry =
                        publicationEntries[sessionID]
                else { continue }
                group.addTask {
                    await entry.owner.revokeServerReferences(
                        diff.revocations)
                }
            }
        }
        var firstConsentRevocationError: Error?
        for sessionID in diffs.keys.sorted(by: {
            $0.rawValue < $1.rawValue
        }) {
            guard let diff = diffs[sessionID],
                  !diff.revocations.isEmpty
            else { continue }
            do {
                try await publicationEntries[sessionID]?
                    .consentRevoker?
                    .revokeConsents(diff.revocations)
            } catch {
                // One session's persistence failure cannot prevent attempts
                // to revoke every other session's durable consent.
                if firstConsentRevocationError == nil {
                    firstConsentRevocationError = error
                }
            }
        }
        if let firstConsentRevocationError {
            throw firstConsentRevocationError
        }
        return MCPProcessCatalogPublicationReport(
            publication:
                MCPCatalogPublicationIdentity(
                    catalog: checked),
            sessionDiffs: diffs)
    }

    private func acquirePublicationTurn() async {
        guard publicationTurnOccupied else {
            publicationTurnOccupied = true
            return
        }
        await withCheckedContinuation {
            continuation in
            publicationTurnWaiters.append(
                continuation)
        }
    }

    private func releasePublicationTurn() {
        guard !publicationTurnWaiters.isEmpty else {
            publicationTurnOccupied = false
            return
        }
        publicationTurnWaiters
            .removeFirst()
            .resume()
    }

    public func reloadCatalog(
        from store: MCPServerCatalogStore
    ) async throws
        -> MCPProcessCatalogPublicationReport
    {
        try await publish(await store.load())
    }

    /// Credential logout/account replacement is an authority change even when
    /// the secret-free catalog bytes do not change. Drain every exact live
    /// route and revoke its durable connection consent before a later login
    /// can reuse the same account reference.
    public func revokeCredentialAuthority(
        _ reference: MCPServerReference
    ) async throws {
        let generation =
            MCPRevocationGeneration(
                rawValue:
                    IDGen.random(
                        prefix:
                            "mcprevocation_credential"))
        let revocation =
            MCPCatalogReferenceRevocation(
                reference: reference,
                reason: .credentialChanged,
                replacementGeneration:
                    generation)
        let revocations = [revocation]
        let affectedEntries = entries

        await withTaskGroup(of: Void.self) { group in
            for entry in affectedEntries.values {
                group.addTask {
                    await entry.owner
                        .revokeServerReferences(
                            revocations)
                }
            }
        }
        var firstConsentRevocationError: Error?
        for sessionID in affectedEntries.keys.sorted(by: {
            $0.rawValue < $1.rawValue
        }) {
            do {
                try await affectedEntries[sessionID]?
                    .consentRevoker?
                    .revokeConsents(revocations)
            } catch {
                if firstConsentRevocationError == nil {
                    firstConsentRevocationError = error
                }
            }
        }
        if let firstConsentRevocationError {
            throw firstConsentRevocationError
        }
    }

    public func referenceUsage(
        _ reference: MCPServerReference,
        durableSource:
            (any MCPServerReferenceDurableUsageSource)? = nil
    ) async throws -> MCPServerReferenceUsage {
        let durable = try await durableSource?
            .durableSessionIDs(
                referencing: reference) ?? []
        var liveCount = 0
        for entry in entries.values {
            liveCount += await entry.owner
                .liveConnectionSnapshots()
                .filter {
                    $0.reuseIdentity.server
                        == reference
                }.count
        }
        return MCPServerReferenceUsage(
            reference: reference,
            durableSessionIDs: durable,
            liveAuthorityCount: liveCount)
    }
}
