import Foundation
import XCTest
import IntatisProtocol
import MCP
@testable import IntatisMCP

final class MCPTaskWireTests: XCTestCase {
    func testExactTaskMethodsAndRequiredNullTTLWireShape() throws {
        let task = MCPTaskWire(
            taskId: "remote-task-1",
            status: .working,
            statusMessage: "running",
            createdAt: "2025-11-25T10:30:00Z",
            lastUpdatedAt: "2025-11-25T10:40:00Z",
            ttl: nil,
            pollInterval: 5_000)
        let encodedTask = try object(task)
        XCTAssertTrue(encodedTask.keys.contains("ttl"))
        XCTAssertTrue(encodedTask["ttl"] is NSNull)
        XCTAssertEqual(encodedTask["taskId"] as? String, "remote-task-1")
        XCTAssertEqual(encodedTask["status"] as? String, "working")

        let get = try object(
            GetTask.request(.init(taskId: "remote-task-1")))
        XCTAssertEqual(get["method"] as? String, "tasks/get")
        XCTAssertEqual(
            (get["params"] as? [String: Any])?["taskId"] as? String,
            "remote-task-1")

        let result = try object(
            GetTaskPayload.request(.init(taskId: "remote-task-1")))
        XCTAssertEqual(result["method"] as? String, "tasks/result")

        let list = try object(
            ListTasks.request(.init(cursor: "opaque-cursor")))
        XCTAssertEqual(list["method"] as? String, "tasks/list")
        XCTAssertEqual(
            (list["params"] as? [String: Any])?["cursor"] as? String,
            "opaque-cursor")

        let cancel = try object(
            CancelTask.request(.init(taskId: "remote-task-1")))
        XCTAssertEqual(cancel["method"] as? String, "tasks/cancel")

        let notification = try object(
            TaskStatusNotification.message(task))
        XCTAssertEqual(
            notification["method"] as? String,
            "notifications/tasks/status")
        XCTAssertEqual(
            (notification["params"] as? [String: Any])?["taskId"]
                as? String,
            "remote-task-1")
    }

