import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisProviders requires CryptoKit or swift-crypto")
#endif
import IntatisCore
import IntatisProtocol

public enum ProviderEmbeddingDialect: String, Codable, Sendable {
    case openAICompatibleV1 = "openai-compatible-embeddings-v1"
    case openRouterV1 = "openrouter-embeddings-v1"
}

public enum ProviderRerankerDialect: String, Codable, Sendable {
    case siliconFlowV1 = "siliconflow-rerank-v1"
    case cohereV2 = "cohere-rerank-v2"
    case openRouterV1 = "openrouter-rerank-v1"
}

/// Complete non-secret identity of one prepared role route. The definition
/// digest commits the URL, adapter, credential reference, request options and
/// role configuration without persisting those raw values in a knowledge
/// snapshot or exposing them to the model.
public struct ProviderKnowledgeRouteIdentity: Codable, Equatable, Hashable, Sendable {
    public let providerID: String
    public let modelID: ModelID
    public let definitionRevision: String
    public let adapterIdentity: String
    public let trustDomain: String
    public let egressClassification: String
    public let credentialReferenceDigest: String
    public let definitionDigest: String

    public init(providerID: String,
                modelID: ModelID,
                definitionRevision: String,
                adapterIdentity: String,
                trustDomain: String,
                egressClassification: String,
                credentialReferenceDigest: String,
                definitionDigest: String) {
        self.providerID = providerID
        self.modelID = modelID
        self.definitionRevision = definitionRevision
        self.adapterIdentity = adapterIdentity
        self.trustDomain = trustDomain
        self.egressClassification = egressClassification
        self.credentialReferenceDigest = credentialReferenceDigest
        self.definitionDigest = definitionDigest
    }
}

public struct ProviderEmbeddingConfiguration: Codable, Equatable, Sendable {
    public let route: ProviderKnowledgeRouteIdentity
    public let dialect: ProviderEmbeddingDialect
    public let dimensions: Int
    /// Optional wire-level dimensions override. `dimensions` remains the exact
    /// expected output width even when a provider/model requires this request
    /// member to be omitted.
    public let requestDimensions: Int?
    public let normalization: String
    public let similarity: String
    public let documentInstruction: String
    public let queryInstruction: String
    public let tokenizerRevision: String
    public let maximumInputCharacters: Int
    public let truncation: String

    public init(route: ProviderKnowledgeRouteIdentity,
                dialect: ProviderEmbeddingDialect,
                dimensions: Int,
                requestDimensions: Int? = nil,
                normalization: String = "l2",
                similarity: String = "cosine",
                documentInstruction: String = "",
                queryInstruction: String = "",
                tokenizerRevision: String = IntatisHostApplication.identity
                    .fileNameStem + "-unicode-character-prefix/1",
                maximumInputCharacters: Int = 8_192,
                truncation: String = "end") {
        self.route = route
        self.dialect = dialect
        self.dimensions = dimensions
        self.requestDimensions = requestDimensions
        self.normalization = normalization
        self.similarity = similarity
        self.documentInstruction = documentInstruction
        self.queryInstruction = queryInstruction
        self.tokenizerRevision = tokenizerRevision
        self.maximumInputCharacters = maximumInputCharacters
        self.truncation = truncation
    }
}

public struct ProviderRerankerConfiguration: Codable, Equatable, Sendable {
    public let route: ProviderKnowledgeRouteIdentity
    public let dialect: ProviderRerankerDialect
    public let tokenizerRevision: String
    public let maximumInputCharacters: Int
    public let maximumCandidates: Int
    public let templateRevision: String
    public let truncation: String
    public let scoreSemantics: String

    public init(route: ProviderKnowledgeRouteIdentity,
                dialect: ProviderRerankerDialect,
                tokenizerRevision: String = "provider-defined",
                maximumInputCharacters: Int = 8_192,
                maximumCandidates: Int = 64,
                templateRevision: String,
                truncation: String = "end",
                scoreSemantics: String = "relevance_score_descending") {
        self.route = route
        self.dialect = dialect
        self.tokenizerRevision = tokenizerRevision
        self.maximumInputCharacters = maximumInputCharacters
        self.maximumCandidates = maximumCandidates
        self.templateRevision = templateRevision
        self.truncation = truncation
        self.scoreSemantics = scoreSemantics
    }
}

