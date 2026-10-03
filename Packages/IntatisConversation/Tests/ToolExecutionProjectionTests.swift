import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisConversation

final class ToolExecutionProjectionTests: XCTestCase {
    private let session = SessionID(rawValue: "sess_tool_projection")
    private let taskID = TaskID(rawValue: "task_tool_projection")
    private let agent = AgentID(rawValue: "worker")

    private func envelope(_ seq: Int, _ event: Event) -> Envelope {
        Envelope(
            seq: seq,
            ts: Date(timeIntervalSince1970: Double(seq)),
            session: session,
            event: event)
    }

    private func prepared(id: String,
                          callID: String,
                          tool: String,
                          sideEffect: SideEffect) -> ToolExecutionPreparedPayload {
        ToolExecutionPreparedPayload(
            executionID: id,
            taskID: taskID,
            attempt: 1,
            toolCallID: callID,
            agent: agent,
            tool: tool,
            sideEffect: sideEffect)
    }

    func testCoworkProjectionExposesOnlyUnsettledExecutionsForRecovery() throws {
        let read = prepared(id: "exec_read", callID: "call_read", tool: "read_file", sideEffect: .readOnly)
        let write = prepared(id: "exec_write", callID: "call_write", tool: "write_file", sideEffect: .write)
        let projection = CoworkProjection.build(from: [
            envelope(1, .toolExecutionPrepared(read)),
            envelope(2, .toolExecutionPrepared(write)),
            envelope(3, .toolExecutionSettled(.init(
                prepared: read,
                outcome: .succeeded,
                reason: "result persisted"))),
        ])

        XCTAssertEqual(projection.toolExecutions.count, 2)
        XCTAssertEqual(projection.toolExecutions["exec_read"]?.settled?.outcome, .succeeded)
        XCTAssertEqual(projection.unresolvedToolExecutions.map(\.id), ["exec_write"])
        XCTAssertEqual(projection.unresolvedNonReplayableToolExecutions.map(\.id), ["exec_write"])
        XCTAssertEqual(
            try XCTUnwrap(projection.unresolvedToolExecutions.first).prepared.taskID,
            taskID)
    }

    func testSettledEventCanReconstructIndexWhenPrepareRecordIsMissing() throws {
        let write = prepared(id: "exec_orphan_settle", callID: "call_write", tool: "write_file", sideEffect: .write)
        let settled = ToolExecutionSettledPayload(prepared: write, outcome: .failed, reason: "tool failed")

        let projection = CoworkProjection.build(from: [
            envelope(5, .toolExecutionSettled(settled)),
        ])

        let execution = try XCTUnwrap(projection.toolExecutions[write.executionID])
        XCTAssertEqual(execution.prepared, write)
        XCTAssertEqual(execution.settled, settled)
        XCTAssertTrue(projection.unresolvedToolExecutions.isEmpty)
        XCTAssertEqual(
            projection.startedNonReplayableToolExecutions.map(\.id),
            [write.executionID],
            "legacy settlements without an effect disposition remain conservative")
    }

    func testSettledSuccessfulNonReplayableExecutionStillBlocksWholeTaskReplay() throws {
        let write = prepared(
            id: "exec_completed_write",
            callID: "call_completed_write",
            tool: "write_file",
            sideEffect: .write)
        let projection = CoworkProjection.build(from: [
            envelope(1, .toolExecutionPrepared(write)),
            envelope(2, .toolExecutionSettled(.init(
                prepared: write,
                outcome: .succeeded,
                effectDisposition: .committed))),
        ])

        XCTAssertTrue(projection.unresolvedNonReplayableToolExecutions.isEmpty)
        XCTAssertEqual(projection.startedNonReplayableToolExecutions.map(\.id), [write.executionID])
        XCTAssertEqual(
            projection.startedNonReplayableToolExecutions(taskID: taskID, attempt: 1).map(\.id),
            [write.executionID])
        XCTAssertTrue(
            projection.startedNonReplayableToolExecutions(taskID: taskID, attempt: 2).isEmpty)
    }

    func testTypedNotStartedSettlementDoesNotBlockWholeTaskReplay() {
        let update = prepared(
            id: "exec_stale_update",
            callID: "call_stale_update",
            tool: "task_update",
            sideEffect: .write)
        let projection = CoworkProjection.build(from: [
            envelope(1, .toolExecutionPrepared(update)),
            envelope(2, .toolExecutionSettled(.init(
                prepared: update,
                outcome: .failed,
                effectDisposition: .notStarted,
                reason: "stale_revision"))),
        ])

        XCTAssertTrue(projection.unresolvedToolExecutions.isEmpty)
        XCTAssertTrue(projection.unresolvedNonReplayableToolExecutions.isEmpty)
        XCTAssertTrue(projection.startedNonReplayableToolExecutions.isEmpty)
        XCTAssertTrue(
            projection.startedNonReplayableToolExecutions(taskID: taskID, attempt: 1).isEmpty)
    }

