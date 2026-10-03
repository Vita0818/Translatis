import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
@testable import IntatisCowork

private final class SemanticProvider: ToolCallingProvider, @unchecked Sendable {
    private let chunks: [AgentChunk]

    init(_ chunks: [AgentChunk] = [.textDelta("semantic result"), .done(finishReason: "stop")]) {
        self.chunks = chunks
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private func semanticLog(_ suffix: String = UUID().uuidString) throws -> EventLog {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-semantic-\(suffix)", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    return try EventLog(session: SessionID(rawValue: "semantic"), fileURL: url)
}

private func semanticWorkspace() throws -> URL {
    let ws = FileManager.default.temporaryDirectory
        .appendingPathComponent("semantic-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    return ws
}

final class CoworkSemanticEventTests: XCTestCase {
    private let encoder = Envelope.makeEncoder()
    private let decoder = Envelope.makeDecoder()

    func testTaskCreatedCodableRoundTripWithMetadata() throws {
        let contract = TaskContract(
            id: TaskID(rawValue: "task_semantic"),
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "worker"),
            objective: "Inspect the task.",
            roleHint: "inspector",
            expectedDeliverable: "summary")
        let metadata = CoworkEventMetadata(
            taskID: contract.id,
            rootTaskID: TaskID(rawValue: "task_root"),
            sender: AgentID(rawValue: "main"),
            recipient: AgentID(rawValue: "worker"),
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "worker"),
            scope: .task,
            visibility: .task,
            createdAt: Date(timeIntervalSince1970: 1))
        let envelope = Envelope(seq: 1, ts: Date(timeIntervalSince1970: 2),
                                session: SessionID(rawValue: "sess_semantic"),
                                event: .taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)))

        let decoded = try decoder.decode(Envelope.self, from: try encoder.encode(envelope))

        XCTAssertEqual(decoded, envelope)
    }

    func testDuplicateDelegationPreflightWritesNoRejectionEvent() async throws {
        let log = try semanticLog()
        let main = AgentID(rawValue: "main")
        let worker = AgentID(rawValue: "worker")
        let wsMain = try semanticWorkspace()
        let wsWorker = try semanticWorkspace()
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { _ in SemanticProvider() }
        let mainAttached = await orch.attach(Agent(name: main, workspaceRoot: wsMain, model: ModelID(rawValue: "m"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orch.attach(Agent(name: worker, workspaceRoot: wsWorker, model: ModelID(rawValue: "m"),
                                                     profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)

        let admitted = await orch.enqueueDelegatedTask(
            from: main,
            to: worker.rawValue,
            objective: "Duplicate me.")
        let rejectedResult = await orch.enqueueDelegatedTask(
            from: main,
            to: worker.rawValue,
            objective: "duplicate me.")

        let events = await log.replay()
        let rejected = events.compactMap {
            if case .delegationRejected(let payload) = $0.event { return payload }
            return nil
        }
        let delegated = events.filter {
            if case .taskDelegated = $0.event { return true }
            return false
        }
        XCTAssertNotNil(admitted.taskID)
        XCTAssertNil(rejectedResult.taskID)
        XCTAssertFalse(rejectedResult.message.isEmpty)
        XCTAssertTrue(rejected.isEmpty, "preflight rejection must not append an audit fact")
        XCTAssertEqual(delegated.count, 1)
    }

    func testAgentMessageEventContainsSenderRecipientAndTaskMetadata() async throws {
        let log = try semanticLog()
        let main = AgentID(rawValue: "main")
        let worker = AgentID(rawValue: "worker")
        let wsMain = try semanticWorkspace()
        let wsWorker = try semanticWorkspace()
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { _ in SemanticProvider() }
        let mainAttached = await orch.attach(Agent(name: main, workspaceRoot: wsMain, model: ModelID(rawValue: "m"),
                                                   profile: .reviewed,
                                                   coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orch.attach(Agent(name: worker, workspaceRoot: wsWorker, model: ModelID(rawValue: "m"),
                                                     profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)
        let rootTaskIDOptional = await orch.createRootTask(assignee: main, objective: "Root")
        let rootTaskID = try XCTUnwrap(rootTaskIDOptional)

        _ = await orch.sendMessage(from: main, to: worker.rawValue, content: "hello", taskID: rootTaskID)

        let messages = await log.replay().compactMap {
            if case .agentMessage(let payload) = $0.event { return payload }
            return nil
        }
        let message = try XCTUnwrap(messages.first)
        XCTAssertEqual(message.from, main)
        XCTAssertEqual(message.to, worker)
        XCTAssertEqual(message.taskID, rootTaskID)
    }

    func testMacOSIOSCounterScenarioProducesSemanticTaskEventsInOrder() async throws {
        let log = try semanticLog()
        let main = AgentID(rawValue: "main")
        let macos = AgentID(rawValue: "macos-counter")
        let ios = AgentID(rawValue: "ios-counter")
        let wsMain = try semanticWorkspace()
        let wsMacos = try semanticWorkspace()
        let wsIOS = try semanticWorkspace()
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsMacos)
            try? FileManager.default.removeItem(at: wsIOS)
        }
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            if agent.name == macos { return SemanticProvider([.textDelta("macOS count"), .done(finishReason: "stop")]) }
            if agent.name == ios { return SemanticProvider([.textDelta("iOS count"), .done(finishReason: "stop")]) }
            return SemanticProvider([.textDelta("main"), .done(finishReason: "stop")])
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
        let rootTaskIDOptional = await orch.createRootTask(assignee: main, objective: "Count Swift files.")
        let rootTaskID = try XCTUnwrap(rootTaskIDOptional)
        let macosQueued = await orch.enqueueDelegatedTask(from: main, to: macos.rawValue,
                                                          objective: "Count macOS Swift files only.",
                                                          parentTaskID: rootTaskID)
        let iosQueued = await orch.enqueueDelegatedTask(from: main, to: ios.rawValue,
                                                        objective: "Count iOS Swift files only.",
                                                        parentTaskID: rootTaskID)
        XCTAssertNotNil(macosQueued.taskID)
        XCTAssertNotNil(iosQueued.taskID)

        await orch.runSchedulerUntilIdle()

        let types = await log.replay().map(\.event.type)
        XCTAssertTrue(types.contains(.delegationApproved))
        XCTAssertTrue(types.contains(.taskCreated))
        XCTAssertTrue(types.contains(.taskAssigned))
        XCTAssertTrue(types.contains(.taskQueued))
        XCTAssertTrue(types.contains(.taskStarted))
        XCTAssertTrue(types.contains(.taskCompleted))
        let firstCreated = try XCTUnwrap(types.firstIndex(of: .taskCreated))
        let firstQueued = try XCTUnwrap(types.firstIndex(of: .taskQueued))
        let firstStarted = try XCTUnwrap(types.firstIndex(of: .taskStarted))
        XCTAssertLessThan(firstCreated, firstQueued)
        XCTAssertLessThan(firstQueued, firstStarted)
    }
}
