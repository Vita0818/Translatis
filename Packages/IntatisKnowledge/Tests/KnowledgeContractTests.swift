import XCTest
@testable import IntatisKnowledge

final class KnowledgeContractTests: XCTestCase {
    func testKnowledgeDiagnosticsRedactUntrustedSubjectsOnInitAndDecode() throws {
        let secret = "sk-abcdefghijklmnopqrstuvwxyz0123456789"
        let subject = "concepts/\(secret).md"
        let message = "failed https://private.example.invalid/\(secret)"

        let initialized = KnowledgeDiagnostic(
            severity: .error,
            code: "okf_concept_invalid",
            subject: subject,
            message: message)
        XCTAssertFalse(initialized.subject.contains(secret))
        XCTAssertFalse(initialized.message.contains(secret))
        XCTAssertFalse(initialized.message.contains("private.example.invalid"))

        let forged = #"{"severity":"error","code":"checksums_path","subject":"\#(subject)","message":"\#(message)"}"#
        let decoded = try KnowledgeJSON.decode(
            KnowledgeDiagnostic.self,
            from: Data(forged.utf8))
        XCTAssertFalse(decoded.subject.contains(secret))
        XCTAssertFalse(decoded.message.contains(secret))
        XCTAssertFalse(decoded.message.contains("private.example.invalid"))
        XCTAssertTrue(decoded.subject.contains("[REDACTED_TOKEN]"))
        XCTAssertTrue(decoded.message.contains("[REDACTED_URL]"))
    }

    func testEveryFrozenSchemaLoads() throws {
        let validator = KnowledgeJSONSchemaValidator()
        for schema in KnowledgeJSONSchemaValidator.Schema.allCases {
            guard case .object = try validator.schemaValue(schema) else {
                return XCTFail("\(schema.rawValue) is not an object schema")
            }
        }
    }

    func testStoreSchemaRejectsAdditionalPropertiesAndEscapingSnapshot() throws {
        let validator = KnowledgeJSONSchemaValidator()
        let valid = #"{"schema":"intatis-rag-store/1","store_id":"kb_demo","revision":1,"current_snapshot":"snap_one","current_snapshot_revision":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#
        XCTAssertNoThrow(try validator.validate(
            data: Data(valid.utf8),
            against: .store))

        let extra = valid.dropLast() + #", "path":"/private/secret"}"#
        XCTAssertThrowsError(try validator.validate(
            data: Data(extra.utf8),
            against: .store))
        let escape = valid.replacingOccurrences(
            of: "snap_one",
            with: "../snap_one")
        XCTAssertThrowsError(try validator.validate(
            data: Data(escape.utf8),
            against: .store))
    }

