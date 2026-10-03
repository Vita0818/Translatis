import XCTest
import IntatisCore
@testable import IntatisProtocol

final class TaskGoalProtocolTests: XCTestCase {
    private let session = SessionID(rawValue: "sess_task_goal")
    private let runID = ContinuationRunID(rawValue: "run_1")
    private let goalID = GoalID(rawValue: "goal_1")
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testTypedIdentifiersEncodeAsBareStringsAndUseDistinctPrefixes() throws {
        let ids: [String] = [
            WorkTaskID.new().rawValue,
            GoalID.new().rawValue,
            ContinuationRunID.new().rawValue,
        ]
        XCTAssertTrue(ids[0].hasPrefix("wt_"))
        XCTAssertTrue(ids[1].hasPrefix("goal_"))
        XCTAssertTrue(ids[2].hasPrefix("run_"))

        let encoded = try JSONEncoder().encode(WorkTaskID(rawValue: "wt_fixed"))
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #""wt_fixed""#)
        XCTAssertEqual(
            try JSONDecoder().decode(WorkTaskID.self, from: encoded),
            WorkTaskID(rawValue: "wt_fixed"))
    }

    func testTaskContractLegacyDecodeLeavesPlanningScopeNil() throws {
        let json = #"{"id":"task_legacy","kind":"agent_invocation","assignee":"worker","objective":"inspect","roleHint":"reader","expectedDeliverable":"report","relatedAgents":[],"relatedTasks":[],"constraints":[]}"#
        let contract = try JSONDecoder().decode(TaskContract.self, from: Data(json.utf8))
        XCTAssertNil(contract.workTaskID)
        XCTAssertNil(contract.continuationRunID)
        XCTAssertNil(contract.goalID)

        let scoped = TaskContract(
            id: TaskID(rawValue: "task_scoped"),
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "worker"),
            workTaskID: WorkTaskID(rawValue: "wt_scoped"),
            continuationRunID: runID,
            goalID: goalID,
            objective: "implement",
            roleHint: "worker",
            expectedDeliverable: "patch")
        XCTAssertEqual(
            try JSONDecoder().decode(TaskContract.self, from: JSONEncoder().encode(scoped)),
            scoped)
    }

    func testTaskFailedPayloadRoundTripPreservesFailureCode() throws {
        let payload = TaskFailedPayload(
            taskID: TaskID(rawValue: "task_usage_limit"),
            agent: AgentID(rawValue: "worker"),
            error: "Provider usage limit reached.",
            failureCode: .providerUsageLimit)

        let decoded = try roundTrip(payload)

        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.failureCode, .providerUsageLimit)
    }

    func testLegacyTaskFailedPayloadWithoutFailureCodeDecodesNil() throws {
        let json = #"{"taskID":"task_legacy_failure","agent":"worker","error":"legacy failure"}"#

        let decoded = try JSONDecoder().decode(
            TaskFailedPayload.self,
            from: Data(json.utf8))

        XCTAssertEqual(decoded.taskID, TaskID(rawValue: "task_legacy_failure"))
        XCTAssertEqual(decoded.agent, AgentID(rawValue: "worker"))
        XCTAssertEqual(decoded.error, "legacy failure")
        XCTAssertNil(decoded.failureCode)
    }

    func testDomainModelsCodableRoundTrip() throws {
        let evidence = TaskEvidence(
            kind: "test",
            reference: "swift test",
            summary: "passed",
            recordedAt: now)
        let task = WorkTask(
            id: WorkTaskID(rawValue: "wt_roundtrip"),
            title: "Protocol",
            description: "Implement durable protocol",
            acceptanceCriteria: ["round trips"],
            expectedArtifacts: ["WorkTask.swift"],
            status: .completed,
            priority: .high,
            progressNote: "done",
            result: "implemented",
            evidence: [evidence],
            latestInvocationIDs: [TaskID(rawValue: "task_invocation")],
            createdAt: now,
            completedAt: now,
            revision: 3)
        XCTAssertEqual(try roundTrip(task), task)

        let audit = completionAudit(requirementTexts: [
            "Ship Task and Goal",
            "tests pass",
            "preserve legacy logs",
        ])
        let goal = Goal(
            id: goalID,
            sessionID: session,
            objective: "Ship Task and Goal",
            successCriteria: ["tests pass"],
            constraints: ["preserve legacy logs"],
            status: .completed,
            revision: 4,
            tokenBudget: 10_000,
            tokensUsed: 2_000,
            activeElapsedSeconds: 42,
            latestAudit: audit,
            createdAt: now,
            updatedAt: now,
            completedAt: now)
        XCTAssertEqual(try roundTrip(goal), goal)

        let run = ContinuationRun(
            id: runID,
            sessionID: session,
            goalID: goalID,
            ordinal: 2,
            status: .checkpointed,
            startedAt: now,
            progressSummary: "protocol complete")
        XCTAssertEqual(try roundTrip(run), run)
    }

    func testWorkTaskStatusMachineAndCompletionRequirements() throws {
        XCTAssertTrue(WorkTaskStatus.pending.canTransition(to: .ready))
        XCTAssertFalse(WorkTaskStatus.pending.canTransition(to: .completed))
        XCTAssertFalse(WorkTaskStatus.completed.canTransition(to: .inProgress))
        XCTAssertFalse(WorkTaskStatus.failed.canTransition(to: .ready))
        XCTAssertTrue(WorkTaskStatus.failed.canTransition(to: .ready, isRetry: true))

        let id = WorkTaskID(rawValue: "wt_settlement")
        var graph = WorkTaskGraph()
        XCTAssertSuccess(graph.add(WorkTask(
            id: id,
            title: "Verify",
            description: "Run tests",
            acceptanceCriteria: ["tests pass"],
            status: .ready,
            createdAt: now)))
        XCTAssertSuccess(graph.transition(
            taskID: id,
            to: .inProgress,
            expectedRevision: 0,
            updatedAt: now.addingTimeInterval(1)))

        XCTAssertFailure(
            graph.transition(
                taskID: id,
                to: .completed,
                expectedRevision: 1,
                updatedAt: now.addingTimeInterval(2)),
            kind: .missingCompletionResult)
        XCTAssertFailure(
            graph.transition(
                taskID: id,
                to: .completed,
                expectedRevision: 1,
                result: "done",
                updatedAt: now.addingTimeInterval(2)),
            kind: .missingCompletionEvidence)

        let completed = try XCTUnwrap(success(graph.transition(
            taskID: id,
            to: .completed,
            expectedRevision: 1,
            result: "done",
            evidence: [TaskEvidence(kind: "test", reference: "swift test", summary: "passed", recordedAt: now)],
            updatedAt: now.addingTimeInterval(2))))
        XCTAssertEqual(completed.revision, 2)
        XCTAssertTrue(completed.hasValidCompletionEvidence)
    }

    func testWorkTaskGraphRejectsMissingSelfCycleAndStaleRevision() throws {
        let aID = WorkTaskID(rawValue: "wt_a")
        let bID = WorkTaskID(rawValue: "wt_b")
        var graph = WorkTaskGraph()

        XCTAssertFailure(graph.add(WorkTask(
            id: WorkTaskID(rawValue: "wt_missing"),
            title: "missing",
            description: "missing",
            dependsOn: [aID])), kind: .missingDependency)
        XCTAssertFailure(graph.add(WorkTask(
            id: WorkTaskID(rawValue: "wt_self"),
            title: "self",
            description: "self",
            dependsOn: [WorkTaskID(rawValue: "wt_self")])), kind: .selfDependency)

        XCTAssertSuccess(graph.add(WorkTask(
            id: aID,
            title: "A",
            description: "first",
            status: .ready,
            createdAt: now)))
        XCTAssertSuccess(graph.add(WorkTask(
            id: bID,
            title: "B",
            description: "second",
            dependsOn: [aID],
            createdAt: now)))

        let unordered = WorkTaskGraph.validating([
            WorkTask(
                id: bID,
                title: "B",
                description: "second",
                dependsOn: [aID],
                createdAt: now),
            WorkTask(
                id: aID,
                title: "A",
                description: "first",
                status: .ready,
                createdAt: now),
        ])
        XCTAssertNoThrow(try unordered.get())
        XCTAssertFailureGraph(
            WorkTaskGraph.validating([
                try XCTUnwrap(graph.task(aID)),
                try XCTUnwrap(graph.task(aID)),
            ]),
            kind: .duplicateTaskID)
        XCTAssertFailure(graph.updateDependencies(
            taskID: aID,
            dependsOn: [bID],
            expectedRevision: 0,
            updatedAt: now), kind: .cycleDetected)

        var changed = try XCTUnwrap(graph.task(aID))
        changed.title = "changed"
        XCTAssertFailure(graph.update(
            changed,
            expectedRevision: 99,
            updatedAt: now), kind: .staleRevision)
    }

    func testGoalAndContinuationRunStateMachines() throws {
        let goal = Goal(
            id: goalID,
            sessionID: session,
            objective: "finish",
            successCriteria: ["verified"],
            constraints: ["stay local"],
            createdAt: now)
        let empty = GoalAuditSummary(verdict: .complete, progressMade: true, auditedAt: now)
        XCTAssertFalse(empty.isCompletionProof)
        let audit = completionAudit(requirementTexts: goal.completionRequirementTexts)
        XCTAssertTrue(audit.isCompletionProof)
        XCTAssertTrue(audit.isCompletionProof(for: goal))

        XCTAssertFailure(goal.transitioning(
            to: .completed,
            expectedRevision: 0,
            audit: empty,
            at: now), goalKind: .invalidCompletionAudit)
        let completed = try XCTUnwrap(goalSuccess(goal.transitioning(
            to: .completed,
            expectedRevision: 0,
            audit: audit,
            at: now)))
        XCTAssertEqual(completed.status, .completed)
        XCTAssertFailure(completed.transitioning(
            to: .active,
            expectedRevision: 1,
            at: now), goalKind: .invalidStatusTransition)

        let run = ContinuationRun(
            id: runID,
            sessionID: session,
            goalID: goalID,
            ordinal: 1,
            startedAt: now)
        let running = try XCTUnwrap(runSuccess(run.transitioning(to: .running, at: now)))
        let checkpointed = try XCTUnwrap(runSuccess(running.transitioning(
            to: .checkpointed,
            progressSummary: "checkpoint",
            at: now)))
        let ended = try XCTUnwrap(runSuccess(checkpointed.transitioning(to: .completed, at: now)))
        XCTAssertTrue(ended.status.isTerminal)
        XCTAssertNotNil(ended.endedAt)
        XCTAssertNil(runSuccess(ended.transitioning(to: .running, at: now)))
    }

    func testGoalEditInvalidatesPriorAuditAndProgressStreaks() throws {
        let audit = GoalAuditSummary(
            verdict: .blockedCandidate,
            requirements: [GoalRequirementAudit(
                id: "objective",
                text: "old objective",
                status: .unproven,
                gap: "old blocker")],
            progressMade: false,
            remainingWork: ["old work"],
            blocker: "old blocker",
            auditedAt: now)
        let goal = Goal(
            id: goalID,
            sessionID: session,
            objective: "old objective",
            status: .paused,
            revision: 4,
            latestAudit: audit,
            blockerFingerprint: "old blocker",
            consecutiveBlockedRuns: 2,
            noProgressRuns: 2,
            createdAt: now,
            updatedAt: now)

        let edited = try goal.edited(
            objective: "new objective",
            successCriteria: ["new criterion"],
            constraints: ["new constraint"],
            tokenBudget: 100,
            expectedRevision: 4,
            at: now).get()

        XCTAssertEqual(edited.status, .paused)
        XCTAssertEqual(edited.revision, 5)
        XCTAssertNil(edited.latestAudit)
        XCTAssertNil(edited.blockerFingerprint)
        XCTAssertEqual(edited.consecutiveBlockedRuns, 0)
        XCTAssertEqual(edited.noProgressRuns, 0)
    }

    func testGoalCompletionProofRequiresEvidenceNoRemainingWorkNoBlockerAndFullCoverage() {
        let goal = Goal(
            id: goalID,
            sessionID: session,
            objective: "Finish\nFeature",
            successCriteria: ["Tests pass", "Artifact exists"],
            constraints: ["Stay local"],
            createdAt: now)
        let proof = completionAudit(requirementTexts: [
            "  finish   feature  ",
            "TESTS PASS",
            "Artifact exists",
            "stay\nlocal",
        ])

        XCTAssertTrue(proof.isCompletionProof)
        XCTAssertTrue(proof.isCompletionProof(for: goal))

        for index in proof.requirements.indices {
            var omitted = proof
            omitted.requirements.remove(at: index)
            XCTAssertTrue(omitted.isCompletionProof)
            XCTAssertFalse(
                omitted.isCompletionProof(for: goal),
                "omitting Goal requirement at index \(index) must fail completion")
        }

        var withoutEvidence = proof
        withoutEvidence.requirements[0].evidence = []
        XCTAssertFalse(withoutEvidence.isCompletionProof)
        XCTAssertFalse(withoutEvidence.isCompletionProof(for: goal))

        var withRemainingWork = proof
        withRemainingWork.remainingWork = ["one required check remains"]
        XCTAssertFalse(withRemainingWork.isCompletionProof)
        XCTAssertFalse(withRemainingWork.isCompletionProof(for: goal))

        var withBlocker = proof
        withBlocker.blocker = "Waiting for approval"
        XCTAssertFalse(withBlocker.isCompletionProof)
        XCTAssertFalse(withBlocker.isCompletionProof(for: goal))

        var whitespaceBlocker = proof
        whitespaceBlocker.blocker = " \n\t "
        XCTAssertTrue(whitespaceBlocker.isCompletionProof(for: goal))

        XCTAssertFailure(goal.transitioning(
            to: .completed,
            expectedRevision: 0,
            audit: withRemainingWork,
            at: now), goalKind: .invalidCompletionAudit)
    }

    func testAllTaskGoalRunEventsRoundTripWithStableTypeTags() throws {
        let task = WorkTask(
            id: WorkTaskID(rawValue: "wt_event"),
            title: "Event",
            description: "Round trip",
            status: .inProgress,
            createdAt: now,
            revision: 1)
        let evidence = TaskEvidence(kind: "test", reference: "swift test", summary: "passed", recordedAt: now)
        let audit = completionAudit(requirementTexts: ["Round trip events", "all tags"])
        let goal = Goal(
            id: goalID,
            sessionID: session,
            objective: "Round trip events",
            successCriteria: ["all tags"],
            latestAudit: audit,
            createdAt: now)
        let run = ContinuationRun(
            id: runID,
            sessionID: session,
            goalID: goalID,
            status: .running,
            startedAt: now)
        let events: [(Event, String)] = [
            (.workTaskCreated(.init(task: task)), "work_task_created"),
            (.workTaskUpdated(.init(task: task, previousRevision: 0)), "work_task_updated"),
            (.workTaskDependencyChanged(.init(task: task, previousDependencies: [])), "work_task_dependency_changed"),
            (.workTaskReady(.init(task: task)), "work_task_ready"),
            (.workTaskStarted(.init(task: task)), "work_task_started"),
            (.workTaskProgressed(.init(task: task)), "work_task_progressed"),
            (.workTaskBlocked(.init(task: task, blocker: "blocked")), "work_task_blocked"),
            (.workTaskCompleted(.init(task: task)), "work_task_completed"),
            (.workTaskFailed(.init(task: task, error: "failed")), "work_task_failed"),
            (.workTaskCancelled(.init(task: task, reason: "cancelled")), "work_task_cancelled"),
            (.workTaskInvocationLinked(.init(task: task, invocationID: TaskID(rawValue: "task_1"))), "work_task_invocation_linked"),
            (.workTaskEvidenceAdded(.init(task: task, evidence: evidence)), "work_task_evidence_added"),
            (.goalCreated(.init(goal: goal)), "goal_created"),
            (.goalEdited(.init(goal: goal, previousRevision: 0)), "goal_edited"),
            (.goalPaused(.init(goal: goal)), "goal_paused"),
            (.goalResumed(.init(goal: goal)), "goal_resumed"),
            (.goalAuditCompleted(.init(goal: goal, audit: audit, runID: runID)), "goal_audit_completed"),
            (.goalContinuationScheduled(.init(goal: goal, runID: runID)), "goal_continuation_scheduled"),
            (.goalProgressed(.init(goal: goal, runID: runID, progressSummary: "progress")), "goal_progressed"),
            (.goalBlocked(.init(goal: goal, blocker: "blocked")), "goal_blocked"),
            (.goalBudgetLimited(.init(goal: goal)), "goal_budget_limited"),
            (.goalUsageLimited(.init(goal: goal, reason: "quota")), "goal_usage_limited"),
            (.goalCompleted(.init(goal: goal, audit: audit)), "goal_completed"),
            (.goalCleared(.init(goal: goal, reason: "user")), "goal_cleared"),
            (.continuationRunCreated(.init(run: run)), "continuation_run_created"),
            (.continuationRunStarted(.init(run: run)), "continuation_run_started"),
            (.continuationRunCheckpointed(.init(run: run)), "continuation_run_checkpointed"),
            (.continuationRunCloseRequested(.init(
                sessionID: session,
                runID: runID,
                goalID: goalID,
                requestedOutcome: .completed,
                source: .mainAgent,
                reason: "verified",
                requestedAt: now)), "continuation_run_close_requested"),
            (.continuationRunCompleted(.init(run: run)), "continuation_run_completed"),
            (.continuationRunInterrupted(.init(run: run, reason: "runtime")), "continuation_run_interrupted"),
            (.continuationRunCancelled(.init(run: run, reason: "user")), "continuation_run_cancelled"),
        ]

        for (index, pair) in events.enumerated() {
            let envelope = Envelope(
                seq: index,
                ts: now,
                session: session,
                event: pair.0)
            let data = try Envelope.makeEncoder().encode(envelope)
            XCTAssertEqual(
                try Envelope.makeDecoder().decode(Envelope.self, from: data),
                envelope,
                "failed event \(pair.1)")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["type"] as? String, pair.1)
            XCTAssertEqual(object["v"] as? Int, 1)
        }
    }

    func testLegacyGoalCompletedEventWithoutPayloadAuditStillDecodes() throws {
        let audit = completionAudit(requirementTexts: ["legacy completion"])
        let goal = Goal(
            id: goalID,
            sessionID: session,
            objective: "legacy completion",
            status: .completed,
            revision: 1,
            latestAudit: audit,
            createdAt: now,
            updatedAt: now,
            completedAt: now)
        let envelope = Envelope(
            seq: 0,
            ts: now,
            session: session,
            event: .goalCompleted(.init(goal: goal)))

        let data = try Envelope.makeEncoder().encode(envelope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertNil(payload["audit"])

        let decoded = try Envelope.makeDecoder().decode(Envelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
    }

    private func completionAudit(requirementTexts: [String] = ["tests pass"]) -> GoalAuditSummary {
        let evidence = TaskEvidence(
            kind: "test",
            reference: "swift test",
            summary: "passed",
            recordedAt: now)
        return GoalAuditSummary(
            verdict: .complete,
            requirements: requirementTexts.enumerated().map { offset, text in
                GoalRequirementAudit(
                    id: "req_\(offset + 1)",
                    text: text,
                    status: .proven,
                    evidence: [evidence])
            },
            progressMade: true,
            auditedAt: now)
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func success(_ result: Result<WorkTask, WorkTaskGraphViolation>) -> WorkTask? {
        if case .success(let value) = result { return value }
        return nil
    }

    private func goalSuccess(_ result: Result<Goal, GoalMutationViolation>) -> Goal? {
        if case .success(let value) = result { return value }
        return nil
    }

    private func runSuccess(_ result: Result<ContinuationRun, ContinuationRunViolation>) -> ContinuationRun? {
        if case .success(let value) = result { return value }
        return nil
    }

    private func XCTAssertSuccess(_ result: Result<WorkTask, WorkTaskGraphViolation>,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        if case .failure(let error) = result {
            XCTFail("unexpected failure: \(error)", file: file, line: line)
        }
    }

    private func XCTAssertFailure(_ result: Result<WorkTask, WorkTaskGraphViolation>,
                                  kind: WorkTaskGraphViolation.Kind,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        guard case .failure(let error) = result else {
            return XCTFail("expected failure", file: file, line: line)
        }
        XCTAssertEqual(error.kind, kind, file: file, line: line)
    }

    private func XCTAssertFailure(_ result: Result<Goal, GoalMutationViolation>,
                                  goalKind: GoalMutationViolation.Kind,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        guard case .failure(let error) = result else {
            return XCTFail("expected failure", file: file, line: line)
        }
        XCTAssertEqual(error.kind, goalKind, file: file, line: line)
    }

    private func XCTAssertFailureGraph(_ result: Result<WorkTaskGraph, WorkTaskGraphViolation>,
                                       kind: WorkTaskGraphViolation.Kind,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        guard case .failure(let error) = result else {
            return XCTFail("expected graph failure", file: file, line: line)
        }
        XCTAssertEqual(error.kind, kind, file: file, line: line)
    }
}
