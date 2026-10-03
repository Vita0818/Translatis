import XCTest
import IntatisCore
@testable import IntatisProtocol

final class IntatisProtocolTests: XCTestCase {

    private let enc = Envelope.makeEncoder()
    private let dec = Envelope.makeDecoder()

    private func roundTrip(_ env: Envelope, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try enc.encode(env)
        let back = try dec.decode(Envelope.self, from: data)
        XCTAssertEqual(back, env, file: file, line: line)
    }

    func testEnvelopeRoundTripAllEvents() throws {
        let s = SessionID(rawValue: "sess_x")
        let m = MessageID(rawValue: "msg_1")
        try roundTrip(Envelope(seq: 1, ts: Date(timeIntervalSince1970: 1_700_000_000), session: s,
                               event: .userMessage(.init(text: "hi",
                                                         to: AgentID(rawValue: "Rokurics"),
                                                         tags: ["Goal"],
                                                         goal: "hi"))))
        try roundTrip(Envelope(seq: 2, ts: Date(timeIntervalSince1970: 1_700_000_001), session: s,
                               event: .messageDelta(.init(
                                messageId: m,
                                role: .assistant,
                                textDelta: "he",
                                phase: .commentary))))
        try roundTrip(Envelope(seq: 3, ts: Date(timeIntervalSince1970: 1_700_000_002), session: s,
                               event: .messageCompleted(.init(
                                messageId: m,
                                role: .assistant,
                                text: "hello",
                                phase: .finalAnswer))))
        try roundTrip(Envelope(seq: 4, ts: Date(timeIntervalSince1970: 1_700_000_003), session: s,
                               event: .error(.init(code: "provider", message: "boom", fatal: true))))
        try roundTrip(Envelope(
            seq: 5,
            ts: Date(timeIntervalSince1970: 1_700_000_004),
            session: s,
            event: .codexAppServerEvent(.init(
                eventID: "codex-app-server:item/started:item_1",
                method: "item/started",
                agent: AgentID(rawValue: "main"),
                threadID: "thread_1",
                turnID: "turn_1",
                itemID: "item_1",
                itemType: "agentMessage",
                status: "inProgress",
                phase: .commentary,
                message: "Reconnecting... 1/5",
                details: "Upstream idle timeout exceeded",
                willRetry: true,
                fromModel: "model-a",
                toModel: "model-b",
                reason: "highRiskCyberActivity"))))
        try roundTrip(Envelope(
            seq: 6,
            ts: Date(timeIntervalSince1970: 1_700_000_005),
            session: s,
            event: .responsesUsage(.init(
                turnID: TurnID(rawValue: "codex:turn_1"),
                responseMessageID: MessageID(
                    rawValue: "codex:message_1"),
                agentID: AgentID(rawValue: "main"),
                inputTokens: 150,
                cachedInputTokens: 100,
                cacheWriteInputTokens: 10,
                outputTokens: 30,
                reasoningOutputTokens: 10,
                totalTokens: 180,
                durationMs: 1_234))))
    }

