import XCTest
import IntatisCore
import IntatisProtocol
import IntatisProviders
@testable import IntatisAgentKernel

final class ModelHistoryProjectionTests: XCTestCase {
    private let session = SessionID(rawValue: "sess_model_projection")
    private let main = AgentID(rawValue: "main")
    private let other = AgentID(rawValue: "other")

    func testProjectsLegacyAndDirectTurnsInSubmissionOrderAndNormalizesToolPairs() throws {
        let legacyID = SubmissionID(rawValue: "sub_legacy")
        let directID = SubmissionID(rawValue: "sub_direct")
        let currentID = SubmissionID(rawValue: "sub_current")
        let legacyTask = rootTask("task_legacy", legacyID, "legacy U")
        let directTask = rootTask("task_direct", directID, "direct U")
        let currentTask = rootTask("task_current", currentID, "current U")
        let turnID = TurnID(rawValue: "turn_direct")

        let events = [
            envelope(1, .userMessage(UserMessagePayload(
                text: "legacy U",
                to: main,
                submissionID: legacyID))),
            envelope(2, .taskCreated(TaskCreatedPayload(contract: legacyTask))),
            envelope(3, .taskCompleted(TaskCompletedPayload(
                taskID: legacyTask.id,
                agent: main,
                result: "legacy A"))),
            envelope(4, .userMessage(UserMessagePayload(
                text: "direct U",
                to: main,
                submissionID: directID))),
            envelope(5, .taskCreated(TaskCreatedPayload(contract: directTask))),
            envelope(6, .modelHistoryItem(.message(
                itemID: "direct-user",
                turnID: turnID,
                agent: main,
                taskID: directTask.id,
                submissionID: directID,
                taskAttempt: 1,
                role: .user,
                content: "direct U"))),
            // This output has no matching call and must not be sent.
            envelope(7, .modelHistoryItem(.functionCallOutput(
                itemID: "orphan-output",
                turnID: turnID,
                agent: main,
                taskID: directTask.id,
                submissionID: directID,
                taskAttempt: 1,
                callID: "orphan",
                output: "must disappear"))),
            envelope(8, .modelHistoryItem(.functionCallBatch(
                itemID: "direct-calls",
                turnID: turnID,
                agent: main,
                taskID: directTask.id,
                submissionID: directID,
                taskAttempt: 1,
                content: "checking",
                calls: [
                    ModelHistoryFunctionCall(
                        callID: "call_a",
                        name: "read_file",
                        arguments: #"{"path":"A"}"#),
                    ModelHistoryFunctionCall(
                        callID: "call_b",
                        name: "read_file",
                        arguments: #"{"path":"B"}"#),
                ]))),
            // Completion order does not decide provider order.
            envelope(9, .modelHistoryItem(.functionCallOutput(
                itemID: "output-b",
                turnID: turnID,
                agent: main,
                taskID: directTask.id,
                submissionID: directID,
                taskAttempt: 1,
                callID: "call_b",
                output: "B result"))),
            envelope(10, .modelHistoryItem(.message(
                itemID: "direct-assistant",
                turnID: turnID,
                agent: main,
                taskID: directTask.id,
                submissionID: directID,
                taskAttempt: 1,
                role: .assistant,
                content: "direct A"))),
            envelope(11, .userMessage(UserMessagePayload(
                text: "current U",
                to: main,
                submissionID: currentID))),
            envelope(12, .taskCreated(TaskCreatedPayload(contract: currentTask))),
        ]

        let messages = try AgentModelHistoryProjector().project(
            agentID: main,
            currentTask: currentTask,
            events: events)

        XCTAssertEqual(messages.count, 7)
        XCTAssertEqual(messages[0], .user("legacy U"))
        XCTAssertEqual(messages[1], .assistant("legacy A"))
        XCTAssertEqual(messages[2], .user("direct U"))
        XCTAssertEqual(messages[3].role, .assistant)
        XCTAssertEqual(messages[3].content, "checking")
        XCTAssertEqual(messages[3].toolCalls?.map(\.id), ["call_a", "call_b"])
        XCTAssertEqual(messages[4], .tool(id: "call_a", content: "aborted"))
        XCTAssertEqual(messages[5], .tool(id: "call_b", content: "B result"))
        XCTAssertEqual(messages[6], .assistant("direct A"))
        XCTAssertFalse(messages.contains { $0.content == "must disappear" })
    }

    func testFailedAndInterruptedTurnOutcomesDropOnlyFinalAssistantHistory() throws {
        for outcome in [TurnOutcome.failed, .interrupted] {
            let fixture = terminalOutcomeFixture(outcome: outcome)
            let messages = try AgentModelHistoryProjector().project(
                agentID: main,
                currentTask: fixture.currentTask,
                events: fixture.events)

            XCTAssertTrue(messages.contains { $0.content == "prior user" })
            XCTAssertTrue(messages.contains { $0.toolCalls?.first?.id == "read-call" })
            XCTAssertTrue(messages.contains { $0.content == "tool output" })
            XCTAssertFalse(messages.contains { $0.content == "invalid final answer" })
        }
    }

    func testCompletedAndLegacyTurnsKeepFinalAssistantHistory() throws {
        for outcome in [TurnOutcome.completed, nil] {
            let fixture = terminalOutcomeFixture(outcome: outcome)
            let messages = try AgentModelHistoryProjector().project(
                agentID: main,
                currentTask: fixture.currentTask,
                events: fixture.events)

            XCTAssertTrue(messages.contains { $0.content == "invalid final answer" })
        }
    }

    func testConflictingTurnOutcomesFailHistoryProjectionClosed() throws {
        var fixture = terminalOutcomeFixture(outcome: .failed)
        fixture.events.insert(
            envelope(8, .turnOutcome(TurnOutcomePayload(
                turnID: TurnID(rawValue: "turn_terminal_fixture"),
                outcome: .completed,
                submissionID: SubmissionID(rawValue: "sub_terminal_prior"),
                taskID: TaskID(rawValue: "task_terminal_prior"),
                agentID: main))),
            at: fixture.events.count - 2)

        XCTAssertThrowsError(try AgentModelHistoryProjector().project(
            agentID: main,
            currentTask: fixture.currentTask,
            events: fixture.events)) { error in
                XCTAssertEqual(
                    error as? AgentModelHistoryProjectionError,
                    .invalidItem(
                        "turn-outcome:turn_terminal_fixture",
                        "one turn has conflicting terminal outcomes"))
            }
    }

    func testLatestAttemptReplacesEarlierInvocationForSameSubmission() throws {
        let priorID = SubmissionID(rawValue: "sub_retry")
        let currentID = SubmissionID(rawValue: "sub_after_retry")
        let priorTask = rootTask("task_retry", priorID, "retry U")
        let currentTask = rootTask("task_after_retry", currentID, "current U")

        var events = [
            envelope(1, .userMessage(UserMessagePayload(
                text: "retry U",
                to: main,
                submissionID: priorID))),
            envelope(2, .taskCreated(TaskCreatedPayload(contract: priorTask))),
        ]
        events.append(contentsOf: invocationEvents(
            startingAt: 3,
            turnID: TurnID(rawValue: "turn_attempt_1"),
            task: priorTask,
            attempt: 1,
            answer: "old answer"))
        events.append(contentsOf: invocationEvents(
            startingAt: 5,
            turnID: TurnID(rawValue: "turn_attempt_2"),
            task: priorTask,
            attempt: 2,
            answer: "new answer"))
        events.append(envelope(7, .userMessage(UserMessagePayload(
            text: "current U",
            to: main,
            submissionID: currentID))))
        events.append(envelope(8, .taskCreated(TaskCreatedPayload(
            contract: currentTask))))

        let messages = try AgentModelHistoryProjector().project(
            agentID: main,
            currentTask: currentTask,
            events: events)

        XCTAssertEqual(messages, [
            .user("retry U"),
            .assistant("new answer"),
        ])
    }

    func testToolSearchHistoryReplaysAsDedicatedOutputWithSchemas()
        throws {
        let priorID = SubmissionID(rawValue: "sub_search")
        let currentID = SubmissionID(rawValue: "sub_after_search")
        let priorTask = rootTask(
            "task_search",
            priorID,
            "find calendar tools")
        let currentTask = rootTask(
            "task_after_search",
            currentID,
            "continue")
        let turnID = TurnID(rawValue: "turn_search")
        let deferred: JSONValue = .object([
            "type": .string("namespace"),
            "name": .string("mcp__calendar__"),
            "description": .string("Calendar tools."),
            "tools": .array([
                .object([
                    "type": .string("function"),
                    "name": .string("create_event"),
                    "description": .string("Create an event."),
                    "strict": .bool(false),
                    "defer_loading": .bool(true),
                    "parameters": .object([
                        "type": .string("object"),
                    ]),
                ]),
            ]),
        ])
        let events = [
            envelope(1, .userMessage(UserMessagePayload(
                text: priorTask.objective,
                to: main,
                submissionID: priorID))),
            envelope(2, .taskCreated(TaskCreatedPayload(
                contract: priorTask))),
            envelope(3, .modelHistoryItem(.message(
                itemID: "search-user",
                turnID: turnID,
                agent: main,
                taskID: priorTask.id,
                submissionID: priorID,
                taskAttempt: 1,
                role: .user,
                content: priorTask.objective))),
            envelope(4, .modelHistoryItem(.functionCallBatch(
                itemID: "search-call",
                turnID: turnID,
                agent: main,
                taskID: priorTask.id,
                submissionID: priorID,
                taskAttempt: 1,
                content: nil,
                calls: [
                    ModelHistoryFunctionCall(
                        callID: "search-1",
                        name: "tool_search",
                        arguments: #"{"query":"calendar"}"#,
                        kind: .toolSearch,
                        status: "completed",
                        execution: "client"),
                ]))),
            envelope(5, .modelHistoryItem(.toolSearchOutput(
                itemID: "search-output",
                turnID: turnID,
                agent: main,
                taskID: priorTask.id,
                submissionID: priorID,
                taskAttempt: 1,
                callID: "search-1",
                tools: [deferred]))),
            envelope(6, .modelHistoryItem(.message(
                itemID: "search-answer",
                turnID: turnID,
                agent: main,
                taskID: priorTask.id,
                submissionID: priorID,
                taskAttempt: 1,
                role: .assistant,
                content: "found it"))),
            envelope(7, .userMessage(UserMessagePayload(
                text: currentTask.objective,
                to: main,
                submissionID: currentID))),
            envelope(8, .taskCreated(TaskCreatedPayload(
                contract: currentTask))),
        ]

        let messages = try AgentModelHistoryProjector().project(
            agentID: main,
            currentTask: currentTask,
            events: events)

        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[1].toolCalls?.first?.kind, .toolSearch)
        XCTAssertEqual(messages[1].toolCalls?.first?.id, "search-1")
        XCTAssertEqual(
            messages[2].toolSearchOutput,
            ModelToolSearchOutput(tools: [deferred]))
        XCTAssertNil(messages[2].content)
        XCTAssertEqual(messages[3], .assistant("found it"))

        let input = AgentInputItem.from(messages: messages)
        XCTAssertTrue(input.contains {
            guard case .toolSearchOutput(
                let callID,
                let status,
                let execution,
                let tools) = $0 else {
                return false
            }
            return callID == "search-1"
                && status == "completed"
                && execution == "client"
                && tools == [deferred]
        })
    }

    func testLatestCheckpointReplacesOlderHistoryAndReplaysOnlySuffix()
        throws
    {
        let firstID = SubmissionID(rawValue: "sub_checkpoint_first")
        let suffixID = SubmissionID(rawValue: "sub_checkpoint_suffix")
        let currentID = SubmissionID(rawValue: "sub_checkpoint_current")
        let firstTask = rootTask(
            "task_checkpoint_first",
            firstID,
            "first user")
        let suffixTask = rootTask(
            "task_checkpoint_suffix",
            suffixID,
            "suffix user")
        let currentTask = rootTask(
            "task_checkpoint_current",
            currentID,
            "current user")
        let suffixTurn = TurnID(rawValue: "turn_checkpoint_suffix")
        let compacted = checkpoint(
            message: "state after first",
            replacementHistory: [
                retainedUser(
                    "retained-first",
                    submissionID: firstID,
                    content: firstTask.objective),
                summary("summary-first", "state after first"),
            ])
        let events = [
            envelope(1, .userMessage(UserMessagePayload(
                text: firstTask.objective,
                to: main,
                submissionID: firstID))),
            envelope(2, .taskCreated(TaskCreatedPayload(
                contract: firstTask))),
            envelope(3, .modelHistoryCompacted(compacted)),
            envelope(4, .userMessage(UserMessagePayload(
                text: suffixTask.objective,
                to: main,
                submissionID: suffixID))),
            envelope(5, .taskCreated(TaskCreatedPayload(
                contract: suffixTask))),
            envelope(6, .modelHistoryItem(.message(
                itemID: "suffix-user",
                turnID: suffixTurn,
                agent: main,
                taskID: suffixTask.id,
                submissionID: suffixID,
                taskAttempt: 1,
                role: .user,
                content: suffixTask.objective))),
            envelope(7, .modelHistoryItem(.message(
                itemID: "suffix-assistant",
                turnID: suffixTurn,
                agent: main,
                taskID: suffixTask.id,
                submissionID: suffixID,
                taskAttempt: 1,
                role: .assistant,
                content: "suffix answer"))),
            envelope(8, .userMessage(UserMessagePayload(
                text: currentTask.objective,
                to: main,
                submissionID: currentID))),
            envelope(9, .taskCreated(TaskCreatedPayload(
                contract: currentTask))),
        ]

        let projection = try AgentModelHistoryProjector().projectState(
            agentID: main,
            currentTask: currentTask,
            events: events)

        XCTAssertEqual(projection.messages, [
            .user(firstTask.objective),
            .user("state after first"),
            .user(suffixTask.objective),
            .assistant("suffix answer"),
        ])
        XCTAssertEqual(
            projection.realUserMessages.map(\.submissionID),
            [firstID, suffixID])
        XCTAssertEqual(projection.baseCheckpoint?.sequence, 3)
        XCTAssertEqual(projection.latestCheckpoint?.sequence, 3)
        XCTAssertEqual(projection.latestAgentHistorySequence, 7)
    }

    func testMidTurnCheckpointSuffixMayContinueWithoutAnotherUserItem()
        throws
    {
        let priorID = SubmissionID(rawValue: "sub_midturn_prior")
        let currentID = SubmissionID(rawValue: "sub_midturn_current")
        let priorTask = rootTask(
            "task_midturn_prior",
            priorID,
            "prior user")
        let currentTask = rootTask(
            "task_midturn_current",
            currentID,
            "current user")
        let turnID = TurnID(rawValue: "turn_midturn")
        let compacted = checkpoint(
            message: "state through the tool result",
            replacementHistory: [
                retainedUser(
                    "midturn-retained-user",
                    submissionID: priorID,
                    content: priorTask.objective),
                summary(
                    "midturn-summary",
                    "state through the tool result"),
            ])
        let events = [
            envelope(1, .userMessage(UserMessagePayload(
                text: priorTask.objective,
                to: main,
                submissionID: priorID))),
            envelope(2, .taskCreated(TaskCreatedPayload(
                contract: priorTask))),
            envelope(3, .modelHistoryItem(.message(
                itemID: "midturn-original-user",
                turnID: turnID,
                agent: main,
                taskID: priorTask.id,
                submissionID: priorID,
                taskAttempt: 1,
                role: .user,
                content: priorTask.objective))),
            envelope(4, .modelHistoryCompacted(compacted)),
            // The checkpoint already represents the user and earlier work.
            // A same-turn continuation must not fabricate another user item.
            envelope(5, .modelHistoryItem(.message(
                itemID: "midturn-continuation",
                turnID: turnID,
                agent: main,
                taskID: priorTask.id,
                submissionID: priorID,
                taskAttempt: 1,
                role: .assistant,
                content: "continued after compaction"))),
            envelope(6, .userMessage(UserMessagePayload(
                text: currentTask.objective,
                to: main,
                submissionID: currentID))),
            envelope(7, .taskCreated(TaskCreatedPayload(
                contract: currentTask))),
        ]

        let projection = try AgentModelHistoryProjector().projectState(
            agentID: main,
            currentTask: currentTask,
            events: events)

        XCTAssertEqual(projection.messages, [
            .user(priorTask.objective),
            .user("state through the tool result"),
            .assistant("continued after compaction"),
        ])
        XCTAssertEqual(projection.realUserMessages.count, 1)
        XCTAssertEqual(
            projection.realUserMessages.first?.submissionID,
            priorID)
    }

    func testTwoWindowCheckpointLineageSelectsNewestWindow() throws {
        let firstID = SubmissionID(rawValue: "sub_window_one")
        let secondID = SubmissionID(rawValue: "sub_window_two")
        let currentID = SubmissionID(rawValue: "sub_window_current")
        let firstTask = rootTask("task_window_one", firstID, "U1")
        let secondTask = rootTask("task_window_two", secondID, "U2")
        let currentTask = rootTask(
            "task_window_current",
            currentID,
            "U3")
        let first = checkpoint(
            message: "window one",
            replacementHistory: [
                retainedUser(
                    "window-one-user",
                    submissionID: firstID,
                    content: firstTask.objective),
                summary("window-one-summary", "window one"),
            ])
        let second = checkpoint(
            message: "window two",
            replacementHistory: [
                retainedUser(
                    "window-two-first-user",
                    submissionID: firstID,
                    content: firstTask.objective),
                retainedUser(
                    "window-two-second-user",
                    submissionID: secondID,
                    content: secondTask.objective),
                summary("window-two-summary", "window two"),
            ],
            windowNumber: 2,
            previousWindowID: firstWindowID,
            windowID: secondWindowID)
        let events = [
            envelope(1, .userMessage(UserMessagePayload(
                text: firstTask.objective,
                to: main,
                submissionID: firstID))),
            envelope(2, .taskCreated(TaskCreatedPayload(
                contract: firstTask))),
            envelope(3, .modelHistoryCompacted(first)),
            envelope(4, .userMessage(UserMessagePayload(
                text: secondTask.objective,
                to: main,
                submissionID: secondID))),
            envelope(5, .taskCreated(TaskCreatedPayload(
                contract: secondTask))),
            envelope(6, .modelHistoryCompacted(second)),
            envelope(7, .userMessage(UserMessagePayload(
                text: currentTask.objective,
                to: main,
                submissionID: currentID))),
            envelope(8, .taskCreated(TaskCreatedPayload(
                contract: currentTask))),
        ]

        let projection = try AgentModelHistoryProjector().projectState(
            agentID: main,
            currentTask: currentTask,
            events: events)

        XCTAssertEqual(projection.messages, [
            .user(firstTask.objective),
            .user(secondTask.objective),
            .user("window two"),
        ])
        XCTAssertEqual(projection.baseCheckpoint?.sequence, 6)
        XCTAssertEqual(projection.latestCheckpoint?.sequence, 6)
        XCTAssertEqual(
            projection.latestCheckpoint?.payload.windowNumber,
            2)
    }

    func testNonContiguousCheckpointLineageFailsClosed() throws {
        let firstID = SubmissionID(rawValue: "sub_bad_lineage_first")
        let secondID = SubmissionID(rawValue: "sub_bad_lineage_second")
        let currentID = SubmissionID(rawValue: "sub_bad_lineage_current")
        let firstTask = rootTask(
            "task_bad_lineage_first",
            firstID,
            "U1")
        let secondTask = rootTask(
            "task_bad_lineage_second",
            secondID,
            "U2")
        let currentTask = rootTask(
            "task_bad_lineage_current",
            currentID,
            "U3")
        let first = checkpoint(
            message: "window one",
            replacementHistory: [
                retainedUser(
                    "bad-lineage-window-one-user",
                    submissionID: firstID,
                    content: firstTask.objective),
                summary(
                    "bad-lineage-window-one-summary",
                    "window one"),
            ])
        let invalidSecond = checkpoint(
            message: "window two",
            replacementHistory: [
                retainedUser(
                    "bad-lineage-window-two-user",
                    submissionID: secondID,
                    content: secondTask.objective),
                summary(
                    "bad-lineage-window-two-summary",
                    "window two"),
            ],
            windowNumber: 2,
            // A second window must point to the first checkpoint's window,
            // not back to the initial window.
            previousWindowID: initialWindowID,
            windowID: secondWindowID)
        let events = [
            envelope(1, .userMessage(UserMessagePayload(
                text: firstTask.objective,
                to: main,
                submissionID: firstID))),
            envelope(2, .taskCreated(TaskCreatedPayload(
                contract: firstTask))),
            envelope(3, .modelHistoryCompacted(first)),
            envelope(4, .userMessage(UserMessagePayload(
                text: secondTask.objective,
                to: main,
                submissionID: secondID))),
            envelope(5, .taskCreated(TaskCreatedPayload(
                contract: secondTask))),
            envelope(6, .modelHistoryCompacted(invalidSecond)),
            envelope(7, .userMessage(UserMessagePayload(
                text: currentTask.objective,
                to: main,
                submissionID: currentID))),
            envelope(8, .taskCreated(TaskCreatedPayload(
                contract: currentTask))),
        ]

        XCTAssertThrowsError(
            try AgentModelHistoryProjector().projectState(
                agentID: main,
                currentTask: currentTask,
                events: events)
        ) { error in
            XCTAssertEqual(
                error as? AgentModelHistoryProjectionError,
                .invalidCheckpoint(
                    sequence: 6,
                    reason: "window lineage is not contiguous"))
        }
    }

    func testContextualSkillReplaysButIsNotClassifiedAsRealUser()
        throws
    {
        let priorID = SubmissionID(rawValue: "sub_contextual_skill")
        let currentID = SubmissionID(rawValue: "sub_contextual_current")
        let priorTask = rootTask(
            "task_contextual_skill",
            priorID,
            "use the selected skill")
        let currentTask = rootTask(
            "task_contextual_current",
            currentID,
            "continue")
        let skillBody =
            "<skill><name>example</name><instructions>Follow it.</instructions></skill>"
        let compacted = checkpoint(
            message: "skill-guided state",
            replacementHistory: [
                ModelHistoryReplacementItem(
                    itemID: "contextual-skill",
                    kind: .message,
                    role: .user,
                    messageClassification: .contextual,
                    content: skillBody),
                retainedUser(
                    "contextual-real-user",
                    submissionID: priorID,
                    content: priorTask.objective),
                summary(
                    "contextual-summary",
                    "skill-guided state"),
            ])
        let events = [
            envelope(1, .userMessage(UserMessagePayload(
                text: priorTask.objective,
                to: main,
                submissionID: priorID))),
            envelope(2, .taskCreated(TaskCreatedPayload(
                contract: priorTask))),
            envelope(3, .modelHistoryCompacted(compacted)),
            envelope(4, .userMessage(UserMessagePayload(
                text: currentTask.objective,
                to: main,
                submissionID: currentID))),
            envelope(5, .taskCreated(TaskCreatedPayload(
                contract: currentTask))),
        ]

        let projection = try AgentModelHistoryProjector().projectState(
            agentID: main,
            currentTask: currentTask,
            events: events)

        XCTAssertEqual(projection.messages, [
            .user(skillBody),
            .user(priorTask.objective),
            .user("skill-guided state"),
        ])
        XCTAssertEqual(projection.realUserMessages.count, 1)
        XCTAssertEqual(
            projection.realUserMessages.first?.submissionID,
            priorID)
        XCTAssertEqual(
            projection.realUserMessages.first?.content,
            priorTask.objective)
        XCTAssertFalse(
            projection.realUserMessages.contains {
                $0.content == skillBody
            })
    }

    func testCheckpointAfterQueuedCurrentAcceptanceStillBecomesBase()
        throws
    {
        let priorID = SubmissionID(rawValue: "sub_queued_prior")
        let currentID = SubmissionID(rawValue: "sub_queued_current")
        let priorTask = rootTask(
            "task_queued_prior",
            priorID,
            "prior")
        let currentTask = rootTask(
            "task_queued_current",
            currentID,
            "already queued")
        let compacted = checkpoint(
            message: "prior compacted after U2 was queued",
            replacementHistory: [
                retainedUser(
                    "queued-prior-user",
                    submissionID: priorID,
                    content: priorTask.objective),
                summary(
                    "queued-prior-summary",
                    "prior compacted after U2 was queued"),
            ])
        let events = [
            envelope(1, .userMessage(UserMessagePayload(
                text: priorTask.objective,
                to: main,
                submissionID: priorID))),
            envelope(2, .taskCreated(TaskCreatedPayload(
                contract: priorTask))),
            envelope(3, .userMessage(UserMessagePayload(
                text: currentTask.objective,
                to: main,
                submissionID: currentID))),
            envelope(4, .taskQueued(TaskQueuedPayload(
                contract: currentTask,
                rootTaskID: currentTask.id,
                assignee: main,
                hopCount: 0,
                visitedAgents: [main],
                attempt: 1))),
            envelope(5, .modelHistoryCompacted(compacted)),
        ]

        let projection = try AgentModelHistoryProjector().projectState(
            agentID: main,
            currentTask: currentTask,
            events: events)

        XCTAssertEqual(projection.messages, [
            .user(priorTask.objective),
            .user("prior compacted after U2 was queued"),
        ])
        XCTAssertEqual(projection.baseCheckpoint?.sequence, 5)
        XCTAssertEqual(projection.latestCheckpoint?.sequence, 5)
    }

    func testRetrySupersedesNewestCheckpointButKeepsLatestCursor()
        throws
    {
        let oldestID = SubmissionID(rawValue: "sub_retry_oldest")
        let retriedID = SubmissionID(rawValue: "sub_retry_covered")
        let currentID = SubmissionID(rawValue: "sub_retry_current")
        let oldestTask = rootTask(
            "task_retry_oldest",
            oldestID,
            "oldest U")
        let retriedTask = rootTask(
            "task_retry_covered",
            retriedID,
            "retried U")
        let currentTask = rootTask(
            "task_retry_current",
            currentID,
            "current U")
        let first = checkpoint(
            message: "oldest summary",
            replacementHistory: [
                retainedUser(
                    "retry-oldest-retained",
                    submissionID: oldestID,
                    content: oldestTask.objective),
                summary(
                    "retry-oldest-summary",
                    "oldest summary"),
            ])
        let second = checkpoint(
            message: "summary containing failed attempt",
            replacementHistory: [
                retainedUser(
                    "retry-second-oldest",
                    submissionID: oldestID,
                    content: oldestTask.objective),
                retainedUser(
                    "retry-second-covered",
                    submissionID: retriedID,
                    content: retriedTask.objective),
                summary(
                    "retry-second-summary",
                    "summary containing failed attempt"),
            ],
            windowNumber: 2,
            previousWindowID: firstWindowID,
            windowID: secondWindowID)
        let firstAttemptTurn = TurnID(
            rawValue: "turn_retry_first_attempt")
        let secondAttemptTurn = TurnID(
            rawValue: "turn_retry_second_attempt")
        let events = [
            envelope(1, .userMessage(UserMessagePayload(
                text: oldestTask.objective,
                to: main,
                submissionID: oldestID))),
            envelope(2, .taskCreated(TaskCreatedPayload(
                contract: oldestTask))),
            envelope(3, .modelHistoryCompacted(first)),
            envelope(4, .userMessage(UserMessagePayload(
                text: retriedTask.objective,
                to: main,
                submissionID: retriedID))),
            envelope(5, .taskCreated(TaskCreatedPayload(
                contract: retriedTask))),
            envelope(6, .modelHistoryItem(.message(
                itemID: "retry-first-user",
                turnID: firstAttemptTurn,
                agent: main,
                taskID: retriedTask.id,
                submissionID: retriedID,
                taskAttempt: 1,
                role: .user,
                content: retriedTask.objective))),
            envelope(7, .modelHistoryItem(.message(
                itemID: "retry-first-answer",
                turnID: firstAttemptTurn,
                agent: main,
                taskID: retriedTask.id,
                submissionID: retriedID,
                taskAttempt: 1,
                role: .assistant,
                content: "failed attempt answer"))),
            envelope(8, .modelHistoryCompacted(second)),
            envelope(9, .modelHistoryItem(.message(
                itemID: "retry-second-user",
                turnID: secondAttemptTurn,
                agent: main,
                taskID: retriedTask.id,
                submissionID: retriedID,
                taskAttempt: 2,
                role: .user,
                content: retriedTask.objective))),
            envelope(10, .modelHistoryItem(.message(
                itemID: "retry-second-answer",
                turnID: secondAttemptTurn,
                agent: main,
                taskID: retriedTask.id,
                submissionID: retriedID,
                taskAttempt: 2,
                role: .assistant,
                content: "fresh retry answer"))),
            envelope(11, .userMessage(UserMessagePayload(
                text: currentTask.objective,
                to: main,
                submissionID: currentID))),
            envelope(12, .taskCreated(TaskCreatedPayload(
                contract: currentTask))),
        ]

        let projection = try AgentModelHistoryProjector().projectState(
            agentID: main,
            currentTask: currentTask,
            events: events)

        XCTAssertEqual(projection.baseCheckpoint?.sequence, 3)
        XCTAssertEqual(projection.latestCheckpoint?.sequence, 8)
        XCTAssertEqual(
            projection.baseCheckpoint?.payload.windowNumber,
            1)
        XCTAssertEqual(
            projection.latestCheckpoint?.payload.windowNumber,
            2)
        XCTAssertEqual(projection.messages, [
            .user(oldestTask.objective),
            .user("oldest summary"),
            .user(retriedTask.objective),
            .assistant("fresh retry answer"),
        ])
        XCTAssertFalse(
            projection.messages.contains {
                $0.content == "summary containing failed attempt"
                    || $0.content == "failed attempt answer"
            })
        XCTAssertEqual(projection.latestAgentHistorySequence, 10)
    }

    func testUTF8TruncatedRetainedUserSurvivesEnvelopeRoundTrip()
        throws
    {
        let priorID = SubmissionID(rawValue: "sub_utf8_prior")
        let currentID = SubmissionID(rawValue: "sub_utf8_current")
        let source = "不会保留的前缀🙂中段🧠最终片段漢字🚀"
        let suffix = "最终片段漢字🚀"
        let marker =
            AgentModelHistoryCompactor.retainedRealUserTruncationMarker
        let retained = marker + suffix
        let priorTask = rootTask(
            "task_utf8_prior",
            priorID,
            source)
        let currentTask = rootTask(
            "task_utf8_current",
            currentID,
            "继续")
        let compacted = checkpoint(
            message: "UTF-8 summary 🧾",
            replacementHistory: [
                retainedUser(
                    "utf8-retained-user",
                    submissionID: priorID,
                    content: retained,
                    contentTruncated: true),
                summary(
                    "utf8-summary",
                    "UTF-8 summary 🧾"),
            ])
        let events = [
            envelope(1, .userMessage(UserMessagePayload(
                text: source,
                to: main,
                submissionID: priorID))),
            envelope(2, .taskCreated(TaskCreatedPayload(
                contract: priorTask))),
            envelope(3, .modelHistoryCompacted(compacted)),
            envelope(4, .userMessage(UserMessagePayload(
                text: currentTask.objective,
                to: main,
                submissionID: currentID))),
            envelope(5, .taskCreated(TaskCreatedPayload(
                contract: currentTask))),
        ]
        let encoded = try JSONEncoder().encode(events)
        let decoded = try JSONDecoder().decode(
            [Envelope].self,
            from: encoded)

        let projection = try AgentModelHistoryProjector().projectState(
            agentID: main,
            currentTask: currentTask,
            events: decoded)

        XCTAssertEqual(projection.messages.first, .user(retained))
        XCTAssertEqual(projection.realUserMessages.count, 1)
        XCTAssertEqual(
            projection.realUserMessages.first?.content,
            retained)
        XCTAssertEqual(
            projection.realUserMessages.first?.contentTruncated,
            true)
        XCTAssertTrue(source.hasSuffix(suffix))
    }

    func testCheckpointShadowsInvalidRawHistoryBeforeItsBoundary()
        throws
    {
        let priorID = SubmissionID(rawValue: "sub_shadowed_invalid")
        let currentID = SubmissionID(rawValue: "sub_shadowed_current")
        let priorTask = rootTask(
            "task_shadowed_invalid",
            priorID,
            "canonical user")
        let currentTask = rootTask(
            "task_shadowed_current",
            currentID,
            "current")
        let invalidTurn = TurnID(rawValue: "turn_shadowed_invalid")
        let compacted = checkpoint(
            message: "validated replacement",
            replacementHistory: [
                retainedUser(
                    "shadowed-retained-user",
                    submissionID: priorID,
                    content: priorTask.objective),
                summary(
                    "shadowed-summary",
                    "validated replacement"),
            ])
        let invalidRaw = [
            envelope(1, .userMessage(UserMessagePayload(
                text: priorTask.objective,
                to: main,
                submissionID: priorID))),
            envelope(2, .taskCreated(TaskCreatedPayload(
                contract: priorTask))),
            // This would fail an uncheckpointed reconstruction because it
            // does not match the accepted durable submission.
            envelope(3, .modelHistoryItem(.message(
                itemID: "shadowed-invalid-user",
                turnID: invalidTurn,
                agent: main,
                taskID: priorTask.id,
                submissionID: priorID,
                taskAttempt: 1,
                role: .user,
                content: "not the accepted user text"))),
        ]
        let currentEvents = [
            envelope(5, .userMessage(UserMessagePayload(
                text: currentTask.objective,
                to: main,
                submissionID: currentID))),
            envelope(6, .taskCreated(TaskCreatedPayload(
                contract: currentTask))),
        ]
        XCTAssertThrowsError(
            try AgentModelHistoryProjector().project(
                agentID: main,
                currentTask: currentTask,
                events: invalidRaw + currentEvents))

        let projection = try AgentModelHistoryProjector().projectState(
            agentID: main,
            currentTask: currentTask,
            events:
                invalidRaw
                + [envelope(4, .modelHistoryCompacted(compacted))]
                + currentEvents)

        XCTAssertEqual(projection.messages, [
            .user(priorTask.objective),
            .user("validated replacement"),
        ])
        XCTAssertEqual(projection.baseCheckpoint?.sequence, 4)
    }

    func testConflictingReuseOfItemIDFailsClosed() throws {
        let priorID = SubmissionID(rawValue: "sub_conflict")
        let currentID = SubmissionID(rawValue: "sub_conflict_current")
        let priorTask = rootTask("task_conflict", priorID, "U1")
        let currentTask = rootTask("task_conflict_current", currentID, "U2")
        let turnID = TurnID(rawValue: "turn_conflict")
        let first = ModelHistoryItemPayload.message(
            itemID: "same-item",
            turnID: turnID,
            agent: main,
            taskID: priorTask.id,
            submissionID: priorID,
            taskAttempt: 1,
            role: .user,
            content: "U1")
        let second = ModelHistoryItemPayload.message(
            itemID: "same-item",
            turnID: turnID,
            agent: main,
            taskID: priorTask.id,
            submissionID: priorID,
            taskAttempt: 1,
            role: .assistant,
            content: "conflict")
        let events = [
            envelope(1, .userMessage(UserMessagePayload(
                text: "U1", to: main, submissionID: priorID))),
            envelope(2, .taskCreated(TaskCreatedPayload(contract: priorTask))),
            envelope(3, .modelHistoryItem(first)),
            envelope(4, .modelHistoryItem(second)),
            envelope(5, .userMessage(UserMessagePayload(
                text: "U2", to: main, submissionID: currentID))),
            envelope(6, .taskCreated(TaskCreatedPayload(contract: currentTask))),
        ]

        XCTAssertThrowsError(try AgentModelHistoryProjector().project(
            agentID: main,
            currentTask: currentTask,
            events: events)) { error in
                XCTAssertEqual(
                    error as? AgentModelHistoryProjectionError,
                    .conflictingItemID("same-item"))
            }
    }

    func testWrongAgentOrAcceptedTargetFailsClosed() throws {
        let priorID = SubmissionID(rawValue: "sub_wrong_binding")
        let currentID = SubmissionID(rawValue: "sub_wrong_binding_current")
        let priorTask = rootTask("task_wrong_binding", priorID, "U1")
        let currentTask = rootTask(
            "task_wrong_binding_current",
            currentID,
            "U2")
        let wrongAgentEvents = [
            envelope(1, .userMessage(UserMessagePayload(
                text: "U1", to: main, submissionID: priorID))),
            envelope(2, .taskCreated(TaskCreatedPayload(contract: priorTask))),
            envelope(3, .modelHistoryItem(.message(
                itemID: "wrong-agent-user",
                turnID: TurnID(rawValue: "turn_wrong_agent"),
                agent: other,
                taskID: priorTask.id,
                submissionID: priorID,
                taskAttempt: 1,
                role: .user,
                content: "U1"))),
            envelope(4, .userMessage(UserMessagePayload(
                text: "U2", to: main, submissionID: currentID))),
            envelope(5, .taskCreated(TaskCreatedPayload(
                contract: currentTask))),
        ]

        XCTAssertThrowsError(try AgentModelHistoryProjector().project(
            agentID: main,
            currentTask: currentTask,
            events: wrongAgentEvents)) { error in
                XCTAssertEqual(
                    error as? AgentModelHistoryProjectionError,
                    .invalidItem(
                        "wrong-agent-user",
                        "item agent does not match the durable root assignee"))
            }

        let wrongTargetEvents = [
            envelope(1, .userMessage(UserMessagePayload(
                text: "U2", to: other, submissionID: currentID))),
            envelope(2, .taskCreated(TaskCreatedPayload(
                contract: currentTask))),
        ]
        XCTAssertThrowsError(try AgentModelHistoryProjector().project(
            agentID: main,
            currentTask: currentTask,
            events: wrongTargetEvents)) { error in
                XCTAssertEqual(
                    error as? AgentModelHistoryProjectionError,
                    .invalidItem(
                        "accepted-submission:\(currentID.rawValue)",
                        "accepted user target does not match the current root assignee"))
        }
    }

    func testMediaDirectHistoryProjectsAlignedBindingsAndMessagesOnlyFails()
        throws
    {
        let artifactID = ArtifactID(rawValue: "artifact-projected-image")
        let reference = ModelHistoryImageReference(
            artifactID: artifactID,
            mimeType: "image/jpeg",
            byteCount: 256,
            sha256: String(repeating: "d", count: 64))
        let priorID = SubmissionID(rawValue: "sub-media-prior")
        let currentID = SubmissionID(rawValue: "sub-media-current")
        let priorTask = rootTask("task-media-prior", priorID, "inspect")
        let currentTask = rootTask("task-media-current", currentID, "next")
        let turnID = TurnID(rawValue: "turn-media-prior")
        let events = [
            envelope(1, .userMessage(UserMessagePayload(
                text: "inspect",
                attachments: [artifactID],
                to: main,
                submissionID: priorID))),
            envelope(2, .taskCreated(TaskCreatedPayload(contract: priorTask))),
            envelope(3, .modelHistoryItem(.message(
                itemID: "media-user",
                turnID: turnID,
                agent: main,
                taskID: priorTask.id,
                submissionID: priorID,
                taskAttempt: 1,
                role: .user,
                content: "inspect",
                attachmentIDs: [artifactID],
                imageReferences: [reference],
                messageClassification: .realUser))),
            envelope(4, .modelHistoryItem(.functionCallBatch(
                itemID: "media-call",
                turnID: turnID,
                agent: main,
                taskID: priorTask.id,
                submissionID: priorID,
                taskAttempt: 1,
                content: nil,
                calls: [ModelHistoryFunctionCall(
                    callID: "call-media",
                    name: "inspect_image",
                    arguments: "{}")]))),
            envelope(5, .modelHistoryItem(.functionCallOutput(
                itemID: "media-output",
                turnID: turnID,
                agent: main,
                taskID: priorTask.id,
                submissionID: priorID,
                taskAttempt: 1,
                callID: "call-media",
                output: "",
                imageReferences: [reference]))),
            envelope(6, .userMessage(UserMessagePayload(
                text: "next", to: main, submissionID: currentID))),
            envelope(7, .taskCreated(TaskCreatedPayload(contract: currentTask))),
        ]

        let projection = try AgentModelHistoryProjector().projectState(
            agentID: main,
            currentTask: currentTask,
            events: events)
        XCTAssertEqual(projection.messages.count, projection.imageBindings.count)
        let expectedBindings: [ProjectedImageBinding?] = [
            .userVerified([reference]),
            nil,
            .toolVerified(callID: "call-media", imageReferences: [reference]),
        ]
        XCTAssertEqual(projection.imageBindings, expectedBindings)
        XCTAssertEqual(
            projection.realUserMessages.first?.imageReferences,
            [reference])
        XCTAssertThrowsError(try AgentModelHistoryProjector().project(
            agentID: main,
            currentTask: currentTask,
            events: events)) {
                XCTAssertEqual(
                    $0 as? AgentModelHistoryProjectionError,
                    .mediaBindingsRequireProjectionState)
            }
    }

    func testV1CheckpointCannotMaskV2HistoryAndV2DropsOldImages()
        throws
    {
        let artifactID = ArtifactID(rawValue: "artifact-checkpoint-image")
        let reference = ModelHistoryImageReference(
            artifactID: artifactID,
            mimeType: "image/png",
            byteCount: 128,
            sha256: String(repeating: "e", count: 64))
        let priorID = SubmissionID(rawValue: "sub-checkpoint-media")
        let currentID = SubmissionID(rawValue: "sub-checkpoint-current")
        let priorTask = rootTask("task-checkpoint-media", priorID, "inspect")
        let currentTask = rootTask("task-checkpoint-current", currentID, "next")
        let directEvents = [
            envelope(1, .userMessage(UserMessagePayload(
                text: "inspect",
                attachments: [artifactID],
                to: main,
                submissionID: priorID))),
            envelope(2, .taskCreated(TaskCreatedPayload(contract: priorTask))),
            envelope(3, .modelHistoryItem(.message(
                itemID: "checkpoint-media-user",
                turnID: TurnID(rawValue: "turn-checkpoint-media"),
                agent: main,
                taskID: priorTask.id,
                submissionID: priorID,
                taskAttempt: 1,
                role: .user,
                content: "inspect",
                attachmentIDs: [artifactID],
                imageReferences: [reference],
                messageClassification: .realUser))),
        ]
        let replacement = [
            retainedUser(
                "checkpoint-retained-user",
                submissionID: priorID,
                content: "inspect"),
            summary("checkpoint-summary", "image summarized"),
        ]
        let currentEvents = [
            envelope(5, .userMessage(UserMessagePayload(
                text: "next", to: main, submissionID: currentID))),
            envelope(6, .taskCreated(TaskCreatedPayload(contract: currentTask))),
        ]

        XCTAssertThrowsError(try AgentModelHistoryProjector().projectState(
            agentID: main,
            currentTask: currentTask,
            events: directEvents + [
                envelope(4, .modelHistoryCompacted(checkpoint(
                    message: "image summarized",
                    replacementHistory: replacement))),
            ] + currentEvents))

        let mediaCheckpoint = checkpoint(
            schemaVersion: ModelHistoryCompactedPayload.mediaSchemaVersion,
            message: "image summarized",
            replacementHistory: replacement)
        let projection = try AgentModelHistoryProjector().projectState(
            agentID: main,
            currentTask: currentTask,
            events: directEvents + [
                envelope(4, .modelHistoryCompacted(mediaCheckpoint)),
            ] + currentEvents)
        XCTAssertTrue(projection.imageBindings.allSatisfy { $0 == nil })
        XCTAssertTrue(projection.realUserMessages.allSatisfy {
            $0.attachmentIDs == nil && $0.imageReferences == nil
        })
    }

    func testLegacyV1CheckpointAttachmentIDsDecodeButDoNotReinsertImages()
        throws
    {
        let artifactID = ArtifactID(rawValue: "artifact-legacy-checkpoint")
        let priorID = SubmissionID(rawValue: "sub-legacy-checkpoint")
        let currentID = SubmissionID(rawValue: "sub-legacy-checkpoint-current")
        let priorTask = rootTask(
            "task-legacy-checkpoint",
            priorID,
            "legacy image request")
        let currentTask = rootTask(
            "task-legacy-checkpoint-current",
            currentID,
            "next")
        let legacyCheckpoint = checkpoint(
            message: "legacy image summarized",
            replacementHistory: [
                ModelHistoryReplacementItem(
                    itemID: "legacy-retained-user",
                    sourceSubmissionID: priorID,
                    kind: .message,
                    role: .user,
                    messageClassification: .realUser,
                    content: "legacy image request",
                    attachmentIDs: [artifactID]),
                summary(
                    "legacy-checkpoint-summary",
                    "legacy image summarized"),
            ])
        let events = [
            envelope(1, .userMessage(UserMessagePayload(
                text: "legacy image request",
                attachments: [artifactID],
                to: main,
                submissionID: priorID))),
            envelope(2, .taskCreated(TaskCreatedPayload(contract: priorTask))),
            envelope(3, .modelHistoryCompacted(legacyCheckpoint)),
            envelope(4, .userMessage(UserMessagePayload(
                text: "next", to: main, submissionID: currentID))),
            envelope(5, .taskCreated(TaskCreatedPayload(contract: currentTask))),
        ]

        let projection = try AgentModelHistoryProjector().projectState(
            agentID: main,
            currentTask: currentTask,
            events: events)
        XCTAssertTrue(projection.imageBindings.allSatisfy { $0 == nil })
        XCTAssertTrue(projection.realUserMessages.allSatisfy {
            $0.attachmentIDs == nil && $0.imageReferences == nil
        })
        XCTAssertNoThrow(try AgentModelHistoryProjector().project(
            agentID: main,
            currentTask: currentTask,
            events: events))
    }

    private func invocationEvents(
        startingAt sequence: Int,
        turnID: TurnID,
        task: TaskContract,
        attempt: Int,
        answer: String
    ) -> [Envelope] {
        [
            envelope(sequence, .modelHistoryItem(.message(
                itemID: "user-\(turnID.rawValue)",
                turnID: turnID,
                agent: main,
                taskID: task.id,
                submissionID: task.submissionID,
                taskAttempt: attempt,
                role: .user,
                content: task.objective))),
            envelope(sequence + 1, .modelHistoryItem(.message(
                itemID: "assistant-\(turnID.rawValue)",
                turnID: turnID,
                agent: main,
                taskID: task.id,
                submissionID: task.submissionID,
                taskAttempt: attempt,
                role: .assistant,
                content: answer))),
        ]
    }

    private func terminalOutcomeFixture(
        outcome: TurnOutcome?
    ) -> (events: [Envelope], currentTask: TaskContract) {
        let priorSubmission = SubmissionID(rawValue: "sub_terminal_prior")
        let currentSubmission = SubmissionID(rawValue: "sub_terminal_current")
        let priorTask = rootTask(
            "task_terminal_prior",
            priorSubmission,
            "prior user")
        let currentTask = rootTask(
            "task_terminal_current",
            currentSubmission,
            "current user")
        let turnID = TurnID(rawValue: "turn_terminal_fixture")
        var events: [Envelope] = [
            envelope(1, .userMessage(UserMessagePayload(
                text: "prior user",
                to: main,
                submissionID: priorSubmission))),
            envelope(2, .taskCreated(TaskCreatedPayload(contract: priorTask))),
            envelope(3, .modelHistoryItem(.message(
                itemID: "terminal-user",
                turnID: turnID,
                agent: main,
                taskID: priorTask.id,
                submissionID: priorSubmission,
                taskAttempt: 1,
                role: .user,
                content: "prior user"))),
            envelope(4, .modelHistoryItem(.functionCallBatch(
                itemID: "terminal-call",
                turnID: turnID,
                agent: main,
                taskID: priorTask.id,
                submissionID: priorSubmission,
                taskAttempt: 1,
                content: "checking",
                calls: [ModelHistoryFunctionCall(
                    callID: "read-call",
                    name: "read_file",
                    arguments: #"{"path":"README.md"}"#)]))),
            envelope(5, .modelHistoryItem(.functionCallOutput(
                itemID: "terminal-output",
                turnID: turnID,
                agent: main,
                taskID: priorTask.id,
                submissionID: priorSubmission,
                taskAttempt: 1,
                callID: "read-call",
                output: "tool output"))),
            envelope(6, .modelHistoryItem(.message(
                itemID: "terminal-assistant",
                turnID: turnID,
                agent: main,
                taskID: priorTask.id,
                submissionID: priorSubmission,
                taskAttempt: 1,
                role: .assistant,
                content: "invalid final answer"))),
        ]
        if let outcome {
            events.append(envelope(7, .turnOutcome(TurnOutcomePayload(
                turnID: turnID,
                outcome: outcome,
                submissionID: priorSubmission,
                taskID: priorTask.id,
                agentID: main))))
        }
        events.append(envelope(9, .userMessage(UserMessagePayload(
            text: "current user",
            to: main,
            submissionID: currentSubmission))))
        events.append(envelope(10, .taskCreated(TaskCreatedPayload(
            contract: currentTask))))
        return (events, currentTask)
    }

    private let initialWindowID =
        "018f47a0-7b1c-7000-8000-000000000001"
    private let firstWindowID =
        "018f47a0-7b1c-7000-8000-000000000002"
    private let secondWindowID =
        "018f47a0-7b1c-7000-8000-000000000003"

    private func checkpoint(
        schemaVersion: Int =
            ModelHistoryCompactedPayload.currentSchemaVersion,
        message: String,
        replacementHistory: [ModelHistoryReplacementItem],
        windowNumber: UInt64 = 1,
        previousWindowID: String? = nil,
        windowID: String? = nil
    ) -> ModelHistoryCompactedPayload {
        ModelHistoryCompactedPayload(
            schemaVersion: schemaVersion,
            agent: main,
            message: message,
            replacementHistory: replacementHistory,
            windowNumber: windowNumber,
            firstWindowID: initialWindowID,
            previousWindowID:
                previousWindowID ?? initialWindowID,
            windowID: windowID ?? firstWindowID)
    }

    private func retainedUser(
        _ itemID: String,
        submissionID: SubmissionID,
        content: String,
        contentTruncated: Bool = false
    ) -> ModelHistoryReplacementItem {
        ModelHistoryReplacementItem(
            itemID: itemID,
            sourceSubmissionID: submissionID,
            kind: .message,
            role: .user,
            messageClassification: .realUser,
            content: content,
            contentTruncated:
                contentTruncated ? true : nil)
    }

    private func summary(
        _ itemID: String,
        _ content: String
    ) -> ModelHistoryReplacementItem {
        ModelHistoryReplacementItem(
            itemID: itemID,
            kind: .message,
            role: .user,
            messageClassification: .compactionSummary,
            content: content)
    }

    private func rootTask(
        _ taskID: String,
        _ submissionID: SubmissionID,
        _ objective: String
    ) -> TaskContract {
        TaskContract(
            id: TaskID(rawValue: taskID),
            kind: .root,
            issuer: nil,
            assignee: main,
            submissionID: submissionID,
            objective: objective,
            roleHint: "root",
            expectedDeliverable: "answer")
    }

    private func envelope(_ sequence: Int, _ event: Event) -> Envelope {
        Envelope(
            seq: sequence,
            session: session,
            event: event)
    }
}
