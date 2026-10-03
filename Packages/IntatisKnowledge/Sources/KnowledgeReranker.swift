import Foundation

public struct KnowledgeRerankCandidate: Equatable, Sendable {
    public let chunkID: String
    public let text: String
    public let retrievalRank: Int
    public let retrievalScore: Double

    public init(chunkID: String,
                text: String,
                retrievalRank: Int,
                retrievalScore: Double) {
        self.chunkID = chunkID
        self.text = text
        self.retrievalRank = retrievalRank
        self.retrievalScore = retrievalScore
    }
}

public struct KnowledgeRerankedCandidate: Equatable, Sendable {
    public let chunkID: String
    public let score: Double

    public init(chunkID: String, score: Double) {
        self.chunkID = chunkID
        self.score = score
    }
}

public protocol KnowledgeRerankerProvider: Sendable {
    var modelIdentity: KnowledgeRerankerModelIdentity { get }

    /// Returns a complete, duplicate-free ordering of the supplied candidates.
    /// The search engine independently verifies that invariant before accepting
    /// the result, so a runtime cannot inject a chunk outside the frozen corpus.
    func rerank(query: String,
                candidates: [KnowledgeRerankCandidate]) async throws
        -> [KnowledgeRerankedCandidate]
}

public struct KnowledgeRerankerRuntimeRegistry: Sendable {
    private let providers: [String: any KnowledgeRerankerProvider]
    public let digest: String

    public init(_ providers: [any KnowledgeRerankerProvider] = []) throws {
        var byBinding: [String: any KnowledgeRerankerProvider] = [:]
        var identities: [KnowledgeRerankerModelIdentity] = []
        for provider in providers {
            let binding = provider.modelIdentity.runtimeBindingDigest
            guard KnowledgeDigest.isValid(binding), byBinding[binding] == nil else {
                throw KnowledgeDomainError(
                    .rerankUnavailable,
                    "A reranker runtime binding is invalid or registered more than once.")
            }
            byBinding[binding] = provider
            identities.append(provider.modelIdentity)
        }
        self.providers = byBinding
        digest = try KnowledgeDigest.canonical(identities.sorted {
            if $0.identity != $1.identity { return $0.identity < $1.identity }
            if $0.revision != $1.revision { return $0.revision < $1.revision }
            return $0.runtimeBindingDigest < $1.runtimeBindingDigest
        })
    }

    public func resolve(_ expected: KnowledgeRerankerModelIdentity) throws
        -> any KnowledgeRerankerProvider {
        guard let provider = providers[expected.runtimeBindingDigest],
              provider.modelIdentity == expected else {
            throw KnowledgeDomainError(
                .rerankUnavailable,
                retryable: true,
                "The exact reranker runtime is unavailable.")
        }
        return provider
    }
}

/// Minimal local Phase-4 route: candidates are embedded again under one exact
/// embedding compatibility identity and sorted by cosine similarity. This is
/// deliberately named as an embedding-cosine reranker rather than pretending
/// to be a cross-encoder. Its frozen template and runtime binding remain fully
/// recorded in `KnowledgeRerankerModelIdentity`.
public struct KnowledgeEmbeddingCosineRerankerProvider: KnowledgeRerankerProvider {
    public static var template: String {
        KnowledgeHostIdentity.schema(
            "embedding-cosine-reranker-template/1")
    }

    public let modelIdentity: KnowledgeRerankerModelIdentity
    private let embeddingProvider: any KnowledgeEmbeddingProvider

    public init(embeddingProvider: any KnowledgeEmbeddingProvider) throws {
        let embedding = embeddingProvider.modelIdentity
        let templateDigest = KnowledgeDigest.sha256(Self.template)
        struct RuntimeProjection: Codable {
            let route: String
            let templateDigest: String
            let embedding: KnowledgeEmbeddingModelIdentity
        }
        let runtimeBindingDigest = try KnowledgeDigest.canonical(RuntimeProjection(
            route: KnowledgeHostIdentity.schema(
                "embedding-cosine-reranker-runtime/1"),
            templateDigest: templateDigest,
            embedding: embedding))
        modelIdentity = KnowledgeRerankerModelIdentity(
            identity: KnowledgeHostIdentity.reverseDomain(
                "embedding-cosine.\(embedding.identity)"),
            revision: "embedding-cosine/1+\(embedding.revision)",
            tokenizerRevision: embedding.tokenizerRevision,
            runtimeBindingKind: embedding.runtimeBindingKind,
            runtimeBindingDigest: runtimeBindingDigest,
            templateDigest: templateDigest,
            maxInputTokens: embedding.maxInputTokens,
            truncation: embedding.truncation,
            scoreSemantics: "cosine_similarity_descending")
        self.embeddingProvider = embeddingProvider
    }

    public func rerank(query: String,
                       candidates: [KnowledgeRerankCandidate]) async throws
        -> [KnowledgeRerankedCandidate] {
        guard !query.isEmpty else {
            throw KnowledgeDomainError(
                .rerankUnavailable,
                "The reranker query is empty.")
        }
        guard !candidates.isEmpty else { return [] }
        let queryVector = try await embeddingProvider.embedQuery(query)
        let documentVectors = try await embeddingProvider.embedDocuments(
            candidates.map(\.text))
        guard documentVectors.count == candidates.count else {
            throw KnowledgeDomainError(
                .rerankUnavailable,
                retryable: true,
                "The reranker runtime returned an incomplete candidate batch.")
        }
        var results: [(candidate: KnowledgeRerankCandidate, score: Double)] = []
        results.reserveCapacity(candidates.count)
        for (candidate, vector) in zip(candidates, documentVectors) {
            let score = try KnowledgeVectorMath.cosine(queryVector, vector)
            guard score.isFinite else {
                throw KnowledgeDomainError(
                    .rerankUnavailable,
                    "The reranker produced a non-finite score.")
            }
            results.append((candidate, score))
        }
        return results.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.candidate.retrievalRank != $1.candidate.retrievalRank {
                return $0.candidate.retrievalRank < $1.candidate.retrievalRank
            }
            return $0.candidate.chunkID < $1.candidate.chunkID
        }.map {
            KnowledgeRerankedCandidate(
                chunkID: $0.candidate.chunkID,
                score: $0.score)
        }
    }
}
