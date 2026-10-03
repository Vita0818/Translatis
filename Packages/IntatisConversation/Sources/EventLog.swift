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

/// Failures raised by the event-log coordination layer. Messages deliberately
/// omit the backing file URL because session paths can contain private user or
/// workspace information.
public enum EventLogError: Error, Equatable, LocalizedError, Sendable {
    case lockUnavailable(code: Int32)
    case lockTimedOut
    case writerAlreadyActive
    case storageUnavailable(operation: String, code: Int)
    case journalCorrupted
    case journalMismatch
    case sessionMismatch
    case corruptedEvent(line: Int)
    case nonMonotonicSequence(previous: Int, current: Int)
    case sequenceRegressed(expectedAtLeast: Int, found: Int)
    case sequenceExhausted
    case unsupportedEventTypes
    case incompleteEventHistory
    case staleModelHistory(
        expectedLatestAgentHistorySeq: Int?,
        actualLatestAgentHistorySeq: Int?)
    case invalidModelHistoryWindowLineage
    case reusedModelHistoryWindowID
    case modelHistoryCompactionRequiresValidatedAppend
    case invalidModelHistoryMediaBatch
    case permissionRequestNotFound
    case conflictingPermissionRequest
    case conflictingPermissionSettlement
    case conflictingContinuationRunCloseClaim

    public var errorDescription: String? {
        switch self {
        case .lockUnavailable(let code):
            return "The session event log lock could not be opened (error code \(code))."
        case .lockTimedOut:
            return "The session event log is busy in another \(IntatisHostApplication.identity.name) operation."
        case .writerAlreadyActive:
            return "Another \(IntatisHostApplication.identity.name) runtime is already writing this session."
        case .storageUnavailable(let operation, let code):
            return "The session event log could not \(operation) (error code \(code))."
        case .journalCorrupted:
            return "The session event log recovery journal is corrupted."
        case .journalMismatch:
            return "The session event log no longer matches its recovery journal."
        case .sessionMismatch:
            return "The session event log contains an event for another session."
        case .corruptedEvent(let line):
            return "The session event log contains a corrupted event at line \(line)."
        case .nonMonotonicSequence(let previous, let current):
            return "The session event log has non-monotonic sequence numbers (\(previous), \(current))."
        case .sequenceRegressed(let expectedAtLeast, let found):
            return "The session event log was replaced or truncated (expected sequence \(expectedAtLeast) or later, found \(found))."
        case .sequenceExhausted:
            return "The session event log sequence space is exhausted."
        case .unsupportedEventTypes:
            return "The session contains newer event types that this \(IntatisHostApplication.identity.name) version cannot update safely."
        case .incompleteEventHistory:
            return "The session event history is incomplete and cannot be updated safely."
        case .staleModelHistory(
            let expectedLatestAgentHistorySeq,
            let actualLatestAgentHistorySeq):
            let expected = expectedLatestAgentHistorySeq.map(String.init)
                ?? "none"
            let actual = actualLatestAgentHistorySeq.map(String.init)
                ?? "none"
            return "The agent model history changed before its compaction checkpoint could be persisted (expected \(expected), found \(actual))."
        case .invalidModelHistoryWindowLineage:
            return "The model history compaction window does not continue the agent's canonical checkpoint chain."
        case .reusedModelHistoryWindowID:
            return "The model history compaction reuses a window identifier from the agent's canonical checkpoint chain."
        case .modelHistoryCompactionRequiresValidatedAppend:
            return "Model history compaction checkpoints require the validated compare-and-append operation."
        case .invalidModelHistoryMediaBatch:
            return "A model history image output is not bound to one exact tool result and execution settlement in the same event batch."
        case .permissionRequestNotFound:
            return "The permission request is not durably registered in this session."
        case .conflictingPermissionRequest:
            return "The session contains conflicting records for the same permission request."
        case .conflictingPermissionSettlement:
            return "The permission request already has a different terminal response."
        case .conflictingContinuationRunCloseClaim:
            return "The continuation run contains conflicting durable close claims."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .lockUnavailable, .storageUnavailable:
            return "Check storage permissions and available disk space, then retry."
        case .lockTimedOut:
            return "Wait for the other operation to finish, or close the other \(IntatisHostApplication.identity.name) process using this session, then retry."
        case .writerAlreadyActive:
            return "Close the other Code or Cowork runtime for this session, then retry. Read-only replay can remain open."
        case .journalCorrupted, .journalMismatch, .sessionMismatch, .corruptedEvent,
             .nonMonotonicSequence, .sequenceRegressed:
            return "Stop writing to this session and inspect or restore its event log before retrying."
        case .sequenceExhausted:
            return "Start a new session."
        case .unsupportedEventTypes:
            return "Open this session with a compatible newer \(IntatisHostApplication.identity.name) version before changing its settings."
        case .staleModelHistory:
            return "Reload the agent's canonical model history, rebuild the replacement checkpoint, and retry."
        case .invalidModelHistoryWindowLineage,
             .reusedModelHistoryWindowID:
            return "Reload the agent's canonical checkpoint chain, create the next unique window, and retry."
        case .modelHistoryCompactionRequiresValidatedAppend:
            return "Use the model-history compaction append operation so revision and window lineage are checked atomically."
        case .invalidModelHistoryMediaBatch:
            return "Rebuild the tool completion batch from one canonical structured result, then retry."
        case .incompleteEventHistory:
            return "Stop writing to this session and inspect or restore its canonical event log before retrying."
        case .permissionRequestNotFound,
             .conflictingPermissionRequest, .conflictingPermissionSettlement:
            return "Reload the session from its canonical event log and inspect the permission history before retrying."
        case .conflictingContinuationRunCloseClaim:
            return "Reload the session from its canonical event log and inspect the continuation-run close history before retrying."
        }
    }
}

/// The stable envelope fields needed to reserve sequence numbers even when an
/// older binary cannot decode a future event `type` or payload schema.
private struct EnvelopeSequenceHeader: Decodable {
    let seq: Int
    let ts: Date
    let session: SessionID
    let v: Int
    let type: String
}

private struct EventLogSequenceState {
    let nextSeq: Int
    let needsSeparator: Bool
}

/// Durable intent for one multi-event append. The journal is promoted from a
/// synchronized temporary file before the JSONL is touched. Recovery can then
/// distinguish an untouched/partial batch (truncate to `originalOffset`) from
/// a fully persisted batch (keep it) without changing the Envelope wire shape.
/// Internal visibility exists only so crash-boundary tests can construct the
/// exact on-disk state a terminated process would leave behind.
struct EventLogWriteAheadJournal: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let prefixLimit = 4 * 1_024

    let formatVersion: Int
    let session: SessionID
    let originalOffset: UInt64
    let prefixStartOffset: UInt64
    let prefixBytes: Data
    let batchBytes: Data
    let firstSequence: Int
    let eventCount: Int
    let prefixChecksum: String
    let batchChecksum: String

    init(session: SessionID,
         originalOffset: UInt64,
         prefixStartOffset: UInt64,
         prefixBytes: Data,
         batchBytes: Data,
         firstSequence: Int,
         eventCount: Int) {
        self.formatVersion = Self.currentVersion
        self.session = session
        self.originalOffset = originalOffset
        self.prefixStartOffset = prefixStartOffset
        self.prefixBytes = prefixBytes
        self.batchBytes = batchBytes
        self.firstSequence = firstSequence
        self.eventCount = eventCount
        self.prefixChecksum = Self.checksum(prefixBytes)
        self.batchChecksum = Self.checksum(batchBytes)
    }

    func validate(expectedSession: SessionID, decoder: JSONDecoder) throws {
        guard formatVersion == Self.currentVersion,
              session == expectedSession,
              eventCount > 0,
              prefixBytes.count <= Self.prefixLimit,
              UInt64(prefixBytes.count) <= originalOffset,
              prefixStartOffset == originalOffset - UInt64(prefixBytes.count),
              prefixChecksum == Self.checksum(prefixBytes),
              batchChecksum == Self.checksum(batchBytes),
              !batchBytes.isEmpty,
              batchBytes.last == 0x0A else {
            throw EventLogError.journalCorrupted
        }

        let expectsSeparator = originalOffset > 0 && prefixBytes.last != 0x0A
        let hasSeparator = batchBytes.first == 0x0A
        guard expectsSeparator == hasSeparator else {
            throw EventLogError.journalCorrupted
        }

        let body = hasSeparator ? batchBytes.dropFirst() : batchBytes[...]
        let lines = body.split(separator: 0x0A, omittingEmptySubsequences: false)
        guard lines.count == eventCount + 1,
              lines.last?.isEmpty == true,
              lines.dropLast().allSatisfy({ !$0.isEmpty }) else {
            throw EventLogError.journalCorrupted
        }

        for (offset, line) in lines.dropLast().enumerated() {
            let header: EnvelopeSequenceHeader
            do {
                header = try decoder.decode(EnvelopeSequenceHeader.self, from: Data(line))
            } catch {
                throw EventLogError.journalCorrupted
            }
            let (expectedSequence, overflow) = firstSequence.addingReportingOverflow(offset)
            guard !overflow,
                  header.seq == expectedSequence,
                  header.session == expectedSession else {
                throw EventLogError.journalCorrupted
            }
        }
    }

    /// FNV-1a is used as an on-disk damage detector, not as an authentication
    /// primitive. Exact prefix/suffix byte comparison supplies the recovery
    /// decision; this checksum ensures a damaged but still-decodable journal
    /// itself fails closed before that comparison.
    private static func checksum(_ data: Data) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return String(format: "%016llx", value)
    }
}

