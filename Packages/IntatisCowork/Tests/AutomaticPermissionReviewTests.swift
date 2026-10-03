import XCTest
import Foundation
import IntatisAgentKernel
import IntatisConversation
import IntatisCore
import IntatisPermission
import IntatisProtocol
import IntatisProviders
import IntatisTools
@testable import IntatisCowork

private final class AutoReviewScriptedProvider: ToolCallingProvider, @unchecked Sendable {
    private var responses: [[AgentChunk]]
    private var index = 0
    private var capturedRequests: [AgentRequest] = []
    private let lock = NSLock()

    init(_ responses: [[AgentChunk]]) {
        self.responses = responses
    }

    var requests: [AgentRequest] {
        lock.withLock { capturedRequests }
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        capturedRequests.append(request)
        let chunks = responses.isEmpty ? [.done(finishReason: "stop")] : responses[min(index, responses.count - 1)]
        index += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

private final class AutoReviewCapturingProvider: ToolCallingProvider, @unchecked Sendable {
    private let chunks: [AgentChunk]
    private var capturedRequests: [AgentRequest] = []
    private let lock = NSLock()

    init(_ chunks: [AgentChunk]) {
        self.chunks = chunks
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
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

private final class AutoReviewProviderResolutionSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let providers: [ToolCallingProvider]
    private var index = 0

    init(_ providers: [ToolCallingProvider]) {
        precondition(!providers.isEmpty)
        self.providers = providers
    }

    var resolutionCount: Int { lock.withLock { index } }

    func next() -> ToolCallingProvider {
        lock.withLock {
            let provider = providers[min(index, providers.count - 1)]
            index += 1
            return provider
        }
    }
}

private actor AutoReviewPendingAllowGate {
    private var started = false
    private var released = false
    private var finished = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishedWaiters: [CheckedContinuation<Void, Never>] = []

    func startAndWaitForRelease() async {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func markFinished() {
        finished = true
        let waiters = finishedWaiters
        finishedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilFinished() async {
        if finished { return }
        await withCheckedContinuation { continuation in
            finishedWaiters.append(continuation)
        }
    }
}

private actor AutoReviewSecondResolutionGate {
    private var resolutionCount = 0
    private var secondResolutionStarted = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pauseSecondResolution() async {
        resolutionCount += 1
        guard resolutionCount == 2 else { return }
        secondResolutionStarted = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilSecondResolutionStarts() async {
        if secondResolutionStarted { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func releaseSecondResolution() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor AutoReviewReviewerRevalidationGate {
    private var reviewerResolutionCount = 0
    private var secondReviewerResolutionStarted = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pauseSecondReviewerResolution(for agent: AgentID) async {
        guard agent == Orchestrator.automaticPermissionReviewerID else { return }
        reviewerResolutionCount += 1
        guard reviewerResolutionCount == 2 else { return }
        secondReviewerResolutionStarted = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilSecondReviewerResolutionStarts() async {
        if secondReviewerResolutionStarted { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func releaseSecondReviewerResolution() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private final class AutoReviewPendingAllowProvider: ToolCallingProvider, @unchecked Sendable {
    let gate: AutoReviewPendingAllowGate

    init(gate: AutoReviewPendingAllowGate) {
        self.gate = gate
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        let gate = gate
        return AsyncThrowingStream { continuation in
            // Deliberately implementation-owned: consumer cancellation does
            // not stop this producer, exercising retired-generation/quiesce guards.
            Task.detached {
                await gate.startAndWaitForRelease()
                continuation.yield(.textDelta("late allow\nALLOW"))
                continuation.yield(.done(finishReason: "stop"))
                continuation.finish()
                await gate.markFinished()
            }
        }
    }
}

private actor AutoReviewDisableBatchGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private struct AttachOnlyResponder: PermissionResponder {
    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        request.tool == "agent.attach" ? .allow : .deny
    }
}

private struct DenyAllResponder: PermissionResponder {
    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        .deny
    }
}

private actor AutoReviewAllowingResponder: PermissionResponder {
    nonisolated let approvalMode: PermissionApprovalMode = .automaticReviewer
    private var capturedInvocations: [PermissionReviewInvocationInput] = []

    func requestApproval(
        _ request: PermissionRequestPayload
    ) async -> PermissionDecision {
        .allow
    }

    func requestResolution(
        _ request: PermissionRequestPayload,
        invocation: PermissionReviewInvocationInput
    ) async -> PermissionApprovalResolution {
        capturedInvocations.append(invocation)
        return PermissionApprovalResolution(
            decision: .allow,
            reason: "the exact bounded test action is allowed",
            risk: request.risk,
            source: .automaticReviewer,
            reviewStatus: .allowed)
    }

    func invocations() -> [PermissionReviewInvocationInput] {
        capturedInvocations
    }
}

private actor AutoReviewExecutionProbe {
    private var count = 0

    func record() { count += 1 }
    func executionCount() -> Int { count }
}

private struct AutoReviewBindingTransformTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "binding_transform_write",
        description: "Test-only write whose host authorization identity differs from raw arguments.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .string("string"),
                    "minLength": .number(1),
                ]),
            ]),
            "required": .array([.string("value")]),
            "additionalProperties": .bool(false),
        ]))

    let probe: AutoReviewExecutionProbe

    func authorizationArgumentIdentity(_ args: ToolArgs) -> String {
        "host-transformed-identity"
    }

    func execute(
        _ args: ToolArgs,
        in context: ToolContext
    ) async throws -> ToolObservation {
        await probe.record()
        return ToolObservation(text: "unexpected execution")
    }
}

private enum AutoReviewPersistenceError: Error {
    case forcedBatchFailure
}

private func autoReviewTempLog() throws -> EventLog {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-auto-review-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    return try EventLog(session: SessionID(rawValue: "auto_review"), fileURL: url)
}

private func autoReviewWorkspace() throws -> URL {
    let ws = FileManager.default.temporaryDirectory
        .appendingPathComponent("auto-review-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    return ws
}

private func autoReviewAuthorizationContext(
    reference: String,
    justification: String
) -> String {
    [
        "Relevant user evidence: \(reference).",
        "Current progress: the acting model selected this next bounded action.",
        "Action justification: \(justification)",
        "Scope: only this exact tool call and its named resources.",
        "Uncertainties: none known.",
    ].joined(separator: " ")
}

private func autoReviewArguments(
    _ businessArguments: [String: Any],
    reference: String,
    justification: String
) -> String {
    var arguments = businessArguments
    arguments[AuthorizationSidecarCodec.reservedFieldName] =
        autoReviewAuthorizationContext(
            reference: reference,
            justification: justification)
    let data = try! JSONSerialization.data(
        withJSONObject: arguments,
        options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func autoReviewWriteArgs(
    path: String,
    content: String,
    justification: String? = nil
) -> String {
    autoReviewArguments(
        ["path": path, "content": content],
        reference: "current user request for \(path)",
        justification: justification
            ?? "Writing \(path) is the next exact bounded step.")
}

private func autoReviewPromptBlock(
    _ name: String,
    in prompt: String
) -> String? {
    guard let marker = prompt.range(of: "<<<\(name)"),
          let bodyStart = prompt[marker.upperBound...].firstIndex(of: "\n"),
          let end = prompt.range(
            of: "<<<END_\(name)>>>",
            range: bodyStart..<prompt.endIndex) else {
        return nil
    }
    return String(prompt[prompt.index(after: bodyStart)..<end.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func autoReviewUserMessage(
    _ text: String,
    id: String
) -> UserMessagePayload {
    UserMessagePayload(
        text: text,
        submissionID: SubmissionID(rawValue: id))
}

final class AutomaticPermissionReviewTests: XCTestCase {
    private let main = AgentID(rawValue: "main")
    private let reviewer = Orchestrator.automaticPermissionReviewerID

    private func phaseSBinding() -> AgentInferenceBinding {
        AgentInferenceBinding(
            inferenceProfileRef: InferenceProfileRef(
                inferenceProfileID: InferenceProfileID(rawValue: "phase-s-profile"),
                inferenceProfileRevision: InferenceProfileRevision(rawValue: "revision-1")),
            inferenceConnectionID: InferenceConnectionID(rawValue: "phase-s-connection"),
            inferenceConnectionRevision: InferenceConnectionRevision(rawValue: "connection-revision-1"),
            modelID: ModelID(rawValue: "phase-s-model"),
            immutableDefinitionFingerprint: "sha256:phase-s-safe-fingerprint")
    }

    private func phaseSReviewerBinding(
        revision: String = "revision-1",
        connectionRevision: String = "connection-revision-1",
        model: String = "phase-s-reviewer-model",
        fingerprint: String = "sha256:phase-s-reviewer-safe-fingerprint"
    ) -> AgentInferenceBinding {
        AgentInferenceBinding(
            inferenceProfileRef: InferenceProfileRef(
                inferenceProfileID: InferenceProfileID(rawValue: "phase-s-reviewer-profile"),
                inferenceProfileRevision: InferenceProfileRevision(rawValue: revision)),
            inferenceConnectionID: InferenceConnectionID(rawValue: "phase-s-reviewer-connection"),
            inferenceConnectionRevision: InferenceConnectionRevision(rawValue: connectionRevision),
            modelID: ModelID(rawValue: model),
            immutableDefinitionFingerprint: fingerprint)
    }

    func testAutoCreatesReadonlyReviewerAndDefaultRemovesIt() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let provider = AutoReviewCapturingProvider([.textDelta("ok\nALLOW"),
                                                    .done(finishReason: "stop")])
        let orch = Orchestrator(log: log, allowsShell: true, responder: AttachOnlyResponder()) { _ in provider }

        let initiallyEnabled = await orch.automaticPermissionReviewEnabled()
        XCTAssertFalse(initiallyEnabled)
        let result = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)

        XCTAssertEqual(result, .enabled(reviewer))
        let enabled = await orch.automaticPermissionReviewEnabled()
        XCTAssertTrue(enabled)
        let agentsAfterEnable = await orch.agentList()
        let reviewerAgent = try XCTUnwrap(agentsAfterEnable.first { $0.name == reviewer })
        XCTAssertEqual(reviewerAgent.profile, .readOnly)
        XCTAssertEqual(reviewerAgent.coordinationDepth, 0)
        XCTAssertEqual(reviewerAgent.model, ModelID(rawValue: "reviewer-model"))

        let reviewerLease = await orch.capabilityLeaseList().first { $0.tools.isEmpty }
        XCTAssertNotNil(reviewerLease)
        let reviewerWorkspaceLease = await orch.workspaceLeaseList().first { $0.access == .readOnly }
        let reviewerWorkspaceLeaseID = try XCTUnwrap(reviewerWorkspaceLease?.id)

        let disabled = await orch.disableAutomaticPermissionReview()
        XCTAssertEqual(disabled, .disabled(reviewer))
        let enabledAfterDisable = await orch.automaticPermissionReviewEnabled()
        XCTAssertFalse(enabledAfterDisable)
        let agentsAfterDisable = await orch.agentList()
        XCTAssertNil(agentsAfterDisable.first { $0.name == reviewer })
        let events = await log.replay()
        XCTAssertTrue(events.contains { envelope in
            guard case .workspaceLeaseRevoked(let payload) = envelope.event else { return false }
            return payload.agent == reviewer && payload.leaseID == reviewerWorkspaceLeaseID
        })
        XCTAssertNil(CoworkProjection.build(from: events).workspaceLeases[reviewerWorkspaceLeaseID])
    }

    func testFreshSessionBootstrapsMainThenReviewerWithoutReviewingMainAdmission() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let reviewerProvider = AutoReviewCapturingProvider([
            .textDelta("unused\nALLOW"),
            .done(finishReason: "stop"),
        ])
        let orch = try Orchestrator.runtime(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in reviewerProvider }

        let mainResult = await orch.bootstrapMainAgent(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertEqual(mainResult, .attached(main))

        let reviewerResult = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(reviewerResult, .enabled(reviewer))
        XCTAssertTrue(reviewerProvider.requests.isEmpty)

        let events = await log.replay()
        let projection = CoworkProjection.build(from: events)
        XCTAssertEqual(Set(projection.agentRoster.keys), Set([main, reviewer]))
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionRequest(let payload) = envelope.event else { return false }
            return payload.tool == "agent.attach" && payload.agent == main
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionReviewRequested(let payload) = envelope.event else { return false }
            return payload.task.tool == "agent.attach" && payload.task.requestingAgent == main
        })
        let mainWorkspaceLeases = projection.workspaceLeaseAgents.filter { $0.value == main }
        let reviewerWorkspaceLeases = projection.workspaceLeaseAgents.filter { $0.value == reviewer }
        XCTAssertEqual(mainWorkspaceLeases.count, 1)
        XCTAssertEqual(reviewerWorkspaceLeases.count, 1)
        XCTAssertEqual(mainWorkspaceLeases.values.first, main)
        XCTAssertEqual(reviewerWorkspaceLeases.values.first, reviewer)
        XCTAssertEqual(
            mainWorkspaceLeases.keys.first.flatMap { projection.workspaceLeases[$0]?.access },
            .readWrite)
        XCTAssertEqual(
            reviewerWorkspaceLeases.keys.first.flatMap { projection.workspaceLeases[$0]?.access },
            .readOnly)
    }

    func testPhaseSFreshBootstrapPersistsSettingsAndBothRegistrationsInOneBatch() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let provider = AutoReviewCapturingProvider([.done(finishReason: "stop")])
        let binding = phaseSBinding()
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in provider }
        let settings = CoworkSessionSettings(
            sessionID: await log.sessionID,
            defaultModelID: binding.modelID.rawValue,
            defaultInferenceProfileBinding: binding,
            workspaces: [
                CoworkSessionWorkspace(
                    path: ws.path,
                    agentName: main.rawValue,
                    isPrimary: true,
                    addedAt: Date(timeIntervalSince1970: 0)),
            ])

        let result = await orch.bootstrapFreshSession(
            main: Agent(
                name: main,
                workspaceRoot: ws,
                model: binding.modelID,
                agentInferenceBinding: binding,
                profile: .reviewed,
                coordinationDepth: Agent.defaultCoordinationDepth),
            settings: settings,
            permissionReviewerModel: binding.modelID,
            permissionReviewerInferenceBinding: binding)

        XCTAssertEqual(result, .attached(main))
        XCTAssertTrue(provider.requests.isEmpty, "local registration must not issue a model request")
        let events = try await log.replayChecked()
        XCTAssertEqual(events.count, 7)
        XCTAssertTrue({ if case .sessionSettingsUpdated = events[0].event { return true }; return false }())
        XCTAssertTrue({ if case .workspaceLeaseGranted = events[1].event { return true }; return false }())
        XCTAssertTrue({ if case .capabilityLeaseCreated = events[2].event { return true }; return false }())
        XCTAssertTrue({ if case .agentAttached = events[3].event { return true }; return false }())
        XCTAssertTrue({ if case .workspaceLeaseGranted = events[4].event { return true }; return false }())
        XCTAssertTrue({ if case .capabilityLeaseCreated = events[5].event { return true }; return false }())
        XCTAssertTrue({ if case .agentAttached = events[6].event { return true }; return false }())

        let projection = CoworkProjection.build(from: events)
        XCTAssertEqual(Set(projection.agentRoster.keys), Set([main, reviewer]))
        XCTAssertEqual(projection.agentRoster[main]?.agentInferenceBinding, binding)
        XCTAssertEqual(projection.agentRoster[reviewer]?.agentInferenceBinding, binding)
        XCTAssertEqual(projection.agentRoster[reviewer]?.profile, PermissionProfile.readOnly.rawValue)
        let mainCapabilities = projection.capabilityLeaseAgents.compactMap { leaseID, agent in
            agent == main ? projection.capabilityLeases[leaseID] : nil
        }
        XCTAssertEqual(mainCapabilities.count, 1)
        XCTAssertTrue(mainCapabilities[0].tools.contains(.renameSession))
        let reviewerCapabilities = projection.capabilityLeaseAgents.compactMap { leaseID, agent in
            agent == reviewer ? projection.capabilityLeases[leaseID] : nil
        }
        XCTAssertEqual(reviewerCapabilities.count, 1)
        XCTAssertEqual(reviewerCapabilities[0].tools, [])
        let mainWorkspaceID = try XCTUnwrap(projection.workspaceLeaseAgents.first {
            $0.value == main
        }?.key)
        let reviewerWorkspaceID = try XCTUnwrap(projection.workspaceLeaseAgents.first {
            $0.value == reviewer
        }?.key)
        XCTAssertNotEqual(mainWorkspaceID, reviewerWorkspaceID)
        XCTAssertEqual(projection.workspaceLeases[mainWorkspaceID]?.access, .readWrite)
        XCTAssertEqual(projection.workspaceLeases[reviewerWorkspaceID]?.access, .readOnly)
        let automaticReviewEnabled = await orch.automaticPermissionReviewEnabled()
        XCTAssertTrue(automaticReviewEnabled)

        let document = try SessionProjectionStore.load(
            from: SessionProjectionStore.fileURL(for: log),
            expectedSession: await log.sessionID)
        XCTAssertEqual(document.projectedThroughSeq, 6)
        XCTAssertEqual(document.coworkSettings, settings)
    }

    func testPhaseSFreshBootstrapPersistsDistinctReviewerExactBinding() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let mainBinding = phaseSBinding()
        let reviewerBinding = phaseSReviewerBinding()
        let provider = AutoReviewCapturingProvider([.done(finishReason: "stop")])
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder(),
            availableInferenceProfiles: [mainBinding, reviewerBinding],
            requiresInferenceBindings: true,
            resolvedInferenceFor: { agent in
                guard let binding = agent.agentInferenceBinding else {
                    throw InferenceCatalogError.unresolvedProfile
                }
                return ResolvedInferenceProfile(
                    binding: binding,
                    model: agent.model,
                    provider: provider)
            },
            providerFor: { _ in provider })
        let settings = CoworkSessionSettings(
            sessionID: await log.sessionID,
            defaultModelID: mainBinding.modelID.rawValue,
            defaultInferenceProfileBinding: mainBinding,
            workspaces: [CoworkSessionWorkspace(
                path: ws.path,
                agentName: main.rawValue,
                isPrimary: true)])

        let result = await orch.bootstrapFreshSession(
            main: Agent(
                name: main,
                workspaceRoot: ws,
                model: mainBinding.modelID,
                agentInferenceBinding: mainBinding,
                profile: .reviewed,
                coordinationDepth: Agent.defaultCoordinationDepth),
            settings: settings,
            permissionReviewerModel: reviewerBinding.modelID,
            permissionReviewerInferenceBinding: reviewerBinding)

        XCTAssertEqual(result, .attached(main))
        XCTAssertTrue(provider.requests.isEmpty, "bootstrap resolution must not issue a model request")
        let events = try await log.replayChecked()
        XCTAssertEqual(events.count, 7)
        let projection = CoworkProjection.build(from: events)
        XCTAssertEqual(projection.agentRoster[main]?.model, mainBinding.modelID)
        XCTAssertEqual(projection.agentRoster[main]?.agentInferenceBinding, mainBinding)
        XCTAssertEqual(projection.agentRoster[reviewer]?.model, reviewerBinding.modelID)
        XCTAssertEqual(
            projection.agentRoster[reviewer]?.agentInferenceBinding,
            reviewerBinding)
        XCTAssertNotEqual(
            projection.agentRoster[main]?.agentInferenceBinding,
            projection.agentRoster[reviewer]?.agentInferenceBinding)
        XCTAssertEqual(
            projection.agentRoster[reviewer]?.profile,
            PermissionProfile.readOnly.rawValue)
    }

    func testPhaseSFreshBootstrapRejectsMissingReviewerBindingBeforeEvents() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let binding = phaseSBinding()
        let provider = AutoReviewCapturingProvider([.done(finishReason: "stop")])
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in provider }
        let settings = CoworkSessionSettings(
            sessionID: await log.sessionID,
            defaultModelID: binding.modelID.rawValue,
            defaultInferenceProfileBinding: binding,
            workspaces: [CoworkSessionWorkspace(
                path: ws.path,
                agentName: main.rawValue,
                isPrimary: true)])

