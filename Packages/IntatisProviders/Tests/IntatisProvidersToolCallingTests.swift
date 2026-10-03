import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisProviders

private struct FakeHTTP2: HTTPByteStreaming {
    let chunks: [Data]
    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private struct FixedToolSecretResolver: SecretResolver {
    func secret(for ref: KeychainRef) async throws -> String {
        "test-key"
    }
}

private struct ToolStreamAttempt {
    var chunks: [Data]
    var error: Error?
}

private final class SequencedToolHTTP: HTTPByteStreaming, @unchecked Sendable {
    private let queue = DispatchQueue(label: "intatis.tests.sequenced-tool-http")
    private var index = 0
    private let attempts: [ToolStreamAttempt]

    init(attempts: [ToolStreamAttempt]) {
        self.attempts = attempts
    }

    var attemptCount: Int {
        queue.sync { index }
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        let attempt = queue.sync { () -> ToolStreamAttempt in
            let value = attempts[min(index, attempts.count - 1)]
            index += 1
            return value
        }
        return AsyncThrowingStream { continuation in
            for chunk in attempt.chunks {
                continuation.yield(chunk)
            }
            if let error = attempt.error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }
}

private func fragment(_ s: String, size: Int) -> [Data] {
    let bytes = Array(s.utf8)
    var out: [Data] = []
    var i = 0
    while i < bytes.count {
        let end = min(i + size, bytes.count)
        out.append(Data(bytes[i..<end]))
        i = end
    }
    return out
}

private let endpoint = ProviderEndpoint(
    id: "e",
    baseURL: URL(string: "https://example.test/v1")!,
    apiKeyRef: KeychainRef(service: "s", account: "a"),
    wire: .openai
)

private let nonHTTPToolEndpoint = ProviderEndpoint(
    id: "bad-agent",
    baseURL: URL(string: "https://example.test/v1")!,
    chatEndpoint: URL(fileURLWithPath: "/tmp/intatis-agent"),
    apiKeyRef: KeychainRef(service: "s", account: "a"),
    wire: .openai
)

final class IntatisProvidersToolCallingTests: XCTestCase {

