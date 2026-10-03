import XCTest
import IntatisCore
@testable import IntatisProtocol

final class IntatisProtocolV02Tests: XCTestCase {

    private let enc = Envelope.makeEncoder()
    private let dec = Envelope.makeDecoder()

    private func roundTrip(_ env: Envelope, line: UInt = #line) throws {
        let data = try enc.encode(env)
        let back = try dec.decode(Envelope.self, from: data)
        XCTAssertEqual(back, env, line: line)
    }

    func testV02EventRoundTrips() throws {
        let s = SessionID(rawValue: "sess_x")
        let req = RequestID(rawValue: "req_1")
        let a = AgentID(rawValue: "Rokurics")
        try roundTrip(Envelope(seq: 1, ts: Date(timeIntervalSince1970: 1), session: s,
            event: .toolCall(.init(toolCallId: "tc1", agent: a, name: "read_file", args: "{\"path\":\"a.swift\"}"))))
        try roundTrip(Envelope(seq: 2, ts: Date(timeIntervalSince1970: 2), session: s,
            event: .toolResult(.init(toolCallId: "tc1", observation: "contents", truncated: false))))
        try roundTrip(Envelope(seq: 3, ts: Date(timeIntervalSince1970: 3), session: s,
            event: .permissionRequest(.init(requestId: req, tool: "apply_patch", args: "{}", risk: .medium, reason: "writes 1 file"))))
        try roundTrip(Envelope(seq: 4, ts: Date(timeIntervalSince1970: 4), session: s,
            event: .permissionResolved(.init(requestId: req, tool: "apply_patch", decision: .allow, risk: .low, reason: "ok"))))
        try roundTrip(Envelope(seq: 5, ts: Date(timeIntervalSince1970: 5), session: s,
            event: .patchProposed(.init(patchId: "p1", files: ["a.swift"], diff: "@@ -1 +1 @@"))))
        try roundTrip(Envelope(seq: 6, ts: Date(timeIntervalSince1970: 6), session: s,
            event: .agentStatus(.init(agent: a, state: .tool, task: "editing"))))
    }

    func testToolCallWireType() throws {
        let env = Envelope(seq: 1, ts: Date(timeIntervalSince1970: 1), session: SessionID(rawValue: "s"),
                           event: .toolCall(.init(toolCallId: "tc", name: "search_text", args: "{}")))
        let json = try JSONSerialization.jsonObject(with: try enc.encode(env)) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "tool_call")
    }

    func testToolCallAuditMetadataIsAdditiveAndRoundTrips() throws {
        let payload = ToolCallPayload(
            toolCallId: "tc-redacted",
            name: "spawn_agent",
            args: #"{"_intatis":"arguments_redacted"}"#,
            argsDigest: nil,
            argsCharacterCount: 241,
            argsRedacted: true)
        try roundTrip(Envelope(
            seq: 1,
            ts: Date(timeIntervalSince1970: 1),
            session: SessionID(rawValue: "s"),
            event: .toolCall(payload)))

        let legacy = #"{"toolCallId":"legacy","name":"read_file","args":"{}"}"#
        let decodedLegacy = try JSONDecoder().decode(
            ToolCallPayload.self,
            from: Data(legacy.utf8))
        XCTAssertNil(decodedLegacy.argsDigest)
        XCTAssertNil(decodedLegacy.argsCharacterCount)
        XCTAssertNil(decodedLegacy.argsRedacted)
    }

    func testV02CommandRoundTrips() throws {
        let cmds: [Command] = [
            .permissionRespond(.init(session: SessionID(rawValue: "s"),
                                     requestId: RequestID(rawValue: "r"), decision: .allow)),
            .agentAttach(.init(session: SessionID(rawValue: "s"), name: AgentID(rawValue: "Kikaria"),
                               path: "/tmp/ws", model: ModelID(rawValue: "m"))),
        ]
        let e = JSONEncoder()
        let d = JSONDecoder()
        for cmd in cmds {
            XCTAssertEqual(try d.decode(Command.self, from: try e.encode(cmd)), cmd)
        }
    }

    func testJSONValueRoundTrip() throws {
        let v = JSONValue.object([
            "type": .string("object"),
            "n": .number(3),
            "ok": .bool(true),
            "items": .array([.string("a"), .null]),
        ])
        let data = try JSONEncoder().encode(v)
        let back = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(back, v)
    }
}
