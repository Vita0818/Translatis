import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
@testable import IntatisAgentKernel

private final class SubmissionHistoryCapturingProvider: ToolCallingProvider, @unchecked Sendable {
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
            continuation.yield(.textDelta("current response"))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }
}

final class SubmittedIntentHistoryTests: XCTestCase {
    func testRetryHistoryKeepsEarlierCompletedTurnAndExcludesCurrentAndLaterSubmissions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "intatis-submission-history-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let log = try EventLog(
            session: SessionID(rawValue: "sess_submission_history"),
            fileURL: root.appendingPathComponent("events.jsonl"))
        let priorID = SubmissionID(rawValue: "sub_prior")
        let currentID = SubmissionID(rawValue: "sub_current")
        let laterID = SubmissionID(rawValue: "sub_later")

        try await log.append(.userMessage(UserMessagePayload(
            text: "prior submission",
            submissionID: priorID)))
        try await log.append(.userMessage(UserMessagePayload(
            text: "current submission",
            submissionID: currentID)))
        try await log.append(.userMessage(UserMessagePayload(
            text: "later queued submission",
            submissionID: laterID)))

        // The prior response may be appended after later submissions were
        // accepted. Logical submission order must still retain it.
        let priorMessageID = MessageID(rawValue: "msg_prior")
        try await log.append(.messageDelta(MessageDeltaPayload(
            messageId: priorMessageID,
            role: .agent,
            agent: AgentID(rawValue: "agent"),
            textDelta: "prior partial",
            submissionID: priorID)))
        try await log.append(.messageCompleted(MessageCompletedPayload(
            messageId: priorMessageID,
            role: .agent,
            agent: AgentID(rawValue: "agent"),
            text: "prior full response",
            submissionID: priorID)))

        // Output from an earlier failed attempt of the current submission and
        // output correlated with the later queued submission are both excluded.
        try await log.append(.messageCompleted(MessageCompletedPayload(
            messageId: MessageID(rawValue: "msg_current_stale"),
            role: .agent,
            agent: AgentID(rawValue: "agent"),
            text: "stale current response",
            submissionID: currentID)))
        try await log.append(.messageCompleted(MessageCompletedPayload(
            messageId: MessageID(rawValue: "msg_later"),
            role: .agent,
            agent: AgentID(rawValue: "agent"),
            text: "later response",
            submissionID: laterID)))

        let provider = SubmissionHistoryCapturingProvider()
        let loop = AgentLoop(
            log: log,
            provider: provider,
            registry: ToolRegistry([]),
            engine: PermissionEngine(),
            responder: FixedResponder(.deny),
            agent: Agent(
                name: AgentID(rawValue: "agent"),
                workspaceRoot: root,
                model: ModelID(rawValue: "test-model"),
                profile: .reviewed),
            allowsShell: false)

        let result = try await loop.send(
            "current submission",
            recordUserMessage: false,
            submissionID: currentID)

        XCTAssertEqual(result, "current response")
        let request = try XCTUnwrap(provider.requests.first)
        let conversation = request.messages
            .filter { $0.role != .system }
            .map { ($0.role, $0.content) }
        XCTAssertEqual(conversation.count, 3)
        XCTAssertEqual(conversation[0].0, .user)
        XCTAssertEqual(conversation[0].1, "prior submission")
        XCTAssertEqual(conversation[1].0, .assistant)
        XCTAssertEqual(conversation[1].1, "prior full response")
        XCTAssertEqual(conversation[2].0, .user)
        XCTAssertEqual(conversation[2].1, "current submission")
        XCTAssertFalse(request.messages.contains { $0.content == "stale current response" })
        XCTAssertFalse(request.messages.contains { $0.content == "later queued submission" })
        XCTAssertFalse(request.messages.contains { $0.content == "later response" })

        let canonicalUsers = await log.replay().compactMap { envelope -> UserMessagePayload? in
            guard case .userMessage(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(canonicalUsers.compactMap(\.submissionID), [priorID, currentID, laterID])
        XCTAssertEqual(canonicalUsers.filter { $0.submissionID == currentID }.count, 1)
    }

    func testCoworkRootHistoryMatchesCodexTurnOrderWithContextBundleAndReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "intatis-cowork-thread-history-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let log = try EventLog(
            session: SessionID(rawValue: "sess_cowork_thread_history"),
            fileURL: root.appendingPathComponent("events.jsonl"))
        let main = AgentID(rawValue: "main")
        let other = AgentID(rawValue: "other")
        let firstID = SubmissionID(rawValue: "sub_u1")
        let secondID = SubmissionID(rawValue: "sub_u2")
        let currentID = SubmissionID(rawValue: "sub_u3")
        let firstAnswer = "ROOT-ANSWER-ONE-SENTINEL"
        let secondAnswer = "ROOT-ANSWER-TWO-SENTINEL"

        func rootContract(_ id: String,
                          submissionID: SubmissionID,
                          objective: String) -> TaskContract {
            TaskContract(
                id: TaskID(rawValue: id),
                kind: .root,
                issuer: nil,
                assignee: main,
                submissionID: submissionID,
                objective: objective,
                roleHint: "root",
                expectedDeliverable: "answer")
        }

        let firstTask = rootContract("task_u1", submissionID: firstID, objective: "U1")
        let secondTask = rootContract("task_u2", submissionID: secondID, objective: "U2")
        let currentTask = rootContract("task_u3", submissionID: currentID, objective: "U3")

        // The outbox can accept U2 and U3 before A1/A2 are appended. Raw
        // persistence order is intentionally not conversation order.
        try await log.append(.userMessage(UserMessagePayload(
            text: "U1", to: main, submissionID: firstID)))
        try await log.append(.userMessage(UserMessagePayload(
            text: "U2", to: main, submissionID: secondID)))
        try await log.append(.userMessage(UserMessagePayload(
            text: "U3", to: main, submissionID: currentID)))
        try await log.append(.taskCreated(TaskCreatedPayload(contract: firstTask)))
        try await log.append(.taskCreated(TaskCreatedPayload(contract: secondTask)))
        try await log.append(.taskCreated(TaskCreatedPayload(contract: currentTask)))
        try await log.append(.messageCompleted(MessageCompletedPayload(
            messageId: MessageID(rawValue: "other_a1"),
            role: .agent,
            agent: other,
            text: "OTHER AGENT MUST NOT LEAK",
            submissionID: firstID)))
        try await log.append(.messageCompleted(MessageCompletedPayload(
            messageId: MessageID(rawValue: "main_a1_stream"),
            role: .agent,
            agent: main,
            text: "non-final A1 text",
            submissionID: firstID)))
        try await log.append(.taskCompleted(TaskCompletedPayload(
            taskID: firstTask.id,
            agent: main,
            result: firstAnswer)))
        try await log.append(.taskCompleted(TaskCompletedPayload(
            taskID: secondTask.id,
            agent: main,
            result: secondAnswer)))

        let replayed = try await log.replayChecked()
        let bundle = ContextProjector().project(
            agentID: main,
            taskContract: currentTask,
            events: replayed,
            allowedToolNames: [],
            workspaceRoot: root,
            projectsCompletedRootAnswersIntoConversation: true)
        let provider = SubmissionHistoryCapturingProvider()

        // Constructing a fresh loop from the durable log models the same
        // history-reconstruction boundary used after reopening a session.
        let loop = AgentLoop(
            log: log,
            provider: provider,
            registry: ToolRegistry([]),
            engine: PermissionEngine(),
            responder: FixedResponder(.deny),
            agent: Agent(
                name: main,
                workspaceRoot: root,
                model: ModelID(rawValue: "test-model"),
                profile: .reviewed),
            context: ContextBuilder(
                systemPrompt: "system",
                taskContract: currentTask,
                contextBundle: bundle,
                runtimeEnvironment: .cowork,
                conversationHistoryPolicy: .coworkMainThread),
            allowsShell: false)

        _ = try await loop.send(
            "U3",
            recordUserMessage: false,
            submissionID: currentID)

        let request = try XCTUnwrap(provider.requests.first)
        let expectedText = Set([
            "U1", firstAnswer, "U2", secondAnswer, "U3",
        ])
        let conversation = request.messages.compactMap { message -> (AgentRole, String)? in
            guard let content = message.content,
                  expectedText.contains(content) else {
                return nil
            }
            return (message.role, content)
        }
        XCTAssertEqual(conversation.map(\.0), [.user, .assistant, .user, .assistant, .user])
        XCTAssertEqual(
            conversation.map(\.1),
            ["U1", firstAnswer, "U2", secondAnswer, "U3"])
        XCTAssertEqual(request.messages.filter { $0.content == "U3" }.count, 1)
        XCTAssertFalse(request.messages.contains { $0.content == "non-final A1 text" })
        XCTAssertFalse(request.messages.contains { $0.content == "OTHER AGENT MUST NOT LEAK" })

        let contextData = try XCTUnwrap(request.messages.first {
            $0.content?.contains("<<<UNTRUSTED_CONTEXT_DATA>>>") == true
        }?.content)
        XCTAssertFalse(contextData.contains(firstAnswer))
        XCTAssertFalse(contextData.contains(secondAnswer))
    }

    func testTaskScopedWorkerDoesNotReceiveRootThreadTranscript() {
        let main = AgentID(rawValue: "main")
        let worker = AgentID(rawValue: "worker")
        let priorID = SubmissionID(rawValue: "sub_main_prior")
        let currentID = SubmissionID(rawValue: "sub_worker_current")
        let mainTask = TaskContract(
            id: TaskID(rawValue: "task_main_prior"),
            kind: .root,
            issuer: nil,
            assignee: main,
            submissionID: priorID,
            objective: "private main request",
            roleHint: "root",
            expectedDeliverable: "answer")
        let workerTask = TaskContract(
            id: TaskID(rawValue: "task_worker"),
            kind: .agentInvocation,
            issuer: main,
            assignee: worker,
            parentTaskID: mainTask.id,
            submissionID: currentID,
            objective: "scoped worker task",
            roleHint: "worker",
            expectedDeliverable: "report")
        let events = [
            Envelope(
                seq: 0,
                session: SessionID(rawValue: "sess_worker_scope"),
                event: .userMessage(UserMessagePayload(
                    text: "private main request",
                    to: main,
                    submissionID: priorID))),
            Envelope(
                seq: 1,
                session: SessionID(rawValue: "sess_worker_scope"),
                event: .taskCreated(TaskCreatedPayload(contract: mainTask))),
            Envelope(
                seq: 2,
                session: SessionID(rawValue: "sess_worker_scope"),
                event: .messageCompleted(MessageCompletedPayload(
                    messageId: MessageID(rawValue: "main_private_answer"),
                    role: .agent,
                    agent: main,
                    text: "private main answer",
                    submissionID: priorID))),
        ]

        let history = AgentThreadHistoryProjector().project(
            agentID: worker,
            currentTask: workerTask,
            events: events)

        XCTAssertTrue(history.isEmpty)
    }

    func testRootHistoryRequiresDurableCompletionAndRootBinding() {
        let main = AgentID(rawValue: "main")
        let unboundID = SubmissionID(rawValue: "sub_unbound")
        let incompleteID = SubmissionID(rawValue: "sub_incomplete")
        let completedID = SubmissionID(rawValue: "sub_completed")
        let currentID = SubmissionID(rawValue: "sub_current")
        let incompleteTask = TaskContract(
            id: TaskID(rawValue: "task_incomplete"),
            kind: .root,
            issuer: nil,
            assignee: main,
            submissionID: incompleteID,
            objective: "incomplete request",
            roleHint: "root",
            expectedDeliverable: "answer")
        let completedTask = TaskContract(
            id: TaskID(rawValue: "task_completed"),
            kind: .root,
            issuer: nil,
            assignee: main,
            submissionID: completedID,
            objective: "completed request",
            roleHint: "root",
            expectedDeliverable: "answer")
        let currentTask = TaskContract(
            id: TaskID(rawValue: "task_current"),
            kind: .root,
            issuer: nil,
            assignee: main,
            submissionID: currentID,
            objective: "current request",
            roleHint: "root",
            expectedDeliverable: "answer")
        let session = SessionID(rawValue: "sess_completion_boundary")
        let events = [
            Envelope(
                seq: 0,
                session: session,
                event: .userMessage(UserMessagePayload(
                    text: "unbound request",
                    to: main,
                    submissionID: unboundID))),
            Envelope(
                seq: 1,
                session: session,
                event: .userMessage(UserMessagePayload(
                    text: "incomplete request",
                    to: main,
                    submissionID: incompleteID))),
            Envelope(
                seq: 2,
                session: session,
                event: .userMessage(UserMessagePayload(
                    text: "completed request",
                    to: main,
                    submissionID: completedID))),
            Envelope(
                seq: 3,
                session: session,
                event: .userMessage(UserMessagePayload(
                    text: "current request",
                    to: main,
                    submissionID: currentID))),
            Envelope(
                seq: 4,
                session: session,
                event: .taskCreated(TaskCreatedPayload(contract: incompleteTask))),
            Envelope(
                seq: 5,
                session: session,
                event: .taskCreated(TaskCreatedPayload(contract: completedTask))),
            Envelope(
                seq: 6,
                session: session,
                event: .taskCreated(TaskCreatedPayload(contract: currentTask))),
            Envelope(
                seq: 7,
                session: session,
                event: .messageCompleted(MessageCompletedPayload(
                    messageId: MessageID(rawValue: "intermediate"),
                    role: .agent,
                    agent: main,
                    text: "intermediate tool-loop text",
                    submissionID: incompleteID))),
            Envelope(
                seq: 8,
                session: session,
                event: .taskCompleted(TaskCompletedPayload(
                    taskID: completedTask.id,
                    agent: main,
                    result: "completed answer"))),
        ]

        let history = AgentThreadHistoryProjector().project(
            agentID: main,
            currentTask: currentTask,
            events: events)

        XCTAssertEqual(
            history.compactMap(\.content),
            ["completed request", "completed answer"])
    }
}
