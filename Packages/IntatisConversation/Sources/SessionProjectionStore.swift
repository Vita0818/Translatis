import Foundation
import IntatisCore
import IntatisProtocol

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Serializes rebuild/refresh writers across EventLog instances and processes.
/// Without this lock, an older replay can finish after a newer replay and
/// regress the derived high-watermark even though EventLog itself is correct.
private final class SessionProjectionFileLock {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(at url: URL) throws -> SessionProjectionFileLock {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let descriptor = open(
            url.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              flock(descriptor, LOCK_EX) == 0 else {
            if descriptor >= 0 { _ = close(descriptor) }
            throw SessionProjectionStoreError.verificationFailed
        }
        return SessionProjectionFileLock(descriptor: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

public struct SessionAgentRegistrationProjection: Codable, Equatable, Sendable {
    public var agent: AgentID
    public var path: String
    public var model: ModelID
    public var profile: String
    public var agentInferenceBinding: AgentInferenceBinding?

    public init(payload: AgentAttachedPayload) {
        self.agent = payload.agent
        self.path = payload.path
        self.model = payload.model
        self.profile = payload.profile
        self.agentInferenceBinding = payload.agentInferenceBinding
    }
}

public struct SessionWorkspaceCapabilityProjection: Codable, Equatable, Sendable {
    public var leaseID: WorkspaceLeaseID
    public var workspaceID: WorkspaceID
    public var agent: AgentID?
    public var taskID: TaskID?
    public var rootPath: String
    public var access: WorkspaceAccess

    public init(lease: WorkspaceLease, agent: AgentID?) {
        self.leaseID = lease.id
        self.workspaceID = lease.workspaceID
        self.agent = agent
        self.taskID = lease.taskID
        self.rootPath = lease.rootPath
        self.access = lease.access
    }
}

public struct SessionCapabilityProjection: Codable, Equatable, Sendable {
    public var leaseID: CapabilityLeaseID
    public var agent: AgentID?
    public var taskID: TaskID?
    public var tools: [ToolCapability]
    public var expiresAtTaskCompletion: Bool

    public init(lease: CapabilityLease, agent: AgentID?) {
        self.leaseID = lease.id
        self.agent = agent
        self.taskID = lease.taskID
        self.tools = lease.tools.sorted { $0.rawValue < $1.rawValue }
        self.expiresAtTaskCompletion = lease.expiresAtTaskCompletion
    }
}

/// Rebuildable, secret-free fast projection. `events.jsonl` remains the only
/// canonical authority; deleting this document is always safe.
public struct SessionProjectionDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var sessionID: SessionID
    public var kind: SessionKind
    public var displayName: String?
    public var projectedThroughSeq: Int
    public var settingsRevision: Int?
    public var coworkSettings: CoworkSessionSettings?
    public var agentRegistrations: [SessionAgentRegistrationProjection]
    public var workspaceCapabilities: [SessionWorkspaceCapabilityProjection]
    public var capabilitySummaries: [SessionCapabilityProjection]
    public var completedMigrations: [SessionStorageMigratedPayload]

    public init(schemaVersion: Int = SessionProjectionDocument.currentSchemaVersion,
                sessionID: SessionID,
                kind: SessionKind,
                displayName: String? = nil,
                projectedThroughSeq: Int,
                settingsRevision: Int? = nil,
                coworkSettings: CoworkSessionSettings? = nil,
                agentRegistrations: [SessionAgentRegistrationProjection] = [],
                workspaceCapabilities: [SessionWorkspaceCapabilityProjection] = [],
                capabilitySummaries: [SessionCapabilityProjection] = [],
                completedMigrations: [SessionStorageMigratedPayload] = []) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.kind = kind
        self.displayName = displayName
        self.projectedThroughSeq = projectedThroughSeq
        self.settingsRevision = settingsRevision
        self.coworkSettings = coworkSettings
        self.agentRegistrations = agentRegistrations
        self.workspaceCapabilities = workspaceCapabilities
        self.capabilitySummaries = capabilitySummaries
        self.completedMigrations = completedMigrations
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case legacyVersion = "version"
        case sessionID, kind, displayName, projectedThroughSeq, settingsRevision
        case coworkSettings, agentRegistrations, workspaceCapabilities
        case capabilitySummaries, completedMigrations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyVersion)
            ?? 1
        sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        kind = try container.decode(SessionKind.self, forKey: .kind)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        projectedThroughSeq = try container.decode(Int.self, forKey: .projectedThroughSeq)
        settingsRevision = try container.decodeIfPresent(Int.self, forKey: .settingsRevision)
        coworkSettings = try container.decodeIfPresent(
            CoworkSessionSettings.self,
            forKey: .coworkSettings)
        agentRegistrations = try container.decodeIfPresent(
            [SessionAgentRegistrationProjection].self,
            forKey: .agentRegistrations) ?? []
        workspaceCapabilities = try container.decodeIfPresent(
            [SessionWorkspaceCapabilityProjection].self,
            forKey: .workspaceCapabilities) ?? []
        capabilitySummaries = try container.decodeIfPresent(
            [SessionCapabilityProjection].self,
            forKey: .capabilitySummaries) ?? []
        completedMigrations = try container.decodeIfPresent(
            [SessionStorageMigratedPayload].self,
            forKey: .completedMigrations) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encode(projectedThroughSeq, forKey: .projectedThroughSeq)
        try container.encodeIfPresent(settingsRevision, forKey: .settingsRevision)
        try container.encodeIfPresent(coworkSettings, forKey: .coworkSettings)
        try container.encode(agentRegistrations, forKey: .agentRegistrations)
        try container.encode(workspaceCapabilities, forKey: .workspaceCapabilities)
        try container.encode(capabilitySummaries, forKey: .capabilitySummaries)
        try container.encode(completedMigrations, forKey: .completedMigrations)
    }
}

public enum SessionProjectionStoreError: Error, LocalizedError, Equatable, Sendable {
    case unknownEventTypes
    case invalidSettingsHistory
    case sessionMismatch
    case invalidDisplayName
    case invalidRenameOperationID
    case conflictingRenameOperation
    case unsupportedSchemaVersion
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .unknownEventTypes:
            return "This \(IntatisHostApplication.identity.name) version cannot fully project one or more newer session events."
        case .invalidSettingsHistory:
            return "The session settings history has an invalid revision or identity."
        case .sessionMismatch:
            return "The derived session projection belongs to another session."
        case .invalidDisplayName:
            return "Session names must contain 1–120 characters and cannot contain control characters."
        case .invalidRenameOperationID:
            return "The session rename operation identifier is invalid."
        case .conflictingRenameOperation:
            return "The session rename operation identifier was already used for another change."
        case .unsupportedSchemaVersion:
            return "The session projection uses an unsupported schema version and must be rebuilt by a compatible \(IntatisHostApplication.identity.name) version."
        case .verificationFailed:
            return "The derived session projection could not be verified after writing."
        }
    }
}

