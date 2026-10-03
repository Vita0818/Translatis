import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
@testable import IntatisAgentKernel

private final class CompactionScriptedProvider:
    ToolCallingProvider, @unchecked Sendable
{
    let toolCallingCapabilities: ToolCallingProviderCapabilities

    private let lock = NSLock()
    private let responses: [[AgentChunk]]
    private var responseIndex = 0
    private var capturedRequests: [AgentRequest] = []

    init(
        _ responses: [[AgentChunk]],
        capabilities: ToolCallingProviderCapabilities =
            .chatCompletionsOnly
    ) {
        precondition(!responses.isEmpty)
        self.responses = responses
        toolCallingCapabilities = capabilities
    }

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    func stream(
        _ request: AgentRequest
    ) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        capturedRequests.append(request)
        let index = min(responseIndex, responses.count - 1)
        let response = responses[index]
        responseIndex += 1
        lock.unlock()

        return AsyncThrowingStream { continuation in
            for chunk in response {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

private actor CompactionToolSnapshotProbe {
    private let snapshot: AgentRequestToolSnapshot
    private var resolutions = 0

    init(snapshot: AgentRequestToolSnapshot) {
        self.snapshot = snapshot
    }

    func resolve() -> AgentRequestToolSnapshot {
        resolutions += 1
        return snapshot
    }

    func resolutionCount() -> Int {
        resolutions
    }
}

private actor CompactionToolSnapshotSequenceProbe {
    private let snapshots: [AgentRequestToolSnapshot]
    private let failingResolution: Int?
    private var resolutions = 0

    init(
        snapshots: [AgentRequestToolSnapshot],
        failingResolution: Int? = nil
    ) {
        precondition(!snapshots.isEmpty)
        self.snapshots = snapshots
        self.failingResolution = failingResolution
    }

    func resolve() throws -> AgentRequestToolSnapshot {
        resolutions += 1
        if resolutions == failingResolution {
            throw CompactionSnapshotFailure.unavailable
        }
        return snapshots[min(resolutions - 1, snapshots.count - 1)]
    }

    func resolutionCount() -> Int {
        resolutions
    }
}

private enum CompactionSnapshotFailure: Error {
    case unavailable
}

private struct CompactionProbeArguments: Decodable {
    var path: String
}

private struct CompactionLargeProbeTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "read_large_probe",
        description: "Returns a deliberately large stable observation.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "minLength": .number(1),
                ]),
            ]),
            "required": .array([.string("path")]),
            "additionalProperties": .bool(false),
        ]))

    func execute(
        _ args: ToolArgs,
        in context: ToolContext
    ) async throws -> ToolObservation {
        let decoded = try args.decode(CompactionProbeArguments.self)
        return ToolObservation(
            text:
                "probe:\(decoded.path):"
                + String(repeating: "large-observation-", count: 1_200))
    }
}

private struct CompactionDeferredToolSearchTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "tool_search",
        description: "Return deferred functions for compaction testing.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false),
        ]),
        modelSpecKind: .toolSearch)

    let output: ModelToolSearchOutput

    func execute(
        _ args: ToolArgs,
        in context: ToolContext
    ) async throws -> ToolObservation {
        ToolObservation(
            text: "deferred functions loaded",
            toolSearchOutput: output)
    }
}

private struct CompactionAutomaticResponder: PermissionResponder {
    let approvalMode: PermissionApprovalMode = .automaticReviewer

    func requestApproval(
        _ request: PermissionRequestPayload
    ) async -> PermissionDecision {
        .allow
    }
}

final class ModelHistoryCompactionAgentLoopTests: XCTestCase {
    private let main = AgentID(rawValue: "main")

    func testPreTurnCompactionExcludesIncomingAndCommitsBeforeCurrentUserHistory()
        async throws
    {
        let fixture = try makeFixture("preturn")
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let previousID = SubmissionID(rawValue: "sub_compact_previous")
        let currentID = SubmissionID(rawValue: "sub_compact_current")
        let previousTask = rootTask(
            "task_compact_previous",
            previousID,
            "OLDER USER")
        let currentTask = rootTask(
            "task_compact_current",
            currentID,
            "INCOMING USER")
        try await appendCompletedDirectTurn(
            log: fixture.log,
            task: previousTask,
            userText: "OLDER USER",
            assistantText: "OLDER ASSISTANT")
        try await fixture.log.append([
            .userMessage(UserMessagePayload(
                text: "INCOMING USER",
                to: main,
                submissionID: currentID)),
            .taskCreated(TaskCreatedPayload(contract: currentTask)),
        ])

        let provider = CompactionScriptedProvider([
            [
                .textDelta("PRE-TURN SUMMARY"),
                .done(finishReason: "stop"),
            ],
            [
                .textDelta("CURRENT ANSWER"),
                .done(finishReason: "stop"),
            ],
        ])
        let loop = makeRootLoop(
            fixture: fixture,
            provider: provider,
            task: currentTask,
            modelContextPolicy:
                AgentModelContextPolicy(autoCompactTokenLimit: 1))

        let result = try await loop.send(
            "INCOMING USER",
            recordUserMessage: false,
            submissionID: currentID)

        XCTAssertEqual(result, "CURRENT ANSWER")
        XCTAssertEqual(provider.requests.count, 2)
        let compactRequest = provider.requests[0]
        XCTAssertTrue(compactRequest.tools.isEmpty)
        XCTAssertTrue(compactRequest.messages.contains {
            $0.content == "OLDER USER"
        })
        XCTAssertTrue(compactRequest.messages.contains {
            $0.content == "OLDER ASSISTANT"
        })
        XCTAssertFalse(compactRequest.messages.contains {
            $0.content?.contains("INCOMING USER") == true
        })

        let normalRequest = provider.requests[1]
        XCTAssertTrue(normalRequest.messages.contains {
            $0.content == "OLDER USER"
        })
        XCTAssertTrue(normalRequest.messages.contains {
            $0.content?.contains("PRE-TURN SUMMARY") == true
        })
        XCTAssertFalse(normalRequest.messages.contains {
            $0.content == "OLDER ASSISTANT"
        })
        XCTAssertEqual(
            normalRequest.messages.last,
            .user("INCOMING USER"))

        let replay = try await fixture.log.replayChecked()
        let checkpointEnvelope = try XCTUnwrap(replay.first {
            if case .modelHistoryCompacted = $0.event { return true }
            return false
        })
        let currentUserEnvelope = try XCTUnwrap(replay.first {
            guard case .modelHistoryItem(let payload) = $0.event else {
                return false
            }
            return payload.submissionID == currentID
                && payload.messageClassification == .realUser
        })
        XCTAssertLessThan(checkpointEnvelope.seq, currentUserEnvelope.seq)

        guard case .modelHistoryCompacted(let checkpoint) =
            checkpointEnvelope.event else {
            return XCTFail("expected model-history checkpoint")
        }
        XCTAssertEqual(
            checkpoint.replacementHistory.map(\.messageClassification),
            [.realUser, .compactionSummary])
        XCTAssertEqual(
            checkpoint.replacementHistory.first?.content,
            "OLDER USER")
        XCTAssertEqual(
            checkpoint.replacementHistory.last?.content,
            checkpoint.message)
    }

