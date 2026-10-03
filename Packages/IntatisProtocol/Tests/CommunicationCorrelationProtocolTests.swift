import XCTest
import Foundation
import IntatisCore
@testable import IntatisProtocol

final class CommunicationCorrelationProtocolTests: XCTestCase {
    func testLegacyInformationEventsDecodeWithoutCorrelationExtensions() throws {
        let legacyJSON = [
            #"{"seq":1,"ts":"2026-07-19T00:00:00Z","session":"sess_legacy","v":1,"type":"information_requested","payload":{"requestID":"msg_request","from":"main","to":"worker","question":"status?","mediated":true}}"#,
            #"{"seq":2,"ts":"2026-07-19T00:00:00Z","session":"sess_legacy","v":1,"type":"information_replied","payload":{"replyID":"msg_reply","inReplyTo":"msg_request","from":"worker","to":"main","content":"ready","mediated":true}}"#,
        ]

        let events = try legacyJSON.map {
            try Envelope.makeDecoder().decode(Envelope.self, from: Data($0.utf8)).event
        }
        guard case .informationRequested(let request) = events[0],
              case .informationReplied(let reply) = events[1] else {
            return XCTFail("legacy information events decoded to unexpected event types")
        }
        XCTAssertNil(request.conversationID)
        XCTAssertNil(request.basedOn)
        XCTAssertNil(reply.conversationID)
        XCTAssertEqual(reply.inReplyTo, request.requestID)
    }

    func testCorrelationFieldsRoundTrip() throws {
        let conversationID = MessageID(rawValue: "msg_conversation")
        let priorReplyID = MessageID(rawValue: "msg_prior_reply")
        let request = InformationRequestedPayload(
            requestID: MessageID(rawValue: "msg_follow_up"),
            conversationID: conversationID,
            basedOn: priorReplyID,
            from: AgentID(rawValue: "main"),
            to: AgentID(rawValue: "worker"),
            question: "next?",
            mediated: true)
        let reply = InformationRepliedPayload(
            replyID: MessageID(rawValue: "msg_answer"),
            inReplyTo: request.requestID,
            conversationID: conversationID,
            from: request.to,
            to: request.from,
            content: "answer",
            mediated: true)

        XCTAssertEqual(
            try JSONDecoder().decode(
                InformationRequestedPayload.self,
                from: JSONEncoder().encode(request)),
            request)
        XCTAssertEqual(
            try JSONDecoder().decode(
                InformationRepliedPayload.self,
                from: JSONEncoder().encode(reply)),
            reply)
    }
}