/// Exact result of one EventLog-first display-name transaction. `didAppend`
/// reports whether this invocation committed a new settings revision; an exact
/// operation retry returns its original transition while `projection` remains
/// the latest canonical session state.
public struct SessionDisplayNameUpdateResult: Equatable, Sendable {
    public var previousDisplayName: String?
    public var displayName: String
    public var revision: Int
    public var didAppend: Bool
    public var projection: SessionProjectionDocument

    public init(previousDisplayName: String?,
                displayName: String,
                revision: Int,
                didAppend: Bool,
                projection: SessionProjectionDocument) {
        self.previousDisplayName = previousDisplayName
        self.displayName = displayName
        self.revision = revision
        self.didAppend = didAppend
        self.projection = projection
    }
}

private struct SessionDisplayNameTransactionValue: Sendable {
    var previousDisplayName: String?
    var displayName: String
    var revision: Int
}

/// `appendSessionStateTransaction` executes synchronously while its exclusive
/// file lock is held, but its builder is `@Sendable`. This tiny lock-protected
/// capture returns the exact state observed at that linearization point without
/// weakening the EventLog API or relying on a racy pre-read.
private final class SessionDisplayNameTransactionCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SessionDisplayNameTransactionValue?

    func set(_ value: SessionDisplayNameTransactionValue) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func get() -> SessionDisplayNameTransactionValue? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

public enum SessionProjectionStore {
    public static let fileName = "session.json"
    public static let legacyCoworkSettingsMigrationID = "legacy-cowork-user-defaults-v1"
    public static let legacyWorkspaceAccessMigrationID = "legacy-workspace-user-defaults-v1"
    public static let legacyDisplayNameMigrationID = "legacy-session-display-name-v1"

    public static func fileURL(for log: EventLog) -> URL {
        log.sessionDirectoryURL.appendingPathComponent(fileName)
    }

