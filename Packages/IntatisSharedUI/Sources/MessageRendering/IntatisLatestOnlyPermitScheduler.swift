import Foundation
import IntatisCore

/// A process-local, monotonically increasing identity assigned to an acquire request.
struct IntatisLatestOnlySubmissionID: Hashable, Comparable, RawRepresentable, Sendable {
  public let rawValue: UInt64

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// A scheduler-issued lease for one key and one submission generation.
///
/// A permit is intentionally output-free. The caller owns its operation and any non-Sendable
/// result. Copies are harmless because `finish` accepts a permit at most once.
struct IntatisLatestOnlyPermit<Key: Hashable & Sendable>: Sendable {
  public let key: Key
  public let submissionID: IntatisLatestOnlySubmissionID

  fileprivate let schedulerID: UUID
}

/// The caller-reported reason a permit's real work ended.
enum IntatisLatestOnlyFinishOutcome: Sendable {
  case success
  case cancelled
  case failed
}

/// A point-in-time, actor-isolated view of scheduler load and lifecycle counters.
struct IntatisLatestOnlyPermitSchedulerSnapshot<Key: Hashable & Sendable>: Sendable {
  public let activePermits: Int
  public let pendingAcquires: Int
  public let maxConcurrentPermits: Int
  public let maxPendingAcquires: Int
  public let peakActivePermits: Int
  public let peakPendingAcquires: Int
  public let activeKeys: Set<Key>
  public let pendingKeys: Set<Key>

