import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisTools
@testable import IntatisKnowledge

final class KnowledgeSourceLocatorTests: XCTestCase {
    func testMountValidatorAndSearchReuseExactLocatorRuntime() async throws {
        let fixture = try SourceLocatorSnapshotFixture()
        defer { fixture.remove() }
        let validator = try KnowledgeValidator()
        let snapshot = try validator.validateSnapshot(
            at: fixture.root,
            mode: .mount,
            policy: KnowledgeValidationPolicy(
                evaluationDate: SourceLocatorSnapshotFixture.timestamp))

        XCTAssertTrue(snapshot.report.semanticVerdict)
        XCTAssertEqual(
            snapshot.evidenceValidationContext.backendRegistry.digest,
            snapshot.backendRegistryDigest)
        XCTAssertEqual(
            snapshot.chunks.first?.sourceLocators?.first?.value,
            "0:\(fixture.sourceBytes.count)")

        let embedding = SourceLocatorEmbeddingProvider(
            modelIdentity: fixture.model)
        let reader = try KnowledgeSnapshotSearchReader(
            snapshot: snapshot,
            embeddingRegistry: KnowledgeEmbeddingRuntimeRegistry([embedding]),
            policy: KnowledgeSearchPolicy(
                lexicalCandidateLimit: 0,
                evaluationDate: SourceLocatorSnapshotFixture.timestamp))
        let result = try await reader.search(
            knowledgeBase: "kb_locator",
            query: "grounded source",
            limit: 1)
        let evidence = try XCTUnwrap(result.evidence?.first)
        let locator = try XCTUnwrap(evidence.sourceLocators?.first)
        let replay = try snapshot.evidenceValidationContext.backendRegistry
            .sourceLocatorAdapters.replay(locator, in: fixture.sourceBytes)
        XCTAssertEqual(replay.content, fixture.sourceBytes)
        XCTAssertEqual(replay.byteRange, 0..<fixture.sourceBytes.count)
    }

    func testMountValidatorRejectsUnregisteredLocatorVersion() throws {
        let fixture = try SourceLocatorSnapshotFixture(adapterVersion: "2")
        defer { fixture.remove() }

        XCTAssertThrowsError(try KnowledgeValidator().validateSnapshot(
            at: fixture.root,
            mode: .mount,
            policy: KnowledgeValidationPolicy(
                evaluationDate: SourceLocatorSnapshotFixture.timestamp))) { error in
            let domain = error as? KnowledgeDomainError
            XCTAssertEqual(domain?.failure.code, .integrityFailed)
            XCTAssertTrue(domain?.diagnostics.contains(where: {
                $0.code == "source_locator"
            }) == true)
        }
    }

    func testMountValidatorRejectsPathOrSecretSourceIdentityWithoutEcho() throws {
        for sourceID in [
            "/Users/private/secret.pdf",
            "sk-supersecret123456",
        ] {
            let fixture = try SourceLocatorSnapshotFixture(sourceID: sourceID)
            defer { fixture.remove() }

            XCTAssertThrowsError(try KnowledgeValidator().validateSnapshot(
                at: fixture.root,
                mode: .mount,
                policy: KnowledgeValidationPolicy(
                    evaluationDate: SourceLocatorSnapshotFixture.timestamp))) { error in
                guard let domain = error as? KnowledgeDomainError else {
                    return XCTFail("Expected fail-closed KnowledgeDomainError")
                }
                XCTAssertEqual(domain.failure.code, .integrityFailed)
                XCTAssertTrue(domain.diagnostics.contains(where: {
                    $0.code == "source_id" || $0.code == "chunk_decode"
                }))
                let visible = ([domain.failure.message]
                    + domain.diagnostics.map(\.message))
                    .joined(separator: "\n")
                XCTAssertFalse(visible.contains(sourceID))
                XCTAssertFalse(visible.contains("/Users/private"))
                XCTAssertFalse(visible.contains("sk-supersecret"))
            }
        }
    }

