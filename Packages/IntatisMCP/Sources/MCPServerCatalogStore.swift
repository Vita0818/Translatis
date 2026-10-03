import Foundation
import IntatisCore
import IntatisProtocol

public struct MCPCatalogSaveItem: Sendable {
    public let alias: String
    public let staging: MCPConfigurationStaging
    public let proof: MCPConfigurationTestProof

    public init(
        alias: String,
        staging: MCPConfigurationStaging,
        proof: MCPConfigurationTestProof
    ) {
        self.alias = alias
        self.staging = staging
        self.proof = proof
    }
}

public struct MCPCatalogSaveResult: Equatable, Sendable {
    public let catalog: MCPServerCatalog
    public let definitions: [MCPServerDefinition]

    public init(
        catalog: MCPServerCatalog,
        definitions: [MCPServerDefinition]
    ) {
        self.catalog = catalog
        self.definitions = definitions
    }
}

public struct MCPPreparedCatalogSaveItem: Sendable {
    public let prepared: MCPPreparedServerConfiguration
    public let proof: MCPPreparedConfigurationTestProof

    public init(
        prepared: MCPPreparedServerConfiguration,
        proof: MCPPreparedConfigurationTestProof
    ) {
        self.prepared = prepared
        self.proof = proof
    }
}

/// Owner of the global, secret-free MCP catalog.
///
/// Every mutation is a read/validate/CAS/write transaction under a stable
/// owner-only cross-process flock sidecar. `DurableOwnerOnlyFile` additionally
/// enforces no-follow, regular-file, current-UID, mode 0600, single-link,
/// same-directory atomic replace, fsync, and byte-for-byte readback.
public actor MCPServerCatalogStore {
    public static let fileName = "mcp-catalog-v1.json"
    public static let maximumEncodedBytes = 16 * 1024 * 1024

    public let fileURL: URL
    public let lockURL: URL
    private let fileManager: FileManager
    private let precommitVerifier:
        any MCPPreparedDefinitionPrecommitVerifier

    public init(
        fileURL: URL,
        fileManager: FileManager = .default,
        precommitVerifier:
            any MCPPreparedDefinitionPrecommitVerifier =
                MCPHTTPOnlyPreparedDefinitionPrecommitVerifier()
    ) {
        self.fileURL = fileURL.standardizedFileURL
        lockURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).lock")
            .standardizedFileURL
        self.fileManager = fileManager
        self.precommitVerifier = precommitVerifier
    }

    public func load() throws -> MCPServerCatalog {
        try prepareDirectory()
        return try readCatalog()
    }

    /// Publishes the one immutable definition predicted by `prepare`.
    ///
    /// There is deliberately no retry or re-planning path. A generation or
    /// digest conflict invalidates the preparation and its Test proof.
    @discardableResult
    public func savePrepared(
        _ prepared: MCPPreparedServerConfiguration,
        proof: MCPPreparedConfigurationTestProof,
        now: Date = Date()
    ) throws -> MCPCatalogSaveResult {
        try savePreparedBatch(
            [MCPPreparedCatalogSaveItem(
                prepared: prepared,
                proof: proof)],
            importMarker: nil,
            now: now)
    }

    /// One exact-generation transaction for a complete prepared import batch.
    /// Every predicted revision came from the same catalog snapshot; either
    /// all planned definitions and the marker publish, or none do.
    @discardableResult
    public func savePreparedBatch(
        _ items: [MCPPreparedCatalogSaveItem],
        importMarker: MCPImportMarker?,
        now: Date = Date()
    ) throws -> MCPCatalogSaveResult {
        guard !items.isEmpty, items.count <= 10_000 else {
            throw MCPServerCatalogError.catalogTooLarge
        }
        guard let expectedPublication =
                items.first?.prepared.catalogPublication,
              items.allSatisfy({
                  $0.prepared.catalogPublication
                      == expectedPublication
              })
        else {
            throw MCPServerCatalogError.preparedPlanMismatch
        }
        let aliases = items.map { $0.prepared.alias }
        let serverIDs = items.map {
            $0.prepared.definition.reference.serverID
        }
        guard Set(aliases).count == aliases.count,
              Set(serverIDs).count == serverIDs.count
        else {
            throw MCPServerCatalogError.aliasConflict
        }
        for item in items {
            try item.prepared.validate(
                proof: item.proof,
                at: now)
        }

        return try withMutationLock {
            let existing = try readCatalog()
            try checkCAS(
                expectedPublication.generation,
                actual: existing.generation)
            guard existing.contentDigest
                    == expectedPublication.catalogFingerprint
            else {
                throw MCPServerCatalogError.preparedPlanMismatch
            }
            for item in items {
                try item.prepared.validatePlan(
                    against: existing)
            }
            // This must remain inside the cross-process catalog lock and after
            // exact-generation CAS. A successful isolated Test does not grant
            // permission to publish a launch closure that changed afterward.
            for item in items {
                try precommitVerifier
                    .verifyBeforeCatalogCommit(
                        item.prepared.definition)
            }

            var definitions = existing.definitions
            var heads = existing.heads
            var markers = existing.importMarkers
            var saved: [MCPServerDefinition] = []

            for item in items {
                let prepared = item.prepared
                let definition = prepared.definition
                if let existingDefinition =
                        existing.definition(
                            for: definition.reference) {
                    guard existingDefinition == definition,
                          !existing.isTombstoned(
                              definition.reference)
                    else {
                        throw MCPServerCatalogError
                            .preparedPlanMismatch
                    }
                } else {
                    definitions.append(definition)
                }
                saved.append(definition)

                let replacement = try MCPServerCatalogHead(
                    serverID: definition.reference.serverID,
                    alias: prepared.alias,
                    currentRevision:
                        definition.reference.serverRevision,
                    disabled: false)
                if let index = heads.firstIndex(where: {
                    $0.serverID
                        == definition.reference.serverID
                }) {
                    heads[index] = replacement
                } else {
                    heads.append(replacement)
                }
            }

            if let importMarker {
                if let existingMarker = markers.first(where: {
                    $0.sourceKind == importMarker.sourceKind
                        && $0.sourceFingerprint
                            == importMarker.sourceFingerprint
                }) {
                    guard existingMarker == importMarker else {
                        throw MCPServerCatalogError
                            .invalidImportMarker
                    }
                } else {
                    markers.append(importMarker)
                }
            }

            let updated = try advancedCatalog(
                from: existing,
                definitions: definitions,
                heads: heads,
                tombstones: existing.tombstones,
                importMarkers: markers)
            try writeCatalog(updated)
            return MCPCatalogSaveResult(
                catalog: updated,
                definitions: saved)
        }
    }

    /// Saves one exact staged definition. Old definitions remain immutable.
    @discardableResult
    public func save(
        alias: String,
        staging: MCPConfigurationStaging,
        proof: MCPConfigurationTestProof,
        expectedGeneration: UInt64,
        now: Date = Date()
    ) throws -> MCPCatalogSaveResult {
        try saveBatch(
            [MCPCatalogSaveItem(alias: alias, staging: staging, proof: proof)],
            importMarker: nil,
            expectedGeneration: expectedGeneration,
            now: now)
    }

    /// Atomically saves every confirmed imported proposal and its marker.
    /// One invalid proof or conflict aborts the complete batch before writing.
    @discardableResult
    public func saveBatch(
        _ items: [MCPCatalogSaveItem],
        importMarker: MCPImportMarker?,
        expectedGeneration: UInt64,
        now: Date = Date()
    ) throws -> MCPCatalogSaveResult {
        guard !items.isEmpty, items.count <= 10_000 else {
            throw MCPServerCatalogError.catalogTooLarge
        }
        let aliases = items.map(\.alias)
        let serverIDs = items.map { $0.staging.configuration.serverID }
        guard Set(aliases).count == aliases.count,
              Set(serverIDs).count == serverIDs.count else {
            throw MCPServerCatalogError.aliasConflict
        }
        for item in items {
            try MCPConfigurationValidation.validateIdentifier(
                item.alias,
                field: "alias")
            try item.staging.validate(proof: item.proof, at: now)
        }

        return try withMutationLock {
            let existing = try readCatalog()
            try checkCAS(expectedGeneration, actual: existing.generation)

            var definitions = existing.definitions
            var heads = existing.heads
            var markers = existing.importMarkers
            var saved: [MCPServerDefinition] = []

            for item in items {
                let configuration = try item.staging.configuration.validatedCanonical()
                if let aliasOwner = heads.first(where: { $0.alias == item.alias }),
                   aliasOwner.serverID != configuration.serverID {
                    throw MCPServerCatalogError.aliasConflict
                }
                if let serverHead = heads.first(where: {
                    $0.serverID == configuration.serverID
                }), serverHead.alias != item.alias {
                    throw MCPServerCatalogError.serverIDConflict
                }

                let reusable = definitions.first {
                    $0.reference.serverID == configuration.serverID
                        && $0.definitionFingerprint == configuration.canonicalFingerprint
                        && !existing.isTombstoned($0.reference)
                }
                let definition: MCPServerDefinition
                if let reusable {
                    definition = reusable
                } else {
                    let maximumOrdinal = definitions
                        .filter { $0.reference.serverID == configuration.serverID }
                        .map(\.revisionOrdinal)
                        .max() ?? 0
                    guard maximumOrdinal < UInt64.max else {
                        throw MCPServerCatalogError.generationOverflow
                    }
                    definition = MCPServerDefinition(
                        configuration: configuration,
                        revisionOrdinal: maximumOrdinal + 1)
                }
                try precommitVerifier
                    .verifyBeforeCatalogCommit(definition)
                if reusable == nil {
                    definitions.append(definition)
                }
                saved.append(definition)

                let replacement = try MCPServerCatalogHead(
                    serverID: configuration.serverID,
                    alias: item.alias,
                    currentRevision: definition.reference.serverRevision,
                    disabled: false)
                if let index = heads.firstIndex(where: {
                    $0.serverID == configuration.serverID
                }) {
                    heads[index] = replacement
                } else {
                    heads.append(replacement)
                }
            }

            if let importMarker {
                if let existingMarker = markers.first(where: {
                    $0.sourceKind == importMarker.sourceKind
                        && $0.sourceFingerprint == importMarker.sourceFingerprint
                }) {
                    guard existingMarker == importMarker else {
                        throw MCPServerCatalogError.invalidImportMarker
                    }
                } else {
                    markers.append(importMarker)
                }
            }

            let updated = try advancedCatalog(
                from: existing,
                definitions: definitions,
                heads: heads,
                tombstones: existing.tombstones,
                importMarkers: markers)
            try writeCatalog(updated)
            return MCPCatalogSaveResult(
                catalog: updated,
                definitions: saved)
        }
    }

    @discardableResult
    public func setDisabled(
        serverID: MCPServerID,
        disabled: Bool,
        expectedGeneration: UInt64
    ) throws -> MCPServerCatalog {
        try withMutationLock {
            let existing = try readCatalog()
            try checkCAS(expectedGeneration, actual: existing.generation)
            guard let index = existing.heads.firstIndex(where: {
                $0.serverID == serverID
            }) else {
                throw MCPServerCatalogError.revisionNotFound
            }
            if existing.heads[index].disabled == disabled {
                return existing
            }
            let head = existing.heads[index]
            if !disabled, let revision = head.currentRevision {
                let reference = MCPServerReference(
                    serverID: serverID,
                    serverRevision: revision)
                guard !existing.isTombstoned(reference) else {
                    throw MCPServerCatalogError.revisionTombstoned
                }
            }
            var heads = existing.heads
            heads[index] = try MCPServerCatalogHead(
                serverID: serverID,
                alias: head.alias,
                currentRevision: head.currentRevision,
                disabled: disabled)
            let updated = try advancedCatalog(
                from: existing,
                definitions: existing.definitions,
                heads: heads,
                tombstones: existing.tombstones,
                importMarkers: existing.importMarkers)
            try writeCatalog(updated)
            return updated
        }
    }

    /// Tombstoning is the only delete operation allowed while a definition may
    /// still be referenced. It preserves all secret-free history and disables a
    /// current head without selecting an older revision as an implicit fallback.
    @discardableResult
    public func tombstone(
        _ reference: MCPServerReference,
        reason: MCPTombstoneReason,
        expectedGeneration: UInt64,
        now: Date = Date()
    ) throws -> MCPServerCatalog {
        try withMutationLock {
            let existing = try readCatalog()
            try checkCAS(expectedGeneration, actual: existing.generation)
            guard existing.definition(for: reference) != nil else {
                throw MCPServerCatalogError.revisionNotFound
            }
            if existing.isTombstoned(reference) {
                return existing
            }
            var tombstones = existing.tombstones
            tombstones.append(MCPServerRevisionTombstone(
                reference: reference,
                reason: reason,
                tombstonedAt: now))
            var heads = existing.heads
            if let index = heads.firstIndex(where: {
                $0.serverID == reference.serverID
                    && $0.currentRevision == reference.serverRevision
            }) {
                let head = heads[index]
                heads[index] = try MCPServerCatalogHead(
                    serverID: head.serverID,
                    alias: head.alias,
                    currentRevision: head.currentRevision,
                    disabled: true)
            }
            let updated = try advancedCatalog(
                from: existing,
                definitions: existing.definitions,
                heads: heads,
                tombstones: tombstones,
                importMarkers: existing.importMarkers)
            try writeCatalog(updated)
            return updated
        }
    }

    /// Permanently removes a tombstoned definition only after an exact
    /// durable/live zero-reference proof at the same catalog generation.
    @discardableResult
    public func purge(
        _ reference: MCPServerReference,
        proof: MCPZeroReferenceProof,
        expectedGeneration: UInt64
    ) throws -> MCPServerCatalog {
        try withMutationLock {
            let existing = try readCatalog()
            try checkCAS(expectedGeneration, actual: existing.generation)
            guard proof.reference == reference,
                  proof.catalogGeneration == existing.generation else {
                throw MCPServerCatalogError.invalidReferenceProof
            }
            guard proof.provesZeroReferences else {
                throw MCPServerCatalogError.revisionStillReferenced
            }
            guard existing.definition(for: reference) != nil else {
                throw MCPServerCatalogError.revisionNotFound
            }
            guard existing.isTombstoned(reference) else {
                throw MCPServerCatalogError.purgeRequiresTombstone
            }

            let definitions = existing.definitions.filter {
                $0.reference != reference
            }
            let tombstones = existing.tombstones.filter {
                $0.reference != reference
            }
            var heads = existing.heads
            if let index = heads.firstIndex(where: {
                $0.serverID == reference.serverID
                    && $0.currentRevision == reference.serverRevision
            }) {
                let head = heads[index]
                heads[index] = try MCPServerCatalogHead(
                    serverID: head.serverID,
                    alias: head.alias,
                    currentRevision: nil,
                    disabled: true)
            }
            let updated = try advancedCatalog(
                from: existing,
                definitions: definitions,
                heads: heads,
                tombstones: tombstones,
                importMarkers: existing.importMarkers)
            try writeCatalog(updated)
            return updated
        }
    }

    // MARK: - Safe storage

    private func withMutationLock<T>(_ operation: () throws -> T) throws -> T {
        try prepareDirectory()
        do {
            return try DurableOwnerOnlyFile.withExclusiveLock(
                at: lockURL,
                operation)
        } catch let error as MCPServerCatalogError {
            throw error
        } catch let error as DurableOwnerOnlyFileError {
            if error == .commitUncertain {
                throw MCPServerCatalogError.commitUncertain
            }
            throw MCPServerCatalogError.catalogIO
        } catch {
            // The lock implementation reports all of its own failures as
            // DurableOwnerOnlyFileError. Preserve a typed error emitted by
            // the mutation body, notably an external precommit verifier,
            // instead of disguising a security rejection as catalog I/O.
            throw error
        }
    }

    private func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)])
            _ = try DurableOwnerOnlyFile.validateOwnedDirectory(at: directory)
        } catch {
            throw MCPServerCatalogError.catalogIO
        }
    }

    private func readCatalog() throws -> MCPServerCatalog {
        let data: Data?
        do {
            data = try DurableOwnerOnlyFile.read(from: fileURL)
        } catch {
            throw MCPServerCatalogError.catalogIO
        }
        guard let data else { return .empty }
        guard data.count <= Self.maximumEncodedBytes else {
            throw MCPServerCatalogError.catalogTooLarge
        }
        do {
            try validateTopLevelShape(data)
            return try JSONDecoder().decode(
                MCPServerCatalog.self,
                from: data).validated()
        } catch let error as MCPServerCatalogError {
            throw error
        } catch {
            throw MCPServerCatalogError.catalogCorrupted
        }
    }

    private func writeCatalog(_ catalog: MCPServerCatalog) throws {
        let validated = try catalog.validated()
        let data: Data
        do {
            data = try MCPConfigurationCanonical.encode(validated)
        } catch {
            throw MCPServerCatalogError.catalogCorrupted
        }
        guard data.count <= Self.maximumEncodedBytes else {
            throw MCPServerCatalogError.catalogTooLarge
        }
        do {
            try DurableOwnerOnlyFile.writeAtomically(
                data,
                to: fileURL,
                temporaryPrefix: ".mcp-catalog-")
        } catch DurableOwnerOnlyFileError.commitUncertain {
            throw MCPServerCatalogError.commitUncertain
        } catch {
            throw MCPServerCatalogError.catalogIO
        }
    }

    private func validateTopLevelShape(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(
            with: data,
            options: []) as? [String: Any] else {
            throw MCPServerCatalogError.catalogCorrupted
        }
        let expected: Set<String> = [
            "schemaVersion", "generation", "definitions", "heads",
            "tombstones", "importMarkers", "contentDigest",
        ]
        guard Set(object.keys) == expected else {
            throw MCPServerCatalogError.catalogCorrupted
        }
        guard let schema = object["schemaVersion"] as? NSNumber else {
            throw MCPServerCatalogError.catalogCorrupted
        }
        guard schema.intValue == MCPServerCatalog.currentSchemaVersion else {
            throw MCPServerCatalogError.unsupportedSchemaVersion
        }
    }

    private func checkCAS(_ expected: UInt64, actual: UInt64) throws {
        guard expected == actual else {
            throw MCPServerCatalogError.compareAndSwapConflict(
                expected: expected,
                actual: actual)
        }
    }

    private func advancedCatalog(
        from existing: MCPServerCatalog,
        definitions: [MCPServerDefinition],
        heads: [MCPServerCatalogHead],
        tombstones: [MCPServerRevisionTombstone],
        importMarkers: [MCPImportMarker]
    ) throws -> MCPServerCatalog {
        guard existing.generation < UInt64.max else {
            throw MCPServerCatalogError.generationOverflow
        }
        return try MCPServerCatalog(
            generation: existing.generation + 1,
            definitions: definitions,
            heads: heads,
            tombstones: tombstones,
            importMarkers: importMarkers)
    }
}
