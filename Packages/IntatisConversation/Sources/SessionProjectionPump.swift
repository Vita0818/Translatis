import Foundation
import IntatisCore
import IntatisProtocol

private extension Event {
    var isPresentationTextDelta: Bool {
        switch self {
        case .messageDelta:
            return true
        case .codexAppServerEvent(let payload):
            return payload.textDelta != nil
        default:
            return false
        }
    }
}

/// Identifies one projection publisher independently from the process-owned
/// runtime. A replacement publisher for the same session always receives a new
/// generation, so delayed snapshots cannot mutate a newer presentation.
public struct SessionProjectionIdentity: Equatable, Sendable {
    public var sessionID: SessionID
    public var generation: UUID

    public init(
        sessionID: SessionID,
        generation: UUID = UUID()
    ) {
        self.sessionID = sessionID
        self.generation = generation
    }
}

/// MainActor-side monotonic fence for projection snapshots. It is deliberately
/// pure so session/generation replacement and stale-sequence behavior can be
/// proven without constructing SwiftUI view models.
public struct SessionProjectionCommitFence:
    Equatable,
    Sendable
{
    public private(set) var identity:
        SessionProjectionIdentity
    public private(set) var throughSeq: Int

    public init(
        identity: SessionProjectionIdentity,
        throughSeq: Int = Int.min
    ) {
        self.identity = identity
        self.throughSeq = throughSeq
    }

    @discardableResult
    public mutating func accept(
        identity candidateIdentity:
            SessionProjectionIdentity,
        throughSeq candidateSeq: Int
    ) -> Bool {
        guard candidateIdentity == identity,
              candidateSeq > throughSeq else {
            return false
        }
        throughSeq = candidateSeq
        return true
    }

    public mutating func replace(
        with identity:
            SessionProjectionIdentity
    ) {
        self.identity = identity
        throughSeq = Int.min
    }
}

/// Presentation domains changed since the previous publication. EventLog
/// folding remains exact; this mask only controls which observable properties
/// the MainActor presentation layer republishes.
public struct SessionProjectionDirtyDomains:
    OptionSet,
    Equatable,
    Sendable
{
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let thread =
        SessionProjectionDirtyDomains(rawValue: 1 << 0)
    public static let cowork =
        SessionProjectionDirtyDomains(rawValue: 1 << 1)
    public static let permission =
        SessionProjectionDirtyDomains(rawValue: 1 << 2)
    public static let stats =
        SessionProjectionDirtyDomains(rawValue: 1 << 3)
    public static let agentState =
        SessionProjectionDirtyDomains(rawValue: 1 << 4)

    public static let codeAll: SessionProjectionDirtyDomains = [
        .thread,
        .permission,
        .stats,
        .agentState,
    ]
    public static let coworkAll: SessionProjectionDirtyDomains = [
        .thread,
        .cowork,
        .permission,
        .stats,
    ]
}

public enum SessionProjectionPumpFailure:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case sessionMismatch(
        expected: SessionID,
        actual: SessionID)
    case sequenceGap(
        expected: Int,
        actual: Int)
    case alreadyStarted
    case initialReplayAlreadyLoaded

    public var errorDescription: String? {
        switch self {
        case .sessionMismatch(let expected, let actual):
            return "Projection stream session mismatch (expected \(expected.rawValue), found \(actual.rawValue))."
        case .sequenceGap(let expected, let actual):
            return "Projection stream is incomplete (expected seq \(expected), found \(actual))."
        case .alreadyStarted:
            return "Projection stream consumption has already started."
        case .initialReplayAlreadyLoaded:
            return "The projection pump initial replay has already been loaded."
        }
    }
}

public enum SessionProjectionPumpOutput<Snapshot: Sendable>: Sendable {
    case snapshot(Snapshot)
    case failed(SessionProjectionPumpFailure)
}

public struct CodeSessionProjectionSnapshot: Equatable, Sendable {
    public var identity: SessionProjectionIdentity
    public var throughSeq: Int
    public var dirtyDomains: SessionProjectionDirtyDomains
    public var projectionBatch:
        IntatisProjectionBatchPublication?
    public var items: [CodeItem]?
    public var permission: PermissionProjection?
    public var turnStats: TurnStatsProjection?
    public var agentState: String?
    public var barrierEnvelope: Envelope?

