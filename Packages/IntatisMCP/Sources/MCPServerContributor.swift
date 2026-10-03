#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisMCP requires CryptoKit or swift-crypto")
#endif
import Foundation
import IntatisCore
import IntatisProtocol

/// A bounded, fixed-format document containing server-definition proposals.
///
/// The bytes are intentionally not Codable and are not exposed after
/// construction. A contributor can only hand them to the host review pipeline;
/// this type has no catalog, transport, credential, or authorization capability.
public struct MCPServerContributionDocument: Equatable, Sendable {
    public static let maximumSourceLabelBytes = 128

    public let documentID: String
    public let format: MCPImportFormat
    public let sourceLabel: String
    fileprivate let bytes: Data

    public init(
        documentID: String,
        format: MCPImportFormat,
        sourceLabel: String,
        bytes: Data
    ) throws {
        try MCPConfigurationValidation.validateIdentifier(
            documentID,
            field: "contribution_document_id")
        let safeLabel = (sourceLabel as NSString).lastPathComponent
        guard safeLabel == sourceLabel,
              (1...Self.maximumSourceLabelBytes)
                .contains(safeLabel.utf8.count),
              !safeLabel.contains("\0"),
              bytes.count <= MCPConfigurationImporter.maximumSourceBytes else {
            throw MCPServerContributorError.invalidDocument
        }
        self.documentID = documentID
        self.format = format
        self.sourceLabel = safeLabel
        self.bytes = bytes
    }
}

/// One atomic response from a provider-neutral host extension.
///
/// The batch is only proposal data. It cannot install software, mutate the
/// global catalog, start a process, open a network connection, authenticate, or
/// grant an MCP capability.
public struct MCPServerContributionBatch: Equatable, Sendable {
    public static let maximumDocuments = 32
    public static let maximumTotalBytes =
        MCPConfigurationImporter.maximumSourceBytes

    public let contributorID: String
    public let documents: [MCPServerContributionDocument]

    public init(
        contributorID: String,
        documents: [MCPServerContributionDocument]
    ) throws {
        do {
            try MCPConfigurationValidation.validateIdentifier(
                contributorID,
                field: "contributor_id")
        } catch {
            throw MCPServerContributorError.invalidContributor
        }
        guard !documents.isEmpty,
              documents.count <= Self.maximumDocuments else {
            throw MCPServerContributorError.invalidDocumentCount
        }
        guard Set(documents.map(\.documentID)).count == documents.count else {
            throw MCPServerContributorError.duplicateDocumentID
        }
        var total = 0
        for document in documents {
            let (next, overflow) =
                total.addingReportingOverflow(document.bytes.count)
            guard !overflow, next <= Self.maximumTotalBytes else {
                throw MCPServerContributorError.totalSourceTooLarge
            }
            total = next
        }
        self.contributorID = contributorID
        self.documents = documents
    }
}

/// Provider-neutral proposal source. The only value returned to Intatis is a
/// bounded batch of review documents; no privileged host service is passed in.
public protocol MCPServerContributor: Sendable {
    func serverDefinitionProposals() async throws
        -> MCPServerContributionBatch
}

/// Host-reviewed contribution. `preview` can enter the existing explicit
/// conflict-resolution pipeline, while `importMarker()` preserves contributor
/// provenance if the user later completes Test-before-save.
public struct MCPServerContributionReview: Sendable {
    public let contributorID: String
    public let documentID: String
    public let preview: MCPImportPreview

    fileprivate init(
        contributorID: String,
        documentID: String,
        preview: MCPImportPreview
    ) {
        self.contributorID = contributorID
        self.documentID = documentID
        self.preview = preview
    }

    public func importMarker() throws -> MCPImportMarker {
        guard preview.canProceedToResolution else {
            throw MCPImportError.previewHasBlockingIssues
        }
        return try MCPImportMarker(
            sourceKind: .contributorProposal,
            sourceFingerprint: preview.sourceFingerprint,
            formatVersion: preview.parserVersion,
            importedServerIDs: preview.proposals.map(\.serverID))
    }
}