public struct ProviderRerankResult: Equatable, Sendable {
    public let index: Int
    public let score: Double

    public init(index: Int, score: Double) {
        self.index = index
        self.score = score
    }
}

/// Safe, provider-reported Knowledge model usage. Monetary cost is deliberately
/// not inferred here because prices are mutable provider-side policy. The live
/// acceptance harness records these raw token and billable-unit counters next
/// to the exact route identity instead.
public struct ProviderKnowledgeUsage: Equatable, Sendable {
    public let inputTokens: Double?
    public let outputTokens: Double?
    public let totalTokens: Double?
    public let billedInputTokens: Double?
    public let billedOutputTokens: Double?
    public let billedSearchUnits: Double?

    public init(inputTokens: Double? = nil,
                outputTokens: Double? = nil,
                totalTokens: Double? = nil,
                billedInputTokens: Double? = nil,
                billedOutputTokens: Double? = nil,
                billedSearchUnits: Double? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.billedInputTokens = billedInputTokens
        self.billedOutputTokens = billedOutputTokens
        self.billedSearchUnits = billedSearchUnits
    }

    public func adding(_ other: ProviderKnowledgeUsage?)
        -> ProviderKnowledgeUsage {
        guard let other else { return self }
        return ProviderKnowledgeUsage(
            inputTokens: Self.sum(inputTokens, other.inputTokens),
            outputTokens: Self.sum(outputTokens, other.outputTokens),
            totalTokens: Self.sum(totalTokens, other.totalTokens),
            billedInputTokens: Self.sum(
                billedInputTokens,
                other.billedInputTokens),
            billedOutputTokens: Self.sum(
                billedOutputTokens,
                other.billedOutputTokens),
            billedSearchUnits: Self.sum(
                billedSearchUnits,
                other.billedSearchUnits))
    }

    private static func sum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case (.none, .none): nil
        case (.some(let value), .none), (.none, .some(let value)): value
        case (.some(let lhs), .some(let rhs)): lhs + rhs
        }
    }
}

public struct ProviderEmbeddingResponse: Equatable, Sendable {
    public let vectors: [[Double]]
    public let usage: ProviderKnowledgeUsage?

    public init(vectors: [[Double]], usage: ProviderKnowledgeUsage?) {
        self.vectors = vectors
        self.usage = usage
    }
}

public struct ProviderRerankResponse: Equatable, Sendable {
    public let results: [ProviderRerankResult]
    public let usage: ProviderKnowledgeUsage?

    public init(results: [ProviderRerankResult],
                usage: ProviderKnowledgeUsage?) {
        self.results = results
        self.usage = usage
    }
}

public protocol ProviderEmbeddingModel: Sendable {
    var configuration: ProviderEmbeddingConfiguration { get }
    func embed(_ texts: [String], instruction: String) async throws -> [[Double]]
    func embedWithUsage(_ texts: [String], instruction: String) async throws
        -> ProviderEmbeddingResponse
}

public protocol ProviderRerankerModel: Sendable {
    var configuration: ProviderRerankerConfiguration { get }
    func rerank(query: String, documents: [String]) async throws -> [ProviderRerankResult]
    func rerankWithUsage(query: String, documents: [String]) async throws
        -> ProviderRerankResponse
}

public extension ProviderEmbeddingModel {
    func embedWithUsage(_ texts: [String], instruction: String) async throws
        -> ProviderEmbeddingResponse {
        ProviderEmbeddingResponse(
            vectors: try await embed(texts, instruction: instruction),
            usage: nil)
    }
}

public extension ProviderRerankerModel {
    func rerankWithUsage(query: String, documents: [String]) async throws
        -> ProviderRerankResponse {
        ProviderRerankResponse(
            results: try await rerank(query: query, documents: documents),
            usage: nil)
    }
}

