import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisConversation

final class ModelHistoryCompactionEventLogTests: XCTestCase {
    private func temporaryLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-history-compaction-\(UUID().uuidString)",
                isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    private func historyItem(
        agent: AgentID,
        itemID: String
    ) -> ModelHistoryItemPayload {
        .message(
            itemID: itemID,
            turnID: TurnID(rawValue: "turn-\(itemID)"),
            agent: agent,
            taskID: nil,
            submissionID: nil,
            taskAttempt: nil,
            role: .assistant,
            content: "history \(itemID)")
    }

    private func checkpoint(
        agent: AgentID,
        schemaVersion: Int =
            ModelHistoryCompactedPayload.currentSchemaVersion,
        message: String = "compacted",
        windowNumber: UInt64 = 1,
        firstWindowID: String =
            "018f47a0-7b1c-7cc0-8e5f-7f0a3c91d111",
        previousWindowID: String? = nil,
        windowID: String =
            "018f47a0-7b1c-7cc0-8e5f-7f0a3c91d222"
    ) -> ModelHistoryCompactedPayload {
        ModelHistoryCompactedPayload(
            schemaVersion: schemaVersion,
            agent: agent,
            message: message,
            replacementHistory: [
                ModelHistoryReplacementItem(
                    itemID: "summary-\(windowID)",
                    kind: .message,
                    role: .user,
                    messageClassification: .compactionSummary,
                    content: message),
            ],
            windowNumber: windowNumber,
            firstWindowID: firstWindowID,
            previousWindowID:
                previousWindowID ?? firstWindowID,
            windowID: windowID)
    }

    private func appendRaw(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func writeCrashJournal(
        fileURL: URL,
        session: SessionID,
        batchBytes: Data,
        firstSequence: Int
    ) throws {
        let original = try Data(contentsOf: fileURL)
        let prefixLength = min(
            original.count,
            EventLogWriteAheadJournal.prefixLimit)
        let journal = EventLogWriteAheadJournal(
            session: session,
            originalOffset: UInt64(original.count),
            prefixStartOffset:
                UInt64(original.count - prefixLength),
            prefixBytes: Data(original.suffix(prefixLength)),
            batchBytes: batchBytes,
            firstSequence: firstSequence,
            eventCount: 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(journal).write(
            to: fileURL.appendingPathExtension("wal"),
            options: .atomic)
    }

    func testCompactionCASAllowsUnrelatedAgentAndEventInterleaving()
        async throws
    {
        let url = temporaryLogURL()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent())
        }
        let session = SessionID(rawValue: "sess-compaction-cas")
        let main = AgentID(rawValue: "main")
        let worker = AgentID(rawValue: "worker")
        let first = try EventLog(session: session, fileURL: url)
        let second = try EventLog(session: session, fileURL: url)

        let source = try await first.append(
            .modelHistoryItem(
                historyItem(agent: main, itemID: "main-source")))
        _ = try await second.append(
            .userMessage(.init(text: "unrelated event")))
        _ = try await second.append(
            .modelHistoryItem(
                historyItem(agent: worker, itemID: "worker-source")))

        let appended = try await first.appendModelHistoryCompaction(
            checkpoint(agent: main),
            expectedLatestAgentHistorySeq: source.seq)

        XCTAssertEqual(appended.seq, 3)
        guard case .modelHistoryCompacted(let payload) = appended.event else {
            return XCTFail("expected a model-history compaction")
        }
        XCTAssertEqual(payload.agent, main)

        do {
            _ = try await second.appendModelHistoryCompaction(
                checkpoint(
                    agent: main,
                    windowID:
                        "018f47a0-7b1c-7cc0-8e5f-7f0a3c91d333"),
                expectedLatestAgentHistorySeq: source.seq)
            XCTFail("the prior checkpoint must advance the agent revision")
        } catch let error as EventLogError {
            XCTAssertEqual(
                error,
                .staleModelHistory(
                    expectedLatestAgentHistorySeq: source.seq,
                    actualLatestAgentHistorySeq: appended.seq))
        }
    }

