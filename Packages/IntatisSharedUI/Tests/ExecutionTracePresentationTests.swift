import XCTest
import IntatisConversation
import IntatisProtocol
@testable import IntatisSharedUI

final class ExecutionTracePresentationTests: XCTestCase {
    func testExecutionTraceDefaultsToHidden() {
        XCTAssertFalse(
            IntatisExecutionTracePresentation.resolve(
                arguments: ["Intatis"],
                environment: [:]))
    }

    func testLaunchArgumentEnablesExecutionTrace() {
        XCTAssertTrue(
            IntatisExecutionTracePresentation.resolve(
                arguments: ["Intatis", IntatisExecutionTracePresentation.launchArgument],
                environment: [:]))
    }

    func testTruthyEnvironmentValueEnablesExecutionTrace() {
        for value in ["1", "true", " YES ", "On", "enabled"] {
            XCTAssertTrue(
                IntatisExecutionTracePresentation.resolve(
                    arguments: ["Intatis"],
                    environment: [IntatisExecutionTracePresentation.environmentVariable: value]),
                "Expected \(value) to enable the execution trace")
        }
    }

    func testFalseOrUnknownEnvironmentValueKeepsExecutionTraceHidden() {
        for value in ["0", "false", "off", "unexpected", ""] {
            XCTAssertFalse(
                IntatisExecutionTracePresentation.resolve(
                    arguments: ["Intatis"],
                    environment: [IntatisExecutionTracePresentation.environmentVariable: value]),
                "Expected \(value) to keep the execution trace hidden")
        }
    }

    func testDefaultProjectionKeepsConversationAgentTrafficAndErrors() {
        let items = makeItems()

        let displayed = IntatisExecutionTracePresentation.displayedItems(
            items,
            showExecutionTrace: false)

        XCTAssertEqual(
            displayed.map(\.kind),
            [.user, .runtimeEvent, .agentToAgent, .agent, .error])
        XCTAssertEqual(
            displayed.map(\.id),
            [
                "user",
                "codex-activity:item:command-1",
                "agent-to-agent",
                "agent",
                "error",
            ])
        XCTAssertEqual(
            displayed[1].codexActivity?.category,
            .command)
        XCTAssertEqual(
            displayed[1].codexActivity?.state,
            .running)
        XCTAssertNotEqual(displayed[1].title, "item/started")
    }

    func testEnabledProjectionRestoresCompletePreviousTranscript() {
        let items = makeItems()

        XCTAssertEqual(
            IntatisExecutionTracePresentation.displayedItems(
                items,
                showExecutionTrace: true),
            items)
    }

    func testTaskCompletionFallbackRemainsVisibleWithoutMatchingMessage() {
        let fallback = CodeItem(
            id: "task-fallback",
            kind: .agent,
            title: "worker",
            body: "Only durable result")

        XCTAssertEqual(
            IntatisExecutionTracePresentation.displayedItems(
                [fallback],
                showExecutionTrace: false),
            [fallback])
    }

    func testDefaultProjectionConsumesDedicatedEventsAndCoalescesItemLifecycle() {
        let items = [
            runtimeEvent(
                id: "turn-started",
                method: "turn/started",
                turnID: "turn-1",
                status: "inProgress"),
            runtimeEvent(
                id: "command-started",
                method: "item/started",
                turnID: "turn-1",
                itemID: "command-1",
                itemType: "commandExecution",
                status: "inProgress"),
            runtimeEvent(
                id: "usage",
                method: "thread/tokenUsage/updated",
                turnID: "turn-1"),
            runtimeEvent(
                id: "command-completed",
                method: "item/completed",
                turnID: "turn-1",
                itemID: "command-1",
                itemType: "commandExecution",
                status: "completed"),
            runtimeEvent(
                id: "future-event",
                method: "item/futureActivity/changed",
                turnID: "turn-1",
                itemID: "future-1",
                status: "running"),
            runtimeEvent(
                id: "turn-completed",
                method: "turn/completed",
                turnID: "turn-1",
                status: "completed"),
        ]

        let displayed = IntatisExecutionTracePresentation.displayedItems(
            items,
            showExecutionTrace: false)

        XCTAssertEqual(displayed.count, 2)
        XCTAssertEqual(
            displayed.map { $0.codexActivity?.category },
            [.command, .runtime])
        XCTAssertEqual(displayed[0].codexActivity?.state, .completed)
        XCTAssertEqual(
            displayed[0].codexActivity?.rawMethods,
            ["item/started", "item/completed"])
        XCTAssertEqual(
            displayed[1].codexActivity?.rawMethods,
            ["item/futureActivity/changed"])
    }

