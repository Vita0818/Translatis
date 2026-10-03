import Foundation
import XCTest
@testable import IntatisMCP

private struct MCPServerContributorFixture: MCPServerContributor {
    let batch: MCPServerContributionBatch

    func serverDefinitionProposals() async throws
        -> MCPServerContributionBatch {
        batch
    }
}

final class MCPServerContributorTests: XCTestCase {
    func testContributorCanOnlyReturnReviewableProposalDocuments() async throws {
        let document = try MCPServerContributionDocument(
            documentID: "primary",
            format: .mcpJSON,
            sourceLabel: "fixture.mcp.json",
            bytes: Data(
                """
                {"mcpServers":{"remote":{"type":"http","url":"https://example.com/mcp"}}}
                """.utf8))
        let contributor = MCPServerContributorFixture(
            batch: try MCPServerContributionBatch(
                contributorID: "fixture.contributor",
                documents: [document]))

        let reviews = try await MCPServerContributorReviewer.review(
            contributor)
        let review = try XCTUnwrap(reviews.first)
        XCTAssertEqual(reviews.count, 1)
        XCTAssertEqual(review.contributorID, "fixture.contributor")
        XCTAssertEqual(review.documentID, "primary")
        XCTAssertTrue(review.preview.canProceedToResolution)
        let proposal = try XCTUnwrap(review.preview.proposals.first)
        XCTAssertEqual(
            proposal.provenance.sourceKind,
            .contributorProposal)
        XCTAssertEqual(
            proposal.provenance.sourceFingerprint,
            review.preview.sourceFingerprint)
        XCTAssertTrue(
            proposal.proposalID.hasPrefix("mcpcontributorproposal_"))
        XCTAssertTrue(
            proposal.serverID.rawValue.hasPrefix("mcpcontributor_"))

        let marker = try review.importMarker()
        XCTAssertEqual(marker.sourceKind, .contributorProposal)
        XCTAssertEqual(
            marker.sourceFingerprint,
            review.preview.sourceFingerprint)
        XCTAssertEqual(marker.importedServerIDs, [proposal.serverID])
        let plan = try MCPImportPlanner.plan(
            preview: review.preview,
            catalog: .empty)
        XCTAssertEqual(plan.proposalsWithoutConflicts, [proposal])
    }

    func testContributorSecretMaterialIsErasedAndCannotEnterPlanning()
        async throws {
        let secret = "sk-contributor-must-not-migrate"
        let batch = try MCPServerContributionBatch(
            contributorID: "fixture.contributor",
            documents: [
                try MCPServerContributionDocument(
                    documentID: "secret",
                    format: .claudeJSON,
                    sourceLabel: "secret.claude.json",
                    bytes: Data(
                        """
                        {"mcpServers":{"remote":{"type":"http","url":"https://example.com/mcp","bearer_token":"\(secret)"}}}
                        """.utf8)),
            ])

        let reviews =
            try await MCPServerContributorReviewer.review(batch)
        let review = try XCTUnwrap(reviews.first)
        XCTAssertFalse(review.preview.canProceedToResolution)
        XCTAssertTrue(review.preview.proposals.isEmpty)
        XCTAssertTrue(review.preview.secretDescriptors.isEmpty)
        XCTAssertEqual(
            review.preview.issues.map(\.code),
            [.contributorSecretMaterial])
        XCTAssertEqual(
            review.preview.issues.map(\.path),
            ["$.mcpServers.remote.bearer_token"])
        XCTAssertThrowsError(try MCPImportPlanner.plan(
            preview: review.preview,
            catalog: .empty))
        XCTAssertThrowsError(try review.importMarker()) {
            XCTAssertEqual(
                $0 as? MCPImportError,
                .previewHasBlockingIssues)
        }
    }

    func testPrivateHostSemanticsRemainBlockingInContributorReview()
        async throws {
        let batch = try MCPServerContributionBatch(
            contributorID: "fixture.contributor",
            documents: [
                try MCPServerContributionDocument(
                    documentID: "private",
                    format: .mcpJSON,
                    sourceLabel: "private.mcp.json",
                    bytes: Data(
                        """
                        {"mcpServers":{"remote":{"type":"http","url":"https://example.com/mcp","hostedApp":{"id":"private"}}}}
                        """.utf8)),
            ])
        let reviews =
            try await MCPServerContributorReviewer.review(batch)
        let review = try XCTUnwrap(reviews.first)
        XCTAssertFalse(review.preview.canProceedToResolution)
        XCTAssertTrue(review.preview.issues.contains {
            $0.code == .unsupportedPrivateSemantics
                && $0.path == "$.mcpServers.remote.hostedApp"
        })
    }

    func testContributionBatchRejectsDuplicateAndOversizedDocuments()
        throws {
        let document = try MCPServerContributionDocument(
            documentID: "same",
            format: .mcpJSON,
            sourceLabel: "fixture.mcp.json",
            bytes: Data(
                #"{"mcpServers":{"one":{"command":"/usr/bin/true"}}}"#.utf8))
        XCTAssertThrowsError(try MCPServerContributionBatch(
            contributorID: "fixture.contributor",
            documents: [document, document])) {
                XCTAssertEqual(
                    $0 as? MCPServerContributorError,
                    .duplicateDocumentID)
            }
        XCTAssertThrowsError(try MCPServerContributionBatch(
            contributorID: "fixture.contributor",
            documents: [])) {
                XCTAssertEqual(
                    $0 as? MCPServerContributorError,
                    .invalidDocumentCount)
            }
        XCTAssertThrowsError(try MCPServerContributionDocument(
            documentID: "oversized",
            format: .mcpJSON,
            sourceLabel: "fixture.mcp.json",
            bytes: Data(
                repeating: 0,
                count: MCPConfigurationImporter.maximumSourceBytes + 1))) {
                    XCTAssertEqual(
                        $0 as? MCPServerContributorError,
                        .invalidDocument)
                }
    }

    func testContributorIdentityBindsProposalAndMarkerFingerprints()
        async throws {
        let document = try MCPServerContributionDocument(
            documentID: "same",
            format: .mcpJSON,
            sourceLabel: "fixture.mcp.json",
            bytes: Data(
                """
                {"mcpServers":{"remote":{"type":"http","url":"https://example.com/mcp"}}}
                """.utf8))
        let first = try MCPServerContributionBatch(
            contributorID: "contributor.one",
            documents: [document])
        let second = try MCPServerContributionBatch(
            contributorID: "contributor.two",
            documents: [document])

        let firstReviews =
            try await MCPServerContributorReviewer.review(first)
        let secondReviews =
            try await MCPServerContributorReviewer.review(second)
        let firstReview = try XCTUnwrap(firstReviews.first)
        let secondReview = try XCTUnwrap(secondReviews.first)
        XCTAssertNotEqual(
            firstReview.preview.sourceFingerprint,
            secondReview.preview.sourceFingerprint)
        XCTAssertNotEqual(
            firstReview.preview.proposals.first?.serverID,
            secondReview.preview.proposals.first?.serverID)
    }
}
