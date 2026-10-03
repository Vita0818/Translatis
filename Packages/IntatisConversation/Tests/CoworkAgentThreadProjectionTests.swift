import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisConversation

final class CoworkAgentThreadProjectionTests: XCTestCase {
    private let session = SessionID(rawValue: "cowork_agent_thread")
    private let main = AgentID(rawValue: "main")
    private let worker = AgentID(rawValue: "worker")

    func testTypedAttributionTargetsMainWorkerToolAndBothA2AParticipants() {
        var projection = CodeProjection(tracksAgentThreadIndex: true)
        projection.setDefaultConversationAgentID(main)
        let mainSubmission = SubmissionID(rawValue: "submission-main")
        let workerSubmission = SubmissionID(rawValue: "submission-worker")
        let events: [Event] = [
            .userMessage(.init(
                text: "main request",
                submissionID: mainSubmission)),
            .userMessage(.init(
                text: "worker request",
                to: worker,
                submissionID: workerSubmission)),
            .messageCompleted(.init(
                messageId: MessageID(rawValue: "main-answer"),
                role: .agent,
                agent: main,
                text: "main answer")),
            .messageCompleted(.init(
                messageId: MessageID(rawValue: "worker-answer"),
                role: .agent,
                agent: worker,
                text: "worker answer")),
            .toolCall(.init(
                toolCallId: "worker-tool",
                agent: worker,
                name: "read_file",
                args: "{}")),
            .toolResult(.init(
                toolCallId: "worker-tool",
                observation: "tool output")),
            .agentToAgentMessage(.init(
                from: main,
                to: worker,
                content: "handoff",
                mediated: true)),
            .error(.init(
                code: "worker_failed",
                message: "worker error",
                submissionID: workerSubmission)),
        ]
        for (seq, event) in events.enumerated() {
            projection.apply(envelope(seq, event))
        }

        let mainSnapshot = projection.coworkAgentThreadSnapshot(
            agentID: main,
            showsExecutionTrace: false,
            projectedThroughSeq: events.count - 1,
            projectionGeneration: UUID(),
            isAgentWorking: false)
        let workerSnapshot = projection.coworkAgentThreadSnapshot(
            agentID: worker,
            showsExecutionTrace: false,
            projectedThroughSeq: events.count - 1,
            projectionGeneration: UUID(),
            isAgentWorking: false)
        let workerTraceSnapshot = projection.coworkAgentThreadSnapshot(
            agentID: worker,
            showsExecutionTrace: true,
            projectedThroughSeq: events.count - 1,
            projectionGeneration: UUID(),
            isAgentWorking: false)

        XCTAssertEqual(mainSnapshot.items.map(\.id), [
            mainSubmission.rawValue,
            "main-answer",
            "cowork_agent_thread:6:agent_to_agent",
        ])
        XCTAssertEqual(workerSnapshot.items.map(\.id), [
            workerSubmission.rawValue,
            "worker-answer",
            "cowork_agent_thread:6:agent_to_agent",
            "cowork_agent_thread:7:error",
        ])
        XCTAssertEqual(workerTraceSnapshot.items.map(\.id), [
            workerSubmission.rawValue,
            "worker-answer",
            "worker-tool",
            "worker-tool:result",
            "cowork_agent_thread:6:agent_to_agent",
            "cowork_agent_thread:7:error",
        ])
        XCTAssertEqual(
            projection.items.filter {
                $0.id == "cowork_agent_thread:6:agent_to_agent"
            }.count,
            1,
            "A2A body must stay canonical once while both indices reference it")
    }

