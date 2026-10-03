import Foundation
import XCTest
@testable import IntatisKnowledge
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

final class KnowledgeRetrievalQualityTests: XCTestCase {
    private struct Corpus: Decodable {
        struct Document: Decodable, Equatable {
            let id: String
            let text: String
            let status: String
            let staleAfter: String?
            let sourceIDs: [String]
            let containsPromptInjection: Bool
        }

        struct Query: Decodable, Equatable {
            let id: String
            let text: String
            let relevant: [String]
            let answerable: Bool
            let expectedSourceIDs: [String]
            let containsPromptInjection: Bool
        }

        let schema: String
        let evaluationDate: String
        let documents: [Document]
        let queries: [Query]
    }

    private struct RetrievalMetrics {
        var recallAtOne = 0.0
        var recallAtFive = 0.0
        var meanReciprocalRank = 0.0
        var nDCGAtFive = 0.0
        var citationCoverage = 0.0
        var citationPrecision = 0.0
    }

    func testFrozenCorpusIsClosedWorldAndSeparatesAnswerability() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.schema, "intatis-knowledge-eval-corpus/2")
        XCTAssertEqual(corpus.evaluationDate, "2026-08-09T00:00:00Z")

        let documentIDs = corpus.documents.map(\.id)
        XCTAssertEqual(Set(documentIDs).count, documentIDs.count)
        XCTAssertTrue(corpus.documents.allSatisfy {
            !$0.id.isEmpty && !$0.text.isEmpty && !$0.sourceIDs.isEmpty
        })

        let queryIDs = corpus.queries.map(\.id)
        XCTAssertEqual(Set(queryIDs).count, queryIDs.count)
        let knownDocumentIDs = Set(documentIDs)
        for query in corpus.queries {
            XCTAssertEqual(
                query.answerable,
                !query.relevant.isEmpty,
                "Answerability label drifted for \(query.id)")
            XCTAssertTrue(
                Set(query.relevant).isSubset(of: knownDocumentIDs),
                "Unknown relevance identifier in \(query.id)")
            if query.answerable {
                XCTAssertFalse(query.expectedSourceIDs.isEmpty)
                let relevantSources = Set(query.relevant.flatMap { relevantID in
                    corpus.documents.first(where: { $0.id == relevantID })?.sourceIDs ?? []
                })
                XCTAssertTrue(
                    Set(query.expectedSourceIDs).isSubset(of: relevantSources),
                    "Expected provenance is not backed by relevance labels for \(query.id)")
            } else {
                XCTAssertTrue(query.expectedSourceIDs.isEmpty)
            }
        }

        XCTAssertGreaterThanOrEqual(corpus.queries.filter(\.answerable).count, 16)
        XCTAssertGreaterThanOrEqual(corpus.queries.filter { !$0.answerable }.count, 3)
        XCTAssertEqual(corpus.documents.filter(\.containsPromptInjection).count, 1)
        XCTAssertEqual(corpus.queries.filter(\.containsPromptInjection).count, 1)
        XCTAssertEqual(
            Set(blockedDocumentIDs(in: corpus)),
            ["rag-grounding-stale", "rag-snapshot-deprecated"])
    }

    #if canImport(NaturalLanguage)
    func testAppleEnglishHybridRouteMeetsFrozenCorpusGate() async throws {
        let corpus = try loadCorpus()
        let eligible = try eligibleDocuments(in: corpus)
        let provider: AppleNaturalLanguageSentenceEmbeddingProvider
        do {
            provider = try AppleNaturalLanguageSentenceEmbeddingProvider(
                language: .english,
                revision: 1,
                requiredDimensions: 512,
                maximumInputUnits: 512)
        } catch {
            throw XCTSkip(
                "Pinned Apple NaturalLanguage sentence embedding is unavailable "
                    + "on this test host; the route, Intel, and real-device matrix remain UNKNOWN.")
        }

        let documentVectors = try await provider.embedDocuments(
            eligible.map(\.text))
        let denseFile = KnowledgeDenseIndexFile(
            dimensions: 512,
            vectors: zip(eligible, documentVectors).map {
                KnowledgeDenseVectorRecord(chunkID: $0.0.id, values: $0.1)
            })
        let lexicalFile = makeLexicalFile(documents: eligible)
        let dense = try KnowledgeDenseIndex(file: denseFile)
        let lexical = try KnowledgeBM25Index(file: lexicalFile)

        let answerable = corpus.queries.filter(\.answerable)
        let documentsByID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        var recallAtOne = 0
        var recallAtFive = 0
        var reciprocalRank = 0.0
        var nDCG = 0.0
        var selectedCitations = 0
        var correctCitations = 0

        for query in answerable {
            let vector = try await provider.embedQuery(query.text)
            let denseRanking = try dense.search(query: vector, limit: 10)
            let lexicalRanking = lexical.search(query: query.text, limit: 10)
            let ranking = KnowledgeRRF.fuse(
                [denseRanking, lexicalRanking],
                limit: 10).map(\.chunkID)
            let relevant = Set(query.relevant)

            if ranking.first.map(relevant.contains) == true {
                recallAtOne += 1
            }
            if !Set(ranking.prefix(5)).isDisjoint(with: relevant) {
                recallAtFive += 1
            }
            if let index = ranking.firstIndex(where: relevant.contains) {
                reciprocalRank += 1.0 / Double(index + 1)
            }
            nDCG += Self.nDCG(ranking: ranking, relevant: relevant, at: 5)

            // The citation selector is deliberately limited to retrieved,
            // relevant evidence. This metric measures whether retrieval keeps
            // the exact source provenance attached instead of fabricating or
            // cross-wiring it to a different document.
            if let citationID = ranking.prefix(5).first(where: relevant.contains),
               let document = documentsByID[citationID] {
                selectedCitations += 1
                let returnedSources = Set(document.sourceIDs)
                let expectedSources = Set(query.expectedSourceIDs)
                if !returnedSources.isEmpty,
                   returnedSources.isSubset(of: expectedSources) {
                    correctCitations += 1
                }
            }
        }

        let count = Double(answerable.count)
        let metrics = RetrievalMetrics(
            recallAtOne: Double(recallAtOne) / count,
            recallAtFive: Double(recallAtFive) / count,
            meanReciprocalRank: reciprocalRank / count,
            nDCGAtFive: nDCG / count,
            citationCoverage: Double(selectedCitations) / count,
            citationPrecision: selectedCitations == 0
                ? 0
                : Double(correctCitations) / Double(selectedCitations))

        XCTAssertGreaterThanOrEqual(
            metrics.recallAtFive,
            0.85,
            "Recall@5 regression: \(metrics.recallAtFive)")
        XCTAssertGreaterThanOrEqual(
            metrics.meanReciprocalRank,
            0.60,
            "MRR regression: \(metrics.meanReciprocalRank)")
        XCTAssertGreaterThanOrEqual(
            metrics.nDCGAtFive,
            0.60,
            "nDCG@5 regression: \(metrics.nDCGAtFive)")
        XCTAssertGreaterThanOrEqual(
            metrics.citationCoverage,
            0.85,
            "Citation coverage regression: \(metrics.citationCoverage)")
        XCTAssertEqual(
            metrics.citationPrecision,
            1.0,
            accuracy: 0.000_001,
            "Retrieved citation provenance was cross-wired")

        let serializedIndexBytes = try KnowledgeJSON.encode(denseFile).count
            + KnowledgeJSON.encode(lexicalFile).count
        let denseMemoryProxyBytes = eligible.count * 512 * MemoryLayout<Float>.stride
        print(
            "[KnowledgeRetrievalQuality] current-host Apple NL: "
                + String(
                    format: "Recall@1=%.3f Recall@5=%.3f MRR=%.3f nDCG@5=%.3f citationCoverage=%.3f citationPrecision=%.3f indexBytes=%d denseMemoryProxyBytes=%d",
                    metrics.recallAtOne,
                    metrics.recallAtFive,
                    metrics.meanReciprocalRank,
                    metrics.nDCGAtFive,
                    metrics.citationCoverage,
                    metrics.citationPrecision,
                    serializedIndexBytes,
                    denseMemoryProxyBytes))
    }
    #else
    func testAppleEnglishHybridRouteMeetsFrozenCorpusGate() async throws {
        throw XCTSkip(
            "NaturalLanguage is not linked on this host; Apple embedding, Intel, "
                + "and real-device retrieval quality remain UNKNOWN.")
    }
    #endif

    func testUnanswerableSentinelsAbstainOnDeterministicLexicalRoute() throws {
        let corpus = try loadCorpus()
        let eligible = try eligibleDocuments(in: corpus)
        let lexical = try KnowledgeBM25Index(
            file: makeLexicalFile(documents: eligible))
        let unanswerable = corpus.queries.filter { !$0.answerable }
        var trueNegatives = 0

        for query in unanswerable {
            let ranking = lexical.search(query: query.text, limit: 5)
            if ranking.isEmpty { trueNegatives += 1 }
            XCTAssertTrue(
                ranking.isEmpty,
                "Out-of-domain sentinel unexpectedly matched indexed evidence: \(query.id) -> \(ranking.map(\.chunkID))")
        }

        let trueNegativeRate = Double(trueNegatives) / Double(unanswerable.count)
        XCTAssertEqual(trueNegativeRate, 1.0, accuracy: 0.000_001)
        print(
            String(
                format: "[KnowledgeRetrievalQuality] unanswerable lexical TNR=%.3f (%d/%d)",
                trueNegativeRate,
                trueNegatives,
                unanswerable.count))
    }

    func testStaleAndDeprecatedDocumentsAreFilteredBeforeRanking() throws {
        let corpus = try loadCorpus()
        let unfiltered = try KnowledgeBM25Index(
            file: makeLexicalFile(documents: corpus.documents))
        let eligible = try eligibleDocuments(in: corpus)
        let filtered = try KnowledgeBM25Index(
            file: makeLexicalFile(documents: eligible))
        let blocked = corpus.documents.filter {
            blockedDocumentIDs(in: corpus).contains($0.id)
        }

        XCTAssertEqual(blocked.count, 2)
        for document in blocked {
            let before = unfiltered.search(query: document.text, limit: 5).map(\.chunkID)
            let after = filtered.search(query: document.text, limit: 5).map(\.chunkID)
            XCTAssertEqual(
                before.first,
                document.id,
                "Blocked decoy must be strong enough to exercise pre-Top-K filtering")
            XCTAssertFalse(
                after.contains(document.id),
                "Blocked document leaked into the eligible ranking: \(document.id)")
        }
        XCTAssertFalse(Set(eligible.map(\.id)).contains("rag-snapshot-deprecated"))
        XCTAssertFalse(Set(eligible.map(\.id)).contains("rag-grounding-stale"))
    }

    func testCitationProvenanceAndPromptInjectionRemainDataOnly() throws {
        let corpus = try loadCorpus()
        let eligible = try eligibleDocuments(in: corpus)
        let documentsByID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        let lexical = try KnowledgeBM25Index(
            file: makeLexicalFile(documents: eligible))

        let injectedQuery = try XCTUnwrap(
            corpus.queries.first(where: \.containsPromptInjection))
        let injectedRanking = lexical.search(
            query: injectedQuery.text,
            limit: 5).map(\.chunkID)
        XCTAssertTrue(
            !Set(injectedRanking).isDisjoint(with: injectedQuery.relevant),
            "Instruction-shaped query text displaced the legitimate retrieval intent")
        let selectedID = try XCTUnwrap(
            injectedRanking.first(where: Set(injectedQuery.relevant).contains))
        let selectedDocument = try XCTUnwrap(documentsByID[selectedID])
        XCTAssertEqual(
            Set(selectedDocument.sourceIDs),
            Set(injectedQuery.expectedSourceIDs))

        let selectedEvidence = makeEvidence(document: selectedDocument, rank: 1)
        let selectedPayload = String(
            decoding: try KnowledgeJSON.encode(KnowledgeSearchResponse.success(
                knowledgeBase: "kb_quality",
                knowledgeBaseRevision: KnowledgeDigest.sha256("quality-bundle"),
                retrievalSnapshot: "snap_quality",
                retrievalSnapshotRevision: KnowledgeDigest.sha256("quality-snapshot"),
                rerankApplied: false,
                truncated: false,
                evidence: [selectedEvidence])),
            as: UTF8.self)
        XCTAssertFalse(selectedPayload.contains("run_shell"))
        XCTAssertFalse(selectedPayload.contains("Ignore previous instructions"))
        XCTAssertFalse(selectedPayload.contains(#"\"role\""#))
        XCTAssertFalse(selectedPayload.contains(#"\"tool_calls\""#))

        let injectionDocument = try XCTUnwrap(
            eligible.first(where: \.containsPromptInjection))
        let injectionRanking = lexical.search(
            query: injectionDocument.text,
            limit: 5).map(\.chunkID)
        XCTAssertEqual(injectionRanking.first, injectionDocument.id)
        let untrustedPayload = String(
            decoding: try KnowledgeJSON.encode(makeEvidence(
                document: injectionDocument,
                rank: 1)),
            as: UTF8.self)
        XCTAssertTrue(untrustedPayload.contains("run_shell"))
        XCTAssertTrue(untrustedPayload.contains("https://example.invalid/execute"))
        XCTAssertFalse(untrustedPayload.contains(#"\"role\""#))
        XCTAssertFalse(untrustedPayload.contains(#"\"tool_calls\""#))
        XCTAssertFalse(untrustedPayload.contains(#"\"executed_url\""#))
        XCTAssertEqual(
            selectedEvidence.textSha256,
            KnowledgeDigest.sha256(selectedDocument.text))
        XCTAssertEqual(selectedEvidence.sourceIDs, selectedDocument.sourceIDs.sorted())
    }

    func testImmutableSnapshotDeletionRemovesDenseLexicalAndEvidenceMappings() throws {
        let corpus = try loadCorpus()
        let currentDocuments = try eligibleDocuments(in: corpus)
        let dimensions = max(32, currentDocuments.count)
        let currentDenseFile = makeSyntheticDenseFile(
            documents: currentDocuments,
            dimensions: dimensions)
        let currentLexicalFile = makeLexicalFile(documents: currentDocuments)
        let currentDense = try KnowledgeDenseIndex(file: currentDenseFile)
        let currentLexical = try KnowledgeBM25Index(file: currentLexicalFile)
        let deletedID = "event-log"
        let deletedVector = try XCTUnwrap(
            currentDenseFile.vectors.first(where: { $0.chunkID == deletedID })?.values)
        XCTAssertEqual(
            try currentDense.search(query: deletedVector, limit: 1).first?.chunkID,
            deletedID)
        XCTAssertEqual(
            currentLexical.search(
                query: "events.jsonl append-only canonical truth",
                limit: 1).first?.chunkID,
            deletedID)

        // An update is a new immutable snapshot: every derived component and
        // active evidence map is projected from the same surviving ID set.
        let nextDocuments = currentDocuments.filter { $0.id != deletedID }
        let nextDenseFile = KnowledgeDenseIndexFile(
            dimensions: dimensions,
            vectors: currentDenseFile.vectors.filter { $0.chunkID != deletedID })
        let nextLexicalFile = KnowledgeLexicalIndexFile(
            tokenizer: currentLexicalFile.tokenizer,
            documents: currentLexicalFile.documents.filter {
                $0.chunkID != deletedID
            })
        let nextEvidenceSources = Dictionary(uniqueKeysWithValues: nextDocuments.map {
            ($0.id, $0.sourceIDs)
        })
        let expectedSurvivors = Set(nextDocuments.map(\.id))

        XCTAssertEqual(Set(nextDenseFile.vectors.map(\.chunkID)), expectedSurvivors)
        XCTAssertEqual(Set(nextLexicalFile.documents.map(\.chunkID)), expectedSurvivors)
        XCTAssertEqual(Set(nextEvidenceSources.keys), expectedSurvivors)
        XCTAssertNil(nextEvidenceSources[deletedID])

        let nextDense = try KnowledgeDenseIndex(file: nextDenseFile)
        let nextLexical = try KnowledgeBM25Index(file: nextLexicalFile)
        XCTAssertFalse(
            try nextDense.search(
                query: deletedVector,
                limit: nextDocuments.count).contains { $0.chunkID == deletedID })
        XCTAssertFalse(
            nextLexical.search(
                query: "events.jsonl append-only canonical truth",
                limit: nextDocuments.count).contains { $0.chunkID == deletedID })

        let controlID = "rag-snapshot"
        let controlVector = try XCTUnwrap(
            nextDenseFile.vectors.first(where: { $0.chunkID == controlID })?.values)
        XCTAssertEqual(
            try nextDense.search(query: controlVector, limit: 1).first?.chunkID,
            controlID)
    }

    func testFrozenCorpusFootprintAndLatencyProxiesStayBounded() throws {
        let corpus = try loadCorpus()
        let documents = try eligibleDocuments(in: corpus)
        let denseFile = makeSyntheticDenseFile(
            documents: documents,
            dimensions: 512)
        let lexicalFile = makeLexicalFile(documents: documents)
        let dense = try KnowledgeDenseIndex(file: denseFile)
        let lexical = try KnowledgeBM25Index(file: lexicalFile)

        let serializedIndexBytes = try KnowledgeJSON.encode(denseFile).count
            + KnowledgeJSON.encode(lexicalFile).count
        let denseMemoryProxyBytes = denseFile.vectors.reduce(0) {
            $0 + $1.values.count * MemoryLayout<Float>.stride
                + $1.chunkID.utf8.count
        }
        let lexicalMemoryProxyBytes = lexicalFile.documents.reduce(0) { total, document in
            total + document.chunkID.utf8.count
                + document.terms.reduce(0) { termTotal, term in
                    termTotal + term.key.utf8.count
                        + MemoryLayout<Int>.stride
                        + 32 // conservative dictionary-entry bookkeeping proxy
                }
        }
        let memoryProxyBytes = denseMemoryProxyBytes + lexicalMemoryProxyBytes

        let iterations = 200
        let started = DispatchTime.now().uptimeNanoseconds
        for offset in 0..<iterations {
            let documentOffset = offset % documents.count
            let queryVector = denseFile.vectors[documentOffset].values
            _ = try dense.search(query: queryVector, limit: 8)
            _ = lexical.search(query: documents[documentOffset].text, limit: 8)
        }
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - started
        let elapsedMilliseconds = Double(elapsedNanoseconds) / 1_000_000
        let averageMilliseconds = elapsedMilliseconds / Double(iterations)

        XCTAssertLessThan(
            serializedIndexBytes,
            2 * 1_024 * 1_024,
            "Frozen quality corpus serialized indexes exceeded 2 MiB")
        XCTAssertLessThan(
            memoryProxyBytes,
            2 * 1_024 * 1_024,
            "Frozen quality corpus deterministic memory proxy exceeded 2 MiB")
        XCTAssertLessThan(
            elapsedMilliseconds,
            10_000,
            "200 exact dense+BM25 searches exceeded the broad host-independent latency gate")
        XCTAssertLessThan(
            averageMilliseconds,
            50,
            "Average exact dense+BM25 proxy latency exceeded 50 ms")

        print(
            String(
                format: "[KnowledgeRetrievalQuality] deterministic proxy: iterations=%d totalMs=%.3f averageMs=%.3f indexBytes=%d memoryProxyBytes=%d (proxy only; Intel/real-device memory and latency remain UNKNOWN)",
                iterations,
                elapsedMilliseconds,
                averageMilliseconds,
                serializedIndexBytes,
                memoryProxyBytes))
    }

    private func loadCorpus() throws -> Corpus {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "retrieval-corpus",
            withExtension: "json",
            subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    private func eligibleDocuments(in corpus: Corpus) throws -> [Corpus.Document] {
        let formatter = ISO8601DateFormatter()
        let evaluationDate = try XCTUnwrap(
            formatter.date(from: corpus.evaluationDate),
            "Invalid frozen evaluationDate")
        return corpus.documents.filter { document in
            guard document.status == "stable" else { return false }
            guard let staleAfter = document.staleAfter else { return true }
            guard let staleDate = formatter.date(from: staleAfter) else { return false }
            return staleDate > evaluationDate
        }.sorted { $0.id < $1.id }
    }

    private func blockedDocumentIDs(in corpus: Corpus) -> [String] {
        let formatter = ISO8601DateFormatter()
        guard let evaluationDate = formatter.date(from: corpus.evaluationDate) else {
            return corpus.documents.map(\.id)
        }
        return corpus.documents.compactMap { document in
            if document.status != "stable" { return document.id }
            guard let staleAfter = document.staleAfter else { return nil }
            guard let staleDate = formatter.date(from: staleAfter) else {
                return document.id
            }
            return staleDate <= evaluationDate ? document.id : nil
        }.sorted()
    }

    private func makeLexicalFile(
        documents: [Corpus.Document]
    ) -> KnowledgeLexicalIndexFile {
        KnowledgeLexicalIndexFile(
            tokenizer: KnowledgeTextTokenizer.identity,
            documents: documents.map { document in
                let tokens = KnowledgeTextTokenizer.tokens(document.text)
                return KnowledgeLexicalDocumentRecord(
                    chunkID: document.id,
                    length: tokens.count,
                    terms: Dictionary(
                        tokens.map { ($0, 1) },
                        uniquingKeysWith: +))
            })
    }

    private func makeSyntheticDenseFile(
        documents: [Corpus.Document],
        dimensions: Int
    ) -> KnowledgeDenseIndexFile {
        precondition(dimensions >= documents.count)
        return KnowledgeDenseIndexFile(
            dimensions: dimensions,
            vectors: documents.enumerated().map { offset, document in
                var vector = Array(repeating: Float(0), count: dimensions)
                vector[offset] = 1
                return KnowledgeDenseVectorRecord(
                    chunkID: document.id,
                    values: vector)
            })
    }

    private func makeEvidence(
        document: Corpus.Document,
        rank: Int
    ) -> KnowledgeSearchEvidence {
        let textDigest = KnowledgeDigest.sha256(document.text)
        let evidenceDigest = KnowledgeDigest.sha256(
            "quality\u{1f}\(document.id)\u{1f}\(textDigest)")
        let evidenceID = "ev_" + evidenceDigest.dropFirst("sha256:".count)
        return KnowledgeSearchEvidence(
            evidenceID: evidenceID,
            rank: rank,
            text: document.text,
            textSha256: textDigest,
            evidenceURI: "knowledge://kb_quality/snap_quality/\(evidenceID)",
            conceptID: "concepts/\(document.id)",
            conceptRevision: textDigest,
            evidenceClass: .exactConceptSlice,
            conceptLocator: KnowledgeConceptLocator(
                start: 0,
                end: Data(document.text.utf8).count),
            supportingConcepts: nil,
            producer: nil,
            sourceIDs: document.sourceIDs.sorted(),
            sourceLocators: nil,
            trust: "human-reviewed",
            status: document.status,
            stale: false)
    }

    private static func nDCG(
        ranking: [String],
        relevant: Set<String>,
        at limit: Int
    ) -> Double {
        guard !relevant.isEmpty else { return 0 }
        let actual = ranking.prefix(limit).enumerated().reduce(0.0) { total, item in
            guard relevant.contains(item.element) else { return total }
            return total + 1.0 / log2(Double(item.offset) + 2.0)
        }
        let idealCount = min(limit, relevant.count)
        let ideal = (0..<idealCount).reduce(0.0) { total, offset in
            total + 1.0 / log2(Double(offset) + 2.0)
        }
        return ideal == 0 ? 0 : actual / ideal
    }
}
