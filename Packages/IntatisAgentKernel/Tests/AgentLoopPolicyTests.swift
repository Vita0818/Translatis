import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
@testable import IntatisAgentKernel

private final class PolicyScriptedProvider: ToolCallingProvider, @unchecked Sendable {
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

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        capturedRequests.append(request)
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

private actor PolicyStreamEndCancellationState {
    private var phase = 0
    private var waitingForEnd = false
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func next() async -> AgentChunk? {
        switch phase {
        case 0:
            phase = 1
            return .textDelta("finished response")
        case 1:
            phase = 2
            return .usage(Usage(promptTokens: 8, completionTokens: 4, totalTokens: 12))
        case 2:
            phase = 3
            return .done(finishReason: "stop")
        default:
            waitingForEnd = true
            let waiters = waitingContinuations
            waitingContinuations.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                finishContinuation = continuation
            }
            return nil
        }
    }

    func waitUntilProviderIsReadyToEnd() async {
        if waitingForEnd { return }
        await withCheckedContinuation { continuation in
            waitingContinuations.append(continuation)
        }
    }

    func finishStream() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

private struct PolicyStreamEndCancellationProvider: ToolCallingProvider {
    let state: PolicyStreamEndCancellationState

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream(unfolding: { await state.next() })
    }
}

private actor ParallelToolProbe {
    private var activeCount = 0
    private var peakActiveCount = 0
    private var completionOrder: [String] = []

    func begin() {
        activeCount += 1
        peakActiveCount = max(peakActiveCount, activeCount)
    }

    func finish(label: String) -> String {
        activeCount -= 1
        completionOrder.append(label)
        return "result:\(label)"
    }

    func snapshot() -> (peakActiveCount: Int, completionOrder: [String]) {
        (peakActiveCount, completionOrder)
    }
}

private struct ParallelToolArguments: Decodable {
    var label: String
    var delayMillis: Int
}

private let parallelToolParameters = JSONValue.object([
    "type": .string("object"),
    "properties": .object([
        "label": .object([
            "type": .string("string"),
            "minLength": .number(1),
        ]),
        "delayMillis": .object([
            "type": .string("integer"),
            "minimum": .number(0),
            "maximum": .number(1_000),
        ]),
    ]),
    "required": .array([.string("label"), .string("delayMillis")]),
    "additionalProperties": .bool(false),
])

private struct PolicyAskAgentTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "ask_agent",
        description: "Test-only ask tool with observable concurrency.",
        sideEffect: .readOnly,
        parameters: parallelToolParameters)

    let probe: ParallelToolProbe

    func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let decoded = try args.decode(ParallelToolArguments.self)
        await probe.begin()
        try await Task.sleep(nanoseconds: UInt64(decoded.delayMillis) * 1_000_000)
        return ToolObservation(text: await probe.finish(label: decoded.label))
    }
}

private struct PolicyDelegateTaskTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "delegate_task",
        description: "Test-only delegation tool with observable concurrency.",
        sideEffect: .readOnly,
        parameters: parallelToolParameters)

    let probe: ParallelToolProbe

    func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let decoded = try args.decode(ParallelToolArguments.self)
        await probe.begin()
        try await Task.sleep(nanoseconds: UInt64(decoded.delayMillis) * 1_000_000)
        return ToolObservation(text: await probe.finish(label: decoded.label))
    }
}

private struct PolicyDeferredToolSearchTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "tool_search",
        description: "Return one deferred test function.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                ]),
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
            text: "deferred tool loaded",
            toolSearchOutput: output)
    }
}

private actor CapturingPolicyResponder: PermissionResponder {
    private var captured: [PermissionRequestPayload] = []
    private let decision: PermissionDecision

    init(_ decision: PermissionDecision) {
        self.decision = decision
    }

    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        captured.append(request)
        return decision
    }

    func requests() -> [PermissionRequestPayload] { captured }
}

private actor SequencedStructuredPolicyResponder: PermissionResponder {
    nonisolated let approvalMode: PermissionApprovalMode = .automaticReviewer

    private var captured: [PermissionRequestPayload] = []
    private let resolutions: [PermissionApprovalResolution]

    init(_ resolutions: [PermissionApprovalResolution]) {
        self.resolutions = resolutions
    }

    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        await requestResolution(request).decision
    }

    func requestResolution(_ request: PermissionRequestPayload) async -> PermissionApprovalResolution {
        nextResolution(for: request)
    }

    func requestResolution(
        _ request: PermissionRequestPayload,
        invocation _: PermissionReviewInvocationInput
    ) async -> PermissionApprovalResolution {
        nextResolution(for: request)
    }

    private func nextResolution(
        for request: PermissionRequestPayload
    ) -> PermissionApprovalResolution {
        let index = min(captured.count, resolutions.count - 1)
        captured.append(request)
        return resolutions[index]
    }

    func requests() -> [PermissionRequestPayload] { captured }
}

private struct StructuredDenyPolicyResponder: PermissionResponder {
    let reason: String

    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        .deny
    }

    func requestResolution(_ request: PermissionRequestPayload) async -> PermissionApprovalResolution {
        PermissionApprovalResolution(
            decision: .deny,
            reason: reason,
            source: .automaticReviewer,
            reviewTaskID: PermissionReviewTaskID(rawValue: "review-structured-deny"),
            reviewStatus: .denied)
    }
}

private struct PolicyAllowingInEngineReviewer: PermissionReviewer {
    func review(
        _ call: ToolCallContext,
        _ context: PermissionContext,
        gateReason: String,
        risk: RiskLevel
    ) async -> PermissionOutcome {
        _ = call
        _ = context
        _ = gateReason
        return PermissionOutcome(
            decision: .allow,
            risk: risk,
            reason: "in-engine reviewer allowed")
    }
}

private struct DeleteAuditBeforeAllowResponder: PermissionResponder {
    let eventLogURL: URL

    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        try? FileManager.default.removeItem(at: eventLogURL)
        return .allow
    }
}

private struct ReplaceWorkspaceBeforeAllowResponder: PermissionResponder {
    let workspace: URL
    let movedWorkspace: URL

    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        do {
            try FileManager.default.moveItem(at: workspace, to: movedWorkspace)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            return .allow
        } catch {
            return .deny
        }
    }
}

private struct PolicyUncertainWriteTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "uncertain_write",
        description: "Test-only non-replayable tool that can fail after an uncertain side effect.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ]))

    func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        throw IntatisError.io("the executor lost its completion acknowledgement")
    }
}

private struct PolicyMCPErrorResultTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "mcp__test__reported_error",
        description: "Test-only MCP tool returning a typed isError result.",
        sideEffect: .network,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ]))

    func execute(
        _ args: ToolArgs,
        in context: ToolContext
    ) async throws -> ToolObservation {
        ToolObservation(
            text: "remote MCP failure",
            structuredResult: MCPStructuredToolResult(
                content: [
                    MCPContentBlock(
                        kind: .text,
                        text: "remote MCP failure"),
                ],
                isError: true))
    }
}

private struct PolicyStructuredReadArguments: Decodable {
    var path: String
    var shouldFail: Bool

    enum CodingKeys: String, CodingKey {
        case path
        case shouldFail = "should_fail"
    }
}

private actor PolicyStructuredReadProbe {
    private var completedPaths: [String] = []

    func complete(path: String) -> ToolObservation {
        completedPaths.append(path)
        return ToolObservation(text: "read completed: \(path)")
    }

    func paths() -> [String] { completedPaths }
}

private struct PolicyStructuredReadTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "structured_read_probe",
        description: "Test-only safe structured reader.",
        sideEffect: .exec,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "minLength": .number(1),
                ]),
                "should_fail": .object([
                    "type": .string("boolean"),
                ]),
            ]),
            "required": .array([
                .string("path"),
                .string("should_fail"),
            ]),
            "additionalProperties": .bool(false),
        ]))

    let probe: PolicyStructuredReadProbe

    func permissionIntent(
        _ args: ToolArgs,
        workspaceRoot: URL
    ) -> PermissionIntent {
        let value = try? args.decode(PolicyStructuredReadArguments.self)
        return PermissionIntent(
            action: "document.read",
            resources: [PermissionResource(
                kind: .workspacePath,
                value: value?.path ?? "unknown",
                access: .readOnly)],
            metadata: [
                "execution_class": .string(
                    PermissionIntent.structuredReadOnlyExecutionClass),
            ],
            dataEffects: [.read, .execute],
            risks: [.processExecution],
            replayPolicy: .safeToReplay)
    }

    func execute(
        _ args: ToolArgs,
        in context: ToolContext
    ) async throws -> ToolObservation {
        let value = try args.decode(PolicyStructuredReadArguments.self)
        if value.shouldFail {
            throw IntatisError.io("the structured reader rejected the input")
        }
        return await probe.complete(path: value.path)
    }
}

private struct PolicyTaskUpdateArguments: Decodable {
    var taskID: String
    var expectedRevision: Int

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case expectedRevision = "expected_revision"
    }
}

private actor PolicyStaleThenSuccessfulTaskUpdateState {
    private var attemptedRevisions: [Int] = []

    func execute(expectedRevision: Int) throws -> ToolObservation {
        attemptedRevisions.append(expectedRevision)
        if attemptedRevisions.count == 1 {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "stale_revision",
                message: "task_update rejected without applying changes: expected_revision \(expectedRevision) is stale; the current revision is 2. Call task_get for task_id \"task-retry\", merge against the authoritative task state, then retry task_update using that revision as expected_revision.")
        }
        return ToolObservation(text: "task updated at revision \(expectedRevision)")
    }

    func revisions() -> [Int] { attemptedRevisions }
}

