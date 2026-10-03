import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisProviders

private struct FakeHTTP: HTTPByteStreaming {
    let chunks: [Data]
    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private struct DelayedHTTP: HTTPByteStreaming {
    let delayNanoseconds: UInt64
    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct StreamAttempt {
    var chunks: [Data]
    var error: Error?
}

private final class SequencedHTTP: HTTPByteStreaming, @unchecked Sendable {
    private let queue = DispatchQueue(label: "intatis.tests.sequenced-http")
    private var index = 0
    private var requests: [URLRequest] = []
    private let attempts: [StreamAttempt]

    init(attempts: [StreamAttempt]) {
        self.attempts = attempts
    }

    var attemptCount: Int {
        queue.sync { index }
    }

    var recordedRequests: [URLRequest] {
        queue.sync { requests }
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        let attempt = queue.sync { () -> StreamAttempt in
            requests.append(request)
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

private final class CapturingHTTP: HTTPByteStreaming, @unchecked Sendable {
    private let queue = DispatchQueue(label: "intatis.tests.capturing-http")
    private let chunks: [Data]
    private var requests: [URLRequest] = []
    private var requestBodies: [Data] = []

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    var lastBody: Data? {
        queue.sync { requestBodies.last }
    }

    var lastRequest: URLRequest? {
        queue.sync { requests.last }
    }

    var requestCount: Int {
        queue.sync { requests.count }
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        queue.sync {
            requests.append(request)
            requestBodies.append(request.httpBody ?? Data())
        }
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

private struct StaticSecret: SecretResolver {
    let key: String
    func secret(for ref: KeychainRef) async throws -> String { key }
}

private let openAIEndpoint = ProviderEndpoint(id: "e",
                                              baseURL: URL(string: "https://example.test/v1")!,
                                              apiKeyRef: KeychainRef(service: "s", account: "a"),
                                              wire: .openai)

private let nonHTTPChatEndpoint = ProviderEndpoint(id: "bad-chat",
                                                   baseURL: URL(string: "https://example.test/v1")!,
                                                   chatEndpoint: URL(fileURLWithPath: "/tmp/intatis-chat"),
                                                   apiKeyRef: KeychainRef(service: "s", account: "a"),
                                                   wire: .openai)

final class IntatisProvidersTests: XCTestCase {

    func testSSEParserReassemblesAcrossArbitraryChunks() {
        let parser = SSEParser()
        let raw = "data: {\"a\":1}\n\ndata: [DONE]\n\n"
        let bytes = Array(raw.utf8)
        var events: [String] = []
        var i = 0
        while i < bytes.count {
            let end = min(i + 3, bytes.count)
            events += parser.consume(Data(bytes[i..<end]))
            i = end
        }
        events += parser.flush()
        XCTAssertEqual(events, ["{\"a\":1}", "[DONE]"])
    }

    func testOpenAIStreamingYieldsDeltasThenDone() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"He"}}]}

        data: {"choices":[{"delta":{"content":"llo"}}]}

        data: [DONE]

        """
        // Fragment into tiny chunks to prove cross-chunk buffering is correct.
        let bytes = Array(sse.utf8)
        var chunks: [Data] = []
        var i = 0
        while i < bytes.count {
            let end = min(i + 5, bytes.count)
            chunks.append(Data(bytes[i..<end]))
            i = end
        }
        let endpoint = ProviderEndpoint(id: "e",
                                        baseURL: URL(string: "https://example.test/v1")!,
                                        apiKeyRef: KeychainRef(service: "s", account: "a"),
                                        wire: .openai)
        let provider = OpenAIWireProvider(endpoint: endpoint, apiKey: "k", http: FakeHTTP(chunks: chunks))
        var text = ""
        var sawDone = false
        for try await chunk in provider.stream(ChatRequest(model: ModelID(rawValue: "gpt-x"),
                                                           messages: [ChatMessage(role: .user, content: "hi")])) {
            switch chunk {
            case .delta(let d): text += d
            case .citation: break
            case .usage: break
            case .done: sawDone = true
            }
        }
        XCTAssertEqual(text, "Hello")
        XCTAssertTrue(sawDone)
    }

    func testWebSearchUsesResponsesHostedToolRequest() async throws {
        let sse = """
        data: {"type":"response.completed","response":{"id":"resp_search"}}

        """
        let http = CapturingHTTP(chunks: [Data(sse.utf8)])
        let provider = OpenAIWireProvider(
            endpoint: openAIEndpoint,
            apiKey: "k",
            http: http)
        let request = ChatRequest(
            model: ModelID(rawValue: "gpt-search"),
            messages: [
                ChatMessage(role: .system, content: "Be concise."),
                ChatMessage(role: .user, content: "What changed?"),
                ChatMessage(role: .assistant, content: "I will check."),
            ],
            webSearch: ChatWebSearchConfiguration(
                dialect: .openAIResponses,
                contextSize: .high))

        var doneCount = 0
        for try await chunk in provider.stream(request) {
            if case .done = chunk { doneCount += 1 }
        }

        XCTAssertEqual(doneCount, 1)
        XCTAssertEqual(http.lastRequest?.url?.absoluteString,
                       "https://example.test/v1/responses")
        let bodyData = try XCTUnwrap(http.lastBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-search")
        XCTAssertEqual(body["instructions"] as? String, "Be concise.")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
        XCTAssertNil(body["messages"])
        XCTAssertNil(body["n"])

        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "web_search")
        XCTAssertEqual(tools[0]["search_context_size"] as? String, "high")

        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 2)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        XCTAssertEqual(input[1]["role"] as? String, "assistant")
        let userContent = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        let assistantContent = try XCTUnwrap(input[1]["content"] as? [[String: Any]])
        XCTAssertEqual(userContent.first?["type"] as? String, "input_text")
        XCTAssertEqual(assistantContent.first?["type"] as? String, "output_text")
    }

    func testOpenRouterHostedSearchUsesItsServerToolDialectAndKeepsRoutingOptions()
        async throws
    {
        let sse = """
        data: {"type":"response.completed","response":{"id":"resp_router"}}

        """
        let http = CapturingHTTP(chunks: [Data(sse.utf8)])
        let endpoint = ProviderEndpoint(
            id: "router",
            baseURL: URL(string: "https://openrouter.example/api/v1")!,
            apiKeyRef: KeychainRef(service: "s", account: "router"),
            wire: .openai,
            requestAdapter: .openRouter,
            modelRequestOptions: [
                "router-model": [
                    "provider": .object([
                        "only": .array([.string("provider-a")]),
                        "allow_fallbacks": .bool(false),
                        "require_parameters": .bool(true),
                    ]),
                ],
            ])
        let provider = OpenAIWireProvider(
            endpoint: endpoint,
            apiKey: "k",
            http: http)
        let request = ChatRequest(
            model: ModelID(rawValue: "router-model"),
            messages: [ChatMessage(role: .user, content: "latest")],
            webSearch: ChatWebSearchConfiguration(
                dialect: .openRouterServerTool,
                contextSize: .low))

        for try await _ in provider.stream(request) {}

        let bodyData = try XCTUnwrap(http.lastBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String,
                       "openrouter:web_search")
        let parameters = try XCTUnwrap(
            tools[0]["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["search_context_size"] as? String, "low")
        XCTAssertNil(tools[0]["search_context_size"])

        let routing = try XCTUnwrap(body["provider"] as? [String: Any])
        XCTAssertEqual(routing["allow_fallbacks"] as? Bool, false)
        XCTAssertEqual(routing["require_parameters"] as? Bool, true)
        XCTAssertEqual(routing["only"] as? [String], ["provider-a"])
    }

    func testStructuredHostedSearchRejectionFallsBackOnceOnSameRoute()
        async throws
    {
        let ordinarySSE = """
        data: {"choices":[{"delta":{"content":"ordinary"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let http = SequencedHTTP(attempts: [
            StreamAttempt(
                chunks: [],
                error: ProviderHTTPStatusError(
                    statusCode: 400,
                    body: Data(#"{"error":{"code":"unsupported_parameter","param":"tools[0].type","message":"not supported"}}"#.utf8),
                    headers: [:],
                    operation: "streaming request")),
            StreamAttempt(chunks: [Data(ordinarySSE.utf8)], error: nil),
        ])
        let endpoint = ProviderEndpoint(
            id: "router",
            baseURL: URL(string: "https://router.example/v1")!,
            apiKeyRef: KeychainRef(service: "s", account: "router"),
            wire: .openai,
            requestAdapter: .openRouter,
            modelRequestOptions: [
                "m": [
                    "provider": .object([
                        "only": .array([.string("provider-a")]),
                        "allow_fallbacks": .bool(false),
                    ]),
                ],
            ])
        let provider = OpenAIWireProvider(
            endpoint: endpoint,
            apiKey: "k",
            http: http,
            runtimePolicy: ProviderRuntimePolicy(
                maxAttempts: 2,
                requestTimeoutSeconds: 1,
                initialRetryDelaySeconds: 0,
                maxRetryDelaySeconds: 0))
        let request = ChatRequest(
            model: ModelID(rawValue: "m"),
            messages: [ChatMessage(role: .user, content: "hi")],
            webSearch: ChatWebSearchConfiguration(
                dialect: .openRouterServerTool))

        var text = ""
        for try await chunk in provider.stream(request) {
            if case .delta(let value) = chunk { text += value }
        }

        XCTAssertEqual(text, "ordinary")
        XCTAssertEqual(http.attemptCount, 2)
        let requests = http.recordedRequests
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/v1/responses",
            "/v1/chat/completions",
        ])
        let ordinaryBody = try XCTUnwrap(requests.last?.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ordinaryBody) as? [String: Any])
        XCTAssertNil(object["tools"])
        let routing = try XCTUnwrap(object["provider"] as? [String: Any])
        XCTAssertEqual(routing["allow_fallbacks"] as? Bool, false)
        XCTAssertEqual(routing["only"] as? [String], ["provider-a"])
    }

    func testExplicitHostedSearchFailsClosedWithoutOrdinaryRetry()
        async throws
    {
        let http = SequencedHTTP(attempts: [
            StreamAttempt(
                chunks: [],
                error: ProviderHTTPStatusError(
                    statusCode: 400,
                    body: Data(#"{"error":{"code":"unsupported_parameter","param":"tools[0].type","message":"not supported"}}"#.utf8),
                    headers: [:],
                    operation: "streaming request")),
        ])
        let provider = OpenAIWireProvider(
            endpoint: ProviderEndpoint(
                id: "router",
                baseURL: URL(string: "https://router.example/v1")!,
                apiKeyRef: KeychainRef(service: "s", account: "router"),
                wire: .openai,
                requestAdapter: .openRouter),
            apiKey: "k",
            http: http,
            runtimePolicy: ProviderRuntimePolicy(
                maxAttempts: 1,
                requestTimeoutSeconds: 1,
                initialRetryDelaySeconds: 0,
                maxRetryDelaySeconds: 0))

        do {
            for try await _ in provider.stream(ChatRequest(
                model: ModelID(rawValue: "m"),
                messages: [ChatMessage(role: .user, content: "hi")],
                webSearch: ChatWebSearchConfiguration(
                    dialect: .openRouterServerTool,
                    unsupportedBehavior: .failClosed,
                    toolChoice: .required))) {}
            XCTFail("explicit hosted search unexpectedly fell back")
        } catch {
            XCTAssertEqual(http.attemptCount, 1)
            XCTAssertEqual(
                http.recordedRequests.map { $0.url?.path },
                ["/v1/responses"])
            let body = try XCTUnwrap(
                http.recordedRequests.first?.httpBody)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body)
                    as? [String: Any])
            XCTAssertEqual(object["tool_choice"] as? String, "required")
        }
    }

    func testBareHostedSearch404DoesNotTriggerOrdinaryFallback()
        async throws
    {
        let http = SequencedHTTP(attempts: [
            StreamAttempt(
                chunks: [],
                error: ProviderHTTPStatusError(
                    statusCode: 404,
                    body: Data(#"{"error":{"message":"No endpoints found"}}"#.utf8),
                    headers: [:],
                    operation: "streaming request")),
        ])
        let provider = OpenAIWireProvider(
            endpoint: ProviderEndpoint(
                id: "router",
                baseURL: URL(string: "https://router.example/v1")!,
                apiKeyRef: KeychainRef(service: "s", account: "router"),
                wire: .openai,
                requestAdapter: .openRouter),
            apiKey: "k",
            http: http)

        do {
            for try await _ in provider.stream(ChatRequest(
                model: ModelID(rawValue: "m"),
                messages: [ChatMessage(role: .user, content: "hi")],
                webSearch: ChatWebSearchConfiguration(
                    dialect: .openRouterServerTool))) {}
            XCTFail("expected provider error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 404"))
            XCTAssertEqual(http.attemptCount, 1)
        }
    }

    func testHostedSearchRejectionAfterValidPayloadDoesNotReplayTurn()
        async throws
    {
        let sse = """
        data: {"type":"response.created","response":{"id":"resp_1"}}

        data: {"type":"error","code":"unsupported_parameter","param":"tools","message":"not supported"}

        """
        let http = SequencedHTTP(attempts: [
            StreamAttempt(chunks: [Data(sse.utf8)], error: nil),
        ])
        let provider = OpenAIWireProvider(
            endpoint: ProviderEndpoint(
                id: "router",
                baseURL: URL(string: "https://router.example/v1")!,
                apiKeyRef: KeychainRef(service: "s", account: "router"),
                wire: .openai,
                requestAdapter: .openRouter),
            apiKey: "k",
            http: http)

        do {
            for try await _ in provider.stream(ChatRequest(
                model: ModelID(rawValue: "m"),
                messages: [ChatMessage(role: .user, content: "hi")],
                webSearch: ChatWebSearchConfiguration(
                    dialect: .openRouterServerTool))) {}
            XCTFail("expected provider error")
        } catch {
            XCTAssertEqual(http.attemptCount, 1)
        }
    }

    func testWebSearchStreamingParsesAndDeduplicatesSafeCitations() async throws {
        let sse = """
        data: {"type":"response.output_text.delta","delta":"Latest"}

        data: {"type":"response.output_text.annotation.added","annotation":{"type":"url_citation","url":"https://example.com/story","title":"Example\\nNews"}}

        data: {"type":"response.output_text.annotation.added","annotation":{"type":"url_citation","url":"javascript:alert(1)","title":"Unsafe"}}

        data: {"type":"response.output_text.annotation.added","annotation":{"type":"url_citation","url_citation":{"url":"https://router.example/source","title":"Router source"}}}

        data: {"type":"response.output_item.done","item":{"type":"message","content":[{"type":"output_text","text":"Latest facts","annotations":[{"type":"url_citation","url":"https://example.com/story","title":"Example News"},{"type":"url_citation","url":"https://user:pass@unsafe.example/path","title":"Credentials"}]}]}}

        data: {"type":"response.completed","response":{"id":"resp_search","output":[{"type":"message","content":[{"type":"output_text","text":"Latest facts","annotations":[{"type":"url_citation","url":"https://example.com/story","title":"Example News"}]}]}],"usage":{"input_tokens":12,"output_tokens":3,"total_tokens":15,"input_tokens_details":{"cached_tokens":2}}}}

        """
        let provider = OpenAIWireProvider(
            endpoint: openAIEndpoint,
            apiKey: "k",
            http: FakeHTTP(chunks: [Data(sse.utf8)]))
        let request = ChatRequest(
            model: ModelID(rawValue: "gpt-search"),
            messages: [ChatMessage(role: .user, content: "latest")],
            webSearch: ChatWebSearchConfiguration(
                dialect: .openAIResponses))

        var text = ""
        var citations: [MessageCitation] = []
        var usage: Usage?
        var doneCount = 0
        for try await chunk in provider.stream(request) {
            switch chunk {
            case .delta(let value):
                text += value
            case .citation(let citation):
                citations.append(citation)
            case .usage(let value):
                usage = value
            case .done:
                doneCount += 1
            }
        }

        XCTAssertEqual(text, "Latest facts")
        XCTAssertEqual(citations, [
            MessageCitation(
                url: "https://example.com/story",
                title: "Example News"),
            MessageCitation(
                url: "https://router.example/source",
                title: "Router source"),
        ])
        XCTAssertEqual(usage?.promptTokens, 12)
        XCTAssertEqual(usage?.cachedPromptTokens, 2)
        XCTAssertEqual(usage?.completionTokens, 3)
        XCTAssertEqual(usage?.totalTokens, 15)
        XCTAssertEqual(doneCount, 1)
    }

    func testOpenAIStreamingNormalizesBearerAPIKeyInAuthorizationHeader() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"OK"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let http = CapturingHTTP(chunks: [Data(sse.utf8)])
        let provider = OpenAIWireProvider(endpoint: openAIEndpoint,
                                          apiKey: " \"Bearer valid-token\" ",
                                          http: http)

        for try await _ in provider.stream(ChatRequest(model: ModelID(rawValue: "m"),
                                                       messages: [ChatMessage(role: .user, content: "hi")])) {}

        XCTAssertEqual(http.lastRequest?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer valid-token")
        XCTAssertEqual(ProviderAuthorization.bearerHeaderValue(apiKey: "'Bearer valid-token'"),
                       "Bearer valid-token")
    }

    func testOpenAIStreamingParsesUsage() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"hi"}}]}

        data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":3,"total_tokens":14,"prompt_tokens_details":{"cached_tokens":4}}}

        data: [DONE]

        """
        let bytes = Array(sse.utf8)
        var chunks: [Data] = []
        var i = 0
        while i < bytes.count { let e = min(i + 9, bytes.count); chunks.append(Data(bytes[i..<e])); i = e }
        let endpoint = ProviderEndpoint(id: "e", baseURL: URL(string: "https://example.test/v1")!,
                                        apiKeyRef: KeychainRef(service: "s", account: "a"), wire: .openai)
        let provider = OpenAIWireProvider(endpoint: endpoint, apiKey: "k", http: FakeHTTP(chunks: chunks))
        var usage: Usage?
        for try await chunk in provider.stream(ChatRequest(model: ModelID(rawValue: "m"),
                                                           messages: [ChatMessage(role: .user, content: "hi")],
                                                           includeUsage: true)) {
            if case .usage(let u) = chunk { usage = u }
        }
        XCTAssertEqual(usage?.promptTokens, 11)
        XCTAssertEqual(usage?.cachedPromptTokens, 4)
        XCTAssertEqual(usage?.completionTokens, 3)
        XCTAssertEqual(usage?.totalTokens, 14)
    }

    func testOpenAIStreamingTreatsFinishReasonAsDoneWithoutDoneMarker() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"OK"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        """
        let provider = OpenAIWireProvider(endpoint: openAIEndpoint,
                                          apiKey: "k",
                                          http: FakeHTTP(chunks: [Data(sse.utf8)]))

        var text = ""
        var doneCount = 0
        for try await chunk in provider.stream(ChatRequest(model: ModelID(rawValue: "m"),
                                                           messages: [ChatMessage(role: .user, content: "hi")])) {
            switch chunk {
            case .delta(let value):
                text += value
            case .citation:
                break
            case .usage:
                break
            case .done:
                doneCount += 1
            }
        }

        XCTAssertEqual(text, "OK")
        XCTAssertEqual(doneCount, 1)
    }

    func testOpenAIStreamingReadsContentAndFinishFromNonFirstChoice() async throws {
        let sse = """
        data: {"choices":[{"index":0,"delta":{}},{"index":1,"delta":{"content":"OK"},"finish_reason":"stop"}]}

        """
        let provider = OpenAIWireProvider(endpoint: openAIEndpoint,
                                          apiKey: "k",
                                          http: FakeHTTP(chunks: [Data(sse.utf8)]))

        var text = ""
        var doneCount = 0
        for try await chunk in provider.stream(ChatRequest(model: ModelID(rawValue: "m"),
                                                           messages: [ChatMessage(role: .user, content: "hi")])) {
            switch chunk {
            case .delta(let value):
                text += value
            case .citation:
                break
            case .usage:
                break
            case .done:
                doneCount += 1
            }
        }

        XCTAssertEqual(text, "OK")
        XCTAssertEqual(doneCount, 1)
    }

    func testOpenAIStreamingKeepsUsageAfterFinishReasonAndDoesNotDuplicateDone() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"OK"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6}}

        data: [DONE]

        """
        let provider = OpenAIWireProvider(endpoint: openAIEndpoint,
                                          apiKey: "k",
                                          http: FakeHTTP(chunks: [Data(sse.utf8)]))

        var usage: Usage?
        var doneCount = 0
        for try await chunk in provider.stream(ChatRequest(model: ModelID(rawValue: "m"),
                                                           messages: [ChatMessage(role: .user, content: "hi")],
                                                           includeUsage: true)) {
            switch chunk {
            case .delta:
                break
            case .citation:
                break
            case .usage(let value):
                usage = value
            case .done:
                doneCount += 1
            }
        }

        XCTAssertEqual(doneCount, 1)
        XCTAssertEqual(usage?.promptTokens, 5)
        XCTAssertEqual(usage?.completionTokens, 1)
        XCTAssertEqual(usage?.totalTokens, 6)
    }

    func testOpenAIStreamingThrowsWhenCompletionMarkerMissing() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"partial"}}]}
        """ + "\n\n"
        let provider = OpenAIWireProvider(endpoint: openAIEndpoint,
                                          apiKey: "k",
                                          http: FakeHTTP(chunks: [Data(sse.utf8)]))

        var text = ""
        do {
            for try await chunk in provider.stream(ChatRequest(model: ModelID(rawValue: "m"),
                                                               messages: [ChatMessage(role: .user, content: "hi")])) {
                switch chunk {
                case .delta(let value):
                    text += value
                case .citation:
                    break
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

    func testOpenAIStreamingRejectsNonHTTPChatEndpointBeforeTransport() async {
        let provider = OpenAIWireProvider(
            endpoint: nonHTTPChatEndpoint,
            apiKey: "k",
            http: FakeHTTP(chunks: [Data("data: [DONE]\n\n".utf8)]))

        do {
            for try await _ in provider.stream(ChatRequest(model: ModelID(rawValue: "m"),
                                                           messages: [ChatMessage(role: .user, content: "hi")])) {}
            XCTFail("expected invalid provider endpoint error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalid provider endpoint 'bad-chat'"))
            XCTAssertTrue(error.localizedDescription.contains("Chat endpoint scheme 'file' is not supported"))
            XCTAssertTrue(error.localizedDescription.contains("http:// or https://"))
        }
    }

    func testProviderHTTPErrorIncludesStatusGuidanceAndProviderMessage() {
        let body = Data(#"{"error":{"message":"bad API key","type":"auth","code":"invalid_key"}}"#.utf8)
        let error = ProviderErrorFormatting.httpStatus(401, body: body, operation: "streaming request")

        XCTAssertTrue(error.localizedDescription.contains("HTTP 401 Unauthorized"))
        XCTAssertTrue(error.localizedDescription.contains("Check the API key"))
        XCTAssertTrue(error.localizedDescription.contains("bad API key"))
        XCTAssertTrue(error.localizedDescription.contains("code=invalid_key"))
    }

    func testProviderDiagnosticsRedactEchoedAuthorizationBeforePersistence() {
        let secret = "opaque-credential-that-must-not-survive"
        let body = Data(
            #"{"error":{"message":"Authorization: Bearer \#(secret)","type":"auth"}}"#.utf8)
        let httpError = ProviderErrorFormatting.httpStatus(
            401,
            body: body,
            operation: "streaming request")
        let streamError = ProviderErrorFormatting.streamErrorPayload(body)
        let usageError = ProviderUsageLimitError(
            signal: "insufficient_quota",
            providerMessage: "api_key=\(secret)")

        for message in [
            httpError.localizedDescription,
            streamError?.localizedDescription ?? "",
            usageError.localizedDescription,
        ] {
            XCTAssertFalse(message.contains(secret))
            XCTAssertTrue(message.contains("REDACTED"))
        }
    }

    func testProviderDiagnosticsRedactPrivateURLsFromStructuredMessageAndDetail() throws {
        let nestedURL = "http://10.24.8.9:8080/private/v1/chat/completions"
        let nestedBody = Data(
            #"{"error":{"message":"upstream \#(nestedURL) failed","type":"gateway","code":"upstream_502"}}"#.utf8)
        let detailURL = "https://internal-gateway.example.test/provider/v1?token=opaque-token"
        let detailBody = Data(#"{"detail":"proxy could not reach \#(detailURL)"}"#.utf8)

        let httpMessage = ProviderErrorFormatting.httpStatus(
            502,
            body: nestedBody,
            operation: "streaming request").localizedDescription
        let streamMessage = try XCTUnwrap(
            ProviderErrorFormatting.streamErrorPayload(detailBody)).localizedDescription
        let transportedMessage = ProviderErrorFormatting.transport(
            IntatisError.provider(
                "custom runtime could not reach \(nestedURL); status=502")).localizedDescription

        for message in [httpMessage, streamMessage, transportedMessage] {
            XCTAssertTrue(message.contains("[REDACTED_URL]"))
            XCTAssertFalse(message.contains("http://"))
            XCTAssertFalse(message.contains("https://"))
            XCTAssertFalse(message.contains("10.24.8.9"))
            XCTAssertFalse(message.contains("internal-gateway"))
            XCTAssertFalse(message.contains("opaque-token"))
        }
        XCTAssertTrue(httpMessage.contains("HTTP 502 Bad Gateway"))
        XCTAssertTrue(httpMessage.contains("type=gateway"))
        XCTAssertTrue(httpMessage.contains("code=upstream_502"))
        XCTAssertTrue(streamMessage.contains("Provider rejected the streaming request"))
        XCTAssertTrue(transportedMessage.contains("status=502"))
    }

    func testProviderTransportRejectsHTTPRedirectBeforeFollowingRoute() throws {
        let original = try XCTUnwrap(URL(string: "https://approved.example/v1/chat/completions"))
        let redirected = try XCTUnwrap(URL(string: "https://unreviewed.example/collect"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: original,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirected.absoluteString]))
        let session = ProviderURLSession.makeNoRedirectSession()
        let task = session.dataTask(with: URLRequest(url: original))
        var redirectDecision: URLRequest? = URLRequest(url: redirected)

        ProviderNoRedirectURLSessionDelegate.shared.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirected)) { request in
                redirectDecision = request
            }

        XCTAssertNil(redirectDecision)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertNil(session.configuration.urlCache)
        session.invalidateAndCancel()
    }

    func testProviderHTTPErrorUsesPreviewForUnstructuredBody() {
        let body = Data(#"<html><body>gateway generated an HTML error page</body></html>"#.utf8)
        let error = ProviderErrorFormatting.httpStatus(502, body: body, operation: "streaming request")

        XCTAssertTrue(error.localizedDescription.contains("HTTP 502 Bad Gateway"))
        XCTAssertTrue(error.localizedDescription.contains("upstream gateway failed"))
        XCTAssertTrue(error.localizedDescription.contains("Preview: <html><body>gateway generated an HTML error page"))
        XCTAssertFalse(error.localizedDescription.contains("Provider said:"))
    }

    func testProviderHTTPErrorIncludesRetryAfterHeaderGuidance() {
        let error = ProviderErrorFormatting.httpStatus(
            429,
            body: Data(#"{"error":{"message":"rate limited"}}"#.utf8),
            headers: ["Retry-After": "2"],
            operation: "streaming request")

        XCTAssertTrue(error.localizedDescription.contains("HTTP 429 Too Many Requests"))
        XCTAssertTrue(error.localizedDescription.contains("retry after about 2s"))
        XCTAssertTrue(error.localizedDescription.contains("retry-after"))
        XCTAssertTrue(error.localizedDescription.contains("rate limited"))
    }

    func testProviderUsageLimitTypeSurvivesRuntimeNormalizationAndExhaustion() throws {
        let original = ProviderUsageLimitError(
            signal: "insufficient_quota",
            providerMessage: "Account credits are exhausted.",
            statusCode: 429,
            operation: "streaming request")
        let policy = ProviderRuntimePolicy(maxAttempts: 3)

        let transported = try XCTUnwrap(
            ProviderErrorFormatting.transport(original) as? ProviderUsageLimitError)
        let exhausted = try XCTUnwrap(
            ProviderRuntime.exhausted(
                original,
                attempts: 3,
                operation: "streaming request") as? ProviderUsageLimitError)

        XCTAssertEqual(transported, original)
        XCTAssertEqual(exhausted, original)
        XCTAssertFalse(ProviderRuntime.shouldRetry(
            error: original,
            attempt: 1,
            policy: policy))
    }

    func testContextWindowOverflowRequiresStructuredProviderSignal()
        throws
    {
        let body = Data(
            #"{"error":{"message":"maximum input reached","type":"invalid_request_error","code":"context_length_exceeded"}}"#.utf8)
        let typed = try XCTUnwrap(
            ProviderErrorFormatting.httpStatus(
                400,
                body: body,
                operation: "streaming request")
                as? ProviderContextWindowExceededError)
        XCTAssertEqual(typed.signal, "context_length_exceeded")
        XCTAssertEqual(typed.statusCode, 400)

        let proseOnly = Data(
            #"{"error":{"message":"context length exceeded","type":"invalid_request_error","code":"bad_request"}}"#.utf8)
        XCTAssertFalse(
            ProviderErrorFormatting.httpStatus(
                400,
                body: proseOnly,
                operation: "streaming request")
                is ProviderContextWindowExceededError)
    }

    func testContextWindowTypeSurvivesRuntimeNormalizationAndExhaustion()
        throws
    {
        let original = ProviderContextWindowExceededError(
            signal: "context_window_exceeded",
            providerMessage: "input is too large",
            statusCode: 400,
            operation: "streaming request")
        let policy = ProviderRuntimePolicy(maxAttempts: 3)

        XCTAssertEqual(
            try XCTUnwrap(
                ProviderErrorFormatting.transport(original)
                    as? ProviderContextWindowExceededError),
            original)
        XCTAssertEqual(
            try XCTUnwrap(
                ProviderRuntime.exhausted(
                    original,
                    attempts: 3,
                    operation: "streaming request")
                    as? ProviderContextWindowExceededError),
            original)
        XCTAssertFalse(ProviderRuntime.shouldRetry(
            error: original,
            attempt: 1,
            policy: policy))
    }

    func testRetryAfterHeaderControlsRuntimeDelayAndCapsLongValues() {
        let hint = ProviderErrorFormatting.retryHint(headers: ["Retry-After": "3"])
        XCTAssertEqual(hint?.delaySeconds, 3)

        let policy = ProviderRuntimePolicy(maxAttempts: 2,
                                           requestTimeoutSeconds: 1,
                                           initialRetryDelaySeconds: 0.1,
                                           maxRetryDelaySeconds: 0.5,
                                           maxRetryAfterDelaySeconds: 5)
        XCTAssertEqual(ProviderRuntime.retryDelayNanoseconds(forNextAttempt: 2,
                                                             policy: policy,
                                                             retryHint: hint),
                       3_000_000_000)

        let cappedPolicy = ProviderRuntimePolicy(maxAttempts: 2,
                                                 requestTimeoutSeconds: 1,
                                                 initialRetryDelaySeconds: 0.1,
                                                 maxRetryDelaySeconds: 0.5,
                                                 maxRetryAfterDelaySeconds: 1)
        XCTAssertEqual(ProviderRuntime.retryDelayNanoseconds(forNextAttempt: 2,
                                                             policy: cappedPolicy,
                                                             retryHint: hint),
                       1_000_000_000)
    }

    func testRetryHintHandlesCaseDuplicateHeadersAndHTTPDates() {
        let duplicateCaseHint = ProviderErrorFormatting.retryHint(headers: [
            "Retry-After": "2",
            "retry-after": "3",
        ])
        XCTAssertTrue([2, 3].contains(Int(duplicateCaseHint?.delaySeconds ?? -1)))
        XCTAssertEqual(duplicateCaseHint?.source, "retry-after")

        let now = Date(timeIntervalSince1970: 1_445_412_470)
        let dateHint = ProviderErrorFormatting.retryHint(
            headers: ["x-ratelimit-reset": "Wed, 21 Oct 2015 07:28:00 GMT"],
            now: now)
        XCTAssertEqual(dateHint?.delaySeconds, 10)
        XCTAssertEqual(dateHint?.source, "x-ratelimit-reset")
    }

    func testRetryHintParsesDurationStyleRateLimitHeaders() {
        let millisecondHint = ProviderErrorFormatting.retryHint(headers: [
            "x-ratelimit-reset-tokens": "750ms",
        ])
        XCTAssertEqual(millisecondHint?.delaySeconds, 0.75)
        XCTAssertEqual(millisecondHint?.source, "x-ratelimit-reset-tokens")

        let combinedHint = ProviderErrorFormatting.retryHint(headers: [
            "x-ratelimit-reset-requests": "1m30s",
        ])
        XCTAssertEqual(combinedHint?.delaySeconds, 90)
        XCTAssertEqual(combinedHint?.source, "x-ratelimit-reset-requests")

        let spacedHint = ProviderErrorFormatting.retryHint(headers: [
            "ratelimit-reset": "2 s",
        ])
        XCTAssertEqual(spacedHint?.delaySeconds, 2)
        XCTAssertEqual(spacedHint?.source, "ratelimit-reset")
    }

    func testOpenAIStreamingThrowsProviderErrorPayload() async throws {
        let sse = """
        data: {"error":{"message":"model not found","type":"invalid_request_error","code":"model_not_found"}}

        """
        let provider = OpenAIWireProvider(endpoint: openAIEndpoint, apiKey: "k", http: FakeHTTP(chunks: [Data(sse.utf8)]))

        do {
            for try await _ in provider.stream(ChatRequest(model: ModelID(rawValue: "missing"),
                                                           messages: [ChatMessage(role: .user, content: "hi")])) {}
            XCTFail("expected provider error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("model not found"))
            XCTAssertTrue(error.localizedDescription.contains("model_not_found"))
        }
    }

    func testOpenAIStreamingThrowsOnMalformedSSEPayload() async throws {
        let sse = """
        data: not-json

        """
        let provider = OpenAIWireProvider(endpoint: openAIEndpoint, apiKey: "k", http: FakeHTTP(chunks: [Data(sse.utf8)]))

        do {
            for try await _ in provider.stream(ChatRequest(model: ModelID(rawValue: "m"),
                                                           messages: [ChatMessage(role: .user, content: "hi")])) {}
            XCTFail("expected decoding error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("non-JSON SSE data"))
            XCTAssertTrue(error.localizedDescription.contains("not-json"))
        }
    }

    func testOpenAIStreamingRetriesRetryableHTTPBeforeResponseBytes() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"OK"}}]}

        data: [DONE]

        """
        let http = SequencedHTTP(attempts: [
            StreamAttempt(
                chunks: [],
                error: ProviderErrorFormatting.httpStatus(
                    503,
                    body: Data(#"{"error":{"message":"upstream overloaded"}}"#.utf8),
                    operation: "streaming request")),
            StreamAttempt(chunks: [Data(sse.utf8)], error: nil),
        ])
        let provider = OpenAIWireProvider(
            endpoint: openAIEndpoint,
            apiKey: "k",
            http: http,
            runtimePolicy: ProviderRuntimePolicy(maxAttempts: 2,
                                                 requestTimeoutSeconds: 1,
                                                 initialRetryDelaySeconds: 0,
                                                 maxRetryDelaySeconds: 0))

        var text = ""
        for try await chunk in provider.stream(ChatRequest(model: ModelID(rawValue: "m"),
                                                           messages: [ChatMessage(role: .user, content: "hi")])) {
            if case .delta(let value) = chunk {
                text += value
            }
        }

        XCTAssertEqual(text, "OK")
        XCTAssertEqual(http.attemptCount, 2)
    }

    func testOpenAIStreamingDoesNotRetryAfterResponseBytes() async throws {
        let sse = #"""
        data: {"choices":[{"delta":{"content":"partial"}}]}

        data: {"error":{"message":"Network connection lost","code":502}}

        """#
        let http = SequencedHTTP(attempts: [
            StreamAttempt(
                chunks: [Data(sse.utf8)],
                error: nil),
            StreamAttempt(chunks: [Data("data: [DONE]\n\n".utf8)], error: nil),
        ])
        let provider = OpenAIWireProvider(
            endpoint: openAIEndpoint,
            apiKey: "k",
            http: http,
            runtimePolicy: ProviderRuntimePolicy(maxAttempts: 2,
                                                 requestTimeoutSeconds: 1,
                                                 initialRetryDelaySeconds: 0,
                                                 maxRetryDelaySeconds: 0))

        var text = ""
        do {
            for try await chunk in provider.stream(ChatRequest(model: ModelID(rawValue: "m"),
                                                               messages: [ChatMessage(role: .user, content: "hi")])) {
                if case .delta(let value) = chunk {
                    text += value
                    // The important invariant is that a stream that has already
                    // delivered semantic output is not retried, because that can
                    // duplicate text or tool calls.
                }
            }
            XCTFail("expected mid-stream provider error")
        } catch {
            XCTAssertEqual(text, "partial")
            XCTAssertEqual(http.attemptCount, 1)
            XCTAssertTrue(error.localizedDescription.contains("Network connection lost"))
        }
    }

    func testRegistryResolvesOpenAIProvider() async throws {
        let endpoint = ProviderEndpoint(id: "default",
                                        baseURL: URL(string: "https://example.test/v1")!,
                                        apiKeyRef: KeychainRef(service: "s", account: "a"),
                                        wire: .openai)
        let config = ProviderConfig(
            endpoints: [endpoint],
            models: ResolvedModels(chat: ModelRef(endpoint: "default", model: ModelID(rawValue: "gpt-x"))))
        let registry = ProviderRegistry(config: config, resolver: StaticSecret(key: "k"), http: FakeHTTP(chunks: []))
        let resolved = try await registry.defaultChatProvider()
        let provider = try XCTUnwrap(resolved as? OpenAIWireProvider)
        XCTAssertEqual(provider.runtimePolicy, .streaming)
        XCTAssertEqual(provider.runtimePolicy.requestTimeoutSeconds, 120)
    }

    func testRegistryIgnoresLegacyWebSearchRouteAndPlansCurrentOpenRouterModel()
        async throws
    {
        let chatEndpoint = ProviderEndpoint(
            id: "chat",
            baseURL: URL(string: "https://chat.example.test/v1")!,
            apiKeyRef: KeychainRef(service: "s", account: "chat"),
            wire: .openai,
            requestAdapter: .openRouter,
            modelCapabilities: [
                "chat-model": [.chat, .hostedWebSearch],
            ])
        let searchEndpoint = ProviderEndpoint(
            id: "search",
            baseURL: URL(string: "https://search.example.test/v1")!,
            apiKeyRef: KeychainRef(service: "s", account: "search"),
            wire: .openai)
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [chatEndpoint, searchEndpoint],
                models: ResolvedModels(
                    chat: ModelRef(
                        endpoint: "chat",
                        model: ModelID(rawValue: "chat-model")),
                    webSearch: ModelRef(
                        endpoint: "search",
                        model: ModelID(rawValue: "search-model")))),
            resolver: StaticSecret(key: "k"),
            http: FakeHTTP(chunks: []))

        let route = try await registry.chatRuntimeRoute()

        XCTAssertEqual(route.model.rawValue, "chat-model")
        XCTAssertEqual(
            try XCTUnwrap(route.provider as? OpenAIWireProvider)
                .endpoint.id,
            "chat")
        XCTAssertEqual(
            route.webSearch,
            ChatWebSearchConfiguration(
                dialect: .openRouterServerTool,
                contextSize: .medium))
    }

    func testRegistrySilentlyUsesOrdinaryChatWhenHostedSearchIsUndeclared()
        async throws
    {
        let endpoint = ProviderEndpoint(
            id: "chat",
            baseURL: URL(string: "https://chat.example.test/v1")!,
            apiKeyRef: KeychainRef(service: "s", account: "chat"),
            wire: .openai)
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(chat: ModelRef(
                    endpoint: "chat",
                    model: ModelID(rawValue: "chat-model")))),
            resolver: StaticSecret(key: "k"),
            http: FakeHTTP(chunks: []))

        let route = try await registry.chatRuntimeRoute()

        XCTAssertEqual(route.model.rawValue, "chat-model")
        XCTAssertEqual(
            try XCTUnwrap(route.provider as? OpenAIWireProvider).endpoint.id,
            "chat")
        XCTAssertNil(route.webSearch)
    }

    func testRegistrySilentlyUsesOrdinaryChatForCompatibleAdapterEvenWhenDeclared()
        async throws
    {
        let endpoint = ProviderEndpoint(
            id: "chat",
            baseURL: URL(string: "https://chat.example.test/v1")!,
            apiKeyRef: KeychainRef(service: "s", account: "chat"),
            wire: .openai,
            requestAdapter: .openAICompatible,
            modelCapabilities: [
                "chat-model": [.chat, .hostedWebSearch],
            ])
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(
                    chat: ModelRef(
                        endpoint: "chat",
                        model: ModelID(rawValue: "chat-model")),
                    webSearch: ModelRef(
                        endpoint: "missing-legacy-route",
                        model: ModelID(rawValue: "ignored")))),
            resolver: StaticSecret(key: "k"),
            http: FakeHTTP(chunks: []))

        let route = try await registry.chatRuntimeRoute()

        XCTAssertEqual(route.model.rawValue, "chat-model")
        XCTAssertEqual(
            try XCTUnwrap(route.provider as? OpenAIWireProvider).endpoint.id,
            "chat")
        XCTAssertNil(route.webSearch)
    }

    func testUnsupportedHostedSearchRouteSendsOneOrdinaryRequestWithoutProbe()
        async throws
    {
        let sse = """
        data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let http = CapturingHTTP(chunks: [Data(sse.utf8)])
        let endpoint = ProviderEndpoint(
            id: "chat",
            baseURL: URL(string: "https://chat.example.test/v1")!,
            apiKeyRef: KeychainRef(service: "s", account: "chat"),
            wire: .openai,
            requestAdapter: .openAICompatible,
            modelCapabilities: [
                "chat-model": [.chat, .hostedWebSearch],
            ])
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(
                    chat: ModelRef(
                        endpoint: "chat",
                        model: ModelID(rawValue: "chat-model")),
                    webSearch: ModelRef(
                        endpoint: "unused",
                        model: ModelID(rawValue: "unused")))),
            resolver: StaticSecret(key: "k"),
            http: http)

        let route = try await registry.chatRuntimeRoute()
        for try await _ in route.provider.stream(ChatRequest(
            model: route.model,
            messages: [ChatMessage(role: .user, content: "hi")],
            webSearch: route.webSearch)) {}

        XCTAssertEqual(http.requestCount, 1)
        XCTAssertEqual(http.lastRequest?.url?.path, "/v1/chat/completions")
        let body = try XCTUnwrap(http.lastBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(object["tools"])
        XCTAssertNil(object["tool_choice"])
    }

    func testChatRuntimeRouteReplansCapabilityForModelOverride()
        async throws
    {
        let endpoint = ProviderEndpoint(
            id: "chat",
            baseURL: URL(string: "https://chat.example.test/v1")!,
            apiKeyRef: KeychainRef(service: "s", account: "chat"),
            wire: .openai,
            requestAdapter: .openRouter,
            modelCapabilities: [
                "search-model": [.chat, .hostedWebSearch],
                "plain-model": [.chat],
            ])
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(chat: ModelRef(
                    endpoint: "chat",
                    model: ModelID(rawValue: "search-model")))),
            resolver: StaticSecret(key: "k"),
            http: FakeHTTP(chunks: []))

        let searchable = try await registry.chatRuntimeRoute()
        let plain = try await registry.chatRuntimeRoute(
            model: ModelID(rawValue: "plain-model"))

        XCTAssertEqual(searchable.model.rawValue, "search-model")
        XCTAssertEqual(searchable.webSearch?.dialect,
                       .openRouterServerTool)
        XCTAssertEqual(plain.model.rawValue, "plain-model")
        XCTAssertNil(plain.webSearch)
    }

    func testRegistryUsesLongRunningStreamingPolicyOnlyForAgentProvider() async throws {
        let endpoint = ProviderEndpoint(
            id: "default",
            baseURL: URL(string: "https://example.test/v1")!,
            apiKeyRef: KeychainRef(service: "s", account: "a"),
            wire: .openai)
        let config = ProviderConfig(
            endpoints: [endpoint],
            models: ResolvedModels(
                chat: ModelRef(
                    endpoint: "default",
                    model: ModelID(rawValue: "gpt-chat")),
                agent: ModelRef(
                    endpoint: "default",
                    model: ModelID(rawValue: "gpt-agent"))))
        let registry = ProviderRegistry(
            config: config,
            resolver: StaticSecret(key: "k"),
            http: FakeHTTP(chunks: []))

        let resolvedChat = try await registry.defaultChatProvider()
        let resolvedAgent = try await registry.defaultAgentProvider()
        let chat = try XCTUnwrap(resolvedChat as? OpenAIWireProvider)
        let agent = try XCTUnwrap(resolvedAgent as? OpenAIWireProvider)

        XCTAssertEqual(chat.runtimePolicy, .streaming)
        XCTAssertEqual(chat.runtimePolicy.requestTimeoutSeconds, 120)
        XCTAssertEqual(agent.runtimePolicy, .agentStreaming)
        XCTAssertEqual(agent.runtimePolicy.requestTimeoutSeconds, 180)
    }

    func testAgentRuntimeRouteExposesExactProviderHostedSearchCapability()
        async throws
    {
        let endpoint = ProviderEndpoint(
            id: "router",
            baseURL: URL(string: "https://router.example.test/v1")!,
            apiKeyRef: KeychainRef(service: "s", account: "router"),
            wire: .openai,
            requestAdapter: .openRouter,
            modelCapabilities: [
                "agent-model": [.toolCalling, .hostedWebSearch],
            ])
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(
                    chat: ModelRef(
                        endpoint: "router",
                        model: ModelID(rawValue: "chat-model")),
                    agent: ModelRef(
                        endpoint: "router",
                        model: ModelID(rawValue: "agent-model")))),
            resolver: StaticSecret(key: "k"),
            http: FakeHTTP(chunks: []))

        let route = try await registry.defaultAgentRuntimeRoute()
        let hosted = try XCTUnwrap(route.hostedWebSearch)

        XCTAssertEqual(route.model.rawValue, "agent-model")
        XCTAssertEqual(hosted.model, route.model)
        XCTAssertEqual(hosted.configuration.dialect, .openRouterServerTool)
        XCTAssertEqual(hosted.configuration.contextSize, .medium)
        XCTAssertEqual(
            hosted.configuration.unsupportedBehavior,
            .failClosed)
        XCTAssertEqual(hosted.configuration.toolChoice, .required)
        XCTAssertEqual(
            try XCTUnwrap(route.provider as? OpenAIWireProvider)
                .endpoint.id,
            "router")
        XCTAssertEqual(
            try XCTUnwrap(hosted.provider as? OpenAIWireProvider)
                .endpoint.id,
            "router")

        let codexRoute = try await registry.codexRuntimeRoute()
        let codexHosted = try XCTUnwrap(
            codexRoute.hostedWebSearch)
        XCTAssertEqual(codexRoute.responses.model, route.model)
        XCTAssertEqual(
            codexRoute.responses.requestAdapter,
            .openRouter)
        XCTAssertEqual(codexHosted.model, codexRoute.responses.model)
        XCTAssertEqual(
            codexHosted.configuration.toolChoice,
            .required)
    }

    func testAgentRuntimeRouteDoesNotInferHostedSearchFromCompatibleWire()
        async throws
    {
        let endpoint = ProviderEndpoint(
            id: "compatible",
            baseURL: URL(string: "https://compatible.example.test/v1")!,
            apiKeyRef: KeychainRef(service: "s", account: "compatible"),
            wire: .openai,
            requestAdapter: .openAICompatible,
            modelCapabilities: [
                "agent-model": [.toolCalling, .hostedWebSearch],
            ])
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(
                    chat: ModelRef(
                        endpoint: "compatible",
                        model: ModelID(rawValue: "chat-model")),
                    agent: ModelRef(
                        endpoint: "compatible",
                        model: ModelID(rawValue: "agent-model")))),
            resolver: StaticSecret(key: "k"),
            http: FakeHTTP(chunks: []))

        let route = try await registry.defaultAgentRuntimeRoute()
        let codexRoute = try await registry.codexRuntimeRoute()

        XCTAssertNil(route.hostedWebSearch)
        XCTAssertNil(codexRoute.hostedWebSearch)
    }

    func testRegistryUnknownEndpointThrows() async {
        let config = ProviderConfig(
            endpoints: [],
            models: ResolvedModels(chat: ModelRef(endpoint: "missing", model: ModelID(rawValue: "x"))))
        let registry = ProviderRegistry(config: config, resolver: StaticSecret(key: "k"), http: FakeHTTP(chunks: []))
        do {
            _ = try await registry.defaultChatProvider()
            XCTFail("expected unknown-endpoint error")
        } catch {
            // expected
        }
    }

    func testHealthCheckReportsOKForCompletedChatStream() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"OK"}}]}

        data: {"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}

        data: [DONE]

        """
        let config = ProviderConfig(
            endpoints: [openAIEndpoint],
            models: ResolvedModels(chat: ModelRef(endpoint: "e", model: ModelID(rawValue: "gpt-health"))))
        let http = CapturingHTTP(chunks: [Data(sse.utf8)])
        let registry = ProviderRegistry(config: config, resolver: StaticSecret(key: "k"), http: http)

        let report = await registry.healthCheck()

        XCTAssertEqual(report.status, .ok)
        XCTAssertEqual(report.role, .chat)
        XCTAssertEqual(report.endpointID, "e")
        XCTAssertEqual(report.model.rawValue, "gpt-health")
        XCTAssertEqual(report.wire, .openai)
        XCTAssertEqual(report.totalTokens, 3)
        XCTAssertEqual(report.responsePreview, "OK")
        XCTAssertNil(report.code)
        let body = try XCTUnwrap(http.lastBody)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(root["temperature"])
    }

    func testHealthCheckReportsPartialStreamWhenDoneMarkerMissing() async {
        let sse = """
        data: {"choices":[{"delta":{"content":"partial"}}]}

        """
        let config = ProviderConfig(
            endpoints: [openAIEndpoint],
            models: ResolvedModels(chat: ModelRef(endpoint: "e", model: ModelID(rawValue: "gpt-health"))))
        let registry = ProviderRegistry(config: config, resolver: StaticSecret(key: "k"), http: FakeHTTP(chunks: [Data(sse.utf8)]))

        let report = await registry.healthCheck()

        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.code, "provider.partial_stream")
        XCTAssertEqual(report.responsePreview, "partial")
        XCTAssertTrue(report.message.contains("completion marker"))
    }

    func testHealthCheckAcceptsFinishReasonWhenDoneMarkerMissing() async {
        let sse = """
        data: {"choices":[{"delta":{"content":"OK"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        """
        let config = ProviderConfig(
            endpoints: [openAIEndpoint],
            models: ResolvedModels(chat: ModelRef(endpoint: "e", model: ModelID(rawValue: "gpt-health"))))
        let registry = ProviderRegistry(config: config,
                                        resolver: StaticSecret(key: "k"),
                                        http: FakeHTTP(chunks: [Data(sse.utf8)]))

        let report = await registry.healthCheck()

        XCTAssertEqual(report.status, .ok)
        XCTAssertEqual(report.code, nil)
        XCTAssertEqual(report.responsePreview, "OK")
    }

    func testHealthCheckReportsTimeout() async {
        let config = ProviderConfig(
            endpoints: [openAIEndpoint],
            models: ResolvedModels(chat: ModelRef(endpoint: "e", model: ModelID(rawValue: "gpt-health"))))
        let registry = ProviderRegistry(
            config: config,
            resolver: StaticSecret(key: "k"),
            http: DelayedHTTP(delayNanoseconds: 2_000_000_000))

        let report = await registry.healthCheck(options: ProviderHealthCheckOptions(timeoutSeconds: 0.01))

        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.code, "provider.timeout")
        XCTAssertTrue(report.message.contains("timed out"))
    }

    func testHealthCheckReportsUnknownEndpointWithoutThrowing() async {
        let config = ProviderConfig(
            endpoints: [],
            models: ResolvedModels(chat: ModelRef(endpoint: "missing", model: ModelID(rawValue: "x"))))
        let registry = ProviderRegistry(config: config, resolver: StaticSecret(key: "k"), http: FakeHTTP(chunks: []))

        let report = await registry.healthCheck()

        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.code, "config")
        XCTAssertEqual(report.endpointID, "missing")
        XCTAssertTrue(report.message.contains("unknown endpoint"))
    }

    func testHealthCheckReportsInvalidProviderURLAsConfigError() async {
        let config = ProviderConfig(
            endpoints: [nonHTTPChatEndpoint],
            models: ResolvedModels(chat: ModelRef(endpoint: "bad-chat", model: ModelID(rawValue: "x"))))
        let registry = ProviderRegistry(
            config: config,
            resolver: StaticSecret(key: "k"),
            http: FakeHTTP(chunks: [Data("data: [DONE]\n\n".utf8)]))

        let report = await registry.healthCheck()

        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.code, "config")
        XCTAssertEqual(report.endpointID, "bad-chat")
        XCTAssertTrue(report.message.contains("invalid provider endpoint 'bad-chat'"))
        XCTAssertTrue(report.message.contains("Chat endpoint scheme 'file' is not supported"))
    }

    func testHealthCheckCanUseAgentRole() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"OK"}}]}

        data: {"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        """
        let config = ProviderConfig(
            endpoints: [openAIEndpoint],
            models: ResolvedModels(
                chat: ModelRef(endpoint: "e", model: ModelID(rawValue: "gpt-chat")),
                agent: ModelRef(endpoint: "e", model: ModelID(rawValue: "gpt-agent"))))
        let http = CapturingHTTP(chunks: [Data(sse.utf8)])
        let registry = ProviderRegistry(config: config, resolver: StaticSecret(key: "k"), http: http)

        let report = await registry.healthCheck(role: .agent)

        XCTAssertEqual(report.status, .ok)
        XCTAssertEqual(report.role, .agent)
        XCTAssertEqual(report.model.rawValue, "gpt-agent")
        XCTAssertEqual(report.totalTokens, 3)
        XCTAssertEqual(report.responsePreview, "OK")

        let body = try XCTUnwrap(http.lastBody)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let streamOptions = try XCTUnwrap(root["stream_options"] as? [String: Any])
        XCTAssertEqual(streamOptions["include_usage"] as? Bool, true)
    }

    func testStrictRoutingHealthCheckPreservesOptionsWithoutInventingUnsupportedParameters()
        async throws
    {
        let model = "openai/gpt-strict"
        let endpoint = ProviderEndpoint(
            id: "strict",
            baseURL: URL(string: "https://openrouter.example.test/api/v1")!,
            apiKeyRef: KeychainRef(service: "s", account: "a"),
            wire: .openai,
            modelRequestOptions: [
                model: [
                    "provider": .object([
                        "require_parameters": .bool(true),
                    ]),
                ],
            ])
        let sse = """
        data: {"choices":[{"delta":{"content":"OK"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        """
        let http = CapturingHTTP(chunks: [Data(sse.utf8)])
        let modelRef = ModelRef(
            endpoint: "strict",
            model: ModelID(rawValue: model))
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(
                    chat: modelRef,
                    agent: modelRef)),
            resolver: StaticSecret(key: "k"),
            http: http)

        let report = await registry.healthCheck(role: .agent)

        XCTAssertEqual(report.status, .ok)
        let data = try XCTUnwrap(http.lastBody)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let routing = try XCTUnwrap(root["provider"] as? [String: Any])
        XCTAssertEqual(routing["require_parameters"] as? Bool, true)
        XCTAssertNil(root["temperature"])
        XCTAssertNil(root["max_tokens"])
        XCTAssertNil(root["max_completion_tokens"])
        XCTAssertNil(root["max_output_tokens"])
    }

    func testConfiguredModelOptionsPassThroughChatBodyWithoutOverridingRuntimeStructure() throws {
        let endpoint = ProviderEndpoint(
            id: "generic",
            baseURL: URL(string: "https://example.test/v1")!,
            apiKeyRef: KeychainRef(service: "s", account: "a"),
            wire: .openai,
            modelRequestOptions: [
                "vendor/model": [
                    "provider": .object([
                        "only": .array([.string("vendor-a")]),
                        "allow_fallbacks": .bool(false),
                    ]),
                    "vendor_extension": .object([
                        "mode": .string("exact"),
                        "threshold": .number(0.75),
                    ]),
                    "temperature": .number(0.9),
                    "model": .string("must-not-win"),
                    "messages": .array([]),
                    "tools": .array([]),
                    "stream": .bool(false),
                    "stream_options": .object(["include_usage": .bool(true)]),
                    "n": .number(8),
                    "best_of": .number(8),
                    "num_return_sequences": .number(8),
                    "candidate_count": .number(8),
                ],
            ])
        let provider = OpenAIWireProvider(endpoint: endpoint, apiKey: "k", http: FakeHTTP(chunks: []))
        let request = try provider.buildRequest(ChatRequest(
            model: ModelID(rawValue: "vendor/model"),
            messages: [ChatMessage(role: .user, content: "hello")],
            temperature: 0.2))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
        guard case .object(let body) = decoded else { return XCTFail("request body is not an object") }

        XCTAssertEqual(body["provider"], JSONValue.object([
            "only": .array([.string("vendor-a")]),
            "allow_fallbacks": .bool(false),
        ]))
        XCTAssertEqual(body["vendor_extension"], JSONValue.object([
            "mode": .string("exact"),
            "threshold": .number(0.75),
        ]))
        XCTAssertEqual(body["temperature"], JSONValue.number(0.2))
        XCTAssertEqual(body["model"], JSONValue.string("vendor/model"))
        XCTAssertEqual(body["stream"], JSONValue.bool(true))
        XCTAssertEqual(body["n"], JSONValue.number(1))
        XCTAssertNil(body["best_of"])
        XCTAssertNil(body["num_return_sequences"])
        XCTAssertNil(body["candidate_count"])
        XCTAssertNil(body["stream_options"])
        guard let messageValue = body["messages"],
              case .array(let messages) = messageValue else {
            return XCTFail("runtime messages were not encoded")
        }
        XCTAssertEqual(messages.count, 1)
        XCTAssertNil(body["tools"])
    }

    func testChatRequestCanonicalizesSDKReasoningAliasBeforeWire()
        throws {
        let endpoint = ProviderEndpoint(
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
                "deepseek/model": [
                    "reasoningEffort":
                        .string("xhigh"),
                    "provider": .object([
                        "only": .array([
                            .string("deepseek"),
                        ]),
                        "allow_fallbacks": .bool(false),
                        "require_parameters": .bool(true),
                    ]),
                ],
            ])
        let provider = OpenAIWireProvider(
            endpoint: endpoint,
            apiKey: "k",
            http: FakeHTTP(chunks: []))

        let request = try provider.buildRequest(
            ChatRequest(
                model: ModelID(
                    rawValue: "deepseek/model"),
                messages: [
                    ChatMessage(
                        role: .user,
                        content: "hello"),
                ]))
        let decoded = try JSONDecoder().decode(
            JSONValue.self,
            from: XCTUnwrap(request.httpBody))
        guard case .object(let body) = decoded else {
            return XCTFail(
                "request body is not an object")
        }

        XCTAssertEqual(
            body["reasoning_effort"],
            .string("xhigh"))
        XCTAssertNil(body["reasoningEffort"])
        XCTAssertEqual(
            body["provider"],
            .object([
                "only": .array([
                    .string("deepseek"),
                ]),
                "allow_fallbacks": .bool(false),
                "require_parameters": .bool(true),
            ]))
        XCTAssertNil(body["n"])
        XCTAssertNil(body["parallel_tool_calls"])
    }

    func testOpenAICompatibleAdapterKeepsNestedReasoningAlongsideCamelAlias()
        throws {
        let endpoint = ProviderEndpoint(
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
                "reasoning/model": [
                    "reasoning_effort":
                        .string("medium"),
                    "reasoningEffort":
                        .string("low"),
                    "reasoning": .object([
                        "effort": .string("xhigh"),
                        "max_tokens": .number(2_000),
                    ]),
                ],
            ])
        let provider = OpenAIWireProvider(
            endpoint: endpoint,
            apiKey: "k",
            http: FakeHTTP(chunks: []))

        let request = try provider.buildRequest(
            ChatRequest(
                model: ModelID(
                    rawValue: "reasoning/model"),
                messages: [
                    ChatMessage(
                        role: .user,
                        content: "hello"),
                ]))
        let decoded = try JSONDecoder().decode(
            JSONValue.self,
            from: XCTUnwrap(request.httpBody))
        guard case .object(let body) = decoded else {
            return XCTFail(
                "request body is not an object")
        }

        XCTAssertNil(body["reasoningEffort"])
        XCTAssertEqual(
            body["reasoning_effort"],
            .string("low"))
        XCTAssertEqual(
            body["reasoning"],
            .object([
                "effort": .string("xhigh"),
                "max_tokens": .number(2_000),
            ]))
    }

    func testOpenAICompatibleAdapterMatchesPinnedSDKAliasConflicts()
        throws {
        let endpoint = ProviderEndpoint(
            id: "compatible",
            baseURL: URL(
                string: "https://example.test/v1")!,
            apiKeyRef: KeychainRef(
                service: "s",
                account: "a"),
            wire: .openai,
            requestAdapter:
                .openAICompatible,
            modelRequestOptions: [
                "camel-wins": [
                    "reasoningEffort":
                        .string("xhigh"),
                    "reasoning_effort":
                        .string("low"),
                    "textVerbosity":
                        .string("high"),
                    "verbosity":
                        .string("low"),
                ],
                "snake-only": [
                    "reasoning_effort":
                        .string("high"),
                    "verbosity":
                        .string("medium"),
                ],
            ])
        let provider = OpenAIWireProvider(
            endpoint: endpoint,
            apiKey: "k",
            http: FakeHTTP(chunks: []))

        let camelRequest = try provider.buildRequest(
            ChatRequest(
                model: ModelID(
                    rawValue: "camel-wins"),
                messages: [
                    ChatMessage(
                        role: .user,
                        content: "hello"),
                ]))
        let camelValue = try JSONDecoder().decode(
            JSONValue.self,
            from: XCTUnwrap(camelRequest.httpBody))
        guard case .object(let camelBody) =
                camelValue else {
            return XCTFail(
                "request body is not an object")
        }
        XCTAssertEqual(
            camelBody["reasoning_effort"],
            .string("xhigh"))
        XCTAssertEqual(
            camelBody["verbosity"],
            .string("high"))
        XCTAssertNil(camelBody["reasoningEffort"])
        XCTAssertNil(camelBody["textVerbosity"])

        let snakeRequest = try provider.buildRequest(
            ChatRequest(
                model: ModelID(
                    rawValue: "snake-only"),
                messages: [
                    ChatMessage(
                        role: .user,
                        content: "hello"),
                ]))
        let snakeValue = try JSONDecoder().decode(
            JSONValue.self,
            from: XCTUnwrap(snakeRequest.httpBody))
        guard case .object(let snakeBody) =
                snakeValue else {
            return XCTFail(
                "request body is not an object")
        }
        XCTAssertNil(snakeBody["reasoning_effort"])
        XCTAssertNil(snakeBody["verbosity"])
    }

    func testModelAdapterOverrideUsesOpenRouterOptionSemantics()
        throws {
        let endpoint = ProviderEndpoint(
            id: "mixed",
            baseURL: URL(
                string: "https://example.test/v1")!,
            apiKeyRef: KeychainRef(
                service: "s",
                account: "a"),
            wire: .openai,
            requestAdapter:
                .openAICompatible,
            modelRequestAdapters: [
                "openrouter/model":
                    .openRouter,
            ],
            modelRequestOptions: [
                "openrouter/model": [
                    "reasoningEffort":
                        .string("xhigh"),
                    "reasoning": .object([
                        "effort":
                            .string("high"),
                    ]),
                    "provider": .object([
                        "only": .array([
                            .string("deepseek"),
                        ]),
                        "require_parameters":
                            .bool(true),
                    ]),
                    "cacheControl":
                        .null,
                ],
            ])
        let provider = OpenAIWireProvider(
            endpoint: endpoint,
            apiKey: "k",
            http: FakeHTTP(chunks: []))

        let request = try provider.buildRequest(
            ChatRequest(
                model: ModelID(
                    rawValue: "openrouter/model"),
                messages: [
                    ChatMessage(
                        role: .user,
                        content: "hello"),
                ]))
        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: XCTUnwrap(request.httpBody))
        guard case .object(let body) = value else {
            return XCTFail(
                "request body is not an object")
        }

        XCTAssertEqual(
            body["reasoningEffort"],
            .string("xhigh"))
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertNil(body["cacheControl"])
        XCTAssertNil(body["cache_control"])
        XCTAssertEqual(
            body["reasoning"],
            .object([
                "effort": .string("high"),
            ]))
        XCTAssertEqual(
            body["provider"],
            .object([
                "only": .array([
                    .string("deepseek"),
                ]),
                "require_parameters": .bool(true),
            ]))
    }

    func testUnknownProviderAdapterFailsBeforeBuildingNetworkRequest() {
        for rawAdapter in [
            "@private/adapter",
            "",
            "   ",
        ] {
            let endpoint = ProviderEndpoint(
                id: "unsupported",
                baseURL: URL(
                    string: "https://example.test/v1")!,
                apiKeyRef: KeychainRef(
                    service: "s",
                    account: "a"),
                wire: .openai,
                requestAdapter:
                    ProviderRequestAdapter(
                        rawValue: rawAdapter),
                modelRequestOptions: [
                    "m": [
                        "opaque": .bool(true),
                    ],
                ])
            let provider = OpenAIWireProvider(
                endpoint: endpoint,
                apiKey: "k",
                http: FakeHTTP(chunks: []))

            XCTAssertThrowsError(
                try provider.buildRequest(
                    ChatRequest(
                        model: ModelID(rawValue: "m"),
                        messages: [
                            ChatMessage(
                                role: .user,
                                content: "hello"),
                ])))
        }

        let modelOverrideEndpoint = ProviderEndpoint(
            id: "unsupported-model-override",
            baseURL: URL(
                string: "https://example.test/v1")!,
            apiKeyRef: KeychainRef(
                service: "s",
                account: "a"),
            wire: .openai,
            requestAdapter: .openAICompatible,
            modelRequestAdapters: [
                "m": ProviderRequestAdapter(
                    rawValue: "   "),
            ])
        let modelOverrideProvider = OpenAIWireProvider(
            endpoint: modelOverrideEndpoint,
            apiKey: "k",
            http: FakeHTTP(chunks: []))
        XCTAssertThrowsError(
            try modelOverrideProvider.buildRequest(
                ChatRequest(
                    model: ModelID(rawValue: "m"),
                    messages: [
                        ChatMessage(
                            role: .user,
                            content: "hello"),
                    ])))
    }

    func testProviderEndpointModelOptionsAreCodableAndLegacyEndpointsDefaultEmpty() throws {
        let endpoint = ProviderEndpoint(
            id: "generic",
            baseURL: URL(string: "https://example.test/v1")!,
            apiKeyRef: KeychainRef(service: "s", account: "a"),
            wire: .openai,
            modelRequestOptions: ["m": ["top_k": .number(7)]])
        let roundTrip = try JSONDecoder().decode(
            ProviderEndpoint.self,
            from: JSONEncoder().encode(endpoint))
        XCTAssertEqual(roundTrip, endpoint)

        let legacy = #"{"id":"legacy","baseURL":"https:\/\/example.test\/v1","apiKeyRef":{"service":"s","account":"a"},"wire":"openai"}"#
        let decoded = try JSONDecoder().decode(ProviderEndpoint.self, from: Data(legacy.utf8))
        XCTAssertTrue(decoded.modelRequestOptions.isEmpty)
        XCTAssertEqual(
            decoded.requestAdapter,
            .legacyOpenAIWire)
    }

    func testModelConfigurationPresentationReadsReasoningLabelsWithoutRewritingOptions() {
        let cases: [([String: JSONValue], String)] = [
            (["reasoning_effort": .string("max")], "max"),
            (["reasoningEffort": .string("xhigh")], "xhigh"),
            (["reasoning": .object(["effort": .string("high")])], "high"),
            (["output_config": .object(["effort": .string("medium")])], "medium"),
            (["thinking": .object(["budgetTokens": .number(16_000)])], "16000 tokens"),
            (["reasoning": .object(["max_tokens": .number(2_000)])], "2000 tokens"),
        ]

        for (options, expected) in cases {
            let original = options
            let presentation = ModelConfigurationPresentation(requestOptions: options)
            XCTAssertEqual(presentation.reasoningLabel, expected)
            XCTAssertEqual(options, original)
        }
    }

    func testModelConfigurationPresentationDoesNotPretendAnUnselectedVariantIsActive() {
        let presentation = ModelConfigurationPresentation(
            modelMetadata: [
                "variants": .object([
                    "high": .object(["reasoningEffort": .string("high")]),
                    "low": .object(["reasoningEffort": .string("low")]),
                ]),
                "capabilities": .object(["effort": .string("unrelated")]),
            ],
            requestOptions: [:])

        XCTAssertNil(presentation.reasoningLabel)
    }

    func testModelConfigurationPresentationCanReadDirectModelMetadata() {
        let presentation = ModelConfigurationPresentation(
            modelMetadata: ["reasoningEffort": .string("max")],
            requestOptions: [:])

        XCTAssertEqual(presentation.reasoningLabel, "max")
    }
}