    func testDuplicateChildRepresentationsProduceOneSemanticActivity() {
        let payload = CodexAppServerEventPayload(
            eventID: "reasoning-event",
            method: "item/reasoning/textDelta",
            turnID: "turn-child",
            itemID: "reasoning-child",
            textDelta: "Checking files")
        let items = [
            CodeItem(
                id: "thread-child:reasoning-event",
                kind: .runtimeEvent,
                title: payload.method,
                body: "Checking files",
                complete: false,
                codexAppServerEvent: payload),
            CodeItem(
                id: payload.eventID,
                kind: .runtimeEvent,
                title: payload.method,
                body: "Checking files",
                complete: false,
                codexAppServerEvent: payload),
        ]

        let displayed = IntatisExecutionTracePresentation.displayedItems(
            items,
            showExecutionTrace: false)

        XCTAssertEqual(displayed.count, 1)
        XCTAssertEqual(displayed[0].body, "Checking files")
        XCTAssertEqual(displayed[0].codexActivity?.category, .reasoning)
    }

    func testEveryKnownRuntimeItemTypeHasAStableSemanticCategory() {
        let mappings: [(String, CodexActivityPresentation.Category)] = [
            ("commandExecution", .command),
            ("fileChange", .fileChanges),
            ("dynamicToolCall", .tool),
            ("mcpToolCall", .mcpTool),
            ("webSearch", .webSearch),
            ("imageGeneration", .image),
            ("imageView", .image),
            ("collabAgentToolCall", .collaboration),
            ("collabToolCall", .collaboration),
            ("subAgentActivity", .subagent),
            ("plan", .plan),
            ("reasoning", .reasoning),
            ("futureItemType", .runtime),
        ]

        for (index, mapping) in mappings.enumerated() {
            let item = runtimeEvent(
                id: "item-started-\(index)",
                method: "item/started",
                turnID: "turn-\(index)",
                itemID: "item-\(index)",
                itemType: mapping.0,
                status: "inProgress")
            let displayed = IntatisExecutionTracePresentation.displayedItems(
                [item],
                showExecutionTrace: false)

            XCTAssertEqual(displayed.count, 1, mapping.0)
            XCTAssertEqual(
                displayed.first?.codexActivity?.category,
                mapping.1,
                mapping.0)
            XCTAssertEqual(
                displayed.first?.codexActivity?.state,
                .running,
                mapping.0)
        }
    }

    func testTurnActivityIsVisibleOnlyUntilItsOfficialTerminalEvent() {
        let started = runtimeEvent(
            id: "turn-started",
            method: "turn/started",
            turnID: "turn-1",
            status: "inProgress")
        let completed = runtimeEvent(
            id: "turn-completed",
            method: "turn/completed",
            turnID: "turn-1",
            status: "completed")

        let active = IntatisExecutionTracePresentation.displayedItems(
            [started],
            showExecutionTrace: false)
        XCTAssertEqual(active.first?.codexActivity?.category, .turn)
        XCTAssertEqual(active.first?.codexActivity?.state, .running)

        XCTAssertTrue(
            IntatisExecutionTracePresentation.displayedItems(
                [started, completed],
                showExecutionTrace: false).isEmpty)
    }

    func testFailedItemLifecycleKeepsSemanticFailureWithoutRawMethodTitle() {
        let failed = runtimeEvent(
            id: "command-failed",
            method: "item/completed",
            turnID: "turn-1",
            itemID: "command-1",
            itemType: "commandExecution",
            status: "failed")

        let displayed = IntatisExecutionTracePresentation.displayedItems(
            [failed],
            showExecutionTrace: false)

        XCTAssertEqual(displayed.first?.codexActivity?.state, .failed)
        XCTAssertEqual(displayed.first?.isFailure, true)
        XCTAssertNotEqual(displayed.first?.title, "item/completed")
    }

