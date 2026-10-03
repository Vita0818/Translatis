import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisTools
@testable import IntatisKnowledge

final class SearchKnowledgeToolTests: XCTestCase {
    func testRegistrationUsesExactSchemasAndTypedInvalidArguments() throws {
        let embedding = try embeddingRegistry(identity: "test.embedding.one")
        let registration = try SearchKnowledgeTool.registration(
            mountRegistry: mountRegistry(),
            embeddingRegistry: embedding,
            policy: policy())

        XCTAssertEqual(registration.descriptor.name, "search_knowledge")
        XCTAssertEqual(registration.descriptor.strict, true)
        XCTAssertEqual(registration.descriptor.supportsParallelCalls, true)
        XCTAssertNotNil(registration.descriptor.outputSchema)
        XCTAssertTrue(registration.descriptor.description.contains(
            "[[evidence:<evidence_id>]]"))

        let valid = ToolArgs(raw: #"{"knowledge_base":"kb_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","query":"refund","limit":2}"#)
        XCTAssertNoThrow(try registration.validateArguments(valid))
        let localIntent = registration.permissionIntent(
            valid,
            workspaceRoot: URL(fileURLWithPath: "/tmp/workspace"))
        XCTAssertEqual(localIntent.action, "knowledge.search.local")
        XCTAssertEqual(localIntent.dataEffects, [.read])
        XCTAssertFalse(localIntent.risks.contains(.networkAccess))
        XCTAssertEqual(
            registration.permissionActionPreview(valid)?.fields["executionSemantics"],
            "local_only")
        let hostDefault = ToolArgs(raw: #"{"knowledge_base":"kb_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","query":"refund","limit":null}"#)
        XCTAssertNoThrow(try registration.validateArguments(hostDefault))
        XCTAssertEqual(
            registration.permissionActionPreview(hostDefault)?.fields["limit"],
            "8")
        XCTAssertThrowsError(try registration.validateArguments(
            ToolArgs(raw: #"{"knowledge_base":"kb_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","query":"refund"}"#)))
        assertStrictObjectSchema(registration.descriptor.parameters)
        let invalid = ToolArgs(raw: #"{"knowledge_base":"kb_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","query":"refund","path":"/tmp/leak"}"#)
        XCTAssertThrowsError(try registration.validateArguments(invalid))

        let observation = try XCTUnwrap(registration.argumentValidationFailure(
            message: "implementation detail must not escape"))
        let response = try KnowledgeJSON.decode(
            KnowledgeSearchResponse.self,
            from: Data(observation.text.utf8))
        XCTAssertEqual(response.status, .error)
        XCTAssertEqual(response.error?.code, .toolInputInvalid)
        XCTAssertEqual(observation.structuredResult?.resultType, .complete)
        XCTAssertEqual(observation.structuredResult?.isError, true)
        try assertStructuredEnvelope(observation, registration: registration)
    }

    func testUnknownHandleAfterExactAuthorizationIsTypedAndNonEnumerating() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-tool-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let embedding = try embeddingRegistry(identity: "test.embedding.auth")
        let policy = policy()
        let registration = try SearchKnowledgeTool.registration(
            mountRegistry: mountRegistry(),
            embeddingRegistry: embedding,
            policy: policy)
        let version = try SearchKnowledgeTool.registryVersionComponent(
            binding: nil,
            embeddingRegistry: embedding,
            policy: policy)
        let registry = ToolRegistry(
            registrations: [registration],
            registryVersion: version)
        let raw = #"{"knowledge_base":"kb_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","query":"refund","limit":null}"#
        let args = ToolArgs(raw: raw)
        try registration.validateArguments(args)
        let capabilityLease = CapabilityLease(tools: [.searchKnowledge])
        let workspaceLease = WorkspaceLease(
            rootPath: root.path,
            access: .readOnly,
            deniedPatterns: [])
        let authorization = try registry.resolveAuthorization(
            toolName: "search_knowledge",
            intent: registration.permissionIntent(args, workspaceRoot: root),
            risksNetwork: registration.risksNetwork(args),
            normalizedArguments: raw,
            invocation: ToolAuthorizationInvocationContext(
                sessionID: SessionID(rawValue: "session-search"),
                agent: AgentID(rawValue: "main"),
                toolCallID: "call-search"),
            capabilityLease: capabilityLease,
            workspaceLease: workspaceLease)
        let observation = try await registration.execute(
            args,
            in: ToolContext(
                workspaceRoot: root,
                workspaceLease: workspaceLease,
                authorization: authorization))

        let response = try KnowledgeJSON.decode(
            KnowledgeSearchResponse.self,
            from: Data(observation.text.utf8))
        XCTAssertEqual(response.status, .error)
        XCTAssertEqual(response.error?.code, .accessDenied)
        XCTAssertNil(response.knowledgeBase)
        XCTAssertNil(response.knowledgeBaseRevision)
        XCTAssertEqual(observation.structuredResult?.isError, true)
        try assertStructuredEnvelope(observation, registration: registration)
    }

    func testRegistryVersionBindsBackendRerankerAndCompletePolicy() throws {
        let firstEmbedding = try embeddingRegistry(identity: "test.embedding.first")
        let secondEmbedding = try embeddingRegistry(identity: "test.embedding.second")
        let basePolicy = policy()
        var changedPolicy = basePolicy
        changedPolicy.allowedConceptIDs = ["concepts/only"]
        changedPolicy.allowedSourceIDs = ["source-only"]
        changedPolicy.minimumDenseSimilarity = 0.75
        let provider = try XCTUnwrap(firstEmbeddingProvider(
            identity: "test.embedding.first"))
        let reranker = try KnowledgeEmbeddingCosineRerankerProvider(
            embeddingProvider: provider)
        let rerankerRegistry = try KnowledgeRerankerRuntimeRegistry([reranker])

        let baseline = try SearchKnowledgeTool.registryVersionComponent(
            binding: nil,
            embeddingRegistry: firstEmbedding,
            policy: basePolicy)
        let changedEmbedding = try SearchKnowledgeTool.registryVersionComponent(
            binding: nil,
            embeddingRegistry: secondEmbedding,
            policy: basePolicy)
        let changedReranker = try SearchKnowledgeTool.registryVersionComponent(
            binding: nil,
            embeddingRegistry: firstEmbedding,
            rerankerRegistry: rerankerRegistry,
            policy: basePolicy)
        let changedPolicyVersion = try SearchKnowledgeTool.registryVersionComponent(
            binding: nil,
            embeddingRegistry: firstEmbedding,
            policy: changedPolicy)

        XCTAssertTrue(KnowledgeDigest.isValid(baseline))
        XCTAssertNotEqual(baseline, changedEmbedding)
        XCTAssertNotEqual(baseline, changedReranker)
        XCTAssertNotEqual(baseline, changedPolicyVersion)
    }

    func testSnapshotBoundRegistrationRejectsHandleOverride() throws {
        let binding = KnowledgeMountedSnapshotBinding(
            handle: try XCTUnwrap(KnowledgeBaseHandle(
                rawValue: "kb_cccccccccccccccccccccccccccccccc")),
            storeID: "kb_store",
            storePointerRevision: 1,
            admissionKind: .current,
            knowledgeBaseRevision: KnowledgeDigest.sha256("bundle"),
            snapshotID: "snap_bound",
            snapshotRevision: KnowledgeDigest.sha256("snapshot"),
            backendRegistryDigest: try KnowledgeBackendRegistry().digest)
        let embedding = try embeddingRegistry(identity: "test.embedding.bound")
        let registration = try SearchKnowledgeTool.registration(
            mountRegistry: mountRegistry(),
            embeddingRegistry: embedding,
            policy: policy(),
            boundTo: binding)

        XCTAssertNoThrow(try registration.validateArguments(
            ToolArgs(raw: #"{"query":"refund","limit":1}"#)))
        XCTAssertThrowsError(try registration.validateArguments(
            ToolArgs(raw: #"{"knowledge_base":"kb_dddddddddddddddddddddddddddddddd","query":"refund","limit":null}"#)))
        guard case .object(let schema) = registration.descriptor.parameters,
              case .object(let properties)? = schema["properties"] else {
            return XCTFail("Expected an object input schema")
        }
        XCTAssertNil(properties["knowledge_base"])
        assertStrictObjectSchema(registration.descriptor.parameters)
        XCTAssertTrue(registration.descriptor.description.contains(
            binding.knowledgeBaseHandle))
    }

    private func assertStructuredEnvelope(
        _ observation: ToolObservation,
        registration: ToolRegistration
    ) throws {
        let result = try XCTUnwrap(observation.structuredResult)
        let structured = try XCTUnwrap(result.structuredContent)
        let structuredBlock = try XCTUnwrap(result.content.first(where: {
            $0.kind == .structuredJSON
        }))
        XCTAssertEqual(structuredBlock.structuredJSON, structured)
        let outputSchema = try XCTUnwrap(registration.descriptor.outputSchema)
        try KnowledgeJSONSchemaValidator().validate(
            structured,
            againstDynamicSchema: outputSchema)
        let schemaData = try KnowledgeJSON.encode(outputSchema)
        let expectedHash = String(
            KnowledgeDigest.sha256(schemaData).dropFirst("sha256:".count))
        XCTAssertEqual(result.outputSchemaHash, expectedHash)
        let summaryBytes = result.content
            .filter { $0.kind == .text }
            .compactMap(\.byteCount)
            .reduce(0, +)
        XCTAssertEqual(
            result.totalByteCount,
            Data(observation.text.utf8).count * 2 + summaryBytes)
    }

    private func assertStrictObjectSchema(
        _ value: JSONValue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .object(let schema) = value,
              case .object(let properties)? = schema["properties"],
              case .array(let requiredValues)? = schema["required"] else {
            return XCTFail(
                "Expected a strict object schema",
                file: file,
                line: line)
        }
        let required = Set(requiredValues.compactMap { value -> String? in
            guard case .string(let name) = value else { return nil }
            return name
        })
        XCTAssertEqual(
            required,
            Set(properties.keys),
            file: file,
            line: line)
        XCTAssertEqual(
            schema["additionalProperties"],
            .bool(false),
            file: file,
            line: line)
    }

    private func mountRegistry() -> KnowledgeMountRegistry {
        KnowledgeMountRegistry(
            policy: KnowledgeValidationPolicy(
                evaluationDate: "2026-08-09T00:00:00Z"),
            validate: { _, _, _, _ in
                throw KnowledgeDomainError(
                    .internalError,
                    "Unexpected validator call in registration test.")
            })
    }

    private func policy() -> KnowledgeSearchPolicy {
        KnowledgeSearchPolicy(evaluationDate: "2026-08-09T00:00:00Z")
    }

    private func embeddingRegistry(
        identity: String
    ) throws -> KnowledgeEmbeddingRuntimeRegistry {
        try KnowledgeEmbeddingRuntimeRegistry([
            try XCTUnwrap(firstEmbeddingProvider(identity: identity)),
        ])
    }

    private func firstEmbeddingProvider(
        identity: String
    ) -> ToolTestEmbeddingProvider? {
        ToolTestEmbeddingProvider(identity: identity)
    }
}

private struct ToolTestEmbeddingProvider: KnowledgeEmbeddingProvider {
    let modelIdentity: KnowledgeEmbeddingModelIdentity

    init(identity: String) {
        modelIdentity = KnowledgeEmbeddingModelIdentity(
            identity: identity,
            revision: "revision-1",
            tokenizerRevision: "tokenizer-1",
            runtimeBindingKind: .local,
            runtimeBindingDigest: KnowledgeDigest.sha256(
                "runtime:\(identity)"),
            dimensions: 2,
            pooling: "test",
            maxInputTokens: 32)
    }

    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [1, 0] }
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        [1, 0]
    }
}
