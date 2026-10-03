import Foundation
import IntatisConversation
import IntatisCore
import IntatisPermission
import IntatisProtocol
import IntatisTools

/// Verified, secret-free metadata emitted after the canonical EventLog rename
/// transaction and projection rebuild have both completed. App hosts can use
/// this narrow signal to patch exactly one cached sidebar row.
public struct SessionDisplayNameCommit: Equatable, Sendable {
    public var sessionID: SessionID
    public var kind: SessionKind
    public var displayName: String
    public var settingsRevision: Int
    public var projectedThroughSeq: Int

    public init(sessionID: SessionID,
                kind: SessionKind,
                displayName: String,
                settingsRevision: Int,
                projectedThroughSeq: Int) {
        self.sessionID = sessionID
        self.kind = kind
        self.displayName = displayName
        self.settingsRevision = settingsRevision
        self.projectedThroughSeq = projectedThroughSeq
    }
}

/// Current-session-only adapter shared by Code, Cowork, and CLI hosts. The
/// model never supplies a SessionID or SessionKind: those authorities are
/// fixed when the host creates this service for one runtime.
public struct EventLogSessionNamingService: SessionNamingService, Sendable {
    public typealias CommitHandler = @Sendable (SessionDisplayNameCommit) async -> Void

    private let log: EventLog
    private let kind: SessionKind
    private let commitHandler: CommitHandler?

    public init(log: EventLog,
                kind: SessionKind,
                commitHandler: CommitHandler? = nil) {
        self.log = log
        self.kind = kind
        self.commitHandler = commitHandler
    }

    public func renameCurrentSession(to name: String,
                                     operationID: String) async throws -> SessionRenameResult {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if SecretScanner.containsSecret(normalizedName) {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "session_name_contains_secret",
                message: "The session name appears to contain a secret and was not saved.")
        }

        let update: SessionDisplayNameUpdateResult
        do {
            update = try await SessionProjectionStore.renameDisplayName(
                in: log,
                kind: kind,
                displayName: normalizedName,
                source: .modelTool,
                operationID: operationID)
        } catch let error as SessionProjectionStoreError {
            switch error {
            case .invalidDisplayName, .invalidRenameOperationID, .conflictingRenameOperation,
                 .sessionMismatch:
                throw ToolExecutionRejectedWithoutSideEffect(
                    code: "session_rename_rejected",
                    message: error.localizedDescription)
            case .unknownEventTypes, .invalidSettingsHistory,
                 .unsupportedSchemaVersion, .verificationFailed:
                // These failures cannot prove whether the EventLog append
                // committed. Preserve the durable executor's conservative
                // reconciliation behavior instead of claiming no side effect.
                throw error
            }
        }

        guard let currentName = update.projection.displayName,
              let currentRevision = update.projection.settingsRevision else {
            throw SessionProjectionStoreError.verificationFailed
        }
        if let commitHandler {
            await commitHandler(SessionDisplayNameCommit(
                sessionID: update.projection.sessionID,
                kind: update.projection.kind,
                displayName: currentName,
                settingsRevision: currentRevision,
                projectedThroughSeq: update.projection.projectedThroughSeq))
        }
        return SessionRenameResult(
            previousName: update.previousDisplayName,
            name: update.displayName,
            currentName: currentName,
            revision: update.revision,
            changed: update.didAppend)
    }
}