    func testEvidenceConditionalBranchesAreStrict() throws {
        let validator = KnowledgeJSONSchemaValidator()
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let exact = """
        {
          "evidence_id":"ev_one",
          "rank":1,
          "text":"grounded",
          "text_sha256":"\(digest)",
          "evidence_uri":"knowledge://kb_demo/snap_one/ev_one",
          "concept_id":"concepts/one",
          "concept_revision":"\(digest)",
          "evidence_class":"exact_concept_slice",
          "concept_locator":{"kind":"utf8-byte-range","start":1,"end":2},
          "source_ids":["source-one"],
          "status":"stable",
          "stale":false
        }
        """
        XCTAssertNoThrow(try validator.validate(
            data: Data(exact.utf8),
            against: .evidence))
        let forged = exact.replacingOccurrences(
            of: #""status":"stable""#,
            with: #""producer":{"identity":"model","version":"1","at":"2026-08-09T00:00:00Z"},"status":"stable""#)
        XCTAssertThrowsError(try validator.validate(
            data: Data(forged.utf8),
            against: .evidence))
    }

    func testChunkSchemaValidatesSourceLocatorWithoutExternalResolution() throws {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let chunk = """
        {
          "schema":"intatis-chunk/1",
          "chunk_id":"chk_one",
          "concept_id":"concepts/one",
          "concept_revision":"\(digest)",
          "evidence_class":"exact_concept_slice",
          "text":"grounded",
          "text_sha256":"\(digest)",
          "concept_locator":{"kind":"utf8-byte-range","start":0,"end":8},
          "source_ids":["source-one"],
          "source_locators":[{
            "schema":"intatis-source-locator/1",
            "source_id":"source-one",
            "source_revision":"\(digest)",
            "adapter_identity":"org.vita.intatis.utf8-byte-range",
            "adapter_version":"1",
            "kind":"utf8-byte-range",
            "value":"0:8"
          }],
          "producer":{"identity":"chunker","version":"1","at":"2026-08-09T00:00:00Z"}
        }
        """
        let validator = KnowledgeJSONSchemaValidator()
        XCTAssertNoThrow(try validator.validate(
            data: Data(chunk.utf8),
            against: .chunk))
        let extra = chunk.replacingOccurrences(
            of: #""value":"0:8""#,
            with: #""value":"0:8","path":"/private/escape""#)
        XCTAssertThrowsError(try validator.validate(
            data: Data(extra.utf8),
            against: .chunk))
    }

    func testPortableSourceIdentityIsFrozenAcrossModelFacingSchemas() throws {
        XCTAssertTrue(KnowledgeSourceIdentity.isPortable("refund-policy"))
        XCTAssertTrue(KnowledgeSourceIdentity.isPortable("docs:security_permissions.v1"))
        for rejected in [
            "/Users/private/secret.pdf",
            #"C:\Users\private\secret.pdf"#,
            "source\ncontrol",
            "sk-supersecret123456",
        ] {
            XCTAssertFalse(KnowledgeSourceIdentity.isPortable(rejected))
        }

        let digest = "sha256:" + String(repeating: "a", count: 64)
        let pathID = "/Users/private/secret.pdf"
        let locator = """
        {
          "schema":"intatis-source-locator/1",
          "source_id":"\(pathID)",
          "source_revision":"\(digest)",
          "adapter_identity":"org.vita.intatis.utf8-byte-range",
          "adapter_version":"1",
          "kind":"utf8-byte-range",
          "value":"0:8"
        }
        """
        let chunk = """
        {
          "schema":"intatis-chunk/1",
          "chunk_id":"chk_one",
          "concept_id":"concepts/one",
          "concept_revision":"\(digest)",
          "evidence_class":"exact_concept_slice",
          "text":"grounded",
          "text_sha256":"\(digest)",
          "concept_locator":{"kind":"utf8-byte-range","start":0,"end":8},
          "source_ids":["\(pathID)"],
          "producer":{"identity":"chunker","version":"1","at":"2026-08-09T00:00:00Z"}
        }
        """
        let evidence = Self.exactEvidenceJSON(
            sourceID: pathID,
            digest: digest)
        let output = """
        {
          "status":"ok",
          "knowledge_base":"kb_demo",
          "knowledge_base_revision":"\(digest)",
          "retrieval_snapshot":"snap_one",
          "retrieval_snapshot_revision":"\(digest)",
          "rerank_applied":false,
          "truncated":false,
          "evidence":[\(evidence)]
        }
        """
        let validator = KnowledgeJSONSchemaValidator()
        for rejectedID in [pathID, "sk-supersecret123456"] {
            for (template, schema) in [
                (locator, KnowledgeJSONSchemaValidator.Schema.sourceLocator),
                (chunk, .chunk),
                (evidence, .evidence),
                (output, .searchOutput),
            ] {
                let payload = template.replacingOccurrences(
                    of: pathID,
                    with: rejectedID)
                XCTAssertThrowsError(try validator.validate(
                    data: Data(payload.utf8),
                    against: schema))
            }
        }
    }

    func testOKFReaderAcceptsV02AndLegacyCitations() throws {
        let reader = OKFReader()
        let modern = """
        ---
        type: Policy
        title: Refunds
        sources:
          - id: refund-policy
            resource: https://example.invalid/refund
        verified: { by: human:reviewer, at: 2026-08-09T00:00:00Z }
        ---

        # Rule
        Refunds require a receipt.
        """
        let concept = try reader.readConcept(
            data: Data(modern.utf8),
            relativePath: "concepts/refund.md")
        XCTAssertEqual(concept.conceptID, "concepts/refund")
        XCTAssertEqual(concept.sources.map(\.id), ["refund-policy"])
        XCTAssertEqual(concept.trustTier, "human-reviewed")

        let legacy = """
        ---
        type: Note
        timestamp: '2026-08-01T00:00:00Z'
        ---

        # Facts
        A legacy fact.

        # Citations
        - https://example.invalid/legacy
        """
        let old = try reader.readConcept(
            data: Data(legacy.utf8),
            relativePath: "concepts/legacy.md")
        XCTAssertEqual(old.legacyTimestamp, "2026-08-01T00:00:00Z")
        XCTAssertEqual(old.sources.count, 1)
        XCTAssertTrue(old.sources[0].id?.hasPrefix("legacy-") == true)
    }

    func testReservedIndexAndLogSemanticsApplyAtEveryHierarchyLevel() throws {
        let reader = OKFReader()
        let root = """
        ---
        okf_version: "0.2"
        ---
        # Bundle

        * [Policy](domain/policy.md) - policy
        """
        XCTAssertEqual(
            try reader.readIndexDocument(
                data: Data(root.utf8),
                relativePath: "index.md").declaredVersion,
            "0.2")
        XCTAssertNoThrow(try reader.readIndexDocument(
            data: Data("# Domain\n\n* [Policy](policy.md) - policy\n".utf8),
            relativePath: "domain/index.md"))
        XCTAssertNoThrow(try reader.readLogDocument(
            data: Data("""
            # Domain Update Log

            ## 2026-08-09
            * **Update**: Refreshed policy.

            ## 2026-08-08
            - **Creation**: Added policy.
            """.utf8),
            relativePath: "domain/log.md"))

        XCTAssertThrowsError(try reader.readIndexDocument(
            data: Data("""
            ---
            okf_version: "0.2"
            ---
            # Nested
            """.utf8),
            relativePath: "domain/index.md"))
        XCTAssertThrowsError(try reader.readIndexDocument(
            data: Data("""
            ---
            type: Index
            okf_version: "0.2"
            ---
            # Root
            """.utf8),
            relativePath: "index.md"))
        XCTAssertThrowsError(try reader.readLogDocument(
            data: Data("""
            # Log
            ## 2026-08-08
            * Older
            ## 2026-08-09
            * Newer
            """.utf8),
            relativePath: "log.md"))
        XCTAssertThrowsError(try reader.readLogDocument(
            data: Data("""
            # Log
            ## 2026-02-30
            * Impossible date
            """.utf8),
            relativePath: "log.md"))
    }

    func testOKFReaderRejectsAliasAndCustomTagSafetyHazards() {
        let reader = OKFReader()
        let alias = """
        ---
        type: &kind Policy
        title: *kind
        ---
        body
        """
        assertUnsafeStorage {
            _ = try reader.readConcept(
                data: Data(alias.utf8),
                relativePath: "concepts/alias.md")
        }
        assertUnsafeStorage {
            _ = try reader.readRootIndexVersion(data: Data(alias.utf8))
        }
        let tag = """
        ---
        type: !exec Policy
        ---
        body
        """
        assertUnsafeStorage {
            _ = try reader.readConcept(
                data: Data(tag.utf8),
                relativePath: "concepts/tag.md")
        }
        assertUnsafeStorage {
            _ = try reader.readRootIndexVersion(data: Data(tag.utf8))
        }
    }

    private func assertUnsafeStorage(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard let domain = error as? KnowledgeDomainError else {
                return XCTFail("Expected KnowledgeDomainError, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(domain.failure.code, .unsafeStorage, file: file, line: line)
        }
    }

    func testTokenizerSupportsChineseAndCodeIdentifiers() {
        let tokens = KnowledgeTextTokenizer.tokens(
            "权限链 PathConfinement.isWithin embed_query")
        XCTAssertTrue(tokens.contains("权"))
        XCTAssertTrue(tokens.contains("权限"))
        XCTAssertTrue(tokens.contains("pathconfinement"))
        XCTAssertTrue(tokens.contains("embed_query"))
    }

    func testUTF8SourceLocatorAdapterReplaysOnlyCanonicalImmutableRanges() throws {
        let source = Data("abc权限xyz".utf8)
        let locator = KnowledgeSourceLocator(
            sourceID: "source-one",
            sourceRevision: KnowledgeDigest.sha256(source),
            adapterIdentity: KnowledgeUTF8ByteRangeSourceLocatorAdapter.identity,
            adapterVersion: KnowledgeUTF8ByteRangeSourceLocatorAdapter.version,
            kind: "utf8-byte-range",
            value: "3:9")
        XCTAssertEqual(
            try KnowledgeUTF8ByteRangeSourceLocatorAdapter.replay(
                locator,
                in: source),
            3..<9)
        let replay = try KnowledgeSourceLocatorAdapterRegistry().replay(
            locator,
            in: source)
        XCTAssertEqual(replay.byteRange, 3..<9)
        XCTAssertEqual(replay.utf8Text, "权限")

        let nonCanonical = KnowledgeSourceLocator(
            sourceID: locator.sourceID,
            sourceRevision: locator.sourceRevision,
            adapterIdentity: locator.adapterIdentity,
            adapterVersion: locator.adapterVersion,
            kind: locator.kind,
            value: "03:9")
        XCTAssertThrowsError(
            try KnowledgeUTF8ByteRangeSourceLocatorAdapter.replay(
                nonCanonical,
                in: source))

        let splitCodePoint = KnowledgeSourceLocator(
            sourceID: locator.sourceID,
            sourceRevision: locator.sourceRevision,
            adapterIdentity: locator.adapterIdentity,
            adapterVersion: locator.adapterVersion,
            kind: locator.kind,
            value: "4:9")
        XCTAssertThrowsError(
            try KnowledgeUTF8ByteRangeSourceLocatorAdapter.replay(
                splitCodePoint,
                in: source))

        let wrongRevision = KnowledgeSourceLocator(
            sourceID: locator.sourceID,
            sourceRevision: KnowledgeDigest.sha256("different"),
            adapterIdentity: locator.adapterIdentity,
            adapterVersion: locator.adapterVersion,
            kind: locator.kind,
            value: locator.value)
        XCTAssertThrowsError(
            try KnowledgeUTF8ByteRangeSourceLocatorAdapter.replay(
                wrongRevision,
                in: source))

        let binary = Data([0xff, 0x61])
        let binaryLocator = KnowledgeSourceLocator(
            sourceID: locator.sourceID,
            sourceRevision: KnowledgeDigest.sha256(binary),
            adapterIdentity: locator.adapterIdentity,
            adapterVersion: locator.adapterVersion,
            kind: locator.kind,
            value: "1:2")
        XCTAssertThrowsError(
            try KnowledgeUTF8ByteRangeSourceLocatorAdapter.replay(
                binaryLocator,
                in: binary))
    }

    func testDefaultBackendRegistryPinsExecutableSourceLocatorAdapter() throws {
        let registry = try KnowledgeBackendRegistry()
        XCTAssertEqual(
            registry.sourceLocators,
            [KnowledgeUTF8ByteRangeSourceLocatorAdapter.key])
        XCTAssertNotEqual(
            registry.digest,
            try KnowledgeBackendRegistry(
                sourceLocatorAdapters: KnowledgeSourceLocatorAdapterRegistry(
                    adapters: [])).digest)
    }

    func testSourceLocatorRegistryIsDeterministicAndRejectsAmbiguity() throws {
        let alpha = ContractTestSourceLocatorAdapter(
            descriptor: .init(
                identity: "test.alpha",
                version: "1",
                kinds: ["line-range"]))
        let beta = ContractTestSourceLocatorAdapter(
            descriptor: .init(
                identity: "test.beta",
                version: "2",
                kinds: ["page"]))
        let forward = try KnowledgeSourceLocatorAdapterRegistry(
            adapters: [alpha, beta])
        let reverse = try KnowledgeSourceLocatorAdapterRegistry(
            adapters: [beta, alpha])
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.digest, reverse.digest)
        XCTAssertEqual(forward.descriptors.map(\.key), [
            "test.alpha@1", "test.beta@2",
        ])

        XCTAssertThrowsError(try KnowledgeSourceLocatorAdapterRegistry(
            adapters: [alpha, alpha]))
        XCTAssertThrowsError(try KnowledgeSourceLocatorAdapterRegistry(
            adapters: [ContractTestSourceLocatorAdapter(
                descriptor: .init(
                    identity: "test.ambiguous",
                    version: "1",
                    kinds: ["page", "page"]))]))
    }

    private static func exactEvidenceJSON(
        sourceID: String,
        digest: String
    ) -> String {
        """
        {
          "evidence_id":"ev_one",
          "rank":1,
          "text":"grounded",
          "text_sha256":"\(digest)",
          "evidence_uri":"knowledge://kb_demo/snap_one/ev_one",
          "concept_id":"concepts/one",
          "concept_revision":"\(digest)",
          "evidence_class":"exact_concept_slice",
          "concept_locator":{"kind":"utf8-byte-range","start":0,"end":8},
          "source_ids":["\(sourceID)"],
          "status":"stable",
          "stale":false
        }
        """
    }
}

private struct ContractTestSourceLocatorAdapter: KnowledgeSourceLocatorAdapter {
    let descriptor: KnowledgeSourceLocatorAdapterDescriptor

    func replay(
        _ locator: KnowledgeSourceLocator,
        in immutableSourceBytes: Data
    ) throws -> KnowledgeSourceLocatorReplay {
        KnowledgeSourceLocatorReplay(
            byteRange: nil,
            content: immutableSourceBytes)
    }
}
