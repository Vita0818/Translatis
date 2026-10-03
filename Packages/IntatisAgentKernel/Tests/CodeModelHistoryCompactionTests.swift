import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
@testable import IntatisAgentKernel

private final class CodeCompactionScriptedProvider:
    ToolCallingProvider, @unchecked Sendable
{
    private let lock = NSLock()
    private let responses: [[AgentChunk]]
    private var responseIndex = 0
    private var capturedRequests: [AgentRequest] = []

    init(_ responses: [[AgentChunk]]) {
        precondition(!responses.isEmpty)
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

final class CodeModelHistoryCompactionTests: XCTestCase {
    private let coder = AgentID(rawValue: "Coder")

    func testCodeUsesDurableReplacementCheckpointAndResumesItsSuffix()
        async throws
    {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-code-compaction-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let log = try EventLog(
            session: SessionID(rawValue: "sess_code_compaction"),
            fileURL: workspace.appendingPathComponent("events.jsonl"))

        let firstUser =
            "FIRST USER " + String(repeating: "old-context-", count: 700)
        let firstProvider = CodeCompactionScriptedProvider([[
            .textDelta("FIRST FINAL"),
            .done(finishReason: "stop"),
        ]])
        let first = makeLoop(
            workspace: workspace,
            log: log,
            provider: firstProvider)
        let firstAnswer = try await first.send(firstUser)
        XCTAssertEqual(firstAnswer, "FIRST FINAL")

        var events = try await log.replayForProjectionChecked().envelopes
        let firstSubmission = try XCTUnwrap(events.compactMap {
            envelope -> SubmissionID? in
            guard case .userMessage(let payload) = envelope.event,
                  payload.text == firstUser else {
                return nil
            }
            return payload.submissionID
        }.first)
        let firstItems = events.compactMap {
            envelope -> ModelHistoryItemPayload? in
            guard case .modelHistoryItem(let payload) = envelope.event,
                  payload.submissionID == firstSubmission else {
                return nil
            }
            return payload
        }
        XCTAssertEqual(firstItems.count, 2)
        XCTAssertTrue(firstItems.allSatisfy { $0.taskID == nil })

        let secondProvider = CodeCompactionScriptedProvider([
            [
                .textDelta("CODE SUMMARY"),
                .done(finishReason: "stop"),
            ],
            [
                .textDelta("SECOND FINAL"),
                .done(finishReason: "stop"),
            ],
        ])
        let second = makeLoop(
            workspace: workspace,
            log: log,
            provider: secondProvider,
            modelContextPolicy:
                AgentModelContextPolicy(autoCompactTokenLimit: 1))
        let secondAnswer = try await second.send("SECOND USER")
        XCTAssertEqual(secondAnswer, "SECOND FINAL")
        XCTAssertEqual(secondProvider.requests.count, 2)
        XCTAssertFalse(secondProvider.requests[0].messages.contains {
            $0.content == "SECOND USER"
        })
        XCTAssertTrue(secondProvider.requests[1].messages.contains {
            $0.content == "SECOND USER"
        })
        XCTAssertTrue(secondProvider.requests[1].messages.contains {
            $0.content?.contains("CODE SUMMARY") == true
        })

        events = try await log.replayForProjectionChecked().envelopes
        let checkpoint = try XCTUnwrap(events.first {
            if case .modelHistoryCompacted = $0.event {
                return true
            }
            return false
        })
        let secondUserItem = try XCTUnwrap(events.first {
            guard case .modelHistoryItem(let payload) = $0.event else {
                return false
            }
            return payload.content == "SECOND USER"
                && payload.messageClassification == .realUser
        })
        XCTAssertLessThan(checkpoint.seq, secondUserItem.seq)

        let thirdProvider = CodeCompactionScriptedProvider([[
            .textDelta("THIRD FINAL"),
            .done(finishReason: "stop"),
        ]])
        let third = makeLoop(
            workspace: workspace,
            log: log,
            provider: thirdProvider)
        let thirdAnswer = try await third.send("THIRD USER")
        XCTAssertEqual(thirdAnswer, "THIRD FINAL")
        XCTAssertEqual(thirdProvider.requests.count, 1)
        let resumed = thirdProvider.requests[0].messages
        XCTAssertTrue(resumed.contains {
            $0.content?.contains("CODE SUMMARY") == true
        })
        XCTAssertTrue(resumed.contains {
            $0.role == .user && $0.content == "SECOND USER"
        })
        XCTAssertTrue(resumed.contains {
            $0.role == .assistant && $0.content == "SECOND FINAL"
        })
        XCTAssertTrue(resumed.contains {
            $0.role == .user && $0.content == "THIRD USER"
        })
    }

    private func makeLoop(
        workspace: URL,
        log: EventLog,
        provider: ToolCallingProvider,
        modelContextPolicy: AgentModelContextPolicy = .unspecified
    ) -> AgentLoop {
        AgentRuntime.code(
            registry: ToolRegistry([]),
            allowsShell: false,
            modelContextPolicy: modelContextPolicy)
            .makeLoop(
                log: log,
                provider: provider,
                responder: FixedResponder(.allow),
                agent: Agent(
                    name: coder,
                    workspaceRoot: workspace,
                    model: ModelID(rawValue: "test-model"),
                    profile: .reviewed),
                context: ContextBuilder(
                    systemPrompt: "system",
                    runtimeEnvironment: .code))
    }
}
