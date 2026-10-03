import Foundation

/// Exact process-local identity for one session runtime.
///
/// A `SessionID` alone is not sufficient because different product surfaces
/// may legally use the same raw identifier while owning different runtimes.
public struct SessionRuntimeIdentity: Codable, Hashable, Sendable {
    public let kind: SessionKind
    public let sessionID: SessionID

    public init(kind: SessionKind, sessionID: SessionID) {
        self.kind = kind
        self.sessionID = sessionID
    }

    public static func == (lhs: SessionRuntimeIdentity,
                           rhs: SessionRuntimeIdentity) -> Bool {
        lhs.kind.rawValue == rhs.kind.rawValue && lhs.sessionID == rhs.sessionID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind.rawValue)
        hasher.combine(sessionID)
    }
}

/// One asynchronous stop request in an application-wide shutdown batch.
public struct SessionRuntimeStopRequest: Sendable {
    public let identity: SessionRuntimeIdentity
    private let operation: @Sendable () async -> Void

    public init(identity: SessionRuntimeIdentity,
                stop: @escaping @Sendable () async -> Void) {
        self.identity = identity
        operation = stop
    }

    fileprivate func stop() async {
        await operation()
    }
}

/// Injectable deadline used by ``BoundedSessionRuntimeShutdown``.
///
/// Tests can provide a manually triggered wait operation. Production callers
/// normally use ``after(_:)`` with a monotonic clock.
public struct SessionRuntimeShutdownDeadline: Sendable {
    private let waitOperation: @Sendable () async -> Void

    public init(waitUntilReached: @escaping @Sendable () async -> Void) {
        waitOperation = waitUntilReached
    }

    public static func after(_ duration: Duration) -> Self {
        let delay = duration < .zero ? .zero : duration
        return Self {
            do {
                try await ContinuousClock().sleep(for: delay)
            } catch {
                // The batch cancels this waiter when every runtime settles.
            }
        }
    }

    fileprivate func wait() async {
        await waitOperation()
    }
}

public enum SessionRuntimeShutdownDisposition: String, Codable, Sendable {
    case settled
    case timedOut
}

/// Immutable result of one bounded application-wide shutdown broadcast.
/// Identities are ordered by surface then raw session identifier so callers
/// and tests receive the same result regardless of task scheduling order.
public struct SessionRuntimeShutdownReport: Equatable, Sendable {
    public let settled: [SessionRuntimeIdentity]
    public let timedOut: [SessionRuntimeIdentity]

    public init(settled: [SessionRuntimeIdentity],
                timedOut: [SessionRuntimeIdentity]) {
        self.settled = settled
        self.timedOut = timedOut
    }

    public var isFullySettled: Bool { timedOut.isEmpty }

    public func disposition(for identity: SessionRuntimeIdentity)
        -> SessionRuntimeShutdownDisposition? {
        if settled.contains(identity) { return .settled }
        if timedOut.contains(identity) { return .timedOut }
        return nil
    }
}

