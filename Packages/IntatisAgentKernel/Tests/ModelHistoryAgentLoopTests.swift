import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
@testable import IntatisAgentKernel

private final class ModelHistoryScriptedProvider:
    ToolCallingProvider, @unchecked Sendable
{
    private let lock = NSLock()
    private let responses: [[AgentChunk]]
    private var responseIndex = 0
    private var capturedRequests: [AgentRequest] = []

    init(_ responses: [[AgentChunk]]) {
        self.responses = responses
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
        let response = responses[min(responseIndex, responses.count - 1)]
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

private struct ModelHistoryProbeArguments: Decodable {
    var path: String
}

private struct ModelHistoryProbeTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "read_probe",
        description: "Returns a stable test observation.",
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
        let decoded = try args.decode(ModelHistoryProbeArguments.self)
        return ToolObservation(text: "probe:\(decoded.path)")
    }
}

private struct ModelHistoryStdinArguments: Decodable {
    var characters: String
}

private struct ModelHistoryStdinTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "write_stdin",
        description: "Test-only sensitive-input sink.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "characters": .object([
                    "type": .string("string"),
                    "minLength": .number(1),
                ]),
            ]),
            "required": .array([.string("characters")]),
            "additionalProperties": .bool(false),
        ]))

    func execute(
        _ args: ToolArgs,
        in context: ToolContext
    ) async throws -> ToolObservation {
        _ = try args.decode(ModelHistoryStdinArguments.self)
        return ToolObservation(text: "input accepted")
    }
}

final class ModelHistoryAgentLoopTests: XCTestCase {
    private let main = AgentID(rawValue: "main")