    func testRetryNotificationsCoalesceToLatestProgressAndDisappearAtTerminal() throws {
        let started = runtimeEvent(
            id: "turn-started",
            method: "turn/started",
            turnID: "turn-retry",
            status: "inProgress")
        let first = runtimeEvent(
            id: "retry-1",
            method: "error",
            turnID: "turn-retry",
            message: "Reconnecting... 1/5",
            details: "first disconnect",
            willRetry: true)
        let second = runtimeEvent(
            id: "retry-2",
            method: "error",
            turnID: "turn-retry",
            message: "Reconnecting... 2/5",
            details: "second disconnect",
            willRetry: true)

        let active = IntatisExecutionTracePresentation.displayedItems(
            [started, first, second],
            showExecutionTrace: false)
        let retry = try XCTUnwrap(active.first(where: {
            $0.codexActivity?.category == .retry
        }))
        XCTAssertEqual(retry.codexActivity?.retryAttempt, 2)
        XCTAssertEqual(retry.codexActivity?.retryLimit, 5)
        XCTAssertEqual(retry.body, "second disconnect")

        let completed = runtimeEvent(
            id: "turn-completed",
            method: "turn/completed",
            turnID: "turn-retry",
            status: "failed")
        XCTAssertFalse(
            IntatisExecutionTracePresentation.displayedItems(
                [started, first, second, completed],
                showExecutionTrace: false).contains(where: {
                    $0.codexActivity?.category == .retry
                }))
    }

    func testTerminalErrorBecomesRecoverableFailureActivity() {
        let terminal = runtimeEvent(
            id: "terminal-error",
            method: "error",
            turnID: "turn-error",
            message: "Upstream idle timeout exceeded",
            details: "stream disconnected before completion",
            willRetry: false)

        let displayed = IntatisExecutionTracePresentation.displayedItems(
            [terminal],
            showExecutionTrace: false)

        XCTAssertEqual(displayed.count, 1)
        XCTAssertEqual(displayed[0].codexActivity?.category, .runtime)
        XCTAssertEqual(displayed[0].codexActivity?.state, .failed)
        XCTAssertEqual(displayed[0].isFailure, true)
        XCTAssertEqual(
            displayed[0].body,
            "Upstream idle timeout exceeded\nstream disconnected before completion")
    }

    func testNoticeMCPProgressAndApprovalReviewKeepTheirSafeSemantics() {
        let warning = runtimeEvent(
            id: "warning",
            method: "warning",
            turnID: "turn-1",
            message: "Provider is recovering")
        let progress = runtimeEvent(
            id: "progress",
            method: "item/mcpToolCall/progress",
            turnID: "turn-1",
            itemID: "mcp-1",
            message: "Loading resources")
        let reviewStarted = runtimeEvent(
            id: "review-started",
            method: "item/autoApprovalReview/started",
            turnID: "turn-1",
            itemID: "review-1",
            itemType: "approvalReview",
            status: "inProgress")
        let reviewCompleted = runtimeEvent(
            id: "review-completed",
            method: "item/autoApprovalReview/completed",
            turnID: "turn-1",
            itemID: "review-1",
            itemType: "approvalReview",
            status: "completed")

        let displayed = IntatisExecutionTracePresentation.displayedItems(
            [warning, progress, reviewStarted, reviewCompleted],
            showExecutionTrace: false)

        XCTAssertEqual(
            displayed.map { $0.codexActivity?.category },
            [.runtime, .mcpTool, .approvalReview])
        XCTAssertEqual(displayed[0].body, "Provider is recovering")
        XCTAssertEqual(displayed[1].body, "Loading resources")
        XCTAssertEqual(displayed[2].codexActivity?.state, .completed)
    }

