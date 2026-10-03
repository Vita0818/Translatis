import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
@testable import IntatisCowork

private let A = AgentID(rawValue: "Rokurics")
private let B = AgentID(rawValue: "Kikaria")

private final class ScriptedProvider: ToolCallingProvider, @unchecked Sendable {
    private var responses: [[AgentChunk]]
    private var index = 0
    private var capturedRequests: [AgentRequest] = []
    private let lock = NSLock()
    init(_ responses: [[AgentChunk]]) { self.responses = responses }
    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }
    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        capturedRequests.append(request)
        let chunks = responses.isEmpty ? [.done(finishReason: "stop")] : responses[min(index, responses.count - 1)]
        index += 1
        lock.unlock()
        return AsyncThrowingStream { c in
            for chunk in chunks { c.yield(chunk) }
            c.finish()
        }
    }
}

private final class CapturingProvider: ToolCallingProvider, @unchecked Sendable {
    private let chunks: [AgentChunk]
    private var capturedRequests: [AgentRequest] = []
    private let lock = NSLock()

    init(_ chunks: [AgentChunk] = [.done(finishReason: "stop")]) {
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
        return AsyncThrowingStream { c in
            for chunk in chunks { c.yield(chunk) }
            c.finish()
        }
    }
}

private enum ProviderFailure: LocalizedError {
    case unavailable

    var errorDescription: String? { "provider unavailable" }
}

private struct ThrowingProvider: ToolCallingProvider {
    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ProviderFailure.unavailable)
        }
    }
}

private final class FailOnceProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var invocationCount = 0

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        invocationCount += 1
        let shouldFail = invocationCount == 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            if shouldFail {
                continuation.finish(throwing: ProviderFailure.unavailable)
            } else {
                continuation.yield(.textDelta("retried"))
                continuation.yield(.done(finishReason: "stop"))
                continuation.finish()
            }
        }
    }
}

private func tempLog() throws -> EventLog {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-cowork-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    return try EventLog(session: SessionID(rawValue: "cw"), fileURL: url)
}

private func tempWorkspace() throws -> URL {
    let ws = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    return ws
}

private func askArgs(to: String, question: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: ["to": to, "question": question]), as: UTF8.self)
}

