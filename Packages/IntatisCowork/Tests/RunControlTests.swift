import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
@testable import IntatisCowork

private final class RunControlScriptedProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [[AgentChunk]]
    private var index = 0
    private var captured: [AgentRequest] = []

    init(_ responses: [[AgentChunk]]) {
        self.responses = responses
    }

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        captured.append(request)
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

private actor RunControlDelayedStreamState {
    private var phase = 0
    private let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func next() async throws -> AgentChunk? {
        switch phase {
        case 0:
            phase = 1
            try await Task.sleep(nanoseconds: delayNanoseconds)
            return .textDelta("late result")
        case 1:
            phase = 2
            return .done(finishReason: "stop")
        default:
            return nil
        }
    }
}

private final class RunControlDelayedProvider: ToolCallingProvider, @unchecked Sendable {
    private let delayNanoseconds: UInt64
    private let lock = NSLock()
    private var capturedRequestCount = 0

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequestCount
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        capturedRequestCount += 1
        lock.unlock()
        let state = RunControlDelayedStreamState(delayNanoseconds: delayNanoseconds)
        return AsyncThrowingStream(unfolding: { try await state.next() })
    }
}

final class RunControlTests: XCTestCase {
    private func fixture(
        provider: ToolCallingProvider,
        suffix: String,
        executionPolicy: CoworkExecutionPolicy = CoworkExecutionPolicy()
    ) async throws -> (Orchestrator, EventLog, URL, ContinuationRun) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-run-control-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let sessionID = SessionID(rawValue: "run-control-\(suffix)")
        let log = try EventLog(
            session: sessionID,
            fileURL: directory.appendingPathComponent("events.jsonl"))
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            executionPolicy: executionPolicy) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: Orchestrator.mainAgentID,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "test-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        let created = ContinuationRun(
            id: ContinuationRunID(rawValue: "run-\(suffix)"),
            sessionID: sessionID)
        let started = try created.transitioning(to: .running).get()
        try await log.append([
            .continuationRunCreated(.init(run: created)),
            .continuationRunStarted(.init(run: started)),
        ])
        return (orchestrator, log, directory, started)
    }

    private func waitForRunningTask(in log: EventLog) async throws -> TaskID {
        for _ in 0..<300 {
            if let taskID = CoworkProjection.build(from: await log.replay())
                .runningTasks.first?.id {
                return taskID
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw XCTSkip("root invocation did not reach running state")
    }

    func testFinishRunIsVisibleToExactMainRootAndClaimsBeforeTaskTerminal() async throws {
        let provider = RunControlScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "finish-current-run",
                    name: "finish_run",
                    arguments: #"{"reason":"verified deliverable"}"#)]),
                .done(finishReason: "tool_calls"),
            ],
            [.textDelta("verified result"), .done(finishReason: "stop")],
        ])
        let (orchestrator, log, directory, run) = try await fixture(
            provider: provider,
            suffix: "explicit")
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = await orchestrator.send(
            "complete the request",
            to: Orchestrator.mainAgentID,
            continuationRunID: run.id)

        XCTAssertEqual(result, .sent)
        let firstTools = Set(try XCTUnwrap(provider.requests.first).tools.map(\.name))
        XCTAssertTrue(firstTools.contains("finish_run"))
        XCTAssertTrue(firstTools.contains("stop_run"))
        let events = await log.replay()
        let close = try XCTUnwrap(events.first {
            if case .continuationRunCloseRequested = $0.event { return true }
            return false
        })
        let terminal = try XCTUnwrap(events.first {
            if case .taskCompleted = $0.event { return true }
            return false
        })
        XCTAssertLessThan(close.seq, terminal.seq)
        guard case .continuationRunCloseRequested(let claim) = close.event else {
            return XCTFail("expected run close claim")
        }
        XCTAssertEqual(claim.runID, run.id)
        XCTAssertEqual(claim.requestedOutcome, .completed)
        XCTAssertEqual(claim.source, .mainAgent)
        XCTAssertEqual(events.filter {
            if case .continuationRunCloseRequested = $0.event { return true }
            return false
        }.count, 1)
    }

    func testRootFinalResponseDoesNotForgeExplicitRunCloseClaim() async throws {
        let provider = RunControlScriptedProvider([
            [.textDelta("direct result"), .done(finishReason: "stop")],
        ])
        let (orchestrator, log, directory, run) = try await fixture(
            provider: provider,
            suffix: "implicit")
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = await orchestrator.send(
            "answer directly",
            to: Orchestrator.mainAgentID,
            continuationRunID: run.id)
        XCTAssertEqual(result, .sent)

        let claims = await log.replay().compactMap { envelope -> ContinuationRunCloseRequestedPayload? in
            guard case .continuationRunCloseRequested(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertTrue(claims.isEmpty)
    }

    func testStopRunCreatesStoppedClaimForExactCurrentRun() async throws {
        let provider = RunControlScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "stop-current-run",
                    name: "stop_run",
                    arguments: #"{"reason":"required authority is unavailable"}"#)]),
                .done(finishReason: "tool_calls"),
            ],
            [.textDelta("blocked by missing authority"), .done(finishReason: "stop")],
        ])
        let (orchestrator, log, directory, run) = try await fixture(
            provider: provider,
            suffix: "stopped")
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = await orchestrator.send(
            "stop when blocked",
            to: Orchestrator.mainAgentID,
            continuationRunID: run.id)

        XCTAssertEqual(result, .sent)
        let claims: [ContinuationRunCloseRequestedPayload] = await log.replay().compactMap { envelope in
            guard case .continuationRunCloseRequested(let payload) = envelope.event else {
                return nil
            }
            return payload
        }
        let claim = try XCTUnwrap(claims.first)
        XCTAssertEqual(claim.runID, run.id)
        XCTAssertEqual(claim.requestedOutcome, .stopped)
        XCTAssertEqual(claim.source, .mainAgent)
    }

    func testRootTimeoutInstallsRuntimeCloseFenceBeforeFailedTerminal() async throws {
        let provider = RunControlDelayedProvider(delayNanoseconds: 2_000_000_000)
        let (orchestrator, log, directory, run) = try await fixture(
            provider: provider,
            suffix: "timeout",
            executionPolicy: CoworkExecutionPolicy(taskTimeoutSeconds: 0.02))
        defer { try? FileManager.default.removeItem(at: directory) }

        guard case .failed(let message) = await orchestrator.send(
            "time out this exact run",
            to: Orchestrator.mainAgentID,
            continuationRunID: run.id) else {
            return XCTFail("root timeout must fail the invocation")
        }
        XCTAssertTrue(message.lowercased().contains("timed out"), message)
        XCTAssertEqual(provider.requestCount, 1)

        let events = await log.replay()
        let closeIndex = try XCTUnwrap(events.firstIndex {
            guard case .continuationRunCloseRequested(let payload) = $0.event else {
                return false
            }
            return payload.runID == run.id
                && payload.requestedOutcome == .timedOut
                && payload.source == .runtime
        })
        let failedIndex = try XCTUnwrap(events.firstIndex {
            if case .taskFailed = $0.event { return true }
            return false
        })
        XCTAssertLessThan(closeIndex, failedIndex)
    }

    func testRunningUserCancellationFencesRunBeforeCancelledTerminalAndPreservesSource() async throws {
        let provider = RunControlDelayedProvider(delayNanoseconds: 5_000_000_000)
        let (orchestrator, log, directory, run) = try await fixture(
            provider: provider,
            suffix: "user-cancel")
        defer { try? FileManager.default.removeItem(at: directory) }

        let send = Task {
            await orchestrator.send(
                "cancel this running root",
                to: Orchestrator.mainAgentID,
                continuationRunID: run.id)
        }
        let taskID = try await waitForRunningTask(in: log)
        let cancelled = await orchestrator.cancel(
            taskID: taskID,
            reason: "cancelled by user regression")
        XCTAssertTrue(cancelled)
        guard case .failed = await send.value else {
            return XCTFail("a cancelled root must not report success")
        }

        let events = await log.replay()
        let closeIndex = try XCTUnwrap(events.firstIndex {
            guard case .continuationRunCloseRequested(let payload) = $0.event else {
                return false
            }
            return payload.runID == run.id
                && payload.requestedOutcome == .cancelled
                && payload.source == .user
        })
        let cancelledIndex = try XCTUnwrap(events.firstIndex {
            guard case .taskCancelled(let payload) = $0.event else { return false }
            return payload.taskID == taskID
        })
        XCTAssertLessThan(closeIndex, cancelledIndex)
    }

    func testSessionShutdownPreservesHostLifecycleCloseSource() async throws {
        let provider = RunControlDelayedProvider(delayNanoseconds: 5_000_000_000)
        let (orchestrator, log, directory, run) = try await fixture(
            provider: provider,
            suffix: "host-shutdown")
        defer { try? FileManager.default.removeItem(at: directory) }

        let send = Task {
            await orchestrator.send(
                "remain active until host shutdown",
                to: Orchestrator.mainAgentID,
                continuationRunID: run.id)
        }
        _ = try await waitForRunningTask(in: log)
        await orchestrator.cancelAll(reason: "host lifecycle regression")
        guard case .failed = await send.value else {
            return XCTFail("host shutdown must cancel the root invocation")
        }

        let replayed = await log.replay()
        let claims: [ContinuationRunCloseRequestedPayload] = replayed.compactMap { envelope in
            guard case .continuationRunCloseRequested(let payload) = envelope.event,
                  payload.runID == run.id else { return nil }
            return payload
        }
        let claim = try XCTUnwrap(claims.first)
        XCTAssertEqual(claim.requestedOutcome, .interrupted)
        XCTAssertEqual(claim.source, .hostLifecycle)
    }

    func testRestoreDrainsQueuedTaskBehindDurableCloseFenceWithoutProviderDispatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-run-close-restore-\(UUID().uuidString)", isDirectory: true)
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = SessionID(rawValue: "run-close-restore")
        let runID = ContinuationRunID(rawValue: "run-close-restore")
        let taskID = TaskID(rawValue: "task-close-restore")
        let log = try EventLog(
            session: sessionID,
            fileURL: directory.appendingPathComponent("events.jsonl"))
        let workspaceLease = WorkspaceLease(
            taskID: taskID,
            rootPath: workspace.path,
            access: .readWrite)
        let capabilityLease = CapabilityLease.coordinator(taskID: taskID)
        let contract = TaskContract(
            id: taskID,
            kind: .root,
            issuer: nil,
            assignee: Orchestrator.mainAgentID,
            continuationRunID: runID,
            objective: "must remain closed after restart",
            roleHint: "root coordinator",
            expectedDeliverable: "no provider dispatch",
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            replyMode: TaskReplyMode.none,
            maxAttempts: 3)
        let metadata = CoworkEventMetadata(
            taskID: taskID,
            rootTaskID: taskID,
            agentID: Orchestrator.mainAgentID,
            assignee: Orchestrator.mainAgentID,
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            scope: .task)
        try await log.append([
            .agentAttached(.init(
                agent: Orchestrator.mainAgentID,
                path: workspace.path,
                model: ModelID(rawValue: "test-model"),
                profile: PermissionProfile.reviewed.rawValue)),
            .workspaceLeaseGranted(.init(
                agent: Orchestrator.mainAgentID,
                lease: workspaceLease)),
            .capabilityLeaseCreated(.init(
                agent: Orchestrator.mainAgentID,
                lease: capabilityLease)),
            .taskCreated(.init(contract: contract, metadata: metadata)),
            .taskAssigned(.init(contract: contract, metadata: metadata)),
            .taskQueued(.init(
                contract: contract,
                rootTaskID: taskID,
                assignee: Orchestrator.mainAgentID,
                hopCount: 0,
                visitedAgents: [Orchestrator.mainAgentID],
                attempt: 1,
                metadata: metadata)),
        ])
        _ = try await log.claimContinuationRunClose(.init(
            sessionID: sessionID,
            runID: runID,
            rootTaskID: taskID,
            requestedOutcome: .completed,
            source: .mainAgent,
            reason: "already verified"))

        let provider = RunControlScriptedProvider([
            [.textDelta("must not run"), .done(finishReason: "stop")],
        ])
        let restored = Orchestrator(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.allow)) { _ in provider }
        await restored.restore(from: CoworkProjection.build(from: await log.replay()))
        _ = await restored.resumePendingTasks()
        await restored.runSchedulerUntilIdle()

        XCTAssertTrue(provider.requests.isEmpty)
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(projection.tasks[taskID]?.status, .cancelled)
        XCTAssertEqual(projection.continuationRunCloseClaims.count, 1)
    }
}
