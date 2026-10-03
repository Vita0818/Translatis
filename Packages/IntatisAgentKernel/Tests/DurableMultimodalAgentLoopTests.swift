import Foundation
import XCTest
import IntatisArtifacts
import IntatisConversation
import IntatisCore
import IntatisPermission
import IntatisProtocol
import IntatisProviders
import IntatisTools
@testable import IntatisAgentKernel

private final class DurableMediaCapturingProvider:
    ToolCallingProvider, @unchecked Sendable
{
    let toolCallingCapabilities: ToolCallingProviderCapabilities

    private let lock = NSLock()
    private let responses: [[AgentChunk]]
    private var nextResponse = 0
    private var requestStorage: [AgentRequest] = []

    init(
        responses: [[AgentChunk]],
        capabilities: ToolCallingProviderCapabilities
    ) {
        self.responses = responses
        toolCallingCapabilities = capabilities
    }

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestStorage
    }

    func stream(
        _ request: AgentRequest
    ) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        requestStorage.append(request)
        let response = responses[min(
            nextResponse,
            responses.count - 1)]
        nextResponse += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in response { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private struct DurableMediaTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "durable_media",
        description: "Returns one durable image reference.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ]))

    let artifactID: ArtifactID
    let sha256: String

    func execute(
        _ args: ToolArgs,
        in context: ToolContext
    ) async throws -> ToolObservation {
        _ = try args.decode([String: String].self)
        return ToolObservation(
            text: "legacy UI projection",
            structuredResult: MCPStructuredToolResult(content: [
                MCPContentBlock(kind: .text, text: "visual result"),
                MCPContentBlock(
                    kind: .imageReference,
                    artifactID: artifactID,
                    mimeType: "image/png",
                    byteCount: 8,
                    sha256: sha256),
            ]))
    }
}

private actor AutomaticMediaTestResponder: PermissionResponder {
    nonisolated let approvalMode: PermissionApprovalMode = .automaticReviewer
    private var requestCount = 0
    private var invocationInputs: [PermissionReviewInvocationInput] = []

    func requestApproval(
        _ request: PermissionRequestPayload
    ) async -> PermissionDecision {
        _ = request
        return .deny
    }

    func requestResolution(
        _ request: PermissionRequestPayload,
        invocation: PermissionReviewInvocationInput
    ) async -> PermissionApprovalResolution {
        requestCount += 1
        invocationInputs.append(invocation)
        return PermissionApprovalResolution(
            decision: .allow,
            action: .approve,
            reason: "bounded image-backed request is authorized",
            risk: request.risk,
            source: .automaticReviewer,
            reviewStatus: .allowed)
    }

    func count() -> Int { requestCount }
    func invocations() -> [PermissionReviewInvocationInput] {
        invocationInputs
    }
}