private struct EventLogFileSnapshot {
    let offset: UInt64
    let prefixStartOffset: UInt64
    let prefixBytes: Data
}

private struct EventLogCheckedScan {
    let envelopes: [Envelope]
    let containsEnvelopeHeader: Bool
    let containsUnknownEventTypes: Bool
    let nextSeq: Int
}

/// Strict replay metadata used only by rebuildable derived projections. Unlike
/// ordinary `replayChecked`, this also exposes the highest durable header and
/// whether a newer binary wrote an event type this binary cannot project.
public struct EventLogProjectionReplay: Equatable, Sendable {
    public let envelopes: [Envelope]
    public let lastDurableSeq: Int?
    public let containsUnknownEventTypes: Bool

    public init(envelopes: [Envelope],
                lastDurableSeq: Int?,
                containsUnknownEventTypes: Bool) {
        self.envelopes = envelopes
        self.lastDurableSeq = lastDurableSeq
        self.containsUnknownEventTypes = containsUnknownEventTypes
    }

    /// Whether this binary has a complete, gap-free projection of every
    /// durable event from sequence zero through the current tail. Unknown
    /// future types and sequence gaps both invalidate absence/order proofs.
    public var hasCompleteKnownHistory: Bool {
        guard !containsUnknownEventTypes else { return false }
        guard let lastDurableSeq else { return envelopes.isEmpty }
        guard lastDurableSeq >= 0 else { return false }
        let (expectedCount, overflow) = lastDurableSeq.addingReportingOverflow(1)
        guard !overflow,
              envelopes.count == expectedCount else { return false }
        return envelopes.enumerated().allSatisfy { offset, envelope in
            envelope.seq == offset
        }
    }
}

/// Result of the RequestID-scoped permission settlement compare-and-append.
/// `didAppend == false` is an idempotent replay of the exact first terminal
/// response; the returned envelope is always the canonical durable winner.
public struct PermissionSettlementAppendResult: Equatable, Sendable {
    public let envelope: Envelope
    public let resolution: PermissionResolvedPayload
    public let didAppend: Bool

    public init(envelope: Envelope,
                resolution: PermissionResolvedPayload,
                didAppend: Bool) {
        self.envelope = envelope
        self.resolution = resolution
        self.didAppend = didAppend
    }
}

public struct PermissionRequestRegistrationResult: Equatable, Sendable {
    public let envelope: Envelope
    public let request: PermissionRequestPayload
    public let didAppend: Bool

    public init(envelope: Envelope,
                request: PermissionRequestPayload,
                didAppend: Bool) {
        self.envelope = envelope
        self.request = request
        self.didAppend = didAppend
    }
}

/// Result of the ContinuationRunID-scoped first-write close claim. A caller
/// that loses a race receives the canonical first claim with `matchesRequest`
/// false and must honor that winner rather than appending another outcome.
public struct ContinuationRunCloseClaimResult: Equatable, Sendable {
    public let envelope: Envelope
    public let claim: ContinuationRunCloseRequestedPayload
    public let didAppend: Bool
    public let matchesRequest: Bool

    public init(envelope: Envelope,
                claim: ContinuationRunCloseRequestedPayload,
                didAppend: Bool,
                matchesRequest: Bool) {
        self.envelope = envelope
        self.claim = claim
        self.didAppend = didAppend
        self.matchesRequest = matchesRequest
    }
}

private enum EventLogJournalState {
    case untouched
    case partial
    case complete
}

/// Advisory lock shared by every EventLog instance that targets the same
/// canonical JSONL path. The descriptor is always close-on-exec and is held
/// only for the read or append critical section, so a process crash releases
/// it automatically. Readers use a shared lock; appenders use an exclusive
/// lock and re-read sequence state while holding it.
fileprivate final class EventLogFileLock {
    enum Mode {
        case shared
        case exclusive
    }

    private static let retryCount = 400
    private static let retryInterval: TimeInterval = 0.005

    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(at url: URL,
                        mode: Mode,
                        contentionError: EventLogError = .lockTimedOut,
                        maxRetries: Int = retryCount) throws -> EventLogFileLock {
        let descriptor = openLockFile(at: url)
        guard descriptor >= 0 else {
            throw EventLogError.lockUnavailable(code: currentErrno())
        }

        let operation: Int32
        switch mode {
        case .shared:
            operation = LOCK_SH | LOCK_NB
        case .exclusive:
            operation = LOCK_EX | LOCK_NB
        }
        for attempt in 0...maxRetries {
            if applyLock(descriptor, operation: operation) == 0 {
                return EventLogFileLock(descriptor: descriptor)
            }

            let code = currentErrno()
            guard code == EWOULDBLOCK || code == EAGAIN else {
                closeFile(descriptor)
                throw EventLogError.lockUnavailable(code: code)
            }
            guard attempt < maxRetries else {
                closeFile(descriptor)
                throw contentionError
            }
            Thread.sleep(forTimeInterval: retryInterval)
        }

        closeFile(descriptor)
        throw contentionError
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = Self.applyLock(descriptor, operation: LOCK_UN)
        Self.closeFile(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }

    private static func openLockFile(at url: URL) -> Int32 {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            let flags = O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW
#if canImport(Darwin)
            return Darwin.open(path, flags, mode_t(S_IRUSR | S_IWUSR))
#elseif canImport(Glibc)
            return Glibc.open(path, flags, mode_t(S_IRUSR | S_IWUSR))
#elseif canImport(Musl)
            return Musl.open(path, flags, mode_t(S_IRUSR | S_IWUSR))
#else
            return -1
#endif
        }
    }

    private static func applyLock(_ descriptor: Int32, operation: Int32) -> Int32 {
#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        return flock(descriptor, operation)
#else
        return -1
#endif
    }

    private static func closeFile(_ descriptor: Int32) {
#if canImport(Darwin)
        _ = Darwin.close(descriptor)
#elseif canImport(Glibc)
        _ = Glibc.close(descriptor)
#elseif canImport(Musl)
        _ = Musl.close(descriptor)
#endif
    }

    private static func currentErrno() -> Int32 {
#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        return errno
#else
        return -1
#endif
    }
}

/// Optional long-lived lease for runtimes that execute tasks from an EventLog.
/// EventLog itself does not acquire this lease at initialization, so history
/// and read-only projections may coexist. A Code/Cowork runtime keeps the
/// returned object alive for its whole execution lifetime; a second runtime
/// targeting the same log receives `writerAlreadyActive`. Releasing the object
/// or terminating the process closes the descriptor and frees the lease.
public final class EventLogWriterLease: @unchecked Sendable {
    private let stateLock = NSLock()
    private var fileLock: EventLogFileLock?

    fileprivate init(fileLock: EventLogFileLock) {
        self.fileLock = fileLock
    }

    public func release() {
        stateLock.lock()
        let lock = fileLock
        fileLock = nil
        stateLock.unlock()
        lock?.release()
    }

    deinit {
        release()
    }
}

