import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisTools
@testable import IntatisKnowledge

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class KnowledgeBundleBuildServiceTests: XCTestCase {
    func testExistingStoreUpdateRequiresExactCurrentStoreAndSnapshotCAS() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        let provider = CountingBuildEmbeddingProvider()
        let service = try KnowledgeBundleBuildService(
            embeddingProvider: provider)
        let first = try await service.buildAndPublish(fixture.request())
        let requestsAfterFirst = await provider.requestTextCount()

        do {
            _ = try await service.buildAndPublish(
                fixture.request(expectedStoreID: first.storeID))
            XCTFail("an update without expected_snapshot_id must fail")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .toolInputInvalid)
        }
        let requestsAfterMissingSnapshot = await provider.requestTextCount()
        XCTAssertEqual(requestsAfterMissingSnapshot, requestsAfterFirst)

        do {
            _ = try await service.buildAndPublish(fixture.request(
                expectedStoreID: first.storeID,
                expectedSnapshotID: "snap_stale"))
            XCTFail("a stale snapshot CAS must fail")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .revisionChanged)
            XCTAssertTrue(error.failure.retryable)
        }
        let requestsAfterStaleSnapshot = await provider.requestTextCount()
        XCTAssertEqual(requestsAfterStaleSnapshot, requestsAfterFirst)
    }

    func testPublishesCompleteSnapshotAndReusesUnchangedEmbeddings() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        let provider = CountingBuildEmbeddingProvider()
        let service = try KnowledgeBundleBuildService(
            embeddingProvider: provider,
            now: { Date(timeIntervalSince1970: 1_786_233_600) })

        let first = try await service.buildAndPublish(fixture.request())
        XCTAssertEqual(first.storeRevision, 1)
        XCTAssertEqual(first.vectorCount, first.chunkCount)
        XCTAssertEqual(first.embeddedVectorCount, first.chunkCount)
        XCTAssertEqual(first.reusedVectorCount, 0)
        XCTAssertGreaterThan(first.embeddingRequestTextCount, 0)
        let firstRequestCount = await provider.requestTextCount()
        XCTAssertEqual(firstRequestCount, first.embeddingRequestTextCount)

        let store = try KnowledgeSnapshotStore(
            root: fixture.store,
            workspaceLease: fixture.workspaceLease)
        let oldReader = try store.acquireCurrentReaderLease()
        defer { oldReader.release() }
        XCTAssertEqual(oldReader.pointer.currentSnapshot, first.snapshotID)

        let second = try await service.buildAndPublish(
            fixture.request(
                expectedStoreID: first.storeID,
                expectedSnapshotID: first.snapshotID))
        XCTAssertEqual(second.storeID, first.storeID)
        XCTAssertEqual(second.storeRevision, 2)
        XCTAssertNotEqual(second.snapshotID, first.snapshotID)
        XCTAssertEqual(second.reusedVectorCount, second.chunkCount)
        XCTAssertEqual(second.embeddedVectorCount, 0)
        XCTAssertEqual(second.embeddingRequestTextCount, 0)
        let secondRequestCount = await provider.requestTextCount()
        XCTAssertEqual(secondRequestCount, firstRequestCount)

        let current = try store.loadCurrentPointer()
        XCTAssertEqual(current.currentSnapshot, second.snapshotID)
        XCTAssertEqual(current.currentSnapshotRevision, second.snapshotRevision)
        XCTAssertNoThrow(try oldReader.verifyStable())
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldReader.snapshotRoot.path))

        let secondRoot = fixture.store
            .appendingPathComponent(
                KnowledgeSnapshotStore.publishedSnapshotsDirectoryName,
                isDirectory: true)
            .appendingPathComponent(second.snapshotID, isDirectory: true)
        let validated = try KnowledgeValidator().validateSnapshot(
            at: secondRoot,
            mode: .mount,
            policy: KnowledgeValidationPolicy(
                evaluationDate: "2026-08-09T00:00:00Z",
                trustedVerificationActors: ["human:test"]),
            workspaceLease: fixture.workspaceLease)
        XCTAssertEqual(validated.profile.bundle.revision, second.bundleRevision)
        XCTAssertEqual(validated.denseFile.vectors.count, second.vectorCount)
        XCTAssertEqual(validated.lexicalFile?.documents.count, second.chunkCount)
    }

    func testCanonicalV02WriterDiscoversWholeTreeAndOwnsPortableSourceIdentity() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        try fixture.removeDraft(relativePath: "concepts/publication.md")
        let localSource = fixture.draft
            .appendingPathComponent("references/source.txt").absoluteString
        try fixture.replaceDraft(
            relativePath: "root-policy.md",
            text: """
            ---
            type: Policy
            title: Root policy
            timestamp: "2026-08-01T00:00:00Z"
            sources:
              - id: proposed-/Users/private/source
                resource: "\(localSource)"
            verified: { by: human:test, at: "2026-08-09T00:00:00Z" }
            status: stable
            ---

            # Root rule

            Canonical root evidence remains attributable.[^proposed-/Users/private/source]

            [^proposed-/Users/private/source]: proposed local source

            # Citations
            - https://legacy.example.invalid/raw
            """)
        try fixture.replaceDraft(
            relativePath: "domain/references/nested.txt",
            text: "Nested immutable source bytes.\n")
        try fixture.replaceDraft(
            relativePath: "domain/policies/refund.md",
            text: """
            ---
            type: Policy
            title: Nested policy
            sources:
              - id: model-nested
                resource: ../references/nested.txt
            verified: { by: human:test, at: "2026-08-09T00:00:00Z" }
            status: stable
            ---

            # Nested rule

            Nested references are a convention at any hierarchy depth and remain grounded.
            """)
        try fixture.replaceDraft(
            relativePath: "scope.md",
            text: """
            ---
            type: Reference
            title: Scope descriptor
            sources:
              - resource: all rows in dataset/project X
            verified: { by: human:test, at: "2026-08-09T00:00:00Z" }
            status: stable
            ---

            # Scope rule

            A population descriptor is provenance but is never fabricated into a file locator.
            """)
        try fixture.replaceDraft(
            relativePath: "domain/index.md",
            text: """
            # Domain knowledge

            * [Nested policy](policies/refund.md) - nested policy
            """)
        try fixture.replaceDraft(
            relativePath: "domain/log.md",
            text: """
            # Domain Update Log

            ## 2026-08-09
            * **Creation**: Added the nested policy.

            ## 2026-08-08
            * **Initialization**: Created the domain scope.
            """)

        let provider = CountingBuildEmbeddingProvider()
        let result = try await KnowledgeBundleBuildService(
            embeddingProvider: provider,
            now: { Date(timeIntervalSince1970: 1_786_233_600) })
            .buildAndPublish(fixture.request())
        let snapshot = try KnowledgeValidator().validateSnapshot(
            at: fixture.snapshotRoot(result),
            mode: .mount,
            policy: fixture.validationPolicy,
            workspaceLease: fixture.workspaceLease)
        XCTAssertEqual(Set(snapshot.concepts.keys), Set([
            "domain/policies/refund", "root-policy", "scope",
        ]))

        let rootConcept = try XCTUnwrap(snapshot.concepts["root-policy"])
        let rootSource = try XCTUnwrap(rootConcept.sources.first)
        let canonicalID = OKFCanonicalWriter.canonicalSourceID(
            resource: "/references/source.txt")
        XCTAssertEqual(rootSource.id, canonicalID)
        XCTAssertEqual(rootSource.resource, "/references/source.txt")
        XCTAssertEqual(rootConcept.generatedAt, "2026-08-01T00:00:00Z")
        XCTAssertNil(rootConcept.legacyTimestamp)
        XCTAssertFalse(rootConcept.normalizedText.contains("# Citations"))
        XCTAssertTrue(rootConcept.body.contains("[^\(canonicalID)]"))
        XCTAssertTrue(rootConcept.body.contains("[^\(canonicalID)]:"))
        XCTAssertFalse(rootConcept.normalizedText.contains("proposed-/Users"))

        let nested = try XCTUnwrap(snapshot.concepts["domain/policies/refund"])
        XCTAssertEqual(
            nested.sources.first?.resource,
            "/domain/references/nested.txt")
        let scope = try XCTUnwrap(snapshot.concepts["scope"])
        XCTAssertTrue(scope.sources.first?.resource.hasPrefix(
            "urn:intatis:scope:") == true)
        XCTAssertEqual(
            scope.sources.first?.title,
            "all rows in dataset/project X")

        let rootIndex = String(decoding: try fixture.snapshotData(
            result,
            relativePath: "index.md"), as: UTF8.self)
        XCTAssertTrue(rootIndex.contains("okf_version: \"0.2\""))
        XCTAssertFalse(rootIndex.contains("type: Index"))
        for entry in try KnowledgeSecureFileSystem().leafInventory(
            root: fixture.snapshotRoot(result)) {
            let text = String(decoding: try fixture.snapshotData(
                result,
                relativePath: entry.path), as: UTF8.self)
            XCTAssertFalse(text.contains(fixture.root.path))
            XCTAssertFalse(text.contains("/Users/private"))
        }
    }

    func testCanonicalWriterRejectsPrivateSourceMetadataBeforeEmbedding() async throws {
        let privateResources = [
            "file:///Users/private/secret.pdf",
            "https://example.invalid/?path=%2FUsers%2Fprivate%2Fsecret.pdf",
            "https://example.invalid/?path=%252FUsers%252Fprivate%252Fsecret.pdf",
            "https://example.invalid/?path=%25252FUsers%25252Fprivate%25252Fsecret.pdf",
        ]
        for privateResource in privateResources {
            let fixture = try BuildFixture()
            defer { fixture.cleanup() }
            try fixture.replaceDraft(
                relativePath: "concepts/publication.md",
                text: """
                ---
                type: Policy
                title: Private source refusal
                sources:
                  - id: proposed
                    resource: "\(privateResource)"
                verified: { by: human:test, at: "2026-08-09T00:00:00Z" }
                status: stable
                ---

                # Rule

                A private source path must never enter portable knowledge bytes.
                """)
            let provider = CountingBuildEmbeddingProvider()
            do {
                _ = try await KnowledgeBundleBuildService(
                    embeddingProvider: provider).buildAndPublish(fixture.request())
                XCTFail("private source path unexpectedly published")
            } catch let error as KnowledgeDomainError {
                XCTAssertEqual(error.failure.code, .accessDenied)
                XCTAssertFalse(error.failure.message.contains("/Users/private"))
                XCTAssertFalse(error.failure.message.contains("%2FUsers"))
            }
            let requestCount = await provider.requestTextCount()
            XCTAssertEqual(requestCount, 0)
            XCTAssertFalse(fixture.hasActivePointer)
        }
    }

    func testCanonicalWriterRejectsIncompleteGeneratedMetadataBeforeEmbedding() async throws {
        let invalidGenerated = [
            "generated: process:intatis",
            "generated: { at: '2026-08-09T00:00:00Z' }",
            "generated: { by: process:intatis }",
            "generated: { by: '', at: '2026-08-09T00:00:00Z' }",
            "generated: { by: process:intatis, at: not-a-time }",
        ]
        for generated in invalidGenerated {
            let fixture = try BuildFixture()
            defer { fixture.cleanup() }
            try fixture.replaceDraft(
                relativePath: "concepts/publication.md",
                text: """
                ---
                type: Policy
                title: Invalid generated metadata
                \(generated)
                sources:
                  - id: publication-source
                    resource: ../references/source.txt
                status: stable
                ---

                # Rule

                Generated provenance must be complete before indexing.
                """)
            let provider = CountingBuildEmbeddingProvider()
            do {
                _ = try await KnowledgeBundleBuildService(
                    embeddingProvider: provider).buildAndPublish(
                        fixture.request())
                XCTFail("incomplete generated metadata unexpectedly published")
            } catch let domain as KnowledgeDomainError {
                XCTAssertEqual(domain.failure.code, .okfInvalid)
                XCTAssertFalse(domain.failure.message.contains(generated))
            }
            let requestCount = await provider.requestTextCount()
            XCTAssertEqual(requestCount, 0)
            XCTAssertFalse(fixture.hasActivePointer)
        }
    }

    func testCanonicalWriterRejectsInconsistentFootnoteAttributionBeforeEmbedding() async throws {
        let invalidBodies = [
            "A claim uses an unknown source.[^unknown]\n\n[^unknown]: Unknown source.",
            "A claim has no definition.[^publication-source]",
            "An orphan definition follows.\n\n[^publication-source]: Never cited.",
        ]
        for body in invalidBodies {
            let fixture = try BuildFixture()
            defer { fixture.cleanup() }
            try fixture.replaceDraft(
                relativePath: "concepts/publication.md",
                text: """
                ---
                type: Policy
                title: Invalid source attribution
                sources:
                  - id: publication-source
                    resource: ../references/source.txt
                status: stable
                ---

                # Rule

                \(body)
                """)
            let provider = CountingBuildEmbeddingProvider()
            do {
                _ = try await KnowledgeBundleBuildService(
                    embeddingProvider: provider).buildAndPublish(
                        fixture.request())
                XCTFail("inconsistent footnote attribution unexpectedly published")
            } catch let domain as KnowledgeDomainError {
                XCTAssertEqual(domain.failure.code, .okfInvalid)
                XCTAssertFalse(domain.failure.message.contains("publication-source"))
                XCTAssertFalse(domain.failure.message.contains("unknown"))
            }
            let requestCount = await provider.requestTextCount()
            XCTAssertEqual(requestCount, 0)
            XCTAssertFalse(fixture.hasActivePointer)
        }
    }

    func testMultiSourceChunksUseExplicitFootnotesInsteadOfAllSources() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        try fixture.replaceDraft(
            relativePath: "references/secondary.txt",
            text: "Secondary immutable source bytes.\n")
        try fixture.replaceDraft(
            relativePath: "concepts/publication.md",
            text: """
            ---
            type: Policy
            title: Explicit multi-source attribution
            sources:
              - id: primary-source
                resource: ../references/source.txt
              - id: secondary-source
                resource: ../references/secondary.txt
            status: stable
            ---

            # Rules

            The primary claim is grounded only in its first source.[^primary-source]

            The secondary claim is grounded only in its second source.[^secondary-source]

            This ambiguous multi-source paragraph has no attribution and must not become grounded evidence.

            [^primary-source]: Primary immutable source.

            [^secondary-source]: Secondary immutable source.
            """)

        let result = try await KnowledgeBundleBuildService(
            embeddingProvider: CountingBuildEmbeddingProvider())
            .buildAndPublish(fixture.request())
        let snapshot = try KnowledgeValidator().validateSnapshot(
            at: fixture.snapshotRoot(result),
            mode: .mount,
            policy: fixture.validationPolicy,
            workspaceLease: fixture.workspaceLease)
        let chunks = snapshot.chunks.filter {
            $0.conceptID == "concepts/publication"
        }
        let primaryID = OKFCanonicalWriter.canonicalSourceID(
            resource: "/references/source.txt")
        let secondaryID = OKFCanonicalWriter.canonicalSourceID(
            resource: "/references/secondary.txt")
        XCTAssertTrue(chunks.contains { $0.sourceIDs == [primaryID] })
        XCTAssertTrue(chunks.contains { $0.sourceIDs == [secondaryID] })
        XCTAssertFalse(chunks.contains { $0.sourceIDs.count > 1 })
        XCTAssertFalse(chunks.contains {
            $0.text.contains("ambiguous multi-source paragraph")
        })
    }

    func testChunkManifestAndBytesAreStableAcrossOperationalClocks() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        let provider = CountingBuildEmbeddingProvider()
        let first = try await KnowledgeBundleBuildService(
            embeddingProvider: provider,
            now: { Date(timeIntervalSince1970: 1_786_233_600) })
            .buildAndPublish(fixture.request())
        let firstProfile = try KnowledgeJSON.decode(
            KnowledgeProfile.self,
            from: fixture.snapshotData(
                first,
                relativePath: ".intatis-rag/profile.json"))
        let firstChunks = try fixture.snapshotData(
            first,
            relativePath: ".intatis-rag/chunks.jsonl")
        let firstRequestCount = await provider.requestTextCount()

        let second = try await KnowledgeBundleBuildService(
            embeddingProvider: provider,
            now: { Date(timeIntervalSince1970: 1_786_320_000) })
            .buildAndPublish(fixture.request(
                expectedStoreID: first.storeID,
                expectedSnapshotID: first.snapshotID))
        let secondProfile = try KnowledgeJSON.decode(
            KnowledgeProfile.self,
            from: fixture.snapshotData(
                second,
                relativePath: ".intatis-rag/profile.json"))
        let secondChunks = try fixture.snapshotData(
            second,
            relativePath: ".intatis-rag/chunks.jsonl")

        XCTAssertEqual(first.bundleRevision, second.bundleRevision)
        XCTAssertEqual(firstChunks, secondChunks)
        XCTAssertEqual(
            firstProfile.chunking.manifestDigest,
            secondProfile.chunking.manifestDigest)
        XCTAssertNotEqual(
            firstProfile.bundle.createdAt,
            secondProfile.bundle.createdAt)
        XCTAssertEqual(second.reusedVectorCount, second.chunkCount)
        XCTAssertEqual(second.embeddedVectorCount, 0)
        let secondRequestCount = await provider.requestTextCount()
        XCTAssertEqual(secondRequestCount, firstRequestCount)
        let chunks = try KnowledgeChunkManifestIdentity.decode(secondChunks)
        XCTAssertTrue(chunks.allSatisfy {
            $0.producer.at == "1970-01-01T00:00:00Z"
        })
    }

    func testValidatorIsDeterministicAndNeverCallsEmbedding() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        let provider = CountingBuildEmbeddingProvider()
        let result = try await KnowledgeBundleBuildService(
            embeddingProvider: provider).buildAndPublish(fixture.request())
        let requestCount = await provider.requestTextCount()
        let validator = try KnowledgeValidator()
        let first = try validator.validateSnapshot(
            at: fixture.snapshotRoot(result),
            mode: .mount,
            policy: fixture.validationPolicy,
            workspaceLease: fixture.workspaceLease)
        let second = try validator.validateSnapshot(
            at: fixture.snapshotRoot(result),
            mode: .mount,
            policy: fixture.validationPolicy,
            workspaceLease: fixture.workspaceLease)
        XCTAssertEqual(first.report, second.report)
        XCTAssertEqual(first.backendRegistryDigest, second.backendRegistryDigest)
        XCTAssertEqual(first.contentSealDigest, second.contentSealDigest)
        let postValidationRequestCount = await provider.requestTextCount()
        XCTAssertEqual(postValidationRequestCount, requestCount)
    }

    func testStaleAfterUsesStrictDateOnlyAndBecomesStaleAtUTCDateBoundary() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        let original = try fixture.draftText(
            relativePath: "concepts/publication.md")
        try fixture.replaceDraft(
            relativePath: "concepts/publication.md",
            text: original.replacingOccurrences(
                of: "status: stable",
                with: "status: stable\nstale_after: 2026-08-09"))
        let buildDate = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-08T12:00:00Z"))
        let result = try await KnowledgeBundleBuildService(
            embeddingProvider: CountingBuildEmbeddingProvider(),
            now: { buildDate }).buildAndPublish(fixture.request())
        let validator = try KnowledgeValidator()
        let before = try validator.validateSnapshot(
            at: fixture.snapshotRoot(result),
            mode: .mount,
            policy: KnowledgeValidationPolicy(
                evaluationDate: "2026-08-08T23:59:59Z",
                trustedVerificationActors: ["human:test"]),
            workspaceLease: fixture.workspaceLease)
        let boundary = try validator.validateSnapshot(
            at: fixture.snapshotRoot(result),
            mode: .mount,
            policy: KnowledgeValidationPolicy(
                evaluationDate: "2026-08-09T00:00:00Z",
                trustedVerificationActors: ["human:test"]),
            workspaceLease: fixture.workspaceLease)
        XCTAssertFalse(before.report.diagnostics.contains {
            $0.code == "stale_concept"
        })
        XCTAssertTrue(boundary.report.diagnostics.contains {
            $0.code == "stale_concept"
        })

        let invalidFixture = try BuildFixture()
        defer { invalidFixture.cleanup() }
        let invalidOriginal = try invalidFixture.draftText(
            relativePath: "concepts/publication.md")
        try invalidFixture.replaceDraft(
            relativePath: "concepts/publication.md",
            text: invalidOriginal.replacingOccurrences(
                of: "status: stable",
                with: "status: stable\nstale_after: 2026-08-09T00:00:00Z"))
        let provider = CountingBuildEmbeddingProvider()
        do {
            _ = try await KnowledgeBundleBuildService(
                embeddingProvider: provider)
                .buildAndPublish(invalidFixture.request())
            XCTFail("date-time stale_after unexpectedly published")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .okfInvalid)
        }
        let invalidRequestCount = await provider.requestTextCount()
        XCTAssertEqual(invalidRequestCount, 0)
        XCTAssertFalse(invalidFixture.hasActivePointer)
    }

    func testRejectsAdmissionWithoutDeterministicPermissionSnapshot() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        let provider = CountingBuildEmbeddingProvider()
        let service = try KnowledgeBundleBuildService(embeddingProvider: provider)
        let invalid = fixture.request(
            authorization: fixture.authorization(deterministicGate: nil))

        do {
            _ = try await service.buildAndPublish(invalid)
            XCTFail("unreviewed build admission unexpectedly succeeded")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .accessDenied)
        }
        let requestCount = await provider.requestTextCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.store
                .appendingPathComponent(".intatis-rag-store.json").path))
    }

    func testBudgetFailureAbortsStagingWithoutActivatingPartialSnapshot() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        let provider = CountingBuildEmbeddingProvider()
        let service = try KnowledgeBundleBuildService(embeddingProvider: provider)
        var budget = KnowledgeBuildBudget()
        budget.maximumDraftBytes = 1

        do {
            _ = try await service.buildAndPublish(fixture.request(), budget: budget)
            XCTFail("over-budget build unexpectedly succeeded")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .searchBudgetExceeded)
        }
        let requestCount = await provider.requestTextCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.store
                .appendingPathComponent(".intatis-rag-store.json").path))
        let staging = fixture.store
            .appendingPathComponent(
                KnowledgeSnapshotStore.publishedSnapshotsDirectoryName,
                isDirectory: true)
            .appendingPathComponent(".staging", isDirectory: true)
        if FileManager.default.fileExists(atPath: staging.path) {
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: staging.path),
                [])
        }
    }

    func testEmbeddingCancellationIsTypedAndDoesNotPublish() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        let service = try KnowledgeBundleBuildService(
            embeddingProvider: CancellingBuildEmbeddingProvider())
        do {
            _ = try await service.buildAndPublish(fixture.request())
            XCTFail("cancelled embedding unexpectedly published")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .searchCancelled)
            XCTAssertFalse(error.failure.retryable)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.store
                .appendingPathComponent(".intatis-rag-store.json").path))
        XCTAssertFalse(fixture.containsValidationReceiptArtifact)
    }

    func testEmbeddingIdentityChangeForcesCompleteReembedding() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        let initialProvider = CountingBuildEmbeddingProvider()
        let initialService = try KnowledgeBundleBuildService(
            embeddingProvider: initialProvider)
        let first = try await initialService.buildAndPublish(fixture.request())

        let changedIdentity = KnowledgeEmbeddingModelIdentity(
            identity: testBuildEmbeddingIdentity.identity,
            revision: KnowledgeDigest.sha256("changed-model-revision"),
            tokenizerRevision: testBuildEmbeddingIdentity.tokenizerRevision,
            runtimeBindingKind: testBuildEmbeddingIdentity.runtimeBindingKind,
            runtimeBindingDigest: testBuildEmbeddingIdentity.runtimeBindingDigest,
            dimensions: testBuildEmbeddingIdentity.dimensions,
            pooling: testBuildEmbeddingIdentity.pooling,
            maxInputTokens: testBuildEmbeddingIdentity.maxInputTokens)
        let changedProvider = CountingBuildEmbeddingProvider(
            modelIdentity: changedIdentity)
        let changedService = try KnowledgeBundleBuildService(
            embeddingProvider: changedProvider)
        let second = try await changedService.buildAndPublish(
            fixture.request(
                expectedStoreID: first.storeID,
                expectedSnapshotID: first.snapshotID,
                embeddingModel: changedIdentity))

        XCTAssertEqual(second.reusedVectorCount, 0)
        XCTAssertEqual(second.embeddedVectorCount, second.chunkCount)
        let changedRequestCount = await changedProvider.requestTextCount()
        XCTAssertEqual(
            changedRequestCount,
            second.embeddingRequestTextCount)
        XCTAssertGreaterThan(second.embeddingRequestTextCount, 0)
    }

    func testChunkerParameterChangeForcesCompleteReembedding() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        let provider = CountingBuildEmbeddingProvider()
        let initialService = try KnowledgeBundleBuildService(
            embeddingProvider: provider)
        let first = try await initialService.buildAndPublish(fixture.request())

        let changedProvider = CountingBuildEmbeddingProvider()
        let changedService = try KnowledgeBundleBuildService(
            chunker: DeterministicKnowledgeChunker(
                configuration: KnowledgeChunkerConfiguration(
                    maximumUTF8Bytes: 1_201,
                    overlapUTF8Bytes: 160,
                    minimumUTF8Bytes: 24)),
            embeddingProvider: changedProvider)
        let second = try await changedService.buildAndPublish(
            fixture.request(
                expectedStoreID: first.storeID,
                expectedSnapshotID: first.snapshotID))

        XCTAssertEqual(second.reusedVectorCount, 0)
        XCTAssertEqual(second.embeddedVectorCount, second.chunkCount)
        let changedRequestCount = await changedProvider.requestTextCount()
        XCTAssertEqual(
            changedRequestCount,
            second.embeddingRequestTextCount)
        XCTAssertGreaterThan(second.embeddingRequestTextCount, 0)
    }

    func testEmbeddingDeadlineCancelsAndDrainsBeforeStagingCleanup() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        let provider = DeadlineBuildEmbeddingProvider()
        let service = try KnowledgeBundleBuildService(
            embeddingProvider: provider)
        var budget = KnowledgeBuildBudget()
        budget.maximumWallTimeSeconds = 1
        budget.maximumWriterWaitSeconds = 1

        do {
            _ = try await service.buildAndPublish(
                fixture.request(),
                budget: budget)
            XCTFail("timed-out embedding unexpectedly published")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .searchTimeout)
            XCTAssertTrue(error.failure.retryable)
        }
        let observedCancellation = await provider.observedCancellation()
        XCTAssertTrue(observedCancellation)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.store
                .appendingPathComponent(".intatis-rag-store.json").path))
        let staging = fixture.store
            .appendingPathComponent(
                KnowledgeSnapshotStore.publishedSnapshotsDirectoryName,
                isDirectory: true)
            .appendingPathComponent(".staging", isDirectory: true)
        if FileManager.default.fileExists(atPath: staging.path) {
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: staging.path),
                [])
        }
        XCTAssertFalse(fixture.containsValidationReceiptArtifact)
    }

    func testSecretDraftAndEmbeddingIdentityFailBeforeEmbeddingOrPublication() async throws {
        let secret = "sk-supersecret123456"

        let draftFixture = try BuildFixture()
        defer { draftFixture.cleanup() }
        try draftFixture.replaceDraft(
            relativePath: "references/source.txt",
            text: "credential=\(secret)\n")
        let draftProvider = CountingBuildEmbeddingProvider()
        let draftService = try KnowledgeBundleBuildService(
            embeddingProvider: draftProvider)
        do {
            _ = try await draftService.buildAndPublish(draftFixture.request())
            XCTFail("credential-like draft unexpectedly published")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .integrityFailed)
            assertDoesNotEcho(secret, error: error)
        }
        let draftRequestCount = await draftProvider.requestTextCount()
        XCTAssertEqual(draftRequestCount, 0)
        XCTAssertFalse(draftFixture.hasActivePointer)

        let profileFixture = try BuildFixture()
        defer { profileFixture.cleanup() }
        let unsafeIdentity = KnowledgeEmbeddingModelIdentity(
            identity: "org.vita.\(secret)",
            revision: testBuildEmbeddingIdentity.revision,
            tokenizerRevision: testBuildEmbeddingIdentity.tokenizerRevision,
            runtimeBindingKind: .local,
            runtimeBindingDigest: testBuildEmbeddingIdentity.runtimeBindingDigest,
            dimensions: testBuildEmbeddingIdentity.dimensions,
            pooling: testBuildEmbeddingIdentity.pooling,
            maxInputTokens: testBuildEmbeddingIdentity.maxInputTokens)
        let profileProvider = CountingBuildEmbeddingProvider(
            modelIdentity: unsafeIdentity)
        let profileService = try KnowledgeBundleBuildService(
            embeddingProvider: profileProvider)
        do {
            _ = try await profileService.buildAndPublish(profileFixture.request(
                embeddingModel: unsafeIdentity))
            XCTFail("credential-like profile identity unexpectedly published")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .accessDenied)
            assertDoesNotEcho(secret, error: error)
        }
        let profileRequestCount = await profileProvider.requestTextCount()
        XCTAssertEqual(profileRequestCount, 0)
        XCTAssertFalse(profileFixture.hasActivePointer)
    }

    func testChecksumInventoryRejectsMissingUnlistedSelfReferenceSizeAndHash() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        let service = try KnowledgeBundleBuildService(
            embeddingProvider: CountingBuildEmbeddingProvider())
        let result = try await service.buildAndPublish(fixture.request())
        let root = fixture.snapshotRoot(result)
        let path = ".intatis-rag/checksums.json"
        let originalData = try fixture.snapshotData(result, relativePath: path)
        let original = try KnowledgeJSON.decode(
            KnowledgeChecksums.self,
            from: originalData)
        let first = try XCTUnwrap(original.files.first)

        try fixture.removeSnapshotFile(result, relativePath: path)
        XCTAssertEqual(
            validationFailure(root: root, fixture: fixture)?.failure.code,
            .indexNotReady)
        try fixture.replaceSnapshotData(result, relativePath: path, data: originalData)

        let unlisted = KnowledgeChecksums(files: Array(original.files.dropLast()))
        try fixture.replaceSnapshotData(
            result,
            relativePath: path,
            data: try KnowledgeJSON.encode(unlisted, pretty: true))
        assertDiagnostic(
            "checksums_completeness",
            in: validationFailure(root: root, fixture: fixture))

        let selfReference = KnowledgeChecksumEntry(
            path: path,
            size: originalData.count,
            sha256: KnowledgeDigest.sha256(originalData),
            role: "checksum_inventory")
        try fixture.replaceSnapshotData(
            result,
            relativePath: path,
            data: try KnowledgeJSON.encode(
                KnowledgeChecksums(files: original.files + [selfReference]),
                pretty: true))
        XCTAssertEqual(
            validationFailure(root: root, fixture: fixture)?.failure.code,
            .integrityFailed)

        let missing = KnowledgeChecksumEntry(
            path: "references/missing.txt",
            size: 1,
            sha256: KnowledgeDigest.sha256("x"),
            role: "reference")
        try fixture.replaceSnapshotData(
            result,
            relativePath: path,
            data: try KnowledgeJSON.encode(
                KnowledgeChecksums(files: original.files + [missing]),
                pretty: true))
        assertDiagnostic(
            "checksums_missing",
            in: validationFailure(root: root, fixture: fixture))

        let wrongSize = KnowledgeChecksumEntry(
            path: first.path,
            size: first.size + 1,
            sha256: first.sha256,
            role: first.role)
        try fixture.replaceSnapshotData(
            result,
            relativePath: path,
            data: try KnowledgeJSON.encode(
                KnowledgeChecksums(files: [wrongSize] + original.files.dropFirst()),
                pretty: true))
        assertDiagnostic(
            "checksums_mismatch",
            in: validationFailure(root: root, fixture: fixture))

        let wrongHash = KnowledgeChecksumEntry(
            path: first.path,
            size: first.size,
            sha256: KnowledgeDigest.sha256("wrong"),
            role: first.role)
        try fixture.replaceSnapshotData(
            result,
            relativePath: path,
            data: try KnowledgeJSON.encode(
                KnowledgeChecksums(files: [wrongHash] + original.files.dropFirst()),
                pretty: true))
        assertDiagnostic(
            "checksums_mismatch",
            in: validationFailure(root: root, fixture: fixture))

        try fixture.replaceSnapshotData(result, relativePath: path, data: originalData)
        try fixture.addSnapshotFile(
            result,
            relativePath: "references/unlisted.txt",
            data: Data("extra".utf8))
        assertDiagnostic(
            "checksums_completeness",
            in: validationFailure(root: root, fixture: fixture))
    }

    func testDenseAndLexicalCorruptionFailsClosedAcrossKeyAndDigestMatrix() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        let service = try KnowledgeBundleBuildService(
            embeddingProvider: CountingBuildEmbeddingProvider())
        let result = try await service.buildAndPublish(fixture.request())
        let root = fixture.snapshotRoot(result)
        let densePath = ".intatis-rag/dense/exact-knn.json"
        let lexicalPath = ".intatis-rag/lexical/bm25.json"
        let denseData = try fixture.snapshotData(result, relativePath: densePath)
        let lexicalData = try fixture.snapshotData(result, relativePath: lexicalPath)
        let dense = try KnowledgeJSON.decode(
            KnowledgeDenseIndexFile.self,
            from: denseData)
        let lexical = try KnowledgeJSON.decode(
            KnowledgeLexicalIndexFile.self,
            from: lexicalData)
        let vector = try XCTUnwrap(dense.vectors.first)
        let document = try XCTUnwrap(lexical.documents.first)

        let denseCases: [(KnowledgeDenseIndexFile, String)] = [
            (KnowledgeDenseIndexFile(
                dimensions: dense.dimensions + 1,
                vectors: dense.vectors), "dense_index_invalid"),
            (KnowledgeDenseIndexFile(
                dimensions: dense.dimensions,
                vectors: dense.vectors + [vector]), "dense_index_invalid"),
            (KnowledgeDenseIndexFile(
                dimensions: dense.dimensions,
                vectors: []), "dense_index_invalid"),
            (KnowledgeDenseIndexFile(
                dimensions: dense.dimensions,
                vectors: [KnowledgeDenseVectorRecord(
                    chunkID: "chk_orphan",
                    values: vector.values)] + dense.vectors.dropFirst()),
             "dense_completeness"),
        ]
        for (corrupt, diagnostic) in denseCases {
            try fixture.replaceSnapshotData(
                result,
                relativePath: densePath,
                data: try KnowledgeJSON.encode(corrupt))
            let failure = validationFailure(root: root, fixture: fixture)
            assertDiagnostic(diagnostic, in: failure)
            assertDiagnostic("dense_integrity", in: failure)
        }
        try fixture.replaceSnapshotData(result, relativePath: densePath, data: denseData)

        let lexicalCases: [(KnowledgeLexicalIndexFile, String)] = [
            (KnowledgeLexicalIndexFile(
                tokenizer: lexical.tokenizer,
                documents: lexical.documents + [document]), "lexical_index_invalid"),
            (KnowledgeLexicalIndexFile(
                tokenizer: lexical.tokenizer,
                documents: []), "lexical_index_invalid"),
            (KnowledgeLexicalIndexFile(
                tokenizer: lexical.tokenizer,
                documents: [KnowledgeLexicalDocumentRecord(
                    chunkID: "chk_orphan",
                    length: document.length,
                    terms: document.terms)] + lexical.documents.dropFirst()),
             "lexical_completeness"),
        ]
        for (corrupt, diagnostic) in lexicalCases {
            try fixture.replaceSnapshotData(
                result,
                relativePath: lexicalPath,
                data: try KnowledgeJSON.encode(corrupt))
            let failure = validationFailure(root: root, fixture: fixture)
            assertDiagnostic(diagnostic, in: failure)
            if diagnostic == "lexical_completeness" {
                assertDiagnostic("lexical_integrity", in: failure)
            }
        }
    }

    func testProfileRejectsUnsupportedMissingAndRequiredComponents() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        let result = try await KnowledgeBundleBuildService(
            embeddingProvider: CountingBuildEmbeddingProvider())
            .buildAndPublish(fixture.request())
        let root = fixture.snapshotRoot(result)
        let profilePath = ".intatis-rag/profile.json"
        let original = try fixture.snapshotData(result, relativePath: profilePath)

        try fixture.replaceSnapshotData(
            result,
            relativePath: profilePath,
            data: try mutateJSONObject(original) { object in
                var indexes = try requireArray(
                    object["embedding_indexes"],
                    field: "embedding_indexes")
                var first = try requireObject(indexes.first, field: "dense")
                var backend = try requireObject(first["backend"], field: "dense.backend")
                backend["identity"] = "unsupported.dense.backend"
                first["backend"] = backend
                indexes[0] = first
                object["embedding_indexes"] = indexes
            })
        assertDiagnostic(
            "dense_backend",
            in: validationFailure(root: root, fixture: fixture))

        try fixture.replaceSnapshotData(
            result,
            relativePath: profilePath,
            data: try mutateJSONObject(original) { object in
                var indexes = try requireArray(
                    object["lexical_indexes"],
                    field: "lexical_indexes")
                var first = try requireObject(indexes.first, field: "lexical")
                var backend = try requireObject(first["backend"], field: "lexical.backend")
                backend["identity"] = "unsupported.lexical.backend"
                first["backend"] = backend
                indexes[0] = first
                object["lexical_indexes"] = indexes
            })
        assertDiagnostic(
            "lexical_backend",
            in: validationFailure(root: root, fixture: fixture))

        try fixture.replaceSnapshotData(
            result,
            relativePath: profilePath,
            data: try mutateJSONObject(original) { object in
                var snapshot = try requireObject(
                    object["retrieval_snapshot"],
                    field: "retrieval_snapshot")
                snapshot.removeValue(forKey: "lexical")
                object["retrieval_snapshot"] = snapshot
            })
        assertDiagnostic(
            "lexical_required",
            in: validationFailure(root: root, fixture: fixture))

        try fixture.replaceSnapshotData(
            result,
            relativePath: profilePath,
            data: try mutateJSONObject(original) { object in
                var snapshot = try requireObject(
                    object["retrieval_snapshot"],
                    field: "retrieval_snapshot")
                var dense = try requireObject(snapshot["dense"], field: "dense")
                dense["id"] = "missing_dense_component"
                snapshot["dense"] = dense
                object["retrieval_snapshot"] = snapshot
            })
        XCTAssertEqual(
            validationFailure(root: root, fixture: fixture)?.failure.code,
            .indexNotReady)

        try fixture.replaceSnapshotData(result, relativePath: profilePath, data: original)
        try fixture.removeSnapshotFile(result, relativePath: ".intatis-rag/dense/exact-knn.json")
        XCTAssertNotNil(validationFailure(root: root, fixture: fixture))
    }

    func testSecretsInEverySnapshotLayerFailValidationWithoutEcho() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        let result = try await KnowledgeBundleBuildService(
            embeddingProvider: CountingBuildEmbeddingProvider())
            .buildAndPublish(fixture.request())
        let root = fixture.snapshotRoot(result)
        let secret = "sk-layersecret123456"
        let paths = [
            "concepts/publication.md",
            "references/source.txt",
            ".intatis-rag/chunks.jsonl",
            ".intatis-rag/dense/exact-knn.json",
            ".intatis-rag/lexical/bm25.json",
        ]
        for path in paths {
            let original = try fixture.snapshotData(result, relativePath: path)
            var changed = original
            changed.append(Data("\n\(secret)\n".utf8))
            try fixture.replaceSnapshotData(result, relativePath: path, data: changed)
            let failure = try XCTUnwrap(validationFailure(root: root, fixture: fixture))
            assertDoesNotEcho(secret, error: failure)
            assertDiagnostic("secret_material", in: failure)
            try fixture.replaceSnapshotData(result, relativePath: path, data: original)
        }

        let profilePath = ".intatis-rag/profile.json"
        let profile = try fixture.snapshotData(result, relativePath: profilePath)
        let secretProfile = try mutateJSONObject(profile) { object in
            var bundle = try requireObject(object["bundle"], field: "bundle")
            bundle["id"] = "kb_demo-\(secret)"
            object["bundle"] = bundle
        }
        try fixture.replaceSnapshotData(
            result,
            relativePath: profilePath,
            data: secretProfile)
        let profileFailure = try XCTUnwrap(
            validationFailure(root: root, fixture: fixture))
        assertDiagnostic("secret_material", in: profileFailure)
        assertDoesNotEcho(secret, error: profileFailure)
        try fixture.replaceSnapshotData(result, relativePath: profilePath, data: profile)

        let checksumPath = ".intatis-rag/checksums.json"
        let checksumData = try fixture.snapshotData(result, relativePath: checksumPath)
        let checksums = try KnowledgeJSON.decode(
            KnowledgeChecksums.self,
            from: checksumData)
        let secretEntry = KnowledgeChecksumEntry(
            path: "references/\(secret).txt",
            size: 1,
            sha256: KnowledgeDigest.sha256("x"),
            role: "reference")
        try fixture.replaceSnapshotData(
            result,
            relativePath: checksumPath,
            data: try KnowledgeJSON.encode(
                KnowledgeChecksums(files: checksums.files + [secretEntry]),
                pretty: true))
        let checksumFailure = try XCTUnwrap(
            validationFailure(root: root, fixture: fixture))
        assertDiagnostic("secret_material", in: checksumFailure)
        assertDoesNotEcho(secret, error: checksumFailure)
    }

    func testModifiedAndDeletedChunksReuseOnlyUnchangedCanonicalText() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        try fixture.replaceDraft(
            relativePath: "concepts/secondary.md",
            text: BuildFixture.secondaryConcept)
        let provider = CountingBuildEmbeddingProvider()
        let service = try KnowledgeBundleBuildService(embeddingProvider: provider)
        let first = try await service.buildAndPublish(fixture.request())
        XCTAssertGreaterThanOrEqual(first.chunkCount, 2)

        try fixture.replaceDraft(
            relativePath: "concepts/publication.md",
            text: BuildFixture.modifiedPublicationConcept)
        let modified = try await service.buildAndPublish(
            fixture.request(
                expectedStoreID: first.storeID,
                expectedSnapshotID: first.snapshotID))
        XCTAssertGreaterThan(modified.reusedVectorCount, 0)
        XCTAssertGreaterThan(modified.embeddedVectorCount, 0)
        XCTAssertEqual(
            modified.reusedVectorCount + modified.embeddedVectorCount,
            modified.chunkCount)

        try fixture.removeDraft(relativePath: "concepts/publication.md")
        let deleted = try await service.buildAndPublish(
            fixture.request(
                expectedStoreID: modified.storeID,
                expectedSnapshotID: modified.snapshotID))
        XCTAssertEqual(deleted.reusedVectorCount, deleted.chunkCount)
        XCTAssertEqual(deleted.embeddedVectorCount, 0)
        XCTAssertEqual(deleted.vectorCount, deleted.chunkCount)
        let validated = try KnowledgeValidator().validateSnapshot(
            at: fixture.snapshotRoot(deleted),
            mode: .mount,
            policy: fixture.validationPolicy,
            workspaceLease: fixture.workspaceLease)
        XCTAssertEqual(
            Set(validated.denseFile.vectors.map(\.chunkID)),
            Set(validated.chunks.map(\.chunkID)))
        XCTAssertFalse(validated.concepts.keys.contains("concepts/publication"))
    }

    func testEverySupportedEmbeddingIdentityFieldChangeForcesFullRebuild() async throws {
        let variants = [
            changedEmbeddingIdentity(identity: "org.vita.intatis.tests.embedding.changed"),
            changedEmbeddingIdentity(revision: KnowledgeDigest.sha256("changed-revision")),
            changedEmbeddingIdentity(tokenizerRevision: KnowledgeDigest.sha256("changed-tokenizer")),
            changedEmbeddingIdentity(runtimeBindingKind: .remote),
            changedEmbeddingIdentity(runtimeBindingDigest: KnowledgeDigest.sha256("changed-runtime")),
            changedEmbeddingIdentity(dimensions: 5),
            changedEmbeddingIdentity(pooling: "changed-pooling"),
            changedEmbeddingIdentity(documentInstruction: "document: "),
            changedEmbeddingIdentity(queryInstruction: "query: "),
            changedEmbeddingIdentity(maxInputTokens: 513),
        ]
        for identity in variants {
            let fixture = try BuildFixture()
            defer { fixture.cleanup() }
            let first = try await KnowledgeBundleBuildService(
                embeddingProvider: CountingBuildEmbeddingProvider())
                .buildAndPublish(fixture.request())
            let changedProvider = CountingBuildEmbeddingProvider(
                modelIdentity: identity)
            let second = try await KnowledgeBundleBuildService(
                embeddingProvider: changedProvider)
                .buildAndPublish(fixture.request(
                    expectedStoreID: first.storeID,
                    expectedSnapshotID: first.snapshotID,
                    embeddingModel: identity))
            XCTAssertEqual(
                second.reusedVectorCount,
                0,
                "identity change reused vectors: \(identity)")
            XCTAssertEqual(second.embeddedVectorCount, second.chunkCount)
            let requestCount = await changedProvider.requestTextCount()
            XCTAssertEqual(requestCount, second.embeddingRequestTextCount)
            XCTAssertGreaterThan(requestCount, 0)
        }
    }

    func testUnsupportedEmbeddingSemanticFieldChangesNeverActivateSnapshot() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        let first = try await KnowledgeBundleBuildService(
            embeddingProvider: CountingBuildEmbeddingProvider())
            .buildAndPublish(fixture.request())
        let variants = [
            changedEmbeddingIdentity(scalarType: "float16"),
            changedEmbeddingIdentity(quantization: "int8"),
            changedEmbeddingIdentity(normalization: "none"),
            changedEmbeddingIdentity(similarity: "dot"),
            changedEmbeddingIdentity(truncation: "start"),
        ]
        for identity in variants {
            let provider = CountingBuildEmbeddingProvider(modelIdentity: identity)
            do {
                _ = try await KnowledgeBundleBuildService(
                    embeddingProvider: provider)
                    .buildAndPublish(fixture.request(
                        expectedStoreID: first.storeID,
                        expectedSnapshotID: first.snapshotID,
                        embeddingModel: identity))
                XCTFail("unsupported embedding semantics unexpectedly published")
            } catch let error as KnowledgeDomainError {
                XCTAssertTrue([
                    KnowledgeErrorCode.integrityFailed,
                    .profileInvalid,
                ].contains(error.failure.code))
            }
            let pointer = try KnowledgeSnapshotStore(
                root: fixture.store,
                workspaceLease: fixture.workspaceLease).loadCurrentPointer()
            XCTAssertEqual(pointer.currentSnapshot, first.snapshotID)
        }
    }

    private func validationFailure(
        root: URL,
        fixture: BuildFixture
    ) -> KnowledgeDomainError? {
        do {
            _ = try KnowledgeValidator().validateSnapshot(
                at: root,
                mode: .mount,
                policy: fixture.validationPolicy,
                workspaceLease: fixture.workspaceLease)
            XCTFail("corrupt knowledge snapshot unexpectedly validated")
            return nil
        } catch let error as KnowledgeDomainError {
            return error
        } catch {
            XCTFail("unexpected validation error type: \(error)")
            return nil
        }
    }

    private func assertDiagnostic(
        _ code: String,
        in error: KnowledgeDomainError?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let error else {
            return XCTFail("expected \(code) validation failure", file: file, line: line)
        }
        XCTAssertTrue(
            error.diagnostics.contains { $0.code == code },
            "missing \(code); got \(error.diagnostics.map(\.code))",
            file: file,
            line: line)
    }

    private func assertDoesNotEcho(
        _ secret: String,
        error: KnowledgeDomainError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let diagnosticText = error.diagnostics.flatMap {
            [$0.code, $0.subject, $0.message]
        }.joined(separator: "\n")
        XCTAssertFalse(error.failure.message.contains(secret), file: file, line: line)
        XCTAssertFalse(diagnosticText.contains(secret), file: file, line: line)
    }
}