private func automaticMediaWriteArguments(
    path: String,
    content: String,
    evidenceReference: String,
    evidenceSummary: String
) -> String {
    let arguments: [String: Any] = [
        "path": path,
        "content": content,
        AuthorizationSidecarCodec.reservedFieldName:
            "The user requested this exact image-backed file. The acting model inspected image evidence \(evidenceReference): \(evidenceSummary). This bounded write is the next required step.",
    ]
    let data = try! JSONSerialization.data(
        withJSONObject: arguments,
        options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private actor SequencedDurableMediaResolver {
    private let artifactID: ArtifactID
    private let sha256: String
    private let attachments: [ImageAttachment]
    private var calls = 0

    init(
        artifactID: ArtifactID,
        sha256: String,
        attachments: [ImageAttachment]
    ) {
        self.artifactID = artifactID
        self.sha256 = sha256
        self.attachments = attachments
    }

    func resolve(_ ids: [ArtifactID]) throws -> [AgentResolvedImage] {
        guard ids == [artifactID] else {
            throw ArtifactImageResolutionError.missing(
                ids.first ?? artifactID)
        }
        let attachment = attachments[min(calls, attachments.count - 1)]
        calls += 1
        return [AgentResolvedImage(
            artifactID: artifactID,
            mimeType: "image/png",
            byteCount: 8,
            sha256: sha256,
            attachment: attachment)]
    }

    func count() -> Int { calls }
}

private struct DurableUnsupportedMediaTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "durable_unsupported_media",
        description: "Returns unsupported durable audio.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ]))

    let artifactID: ArtifactID
    let sha256: String

    func execute(
        _ args: ToolArgs,
        in context: ToolContext
    ) async throws -> ToolObservation {
        _ = try args.decode([String: String].self)
        return ToolObservation(
            text: "legacy audio projection",
            structuredResult: MCPStructuredToolResult(content: [
                MCPContentBlock(
                    kind: .audioReference,
                    artifactID: artifactID,
                    mimeType: "audio/mpeg",
                    byteCount: 8,
                    sha256: sha256),
            ]))
    }
}

final class DurableMultimodalAgentLoopTests: XCTestCase {
    private let agentID = AgentID(rawValue: "durable-media-agent")
    private let artifactID = ArtifactID(rawValue: "artifact-image-1")
    private let sha256 = String(repeating: "a", count: 64)

    func testCurrentUserImagePersistsAndReplaysFromDescriptor() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let eventURL = workspace.appendingPathComponent("events.jsonl")
        let log = try EventLog(
            session: SessionID(rawValue: "durable-user-image"),
            fileURL: eventURL)
        let capabilities = ToolCallingProviderCapabilities(
            supportsUserImageInput: true,
            supportsFunctionOutputImageInput: true)
        let firstProvider = DurableMediaCapturingProvider(
            responses: [[
                .textDelta("first"),
                .done(finishReason: "stop"),
            ]],
            capabilities: capabilities)
        let firstSubmission = SubmissionID(rawValue: "submission-image-1")
        let committedReadbackImage = ImageAttachment(
            url: "data:image/png;base64,QUJDREVGR0g=")
        let sequencedResolver = SequencedDurableMediaResolver(
            artifactID: artifactID,
            sha256: sha256,
            attachments: [requestImage, committedReadbackImage])
        let firstLoop = makeLoop(
            workspace: workspace,
            log: log,
            provider: firstProvider,
            registry: ToolRegistry([]),
            imageResolver: { ids in
                try await sequencedResolver.resolve(ids)
            })

        _ = try await firstLoop.send(
            "inspect this",
            userMessage: UserMessagePayload(
                text: "inspect this",
                attachments: [artifactID],
                submissionID: firstSubmission))

        let firstRequest = try XCTUnwrap(firstProvider.requests.first)
        XCTAssertEqual(
            firstRequest.messages.last(where: { $0.role == .user })?.images,
            [committedReadbackImage])
        let resolverCallCount = await sequencedResolver.count()
        XCTAssertEqual(resolverCallCount, 2)

        let firstEvents = try await log.replayChecked()
        let durableUser = try XCTUnwrap(firstEvents.compactMap {
            envelope -> ModelHistoryItemPayload? in
            guard case .modelHistoryItem(let payload) = envelope.event,
                  payload.submissionID == firstSubmission,
                  payload.messageClassification == .realUser else {
                return nil
            }
            return payload
        }.first)
        XCTAssertEqual(
            durableUser.schemaVersion,
            ModelHistoryItemPayload.mediaSchemaVersion)
        XCTAssertEqual(durableUser.imageReferences, [imageReference])
        XCTAssertFalse(
            try String(contentsOf: eventURL, encoding: .utf8)
                .contains("data:image"))

        let secondProvider = DurableMediaCapturingProvider(
            responses: [[
                .textDelta("second"),
                .done(finishReason: "stop"),
            ]],
            capabilities: capabilities)
        let secondLoop = makeLoop(
            workspace: workspace,
            log: log,
            provider: secondProvider,
            registry: ToolRegistry([]))
        _ = try await secondLoop.send(
            "continue",
            userMessage: UserMessagePayload(
                text: "continue",
                submissionID:
                    SubmissionID(rawValue: "submission-image-2")))

        let replayRequest = try XCTUnwrap(secondProvider.requests.first)
        XCTAssertTrue(replayRequest.messages.contains { message in
            message.role == .user
                && message.content == "inspect this"
                && message.images == [requestImage]
        })
    }

    func testCompactionPreflightsHistoricalUserImageCapability()
        async throws
    {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let log = try EventLog(
            session: SessionID(rawValue: "media-compaction-preflight"),
            fileURL: workspace.appendingPathComponent("events.jsonl"))
        let capable = DurableMediaCapturingProvider(
            responses: [[
                .textDelta("first"),
                .done(finishReason: "stop"),
            ]],
            capabilities: ToolCallingProviderCapabilities(
                supportsUserImageInput: true))
        _ = try await makeLoop(
            workspace: workspace,
            log: log,
            provider: capable,
            registry: ToolRegistry([]))
            .send(
                "inspect",
                userMessage: UserMessagePayload(
                    text: "inspect",
                    attachments: [artifactID],
                    submissionID:
                        SubmissionID(rawValue: "media-preflight-first")))

        let incapable = DurableMediaCapturingProvider(
            responses: [[.done(finishReason: "stop")]],
            capabilities: .chatCompletionsOnly)
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: incapable,
            registry: ToolRegistry([]),
            modelContextPolicy:
                AgentModelContextPolicy(autoCompactTokenLimit: 1))
        do {
            _ = try await loop.send("continue")
            XCTFail("compaction must reject an unsupported image route")
        } catch let error as AgentLoopError {
            guard case .mediaOutputUnsupported = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(incapable.requests.isEmpty)
    }

    func testTaskScopedDataURLBypassFailsBeforeProviderDispatch()
        async throws
    {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let log = try EventLog(
            session: SessionID(rawValue: "task-scoped-image-bypass"),
            fileURL: workspace.appendingPathComponent("events.jsonl"))
        let provider = DurableMediaCapturingProvider(
            responses: [[.done(finishReason: "stop")]],
            capabilities: ToolCallingProviderCapabilities(
                supportsUserImageInput: true))
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([]),
            context: ContextBuilder(
                systemPrompt: "system",
                runtimeEnvironment: .cowork,
                conversationHistoryPolicy: .taskScoped))

        do {
            _ = try await loop.send(
                "inspect",
                images: [requestImage])
            XCTFail("direct data URLs must fail closed")
        } catch let error as AgentLoopError {
            guard case .mediaOutputInvalid = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(provider.requests.isEmpty)
        let events = try await log.replayChecked()
        XCTAssertTrue(events.isEmpty)
    }

    func testTaskScopedCoworkImageResolvesFromArtifactAttachment()
        async throws
    {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let log = try EventLog(
            session: SessionID(rawValue: "task-scoped-artifact-image"),
            fileURL: workspace.appendingPathComponent("events.jsonl"))
        let provider = DurableMediaCapturingProvider(
            responses: [[
                .textDelta("done"),
                .done(finishReason: "stop"),
            ]],
            capabilities: ToolCallingProviderCapabilities(
                supportsUserImageInput: true))
        let task = TaskContract(
            id: TaskID(rawValue: "task-scoped-artifact-image"),
            kind: .agentInvocation,
            issuer: AgentID(rawValue: "main"),
            assignee: agentID,
            objective: "inspect",
            roleHint: "worker",
            expectedDeliverable: "answer")
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([]),
            context: ContextBuilder(
                systemPrompt: "system",
                taskContract: task,
                contextBundle: ContextBundle(
                    globalBrief: task.objective,
                    safetyPolicy: "test",
                    taskContract: task),
                runtimeEnvironment: .cowork,
                conversationHistoryPolicy: .taskScoped))

        let result = try await loop.send(
            "inspect",
            userMessage: UserMessagePayload(
                text: "inspect",
                attachments: [artifactID],
                to: agentID))

        XCTAssertEqual(result, "done")
        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertTrue(request.messages.contains { message in
            message.role == .user
                && message.content == "inspect"
                && message.images == [requestImage]
        })
        XCTAssertFalse(
            try String(
                contentsOf: workspace.appendingPathComponent("events.jsonl"),
                encoding: .utf8)
                .contains("data:image"))
    }

    func testUnsupportedStructuredMediaUsesFrozenDurableFallback()
        async throws
    {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let log = try EventLog(
            session: SessionID(rawValue: "unsupported-media-fallback"),
            fileURL: workspace.appendingPathComponent("events.jsonl"))
        let provider = DurableMediaCapturingProvider(
            responses: [[
                .toolCalls([ToolCall(
                    id: "call-audio",
                    name: "durable_unsupported_media",
                    arguments: "{}")]),
                .done(finishReason: "tool_calls"),
            ]],
            capabilities: ToolCallingProviderCapabilities(
                supportsUserImageInput: true,
                supportsFunctionOutputImageInput: true))
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([DurableUnsupportedMediaTool(
                artifactID: artifactID,
                sha256: sha256)]))

        do {
            _ = try await loop.send("use audio")
            XCTFail("unsupported structured media must fail closed")
        } catch let error as AgentLoopError {
            guard case .mediaOutputUnsupported = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let events = try await log.replayChecked()
        XCTAssertTrue(events.contains { envelope in
            guard case .modelHistoryItem(let payload) = envelope.event else {
                return false
            }
            return payload.callID == "call-audio"
                && payload.output
                    == "[media delivery unavailable: media_output_unsupported]"
                && payload.imageReferences == nil
        })
    }

    func testStructuredToolImageUsesSameCallFCOAndReplays() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let log = try EventLog(
            session: SessionID(rawValue: "durable-tool-image"),
            fileURL: workspace.appendingPathComponent("events.jsonl"))
        let capabilities = ToolCallingProviderCapabilities(
            supportsUserImageInput: true,
            supportsFunctionOutputImageInput: true)
        let provider = DurableMediaCapturingProvider(
            responses: [
                [
                    .toolCalls([ToolCall(
                        id: "call-media",
                        name: "durable_media",
                        arguments: "{}")]),
                    .done(finishReason: "tool_calls"),
                ],
                [
                    .textDelta("done"),
                    .done(finishReason: "stop"),
                ],
            ],
            capabilities: capabilities)
        let registry = ToolRegistry([DurableMediaTool(
            artifactID: artifactID,
            sha256: sha256)])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: registry)

        let answer = try await loop.send(
            "use media",
            userMessage: UserMessagePayload(
                text: "use media",
                submissionID:
                    SubmissionID(rawValue: "submission-tool-1")))
        XCTAssertEqual(answer, "done")

        XCTAssertEqual(provider.requests.count, 2)
        let delivered = try XCTUnwrap(
            provider.requests[1].messages.first(where: {
                $0.role == .tool && $0.toolCallId == "call-media"
            }))
        XCTAssertEqual(delivered.content, "visual result")
        XCTAssertEqual(delivered.images, [requestImage])
        XCTAssertTrue(provider.requests[1].requiresResponsesAPI)

        let events = try await log.replayChecked()
        let durableOutput = try XCTUnwrap(events.compactMap {
            envelope -> ModelHistoryItemPayload? in
            guard case .modelHistoryItem(let payload) = envelope.event,
                  payload.kind == .functionCallOutput,
                  payload.callID == "call-media" else {
                return nil
            }
            return payload
        }.first)
        XCTAssertEqual(durableOutput.output, "visual result")
        XCTAssertEqual(durableOutput.imageReferences, [imageReference])

        let replayProvider = DurableMediaCapturingProvider(
            responses: [[
                .textDelta("replayed"),
                .done(finishReason: "stop"),
            ]],
            capabilities: capabilities)
        let replayLoop = makeLoop(
            workspace: workspace,
            log: log,
            provider: replayProvider,
            registry: registry)
        _ = try await replayLoop.send(
            "next",
            userMessage: UserMessagePayload(
                text: "next",
                submissionID:
                    SubmissionID(rawValue: "submission-tool-2")))
        XCTAssertTrue(try XCTUnwrap(replayProvider.requests.first)
            .messages.contains { message in
                message.role == .tool
                    && message.toolCallId == "call-media"
                    && message.content == "visual result"
                    && message.images == [requestImage]
            })
    }

    func testUnsupportedFCOImageFailsAfterTruthfulSettlement() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let log = try EventLog(
            session: SessionID(rawValue: "unsupported-tool-image"),
            fileURL: workspace.appendingPathComponent("events.jsonl"))
        let provider = DurableMediaCapturingProvider(
            responses: [[
                .toolCalls([ToolCall(
                    id: "call-unsupported-media",
                    name: "durable_media",
                    arguments: "{}")]),
                .done(finishReason: "tool_calls"),
            ]],
            capabilities: ToolCallingProviderCapabilities(
                supportsUserImageInput: true,
                supportsFunctionOutputImageInput: false))
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([DurableMediaTool(
                artifactID: artifactID,
                sha256: sha256)]))

        do {
            _ = try await loop.send(
                "use media",
                userMessage: UserMessagePayload(
                    text: "use media",
                    submissionID:
                        SubmissionID(rawValue: "submission-unsupported")))
            XCTFail("unsupported FCO image route must fail closed")
        } catch let error as AgentLoopError {
            guard case .mediaOutputUnsupported = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(provider.requests.count, 1)

        let events = try await log.replayChecked()
        XCTAssertTrue(events.contains { envelope in
            guard case .toolExecutionSettled(let payload) = envelope.event
            else { return false }
            return payload.toolCallID == "call-unsupported-media"
                && payload.outcome == .succeeded
                && payload.effectDisposition == .committed
        })
        XCTAssertTrue(events.contains { envelope in
            guard case .modelHistoryItem(let payload) = envelope.event
            else { return false }
            return payload.callID == "call-unsupported-media"
                && payload.imageReferences == [imageReference]
        })
        XCTAssertTrue(events.contains { envelope in
            guard case .error(let payload) = envelope.event else {
                return false
            }
            return payload.code == "media_output_unsupported"
        })
    }

    func testAutomaticReviewerUsesImageSidecarWithoutBlanketMediaDeny()
        async throws
    {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let log = try EventLog(
            session: SessionID(rawValue: "automatic-review-media"),
            fileURL: workspace.appendingPathComponent("events.jsonl"))
        let rawSidecarSentinel =
            "IMAGE_SIDECAR_RAW_SENTINEL_CURRENT_USER"
        let provider = DurableMediaCapturingProvider(
            responses: [
                [
                    .toolCalls([ToolCall(
                        id: "call-media-write",
                        name: "write_file",
                        arguments: automaticMediaWriteArguments(
                            path: "image-backed.txt",
                            content: "approved from image summary",
                            evidenceReference: "current-user-image",
                            evidenceSummary: rawSidecarSentinel))]),
                    .done(finishReason: "tool_calls"),
                ],
                [
                    .textDelta("The image-backed write completed."),
                    .done(finishReason: "stop"),
                ],
            ],
            capabilities: ToolCallingProviderCapabilities(
                supportsUserImageInput: true,
                supportsFunctionOutputImageInput: true))
        let submissionID = SubmissionID(
            rawValue: "submission-automatic-media")
        let task = TaskContract(
            id: TaskID(rawValue: "task-automatic-media"),
            kind: .root,
            issuer: nil,
            assignee: agentID,
            submissionID: submissionID,
            objective: "Inspect the image and create image-backed.txt.",
            roleHint: "root",
            expectedDeliverable: "answer")
        let responder = AutomaticMediaTestResponder()
        let resolved = AgentResolvedImage(
            artifactID: artifactID,
            mimeType: "image/png",
            byteCount: 8,
            sha256: sha256,
            attachment: requestImage)
        let loop = AgentLoop(
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            engine: PermissionEngine(),
            responder: responder,
            agent: Agent(
                name: agentID,
                workspaceRoot: workspace,
                model: ModelID(rawValue: "durable-media-model"),
                profile: .reviewed),
            context: ContextBuilder(
                systemPrompt: "system",
                taskContract: task,
                contextBundle: ContextBundle(
                    globalBrief: task.objective,
                    safetyPolicy: "test",
                    taskContract: task),
                runtimeEnvironment: .cowork,
                conversationHistoryPolicy: .coworkMainThread),
            allowsShell: false,
            imageResolver: { ids in
                try ids.map { id in
                    guard id == resolved.artifactID else {
                        throw ArtifactImageResolutionError.missing(id)
                    }
                    return resolved
                }
            },
            taskAttempt: 1)

        let final = try await loop.send(
            "inspect the image and create image-backed.txt",
            userMessage: UserMessagePayload(
                text: "inspect the image and create image-backed.txt",
                attachments: [artifactID],
                to: agentID,
                submissionID: submissionID))
        XCTAssertEqual(final, "The image-backed write completed.")
        let responderCallCount = await responder.count()
        XCTAssertEqual(responderCallCount, 1)
        XCTAssertEqual(
            try String(
                contentsOf: workspace.appendingPathComponent(
                    "image-backed.txt"),
                encoding: .utf8),
            "approved from image summary")
        let invocations = await responder.invocations()
        let invocation = try XCTUnwrap(invocations.first)
        XCTAssertEqual(
            invocation.sessionID,
            SessionID(rawValue: "automatic-review-media"))
        XCTAssertEqual(invocation.taskID, task.id)
        XCTAssertEqual(invocation.toolCallID, "call-media-write")
        XCTAssertEqual(invocation.toolName, "write_file")
        XCTAssertEqual(
            invocation.canonicalBusinessArguments,
            #"{"content":"approved from image summary","path":"image-backed.txt"}"#)
        XCTAssertFalse(invocation.canonicalBusinessArguments.contains(
            AuthorizationSidecarCodec.reservedFieldName))
        XCTAssertTrue(invocation.modelAuthorizationContextJSON.contains(
            "current-user-image"))
        XCTAssertTrue(invocation.modelAuthorizationContextJSON.contains(
            rawSidecarSentinel))
        XCTAssertFalse(invocation.modelAuthorizationContextJSON.contains(
            "data:image"),
            "the reviewer receives a model summary, not raw image bytes")

        let events = try await log.replayChecked()
        let request = try XCTUnwrap(events.compactMap {
            envelope -> PermissionRequestPayload? in
            guard case .permissionRequest(let payload) = envelope.event,
                  payload.context?.toolCallID == "call-media-write" else {
                return nil
            }
            return payload
        }.first)
        let evidenceMetadata = try XCTUnwrap(
            request.context?.reviewInvocationEvidence)
        XCTAssertEqual(evidenceMetadata.status, .valid)
        XCTAssertEqual(evidenceMetadata.sourceGenerationID,
                       invocation.sourceGenerationID)
        XCTAssertEqual(evidenceMetadata.toolSnapshotID,
                       invocation.toolSnapshotID)
        XCTAssertEqual(
            evidenceMetadata.modelAuthorizationContextDigest,
            invocation.modelAuthorizationContextDigest)
        let resolution = try XCTUnwrap(events.compactMap {
            envelope -> PermissionResolvedPayload? in
            guard case .permissionResolved(let payload) = envelope.event,
                  payload.toolCallID == "call-media-write",
                  payload.requestId != nil else {
                return nil
            }
            return payload
        }.first)
        XCTAssertEqual(resolution.source, .automaticReviewer)
        XCTAssertEqual(resolution.decision, .allow)
        XCTAssertNil(resolution.failureKind)
        XCTAssertTrue(events.contains { envelope in
            guard case .toolExecutionSettled(let payload) = envelope.event else {
                return false
            }
            return payload.toolCallID == "call-media-write"
                && payload.outcome == .succeeded
        })
        let durableBytes = try events.map {
            String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
        }.joined(separator: "\n")
        XCTAssertFalse(durableBytes.contains(
            AuthorizationSidecarCodec.reservedFieldName))
        XCTAssertFalse(durableBytes.contains(rawSidecarSentinel))
    }

    func testHistoricalFCOImageUsesSidecarAndReachesAutomaticReviewer()
        async throws
    {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let log = try EventLog(
            session: SessionID(rawValue: "automatic-review-fco-media"),
            fileURL: workspace.appendingPathComponent("events.jsonl"))
        let resolvedImage = AgentResolvedImage(
            artifactID: artifactID,
            mimeType: "image/png",
            byteCount: 8,
            sha256: sha256,
            attachment: requestImage)

        let firstSubmission = SubmissionID(
            rawValue: "submission-fco-media-first")
        let firstTask = TaskContract(
            id: TaskID(rawValue: "task-fco-media-first"),
            kind: .root,
            issuer: nil,
            assignee: agentID,
            submissionID: firstSubmission,
            objective: "Produce a visual result.",
            roleHint: "root",
            expectedDeliverable: "answer")
        try await log.append(.taskCreated(TaskCreatedPayload(
            contract: firstTask)))
        let firstProvider = DurableMediaCapturingProvider(
            responses: [
                [
                    .toolCalls([ToolCall(
                        id: "call-historical-media",
                        name: "durable_media",
                        arguments: "{}")]),
                    .done(finishReason: "tool_calls"),
                ],
                [
                    .textDelta("Visual result recorded."),
                    .done(finishReason: "stop"),
                ],
            ],
            capabilities: ToolCallingProviderCapabilities(
                supportsUserImageInput: true,
                supportsFunctionOutputImageInput: true))
        let firstLoop = AgentLoop(
            log: log,
            provider: firstProvider,
            registry: ToolRegistry([DurableMediaTool(
                artifactID: artifactID,
                sha256: sha256)]),
            engine: PermissionEngine(),
            responder: FixedResponder(.allow),
            agent: Agent(
                name: agentID,
                workspaceRoot: workspace,
                model: ModelID(rawValue: "durable-media-model"),
                profile: .reviewed),
            context: ContextBuilder(
                systemPrompt: "system",
                taskContract: firstTask,
                contextBundle: ContextBundle(
                    globalBrief: firstTask.objective,
                    safetyPolicy: "test",
                    taskContract: firstTask),
                runtimeEnvironment: .cowork,
                conversationHistoryPolicy: .coworkMainThread),
            allowsShell: false,
            imageResolver: { ids in
                try ids.map { id in
                    guard id == resolvedImage.artifactID else {
                        throw ArtifactImageResolutionError.missing(id)
                    }
                    return resolvedImage
                }
            },
            taskAttempt: 1)
        _ = try await firstLoop.send(
            "produce a visual result",
            userMessage: UserMessagePayload(
                text: "produce a visual result",
                to: agentID,
                submissionID: firstSubmission))

        let secondSubmission = SubmissionID(
            rawValue: "submission-fco-media-second")
        let rawSidecarSentinel =
            "IMAGE_SIDECAR_RAW_SENTINEL_HISTORICAL_FCO"
        let secondTask = TaskContract(
            id: TaskID(rawValue: "task-fco-media-second"),
            kind: .root,
            issuer: nil,
            assignee: agentID,
            submissionID: secondSubmission,
            objective: "Use the prior visual result and create after-fco.txt.",
            roleHint: "root",
            expectedDeliverable: "answer")
        try await log.append(.taskCreated(TaskCreatedPayload(
            contract: secondTask)))
        let secondProvider = DurableMediaCapturingProvider(
            responses: [
                [
                    .toolCalls([ToolCall(
                        id: "call-write-after-fco",
                        name: "write_file",
                        arguments: automaticMediaWriteArguments(
                            path: "after-fco.txt",
                            content: "approved from prior visual result",
                            evidenceReference:
                                "tool-result:call-historical-media",
                            evidenceSummary: rawSidecarSentinel))]),
                    .done(finishReason: "tool_calls"),
                ],
                [
                    .textDelta("The prior visual result was used for the approved write."),
                    .done(finishReason: "stop"),
                ],
            ],
            capabilities: ToolCallingProviderCapabilities(
                supportsUserImageInput: true,
                supportsFunctionOutputImageInput: true))
        let responder = AutomaticMediaTestResponder()
        let secondLoop = AgentLoop(
            log: log,
            provider: secondProvider,
            registry: ToolRegistry([WriteFileTool()]),
            engine: PermissionEngine(),
            responder: responder,
            agent: Agent(
                name: agentID,
                workspaceRoot: workspace,
                model: ModelID(rawValue: "durable-media-model"),
                profile: .reviewed),
            context: ContextBuilder(
                systemPrompt: "system",
                taskContract: secondTask,
                contextBundle: ContextBundle(
                    globalBrief: secondTask.objective,
                    safetyPolicy: "test",
                    taskContract: secondTask),
                runtimeEnvironment: .cowork,
                conversationHistoryPolicy: .coworkMainThread),
            allowsShell: false,
            imageResolver: { ids in
                try ids.map { id in
                    guard id == resolvedImage.artifactID else {
                        throw ArtifactImageResolutionError.missing(id)
                    }
                    return resolvedImage
                }
            },
            taskAttempt: 1)

        let final = try await secondLoop.send(
            "use the prior visual result and create after-fco.txt",
            userMessage: UserMessagePayload(
                text: "use the prior visual result and create after-fco.txt",
                to: agentID,
                submissionID: secondSubmission))
        XCTAssertEqual(
            final,
            "The prior visual result was used for the approved write.")

        let askRequest = try XCTUnwrap(secondProvider.requests.first)
        XCTAssertTrue(askRequest.messages.contains { message in
            message.role == .tool
                && message.toolCallId == "call-historical-media"
                && message.images == [requestImage]
        })
        XCTAssertFalse(askRequest.messages.contains { message in
            message.role == .user && !message.images.isEmpty
        })
        XCTAssertEqual(secondProvider.requests.count, 2)
        XCTAssertTrue(secondProvider.requests.allSatisfy { !$0.tools.isEmpty })
        let responderCallCount = await responder.count()
        XCTAssertEqual(responderCallCount, 1)
        XCTAssertEqual(
            try String(
                contentsOf: workspace.appendingPathComponent(
                    "after-fco.txt"),
                encoding: .utf8),
            "approved from prior visual result")
        let invocations = await responder.invocations()
        let invocation = try XCTUnwrap(invocations.first)
        XCTAssertEqual(
            invocation.sessionID,
            SessionID(rawValue: "automatic-review-fco-media"))
        XCTAssertEqual(invocation.taskID, secondTask.id)
        XCTAssertEqual(invocation.toolCallID, "call-write-after-fco")
        XCTAssertEqual(invocation.toolName, "write_file")
        XCTAssertEqual(
            invocation.canonicalBusinessArguments,
            #"{"content":"approved from prior visual result","path":"after-fco.txt"}"#)
        XCTAssertTrue(invocation.modelAuthorizationContextJSON.contains(
            "tool-result:call-historical-media"))
        XCTAssertTrue(invocation.modelAuthorizationContextJSON.contains(
            rawSidecarSentinel))
        XCTAssertFalse(invocation.modelAuthorizationContextJSON.contains(
            "data:image"))

        let events = try await log.replayChecked()
        let request = try XCTUnwrap(events.compactMap {
            envelope -> PermissionRequestPayload? in
            guard case .permissionRequest(let payload) = envelope.event,
                  payload.context?.toolCallID == "call-write-after-fco" else {
                return nil
            }
            return payload
        }.first)
        let evidenceMetadata = try XCTUnwrap(
            request.context?.reviewInvocationEvidence)
        XCTAssertEqual(evidenceMetadata.status, .valid)
        XCTAssertEqual(evidenceMetadata.sourceGenerationID,
                       invocation.sourceGenerationID)
        XCTAssertEqual(evidenceMetadata.toolSnapshotID,
                       invocation.toolSnapshotID)
        XCTAssertEqual(
            evidenceMetadata.modelAuthorizationContextDigest,
            invocation.modelAuthorizationContextDigest)
        let resolution = try XCTUnwrap(events.compactMap {
            envelope -> PermissionResolvedPayload? in
            guard case .permissionResolved(let payload) = envelope.event,
                  payload.toolCallID == "call-write-after-fco" else {
                return nil
            }
            return payload
        }.first)
        XCTAssertEqual(resolution.requestId, request.requestId)
        XCTAssertEqual(resolution.decision, .allow)
        XCTAssertEqual(resolution.source, .automaticReviewer)
        XCTAssertEqual(resolution.reviewStatus, .allowed)
        XCTAssertNil(resolution.failureKind)
        XCTAssertTrue(events.contains { envelope in
            guard case .toolExecutionPrepared(let payload) = envelope.event
            else { return false }
            return payload.toolCallID == "call-write-after-fco"
        })
        XCTAssertTrue(events.contains { envelope in
            guard case .toolExecutionSettled(let payload) = envelope.event
            else { return false }
            return payload.toolCallID == "call-write-after-fco"
                && payload.outcome == .succeeded
        })
        let durableBytes = try events.map {
            String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
        }.joined(separator: "\n")
        XCTAssertFalse(durableBytes.contains(
            AuthorizationSidecarCodec.reservedFieldName))
        XCTAssertFalse(durableBytes.contains(rawSidecarSentinel))
    }

    private var imageReference: ModelHistoryImageReference {
        ModelHistoryImageReference(
            artifactID: artifactID,
            mimeType: "image/png",
            byteCount: 8,
            sha256: sha256)
    }

    private var requestImage: ImageAttachment {
        ImageAttachment(url: "data:image/png;base64,iVBORw0KGgo=")
    }

    private func makeLoop(
        workspace: URL,
        log: EventLog,
        provider: any ToolCallingProvider,
        registry: ToolRegistry,
        imageResolver: AgentImageResolver? = nil,
        context: ContextBuilder? = nil,
        modelContextPolicy: AgentModelContextPolicy = .unspecified
    ) -> AgentLoop {
        let resolved = AgentResolvedImage(
            artifactID: artifactID,
            mimeType: "image/png",
            byteCount: 8,
            sha256: sha256,
            attachment: requestImage)
        let defaultResolver: AgentImageResolver = { ids in
            try ids.map { id in
                guard id == resolved.artifactID else {
                    throw ArtifactImageResolutionError.missing(id)
                }
                return resolved
            }
        }
        return AgentLoop(
            log: log,
            provider: provider,
            registry: registry,
            engine: PermissionEngine(),
            responder: FixedResponder(.allow),
            agent: Agent(
                name: agentID,
                workspaceRoot: workspace,
                model: ModelID(rawValue: "durable-media-model"),
                profile: .reviewed),
            context: context ?? ContextBuilder(
                systemPrompt: "system",
                runtimeEnvironment: .code,
                conversationHistoryPolicy: .conversation),
            allowsShell: false,
            imageResolver: imageResolver ?? defaultResolver,
            modelContextPolicy: modelContextPolicy)
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-durable-media-loop-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true)
        return url
    }
}
