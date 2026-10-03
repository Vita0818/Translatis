import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
@testable import IntatisAgentKernel

private final class TerminalLoopProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [[AgentChunk]]
    private var index = 0

    init(_ responses: [[AgentChunk]]) {
        self.responses = responses
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        let response = responses[min(index, responses.count - 1)]
        index += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in response {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

private actor RecordingTerminalManager: TerminalSessionManaging {
    private var inputs: [String] = []

    func execute(_ request: TerminalExecRequest,
                 owner: TerminalSessionOwner,
                 workspaceLease: WorkspaceLease) async throws -> TerminalSessionObservation {
        TerminalSessionObservation(
            sessionID: "terminal_test_session",
            isRunning: true,
            stdout: "ready",
            stderr: "",
            exitCode: nil)
    }

    func interact(sessionID: String,
                  request: TerminalInteractionRequest,
                  owner: TerminalSessionOwner) async throws -> TerminalSessionObservation {
        if let characters = request.characters {
            inputs.append(characters)
        }
        return TerminalSessionObservation(
            sessionID: nil,
            isRunning: false,
            stdout: "accepted low-entropy-code-123456",
            stderr: "",
            exitCode: 0)
    }

    func terminate(taskID: TaskID, reason: String) async {}
    func terminateAll(reason: String) async {}
    func shutdown(reason: String) async {}

    func capturedInputs() -> [String] {
        inputs
    }
}

final class TerminalAgentLoopTests: XCTestCase {
    func testTerminalCallsUseDurablePipelineWithoutPersistingStdinBytes() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-terminal-loop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let log = try EventLog(
            session: SessionID(rawValue: "terminal_loop"),
            fileURL: workspace.appendingPathComponent("events.jsonl"))
        let secretInput = "low-entropy-code-123456"
        let provider = TerminalLoopProvider([
            [
                .toolCalls([ToolCall(
                    id: "exec-1",
                    name: "exec_command",
                    arguments: #"{"command":"read value","yield-time_ms":250}"#)]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .toolCalls([ToolCall(
                    id: "stdin-1",
                    name: "write_stdin",
                    arguments: #"{"session_id":"terminal_test_session","chars":"low-entropy-code-123456\n","yield-time_ms":1000}"#)]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .textDelta("Terminal interaction completed."),
                .done(finishReason: "stop"),
            ],
        ])
        let terminal = RecordingTerminalManager()
        let loop = AgentLoop(
            log: log,
            provider: provider,
            registry: .standard(includesTerminal: true),
            engine: PermissionEngine(),
            responder: FixedResponder(.allow),
            agent: Agent(
                name: AgentID(rawValue: "terminal-agent"),
                workspaceRoot: workspace,
                model: ModelID(rawValue: "test-model"),
                profile: .reviewed),
            allowsShell: true,
            terminal: terminal,
            maxIterations: 4)

        let answer = try await loop.send("Run an interactive terminal command.")

        let events = await log.replay()
        let debugEvents = String(
            decoding: try JSONEncoder().encode(events),
            as: UTF8.self)
        XCTAssertEqual(answer, "Terminal interaction completed.")
        let capturedInputs = await terminal.capturedInputs()
        XCTAssertEqual(capturedInputs, [secretInput + "\n"], debugEvents)

        let stdinCall = try XCTUnwrap(events.compactMap { envelope -> ToolCallPayload? in
            guard case .toolCall(let payload) = envelope.event,
                  payload.toolCallId == "stdin-1" else { return nil }
            return payload
        }.first)
        XCTAssertEqual(stdinCall.argsRedacted, true)
        XCTAssertFalse(stdinCall.args.contains(secretInput))

        let encoded = try JSONEncoder().encode(events)
        let durableText = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(durableText.contains(secretInput), durableText)

        let settlements = events.compactMap { envelope -> ToolExecutionSettledPayload? in
            guard case .toolExecutionSettled(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(settlements.count, 2)
        XCTAssertTrue(settlements.allSatisfy {
            $0.outcome == .succeeded && $0.effectDisposition == .committed
        })
        let stdinResult = try XCTUnwrap(events.compactMap { envelope -> ToolResultPayload? in
            guard case .toolResult(let payload) = envelope.event,
                  payload.toolCallId == "stdin-1" else { return nil }
            return payload
        }.first)
        XCTAssertTrue(stdinResult.observation.contains("interactive input echo redacted"))
        XCTAssertEqual(stdinResult.truncated, true)
    }
}
