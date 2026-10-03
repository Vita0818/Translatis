import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
@testable import IntatisCowork

private final class CorrelatedConversationProvider: ToolCallingProvider, @unchecked Sendable {
    enum Role { case main, worker }

    private let role: Role
    private let lock = NSLock()
    private var mainReplyReceipts = 0
    private var captured: [AgentRequest] = []

    init(role: Role) {
        self.role = role
    }

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        captured.append(request)
        let chunks = response(for: request)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    private func response(for request: AgentRequest) -> [AgentChunk] {
        if request.messages.last?.role == .tool {
            return [.textDelta("correlation handled"), .done(finishReason: "stop")]
        }
        let context = request.messages.compactMap(\.content).joined(separator: "\n")
        switch role {
        case .main:
            if context.contains("start correlated conversation"),
               !context.contains("Kind:\n| information_replied") {
                return toolCall(
                    id: "request-round-1",
                    name: "request_information",
                    object: [
                        "to": "worker",
                        "question": "What is the first fact?",
                    ])
            }
            if context.contains("Kind:\n| information_replied"),
               let replyID = Self.frozenMessageID(in: context) {
                mainReplyReceipts += 1
                if mainReplyReceipts == 1 {
                    return toolCall(
                        id: "request-round-2",
                        name: "request_information",
                        object: [
                            "to": "worker",
                            "question": "What is the second fact?",
                            "based_on": replyID,
                        ])
                }
                return [.textDelta("both facts received"), .done(finishReason: "stop")]
            }
            return [.textDelta("main done"), .done(finishReason: "stop")]

        case .worker:
            guard context.contains("Kind:\n| information_requested"),
                  let requestID = Self.frozenMessageID(in: context) else {
                return [.textDelta("worker done"), .done(finishReason: "stop")]
            }
            return toolCall(
                id: "reply-\(requestID)",
                name: "reply_message",
                object: [
                    "to": "main",
                    "content": context.contains("second fact") ? "fact two" : "fact one",
                    "inReplyTo": requestID,
                ])
        }
    }

    private func toolCall(
        id: String,
        name: String,
        object: [String: String]
    ) -> [AgentChunk] {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return [
            .toolCalls([ToolCall(
                id: id,
                name: name,
                arguments: String(decoding: data, as: UTF8.self))]),
            .done(finishReason: "tool_calls"),
        ]
    }

    private static func frozenMessageID(in context: String) -> String? {
        guard let range = context.range(of: "Message ID:\n| ") else { return nil }
        let suffix = context[range.upperBound...]
        let rawValue = String(suffix.prefix { $0 != "\n" })
        return rawValue.isEmpty ? nil : rawValue
    }
}

private final class DuplicateReplyScenarioProvider: ToolCallingProvider, @unchecked Sendable {
    enum Role { case main, worker }

    private let role: Role
    private let lock = NSLock()
    private var workerPhase = 0
    private var requestID: String?
    private var captured: [AgentRequest] = []

    init(role: Role) {
        self.role = role
    }

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        captured.append(request)
        let chunks = response(for: request)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    private func response(for request: AgentRequest) -> [AgentChunk] {
        let context = request.messages.compactMap(\.content).joined(separator: "\n")
        switch role {
        case .main:
            if context.contains("Kind:\n| information_replied") {
                return [.textDelta("receipt observed"), .done(finishReason: "stop")]
            }
            if request.messages.last?.role == .tool {
                return [.textDelta("request issued"), .done(finishReason: "stop")]
            }
            return toolCall(
                id: "single-request",
                name: "request_information",
                object: [
                    "to": "worker",
                    "question": "give one terminal answer",
                ])

        case .worker:
            if requestID == nil {
                requestID = Self.frozenMessageID(in: context)
            }
            guard let requestID else {
                return [.textDelta("missing correlation"), .done(finishReason: "stop")]
            }
            defer { workerPhase += 1 }
            switch workerPhase {
            case 0:
                return replyToolCall(
                    id: "first-reply",
                    requestID: requestID,
                    content: "terminal answer")
            case 1:
                return replyToolCall(
                    id: "exact-duplicate-reply",
                    requestID: requestID,
                    content: "terminal answer")
            case 2:
                return replyToolCall(
                    id: "conflicting-reply",
                    requestID: requestID,
                    content: "different answer")
            default:
                return [.textDelta("reply settled once"), .done(finishReason: "stop")]
            }
        }
    }

