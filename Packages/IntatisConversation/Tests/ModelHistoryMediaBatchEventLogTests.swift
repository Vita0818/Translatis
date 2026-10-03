import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisConversation

final class ModelHistoryMediaBatchEventLogTests: XCTestCase {
    private func temporaryLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-history-media-batch-\(UUID().uuidString)",
                isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    private func reference(
        _ artifactID: String,
        mimeType: String = "image/png",
        byteCount: Int = 12,
        digestCharacter: Character = "a"
    ) -> ModelHistoryImageReference {
        ModelHistoryImageReference(
            artifactID: ArtifactID(rawValue: artifactID),
            mimeType: mimeType,
            byteCount: byteCount,
            sha256: String(repeating: digestCharacter, count: 64))
    }

    private func imageBlock(
        _ reference: ModelHistoryImageReference
    ) -> MCPContentBlock {
        MCPContentBlock(
            kind: .imageReference,
            artifactID: reference.artifactID,
            mimeType: reference.mimeType,
            byteCount: reference.byteCount,
            sha256: reference.sha256)
    }

    private func toolResult(
        callID: String,
        content: [MCPContentBlock]?,
        turnID: TurnID? = TurnID(rawValue: "turn-media-batch")
    ) -> Event {
        .toolResult(ToolResultPayload(
            toolCallId: callID,
            observation: "canonical tool observation",
            turnID: turnID,
            structuredResult: content.map {
                MCPStructuredToolResult(content: $0)
            }))
    }

    private func functionOutput(
        callID: String,
        itemID: String = "media-output",
        turnID: TurnID = TurnID(rawValue: "turn-media-batch"),
        agent: AgentID = AgentID(rawValue: "main"),
        taskID: TaskID? = nil,
        taskAttempt: Int? = nil,
        references: [ModelHistoryImageReference]
    ) -> Event {
        .modelHistoryItem(.functionCallOutput(
            itemID: itemID,
            turnID: turnID,
            agent: agent,
            taskID: taskID,
            submissionID: nil,
            taskAttempt: taskAttempt,
            callID: callID,
            output: "canonical tool observation",
            imageReferences: references))
    }

    private func settlement(
        callID: String,
        executionID: String? = nil,
        agent: AgentID? = AgentID(rawValue: "main"),
        taskID: TaskID? = nil,
        attempt: Int? = nil
    ) -> Event {
        .toolExecutionSettled(ToolExecutionSettledPayload(
            executionID: executionID ?? "execution-\(callID)",
            taskID: taskID,
            attempt: attempt,
            toolCallID: callID,
            agent: agent,
            tool: "media_tool",
            sideEffect: .readOnly,
            outcome: .succeeded,
            effectDisposition: .committed))
    }