    func testCoworkReplayUsesDurableMainForUntargetedLegacyUserMessage()
        async throws
    {
        let pump = SessionProjectionPump<
            CoworkSessionProjectionState,
            ContinuousClock>(
                identity: SessionProjectionIdentity(sessionID: session),
                clock: ContinuousClock())
        let settings = SessionSettingsUpdatedPayload(
            revision: 1,
            changeKind: .created,
            kind: .cowork,
            cowork: CoworkSessionSettings(
                sessionID: session,
                mainAgentName: "main"))
        _ = try await pump.loadInitialReplay([
            envelope(0, .userMessage(.init(text: "legacy main message"))),
            envelope(1, .sessionSettingsUpdated(settings)),
        ])

        let snapshot = await pump.coworkAgentThreadSnapshot(
            agentID: main,
            showsExecutionTrace: false)
        XCTAssertEqual(snapshot.items.map(\.body), ["legacy main message"])
    }

    func testWorkerDeltaPublishesOnlyWorkerThreadIdentity() async throws {
        let pump = SessionProjectionPump<
            CoworkSessionProjectionState,
            ContinuousClock>(
                identity: SessionProjectionIdentity(sessionID: session),
                clock: ContinuousClock())
        _ = try await pump.loadInitialReplay([])
        let candidate = try await pump.ingest(envelope(
            0,
            .messageDelta(.init(
                messageId: MessageID(rawValue: "worker-stream"),
                role: .agent,
                agent: worker,
                textDelta: "token"))))
        let snapshot = try XCTUnwrap(candidate)

        XCTAssertNil(snapshot.items)
        XCTAssertEqual(snapshot.threadAgentIDs, [worker])
        XCTAssertEqual(snapshot.visibleThreadAgentIDs, [worker])
        XCTAssertFalse(snapshot.visibleThreadAgentIDs.contains(main))
    }

    func testContinuousSnapshotReturnsAllSelectedAgentRows() {
        var projection = CodeProjection(tracksAgentThreadIndex: true)
        projection.setDefaultConversationAgentID(main)
        for index in 0..<1_000 {
            projection.apply(envelope(
                index * 2,
                .messageCompleted(.init(
                    messageId: MessageID(rawValue: "main-\(index)"),
                    role: .agent,
                    agent: main,
                    text: "main \(index)"))))
            projection.apply(envelope(
                index * 2 + 1,
                .messageCompleted(.init(
                    messageId: MessageID(rawValue: "worker-\(index)"),
                    role: .agent,
                    agent: worker,
                    text: "worker \(index)"))))
        }

        let snapshot = projection.coworkAgentThreadSnapshot(
            agentID: worker,
            showsExecutionTrace: false,
            projectedThroughSeq: 1_999,
            projectionGeneration: UUID(),
            isAgentWorking: true)
        XCTAssertEqual(snapshot.items.count, 1_000)
        XCTAssertEqual(snapshot.items.first?.id, "worker-0")
        XCTAssertEqual(snapshot.items.last?.id, "worker-999")
        XCTAssertTrue(snapshot.isAgentWorking)
    }

    func testContinuousSnapshotIncludesNewRowsWithoutDroppingHistory() {
        var projection = CodeProjection(tracksAgentThreadIndex: true)
        projection.setDefaultConversationAgentID(main)
        for index in 0..<20 {
            projection.apply(envelope(
                index,
                .messageCompleted(.init(
                    messageId: MessageID(rawValue: "worker-\(index)"),
                    role: .agent,
                    agent: worker,
                    text: "\(index)"))))
        }
        let before = projection.coworkAgentThreadSnapshot(
            agentID: worker,
            showsExecutionTrace: false,
            projectedThroughSeq: 19,
            projectionGeneration: UUID(),
            isAgentWorking: false)
        projection.apply(envelope(
            20,
            .messageCompleted(.init(
                messageId: MessageID(rawValue: "worker-20"),
                role: .agent,
                agent: worker,
                text: "20"))))
        let after = projection.coworkAgentThreadSnapshot(
            agentID: worker,
            showsExecutionTrace: false,
            projectedThroughSeq: 20,
            projectionGeneration: UUID(),
            isAgentWorking: false)

        XCTAssertEqual(before.items.count, 20)
        XCTAssertEqual(after.items.count, 21)
        XCTAssertEqual(after.items.prefix(20).map(\.id), before.items.map(\.id))
        XCTAssertEqual(after.items.last?.id, "worker-20")
    }

