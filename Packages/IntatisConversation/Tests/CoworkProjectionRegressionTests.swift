import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisConversation

final class CoworkProjectionRegressionTests: XCTestCase {
    private let session = SessionID(rawValue: "sess_cowork_projection")
    private let main = AgentID(rawValue: "main")
    private let worker = AgentID(rawValue: "worker")

    private func envelope(_ seq: Int, _ event: Event) -> Envelope {
        Envelope(
            seq: seq,
            ts: Date(timeIntervalSince1970: Double(seq)),
            session: session,
            event: event)
    }

    private func contract(id: String = "task_projection") -> TaskContract {
        TaskContract(
            id: TaskID(rawValue: id),
            issuer: main,
            assignee: worker,
            objective: "Inspect the workspace.",
            roleHint: "workspace inspector",
            expectedDeliverable: "A concise report.",
            maxAttempts: 2)
    }

    private func queued(_ contract: TaskContract,
                        attempt: Int,
                        reason: String) -> TaskQueuedPayload {
        TaskQueuedPayload(
            contract: contract,
            rootTaskID: contract.id,
            issuer: main,
            assignee: worker,
            hopCount: 0,
            visitedAgents: [worker],
            attempt: attempt,
            reason: reason)
    }

    private func inferenceBinding(profile: String,
                                  revision: String = "rev-1") -> AgentInferenceBinding {
        AgentInferenceBinding(
            inferenceProfileRef: InferenceProfileRef(
                inferenceProfileID: InferenceProfileID(rawValue: profile),
                inferenceProfileRevision: InferenceProfileRevision(rawValue: revision)),
            inferenceConnectionID: InferenceConnectionID(rawValue: "connection-\(profile)"),
            inferenceConnectionRevision: InferenceConnectionRevision(rawValue: "connection-rev-1"),
            modelID: ModelID(rawValue: "model-\(profile)"),
            variantID: "high",
            safeRouteLabel: "route-\(profile)",
            immutableDefinitionFingerprint: "fingerprint-\(profile)-\(revision)")
    }

    func testAgentSpawnedDoesNotOverwriteAttachedInferenceBinding() throws {
        let binding = inferenceBinding(profile: "profile-worker")
        let attached = AgentAttachedPayload(
            agent: worker,
            path: "/workspace/approved",
            model: binding.modelID,
            profile: "reviewed",
            agentInferenceBinding: binding,
            metadata: CoworkEventMetadata(agentID: worker, scope: .agent))
        let projection = CoworkProjection.build(from: [
            envelope(0, .agentAttached(attached)),
            envelope(1, .agentSpawned(.init(
                requestedBy: main,
                agent: worker,
                path: "/workspace/spawn-event",
                model: ModelID(rawValue: "different-model"),
                agentInferenceBinding: inferenceBinding(profile: "different-profile")))),
        ])

        XCTAssertEqual(try XCTUnwrap(projection.agentRoster[worker]), attached)
        XCTAssertEqual(
            try XCTUnwrap(projection.historicalAgentRoster[worker]),
            attached)
        XCTAssertEqual(projection.agentOwners[worker], main)
    }

    func testSpawnOnlyLegacyLogSynthesizesUnresolvedInferenceBinding() throws {
        let projection = CoworkProjection.build(from: [
            envelope(0, .agentSpawned(.init(
                requestedBy: main,
                agent: worker,
                path: "/workspace/legacy",
                model: ModelID(rawValue: "legacy-model")))),
        ])

        let attached = try XCTUnwrap(projection.agentRoster[worker])
        XCTAssertEqual(attached.agent, worker)
        XCTAssertEqual(attached.path, "/workspace/legacy")
        XCTAssertEqual(attached.model, ModelID(rawValue: "legacy-model"))
        XCTAssertEqual(attached.profile, "reviewed")
        XCTAssertNil(attached.agentInferenceBinding)
        XCTAssertEqual(projection.historicalAgentRoster[worker], attached)
        XCTAssertEqual(projection.agentOwners[worker], main)
    }

