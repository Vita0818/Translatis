import Foundation
import IntatisCore
import IntatisProtocol
import MCP
import XCTest
@testable import IntatisMCP

final class MCPTaskStateMachineTests: XCTestCase {
    func testTaskAugmentationCombinesProfileServerAndToolCapabilities() throws {
        XCTAssertEqual(
            try MCPTaskAugmentationPolicy.decide(
                profile: .standardExtended,
                serverSupportsToolCallTasks: true,
                toolTaskSupport: .required,
                preference: .automatic,
                requestedTTLMilliseconds: 60_000),
            .task(ttlMilliseconds: 60_000))
        XCTAssertEqual(
            try MCPTaskAugmentationPolicy.decide(
                profile: .standardExtended,
                serverSupportsToolCallTasks: true,
                toolTaskSupport: .optional,
                preference: .preferTask),
            .task(ttlMilliseconds: nil))
        XCTAssertEqual(
            try MCPTaskAugmentationPolicy.decide(
                profile: .standardExtended,
                serverSupportsToolCallTasks: true,
                toolTaskSupport: nil,
                preference: .automatic),
            .ordinary)
        XCTAssertThrowsError(try MCPTaskAugmentationPolicy.decide(
            profile: .codexCompat,
            serverSupportsToolCallTasks: true,
            toolTaskSupport: .required,
            preference: .automatic))
        XCTAssertThrowsError(try MCPTaskAugmentationPolicy.decide(
            profile: .standardExtended,
            serverSupportsToolCallTasks: false,
            toolTaskSupport: .required,
            preference: .automatic))
        XCTAssertThrowsError(try MCPTaskAugmentationPolicy.decide(
            profile: .standardExtended,
            serverSupportsToolCallTasks: true,
            toolTaskSupport: .required,
            preference: .forbidTask))
    }