    func testMountValidatorRejectsFootnoteWithoutDeclaredSource() throws {
        let fixture = try SourceLocatorSnapshotFixture(conceptBody: """
        A direct-mounted claim uses unknown attribution.[^unknown-source]

        [^unknown-source]: This definition has no declared OKF source.
        """)
        defer { fixture.remove() }

        XCTAssertThrowsError(try KnowledgeValidator().validateSnapshot(
            at: fixture.root,
            mode: .mount,
            policy: KnowledgeValidationPolicy(
                evaluationDate: SourceLocatorSnapshotFixture.timestamp))) { error in
            guard let domain = error as? KnowledgeDomainError else {
                return XCTFail("Expected fail-closed KnowledgeDomainError")
            }
            XCTAssertEqual(domain.failure.code, .integrityFailed)
            XCTAssertTrue(domain.diagnostics.contains(where: {
                $0.code == "source_attribution"
            }))
            XCTAssertFalse(domain.failure.message.contains("unknown-source"))
        }
    }

    func testEvidenceValidatorRejectsPathOrSecretSourceIdentityWithoutEcho() throws {
        let fixture = try SourceLocatorSnapshotFixture()
        defer { fixture.remove() }
        let validator = try KnowledgeValidator()
        let snapshot = try validator.validateSnapshot(
            at: fixture.root,
            mode: .mount,
            policy: KnowledgeValidationPolicy(
                evaluationDate: SourceLocatorSnapshotFixture.timestamp))
        let chunk = try XCTUnwrap(snapshot.chunks.first)

        for sourceID in [
            "/Users/private/secret.pdf",
            "sk-supersecret123456",
        ] {
            let evidence = KnowledgeSearchEvidence(
                evidenceID: "ev_portable_source_gate",
                rank: 1,
                text: chunk.text,
                textSha256: chunk.textSha256,
                evidenceURI:
                    "knowledge://kb_locator/snap_locator/ev_portable_source_gate",
                conceptID: chunk.conceptID,
                conceptRevision: chunk.conceptRevision,
                evidenceClass: chunk.evidenceClass,
                conceptLocator: chunk.conceptLocator,
                supportingConcepts: chunk.supportingConcepts,
                producer: nil,
                sourceIDs: [sourceID],
                sourceLocators: nil,
                trust: "human-reviewed",
                status: "stable",
                stale: false)
            XCTAssertThrowsError(try validator.validateEvidence(
                evidence,
                in: snapshot)) { error in
                guard let domain = error as? KnowledgeDomainError else {
                    return XCTFail("Expected fail-closed KnowledgeDomainError")
                }
                XCTAssertEqual(domain.failure.code, .integrityFailed)
                XCTAssertFalse(domain.failure.message.contains(sourceID))
                XCTAssertFalse(domain.failure.message.contains("/Users/private"))
                XCTAssertFalse(domain.failure.message.contains("sk-supersecret"))
            }
        }
    }

    func testMountValidatorRejectsUTF8BoundaryDrift() throws {
        let fixture = try SourceLocatorSnapshotFixture(
            locatorValue: "1:24")
        defer { fixture.remove() }

        XCTAssertThrowsError(try KnowledgeValidator().validateSnapshot(
            at: fixture.root,
            mode: .mount,
            policy: KnowledgeValidationPolicy(
                evaluationDate: SourceLocatorSnapshotFixture.timestamp))) { error in
            let domain = error as? KnowledgeDomainError
            XCTAssertEqual(domain?.failure.code, .integrityFailed)
            XCTAssertTrue(domain?.diagnostics.contains(where: {
                $0.code == "source_locator"
            }) == true)
        }
    }

    func testCustomExecutableAdapterFlowsFromMountIntoSearch() async throws {
        let adapter = LineOneSourceLocatorAdapter()
        let fixture = try SourceLocatorSnapshotFixture(
            adapterIdentity: adapter.descriptor.identity,
            adapterVersion: adapter.descriptor.version,
            locatorKind: "line-range",
            locatorValue: "1")
        defer { fixture.remove() }
        let sourceRegistry = try KnowledgeSourceLocatorAdapterRegistry(
            adapters: [adapter])
        let backendRegistry = try KnowledgeBackendRegistry(
            sourceLocatorAdapters: sourceRegistry)
        let snapshot = try KnowledgeValidator(
            backendRegistry: backendRegistry).validateSnapshot(
                at: fixture.root,
                mode: .mount,
                policy: KnowledgeValidationPolicy(
                    evaluationDate: SourceLocatorSnapshotFixture.timestamp))

        let reader = try KnowledgeSnapshotSearchReader(
            snapshot: snapshot,
            embeddingRegistry: KnowledgeEmbeddingRuntimeRegistry([
                SourceLocatorEmbeddingProvider(
                    modelIdentity: fixture.model),
            ]),
            policy: KnowledgeSearchPolicy(
                lexicalCandidateLimit: 0,
                evaluationDate: SourceLocatorSnapshotFixture.timestamp))
        let result = try await reader.search(
            knowledgeBase: "kb_locator",
            query: "grounded source",
            limit: 1)
        let locator = try XCTUnwrap(
            result.evidence?.first?.sourceLocators?.first)
        XCTAssertEqual(locator.kind, "line-range")
        XCTAssertEqual(
            try sourceRegistry.replay(locator, in: fixture.sourceBytes).content,
            Data("权限 source evidence.".utf8))
    }