    func testDetachedAgentLeavesLiveRosterButRemainsInHistoricalRoster() throws {
        let binding = inferenceBinding(profile: "profile-worker")
        let attached = AgentAttachedPayload(
            agent: worker,
            path: "/workspace/worker",
            model: binding.modelID,
            profile: "reviewed",
            agentInferenceBinding: binding)
        let projection = CoworkProjection.build(from: [
            envelope(0, .agentAttached(attached)),
            envelope(1, .agentStatus(.init(agent: worker, state: .thinking))),
            envelope(2, .agentDetached(.init(
                agent: worker,
                reason: "work complete"))),
        ])

        XCTAssertNil(projection.agentRoster[worker])
        XCTAssertEqual(
            try XCTUnwrap(projection.historicalAgentRoster[worker]),
            attached)
        XCTAssertNil(projection.agentStatuses[worker])
    }

    func testReattachingHistoricalAgentUpdatesOneStableIdentity() throws {
        let first = AgentAttachedPayload(
            agent: worker,
            path: "/workspace/first",
            model: ModelID(rawValue: "first-model"),
            profile: "reviewed")
        let reattached = AgentAttachedPayload(
            agent: worker,
            path: "/workspace/second",
            model: ModelID(rawValue: "second-model"),
            profile: "reviewed")
        let projection = CoworkProjection.build(from: [
            envelope(0, .agentAttached(first)),
            envelope(1, .agentDetached(.init(agent: worker))),
            envelope(2, .agentAttached(reattached)),
        ])

        XCTAssertEqual(projection.agentRoster.count, 1)
        XCTAssertEqual(projection.historicalAgentRoster.count, 1)
        XCTAssertEqual(projection.agentRoster[worker], reattached)
        XCTAssertEqual(projection.historicalAgentRoster[worker], reattached)
    }

    func testHistoricalAgentsKeepFirstAdmissionOrderAcrossLiveChanges() {
        let first = AgentID(rawValue: "z-first")
        let second = AgentID(rawValue: "a-second")
        let third = AgentID(rawValue: "m-third")
        func attached(_ agent: AgentID, path: String) -> AgentAttachedPayload {
            AgentAttachedPayload(
                agent: agent,
                path: path,
                model: ModelID(rawValue: "fixture-model"),
                profile: "reviewed")
        }

        let projection = CoworkProjection.build(from: [
            envelope(0, .agentAttached(attached(first, path: "/workspace/first"))),
            envelope(1, .agentStatus(.init(agent: first, state: .thinking))),
            envelope(2, .agentAttached(attached(second, path: "/workspace/second"))),
            envelope(3, .agentDetached(.init(agent: first))),
            envelope(4, .agentAttached(attached(third, path: "/workspace/third"))),
            envelope(5, .agentAttached(attached(first, path: "/workspace/reattached"))),
        ])

        XCTAssertEqual(projection.historicalAgentOrder, [first, second, third])
        XCTAssertEqual(
            projection.historicalAgentsInCreationOrder.map(\.agent),
            [first, second, third])
        XCTAssertEqual(
            projection.historicalAgentRoster[first]?.path,
            "/workspace/reattached")
    }

    func testLargeHistoricalRosterDoesNotInflateLiveRoster() {
        let count = 512
        var events: [Envelope] = []
        events.reserveCapacity(count * 2)
        for index in 0..<count {
            let agent = AgentID(rawValue: "worker-\(index)")
            events.append(envelope(
                index,
                .agentAttached(.init(
                    agent: agent,
                    path: "/workspace/\(index)",
                    model: ModelID(rawValue: "fixture-model"),
                    profile: "reviewed"))))
        }
        for index in 0..<(count - 12) {
            events.append(envelope(
                count + index,
                .agentDetached(.init(
                    agent: AgentID(rawValue: "worker-\(index)")))))
        }

        let projection = CoworkProjection.build(from: events)

        XCTAssertEqual(projection.historicalAgentRoster.count, count)
        XCTAssertEqual(projection.agentRoster.count, 12)
        XCTAssertNotNil(
            projection.historicalAgentRoster[
                AgentID(rawValue: "worker-0")])
        XCTAssertNil(projection.agentRoster[AgentID(rawValue: "worker-0")])
    }

