import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisTools
import IntatisConversation
@testable import IntatisCowork

final class CodexWorkTaskControllerTests: XCTestCase {
    func testRootCreatesAndLinkedChildUpdatesOnlyItsWorkTask()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let log = try EventLog(
            session: SessionID(rawValue: "codex-work-task"),
            fileURL: temporary.appendingPathComponent("events.jsonl"))
        let rootID = AgentID(rawValue: "main")
        let childID = AgentID(rawValue: "codex:child-thread")
        let controller = CodexWorkTaskController(
            log: log,
            rootAgentID: rootID)
        let root = await controller.manager(
            for: rootID)
        let child = await controller.manager(
            for: childID)

        let first = try await root.createWorkTask(
            WorkTaskCreateRequest(
                title: "Implement child slice",
                description: "Return verified evidence"))
        XCTAssertEqual(first.task.status, .ready)
        XCTAssertEqual(first.task.revision, 0)

        do {
            _ = try await child.createWorkTask(
                WorkTaskCreateRequest(
                    title: "unauthorized",
                    description: "must fail"))
            XCTFail("child unexpectedly created a WorkTask")
        } catch let rejection as ToolExecutionRejectedWithoutSideEffect {
            XCTAssertEqual(rejection.code, "permission_denied")
        }

        try await controller.agentDirectory.register(
            taskName: "/root/child_task",
            verifiedAgentID: childID)
        let linker = try XCTUnwrap(
            root as? any CodexWorkTaskAgentLinking)
        let linked = try await linker.linkWorkTask(
            taskID: first.task.id,
            expectedRevision: first.task.revision,
            agentTaskName: "/root/child_task")
        XCTAssertEqual(linked.task.revision, 1)
        XCTAssertEqual(linked.task.latestInvocationIDs.count, 1)

        let progressed = try await child.updateWorkTask(
            WorkTaskUpdateRequest(
                taskID: linked.task.id,
                expectedRevision: linked.task.revision,
                progressNote: "child inspected the target",
                status: .inProgress))
        XCTAssertEqual(progressed.task.status, .inProgress)
        XCTAssertEqual(
            progressed.task.progressNote,
            "child inspected the target")

        let second = try await root.createWorkTask(
            WorkTaskCreateRequest(
                title: "Root-only task",
                description: "Remain outside child scope"))
        do {
            _ = try await child.updateWorkTask(
                WorkTaskUpdateRequest(
                    taskID: second.task.id,
                    expectedRevision: second.task.revision,
                    progressNote: "must not apply"))
            XCTFail("child unexpectedly updated another WorkTask")
        } catch let rejection as ToolExecutionRejectedWithoutSideEffect {
            XCTAssertEqual(rejection.code, "permission_denied")
        }

        let visible = try await child.listWorkTasks(WorkTaskListRequest())
        XCTAssertEqual(visible.map(\.task.id), [first.task.id])
    }

    func testCodexRegistryContainsOnlyWorkTaskCardTools() {
        XCTAssertEqual(
            CodexWorkTaskToolRegistry.registrations
                .map(\.descriptor.name)
                .sorted(),
            [
                "task_create", "task_get", "task_link_agent",
                "task_list", "task_update",
            ])
    }

    func testConcurrentSameRevisionUpdateHasOneDurableWinner()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fileURL = temporary.appendingPathComponent("events.jsonl")
        let sessionID = SessionID(rawValue: "codex-work-task-cas")
        let rootID = AgentID(rawValue: "main")
        let firstController = CodexWorkTaskController(
            log: try EventLog(session: sessionID, fileURL: fileURL),
            rootAgentID: rootID)
        let secondController = CodexWorkTaskController(
            log: try EventLog(session: sessionID, fileURL: fileURL),
            rootAgentID: rootID)
        let creator = await firstController.manager(for: rootID)
        let created = try await creator.createWorkTask(
            WorkTaskCreateRequest(
                title: "CAS task",
                description: "Accept exactly one revision"))

        let outcomes = await withTaskGroup(
            of: String.self,
            returning: [String].self
        ) { group in
            for (controller, note) in [
                (firstController, "first"),
                (secondController, "second"),
            ] {
                group.addTask {
                    let manager = await controller.manager(for: rootID)
                    do {
                        _ = try await manager.updateWorkTask(
                            WorkTaskUpdateRequest(
                                taskID: created.task.id,
                                expectedRevision: created.task.revision,
                                progressNote: note))
                        return "success"
                    } catch let rejection
                        as ToolExecutionRejectedWithoutSideEffect {
                        return rejection.code
                    } catch {
                        return "unexpected:\(error.localizedDescription)"
                    }
                }
            }
            var values: [String] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(outcomes.filter { $0 == "success" }.count, 1)
        XCTAssertEqual(
            outcomes.filter { $0 == "stale_revision" }.count,
            1,
            "outcomes=\(outcomes)")

        let replayLog = try EventLog(
            session: sessionID,
            fileURL: fileURL)
        let replay = await replayLog.replay()
        let task = try XCTUnwrap(
            CoworkProjection.build(from: replay)
                .workTasks[created.task.id])
        XCTAssertEqual(task.revision, 1)
        XCTAssertTrue(["first", "second"].contains(task.progressNote))
    }

    func testInProgressContractIsFrozenForRoot() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sessionID = SessionID(rawValue: "codex-work-task-frozen")
        let log = try EventLog(
            session: sessionID,
            fileURL: temporary.appendingPathComponent("events.jsonl"))
        let rootID = AgentID(rawValue: "main")
        let controller = CodexWorkTaskController(
            log: log,
            rootAgentID: rootID)
        let root = await controller.manager(for: rootID)
        let created = try await root.createWorkTask(
            WorkTaskCreateRequest(
                title: "Frozen contract",
                description: "Do not mutate after start"))
        let started = try await root.updateWorkTask(
            WorkTaskUpdateRequest(
                taskID: created.task.id,
                expectedRevision: created.task.revision,
                status: .inProgress))
        do {
            _ = try await root.updateWorkTask(
                WorkTaskUpdateRequest(
                    taskID: started.task.id,
                    expectedRevision: started.task.revision,
                    title: "Illicit rewrite"))
            XCTFail("root unexpectedly changed an in-progress contract")
        } catch let rejection as ToolExecutionRejectedWithoutSideEffect {
            XCTAssertEqual(rejection.code, "permission_denied")
        }
        let settled = try await root.getWorkTask(started.task.id)
        XCTAssertEqual(settled.task.revision, started.task.revision)
        XCTAssertEqual(settled.task.title, "Frozen contract")
    }

    func testTaskDirectoryReplacementIsAtomicOnConflict() async throws {
        let directory = CodexAgentTaskDirectory()
        let first = AgentID(rawValue: "codex:first")
        let second = AgentID(rawValue: "codex:second")
        try await directory.register(
            taskName: "/root/first",
            verifiedAgentID: first)
        try await directory.register(
            taskName: "/root/second",
            verifiedAgentID: second)
        do {
            try await directory.replace(
                previousTaskName: "/root/first",
                taskName: "/root/second",
                verifiedAgentID: first)
            XCTFail("conflicting replacement unexpectedly succeeded")
        } catch {}
        let resolvedFirst = await directory.resolve(
            taskName: "/root/first")
        let resolvedSecond = await directory.resolve(
            taskName: "/root/second")
        XCTAssertEqual(resolvedFirst, first)
        XCTAssertEqual(resolvedSecond, second)
    }
}