    func testContinuousSnapshotPreservesZeroOneSixteenAndSeventeenRows() {
        for count in [0, 1, 16, 17] {
            var projection = CodeProjection(tracksAgentThreadIndex: true)
            for index in 0..<count {
                projection.apply(envelope(
                    index,
                    .messageCompleted(.init(
                        messageId: MessageID(rawValue: "worker-\(count)-\(index)"),
                        role: .agent,
                        agent: worker,
                        text: "\(index)"))))
            }
            let snapshot = projection.coworkAgentThreadSnapshot(
                agentID: worker,
                showsExecutionTrace: false,
                projectedThroughSeq: count - 1,
                projectionGeneration: UUID(),
                isAgentWorking: false)

            XCTAssertEqual(snapshot.items.count, count)
            XCTAssertEqual(
                snapshot.items.first?.id,
                count == 0 ? nil : "worker-\(count)-0")
            XCTAssertEqual(
                snapshot.items.last?.id,
                count == 0 ? nil : "worker-\(count)-\(count - 1)")
        }
    }

    func testLaterTypedDeltaRepairsInitiallyUntypedAttribution() {
        var projection = CodeProjection(tracksAgentThreadIndex: true)
        let messageID = MessageID(rawValue: "late-agent-identity")
        projection.apply(envelope(
            0,
            .messageDelta(.init(
                messageId: messageID,
                role: .agent,
                textDelta: "first"))))
        projection.apply(envelope(
            1,
            .messageCompleted(.init(
                messageId: MessageID(rawValue: "worker-between"),
                role: .agent,
                agent: worker,
                text: "between"))))
        projection.apply(envelope(
            2,
            .messageDelta(.init(
                messageId: messageID,
                role: .agent,
                agent: worker,
                textDelta: " second"))))
        projection.setDefaultConversationAgentID(main)

        let workerSnapshot = projection.coworkAgentThreadSnapshot(
            agentID: worker,
            showsExecutionTrace: false,
            projectedThroughSeq: 2,
            projectionGeneration: UUID(),
            isAgentWorking: true)
        XCTAssertEqual(
            workerSnapshot.items.map(\.id),
            [messageID.rawValue, "worker-between"])
        XCTAssertEqual(
            workerSnapshot.items.map(\.body),
            ["first second", "between"])
        let mainSnapshot = projection.coworkAgentThreadSnapshot(
            agentID: main,
            showsExecutionTrace: false,
            projectedThroughSeq: 2,
            projectionGeneration: UUID(),
            isAgentWorking: false)
        XCTAssertTrue(mainSnapshot.items.isEmpty)
    }

    func testEightThousandItemFixtureSupportsOneThousandSelectedAgentSnapshots() {
        var projection = CodeProjection(tracksAgentThreadIndex: true)
        let agents = (0..<8).map {
            AgentID(rawValue: "agent-\($0)")
        }
        for agent in agents {
            for index in 0..<1_000 {
                let seq = projection.items.count
                projection.apply(envelope(
                    seq,
                    .messageCompleted(.init(
                        messageId: MessageID(
                            rawValue: "\(agent.rawValue)-\(index)"),
                        role: .agent,
                        agent: agent,
                        text: "item \(index)"))))
            }
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        for index in 0..<1_000 {
            let snapshot = projection.coworkAgentThreadSnapshot(
                agentID: agents[index % agents.count],
                showsExecutionTrace: false,
                projectedThroughSeq: 7_999,
                projectionGeneration: UUID(),
                isAgentWorking: false)
            XCTAssertEqual(snapshot.items.count, 1_000)
        }
        let endedAt = DispatchTime.now().uptimeNanoseconds
        XCTAssertLessThan(
            endedAt - startedAt,
            2_000_000_000,
            "1,000 selections must use the selected agent index, not scan all 8,000 rows")
    }

    private func envelope(_ seq: Int, _ event: Event) -> Envelope {
        Envelope(
            seq: seq,
            ts: Date(timeIntervalSince1970: Double(seq)),
            session: session,
            event: event)
    }
}