struct OpenAICompatibleEmbeddingModel: ProviderEmbeddingModel {
    let endpoint: ProviderEndpoint
    let resolver: any SecretResolver
    let apiKeyRef: KeychainRef
    let model: ModelID
    let http: HTTPDataClient
    let configuration: ProviderEmbeddingConfiguration

    func embed(_ texts: [String], instruction: String) async throws -> [[Double]] {
        try await embedWithUsage(texts, instruction: instruction).vectors
    }

    func embedWithUsage(_ texts: [String], instruction: String) async throws
        -> ProviderEmbeddingResponse {
        guard !texts.isEmpty, texts.count <= 256 else {
            throw IntatisError.provider(
                "embedding request batch is empty or exceeds the 256-input limit")
        }
        let bounded = texts.map {
            let instructed = instruction.isEmpty ? $0 : instruction + "\n" + $0
            return Self.bounded(
                instructed,
                maximum: configuration.maximumInputCharacters)
        }
        guard bounded.allSatisfy({ !$0.isEmpty }) else {
            throw IntatisError.provider("embedding input is empty")
        }
        // Resolve credentials at the real network boundary. Merely composing
        // or advertising the Knowledge tool surface must never read a secret.
        let apiKey = try await resolver.secret(for: apiKeyRef)
        let body = EmbeddingRequest(
            model: model.rawValue,
            input: bounded,
            encodingFormat: "float",
            dimensions: configuration.requestDimensions)
        var request = URLRequest(url: try endpoint.validatedBaseURLAppendingPathComponent(
            "embeddings",
            operation: "knowledge embedding"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        let response = try await http.sendResponse(request)
        guard (200..<300).contains(response.status),
              response.data.count <= 128 * 1_024 * 1_024 else {
            throw IntatisError.provider(
                "embedding provider returned an unsuccessful or oversized response")
        }
        let decoded = try JSONDecoder().decode(
            EmbeddingResponse.self,
            from: response.data)
        guard decoded.data.count == bounded.count else {
            throw IntatisError.provider(
                "embedding provider returned an incomplete batch")
        }
        var byIndex: [Int: [Double]] = [:]
        for item in decoded.data {
            guard item.index >= 0,
                  item.index < bounded.count,
                  byIndex[item.index] == nil,
                  item.embedding.count == configuration.dimensions,
                  item.embedding.allSatisfy(\.isFinite) else {
                throw IntatisError.provider(
                    "embedding provider returned malformed vectors")
            }
            byIndex[item.index] = item.embedding
        }
        guard byIndex.count == bounded.count else {
            throw IntatisError.provider(
                "embedding provider returned duplicate or missing indexes")
        }
        let vectors = try bounded.indices.map { index in
            guard let vector = byIndex[index] else {
                throw IntatisError.provider(
                    "embedding provider omitted a vector")
            }
            return vector
        }
        return ProviderEmbeddingResponse(
            vectors: vectors,
            usage: try Self.validatedUsage(decoded.usage))
    }

    private static func bounded(_ text: String, maximum: Int) -> String {
        text.count <= maximum ? text : String(text.prefix(maximum))
    }

    private struct EmbeddingRequest: Encodable {
        let model: String
        let input: [String]
        let encodingFormat: String
        let dimensions: Int?

        enum CodingKeys: String, CodingKey {
            case model, input, dimensions
            case encodingFormat = "encoding_format"
        }
    }

    private struct EmbeddingResponse: Decodable {
        struct Item: Decodable {
            let embedding: [Double]
            let index: Int
        }
        let data: [Item]
        let usage: Usage?

        struct Usage: Decodable {
            let promptTokens: Double?
            let completionTokens: Double?
            let totalTokens: Double?

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case totalTokens = "total_tokens"
            }
        }
    }

    private static func validatedUsage(_ usage: EmbeddingResponse.Usage?) throws
        -> ProviderKnowledgeUsage? {
        guard let usage else { return nil }
        let values = [
            usage.promptTokens,
            usage.completionTokens,
            usage.totalTokens,
        ].compactMap { $0 }
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw IntatisError.provider(
                "embedding provider returned malformed usage")
        }
        guard !values.isEmpty else { return nil }
        return ProviderKnowledgeUsage(
            inputTokens: usage.promptTokens,
            outputTokens: usage.completionTokens,
            totalTokens: usage.totalTokens)
    }
}

