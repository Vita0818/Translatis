import Foundation

public enum KnowledgeTextTokenizer {
    public static var identity: String {
        KnowledgeHostIdentity.schema(
            "multilingual-code-tokenizer/1")
    }

    public static func tokens(_ text: String) -> [String] {
        let normalized = OKFReader.normalize(text).lowercased()
        var tokens: [String] = []
        var current = String.UnicodeScalarView()

        func flush() {
            guard !current.isEmpty else { return }
            let value = String(current)
            tokens.append(value)
            if value.unicodeScalars.count >= 3 {
                let scalars = Array(value.unicodeScalars)
                for index in 0...(scalars.count - 3) {
                    tokens.append(String(String.UnicodeScalarView(scalars[index..<(index + 3)])))
                }
            }
            current.removeAll(keepingCapacity: true)
        }

        for scalar in normalized.unicodeScalars {
            if CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || scalar == "_" {
                if isCJK(scalar) {
                    flush()
                    tokens.append(String(scalar))
                } else {
                    current.append(scalar)
                }
            } else {
                flush()
            }
        }
        flush()

        let cjk = Array(normalized.unicodeScalars.filter(isCJK))
        if cjk.count >= 2 {
            for index in 0..<(cjk.count - 1) {
                tokens.append(String(String.UnicodeScalarView(cjk[index...index + 1])))
            }
        }
        if cjk.count >= 3 {
            for index in 0..<(cjk.count - 2) {
                tokens.append(String(String.UnicodeScalarView(cjk[index...index + 2])))
            }
        }
        return tokens.filter { !$0.isEmpty }
    }

    public static func prefix(_ text: String, maximumUnits: Int) -> String {
        guard maximumUnits > 0 else { return "" }
        let normalized = OKFReader.normalize(text)
        var units = 0
        var end = normalized.startIndex
        var index = normalized.startIndex
        var inWord = false
        while index < normalized.endIndex {
            let character = normalized[index]
            let isWord = character.unicodeScalars.allSatisfy {
                CharacterSet.letters.contains($0)
                    || CharacterSet.decimalDigits.contains($0)
                    || $0 == "_"
            }
            if isWord {
                if !inWord {
                    units += 1
                    guard units <= maximumUnits else { break }
                }
                inWord = true
            } else {
                inWord = false
            }
            end = normalized.index(after: index)
            index = end
        }
        return String(normalized[..<end])
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}

public struct KnowledgeScoredChunk: Equatable, Sendable {
    public let chunkID: String
    public let score: Double
}

public struct KnowledgeDenseIndex: Sendable {
    public let dimensions: Int
    private let vectors: [KnowledgeDenseVectorRecord]

    public init(file: KnowledgeDenseIndexFile) throws {
        guard file.schema == KnowledgeHostIdentity.schema(
                "dense-exact-knn/1"),
              file.dimensions > 0,
              !file.vectors.isEmpty else {
            throw KnowledgeDomainError(.integrityFailed, "Dense index header is invalid.")
        }
        var IDs = Set<String>()
        for record in file.vectors {
            guard IDs.insert(record.chunkID).inserted,
                  record.values.count == file.dimensions,
                  KnowledgeVectorMath.isUnitNormalized(record.values) else {
                throw KnowledgeDomainError(.integrityFailed, "Dense index contains duplicate or incompatible vectors.")
            }
        }
        dimensions = file.dimensions
        vectors = file.vectors.sorted { $0.chunkID < $1.chunkID }
    }

    public func search(query: [Float], limit: Int) throws -> [KnowledgeScoredChunk] {
        guard query.count == dimensions else {
            throw KnowledgeDomainError(.embeddingIncompatible, "Query embedding does not match the dense index.")
        }
        let normalizedQuery = try KnowledgeVectorMath.normalized(query)
        return try vectors.map {
            KnowledgeScoredChunk(
                chunkID: $0.chunkID,
                score: try KnowledgeVectorMath.cosine(
                    normalizedQuery,
                    $0.values))
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.chunkID < $1.chunkID
        }.prefix(max(0, limit)).map { $0 }
    }
}

public struct KnowledgeBM25Index: Sendable {
    public struct Parameters: Codable, Equatable, Sendable {
        public let k1: Double
        public let b: Double

        public init(k1: Double = 1.2, b: Double = 0.75) {
            self.k1 = k1
            self.b = b
        }
    }

    public let parameters: Parameters
    private let documents: [KnowledgeLexicalDocumentRecord]
    private let documentFrequency: [String: Int]
    private let averageLength: Double

    public init(file: KnowledgeLexicalIndexFile,
                parameters: Parameters = Parameters()) throws {
        guard file.schema == KnowledgeHostIdentity.schema(
                "lexical-bm25/1"),
              file.tokenizer == KnowledgeTextTokenizer.identity,
              !file.documents.isEmpty else {
            throw KnowledgeDomainError(.integrityFailed, "Lexical index header is invalid.")
        }
        var IDs = Set<String>()
        var frequency: [String: Int] = [:]
        for document in file.documents {
            guard IDs.insert(document.chunkID).inserted,
                  document.length > 0,
                  document.terms.values.allSatisfy({ $0 > 0 }) else {
                throw KnowledgeDomainError(.integrityFailed, "Lexical index contains invalid documents.")
            }
            for term in document.terms.keys {
                frequency[term, default: 0] += 1
            }
        }
        self.parameters = parameters
        documents = file.documents.sorted { $0.chunkID < $1.chunkID }
        documentFrequency = frequency
        averageLength = Double(file.documents.reduce(0) { $0 + $1.length })
            / Double(file.documents.count)
    }

    public func search(query: String, limit: Int) -> [KnowledgeScoredChunk] {
        let terms = Array(Set(KnowledgeTextTokenizer.tokens(query))).sorted()
        guard !terms.isEmpty else { return [] }
        let count = Double(documents.count)
        var scores: [KnowledgeScoredChunk] = []
        for document in documents {
            var score = 0.0
            for term in terms {
                guard let termFrequency = document.terms[term],
                      let frequency = documentFrequency[term] else { continue }
                let idf = log(1 + (count - Double(frequency) + 0.5) / (Double(frequency) + 0.5))
                let tf = Double(termFrequency)
                let denominator = tf + parameters.k1 * (
                    1 - parameters.b
                        + parameters.b * Double(document.length) / max(1, averageLength))
                score += idf * tf * (parameters.k1 + 1) / denominator
            }
            if score > 0 {
                scores.append(KnowledgeScoredChunk(chunkID: document.chunkID, score: score))
            }
        }
        return scores.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.chunkID < $1.chunkID
        }.prefix(max(0, limit)).map { $0 }
    }
}

public enum KnowledgeRRF {
    public static func fuse(_ rankings: [[KnowledgeScoredChunk]],
                            k: Int = 60,
                            limit: Int) -> [KnowledgeScoredChunk] {
        var scores: [String: Double] = [:]
        for ranking in rankings {
            for (offset, result) in ranking.enumerated() {
                scores[result.chunkID, default: 0] += 1 / Double(k + offset + 1)
            }
        }
        return scores.map {
            KnowledgeScoredChunk(chunkID: $0.key, score: $0.value)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.chunkID < $1.chunkID
        }.prefix(max(0, limit)).map { $0 }
    }
}
