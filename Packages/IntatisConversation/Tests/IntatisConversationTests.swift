import XCTest
import IntatisCore
import IntatisProtocol
import IntatisProviders
@testable import IntatisConversation

private struct MockProvider: ChatProvider {
    let parts: [String]
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            for p in parts { continuation.yield(.delta(p)) }
            continuation.yield(.done)
            continuation.finish()
        }
    }
}

private actor ChatRequestRecorder {
    private var value: ChatRequest?

    func record(_ request: ChatRequest) {
        value = request
    }

    func recorded() -> ChatRequest? {
        value
    }
}

private struct SearchCitationProvider: ChatProvider {
    let recorder: ChatRequestRecorder

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await recorder.record(request)
                continuation.yield(.delta("Current answer"))
                continuation.yield(.citation(MessageCitation(
                    url: "https://example.com/current",
                    title: "Current source")))
                continuation.yield(.citation(MessageCitation(
                    url: "https://example.com/current",
                    title: "Duplicate source")))
                continuation.yield(.done)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct PartialThenFailingProvider: ChatProvider {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.delta("partial"))
            continuation.finish(throwing: IntatisError.decoding(
                "streaming request ended before a completion marker. Check endpoint compatibility."))
        }
    }
}

private struct SplitUsageProvider: ChatProvider {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.delta("ok"))
            continuation.yield(.usage(Usage(promptTokens: 7, cachedPromptTokens: 3)))
            continuation.yield(.usage(Usage(completionTokens: 2, totalTokens: 9)))
            continuation.yield(.done)
            continuation.finish()
        }
    }
}

private struct URLLeakingProviderError: LocalizedError {
    var errorDescription: String? {
        "upstream http://10.20.30.40:8123/private/chat/completions?token=opaque-token failed; status=502; retry later"
    }
}

private struct URLLeakingProvider: ChatProvider {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: URLLeakingProviderError())
        }
    }
}

private struct SelfCancellingChatProvider: ChatProvider {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: CancellationError())
        }
    }
}

final class IntatisConversationTests: XCTestCase {

    private func tmpFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-conv-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    private func encodedBatch(session: SessionID,
                              firstSequence: Int,
                              texts: [String],
                              needsSeparator: Bool = false) throws -> Data {
        let encoder = Envelope.makeEncoder()
        var data = Data()
        if needsSeparator { data.append(0x0A) }
        for (offset, text) in texts.enumerated() {
            let envelope = Envelope(
                seq: firstSequence + offset,
                ts: Date(timeIntervalSince1970: Double(firstSequence + offset)),
                session: session,
                event: .userMessage(.init(text: text)))
            data.append(try encoder.encode(envelope))
            data.append(0x0A)
        }
        return data
    }

    private func writeCrashJournal(fileURL: URL,
                                   session: SessionID,
                                   batchBytes: Data,
                                   firstSequence: Int,
                                   eventCount: Int) throws {
        let original = try Data(contentsOf: fileURL)
        let prefixLength = min(original.count, EventLogWriteAheadJournal.prefixLimit)
        let prefix = Data(original.suffix(prefixLength))
        let journal = EventLogWriteAheadJournal(
            session: session,
            originalOffset: UInt64(original.count),
            prefixStartOffset: UInt64(original.count - prefixLength),
            prefixBytes: prefix,
            batchBytes: batchBytes,
            firstSequence: firstSequence,
            eventCount: eventCount)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(journal).write(
            to: fileURL.appendingPathExtension("wal"),
            options: .atomic)
    }

    private func appendRaw(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    func testAppendReplayAndResumeSeq() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = SessionID(rawValue: "sess_r")
        let log = try EventLog(session: s, fileURL: url)
        _ = try await log.append(.userMessage(.init(text: "a")))
        _ = try await log.append(.userMessage(.init(text: "b")))

        // Reload: seq continues from the persisted max.
        let reloaded = try EventLog(session: s, fileURL: url)
        let all = await reloaded.replay()
        XCTAssertEqual(all.map { $0.seq }, [0, 1])
        let next = try await reloaded.append(.userMessage(.init(text: "c")))
        XCTAssertEqual(next.seq, 2)
    }

    func testAppendReturnsAndPublishesCanonicalPersistedEnvelopes() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = SessionID(rawValue: "cowork_canonical_append")
        let log = try EventLog(session: session, fileURL: url)
        let stream = await log.stream(from: 0)
        var iterator = stream.makeAsyncIterator()
        let timestamp = Date(timeIntervalSince1970: 1_234_567_890.987_654)
        let settings = CoworkSessionSettings(
            sessionID: session,
            defaultProviderID: "provider-must-remain-decode-only",
            defaultModelID: "model",
            workspaces: [])
        let update = SessionSettingsUpdatedPayload(
            revision: 7,
            previousRevision: 6,
            changeKind: .updated,
            kind: .cowork,
            cowork: settings)
        let marker = SessionStorageMigratedPayload(
            migrationID: "canonical-envelope-test",
            source: .legacySessionMetadata,
            settingsRevision: 7)