struct DedicatedRerankerModel: ProviderRerankerModel {
    let endpoint: ProviderEndpoint
    let resolver: any SecretResolver
    let apiKeyRef: KeychainRef
    let model: ModelID
    let http: HTTPDataClient
    let configuration: ProviderRerankerConfiguration

    func rerank(query: String, documents: [String]) async throws -> [ProviderRerankResult] {
        try await rerankWithUsage(query: query, documents: documents).results
    }

    func rerankWithUsage(query: String, documents: [String]) async throws
        -> ProviderRerankResponse {
        guard !query.isEmpty,
              !documents.isEmpty,
              documents.count <= configuration.maximumCandidates else {
            throw IntatisError.provider(
                "rerank request is empty or exceeds the configured candidate limit")
        }
        let boundedDocuments = documents.map {
            Self.bounded($0, maximum: configuration.maximumInputCharacters)
        }
        // The reranker has its own exact credential reference and resolves it
        // only when semantic reranking is actually dispatched.
        let apiKey = try await resolver.secret(for: apiKeyRef)
        let body = RerankRequest(
            model: model.rawValue,
            query: Self.bounded(
                query,
                maximum: configuration.maximumInputCharacters),
            documents: boundedDocuments,
            topN: boundedDocuments.count)
        var request = URLRequest(url: try endpoint.validatedBaseURLAppendingPathComponent(
            "rerank",
            operation: "knowledge rerank"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        let response = try await http.sendResponse(request)
        guard (200..<300).contains(response.status),
              response.data.count <= 16 * 1_024 * 1_024 else {
            throw IntatisError.provider(
                "reranker provider returned an unsuccessful or oversized response")
        }
        let decoded = try JSONDecoder().decode(
            RerankResponse.self,
            from: response.data)
        guard decoded.results.count == boundedDocuments.count else {
            throw IntatisError.provider(
                "reranker provider returned an incomplete candidate permutation")
        }
        var seen = Set<Int>()
        let results = try decoded.results.map { item -> ProviderRerankResult in
            guard item.index >= 0,
                  item.index < boundedDocuments.count,
                  item.relevanceScore.isFinite,
                  seen.insert(item.index).inserted else {
                throw IntatisError.provider(
                    "reranker provider returned invalid candidate indexes or scores")
            }
            return ProviderRerankResult(
                index: item.index,
                score: item.relevanceScore)
        }
        guard seen.count == boundedDocuments.count else {
            throw IntatisError.provider("reranker provider omitted a candidate")
        }
        let sorted = results.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.index < $1.index
        }
        return ProviderRerankResponse(
            results: sorted,
            usage: try Self.validatedUsage(
                decoded,
                dialect: configuration.dialect))
    }

    private static func bounded(_ text: String, maximum: Int) -> String {
        text.count <= maximum ? text : String(text.prefix(maximum))
    }

    private struct RerankRequest: Encodable {
        let model: String
        let query: String
        let documents: [String]
        let topN: Int

        enum CodingKeys: String, CodingKey {
            case model, query, documents
            case topN = "top_n"
        }
    }

    private struct RerankResponse: Decodable {
        struct Item: Decodable {
            let index: Int
            let relevanceScore: Double

            enum CodingKeys: String, CodingKey {
                case index
                case relevanceScore = "relevance_score"
            }
        }
        let results: [Item]
        let meta: Meta?
        let usage: Usage?

        struct Meta: Decodable {
            let tokens: Units?
            let billedUnits: Units?

            enum CodingKeys: String, CodingKey {
                case tokens
                case billedUnits = "billed_units"
            }
        }

        struct Units: Decodable {
            let inputTokens: Double?
            let outputTokens: Double?
            let searchUnits: Double?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case searchUnits = "search_units"
            }
        }

        /// OpenRouter reports rerank accounting at the top level instead of
        /// Cohere's `meta` object. Keep this dialect-specific so a coincidental
        /// response shape from an unreviewed compatible endpoint cannot be
        /// treated as a supported route.
        struct Usage: Decodable {
            let promptTokens: Double?
            let inputTokens: Double?
            let totalTokens: Double?
            let searchUnits: Double?

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case inputTokens = "input_tokens"
                case totalTokens = "total_tokens"
                case searchUnits = "search_units"
            }
        }
    }

    private static func validatedUsage(
        _ response: RerankResponse,
        dialect: ProviderRerankerDialect
    ) throws
        -> ProviderKnowledgeUsage? {
        if dialect == .openRouterV1 {
            return try validatedOpenRouterUsage(response.usage)
        }
        return try validatedCohereUsage(response.meta)
    }

    private static func validatedCohereUsage(_ meta: RerankResponse.Meta?) throws
        -> ProviderKnowledgeUsage? {
        guard let meta else { return nil }
        let values = [
            meta.tokens?.inputTokens,
            meta.tokens?.outputTokens,
            meta.billedUnits?.inputTokens,
            meta.billedUnits?.outputTokens,
            meta.billedUnits?.searchUnits,
        ].compactMap { $0 }
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw IntatisError.provider(
                "reranker provider returned malformed usage")
        }
        guard !values.isEmpty else { return nil }
        let totalTokens: Double?
        if let input = meta.tokens?.inputTokens,
           let output = meta.tokens?.outputTokens {
            totalTokens = input + output
        } else {
            totalTokens = nil
        }
        return ProviderKnowledgeUsage(
            inputTokens: meta.tokens?.inputTokens,
            outputTokens: meta.tokens?.outputTokens,
            totalTokens: totalTokens,
            billedInputTokens: meta.billedUnits?.inputTokens,
            billedOutputTokens: meta.billedUnits?.outputTokens,
            billedSearchUnits: meta.billedUnits?.searchUnits)
    }

    private static func validatedOpenRouterUsage(
        _ usage: RerankResponse.Usage?
    ) throws -> ProviderKnowledgeUsage? {
        guard let usage else { return nil }
        let values = [
            usage.promptTokens,
            usage.inputTokens,
            usage.totalTokens,
            usage.searchUnits,
        ].compactMap { $0 }
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw IntatisError.provider(
                "reranker provider returned malformed usage")
        }
        guard !values.isEmpty else { return nil }
        return ProviderKnowledgeUsage(
            inputTokens: usage.inputTokens ?? usage.promptTokens,
            totalTokens: usage.totalTokens,
            billedSearchUnits: usage.searchUnits)
    }
}

