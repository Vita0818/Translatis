import XCTest
@testable import IntatisCore

final class BoundedSessionRuntimeShutdownTests: XCTestCase {
    func testEmptyBatchSettlesImmediately() async {
        let batch = BoundedSessionRuntimeShutdown(
            requests: [],
            deadline: .after(.seconds(1)))

        let report = await batch.shutdown()

        XCTAssertEqual(report, SessionRuntimeShutdownReport(settled: [], timedOut: []))
    }

    func testBroadcastUsesExactKindAndSessionIdentityBeforeWaitingForAcknowledgements() async {
        let sharedID = SessionID(rawValue: "shared")
        let chat = SessionRuntimeIdentity(kind: .chat, sessionID: sharedID)
        let code = SessionRuntimeIdentity(kind: .code, sessionID: sharedID)
        let cowork = SessionRuntimeIdentity(
            kind: .cowork,
            sessionID: SessionID(rawValue: "cowork_other"))
        let barrier = StopBarrier(expectedEntries: 3)
        let deadline = ManualDeadline()
        let batch = BoundedSessionRuntimeShutdown(
            requests: [chat, code, cowork].map { identity in
                SessionRuntimeStopRequest(identity: identity) {
                    await barrier.enterAndWait(identity)
                }
            },
            deadline: deadline.value)

        let shutdownTask = Task { await batch.shutdown() }
        await barrier.waitUntilAllEntered()

        let enteredIdentities = await barrier.enteredIdentities()
        let entryCount = await barrier.entryCount()
        XCTAssertEqual(enteredIdentities, Set([chat, code, cowork]))
        XCTAssertEqual(entryCount, 3)
        await barrier.releaseAll()

        let report = await shutdownTask.value
        XCTAssertEqual(report.settled, [chat, code, cowork])
        XCTAssertEqual(report.timedOut, [])
        XCTAssertTrue(report.isFullySettled)
        XCTAssertEqual(report.disposition(for: code), .settled)
    }

    func testDeadlineReturnsWithoutAwaitingStopThatIgnoresCancellation() async {
        let stubborn = SessionRuntimeIdentity(
            kind: .cowork,
            sessionID: SessionID(rawValue: "cowork_stubborn"))
        let stubbornBarrier = CancellationIgnoringStopBarrier()
        let deadline = ManualDeadline()
        let batch = BoundedSessionRuntimeShutdown(
            requests: [
                SessionRuntimeStopRequest(identity: stubborn) {
                    await stubbornBarrier.stop()
                },
            ],
            deadline: deadline.value)

        let shutdownTask = Task { await batch.shutdown() }
        await stubbornBarrier.waitUntilEntered()
        deadline.reach()

        let report = await shutdownTask.value
        XCTAssertEqual(report.settled, [])
        XCTAssertEqual(report.timedOut, [stubborn])
        XCTAssertFalse(report.isFullySettled)
        XCTAssertEqual(report.disposition(for: stubborn), .timedOut)
        let finishedBeforeRelease = await stubbornBarrier.hasFinished()
        XCTAssertFalse(finishedBeforeRelease)

        // The batch has already returned even though this stop was never
        // released. Releasing it only lets the test verify cancellation was
        // delivered and prevents a leaked test task.
        await stubbornBarrier.release()
        await stubbornBarrier.waitUntilFinished()
        let observedCancellation = await stubbornBarrier.observedCancellation()
        XCTAssertTrue(observedCancellation)
    }

    func testConcurrentAndRepeatedShutdownCallsAreSingleFlight() async {
        let identity = SessionRuntimeIdentity(
            kind: .chat,
            sessionID: SessionID(rawValue: "sess_single_flight"))
        let barrier = StopBarrier(expectedEntries: 1)
        let deadline = ManualDeadline()
        let batch = BoundedSessionRuntimeShutdown(
            requests: [
                SessionRuntimeStopRequest(identity: identity) {
                    await barrier.enterAndWait(identity)
                },
            ],
            deadline: deadline.value)

        async let first = batch.shutdown()
        async let second = batch.shutdown()
        await barrier.waitUntilAllEntered()
        let entryCountDuringFlight = await barrier.entryCount()
        XCTAssertEqual(entryCountDuringFlight, 1)
        await barrier.releaseAll()

        let reports = await [first, second]
        XCTAssertEqual(reports[0], reports[1])
        XCTAssertEqual(reports[0].settled, [identity])

        let repeated = await batch.shutdown()
        XCTAssertEqual(repeated, reports[0])
        let finalEntryCount = await barrier.entryCount()
        XCTAssertEqual(finalEntryCount, 1)
    }

    func testDuplicateExactIdentityUsesFirstStopOnly() async {
        let identity = SessionRuntimeIdentity(
            kind: .cowork,
            sessionID: SessionID(rawValue: "cowork_duplicate"))
        let first = CallRecorder()
        let duplicate = CallRecorder()
        let batch = BoundedSessionRuntimeShutdown(
            requests: [
                SessionRuntimeStopRequest(identity: identity) {
                    await first.record()
                },
                SessionRuntimeStopRequest(identity: identity) {
                    await duplicate.record()
                },
            ],
            deadline: .after(.seconds(1)))

        let report = await batch.shutdown()

        let firstCount = await first.count()
        let duplicateCount = await duplicate.count()
        XCTAssertEqual(report.settled, [identity])
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(duplicateCount, 0)
    }
}

private final class ManualDeadline: @unchecked Sendable {
    let value: SessionRuntimeShutdownDeadline
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        var captured: AsyncStream<Void>.Continuation?
        let stream = AsyncStream<Void> { captured = $0 }
        continuation = captured!
        value = SessionRuntimeShutdownDeadline {
            for await _ in stream {
                return
            }
        }
    }

    func reach() {
        continuation.yield(())
        continuation.finish()
    }
}

private actor CallRecorder {
    private var callCount = 0

    func record() {
        callCount += 1
    }

    func count() -> Int { callCount }
}

private actor StopBarrier {
    private let expectedEntries: Int
    private var entries: [SessionRuntimeIdentity] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(expectedEntries: Int) {
        self.expectedEntries = expectedEntries
    }

    func enterAndWait(_ identity: SessionRuntimeIdentity) async {
        entries.append(identity)
        if entries.count >= expectedEntries {
            let waiters = entryWaiters
            entryWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilAllEntered() async {
        guard entries.count < expectedEntries else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func releaseAll() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func enteredIdentities() -> Set<SessionRuntimeIdentity> { Set(entries) }
    func entryCount() -> Int { entries.count }
}

private actor CancellationIgnoringStopBarrier {
    private var entered = false
    private var finished = false
    private var cancelled = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    func stop() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }

        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        cancelled = Task.isCancelled
        finished = true
        let completions = finishWaiters
        finishWaiters.removeAll()
        completions.forEach { $0.resume() }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilFinished() async {
        guard !finished else { return }
        await withCheckedContinuation { continuation in
            finishWaiters.append(continuation)
        }
    }

    func hasFinished() -> Bool { finished }
    func observedCancellation() -> Bool { cancelled }
}