    private func replyToolCall(
        id: String,
        requestID: String,
        content: String
    ) -> [AgentChunk] {
        toolCall(
            id: id,
            name: "reply_message",
            object: [
                "to": "main",
                "content": content,
                "inReplyTo": requestID,
            ])
    }

    private func toolCall(
        id: String,
        name: String,
        object: [String: String]
    ) -> [AgentChunk] {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return [
            .toolCalls([ToolCall(
                id: id,
                name: name,
                arguments: String(decoding: data, as: UTF8.self))]),
            .done(finishReason: "tool_calls"),
        ]
    }

    private static func frozenMessageID(in context: String) -> String? {
        guard let range = context.range(of: "Message ID:\n| ") else { return nil }
        let suffix = context[range.upperBound...]
        let rawValue = String(suffix.prefix { $0 != "\n" })
        return rawValue.isEmpty ? nil : rawValue
    }
}

private final class AcknowledgementAttemptProvider: ToolCallingProvider, @unchecked Sendable {
    enum Role { case main, worker }

    private let role: Role
    private let lock = NSLock()
    private var captured: [AgentRequest] = []

    init(role: Role) {
        self.role = role
    }

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        captured.append(request)
        let response = response(for: request)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            response.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    private func response(for request: AgentRequest) -> [AgentChunk] {
        if request.messages.last?.role == .tool {
            return [.textDelta("receipt consumed"), .done(finishReason: "stop")]
        }
        let context = request.messages.compactMap(\.content).joined(separator: "\n")
        switch role {
        case .main:
            if context.contains("Kind:\n| information_replied"),
               let replyID = Self.frozenMessageID(in: context) {
                // Deliberately emulate the incident's bad model behavior. The
                // receipt invocation must not advertise or execute this tool.
                return toolCall(
                    id: "illegal-ack",
                    name: "reply_message",
                    object: [
                        "to": "worker",
                        "content": "received; no further action",
                        "inReplyTo": replyID,
                    ])
            }
            return toolCall(
                id: "ack-scenario-request",
                name: "request_information",
                object: [
                    "to": "worker",
                    "question": "send the candidate result",
                ])

        case .worker:
            guard context.contains("Kind:\n| information_requested"),
                  let requestID = Self.frozenMessageID(in: context) else {
                return [.textDelta("worker idle"), .done(finishReason: "stop")]
            }
            return toolCall(
                id: "ack-scenario-reply",
                name: "reply_message",
                object: [
                    "to": "main",
                    "content": "candidate result",
                    "inReplyTo": requestID,
                ])
        }
    }

    private func toolCall(
        id: String,
        name: String,
        object: [String: String]
    ) -> [AgentChunk] {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return [
            .toolCalls([ToolCall(
                id: id,
                name: name,
                arguments: String(decoding: data, as: UTF8.self))]),
            .done(finishReason: "tool_calls"),
        ]
    }

    private static func frozenMessageID(in context: String) -> String? {
        guard let range = context.range(of: "Message ID:\n| ") else { return nil }
        let suffix = context[range.upperBound...]
        let rawValue = String(suffix.prefix { $0 != "\n" })
        return rawValue.isEmpty ? nil : rawValue
    }
}

