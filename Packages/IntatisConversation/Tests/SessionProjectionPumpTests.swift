import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisConversation

final class SessionProjectionPumpTests:
    XCTestCase
{
    private let session =
        SessionID(rawValue: "projection_pump")
    private let agent =
        AgentID(rawValue: "main")
    private let message =
        MessageID(rawValue: "message")

    func testSnapshotSemanticEqualityIgnoresProjectionDiagnostics() {
        let identity =
            SessionProjectionIdentity(
                sessionID: session)
        let interval =
            IntatisPerformanceDiagnostics()
                .beginProjectionBatch()
        let diagnostics = interval.seal(
            metrics:
                IntatisProjectionBatchMetrics(
                    receivedEnvelopeCount: 2,
                    deltaCount: 1,
                    throughSeq: 4,
                    dirtyMask: 1,
                    foldDurationNanoseconds:
                        123))
        defer {
            diagnostics.finish(
                commitDurationNanoseconds: 456,
                published: false)
        }

        let codeWithoutDiagnostics =
            CodeSessionProjectionSnapshot(
                identity: identity,
                throughSeq: 4,
                dirtyDomains: .thread,
                items: [],
                permission: nil,
                turnStats: nil,
                agentState: nil,
                barrierEnvelope: nil)
        let codeWithDiagnostics =
            CodeSessionProjectionSnapshot(
                identity: identity,
                throughSeq: 4,
                dirtyDomains: .thread,
                projectionBatch:
                    diagnostics,
                items: [],
                permission: nil,
                turnStats: nil,
                agentState: nil,
                barrierEnvelope: nil)
        XCTAssertEqual(
            codeWithoutDiagnostics,
            codeWithDiagnostics)

        let coworkWithoutDiagnostics =
            CoworkSessionProjectionSnapshot(
                identity: identity,
                throughSeq: 4,
                dirtyDomains: .thread,
                items: [],
                cowork: nil,
                permission: nil,
                turnStats: nil,
                barrierEnvelope: nil)
        let coworkWithDiagnostics =
            CoworkSessionProjectionSnapshot(
                identity: identity,
                throughSeq: 4,
                dirtyDomains: .thread,
                projectionBatch:
                    diagnostics,
                items: [],
                cowork: nil,
                permission: nil,
                turnStats: nil,
                barrierEnvelope: nil)
        XCTAssertEqual(
            coworkWithoutDiagnostics,
            coworkWithDiagnostics)
    }

    func testNonDeltaIsImmediateBarrierAndFlushesPendingDelta()
        async throws
    {
        let clock = ManualProjectionClock()
        let identity = SessionProjectionIdentity(
            sessionID: session,
            generation: UUID(
                uuidString:
                    "00000000-0000-0000-0000-000000000001")!)
        let pump = SessionProjectionPump<
            CodeSessionProjectionState,
            ManualProjectionClock>(
                identity: identity,
                clock: clock)
        _ = try await pump.loadInitialReplay([])

        let leading = try await pump.ingest(
            envelope(
                0,
                .messageDelta(.init(
                    messageId: message,
                    role: .agent,
                    agent: agent,
                    textDelta: "A"))))
        XCTAssertEqual(
            leading?.items?.last?.body,
            "A")
        XCTAssertEqual(
            leading?.projectionBatch?
                .metrics
                .receivedEnvelopeCount,
            1)
        XCTAssertEqual(
            leading?.projectionBatch?
                .metrics.deltaCount,
            1)
        XCTAssertEqual(
            leading?.projectionBatch?
                .metrics.throughSeq,
            0)
        XCTAssertEqual(
            leading?.projectionBatch?
                .metrics.dirtyMask,
            UInt64(
                SessionProjectionDirtyDomains
                    .thread.rawValue))

        clock.advance(by: .milliseconds(10))
        let coalesced = try await pump.ingest(
            envelope(
                1,
                .messageDelta(.init(
                    messageId: message,
                    role: .agent,
                    agent: agent,
                    textDelta: "B"))))
        XCTAssertNil(coalesced)

        let barrierEnvelope = envelope(
            2,
            .turnStats(.init(
                totalTokens: 2,
                responseMessageID: message,
                agentID: agent)))
        let barrier =
            try await pump.ingest(
                barrierEnvelope)

        XCTAssertEqual(barrier?.throughSeq, 2)
        XCTAssertEqual(
            barrier?.barrierEnvelope,
            barrierEnvelope)
        XCTAssertEqual(
            barrier?.dirtyDomains,
            [.thread, .stats])
        XCTAssertEqual(
            barrier?.items?.last?.body,
            "AB")
        XCTAssertEqual(
            barrier?.items?.last?.turnStats?.totalTokens,
            2)
        XCTAssertEqual(
            barrier?.turnStats?
                .latest?.totalTokens,
            2)
        XCTAssertEqual(
            barrier?.projectionBatch?
                .metrics
                .receivedEnvelopeCount,
            2)
        XCTAssertEqual(
            barrier?.projectionBatch?
                .metrics.deltaCount,
            1)
        XCTAssertEqual(
            barrier?.projectionBatch?
                .metrics.throughSeq,
            2)
        XCTAssertEqual(
            barrier?.projectionBatch?
                .metrics.dirtyMask,
            UInt64(
                SessionProjectionDirtyDomains
                    .thread
                    .union(.stats)
                    .rawValue))
        let noTrailing =
            await pump.flushDuePublication()
        XCTAssertNil(noTrailing)
    }

    func testFiftyMillisecondFixedWindowKeepsLeadingAndTrailing()
        async throws
    {
        let clock = ManualProjectionClock()
        let pump = SessionProjectionPump<
            CodeSessionProjectionState,
            ManualProjectionClock>(
                identity:
                    SessionProjectionIdentity(
                        sessionID: session),
                cadence: .milliseconds(50),
                clock: clock)
        _ = try await pump.loadInitialReplay([])

        let first = try await pump.ingest(
            delta(seq: 0, text: "A"))
        XCTAssertEqual(
            first?.items?.last?.body,
            "A")

        clock.advance(by: .milliseconds(10))
        let second =
            try await pump.ingest(
                delta(seq: 1, text: "B"))
        XCTAssertNil(second)

        clock.advance(by: .milliseconds(39))
        let tooEarly =
            await pump.flushDuePublication()
        XCTAssertNil(tooEarly)

        clock.advance(by: .milliseconds(1))
        let trailing =
            await pump.flushDuePublication()
        XCTAssertEqual(
            trailing?.throughSeq,
            1)
        XCTAssertEqual(
            trailing?.items?.last?.body,
            "AB")

        // Continuous output does not open another immediate leading slot at
        // the same boundary; the next publication remains 50 ms away.
        let boundaryDelta =
            try await pump.ingest(
                delta(seq: 2, text: "C"))
        XCTAssertNil(boundaryDelta)
        clock.advance(by: .milliseconds(50))
        let nextWindow =
            try await pump.ingest(
                delta(seq: 3, text: "D"))
        XCTAssertEqual(
            nextWindow?.throughSeq,
            3)
        XCTAssertEqual(
            nextWindow?.items?.last?.body,
            "ABCD")
    }

    func testCodexActivityTextDeltaUsesCadenceAndCompletionBarrier()
        async throws
    {
        let clock = ManualProjectionClock()
        let pump = SessionProjectionPump<
            CodeSessionProjectionState,
            ManualProjectionClock>(
                identity: SessionProjectionIdentity(
                    sessionID: session),
                cadence: .milliseconds(50),
                clock: clock)
        _ = try await pump.loadInitialReplay([])

        let eventID =
            "codex-app-server:item/reasoning/textDelta:reasoning-1"
        let leading = try await pump.ingest(envelope(
            0,
            .codexAppServerEvent(.init(
                eventID: eventID,
                method: "item/reasoning/textDelta",
                agent: agent,
                turnID: "turn-1",
                itemID: "reasoning-1",
                textDelta: "first "))))
        XCTAssertEqual(leading?.items?.last?.body, "first ")
        XCTAssertEqual(
            leading?.projectionBatch?.metrics.deltaCount,
            1)

        clock.advance(by: .milliseconds(10))
        let coalesced = try await pump.ingest(envelope(
            1,
            .codexAppServerEvent(.init(
                eventID: eventID,
                method: "item/reasoning/textDelta",
                agent: agent,
                turnID: "turn-1",
                itemID: "reasoning-1",
                textDelta: "second"))))
        XCTAssertNil(coalesced)

        let completed = envelope(
            2,
            .codexAppServerEvent(.init(
                eventID:
                    "codex-app-server:item/completed:reasoning-1",
                method: "item/completed",
                agent: agent,
                turnID: "turn-1",
                itemID: "reasoning-1",
                itemType: "reasoning",
                status: "completed")))
        let barrier = try await pump.ingest(completed)

        XCTAssertEqual(barrier?.barrierEnvelope, completed)
        XCTAssertEqual(barrier?.items?.first?.body, "first second")
        XCTAssertEqual(
            barrier?.projectionBatch?.metrics.deltaCount,
            1)
        let noTrailing = await pump.flushDuePublication()
        XCTAssertNil(noTrailing)
    }

    func testScheduledTrailingPublicationUsesInjectedClockWithoutWallSleep()
        async throws
    {
        let clock = ManualProjectionClock()
        let pump = SessionProjectionPump<
            CodeSessionProjectionState,
            ManualProjectionClock>(
                identity:
                    SessionProjectionIdentity(
                        sessionID: session),
                cadence: .milliseconds(50),
                clock: clock)
        _ = try await pump.loadInitialReplay([])
        let input =
            AsyncStream<Envelope>.makeStream()
        let output =
            try await pump.publications(
                consuming: input.stream)
        var iterator =
            output.makeAsyncIterator()

        let leading =
            try await pump.ingest(
                delta(seq: 0, text: "A"))
        XCTAssertEqual(
            leading?.items?.last?.body,
            "A")
        clock.advance(by: .milliseconds(10))
        let pending =
            try await pump.ingest(
                delta(seq: 1, text: "B"))
        XCTAssertNil(pending)

        clock.advance(by: .milliseconds(40))
        guard case .snapshot(let trailing)? =
                await iterator.next() else {
            return XCTFail(
                "deadline should emit the trailing snapshot")
        }
        XCTAssertEqual(
            trailing.throughSeq,
            1)
        XCTAssertEqual(
            trailing.items?.last?.body,
            "AB")

        clock.advance(by: .milliseconds(10))
        _ = try await pump.ingest(
            delta(seq: 2, text: "C"))
        let barrierEnvelope =
            envelope(
                3,
                .turnStats(.init(
                    totalTokens: 3)))
        let barrier =
            try await pump.ingest(
                barrierEnvelope)
        XCTAssertEqual(
            barrier?.barrierEnvelope,
            barrierEnvelope)
        XCTAssertEqual(
            barrier?.items?.last?.body,
            "ABC")

        _ = await pump.finishAndFlush()
        input.continuation.finish()
        let afterFinish =
            await iterator.next()
        XCTAssertNil(afterFinish)
    }

    func testFiveHundredDeltaBurstStaysWithinPublicationBoundAndFoldsExactly()
        async throws
    {
        let clock = ManualProjectionClock()
        let pump = SessionProjectionPump<
            CoworkSessionProjectionState,
            ManualProjectionClock>(
                identity:
                    SessionProjectionIdentity(
                        sessionID: session),
                cadence: .milliseconds(50),
                clock: clock)
        _ = try await pump.loadInitialReplay([])

        var envelopes: [Envelope] = []
        var publications:
            [CoworkSessionProjectionSnapshot] = []
        for seq in 0..<500 {
            if seq > 0 {
                clock.advance(
                    by: .milliseconds(2))
            }
            let envelope =
                delta(seq: seq, text: "x")
            envelopes.append(envelope)
            if let snapshot =
                    try await pump.ingest(
                        envelope)
            {
                publications.append(snapshot)
            }
        }
        clock.advance(by: .milliseconds(2))
        if let trailing =
                await pump
                    .flushDuePublication()
        {
            publications.append(trailing)
        }

        let finalText =
            String(repeating: "x", count: 500)
        let completion = envelope(
            500,
            .messageCompleted(.init(
                messageId: message,
                role: .agent,
                agent: agent,
                text: finalText)))
        envelopes.append(completion)
        let terminalCandidate =
            try await pump.ingest(
                completion)
        let terminal =
            try XCTUnwrap(
                terminalCandidate)

        XCTAssertEqual(
            publications.count,
            21)
        XCTAssertEqual(
            publications.count + 1,
            22)
        XCTAssertTrue(
            publications.allSatisfy {
                $0.dirtyDomains == .thread
                    && $0.cowork == nil
                    && $0.barrierEnvelope == nil
            })
        XCTAssertEqual(
            terminal.barrierEnvelope,
            completion)
        XCTAssertNil(terminal.cowork)
        XCTAssertNil(terminal.items)
        let snapshot = await pump.coworkAgentThreadSnapshot(
            agentID: agent,
            showsExecutionTrace: false)
        XCTAssertEqual(snapshot.items.map(\.body), [finalText])
        let throughSeq =
            await pump.currentThroughSeq()
        XCTAssertEqual(throughSeq, 500)
    }

    func testDurableFiveHundredDeltaBurstReopensExactlyAndPumpMatchesFullReplay()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-projection-pump-\(UUID().uuidString)",
                isDirectory: true)
        let file = root.appendingPathComponent("events.jsonl")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let log = try EventLog(
            session: session,
            fileURL: file)
        let finalText =
            String(repeating: "x", count: 500)
        let events: [Event] =
            (0..<500).map { _ in
                .messageDelta(.init(
                    messageId: message,
                    role: .agent,
                    agent: agent,
                    textDelta: "x"))
            } + [
                .messageCompleted(.init(
                    messageId: message,
                    role: .agent,
                    agent: agent,
                    text: finalText)),
            ]
        _ = try await log.append(
            events,
            ts: Date(
                timeIntervalSince1970: 1))

        let reopened = try EventLog(
            session: session,
            fileURL: file)
        let durable = await reopened.replay()
        XCTAssertEqual(durable.count, 501)
        XCTAssertEqual(
            durable.map(\.seq),
            Array(0...500))

        let clock = ManualProjectionClock()
        let pump = SessionProjectionPump<
            CodeSessionProjectionState,
            ManualProjectionClock>(
                identity:
                    SessionProjectionIdentity(
                        sessionID: session),
                cadence: .milliseconds(50),
                clock: clock)
        _ = try await pump.loadInitialReplay([])

        var publications:
            [CodeSessionProjectionSnapshot] = []
        for (index, envelope) in
                durable.enumerated() {
            if index > 0 {
                clock.advance(
                    by: .milliseconds(2))
            }
            if let snapshot =
                    try await pump.ingest(
                        envelope) {
                publications.append(snapshot)
            }
        }

        XCTAssertLessThanOrEqual(
            publications.count,
            22)
        XCTAssertEqual(
            publications.last?.barrierEnvelope,
            durable.last)
        XCTAssertEqual(
            publications.last?.throughSeq,
            500)
        XCTAssertEqual(
            publications.last?.items,
            CodeProjection.build(
                from: durable).items)
        XCTAssertEqual(
            publications.last?.items?
                .first(where: {
                    $0.id == message.rawValue
                })?.body,
            finalText)
    }

    func testErrorAndCancelledTurnAreImmediateBarriersWithoutLosingPartialText()
        async throws
    {
        let clock = ManualProjectionClock()
        let pump = SessionProjectionPump<
            CodeSessionProjectionState,
            ManualProjectionClock>(
                identity:
                    SessionProjectionIdentity(
                        sessionID: session),
                cadence: .milliseconds(50),
                clock: clock)
        _ = try await pump.loadInitialReplay([])

        let first = delta(
            seq: 0,
            text: "partial-")
        let second = delta(
            seq: 1,
            text: "before-error")
        let providerError = envelope(
            2,
            .error(.init(
                code: "provider_failed",
                message: "bounded failure",
                fatal: false)))
        let afterError = delta(
            seq: 3,
            text: "-before-cancel")
        let cancelled = envelope(
            4,
            .turnOutcome(.init(
                turnID: TurnID(
                    rawValue: "turn-cancelled"),
                outcome: .interrupted,
                failureSource:
                    .turnCancelled,
                reason: "cancelled")))
        let ordered = [
            first,
            second,
            providerError,
            afterError,
            cancelled,
        ]

        _ = try await pump.ingest(first)
        clock.advance(
            by: .milliseconds(10))
        let coalescedBeforeError =
            try await pump.ingest(second)
        XCTAssertNil(coalescedBeforeError)
        let errorCandidate =
            try await pump.ingest(
                providerError)
        let errorSnapshot =
            try XCTUnwrap(
                errorCandidate)
        XCTAssertEqual(
            errorSnapshot.barrierEnvelope,
            providerError)
        XCTAssertEqual(
            errorSnapshot.items?
                .first(where: {
                    $0.id == message.rawValue
                })?.body,
            "partial-before-error")

        clock.advance(
            by: .milliseconds(10))
        let coalescedBeforeCancel =
            try await pump.ingest(
                afterError)
        XCTAssertNil(coalescedBeforeCancel)
        let cancelCandidate =
            try await pump.ingest(
                cancelled)
        let cancelSnapshot =
            try XCTUnwrap(
                cancelCandidate)
        XCTAssertEqual(
            cancelSnapshot.barrierEnvelope,
            cancelled)
        XCTAssertEqual(
            cancelSnapshot.throughSeq,
            4)
        XCTAssertEqual(
            cancelSnapshot.items,
            CodeProjection.build(
                from: ordered).items)
        XCTAssertEqual(
            cancelSnapshot.items?
                .first(where: {
                    $0.id == message.rawValue
                })?.body,
            "partial-before-error-before-cancel")
        let trailing =
            await pump.flushDuePublication()
        XCTAssertNil(trailing)
    }

    func testInterleavedAgentsShareOneSessionCadenceAndPreserveSequence()
        async throws
    {
        let clock = ManualProjectionClock()
        let pump = SessionProjectionPump<
            CoworkSessionProjectionState,
            ManualProjectionClock>(
                identity:
                    SessionProjectionIdentity(
                        sessionID: session),
                cadence: .milliseconds(50),
                clock: clock)
        _ = try await pump.loadInitialReplay([])
        let secondMessage =
            MessageID(rawValue: "message-two")
        let secondAgent =
            AgentID(rawValue: "worker")
        var ordered: [Envelope] = []
        var publications:
            [CoworkSessionProjectionSnapshot] = []

        for seq in 0..<500 {
            if seq > 0 {
                clock.advance(
                    by: .milliseconds(2))
            }
            let usesFirst =
                seq.isMultiple(of: 2)
            let item = envelope(
                seq,
                .messageDelta(.init(
                    messageId:
                        usesFirst
                            ? message
                            : secondMessage,
                    role: .agent,
                    agent:
                        usesFirst
                            ? agent
                            : secondAgent,
                    textDelta:
                        usesFirst ? "a" : "b")))
            ordered.append(item)
            if let snapshot =
                    try await pump.ingest(item) {
                publications.append(snapshot)
            }
        }
        clock.advance(
            by: .milliseconds(2))
        if let trailing =
                await pump.flushDuePublication() {
            publications.append(trailing)
        }

        XCTAssertLessThanOrEqual(
            publications.count,
            21)
        XCTAssertTrue(
            publications.allSatisfy {
                $0.dirtyDomains == .thread
                    && $0.cowork == nil
            })
        XCTAssertTrue(publications.allSatisfy { $0.items == nil })
        let mainSnapshot = await pump.coworkAgentThreadSnapshot(
            agentID: agent,
            showsExecutionTrace: false)
        let workerSnapshot = await pump.coworkAgentThreadSnapshot(
            agentID: secondAgent,
            showsExecutionTrace: false)
        XCTAssertEqual(mainSnapshot.items.last?.body.count, 250)
        XCTAssertEqual(workerSnapshot.items.last?.body.count, 250)
    }

    func testPermissionTaskAndTurnEventsAreImmediateOrderedBarriers()
        async throws
    {
        let clock = ManualProjectionClock()
        let pump = SessionProjectionPump<
            CoworkSessionProjectionState,
            ManualProjectionClock>(
                identity:
                    SessionProjectionIdentity(
                        sessionID: session),
                cadence: .milliseconds(50),
                clock: clock)
        _ = try await pump.loadInitialReplay([])
        let requestID =
            RequestID(rawValue: "request")
        let taskID =
            TaskID(rawValue: "task")
        let pendingDelta = delta(
            seq: 0,
            text: "pending")
        let permission = envelope(
            1,
            .permissionRequest(.init(
                requestId: requestID,
                agent: agent,
                tool: "read_file",
                args: "{}",
                risk: .medium,
                reason: "review")))
        let task = envelope(
            2,
            .taskStarted(.init(
                taskID: taskID,
                agent: agent,
                attempt: 2)))
        let turn = envelope(
            3,
            .turnOutcome(.init(
                turnID:
                    TurnID(
                        rawValue: "turn"),
                outcome: .completed,
                taskID: taskID,
                agentID: agent)))

        _ = try await pump.ingest(
            pendingDelta)
        clock.advance(
            by: .milliseconds(10))
        let permissionCandidate =
            try await pump.ingest(
                permission)
        let permissionSnapshot =
            try XCTUnwrap(
                permissionCandidate)
        XCTAssertEqual(
            permissionSnapshot.throughSeq,
            1)
        XCTAssertEqual(
            permissionSnapshot
                .barrierEnvelope,
            permission)
        XCTAssertEqual(
            permissionSnapshot.permission?
                .latest?.id,
            requestID)

        let taskCandidate =
            try await pump.ingest(task)
        let taskSnapshot =
            try XCTUnwrap(
                taskCandidate)
        XCTAssertEqual(
            taskSnapshot.throughSeq,
            2)
        XCTAssertEqual(
            taskSnapshot.barrierEnvelope,
            task)

        let turnCandidate =
            try await pump.ingest(turn)
        let turnSnapshot =
            try XCTUnwrap(
                turnCandidate)
        XCTAssertEqual(
            turnSnapshot.throughSeq,
            3)
        XCTAssertEqual(
            turnSnapshot.barrierEnvelope,
            turn)
        let trailing =
            await pump.flushDuePublication()
        XCTAssertNil(trailing)
    }

    func testDurablePermissionReviewFIFOFirstTerminalAndTaskAttemptsMatchFullReplay()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-projection-lifecycle-\(UUID().uuidString)",
                isDirectory: true)
        let file = root.appendingPathComponent(
            "events.jsonl")
        defer {
            try? FileManager.default
                .removeItem(at: root)
        }
        let log = try EventLog(
            session: session,
            fileURL: file)
        let firstRequestID =
            RequestID(rawValue: "request-first")
        let secondRequestID =
            RequestID(rawValue: "request-second")
        let firstRequest =
            permissionRequest(
                id: firstRequestID,
                approvalMode:
                    .automaticReviewer)
        let secondRequest =
            permissionRequest(
                id: secondRequestID,
                approvalMode: .manual)

        let firstRegistration =
            try await log
                .registerPermissionRequest(
                    firstRequest,
                    ts: Date(
                        timeIntervalSince1970: 1))
        let secondRegistration =
            try await log
                .registerPermissionRequest(
                    secondRequest,
                    ts: Date(
                        timeIntervalSince1970: 2))
        let duplicateRegistration =
            try await log
                .registerPermissionRequest(
                    firstRequest,
                    ts: Date(
                        timeIntervalSince1970: 3))
        XCTAssertTrue(
            firstRegistration.didAppend)
        XCTAssertTrue(
            secondRegistration.didAppend)
        XCTAssertFalse(
            duplicateRegistration.didAppend)
        XCTAssertEqual(
            duplicateRegistration.envelope,
            firstRegistration.envelope)

        let reviewTaskID =
            PermissionReviewTaskID(
                rawValue: "review-first")
        let reviewTask =
            PermissionReviewTask(
                id: reviewTaskID,
                sessionID: session,
                requestID: firstRequestID,
                requestingAgent: agent,
                reviewerAgent:
                    AgentID(
                        rawValue:
                            "permission-reviewer"),
                tool: "write_file",
                normalizedArgs: "{}",
                gate:
                    PermissionReviewGateSnapshot(
                        decision: .ask,
                        risk: .medium,
                        reason:
                            "automatic review required"),
                createdAt:
                    Date(
                        timeIntervalSince1970:
                            3),
                deadline:
                    Date(
                        timeIntervalSince1970:
                            63))
        let reviewRequested =
            try await log.append(
                .permissionReviewRequested(
                    .init(task: reviewTask)),
                ts: Date(
                    timeIntervalSince1970: 3))
        let reviewSettledPayload =
            PermissionReviewSettledPayload(
                reviewTaskID: reviewTaskID,
                requestID: firstRequestID,
                requestingAgent: agent,
                reviewerAgent:
                    reviewTask.reviewerAgent,
                reviewerModel:
                    ModelID(
                        rawValue:
                            "reviewer-model"),
                tool: "write_file",
                decision: .allow,
                risk: .medium,
                status: .allowed,
                reason: "review allowed",
                durationMillis: 25,
                settledAt:
                    Date(
                        timeIntervalSince1970:
                            4))
        let reviewSettled =
            try await log.append(
                .permissionReviewSettled(
                    reviewSettledPayload),
                ts: Date(
                    timeIntervalSince1970: 4))
        let firstResolution =
            PermissionResolvedPayload(
                requestId: firstRequestID,
                tool: "write_file",
                decision: .allow,
                risk: .medium,
                reason: "review allowed",
                source: .automaticReviewer,
                reviewTaskID: reviewTaskID,
                reviewStatus: .allowed)
        let settlement =
            try await log
                .settlePermissionRequest(
                    firstResolution,
                    ts: Date(
                        timeIntervalSince1970: 5))
        let duplicateSettlement =
            try await log
                .settlePermissionRequest(
                    firstResolution,
                    ts: Date(
                        timeIntervalSince1970: 6))
        XCTAssertTrue(settlement.didAppend)
        XCTAssertFalse(
            duplicateSettlement.didAppend)
        XCTAssertEqual(
            duplicateSettlement.envelope,
            settlement.envelope)

        var conflictingResolution =
            firstResolution
        conflictingResolution.decision = .deny
        conflictingResolution.reason =
            "late conflicting terminal"
        do {
            _ = try await log
                .settlePermissionRequest(
                    conflictingResolution,
                    ts: Date(
                        timeIntervalSince1970:
                            7))
            XCTFail(
                "a conflicting permission terminal must fail closed")
        } catch let failure as EventLogError {
            XCTAssertEqual(
                failure,
                .conflictingPermissionSettlement)
        }

        let worker =
            AgentID(rawValue: "worker")
        let taskID =
            TaskID(rawValue: "retry-task")
        let contract =
            TaskContract(
                id: taskID,
                issuer: agent,
                assignee: worker,
                objective: "Exercise retry projection.",
                roleHint: "test worker",
                expectedDeliverable:
                    "A deterministic result.",
                maxAttempts: 2)
        func queued(
            attempt: Int,
            reason: String
        ) -> TaskQueuedPayload {
            TaskQueuedPayload(
                contract: contract,
                rootTaskID: taskID,
                issuer: agent,
                assignee: worker,
                hopCount: 0,
                visitedAgents: [worker],
                attempt: attempt,
                reason: reason)
        }
        let taskEnvelopes =
            try await log.append(
                [
                    .taskCreated(
                        .init(
                            contract: contract)),
                    .taskQueued(
                        queued(
                            attempt: 1,
                            reason:
                                "initial attempt")),
                    .taskStarted(
                        .init(
                            taskID: taskID,
                            agent: worker,
                            attempt: 1)),
                    .taskFailed(
                        .init(
                            taskID: taskID,
                            agent: worker,
                            error:
                                "transient failure",
                            attempt: 1)),
                    .taskQueued(
                        queued(
                            attempt: 2,
                            reason:
                                "explicit retry")),
                    .taskStarted(
                        .init(
                            taskID: taskID,
                            agent: worker,
                            attempt: 2)),
                    .taskCompleted(
                        .init(
                            taskID: taskID,
                            agent: worker,
                            result: "done",
                            attempt: 2)),
                ],
                ts: Date(
                    timeIntervalSince1970: 8))

        let reopened = try EventLog(
            session: session,
            fileURL: file)
        let durable =
            try await reopened.replayChecked()
        XCTAssertEqual(
            durable.map(\.seq),
            Array(0..<durable.count))
        XCTAssertEqual(
            durable.count,
            12)
        XCTAssertEqual(
            reviewRequested.seq,
            2)
        XCTAssertEqual(
            reviewSettled.seq,
            3)
        XCTAssertEqual(
            settlement.envelope.seq,
            4)
        XCTAssertEqual(
            taskEnvelopes.map(\.seq),
            Array(5...11))
        XCTAssertEqual(
            durable.compactMap {
                envelope
                    -> PermissionResolvedPayload?
                in
                guard case .permissionResolved(
                    let payload) =
                        envelope.event else {
                    return nil
                }
                return payload
            },
            [firstResolution])

        let clock =
            ManualProjectionClock()
        let pump = SessionProjectionPump<
            CoworkSessionProjectionState,
            ManualProjectionClock>(
                identity:
                    SessionProjectionIdentity(
                        sessionID: session),
                cadence: .milliseconds(50),
                clock: clock)
        _ = try await pump
            .loadInitialReplay([])
        var barriers:
            [CoworkSessionProjectionSnapshot] =
                []
        for item in durable {
            let candidate =
                try await pump.ingest(item)
            let snapshot =
                try XCTUnwrap(candidate)
            XCTAssertEqual(
                snapshot.barrierEnvelope,
                item)
            barriers.append(snapshot)
        }
        XCTAssertEqual(
            barriers.map(\.barrierEnvelope),
            durable.map(Optional.some))

        let afterTwoRequests =
            barriers[1]
        XCTAssertEqual(
            afterTwoRequests.permission?
                .pending.map(\.id),
            [
                firstRequestID,
                secondRequestID,
            ])
        XCTAssertEqual(
            afterTwoRequests.permission?
                .latest?.id,
            firstRequestID)
        let afterReviewRequested =
            barriers[2]
        XCTAssertEqual(
            afterReviewRequested.permission?
                .latest?.state,
            .resolving)
        XCTAssertFalse(
            afterReviewRequested.permission?
                .latest?.state
                .isActionable == true)
        let afterReviewSettled =
            barriers[3]
        XCTAssertEqual(
            afterReviewSettled
                .dirtyDomains,
            [])
        XCTAssertNil(
            afterReviewSettled.permission)
        let afterResolved =
            barriers[4]
        XCTAssertEqual(
            afterResolved.permission?
                .pending.map(\.id),
            [secondRequestID])
        XCTAssertEqual(
            afterResolved.permission?
                .latest?.id,
            secondRequestID)
        XCTAssertEqual(
            afterResolved.permission?
                .latestResolved?.decision,
            .allow)
        XCTAssertEqual(
            afterResolved.permission?
                .latestResolved?
                .reviewTaskID,
            reviewTaskID)

        let finalCandidate =
            await pump.flushNow()
        let final =
            try XCTUnwrap(finalCandidate)
        let directCowork =
            CoworkProjection.build(
                from: durable)
        let directPermission =
            PermissionProjection.build(
                from: durable)
        let directStats =
            TurnStatsProjection.build(
                from: durable)

        XCTAssertEqual(
            final.throughSeq,
            durable.count - 1)
        XCTAssertEqual(
            final.dirtyDomains,
            .coworkAll)
        XCTAssertNil(final.barrierEnvelope)
        XCTAssertNil(final.items)
        let workerSnapshot = await pump.coworkAgentThreadSnapshot(
            agentID: worker,
            showsExecutionTrace: true)
        XCTAssertEqual(workerSnapshot.items.last?.body, "done")
        XCTAssertEqual(
            final.cowork,
            directCowork)
        XCTAssertEqual(
            final.permission,
            directPermission)
        XCTAssertEqual(
            final.turnStats,
            directStats)
        XCTAssertEqual(
            final.cowork?
                .tasks[taskID]?.status,
            .completed)
        XCTAssertEqual(
            final.cowork?
                .tasks[taskID]?.attempt,
            2)
        XCTAssertEqual(
            final.cowork?
                .tasks[taskID]?.result,
            "done")
        XCTAssertEqual(
            final.permission?
                .pending.map(\.id),
            [secondRequestID])
        XCTAssertEqual(
            final.permission?
                .resolved.map(\.requestId),
            [firstRequestID])
    }

    func testSessionAToBToARejectsOldTimerAndFlushesLatestAOnReattach()
        async throws
    {
        let sessionB =
            SessionID(rawValue: "projection-b")
        let identityA =
            SessionProjectionIdentity(
                sessionID: session,
                generation: UUID(
                    uuidString:
                        "00000000-0000-0000-0000-000000000101")!)
        let identityB =
            SessionProjectionIdentity(
                sessionID: sessionB,
                generation: UUID(
                    uuidString:
                        "00000000-0000-0000-0000-000000000102")!)
        let clockA =
            ManualProjectionClock()
        let clockB =
            ManualProjectionClock()
        let pumpA = SessionProjectionPump<
            CodeSessionProjectionState,
            ManualProjectionClock>(
                identity: identityA,
                cadence: .milliseconds(50),
                clock: clockA)
        let pumpB = SessionProjectionPump<
            CodeSessionProjectionState,
            ManualProjectionClock>(
                identity: identityB,
                cadence: .milliseconds(50),
                clock: clockB)
        _ = try await pumpA
            .loadInitialReplay([])
        _ = try await pumpB
            .loadInitialReplay([])
        var fence =
            SessionProjectionCommitFence(
                identity: identityA)

        let firstACandidate =
            try await pumpA.ingest(
                delta(seq: 0, text: "A"))
        let firstA = try XCTUnwrap(
            firstACandidate)
        XCTAssertTrue(
            fence.accept(
                identity: firstA.identity,
                throughSeq:
                    firstA.throughSeq))
        clockA.advance(
            by: .milliseconds(10))
        let pendingA =
            try await pumpA.ingest(
                delta(seq: 1, text: "2"))
        XCTAssertNil(pendingA)

        fence.replace(with: identityB)
        let firstBEnvelope = Envelope(
            seq: 0,
            ts: Date(),
            session: sessionB,
            event: .messageDelta(.init(
                messageId:
                    MessageID(
                        rawValue: "message-b"),
                role: .agent,
                agent:
                    AgentID(
                        rawValue: "agent-b"),
                textDelta: "B")))
        let firstBCandidate =
            try await pumpB.ingest(
                firstBEnvelope)
        let firstB = try XCTUnwrap(
            firstBCandidate)
        XCTAssertTrue(
            fence.accept(
                identity: firstB.identity,
                throughSeq:
                    firstB.throughSeq))

        clockA.advance(
            by: .milliseconds(40))
        let delayedACandidate =
            await pumpA
                .flushDuePublication()
        let delayedA = try XCTUnwrap(
            delayedACandidate)
        XCTAssertFalse(
            fence.accept(
                identity: delayedA.identity,
                throughSeq:
                    delayedA.throughSeq))

        fence.replace(with: identityA)
        let reattachedACandidate =
            await pumpA.flushNow()
        let reattachedA = try XCTUnwrap(
            reattachedACandidate)
        XCTAssertTrue(
            fence.accept(
                identity:
                    reattachedA.identity,
                throughSeq:
                    reattachedA.throughSeq))
        XCTAssertEqual(
            reattachedA.items?
                .first(where: {
                    $0.id == message.rawValue
                })?.body,
            "A2")

        let nextACandidate =
            try await pumpA.ingest(
                delta(seq: 2, text: "3"))
        let nextA = try XCTUnwrap(
            nextACandidate)
        XCTAssertEqual(
            nextA.throughSeq,
            2)
        XCTAssertEqual(
            nextA.items?
                .first(where: {
                    $0.id == message.rawValue
                })?.body,
            "A23")
    }

    func testCommitFenceRejectsOldSessionGenerationAndNonIncreasingSequence() {
        let first = SessionProjectionIdentity(
            sessionID: session,
            generation: UUID(
                uuidString:
                    "00000000-0000-0000-0000-000000000011")!)
        let replacement =
            SessionProjectionIdentity(
                sessionID: session,
                generation: UUID(
                    uuidString:
                        "00000000-0000-0000-0000-000000000012")!)
        var fence =
            SessionProjectionCommitFence(
                identity: first)

        XCTAssertTrue(
            fence.accept(
                identity: first,
                throughSeq: 5))
        XCTAssertFalse(
            fence.accept(
                identity: first,
                throughSeq: 5))
        XCTAssertFalse(
            fence.accept(
                identity: first,
                throughSeq: 4))
        let otherSession =
            SessionProjectionIdentity(
                sessionID:
                    SessionID(
                        rawValue: "other"),
                generation:
                    first.generation)
        XCTAssertFalse(
            fence.accept(
                identity: otherSession,
                throughSeq: 100))

        fence.replace(with: replacement)
        XCTAssertFalse(
            fence.accept(
                identity: first,
                throughSeq: 100))
        XCTAssertTrue(
            fence.accept(
                identity: replacement,
                throughSeq: 0))
    }

    func testRestoreSynchronizationSkipsStreamDuplicatesAndKeepsLiveLeading()
        async throws
    {
        let clock = ManualProjectionClock()
        let pump = SessionProjectionPump<
            CodeSessionProjectionState,
            ManualProjectionClock>(
                identity:
                    SessionProjectionIdentity(
                        sessionID: session),
                clock: clock)
        let first =
            envelope(
                0,
                .userMessage(.init(
                    text: "request")))
        _ = try await pump
            .loadInitialReplay([first])
        let restoredDelta =
            delta(seq: 1, text: "restored")
        let synchronized =
            try await pump.synchronize(
                with: [
                    first,
                    restoredDelta,
                ])
        XCTAssertEqual(
            synchronized.throughSeq,
            1)
        XCTAssertEqual(
            synchronized.items?.last?.body,
            "restored")

        let firstLive =
            try await pump.ingest(
                delta(seq: 2, text: "-live"))
        XCTAssertEqual(
            firstLive?.throughSeq,
            2)
        XCTAssertEqual(
            firstLive?.items?.last?.body,
            "restored-live")
    }

    func testPumpRejectsWrongSessionAndSequenceGap()
        async throws
    {
        let clock = ManualProjectionClock()
        let pump = SessionProjectionPump<
            CodeSessionProjectionState,
            ManualProjectionClock>(
                identity:
                    SessionProjectionIdentity(
                        sessionID: session),
                clock: clock)
        _ = try await pump.loadInitialReplay([])

        let otherSession =
            SessionID(rawValue: "other")
        do {
            _ = try await pump.ingest(
                Envelope(
                    seq: 0,
                    ts: Date(
                        timeIntervalSince1970:
                            0),
                    session: otherSession,
                    event: .userMessage(
                        .init(text: "wrong"))))
            XCTFail(
                "wrong-session envelope should fail")
        } catch let failure
            as SessionProjectionPumpFailure {
            XCTAssertEqual(
                failure,
                .sessionMismatch(
                    expected: session,
                    actual: otherSession))
        }

        do {
            _ = try await pump.ingest(
                delta(seq: 1, text: "gap"))
            XCTFail(
                "sequence gap should fail")
        } catch let failure
            as SessionProjectionPumpFailure {
            XCTAssertEqual(
                failure,
                .sequenceGap(
                    expected: 0,
                    actual: 1))
        }
    }

    private func delta(
        seq: Int,
        text: String
    ) -> Envelope {
        envelope(
            seq,
            .messageDelta(.init(
                messageId: message,
                role: .agent,
                agent: agent,
                textDelta: text)))
    }

    private func envelope(
        _ seq: Int,
        _ event: Event
    ) -> Envelope {
        Envelope(
            seq: seq,
            ts: Date(
                timeIntervalSince1970:
                    Double(seq)),
            session: session,
            event: event)
    }

    private func permissionRequest(
        id: RequestID,
        approvalMode:
            PermissionApprovalMode
    ) -> PermissionRequestPayload {
        PermissionRequestPayload(
            requestId: id,
            agent: agent,
            tool: "write_file",
            args: "{}",
            risk: .medium,
            reason:
                "write requires approval",
            approvalMode: approvalMode)
    }
}