public enum MCPServerContributorError:
    Error, LocalizedError, Equatable, Sendable {
    case invalidContributor
    case invalidDocument
    case invalidDocumentCount
    case duplicateDocumentID
    case totalSourceTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidContributor:
            return "The MCP contributor identifier is invalid."
        case .invalidDocument:
            return "An MCP contribution document is invalid."
        case .invalidDocumentCount:
            return "An MCP contribution batch must contain a bounded, non-empty document set."
        case .duplicateDocumentID:
            return "An MCP contribution batch contains a duplicate document identifier."
        case .totalSourceTooLarge:
            return "The MCP contribution batch exceeds the bounded source size."
        }
    }
}

/// Converts contributor output into the same fixed parser and conflict-review
/// model used by explicit file imports. Inline secret material is never exposed
/// to a secret sink: it is erased from staging and leaves only blocking,
/// path-only issues in the review.
public enum MCPServerContributorReviewer {
    public static func review(
        _ contributor: any MCPServerContributor
    ) async throws -> [MCPServerContributionReview] {
        try await review(
            try await contributor.serverDefinitionProposals())
    }

    public static func review(
        _ batch: MCPServerContributionBatch
    ) async throws -> [MCPServerContributionReview] {
        var reviews: [MCPServerContributionReview] = []
        reviews.reserveCapacity(batch.documents.count)
        for document in batch.documents {
            let parsed = try MCPConfigurationImporter.parse(
                data: document.bytes,
                format: document.format,
                sourceLabel: document.sourceLabel)
            await parsed.secretStaging.discard()

            let sourceFingerprint = contributorSourceFingerprint(
                contributorID: batch.contributorID,
                documentID: document.documentID,
                contentFingerprint: parsed.preview.sourceFingerprint)
            let secretIssues = parsed.preview.secretDescriptors.map {
                MCPImportIssue(
                    code: .contributorSecretMaterial,
                    path: $0.fieldPath)
            }
            let proposals: [MCPImportedServerProposal]
            if secretIssues.isEmpty {
                proposals = try parsed.preview.proposals.map {
                    try contributorProposal(
                        from: $0,
                        sourceLabel: document.sourceLabel,
                        sourceFingerprint: sourceFingerprint)
                }
            } else {
                // Never hand a proposal containing pending secret material to
                // planning or resolution, even though the issues are blocking.
                proposals = []
            }
            let preview = MCPImportPreview(
                format: parsed.preview.format,
                parserVersion: parsed.preview.parserVersion,
                sourceLabel: parsed.preview.sourceLabel,
                sourceFingerprint: sourceFingerprint,
                proposals: proposals,
                issues: (parsed.preview.issues + secretIssues).sorted {
                    if $0.path != $1.path { return $0.path < $1.path }
                    return $0.code.rawValue < $1.code.rawValue
                },
                secretDescriptors: [])
            reviews.append(MCPServerContributionReview(
                contributorID: batch.contributorID,
                documentID: document.documentID,
                preview: preview))
        }
        return reviews
    }

    private static func contributorSourceFingerprint(
        contributorID: String,
        documentID: String,
        contentFingerprint: String
    ) -> String {
        MCPConfigurationCanonical.sha256(Data(
            """
            \(IntatisHostApplication.identity.namespacedIdentifier("mcp.contributor.v1"))\u{1f}\(contributorID)\u{1f}\(documentID)\u{1f}\(contentFingerprint)
            """.utf8))
    }

    private static func contributorProposal(
        from proposal: MCPImportedServerProposal,
        sourceLabel: String,
        sourceFingerprint: String
    ) throws -> MCPImportedServerProposal {
        let proposalDigest = MCPConfigurationCanonical.sha256(Data(
            """
            \(sourceFingerprint)\u{1f}\(proposal.alias)
            """.utf8))
        return MCPImportedServerProposal(
            proposalID: "mcpcontributorproposal_\(proposalDigest.prefix(24))",
            alias: proposal.alias,
            serverID: MCPServerID(
                rawValue: "mcpcontributor_\(proposalDigest.prefix(24))"),
            displayName: proposal.displayName,
            enabled: proposal.enabled,
            required: proposal.required,
            approvalPolicy: proposal.approvalPolicy,
            parallelCalls: proposal.parallelCalls,
            timeouts: proposal.timeouts,
            filters: proposal.filters,
            transport: proposal.transport,
            provenance: try MCPConfigurationProvenance(
                sourceKind: .contributorProposal,
                sourceLabel: sourceLabel,
                formatVersion: MCPConfigurationImporter.parserVersion,
                sourceFingerprint: sourceFingerprint))
    }
}
