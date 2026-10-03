import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
@testable import IntatisCowork

private final class E2EProvider: ToolCallingProvider, @unchecked Sendable {
    private let responses: [[AgentChunk]]
    private let lock = NSLock()
    private var index = 0
    private var capturedRequests: [AgentRequest] = []

    init(_ responses: [[AgentChunk]]) {
        self.responses = responses
    }

    convenience init(text: String) {
        self.init([[.textDelta(text), .done(finishReason: "stop")]])
    }

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        capturedRequests.append(request)
        let response = responses.isEmpty ? [.done(finishReason: "stop")] : responses[min(index, responses.count - 1)]
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

private struct CounterFixture {
    var root: URL
    var macOSRoot: URL
    var iOSRoot: URL
}

private func e2eLog() throws -> EventLog {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-cowork-e2e-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    return try EventLog(session: SessionID(rawValue: "cowork_e2e"), fileURL: url)
}

private func makeCounterFixture() throws -> CounterFixture {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("intatis-cowork-count-fixture-\(UUID().uuidString)", isDirectory: true)
    let macSources = root
        .appendingPathComponent("Apps", isDirectory: true)
        .appendingPathComponent("TranslatisMac", isDirectory: true)
        .appendingPathComponent("Sources", isDirectory: true)
    let iosSources = root
        .appendingPathComponent("Apps", isDirectory: true)
        .appendingPathComponent("TranslatisiOS", isDirectory: true)
        .appendingPathComponent("Sources", isDirectory: true)
    try fm.createDirectory(at: macSources, withIntermediateDirectories: true)
    try fm.createDirectory(at: iosSources, withIntermediateDirectories: true)
    try "struct A {}\n".write(to: macSources.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
    try "struct B {}\n".write(to: macSources.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)
    try "struct C {}\n".write(to: iosSources.appendingPathComponent("C.swift"), atomically: true, encoding: .utf8)
    try "struct D {}\n".write(to: iosSources.appendingPathComponent("D.swift"), atomically: true, encoding: .utf8)
    try "struct E {}\n".write(to: iosSources.appendingPathComponent("E.swift"), atomically: true, encoding: .utf8)
    try "# Fixture\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    return CounterFixture(
        root: root,
        macOSRoot: root.appendingPathComponent("Apps/TranslatisMac", isDirectory: true),
        iOSRoot: root.appendingPathComponent("Apps/TranslatisiOS", isDirectory: true))
}

private func taskContracts(_ events: [Envelope], assignee: AgentID? = nil) -> [TaskContract] {
    events.compactMap {
        if case .taskCreated(let payload) = $0.event,
           assignee == nil || payload.contract.assignee == assignee {
            return payload.contract
        }
        return nil
    }
}

private func firstIndex(of type: Event.TypeTag, taskID: TaskID, in events: [Envelope]) -> Int? {
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
        default:
            return false
        }
    }
}

