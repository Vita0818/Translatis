import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
import IntatisTools
@testable import IntatisCowork

private actor ReliabilityConcurrencyProbe {
    private var active = 0
    private var activeByAgent: [AgentID: Int] = [:]
    private var maximumActive = 0
    private var maximumByAgent: [AgentID: Int] = [:]

    func begin(_ agent: AgentID) {
        active += 1
        activeByAgent[agent, default: 0] += 1
        maximumActive = max(maximumActive, active)
        maximumByAgent[agent] = max(maximumByAgent[agent] ?? 0, activeByAgent[agent] ?? 0)
    }

    func end(_ agent: AgentID) {
        active = max(0, active - 1)
        activeByAgent[agent] = max(0, (activeByAgent[agent] ?? 0) - 1)
    }

    func snapshot() -> (maximumActive: Int, maximumByAgent: [AgentID: Int]) {
        (maximumActive, maximumByAgent)
    }
}

private actor ReliabilityTaskStartGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor ReliabilityForwardingGate: ForwardingReviewer {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func review(from: AgentID, to: AgentID, content: String) async -> ForwardingDecision {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
        return .forward(content)
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private enum ReliabilityForcedError: Error, LocalizedError {
    case providerFailure
    case terminalPersistenceFailure

    var errorDescription: String? {
        switch self {
        case .providerFailure: return "forced provider failure"
        case .terminalPersistenceFailure: return "forced terminal persistence failure"
        }
    }
}

private actor ReliabilityOneShotRevocationFailure {
    private var hasFailed = false

    func append(_ events: [Event], to log: EventLog) async throws {
        if !hasFailed, events.contains(where: { event in
            if case .capabilityLeaseRevoked = event { return true }
            if case .workspaceLeaseRevoked = event { return true }
            return false
        }) {
            hasFailed = true
            throw ReliabilityForcedError.terminalPersistenceFailure
        }
        try await log.append(events)
    }
}

private actor ReliabilityCancellationPersistenceGate {
    private var rejectsCancellation = true

    func append(_ event: Event, to log: EventLog) async throws {
        if rejectsCancellation, case .taskCancelled = event {
            throw ReliabilityForcedError.terminalPersistenceFailure
        }
        _ = try await log.append(event)
    }

    func allowCancellation() {
        rejectsCancellation = false
    }
}

private final class ReliabilityFailingProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequestCount = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequestCount
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        capturedRequestCount += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: ReliabilityForcedError.providerFailure)
        }
    }
}

private final class ReliabilityThreeFailuresThenSuccessProvider:
    ToolCallingProvider, @unchecked Sendable
{
    private let lock = NSLock()
    private var capturedRequestCount = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequestCount
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        capturedRequestCount += 1
        let requestNumber = capturedRequestCount
        lock.unlock()
        return AsyncThrowingStream { continuation in
            if requestNumber <= 3 {
                continuation.finish(throwing: ReliabilityForcedError.providerFailure)
            } else {
                continuation.yield(.textDelta("completed after poison delivery"))
                continuation.yield(.done(finishReason: "stop"))
                continuation.finish()
            }
        }
    }
}

private struct ReliabilitySelfCancellingProvider: ToolCallingProvider {
    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: CancellationError())
        }
    }
}

private final class ReliabilityWriteThenFinalProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequestCount = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequestCount
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        capturedRequestCount += 1
        let requestNumber = capturedRequestCount
        lock.unlock()
        return AsyncThrowingStream { continuation in
            if requestNumber == 1 {
                continuation.yield(.toolCalls([ToolCall(
                    id: "phase-c-cancel-all-write",
                    name: "write_file",
                    arguments: #"{"__intatis_authorization_context":"The user requested the exact bounded phase-c.txt write, and this call is the next required step.","content":"must not run","path":"phase-c.txt"}"#)]))
                continuation.yield(.done(finishReason: "tool_calls"))
            } else {
                continuation.yield(.textDelta("continued after reviewer shutdown"))
                continuation.yield(.done(finishReason: "stop"))
            }
            continuation.finish()
        }
    }
}

private final class ReliabilityMailboxSideEffectThenFailProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequestCount = 0
    private var capturedOriginalMailboxRequestCount = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequestCount
    }

    var originalMailboxRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return capturedOriginalMailboxRequestCount
    }

    private static func frozenMessageID(in request: AgentRequest) -> String? {
        let markers = [
            "Message ID:\n| ",
            "Process only these frozen mailbox Message IDs: ",
        ]
        for message in request.messages {
            guard let content = message.content else { continue }
            for marker in markers {
                guard let markerRange = content.range(of: marker) else { continue }
                let suffix = content[markerRange.upperBound...]
                let value = suffix.prefix {
                    !$0.isWhitespace && $0 != "," && $0 != "."
                }
                if !value.isEmpty {
                    return String(value)
                }
            }
        }
        return nil
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        let isOriginalMailboxRequest = request.messages.contains {
            $0.content?.contains("handle once") == true
        }
        let hasOriginalToolCall = request.messages.contains {
            $0.toolCalls?.contains(where: { $0.id == "mailbox-reply-side-effect" }) == true
        }
        let frozenMessageID = Self.frozenMessageID(in: request)
        lock.lock()
        capturedRequestCount += 1
        if isOriginalMailboxRequest {
            capturedOriginalMailboxRequestCount += 1
        }
        lock.unlock()
        return AsyncThrowingStream { continuation in
            if isOriginalMailboxRequest, !hasOriginalToolCall, let frozenMessageID {
                let arguments = #"{"to":"main","content":"already attempted","inReplyTo":"\#(frozenMessageID)"}"#
                continuation.yield(.toolCalls([ToolCall(
                    id: "mailbox-reply-side-effect",
                    name: "reply_message",
                    arguments: arguments)]))
                continuation.yield(.done(finishReason: "tool_calls"))
                continuation.finish()
            } else if isOriginalMailboxRequest {
                continuation.finish(throwing: ReliabilityForcedError.providerFailure)
            } else {
                continuation.yield(.textDelta("unrelated mailbox completed"))
                continuation.yield(.done(finishReason: "stop"))
                continuation.finish()
            }
        }
    }
}

private actor ReliabilityDelayedStreamState {
    private var phase = 0
    private let agent: AgentID
    private let delayNanoseconds: UInt64
    private let response: String
    private let probe: ReliabilityConcurrencyProbe

    init(agent: AgentID,
         delayNanoseconds: UInt64,
         response: String,
         probe: ReliabilityConcurrencyProbe) {
        self.agent = agent
        self.delayNanoseconds = delayNanoseconds
        self.response = response
        self.probe = probe
    }

    func next() async throws -> AgentChunk? {
        switch phase {
        case 0:
            phase = 1
            await probe.begin(agent)
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                phase = 3
                await probe.end(agent)
                throw error
            }
            return .textDelta(response)
        case 1:
            phase = 2
            await probe.end(agent)
            return .done(finishReason: "stop")
        default:
            return nil
        }
    }
}

private final class ReliabilityDelayedProvider: ToolCallingProvider, @unchecked Sendable {
    private let agent: AgentID
    private let delayNanoseconds: UInt64
    private let response: String
    private let probe: ReliabilityConcurrencyProbe
    private let lock = NSLock()
    private var capturedRequestCount = 0

    init(agent: AgentID,
         delayNanoseconds: UInt64,
         response: String = "done",
         probe: ReliabilityConcurrencyProbe) {
        self.agent = agent
        self.delayNanoseconds = delayNanoseconds
        self.response = response
        self.probe = probe
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
        let state = ReliabilityDelayedStreamState(
            agent: agent,
            delayNanoseconds: delayNanoseconds,
            response: response,
            probe: probe)
        return AsyncThrowingStream(unfolding: { try await state.next() })
    }
}

private struct ReliabilityFinalProvider: ToolCallingProvider {
    var text: String = "done"

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(text))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }
}

private final class ReliabilityBlockingProvider: ToolCallingProvider, @unchecked Sendable {
    private let blockingSeconds: TimeInterval
    private let lock = NSLock()
    private var capturedRequests: [AgentRequest] = []

    init(blockingSeconds: TimeInterval) {
        self.blockingSeconds = blockingSeconds
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests.count
    }

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        capturedRequests.append(request)
        lock.unlock()
        // Deliberately blocks synchronously and ignores Swift task cancellation.
        Thread.sleep(forTimeInterval: blockingSeconds)
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("late"))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }
}

private final class ReliabilityCancellationCleanupProbe: @unchecked Sendable {
    enum Milestone: Hashable {
        case providerEntered
        case callerWaiting
        case providerCleanupFinished
        case terminalPersisted
        case callerReturned
    }

    private let condition = NSCondition()
    private var cleanupReleased = false
    private var recordedMilestones: [Milestone] = []
    private var milestoneWaiters: [Milestone: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ milestone: Milestone) {
        condition.lock()
        recordedMilestones.append(milestone)
        let waiters = milestoneWaiters.removeValue(forKey: milestone) ?? []
        condition.unlock()
        for waiter in waiters { waiter.resume() }
    }

    func wait(until milestone: Milestone) async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if recordedMilestones.contains(milestone) {
                condition.unlock()
                continuation.resume()
            } else {
                milestoneWaiters[milestone, default: []].append(continuation)
                condition.unlock()
            }
        }
    }

    func waitForCleanupRelease() {
        condition.lock()
        while !cleanupReleased {
            condition.wait()
        }
        condition.unlock()
    }

    func releaseCleanup() {
        condition.lock()
        cleanupReleased = true
        condition.broadcast()
        condition.unlock()
    }

    func milestones() -> [Milestone] {
        condition.lock()
        defer { condition.unlock() }
        return recordedMilestones
    }
}

private final class ReliabilityFiniteCleanupBarrierProvider: ToolCallingProvider, @unchecked Sendable {
    private let probe: ReliabilityCancellationCleanupProbe
    private let lock = NSLock()
    private var capturedRequestCount = 0

    init(probe: ReliabilityCancellationCleanupProbe) {
        self.probe = probe
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

        probe.record(.providerEntered)
        probe.waitForCleanupRelease()
        probe.record(.providerCleanupFinished)
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("late provider output"))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }
}

private final class ReliabilityCapturingProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [AgentRequest] = []

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        captured.append(request)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("mailbox handled"))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }
}

private struct ReliabilityEndlessToolProvider: ToolCallingProvider {
    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.toolCalls([
                ToolCall(id: IDGen.random(prefix: "call"), name: "missing_tool", arguments: "{}"),
            ]))
            continuation.yield(.done(finishReason: "tool_calls"))
            continuation.finish()
        }
    }
}

private func reliabilityLog(_ name: String = UUID().uuidString) throws -> EventLog {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-reliability-\(name)", isDirectory: true)
    return try EventLog(
        session: SessionID(rawValue: "reliability"),
        fileURL: directory.appendingPathComponent("events.jsonl"))
}

private func reliabilityWorkspace() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-reliability-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func reliabilityEventIndex(_ events: [Envelope],
                                   type: Event.TypeTag,
                                   taskID: TaskID) -> Int? {
    events.firstIndex { envelope in
        switch envelope.event {
        case .taskCreated(let payload):
            return type == .taskCreated && payload.contract.id == taskID
        case .taskAssigned(let payload):
            return type == .taskAssigned && payload.contract.id == taskID
        case .taskQueued(let payload):
            return type == .taskQueued && payload.contract.id == taskID
        case .taskStarted(let payload):
            return type == .taskStarted && payload.taskID == taskID
        case .taskCompleted(let payload):
            return type == .taskCompleted && payload.taskID == taskID
        case .taskFailed(let payload):
            return type == .taskFailed && payload.taskID == taskID
        case .taskCancelled(let payload):
            return type == .taskCancelled && payload.taskID == taskID
        default:
            return false
        }
    }
}

