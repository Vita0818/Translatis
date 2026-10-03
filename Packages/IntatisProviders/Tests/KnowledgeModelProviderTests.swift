import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisProviders

private actor CountingKnowledgeSecretResolver: SecretResolver {
    private var references: [KeychainRef] = []

    func secret(for ref: KeychainRef) async throws -> String {
        references.append(ref)
        return "knowledge-test-secret"
    }

    func resolvedReferences() -> [KeychainRef] { references }
}

private actor FailingKnowledgeSecretResolver: SecretResolver {
    private var references: [KeychainRef] = []

    func secret(for ref: KeychainRef) async throws -> String {
        references.append(ref)
        throw IntatisError.config("knowledge test credential unavailable")
    }

    func resolvedReferences() -> [KeychainRef] { references }
}

private actor CapturingKnowledgeDataClient: HTTPDataClient {
    private var responses: [HTTPDataResponse]
    private var recorded: [URLRequest] = []

    init(responses: [HTTPDataResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let response = try await sendResponse(request)
        return (response.data, response.status)
    }

    func sendResponse(_ request: URLRequest) async throws -> HTTPDataResponse {
        recorded.append(request)
        guard !responses.isEmpty else {
            throw IntatisError.provider("unexpected knowledge request")
        }
        return responses.removeFirst()
    }

    func requests() -> [URLRequest] { recorded }
}

private actor BlockingKnowledgeDataClient: HTTPDataClient {
    private var started = 0
    private var cancelled = 0

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let response = try await sendResponse(request)
        return (response.data, response.status)
    }

    func sendResponse(_ request: URLRequest) async throws -> HTTPDataResponse {
        _ = request
        started += 1
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw IntatisError.provider("blocking test transport unexpectedly resumed")
        } catch is CancellationError {
            cancelled += 1
            throw CancellationError()
        }
    }

    func counts() -> (started: Int, cancelled: Int) {
        (started, cancelled)
    }
}