    func testUnknownAndLegacyFailedSettlementsRemainUncertain() {
        let explicitUnknown = prepared(
            id: "exec_explicit_unknown",
            callID: "call_explicit_unknown",
            tool: "write_file",
            sideEffect: .write)
        let legacyFailed = prepared(
            id: "exec_legacy_failed",
            callID: "call_legacy_failed",
            tool: "write_file",
            sideEffect: .write)
        let legacySucceeded = prepared(
            id: "exec_legacy_succeeded",
            callID: "call_legacy_succeeded",
            tool: "write_file",
            sideEffect: .write)
        let committed = prepared(
            id: "exec_committed",
            callID: "call_committed",
            tool: "write_file",
            sideEffect: .write)
        let projection = CoworkProjection.build(from: [
            envelope(1, .toolExecutionPrepared(explicitUnknown)),
            envelope(2, .toolExecutionSettled(.init(
                prepared: explicitUnknown,
                outcome: .failed,
                effectDisposition: .unknown))),
            envelope(3, .toolExecutionPrepared(legacyFailed)),
            envelope(4, .toolExecutionSettled(.init(
                prepared: legacyFailed,
                outcome: .failed))),
            envelope(5, .toolExecutionPrepared(legacySucceeded)),
            envelope(6, .toolExecutionSettled(.init(
                prepared: legacySucceeded,
                outcome: .succeeded))),
            envelope(7, .toolExecutionPrepared(committed)),
            envelope(8, .toolExecutionSettled(.init(
                prepared: committed,
                outcome: .failed,
                effectDisposition: .committed))),
        ])

        XCTAssertEqual(
            projection.uncertainNonReplayableToolExecutions.map(\.id),
            [explicitUnknown.executionID, legacyFailed.executionID])
        XCTAssertEqual(
            Set(projection.startedNonReplayableToolExecutions.map(\.id)),
            Set([
                explicitUnknown.executionID,
                legacyFailed.executionID,
                legacySucceeded.executionID,
                committed.executionID,
            ]))
    }

    func testMismatchedDuplicateOrContradictoryHistoryCannotProveNotStarted() {
        let mismatched = prepared(
            id: "exec_mismatched",
            callID: "call_original",
            tool: "task_update",
            sideEffect: .write)
        var foreignPrepare = mismatched
        foreignPrepare.toolCallID = "call_foreign"
        let repeated = prepared(
            id: "exec_repeated",
            callID: "call_repeated",
            tool: "task_update",
            sideEffect: .write)
        let contradictory = prepared(
            id: "exec_contradictory",
            callID: "call_contradictory",
            tool: "task_update",
            sideEffect: .write)
        let projection = CoworkProjection.build(from: [
            envelope(1, .toolExecutionPrepared(mismatched)),
            envelope(2, .toolExecutionSettled(.init(
                prepared: foreignPrepare,
                outcome: .failed,
                effectDisposition: .notStarted))),
            envelope(3, .toolExecutionPrepared(repeated)),
            envelope(4, .toolExecutionSettled(.init(
                prepared: repeated,
                outcome: .failed,
                effectDisposition: .notStarted))),
            envelope(5, .toolExecutionPrepared(repeated)),
            envelope(6, .toolExecutionPrepared(contradictory)),
            envelope(7, .toolExecutionSettled(.init(
                prepared: contradictory,
                outcome: .succeeded,
                effectDisposition: .notStarted))),
        ])

        XCTAssertEqual(
            projection.unresolvedNonReplayableToolExecutions.map(\.id),
            [mismatched.executionID, repeated.executionID, contradictory.executionID])
        XCTAssertEqual(
            projection.uncertainNonReplayableToolExecutions.map(\.id),
            [mismatched.executionID, repeated.executionID, contradictory.executionID])
        XCTAssertEqual(
            Set(projection.startedNonReplayableToolExecutions.map(\.id)),
            Set([mismatched.executionID, repeated.executionID, contradictory.executionID]))
    }

    func testConflictingTerminalSettlementCannotOverwriteFirstOutcome() throws {
        let write = prepared(
            id: "exec_conflicting_terminal",
            callID: "call_conflicting_terminal",
            tool: "write_file",
            sideEffect: .write)
        let committed = ToolExecutionSettledPayload(
            prepared: write,
            outcome: .succeeded,
            effectDisposition: .committed)
        let inventedNoEffect = ToolExecutionSettledPayload(
            prepared: write,
            outcome: .failed,
            effectDisposition: .notStarted)
        let idempotentEvents = [
            envelope(1, .toolExecutionPrepared(write)),
            envelope(2, .toolExecutionSettled(committed)),
            envelope(3, .toolExecutionSettled(committed)),
        ]
        let idempotentProjection = CoworkProjection.build(from: idempotentEvents)
        let idempotentExecution = try XCTUnwrap(
            idempotentProjection.toolExecutions[write.executionID])
        XCTAssertFalse(idempotentExecution.hasAmbiguousDurableHistory)
        XCTAssertEqual(idempotentExecution.settled, committed)
        XCTAssertEqual(idempotentExecution.settledSeq, 2)
        XCTAssertEqual(idempotentExecution.validatedSettlement, committed)

        let projection = CoworkProjection.build(from: idempotentEvents + [
            envelope(4, .toolExecutionSettled(inventedNoEffect)),
        ])

        let execution = try XCTUnwrap(projection.toolExecutions[write.executionID])
        XCTAssertEqual(execution.settled, committed, "the first terminal record remains the audit record")
        XCTAssertTrue(execution.hasAmbiguousDurableHistory)
        XCTAssertNil(execution.validatedSettlement)
        XCTAssertEqual(projection.unresolvedNonReplayableToolExecutions.map(\.id), [write.executionID])
        XCTAssertEqual(projection.uncertainNonReplayableToolExecutions.map(\.id), [write.executionID])
        XCTAssertEqual(projection.startedNonReplayableToolExecutions.map(\.id), [write.executionID])
    }

    func testChatAndCodeProjectionsIgnoreRecoveryBookkeepingEvents() {
        let execution = prepared(id: "exec_ignored", callID: "call_ignored", tool: "read_file", sideEffect: .readOnly)
        let events = [
            envelope(1, .toolExecutionPrepared(execution)),
            envelope(2, .toolExecutionSettled(.init(prepared: execution, outcome: .succeeded))),
        ]

        XCTAssertTrue(ConversationProjection.build(from: events).messages.isEmpty)
        XCTAssertTrue(CodeProjection.build(from: events).items.isEmpty)
    }
}
