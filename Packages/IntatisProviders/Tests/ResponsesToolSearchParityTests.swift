import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisProviders

private struct ResponsesParityHTTP: HTTPByteStreaming {
    let chunks: [Data]

    func stream(
        _: URLRequest
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

final class ResponsesToolSearchParityTests: XCTestCase {
    private let endpoint = ProviderEndpoint(
        id: "responses",
        baseURL: URL(string: "https://example.test/v1")!,
        apiKeyRef: KeychainRef(service: "s", account: "a"),
        wire: .openai)

    func testToolSearchCapabilityRequiresExplicitModelMetadata()
        throws {
        XCTAssertFalse(
            ModelCapabilityMetadata
                .declaredCapabilities(in: [:])
                .contains(.toolSearch))
        XCTAssertTrue(
            ModelCapabilityMetadata
                .declaredCapabilities(in: [
                    "supports_search_tool":
                        .bool(true),
                ])
                .contains(.toolSearch))
        XCTAssertFalse(
            ModelCapabilityMetadata
                .declaredCapabilities(in: [
                    "capabilities": .array([
                        .string("tool_search"),
                    ]),
                    "supports_search_tool":
                        .bool(false),
                ])
                .contains(.toolSearch))
    }

    func testHostedWebSearchCapabilityIsExplicitAndDistinctFromToolSearch()
        throws
    {
        let hosted = ModelCapabilityMetadata.declaredCapabilities(in: [
            "capabilities": .array([
                .string("hosted_web_search"),
            ]),
        ])
        XCTAssertTrue(hosted.contains(.hostedWebSearch))
        XCTAssertFalse(hosted.contains(.toolSearch))

        let toolSearch = ModelCapabilityMetadata.declaredCapabilities(in: [
            "supports_search_tool": .bool(true),
        ])
        XCTAssertTrue(toolSearch.contains(.toolSearch))
        XCTAssertFalse(toolSearch.contains(.hostedWebSearch))

        let explicitFalse = ModelCapabilityMetadata.declaredCapabilities(in: [
            "capabilities": .array([
                .string("hosted_web_search"),
            ]),
            "supports_hosted_web_search": .bool(false),
        ])
        XCTAssertFalse(explicitFalse.contains(.hostedWebSearch))
    }

    func testEndpointCapabilityConfigurationRoundTripsAndLegacyDefaultsClosed()
        throws {
        let configured = ProviderEndpoint(
            id: "configured",
            baseURL: URL(
                string: "https://example.test/v1")!,
            apiKeyRef: KeychainRef(
                service: "s",
                account: "a"),
            wire: .openai,
            modelCapabilities: [
                "model": [
                    .chat,
                    .toolCalling,
                    .toolSearch,
                ],
            ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(configured)
        let decoded = try JSONDecoder().decode(
            ProviderEndpoint.self,
            from: encoded)
        XCTAssertEqual(decoded, configured)
        XCTAssertTrue(
            decoded.capabilities(
                for: ModelID(rawValue: "model"))
                .contains(.toolSearch))

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: encoded)
                as? [String: Any])
        legacyObject.removeValue(
            forKey: "modelCapabilities")
        let legacyData =
            try JSONSerialization.data(
                withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(
            ProviderEndpoint.self,
            from: legacyData)
        XCTAssertFalse(
            legacy.capabilities(
                for: ModelID(rawValue: "model"))
                .contains(.toolSearch))
    }

    func testToolSearchOutputIsAResponsesHistoryItemAndNeverATopLevelTool()
        throws {
        let provider = OpenAIWireProvider(
            endpoint: endpoint,
            apiKey: "key",
            http: ResponsesParityHTTP(chunks: []),
            toolCallingCapabilities:
                .responsesToolSearch)
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
        let request = AgentRequest(
            model: ModelID(rawValue: "gpt-responses"),
            messages: [
                .system("trusted"),
                .user("find calendar tools"),
                .assistant(toolCalls: [
                    ToolCall(
                        id: "search-1",
                        name: "tool_search",
                        arguments:
                            #"{"limit":1,"query":"calendar create"}"#,
                        kind: .toolSearch,
                        execution: "client"),
                ]),
                .toolSearchOutput(
                    id: "search-1",
                    output: ModelToolSearchOutput(
                        tools: [deferred])),
                .assistant(toolCalls: [
                    ToolCall(
                        id: "calendar-1",
                        name: "mcp__calendar__create_event",
                        arguments: #"{"title":"Review"}"#,
                        namespace: "mcp__calendar__"),
                ]),
                .tool(id: "calendar-1", content: "created"),
            ],
            tools: [
                .toolSearch(
                    description: "# Tool discovery",
                    parameters: .object([
                        "type": .string("object"),
                    ])),
            ],
            parallelToolCalls: true)

        let encoded = try provider.buildAgentRequest(request)
        XCTAssertEqual(encoded.url?.path, "/v1/responses")
        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: try XCTUnwrap(encoded.httpBody))
        guard case .object(let body) = value,
              case .array(let tools)? = body["tools"],
              case .array(let input)? = body["input"] else {
            return XCTFail("missing Responses request arrays")
        }

        XCTAssertNil(body["messages"])
        XCTAssertEqual(body["instructions"], .string("trusted"))
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(
            tools.first,
            .object([
                "type": .string("tool_search"),
                "execution": .string("client"),
                "description": .string("# Tool discovery"),
                "parameters": .object([
                    "type": .string("object"),
                ]),
            ]))
        XCTAssertFalse(tools.contains(deferred))

        let inputObjects: [[String: JSONValue]] = input.compactMap {
            guard case .object(let object) = $0 else { return nil }
            return object
        }
        let searchOutput = try XCTUnwrap(inputObjects.first {
            $0["type"] == .string("tool_search_output")
        })
        XCTAssertEqual(searchOutput["call_id"], .string("search-1"))
        XCTAssertEqual(searchOutput["status"], .string("completed"))
        XCTAssertEqual(searchOutput["execution"], .string("client"))
        XCTAssertEqual(searchOutput["tools"], .array([deferred]))

        let searchCall = try XCTUnwrap(inputObjects.first {
            $0["type"] == .string("tool_search_call")
        })
        XCTAssertEqual(searchCall["call_id"], .string("search-1"))
        XCTAssertEqual(
            searchCall["arguments"],
            .object([
                "limit": .number(1),
                "query": .string("calendar create"),
            ]))

        let functionCall = try XCTUnwrap(inputObjects.first {
            $0["type"] == .string("function_call")
        })
        XCTAssertEqual(
            functionCall["namespace"],
            .string("mcp__calendar__"))
        XCTAssertEqual(
            functionCall["name"],
            .string("create_event"))
    }

    func testResponsesCanonicalizesReasoningAliasesToNestedWireShape()
        throws {
        let configuredEndpoint = ProviderEndpoint(
            id: "responses",
            baseURL: URL(
                string: "https://example.test/v1")!,
            apiKeyRef: KeychainRef(
                service: "s",
                account: "a"),
            wire: .openai,
            modelRequestOptions: [
                "gpt-responses": [
                    "reasoningEffort":
                        .string("xhigh"),
                    "reasoning": .object([
                        "summary": .string("auto"),
                    ]),
                ],
            ])
        let provider = OpenAIWireProvider(
            endpoint: configuredEndpoint,
            apiKey: "key",
            http: ResponsesParityHTTP(chunks: []),
            toolCallingCapabilities:
                .responsesToolSearch)

        let encoded = try provider.buildAgentRequest(
            AgentRequest(
                model: ModelID(
                    rawValue: "gpt-responses"),
                messages: [.user("find a tool")],
                tools: [
                    .toolSearch(
                        description: "Search",
                        parameters: .object([
                            "type": .string("object"),
                        ])),
                ]))
        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: try XCTUnwrap(encoded.httpBody))
        guard case .object(let body) = value else {
            return XCTFail(
                "request body is not an object")
        }

        XCTAssertNil(body["reasoningEffort"])
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertEqual(
            body["reasoning"],
            .object([
                "effort": .string("xhigh"),
                "summary": .string("auto"),
            ]))
    }

    func testResponsesStreamParsesToolSearchAndNamespaceFunctionCalls()
        async throws {
        let stream = """
        data: {"type":"response.output_item.done","item":{"type":"tool_search_call","call_id":"search-1","status":"completed","execution":"client","arguments":{"query":"calendar","limit":1}}}

        data: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"call-1","namespace":"mcp__calendar__","name":"create_event","arguments":"{\\"title\\":\\"Review\\"}"}}

        data: {"type":"response.completed","response":{"id":"resp-1","usage":{"input_tokens":11,"input_tokens_details":{"cached_tokens":3},"output_tokens":5,"total_tokens":16}}}

        """
        let provider = OpenAIWireProvider(
            endpoint: endpoint,
            apiKey: "key",
            http: ResponsesParityHTTP(
                chunks: [Data(stream.utf8)]),
            toolCallingCapabilities:
                .responsesToolSearch)
        var calls: [ToolCall] = []
        var usage: Usage?
        var didComplete = false

        for try await chunk in provider.stream(AgentRequest(
            model: ModelID(rawValue: "gpt-responses"),
            messages: [.user("find a tool")],
            tools: [
                .toolSearch(
                    description: "Search",
                    parameters: .object([
                        "type": .string("object"),
                    ])),
            ])) {
            switch chunk {
            case .toolCalls(let emitted):
                calls.append(contentsOf: emitted)
            case .usage(let value):
                usage = value
            case .done(let reason):
                didComplete = reason == "completed"
            case .textDelta:
                break
            }
        }

        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].kind, .toolSearch)
        XCTAssertEqual(calls[0].name, "tool_search")
        XCTAssertEqual(calls[0].execution, "client")
        XCTAssertEqual(
            calls[1].name,
            "mcp__calendar__create_event")
        XCTAssertEqual(calls[1].namespace, "mcp__calendar__")
        XCTAssertEqual(usage?.promptTokens, 11)
        XCTAssertEqual(usage?.cachedPromptTokens, 3)
        XCTAssertEqual(usage?.completionTokens, 5)
        XCTAssertEqual(usage?.totalTokens, 16)
        XCTAssertTrue(didComplete)
    }

    func testUnsupportedRouteCannotSwitchToResponsesForToolSearch()
        throws {
        let provider = OpenAIWireProvider(
            endpoint: endpoint,
            apiKey: "key",
            http: ResponsesParityHTTP(chunks: []))
        let request = AgentRequest(
            model: ModelID(rawValue: "chat-compatible-only"),
            messages: [.user("find a tool")],
            tools: [
                .toolSearch(
                    description: "Search",
                    parameters: .object([
                        "type": .string("object"),
                    ])),
            ])

        XCTAssertThrowsError(
            try provider.buildAgentRequest(request)
        ) { error in
            XCTAssertEqual(
                error as?
                    ToolCallingProviderCapabilityError,
                .toolSearchUnsupported)
        }
    }

    func testLegacyToolCallDecodeDefaultsToFunction() throws {
        let decoded = try JSONDecoder().decode(
            ToolCall.self,
            from: Data(
                #"{"id":"call-1","name":"inspect","arguments":"{}"}"#
                    .utf8))
        XCTAssertEqual(decoded.kind, .function)
        XCTAssertNil(decoded.namespace)
        XCTAssertNil(decoded.status)
        XCTAssertNil(decoded.execution)
    }
}