extension ProviderRegistry {
    /// Validates the complete Knowledge route plan without resolving a secret,
    /// touching the network, or acquiring filesystem authority. Product hosts
    /// use this before advertising the tools or reporting `knowledge ready`;
    /// the actual provider constructors reuse the same configuration builders.
    public static func validateKnowledgeConfiguration(
        _ config: ProviderConfig
    ) throws {
        guard let embeddingRef = config.models.embedding,
              let rerankerRef = config.models.reranker else {
            throw IntatisError.config(
                "Knowledge tools unavailable: configure embedding_model and reranker_model.")
        }
        guard let embeddingEndpoint = config.endpoint(
            id: embeddingRef.endpoint) else {
            throw IntatisError.config(
                "unknown embedding endpoint '\(embeddingRef.endpoint)'")
        }
        guard let rerankerEndpoint = config.endpoint(
            id: rerankerRef.endpoint) else {
            throw IntatisError.config(
                "unknown reranker endpoint '\(rerankerRef.endpoint)'")
        }
        _ = try embeddingConfiguration(
            endpoint: embeddingEndpoint,
            ref: embeddingRef)
        _ = try rerankerConfiguration(
            endpoint: rerankerEndpoint,
            ref: rerankerRef)
    }

    public func configuredKnowledgeModels() async throws -> (
        embedding: any ProviderEmbeddingModel,
        reranker: any ProviderRerankerModel
    ) {
        guard let embeddingRef = config.models.embedding,
              let rerankerRef = config.models.reranker else {
            throw IntatisError.config(
                "Knowledge tools unavailable: configure embedding_model and reranker_model.")
        }
        return (
            try await embeddingModel(for: embeddingRef),
            try await rerankerModel(for: rerankerRef))
    }