    func testEnvelopeWireShapeIsFlat() throws {
        let env = Envelope(seq: 7, ts: Date(timeIntervalSince1970: 1_700_000_000),
                           session: SessionID(rawValue: "sess_x"),
                           event: .messageDelta(.init(messageId: MessageID(rawValue: "msg_1"),
                                                      role: .assistant, textDelta: "x")))
        let data = try enc.encode(env)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["seq"] as? Int, 7)
        XCTAssertEqual(json["v"] as? Int, 1)
        XCTAssertEqual(json["type"] as? String, "message_delta")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(payload["textDelta"] as? String, "x")
        XCTAssertEqual(payload["role"] as? String, "assistant")
    }

    func testLegacyUserMessageWithoutGoalMetadataDecodes() throws {
        let json = """
        {"seq":1,"ts":"2023-11-14T22:13:20Z","session":"sess_legacy","v":1,"type":"user_message","payload":{"text":"hi"}}
        """

        let envelope = try dec.decode(Envelope.self, from: Data(json.utf8))

        guard case .userMessage(let payload) = envelope.event else {
            return XCTFail("expected user_message")
        }
        XCTAssertEqual(payload.text, "hi")
        XCTAssertNil(payload.tags)
        XCTAssertNil(payload.goal)
    }

    func testLegacyMessageEventsWithoutPhaseDecodeAsUnknown() throws {
        let deltaJSON = #"{"seq":1,"ts":"2023-11-14T22:13:20Z","session":"sess_legacy","v":1,"type":"message_delta","payload":{"messageId":"msg_legacy","role":"assistant","textDelta":"hi"}}"#
        let completedJSON = #"{"seq":2,"ts":"2023-11-14T22:13:21Z","session":"sess_legacy","v":1,"type":"message_completed","payload":{"messageId":"msg_legacy","role":"assistant","text":"hi"}}"#

        guard case .messageDelta(let delta) = try dec.decode(
            Envelope.self,
            from: Data(deltaJSON.utf8)).event else {
            return XCTFail("expected message_delta")
        }
        guard case .messageCompleted(let completed) = try dec.decode(
            Envelope.self,
            from: Data(completedJSON.utf8)).event else {
            return XCTFail("expected message_completed")
        }

        XCTAssertNil(delta.phase)
        XCTAssertNil(completed.phase)
    }

    func testNewCoworkLifecycleEventsRoundTripThroughEnvelope() throws {
        let session = SessionID(rawValue: "sess_cowork_lifecycle")
        let agent = AgentID(rawValue: "worker")
        let taskID = TaskID(rawValue: "task_1")
        let messageID = MessageID(rawValue: "msg_1")
        let metadata = CoworkEventMetadata(
            taskID: taskID,
            agentID: agent,
            scope: .task,
            visibility: .task,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let cases: [(event: Event, wireType: String)] = [
            (
                .agentMessageConsumed(.init(
                    messageID: messageID,
                    agent: agent,
                    taskID: taskID,
                    metadata: metadata)),
                "agent_message_consumed"
            ),
            (
                .agentMessageDiscarded(.init(
                    messageID: MessageID(rawValue: "msg_cancelled"),
                    agent: agent,
                    reason: "owning Goal run was cancelled",
                    taskID: taskID,
                    goalID: GoalID(rawValue: "goal_cancelled"),
                    continuationRunID: ContinuationRunID(rawValue: "run_cancelled"),
                    metadata: metadata)),
                "agent_message_discarded"
            ),
            (
                .workspaceLeaseRevoked(.init(
                    agent: agent,
                    leaseID: WorkspaceLeaseID(rawValue: "wlease_1"),
                    reason: "task completed",
                    metadata: metadata)),
                "workspace_lease_revoked"
            ),
            (
                .taskCancelled(.init(
                    taskID: taskID,
                    agent: agent,
                    reason: "cancelled by user",
                    attempt: 2,
                    metadata: metadata)),
                "task_cancelled"
            ),
        ]

        for (index, testCase) in cases.enumerated() {
            let envelope = Envelope(
                seq: index,
                ts: Date(timeIntervalSince1970: 1_700_000_100 + Double(index)),
                session: session,
                event: testCase.event)
            let data = try enc.encode(envelope)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

            XCTAssertEqual(json["type"] as? String, testCase.wireType)
            XCTAssertEqual(try dec.decode(Envelope.self, from: data), envelope)
        }
    }

    func testCommandRoundTrip() throws {
        let cmds: [Command] = [
            .sessionCreate(.init(kind: .chat, title: "Hello")),
            .sessionResume(.init(session: SessionID(rawValue: "sess_x"), fromSeq: 12)),
            .sessionList,
            .messageSend(.init(session: SessionID(rawValue: "sess_x"), text: "hi"))
        ]
        let e = JSONEncoder()
        let d = JSONDecoder()
        for cmd in cmds {
            let data = try e.encode(cmd)
            let back = try d.decode(Command.self, from: data)
            XCTAssertEqual(back, cmd)
        }
    }

    func testCommandMethodString() throws {
        let data = try JSONEncoder().encode(
            Command.messageSend(.init(session: SessionID(rawValue: "s"), text: "hi")))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["method"] as? String, "message.send")
    }
}
