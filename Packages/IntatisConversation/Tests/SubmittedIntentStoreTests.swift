import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisConversation

final class SubmittedIntentStoreTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let session: SessionID
        let log: EventLog
    }

    private func makeFixture(_ suffix: String = UUID().uuidString) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "submitted-intent-outbox-\(suffix)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = SessionID(rawValue: "sess_outbox_\(suffix)")
        let log = try EventLog(
            session: session,
            fileURL: root.appendingPathComponent("events.jsonl"))
        return Fixture(root: root, session: session, log: log)
    }

    private func payload(_ id: String = "sub_phase_a",
                         text: String = "preserve this intent") -> UserMessagePayload {
        UserMessagePayload(
            text: text,
            attachments: [ArtifactID(rawValue: "art_phase_a")],
            to: AgentID(rawValue: "main"),
            tags: ["phase-a"],
            goal: "durable admission",
            submissionID: SubmissionID(rawValue: id))
    }

    func testOutboxRoundTripsSchemaOwnerPermissionsAndRemoval() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = try SubmittedIntentOutboxEntry(
            payload: payload(),
            createdAt: createdAt,
            lastCanonicalError: "Event log temporarily unavailable.")

        let persisted = try SubmittedIntentOutboxStore.upsert(
            entry,
            sessionDirectoryURL: fixture.root,
            sessionID: fixture.session)

        XCTAssertEqual(persisted, entry)
        let document = try SubmittedIntentOutboxStore.load(
            sessionDirectoryURL: fixture.root,
            sessionID: fixture.session)
        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.sessionID, fixture.session)
        XCTAssertEqual(document.entries, [entry])
        let url = fixture.root.appendingPathComponent(SubmittedIntentOutboxStore.fileName)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let emptied = try SubmittedIntentOutboxStore.remove(
            id: try XCTUnwrap(entry.payload.submissionID),
            sessionDirectoryURL: fixture.root,
            sessionID: fixture.session)
        XCTAssertTrue(emptied.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOutboxRejectsMissingIdentityWrongSessionAndSymlink() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try SubmittedIntentOutboxEntry(
            payload: UserMessagePayload(text: "missing"))) { error in
            XCTAssertEqual(error as? SubmittedIntentStoreError, .missingSubmissionID)
        }

        _ = try SubmittedIntentOutboxStore.upsert(
            SubmittedIntentOutboxEntry(payload: payload()),
            sessionDirectoryURL: fixture.root,
            sessionID: fixture.session)
        XCTAssertThrowsError(try SubmittedIntentOutboxStore.load(
            sessionDirectoryURL: fixture.root,
            sessionID: SessionID(rawValue: "sess_other"))) { error in
            XCTAssertEqual(error as? SubmittedIntentStoreError, .sessionMismatch)
        }

        let outboxURL = fixture.root.appendingPathComponent(SubmittedIntentOutboxStore.fileName)
        try FileManager.default.removeItem(at: outboxURL)
        let target = fixture.root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: outboxURL, withDestinationURL: target)
        XCTAssertThrowsError(try SubmittedIntentOutboxStore.load(
            sessionDirectoryURL: fixture.root,
            sessionID: fixture.session)) { error in
            XCTAssertEqual(error as? SubmittedIntentStoreError, .unsafeFile)
        }
    }

    func testUpsertIsFirstWriteWinsAndConflictingPayloadFailsClosed() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstCreatedAt = Date(timeIntervalSince1970: 100)
        let first = try SubmittedIntentOutboxEntry(
            payload: payload(),
            createdAt: firstCreatedAt)
        _ = try SubmittedIntentOutboxStore.upsert(
            first,
            sessionDirectoryURL: fixture.root,
            sessionID: fixture.session)

        let repeated = try SubmittedIntentOutboxEntry(
            payload: payload(),
            createdAt: Date(timeIntervalSince1970: 999),
            lastCanonicalError: "Canonical append failed.")
        let merged = try SubmittedIntentOutboxStore.upsert(
            repeated,
            sessionDirectoryURL: fixture.root,
            sessionID: fixture.session)
        XCTAssertEqual(merged.createdAt, firstCreatedAt)
        XCTAssertEqual(merged.lastCanonicalError, "Canonical append failed.")

        let conflict = try SubmittedIntentOutboxEntry(
            payload: payload(text: "different immutable text"))
        XCTAssertThrowsError(try SubmittedIntentOutboxStore.upsert(
            conflict,
            sessionDirectoryURL: fixture.root,
            sessionID: fixture.session)) { error in
            XCTAssertEqual(
                error as? SubmittedIntentStoreError,
                .payloadConflict(SubmissionID(rawValue: "sub_phase_a")))
        }
        let retained = try SubmittedIntentOutboxStore.load(
            sessionDirectoryURL: fixture.root,
            sessionID: fixture.session)
        XCTAssertEqual(retained.entries.count, 1)
        XCTAssertEqual(retained.entries[0].payload.text, "preserve this intent")
    }

    func testConcurrentConflictingUpsertsPersistExactlyOneImmutablePayload() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let identity = "sub_concurrent"

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<16 {
                group.addTask {
                    do {
                        let entry = try SubmittedIntentOutboxEntry(
                            payload: self.payload(identity, text: "candidate \(index)"))
                        _ = try SubmittedIntentOutboxStore.upsert(
                            entry,
                            sessionDirectoryURL: fixture.root,
                            sessionID: fixture.session)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }

        XCTAssertEqual(successes, 1)
        let document = try SubmittedIntentOutboxStore.load(
            sessionDirectoryURL: fixture.root,
            sessionID: fixture.session)
        XCTAssertEqual(document.entries.count, 1)
        XCTAssertEqual(document.entries[0].submissionID.rawValue, identity)
    }

    func testAcceptAtomicallyCanonicalizesUserAndQueuedStatusThenClearsOutbox() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = SubmittedIntentStore(log: fixture.log)
        let user = payload()

        let result = try await store.accept(
            payload: user,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        guard case .canonical(let accepted, let warning) = result else {
            return XCTFail("a writable EventLog must accept canonically")
        }
        XCTAssertEqual(accepted.payload, user)
        XCTAssertNil(warning)

        let history = try await fixture.log.replayChecked()
        XCTAssertEqual(history.count, 2)
        guard case .userMessage(let canonicalUser) = history[0].event,
              case .submissionStatusChanged(let status) = history[1].event else {
            return XCTFail("acceptance must persist one atomic user/status pair")
        }
        XCTAssertEqual(canonicalUser, user)
        XCTAssertEqual(status.submissionID, user.submissionID)
        XCTAssertEqual(status.status, .queued)
        XCTAssertEqual(status.attempt, 1)
        XCTAssertNil(status.failure)
        let emptyOutbox = try await store.loadOutbox()
        XCTAssertTrue(emptyOutbox.entries.isEmpty)

        let repeated = try await store.accept(payload: user)
        guard case .canonical = repeated else {
            return XCTFail("repeated acceptance must remain canonical")
        }
        let repeatedHistory = try await fixture.log.replayChecked()
        XCTAssertEqual(repeatedHistory.count, 2)
    }

    func testCanonicalAppendFailureReturnsVisibleOutboxWithStablePayload() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let corrupt = Data("not an envelope\n".utf8)
        try corrupt.write(to: fixture.root.appendingPathComponent("events.jsonl"))
        let store = SubmittedIntentStore(log: fixture.log)
        let user = payload("sub_visible_failure")

        let result = try await store.accept(payload: user)
        guard case .outbox(let entry, let error) = result else {
            return XCTFail("canonical failure must retain a visible outbox entry")
        }
        XCTAssertEqual(entry.payload, user)
        XCTAssertFalse(error.isEmpty)
        XCTAssertEqual(entry.lastCanonicalError, error)
        let visible = try await store.loadOutbox()
        XCTAssertEqual(visible.entries.count, 1)
        XCTAssertEqual(visible.entries[0].payload, user)
        XCTAssertEqual(visible.entries[0].lastCanonicalError, error)
    }

    func testRetryOutboxCanonicalizesTheExactPayloadAtAttemptOne() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let user = payload("sub_outbox_retry")
        _ = try SubmittedIntentOutboxStore.upsert(
            SubmittedIntentOutboxEntry(payload: user),
            sessionDirectoryURL: fixture.root,
            sessionID: fixture.session)

        let result = try await SubmittedIntentStore(log: fixture.log)
            .retryOutbox(id: try XCTUnwrap(user.submissionID))
        guard case .canonical(let entry, _) = result else {
            return XCTFail("a writable EventLog must canonicalize the outbox entry")
        }
        XCTAssertEqual(entry.payload, user)
        let projection = CoworkProjection.build(from: try await fixture.log.replayChecked())
        XCTAssertEqual(projection.submittedIntents.first?.attempt, 1)
        XCTAssertEqual(projection.submittedIntents.first?.status, .queued)
    }

    func testOutboxFailureThrowsBeforeCanonicalAdmission() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outboxURL = fixture.root.appendingPathComponent(SubmittedIntentOutboxStore.fileName)
        try FileManager.default.createDirectory(at: outboxURL, withIntermediateDirectories: true)
        let store = SubmittedIntentStore(log: fixture.log)

        do {
            _ = try await store.accept(payload: payload("sub_outbox_failure"))
            XCTFail("an unwritable outbox must reject local admission")
        } catch {
            XCTAssertTrue(error is SubmittedIntentStoreError)
        }
        let history = try await fixture.log.replayChecked()
        XCTAssertTrue(history.isEmpty)
    }

    func testLoadFiltersStaleOutboxCopyOnceExactPayloadIsCanonical() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let user = payload("sub_cleanup_retry")
        let entry = try SubmittedIntentOutboxEntry(payload: user)
        _ = try SubmittedIntentOutboxStore.upsert(
            entry,
            sessionDirectoryURL: fixture.root,
            sessionID: fixture.session)
        try await fixture.log.append([
            .userMessage(user),
            .submissionStatusChanged(SubmissionStatusChangedPayload(
                submissionID: try XCTUnwrap(user.submissionID),
                status: .queued,
                attempt: 1)),
        ])
        let store = SubmittedIntentStore(log: fixture.log)

        let visible = try await store.loadOutbox()
        XCTAssertTrue(visible.entries.isEmpty)
        XCTAssertTrue(try SubmittedIntentOutboxStore.load(
            sessionDirectoryURL: fixture.root,
            sessionID: fixture.session).entries.isEmpty)
    }

    func testAppendStatusIsIdempotentAndRequiresCanonicalSubmission() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = SubmittedIntentStore(log: fixture.log)
        let user = payload("sub_status")
        _ = try await store.accept(payload: user)
        let running = SubmissionStatusChangedPayload(
            submissionID: try XCTUnwrap(user.submissionID),
            status: .running,
            attempt: 1)

        let firstStatus = try await store.appendStatus(running)
        let repeatedStatus = try await store.appendStatus(running)
        XCTAssertNotNil(firstStatus)
        XCTAssertNil(repeatedStatus)
        let history = try await fixture.log.replayChecked()
        XCTAssertEqual(history.count, 3)

        let missing = SubmissionStatusChangedPayload(
            submissionID: SubmissionID(rawValue: "sub_missing"),
            status: .running,
            attempt: 1)
        await XCTAssertThrowsErrorAsync(try await store.appendStatus(missing)) { error in
            XCTAssertEqual(
                error as? SubmittedIntentStoreError,
                .canonicalHistoryConflict(SubmissionID(rawValue: "sub_missing")))
        }
    }

    func testAppendStatusRejectsZeroBasedAttempt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = SubmittedIntentStore(log: fixture.log)
        let user = payload("sub_one_based_attempt")
        _ = try await store.accept(payload: user)

        let invalid = SubmissionStatusChangedPayload(
            submissionID: try XCTUnwrap(user.submissionID),
            status: .running,
            attempt: 0)
        await XCTAssertThrowsErrorAsync(try await store.appendStatus(invalid)) { error in
            XCTAssertEqual(error as? SubmittedIntentStoreError, .invalidAttempt)
        }

        let history = try await fixture.log.replayChecked()
        let attempts = history.compactMap { envelope -> Int? in
            guard case .submissionStatusChanged(let status) = envelope.event else { return nil }
            return status.attempt
        }
        XCTAssertEqual(attempts, [1])
    }

    func testAppendStatusRejectsSkippedAttemptAndTerminalRewrite() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = SubmittedIntentStore(log: fixture.log)
        let user = payload("sub_status_transition")
        let id = try XCTUnwrap(user.submissionID)
        _ = try await store.accept(payload: user)
        _ = try await store.appendStatus(SubmissionStatusChangedPayload(
            submissionID: id,
            status: .completed,
            attempt: 1))

        for invalid in [
            SubmissionStatusChangedPayload(
                submissionID: id,
                status: .failed,
                attempt: 1,
                failure: SubmissionFailure(
                    code: "rewrite",
                    message: "must not replace terminal state",
                    retryable: true)),
            SubmissionStatusChangedPayload(
                submissionID: id,
                status: .queued,
                attempt: 3),
        ] {
            await XCTAssertThrowsErrorAsync(try await store.appendStatus(invalid)) { error in
                XCTAssertEqual(
                    error as? SubmittedIntentStoreError,
                    .invalidStatusTransition(id))
            }
        }

        let retry = try await store.appendStatus(SubmissionStatusChangedPayload(
            submissionID: id,
            status: .queued,
            attempt: 2))
        XCTAssertNotNil(retry)
    }

    func testRetryPlannerResumesRestoredAttemptsAndOnlyIncrementsWholeTaskRetry() {
        func task(_ status: TaskStatus, attempt: Int) -> CoworkTaskView {
            CoworkTaskView(
                id: TaskID(rawValue: "task_\(status.rawValue)_\(attempt)"),
                status: status,
                attempt: attempt)
        }

        XCTAssertEqual(
            SubmittedIntentRetryPlanner.plan(
                currentAttempt: 1,
                task: task(.queued, attempt: 1),
                isRestoredSubmission: true),
            .resumeRestoredTask(
                attempt: 1,
                appendsQueuedStatus: false))
        XCTAssertEqual(
            SubmittedIntentRetryPlanner.plan(
                currentAttempt: 1,
                task: task(.queued, attempt: 2),
                isRestoredSubmission: true),
            .resumeRestoredTask(
                attempt: 2,
                appendsQueuedStatus: true))

        for status in [TaskStatus.failed, .cancelled] {
            XCTAssertEqual(
                SubmittedIntentRetryPlanner.plan(
                    currentAttempt: 1,
                    task: task(status, attempt: 1),
                    isRestoredSubmission: false),
                .retryTerminalTask(attempt: 2))
        }
        XCTAssertEqual(
            SubmittedIntentRetryPlanner.plan(
                currentAttempt: 1,
                task: nil,
                isRestoredSubmission: false),
            .retrySubmissionWithoutTask(attempt: 2))

        for status in [TaskStatus.created, .assigned, .running] {
            XCTAssertEqual(
                SubmittedIntentRetryPlanner.plan(
                    currentAttempt: 1,
                    task: task(status, attempt: 1),
                    isRestoredSubmission: true),
                .reject)
        }
        XCTAssertEqual(
            SubmittedIntentRetryPlanner.plan(
                currentAttempt: 1,
                task: task(.queued, attempt: 1),
                isRestoredSubmission: false),
            .reject)
        XCTAssertEqual(
            SubmittedIntentRetryPlanner.plan(
                currentAttempt: 1,
                task: task(.queued, attempt: 3),
                isRestoredSubmission: true),
            .reject)
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ errorHandler: (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected expression to throw")
        } catch {
            errorHandler(error)
        }
    }
}