    func testFinalGroundingReopensExactSnapshotAndFailsAfterUrgentPurge() async throws {
        let source = try SourceLocatorSnapshotFixture()
        defer { source.remove() }
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-final-grounding-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }

        let workspaceLease = WorkspaceLease(
            rootPath: workspaceRoot.path,
            access: .readWrite)
        let store = try KnowledgeSnapshotStore(
            root: workspaceRoot.appendingPathComponent(
                "knowledge",
                isDirectory: true),
            workspaceLease: workspaceLease,
            coordinationRoot: workspaceRoot.appendingPathComponent(
                "host-locks",
                isDirectory: true),
            createIfMissing: true)
        let writer = try store.acquireWriterLease()
        let staging = try writer.createStagingSnapshot(
            snapshotID: "snap_locator")
        do {
            for item in try FileManager.default.contentsOfDirectory(
                at: source.root,
                includingPropertiesForKeys: nil) {
                try FileManager.default.copyItem(
                    at: item,
                    to: staging.root.appendingPathComponent(
                        item.lastPathComponent,
                        isDirectory: item.hasDirectoryPath))
            }
            let validator = try KnowledgeValidator()
            let validated = try validator.validateSnapshot(
                at: staging.root,
                mode: .publish,
                policy: KnowledgeValidationPolicy(
                    evaluationDate: SourceLocatorSnapshotFixture.timestamp),
                workspaceLease: store.managedContentWorkspaceLease)
            _ = try writer.publishValidatedStaging(
                staging,
                validatedSnapshot: validated,
                expectedPointerRevision: nil)
        } catch {
            try? writer.abortStagingSnapshot(staging)
            writer.release()
            throw error
        }
        writer.release()