/// Append-only, per-session event log persisted as JSONL (one `Envelope` per
/// line). This is the single source of truth (ARCHITECTURE.md §1.2 principle A):
/// `append` is the only mutation; `replay`/`stream` are projections; `resume`
/// is just "read from a `seq`". The actor serializes one instance, while a
/// cross-process file lock serializes all instances targeting the same file.
public actor EventLog {
    static let journaledSingleEventByteThreshold = 64 * 1_024

    static func shouldJournalWrite(
        eventCount: Int,
        byteCount: Int
    ) -> Bool {
        eventCount > 1
            || byteCount >= journaledSingleEventByteThreshold
    }

    private let session: SessionID
    private let fileURL: URL
    public nonisolated let sessionDirectoryURL: URL
    /// Package-internal identity for process-wide coordination registries.
    /// It may contain a private filesystem path and must never be logged or
    /// surfaced to models/UI.
    package nonisolated let coordinationKey: String
    private let lockURL: URL
    private let writerLockURL: URL
    private let journalURL: URL
    private let journalTemporaryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var nextSeq: Int
    private var subscribers: [UUID: AsyncStream<Envelope>.Continuation] = [:]

    public init(session: SessionID, fileURL: URL) throws {
        self.session = session
        let canonicalFileURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        self.fileURL = canonicalFileURL
        self.sessionDirectoryURL = canonicalFileURL.deletingLastPathComponent()
        self.coordinationKey = canonicalFileURL.path
        self.lockURL = canonicalFileURL.appendingPathExtension("lock")
        self.writerLockURL = canonicalFileURL.appendingPathExtension("writer.lock")
        self.journalURL = canonicalFileURL.appendingPathExtension("wal")
        self.journalTemporaryURL = canonicalFileURL.appendingPathExtension("wal.tmp")
        self.encoder = Envelope.makeEncoder()
        self.decoder = Envelope.makeDecoder()

        do {
            try FileManager.default.createDirectory(
                at: canonicalFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        } catch {
            throw Self.storageError(operation: "initialize its directory", error: error)
        }

        // Initialization is a recovery boundary. Recovery can truncate only a
        // crash-left partial batch, so it holds the same exclusive lock as an
        // appender before inspecting sequence state.
        let lock = try EventLogFileLock.acquire(at: lockURL, mode: .exclusive)
        defer { lock.release() }
        try Self.recoverJournalIfNeeded(
            fileURL: canonicalFileURL,
            journalURL: journalURL,
            temporaryURL: journalTemporaryURL,
            session: session,
            decoder: Envelope.makeDecoder())
        self.nextSeq = try Self.sequenceState(
            at: canonicalFileURL,
            expectedSession: session,
            decoder: Envelope.makeDecoder()).nextSeq
    }

    public var sessionID: SessionID { session }

    /// Acquires an optional process-lifetime writer lease for a task-executing
    /// runtime. Ordinary append calls remain independently protected so Chat
    /// and migration callers do not need to hold this lease.
    public nonisolated func acquireWriterLease() throws -> EventLogWriterLease {
        let lock = try EventLogFileLock.acquire(
            at: writerLockURL,
            mode: .exclusive,
            contentionError: .writerAlreadyActive,
            maxRetries: 0)
        return EventLogWriterLease(fileLock: lock)
    }

    /// Append an event. Returns the persisted envelope (with its assigned seq).
    @discardableResult
    public func append(_ event: Event, ts: Date = Date()) throws -> Envelope {
        guard let envelope = try append([event], ts: ts).first else {
            preconditionFailure("a single-event append must produce one envelope")
        }
        return envelope
    }

    /// Appends a contiguous group of events while holding one cross-process
    /// exclusive lock. The group is encoded before any JSONL bytes are written;
    /// multi-event groups first persist a recovery journal, then synchronize
    /// the JSONL batch. Local sequence state and live subscribers advance only
    /// after the durable write succeeds.
    @discardableResult
    public func append(_ events: [Event], ts: Date = Date()) throws -> [Envelope] {
        guard !events.isEmpty else { return [] }

        let lock = try EventLogFileLock.acquire(at: lockURL, mode: .exclusive)
        defer { lock.release() }

        // A previous process may have terminated after promoting its journal.
        // Resolve it before allocating any new sequence numbers.
        try Self.recoverJournalIfNeeded(
            fileURL: fileURL,
            journalURL: journalURL,
            temporaryURL: journalTemporaryURL,
            session: session,
            decoder: decoder)

        // Re-read the persisted tail while holding the cross-process lock.
        // This is the sequence CAS: a stale EventLog instance must observe
        // appends made by another instance before assigning its own range.
        let state = try Self.tailSequenceState(
            at: fileURL,
            expectedSession: session,
            decoder: decoder)
        guard state.nextSeq >= nextSeq else {
            throw EventLogError.sequenceRegressed(
                expectedAtLeast: nextSeq,
                found: state.nextSeq)
        }

        return try persistLocked(events, ts: ts, state: state)
    }

    /// Internal compare-and-append primitive for versioned session metadata.
    /// The builder sees the strictly decoded canonical history while the same
    /// cross-process lock that assigns sequence numbers is held. This prevents
    /// two EventLog instances from deriving and appending the same settings
    /// revision, while keeping the public EventLog schema append-only.
    public func appendSessionStateTransaction(
        ts: Date = Date(),
        _ buildEvents: @Sendable ([Envelope]) throws -> [Event]
    ) throws -> [Envelope] {
        let lock = try EventLogFileLock.acquire(at: lockURL, mode: .exclusive)
        defer { lock.release() }

        try Self.recoverJournalIfNeeded(
            fileURL: fileURL,
            journalURL: journalURL,
            temporaryURL: journalTemporaryURL,
            session: session,
            decoder: decoder)
        let data = try Self.readLogData(at: fileURL)
        let scan = try Self.checkedScan(
            data: data,
            expectedSession: session,
            decoder: decoder,
            from: 0)
        guard !scan.containsUnknownEventTypes else {
            throw EventLogError.unsupportedEventTypes
        }
        let state = try Self.tailSequenceState(
            at: fileURL,
            expectedSession: session,
            decoder: decoder)
        guard state.nextSeq >= nextSeq else {
            throw EventLogError.sequenceRegressed(
                expectedAtLeast: nextSeq,
                found: state.nextSeq)
        }
        let events = try buildEvents(scan.envelopes)
        guard !events.isEmpty else {
            nextSeq = state.nextSeq
            return []
        }
        return try persistLocked(events, ts: ts, state: state)
    }

    /// Persists one full replacement-history checkpoint only if the target
    /// agent's durable model history is still the exact source revision used
    /// to build it.
    ///
    /// Unrelated agents and non-model-history events may advance the shared
    /// EventLog tail without invalidating this compare-and-append. Unknown
    /// event types or a sequence gap fail closed because they make absence and
    /// ordering proofs unsafe.
    @discardableResult
    public func appendModelHistoryCompaction(
        _ checkpoint: ModelHistoryCompactedPayload,
        expectedLatestAgentHistorySeq: Int?,
        ts: Date = Date()
    ) throws -> Envelope {
        try checkpoint.validate()

        let lock = try EventLogFileLock.acquire(at: lockURL, mode: .exclusive)
        defer { lock.release() }

        try Self.recoverJournalIfNeeded(
            fileURL: fileURL,
            journalURL: journalURL,
            temporaryURL: journalTemporaryURL,
            session: session,
            decoder: decoder)
        let data = try Self.readLogData(at: fileURL)
        let scan = try Self.checkedScan(
            data: data,
            expectedSession: session,
            decoder: decoder,
            from: 0)
        guard !scan.containsUnknownEventTypes else {
            throw EventLogError.unsupportedEventTypes
        }
        guard scan.nextSeq == scan.envelopes.count,
              scan.envelopes.enumerated().allSatisfy({
                  offset, envelope in
                  envelope.seq == offset
              }) else {
            throw EventLogError.incompleteEventHistory
        }

        let actualLatestAgentHistorySeq =
            Self.latestModelHistorySequence(
                for: checkpoint.agent,
                in: scan.envelopes)
        guard actualLatestAgentHistorySeq ==
                expectedLatestAgentHistorySeq else {
            throw EventLogError.staleModelHistory(
                expectedLatestAgentHistorySeq:
                    expectedLatestAgentHistorySeq,
                actualLatestAgentHistorySeq:
                    actualLatestAgentHistorySeq)
        }

        try Self.validateModelHistoryCheckpointLineage(
            appending: checkpoint,
            in: scan.envelopes)

        let state = try Self.tailSequenceState(
            at: fileURL,
            expectedSession: session,
            decoder: decoder)
        guard state.nextSeq >= nextSeq else {
            throw EventLogError.sequenceRegressed(
                expectedAtLeast: nextSeq,
                found: state.nextSeq)
        }
        guard let envelope = try persistLocked(
            [.modelHistoryCompacted(checkpoint)],
            ts: ts,
            state: state,
            allowsModelHistoryCompaction: true).first else {
            preconditionFailure(
                "a model history compaction must persist one event")
        }
        return envelope
    }

    /// Atomically settles one durably registered permission request.
    ///
    /// The complete-known-history check, first-terminal comparison, and append
    /// all run under the same cross-process lock. An exact duplicate response
    /// is idempotent; a conflicting duplicate fails closed and no bytes are
    /// appended. This is the durable linearization point used by local UI,
    /// automatic review, and future remote `permission.respond` transports.
    public func settlePermissionRequest(
        _ resolution: PermissionResolvedPayload,
        ts: Date = Date()
    ) throws -> PermissionSettlementAppendResult {
        guard let requestID = resolution.requestId else {
            throw EventLogError.permissionRequestNotFound
        }

        let lock = try EventLogFileLock.acquire(at: lockURL, mode: .exclusive)
        defer { lock.release() }

        try Self.recoverJournalIfNeeded(
            fileURL: fileURL,
            journalURL: journalURL,
            temporaryURL: journalTemporaryURL,
            session: session,
            decoder: decoder)
        let data = try Self.readLogData(at: fileURL)
        let scan = try Self.checkedScan(
            data: data,
            expectedSession: session,
            decoder: decoder,
            from: 0)
        guard !scan.containsUnknownEventTypes else {
            throw EventLogError.unsupportedEventTypes
        }
        guard scan.envelopes.enumerated().allSatisfy({ offset, envelope in
            envelope.seq == offset
        }) else {
            throw EventLogError.incompleteEventHistory
        }

        let existingTerminalIndex =
            try Self.validatedPermissionSettlementIndex(
                in: scan.envelopes,
                requestID: requestID,
                resolution: resolution)
        if let existingTerminalIndex {
            nextSeq = max(nextSeq, scan.nextSeq)
            return Self.existingPermissionSettlementResult(
                in: scan.envelopes,
                at: existingTerminalIndex)
        }

        let state = try Self.tailSequenceState(
            at: fileURL,
            expectedSession: session,
            decoder: decoder)
        guard state.nextSeq >= nextSeq else {
            throw EventLogError.sequenceRegressed(
                expectedAtLeast: nextSeq,
                found: state.nextSeq)
        }
        let events = try Self.permissionSettlementEvents(
            resolution: resolution,
            ts: ts,
            history: scan.envelopes)
        return try persistPermissionSettlement(
            events,
            ts: ts,
            state: state)
    }

    @inline(never)
    private static func validatedPermissionSettlementIndex(
        in history: [Envelope],
        requestID: RequestID,
        resolution: PermissionResolvedPayload
    ) throws -> Int? {
        var registeredRequest: PermissionRequestPayload?
        var firstTerminal: PermissionResolvedPayload?
        var firstTerminalIndex: Int?
        for (index, envelope) in history.enumerated() {
            switch envelope.event {
            case .permissionRequest(let request)
                    where request.requestId == requestID:
                if let registeredRequest,
                   registeredRequest != request {
                    throw EventLogError
                        .conflictingPermissionRequest
                }
                registeredRequest = request

            case .permissionResolved(let existing)
                    where existing.requestId == requestID:
                if let firstTerminal {
                    guard firstTerminal == existing else {
                        throw EventLogError
                            .conflictingPermissionSettlement
                    }
                } else {
                    firstTerminal = existing
                    firstTerminalIndex = index
                }

            default:
                break
            }
        }

        guard let registeredRequest else {
            throw EventLogError.permissionRequestNotFound
        }
        guard registeredRequest.tool == resolution.tool else {
            throw EventLogError
                .conflictingPermissionSettlement
        }
        if let expectedTurnID =
                registeredRequest.context?.turnID {
            guard resolution.turnID == expectedTurnID else {
                throw EventLogError
                    .conflictingPermissionSettlement
            }
        }
        if let expectedToolCallID =
                registeredRequest.context?.toolCallID {
            guard resolution.toolCallID
                    == expectedToolCallID else {
                throw EventLogError
                    .conflictingPermissionSettlement
            }
        }
        if let expectedAuthorization =
                registeredRequest.context?.authorization {
            guard resolution.authorization
                    == expectedAuthorization else {
                throw EventLogError
                    .conflictingPermissionSettlement
            }
        }
        if let action = resolution.action {
            let isConsistent: Bool
            switch action {
            case .approve, .approveAndRemember:
                isConsistent =
                    resolution.decision == .allow
            case .decline, .cancelTurn:
                isConsistent =
                    resolution.decision == .deny
            }
            guard isConsistent else {
                throw EventLogError
                    .conflictingPermissionSettlement
            }
        }
        if resolution.action
                == .approveAndRemember {
            guard resolution.source == .user,
                  resolution.decision == .allow,
                  registeredRequest.context?
                    .authorization?
                    .sideEffect == .readOnly,
                  registeredRequest.context?
                    .authorization?.mcp?
                    .effectiveApprovalMode == .auto,
                  resolution.authorization?
                    .sideEffect == .readOnly,
                  resolution.authorization?.mcp?
                    .effectiveApprovalMode == .auto else {
                throw EventLogError
                    .conflictingPermissionSettlement
            }
        }
        if let firstTerminal {
            guard firstTerminal == resolution else {
                throw EventLogError
                    .conflictingPermissionSettlement
            }
        }
        return firstTerminalIndex
    }

    @inline(never)
    private static func existingPermissionSettlementResult(
        in history: [Envelope],
        at index: Int
    ) -> PermissionSettlementAppendResult {
        let envelope = history[index]
        guard case .permissionResolved(
            let canonicalResolution) = envelope.event else {
            preconditionFailure(
                "validated permission settlement index must reference a terminal event")
        }
        return PermissionSettlementAppendResult(
            envelope: envelope,
            resolution: canonicalResolution,
            didAppend: false)
    }

    @inline(never)
    private static func permissionSettlementEvents(
        resolution: PermissionResolvedPayload,
        ts: Date,
        history: [Envelope]
    ) throws -> [Event] {
        var events: [Event] = [
            .permissionResolved(resolution),
        ]
        if resolution.decision == .allow,
           resolution.action
                == .approveAndRemember,
           let MCPAuthorization =
                resolution.authorization?.mcp,
           resolution.authorization?
                .sideEffect == .readOnly,
           MCPAuthorization.effectiveApprovalMode
                == .auto {
            let approval =
                try MCPRememberedToolApproval(
                    authorization: MCPAuthorization,
                    createdAt: ts)
            var active:
                [MCPRememberedApprovalID:
                    MCPRememberedToolApproval] = [:]
            for envelope in history {
                switch envelope.event {
                case .mcpRememberedApprovalGranted(
                        let payload):
                    active[
                        payload.approval.approvalID] =
                        payload.approval
                case .mcpRememberedApprovalRevoked(
                        let payload):
                    active.removeValue(
                        forKey: payload.approvalID)
                default:
                    break
                }
            }
            if !active.values.contains(where: {
                $0.exactlyMatches(
                    MCPAuthorization,
                    at: ts)
            }) {
                events.append(
                    .mcpRememberedApprovalGranted(
                        .init(approval: approval)))
            }
        }
        return events
    }

    @inline(never)
    private func persistPermissionSettlement(
        _ events: [Event],
        ts: Date,
        state: EventLogSequenceState
    ) throws -> PermissionSettlementAppendResult {
        guard let envelope = try persistLocked(
            events,
            ts: ts,
            state: state).first,
              case .permissionResolved(
                let canonicalResolution) =
                envelope.event else {
            preconditionFailure(
                "a permission settlement append must persist one terminal event")
        }
        return PermissionSettlementAppendResult(
            envelope: envelope,
            resolution: canonicalResolution,
            didAppend: true)
    }

    /// RequestID-scoped first-write registration for callers entering at a
    /// responder/transport boundary. AgentLoop normally persists its request
    /// and blocked status as one batch before publishing; this method lets a
    /// reconnect or test verify that exact durable identity without appending
    /// a duplicate. A conflicting payload fails closed under the same lock.
    public func registerPermissionRequest(
        _ request: PermissionRequestPayload,
        ts: Date = Date()
    ) throws -> PermissionRequestRegistrationResult {
        let lock = try EventLogFileLock.acquire(at: lockURL, mode: .exclusive)
        defer { lock.release() }

        try Self.recoverJournalIfNeeded(
            fileURL: fileURL,
            journalURL: journalURL,
            temporaryURL: journalTemporaryURL,
            session: session,
            decoder: decoder)
        let data = try Self.readLogData(at: fileURL)
        let scan = try Self.checkedScan(
            data: data,
            expectedSession: session,
            decoder: decoder,
            from: 0)
        guard !scan.containsUnknownEventTypes else {
            throw EventLogError.unsupportedEventTypes
        }
        guard scan.envelopes.enumerated().allSatisfy({ offset, envelope in
            envelope.seq == offset
        }) else {
            throw EventLogError.incompleteEventHistory
        }

        var firstRequest: (Envelope, PermissionRequestPayload)?
        for envelope in scan.envelopes {
            if case .permissionRequest(let existing) = envelope.event,
               existing.requestId == request.requestId {
                if let firstRequest {
                    guard firstRequest.1 == existing else {
                        throw EventLogError.conflictingPermissionRequest
                    }
                } else {
                    firstRequest = (envelope, existing)
                }
            }
        }
        if let firstRequest {
            guard firstRequest.1 == request else {
                throw EventLogError.conflictingPermissionRequest
            }
            nextSeq = max(nextSeq, scan.nextSeq)
            return PermissionRequestRegistrationResult(
                envelope: firstRequest.0,
                request: firstRequest.1,
                didAppend: false)
        }

        let state = try Self.tailSequenceState(
            at: fileURL,
            expectedSession: session,
            decoder: decoder)
        guard state.nextSeq >= nextSeq else {
            throw EventLogError.sequenceRegressed(
                expectedAtLeast: nextSeq,
                found: state.nextSeq)
        }
        guard let envelope = try persistLocked(
            [.permissionRequest(request)],
            ts: ts,
            state: state).first,
              case .permissionRequest(let canonicalRequest) = envelope.event else {
            preconditionFailure("a permission registration must persist one request event")
        }
        return PermissionRequestRegistrationResult(
            envelope: envelope,
            request: canonicalRequest,
            didAppend: true)
    }

    /// Atomically installs the first admission-closing claim for one exact
    /// ContinuationRunID. The complete-known-history proof and append share the
    /// event-log lock, so separate runtime instances cannot both win. An exact
    /// replay is idempotent; a different request observes the canonical winner.
    public func claimContinuationRunClose(
        _ request: ContinuationRunCloseRequestedPayload,
        ts: Date = Date()
    ) throws -> ContinuationRunCloseClaimResult {
        guard request.sessionID == session else {
            throw EventLogError.sessionMismatch
        }

        let lock = try EventLogFileLock.acquire(at: lockURL, mode: .exclusive)
        defer { lock.release() }

        try Self.recoverJournalIfNeeded(
            fileURL: fileURL,
            journalURL: journalURL,
            temporaryURL: journalTemporaryURL,
            session: session,
            decoder: decoder)
        let data = try Self.readLogData(at: fileURL)
        let scan = try Self.checkedScan(
            data: data,
            expectedSession: session,
            decoder: decoder,
            from: 0)
        guard !scan.containsUnknownEventTypes else {
            throw EventLogError.unsupportedEventTypes
        }
        guard scan.envelopes.enumerated().allSatisfy({ offset, envelope in
            envelope.seq == offset
        }) else {
            throw EventLogError.incompleteEventHistory
        }

        var first: (Envelope, ContinuationRunCloseRequestedPayload)?
        for envelope in scan.envelopes {
            guard case .continuationRunCloseRequested(let existing) = envelope.event,
                  existing.runID == request.runID else { continue }
            if let first {
                guard first.1 == existing else {
                    throw EventLogError.conflictingContinuationRunCloseClaim
                }
            } else {
                first = (envelope, existing)
            }
        }
        if let first {
            nextSeq = max(nextSeq, scan.nextSeq)
            return ContinuationRunCloseClaimResult(
                envelope: first.0,
                claim: first.1,
                didAppend: false,
                matchesRequest: first.1 == request)
        }

        let state = try Self.tailSequenceState(
            at: fileURL,
            expectedSession: session,
            decoder: decoder)
        guard state.nextSeq >= nextSeq else {
            throw EventLogError.sequenceRegressed(
                expectedAtLeast: nextSeq,
                found: state.nextSeq)
        }
        guard let envelope = try persistLocked(
            [.continuationRunCloseRequested(request)],
            ts: ts,
            state: state).first,
              case .continuationRunCloseRequested(let canonical) = envelope.event else {
            preconditionFailure("a run close claim append must persist one claim")
        }
        return ContinuationRunCloseClaimResult(
            envelope: envelope,
            claim: canonical,
            didAppend: true,
            matchesRequest: true)
    }

    /// Appends a fresh-session bootstrap only if no durable Envelope header is
    /// present at the instant of append. The emptiness predicate and batch
    /// write share one cross-process lock, closing the check/write race between
    /// separate EventLog instances.
    public func appendIfEmptyChecked(
        _ events: [Event],
        ts: Date = Date()
    ) throws -> [Envelope]? {
        guard !events.isEmpty else { return [] }
        let lock = try EventLogFileLock.acquire(at: lockURL, mode: .exclusive)
        defer { lock.release() }

        try Self.recoverJournalIfNeeded(
            fileURL: fileURL,
            journalURL: journalURL,
            temporaryURL: journalTemporaryURL,
            session: session,
            decoder: decoder)
        let data = try Self.readLogData(at: fileURL)
        let scan = try Self.checkedScan(
            data: data,
            expectedSession: session,
            decoder: decoder,
            from: 0)
        guard !scan.containsEnvelopeHeader else {
            nextSeq = max(nextSeq, scan.nextSeq)
            return nil
        }
        let state = try Self.tailSequenceState(
            at: fileURL,
            expectedSession: session,
            decoder: decoder)
        guard state.nextSeq >= nextSeq else {
            throw EventLogError.sequenceRegressed(
                expectedAtLeast: nextSeq,
                found: state.nextSeq)
        }
        return try persistLocked(events, ts: ts, state: state)
    }

    private func persistLocked(
        _ events: [Event],
        ts: Date,
        state: EventLogSequenceState,
        allowsModelHistoryCompaction: Bool = false
    ) throws -> [Envelope] {
        guard !events.isEmpty else { return [] }
        guard allowsModelHistoryCompaction
                || !events.contains(where: {
                    if case .modelHistoryCompacted = $0 {
                        return true
                    }
                    return false
                }) else {
            throw EventLogError
                .modelHistoryCompactionRequiresValidatedAppend
        }
        try Self.validateModelHistoryMediaBatch(events)

        var envelopes: [Envelope] = []
        envelopes.reserveCapacity(events.count)
        var bytes = Data()
        if state.needsSeparator {
            bytes.append(0x0A)
        }

        for (offset, event) in events.enumerated() {
            let (seq, overflow) = state.nextSeq.addingReportingOverflow(offset)
            guard !overflow else { throw EventLogError.sequenceExhausted }
            let envelope = Envelope(seq: seq, ts: ts, session: session, event: event)
            var line: Data
            do {
                line = try encoder.encode(envelope)
            } catch {
                throw Self.storageError(operation: "encode an event", error: error)
            }
            let canonicalEnvelope: Envelope
            do {
                // Encoding may intentionally omit decode-only compatibility
                // fields or normalize values such as Date precision. Return
                // and publish the exact semantic envelope represented by the
                // bytes that will become canonical JSONL state.
                canonicalEnvelope = try decoder.decode(Envelope.self, from: line)
            } catch {
                throw Self.storageError(operation: "canonicalize an event", error: error)
            }
            line.append(0x0A)
            bytes.append(line)
            envelopes.append(canonicalEnvelope)
        }

        let (advancedNextSeq, overflow) = state.nextSeq.addingReportingOverflow(events.count)
        guard !overflow else { throw EventLogError.sequenceExhausted }
        if Self.shouldJournalWrite(
            eventCount: events.count,
            byteCount: bytes.count)
        {
            let snapshot = try Self.fileSnapshot(at: fileURL)
            let journal = EventLogWriteAheadJournal(
                session: session,
                originalOffset: snapshot.offset,
                prefixStartOffset: snapshot.prefixStartOffset,
                prefixBytes: snapshot.prefixBytes,
                batchBytes: bytes,
                firstSequence: state.nextSeq,
                eventCount: events.count)
            try Self.commitJournaledBatch(
                journal,
                fileURL: fileURL,
                journalURL: journalURL,
                temporaryURL: journalTemporaryURL,
                decoder: decoder)
        } else {
            try appendBytes(bytes)
        }

        nextSeq = advancedNextSeq
        for envelope in envelopes {
            for (_, continuation) in subscribers {
                continuation.yield(envelope)
            }
        }
        return envelopes
    }

    /// Compatibility replay. Callers that must distinguish an empty log from
    /// lock, read, or known-event corruption should use `replayChecked`.
    /// Unknown future event types remain intentionally invisible to this
    /// binary, preserving additive event-schema evolution.
    public func replay(from seq: Int = 0) -> [Envelope] {
        // Compatibility replay remains fail-soft, but it must not expose a
        // prefix of an atomic multi-event batch. Recover any promoted WAL under
        // the same exclusive lock as append; if recovery cannot be proven,
        // return no projection rather than reading the uncertain JSONL bytes.
        guard let lock = try? EventLogFileLock.acquire(at: lockURL, mode: .exclusive) else {
            return []
        }
        defer { lock.release() }
        do {
            try Self.recoverJournalIfNeeded(
                fileURL: fileURL,
                journalURL: journalURL,
                temporaryURL: journalTemporaryURL,
                session: session,
                decoder: decoder)
        } catch {
            return []
        }
        guard let data = try? Self.readLogData(at: fileURL) else { return [] }
        var result: [Envelope] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let envelope = try? decoder.decode(Envelope.self, from: Data(line)),
               envelope.seq >= seq {
                result.append(envelope)
            }
        }
        return result
    }

    /// Strict replay for safety-sensitive callers. A well-formed envelope
    /// header with a future `type` reserves sequence space and is skipped; a
    /// malformed line or a known type whose payload cannot decode is a hard
    /// error rather than being confused with an empty session.
    public func replayChecked(from seq: Int = 0) throws -> [Envelope] {
        // A strict reader is also a recovery boundary. A process may have
        // terminated after this EventLog instance was initialized, leaving a
        // promoted WAL plus a partial JSONL suffix. Recover under the same
        // exclusive lock as append before exposing any batch member.
        let lock = try EventLogFileLock.acquire(at: lockURL, mode: .exclusive)
        defer { lock.release() }
        try Self.recoverJournalIfNeeded(
            fileURL: fileURL,
            journalURL: journalURL,
            temporaryURL: journalTemporaryURL,
            session: session,
            decoder: decoder)
        let data = try Self.readLogData(at: fileURL)
        let scan = try Self.checkedScan(
            data: data,
            expectedSession: session,
            decoder: decoder,
            from: seq)
        guard scan.nextSeq >= nextSeq else {
            throw EventLogError.sequenceRegressed(
                expectedAtLeast: nextSeq,
                found: scan.nextSeq)
        }
        return scan.envelopes
    }

    /// Strict replay for `session.json` and other fully rebuildable caches.
    /// Callers must not overwrite a newer projection when an unknown event is
    /// present because this binary cannot prove it understands that state.
    public func replayForProjectionChecked(from seq: Int = 0) throws -> EventLogProjectionReplay {
        let lock = try EventLogFileLock.acquire(at: lockURL, mode: .exclusive)
        defer { lock.release() }
        try Self.recoverJournalIfNeeded(
            fileURL: fileURL,
            journalURL: journalURL,
            temporaryURL: journalTemporaryURL,
            session: session,
            decoder: decoder)
        let data = try Self.readLogData(at: fileURL)
        let scan = try Self.checkedScan(
            data: data,
            expectedSession: session,
            decoder: decoder,
            from: seq)
        guard scan.nextSeq >= nextSeq else {
            throw EventLogError.sequenceRegressed(
                expectedAtLeast: nextSeq,
                found: scan.nextSeq)
        }
        return EventLogProjectionReplay(
            envelopes: scan.envelopes,
            lastDurableSeq: scan.containsEnvelopeHeader ? scan.nextSeq - 1 : nil,
            containsUnknownEventTypes: scan.containsUnknownEventTypes)
    }

    /// Strict emptiness check used by fresh-session bootstrap. Unlike
    /// `replayChecked().isEmpty`, any valid Envelope header counts as durable
    /// state, including an otherwise-skipped future event type.
    public func isEmptyChecked() throws -> Bool {
        let lock = try EventLogFileLock.acquire(at: lockURL, mode: .exclusive)
        defer { lock.release() }
        try Self.recoverJournalIfNeeded(
            fileURL: fileURL,
            journalURL: journalURL,
            temporaryURL: journalTemporaryURL,
            session: session,
            decoder: decoder)
        let data = try Self.readLogData(at: fileURL)
        let scan = try Self.checkedScan(
            data: data,
            expectedSession: session,
            decoder: decoder,
            from: 0)
        guard scan.nextSeq >= nextSeq else {
            throw EventLogError.sequenceRegressed(
                expectedAtLeast: nextSeq,
                found: scan.nextSeq)
        }
        return !scan.containsEnvelopeHeader
    }

    /// Replays existing events (>= `from`), then streams live ones as appended.
    /// Built with `makeStream` so the replay + subscriber registration run in
    /// this actor-isolated method body, not inside a `@Sendable` closure.
    public func stream(from seq: Int = 0) -> AsyncStream<Envelope> {
        let (stream, continuation) = AsyncStream<Envelope>.makeStream()
        for env in replay(from: seq) {
            continuation.yield(env)
        }
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    /// Registers a live-only subscriber at the exact current durable tail.
    ///
    /// The cross-process lock prevents another writer from appending between
    /// the complete-known tail scan and subscriber registration, while actor
    /// isolation prevents an in-process append from crossing the boundary.
    /// Existing history is intentionally not replayed.
    public func streamFromCurrentDurableTail()
        throws -> AsyncStream<Envelope>
    {
        let lock = try EventLogFileLock.acquire(
            at: lockURL,
            mode: .exclusive)
        defer { lock.release() }
        try Self.recoverJournalIfNeeded(
            fileURL: fileURL,
            journalURL: journalURL,
            temporaryURL: journalTemporaryURL,
            session: session,
            decoder: decoder)
        let data = try Self.readLogData(
            at: fileURL)
        let scan = try Self.checkedScan(
            data: data,
            expectedSession: session,
            decoder: decoder,
            from: 0)
        guard !scan.containsUnknownEventTypes else {
            throw EventLogError.unsupportedEventTypes
        }
        guard scan.envelopes.enumerated()
            .allSatisfy({
                offset, envelope in
                envelope.seq == offset
            }) else {
            throw EventLogError.incompleteEventHistory
        }
        nextSeq = max(nextSeq, scan.nextSeq)
        let (stream, continuation) =
            AsyncStream<Envelope>.makeStream()
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = {
            [weak self] _ in
            Task {
                await self?.removeSubscriber(id)
            }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private static func readLogData(at fileURL: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Data()
        }
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            throw storageError(operation: "read its data", error: error)
        }
    }

    private static func checkedScan(data: Data,
                                    expectedSession: SessionID,
                                    decoder: JSONDecoder,
                                    from seq: Int) throws -> EventLogCheckedScan {
        var envelopes: [Envelope] = []
        var previousSequence: Int?
        var containsEnvelopeHeader = false
        var containsUnknownEventTypes = false
        var nextSequence = 0
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)

        for (index, line) in lines.enumerated() where !line.isEmpty {
            let lineNumber = index + 1
            let header: EnvelopeSequenceHeader
            do {
                header = try decoder.decode(
                    EnvelopeSequenceHeader.self,
                    from: Data(line))
            } catch {
                throw EventLogError.corruptedEvent(line: lineNumber)
            }

            guard header.seq >= 0 else {
                throw EventLogError.corruptedEvent(line: lineNumber)
            }
            guard header.session == expectedSession else {
                throw EventLogError.sessionMismatch
            }
            if let previousSequence, header.seq <= previousSequence {
                throw EventLogError.nonMonotonicSequence(
                    previous: previousSequence,
                    current: header.seq)
            }
            previousSequence = header.seq
            containsEnvelopeHeader = true
            let (advanced, overflow) = header.seq.addingReportingOverflow(1)
            guard !overflow else { throw EventLogError.sequenceExhausted }
            nextSequence = advanced

            // A header that is structurally valid but names a future type is
            // durable state and reserves its sequence. Its payload remains
            // opaque to this binary and is intentionally skipped.
            guard Event.TypeTag(rawValue: header.type) != nil else {
                containsUnknownEventTypes = true
                continue
            }
            let envelope: Envelope
            do {
                envelope = try decoder.decode(
                    Envelope.self,
                    from: Data(line))
            } catch {
                throw EventLogError.corruptedEvent(line: lineNumber)
            }
            if envelope.seq >= seq {
                envelopes.append(envelope)
            }
        }

        return EventLogCheckedScan(
            envelopes: envelopes,
            containsEnvelopeHeader: containsEnvelopeHeader,
            containsUnknownEventTypes: containsUnknownEventTypes,
            nextSeq: nextSequence)
    }

    private static func latestModelHistorySequence(
        for agent: AgentID,
        in envelopes: [Envelope]
    ) -> Int? {
        for envelope in envelopes.reversed() {
            switch envelope.event {
            case .modelHistoryItem(let payload)
                where payload.agent == agent:
                return envelope.seq
            case .modelHistoryCompacted(let payload)
                where payload.agent == agent:
                return envelope.seq
            default:
                continue
            }
        }
        return nil
    }

    /// Binds every durable media-bearing function output to the canonical tool
    /// result and execution settlement that produced it. This runs before
    /// envelope/WAL bytes are created so an orphan, mismatch, or duplicate
    /// rejects the whole batch.
    private static func validateModelHistoryMediaBatch(
        _ events: [Event]
    ) throws {
        struct SettlementKey: Hashable {
            var callID: String
            var taskID: TaskID?
            var attempt: Int?
            var agent: AgentID?
        }

        var toolResultsByTurnAndCall:
            [TurnID: [String: [ToolResultPayload]]] = [:]
        var settlementsByKey:
            [SettlementKey: [ToolExecutionSettledPayload]] = [:]
        for event in events {
            switch event {
            case .toolResult(let payload):
                guard let turnID = payload.turnID else { continue }
                toolResultsByTurnAndCall[turnID, default: [:]][
                    payload.toolCallId,
                    default: []
                ].append(payload)
            case .toolExecutionSettled(let payload):
                settlementsByKey[SettlementKey(
                    callID: payload.toolCallID,
                    taskID: payload.taskID,
                    attempt: payload.attempt,
                    agent: payload.agent), default: []].append(payload)
            default:
                continue
            }
        }

        var mediaOutputCallIDsByTurn: [TurnID: Set<String>] = [:]
        var mediaOutputSettlementKeys = Set<SettlementKey>()
        for event in events {
            guard case .modelHistoryItem(let payload) = event,
                  payload.schemaVersion
                    == ModelHistoryItemPayload.mediaSchemaVersion,
                  payload.kind == .functionCallOutput,
                  let references = payload.imageReferences,
                  !references.isEmpty else {
                continue
            }
            guard let callID = payload.callID,
                  mediaOutputCallIDsByTurn[
                    payload.turnID,
                    default: []
                  ].insert(callID).inserted,
                  let matchingResults = toolResultsByTurnAndCall[
                    payload.turnID
                  ]?[callID],
                  matchingResults.count == 1,
                  let structuredResult = matchingResults[0].structuredResult,
                  mediaOutputSettlementKeys.insert(SettlementKey(
                    callID: callID,
                    taskID: payload.taskID,
                    attempt: payload.taskAttempt,
                    agent: payload.agent)).inserted
            else {
                throw EventLogError.invalidModelHistoryMediaBatch
            }

            let imageBlocks = structuredResult.content.filter {
                $0.kind == .imageReference
            }
            guard imageBlocks.count == references.count else {
                throw EventLogError.invalidModelHistoryMediaBatch
            }
            for (block, reference) in zip(imageBlocks, references) {
                guard block.artifactID == reference.artifactID,
                      block.mimeType == reference.mimeType,
                      block.byteCount == reference.byteCount,
                      block.sha256 == reference.sha256 else {
                    throw EventLogError.invalidModelHistoryMediaBatch
                }
            }
        }
        for key in mediaOutputSettlementKeys {
            guard settlementsByKey[key]?.count == 1 else {
                throw EventLogError.invalidModelHistoryMediaBatch
            }
        }
    }

    /// Validates the complete same-agent checkpoint chain while the EventLog
    /// lock is held. The candidate is checked after its source-history CAS and
    /// before any envelope or WAL bytes are created.
    private static func validateModelHistoryCheckpointLineage(
        appending candidate: ModelHistoryCompactedPayload,
        in envelopes: [Envelope]
    ) throws {
        var mediaAwareSchemaRequired = false
        for envelope in envelopes {
            switch envelope.event {
            case .modelHistoryItem(let payload)
                    where payload.agent == candidate.agent:
                if payload.schemaVersion
                    == ModelHistoryItemPayload.mediaSchemaVersion {
                    mediaAwareSchemaRequired = true
                }
            case .modelHistoryCompacted(let payload)
                    where payload.agent == candidate.agent:
                if mediaAwareSchemaRequired,
                   payload.schemaVersion
                    != ModelHistoryCompactedPayload.mediaSchemaVersion {
                    throw EventLogError.invalidModelHistoryWindowLineage
                }
                if payload.schemaVersion
                    == ModelHistoryCompactedPayload.mediaSchemaVersion {
                    mediaAwareSchemaRequired = true
                }
            default:
                continue
            }
        }
        if mediaAwareSchemaRequired,
           candidate.schemaVersion
            != ModelHistoryCompactedPayload.mediaSchemaVersion {
            throw EventLogError.invalidModelHistoryWindowLineage
        }

        var checkpoints = envelopes.compactMap {
            envelope -> ModelHistoryCompactedPayload? in
            guard case .modelHistoryCompacted(let payload) =
                    envelope.event,
                  payload.agent == candidate.agent else {
                return nil
            }
            return payload
        }
        checkpoints.append(candidate)

        var previous: ModelHistoryCompactedPayload?
        var usedWindowIDs = Set<String>()
        for checkpoint in checkpoints {
            try checkpoint.validate()
            if let previous {
                let (expectedWindowNumber, overflow) =
                    previous.windowNumber.addingReportingOverflow(1)
                guard !overflow,
                      checkpoint.windowNumber == expectedWindowNumber,
                      checkpoint.firstWindowID
                        == previous.firstWindowID,
                      checkpoint.previousWindowID
                        == previous.windowID else {
                    throw EventLogError
                        .invalidModelHistoryWindowLineage
                }
            } else {
                guard checkpoint.windowNumber == 1,
                      checkpoint.previousWindowID
                        == checkpoint.firstWindowID,
                      checkpoint.windowID
                        != checkpoint.firstWindowID else {
                    throw EventLogError
                        .invalidModelHistoryWindowLineage
                }
                usedWindowIDs.insert(checkpoint.firstWindowID)
            }

            guard usedWindowIDs.insert(
                checkpoint.windowID).inserted else {
                throw EventLogError.reusedModelHistoryWindowID
            }
            previous = checkpoint
        }
    }

    private static func fileSnapshot(at fileURL: URL) throws -> EventLogFileSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return EventLogFileSnapshot(
                offset: 0,
                prefixStartOffset: 0,
                prefixBytes: Data())
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw storageError(operation: "open its data for journaling", error: error)
        }
        defer { try? handle.close() }

        do {
            let offset = try handle.seekToEnd()
            let prefixLength = min(offset, UInt64(EventLogWriteAheadJournal.prefixLimit))
            let prefixStartOffset = offset - prefixLength
            try handle.seek(toOffset: prefixStartOffset)
            let prefixBytes = try readExactly(handle, count: Int(prefixLength))
            return EventLogFileSnapshot(
                offset: offset,
                prefixStartOffset: prefixStartOffset,
                prefixBytes: prefixBytes)
        } catch let error as EventLogError {
            throw error
        } catch {
            throw storageError(operation: "read its journal prefix", error: error)
        }
    }

    private static func commitJournaledBatch(
        _ journal: EventLogWriteAheadJournal,
        fileURL: URL,
        journalURL: URL,
        temporaryURL: URL,
        decoder: JSONDecoder
    ) throws {
        try journal.validate(expectedSession: journal.session, decoder: decoder)
        try persistJournal(journal, at: journalURL, temporaryURL: temporaryURL)

        let initialState = try journalState(journal, fileURL: fileURL)
        guard initialState == .untouched else {
            throw EventLogError.journalMismatch
        }

        do {
            try appendJournalBytes(journal.batchBytes,
                                   at: fileURL,
                                   expectedOffset: journal.originalOffset)
            // Persist a newly-created JSONL directory entry before the WAL can
            // be removed. Existing files also take this path; the extra fsync
            // keeps the commit ordering explicit across supported platforms.
            try synchronizeParentDirectory(
                of: fileURL,
                operation: "synchronize its committed batch directory")
        } catch {
            // A write or synchronize call may have persisted only a prefix.
            // Roll back while the lock is still held. If rollback itself
            // fails, retain the journal so the next init/append can recover.
            let isMismatch = (error as? EventLogError) == .journalMismatch
            if !isMismatch,
               (try? truncateLog(at: fileURL, to: journal.originalOffset)) != nil {
                try? removeItemIfPresent(at: journalURL,
                                         operation: "remove its recovery journal")
            }
            throw error
        }

        // The synchronized JSONL bytes are the commit point. Cleanup failure
        // must not report the committed batch as failed (which could provoke a
        // duplicate retry); the next init/append will recognize it as complete
        // and retry journal removal.
        try? removeItemIfPresent(at: journalURL,
                                 operation: "remove its recovery journal")
    }

    private static func persistJournal(_ journal: EventLogWriteAheadJournal,
                                       at journalURL: URL,
                                       temporaryURL: URL) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(journal)
        } catch {
            throw storageError(operation: "encode its recovery journal", error: error)
        }

        if FileManager.default.fileExists(atPath: journalURL.path) {
            throw EventLogError.journalMismatch
        }
        try removeItemIfPresent(
            at: temporaryURL,
            operation: "remove an incomplete recovery journal")

        var promoted = false
        do {
            try data.write(to: temporaryURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: temporaryURL.path)
            let temporaryHandle = try FileHandle(forWritingTo: temporaryURL)
            do {
                try temporaryHandle.synchronize()
                try temporaryHandle.close()
            } catch {
                try? temporaryHandle.close()
                throw error
            }
            try FileManager.default.moveItem(at: temporaryURL, to: journalURL)
            promoted = true
            // fsync the parent after rename so a power interruption cannot
            // leave JSONL touched without the promoted recovery intent.
            try synchronizeParentDirectory(
                of: journalURL,
                operation: "synchronize its recovery journal directory")
        } catch {
            if !promoted {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            throw storageError(operation: "persist its recovery journal", error: error)
        }
    }

    private static func recoverJournalIfNeeded(
        fileURL: URL,
        journalURL: URL,
        temporaryURL: URL,
        session: SessionID,
        decoder: JSONDecoder
    ) throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            // A temporary file is never authoritative: promotion happens
            // before the JSONL is touched. A crash before promotion therefore
            // leaves an uncommitted temp that is safe to discard.
            try removeItemIfPresent(
                at: temporaryURL,
                operation: "remove an incomplete recovery journal")
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: journalURL)
        } catch {
            throw storageError(operation: "read its recovery journal", error: error)
        }

        let journal: EventLogWriteAheadJournal
        do {
            journal = try JSONDecoder().decode(EventLogWriteAheadJournal.self, from: data)
        } catch {
            throw EventLogError.journalCorrupted
        }
        try journal.validate(expectedSession: session, decoder: decoder)

        switch try journalState(journal, fileURL: fileURL) {
        case .untouched:
            break
        case .partial:
            try truncateLog(at: fileURL, to: journal.originalOffset)
        case .complete:
            break
        }

        try removeItemIfPresent(at: journalURL,
                                operation: "remove its recovered journal")
        try removeItemIfPresent(at: temporaryURL,
                                operation: "remove an incomplete recovery journal")
    }

    private static func journalState(_ journal: EventLogWriteAheadJournal,
                                     fileURL: URL) throws -> EventLogJournalState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            guard journal.originalOffset == 0, journal.prefixBytes.isEmpty else {
                throw EventLogError.journalMismatch
            }
            return .untouched
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw storageError(operation: "open its data for recovery", error: error)
        }
        defer { try? handle.close() }

        do {
            let endOffset = try handle.seekToEnd()
            guard endOffset >= journal.originalOffset else {
                throw EventLogError.journalMismatch
            }

            try handle.seek(toOffset: journal.prefixStartOffset)
            let prefix = try readExactly(handle, count: journal.prefixBytes.count)
            guard prefix == journal.prefixBytes else {
                throw EventLogError.journalMismatch
            }

            let suffixLength = endOffset - journal.originalOffset
            guard suffixLength <= UInt64(journal.batchBytes.count) else {
                throw EventLogError.journalMismatch
            }
            try handle.seek(toOffset: journal.originalOffset)
            let suffix = try readExactly(handle, count: Int(suffixLength))
            guard journal.batchBytes.starts(with: suffix) else {
                throw EventLogError.journalMismatch
            }
            if suffix.isEmpty { return .untouched }
            if suffix.count == journal.batchBytes.count { return .complete }
            return .partial
        } catch let error as EventLogError {
            throw error
        } catch {
            throw storageError(operation: "inspect its recovery state", error: error)
        }
    }

    private static func appendJournalBytes(_ data: Data,
                                           at fileURL: URL,
                                           expectedOffset: UInt64) throws {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard expectedOffset == 0 else { throw EventLogError.journalMismatch }
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw EventLogError.storageUnavailable(
                    operation: "create its data file",
                    code: 0)
            }
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: fileURL)
        } catch {
            throw storageError(operation: "open for journaled append", error: error)
        }
        defer { try? handle.close() }

        do {
            let endOffset = try handle.seekToEnd()
            guard endOffset == expectedOffset else {
                throw EventLogError.journalMismatch
            }
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch let error as EventLogError {
            throw error
        } catch {
            throw storageError(operation: "append and synchronize a batch", error: error)
        }
    }

    private static func truncateLog(at fileURL: URL, to offset: UInt64) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            guard offset == 0 else { throw EventLogError.journalMismatch }
            return
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: fileURL)
        } catch {
            throw storageError(operation: "open for recovery rollback", error: error)
        }
        defer { try? handle.close() }
        do {
            let endOffset = try handle.seekToEnd()
            guard endOffset >= offset else { throw EventLogError.journalMismatch }
            try handle.truncate(atOffset: offset)
            try handle.synchronize()
        } catch let error as EventLogError {
            throw error
        } catch {
            throw storageError(operation: "roll back a partial batch", error: error)
        }
    }

    private static func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            let chunk = try handle.read(upToCount: count - result.count) ?? Data()
            guard !chunk.isEmpty else { throw EventLogError.journalMismatch }
            result.append(chunk)
        }
        return result
    }

    private static func removeItemIfPresent(at url: URL,
                                            operation: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw storageError(operation: operation, error: error)
        }
    }

    private static func synchronizeParentDirectory(of url: URL,
                                                   operation: String) throws {
        let directoryPath = url.deletingLastPathComponent().path
        let descriptor = open(directoryPath, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw EventLogError.storageUnavailable(operation: operation, code: Int(errno))
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw EventLogError.storageUnavailable(operation: operation, code: Int(errno))
        }
    }

    private func appendBytes(_ data: Data) throws {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw EventLogError.storageUnavailable(operation: "create its data file", code: 0)
            }
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: fileURL)
        } catch {
            throw Self.storageError(operation: "open for append", error: error)
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            throw Self.storageError(operation: "append and synchronize data", error: error)
        }
    }

    private static func sequenceState(at fileURL: URL,
                                      expectedSession: SessionID,
                                      decoder: JSONDecoder) throws -> EventLogSequenceState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return EventLogSequenceState(nextSeq: 0, needsSeparator: false)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw storageError(operation: "read sequence state", error: error)
        }

        var previous: Int?
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let header = try? decoder.decode(EnvelopeSequenceHeader.self, from: Data(line)) else {
                continue
            }
            guard header.session == expectedSession else {
                throw EventLogError.sessionMismatch
            }
            if let previous, header.seq <= previous {
                throw EventLogError.nonMonotonicSequence(
                    previous: previous,
                    current: header.seq)
            }
            previous = header.seq
        }

        let nextSeq: Int
        if let previous {
            let (advanced, overflow) = previous.addingReportingOverflow(1)
            guard !overflow else { throw EventLogError.sequenceExhausted }
            nextSeq = advanced
        } else {
            nextSeq = 0
        }
        return EventLogSequenceState(
            nextSeq: nextSeq,
            needsSeparator: !data.isEmpty && data.last != 0x0A)
    }

    /// Finds the most recent decodable envelope header without re-reading a
    /// long session from byte zero on every append. The search starts with the
    /// final 64 KiB and doubles until it reaches a complete valid line or the
    /// beginning of the file. Initialization still performs a full monotonicity
    /// validation; this locked tail read is the per-append cross-instance CAS.
    private static func tailSequenceState(at fileURL: URL,
                                          expectedSession: SessionID,
                                          decoder: JSONDecoder) throws -> EventLogSequenceState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return EventLogSequenceState(nextSeq: 0, needsSeparator: false)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw storageError(operation: "open sequence state", error: error)
        }
        defer { try? handle.close() }

        do {
            let endOffset = try handle.seekToEnd()
            guard endOffset > 0 else {
                return EventLogSequenceState(nextSeq: 0, needsSeparator: false)
            }

            var window = min(endOffset, 64 * 1_024)
            var needsSeparator = false
            var inspectedEndByte = false
            while true {
                let startOffset = endOffset - window
                try handle.seek(toOffset: startOffset)
                let data = try handle.read(upToCount: Int(window)) ?? Data()
                if !inspectedEndByte {
                    needsSeparator = data.last != 0x0A
                    inspectedEndByte = true
                }

                var lines = data.split(separator: 0x0A)
                if startOffset > 0, data.first != 0x0A, !lines.isEmpty {
                    // The window began in the middle of a JSON object. Ignore
                    // that fragment until a larger window reaches its start.
                    lines.removeFirst()
                }
                for line in lines.reversed() where !line.isEmpty {
                    guard let header = try? decoder.decode(
                        EnvelopeSequenceHeader.self,
                        from: Data(line)) else {
                        continue
                    }
                    guard header.session == expectedSession else {
                        throw EventLogError.sessionMismatch
                    }
                    let (nextSeq, overflow) = header.seq.addingReportingOverflow(1)
                    guard !overflow else { throw EventLogError.sequenceExhausted }
                    return EventLogSequenceState(
                        nextSeq: nextSeq,
                        needsSeparator: needsSeparator)
                }

                guard startOffset > 0 else {
                    return EventLogSequenceState(
                        nextSeq: 0,
                        needsSeparator: needsSeparator)
                }
                window = min(endOffset, window * 2)
            }
        } catch let error as EventLogError {
            throw error
        } catch {
            throw storageError(operation: "read sequence state", error: error)
        }
    }

    private static func storageError(operation: String, error: Error) -> EventLogError {
        EventLogError.storageUnavailable(
            operation: operation,
            code: (error as NSError).code)
    }
}