private struct PolicyStaleThenSuccessfulTaskUpdateTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "task_update",
        description: "Test-only optimistic task update.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "task_id": .object([
                    "type": .string("string"),
                    "minLength": .number(1),
                ]),
                "expected_revision": .object([
                    "type": .string("integer"),
                    "minimum": .number(0),
                ]),
            ]),
            "required": .array([.string("task_id"), .string("expected_revision")]),
            "additionalProperties": .bool(false),
        ]))

    let state: PolicyStaleThenSuccessfulTaskUpdateState

    func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(PolicyTaskUpdateArguments.self)
        return PermissionIntent(
            action: "task.update",
            resources: [PermissionResource(kind: .task, value: value?.taskID ?? "unknown")],
            metadata: [
                "expectedRevision": .number(Double(value?.expectedRevision ?? -1)),
            ],
            dataEffects: [.none],
            controlEffects: [.updateTask],
            risks: [.controlPlaneMutation],
            replayPolicy: .doNotReplay)
    }

    func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try args.decode(PolicyTaskUpdateArguments.self)
        return try await state.execute(expectedRevision: value.expectedRevision)
    }
}

private actor PolicyPostPrepareCancellationGate {
    private var callCount = 0
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func revalidate() async -> String? {
        callCount += 1
        guard callCount == 3 else { return nil }
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return nil
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor PolicyCancellationGate {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func runUntilCancelled() async throws -> ToolObservation {
        entered = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters { waiter.resume() }
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return ToolObservation(text: "unexpected completion")
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private struct PolicyCancellableUncertainWriteTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "cancellable_uncertain_write",
        description: "Test-only non-replayable tool cancelled after its executor boundary.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ]))

    let gate: PolicyCancellationGate

    func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        try await gate.runUntilCancelled()
    }
}

private actor PolicyAuthorizationRevalidationProbe {
    private var calls = 0
    private let failOnCall: Int

    init(failOnCall: Int) {
        self.failOnCall = failOnCall
    }

    func nextFailure() -> String? {
        calls += 1
        return calls == failOnCall
            ? "permission denied: capability lease was revoked before tool execution"
            : nil
    }

    func callCount() -> Int { calls }
}

final class AgentLoopPolicyTests: XCTestCase {
    private func makeWorkspaceAndLog(_ suffix: String) throws -> (URL, EventLog) {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-agent-policy-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let log = try EventLog(
            session: SessionID(rawValue: "agent_policy_\(suffix)"),
            fileURL: workspace.appendingPathComponent("events.jsonl"))
        return (workspace, log)
    }

    private func makeLoop(workspace: URL,
                          log: EventLog,
                          provider: ToolCallingProvider,
                          registry: ToolRegistry = ToolRegistry([]),
                          engine: PermissionEngine = PermissionEngine(),
                          responder: PermissionResponder = FixedResponder(.allow),
                          context: ContextBuilder = ContextBuilder(),
                          capabilityLease: CapabilityLease? = nil,
                          workspaceLease: WorkspaceLease? = nil,
                          rootTaskID: TaskID? = nil,
                          taskAttempt: Int? = nil,
                          tokenBudgetMeter: AgentTokenBudgetMeter? = nil,
                          authorizationRevalidator: ToolAuthorizationRevalidator? = nil,
                          agentName: String = "policy-agent") -> AgentLoop {
        AgentLoop(
            log: log,
            provider: provider,
            registry: registry,
            engine: engine,
            responder: responder,
            agent: Agent(
                name: AgentID(rawValue: agentName),
                workspaceRoot: workspace,
                model: ModelID(rawValue: "test-model"),
                profile: .reviewed),
            context: context,
            allowsShell: false,
            includeUsage: tokenBudgetMeter != nil,
            maxIterations: 4,
            capabilityLease: capabilityLease,
            workspaceLease: workspaceLease,
            rootTaskID: rootTaskID,
            taskAttempt: taskAttempt,
            tokenBudgetMeter: tokenBudgetMeter,
            authorizationRevalidator: authorizationRevalidator)
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func automaticToolArguments(
        _ business: [String: Any],
        marker: String
    ) -> String {
        var combined = business
        combined[AuthorizationSidecarCodec.reservedFieldName] =
            "The current user request authorizes this exact bounded test action; \(marker). The selected business call is the next required step."
        return json(combined)
    }

    private func toolResults(in log: EventLog) async -> [ToolResultPayload] {
        await log.replay().compactMap { envelope in
            guard case .toolResult(let payload) = envelope.event else { return nil }
            return payload
        }
    }

    private func errors(in log: EventLog) async -> [ErrorPayload] {
        await log.replay().compactMap { envelope in
            guard case .error(let payload) = envelope.event else { return nil }
            return payload
        }
    }

    func testAutomaticCoworkDecoratesDeferredOutputOnlyForNextProviderRequest()
        async throws {
        let (workspace, log) = try makeWorkspaceAndLog(
            "automatic-deferred-sidecar")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let businessSchema = JSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string")]),
                "limit": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false),
        ])
        let rawDeferredFunction = JSONValue.object([
            "type": .string("function"),
            "name": .string("remote_search"),
            "description": .string("Search the remote service."),
            "strict": .bool(false),
            "defer_loading": .bool(true),
            "parameters": businessSchema,
        ])
        let rawOutput = ModelToolSearchOutput(
            tools: [rawDeferredFunction])
        let provider = PolicyScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "search-call",
                    name: "tool_search",
                    arguments: #"{"query":"remote search"}"#,
                    kind: .toolSearch,
                    status: "completed",
                    execution: "client")]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .textDelta("Deferred tool definition received."),
                .done(finishReason: "stop"),
            ],
        ])
        let responder = SequencedStructuredPolicyResponder([
            PermissionApprovalResolution(
                decision: .allow,
                reason: "must not be consulted for deterministic discovery",
                source: .automaticReviewer,
                reviewStatus: .allowed),
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([
                PolicyDeferredToolSearchTool(output: rawOutput),
            ]),
            responder: responder,
            context: ContextBuilder(runtimeEnvironment: .cowork))

        let answer = try await loop.send("Find the remote search tool.")

        XCTAssertEqual(answer, "Deferred tool definition received.")
        let reviewRequests = await responder.requests()
        XCTAssertTrue(reviewRequests.isEmpty)
        XCTAssertEqual(provider.requests.count, 2)
        let firstRequest = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(firstRequest.tools.count, 1)
        XCTAssertEqual(firstRequest.tools[0].kind, .toolSearch)
        XCTAssertEqual(
            firstRequest.tools[0].parameters,
            PolicyDeferredToolSearchTool.descriptor.parameters)
        let secondRequest = provider.requests[1]
        let providerOutput = try XCTUnwrap(
            secondRequest.messages.compactMap(\.toolSearchOutput).first)
        guard let firstDeferredTool = providerOutput.tools.first,
              case .object(let function) = firstDeferredTool,
              case .object(let parameters)? = function["parameters"],
              case .object(let properties)? = parameters["properties"],
              case .array(let required)? = parameters["required"] else {
            return XCTFail("expected a provider-decorated deferred function")
        }
        XCTAssertNotNil(
            properties[AuthorizationSidecarCodec.reservedFieldName])
        XCTAssertEqual(required, [
            .string("query"),
            .string(AuthorizationSidecarCodec.reservedFieldName),
        ])
        XCTAssertEqual(rawOutput.tools, [rawDeferredFunction])
    }

    func testReadOnlyWorkspaceLeaseRejectsWriteToolBeforeExecution() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("readonly")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = PolicyScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "write",
                    name: "write_file",
                    arguments: json(["path": "blocked.txt", "content": "must not be written"]))]),
                .done(finishReason: "tool_calls"),
            ],
            [.textDelta("Write was blocked."), .done(finishReason: "stop")],
        ])
        let lease = WorkspaceLease(
            rootPath: workspace.path,
            access: .readOnly,
            allowedPathRules: [PathRule(pattern: ".")],
            deniedPatterns: [])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            workspaceLease: lease)

        let answer = try await loop.send("Attempt a write under a read-only lease.")

        XCTAssertEqual(answer, "Write was blocked.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("blocked.txt").path))
        let results = await toolResults(in: log)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.observation, "permission denied: workspace lease is read-only")
        let permissionRequests = await log.replay().filter {
            if case .permissionRequest = $0.event { return true }
            return false
        }
        XCTAssertTrue(permissionRequests.isEmpty)
    }

    func testWorkspaceLeaseAllowListAndDeniedPatternsConstrainTouchedPaths() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("paths")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = PolicyScriptedProvider([
            [
                .toolCalls([
                    ToolCall(id: "allowed", name: "write_file", arguments: json([
                        "path": "allowed/ok.txt", "content": "ok",
                    ])),
                    ToolCall(id: "outside", name: "write_file", arguments: json([
                        "path": "outside/no.txt", "content": "outside",
                    ])),
                    ToolCall(id: "denied", name: "write_file", arguments: json([
                        "path": "allowed/private/blocked.txt", "content": "blocked",
                    ])),
                ]),
                .done(finishReason: "tool_calls"),
            ],
            [.textDelta("Path checks complete."), .done(finishReason: "stop")],
        ])
        let lease = WorkspaceLease(
            rootPath: workspace.path,
            access: .readWrite,
            allowedPathRules: [PathRule(pattern: "allowed/**")],
            deniedPatterns: ["allowed/private/**"])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            workspaceLease: lease)

        _ = try await loop.send("Exercise lease path rules.")

        XCTAssertEqual(
            try String(contentsOf: workspace.appendingPathComponent("allowed/ok.txt"), encoding: .utf8),
            "ok")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("outside/no.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("allowed/private/blocked.txt").path))
        let resultsByID = Dictionary(uniqueKeysWithValues: await toolResults(in: log).map {
            ($0.toolCallId, $0.observation)
        })
        XCTAssertTrue(resultsByID["allowed"]?.hasPrefix("wrote 2 bytes") == true)
        XCTAssertEqual(
            resultsByID["outside"],
            "permission denied: path is outside the workspace lease allow-list: outside/no.txt")
        XCTAssertEqual(
            resultsByID["denied"],
            "permission denied: path is denied by the workspace lease: allowed/private/blocked.txt")
        let executionEvents = await log.replay().filter {
            if case .toolExecutionPrepared = $0.event { return true }
            if case .toolExecutionSettled = $0.event { return true }
            return false
        }
        XCTAssertEqual(executionEvents.count, 2, "only the allowed write reaches the executor boundary")
    }

    func testWorkspaceLeaseRejectsRootReplacementBeforeToolExecution() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("root-identity")
        let parent = workspace.deletingLastPathComponent()
        let moved = parent.appendingPathComponent("\(workspace.lastPathComponent)-moved")
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: moved)
        }
        let lease = WorkspaceLease(
            rootPath: workspace.path,
            access: .readWrite,
            deniedPatterns: [])
        try FileManager.default.moveItem(at: workspace, to: moved)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let provider = PolicyScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "identity-write",
                    name: "write_file",
                    arguments: json(["path": "unexpected.txt", "content": "blocked"]))]),
                .done(finishReason: "tool_calls"),
            ],
            [.textDelta("Blocked."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            workspaceLease: lease)

        _ = try await loop.send("Attempt to use a replaced workspace root.")

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("unexpected.txt").path))
        let results = await toolResults(in: log)
        XCTAssertEqual(
            results.first?.observation,
            "permission denied: workspace root changed after the lease was granted; reattach the workspace")
    }

    func testWorkspaceLeaseRejectsRootReplacementWhileAwaitingPermission() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-agent-policy-root-review-\(UUID().uuidString)", isDirectory: true)
        let workspace = parent.appendingPathComponent("workspace", isDirectory: true)
        let moved = parent.appendingPathComponent("workspace-reviewed", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let log = try EventLog(
            session: SessionID(rawValue: "agent_policy_root_review"),
            fileURL: parent.appendingPathComponent("events.jsonl"))
        let lease = WorkspaceLease(
            rootPath: workspace.path,
            access: .readWrite,
            deniedPatterns: [])
        let provider = PolicyScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "reviewed-identity-write",
                    name: "write_file",
                    arguments: json(["path": "unexpected.txt", "content": "blocked"]))]),
                .done(finishReason: "tool_calls"),
            ],
            [.textDelta("Blocked after review."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            responder: ReplaceWorkspaceBeforeAllowResponder(
                workspace: workspace,
                movedWorkspace: moved),
            workspaceLease: lease)

        _ = try await loop.send("Approve a write while replacing the workspace root.")

        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("unexpected.txt").path))
        let results = await toolResults(in: log)
        XCTAssertEqual(
            results.first?.observation,
            "permission denied: workspace root changed after the lease was granted; reattach the workspace")
        let prepared = await log.replay().contains { envelope in
            if case .toolExecutionPrepared = envelope.event { return true }
            return false
        }
        XCTAssertFalse(prepared, "root replacement after approval must be rejected before executor prepare")
    }

    func testLiveAuthorizationRevocationAfterDurablePrepareFailsClosed() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("live-authorization-revalidation")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let probe = PolicyAuthorizationRevalidationProbe(failOnCall: 3)
        let provider = PolicyScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "revoked-write",
                    name: "write_file",
                    arguments: json(["path": "must-not-exist.txt", "content": "blocked"]))]),
                .done(finishReason: "tool_calls"),
            ],
            [.textDelta("The revoked write was blocked."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            authorizationRevalidator: { _ in await probe.nextFailure() })

        let answer = try await loop.send("Attempt a write whose live lease is revoked after prepare.")

        XCTAssertEqual(answer, "The revoked write was blocked.")
        let revalidationCount = await probe.callCount()
        XCTAssertEqual(revalidationCount, 3)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("must-not-exist.txt").path))
        let results = await toolResults(in: log)
        XCTAssertEqual(
            results.first?.observation,
            "permission denied: capability lease was revoked before tool execution")
        let events = await log.replay()
        let prepared = events.compactMap { envelope -> ToolExecutionPreparedPayload? in
            guard case .toolExecutionPrepared(let payload) = envelope.event else { return nil }
            return payload
        }
        let settled = events.compactMap { envelope -> ToolExecutionSettledPayload? in
            guard case .toolExecutionSettled(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(settled.count, 1)
        XCTAssertEqual(settled.first?.outcome, .denied)
        XCTAssertEqual(settled.first?.effectDisposition, .notStarted)
        XCTAssertEqual(settled.first?.authorization, prepared.first?.authorization)
    }

    func testHostAuthorizationFailureBeforeReviewSkipsReviewerAndPrepare() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("authorization-preflight")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let probe = PolicyAuthorizationRevalidationProbe(failOnCall: 1)
        let responder = CapturingPolicyResponder(.allow)
        let provider = PolicyScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "preflight-write",
                    name: "write_file",
                    arguments: json(["path": "must-not-exist.txt", "content": "blocked"]))]),
                .done(finishReason: "tool_calls"),
            ],
            [.textDelta("The host rejected the stale authorization."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            responder: responder,
            authorizationRevalidator: { _ in await probe.nextFailure() })

        let answer = try await loop.send("Attempt a write with an invalid live authorization.")

        XCTAssertEqual(answer, "The host rejected the stale authorization.")
        let capturedRequests = await responder.requests()
        XCTAssertEqual(capturedRequests.count, 0)
        let revalidationCount = await probe.callCount()
        XCTAssertEqual(revalidationCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("must-not-exist.txt").path))
        let prepared = await log.replay().contains { envelope in
            if case .toolExecutionPrepared = envelope.event { return true }
            return false
        }
        XCTAssertFalse(prepared)
    }

    func testLiveAuthorizationRevocationAfterReviewFailsBeforePrepare() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("authorization-post-review")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let probe = PolicyAuthorizationRevalidationProbe(failOnCall: 2)
        let responder = CapturingPolicyResponder(.allow)
        let provider = PolicyScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "post-review-write",
                    name: "write_file",
                    arguments: json(["path": "must-not-exist.txt", "content": "blocked"]))]),
                .done(finishReason: "tool_calls"),
            ],
            [.textDelta("The revoked authorization was rejected."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            responder: responder,
            authorizationRevalidator: { _ in await probe.nextFailure() })

        let answer = try await loop.send("Attempt a write revoked immediately after review.")

        XCTAssertEqual(answer, "The revoked authorization was rejected.")
        let capturedRequests = await responder.requests()
        XCTAssertEqual(capturedRequests.count, 1)
        let revalidationCount = await probe.callCount()
        XCTAssertEqual(revalidationCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("must-not-exist.txt").path))
        let events = await log.replay()
        XCTAssertFalse(events.contains { envelope in
            if case .toolExecutionPrepared = envelope.event { return true }
            return false
        })
        let resolved = events.compactMap { envelope -> PermissionResolvedPayload? in
            guard case .permissionResolved(let payload) = envelope.event else { return nil }
            return payload
        }.last
        XCTAssertEqual(resolved?.source, .authorizationRevalidation)
        XCTAssertEqual(resolved?.failureKind, .authorizationSnapshotInvalid)
    }

    func testPermissionAuditFailurePreventsAllowedToolExecution() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("audit-fail-closed")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let logURL = workspace.appendingPathComponent("events.jsonl")
        let provider = PolicyScriptedProvider([[
            .toolCalls([ToolCall(
                id: "write",
                name: "write_file",
                arguments: json(["path": "must-not-exist.txt", "content": "blocked"]))]),
            .done(finishReason: "tool_calls"),
        ]])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            responder: DeleteAuditBeforeAllowResponder(eventLogURL: logURL))

        do {
            _ = try await loop.send("Attempt a write while the permission audit store fails.")
            XCTFail("The loop must fail closed when the allow verdict cannot be persisted.")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("must-not-exist.txt").path))
    }

    func testPermissionRequestCarriesExactTaskLeaseAndToolContext() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("review-context")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let responder = CapturingPolicyResponder(.deny)
        let rootTaskID = TaskID(rawValue: "root-context")
        let parentTaskID = TaskID(rawValue: "parent-context")
        let taskID = TaskID(rawValue: "task-context")
        let contract = TaskContract(
            id: taskID,
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "policy-agent"),
            parentTaskID: parentTaskID,
            objective: "Write the scoped file",
            roleHint: "worker",
            expectedDeliverable: "one file")
        let capability = CapabilityLease.worker(taskID: taskID, workspaceAccess: .readWrite)
        let workspaceLease = WorkspaceLease(
            taskID: taskID,
            rootPath: workspace.path,
            access: .readWrite,
            deniedPatterns: [])
        let provider = PolicyScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "context-write",
                    name: "write_file",
                    arguments: json(["path": "scoped.txt", "content": "no"]))]),
                .done(finishReason: "tool_calls"),
            ],
            [.textDelta("Denied."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry(
                registrations: [ToolRegistration(
                    tool: WriteFileTool(),
                    grantingCapabilities: [.applyPatch])],
                registryVersion: "test.cowork.v1"),
            responder: responder,
            context: ContextBuilder(taskContract: contract),
            capabilityLease: capability,
            workspaceLease: workspaceLease,
            rootTaskID: rootTaskID,
            taskAttempt: 3)

        let answer = try await loop.send("Write it.")
        XCTAssertEqual(answer, "Denied.")
        let capturedRequests = await responder.requests()
        let request = try XCTUnwrap(capturedRequests.first)
        let reviewContext = try XCTUnwrap(request.context)
        XCTAssertEqual(reviewContext.taskID, taskID)
        XCTAssertEqual(reviewContext.rootTaskID, rootTaskID)
        XCTAssertEqual(reviewContext.parentTaskID, parentTaskID)
        XCTAssertEqual(reviewContext.attempt, 3)
        XCTAssertEqual(reviewContext.toolCallID, "context-write")
        XCTAssertEqual(reviewContext.touchedPaths, ["scoped.txt"])
        XCTAssertEqual(reviewContext.sideEffect, .write)
        XCTAssertEqual(reviewContext.capabilityLease, capability)
        XCTAssertEqual(reviewContext.workspaceLease, workspaceLease)
        XCTAssertEqual(reviewContext.taskContract, contract)
        XCTAssertEqual(reviewContext.replayPolicy, ToolExecutionReplayPolicy.doNotReplay.rawValue)
        XCTAssertEqual(reviewContext.gate?.decision, .pass)
        let authorization = try XCTUnwrap(reviewContext.authorization)
        XCTAssertEqual(authorization.registryVersion, "test.cowork.v1")
        XCTAssertEqual(authorization.concreteToolID, "test.cowork.v1/write_file")
        XCTAssertEqual(authorization.canonicalAction, "filesystem.write")
        XCTAssertEqual(authorization.requiredCapabilities, [.applyPatch])
        XCTAssertEqual(authorization.membership, .granted)
        XCTAssertEqual(authorization.capabilityLeaseID, capability.id)
        XCTAssertEqual(authorization.capabilityTaskID, taskID)
        XCTAssertEqual(authorization.workspaceLeaseID, workspaceLease.id)
        XCTAssertEqual(authorization.taskID, taskID)
        XCTAssertEqual(authorization.rootTaskID, rootTaskID)
        XCTAssertEqual(authorization.parentTaskID, parentTaskID)
        XCTAssertEqual(authorization.attempt, 3)
        XCTAssertEqual(authorization.toolCallID, "context-write")
        XCTAssertEqual(authorization.deterministicGate?.decision, .pass)
        XCTAssertEqual(authorization.normalizedArgumentsDigest.count, 64)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("scoped.txt").path))
    }

    func testUnleasedScopedToolIsDeniedBeforeResponder() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("unleased-tool")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let responder = CapturingPolicyResponder(.allow)
        let provider = PolicyScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "unleased-write",
                    name: "write_file",
                    arguments: json(["path": "blocked.txt", "content": "blocked"]))]),
                .done(finishReason: "tool_calls"),
            ],
            [.textDelta("Host denied it."), .done(finishReason: "stop")],
        ])
        let registry = ToolRegistry(
            registrations: [ToolRegistration(
                tool: WriteFileTool(),
                grantingCapabilities: [.applyPatch])],
            registryVersion: "test.cowork.v1")
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: registry,
            responder: responder,
            capabilityLease: CapabilityLease(tools: [.readWorkspace]),
            workspaceLease: WorkspaceLease(rootPath: workspace.path, access: .readWrite))

        let answer = try await loop.send("Try the unleased write.")
        let responderRequests = await responder.requests()
        let results = await toolResults(in: log)
        XCTAssertEqual(answer, "Host denied it.")
        XCTAssertTrue(responderRequests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("blocked.txt").path))
        let result = try XCTUnwrap(results.first)
        XCTAssertTrue(result.observation.contains("not granted by the active capability lease"))
        XCTAssertEqual(provider.requests.count, 2)
    }

    func testStructuredReviewerReasonReachesResolvedToolResultAndNextTurnExactlyOnce() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("structured-deny")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let exactReason = "requested overwrite is unrelated to the assigned report"
        let provider = PolicyScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "reviewed-write",
                    name: "write_file",
                    arguments: json(["path": "blocked.txt", "content": "blocked"]))]),
                .done(finishReason: "tool_calls"),
            ],
            [.textDelta("I could not perform the write."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            responder: StructuredDenyPolicyResponder(reason: exactReason))

        let answer = try await loop.send("Attempt the reviewed write.")
        XCTAssertEqual(answer, "I could not perform the write.")
        let events = await log.replay()
        let resolved = try XCTUnwrap(events.compactMap { envelope -> PermissionResolvedPayload? in
            if case .permissionResolved(let payload) = envelope.event,
               payload.requestId != nil { return payload }
            return nil
        }.first)
        XCTAssertEqual(resolved.reason, exactReason)
        XCTAssertEqual(resolved.source, .automaticReviewer)
        XCTAssertEqual(resolved.reviewTaskID?.rawValue, "review-structured-deny")
        XCTAssertEqual(resolved.reviewStatus, .denied)
        let observation = try XCTUnwrap(events.compactMap { envelope -> ToolResultPayload? in
            if case .toolResult(let payload) = envelope.event { return payload }
            return nil
        }.first?.observation)
        XCTAssertEqual(observation, "permission denied: \(exactReason)")
        XCTAssertFalse(observation.contains("permission denied: permission denied:"))
        let nextTurn = try XCTUnwrap(provider.requests.dropFirst().first)
        XCTAssertTrue(nextTurn.messages.contains { $0.content == observation })
    }

    func testMCPIsErrorResultIsDurableTypedFailureWithUnknownEffect()
        async throws {
        let (workspace, log) = try makeWorkspaceAndLog(
            "mcp-typed-error-result")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = PolicyScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "mcp-error-call",
                    name: "mcp__test__reported_error",
                    arguments: "{}")]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .textDelta("The remote tool reported failure."),
                .done(finishReason: "stop"),
            ],
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([PolicyMCPErrorResultTool()]))

        let answer = try await loop.send("Call the remote tool.")

        XCTAssertEqual(
            answer,
            "The remote tool reported failure.")
        let events = await log.replay()
        let result = try XCTUnwrap(events.compactMap {
            envelope -> ToolResultPayload? in
            guard case .toolResult(let payload) = envelope.event
            else { return nil }
            return payload
        }.first)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.failureSource, .runtimeFailed)
        XCTAssertEqual(result.structuredResult?.isError, true)
        let settled = try XCTUnwrap(events.compactMap {
            envelope -> ToolExecutionSettledPayload? in
            guard case .toolExecutionSettled(let payload) =
                    envelope.event else { return nil }
            return payload
        }.first)
        XCTAssertEqual(settled.outcome, .failed)
        XCTAssertEqual(settled.effectDisposition, .unknown)
    }

    func testSafeStructuredReadFailureSettlesContinuesBatchAndAllowsFinalAnswer()
        async throws {
        let (workspace, log) = try makeWorkspaceAndLog(
            "safe-structured-read-failure")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID(rawValue: "task-safe-structured-read-failure")
        let contract = TaskContract(
            id: taskID,
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "policy-agent"),
            objective: "Read two independent documents.",
            roleHint: "worker",
            expectedDeliverable: "a bounded read summary")
        let provider = PolicyScriptedProvider([
            [
                .toolCalls([
                    ToolCall(
                        id: "failed-structured-read",
                        name: "structured_read_probe",
                        arguments: json([
                            "path": "failed.xlsx",
                            "should_fail": true,
                        ])),
                    ToolCall(
                        id: "later-structured-read",
                        name: "structured_read_probe",
                        arguments: json([
                            "path": "later.pptx",
                            "should_fail": false,
                        ])),
                ]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .textDelta("The first read failed; the second read completed."),
                .done(finishReason: "stop"),
            ],
        ])
        let probe = PolicyStructuredReadProbe()
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([PolicyStructuredReadTool(probe: probe)]),
            context: ContextBuilder(
                taskContract: contract,
                runtimeEnvironment: .cowork),
            rootTaskID: taskID,
            taskAttempt: 1)

        let answer = try await loop.send("Read both documents.")

        XCTAssertEqual(
            answer,
            "The first read failed; the second read completed.")
        let completedPaths = await probe.paths()
        XCTAssertEqual(completedPaths, ["later.pptx"])
        let events = await log.replay()
        let results = events.compactMap { envelope -> ToolResultPayload? in
            guard case .toolResult(let payload) = envelope.event else {
                return nil
            }
            return payload
        }
        XCTAssertEqual(results.map(\.toolCallId), [
            "failed-structured-read",
            "later-structured-read",
        ])
        XCTAssertEqual(results.first?.outcome, .failed)
        XCTAssertEqual(results.first?.failureSource, .runtimeFailed)
        XCTAssertEqual(results.last?.outcome, .succeeded)
        XCTAssertFalse(events.contains { envelope in
            if case .permissionRequest = envelope.event { return true }
            return false
        })
        let permissionResolutions = events.compactMap {
            envelope -> PermissionResolvedPayload? in
            guard case .permissionResolved(let payload) = envelope.event
            else { return nil }
            return payload
        }
        XCTAssertEqual(permissionResolutions.count, 2)
        XCTAssertTrue(permissionResolutions.allSatisfy {
            $0.decision == .allow
                && $0.requestId == nil
                && $0.source == .deterministicPolicy
        })
        let settlements = events.compactMap {
            envelope -> ToolExecutionSettledPayload? in
            guard case .toolExecutionSettled(let payload) = envelope.event
            else { return nil }
            return payload
        }
        XCTAssertEqual(settlements.count, 2)
        XCTAssertEqual(settlements.first?.outcome, .failed)
        XCTAssertEqual(settlements.first?.effectDisposition, .unknown)
        XCTAssertEqual(settlements.first?.replayPolicy, .safeToReplay)
        XCTAssertEqual(settlements.last?.outcome, .succeeded)
        XCTAssertEqual(settlements.last?.effectDisposition, .committed)
    }

    func testNonReplayableToolFailureSettlesAndReturnsFailureToModel() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("uncertain-side-effect")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID(rawValue: "task-uncertain-side-effect")
        let contract = TaskContract(
            id: taskID,
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "policy-agent"),
            objective: "Run an uncertain write.",
            roleHint: "worker",
            expectedDeliverable: "result")
        let provider = PolicyScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "uncertain-call",
                    name: "uncertain_write",
                    arguments: "{}")]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .textDelta("The tool failed; no result was claimed."),
                .done(finishReason: "stop"),
            ],
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([PolicyUncertainWriteTool()]),
            context: ContextBuilder(taskContract: contract),
            taskAttempt: 1)

        let answer = try await loop.send("Run it.")

        XCTAssertEqual(answer, "The tool failed; no result was claimed.")

        let events = await log.replay()
        let projection = CoworkProjection.build(from: events)
        XCTAssertTrue(projection.unresolvedNonReplayableToolExecutions.isEmpty)
        let settlement = try XCTUnwrap(events.compactMap { envelope -> ToolExecutionSettledPayload? in
            guard case .toolExecutionSettled(let payload) = envelope.event,
                  payload.toolCallID == "uncertain-call" else { return nil }
            return payload
        }.first)
        XCTAssertEqual(settlement.taskID, taskID)
        XCTAssertEqual(settlement.attempt, 1)
        XCTAssertEqual(settlement.tool, "uncertain_write")
        XCTAssertEqual(settlement.outcome, .failed)
        XCTAssertEqual(settlement.effectDisposition, .unknown)
        XCTAssertTrue(events.contains { envelope in
            guard case .toolResult(let payload) = envelope.event else { return false }
            return payload.toolCallId == "uncertain-call"
                && payload.observation.contains("lost its completion acknowledgement")
                && !payload.observation.contains("reconciliation")
        })
    }

    func testRejectedWithoutSideEffectSettlesAndReturnsRecoveryToModel() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("rejected-without-side-effect")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID(rawValue: "task-no-effect-retry")
        let contract = TaskContract(
            id: taskID,
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "policy-agent"),
            objective: "Retry an optimistic task update.",
            roleHint: "worker",
            expectedDeliverable: "updated task")
        let provider = PolicyScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "stale-update",
                    name: "task_update",
                    arguments: json(["task_id": "task-retry", "expected_revision": 1]))]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .toolCalls([ToolCall(
                    id: "retried-update",
                    name: "task_update",
                    arguments: json(["task_id": "task-retry", "expected_revision": 2]))]),
                .done(finishReason: "tool_calls"),
            ],
            [.textDelta("The task update succeeded after refreshing its revision."),
             .done(finishReason: "stop")],
        ])
        let state = PolicyStaleThenSuccessfulTaskUpdateState()
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([PolicyStaleThenSuccessfulTaskUpdateTool(state: state)]),
            context: ContextBuilder(
                taskContract: contract,
                runtimeEnvironment: .cowork),
            taskAttempt: 1)

        let answer = try await loop.send("Update the task.")

        XCTAssertEqual(answer, "The task update succeeded after refreshing its revision.")
        let attemptedRevisions = await state.revisions()
        XCTAssertEqual(attemptedRevisions, [1, 2])
        XCTAssertEqual(provider.requests.count, 3)
        let recoveryRequest = try XCTUnwrap(provider.requests.dropFirst().first)
        XCTAssertTrue(recoveryRequest.messages.contains { message in
            message.content?.contains("Call task_get for task_id \"task-retry\"") == true
                && message.content?.contains("current revision is 2") == true
        })

        let events = await log.replay()
        let stalePrepared = try XCTUnwrap(events.compactMap { envelope -> ToolExecutionPreparedPayload? in
            guard case .toolExecutionPrepared(let payload) = envelope.event,
                  payload.toolCallID == "stale-update" else { return nil }
            return payload
        }.first)
        let staleSettled = try XCTUnwrap(events.compactMap { envelope -> ToolExecutionSettledPayload? in
            guard case .toolExecutionSettled(let payload) = envelope.event,
                  payload.executionID == stalePrepared.executionID else { return nil }
            return payload
        }.first)
        XCTAssertEqual(staleSettled.outcome, .failed)
        XCTAssertEqual(staleSettled.effectDisposition, .notStarted)
        XCTAssertTrue(events.contains { envelope in
            guard case .toolResult(let payload) = envelope.event else { return false }
            return payload.toolCallId == "stale-update"
                && payload.observation.contains("Call task_get")
        })
        XCTAssertFalse(CoworkProjection.build(from: events)
            .unresolvedNonReplayableToolExecutions
            .contains { $0.id == stalePrepared.executionID })
        let successfulSettlement = try XCTUnwrap(events.compactMap { envelope -> ToolExecutionSettledPayload? in
            guard case .toolExecutionSettled(let payload) = envelope.event,
                  payload.toolCallID == "retried-update" else { return nil }
            return payload
        }.first)
        XCTAssertEqual(successfulSettlement.outcome, .succeeded)
        XCTAssertEqual(successfulSettlement.effectDisposition, .committed)
        XCTAssertFalse(events.contains { envelope in
            if case .error = envelope.event { return true }
            return false
        })
    }

    func testCancellationAfterPrepareBeforeExecutorSettlesNotStarted() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("cancel-before-executor")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = PolicyScriptedProvider([[
            .toolCalls([ToolCall(
                id: "cancelled-before-executor",
                name: "write_file",
                arguments: json(["path": "must-not-exist.txt", "content": "blocked"]))]),
            .done(finishReason: "tool_calls"),
        ]])
        let gate = PolicyPostPrepareCancellationGate()
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            authorizationRevalidator: { _ in await gate.revalidate() })
        let execution = Task { try await loop.send("Cancel after prepare.") }
        await gate.waitUntilEntered()

        execution.cancel()
        await gate.release()
        do {
            _ = try await execution.value
            XCTFail("Cancellation before executor entry must propagate.")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("must-not-exist.txt").path))
        let events = await log.replay()
        let prepared = try XCTUnwrap(events.compactMap { envelope -> ToolExecutionPreparedPayload? in
            guard case .toolExecutionPrepared(let payload) = envelope.event else { return nil }
            return payload
        }.first)
        let settled = try XCTUnwrap(events.compactMap { envelope -> ToolExecutionSettledPayload? in
            guard case .toolExecutionSettled(let payload) = envelope.event,
                  payload.executionID == prepared.executionID else { return nil }
            return payload
        }.first)
        XCTAssertEqual(settled.outcome, .cancelled)
        XCTAssertEqual(settled.effectDisposition, .notStarted)
        XCTAssertTrue(events.contains { envelope in
            guard case .toolResult(let payload) = envelope.event else { return false }
            return payload.toolCallId == "cancelled-before-executor"
                && payload.observation == "tool cancelled before execution started"
        })
        XCTAssertFalse(CoworkProjection.build(from: events)
            .unresolvedNonReplayableToolExecutions
            .contains { $0.id == prepared.executionID })
    }

    func testCancelledNonReplayableToolSettlesCancelledWithoutGenericReconciliationError() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("cancelled-uncertain-side-effect")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID(rawValue: "task-cancelled-uncertain-side-effect")
        let contract = TaskContract(
            id: taskID,
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "policy-agent"),
            objective: "Cancel an uncertain write.",
            roleHint: "worker",
            expectedDeliverable: "result")
        let provider = PolicyScriptedProvider([[
            .toolCalls([ToolCall(
                id: "cancelled-uncertain-call",
                name: "cancellable_uncertain_write",
                arguments: "{}")]),
            .done(finishReason: "tool_calls"),
        ]])
        let gate = PolicyCancellationGate()
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([PolicyCancellableUncertainWriteTool(gate: gate)]),
            context: ContextBuilder(taskContract: contract),
            taskAttempt: 1)
        let execution = Task { try await loop.send("Run it once.") }
        await gate.waitUntilEntered()

        execution.cancel()
        do {
            _ = try await execution.value
            XCTFail("Cancelling an uncertain non-replayable executor must stop the task.")
        } catch is CancellationError {
            // Expected.
        }

        let events = await log.replay()
        XCTAssertTrue(CoworkProjection.build(from: events)
            .unresolvedNonReplayableToolExecutions.isEmpty)
        let settled = try XCTUnwrap(events.compactMap { envelope -> ToolExecutionSettledPayload? in
            guard case .toolExecutionSettled(let payload) = envelope.event,
                  payload.toolCallID == "cancelled-uncertain-call" else { return nil }
            return payload
        }.first)
        XCTAssertEqual(settled.taskID, taskID)
        XCTAssertEqual(settled.tool, "cancellable_uncertain_write")
        XCTAssertEqual(settled.outcome, .cancelled)
        XCTAssertEqual(settled.effectDisposition, .unknown)
        XCTAssertTrue(events.contains { envelope in
            guard case .toolResult(let payload) = envelope.event else { return false }
            return payload.toolCallId == "cancelled-uncertain-call"
                && payload.observation == "tool cancelled after execution started"
        })
    }

    func testSharedSoftTokenBudgetReservesBeforeDispatchAndReportsProviderOverrun() async throws {
        // Leave ample room for the real model-facing prompt so this test stays
        // focused on a provider ignoring its output ceiling rather than on the
        // separately covered request-too-large admission path.
        let budgetLimit = 100_000
        let firstReportedTokens = 6
        let overrunReportedTokens = budgetLimit - firstReportedTokens + 1
        let meter = AgentTokenBudgetMeter(limit: budgetLimit)
        let (firstWorkspace, firstLog) = try makeWorkspaceAndLog("budget-first")
        let (secondWorkspace, secondLog) = try makeWorkspaceAndLog("budget-second")
        defer {
            try? FileManager.default.removeItem(at: firstWorkspace)
            try? FileManager.default.removeItem(at: secondWorkspace)
        }
        let firstProvider = PolicyScriptedProvider([[
            .textDelta("first"),
            .usage(Usage(
                promptTokens: 4,
                completionTokens: 2,
                totalTokens: firstReportedTokens)),
            .done(finishReason: "stop"),
        ]])
        let secondProvider = PolicyScriptedProvider([[
            .textDelta("second"),
            // Simulates a provider that ignores the requested output ceiling.
            .usage(Usage(
                promptTokens: 80,
                completionTokens: overrunReportedTokens - 80,
                totalTokens: overrunReportedTokens)),
            .done(finishReason: "stop"),
        ]])
        let firstLoop = makeLoop(
            workspace: firstWorkspace,
            log: firstLog,
            provider: firstProvider,
            tokenBudgetMeter: meter,
            agentName: "budget-first")
        let secondLoop = makeLoop(
            workspace: secondWorkspace,
            log: secondLog,
            provider: secondProvider,
            tokenBudgetMeter: meter,
            agentName: "budget-second")

        let firstResult = try await firstLoop.send("Spend six tokens.")
        XCTAssertEqual(firstResult, "first")
        let afterFirst = await meter.snapshot()
        XCTAssertEqual(afterFirst.consumed, firstReportedTokens)
        XCTAssertEqual(afterFirst.remaining, budgetLimit - firstReportedTokens)
        XCTAssertNotNil(firstProvider.requests.first?.maxOutputTokens)

        do {
            _ = try await secondLoop.send("Simulate a provider that ignores its output ceiling.")
            XCTFail("Expected the explicitly soft budget to report the provider overrun.")
        } catch let error as AgentExecutionBudgetError {
            XCTAssertEqual(
                error,
                .exhausted(limit: budgetLimit, consumed: budgetLimit + 1))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let finalSnapshot = await meter.snapshot()
        XCTAssertEqual(finalSnapshot.consumed, budgetLimit + 1)
        XCTAssertEqual(finalSnapshot.remaining, 0)
        let requestedCeiling = try XCTUnwrap(secondProvider.requests.first?.maxOutputTokens)
        XCTAssertLessThan(requestedCeiling, overrunReportedTokens)
        let errorPayloads = await errors(in: secondLog)
        XCTAssertEqual(errorPayloads.count, 1)
        XCTAssertEqual(errorPayloads.first?.code, "token_budget_exhausted")
    }

    func testConcurrentTokenReservationsCannotSpendTheSameRemainingBalance() async throws {
        let meter = AgentTokenBudgetMeter(
            limit: 100,
            preferredOutputTokensPerRequest: 40)

        let first = try await meter.reserve(estimatedInputTokens: 10)
        let second = try await meter.reserve(estimatedInputTokens: 10)
        let fullyReserved = await meter.snapshot()
        XCTAssertEqual(fullyReserved.consumed, 0)
        XCTAssertEqual(fullyReserved.reserved, 100)
        XCTAssertEqual(fullyReserved.remaining, 0)

        do {
            _ = try await meter.reserve(estimatedInputTokens: 10)
            XCTFail("A third concurrent request must not reuse the reserved balance.")
        } catch let error as AgentExecutionBudgetError {
            XCTAssertEqual(error, .requestTooLarge(limit: 100, available: 0, estimatedInput: 10))
        }

        try await meter.settle(first, reportedTokens: 45, estimatedTokens: 45)
        try await meter.settle(second, reportedTokens: 45, estimatedTokens: 45)
        let settled = await meter.snapshot()
        XCTAssertEqual(settled.consumed, 90)
        XCTAssertEqual(settled.reserved, 0)
        XCTAssertEqual(settled.remaining, 10)
    }

    func testCancellationAfterNormalProviderEndSettlesReservationExactlyOnce() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("budget-post-stream-cancel")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let state = PolicyStreamEndCancellationState()
        let meter = AgentTokenBudgetMeter(limit: 10_000)
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: PolicyStreamEndCancellationProvider(state: state),
            tokenBudgetMeter: meter,
            agentName: "budget-post-stream-cancel")

        let sendTask = Task { () -> String in
            do {
                _ = try await loop.send("Finish the stream, then cancel before accounting.")
                return "unexpected-success"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "unexpected-error:\(error.localizedDescription)"
            }
        }

        await state.waitUntilProviderIsReadyToEnd()
        sendTask.cancel()
        await state.finishStream()
        let sendResult = await sendTask.value
        XCTAssertEqual(sendResult, "cancelled")

        let snapshot = await meter.snapshot()
        XCTAssertEqual(snapshot.consumed, 12)
        XCTAssertEqual(snapshot.reserved, 0)
        XCTAssertEqual(snapshot.remaining, 9_988)
        let stats = await log.replay().compactMap { envelope -> TurnStatsPayload? in
            guard case .turnStats(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(stats.last?.totalTokens, 12)
    }

    func testBudgetReconfigurationPreservesOutstandingReservationAcrossDisableAndReenable() async throws {
        let meter = AgentTokenBudgetMeter(
            limit: 100,
            preferredOutputTokensPerRequest: 40)
        let reservation = try await meter.reserve(estimatedInputTokens: 10)

        await meter.reconfigure(tokenBudget: nil, durableConsumed: 0)
        let disabled = await meter.snapshot()
        XCTAssertNil(disabled.limit)
        XCTAssertEqual(disabled.consumed, 0)
        XCTAssertEqual(disabled.reserved, 50)
        XCTAssertNil(disabled.remaining)

        await meter.reconfigure(tokenBudget: 60, durableConsumed: 0)
        let reconfigured = await meter.snapshot()
        XCTAssertEqual(reconfigured.limit, 60)
        XCTAssertEqual(reconfigured.consumed, 0)
        XCTAssertEqual(reconfigured.reserved, 50)
        XCTAssertEqual(reconfigured.remaining, 10)

        do {
            _ = try await meter.reserve(estimatedInputTokens: 10)
            XCTFail("reconfiguration must not make the old reservation disappear")
        } catch let error as AgentExecutionBudgetError {
            XCTAssertEqual(error, .requestTooLarge(limit: 60, available: 10, estimatedInput: 10))
        }

        try await meter.settle(reservation, reportedTokens: 12, estimatedTokens: 12)
        let settled = await meter.snapshot()
        XCTAssertEqual(settled.consumed, 12)
        XCTAssertEqual(settled.reserved, 0)
        XCTAssertEqual(settled.remaining, 48)
    }

    func testDisabledBudgetTracksUsageWithoutProviderOutputCeiling() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("budget-disabled")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let meter = AgentTokenBudgetMeter(limit: nil)
        let provider = PolicyScriptedProvider([[
            .textDelta("unmetered"),
            .done(finishReason: "stop"),
        ]])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            tokenBudgetMeter: meter,
            agentName: "budget-disabled")

        let result = try await loop.send("Run while the budget is disabled.")
        XCTAssertEqual(result, "unmetered")
        XCTAssertNil(provider.requests.first?.maxOutputTokens)
        let snapshot = await meter.snapshot()
        XCTAssertNil(snapshot.limit)
        XCTAssertGreaterThan(snapshot.consumed, 0)
        XCTAssertEqual(snapshot.reserved, 0)
        XCTAssertNil(snapshot.remaining)
    }

    func testMultipleCollaborationToolCallsRunConcurrentlyAndFeedResultsInCallOrder() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("parallel")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let probe = ParallelToolProbe()
        let calls = [
            ToolCall(id: "ask-slow", name: "ask_agent", arguments: json([
                "label": "ask-slow", "delayMillis": 100,
            ])),
            ToolCall(id: "delegate-fast", name: "delegate_task", arguments: json([
                "label": "delegate-fast", "delayMillis": 5,
            ])),
            ToolCall(id: "ask-mid", name: "ask_agent", arguments: json([
                "label": "ask-mid", "delayMillis": 60,
            ])),
            ToolCall(id: "delegate-mid", name: "delegate_task", arguments: json([
                "label": "delegate-mid", "delayMillis": 20,
            ])),
        ]
        let provider = PolicyScriptedProvider([
            [.toolCalls(calls), .done(finishReason: "tool_calls")],
            [.textDelta("Combined in order."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([
                PolicyAskAgentTool(probe: probe),
                PolicyDelegateTaskTool(probe: probe),
            ]))

        let result = try await loop.send("Run all collaboration calls.")
        XCTAssertEqual(result, "Combined in order.")

        let snapshot = await probe.snapshot()
        XCTAssertGreaterThan(snapshot.peakActiveCount, 1)
        let requests = provider.requests
        XCTAssertEqual(requests.count, 2)
        let toolMessages = requests[1].messages.filter { $0.role == .tool }
        XCTAssertEqual(toolMessages.compactMap(\.toolCallId), calls.map(\.id))
        XCTAssertEqual(
            toolMessages.compactMap(\.content),
            ["result:ask-slow", "result:delegate-fast", "result:ask-mid", "result:delegate-mid"])
    }

    func testRepeatedIdenticalDeniedToolCallIsReviewedOnceThenTerminates() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("denial-circuit-breaker")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let semanticallyIdenticalArguments = [
            #"{"path":"blocked.txt","content":"blocked"}"#,
            #"{ "content" : "blocked", "path" : "blocked.txt" }"#,
            "{\n  \"path\": \"blocked.txt\",\n  \"content\": \"blocked\"\n}",
        ]
        let provider = PolicyScriptedProvider([
            [.toolCalls([ToolCall(id: "denied-1", name: "write_file", arguments: semanticallyIdenticalArguments[0])]),
             .done(finishReason: "tool_calls")],
            [.toolCalls([ToolCall(id: "denied-2", name: "write_file", arguments: semanticallyIdenticalArguments[1])]),
             .done(finishReason: "tool_calls")],
            [.toolCalls([ToolCall(id: "denied-3", name: "write_file", arguments: semanticallyIdenticalArguments[2])]),
             .done(finishReason: "tool_calls")],
        ])
        let responder = CapturingPolicyResponder(.deny)
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            responder: responder)

        do {
            _ = try await loop.send("Keep retrying the same denied write.")
            XCTFail("The third identical denied call must terminate the run.")
        } catch let error as AgentLoopError {
            XCTAssertEqual(error, .repeatedDeniedToolCall(tool: "write_file"))
        }

        let approvalRequests = await responder.requests()
        XCTAssertEqual(approvalRequests.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("blocked.txt").path))
        let terminalErrors = await errors(in: log)
        XCTAssertEqual(terminalErrors.last?.code, "repeated_denied_tool_call")
    }

    func testManualModeRejectsReservedAuthorizationSidecarBeforePersistenceOrExecution()
        async throws {
        let (workspace, log) = try makeWorkspaceAndLog(
            "manual-reserved-sidecar")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sentinel = "MANUAL_RESERVED_SIDECAR_SENTINEL"
        let provider = PolicyScriptedProvider([
            [.toolCalls([ToolCall(
                id: "manual-reserved-sidecar",
                name: "write_file",
                arguments: automaticToolArguments(
                    ["path": "must-not-exist.txt", "content": "blocked"],
                    marker: sentinel))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("The reserved field was rejected."),
             .done(finishReason: "stop")],
        ])
        let responder = CapturingPolicyResponder(.allow)
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            responder: responder)

        let answer = try await loop.send("Exercise the mode boundary.")

        XCTAssertEqual(answer, "The reserved field was rejected.")
        let capturedRequests = await responder.requests()
        XCTAssertTrue(capturedRequests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent(
                "must-not-exist.txt").path))
        let events = await log.replay()
        XCTAssertTrue(events.contains { envelope in
            guard case .toolResult(let payload) = envelope.event else {
                return false
            }
            return payload.observation.contains(
                "authorization_context_mode_mismatch")
        })
        let encoder = Envelope.makeEncoder()
        let durableText = try events.map {
            String(decoding: try encoder.encode($0), as: UTF8.self)
        }.joined(separator: "\n")
        XCTAssertFalse(durableText.contains(sentinel))
    }

    func testCoworkAutomaticModeFailsClosedWhenInEngineReviewerIsInjected()
        async throws {
        let (workspace, log) = try makeWorkspaceAndLog(
            "cowork-double-reviewer")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID(rawValue: "task-cowork-double-reviewer")
        let contract = TaskContract(
            id: taskID,
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "policy-agent"),
            objective: "Create a bounded file.",
            roleHint: "worker",
            expectedDeliverable: "one file")
        let provider = PolicyScriptedProvider([
            [.toolCalls([ToolCall(
                id: "double-reviewer-call",
                name: "write_file",
                arguments: automaticToolArguments(
                    ["path": "must-not-exist.txt", "content": "blocked"],
                    marker: "double reviewer guard"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("The misconfigured action was not executed."),
             .done(finishReason: "stop")],
        ])
        let responder = SequencedStructuredPolicyResponder([
            PermissionApprovalResolution(
                decision: .allow,
                reason: "must not be consulted",
                source: .automaticReviewer,
                reviewStatus: .allowed),
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            engine: PermissionEngine(
                reviewer: PolicyAllowingInEngineReviewer()),
            responder: responder,
            context: ContextBuilder(
                taskContract: contract,
                runtimeEnvironment: .cowork),
            rootTaskID: taskID,
            taskAttempt: 1)

        let answer = try await loop.send(
            "Exercise the double-reviewer guard.")
        XCTAssertEqual(
            answer,
            "The misconfigured action was not executed.")

        let capturedRequests = await responder.requests()
        XCTAssertTrue(capturedRequests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent(
                "must-not-exist.txt").path))
        let events = await log.replay()
        XCTAssertTrue(events.contains { envelope in
            guard case .permissionResolved(let payload) = envelope.event else {
                return false
            }
            return payload.toolCallID == "double-reviewer-call"
                && payload.failureKind == .reviewerContractViolation
                && payload.source == .automaticReviewerFailure
        })
    }

    func testIdenticalToolCallGetsOneFreshReviewAfterTransientReviewerProviderFailure() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("transient-reviewer-retry")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID(rawValue: "task-transient-reviewer-retry")
        let contract = TaskContract(
            id: taskID,
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "policy-agent"),
            objective: "Create recovered.txt after a transient reviewer outage.",
            roleHint: "worker",
            expectedDeliverable: "recovered.txt")
        let provider = PolicyScriptedProvider([
            [.toolCalls([ToolCall(
                id: "reviewer-failed-1",
                name: "write_file",
                arguments: automaticToolArguments(
                    ["path": "recovered.txt", "content": "recovered"],
                    marker: "first transient reviewer attempt"))]),
             .done(finishReason: "tool_calls")],
            [.toolCalls([ToolCall(
                id: "reviewer-retry-2",
                name: "write_file",
                arguments: automaticToolArguments(
                    ["content": "recovered", "path": "recovered.txt"],
                    marker: "fresh transient reviewer retry"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("Write recovered."), .done(finishReason: "stop")],
        ])
        let responder = SequencedStructuredPolicyResponder([
            PermissionApprovalResolution(
                decision: .deny,
                reason: "automatic reviewer provider failed: Network connection lost",
                source: .automaticReviewerFailure,
                reviewTaskID: PermissionReviewTaskID(rawValue: "review-provider-failure"),
                reviewStatus: .failed,
                failureKind: .providerFailure,
                failureSource: .reviewerFailed),
            PermissionApprovalResolution(
                decision: .allow,
                reason: "automatic reviewer allowed the fresh request",
                source: .automaticReviewer,
                reviewTaskID: PermissionReviewTaskID(rawValue: "review-retry-allow"),
                reviewStatus: .allowed),
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            responder: responder,
            context: ContextBuilder(
                taskContract: contract,
                runtimeEnvironment: .cowork),
            rootTaskID: taskID,
            taskAttempt: 1)

        let result = try await loop.send("Retry a write after a transient reviewer outage.")

        XCTAssertEqual(result, "Write recovered.")
        XCTAssertEqual(
            try String(contentsOf: workspace.appendingPathComponent("recovered.txt"),
                       encoding: .utf8),
            "recovered")
        let approvalRequests = await responder.requests()
        XCTAssertEqual(approvalRequests.count, 2)
        if approvalRequests.count == 2 {
            XCTAssertNotEqual(approvalRequests[0].requestId, approvalRequests[1].requestId)
        }
        let preparedCount = await log.replay().filter { envelope in
            if case .toolExecutionPrepared = envelope.event { return true }
            return false
        }.count
        XCTAssertEqual(preparedCount, 1)
    }

    func testFreshReviewDoesNotRearmAfterSecondTransientReviewerFailure() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("bounded-transient-reviewer-retry")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID(rawValue: "task-bounded-transient-reviewer-retry")
        let contract = TaskContract(
            id: taskID,
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "policy-agent"),
            objective: "Keep never-written.txt blocked after repeated reviewer outages.",
            roleHint: "worker",
            expectedDeliverable: "a bounded reviewer failure")
        let arguments = automaticToolArguments(
            ["path": "never-written.txt", "content": "blocked"],
            marker: "bounded transient reviewer retry")
        let provider = PolicyScriptedProvider([
            [.toolCalls([ToolCall(
                id: "transient-failure-1",
                name: "write_file",
                arguments: arguments)]),
             .done(finishReason: "tool_calls")],
            [.toolCalls([ToolCall(
                id: "transient-failure-2",
                name: "write_file",
                arguments: arguments)]),
             .done(finishReason: "tool_calls")],
            [.toolCalls([ToolCall(
                id: "transient-failure-3",
                name: "write_file",
                arguments: arguments)]),
             .done(finishReason: "tool_calls")],
        ])
        let responder = SequencedStructuredPolicyResponder([
            PermissionApprovalResolution(
                decision: .deny,
                reason: "first reviewer provider failure",
                source: .automaticReviewerFailure,
                reviewTaskID: PermissionReviewTaskID(rawValue: "review-provider-failure-1"),
                reviewStatus: .failed,
                failureKind: .providerFailure,
                failureSource: .reviewerFailed),
            PermissionApprovalResolution(
                decision: .deny,
                reason: "second reviewer provider failure",
                source: .automaticReviewerFailure,
                reviewTaskID: PermissionReviewTaskID(rawValue: "review-provider-failure-2"),
                reviewStatus: .failed,
                failureKind: .providerFailure,
                failureSource: .reviewerFailed),
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            responder: responder,
            context: ContextBuilder(
                taskContract: contract,
                runtimeEnvironment: .cowork),
            rootTaskID: taskID,
            taskAttempt: 1)

        do {
            _ = try await loop.send("Keep retrying through reviewer outages.")
            XCTFail("A second transient failure must not re-arm another fresh review.")
        } catch let error as AgentLoopError {
            XCTAssertEqual(error, .repeatedDeniedToolCall(tool: "write_file"))
        }

        let approvalRequests = await responder.requests()
        XCTAssertEqual(approvalRequests.count, 2)
        let preparedCount = await log.replay().filter { envelope in
            if case .toolExecutionPrepared = envelope.event { return true }
            return false
        }.count
        XCTAssertEqual(preparedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("never-written.txt").path))
    }

    func testRepeatedDeniedCoworkActionDoesNotOverrideFinalResponse() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("deduplicated-denial-evidence")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID(rawValue: "task-deduplicated-denial-evidence")
        let contract = TaskContract(
            id: taskID,
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "policy-agent"),
            objective: "Attempt blocked.txt.",
            roleHint: "worker",
            expectedDeliverable: "blocked.txt")
        let provider = PolicyScriptedProvider([
            [.toolCalls([ToolCall(
                id: "denied-evidence-1",
                name: "write_file",
                arguments: #"{"path":"blocked.txt","content":"blocked"}"#)]),
             .done(finishReason: "tool_calls")],
            [.toolCalls([ToolCall(
                id: "denied-evidence-2",
                name: "write_file",
                arguments: #"{ "content" : "blocked", "path" : "blocked.txt" }"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("The write remained blocked."), .done(finishReason: "stop")],
        ])
        let responder = CapturingPolicyResponder(.deny)
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            responder: responder,
            context: ContextBuilder(
                taskContract: contract,
                runtimeEnvironment: .cowork),
            rootTaskID: taskID,
            taskAttempt: 1)

        let answer = try await loop.send(
            "Attempt the same denied write twice.")
        XCTAssertEqual(answer, "The write remained blocked.")

        let approvalRequests = await responder.requests()
        XCTAssertEqual(approvalRequests.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("blocked.txt").path))
        let events = await log.replay()
        XCTAssertTrue(events.contains {
            if case .messageDelta(let payload) = $0.event {
                return payload.textDelta.contains("write remained blocked")
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .messageCompleted = $0.event { return true }
            return false
        })
        let outcomes = events.compactMap { envelope -> TurnOutcomePayload? in
            guard case .turnOutcome(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(outcomes.map(\.outcome), [.completed])
        XCTAssertEqual(outcomes.first?.taskID, taskID)
    }

    func testRepeatedIdenticalUnleasedToolCallTerminatesWithoutReviewer() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("unleased-denial-circuit-breaker")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = PolicyScriptedProvider([
            [.toolCalls([ToolCall(
                id: "unleased-1",
                name: "write_file",
                arguments: #"{"content":"blocked","path":"blocked.txt"}"#)]),
             .done(finishReason: "tool_calls")],
            [.toolCalls([ToolCall(
                id: "unleased-2",
                name: "write_file",
                arguments: #"{ "path": "blocked.txt", "content": "blocked" }"#)]),
             .done(finishReason: "tool_calls")],
            [.toolCalls([ToolCall(
                id: "unleased-3",
                name: "write_file",
                arguments: #"{"path":"blocked.txt","content":"blocked"}"#)]),
             .done(finishReason: "tool_calls")],
        ])
        let responder = CapturingPolicyResponder(.allow)
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry(
                registrations: [ToolRegistration(
                    tool: WriteFileTool(),
                    grantingCapabilities: [.applyPatch])],
                registryVersion: "test.cowork.v1"),
            responder: responder,
            capabilityLease: CapabilityLease(tools: [.readWorkspace]),
            workspaceLease: WorkspaceLease(rootPath: workspace.path, access: .readWrite))

        do {
            _ = try await loop.send("Keep retrying an unleased write.")
            XCTFail("The third identical unleased call must terminate the run.")
        } catch let error as AgentLoopError {
            XCTAssertEqual(error, .repeatedDeniedToolCall(tool: "write_file"))
        }
        let responderRequests = await responder.requests()
        XCTAssertTrue(responderRequests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("blocked.txt").path))
    }

    func testInvalidCoworkWriteFailureDoesNotOverrideFinalResponse() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("invalid-write-completion")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID(rawValue: "task-invalid-write-completion")
        let contract = TaskContract(
            id: taskID,
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "policy-agent"),
            objective: "Create invalid.txt.",
            roleHint: "worker",
            expectedDeliverable: "invalid.txt")
        let provider = PolicyScriptedProvider([
            [.toolCalls([ToolCall(
                id: "invalid-write",
                name: "write_file",
                arguments: #"{"path":"invalid.txt"}"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("I created invalid.txt."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            context: ContextBuilder(
                taskContract: contract,
                runtimeEnvironment: .cowork),
            taskAttempt: 1)

        let answer = try await loop.send("Create it.")
        XCTAssertEqual(answer, "I created invalid.txt.")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("invalid.txt").path))
    }

    func testChangedDeniedResourceHasDistinctActionIdentity() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("denial-action-identity")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = PolicyScriptedProvider([
            [.toolCalls([ToolCall(
                id: "denied-a",
                name: "write_file",
                arguments: #"{"path":"a.txt","content":"blocked"}"#)]),
             .done(finishReason: "tool_calls")],
            [.toolCalls([ToolCall(
                id: "denied-b",
                name: "write_file",
                arguments: #"{"path":"b.txt","content":"blocked"}"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("Both distinct writes were denied."), .done(finishReason: "stop")],
        ])
        let responder = CapturingPolicyResponder(.deny)
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: ToolRegistry([WriteFileTool()]),
            responder: responder)

        let answer = try await loop.send("Attempt two different writes.")

        XCTAssertEqual(answer, "Both distinct writes were denied.")
        let approvalRequests = await responder.requests()
        XCTAssertEqual(approvalRequests.count, 2)
    }

    func testCoworkRunRejectsCorruptDurableHistoryBeforeProviderDispatch() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("corrupt-cowork-history")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = PolicyScriptedProvider([[
            .textDelta("must not run"),
            .done(finishReason: "stop"),
        ]])
        let contract = TaskContract(
            id: TaskID(rawValue: "task-corrupt-cowork-history"),
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "policy-agent"),
            objective: "Do not continue from corrupt history.",
            roleHint: "worker",
            expectedDeliverable: "none")
        try Data("{\"invalid\":true}\n".utf8)
            .write(to: workspace.appendingPathComponent("events.jsonl"))
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            context: ContextBuilder(
                taskContract: contract,
                runtimeEnvironment: .cowork))

        do {
            _ = try await loop.send("Continue the task.")
            XCTFail("Cowork AgentLoop must not dispatch against corrupt durable history.")
        } catch let error as EventLogError {
            XCTAssertEqual(error, .corruptedEvent(line: 1))
        }
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testPriorAllowedWriteHistoryDoesNotBlockNewFinalResponse() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("restore-permission-resolved-window")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID(rawValue: "task-restore-permission-resolved")
        let contract = TaskContract(
            id: taskID,
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "policy-agent"),
            objective: "Write the pending file.",
            roleHint: "worker",
            expectedDeliverable: "pending.txt")
        let registry = ToolRegistry([WriteFileTool()])
        let arguments = #"{"content":"pending","path":"pending.txt"}"#
        let intent = WriteFileTool().permissionIntent(
            ToolArgs(raw: arguments),
            workspaceRoot: workspace)
        let authorization = try registry.resolveAuthorization(
            toolName: "write_file",
            intent: intent,
            risksNetwork: false,
            normalizedArguments: arguments,
            invocation: ToolAuthorizationInvocationContext(
                agent: contract.assignee,
                taskID: taskID,
                attempt: 1,
                toolCallID: "pending-write"),
            capabilityLease: nil,
            workspaceLease: nil)
        try await log.append(.permissionResolved(PermissionResolvedPayload(
            tool: "write_file",
            decision: .allow,
            risk: .medium,
            reason: "approved before the prior process stopped",
            intent: intent,
            authorization: authorization,
            source: .automaticReviewer,
            reviewStatus: .allowed)))

        let provider = PolicyScriptedProvider([[
            .textDelta("The file is complete."),
            .done(finishReason: "stop"),
        ]])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: registry,
            context: ContextBuilder(
                taskContract: contract,
                runtimeEnvironment: .cowork),
            taskAttempt: 2)

        let answer = try await loop.send("Resume the task.")
        XCTAssertEqual(answer, "The file is complete.")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("pending.txt").path))
    }

    func testPriorReviewSettlementDoesNotBlockNewFinalResponse() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("restore-review-settled-window")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID(rawValue: "task-restore-review-settled")
        let contract = TaskContract(
            id: taskID,
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "policy-agent"),
            objective: "Write the pending file.",
            roleHint: "worker",
            expectedDeliverable: "pending.txt")
        let registry = ToolRegistry([WriteFileTool()])
        let arguments = #"{"content":"pending","path":"pending.txt"}"#
        let intent = WriteFileTool().permissionIntent(
            ToolArgs(raw: arguments),
            workspaceRoot: workspace)
        let authorization = try registry.resolveAuthorization(
            toolName: "write_file",
            intent: intent,
            risksNetwork: false,
            normalizedArguments: arguments,
            invocation: ToolAuthorizationInvocationContext(
                agent: contract.assignee,
                taskID: taskID,
                attempt: 1,
                toolCallID: "pending-write"),
            capabilityLease: nil,
            workspaceLease: nil)
        try await log.append(.permissionReviewSettled(PermissionReviewSettledPayload(
            reviewTaskID: PermissionReviewTaskID(rawValue: "review-before-crash"),
            requestID: RequestID(rawValue: "request-before-crash"),
            requestingAgent: contract.assignee,
            reviewerAgent: AgentID(rawValue: "permission-reviewer"),
            reviewerModel: ModelID(rawValue: "review-model"),
            tool: "write_file",
            decision: .allow,
            risk: .medium,
            status: .allowed,
            reason: "approved before the prior process stopped",
            authorization: authorization,
            durationMillis: 1)))

        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: PolicyScriptedProvider([[
                .textDelta("The file is complete."),
                .done(finishReason: "stop"),
            ]]),
            registry: registry,
            context: ContextBuilder(
                taskContract: contract,
                runtimeEnvironment: .cowork),
            taskAttempt: 2)

        let answer = try await loop.send("Resume the task.")
        XCTAssertEqual(answer, "The file is complete.")
    }

    func testPriorSuccessfulSettlementHistoryDoesNotBlockNewFinalResponse() async throws {
        let (workspace, log) = try makeWorkspaceAndLog("restore-successful-settlement")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let taskID = TaskID(rawValue: "task-restore-success")
        let contract = TaskContract(
            id: taskID,
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "policy-agent"),
            objective: "Write the completed file.",
            roleHint: "worker",
            expectedDeliverable: "completed.txt")
        let registry = ToolRegistry([WriteFileTool()])
        let arguments = #"{"content":"complete","path":"completed.txt"}"#
        let intent = WriteFileTool().permissionIntent(
            ToolArgs(raw: arguments),
            workspaceRoot: workspace)
        let authorization = try registry.resolveAuthorization(
            toolName: "write_file",
            intent: intent,
            risksNetwork: false,
            normalizedArguments: arguments,
            invocation: ToolAuthorizationInvocationContext(
                agent: contract.assignee,
                taskID: taskID,
                attempt: 1,
                toolCallID: "completed-write"),
            capabilityLease: nil,
            workspaceLease: nil)
        let prepared = ToolExecutionPreparedPayload(
            executionID: "completed-execution",
            taskID: taskID,
            attempt: 1,
            toolCallID: "completed-write",
            agent: contract.assignee,
            tool: "write_file",
            sideEffect: .write,
            intent: intent,
            authorization: authorization)
        try await log.append([
            .permissionResolved(PermissionResolvedPayload(
                tool: "write_file",
                decision: .allow,
                risk: .medium,
                reason: "approved",
                intent: intent,
                authorization: authorization,
                source: .automaticReviewer,
                reviewStatus: .allowed)),
            .toolExecutionPrepared(prepared),
            .toolExecutionSettled(ToolExecutionSettledPayload(
                prepared: prepared,
                outcome: .succeeded)),
        ])
        let provider = PolicyScriptedProvider([[
            .textDelta("The prior write is durably complete."),
            .done(finishReason: "stop"),
        ]])
        let loop = makeLoop(
            workspace: workspace,
            log: log,
            provider: provider,
            registry: registry,
            context: ContextBuilder(
                taskContract: contract,
                runtimeEnvironment: .cowork),
            taskAttempt: 2)

        let answer = try await loop.send("Confirm the recovered task.")
        XCTAssertEqual(answer, "The prior write is durably complete.")
    }
}