    /// Strictly folds canonical session settings from an already verified
    /// EventLog history. Safety-sensitive compare-and-append callers use this
    /// same revision-chain validation as `session.json` rebuilds instead of a
    /// fail-soft UI/runtime projection that may ignore an invalid transition.
    public static func canonicalSessionSettings(
        from envelopes: [Envelope],
        session: SessionID
    ) throws -> SessionSettingsUpdatedPayload? {
        try foldSessionState(envelopes, session: session).settings
    }

    public static func load(from fileURL: URL,
                            expectedSession: SessionID? = nil) throws -> SessionProjectionDocument {
        let data = try Data(contentsOf: fileURL)
        let document = try makeDecoder().decode(SessionProjectionDocument.self, from: data)
        guard document.schemaVersion == SessionProjectionDocument.currentSchemaVersion else {
            throw SessionProjectionStoreError.unsupportedSchemaVersion
        }
        if let expectedSession, document.sessionID != expectedSession {
            throw SessionProjectionStoreError.sessionMismatch
        }
        return document
    }

    /// Strictly rebuilds the derived document. Unknown future event types stop
    /// the overwrite, preserving a possibly newer projection instead of
    /// claiming that this binary projected state it does not understand.
    @discardableResult
    public static func rebuild(from log: EventLog) async throws -> SessionProjectionDocument {
        let target = fileURL(for: log)
        let lock = try SessionProjectionFileLock.acquire(
            at: target.appendingPathExtension("lock"))
        defer { lock.release() }
        return try await rebuildLocked(from: log, target: target)
    }

    private static func rebuildLocked(
        from log: EventLog,
        target: URL
    ) async throws -> SessionProjectionDocument {
        let replay = try await log.replayForProjectionChecked()
        guard !replay.containsUnknownEventTypes else {
            throw SessionProjectionStoreError.unknownEventTypes
        }
        let session = await log.sessionID
        let legacyDisplayName = readCompatibleDisplayName(from: target)
        let document = try build(
            session: session,
            replay: replay,
            legacyDisplayName: legacyDisplayName)
        return try write(document, to: target)
    }

    /// Advances a derived projection from its durable high-watermark, but never
    /// trusts cache fields merely because their sequence number looks current.
    /// A full canonical fold is used as the verification oracle; a valid
    /// lagging cache may still be advanced with its tail, but that result is
    /// written only when it exactly matches the canonical fold. This keeps the
    /// incremental path while making EventLog win over same-watermark or
    /// lagging cache corruption.
    @discardableResult
    public static func refresh(from log: EventLog) async throws -> SessionProjectionDocument {
        let session = await log.sessionID
        let target = fileURL(for: log)
        let lock = try SessionProjectionFileLock.acquire(
            at: target.appendingPathExtension("lock"))
        defer { lock.release() }
        let replay = try await log.replayForProjectionChecked()
        guard !replay.containsUnknownEventTypes else {
            throw SessionProjectionStoreError.unknownEventTypes
        }
        let lastDurableSeq = replay.lastDurableSeq ?? -1
        let canonical = try build(
            session: session,
            replay: replay,
            legacyDisplayName: readCompatibleDisplayName(from: target))
        guard let existing = try? load(from: target, expectedSession: session),
              existing.projectedThroughSeq >= -1,
              existing.projectedThroughSeq <= lastDurableSeq else {
            return try write(canonical, to: target)
        }
        if existing == canonical {
            return existing
        }
        let (start, overflow) = existing.projectedThroughSeq.addingReportingOverflow(1)
        guard !overflow else { throw SessionProjectionStoreError.verificationFailed }
        guard existing.projectedThroughSeq < lastDurableSeq else {
            return try write(canonical, to: target)
        }
        let tail = replay.envelopes.filter { $0.seq >= start }
        let advanced = try? applyTail(
            tail,
            to: existing,
            session: session,
            projectedThroughSeq: lastDurableSeq)
        if let advanced, advanced == canonical {
            return try write(advanced, to: target)
        }
        return try write(canonical, to: target)
    }

