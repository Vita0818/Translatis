import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisMCP
@testable import IntatisCodexRuntime

private actor NativeDynamicToolCapture {
    private var calls: [CodexRuntimeDynamicToolCall] = []

    func record(_ call: CodexRuntimeDynamicToolCall) {
        calls.append(call)
    }

    func snapshot() -> [CodexRuntimeDynamicToolCall] { calls }
}

final class CodexNativeSubagentIntegrationTests: XCTestCase {
    func testPinnedRuntimeFlatV2ChildUsesPresetWorkspaceModelAndDynamicTool()
        async throws
    {
        let executable: URL
        do {
            executable = try CodexRuntimeExecutable.locate()
            _ = try CodexRuntimeExecutable.verifiedVersion(at: executable)
        } catch {
            throw XCTSkip(
                "Pinned Codex Runtime is not installed for native subagent integration")
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootWorkspace = temporary.appendingPathComponent(
            "root",
            isDirectory: true)
        let childWorkspace = temporary.appendingPathComponent(
            "child",
            isDirectory: true)
        let runtimeRoot = temporary.appendingPathComponent(
            "runtime",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootWorkspace,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: childWorkspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let server = try LocalResponsesServer { _, request in
            let model = request["model"] as? String ?? ""
            if model == "child-model" {
                let input = request["input"] as? [[String: Any]] ?? []
                let hasToolOutput = input.contains {
                    $0["type"] as? String == "function_call_output"
                        && $0["call_id"] as? String
                            == "child-echo-call"
                }
                if !hasToolOutput {
                    return Self.functionCallSSE(
                        responseID: "resp-child-tool",
                        model: model,
                        itemID: "fc-child-echo",
                        callID: "child-echo-call",
                        name: "business_echo",
                        arguments: Self.json([
                            "value": "from child",
                        ]))
                }
                let hasKnowledgeOutput = input.contains {
                    $0["type"] as? String == "function_call_output"
                        && $0["call_id"] as? String
                            == "child-knowledge-call"
                }
                if !hasKnowledgeOutput {
                    return Self.functionCallSSE(
                        responseID: "resp-child-knowledge",
                        model: model,
                        itemID: "fc-child-knowledge",
                        callID: "child-knowledge-call",
                        name: "search_knowledge",
                        arguments: "{}")
                }
                return responsesMessageSSE(
                    responseID: "resp-child",
                    messageID: "msg-child",
                    model: model,
                    text: "CHILD_OK")
            }
            let input = request["input"] as? [[String: Any]] ?? []
            let hasSpawnOutput = input.contains {
                $0["type"] as? String == "function_call_output"
                    && $0["call_id"] as? String == "spawn-call"
            }
            if hasSpawnOutput {
                return responsesMessageSSE(
                    responseID: "resp-root-final",
                    messageID: "msg-root-final",
                    model: model,
                    text: "ROOT_OK")
            }
            let arguments = Self.json([
                "task_name": "native_probe",
                "message": "Reply with CHILD_OK and stop.",
                "fork_turns": "none",
                "agent_type": "research",
                "workspace": "research",
            ])
            let item: [String: Any] = [
                "id": "fc-spawn",
                "type": "function_call",
                "status": "completed",
                "name": "spawn_agent",
                "call_id": "spawn-call",
                "arguments": arguments,
            ]
            return responsesSSE([
                Self.json([
                    "type": "response.created",
                    "response": [
                        "id": "resp-root-spawn",
                        "status": "in_progress",
                        "model": model,
                        "output": [],
                    ],
                ]),
                Self.json([
                    "type": "response.output_item.done",
                    "output_index": 0,
                    "item": item,
                ]),
                Self.json([
                    "type": "response.completed",
                    "response": [
                        "id": "resp-root-spawn",
                        "status": "completed",
                        "model": model,
                        "output": [item],
                        "usage": Self.usage,
                    ],
                ]),
            ])
        }
        defer { server.stop() }
        let mcpServer = try LocalMCPServer()
        defer { mcpServer.stop() }
        let baseURL = try server.baseURL
        let nativeMCP = CodexRuntimeMCPConfiguration(
            servers: [.init(
                name: "native_probe",
                required: true,
                supportsParallelToolCalls: false,
                startupTimeoutSeconds: 5,
                toolTimeoutSeconds: 5,
                enabledTools: ["native_mcp_probe"],
                disabledTools: [],
                defaultApprovalMode: .auto,
                toolApprovalModes: [:],
                http: .init(
                    url: try mcpServer.endpoint,
                    bearerTokenEnvironmentVariable: nil,
                    literalHeaders: [:],
                    environmentHeaders: [:],
                    oauthResource: nil,
                    oauthClientID: nil,
                    oauthScopes: []))],
            processEnvironment: [:],
            identity: "native-mcp-subagent-scope-v1")
        let capture = NativeDynamicToolCapture()
        let dynamicTools = CodexRuntimeDynamicTools(
            toolsetID: "native-subagent-business-v1",
            specs: [
                CodexRuntimeDynamicToolSpec(
                    name: "business_echo",
                    description: "Echo one value.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "value": .object([
                                "type": .string("string"),
                            ]),
                        ]),
                        "required": .array([.string("value")]),
                        "additionalProperties": .bool(false),
                    ])),
                CodexRuntimeDynamicToolSpec(
                    name: "search_knowledge",
                    description: "Search one host-approved Knowledge mount.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "additionalProperties": .bool(false),
                    ])),
            ],
            handler: { call in
                await capture.record(call)
                return .text("echoed by Intatis")
            })
        let configuration = CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "native-subagent"),
                mode: .cowork,
                workspaceURL: rootWorkspace,
                runtimeRootURL: runtimeRoot,
                route: ResponsesRuntimeRoute(
                    endpointID: "root",
                    model: ModelID(rawValue: "root-model"),
                    baseURL: baseURL,
                    bearerToken: "root-token",
                    providerOptions: [
                        "require_parameters": .bool(true),
                        "allow_fallbacks": .bool(false),
                    ],
                    requestAdapter: .openRouter),
                approvalReviewer: .user,
                executableOverride: executable,
                dynamicTools: dynamicTools,
                mcpConfiguration: nativeMCP,
                childProfiles: [CodexRuntimeChildProfile(
                    roleName: "research",
                    description: "Use for the native child probe.",
                    workspaceURL: childWorkspace,
                    route: ResponsesRuntimeRoute(
                        endpointID: "child",
                        model: ModelID(rawValue: "child-model"),
                        baseURL: baseURL,
                        bearerToken: "child-token",
                        reasoningEffort: "medium",
                        providerOptions: [
                            "require_parameters": .bool(true),
                            "allow_fallbacks": .bool(false),
                        ],
                        requestAdapter: .openRouter),
                    sandbox: .workspaceWrite,
                    knowledgeCapabilities: [.searchKnowledge])])
        let session = CodexAppServerSession(
            configuration: configuration)
        _ = try await session.start()
        let result = try await session.runTurn(
            text: "Run the native child probe.")
        XCTAssertTrue(
            result.succeeded,
            "result=\(result) requests=\(Self.json(server.requests()))")

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let requests = server.requests()
            let descendants = await session.descendantThreadDescriptors()
            if requests.filter({
                $0["model"] as? String == "child-model"
            }).count >= 2,
               (await capture.snapshot()).count >= 2,
               descendants.first?.requestedModel == "child-model",
               descendants.first?.runtimeWorkspaceRoots.isEmpty == false {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let requests = server.requests()
        let descendants = await session.descendantThreadDescriptors()
        let dynamicCalls = await capture.snapshot()
        await session.shutdown()

        let firstRoot = try XCTUnwrap(requests.first(where: {
            $0["model"] as? String == "root-model"
        }))
        let rootTools = firstRoot["tools"] as? [[String: Any]] ?? []
        let rootToolsJSON = Self.json(rootTools)
        XCTAssertTrue(rootTools.contains {
            $0["type"] as? String == "function"
                && $0["name"] as? String == "spawn_agent"
        }, rootToolsJSON)
        let spawnTool = try XCTUnwrap(rootTools.first(where: {
            $0["type"] as? String == "function"
                && $0["name"] as? String == "spawn_agent"
        }))
        let spawnProperties = try XCTUnwrap(
            (spawnTool["parameters"] as? [String: Any])?["properties"]
                as? [String: Any],
            "spawn tool=\(Self.json(spawnTool))")
        XCTAssertEqual(
            (spawnProperties["agent_type"] as? [String: Any])?["enum"]
                as? [String],
            ["research"])
        XCTAssertEqual(
            (spawnProperties["workspace"] as? [String: Any])?["enum"]
                as? [String],
            ["research"])
        XCTAssertNil(spawnProperties["model"])
        XCTAssertNil(spawnProperties["reasoning_effort"])
        XCTAssertNil(spawnProperties["service_tier"])
        XCTAssertFalse(rootTools.contains {
            $0["type"] as? String == "namespace"
                && $0["name"] as? String != "mcp__native_probe"
        }, rootToolsJSON)
        XCTAssertTrue(rootTools.contains {
            $0["type"] as? String == "function"
                && $0["name"] as? String == "business_echo"
        })
        XCTAssertTrue(
            Self.hasNativeMCPProbe(rootTools),
            "root tools=\(rootToolsJSON)")

        let childRequest = try XCTUnwrap(requests.first(where: {
            $0["model"] as? String == "child-model"
        }), "requests=\(Self.json(requests))")
        let childTools = childRequest["tools"] as? [[String: Any]] ?? []
        XCTAssertTrue(childTools.contains {
            $0["type"] as? String == "function"
                && $0["name"] as? String == "business_echo"
        }, "child tools=\(Self.json(childTools))")
        XCTAssertFalse(
            Self.hasNativeMCPProbe(childTools),
            "child tools=\(Self.json(childTools))")
        XCTAssertTrue(mcpServer.methods().contains("initialize"))
        XCTAssertTrue(mcpServer.methods().contains("tools/list"))
        let child = try XCTUnwrap(
            descendants.first,
            "requests=\(Self.json(requests))")
        XCTAssertEqual(child.agentRole, "research", "child=\(child)")
        XCTAssertEqual(
            child.agentPath,
            "/root/native_probe",
            "child=\(child)")
        XCTAssertFalse(child.isArchived, "child=\(child)")
        XCTAssertEqual(
            child.requestedModel,
            "child-model",
            "child=\(child)")
        let expectedChildWorkspace = childWorkspace
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        XCTAssertEqual(
            URL(fileURLWithPath: child.cwd)
                .resolvingSymlinksInPath().standardizedFileURL.path,
            expectedChildWorkspace,
            "child=\(child)")
        XCTAssertEqual(
            child.runtimeWorkspaceRoots.map {
                URL(fileURLWithPath: $0)
                    .resolvingSymlinksInPath().standardizedFileURL.path
            },
            [expectedChildWorkspace],
            "child=\(child)")
        XCTAssertEqual(dynamicCalls.count, 2)
        XCTAssertTrue(dynamicCalls.allSatisfy {
            $0.threadID == child.threadID
                && $0.workspaceURL?.path == expectedChildWorkspace
        })
        XCTAssertEqual(dynamicCalls.map(\.tool), [
            "business_echo",
            "search_knowledge",
        ])
        XCTAssertEqual(
            dynamicCalls.last?.knowledgeCapabilities,
            [.searchKnowledge])

        let requestCountBeforeResume = server.requests().count
        let resumedSession = CodexAppServerSession(
            configuration: configuration)
        _ = try await resumedSession.start()
        let restoredDeadline = Date().addingTimeInterval(10)
        var restoredChild: CodexRuntimeThreadDescriptor?
        while Date() < restoredDeadline {
            restoredChild = await resumedSession
                .descendantThreadDescriptors().first
            if restoredChild != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let exactRestoredChild = try XCTUnwrap(restoredChild)
        _ = try await resumedSession.sendMessage(
            toDescendantThreadID: exactRestoredChild.threadID,
            text: "Confirm the restored child remains active.")
        let restoredTurnDeadline = Date().addingTimeInterval(10)
        while Date() < restoredTurnDeadline {
            if server.requests().dropFirst(requestCountBeforeResume)
                .contains(where: {
                    $0["model"] as? String == "child-model"
                }) {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let restoredChildRequest = try XCTUnwrap(
            server.requests().dropFirst(requestCountBeforeResume)
                .last(where: {
                    $0["model"] as? String == "child-model"
                }))
        let restoredChildTools = restoredChildRequest["tools"]
            as? [[String: Any]] ?? []
        await resumedSession.shutdown()
        XCTAssertFalse(
            Self.hasNativeMCPProbe(restoredChildTools),
            "restored child tools=\(Self.json(restoredChildTools))")
    }

    private static let usage: [String: Any] = [
        "input_tokens": 10,
        "input_tokens_details": ["cached_tokens": 0],
        "output_tokens": 2,
        "output_tokens_details": ["reasoning_tokens": 0],
        "total_tokens": 12,
    ]

    private static func hasNativeMCPProbe(
        _ tools: [[String: Any]]
    ) -> Bool {
        tools.contains { tool in
            if (tool["name"] as? String)?.contains(
                    "native_mcp_probe") == true {
                return true
            }
            return (tool["tools"] as? [[String: Any]])?.contains {
                ($0["name"] as? String)?.contains(
                    "native_mcp_probe") == true
            } == true
        }
    }

    private static func functionCallSSE(
        responseID: String,
        model: String,
        itemID: String,
        callID: String,
        name: String,
        arguments: String
    ) -> String {
        let item: [String: Any] = [
            "id": itemID,
            "type": "function_call",
            "status": "completed",
            "name": name,
            "call_id": callID,
            "arguments": arguments,
        ]
        return responsesSSE([
            json([
                "type": "response.created",
                "response": [
                    "id": responseID,
                    "status": "in_progress",
                    "model": model,
                    "output": [],
                ],
            ]),
            json([
                "type": "response.output_item.done",
                "output_index": 0,
                "item": item,
            ]),
            json([
                "type": "response.completed",
                "response": [
                    "id": responseID,
                    "status": "completed",
                    "model": model,
                    "output": [item],
                    "usage": usage,
                ],
            ]),
        ])
    }

    private static func json(_ value: Any) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