final class MailboxCorrelationTests: XCTestCase {
    func testReplyReceiptHasNoReplyToolButCanOpenExplicitFollowUpCorrelation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-mailbox-correlation-\(UUID().uuidString)", isDirectory: true)
        let mainWorkspace = directory.appendingPathComponent("main", isDirectory: true)
        let workerWorkspace = directory.appendingPathComponent("worker", isDirectory: true)
        try FileManager.default.createDirectory(at: mainWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workerWorkspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = SessionID(rawValue: "mailbox-correlation")
        let log = try EventLog(
            session: sessionID,
            fileURL: directory.appendingPathComponent("events.jsonl"))
        let mainProvider = CorrelatedConversationProvider(role: .main)
        let workerProvider = CorrelatedConversationProvider(role: .worker)
        let workerID = AgentID(rawValue: "worker")
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.allow)) { agent in
                agent.name == workerID ? workerProvider : mainProvider
            }
        let mainAttached = await orchestrator.attach(Agent(
            name: Orchestrator.mainAgentID,
            workspaceRoot: mainWorkspace,
            model: ModelID(rawValue: "model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orchestrator.attach(Agent(
            name: workerID,
            workspaceRoot: workerWorkspace,
            model: ModelID(rawValue: "model"),
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)

        let runID = ContinuationRunID(rawValue: "run-mailbox-correlation")
        let rootResult = await orchestrator.send(
            "start correlated conversation",
            to: Orchestrator.mainAgentID,
            continuationRunID: runID)
        XCTAssertEqual(rootResult, .sent)
        await orchestrator.runSchedulerUntilIdle()

        let events = await log.replay()
        let informationRequests = events.compactMap { envelope -> InformationRequestedPayload? in
            guard case .informationRequested(let payload) = envelope.event else { return nil }
            return payload
        }
        let informationReplies = events.compactMap { envelope -> InformationRepliedPayload? in
            guard case .informationReplied(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(informationRequests.count, 2)
        XCTAssertEqual(informationReplies.count, 2, "reply receipts must not generate acknowledgment replies")
        guard informationRequests.count == 2, informationReplies.count == 2 else { return }
        XCTAssertNotEqual(informationRequests[0].requestID, informationRequests[1].requestID)
        XCTAssertEqual(informationRequests[0].conversationID, informationRequests[0].requestID)
        XCTAssertEqual(informationRequests[1].conversationID, informationRequests[0].conversationID)
        XCTAssertEqual(informationRequests[1].basedOn, informationReplies[0].replyID)
        XCTAssertEqual(informationReplies[0].inReplyTo, informationRequests[0].requestID)
        XCTAssertEqual(informationReplies[1].inReplyTo, informationRequests[1].requestID)

        let receiptRequests = mainProvider.requests.filter { request in
            request.messages.compactMap(\.content).joined(separator: "\n")
                .contains("Kind:\n| information_replied")
                && request.messages.last?.role != .tool
        }
        XCTAssertEqual(receiptRequests.count, 2)
        for receipt in receiptRequests {
            let tools = Set(receipt.tools.map(\.name))
            XCTAssertFalse(tools.contains("reply_message"))
            XCTAssertTrue(tools.contains("request_information"))
        }
    }

    func testInformationRequestAcceptsOneTerminalReplyAndRejectsConflict() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-mailbox-terminal-\(UUID().uuidString)", isDirectory: true)
        let mainWorkspace = directory.appendingPathComponent("main", isDirectory: true)
        let workerWorkspace = directory.appendingPathComponent("worker", isDirectory: true)
        try FileManager.default.createDirectory(at: mainWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workerWorkspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = try EventLog(
            session: SessionID(rawValue: "mailbox-terminal"),
            fileURL: directory.appendingPathComponent("events.jsonl"))
        let mainProvider = DuplicateReplyScenarioProvider(role: .main)
        let workerProvider = DuplicateReplyScenarioProvider(role: .worker)
        let workerID = AgentID(rawValue: "worker")
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.allow)) { agent in
                agent.name == workerID ? workerProvider : mainProvider
            }
        let mainAttached = await orchestrator.attach(Agent(
            name: Orchestrator.mainAgentID,
            workspaceRoot: mainWorkspace,
            model: ModelID(rawValue: "model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orchestrator.attach(Agent(
            name: workerID,
            workspaceRoot: workerWorkspace,
            model: ModelID(rawValue: "model"),
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)

        let result = await orchestrator.send(
            "test one terminal information reply",
            to: Orchestrator.mainAgentID,
            continuationRunID: ContinuationRunID(rawValue: "run-terminal-reply"))
        XCTAssertEqual(result, .sent)
        await orchestrator.runSchedulerUntilIdle()

        let events = await log.replay()
        XCTAssertEqual(events.filter {
            if case .informationRequested = $0.event { return true }
            return false
        }.count, 1)
        XCTAssertEqual(events.filter {
            if case .informationReplied = $0.event { return true }
            return false
        }.count, 1)
        let workerContexts = workerProvider.requests.map {
            $0.messages.compactMap(\.content).joined(separator: "\n")
        }
        XCTAssertTrue(workerContexts.contains { $0.contains("idempotent") })
        let conflict = try XCTUnwrap(events.compactMap { envelope -> ToolResultPayload? in
            guard case .toolResult(let payload) = envelope.event,
                  payload.toolCallId == "conflicting-reply" else { return nil }
            return payload
        }.last)
        XCTAssertTrue(conflict.observation.contains("terminal reply"), conflict.observation)
    }

    func testReplyReceiptAcknowledgementAttemptCannotCreateAnotherMessageOrWake() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-mailbox-no-ack-\(UUID().uuidString)", isDirectory: true)
        let mainWorkspace = directory.appendingPathComponent("main", isDirectory: true)
        let workerWorkspace = directory.appendingPathComponent("worker", isDirectory: true)
        try FileManager.default.createDirectory(at: mainWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workerWorkspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = try EventLog(
            session: SessionID(rawValue: "mailbox-no-ack"),
            fileURL: directory.appendingPathComponent("events.jsonl"))
        let mainProvider = AcknowledgementAttemptProvider(role: .main)
        let workerProvider = AcknowledgementAttemptProvider(role: .worker)
        let workerID = AgentID(rawValue: "worker")
        let orchestrator = Orchestrator(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.allow)) { agent in
                agent.name == workerID ? workerProvider : mainProvider
            }
        let mainAttached = await orchestrator.attach(Agent(
            name: Orchestrator.mainAgentID,
            workspaceRoot: mainWorkspace,
            model: ModelID(rawValue: "model"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orchestrator.attach(Agent(
            name: workerID,
            workspaceRoot: workerWorkspace,
            model: ModelID(rawValue: "model"),
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)

        let rootResult = await orchestrator.send(
            "reproduce acknowledgement loop",
            to: Orchestrator.mainAgentID,
            continuationRunID: ContinuationRunID(rawValue: "run-no-ack"))
        XCTAssertEqual(rootResult, .sent)
        await orchestrator.runSchedulerUntilIdle()

        let events = await log.replay()
        XCTAssertEqual(events.filter {
            if case .informationRequested = $0.event { return true }
            return false
        }.count, 1)
        XCTAssertEqual(events.filter {
            if case .informationReplied = $0.event { return true }
            return false
        }.count, 1)
        XCTAssertEqual(events.compactMap { envelope -> TaskContract? in
            guard case .taskCreated(let payload) = envelope.event,
                  payload.contract.kind == .mailboxDelivery else { return nil }
            return payload.contract
        }.count, 2, "request and reply receipt each wake once; the attempted ACK must not wake again")

        let receiptRequest = try XCTUnwrap(mainProvider.requests.first { request in
            request.messages.compactMap(\.content).joined(separator: "\n")
                .contains("Kind:\n| information_replied")
                && request.messages.last?.role != .tool
        })
        XCTAssertFalse(receiptRequest.tools.map(\.name).contains("reply_message"))
        let rejectedACK = try XCTUnwrap(events.compactMap { envelope -> ToolResultPayload? in
            guard case .toolResult(let payload) = envelope.event,
                  payload.toolCallId == "illegal-ack" else { return nil }
            return payload
        }.last)
        XCTAssertTrue(rejectedACK.observation.contains("unknown tool"), rejectedACK.observation)
    }

    func testReplyValidationRejectsMissingForgedCrossAgentAndCrossRunCorrelation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-mailbox-invalid-correlation-\(UUID().uuidString)", isDirectory: true)
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = try EventLog(
            session: SessionID(rawValue: "mailbox-invalid-correlation"),
            fileURL: directory.appendingPathComponent("events.jsonl"))
        let main = Orchestrator.mainAgentID
        let worker = AgentID(rawValue: "worker")
        let intruder = AgentID(rawValue: "intruder")
        let requestID = MessageID(rawValue: "msg_cross_run_request")
        let forgedID = MessageID(rawValue: "msg_forged_request")
        let originTaskID = TaskID(rawValue: "task_origin_run_a")
        let mailboxTaskID = TaskID(rawValue: "task_mailbox_run_b")
        let runA = ContinuationRunID(rawValue: "run_a")
        let runB = ContinuationRunID(rawValue: "run_b")
        let goalID = GoalID(rawValue: "goal_shared")
        let origin = TaskContract(
            id: originTaskID,
            kind: .root,
            issuer: nil,
            assignee: main,
            continuationRunID: runA,
            goalID: goalID,
            objective: "origin request",
            roleHint: "root",
            expectedDeliverable: "request")
        let capabilityLease = CapabilityLease(
            id: CapabilityLeaseID(rawValue: "clease_mailbox_run_b"),
            taskID: mailboxTaskID,
            tools: [.replyMessage],
            communication: .replyOnly,
            delegation: .none,
            expiresAtTaskCompletion: true)
        let workspaceLease = WorkspaceLease(
            id: WorkspaceLeaseID(rawValue: "wlease_mailbox_run_b"),
            workspaceID: WorkspaceID(rawValue: "workspace_mailbox_run_b"),
            taskID: mailboxTaskID,
            rootPath: workspace.path,
            access: .readOnly,
            expiresAtTaskCompletion: true)
        let mailbox = TaskContract(
            id: mailboxTaskID,
            kind: .mailboxDelivery,
            issuer: main,
            assignee: worker,
            continuationRunID: runB,
            goalID: goalID,
            objective: "reply only to a valid frozen request",
            roleHint: "mailbox responder",
            expectedDeliverable: "one correlated reply",
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            mailboxMessageIDs: [requestID, forgedID],
            replyMode: TaskReplyMode.none,
            maxAttempts: 3)
        try await log.append([
            .agentAttached(.init(
                agent: main,
                path: workspace.path,
                model: ModelID(rawValue: "m"),
                profile: PermissionProfile.reviewed.rawValue)),
            .agentAttached(.init(
                agent: worker,
                path: workspace.path,
                model: ModelID(rawValue: "m"),
                profile: PermissionProfile.reviewed.rawValue)),
            .agentAttached(.init(
                agent: intruder,
                path: workspace.path,
                model: ModelID(rawValue: "m"),
                profile: PermissionProfile.reviewed.rawValue)),
            .taskCreated(.init(contract: origin)),
            .informationRequested(.init(
                requestID: requestID,
                conversationID: requestID,
                from: main,
                to: worker,
                question: "request from run A",
                mediated: true,
                taskID: originTaskID)),
            .capabilityLeaseCreated(.init(agent: worker, lease: capabilityLease)),
            .workspaceLeaseGranted(.init(agent: worker, lease: workspaceLease)),
            .taskCreated(.init(contract: mailbox)),
            .taskAssigned(.init(contract: mailbox)),
            .taskQueued(.init(
                contract: mailbox,
                rootTaskID: mailboxTaskID,
                issuer: main,
                assignee: worker,
                hopCount: 0,
                visitedAgents: [worker],
                attempt: 1,
                reason: "invalid-correlation fixture")),
        ])

        let orchestrator = Orchestrator(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.allow)) { _ in
                RunControlScriptedProviderForMailboxValidation()
            }
        await orchestrator.restore(from: CoworkProjection.build(from: await log.replay()))

        let missing = await orchestrator.replyMessage(
            from: worker,
            to: main.rawValue,
            content: "missing",
            inReplyTo: nil,
            taskID: mailboxTaskID)
        XCTAssertTrue(missing.contains("inReplyTo is required"), missing)

        let forged = await orchestrator.replyMessage(
            from: worker,
            to: main.rawValue,
            content: "forged",
            inReplyTo: forgedID.rawValue,
            taskID: mailboxTaskID)
        XCTAssertTrue(forged.contains("not an information request"), forged)

        let crossRun = await orchestrator.replyMessage(
            from: worker,
            to: main.rawValue,
            content: "cross run",
            inReplyTo: requestID.rawValue,
            taskID: mailboxTaskID)
        XCTAssertTrue(crossRun.contains("exact target and run scope"), crossRun)

        let crossAgent = await orchestrator.replyMessage(
            from: worker,
            to: intruder.rawValue,
            content: "wrong target",
            inReplyTo: requestID.rawValue,
            taskID: mailboxTaskID)
        XCTAssertTrue(crossAgent.contains("assigning agent"), crossAgent)
        let finalEvents = await log.replay()
        XCTAssertFalse(finalEvents.contains {
            if case .informationReplied = $0.event { return true }
            return false
        })
    }
}

private struct RunControlScriptedProviderForMailboxValidation: ToolCallingProvider {
    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("unused"))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }
}
