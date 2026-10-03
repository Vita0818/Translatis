import XCTest
import IntatisProtocol
import IntatisTools
@testable import IntatisAgentKernel

final class TurnGroundingEvidenceRegistryTests: XCTestCase {
    private let evidenceID = "ev_fixture"
    private let knowledgeBase = "kb_0123456789abcdef0123456789abcdef"
    private let snapshot = "snap_fixture"
    private let revision = "sha256:" + String(repeating: "a", count: 64)
    private let textDigest = "sha256:e67c6d223f7cc6495f0c65e9adb1aefc235742969c4f537449b2583c2fc71f14"

    func testAcceptsOnlyEvidenceReturnedBySuccessfulCurrentTurnSearch() async throws {
        var registry = TurnGroundingEvidenceRegistry()
        try registry.record(
            toolName: "search_knowledge",
            observation: successfulObservation(),
            revalidator: acceptingRevalidator)

        try await registry.validateCitations(
            in: "Grounded answer [[evidence:\(evidenceID)]]")
        do {
            try await registry.validateCitations(
                in: "Invented [[evidence:ev_not_returned]]")
            XCTFail("invented citation unexpectedly passed")
        } catch {
            XCTAssertEqual(
                error as? TurnGroundingEvidenceRegistry.ValidationError,
                .unknownCitation("ev_not_returned"))
        }
    }

    func testFinalAnswerRequiresCitationAfterSuccessfulSearch() async throws {
        var registry = TurnGroundingEvidenceRegistry()
        try registry.record(
            toolName: "search_knowledge",
            observation: successfulObservation(),
            revalidator: acceptingRevalidator)

        try await registry.validateCitations(
            in: "Continuing with another tool call.",
            requireAtLeastOne: false)
        do {
            try await registry.validateCitations(
                in: "Ungrounded final answer.",
                requireAtLeastOne: true)
            XCTFail("a final answer without current-turn evidence unexpectedly passed")
        } catch {
            XCTAssertEqual(
                error as? TurnGroundingEvidenceRegistry.ValidationError,
                .missingCitation)
        }
    }

    func testNewTurnCannotReusePriorTurnEvidence() async throws {
        var firstTurn = TurnGroundingEvidenceRegistry()
        try firstTurn.record(
            toolName: "search_knowledge",
            observation: successfulObservation(),
            revalidator: acceptingRevalidator)
        try await firstTurn.validateCitations(
            in: "First [[evidence:\(evidenceID)]]")

        let nextTurn = TurnGroundingEvidenceRegistry()
        do {
            try await nextTurn.validateCitations(
                in: "Second [[evidence:\(evidenceID)]]")
            XCTFail("old-turn citation unexpectedly passed")
        } catch {
            XCTAssertEqual(
                error as? TurnGroundingEvidenceRegistry.ValidationError,
                .unknownCitation(evidenceID))
        }
    }

    func testRejectsMalformedCitationAndTamperedEvidenceDigest() async throws {
        let empty = TurnGroundingEvidenceRegistry()
        do {
            try await empty.validateCitations(
                in: "Broken [[evidence:ev_fixture")
            XCTFail("malformed citation unexpectedly passed")
        } catch {
            XCTAssertEqual(
                error as? TurnGroundingEvidenceRegistry.ValidationError,
                .malformedCitation)
        }

        var registry = TurnGroundingEvidenceRegistry()
        XCTAssertThrowsError(try registry.record(
            toolName: "search_knowledge",
            observation: successfulObservation(textDigest: revision),
            revalidator: acceptingRevalidator)) { error in
            guard case .malformedSearchResult? =
                    error as? TurnGroundingEvidenceRegistry.ValidationError else {
                return XCTFail("expected malformed search result, got \(error)")
            }
        }
    }