    func testCompactionCASRejectsSameAgentHistoryChange()
        async throws
    {
        let url = temporaryLogURL()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent())
        }
        let session = SessionID(rawValue: "sess-compaction-stale")
        let main = AgentID(rawValue: "main")
        let first = try EventLog(session: session, fileURL: url)
        let second = try EventLog(session: session, fileURL: url)

        let source = try await first.append(
            .modelHistoryItem(
                historyItem(agent: main, itemID: "source")))
        let changed = try await second.append(
            .modelHistoryItem(
                historyItem(agent: main, itemID: "newer")))

        do {
            _ = try await first.appendModelHistoryCompaction(
                checkpoint(agent: main),
                expectedLatestAgentHistorySeq: source.seq)
            XCTFail("stale compaction must not be appended")
        } catch let error as EventLogError {
            XCTAssertEqual(
                error,
                .staleModelHistory(
                    expectedLatestAgentHistorySeq: source.seq,
                    actualLatestAgentHistorySeq: changed.seq))
        }

        let replayed = try await first.replayChecked()
        XCTAssertEqual(replayed.map(\.seq), [0, 1])
    }

    func testCompactionAcceptsContiguousWindowLineage()
        async throws
    {
        let url = temporaryLogURL()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent())
        }
        let session = SessionID(rawValue: "sess-compaction-lineage")
        let main = AgentID(rawValue: "main")
        let log = try EventLog(session: session, fileURL: url)
        let source = try await log.append(
            .modelHistoryItem(
                historyItem(agent: main, itemID: "source")))
        let firstPayload = checkpoint(agent: main)
        let first = try await log.appendModelHistoryCompaction(
            firstPayload,
            expectedLatestAgentHistorySeq: source.seq)
        let secondPayload = checkpoint(
            agent: main,
            windowNumber: 2,
            firstWindowID: firstPayload.firstWindowID,
            previousWindowID: firstPayload.windowID,
            windowID:
                "018f47a0-7b1c-7cc0-8e5f-7f0a3c91d333")

        let second = try await log.appendModelHistoryCompaction(
            secondPayload,
            expectedLatestAgentHistorySeq: first.seq)

        XCTAssertEqual(second.seq, 2)
        let replayed = try await log.replayChecked()
        XCTAssertEqual(replayed.map(\.seq), [0, 1, 2])
    }

    func testCompactionRejectsNonContiguousLineageBeforePersistence()
        async throws
    {
        let url = temporaryLogURL()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent())
        }
        let session = SessionID(
            rawValue: "sess-compaction-bad-lineage")
        let main = AgentID(rawValue: "main")
        let log = try EventLog(session: session, fileURL: url)
        let source = try await log.append(
            .modelHistoryItem(
                historyItem(agent: main, itemID: "source")))
        let firstPayload = checkpoint(agent: main)
        let first = try await log.appendModelHistoryCompaction(
            firstPayload,
            expectedLatestAgentHistorySeq: source.seq)
        let before = try Data(contentsOf: url)
        let skippedWindow = checkpoint(
            agent: main,
            windowNumber: 3,
            firstWindowID: firstPayload.firstWindowID,
            previousWindowID: firstPayload.windowID,
            windowID:
                "018f47a0-7b1c-7cc0-8e5f-7f0a3c91d333")

        do {
            _ = try await log.appendModelHistoryCompaction(
                skippedWindow,
                expectedLatestAgentHistorySeq: first.seq)
            XCTFail("a skipped window number must fail closed")
        } catch let error as EventLogError {
            XCTAssertEqual(
                error,
                .invalidModelHistoryWindowLineage)
        }

        XCTAssertEqual(try Data(contentsOf: url), before)
        let replayed = try await log.replayChecked()
        XCTAssertEqual(replayed.map(\.seq), [0, 1])
    }

    func testCompactionWriterRejectsV1AfterMediaAwareDirectHistory()
        async throws
    {
        let url = temporaryLogURL()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent())
        }
        let main = AgentID(rawValue: "main")
        let log = try EventLog(
            session: SessionID(rawValue: "sess-media-schema-lineage"),
            fileURL: url)
        let artifactID = ArtifactID(rawValue: "artifact-media-lineage")
        let source = try await log.append(.modelHistoryItem(.message(
            itemID: "media-source",
            turnID: TurnID(rawValue: "turn-media-source"),
            agent: main,
            taskID: nil,
            submissionID: SubmissionID(rawValue: "submission-media-source"),
            taskAttempt: 1,
            role: .user,
            content: "image",
            attachmentIDs: [artifactID],
            imageReferences: [ModelHistoryImageReference(
                artifactID: artifactID,
                mimeType: "image/png",
                byteCount: 8,
                sha256: String(repeating: "a", count: 64))],
            messageClassification: .realUser)))
        let before = try Data(contentsOf: url)

        do {
            _ = try await log.appendModelHistoryCompaction(
                checkpoint(agent: main),
                expectedLatestAgentHistorySeq: source.seq)
            XCTFail("a v1 checkpoint must not mask v2 direct history")
        } catch let error as EventLogError {
            XCTAssertEqual(error, .invalidModelHistoryWindowLineage)
        }
        XCTAssertEqual(try Data(contentsOf: url), before)

        let appended = try await log.appendModelHistoryCompaction(
            checkpoint(
                agent: main,
                schemaVersion:
                    ModelHistoryCompactedPayload.mediaSchemaVersion),
            expectedLatestAgentHistorySeq: source.seq)
        XCTAssertEqual(appended.seq, source.seq + 1)
    }

    func testCompactionRejectsReusedWindowIDBeforePersistence()
        async throws
    {
        let url = temporaryLogURL()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent())
        }
        let session = SessionID(
            rawValue: "sess-compaction-reused-window")
        let main = AgentID(rawValue: "main")
        let log = try EventLog(session: session, fileURL: url)
        let source = try await log.append(
            .modelHistoryItem(
                historyItem(agent: main, itemID: "source")))
        let firstPayload = checkpoint(agent: main)
        let first = try await log.appendModelHistoryCompaction(
            firstPayload,
            expectedLatestAgentHistorySeq: source.seq)
        let secondPayload = checkpoint(
            agent: main,
            windowNumber: 2,
            firstWindowID: firstPayload.firstWindowID,
            previousWindowID: firstPayload.windowID,
            windowID:
                "018f47a0-7b1c-7cc0-8e5f-7f0a3c91d333")
        let second = try await log.appendModelHistoryCompaction(
            secondPayload,
            expectedLatestAgentHistorySeq: first.seq)
        let before = try Data(contentsOf: url)
        let reused = checkpoint(
            agent: main,
            windowNumber: 3,
            firstWindowID: firstPayload.firstWindowID,
            previousWindowID: secondPayload.windowID,
            windowID: firstPayload.windowID)

        do {
            _ = try await log.appendModelHistoryCompaction(
                reused,
                expectedLatestAgentHistorySeq: second.seq)
            XCTFail("a reused window ID must fail closed")
        } catch let error as EventLogError {
            XCTAssertEqual(error, .reusedModelHistoryWindowID)
        }

        XCTAssertEqual(try Data(contentsOf: url), before)
        let replayed = try await log.replayChecked()
        XCTAssertEqual(replayed.map(\.seq), [0, 1, 2])
    }

    func testCompactionRejectsInvalidInitialWindowAndGenericAppend()
        async throws
    {
        let url = temporaryLogURL()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent())
        }
        let session = SessionID(
            rawValue: "sess-compaction-specialized-append")
        let main = AgentID(rawValue: "main")
        let log = try EventLog(session: session, fileURL: url)
        let valid = checkpoint(agent: main)

        do {
            _ = try await log.append(
                .modelHistoryCompacted(valid))
            XCTFail("generic append must not bypass the lineage gate")
        } catch let error as EventLogError {
            XCTAssertEqual(
                error,
                .modelHistoryCompactionRequiresValidatedAppend)
        }

        var invalidInitial = valid
        invalidInitial.windowID = invalidInitial.firstWindowID
        do {
            _ = try await log.appendModelHistoryCompaction(
                invalidInitial,
                expectedLatestAgentHistorySeq: nil)
            XCTFail("an invalid initial window must fail closed")
        } catch let error
            as ModelHistoryCompactedPayloadValidationError
        {
            XCTAssertEqual(error, .invalidInitialWindow)
        }

        let replayed = try await log.replayChecked()
        XCTAssertEqual(replayed, [])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path))
    }

    func testCompactionCASRejectsUnknownFutureEvent()
        async throws
    {
        let url = temporaryLogURL()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent())
        }
        let session = SessionID(rawValue: "sess-compaction-future")
        let log = try EventLog(session: session, fileURL: url)
        _ = try await log.append(.userMessage(.init(text: "known")))
        let future = Data(
            #"{"seq":1,"ts":"2023-11-14T22:13:20Z","session":"sess-compaction-future","v":1,"type":"future_history","payload":{}}"#
                .utf8)
        try appendRaw(future + Data([0x0A]), to: url)

        do {
            _ = try await log.appendModelHistoryCompaction(
                checkpoint(agent: AgentID(rawValue: "main")),
                expectedLatestAgentHistorySeq: nil)
            XCTFail("unknown future history must fail closed")
        } catch let error as EventLogError {
            XCTAssertEqual(error, .unsupportedEventTypes)
        }
    }

    func testCompactionCASRejectsSequenceGap()
        async throws
    {
        let url = temporaryLogURL()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent())
        }
        let session = SessionID(rawValue: "sess-compaction-gap")
        let log = try EventLog(session: session, fileURL: url)
        _ = try await log.append(.userMessage(.init(text: "known")))
        var gap = try Envelope.makeEncoder().encode(
            Envelope(
                seq: 2,
                ts: Date(timeIntervalSince1970: 1_700_000_002),
                session: session,
                event: .userMessage(.init(text: "after gap"))))
        gap.append(0x0A)
        try appendRaw(gap, to: url)

        do {
            _ = try await log.appendModelHistoryCompaction(
                checkpoint(agent: AgentID(rawValue: "main")),
                expectedLatestAgentHistorySeq: nil)
            XCTFail("a sequence gap must fail closed")
        } catch let error as EventLogError {
            XCTAssertEqual(error, .incompleteEventHistory)
        }
    }

    func testLargeSingleCompactionUsesRecoverableWALBoundary()
        async throws
    {
        XCTAssertFalse(EventLog.shouldJournalWrite(
            eventCount: 1,
            byteCount:
                EventLog.journaledSingleEventByteThreshold - 1))
        XCTAssertTrue(EventLog.shouldJournalWrite(
            eventCount: 1,
            byteCount:
                EventLog.journaledSingleEventByteThreshold))

        let url = temporaryLogURL()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent())
        }
        let session = SessionID(rawValue: "sess-large-compaction")
        let initial = try EventLog(session: session, fileURL: url)
        _ = try await initial.append(
            .userMessage(.init(text: "committed prefix")))
        let original = try Data(contentsOf: url)
        let large = checkpoint(
            agent: AgentID(rawValue: "main"),
            message: String(repeating: "x", count: 70 * 1_024))
        let envelope = Envelope(
            seq: 1,
            ts: Date(timeIntervalSince1970: 1_700_000_001),
            session: session,
            event: .modelHistoryCompacted(large))
        var batch = try Envelope.makeEncoder().encode(envelope)
        batch.append(0x0A)
        XCTAssertGreaterThanOrEqual(
            batch.count,
            EventLog.journaledSingleEventByteThreshold)

        try writeCrashJournal(
            fileURL: url,
            session: session,
            batchBytes: batch,
            firstSequence: 1)
        try appendRaw(
            Data(batch.prefix(batch.count / 2)),
            to: url)

        let recovered = try EventLog(session: session, fileURL: url)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let afterRecovery = try await recovered.replayChecked()
        XCTAssertEqual(afterRecovery.map(\.seq), [0])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathExtension("wal").path))

        let appended = try await recovered
            .appendModelHistoryCompaction(
                large,
                expectedLatestAgentHistorySeq: nil)
        XCTAssertEqual(appended.seq, 1)
        let afterAppend = try await recovered.replayChecked()
        XCTAssertEqual(afterAppend.map(\.seq), [0, 1])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathExtension("wal").path))
    }
}