    func testTaskMissingTTLIsRejectedAndTerminalStatesAreClosed() throws {
        let missingTTL = Data(#"""
        {
          "taskId": "task-1",
          "status": "working",
          "createdAt": "2025-11-25T10:30:00Z",
          "lastUpdatedAt": "2025-11-25T10:40:00Z"
        }
        """#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(MCPTaskWire.self, from: missingTTL))
        XCTAssertFalse(MCPTaskStatus.working.isTerminal)
        XCTAssertFalse(MCPTaskStatus.inputRequired.isTerminal)
        XCTAssertTrue(MCPTaskStatus.completed.isTerminal)
        XCTAssertTrue(MCPTaskStatus.failed.isTerminal)
        XCTAssertTrue(MCPTaskStatus.cancelled.isTerminal)
    }

    func testTaskAugmentationAndToolExecutionEncodeExactly() throws {
        let tool = MCP.Tool(
            name: "long_running",
            description: "Long operation",
            inputSchema: .object(["type": .string("object")]),
            execution: .init(taskSupport: .required))
        let toolObject = try object(tool)
        XCTAssertEqual(
            ((toolObject["execution"] as? [String: Any])?["taskSupport"])
                as? String,
            "required")

        let call = CallTool.request(.init(
            name: "long_running",
            arguments: ["value": .string("safe")],
            task: .init(ttl: 60_000)))
        let callObject = try object(call)
        let callParams = try XCTUnwrap(
            callObject["params"] as? [String: Any])
        XCTAssertEqual(
            (callParams["task"] as? [String: Any])?["ttl"] as? Int,
            60_000)

        let sampling = CreateSamplingMessage.request(.init(
            messages: [.user(.text("hello"))],
            task: .init(ttl: 30_000),
            maxTokens: 128))
        let samplingParams = try XCTUnwrap(
            try object(sampling)["params"] as? [String: Any])
        XCTAssertEqual(
            (samplingParams["task"] as? [String: Any])?["ttl"] as? Int,
            30_000)

        let elicitation = CreateElicitation.request(.form(.init(
            message: "Choose a value",
            task: .init(ttl: 45_000),
            requestedSchema: .init())))
        let elicitationParams = try XCTUnwrap(
            try object(elicitation)["params"] as? [String: Any])
        XCTAssertEqual(
            (elicitationParams["task"] as? [String: Any])?["ttl"] as? Int,
            45_000)
    }

    func testTasksCapabilityIsTopLevelExhaustiveAndProfileGated() throws {
        let codex = SDKPatchCompatibility.makeCapabilityProbe(extended: false)
        XCTAssertNil(codex.tasks)

        let extended = SDKPatchCompatibility.makeCapabilityProbe(extended: true)
        let object = try object(extended)
        let tasks = try XCTUnwrap(object["tasks"] as? [String: Any])
        XCTAssertNotNil(tasks["list"] as? [String: Any])
        XCTAssertNotNil(tasks["cancel"] as? [String: Any])
        let requests = try XCTUnwrap(
            tasks["requests"] as? [String: Any])
        XCTAssertNotNil(
            ((requests["sampling"] as? [String: Any])?["createMessage"])
                as? [String: Any])
        XCTAssertNotNil(
            ((requests["elicitation"] as? [String: Any])?["create"])
                as? [String: Any])
        XCTAssertNil(object["experimental"])

        let serverTasks = MCPServerTaskCapabilities(
            list: .init(),
            cancel: .init(),
            requests: .init(tools: .init(call: .init())))
        let negotiated = MCPNegotiatedCapabilitySet(
            server: .init(tasks: serverTasks),
            client: extended)
        XCTAssertTrue(negotiated.capabilities.contains(.tasks))
        XCTAssertTrue(negotiated.remoteTaskGetAndResult)
        XCTAssertTrue(negotiated.remoteTaskList)
        XCTAssertTrue(negotiated.remoteTaskCancel)
        XCTAssertTrue(negotiated.remoteTaskToolCall)
        XCTAssertTrue(negotiated.clientHostedTaskList)
        XCTAssertTrue(negotiated.clientHostedTaskCancel)
        XCTAssertTrue(negotiated.clientHostedTaskSampling)
        XCTAssertTrue(negotiated.clientHostedTaskElicitation)

        let noOptionalOperations = MCPNegotiatedCapabilitySet(
            server: .init(tasks: .init(
                requests: .init(tools: .init(call: .init())))),
            client: extended)
        XCTAssertTrue(noOptionalOperations.remoteTaskGetAndResult)
        XCTAssertFalse(noOptionalOperations.remoteTaskList)
        XCTAssertFalse(noOptionalOperations.remoteTaskCancel)
        XCTAssertTrue(noOptionalOperations.remoteTaskToolCall)

        let missingServerNegotiation = MCPNegotiatedCapabilitySet(
            server: .init(),
            client: extended)
        XCTAssertFalse(
            missingServerNegotiation.capabilities.contains(.tasks))
        XCTAssertFalse(missingServerNegotiation.remoteTaskGetAndResult)
    }

    func testCreateTaskMetadataKeysRemainOpaqueAndExact() throws {
        let task = MCPTaskWire(
            taskId: "opaque-task",
            status: .working,
            createdAt: "2025-11-25T00:00:00Z",
            lastUpdatedAt: "2025-11-25T00:00:00Z",
            ttl: 60_000)
        let result = MCPCreateTaskResult(
            task: task,
            _meta: Metadata(additionalFields: [
                MCPModelImmediateResponseMetadataKey:
                    .string("Task accepted"),
            ]))
        let object = try object(result)
        let metadata = try XCTUnwrap(
            object["_meta"] as? [String: Any])
        XCTAssertEqual(
            metadata[MCPModelImmediateResponseMetadataKey] as? String,
            "Task accepted")
        XCTAssertNil(metadata[MCPRelatedTaskMetadataKey])
    }

    func testTaskAugmentedMethodResultsUseExactCreateTaskShape() throws {
        let task = MCPTaskWire(
            taskId: "created-task",
            status: .inputRequired,
            createdAt: "2025-11-25T00:00:00Z",
            lastUpdatedAt: "2025-11-25T00:00:00Z",
            ttl: 60_000)

        let toolResult = CallTool.Result(task: task)
        let toolObject = try object(toolResult)
        XCTAssertEqual(
            (toolObject["task"] as? [String: Any])?["taskId"] as? String,
            "created-task")
        XCTAssertNil(toolObject["content"])
        let decodedTool = try JSONDecoder().decode(
            CallTool.Result.self,
            from: JSONEncoder().encode(toolResult))
        XCTAssertEqual(decodedTool.task, task)
        XCTAssertTrue(decodedTool.content.isEmpty)

        let samplingResult = CreateSamplingMessage.Result(task: task)
        let samplingObject = try object(samplingResult)
        XCTAssertEqual(
            (samplingObject["task"] as? [String: Any])?["status"] as? String,
            "input_required")
        XCTAssertNil(samplingObject["model"])
        XCTAssertEqual(
            try JSONDecoder().decode(
                CreateSamplingMessage.Result.self,
                from: JSONEncoder().encode(samplingResult)).task,
            task)

        let elicitationResult = CreateElicitation.Result(task: task)
        let elicitationObject = try object(elicitationResult)
        XCTAssertNotNil(elicitationObject["task"])
        XCTAssertNil(elicitationObject["action"])
        XCTAssertEqual(
            try JSONDecoder().decode(
                CreateElicitation.Result.self,
                from: JSONEncoder().encode(elicitationResult)).task,
            task)
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
