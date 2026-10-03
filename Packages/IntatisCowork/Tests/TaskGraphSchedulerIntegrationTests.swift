import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
@testable import IntatisCowork

private final class GraphSchedulerProvider: ToolCallingProvider, @unchecked Sendable {
    private let chunks: [AgentChunk]
    private let lock = NSLock()
    private var capturedRequests: [AgentRequest] = []

    init(_ chunks: [AgentChunk] = [.textDelta("graph result"), .done(finishReason: "stop")]) {
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
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private func graphSchedulerLog() throws -> EventLog {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-taskgraph-scheduler-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    return try EventLog(session: SessionID(rawValue: "taskgraph_scheduler"), fileURL: url)
}

private func graphSchedulerWorkspace() throws -> URL {
    let ws = FileManager.default.temporaryDirectory
        .appendingPathComponent("taskgraph-scheduler-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    return ws
}

final class TaskGraphSchedulerIntegrationTests: XCTestCase {
    private let main = AgentID(rawValue: "main")
    private let worker = AgentID(rawValue: "worker")

    private func makeOrchestrator(log: EventLog,
                                  policy: TaskGraphPolicy = .default,
                                  workerProvider: GraphSchedulerProvider = GraphSchedulerProvider()) async throws -> (Orchestrator, URL, URL) {
        let wsMain = try graphSchedulerWorkspace()
        let wsWorker = try graphSchedulerWorkspace()
        let worker = self.worker
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow),
                                taskGraphPolicy: policy) { agent in
            agent.name == worker ? workerProvider : GraphSchedulerProvider([.textDelta("main"), .done(finishReason: "stop")])
        }
        let mainAttached = await orch.attach(Agent(name: main, workspaceRoot: wsMain, model: ModelID(rawValue: "m"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orch.attach(Agent(name: worker, workspaceRoot: wsWorker, model: ModelID(rawValue: "m"),
                                                     profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)
        return (orch, wsMain, wsWorker)
    }

    func testSchedulerOnlyEnqueuesAfterTaskGraphValidation() async throws {
        let log = try graphSchedulerLog()
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }

        let first = await orch.enqueueDelegatedTask(from: main, to: worker.rawValue, objective: "Inspect workspace.")
        let duplicate = await orch.enqueueDelegatedTask(from: main, to: worker.rawValue, objective: " inspect   workspace. ")

        XCTAssertNotNil(first.taskID)
        XCTAssertNil(duplicate.taskID)
        XCTAssertTrue(duplicate.message.hasPrefix("error: duplicate task rejected"))
        let queued = await orch.queuedTasks()
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.contract.id, first.taskID)
        let graph = await orch.taskGraphSnapshot()
        XCTAssertEqual(graph.nodes.count, 1)
    }

    func testTaskStatusMovesQueuedRunningCompleted() async throws {
        let log = try graphSchedulerLog()
        let provider = GraphSchedulerProvider([.textDelta("completed result"), .done(finishReason: "stop")])
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log, workerProvider: provider)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }

        let queued = await orch.enqueueDelegatedTask(from: main, to: worker.rawValue, objective: "Run status task.")
        let taskID = try XCTUnwrap(queued.taskID)
        let queuedStatus = await orch.taskGraphNode(taskID)?.status
        XCTAssertEqual(queuedStatus, .queued)

        let ran = await orch.runNextScheduledTask()

        XCTAssertTrue(ran)
        let graphStatus = await orch.taskGraphNode(taskID)?.status
        let recordStatus = await orch.executionRecord(taskID: taskID)?.status
        XCTAssertEqual(graphStatus, .completed)
        XCTAssertEqual(recordStatus, .completed)
    }

    func testBusyAssigneeCannotBeDetachedBeforeQueuedTaskCompletes() async throws {
        let log = try graphSchedulerLog()
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }
        let queued = await orch.enqueueDelegatedTask(from: main, to: worker.rawValue, objective: "Will fail.")
        let taskID = try XCTUnwrap(queued.taskID)
        let detached = await orch.detach(worker)

        let ran = await orch.runNextScheduledTask()

        XCTAssertFalse(detached)
        XCTAssertTrue(ran)
        let graphStatus = await orch.taskGraphNode(taskID)?.status
        let recordStatus = await orch.executionRecord(taskID: taskID)?.status
        XCTAssertEqual(graphStatus, .completed)
        XCTAssertEqual(recordStatus, .completed)
        let events = await log.replay()
        XCTAssertTrue(events.contains {
            if case .error(let payload) = $0.event { return payload.code == "agent_busy" }
            return false
        })
        XCTAssertFalse(events.contains { if case .agentDetached = $0.event { return true } else { return false } })
    }

    func testMainCanDelegateMacOSAndIOSSiblingsUnderSameRoot() async throws {
        let log = try graphSchedulerLog()
        let macos = AgentID(rawValue: "macos-counter")
        let ios = AgentID(rawValue: "ios-counter")
        let wsMain = try graphSchedulerWorkspace()
        let wsMacos = try graphSchedulerWorkspace()
        let wsIOS = try graphSchedulerWorkspace()
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsMacos)
            try? FileManager.default.removeItem(at: wsIOS)
        }
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            if agent.name == macos { return GraphSchedulerProvider([.textDelta("macOS done"), .done(finishReason: "stop")]) }
            if agent.name == ios { return GraphSchedulerProvider([.textDelta("iOS done"), .done(finishReason: "stop")]) }
            return GraphSchedulerProvider([.textDelta("main"), .done(finishReason: "stop")])
        }
        let mainAttached = await orch.attach(Agent(name: main, workspaceRoot: wsMain, model: ModelID(rawValue: "m"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        let macosAttached = await orch.attach(Agent(name: macos, workspaceRoot: wsMacos, model: ModelID(rawValue: "m"),
                                                    profile: .reviewed))
        let iosAttached = await orch.attach(Agent(name: ios, workspaceRoot: wsIOS, model: ModelID(rawValue: "m"),
                                                  profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(macosAttached)
        XCTAssertTrue(iosAttached)
        let rootOptional = await orch.createRootTask(
            assignee: main,
            objective: "Count Swift files for macOS and iOS.",
            roleHint: "Swift count coordinator")
        let rootTaskID = try XCTUnwrap(rootOptional)

        let macosQueued = await orch.enqueueDelegatedTask(from: main, to: macos.rawValue,
                                                          objective: "Count macOS Swift files only.",
                                                          parentTaskID: rootTaskID)
        let iosQueued = await orch.enqueueDelegatedTask(from: main, to: ios.rawValue,
                                                        objective: "Count iOS Swift files only.",
                                                        parentTaskID: rootTaskID)

        let macosTaskID = try XCTUnwrap(macosQueued.taskID)
        let iosTaskID = try XCTUnwrap(iosQueued.taskID)
        let graph = await orch.taskGraphSnapshot()
        XCTAssertEqual(graph.node(macosTaskID)?.rootTaskID, rootTaskID)
        XCTAssertEqual(graph.node(iosTaskID)?.rootTaskID, rootTaskID)
        XCTAssertEqual(graph.edges.filter { $0.fromTaskID == rootTaskID && $0.kind == .delegates }.count, 2)
    }
}
