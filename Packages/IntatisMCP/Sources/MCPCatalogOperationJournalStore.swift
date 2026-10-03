import Foundation
import IntatisCore
import IntatisProtocol

public enum MCPGlobalTestOperationState: String, Codable, Equatable, Hashable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
    case timedOut = "timed_out"

    public var isTerminal: Bool { self != .running }
}

/// Bounded, secret-free fact for a global Test that is not yet associated with
/// a session EventLog.
public struct MCPGlobalTestOperationRecord: Codable, Equatable, Hashable, Sendable {
    public let operationID: MCPControlOperationID
    public let serverID: MCPServerID
    public let challengeID: String
    public let configurationFingerprint: String
    public let transportFingerprint: String
    public let plannedReference: MCPServerReference?
    public let catalogGeneration: UInt64?
    public let catalogFingerprint: String?
    public let preparationFingerprint: String?
    public let callerFingerprint: String?
    public let directUserAction: Bool?
    public let testedIdentityFingerprint: String?
    public let state: MCPGlobalTestOperationState
    public let startedAt: Date
    public let completedAt: Date?
    public let sanitizedReasonCode: String?

    public init(
        operationID: MCPControlOperationID = .new(),
        serverID: MCPServerID,
        challenge: MCPConfigurationTestChallenge,
        startedAt: Date = Date()
    ) throws {
        try MCPConfigurationValidation.validateIdentifier(
            serverID.rawValue,
            field: "server_id")
        guard !challenge.challengeID.isEmpty,
              MCPConfigurationValidation.isSHA256(
                  challenge.configurationFingerprint),
              MCPConfigurationValidation.isSHA256(
                  challenge.transportFingerprint) else {
            throw MCPGlobalTestJournalError.invalidRecord
        }
        self.operationID = operationID
        self.serverID = serverID
        challengeID = challenge.challengeID
        configurationFingerprint = challenge.configurationFingerprint
        transportFingerprint = challenge.transportFingerprint
        plannedReference = nil
        catalogGeneration = nil
        catalogFingerprint = nil
        preparationFingerprint = nil
        callerFingerprint = nil
        directUserAction = nil
        testedIdentityFingerprint = nil
        state = .running
        self.startedAt = startedAt
        completedAt = nil
        sanitizedReasonCode = nil
    }

    public init(
        prepared: MCPPreparedServerConfiguration,
        authorization: MCPConfigurationTestAuthorization,
        startedAt: Date = Date()
    ) throws {
        try MCPConfigurationValidation.validateIdentifier(
            prepared.definition.reference.serverID.rawValue,
            field: "server_id")
        operationID = prepared.testOperationID
        serverID = prepared.definition.reference.serverID
        challengeID = prepared.staging.challenge.challengeID
        configurationFingerprint =
            prepared.definition.definitionFingerprint
        transportFingerprint =
            prepared.staging.challenge.transportFingerprint
        plannedReference = prepared.definition.reference
        catalogGeneration =
            prepared.catalogPublication.generation
        catalogFingerprint =
            prepared.catalogPublication.catalogFingerprint
        preparationFingerprint =
            prepared.preparationFingerprint
        callerFingerprint =
            authorization.callerFingerprint
        directUserAction =
            authorization.directUserAction
        testedIdentityFingerprint = nil
        state = .running
        self.startedAt = startedAt
        completedAt = nil
        sanitizedReasonCode = nil
    }

    fileprivate init(
        registered: MCPGlobalTestOperationRecord,
        result: MCPConfigurationTestResult
    ) throws {
        guard registered.challengeID == result.challenge.challengeID,
              registered.configurationFingerprint
                == result.challenge.configurationFingerprint,
              registered.transportFingerprint
                == result.challenge.transportFingerprint,
              result.completedAt >= registered.startedAt else {
            throw MCPGlobalTestJournalError.conflictingSettlement
        }
        let mappedState: MCPGlobalTestOperationState
        switch result.terminal {
        case .succeeded: mappedState = .succeeded
        case .failed: mappedState = .failed
        case .cancelled: mappedState = .cancelled
        case .timedOut: mappedState = .timedOut
        }
        operationID = registered.operationID
        serverID = registered.serverID
        challengeID = registered.challengeID
        configurationFingerprint = registered.configurationFingerprint
        transportFingerprint = registered.transportFingerprint
        plannedReference = registered.plannedReference
        catalogGeneration = registered.catalogGeneration
        catalogFingerprint = registered.catalogFingerprint
        preparationFingerprint =
            registered.preparationFingerprint
        callerFingerprint = registered.callerFingerprint
        directUserAction = registered.directUserAction
        testedIdentityFingerprint = result.testedIdentityFingerprint
        state = mappedState
        startedAt = registered.startedAt
        completedAt = result.completedAt
        sanitizedReasonCode = result.sanitizedReasonCode
    }

