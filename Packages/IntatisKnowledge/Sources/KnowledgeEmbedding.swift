import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

public protocol KnowledgeEmbeddingProvider: Sendable {
    var modelIdentity: KnowledgeEmbeddingModelIdentity { get }
    func embedDocuments(_ texts: [String]) async throws -> [[Float]]
    func embedQuery(_ text: String) async throws -> [Float]
}

public struct KnowledgeEmbeddingRuntimeRegistry: Sendable {
    private let providers: [String: any KnowledgeEmbeddingProvider]
    public let digest: String

    public init(_ providers: [any KnowledgeEmbeddingProvider]) throws {
        var byDigest: [String: any KnowledgeEmbeddingProvider] = [:]
        var identities: [KnowledgeEmbeddingModelIdentity] = []
        for provider in providers {
            let key = provider.modelIdentity.runtimeBindingDigest
            guard byDigest[key] == nil else {
                throw KnowledgeDomainError(.embeddingIncompatible, "Embedding runtime binding is registered more than once.")
            }
            byDigest[key] = provider
            identities.append(provider.modelIdentity)
        }
        self.providers = byDigest
        digest = try KnowledgeDigest.canonical(
            identities.sorted {
                if $0.identity != $1.identity { return $0.identity < $1.identity }
                return $0.runtimeBindingDigest < $1.runtimeBindingDigest
            })
    }

    public func resolve(_ expected: KnowledgeEmbeddingModelIdentity) throws -> any KnowledgeEmbeddingProvider {
        guard let provider = providers[expected.runtimeBindingDigest] else {
            throw KnowledgeDomainError(.embeddingUnavailable, retryable: true, "The exact embedding runtime is unavailable.")
        }
        guard provider.modelIdentity == expected else {
            throw KnowledgeDomainError(.embeddingIncompatible, "The embedding runtime compatibility identity does not match the index.")
        }
        return provider
    }
}

#if canImport(NaturalLanguage)
public actor AppleNaturalLanguageSentenceEmbeddingProvider: KnowledgeEmbeddingProvider {
    public nonisolated let modelIdentity: KnowledgeEmbeddingModelIdentity
    private let language: NLLanguage
    private let requiredRevision: Int
    private let maximumInputUnits: Int

    public init(language: NLLanguage = .english,
                revision: Int = 1,
                requiredDimensions: Int = 512,
                maximumInputUnits: Int = 512) throws {
        guard NLEmbedding.supportedSentenceEmbeddingRevisions(for: language).contains(revision),
              let embedding = NLEmbedding.sentenceEmbedding(for: language, revision: revision),
              embedding.revision == revision,
              embedding.dimension == requiredDimensions else {
            throw KnowledgeDomainError(.embeddingUnavailable, retryable: true, "The required Apple sentence embedding revision is unavailable.")
        }
        self.language = language
        requiredRevision = revision
        self.maximumInputUnits = maximumInputUnits
        let binding = [
            "framework=NaturalLanguage",
            "kind=sentence",
            "language=\(language.rawValue)",
            "revision=\(revision)",
            "dimensions=\(requiredDimensions)",
            "input=\(KnowledgeHostIdentity.schema("unicode-token-prefix/1")):\(maximumInputUnits)",
            "architecture=\(Self.runtimeArchitecture)",
            "os=\(ProcessInfo.processInfo.operatingSystemVersionString)",
        ].joined(separator: ";")
        modelIdentity = KnowledgeEmbeddingModelIdentity(
            identity: "com.apple.NaturalLanguage.sentence.\(language.rawValue)",
            revision: "vendor-revision:\(revision)",
            tokenizerRevision: KnowledgeHostIdentity.schema(
                "unicode-token-prefix/1")
                + "+vendor-revision:\(revision)",
            runtimeBindingKind: .local,
            runtimeBindingDigest: KnowledgeDigest.sha256(binding),
            dimensions: requiredDimensions,
            pooling: "vendor-sentence",
            documentInstruction: "",
            queryInstruction: "",
            maxInputTokens: maximumInputUnits,
            truncation: "end")
    }

    public func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        try embed(texts)
    }

    public func embedQuery(_ text: String) async throws -> [Float] {
        guard let first = try embed([text]).first else {
            throw KnowledgeDomainError(.embeddingUnavailable, retryable: true, "The query embedding was not produced.")
        }
        return first
    }

    private func embed(_ texts: [String]) throws -> [[Float]] {
        guard let embedding = NLEmbedding.sentenceEmbedding(
            for: language,
            revision: requiredRevision),
              embedding.revision == requiredRevision,
              embedding.dimension == modelIdentity.dimensions else {
            throw KnowledgeDomainError(.embeddingUnavailable, retryable: true, "The exact Apple sentence embedding runtime changed.")
        }
        return try texts.map { text in
            let bounded = KnowledgeTextTokenizer.prefix(
                text,
                maximumUnits: maximumInputUnits)
            guard !bounded.isEmpty,
                  let raw = embedding.vector(for: bounded),
                  raw.count == modelIdentity.dimensions else {
                throw KnowledgeDomainError(.embeddingUnavailable, retryable: true, "Apple sentence embedding did not return the expected vector.")
            }
            return try KnowledgeVectorMath.normalized(raw.map(Float.init))
        }
    }

    private nonisolated static var runtimeArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unsupported"
        #endif
    }
}
#endif

public enum KnowledgeVectorMath {
    public static func isUnitNormalized(
        _ values: [Float],
        tolerance: Double = 0.002
    ) -> Bool {
        guard tolerance >= 0,
              !values.isEmpty,
              values.allSatisfy(\.isFinite) else { return false }
        let squared = values.reduce(0.0) {
            $0 + Double($1) * Double($1)
        }
        return squared.isFinite && abs(squared - 1) <= tolerance
    }

    public static func normalized(_ values: [Float]) throws -> [Float] {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else {
            throw KnowledgeDomainError(.embeddingIncompatible, "Embedding vector is empty or non-finite.")
        }
        var sum: Double = 0
        for value in values {
            sum += Double(value) * Double(value)
        }
        let norm = sqrt(sum)
        guard norm.isFinite, norm > 0 else {
            throw KnowledgeDomainError(.embeddingIncompatible, "Embedding vector norm is invalid.")
        }
        return values.map { Float(Double($0) / norm) }
    }

    public static func cosine(_ lhs: [Float], _ rhs: [Float]) throws -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty,
              lhs.allSatisfy(\.isFinite), rhs.allSatisfy(\.isFinite) else {
            throw KnowledgeDomainError(.embeddingIncompatible, "Embedding vectors are incompatible.")
        }
        var dot: Double = 0
        var lhsSquared: Double = 0
        var rhsSquared: Double = 0
        for index in lhs.indices {
            let left = Double(lhs[index])
            let right = Double(rhs[index])
            dot += left * right
            lhsSquared += left * left
            rhsSquared += right * right
        }
        let denominator = sqrt(lhsSquared) * sqrt(rhsSquared)
        guard dot.isFinite,
              denominator.isFinite,
              denominator > 0 else {
            throw KnowledgeDomainError(.embeddingIncompatible, "Embedding similarity is non-finite.")
        }
        return dot / denominator
    }
}