        let mountRegistry = KnowledgeMountRegistry(
            validator: try KnowledgeValidator(),
            policy: KnowledgeValidationPolicy(
                evaluationDate: SourceLocatorSnapshotFixture.timestamp))
        let authority = KnowledgeMountAuthority(
            sessionID: .new(),
            agentID: AgentID(rawValue: "agent_final_grounding"),
            taskID: nil,
            capabilityLeaseID: .new(),
            workspaceLeaseID: workspaceLease.id,
            workspaceRootIdentity: try XCTUnwrap(
                workspaceLease.rootIdentity))
        let binding = try await mountRegistry.mount(
            store: store,
            authority: authority)
        let embeddingProvider = SourceLocatorEmbeddingProvider(
            modelIdentity: source.model)
        let embeddingRegistry = try KnowledgeEmbeddingRuntimeRegistry([
            embeddingProvider,
        ])
        let searchPolicy = KnowledgeSearchPolicy(
            lexicalCandidateLimit: 0,
            evaluationDate: SourceLocatorSnapshotFixture.timestamp)
        let registration = try SearchKnowledgeTool.registration(
            mountRegistry: mountRegistry,
            embeddingRegistry: embeddingRegistry,
            policy: searchPolicy,
            boundTo: binding)
        let registryVersion = try SearchKnowledgeTool
            .registryVersionComponent(
                binding: binding,
                embeddingRegistry: embeddingRegistry,
                policy: searchPolicy)
        let toolRegistry = ToolRegistry(
            registrations: [registration],
            registryVersion: registryVersion)
        let args = ToolArgs(
            raw: #"{"query":"grounded source","limit":1}"#)
        try registration.validateArguments(args)
        let capabilityLease = CapabilityLease(
            id: authority.capabilityLeaseID,
            tools: [.searchKnowledge])
        let authorization = try toolRegistry.resolveAuthorization(
            toolName: "search_knowledge",
            intent: registration.permissionIntent(
                args,
                workspaceRoot: workspaceRoot),
            risksNetwork: registration.risksNetwork(args),
            normalizedArguments: args.raw,
            invocation: ToolAuthorizationInvocationContext(
                sessionID: authority.sessionID,
                agent: authority.agentID,
                taskID: authority.taskID,
                toolCallID: "call_final_grounding"),
            capabilityLease: capabilityLease,
            workspaceLease: workspaceLease)
        let observation = try await registration.execute(
            args,
            in: ToolContext(
                workspaceRoot: workspaceRoot,
                workspaceLease: workspaceLease,
                authorization: authorization))
        let result = try KnowledgeJSON.decode(
            KnowledgeSearchResponse.self,
            from: Data(observation.text.utf8))
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(observation.structuredResult?.resultType, .complete)
        XCTAssertEqual(observation.structuredResult?.isError, false)

        let evidence = try XCTUnwrap(result.evidence?.first)
        let grounding = ToolGroundingEvidence(
            toolName: "search_knowledge",
            evidenceID: evidence.evidenceID,
            knowledgeBase: try XCTUnwrap(result.knowledgeBase),
            knowledgeBaseRevision: try XCTUnwrap(
                result.knowledgeBaseRevision),
            retrievalSnapshot: try XCTUnwrap(result.retrievalSnapshot),
            retrievalSnapshotRevision: try XCTUnwrap(
                result.retrievalSnapshotRevision),
            textSHA256: evidence.textSha256,
            evidenceURI: evidence.evidenceURI,
            structuredEvidence: try KnowledgeJSON.value(evidence))
        let revalidate = try XCTUnwrap(
            registration.groundingEvidenceRevalidator)
        try await revalidate(grounding)

        let receiptStore = try KnowledgeValidationReceiptStore(
            root: workspaceRoot.appendingPathComponent(
                "receipts",
                isDirectory: true))
        _ = try await mountRegistry.urgentPurge(
            storeID: "kb_locator",
            snapshotIDs: ["snap_locator"],
            receiptStore: receiptStore,
            timeoutNanoseconds: 1_000_000_000)
        do {
            try await revalidate(grounding)
            XCTFail("Purged evidence unexpectedly survived final grounding validation")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .revisionChanged)
        }
    }
}

private struct LineOneSourceLocatorAdapter: KnowledgeSourceLocatorAdapter {
    let descriptor = KnowledgeSourceLocatorAdapterDescriptor(
        identity: "org.vita.intatis.tests.line-one",
        version: "1",
        kinds: ["line-range"])

    func replay(
        _ locator: KnowledgeSourceLocator,
        in immutableSourceBytes: Data
    ) throws -> KnowledgeSourceLocatorReplay {
        guard locator.adapterIdentity == descriptor.identity,
              locator.adapterVersion == descriptor.version,
              locator.kind == "line-range",
              locator.value == "1",
              locator.sourceRevision == KnowledgeDigest.sha256(
                immutableSourceBytes),
              let newline = immutableSourceBytes.firstIndex(of: 0x0a) else {
            throw KnowledgeDomainError(
                .integrityFailed,
                "Line locator does not bind the first immutable source line.")
        }
        let range = immutableSourceBytes.startIndex..<newline
        return KnowledgeSourceLocatorReplay(
            byteRange: range,
            content: immutableSourceBytes.subdata(in: range))
    }
}

private struct SourceLocatorEmbeddingProvider: KnowledgeEmbeddingProvider {
    let modelIdentity: KnowledgeEmbeddingModelIdentity

    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [1, 0] }
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        [1, 0]
    }
}

private final class SourceLocatorSnapshotFixture {
    static let timestamp = "2026-08-09T00:00:00Z"

    let root: URL
    let sourceBytes = Data("权限 source evidence.\n".utf8)
    let model = KnowledgeEmbeddingModelIdentity(
        identity: "org.vita.intatis.tests.locator-embedding",
        revision: "1",
        tokenizerRevision: "1",
        runtimeBindingKind: .local,
        runtimeBindingDigest: KnowledgeDigest.sha256(
            "source-locator-test-runtime/1"),
        dimensions: 2,
        pooling: "sentence",
        maxInputTokens: 128)