    fileprivate func validated() throws -> MCPGlobalTestOperationRecord {
        try MCPConfigurationValidation.validateIdentifier(
            serverID.rawValue,
            field: "server_id")
        guard !operationID.rawValue.isEmpty,
              !challengeID.isEmpty,
              MCPConfigurationValidation.isSHA256(configurationFingerprint),
              MCPConfigurationValidation.isSHA256(transportFingerprint) else {
            throw MCPGlobalTestJournalError.invalidRecord
        }
        let preparedFields: [Bool] = [
            plannedReference != nil,
            catalogGeneration != nil,
            catalogFingerprint != nil,
            preparationFingerprint != nil,
            callerFingerprint != nil,
            directUserAction != nil,
        ]
        guard preparedFields.allSatisfy({ $0 })
                || preparedFields.allSatisfy({ !$0 })
        else {
            throw MCPGlobalTestJournalError.invalidRecord
        }
        if plannedReference != nil {
            guard plannedReference?.serverID == serverID,
                  MCPConfigurationValidation.isSHA256(
                      catalogFingerprint ?? ""),
                  MCPConfigurationValidation.isSHA256(
                      preparationFingerprint ?? ""),
                  MCPConfigurationValidation.isSHA256(
                      callerFingerprint ?? "")
            else {
                throw MCPGlobalTestJournalError.invalidRecord
            }
        }
        if state == .running {
            guard testedIdentityFingerprint == nil,
                  completedAt == nil,
                  sanitizedReasonCode == nil else {
                throw MCPGlobalTestJournalError.invalidRecord
            }
        } else {
            guard let testedIdentityFingerprint,
                  MCPConfigurationValidation.isSHA256(
                      testedIdentityFingerprint),
                  let completedAt,
                  completedAt >= startedAt,
                  let sanitizedReasonCode else {
                throw MCPGlobalTestJournalError.invalidRecord
            }
            try MCPConfigurationValidation.validateIdentifier(
                sanitizedReasonCode,
                field: "test_reason")
        }
        return self
    }
}

private struct MCPGlobalTestJournalDigestPayload: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let records: [MCPGlobalTestOperationRecord]
}

public struct MCPGlobalTestOperationJournal: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generation: UInt64
    public let records: [MCPGlobalTestOperationRecord]
    public let contentDigest: String

    fileprivate init(
        generation: UInt64,
        records: [MCPGlobalTestOperationRecord]
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.generation = generation
        self.records = records.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.operationID.rawValue < $1.operationID.rawValue
        }
        contentDigest = MCPConfigurationCanonical.sha256(
            try MCPConfigurationCanonical.encode(
                MCPGlobalTestJournalDigestPayload(
                    schemaVersion: schemaVersion,
                    generation: generation,
                    records: self.records)))
    }

    public static var empty: MCPGlobalTestOperationJournal {
        try! MCPGlobalTestOperationJournal(generation: 0, records: [])
    }

    fileprivate func validated() throws -> MCPGlobalTestOperationJournal {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MCPGlobalTestJournalError.unsupportedSchemaVersion
        }
        let checked = try records.map { try $0.validated() }
        guard Set(checked.map(\.operationID)).count == checked.count else {
            throw MCPGlobalTestJournalError.corrupted
        }
        let rebuilt = try MCPGlobalTestOperationJournal(
            generation: generation,
            records: checked)
        guard rebuilt == self else {
            throw MCPGlobalTestJournalError.corrupted
        }
        return rebuilt
    }
}

public enum MCPGlobalTestJournalError: Error, LocalizedError, Equatable, Sendable {
    case io
    case commitUncertain
    case tooLarge
    case corrupted
    case unsupportedSchemaVersion
    case compareAndSwapConflict(expected: UInt64, actual: UInt64)
    case invalidRecord
    case operationNotFound
    case conflictingRegistration
    case conflictingSettlement
    case generationOverflow