    public func embeddingModel(for ref: ModelRef) async throws
        -> any ProviderEmbeddingModel {
        guard let endpoint = config.endpoint(id: ref.endpoint) else {
            throw IntatisError.config(
                "unknown embedding endpoint '\(ref.endpoint)'")
        }
        let configuration = try Self.embeddingConfiguration(
            endpoint: endpoint,
            ref: ref)
        return OpenAICompatibleEmbeddingModel(
            endpoint: endpoint,
            resolver: resolver,
            apiKeyRef: endpoint.apiKeyRef,
            model: ref.model,
            http: dataClient,
            configuration: configuration)
    }

    public func rerankerModel(for ref: ModelRef) async throws
        -> any ProviderRerankerModel {
        guard let endpoint = config.endpoint(id: ref.endpoint) else {
            throw IntatisError.config(
                "unknown reranker endpoint '\(ref.endpoint)'")
        }
        let configuration = try Self.rerankerConfiguration(
            endpoint: endpoint,
            ref: ref)
        return DedicatedRerankerModel(
            endpoint: endpoint,
            resolver: resolver,
            apiKeyRef: endpoint.apiKeyRef,
            model: ref.model,
            http: dataClient,
            configuration: configuration)
    }

    private static func embeddingConfiguration(
        endpoint: ProviderEndpoint,
        ref: ModelRef
    ) throws -> ProviderEmbeddingConfiguration {
        let adapter = endpoint.requestAdapter(for: ref.model)
        let dialect: ProviderEmbeddingDialect
        switch adapter {
        case .legacyOpenAIWire, .openAICompatible, .openAI, .siliconFlowV1:
            dialect = .openAICompatibleV1
        case .openRouter:
            dialect = .openRouterV1
        default:
            throw IntatisError.config(
                "the configured embedding_model has no reviewed native embedding adapter")
        }
        let options = endpoint.requestOptions(for: ref.model)
        let configuredRequestDimensions = try Self.optionalPositiveInteger(
            options["dimensions"],
            name: "dimensions",
            maximum: 65_536)
        let declaredDimensions = try Self.optionalPositiveInteger(
            options["knowledgeEmbeddingDimensions"],
            name: "knowledgeEmbeddingDimensions",
            maximum: 65_536)
        guard configuredRequestDimensions == nil
                || declaredDimensions == nil
                || configuredRequestDimensions == declaredDimensions else {
            throw IntatisError.config(
                "the configured embedding_model declares conflicting dimensions")
        }
        let reviewedDimensions = Self.reviewedDefaultDimensions(for: ref.model)
        // Most fixed-width models use a reviewed expected dimension while
        // omitting the optional wire member. Gemini Embedding 2 is explicitly
        // configurable, so its reviewed 1536-width profile must also request
        // that width when the role-only route has no model menu entry/options.
        let requestDimensions = configuredRequestDimensions
            ?? (declaredDimensions == nil
                ? Self.reviewedDefaultRequestDimensions(for: ref.model)
                : nil)
        guard let dimensions = configuredRequestDimensions
                ?? declaredDimensions
                ?? reviewedDimensions else {
            throw IntatisError.config(
                "the configured embedding_model must declare a positive dimensions option")
        }
        let maximumInput = try Self.optionalPositiveInteger(
            options["knowledgeEmbeddingMaxInputCharacters"],
            name: "knowledgeEmbeddingMaxInputCharacters",
            maximum: 1_000_000) ?? 8_192
        let documentInstruction = try Self.optionalSafeString(
            options["knowledgeDocumentInstruction"],
            name: "knowledgeDocumentInstruction",
            maximum: 2_048) ?? ""
        let queryInstruction = try Self.optionalSafeString(
            options["knowledgeQueryInstruction"],
            name: "knowledgeQueryInstruction",
            maximum: 2_048) ?? ""
        let normalization = "l2"
        let similarity = "cosine"
        let tokenizerRevision = IntatisHostApplication.identity
            .fileNameStem + "-unicode-character-prefix/1"
        let truncation = "end"
        let route = try Self.knowledgeRouteIdentity(
            endpoint: endpoint,
            ref: ref,
            adapterIdentity: dialect.rawValue,
            roleConfiguration: [
                "dimensions": .number(Double(dimensions)),
                "requestDimensions": requestDimensions.map {
                    .number(Double($0))
                } ?? .null,
                "maximumInputCharacters": .number(Double(maximumInput)),
                "documentInstruction": .string(documentInstruction),
                "queryInstruction": .string(queryInstruction),
                "normalization": .string(normalization),
                "similarity": .string(similarity),
                "tokenizerRevision": .string(tokenizerRevision),
                "truncation": .string(truncation),
            ])
        return ProviderEmbeddingConfiguration(
            route: route,
            dialect: dialect,
            dimensions: dimensions,
            requestDimensions: requestDimensions,
            normalization: normalization,
            similarity: similarity,
            documentInstruction: documentInstruction,
            queryInstruction: queryInstruction,
            tokenizerRevision: tokenizerRevision,
            maximumInputCharacters: maximumInput,
            truncation: truncation)
    }