final class KnowledgeModelProviderTests: XCTestCase {
    func testOpenRouterKnowledgeRoutesUseOfficialEndpointsAndUsageShape()
        async throws {
        let resolver = CountingKnowledgeSecretResolver()
        let embeddingVector = [Double](repeating: 0.25, count: 1_536)
        let embeddingData = try JSONSerialization.data(withJSONObject: [
            "data": [["index": 0, "embedding": embeddingVector]],
            "usage": ["prompt_tokens": 4, "total_tokens": 4],
        ])
        let rerankerData = Data(#"{"model":"cohere/rerank-4-pro","results":[{"document":{"text":"relevant"},"index":1,"relevance_score":0.97},{"document":{"text":"other"},"index":0,"relevance_score":0.08}],"id":"gen-rerank-test","usage":{"search_units":1,"total_tokens":19}}"#.utf8)
        let http = CapturingKnowledgeDataClient(responses: [
            HTTPDataResponse(data: embeddingData, status: 200),
            HTTPDataResponse(data: rerankerData, status: 200),
        ])
        let endpoint = ProviderEndpoint(
            id: "OpenRouter",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            apiKeyRef: .environment("OPENROUTER_API_KEY"),
            wire: .openai,
            requestAdapter: .openRouter)
        let config = ProviderConfig(
            endpoints: [endpoint],
            models: ResolvedModels(
                chat: ModelRef(
                    endpoint: endpoint.id,
                    model: ModelID(rawValue: "chat-unused")),
                embedding: ModelRef(
                    endpoint: endpoint.id,
                    model: ModelID(rawValue: "google/gemini-embedding-2")),
                reranker: ModelRef(
                    endpoint: endpoint.id,
                    model: ModelID(rawValue: "cohere/rerank-4-pro"))))

        XCTAssertNoThrow(try ProviderRegistry.validateKnowledgeConfiguration(config))
        let registry = ProviderRegistry(
            config: config,
            resolver: resolver,
            dataClient: http)
        let models = try await registry.configuredKnowledgeModels()
        XCTAssertEqual(models.embedding.configuration.dialect, .openRouterV1)
        XCTAssertEqual(models.embedding.configuration.dimensions, 1_536)
        XCTAssertEqual(models.embedding.configuration.requestDimensions, 1_536)
        XCTAssertEqual(models.reranker.configuration.dialect, .openRouterV1)

        let embedding = try await models.embedding.embedWithUsage(
            ["knowledge"],
            instruction: "")
        XCTAssertEqual(embedding.vectors.first?.count, 1_536)
        XCTAssertEqual(embedding.usage?.inputTokens, 4)
        let reranked = try await models.reranker.rerankWithUsage(
            query: "knowledge retrieval",
            documents: ["other", "relevant"])
        XCTAssertEqual(reranked.results.map(\.index), [1, 0])
        XCTAssertEqual(reranked.usage?.totalTokens, 19)
        XCTAssertEqual(reranked.usage?.billedSearchUnits, 1)

        let requests = await http.requests()
        XCTAssertEqual(
            requests.map(\.url?.absoluteString),
            [
                "https://openrouter.ai/api/v1/embeddings",
                "https://openrouter.ai/api/v1/rerank",
            ])
        let embeddingBody = try XCTUnwrap(requests.first?.httpBody)
        let embeddingJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: embeddingBody) as? [String: Any])
        XCTAssertEqual(
            embeddingJSON["model"] as? String,
            "google/gemini-embedding-2")
        XCTAssertEqual(embeddingJSON["dimensions"] as? Int, 1_536)
        let rerankerBody = try XCTUnwrap(requests.last?.httpBody)
        let rerankerJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rerankerBody) as? [String: Any])
        XCTAssertEqual(
            rerankerJSON["model"] as? String,
            "cohere/rerank-4-pro")
        XCTAssertEqual(rerankerJSON["top_n"] as? Int, 2)
    }

    func testExactKnowledgeRoutesAreSecretFreeUntilEachRealRequest() async throws {
        let resolver = CountingKnowledgeSecretResolver()
        let http = CapturingKnowledgeDataClient(responses: [
            HTTPDataResponse(
                data: Data(#"{"data":[{"index":1,"embedding":[0,1,0]},{"index":0,"embedding":[1,0,0]}],"usage":{"prompt_tokens":7,"completion_tokens":0,"total_tokens":7}}"#.utf8),
                status: 200),
            HTTPDataResponse(
                data: Data(#"{"results":[{"index":1,"relevance_score":0.9},{"index":0,"relevance_score":0.2}],"meta":{"tokens":{"input_tokens":12,"output_tokens":0},"billed_units":{"input_tokens":12,"output_tokens":0,"search_units":1}}}"#.utf8),
                status: 200),
        ])
        let embeddingEndpoint = ProviderEndpoint(
            id: "embedding-route",
            baseURL: URL(string: "https://embedding.example/v1")!,
            apiKeyRef: .environment("EMBEDDING_TEST_KEY"),
            wire: .openai,
            requestAdapter: .siliconFlowV1,
            modelRequestOptions: [
                "embed-model": [
                    "dimensions": .number(3),
                    "knowledgeDocumentInstruction": .string("document"),
                    "knowledgeQueryInstruction": .string("query"),
                ],
            ])
        let rerankerEndpoint = ProviderEndpoint(
            id: "reranker-route",
            baseURL: URL(string: "https://reranker.example/v2")!,
            apiKeyRef: .environment("RERANKER_TEST_KEY"),
            wire: .openai,
            requestAdapter: .cohereV2)
        let models = ResolvedModels(
            chat: ModelRef(endpoint: "embedding-route", model: ModelID(rawValue: "chat-unused")),
            embedding: ModelRef(endpoint: "embedding-route", model: ModelID(rawValue: "embed-model")),
            reranker: ModelRef(endpoint: "reranker-route", model: ModelID(rawValue: "rerank-model")))
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [embeddingEndpoint, rerankerEndpoint],
                models: models),
            resolver: resolver,
            dataClient: http)

        let configured = try await registry.configuredKnowledgeModels()
        let unresolvedReferences = await resolver.resolvedReferences()
        XCTAssertTrue(unresolvedReferences.isEmpty)
        XCTAssertEqual(configured.embedding.configuration.dimensions, 3)
        XCTAssertEqual(configured.embedding.configuration.requestDimensions, 3)
        XCTAssertEqual(
            configured.reranker.configuration.dialect,
            .cohereV2)
        XCTAssertNotEqual(
            configured.embedding.configuration.route.definitionDigest,
            configured.reranker.configuration.route.definitionDigest)

        let embeddingResponse = try await configured.embedding.embedWithUsage(
            ["alpha", "beta"],
            instruction: configured.embedding.configuration.documentInstruction)
        let vectors = embeddingResponse.vectors
        XCTAssertEqual(vectors, [[1, 0, 0], [0, 1, 0]])
        XCTAssertEqual(embeddingResponse.usage?.inputTokens, 7)
        XCTAssertEqual(embeddingResponse.usage?.totalTokens, 7)
        let embeddingReferences = await resolver.resolvedReferences()
        XCTAssertEqual(embeddingReferences.count, 1)

        let rerankResponse = try await configured.reranker.rerankWithUsage(
            query: "question",
            documents: ["first", "second"])
        let reranked = rerankResponse.results
        XCTAssertEqual(reranked.map(\.index), [1, 0])
        XCTAssertEqual(rerankResponse.usage?.inputTokens, 12)
        XCTAssertEqual(rerankResponse.usage?.totalTokens, 12)
        XCTAssertEqual(rerankResponse.usage?.billedInputTokens, 12)
        XCTAssertEqual(rerankResponse.usage?.billedSearchUnits, 1)
        let allReferences = await resolver.resolvedReferences()
        XCTAssertEqual(allReferences.count, 2)

        let requests = await http.requests()
        XCTAssertEqual(requests.map(\.url?.path), ["/v1/embeddings", "/v2/rerank"])
        XCTAssertTrue(requests.allSatisfy { $0.timeoutInterval == 60 })
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization")
                == "Bearer knowledge-test-secret"
        })
        let embeddingBody = try XCTUnwrap(requests.first?.httpBody)
        let embeddingJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: embeddingBody) as? [String: Any])
        XCTAssertEqual(embeddingJSON["model"] as? String, "embed-model")
        XCTAssertEqual(embeddingJSON["dimensions"] as? Int, 3)
        XCTAssertEqual(
            embeddingJSON["input"] as? [String],
            ["document\nalpha", "document\nbeta"])
        let rerankBody = try XCTUnwrap(requests.last?.httpBody)
        let rerankJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rerankBody) as? [String: Any])
        XCTAssertEqual(rerankJSON["query"] as? String, "question")
        XCTAssertEqual(rerankJSON["documents"] as? [String], ["first", "second"])
        XCTAssertEqual(rerankJSON["top_n"] as? Int, 2)
    }

    func testReviewedDefaultDimensionIsValidatedButOmittedFromWireRequest()
        async throws {
        let resolver = CountingKnowledgeSecretResolver()
        var vector = [Double](repeating: 0, count: 1_024)
        vector[0] = 1
        let response = try JSONSerialization.data(withJSONObject: [
            "data": [["index": 0, "embedding": vector]],
            "usage": ["prompt_tokens": 2, "total_tokens": 2],
        ])
        let http = CapturingKnowledgeDataClient(responses: [
            HTTPDataResponse(data: response, status: 200),
        ])
        let endpoint = ProviderEndpoint(
            id: "siliconflow-embedding",
            baseURL: URL(string: "https://embedding.example/v1")!,
            apiKeyRef: .environment("EMBEDDING_TEST_KEY"),
            wire: .openai,
            requestAdapter: .siliconFlowV1)
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(
                    chat: ModelRef(
                        endpoint: endpoint.id,
                        model: ModelID(rawValue: "chat")))),
            resolver: resolver,
            dataClient: http)
        let model = try await registry.embeddingModel(for: ModelRef(
            endpoint: endpoint.id,
            model: ModelID(rawValue: "BAAI/bge-m3")))

        XCTAssertEqual(model.configuration.dimensions, 1_024)
        XCTAssertNil(model.configuration.requestDimensions)
        let output = try await model.embedWithUsage(
            ["document"],
            instruction: "")
        XCTAssertEqual(output.vectors.first?.count, 1_024)
        XCTAssertEqual(output.usage?.inputTokens, 2)
        let requests = await http.requests()
        let request = try XCTUnwrap(requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["dimensions"])
    }

    func testInvalidOrConflictingKnowledgeDimensionsFailBeforeSecretAndNetwork()
        async throws {
        let resolver = CountingKnowledgeSecretResolver()
        let http = CapturingKnowledgeDataClient(responses: [])
        func endpoint(options: [String: JSONValue]) -> ProviderEndpoint {
            ProviderEndpoint(
                id: "embedding",
                baseURL: URL(string: "https://embedding.example/v1")!,
                apiKeyRef: .environment("EMBEDDING_TEST_KEY"),
                wire: .openai,
                requestAdapter: .siliconFlowV1,
                modelRequestOptions: ["BAAI/bge-m3": options])
        }
        for options in [
            ["dimensions": JSONValue.number(-1)],
            [
                "dimensions": JSONValue.number(512),
                "knowledgeEmbeddingDimensions": JSONValue.number(1_024),
            ],
        ] {
            let route = endpoint(options: options)
            let registry = ProviderRegistry(
                config: ProviderConfig(
                    endpoints: [route],
                    models: ResolvedModels(
                        chat: ModelRef(
                            endpoint: route.id,
                            model: ModelID(rawValue: "chat")))),
                resolver: resolver,
                dataClient: http)
            do {
                _ = try await registry.embeddingModel(for: ModelRef(
                    endpoint: route.id,
                    model: ModelID(rawValue: "BAAI/bge-m3")))
                XCTFail("invalid Knowledge dimensions unexpectedly resolved")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("dimensions"))
            }
        }
        let references = await resolver.resolvedReferences()
        let requests = await http.requests()
        XCTAssertTrue(references.isEmpty)
        XCTAssertTrue(requests.isEmpty)
    }

    func testInvalidKnowledgeCompatibilityOptionsFailBeforeSecretAndNetwork()
        async throws {
        let resolver = CountingKnowledgeSecretResolver()
        let http = CapturingKnowledgeDataClient(responses: [])

        let invalidEmbeddingOptions: [(String, JSONValue)] = [
            ("knowledgeEmbeddingMaxInputCharacters", .string("8192")),
            ("knowledgeDocumentInstruction", .string(String(
                repeating: "x",
                count: 2_049))),
            ("knowledgeQueryInstruction", .number(1)),
        ]
        for (name, value) in invalidEmbeddingOptions {
            let endpoint = ProviderEndpoint(
                id: "embedding-\(name)",
                baseURL: URL(string: "https://embedding.example/v1")!,
                apiKeyRef: .environment("EMBEDDING_TEST_KEY"),
                wire: .openai,
                requestAdapter: .siliconFlowV1,
                modelRequestOptions: [
                    "BAAI/bge-m3": [name: value],
                ])
            let registry = ProviderRegistry(
                config: ProviderConfig(
                    endpoints: [endpoint],
                    models: ResolvedModels(
                        chat: ModelRef(
                            endpoint: endpoint.id,
                            model: ModelID(rawValue: "chat")))),
                resolver: resolver,
                dataClient: http)
            do {
                _ = try await registry.embeddingModel(for: ModelRef(
                    endpoint: endpoint.id,
                    model: ModelID(rawValue: "BAAI/bge-m3")))
                XCTFail("invalid \(name) unexpectedly resolved")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(name))
            }
        }

        let invalidRerankerOptions: [(String, JSONValue)] = [
            ("knowledgeRerankerMaxInputCharacters", .number(0)),
            ("knowledgeRerankerMaxCandidates", .number(1_001)),
        ]
        for (name, value) in invalidRerankerOptions {
            let endpoint = ProviderEndpoint(
                id: "reranker-\(name)",
                baseURL: URL(string: "https://reranker.example/v2")!,
                apiKeyRef: .environment("RERANKER_TEST_KEY"),
                wire: .openai,
                requestAdapter: .cohereV2,
                modelRequestOptions: [
                    "rerank-model": [name: value],
                ])
            let registry = ProviderRegistry(
                config: ProviderConfig(
                    endpoints: [endpoint],
                    models: ResolvedModels(
                        chat: ModelRef(
                            endpoint: endpoint.id,
                            model: ModelID(rawValue: "chat")))),
                resolver: resolver,
                dataClient: http)
            do {
                _ = try await registry.rerankerModel(for: ModelRef(
                    endpoint: endpoint.id,
                    model: ModelID(rawValue: "rerank-model")))
                XCTFail("invalid \(name) unexpectedly resolved")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(name))
            }
        }

        let references = await resolver.resolvedReferences()
        let requests = await http.requests()
        XCTAssertTrue(references.isEmpty)
        XCTAssertTrue(requests.isEmpty)
    }

    func testMissingRoleAndUnknownRerankerDialectFailBeforeSecretOrNetwork() async throws {
        let resolver = CountingKnowledgeSecretResolver()
        let http = CapturingKnowledgeDataClient(responses: [])
        let endpoint = ProviderEndpoint(
            id: "compatible",
            baseURL: URL(string: "https://provider.example/v1")!,
            apiKeyRef: .environment("KNOWLEDGE_TEST_KEY"),
            wire: .openai,
            requestAdapter: .openAICompatible,
            modelRequestOptions: ["embed": ["dimensions": .number(3)]])
        let missingConfig = ProviderConfig(
            endpoints: [endpoint],
            models: ResolvedModels(
                chat: ModelRef(endpoint: "compatible", model: ModelID(rawValue: "chat")),
                embedding: ModelRef(endpoint: "compatible", model: ModelID(rawValue: "embed"))))
        let missing = ProviderRegistry(
            config: missingConfig,
            resolver: resolver,
            dataClient: http)

        XCTAssertThrowsError(try ProviderRegistry
            .validateKnowledgeConfiguration(missingConfig)) { error in
            XCTAssertTrue(error.localizedDescription.contains(
                "embedding_model and reranker_model"))
        }
        do {
            _ = try await missing.configuredKnowledgeModels()
            XCTFail("missing reranker_model must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("embedding_model and reranker_model"))
        }

        let unsupportedConfig = ProviderConfig(
            endpoints: [endpoint],
            models: ResolvedModels(
                chat: ModelRef(endpoint: "compatible", model: ModelID(rawValue: "chat")),
                embedding: ModelRef(endpoint: "compatible", model: ModelID(rawValue: "embed")),
                reranker: ModelRef(endpoint: "compatible", model: ModelID(rawValue: "rerank"))))
        let unsupported = ProviderRegistry(
            config: unsupportedConfig,
            resolver: resolver,
            dataClient: http)
        XCTAssertThrowsError(try ProviderRegistry
            .validateKnowledgeConfiguration(unsupportedConfig)) { error in
            XCTAssertTrue(error.localizedDescription.contains("explicit"))
        }
        do {
            _ = try await unsupported.configuredKnowledgeModels()
            XCTFail("an arbitrary compatible route must not become a reranker")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("explicit"))
        }
        let resolvedReferences = await resolver.resolvedReferences()
        let requests = await http.requests()
        XCTAssertTrue(resolvedReferences.isEmpty)
        XCTAssertTrue(requests.isEmpty)
    }

    func testRerankerRejectsPartialOrDuplicateCandidatePermutation() async throws {
        let resolver = CountingKnowledgeSecretResolver()
        let http = CapturingKnowledgeDataClient(responses: [
            HTTPDataResponse(
                data: Data(#"{"results":[{"index":0,"relevance_score":0.8},{"index":0,"relevance_score":0.7}]}"#.utf8),
                status: 200),
        ])
        let rerankerEndpoint = ProviderEndpoint(
            id: "reranker",
            baseURL: URL(string: "https://reranker.example/v1")!,
            apiKeyRef: .environment("RERANKER_TEST_KEY"),
            wire: .openai,
            requestAdapter: .siliconFlowV1)
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [rerankerEndpoint],
                models: ResolvedModels(
                    chat: ModelRef(endpoint: "reranker", model: ModelID(rawValue: "chat")),
                    reranker: ModelRef(endpoint: "reranker", model: ModelID(rawValue: "rerank")))),
            resolver: resolver,
            dataClient: http)
        let model = try await registry.rerankerModel(
            for: ModelRef(endpoint: "reranker", model: ModelID(rawValue: "rerank")))

        do {
            _ = try await model.rerank(
                query: "q",
                documents: ["a", "b"])
            XCTFail("duplicate candidate indexes must fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalid candidate"))
        }
    }

    func testCredentialFailureStopsBothKnowledgeRoutesBeforeHTTPDispatch()
        async throws {
        let resolver = FailingKnowledgeSecretResolver()
        let http = CapturingKnowledgeDataClient(responses: [])
        let embeddingEndpoint = ProviderEndpoint(
            id: "embedding",
            baseURL: URL(string: "https://embedding.example/v1")!,
            apiKeyRef: .environment("EMBEDDING_TEST_KEY"),
            wire: .openai,
            requestAdapter: .openAICompatible,
            modelRequestOptions: ["embed": ["dimensions": .number(3)]])
        let rerankerEndpoint = ProviderEndpoint(
            id: "reranker",
            baseURL: URL(string: "https://reranker.example/v1")!,
            apiKeyRef: .environment("RERANKER_TEST_KEY"),
            wire: .openai,
            requestAdapter: .siliconFlowV1)
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [embeddingEndpoint, rerankerEndpoint],
                models: ResolvedModels(
                    chat: ModelRef(
                        endpoint: "embedding",
                        model: ModelID(rawValue: "chat")))),
            resolver: resolver,
            dataClient: http)
        let embedding = try await registry.embeddingModel(
            for: ModelRef(
                endpoint: "embedding",
                model: ModelID(rawValue: "embed")))
        let reranker = try await registry.rerankerModel(
            for: ModelRef(
                endpoint: "reranker",
                model: ModelID(rawValue: "rerank")))

        do {
            _ = try await embedding.embed(["document"], instruction: "")
            XCTFail("embedding request unexpectedly bypassed credential failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("credential unavailable"))
        }
        do {
            _ = try await reranker.rerank(
                query: "query",
                documents: ["candidate"])
            XCTFail("reranker request unexpectedly bypassed credential failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("credential unavailable"))
        }

        let references = await resolver.resolvedReferences()
        let requests = await http.requests()
        XCTAssertEqual(references.count, 2)
        XCTAssertTrue(requests.isEmpty)
    }

    func testEmbeddingRejectsMalformedVectorBatchAndRedirectStatus()
        async throws {
        let resolver = CountingKnowledgeSecretResolver()
        let http = CapturingKnowledgeDataClient(responses: [
            HTTPDataResponse(
                data: Data(#"{"data":[{"index":0,"embedding":[1,0,0]},{"index":1,"embedding":[0,1]}]}"#.utf8),
                status: 200),
            HTTPDataResponse(
                data: Data(),
                status: 302,
                headers: ["location": "https://unreviewed.example/collect"]),
        ])
        let endpoint = ProviderEndpoint(
            id: "embedding",
            baseURL: URL(string: "https://embedding.example/v1")!,
            apiKeyRef: .environment("EMBEDDING_TEST_KEY"),
            wire: .openai,
            requestAdapter: .openAICompatible,
            modelRequestOptions: ["embed": ["dimensions": .number(3)]])
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(
                    chat: ModelRef(
                        endpoint: "embedding",
                        model: ModelID(rawValue: "chat")))),
            resolver: resolver,
            dataClient: http)
        let embedding = try await registry.embeddingModel(
            for: ModelRef(
                endpoint: "embedding",
                model: ModelID(rawValue: "embed")))

        do {
            _ = try await embedding.embed(["a", "b"], instruction: "")
            XCTFail("malformed embedding dimensions unexpectedly succeeded")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("malformed vectors"))
        }
        do {
            _ = try await embedding.embed(["a"], instruction: "")
            XCTFail("redirect response unexpectedly became a provider success")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unsuccessful"))
        }
        let requests = await http.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.timeoutInterval == 60 })
    }

    func testEmbeddingAndRerankerCancellationReachTheirExactTransports()
        async throws {
        let resolver = CountingKnowledgeSecretResolver()
        let embeddingHTTP = BlockingKnowledgeDataClient()
        let embeddingEndpoint = ProviderEndpoint(
            id: "embedding",
            baseURL: URL(string: "https://embedding.example/v1")!,
            apiKeyRef: .environment("EMBEDDING_TEST_KEY"),
            wire: .openai,
            requestAdapter: .openAICompatible,
            modelRequestOptions: ["embed": ["dimensions": .number(3)]])
        let embeddingRegistry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [embeddingEndpoint],
                models: ResolvedModels(
                    chat: ModelRef(
                        endpoint: "embedding",
                        model: ModelID(rawValue: "chat")))),
            resolver: resolver,
            dataClient: embeddingHTTP)
        let embedding = try await embeddingRegistry.embeddingModel(
            for: ModelRef(
                endpoint: "embedding",
                model: ModelID(rawValue: "embed")))
        let embeddingTask = Task {
            try await embedding.embed(["document"], instruction: "")
        }
        for _ in 0..<10_000 {
            if (await embeddingHTTP.counts()).started == 1 { break }
            await Task.yield()
        }
        let embeddingStarted = (await embeddingHTTP.counts()).started
        XCTAssertEqual(embeddingStarted, 1)
        embeddingTask.cancel()
        do {
            _ = try await embeddingTask.value
            XCTFail("cancelled embedding request unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
        let embeddingCancelled = (await embeddingHTTP.counts()).cancelled
        XCTAssertEqual(embeddingCancelled, 1)

        let rerankerHTTP = BlockingKnowledgeDataClient()
        let rerankerEndpoint = ProviderEndpoint(
            id: "reranker",
            baseURL: URL(string: "https://reranker.example/v1")!,
            apiKeyRef: .environment("RERANKER_TEST_KEY"),
            wire: .openai,
            requestAdapter: .cohereV2)
        let rerankerRegistry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [rerankerEndpoint],
                models: ResolvedModels(
                    chat: ModelRef(
                        endpoint: "reranker",
                        model: ModelID(rawValue: "chat")))),
            resolver: resolver,
            dataClient: rerankerHTTP)
        let reranker = try await rerankerRegistry.rerankerModel(
            for: ModelRef(
                endpoint: "reranker",
                model: ModelID(rawValue: "rerank")))
        let rerankerTask = Task {
            try await reranker.rerank(
                query: "query",
                documents: ["candidate"])
        }
        for _ in 0..<10_000 {
            if (await rerankerHTTP.counts()).started == 1 { break }
            await Task.yield()
        }
        let rerankerStarted = (await rerankerHTTP.counts()).started
        XCTAssertEqual(rerankerStarted, 1)
        rerankerTask.cancel()
        do {
            _ = try await rerankerTask.value
            XCTFail("cancelled reranker request unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
        let rerankerCancelled = (await rerankerHTTP.counts()).cancelled
        XCTAssertEqual(rerankerCancelled, 1)
    }

    func testRouteIdentityFreezesEveryCompatibilityDefault() async throws {
        let resolver = CountingKnowledgeSecretResolver()
        let http = CapturingKnowledgeDataClient(responses: [])
        func endpoint(maximumInput: Int) -> ProviderEndpoint {
            ProviderEndpoint(
                id: "embedding",
                baseURL: URL(string: "https://embedding.example/v1")!,
                apiKeyRef: .environment("EMBEDDING_TEST_KEY"),
                wire: .openai,
                requestAdapter: .openAICompatible,
                modelRequestOptions: [
                    "embed": [
                        "dimensions": .number(3),
                        "knowledgeEmbeddingMaxInputCharacters":
                            .number(Double(maximumInput)),
                    ],
                ])
        }
        let first = try await ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint(maximumInput: 8_192)],
                models: ResolvedModels(
                    chat: ModelRef(
                        endpoint: "embedding",
                        model: ModelID(rawValue: "chat")))),
            resolver: resolver,
            dataClient: http).embeddingModel(
                for: ModelRef(
                    endpoint: "embedding",
                    model: ModelID(rawValue: "embed")))
        let second = try await ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint(maximumInput: 4_096)],
                models: ResolvedModels(
                    chat: ModelRef(
                        endpoint: "embedding",
                        model: ModelID(rawValue: "chat")))),
            resolver: resolver,
            dataClient: http).embeddingModel(
                for: ModelRef(
                    endpoint: "embedding",
                    model: ModelID(rawValue: "embed")))

        XCTAssertEqual(first.configuration.normalization, "l2")
        XCTAssertEqual(first.configuration.similarity, "cosine")
        XCTAssertEqual(
            first.configuration.tokenizerRevision,
            "intatis-unicode-character-prefix/1")
        XCTAssertEqual(first.configuration.truncation, "end")
        XCTAssertNotEqual(
            first.configuration.route.definitionDigest,
            second.configuration.route.definitionDigest)
        let references = await resolver.resolvedReferences()
        let requests = await http.requests()
        XCTAssertTrue(references.isEmpty)
        XCTAssertTrue(requests.isEmpty)
    }
}