    public init(
        identity: SessionProjectionIdentity,
        throughSeq: Int,
        dirtyDomains: SessionProjectionDirtyDomains,
        projectionBatch:
            IntatisProjectionBatchPublication? = nil,
        items: [CodeItem]?,
        permission: PermissionProjection?,
        turnStats: TurnStatsProjection?,
        agentState: String?,
        barrierEnvelope: Envelope?
    ) {
        self.identity = identity
        self.throughSeq = throughSeq
        self.dirtyDomains = dirtyDomains
        self.projectionBatch = projectionBatch
        self.items = items
        self.permission = permission
        self.turnStats = turnStats
        self.agentState = agentState
        self.barrierEnvelope = barrierEnvelope
    }

    public static func == (
        lhs: CodeSessionProjectionSnapshot,
        rhs: CodeSessionProjectionSnapshot
    ) -> Bool {
        lhs.identity == rhs.identity
            && lhs.throughSeq == rhs.throughSeq
            && lhs.dirtyDomains
                == rhs.dirtyDomains
            && lhs.items == rhs.items
            && lhs.permission == rhs.permission
            && lhs.turnStats == rhs.turnStats
            && lhs.agentState == rhs.agentState
            && lhs.barrierEnvelope
                == rhs.barrierEnvelope
    }
}

public struct CoworkSessionProjectionSnapshot: Equatable, Sendable {
    public var identity: SessionProjectionIdentity
    public var throughSeq: Int
    public var dirtyDomains: SessionProjectionDirtyDomains
    public var projectionBatch:
        IntatisProjectionBatchPublication?
    public var items: [CodeItem]?
    public var cowork: CoworkProjection?
    public var permission: PermissionProjection?
    public var turnStats: TurnStatsProjection?
    /// Agent-scoped thread publications accumulated in this snapshot. The two
    /// lists are kept separate so the app can honor the process-wide execution
    /// trace policy without filtering the canonical item array on MainActor.
    public var threadAgentIDs: [AgentID]
    public var visibleThreadAgentIDs: [AgentID]
    public var barrierEnvelope: Envelope?

    public init(
        identity: SessionProjectionIdentity,
        throughSeq: Int,
        dirtyDomains: SessionProjectionDirtyDomains,
        projectionBatch:
            IntatisProjectionBatchPublication? = nil,
        items: [CodeItem]?,
        cowork: CoworkProjection?,
        permission: PermissionProjection?,
        turnStats: TurnStatsProjection?,
        threadAgentIDs: [AgentID] = [],
        visibleThreadAgentIDs: [AgentID] = [],
        barrierEnvelope: Envelope?
    ) {
        self.identity = identity
        self.throughSeq = throughSeq
        self.dirtyDomains = dirtyDomains
        self.projectionBatch = projectionBatch
        self.items = items
        self.cowork = cowork
        self.permission = permission
        self.turnStats = turnStats
        self.threadAgentIDs = threadAgentIDs
        self.visibleThreadAgentIDs = visibleThreadAgentIDs
        self.barrierEnvelope = barrierEnvelope
    }

    public static func == (
        lhs: CoworkSessionProjectionSnapshot,
        rhs: CoworkSessionProjectionSnapshot
    ) -> Bool {
        lhs.identity == rhs.identity
            && lhs.throughSeq == rhs.throughSeq
            && lhs.dirtyDomains
                == rhs.dirtyDomains
            && lhs.items == rhs.items
            && lhs.cowork == rhs.cowork
            && lhs.permission == rhs.permission
            && lhs.turnStats == rhs.turnStats
            && lhs.threadAgentIDs == rhs.threadAgentIDs
            && lhs.visibleThreadAgentIDs == rhs.visibleThreadAgentIDs
            && lhs.barrierEnvelope
                == rhs.barrierEnvelope
    }
}