    public var errorDescription: String? {
        switch self {
        case .io: return "The MCP Test journal could not be accessed safely."
        case .commitUncertain: return "The MCP Test journal commit could not be proven durable."
        case .tooLarge: return "The MCP Test journal exceeds its bounded size."
        case .corrupted: return "The MCP Test journal is corrupted."
        case .unsupportedSchemaVersion: return "The MCP Test journal schema is unsupported."
        case .compareAndSwapConflict: return "The MCP Test journal changed concurrently."
        case .invalidRecord: return "The MCP Test journal record is invalid."
        case .operationNotFound: return "The MCP Test operation was not registered."
        case .conflictingRegistration: return "The MCP Test operation ID was registered with different facts."
        case .conflictingSettlement: return "The MCP Test operation already has a different terminal."
        case .generationOverflow: return "The MCP Test journal generation cannot advance."
        }
    }
}

/// Owner-only bounded journal for global Test control-plane facts.
public actor MCPCatalogOperationJournalStore {
    public static let fileName = "mcp-catalog-operations-v1.json"
    public static let maximumRecords = 1_024
    public static let maximumEncodedBytes = 2 * 1024 * 1024

    public let fileURL: URL
    public let lockURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
        lockURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).lock")
            .standardizedFileURL
    }

    public func load() throws -> MCPGlobalTestOperationJournal {
        try prepareDirectory()
        return try read()
    }

    @discardableResult
    public func register(
        _ record: MCPGlobalTestOperationRecord,
        expectedGeneration: UInt64
    ) throws -> MCPGlobalTestOperationJournal {
        try mutate(expectedGeneration: expectedGeneration) { existing in
            if let prior = existing.records.first(where: {
                $0.operationID == record.operationID
            }) {
                guard prior == record else {
                    throw MCPGlobalTestJournalError.conflictingRegistration
                }
                return existing
            }
            var records = existing.records
            records.append(try record.validated())
            records = try bounded(records)
            return try advance(existing, records: records)
        }
    }

    /// Cross-process first-write registration. Exact duplicates are
    /// idempotent; an operation ID with different facts fails closed.
    @discardableResult
    public func registerFirstWrite(
        _ record: MCPGlobalTestOperationRecord
    ) throws -> MCPGlobalTestOperationJournal {
        try mutateCurrent { existing in
            if let prior = existing.records.first(where: {
                $0.operationID == record.operationID
            }) {
                guard prior == record else {
                    throw MCPGlobalTestJournalError
                        .conflictingRegistration
                }
                return existing
            }
            var records = existing.records
            records.append(try record.validated())
            records = try bounded(records)
            return try advance(existing, records: records)
        }
    }

    @discardableResult
    public func settle(
        operationID: MCPControlOperationID,
        result: MCPConfigurationTestResult,
        expectedGeneration: UInt64
    ) throws -> MCPGlobalTestOperationJournal {
        try mutate(expectedGeneration: expectedGeneration) { existing in
            guard let index = existing.records.firstIndex(where: {
                $0.operationID == operationID
            }) else {
                throw MCPGlobalTestJournalError.operationNotFound
            }
            let prior = existing.records[index]
            let settled = try MCPGlobalTestOperationRecord(
                registered: prior.state == .running ? prior : MCPGlobalTestOperationRecord(
                    operationID: prior.operationID,
                    serverID: prior.serverID,
                    challenge: result.challenge,
                    startedAt: prior.startedAt),
                result: result)
            if prior.state.isTerminal {
                guard prior == settled else {
                    throw MCPGlobalTestJournalError.conflictingSettlement
                }
                return existing
            }
            var records = existing.records
            records[index] = settled
            records = try bounded(records)
            return try advance(existing, records: records)
        }
    }

    /// Cross-process first-terminal settlement. An exact duplicate terminal
    /// is idempotent; a different terminal or payload fails closed.
    @discardableResult
    public func settleFirstTerminal(
        operationID: MCPControlOperationID,
        result: MCPConfigurationTestResult
    ) throws -> MCPGlobalTestOperationJournal {
        try mutateCurrent { existing in
            guard let index = existing.records.firstIndex(where: {
                $0.operationID == operationID
            }) else {
                throw MCPGlobalTestJournalError.operationNotFound
            }
            let prior = existing.records[index]
            let settled = try MCPGlobalTestOperationRecord(
                registered: prior,
                result: result)
            if prior.state.isTerminal {
                guard prior == settled else {
                    throw MCPGlobalTestJournalError
                        .conflictingSettlement
                }
                return existing
            }
            var records = existing.records
            records[index] = settled
            records = try bounded(records)
            return try advance(existing, records: records)
        }
    }

    private func mutate(
        expectedGeneration: UInt64,
        _ operation: (MCPGlobalTestOperationJournal) throws
            -> MCPGlobalTestOperationJournal
    ) throws -> MCPGlobalTestOperationJournal {
        try prepareDirectory()
        do {
            return try DurableOwnerOnlyFile.withExclusiveLock(at: lockURL) {
                let existing = try read()
                guard existing.generation == expectedGeneration else {
                    throw MCPGlobalTestJournalError.compareAndSwapConflict(
                        expected: expectedGeneration,
                        actual: existing.generation)
                }
                let updated = try operation(existing)
                guard updated != existing else { return existing }
                try write(updated)
                return updated
            }
        } catch let error as MCPGlobalTestJournalError {
            throw error
        } catch DurableOwnerOnlyFileError.commitUncertain {
            throw MCPGlobalTestJournalError.commitUncertain
        } catch {
            throw MCPGlobalTestJournalError.io
        }
    }

    private func mutateCurrent(
        _ operation: (MCPGlobalTestOperationJournal) throws
            -> MCPGlobalTestOperationJournal
    ) throws -> MCPGlobalTestOperationJournal {
        try prepareDirectory()
        do {
            return try DurableOwnerOnlyFile.withExclusiveLock(
                at: lockURL
            ) {
                let existing = try read()
                let updated = try operation(existing)
                guard updated != existing else {
                    return existing
                }
                try write(updated)
                return updated
            }
        } catch let error as MCPGlobalTestJournalError {
            throw error
        } catch DurableOwnerOnlyFileError.commitUncertain {
            throw MCPGlobalTestJournalError.commitUncertain
        } catch {
            throw MCPGlobalTestJournalError.io
        }
    }

    private func bounded(
        _ input: [MCPGlobalTestOperationRecord]
    ) throws -> [MCPGlobalTestOperationRecord] {
        guard input.count > Self.maximumRecords else { return input }
        var records = input.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.operationID.rawValue < $1.operationID.rawValue
        }
        while records.count > Self.maximumRecords {
            guard let removable = records.firstIndex(where: {
                $0.state.isTerminal
            }) else {
                throw MCPGlobalTestJournalError.tooLarge
            }
            records.remove(at: removable)
        }
        return records
    }

    private func advance(
        _ existing: MCPGlobalTestOperationJournal,
        records: [MCPGlobalTestOperationRecord]
    ) throws -> MCPGlobalTestOperationJournal {
        guard existing.generation < UInt64.max else {
            throw MCPGlobalTestJournalError.generationOverflow
        }
        return try MCPGlobalTestOperationJournal(
            generation: existing.generation + 1,
            records: records)
    }

    private func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)])
            _ = try DurableOwnerOnlyFile.validateOwnedDirectory(at: directory)
        } catch {
            throw MCPGlobalTestJournalError.io
        }
    }

    private func read() throws -> MCPGlobalTestOperationJournal {
        let data: Data?
        do {
            data = try DurableOwnerOnlyFile.read(from: fileURL)
        } catch {
            throw MCPGlobalTestJournalError.io
        }
        guard let data else { return .empty }
        guard data.count <= Self.maximumEncodedBytes else {
            throw MCPGlobalTestJournalError.tooLarge
        }
        do {
            guard let object = try JSONSerialization.jsonObject(
                with: data) as? [String: Any],
                  Set(object.keys) == [
                      "schemaVersion", "generation", "records", "contentDigest",
                  ] else {
                throw MCPGlobalTestJournalError.corrupted
            }
            return try JSONDecoder().decode(
                MCPGlobalTestOperationJournal.self,
                from: data).validated()
        } catch let error as MCPGlobalTestJournalError {
            throw error
        } catch {
            throw MCPGlobalTestJournalError.corrupted
        }
    }

    private func write(_ journal: MCPGlobalTestOperationJournal) throws {
        let data = try MCPConfigurationCanonical.encode(journal.validated())
        guard data.count <= Self.maximumEncodedBytes else {
            throw MCPGlobalTestJournalError.tooLarge
        }
        do {
            try DurableOwnerOnlyFile.writeAtomically(
                data,
                to: fileURL,
                temporaryPrefix: ".mcp-test-journal-")
        } catch DurableOwnerOnlyFileError.commitUncertain {
            throw MCPGlobalTestJournalError.commitUncertain
        } catch {
            throw MCPGlobalTestJournalError.io
        }
    }
}
