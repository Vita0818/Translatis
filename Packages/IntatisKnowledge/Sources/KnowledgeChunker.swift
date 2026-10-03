import Foundation

public struct KnowledgeChunkerConfiguration: Codable, Equatable, Sendable {
    public var maximumUTF8Bytes: Int
    public var overlapUTF8Bytes: Int
    public var minimumUTF8Bytes: Int

    public init(maximumUTF8Bytes: Int = 1_200,
                overlapUTF8Bytes: Int = 160,
                minimumUTF8Bytes: Int = 24) {
        self.maximumUTF8Bytes = maximumUTF8Bytes
        self.overlapUTF8Bytes = overlapUTF8Bytes
        self.minimumUTF8Bytes = minimumUTF8Bytes
    }
}

public struct KnowledgeChunkingResult: Equatable, Sendable {
    public let chunks: [KnowledgeChunk]
    public let jsonLines: Data
    public let parametersDigest: String
    public let manifestDigest: String
}

enum KnowledgeChunkManifestIdentity {
    static func digest(
        bundleRevision: String,
        algorithm: String,
        algorithmVersion: String,
        parametersDigest: String,
        chunks: [KnowledgeChunk]
    ) throws -> String {
        var identityLines = Data()
        for chunk in chunks.sorted(by: { $0.chunkID < $1.chunkID }) {
            // The deterministic writer already freezes exact-slice producer
            // metadata, so manifest identity hashes the actual canonical leaf
            // records rather than a second, weaker projection of them.
            identityLines.append(try KnowledgeJSON.encode(chunk))
            identityLines.append(0x0A)
        }
        struct Projection: Codable {
            let version: String
            let bundleRevision: String
            let algorithm: String
            let algorithmVersion: String
            let parametersDigest: String
            let identityLinesSha256: String
        }
        return try KnowledgeDigest.canonical(Projection(
            version: KnowledgeHostIdentity.schema(
                "chunk-manifest-digest/2"),
            bundleRevision: bundleRevision,
            algorithm: algorithm,
            algorithmVersion: algorithmVersion,
            parametersDigest: parametersDigest,
            identityLinesSha256: KnowledgeDigest.sha256(identityLines)))
    }

    static func decode(_ jsonLines: Data) throws -> [KnowledgeChunk] {
        try jsonLines.split(
            separator: 0x0A,
            omittingEmptySubsequences: true).map {
                try KnowledgeJSON.decode(
                    KnowledgeChunk.self,
                    from: Data($0))
            }
    }
}

public struct DeterministicKnowledgeChunker: Sendable {
    public let configuration: KnowledgeChunkerConfiguration

    public init(configuration: KnowledgeChunkerConfiguration = KnowledgeChunkerConfiguration()) {
        self.configuration = configuration
    }