    private static func rerankerConfiguration(
        endpoint: ProviderEndpoint,
        ref: ModelRef
    ) throws -> ProviderRerankerConfiguration {
        let adapter = endpoint.requestAdapter(for: ref.model)
        let dialect: ProviderRerankerDialect
        switch adapter {
        case .siliconFlowV1:
            dialect = .siliconFlowV1
        case .cohereV2:
            dialect = .cohereV2
        case .openRouter:
            dialect = .openRouterV1
        default:
            throw IntatisError.config(
                "the configured reranker_model must use an explicit \(IntatisHostApplication.identity.colonIdentifier("siliconflow-v1")), \(IntatisHostApplication.identity.colonIdentifier("cohere-v2")), or @openrouter/ai-sdk-provider adapter")
        }
        let options = endpoint.requestOptions(for: ref.model)
        let maximumInput = try Self.optionalPositiveInteger(
            options["knowledgeRerankerMaxInputCharacters"],
            name: "knowledgeRerankerMaxInputCharacters",
            maximum: 1_000_000) ?? 8_192
        let maximumCandidates = try Self.optionalPositiveInteger(
            options["knowledgeRerankerMaxCandidates"],
            name: "knowledgeRerankerMaxCandidates",
            maximum: 1_000) ?? 64
        let template = IntatisHostApplication.identity.temporaryPrefix(
            "\(dialect.rawValue)-query-documents/1")
        let tokenizerRevision = "provider-defined"
        let truncation = "end"
        let scoreSemantics = "relevance_score_descending"
        let route = try Self.knowledgeRouteIdentity(
            endpoint: endpoint,
            ref: ref,
            adapterIdentity: dialect.rawValue,
            roleConfiguration: [
                "maximumInputCharacters": .number(Double(maximumInput)),
                "maximumCandidates": .number(Double(maximumCandidates)),
                "template": .string(template),
                "tokenizerRevision": .string(tokenizerRevision),
                "truncation": .string(truncation),
                "scoreSemantics": .string(scoreSemantics),
            ])
        return ProviderRerankerConfiguration(
            route: route,
            dialect: dialect,
            tokenizerRevision: tokenizerRevision,
            maximumInputCharacters: maximumInput,
            maximumCandidates: maximumCandidates,
            templateRevision: template,
            truncation: truncation,
            scoreSemantics: scoreSemantics)
    }

