import XCTest
import IntatisCore
@testable import IntatisProtocol

final class TaskContractTests: XCTestCase {
    private let encoder = Envelope.makeEncoder()
    private let decoder = Envelope.makeDecoder()

    func testTaskContractCodableRoundTrip() throws {
        let contract = TaskContract(
            id: TaskID(rawValue: "task_count_macos"),
            kind: .agentInvocation,
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "macos-counter"),
            parentTaskID: TaskID(rawValue: "task_root"),
            submissionID: SubmissionID(rawValue: "sub_root_request"),
            objective: "Recursively count macOS Swift files.",
            roleHint: "macOS Swift file counter",
            expectedDeliverable: "File count and path list.",
            workspaceID: WorkspaceID(rawValue: "workspace_macos"),
            workspaceLeaseID: WorkspaceLeaseID(rawValue: "wlease_macos"),
            capabilityLeaseID: CapabilityLeaseID(rawValue: "clease_macos"),
            relatedAgents: [AgentID(rawValue: "ios-counter")],
            relatedTasks: [TaskID(rawValue: "task_count_ios")],
            mailboxMessageIDs: [
                MessageID(rawValue: "mailbox_1"),
                MessageID(rawValue: "mailbox_2"),
            ],
            constraints: ["Complete only the assigned task."],
            replyMode: .taskReport,
            executionTimeoutSeconds: 45,
            maxAttempts: 3)

        let data = try JSONEncoder().encode(contract)
        let decoded = try JSONDecoder().decode(TaskContract.self, from: data)

        XCTAssertEqual(decoded, contract)
        XCTAssertEqual(decoded.workspaceLeaseID, WorkspaceLeaseID(rawValue: "wlease_macos"))
        XCTAssertEqual(decoded.capabilityLeaseID, CapabilityLeaseID(rawValue: "clease_macos"))
        XCTAssertEqual(decoded.submissionID, SubmissionID(rawValue: "sub_root_request"))
        XCTAssertEqual(decoded.replyMode, .taskReport)
        XCTAssertEqual(decoded.executionTimeoutSeconds, 45)
        XCTAssertEqual(decoded.maxAttempts, 3)
        XCTAssertEqual(decoded.mailboxMessageIDs, [
            MessageID(rawValue: "mailbox_1"),
            MessageID(rawValue: "mailbox_2"),
        ])
    }

    func testLegacyTaskContractWithoutExecutionFieldsDecodes() throws {
        let json = """
        {
          "id": "task_legacy",
          "kind": "agent_invocation",
          "issuer": "main",
          "assignee": "worker",
          "parentTaskID": "task_root",
          "objective": "Inspect the legacy workspace.",
          "roleHint": "workspace inspector",
          "expectedDeliverable": "A concise report.",
          "workspaceID": "workspace_legacy",
          "workspaceLeaseID": "wlease_legacy",
          "capabilityLeaseID": "clease_legacy",
          "relatedAgents": [],
          "relatedTasks": [],
          "constraints": ["Read only."]
        }
        """

        let decoded = try JSONDecoder().decode(TaskContract.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.id, TaskID(rawValue: "task_legacy"))
        XCTAssertEqual(decoded.kind, .agentInvocation)
        XCTAssertEqual(decoded.assignee, AgentID(rawValue: "worker"))
        XCTAssertNil(decoded.replyMode)
        XCTAssertNil(decoded.executionTimeoutSeconds)
        XCTAssertNil(decoded.maxAttempts)
        XCTAssertNil(decoded.submissionID)
        XCTAssertNil(decoded.mailboxMessageIDs)
    }

    func testLegacyMailboxTaskWithoutMessageIDsDecodesAsNil() throws {
        let json = """
        {
          "id": "task_legacy_mailbox",
          "kind": "mailbox_delivery",
          "issuer": "worker",
          "assignee": "main",
          "objective": "Review pending mailbox messages.",
          "roleHint": "mailbox responder",
          "expectedDeliverable": "Handle the pending message.",
          "relatedAgents": [],
          "relatedTasks": ["task_causal"],
          "constraints": []
        }
        """

        let decoded = try JSONDecoder().decode(TaskContract.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.kind, .mailboxDelivery)
        XCTAssertEqual(decoded.relatedTasks, [TaskID(rawValue: "task_causal")])
        XCTAssertNil(decoded.mailboxMessageIDs)
    }

    func testAgentAdmissionTaskKindRoundTrips() throws {
        let contract = TaskContract(
            id: TaskID(rawValue: "task_admission"),
            kind: .agentAdmission,
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "worker"),
            objective: "Attach the worker with reviewed leases.",
            roleHint: "agent workspace admission",
            expectedDeliverable: "A durable admission record.",
            replyMode: TaskReplyMode.none,
            maxAttempts: 1)

        let data = try JSONEncoder().encode(contract)
        let decoded = try JSONDecoder().decode(TaskContract.self, from: data)

        XCTAssertEqual(decoded, contract)
        XCTAssertEqual(decoded.kind, .agentAdmission)
        XCTAssertEqual(decoded.replyMode, TaskReplyMode.none)
    }

    func testTaskEventsRoundTripThroughEnvelope() throws {
        let contract = TaskContract(
            id: TaskID(rawValue: "task_1"),
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "worker"),
            objective: "Inspect the assigned workspace.",
            roleHint: "workspace inspector",
            expectedDeliverable: "Summary of findings.",
            constraints: ["Complete only the assigned task."])

        try roundTrip(Envelope(seq: 1, ts: Date(timeIntervalSince1970: 1),
                               session: SessionID(rawValue: "sess_task"),
                               event: .taskCreated(.init(contract: contract))))
        try roundTrip(Envelope(seq: 2, ts: Date(timeIntervalSince1970: 2),
                               session: SessionID(rawValue: "sess_task"),
                               event: .taskAssigned(.init(contract: contract))))
    }

    private func roundTrip(_ envelope: Envelope, line: UInt = #line) throws {
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(Envelope.self, from: data)
        XCTAssertEqual(decoded, envelope, line: line)
    }
}