        let result = await orch.bootstrapFreshSession(
            main: Agent(
                name: main,
                workspaceRoot: ws,
                model: binding.modelID,
                agentInferenceBinding: binding,
                profile: .reviewed,
                coordinationDepth: Agent.defaultCoordinationDepth),
            settings: settings,
            permissionReviewerModel: phaseSReviewerBinding().modelID,
            permissionReviewerInferenceBinding: nil)

        guard case .failed = result else {
            return XCTFail("a strict bootstrap without a reviewer binding must fail closed")
        }
        XCTAssertTrue(provider.requests.isEmpty)
        let events = try await log.replayChecked()
        let agents = await orch.agentList()
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(agents.isEmpty)
    }

    func testPhaseSFreshBootstrapRejectsMismatchedReviewerModelBeforeEvents() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let binding = phaseSBinding()
        let reviewerBinding = phaseSReviewerBinding()
        let provider = AutoReviewCapturingProvider([.done(finishReason: "stop")])
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in provider }
        let settings = CoworkSessionSettings(
            sessionID: await log.sessionID,
            defaultModelID: binding.modelID.rawValue,
            defaultInferenceProfileBinding: binding,
            workspaces: [CoworkSessionWorkspace(
                path: ws.path,
                agentName: main.rawValue,
                isPrimary: true)])

        let result = await orch.bootstrapFreshSession(
            main: Agent(
                name: main,
                workspaceRoot: ws,
                model: binding.modelID,
                agentInferenceBinding: binding,
                profile: .reviewed,
                coordinationDepth: Agent.defaultCoordinationDepth),
            settings: settings,
            permissionReviewerModel: ModelID(rawValue: "wrong-reviewer-model"),
            permissionReviewerInferenceBinding: reviewerBinding)

        guard case .failed = result else {
            return XCTFail("a mismatched reviewer model/binding tuple must fail closed")
        }
        XCTAssertTrue(provider.requests.isEmpty)
        let events = try await log.replayChecked()
        let agents = await orch.agentList()
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(agents.isEmpty)
    }

    func testPhaseSFreshBootstrapRejectsReviewerCatalogTOCTOUBeforeEvents() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let mainBinding = phaseSBinding()
        let reviewerBinding = phaseSReviewerBinding()
        let driftedReviewerBinding = phaseSReviewerBinding(
            revision: "revision-2",
            connectionRevision: "connection-revision-2",
            fingerprint: "sha256:phase-s-reviewer-drifted-fingerprint")
        let provider = AutoReviewCapturingProvider([.done(finishReason: "stop")])
        let resolutionGate = AutoReviewReviewerRevalidationGate()
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder(),
            availableInferenceProfiles: [mainBinding, reviewerBinding],
            requiresInferenceBindings: true,
            resolvedInferenceFor: { agent in
                await resolutionGate.pauseSecondReviewerResolution(for: agent.name)
                guard let binding = agent.agentInferenceBinding else {
                    throw InferenceCatalogError.unresolvedProfile
                }
                return ResolvedInferenceProfile(
                    binding: binding,
                    model: agent.model,
                    provider: provider)
            },
            providerFor: { _ in provider })
        let settings = CoworkSessionSettings(
            sessionID: await log.sessionID,
            defaultModelID: mainBinding.modelID.rawValue,
            defaultInferenceProfileBinding: mainBinding,
            workspaces: [CoworkSessionWorkspace(
                path: ws.path,
                agentName: main.rawValue,
                isPrimary: true)])

        let bootstrap = Task {
            await orch.bootstrapFreshSession(
                main: Agent(
                    name: main,
                    workspaceRoot: ws,
                    model: mainBinding.modelID,
                    agentInferenceBinding: mainBinding,
                    profile: .reviewed,
                    coordinationDepth: Agent.defaultCoordinationDepth),
                settings: settings,
                permissionReviewerModel: reviewerBinding.modelID,
                permissionReviewerInferenceBinding: reviewerBinding)
        }
        await resolutionGate.waitUntilSecondReviewerResolutionStarts()
        await orch.updateAvailableInferenceProfiles(
            [mainBinding, driftedReviewerBinding],
            hostAuthorized: true)
        await resolutionGate.releaseSecondReviewerResolution()

        let result = await bootstrap.value
        guard case .failed = result else {
            return XCTFail("reviewer catalog drift must fail the final bootstrap preflight")
        }
        XCTAssertTrue(provider.requests.isEmpty)
        let events = try await log.replayChecked()
        let agents = await orch.agentList()
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(agents.isEmpty)
    }

    func testPhaseSFreshBootstrapRejectsPermissionProfileDriftBeforePersistenceOrModelUse() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let binding = phaseSBinding()
        let provider = AutoReviewCapturingProvider([.done(finishReason: "stop")])
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in provider }
        let settings = CoworkSessionSettings(
            sessionID: await log.sessionID,
            defaultModelID: binding.modelID.rawValue,
            defaultInferenceProfileBinding: binding,
            defaultPermissionProfile: PermissionProfile.readOnly.rawValue,
            workspaces: [CoworkSessionWorkspace(
                path: ws.path,
                agentName: main.rawValue,
                isPrimary: true)])

        let result = await orch.bootstrapFreshSession(
            main: Agent(
                name: main,
                workspaceRoot: ws,
                model: binding.modelID,
                agentInferenceBinding: binding,
                profile: .reviewed,
                coordinationDepth: Agent.defaultCoordinationDepth),
            settings: settings,
            permissionReviewerModel: binding.modelID,
            permissionReviewerInferenceBinding: binding)

        guard case .failed = result else {
            return XCTFail("profile drift must reject the fixed local registration")
        }
        XCTAssertTrue(provider.requests.isEmpty)
        let replayed = try await log.replayChecked()
        let agents = await orch.agentList()
        XCTAssertTrue(replayed.isEmpty)
        XCTAssertTrue(agents.isEmpty)
    }

    func testPhaseSFreshBootstrapBatchFailureLeavesNoGhostState() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let binding = phaseSBinding()
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in
                AutoReviewCapturingProvider([.done(finishReason: "stop")])
            }
        await orch.setAdmissionEventsAppender { events in
            XCTAssertEqual(events.count, 7)
            throw AutoReviewPersistenceError.forcedBatchFailure
        }
        let settings = CoworkSessionSettings(
            sessionID: await log.sessionID,
            defaultModelID: binding.modelID.rawValue,
            defaultInferenceProfileBinding: binding,
            workspaces: [CoworkSessionWorkspace(
                path: ws.path,
                agentName: main.rawValue,
                isPrimary: true)])

        let result = await orch.bootstrapFreshSession(
            main: Agent(
                name: main,
                workspaceRoot: ws,
                model: binding.modelID,
                agentInferenceBinding: binding,
                profile: .reviewed,
                coordinationDepth: Agent.defaultCoordinationDepth),
            settings: settings,
            permissionReviewerModel: binding.modelID,
            permissionReviewerInferenceBinding: binding)

        guard case .failed = result else { return XCTFail("forced batch failure must fail") }
        let replayed = await log.replay()
        let agents = await orch.agentList()
        let workspaceLeases = await orch.workspaceLeaseList()
        let capabilityLeases = await orch.capabilityLeaseList()
        XCTAssertTrue(replayed.isEmpty)
        XCTAssertTrue(agents.isEmpty)
        XCTAssertTrue(workspaceLeases.isEmpty)
        XCTAssertTrue(capabilityLeases.isEmpty)
        let automaticReviewEnabled = await orch.automaticPermissionReviewEnabled()
        XCTAssertFalse(automaticReviewEnabled)
    }

    func testPhaseSTwoEventLogInstancesCannotBothBootstrapTheSameFreshSession() async throws {
        let firstLog = try autoReviewTempLog()
        let secondLog = try EventLog(
            session: await firstLog.sessionID,
            fileURL: firstLog.sessionDirectoryURL.appendingPathComponent("events.jsonl"))
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let binding = phaseSBinding()
        let firstProvider = AutoReviewCapturingProvider([.done(finishReason: "stop")])
        let secondProvider = AutoReviewCapturingProvider([.done(finishReason: "stop")])
        let first = Orchestrator(
            log: firstLog,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in firstProvider }
        let second = Orchestrator(
            log: secondLog,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in secondProvider }
        let settings = CoworkSessionSettings(
            sessionID: await firstLog.sessionID,
            defaultModelID: binding.modelID.rawValue,
            defaultInferenceProfileBinding: binding,
            workspaces: [CoworkSessionWorkspace(
                path: ws.path,
                agentName: main.rawValue,
                isPrimary: true)])
        let mainAgent = Agent(
            name: main,
            workspaceRoot: ws,
            model: binding.modelID,
            agentInferenceBinding: binding,
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth)

        async let firstResult = first.bootstrapFreshSession(
            main: mainAgent,
            settings: settings,
            permissionReviewerModel: binding.modelID,
            permissionReviewerInferenceBinding: binding)
        async let secondResult = second.bootstrapFreshSession(
            main: mainAgent,
            settings: settings,
            permissionReviewerModel: binding.modelID,
            permissionReviewerInferenceBinding: binding)
        let (resolvedFirst, resolvedSecond) = await (firstResult, secondResult)
        let results = [resolvedFirst, resolvedSecond]

        XCTAssertEqual(results.filter {
            if case .attached = $0 { return true }
            return false
        }.count, 1)
        XCTAssertEqual(results.filter {
            if case .failed = $0 { return true }
            return false
        }.count, 1)
        let durableEvents = try await firstLog.replayChecked()
        XCTAssertEqual(durableEvents.count, 7)
        XCTAssertTrue(firstProvider.requests.isEmpty)
        XCTAssertTrue(secondProvider.requests.isEmpty)
        let firstAgents = await first.agentList()
        let secondAgents = await second.agentList()
        let totalRuntimeAgents = firstAgents.count + secondAgents.count
        XCTAssertEqual(totalRuntimeAgents, 2, "only the winning runtime may register @main and reviewer")
    }

    func testPhaseSHistoricalMainRecoveryUsesCanonicalSettingsWithoutModelReview() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let binding = phaseSBinding()
        let settings = CoworkSessionSettings(
            sessionID: await log.sessionID,
            defaultModelID: binding.modelID.rawValue,
            defaultInferenceProfileBinding: binding,
            workspaces: [CoworkSessionWorkspace(
                path: ws.path,
                agentName: main.rawValue,
                isPrimary: true)])
        try await log.append(.sessionSettingsUpdated(SessionSettingsUpdatedPayload(
            revision: 1,
            changeKind: .migrated,
            kind: .cowork,
            cowork: settings)))
        let provider = AutoReviewCapturingProvider([.done(finishReason: "stop")])
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in provider }
        let agent = Agent(
            name: main,
            workspaceRoot: ws,
            model: binding.modelID,
            agentInferenceBinding: binding,
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth)

        let denied = await orch.restoreHistoricalMainAgent(
            agent,
            settings: settings,
            hostAuthorized: false)
        XCTAssertEqual(
            denied,
            .failed("Historical @main recovery requires explicit host authorization."))
        let deniedEvents = try await log.replayChecked()
        XCTAssertEqual(deniedEvents.count, 1)

        let recovered = await orch.restoreHistoricalMainAgent(
            agent,
            settings: settings,
            hostAuthorized: true)

        XCTAssertEqual(recovered, .attached(main))
        XCTAssertTrue(provider.requests.isEmpty)
        let events = try await log.replayChecked()
        XCTAssertEqual(events.count, 4)
        XCTAssertFalse(events.contains {
            if case .permissionRequest = $0.event { return true }
            if case .permissionReviewRequested = $0.event { return true }
            return false
        })
        let projection = CoworkProjection.build(from: events)
        XCTAssertEqual(projection.agentRoster[main]?.agentInferenceBinding, binding)
        XCTAssertEqual(projection.workspaceLeaseAgents.values.filter { $0 == main }.count, 1)
        XCTAssertEqual(projection.capabilityLeaseAgents.values.filter { $0 == main }.count, 1)
        let repeated = await orch.restoreHistoricalMainAgent(
            agent,
            settings: settings,
            hostAuthorized: true)
        XCTAssertEqual(repeated, .alreadyAttached(main))
    }

    func testPhaseSHistoricalMainRecoveryCASRejectsInvalidSettingsRevisionChain() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let binding = phaseSBinding()
        let settings = CoworkSessionSettings(
            sessionID: await log.sessionID,
            defaultModelID: binding.modelID.rawValue,
            defaultInferenceProfileBinding: binding,
            workspaces: [CoworkSessionWorkspace(
                path: ws.path,
                agentName: main.rawValue,
                isPrimary: true)])
        try await log.append(.sessionSettingsUpdated(SessionSettingsUpdatedPayload(
            revision: 1,
            changeKind: .migrated,
            kind: .cowork,
            cowork: settings)))

        let provider = AutoReviewCapturingProvider([.done(finishReason: "stop")])
        let resolutionGate = AutoReviewSecondResolutionGate()
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder(),
            availableInferenceProfiles: [binding],
            requiresInferenceBindings: true,
            resolvedInferenceFor: { agent in
                await resolutionGate.pauseSecondResolution()
                guard let resolvedBinding = agent.agentInferenceBinding else {
                    throw InferenceCatalogError.unresolvedProfile
                }
                return ResolvedInferenceProfile(
                    binding: resolvedBinding,
                    model: agent.model,
                    provider: provider)
            },
            providerFor: { _ in provider })
        let mainAgent = Agent(
            name: main,
            workspaceRoot: ws,
            model: binding.modelID,
            agentInferenceBinding: binding,
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth)

        let restoreTask = Task {
            await orch.restoreHistoricalMainAgent(
                mainAgent,
                settings: settings,
                hostAuthorized: true)
        }
        await resolutionGate.waitUntilSecondResolutionStarts()
        try await log.append(.sessionSettingsUpdated(SessionSettingsUpdatedPayload(
            revision: 3,
            previousRevision: 1,
            changeKind: .updated,
            kind: .cowork,
            cowork: settings)))
        await resolutionGate.releaseSecondResolution()

        let result = await restoreTask.value
        guard case .failed = result else {
            return XCTFail("invalid settings history must fail the final recovery CAS")
        }
        XCTAssertTrue(provider.requests.isEmpty)
        let replayed = try await log.replayChecked()
        XCTAssertEqual(replayed.count, 2)
        XCTAssertFalse(replayed.contains {
            switch $0.event {
            case .workspaceLeaseGranted, .capabilityLeaseCreated, .agentAttached:
                return true
            default:
                return false
            }
        })
        let agents = await orch.agentList()
        XCTAssertTrue(agents.isEmpty)
    }

    func testPhaseSHistoricalMainRecoveryRejectsPermissionProfileDrift() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let binding = phaseSBinding()
        let canonical = CoworkSessionSettings(
            sessionID: await log.sessionID,
            defaultModelID: binding.modelID.rawValue,
            defaultInferenceProfileBinding: binding,
            workspaces: [CoworkSessionWorkspace(
                path: ws.path,
                agentName: main.rawValue,
                isPrimary: true)])
        try await log.append(.sessionSettingsUpdated(SessionSettingsUpdatedPayload(
            revision: 1,
            changeKind: .migrated,
            kind: .cowork,
            cowork: canonical)))
        var drifted = canonical
        drifted.defaultPermissionProfile = PermissionProfile.readOnly.rawValue
        let provider = AutoReviewCapturingProvider([.done(finishReason: "stop")])
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in provider }

        let result = await orch.restoreHistoricalMainAgent(
            Agent(
                name: main,
                workspaceRoot: ws,
                model: binding.modelID,
                agentInferenceBinding: binding,
                profile: .reviewed,
                coordinationDepth: Agent.defaultCoordinationDepth),
            settings: drifted,
            hostAuthorized: true)

        guard case .failed = result else {
            return XCTFail("historical profile drift must fail closed")
        }
        XCTAssertTrue(provider.requests.isEmpty)
        let replayed = try await log.replayChecked()
        let agents = await orch.agentList()
        XCTAssertEqual(replayed.count, 1)
        XCTAssertTrue(agents.isEmpty)
    }

    func testMainBootstrapFailsClosedForNonemptySession() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        try await log.append(.error(ErrorPayload(code: "existing", message: "existing session state")))
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in
                AutoReviewScriptedProvider([[.done(finishReason: "stop")]])
            }

        let result = await orch.bootstrapMainAgent(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))

        guard case .failed(let message) = result else {
            return XCTFail("nonempty sessions must not use the bootstrap bypass")
        }
        XCTAssertTrue(message.contains("empty Cowork session"))
        let agents = await orch.agentList()
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertTrue(agents.isEmpty)
        XCTAssertNil(projection.agentRoster[main])
    }

    func testMainBootstrapTreatsUnknownStateAsNonemptyAndKnownCorruptionAsFailure() async throws {
        let encoder = Envelope.makeEncoder()
        let session = SessionID(rawValue: "auto_review")
        let valid = try encoder.encode(Envelope(
            seq: 0,
            ts: Date(timeIntervalSince1970: 0),
            session: session,
            event: .error(ErrorPayload(code: "existing", message: "state"))))
        var unknownObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: valid) as? [String: Any])
        unknownObject["type"] = "future_security_state"
        var corruptObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var corruptPayload = try XCTUnwrap(corruptObject["payload"] as? [String: Any])
        corruptPayload.removeValue(forKey: "message")
        corruptObject["payload"] = corruptPayload
        let variants: [(suffix: String, line: Data, expected: String)] = [
            ("unknown", try JSONSerialization.data(withJSONObject: unknownObject), "empty Cowork session"),
            ("corrupt-known", try JSONSerialization.data(withJSONObject: corruptObject), "could not verify"),
        ]

        for variant in variants {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "intatis-bootstrap-\(variant.suffix)-\(UUID().uuidString)",
                    isDirectory: true)
            let url = directory.appendingPathComponent("events.jsonl")
            let ws = try autoReviewWorkspace()
            defer {
                try? FileManager.default.removeItem(at: directory)
                try? FileManager.default.removeItem(at: ws)
            }
            let log = try EventLog(session: session, fileURL: url)
            var line = variant.line
            line.append(0x0A)
            try line.write(to: url, options: .atomic)
            let orch = Orchestrator(
                log: log,
                allowsShell: true,
                responder: DenyAllResponder()) { _ in
                    AutoReviewScriptedProvider([[.done(finishReason: "stop")]])
                }

            let result = await orch.bootstrapMainAgent(Agent(
                name: main,
                workspaceRoot: ws,
                model: ModelID(rawValue: "main-model"),
                profile: .reviewed,
                coordinationDepth: Agent.defaultCoordinationDepth))

            guard case .failed(let message) = result else {
                return XCTFail("bootstrap must fail closed for \(variant.suffix) log state")
            }
            XCTAssertTrue(message.contains(variant.expected), message)
            let agents = await orch.agentList()
            XCTAssertTrue(agents.isEmpty)
        }
    }

    func testMainBootstrapPersistenceFailureLeavesNoGhostAgentOrLease() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: DenyAllResponder()) { _ in
                AutoReviewScriptedProvider([[.done(finishReason: "stop")]])
            }
        let mainID = main
        await orch.setAdmissionEventsAppender { events in
            if events.contains(where: { event in
                guard case .agentAttached(let payload) = event else { return false }
                return payload.agent == mainID
            }) {
                throw AutoReviewPersistenceError.forcedBatchFailure
            }
            try await log.append(events)
        }

        let result = await orch.bootstrapMainAgent(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))

        guard case .failed = result else {
            return XCTFail("bootstrap must fail when its atomic admission batch fails")
        }
        let agents = await orch.agentList()
        let workspaceLeases = await orch.workspaceLeaseList()
        let capabilityLeases = await orch.capabilityLeaseList()
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertTrue(agents.isEmpty)
        XCTAssertTrue(workspaceLeases.isEmpty)
        XCTAssertTrue(capabilityLeases.isEmpty)
        XCTAssertNil(projection.agentRoster[main])
    }

    func testRestoreRevokesStaleReviewerIdentityAndLeasesBeforeReenable() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let provider = AutoReviewCapturingProvider([
            .textDelta("ok\nALLOW"),
            .done(finishReason: "stop"),
        ])
        let first = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { _ in provider }
        let firstEnableResult = await first.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(firstEnableResult, .enabled(reviewer))
        let firstCapabilityLeases = await first.capabilityLeaseList()
        let firstWorkspaceLeases = await first.workspaceLeaseList()
        let oldCapabilityLease = try XCTUnwrap(
            firstCapabilityLeases.first { $0.tools.isEmpty })
        let oldWorkspaceLease = try XCTUnwrap(
            firstWorkspaceLeases.first { $0.access == .readOnly })
        await first.cancelAll(reason: "simulate session close")

        let replacement = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { _ in provider }
        let beforeRestore = CoworkProjection.build(from: await log.replay())
        XCTAssertNotNil(beforeRestore.agentRoster[reviewer])
        await replacement.restore(from: beforeRestore)

        let afterRestore = CoworkProjection.build(from: await log.replay())
        XCTAssertNil(afterRestore.agentRoster[reviewer])
        XCTAssertNil(afterRestore.capabilityLeases[oldCapabilityLease.id])
        XCTAssertNil(afterRestore.workspaceLeases[oldWorkspaceLease.id])
        let replacementEnableResult = await replacement.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(replacementEnableResult, .enabled(reviewer))
        let afterReenable = CoworkProjection.build(from: await log.replay())
        let activeReviewerCapabilityLeases = afterReenable.capabilityLeaseAgents.filter {
            $0.value == reviewer
        }
        let activeReviewerWorkspaceLeases = afterReenable.workspaceLeaseAgents.filter {
            $0.value == reviewer
        }
        XCTAssertEqual(activeReviewerCapabilityLeases.count, 1)
        XCTAssertEqual(activeReviewerWorkspaceLeases.count, 1)
    }

    func testEnableAdmissionBatchFailureLeavesNoGhostReviewerLease() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let provider = AutoReviewCapturingProvider([
            .textDelta("ok\nALLOW"),
            .done(finishReason: "stop"),
        ])
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { _ in provider }
        await orch.setAdmissionEventsAppender { events in
            if events.contains(where: { event in
                guard case .agentAttached(let payload) = event else { return false }
                return payload.agent == Orchestrator.automaticPermissionReviewerID
            }) {
                throw AutoReviewPersistenceError.forcedBatchFailure
            }
            try await log.append(events)
        }

        let result = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)

        guard case .failed = result else {
            return XCTFail("reviewer enable must fail when its atomic admission batch fails")
        }
        let enabled = await orch.automaticPermissionReviewEnabled()
        XCTAssertFalse(enabled)
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertNil(projection.agentRoster[reviewer])
        XCTAssertFalse(projection.capabilityLeaseAgents.values.contains(reviewer))
        XCTAssertFalse(projection.workspaceLeaseAgents.values.contains(reviewer))
    }

    func testDisableBatchFailureLeavesReviewerHealthyAndDurablyAttached() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let provider = AutoReviewCapturingProvider([
            .textDelta("ok\nALLOW"),
            .done(finishReason: "stop"),
        ])
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { _ in provider }
        let enableResult = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(enableResult, .enabled(reviewer))
        let capabilityLeases = await orch.capabilityLeaseList()
        let workspaceLeases = await orch.workspaceLeaseList()
        let reviewerCapabilityLease = try XCTUnwrap(
            capabilityLeases.first { $0.tools.isEmpty })
        let reviewerWorkspaceLease = try XCTUnwrap(
            workspaceLeases.first { $0.access == .readOnly })
        await orch.setAdmissionEventsAppender { events in
            if events.contains(where: { event in
                if case .agentDetached = event { return true }
                return false
            }) {
                throw AutoReviewPersistenceError.forcedBatchFailure
            }
            try await log.append(events)
        }

        let disabled = await orch.disableAutomaticPermissionReview()
        let stillEnabled = await orch.automaticPermissionReviewEnabled()
        let health = await orch.automaticPermissionReviewHealth()
        let agents = await orch.agentList()
        let retainedCapabilityLease = await orch.capabilityLease(id: reviewerCapabilityLease.id)
        let retainedWorkspaceLease = await orch.workspaceLease(id: reviewerWorkspaceLease.id)
        guard case .failed(let disableMessage) = disabled else {
            return XCTFail("disable persistence failure must be distinguishable from already disabled")
        }
        XCTAssertTrue(disableMessage.contains("remains enabled"))
        XCTAssertTrue(stillEnabled)
        XCTAssertEqual(health, .healthy)
        XCTAssertNotNil(agents.first { $0.name == reviewer })
        XCTAssertNotNil(retainedCapabilityLease)
        XCTAssertNotNil(retainedWorkspaceLease)
        let events = await log.replay()
        XCTAssertFalse(events.contains { envelope in
            if case .capabilityLeaseRevoked(let payload) = envelope.event {
                return payload.agent == reviewer
            }
            if case .workspaceLeaseRevoked(let payload) = envelope.event {
                return payload.agent == reviewer
            }
            if case .agentDetached(let payload) = envelope.event {
                return payload.agent == reviewer
            }
            return false
        })
        let projection = CoworkProjection.build(from: events)
        XCTAssertNotNil(projection.agentRoster[reviewer])
        XCTAssertNotNil(projection.capabilityLeases[reviewerCapabilityLease.id])
        XCTAssertNotNil(projection.workspaceLeases[reviewerWorkspaceLease.id])
    }

    func testFailedDisableResumesWithFreshGenerationWhileRetiredAllowArrivesLate() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let preflightProvider = AutoReviewCapturingProvider([
            .done(finishReason: "stop"),
        ])
        let lateGate = AutoReviewPendingAllowGate()
        let lateProvider = AutoReviewPendingAllowProvider(gate: lateGate)
        let recoveredProvider = AutoReviewCapturingProvider([
            .textDelta("fresh review after failed disable\nALLOW"),
            .done(finishReason: "stop"),
        ])
        let reviewerProviders = AutoReviewProviderResolutionSequence([
            preflightProvider,
            lateProvider,
            recoveredProvider,
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { agent -> any ToolCallingProvider in
                if agent.name == reviewerID { return reviewerProviders.next() }
                return AutoReviewScriptedProvider([[
                    .textDelta("unused"),
                    .done(finishReason: "stop"),
                ]])
            }
        let mainAttached = await orch.attach(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(mainAttached)
        let enableResult = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(enableResult, .enabled(reviewer))

        let firstWorker = AgentID(rawValue: "worker-before-resume")
        let firstAttach = Task {
            await orch.attach(Agent(
                name: firstWorker,
                workspaceRoot: ws,
                model: ModelID(rawValue: "worker-model"),
                profile: .reviewed,
                coordinationDepth: 0))
        }
        await lateGate.waitUntilStarted()
        await orch.setAdmissionEventsAppender { events in
            if events.contains(where: { event in
                guard case .agentDetached(let payload) = event else { return false }
                return payload.agent == reviewerID
            }) {
                throw AutoReviewPersistenceError.forcedBatchFailure
            }
            try await log.append(events)
        }

        let disableResult = await orch.disableAutomaticPermissionReview()
        let firstAttached = await firstAttach.value
        guard case .failed(let message) = disableResult else {
            return XCTFail("failed reviewer detach must roll quiesce back")
        }
        XCTAssertTrue(message.contains("remains enabled"))
        XCTAssertFalse(firstAttached)
        let stillEnabled = await orch.automaticPermissionReviewEnabled()
        XCTAssertTrue(stillEnabled)

        let secondWorker = AgentID(rawValue: "worker-after-resume")
        let secondAttached = await orch.attach(Agent(
            name: secondWorker,
            workspaceRoot: ws,
            model: ModelID(rawValue: "worker-model"),
            profile: .reviewed,
            coordinationDepth: 0))
        XCTAssertTrue(secondAttached)
        XCTAssertEqual(reviewerProviders.resolutionCount, 3)
        XCTAssertTrue(preflightProvider.requests.isEmpty)
        XCTAssertEqual(recoveredProvider.requests.count, 1)
        let recoveredHealth = await orch.automaticPermissionReviewHealth()
        XCTAssertEqual(recoveredHealth, .healthy)
        let eventsBeforeLateAllow = await log.replay()
        let settlementsBeforeLateAllow = eventsBeforeLateAllow.compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settlementsBeforeLateAllow.map(\.status), [.cancelled, .allowed])
        let rosterBeforeLateAllow = CoworkProjection.build(from: eventsBeforeLateAllow).agentRoster
        XCTAssertNil(rosterBeforeLateAllow[firstWorker])
        XCTAssertNotNil(rosterBeforeLateAllow[secondWorker])

        await lateGate.release()
        await lateGate.waitUntilFinished()
        let eventsAfterLateAllow = await log.replay()
        let settlementsAfterLateAllow = eventsAfterLateAllow.compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settlementsAfterLateAllow, settlementsBeforeLateAllow)
        let rosterAfterLateAllow = CoworkProjection.build(from: eventsAfterLateAllow).agentRoster
        XCTAssertNil(rosterAfterLateAllow[firstWorker])
        XCTAssertNotNil(rosterAfterLateAllow[secondWorker])
    }

    func testDisableQuiescesPendingAllowBeforeDurableDetach() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let allowGate = AutoReviewPendingAllowGate()
        let reviewerProvider = AutoReviewPendingAllowProvider(gate: allowGate)
        let reviewerID = reviewer
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { agent in
                if agent.name == reviewerID { return reviewerProvider }
                return AutoReviewScriptedProvider([[
                    .textDelta("unused"),
                    .done(finishReason: "stop"),
                ]])
            }
        let enableResult = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(enableResult, .enabled(reviewer))

        let attachTask = Task {
            await orch.attach(Agent(
                name: main,
                workspaceRoot: ws,
                model: ModelID(rawValue: "main-model"),
                profile: .reviewed,
                coordinationDepth: Agent.defaultCoordinationDepth))
        }
        await allowGate.waitUntilStarted()

        let batchGate = AutoReviewDisableBatchGate()
        await orch.setAdmissionEventsAppender { events in
            await batchGate.pause()
            try await log.append(events)
        }
        let disableTask = Task { await orch.disableAutomaticPermissionReview() }
        await batchGate.waitUntilEntered()

        // The quiescence barrier has drained the permission job. Commit the
        // detach, then let the implementation-owned producer emit its late
        // `allow`; it must no longer be able to authorize the attach.
        await batchGate.release()
        let disabled = await disableTask.value
        await allowGate.release()
        await allowGate.waitUntilFinished()
        let attached = await attachTask.value

        XCTAssertEqual(disabled, .disabled(reviewer))
        XCTAssertFalse(attached)
        let events = await log.replay()
        let reviewerDetachSeq = try XCTUnwrap(events.first { envelope in
            guard case .agentDetached(let payload) = envelope.event else { return false }
            return payload.agent == reviewer
        }?.seq)
        XCTAssertFalse(events.contains { envelope in
            guard envelope.seq >= reviewerDetachSeq,
                  case .permissionReviewSettled(let payload) = envelope.event else { return false }
            return payload.decision == .allow
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionResolved(let payload) = envelope.event else { return false }
            return payload.tool == "agent.attach" && payload.decision == .allow
        })
        let projection = CoworkProjection.build(from: events)
        XCTAssertNil(projection.agentRoster[reviewer])
        XCTAssertNil(projection.agentRoster[main])
    }

    func testCallerCancellationCannotAttachAfterLateReviewerAllow() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let allowGate = AutoReviewPendingAllowGate()
        let reviewerProvider = AutoReviewPendingAllowProvider(gate: allowGate)
        let reviewerID = reviewer
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { agent in
                if agent.name == reviewerID { return reviewerProvider }
                return AutoReviewScriptedProvider([[
                    .textDelta("unused"),
                    .done(finishReason: "stop"),
                ]])
            }
        let mainAttached = await orch.attach(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(mainAttached)
        let enabled = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(enabled, .enabled(reviewer))

        let worker = AgentID(rawValue: "worker-cancelled-before-late-allow")
        let attachTask = Task {
            await orch.attach(Agent(
                name: worker,
                workspaceRoot: ws,
                model: ModelID(rawValue: "worker-model"),
                profile: .reviewed,
                coordinationDepth: 0))
        }
        await allowGate.waitUntilStarted()

        attachTask.cancel()
        await allowGate.release()
        await allowGate.waitUntilFinished()
        let attached = await attachTask.value

        XCTAssertFalse(attached)
        let events = await log.replay()
        let projection = CoworkProjection.build(from: events)
        XCTAssertNil(projection.agentRoster[worker])
        let settlements = events.compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settlements.last?.status, .cancelled)
        XCTAssertEqual(settlements.last?.decision, .deny)
        let attachDecisions = events.compactMap { envelope -> PermissionResolvedPayload? in
            guard case .permissionResolved(let payload) = envelope.event,
                  payload.tool == "agent.attach" else { return nil }
            return payload
        }
        XCTAssertEqual(attachDecisions.last?.decision, .deny)
    }

    func testCallerCancellationDuringPostReviewInferenceResolutionCannotCommitAttach() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let binding = phaseSBinding()
        let provider = AutoReviewCapturingProvider([.done(finishReason: "stop")])
        let resolutionGate = AutoReviewSecondResolutionGate()
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder(),
            availableInferenceProfiles: [binding],
            requiresInferenceBindings: true,
            resolvedInferenceFor: { agent in
                await resolutionGate.pauseSecondResolution()
                guard let resolvedBinding = agent.agentInferenceBinding else {
                    throw InferenceCatalogError.unresolvedProfile
                }
                return ResolvedInferenceProfile(
                    binding: resolvedBinding,
                    model: agent.model,
                    provider: provider)
            },
            providerFor: { _ in provider })
        let worker = AgentID(rawValue: "worker-cancelled-during-post-review-resolution")
        let attachTask = Task {
            await orch.attach(Agent(
                name: worker,
                workspaceRoot: ws,
                model: binding.modelID,
                agentInferenceBinding: binding,
                profile: .reviewed,
                coordinationDepth: 0))
        }
        await resolutionGate.waitUntilSecondResolutionStarts()

        attachTask.cancel()
        await resolutionGate.releaseSecondResolution()
        let attached = await attachTask.value

        XCTAssertFalse(attached)
        XCTAssertTrue(provider.requests.isEmpty)
        let events = try await log.replayChecked()
        let projection = CoworkProjection.build(from: events)
        XCTAssertNil(projection.agentRoster[worker])
        XCTAssertFalse(events.contains { envelope in
            if case .workspaceLeaseGranted(let payload) = envelope.event {
                return payload.agent == worker
            }
            if case .capabilityLeaseCreated(let payload) = envelope.event {
                return payload.agent == worker
            }
            if case .agentAttached(let payload) = envelope.event {
                return payload.agent == worker
            }
            return false
        })
        let attachDecisions = events.compactMap { envelope -> PermissionResolvedPayload? in
            guard case .permissionResolved(let payload) = envelope.event,
                  payload.tool == "agent.attach" else { return nil }
            return payload
        }
        XCTAssertEqual(attachDecisions.last?.decision, .deny)
        XCTAssertEqual(attachDecisions.last?.source, .callerCancellation)
        XCTAssertEqual(attachDecisions.last?.reviewStatus, .cancelled)
        XCTAssertEqual(attachDecisions.last?.failureKind, .callerCancelled)
    }

    func testAttachRejectsWorkspaceRootReplacedWhileReviewIsPending() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        let moved = ws.deletingLastPathComponent()
            .appendingPathComponent("\(ws.lastPathComponent)-reviewed")
        defer {
            try? FileManager.default.removeItem(at: ws)
            try? FileManager.default.removeItem(at: moved)
        }
        let allowGate = AutoReviewPendingAllowGate()
        let reviewerProvider = AutoReviewPendingAllowProvider(gate: allowGate)
        let reviewerID = reviewer
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { agent in
                if agent.name == reviewerID { return reviewerProvider }
                return AutoReviewScriptedProvider([[
                    .textDelta("unused"),
                    .done(finishReason: "stop"),
                ]])
            }
        let enableResult = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(enableResult, .enabled(reviewer))

        let attachTask = Task {
            await orch.attach(Agent(
                name: main,
                workspaceRoot: ws,
                model: ModelID(rawValue: "main-model"),
                profile: .reviewed,
                coordinationDepth: Agent.defaultCoordinationDepth))
        }
        await allowGate.waitUntilStarted()
        try FileManager.default.moveItem(at: ws, to: moved)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        await allowGate.release()

        let attached = await attachTask.value
        let agents = await orch.agentList()
        XCTAssertFalse(attached)
        XCTAssertNil(agents.first { $0.name == main })
        let events = await log.replay()
        XCTAssertTrue(events.contains { envelope in
            guard case .permissionResolved(let payload) = envelope.event else { return false }
            return payload.tool == "agent.attach"
                && payload.decision == .deny
                && payload.reason.contains("identity changed")
        })
    }

    func testReviewerCanApproveMainAttachBeforeMainExists() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let reviewerProvider = AutoReviewCapturingProvider([
            .textDelta("workspace attach matches session root\nALLOW"),
            .done(finishReason: "stop"),
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(log: log, allowsShell: true, responder: DenyAllResponder()) { agent in
            if agent.name == reviewerID {
                return reviewerProvider
            }
            return AutoReviewScriptedProvider([[.textDelta("unused"), .done(finishReason: "stop")]])
        }

        let enableResult = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(enableResult, .enabled(reviewer))

        let attached = await orch.attach(Agent(name: main,
                                               workspaceRoot: ws,
                                               model: ModelID(rawValue: "main-model"),
                                               profile: .reviewed,
                                               coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        XCTAssertEqual(reviewerProvider.requests.count, 1)
        let prompt = try XCTUnwrap(reviewerProvider.requests.first?.messages.compactMap(\.content).joined(separator: "\n"))
        XCTAssertTrue(prompt.contains("tool: agent.attach"))
        XCTAssertTrue(prompt.contains("requesting_agent: @main"))
        XCTAssertTrue(prompt.contains("Directly related causal events:"))

        let reviews = await log.replay().compactMap { envelope -> PermissionReviewPayload? in
            if case .permissionReview(let payload) = envelope.event {
                return payload
            }
            return nil
        }
        XCTAssertEqual(reviews.last?.tool, "agent.attach")
        XCTAssertEqual(reviews.last?.decision, .allow)
    }

    func testReviewerSeesFrozenWorkerAttachContractAndCommittedLeasesMatch() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let reviewerProvider = AutoReviewCapturingProvider([
            .textDelta("reviewed worker admission\nALLOW"),
            .done(finishReason: "stop"),
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(log: log, allowsShell: true, responder: DenyAllResponder()) { agent in
            if agent.name == reviewerID {
                return reviewerProvider
            }
            return AutoReviewScriptedProvider([[.textDelta("unused"), .done(finishReason: "stop")]])
        }
        let enableResult = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(enableResult, .enabled(reviewer))

        let workerID = AgentID(rawValue: "worker-admission")
        let attached = await orch.attach(Agent(
            name: workerID,
            workspaceRoot: ws,
            model: ModelID(rawValue: "worker-model"),
            profile: .reviewed,
            coordinationDepth: 0))

        XCTAssertTrue(attached)
        XCTAssertEqual(reviewerProvider.requests.count, 1)
        let events = await log.replay()
        let reviewTask = try XCTUnwrap(events.compactMap { envelope -> PermissionReviewTask? in
            guard case .permissionReviewRequested(let payload) = envelope.event,
                  payload.task.requestingAgent == workerID,
                  payload.task.tool == "agent.attach" else { return nil }
            return payload.task
        }.first)
        let taskID = try XCTUnwrap(reviewTask.taskID)
        let proposedCapability = try XCTUnwrap(reviewTask.capabilityLease)
        let proposedWorkspace = try XCTUnwrap(reviewTask.workspaceLease)
        let contract = try XCTUnwrap(reviewTask.taskContract)

        XCTAssertEqual(reviewTask.rootTaskID, taskID)
        XCTAssertNil(reviewTask.parentTaskID)
        XCTAssertEqual(reviewTask.attempt, 1)
        XCTAssertEqual(reviewTask.causalContext.taskLineage, [taskID])
        XCTAssertEqual(contract.id, taskID)
        XCTAssertEqual(contract.kind, .agentAdmission)
        XCTAssertEqual(contract.assignee, workerID)
        XCTAssertEqual(contract.workspaceID, proposedWorkspace.workspaceID)
        XCTAssertEqual(contract.workspaceLeaseID, proposedWorkspace.id)
        XCTAssertEqual(contract.capabilityLeaseID, proposedCapability.id)
        XCTAssertEqual(proposedWorkspace.access, .readWrite)
        XCTAssertFalse(proposedCapability.tools.contains(.delegateTask))
        XCTAssertFalse(proposedCapability.tools.contains(.attachWorkspace))
        XCTAssertEqual(proposedCapability.delegation, .none)

        let authorization = try XCTUnwrap(reviewTask.authorization)
        XCTAssertEqual(
            reviewTask.normalizedArgs,
            "digest=\(authorization.normalizedArgumentsDigest); characters=\(authorization.normalizedArgumentsCharacterCount)")
        XCTAssertEqual(reviewTask.intent?.metadata["canCoordinate"], .bool(false))
        XCTAssertEqual(authorization.taskID, taskID)
        XCTAssertEqual(authorization.capabilityLeaseID, proposedCapability.id)
        XCTAssertEqual(authorization.workspaceLeaseID, proposedWorkspace.id)

        let committedCapability = try XCTUnwrap(events.compactMap { envelope -> CapabilityLease? in
            guard case .capabilityLeaseCreated(let payload) = envelope.event,
                  payload.agent == workerID else { return nil }
            return payload.lease
        }.last)
        let committedWorkspace = try XCTUnwrap(events.compactMap { envelope -> WorkspaceLease? in
            guard case .workspaceLeaseGranted(let payload) = envelope.event,
                  payload.agent == workerID else { return nil }
            return payload.lease
        }.last)
        XCTAssertEqual(committedCapability, proposedCapability)
        XCTAssertEqual(committedWorkspace, proposedWorkspace)
        let attachedMetadata = try XCTUnwrap(events.compactMap { envelope -> CoworkEventMetadata? in
            guard case .agentAttached(let payload) = envelope.event,
                  payload.agent == workerID else { return nil }
            return payload.metadata
        }.last)
        XCTAssertEqual(attachedMetadata.taskID, taskID)
        XCTAssertEqual(attachedMetadata.rootTaskID, taskID)
        XCTAssertEqual(attachedMetadata.workspaceLeaseID, proposedWorkspace.id)
        XCTAssertEqual(attachedMetadata.capabilityLeaseID, proposedCapability.id)

        let prompt = try XCTUnwrap(
            reviewerProvider.requests.first?.messages.compactMap(\.content).joined(separator: "\n"))
        XCTAssertTrue(prompt.contains("task_id: \(taskID.rawValue)"))
        XCTAssertTrue(prompt.contains("root_task_id: \(taskID.rawValue)"))
        XCTAssertTrue(prompt.contains("kind=agent_admission"))
        XCTAssertTrue(prompt.contains("capability_lease: id=\(proposedCapability.id.rawValue)"))
        XCTAssertTrue(prompt.contains("workspace_lease: id=\(proposedWorkspace.id.rawValue)"))
        XCTAssertTrue(prompt.contains("canCoordinate=false"))
    }

    func testSpawnToolUsesOneAutomaticReviewAndCommitsCoordinatorAdmissionAtomically() async throws {
        let log = try autoReviewTempLog()
        let mainWorkspace = try autoReviewWorkspace()
        let childWorkspace = mainWorkspace.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: childWorkspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mainWorkspace) }
        let spawnArgs = autoReviewArguments(
            [
                "name": "coordinator-admission",
                "path": childWorkspace.path,
                "canCoordinate": true,
            ],
            reference: "current coordinator creation request",
            justification:
                "Creating this one bounded coordinator is the requested next step.")
        let mainProvider = AutoReviewScriptedProvider([
            [.toolCalls([ToolCall(id: "spawn-once", name: "spawn_agent", arguments: spawnArgs)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("coordinator created"), .done(finishReason: "stop")],
        ])
        let reviewerProvider = AutoReviewCapturingProvider([
            .textDelta("bounded coordinator spawn\nALLOW"),
            .done(finishReason: "stop"),
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(log: log, allowsShell: true, responder: AttachOnlyResponder()) { agent -> any ToolCallingProvider in
            if agent.name == reviewerID {
                return reviewerProvider
            }
            return mainProvider
        }
        let mainAttached = await orch.attach(Agent(
            name: main,
            workspaceRoot: mainWorkspace,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(mainAttached)
        let enabled = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: mainWorkspace)
        XCTAssertEqual(enabled, .enabled(reviewer))

        let sent = await orch.send(
            "create one coordinator for child",
            to: main,
            userMessage: autoReviewUserMessage(
                "create one coordinator for child",
                id: "submission_spawn_coordinator"))
        XCTAssertEqual(sent, .sent)

        let childID = AgentID(rawValue: "coordinator-admission")
        let events = await log.replay()
        let reviewTasks = events.compactMap { envelope -> PermissionReviewTask? in
            guard case .permissionReviewRequested(let payload) = envelope.event else { return nil }
            return payload.task
        }
        XCTAssertEqual(reviewerProvider.requests.count, 1)
        XCTAssertEqual(reviewTasks.filter { $0.tool == "spawn_agent" }.count, 1)
        XCTAssertFalse(reviewTasks.contains { $0.tool == "agent.attach" && $0.requestingAgent == childID })
        let spawnReview = try XCTUnwrap(reviewTasks.first { $0.tool == "spawn_agent" })
        XCTAssertEqual(spawnReview.requestingAgent, main)
        let spawnAuthorization = try XCTUnwrap(spawnReview.authorization)
        XCTAssertEqual(
            spawnReview.normalizedArgs,
            "digest=\(spawnAuthorization.normalizedArgumentsDigest); characters=\(spawnAuthorization.normalizedArgumentsCharacterCount)")
        XCTAssertTrue(spawnReview.touchedPaths.isEmpty)
        XCTAssertEqual(spawnReview.intent?.action, "agent.spawn")
        XCTAssertEqual(spawnReview.intent?.dataEffects, [.none])
        XCTAssertEqual(
            spawnReview.intent?.controlEffects,
            [.createAgent, .attachWorkspace, .grantCapability])
        XCTAssertEqual(spawnReview.intent?.metadata["canCoordinate"], .bool(true))
        XCTAssertEqual(spawnReview.intent?.metadata["requestedAccess"],
                       .string(WorkspaceAccess.readOnly.rawValue))

        let committedCapability = try XCTUnwrap(events.compactMap { envelope -> CapabilityLease? in
            guard case .capabilityLeaseCreated(let payload) = envelope.event,
                  payload.agent == childID else { return nil }
            return payload.lease
        }.last)
        let committedWorkspace = try XCTUnwrap(events.compactMap { envelope -> WorkspaceLease? in
            guard case .workspaceLeaseGranted(let payload) = envelope.event,
                  payload.agent == childID else { return nil }
            return payload.lease
        }.last)
        XCTAssertEqual(committedWorkspace.rootPath, childWorkspace.resolvingSymlinksInPath().path)
        XCTAssertEqual(committedWorkspace.access, .readOnly)
        XCTAssertTrue(committedCapability.tools.contains(.delegateTask))
        XCTAssertTrue(committedCapability.tools.contains(.attachWorkspace))
        XCTAssertFalse(committedCapability.tools.contains(.applyPatch))
        if case .granted(let budget) = committedCapability.delegation {
            XCTAssertEqual(budget.maxDepth, 0)
        } else {
            XCTFail("committed coordinator lease must include delegation")
        }
        XCTAssertTrue(events.contains {
            guard case .agentSpawned(let payload) = $0.event else { return false }
            return payload.agent == childID && payload.requestedBy == main
        })
    }

    func testReviewerApprovesWorkspaceWriteWithoutTerminalApproval() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let priorPDFSentinel =
            "PDF_FULLTEXT_SENTINEL_THIS_MUST_STAY_WITH_THE_ACTING_MODEL"
        let rawSidecarSentinel =
            "MODEL_SIDECAR_RAW_SENTINEL_DO_NOT_PERSIST"
        try await log.append(.userMessage(autoReviewUserMessage(
            priorPDFSentinel,
            id: "submission_prior_pdf_context")))
        let mainProvider = AutoReviewScriptedProvider([
            [.toolCalls([ToolCall(id: "write", name: "write_file",
                                  arguments: autoReviewWriteArgs(
                                    path: "auto.txt",
                                    content: "approved",
                                    justification:
                                        "Writing auto.txt is exactly what the user requested. \(rawSidecarSentinel)"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("done"), .done(finishReason: "stop")],
        ])
        let reviewerProvider = AutoReviewCapturingProvider([
            .textDelta("matches the user request\nALLOW"),
            .done(finishReason: "stop"),
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(log: log, allowsShell: true, responder: AttachOnlyResponder()) { agent in
            if agent.name == reviewerID {
                return reviewerProvider
            }
            return mainProvider
        }

        let mainAttached = await orch.attach(Agent(name: main,
                                                   workspaceRoot: ws,
                                                   model: ModelID(rawValue: "main-model"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(mainAttached)
        let enableResult = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(enableResult, .enabled(reviewer))

        let result = await orch.send(
            "create auto.txt with approved",
            to: main,
            userMessage: autoReviewUserMessage(
                "create auto.txt with approved",
                id: "submission_create_auto"))

        XCTAssertEqual(result, OrchestratorSendResult.sent)
        XCTAssertEqual(try String(contentsOf: ws.appendingPathComponent("auto.txt"), encoding: .utf8),
                       "approved")
        let reviewRequest = try XCTUnwrap(reviewerProvider.requests.first)
        XCTAssertEqual(reviewRequest.model, ModelID(rawValue: "reviewer-model"))
        XCTAssertTrue(reviewRequest.tools.isEmpty)
        XCTAssertNil(reviewRequest.temperature)
        XCTAssertNil(reviewRequest.maxOutputTokens)
        let prompt = reviewRequest.messages.compactMap(\.content).joined(separator: "\n")
        XCTAssertTrue(prompt.contains("Active agent roster:"))
        XCTAssertTrue(prompt.contains("@main"))
        XCTAssertTrue(prompt.contains("Directly related causal events:"))
        XCTAssertFalse(prompt.contains("create auto.txt with approved"),
                       "the reviewer must rely on the acting model's bounded sidecar rather than receive raw user-message text")
        XCTAssertTrue(prompt.contains("<<<EXACT_BUSINESS_ARGUMENTS"))
        XCTAssertTrue(prompt.contains(#"{"content":"approved","path":"auto.txt"}"#))
        XCTAssertTrue(prompt.contains("<<<MODEL_AUTHORIZATION_CONTEXT"))
        XCTAssertTrue(prompt.contains(
            "Writing auto.txt is exactly what the user requested."))
        XCTAssertTrue(prompt.contains(rawSidecarSentinel),
                      "the live reviewer must receive the acting model's sidecar")
        XCTAssertFalse(prompt.contains(priorPDFSentinel),
                       "the reviewer must not receive prior raw PDF/history text")
        XCTAssertTrue(prompt.contains("write_file"))
        XCTAssertTrue(prompt.contains("membership=granted"))
        XCTAssertTrue(prompt.contains("canonical_permission=filesystem.edit"))
        XCTAssertFalse(prompt.contains("required_capabilities=[apply_patch]"))
        XCTAssertFalse(prompt.contains("lease-inconsistent"))

        XCTAssertEqual(mainProvider.requests.count, 2,
                       "the acting model must not be called again as a reporter")
        let actingWriteSpec = try XCTUnwrap(
            mainProvider.requests[0].tools.first { $0.name == "write_file" })
        guard case .object(let writeSchema) = actingWriteSpec.parameters,
              case .object(let writeProperties)? = writeSchema["properties"],
              case .array(let writeRequired)? = writeSchema["required"] else {
            return XCTFail("automatic Cowork tools must expose the sidecar schema")
        }
        XCTAssertNotNil(writeProperties[
            AuthorizationSidecarCodec.reservedFieldName])
        XCTAssertTrue(writeRequired.contains(
            .string(AuthorizationSidecarCodec.reservedFieldName)))
        let liveHistoryCall = try XCTUnwrap(
            mainProvider.requests[1].messages
                .compactMap(\.toolCalls)
                .flatMap { $0 }
                .first { $0.id == "write" })
        let liveHistoryArguments = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(liveHistoryCall.arguments.utf8))
                as? [String: Any])
        XCTAssertEqual(liveHistoryArguments["path"] as? String, "auto.txt")
        XCTAssertEqual(liveHistoryArguments["content"] as? String, "approved")
        let liveHistoryContext = try XCTUnwrap(
            liveHistoryArguments[
                AuthorizationSidecarCodec.reservedFieldName
            ] as? String)
        XCTAssertTrue(
            liveHistoryContext.contains(rawSidecarSentinel),
            "the same turn's next acting request must retain the valid call shape instead of teaching the model that an ask-class call succeeds without its required sidecar")

        let events = await log.replay()
        XCTAssertTrue(events.contains { envelope in
            guard case .userMessage(let payload) = envelope.event else {
                return false
            }
            return payload.text == priorPDFSentinel
        }, "the excluded prior PDF/history text must still exist durably")
        let permissionRequest = try XCTUnwrap(events.compactMap {
            envelope -> PermissionRequestPayload? in
            guard case .permissionRequest(let payload) = envelope.event,
                  payload.context?.toolCallID == "write" else {
                return nil
            }
            return payload
        }.last)
        let evidenceMetadata = try XCTUnwrap(
            permissionRequest.context?.reviewInvocationEvidence)
        XCTAssertEqual(evidenceMetadata.status, .valid)
        XCTAssertFalse(evidenceMetadata.sourceGenerationID.isEmpty)
        XCTAssertFalse(evidenceMetadata.toolSnapshotID.isEmpty)
        XCTAssertFalse(
            evidenceMetadata.modelAuthorizationContextDigest.isEmpty)
        let reviews = events.compactMap { envelope -> PermissionReviewPayload? in
            if case .permissionReview(let payload) = envelope.event {
                return payload
            }
            return nil
        }
        XCTAssertEqual(reviews.last?.decision, .allow)
        XCTAssertEqual(reviews.last?.reviewerModel, "@permission-reviewer:reviewer-model")
        let requested = try XCTUnwrap(events.compactMap { envelope -> PermissionReviewTask? in
            if case .permissionReviewRequested(let payload) = envelope.event { return payload.task }
            return nil
        }.last)
        let settled = try XCTUnwrap(events.compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }.last)
        let resolved = try XCTUnwrap(events.compactMap { envelope -> PermissionResolvedPayload? in
            if case .permissionResolved(let payload) = envelope.event,
               payload.tool == "write_file",
               payload.requestId != nil { return payload }
            return nil
        }.last)
        let prepared = try XCTUnwrap(events.compactMap { envelope -> ToolExecutionPreparedPayload? in
            if case .toolExecutionPrepared(let payload) = envelope.event,
               payload.tool == "write_file" { return payload }
            return nil
        }.last)
        let executionSettled = try XCTUnwrap(events.compactMap { envelope -> ToolExecutionSettledPayload? in
            if case .toolExecutionSettled(let payload) = envelope.event,
               payload.tool == "write_file" { return payload }
            return nil
        }.last)
        let authorization = try XCTUnwrap(requested.authorization)
        XCTAssertEqual(authorization.membership, .granted)
        XCTAssertEqual(authorization.requiredCapabilities, [.applyPatch])
        XCTAssertEqual(authorization.canonicalAction, "filesystem.write")
        XCTAssertEqual(authorization.deterministicGate?.decision, .pass)
        XCTAssertEqual(settled.authorization, authorization)
        XCTAssertEqual(resolved.authorization, authorization)
        XCTAssertEqual(prepared.authorization, authorization)
        XCTAssertEqual(executionSettled.authorization, authorization)
        XCTAssertEqual(resolved.source, .automaticReviewer)
        XCTAssertEqual(resolved.reviewTaskID, requested.id)
        XCTAssertEqual(resolved.reviewStatus, .allowed)
        let durableBytes = try events.map {
            String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
        }.joined(separator: "\n")
        XCTAssertFalse(durableBytes.contains(
            AuthorizationSidecarCodec.reservedFieldName),
            "raw authorization sidecars are transient and must not enter EventLog/model history")
        XCTAssertFalse(durableBytes.contains(rawSidecarSentinel),
                       "only sidecar binding metadata may be durable")
    }

    func testOneAssistantBatchBindsEachAskClassCallIndependently()
        async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let mainProvider = AutoReviewScriptedProvider([
            [
                .toolCalls([
                    ToolCall(
                        id: "write-first",
                        name: "write_file",
                        arguments: autoReviewWriteArgs(
                            path: "first.txt",
                            content: "first",
                            justification:
                                "The first exact write creates first.txt.")),
                    ToolCall(
                        id: "write-second",
                        name: "write_file",
                        arguments: autoReviewWriteArgs(
                            path: "second.txt",
                            content: "second",
                            justification:
                                "The second exact write creates second.txt.")),
                ]),
                .done(finishReason: "tool_calls"),
            ],
            [.textDelta("done"), .done(finishReason: "stop")],
        ])
        let reviewerProvider = AutoReviewScriptedProvider([
            [
                .textDelta("first requested file\nALLOW"),
                .done(finishReason: "stop"),
            ],
            [
                .textDelta("second requested file\nALLOW"),
                .done(finishReason: "stop"),
            ],
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { agent -> any ToolCallingProvider in
                agent.name == reviewerID
                    ? reviewerProvider
                    : mainProvider
            }
        let attached = await orch.attach(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let enabled = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertTrue(attached)
        XCTAssertEqual(enabled, .enabled(reviewer))

        let result = await orch.send(
            "create first.txt and second.txt",
            to: main,
            userMessage: autoReviewUserMessage(
                "create first.txt and second.txt",
                id: "submission_two_writes"))

        XCTAssertEqual(result, .sent)
        XCTAssertEqual(
            try String(
                contentsOf: ws.appendingPathComponent("first.txt"),
                encoding: .utf8),
            "first")
        XCTAssertEqual(
            try String(
                contentsOf: ws.appendingPathComponent("second.txt"),
                encoding: .utf8),
            "second")
        XCTAssertEqual(mainProvider.requests.count, 2,
                       "a multi-call batch must not trigger reporter generations")
        XCTAssertFalse(mainProvider.requests.contains { request in
            request.tools.contains {
                $0.name == "submit_permission_authorization"
            }
        })
        XCTAssertEqual(reviewerProvider.requests.count, 2)
        let reviewerPrompts = reviewerProvider.requests.map {
            $0.messages.compactMap(\.content).joined(separator: "\n")
        }
        let firstBusinessBlock = try XCTUnwrap(autoReviewPromptBlock(
            "EXACT_BUSINESS_ARGUMENTS",
            in: reviewerPrompts[0]))
        let firstContextBlock = try XCTUnwrap(autoReviewPromptBlock(
            "MODEL_AUTHORIZATION_CONTEXT",
            in: reviewerPrompts[0]))
        let secondBusinessBlock = try XCTUnwrap(autoReviewPromptBlock(
            "EXACT_BUSINESS_ARGUMENTS",
            in: reviewerPrompts[1]))
        let secondContextBlock = try XCTUnwrap(autoReviewPromptBlock(
            "MODEL_AUTHORIZATION_CONTEXT",
            in: reviewerPrompts[1]))
        XCTAssertTrue(firstBusinessBlock.contains(
            #"{"content":"first","path":"first.txt"}"#))
        XCTAssertTrue(firstContextBlock.contains(
            "The first exact write creates first.txt."))
        XCTAssertFalse(firstContextBlock.contains("second.txt"))
        XCTAssertTrue(secondBusinessBlock.contains(
            #"{"content":"second","path":"second.txt"}"#))
        XCTAssertTrue(secondContextBlock.contains(
            "The second exact write creates second.txt."))
        XCTAssertFalse(secondContextBlock.contains("first.txt"))
        let reviewTasks = await log.replay().compactMap {
            envelope -> PermissionReviewTask? in
            guard case .permissionReviewRequested(let payload) =
                    envelope.event,
                  payload.task.toolCallID == "write-first"
                    || payload.task.toolCallID == "write-second" else {
                return nil
            }
            return payload.task
        }
        XCTAssertEqual(reviewTasks.count, 2)
        XCTAssertTrue(reviewTasks.allSatisfy {
            $0.causalContext.authorizationContext == nil
        })
        let permissionRequests = await log.replay().compactMap {
            envelope -> PermissionRequestPayload? in
            guard case .permissionRequest(let payload) = envelope.event,
                  payload.context?.toolCallID == "write-first"
                    || payload.context?.toolCallID == "write-second" else {
                return nil
            }
            return payload
        }
        XCTAssertEqual(permissionRequests.count, 2)
        let firstEvidence = try XCTUnwrap(
            permissionRequests[0].context?.reviewInvocationEvidence)
        let secondEvidence = try XCTUnwrap(
            permissionRequests[1].context?.reviewInvocationEvidence)
        XCTAssertEqual(firstEvidence.status, .valid)
        XCTAssertEqual(secondEvidence.status, .valid)
        XCTAssertEqual(firstEvidence.sourceGenerationID,
                       secondEvidence.sourceGenerationID,
                       "calls from one assistant batch share one generation")
        XCTAssertEqual(firstEvidence.toolSnapshotID,
                       secondEvidence.toolSnapshotID,
                       "calls from one assistant batch share one tool snapshot")
        XCTAssertNotEqual(
            firstEvidence.modelAuthorizationContextDigest,
            secondEvidence.modelAuthorizationContextDigest,
            "each call must retain its own model-authored context binding")
        XCTAssertNotEqual(
            permissionRequests[0].context?.authorization?
                .normalizedArgumentsDigest,
            permissionRequests[1].context?.authorization?
                .normalizedArgumentsDigest,
            "each call must retain its own exact business-argument binding")
    }

    func testMissingAndMalformedSidecarsReturnCorrectableResultsBeforePermissionRequest()
        async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let malformedArguments = String(
            decoding: try JSONSerialization.data(
                withJSONObject: [
                    "path": "malformed-sidecar.txt",
                    "content": "written after correction",
                    AuthorizationSidecarCodec.reservedFieldName: [
                        "goal": "MALFORMED_SIDECAR_RAW_SENTINEL_DO_NOT_PERSIST",
                    ],
                ],
                options: [.sortedKeys]),
            as: UTF8.self)
        let mainProvider = AutoReviewScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "write-missing-sidecar",
                    name: "write_file",
                    arguments: #"{"path":"malformed-sidecar.txt","content":"unapproved missing context"}"#)]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .toolCalls([ToolCall(
                    id: "write-malformed-sidecar",
                    name: "write_file",
                    arguments: malformedArguments)]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .toolCalls([ToolCall(
                    id: "write-corrected-sidecar",
                    name: "write_file",
                    arguments: autoReviewWriteArgs(
                        path: "malformed-sidecar.txt",
                        content: "written after correction",
                        justification:
                            "The corrected exact write follows the current request."))]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .textDelta("The corrected write completed."),
                .done(finishReason: "stop"),
            ],
        ])
        let reviewerProvider = AutoReviewCapturingProvider([
            .textDelta("the regenerated call has complete bounded evidence\nALLOW"),
            .done(finishReason: "stop"),
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { agent -> any ToolCallingProvider in
                agent.name == reviewerID ? reviewerProvider : mainProvider
            }
        let attached = await orch.attach(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let enabled = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertTrue(attached)
        XCTAssertEqual(enabled, .enabled(reviewer))

        let result = await orch.send(
            "write malformed-sidecar.txt",
            to: main,
            userMessage: autoReviewUserMessage(
                "write malformed-sidecar.txt",
                id: "submission_malformed_sidecar"))

        XCTAssertEqual(result, .sent)
        XCTAssertEqual(
            try String(
                contentsOf: ws.appendingPathComponent(
                    "malformed-sidecar.txt"),
                encoding: .utf8),
            "written after correction")
        XCTAssertEqual(reviewerProvider.requests.count, 1)
        XCTAssertEqual(mainProvider.requests.count, 4,
                       "correction must stay in the ordinary tool loop without a reporter request")
        let events = await log.replay()
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionRequest(let payload) = envelope.event else {
                return false
            }
            return payload.context?.toolCallID == "write-missing-sidecar"
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionRequest(let payload) = envelope.event else {
                return false
            }
            return payload.context?.toolCallID == "write-malformed-sidecar"
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionReviewRequested(let payload) = envelope.event else {
                return false
            }
            return payload.task.toolCallID == "write-missing-sidecar"
                || payload.task.toolCallID == "write-malformed-sidecar"
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionReviewSettled(let payload) = envelope.event else {
                return false
            }
            return payload.authorization?.toolCallID == "write-missing-sidecar"
                || payload.authorization?.toolCallID == "write-malformed-sidecar"
        })
        let missingCorrections = events.compactMap {
            envelope -> ToolResultPayload? in
            guard case .toolResult(let payload) = envelope.event,
                  payload.toolCallId == "write-missing-sidecar" else {
                return nil
            }
            return payload
        }
        XCTAssertEqual(missingCorrections.count, 1)
        let missingCorrection = try XCTUnwrap(missingCorrections.first)
        XCTAssertEqual(missingCorrection.outcome, .failed)
        XCTAssertEqual(missingCorrection.failureSource, .runtimeFailed)
        XCTAssertNil(missingCorrection.permissionRequestID)
        XCTAssertTrue(missingCorrection.observation.hasPrefix(
            "authorization_context_missing:"))
        let malformedCorrections = events.compactMap {
            envelope -> ToolResultPayload? in
            guard case .toolResult(let payload) = envelope.event,
                  payload.toolCallId == "write-malformed-sidecar" else {
                return nil
            }
            return payload
        }
        XCTAssertEqual(malformedCorrections.count, 1)
        let malformedCorrection = try XCTUnwrap(
            malformedCorrections.first)
        XCTAssertEqual(malformedCorrection.outcome, .failed)
        XCTAssertEqual(malformedCorrection.failureSource, .runtimeFailed)
        XCTAssertNil(malformedCorrection.permissionRequestID)
        XCTAssertTrue(malformedCorrection.observation.hasPrefix(
            "authorization_context_malformed:"))
        let correctableCallIDs: Set<String> = [
            "write-missing-sidecar",
            "write-malformed-sidecar",
        ]
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionResolved(let payload) = envelope.event,
                  let callID = payload.toolCallID else {
                return false
            }
            return correctableCallIDs.contains(callID)
        }, "the reviewer has not run, so tool-input contract failures must not be recorded as permission settlements")
        for callID in correctableCallIDs {
            let callEnvelope = try XCTUnwrap(events.first { envelope in
                guard case .toolCall(let payload) = envelope.event else {
                    return false
                }
                return payload.toolCallId == callID
            })
            let resultEnvelope = try XCTUnwrap(events.first { envelope in
                guard case .toolResult(let payload) = envelope.event else {
                    return false
                }
                return payload.toolCallId == callID
            })
            guard case .toolCall(let durableCall) = callEnvelope.event,
                  case .toolResult(let failedResult) = resultEnvelope.event else {
                return XCTFail("Expected a sidecar-free call and correctable tool-input result")
            }
            XCTAssertFalse(durableCall.args.contains(
                AuthorizationSidecarCodec.reservedFieldName))
            XCTAssertNil(failedResult.permissionRequestID)
            XCTAssertEqual(failedResult.outcome, .failed)
            XCTAssertEqual(failedResult.failureSource, .runtimeFailed)
            XCTAssertEqual(
                resultEnvelope.seq,
                callEnvelope.seq + 1,
                "the sidecar-free call must be followed directly by its tool-input failure")
        }
        XCTAssertTrue(mainProvider.requests[1].messages.contains { message in
            message.role == .tool
                && message.toolCallId == "write-missing-sidecar"
                && message.content?.hasPrefix(
                    "authorization_context_missing:") == true
        })
        XCTAssertTrue(mainProvider.requests[2].messages.contains { message in
            message.role == .tool
                && message.toolCallId == "write-malformed-sidecar"
                && message.content?.hasPrefix(
                    "authorization_context_malformed:") == true
        })
        XCTAssertFalse(mainProvider.requests.dropFirst(2).contains { request in
            request.messages.contains { message in
                message.content?.contains(
                    "MALFORMED_SIDECAR_RAW_SENTINEL_DO_NOT_PERSIST") == true
                    || message.toolCalls?.contains {
                        $0.arguments.contains(
                            "MALFORMED_SIDECAR_RAW_SENTINEL_DO_NOT_PERSIST")
                    } == true
            }
        }, "malformed raw sidecar text must not enter model history")
        XCTAssertFalse(events.contains { envelope in
            guard case .toolExecutionPrepared(let payload) = envelope.event else {
                return false
            }
            return payload.toolCallID == "write-missing-sidecar"
                || payload.toolCallID == "write-malformed-sidecar"
        })
        XCTAssertTrue(events.contains { envelope in
            guard case .permissionRequest(let payload) = envelope.event else {
                return false
            }
            return payload.context?.toolCallID == "write-corrected-sidecar"
        })
        let durableBytes = try events.map {
            String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
        }.joined(separator: "\n")
        XCTAssertFalse(durableBytes.contains(
            "MALFORMED_SIDECAR_RAW_SENTINEL_DO_NOT_PERSIST"))
    }

    func testTwoMissingSidecarsForSameBusinessArgumentsDoNotPoisonCorrectedCall()
        async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let businessArguments: [String: Any] = [
            "path": "same-business-arguments.txt",
            "content": "written only after valid review",
        ]
        let missingSidecarArguments = String(
            decoding: try JSONSerialization.data(
                withJSONObject: businessArguments,
                options: [.sortedKeys]),
            as: UTF8.self)
        let validSidecarArguments = autoReviewArguments(
            businessArguments,
            reference: "current request for same-business-arguments.txt",
            justification:
                "This exact regenerated call contains the required bounded authorization context.")
        let preRequestFailureCallIDs: Set<String> = [
            "same-args-missing-sidecar-1",
            "same-args-missing-sidecar-2",
        ]
        let correctedCallID = "same-args-valid-sidecar"
        let mainProvider = AutoReviewScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "same-args-missing-sidecar-1",
                    name: "write_file",
                    arguments: missingSidecarArguments)]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .toolCalls([ToolCall(
                    id: "same-args-missing-sidecar-2",
                    name: "write_file",
                    arguments: missingSidecarArguments)]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .toolCalls([ToolCall(
                    id: correctedCallID,
                    name: "write_file",
                    arguments: validSidecarArguments)]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .textDelta("The corrected write completed."),
                .done(finishReason: "stop"),
            ],
        ])
        let reviewerProvider = AutoReviewCapturingProvider([
            .textDelta("the exact regenerated call is bounded\nALLOW"),
            .done(finishReason: "stop"),
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { agent -> any ToolCallingProvider in
                agent.name == reviewerID ? reviewerProvider : mainProvider
            }
        let attached = await orch.attach(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let enabled = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertTrue(attached)
        XCTAssertEqual(enabled, .enabled(reviewer))

        let result = await orch.send(
            "write same-business-arguments.txt",
            to: main,
            userMessage: autoReviewUserMessage(
                "write same-business-arguments.txt",
                id: "submission_same_business_arguments"))

        XCTAssertEqual(
            result,
            .sent,
            "a corrected third call must not trip repeated_denied_tool_call")
        XCTAssertEqual(
            try String(
                contentsOf: ws.appendingPathComponent(
                    "same-business-arguments.txt"),
                encoding: .utf8),
            "written only after valid review")
        XCTAssertEqual(mainProvider.requests.count, 4)
        XCTAssertEqual(reviewerProvider.requests.count, 1,
                       "only the valid third call may reach the reviewer")

        let events = await log.replay()
        let preRequestResults = events.compactMap {
            envelope -> ToolResultPayload? in
            guard case .toolResult(let payload) = envelope.event,
                  preRequestFailureCallIDs.contains(payload.toolCallId) else {
                return nil
            }
            return payload
        }
        XCTAssertEqual(preRequestResults.count, 2)
        for toolResult in preRequestResults {
            XCTAssertEqual(toolResult.outcome, .failed)
            XCTAssertEqual(toolResult.failureSource, .runtimeFailed)
            XCTAssertNil(toolResult.permissionRequestID)
            XCTAssertTrue(toolResult.observation.hasPrefix(
                "authorization_context_missing:"))
        }
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionResolved(let payload) = envelope.event else {
                return false
            }
            return payload.toolCallID.map(preRequestFailureCallIDs.contains)
                == true
        }, "a missing required sidecar is a correctable tool-input failure, not a reviewer failure")
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionRequest(let payload) = envelope.event else {
                return false
            }
            return payload.context?.toolCallID.map(
                preRequestFailureCallIDs.contains) == true
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionReviewRequested(let payload) = envelope.event else {
                return false
            }
            return payload.task.toolCallID.map(
                preRequestFailureCallIDs.contains) == true
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionReviewSettled(let payload) = envelope.event,
                  let callID = payload.authorization?.toolCallID else {
                return false
            }
            return preRequestFailureCallIDs.contains(callID)
        })

        let reviewedCallIDs = events.compactMap {
            envelope -> String? in
            guard case .permissionRequest(let payload) = envelope.event else {
                return nil
            }
            guard let callID = payload.context?.toolCallID,
                  preRequestFailureCallIDs.contains(callID)
                    || callID == correctedCallID else {
                return nil
            }
            return callID
        }
        XCTAssertEqual(reviewedCallIDs, [correctedCallID])
        XCTAssertEqual(events.compactMap { envelope -> String? in
            guard case .permissionReviewRequested(let payload) = envelope.event else {
                return nil
            }
            guard let callID = payload.task.toolCallID,
                  preRequestFailureCallIDs.contains(callID)
                    || callID == correctedCallID else {
                return nil
            }
            return callID
        }, [correctedCallID])
        XCTAssertTrue(events.contains { envelope in
            guard case .toolExecutionSettled(let payload) = envelope.event else {
                return false
            }
            return payload.toolCallID == correctedCallID
                && payload.outcome == .succeeded
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .error(let payload) = envelope.event else {
                return false
            }
            return payload.code == "repeated_denied_tool_call"
        })

        let durableCalls = events.compactMap {
            envelope -> ToolCallPayload? in
            guard case .toolCall(let payload) = envelope.event,
                  preRequestFailureCallIDs.contains(payload.toolCallId)
                    || payload.toolCallId == correctedCallID else {
                return nil
            }
            return payload
        }
        XCTAssertEqual(durableCalls.count, 3)
        XCTAssertEqual(Set(durableCalls.compactMap(\.argsDigest)).count, 1,
                       "all three attempts must bind the same stripped business arguments")
        XCTAssertTrue(durableCalls.allSatisfy {
            !$0.args.contains(AuthorizationSidecarCodec.reservedFieldName)
        })
        let finalActingRequest = try XCTUnwrap(
            mainProvider.requests.dropFirst(3).first)
        let liveCorrectedCall = try XCTUnwrap(
            finalActingRequest.messages
                .compactMap(\.toolCalls)
                .flatMap { $0 }
                .first { $0.id == correctedCallID })
        XCTAssertTrue(liveCorrectedCall.arguments.contains(
            AuthorizationSidecarCodec.reservedFieldName),
            "the valid successful call must remain a valid example in same-turn acting history")
    }

    func testSecretSidecarFailsWhileCustomAuthorizationIdentityRemainsBound()
        async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let secretSentinel =
            "ghp_0123456789abcdefghijklmnopqrstuvwxyzSECRET_SIDECAR_SENTINEL"
        let secretContext = autoReviewAuthorizationContext(
            reference: "current secret-safe write request",
            justification: "The requested write is bounded.")
            + " Secret-bearing material: \(secretSentinel)"
        let secretArguments = String(decoding: try JSONSerialization.data(
            withJSONObject: [
                "path": "must-not-exist.txt",
                "content": "safe business content",
                AuthorizationSidecarCodec.reservedFieldName: secretContext,
            ],
            options: [.sortedKeys]), as: UTF8.self)
        let bindingProbe = AutoReviewExecutionProbe()
        let provider = AutoReviewScriptedProvider([
            [
                .toolCalls([
                    ToolCall(
                        id: "write-secret-sidecar",
                        name: "write_file",
                        arguments: secretArguments),
                    ToolCall(
                        id: "write-custom-identity",
                        name: AutoReviewBindingTransformTool.descriptor.name,
                        arguments: autoReviewArguments(
                            ["value": "bounded"],
                            reference: "current custom identity binding request",
                            justification:
                                "The exact test call is the requested bounded action.")),
                ]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .textDelta("The secret-bearing call was rejected and the bound call completed."),
                .done(finishReason: "stop"),
            ],
        ])
        let responder = AutoReviewAllowingResponder()
        let taskID = TaskID(rawValue: "task-secret-unbound-sidecars")
        let assignee = AgentID(rawValue: "sidecar-contract-agent")
        let contract = TaskContract(
            id: taskID,
            issuer: main,
            assignee: assignee,
            objective: "Exercise secret rejection and custom identity binding.",
            roleHint: "worker",
            expectedDeliverable: "one input failure and one successful call")
        let loop = AgentLoop(
            log: log,
            provider: provider,
            registry: ToolRegistry([
                WriteFileTool(),
                AutoReviewBindingTransformTool(probe: bindingProbe),
            ]),
            engine: PermissionEngine(),
            responder: responder,
            agent: Agent(
                name: assignee,
                workspaceRoot: ws,
                model: ModelID(rawValue: "sidecar-contract-model"),
                profile: .reviewed),
            context: ContextBuilder(
                taskContract: contract,
                runtimeEnvironment: .cowork),
            allowsShell: false,
            maxIterations: 2,
            rootTaskID: taskID,
            taskAttempt: 1)

        let answer = try await loop.send(
            "Exercise secret rejection and custom identity binding.")
        XCTAssertEqual(
            answer,
            "The secret-bearing call was rejected and the bound call completed.")

        let capturedInvocations = await responder.invocations()
        let bindingExecutionCount = await bindingProbe.executionCount()
        XCTAssertEqual(capturedInvocations.count, 1)
        XCTAssertEqual(bindingExecutionCount, 1)
        XCTAssertEqual(
            capturedInvocations.first?.canonicalBusinessArguments,
            #"{"value":"bounded"}"#)
        XCTAssertEqual(
            capturedInvocations.first?.businessArgumentsDigest,
            ToolRegistry.authorizationDigest(#"{"value":"bounded"}"#))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ws.appendingPathComponent("must-not-exist.txt").path))
        XCTAssertFalse(provider.requests.dropFirst().contains { request in
            request.messages.contains { message in
                message.content?.contains(secretSentinel) == true
                    || message.toolCalls?.contains {
                        $0.arguments.contains(secretSentinel)
                    } == true
            }
        })

        let events = await log.replay()
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionRequest(let payload) = envelope.event else {
                return false
            }
            return payload.context?.toolCallID == "write-secret-sidecar"
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionReviewRequested(let payload) = envelope.event else {
                return false
            }
            return payload.task.toolCallID == "write-secret-sidecar"
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionReviewSettled(let payload) = envelope.event else {
                return false
            }
            return payload.authorization?.toolCallID == "write-secret-sidecar"
        })

        let secretCallEnvelope = try XCTUnwrap(events.first { envelope in
            guard case .toolCall(let payload) = envelope.event else {
                return false
            }
            return payload.toolCallId == "write-secret-sidecar"
        })
        let secretResultEnvelope = try XCTUnwrap(events.first { envelope in
            guard case .toolResult(let payload) = envelope.event else {
                return false
            }
            return payload.toolCallId == "write-secret-sidecar"
        })
        guard case .toolCall(let durableSecretCall) = secretCallEnvelope.event,
              case .toolResult(let secretResult) = secretResultEnvelope.event else {
            return XCTFail("Expected a sidecar-free call and tool-input failure")
        }
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionResolved(let payload) = envelope.event else {
                return false
            }
            return payload.toolCallID == "write-secret-sidecar"
        })
        XCTAssertFalse(durableSecretCall.args.contains(
            AuthorizationSidecarCodec.reservedFieldName))
        XCTAssertEqual(secretResult.outcome, .failed)
        XCTAssertEqual(secretResult.failureSource, .runtimeFailed)
        XCTAssertNil(secretResult.permissionRequestID)
        XCTAssertTrue(secretResult.observation.hasPrefix(
            "authorization_context_secret_bearing:"))
        XCTAssertEqual(secretResultEnvelope.seq, secretCallEnvelope.seq + 1)

        let customResolvedEnvelope = try XCTUnwrap(events.first { envelope in
            guard case .permissionResolved(let payload) = envelope.event else {
                return false
            }
            return payload.toolCallID == "write-custom-identity"
        })
        let customResultEnvelope = try XCTUnwrap(events.first { envelope in
            guard case .toolResult(let payload) = envelope.event else {
                return false
            }
            return payload.toolCallId == "write-custom-identity"
        })
        guard case .permissionResolved(let customResolved) =
            customResolvedEnvelope.event,
            case .toolResult(let customResult) = customResultEnvelope.event else {
            return XCTFail("Expected an allowed custom-identity execution")
        }
        XCTAssertNotNil(customResolved.requestId)
        XCTAssertEqual(customResolved.decision, .allow)
        XCTAssertEqual(customResolved.source, .automaticReviewer)
        XCTAssertEqual(customResolved.reviewStatus, .allowed)
        XCTAssertNil(customResolved.failureKind)
        XCTAssertNil(customResolved.failureSource)
        let customAuthorization = try XCTUnwrap(
            customResolved.authorization)
        XCTAssertEqual(
            customAuthorization.normalizedArgumentsDigest,
            ToolRegistry.authorizationDigest("host-transformed-identity"))
        XCTAssertNotEqual(
            customAuthorization.normalizedArgumentsDigest,
            capturedInvocations.first?.businessArgumentsDigest)
        XCTAssertEqual(customResolved.intent, customAuthorization.intent)
        XCTAssertEqual(customAuthorization.taskID, taskID)
        XCTAssertEqual(
            customAuthorization.toolCallID,
            "write-custom-identity")
        XCTAssertEqual(customResolved.turnID, customResult.turnID)
        XCTAssertEqual(customResult.outcome, .succeeded)
        XCTAssertNil(customResult.failureSource)
        let durableBytes = try events.map {
            String(decoding: try Envelope.makeEncoder().encode($0), as: UTF8.self)
        }.joined(separator: "\n")
        XCTAssertFalse(durableBytes.contains(secretSentinel))
    }

    func testRestartDoesNotRestoreMissingSidecarAsPermissionDenialAndCorrectionSucceeds()
        async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let taskID = TaskID(rawValue: "task-restart-sidecar-denial")
        let assignee = AgentID(rawValue: "restart-sidecar-agent")
        let contract = TaskContract(
            id: taskID,
            issuer: main,
            assignee: assignee,
            objective: "Create restart-sidecar.txt.",
            roleHint: "worker",
            expectedDeliverable: "restart-sidecar.txt")
        let context = ContextBuilder(
            taskContract: contract,
            runtimeEnvironment: .cowork)
        let registry = ToolRegistry([WriteFileTool()])
        let responder = AutoReviewAllowingResponder()
        let makeLoop: (ToolCallingProvider, Int, Int) -> AgentLoop = {
            provider, maxIterations, attempt in
            AgentLoop(
                log: log,
                provider: provider,
                registry: registry,
                engine: PermissionEngine(),
                responder: responder,
                agent: Agent(
                    name: assignee,
                    workspaceRoot: ws,
                    model: ModelID(rawValue: "restart-sidecar-model"),
                    profile: .reviewed),
                context: context,
                allowsShell: false,
                maxIterations: maxIterations,
                rootTaskID: taskID,
                taskAttempt: attempt)
        }

        let firstLoop = makeLoop(AutoReviewScriptedProvider([[
            .toolCalls([ToolCall(
                id: "restart-missing-sidecar",
                name: "write_file",
                arguments:
                    #"{"path":"restart-sidecar.txt","content":"recovered"}"#)]),
            .done(finishReason: "tool_calls"),
        ]]), 1, 1)
        do {
            _ = try await firstLoop.send("Create restart-sidecar.txt.")
            XCTFail("The first process boundary should stop after the denied call.")
        } catch let error as AgentLoopError {
            XCTAssertEqual(error, .maxIterationsExceeded(limit: 1))
        }

        let firstEvents = await log.replay()
        XCTAssertFalse(firstEvents.contains { envelope in
            guard case .permissionResolved(let payload) = envelope.event else {
                return false
            }
            return payload.toolCallID == "restart-missing-sidecar"
        })
        XCTAssertFalse(firstEvents.contains { envelope in
            switch envelope.event {
            case .permissionRequest(let payload):
                return payload.context?.toolCallID == "restart-missing-sidecar"
            case .permissionReviewRequested(let payload):
                return payload.task.toolCallID == "restart-missing-sidecar"
            case .permissionReviewSettled(let payload):
                return payload.authorization?.toolCallID
                    == "restart-missing-sidecar"
            default:
                return false
            }
        })
        let missingCallEnvelope = try XCTUnwrap(firstEvents.first { envelope in
            guard case .toolCall(let payload) = envelope.event else {
                return false
            }
            return payload.toolCallId == "restart-missing-sidecar"
        })
        let missingResultEnvelope = try XCTUnwrap(firstEvents.first { envelope in
            guard case .toolResult(let payload) = envelope.event else {
                return false
            }
            return payload.toolCallId == "restart-missing-sidecar"
        })
        guard case .toolCall(let missingCall) = missingCallEnvelope.event,
              case .toolResult(let missingResult) = missingResultEnvelope.event else {
            return XCTFail("Expected a sidecar-free call and tool-input failure")
        }
        XCTAssertFalse(missingCall.args.contains(
            AuthorizationSidecarCodec.reservedFieldName))
        XCTAssertEqual(missingResult.outcome, .failed)
        XCTAssertEqual(missingResult.failureSource, .runtimeFailed)
        XCTAssertNil(missingResult.permissionRequestID)
        XCTAssertTrue(missingResult.observation.hasPrefix(
            "authorization_context_missing:"))
        XCTAssertEqual(missingResultEnvelope.seq, missingCallEnvelope.seq + 1)

        let replayedFinalLoop = makeLoop(AutoReviewScriptedProvider([[
            .textDelta("The file is complete."),
            .done(finishReason: "stop"),
        ]]), 1, 2)
        let replayedAnswer = try await replayedFinalLoop.send(
            "Resume and report the missing-sidecar input failure.")
        XCTAssertEqual(replayedAnswer, "The file is complete.")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ws.appendingPathComponent("restart-sidecar.txt").path))

        let correctedLoop = makeLoop(AutoReviewScriptedProvider([
            [
                .toolCalls([ToolCall(
                    id: "restart-corrected-sidecar",
                    name: "write_file",
                    arguments: autoReviewWriteArgs(
                        path: "restart-sidecar.txt",
                        content: "recovered",
                        justification:
                            "This corrected exact call creates the requested file."))]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .textDelta("The corrected write completed."),
                .done(finishReason: "stop"),
            ],
        ]), 2, 3)
        let answer = try await correctedLoop.send(
            "Regenerate the exact call with valid authorization context.")

        XCTAssertEqual(answer, "The corrected write completed.")
        XCTAssertEqual(
            try String(
                contentsOf: ws.appendingPathComponent("restart-sidecar.txt"),
                encoding: .utf8),
            "recovered")
        let reviewInvocationCount = await responder.invocations().count
        XCTAssertEqual(reviewInvocationCount, 1)
        let finalEvents = await log.replay()
        XCTAssertTrue(finalEvents.contains { envelope in
            guard case .toolExecutionSettled(let payload) = envelope.event else {
                return false
            }
            return payload.toolCallID == "restart-corrected-sidecar"
                && payload.outcome == .succeeded
        })
    }

    func testTimedOutReviewDeniesOnlyItsToolAndFreshGenerationCanExecuteNextTool() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let mainProvider = AutoReviewScriptedProvider([
            [.toolCalls([ToolCall(
                id: "write-timed-out-generation",
                name: "write_file",
                arguments: autoReviewWriteArgs(
                    path: "timed-out.txt",
                    content: "must not be written",
                    justification:
                        "The first exact file write follows the first user request."))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("first write was denied"), .done(finishReason: "stop")],
            [.toolCalls([ToolCall(
                id: "write-fresh-generation",
                name: "write_file",
                arguments: autoReviewWriteArgs(
                    path: "fresh.txt",
                    content: "fresh generation approved",
                    justification:
                        "The fresh file write follows the second user request."))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("second write completed"), .done(finishReason: "stop")],
        ])
        let lateGate = AutoReviewPendingAllowGate()
        let lateProvider = AutoReviewPendingAllowProvider(gate: lateGate)
        let preflightProvider = AutoReviewCapturingProvider([
            .done(finishReason: "stop"),
        ])
        let recoveredProvider = AutoReviewCapturingProvider([
            .textDelta("fresh generation matches the second request\nALLOW"),
            .done(finishReason: "stop"),
        ])
        let reviewerProviders = AutoReviewProviderResolutionSequence([
            preflightProvider,
            lateProvider,
            recoveredProvider,
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { agent -> any ToolCallingProvider in
                if agent.name == reviewerID { return reviewerProviders.next() }
                return mainProvider
            }
        let attached = await orch.attach(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        let enabled = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws,
            policy: PermissionReviewControlPlanePolicy(
                timeoutSeconds: 0.03,
                tokenBudget: 50_000,
                estimatedCompletionTokens: 64,
                maxRecentEvents: 12))
        XCTAssertEqual(enabled, .enabled(reviewer))

        let first = await orch.send(
            "write timed-out.txt",
            to: main,
            userMessage: autoReviewUserMessage(
                "write timed-out.txt",
                id: "submission_timed_out_write"))
        let firstPath = ws.appendingPathComponent("timed-out.txt")
        XCTAssertEqual(first, .sent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPath.path))

        let second = await orch.send(
            "write fresh.txt",
            to: main,
            userMessage: autoReviewUserMessage(
                "write fresh.txt",
                id: "submission_fresh_write"))
        let secondPath = ws.appendingPathComponent("fresh.txt")
        XCTAssertEqual(second, .sent)
        XCTAssertEqual(
            try String(contentsOf: secondPath, encoding: .utf8),
            "fresh generation approved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPath.path))
        XCTAssertEqual(reviewerProviders.resolutionCount, 3)
        XCTAssertTrue(preflightProvider.requests.isEmpty)
        XCTAssertEqual(recoveredProvider.requests.count, 1)

        let eventsBeforeLateAllow = await log.replay()
        let reviewSettlements = eventsBeforeLateAllow.compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(reviewSettlements.map(\.status), [.timedOut, .allowed])
        XCTAssertEqual(reviewSettlements.map(\.decision), [.deny, .allow])
        let permissionDecisions = eventsBeforeLateAllow.compactMap { envelope -> PermissionResolvedPayload? in
            guard case .permissionResolved(let payload) = envelope.event,
                  payload.tool == "write_file" else { return nil }
            return payload
        }
        XCTAssertEqual(permissionDecisions.map(\.decision), [.deny, .allow])
        let executionSettlements = eventsBeforeLateAllow.compactMap { envelope -> ToolExecutionSettledPayload? in
            guard case .toolExecutionSettled(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertFalse(executionSettlements.contains {
            $0.toolCallID == "write-timed-out-generation" && $0.outcome == .succeeded
        })
        XCTAssertEqual(executionSettlements.filter {
            $0.toolCallID == "write-fresh-generation" && $0.outcome == .succeeded
        }.count, 1)

        await lateGate.release()
        await lateGate.waitUntilFinished()
        let eventsAfterLateAllow = await log.replay()
        let settlementsAfterLateAllow = eventsAfterLateAllow.compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(settlementsAfterLateAllow, reviewSettlements)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPath.path))
    }

    func testCancellingActiveTasksKeepsAutomaticReviewerAvailableForNextRequest() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let mainProvider = AutoReviewScriptedProvider([
            [.toolCalls([ToolCall(
                id: "write-after-cancel",
                name: "write_file",
                arguments: autoReviewWriteArgs(
                    path: "after-cancel.txt",
                    content: "reviewed",
                    justification:
                        "The bounded after-cancel write is the current user request."))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("done"), .done(finishReason: "stop")],
        ])
        let reviewerProvider = AutoReviewCapturingProvider([
            .textDelta("next request remains reviewable\nALLOW"),
            .done(finishReason: "stop"),
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { agent -> any ToolCallingProvider in
                if agent.name == reviewerID { return reviewerProvider }
                return mainProvider
            }
        let attached = await orch.attach(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        let enabled = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(enabled, .enabled(reviewer))

        await orch.cancelActiveTasks(reason: "cancelled by user")

        let stillEnabled = await orch.automaticPermissionReviewEnabled()
        let health = await orch.automaticPermissionReviewHealth()
        let sent = await orch.send(
            "write after-cancel.txt",
            to: main,
            userMessage: autoReviewUserMessage(
                "write after-cancel.txt",
                id: "submission_after_cancel"))
        XCTAssertTrue(stillEnabled)
        XCTAssertEqual(health, .healthy)
        XCTAssertEqual(sent, .sent)
        XCTAssertEqual(
            try String(
                contentsOf: ws.appendingPathComponent("after-cancel.txt"),
                encoding: .utf8),
            "reviewed")
        XCTAssertEqual(reviewerProvider.requests.count, 1)
    }

    func testMalformedReviewerOutputIsNormalizedToAutomaticDenyWithoutFallback()
        async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let mainProvider = AutoReviewScriptedProvider([
            [.toolCalls([ToolCall(id: "write", name: "write_file",
                                  arguments: autoReviewWriteArgs(path: "fallback.txt", content: "blocked"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("not written"), .done(finishReason: "stop")],
        ])
        let reviewerProvider = AutoReviewCapturingProvider([
            .textDelta("ambiguous output without a final verdict marker"),
            .done(finishReason: "stop"),
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(log: log, allowsShell: true, responder: AttachOnlyResponder()) { agent in
            if agent.name == reviewerID {
                return reviewerProvider
            }
            return mainProvider
        }

        let mainAttached = await orch.attach(Agent(name: main,
                                                   workspaceRoot: ws,
                                                   model: ModelID(rawValue: "main-model"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(mainAttached)
        _ = await orch.enableAutomaticPermissionReview(model: ModelID(rawValue: "reviewer-model"), workspaceRoot: ws)

        let sendResult = await orch.send(
            "write fallback.txt",
            to: main,
            userMessage: autoReviewUserMessage(
                "write fallback.txt",
                id: "submission_fallback_write"))
        XCTAssertEqual(sendResult, .sent)

        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("fallback.txt").path))
        let reviews = await log.replay().compactMap { envelope -> PermissionReviewPayload? in
            if case .permissionReview(let payload) = envelope.event {
                return payload
            }
            return nil
        }
        XCTAssertEqual(reviews.last?.decision, .deny)
    }

    func testReviewerDenyUsesBoundedHostReasonAndFinalCanCompleteInvocation() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let modelReason = "requested overwrite is outside the assigned deliverable"
        let durableReason =
            "automatic reviewer denied the bound tool invocation"
        let mainProvider = AutoReviewScriptedProvider([
            [.toolCalls([ToolCall(
                id: "denied-write",
                name: "write_file",
                arguments: autoReviewWriteArgs(
                    path: "denied.txt",
                    content: "not allowed",
                    justification:
                        "The exact denied.txt write is the proposed action for review."))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("The denied write was not executed."), .done(finishReason: "stop")],
        ])
        let reviewerProvider = AutoReviewCapturingProvider([
            .textDelta(
                "requested overwrite is outside the assigned deliverable\nDENY"),
            .done(finishReason: "stop"),
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { agent -> any ToolCallingProvider in
                if agent.name == reviewerID { return reviewerProvider }
                return mainProvider
            }
        let attached = await orch.attach(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let enabled = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)

        let sent = await orch.send(
            "create denied.txt",
            to: main,
            userMessage: autoReviewUserMessage(
                "create denied.txt",
                id: "submission_denied_write"))
        XCTAssertTrue(attached)
        XCTAssertEqual(enabled, AutomaticPermissionReviewResult.enabled(reviewer))
        XCTAssertEqual(sent, .sent)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ws.appendingPathComponent("denied.txt").path))
        let events = await log.replay()
        let settled = try XCTUnwrap(events.compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event { return payload }
            return nil
        }.last)
        let resolved = try XCTUnwrap(events.compactMap { envelope -> PermissionResolvedPayload? in
            if case .permissionResolved(let payload) = envelope.event,
               payload.tool == "write_file",
               payload.requestId != nil { return payload }
            return nil
        }.last)
        let observation = try XCTUnwrap(events.compactMap { envelope -> ToolResultPayload? in
            if case .toolResult(let payload) = envelope.event,
               payload.toolCallId == "denied-write" { return payload }
            return nil
        }.last?.observation)
        XCTAssertEqual(settled.reason, durableReason)
        XCTAssertEqual(resolved.reason, durableReason)
        XCTAssertEqual(resolved.source, .automaticReviewer)
        XCTAssertEqual(resolved.reviewTaskID, settled.reviewTaskID)
        XCTAssertEqual(resolved.reviewStatus, .denied)
        XCTAssertEqual(observation, "permission denied: \(durableReason)")
        XCTAssertFalse(observation.contains("permission denied: permission denied:"))
        let durableBytes = try events.map {
            String(decoding: try Envelope.makeEncoder().encode($0), as: UTF8.self)
        }.joined(separator: "\n")
        XCTAssertFalse(durableBytes.contains(modelReason))
        XCTAssertTrue(mainProvider.requests.last?.messages.contains {
            $0.content == observation
        } == true)
        XCTAssertTrue(events.contains { envelope in
            if case .taskCompleted(let payload) = envelope.event {
                return payload.agent == main
            }
            return false
        })
        XCTAssertFalse(events.contains { envelope in
            if case .taskFailed(let payload) = envelope.event {
                return payload.agent == main
            }
            return false
        })
    }

    func testDeniedWriteCanBeFollowedByApprovedEquivalentEdit() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let file = ws.appendingPathComponent("document.txt")
        try "old\n".write(to: file, atomically: true, encoding: .utf8)
        let diff = [
            "--- a/document.txt",
            "+++ b/document.txt",
            "@@ -1 +1 @@",
            "-old",
            "+new",
        ].joined(separator: "\n")
        let patchArgs = autoReviewArguments(
            ["diff": diff],
            reference: "current minimal edit request",
            justification:
                "The minimal patch is the corrected bounded way to make the requested edit.")
        let mainProvider = AutoReviewScriptedProvider([
            [.toolCalls([ToolCall(
                id: "denied-write",
                name: "write_file",
                arguments: autoReviewWriteArgs(
                    path: "document.txt",
                    content: "new\n",
                    justification:
                        "The broad overwrite is the first proposed way to make the requested edit."))]),
             .done(finishReason: "tool_calls")],
            [.toolCalls([ToolCall(
                id: "approved-patch",
                name: "apply_patch",
                arguments: patchArgs)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("Updated document.txt through the approved patch."),
             .done(finishReason: "stop")],
        ])
        let reviewerProvider = AutoReviewScriptedProvider([
            [.textDelta("replace the broad overwrite with a minimal patch\nDENY"),
             .done(finishReason: "stop")],
            [.textDelta("minimal patch matches the requested edit\nALLOW"),
             .done(finishReason: "stop")],
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: AttachOnlyResponder()) { agent -> any ToolCallingProvider in
                agent.name == reviewerID ? reviewerProvider : mainProvider
            }
        let attached = await orch.attach(Agent(
            name: main,
            workspaceRoot: ws,
            model: ModelID(rawValue: "main-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        let enabled = await orch.enableAutomaticPermissionReview(
            model: ModelID(rawValue: "reviewer-model"),
            workspaceRoot: ws)
        XCTAssertEqual(enabled, .enabled(reviewer))

        let result = await orch.send(
            "change document.txt from old to new",
            to: main,
            userMessage: autoReviewUserMessage(
                "change document.txt from old to new",
                id: "submission_equivalent_edit"))

        XCTAssertEqual(result, .sent)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new\n")
        XCTAssertEqual(reviewerProvider.requests.count, 2)
        let settlements = await log.replay().compactMap { envelope -> ToolExecutionSettledPayload? in
            guard case .toolExecutionSettled(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertTrue(settlements.contains {
            $0.tool == "apply_patch" && $0.outcome == .succeeded
        })
        let reviewTasks = await log.replay().compactMap {
            envelope -> PermissionReviewTask? in
            guard case .permissionReviewRequested(let payload) = envelope.event,
                  payload.task.tool == "write_file"
                    || payload.task.tool == "apply_patch" else {
                return nil
            }
            return payload.task
        }
        XCTAssertEqual(reviewTasks.count, 2)
        XCTAssertTrue(reviewTasks.allSatisfy {
            $0.causalContext.authorizationContext == nil
        })
        XCTAssertEqual(mainProvider.requests.count, 3,
                       "two business generations plus final must not add reporter calls")
        XCTAssertFalse(mainProvider.requests.contains { request in
            request.tools.contains {
                $0.name == "submit_permission_authorization"
            }
        })
        let reviewPrompts = reviewerProvider.requests.map {
            $0.messages.compactMap(\.content).joined(separator: "\n")
        }
        let firstContext = try XCTUnwrap(autoReviewPromptBlock(
            "MODEL_AUTHORIZATION_CONTEXT",
            in: reviewPrompts[0]))
        let secondContext = try XCTUnwrap(autoReviewPromptBlock(
            "MODEL_AUTHORIZATION_CONTEXT",
            in: reviewPrompts[1]))
        XCTAssertTrue(firstContext.contains(
            "The broad overwrite is the first proposed way to make the requested edit."))
        XCTAssertTrue(secondContext.contains(
            "The minimal patch is the corrected bounded way to make the requested edit."))
    }

    func testHardDenyNeverReachesAutomaticReviewer() async throws {
        let log = try autoReviewTempLog()
        let ws = try autoReviewWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let mainProvider = AutoReviewScriptedProvider([
            [.toolCalls([ToolCall(id: "write", name: "write_file",
                                  arguments: autoReviewWriteArgs(path: ".env", content: "SECRET=value"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("blocked"), .done(finishReason: "stop")],
        ])
        let reviewerProvider = AutoReviewCapturingProvider([
            .textDelta("should not be called\nALLOW"),
            .done(finishReason: "stop"),
        ])
        let reviewerID = reviewer
        let orch = Orchestrator(log: log, allowsShell: true, responder: AttachOnlyResponder()) { agent in
            if agent.name == reviewerID {
                return reviewerProvider
            }
            return mainProvider
        }

        let mainAttached = await orch.attach(Agent(name: main,
                                                   workspaceRoot: ws,
                                                   model: ModelID(rawValue: "main-model"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(mainAttached)
        _ = await orch.enableAutomaticPermissionReview(model: ModelID(rawValue: "reviewer-model"), workspaceRoot: ws)

        let sendResult = await orch.send(
            "write .env",
            to: main,
            userMessage: autoReviewUserMessage(
                "write .env",
                id: "submission_hard_deny"))
        XCTAssertEqual(sendResult, .sent)

        XCTAssertTrue(reviewerProvider.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent(".env").path))
        let resolved = await log.replay().compactMap { envelope -> PermissionResolvedPayload? in
            if case .permissionResolved(let payload) = envelope.event, payload.tool == "write_file" {
                return payload
            }
            return nil
        }
        XCTAssertEqual(resolved.last?.decision, .deny)
    }
}
