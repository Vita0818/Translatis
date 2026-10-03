import XCTest
import IntatisCore
@testable import IntatisProtocol

final class SubmissionProtocolTests: XCTestCase {
    private let session = SessionID(rawValue: "sess_submission")
    private let submissionID = SubmissionID(rawValue: "sub_immutable")

    func testSubmissionEventsAndCorrelatedOutputRoundTrip() throws {
        let events: [Event] = [
            .userMessage(UserMessagePayload(
                text: "ship it",
                attachments: [ArtifactID(rawValue: "art_one")],
                to: AgentID(rawValue: "main"),
                tags: ["phase-a"],
                goal: "finish",
                submissionID: submissionID)),
            .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: submissionID,
                status: .failed,
                attempt: 2,
                failure: SubmissionFailure(
                    code: "provider_unavailable",
                    message: "Provider unavailable",
                    retryable: true))),
            .messageDelta(MessageDeltaPayload(
                messageId: MessageID(rawValue: "msg_one"),
                role: .assistant,
                textDelta: "partial",
                submissionID: submissionID)),
            .messageCompleted(MessageCompletedPayload(
                messageId: MessageID(rawValue: "msg_one"),
                role: .assistant,
                text: "complete",
                submissionID: submissionID,
                citations: [MessageCitation(
                    url: "https://example.com/source",
                    title: "Example source")])),
            .error(ErrorPayload(
                code: "provider_unavailable",
                message: "Provider unavailable",
                submissionID: submissionID)),
        ]

        for (offset, event) in events.enumerated() {
            let envelope = Envelope(
                seq: offset + 1,
                ts: Date(timeIntervalSince1970: Double(offset + 1)),
                session: session,
                event: event)
            let data = try Envelope.makeEncoder().encode(envelope)
            XCTAssertEqual(
                try Envelope.makeDecoder().decode(Envelope.self, from: data),
                envelope)
        }
    }

    func testSubmissionStatusUsesStableWireTag() throws {
        let envelope = Envelope(
            seq: 1,
            ts: Date(timeIntervalSince1970: 1),
            session: session,
            event: .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: submissionID,
                status: .queued,
                attempt: 1)))

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Envelope.makeEncoder().encode(envelope))
                as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "submission_status_changed")
    }

    func testLegacyMessagePayloadsDecodeWithoutSubmissionIdentity() throws {
        let legacyJSON: [String] = [
            #"{"seq":1,"ts":"2026-07-19T00:00:00Z","session":"sess_legacy","v":1,"type":"user_message","payload":{"text":"hello"}}"#,
            #"{"seq":2,"ts":"2026-07-19T00:00:00Z","session":"sess_legacy","v":1,"type":"message_delta","payload":{"messageId":"msg_legacy","role":"assistant","textDelta":"hi"}}"#,
            #"{"seq":3,"ts":"2026-07-19T00:00:00Z","session":"sess_legacy","v":1,"type":"message_completed","payload":{"messageId":"msg_legacy","role":"assistant","text":"hi"}}"#,
            #"{"seq":4,"ts":"2026-07-19T00:00:00Z","session":"sess_legacy","v":1,"type":"error","payload":{"code":"legacy","message":"failed","fatal":false}}"#,
        ]

        let events = try legacyJSON.map {
            try Envelope.makeDecoder().decode(Envelope.self, from: Data($0.utf8)).event
        }
        guard case .userMessage(let user) = events[0],
              case .messageDelta(let delta) = events[1],
              case .messageCompleted(let completed) = events[2],
              case .error(let error) = events[3] else {
            return XCTFail("legacy payloads decoded to unexpected event types")
        }
        XCTAssertNil(user.submissionID)
        XCTAssertNil(delta.submissionID)
        XCTAssertNil(completed.submissionID)
        XCTAssertNil(completed.citations)
        XCTAssertNil(error.submissionID)
    }
}
