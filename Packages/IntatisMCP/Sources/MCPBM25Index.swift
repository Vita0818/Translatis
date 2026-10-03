// Derived Swift implementation of bm25 2.3.2
// (Michael-JB/bm25, crate commit 8ef726045b41702e148d8996d344f3500844fde1)
// and fxhash 0.2.1's 32-bit string hasher.
//
// Local modifications: Swift value types, deterministic document-ID ordering
// for upstream-undefined exact-score ties, and no Rust runtime dependency.
// Provenance and license notices: ThirdPartyNotices/MCPToolSearch.md.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Scoring-equivalent port of bm25 2.3.2's default
/// `SearchEngineBuilder::<usize>::with_documents(Language::English, ...)`.
///
/// It deliberately uses Float throughout because the pinned Rust crate uses
/// f32 for average length, normalized term frequency, IDF, and score
/// accumulation. Query duplicates are retained and scored repeatedly.
struct MCPBM25Index: Sendable {
    struct Ranked: Equatable, Sendable {
        let index: Int
        let score: Double
    }

    private struct DocumentEmbedding: Sendable {
        let values: [UInt32: Float]
    }

    private let embeddings: [DocumentEmbedding]
    private let documentFrequencies: [UInt32: Int]

    init(documents: [String]) {
        let tokenIDs = documents.map {
            MCPEnglishTokenizer.tokens($0).map(MCPFxHash32.hash)
        }
        let totalLength = tokenIDs.reduce(UInt64(0)) {
            $0 + UInt64($1.count)
        }
        let averageDocumentLength: Float
        if tokenIDs.isEmpty {
            averageDocumentLength = 256
        } else {
            averageDocumentLength = Self.averageDocumentLength(
                totalLength: totalLength,
                documentCount: tokenIDs.count)
        }
        let effectiveAverage = averageDocumentLength <= 0
            ? Float(256)
            : averageDocumentLength
        let k1 = Float(1.2)
        let b = Float(0.75)

        embeddings = tokenIDs.map { document in
            var counts: [UInt32: Int] = [:]
            for token in document {
                counts[token, default: 0] += 1
            }
            var values: [UInt32: Float] = [:]
            for (token, count) in counts {
                let frequency = Float(count)
                let numerator = frequency * (k1 + 1)
                let lengthRatio =
                    Float(document.count) / effectiveAverage
                let denominator = frequency
                    + k1 * (1 - b + b * lengthRatio)
                values[token] = numerator / denominator
            }
            return DocumentEmbedding(values: values)
        }

        var frequencies: [UInt32: Int] = [:]
        for document in tokenIDs {
            for token in Set(document) {
                frequencies[token, default: 0] += 1
            }
        }
        documentFrequencies = frequencies
    }

    /// Mirrors bm25 2.3.2's
    /// `(total_len as f64 / corpus.len() as f64) as f32` exactly. Keeping the
    /// division in Double matters once token totals exceed Float's exact
    /// integer range.
    static func averageDocumentLength(
        totalLength: UInt64,
        documentCount: Int
    ) -> Float {
        Float(Double(totalLength) / Double(documentCount))
    }

    func search(query: String, limit: Int) -> [Ranked] {
        guard limit > 0, !embeddings.isEmpty else { return [] }
        let queryTokens =
            MCPEnglishTokenizer.tokens(query).map(MCPFxHash32.hash)
        guard !queryTokens.isEmpty else { return [] }

        let documentCount = Float(embeddings.count)
        var ranked: [(index: Int, score: Float)] = []
        ranked.reserveCapacity(embeddings.count)
        for (index, embedding) in embeddings.enumerated() {
            var score = Float(0)
            var matched = false
            for token in queryTokens {
                guard let normalizedFrequency = embedding.values[token],
                      let frequency = documentFrequencies[token] else {
                    continue
                }
                matched = true
                let documentFrequency = Float(frequency)
                let numerator =
                    documentCount - documentFrequency + Float(0.5)
                let denominator =
                    documentFrequency + Float(0.5)
                let inverseDocumentFrequency =
                    logf(1 + numerator / denominator)
                let tokenScore =
                    inverseDocumentFrequency * normalizedFrequency
                score += tokenScore
            }
            if matched, score > 0 {
                ranked.append((index, score))
            }
        }
        ranked.sort {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            // bm25's HashSet traversal leaves exact ties unspecified. A stable
            // document-id tie break makes replay deterministic without changing
            // any score-defined ordering.
            return $0.index < $1.index
        }
        return ranked.prefix(limit).map {
            Ranked(index: $0.index, score: Double($0.score))
        }
    }
}

/// fxhash 0.2.1 `hash32(&str)` used by bm25's default u32 token embedder.
enum MCPFxHash32 {
    private static let seed = UInt32(0x2722_0A95)

    static func hash(_ value: String) -> UInt32 {
        let bytes = Array(value.utf8)
        var hash = UInt32(0)
        var index = 0
        while index + 4 <= bytes.count {
            let word = UInt32(bytes[index])
                | (UInt32(bytes[index + 1]) << 8)
                | (UInt32(bytes[index + 2]) << 16)
                | (UInt32(bytes[index + 3]) << 24)
            hash = mix(hash, word)
            index += 4
        }
        while index < bytes.count {
            hash = mix(hash, UInt32(bytes[index]))
            index += 1
        }
        // Rust's Hash implementation for str terminates the byte stream with
        // 0xff so concatenated string tuples remain prefix-free.
        return mix(hash, 0xFF)
    }

    private static func mix(
        _ hash: UInt32,
        _ word: UInt32
    ) -> UInt32 {
        let rotated = (hash << 5) | (hash >> 27)
        return (rotated ^ word) &* seed
    }
}