private func jsonObject(_ object: [String: String]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

final class CoworkEndToEndTests: XCTestCase {
    private let main = AgentID(rawValue: "main")
    private let macOS = AgentID(rawValue: "macos-counter")
    private let iOS = AgentID(rawValue: "ios-counter")

    func testMacOSIOSSwiftFileCountScenarioClosesThroughSchedulerAndProjection() async throws {
        let fixture = try makeCounterFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let log = try e2eLog()
        let macOSProvider = E2EProvider(text: "macOS Swift count: 2\nApps/TranslatisMac/Sources/A.swift\nApps/TranslatisMac/Sources/B.swift")
        let iOSProvider = E2EProvider(text: "iOS Swift count: 3\nApps/TranslatisiOS/Sources/C.swift\nApps/TranslatisiOS/Sources/D.swift\nApps/TranslatisiOS/Sources/E.swift")
        let mainProvider = E2EProvider(text: "main")
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            if agent.name == self.macOS { return macOSProvider }
            if agent.name == self.iOS { return iOSProvider }
            return mainProvider
        }

        let mainAttached = await orch.attach(Agent(name: main, workspaceRoot: fixture.root,
                                                   model: ModelID(rawValue: "m"), profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        let macOSAttached = await orch.attach(Agent(name: macOS, workspaceRoot: fixture.macOSRoot,
                                                    model: ModelID(rawValue: "m"), profile: .reviewed))
        let iOSAttached = await orch.attach(Agent(name: iOS, workspaceRoot: fixture.iOSRoot,
                                                  model: ModelID(rawValue: "m"), profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(macOSAttached)
        XCTAssertTrue(iOSAttached)

        let globalRequest = "拉起两个子 Agent，分别统计 macOS 和 iOS Swift 文件。"
        try await log.append(.userMessage(UserMessagePayload(text: globalRequest)))
        let rootTaskIDOptional = await orch.createRootTask(
            assignee: main,
            objective: "Count Swift files for macOS and iOS.",
            roleHint: "Swift count coordinator",
            expectedDeliverable: "Combined macOS and iOS Swift file count summary.")
        let rootTaskID = try XCTUnwrap(rootTaskIDOptional)

        let macOSObjective = "Recursively count Swift files in Apps/TranslatisMac only. Do not count iOS files."
        let iOSObjective = "Recursively count Swift files in Apps/TranslatisiOS only. Do not count macOS files."
        let macOSQueued = await orch.enqueueDelegatedTask(
            from: main,
            to: macOS.rawValue,
            objective: macOSObjective,
            roleHint: "macOS Swift file counter",
            expectedDeliverable: "macOS Swift file count plus relative path list.",
            parentTaskID: rootTaskID)
        let iOSQueued = await orch.enqueueDelegatedTask(
            from: main,
            to: iOS.rawValue,
            objective: iOSObjective,
            roleHint: "iOS Swift file counter",
            expectedDeliverable: "iOS Swift file count plus relative path list.",
            parentTaskID: rootTaskID)
        let macOSTaskID = try XCTUnwrap(macOSQueued.taskID)
        let iOSTaskID = try XCTUnwrap(iOSQueued.taskID)

        let queuedProjection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(Set(queuedProjection.queuedTasks.map(\.id)), Set([macOSTaskID, iOSTaskID]))

        let contractEvents = await log.replay()
        let macOSContract = try XCTUnwrap(taskContracts(contractEvents, assignee: macOS).last)
        let iOSContract = try XCTUnwrap(taskContracts(contractEvents, assignee: iOS).last)
        XCTAssertEqual(macOSContract.assignee, macOS)
        XCTAssertEqual(iOSContract.assignee, iOS)
        XCTAssertTrue(macOSContract.objective.contains("TranslatisMac"))
        XCTAssertFalse(macOSContract.objective.contains("TranslatisiOS"))
        XCTAssertTrue(iOSContract.objective.contains("TranslatisiOS"))
        XCTAssertFalse(iOSContract.objective.contains("TranslatisMac only"))

        let macOSCapabilityLeaseID = try XCTUnwrap(macOSContract.capabilityLeaseID)
        let iOSCapabilityLeaseID = try XCTUnwrap(iOSContract.capabilityLeaseID)
        let macOSLeaseOptional = await orch.capabilityLease(id: macOSCapabilityLeaseID)
        let iOSLeaseOptional = await orch.capabilityLease(id: iOSCapabilityLeaseID)
        let macOSLease = try XCTUnwrap(macOSLeaseOptional)
        let iOSLease = try XCTUnwrap(iOSLeaseOptional)
        for lease in [macOSLease, iOSLease] {
            XCTAssertFalse(lease.tools.contains(.delegateTask))
            XCTAssertFalse(lease.tools.contains(.attachWorkspace))
        }

        await orch.runSchedulerUntilIdle()

        let macOSRequest = try XCTUnwrap(macOSProvider.requests.first)
        let iOSRequest = try XCTUnwrap(iOSProvider.requests.first)
        XCTAssertEqual(macOSProvider.requests.count, 1)
        XCTAssertEqual(iOSProvider.requests.count, 1)
        assertWorkerToolSurface(macOSRequest)
        assertWorkerToolSurface(iOSRequest)

        let macOSSystemPrompt = try XCTUnwrap(macOSRequest.messages.first?.content)
        let macOSPrompt = macOSRequest.messages.compactMap(\.content).joined(separator: "\n")
        XCTAssertFalse(macOSSystemPrompt.contains(macOSObjective))
        XCTAssertTrue(macOSPrompt.contains("Current AgentInvocation data:"))
        XCTAssertTrue(macOSPrompt.contains("Your role in this invocation:"))
        XCTAssertTrue(macOSPrompt.contains("macOS Swift file counter"))
        XCTAssertTrue(macOSPrompt.contains(macOSObjective))
        XCTAssertTrue(macOSPrompt.contains("Expected deliverable:"))
        XCTAssertTrue(macOSPrompt.contains("macOS Swift file count plus relative path list."))
        XCTAssertTrue(macOSPrompt.contains("@ios-counter"))
        XCTAssertTrue(macOSPrompt.contains("Do not re-run the global task decomposition."))
        XCTAssertTrue(macOSPrompt.contains("Do not create, remove, or coordinate other agents."))
        XCTAssertFalse(macOSPrompt.contains(fixture.iOSRoot.path))
        XCTAssertFalse(macOSPrompt.contains(iOSObjective))
        XCTAssertFalse(macOSPrompt.contains("You may also act as a COORDINATOR"))
        XCTAssertFalse(macOSPrompt.contains("spawn_agent"))
        XCTAssertFalse(macOSPrompt.contains("delegate_task"))

        let iOSSystemPrompt = try XCTUnwrap(iOSRequest.messages.first?.content)
        let iOSPrompt = iOSRequest.messages.compactMap(\.content).joined(separator: "\n")
        XCTAssertFalse(iOSSystemPrompt.contains(iOSObjective))
        XCTAssertTrue(iOSPrompt.contains("Your role in this invocation:"))
        XCTAssertTrue(iOSPrompt.contains("iOS Swift file counter"))
        XCTAssertTrue(iOSPrompt.contains(iOSObjective))
        XCTAssertTrue(iOSPrompt.contains("@macos-counter"))
        XCTAssertFalse(iOSPrompt.contains(fixture.macOSRoot.path))
        XCTAssertFalse(iOSPrompt.contains(macOSObjective))

        let macOSUserMessages = macOSRequest.messages.filter { $0.role == .user }.compactMap(\.content)
        XCTAssertEqual(macOSUserMessages.last, macOSObjective)
        XCTAssertTrue(macOSUserMessages.contains { $0.contains("<<<UNTRUSTED_CONTEXT_DATA>>>") })
        XCTAssertFalse(macOSUserMessages.contains { $0.contains(globalRequest) })

        let events = await log.replay()
        let runningIndex = try XCTUnwrap(firstIndex(of: .taskStarted, taskID: macOSTaskID, in: events))
        let runningProjection = CoworkProjection.build(from: Array(events.prefix(through: runningIndex)))
        XCTAssertTrue(runningProjection.runningTasks.contains { $0.id == macOSTaskID })

        let finalProjection = CoworkProjection.build(from: events)
        XCTAssertEqual(Set(finalProjection.agentRoster.keys), Set([main, macOS, iOS]))
        XCTAssertEqual(Set(finalProjection.completedTasks.map(\.id)), Set([macOSTaskID, iOSTaskID]))
        XCTAssertEqual(finalProjection.mailboxes[macOS]?.completedTasks, [macOSTaskID])
        XCTAssertEqual(finalProjection.mailboxes[iOS]?.completedTasks, [iOSTaskID])
        XCTAssertFalse(finalProjection.workspaceLeases.isEmpty)
        XCTAssertFalse(finalProjection.capabilityLeases.isEmpty)
        XCTAssertTrue(finalProjection.completedTasks.contains { $0.result?.contains("macOS Swift count: 2") == true })
        XCTAssertTrue(finalProjection.completedTasks.contains { $0.result?.contains("iOS Swift count: 3") == true })

        for taskID in [macOSTaskID, iOSTaskID] {
            let created = try XCTUnwrap(firstIndex(of: .taskCreated, taskID: taskID, in: events))
            let queued = try XCTUnwrap(firstIndex(of: .taskQueued, taskID: taskID, in: events))
            let started = try XCTUnwrap(firstIndex(of: .taskStarted, taskID: taskID, in: events))
            let completed = try XCTUnwrap(firstIndex(of: .taskCompleted, taskID: taskID, in: events))
            XCTAssertLessThan(created, queued)
            XCTAssertLessThan(queued, started)
            XCTAssertLessThan(started, completed)
            let graphStatus = await orch.taskGraphNode(taskID)?.status
            XCTAssertEqual(graphStatus, .completed)
        }
    }

    func testWorkerCannotNestedSpawnOrDirectlyDelegateEvenIfModelAttemptsTools() async throws {
        let fixture = try makeCounterFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let log = try e2eLog()
        let worker = AgentID(rawValue: "worker")
        let workerProvider = E2EProvider([
            [.toolCalls([
                ToolCall(id: "delegate", name: "delegate_task", arguments: jsonObject([
                    "to": "main",
                    "objective": "try to delegate back",
                ])),
                ToolCall(id: "spawn", name: "spawn_agent", arguments: jsonObject([
                    "name": "nested",
                    "path": fixture.root.path,
                ])),
            ]), .done(finishReason: "tool_calls")],
            [.textDelta("worker stopped after denied tool surface"), .done(finishReason: "stop")],
        ])
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            agent.name == worker ? workerProvider : E2EProvider(text: "main")
        }
        let mainAttached = await orch.attach(Agent(name: main, workspaceRoot: fixture.root,
                                                   model: ModelID(rawValue: "m"), profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orch.attach(Agent(name: worker, workspaceRoot: fixture.macOSRoot,
                                                     model: ModelID(rawValue: "m"), profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)
        let rootTaskIDOptional = await orch.createRootTask(assignee: main, objective: "Root task.")
        let rootTaskID = try XCTUnwrap(rootTaskIDOptional)
        let queued = await orch.enqueueDelegatedTask(from: main, to: worker.rawValue,
                                                     objective: "Run worker task only.",
                                                     parentTaskID: rootTaskID)
        let taskID = try XCTUnwrap(queued.taskID)

        await orch.runSchedulerUntilIdle()

        let request = try XCTUnwrap(workerProvider.requests.first)
        assertWorkerToolSurface(request)
        let prompt = try XCTUnwrap(request.messages.first?.content)
        XCTAssertTrue(prompt.contains("You are executing the assigned task as a worker agent."))
        XCTAssertFalse(prompt.contains("You may also act as a COORDINATOR"))
        XCTAssertFalse(prompt.contains("spawn_agent"))
        XCTAssertFalse(prompt.contains("delegate_task"))

        let events = await log.replay()
        let toolResults = events.compactMap { envelope -> ToolResultPayload? in
            if case .toolResult(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertTrue(toolResults.contains { $0.observation.hasPrefix("unknown tool: delegate_task") })
        XCTAssertTrue(toolResults.contains { $0.observation.hasPrefix("unknown tool: spawn_agent") })
        XCTAssertFalse(events.contains { if case .agentSpawned = $0.event { return true } else { return false } })
        let graphStatus = await orch.taskGraphNode(taskID)?.status
        let queuedCount = await orch.queuedTasks().count
        XCTAssertEqual(graphStatus, .completed)
        XCTAssertEqual(queuedCount, 0)
    }

    func testSelfCallsAreRejectedWithoutSchedulingOrAgentLoopExecution() async throws {
        let fixture = try makeCounterFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let log = try e2eLog()
        let worker = AgentID(rawValue: "worker")
        let workerProvider = E2EProvider(text: "must not run")
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            agent.name == worker ? workerProvider : E2EProvider(text: "main")
        }
        let mainAttached = await orch.attach(Agent(name: main, workspaceRoot: fixture.root,
                                                   model: ModelID(rawValue: "m"), profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orch.attach(Agent(name: worker, workspaceRoot: fixture.macOSRoot,
                                                     model: ModelID(rawValue: "m"), profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)

        let send = await orch.sendMessage(from: worker, to: worker.rawValue, content: "self")
        let request = await orch.requestInformation(from: worker, to: worker.rawValue, question: "self")
        let ask = await orch.enqueueAsk(from: worker, to: worker.rawValue, question: "self", parentTaskID: nil)
        let delegated = await orch.enqueueDelegatedTask(from: worker, to: worker.rawValue, objective: "self task")

        XCTAssertEqual(send, "error: agent cannot message itself")
        XCTAssertEqual(request, "error: agent cannot request information from itself")
        XCTAssertNil(ask.taskID)
        XCTAssertEqual(ask.message, "error: agent cannot ask itself")
        XCTAssertNil(delegated.taskID)
        XCTAssertEqual(delegated.message, "error: agent cannot delegate to itself")
        let queuedTasks = await orch.queuedTasks()
        XCTAssertTrue(queuedTasks.isEmpty)
        XCTAssertTrue(workerProvider.requests.isEmpty)

        let events = await log.replay()
        XCTAssertTrue(events.contains {
            if case .error(let payload) = $0.event { return payload.code == "agent_self_call" }
            return false
        })
        XCTAssertFalse(events.contains { if case .taskCreated = $0.event { return true } else { return false } })
    }

    private func assertWorkerToolSurface(_ request: AgentRequest,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) {
        let tools = Set(request.tools.map(\.name))
        XCTAssertTrue(tools.contains("read_file"), file: file, line: line)
        XCTAssertTrue(tools.contains("read_pdf"), file: file, line: line)
        XCTAssertTrue(tools.contains("list_files"), file: file, line: line)
        XCTAssertTrue(tools.contains("search_text"), file: file, line: line)
        XCTAssertFalse(tools.contains("request_delegation"), file: file, line: line)
        XCTAssertTrue(tools.contains("reply_message"), file: file, line: line)
        XCTAssertFalse(tools.contains("edit_pdf_pages"), file: file, line: line)
        XCTAssertFalse(tools.contains("compile_latex"), file: file, line: line)
        XCTAssertFalse(tools.contains("generate_image"), file: file, line: line)
        XCTAssertFalse(tools.contains("edit_image"), file: file, line: line)
        XCTAssertFalse(tools.contains("web_fetch"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_diagnostics"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_profiles"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_profile_delete"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_history"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_navigate"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_snapshot"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_handoff"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_reload"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_back"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_forward"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_click"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_type"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_submit"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_select_option"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_press_key"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_scroll"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_wait"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_screenshot"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_upload_file"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_download"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_downloads"), file: file, line: line)
        XCTAssertFalse(tools.contains("browser_search"), file: file, line: line)
        XCTAssertFalse(tools.contains("spawn_agent"), file: file, line: line)
        XCTAssertFalse(tools.contains("remove_agent"), file: file, line: line)
        XCTAssertFalse(tools.contains("list_agents"), file: file, line: line)
        XCTAssertFalse(tools.contains("ask_agent"), file: file, line: line)
        XCTAssertFalse(tools.contains("delegate_task"), file: file, line: line)
    }
}
