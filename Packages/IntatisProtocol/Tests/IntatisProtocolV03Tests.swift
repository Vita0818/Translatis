import XCTest
import IntatisCore
@testable import IntatisProtocol

final class IntatisProtocolV03Tests: XCTestCase {

    private let enc = Envelope.makeEncoder()
    private let dec = Envelope.makeDecoder()

    private func rt(_ env: Envelope, line: UInt = #line) throws {
        XCTAssertEqual(try dec.decode(Envelope.self, from: try enc.encode(env)), env, line: line)
    }

    func testV03EventRoundTrips() throws {
        let s = SessionID(rawValue: "s")
        let a = AgentID(rawValue: "Rokurics")
        let b = AgentID(rawValue: "Kikaria")
        try rt(Envelope(seq: 1, ts: Date(timeIntervalSince1970: 1), session: s,
            event: .agentAttached(.init(agent: a, path: "/ws/a", model: ModelID(rawValue: "m"), profile: "reviewed"))))
        try rt(Envelope(seq: 2, ts: Date(timeIntervalSince1970: 2), session: s,
            event: .agentDetached(.init(agent: a))))
        try rt(Envelope(seq: 3, ts: Date(timeIntervalSince1970: 3), session: s,
            event: .agentMessage(.init(agent: a, messageId: MessageID(rawValue: "m1"), content: "hi"))))
        try rt(Envelope(seq: 4, ts: Date(timeIntervalSince1970: 4), session: s,
            event: .agentToAgentMessage(.init(from: a, to: b, content: "summary only", mediated: true))))
        try rt(Envelope(seq: 5, ts: Date(timeIntervalSince1970: 5), session: s,
            event: .permissionReview(.init(agent: b, tool: "apply_patch", reviewerModel: "reviewer-x",
                                           decision: .allow, risk: .low, reason: "ok"))))
    }

    func testAgentToAgentWireType() throws {
        let env = Envelope(seq: 1, ts: Date(timeIntervalSince1970: 1), session: SessionID(rawValue: "s"),
                           event: .agentToAgentMessage(.init(from: AgentID(rawValue: "A"),
                                                             to: AgentID(rawValue: "B"),
                                                             content: "x", mediated: true)))
        let json = try JSONSerialization.jsonObject(with: try enc.encode(env)) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "agent_to_agent_message")
    }

    func testProfileSetCommandRoundTrip() throws {
        let cmd = Command.profileSet(.init(session: SessionID(rawValue: "s"),
                                           agent: AgentID(rawValue: "A"), mode: "autopilot"))
        XCTAssertEqual(try JSONDecoder().decode(Command.self, from: try JSONEncoder().encode(cmd)), cmd)
        let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(cmd)) as! [String: Any]
        XCTAssertEqual(json["method"] as? String, "profile.set")
    }
}