/// Internal reducer contract shared by Code and Cowork projection pumps.
///
/// Implementations always fold every accepted envelope. Only publication is
/// coalesced, and only for consecutive assistant or Codex activity text
/// deltas.
public protocol SessionProjectionReducing: Sendable {
    associatedtype Snapshot: Equatable, Sendable

    static var allDirtyDomains:
        SessionProjectionDirtyDomains { get }

    init()

    mutating func apply(
        _ envelope: Envelope
    ) -> SessionProjectionDirtyDomains

    mutating func markRestoredPermissionsNeedsRerun()

    mutating func makeSnapshot(
        identity: SessionProjectionIdentity,
        throughSeq: Int,
        dirtyDomains: SessionProjectionDirtyDomains,
        projectionBatch:
            IntatisProjectionBatchPublication?,
        barrierEnvelope: Envelope?
    ) -> Snapshot
}

public struct CodeSessionProjectionState:
    SessionProjectionReducing,
    Equatable,
    Sendable
{
    public static let allDirtyDomains =
        SessionProjectionDirtyDomains.codeAll

    private var code = CodeProjection()
    private var permission = PermissionProjection()
    private var turnStats = TurnStatsProjection()
    private var agentState = "idle"

    public init() {}

    public mutating func apply(
        _ envelope: Envelope
    ) -> SessionProjectionDirtyDomains {
        let codeChange = code.apply(envelope)
        if envelope.event.isPresentationTextDelta {
            // These reducers intentionally receive the exact envelope too.
            // They are no-ops for presentation text deltas, so Cowork-only
            // work is not marked dirty during a text burst.
            permission.apply(envelope)
            turnStats.apply(envelope)
            return codeChange.didChangeItems ? .thread : []
        }

        let previousPermission = permission
        let previousTurnStats = turnStats
        let previousAgentState = agentState

        permission.apply(envelope)
        turnStats.apply(envelope)
        if case .agentStatus(let payload) = envelope.event {
            agentState = payload.state.rawValue
        }

        var dirty: SessionProjectionDirtyDomains = []
        if codeChange.didChangeItems { dirty.insert(.thread) }
        if permission != previousPermission {
            dirty.insert(.permission)
        }
        if turnStats != previousTurnStats {
            dirty.insert(.stats)
        }
        if agentState != previousAgentState {
            dirty.insert(.agentState)
        }
        return dirty
    }

    public mutating func markRestoredPermissionsNeedsRerun() {
        permission.markNeedsRerun()
    }

    public mutating func makeSnapshot(
        identity: SessionProjectionIdentity,
        throughSeq: Int,
        dirtyDomains: SessionProjectionDirtyDomains,
        projectionBatch:
            IntatisProjectionBatchPublication?,
        barrierEnvelope: Envelope?
    ) -> CodeSessionProjectionSnapshot {
        CodeSessionProjectionSnapshot(
            identity: identity,
            throughSeq: throughSeq,
            dirtyDomains: dirtyDomains,
            projectionBatch: projectionBatch,
            items: dirtyDomains.contains(.thread)
                ? code.items
                : nil,
            permission: dirtyDomains.contains(.permission)
                ? permission
                : nil,
            turnStats: dirtyDomains.contains(.stats)
                ? turnStats
                : nil,
            agentState: dirtyDomains.contains(.agentState)
                ? agentState
                : nil,
            barrierEnvelope: barrierEnvelope)
    }
}