    @discardableResult
    public static func updateSettings(
        in log: EventLog,
        kind: SessionKind,
        coworkSettings: CoworkSessionSettings?,
        displayName: String? = nil,
        changeKind: SessionSettingsChangeKind = .updated
    ) async throws -> SessionProjectionDocument {
        let session = await log.sessionID
        if let coworkSettings {
            guard kind == .cowork,
                  coworkSettings.schemaVersion == CoworkSessionSettings.currentSchemaVersion else {
                throw SessionProjectionStoreError.invalidSettingsHistory
            }
            guard coworkSettings.sessionID == session else {
                throw SessionProjectionStoreError.sessionMismatch
            }
        }
        let requestedDisplayName = try displayName.map { try normalizedDisplayName($0) }
        _ = try await log.appendSessionStateTransaction { envelopes in
            let state = try foldSessionState(envelopes, session: session)
            let effectiveDisplayName = requestedDisplayName ?? state.settings?.displayName
            if (state.settings?.kind ?? inferredKind(session)) == kind,
               state.settings?.cowork == coworkSettings,
               state.settings?.displayName == effectiveDisplayName {
                return []
            }
            let revision = try nextRevision(after: state.settings?.revision)
            return [.sessionSettingsUpdated(SessionSettingsUpdatedPayload(
                revision: revision,
                previousRevision: state.settings?.revision,
                changeKind: changeKind,
                kind: kind,
                displayName: effectiveDisplayName,
                cowork: coworkSettings))]
        }
        return try await rebuild(from: log)
    }

    /// Changes only the display name while preserving the latest settings
    /// snapshot observed under EventLog's cross-process append lock.
    @discardableResult
    public static func updateDisplayName(
        in log: EventLog,
        kind: SessionKind,
        displayName: String
    ) async throws -> SessionProjectionDocument {
        try await renameDisplayName(
            in: log,
            kind: kind,
            displayName: displayName,
            source: .userInterface).projection
    }

    /// EventLog-first rename transaction with an optional host-only operation
    /// identity. A new operation ID is durably recorded even when the requested
    /// name already matches, closing the A→X, B→Y, retry-A overwrite race.
    @discardableResult
    public static func renameDisplayName(
        in log: EventLog,
        kind: SessionKind,
        displayName: String,
        source: SessionDisplayNameSource,
        operationID: String? = nil
    ) async throws -> SessionDisplayNameUpdateResult {
        let session = await log.sessionID
        guard let normalized = try normalizedDisplayName(displayName) else {
            throw SessionProjectionStoreError.invalidDisplayName
        }
        let normalizedOperationID = try normalizedRenameOperationID(operationID)
        let capture = SessionDisplayNameTransactionCapture()
        let appended = try await log.appendSessionStateTransaction { envelopes in
            let state = try foldSessionState(envelopes, session: session)
            let effectiveKind = state.settings?.kind ?? kind
            guard effectiveKind == kind else {
                throw SessionProjectionStoreError.sessionMismatch
            }
            if let normalizedOperationID {
                var previousSettings: SessionSettingsUpdatedPayload?
                var matchedOperation: SessionDisplayNameTransactionValue?
                for envelope in envelopes {
                    guard case .sessionSettingsUpdated(let payload) = envelope.event else {
                        continue
                    }
                    if payload.renameOperationID == normalizedOperationID {
                        guard payload.changeKind == .renamed,
                              payload.kind == kind,
                              payload.displayName == normalized,
                              payload.displayNameSource == source else {
                            throw SessionProjectionStoreError.conflictingRenameOperation
                        }
                        if matchedOperation == nil {
                            matchedOperation = SessionDisplayNameTransactionValue(
                                previousDisplayName: previousSettings?.displayName,
                                displayName: normalized,
                                revision: payload.revision)
                        }
                    }
                    previousSettings = payload
                }
                if let matchedOperation {
                    capture.set(matchedOperation)
                    return []
                }
            }
            if normalizedOperationID == nil,
               state.settings?.displayName == normalized,
               let revision = state.settings?.revision {
                capture.set(SessionDisplayNameTransactionValue(
                    previousDisplayName: normalized,
                    displayName: normalized,
                    revision: revision))
                return []
            }
            let revision = try nextRevision(after: state.settings?.revision)
            capture.set(SessionDisplayNameTransactionValue(
                previousDisplayName: state.settings?.displayName,
                displayName: normalized,
                revision: revision))
            return [.sessionSettingsUpdated(SessionSettingsUpdatedPayload(
                revision: revision,
                previousRevision: state.settings?.revision,
                changeKind: .renamed,
                kind: effectiveKind,
                displayName: normalized,
                renameOperationID: normalizedOperationID,
                displayNameSource: source,
                cowork: state.settings?.cowork))]
        }
        let projection = try await rebuild(from: log)
        guard let transaction = capture.get() else {
            throw SessionProjectionStoreError.verificationFailed
        }
        return SessionDisplayNameUpdateResult(
            previousDisplayName: transaction.previousDisplayName,
            displayName: transaction.displayName,
            revision: transaction.revision,
            didAppend: !appended.isEmpty,
            projection: projection)
    }

