import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
@testable import IntatisTools
import IntatisPermission
import IntatisConversation
@testable import IntatisAgentKernel

private final class SandboxDenialScriptedProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [[AgentChunk]]
    private var responseIndex = 0

    init(_ responses: [[AgentChunk]]) {
        self.responses = responses
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return responseIndex
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        let chunks = responses[min(responseIndex, responses.count - 1)]
        responseIndex += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

private actor SandboxDeniedToolProbe {
    private var executions = 0

    func recordExecution() {
        executions += 1
    }

    func executionCount() -> Int {
        executions
    }
}

private struct SandboxDeniedTestTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "sandbox_denied_test",
        description: "Test-only managed process whose sandbox wrapper rejects startup.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ]))

    let probe: SandboxDeniedToolProbe

    func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        await probe.recordExecution()
        throw WorkspaceSandboxDeniedError(
            reason: "macOS workspace sandbox denied process startup")
    }
}

final class SandboxDenialOutcomeTests: XCTestCase {
    func testSandboxStartupDenialIsTypedNotStartedAndIsNotRetried() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-agent-sandbox-denial-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let log = try EventLog(
            session: SessionID(rawValue: "agent_sandbox_denial"),
            fileURL: workspace.appendingPathComponent("events.jsonl"))
        let provider = SandboxDenialScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "sandbox-denied-call",
                    name: "sandbox_denied_test",
                    arguments: "{}")]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .toolCalls([ToolCall(
                    id: "sandbox-denied-retry",
                    name: "sandbox_denied_test",
                    arguments: "{}")]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .textDelta("Recovered without rerunning the tool."),
                .done(finishReason: "stop"),
            ],
        ])
        let probe = SandboxDeniedToolProbe()
        let loop = AgentLoop(
            log: log,
            provider: provider,
            registry: ToolRegistry([SandboxDeniedTestTool(probe: probe)]),
            engine: PermissionEngine(),
            responder: FixedResponder(.deny),
            agent: Agent(
                name: AgentID(rawValue: "sandbox-denial-agent"),
                workspaceRoot: workspace,
                model: ModelID(rawValue: "test-model"),
                profile: .reviewed),
            allowsShell: false,
            maxIterations: 4)

        let answer = try await loop.send("Run the managed sandbox test tool once.")

        XCTAssertEqual(answer, "Recovered without rerunning the tool.")
        let executionCount = await probe.executionCount()
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(provider.requestCount, 3)

        let events = await log.replay()
        let results = events.compactMap { envelope -> ToolResultPayload? in
            guard case .toolResult(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(results.count, 2)
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.toolCallId, "sandbox-denied-call")
        XCTAssertEqual(result.outcome, .denied)
        XCTAssertEqual(result.failureSource, .sandboxDenied)
        XCTAssertNotNil(result.turnID)
        XCTAssertEqual(
            result.observation,
            "sandbox denied tool execution: macOS workspace sandbox denied process startup")
        XCTAssertEqual(results.last?.toolCallId, "sandbox-denied-retry")
        XCTAssertEqual(results.last?.outcome, .denied)
        XCTAssertEqual(results.last?.failureSource, .policyDenied)
        XCTAssertEqual(
            results.last?.observation,
            "permission denied: identical tool call was already denied in this agent run")

        let settlements = events.compactMap { envelope -> ToolExecutionSettledPayload? in
            guard case .toolExecutionSettled(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(settlements.count, 1)
        let settlement = try XCTUnwrap(settlements.first)
        XCTAssertEqual(settlement.toolCallID, "sandbox-denied-call")
        XCTAssertEqual(settlement.outcome, .denied)
        XCTAssertEqual(settlement.effectDisposition, .notStarted)

        XCTAssertFalse(events.contains { envelope in
            if case .permissionRequest = envelope.event { return true }
            return false
        })
        let outcomes = events.compactMap { envelope -> TurnOutcomePayload? in
            guard case .turnOutcome(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(outcomes.map(\.outcome), [.completed])
    }
}
