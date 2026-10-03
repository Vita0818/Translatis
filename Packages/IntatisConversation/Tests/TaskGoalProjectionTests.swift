import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisConversation

final class TaskGoalProjectionTests: XCTestCase {
    private let session = SessionID(rawValue: "sess_task_goal_projection")
    private let goalID = GoalID(rawValue: "goal_projection")
    private let runID = ContinuationRunID(rawValue: "run_projection")
    private let workTaskID = WorkTaskID(rawValue: "wt_projection")
    private let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testProjectionSeparatesInvocationCompletionFromWorkTaskSettlement() throws {
        let task = workTask(status: .ready, revision: 0)
        let invocation = TaskContract(
            id: TaskID(rawValue: "task_invocation"),
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "worker"),
            workTaskID: workTaskID,
            continuationRunID: runID,
            goalID: goalID,
            objective: "execute work task",
            roleHint: "worker",
            expectedDeliverable: "candidate result")

        let projection = CoworkProjection.build(from: [
            envelope(0, .workTaskCreated(.init(task: task))),
            envelope(1, .taskCreated(.init(contract: invocation))),
            envelope(2, .taskCompleted(.init(
                taskID: invocation.id,
                agent: invocation.assignee,
                result: "candidate result"))),
        ])

        XCTAssertEqual(projection.tasks[invocation.id]?.status, .completed)
        XCTAssertEqual(projection.workTasks[workTaskID]?.status, .ready)
        XCTAssertNil(projection.workTasks[workTaskID]?.result)
    }

    func testProjectionFoldsGoalRunWorkTaskAndKeepsCompletedGoalCurrent() throws {
        let goal = activeGoal(id: goalID, revision: 0)
        let run = ContinuationRun(
            id: runID,
            sessionID: session,
            goalID: goalID,
            ordinal: 0,
            status: .created,
            startedAt: createdAt)
        let ready = workTask(status: .ready, revision: 0)
        var started = ready
        started.status = .inProgress
        started.revision = 1
        started.updatedAt = createdAt.addingTimeInterval(1)
        var completedTask = started
        completedTask.status = .completed
        completedTask.result = "implemented"
        completedTask.evidence = [evidence()]
        completedTask.completedAt = createdAt.addingTimeInterval(2)
        completedTask.updatedAt = createdAt.addingTimeInterval(2)
        completedTask.revision = 2

        let audit = completionAudit()
        var auditedGoal = goal
        auditedGoal.latestAudit = audit
        auditedGoal.revision = 1
        auditedGoal.updatedAt = createdAt.addingTimeInterval(3)
        var completedGoal = auditedGoal
        completedGoal.status = .completed
        completedGoal.revision = 2
        completedGoal.updatedAt = createdAt.addingTimeInterval(4)
        completedGoal.completedAt = createdAt.addingTimeInterval(4)

        var runningRun = run
        runningRun.status = .running
        var endedRun = runningRun
        endedRun.status = .completed
        endedRun.endedAt = createdAt.addingTimeInterval(4)
        endedRun.progressSummary = "complete"

        var projection = CoworkProjection.build(from: [
            envelope(0, .goalCreated(.init(goal: goal))),
            envelope(1, .continuationRunCreated(.init(run: run))),
            envelope(2, .continuationRunStarted(.init(run: runningRun))),
            envelope(3, .workTaskCreated(.init(task: ready))),
            envelope(4, .workTaskStarted(.init(task: started))),
            envelope(5, .workTaskCompleted(.init(task: completedTask))),
            envelope(6, .goalAuditCompleted(.init(goal: auditedGoal, audit: audit, runID: runID))),
            envelope(7, .continuationRunCompleted(.init(run: endedRun))),
            envelope(8, .goalCompleted(.init(goal: completedGoal, audit: audit))),
        ])

        XCTAssertEqual(projection.workTasks[workTaskID], completedTask)
        XCTAssertEqual(projection.goals[goalID], completedGoal)
        XCTAssertEqual(projection.continuationRuns[runID], endedRun)
        XCTAssertEqual(projection.currentGoalID, goalID)
        XCTAssertEqual(projection.currentGoal?.status, .completed)
        XCTAssertNoThrow(try projection.workTaskGraph.validate().get())

        let nextID = GoalID(rawValue: "goal_next")
        let next = activeGoal(id: nextID, revision: 0)
        projection.apply(envelope(9, .goalCreated(.init(goal: next))))
        XCTAssertEqual(projection.currentGoalID, nextID)

        projection.apply(envelope(10, .goalCleared(.init(goal: next, reason: "user clear"))))
        XCTAssertNil(projection.currentGoalID)
        XCTAssertEqual(projection.goals[nextID], next)
    }

    func testProjectionRejectsStaleRevisionAndTerminalRegression() throws {
        let ready = workTask(status: .ready, revision: 0)
        var running = ready
        running.status = .inProgress
        running.revision = 1
        running.updatedAt = createdAt.addingTimeInterval(1)
        var stale = ready
        stale.title = "stale overwrite"
        stale.revision = 0
        var completed = running
        completed.status = .completed
        completed.result = "done"
        completed.evidence = [evidence()]
        completed.revision = 2
        completed.updatedAt = createdAt.addingTimeInterval(2)
        completed.completedAt = createdAt.addingTimeInterval(2)
        var regressed = completed
        regressed.status = .inProgress
        regressed.revision = 3
        regressed.result = nil
        regressed.completedAt = nil

        let goal = activeGoal(id: goalID, revision: 0)
        let audit = completionAudit()
        var completedGoal = goal
        completedGoal.status = .completed
        completedGoal.latestAudit = audit
        completedGoal.revision = 1
        completedGoal.updatedAt = createdAt.addingTimeInterval(2)
        completedGoal.completedAt = createdAt.addingTimeInterval(2)
        var regressedGoal = completedGoal
        regressedGoal.status = .active
        regressedGoal.revision = 2
        regressedGoal.completedAt = nil

        let projection = CoworkProjection.build(from: [
            envelope(0, .workTaskCreated(.init(task: ready))),
            envelope(1, .workTaskStarted(.init(task: running))),
            envelope(2, .workTaskUpdated(.init(task: stale))),
            envelope(3, .workTaskCompleted(.init(task: completed))),
            envelope(4, .workTaskProgressed(.init(task: regressed))),
            envelope(5, .goalCreated(.init(goal: goal))),
            envelope(6, .goalCompleted(.init(goal: completedGoal, audit: audit))),
            envelope(7, .goalProgressed(.init(goal: regressedGoal))),
        ])

        XCTAssertEqual(projection.workTasks[workTaskID], completed)
        XCTAssertEqual(projection.goals[goalID], completedGoal)
        XCTAssertEqual(projection.currentGoalID, goalID)
    }

    func testProjectionRejectsCompletedGoalWithoutFullCompletionProof() {
        let active = activeGoal(id: goalID, revision: 0)
        let proof = completionAudit()
        var invalidAudits: [(String, GoalAuditSummary)] = []

        for index in proof.requirements.indices {
            var omitted = proof
            omitted.requirements.remove(at: index)
            invalidAudits.append(("missing requirement \(index)", omitted))
        }

        var withoutEvidence = proof
        withoutEvidence.requirements[0].evidence = []
        invalidAudits.append(("missing evidence", withoutEvidence))

        var withRemainingWork = proof
        withRemainingWork.remainingWork = ["finish replay validation"]
        invalidAudits.append(("remaining work", withRemainingWork))

        var withBlocker = proof
        withBlocker.blocker = "external approval pending"
        invalidAudits.append(("blocker", withBlocker))

        for (reason, audit) in invalidAudits {
            var completed = active
            completed.status = .completed
            completed.latestAudit = audit
            completed.revision = 1
            completed.updatedAt = createdAt.addingTimeInterval(1)
            completed.completedAt = createdAt.addingTimeInterval(1)

            let projection = CoworkProjection.build(from: [
                envelope(0, .goalCreated(.init(goal: active))),
                envelope(1, .goalCompleted(.init(goal: completed, audit: audit))),
            ])
            XCTAssertEqual(projection.goals[goalID], active, reason)
            XCTAssertEqual(projection.currentGoal?.status, .active, reason)

            let orphanProjection = CoworkProjection.build(from: [
                envelope(0, .goalCompleted(.init(goal: completed, audit: audit))),
            ])
            XCTAssertNil(orphanProjection.goals[goalID], reason)
        }
    }

    func testProjectionRejectsContradictoryCompletionAuditsAndAcceptsLegacyPayloadProof() {
        let active = activeGoal(id: goalID, revision: 0)
        let proof = completionAudit()
        var completed = active
        completed.status = .completed
        completed.revision = 1
        completed.updatedAt = createdAt.addingTimeInterval(1)
        completed.completedAt = createdAt.addingTimeInterval(1)

        var contradictory = proof
        contradictory.requirements[0].text = "different objective"
        completed.latestAudit = proof
        let rejected = CoworkProjection.build(from: [
            envelope(0, .goalCreated(.init(goal: active))),
            envelope(1, .goalCompleted(.init(goal: completed, audit: contradictory))),
        ])
        XCTAssertEqual(rejected.goals[goalID], active)

        completed.latestAudit = nil
        let accepted = CoworkProjection.build(from: [
            envelope(0, .goalCreated(.init(goal: active))),
            envelope(1, .goalCompleted(.init(goal: completed, audit: proof))),
        ])
        var expected = completed
        expected.latestAudit = proof
        XCTAssertEqual(accepted.goals[goalID], expected)
        XCTAssertEqual(accepted.currentGoal?.status, .completed)
    }

    func testInterruptedContinuationRunCannotBeReopened() {
        let created = ContinuationRun(
            id: runID,
            sessionID: session,
            goalID: goalID,
            status: .created,
            startedAt: createdAt)
        var running = created
        running.status = .running
        var interrupted = running
        interrupted.status = .interrupted
        interrupted.progressSummary = "provider unavailable"
        interrupted.endedAt = createdAt.addingTimeInterval(5)
        var invalidRestart = interrupted
        invalidRestart.status = .running
        invalidRestart.endedAt = nil

        let projection = CoworkProjection.build(from: [
            envelope(0, .continuationRunCreated(.init(run: created))),
            envelope(1, .continuationRunStarted(.init(run: running))),
            envelope(2, .continuationRunInterrupted(.init(
                run: interrupted,
                reason: "provider unavailable"))),
            envelope(3, .continuationRunStarted(.init(run: invalidRestart))),
        ])

        XCTAssertEqual(projection.continuationRuns[runID], interrupted)
    }

    func testEventLogReopenRebuildsTaskGoalRunProjection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-task-goal-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let goal = activeGoal(id: goalID, revision: 0)
        let run = ContinuationRun(
            id: runID,
            sessionID: session,
            goalID: goalID,
            status: .created,
            startedAt: createdAt)
        let task = workTask(status: .ready, revision: 0)
        let log = try EventLog(session: session, fileURL: url)
        _ = try await log.append([
            .goalCreated(.init(goal: goal)),
            .continuationRunCreated(.init(run: run)),
            .workTaskCreated(.init(task: task)),
        ], ts: createdAt)

        let reopened = try EventLog(session: session, fileURL: url)
        let replayed = await reopened.replay()
        let projection = CoworkProjection.build(from: replayed)

        XCTAssertEqual(replayed.map(\.seq), [0, 1, 2])
        XCTAssertEqual(projection.currentGoalID, goalID)
        XCTAssertEqual(projection.goals[goalID], goal)
        XCTAssertEqual(projection.continuationRuns[runID], run)
        XCTAssertEqual(projection.workTasks[workTaskID], task)
    }

    private func envelope(_ seq: Int, _ event: Event) -> Envelope {
        Envelope(
            seq: seq,
            ts: createdAt.addingTimeInterval(Double(seq)),
            session: session,
            event: event)
    }

    private func workTask(status: WorkTaskStatus, revision: Int) -> WorkTask {
        WorkTask(
            id: workTaskID,
            title: "Implement projection",
            description: "Fold durable Task/Goal events",
            acceptanceCriteria: ["recovery works"],
            status: status,
            createdAt: createdAt,
            revision: revision)
    }

    private func activeGoal(id: GoalID, revision: Int) -> Goal {
        Goal(
            id: id,
            sessionID: session,
            objective: "Implement Task and Goal",
            successCriteria: ["recovery works"],
            constraints: ["preserve legacy logs"],
            revision: revision,
            createdAt: createdAt)
    }

    private func evidence() -> TaskEvidence {
        TaskEvidence(
            kind: "test",
            reference: "swift test --filter TaskGoalProjectionTests",
            summary: "passed",
            recordedAt: createdAt)
    }

    private func completionAudit() -> GoalAuditSummary {
        let proof = evidence()
        return GoalAuditSummary(
            verdict: .complete,
            requirements: [
                GoalRequirementAudit(
                    id: "objective",
                    text: "  implement   TASK and goal ",
                    status: .proven,
                    evidence: [proof]),
                GoalRequirementAudit(
                    id: "success_criterion_1",
                    text: "RECOVERY WORKS",
                    status: .proven,
                    evidence: [proof]),
                GoalRequirementAudit(
                    id: "constraint_1",
                    text: "preserve\nlegacy logs",
                    status: .proven,
                    evidence: [proof]),
            ],
            progressMade: true,
            auditedAt: createdAt)
    }
}