private struct ManualProjectionClock:
    Clock,
    @unchecked Sendable
{
    struct Instant:
        InstantProtocol,
        Sendable
    {
        var offset: Duration

        func advanced(
            by duration: Duration
        ) -> Instant {
            Instant(
                offset:
                    offset + duration)
        }

        func duration(
            to other: Instant
        ) -> Duration {
            other.offset - offset
        }

        static func < (
            lhs: Instant,
            rhs: Instant
        ) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    final class Storage:
        @unchecked Sendable
    {
        struct Waiter {
            var id: UUID
            var deadline: Instant
            var continuation:
                CheckedContinuation<
                    Void,
                    any Error>
        }

        let lock = NSLock()
        var offset = Duration.zero
        var waiters: [Waiter] = []
        var cancelledWaiters:
            Set<UUID> = []

        func register(
            id: UUID,
            deadline: Instant,
            continuation:
                CheckedContinuation<
                    Void,
                    any Error>
        ) {
            lock.lock()
            if cancelledWaiters.remove(id)
                != nil {
                lock.unlock()
                continuation.resume(
                    throwing:
                        CancellationError())
                return
            }
            if offset >= deadline.offset {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(
                Waiter(
                    id: id,
                    deadline: deadline,
                    continuation:
                        continuation))
            lock.unlock()
        }

        func cancel(id: UUID) {
            lock.lock()
            if let index =
                    waiters.firstIndex(
                        where: {
                            $0.id == id
                        })
            {
                let waiter =
                    waiters.remove(
                        at: index)
                lock.unlock()
                waiter.continuation.resume(
                    throwing:
                        CancellationError())
                return
            }
            cancelledWaiters.insert(id)
            lock.unlock()
        }

        func advance(
            by duration: Duration
        ) {
            lock.lock()
            offset += duration
            let now = offset
            let due =
                waiters.filter {
                    $0.deadline.offset <= now
                }
            waiters.removeAll {
                $0.deadline.offset <= now
            }
            lock.unlock()
            for waiter in due {
                waiter.continuation
                    .resume()
            }
        }
    }

    private let storage =
        Storage()

    var now: Instant {
        storage.lock.lock()
        defer {
            storage.lock.unlock()
        }
        return Instant(
            offset: storage.offset)
    }

    var minimumResolution: Duration {
        .nanoseconds(1)
    }

    func sleep(
        until deadline: Instant,
        tolerance: Duration?
    ) async throws {
        guard now < deadline else {
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                continuation in
                storage.register(
                    id: id,
                    deadline: deadline,
                    continuation:
                        continuation)
            }
        } onCancel: {
            storage.cancel(id: id)
        }
    }

    func advance(
        by duration: Duration
    ) {
        storage.advance(by: duration)
    }
}
