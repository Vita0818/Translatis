import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
@testable import IntatisAgentKernel

private struct OutcomeProvider: ToolCallingProvider {
    let chunks: [AgentChunk]

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

private struct CancelledOutcomeProvider: ToolCallingProvider {
    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: CancellationError())
        }
    }
}

private actor SuspendedApprovalResponder: PermissionResponder {
    private var approvalContinuation: CheckedContinuation<PermissionDecision, Never>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var didReceiveRequest = false

    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            didReceiveRequest = true
            let waiters = requestWaiters
            requestWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilRequested() async {
        if didReceiveRequest { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func resolve(_ decision: PermissionDecision) {
        let continuation = approvalContinuation
        approvalContinuation = nil
        continuation?.resume(returning: decision)
    }
}

private struct CancelTurnOutcomeResponder: PermissionResponder {
    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        .deny
    }

    func requestResolution(
        _ request: PermissionRequestPayload
    ) async -> PermissionApprovalResolution {
        PermissionApprovalResolution(
            decision: .deny,
            action: .cancelTurn,
            reason: "Turn cancelled by user",
            risk: request.risk,
            source: .user,
            failureSource: .userCancelled)
    }
}

final class AgentLoopOutcomeTests: XCTestCase {
    private func makeLoop(provider: ToolCallingProvider,
                          maxIterations: Int = 50,
                          registry: ToolRegistry = ToolRegistry([]),
                          responder: PermissionResponder = FixedResponder(.deny)) throws -> (AgentLoop, EventLog, URL) {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-agent-outcome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let log = try EventLog(
            session: SessionID(rawValue: "agent_outcome"),
            fileURL: workspace.appendingPathComponent("events.jsonl"))
        let loop = AgentLoop(
            log: log,
            provider: provider,
            registry: registry,
            engine: PermissionEngine(),
            responder: responder,
            agent: Agent(
                name: AgentID(rawValue: "outcome-agent"),
                workspaceRoot: workspace,
                model: ModelID(rawValue: "test-model"),
                profile: .reviewed),
            allowsShell: false,
            maxIterations: maxIterations)
        return (loop, log, workspace)
    }

    private func errorPayloads(in log: EventLog) async -> [ErrorPayload] {
        await log.replay().compactMap { envelope in
            guard case .error(let payload) = envelope.event else { return nil }
            return payload
        }
    }

    func testMaxIterationsThrowsRecognizableErrorAndLogsItOnce() async throws {
        let provider = OutcomeProvider(chunks: [
            .toolCalls([ToolCall(id: "call-1", name: "missing_tool", arguments: "{}")]),
            .done(finishReason: "tool_calls"),
        ])
        let (loop, log, workspace) = try makeLoop(provider: provider, maxIterations: 1)
        defer { try? FileManager.default.removeItem(at: workspace) }

        do {
            _ = try await loop.send("Keep using a tool.")
            XCTFail("Expected max-iteration exhaustion to throw instead of returning success.")
        } catch let error as AgentLoopError {
            XCTAssertEqual(error, .maxIterationsExceeded(limit: 1))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let errors = await errorPayloads(in: log)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.code, "max_iterations")
        XCTAssertTrue(errors.first?.message.contains("maximum of 1 tool iterations") == true)
    }

    func testProviderSelfCancellationIsRuntimeFailureNotTurnCancellation() async throws {
        let (loop, log, workspace) = try makeLoop(provider: CancelledOutcomeProvider())
        defer { try? FileManager.default.removeItem(at: workspace) }

        do {
            _ = try await loop.send("Cancel this request.")
            XCTFail("Expected provider cancellation to propagate.")
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        }

        let errors = await errorPayloads(in: log)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.code, "runtime_failed")
        let outcomes = await log.replay().compactMap { envelope -> TurnOutcomePayload? in
            if case .turnOutcome(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(outcomes.map(\.outcome), [.failed])
        XCTAssertEqual(outcomes.first?.failureSource, .runtimeFailed)
    }

    func testExplicitCompletionWithoutToolCallsReturnsFinalText() async throws {
        let provider = OutcomeProvider(chunks: [
            .textDelta("Finished."),
            .done(finishReason: "stop"),
        ])
        let (loop, log, workspace) = try makeLoop(provider: provider)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let result = try await loop.send("Complete normally.")

        XCTAssertEqual(result, "Finished.")
        let errors = await errorPayloads(in: log)
        XCTAssertTrue(errors.isEmpty)
        let completed = await log.replay().compactMap { envelope -> MessageCompletedPayload? in
            guard case .messageCompleted(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.text, "Finished.")
        let outcomes = await log.replay().compactMap { envelope -> TurnOutcomePayload? in
            if case .turnOutcome(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(outcomes.map(\.outcome), [.completed])
    }

    func testHostControlInputCanSkipUserMessageRecording() async throws {
        let provider = OutcomeProvider(chunks: [
            .textDelta("Control-plane result."),
            .done(finishReason: "stop"),
        ])
        let (loop, log, workspace) = try makeLoop(provider: provider)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let result = try await loop.send(
            "Internal continuation input.",
            recordUserMessage: false)

        XCTAssertEqual(result, "Control-plane result.")
        let events = await log.replay()
        XCTAssertFalse(events.contains {
            if case .userMessage = $0.event { return true }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .messageCompleted = $0.event { return true }
            return false
        })
    }

    func testStreamWithoutCompletionMarkerThrowsAndKeepsPartialMessageIncomplete() async throws {
        let provider = OutcomeProvider(chunks: [.textDelta("partial")])
        let (loop, log, workspace) = try makeLoop(provider: provider)
        defer { try? FileManager.default.removeItem(at: workspace) }

        do {
            _ = try await loop.send("Require an explicit terminal marker.")
            XCTFail("Expected an incomplete stream to throw.")
        } catch let error as AgentLoopError {
            XCTAssertEqual(error, .responseEndedWithoutCompletionMarker)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = await log.replay()
        XCTAssertTrue(events.contains { if case .messageDelta = $0.event { return true } else { return false } })
        XCTAssertFalse(events.contains { if case .messageCompleted = $0.event { return true } else { return false } })
        let errors = await errorPayloads(in: log)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.code, "incomplete_completion")
    }

    func testLengthFinishReasonFailsInsteadOfCompletingPartialAnswer() async throws {
        let provider = OutcomeProvider(chunks: [
            .textDelta("partial answer"),
            .done(finishReason: "length"),
        ])
        let (loop, log, workspace) = try makeLoop(provider: provider)
        defer { try? FileManager.default.removeItem(at: workspace) }

        do {
            _ = try await loop.send("Do not accept truncation as success.")
            XCTFail("Expected a length-truncated response to fail.")
        } catch let error as AgentLoopError {
            XCTAssertEqual(error, .incompleteFinishReason("length"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = await log.replay()
        XCTAssertFalse(events.contains { if case .messageCompleted = $0.event { return true } else { return false } })
        let errors = await errorPayloads(in: log)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.code, "incomplete_response")
    }

    func testUnknownFinishReasonFailsClosedInsteadOfCompletingPartialAnswer() async throws {
        let provider = OutcomeProvider(chunks: [
            .textDelta("partial answer"),
            .done(finishReason: "server_error"),
        ])
        let (loop, log, workspace) = try makeLoop(provider: provider)
        defer { try? FileManager.default.removeItem(at: workspace) }

        do {
            _ = try await loop.send("Unknown terminal reasons must not complete the task.")
            XCTFail("Expected an unknown finish reason to fail closed.")
        } catch let error as AgentLoopError {
            XCTAssertEqual(error, .incompleteFinishReason("server_error"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = await log.replay()
        XCTAssertFalse(events.contains { if case .messageCompleted = $0.event { return true } else { return false } })
        let errors = await errorPayloads(in: log)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.code, "incomplete_response")
    }

    func testNilAndKnownNonToolSuccessFinishReasonsComplete() async throws {
        let finishReasons: [String?] = [nil, "stop", "end_turn", "completed", "complete"]
        var workspaces: [URL] = []
        defer {
            for workspace in workspaces {
                try? FileManager.default.removeItem(at: workspace)
            }
        }

        for finishReason in finishReasons {
            let provider = OutcomeProvider(chunks: [
                .textDelta("Finished."),
                .done(finishReason: finishReason),
            ])
            let (loop, log, workspace) = try makeLoop(provider: provider)
            workspaces.append(workspace)

            let result = try await loop.send("Accept a supported completion marker.")

            XCTAssertEqual(result, "Finished.", "finish reason: \(finishReason ?? "nil")")
            let errors = await errorPayloads(in: log)
            XCTAssertTrue(errors.isEmpty, "finish reason: \(finishReason ?? "nil")")
        }
    }

    func testCancellationInterruptsSuspendedApprovalAndNeverExecutesAllowedWrite() async throws {
        let responder = SuspendedApprovalResponder()
        let provider = OutcomeProvider(chunks: [
            .toolCalls([ToolCall(
                id: "write-after-cancel",
                name: "write_file",
                arguments: #"{"path":"cancelled.txt","content":"must not be written"}"#)]),
            .done(finishReason: "tool_calls"),
        ])
        let (loop, log, workspace) = try makeLoop(
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            responder: responder)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let loopTask = Task {
            try await loop.send("Request a write, then wait for approval.")
        }
        await responder.waitUntilRequested()
        loopTask.cancel()

        let completed = expectation(description: "cancelled permission wait exits")
        let observer = Task {
            defer { completed.fulfill() }
            do {
                _ = try await loopTask.value
                XCTFail("Expected cancellation to propagate from the permission wait.")
            } catch {
                XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
            }
        }
        await fulfillment(of: [completed], timeout: 1)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("cancelled.txt").path))
        let events = await log.replay()
        let resolutions = events.compactMap { envelope -> PermissionResolvedPayload? in
            guard case .permissionResolved(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(resolutions.last?.decision, .deny)
        XCTAssertEqual(resolutions.last?.reason, "permission request cancelled")
        XCTAssertEqual(resolutions.last?.failureSource, .turnCancelled)
        XCTAssertFalse(events.contains { if case .toolResult = $0.event { return true } else { return false } })
        let outcomes = events.compactMap { envelope -> TurnOutcomePayload? in
            if case .turnOutcome(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(outcomes.map(\.outcome), [.interrupted])
        XCTAssertEqual(outcomes.first?.failureSource, .turnCancelled)
        let cancellationErrors = await errorPayloads(in: log)
        XCTAssertTrue(cancellationErrors.isEmpty)

        // Release the deliberately non-cooperative responder after verifying the
        // AgentLoop no longer depends on it. A late allow must remain ineffectual.
        await responder.resolve(.allow)
        await observer.value
        await Task.yield()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("cancelled.txt").path))
    }

    func testExplicitCancelTurnInterruptsWithoutDeniedToolResult() async throws {
        let provider = OutcomeProvider(chunks: [
            .toolCalls([ToolCall(
                id: "cancel-turn-call",
                name: "write_file",
                arguments: #"{"path":"must-not-exist.txt","content":"no"}"#)]),
            .done(finishReason: "tool_calls"),
        ])
        let (loop, log, workspace) = try makeLoop(
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            responder: CancelTurnOutcomeResponder())
        defer { try? FileManager.default.removeItem(at: workspace) }

        do {
            _ = try await loop.send("Request a write then cancel the turn.")
            XCTFail("Cancel Turn must interrupt the enclosing turn.")
        } catch let error as AgentTurnInterruptedError {
            XCTAssertEqual(error.failureSource, .userCancelled)
        } catch {
            XCTFail("Expected AgentTurnInterruptedError, got \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("must-not-exist.txt").path))
        let events = await log.replay()
        XCTAssertFalse(events.contains {
            if case .toolResult = $0.event { return true }
            return false
        })
        let resolution = try XCTUnwrap(events.compactMap { envelope -> PermissionResolvedPayload? in
            if case .permissionResolved(let payload) = envelope.event { return payload }
            return nil
        }.last)
        XCTAssertEqual(resolution.action, .cancelTurn)
        XCTAssertEqual(resolution.failureSource, .userCancelled)
        let outcome = try XCTUnwrap(events.compactMap { envelope -> TurnOutcomePayload? in
            if case .turnOutcome(let payload) = envelope.event { return payload }
            return nil
        }.last)
        XCTAssertEqual(outcome.outcome, .interrupted)
        XCTAssertEqual(outcome.failureSource, .userCancelled)
        let cancellationErrors = await errorPayloads(in: log)
        XCTAssertTrue(cancellationErrors.isEmpty)
    }
}
