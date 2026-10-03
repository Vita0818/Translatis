import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisConversation

final class ContinuationRunCloseClaimTests: XCTestCase {
    private let session = SessionID(rawValue: "run-close-session")
    private let runID = ContinuationRunID(rawValue: "run-close-exact")

    private func makeLogPair() throws -> (EventLog, EventLog, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-run-close-\(UUID().uuidString)",
                isDirectory: true)
        let fileURL = directory.appendingPathComponent("events.jsonl")
        return (
            try EventLog(session: session, fileURL: fileURL),
            try EventLog(session: session, fileURL: fileURL),
            directory)
    }

    private func claim(
        outcome: ContinuationRunCloseOutcome = .completed,
        source: ContinuationRunCloseSource = .mainAgent,
        reason: String = "verified",
        at date: Date = Date(timeIntervalSince1970: 1_725_000_000)
    ) -> ContinuationRunCloseRequestedPayload {
        ContinuationRunCloseRequestedPayload(
            sessionID: session,
            runID: runID,
            submissionID: SubmissionID(rawValue: "submission-close"),
            rootTaskID: TaskID(rawValue: "root-close"),
            requestedOutcome: outcome,
            source: source,
            reason: reason,
            requestedAt: date)
    }

    func testConcurrentExactClaimAppendsOnce() async throws {
        let (first, second, directory) = try makeLogPair()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = claim()

        async let left = first.claimContinuationRunClose(payload)
        async let right = second.claimContinuationRunClose(payload)
        let (leftResult, rightResult) = try await (left, right)
        let results = [leftResult, rightResult]

        XCTAssertEqual(results.filter(\.didAppend).count, 1)
        XCTAssertTrue(results.allSatisfy(\.matchesRequest))
        XCTAssertEqual(Set(results.map(\.envelope.seq)).count, 1)
        let replayed = try await first.replayChecked()
        XCTAssertEqual(replayed.compactMap { envelope in
            guard case .continuationRunCloseRequested(let durable) = envelope.event else {
                return nil
            }
            return durable
        }, [payload])
    }

    func testConflictingClaimObservesFirstWinnerWithoutAppending() async throws {
        let (first, second, directory) = try makeLogPair()
        defer { try? FileManager.default.removeItem(at: directory) }
        let winner = claim()
        _ = try await first.claimContinuationRunClose(winner)

        let result = try await second.claimContinuationRunClose(
            claim(outcome: .stopped, reason: "no useful progress"))

        XCTAssertFalse(result.didAppend)
        XCTAssertFalse(result.matchesRequest)
        XCTAssertEqual(result.claim, winner)
        let replayed = try await second.replayChecked()
        XCTAssertEqual(replayed.filter {
            if case .continuationRunCloseRequested = $0.event { return true }
            return false
        }.count, 1)
    }

    func testProjectionRetainsFirstClaimAndFlagsConflictingDurableHistory() {
        let first = claim()
        let conflicting = claim(outcome: .stopped, reason: "different terminal")
        let projection = CoworkProjection.build(from: [
            Envelope(
                seq: 0,
                session: session,
                event: .continuationRunCloseRequested(first)),
            Envelope(
                seq: 1,
                session: session,
                event: .continuationRunCloseRequested(conflicting)),
        ])

        XCTAssertEqual(projection.continuationRunCloseClaims[runID], first)
        XCTAssertEqual(projection.ambiguousContinuationRunCloseClaimIDs, [runID])
    }
}