        let appended = try await log.append([
            .sessionSettingsUpdated(update),
            .sessionStorageMigrated(marker),
        ], ts: timestamp)
        let streamed = [await iterator.next(), await iterator.next()].compactMap { $0 }
        let replayed = try await log.replayChecked()
        let persisted = try Data(contentsOf: url)
            .split(separator: 0x0A)
            .map { try Envelope.makeDecoder().decode(Envelope.self, from: Data($0)) }

        XCTAssertEqual(appended, persisted)
        XCTAssertEqual(streamed, persisted)
        XCTAssertEqual(replayed, persisted)
        XCTAssertEqual(appended.map(\.ts), [persisted[0].ts, persisted[1].ts])
        guard case .sessionSettingsUpdated(let canonicalUpdate) = appended[0].event else {
            return XCTFail("the first canonical event must remain a settings update")
        }
        XCTAssertEqual(canonicalUpdate.revision, 7)
        XCTAssertEqual(canonicalUpdate.previousRevision, 6)
        XCTAssertNil(canonicalUpdate.cowork?.defaultProviderID)
        guard case .sessionStorageMigrated(let canonicalMarker) = appended[1].event else {
            return XCTFail("the second canonical event must remain a migration marker")
        }
        XCTAssertEqual(canonicalMarker.settingsRevision, 7)
    }

    func testConcurrentEventLogInstancesAssignUniqueMonotonicSequences() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = SessionID(rawValue: "sess_multi_writer")
        let first = try EventLog(session: session, fileURL: url)
        let second = try EventLog(session: session, fileURL: url)
        let count = 80

        let persisted = try await withThrowingTaskGroup(of: Envelope.self) { group in
            for index in 0..<count {
                let log = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    try await log.append(.userMessage(.init(text: "event-\(index)")))
                }
            }
            var envelopes: [Envelope] = []
            for try await envelope in group {
                envelopes.append(envelope)
            }
            return envelopes
        }

        XCTAssertEqual(persisted.map(\.seq).sorted(), Array(0..<count))
        let replayed = await first.replay()
        XCTAssertEqual(replayed.map(\.seq), Array(0..<count))
        XCTAssertEqual(Set(replayed.map(\.seq)).count, count)
        XCTAssertEqual(replayed.count, count)

        // A fresh instance must recover the sequence written by both actors.
        let reopened = try EventLog(session: session, fileURL: url)
        let next = try await reopened.append(.userMessage(.init(text: "after-reopen")))
        XCTAssertEqual(next.seq, count)
    }

    func testWriterLeaseRejectsSecondRuntimeButAllowsReadOnlyReplay() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = SessionID(rawValue: "sess_writer_lease")
        let first = try EventLog(session: session, fileURL: url)
        let second = try EventLog(session: session, fileURL: url)
        _ = try await first.append(.userMessage(.init(text: "persisted")))

        let lease = try first.acquireWriterLease()
        do {
            _ = try second.acquireWriterLease()
            XCTFail("a second task-executing runtime must not acquire the same session")
        } catch let error as EventLogError {
            XCTAssertEqual(error, .writerAlreadyActive)
            XCTAssertFalse(error.localizedDescription.contains(url.path))
            XCTAssertNotNil(error.recoverySuggestion)
        }

        // The lifetime writer lease is distinct from the short I/O lock, so
        // history/projection reads may coexist with the active runtime.
        let concurrentReplay = await second.replay()
        XCTAssertEqual(concurrentReplay.map(\.seq), [0])

        lease.release()
        let replacementLease = try second.acquireWriterLease()
        replacementLease.release()
    }

    func testAppendBatchPersistsContiguousSequenceGroup() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(
            session: SessionID(rawValue: "sess_batch"),
            fileURL: url)

        let envelopes = try await log.append([
            .userMessage(.init(text: "one")),
            .userMessage(.init(text: "two")),
            .userMessage(.init(text: "three")),
        ], ts: Date(timeIntervalSince1970: 123))

        XCTAssertEqual(envelopes.map(\.seq), [0, 1, 2])
        XCTAssertEqual(envelopes.map(\.ts), Array(repeating: Date(timeIntervalSince1970: 123), count: 3))
        let replayed = await log.replay()
        XCTAssertEqual(replayed.map(\.seq), [0, 1, 2])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathExtension("wal").path))
    }

    func testInitializationRollsBackPartialJournaledBatch() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = SessionID(rawValue: "sess_partial_wal")
        let initial = try EventLog(session: session, fileURL: url)
        _ = try await initial.append(.userMessage(.init(text: "committed")))
        let original = try Data(contentsOf: url)
        let batch = try encodedBatch(
            session: session,
            firstSequence: 1,
            texts: ["rolled-back-1", "rolled-back-2"])
        try writeCrashJournal(
            fileURL: url,
            session: session,
            batchBytes: batch,
            firstSequence: 1,
            eventCount: 2)
        try appendRaw(Data(batch.prefix(max(1, batch.count / 2))), to: url)

        let recovered = try EventLog(session: session, fileURL: url)
        let replayed = try await recovered.replayChecked()
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(replayed.map(\.seq), [0])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathExtension("wal").path))

        let next = try await recovered.append(.userMessage(.init(text: "after-recovery")))
        XCTAssertEqual(next.seq, 1)
    }

    func testInitializationKeepsCompleteJournaledBatch() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = SessionID(rawValue: "sess_complete_wal")
        let initial = try EventLog(session: session, fileURL: url)
        _ = try await initial.append(.userMessage(.init(text: "committed")))
        let batch = try encodedBatch(
            session: session,
            firstSequence: 1,
            texts: ["committed-1", "committed-2"])
        try writeCrashJournal(
            fileURL: url,
            session: session,
            batchBytes: batch,
            firstSequence: 1,
            eventCount: 2)
        try appendRaw(batch, to: url)

        let recovered = try EventLog(session: session, fileURL: url)
        let replayed = try await recovered.replayChecked()
        XCTAssertEqual(replayed.map(\.seq), [0, 1, 2])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathExtension("wal").path))
        let next = try await recovered.append(.userMessage(.init(text: "after-recovery")))
        XCTAssertEqual(next.seq, 3)
    }

    func testInitializationFailsClosedForCorruptOrMismatchedJournal() async throws {
        let corruptURL = tmpFile()
        defer { try? FileManager.default.removeItem(at: corruptURL.deletingLastPathComponent()) }
        let corruptSession = SessionID(rawValue: "sess_corrupt_wal")
        let corruptLog = try EventLog(session: corruptSession, fileURL: corruptURL)
        _ = try await corruptLog.append(.userMessage(.init(text: "committed")))
        try Data("not-json".utf8).write(
            to: corruptURL.appendingPathExtension("wal"),
            options: .atomic)
        XCTAssertThrowsError(try EventLog(session: corruptSession, fileURL: corruptURL)) { error in
            XCTAssertEqual(error as? EventLogError, .journalCorrupted)
        }

        let mismatchURL = tmpFile()
        defer { try? FileManager.default.removeItem(at: mismatchURL.deletingLastPathComponent()) }
        let mismatchSession = SessionID(rawValue: "sess_mismatch_wal")
        let mismatchLog = try EventLog(session: mismatchSession, fileURL: mismatchURL)
        _ = try await mismatchLog.append(.userMessage(.init(text: "committed")))
        let batch = try encodedBatch(
            session: mismatchSession,
            firstSequence: 1,
            texts: ["expected-1", "expected-2"])
        try writeCrashJournal(
            fileURL: mismatchURL,
            session: mismatchSession,
            batchBytes: batch,
            firstSequence: 1,
            eventCount: 2)
        try appendRaw(Data("different bytes".utf8), to: mismatchURL)
        XCTAssertThrowsError(try EventLog(session: mismatchSession, fileURL: mismatchURL)) { error in
            XCTAssertEqual(error as? EventLogError, .journalMismatch)
        }
    }

    func testReplayAPIsRecoverJournalCreatedAfterReaderInitialization() async throws {
        for state in ["untouched", "partial"] {
            let url = tmpFile()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let session = SessionID(rawValue: "sess_live_\(state)_wal")
            let log = try EventLog(session: session, fileURL: url)
            _ = try await log.append(.userMessage(.init(text: "committed")))
            let original = try Data(contentsOf: url)
            let batch = try encodedBatch(
                session: session,
                firstSequence: 1,
                texts: ["not-visible-1", "not-visible-2"])
            try writeCrashJournal(
                fileURL: url,
                session: session,
                batchBytes: batch,
                firstSequence: 1,
                eventCount: 2)
            if state == "partial" {
                let firstLineEnd = try XCTUnwrap(batch.firstIndex(of: 0x0A))
                // Simulate a process dying after one complete member of the
                // atomic batch reached JSONL but before the second member.
                try appendRaw(Data(batch.prefix(firstLineEnd + 1)), to: url)
            }

            let replayed: [Envelope]
            if state == "partial" {
                // The compatibility projection is fail-soft, but it must still
                // recover rather than expose the first complete batch member.
                replayed = await log.replay()
            } else {
                replayed = try await log.replayChecked()
            }

            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertEqual(replayed.map(\.seq), [0])
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: url.appendingPathExtension("wal").path))
        }
    }

    func testCheckedReplayAndAppendRejectEventsFromAnotherSession() async throws {
        for useUnknownType in [false, true] {
            let url = tmpFile()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let session = SessionID(rawValue: "sess_expected_\(useUnknownType)")
            let otherSession = SessionID(rawValue: "sess_other_\(useUnknownType)")
            let log = try EventLog(session: session, fileURL: url)
            let encoder = Envelope.makeEncoder()
            let encoded = try encoder.encode(Envelope(
                seq: 0,
                ts: Date(timeIntervalSince1970: 0),
                session: otherSession,
                event: .userMessage(.init(text: "wrong session"))))
            var bytes: Data
            if useUnknownType {
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: encoded) as? [String: Any])
                object["type"] = "future_event_type"
                object["payload"] = ["futureField": true]
                bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            } else {
                bytes = encoded
            }
            bytes.append(0x0A)
            try bytes.write(to: url)

            do {
                _ = try await log.replayChecked()
                XCTFail("strict replay must reject a \(useUnknownType ? "future" : "known") event from another session")
            } catch let error as EventLogError {
                XCTAssertEqual(error, .sessionMismatch)
            }
            do {
                _ = try await log.isEmptyChecked()
                XCTFail("strict emptiness must reject another session")
            } catch let error as EventLogError {
                XCTAssertEqual(error, .sessionMismatch)
            }
            do {
                _ = try await log.append(.userMessage(.init(text: "must not reuse sequence")))
                XCTFail("append must not allocate after another session's tail")
            } catch let error as EventLogError {
                XCTAssertEqual(error, .sessionMismatch)
            }
        }
    }

    func testUnknownFutureEventReservesItsSequenceForConcurrentSafeAppend() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let session = SessionID(rawValue: "sess_future_sequence")
        let encoder = Envelope.makeEncoder()
        let known = try encoder.encode(Envelope(
            seq: 0,
            ts: Date(timeIntervalSince1970: 0),
            session: session,
            event: .userMessage(.init(text: "known"))))
        let futureBase = try encoder.encode(Envelope(
            seq: 7,
            ts: Date(timeIntervalSince1970: 7),
            session: session,
            event: .userMessage(.init(text: "placeholder"))))
        var futureObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: futureBase) as? [String: Any])
        futureObject["type"] = "future_event_type"
        futureObject["payload"] = ["futureField": true]
        let future = try JSONSerialization.data(withJSONObject: futureObject, options: [.sortedKeys])
        var initialData = known
        initialData.append(0x0A)
        initialData.append(future)
        initialData.append(0x0A)
        try initialData.write(to: url)

        let log = try EventLog(session: session, fileURL: url)
        let appended = try await log.append(.userMessage(.init(text: "current")))

        XCTAssertEqual(appended.seq, 8)
        // The future event is intentionally skipped by this binary, but its
        // occupied sequence remains reserved.
        let replayed = await log.replay()
        XCTAssertEqual(replayed.map(\.seq), [0, 8])
    }

    func testReplayCheckedSkipsValidUnknownFutureTypeButEmptyCheckCountsIt() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let session = SessionID(rawValue: "sess_checked_future")
        let encoder = Envelope.makeEncoder()
        let placeholder = try encoder.encode(Envelope(
            seq: 7,
            ts: Date(timeIntervalSince1970: 7),
            session: session,
            event: .userMessage(.init(text: "placeholder"))))
        var futureObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: placeholder) as? [String: Any])
        futureObject["type"] = "future_event_type"
        futureObject["payload"] = ["futureField": true]
        var future = try JSONSerialization.data(
            withJSONObject: futureObject,
            options: [.sortedKeys])
        future.append(0x0A)
        try future.write(to: url)

        let log = try EventLog(session: session, fileURL: url)
        let replayed = try await log.replayChecked()
        let isEmpty = try await log.isEmptyChecked()
        XCTAssertTrue(replayed.isEmpty)
        XCTAssertFalse(isEmpty, "a valid unknown header is still durable session state")
        let appended = try await log.append(.userMessage(.init(text: "current")))
        XCTAssertEqual(appended.seq, 8)
    }

    func testReplayCheckedThrowsForKnownTypeWithCorruptPayload() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let session = SessionID(rawValue: "sess_checked_corrupt_known")
        let encoder = Envelope.makeEncoder()
        let encoded = try encoder.encode(Envelope(
            seq: 0,
            ts: Date(timeIntervalSince1970: 0),
            session: session,
            event: .userMessage(.init(text: "placeholder"))))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["payload"] = ["attachments": []]
        var corrupted = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys])
        corrupted.append(0x0A)
        try corrupted.write(to: url)

        let log = try EventLog(session: session, fileURL: url)
        do {
            _ = try await log.replayChecked()
            XCTFail("a known event with an invalid payload must fail strict replay")
        } catch let error as EventLogError {
            XCTAssertEqual(error, .corruptedEvent(line: 1))
            XCTAssertFalse(error.localizedDescription.contains(url.path))
        }
        do {
            _ = try await log.isEmptyChecked()
            XCTFail("strict emptiness must not turn corruption into an empty session")
        } catch let error as EventLogError {
            XCTAssertEqual(error, .corruptedEvent(line: 1))
        }

        // The legacy API remains fail-soft for projection callers.
        let compatibilityReplay = await log.replay()
        XCTAssertTrue(compatibilityReplay.isEmpty)
    }

    func testReplayCheckedThrowsForReadFailure() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(
            session: SessionID(rawValue: "sess_checked_read_failure"),
            fileURL: url)
        let initiallyEmpty = try await log.isEmptyChecked()
        XCTAssertTrue(initiallyEmpty)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        do {
            _ = try await log.replayChecked()
            XCTFail("strict replay must surface storage read failures")
        } catch let error as EventLogError {
            guard case .storageUnavailable = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testInitializationRejectsNonMonotonicValidEnvelopeHeadersWithoutPathLeak() throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let session = SessionID(rawValue: "sess_bad_sequence")
        let encoder = Envelope.makeEncoder()
        var data = try encoder.encode(Envelope(
            seq: 2,
            ts: Date(timeIntervalSince1970: 0),
            session: session,
            event: .userMessage(.init(text: "first"))))
        data.append(0x0A)
        data.append(try encoder.encode(Envelope(
            seq: 2,
            ts: Date(timeIntervalSince1970: 1),
            session: session,
            event: .userMessage(.init(text: "duplicate")))))
        data.append(0x0A)
        try data.write(to: url)

        do {
            _ = try EventLog(session: session, fileURL: url)
            XCTFail("duplicate valid sequence headers must fail closed")
        } catch let error as EventLogError {
            XCTAssertEqual(error, .nonMonotonicSequence(previous: 2, current: 2))
            XCTAssertFalse(error.localizedDescription.contains(url.path))
            XCTAssertNotNil(error.recoverySuggestion)
        }
    }

    func testAppendAfterCrashTailKeepsNewEnvelopeReplayable() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = SessionID(rawValue: "sess_crash_tail")
        let initialLog = try EventLog(session: session, fileURL: url)
        _ = try await initialLog.append(.userMessage(.init(text: "before crash")))

        let corruptTail = Data(#"{"seq":999,"type":"user_message","payload":{"text":"partial""#.utf8)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: corruptTail)
        try handle.close()

        let reloaded = try EventLog(session: session, fileURL: url)
        let appended = try await reloaded.append(.userMessage(.init(text: "after restart")))
        let replayed = await reloaded.replay()

        XCTAssertEqual(appended.seq, 1)
        XCTAssertEqual(replayed.map(\.seq), [0, 1])
        XCTAssertEqual(replayed.compactMap { envelope -> String? in
            guard case .userMessage(let payload) = envelope.event else { return nil }
            return payload.text
        }, ["before crash", "after restart"])

        let persistedLines = try Data(contentsOf: url).split(separator: 0x0A)
        XCTAssertEqual(persistedLines.count, 3)
        XCTAssertEqual(Data(persistedLines[1]), corruptTail)
    }

    func testReplayFromSeqFiltersEarlier() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(session: SessionID(rawValue: "sess_f"), fileURL: url)
        for t in ["a", "b", "c"] { _ = try await log.append(.userMessage(.init(text: t))) }
        let tail = await log.replay(from: 1)
        XCTAssertEqual(tail.map { $0.seq }, [1, 2])
    }

    func testStreamReplaysThenLive() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(session: SessionID(rawValue: "sess_s"), fileURL: url)
        _ = try await log.append(.userMessage(.init(text: "first")))

        let stream = await log.stream(from: 0)
        var iterator = stream.makeAsyncIterator()
        _ = try await log.append(.userMessage(.init(text: "second")))

        let e0 = await iterator.next()
        let e1 = await iterator.next()
        XCTAssertEqual(e0?.seq, 0)
        XCTAssertEqual(e1?.seq, 1)
    }

    func testChatLoopStreamsAndProjects() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(session: SessionID(rawValue: "sess_c"), fileURL: url)
        let loop = ChatLoop(log: log, provider: MockProvider(parts: ["He", "llo"]), model: ModelID(rawValue: "m"))
        try await loop.send("hi")

        let projection = ConversationProjection.build(from: await log.replay())
        XCTAssertEqual(projection.messages.count, 2)
        XCTAssertEqual(projection.messages[0].role, .user)
        XCTAssertEqual(projection.messages[0].text, "hi")
        XCTAssertEqual(projection.messages[1].role, .assistant)
        XCTAssertEqual(projection.messages[1].text, "Hello")
        XCTAssertTrue(projection.messages[1].isComplete)
        let outcomes = await log.replay().compactMap { envelope -> TurnOutcomePayload? in
            guard case .turnOutcome(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.outcome, .completed)
    }

    func testChatLoopPassesWebSearchAndPersistsDeduplicatedCitations() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(
            session: SessionID(rawValue: "sess_web_search"),
            fileURL: url)
        let recorder = ChatRequestRecorder()
        let loop = ChatLoop(
            log: log,
            provider: SearchCitationProvider(recorder: recorder),
            model: ModelID(rawValue: "m"),
            webSearch: ChatWebSearchConfiguration(
                dialect: .openAIResponses,
                contextSize: .high))

        try await loop.send("what is current?")

        let request = await recorder.recorded()
        XCTAssertEqual(request?.webSearch,
                       ChatWebSearchConfiguration(
                           dialect: .openAIResponses,
                           contextSize: .high))
        let replayed = await log.replay()
        let completed = try XCTUnwrap(replayed.compactMap { envelope -> MessageCompletedPayload? in
            guard case .messageCompleted(let payload) = envelope.event else {
                return nil
            }
            return payload
        }.last)
        XCTAssertEqual(completed.citations, [
            MessageCitation(
                url: "https://example.com/current",
                title: "Current source"),
        ])
        let projection = ConversationProjection.build(from: replayed)
        XCTAssertEqual(projection.messages.last?.citations,
                       completed.citations ?? [])
    }

    func testChatLoopPreservesPartialTextWhenStreamEndsWithoutCompletionMarker() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(session: SessionID(rawValue: "sess_partial_eof"), fileURL: url)
        let loop = ChatLoop(log: log,
                            provider: PartialThenFailingProvider(),
                            model: ModelID(rawValue: "m"))

        do {
            try await loop.send("hi")
            XCTFail("expected incomplete stream error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("completion marker"))
        }

        let projection = ConversationProjection.build(from: await log.replay())
        XCTAssertEqual(projection.messages.count, 3)
        XCTAssertEqual(projection.messages[0].role, .user)
        XCTAssertEqual(projection.messages[1].role, .assistant)
        XCTAssertEqual(projection.messages[1].text, "partial")
        XCTAssertFalse(projection.messages[1].isComplete)
        XCTAssertEqual(projection.messages[1].recoveryAdvice?.title, "Response stopped before completion")
        XCTAssertEqual(projection.messages[2].role, .system)
        XCTAssertEqual(projection.messages[2].recoveryAdvice?.title, "Check endpoint compatibility")
        let outcomes = await log.replay().compactMap { envelope -> TurnOutcomePayload? in
            guard case .turnOutcome(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.outcome, .failed)
        XCTAssertEqual(outcomes.first?.failureSource, .runtimeFailed)
    }

    func testChatProviderSelfCancellationIsRuntimeFailureNotTurnCancellation() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(
            session: SessionID(rawValue: "sess_provider_self_cancel"),
            fileURL: url)
        let loop = ChatLoop(
            log: log,
            provider: SelfCancellingChatProvider(),
            model: ModelID(rawValue: "m"))

        do {
            try await loop.send("hi")
            XCTFail("expected provider cancellation")
        } catch is CancellationError {
            // A provider-originated CancellationError is still a runtime
            // failure because this caller task was never cancelled.
        }

        let replayed = await log.replay()
        let outcomes = replayed.compactMap { envelope -> TurnOutcomePayload? in
            guard case .turnOutcome(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.outcome, .failed)
        XCTAssertEqual(outcomes.first?.failureSource, .runtimeFailed)
        XCTAssertTrue(replayed.contains { envelope in
            guard case .error(let payload) = envelope.event else { return false }
            return payload.code == "runtime_failed"
        })
    }

    func testChatLoopEventLogRedactsURLFromUnformattedProviderError() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(session: SessionID(rawValue: "sess_url_error"), fileURL: url)
        let loop = ChatLoop(
            log: log,
            provider: URLLeakingProvider(),
            model: ModelID(rawValue: "m"))

        do {
            try await loop.send("hi")
            XCTFail("expected provider failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("10.20.30.40"))
        }

        let replayed = await log.replay()
        let payload = try XCTUnwrap(replayed.compactMap { envelope -> ErrorPayload? in
            guard case .error(let payload) = envelope.event else { return nil }
            return payload
        }.last)
        let persisted = try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .utf8))

        XCTAssertEqual(payload.code, "provider")
        XCTAssertTrue(payload.message.contains("[REDACTED_URL]"))
        XCTAssertTrue(payload.message.contains("status=502"))
        XCTAssertTrue(payload.message.contains("retry later"))
        for text in [payload.message, persisted] {
            XCTAssertFalse(text.contains("http://"))
            XCTAssertFalse(text.contains("10.20.30.40"))
            XCTAssertFalse(text.contains("/private/chat/completions"))
            XCTAssertFalse(text.contains("opaque-token"))
        }
    }

    func testChatLoopMergesSplitUsageChunksIntoTurnStats() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(session: SessionID(rawValue: "sess_split_usage"), fileURL: url)
        let loop = ChatLoop(log: log,
                            provider: SplitUsageProvider(),
                            model: ModelID(rawValue: "m"),
                            includeUsage: true)

        try await loop.send("hi")

        let events = await log.replay()
        let stats = events.compactMap { envelope -> TurnStatsPayload? in
            guard case .turnStats(let payload) = envelope.event else { return nil }
            return payload
        }.last
        let responseMessageID = events.compactMap { envelope -> MessageID? in
            guard case .messageCompleted(let payload) = envelope.event else {
                return nil
            }
            return payload.messageId
        }.last
        let outcomeTurnID = events.compactMap { envelope -> TurnID? in
            guard case .turnOutcome(let payload) = envelope.event else {
                return nil
            }
            return payload.turnID
        }.last
        XCTAssertEqual(stats?.promptTokens, 7)
        XCTAssertEqual(stats?.cachedPromptTokens, 3)
        XCTAssertEqual(stats?.completionTokens, 2)
        XCTAssertEqual(stats?.totalTokens, 9)
        XCTAssertEqual(stats?.responseMessageID, responseMessageID)
        XCTAssertEqual(stats?.turnID, outcomeTurnID)

        let projectedReply = ConversationProjection.build(
            from: events).messages.last
        XCTAssertEqual(projectedReply?.id, responseMessageID)
        XCTAssertEqual(projectedReply?.turnStats?.totalTokens, 9)
    }

    func testChatLoopCanPersistGoalUserPayload() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(session: SessionID(rawValue: "sess_goal_loop"), fileURL: url)
        let loop = ChatLoop(log: log, provider: MockProvider(parts: ["ok"]), model: ModelID(rawValue: "m"))
        let parsed = try XCTUnwrap(GoalInputParser.parse("/goal ship v0.12").successValue)

        try await loop.send(parsed.text, userMessage: parsed.userMessagePayload)

        let replayed = await log.replay()
        let first = try XCTUnwrap(replayed.first)
        guard case .userMessage(let payload) = first.event else {
            return XCTFail("first event should be user_message")
        }
        XCTAssertEqual(payload.text, "ship v0.12")
        XCTAssertEqual(payload.tags ?? [], ["Goal"])
        XCTAssertEqual(payload.goal, "ship v0.12")
    }

    func testChatLoopBuildsHistoryAcrossTurns() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(session: SessionID(rawValue: "sess_h"), fileURL: url)
        let loop = ChatLoop(log: log, provider: MockProvider(parts: ["ok"]), model: ModelID(rawValue: "m"))
        try await loop.send("first")
        try await loop.send("second")

        let projection = ConversationProjection.build(from: await log.replay())
        XCTAssertEqual(projection.messages.map { $0.role }, [.user, .assistant, .user, .assistant])
    }

    func testChatLoopPersistsAndRehydratesImageAttachmentsAcrossTurns() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(
            session: SessionID(rawValue: "sess_attachment_history"),
            fileURL: url)
        let recorder = ChatRequestRecorder()
        let firstID = ArtifactID(rawValue: "art_first_image")
        let secondID = ArtifactID(rawValue: "art_second_image")
        let firstImage = ImageAttachment.base64(
            mime: "image/png",
            base64: "RklSU1Q=")
        let secondImage = ImageAttachment.base64(
            mime: "image/jpeg",
            base64: "U0VDT05E")
        let loop = ChatLoop(
            log: log,
            provider: SearchCitationProvider(recorder: recorder),
            model: ModelID(rawValue: "m"),
            attachmentResolver: { ids in
                guard ids == [firstID] else {
                    throw IntatisError.notFound("unexpected attachment set")
                }
                return [firstImage]
            })

        try await loop.send(
            "first",
            images: [firstImage],
            userMessage: UserMessagePayload(
                text: "first",
                attachments: [firstID]))
        try await loop.send(
            "second",
            images: [secondImage],
            userMessage: UserMessagePayload(
                text: "second",
                attachments: [secondID]))

        let recordedRequest = await recorder.recorded()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.messages.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(request.messages[0].images, [firstImage])
        XCTAssertEqual(request.messages[1].images, [])
        XCTAssertEqual(request.messages[2].images, [secondImage])

        let userMessages = ConversationProjection
            .build(from: await log.replay())
            .messages
            .filter { $0.role == .user }
        XCTAssertEqual(userMessages.map(\.attachments), [[firstID], [secondID]])
    }

    func testConversationProjectionUsesStableSyntheticMessageIDsAcrossReplay() {
        let session = SessionID(rawValue: "sess_stable_chat")
        func env(_ seq: Int, _ event: Event) -> Envelope {
            Envelope(seq: seq, ts: Date(timeIntervalSince1970: Double(seq)), session: session, event: event)
        }
        let envelopes: [Envelope] = [
            env(0, .userMessage(.init(text: "draw"))),
            env(1, .error(.init(code: "provider", message: "failed"))),
            env(2, .artifactAdded(.init(
                artifactId: ArtifactID(rawValue: "art_stable"),
                kind: "image",
                mime: "image/png",
                path: "/tmp/image.png",
                prompt: "draw"))),
        ]

        let first = ConversationProjection.build(from: envelopes).messages.map(\.id)
        let second = ConversationProjection.build(from: envelopes).messages.map(\.id)

        XCTAssertEqual(first, second)
    }

    func testConversationProjectionAddsRecoveryAdviceForProviderErrors() {
        let session = SessionID(rawValue: "sess_chat_error_recovery")
        let envelope = Envelope(
            seq: 0,
            ts: Date(timeIntervalSince1970: 0),
            session: session,
            event: .error(.init(
                code: "provider",
                message: "streaming request failed with HTTP 401 Unauthorized. Check your API key.")))

        let message = ConversationProjection.build(from: [envelope]).messages.first

        XCTAssertEqual(message?.role, .system)
        XCTAssertEqual(message?.recoveryAdvice?.title, "Fix provider configuration")
        XCTAssertEqual(message?.recoveryAdvice?.retryable, false)
    }

    func testConversationProjectionMarksPartialStreamStoppedByError() {
        let session = SessionID(rawValue: "sess_chat_partial_stop")
        let messageID = MessageID(rawValue: "m_partial")
        func env(_ seq: Int, _ event: Event) -> Envelope {
            Envelope(seq: seq, ts: Date(timeIntervalSince1970: Double(seq)), session: session, event: event)
        }
        let envelopes: [Envelope] = [
            env(0, .messageDelta(.init(messageId: messageID, role: .assistant, textDelta: "partial"))),
            env(1, .error(.init(
                code: "provider",
                message: "streaming request failed with HTTP 503 Service Unavailable. Retry later."))),
        ]

        let projection = ConversationProjection.build(from: envelopes)

        XCTAssertEqual(projection.messages.count, 2)
        XCTAssertEqual(projection.messages[0].id, messageID)
        XCTAssertEqual(projection.messages[0].text, "partial")
        XCTAssertFalse(projection.messages[0].isComplete)
        XCTAssertEqual(projection.messages[0].recoveryAdvice?.title, "Response stopped before completion")
        XCTAssertEqual(projection.messages[0].recoveryAdvice?.retryable, true)
        XCTAssertEqual(projection.messages[1].recoveryAdvice?.title, "Retry or switch provider")
    }

    func testConversationProjectionKeepsGoalMetadata() {
        let session = SessionID(rawValue: "sess_goal_projection")
        let envelopes: [Envelope] = [
            Envelope(seq: 0, ts: Date(timeIntervalSince1970: 0), session: session,
                     event: .userMessage(.init(text: "ship v0.12", tags: ["Goal"], goal: "ship v0.12"))),
        ]

        let message = ConversationProjection.build(from: envelopes).messages.first

        XCTAssertEqual(message?.text, "ship v0.12")
        XCTAssertEqual(message?.tags ?? [], ["Goal"])
        XCTAssertEqual(message?.goal, "ship v0.12")
    }

    func testGoalInputParserStripsGoalCommandAndKeepsBoundary() throws {
        let parsed = try XCTUnwrap(GoalInputParser.parse("  /goal   ship v0.12  ").successValue)

        XCTAssertEqual(parsed.text, "ship v0.12")
        XCTAssertEqual(parsed.goal, "ship v0.12")
        XCTAssertEqual(parsed.tags, ["Goal"])

        let plain = try XCTUnwrap(GoalInputParser.parse("/goals are useful").successValue)
        XCTAssertEqual(plain.text, "/goals are useful")
        XCTAssertNil(plain.goal)
        XCTAssertTrue(plain.tags.isEmpty)
    }

    func testGoalInputParserRejectsEmptyGoal() {
        XCTAssertEqual(GoalInputParser.parse("/goal").failureValue, .missingGoal)
        XCTAssertEqual(GoalInputParser.parse(" /goal   ").failureValue, .missingGoal)
        XCTAssertEqual(GoalInputParser.parse("   ").failureValue, .empty)
    }

    func testArtifactProgressProjectionTracksActiveJobsAndClearsOnArtifactAdded() {
        let session = SessionID(rawValue: "sess_artifacts")
        let artifact = ArtifactID(rawValue: "art_image")
        func env(_ seq: Int, _ event: Event) -> Envelope {
            Envelope(seq: seq, ts: Date(timeIntervalSince1970: Double(seq)), session: session, event: event)
        }

        var projection = ArtifactProgressProjection.build(from: [
            env(0, .artifactProgress(.init(artifactId: artifact, progress: 0.1, state: "queued"))),
            env(1, .artifactProgress(.init(artifactId: artifact, progress: 0.6, state: "running"))),
        ])

        XCTAssertEqual(projection.active, [
            ArtifactProgressSnapshot(id: artifact, progress: 0.6, state: "running", seq: 1)
        ])

        projection.apply(env(2, .artifactAdded(.init(
            artifactId: artifact,
            kind: "image",
            mime: "image/png",
            path: "/tmp/image.png",
            prompt: "draw"))))

        XCTAssertTrue(projection.active.isEmpty)
    }
}

private extension Result {
    var successValue: Success? {
        if case .success(let value) = self { return value }
        return nil
    }

    var failureValue: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}