    func testRemoteTaskUsesProtectedMappingPollsAndRetrievesExactlyOnce() async throws {
        let events = TaskEventRecorder()
        let payloads = TaskPayloadStore()
        let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
        let manager = MCPRemoteTaskManager(
            authority: remoteAuthority(),
            profile: .standardExtended,
            supportsGetAndResult: true,
            supportsCancel: true,
            events: events,
            payloadStore: payloads)
        let taskID = try await manager.begin(
            operation: .toolCall,
            requestPayload: Data(#"{"name":"long"}"#.utf8),
            originatingToolCallID: "tool-call-1",
            now: fixedNow)
        try await manager.acceptCreation(
            taskID: taskID,
            task: wire(
                remoteID: "remote-opaque-id",
                status: .working,
                ttl: 60_000),
            now: fixedNow)

        let snapshotData = try JSONEncoder().encode(
            try await manager.snapshot(taskID, now: fixedNow))
        XCTAssertFalse(
            String(decoding: snapshotData, as: UTF8.self)
                .contains("remote-opaque-id"))

        let client = RemoteTaskClientFixture(
            getResult: wire(
                remoteID: "remote-opaque-id",
                status: .completed,
                ttl: 60_000),
            taskResult: relatedResult(
                remoteID: "remote-opaque-id"),
            cancelResult: wire(
                remoteID: "remote-opaque-id",
                status: .cancelled,
                ttl: 60_000))
        let refreshed = try await manager.refresh(
            taskID,
            client: client,
            now: fixedNow.addingTimeInterval(1))
        XCTAssertEqual(refreshed.state, .completed)
        XCTAssertFalse(refreshed.durablySettled)

        let first = try await manager.retrieveResult(
            taskID,
            client: client,
            now: fixedNow.addingTimeInterval(2))
        let second = try await manager.retrieveResult(
            taskID,
            client: client,
            now: fixedNow.addingTimeInterval(3))
        XCTAssertEqual(first, second)
        let resultCalls = await client.resultCallCount()
        XCTAssertEqual(resultCalls, 1)
        let settled = try await manager.snapshot(
            taskID,
            now: fixedNow.addingTimeInterval(3))
        XCTAssertTrue(settled.durablySettled)
        XCTAssertNotNil(settled.resultReference)
        let recorded = await events.values()
        XCTAssertTrue(recorded.contains {
            if case .mcpRemoteTaskMapped = $0 { return true }
            return false
        })
        XCTAssertTrue(recorded.contains {
            if case .mcpRemoteTaskSettled(let payload) = $0 {
                return payload.status == .succeeded
                    && payload.resultReference != nil
            }
            return false
        })
    }

    func testRemoteTaskCreationMustBeginWorkingAndInputRequiredUsesResult()
        async throws {
        let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
        let manager = MCPRemoteTaskManager(
            authority: remoteAuthority(),
            profile: .standardExtended,
            supportsGetAndResult: true,
            supportsCancel: true,
            events: TaskEventRecorder(),
            payloadStore: TaskPayloadStore())
        let invalidID = try await manager.begin(
            operation: .toolCall,
            requestPayload: Data(#"{"name":"invalid"}"#.utf8),
            now: fixedNow)
        do {
            try await manager.acceptCreation(
                taskID: invalidID,
                task: wire(
                    remoteID: "remote-invalid",
                    status: .completed,
                    ttl: 60_000),
                now: fixedNow)
            XCTFail("CreateTaskResult must begin in working status")
        } catch let error as MCPTaskRuntimeError {
            guard case .malformedTask = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let taskID = try await manager.begin(
            operation: .toolCall,
            requestPayload: Data(#"{"name":"needs-input"}"#.utf8),
            now: fixedNow)
        try await manager.acceptCreation(
            taskID: taskID,
            task: wire(
                remoteID: "remote-input-required",
                status: .working,
                ttl: 60_000),
            now: fixedNow)
        let client = RemoteTaskClientFixture(
            getResult: wire(
                remoteID: "remote-input-required",
                status: .inputRequired,
                ttl: 60_000),
            taskResult: relatedResult(
                remoteID: "remote-input-required"),
            cancelResult: wire(
                remoteID: "remote-input-required",
                status: .cancelled,
                ttl: 60_000))
        let inputRequired = try await manager.refresh(
            taskID,
            client: client,
            now: fixedNow.addingTimeInterval(1))
        XCTAssertEqual(inputRequired.state, .inputRequired)

        _ = try await manager.retrieveResult(
            taskID,
            client: client,
            now: fixedNow.addingTimeInterval(2))
        let completed = try await manager.snapshot(
            taskID,
            now: fixedNow.addingTimeInterval(2))
        XCTAssertEqual(completed.state, .completed)
        XCTAssertTrue(completed.durablySettled)
        let resultCalls = await client.resultCallCount()
        XCTAssertEqual(resultCalls, 1)
    }

    func testRemoteTaskCancellationUsesTasksCancelAndTerminalCAS() async throws {
        let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
        let manager = MCPRemoteTaskManager(
            authority: remoteAuthority(),
            profile: .standardExtended,
            supportsGetAndResult: true,
            supportsCancel: true,
            events: TaskEventRecorder(),
            payloadStore: TaskPayloadStore())
        let taskID = try await manager.begin(
            operation: .toolCall,
            requestPayload: Data("{}".utf8),
            now: fixedNow)
        try await manager.acceptCreation(
            taskID: taskID,
            task: wire(
                remoteID: "remote-cancel",
                status: .working,
                ttl: 60_000),
            now: fixedNow)
        let client = RemoteTaskClientFixture(
            getResult: wire(
                remoteID: "remote-cancel",
                status: .working,
                ttl: 60_000),
            taskResult: relatedResult(remoteID: "remote-cancel"),
            cancelResult: wire(
                remoteID: "remote-cancel",
                status: .cancelled,
                ttl: 60_000))

        let cancelled = try await manager.cancel(
            taskID,
            client: client,
            now: fixedNow.addingTimeInterval(1))
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertTrue(cancelled.durablySettled)
        let cancelCalls = await client.cancelCallCount()
        XCTAssertEqual(cancelCalls, 1)
        let duplicate = try await manager.cancel(
            taskID,
            client: client,
            now: fixedNow.addingTimeInterval(2))
        XCTAssertEqual(duplicate.state, .cancelled)
        let duplicateCancelCalls = await client.cancelCallCount()
        XCTAssertEqual(duplicateCancelCalls, 1)
    }

    func testRemoteTaskStatusNotificationIsAdvisoryExactAndDoesNotPoll() async throws {
        let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
        let manager = MCPRemoteTaskManager(
            authority: remoteAuthority(),
            profile: .standardExtended,
            supportsGetAndResult: true,
            supportsCancel: true,
            events: TaskEventRecorder(),
            payloadStore: TaskPayloadStore())
        let taskID = try await manager.begin(
            operation: .toolCall,
            requestPayload: Data("{}".utf8),
            now: fixedNow)
        try await manager.acceptCreation(
            taskID: taskID,
            task: wire(
                remoteID: "remote-notification",
                status: .working,
                ttl: 60_000),
            now: fixedNow)

        let unknown = try await manager.observeStatusNotification(
            wire(
                remoteID: "unknown",
                status: .completed,
                ttl: 60_000),
            now: fixedNow.addingTimeInterval(1))
        XCTAssertNil(unknown)

        let updated = try await manager.observeStatusNotification(
            wire(
                remoteID: "remote-notification",
                status: .completed,
                ttl: 60_000),
            now: fixedNow.addingTimeInterval(2))
        XCTAssertEqual(updated?.taskID, taskID)
        XCTAssertEqual(updated?.state, .completed)
        XCTAssertFalse(updated?.durablySettled ?? true)

        let relay = MCPRemoteTaskStatusRelay(
            expectedAuthority: callbackAuthority())
        try await relay.bind(
            manager,
            authority: remoteAuthority())
        await relay.remoteTaskStatusChanged(
            authority: MCPCallbackAuthorityContext(
                server: MCPServerReference(
                    serverID: MCPServerID(rawValue: "other"),
                    serverRevision: MCPServerRevision(rawValue: "other")),
                connectionGeneration: generation(),
                authorityFingerprint: String(repeating: "a", count: 64),
                profile: .standardExtended),
            task: wire(
                remoteID: "remote-notification",
                status: .failed,
                ttl: 60_000))
        let unchanged = try await manager.snapshot(
            taskID,
            now: fixedNow.addingTimeInterval(3))
        XCTAssertEqual(unchanged.state, .completed)
    }

    func testRemoteTaskRestoreIsScopeBoundAndDoesNotPoll() async throws {
        let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
        let manager = MCPRemoteTaskManager(
            authority: remoteAuthority(),
            profile: .standardExtended,
            supportsGetAndResult: true,
            supportsCancel: true,
            events: TaskEventRecorder(),
            payloadStore: TaskPayloadStore())
        let taskID = MCPRemoteServerTaskID(rawValue: "mcpremote-restore")
        let snapshot = MCPRemoteTaskSnapshot(
            taskID: taskID,
            authority: remoteAuthority(),
            operation: .toolCall,
            originatingToolCallID: nil,
            remoteIDReference: MCPResultReference(
                rawValue: "protected-reference"),
            state: .working,
            stateRevision: 2,
            createdAt: fixedNow,
            lastUpdatedAt: fixedNow,
            expiresAt: fixedNow.addingTimeInterval(60),
            pollIntervalMilliseconds: 1_000,
            resultReference: nil)
        try await manager.restore([snapshot], now: fixedNow)
        let candidates = try await manager.explicitResumeCandidates(
            now: fixedNow)
        XCTAssertEqual(candidates, [taskID])

        let mismatched = MCPRemoteTaskSnapshot(
            taskID: MCPRemoteServerTaskID(
                rawValue: "mcpremote-other"),
            authority: MCPRemoteTaskAuthority(
                server: MCPServerReference(
                    serverID: MCPServerID(rawValue: "other"),
                    serverRevision: MCPServerRevision(rawValue: "other")),
                connectionGeneration: MCPConnectionGeneration(
                    rawValue: "other"),
                authorityFingerprint: "other"),
            operation: .toolCall,
            originatingToolCallID: nil,
            remoteIDReference: nil,
            state: .working,
            stateRevision: 1,
            createdAt: fixedNow,
            lastUpdatedAt: fixedNow,
            expiresAt: fixedNow.addingTimeInterval(60),
            pollIntervalMilliseconds: nil,
            resultReference: nil)
        let otherManager = MCPRemoteTaskManager(
            authority: remoteAuthority(),
            profile: .standardExtended,
            supportsGetAndResult: true,
            supportsCancel: true,
            events: TaskEventRecorder(),
            payloadStore: TaskPayloadStore())
        do {
            try await otherManager.restore([mismatched], now: fixedNow)
            XCTFail("cross-authority task restored")
        } catch {
            XCTAssertEqual(
                error as? MCPTaskRuntimeError,
                .scopeMismatch)
        }
    }

    func testClientHostedTaskReturnsCreateTaskThenRelatedResult() async throws {
        let events = TaskEventRecorder()
        let payloads = TaskPayloadStore()
        let notifications = TaskNotificationRecorder()
        let manager = MCPClientHostedTaskManager(
            authority: callbackAuthority(),
            supportsList: true,
            supportsCancel: true,
            supportsSampling: true,
            supportsElicitation: true,
            events: events,
            payloadStore: payloads,
            notifications: notifications)
        let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
        let expected = CreateSamplingMessage.Result(
            model: "fixture",
            stopReason: .endTurn,
            role: .assistant,
            content: .text("done"))
        let wire = try await manager.create(
            kind: .sampling,
            taskMetadata: .init(ttl: 60_000),
            requestPayload: Data("request".utf8),
            requiresUserInput: true,
            now: fixedNow
        ) {
            try JSONEncoder().encode(expected)
        }
        XCTAssertEqual(wire.status, .inputRequired)
        XCTAssertNotEqual(
            MCPClientHostedTaskID(rawValue: wire.taskId).rawValue,
            MCPRemoteServerTaskID(rawValue: wire.taskId).rawValue + "-remote")

        let result = try await manager.result(
            taskID: wire.taskId,
            now: fixedNow)
        guard case .object(let object) = result,
              case .object(let metadata)? = object["_meta"],
              case .object(let related)? =
                metadata[MCPRelatedTaskMetadataKey] else {
            return XCTFail("tasks/result omitted related-task metadata")
        }
        XCTAssertEqual(
            related["taskId"]?.stringValue,
            wire.taskId)
        let status = try await manager.get(
            taskID: wire.taskId,
            now: fixedNow)
        XCTAssertEqual(status.status, .completed)
        let notificationValues = await notifications.values()
        XCTAssertTrue(notificationValues.contains {
            $0.taskId == wire.taskId && $0.status == .completed
        })
        let recorded = await events.values()
        XCTAssertTrue(recorded.contains {
            if case .mcpClientTaskSettled(let payload) = $0 {
                return payload.status == .succeeded
            }
            return false
        })
    }

    func testClientHostedListCursorIsolationCancelAndColdRestore() async throws {
        let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
        let policy = MCPTaskRuntimePolicy(listPageSize: 1)
        let manager = MCPClientHostedTaskManager(
            authority: callbackAuthority(),
            supportsList: true,
            supportsCancel: true,
            supportsSampling: true,
            supportsElicitation: true,
            policy: policy,
            events: TaskEventRecorder(),
            payloadStore: TaskPayloadStore())
        let first = try await manager.create(
            kind: .sampling,
            taskMetadata: .init(ttl: 60_000),
            requestPayload: Data("one".utf8),
            requiresUserInput: false,
            now: fixedNow
        ) {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return Data("{}".utf8)
        }
        _ = try await manager.create(
            kind: .elicitation,
            taskMetadata: .init(ttl: 60_000),
            requestPayload: Data("two".utf8),
            requiresUserInput: false,
            now: fixedNow.addingTimeInterval(1)
        ) {
            Data("{}".utf8)
        }
        let pageOne = try await manager.list(cursor: nil, now: fixedNow)
        XCTAssertEqual(pageOne.tasks.count, 1)
        let cursor = try XCTUnwrap(pageOne.nextCursor)
        let pageTwo = try await manager.list(
            cursor: cursor,
            now: fixedNow)
        XCTAssertEqual(pageTwo.tasks.count, 1)

        let other = MCPClientHostedTaskManager(
            authority: MCPCallbackAuthorityContext(
                server: MCPServerReference(
                    serverID: MCPServerID(rawValue: "other"),
                    serverRevision: MCPServerRevision(rawValue: "other")),
                connectionGeneration: MCPConnectionGeneration(
                    rawValue: "other"),
                authorityFingerprint: "other",
                profile: .standardExtended),
            supportsList: true,
            supportsCancel: true,
            supportsSampling: true,
            supportsElicitation: true,
            policy: policy,
            events: TaskEventRecorder(),
            payloadStore: TaskPayloadStore())
        do {
            _ = try await other.list(cursor: cursor, now: fixedNow)
            XCTFail("cross-authority cursor was accepted")
        } catch {
            XCTAssertEqual(
                error as? MCPTaskRuntimeError,
                .invalidCursor)
        }

        let cancelled = try await manager.cancel(
            taskID: first.taskId,
            now: fixedNow.addingTimeInterval(2))
        XCTAssertEqual(cancelled.status, .cancelled)

        let activeSnapshot = MCPClientHostedTaskSnapshot(
            taskID: MCPClientHostedTaskID(
                rawValue: "mcpclient-restored"),
            kind: .sampling,
            state: .inputRequired,
            stateRevision: 1,
            createdAt: fixedNow,
            lastUpdatedAt: fixedNow,
            ttlMilliseconds: 60_000,
            expiresAt: fixedNow.addingTimeInterval(60),
            resultReference: nil)
        let restored = MCPClientHostedTaskManager(
            authority: callbackAuthority(),
            supportsList: true,
            supportsCancel: true,
            supportsSampling: true,
            supportsElicitation: true,
            events: TaskEventRecorder(),
            payloadStore: TaskPayloadStore())
        try await restored.restore([activeSnapshot], now: fixedNow)
        let restoredStatus = try await restored.get(
            taskID: activeSnapshot.taskID.rawValue,
            now: fixedNow)
        XCTAssertEqual(restoredStatus.status, .failed)
        await manager.shutdown(now: fixedNow.addingTimeInterval(3))
    }

    private func remoteAuthority() -> MCPRemoteTaskAuthority {
        MCPRemoteTaskAuthority(
            server: server(),
            connectionGeneration: generation(),
            authorityFingerprint: String(repeating: "a", count: 64))
    }

    private func callbackAuthority() -> MCPCallbackAuthorityContext {
        MCPCallbackAuthorityContext(
            server: server(),
            connectionGeneration: generation(),
            authorityFingerprint: String(repeating: "a", count: 64),
            profile: .standardExtended)
    }

    private func server() -> MCPServerReference {
        MCPServerReference(
            serverID: MCPServerID(rawValue: "mcpserver-task"),
            serverRevision: MCPServerRevision(rawValue: "mcprev-task"))
    }

    private func generation() -> MCPConnectionGeneration {
        MCPConnectionGeneration(rawValue: "mcpcnx-task")
    }

    private func wire(
        remoteID: String,
        status: MCPTaskStatus,
        ttl: Int?
    ) -> MCPTaskWire {
        MCPTaskWire(
            taskId: remoteID,
            status: status,
            createdAt: "2025-11-25T10:30:00Z",
            lastUpdatedAt: "2025-11-25T10:40:00Z",
            ttl: ttl,
            pollInterval: 1_000)
    }

    private func relatedResult(remoteID: String) -> Value {
        .object([
            "content": .array([]),
            "isError": .bool(false),
            "_meta": .object([
                MCPRelatedTaskMetadataKey: .object([
                    "taskId": .string(remoteID),
                ]),
            ]),
        ])
    }
}

private actor TaskEventRecorder: MCPBrokerEventSink {
    private var recorded: [Event] = []

    func appendMCPBrokerEvent(_ event: Event) async throws {
        recorded.append(event)
    }

    func appendMCPBrokerEvents(_ events: [Event]) async throws {
        recorded.append(contentsOf: events)
    }

    func values() -> [Event] {
        recorded
    }
}

private actor TaskPayloadStore: MCPBrokerPayloadStore {
    private struct Entry {
        let scope: String
        let data: Data
    }

    private var entries: [MCPResultReference: Entry] = [:]

    func store(
        _ payload: Data,
        scopeFingerprint: String
    ) async throws -> MCPResultReference {
        let reference = MCPResultReference.new()
        entries[reference] = Entry(
            scope: scopeFingerprint,
            data: payload)
        return reference
    }

    func resolve(
        _ reference: MCPResultReference,
        scopeFingerprint: String
    ) async throws -> Data {
        guard let entry = entries[reference],
              entry.scope == scopeFingerprint else {
            throw MCPSecretStoreError.notFound
        }
        return entry.data
    }

    func remove(
        _ reference: MCPResultReference,
        scopeFingerprint: String
    ) async throws {
        guard let entry = entries[reference],
              entry.scope == scopeFingerprint else {
            throw MCPSecretStoreError.notFound
        }
        entries[reference] = nil
    }
}

private actor RemoteTaskClientFixture: MCPRemoteTaskClient {
    private let getResult: MCPTaskWire
    private let taskResult: Value
    private let cancelResult: MCPTaskWire
    private var resultCalls = 0
    private var cancelCalls = 0

    init(
        getResult: MCPTaskWire,
        taskResult: Value,
        cancelResult: MCPTaskWire
    ) {
        self.getResult = getResult
        self.taskResult = taskResult
        self.cancelResult = cancelResult
    }

    func getRemoteTask(
        _ remoteTaskID: String,
        timeoutMilliseconds _: Int?
    ) async throws
        -> MCPTaskWire
    {
        getResult
    }

    func getRemoteTaskResult(
        _ remoteTaskID: String,
        timeoutMilliseconds _: Int?
    ) async throws -> Value {
        resultCalls += 1
        return taskResult
    }

    func cancelRemoteTask(
        _ remoteTaskID: String,
        timeoutMilliseconds _: Int?
    ) async throws
        -> MCPTaskWire
    {
        cancelCalls += 1
        return cancelResult
    }

    func resultCallCount() -> Int {
        resultCalls
    }

    func cancelCallCount() -> Int {
        cancelCalls
    }
}

private actor TaskNotificationRecorder: MCPClientTaskNotificationSink {
    private var tasks: [MCPTaskWire] = []

    func notifyClientHostedTaskStatus(_ task: MCPTaskWire) async {
        tasks.append(task)
    }

    func values() -> [MCPTaskWire] {
        tasks
    }
}