private enum KnowledgeTestMutationError: Error {
    case invalidJSONField(String)
}

private func mutateJSONObject(
    _ data: Data,
    mutation: (inout [String: Any]) throws -> Void
) throws -> Data {
    guard var object = try JSONSerialization.jsonObject(with: data)
        as? [String: Any] else {
        throw KnowledgeTestMutationError.invalidJSONField("root")
    }
    try mutation(&object)
    return try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys])
}

private func requireObject(
    _ value: Any?,
    field: String
) throws -> [String: Any] {
    guard let object = value as? [String: Any] else {
        throw KnowledgeTestMutationError.invalidJSONField(field)
    }
    return object
}

private func requireArray(
    _ value: Any?,
    field: String
) throws -> [[String: Any]] {
    guard let array = value as? [[String: Any]], !array.isEmpty else {
        throw KnowledgeTestMutationError.invalidJSONField(field)
    }
    return array
}

private actor CountingBuildEmbeddingProvider: KnowledgeEmbeddingProvider {
    nonisolated let modelIdentity: KnowledgeEmbeddingModelIdentity
    private var embeddedTextCount = 0

    init(modelIdentity: KnowledgeEmbeddingModelIdentity = testBuildEmbeddingIdentity) {
        self.modelIdentity = modelIdentity
    }

    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        embeddedTextCount += texts.count
        return texts.map { text in
            let discriminator = Float((Data(text.utf8).count % 7) + 1)
            return (0..<modelIdentity.dimensions).map {
                $0 == 0 ? discriminator : Float($0 + 1)
            }
        }
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        (0..<modelIdentity.dimensions).map { Float($0 + 1) }
    }

    func requestTextCount() -> Int { embeddedTextCount }
}

