import XCTest
import IntatisCore
@testable import IntatisProtocol

final class ModelHistoryProtocolTests: XCTestCase {
    private let encoder = Envelope.makeEncoder()
    private let decoder = Envelope.makeDecoder()

    func testModelHistoryPayloadKindsCodableRoundTrip() throws {
        let turnID = TurnID(rawValue: "turn_history")
        let agent = AgentID(rawValue: "main")
        let taskID = TaskID(rawValue: "task_history")
        let submissionID = SubmissionID(rawValue: "sub_history")
        let metadata = (
            turnID: turnID,
            agent: agent,
            taskID: Optional(taskID),
            submissionID: Optional(submissionID),
            taskAttempt: Optional(2)
        )
        let payloads: [ModelHistoryItemPayload] = [
            .message(
                itemID: "item_user",
                turnID: metadata.turnID,
                agent: metadata.agent,
                taskID: metadata.taskID,
                submissionID: metadata.submissionID,
                taskAttempt: metadata.taskAttempt,
                role: .user,
                content: "Inspect the project.",
                attachmentIDs: [
                    ArtifactID(rawValue: "artifact_one"),
                    ArtifactID(rawValue: "artifact_two"),
                ],
                messageClassification: .realUser),
            .functionCallBatch(
                itemID: "item_calls",
                turnID: metadata.turnID,
                agent: metadata.agent,
                taskID: metadata.taskID,
                submissionID: metadata.submissionID,
                taskAttempt: metadata.taskAttempt,
                content: "I will inspect both files.",
                calls: [
                    ModelHistoryFunctionCall(
                        callID: "call_read",
                        name: "read_file",
                        arguments: #"{"path":"README.md"}"#),
                    ModelHistoryFunctionCall(
                        callID: "call_redacted",
                        name: "write_stdin",
                        arguments: #"{"_intatis":"arguments_redacted"}"#,
                        argumentsRedacted: true),
                ]),
            .functionCallOutput(
                itemID: "item_output",
                turnID: metadata.turnID,
                agent: metadata.agent,
                taskID: metadata.taskID,
                submissionID: metadata.submissionID,
                taskAttempt: metadata.taskAttempt,
                callID: "call_read",
                output: "README contents"),
            .toolSearchOutput(
                itemID: "item_tool_search_output",
                turnID: metadata.turnID,
                agent: metadata.agent,
                taskID: metadata.taskID,
                submissionID: metadata.submissionID,
                taskAttempt: metadata.taskAttempt,
                callID: "call_search",
                tools: [
                    .object([
                        "type": .string("function"),
                        "name": .string("calendar_create"),
                    ]),
                ]),
            ModelHistoryItemPayload(
                itemID: "item_reasoning",
                turnID: metadata.turnID,
                agent: metadata.agent,
                taskID: metadata.taskID,
                submissionID: metadata.submissionID,
                taskAttempt: metadata.taskAttempt,
                kind: .reasoning,
                reasoningSummary: ["Checked the durable history."],
                reasoningContent: "Model-visible reasoning content",
                encryptedReasoningContent: "opaque-encrypted-content"),
        ]

        for payload in payloads {
            let data = try JSONEncoder().encode(payload)
            XCTAssertEqual(
                try JSONDecoder().decode(ModelHistoryItemPayload.self, from: data),
                payload)
        }
    }

    func testLegacyModelHistoryUserMessageDecodesWithoutClassification()
        throws
    {
        let legacy = #"""
        {
          "schemaVersion": 1,
          "itemID": "legacy-user",
          "turnID": "turn-legacy",
          "agent": "main",
          "kind": "message",
          "role": "user",
          "content": "Legacy user text"
        }
        """#

        let decoded = try JSONDecoder().decode(
            ModelHistoryItemPayload.self,
            from: Data(legacy.utf8))

        XCTAssertEqual(decoded.role, .user)
        XCTAssertNil(decoded.messageClassification)
    }

    func testMediaAwareDirectHistoryRoundTripsWithVerifiedImageReferences()
        throws
    {
        let reference = ModelHistoryImageReference(
            artifactID: ArtifactID(rawValue: "artifact-image"),
            mimeType: "image/png",
            byteCount: 128,
            sha256: String(repeating: "a", count: 64))
        let user = ModelHistoryItemPayload.message(
            itemID: "media-user",
            turnID: TurnID(rawValue: "turn-media"),
            agent: AgentID(rawValue: "main"),
            taskID: nil,
            submissionID: SubmissionID(rawValue: "sub-media"),
            taskAttempt: 1,
            role: .user,
            content: "inspect",
            attachmentIDs: [reference.artifactID],
            imageReferences: [reference],
            messageClassification: .realUser)
        let output = ModelHistoryItemPayload.functionCallOutput(
            itemID: "media-output",
            turnID: user.turnID,
            agent: user.agent,
            taskID: nil,
            submissionID: user.submissionID,
            taskAttempt: 1,
            callID: "call-image",
            output: "",
            imageReferences: [reference])

        for payload in [user, output] {
            XCTAssertEqual(
                payload.schemaVersion,
                ModelHistoryItemPayload.mediaSchemaVersion)
            let data = try JSONEncoder().encode(payload)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    ModelHistoryItemPayload.self,
                    from: data),
                payload)
        }
    }

    func testFunctionCallOutputGoldenShapeAllowsExplicitEmptyTextOrMedia()
        throws
    {
        let turnID = TurnID(rawValue: "turn-output-shape")
        let agent = AgentID(rawValue: "main")
        let textOutput = ModelHistoryItemPayload.functionCallOutput(
            itemID: "text-output",
            turnID: turnID,
            agent: agent,
            taskID: nil,
            submissionID: nil,
            taskAttempt: nil,
            callID: "call-text",
            output: "complete")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(textOutput)) as? [String: Any])

        XCTAssertEqual(Set(object.keys), [
            "agent", "callID", "itemID", "kind", "output",
            "schemaVersion", "turnID",
        ])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["kind"] as? String, "function_call_output")
        XCTAssertEqual(object["output"] as? String, "complete")

        var emptyTextOutput = textOutput
        emptyTextOutput.output = ""
        XCTAssertNoThrow(try emptyTextOutput.validate())
        let emptyTextData = try JSONEncoder().encode(emptyTextOutput)
        let emptyTextObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: emptyTextData)
                as? [String: Any])
        XCTAssertEqual(emptyTextObject["output"] as? String, "")
        XCTAssertEqual(
            try JSONDecoder().decode(
                ModelHistoryItemPayload.self,
                from: emptyTextData),
            emptyTextOutput)

        var missingTextOutput = textOutput
        missingTextOutput.output = nil
        XCTAssertThrowsError(try missingTextOutput.validate()) {
            XCTAssertEqual(
                $0 as? ModelHistoryItemPayloadValidationError,
                .invalidShape(
                    "function-call output fields are inconsistent"))
        }

        let reference = ModelHistoryImageReference(
            artifactID: ArtifactID(rawValue: "artifact-output-shape"),
            mimeType: "image/png",
            byteCount: 1,
            sha256: String(repeating: "c", count: 64))
        let mediaOutput = ModelHistoryItemPayload.functionCallOutput(
            itemID: "media-output",
            turnID: turnID,
            agent: agent,
            taskID: nil,
            submissionID: nil,
            taskAttempt: nil,
            callID: "call-media",
            output: "",
            imageReferences: [reference])
        XCTAssertNoThrow(try mediaOutput.validate())
        XCTAssertEqual(
            mediaOutput.schemaVersion,
            ModelHistoryItemPayload.mediaSchemaVersion)
    }

    func testMediaAwareHistoryRejectsInvalidVersionShapeAndDescriptor()
        throws
    {
        let reference = ModelHistoryImageReference(
            artifactID: ArtifactID(rawValue: "artifact-image"),
            mimeType: "image/png",
            byteCount: 128,
            sha256: String(repeating: "b", count: 64))
        var v1WithReference = ModelHistoryItemPayload.message(
            itemID: "v1-with-media",
            turnID: TurnID(rawValue: "turn-v1-media"),
            agent: AgentID(rawValue: "main"),
            taskID: nil,
            submissionID: SubmissionID(rawValue: "sub-v1-media"),
            taskAttempt: 1,
            role: .user,
            content: "inspect",
            attachmentIDs: [reference.artifactID],
            imageReferences: [reference],
            messageClassification: .realUser)
        v1WithReference.schemaVersion =
            ModelHistoryItemPayload.currentSchemaVersion
        XCTAssertThrowsError(try JSONEncoder().encode(v1WithReference))

        var unsupportedMIME = reference
        unsupportedMIME.mimeType = "image/webp"
        XCTAssertThrowsError(try unsupportedMIME.validate()) {
            XCTAssertEqual(
                $0 as? ModelHistoryImageReferenceValidationError,
                .unsupportedMIMEType("image/webp"))
        }

        var mediaCheckpoint = validCheckpoint()
        mediaCheckpoint.schemaVersion =
            ModelHistoryCompactedPayload.mediaSchemaVersion
        mediaCheckpoint.replacementHistory.insert(
            ModelHistoryReplacementItem(
                itemID: "old-media-user",
                sourceSubmissionID:
                    SubmissionID(rawValue: "sub-old-media"),
                kind: .message,
                role: .user,
                messageClassification: .realUser,
                content: "old image request",
                attachmentIDs: [reference.artifactID],
                imageReferences: [reference]),
            at: 0)
        XCTAssertThrowsError(try mediaCheckpoint.validate())
    }

    func testReplacementHistoryItemsPreserveProviderShapeWithoutInvocationCorrelation()
        throws
    {
        let items: [ModelHistoryReplacementItem] = [
            ModelHistoryReplacementItem(
                itemID: "replacement-user",
                sourceSubmissionID: SubmissionID(rawValue: "sub-source"),
                kind: .message,
                role: .user,
                messageClassification: .realUser,
                content: "Retained user text",
                attachmentIDs: [
                    ArtifactID(rawValue: "artifact-retained"),
                ]),
            ModelHistoryReplacementItem(
                itemID: "replacement-calls",
                kind: .functionCallBatch,
                content: "Inspecting.",
                functionCalls: [
                    ModelHistoryFunctionCall(
                        callID: "call-read",
                        name: "read_file",
                        arguments: #"{"path":"README.md"}"#),
                ]),
            ModelHistoryReplacementItem(
                itemID: "replacement-output",
                kind: .functionCallOutput,
                callID: "call-read",
                output: "contents"),
            ModelHistoryReplacementItem(
                itemID: "replacement-reasoning",
                kind: .reasoning,
                reasoningSummary: ["summary"],
                reasoningContent: "content",
                encryptedReasoningContent: "encrypted"),
            ModelHistoryReplacementItem(
                itemID: "replacement-summary",
                kind: .message,
                role: .user,
                messageClassification: .compactionSummary,
                content: "Compacted state"),
        ]

        let data = try JSONEncoder().encode(items)
        XCTAssertEqual(
            try JSONDecoder().decode(
                [ModelHistoryReplacementItem].self,
                from: data),
            items)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertNil(object[0]["turnID"])
        XCTAssertNil(object[0]["agent"])
        XCTAssertNil(object[0]["taskID"])
        XCTAssertNil(object[0]["taskAttempt"])
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ModelHistoryReplacementItem.self,
                from: Data(#"{"kind":"message","role":"user","content":"missing id"}"#.utf8)))
    }

    func testCompactedHistoryEnvelopeRoundTripsWithStableWireType()
        throws
    {
        let payload = ModelHistoryCompactedPayload(
            agent: AgentID(rawValue: "main"),
            message: "Compacted state",
            replacementHistory: [
                ModelHistoryReplacementItem(
                    itemID: "summary-item",
                    kind: .message,
                    role: .user,
                    messageClassification: .compactionSummary,
                    content: "Compacted state"),
            ],
            windowNumber: 1,
            firstWindowID: "018f47a0-7b1c-7cc0-8e5f-7f0a3c91d111",
            previousWindowID: "018f47a0-7b1c-7cc0-8e5f-7f0a3c91d111",
            windowID: "018f47a0-7b1c-7cc0-8e5f-7f0a3c91d222")
        let envelope = Envelope(
            seq: 9,
            ts: Date(timeIntervalSince1970: 1_700_000_009),
            session: SessionID(rawValue: "sess-compacted-history"),
            event: .modelHistoryCompacted(payload))

        let data = try encoder.encode(envelope)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            object["type"] as? String,
            "model_history_compacted")
        XCTAssertEqual(
            try decoder.decode(Envelope.self, from: data),
            envelope)
    }

    func testCompactedHistoryRejectsNonCanonicalWindowAndItemIDs()
        throws
    {
        let valid = validCheckpoint()
        XCTAssertNoThrow(try valid.validate())

        var uppercaseWindow = valid
        uppercaseWindow.windowID = uppercaseWindow.windowID.uppercased()
        XCTAssertThrowsError(try JSONEncoder().encode(uppercaseWindow))

        var emptyItemID = valid
        emptyItemID.replacementHistory[0].itemID = " "
        XCTAssertThrowsError(try JSONEncoder().encode(emptyItemID))

        var duplicateItemID = valid
        duplicateItemID.replacementHistory.append(
            duplicateItemID.replacementHistory[0])
        XCTAssertThrowsError(try JSONEncoder().encode(duplicateItemID))
    }

    func testCompactedHistoryRejectsUnsupportedSchemaAndInvalidSummary()
        throws
    {
        var unsupportedSchema = validCheckpoint()
        unsupportedSchema.schemaVersion =
            ModelHistoryCompactedPayload.mediaSchemaVersion + 1
        assertValidationError(
            unsupportedSchema,
            equals: .unsupportedSchemaVersion(3))

        var emptySummary = validCheckpoint()
        emptySummary.message = " \n "
        emptySummary.replacementHistory[0].content = emptySummary.message
        assertValidationError(
            emptySummary,
            equals: .emptySummary)

        var emptyReplacement = validCheckpoint()
        emptyReplacement.replacementHistory = []
        assertValidationError(
            emptyReplacement,
            equals: .emptyReplacementHistory)

        var mismatchedSummary = validCheckpoint()
        mismatchedSummary.replacementHistory[0].content =
            "a different summary"
        assertValidationError(
            mismatchedSummary,
            equals: .finalSummaryMismatch)

        var nonFinalSummary = validCheckpoint()
        nonFinalSummary.replacementHistory.insert(
            ModelHistoryReplacementItem(
                itemID: "early-summary",
                kind: .message,
                role: .user,
                messageClassification: .compactionSummary,
                content: "early"),
            at: 0)
        assertValidationError(
            nonFinalSummary,
            equals: .invalidReplacementItemClassification(index: 0))
    }

    func testCompactedHistoryRejectsUnsupportedReplacementShapesAndProvenance()
        throws
    {
        var unsupportedShape = validCheckpoint()
        unsupportedShape.replacementHistory.insert(
            ModelHistoryReplacementItem(
                itemID: "assistant",
                kind: .message,
                role: .assistant,
                messageClassification: .contextual,
                content: "not supported by v1"),
            at: 0)
        assertValidationError(
            unsupportedShape,
            equals: .unsupportedReplacementItemShape(index: 0))

        var missingRealUserSource = validCheckpoint()
        missingRealUserSource.replacementHistory.insert(
            ModelHistoryReplacementItem(
                itemID: "retained-user",
                kind: .message,
                role: .user,
                messageClassification: .realUser,
                content: "retained"),
            at: 0)
        assertValidationError(
            missingRealUserSource,
            equals: .invalidRealUserProvenance(index: 0))

        var contextualWithSource = validCheckpoint()
        contextualWithSource.replacementHistory.insert(
            ModelHistoryReplacementItem(
                itemID: "context",
                sourceSubmissionID:
                    SubmissionID(rawValue: "sub-context"),
                kind: .message,
                role: .user,
                messageClassification: .contextual,
                content: "turn context"),
            at: 0)
        assertValidationError(
            contextualWithSource,
            equals:
                .invalidReplacementItemClassification(index: 0))
    }

    func testCompactedHistoryRequiresCanonicalUUIDv7AndValidInitialWindow()
        throws
    {
        var nonV7 = validCheckpoint()
        nonV7.windowID =
            "550e8400-e29b-41d4-a716-446655440000"
        assertValidationError(
            nonV7,
            equals: .nonUUIDv7WindowID(field: "windowID"))

        var zeroWindow = validCheckpoint()
        zeroWindow.windowNumber = 0
        assertValidationError(
            zeroWindow,
            equals: .invalidInitialWindow)

        var wrongInitialPrevious = validCheckpoint()
        wrongInitialPrevious.previousWindowID =
            wrongInitialPrevious.windowID
        assertValidationError(
            wrongInitialPrevious,
            equals: .invalidInitialWindow)

        var reusedInitialID = validCheckpoint()
        reusedInitialID.windowID = reusedInitialID.firstWindowID
        assertValidationError(
            reusedInitialID,
            equals: .invalidInitialWindow)
    }

    func testModelHistoryEventsRoundTripThroughEnvelopeWithStableWireType() throws {
        let session = SessionID(rawValue: "sess_model_history")
        let agent = AgentID(rawValue: "main")
        let turnID = TurnID(rawValue: "turn_model_history")
        let payloads: [ModelHistoryItemPayload] = [
            .message(
                itemID: "item_assistant",
                turnID: turnID,
                agent: agent,
                taskID: TaskID(rawValue: "task_model_history"),
                submissionID: SubmissionID(rawValue: "sub_model_history"),
                taskAttempt: 1,
                role: .assistant,
                content: "Done."),
            .functionCallOutput(
                itemID: "item_tool_output",
                turnID: turnID,
                agent: agent,
                taskID: TaskID(rawValue: "task_model_history"),
                submissionID: SubmissionID(rawValue: "sub_model_history"),
                taskAttempt: 1,
                callID: "call_model_history",
                output: "ok"),
        ]

        for (index, payload) in payloads.enumerated() {
            let envelope = Envelope(
                seq: index + 1,
                ts: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                session: session,
                event: .modelHistoryItem(payload))
            let data = try encoder.encode(envelope)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any])

            XCTAssertEqual(object["type"] as? String, "model_history_item")
            XCTAssertEqual(try decoder.decode(Envelope.self, from: data), envelope)
        }
    }

    func testLegacyEnvelopeStillDecodesWithoutModelHistoryItem() throws {
        let legacyJSON = #"{"seq":7,"ts":"2023-11-14T22:13:20Z","session":"sess_legacy_history","v":1,"type":"message_completed","payload":{"messageId":"msg_legacy","role":"assistant","text":"legacy answer"}}"#

        let envelope = try decoder.decode(Envelope.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(envelope.seq, 7)
        XCTAssertEqual(envelope.session, SessionID(rawValue: "sess_legacy_history"))
        XCTAssertEqual(envelope.v, 1)
        XCTAssertEqual(
            envelope.event,
            .messageCompleted(MessageCompletedPayload(
                messageId: MessageID(rawValue: "msg_legacy"),
                role: .assistant,
                text: "legacy answer")))
    }

    func testLegacyFunctionCallDecodesWithFunctionKindDefaults()
        throws {
        let legacy = #"""
        {
          "callID": "legacy-call",
          "name": "read_file",
          "arguments": "{\"path\":\"README.md\"}",
          "argumentsRedacted": false
        }
        """#
        let decoded = try JSONDecoder().decode(
            ModelHistoryFunctionCall.self,
            from: Data(legacy.utf8))

        XCTAssertEqual(decoded.kind, .function)
        XCTAssertNil(decoded.namespace)
        XCTAssertNil(decoded.status)
        XCTAssertNil(decoded.execution)
    }

    private func validCheckpoint() -> ModelHistoryCompactedPayload {
        ModelHistoryCompactedPayload(
            agent: AgentID(rawValue: "main"),
            message: "summary",
            replacementHistory: [
                ModelHistoryReplacementItem(
                    itemID: "summary",
                    kind: .message,
                    role: .user,
                    messageClassification: .compactionSummary,
                    content: "summary"),
            ],
            windowNumber: 1,
            firstWindowID:
                "018f47a0-7b1c-7cc0-8e5f-7f0a3c91d111",
            previousWindowID:
                "018f47a0-7b1c-7cc0-8e5f-7f0a3c91d111",
            windowID:
                "018f47a0-7b1c-7cc0-8e5f-7f0a3c91d222")
    }

    private func assertValidationError(
        _ payload: ModelHistoryCompactedPayload,
        equals expected:
            ModelHistoryCompactedPayloadValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try payload.validate()
            XCTFail(
                "expected checkpoint validation to fail",
                file: file,
                line: line)
        } catch let error
            as ModelHistoryCompactedPayloadValidationError
        {
            XCTAssertEqual(
                error,
                expected,
                file: file,
                line: line)
        } catch {
            XCTFail(
                "unexpected validation error: \(error)",
                file: file,
                line: line)
        }
    }
}