/// A one-shot, single-flight shutdown batch for app-owned session runtimes.
///
/// All stop operations are started before the deadline waiter is started.
/// Operations run in unstructured tasks intentionally: at the deadline any
/// unacknowledged task is cancelled, but the result never awaits a child that
/// ignores cooperative cancellation. Repeated calls reuse the same in-flight
/// task or immutable final report, so a runtime receives at most one stop.
public actor BoundedSessionRuntimeShutdown {
    private enum State {
        case idle
        case running(Task<SessionRuntimeShutdownReport, Never>)
        case finished(SessionRuntimeShutdownReport)
    }

    private let requests: [SessionRuntimeStopRequest]
    private let deadline: SessionRuntimeShutdownDeadline
    private var state: State = .idle

    public init(requests: [SessionRuntimeStopRequest],
                deadline: SessionRuntimeShutdownDeadline) {
        self.requests = Self.canonicalRequests(requests)
        self.deadline = deadline
    }

    public func shutdown() async -> SessionRuntimeShutdownReport {
        switch state {
        case .finished(let report):
            return report
        case .running(let task):
            let report = await task.value
            state = .finished(report)
            return report
        case .idle:
            let requests = requests
            let deadline = deadline
            let task = Task {
                await Self.perform(requests: requests, deadline: deadline)
            }
            state = .running(task)
            let report = await task.value
            state = .finished(report)
            return report
        }
    }

    private static func canonicalRequests(_ requests: [SessionRuntimeStopRequest])
        -> [SessionRuntimeStopRequest] {
        var firstByIdentity: [SessionRuntimeIdentity: SessionRuntimeStopRequest] = [:]
        for request in requests where firstByIdentity[request.identity] == nil {
            firstByIdentity[request.identity] = request
        }
        return firstByIdentity.values.sorted {
            if $0.identity.kind.rawValue != $1.identity.kind.rawValue {
                return $0.identity.kind.rawValue < $1.identity.kind.rawValue
            }
            return $0.identity.sessionID.rawValue < $1.identity.sessionID.rawValue
        }
    }

    private static func perform(requests: [SessionRuntimeStopRequest],
                                deadline: SessionRuntimeShutdownDeadline) async
        -> SessionRuntimeShutdownReport {
        let identities = requests.map(\.identity)
        guard !requests.isEmpty else {
            return SessionRuntimeShutdownReport(settled: [], timedOut: [])
        }

        let race = SessionRuntimeShutdownRace(identities: identities)
        var stopTasks: [SessionRuntimeIdentity: Task<Void, Never>] = [:]

        // Create every stop task before starting the deadline waiter. No stop
        // acknowledgement is required before the remaining tasks are launched.
        for request in requests {
            stopTasks[request.identity] = Task {
                await request.stop()
                race.markSettled(request.identity)
            }
        }
        let deadlineTask = Task {
            await deadline.wait()
            race.reachDeadline()
        }
        race.install(stopTasks: stopTasks, deadlineTask: deadlineTask)

        return await race.wait()
    }
}

/// Lock-backed terminal gate used so the deadline can return without joining
/// uncooperative stop tasks. The first terminal classification of each exact
/// identity is immutable.
private final class SessionRuntimeShutdownRace: @unchecked Sendable {
    private let lock = NSLock()
    private let orderedIdentities: [SessionRuntimeIdentity]
    private var pending: Set<SessionRuntimeIdentity>
    private var report: SessionRuntimeShutdownReport?
    private var continuation: CheckedContinuation<SessionRuntimeShutdownReport, Never>?
    private var stopTasks: [SessionRuntimeIdentity: Task<Void, Never>] = [:]
    private var deadlineTask: Task<Void, Never>?

    init(identities: [SessionRuntimeIdentity]) {
        orderedIdentities = identities
        pending = Set(identities)
    }

    func install(stopTasks: [SessionRuntimeIdentity: Task<Void, Never>],
                 deadlineTask: Task<Void, Never>) {
        lock.lock()
        let existingReport = report
        if existingReport == nil {
            self.stopTasks = stopTasks
            self.deadlineTask = deadlineTask
        }
        lock.unlock()

        if let existingReport {
            deadlineTask.cancel()
            for identity in existingReport.timedOut {
                stopTasks[identity]?.cancel()
            }
        }
    }

    func markSettled(_ identity: SessionRuntimeIdentity) {
        lock.lock()
        guard report == nil, pending.remove(identity) != nil else {
            lock.unlock()
            return
        }
        guard pending.isEmpty else {
            lock.unlock()
            return
        }
        let resolved = makeReportLocked()
        report = resolved
        let continuation = self.continuation
        self.continuation = nil
        let deadlineTask = self.deadlineTask
        self.deadlineTask = nil
        stopTasks.removeAll()
        lock.unlock()

        deadlineTask?.cancel()
        continuation?.resume(returning: resolved)
    }

    func reachDeadline() {
        lock.lock()
        guard report == nil else {
            lock.unlock()
            return
        }
        let resolved = makeReportLocked()
        report = resolved
        let continuation = self.continuation
        self.continuation = nil
        let timedOutTasks = pending.compactMap { stopTasks[$0] }
        stopTasks.removeAll()
        deadlineTask = nil
        lock.unlock()

        // Cancellation is a best-effort signal only. Deliberately do not read
        // task.value or otherwise join a stop implementation that may ignore it.
        for task in timedOutTasks {
            task.cancel()
        }
        continuation?.resume(returning: resolved)
    }

    func wait() async -> SessionRuntimeShutdownReport {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let report {
                lock.unlock()
                continuation.resume(returning: report)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    private func makeReportLocked() -> SessionRuntimeShutdownReport {
        SessionRuntimeShutdownReport(
            settled: orderedIdentities.filter { !pending.contains($0) },
            timedOut: orderedIdentities.filter { pending.contains($0) })
    }
}
