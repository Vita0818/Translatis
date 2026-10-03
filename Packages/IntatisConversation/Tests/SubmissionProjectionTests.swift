import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisConversation

final class SubmissionProjectionTests: XCTestCase {
    private let session = SessionID(rawValue: "sess_submission_projection")

    private func envelope(_ seq: Int, _ event: Event) -> Envelope {
        Envelope(
            seq: seq,
            ts: Date(timeIntervalSince1970: Double(seq)),
            session: session,
            event: event)
    }

    func testCodeProjectionKeepsFirstPayloadAndFoldsLatestMonotonicAttempt() throws {
        let id = SubmissionID(rawValue: "sub_first_write_wins")
        let first = UserMessagePayload(text: "first", submissionID: id)
        let conflictingDuplicate = UserMessagePayload(text: "replacement", submissionID: id)
        let failure = SubmissionFailure(code: "offline", message: "Offline", retryable: true)

        let projection = CodeProjection.build(from: [
            envelope(1, .userMessage(first)),
            envelope(2, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: id, status: .queued, attempt: 1))),
            envelope(3, .userMessage(conflictingDuplicate)),
            envelope(4, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: id, status: .running, attempt: 1))),
            envelope(5, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: id, status: .failed, attempt: 1, failure: failure))),
            envelope(6, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: id, status: .queued, attempt: 2))),
            envelope(7, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: id, status: .running, attempt: 1))),
        ])

        let userItems = projection.items.filter { $0.kind == .user }
        let item = try XCTUnwrap(userItems.first)
        XCTAssertEqual(userItems.count, 1)
        XCTAssertEqual(item.id, id.rawValue)
        XCTAssertEqual(item.body, "first")
        XCTAssertEqual(item.submissionID, id)
        XCTAssertEqual(item.submissionStatus, .queued)
        XCTAssertEqual(item.submissionAttempt, 2)
        XCTAssertNil(item.submissionFailure)
    }

    func testCodeProjectionIgnoresOrphanAndSameAttemptTerminalRegression() throws {
        let orphan = SubmissionID(rawValue: "sub_orphan")
        let accepted = SubmissionID(rawValue: "sub_accepted")
        let failure = SubmissionFailure(code: "failed", message: "Failed", retryable: false)

        let projection = CodeProjection.build(from: [
            envelope(1, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: orphan, status: .failed, attempt: 1, failure: failure))),
            envelope(2, .userMessage(UserMessagePayload(text: "accepted", submissionID: accepted))),
            envelope(3, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: accepted, status: .queued, attempt: 1))),
            envelope(4, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: accepted, status: .running, attempt: 1))),
            envelope(5, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: accepted, status: .completed, attempt: 1))),
            envelope(6, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: accepted, status: .failed, attempt: 1, failure: failure))),
        ])

        let item = try XCTUnwrap(projection.items.first)
        XCTAssertEqual(item.submissionStatus, .completed)
        XCTAssertEqual(item.submissionAttempt, 1)
        XCTAssertNil(item.submissionFailure)
    }

    func testCoworkProjectionPreservesAdmissionFIFOAndIgnoresOrphanStatuses() throws {
        let firstID = SubmissionID(rawValue: "sub_first")
        let secondID = SubmissionID(rawValue: "sub_second")
        let orphanID = SubmissionID(rawValue: "sub_orphan")
        let failure = SubmissionFailure(code: "offline", message: "Offline", retryable: true)

        let projection = CoworkProjection.build(from: [
            envelope(1, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: orphanID, status: .failed, attempt: 1, failure: failure))),
            envelope(2, .userMessage(UserMessagePayload(text: "first", submissionID: firstID))),
            envelope(3, .userMessage(UserMessagePayload(text: "second", submissionID: secondID))),
            envelope(4, .userMessage(UserMessagePayload(text: "must be ignored", submissionID: firstID))),
            envelope(5, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: secondID, status: .queued, attempt: 1))),
            envelope(6, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: firstID, status: .queued, attempt: 1))),
            envelope(7, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: firstID, status: .failed, attempt: 1, failure: failure))),
        ])

        XCTAssertEqual(projection.submittedIntents.map(\.id), [firstID, secondID])
        XCTAssertEqual(projection.submittedIntents.map(\.payload.text), ["first", "second"])
        XCTAssertEqual(projection.submittedIntents.map(\.submittedSeq), [2, 3])
        XCTAssertEqual(projection.submittedIntents[0].status, .failed)
        XCTAssertEqual(projection.submittedIntents[0].failure, failure)
        XCTAssertEqual(projection.submittedIntents[1].status, .queued)
    }

    func testCoworkProjectionRejectsLowerAttemptAndSameAttemptTerminalRewrite() throws {
        let id = SubmissionID(rawValue: "sub_attempts")
        let firstFailure = SubmissionFailure(code: "first", message: "First", retryable: true)
        let staleFailure = SubmissionFailure(code: "stale", message: "Stale", retryable: true)

        let projection = CoworkProjection.build(from: [
            envelope(1, .userMessage(UserMessagePayload(text: "run", submissionID: id))),
            envelope(2, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: id, status: .queued, attempt: 1))),
            envelope(3, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: id, status: .failed, attempt: 1, failure: staleFailure))),
            envelope(4, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: id, status: .queued, attempt: 2))),
            envelope(5, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: id, status: .running, attempt: 2))),
            envelope(6, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: id, status: .failed, attempt: 2, failure: firstFailure))),
            envelope(7, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: id, status: .failed, attempt: 1, failure: staleFailure))),
            envelope(8, .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: id, status: .completed, attempt: 2))),
        ])

        let intent = try XCTUnwrap(projection.submittedIntents.first)
        XCTAssertEqual(intent.attempt, 2)
        XCTAssertEqual(intent.status, .failed)
        XCTAssertEqual(intent.failure, firstFailure)
    }
}