@discardableResult
private func appendReliabilityTaskWithSettledSideEffect(
    to log: EventLog,
    workspace: URL,
    taskID: TaskID,
    agent: AgentID,
    terminalStatus: TaskStatus?,
    outcome: ToolExecutionOutcome = .succeeded,
    effectDisposition: ToolExecutionEffectDisposition? = nil
) async throws -> TaskContract {
    let workspaceLease = WorkspaceLease(
        taskID: taskID,
        rootPath: workspace.path,
        access: .readWrite)
    let capabilityLease = CapabilityLease.coordinator(taskID: taskID)
    let contract = TaskContract(
        id: taskID,
        kind: .root,
        issuer: nil,
        assignee: agent,
        objective: "do not replay an already completed side effect",
        roleHint: "root coordinator",
        expectedDeliverable: "start a new run",
        workspaceID: workspaceLease.workspaceID,
        workspaceLeaseID: workspaceLease.id,
        capabilityLeaseID: capabilityLease.id,
        replyMode: TaskReplyMode.none,
        maxAttempts: 3)
    let metadata = CoworkEventMetadata(
        taskID: taskID,
        rootTaskID: taskID,
        agentID: agent,
        assignee: agent,
        workspaceID: workspaceLease.workspaceID,
        workspaceLeaseID: workspaceLease.id,
        capabilityLeaseID: capabilityLease.id,
        scope: .task)
    let prepared = ToolExecutionPreparedPayload(
        executionID: "settled-write-\(taskID.rawValue)",
        taskID: taskID,
        attempt: 1,
        toolCallID: "settled-write-call",
        agent: agent,
        tool: "write_file",
        sideEffect: .write)
    var events: [Event] = [
        .agentAttached(AgentAttachedPayload(
            agent: agent,
            path: workspace.path,
            model: ModelID(rawValue: "m"),
            profile: PermissionProfile.reviewed.rawValue)),
        .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
            agent: agent,
            lease: workspaceLease)),
        .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
            agent: agent,
            lease: capabilityLease)),
        .taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)),
        .taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)),
        .taskQueued(TaskQueuedPayload(
            contract: contract,
            rootTaskID: taskID,
            assignee: agent,
            hopCount: 0,
            visitedAgents: [agent],
            attempt: 1,
            metadata: metadata)),
        .taskStarted(TaskStartedPayload(
            taskID: taskID,
            agent: agent,
            attempt: 1,
            metadata: metadata)),
        .toolExecutionPrepared(prepared),
        .toolExecutionSettled(ToolExecutionSettledPayload(
            prepared: prepared,
            outcome: outcome,
            effectDisposition: effectDisposition,
            reason: "the tool reached a durable terminal test outcome")),
    ]
    switch terminalStatus {
    case .failed:
        events.append(.taskFailed(TaskFailedPayload(
            taskID: taskID,
            agent: agent,
            error: "failure after completed write",
            attempt: 1,
            metadata: metadata)))
    case .cancelled:
        events.append(.taskCancelled(TaskCancelledPayload(
            taskID: taskID,
            agent: agent,
            reason: "cancelled after completed write",
            attempt: 1,
            metadata: metadata)))
    case nil, .running:
        break
    default:
        preconditionFailure("test helper only supports running, failed, or cancelled tasks")
    }
    try await log.append(events)
    return contract
}


final class OrchestrationReliabilityTests: XCTestCase {
    func testDefaultExecutionPolicyAllowsOneHourCoworkInvocations() {
        let policy = CoworkExecutionPolicy()

        XCTAssertEqual(policy.maxConcurrentTasks, 4)
        XCTAssertEqual(policy.taskTimeoutSeconds, 3_600)
        XCTAssertEqual(policy.maxAttempts, 3)
        XCTAssertNil(policy.tokenBudget)
    }

    private let main = AgentID(rawValue: "main")

    func testPublicRuntimeFactoryRetainsExclusiveSessionWriterLease() throws {
        let log = try reliabilityLog()
        let orchestrator = try Orchestrator.runtime(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in ReliabilityFinalProvider() }

        do {
            _ = try log.acquireWriterLease()
            XCTFail("a second runtime must not acquire the same session writer lease")
        } catch let error as EventLogError {
            XCTAssertEqual(error, .writerAlreadyActive)
        }
        withExtendedLifetime(orchestrator) {}
    }