    func testPinnedCompactionReviewWaitingPlanAndMCPStatusAreSemantic() {
        let compactionStarted = runtimeEvent(
            id: "compact-started",
            method: "item/started",
            turnID: "turn-1",
            itemID: "compact-1",
            itemType: "contextCompaction")
        let compactionCompleted = runtimeEvent(
            id: "compact-completed",
            method: "item/completed",
            turnID: "turn-1",
            itemID: "compact-1",
            itemType: "contextCompaction")
        let review = runtimeEvent(
            id: "review-mode",
            method: "item/completed",
            turnID: "turn-1",
            itemID: "review-mode-1",
            itemType: "enteredReviewMode")
        let waiting = runtimeEvent(
            id: "sleep",
            method: "item/completed",
            turnID: "turn-1",
            itemID: "sleep-1",
            itemType: "sleep")
        let plan = runtimeEvent(
            id: "turn-plan",
            method: "turn/plan/updated",
            turnID: "turn-1",
            status: "inProgress",
            message: "Checking the remaining work")
        let mcpFailure = runtimeEvent(
            id: "mcp-startup",
            method: "mcpServer/startupStatus/updated",
            turnID: "turn-1",
            status: "failed",
            message: "documentation",
            details: "reauthenticationRequired")

        let displayed = IntatisExecutionTracePresentation.displayedItems(
            [
                compactionStarted,
                compactionCompleted,
                review,
                waiting,
                plan,
                mcpFailure,
            ],
            showExecutionTrace: false)

        XCTAssertEqual(
            displayed.map { $0.codexActivity?.category },
            [.compaction, .review, .waiting, .plan, .mcpTool])
        XCTAssertEqual(displayed[0].codexActivity?.state, .completed)
        XCTAssertEqual(displayed[3].body, "Checking the remaining work")
        XCTAssertEqual(displayed[4].codexActivity?.state, .failed)
        XCTAssertTrue(displayed[4].isFailure)
    }

    func testNonTranscriptSessionNotificationIsHiddenOnlyFromDefaultUI() {
        let skillsChanged = runtimeEvent(
            id: "skills-changed",
            method: "skills/changed",
            turnID: "turn-1")

        XCTAssertTrue(
            IntatisExecutionTracePresentation.displayedItems(
                [skillsChanged],
                showExecutionTrace: false).isEmpty)
        XCTAssertEqual(
            IntatisExecutionTracePresentation.displayedItems(
                [skillsChanged],
                showExecutionTrace: true),
            [skillsChanged])
    }

    private func makeItems() -> [CodeItem] {
        [
            CodeItem(id: "user", kind: .user, title: "You", body: "request"),
            CodeItem(
                id: "runtime-event",
                kind: .runtimeEvent,
                title: "item/started",
                body: "type: commandExecution\nstatus: inProgress",
                codexAppServerEvent: CodexAppServerEventPayload(
                    eventID: "runtime-event",
                    method: "item/started",
                    turnID: "turn-1",
                    itemID: "command-1",
                    itemType: "commandExecution",
                    status: "inProgress")),
            CodeItem(id: "tool-call", kind: .toolCall, title: "read_file", body: "{}"),
            CodeItem(id: "tool-result", kind: .toolResult, title: "result", body: "large output", isFailure: true),
            CodeItem(id: "patch", kind: .patch, title: "patch", body: "diff"),
            CodeItem(id: "note", kind: .note, title: "task", body: "started"),
            CodeItem(id: "agent-to-agent", kind: .agentToAgent, title: "main → worker", body: "internal"),
            CodeItem(id: "agent", kind: .agent, title: "Agent", body: "answer"),
            CodeItem(
                id: "task-completion-mirror",
                kind: .agent,
                title: "Agent",
                body: "answer",
                presentationSource: .executionTrace),
            CodeItem(id: "error", kind: .error, title: "error", body: "actionable failure"),
        ]
    }

    private func runtimeEvent(
        id: String,
        method: String,
        turnID: String,
        itemID: String? = nil,
        itemType: String? = nil,
        status: String? = nil,
        message: String? = nil,
        details: String? = nil,
        willRetry: Bool? = nil
    ) -> CodeItem {
        let payload = CodexAppServerEventPayload(
            eventID: id,
            method: method,
            turnID: turnID,
            itemID: itemID,
            itemType: itemType,
            status: status,
            message: message,
            details: details,
            willRetry: willRetry)
        return CodeItem(
            id: id,
            kind: .runtimeEvent,
            title: method,
            body: "",
            codexAppServerEvent: payload)
    }
}