private struct CancellingBuildEmbeddingProvider: KnowledgeEmbeddingProvider {
    let modelIdentity = testBuildEmbeddingIdentity

    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        throw CancellationError()
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        throw CancellationError()
    }
}

private actor DeadlineBuildEmbeddingProvider: KnowledgeEmbeddingProvider {
    nonisolated let modelIdentity = testBuildEmbeddingIdentity
    private var cancelled = false

    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return texts.map { _ in [1, 2, 3, 4] }
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        [1, 2, 3, 4]
    }

    func observedCancellation() -> Bool { cancelled }
}

private let testBuildEmbeddingIdentity = KnowledgeEmbeddingModelIdentity(
    identity: "org.vita.intatis.tests.embedding",
    revision: "sha256:" + String(repeating: "1", count: 64),
    tokenizerRevision: "sha256:" + String(repeating: "2", count: 64),
    runtimeBindingKind: .local,
    runtimeBindingDigest: KnowledgeDigest.sha256("test-build-embedding-runtime/1"),
    dimensions: 4,
    pooling: "test",
    maxInputTokens: 512)

private func changedEmbeddingIdentity(
    identity: String = testBuildEmbeddingIdentity.identity,
    revision: String = testBuildEmbeddingIdentity.revision,
    tokenizerRevision: String = testBuildEmbeddingIdentity.tokenizerRevision,
    runtimeBindingKind: KnowledgeEmbeddingModelIdentity.RuntimeBindingKind = testBuildEmbeddingIdentity.runtimeBindingKind,
    runtimeBindingDigest: String = testBuildEmbeddingIdentity.runtimeBindingDigest,
    dimensions: Int = testBuildEmbeddingIdentity.dimensions,
    scalarType: String = testBuildEmbeddingIdentity.scalarType,
    quantization: String = testBuildEmbeddingIdentity.quantization,
    pooling: String = testBuildEmbeddingIdentity.pooling,
    normalization: String = testBuildEmbeddingIdentity.normalization,
    similarity: String = testBuildEmbeddingIdentity.similarity,
    documentInstruction: String = testBuildEmbeddingIdentity.documentInstruction,
    queryInstruction: String = testBuildEmbeddingIdentity.queryInstruction,
    maxInputTokens: Int = testBuildEmbeddingIdentity.maxInputTokens,
    truncation: String = testBuildEmbeddingIdentity.truncation
) -> KnowledgeEmbeddingModelIdentity {
    KnowledgeEmbeddingModelIdentity(
        identity: identity,
        revision: revision,
        tokenizerRevision: tokenizerRevision,
        runtimeBindingKind: runtimeBindingKind,
        runtimeBindingDigest: runtimeBindingDigest,
        dimensions: dimensions,
        scalarType: scalarType,
        quantization: quantization,
        pooling: pooling,
        normalization: normalization,
        similarity: similarity,
        documentInstruction: documentInstruction,
        queryInstruction: queryInstruction,
        maxInputTokens: maxInputTokens,
        truncation: truncation)
}

