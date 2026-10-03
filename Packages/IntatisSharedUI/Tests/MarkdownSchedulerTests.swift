import XCTest
@testable import IntatisSharedUI

private enum MarkdownSchedulerTestError: Error {
    case timedOut
}

private func waitForMarkdownSchedulerSnapshot<Key: Hashable & Sendable>(
    _ scheduler: IntatisLatestOnlyPermitScheduler<Key>,
    attempts: Int = 2_000,
    matching predicate: @Sendable (IntatisLatestOnlyPermitSchedulerSnapshot<Key>) -> Bool
) async throws -> IntatisLatestOnlyPermitSchedulerSnapshot<Key> {
    for _ in 0..<attempts {
        let snapshot = await scheduler.snapshot()
        if predicate(snapshot) {
            return snapshot
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw MarkdownSchedulerTestError.timedOut
}

final class MarkdownSchedulerTests: XCTestCase {
    func testRejectsNonPositiveBounds() {
        XCTAssertThrowsError(try IntatisLatestOnlyPermitScheduler<String>(
            maxConcurrentPermits: 0,
            maxPendingAcquires: 1
        )) { error in
            XCTAssertEqual(
                error as? IntatisLatestOnlyPermitSchedulerConfigurationError,
                .nonPositiveConcurrentMaximum(0))
        }
        XCTAssertThrowsError(try IntatisLatestOnlyPermitScheduler<String>(
            maxConcurrentPermits: 1,
            maxPendingAcquires: 0
        )) { error in
            XCTAssertEqual(
                error as? IntatisLatestOnlyPermitSchedulerConfigurationError,
                .nonPositivePendingMaximum(0))
        }
    }

    func testGlobalConcurrencyAndPendingCapacityStayBounded() async throws {
        let scheduler = try IntatisLatestOnlyPermitScheduler<Int>(
            maxConcurrentPermits: 2,
            maxPendingAcquires: 2)
        let firstCandidate = await scheduler.acquire(for: 1)
        let secondCandidate = await scheduler.acquire(for: 2)
        let first = try XCTUnwrap(firstCandidate)
        let second = try XCTUnwrap(secondCandidate)
        let thirdTask = Task { await scheduler.acquire(for: 3) }
        let fourthTask = Task { await scheduler.acquire(for: 4) }
        let saturated = try await waitForMarkdownSchedulerSnapshot(scheduler) {
            $0.activePermits == 2 && $0.pendingAcquires == 2
        }

        XCTAssertEqual(saturated.peakActivePermits, 2)
        XCTAssertEqual(saturated.peakPendingAcquires, 2)
        let rejected = await scheduler.acquire(for: 5)
        XCTAssertNil(rejected)

        let firstFinished = await scheduler.finish(first)
        XCTAssertTrue(firstFinished)
        let thirdCandidate = await thirdTask.value
        let third = try XCTUnwrap(thirdCandidate)
        let secondFinished = await scheduler.finish(second)
        XCTAssertTrue(secondFinished)
        let fourthCandidate = await fourthTask.value
        let fourth = try XCTUnwrap(fourthCandidate)
        let thirdFinished = await scheduler.finish(third)
        let fourthFinished = await scheduler.finish(fourth)
        XCTAssertTrue(thirdFinished)
        XCTAssertTrue(fourthFinished)

        let finished = await scheduler.snapshot()
        XCTAssertEqual(finished.activePermits, 0)
        XCTAssertEqual(finished.pendingAcquires, 0)
        XCTAssertEqual(finished.rejectedAtPendingCapacity, 1)
    }

    func testSameKeyKeepsOneRunningAndOneReplaceablePending() async throws {
        let scheduler = try IntatisLatestOnlyPermitScheduler<String>(
            maxConcurrentPermits: 1,
            maxPendingAcquires: 1)
        let firstCandidate = await scheduler.acquire(for: "message")
        let first = try XCTUnwrap(firstCandidate)
        let replacedTask = Task { await scheduler.acquire(for: "message") }
        _ = try await waitForMarkdownSchedulerSnapshot(scheduler) {
            $0.pendingAcquires == 1
        }
        let latestTask = Task { await scheduler.acquire(for: "message") }

        let replaced = await replacedTask.value
        XCTAssertNil(replaced)
        let backedUp = await scheduler.snapshot()
        XCTAssertEqual(backedUp.activePermits, 1)
        XCTAssertEqual(backedUp.pendingAcquires, 1)
        XCTAssertEqual(backedUp.replacedPendingAcquires, 1)
        XCTAssertEqual(backedUp.staledRunningPermits, 1)

        let firstFinished = await scheduler.finish(first)
        XCTAssertFalse(firstFinished)
        let latestCandidate = await latestTask.value
        let latest = try XCTUnwrap(latestCandidate)
        let latestFinished = await scheduler.finish(latest)
        XCTAssertTrue(latestFinished)

        let finished = await scheduler.snapshot()
        XCTAssertEqual(finished.publishableFinishes, 1)
        XCTAssertEqual(finished.suppressedSuccessfulFinishes, 1)
    }

    func testCancellationRemovesOnlyItsExactPendingGeneration() async throws {
        let scheduler = try IntatisLatestOnlyPermitScheduler<String>(
            maxConcurrentPermits: 1,
            maxPendingAcquires: 1)
        let blockerCandidate = await scheduler.acquire(for: "blocker")
        let blocker = try XCTUnwrap(blockerCandidate)
        let oldTask = Task { await scheduler.acquire(for: "message") }
        _ = try await waitForMarkdownSchedulerSnapshot(scheduler) {
            $0.pendingAcquires == 1
        }
        oldTask.cancel()
        let newTask = Task { await scheduler.acquire(for: "message") }

        let old = await oldTask.value
        XCTAssertNil(old)
        _ = try await waitForMarkdownSchedulerSnapshot(scheduler) {
            $0.pendingAcquires == 1 && $0.pendingKeys == ["message"]
        }
        let blockerFinished = await scheduler.finish(blocker)
        XCTAssertTrue(blockerFinished)
        let currentCandidate = await newTask.value
        let current = try XCTUnwrap(currentCandidate)
        let currentFinished = await scheduler.finish(current)
        XCTAssertTrue(currentFinished)
    }

    func testCancelAllDoesNotReleaseSynchronousWorkBeforeFinish() async throws {
        let scheduler = try IntatisLatestOnlyPermitScheduler<Int>(
            maxConcurrentPermits: 1,
            maxPendingAcquires: 1)
        let runningCandidate = await scheduler.acquire(for: 1)
        let running = try XCTUnwrap(runningCandidate)
        let pendingTask = Task { await scheduler.acquire(for: 2) }
        _ = try await waitForMarkdownSchedulerSnapshot(scheduler) {
            $0.pendingAcquires == 1
        }

        await scheduler.cancelAll()
        let cancelled = await scheduler.snapshot()
        XCTAssertEqual(cancelled.activePermits, 1)
        XCTAssertEqual(cancelled.pendingAcquires, 0)
        let pending = await pendingTask.value
        XCTAssertNil(pending)
        let runningFinished = await scheduler.finish(running)
        XCTAssertFalse(runningFinished)
        await scheduler.waitUntilIdle()
        let finished = await scheduler.snapshot()
        XCTAssertEqual(finished.activePermits, 0)
    }

    func testBurstCoalescesByKeyWithoutUnboundedPendingState() async throws {
        let scheduler = try IntatisLatestOnlyPermitScheduler<Int>(
            maxConcurrentPermits: 1,
            maxPendingAcquires: 20)
        let blockerCandidate = await scheduler.acquire(for: -1)
        let blocker = try XCTUnwrap(blockerCandidate)
        let tasks = (0..<200).map { index in
            Task { await scheduler.acquire(for: index % 20) }
        }
        let saturated = try await waitForMarkdownSchedulerSnapshot(
            scheduler,
            attempts: 10_000
        ) {
            // `acquireCalls` increments before the continuation is registered.
            // Actor reentrancy can therefore expose 201 calls while a few
            // acquires are still between those two steps. Wait until all 180
            // superseded generations have actually settled before cancelAll,
            // otherwise a late registration can outlive the test teardown.
            $0.acquireCalls == 201
                && $0.pendingAcquires == 20
                && $0.replacedPendingAcquires == 180
        }

        XCTAssertEqual(saturated.peakPendingAcquires, 20)
        XCTAssertEqual(saturated.replacedPendingAcquires, 180)
        await scheduler.cancelAll()
        for task in tasks {
            let permit = await task.value
            XCTAssertNil(permit)
        }
        let blockerFinished = await scheduler.finish(blocker)
        XCTAssertFalse(blockerFinished)
        await scheduler.waitUntilIdle()
        let finished = await scheduler.snapshot()
        XCTAssertEqual(finished.activePermits, 0)
        XCTAssertEqual(finished.pendingAcquires, 0)
        XCTAssertEqual(finished.cancelledPendingAcquires, 20)
    }
}