    init(sourceID: String = "source-one",
         conceptBody: String =
            "A grounded source locator remains bound to immutable original bytes.",
         adapterIdentity: String = KnowledgeUTF8ByteRangeSourceLocatorAdapter.identity,
         adapterVersion: String = KnowledgeUTF8ByteRangeSourceLocatorAdapter.version,
         locatorKind: String = "utf8-byte-range",
         locatorValue: String? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "intatis-source-locator-\(UUID().uuidString)",
            isDirectory: true)
        try Self.makeDirectory(root)
        try Self.makeDirectory(root.appendingPathComponent("concepts"))
        try Self.makeDirectory(root.appendingPathComponent("references"))
        let rag = root.appendingPathComponent(".intatis-rag")
        let denseRoot = rag.appendingPathComponent("dense")
        try Self.makeDirectory(rag)
        try Self.makeDirectory(denseRoot)

        let index = Data("""
        ---
        okf_version: "0.2"
        ---

        # Locator fixture
        """.utf8)
        let conceptData = Data("""
        ---
        type: Policy
        sources:
          - id: \(sourceID)
            resource: ../references/source.txt
        status: stable
        ---

        \(conceptBody)
        """.utf8)
        try Self.write(index, to: root.appendingPathComponent("index.md"))
        let conceptURL = root.appendingPathComponent("concepts/locator.md")
        try Self.write(conceptData, to: conceptURL)
        try Self.write(
            sourceBytes,
            to: root.appendingPathComponent("references/source.txt"))

        let fileSystem = KnowledgeSecureFileSystem()
        let knowledgeInventory = try fileSystem.leafInventory(root: root)
        let bundleRevision = try KnowledgeSecureFileSystem
            .canonicalBundleDigest(knowledgeInventory)
        let concept = try OKFReader().readConcept(
            data: conceptData,
            relativePath: "concepts/locator.md")
        let chunked = try DeterministicKnowledgeChunker().chunk(
            concepts: [concept],
            bundleRevision: bundleRevision,
            producedAt: Self.timestamp)
        guard !chunked.chunks.isEmpty else {
            throw KnowledgeDomainError(
                .integrityFailed,
                "Source locator fixture produced no chunks.")
        }
        let locator = KnowledgeSourceLocator(
            sourceID: sourceID,
            sourceRevision: KnowledgeDigest.sha256(sourceBytes),
            adapterIdentity: adapterIdentity,
            adapterVersion: adapterVersion,
            kind: locatorKind,
            value: locatorValue ?? "0:\(sourceBytes.count)")
        let chunks = chunked.chunks.map { chunk in
            KnowledgeChunk(
                chunkID: chunk.chunkID,
                conceptID: chunk.conceptID,
                conceptRevision: chunk.conceptRevision,
                evidenceClass: chunk.evidenceClass,
                text: chunk.text,
                textSha256: chunk.textSha256,
                conceptLocator: chunk.conceptLocator,
                sourceIDs: chunk.sourceIDs,
                sourceLocators: [locator],
                producer: chunk.producer,
                supportingConcepts: chunk.supportingConcepts)
        }
        var chunkData = Data()
        for chunk in chunks.sorted(by: { $0.chunkID < $1.chunkID }) {
            chunkData.append(try KnowledgeJSON.encode(chunk))
            chunkData.append(0x0a)
        }
        let chunkingSeed = KnowledgeProfile.Chunking(
            manifest: ".intatis-rag/chunks.jsonl",
            algorithm: KnowledgeContract.deterministicChunkerIdentity,
            version: KnowledgeContract.deterministicChunkerVersion,
            parametersDigest: chunked.parametersDigest,
            manifestDigest: KnowledgeDigest.sha256("placeholder"))
        let chunkManifestDigest = try KnowledgeValidator.chunkManifestDigest(
            bundleRevision: bundleRevision,
            chunking: chunkingSeed,
            jsonLines: chunkData)
        let chunking = KnowledgeProfile.Chunking(
            manifest: chunkingSeed.manifest,
            algorithm: chunkingSeed.algorithm,
            version: chunkingSeed.version,
            parametersDigest: chunkingSeed.parametersDigest,
            manifestDigest: chunkManifestDigest)

