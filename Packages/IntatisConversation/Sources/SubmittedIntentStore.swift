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

private final class SubmittedIntentOutboxFileLock {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(at url: URL) throws -> SubmittedIntentOutboxFileLock {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let descriptor = open(
            url.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw SubmittedIntentStoreError.lockUnavailable
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_mode & S_IFMT == S_IFREG,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              flock(descriptor, LOCK_EX) == 0 else {
            _ = close(descriptor)
            throw SubmittedIntentStoreError.lockUnavailable
        }
        return SubmittedIntentOutboxFileLock(descriptor: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

/// One locally durable submitted intent that has not yet been admitted to the
/// canonical EventLog. The payload and creation time are first-write-wins;
/// only the bounded canonical-write diagnostic may change between retries.
public struct SubmittedIntentOutboxEntry: Codable, Equatable, Sendable {
    public let submissionID: SubmissionID
    public let payload: UserMessagePayload
    public let createdAt: Date
    public let lastCanonicalError: String?

    public init(payload: UserMessagePayload,
                createdAt: Date = Date(),
                lastCanonicalError: String? = nil) throws {
        guard let submissionID = payload.submissionID else {
            throw SubmittedIntentStoreError.missingSubmissionID
        }
        self.submissionID = submissionID
        self.payload = payload
        self.createdAt = createdAt
        self.lastCanonicalError = lastCanonicalError
        try SubmittedIntentOutboxStore.validate(self)
    }

    fileprivate init(submissionID: SubmissionID,
                     payload: UserMessagePayload,
                     createdAt: Date,
                     lastCanonicalError: String?) {
        self.submissionID = submissionID
        self.payload = payload
        self.createdAt = createdAt
        self.lastCanonicalError = lastCanonicalError
    }
}

/// Non-canonical, session-owned fallback used only until the immutable intent
/// has been appended to EventLog. It is safe to delete after canonicalization.
public struct SubmittedIntentOutboxDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sessionID: SessionID
    public let entries: [SubmittedIntentOutboxEntry]

    public init(schemaVersion: Int = SubmittedIntentOutboxDocument.currentSchemaVersion,
                sessionID: SessionID,
                entries: [SubmittedIntentOutboxEntry] = []) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.entries = entries
    }
}

public enum SubmittedIntentStoreError: Error, LocalizedError, Equatable, Sendable {
    case missingSubmissionID
    case submissionIDMismatch
    case invalidSubmissionID
    case invalidCreatedAt
    case invalidCanonicalError
    case duplicateSubmissionID(SubmissionID)
    case payloadConflict(SubmissionID)
    case sessionMismatch
    case unsupportedSchemaVersion
    case unsafeFile
    case lockUnavailable
    case storageUnavailable
    case verificationFailed
    case entryNotFound(SubmissionID)
    case canonicalHistoryConflict(SubmissionID)
    case invalidAttempt
    case invalidStatusTransition(SubmissionID)

    public var errorDescription: String? {
        switch self {
        case .missingSubmissionID:
            return "A submitted intent must have a stable submission identity."
        case .submissionIDMismatch:
            return "The submitted intent identity does not match its immutable payload."
        case .invalidSubmissionID:
            return "The submitted intent identity is invalid."
        case .invalidCreatedAt:
            return "The submitted intent creation time is invalid."
        case .invalidCanonicalError:
            return "The submitted intent diagnostic is invalid."
        case .duplicateSubmissionID:
            return "The submitted-intent outbox contains a duplicate identity."
        case .payloadConflict:
            return "A different immutable payload already uses this submission identity."
        case .sessionMismatch:
            return "The submitted-intent outbox belongs to another session."
        case .unsupportedSchemaVersion:
            return "The submitted-intent outbox uses an unsupported schema version."
        case .unsafeFile:
            return "The submitted-intent outbox is not a safe owner-only regular file."
        case .lockUnavailable:
            return "The submitted-intent outbox lock is unavailable."
        case .storageUnavailable:
            return "The submitted-intent outbox storage is unavailable."
        case .verificationFailed:
            return "The submitted-intent outbox could not be verified after writing."
        case .entryNotFound:
            return "The submitted intent is no longer present in the local outbox."
        case .canonicalHistoryConflict:
            return "The canonical submission history is inconsistent."
        case .invalidAttempt:
            return "Submission attempt numbers must be positive."
        case .invalidStatusTransition:
            return "The submission status transition is invalid."
        }
    }
}

/// Secure file operations for the explicit local fallback. EventLog remains
/// canonical; this store never drives execution without canonical admission.
public enum SubmittedIntentOutboxStore {
    public static let fileName = "submitted-intent-outbox.json"
    private static let maximumErrorCharacters = 1_024