  public let acquireCalls: UInt64
  public let issuedPermits: UInt64
  public let finishedPermits: UInt64
  public let publishableFinishes: UInt64
  public let replacedPendingAcquires: UInt64
  public let rejectedAtPendingCapacity: UInt64
  public let cancelledPendingAcquires: UInt64
  public let cancelledBeforeRegistration: UInt64
  public let cancelledBeforePermitHandoff: UInt64
  public let staledRunningPermits: UInt64
  public let schedulerCancelledRunningPermits: UInt64
  public let cancelledFinishes: UInt64
  public let failedFinishes: UInt64
  public let suppressedSuccessfulFinishes: UInt64
  public let invalidFinishes: UInt64
}

enum IntatisLatestOnlyPermitSchedulerConfigurationError: Error, Equatable, Sendable {
  case nonPositiveConcurrentMaximum(Int)
  case nonPositivePendingMaximum(Int)
}

/// An output-free, bounded, fair, latest-only permit scheduler.
///
/// The actor stores only keys, generation identities, permit state, pending acquire continuations,
/// ready-queue tickets, and metrics. It never stores or executes caller work, never receives an
/// operation result, and has no publication queue.
///
/// Each key owns at most one running permit and one replaceable pending acquire. Across keys the
/// actor issues at most `maxConcurrentPermits` permits and retains at most `maxPendingAcquires`
/// suspended acquires. A new acquire marks that key's running permit stale, but the global and
/// per-key slot remain occupied until its caller really invokes `finish`. Only a latest,
/// successful, non-cancelled finish returns `true`; that Boolean is the caller's authorization to
/// publish a result in the caller's own actor.
actor IntatisLatestOnlyPermitScheduler<Key: Hashable & Sendable> {
  public typealias Permit = IntatisLatestOnlyPermit<Key>
  public typealias Snapshot = IntatisLatestOnlyPermitSchedulerSnapshot<Key>

  private struct PendingAcquire: Sendable {
    let submissionID: IntatisLatestOnlySubmissionID
    let continuation: CheckedContinuation<Permit?, Never>
  }

  private struct RunningPermit: Sendable {
    let submissionID: IntatisLatestOnlySubmissionID
    var isStale: Bool
    var isSchedulerCancelled: Bool
  }

  private struct ReadyEntry: Sendable {
    let key: Key
    let ticket: UInt64
  }

  private let schedulerID = UUID()
  private let maxConcurrentPermits: Int
  private let maxPendingAcquires: Int

  private var nextSubmissionRawValue: UInt64 = 0
  private var nextReadyTicket: UInt64 = 0

  private var latestSubmissionByKey: [Key: IntatisLatestOnlySubmissionID] = [:]
  private var pendingByKey: [Key: PendingAcquire] = [:]
  private var runningByKey: [Key: RunningPermit] = [:]

  // Queue entries are invalidated by changing/removing the matching ticket. Pending replacement
  // retains the original ticket and therefore the key's FIFO position.
  private var readyQueue: [ReadyEntry] = []
  private var readyQueueHead = 0
  private var readyTicketByKey: [Key: UInt64] = [:]

  private var idleWaiters: [CheckedContinuation<Void, Never>] = []

  private var peakActivePermits = 0
  private var peakPendingAcquires = 0
  private var acquireCalls: UInt64 = 0
  private var issuedPermits: UInt64 = 0
  private var finishedPermits: UInt64 = 0
  private var publishableFinishes: UInt64 = 0
  private var replacedPendingAcquires: UInt64 = 0
  private var rejectedAtPendingCapacity: UInt64 = 0
  private var cancelledPendingAcquires: UInt64 = 0
  private var cancelledBeforeRegistration: UInt64 = 0
  private var cancelledBeforePermitHandoff: UInt64 = 0
  private var staledRunningPermits: UInt64 = 0
  private var schedulerCancelledRunningPermits: UInt64 = 0
  private var cancelledFinishes: UInt64 = 0
  private var failedFinishes: UInt64 = 0
  private var suppressedSuccessfulFinishes: UInt64 = 0
  private var invalidFinishes: UInt64 = 0

  public init(
    maxConcurrentPermits: Int,
    maxPendingAcquires: Int
  ) throws {
    guard maxConcurrentPermits > 0 else {
      throw IntatisLatestOnlyPermitSchedulerConfigurationError.nonPositiveConcurrentMaximum(
        maxConcurrentPermits
      )
    }
    guard maxPendingAcquires > 0 else {
      throw IntatisLatestOnlyPermitSchedulerConfigurationError.nonPositivePendingMaximum(
        maxPendingAcquires
      )
    }
    self.maxConcurrentPermits = maxConcurrentPermits
    self.maxPendingAcquires = maxPendingAcquires
  }

  /// Requests the latest permit for `key`.
  ///
  /// The call suspends while another permit for the same key is running or the global limit is
  /// saturated. A newer call for the same key resumes the replaced pending call with `nil`.
  /// Cancellation while pending removes only this exact generation and also returns `nil`. A new
  /// pending key is rejected with `nil` before altering scheduler state when pending capacity is
  /// full; replacing an existing pending key remains permitted.
  public func acquire(for key: Key) async -> Permit? {
    acquireCalls += 1
    guard !Task.isCancelled else {
      cancelledBeforeRegistration += 1
      return nil
    }

    let submissionID = makeSubmissionID()
    let permit = await withTaskCancellationHandler {
      await suspendAcquire(for: key, submissionID: submissionID)
    } onCancel: { [weak self] in
      Task { [weak self] in
        await self?.cancelPendingAcquire(
          for: key,
          submissionID: submissionID
        )
      }
    }

    // Cancellation can race with continuation resumption. If the permit was issued but has not
    // yet crossed back to the caller, no work can have started, so retiring it here is safe and
    // prevents a leaked slot.
    if Task.isCancelled, let permit {
      cancelledBeforePermitHandoff += 1
      _ = finishInternal(
        permit,
        outcome: .cancelled,
        callerWasCancelled: true
      )
      return nil
    }
    return permit
  }

  /// Releases a permit after the caller's real work has ended.
  ///
  /// Returns `true` only for a successful permit that is still the latest generation and was not
  /// cancelled. The scheduler also treats the finishing task's cancellation bit as cancellation;
  /// callers moving a permit to another task must pass `.cancelled` explicitly when appropriate.
  @discardableResult
  public func finish(
    _ permit: Permit,
    outcome: IntatisLatestOnlyFinishOutcome = .success
  ) -> Bool {
    finishInternal(
      permit,
      outcome: outcome,
      callerWasCancelled: Task.isCancelled
    )
  }

  /// Cancels all pending acquires and marks all active permits non-publishable.
  ///
  /// Active slots are deliberately retained. Their callers must still invoke `finish` after the
  /// corresponding real work exits; only then can queued work consume those slots.
  public func cancelAll() {
    for pending in pendingByKey.values {
      pending.continuation.resume(returning: nil)
      cancelledPendingAcquires += 1
    }
    pendingByKey.removeAll(keepingCapacity: true)
    readyTicketByKey.removeAll(keepingCapacity: true)
    readyQueue.removeAll(keepingCapacity: true)
    readyQueueHead = 0
    latestSubmissionByKey.removeAll(keepingCapacity: true)

    for key in Array(runningByKey.keys) {
      guard var running = runningByKey[key], !running.isSchedulerCancelled else {
        continue
      }
      running.isStale = true
      running.isSchedulerCancelled = true
      runningByKey[key] = running
      schedulerCancelledRunningPermits += 1
    }

    resumeIdleWaitersIfNeeded()
  }

  /// Suspends until neither active permits nor pending acquires remain.
  public func waitUntilIdle() async {
    guard !isIdle else {
      return
    }
    await withCheckedContinuation { continuation in
      idleWaiters.append(continuation)
    }
  }

  public func snapshot() -> Snapshot {
    Snapshot(
      activePermits: runningByKey.count,
      pendingAcquires: pendingByKey.count,
      maxConcurrentPermits: maxConcurrentPermits,
      maxPendingAcquires: maxPendingAcquires,
      peakActivePermits: peakActivePermits,
      peakPendingAcquires: peakPendingAcquires,
      activeKeys: Set(runningByKey.keys),
      pendingKeys: Set(pendingByKey.keys),
      acquireCalls: acquireCalls,
      issuedPermits: issuedPermits,
      finishedPermits: finishedPermits,
      publishableFinishes: publishableFinishes,
      replacedPendingAcquires: replacedPendingAcquires,
      rejectedAtPendingCapacity: rejectedAtPendingCapacity,
      cancelledPendingAcquires: cancelledPendingAcquires,
      cancelledBeforeRegistration: cancelledBeforeRegistration,
      cancelledBeforePermitHandoff: cancelledBeforePermitHandoff,
      staledRunningPermits: staledRunningPermits,
      schedulerCancelledRunningPermits: schedulerCancelledRunningPermits,
      cancelledFinishes: cancelledFinishes,
      failedFinishes: failedFinishes,
      suppressedSuccessfulFinishes: suppressedSuccessfulFinishes,
      invalidFinishes: invalidFinishes
    )
  }

  private var isIdle: Bool {
    runningByKey.isEmpty && pendingByKey.isEmpty
  }

  private func makeSubmissionID() -> IntatisLatestOnlySubmissionID {
    precondition(
      nextSubmissionRawValue < UInt64.max,
      "\(IntatisHostApplication.identity.storageName)LatestOnlySubmissionID space exhausted"
    )
    nextSubmissionRawValue += 1
    return IntatisLatestOnlySubmissionID(rawValue: nextSubmissionRawValue)
  }

  private func suspendAcquire(
    for key: Key,
    submissionID: IntatisLatestOnlySubmissionID
  ) async -> Permit? {
    await withCheckedContinuation { continuation in
      registerAcquire(
        for: key,
        submissionID: submissionID,
        continuation: continuation
      )
    }
  }

  private func registerAcquire(
    for key: Key,
    submissionID: IntatisLatestOnlySubmissionID,
    continuation: CheckedContinuation<Permit?, Never>
  ) {
    let incoming = PendingAcquire(
      submissionID: submissionID,
      continuation: continuation
    )
    if let replaced = pendingByKey[key] {
      pendingByKey[key] = incoming
      replacedPendingAcquires += 1
      replaced.continuation.resume(returning: nil)
    } else if pendingByKey.count >= maxPendingAcquires {
      // Reject before touching pending/latest/running state. Existing-key replacement takes the
      // branch above and therefore remains legal at capacity without moving its FIFO ticket.
      rejectedAtPendingCapacity += 1
      incoming.continuation.resume(returning: nil)
      return
    } else {
      pendingByKey[key] = incoming
    }

    latestSubmissionByKey[key] = submissionID

    if var running = runningByKey[key], !running.isStale {
      running.isStale = true
      runningByKey[key] = running
      staledRunningPermits += 1
    }

    peakPendingAcquires = max(peakPendingAcquires, pendingByKey.count)
    enqueueIfEligible(key)
    drainReadyQueue()
  }

  private func cancelPendingAcquire(
    for key: Key,
    submissionID: IntatisLatestOnlySubmissionID
  ) {
    guard let pending = pendingByKey[key],
      pending.submissionID == submissionID
    else {
      // A replaced generation's delayed cancellation must not touch the current pending acquire.
      return
    }

    pendingByKey.removeValue(forKey: key)
    invalidateReadyEntry(for: key)
    if latestSubmissionByKey[key] == submissionID {
      latestSubmissionByKey.removeValue(forKey: key)
    }
    cancelledPendingAcquires += 1
    pending.continuation.resume(returning: nil)
    drainReadyQueue()
  }

  private func finishInternal(
    _ permit: Permit,
    outcome: IntatisLatestOnlyFinishOutcome,
    callerWasCancelled: Bool
  ) -> Bool {
    guard permit.schedulerID == schedulerID,
      let running = runningByKey[permit.key],
      running.submissionID == permit.submissionID
    else {
      invalidFinishes += 1
      return false
    }

    runningByKey.removeValue(forKey: permit.key)
    finishedPermits += 1

    let wasCancelled = callerWasCancelled || outcome == .cancelled
    let isPublishable =
      outcome == .success && !wasCancelled && !running.isStale
      && !running.isSchedulerCancelled
      && latestSubmissionByKey[permit.key] == permit.submissionID

    switch outcome {
    case .success:
      if callerWasCancelled {
        cancelledFinishes += 1
      } else if isPublishable {
        publishableFinishes += 1
      } else {
        suppressedSuccessfulFinishes += 1
      }
    case .cancelled:
      cancelledFinishes += 1
    case .failed:
      failedFinishes += 1
    }

    if latestSubmissionByKey[permit.key] == permit.submissionID {
      latestSubmissionByKey.removeValue(forKey: permit.key)
    }

    enqueueIfEligible(permit.key)
    drainReadyQueue()
    return isPublishable
  }

  private func enqueueIfEligible(_ key: Key) {
    guard runningByKey[key] == nil,
      pendingByKey[key] != nil,
      readyTicketByKey[key] == nil
    else {
      return
    }

    precondition(nextReadyTicket < UInt64.max, "ready ticket space exhausted")
    nextReadyTicket += 1
    readyTicketByKey[key] = nextReadyTicket
    readyQueue.append(ReadyEntry(key: key, ticket: nextReadyTicket))
  }

  private func invalidateReadyEntry(for key: Key) {
    guard let ticket = readyTicketByKey.removeValue(forKey: key) else {
      return
    }

    // Cancellation can happen while all global slots are occupied. Physically removing the
    // unconsumed ticket prevents cancelled-key churn from becoming an unbounded metadata queue.
    if let index = readyQueue[readyQueueHead...].firstIndex(where: {
      $0.key == key && $0.ticket == ticket
    }) {
      readyQueue.remove(at: index)
    }
  }

  private func drainReadyQueue() {
    while runningByKey.count < maxConcurrentPermits,
      let key = dequeueReadyKey(),
      let pending = pendingByKey.removeValue(forKey: key)
    {
      let permit = Permit(
        key: key,
        submissionID: pending.submissionID,
        schedulerID: schedulerID
      )
      runningByKey[key] = RunningPermit(
        submissionID: pending.submissionID,
        isStale: false,
        isSchedulerCancelled: false
      )
      issuedPermits += 1
      peakActivePermits = max(peakActivePermits, runningByKey.count)
      pending.continuation.resume(returning: permit)
    }

    compactReadyQueueIfUseful()
    resumeIdleWaitersIfNeeded()
  }

  private func dequeueReadyKey() -> Key? {
    while readyQueueHead < readyQueue.count {
      let entry = readyQueue[readyQueueHead]
      readyQueueHead += 1

      guard readyTicketByKey[entry.key] == entry.ticket else {
        continue
      }
      readyTicketByKey.removeValue(forKey: entry.key)

      guard runningByKey[entry.key] == nil,
        pendingByKey[entry.key] != nil
      else {
        continue
      }
      return entry.key
    }
    return nil
  }

  private func compactReadyQueueIfUseful() {
    guard readyQueueHead > 0,
      readyQueueHead > 64 && readyQueueHead * 2 >= readyQueue.count
    else {
      return
    }
    readyQueue.removeFirst(readyQueueHead)
    readyQueueHead = 0
  }

  private func resumeIdleWaitersIfNeeded() {
    guard isIdle, !idleWaiters.isEmpty else {
      return
    }
    let waiters = idleWaiters
    idleWaiters.removeAll(keepingCapacity: true)
    for waiter in waiters {
      waiter.resume()
    }
  }
}