public struct CoworkSessionProjectionState:
    SessionProjectionReducing,
    Equatable,
    Sendable
{
    public static let allDirtyDomains =
        SessionProjectionDirtyDomains.coworkAll

    private var code = CodeProjection(
        tracksAgentThreadIndex: true)
    private var cowork = CoworkProjection()
    private var permission = PermissionProjection()
    private var turnStats = TurnStatsProjection()
    private var pendingThreadAgentIDs: Set<AgentID> = []
    private var pendingVisibleThreadAgentIDs: Set<AgentID> = []

    public init() {}

    public mutating func apply(
        _ envelope: Envelope
    ) -> SessionProjectionDirtyDomains {
        let previousCowork = cowork
        cowork.apply(envelope)
        var codeChange = CodeProjectionChange.none
        if let settings = cowork.sessionSettings?.cowork {
            codeChange.formUnion(
                code.setDefaultConversationAgentID(
                    AgentID(rawValue: settings.mainAgentName)))
        }
        codeChange.formUnion(code.apply(envelope))
        pendingThreadAgentIDs.formUnion(codeChange.agentIDs)
        pendingVisibleThreadAgentIDs.formUnion(
            codeChange.visibleAgentIDs)

        if envelope.event.isPresentationTextDelta {
            permission.apply(envelope)
            turnStats.apply(envelope)
            return codeChange.didChangeItems ? .thread : []
        }

        let previousPermission = permission
        let previousTurnStats = turnStats
        permission.apply(envelope)
        turnStats.apply(envelope)

        var dirty: SessionProjectionDirtyDomains = []
        if codeChange.didChangeItems { dirty.insert(.thread) }
        if cowork != previousCowork { dirty.insert(.cowork) }
        if permission != previousPermission {
            dirty.insert(.permission)
        }
        if turnStats != previousTurnStats {
            dirty.insert(.stats)
        }
        return dirty
    }

    public mutating func markRestoredPermissionsNeedsRerun() {
        permission.markNeedsRerun()
    }

    public mutating func makeSnapshot(
        identity: SessionProjectionIdentity,
        throughSeq: Int,
        dirtyDomains: SessionProjectionDirtyDomains,
        projectionBatch:
            IntatisProjectionBatchPublication?,
        barrierEnvelope: Envelope?
    ) -> CoworkSessionProjectionSnapshot {
        let publishesAllThreadAgents =
            dirtyDomains == Self.allDirtyDomains
        let threadAgentIDs = publishesAllThreadAgents
            ? pendingThreadAgentIDs.union(code.indexedAgentIDs)
            : pendingThreadAgentIDs
        let visibleThreadAgentIDs = publishesAllThreadAgents
            ? pendingVisibleThreadAgentIDs.union(
                code.visibleIndexedAgentIDs)
            : pendingVisibleThreadAgentIDs
        pendingThreadAgentIDs.removeAll(keepingCapacity: true)
        pendingVisibleThreadAgentIDs.removeAll(keepingCapacity: true)
        return CoworkSessionProjectionSnapshot(
            identity: identity,
            throughSeq: throughSeq,
            dirtyDomains: dirtyDomains,
            projectionBatch: projectionBatch,
            // Cowork windows query only the currently selected agent's
            // continuous transcript below. Never publish every agent's
            // canonical item array to MainActor.
            items: nil,
            cowork: dirtyDomains.contains(.cowork)
                ? cowork
                : nil,
            permission: dirtyDomains.contains(.permission)
                ? permission
                : nil,
            turnStats: dirtyDomains.contains(.stats)
                ? turnStats
                : nil,
            threadAgentIDs: threadAgentIDs.sorted {
                $0.rawValue < $1.rawValue
            },
            visibleThreadAgentIDs: visibleThreadAgentIDs.sorted {
                $0.rawValue < $1.rawValue
            },
            barrierEnvelope: barrierEnvelope)
    }

    public func agentThreadSnapshot(
        identity: SessionProjectionIdentity,
        throughSeq: Int,
        agentID: AgentID,
        showsExecutionTrace: Bool,
        additionalItems: [CodeItem]
    ) -> CoworkAgentThreadSnapshot {
        let isWorking = cowork.runningTasks.contains {
            $0.assignee == agentID
        } || {
            guard let status = cowork.agentStatuses[agentID] else {
                return false
            }
            return status == .thinking || status == .tool
        }()
        return code.coworkAgentThreadSnapshot(
            agentID: agentID,
            showsExecutionTrace: showsExecutionTrace,
            additionalItems: additionalItems,
            projectedThroughSeq: throughSeq,
            projectionGeneration: identity.generation,
            isAgentWorking: isWorking)
    }
}

/// Folds one session's canonical EventLog stream on an actor and publishes a
/// bounded number of presentation snapshots.
///
/// Consecutive assistant or Codex activity text deltas use a fixed-window
/// leading/trailing cadence. Every other event is an immediate barrier. The
/// actor never changes EventLog persistence, subscriber order, or reducer
/// input.
public actor SessionProjectionPump<
    State: SessionProjectionReducing,
    PumpClock: Clock