    /// Installs the host-generated initial Chat title only while the canonical
    /// session name is still absent. The absence check and settings append are
    /// performed under EventLog's cross-process lock, so a user Rename that
    /// wins before this transaction can never be overwritten.
    ///
    /// `nil` means no verified automatic-title commit should be published:
    /// either a name already existed at the linearization point, or a newer
    /// settings revision (for example a concurrent user Rename) won before the
    /// derived projection was rebuilt and read back.
    @discardableResult
    public static func setAutomaticDisplayNameIfAbsent(
        in log: EventLog,
        kind: SessionKind,
        displayName: String
    ) async throws -> SessionDisplayNameUpdateResult? {
        let session = await log.sessionID
        guard kind == .chat, inferredKind(session) == .chat else {
            throw SessionProjectionStoreError.sessionMismatch
        }
        guard let normalized = try normalizedDisplayName(displayName) else {
            throw SessionProjectionStoreError.invalidDisplayName
        }
        let capture = SessionDisplayNameTransactionCapture()
        let appended = try await log.appendSessionStateTransaction { envelopes in
            let state = try foldSessionState(envelopes, session: session)
            let effectiveKind = state.settings?.kind ?? kind
            guard effectiveKind == kind else {
                throw SessionProjectionStoreError.sessionMismatch
            }
            guard state.settings?.displayName == nil else {
                return []
            }
            let revision = try nextRevision(after: state.settings?.revision)
            capture.set(SessionDisplayNameTransactionValue(
                previousDisplayName: nil,
                displayName: normalized,
                revision: revision))
            return [.sessionSettingsUpdated(SessionSettingsUpdatedPayload(
                revision: revision,
                previousRevision: state.settings?.revision,
                changeKind: .renamed,
                kind: effectiveKind,
                displayName: normalized,
                renameOperationID: nil,
                displayNameSource: nil,
                cowork: state.settings?.cowork))]
        }
        guard !appended.isEmpty else { return nil }

        let projection = try await rebuild(from: log)
        guard let transaction = capture.get(),
              projection.sessionID == session,
              projection.kind == kind,
              projection.projectedThroughSeq >= (appended.last?.seq ?? -1) else {
            throw SessionProjectionStoreError.verificationFailed
        }

        guard projection.settingsRevision == transaction.revision,
              projection.displayName == transaction.displayName else {
            if let projectedRevision = projection.settingsRevision,
               projectedRevision > transaction.revision,
               projection.displayName != nil {
                // A later explicit Rename is canonical. The automatic event
                // remains valid history, but it must not emit a stale UI
                // callback or attempt to restore its older title.
                return nil
            }
            throw SessionProjectionStoreError.verificationFailed
        }

        return SessionDisplayNameUpdateResult(
            previousDisplayName: transaction.previousDisplayName,
            displayName: transaction.displayName,
            revision: transaction.revision,
            didAppend: true,
            projection: projection)
    }

    /// Imports a full legacy settings snapshot exactly once. Canonical append
    /// precedes legacy-key cleanup; callers remove old preferences only after
    /// this method returns a read-back-verified projection.
    @discardableResult
    public static func migrateLegacyCoworkSettings(
        in log: EventLog,
        settings: CoworkSessionSettings,
        displayName: String? = nil
    ) async throws -> SessionProjectionDocument {
        let session = await log.sessionID
        guard settings.schemaVersion == CoworkSessionSettings.currentSchemaVersion else {
            throw SessionProjectionStoreError.invalidSettingsHistory
        }
        guard settings.sessionID == session else {
            throw SessionProjectionStoreError.sessionMismatch
        }
        let requestedDisplayName = try displayName.map { try normalizedDisplayName($0) }
        _ = try await log.appendSessionStateTransaction { envelopes in
            let state = try foldSessionState(envelopes, session: session)
            guard state.migrations[legacyCoworkSettingsMigrationID] == nil else {
                return []
            }
            let revision = try nextRevision(after: state.settings?.revision)
            let settingsEvent = SessionSettingsUpdatedPayload(
                revision: revision,
                previousRevision: state.settings?.revision,
                changeKind: .migrated,
                kind: .cowork,
                displayName: requestedDisplayName ?? state.settings?.displayName,
                cowork: settings)
            let marker = SessionStorageMigratedPayload(
                migrationID: legacyCoworkSettingsMigrationID,
                source: .legacyCoworkUserDefaults,
                settingsRevision: revision)
            return [
                .sessionSettingsUpdated(settingsEvent),
                .sessionStorageMigrated(marker),
            ]
        }
        return try await rebuild(from: log)
    }