    private static func knowledgeRouteIdentity(
        endpoint: ProviderEndpoint,
        ref: ModelRef,
        adapterIdentity: String,
        roleConfiguration: [String: JSONValue]
    ) throws -> ProviderKnowledgeRouteIdentity {
        guard endpoint.baseURL.user == nil,
              endpoint.baseURL.password == nil,
              endpoint.baseURL.query == nil,
              endpoint.baseURL.fragment == nil else {
            throw IntatisError.config(
                "Knowledge model Base URLs cannot contain credentials, query strings, or fragments.")
        }
        struct CredentialProjection: Codable {
            let source: SecretRefSource
            let service: String
            let account: String
        }
        struct DefinitionProjection: Codable {
            let schema: String
            let providerID: String
            let modelID: String
            let baseURL: String
            let wire: WireFormat
            let requestAdapter: ProviderRequestAdapter
            let credentialReferenceDigest: String
            let modelOptions: [String: JSONValue]
            let roleConfiguration: [String: JSONValue]
        }
        let credentialDigest = try digest(CredentialProjection(
            source: endpoint.apiKeyRef.source,
            service: endpoint.apiKeyRef.service,
            account: endpoint.apiKeyRef.account))
        let definitionDigest = try digest(DefinitionProjection(
            schema: IntatisHostApplication.identity.temporaryPrefix(
                "knowledge-provider-route/1"),
            providerID: endpoint.id,
            modelID: ref.model.rawValue,
            baseURL: endpoint.baseURL.absoluteString,
            wire: endpoint.wire,
            requestAdapter: endpoint.requestAdapter(for: ref.model),
            credentialReferenceDigest: credentialDigest,
            modelOptions: endpoint.requestOptions(for: ref.model),
            roleConfiguration: roleConfiguration))
        let localHosts = Set(["localhost", "127.0.0.1", "::1"])
        let trust = localHosts.contains(
            endpoint.baseURL.host?.lowercased() ?? "")
            ? "user-configured-local"
            : "user-configured-external"
        return ProviderKnowledgeRouteIdentity(
            providerID: endpoint.id,
            modelID: ref.model,
            definitionRevision: "sha256:\(definitionDigest)",
            adapterIdentity: adapterIdentity,
            trustDomain: trust,
            egressClassification: "network-data-egress",
            credentialReferenceDigest: "sha256:\(credentialDigest)",
            definitionDigest: "sha256:\(definitionDigest)")
    }

    private static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(value))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func optionalPositiveInteger(
        _ value: JSONValue?,
        name: String,
        maximum: Int
    ) throws -> Int? {
        guard let value else { return nil }
        guard case .number(let raw) = value,
              raw.isFinite,
              raw.rounded(.towardZero) == raw,
              raw >= 1,
              raw <= Double(maximum) else {
            throw IntatisError.config(
                "the configured Knowledge option '\(name)' must be a bounded positive integer")
        }
        return Int(raw)
    }

    private static func optionalSafeString(
        _ value: JSONValue?,
        name: String,
        maximum: Int
    ) throws -> String? {
        guard let value else { return nil }
        guard case .string(let raw) = value,
              raw.count <= maximum,
              !PermissionReviewTextSanitizer.containsSensitiveMaterial(raw) else {
            throw IntatisError.config(
                "the configured Knowledge option '\(name)' is invalid or sensitive")
        }
        return raw
    }

    private static func reviewedDefaultDimensions(for model: ModelID) -> Int? {
        switch model.rawValue {
        case "text-embedding-3-small", "text-embedding-ada-002":
            return 1_536
        case "text-embedding-3-large":
            return 3_072
        case "BAAI/bge-m3", "netease-youdao/bce-embedding-base_v1":
            return 1_024
        case "google/gemini-embedding-2":
            return 1_536
        default:
            return nil
        }
    }

    private static func reviewedDefaultRequestDimensions(
        for model: ModelID
    ) -> Int? {
        model.rawValue == "google/gemini-embedding-2" ? 1_536 : nil
    }
}
