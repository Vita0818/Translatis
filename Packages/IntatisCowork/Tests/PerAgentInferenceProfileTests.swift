import Foundation
import XCTest
import IntatisAgentKernel
import IntatisConversation
import IntatisCore
import IntatisPermission
import IntatisProtocol
import IntatisProviders
import IntatisTools
@testable import IntatisCowork

private final class PerAgentProfileProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequests: [AgentRequest] = []

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
            continuation.yield(.textDelta("profile-specific result"))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }
}

private struct PerAgentProfileResolution: Equatable, Sendable {
    var agentID: AgentID
    var modelID: ModelID
    var binding: AgentInferenceBinding?
}

private final class PerAgentProfileFactory: @unchecked Sendable {
    let provider = PerAgentProfileProvider()

    private let lock = NSLock()
    private var capturedResolutions: [PerAgentProfileResolution] = []

    var resolutions: [PerAgentProfileResolution] {
        lock.lock()
        defer { lock.unlock() }
        return capturedResolutions
    }

    func provider(for agent: Agent) -> ToolCallingProvider {
        lock.lock()
        capturedResolutions.append(PerAgentProfileResolution(
            agentID: agent.name,
            modelID: agent.model,
            binding: agent.agentInferenceBinding))
        lock.unlock()
        return provider
    }

    func resolvedInference(for agent: Agent) throws -> ResolvedInferenceProfile {
        guard let binding = agent.agentInferenceBinding else {
            throw InferenceCatalogError.unresolvedProfile
        }
        return ResolvedInferenceProfile(
            binding: binding,
            model: agent.model,
            provider: provider(for: agent))
    }
}

private final class PerAgentSpawnScriptedProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [[AgentChunk]]
    private var index = 0
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
        let chunks = responses.isEmpty
            ? [.done(finishReason: "stop")]
            : responses[min(index, responses.count - 1)]
        index += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private actor PerAgentSpawnReviewGate {
    private var request: PermissionRequestPayload?
    private var releasedDecision: PermissionDecision?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var decisionWaiters: [CheckedContinuation<PermissionDecision, Never>] = []

    func decide(_ request: PermissionRequestPayload) async -> PermissionDecision {
        guard request.tool == "spawn_agent" else { return .allow }
        self.request = request
        let enteredWaiters = enteredWaiters
        self.enteredWaiters.removeAll()
        for waiter in enteredWaiters { waiter.resume() }
        if let releasedDecision { return releasedDecision }
        return await withCheckedContinuation { continuation in
            decisionWaiters.append(continuation)
        }
    }

    func waitUntilSpawnReview() async {
        if request != nil { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release(_ decision: PermissionDecision) {
        releasedDecision = decision
        let decisionWaiters = decisionWaiters
        self.decisionWaiters.removeAll()
        for waiter in decisionWaiters { waiter.resume(returning: decision) }
    }

    func capturedRequest() -> PermissionRequestPayload? { request }
}

private actor PerAgentInferenceResolutionGate {
    private let blockedProfileID: InferenceProfileID
    private let provider: ToolCallingProvider
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(blockedProfileID: InferenceProfileID, provider: ToolCallingProvider) {
        self.blockedProfileID = blockedProfileID
        self.provider = provider
    }

    func resolve(_ agent: Agent) async throws -> ResolvedInferenceProfile {
        guard let binding = agent.agentInferenceBinding else {
            throw InferenceCatalogError.unresolvedProfile
        }
        if binding.inferenceProfileID == blockedProfileID {
            entered = true
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if !released {
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }
        }
        return ResolvedInferenceProfile(
            binding: binding,
            model: binding.modelID,
            provider: provider)
    }

    func waitUntilBlockedResolutionStarts() async {
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

private actor PerAgentDelegationMediatorGate: ForwardingReviewer {
    private let suspendedContent: String
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(suspendedContent: String) {
        self.suspendedContent = suspendedContent
    }

    func review(from: AgentID, to: AgentID, content: String) async -> ForwardingDecision {
        guard content == suspendedContent else { return .forward(content) }
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
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
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor PerAgentMutableInferenceResolver {
    private let provider: ToolCallingProvider
    private var isAvailable = true
    private var resolutionCount = 0

    init(provider: ToolCallingProvider) {
        self.provider = provider
    }

    func resolve(_ agent: Agent) throws -> ResolvedInferenceProfile {
        resolutionCount += 1
        guard isAvailable,
              let binding = agent.agentInferenceBinding else {
            throw InferenceCatalogError.unresolvedProfile
        }
        return ResolvedInferenceProfile(
            binding: binding,
            model: binding.modelID,
            provider: provider)
    }

    func revoke() {
        isAvailable = false
    }

    func resolutions() -> Int { resolutionCount }
}

private actor PerAgentAttachReviewGate {
    private var request: PermissionRequestPayload?
    private var releasedDecision: PermissionDecision?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var decisionWaiters: [CheckedContinuation<PermissionDecision, Never>] = []

    func decide(_ request: PermissionRequestPayload) async -> PermissionDecision {
        guard request.tool == "agent.attach" else { return .allow }
        self.request = request
        let enteredWaiters = enteredWaiters
        self.enteredWaiters.removeAll()
        for waiter in enteredWaiters { waiter.resume() }
        if let releasedDecision { return releasedDecision }
        return await withCheckedContinuation { continuation in
            decisionWaiters.append(continuation)
        }
    }

    func waitUntilAttachReview() async {
        if request != nil { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release(_ decision: PermissionDecision) {
        releasedDecision = decision
        let decisionWaiters = decisionWaiters
        self.decisionWaiters.removeAll()
        for waiter in decisionWaiters { waiter.resume(returning: decision) }
    }
}

private struct PerAgentBlockingAttachResponder: PermissionResponder {
    let gate: PerAgentAttachReviewGate

    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        await gate.decide(request)
    }
}

private struct PerAgentAdmissionBatchFailure: Error {}

private actor PerAgentFailingAdmissionBatchGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func append(_ events: [Event]) async throws {
        guard !entered else { throw PerAgentAdmissionBatchFailure() }
        entered = true
        let enteredWaiters = enteredWaiters
        self.enteredWaiters.removeAll()
        for waiter in enteredWaiters { waiter.resume() }
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        throw PerAgentAdmissionBatchFailure()
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let releaseWaiters = releaseWaiters
        self.releaseWaiters.removeAll()
        for waiter in releaseWaiters { waiter.resume() }
    }
}

private struct PerAgentBlockingSpawnResponder: PermissionResponder {
    let gate: PerAgentSpawnReviewGate

    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        await gate.decide(request)
    }
}

private struct PerAgentProfileEnvironment {
    let root: URL
    let log: EventLog
    let mainWorkspace: URL
    let workerWorkspace: URL

    init(_ label: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-per-agent-profile-\(label)-\(UUID().uuidString)", isDirectory: true)
        mainWorkspace = root.appendingPathComponent("main", isDirectory: true)
        workerWorkspace = root.appendingPathComponent("worker", isDirectory: true)
        try FileManager.default.createDirectory(at: mainWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workerWorkspace, withIntermediateDirectories: true)
        log = try EventLog(
            session: SessionID(rawValue: "per-agent-profile-\(label)"),
            fileURL: root.appendingPathComponent("events.jsonl"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func perAgentBinding(
    profile: String,
    revision: String = "profile-rev-1",
    connection: String? = nil,
    connectionRevision: String = "connection-rev-1",
    model: String,
    variant: String? = nil
) -> AgentInferenceBinding {
    let resolvedConnection = connection ?? "connection-\(profile)"
    return AgentInferenceBinding(
        inferenceProfileRef: InferenceProfileRef(
            inferenceProfileID: InferenceProfileID(rawValue: profile),
            inferenceProfileRevision: InferenceProfileRevision(rawValue: revision)),
        inferenceConnectionID: InferenceConnectionID(rawValue: resolvedConnection),
        inferenceConnectionRevision: InferenceConnectionRevision(rawValue: connectionRevision),
        modelID: ModelID(rawValue: model),
        variantID: variant,
        safeRouteLabel: "route-\(profile)",
        trustDomain: "trust-\(resolvedConnection)",
        egressClassification: "external",
        immutableDefinitionFingerprint: "fingerprint-\(profile)-\(revision)-\(model)-\(variant ?? "base")")
}

final class PerAgentInferenceProfileTests: XCTestCase {
    private let main = AgentID(rawValue: "main")
    private let worker = AgentID(rawValue: "worker")

    func testProfileListUsesDeclaredCapabilitiesAndDoesNotGuessMissingMetadata()
        async throws
    {
        let environment = try PerAgentProfileEnvironment("routing-capabilities")
        defer { environment.remove() }
        let vision = perAgentBinding(
            profile: "vision-profile",
            model: "configured-vision-model")
        let unspecified = perAgentBinding(
            profile: "custom-profile",
            model: "unrecognized-custom-model")
        let provider = PerAgentProfileProvider()
        let orchestrator = Orchestrator(
            log: environment.log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            availableInferenceProfiles: [vision, unspecified],
            inferenceProfileRoutingMetadata: [
                InferenceProfileRoutingMetadata(
                    inferenceProfileID: vision.inferenceProfileID,
                    declaredCapabilities: [.visionInput, .chat]),
            ],
            providerFor: { _ in provider })

        let listing = await orchestrator.listInferenceProfilesForTool()
        let lines = listing.split(separator: "\n").map(String.init)
        let visionLine = try XCTUnwrap(lines.first {
            $0.hasPrefix("vision-profile ·")
        })
        let customLine = try XCTUnwrap(lines.first {
            $0.hasPrefix("custom-profile ·")
        })

        XCTAssertTrue(visionLine.contains(
            "capabilities chat,vision_input"))
        XCTAssertTrue(customLine.contains(
            "capabilities unspecified"))
        XCTAssertFalse(customLine.contains("vision_input"))
    }

    private func spawnArguments(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]), as: UTF8.self)
    }

    private func waitForAdmissionWaiter(
        on orchestrator: Orchestrator,
        attempts: Int = 10_000
    ) async -> Bool {
        for _ in 0..<attempts {
            if await orchestrator.admissionWaiterCountForTesting() > 0 {
                return true
            }
            await Task.yield()
        }
        return false
    }

    func testProviderOnlyShippingRuntimeCannotEnableExactBindingsMode() throws {
        let environment = try PerAgentProfileEnvironment("provider-only-runtime")
        defer { environment.remove() }
        let provider = PerAgentProfileProvider()

        XCTAssertThrowsError(try Orchestrator.runtime(
            log: environment.log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            requiresInferenceBindings: true,
            providerFor: { _ in provider }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("resolvedInferenceFor"))
        }
    }

    func testStrictRuntimeRejectsUnboundAttachAndMainBootstrap() async throws {
        let environment = try PerAgentProfileEnvironment("strict-admission")
        defer { environment.remove() }
        let factory = PerAgentProfileFactory()
        let orchestrator = try Orchestrator.runtime(
            log: environment.log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            requiresInferenceBindings: true,
            resolvedInferenceFor: { agent in
                try factory.resolvedInference(for: agent)
            })

        let attached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: environment.workerWorkspace,
            model: ModelID(rawValue: "legacy-model"),
            profile: .reviewed))
        let bootstrapped = await orchestrator.bootstrapMainAgent(Agent(
            name: main,
            workspaceRoot: environment.mainWorkspace,
            model: ModelID(rawValue: "legacy-model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))

        XCTAssertFalse(attached)
        XCTAssertEqual(
            bootstrapped,
            .failed("@main requires an exact inference profile binding."))
        let agents = await orchestrator.agentList()
        XCTAssertTrue(agents.isEmpty)
        XCTAssertTrue(factory.resolutions.isEmpty)
        XCTAssertTrue(factory.provider.requests.isEmpty)
    }

    func testStrictAttachRejectsUnresolvableExactBindingBeforeDurableAdmission() async throws {
        let environment = try PerAgentProfileEnvironment("unresolvable-admission")
        defer { environment.remove() }
        let binding = perAgentBinding(
            profile: "missing-profile",
            revision: "missing-revision",
            model: "missing-model")
        let orchestrator = try Orchestrator.runtime(
            log: environment.log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            requiresInferenceBindings: true,
            resolvedInferenceFor: { _ in
                throw IntatisError.config(
                    "private endpoint https://secret.example.test and credential should never be logged")
            })

        let attached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: environment.workerWorkspace,
            model: binding.modelID,
            agentInferenceBinding: binding,
            profile: .reviewed))

        XCTAssertFalse(attached)
        let events = await environment.log.replay()
        XCTAssertFalse(events.contains { $0.event.type == .permissionRequest })
        XCTAssertFalse(events.contains { $0.event.type == .agentAttached })
        let errors = events.compactMap { envelope -> ErrorPayload? in
            guard case .error(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(errors.last?.code, "inference_profile_unresolved")
        XCTAssertFalse(errors.last?.message.contains("secret.example.test") == true)
        XCTAssertFalse(errors.last?.message.contains("credential") == true)
    }

    func testAttachRevalidatesExactInferenceAfterPermissionReviewAllow() async throws {
        let environment = try PerAgentProfileEnvironment("attach-resolution-review-race")
        defer { environment.remove() }
        let binding = perAgentBinding(
            profile: "attach-reviewed-profile",
            revision: "profile-rev-4",
            connection: "attach-reviewed-route",
            model: "attach-reviewed-model",
            variant: "high")
        let provider = PerAgentProfileProvider()
        let resolver = PerAgentMutableInferenceResolver(provider: provider)
        let reviewGate = PerAgentAttachReviewGate()
        let orchestrator = try Orchestrator.runtime(
            log: environment.log,
            allowsShell: false,
            responder: PerAgentBlockingAttachResponder(gate: reviewGate),
            availableInferenceProfiles: [binding],
            requiresInferenceBindings: true,
            resolvedInferenceFor: { agent in
                try await resolver.resolve(agent)
            })

        let attachTask = Task {
            await orchestrator.attach(Agent(
                name: self.worker,
                workspaceRoot: environment.workerWorkspace,
                model: binding.modelID,
                agentInferenceBinding: binding,
                profile: .reviewed))
        }
        await reviewGate.waitUntilAttachReview()
        await resolver.revoke()
        await reviewGate.release(.allow)

        let attached = await attachTask.value
        let resolutionCount = await resolver.resolutions()
        let agents = await orchestrator.agentList()
        XCTAssertFalse(attached)
        XCTAssertEqual(resolutionCount, 2)
        XCTAssertTrue(agents.isEmpty)
        XCTAssertTrue(provider.requests.isEmpty)

        let events = await environment.log.replay()
        XCTAssertFalse(events.contains { envelope in
            if case .agentAttached = envelope.event { return true }
            return false
        })
        let resolutions = events.compactMap { envelope -> PermissionResolvedPayload? in
            guard case .permissionResolved(let payload) = envelope.event,
                  payload.tool == "agent.attach" else { return nil }
            return payload
        }
        XCTAssertEqual(resolutions.count, 1)
        XCTAssertEqual(resolutions.first?.decision, .deny)
        XCTAssertEqual(resolutions.first?.source, .authorizationRevalidation)
        XCTAssertEqual(resolutions.first?.failureKind, .authorizationSnapshotInvalid)
        XCTAssertTrue(events.contains { envelope in
            if case .workspaceLeaseDenied = envelope.event { return true }
            return false
        })
    }

    func testAttachRejectsHostCatalogMutationDuringPermissionReview() async throws {
        let environment = try PerAgentProfileEnvironment("attach-catalog-review-race")
        defer { environment.remove() }
        let binding = perAgentBinding(
            profile: "attach-catalog-profile",
            revision: "profile-rev-8",
            connection: "attach-catalog-route",
            model: "attach-catalog-model")
        let provider = PerAgentProfileProvider()
        let resolver = PerAgentMutableInferenceResolver(provider: provider)
        let reviewGate = PerAgentAttachReviewGate()
        let orchestrator = try Orchestrator.runtime(
            log: environment.log,
            allowsShell: false,
            responder: PerAgentBlockingAttachResponder(gate: reviewGate),
            availableInferenceProfiles: [binding],
            requiresInferenceBindings: true,
            resolvedInferenceFor: { agent in
                try await resolver.resolve(agent)
            })

        let attachTask = Task {
            await orchestrator.attach(Agent(
                name: self.worker,
                workspaceRoot: environment.workerWorkspace,
                model: binding.modelID,
                agentInferenceBinding: binding,
                profile: .reviewed))
        }
        await reviewGate.waitUntilAttachReview()
        await orchestrator.updateAvailableInferenceProfiles([], hostAuthorized: true)
        await reviewGate.release(.allow)

        let attached = await attachTask.value
        let resolutionCount = await resolver.resolutions()
        let agents = await orchestrator.agentList()
        XCTAssertFalse(attached)
        XCTAssertEqual(resolutionCount, 2)
        XCTAssertTrue(agents.isEmpty)
        let events = await environment.log.replay()
        XCTAssertFalse(events.contains { envelope in
            if case .agentAttached = envelope.event { return true }
            return false
        })
        let denial = events.compactMap { envelope -> PermissionResolvedPayload? in
            guard case .permissionResolved(let payload) = envelope.event,
                  payload.tool == "agent.attach" else { return nil }
            return payload
        }.last
        XCTAssertEqual(denial?.decision, .deny)
        XCTAssertEqual(denial?.source, .authorizationRevalidation)
        XCTAssertTrue(denial?.reason.contains("host-approved inference profile changed") == true)
    }

    func testBootstrapRevalidatesExactInferenceAfterAdmissionWait() async throws {
        let environment = try PerAgentProfileEnvironment("bootstrap-admission-race")
        defer { environment.remove() }
        let binding = perAgentBinding(
            profile: "bootstrap-reviewed-profile",
            revision: "profile-rev-6",
            connection: "bootstrap-reviewed-route",
            model: "bootstrap-reviewed-model")
        let provider = PerAgentProfileProvider()
        let resolver = PerAgentMutableInferenceResolver(provider: provider)
        let admissionGate = PerAgentFailingAdmissionBatchGate()
        let orchestrator = try Orchestrator.runtime(
            log: environment.log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            availableInferenceProfiles: [binding],
            requiresInferenceBindings: true,
            resolvedInferenceFor: { agent in
                try await resolver.resolve(agent)
            })
        await orchestrator.setAdmissionEventsAppender { events in
            try await admissionGate.append(events)
        }

        let mainAgent = Agent(
            name: main,
            workspaceRoot: environment.mainWorkspace,
            model: binding.modelID,
            agentInferenceBinding: binding,
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth)
        let firstBootstrap = Task {
            await orchestrator.bootstrapMainAgent(mainAgent)
        }
        await admissionGate.waitUntilEntered()

        let waitingBootstrap = Task {
            await orchestrator.bootstrapMainAgent(mainAgent)
        }
        let secondBootstrapWaited = await waitForAdmissionWaiter(on: orchestrator)
        XCTAssertTrue(
            secondBootstrapWaited,
            "the second bootstrap must wait behind the first durable admission")
        await resolver.revoke()
        await admissionGate.release()

        guard case .failed(let firstFailure) = await firstBootstrap.value else {
            return XCTFail("the injected first bootstrap persistence failure must fail closed")
        }
        XCTAssertTrue(firstFailure.contains("could not be persisted"))
        let secondResult = await waitingBootstrap.value
        let agents = await orchestrator.agentList()
        let events = await environment.log.replay()
        XCTAssertEqual(
            secondResult,
            .failed("@main exact inference profile changed or became unavailable before durable admission."))
        XCTAssertTrue(agents.isEmpty)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testStrictRuntimeRejectsNonAtomicBindingAndModelTupleBeforeAdmission() async throws {
        let environment = try PerAgentProfileEnvironment("atomic-resolution-mismatch")
        defer { environment.remove() }
        let expected = perAgentBinding(
            profile: "expected-profile",
            model: "expected-model")
        let mismatched = perAgentBinding(
            profile: "other-profile",
            model: "other-model")
        let provider = PerAgentProfileProvider()
        let orchestrator = try Orchestrator.runtime(
            log: environment.log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            requiresInferenceBindings: true,
            resolvedInferenceFor: { _ in
                ResolvedInferenceProfile(
                    binding: mismatched,
                    model: mismatched.modelID,
                    provider: provider)
            })

        let attached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: environment.workerWorkspace,
            model: expected.modelID,
            agentInferenceBinding: expected,
            profile: .reviewed))

        XCTAssertFalse(attached)
        XCTAssertTrue(provider.requests.isEmpty)
        let events = await environment.log.replay()
        XCTAssertFalse(events.contains { $0.event.type == .permissionRequest })
        XCTAssertFalse(events.contains { $0.event.type == .agentAttached })
    }

    func testRecoveredTaskBindingMismatchFailsBeforeProviderResolution() async throws {
        let environment = try PerAgentProfileEnvironment("recovered-mismatch")
        defer { environment.remove() }
        let original = perAgentBinding(
            profile: "worker-profile",
            revision: "profile-rev-1",
            model: "worker-model-v1",
            variant: "high")
        let rebound = perAgentBinding(
            profile: "worker-profile",
            revision: "profile-rev-2",
            model: "worker-model-v2",
            variant: "max")
        let setupProvider = PerAgentProfileProvider()
        let setup = Orchestrator(
            log: environment.log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            requiresInferenceBindings: true
        ) { _ in
            setupProvider
        }
        let mainAttached = await setup.attach(Agent(
            name: main,
            workspaceRoot: environment.mainWorkspace,
            model: original.modelID,
            agentInferenceBinding: original,
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await setup.attach(Agent(
            name: worker,
            workspaceRoot: environment.workerWorkspace,
            model: original.modelID,
            agentInferenceBinding: original,
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)
        let queued = await setup.enqueueDelegatedTask(
            from: main,
            to: worker.rawValue,
            objective: "Run under the original exact profile revision.")
        let taskID = try XCTUnwrap(queued.taskID)

        // Simulate a durable roster update that raced ahead of a previously
        // frozen task. Recovery must preserve both facts and fail closed.
        try await environment.log.append(.agentAttached(AgentAttachedPayload(
            agent: worker,
            path: environment.workerWorkspace.path,
            model: rebound.modelID,
            profile: PermissionProfile.reviewed.rawValue,
            agentInferenceBinding: rebound,
            previousAgentInferenceBinding: original,
            inferenceBindingChangeReason: "test recovery mismatch",
            metadata: CoworkEventMetadata(agentID: worker, scope: .agent))))

        let factory = PerAgentProfileFactory()
        let recovered = Orchestrator(
            log: environment.log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            requiresInferenceBindings: true
        ) { agent in
            factory.provider(for: agent)
        }
        await recovered.restore(from: CoworkProjection.build(from: await environment.log.replay()))
        let resumed = await recovered.resumePendingTasks()
        XCTAssertTrue(resumed)
        await recovered.runSchedulerUntilIdle()

        let recoveredRecord = await recovered.executionRecord(taskID: taskID)
        let record = try XCTUnwrap(recoveredRecord)
        XCTAssertEqual(record.status, .failed)
        XCTAssertTrue(record.error?.contains("inference profile revisions differ") == true)
        XCTAssertTrue(factory.resolutions.isEmpty)
        XCTAssertTrue(factory.provider.requests.isEmpty)
        XCTAssertTrue(setupProvider.requests.isEmpty)
    }

    func testTwoAgentsResolveTheirOwnExactBindingAndModel() async throws {
        let environment = try PerAgentProfileEnvironment("two-agent-routing")
        defer { environment.remove() }
        let mainBinding = perAgentBinding(
            profile: "coordinator-deep",
            model: "reasoning-model",
            variant: "max")
        let workerBinding = perAgentBinding(
            profile: "worker-fast",
            connection: "regional-connection",
            connectionRevision: "regional-rev-7",
            model: "fast-model",
            variant: "low")
        let factory = PerAgentProfileFactory()
        let orchestrator = try Orchestrator.runtime(
            log: environment.log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            requiresInferenceBindings: true,
            resolvedInferenceFor: { agent in
                try factory.resolvedInference(for: agent)
            })
        let mainAttached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: environment.mainWorkspace,
            model: ModelID(rawValue: "ignored-main-model"),
            agentInferenceBinding: mainBinding,
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: environment.workerWorkspace,
            model: ModelID(rawValue: "ignored-worker-model"),
            agentInferenceBinding: workerBinding,
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)

        let mainResult = await orchestrator.send("Run the coordinator.", to: main)
        let workerResult = await orchestrator.send("Run the worker.", to: worker)
        XCTAssertEqual(mainResult, .sent)
        XCTAssertEqual(workerResult, .sent)

        XCTAssertEqual(factory.resolutions, [
            // Strict admission resolves before review and again after allow,
            // without issuing a model request. Each invocation then resolves
            // its frozen tuple again atomically.
            PerAgentProfileResolution(agentID: main, modelID: mainBinding.modelID, binding: mainBinding),
            PerAgentProfileResolution(agentID: main, modelID: mainBinding.modelID, binding: mainBinding),
            PerAgentProfileResolution(agentID: worker, modelID: workerBinding.modelID, binding: workerBinding),
            PerAgentProfileResolution(agentID: worker, modelID: workerBinding.modelID, binding: workerBinding),
            PerAgentProfileResolution(agentID: main, modelID: mainBinding.modelID, binding: mainBinding),
            PerAgentProfileResolution(agentID: worker, modelID: workerBinding.modelID, binding: workerBinding),
        ])
        XCTAssertEqual(factory.provider.requests.count, 2)

        let frozenBindings = await environment.log.replay().compactMap { envelope -> AgentInferenceBinding? in
            guard case .taskCreated(let payload) = envelope.event,
                  payload.contract.kind == .root else { return nil }
            return payload.contract.agentInferenceBinding
        }
        XCTAssertEqual(frozenBindings, [mainBinding, workerBinding])
    }

    func testSpawnWithoutProfileInheritsParentsCompleteExactBinding() async throws {
        let environment = try PerAgentProfileEnvironment("spawn-inherit-exact")
        defer { environment.remove() }
        let parentBinding = perAgentBinding(
            profile: "parent-reasoning-profile",
            revision: "parent-profile-rev-9",
            connection: "parent-regional-connection",
            connectionRevision: "parent-connection-rev-4",
            model: "parent-reasoning-model",
            variant: "max")
        let childID = AgentID(rawValue: "inherited-child")
        let spawnArgs = try spawnArguments([
            "name": childID.rawValue,
            "path": environment.workerWorkspace.path,
        ])
        let provider = PerAgentSpawnScriptedProvider([
            [.toolCalls([ToolCall(
                id: "spawn-inherit",
                name: "spawn_agent",
                arguments: spawnArgs)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("spawned with the inherited route"), .done(finishReason: "stop")],
        ])
        let orchestrator = Orchestrator(
            log: environment.log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            requiresInferenceBindings: true
        ) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: environment.mainWorkspace,
            model: parentBinding.modelID,
            agentInferenceBinding: parentBinding,
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)

        let result = await orchestrator.send("Spawn a child with my exact route.", to: main)
        XCTAssertEqual(result, .sent)

        let agents = await orchestrator.agentList()
        let parent = try XCTUnwrap(agents.first { $0.name == main })
        let child = try XCTUnwrap(agents.first { $0.name == childID })
        XCTAssertEqual(parent.agentInferenceBinding, parentBinding)
        XCTAssertEqual(parent.model, parentBinding.modelID)
        XCTAssertEqual(child.agentInferenceBinding, parentBinding)
        XCTAssertEqual(child.model, parentBinding.modelID)

        let events = await environment.log.replay()
        let reviewed = try XCTUnwrap(events.compactMap { envelope -> ResolvedToolAuthorization? in
            guard case .permissionRequest(let payload) = envelope.event,
                  payload.tool == "spawn_agent" else { return nil }
            return payload.context?.authorization
        }.last)
        XCTAssertEqual(reviewed.targetAgentInferenceBinding, parentBinding)
        XCTAssertEqual(
            reviewed.intent.metadata["profileSelection"],
            .string("inherit_parent_exact"))
        XCTAssertEqual(
            reviewed.intent.metadata["targetInferenceTrustDomain"],
            .string(parentBinding.trustDomain!))
        XCTAssertEqual(
            reviewed.intent.metadata["targetInferenceEgressClassification"],
            .string(parentBinding.egressClassification!))
        XCTAssertEqual(
            reviewed.intent.metadata["targetInferenceRouteLabel"],
            .string(parentBinding.safeRouteLabel!))
        let prepared = try XCTUnwrap(events.compactMap { envelope -> ToolExecutionPreparedPayload? in
            guard case .toolExecutionPrepared(let payload) = envelope.event,
                  payload.tool == "spawn_agent" else { return nil }
            return payload
        }.last)
        XCTAssertEqual(prepared.authorization?.targetAgentInferenceBinding, parentBinding)
        let spawned = try XCTUnwrap(events.compactMap { envelope -> AgentSpawnedPayload? in
            guard case .agentSpawned(let payload) = envelope.event,
                  payload.agent == childID else { return nil }
            return payload
        }.last)
        XCTAssertEqual(spawned.agentInferenceBinding, parentBinding)
        XCTAssertEqual(spawned.model, parentBinding.modelID)
    }

    func testSpawnRejectsRawRouteAndCredentialInjectionWithoutPersistingArgumentsOrDigest() async throws {
        let environment = try PerAgentProfileEnvironment("spawn-raw-route-injection")
        defer { environment.remove() }
        let parentBinding = perAgentBinding(
            profile: "safe-parent-profile",
            model: "safe-parent-model")
        let secret = "sk-inference-control-secret-123456789"
        let privateURL = "https://private-gateway.example.test/v1?token=hidden"
        let rawArguments = try spawnArguments([
            "name": "malicious-child",
            "path": environment.workerWorkspace.path,
            "inference_profile_id": parentBinding.inferenceProfileID.rawValue,
            "base_url": privateURL,
            "api_key": secret,
            "headers": ["Authorization": "Bearer \(secret)"],
        ])
        let provider = PerAgentSpawnScriptedProvider([
            [.toolCalls([ToolCall(
                id: "spawn-injection",
                name: "spawn_agent",
                arguments: rawArguments)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("raw route injection rejected"), .done(finishReason: "stop")],
        ])
        let orchestrator = Orchestrator(
            log: environment.log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            availableInferenceProfiles: [parentBinding],
            requiresInferenceBindings: true
        ) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: environment.mainWorkspace,
            model: parentBinding.modelID,
            agentInferenceBinding: parentBinding,
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)

        let result = await orchestrator.send("Reject raw route configuration.", to: main)
        XCTAssertEqual(result, .sent)
        let events = await environment.log.replay()
        let durableCall = try XCTUnwrap(events.compactMap { envelope -> ToolCallPayload? in
            guard case .toolCall(let payload) = envelope.event,
                  payload.toolCallId == "spawn-injection" else { return nil }
            return payload
        }.first)
        XCTAssertEqual(durableCall.args, #"{"_intatis":"arguments_redacted"}"#)
        XCTAssertEqual(durableCall.argsRedacted, true)
        XCTAssertNil(durableCall.argsDigest)
        XCTAssertEqual(durableCall.argsCharacterCount, rawArguments.count)
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionRequest(let payload) = envelope.event else { return false }
            return payload.tool == "spawn_agent"
        })
        let agents = await orchestrator.agentList()
        XCTAssertFalse(agents.contains {
            $0.name == AgentID(rawValue: "malicious-child")
        })
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains(privateURL))
        XCTAssertFalse(encoded.contains(rawArguments))
        XCTAssertFalse(encoded.contains(ToolRegistry.authorizationDigest(rawArguments)))
    }

    func testSpawnWithExplicitApprovedProfileFreezesChildAndLeavesParentUnchanged() async throws {
        let environment = try PerAgentProfileEnvironment("spawn-explicit-approved")
        defer { environment.remove() }
        let parentBinding = perAgentBinding(
            profile: "parent-balanced",
            revision: "parent-rev-3",
            model: "parent-model",
            variant: "medium")
        let approvedChildBinding = perAgentBinding(
            profile: "approved-fast-child",
            revision: "child-rev-11",
            connection: "approved-child-connection",
            connectionRevision: "approved-connection-rev-8",
            model: "child-fast-model",
            variant: "low")
        let childID = AgentID(rawValue: "approved-child")
        let spawnArgs = try spawnArguments([
            "name": childID.rawValue,
            "path": environment.workerWorkspace.path,
            "inference_profile_id": approvedChildBinding.inferenceProfileID.rawValue,
        ])
        let provider = PerAgentSpawnScriptedProvider([
            [.toolCalls([ToolCall(
                id: "spawn-explicit",
                name: "spawn_agent",
                arguments: spawnArgs)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("spawned with the approved route"), .done(finishReason: "stop")],
        ])
        let orchestrator = Orchestrator(
            log: environment.log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            availableInferenceProfiles: [approvedChildBinding],
            requiresInferenceBindings: true
        ) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: environment.mainWorkspace,
            model: parentBinding.modelID,
            agentInferenceBinding: parentBinding,
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)

        let result = await orchestrator.send("Spawn the approved fast child.", to: main)
        XCTAssertEqual(result, .sent)

        let agents = await orchestrator.agentList()
        let parent = try XCTUnwrap(agents.first { $0.name == main })
        let child = try XCTUnwrap(agents.first { $0.name == childID })
        XCTAssertEqual(parent.agentInferenceBinding, parentBinding)
        XCTAssertEqual(parent.model, parentBinding.modelID)
        XCTAssertEqual(child.agentInferenceBinding, approvedChildBinding)
        XCTAssertEqual(child.model, approvedChildBinding.modelID)

        let events = await environment.log.replay()
        let reviewed = try XCTUnwrap(events.compactMap { envelope -> ResolvedToolAuthorization? in
            guard case .permissionRequest(let payload) = envelope.event,
                  payload.tool == "spawn_agent" else { return nil }
            return payload.context?.authorization
        }.last)
        XCTAssertEqual(reviewed.targetAgentInferenceBinding, approvedChildBinding)
        XCTAssertEqual(
            reviewed.intent.metadata["profileSelection"],
            .string("explicit_host_catalog"))
        let childAttachment = try XCTUnwrap(events.compactMap { envelope -> AgentAttachedPayload? in
            guard case .agentAttached(let payload) = envelope.event,
                  payload.agent == childID else { return nil }
            return payload
        }.last)
        XCTAssertEqual(childAttachment.agentInferenceBinding, approvedChildBinding)
        XCTAssertEqual(childAttachment.model, approvedChildBinding.modelID)
        XCTAssertNil(childAttachment.previousAgentInferenceBinding)
    }

    func testSpawnRejectsRemovedRawModelFieldAndUnapprovedProfileBeforeAdmission() async throws {
        let environment = try PerAgentProfileEnvironment("spawn-unapproved-routes")
        defer { environment.remove() }
        let parentBinding = perAgentBinding(
            profile: "parent-only",
            model: "parent-model",
            variant: "high")
        let rawChildID = AgentID(rawValue: "raw-model-child")
        let unknownChildID = AgentID(rawValue: "unknown-profile-child")
        let rawModelArgs = try spawnArguments([
            "name": rawChildID.rawValue,
            "path": environment.workerWorkspace.path,
            "model": "different-unapproved-model",
        ])
        let unknownProfileArgs = try spawnArguments([
            "name": unknownChildID.rawValue,
            "path": environment.workerWorkspace.path,
            "inference_profile_id": "profile-not-in-host-catalog",
        ])
        let provider = PerAgentSpawnScriptedProvider([
            [.toolCalls([ToolCall(
                id: "spawn-raw-model",
                name: "spawn_agent",
                arguments: rawModelArgs)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("raw route rejected"), .done(finishReason: "stop")],
            [.toolCalls([ToolCall(
                id: "spawn-unknown-profile",
                name: "spawn_agent",
                arguments: unknownProfileArgs)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("unknown route rejected"), .done(finishReason: "stop")],
        ])
        let orchestrator = Orchestrator(
            log: environment.log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            availableInferenceProfiles: [],
            requiresInferenceBindings: true
        ) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: environment.mainWorkspace,
            model: parentBinding.modelID,
            agentInferenceBinding: parentBinding,
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)

        let rawResult = await orchestrator.send("Try an unapproved raw model.", to: main)
        let unknownResult = await orchestrator.send("Try an unknown profile.", to: main)
        XCTAssertEqual(rawResult, .sent)
        XCTAssertEqual(unknownResult, .sent)

        let agents = await orchestrator.agentList()
        XCTAssertEqual(agents.map(\.name), [main])
        XCTAssertEqual(agents.first?.agentInferenceBinding, parentBinding)
        let events = await environment.log.replay()
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionRequest(let payload) = envelope.event else { return false }
            return payload.tool == "spawn_agent"
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .toolExecutionPrepared(let payload) = envelope.event else { return false }
            return payload.tool == "spawn_agent"
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .agentSpawnRequested(let payload) = envelope.event else { return false }
            return payload.agent == rawChildID || payload.agent == unknownChildID
        })
        XCTAssertTrue(events.contains { envelope in
            guard case .toolResult(let payload) = envelope.event,
                  payload.toolCallId == "spawn-raw-model" else { return false }
            return payload.observation.contains("unknown field(s): model")
        })
        let denials = events.compactMap { envelope -> PermissionResolvedPayload? in
            guard case .permissionResolved(let payload) = envelope.event,
                  payload.tool == "spawn_agent" else { return nil }
            return payload
        }
        XCTAssertEqual(denials.count, 1)
        XCTAssertTrue(denials.allSatisfy { $0.decision == .deny })
        XCTAssertTrue(denials.allSatisfy { $0.source == .authorizationRevalidation })
        XCTAssertTrue(denials.allSatisfy { $0.failureKind == .authorizationSnapshotInvalid })
    }

    func testExplicitSpawnRevalidationRejectsCatalogMutationDuringPermissionReview() async throws {
        let environment = try PerAgentProfileEnvironment("spawn-catalog-race")
        defer { environment.remove() }
        let parentBinding = perAgentBinding(
            profile: "parent-stable",
            model: "parent-model",
            variant: "high")
        let approvedChildBinding = perAgentBinding(
            profile: "approved-at-review-start",
            revision: "approved-rev-5",
            connection: "approved-connection",
            connectionRevision: "approved-connection-rev-2",
            model: "approved-child-model",
            variant: "low")
        let childID = AgentID(rawValue: "catalog-race-child")
        let spawnArgs = try spawnArguments([
            "name": childID.rawValue,
            "path": environment.workerWorkspace.path,
            "inference_profile_id": approvedChildBinding.inferenceProfileID.rawValue,
        ])
        let provider = PerAgentSpawnScriptedProvider([
            [.toolCalls([ToolCall(
                id: "spawn-catalog-race",
                name: "spawn_agent",
                arguments: spawnArgs)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("catalog mutation observed"), .done(finishReason: "stop")],
        ])
        let gate = PerAgentSpawnReviewGate()
        let orchestrator = Orchestrator(
            log: environment.log,
            allowsShell: false,
            responder: PerAgentBlockingSpawnResponder(gate: gate),
            availableInferenceProfiles: [approvedChildBinding],
            requiresInferenceBindings: true
        ) { _ in provider }
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: environment.mainWorkspace,
            model: parentBinding.modelID,
            agentInferenceBinding: parentBinding,
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)

        let sendTask = Task {
            await orchestrator.send("Spawn only if the reviewed route remains approved.", to: main)
        }
        await gate.waitUntilSpawnReview()
        let capturedRequest = await gate.capturedRequest()
        let reviewedRequest = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(
            reviewedRequest.context?.authorization?.targetAgentInferenceBinding,
            approvedChildBinding)
        await orchestrator.updateAvailableInferenceProfiles([], hostAuthorized: true)
        await gate.release(.allow)
        let result = await sendTask.value

        XCTAssertEqual(result, .sent)
        let agents = await orchestrator.agentList()
        XCTAssertEqual(agents.map(\.name), [main])
        XCTAssertEqual(agents.first?.agentInferenceBinding, parentBinding)

        let events = await environment.log.replay()
        XCTAssertFalse(events.contains { envelope in
            guard case .toolExecutionPrepared(let payload) = envelope.event else { return false }
            return payload.tool == "spawn_agent"
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .agentSpawnRequested(let payload) = envelope.event else { return false }
            return payload.agent == childID
        })
        let resolutions = events.compactMap { envelope -> PermissionResolvedPayload? in
            guard case .permissionResolved(let payload) = envelope.event,
                  payload.tool == "spawn_agent" else { return nil }
            return payload
        }
        XCTAssertEqual(resolutions.map(\.decision), [.allow, .deny])
        XCTAssertEqual(resolutions.last?.source, .authorizationRevalidation)
        XCTAssertEqual(resolutions.last?.failureKind, .authorizationSnapshotInvalid)
        XCTAssertTrue(
            resolutions.last?.reason.contains("host-approved inference profile changed") == true)
    }

    func testExplicitSpawnRevalidatesCatalogAfterSuspendedProfileResolution() async throws {
        let environment = try PerAgentProfileEnvironment("spawn-resolution-race")
        defer { environment.remove() }
        let parentBinding = perAgentBinding(
            profile: "resolution-parent",
            model: "parent-model")
        let childBinding = perAgentBinding(
            profile: "resolution-child",
            revision: "profile-rev-9",
            connection: "child-route",
            model: "child-model",
            variant: "high")
        let childID = AgentID(rawValue: "resolution-race-child")
        let spawnArgs = try spawnArguments([
            "name": childID.rawValue,
            "path": environment.workerWorkspace.path,
            "inference_profile_id": childBinding.inferenceProfileID.rawValue,
        ])
        let provider = PerAgentSpawnScriptedProvider([
            [.toolCalls([ToolCall(
                id: "spawn-resolution-race",
                name: "spawn_agent",
                arguments: spawnArgs)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("must not report spawn success"), .done(finishReason: "stop")],
        ])
        let resolutionGate = PerAgentInferenceResolutionGate(
            blockedProfileID: childBinding.inferenceProfileID,
            provider: provider)
        let orchestrator = Orchestrator(
            log: environment.log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            availableInferenceProfiles: [childBinding],
            requiresInferenceBindings: true,
            resolvedInferenceFor: { agent in
                try await resolutionGate.resolve(agent)
            },
            providerFor: { _ in provider })
        let attached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: environment.mainWorkspace,
            model: parentBinding.modelID,
            agentInferenceBinding: parentBinding,
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)

        let sendTask = Task {
            await orchestrator.send("Spawn only while the route remains approved.", to: main)
        }
        await resolutionGate.waitUntilBlockedResolutionStarts()
        await orchestrator.updateAvailableInferenceProfiles([], hostAuthorized: true)
        await resolutionGate.release()
        let result = await sendTask.value

        XCTAssertEqual(result, .sent)
        let agentsAfterRevocation = await orchestrator.agentList()
        XCTAssertEqual(agentsAfterRevocation.map(\.name), [main])
        let events = await environment.log.replay()
        XCTAssertFalse(events.contains { envelope in
            guard case .agentSpawnRequested(let payload) = envelope.event else { return false }
            return payload.agent == childID
        })
    }

    func testAuthorizedDelegationFencesRebindAndRejectsCatalogMutationAfterSuspendedMediator() async throws {
        let environment = try PerAgentProfileEnvironment("delegate-mediator-route-race")
        defer { environment.remove() }
        let mainBinding = perAgentBinding(
            profile: "delegate-main",
            model: "delegate-main-model")
        let workerBinding = perAgentBinding(
            profile: "delegate-worker-reviewed",
            connection: "delegate-worker-route-a",
            model: "delegate-worker-model-a",
            variant: "low")
        let unreviewedRebind = perAgentBinding(
            profile: "delegate-worker-unreviewed",
            connection: "delegate-worker-route-b",
            model: "delegate-worker-model-b",
            variant: "high")
        let objective = "Run only on the exact reviewed worker route."
        let mainProvider = PerAgentSpawnScriptedProvider([
            [.toolCalls([ToolCall(
                id: "delegate-mediator-route-race",
                name: "delegate_task",
                arguments: try spawnArguments([
                    "to": worker.rawValue,
                    "objective": objective,
                ]))]), .done(finishReason: "tool_calls")],
            [.textDelta("delegation route mutation rejected"), .done(finishReason: "stop")],
        ])
        let workerProvider = PerAgentProfileProvider()
        let mediatorGate = PerAgentDelegationMediatorGate(suspendedContent: objective)
        let orchestrator = Orchestrator(
            log: environment.log,
            mediator: Mediator(reviewer: mediatorGate),
            allowsShell: false,
            responder: FixedResponder(.allow),
            availableInferenceProfiles: [mainBinding, workerBinding, unreviewedRebind],
            requiresInferenceBindings: true,
            resolvedInferenceFor: { agent in
                guard let binding = agent.agentInferenceBinding else {
                    throw InferenceCatalogError.unresolvedProfile
                }
                return ResolvedInferenceProfile(
                    binding: binding,
                    model: binding.modelID,
                    provider: agent.name == self.worker ? workerProvider : mainProvider)
            },
            providerFor: { agent in
                if agent.name == self.worker { return workerProvider }
                return mainProvider
            })
        let mainAttached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: environment.mainWorkspace,
            model: mainBinding.modelID,
            agentInferenceBinding: mainBinding,
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: environment.mainWorkspace,
            model: workerBinding.modelID,
            agentInferenceBinding: workerBinding,
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)

        let sendTask = Task {
            await orchestrator.send("Delegate with an exact route snapshot.", to: self.main)
        }
        await mediatorGate.waitUntilEntered()

        let rebind = await orchestrator.rebindAgentInferenceProfile(
            agentID: worker,
            binding: unreviewedRebind,
            hostAuthorized: true)
        guard case .failed(let rebindFailure) = rebind else {
            await mediatorGate.release()
            return XCTFail("a reviewed delegation reservation must fence host rebind")
        }
        XCTAssertTrue(rebindFailure.contains("reserved"))
        await orchestrator.updateAvailableInferenceProfiles(
            [mainBinding, unreviewedRebind],
            hostAuthorized: true)
        await mediatorGate.release()

        let sendResult = await sendTask.value
        XCTAssertEqual(sendResult, .sent)
        let liveWorker = await orchestrator.agentList().first { $0.name == worker }
        XCTAssertEqual(liveWorker?.agentInferenceBinding, workerBinding)
        XCTAssertTrue(workerProvider.requests.isEmpty)
        let events = await environment.log.replay()
        XCTAssertFalse(events.contains { envelope in
            guard case .taskCreated(let payload) = envelope.event else { return false }
            return payload.contract.assignee == worker
                && payload.contract.objective == objective
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .agentAttached(let payload) = envelope.event else { return false }
            return payload.agent == worker
                && payload.previousAgentInferenceBinding != nil
        })
    }

    func testAutomaticDelegationDoesNotProposeWorkerWhenNoneIsAttached() async throws {
        let environment = try PerAgentProfileEnvironment("delegate-no-attached-worker")
        defer { environment.remove() }
        let mainBinding = perAgentBinding(
            profile: "delegate-main-only",
            connection: "delegate-main-route",
            model: "delegate-main-model",
            variant: "medium")
        let mainProvider = PerAgentSpawnScriptedProvider([
            [.toolCalls([ToolCall(
                id: "delegate-without-attached-worker",
                name: "delegate_task",
                arguments: try spawnArguments([
                    "objective": "Use only a worker that is already attached.",
                ]))]), .done(finishReason: "tool_calls")],
            [.textDelta("no worker was admitted"), .done(finishReason: "stop")],
        ])
        let orchestrator = Orchestrator(
            log: environment.log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            availableInferenceProfiles: [mainBinding],
            requiresInferenceBindings: true,
            resolvedInferenceFor: { agent in
                guard let binding = agent.agentInferenceBinding else {
                    throw InferenceCatalogError.unresolvedProfile
                }
                return ResolvedInferenceProfile(
                    binding: binding,
                    model: binding.modelID,
                    provider: mainProvider)
            },
            providerFor: { _ in mainProvider })
        let mainAttached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: environment.mainWorkspace,
            model: mainBinding.modelID,
            agentInferenceBinding: mainBinding,
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(mainAttached)

        let sendResult = await orchestrator.send(
            "Do not create a worker implicitly.",
            to: main)
        XCTAssertEqual(sendResult, .sent)
        let remainingAgents = await orchestrator.agentNames()
        XCTAssertEqual(remainingAgents, [main])
        let events = await environment.log.replay()
        XCTAssertFalse(events.contains { envelope in
            switch envelope.event {
            case .agentSpawnRequested, .agentSpawned, .delegationApproved, .taskDelegated:
                return true
            default:
                return false
            }
        })
        XCTAssertFalse(events.contains { envelope in
            guard case .permissionRequest(let payload) = envelope.event,
                  payload.tool == "delegate_task" else { return false }
            return true
        })
    }

    func testHostRebindRejectsBusyAgentAndOnlyFutureTasksUseDurableBinding() async throws {
        let environment = try PerAgentProfileEnvironment("host-rebind")
        defer { environment.remove() }
        let original = perAgentBinding(
            profile: "worker-profile",
            revision: "profile-rev-1",
            model: "worker-model-v1",
            variant: "high")
        let rebound = perAgentBinding(
            profile: "worker-profile",
            revision: "profile-rev-2",
            model: "worker-model-v2",
            variant: "max")
        let factory = PerAgentProfileFactory()
        let orchestrator = Orchestrator(
            log: environment.log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            availableInferenceProfiles: [rebound],
            requiresInferenceBindings: true
        ) { agent in
            factory.provider(for: agent)
        }
        let mainAttached = await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: environment.mainWorkspace,
            model: original.modelID,
            agentInferenceBinding: original,
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: environment.workerWorkspace,
            model: original.modelID,
            agentInferenceBinding: original,
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)

        let first = await orchestrator.enqueueDelegatedTask(
            from: main,
            to: worker.rawValue,
            objective: "First frozen invocation.")
        XCTAssertNotNil(first.taskID)
        let busyRebind = await orchestrator.rebindAgentInferenceProfile(
            agentID: worker,
            binding: rebound,
            hostAuthorized: true)
        guard case .failed(let busyMessage) = busyRebind else {
            return XCTFail("queued invocation must fence host rebind")
        }
        XCTAssertTrue(busyMessage.contains("active or queued invocation"))

        await orchestrator.runSchedulerUntilIdle()
        let idleRebind = await orchestrator.rebindAgentInferenceProfile(
            agentID: worker,
            binding: rebound,
            hostAuthorized: true)
        XCTAssertEqual(idleRebind, .rebound(worker, rebound))

        let second = await orchestrator.enqueueDelegatedTask(
            from: main,
            to: worker.rawValue,
            objective: "Second frozen invocation.")
        XCTAssertNotNil(second.taskID)
        await orchestrator.runSchedulerUntilIdle()

        let events = await environment.log.replay()
        let workerContracts = events.compactMap { envelope -> TaskContract? in
            guard case .taskCreated(let payload) = envelope.event,
                  payload.contract.assignee == worker,
                  payload.contract.kind == .agentInvocation,
                  payload.contract.objective == "First frozen invocation."
                    || payload.contract.objective == "Second frozen invocation." else {
                return nil
            }
            return payload.contract
        }
        XCTAssertEqual(workerContracts.map(\.agentInferenceBinding), [original, rebound])

        let reboundEvent = events.compactMap { envelope -> AgentAttachedPayload? in
            guard case .agentAttached(let payload) = envelope.event,
                  payload.agent == worker,
                  payload.previousAgentInferenceBinding != nil else { return nil }
            return payload
        }.last
        XCTAssertEqual(reboundEvent?.previousAgentInferenceBinding, original)
        XCTAssertEqual(reboundEvent?.agentInferenceBinding, rebound)

        // Admission probes both agents before review and again after allow,
        // each actual task resolves atomically, and the idle rebind probes the
        // new revision before its durable commit.
        XCTAssertEqual(
            factory.resolutions.map(\.binding),
            [original, original, original, original, original, rebound, rebound])
        XCTAssertEqual(factory.provider.requests.count, 2)
    }

    func testHostRebindRevalidatesCatalogAfterSuspendedProfileResolution() async throws {
        let environment = try PerAgentProfileEnvironment("rebind-resolution-race")
        defer { environment.remove() }
        let original = perAgentBinding(
            profile: "rebind-original",
            model: "original-model")
        let rebound = perAgentBinding(
            profile: "rebind-target",
            revision: "profile-rev-7",
            connection: "new-route",
            model: "new-model")
        let provider = PerAgentProfileProvider()
        let resolutionGate = PerAgentInferenceResolutionGate(
            blockedProfileID: rebound.inferenceProfileID,
            provider: provider)
        let orchestrator = Orchestrator(
            log: environment.log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            availableInferenceProfiles: [rebound],
            requiresInferenceBindings: true,
            resolvedInferenceFor: { agent in
                try await resolutionGate.resolve(agent)
            },
            providerFor: { _ in provider })
        let attached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: environment.workerWorkspace,
            model: original.modelID,
            agentInferenceBinding: original,
            profile: .reviewed))
        XCTAssertTrue(attached)

        let rebindTask = Task {
            await orchestrator.rebindAgentInferenceProfile(
                agentID: worker,
                binding: rebound,
                hostAuthorized: true)
        }
        await resolutionGate.waitUntilBlockedResolutionStarts()
        await orchestrator.updateAvailableInferenceProfiles([], hostAuthorized: true)
        await resolutionGate.release()
        let result = await rebindTask.value

        guard case .failed(let failure) = result else {
            return XCTFail("catalog revocation during resolution must reject rebind")
        }
        XCTAssertTrue(failure.contains("no longer in the host-approved catalog"))
        let live = await orchestrator.agentList().first(where: { $0.name == worker })
        XCTAssertEqual(live?.agentInferenceBinding, original)
        let reboundEvents = await environment.log.replay().compactMap { envelope -> AgentAttachedPayload? in
            guard case .agentAttached(let payload) = envelope.event,
                  payload.agent == worker,
                  payload.previousAgentInferenceBinding != nil else { return nil }
            return payload
        }
        XCTAssertTrue(reboundEvents.isEmpty)
    }

    func testCrossTrustDomainRebindRequiresExplicitHostAuthorizationAndNeverFallsBack() async throws {
        let environment = try PerAgentProfileEnvironment("cross-trust-rebind")
        defer { environment.remove() }
        let original = perAgentBinding(
            profile: "route-a-profile",
            connection: "route-a",
            model: "same-model",
            variant: "low")
        let crossDomain = perAgentBinding(
            profile: "route-b-profile",
            connection: "route-b",
            model: "same-model",
            variant: "high")
        XCTAssertNotEqual(original.trustDomain, crossDomain.trustDomain)
        let factory = PerAgentProfileFactory()
        let orchestrator = Orchestrator(
            log: environment.log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            availableInferenceProfiles: [crossDomain],
            requiresInferenceBindings: true
        ) { agent in
            factory.provider(for: agent)
        }
        let attached = await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: environment.workerWorkspace,
            model: original.modelID,
            agentInferenceBinding: original,
            profile: .reviewed))
        XCTAssertTrue(attached)

        let denied = await orchestrator.rebindAgentInferenceProfile(
            agentID: worker,
            binding: crossDomain,
            hostAuthorized: false)
        guard case .failed = denied else {
            return XCTFail("cross-domain rebind without explicit host authorization must fail")
        }
        let agentsAfterDenied = await orchestrator.agentList()
        XCTAssertEqual(
            agentsAfterDenied.first(where: { $0.name == worker })?.agentInferenceBinding,
            original)

        let approved = await orchestrator.rebindAgentInferenceProfile(
            agentID: worker,
            binding: crossDomain,
            hostAuthorized: true)
        XCTAssertEqual(approved, .rebound(worker, crossDomain))
        let agentsAfterApproved = await orchestrator.agentList()
        XCTAssertEqual(
            agentsAfterApproved.first(where: { $0.name == worker })?.agentInferenceBinding,
            crossDomain)
        let reboundEvents = await environment.log.replay().compactMap { envelope -> AgentAttachedPayload? in
            guard case .agentAttached(let payload) = envelope.event,
                  payload.agent == worker,
                  payload.previousAgentInferenceBinding != nil else { return nil }
            return payload
        }
        XCTAssertEqual(reboundEvents.count, 1)
        XCTAssertEqual(reboundEvents.first?.previousAgentInferenceBinding, original)
        XCTAssertEqual(reboundEvents.first?.agentInferenceBinding, crossDomain)
    }
}