    func testMidTurnCompactionUsesDecoratedDeferredProviderCopyAndPersistsRawOutput()
        async throws
    {
        let fixture = try makeFixture("deferred_sidecar")
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let submissionID = SubmissionID(
            rawValue: "sub_compact_deferred_sidecar")
        let task = rootTask(
            "task_compact_deferred_sidecar",
            submissionID,
            "Find a deferred remote tool.")
        try await fixture.log.append([
            .userMessage(UserMessagePayload(
                text: task.objective,
                to: main,
                submissionID: submissionID)),
            .taskCreated(TaskCreatedPayload(contract: task)),
        ])

        let businessSchema = JSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string")]),
                "limit": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false),
        ])
        let deferredFunctions: [JSONValue] = (0..<12).map { index in
            .object([
                "type": .string("function"),
                "name": .string("remote_search_\(index)"),
                "description": .string("Search remote source \(index)."),
                "strict": .bool(false),
                "defer_loading": .bool(true),
                "parameters": businessSchema,
            ])
        }
        let rawOutput = ModelToolSearchOutput(
            tools: deferredFunctions)
        let registry = ToolRegistry([
            CompactionDeferredToolSearchTool(output: rawOutput),
        ])
        let searchCall = ToolCall(
            id: "deferred-search-call",
            name: "tool_search",
            arguments: #"{"query":"remote"}"#,
            kind: .toolSearch,
            status: "completed",
            execution: "client")
        let builder = rootContext(task)
        let nextSpecs = builder.toolSpecs(registry)
        var rawNextMessages = builder.initialMessages(
            history: [],
            userText: task.objective)
        rawNextMessages.append(.assistant(toolCalls: [searchCall]))
        rawNextMessages.append(.toolSearchOutput(
            id: searchCall.id,
            output: rawOutput))
        let decoratedNextMessages = try AuthorizationSidecarCodec
            .decorateProviderMessages(rawNextMessages)
        let rawTokens = AgentTokenEstimator.approximateInputTokens(
            messages: rawNextMessages,
            tools: nextSpecs)
        let decoratedTokens = AgentTokenEstimator.approximateInputTokens(
            messages: decoratedNextMessages,
            tools: nextSpecs)
        XCTAssertGreaterThan(decoratedTokens, rawTokens)

        let provider = CompactionScriptedProvider(
            [
                [
                    .toolCalls([searchCall]),
                    .done(finishReason: "tool_calls"),
                ],
                [
                    .textDelta("DEFERRED SUMMARY"),
                    .done(finishReason: "stop"),
                ],
                [
                    .textDelta("DEFERRED FINAL"),
                    .done(finishReason: "stop"),
                ],
            ],
            capabilities: .responsesToolSearch)
        let loop = makeRootLoop(
            fixture: fixture,
            provider: provider,
            task: task,
            registry: registry,
            responder: CompactionAutomaticResponder(),
            modelContextPolicy: AgentModelContextPolicy(
                autoCompactTokenLimit: rawTokens + 1),
            maxIterations: 2)

        let answer = try await loop.send(
            task.objective,
            recordUserMessage: false,
            submissionID: submissionID)

        XCTAssertEqual(answer, "DEFERRED FINAL")
        XCTAssertEqual(provider.requests.count, 3)
        let compactRequest = provider.requests[1]
        XCTAssertTrue(compactRequest.tools.isEmpty)
        let providerOutput = try XCTUnwrap(
            compactRequest.messages.compactMap(\.toolSearchOutput).first)
        XCTAssertEqual(providerOutput.tools.count, deferredFunctions.count)
        for deferred in providerOutput.tools {
            guard case .object(let function) = deferred,
                  case .object(let parameters)? = function["parameters"],
                  case .object(let properties)? = parameters["properties"],
                  case .array(let required)? = parameters["required"] else {
                return XCTFail("expected decorated deferred compaction input")
            }
            XCTAssertNotNil(
                properties[AuthorizationSidecarCodec.reservedFieldName])
            XCTAssertEqual(required, [
                .string("query"),
                .string(AuthorizationSidecarCodec.reservedFieldName),
            ])
        }

        let replay = try await fixture.log.replayChecked()
        let durableOutput = try XCTUnwrap(replay.compactMap {
            envelope -> ModelToolSearchOutput? in
            guard case .modelHistoryItem(let payload) = envelope.event else {
                return nil
            }
            return payload.toolSearchOutput
        }.first)
        XCTAssertEqual(durableOutput, rawOutput)
        XCTAssertTrue(replay.contains {
            if case .modelHistoryCompacted = $0.event { return true }
            return false
        })
    }

    func testPreTurnCheckpointFitsNinetyFivePercentUsableWindow()
        async throws
    {
        let fixture = try makeFixture("hard_window")
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let previousID = SubmissionID(rawValue: "sub_hard_previous")
        let currentID = SubmissionID(rawValue: "sub_hard_current")
        let previousTask = rootTask(
            "task_hard_previous",
            previousID,
            String(repeating: "prior-objective-", count: 3_000))
        let currentTask = rootTask(
            "task_hard_current",
            currentID,
            "CURRENT")
        try await appendCompletedDirectTurn(
            log: fixture.log,
            task: previousTask,
            userText: previousTask.objective,
            assistantText:
                String(repeating: "prior-answer-", count: 2_000))
        try await fixture.log.append([
            .userMessage(UserMessagePayload(
                text: "CURRENT",
                to: main,
                submissionID: currentID)),
            .taskCreated(TaskCreatedPayload(contract: currentTask)),
        ])
        let provider = CompactionScriptedProvider([
            [
                .textDelta(String(repeating: "bounded-summary-", count: 30)),
                .done(finishReason: "stop"),
            ],
            [
                .textDelta("CURRENT ANSWER"),
                .done(finishReason: "stop"),
            ],
        ])
        let policy = AgentModelContextPolicy(
            contextWindowTokens: 4_000,
            autoCompactTokenLimit: 1)
        let loop = makeRootLoop(
            fixture: fixture,
            provider: provider,
            task: currentTask,
            modelContextPolicy: policy)

        let answer = try await loop.send(
            "CURRENT",
            recordUserMessage: false,
            submissionID: currentID)
        XCTAssertEqual(answer, "CURRENT ANSWER")

        let replay = try await fixture.log.replayChecked()
        let checkpoint = try XCTUnwrap(replay.compactMap {
            envelope -> ModelHistoryCompactedPayload? in
            guard case .modelHistoryCompacted(let payload) =
                    envelope.event else {
                return nil
            }
            return payload
        }.first)
        let replacementMessages = checkpoint.replacementHistory.compactMap {
            item -> AgentMessage? in
            guard let content = item.content else { return nil }
            return .user(content)
        }
        let builder = ContextBuilder(
            systemPrompt: "system",
            taskContract: currentTask,
            contextBundle: ContextBundle(
                globalBrief: currentTask.objective,
                safetyPolicy: "test",
                taskContract: currentTask),
            runtimeEnvironment: .cowork,
            conversationHistoryPolicy: .coworkMainThread)
        let replacementRequest = builder.initialMessages(
            history: replacementMessages,
            userText: "",
            includeCurrentUser: false,
            includeCurrentTurnContext: false)
        XCTAssertLessThanOrEqual(
            AgentTokenEstimator.approximateInputTokens(
                messages: replacementRequest,
                tools: []),
            try XCTUnwrap(policy.hardUsableContextWindowTokens))
        XCTAssertNotNil(provider.requests.first?.maxOutputTokens)
    }

    func testPreTurnUsesAndReusesExactDynamicToolSnapshotForTriggerAndBudget()
        async throws
    {
        let fixture = try makeFixture("dynamic_snapshot")
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let previousID =
            SubmissionID(rawValue: "sub_dynamic_previous")
        let currentID =
            SubmissionID(rawValue: "sub_dynamic_current")
        let previousTask = rootTask(
            "task_dynamic_previous",
            previousID,
            "OLDER USER")
        let currentTask = rootTask(
            "task_dynamic_current",
            currentID,
            "CURRENT")
        try await appendCompletedDirectTurn(
            log: fixture.log,
            task: previousTask,
            userText: "OLDER USER",
            assistantText: "OLDER ASSISTANT")
        try await fixture.log.append([
            .userMessage(UserMessagePayload(
                text: "CURRENT",
                to: main,
                submissionID: currentID)),
            .taskCreated(TaskCreatedPayload(contract: currentTask)),
        ])

        let dynamicSpec = ToolSpec(
            name: "mcp__dynamic__large_schema",
            description:
                String(
                    repeating: "dynamic-provider-schema-",
                    count: 1_500),
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ]))
        let builder = rootContext(currentTask)
        let preTurnContext = builder.initialMessages(
            history: [
                .user("OLDER USER"),
                .assistant("OLDER ASSISTANT"),
            ],
            userText: "CURRENT",
            includeCurrentUser: false,
            includeCurrentTurnContext: false)
        let baseEstimate =
            AgentTokenEstimator.approximateInputTokens(
                messages: preTurnContext,
                tools: [])
        let dynamicEstimate =
            AgentTokenEstimator.approximateInputTokens(
                messages: preTurnContext,
                tools: [dynamicSpec])
        XCTAssertGreaterThan(dynamicEstimate, baseEstimate + 1)
        let trigger = baseEstimate + 1
        XCTAssertLessThan(baseEstimate, trigger)
        XCTAssertGreaterThanOrEqual(dynamicEstimate, trigger)
        let policy = AgentModelContextPolicy(
            contextWindowTokens: dynamicEstimate + 4_000,
            autoCompactTokenLimit: trigger)
        let snapshotProbe = CompactionToolSnapshotProbe(
            snapshot: AgentRequestToolSnapshot(
                snapshotID: "dynamic-snapshot-v1",
                registry: ToolRegistry([]),
                providerToolSpecs: [dynamicSpec]))
        let provider = CompactionScriptedProvider([
            [
                .textDelta("DYNAMIC SUMMARY"),
                .done(finishReason: "stop"),
            ],
            [
                .textDelta("CURRENT ANSWER"),
                .done(finishReason: "stop"),
            ],
        ])
        let loop = makeRootLoop(
            fixture: fixture,
            provider: provider,
            task: currentTask,
            modelContextPolicy: policy,
            toolSnapshotProvider: { _, _ in
                await snapshotProbe.resolve()
            })

        let answer = try await loop.send(
            "CURRENT",
            recordUserMessage: false,
            submissionID: currentID)
        XCTAssertEqual(answer, "CURRENT ANSWER")
        let snapshotResolutionCount =
            await snapshotProbe.resolutionCount()
        XCTAssertEqual(
            snapshotResolutionCount,
            1,
            "pre-turn and first ordinary dispatch must share one snapshot")
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertTrue(
            provider.requests[0].tools.isEmpty,
            "the compaction request itself must remain tool-free")
        XCTAssertEqual(provider.requests[1].tools, [dynamicSpec])

        let replay = try await fixture.log.replayChecked()
        let checkpoint = try XCTUnwrap(replay.compactMap {
            envelope -> ModelHistoryCompactedPayload? in
            guard case .modelHistoryCompacted(let payload) =
                    envelope.event else {
                return nil
            }
            return payload
        }.first)
        let replacementMessages = checkpoint.replacementHistory.compactMap {
            item -> AgentMessage? in
            guard let content = item.content else { return nil }
            return .user(content)
        }
        let replacementRequest = builder.initialMessages(
            history: replacementMessages,
            userText: "",
            includeCurrentUser: false,
            includeCurrentTurnContext: false)
        XCTAssertLessThanOrEqual(
            AgentTokenEstimator.approximateInputTokens(
                messages: replacementRequest,
                tools: [dynamicSpec]),
            try XCTUnwrap(policy.hardUsableContextWindowTokens))
    }

    func testPreTurnSnapshotResolutionFailureDoesNotFallBackOrWriteCurrentHistory()
        async throws
    {
        let fixture = try makeFixture("snapshot_failure")
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let submissionID =
            SubmissionID(rawValue: "sub_snapshot_failure")
        let task = rootTask(
            "task_snapshot_failure",
            submissionID,
            "CURRENT")
        try await fixture.log.append([
            .userMessage(UserMessagePayload(
                text: "CURRENT",
                to: main,
                submissionID: submissionID)),
            .taskCreated(TaskCreatedPayload(contract: task)),
        ])
        let provider = CompactionScriptedProvider([
            [
                .textDelta("MUST NOT DISPATCH"),
                .done(finishReason: "stop"),
            ],
        ])
        let loop = makeRootLoop(
            fixture: fixture,
            provider: provider,
            task: task,
            toolSnapshotProvider: { _, _ in
                throw CompactionSnapshotFailure.unavailable
            })

        do {
            _ = try await loop.send(
                "CURRENT",
                recordUserMessage: false,
                submissionID: submissionID)
            XCTFail("snapshot failure must fail closed")
        } catch CompactionSnapshotFailure.unavailable {
            // Expected.
        }

        XCTAssertTrue(provider.requests.isEmpty)
        let replay = try await fixture.log.replayChecked()
        XCTAssertFalse(replay.contains {
            guard case .modelHistoryItem(let payload) = $0.event else {
                return false
            }
            return payload.submissionID == submissionID
        })
        XCTAssertFalse(replay.contains {
            if case .modelHistoryCompacted = $0.event { return true }
            return false
        })
    }

    func testMidTurnToolCompactionPersistsContextUserSummaryAndUsesNoIteration()
        async throws
    {
        let fixture = try makeFixture("midturn")
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let submissionID = SubmissionID(rawValue: "sub_compact_midturn")
        let task = rootTask(
            "task_compact_midturn",
            submissionID,
            "MIDTURN USER")
        try await fixture.log.append([
            .userMessage(UserMessagePayload(
                text: "MIDTURN USER",
                to: main,
                submissionID: submissionID)),
            .taskCreated(TaskCreatedPayload(contract: task)),
        ])
        let provider = CompactionScriptedProvider([
            [
                .toolCalls([
                    ToolCall(
                        id: "call_large",
                        name: "read_large_probe",
                        arguments: #"{"path":"A"}"#),
                ]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .textDelta("MID-TURN SUMMARY"),
                .done(finishReason: "stop"),
            ],
            [
                .textDelta("MID-TURN FINAL"),
                .done(finishReason: "stop"),
            ],
        ])
        let loop = makeRootLoop(
            fixture: fixture,
            provider: provider,
            task: task,
            registry: ToolRegistry([CompactionLargeProbeTool()]),
            modelContextPolicy:
                AgentModelContextPolicy(autoCompactTokenLimit: 3_000),
            maxIterations: 2)

        let result = try await loop.send(
            "MIDTURN USER",
            recordUserMessage: false,
            submissionID: submissionID)

        XCTAssertEqual(result, "MID-TURN FINAL")
        XCTAssertEqual(
            provider.requests.count,
            3,
            "the compaction dispatch must not consume an AgentLoop iteration")
        XCTAssertFalse(provider.requests[0].tools.isEmpty)
        XCTAssertTrue(provider.requests[1].tools.isEmpty)
        XCTAssertTrue(provider.requests[1].messages.contains {
            $0.content?.contains("large-observation-") == true
        })

        let replay = try await fixture.log.replayChecked()
        let checkpoints = replay.compactMap {
            envelope -> (Int, ModelHistoryCompactedPayload)? in
            guard case .modelHistoryCompacted(let payload) = envelope.event
            else {
                return nil
            }
            return (envelope.seq, payload)
        }
        XCTAssertEqual(checkpoints.count, 1)
        let (checkpointSequence, checkpoint) = try XCTUnwrap(
            checkpoints.first)
        XCTAssertEqual(
            checkpoint.replacementHistory.map(\.messageClassification),
            [.contextual, .realUser, .compactionSummary])
        let replacementContents = checkpoint.replacementHistory.compactMap(
            \.content)
        XCTAssertTrue(
            replacementContents[0].contains("UNTRUSTED_CONTEXT_DATA"))
        XCTAssertEqual(replacementContents[1], "MIDTURN USER")
        XCTAssertEqual(replacementContents[2], checkpoint.message)

        let finalAssistantSequence = try XCTUnwrap(replay.first {
            guard case .modelHistoryItem(let payload) = $0.event else {
                return false
            }
            return payload.role == .assistant
                && payload.content == "MID-TURN FINAL"
        }?.seq)
        XCTAssertLessThan(checkpointSequence, finalAssistantSequence)

        let continuationUsers = provider.requests[2].messages.filter {
            $0.role == .user
        }
        XCTAssertGreaterThanOrEqual(continuationUsers.count, 3)
        XCTAssertEqual(
            Array(continuationUsers.suffix(3)).map(\.content),
            replacementContents.map(Optional.some))
    }

    func testMidTurnCompactionUsesAndReusesExactNextDynamicToolSnapshot()
        async throws
    {
        let fixture = try makeFixture("midturn_dynamic_snapshot")
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let submissionID =
            SubmissionID(rawValue: "sub_midturn_dynamic_snapshot")
        let task = rootTask(
            "task_midturn_dynamic_snapshot",
            submissionID,
            "MIDTURN DYNAMIC USER")
        try await fixture.log.append([
            .userMessage(UserMessagePayload(
                text: "MIDTURN DYNAMIC USER",
                to: main,
                submissionID: submissionID)),
            .taskCreated(TaskCreatedPayload(contract: task)),
        ])

        let call = ToolCall(
            id: "call_midturn_dynamic",
            name: "read_large_probe",
            arguments: #"{"path":"D"}"#)
        let smallSpec = ToolSpec(
            name: CompactionLargeProbeTool.descriptor.name,
            description: CompactionLargeProbeTool.descriptor.description,
            parameters: CompactionLargeProbeTool.descriptor.parameters)
        let dynamicSpec = ToolSpec(
            name: "mcp__dynamic__expanded_catalog",
            description: String(
                repeating: "next-request-dynamic-schema-",
                count: 1_500),
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ]))
        let firstSpecs = [smallSpec]
        let nextSpecs = [smallSpec, dynamicSpec]
        let observation =
            "probe:D:"
            + String(repeating: "large-observation-", count: 1_200)
        var postToolMessages = rootContext(task).initialMessages(
            history: [],
            userText: "MIDTURN DYNAMIC USER")
        postToolMessages.append(.assistant(
            toolCalls: [call],
            content: nil))
        postToolMessages.append(.tool(
            id: call.id,
            content: observation))
        let currentEstimate =
            AgentTokenEstimator.approximateInputTokens(
                messages: postToolMessages,
                tools: firstSpecs)
        let nextEstimate =
            AgentTokenEstimator.approximateInputTokens(
                messages: postToolMessages,
                tools: nextSpecs)
        XCTAssertGreaterThan(nextEstimate, currentEstimate + 1)
        let trigger = currentEstimate + 1
        XCTAssertLessThan(currentEstimate, trigger)
        XCTAssertGreaterThanOrEqual(nextEstimate, trigger)
        let policy = AgentModelContextPolicy(
            contextWindowTokens: nextEstimate + 4_000,
            autoCompactTokenLimit: trigger)
        let registry = ToolRegistry([CompactionLargeProbeTool()])
        let snapshotProbe = CompactionToolSnapshotSequenceProbe(
            snapshots: [
                AgentRequestToolSnapshot(
                    snapshotID: "midturn-dynamic-small",
                    registry: registry,
                    providerToolSpecs: firstSpecs),
                AgentRequestToolSnapshot(
                    snapshotID: "midturn-dynamic-large",
                    registry: registry,
                    providerToolSpecs: nextSpecs),
            ])
        let provider = CompactionScriptedProvider([
            [
                .toolCalls([call]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .textDelta("MIDTURN DYNAMIC SUMMARY"),
                .done(finishReason: "stop"),
            ],
            [
                .textDelta("MIDTURN DYNAMIC FINAL"),
                .done(finishReason: "stop"),
            ],
        ])
        let loop = makeRootLoop(
            fixture: fixture,
            provider: provider,
            task: task,
            registry: registry,
            modelContextPolicy: policy,
            maxIterations: 2,
            toolSnapshotProvider: { _, _ in
                try await snapshotProbe.resolve()
            })

        let answer = try await loop.send(
            "MIDTURN DYNAMIC USER",
            recordUserMessage: false,
            submissionID: submissionID)

        XCTAssertEqual(answer, "MIDTURN DYNAMIC FINAL")
        let snapshotResolutionCount =
            await snapshotProbe.resolutionCount()
        XCTAssertEqual(
            snapshotResolutionCount,
            2,
            "first dispatch and next continuation must each resolve once")
        XCTAssertEqual(provider.requests.count, 3)
        XCTAssertEqual(provider.requests[0].tools, firstSpecs)
        XCTAssertTrue(
            provider.requests[1].tools.isEmpty,
            "the compaction request itself must remain tool-free")
        XCTAssertEqual(
            provider.requests[2].tools,
            nextSpecs,
            "the continuation must consume the snapshot used for compaction")

        let replay = try await fixture.log.replayChecked()
        let checkpoint = try XCTUnwrap(replay.compactMap {
            envelope -> ModelHistoryCompactedPayload? in
            guard case .modelHistoryCompacted(let payload) =
                    envelope.event else {
                return nil
            }
            return payload
        }.first)
        let replacementMessages = checkpoint.replacementHistory.compactMap {
            item -> AgentMessage? in
            guard let content = item.content else { return nil }
            return .user(content)
        }
        let replacementRequest = rootContext(task).initialMessages(
            history: replacementMessages,
            userText: "",
            includeCurrentUser: false,
            includeCurrentTurnContext: false)
        XCTAssertLessThanOrEqual(
            AgentTokenEstimator.approximateInputTokens(
                messages: replacementRequest,
                tools: nextSpecs),
            try XCTUnwrap(policy.hardUsableContextWindowTokens))
    }

    func testMidTurnNextSnapshotFailureStopsBeforeCheckpointOrSecondRequest()
        async throws
    {
        let fixture = try makeFixture("midturn_snapshot_failure")
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let submissionID =
            SubmissionID(rawValue: "sub_midturn_snapshot_failure")
        let task = rootTask(
            "task_midturn_snapshot_failure",
            submissionID,
            "MIDTURN SNAPSHOT FAILURE")
        try await fixture.log.append([
            .userMessage(UserMessagePayload(
                text: "MIDTURN SNAPSHOT FAILURE",
                to: main,
                submissionID: submissionID)),
            .taskCreated(TaskCreatedPayload(contract: task)),
        ])
        let registry = ToolRegistry([CompactionLargeProbeTool()])
        let smallSpec = ToolSpec(
            name: CompactionLargeProbeTool.descriptor.name,
            description: CompactionLargeProbeTool.descriptor.description,
            parameters: CompactionLargeProbeTool.descriptor.parameters)
        let firstSnapshot = AgentRequestToolSnapshot(
            snapshotID: "midturn-failure-first",
            registry: registry,
            providerToolSpecs: [smallSpec])
        let snapshotProbe = CompactionToolSnapshotSequenceProbe(
            snapshots: [firstSnapshot],
            failingResolution: 2)
        let provider = CompactionScriptedProvider([
            [
                .toolCalls([
                    ToolCall(
                        id: "call_midturn_failure",
                        name: "read_large_probe",
                        arguments: #"{"path":"F"}"#),
                ]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .textDelta("MUST NOT DISPATCH"),
                .done(finishReason: "stop"),
            ],
        ])
        let loop = makeRootLoop(
            fixture: fixture,
            provider: provider,
            task: task,
            registry: registry,
            maxIterations: 2,
            toolSnapshotProvider: { _, _ in
                try await snapshotProbe.resolve()
            })

        do {
            _ = try await loop.send(
                "MIDTURN SNAPSHOT FAILURE",
                recordUserMessage: false,
                submissionID: submissionID)
            XCTFail("the next snapshot failure must fail closed")
        } catch CompactionSnapshotFailure.unavailable {
            // Expected.
        }

        let snapshotResolutionCount =
            await snapshotProbe.resolutionCount()
        XCTAssertEqual(snapshotResolutionCount, 2)
        XCTAssertEqual(
            provider.requests.count,
            1,
            "snapshot failure must precede the continuation provider request")
        let replay = try await fixture.log.replayChecked()
        XCTAssertFalse(replay.contains {
            if case .modelHistoryCompacted = $0.event {
                return true
            }
            return false
        })
    }

    func testFinalAnswerOverThresholdDoesNotImmediatelyCompact() async throws {
        let fixture = try makeFixture("final_no_compact")
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let submissionID = SubmissionID(rawValue: "sub_final_no_compact")
        let task = rootTask(
            "task_final_no_compact",
            submissionID,
            "SHORT USER")
        try await fixture.log.append([
            .userMessage(UserMessagePayload(
                text: "SHORT USER",
                to: main,
                submissionID: submissionID)),
            .taskCreated(TaskCreatedPayload(contract: task)),
        ])
        let largeFinal =
            "FINAL:"
            + String(repeating: "large-final-answer-", count: 1_200)
        let provider = CompactionScriptedProvider([
            [
                .textDelta(largeFinal),
                .done(finishReason: "stop"),
            ],
        ])
        let loop = makeRootLoop(
            fixture: fixture,
            provider: provider,
            task: task,
            modelContextPolicy:
                AgentModelContextPolicy(autoCompactTokenLimit: 3_000))

        let result = try await loop.send(
            "SHORT USER",
            recordUserMessage: false,
            submissionID: submissionID)
        XCTAssertEqual(result, largeFinal)
        XCTAssertEqual(provider.requests.count, 1)
        let replay = try await fixture.log.replayChecked()
        XCTAssertFalse(replay.contains {
            if case .modelHistoryCompacted = $0.event { return true }
            return false
        })
    }

    func testMalformedPreTurnCompactionWritesNoCheckpointAndDoesNotDispatchNormally()
        async throws
    {
        let fixture = try makeFixture("malformed")
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let previousID = SubmissionID(rawValue: "sub_malformed_previous")
        let currentID = SubmissionID(rawValue: "sub_malformed_current")
        let previousTask = rootTask(
            "task_malformed_previous",
            previousID,
            "PREVIOUS")
        let currentTask = rootTask(
            "task_malformed_current",
            currentID,
            "MALFORMED INCOMING")
        try await appendCompletedDirectTurn(
            log: fixture.log,
            task: previousTask,
            userText: "PREVIOUS",
            assistantText: "PREVIOUS ANSWER")
        try await fixture.log.append([
            .userMessage(UserMessagePayload(
                text: "MALFORMED INCOMING",
                to: main,
                submissionID: currentID)),
            .taskCreated(TaskCreatedPayload(contract: currentTask)),
        ])
        let provider = CompactionScriptedProvider([
            [.textDelta("partial without completion marker")],
        ])
        let loop = makeRootLoop(
            fixture: fixture,
            provider: provider,
            task: currentTask,
            modelContextPolicy:
                AgentModelContextPolicy(autoCompactTokenLimit: 1))

        do {
            _ = try await loop.send(
                "MALFORMED INCOMING",
                recordUserMessage: false,
                submissionID: currentID)
            XCTFail("malformed compaction must fail closed")
        } catch let error as AgentModelHistoryCompactionError {
            XCTAssertEqual(
                error,
                .responseEndedWithoutCompletionMarker)
        }

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertFalse(provider.requests[0].messages.contains {
            $0.content?.contains("MALFORMED INCOMING") == true
        })
        let replay = try await fixture.log.replayChecked()
        XCTAssertFalse(replay.contains {
            if case .modelHistoryCompacted = $0.event { return true }
            return false
        })
        XCTAssertFalse(replay.contains {
            guard case .modelHistoryItem(let payload) = $0.event else {
                return false
            }
            return payload.submissionID == currentID
        })
    }

    func testOversizedCompactionSummaryWritesNoCheckpoint()
        async throws
    {
        let fixture = try makeFixture("oversized_summary")
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let previousID =
            SubmissionID(rawValue: "sub_oversized_previous")
        let currentID =
            SubmissionID(rawValue: "sub_oversized_current")
        let previousTask = rootTask(
            "task_oversized_previous",
            previousID,
            String(repeating: "old-", count: 5_000))
        let currentTask = rootTask(
            "task_oversized_current",
            currentID,
            "CURRENT")
        try await appendCompletedDirectTurn(
            log: fixture.log,
            task: previousTask,
            userText: previousTask.objective,
            assistantText: "old answer")
        try await fixture.log.append([
            .userMessage(UserMessagePayload(
                text: "CURRENT",
                to: main,
                submissionID: currentID)),
            .taskCreated(TaskCreatedPayload(contract: currentTask)),
        ])
        let provider = CompactionScriptedProvider([
            [
                .textDelta(
                    String(
                        repeating: "provider-ignored-ceiling-",
                        count: 2_000)),
                .done(finishReason: "stop"),
            ],
        ])
        let loop = makeRootLoop(
            fixture: fixture,
            provider: provider,
            task: currentTask,
            modelContextPolicy: AgentModelContextPolicy(
                contextWindowTokens: 4_000,
                autoCompactTokenLimit: 1))

        do {
            _ = try await loop.send(
                "CURRENT",
                recordUserMessage: false,
                submissionID: currentID)
            XCTFail("an oversized summary must fail before checkpoint commit")
        } catch let error as AgentModelHistoryCompactionError {
            switch error {
            case .summaryOutputLimitExceeded,
                 .replacementExceedsUsableContext:
                break
            default:
                return XCTFail("unexpected error: \(error)")
            }
        }

        let replay = try await fixture.log.replayChecked()
        XCTAssertFalse(replay.contains {
            if case .modelHistoryCompacted = $0.event {
                return true
            }
            return false
        })
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertNotNil(provider.requests[0].maxOutputTokens)
    }

    func testTaskScopedWorkerNeverCompactsEvenWithOneTokenThreshold()
        async throws
    {
        let fixture = try makeFixture("worker")
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let worker = AgentID(rawValue: "worker")
        let task = TaskContract(
            id: TaskID(rawValue: "task_worker"),
            kind: .agentInvocation,
            issuer: main,
            assignee: worker,
            objective: "worker objective",
            roleHint: "worker",
            expectedDeliverable: "worker result")
        let provider = CompactionScriptedProvider([
            [
                .textDelta("WORKER FINAL"),
                .done(finishReason: "stop"),
            ],
        ])
        let loop = AgentLoop(
            log: fixture.log,
            provider: provider,
            registry: ToolRegistry([]),
            engine: PermissionEngine(),
            responder: FixedResponder(.allow),
            agent: Agent(
                name: worker,
                workspaceRoot: fixture.workspace,
                model: ModelID(rawValue: "test-model"),
                profile: .reviewed),
            context: ContextBuilder(
                systemPrompt: "system",
                taskContract: task,
                contextBundle: ContextBundle(
                    globalBrief: task.objective,
                    safetyPolicy: "test",
                    taskContract: task),
                runtimeEnvironment: .cowork,
                conversationHistoryPolicy: .taskScoped),
            allowsShell: false,
            modelContextPolicy:
                AgentModelContextPolicy(autoCompactTokenLimit: 1),
            maxIterations: 2,
            taskAttempt: 1)

        let result = try await loop.send("worker objective")
        XCTAssertEqual(result, "WORKER FINAL")
        XCTAssertEqual(provider.requests.count, 1)
        let replay = try await fixture.log.replayChecked()
        XCTAssertFalse(replay.contains {
            if case .modelHistoryCompacted = $0.event { return true }
            return false
        })
    }

    func testFreshLoopRestoresCheckpointReplacementAndPostCheckpointSuffix()
        async throws
    {
        let fixture = try makeFixture("restart")
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let firstID = SubmissionID(rawValue: "sub_restart_first")
        let firstTask = rootTask(
            "task_restart_first",
            firstID,
            "FIRST USER")
        try await fixture.log.append([
            .userMessage(UserMessagePayload(
                text: "FIRST USER",
                to: main,
                submissionID: firstID)),
            .taskCreated(TaskCreatedPayload(contract: firstTask)),
        ])
        let firstProvider = CompactionScriptedProvider([
            [
                .toolCalls([
                    ToolCall(
                        id: "call_restart",
                        name: "read_large_probe",
                        arguments: #"{"path":"R"}"#),
                ]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .textDelta("RESTART SUMMARY"),
                .done(finishReason: "stop"),
            ],
            [
                .textDelta("FIRST FINAL"),
                .done(finishReason: "stop"),
            ],
        ])
        let firstLoop = makeRootLoop(
            fixture: fixture,
            provider: firstProvider,
            task: firstTask,
            registry: ToolRegistry([CompactionLargeProbeTool()]),
            modelContextPolicy:
                AgentModelContextPolicy(autoCompactTokenLimit: 3_000),
            maxIterations: 2)
        let firstResult = try await firstLoop.send(
            "FIRST USER",
            recordUserMessage: false,
            submissionID: firstID)
        XCTAssertEqual(firstResult, "FIRST FINAL")

        let secondID = SubmissionID(rawValue: "sub_restart_second")
        let secondTask = rootTask(
            "task_restart_second",
            secondID,
            "SECOND USER")
        try await fixture.log.append([
            .userMessage(UserMessagePayload(
                text: "SECOND USER",
                to: main,
                submissionID: secondID)),
            .taskCreated(TaskCreatedPayload(contract: secondTask)),
        ])
        let secondProvider = CompactionScriptedProvider([
            [
                .textDelta("SECOND FINAL"),
                .done(finishReason: "stop"),
            ],
        ])
        let freshLoop = makeRootLoop(
            fixture: fixture,
            provider: secondProvider,
            task: secondTask)

        let secondResult = try await freshLoop.send(
            "SECOND USER",
            recordUserMessage: false,
            submissionID: secondID)
        XCTAssertEqual(secondResult, "SECOND FINAL")
        XCTAssertEqual(secondProvider.requests.count, 1)
        let request = secondProvider.requests[0]
        let userContents = request.messages
            .filter { $0.role == .user }
            .compactMap(\.content)
        let contextualIndex = try XCTUnwrap(userContents.firstIndex {
            $0.contains("UNTRUSTED_CONTEXT_DATA")
        })
        let firstUserIndex = try XCTUnwrap(
            userContents.firstIndex(of: "FIRST USER"))
        let summaryIndex = try XCTUnwrap(userContents.firstIndex {
            $0.contains("RESTART SUMMARY")
        })
        let secondUserIndex = try XCTUnwrap(
            userContents.lastIndex(of: "SECOND USER"))
        XCTAssertLessThan(contextualIndex, firstUserIndex)
        XCTAssertLessThan(firstUserIndex, summaryIndex)
        XCTAssertLessThan(summaryIndex, secondUserIndex)
        XCTAssertTrue(request.messages.contains {
            $0.role == .assistant && $0.content == "FIRST FINAL"
        })
        XCTAssertFalse(request.messages.contains {
            $0.content?.contains("large-observation-") == true
        })
    }

    private struct Fixture {
        var workspace: URL
        var log: EventLog
    }

    private func makeFixture(_ name: String) throws -> Fixture {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-model-history-compaction-\(name)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        let log = try EventLog(
            session: SessionID(rawValue: "sess_compaction_\(name)"),
            fileURL: workspace.appendingPathComponent("events.jsonl"))
        return Fixture(workspace: workspace, log: log)
    }

    private func makeRootLoop(
        fixture: Fixture,
        provider: ToolCallingProvider,
        task: TaskContract,
        registry: ToolRegistry = ToolRegistry([]),
        responder: PermissionResponder = FixedResponder(.allow),
        modelContextPolicy: AgentModelContextPolicy = .unspecified,
        maxIterations: Int = 50,
        toolSnapshotProvider:
            AgentRequestToolSnapshotProvider? = nil
    ) -> AgentLoop {
        AgentLoop(
            log: fixture.log,
            provider: provider,
            registry: registry,
            engine: PermissionEngine(),
            responder: responder,
            agent: Agent(
                name: main,
                workspaceRoot: fixture.workspace,
                model: ModelID(rawValue: "test-model"),
                profile: .reviewed),
            context: rootContext(task),
            allowsShell: false,
            modelContextPolicy: modelContextPolicy,
            maxIterations: maxIterations,
            taskAttempt: 1,
            toolSnapshotProvider: toolSnapshotProvider)
    }

    private func rootContext(_ task: TaskContract) -> ContextBuilder {
        ContextBuilder(
            systemPrompt: "system",
            taskContract: task,
            contextBundle: ContextBundle(
                globalBrief: task.objective,
                safetyPolicy: "test",
                taskContract: task),
            runtimeEnvironment: .cowork,
            conversationHistoryPolicy: .coworkMainThread)
    }

    private func appendCompletedDirectTurn(
        log: EventLog,
        task: TaskContract,
        userText: String,
        assistantText: String
    ) async throws {
        let submissionID = try XCTUnwrap(task.submissionID)
        let turnID = TurnID.new()
        try await log.append([
            .userMessage(UserMessagePayload(
                text: userText,
                to: main,
                submissionID: submissionID)),
            .taskCreated(TaskCreatedPayload(contract: task)),
            .modelHistoryItem(.message(
                itemID: "seed-user:\(turnID.rawValue)",
                turnID: turnID,
                agent: main,
                taskID: task.id,
                submissionID: submissionID,
                taskAttempt: 1,
                role: .user,
                content: userText,
                messageClassification: .realUser)),
            .modelHistoryItem(.message(
                itemID: "seed-assistant:\(turnID.rawValue)",
                turnID: turnID,
                agent: main,
                taskID: task.id,
                submissionID: submissionID,
                taskAttempt: 1,
                role: .assistant,
                content: assistantText)),
        ])
    }

    private func rootTask(
        _ taskID: String,
        _ submissionID: SubmissionID,
        _ objective: String
    ) -> TaskContract {
        TaskContract(
            id: TaskID(rawValue: taskID),
            kind: .root,
            issuer: nil,
            assignee: main,
            submissionID: submissionID,
            objective: objective,
            roleHint: "root",
            expectedDeliverable: "answer")
    }
}