    func testTaskCancelledBecomesTerminalAndLeavesPendingMailbox() throws {
        let contract = contract(id: "task_cancelled")
        let report = TaskReportPayload(
            taskID: contract.id,
            agent: worker,
            status: .cancelled,
            objective: contract.objective,
            expectedDeliverable: contract.expectedDeliverable,
            summary: "Stopped before completion.",
            error: "cancelled by user",
            attempt: 1,
            reportedAt: Date(timeIntervalSince1970: 10))
        let projection = CoworkProjection.build(from: [
            envelope(0, .taskCreated(.init(contract: contract))),
            envelope(1, .taskQueued(queued(contract, attempt: 1, reason: "scheduled"))),
            envelope(2, .taskCancelled(.init(
                taskID: contract.id,
                agent: worker,
                reason: "cancelled by user",
                report: report,
                attempt: 1))),
        ])

        let task = try XCTUnwrap(projection.tasks[contract.id])
        XCTAssertEqual(task.status, .cancelled)
        XCTAssertEqual(task.attempt, 1)
        XCTAssertEqual(task.error, "cancelled by user")
        XCTAssertEqual(task.statusReason, "cancelled by user")
        XCTAssertEqual(task.report, report)
        XCTAssertEqual(projection.cancelledTasks.map(\.id), [contract.id])
        XCTAssertFalse(projection.activeTasks.contains { $0.id == contract.id })
        XCTAssertFalse(projection.mailboxes[worker]?.pendingTasks.contains(contract.id) ?? false)
    }

    func testAgentMessageConsumedRemovesOnlyPendingMarker() {
        let consumedID = MessageID(rawValue: "msg_consumed")
        let pendingID = MessageID(rawValue: "msg_pending")
        let taskID = TaskID(rawValue: "task_messages")
        let projection = CoworkProjection.build(from: [
            envelope(0, .agentMessage(.init(
                from: main,
                to: worker,
                content: "first message",
                kind: .sendMessage,
                messageId: consumedID,
                taskID: taskID))),
            envelope(1, .agentMessage(.init(
                from: main,
                to: worker,
                content: "second message",
                kind: .sendMessage,
                messageId: pendingID,
                taskID: taskID))),
            envelope(2, .agentMessageConsumed(.init(
                messageID: consumedID,
                agent: worker,
                taskID: taskID))),
        ])

        XCTAssertEqual(projection.mailboxes[worker]?.pendingMessages, [pendingID])
        XCTAssertEqual(projection.agentMessages.map(\.messageId), [consumedID, pendingID])
        XCTAssertEqual(projection.agentMessages.first?.content, "first message")
    }

    func testRetryQueueClearsPriorFailureOutcomeAndAdvancesAttempt() throws {
        let contract = contract(id: "task_retry")
        let failedReport = TaskReportPayload(
            taskID: contract.id,
            agent: worker,
            status: .failed,
            objective: contract.objective,
            expectedDeliverable: contract.expectedDeliverable,
            summary: "Attempt zero failed.",
            error: "transient provider failure",
            attempt: 0,
            reportedAt: Date(timeIntervalSince1970: 20))
        let projection = CoworkProjection.build(from: [
            envelope(0, .taskCreated(.init(contract: contract))),
            envelope(1, .taskQueued(queued(contract, attempt: 0, reason: "initial attempt"))),
            envelope(2, .taskStarted(.init(taskID: contract.id, agent: worker, attempt: 0))),
            envelope(3, .taskFailed(.init(
                taskID: contract.id,
                agent: worker,
                error: "transient provider failure",
                report: failedReport,
                attempt: 0))),
            envelope(4, .taskQueued(queued(contract, attempt: 1, reason: "retry after failure"))),
        ])

        let task = try XCTUnwrap(projection.tasks[contract.id])
        XCTAssertEqual(task.status, .queued)
        XCTAssertEqual(task.attempt, 1)
        XCTAssertEqual(task.statusReason, "retry after failure")
        XCTAssertNil(task.result)
        XCTAssertNil(task.error)
        XCTAssertNil(task.report)
        XCTAssertEqual(projection.queuedTasks.map(\.id), [contract.id])
        XCTAssertEqual(projection.mailboxes[worker]?.pendingTasks, [contract.id])
        XCTAssertFalse(projection.failedTasks.contains { $0.id == contract.id })
    }
}