    func testIgnoresFailureAndInsufficientEvidenceResults() throws {
        var registry = TurnGroundingEvidenceRegistry()
        let failed = MCPStructuredToolResult(
            content: [],
            structuredContent: .object(["status": .string("error")]),
            isError: true)
        try registry.record(
            toolName: "search_knowledge",
            observation: ToolObservation(text: "failed", structuredResult: failed))

        let insufficient = MCPStructuredToolResult(
            content: [],
            structuredContent: .object([
                "status": .string("insufficient_evidence"),
                "evidence": .array([]),
            ]))
        try registry.record(
            toolName: "search_knowledge",
            observation: ToolObservation(
                text: "no evidence",
                structuredResult: insufficient))

        XCTAssertTrue(registry.bindings.isEmpty)
    }

    func testFinalCitationFailsWhenMechanicalRevalidationDetectsDrift() async throws {
        var registry = TurnGroundingEvidenceRegistry()
        try registry.record(
            toolName: "search_knowledge",
            observation: successfulObservation(),
            revalidator: { _ in
                throw NSError(domain: "fixture-drift", code: 1)
            })

        do {
            try await registry.validateCitations(
                in: "Changed [[evidence:\(evidenceID)]]")
            XCTFail("drifted evidence unexpectedly passed final validation")
        } catch {
            XCTAssertEqual(
                error as? TurnGroundingEvidenceRegistry.ValidationError,
                .evidenceChanged(evidenceID))
        }
    }

    func testRepeatedStableEvidenceIsIdempotentButChangedBindingIsRejected() async throws {
        var registry = TurnGroundingEvidenceRegistry()
        try registry.record(
            toolName: "search_knowledge",
            observation: successfulObservation(),
            revalidator: acceptingRevalidator)
        try registry.record(
            toolName: "search_knowledge",
            observation: successfulObservation(),
            revalidator: acceptingRevalidator)
        XCTAssertEqual(registry.bindings.count, 1)
        try await registry.validateCitations(
            in: "Repeated [[evidence:\(evidenceID)]]")

        let changedRevision = "sha256:" + String(repeating: "b", count: 64)
        XCTAssertThrowsError(try registry.record(
            toolName: "search_knowledge",
            observation: successfulObservation(
                retrievalSnapshotRevision: changedRevision),
            revalidator: acceptingRevalidator)) { error in
            guard case .malformedSearchResult? =
                    error as? TurnGroundingEvidenceRegistry.ValidationError else {
                return XCTFail("expected changed stable binding, got \(error)")
            }
        }
    }

    private var acceptingRevalidator: ToolGroundingEvidenceRevalidator {
        { _ in }
    }

    private func successfulObservation(
        textDigest: String? = nil,
        retrievalSnapshotRevision: String? = nil
    ) -> ToolObservation {
        let digest = textDigest ?? self.textDigest
        let snapshotRevision = retrievalSnapshotRevision ?? revision
        let evidenceURI =
            "knowledge://\(knowledgeBase)/\(snapshot)/\(evidenceID)"
        let response: JSONValue = .object([
            "status": .string("ok"),
            "knowledge_base": .string(knowledgeBase),
            "knowledge_base_revision": .string(revision),
            "retrieval_snapshot": .string(snapshot),
            "retrieval_snapshot_revision": .string(snapshotRevision),
            "rerank_applied": .bool(false),
            "truncated": .bool(false),
            "evidence": .array([
                .object([
                    "evidence_id": .string(evidenceID),
                    "rank": .number(1),
                    "text": .string("verified evidence"),
                    "text_sha256": .string(digest),
                    "evidence_uri": .string(evidenceURI),
                    "source_ids": .array([.string("source-fixture")]),
                ]),
            ]),
        ])
        return ToolObservation(
            text: "bounded projection",
            structuredResult: MCPStructuredToolResult(
                content: [
                    MCPContentBlock(kind: .structuredJSON, structuredJSON: response),
                ],
                structuredContent: response,
                isError: false))
    }
}