> where PumpClock.Duration == Duration {
    public typealias Snapshot = State.Snapshot
    public typealias Output =
        SessionProjectionPumpOutput<Snapshot>

    private let identity: SessionProjectionIdentity
    private let cadence: Duration
    private let clock: PumpClock

    private struct PendingProjectionBatch {
        var interval:
            IntatisProjectionBatchInterval
        var receivedEnvelopeCount: UInt64 = 0
        var deltaCount: UInt64 = 0
        var foldDurationNanoseconds: UInt64 = 0
    }

    private var state = State()
    private var lastAppliedSeq = -1
    private var pendingDirty: SessionProjectionDirtyDomains = []
    private var pendingProjectionBatch:
        PendingProjectionBatch?
    private var lastPublicationInstant: PumpClock.Instant?
    private var scheduledPublication:
        Task<Void, Never>?
    private var scheduledGeneration: UInt64 = 0
    private var consumerTask: Task<Void, Never>?
    private var outputContinuation:
        AsyncStream<Output>.Continuation?
    private var failure: SessionProjectionPumpFailure?
    private var didLoadInitialReplay = false
    private var isFinished = false

    public init(
        identity: SessionProjectionIdentity,
        cadence: Duration = .milliseconds(50),
        clock: PumpClock
    ) {
        precondition(cadence > .zero)
        self.identity = identity
        self.cadence = cadence
        self.clock = clock
    }

    /// Builds the initial projection on the pump actor. Historical unresolved
    /// permission requests are non-actionable because no live continuation can
    /// survive process restoration.
    public func loadInitialReplay(
        _ envelopes: [Envelope]
    ) throws -> Snapshot {
        guard !didLoadInitialReplay else {
            throw SessionProjectionPumpFailure
                .initialReplayAlreadyLoaded
        }
        guard consumerTask == nil else {
            throw SessionProjectionPumpFailure.alreadyStarted
        }

        for envelope in envelopes {
            _ = try applyOrdered(envelope)
        }
        ensurePendingProjectionBatch()
        let restorationStart =
            DispatchTime.now().uptimeNanoseconds
        state.markRestoredPermissionsNeedsRerun()
        addPendingFoldDuration(
            since: restorationStart)
        didLoadInitialReplay = true
        pendingDirty = []
        cancelScheduledPublication()
        // The replay snapshot is not a streaming-delta cadence slot. The
        // first live delta remains a leading publication.
        lastPublicationInstant = nil
        return state.makeSnapshot(
            identity: identity,
            throughSeq: lastAppliedSeq,
            dirtyDomains: State.allDirtyDomains,
            projectionBatch:
                sealPendingProjectionBatch(
                    dirtyDomains:
                        State.allDirtyDomains,
                    createIfMissing: true),
            barrierEnvelope: nil)
    }

    /// Starts exactly one consumer for an EventLog stream positioned after the
    /// replay used by ``loadInitialReplay(_:)``. The returned stream carries
    /// projection publications rather than raw deltas.
    public func publications(
        consuming stream: AsyncStream<Envelope>
    ) throws -> AsyncStream<Output> {
        guard consumerTask == nil else {
            throw SessionProjectionPumpFailure.alreadyStarted
        }
        let pair = AsyncStream<Output>.makeStream(
            bufferingPolicy: .unbounded)
        outputContinuation = pair.continuation
        pair.continuation.onTermination = {
            [weak self] _ in
            Task {
                await self?.cancelWithoutPublication()
            }
        }
        consumerTask = Task { [weak self] in
            for await envelope in stream {
                guard let self else { return }
                await self.accept(envelope)
                if Task.isCancelled { break }
            }
            await self?.streamDidFinish()
        }
        return pair.stream
    }

    /// Folds a complete replay tail directly into the live actor, skipping
    /// already-applied envelopes and returning one full-domain snapshot. This
    /// is used by startup reconciliation that durably appends events before the
    /// already-created live stream has necessarily delivered them.
    public func synchronize(
        with completeReplay: [Envelope],
        markRestoredPermissionsNeedsRerun: Bool = false
    ) throws -> Snapshot {
        for envelope in completeReplay
            where envelope.seq > lastAppliedSeq {
            let dirty = try applyOrdered(envelope)
            pendingDirty.formUnion(dirty)
        }
        if markRestoredPermissionsNeedsRerun {
            ensurePendingProjectionBatch()
            let restorationStart =
                DispatchTime.now()
                    .uptimeNanoseconds
            state.markRestoredPermissionsNeedsRerun()
            addPendingFoldDuration(
                since: restorationStart)
        }
        cancelScheduledPublication()
        pendingDirty = []
        // A replay synchronization is not a streaming-delta cadence slot.
        // The first subsequently delivered live delta remains a leading
        // publication.
        lastPublicationInstant = nil
        return state.makeSnapshot(
            identity: identity,
            throughSeq: lastAppliedSeq,
            dirtyDomains: State.allDirtyDomains,
            projectionBatch:
                sealPendingProjectionBatch(
                    dirtyDomains:
                        State.allDirtyDomains,
                    createIfMissing: true),
            barrierEnvelope: nil)
    }

    /// Produces one full-domain attachment snapshot for a presentation that is
    /// becoming visible again. Any unpublished delta tail is folded into this
    /// snapshot, and the superseded timer generation is invalidated before the
    /// value leaves the actor. The next live delta therefore receives a fresh
    /// leading slot.
    public func flushNow() -> Snapshot? {
        guard !isFinished,
              failure == nil else {
            return nil
        }
        cancelScheduledPublication()
        pendingDirty = []
        lastPublicationInstant = nil
        return state.makeSnapshot(
            identity: identity,
            throughSeq: lastAppliedSeq,
            dirtyDomains:
                State.allDirtyDomains,
            projectionBatch:
                sealPendingProjectionBatch(
                    dirtyDomains:
                        State.allDirtyDomains,
                    createIfMissing: true),
            barrierEnvelope: nil)
    }

    /// Stops intake and returns the last unpublished partial snapshot, if one
    /// exists. Callers can commit it before cancelling their MainActor
    /// publication task.
    public func finishAndFlush() -> Snapshot? {
        guard !isFinished else { return nil }
        isFinished = true
        consumerTask?.cancel()
        consumerTask = nil
        cancelScheduledPublication()
        let snapshot = makePendingSnapshot(
            barrierEnvelope: nil)
        outputContinuation?.finish()
        outputContinuation = nil
        return snapshot
    }

    public func currentThroughSeq() -> Int {
        lastAppliedSeq
    }

    public func currentFailure()
        -> SessionProjectionPumpFailure?
    {
        failure
    }

    /// Applies one canonical envelope and returns an immediate publication when
    /// the cadence or barrier requires it. This narrow feed API also lets tests
    /// drive a manual Clock without wall-time sleeps.
    public func ingest(
        _ envelope: Envelope
    ) throws -> Snapshot? {
        guard !isFinished else { return nil }
        if let failure { throw failure }

        let dirty = try applyOrdered(envelope)
        pendingDirty.formUnion(dirty)
        if envelope.event.isPresentationTextDelta {
            return makeDeltaPublicationIfEligible()
        }
        cancelScheduledPublication()
        return makePublicationNow(
            barrierEnvelope: envelope,
            at: clock.now)
    }

    /// Emits a pending trailing snapshot once the injected Clock reaches the
    /// fixed-window deadline. Production uses the scheduled Clock sleep;
    /// deterministic tests can advance a manual Clock and call this directly.
    public func flushDuePublication() -> Snapshot? {
        guard !isFinished,
              failure == nil,
              pendingDirty.isEmpty == false,
              let lastPublicationInstant else {
            return nil
        }
        let deadline =
            lastPublicationInstant.advanced(
                by: cadence)
        let now = clock.now
        guard now >= deadline else {
            return nil
        }
        cancelScheduledPublication()
        return makePublicationNow(
            barrierEnvelope: nil,
            at: now)
    }

    private func accept(_ envelope: Envelope) {
        guard !isFinished, failure == nil else { return }
        do {
            if let snapshot =
                    try ingest(envelope) {
                outputContinuation?
                    .yield(.snapshot(snapshot))
            }
        } catch let pumpFailure
            as SessionProjectionPumpFailure {
            fail(pumpFailure)
        } catch {
            preconditionFailure(
                "SessionProjectionPump produced an unexpected error: \(error)")
        }
    }

    private func applyOrdered(
        _ envelope: Envelope
    ) throws -> SessionProjectionDirtyDomains {
        guard envelope.session == identity.sessionID else {
            throw SessionProjectionPumpFailure.sessionMismatch(
                expected: identity.sessionID,
                actual: envelope.session)
        }
        if envelope.seq <= lastAppliedSeq {
            // synchronize(with:) may overtake the already-created EventLog
            // stream. Exact duplicates from that stream are idempotent.
            return []
        }
        let expected = lastAppliedSeq + 1
        guard envelope.seq == expected else {
            throw SessionProjectionPumpFailure.sequenceGap(
                expected: expected,
                actual: envelope.seq)
        }
        ensurePendingProjectionBatch()
        let foldStart =
            DispatchTime.now().uptimeNanoseconds
        lastAppliedSeq = envelope.seq
        let dirty = state.apply(envelope)
        addPendingFoldDuration(since: foldStart)
        pendingProjectionBatch?
            .receivedEnvelopeCount &+= 1
        if envelope.event.isPresentationTextDelta {
            pendingProjectionBatch?
                .deltaCount &+= 1
        }
        return dirty
    }

    private func makeDeltaPublicationIfEligible()
        -> Snapshot?
    {
        let now = clock.now
        guard let lastPublicationInstant else {
            return makePublicationNow(
                barrierEnvelope: nil,
                at: now)
        }
        let deadline =
            lastPublicationInstant.advanced(by: cadence)
        if now >= deadline {
            cancelScheduledPublication()
            return makePublicationNow(
                barrierEnvelope: nil,
                at: now)
        }
        if outputContinuation != nil {
            schedulePublication(at: deadline)
        }
        return nil
    }

    private func makePublicationNow(
        barrierEnvelope: Envelope?,
        at instant: PumpClock.Instant
    ) -> Snapshot? {
        guard pendingDirty.isEmpty == false
                || barrierEnvelope != nil else {
            return nil
        }
        guard let snapshot = makePendingSnapshot(
            barrierEnvelope: barrierEnvelope)
        else {
            return nil
        }
        lastPublicationInstant = instant
        return snapshot
    }

    private func makePendingSnapshot(
        barrierEnvelope: Envelope?
    ) -> Snapshot? {
        guard pendingDirty.isEmpty == false
                || barrierEnvelope != nil else {
            return nil
        }
        let dirty = pendingDirty
        pendingDirty = []
        let projectionBatch =
            sealPendingProjectionBatch(
                dirtyDomains: dirty,
                createIfMissing: false)
        return state.makeSnapshot(
            identity: identity,
            throughSeq: lastAppliedSeq,
            dirtyDomains: dirty,
            projectionBatch:
                projectionBatch,
            barrierEnvelope: barrierEnvelope)
    }

    private func ensurePendingProjectionBatch() {
        guard pendingProjectionBatch == nil else {
            return
        }
        pendingProjectionBatch =
            PendingProjectionBatch(
                interval:
                    IntatisPerformanceDiagnostics
                        .shared
                        .beginProjectionBatch())
    }

    private func addPendingFoldDuration(
        since startNanoseconds: UInt64
    ) {
        let endNanoseconds =
            DispatchTime.now().uptimeNanoseconds
        let elapsed =
            endNanoseconds >= startNanoseconds
                ? endNanoseconds
                    - startNanoseconds
                : 0
        guard var batch =
                pendingProjectionBatch else {
            return
        }
        let (duration, overflow) =
            batch.foldDurationNanoseconds
                .addingReportingOverflow(elapsed)
        batch.foldDurationNanoseconds =
            overflow ? UInt64.max : duration
        pendingProjectionBatch = batch
    }

    private func sealPendingProjectionBatch(
        dirtyDomains:
            SessionProjectionDirtyDomains,
        createIfMissing: Bool
    ) -> IntatisProjectionBatchPublication? {
        if createIfMissing {
            ensurePendingProjectionBatch()
        }
        guard let batch =
                pendingProjectionBatch else {
            return nil
        }
        pendingProjectionBatch = nil
        return batch.interval.seal(
            metrics:
                IntatisProjectionBatchMetrics(
                    receivedEnvelopeCount:
                        batch
                            .receivedEnvelopeCount,
                    deltaCount:
                        batch.deltaCount,
                    throughSeq:
                        Int64(
                            clamping:
                                lastAppliedSeq),
                    dirtyMask:
                        UInt64(
                            dirtyDomains
                                .rawValue),
                    foldDurationNanoseconds:
                        batch
                            .foldDurationNanoseconds))
    }

    private func cancelPendingProjectionBatch() {
        let interval =
            pendingProjectionBatch?.interval
        pendingProjectionBatch = nil
        interval?.cancel()
    }

    private func schedulePublication(
        at deadline: PumpClock.Instant
    ) {
        guard scheduledPublication == nil else { return }
        scheduledGeneration &+= 1
        let generation = scheduledGeneration
        let clock = clock
        scheduledPublication = Task {
            do {
                try await clock.sleep(
                    until: deadline,
                    tolerance: nil)
            } catch {
                return
            }
            self.scheduledPublicationFired(
                generation: generation)
        }
    }

    private func scheduledPublicationFired(
        generation: UInt64
    ) {
        guard !isFinished,
              failure == nil,
              generation == scheduledGeneration else {
            return
        }
        scheduledPublication = nil
        if let snapshot = makePublicationNow(
            barrierEnvelope: nil,
            at: clock.now)
        {
            outputContinuation?
                .yield(.snapshot(snapshot))
        }
    }

    private func cancelScheduledPublication() {
        scheduledGeneration &+= 1
        scheduledPublication?.cancel()
        scheduledPublication = nil
    }

    private func streamDidFinish() {
        guard !isFinished else { return }
        cancelScheduledPublication()
        if let snapshot = makePendingSnapshot(
            barrierEnvelope: nil)
        {
            outputContinuation?.yield(.snapshot(snapshot))
        }
        isFinished = true
        consumerTask = nil
        outputContinuation?.finish()
        outputContinuation = nil
    }

    private func fail(
        _ pumpFailure: SessionProjectionPumpFailure
    ) {
        failure = pumpFailure
        isFinished = true
        consumerTask?.cancel()
        consumerTask = nil
        cancelScheduledPublication()
        cancelPendingProjectionBatch()
        outputContinuation?.yield(.failed(pumpFailure))
        outputContinuation?.finish()
        outputContinuation = nil
    }

    private func cancelWithoutPublication() {
        guard !isFinished else { return }
        isFinished = true
        consumerTask?.cancel()
        consumerTask = nil
        cancelScheduledPublication()
        cancelPendingProjectionBatch()
        outputContinuation = nil
    }
}

public extension SessionProjectionPump
where State == CoworkSessionProjectionState {
    /// Actor-isolated selected-agent transcript lookup used by each Cowork
    /// window. It reads the already-folded in-memory index and never replays
    /// EventLog or publishes unrelated agents' rows.
    func coworkAgentThreadSnapshot(
        agentID: AgentID,
        showsExecutionTrace: Bool,
        additionalItems: [CodeItem] = []
    ) -> CoworkAgentThreadSnapshot {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let snapshot = state.agentThreadSnapshot(
            identity: identity,
            throughSeq: lastAppliedSeq,
            agentID: agentID,
            showsExecutionTrace: showsExecutionTrace,
            additionalItems: additionalItems)
        let endedAt = DispatchTime.now().uptimeNanoseconds
        IntatisPerformanceDiagnostics.shared.recordCoworkAgentPageQuery(
            durationNanoseconds: endedAt >= startedAt
                ? endedAt - startedAt
                : 0,
            rowCount: snapshot.items.count,
            totalCount: snapshot.items.count)
        return snapshot
    }
}