    func testToolCallStreamingAssemblesAcrossFragments() async throws {
        let sse = #"""
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\"pa"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\"a.swift\"}"}}]}}]}

        data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """#
        let provider = OpenAIWireProvider(endpoint: endpoint, apiKey: "k", http: FakeHTTP2(chunks: fragment(sse, size: 8)))
        var calls: [ToolCall] = []
        var sawDone = false
        var finish: String?
        for try await chunk in provider.stream(AgentRequest(model: ModelID(rawValue: "m"),
                                                            messages: [.user("hi")],
                                                            tools: [])) {
            switch chunk {
            case .textDelta: break
            case .toolCalls(let c): calls = c
            case .usage: break
            case .done(let r): sawDone = true; finish = r
            }
        }
        XCTAssertEqual(calls, [ToolCall(id: "call_1", name: "read_file", arguments: #"{"path":"a.swift"}"#)])
        XCTAssertTrue(sawDone)
        XCTAssertEqual(finish, "tool_calls")
    }

    func testToolCallStreamingRejectsNonHTTPChatEndpointBeforeTransport() async {
        let provider = OpenAIWireProvider(
            endpoint: nonHTTPToolEndpoint,
            apiKey: "k",
            http: FakeHTTP2(chunks: [Data("data: [DONE]\n\n".utf8)]))

        do {
            for try await _ in provider.stream(AgentRequest(model: ModelID(rawValue: "m"),
                                                            messages: [.user("hi")],
                                                            tools: [])) {}
            XCTFail("expected invalid provider endpoint error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalid provider endpoint 'bad-agent'"))
            XCTAssertTrue(error.localizedDescription.contains("Chat endpoint scheme 'file' is not supported"))
            XCTAssertTrue(error.localizedDescription.contains("tool-calling streaming request"))
        }
    }

    func testToolCallStreamingAcceptsMissingIndexForSingleToolCall() async throws {
        let sse = #"""
        data: {"choices":[{"delta":{"tool_calls":[{"id":"call_missing_index","function":{"name":"read_file","arguments":"{\"pa"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"th\":\"a.swift\"}"}}]}}]}

        data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

        """#
        let provider = OpenAIWireProvider(endpoint: endpoint, apiKey: "k", http: FakeHTTP2(chunks: fragment(sse, size: 9)))
        var calls: [ToolCall] = []
        for try await chunk in provider.stream(AgentRequest(model: ModelID(rawValue: "m"),
                                                            messages: [.user("hi")],
                                                            tools: [])) {
            if case .toolCalls(let emitted) = chunk {
                calls = emitted
            }
        }

        XCTAssertEqual(calls, [
            ToolCall(id: "call_missing_index", name: "read_file", arguments: #"{"path":"a.swift"}"#),
        ])
    }

    func testToolCallStreamingAcceptsJSONObjectArguments() async throws {
        let sse = #"""
        data: {"choices":[{"delta":{"tool_calls":[{"index":"0","id":"call_json","function":{"name":"read_file","arguments":{"path":"a.swift","line":3}}}]}}]}

        data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

        """#
        let provider = OpenAIWireProvider(endpoint: endpoint, apiKey: "k", http: FakeHTTP2(chunks: fragment(sse, size: 13)))
        var calls: [ToolCall] = []
        for try await chunk in provider.stream(AgentRequest(model: ModelID(rawValue: "m"),
                                                            messages: [.user("hi")],
                                                            tools: [])) {
            if case .toolCalls(let emitted) = chunk {
                calls = emitted
            }
        }

        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.id, "call_json")
        XCTAssertEqual(call.name, "read_file")
        let data = try XCTUnwrap(call.arguments.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["path"] as? String, "a.swift")
        XCTAssertEqual((object["line"] as? NSNumber)?.intValue, 3)
    }

    func testToolCallingStreamingThrowsWhenToolCallArgumentsAreIncompleteJSON() async throws {
        let sse = #"""
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_bad_args","function":{"name":"read_file","arguments":"{\"pa"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\"a.swift\""}}]},"finish_reason":"tool_calls"}]}

        """#
        let provider = OpenAIWireProvider(endpoint: endpoint,
                                          apiKey: "k",
                                          http: FakeHTTP2(chunks: fragment(sse, size: 17)))

        do {
            for try await _ in provider.stream(AgentRequest(model: ModelID(rawValue: "m"),
                                                            messages: [.user("hi")],
                                                            tools: [])) {}
            XCTFail("expected invalid JSON tool-call arguments error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("provider tool-call stream was incomplete"))
            XCTAssertTrue(error.localizedDescription.contains("invalid JSON arguments"))
            XCTAssertTrue(error.localizedDescription.contains("0:0"))
        }
    }

    func testToolCallingStreamingAllowsEmptyArgumentsForCompatibility() async throws {
        let sse = #"""
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_no_args","function":{"name":"ping"}}]},"finish_reason":"tool_calls"}]}

        """#
        let provider = OpenAIWireProvider(endpoint: endpoint,
                                          apiKey: "k",
                                          http: FakeHTTP2(chunks: fragment(sse, size: 13)))
        var calls: [ToolCall] = []

        for try await chunk in provider.stream(AgentRequest(model: ModelID(rawValue: "m"),
                                                            messages: [.user("hi")],
                                                            tools: [])) {
            if case .toolCalls(let emitted) = chunk {
                calls = emitted
            }
        }

        XCTAssertEqual(calls, [
            ToolCall(id: "call_no_args", name: "ping", arguments: ""),
        ])
    }

    func testToolCallStreamingReadsToolCallAndFinishFromNonFirstChoice() async throws {
        let sse = #"""
        data: {"choices":[{"index":0,"delta":{}},{"index":1,"delta":{"tool_calls":[{"index":0,"id":"call_second","function":{"name":"read_file","arguments":"{\"path\":\"a.swift\"}"}}]},"finish_reason":"tool_calls"}]}

        """#
        let provider = OpenAIWireProvider(endpoint: endpoint, apiKey: "k", http: FakeHTTP2(chunks: fragment(sse, size: 17)))
        var calls: [ToolCall] = []
        var sawDone = false
        var finish: String?
        for try await chunk in provider.stream(AgentRequest(model: ModelID(rawValue: "m"),
                                                            messages: [.user("hi")],
                                                            tools: [])) {
            switch chunk {
            case .textDelta:
                break
            case .toolCalls(let emitted):
                calls = emitted
            case .usage:
                break
            case .done(let reason):
                sawDone = true
                finish = reason
            }
        }

        XCTAssertEqual(calls, [
            ToolCall(id: "call_second", name: "read_file", arguments: #"{"path":"a.swift"}"#),
        ])
        XCTAssertTrue(sawDone)
        XCTAssertEqual(finish, "tool_calls")
    }

    func testToolCallStreamingPrefersToolCallFinishReasonAcrossChoices() async throws {
        let sse = #"""
        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"},{"index":1,"delta":{"tool_calls":[{"index":0,"id":"call_second_finish","function":{"name":"read_file","arguments":"{\"path\":\"a.swift\"}"}}]},"finish_reason":"tool_calls"}]}

        """#
        let provider = OpenAIWireProvider(endpoint: endpoint, apiKey: "k", http: FakeHTTP2(chunks: fragment(sse, size: 19)))
        var calls: [ToolCall] = []
        var finish: String?
        for try await chunk in provider.stream(AgentRequest(model: ModelID(rawValue: "m"),
                                                            messages: [.user("hi")],
                                                            tools: [])) {
            switch chunk {
            case .textDelta, .usage:
                break
            case .toolCalls(let emitted):
                calls = emitted
            case .done(let reason):
                finish = reason
            }
        }

        XCTAssertEqual(calls, [
            ToolCall(id: "call_second_finish", name: "read_file", arguments: #"{"path":"a.swift"}"#),
        ])
        XCTAssertEqual(finish, "tool_calls")
    }

    func testToolCallingStreamingThrowsWhenToolCallNameMissingAtFinish() async throws {
        let sse = #"""
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_missing_name","function":{"arguments":"{\"path\":\"a.swift\"}"}}]},"finish_reason":"tool_calls"}]}

        """#
        let provider = OpenAIWireProvider(endpoint: endpoint,
                                          apiKey: "k",
                                          http: FakeHTTP2(chunks: fragment(sse, size: 19)))

        do {
            for try await _ in provider.stream(AgentRequest(model: ModelID(rawValue: "m"),
                                                            messages: [.user("hi")],
                                                            tools: [])) {}
            XCTFail("expected incomplete tool-call stream error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("provider tool-call stream was incomplete"))
            XCTAssertTrue(error.localizedDescription.contains("omitted tool names"))
            XCTAssertTrue(error.localizedDescription.contains("0:0"))
        }
    }

    func testToolCallingStreamingThrowsWhenToolCallNameMissingBeforeStopFinish() async throws {
        let sse = #"""
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_missing_name","function":{"arguments":"{\"path\":\"a.swift\"}"}}]}},{"delta":{},"finish_reason":"stop"}]}

        """#
        let provider = OpenAIWireProvider(endpoint: endpoint,
                                          apiKey: "k",
                                          http: FakeHTTP2(chunks: fragment(sse, size: 19)))

        do {
            for try await _ in provider.stream(AgentRequest(model: ModelID(rawValue: "m"),
                                                            messages: [.user("hi")],
                                                            tools: [])) {}
            XCTFail("expected incomplete tool-call stream error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("provider tool-call stream was incomplete"))
            XCTAssertTrue(error.localizedDescription.contains("omitted tool names"))
            XCTAssertTrue(error.localizedDescription.contains("stop"))
        }
    }

    func testToolCallingStreamingThrowsOnLegacyFunctionCallFinishReason() async throws {
        let sse = #"""
        data: {"choices":[{"delta":{"function_call":{"name":"read_file","arguments":"{\"path\":\"a.swift\"}"}},"finish_reason":"function_call"}]}

        """#
        let provider = OpenAIWireProvider(endpoint: endpoint,
                                          apiKey: "k",
                                          http: FakeHTTP2(chunks: fragment(sse, size: 23)))

        do {
            for try await _ in provider.stream(AgentRequest(model: ModelID(rawValue: "m"),
                                                            messages: [.user("hi")],
                                                            tools: [])) {}
            XCTFail("expected legacy function_call compatibility error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("provider tool-call stream was incomplete"))
            XCTAssertTrue(error.localizedDescription.contains("function_call"))
            XCTAssertTrue(error.localizedDescription.contains("did not emit any tool call deltas"))
        }
    }

    func testTextOnlyStreaming() async throws {
        let sse = #"""
        data: {"choices":[{"delta":{"content":"Hi"}}]}

        data: {"choices":[{"delta":{"content":" there"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """#
        let provider = OpenAIWireProvider(endpoint: endpoint, apiKey: "k", http: FakeHTTP2(chunks: fragment(sse, size: 6)))
        var text = ""
        var finish: String?
        for try await chunk in provider.stream(AgentRequest(model: ModelID(rawValue: "m"),
                                                            messages: [.user("hi")], tools: [])) {
            switch chunk {
            case .textDelta(let d): text += d
            case .toolCalls: XCTFail("unexpected tool call")
            case .usage: break
            case .done(let r): finish = r
            }
        }
        XCTAssertEqual(text, "Hi there")
        XCTAssertEqual(finish, "stop")
    }

    func testToolCallingStreamingKeepsUsageAfterFinishReasonAndDoesNotDuplicateDone() async throws {
        let sse = #"""
        data: {"choices":[{"delta":{"content":"Recovered"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":2,"total_tokens":9,"prompt_tokens_details":{"cached_tokens":3}}}

        data: [DONE]

        """#
        let provider = OpenAIWireProvider(endpoint: endpoint,
                                          apiKey: "k",
                                          http: FakeHTTP2(chunks: fragment(sse, size: 10)))

        var text = ""
        var usage: Usage?
        var doneCount = 0
        var finish: String?
        for try await chunk in provider.stream(AgentRequest(model: ModelID(rawValue: "m"),
                                                            messages: [.user("hi")],
                                                            tools: [],
                                                            includeUsage: true)) {
            switch chunk {
            case .textDelta(let delta):
                text += delta
            case .toolCalls:
                XCTFail("unexpected tool call")
            case .usage(let value):
                usage = value
            case .done(let reason):
                doneCount += 1
                finish = reason
            }
        }

        XCTAssertEqual(text, "Recovered")
        XCTAssertEqual(doneCount, 1)
        XCTAssertEqual(finish, "stop")
        XCTAssertEqual(usage?.promptTokens, 7)
        XCTAssertEqual(usage?.cachedPromptTokens, 3)
        XCTAssertEqual(usage?.completionTokens, 2)
        XCTAssertEqual(usage?.totalTokens, 9)
    }

    func testToolCallingStreamingThrowsWhenCompletionMarkerMissing() async throws {
        let sse = #"""
        data: {"choices":[{"delta":{"content":"partial"}}]}

        """#
        let provider = OpenAIWireProvider(endpoint: endpoint,
                                          apiKey: "k",
                                          http: FakeHTTP2(chunks: fragment(sse, size: 10)))

        var text = ""
        do {
            for try await chunk in provider.stream(AgentRequest(model: ModelID(rawValue: "m"),
                                                                messages: [.user("hi")],
                                                                tools: [])) {
                switch chunk {
                case .textDelta(let delta):
                    text += delta
                case .toolCalls:
                    XCTFail("unexpected tool call for incomplete stream")
                case .usage:
                    break
                case .done:
                    XCTFail("unexpected done for incomplete stream")
                }
            }
            XCTFail("expected incomplete stream error")
        } catch {
            XCTAssertEqual(text, "partial")
            XCTAssertTrue(error.localizedDescription.contains("completion marker"))
        }
    }

    func testToolCallingStreamingRetriesRetryableHTTPBeforeResponseBytes() async throws {
        let sse = #"""
        data: {"choices":[{"delta":{"content":"Recovered"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        """#
        let http = SequencedToolHTTP(attempts: [
            ToolStreamAttempt(
                chunks: [],
                error: ProviderErrorFormatting.httpStatus(
                    503,
                    body: Data(#"{"error":{"message":"upstream busy"}}"#.utf8),
                    operation: "tool-calling streaming request")),
            ToolStreamAttempt(chunks: [Data(sse.utf8)], error: nil),
        ])
        let provider = OpenAIWireProvider(
            endpoint: endpoint,
            apiKey: "k",
            http: http,
            runtimePolicy: ProviderRuntimePolicy(maxAttempts: 2,
                                                 requestTimeoutSeconds: 1,
                                                 initialRetryDelaySeconds: 0,
                                                 maxRetryDelaySeconds: 0))

        var text = ""
        for try await chunk in provider.stream(AgentRequest(model: ModelID(rawValue: "m"),
                                                            messages: [.user("hi")],
                                                            tools: [])) {
            if case .textDelta(let delta) = chunk {
                text += delta
            }
        }

        XCTAssertEqual(text, "Recovered")
        XCTAssertEqual(http.attemptCount, 2)
    }

    func testToolCallingStreamingRetriesRetryableErrorOnlySSEBeforeAcceptedPayload() async throws {
        let errorSSE = #"""
        data: {"error":{"message":"Network connection lost","code":502}}

        """#
        let recoveredSSE = #"""
        data: {"choices":[{"delta":{"content":"Recovered"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        """#
        let http = SequencedToolHTTP(attempts: [
            ToolStreamAttempt(chunks: [Data(errorSSE.utf8)], error: nil),
            ToolStreamAttempt(chunks: [Data(recoveredSSE.utf8)], error: nil),
        ])
        let provider = OpenAIWireProvider(
            endpoint: endpoint,
            apiKey: "k",
            http: http,
            runtimePolicy: ProviderRuntimePolicy(maxAttempts: 2,
                                                 requestTimeoutSeconds: 1,
                                                 initialRetryDelaySeconds: 0,
                                                 maxRetryDelaySeconds: 0))

        var text = ""
        var doneCount = 0
        for try await chunk in provider.stream(AgentRequest(model: ModelID(rawValue: "m"),
                                                            messages: [.user("hi")],
                                                            tools: [])) {
            switch chunk {
            case .textDelta(let delta):
                text += delta
            case .done:
                doneCount += 1
            case .toolCalls, .usage:
                break
            }
        }

        XCTAssertEqual(text, "Recovered")
        XCTAssertEqual(doneCount, 1)
        XCTAssertEqual(http.attemptCount, 2)
    }

    func testToolCallingStreamingDoesNotRetryErrorAfterAcceptedPayload() async throws {
        let partialThenErrorSSE = #"""
        data: {"choices":[{"delta":{"content":"Partial"}}]}

        data: {"error":{"message":"Network connection lost","code":502}}

        """#
        let http = SequencedToolHTTP(attempts: [
            ToolStreamAttempt(chunks: [Data(partialThenErrorSSE.utf8)], error: nil),
            ToolStreamAttempt(
                chunks: [Data("data: [DONE]\n\n".utf8)],
                error: nil),
        ])
        let provider = OpenAIWireProvider(
            endpoint: endpoint,
            apiKey: "k",
            http: http,
            runtimePolicy: ProviderRuntimePolicy(maxAttempts: 2,
                                                 requestTimeoutSeconds: 1,
                                                 initialRetryDelaySeconds: 0,
                                                 maxRetryDelaySeconds: 0))

        var text = ""
        do {
            for try await chunk in provider.stream(AgentRequest(model: ModelID(rawValue: "m"),
                                                                messages: [.user("hi")],
                                                                tools: [])) {
                if case .textDelta(let delta) = chunk {
                    text += delta
                }
            }
            XCTFail("A provider error after accepted output must fail without replaying the request.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Network connection lost"))
        }

        XCTAssertEqual(text, "Partial")
        XCTAssertEqual(http.attemptCount, 1)
    }

    func testToolCallingStreamingThrowsProviderErrorPayload() async throws {
        let sse = #"""
        data: {"error":{"message":"tool schema rejected","type":"invalid_request_error","code":"bad_tool_schema"}}

        """#
        let provider = OpenAIWireProvider(endpoint: endpoint, apiKey: "k", http: FakeHTTP2(chunks: fragment(sse, size: 11)))

        do {
            for try await _ in provider.stream(AgentRequest(model: ModelID(rawValue: "m"),
                                                            messages: [.user("hi")],
                                                            tools: [])) {}
            XCTFail("expected provider error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("tool schema rejected"))
            XCTAssertTrue(error.localizedDescription.contains("bad_tool_schema"))
        }
    }

    func testToolCallingStreamingPreservesStructuredHardUsageLimitError() async {
        let sse = #"""
        data: {"error":{"message":"usage_limit_reached","type":"billing_error"}}

        """#
        let provider = OpenAIWireProvider(
            endpoint: endpoint,
            apiKey: "k",
            http: FakeHTTP2(chunks: fragment(sse, size: 9)))

        do {
            for try await _ in provider.stream(AgentRequest(
                model: ModelID(rawValue: "m"),
                messages: [.user("hi")],
                tools: [])) {}
            XCTFail("expected hard provider usage limit")
        } catch let error as ProviderUsageLimitError {
            XCTAssertEqual(error.signal, "usage_limit_reached")
            XCTAssertNil(error.statusCode)
        } catch {
            XCTFail("expected ProviderUsageLimitError, got \(type(of: error)): \(error)")
        }
    }

    func testMessageJSONShapes() {
        let assistant = OpenAIWireProvider.messageJSON(
            .assistant(toolCalls: [ToolCall(id: "c1", name: "f", arguments: "{}")]))
        guard case .object(let o) = assistant else { return XCTFail("not object") }
        XCTAssertEqual(o["role"], .string("assistant"))
        XCTAssertEqual(o["content"], JSONValue.null)
        XCTAssertNotNil(o["tool_calls"])

        let toolMsg = OpenAIWireProvider.messageJSON(.tool(id: "c1", content: "obs"))
        guard case .object(let t) = toolMsg else { return XCTFail("not object") }
        XCTAssertEqual(t["tool_call_id"], .string("c1"))
        XCTAssertEqual(t["content"], .string("obs"))
    }

    func testReasoningEffortAndOutputCeilingInRequestBody() throws {
        let provider = OpenAIWireProvider(endpoint: endpoint, apiKey: "k", http: FakeHTTP2(chunks: []))

        let withEffort = try provider.buildAgentRequest(
            AgentRequest(
                model: ModelID(rawValue: "m"),
                messages: [.user("hi")],
                tools: [],
                reasoningEffort: .high,
                maxOutputTokens: 321))
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(withEffort.httpBody)) as! [String: Any]
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")
        XCTAssertEqual(body["max_tokens"] as? Int, 321)

        let without = try provider.buildAgentRequest(
            AgentRequest(model: ModelID(rawValue: "m"), messages: [.user("hi")], tools: []))
        let body2 = try JSONSerialization.jsonObject(with: XCTUnwrap(without.httpBody)) as! [String: Any]
        XCTAssertNil(body2["reasoning_effort"])
        XCTAssertNil(body2["max_tokens"])
    }

    func testOpenRouterAdapterUsesNestedRuntimeReasoning()
        throws {
        let configuredEndpoint = ProviderEndpoint(
            id: "openrouter",
            baseURL: URL(
                string: "https://example.test/v1")!,
            apiKeyRef: KeychainRef(
                service: "s",
                account: "a"),
            wire: .openai,
            requestAdapter:
                .openRouter,
            modelRequestOptions: [
                "m": [
                    "reasoning": .object([
                        "effort": .string("low"),
                        "summary": .string("auto"),
                    ]),
                ],
            ])
        let provider = OpenAIWireProvider(
            endpoint: configuredEndpoint,
            apiKey: "k",
            http: FakeHTTP2(chunks: []))

        let request = try provider.buildAgentRequest(
            AgentRequest(
                model: ModelID(rawValue: "m"),
                messages: [.user("hi")],
                tools: [],
                reasoningEffort: .high))
        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: XCTUnwrap(request.httpBody))
        guard case .object(let body) = value else {
            return XCTFail(
                "request body is not an object")
        }
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertEqual(
            body["reasoning"],
            .object([
                "effort": .string("high"),
                "summary": .string("auto"),
            ]))
    }

    func testConfiguredModelOptionsPassThroughAgentBodyAndExplicitRuntimeValuesWin() throws {
        let configuredEndpoint = ProviderEndpoint(
            id: "generic",
            baseURL: URL(string: "https://example.test/v1")!,
            apiKeyRef: KeychainRef(service: "s", account: "a"),
            wire: .openai,
            requestAdapter:
                .openAICompatible,
            modelRequestOptions: [
                "vendor/model": [
                    "provider": .object(["allow_fallbacks": .bool(false)]),
                    "parallel_tool_calls": .bool(false),
                    "max_tokens": .number(999),
                    "reasoning_effort": .string("low"),
                    "reasoningEffort": .string("xhigh"),
                    "reasoning": .object([
                        "effort": .string("medium"),
                        "summary": .string("auto"),
                    ]),
                    "model": .string("must-not-win"),
                    "messages": .array([]),
                    "tools": .array([]),
                    "stream": .bool(false),
                ],
            ])
        let provider = OpenAIWireProvider(
            endpoint: configuredEndpoint,
            apiKey: "k",
            http: FakeHTTP2(chunks: []))
        let encoded = try provider.buildAgentRequest(AgentRequest(
            model: ModelID(rawValue: "vendor/model"),
            messages: [.user("hi")],
            tools: [ToolSpec(name: "inspect", description: "Inspect", parameters: .object([:]))],
            reasoningEffort: .high,
            maxOutputTokens: 321))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(encoded.httpBody))
        guard case .object(let body) = decoded else { return XCTFail("request body is not an object") }

        XCTAssertEqual(body["provider"], JSONValue.object(["allow_fallbacks": .bool(false)]))
        XCTAssertEqual(body["parallel_tool_calls"], JSONValue.bool(false))
        XCTAssertEqual(body["max_tokens"], JSONValue.number(321))
        XCTAssertEqual(body["reasoning_effort"], JSONValue.string("high"))
        XCTAssertNil(body["reasoningEffort"])
        XCTAssertEqual(
            body["reasoning"],
            .object([
                "effort": .string("medium"),
                "summary": .string("auto"),
            ]))
        XCTAssertEqual(body["model"], JSONValue.string("vendor/model"))
        XCTAssertEqual(body["stream"], JSONValue.bool(true))
        guard let messageValue = body["messages"],
              case .array(let messages) = messageValue else {
            return XCTFail("runtime messages were not encoded")
        }
        guard let toolValue = body["tools"],
              case .array(let tools) = toolValue else {
            return XCTFail("runtime tools were not encoded")
        }
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(tools.count, 1)

        let explicitParallel = try provider.buildAgentRequest(AgentRequest(
            model: ModelID(rawValue: "vendor/model"),
            messages: [.user("hi")],
            tools: [],
            parallelToolCalls: true))
        let explicitParallelValue = try JSONDecoder().decode(
            JSONValue.self,
            from: XCTUnwrap(explicitParallel.httpBody))
        guard case .object(let explicitParallelBody) =
                explicitParallelValue else {
            return XCTFail("request body is not an object")
        }
        XCTAssertEqual(
            explicitParallelBody["parallel_tool_calls"],
            .bool(false))
        XCTAssertNil(explicitParallelBody["n"])
    }

    func testOpenAICompatibleStrictRoutingBodyDoesNotSynthesizeUnsupportedControls()
        throws {
        let configuredEndpoint = ProviderEndpoint(
            id: "openrouter-compatible",
            baseURL: URL(
                string: "https://example.test/v1")!,
            apiKeyRef: KeychainRef(
                service: "s",
                account: "a"),
            wire: .openai,
            requestAdapter:
                .openAICompatible,
            modelRequestOptions: [
                "deepseek/deepseek-v4-pro": [
                    "reasoningEffort":
                        .string("xhigh"),
                    "provider": .object([
                        "only": .array([
                            .string("deepseek"),
                        ]),
                        "allow_fallbacks": .bool(false),
                        "require_parameters":
                            .bool(true),
                    ]),
                ],
            ])
        let provider = OpenAIWireProvider(
            endpoint: configuredEndpoint,
            apiKey: "k",
            http: FakeHTTP2(chunks: []))

        let encoded = try provider.buildAgentRequest(
            AgentRequest(
                model: ModelID(
                    rawValue:
                        "deepseek/deepseek-v4-pro"),
                messages: [.user("hi")],
                tools: [
                    ToolSpec(
                        name: "activate_skill",
                        description:
                            "Activate a skill",
                        parameters: .object([:]),
                        supportsParallelCalls: true),
                ],
                parallelToolCalls: true))
        let decoded = try JSONDecoder().decode(
            JSONValue.self,
            from: XCTUnwrap(encoded.httpBody))
        guard case .object(let body) = decoded else {
            return XCTFail(
                "request body is not an object")
        }

        XCTAssertEqual(
            Set(body.keys),
            Set([
                "model",
                "messages",
                "stream",
                "tools",
                "reasoning_effort",
                "provider",
            ]))
        XCTAssertNil(body["n"])
        XCTAssertNil(body["parallel_tool_calls"])
        XCTAssertEqual(
            body["reasoning_effort"],
            .string("xhigh"))
        XCTAssertEqual(
            body["provider"],
            .object([
                "only": .array([
                    .string("deepseek"),
                ]),
                "allow_fallbacks": .bool(false),
                "require_parameters":
                    .bool(true),
            ]))
    }

    func testOpenRouterAdapterAlsoOmitsSyntheticCandidateAndParallelControls()
        throws {
        let configuredEndpoint = ProviderEndpoint(
            id: "openrouter",
            baseURL: URL(
                string: "https://example.test/v1")!,
            apiKeyRef: KeychainRef(
                service: "s",
                account: "a"),
            wire: .openai,
            requestAdapter:
                .openRouter)
        let provider = OpenAIWireProvider(
            endpoint: configuredEndpoint,
            apiKey: "k",
            http: FakeHTTP2(chunks: []))

        let encoded = try provider.buildAgentRequest(
            AgentRequest(
                model: ModelID(
                    rawValue: "deepseek/model"),
                messages: [.user("hi")],
                tools: [
                    ToolSpec(
                        name: "inspect",
                        description: "Inspect",
                        parameters: .object([:]),
                        supportsParallelCalls: true),
                ],
                parallelToolCalls: true))
        let decoded = try JSONDecoder().decode(
            JSONValue.self,
            from: XCTUnwrap(encoded.httpBody))
        guard case .object(let body) = decoded else {
            return XCTFail(
                "request body is not an object")
        }

        XCTAssertNil(body["n"])
        XCTAssertNil(body["parallel_tool_calls"])
    }

    func testProviderRequestBodyEncodingSortsNestedObjectKeys() throws {
        let encoded = try OpenAIWireProvider.encodeRequestBody([
            "zeta": .bool(true),
            "alpha": .object([
                "zeta": .bool(false),
                "alpha": .string("value"),
            ]),
        ])

        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self),
            #"{"alpha":{"alpha":"value","zeta":false},"zeta":true}"#)
    }

    func testAgentMessageWithImageEncodesAsContentArray() {
        let message = AgentMessage.user("what is this?",
                                        images: [ImageAttachment(url: "data:image/png;base64,QUJD")])
        guard case .object(let obj) = OpenAIWireProvider.messageJSON(message),
              case .array(let parts)? = obj["content"] else { return XCTFail("content should be an array") }
        XCTAssertEqual(parts.count, 2)
        guard case .object(let text) = parts[0] else { return XCTFail() }
        XCTAssertEqual(text["type"], .string("text"))
        guard case .object(let img) = parts[1] else { return XCTFail() }
        XCTAssertEqual(img["type"], .string("image_url"))
        guard case .object(let imageURL)? = img["image_url"] else { return XCTFail() }
        XCTAssertEqual(imageURL["url"], .string("data:image/png;base64,QUJD"))
    }

    func testToolMessageImagesFlowIntoFunctionCallOutput() {
        let image = ImageAttachment(
            url: "data:image/png;base64,QUJD")

        XCTAssertEqual(
            AgentInputItem.from(messages: [
                .tool(
                    id: "call-1",
                    content: "observation",
                    images: [image]),
            ]),
            [
                .functionCallOutput(
                    callID: "call-1",
                    output: "observation",
                    images: [image]),
            ])
    }

    func testUserAndFunctionOutputImagesRequireResponsesAPI() {
        let image = ImageAttachment(
            url: "data:image/png;base64,QUJD")

        XCTAssertTrue(AgentRequest(
            model: ModelID(rawValue: "m"),
            messages: [.user("inspect", images: [image])],
            tools: []).requiresResponsesAPI)
        XCTAssertTrue(AgentRequest(
            model: ModelID(rawValue: "m"),
            messages: [
                .tool(
                    id: "call-1",
                    content: "result",
                    images: [image]),
            ],
            tools: []).requiresResponsesAPI)
        XCTAssertFalse(AgentRequest(
            model: ModelID(rawValue: "m"),
            messages: [.user("text only")],
            tools: []).requiresResponsesAPI)
    }

    func testFunctionOutputImagesUseResponsesWithoutToolSearchCapability()
        throws {
        let image = ImageAttachment(
            url: "data:image/png;base64,QUJD")
        let provider = OpenAIWireProvider(
            endpoint: endpoint,
            apiKey: "k",
            http: FakeHTTP2(chunks: []),
            toolCallingCapabilities:
                ToolCallingProviderCapabilities(
                    supportsFunctionOutputImageInput: true))

        let encoded = try provider.buildAgentRequest(AgentRequest(
            model: ModelID(rawValue: "m"),
            messages: [
                .tool(
                    id: "call-1",
                    content: "observation",
                    images: [image]),
            ],
            tools: []))

        XCTAssertEqual(encoded.url?.path, "/v1/responses")
        let decoded = try JSONDecoder().decode(
            JSONValue.self,
            from: XCTUnwrap(encoded.httpBody))
        guard case .object(let body) = decoded,
              case .array(let input)? = body["input"],
              case .object(let output)? = input.first,
              case .array(let parts)? = output["output"] else {
            return XCTFail("missing function output content")
        }
        XCTAssertEqual(output["type"], .string("function_call_output"))
        XCTAssertEqual(output["call_id"], .string("call-1"))
        XCTAssertEqual(parts, [
            .object([
                "type": .string("input_text"),
                "text": .string("observation"),
            ]),
            .object([
                "type": .string("input_image"),
                "image_url": .string(image.url),
            ]),
        ])
    }

    func testUserImagesUseResponsesWithoutToolSearchCapability()
        throws {
        let image = ImageAttachment(
            url: "data:image/png;base64,QUJD")
        let provider = OpenAIWireProvider(
            endpoint: endpoint,
            apiKey: "k",
            http: FakeHTTP2(chunks: []),
            toolCallingCapabilities:
                ToolCallingProviderCapabilities(
                    supportsUserImageInput: true))

        let encoded = try provider.buildAgentRequest(AgentRequest(
            model: ModelID(rawValue: "m"),
            messages: [.user("inspect", images: [image])],
            tools: []))

        XCTAssertEqual(encoded.url?.path, "/v1/responses")
        let decoded = try JSONDecoder().decode(
            JSONValue.self,
            from: XCTUnwrap(encoded.httpBody))
        guard case .object(let body) = decoded,
              case .array(let input)? = body["input"],
              case .object(let message)? = input.first,
              case .array(let parts)? = message["content"] else {
            return XCTFail("missing user message content")
        }
        XCTAssertEqual(parts, [
            .object([
                "type": .string("input_text"),
                "text": .string("inspect"),
            ]),
            .object([
                "type": .string("input_image"),
                "image_url": .string(image.url),
            ]),
        ])
    }

    func testPureImageFunctionOutputOmitsEmptyTextPlaceholder() {
        let images = [
            ImageAttachment(url: "data:image/png;base64,QUJD"),
            ImageAttachment(url: "data:image/jpeg;base64,REVG"),
        ]

        guard case .object(let output)? =
            OpenAIWireProvider.responsesInputJSON(
                .functionCallOutput(
                    callID: "call-1",
                    output: "",
                    images: images)),
              case .array(let parts)? = output["output"] else {
            return XCTFail("missing function output content")
        }
        XCTAssertEqual(parts, images.map {
            .object([
                "type": .string("input_image"),
                "image_url": .string($0.url),
            ])
        })
    }

    func testImageCapabilityFailuresAreTypedAndPrecedeTransport()
        async {
        let image = ImageAttachment(
            url: "data:image/png;base64,QUJD")
        let http = SequencedToolHTTP(attempts: [
            ToolStreamAttempt(
                chunks: [Data("data: [DONE]\n\n".utf8)]),
        ])
        let provider = OpenAIWireProvider(
            endpoint: endpoint,
            apiKey: "k",
            http: http)

        do {
            for try await _ in provider.stream(AgentRequest(
                model: ModelID(rawValue: "m"),
                messages: [.user("inspect", images: [image])],
                tools: [])) {}
            XCTFail("expected user-image capability failure")
        } catch {
            XCTAssertEqual(
                error as? ToolCallingProviderCapabilityError,
                .userImageInputUnsupported)
        }
        XCTAssertEqual(http.attemptCount, 0)

        XCTAssertThrowsError(try provider.buildAgentRequest(AgentRequest(
            model: ModelID(rawValue: "m"),
            messages: [
                .tool(
                    id: "call-1",
                    content: "",
                    images: [image]),
            ],
            tools: []))) { error in
            XCTAssertEqual(
                error as? ToolCallingProviderCapabilityError,
                .functionOutputImageInputUnsupported)
        }
        XCTAssertEqual(http.attemptCount, 0)
    }

    func testRegistryEnablesImageInputOnlyForReviewedOpenAIResponsesAdapterWithVision()
        async throws {
        let model = ModelID(rawValue: "vision-model")
        func makeEndpoint(
            id: String,
            adapter: ProviderRequestAdapter,
            capabilities: [Capability],
            modelOverride: ProviderRequestAdapter? = nil
        ) -> ProviderEndpoint {
            ProviderEndpoint(
                id: id,
                baseURL: URL(string: "https://example.test/v1")!,
                apiKeyRef: KeychainRef(service: "s", account: id),
                wire: .openai,
                requestAdapter: adapter,
                modelRequestAdapters: modelOverride.map {
                    [model.rawValue: $0]
                } ?? [:],
                modelCapabilities: [
                    model.rawValue: capabilities,
                ])
        }
        let endpoints = [
            makeEndpoint(
                id: "responses-vision",
                adapter: .openAI,
                capabilities: [.toolCalling, .visionInput]),
            makeEndpoint(
                id: "responses-text",
                adapter: .openAI,
                capabilities: [.toolCalling]),
            makeEndpoint(
                id: "model-overridden-responses-vision",
                adapter: .openAICompatible,
                capabilities: [.toolCalling, .visionInput],
                modelOverride: .openAI),
            makeEndpoint(
                id: "compatible-vision",
                adapter: .openAICompatible,
                capabilities: [.toolCalling, .visionInput]),
            makeEndpoint(
                id: "legacy-vision",
                adapter: .legacyOpenAIWire,
                capabilities: [.toolCalling, .visionInput]),
            makeEndpoint(
                id: "openrouter-vision",
                adapter: .openRouter,
                capabilities: [.toolCalling, .visionInput]),
            makeEndpoint(
                id: "unknown-vision",
                adapter: ProviderRequestAdapter(
                    rawValue: "example:unknown-adapter"),
                capabilities: [.toolCalling, .visionInput]),
            makeEndpoint(
                id: "overridden-compatible-vision",
                adapter: .openAI,
                capabilities: [.toolCalling, .visionInput],
                modelOverride: .openAICompatible),
        ]
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: endpoints,
                models: ResolvedModels(
                    chat: ModelRef(
                        endpoint: "responses-vision",
                        model: model))),
            resolver: FixedToolSecretResolver(),
            http: FakeHTTP2(chunks: []))

        for endpointID in [
            "responses-vision",
            "model-overridden-responses-vision",
        ] {
            let provider = try await registry.agentProvider(
                for: ModelRef(endpoint: endpointID, model: model))
            XCTAssertTrue(
                provider.toolCallingCapabilities
                    .supportsUserImageInput)
            XCTAssertTrue(
                provider.toolCallingCapabilities
                    .supportsFunctionOutputImageInput)
        }
        for endpointID in [
            "responses-text",
            "compatible-vision",
            "legacy-vision",
            "openrouter-vision",
            "unknown-vision",
            "overridden-compatible-vision",
        ] {
            let provider = try await registry.agentProvider(
                for: ModelRef(endpoint: endpointID, model: model))
            XCTAssertFalse(
                provider.toolCallingCapabilities
                    .supportsUserImageInput)
            XCTAssertFalse(
                provider.toolCallingCapabilities
                    .supportsFunctionOutputImageInput)
        }
    }

    func testChatMessageWithImageEncodesAsContentArray() {
        let m = ChatMessage(role: .user, content: "hi", images: [ImageAttachment(url: "https://x/a.png")])
        guard case .object(let obj) = OpenAIWireProvider.chatMessageJSON(m),
              case .array(let parts)? = obj["content"] else { return XCTFail("content should be an array") }
        XCTAssertEqual(parts.count, 2)
    }

    func testPlainMessageStaysString() {
        guard case .object(let obj) = OpenAIWireProvider.chatMessageJSON(ChatMessage(role: .user, content: "hi")) else {
            return XCTFail()
        }
        XCTAssertEqual(obj["content"], .string("hi"))
    }
}