    public static func fileURL(sessionDirectoryURL: URL) -> URL {
        sessionDirectoryURL.appendingPathComponent(fileName)
    }

    public static func fileURL(for log: EventLog) -> URL {
        fileURL(sessionDirectoryURL: log.sessionDirectoryURL)
    }

    public static func load(sessionDirectoryURL: URL,
                            sessionID: SessionID) throws -> SubmittedIntentOutboxDocument {
        let url = fileURL(sessionDirectoryURL: sessionDirectoryURL)
        let lock = try SubmittedIntentOutboxFileLock.acquire(at: lockURL(for: url))
        defer { lock.release() }
        return try loadUnlocked(from: url, sessionID: sessionID)
            ?? SubmittedIntentOutboxDocument(sessionID: sessionID)
    }

    @discardableResult
    public static func upsert(_ entry: SubmittedIntentOutboxEntry,
                              sessionDirectoryURL: URL,
                              sessionID: SessionID) throws -> SubmittedIntentOutboxEntry {
        try validate(entry)
        let url = fileURL(sessionDirectoryURL: sessionDirectoryURL)
        let lock = try SubmittedIntentOutboxFileLock.acquire(at: lockURL(for: url))
        defer { lock.release() }

        var document = try loadUnlocked(from: url, sessionID: sessionID)
            ?? SubmittedIntentOutboxDocument(sessionID: sessionID)
        if let existing = document.entries.first(where: {
            $0.submissionID == entry.submissionID
        }) {
            guard existing.payload == entry.payload else {
                throw SubmittedIntentStoreError.payloadConflict(entry.submissionID)
            }
            let merged = SubmittedIntentOutboxEntry(
                submissionID: existing.submissionID,
                payload: existing.payload,
                createdAt: existing.createdAt,
                lastCanonicalError: entry.lastCanonicalError ?? existing.lastCanonicalError)
            var entries = document.entries
            let index = entries.firstIndex(where: {
                $0.submissionID == entry.submissionID
            })!
            entries[index] = merged
            document = SubmittedIntentOutboxDocument(
                sessionID: sessionID,
                entries: entries)
            let saved = try saveUnlocked(document, to: url)
            return saved.entries[indexOf: entry.submissionID]!
        }

        document = SubmittedIntentOutboxDocument(
            sessionID: sessionID,
            entries: document.entries + [entry])
        let saved = try saveUnlocked(document, to: url)
        return saved.entries[indexOf: entry.submissionID]!
    }

    @discardableResult
    public static func remove(id: SubmissionID,
                              sessionDirectoryURL: URL,
                              sessionID: SessionID) throws -> SubmittedIntentOutboxDocument {
        let url = fileURL(sessionDirectoryURL: sessionDirectoryURL)
        let lock = try SubmittedIntentOutboxFileLock.acquire(at: lockURL(for: url))
        defer { lock.release() }
        guard let current = try loadUnlocked(from: url, sessionID: sessionID) else {
            return SubmittedIntentOutboxDocument(sessionID: sessionID)
        }
        let remaining = current.entries.filter { $0.submissionID != id }
        guard remaining.count != current.entries.count else { return current }
        if remaining.isEmpty {
            try removeFileUnlocked(at: url)
            return SubmittedIntentOutboxDocument(sessionID: sessionID)
        }
        return try saveUnlocked(
            SubmittedIntentOutboxDocument(sessionID: sessionID, entries: remaining),
            to: url)
    }

