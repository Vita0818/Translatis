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

final class ModelDrivenKnowledgeToolHostTests: XCTestCase {
    func testHostExposesOnlyCapabilitiesGrantedByExactWorkspaceAccess() async throws {
        let root = try makeDirectory("visibility")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try makeHost()
        let base = ToolRegistry(registrations: [], registryVersion: "base/1")

        let readOnlyLease = CapabilityLease(
            tools: [.buildKnowledge, .searchKnowledge])
        let readOnlyWorkspace = WorkspaceLease(
            rootPath: root.path,
            access: .readOnly,
            deniedPatterns: [])
        let readOnly = try await host.augment(
            HostToolRegistryAugmentationInput(
                sessionID: SessionID(rawValue: "session-read-only"),
                agentID: AgentID(rawValue: "worker"),
                taskID: nil,
                capabilityLease: readOnlyLease,
                workspaceLease: readOnlyWorkspace,
                baseRegistry: base))
        XCTAssertNil(readOnly.registry.registration(named: "build_knowledge"))
        let readOnlySearch = try XCTUnwrap(
            readOnly.registry.registration(named: "search_knowledge"))
        XCTAssertTrue(readOnlySearch.descriptor.description.contains(
            "[[evidence:<evidence_id>]]"))
        let readOnlyDrained = await readOnly.close()
        XCTAssertTrue(readOnlyDrained)

        let readWriteWorkspace = WorkspaceLease(
            rootPath: root.path,
            access: .readWrite,
            deniedPatterns: [])
        let readWrite = try await host.augment(
            HostToolRegistryAugmentationInput(
                sessionID: SessionID(rawValue: "session-read-write"),
                agentID: AgentID(rawValue: "main"),
                taskID: nil,
                capabilityLease: readOnlyLease,
                workspaceLease: readWriteWorkspace,
                baseRegistry: base))
        let build = try XCTUnwrap(
            readWrite.registry.registration(named: "build_knowledge"))
        XCTAssertNotNil(readWrite.registry.registration(named: "search_knowledge"))
        XCTAssertNil(build.descriptor.strict)
        XCTAssertEqual(build.descriptor.sideEffect, .write)
        XCTAssertTrue(build.descriptor.description.contains("index.md"))
        XCTAssertTrue(build.descriptor.description.contains(
            "sources: [{id: source-1"))
        XCTAssertTrue(build.descriptor.description.contains(
            "Claim text.[^source-1]"))
        XCTAssertTrue(build.descriptor.description.contains(
            "Do not invent provenance"))
        let parameterText = String(
            decoding: try JSONEncoder().encode(build.descriptor.parameters),
            as: UTF8.self)
        XCTAssertTrue(parameterText.contains(
            "Workspace-authorized OKF 0.2 draft"))
        XCTAssertTrue(build.risksNetwork(
            ToolArgs(raw: #"{"draft_path":"draft","store_path":"store"}"#)))
        XCTAssertNotNil(build.descriptor.outputSchema)

        let invalid = ToolArgs(raw: #"{"draft_path":"draft","store_path":"store","expected_store_id":"kb_existing"}"#)
        XCTAssertThrowsError(try build.validateArguments(invalid))
        let observation = try XCTUnwrap(
            build.argumentValidationFailure(message: "do not expose internals"))
        let structured = try XCTUnwrap(
            observation.structuredResult?.structuredContent)
        let outputSchema = try XCTUnwrap(build.descriptor.outputSchema)
        let validator = KnowledgeJSONSchemaValidator()
        try validator.validate(
            structured,
            againstDynamicSchema: outputSchema)
        XCTAssertThrowsError(try validator.validate(
            .object(["status": .string("ok")]),
            againstDynamicSchema: outputSchema))
        XCTAssertThrowsError(try validator.validate(
            .object(["status": .string("error")]),
            againstDynamicSchema: outputSchema))
        let readWriteDrained = await readWrite.close()
        XCTAssertTrue(readWriteDrained)

        let noKnowledge = CapabilityLease(tools: [.readWorkspace])
        do {
            _ = try await host.augment(
                HostToolRegistryAugmentationInput(
                    sessionID: SessionID(rawValue: "session-no-knowledge"),
                    agentID: AgentID(rawValue: "worker"),
                    taskID: nil,
                    capabilityLease: noKnowledge,
                    workspaceLease: readWriteWorkspace,
                    baseRegistry: base))
            XCTFail("a lease without a Knowledge capability must not receive tools")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .accessDenied)
        }
    }

    func testRegistryVersionBindsCompleteSearchPolicy() async throws {
        let root = try makeDirectory("policy")
        defer { try? FileManager.default.removeItem(at: root) }
        var baselinePolicy = KnowledgeSearchPolicy(
            evaluationDate: "2026-08-10T00:00:00Z")
        let baselineHost = try makeHost(policy: baselinePolicy)
        baselinePolicy.allowedConceptIDs = ["concepts/only"]
        baselinePolicy.allowedSourceIDs = ["source-only"]
        baselinePolicy.resultBudget.maximumSerializedBytes -= 1
        let changedHost = try makeHost(policy: baselinePolicy)
        let capability = CapabilityLease(tools: [.searchKnowledge])
        let workspace = WorkspaceLease(
            rootPath: root.path,
            access: .readOnly,
            deniedPatterns: [])
        let input = HostToolRegistryAugmentationInput(
            sessionID: SessionID(rawValue: "session-policy"),
            agentID: AgentID(rawValue: "main"),
            taskID: nil,
            capabilityLease: capability,
            workspaceLease: workspace,
            baseRegistry: ToolRegistry(
                registrations: [],
                registryVersion: "base/1"))

        let baseline = try await baselineHost.augment(input)
        let changed = try await changedHost.augment(input)
        XCTAssertNotEqual(
            baseline.registry.registryVersion,
            changed.registry.registryVersion)
        let baselineDrained = await baseline.close()
        let changedDrained = await changed.close()
        XCTAssertTrue(baselineDrained)
        XCTAssertTrue(changedDrained)
    }

    func testKnowledgeLeaseRejectsBroadWriteAndRootReplacement() throws {
        XCTAssertThrowsError(try KnowledgeLease.validateRequestedPath("/"))
        XCTAssertThrowsError(try KnowledgeLease.validateRequestedPath("/var"))
        XCTAssertThrowsError(try KnowledgeLease.validateRequestedPath(
            "/private/var"))
        XCTAssertThrowsError(try KnowledgeLease.validateRequestedPath(
            FileManager.default.homeDirectoryForCurrentUser.path))

        let root = try makeDirectory("lease")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try KnowledgeLease(
            root: root,
            sessionID: SessionID(rawValue: "session-lease"),
            agentID: AgentID(rawValue: "main"),
            reuseScope: .session,
            access: .readOnly,
            operations: [.build],
            authorizationReferenceKind: .cliPermission,
            authorizationReferenceDigest: KnowledgeDigest.sha256("permission")))

        let lease = try KnowledgeLease(
            root: root,
            sessionID: SessionID(rawValue: "session-lease"),
            agentID: AgentID(rawValue: "main"),
            reuseScope: .session,
            access: .readOnly,
            operations: [.search],
            authorizationReferenceKind: .cliPermission,
            authorizationReferenceDigest: KnowledgeDigest.sha256("permission"))
        XCTAssertNoThrow(try lease.validate(
            sessionID: SessionID(rawValue: "session-lease"),
            agentID: AgentID(rawValue: "main"),
            taskID: nil,
            turnID: nil,
            operation: .search))
        XCTAssertFalse(lease.durableProjection.rootFingerprint.contains(root.path))

        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        XCTAssertThrowsError(try lease.validate(
            sessionID: SessionID(rawValue: "session-lease"),
            agentID: AgentID(rawValue: "main"),
            taskID: nil,
            turnID: nil,
            operation: .search))
    }

    func testKnowledgeLeaseRejectsSymbolicLinkLeaf() throws {
        let parent = try makeDirectory("lease-symlink")
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent(
            "target",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let link = parent.appendingPathComponent(
            "link",
            isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target)

        XCTAssertThrowsError(try KnowledgeLease.validateRequestedPath(
            link.path)) { error in
            XCTAssertEqual(
                (error as? KnowledgeDomainError)?.failure.code,
                .accessDenied)
        }
    }

    func testSessionKnowledgeBookmarkStoreIsSeparateOwnerOnlyAndReadMerged() throws {
        let support = try makeDirectory("bookmark-support")
        defer { try? FileManager.default.removeItem(at: support) }
        let session = SessionID(rawValue: "session-bookmarks")
        let firstPath = "/tmp/intatis-external-knowledge-a"
        let secondPath = "/tmp/intatis-external-knowledge-b"
        _ = try SessionKnowledgeAccessStore.upsert(
            root: support,
            session: session,
            entry: SessionKnowledgeAccessEntry(
                path: firstPath,
                bookmarkData: Data("bookmark-a".utf8),
                authorizationReferenceDigest: KnowledgeDigest.sha256("bookmark-a")))
        _ = try SessionKnowledgeAccessStore.upsert(
            root: support,
            session: session,
            entry: SessionKnowledgeAccessEntry(
                path: secondPath,
                bookmarkData: Data("bookmark-b".utf8),
                authorizationReferenceDigest: KnowledgeDigest.sha256("bookmark-b")))

        let loaded = try XCTUnwrap(
            SessionKnowledgeAccessStore.load(root: support, session: session))
        XCTAssertEqual(loaded.entries.map(\.path), [firstPath, secondPath])
        let file = try SessionKnowledgeAccessStore.fileURL(
            root: support,
            session: session)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o777, 0o600)
        XCTAssertTrue(file.lastPathComponent == "knowledge-access.plist")

        let revoked = try SessionKnowledgeAccessStore.remove(
            root: support,
            session: session,
            path: firstPath)
        XCTAssertEqual(revoked.entries.map(\.path), [secondPath])
        XCTAssertNil(try SessionKnowledgeAccessStore.entry(
            root: support,
            session: session,
            path: firstPath))
        XCTAssertNotNil(try SessionKnowledgeAccessStore.entry(
            root: support,
            session: session,
            path: secondPath))
    }

    func testSessionKnowledgeBookmarkStoreRejectsUnsafeLockFiles() throws {
        let support = try makeDirectory("bookmark-unsafe-lock")
        defer { try? FileManager.default.removeItem(at: support) }
        let session = SessionID(rawValue: "session-bookmark-unsafe-lock")
        let file = try SessionKnowledgeAccessStore.fileURL(
            root: support,
            session: session)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let lock = file.appendingPathExtension("lock")
        try Data("unsafe-lock".utf8).write(to: lock)
        let secondLink = support.appendingPathComponent("second-lock-link")
        try FileManager.default.linkItem(at: lock, to: secondLink)

        XCTAssertThrowsError(try SessionKnowledgeAccessStore.upsert(
            root: support,
            session: session,
            entry: SessionKnowledgeAccessEntry(
                path: "/tmp/intatis-external-knowledge-unsafe-lock",
                bookmarkData: Data("bookmark".utf8),
                authorizationReferenceDigest: KnowledgeDigest.sha256(
                    "bookmark-unsafe-lock")))) { error in
            XCTAssertEqual(
                error as? SessionKnowledgeAccessStoreError,
                .lockUnavailable)
        }

        try FileManager.default.removeItem(at: secondLink)
        try FileManager.default.removeItem(at: lock)
        let target = support.appendingPathComponent("lock-target")
        try Data("unsafe-lock-target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: lock,
            withDestinationURL: target)

        XCTAssertThrowsError(try SessionKnowledgeAccessStore.load(
            root: support,
            session: session)) { error in
            XCTAssertEqual(
                error as? SessionKnowledgeAccessStoreError,
                .lockUnavailable)
        }
    }

    func testExternalAuthorityRejectsParentSubstitutionAndReleasesGrant() async throws {
        let workspaceRoot = try makeDirectory("external-workspace")
        let externalParent = try makeDirectory("external-parent")
        let requested = externalParent.appendingPathComponent(
            "exact-store",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: requested,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        defer {
            try? FileManager.default.removeItem(at: workspaceRoot)
            try? FileManager.default.removeItem(at: externalParent)
        }

        let sessionID = SessionID(rawValue: "session-external-mismatch")
        let agentID = AgentID(rawValue: "main")
        let workspaceLease = WorkspaceLease(
            rootPath: workspaceRoot.path,
            access: .readWrite,
            deniedPatterns: [])
        let releaseProbe = KnowledgeAuthorityReleaseProbe()
        let provider = KnowledgeExternalAuthorityProvider { request in
            let wrongLease = try KnowledgeLease(
                root: externalParent,
                sessionID: request.sessionID,
                agentID: request.agentID,
                taskID: request.taskID,
                reuseScope: .session,
                access: .readOnly,
                operations: [.search],
                authorizationReferenceKind: .cliPermission,
                authorizationReferenceDigest: KnowledgeDigest.sha256(
                    "parent-substitution"))
            return KnowledgeExternalAuthorityGrant(
                lease: wrongLease,
                release: { await releaseProbe.released() })
        }
        let authorization = ResolvedToolAuthorization(
            authorizationID: "external-mismatch-authorization",
            registryVersion: "test/1",
            concreteToolID: "test/1/search_knowledge",
            descriptorFingerprint: "test-descriptor",
            toolName: "search_knowledge",
            canonicalAction: "knowledge.search.remote",
            canonicalPermission: "knowledge.search",
            requiredCapabilities: [.searchKnowledge],
            membership: .granted,
            capabilityLeaseID: nil,
            capabilityTaskID: nil,
            workspaceLeaseID: workspaceLease.id,
            workspaceAccess: .readWrite,
            workspaceRootIdentity: workspaceLease.rootIdentity,
            invocation: ToolAuthorizationInvocationContext(
                sessionID: sessionID,
                agent: agentID),
            normalizedArgumentsDigest: KnowledgeDigest.sha256(requested.path),
            normalizedArgumentsCharacterCount: requested.path.count,
            intent: PermissionIntent(
                action: "knowledge.search.remote",
                resources: [],
                dataEffects: [.read, .network],
                risks: [.networkAccess],
                replayPolicy: .safeToReplay),
            sideEffect: .network,
            risksNetwork: true,
            replayPolicy: .safeToReplay,
            workspaceID: workspaceLease.workspaceID,
            workspaceRootPath: workspaceLease.rootPath,
            workspaceLeaseFingerprint:
                ToolRegistry.authorizationFingerprint(workspaceLease))

        do {
            _ = try await KnowledgeStoreAuthorityResolver(
                externalProvider: provider).resolve(
                    storePath: requested.path,
                    operation: .search,
                    authorization: authorization,
                    workspaceLease: workspaceLease)
            XCTFail("a parent-directory lease must not authorize its child")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .accessDenied)
        }
        let releaseCount = await releaseProbe.count()
        XCTAssertEqual(releaseCount, 1)
    }

    private func makeHost(
        policy: KnowledgeSearchPolicy = KnowledgeSearchPolicy(
            evaluationDate: "2026-08-10T00:00:00Z")
    ) throws -> ModelDrivenKnowledgeToolHost {
        try ModelDrivenKnowledgeToolHost(
            embeddingProvider: HostTestEmbeddingProvider(),
            rerankerProvider: HostTestRerankerProvider(),
            authorityResolver: KnowledgeStoreAuthorityResolver(),
            policy: policy)
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-model-knowledge-\(label)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        return url
    }
}

private actor KnowledgeAuthorityReleaseProbe {
    private var releases = 0

    func released() { releases += 1 }
    func count() -> Int { releases }
}

private struct HostTestEmbeddingProvider: KnowledgeEmbeddingProvider {
    let modelIdentity = KnowledgeEmbeddingModelIdentity(
        identity: "org.vita.intatis.tests.remote-embedding",
        revision: KnowledgeDigest.sha256("embedding-revision"),
        tokenizerRevision: "test-tokenizer/1",
        runtimeBindingKind: .remote,
        runtimeBindingDigest: KnowledgeDigest.sha256("embedding-route"),
        dimensions: 2,
        pooling: "provider-defined",
        maxInputTokens: 2_048)

    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [1, 0] }
    }

    func embedQuery(_ text: String) async throws -> [Float] { [1, 0] }
}

private struct HostTestRerankerProvider: KnowledgeRerankerProvider {
    let modelIdentity = KnowledgeRerankerModelIdentity(
        identity: "org.vita.intatis.tests.remote-reranker",
        revision: KnowledgeDigest.sha256("reranker-revision"),
        tokenizerRevision: "provider-defined",
        runtimeBindingKind: .remote,
        runtimeBindingDigest: KnowledgeDigest.sha256("reranker-route"),
        templateDigest: KnowledgeDigest.sha256("reranker-template"),
        maxInputTokens: 2_048,
        truncation: "end",
        scoreSemantics: "relevance_score_descending")

    func rerank(
        query: String,
        candidates: [KnowledgeRerankCandidate]
    ) async throws -> [KnowledgeRerankedCandidate] {
        candidates.enumerated().map {
            KnowledgeRerankedCandidate(
                chunkID: $0.element.chunkID,
                score: Double(candidates.count - $0.offset))
        }
    }
}