private final class BuildFixture {
    static let secondaryConcept = """
    ---
    type: Note
    title: Secondary unchanged evidence
    sources:
      - id: source-one
        resource: ../references/source.txt
    verified:
      by: human:test
      at: "2026-08-09T00:00:00Z"
    status: stable
    ---

    # Secondary rule

    This independent canonical chunk remains unchanged across an update and deletion.
    """

    static let modifiedPublicationConcept = """
    ---
    type: Policy
    title: Durable knowledge publication
    sources:
      - id: source-one
        resource: ../references/source.txt
    verified:
      by: human:test
      at: "2026-08-09T00:00:00Z"
    status: stable
    ---

    # Publication rule

    A modified validated knowledge snapshot is published atomically and receives a new embedding.
    """

    let root: URL
    let draft: URL
    let store: URL
    let workspaceLease: WorkspaceLease

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "intatis-knowledge-build-tests-\(UUID().uuidString)",
            isDirectory: true)
        draft = root.appendingPathComponent("draft", isDirectory: true)
        store = root.appendingPathComponent("store", isDirectory: true)
        try Self.createDirectory(root)
        try Self.createDirectory(draft)
        try Self.createDirectory(draft.appendingPathComponent("concepts", isDirectory: true))
        try Self.createDirectory(draft.appendingPathComponent("references", isDirectory: true))
        try Self.write(
            """
            ---
            type: Index
            okf_version: "0.2"
            ---

            # Test knowledge
            """,
            to: draft.appendingPathComponent("index.md"))
        try Self.write(
            """
            ---
            type: Policy
            title: Durable knowledge publication
            sources:
              - id: source-one
                resource: ../references/source.txt
            verified:
              by: human:test
              at: "2026-08-09T00:00:00Z"
            status: stable
            ---

            # Publication rule

            A validated knowledge snapshot is published atomically, and an active reader keeps using its exact immutable revision.

            # Incremental rule

            An unchanged canonical chunk may reuse vector bytes only when the complete embedding and chunking compatibility identity is equal.
            """,
            to: draft.appendingPathComponent("concepts/publication.md"))
        try Self.write(
            "The source fixture is immutable for this build test.\n",
            to: draft.appendingPathComponent("references/source.txt"))
        workspaceLease = WorkspaceLease(
            rootPath: root.path,
            access: .readWrite,
            allowedPathRules: [PathRule(pattern: ".")],
            deniedPatterns: [])
    }

    func request(expectedStoreID: String? = nil,
                 expectedSnapshotID: String? = nil,
                 embeddingModel: KnowledgeEmbeddingModelIdentity = testBuildEmbeddingIdentity,
                 authorization explicit: ResolvedToolAuthorization? = nil)
        -> KnowledgeBundleBuildRequest {
        KnowledgeBundleBuildRequest(
            draftRoot: draft,
            storeRoot: store,
            expectedStoreID: expectedStoreID,
            expectedSnapshotID: expectedSnapshotID,
            workspaceLease: workspaceLease,
            authorization: explicit ?? authorization(
                expectedStoreID: expectedStoreID,
                expectedSnapshotID: expectedSnapshotID,
                embeddingModel: embeddingModel),
            trustedVerificationActors: ["human:test"])
    }

    func authorization(
        expectedStoreID: String? = nil,
        expectedSnapshotID: String? = nil,
        embeddingModel: KnowledgeEmbeddingModelIdentity = testBuildEmbeddingIdentity,
        deterministicGate: PermissionReviewGateSnapshot? = PermissionReviewGateSnapshot(
            decision: .ask,
            risk: .medium,
            reason: "test-reviewed-write",
            policyVersion: "test/1")
    ) -> ResolvedToolAuthorization {
        let intent = PermissionIntent(
            action: "build_knowledge",
            resources: [
                PermissionResource(
                    kind: .workspacePath,
                    value: PathConfinement.relativePath(of: store, root: root),
                    access: .readWrite),
            ],
            dataEffects: [.read, .mutate],
            risks: [.workspaceMutation],
            replayPolicy: .doNotReplay)
        let authorizationIdentity = try! KnowledgeBuildAuthorizationIdentity.canonical(
            draftRoot: draft,
            storeRoot: store,
            expectedStoreID: expectedStoreID,
            expectedSnapshotID: expectedSnapshotID,
            workspaceLease: workspaceLease,
            embeddingModel: embeddingModel,
            trustedVerificationActors: ["human:test"])
        return ResolvedToolAuthorization(
            authorizationID: "test-build-authorization",
            registryVersion: "test-registry/1",
            concreteToolID: "test-registry/1/build_knowledge",
            descriptorFingerprint: "test-descriptor",
            toolName: "build_knowledge",
            canonicalAction: "build_knowledge",
            canonicalPermission: "build_knowledge",
            requiredCapabilities: [.buildKnowledge],
            membership: .granted,
            capabilityLeaseID: CapabilityLeaseID.new(),
            capabilityTaskID: nil,
            workspaceLeaseID: workspaceLease.id,
            workspaceAccess: .readWrite,
            workspaceRootIdentity: workspaceLease.rootIdentity,
            normalizedArgumentsDigest: KnowledgeBuildAuthorizationIdentity.digest(
                authorizationIdentity),
            normalizedArgumentsCharacterCount: authorizationIdentity.count,
            intent: intent,
            sideEffect: .write,
            risksNetwork: embeddingModel.runtimeBindingKind == .remote,
            replayPolicy: .doNotReplay,
            deterministicGate: deterministicGate,
            workspaceID: workspaceLease.workspaceID,
            workspaceTaskID: workspaceLease.taskID,
            workspaceRootPath: workspaceLease.rootPath,
            workspaceLeaseFingerprint: ToolRegistry.authorizationFingerprint(workspaceLease))
    }

    func cleanup() {
        Self.makeWritable(root)
        try? FileManager.default.removeItem(at: root)
    }

    var hasActivePointer: Bool {
        FileManager.default.fileExists(atPath: store
            .appendingPathComponent(".intatis-rag-store.json").path)
    }

    var validationPolicy: KnowledgeValidationPolicy {
        KnowledgeValidationPolicy(
            evaluationDate: "2026-08-09T00:00:00Z",
            trustedVerificationActors: ["human:test"])
    }

    func snapshotRoot(_ result: KnowledgeBundleBuildResult) -> URL {
        store.appendingPathComponent(
            KnowledgeSnapshotStore.publishedSnapshotsDirectoryName,
            isDirectory: true)
            .appendingPathComponent(result.snapshotID, isDirectory: true)
    }

    func snapshotData(
        _ result: KnowledgeBundleBuildResult,
        relativePath: String
    ) throws -> Data {
        try Data(contentsOf: snapshotRoot(result).appendingPathComponent(
            relativePath))
    }

    func replaceSnapshotData(
        _ result: KnowledgeBundleBuildResult,
        relativePath: String,
        data: Data
    ) throws {
        let url = snapshotRoot(result).appendingPathComponent(relativePath)
        makeParentWritable(url)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = chmod(url.path, 0o600)
        }
        try data.write(to: url, options: .atomic)
        _ = chmod(url.path, 0o600)
    }

    func addSnapshotFile(
        _ result: KnowledgeBundleBuildResult,
        relativePath: String,
        data: Data
    ) throws {
        let url = snapshotRoot(result).appendingPathComponent(relativePath)
        makeParentWritable(url)
        try data.write(to: url, options: .withoutOverwriting)
        _ = chmod(url.path, 0o600)
    }

    func removeSnapshotFile(
        _ result: KnowledgeBundleBuildResult,
        relativePath: String
    ) throws {
        let url = snapshotRoot(result).appendingPathComponent(relativePath)
        makeParentWritable(url)
        _ = chmod(url.path, 0o600)
        try FileManager.default.removeItem(at: url)
    }

    func replaceDraft(relativePath: String, text: String) throws {
        let url = draft.appendingPathComponent(relativePath)
        try Self.createDirectory(url.deletingLastPathComponent())
        makeParentWritable(url)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = chmod(url.path, 0o600)
        }
        try Data(text.utf8).write(to: url, options: .atomic)
        _ = chmod(url.path, 0o600)
    }

    func draftText(relativePath: String) throws -> String {
        let data = try Data(contentsOf: draft.appendingPathComponent(
            relativePath))
        guard let text = String(data: data, encoding: .utf8) else {
            throw KnowledgeTestMutationError.invalidJSONField("draft text")
        }
        return text
    }

    var containsValidationReceiptArtifact: Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []) else { return false }
        for case let url as URL in enumerator
            where url.lastPathComponent.lowercased().contains("receipt") {
            return true
        }
        return false
    }

    func removeDraft(relativePath: String) throws {
        let url = draft.appendingPathComponent(relativePath)
        makeParentWritable(url)
        _ = chmod(url.path, 0o600)
        try FileManager.default.removeItem(at: url)
    }

    private static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        _ = chmod(url.path, 0o700)
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        _ = chmod(url.path, 0o600)
    }

    private static func makeWritable(_ root: URL) {
        _ = chmod(root.path, 0o700)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []) else { return }
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                _ = chmod(url.path, isDirectory.boolValue ? 0o700 : 0o600)
            }
        }
    }

    private func makeParentWritable(_ url: URL) {
        var current = url.deletingLastPathComponent()
        while current.path == root.path
            || current.path.hasPrefix(root.path + "/") {
            _ = chmod(current.path, 0o700)
            if current.path == root.path { break }
            current = current.deletingLastPathComponent()
        }
    }
}