    func testEmptyListFilesOutputPersistsAndContinuesTheTurn() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("empty", isDirectory: true),
            withIntermediateDirectories: false)
        let log = try EventLog(
            session: SessionID(rawValue: "sess_model_history_empty_output"),
            fileURL: workspace.appendingPathComponent("events.jsonl"))
        let submissionID = SubmissionID(rawValue: "sub_empty_output")
        let task = rootTask(
            "task_empty_output",
            submissionID,
            "inspect the empty directory")
        try await log.append([
            .userMessage(UserMessagePayload(
                text: "inspect the empty directory",
                to: main,
                submissionID: submissionID)),
            .taskCreated(TaskCreatedPayload(contract: task)),
        ])
        let provider = ModelHistoryScriptedProvider([
            [
                .toolCalls([
                    ToolCall(
                        id: "call_empty_list",
                        name: "list_files",
                        arguments: #"{"path":"empty"}"#),
                ]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .textDelta("The directory is empty."),
                .done(finishReason: "stop"),
            ],
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([ListFilesTool()]),
            task: task)

        let result = try await loop.send(
            "inspect the empty directory",
            recordUserMessage: false,
            submissionID: submissionID)

        XCTAssertEqual(result, "The directory is empty.")
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertTrue(provider.requests[1].messages.contains(
            .tool(id: "call_empty_list", content: "")))

        let events = try await log.replayChecked()
        let toolResult = try XCTUnwrap(events.compactMap {
            envelope -> (Int, ToolResultPayload)? in
            guard case .toolResult(let payload) = envelope.event,
                  payload.toolCallId == "call_empty_list" else {
                return nil
            }
            return (envelope.seq, payload)
        }.first)
        XCTAssertEqual(toolResult.1.observation, "")
        XCTAssertEqual(toolResult.1.outcome, .succeeded)

        let settlement = try XCTUnwrap(events.compactMap {
            envelope -> (Int, ToolExecutionSettledPayload)? in
            guard case .toolExecutionSettled(let payload) = envelope.event,
                  payload.toolCallID == "call_empty_list" else {
                return nil
            }
            return (envelope.seq, payload)
        }.first)
        XCTAssertEqual(settlement.1.outcome, .succeeded)
        XCTAssertEqual(settlement.1.effectDisposition, .committed)

        let historyOutput = try XCTUnwrap(events.compactMap {
            envelope -> (Int, ModelHistoryItemPayload)? in
            guard case .modelHistoryItem(let payload) = envelope.event,
                  payload.kind == .functionCallOutput,
                  payload.callID == "call_empty_list" else {
                return nil
            }
            return (envelope.seq, payload)
        }.first)
        XCTAssertEqual(historyOutput.1.output, "")
        XCTAssertNil(historyOutput.1.imageReferences)
        XCTAssertEqual(settlement.0, toolResult.0 + 1)
        XCTAssertEqual(historyOutput.0, settlement.0 + 1)

        let outcomes = events.compactMap { envelope -> TurnOutcomePayload? in
            guard case .turnOutcome(let payload) = envelope.event else {
                return nil
            }
            return payload
        }
        XCTAssertEqual(outcomes.map(\.outcome), [.completed])
    }

    func testFreshLoopReplaysDurableCallOutputAndFinalAnswerBeforeNextUser() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let log = try EventLog(
            session: SessionID(rawValue: "sess_model_history_loop"),
            fileURL: workspace.appendingPathComponent("events.jsonl"))
        let firstID = SubmissionID(rawValue: "sub_history_first")
        let secondID = SubmissionID(rawValue: "sub_history_second")
        let firstTask = rootTask("task_history_first", firstID, "U1")
        let secondTask = rootTask("task_history_second", secondID, "U2")
        try await log.append([
            .userMessage(UserMessagePayload(
                text: "U1",
                to: main,
                submissionID: firstID)),
            .taskCreated(TaskCreatedPayload(contract: firstTask)),
        ])

        let firstProvider = ModelHistoryScriptedProvider([
            [
                .toolCalls([
                    ToolCall(
                        id: "call_probe",
                        name: "read_probe",
                        arguments: #"{"path":"A"}"#),
                ]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .textDelta("A1"),
                .done(finishReason: "stop"),
            ],
        ])
        let firstLoop = makeLoop(
            workspace: workspace,
            log: log,
            provider: firstProvider,
            registry: ToolRegistry([ModelHistoryProbeTool()]),
            task: firstTask)
        let firstResult = try await firstLoop.send(
            "U1",
            recordUserMessage: false,
            submissionID: firstID)
        XCTAssertEqual(firstResult, "A1")

        let afterFirst = try await log.replayChecked()
        let firstHistory: [ModelHistoryItemPayload] = afterFirst.compactMap {
            envelope -> ModelHistoryItemPayload? in
            guard case .modelHistoryItem(let payload) = envelope.event else {
                return nil
            }
            return payload
        }
        XCTAssertEqual(
            firstHistory.map(\.kind),
            [.message, .functionCallBatch, .functionCallOutput, .message])
        XCTAssertEqual(
            firstHistory[1].functionCalls?.first?.arguments,
            #"{"path":"A"}"#)
        XCTAssertEqual(firstHistory[2].output, "probe:A")

        let batchSequence = try XCTUnwrap(afterFirst.first {
            guard case .modelHistoryItem(let payload) = $0.event else {
                return false
            }
            return payload.kind == .functionCallBatch
        }?.seq)
        let auditCallSequence = try XCTUnwrap(afterFirst.first {
            if case .toolCall = $0.event { return true }
            return false
        }?.seq)
        XCTAssertLessThan(batchSequence, auditCallSequence)
        let auditResultSequence = try XCTUnwrap(afterFirst.first {
            guard case .toolResult(let payload) = $0.event else {
                return false
            }
            return payload.toolCallId == "call_probe"
        }?.seq)
        let settledSequence = try XCTUnwrap(afterFirst.first {
            guard case .toolExecutionSettled(let payload) = $0.event else {
                return false
            }
            return payload.toolCallID == "call_probe"
        }?.seq)
        let modelOutputSequence = try XCTUnwrap(afterFirst.first {
            guard case .modelHistoryItem(let payload) = $0.event else {
                return false
            }
            return payload.kind == .functionCallOutput
                && payload.callID == "call_probe"
        }?.seq)
        XCTAssertLessThan(auditResultSequence, settledSequence)
        XCTAssertEqual(modelOutputSequence, settledSequence + 1)

        try await log.append([
            .userMessage(UserMessagePayload(
                text: "U2",
                to: main,
                submissionID: secondID)),
            .taskCreated(TaskCreatedPayload(contract: secondTask)),
        ])
        let allEvents = try await log.replayChecked()
        let eventsWithoutDirectOutput = allEvents.filter { envelope in
            guard case .modelHistoryItem(let payload) = envelope.event else {
                return true
            }
            return payload.kind != .functionCallOutput
        }
        let incompleteDirectContext = ContextProjector().project(
            agentID: main,
            taskContract: secondTask,
            events: eventsWithoutDirectOutput,
            allowedToolNames: ["read_probe"],
            workspaceRoot: workspace,
            projectsCompletedRootAnswersIntoConversation: true)
        XCTAssertTrue(incompleteDirectContext.agentLocalEvents
            .map(\.content)
            .joined(separator: "\n")
            .contains("probe:A"))
        let secondContext = ContextProjector().project(
            agentID: main,
            taskContract: secondTask,
            events: allEvents,
            allowedToolNames: ["read_probe"],
            workspaceRoot: workspace,
            projectsCompletedRootAnswersIntoConversation: true)
        let projectedAuditText = secondContext.agentLocalEvents
            .map(\.content)
            .joined(separator: "\n")
        XCTAssertFalse(projectedAuditText.contains("read_probe"))
        XCTAssertFalse(projectedAuditText.contains("probe:A"))
        let secondProvider = ModelHistoryScriptedProvider([
            [
                .textDelta("A2"),
                .done(finishReason: "stop"),
            ],
        ])
        let freshLoop = makeLoop(
            workspace: workspace,
            log: log,
            provider: secondProvider,
            registry: ToolRegistry([ModelHistoryProbeTool()]),
            task: secondTask)
        let secondResult = try await freshLoop.send(
            "U2",
            recordUserMessage: false,
            submissionID: secondID)
        XCTAssertEqual(secondResult, "A2")

        let request = try XCTUnwrap(secondProvider.requests.first)
        let history = request.messages.filter {
            $0.role != .system
                && $0.content?.contains("<<<UNTRUSTED_CONTEXT_DATA>>>") != true
        }
        XCTAssertEqual(history.count, 5)
        XCTAssertEqual(history[0], .user("U1"))
        XCTAssertEqual(history[1].role, .assistant)
        XCTAssertEqual(history[1].toolCalls?.map(\.id), ["call_probe"])
        XCTAssertEqual(
            history[1].toolCalls?.map(\.arguments),
            [#"{"path":"A"}"#])
        XCTAssertEqual(history[2], .tool(id: "call_probe", content: "probe:A"))
        XCTAssertEqual(history[3], .assistant("A1"))
        XCTAssertEqual(history[4], .user("U2"))
    }

    func testSensitiveStdinArgumentsNeverEnterDurableModelOrAuditHistory() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let eventLogURL = workspace.appendingPathComponent("events.jsonl")
        let log = try EventLog(
            session: SessionID(rawValue: "sess_model_history_stdin"),
            fileURL: eventLogURL)
        let submissionID = SubmissionID(rawValue: "sub_stdin")
        let task = rootTask("task_stdin", submissionID, "send input")
        try await log.append([
            .userMessage(UserMessagePayload(
                text: "send input",
                to: main,
                submissionID: submissionID)),
            .taskCreated(TaskCreatedPayload(contract: task)),
        ])
        let secret = "stdin-secret-never-persist-9e4f5a"
        let provider = ModelHistoryScriptedProvider([
            [
                .toolCalls([
                    ToolCall(
                        id: "call_stdin",
                        name: "write_stdin",
                        arguments: #"{"characters":"\#(secret)"}"#),
                ]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .textDelta("done"),
                .done(finishReason: "stop"),
            ],
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([ModelHistoryStdinTool()]),
            task: task)

        _ = try await loop.send(
            "send input",
            recordUserMessage: false,
            submissionID: submissionID)

        let replay = try await log.replayChecked()
        let historyCalls: [ModelHistoryFunctionCall] = replay.compactMap {
            envelope -> ModelHistoryFunctionCall? in
            guard case .modelHistoryItem(let payload) = envelope.event,
                  payload.kind == .functionCallBatch else {
                return nil
            }
            return payload.functionCalls?.first
        }
        let historyCall = try XCTUnwrap(historyCalls.first)
        XCTAssertEqual(
            historyCall.arguments,
            #"{"_intatis":"arguments_redacted"}"#)
        XCTAssertTrue(historyCall.argumentsRedacted)
        let auditCalls: [ToolCallPayload] = replay.compactMap {
            envelope -> ToolCallPayload? in
            guard case .toolCall(let payload) = envelope.event else {
                return nil
            }
            return payload
        }
        let auditCall = try XCTUnwrap(auditCalls.first)
        XCTAssertEqual(
            auditCall.args,
            #"{"_intatis":"arguments_redacted"}"#)
        XCTAssertEqual(auditCall.argsRedacted, true)
        XCTAssertFalse(
            try String(contentsOf: eventLogURL, encoding: .utf8)
                .contains(secret))
    }

    func testRepeatedProviderCallIDAcrossToolRoundsIsUniquedAndReplayable() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let log = try EventLog(
            session: SessionID(rawValue: "sess_model_history_repeat_call"),
            fileURL: workspace.appendingPathComponent("events.jsonl"))
        let firstID = SubmissionID(rawValue: "sub_repeat_call_first")
        let secondID = SubmissionID(rawValue: "sub_repeat_call_second")
        let firstTask = rootTask("task_repeat_call_first", firstID, "U1")
        let secondTask = rootTask("task_repeat_call_second", secondID, "U2")
        try await log.append([
            .userMessage(UserMessagePayload(
                text: "U1", to: main, submissionID: firstID)),
            .taskCreated(TaskCreatedPayload(contract: firstTask)),
        ])

        let firstProvider = ModelHistoryScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "call_0",
                    name: "read_probe",
                    arguments: #"{"path":"A"}"#)]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .toolCalls([ToolCall(
                    id: "call_0",
                    name: "read_probe",
                    arguments: #"{"path":"B"}"#)]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .textDelta("A1"),
                .done(finishReason: "stop"),
            ],
        ])
        let firstLoop = makeLoop(
            workspace: workspace,
            log: log,
            provider: firstProvider,
            registry: ToolRegistry([ModelHistoryProbeTool()]),
            task: firstTask)
        let firstResult = try await firstLoop.send(
            "U1",
            recordUserMessage: false,
            submissionID: firstID)
        XCTAssertEqual(firstResult, "A1")

        let replay = try await log.replayChecked()
        let callIDs = replay.compactMap { envelope -> String? in
            guard case .modelHistoryItem(let payload) = envelope.event,
                  payload.kind == .functionCallBatch else {
                return nil
            }
            return payload.functionCalls?.first?.callID
        }
        XCTAssertEqual(callIDs, ["call_0", "call_intatis_0"])

        try await log.append([
            .userMessage(UserMessagePayload(
                text: "U2", to: main, submissionID: secondID)),
            .taskCreated(TaskCreatedPayload(contract: secondTask)),
        ])
        let secondProvider = ModelHistoryScriptedProvider([
            [
                .textDelta("A2"),
                .done(finishReason: "stop"),
            ],
        ])
        let secondLoop = makeLoop(
            workspace: workspace,
            log: log,
            provider: secondProvider,
            registry: ToolRegistry([ModelHistoryProbeTool()]),
            task: secondTask)
        _ = try await secondLoop.send(
            "U2",
            recordUserMessage: false,
            submissionID: secondID)

        let request = try XCTUnwrap(secondProvider.requests.first)
        let messages = request.messages.filter {
            $0.role != .system
                && $0.content?.contains("<<<UNTRUSTED_CONTEXT_DATA>>>") != true
        }
        XCTAssertEqual(messages.count, 7)
        XCTAssertEqual(messages[1].toolCalls?.map(\.id), ["call_0"])
        XCTAssertEqual(messages[2], .tool(id: "call_0", content: "probe:A"))
        XCTAssertEqual(
            messages[3].toolCalls?.map(\.id),
            ["call_intatis_0"])
        XCTAssertEqual(
            messages[4],
            .tool(id: "call_intatis_0", content: "probe:B"))
        XCTAssertEqual(messages[5], .assistant("A1"))
        XCTAssertEqual(messages[6], .user("U2"))
    }

    func testUnknownOrGappedHistoryStopsBeforeProviderDispatch() async throws {
        let cases: [(label: String, seq: Int, unknownType: Bool)] = [
            ("unknown", 2, true),
            ("gap", 7, false),
        ]

        for testCase in cases {
            let workspace = try makeWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let session = SessionID(
                rawValue: "sess_model_history_\(testCase.label)")
            let eventLogURL = workspace.appendingPathComponent("events.jsonl")
            let log = try EventLog(session: session, fileURL: eventLogURL)
            let submissionID = SubmissionID(
                rawValue: "sub_history_\(testCase.label)")
            let task = rootTask(
                "task_history_\(testCase.label)",
                submissionID,
                "continue")
            try await log.append([
                .userMessage(UserMessagePayload(
                    text: "continue",
                    to: main,
                    submissionID: submissionID)),
                .taskCreated(TaskCreatedPayload(contract: task)),
            ])

            let encoder = Envelope.makeEncoder()
            var trailingEnvelope = try encoder.encode(Envelope(
                seq: testCase.seq,
                ts: Date(timeIntervalSince1970: TimeInterval(testCase.seq)),
                session: session,
                event: .userMessage(UserMessagePayload(text: "placeholder"))))
            if testCase.unknownType {
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: trailingEnvelope)
                        as? [String: Any])
                object["type"] = "future_model_history_event"
                object["payload"] = ["futureField": true]
                trailingEnvelope = try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys])
            }
            var bytes = try Data(contentsOf: eventLogURL)
            bytes.append(trailingEnvelope)
            bytes.append(0x0A)
            try bytes.write(to: eventLogURL)

            let provider = ModelHistoryScriptedProvider([
                [
                    .textDelta("must not run"),
                    .done(finishReason: "stop"),
                ],
            ])
            let loop = makeLoop(
                workspace: workspace,
                log: log,
                provider: provider,
                registry: ToolRegistry([ModelHistoryProbeTool()]),
                task: task)

            do {
                _ = try await loop.send(
                    "continue",
                    recordUserMessage: false,
                    submissionID: submissionID)
                XCTFail("\(testCase.label) history must fail closed")
            } catch let error as EventLogError {
                XCTAssertEqual(error, .unsupportedEventTypes)
            }
            XCTAssertTrue(provider.requests.isEmpty)
        }
    }

    private func makeLoop(
        workspace: URL,
        log: EventLog,
        provider: ToolCallingProvider,
        registry: ToolRegistry,
        task: TaskContract
    ) -> AgentLoop {
        AgentLoop(
            log: log,
            provider: provider,
            registry: registry,
            engine: PermissionEngine(),
            responder: FixedResponder(.allow),
            agent: Agent(
                name: main,
                workspaceRoot: workspace,
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
                conversationHistoryPolicy: .coworkMainThread),
            allowsShell: false,
            taskAttempt: 1)
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

    private func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-model-history-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        return workspace
    }
}