    /// Records a separately verified migration such as the opaque workspace
    /// bookmark file. Repeating the operation is idempotent by migration ID.
    @discardableResult
    public static func recordMigration(
        in log: EventLog,
        migrationID: String,
        source: SessionStorageMigrationSource
    ) async throws -> SessionProjectionDocument {
        guard !migrationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionProjectionStoreError.invalidSettingsHistory
        }
        let session = await log.sessionID
        _ = try await log.appendSessionStateTransaction { envelopes in
            let state = try foldSessionState(envelopes, session: session)
            guard state.migrations[migrationID] == nil else { return [] }
            return [.sessionStorageMigrated(SessionStorageMigratedPayload(
                migrationID: migrationID,
                source: source,
                settingsRevision: state.settings?.revision))]
        }
        return try await rebuild(from: log)
    }

    /// Converts the old projection-only display name into canonical EventLog
    /// state. Sessions without a legacy name remain untouched.
    @discardableResult
    public static func migrateLegacyDisplayName(
        in log: EventLog,
        kind: SessionKind
    ) async throws -> SessionProjectionDocument {
        // Capture the projection-only value before any rebuild can replace the
        // legacy document with a schema-v2 cache. If the process stops or the
        // append fails before the EventLog transaction commits, the legacy
        // document remains untouched and a later attempt can read it again.
        let legacyDisplayName = readCompatibleDisplayName(from: fileURL(for: log))
        let session = await log.sessionID
        _ = try await log.appendSessionStateTransaction { envelopes in
            let state = try foldSessionState(envelopes, session: session)
            guard state.migrations[legacyDisplayNameMigrationID] == nil,
                  state.settings?.displayName == nil,
                  let legacyDisplayName else { return [] }
            let revision = try nextRevision(after: state.settings?.revision)
            let settingsEvent = SessionSettingsUpdatedPayload(
                revision: revision,
                previousRevision: state.settings?.revision,
                changeKind: .migrated,
                kind: state.settings?.kind ?? kind,
                displayName: legacyDisplayName,
                cowork: state.settings?.cowork)
            let marker = SessionStorageMigratedPayload(
                migrationID: legacyDisplayNameMigrationID,
                source: .legacySessionMetadata,
                settingsRevision: revision)
            return [
                .sessionSettingsUpdated(settingsEvent),
                .sessionStorageMigrated(marker),
            ]
        }
        return try await rebuild(from: log)
    }

    private struct SessionStateFold {
        var settings: SessionSettingsUpdatedPayload?
        var migrations: [String: SessionStorageMigratedPayload]
    }

    private static func applyTail(
        _ envelopes: [Envelope],
        to base: SessionProjectionDocument,
        session: SessionID,
        projectedThroughSeq: Int
    ) throws -> SessionProjectionDocument {
        guard base.sessionID == session,
              base.schemaVersion == SessionProjectionDocument.currentSchemaVersion else {
            throw SessionProjectionStoreError.sessionMismatch
        }
        var result = base
        var agents = Dictionary(
            result.agentRegistrations.map { ($0.agent, $0) },
            uniquingKeysWith: { _, latest in latest })
        var workspaceLeases = Dictionary(
            result.workspaceCapabilities.map { ($0.leaseID, $0) },
            uniquingKeysWith: { _, latest in latest })
        var capabilityLeases = Dictionary(
            result.capabilitySummaries.map { ($0.leaseID, $0) },
            uniquingKeysWith: { _, latest in latest })
        var migrations = Dictionary(
            result.completedMigrations.map { ($0.migrationID, $0) },
            uniquingKeysWith: { _, latest in latest })

        for envelope in envelopes {
            guard envelope.session == session,
                  envelope.seq > base.projectedThroughSeq else {
                throw SessionProjectionStoreError.verificationFailed
            }
            switch envelope.event {
            case .sessionSettingsUpdated(let payload):
                let (expectedRevision, revisionOverflow) =
                    (result.settingsRevision ?? 0).addingReportingOverflow(1)
                guard payload.schemaVersion == SessionSettingsUpdatedPayload.currentSchemaVersion,
                      !revisionOverflow,
                      payload.previousRevision == result.settingsRevision,
                      payload.revision == expectedRevision,
                      payload.cowork?.sessionID == nil || payload.cowork?.sessionID == session,
                      payload.cowork?.schemaVersion == nil
                        || payload.cowork?.schemaVersion == CoworkSessionSettings.currentSchemaVersion else {
                    throw SessionProjectionStoreError.invalidSettingsHistory
                }
                result.kind = payload.kind
                result.displayName = payload.displayName
                result.settingsRevision = payload.revision
                result.coworkSettings = payload.cowork
            case .sessionStorageMigrated(let payload):
                guard payload.schemaVersion == SessionStorageMigratedPayload.currentSchemaVersion,
                      !payload.migrationID.isEmpty else {
                    throw SessionProjectionStoreError.invalidSettingsHistory
                }
                if let existing = migrations[payload.migrationID], existing != payload {
                    throw SessionProjectionStoreError.invalidSettingsHistory
                }
                migrations[payload.migrationID] = payload
            case .agentAttached(let payload):
                agents[payload.agent] = SessionAgentRegistrationProjection(payload: payload)
            case .agentSpawned(let payload):
                if agents[payload.agent] == nil {
                    agents[payload.agent] = SessionAgentRegistrationProjection(payload:
                        AgentAttachedPayload(
                            agent: payload.agent,
                            path: payload.path,
                            model: payload.model,
                            profile: "reviewed",
                            agentInferenceBinding: nil,
                            metadata: payload.metadata))
                }
            case .agentDetached(let payload):
                agents[payload.agent] = nil
            case .workspaceLeaseGranted(let payload):
                workspaceLeases[payload.lease.id] = SessionWorkspaceCapabilityProjection(
                    lease: payload.lease,
                    agent: payload.agent)
            case .workspaceLeaseRevoked(let payload):
                workspaceLeases[payload.leaseID] = nil
            case .capabilityLeaseCreated(let payload):
                capabilityLeases[payload.lease.id] = SessionCapabilityProjection(
                    lease: payload.lease,
                    agent: payload.agent)
            case .capabilityLeaseRevoked(let payload):
                capabilityLeases[payload.leaseID] = nil
            default:
                break
            }
        }
        result.projectedThroughSeq = projectedThroughSeq
        result.agentRegistrations = agents.values.sorted {
            $0.agent.rawValue < $1.agent.rawValue
        }
        result.workspaceCapabilities = workspaceLeases.values.sorted {
            $0.leaseID.rawValue < $1.leaseID.rawValue
        }
        result.capabilitySummaries = capabilityLeases.values.sorted {
            $0.leaseID.rawValue < $1.leaseID.rawValue
        }
        result.completedMigrations = migrations.values.sorted {
            $0.migrationID < $1.migrationID
        }
        return result
    }

    private static func foldSessionState(
        _ envelopes: [Envelope],
        session: SessionID
    ) throws -> SessionStateFold {
        var settingsPayload: SessionSettingsUpdatedPayload?
        var migrations: [String: SessionStorageMigratedPayload] = [:]
        for envelope in envelopes {
            switch envelope.event {
            case .sessionSettingsUpdated(let payload):
                guard payload.schemaVersion == SessionSettingsUpdatedPayload.currentSchemaVersion,
                      payload.revision > 0,
                      payload.cowork?.sessionID == nil || payload.cowork?.sessionID == session,
                      payload.cowork?.schemaVersion == nil
                        || payload.cowork?.schemaVersion == CoworkSessionSettings.currentSchemaVersion else {
                    throw SessionProjectionStoreError.invalidSettingsHistory
                }
                if let current = settingsPayload {
                    let expectedRevision = try nextRevision(after: current.revision)
                    guard payload.previousRevision == current.revision,
                          payload.revision == expectedRevision else {
                        throw SessionProjectionStoreError.invalidSettingsHistory
                    }
                } else {
                    guard payload.previousRevision == nil, payload.revision == 1 else {
                        throw SessionProjectionStoreError.invalidSettingsHistory
                    }
                }
                settingsPayload = payload
            case .sessionStorageMigrated(let payload):
                guard payload.schemaVersion == SessionStorageMigratedPayload.currentSchemaVersion,
                      !payload.migrationID.isEmpty else {
                    throw SessionProjectionStoreError.invalidSettingsHistory
                }
                if let existing = migrations[payload.migrationID], existing != payload {
                    throw SessionProjectionStoreError.invalidSettingsHistory
                }
                migrations[payload.migrationID] = payload
            default:
                break
            }
        }
        return SessionStateFold(settings: settingsPayload, migrations: migrations)
    }

    private static func build(
        session: SessionID,
        replay: EventLogProjectionReplay,
        legacyDisplayName: String?
    ) throws -> SessionProjectionDocument {
        let state = try foldSessionState(replay.envelopes, session: session)

        let cowork = CoworkProjection.build(from: replay.envelopes)
        let agents = cowork.agentRoster.values
            .map(SessionAgentRegistrationProjection.init(payload:))
            .sorted { $0.agent.rawValue < $1.agent.rawValue }
        let workspaceCapabilities = cowork.workspaceLeases.values
            .map { lease in
                SessionWorkspaceCapabilityProjection(
                    lease: lease,
                    agent: cowork.workspaceLeaseAgents[lease.id])
            }
            .sorted { $0.leaseID.rawValue < $1.leaseID.rawValue }
        let capabilitySummaries = cowork.capabilityLeases.values
            .map { lease in
                SessionCapabilityProjection(
                    lease: lease,
                    agent: cowork.capabilityLeaseAgents[lease.id])
            }
            .sorted { $0.leaseID.rawValue < $1.leaseID.rawValue }

        return SessionProjectionDocument(
            sessionID: session,
            kind: state.settings?.kind ?? inferredKind(session),
            displayName: state.settings?.displayName ?? legacyDisplayName,
            projectedThroughSeq: replay.lastDurableSeq ?? -1,
            settingsRevision: state.settings?.revision,
            coworkSettings: state.settings?.cowork,
            agentRegistrations: agents,
            workspaceCapabilities: workspaceCapabilities,
            capabilitySummaries: capabilitySummaries,
            completedMigrations: state.migrations.values.sorted { $0.migrationID < $1.migrationID })
    }

    private static func write(_ document: SessionProjectionDocument,
                              to fileURL: URL) throws -> SessionProjectionDocument {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try makeEncoder().encode(document)
        try writeOwnerOnlyAtomically(data, to: fileURL)
        let verified = try load(from: fileURL, expectedSession: document.sessionID)
        guard verified == document else {
            throw SessionProjectionStoreError.verificationFailed
        }
        return verified
    }

    private static func writeOwnerOnlyAtomically(_ data: Data, to fileURL: URL) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(
            ".session-projection-\(UUID().uuidString).tmp")
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw SessionProjectionStoreError.verificationFailed
        }
        var removeTemporary = true
        defer {
            _ = close(descriptor)
            if removeTemporary { _ = unlink(temporary.path) }
        }
        let wroteAll = data.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < rawBuffer.count {
                #if canImport(Darwin)
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset)
                #elseif canImport(Glibc)
                let count = Glibc.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset)
                #elseif canImport(Musl)
                let count = Musl.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset)
                #else
                let count = -1
                #endif
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wroteAll, fsync(descriptor) == 0,
              rename(temporary.path, fileURL.path) == 0 else {
            throw SessionProjectionStoreError.verificationFailed
        }
        removeTemporary = false
        let parentDescriptor = open(parent.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard parentDescriptor >= 0 else {
            throw SessionProjectionStoreError.verificationFailed
        }
        defer { _ = close(parentDescriptor) }
        guard fsync(parentDescriptor) == 0 else {
            throw SessionProjectionStoreError.verificationFailed
        }
    }

    private static func readCompatibleDisplayName(from fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schemaVersion"] == nil,
              (object["version"] as? Int ?? 1) <= SessionProjectionDocument.currentSchemaVersion,
              let raw = object["displayName"] as? String else { return nil }
        return try? normalizedDisplayName(raw)
    }

    private static func normalizedDisplayName(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 120,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw SessionProjectionStoreError.invalidDisplayName
        }
        return value
    }

    private static func normalizedRenameOperationID(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 256,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw SessionProjectionStoreError.invalidRenameOperationID
        }
        return value
    }

    private static func inferredKind(_ session: SessionID) -> SessionKind {
        if session.rawValue.hasPrefix("cowork_") { return .cowork }
        if session.rawValue.hasPrefix("code_") { return .code }
        return .chat
    }

    private static func nextRevision(after revision: Int?) throws -> Int {
        let (next, overflow) = (revision ?? 0).addingReportingOverflow(1)
        guard !overflow else {
            throw SessionProjectionStoreError.invalidSettingsHistory
        }
        return next
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
