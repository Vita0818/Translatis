import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisProviders

private struct ToolSpecMetadataHTTP: HTTPByteStreaming {
    func stream(
        _: URLRequest
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

final class ToolSpecMetadataTests: XCTestCase {
    func testLegacyToolSpecDecodeKeepsHistoricalFunctionDefaults()
        throws {
        let legacy = """
        {
          "name": "inspect",
          "description": "Inspect a value",
          "parameters": {"type":"object"}
        }
        """
        let decoded = try JSONDecoder().decode(
            ToolSpec.self,
            from: Data(legacy.utf8))

        XCTAssertEqual(decoded.kind, .function)
        XCTAssertNil(decoded.strict)
        XCTAssertNil(decoded.deferLoading)
        XCTAssertNil(decoded.outputSchema)
        XCTAssertFalse(decoded.supportsParallelCalls)
        XCTAssertNil(decoded.execution)
        XCTAssertTrue(decoded.namespaceTools.isEmpty)
        XCTAssertEqual(
            OpenAIWireProvider.toolJSON(decoded),
            .object([
                "type": .string("function"),
                "function": .object([
                    "name": .string("inspect"),
                    "description": .string("Inspect a value"),
                    "parameters": .object([
                        "type": .string("object"),
                    ]),
                ]),
            ]))
    }

    func testFunctionMetadataUsesExactWireFieldsWithoutHostOnlyFlags() {
        let output: JSONValue = .object([
            "type": .string("object"),
        ])
        let spec = ToolSpec(
            name: "deferred",
            description: "Deferred function",
            parameters: .object(["type": .string("object")]),
            strict: false,
            deferLoading: true,
            outputSchema: output,
            supportsParallelCalls: true)

        XCTAssertEqual(
            OpenAIWireProvider.toolJSON(spec),
            .object([
                "type": .string("function"),
                "function": .object([
                    "name": .string("deferred"),
                    "description": .string("Deferred function"),
                    "parameters": .object([
                        "type": .string("object"),
                    ]),
                    "strict": .bool(false),
                    "defer_loading": .bool(true),
                    "output_schema": output,
                ]),
            ]))
    }

    func testChatCompletionsOmitsResponsesOnlyFunctionMetadata()
        throws {
        let output: JSONValue = .object([
            "type": .string("object"),
        ])
        let spec = ToolSpec(
            name: "portable",
            description: "Portable function",
            parameters: .object(["type": .string("object")]),
            strict: true,
            deferLoading: true,
            outputSchema: output)

        XCTAssertEqual(
            OpenAIWireProvider.chatCompletionsToolJSON(spec),
            .object([
                "type": .string("function"),
                "function": .object([
                    "name": .string("portable"),
                    "description": .string("Portable function"),
                    "parameters": .object([
                        "type": .string("object"),
                    ]),
                    "strict": .bool(true),
                ]),
            ]))
        XCTAssertEqual(
            OpenAIWireProvider.responsesToolJSON(spec),
            .object([
                "type": .string("function"),
                "name": .string("portable"),
                "description": .string("Portable function"),
                "parameters": .object([
                    "type": .string("object"),
                ]),
                "strict": .bool(true),
                "defer_loading": .bool(true),
                "output_schema": output,
            ]))
    }

    func testNamespaceAndToolSearchMatchCodexResponsesShapes() {
        let child = ToolSpec(
            name: "create_event",
            description: "Create an event",
            parameters: .object(["type": .string("object")]),
            strict: false,
            deferLoading: true,
            supportsParallelCalls: true)
        let namespace = ToolSpec(
            name: "mcp__calendar__",
            description:
                "Tools in the mcp__calendar__ namespace.",
            parameters: .object([:]),
            kind: .namespace,
            supportsParallelCalls: true,
            namespaceTools: [child])
        XCTAssertEqual(
            OpenAIWireProvider.toolJSON(namespace),
            .object([
                "type": .string("namespace"),
                "name": .string("mcp__calendar__"),
                "description": .string(
                    "Tools in the mcp__calendar__ namespace."),
                "tools": .array([
                    .object([
                        "type": .string("function"),
                        "name": .string("create_event"),
                        "description": .string("Create an event"),
                        "parameters": .object([
                            "type": .string("object"),
                        ]),
                        "strict": .bool(false),
                        "defer_loading": .bool(true),
                    ]),
                ]),
            ]))

        let parameters: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string")]),
                "limit": .object(["type": .string("number")]),
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false),
        ])
        XCTAssertEqual(
            OpenAIWireProvider.toolJSON(.toolSearch(
                description: "# Tool discovery",
                parameters: parameters)),
            .object([
                "type": .string("tool_search"),
                "execution": .string("client"),
                "description": .string("# Tool discovery"),
                "parameters": parameters,
            ]))
    }

    func testParallelToolCallsIsARequestWideWireCapability()
        throws {
        let endpoint = ProviderEndpoint(
            id: "tool-metadata",
            baseURL: URL(string: "https://example.test/v1")!,
            apiKeyRef: KeychainRef(service: "s", account: "a"),
            wire: .openai)
        let provider = OpenAIWireProvider(
            endpoint: endpoint,
            apiKey: "key",
            http: ToolSpecMetadataHTTP())
        let request = try provider.buildAgentRequest(AgentRequest(
            model: ModelID(rawValue: "model"),
            messages: [.user("hi")],
            tools: [
                ToolSpec(
                    name: "parallel",
                    description: "Parallel-safe",
                    parameters: .object([:]),
                    supportsParallelCalls: true),
            ],
            parallelToolCalls: true))
        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: try XCTUnwrap(request.httpBody))
        guard case .object(let body) = value else {
            return XCTFail("request must be an object")
        }
        XCTAssertEqual(
            body["parallel_tool_calls"],
            .bool(true))
        guard case .array(let tools)? = body["tools"],
              case .object(let wrapper) = tools.first,
              case .object(let function)? = wrapper["function"] else {
            return XCTFail("function tool missing")
        }
        XCTAssertNil(function["supports_parallel_tool_calls"])
    }
}