    fileprivate static func validate(_ entry: SubmittedIntentOutboxEntry) throws {
        guard let payloadID = entry.payload.submissionID else {
            throw SubmittedIntentStoreError.missingSubmissionID
        }
        guard payloadID == entry.submissionID else {
            throw SubmittedIntentStoreError.submissionIDMismatch
        }
        guard !entry.submissionID.rawValue.isEmpty else {
            throw SubmittedIntentStoreError.invalidSubmissionID
        }
        guard entry.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw SubmittedIntentStoreError.invalidCreatedAt
        }
        if let error = entry.lastCanonicalError {
            guard !error.isEmpty,
                  error.count <= maximumErrorCharacters,
                  error.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw SubmittedIntentStoreError.invalidCanonicalError
            }
        }
    }

    private static func validate(_ document: SubmittedIntentOutboxDocument,
                                 expectedSession: SessionID) throws {
        guard document.schemaVersion == SubmittedIntentOutboxDocument.currentSchemaVersion else {
            throw SubmittedIntentStoreError.unsupportedSchemaVersion
        }
        guard document.sessionID == expectedSession else {
            throw SubmittedIntentStoreError.sessionMismatch
        }
        var identities: Set<SubmissionID> = []
        for entry in document.entries {
            try validate(entry)
            guard identities.insert(entry.submissionID).inserted else {
                throw SubmittedIntentStoreError.duplicateSubmissionID(entry.submissionID)
            }
        }
    }

    private static func lockURL(for fileURL: URL) -> URL {
        fileURL.appendingPathExtension("lock")
    }

    private static func loadUnlocked(
        from url: URL,
        sessionID: SessionID
    ) throws -> SubmittedIntentOutboxDocument? {
        guard let data = try readOwnerOnlyFile(at: url) else { return nil }
        let document: SubmittedIntentOutboxDocument
        do {
            document = try makeDecoder().decode(SubmittedIntentOutboxDocument.self, from: data)
        } catch {
            throw SubmittedIntentStoreError.storageUnavailable
        }
        try validate(document, expectedSession: sessionID)
        return normalized(document)
    }

    private static func saveUnlocked(
        _ document: SubmittedIntentOutboxDocument,
        to url: URL
    ) throws -> SubmittedIntentOutboxDocument {
        try validate(document, expectedSession: document.sessionID)
        let canonical = normalized(document)
        let data: Data
        do {
            data = try makeEncoder().encode(canonical)
        } catch {
            throw SubmittedIntentStoreError.storageUnavailable
        }
        try writeOwnerOnlyAtomically(data, to: url)
        guard let verified = try loadUnlocked(from: url, sessionID: canonical.sessionID),
              let verifiedData = try? makeEncoder().encode(verified),
              verifiedData == data else {
            throw SubmittedIntentStoreError.verificationFailed
        }
        return verified
    }

    private static func normalized(
        _ document: SubmittedIntentOutboxDocument
    ) -> SubmittedIntentOutboxDocument {
        SubmittedIntentOutboxDocument(
            sessionID: document.sessionID,
            entries: document.entries.sorted {
                $0.submissionID.rawValue < $1.submissionID.rawValue
            })
    }