    private func assertRejectedBeforeBytes(
        _ events: [Event],
        label: String,
        priorEvents: [Event] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let url = temporaryLogURL()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent())
        }
        let log = try EventLog(
            session: SessionID(rawValue: "sess-\(UUID().uuidString)"),
            fileURL: url)
        _ = try await log.append(.userMessage(.init(text: "seed")))
        for event in priorEvents {
            _ = try await log.append(event)
        }
        let before = try Data(contentsOf: url)

        do {
            _ = try await log.append(events)
            XCTFail("\(label) must reject the whole batch", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? EventLogError,
                .invalidModelHistoryMediaBatch,
                label,
                file: file,
                line: line)
        }

        XCTAssertEqual(
            try Data(contentsOf: url),
            before,
            label,
            file: file,
            line: line)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: url.appendingPathExtension("wal").path),
            label,
            file: file,
            line: line)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: url.appendingPathExtension("wal.tmp").path),
            label,
            file: file,
            line: line)
    }

    func testMatchingMediaFunctionOutputPersistsWithCompletionEvents()
        async throws
    {
        let url = temporaryLogURL()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent())
        }
        let log = try EventLog(
            session: SessionID(rawValue: "sess-media-batch-valid"),
            fileURL: url)
        let first = reference("artifact-first")
        let second = reference(
            "artifact-second",
            mimeType: "image/jpeg",
            byteCount: 23,
            digestCharacter: "b")
        let events: [Event] = [
            functionOutput(callID: "call-valid", references: [first, second]),
            toolResult(callID: "call-valid", content: [
                MCPContentBlock(kind: .text, text: "before"),
                imageBlock(first),
                MCPContentBlock(kind: .text, text: "between"),
                imageBlock(second),
            ]),
            settlement(callID: "call-valid"),
        ]

        let appended = try await log.append(events)
        let replayed = try await log.replayChecked()

        XCTAssertEqual(appended.map(\.event), events)
        XCTAssertEqual(replayed.map(\.event), events)
    }

    func testMediaFunctionOutputRejectsOrphanBeforeWAL()
        async throws
    {
        let image = reference("artifact-orphan")
        try await assertRejectedBeforeBytes(
            [
                settlement(callID: "call-orphan"),
                functionOutput(callID: "call-orphan", references: [image]),
            ],
            label: "missing tool result")
        try await assertRejectedBeforeBytes(
            [functionOutput(callID: "call-orphan", references: [image])],
            label: "completion events from an earlier batch",
            priorEvents: [
                toolResult(
                    callID: "call-orphan",
                    content: [imageBlock(image)]),
                settlement(callID: "call-orphan"),
            ])
        try await assertRejectedBeforeBytes([
            toolResult(
                callID: "call-orphan",
                content: [imageBlock(image)]),
            functionOutput(callID: "call-orphan", references: [image]),
        ], label: "missing execution settlement")
        try await assertRejectedBeforeBytes([
            toolResult(callID: "another-call", content: [imageBlock(image)]),
            settlement(callID: "another-call"),
            functionOutput(callID: "call-orphan", references: [image]),
        ], label: "mismatched call ID")
        try await assertRejectedBeforeBytes([
            toolResult(callID: "call-orphan", content: nil),
            settlement(callID: "call-orphan"),
            functionOutput(callID: "call-orphan", references: [image]),
        ], label: "missing structured result")
    }

    func testMediaFunctionOutputRequiresExactToolResultTurn()
        async throws
    {
        let image = reference("artifact-turn")
        let outputTurn = TurnID(rawValue: "turn-output")
        try await assertRejectedBeforeBytes([
            toolResult(
                callID: "call-turn",
                content: [imageBlock(image)],
                turnID: nil),
            settlement(callID: "call-turn"),
            functionOutput(
                callID: "call-turn",
                turnID: outputTurn,
                references: [image]),
        ], label: "missing tool-result turn ID")
        try await assertRejectedBeforeBytes([
            toolResult(
                callID: "call-turn",
                content: [imageBlock(image)],
                turnID: TurnID(rawValue: "turn-other")),
            settlement(callID: "call-turn"),
            functionOutput(
                callID: "call-turn",
                turnID: outputTurn,
                references: [image]),
        ], label: "mismatched tool-result turn ID")
    }

    func testDifferentTurnsMayReuseCallIDWithoutCollision()
        async throws
    {
        let url = temporaryLogURL()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent())
        }
        let log = try EventLog(
            session: SessionID(rawValue: "sess-media-batch-reused-call"),
            fileURL: url)
        let firstTurn = TurnID(rawValue: "turn-first")
        let secondTurn = TurnID(rawValue: "turn-second")
        let firstImage = reference("artifact-first-turn")
        let secondImage = reference(
            "artifact-second-turn",
            mimeType: "image/jpeg",
            byteCount: 23,
            digestCharacter: "b")
        let firstEvents: [Event] = [
            functionOutput(
                callID: "reused-call",
                itemID: "first-output",
                turnID: firstTurn,
                references: [firstImage]),
            toolResult(
                callID: "reused-call",
                content: [imageBlock(firstImage)],
                turnID: firstTurn),
            settlement(
                callID: "reused-call",
                executionID: "execution-reused-first"),
        ]
        let secondEvents: [Event] = [
            functionOutput(
                callID: "reused-call",
                itemID: "second-output",
                turnID: secondTurn,
                references: [secondImage]),
            toolResult(
                callID: "reused-call",
                content: [imageBlock(secondImage)],
                turnID: secondTurn),
            settlement(
                callID: "reused-call",
                executionID: "execution-reused-second"),
        ]

        let firstAppended = try await log.append(firstEvents)
        let secondAppended = try await log.append(secondEvents)

        XCTAssertEqual(firstAppended.map(\.event), firstEvents)
        XCTAssertEqual(secondAppended.map(\.event), secondEvents)
    }

    func testMediaFunctionOutputRequiresExactSettlementIdentity()
        async throws
    {
        let image = reference("artifact-settlement-identity")
        let taskID = TaskID(rawValue: "task-media")
        let output = functionOutput(
            callID: "call-identity",
            agent: AgentID(rawValue: "main"),
            taskID: taskID,
            taskAttempt: 2,
            references: [image])
        let result = toolResult(
            callID: "call-identity",
            content: [imageBlock(image)])

        try await assertRejectedBeforeBytes([
            result,
            settlement(
                callID: "call-identity",
                agent: AgentID(rawValue: "worker"),
                taskID: taskID,
                attempt: 2),
            output,
        ], label: "mismatched settlement agent")
        try await assertRejectedBeforeBytes([
            result,
            settlement(
                callID: "call-identity",
                taskID: TaskID(rawValue: "task-other"),
                attempt: 2),
            output,
        ], label: "mismatched settlement task")
        try await assertRejectedBeforeBytes([
            result,
            settlement(
                callID: "call-identity",
                taskID: taskID,
                attempt: 1),
            output,
        ], label: "mismatched settlement attempt")
    }

    func testMediaFunctionOutputRejectsDescriptorMismatchBeforeWAL()
        async throws
    {
        let expected = reference("artifact-expected")
        let mismatches: [(String, ModelHistoryImageReference)] = [
            ("artifact ID", reference("artifact-other")),
            ("MIME", reference(
                "artifact-expected",
                mimeType: "image/jpeg")),
            ("byte count", reference(
                "artifact-expected",
                byteCount: expected.byteCount + 1)),
            ("SHA-256", reference(
                "artifact-expected",
                digestCharacter: "b")),
        ]
        for (label, mismatch) in mismatches {
            try await assertRejectedBeforeBytes([
                toolResult(
                    callID: "call-mismatch",
                    content: [imageBlock(mismatch)]),
                settlement(callID: "call-mismatch"),
                functionOutput(
                    callID: "call-mismatch",
                    references: [expected]),
            ], label: label)
        }

        let second = reference(
            "artifact-second",
            mimeType: "image/jpeg",
            byteCount: 23,
            digestCharacter: "b")
        try await assertRejectedBeforeBytes([
            toolResult(
                callID: "call-order",
                content: [imageBlock(second), imageBlock(expected)]),
            settlement(callID: "call-order"),
            functionOutput(
                callID: "call-order",
                references: [expected, second]),
        ], label: "image order")
    }

    func testMediaFunctionOutputRejectsDuplicateBindingBeforeWAL()
        async throws
    {
        let image = reference("artifact-duplicate")
        let result = toolResult(
            callID: "call-duplicate",
            content: [imageBlock(image)])
        let output = functionOutput(
            callID: "call-duplicate",
            references: [image])

        try await assertRejectedBeforeBytes(
            [result, result, settlement(callID: "call-duplicate"), output],
            label: "duplicate tool results")
        try await assertRejectedBeforeBytes([
            result,
            settlement(callID: "call-duplicate"),
            output,
            functionOutput(
                callID: "call-duplicate",
                itemID: "media-output-duplicate",
                references: [image]),
        ], label: "duplicate function outputs")
        try await assertRejectedBeforeBytes([
            result,
            settlement(
                callID: "call-duplicate",
                executionID: "execution-duplicate-first"),
            settlement(
                callID: "call-duplicate",
                executionID: "execution-duplicate-second"),
            output,
        ], label: "duplicate execution settlements")
    }
}