    func testAttachAdmissionPersistenceFailureDoesNotExposeAgentOrLeases() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in ReliabilityFinalProvider() }
        await orchestrator.setAdmissionEventsAppender { events in
            if events.contains(where: { event in
                if case .agentAttached = event { return true }
                return false
            }) {
                throw ReliabilityForcedError.terminalPersistenceFailure
            }
            _ = try await log.append(events)
        }

        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))

        XCTAssertFalse(attached)
        let agentNames = await orchestrator.agentNames()
        let capabilityLeases = await orchestrator.capabilityLeaseList()
        let workspaceLeases = await orchestrator.workspaceLeaseList()
        let events = await log.replay()
        XCTAssertTrue(agentNames.isEmpty)
        XCTAssertTrue(capabilityLeases.isEmpty)
        XCTAssertTrue(workspaceLeases.isEmpty)
        XCTAssertFalse(events.contains { envelope in
            if case .agentAttached = envelope.event { return true }
            return false
        })
    }

    func testDetachPersistenceFailureKeepsAgentAndLeasesInRuntime() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let worker = AgentID(rawValue: "detach-worker")
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in ReliabilityFinalProvider() }
        let attached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(attached)
        let initialCapabilityLeases = await orchestrator.capabilityLeaseList()
        let initialWorkspaceLeases = await orchestrator.workspaceLeaseList()
        let baselineCapabilityIDs = Set(initialCapabilityLeases.map(\.id))
        let baselineWorkspaceIDs = Set(initialWorkspaceLeases.map(\.id))
        await orchestrator.setAdmissionEventsAppender { events in
            if events.contains(where: { event in
                if case .capabilityLeaseRevoked = event { return true }
                return false
            }) {
                throw ReliabilityForcedError.terminalPersistenceFailure
            }
            try await log.append(events)
        }

        let detached = await orchestrator.detach(worker, reason: "forced detach failure")
        let agentNames = await orchestrator.agentNames()
        let finalCapabilityLeases = await orchestrator.capabilityLeaseList()
        let finalWorkspaceLeases = await orchestrator.workspaceLeaseList()
        let events = await log.replay()
        XCTAssertFalse(detached)
        XCTAssertTrue(agentNames.contains(worker))
        XCTAssertEqual(Set(finalCapabilityLeases.map(\.id)), baselineCapabilityIDs)
        XCTAssertEqual(Set(finalWorkspaceLeases.map(\.id)), baselineWorkspaceIDs)
        let projection = CoworkProjection.build(from: events)
        XCTAssertNotNil(projection.agentRoster[worker])
        XCTAssertFalse(events.contains { envelope in
            if case .agentDetached(let payload) = envelope.event { return payload.agent == worker }
            return false
        })
    }

    func testRemoveToolReportsFailureWhenDetachAuditCannotBePersisted() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let worker = AgentID(rawValue: "remove-failure-worker")
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in ReliabilityFinalProvider() }
        let mainAttached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)
        let failure = ReliabilityOneShotRevocationFailure()
        await orchestrator.setAdmissionEventsAppender { events in
            try await failure.append(events, to: log)
        }

        let result = await orchestrator.removeFromTool(
            requestedBy: main,
            currentTaskID: nil,
            name: worker.rawValue)

        XCTAssertTrue(result.hasPrefix("error:"))
        let names = await orchestrator.agentNames()
        XCTAssertTrue(names.contains(worker))
    }

    func testDelegationQueuePersistenceFailureDoesNotCommitOrExecuteTask() async throws {
        let log = try reliabilityLog()
        let mainWorkspace = try reliabilityWorkspace()
        let workerWorkspace = try reliabilityWorkspace()
        defer {
            try? FileManager.default.removeItem(at: mainWorkspace)
            try? FileManager.default.removeItem(at: workerWorkspace)
        }
        let worker = AgentID(rawValue: "worker")
        let provider = ReliabilityCapturingProvider()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        let mainAttached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: mainWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: workerWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)
        let rootIDValue = await orchestrator.createRootTask(
            assignee: main,
            objective: "delegation root")
        let rootID = try XCTUnwrap(rootIDValue)
        let baselineCapabilityLeases = await orchestrator.capabilityLeaseList().count
        let baselineWorkspaceLeases = await orchestrator.workspaceLeaseList().count
        await orchestrator.setAdmissionEventsAppender { events in
            if events.contains(where: { event in
                guard case .taskQueued(let payload) = event else { return false }
                return payload.contract.kind == .agentInvocation
            }) {
                throw ReliabilityForcedError.terminalPersistenceFailure
            }
            _ = try await log.append(events)
        }

        let queued = await orchestrator.enqueueDelegatedTask(
            from: main,
            to: worker.rawValue,
            objective: "must remain unexecutable",
            parentTaskID: rootID)
        await orchestrator.runSchedulerUntilIdle()

        let queuedTasks = await orchestrator.queuedTasks()
        let graph = await orchestrator.taskGraphSnapshot()
        let finalCapabilityLeaseCount = await orchestrator.capabilityLeaseList().count
        let finalWorkspaceLeaseCount = await orchestrator.workspaceLeaseList().count
        let projection = CoworkProjection.build(from: await log.replay())
        let partialTask = projection.tasks.values.first {
            $0.contract?.objective == "must remain unexecutable"
        }
        XCTAssertNil(queued.taskID)
        XCTAssertTrue(queued.message.contains("could not be persisted"))
        XCTAssertTrue(queuedTasks.isEmpty)
        XCTAssertEqual(graph.nodes.count, 1)
        XCTAssertEqual(finalCapabilityLeaseCount, baselineCapabilityLeases)
        XCTAssertEqual(finalWorkspaceLeaseCount, baselineWorkspaceLeases)
        XCTAssertNil(partialTask)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testRecoveryRequeuePersistenceFailureFailsClosedWithoutProviderExecution() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID.new()
        let contract = TaskContract(
            id: taskID,
            kind: .root,
            issuer: nil,
            assignee: main,
            objective: "interrupted",
            roleHint: "root",
            expectedDeliverable: "result",
            replyMode: TaskReplyMode.none,
            executionTimeoutSeconds: 10,
            maxAttempts: 3)
        let metadata = CoworkEventMetadata(
            taskID: taskID,
            rootTaskID: taskID,
            agentID: main,
            assignee: main,
            scope: .task)
        try await log.append(.agentAttached(AgentAttachedPayload(
            agent: main,
            path: workspace.path,
            model: ModelID(rawValue: "m"),
            profile: PermissionProfile.reviewed.rawValue)))
        try await log.append(.taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)))
        try await log.append(.taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)))
        try await log.append(.taskQueued(TaskQueuedPayload(
            contract: contract,
            rootTaskID: taskID,
            assignee: main,
            hopCount: 0,
            visitedAgents: [main],
            attempt: 1,
            metadata: metadata)))
        try await log.append(.taskStarted(TaskStartedPayload(
            taskID: taskID,
            agent: main,
            attempt: 1,
            metadata: metadata)))
        let provider = ReliabilityCapturingProvider()
        let restored = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        await restored.setAdmissionEventAppender { event in
            if case .taskQueued(let payload) = event,
               payload.contract.id == taskID,
               payload.attempt == 2 {
                throw ReliabilityForcedError.terminalPersistenceFailure
            }
            _ = try await log.append(event)
        }

        await restored.restore(from: CoworkProjection.build(from: await log.replay()))
        await restored.resumePendingTasks()
        await restored.runSchedulerUntilIdle()

        let remainingQueuedTasks = await restored.queuedTasks()
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertTrue(remainingQueuedTasks.isEmpty)
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(projection.tasks[taskID]?.status, .failed)
        XCTAssertEqual(projection.tasks[taskID]?.attempt, 2)
    }

    func testMailboxFailureRetriesSameTaskOnlyToConfiguredAttemptLimit() async throws {
        let log = try reliabilityLog()
        let mainWorkspace = try reliabilityWorkspace()
        let workerWorkspace = try reliabilityWorkspace()
        defer {
            try? FileManager.default.removeItem(at: mainWorkspace)
            try? FileManager.default.removeItem(at: workerWorkspace)
        }
        let worker = AgentID(rawValue: "worker")
        let provider = ReliabilityFailingProvider()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(maxAttempts: 3)) { _ in provider }
        let mainAttached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: mainWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: workerWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)

        let sendResult = await orchestrator.sendMessage(
            from: main,
            to: worker.rawValue,
            content: "retry mailbox")
        XCTAssertEqual(sendResult, "sent message to @worker")
        await orchestrator.runSchedulerUntilIdle()

        XCTAssertEqual(provider.requestCount, 3)
        let mailboxQueues = await log.replay().compactMap { envelope -> (TaskID, Int)? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.kind == .mailboxDelivery,
                  let attempt = payload.attempt else { return nil }
            return (payload.contract.id, attempt)
        }
        let pendingMessageCount = await orchestrator.mailbox(for: worker).pendingMessages.count
        let remainingQueuedTasks = await orchestrator.queuedTasks()
        XCTAssertEqual(Set(mailboxQueues.map(\.0)).count, 1)
        XCTAssertEqual(mailboxQueues.map(\.1), [1, 2, 3])
        XCTAssertEqual(pendingMessageCount, 1)
        XCTAssertTrue(remainingQueuedTasks.isEmpty)
    }

    func testExhaustedMailboxMessageIsNotReplacedButNewMessageGetsIndependentTask() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let worker = AgentID(rawValue: "worker")
        let provider = ReliabilityThreeFailuresThenSuccessProvider()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(maxAttempts: 3)) { _ in provider }
        let mainAttached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)

        let poisonSend = await orchestrator.sendMessage(
            from: main,
            to: worker.rawValue,
            content: "poison message")
        XCTAssertEqual(poisonSend, "sent message to @worker")
        await orchestrator.runSchedulerUntilIdle()
        XCTAssertEqual(provider.requestCount, 3)
        let afterPoison = await log.replay()
        let poisonMessageID = try XCTUnwrap(afterPoison.compactMap { envelope -> MessageID? in
            guard case .agentMessage(let payload) = envelope.event,
                  payload.content == "poison message" else { return nil }
            return payload.messageId
        }.first)
        let poisonTaskID = try XCTUnwrap(afterPoison.compactMap { envelope -> TaskID? in
            guard case .taskCreated(let payload) = envelope.event,
                  payload.contract.mailboxMessageIDs == [poisonMessageID] else { return nil }
            return payload.contract.id
        }.first)

        // Draining the scheduler again must not manufacture a replacement
        // delivery task for the already exhausted MessageID.
        await orchestrator.runSchedulerUntilIdle()
        XCTAssertEqual(
            provider.requestCount,
            3,
            "an exhausted delivery must remain quiescent")
        let afterUnrelated = await log.replay()
        XCTAssertEqual(afterUnrelated.compactMap { envelope -> TaskID? in
            guard case .taskCreated(let payload) = envelope.event,
                  payload.contract.kind == .mailboxDelivery else { return nil }
            return payload.contract.id
        }, [poisonTaskID])

        let freshSend = await orchestrator.sendMessage(
            from: main,
            to: worker.rawValue,
            content: "fresh message")
        XCTAssertEqual(freshSend, "sent message to @worker")
        await orchestrator.runSchedulerUntilIdle()
        XCTAssertEqual(provider.requestCount, 4)
        let finalEvents = await log.replay()
        let freshMessageID = try XCTUnwrap(finalEvents.compactMap { envelope -> MessageID? in
            guard case .agentMessage(let payload) = envelope.event,
                  payload.content == "fresh message" else { return nil }
            return payload.messageId
        }.first)
        let mailboxContracts = finalEvents.compactMap { envelope -> TaskContract? in
            guard case .taskCreated(let payload) = envelope.event,
                  payload.contract.kind == .mailboxDelivery else { return nil }
            return payload.contract
        }
        XCTAssertEqual(mailboxContracts.count, 2)
        XCTAssertEqual(mailboxContracts[0].id, poisonTaskID)
        XCTAssertEqual(mailboxContracts[0].mailboxMessageIDs, [poisonMessageID])
        XCTAssertEqual(mailboxContracts[1].mailboxMessageIDs, [freshMessageID])
        let pendingMessages = await orchestrator.mailbox(for: worker).pendingMessages
        XCTAssertEqual(pendingMessages, [poisonMessageID])
    }

    func testMailboxAutomaticRetryStopsAfterSettledNonReplayableExecution() async throws {
        let log = try reliabilityLog()
        let mainWorkspace = try reliabilityWorkspace()
        let workerWorkspace = try reliabilityWorkspace()
        defer {
            try? FileManager.default.removeItem(at: mainWorkspace)
            try? FileManager.default.removeItem(at: workerWorkspace)
        }
        let worker = AgentID(rawValue: "worker")
        let provider = ReliabilityMailboxSideEffectThenFailProvider()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(maxAttempts: 3)) { _ in provider }
        let mainAttached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: mainWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: workerWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)

        let sendResult = await orchestrator.requestInformation(
            from: main,
            to: worker.rawValue,
            question: "handle once")
        XCTAssertTrue(sendResult.hasPrefix("requested information from @worker (request_id: "))
        await orchestrator.runSchedulerUntilIdle()

        let events = await log.replay()
        let originalMessageID = try XCTUnwrap(events.compactMap { envelope -> MessageID? in
            guard case .informationRequested(let payload) = envelope.event,
                  payload.from == main,
                  payload.to == worker,
                  payload.question == "handle once" else { return nil }
            return payload.requestID
        }.first)
        let originalTaskID = try XCTUnwrap(events.compactMap { envelope -> TaskID? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.kind == .mailboxDelivery,
                  payload.contract.mailboxMessageIDs?.contains(originalMessageID) == true else {
                return nil
            }
            return payload.contract.id
        }.first)
        let mailboxQueues = events.compactMap { envelope -> (TaskID, Int)? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.kind == .mailboxDelivery,
                  payload.contract.id == originalTaskID,
                  let attempt = payload.attempt else { return nil }
            return (payload.contract.id, attempt)
        }
        let settledSideEffect = events.compactMap { envelope -> ToolExecutionSettledPayload? in
            guard case .toolExecutionSettled(let payload) = envelope.event,
                  payload.taskID == originalTaskID,
                  payload.toolCallID == "mailbox-reply-side-effect" else { return nil }
            return payload
        }

        XCTAssertEqual(provider.originalMailboxRequestCount, 2)
        XCTAssertGreaterThanOrEqual(provider.requestCount, 2)
        XCTAssertEqual(mailboxQueues.map(\.1), [1])
        XCTAssertEqual(settledSideEffect.map(\.outcome), [.succeeded])
        let pendingMessageCount = await orchestrator.mailbox(for: worker).pendingMessages.count
        let remainingQueuedTasks = await orchestrator.queuedTasks()
        XCTAssertEqual(pendingMessageCount, 1)
        XCTAssertTrue(remainingQueuedTasks.isEmpty)
    }

    func testFailedTaskCannotRenewFromStillLiveLeaseWhenRevokeAuditFails() async throws {
        let log = try reliabilityLog()
        let mainWorkspace = try reliabilityWorkspace()
        let workerWorkspace = try reliabilityWorkspace()
        defer {
            try? FileManager.default.removeItem(at: mainWorkspace)
            try? FileManager.default.removeItem(at: workerWorkspace)
        }
        let worker = AgentID(rawValue: "worker")
        let provider = ReliabilityFailingProvider()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(maxAttempts: 3)) { _ in provider }
        let mainAttached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: mainWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: workerWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)
        await orchestrator.setAdmissionEventsAppender { events in
            if events.contains(where: { event in
                if case .capabilityLeaseRevoked = event { return true }
                if case .workspaceLeaseRevoked = event { return true }
                return false
            }) {
                throw ReliabilityForcedError.terminalPersistenceFailure
            }
            try await log.append(events)
        }

        let sendResult = await orchestrator.sendMessage(
            from: main,
            to: worker.rawValue,
            content: "fail once")
        XCTAssertEqual(sendResult, "sent message to @worker")
        await orchestrator.runSchedulerUntilIdle()

        let projection = CoworkProjection.build(from: await log.replay())
        let failedTask = try XCTUnwrap(projection.tasks.values.first {
            $0.contract?.kind == .mailboxDelivery
        })
        XCTAssertEqual(failedTask.status, .failed)
        let capabilityLeaseID = try XCTUnwrap(failedTask.contract?.capabilityLeaseID)
        let workspaceLeaseID = try XCTUnwrap(failedTask.contract?.workspaceLeaseID)
        let retainedCapabilityLease = await orchestrator.capabilityLease(id: capabilityLeaseID)
        let retainedWorkspaceLease = await orchestrator.workspaceLease(id: workspaceLeaseID)
        XCTAssertNotNil(retainedCapabilityLease)
        XCTAssertNotNil(retainedWorkspaceLease)

        let explicitRetry = await orchestrator.retry(failedTask)

        guard case .failed(let message) = explicitRetry else {
            return XCTFail("Retry must fail closed without committed renewal history.")
        }
        XCTAssertTrue(message.contains("missing without renewal history"))
        XCTAssertEqual(provider.requestCount, 1)
        let queueAttempts = await log.replay().compactMap { envelope -> Int? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.id == failedTask.id else { return nil }
            return payload.attempt
        }
        XCTAssertEqual(queueAttempts, [1])
    }

    func testProductionSendPersistsRealRootLifecycle() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in ReliabilityFinalProvider(text: "root result") }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)

        let sendResult = await orchestrator.send("real root work", to: main)
        XCTAssertEqual(sendResult, .sent)

        let events = await log.replay()
        let root = try XCTUnwrap(events.compactMap { envelope -> TaskContract? in
            guard case .taskCreated(let payload) = envelope.event,
                  payload.contract.kind == .root else { return nil }
            return payload.contract
        }.first)
        XCTAssertNil(root.parentTaskID)
        XCTAssertNil(root.issuer)
        XCTAssertEqual(root.executionTimeoutSeconds, 3_600)
        XCTAssertEqual(root.maxAttempts, 3)
        let projection = CoworkProjection.build(from: events)
        XCTAssertEqual(projection.tasks[root.id]?.status, .completed)
        XCTAssertEqual(projection.tasks[root.id]?.attempt, 1)
        let created = try XCTUnwrap(reliabilityEventIndex(events, type: .taskCreated, taskID: root.id))
        let assigned = try XCTUnwrap(reliabilityEventIndex(events, type: .taskAssigned, taskID: root.id))
        let queued = try XCTUnwrap(reliabilityEventIndex(events, type: .taskQueued, taskID: root.id))
        let started = try XCTUnwrap(reliabilityEventIndex(events, type: .taskStarted, taskID: root.id))
        let completed = try XCTUnwrap(reliabilityEventIndex(events, type: .taskCompleted, taskID: root.id))
        XCTAssertLessThan(created, assigned)
        XCTAssertLessThan(assigned, queued)
        XCTAssertLessThan(queued, started)
        XCTAssertLessThan(started, completed)
    }

    func testTaskStartPersistenceFailureDoesNotExecuteProvider() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReliabilityCapturingProvider()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        await orchestrator.setTaskLifecycleEventAppender { event in
            if case .taskStarted = event {
                throw ReliabilityForcedError.terminalPersistenceFailure
            }
            _ = try await log.append(event)
        }

        let result = await orchestrator.send("must not execute", to: main)

        guard case .failed(let message) = result else {
            return XCTFail("task-start persistence failure must fail the send")
        }
        XCTAssertTrue(message.contains("Task start could not be persisted"))
        XCTAssertTrue(provider.requests.isEmpty)
        let events = await log.replay()
        let taskID = try XCTUnwrap(events.compactMap { envelope -> TaskID? in
            guard case .taskCreated(let payload) = envelope.event,
                  payload.contract.kind == .root else { return nil }
            return payload.contract.id
        }.first)
        XCTAssertNil(reliabilityEventIndex(events, type: .taskStarted, taskID: taskID))
        XCTAssertNotNil(reliabilityEventIndex(events, type: .taskFailed, taskID: taskID))
        XCTAssertEqual(CoworkProjection.build(from: events).tasks[taskID]?.status, .failed)
    }

    func testCompletionPersistenceFailureFallsBackToDurableFailureWithoutReplay() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReliabilityCapturingProvider()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        await orchestrator.setTaskLifecycleEventAppender { event in
            if case .taskCompleted = event {
                throw ReliabilityForcedError.terminalPersistenceFailure
            }
            _ = try await log.append(event)
        }

        let result = await orchestrator.send("persist completion", to: main)

        guard case .failed(let message) = result else {
            return XCTFail("completion persistence failure must fail the send")
        }
        XCTAssertTrue(message.contains("Task completion could not be persisted"))
        XCTAssertEqual(provider.requests.count, 1)
        let events = await log.replay()
        let projection = CoworkProjection.build(from: events)
        let root = try XCTUnwrap(projection.tasks.values.first { $0.contract?.kind == .root })
        XCTAssertEqual(root.status, .failed)
        XCTAssertNil(reliabilityEventIndex(events, type: .taskCompleted, taskID: root.id))
        XCTAssertNotNil(reliabilityEventIndex(events, type: .taskFailed, taskID: root.id))

        let replayProvider = ReliabilityCapturingProvider()
        let restored = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in replayProvider }
        await restored.restore(from: projection)
        await restored.resumePendingTasks()
        await restored.runSchedulerUntilIdle()
        XCTAssertTrue(replayProvider.requests.isEmpty)
    }

    func testRuntimeConcurrencyIsBoundedAndPerAgentSingleFlight() async throws {
        let log = try reliabilityLog()
        let mainWorkspace = try reliabilityWorkspace()
        let firstWorkspace = try reliabilityWorkspace()
        let secondWorkspace = try reliabilityWorkspace()
        defer {
            try? FileManager.default.removeItem(at: mainWorkspace)
            try? FileManager.default.removeItem(at: firstWorkspace)
            try? FileManager.default.removeItem(at: secondWorkspace)
        }
        let first = AgentID(rawValue: "first")
        let second = AgentID(rawValue: "second")
        let probe = ReliabilityConcurrencyProbe()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(maxConcurrentTasks: 2)) { agent in
                ReliabilityDelayedProvider(
                    agent: agent.name,
                    delayNanoseconds: 150_000_000,
                    probe: probe)
            }
        let mainAttached = await orchestrator.attach(Agent(
            name: main, workspaceRoot: mainWorkspace, model: ModelID(rawValue: "m"),
            profile: .reviewed, coordinationDepth: Agent.defaultCoordinationDepth))
        let firstAttached = await orchestrator.attach(Agent(
            name: first, workspaceRoot: firstWorkspace, model: ModelID(rawValue: "m"), profile: .reviewed))
        let secondAttached = await orchestrator.attach(Agent(
            name: second, workspaceRoot: secondWorkspace, model: ModelID(rawValue: "m"), profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(firstAttached)
        XCTAssertTrue(secondAttached)
        let rootIDValue = await orchestrator.createRootTask(assignee: main, objective: "parallel root")
        let rootID = try XCTUnwrap(rootIDValue)
        let firstA = await orchestrator.enqueueDelegatedTask(
            from: main, to: first.rawValue, objective: "first A", parentTaskID: rootID)
        let firstB = await orchestrator.enqueueDelegatedTask(
            from: main, to: first.rawValue, objective: "first B", parentTaskID: rootID)
        let secondA = await orchestrator.enqueueDelegatedTask(
            from: main, to: second.rawValue, objective: "second A", parentTaskID: rootID)
        XCTAssertNotNil(firstA.taskID)
        XCTAssertNotNil(firstB.taskID)
        XCTAssertNotNil(secondA.taskID)

        await orchestrator.runSchedulerUntilIdle()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.maximumActive, 2)
        XCTAssertEqual(snapshot.maximumByAgent[first], 1)
        XCTAssertEqual(snapshot.maximumByAgent[second], 1)
        let completed = CoworkProjection.build(from: await log.replay()).completedTasks
        XCTAssertEqual(Set(completed.map(\.id)), Set([firstA.taskID, firstB.taskID, secondA.taskID].compactMap { $0 }))
    }

    func testRetryUsesCurrentSchedulerAttemptInsteadOfStaleView() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReliabilityFailingProvider()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(maxAttempts: 3)) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        guard case .failed = await orchestrator.send("always fail", to: main) else {
            return XCTFail("first attempt must fail")
        }
        let failedReplay = await log.replay()
        let staleView = try XCTUnwrap(
            CoworkProjection.build(from: failedReplay).failedTasks.first)

        guard case .failed = await orchestrator.retry(staleView) else {
            return XCTFail("second attempt must fail")
        }
        guard case .failed = await orchestrator.retry(staleView) else {
            return XCTFail("stale view must still advance to the current third attempt")
        }
        let exhausted = await orchestrator.retry(staleView)

        XCTAssertEqual(exhausted, .failed("Task reached its maximum of 3 attempts."))
        XCTAssertEqual(provider.requestCount, 3)
        let attempts = await log.replay().compactMap { envelope -> Int? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.id == staleView.id else { return nil }
            return payload.attempt
        }
        XCTAssertEqual(attempts, [1, 2, 3])
    }

    func testScopedCancellationDurablyDiscardsMessageAdmittedByNonCooperativeSender() async throws {
        let log = try reliabilityLog()
        let mainWorkspace = try reliabilityWorkspace()
        let workerWorkspace = try reliabilityWorkspace()
        defer {
            try? FileManager.default.removeItem(at: mainWorkspace)
            try? FileManager.default.removeItem(at: workerWorkspace)
        }
        let worker = AgentID(rawValue: "worker")
        let goalID = GoalID.new()
        let runID = ContinuationRunID.new()
        let mediationGate = ReliabilityForwardingGate()
        let provider = ReliabilityCapturingProvider()
        let orchestrator = Orchestrator(
            log: log,
            mediator: Mediator(reviewer: mediationGate),
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        let mainAttached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: mainWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: workerWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)
        let causalTaskIDValue = await orchestrator.createRootTask(
            assignee: main,
            objective: "scoped communication root",
            goalID: goalID,
            continuationRunID: runID)
        let causalTaskID = try XCTUnwrap(causalTaskIDValue)

        let send = Task {
            await orchestrator.sendMessage(
                from: main,
                to: worker.rawValue,
                content: "late scoped message",
                taskID: causalTaskID)
        }
        await mediationGate.waitUntilEntered()
        let cancellation = Task {
            await orchestrator.cancelActiveTasks(
                goalID: goalID,
                continuationRunID: runID,
                reason: "cancel while sender ignores cancellation",
                resumePendingTasksOnSuccess: false)
        }
        for _ in 0..<100 {
            if await orchestrator.admissionWaiterCountForTesting() > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let admissionWaiterCount = await orchestrator.admissionWaiterCountForTesting()
        XCTAssertGreaterThan(admissionWaiterCount, 0)
        await mediationGate.release()

        let sendResult = await send.value
        let cancellationSucceeded = await cancellation.value

        XCTAssertTrue(cancellationSucceeded)
        XCTAssertTrue(sendResult.contains("ContinuationRun is closed"), sendResult)
        XCTAssertTrue(provider.requests.isEmpty)
        let pendingMessages = await orchestrator.mailbox(for: worker).pendingMessages
        XCTAssertTrue(pendingMessages.isEmpty)
        let events = await log.replay()
        let closeIndex = try XCTUnwrap(events.firstIndex { envelope in
            guard case .continuationRunCloseRequested(let payload) = envelope.event else {
                return false
            }
            return payload.runID == runID
                && payload.requestedOutcome == .cancelled
                && payload.source == .user
        })
        let discardedIndex = try XCTUnwrap(events.firstIndex { envelope in
            guard case .agentMessageDiscarded(let payload) = envelope.event else { return false }
            return payload.agent == worker
                && payload.taskID == causalTaskID
                && payload.goalID == goalID
                && payload.continuationRunID == runID
        })
        XCTAssertLessThan(closeIndex, discardedIndex)
        XCTAssertEqual(events.filter { envelope in
            guard case .continuationRunCloseRequested(let payload) = envelope.event else {
                return false
            }
            return payload.runID == runID
        }.count, 1)
        XCTAssertTrue(events.contains { envelope in
            guard case .agentMessageDiscarded(let payload) = envelope.event else { return false }
            return payload.agent == worker
                && payload.taskID == causalTaskID
                && payload.goalID == goalID
                && payload.continuationRunID == runID
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .agentMessageConsumed(let payload) = envelope.event else { return false }
            return payload.agent == worker
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .taskCreated(let payload) = envelope.event else { return false }
            return payload.contract.kind == .mailboxDelivery
                && payload.contract.goalID == goalID
                && payload.contract.continuationRunID == runID
        })
    }

    func testClaimedTaskCanBeCancelledBeforeTaskStartedCommit() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReliabilityCapturingProvider()
        let gate = ReliabilityTaskStartGate()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        await orchestrator.setTaskStartGate { _ in await gate.pause() }

        let sendTask = Task { await orchestrator.send("cancel before start", to: main) }
        await gate.waitUntilEntered()
        let queuedProjection = CoworkProjection.build(from: await log.replay())
        let taskID = try XCTUnwrap(queuedProjection.queuedTasks.first?.id)
        let cancelled = await orchestrator.cancel(taskID: taskID, reason: "cancel claimed task")
        await gate.release()
        let result = await sendTask.value
        await orchestrator.runSchedulerUntilIdle()

        XCTAssertTrue(cancelled)
        guard case .failed(let message) = result else {
            return XCTFail("cancelled claimed task must fail the send")
        }
        XCTAssertTrue(message.contains("cancel claimed task"))
        XCTAssertTrue(provider.requests.isEmpty)
        let events = await log.replay()
        XCTAssertNil(reliabilityEventIndex(events, type: .taskStarted, taskID: taskID))
        XCTAssertNotNil(reliabilityEventIndex(events, type: .taskCancelled, taskID: taskID))
        XCTAssertEqual(CoworkProjection.build(from: events).tasks[taskID]?.status, .cancelled)
    }

    func testScopeCancellationDuringTaskStartedPersistenceNeverEntersProvider() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReliabilityCapturingProvider()
        let startedPersistenceGate = ReliabilityTaskStartGate()
        let goalID = GoalID.new()
        let runID = ContinuationRunID.new()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        await orchestrator.setTaskLifecycleEventAppender { event in
            _ = try await log.append(event)
            if case .taskStarted = event {
                await startedPersistenceGate.pause()
            }
        }

        let sendTask = Task {
            await orchestrator.send(
                "cancel while task-start persistence is suspended",
                to: main,
                goalID: goalID,
                continuationRunID: runID)
        }
        await startedPersistenceGate.waitUntilEntered()
        let cancellation = Task {
            await orchestrator.cancelActiveTasks(
                goalID: goalID,
                continuationRunID: runID,
                reason: "scope cancelled during task-start persistence",
                resumePendingTasksOnSuccess: false)
        }
        var observedDurableCancellation = false
        for _ in 0..<100 {
            observedDurableCancellation = await log.replay().contains { envelope in
                if case .taskCancelled = envelope.event { return true }
                return false
            }
            if observedDurableCancellation { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(observedDurableCancellation)
        await startedPersistenceGate.release()

        let cancellationSucceeded = await cancellation.value
        XCTAssertTrue(cancellationSucceeded)
        let sendResult = await sendTask.value
        guard case .failed = sendResult else {
            return XCTFail("scope-cancelled send must fail closed")
        }
        await orchestrator.runSchedulerUntilIdle()
        await orchestrator.runSchedulerUntilIdle(
            goalID: goalID,
            continuationRunID: runID)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testCancellationPersistenceFailureQuarantinesTaskWithoutBlockingWaiters() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReliabilityCapturingProvider()
        let startGate = ReliabilityTaskStartGate()
        let cancellationGate = ReliabilityCancellationPersistenceGate()
        let goalID = GoalID.new()
        let runID = ContinuationRunID.new()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        await orchestrator.setTaskStartGate { _ in await startGate.pause() }
        await orchestrator.setTaskLifecycleEventAppender { event in
            try await cancellationGate.append(event, to: log)
        }

        let sendTask = Task {
            await orchestrator.send(
                "quarantine cancellation persistence failure",
                to: main,
                goalID: goalID,
                continuationRunID: runID)
        }
        await startGate.waitUntilEntered()
        let cancellation = Task {
            await orchestrator.cancelActiveTasks(
                goalID: goalID,
                continuationRunID: runID,
                reason: "forced cancellation persistence failure",
                resumePendingTasksOnSuccess: false)
        }
        await Task.yield()
        await startGate.release()

        let cancellationSucceeded = await cancellation.value
        XCTAssertFalse(cancellationSucceeded)
        let sendResult = await sendTask.value
        guard case .failed(let message) = sendResult else {
            return XCTFail("quarantined send must return a failure")
        }
        XCTAssertTrue(message.contains("could not be persisted"))
        let globalStarted = Date()
        await orchestrator.runSchedulerUntilIdle()
        XCTAssertLessThan(Date().timeIntervalSince(globalStarted), 1)
        let scopedStarted = Date()
        await orchestrator.runSchedulerUntilIdle(
            goalID: goalID,
            continuationRunID: runID)
        XCTAssertLessThan(Date().timeIntervalSince(scopedStarted), 1)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testGraphOnlyAssignedRootCancellationRetriesAfterPersistenceRecovers() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReliabilityCapturingProvider()
        let cancellationGate = ReliabilityCancellationPersistenceGate()
        let goalID = GoalID.new()
        let runID = ContinuationRunID.new()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        await orchestrator.setTaskLifecycleEventAppender { event in
            try await cancellationGate.append(event, to: log)
        }
        let createdRootID = await orchestrator.createRootTask(
            assignee: main,
            objective: "durable assigned root without queue admission",
            goalID: goalID,
            continuationRunID: runID)
        let rootID = try XCTUnwrap(createdRootID)

        let first = await orchestrator.cancelActiveTasks(
            goalID: goalID,
            continuationRunID: runID,
            reason: "first cancellation fails",
            resumePendingTasksOnSuccess: false)
        XCTAssertFalse(first)
        let failedCancellationProjection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(
            failedCancellationProjection.tasks[rootID]?.status,
            .assigned)

        await cancellationGate.allowCancellation()
        let second = await orchestrator.cancelActiveTasks(
            goalID: goalID,
            continuationRunID: runID,
            reason: "retry after persistence recovery",
            resumePendingTasksOnSuccess: false)
        XCTAssertTrue(second)
        let recoveredCancellationProjection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(
            recoveredCancellationProjection.tasks[rootID]?.status,
            .cancelled)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testRunningTaskCancellationHasOneCancelledTerminalState() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let probe = ReliabilityConcurrencyProbe()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { agent in
                ReliabilityDelayedProvider(
                    agent: agent.name,
                    delayNanoseconds: 5_000_000_000,
                    probe: probe)
            }
        let attached = await orchestrator.attach(Agent(
            name: main, workspaceRoot: workspace, model: ModelID(rawValue: "m"),
            profile: .reviewed, coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)

        let sendTask = Task { await orchestrator.send("cancel me", to: main) }
        var runningID: TaskID?
        for _ in 0..<200 {
            runningID = CoworkProjection.build(from: await log.replay()).runningTasks.first?.id
            if runningID != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let taskID = try XCTUnwrap(runningID)
        let cancelled = await orchestrator.cancel(taskID: taskID, reason: "test cancellation")
        XCTAssertTrue(cancelled)
        guard case .failed(let message) = await sendTask.value else {
            return XCTFail("cancelled send must report failure")
        }
        XCTAssertTrue(message.contains("test cancellation"))

        let events = await log.replay()
        let terminalEvents = events.filter { envelope in
            switch envelope.event {
            case .taskCompleted(let payload): return payload.taskID == taskID
            case .taskFailed(let payload): return payload.taskID == taskID
            case .taskCancelled(let payload): return payload.taskID == taskID
            default: return false
            }
        }
        XCTAssertEqual(terminalEvents.count, 1)
        XCTAssertNotNil(reliabilityEventIndex(events, type: .taskCancelled, taskID: taskID))
        XCTAssertEqual(CoworkProjection.build(from: events).tasks[taskID]?.status, .cancelled)
    }

    func testSingleTaskCancellationWaitsForProviderCleanupBeforeTerminalAndCallerResult() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let probe = ReliabilityCancellationCleanupProbe()
        defer { probe.releaseCleanup() }
        let provider = ReliabilityFiniteCleanupBarrierProvider(probe: probe)
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        await orchestrator.setTaskLifecycleEventAppender { event in
            _ = try await log.append(event)
            if case .taskCancelled = event {
                probe.record(.terminalPersisted)
            }
        }
        await orchestrator.setSchedulerResultWaiterHookForTesting { _ in
            probe.record(.callerWaiting)
        }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)

        let sendTask = Task {
            let result = await orchestrator.send("cancel after provider starts", to: main)
            probe.record(.callerReturned)
            return result
        }
        await probe.wait(until: .providerEntered)
        await probe.wait(until: .callerWaiting)
        let runningProjection = CoworkProjection.build(from: await log.replay())
        let taskID = try XCTUnwrap(runningProjection.runningTasks.first?.id)

        let cancelled = await orchestrator.cancel(
            taskID: taskID,
            reason: "single-task cleanup barrier")
        XCTAssertTrue(cancelled)
        XCTAssertEqual(provider.requestCount, 1)
        let beforeRelease = probe.milestones()
        XCTAssertNil(beforeRelease.firstIndex(of: .providerCleanupFinished))
        XCTAssertNil(beforeRelease.firstIndex(of: .terminalPersisted))
        XCTAssertNil(beforeRelease.firstIndex(of: .callerReturned))
        let beforeReleaseEvents = await log.replay()
        XCTAssertNil(reliabilityEventIndex(beforeReleaseEvents, type: .taskCompleted, taskID: taskID))
        XCTAssertNil(reliabilityEventIndex(beforeReleaseEvents, type: .taskFailed, taskID: taskID))
        XCTAssertNil(reliabilityEventIndex(beforeReleaseEvents, type: .taskCancelled, taskID: taskID))

        probe.releaseCleanup()
        guard case .failed(let message) = await sendTask.value else {
            return XCTFail("single-task cancellation must fail the waiting send after cleanup")
        }
        XCTAssertTrue(message.contains("single-task cleanup barrier"))

        let milestones = probe.milestones()
        let cleanupIndex = try XCTUnwrap(milestones.firstIndex(of: .providerCleanupFinished))
        let terminalIndex = try XCTUnwrap(milestones.firstIndex(of: .terminalPersisted))
        let callerIndex = try XCTUnwrap(milestones.firstIndex(of: .callerReturned))
        XCTAssertLessThan(cleanupIndex, terminalIndex)
        XCTAssertLessThan(terminalIndex, callerIndex)

        let events = await log.replay()
        let terminalEvents = events.filter { envelope in
            switch envelope.event {
            case .taskCompleted(let payload): return payload.taskID == taskID
            case .taskFailed(let payload): return payload.taskID == taskID
            case .taskCancelled(let payload): return payload.taskID == taskID
            default: return false
            }
        }
        XCTAssertEqual(terminalEvents.count, 1)
        XCTAssertNotNil(reliabilityEventIndex(events, type: .taskCancelled, taskID: taskID))
        XCTAssertEqual(CoworkProjection.build(from: events).tasks[taskID]?.status, .cancelled)
    }

    func testRunningCancellationRefreshesConsumedTokenCount() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let probe = ReliabilityConcurrencyProbe()
        let provider = ReliabilityDelayedProvider(
            agent: main,
            delayNanoseconds: 5_000_000_000,
            probe: probe)
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(tokenBudget: 100_000)) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        try await log.append(.turnStats(TurnStatsPayload(totalTokens: 100_000)))

        let firstSend = Task { await orchestrator.send("cancel and refresh", to: main) }
        var runningID: TaskID?
        for _ in 0..<200 {
            runningID = CoworkProjection.build(from: await log.replay()).runningTasks.first?.id
            if runningID != nil, provider.requestCount == 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let taskID = try XCTUnwrap(runningID)
        let cancelled = await orchestrator.cancel(taskID: taskID, reason: "refresh budget")
        XCTAssertTrue(cancelled)
        _ = await firstSend.value

        let secondResult = await orchestrator.send("must be budget blocked", to: main)

        guard case .failed(let message) = secondResult else {
            return XCTFail("refreshed token budget must block the next task")
        }
        XCTAssertTrue(message.contains("token budget"))
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testEnablingBudgetKeepsTimedOutRequestOnTheSessionMeterUntilCleanupEnds() async throws {
        let log = try reliabilityLog("budget-in-place-reconfigure-\(UUID().uuidString)")
        let firstWorkspace = try reliabilityWorkspace()
        let secondWorkspace = try reliabilityWorkspace()
        defer {
            try? FileManager.default.removeItem(at: firstWorkspace)
            try? FileManager.default.removeItem(at: secondWorkspace)
        }
        let mainAgent = main
        let secondAgent = AgentID(rawValue: "budget-second")
        let firstProvider = ReliabilityBlockingProvider(blockingSeconds: 0.75)
        let secondProvider = ReliabilityCapturingProvider()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(
                maxConcurrentTasks: 2,
                taskTimeoutSeconds: 0.05,
                tokenBudget: nil)) { agent in
                    if agent.name == mainAgent { return firstProvider }
                    return secondProvider
                }
        let firstAttached = await orchestrator.attach(Agent(
            name: mainAgent,
            workspaceRoot: firstWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let secondAttached = await orchestrator.attach(Agent(
            name: secondAgent,
            workspaceRoot: secondWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(firstAttached)
        XCTAssertTrue(secondAttached)

        let firstSend = Task {
            await orchestrator.send(
                "start while disabled and unwind after timeout cancellation",
                to: mainAgent)
        }
        for _ in 0..<200 where firstProvider.requestCount == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(firstProvider.requestCount, 1)
        XCTAssertNil(firstProvider.requests.first?.maxOutputTokens)
        // The watchdog has fired, but structured timeout cleanup keeps the
        // scheduler task non-terminal until this finite blocking provider
        // unwinds. A permanently synchronous provider is outside the runtime
        // contract and would intentionally keep the task non-terminal.
        try await Task.sleep(nanoseconds: 100_000_000)

        let outstanding = await orchestrator.tokenBudgetSnapshotForTesting()
        XCTAssertNil(outstanding.limit)
        XCTAssertEqual(outstanding.consumed, 0)
        XCTAssertGreaterThan(outstanding.reserved, 0)
        XCTAssertNil(outstanding.remaining)

        // Enabling must mutate the same actor. The request whose outer timeout
        // already fired still owns its tracking reservation, so the new limit is
        // unavailable rather than becoming a fresh second pool.
        await orchestrator.updateExecutionPolicy(CoworkExecutionPolicy(
            maxConcurrentTasks: 2,
            taskTimeoutSeconds: 0.05,
            tokenBudget: outstanding.reserved))
        let enabled = await orchestrator.tokenBudgetSnapshotForTesting()
        XCTAssertEqual(enabled.limit, outstanding.reserved)
        XCTAssertEqual(enabled.reserved, outstanding.reserved)
        XCTAssertEqual(enabled.remaining, 0)

        guard case .failed(let blockedMessage) = await orchestrator.send(
            "must not double-spend the in-flight reservation",
            to: secondAgent) else {
            return XCTFail("the in-flight disabled-era request must block a new dispatch")
        }
        XCTAssertTrue(blockedMessage.lowercased().contains("budget"))
        XCTAssertTrue(secondProvider.requests.isEmpty)

        guard case .failed(let firstMessage) = await firstSend.value else {
            return XCTFail("the timed-out request must fail after cleanup ends")
        }
        XCTAssertTrue(firstMessage.lowercased().contains("timed out"))

        var settled = await orchestrator.tokenBudgetSnapshotForTesting()
        for _ in 0..<300 where settled.reserved != 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
            settled = await orchestrator.tokenBudgetSnapshotForTesting()
        }
        XCTAssertEqual(settled.reserved, 0, "the timed-out request must settle exactly once")
        XCTAssertGreaterThan(settled.consumed, 0)
        XCTAssertEqual(firstProvider.requestCount, 1)

        // Raising the same actor's limit after settlement must admit work again,
        // proving the old reservation was neither leaked nor forgotten.
        await orchestrator.updateExecutionPolicy(CoworkExecutionPolicy(
            maxConcurrentTasks: 2,
            taskTimeoutSeconds: 0.05,
            tokenBudget: settled.consumed + 10_000))
        let finalSend = await orchestrator.send(
            "run after the old reservation settles",
            to: secondAgent)
        XCTAssertEqual(finalSend, .sent)
        XCTAssertEqual(secondProvider.requests.count, 1)
        XCTAssertNotNil(secondProvider.requests.first?.maxOutputTokens)
        let final = await orchestrator.tokenBudgetSnapshotForTesting()
        XCTAssertEqual(final.reserved, 0)
        XCTAssertGreaterThan(final.consumed, settled.consumed)
    }

    func testPolicyUpdateAndCancelAllKeepSchedulerSuspendedUntilBothOwnersRelease() async throws {
        let log = try reliabilityLog("budget-update-cancel-all-\(UUID().uuidString)")
        let firstWorkspace = try reliabilityWorkspace()
        let secondWorkspace = try reliabilityWorkspace()
        defer {
            try? FileManager.default.removeItem(at: firstWorkspace)
            try? FileManager.default.removeItem(at: secondWorkspace)
        }
        let mainAgent = main
        let secondAgent = AgentID(rawValue: "budget-after-cancel")
        let concurrencyProbe = ReliabilityConcurrencyProbe()
        let firstProvider = ReliabilityDelayedProvider(
            agent: mainAgent,
            delayNanoseconds: 5_000_000_000,
            probe: concurrencyProbe)
        let secondProvider = ReliabilityCapturingProvider()
        let cancelResumeGate = ReliabilityTaskStartGate()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(
                maxConcurrentTasks: 2,
                taskTimeoutSeconds: 10,
                tokenBudget: 100_000)) { agent in
                    if agent.name == mainAgent { return firstProvider }
                    return secondProvider
                }
        await orchestrator.setCancelAllBeforeResumeHook {
            await cancelResumeGate.pause()
        }
        let firstAttached = await orchestrator.attach(Agent(
            name: mainAgent,
            workspaceRoot: firstWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let secondAttached = await orchestrator.attach(Agent(
            name: secondAgent,
            workspaceRoot: secondWorkspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(firstAttached)
        XCTAssertTrue(secondAttached)

        let firstSend = Task { await orchestrator.send("cancel during policy drain", to: mainAgent) }
        for _ in 0..<200 where firstProvider.requestCount == 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(firstProvider.requestCount, 1)

        let policyUpdate = Task {
            await orchestrator.updateExecutionPolicy(CoworkExecutionPolicy(
                maxConcurrentTasks: 2,
                taskTimeoutSeconds: 10,
                tokenBudget: 200_000))
        }
        for _ in 0..<200 {
            if await orchestrator.isExecutionPolicyUpdateInProgress() { break }
            await Task.yield()
        }
        let cancelAll = Task {
            await orchestrator.cancelAll(reason: "overlapping policy update")
        }
        await cancelResumeGate.waitUntilEntered()

        // The policy owner can finish first, but its resume request must remain
        // pending while cancelAll still owns a separate suspension token.
        await policyUpdate.value
        let secondSend = Task {
            await orchestrator.send("run only after cancelAll releases", to: secondAgent)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(secondProvider.requests.isEmpty)

        await cancelResumeGate.release()
        await cancelAll.value
        let secondResult = await secondSend.value
        XCTAssertEqual(secondResult, .sent)
        XCTAssertEqual(secondProvider.requests.count, 1)
        guard case .failed = await firstSend.value else {
            return XCTFail("cancelAll must cancel the old-meter task")
        }
    }

    func testTimeoutAndIterationExhaustionAreFailedNeverCompleted() async throws {
        let timeoutLog = try reliabilityLog("timeout-\(UUID().uuidString)")
        let timeoutWorkspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: timeoutWorkspace) }
        let probe = ReliabilityConcurrencyProbe()
        let timeoutOrchestrator = Orchestrator(
            log: timeoutLog,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(taskTimeoutSeconds: 1)) { agent in
                ReliabilityDelayedProvider(
                    agent: agent.name,
                    delayNanoseconds: 5_000_000_000,
                    probe: probe)
            }
        let timeoutAttached = await timeoutOrchestrator.attach(Agent(
            name: main, workspaceRoot: timeoutWorkspace, model: ModelID(rawValue: "m"),
            profile: .reviewed, coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(timeoutAttached)
        guard case .failed(let timeoutMessage) = await timeoutOrchestrator.send("time out", to: main) else {
            return XCTFail("timeout must fail")
        }
        XCTAssertTrue(timeoutMessage.lowercased().contains("timed out"))
        let timeoutProjection = CoworkProjection.build(from: await timeoutLog.replay())
        XCTAssertEqual(timeoutProjection.failedTasks.count, 1)
        XCTAssertTrue(timeoutProjection.completedTasks.isEmpty)

        let iterationLog = try reliabilityLog("iteration-\(UUID().uuidString)")
        let iterationWorkspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: iterationWorkspace) }
        let iterationOrchestrator = Orchestrator(
            log: iterationLog,
            allowsShell: true,
            responder: FixedResponder(.allow),
            maxSteps: 1) { _ in ReliabilityEndlessToolProvider() }
        let iterationAttached = await iterationOrchestrator.attach(Agent(
            name: main, workspaceRoot: iterationWorkspace, model: ModelID(rawValue: "m"),
            profile: .reviewed, coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(iterationAttached)
        guard case .failed(let iterationMessage) = await iterationOrchestrator.send("never complete", to: main) else {
            return XCTFail("iteration exhaustion must fail")
        }
        XCTAssertTrue(iterationMessage.contains("maximum of 1"))
        let iterationProjection = CoworkProjection.build(from: await iterationLog.replay())
        XCTAssertEqual(iterationProjection.failedTasks.count, 1)
        XCTAssertTrue(iterationProjection.completedTasks.isEmpty)
    }

    func testTimeoutWaitsForProviderCleanupBeforeTaskSettlement() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReliabilityBlockingProvider(blockingSeconds: 0.5)
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(taskTimeoutSeconds: 0.05)) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)

        let started = Date()
        let result = await orchestrator.send("timeout then await provider cleanup", to: main)
        let elapsed = Date().timeIntervalSince(started)

        guard case .failed(let message) = result else {
            return XCTFail("the bounded watchdog must fail after cleanup")
        }
        XCTAssertTrue(message.lowercased().contains("timed out"))
        XCTAssertGreaterThanOrEqual(elapsed, 0.45)
        XCTAssertLessThan(elapsed, 1.5)
        XCTAssertEqual(provider.requestCount, 1)
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(projection.failedTasks.count, 1)
        XCTAssertTrue(projection.completedTasks.isEmpty)
    }

    func testProviderCancellationErrorIsRuntimeFailureWhenTaskWasNotCancelled() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in
                ReliabilitySelfCancellingProvider()
            }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)

        guard case .failed = await orchestrator.send(
            "provider reports its own cancellation",
            to: main) else {
            return XCTFail("provider-originated CancellationError must be a runtime failure")
        }

        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(projection.failedTasks.count, 1)
        XCTAssertTrue(projection.cancelledTasks.isEmpty)
    }

    func testCancelAllWaitsForDataPlaneCleanupBeforeCancelledTerminal() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ReliabilityBlockingProvider(blockingSeconds: 0.5)
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow),
            executionPolicy: CoworkExecutionPolicy(taskTimeoutSeconds: 10)) { _ in
                provider
            }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)

        let sendTask = Task {
            await orchestrator.send("cancel then await finite cleanup", to: main)
        }
        for _ in 0..<200 where provider.requestCount == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(provider.requestCount, 1)

        let started = Date()
        await orchestrator.cancelAll(reason: "phase C cleanup test")
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertGreaterThanOrEqual(elapsed, 0.4)
        XCTAssertLessThan(elapsed, 1.5)
        guard case .failed = await sendTask.value else {
            return XCTFail("cancelAll must settle the task as cancelled after cleanup")
        }
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(projection.cancelledTasks.count, 1)
        XCTAssertTrue(projection.completedTasks.isEmpty)
    }

    func testCancelAllDrainsDataPlaneBeforeShuttingDownPermissionReviewer() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mainProvider = ReliabilityWriteThenFinalProvider()
        let reviewerProbe = ReliabilityConcurrencyProbe()
        let reviewerProvider = ReliabilityDelayedProvider(
            agent: Orchestrator.automaticPermissionReviewerID,
            delayNanoseconds: 5_000_000_000,
            response: "late allow\nALLOW",
            probe: reviewerProbe)
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { agent -> ToolCallingProvider in
                if agent.name == Orchestrator.automaticPermissionReviewerID {
                    return reviewerProvider
                }
                return mainProvider
            }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        let enableResult = await orchestrator.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer"),
            workspaceRoot: workspace)
        XCTAssertEqual(
            enableResult,
            AutomaticPermissionReviewResult.enabled(
                Orchestrator.automaticPermissionReviewerID))

        let sendTask = Task {
            await orchestrator.send(
                "request a reviewed write",
                to: main,
                userMessage: UserMessagePayload(
                    text: "request a reviewed write",
                    submissionID: SubmissionID(
                        rawValue: "sub_cancel_before_reviewer_shutdown")))
        }
        for _ in 0..<400 where reviewerProvider.requestCount == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(reviewerProvider.requestCount, 1)

        await orchestrator.cancelAll(reason: "phase C session stop")

        guard case .failed = await sendTask.value else {
            return XCTFail("cancelAll must interrupt the running data-plane task")
        }
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(projection.cancelledTasks.count, 1)
        XCTAssertTrue(projection.completedTasks.isEmpty)
        XCTAssertEqual(
            mainProvider.requestCount,
            1,
            "reviewer shutdown must not release a denial that lets the cancelled turn continue after its same-generation authorization sidecar")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("phase-c.txt").path))
    }

    func testRestoreRequeuesInterruptedAttemptAndCompletesNextAttempt() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let workspaceLease = WorkspaceLease(rootPath: workspace.path, access: .readWrite)
        let capabilityLease = CapabilityLease.coordinator()
        let taskID = TaskID.new()
        let contract = TaskContract(
            id: taskID,
            kind: .root,
            issuer: nil,
            assignee: main,
            objective: "resume after crash",
            roleHint: "root coordinator",
            expectedDeliverable: "recovered result",
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            replyMode: TaskReplyMode.none,
            executionTimeoutSeconds: 10,
            maxAttempts: 3)
        let metadata = CoworkEventMetadata(
            taskID: taskID,
            rootTaskID: taskID,
            agentID: main,
            assignee: main,
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            scope: .task)
        try await log.append(.agentAttached(AgentAttachedPayload(
            agent: main,
            path: workspace.path,
            model: ModelID(rawValue: "m"),
            profile: PermissionProfile.reviewed.rawValue)))
        try await log.append(.workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
            agent: main,
            lease: workspaceLease)))
        try await log.append(.capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
            agent: main,
            lease: capabilityLease)))
        try await log.append(.taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)))
        try await log.append(.taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)))
        try await log.append(.taskQueued(TaskQueuedPayload(
            contract: contract,
            rootTaskID: taskID,
            assignee: main,
            hopCount: 0,
            visitedAgents: [main],
            attempt: 1,
            metadata: metadata)))
        try await log.append(.taskStarted(TaskStartedPayload(
            taskID: taskID,
            agent: main,
            attempt: 1,
            metadata: metadata)))

        let restoredProjection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(restoredProjection.tasks[taskID]?.status, .running)
        let restored = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in ReliabilityFinalProvider(text: "recovered") }
        await restored.restore(from: restoredProjection)
        await restored.resumePendingTasks()
        await restored.runSchedulerUntilIdle()

        let events = await log.replay()
        let projection = CoworkProjection.build(from: events)
        XCTAssertEqual(projection.tasks[taskID]?.status, .completed)
        XCTAssertEqual(projection.tasks[taskID]?.attempt, 2)
        XCTAssertEqual(projection.tasks[taskID]?.result, "recovered")
        let attempts = events.compactMap { envelope -> Int? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.id == taskID else { return nil }
            return payload.attempt
        }
        XCTAssertEqual(attempts, [1, 2])
    }

    func testHistoricalRestoreKeepsRecoveredTaskPausedUntilExactRetry() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let workspaceLease = WorkspaceLease(rootPath: workspace.path, access: .readWrite)
        let capabilityLease = CapabilityLease.coordinator()
        let taskID = TaskID.new()
        let submissionID = SubmissionID(rawValue: "sub_restored_exact_retry")
        let userMessage = UserMessagePayload(
            text: "resume only when I explicitly retry",
            submissionID: submissionID)
        let contract = TaskContract(
            id: taskID,
            kind: .root,
            issuer: nil,
            assignee: main,
            submissionID: submissionID,
            objective: userMessage.text,
            roleHint: "root coordinator",
            expectedDeliverable: "recovered result",
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            replyMode: TaskReplyMode.none,
            executionTimeoutSeconds: 10,
            maxAttempts: 3)
        let metadata = CoworkEventMetadata(
            taskID: taskID,
            rootTaskID: taskID,
            agentID: main,
            assignee: main,
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            scope: .task)
        try await log.append(.userMessage(userMessage))
        try await log.append(.agentAttached(AgentAttachedPayload(
            agent: main,
            path: workspace.path,
            model: ModelID(rawValue: "m"),
            profile: PermissionProfile.reviewed.rawValue)))
        try await log.append(.workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
            agent: main,
            lease: workspaceLease)))
        try await log.append(.capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
            agent: main,
            lease: capabilityLease)))
        try await log.append(.taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)))
        try await log.append(.taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)))
        try await log.append(.taskQueued(TaskQueuedPayload(
            contract: contract,
            rootTaskID: taskID,
            assignee: main,
            hopCount: 0,
            visitedAgents: [main],
            attempt: 1,
            metadata: metadata)))
        try await log.append(.taskStarted(TaskStartedPayload(
            taskID: taskID,
            agent: main,
            attempt: 1,
            metadata: metadata)))

        let provider = ReliabilityCapturingProvider()
        let restored = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        await restored.restore(from: CoworkProjection.build(from: await log.replay()))
        let startedNewTasks = await restored.startNewTasksKeepingRestoredTasksPaused()
        XCTAssertTrue(startedNewTasks)

        let newResult = await restored.send("new work after reopening", to: main)
        XCTAssertEqual(newResult, .sent)
        XCTAssertEqual(provider.requests.count, 1)

        let pausedProjection = CoworkProjection.build(from: await log.replay())
        let pausedTask = try XCTUnwrap(pausedProjection.tasks[taskID])
        XCTAssertEqual(pausedTask.status, .queued)
        XCTAssertEqual(pausedTask.attempt, 2)

        let retryResult = await restored.retry(
            pausedTask,
            userMessage: userMessage,
            recordUserMessage: false)
        XCTAssertEqual(retryResult, .sent)
        XCTAssertEqual(provider.requests.count, 2)

        let finalEvents = await log.replay()
        let finalProjection = CoworkProjection.build(from: finalEvents)
        XCTAssertEqual(finalProjection.tasks[taskID]?.status, .completed)
        XCTAssertEqual(finalProjection.tasks[taskID]?.attempt, 2)
        let originalSubmissionMessages = finalEvents.filter { envelope in
            guard case .userMessage(let payload) = envelope.event else { return false }
            return payload.submissionID == submissionID
        }
        XCTAssertEqual(originalSubmissionMessages.count, 1)
    }

    func testRestoreDoesNotReplayUnsettledNonReplayableToolExecution() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID.new()
        let workspaceLease = WorkspaceLease(
            taskID: taskID,
            rootPath: workspace.path,
            access: .readWrite)
        let capabilityLease = CapabilityLease.coordinator(taskID: taskID)
        let contract = TaskContract(
            id: taskID,
            kind: .root,
            issuer: nil,
            assignee: main,
            objective: "do not duplicate the interrupted write",
            roleHint: "root coordinator",
            expectedDeliverable: "start a new run",
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            replyMode: TaskReplyMode.none,
            maxAttempts: 3)
        let metadata = CoworkEventMetadata(
            taskID: taskID,
            rootTaskID: taskID,
            agentID: main,
            assignee: main,
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            scope: .task)
        try await log.append([
            .agentAttached(AgentAttachedPayload(
                agent: main,
                path: workspace.path,
                model: ModelID(rawValue: "m"),
                profile: PermissionProfile.reviewed.rawValue)),
            .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                agent: main,
                lease: workspaceLease)),
            .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                agent: main,
                lease: capabilityLease)),
            .taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)),
            .taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)),
            .taskQueued(TaskQueuedPayload(
                contract: contract,
                rootTaskID: taskID,
                assignee: main,
                hopCount: 0,
                visitedAgents: [main],
                attempt: 1,
                metadata: metadata)),
            .taskStarted(TaskStartedPayload(
                taskID: taskID,
                agent: main,
                attempt: 1,
                metadata: metadata)),
            .toolExecutionPrepared(ToolExecutionPreparedPayload(
                executionID: "interrupted-write",
                taskID: taskID,
                attempt: 1,
                toolCallID: "write-call",
                agent: main,
                tool: "write_file",
                sideEffect: .write)),
        ])

        let provider = ReliabilityCapturingProvider()
        let restored = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        await restored.restore(from: CoworkProjection.build(from: await log.replay()))
        await restored.resumePendingTasks()
        await restored.runSchedulerUntilIdle()

        XCTAssertTrue(provider.requests.isEmpty)
        let events = await log.replay()
        let projection = CoworkProjection.build(from: events)
        XCTAssertEqual(projection.tasks[taskID]?.status, .failed)
        XCTAssertEqual(projection.tasks[taskID]?.attempt, 1)
        XCTAssertTrue(projection.tasks[taskID]?.error?.contains("start a new run") == true)
        let queuedAttempts = events.compactMap { envelope -> Int? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.id == taskID else { return nil }
            return payload.attempt
        }
        XCTAssertEqual(queuedAttempts, [1])
    }


    func testRestoreDoesNotReplayTaskAfterSettledSuccessfulNonReplayableExecution() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID(rawValue: "running-after-settled-write")
        try await appendReliabilityTaskWithSettledSideEffect(
            to: log,
            workspace: workspace,
            taskID: taskID,
            agent: main,
            terminalStatus: nil)

        let provider = ReliabilityCapturingProvider()
        let restored = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        await restored.restore(from: CoworkProjection.build(from: await log.replay()))
        await restored.resumePendingTasks()
        await restored.runSchedulerUntilIdle()

        XCTAssertTrue(provider.requests.isEmpty)
        let events = await log.replay()
        let projection = CoworkProjection.build(from: events)
        XCTAssertEqual(projection.tasks[taskID]?.status, .failed)
        XCTAssertEqual(projection.tasks[taskID]?.attempt, 1)
        XCTAssertTrue(projection.tasks[taskID]?.error?.contains("start a new run") == true)
        let queuedAttempts = events.compactMap { envelope -> Int? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.id == taskID else { return nil }
            return payload.attempt
        }
        XCTAssertEqual(queuedAttempts, [1])
    }

    func testRetryRejectsFailedTaskWithUnsettledNonReplayableExecution() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID.new()
        let workspaceLease = WorkspaceLease(
            taskID: taskID,
            rootPath: workspace.path,
            access: .readWrite)
        let capabilityLease = CapabilityLease.coordinator(taskID: taskID)
        let contract = TaskContract(
            id: taskID,
            kind: .root,
            issuer: nil,
            assignee: main,
            objective: "do not retry an uncertain write",
            roleHint: "root coordinator",
            expectedDeliverable: "start a new run",
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            replyMode: TaskReplyMode.none,
            maxAttempts: 3)
        let metadata = CoworkEventMetadata(
            taskID: taskID,
            rootTaskID: taskID,
            agentID: main,
            assignee: main,
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            scope: .task)
        try await log.append([
            .agentAttached(AgentAttachedPayload(
                agent: main,
                path: workspace.path,
                model: ModelID(rawValue: "m"),
                profile: PermissionProfile.reviewed.rawValue)),
            .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                agent: main,
                lease: workspaceLease)),
            .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                agent: main,
                lease: capabilityLease)),
            .taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)),
            .taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)),
            .taskQueued(TaskQueuedPayload(
                contract: contract,
                rootTaskID: taskID,
                assignee: main,
                hopCount: 0,
                visitedAgents: [main],
                attempt: 1,
                metadata: metadata)),
            .taskStarted(TaskStartedPayload(
                taskID: taskID,
                agent: main,
                attempt: 1,
                metadata: metadata)),
            .toolExecutionPrepared(ToolExecutionPreparedPayload(
                executionID: "failed-uncertain-write",
                taskID: taskID,
                attempt: 1,
                toolCallID: "write-call",
                agent: main,
                tool: "write_file",
                sideEffect: .write)),
            .taskFailed(TaskFailedPayload(
                taskID: taskID,
                agent: main,
                error: "tool completion audit failed",
                attempt: 1,
                metadata: metadata)),
        ])

        let provider = ReliabilityCapturingProvider()
        let restored = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        let initialProjection = CoworkProjection.build(from: await log.replay())
        await restored.restore(from: initialProjection)
        let failedView = try XCTUnwrap(initialProjection.tasks[taskID])

        let result = await restored.retry(failedView)

        guard case .failed(let message) = result else {
            return XCTFail("Retry must be blocked starting a new run.")
        }
        XCTAssertTrue(message.contains("start a new run"))
        XCTAssertTrue(provider.requests.isEmpty)
        let queuedAttempts = await log.replay().compactMap { envelope -> Int? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.id == taskID else { return nil }
            return payload.attempt
        }
        XCTAssertEqual(queuedAttempts, [1])
    }

    func testRetryRejectsFailedOrCancelledTaskAfterSettledSuccessfulNonReplayableExecution() async throws {
        for terminalStatus in [TaskStatus.failed, .cancelled] {
            let log = try reliabilityLog()
            let workspace = try reliabilityWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let taskID = TaskID(rawValue: "\(terminalStatus.rawValue)-after-settled-write")
            try await appendReliabilityTaskWithSettledSideEffect(
                to: log,
                workspace: workspace,
                taskID: taskID,
                agent: main,
                terminalStatus: terminalStatus)

            let provider = ReliabilityCapturingProvider()
            let restored = Orchestrator(
                log: log,
                allowsShell: true,
                responder: FixedResponder(.allow)) { _ in provider }
            let initialProjection = CoworkProjection.build(from: await log.replay())
            await restored.restore(from: initialProjection)
            let terminalView = try XCTUnwrap(initialProjection.tasks[taskID])

            let result = await restored.retry(terminalView)

            guard case .failed(let message) = result else {
                return XCTFail("Retry must be blocked after a settled non-replayable execution.")
            }
            XCTAssertTrue(message.contains("start a new run"))
            XCTAssertTrue(provider.requests.isEmpty)
            let queuedAttempts = await log.replay().compactMap { envelope -> Int? in
                guard case .taskQueued(let payload) = envelope.event,
                      payload.contract.id == taskID else { return nil }
                return payload.attempt
            }
            XCTAssertEqual(queuedAttempts, [1])
        }
    }

    func testRetryFailsClosedWhenDurableSideEffectHistoryCannotBeVerified() async throws {
        let name = "retry-corrupt-history-\(UUID().uuidString)"
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-reliability-\(name)", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let log = try reliabilityLog(name)
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID(rawValue: "retry-corrupt-history")
        try await appendReliabilityTaskWithSettledSideEffect(
            to: log,
            workspace: workspace,
            taskID: taskID,
            agent: main,
            terminalStatus: .failed)

        let provider = ReliabilityCapturingProvider()
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        let initialProjection = CoworkProjection.build(from: try await log.replayChecked())
        await orchestrator.restore(from: initialProjection)
        let failedView = try XCTUnwrap(initialProjection.tasks[taskID])

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"invalid\":true}\n".utf8))
        try handle.synchronize()
        try handle.close()

        let result = await orchestrator.retry(failedView)

        guard case .failed(let message) = result else {
            return XCTFail("Retry must fail closed when durable history is corrupt.")
        }
        XCTAssertTrue(message.contains("could not be verified"))
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testRetryFailsClosedOnUnknownFutureEventOrSequenceGap() async throws {
        for scenario in ["unknown-future", "sequence-gap"] {
            let name = "retry-\(scenario)-\(UUID().uuidString)"
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("intatis-reliability-\(name)", isDirectory: true)
                .appendingPathComponent("events.jsonl")
            defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
            let log = try reliabilityLog(name)
            let workspace = try reliabilityWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let taskID = TaskID(rawValue: "retry-\(scenario)")
            try await appendReliabilityTaskWithSettledSideEffect(
                to: log,
                workspace: workspace,
                taskID: taskID,
                agent: main,
                terminalStatus: .failed,
                outcome: .failed,
                effectDisposition: .notStarted)

            let provider = ReliabilityCapturingProvider()
            let orchestrator = Orchestrator(
                log: log,
                allowsShell: true,
                responder: FixedResponder(.allow)) { _ in provider }
            let knownEvents = try await log.replayChecked()
            let initialProjection = CoworkProjection.build(from: knownEvents)
            await orchestrator.restore(from: initialProjection)
            let failedView = try XCTUnwrap(initialProjection.tasks[taskID])

            let nextSequence = try XCTUnwrap(knownEvents.last?.seq)
                + (scenario == "sequence-gap" ? 2 : 1)
            let encoder = Envelope.makeEncoder()
            let placeholder = try encoder.encode(Envelope(
                seq: nextSequence,
                ts: Date(timeIntervalSince1970: Double(nextSequence)),
                session: await log.sessionID,
                event: .userMessage(.init(text: "placeholder"))))
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: placeholder) as? [String: Any])
            if scenario == "unknown-future" {
                object["type"] = "future_retry_reconciliation_event"
                object["payload"] = ["futureField": true]
            }
            var raw = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            raw.append(0x0A)
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: raw)
            try handle.close()

            let result = await orchestrator.retry(failedView)

            guard case .failed(let message) = result else {
                XCTFail("\(scenario) must keep retry fail-closed")
                continue
            }
            XCTAssertTrue(message.contains("could not be verified"), scenario)
            XCTAssertTrue(provider.requests.isEmpty, scenario)
        }
    }

    func testRestoreAtMaxAttemptFailsAtLastActualAttemptWithoutPhantomRetry() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID.new()
        let contract = TaskContract(
            id: taskID,
            kind: .root,
            issuer: nil,
            assignee: main,
            objective: "do not replay",
            roleHint: "root",
            expectedDeliverable: "result",
            replyMode: TaskReplyMode.none,
            executionTimeoutSeconds: 10,
            maxAttempts: 2)
        let metadata = CoworkEventMetadata(
            taskID: taskID,
            rootTaskID: taskID,
            agentID: main,
            assignee: main,
            scope: .task)
        try await log.append(.agentAttached(AgentAttachedPayload(
            agent: main,
            path: workspace.path,
            model: ModelID(rawValue: "m"),
            profile: PermissionProfile.reviewed.rawValue)))
        try await log.append(.taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)))
        try await log.append(.taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)))
        try await log.append(.taskQueued(TaskQueuedPayload(
            contract: contract,
            rootTaskID: taskID,
            assignee: main,
            hopCount: 0,
            visitedAgents: [main],
            attempt: 2,
            metadata: metadata)))
        try await log.append(.taskStarted(TaskStartedPayload(
            taskID: taskID,
            agent: main,
            attempt: 2,
            metadata: metadata)))

        let provider = ReliabilityCapturingProvider()
        let restored = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        await restored.restore(from: CoworkProjection.build(from: await log.replay()))
        await restored.resumePendingTasks()
        await restored.runSchedulerUntilIdle()

        XCTAssertTrue(provider.requests.isEmpty)
        let events = await log.replay()
        let queuedAttempts = events.compactMap { envelope -> Int? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.id == taskID else { return nil }
            return payload.attempt
        }
        let startedAttempts = events.compactMap { envelope -> Int? in
            guard case .taskStarted(let payload) = envelope.event,
                  payload.taskID == taskID else { return nil }
            return payload.attempt
        }
        let failedAttempts = events.compactMap { envelope -> Int? in
            guard case .taskFailed(let payload) = envelope.event,
                  payload.taskID == taskID else { return nil }
            return payload.attempt
        }
        XCTAssertEqual(queuedAttempts, [2])
        XCTAssertEqual(startedAttempts, [2])
        XCTAssertEqual(failedAttempts, [2])
        let projection = CoworkProjection.build(from: events)
        XCTAssertEqual(projection.tasks[taskID]?.status, .failed)
        XCTAssertEqual(projection.tasks[taskID]?.attempt, 2)
    }

    func testRestoreRetriesFailedExactMailboxDeliveryOnTheSameTaskID() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sender = AgentID(rawValue: "sender")
        let messageID = MessageID(rawValue: "mail_exact_retry")
        let taskID = TaskID(rawValue: "task_exact_retry")
        let capabilityLease = CapabilityLease(
            id: CapabilityLeaseID(rawValue: "clease_exact_retry"),
            taskID: taskID,
            tools: [],
            communication: .none,
            delegation: .none,
            expiresAtTaskCompletion: true)
        let workspaceLease = WorkspaceLease(
            id: WorkspaceLeaseID(rawValue: "wlease_exact_retry"),
            workspaceID: WorkspaceID(rawValue: "workspace_exact_retry"),
            taskID: taskID,
            rootPath: workspace.path,
            access: .readOnly,
            expiresAtTaskCompletion: true)
        try await log.append(.agentAttached(AgentAttachedPayload(
            agent: main,
            path: workspace.path,
            model: ModelID(rawValue: "m"),
            profile: PermissionProfile.reviewed.rawValue)))
        try await log.append(.agentAttached(AgentAttachedPayload(
            agent: sender,
            path: workspace.path,
            model: ModelID(rawValue: "m"),
            profile: PermissionProfile.reviewed.rawValue)))
        try await log.append(.agentMessage(AgentMessagePayload(
            from: sender,
            to: main,
            content: "retry this exact delivery",
            kind: .sendMessage,
            messageId: messageID)))
        let contract = TaskContract(
            id: taskID,
            kind: .mailboxDelivery,
            issuer: sender,
            assignee: main,
            objective: "Handle exact message.",
            roleHint: "mailbox responder",
            expectedDeliverable: "communication outcome",
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            mailboxMessageIDs: [messageID],
            replyMode: TaskReplyMode.none,
            maxAttempts: 3)
        try await log.append(.capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
            agent: main,
            lease: capabilityLease)))
        try await log.append(.workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
            agent: main,
            lease: workspaceLease)))
        try await log.append(.taskCreated(TaskCreatedPayload(contract: contract)))
        try await log.append(.taskAssigned(TaskAssignedPayload(contract: contract)))
        try await log.append(.taskQueued(TaskQueuedPayload(
            contract: contract,
            rootTaskID: taskID,
            issuer: sender,
            assignee: main,
            hopCount: 0,
            visitedAgents: [main],
            attempt: 2,
            reason: "mailbox delivery")))
        try await log.append(.taskStarted(TaskStartedPayload(
            taskID: taskID,
            agent: main,
            attempt: 2)))
        try await log.append(.taskFailed(TaskFailedPayload(
            taskID: taskID,
            agent: main,
            error: "forced second-attempt failure",
            attempt: 2)))
        try await log.append(.capabilityLeaseRevoked(CapabilityLeaseRevokedPayload(
            agent: main,
            leaseID: capabilityLease.id,
            reason: "task failed")))
        try await log.append(.workspaceLeaseRevoked(WorkspaceLeaseRevokedPayload(
            agent: main,
            leaseID: workspaceLease.id,
            reason: "task failed")))

        let provider = ReliabilityCapturingProvider()
        let restored = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        await restored.restore(from: CoworkProjection.build(from: await log.replay()))
        let resumed = await restored.resumePendingTasks()
        XCTAssertTrue(resumed)
        await restored.runSchedulerUntilIdle()

        XCTAssertEqual(provider.requests.count, 1)
        let events = await log.replay()
        let mailboxTaskIDs = events.compactMap { envelope -> TaskID? in
            guard case .taskCreated(let payload) = envelope.event,
                  payload.contract.kind == .mailboxDelivery else { return nil }
            return payload.contract.id
        }
        let queuedAttempts = events.compactMap { envelope -> Int? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.id == taskID else { return nil }
            return payload.attempt
        }
        let consumed = events.compactMap { envelope -> AgentMessageConsumedPayload? in
            guard case .agentMessageConsumed(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(mailboxTaskIDs, [taskID])
        XCTAssertEqual(queuedAttempts, [2, 3])
        XCTAssertEqual(consumed.map(\.messageID), [messageID])
        XCTAssertEqual(consumed.map(\.taskID), [taskID])
        let pendingMessages = await restored.mailbox(for: main).pendingMessages
        XCTAssertTrue(pendingMessages.isEmpty)
    }

    func testRestoreDoesNotDuplicateQueuedExactMailboxDelivery() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sender = AgentID(rawValue: "sender")
        let messageID = MessageID(rawValue: "mail_exact_active")
        let taskID = TaskID(rawValue: "task_exact_active")
        try await log.append(.agentAttached(AgentAttachedPayload(
            agent: main,
            path: workspace.path,
            model: ModelID(rawValue: "m"),
            profile: PermissionProfile.reviewed.rawValue)))
        try await log.append(.agentAttached(AgentAttachedPayload(
            agent: sender,
            path: workspace.path,
            model: ModelID(rawValue: "m"),
            profile: PermissionProfile.reviewed.rawValue)))
        try await log.append(.agentMessage(AgentMessagePayload(
            from: sender,
            to: main,
            content: "already bound",
            kind: .sendMessage,
            messageId: messageID)))
        let contract = TaskContract(
            id: taskID,
            kind: .mailboxDelivery,
            issuer: sender,
            assignee: main,
            objective: "Handle exact message.",
            roleHint: "mailbox responder",
            expectedDeliverable: "communication outcome",
            mailboxMessageIDs: [messageID],
            replyMode: TaskReplyMode.none,
            maxAttempts: 3)
        try await log.append(.taskCreated(TaskCreatedPayload(contract: contract)))
        try await log.append(.taskAssigned(TaskAssignedPayload(contract: contract)))
        try await log.append(.taskQueued(TaskQueuedPayload(
            contract: contract,
            rootTaskID: taskID,
            issuer: sender,
            assignee: main,
            hopCount: 0,
            visitedAgents: [main],
            attempt: 1,
            reason: "mailbox delivery")))

        let provider = ReliabilityCapturingProvider()
        let restored = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        await restored.restore(from: CoworkProjection.build(from: await log.replay()))

        let queued = await restored.queuedTasks().filter {
            $0.contract.kind == .mailboxDelivery
        }
        XCTAssertEqual(queued.map { $0.contract.id }, [taskID])
        let mailboxCreated = await log.replay().compactMap { envelope -> TaskID? in
            guard case .taskCreated(let payload) = envelope.event,
                  payload.contract.kind == .mailboxDelivery else { return nil }
            return payload.contract.id
        }
        XCTAssertEqual(mailboxCreated, [taskID])
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testRestoreTreatsExhaustedLegacyMailboxLineageAsOnePoisonDelivery() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sender = AgentID(rawValue: "sender")
        let messageID = MessageID(rawValue: "mail_legacy_poison")
        let causalTaskID = TaskID(rawValue: "task_legacy_causal")
        try await log.append(.agentAttached(AgentAttachedPayload(
            agent: main,
            path: workspace.path,
            model: ModelID(rawValue: "m"),
            profile: PermissionProfile.reviewed.rawValue)))
        try await log.append(.agentAttached(AgentAttachedPayload(
            agent: sender,
            path: workspace.path,
            model: ModelID(rawValue: "m"),
            profile: PermissionProfile.reviewed.rawValue)))
        let causal = TaskContract(
            id: causalTaskID,
            kind: .root,
            issuer: nil,
            assignee: sender,
            objective: "Produce a report.",
            roleHint: "worker",
            expectedDeliverable: "report")
        try await log.append(.taskCreated(TaskCreatedPayload(contract: causal)))
        try await log.append(.taskCompleted(TaskCompletedPayload(
            taskID: causalTaskID,
            agent: sender,
            result: "report")))
        try await log.append(.agentMessage(AgentMessagePayload(
            from: sender,
            to: main,
            content: "legacy completion report",
            kind: .sendMessage,
            messageId: messageID,
            taskID: causalTaskID)))

        let legacyTasks = [
            (TaskID(rawValue: "task_legacy_exhausted"), 3),
            (TaskID(rawValue: "task_legacy_replacement"), 1),
        ]
        for (legacyTaskID, attempt) in legacyTasks {
            let contract = TaskContract(
                id: legacyTaskID,
                kind: .mailboxDelivery,
                issuer: sender,
                assignee: main,
                objective: "Review and respond to pending mailbox messages.",
                roleHint: "mailbox responder",
                expectedDeliverable: "Handle the pending message.",
                relatedTasks: [causalTaskID],
                replyMode: TaskReplyMode.none,
                maxAttempts: 3)
            try await log.append(.taskCreated(TaskCreatedPayload(contract: contract)))
            try await log.append(.taskAssigned(TaskAssignedPayload(contract: contract)))
            try await log.append(.taskQueued(TaskQueuedPayload(
                contract: contract,
                rootTaskID: legacyTaskID,
                issuer: sender,
                assignee: main,
                causalParentID: causalTaskID,
                hopCount: 0,
                visitedAgents: [main],
                attempt: attempt,
                reason: "mailbox delivery")))
            try await log.append(.taskStarted(TaskStartedPayload(
                taskID: legacyTaskID,
                agent: main,
                attempt: attempt)))
            try await log.append(.taskFailed(TaskFailedPayload(
                taskID: legacyTaskID,
                agent: main,
                error: "forced legacy failure",
                attempt: attempt)))
        }

        let provider = ReliabilityCapturingProvider()
        let restored = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        await restored.restore(from: CoworkProjection.build(from: await log.replay()))
        await restored.resumePendingTasks()
        await restored.runSchedulerUntilIdle()

        XCTAssertTrue(provider.requests.isEmpty)
        let remainingQueue = await restored.queuedTasks()
        let pendingMessages = await restored.mailbox(for: main).pendingMessages
        XCTAssertTrue(remainingQueue.isEmpty)
        XCTAssertEqual(pendingMessages, [messageID])
        let mailboxTaskIDs = await log.replay().compactMap { envelope -> TaskID? in
            guard case .taskCreated(let payload) = envelope.event,
                  payload.contract.kind == .mailboxDelivery else { return nil }
            return payload.contract.id
        }
        XCTAssertEqual(mailboxTaskIDs, legacyTasks.map(\.0))
    }

    func testRestoreSynthesizesMailboxWakeAndConsumesOnlyProjectedBatches() async throws {
        let log = try reliabilityLog()
        let workspace = try reliabilityWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sender = AgentID(rawValue: "sender")
        try await log.append(.agentAttached(AgentAttachedPayload(
            agent: main,
            path: workspace.path,
            model: ModelID(rawValue: "m"),
            profile: PermissionProfile.reviewed.rawValue)))
        try await log.append(.agentAttached(AgentAttachedPayload(
            agent: sender,
            path: workspace.path,
            model: ModelID(rawValue: "m"),
            profile: PermissionProfile.reviewed.rawValue)))
        let messageIDs = (0..<10).map { MessageID(rawValue: "mail_\($0)") }
        for (index, messageID) in messageIDs.enumerated() {
            try await log.append(.agentMessage(AgentMessagePayload(
                from: sender,
                to: main,
                content: "pending message \(index)",
                kind: .sendMessage,
                messageId: messageID)))
        }

        let provider = ReliabilityCapturingProvider()
        let restored = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)) { _ in provider }
        await restored.restore(from: CoworkProjection.build(from: await log.replay()))
        let queuedBeforeResume = await restored.queuedTasks()
        XCTAssertEqual(queuedBeforeResume.filter { $0.contract.kind == .mailboxDelivery }.count, 1)
        XCTAssertTrue(provider.requests.isEmpty)

        await restored.resumePendingTasks()
        await restored.runSchedulerUntilIdle()

        XCTAssertEqual(provider.requests.count, 2, "ten messages should be delivered in the configured 8+2 context batches")
        let finalEvents = await log.replay()
        let consumed = finalEvents.compactMap { envelope -> MessageID? in
            guard case .agentMessageConsumed(let payload) = envelope.event else { return nil }
            return payload.messageID
        }
        XCTAssertEqual(Set(consumed), Set(messageIDs))
        XCTAssertEqual(consumed.count, messageIDs.count)
        let deliveryContracts = finalEvents.compactMap { envelope -> TaskContract? in
            guard case .taskCreated(let payload) = envelope.event,
                  payload.contract.kind == .mailboxDelivery else { return nil }
            return payload.contract
        }
        XCTAssertEqual(deliveryContracts.count, 2)
        let deliverySets = deliveryContracts.map { Set($0.mailboxMessageIDs ?? []) }
        XCTAssertTrue(deliverySets[0].isDisjoint(with: deliverySets[1]))
        XCTAssertEqual(deliverySets[0].union(deliverySets[1]), Set(messageIDs))
        XCTAssertTrue(CoworkProjection.build(from: finalEvents).mailboxes[main]?.pendingMessages.isEmpty == true)
    }
}
