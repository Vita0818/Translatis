import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
@testable import IntatisCowork

private final class SplitProvider: ToolCallingProvider, @unchecked Sendable {
    private let chunks: [AgentChunk]
    private let lock = NSLock()
    private var capturedRequests: [AgentRequest] = []

    init(_ chunks: [AgentChunk] = [.textDelta("done"), .done(finishReason: "stop")]) {
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

private enum SplitProviderFailure: Error {
    case forcedFailure
}

private final class SplitFirstSuccessThenFailureProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequests: [AgentRequest] = []

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests.count
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        capturedRequests.append(request)
        let requestCount = capturedRequests.count
        lock.unlock()
        return AsyncThrowingStream { continuation in
            if requestCount == 1 {
                continuation.yield(.textDelta("done"))
                continuation.yield(.done(finishReason: "stop"))
                continuation.finish()
            } else {
                continuation.finish(throwing: SplitProviderFailure.forcedFailure)
            }
        }
    }
}

private func splitLog() throws -> EventLog {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-split-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    return try EventLog(session: SessionID(rawValue: "split"), fileURL: url)
}

private func splitWorkspace() throws -> URL {
    let ws = FileManager.default.temporaryDirectory.appendingPathComponent("split-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    return ws
}

private func splitTaskContracts(_ events: [Envelope]) -> [TaskContract] {
    events.compactMap {
        if case .taskCreated(let payload) = $0.event { return payload.contract }
        return nil
    }
}

final class MessageDelegationSplitTests: XCTestCase {
    private let main = AgentID(rawValue: "main")
    private let worker = AgentID(rawValue: "worker")

    private func makeOrchestrator(log: EventLog,
                                  mainProvider: SplitProvider = SplitProvider(),
                                  workerProvider: SplitProvider = SplitProvider()) async throws -> (Orchestrator, URL, URL) {
        let wsMain = try splitWorkspace()
        let wsWorker = try splitWorkspace()
        let worker = self.worker
        let orch = Orchestrator(log: log, allowsShell: true, responder: FixedResponder(.allow)) { agent in
            agent.name == worker ? workerProvider : mainProvider
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

    func testSendMessageCreatesDurableMailboxWakeTaskAndConsumesMessage() async throws {
        let log = try splitLog()
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }

        let result = await orch.sendMessage(from: main, to: worker.rawValue, content: "status ping")

        XCTAssertEqual(result, "sent message to @worker")
        await orch.runSchedulerUntilIdle()
        let events = await log.replay()
        let message = try XCTUnwrap(events.compactMap { envelope -> AgentMessagePayload? in
            if case .agentMessage(let payload) = envelope.event,
               payload.from == main, payload.to == worker, payload.kind == .sendMessage {
                return payload
            }
            return nil
        }.first)
        let wakeTask = try XCTUnwrap(splitTaskContracts(events).first {
            $0.kind == .mailboxDelivery && $0.assignee == worker
        })
        XCTAssertEqual(wakeTask.issuer, main)
        XCTAssertEqual(wakeTask.mailboxMessageIDs, [message.messageId])
        let capabilityLease = try XCTUnwrap(events.compactMap { envelope -> CapabilityLease? in
            guard case .capabilityLeaseCreated(let payload) = envelope.event,
                  payload.lease.taskID == wakeTask.id else { return nil }
            return payload.lease
        }.first)
        let workspaceLease = try XCTUnwrap(events.compactMap { envelope -> WorkspaceLease? in
            guard case .workspaceLeaseGranted(let payload) = envelope.event,
                  payload.lease.taskID == wakeTask.id else { return nil }
            return payload.lease
        }.first)
        XCTAssertEqual(workspaceLease.access, .readOnly)
        XCTAssertEqual(capabilityLease.communication, .none)
        XCTAssertEqual(capabilityLease.delegation, .none)
        XCTAssertTrue(capabilityLease.mcpGrants.isEmpty)
        XCTAssertFalse(capabilityLease.tools.contains(.manageWorkTasks))
        XCTAssertFalse(capabilityLease.tools.contains(.updateBoundWorkTask))
        XCTAssertFalse(capabilityLease.tools.contains(.delegateTask))
        XCTAssertFalse(capabilityLease.tools.contains(.runShell))
        XCTAssertFalse(capabilityLease.tools.contains(.gitControl))
        XCTAssertFalse(capabilityLease.tools.contains(.gitRemote))
        XCTAssertFalse(capabilityLease.tools.contains(.applyPatch))
        XCTAssertFalse(capabilityLease.tools.contains(.browseWeb))
        XCTAssertTrue(capabilityLease.tools.contains(.readPDF))
        XCTAssertTrue(ToolCapability.exactDocumentObservationCapabilities
            .isSubset(of: capabilityLease.tools))
        XCTAssertTrue(capabilityLease.tools.isDisjoint(
            with: ToolCapability.legacyDocumentCapabilities))
        XCTAssertTrue(capabilityLease.tools.isDisjoint(
            with: ToolCapability.exactDocumentMutationCapabilities))
        let mailboxToolNames = Set(Orchestrator.toolRegistry(
            for: capabilityLease).descriptors().map(\.name))
        XCTAssertTrue(mailboxToolNames.contains("inspect_pdf"))
        XCTAssertTrue(mailboxToolNames.contains("read_pdf"))
        XCTAssertTrue([
            "read_docx", "continue_docx_read",
            "read_pptx", "continue_pptx_read",
            "read_xlsx", "continue_xlsx_read",
            "read_html", "continue_html_read",
            "read_epub", "continue_epub_read",
        ]
            .allSatisfy(mailboxToolNames.contains))
        XCTAssertFalse(mailboxToolNames.contains("document_read"))
        XCTAssertTrue(mailboxToolNames.contains("ocr_pdf"))
        XCTAssertFalse(mailboxToolNames.contains("pdf_render_page"))
        XCTAssertFalse(mailboxToolNames.contains("document_export_pdf"))
        XCTAssertFalse(mailboxToolNames.contains("document_write"))
        XCTAssertFalse(mailboxToolNames.contains("task_create"))
        XCTAssertFalse(mailboxToolNames.contains("task_update"))
        XCTAssertFalse(mailboxToolNames.contains("delegate_task"))
        XCTAssertFalse(mailboxToolNames.contains("ask_agent"))
        XCTAssertFalse(mailboxToolNames.contains("reply_message"))
        XCTAssertFalse(mailboxToolNames.contains("exec_command"))
        XCTAssertFalse(mailboxToolNames.contains("write_stdin"))
        XCTAssertFalse(mailboxToolNames.contains("apply_patch"))
        XCTAssertFalse(mailboxToolNames.contains("web_fetch"))
        XCTAssertFalse(mailboxToolNames.contains { $0.hasPrefix("git_") })
        XCTAssertFalse(mailboxToolNames.contains { $0.hasPrefix("browser_") })
        XCTAssertTrue(events.contains {
            if case .taskQueued(let payload) = $0.event {
                return payload.contract.id == wakeTask.id && payload.reason == "mailbox delivery"
            }
            return false
        })
        let completedSeq = try XCTUnwrap(events.first {
            guard case .taskCompleted(let payload) = $0.event else { return false }
            return payload.taskID == wakeTask.id
        }?.seq)
        let consumedSeq = try XCTUnwrap(events.first {
            guard case .agentMessageConsumed(let payload) = $0.event else { return false }
            return payload.messageID == message.messageId
        }?.seq)
        XCTAssertEqual(consumedSeq, completedSeq + 1)
        XCTAssertTrue(events.contains {
            if case .agentMessageConsumed(let payload) = $0.event {
                return payload.messageID == message.messageId
                    && payload.agent == worker
                    && payload.taskID == wakeTask.id
            }
            return false
        })
        let workerMailbox = await orch.mailbox(for: worker)
        XCTAssertTrue(workerMailbox.pendingMessages.isEmpty)
        XCTAssertFalse(events.contains { if case .taskDelegated = $0.event { return true } else { return false } })
    }

    func testMessageRemainsPendingWhenConsumptionEventCannotPersist() async throws {
        let log = try splitLog()
        let wsMain = try splitWorkspace()
        let wsWorker = try splitWorkspace()
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }
        let workerProvider = SplitFirstSuccessThenFailureProvider()
        let worker = self.worker
        let orch = Orchestrator(
            log: log,
            allowsShell: true,
            responder: FixedResponder(.allow)
        ) { agent in
            if agent.name == worker { return workerProvider }
            return SplitProvider()
        }
        let mainAttached = await orch.attach(Agent(
            name: main,
            workspaceRoot: wsMain,
            model: ModelID(rawValue: "m"),
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth))
        let workerAttached = await orch.attach(Agent(
            name: worker,
            workspaceRoot: wsWorker,
            model: ModelID(rawValue: "m"),
            profile: .reviewed))
        XCTAssertTrue(mainAttached)
        XCTAssertTrue(workerAttached)
        await orch.setMessageConsumptionPreflightForTesting { _ in
            throw SplitProviderFailure.forcedFailure
        }

        let sendResult = await orch.sendMessage(
            from: main,
            to: worker.rawValue,
            content: "persist before ack")
        XCTAssertEqual(sendResult, "sent message to @worker")
        await orch.runSchedulerUntilIdle()

        let events = await log.replay()
        let message = try XCTUnwrap(events.compactMap { envelope -> AgentMessagePayload? in
            guard case .agentMessage(let payload) = envelope.event else { return nil }
            return payload.content == "persist before ack" ? payload : nil
        }.first)
        let mailbox = await orch.mailbox(for: worker)
        XCTAssertEqual(
            workerProvider.requestCount,
            3,
            "consumption failure retries one exact delivery TaskID through its bounded attempts")
        XCTAssertEqual(mailbox.pendingMessages, [message.messageId])
        let deliveryQueues = events.compactMap { envelope -> (TaskID, Int)? in
            guard case .taskQueued(let payload) = envelope.event,
                  payload.contract.kind == .mailboxDelivery,
                  let attempt = payload.attempt else { return nil }
            return (payload.contract.id, attempt)
        }
        XCTAssertEqual(Set(deliveryQueues.map(\.0)).count, 1)
        XCTAssertEqual(deliveryQueues.map(\.1), [1, 2, 3])
        let deliveryTaskID = try XCTUnwrap(deliveryQueues.first?.0)
        XCTAssertFalse(events.contains {
            guard case .taskCompleted(let payload) = $0.event else { return false }
            return payload.taskID == deliveryTaskID
        })
        XCTAssertFalse(events.contains {
            guard case .agentMessageConsumed(let payload) = $0.event else { return false }
            return payload.messageID == message.messageId
        })
    }

    func testRequestInformationCreatesDurableMailboxWakeTaskAndConsumesRequest() async throws {
        let log = try splitLog()
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }

        let result = await orch.requestInformation(from: main, to: worker.rawValue, question: "Which folder is active?")

        XCTAssertTrue(result.hasPrefix("requested information from @worker (request_id: "))
        await orch.runSchedulerUntilIdle()
        let events = await log.replay()
        let request = try XCTUnwrap(events.compactMap { envelope -> InformationRequestedPayload? in
            if case .informationRequested(let payload) = envelope.event,
               payload.from == main, payload.to == worker, payload.question.contains("folder") {
                return payload
            }
            return nil
        }.first)
        let wakeTask = try XCTUnwrap(splitTaskContracts(events).first {
            $0.kind == .mailboxDelivery && $0.assignee == worker
        })
        XCTAssertEqual(wakeTask.mailboxMessageIDs, [request.requestID])
        XCTAssertTrue(events.contains {
            if case .agentMessageConsumed(let payload) = $0.event {
                return payload.messageID == request.requestID
                    && payload.agent == worker
                    && payload.taskID == wakeTask.id
            }
            return false
        })
        let workerMailbox = await orch.mailbox(for: worker)
        XCTAssertTrue(workerMailbox.pendingMessages.isEmpty)
        XCTAssertFalse(events.contains { if case .taskDelegated = $0.event { return true } else { return false } })
    }

    func testReplyMessageRejectsUnfrozenCorrelation() async throws {
        let log = try splitLog()
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }
        let current = await orch.enqueueDelegatedTask(
            from: main,
            to: worker.rawValue,
            objective: "Prepare the requested status reply.",
            replyMode: .none)
        let currentTaskID = try XCTUnwrap(current.taskID)

        let result = await orch.replyMessage(
            from: worker,
            to: main.rawValue,
            content: "macOS count is ready",
            inReplyTo: "msg_info",
            taskID: currentTaskID)

        XCTAssertEqual(
            result,
            "error: reply_message may answer only an information request frozen into this mailbox invocation")
        await orch.runSchedulerUntilIdle()
        let events = await log.replay()
        XCTAssertFalse(events.contains {
            if case .informationReplied = $0.event { return true }
            return false
        })
    }

    func testReplyMessageSchemaRequiresExactCorrelationAndRejectsExtraFields() throws {
        let data = try JSONEncoder().encode(ReplyMessageTool.descriptor.parameters)
        let schema = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set((schema["required"] as? [String]) ?? []),
            ["to", "content", "inReplyTo"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    }

    func testDelegateTaskCreatesTaskContractAndTaskDelegatedEvent() async throws {
        let log = try splitLog()
        let workerProvider = SplitProvider([.textDelta("worker result"), .done(finishReason: "stop")])
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log, workerProvider: workerProvider)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }

        let result = await orch.delegateTask(from: main,
                                             to: worker.rawValue,
                                             objective: "Count macOS Swift files only.",
                                             roleHint: "macOS Swift counter",
                                             expectedDeliverable: "count and path list")

        XCTAssertTrue(result.contains("Task Report"))
        XCTAssertTrue(result.contains("status: completed"))
        XCTAssertTrue(result.contains("agent: @worker"))
        XCTAssertTrue(result.contains("summary: worker result"))
        let events = await log.replay()
        let contract = try XCTUnwrap(splitTaskContracts(events).first)
        XCTAssertEqual(contract.issuer, main)
        XCTAssertEqual(contract.assignee, worker)
        XCTAssertEqual(contract.roleHint, "macOS Swift counter")
        XCTAssertEqual(contract.expectedDeliverable, "count and path list")
        XCTAssertTrue(events.contains {
            if case .taskDelegated(let payload) = $0.event {
                return payload.contract == contract
            }
            return false
        })
    }

    func testCapabilityLeaseControlsMessageAndDelegationTools() {
        let workerTools = Set(Orchestrator.toolRegistry(for: .worker()).descriptors().map(\.name))
        XCTAssertTrue(workerTools.contains("reply_message"))
        XCTAssertFalse(workerTools.contains("request_delegation"))
        XCTAssertTrue(workerTools.contains("inspect_pdf"))
        XCTAssertTrue(workerTools.contains("read_pdf"))
        XCTAssertTrue([
            "read_docx", "continue_docx_read",
            "read_pptx", "continue_pptx_read",
            "read_xlsx", "continue_xlsx_read",
            "read_html", "continue_html_read",
            "read_epub", "continue_epub_read",
        ]
            .allSatisfy(workerTools.contains))
        XCTAssertFalse(workerTools.contains("document_read"))
        XCTAssertTrue(workerTools.contains("ocr_pdf"))
        XCTAssertFalse(workerTools.contains("pdf_render_page"))
        XCTAssertFalse(workerTools.contains("document_export_pdf"))
        XCTAssertFalse(workerTools.contains("document_write"))
        XCTAssertFalse(workerTools.contains("delegate_task"))
        XCTAssertFalse(workerTools.contains("ask_agent"))
        XCTAssertFalse(workerTools.contains("generate_image"))
        XCTAssertFalse(workerTools.contains("edit_image"))
        XCTAssertFalse(workerTools.contains("browser_diagnostics"))
        XCTAssertFalse(workerTools.contains("browser_profiles"))
        XCTAssertFalse(workerTools.contains("browser_profile_delete"))
        XCTAssertFalse(workerTools.contains("browser_history"))
        XCTAssertFalse(workerTools.contains("browser_navigate"))
        XCTAssertFalse(workerTools.contains("browser_snapshot"))
        XCTAssertFalse(workerTools.contains("browser_handoff"))
        XCTAssertFalse(workerTools.contains("browser_reload"))
        XCTAssertFalse(workerTools.contains("browser_back"))
        XCTAssertFalse(workerTools.contains("browser_forward"))
        XCTAssertFalse(workerTools.contains("browser_click"))
        XCTAssertFalse(workerTools.contains("browser_type"))
        XCTAssertFalse(workerTools.contains("browser_submit"))
        XCTAssertFalse(workerTools.contains("browser_select_option"))
        XCTAssertFalse(workerTools.contains("browser_press_key"))
        XCTAssertFalse(workerTools.contains("browser_scroll"))
        XCTAssertFalse(workerTools.contains("browser_wait"))
        XCTAssertFalse(workerTools.contains("browser_screenshot"))
        XCTAssertFalse(workerTools.contains("browser_upload_file"))
        XCTAssertFalse(workerTools.contains("browser_download"))
        XCTAssertFalse(workerTools.contains("browser_downloads"))
        XCTAssertFalse(workerTools.contains("browser_search"))

        let coordinatorTools = Set(Orchestrator.toolRegistry(for: .coordinator()).descriptors().map(\.name))
        XCTAssertTrue(coordinatorTools.contains("send_message"))
        XCTAssertTrue(coordinatorTools.contains("request_information"))
        XCTAssertTrue(coordinatorTools.contains("reply_message"))
        XCTAssertTrue(coordinatorTools.contains("delegate_task"))
        XCTAssertTrue(coordinatorTools.contains("ask_agent"))
        XCTAssertTrue([
            "read_docx", "continue_docx_read",
            "read_pptx", "continue_pptx_read",
            "read_xlsx", "continue_xlsx_read",
            "read_html", "continue_html_read",
            "read_epub", "continue_epub_read",
        ]
            .allSatisfy(coordinatorTools.contains))
        XCTAssertFalse(coordinatorTools.contains("document_read"))
        XCTAssertTrue(coordinatorTools.contains("ocr_pdf"))
        XCTAssertTrue(coordinatorTools.contains("pdf_render_page"))
        XCTAssertTrue([
            "docx_export_pdf", "pptx_export_pdf", "xlsx_export_pdf", "html_export_pdf",
        ].allSatisfy(coordinatorTools.contains))
        XCTAssertTrue([
            "docx_create_document", "docx_add_paragraph",
            "pptx_create_presentation", "xlsx_create_workbook",
        ].allSatisfy(coordinatorTools.contains))
        XCTAssertFalse(coordinatorTools.contains("document_export_pdf"))
        XCTAssertFalse(coordinatorTools.contains("document_write"))
        XCTAssertFalse(coordinatorTools.contains("read_document"))
        XCTAssertFalse(coordinatorTools.contains("edit_pdf_pages"))
        XCTAssertFalse(coordinatorTools.contains("reconstruct_document_image"))
        XCTAssertTrue(coordinatorTools.contains("compile_latex"))
        XCTAssertTrue(coordinatorTools.contains("generate_image"))
        XCTAssertTrue(coordinatorTools.contains("edit_image"))
        XCTAssertTrue(coordinatorTools.contains("web_fetch"))
        XCTAssertTrue(coordinatorTools.contains("browser_diagnostics"))
        XCTAssertTrue(coordinatorTools.contains("browser_profiles"))
        XCTAssertTrue(coordinatorTools.contains("browser_profile_delete"))
        XCTAssertTrue(coordinatorTools.contains("browser_history"))
        XCTAssertTrue(coordinatorTools.contains("browser_navigate"))
        XCTAssertTrue(coordinatorTools.contains("browser_snapshot"))
        XCTAssertTrue(coordinatorTools.contains("browser_handoff"))
        XCTAssertTrue(coordinatorTools.contains("browser_reload"))
        XCTAssertTrue(coordinatorTools.contains("browser_back"))
        XCTAssertTrue(coordinatorTools.contains("browser_forward"))
        XCTAssertTrue(coordinatorTools.contains("browser_click"))
        XCTAssertTrue(coordinatorTools.contains("browser_type"))
        XCTAssertTrue(coordinatorTools.contains("browser_submit"))
        XCTAssertTrue(coordinatorTools.contains("browser_select_option"))
        XCTAssertTrue(coordinatorTools.contains("browser_press_key"))
        XCTAssertTrue(coordinatorTools.contains("browser_scroll"))
        XCTAssertTrue(coordinatorTools.contains("browser_wait"))
        XCTAssertTrue(coordinatorTools.contains("browser_screenshot"))
        XCTAssertTrue(coordinatorTools.contains("browser_upload_file"))
        XCTAssertTrue(coordinatorTools.contains("browser_download"))
        XCTAssertTrue(coordinatorTools.contains("browser_downloads"))
        XCTAssertTrue(coordinatorTools.contains("browser_search"))
    }

    func testAskAgentCompatibilityWrapperRejectsSelfCallAndWorkerDoesNotSeeAskAgent() async throws {
        let log = try splitLog()
        let workerProvider = SplitProvider()
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log, workerProvider: workerProvider)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }

        let selfCall = await orch.ask(from: worker, to: "@worker", question: "call yourself")
        XCTAssertEqual(selfCall, "error: agent cannot ask itself")

        await orch.send("capture worker request", to: worker)
        let request = try XCTUnwrap(workerProvider.requests.first)
        let toolNames = Set(request.tools.map(\.name))
        XCTAssertFalse(toolNames.contains("ask_agent"))
        XCTAssertFalse(toolNames.contains("delegate_task"))
    }

    func testMessageBusEventsDistinguishMailboxCommunicationFromMediatedDelegation() async throws {
        let log = try splitLog()
        let (orch, wsMain, wsWorker) = try await makeOrchestrator(log: log)
        defer {
            try? FileManager.default.removeItem(at: wsMain)
            try? FileManager.default.removeItem(at: wsWorker)
        }

        let current = await orch.enqueueDelegatedTask(
            from: main,
            to: worker.rawValue,
            objective: "Prepare a reply for the current task.",
            replyMode: .none)
        let currentTaskID = try XCTUnwrap(current.taskID)
        let invalidReply = await orch.replyMessage(
            from: worker,
            to: main.rawValue,
            content: "answer",
            inReplyTo: nil,
            taskID: currentTaskID)
        XCTAssertEqual(
            invalidReply,
            "error: inReplyTo is required and must identify the frozen information request")
        _ = await orch.sendMessage(from: main, to: worker.rawValue, content: "hello")
        _ = await orch.requestInformation(from: main, to: worker.rawValue, question: "question")
        _ = await orch.delegateTask(from: main, to: worker.rawValue, objective: "Do one task.")

        await orch.runSchedulerUntilIdle()
        let events = await log.replay()
        let types = events.map { $0.event.type }
        XCTAssertTrue(types.contains(.agentMessage))
        XCTAssertTrue(types.contains(.informationRequested))
        XCTAssertFalse(types.contains(.informationReplied))
        XCTAssertTrue(types.contains(.agentToAgentMessage))
        XCTAssertTrue(types.contains(.taskDelegated))
        XCTAssertTrue(types.contains(.taskCreated))
        let explicitMessages = events.compactMap { envelope -> AgentMessagePayload? in
            if case .agentMessage(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(explicitMessages.filter { $0.kind == .sendMessage && $0.content == "hello" }.count, 1)
        let mediatedDelegations = events.compactMap { envelope -> AgentToAgentMessagePayload? in
            if case .agentToAgentMessage(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertTrue(mediatedDelegations.contains { $0.content == "Do one task." })
        XCTAssertFalse(explicitMessages.contains { $0.content == "Do one task." })
    }
}