    public func chunk(concepts: [OKFConcept],
                      bundleRevision: String,
                      producedAt: String) throws -> KnowledgeChunkingResult {
        guard configuration.maximumUTF8Bytes >= 128,
              configuration.overlapUTF8Bytes >= 0,
              configuration.overlapUTF8Bytes < configuration.maximumUTF8Bytes,
              configuration.minimumUTF8Bytes >= 1 else {
            throw KnowledgeDomainError(.profileInvalid, "Chunker configuration is invalid.")
        }
        let producer = KnowledgeProducer(
            identity: KnowledgeContract.deterministicChunkerIdentity,
            version: KnowledgeContract.deterministicChunkerVersion,
            // Exact-slice identity is entirely reconstructible from canonical
            // concept bytes. Keep the required schema field bit-stable; the
            // operational publication time belongs to profile.bundle.createdAt.
            at: "1970-01-01T00:00:00Z")
        _ = producedAt
        var chunks: [KnowledgeChunk] = []
        for concept in concepts.sorted(by: { $0.conceptID < $1.conceptID }) {
            let declaredSourceIDs = concept.sources.compactMap(\.id).sorted()
            guard !declaredSourceIDs.isEmpty else { continue }
            for range in paragraphRanges(concept.body) {
                let paragraph = String(concept.body[range])
                let trimmed = trimmedRange(in: paragraph)
                guard let trimmed else { continue }
                let baseStart = concept.body.utf8.distance(
                    from: concept.body.startIndex,
                    to: range.lowerBound)
                let trimmedPrefix = paragraph.utf8.distance(
                    from: paragraph.startIndex,
                    to: trimmed.lowerBound)
                let exact = String(paragraph[trimmed])
                for window in try windows(exact) {
                    let text = String(exact[window])
                    let textBytes = Data(text.utf8)
                    guard textBytes.count >= configuration.minimumUTF8Bytes else { continue }
                    let sourceIDs = try OKFReader.attributedSourceIDs(
                        in: text,
                        declaredSourceIDs: declaredSourceIDs)
                    guard !sourceIDs.isEmpty else { continue }
                    let windowOffset = exact.utf8.distance(
                        from: exact.startIndex,
                        to: window.lowerBound)
                    let start = concept.bodyUTF8Start + baseStart + trimmedPrefix + windowOffset
                    let end = start + textBytes.count
                    let textDigest = KnowledgeDigest.sha256(textBytes)
                    let identity = [
                        KnowledgeHostIdentity.schema("chunk-id/1"),
                        concept.revision,
                        String(start),
                        String(end),
                        textDigest,
                    ].joined(separator: "\n")
                    let chunkID = "chk_" + String(KnowledgeDigest.sha256(identity).dropFirst(7).prefix(32))
                    chunks.append(KnowledgeChunk(
                        chunkID: chunkID,
                        conceptID: concept.conceptID,
                        conceptRevision: concept.revision,
                        evidenceClass: .exactConceptSlice,
                        text: text,
                        textSha256: textDigest,
                        conceptLocator: KnowledgeConceptLocator(start: start, end: end),
                        sourceIDs: sourceIDs,
                        producer: producer))
                }
            }
        }

        var seen = Set<String>()
        guard chunks.allSatisfy({ seen.insert($0.chunkID).inserted }) else {
            throw KnowledgeDomainError(.integrityFailed, "Deterministic chunk IDs collided.")
        }
        let sorted = chunks.sorted { $0.chunkID < $1.chunkID }
        var lines = Data()
        for chunk in sorted {
            lines.append(try KnowledgeJSON.encode(chunk))
            lines.append(0x0A)
        }
        let parametersDigest = try KnowledgeDigest.canonical(configuration)
        let manifestDigest = try KnowledgeChunkManifestIdentity.digest(
            bundleRevision: bundleRevision,
            algorithm: KnowledgeContract.deterministicChunkerIdentity,
            algorithmVersion: KnowledgeContract.deterministicChunkerVersion,
            parametersDigest: parametersDigest,
            chunks: sorted)
        return KnowledgeChunkingResult(
            chunks: sorted,
            jsonLines: lines,
            parametersDigest: parametersDigest,
            manifestDigest: manifestDigest)
    }

    private func paragraphRanges(_ body: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var paragraphStart: String.Index?
        var index = body.startIndex
        var lineStart = index

        func finish(at end: String.Index) {
            if let start = paragraphStart, start < end {
                ranges.append(start..<end)
            }
            paragraphStart = nil
        }

        while index <= body.endIndex {
            let atEnd = index == body.endIndex
            let isNewline = !atEnd && body[index] == "\n"
            if atEnd || isNewline {
                let line = body[lineStart..<index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    finish(at: lineStart)
                } else if paragraphStart == nil {
                    paragraphStart = lineStart
                }
                if atEnd {
                    finish(at: index)
                    break
                }
                index = body.index(after: index)
                lineStart = index
            } else {
                index = body.index(after: index)
            }
        }
        return ranges
    }

    private func trimmedRange(in text: String) -> Range<String.Index>? {
        guard let start = text.firstIndex(where: { !$0.isWhitespace }),
              let last = text.lastIndex(where: { !$0.isWhitespace }) else {
            return nil
        }
        return start..<text.index(after: last)
    }

    private func windows(_ text: String) throws -> [Range<String.Index>] {
        guard Data(text.utf8).count > configuration.maximumUTF8Bytes else {
            return [text.startIndex..<text.endIndex]
        }
        var result: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex {
            var end = start
            var bytes = 0
            var lastBoundary: String.Index?
            while end < text.endIndex {
                let next = text.index(after: end)
                let characterBytes = text[end..<next].utf8.count
                if bytes + characterBytes > configuration.maximumUTF8Bytes { break }
                bytes += characterBytes
                end = next
                if end == text.endIndex || text[text.index(before: end)].isWhitespace {
                    lastBoundary = end
                }
            }
            if let boundary = lastBoundary, boundary > start {
                end = boundary
            }
            if end == start {
                throw KnowledgeDomainError(
                    .okfInvalid,
                    "One extended grapheme cluster exceeds the frozen chunk byte limit.")
            }
            result.append(start..<end)
            if end == text.endIndex { break }

            var overlapStart = end
            var overlapBytes = 0
            while overlapStart > start && overlapBytes < configuration.overlapUTF8Bytes {
                let previous = text.index(before: overlapStart)
                overlapBytes += text[previous..<overlapStart].utf8.count
                overlapStart = previous
            }
            while overlapStart < end, !text[overlapStart].isWhitespace {
                overlapStart = text.index(after: overlapStart)
            }
            while overlapStart < end, text[overlapStart].isWhitespace {
                overlapStart = text.index(after: overlapStart)
            }
            start = overlapStart < end ? overlapStart : end
        }
        return result
    }
}