        let denseFile = KnowledgeDenseIndexFile(
            dimensions: 2,
            vectors: try chunks.map {
                KnowledgeDenseVectorRecord(
                    chunkID: $0.chunkID,
                    values: try KnowledgeVectorMath.normalized([1, 0]))
            })
        let denseData = try KnowledgeJSON.encode(denseFile)
        let backend = KnowledgeBackendIdentity(
            identity: KnowledgeContract.exactKNNBackendIdentity,
            formatVersion: KnowledgeContract.exactKNNFormatVersion,
            runtimeVersion: KnowledgeContract.exactKNNRuntimeVersion)
        let denseSeed = KnowledgeEmbeddingIndexProfile(
            id: "dense_locator",
            componentRevision: KnowledgeDigest.sha256("placeholder"),
            indexPath: ".intatis-rag/dense/exact-knn.json",
            backend: backend,
            model: model,
            chunkManifestDigest: chunkManifestDigest,
            vectorCount: chunks.count,
            indexDigest: KnowledgeDigest.sha256(denseData))
        let dense = KnowledgeEmbeddingIndexProfile(
            id: denseSeed.id,
            componentRevision: try KnowledgeValidator
                .denseComponentRevision(denseSeed),
            indexPath: denseSeed.indexPath,
            backend: denseSeed.backend,
            model: denseSeed.model,
            chunkManifestDigest: denseSeed.chunkManifestDigest,
            vectorCount: denseSeed.vectorCount,
            indexDigest: denseSeed.indexDigest)
        let retrieval = KnowledgeProfile.Retrieval(
            dense: "required",
            lexical: "disabled",
            fusion: "dense_only",
            reranker: KnowledgeRerankerProfile(mode: .disabled, model: nil),
            evidenceContract: KnowledgeContract.evidenceContract)
        let snapshotSeed = KnowledgeProfile.RetrievalSnapshot(
            id: "snap_locator",
            revision: KnowledgeDigest.sha256("placeholder"),
            bundleRevision: bundleRevision,
            chunkManifestDigest: chunkManifestDigest,
            dense: KnowledgeComponentReference(
                id: dense.id,
                componentRevision: dense.componentRevision),
            lexical: nil,
            retrievalPolicyDigest: try KnowledgeDigest.canonical(retrieval),
            rerankerBindingDigest: try KnowledgeDigest.canonical(
                retrieval.reranker))
        let retrievalSnapshot = KnowledgeProfile.RetrievalSnapshot(
            id: snapshotSeed.id,
            revision: try KnowledgeValidator.retrievalSnapshotDigest(
                snapshotSeed),
            bundleRevision: snapshotSeed.bundleRevision,
            chunkManifestDigest: snapshotSeed.chunkManifestDigest,
            dense: snapshotSeed.dense,
            lexical: snapshotSeed.lexical,
            retrievalPolicyDigest: snapshotSeed.retrievalPolicyDigest,
            rerankerBindingDigest: snapshotSeed.rerankerBindingDigest)
        let profile = KnowledgeProfile(
            schema: KnowledgeContract.profileSchema,
            profile: KnowledgeContract.profileIdentity,
            profileVersion: KnowledgeContract.profileVersion,
            okf: KnowledgeProfile.OKF(
                version: KnowledgeContract.okfVersion,
                specCommit: KnowledgeContract.okfSpecCommit),
            bundle: KnowledgeProfile.Bundle(
                id: "kb_locator",
                revision: bundleRevision,
                createdAt: Self.timestamp),
            normalization: KnowledgeProfile.Normalization(
                textEncoding: "utf-8",
                lineEndings: "lf",
                unicode: "nfc",
                version: KnowledgeContract.textNormalizationVersion),
            chunking: chunking,
            embeddingIndexes: [dense],
            lexicalIndexes: [],
            retrieval: retrieval,
            retrievalSnapshot: retrievalSnapshot,
            integrity: KnowledgeProfile.Integrity(
                algorithm: "sha256",
                inventory: ".intatis-rag/checksums.json"))

        try Self.write(
            chunkData,
            to: rag.appendingPathComponent("chunks.jsonl"))
        try Self.write(
            denseData,
            to: denseRoot.appendingPathComponent("exact-knn.json"))
        try Self.write(
            KnowledgeJSON.encode(profile, pretty: true),
            to: rag.appendingPathComponent("profile.json"))
        let checksums = KnowledgeChecksums(
            files: try fileSystem.leafInventory(root: root))
        try Self.write(
            KnowledgeJSON.encode(checksums, pretty: true),
            to: rag.appendingPathComponent("checksums.json"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
    }

    private static func write(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
            throw KnowledgeDomainError(
                .unsafeStorage,
                "Could not write source locator test fixture.")
        }
    }
}
