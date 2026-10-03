import Foundation
import IntatisPermission
import IntatisProviders

/// Bridges the provider catalog's exact embedding route into the immutable
/// Knowledge snapshot identity. The wrapper is deliberately the only place
/// where provider vectors become Knowledge vectors: it scans outbound text,
/// validates dimensions and normalizes every vector before use.
public struct ProviderKnowledgeEmbeddingAdapter: KnowledgeEmbeddingProvider {
    public let modelIdentity: KnowledgeEmbeddingModelIdentity
    private let provider: any ProviderEmbeddingModel

    public init(provider: any ProviderEmbeddingModel) throws {
        let configuration = provider.configuration
        guard KnowledgeDigest.isValid(configuration.route.definitionDigest),
              configuration.dimensions > 0,
              configuration.normalization == "l2",
              configuration.similarity == "cosine",
              configuration.maximumInputCharacters > 0 else {
            throw KnowledgeDomainError(
                .embeddingIncompatible,
                "The configured embedding route has an invalid compatibility identity.")
        }
        modelIdentity = KnowledgeEmbeddingModelIdentity(
            identity: Self.identity(
                role: "embedding",
                digest: configuration.route.definitionDigest),
            revision: configuration.route.definitionRevision,
            tokenizerRevision: configuration.tokenizerRevision,
            runtimeBindingKind: .remote,
            runtimeBindingDigest: configuration.route.definitionDigest,
            dimensions: configuration.dimensions,
            pooling: "provider-defined",
            normalization: configuration.normalization,
            similarity: configuration.similarity,
            documentInstruction: configuration.documentInstruction,
            queryInstruction: configuration.queryInstruction,
            maxInputTokens: configuration.maximumInputCharacters,
            truncation: configuration.truncation)
        self.provider = provider
    }

    public func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        try Self.requireSafeOutbound(texts)
        return try await embed(
            texts,
            instruction: provider.configuration.documentInstruction)
    }

    public func embedQuery(_ text: String) async throws -> [Float] {
        try Self.requireSafeOutbound([text])
        guard let vector = try await embed(
            [text],
            instruction: provider.configuration.queryInstruction).first else {
            throw KnowledgeDomainError(
                .embeddingUnavailable,
                retryable: true,
                "The embedding provider omitted the query vector.")
        }
        return vector
    }

    private func embed(_ texts: [String], instruction: String) async throws
        -> [[Float]] {
        do {
            let vectors = try await provider.embed(texts, instruction: instruction)
            guard vectors.count == texts.count else {
                throw KnowledgeDomainError(
                    .embeddingIncompatible,
                    "The embedding provider returned an incomplete vector batch.")
            }
            return try vectors.map { values in
                guard values.count == modelIdentity.dimensions,
                      values.allSatisfy(\.isFinite) else {
                    throw KnowledgeDomainError(
                        .embeddingIncompatible,
                        "The embedding provider returned an incompatible vector.")
                }
                return try KnowledgeVectorMath.normalized(values.map(Float.init))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let domain as KnowledgeDomainError {
            throw domain
        } catch {
            throw KnowledgeDomainError(
                .embeddingUnavailable,
                retryable: true,
                "The exact embedding provider request failed.")
        }
    }

    private static func requireSafeOutbound(_ texts: [String]) throws {
        guard !texts.isEmpty,
              texts.allSatisfy({ !SecretScanner.containsSecret($0) }) else {
            throw KnowledgeDomainError(
                .accessDenied,
                "Potential secret-bearing text was blocked before embedding egress.")
        }
    }

    fileprivate static func identity(role: String, digest: String) -> String {
        let body = digest.hasPrefix("sha256:")
            ? String(digest.dropFirst("sha256:".count))
            : digest
        return KnowledgeHostIdentity.reverseDomain(
            "provider.\(role).\(body.prefix(24))")
    }
}

/// Bridges a dedicated semantic reranker route into Knowledge. This never
/// substitutes embedding cosine order, and accepts only a complete permutation
/// returned by the provider adapter.
public struct ProviderKnowledgeRerankerAdapter: KnowledgeRerankerProvider {
    public let modelIdentity: KnowledgeRerankerModelIdentity
    private let provider: any ProviderRerankerModel

    public init(provider: any ProviderRerankerModel) throws {
        let configuration = provider.configuration
        guard KnowledgeDigest.isValid(configuration.route.definitionDigest),
              configuration.maximumInputCharacters > 0,
              configuration.maximumCandidates > 0 else {
            throw KnowledgeDomainError(
                .rerankIncompatible,
                "The configured reranker route has an invalid compatibility identity.")
        }
        modelIdentity = KnowledgeRerankerModelIdentity(
            identity: ProviderKnowledgeEmbeddingAdapter.identity(
                role: "reranker",
                digest: configuration.route.definitionDigest),
            revision: configuration.route.definitionRevision,
            tokenizerRevision: configuration.tokenizerRevision,
            runtimeBindingKind: .remote,
            runtimeBindingDigest: configuration.route.definitionDigest,
            templateDigest: KnowledgeDigest.sha256(configuration.templateRevision),
            maxInputTokens: configuration.maximumInputCharacters,
            truncation: configuration.truncation,
            scoreSemantics: configuration.scoreSemantics)
        self.provider = provider
    }

    public func rerank(query: String,
                       candidates: [KnowledgeRerankCandidate]) async throws
        -> [KnowledgeRerankedCandidate] {
        guard !query.isEmpty,
              !candidates.isEmpty,
              candidates.count <= provider.configuration.maximumCandidates else {
            throw KnowledgeDomainError(
                .rerankIncompatible,
                "The reranker input exceeds its frozen candidate contract.")
        }
        let outbound = [query] + candidates.map(\.text)
        guard outbound.allSatisfy({ !SecretScanner.containsSecret($0) }) else {
            throw KnowledgeDomainError(
                .accessDenied,
                "Potential secret-bearing text was blocked before reranker egress.")
        }
        do {
            let results = try await provider.rerank(
                query: query,
                documents: candidates.map(\.text))
            guard results.count == candidates.count else {
                throw KnowledgeDomainError(
                    .rerankIncompatible,
                    "The reranker returned an incomplete candidate permutation.")
            }
            var seen = Set<Int>()
            return try results.map { result in
                guard result.index >= 0,
                      result.index < candidates.count,
                      result.score.isFinite,
                      seen.insert(result.index).inserted else {
                    throw KnowledgeDomainError(
                        .rerankIncompatible,
                        "The reranker returned incompatible indexes or scores.")
                }
                return KnowledgeRerankedCandidate(
                    chunkID: candidates[result.index].chunkID,
                    score: result.score)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let domain as KnowledgeDomainError {
            throw domain
        } catch {
            throw KnowledgeDomainError(
                .rerankUnavailable,
                retryable: true,
                "The exact reranker provider request failed.")
        }
    }
}