    private static func readOwnerOnlyFile(at url: URL) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw SubmittedIntentStoreError.unsafeFile
        }
        defer { _ = close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & mode_t(0o777) == mode_t(S_IRUSR | S_IWUSR) else {
            throw SubmittedIntentStoreError.unsafeFile
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count: Int
            #if canImport(Darwin)
            count = Darwin.read(descriptor, &buffer, buffer.count)
            #elseif canImport(Glibc)
            count = Glibc.read(descriptor, &buffer, buffer.count)
            #elseif canImport(Musl)
            count = Musl.read(descriptor, &buffer, buffer.count)
            #else
            count = -1
            #endif
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw SubmittedIntentStoreError.storageUnavailable
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private static func writeOwnerOnlyAtomically(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(
            ".submitted-intent-outbox-\(UUID().uuidString).tmp")
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw SubmittedIntentStoreError.storageUnavailable
        }
        var shouldRemoveTemporary = true
        defer {
            _ = close(descriptor)
            if shouldRemoveTemporary { _ = unlink(temporary.path) }
        }

        var temporaryStatus = stat()
        guard fstat(descriptor, &temporaryStatus) == 0,
              temporaryStatus.st_uid == geteuid(),
              temporaryStatus.st_nlink == 1,
              temporaryStatus.st_mode & S_IFMT == S_IFREG,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw SubmittedIntentStoreError.storageUnavailable
        }

        let wroteAll = data.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < rawBuffer.count {
                let count: Int
                #if canImport(Darwin)
                count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset)
                #elseif canImport(Glibc)
                count = Glibc.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset)
                #elseif canImport(Musl)
                count = Musl.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset)
                #else
                count = -1
                #endif
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wroteAll,
              fsync(descriptor) == 0,
              rename(temporary.path, url.path) == 0 else {
            throw SubmittedIntentStoreError.storageUnavailable
        }
        shouldRemoveTemporary = false
        try synchronizeParentDirectory(parent)
    }

    private static func removeFileUnlocked(at url: URL) throws {
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw SubmittedIntentStoreError.storageUnavailable
        }
        try synchronizeParentDirectory(url.deletingLastPathComponent())
        var status = stat()
        guard lstat(url.path, &status) != 0, errno == ENOENT else {
            throw SubmittedIntentStoreError.verificationFailed
        }
    }

    private static func synchronizeParentDirectory(_ parent: URL) throws {
        let descriptor = open(parent.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SubmittedIntentStoreError.storageUnavailable
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw SubmittedIntentStoreError.storageUnavailable
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension Array where Element == SubmittedIntentOutboxEntry {
    subscript(indexOf id: SubmissionID) -> SubmittedIntentOutboxEntry? {
        first { $0.submissionID == id }
    }
}

public enum SubmittedIntentAcceptance: Equatable, Sendable {
    case canonical(SubmittedIntentOutboxEntry, cleanupWarning: String?)
    case outbox(SubmittedIntentOutboxEntry, error: String)
}

/// Host-side retry action for one canonical submitted intent. Task attempts
/// recovered by the Orchestrator are authoritative: resuming an exact queued
/// task is not a new whole-submission retry.
public enum SubmittedIntentRetryPlan: Equatable, Sendable {
    case completed(attempt: Int)
    case resumeRestoredTask(attempt: Int, appendsQueuedStatus: Bool)
    case retryTerminalTask(attempt: Int)
    case retrySubmissionWithoutTask(attempt: Int)
    case reject
}

public enum SubmittedIntentRetryPlanner {
    public static func plan(
        currentAttempt: Int,
        task: CoworkTaskView?,
        isRestoredSubmission: Bool
    ) -> SubmittedIntentRetryPlan {
        let currentAttempt = max(1, currentAttempt)
        guard let task else {
            guard currentAttempt < Int.max else { return .reject }
            return .retrySubmissionWithoutTask(attempt: currentAttempt + 1)
        }

        switch task.status {
        case .completed:
            return .completed(attempt: currentAttempt)
        case .queued:
            guard isRestoredSubmission else { return .reject }
            if task.attempt == currentAttempt {
                return .resumeRestoredTask(
                    attempt: currentAttempt,
                    appendsQueuedStatus: false)
            }
            if currentAttempt < Int.max,
               task.attempt == currentAttempt + 1 {
                return .resumeRestoredTask(
                    attempt: task.attempt,
                    appendsQueuedStatus: true)
            }
            return .reject
        case .failed, .cancelled:
            guard task.attempt == currentAttempt,
                  currentAttempt < Int.max else { return .reject }
            return .retryTerminalTask(attempt: currentAttempt + 1)
        case .created, .assigned, .running:
            return .reject
        }
    }
}

/// Coordinates the local fallback with canonical EventLog admission. It never
/// starts remote execution: callers may do so only after receiving `.canonical`.
public actor SubmittedIntentStore {
    private static let canonicalWriteFailure =
        "The submission is saved locally but could not be added to the session event log."
    private static let cleanupFailure =
        "The submission is canonical, but its redundant local outbox copy could not be removed."

    private let log: EventLog
    private let sessionDirectoryURL: URL

    public init(log: EventLog) {
        self.log = log
        self.sessionDirectoryURL = log.sessionDirectoryURL
    }

    public func accept(
        payload: UserMessagePayload,
        createdAt: Date = Date()
    ) async throws -> SubmittedIntentAcceptance {
        let sessionID = await log.sessionID
        let candidate = try SubmittedIntentOutboxEntry(
            payload: payload,
            createdAt: createdAt)
        let persisted = try SubmittedIntentOutboxStore.upsert(
            candidate,
            sessionDirectoryURL: sessionDirectoryURL,
            sessionID: sessionID)
        return try await canonicalize(persisted, sessionID: sessionID)
    }

    public func retryOutbox(id: SubmissionID) async throws -> SubmittedIntentAcceptance {
        let sessionID = await log.sessionID
        let document = try SubmittedIntentOutboxStore.load(
            sessionDirectoryURL: sessionDirectoryURL,
            sessionID: sessionID)
        guard let entry = document.entries[indexOf: id] else {
            throw SubmittedIntentStoreError.entryNotFound(id)
        }
        return try await canonicalize(entry, sessionID: sessionID)
    }

    /// Returns only non-canonical fallback entries. A stale redundant entry
    /// left by cleanup failure is hidden once its exact payload is confirmed in
    /// EventLog, and its physical removal is retried best-effort.
    public func loadOutbox() async throws -> SubmittedIntentOutboxDocument {
        let sessionID = await log.sessionID
        let raw = try SubmittedIntentOutboxStore.load(
            sessionDirectoryURL: sessionDirectoryURL,
            sessionID: sessionID)
        guard !raw.entries.isEmpty else { return raw }

        let history: [Envelope]
        do {
            history = try await log.replayChecked()
        } catch {
            // EventLog uncertainty must not hide the only visible local copy.
            return raw
        }
        let canonical = try Self.canonicalPayloads(from: history)
        var visible: [SubmittedIntentOutboxEntry] = []
        for entry in raw.entries {
            guard let payload = canonical[entry.submissionID] else {
                visible.append(entry)
                continue
            }
            guard payload == entry.payload else {
                throw SubmittedIntentStoreError.payloadConflict(entry.submissionID)
            }
            _ = try? SubmittedIntentOutboxStore.remove(
                id: entry.submissionID,
                sessionDirectoryURL: sessionDirectoryURL,
                sessionID: sessionID)
        }
        return SubmittedIntentOutboxDocument(sessionID: sessionID, entries: visible)
    }

    /// Appends a lifecycle state only for a canonically admitted submission.
    /// Exact duplicate status writes are idempotent across processes.
    @discardableResult
    public func appendStatus(
        _ payload: SubmissionStatusChangedPayload,
        ts: Date = Date()
    ) async throws -> Envelope? {
        guard payload.attempt > 0 else {
            throw SubmittedIntentStoreError.invalidAttempt
        }
        let envelopes = try await log.appendSessionStateTransaction(ts: ts) { history in
            let users = history.compactMap { envelope -> UserMessagePayload? in
                guard case .userMessage(let user) = envelope.event,
                      user.submissionID == payload.submissionID else { return nil }
                return user
            }
            guard users.count == 1 else {
                throw SubmittedIntentStoreError.canonicalHistoryConflict(payload.submissionID)
            }
            let statuses = history.compactMap { envelope -> SubmissionStatusChangedPayload? in
                guard case .submissionStatusChanged(let status) = envelope.event,
                      status.submissionID == payload.submissionID else { return nil }
                return status
            }
            var currentStatus: SubmissionStatus?
            var currentAttempt: Int?
            for status in statuses {
                guard SubmissionStatusFold.accepts(
                    currentStatus: currentStatus,
                    currentAttempt: currentAttempt,
                    next: status) else {
                    throw SubmittedIntentStoreError.canonicalHistoryConflict(
                        payload.submissionID)
                }
                currentStatus = status.status
                currentAttempt = status.attempt
            }
            if statuses.contains(payload) { return [] }
            if statuses.contains(where: {
                $0.attempt == payload.attempt && $0.status == payload.status
            }) {
                throw SubmittedIntentStoreError.canonicalHistoryConflict(payload.submissionID)
            }
            guard SubmissionStatusFold.accepts(
                currentStatus: currentStatus,
                currentAttempt: currentAttempt,
                next: payload) else {
                throw SubmittedIntentStoreError.invalidStatusTransition(
                    payload.submissionID)
            }
            return [.submissionStatusChanged(payload)]
        }
        return envelopes.first
    }

    private func canonicalize(
        _ entry: SubmittedIntentOutboxEntry,
        sessionID: SessionID
    ) async throws -> SubmittedIntentAcceptance {
        do {
            _ = try await log.appendSessionStateTransaction(ts: entry.createdAt) { history in
                let users = history.compactMap { envelope -> UserMessagePayload? in
                    guard case .userMessage(let payload) = envelope.event,
                          payload.submissionID == entry.submissionID else { return nil }
                    return payload
                }
                guard users.count <= 1 else {
                    throw SubmittedIntentStoreError.canonicalHistoryConflict(entry.submissionID)
                }
                if let existing = users.first, existing != entry.payload {
                    throw SubmittedIntentStoreError.payloadConflict(entry.submissionID)
                }
                let hasStatus = history.contains { envelope in
                    guard case .submissionStatusChanged(let status) = envelope.event else {
                        return false
                    }
                    return status.submissionID == entry.submissionID
                }
                if users.isEmpty {
                    guard !hasStatus else {
                        throw SubmittedIntentStoreError.canonicalHistoryConflict(entry.submissionID)
                    }
                    return [
                        .userMessage(entry.payload),
                        .submissionStatusChanged(SubmissionStatusChangedPayload(
                            submissionID: entry.submissionID,
                            status: .queued,
                            attempt: 1)),
                    ]
                }
                if !hasStatus {
                    return [.submissionStatusChanged(SubmissionStatusChangedPayload(
                        submissionID: entry.submissionID,
                        status: .queued,
                        attempt: 1))]
                }
                return []
            }
        } catch let error as SubmittedIntentStoreError {
            switch error {
            case .payloadConflict, .canonicalHistoryConflict:
                throw error
            default:
                return try failedCanonicalization(entry, sessionID: sessionID)
            }
        } catch {
            return try failedCanonicalization(entry, sessionID: sessionID)
        }

        do {
            _ = try SubmittedIntentOutboxStore.remove(
                id: entry.submissionID,
                sessionDirectoryURL: sessionDirectoryURL,
                sessionID: sessionID)
            return .canonical(entry, cleanupWarning: nil)
        } catch {
            return .canonical(entry, cleanupWarning: Self.cleanupFailure)
        }
    }

    private func failedCanonicalization(
        _ entry: SubmittedIntentOutboxEntry,
        sessionID: SessionID
    ) throws -> SubmittedIntentAcceptance {
        let failed = try SubmittedIntentOutboxEntry(
            payload: entry.payload,
            createdAt: entry.createdAt,
            lastCanonicalError: Self.canonicalWriteFailure)
        let persisted = try SubmittedIntentOutboxStore.upsert(
            failed,
            sessionDirectoryURL: sessionDirectoryURL,
            sessionID: sessionID)
        return .outbox(persisted, error: Self.canonicalWriteFailure)
    }

    private static func canonicalPayloads(
        from history: [Envelope]
    ) throws -> [SubmissionID: UserMessagePayload] {
        var result: [SubmissionID: UserMessagePayload] = [:]
        for envelope in history {
            guard case .userMessage(let payload) = envelope.event,
                  let submissionID = payload.submissionID else { continue }
            if let existing = result[submissionID], existing != payload {
                throw SubmittedIntentStoreError.payloadConflict(submissionID)
            }
            result[submissionID] = payload
        }
        return result
    }
}