private func spawnArgs(name: String, path: String, canCoordinate: Bool? = nil) -> String {
    var object: [String: Any] = ["name": name, "path": path]
    if let canCoordinate { object["canCoordinate"] = canCoordinate }
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func taskCreatedContracts(_ events: [Envelope]) -> [TaskContract] {
    events.compactMap {
        if case .taskCreated(let payload) = $0.event { return payload.contract }
        return nil
    }
}

private func taskAssignedContracts(_ events: [Envelope]) -> [TaskContract] {
    events.compactMap {
        if case .taskAssigned(let payload) = $0.event { return payload.contract }
        return nil
    }
}

final class IntatisCoworkTests: XCTestCase {

    // MARK: Mediator

    func testMediatorForwardsNormalContent() async {
        let d = await Mediator().mediate(from: A, to: B, content: "ledger uses confirmed bytes")
        XCTAssertEqual(d, .forward("ledger uses confirmed bytes"))
    }

    func testMediatorBlocksSecret() async {
        let d = await Mediator().mediate(from: A, to: B, content: "the key is ghp_abcdef1234567890")
        guard case .block = d else { return XCTFail("secret should block") }
    }

    func testMediatorBlocksOversized() async {
        let d = await Mediator(maxChars: 10).mediate(from: A, to: B, content: String(repeating: "x", count: 50))
        guard case .block = d else { return XCTFail("oversized should block") }
    }

    func testMediatorReviewerCanBlock() async {
        struct R: ForwardingReviewer {
            func review(from: AgentID, to: AgentID, content: String) async -> ForwardingDecision { .block(reason: "reviewer") }
        }
        let d = await Mediator(reviewer: R()).mediate(from: A, to: B, content: "small ok")
        XCTAssertEqual(d, .block(reason: "reviewer"))
    }

    // MARK: MessageBus

    func testBusForwardLogsBoth() async throws {
        let log = try tempLog()
        let out = await MessageBus(log: log, mediator: Mediator()).deliver(from: A, to: B, content: "hi")
        XCTAssertEqual(out, "hi")
        let types = await log.replay().map { $0.event.type }
        XCTAssertTrue(types.contains(.agentToAgentMessage))
        XCTAssertTrue(types.contains(.permissionReview))
    }

    func testBusBlockReturnsNilAndLogsDeny() async throws {
        let log = try tempLog()
        let out = await MessageBus(log: log, mediator: Mediator()).deliver(from: A, to: B, content: "token ghp_abcdef1234567890")
        XCTAssertNil(out)
        let events = await log.replay()
        XCTAssertFalse(events.map { $0.event.type }.contains(.agentToAgentMessage))
        let reviews = events.compactMap { e -> PermissionReviewPayload? in
            if case .permissionReview(let p) = e.event { return p } else { return nil }
        }
        XCTAssertEqual(reviews.first?.decision, .deny)
    }

    // MARK: Orchestrator

    func testExplicitMissingSendTargetDoesNotFallbackToFirstAgent() async throws {
        let log = try tempLog()
        let wsA = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: wsA) }
        let provider = CapturingProvider([.textDelta("should not run"), .done(finishReason: "stop")])
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { _ in provider }

        await orch.attach(Agent(name: A, workspaceRoot: wsA, model: ModelID(rawValue: "m"), profile: .reviewed))
        await orch.send("do not fallback", to: AgentID(rawValue: "Ghost"))

        XCTAssertTrue(provider.requests.isEmpty)
        let errors = await log.replay().compactMap { envelope -> ErrorPayload? in
            if case .error(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(errors.last?.code, "no_such_agent")
    }

    func testImplicitSendDefaultsToMainWhenMultipleAgentsAreAttached() async throws {
        let log = try tempLog()
        let main = AgentID(rawValue: "main")
        let worker = AgentID(rawValue: "worker")
        let wsMain = try tempWorkspace()
        let wsWorker = try tempWorkspace()
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }
        let mainProvider = CapturingProvider()
        let workerProvider = CapturingProvider()
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            agent.name == main ? mainProvider : workerProvider
        }

        await orch.attach(Agent(name: worker, workspaceRoot: wsWorker, model: ModelID(rawValue: "m"), profile: .reviewed))
        await orch.attach(Agent(name: main,
                                workspaceRoot: wsMain,
                                model: ModelID(rawValue: "m"),
                                profile: .reviewed,
                                coordinationDepth: Agent.defaultCoordinationDepth))

        let result = await orch.send("default project task")
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(mainProvider.requests.count, 1)
        XCTAssertEqual(workerProvider.requests.count, 0)
    }

    func testEachAgentInvocationBuildsSkillsFromItsOwnWorkspace() async throws {
        let log = try tempLog()
        let wsA = try tempWorkspace()
        let wsB = try tempWorkspace()
        defer {
            try? FileManager.default.removeItem(at: wsA)
            try? FileManager.default.removeItem(at: wsB)
        }

        func installSkill(
            _ name: String,
            marker: String,
            in workspace: URL
        ) throws {
            let directory = workspace
                .appendingPathComponent(
                    ".agents/skills/\(name)",
                    isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
            try """
            ---
            name: \(name)
            description: Workspace-local \(name) workflow.
            ---
            \(marker)
            """.write(
                to: directory.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8)
        }

        try installSkill("alpha", marker: "ALPHA_BODY", in: wsA)
        try installSkill("beta", marker: "BETA_BODY", in: wsB)
        let providerA = CapturingProvider([
            .textDelta("alpha done"),
            .done(finishReason: "stop"),
        ])
        let providerB = CapturingProvider([
            .textDelta("beta done"),
            .done(finishReason: "stop"),
        ])
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.allow)
        ) { agent in
            agent.name == A ? providerA : providerB
        }

        let attachedA = await orchestrator.attach(Agent(
            name: A,
            workspaceRoot: wsA,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        let attachedB = await orchestrator.attach(Agent(
            name: B,
            workspaceRoot: wsB,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(attachedA)
        XCTAssertTrue(attachedB)

        let sentA =
            await orchestrator.send("Use $alpha.", to: A)
        let sentB =
            await orchestrator.send("Use $beta.", to: B)
        XCTAssertEqual(sentA, .sent)
        XCTAssertEqual(sentB, .sent)

        let requestA = try XCTUnwrap(providerA.requests.first)
        let requestB = try XCTUnwrap(providerB.requests.first)
        let textA = requestA.messages.compactMap(\.content)
            .joined(separator: "\n")
        let textB = requestB.messages.compactMap(\.content)
            .joined(separator: "\n")
        XCTAssertTrue(textA.contains("alpha"))
        XCTAssertTrue(textA.contains("ALPHA_BODY"))
        XCTAssertFalse(textA.contains("beta"))
        XCTAssertFalse(textA.contains("BETA_BODY"))
        XCTAssertTrue(textB.contains("beta"))
        XCTAssertTrue(textB.contains("BETA_BODY"))
        XCTAssertFalse(textB.contains("alpha"))
        XCTAssertFalse(textB.contains("ALPHA_BODY"))
        XCTAssertEqual(
            Set(requestA.tools.map(\.name))
                .intersection(["activate_skill", "read_skill_resource"]),
            ["activate_skill", "read_skill_resource"])
        XCTAssertEqual(
            Set(requestB.tools.map(\.name))
                .intersection(["activate_skill", "read_skill_resource"]),
            ["activate_skill", "read_skill_resource"])
    }

    func testMainProviderRequestCarriesCompletedConversationAcrossTurns() async throws {
        let log = try tempLog()
        let main = AgentID(rawValue: "main")
        let workspace = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ScriptedProvider([
            [.textDelta("A1"), .done(finishReason: "stop")],
            [.textDelta("A2"), .done(finishReason: "stop")],
            [.textDelta("A3"), .done(finishReason: "stop")],
        ])
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.allow)) { _ in provider }
        let submittedIntentStore = SubmittedIntentStore(log: log)

        await orchestrator.attach(Agent(
            name: main,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))

        let firstPayload = UserMessagePayload(
            text: "U1",
            to: main,
            submissionID: SubmissionID(rawValue: "sub_main_u1"))
        let secondPayload = UserMessagePayload(
            text: "U2",
            to: main,
            submissionID: SubmissionID(rawValue: "sub_main_u2"))
        let thirdPayload = UserMessagePayload(
            text: "U3",
            to: main,
            submissionID: SubmissionID(rawValue: "sub_main_u3"))
        _ = try await submittedIntentStore.accept(payload: firstPayload)
        let first = await orchestrator.send(
            "U1",
            to: main,
            userMessage: firstPayload,
            recordUserMessage: false)
        _ = try await submittedIntentStore.accept(payload: secondPayload)
        let second = await orchestrator.send(
            "U2",
            to: main,
            userMessage: secondPayload,
            recordUserMessage: false)
        _ = try await submittedIntentStore.accept(payload: thirdPayload)
        let third = await orchestrator.send(
            "U3",
            to: main,
            userMessage: thirdPayload,
            recordUserMessage: false)
        XCTAssertEqual(first, .sent)
        XCTAssertEqual(second, .sent)
        XCTAssertEqual(third, .sent)

        let thirdRequest = try XCTUnwrap(provider.requests.last)
        let expectedText = Set(["U1", "A1", "U2", "A2", "U3"])
        let conversation: [(AgentRole, String)] = thirdRequest.messages.compactMap {
            message -> (AgentRole, String)? in
            guard let content = message.content,
                  expectedText.contains(content) else {
                return nil
            }
            return (message.role, content)
        }

        XCTAssertEqual(
            conversation.map { $0.0 },
            [AgentRole.user, .assistant, .user, .assistant, .user])
        XCTAssertEqual(
            conversation.map { $0.1 },
            ["U1", "A1", "U2", "A2", "U3"])
        XCTAssertEqual(
            thirdRequest.messages.filter { $0.content == "U3" }.count,
            1)
    }

    func testDirectWorkerRootRemainsTaskScopedAcrossTurns() async throws {
        let log = try tempLog()
        let worker = AgentID(rawValue: "worker")
        let workspace = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = ScriptedProvider([
            [.textDelta("worker A1"), .done(finishReason: "stop")],
            [.textDelta("worker A2"), .done(finishReason: "stop")],
        ])
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.allow)) { _ in provider }
        let submittedIntentStore = SubmittedIntentStore(log: log)

        await orchestrator.attach(Agent(
            name: worker,
            workspaceRoot: workspace,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))

        let firstPayload = UserMessagePayload(
            text: "worker U1",
            to: worker,
            submissionID: SubmissionID(rawValue: "sub_worker_u1"))
        let secondPayload = UserMessagePayload(
            text: "worker U2",
            to: worker,
            submissionID: SubmissionID(rawValue: "sub_worker_u2"))
        _ = try await submittedIntentStore.accept(payload: firstPayload)
        let first = await orchestrator.send(
            "worker U1",
            to: worker,
            userMessage: firstPayload,
            recordUserMessage: false)
        _ = try await submittedIntentStore.accept(payload: secondPayload)
        let second = await orchestrator.send(
            "worker U2",
            to: worker,
            userMessage: secondPayload,
            recordUserMessage: false)
        XCTAssertEqual(first, .sent)
        XCTAssertEqual(second, .sent)

        let secondRequest = try XCTUnwrap(provider.requests.last)
        XCTAssertFalse(secondRequest.messages.contains { $0.content == "worker U1" })
        XCTAssertFalse(secondRequest.messages.contains { $0.content == "worker A1" })
        XCTAssertEqual(
            secondRequest.messages.filter { $0.content == "worker U2" }.count,
            1)
    }

    func testSendReturnsFailureWhenAgentRunFails() async throws {
        let log = try tempLog()
        let wsA = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: wsA) }
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { _ in
            ThrowingProvider()
        }

        await orch.attach(Agent(name: A, workspaceRoot: wsA, model: ModelID(rawValue: "m"), profile: .reviewed))
        let result = await orch.send("fail visibly", to: A)

        XCTAssertEqual(result, .failed("provider unavailable"))
        let errors = await log.replay().compactMap { envelope -> ErrorPayload? in
            if case .error(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(errors.last?.message, "provider unavailable")
    }

    func testSendRecordsGoalPayloadForTargetedCoworkMessage() async throws {
        let log = try tempLog()
        let wsA = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: wsA) }
        let provider = CapturingProvider([.textDelta("ok"), .done(finishReason: "stop")])
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { _ in provider }
        await orch.attach(Agent(name: A, workspaceRoot: wsA, model: ModelID(rawValue: "m"), profile: .reviewed))

        let result = await orch.send(
            "ship v0.12",
            to: A,
            userMessage: UserMessagePayload(text: "ship v0.12", to: A, tags: ["Goal"], goal: "ship v0.12"))

        XCTAssertEqual(result, .sent)
        let payloads = await log.replay().compactMap { envelope -> UserMessagePayload? in
            if case .userMessage(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(payloads.last?.text, "ship v0.12")
        XCTAssertEqual(payloads.last?.to, A)
        XCTAssertEqual(payloads.last?.tags ?? [], ["Goal"])
        XCTAssertEqual(payloads.last?.goal, "ship v0.12")
        let userMessages = provider.requests.last?.messages.filter { $0.role == .user }.compactMap(\.content)
        XCTAssertEqual(userMessages?.last, "ship v0.12")
    }

    func testRetryFailedTaskRequeuesExistingContract() async throws {
        let log = try tempLog()
        let wsA = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: wsA) }
        let provider = FailOnceProvider()
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { _ in provider }
        await orch.attach(Agent(name: A, workspaceRoot: wsA, model: ModelID(rawValue: "m"), profile: .reviewed))
        let firstResult = await orch.send("Retry the failed task.", to: A)
        guard case .failed = firstResult else { return XCTFail("first attempt must fail") }
        let failedProjection = CoworkProjection.build(from: await log.replay())
        let failed = try XCTUnwrap(failedProjection.failedTasks.first)
        let originalContract = try XCTUnwrap(failed.contract)

        let result = await orch.retry(failed)

        XCTAssertEqual(result, .sent)
        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(projection.tasks[originalContract.id]?.status, .completed)
        XCTAssertEqual(projection.tasks[originalContract.id]?.result, "retried")
        XCTAssertEqual(projection.tasks[originalContract.id]?.attempt, 2)
    }

    func testAgentToAgentFlowIsMediatedAndLogged() async throws {
        let log = try tempLog()
        let wsA = try tempWorkspace(), wsB = try tempWorkspace()
        let provA = ScriptedProvider([
            [.toolCalls([ToolCall(id: "c1", name: "ask_agent",
                                  arguments: askArgs(to: "Kikaria", question: "what are ledger semantics?"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("Kikaria answered."), .done(finishReason: "stop")],
        ])
        let provB = ScriptedProvider([
            [.textDelta("confirmed bytes = durable prefix"), .done(finishReason: "stop")],
        ])
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            agent.name == A ? provA : provB
        }
        await orch.attach(Agent(name: A, workspaceRoot: wsA, model: ModelID(rawValue: "m"), profile: .reviewed,
                                coordinationDepth: Agent.defaultCoordinationDepth))
        await orch.attach(Agent(name: B, workspaceRoot: wsB, model: ModelID(rawValue: "m"), profile: .reviewed))
        await orch.send("compare sync designs", to: A)

        let events = await log.replay()
        let a2a = events.compactMap { e -> AgentToAgentMessagePayload? in
            if case .agentToAgentMessage(let p) = e.event { return p } else { return nil }
        }
        XCTAssertEqual(a2a.count, 2)
        guard a2a.count == 2 else { return }
        XCTAssertEqual(a2a[0].from, A); XCTAssertEqual(a2a[0].to, B)
        XCTAssertEqual(a2a[1].from, B); XCTAssertEqual(a2a[1].to, A)
        XCTAssertTrue(a2a[1].content.contains("confirmed bytes"))
        XCTAssertTrue(events.map { $0.event.type }.contains(.agentAttached))
    }

    func testAskAgentCreatesTaskContractAndInjectsPrompt() async throws {
        let log = try tempLog()
        let wsA = try tempWorkspace(), wsB = try tempWorkspace()
        defer {
            try? FileManager.default.removeItem(at: wsA)
            try? FileManager.default.removeItem(at: wsB)
        }
        let workerProvider = CapturingProvider([.textDelta("done"), .done(finishReason: "stop")])
        let mainProvider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "ask", name: "ask_agent",
                                  arguments: askArgs(to: B.rawValue, question: "Inspect the workspace API."))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("worker answered"), .done(finishReason: "stop")],
        ])
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            if agent.name == B {
                return workerProvider
            }
            return mainProvider
        }

        await orch.attach(Agent(name: A, workspaceRoot: wsA, model: ModelID(rawValue: "m"), profile: .reviewed,
                                coordinationDepth: Agent.defaultCoordinationDepth))
        await orch.attach(Agent(name: B, workspaceRoot: wsB, model: ModelID(rawValue: "m"), profile: .reviewed))
        await orch.send("ask worker", to: A)

        let events = await log.replay()
        let created = taskCreatedContracts(events).filter { $0.assignee == B }
        let assigned = taskAssignedContracts(events).filter { $0.assignee == B }
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(assigned.count, 1)
        let contract = try XCTUnwrap(created.first)
        XCTAssertEqual(assigned.first, contract)
        XCTAssertEqual(contract.issuer, A)
        XCTAssertEqual(contract.assignee, B)
        XCTAssertFalse(contract.objective.isEmpty)
        XCTAssertFalse(contract.expectedDeliverable.isEmpty)
        XCTAssertTrue(contract.relatedAgents.contains(A))
        XCTAssertTrue(contract.constraints.contains("Complete only the assigned task."))
        XCTAssertTrue(contract.constraints.contains("Do not re-run the global task decomposition."))
        XCTAssertTrue(contract.constraints.contains("Do not create, remove, or coordinate other agents."))

        let request = try XCTUnwrap(workerProvider.requests.first)
        let systemPrompt = try XCTUnwrap(request.messages.first?.content)
        let untrustedContext = try XCTUnwrap(request.messages.first {
            $0.role == .user && $0.content?.contains("<<<UNTRUSTED_CONTEXT_DATA>>>") == true
        }?.content)
        XCTAssertFalse(systemPrompt.contains(contract.objective))
        XCTAssertTrue(untrustedContext.contains("Current AgentInvocation data:"))
        XCTAssertTrue(untrustedContext.contains(contract.id.rawValue))
        XCTAssertTrue(untrustedContext.contains("@\(A.rawValue)"))
        XCTAssertTrue(untrustedContext.contains(contract.roleHint))
        XCTAssertTrue(untrustedContext.contains("[same as the current user turn; omitted here]"))
        XCTAssertEqual(request.messages.filter { $0.role == .user }.compactMap(\.content).last,
                       contract.objective)
        XCTAssertTrue(untrustedContext.contains(contract.expectedDeliverable))
        XCTAssertTrue(untrustedContext.contains("Complete only the assigned task."))
        XCTAssertTrue(untrustedContext.contains("Do not re-run the global task decomposition."))
        XCTAssertTrue(untrustedContext.contains("Do not create, remove, or coordinate other agents."))
        XCTAssertFalse(systemPrompt.lowercased().contains("you can spawn agents"))
        XCTAssertFalse(systemPrompt.lowercased().contains("you can coordinate agents"))
        XCTAssertFalse(systemPrompt.lowercased().contains("you can delegate freely"))
    }

    func testSecretQuestionIsBlockedBeforeReachingPeerWithoutPartialMessageFacts() async throws {
        let log = try tempLog()
        let wsA = try tempWorkspace(), wsB = try tempWorkspace()
        let provA = ScriptedProvider([
            [.toolCalls([ToolCall(id: "c1", name: "ask_agent",
                                  arguments: askArgs(to: "Kikaria", question: "here is my key ghp_abcdef1234567890"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("ok"), .done(finishReason: "stop")],
        ])
        let provB = ScriptedProvider([])  // must never be reached
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            agent.name == A ? provA : provB
        }
        await orch.attach(Agent(name: A, workspaceRoot: wsA, model: ModelID(rawValue: "m"), profile: .reviewed,
                                coordinationDepth: Agent.defaultCoordinationDepth))
        await orch.attach(Agent(name: B, workspaceRoot: wsB, model: ModelID(rawValue: "m"), profile: .reviewed))
        await orch.send("leak the key", to: A)

        let events = await log.replay()
        let a2a = events.filter { if case .agentToAgentMessage = $0.event { return true } else { return false } }
        XCTAssertTrue(a2a.isEmpty, "secret content must not be forwarded")
        let mediationAudits = events.compactMap { e -> PermissionReviewPayload? in
            if case .permissionReview(let payload) = e.event { return payload }
            return nil
        }
        let results = events.compactMap { event -> ToolResultPayload? in
            if case .toolResult(let payload) = event.event { return payload }
            return nil
        }
        XCTAssertTrue(mediationAudits.isEmpty, "Mediator rejection must not append communication audit facts")
        XCTAssertTrue(results.contains {
            $0.observation.contains("blocked by the mediator")
        })
    }

    func testMainCanSpawnWorkerButSpawnedWorkerHasNoCoordinatorTools() async throws {
        let log = try tempLog()
        let main = AgentID(rawValue: "main")
        let worker = AgentID(rawValue: "worker")
        let wsMain = try tempWorkspace()
        let wsWorker = wsMain.appendingPathComponent("worker", isDirectory: true)
        try FileManager.default.createDirectory(at: wsWorker, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
        }
        let mainProvider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "spawn", name: "spawn_agent",
                                  arguments: spawnArgs(name: worker.rawValue, path: wsWorker.path))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("worker ready"), .done(finishReason: "stop")],
        ])
        let workerProvider = CapturingProvider()
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            if agent.name == worker {
                return workerProvider
            }
            return mainProvider
        }

        let attached = await orch.attach(Agent(name: main, workspaceRoot: wsMain, model: ModelID(rawValue: "m"),
                                               profile: .reviewed,
                                               coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        await orch.send("create a worker", to: main)

        let spawned = await orch.agentList().first { $0.name == worker }
        XCTAssertNotNil(spawned)
        XCTAssertEqual(spawned?.coordinationDepth, 0)

        await orch.send("count assigned files", to: worker)
        let request = try XCTUnwrap(workerProvider.requests.last)
        let toolNames = Set(request.tools.map(\.name))
        XCTAssertFalse(toolNames.contains("spawn_agent"))
        XCTAssertFalse(toolNames.contains("ask_agent"))
        XCTAssertFalse(toolNames.contains("list_agents"))
        XCTAssertFalse(toolNames.contains("remove_agent"))
        XCTAssertFalse(toolNames.contains("rename_session"))

        let systemPrompt = try XCTUnwrap(request.messages.first?.content)
        XCTAssertTrue(systemPrompt.contains("running inside Intatis"))
        XCTAssertTrue(systemPrompt.contains("in Cowork mode"))
        XCTAssertTrue(systemPrompt.contains("authoritative API tools list"))
        XCTAssertTrue(systemPrompt.contains("only after receiving its ToolResult"))
        XCTAssertTrue(systemPrompt.contains("You are executing the assigned task as a worker agent."))
        XCTAssertTrue(systemPrompt.contains("Do not create, remove, or coordinate other agents."))
        XCTAssertTrue(systemPrompt.contains("Use reply_message only once for the exact frozen information"))
        XCTAssertTrue(systemPrompt.contains("Do not re-run the global task decomposition."))
        XCTAssertFalse(systemPrompt.contains("spawn_agent"))
        XCTAssertFalse(systemPrompt.contains("ask_agent"))
        XCTAssertFalse(systemPrompt.contains("list_agents"))
        XCTAssertFalse(systemPrompt.contains("remove_agent"))
        XCTAssertFalse(systemPrompt.contains("COORDINATOR"))
        XCTAssertFalse(systemPrompt.lowercased().contains("delegate"))
    }

    func testMainCanExplicitlySpawnCoordinatorSubAgent() async throws {
        let log = try tempLog()
        let main = AgentID(rawValue: "main")
        let lead = AgentID(rawValue: "feature-lead")
        let wsMain = try tempWorkspace()
        let wsLead = wsMain.appendingPathComponent("feature", isDirectory: true)
        try FileManager.default.createDirectory(at: wsLead, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
        }
        let mainProvider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "spawn", name: "spawn_agent",
                                  arguments: spawnArgs(name: lead.rawValue,
                                                       path: wsLead.path,
                                                       canCoordinate: true))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("lead ready"), .done(finishReason: "stop")],
        ])
        let leadProvider = CapturingProvider()
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            if agent.name == lead {
                return leadProvider
            }
            return mainProvider
        }

        let attached = await orch.attach(Agent(name: main,
                                               workspaceRoot: wsMain,
                                               model: ModelID(rawValue: "m"),
                                               profile: .reviewed,
                                               coordinationDepth: Agent.defaultCoordinationDepth))
        XCTAssertTrue(attached)
        await orch.send("create a sub coordinator for this feature", to: main)

        let mainRequest = try XCTUnwrap(mainProvider.requests.first)
        let mainToolNames = Set(mainRequest.tools.map(\.name))
        XCTAssertTrue(mainToolNames.contains("spawn_agent"))
        XCTAssertTrue(mainToolNames.contains("delegate_task"))
        XCTAssertTrue(mainToolNames.contains("rename_session"))
        let spawnDescriptor = try XCTUnwrap(mainRequest.tools.first { $0.name == "spawn_agent" })
        let spawnSchema = String(
            decoding: try JSONEncoder().encode(spawnDescriptor.parameters),
            as: UTF8.self)
        XCTAssertTrue(spawnSchema.contains(#""additionalProperties":false"#))
        let mainSystemPrompt = try XCTUnwrap(mainRequest.messages.first?.content)
        XCTAssertTrue(mainSystemPrompt.contains("running inside Intatis"))
        XCTAssertTrue(mainSystemPrompt.contains("in Cowork mode"))
        XCTAssertTrue(mainSystemPrompt.contains("authoritative API tools list"))
        XCTAssertTrue(mainSystemPrompt.contains("only after receiving its ToolResult"))

        let spawned = await orch.agentList().first { $0.name == lead }
        XCTAssertNotNil(spawned)
        XCTAssertEqual(spawned?.coordinationDepth, 1)

        await orch.send("coordinate the nested implementation work", to: lead)
        let request = try XCTUnwrap(leadProvider.requests.last)
        let toolNames = Set(request.tools.map(\.name))
        XCTAssertTrue(toolNames.contains("spawn_agent"))
        XCTAssertTrue(toolNames.contains("delegate_task"))
        XCTAssertTrue(toolNames.contains("list_agents"))
        XCTAssertTrue(toolNames.contains("remove_agent"))
        XCTAssertFalse(toolNames.contains("rename_session"))

        let systemPrompt = try XCTUnwrap(request.messages.first?.content)
        XCTAssertTrue(systemPrompt.contains("running inside Intatis"))
        XCTAssertTrue(systemPrompt.contains("in Cowork mode"))
        XCTAssertTrue(systemPrompt.contains("authoritative API tools list"))
        XCTAssertTrue(systemPrompt.contains("only after receiving its ToolResult"))
        XCTAssertTrue(systemPrompt.contains("You may also act as a COORDINATOR"))
        XCTAssertTrue(systemPrompt.contains("Agents you create are"))
    }

    func testWorkerCannotAskItself() async throws {
        let log = try tempLog()
        let worker = AgentID(rawValue: "worker")
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let provider = CapturingProvider([.textDelta("should not run"), .done(finishReason: "stop")])
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { _ in provider }

        let attached = await orch.attach(Agent(name: worker, workspaceRoot: ws, model: ModelID(rawValue: "m"),
                                               profile: .reviewed))
        XCTAssertTrue(attached)
        let response = await orch.ask(from: worker, to: "@worker", question: "can you do this?")

        XCTAssertEqual(response, "error: agent cannot ask itself")
        XCTAssertTrue(provider.requests.isEmpty)
        let events = await log.replay()
        XCTAssertFalse(events.contains { if case .agentToAgentMessage = $0.event { return true } else { return false } })
        XCTAssertTrue(events.contains {
            if case .error(let payload) = $0.event { return payload.code == "agent_self_call" }
            return false
        })
    }

    func testSpawnAgentDescriptorIsNotReadOnly() {
        XCTAssertEqual(SpawnAgentTool.descriptor.sideEffect, .write)
        XCTAssertTrue(
            SpawnAgentTool.descriptor.description
                .contains("recommended default"))
        XCTAssertTrue(
            SpawnAgentTool.descriptor.description
                .contains("list_inference_profiles"))
        XCTAssertTrue(
            ListInferenceProfilesTool.descriptor.description
                .contains("configuration-declared capabilities"))
        XCTAssertTrue(
            ListInferenceProfilesTool.descriptor.description
                .contains("never infer a missing capability"))
    }

    func testSpawnAgentIntentIsControlPlaneAndDefaultsToReadOnly() throws {
        let root = URL(fileURLWithPath: "/workspace")
        let args = ToolArgs(raw: #"{"name":"counter","path":"/workspace","canCoordinate":false}"#)
        let tool = SpawnAgentTool()
        let intent = tool.permissionIntent(args, workspaceRoot: root)

        XCTAssertEqual(intent.action, "agent.spawn")
        XCTAssertEqual(intent.dataEffects, [.none])
        XCTAssertEqual(intent.controlEffects, [.createAgent, .attachWorkspace, .grantCapability])
        XCTAssertEqual(intent.metadata["requestedAccess"], .string(WorkspaceAccess.readOnly.rawValue))
        XCTAssertTrue(tool.touchedPaths(args).isEmpty)
        XCTAssertFalse(intent.resources.contains { $0.kind == .workspacePath })
        XCTAssertTrue(intent.resources.contains {
            $0.kind == .workspace && $0.access == .readOnly
        })
    }

    func testCountScenarioCreatesSeparateWorkerContracts() async throws {
        let log = try tempLog()
        let main = AgentID(rawValue: "main")
        let macos = AgentID(rawValue: "macos-counter")
        let ios = AgentID(rawValue: "ios-counter")
        let wsMain = try tempWorkspace()
        let wsMacos = try tempWorkspace()
        let wsIOS = try tempWorkspace()
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsMacos)
            try? FileManager.default.removeItem(at: wsIOS)
        }
        let macosProvider = CapturingProvider([.textDelta("macOS count"), .done(finishReason: "stop")])
        let iosProvider = CapturingProvider([.textDelta("iOS count"), .done(finishReason: "stop")])
        let mainProvider = CapturingProvider()
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            if agent.name == macos {
                return macosProvider
            }
            if agent.name == ios {
                return iosProvider
            }
            return mainProvider
        }

        await orch.attach(Agent(name: main, workspaceRoot: wsMain, model: ModelID(rawValue: "m"), profile: .reviewed,
                                coordinationDepth: Agent.defaultCoordinationDepth))
        await orch.attach(Agent(name: macos, workspaceRoot: wsMacos, model: ModelID(rawValue: "m"), profile: .reviewed))
        await orch.attach(Agent(name: ios, workspaceRoot: wsIOS, model: ModelID(rawValue: "m"), profile: .reviewed))

        _ = await orch.ask(from: main, to: macos.rawValue,
                           question: "Recursively count macOS Swift files only.")
        _ = await orch.ask(from: main, to: ios.rawValue,
                           question: "Recursively count iOS Swift files only.")

        let contracts = taskCreatedContracts(await log.replay())
        XCTAssertEqual(contracts.count, 2)
        let macosContract = try XCTUnwrap(contracts.first { $0.assignee == macos })
        let iosContract = try XCTUnwrap(contracts.first { $0.assignee == ios })

        XCTAssertEqual(macosContract.roleHint, "macOS Swift file counter")
        XCTAssertEqual(iosContract.roleHint, "iOS Swift file counter")
        XCTAssertTrue(macosContract.objective.contains("macOS"))
        XCTAssertFalse(macosContract.objective.contains("iOS"))
        XCTAssertTrue(iosContract.objective.contains("iOS"))
        XCTAssertFalse(iosContract.objective.contains("macOS"))
        XCTAssertNotEqual(macosContract.assignee, iosContract.assignee)
        XCTAssertTrue(macosContract.relatedAgents.contains(ios))
        XCTAssertTrue(iosContract.relatedAgents.contains(macos))

        let agents = await orch.agentList()
        XCTAssertEqual(agents.first { $0.name == macos }?.coordinationDepth, 0)
        XCTAssertEqual(agents.first { $0.name == ios }?.coordinationDepth, 0)

        let macosPrompt = macosProvider.requests.first?.messages.compactMap(\.content).joined(separator: "\n") ?? ""
        let iosPrompt = iosProvider.requests.first?.messages.compactMap(\.content).joined(separator: "\n") ?? ""
        XCTAssertTrue(macosPrompt.contains("macOS Swift file counter"))
        XCTAssertTrue(macosPrompt.contains("Recursively count macOS Swift files only."))
        XCTAssertTrue(iosPrompt.contains("iOS Swift file counter"))
        XCTAssertTrue(iosPrompt.contains("Recursively count iOS Swift files only."))
    }
}
