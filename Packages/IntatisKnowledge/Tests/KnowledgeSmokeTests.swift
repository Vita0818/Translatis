import XCTest
@testable import IntatisKnowledge

final class KnowledgeSmokeTests: XCTestCase {
    func testContractVersionIsPinned() {
        XCTAssertEqual(KnowledgeContract.profileVersion, "0.1")
    }

    func testDenseIndexRejectsNonUnitNonFiniteWrongAndDuplicateVectors() throws {
        let invalidVectors: [[KnowledgeDenseVectorRecord]] = [
            [KnowledgeDenseVectorRecord(chunkID: "zero", values: [0, 0])],
            [KnowledgeDenseVectorRecord(chunkID: "scaled", values: [2, 0])],
            [KnowledgeDenseVectorRecord(chunkID: "nan", values: [.nan, 0])],
            [KnowledgeDenseVectorRecord(chunkID: "infinity", values: [.infinity, 0])],
            [KnowledgeDenseVectorRecord(chunkID: "wrong", values: [1])],
            [
                KnowledgeDenseVectorRecord(chunkID: "duplicate", values: [1, 0]),
                KnowledgeDenseVectorRecord(chunkID: "duplicate", values: [0, 1]),
            ],
        ]
        for vectors in invalidVectors {
            XCTAssertThrowsError(try KnowledgeDenseIndex(
                file: KnowledgeDenseIndexFile(
                    dimensions: 2,
                    vectors: vectors)))
        }
    }

    func testDenseQueryAppliesFrozenL2NormalizationAndRejectsZero() throws {
        let index = try KnowledgeDenseIndex(file: KnowledgeDenseIndexFile(
            dimensions: 2,
            vectors: [
                KnowledgeDenseVectorRecord(chunkID: "x", values: [1, 0]),
                KnowledgeDenseVectorRecord(chunkID: "y", values: [0, 1]),
            ]))
        let ranking = try index.search(query: [10, 0], limit: 2)
        XCTAssertEqual(ranking.map(\.chunkID), ["x", "y"])
        XCTAssertEqual(ranking[0].score, 1, accuracy: 0.000_001)
        XCTAssertEqual(ranking[1].score, 0, accuracy: 0.000_001)
        XCTAssertThrowsError(try index.search(query: [0, 0], limit: 2))
    }

    func testLexicalIndexRejectsDuplicateMissingAndInvalidDocuments() throws {
        let valid = KnowledgeLexicalDocumentRecord(
            chunkID: "chunk-one",
            length: 1,
            terms: ["term": 1])
        let invalidFiles = [
            KnowledgeLexicalIndexFile(tokenizer: "wrong", documents: [valid]),
            KnowledgeLexicalIndexFile(
                tokenizer: KnowledgeTextTokenizer.identity,
                documents: []),
            KnowledgeLexicalIndexFile(
                tokenizer: KnowledgeTextTokenizer.identity,
                documents: [valid, valid]),
            KnowledgeLexicalIndexFile(
                tokenizer: KnowledgeTextTokenizer.identity,
                documents: [KnowledgeLexicalDocumentRecord(
                    chunkID: "zero-length",
                    length: 0,
                    terms: ["term": 1])]),
            KnowledgeLexicalIndexFile(
                tokenizer: KnowledgeTextTokenizer.identity,
                documents: [KnowledgeLexicalDocumentRecord(
                    chunkID: "zero-term",
                    length: 1,
                    terms: ["term": 0])]),
        ]
        for file in invalidFiles {
            XCTAssertThrowsError(try KnowledgeBM25Index(file: file))
        }
    }
}
