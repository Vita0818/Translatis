import Foundation
import XCTest
import IntatisConversation
import IntatisCore
import IntatisKnowledge
import IntatisPermission
import IntatisProtocol
import IntatisProviders
import IntatisTools
@testable import IntatisAgentKernel

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class ModelDrivenKnowledgeAgentLoopTests: XCTestCase {
    func testAgentLoopKeepsTwoExternalKnowledgeStoresSnapshotIsolated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "intatis-agentloop-knowledge-\(UUID().uuidString)",
            isDirectory: true)
        let externalStores = ["a", "b"].map { label in
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "intatis-agentloop-external-knowledge-\(label)-\(UUID().uuidString)",
                isDirectory: true)
        }
        defer {
            makeWritable(root)
            try? FileManager.default.removeItem(at: root)
            for store in externalStores {
                makeWritable(store)
                try? FileManager.default.removeItem(at: store)
            }
        }
        try createDirectory(root)
        for store in externalStores { try createDirectory(store) }
        let draft = root.appendingPathComponent("draft", isDirectory: true)
        try createDirectory(draft)
        try createDirectory(draft.appendingPathComponent("concepts", isDirectory: true))
        try createDirectory(draft.appendingPathComponent("references", isDirectory: true))
        try write(
            """
            ---
            type: Index
            okf_version: "0.2"
            ---

            # Product knowledge
            """,
            to: draft.appendingPathComponent("index.md"))
        try write(
            """
            ---
            type: Policy
            title: Exact knowledge retrieval
            sources:
              - id: source-product
                resource: ../references/product.txt
            status: stable
            ---

            # Retrieval rule

            Intatis answers from an immutable snapshot and revalidates cited evidence before publishing the final response.
            """,
            to: draft.appendingPathComponent("concepts/retrieval.md"))
        try write(
            "Immutable retrieval source.\n",
            to: draft.appendingPathComponent("references/product.txt"))

        let sessionID = SessionID(rawValue: "knowledge-loop-\(UUID().uuidString)")
        let agentID = AgentID(rawValue: "KnowledgeAgent")
        let log = try EventLog(
            session: sessionID,
            fileURL: root.appendingPathComponent("events.jsonl"))
        let capabilityLease = CapabilityLease(
            tools: [.buildKnowledge, .searchKnowledge],
            expiresAtTaskCompletion: false)
        let workspaceLease = WorkspaceLease(
            rootPath: root.path,
            access: .readWrite,
            allowedPathRules: [PathRule(pattern: ".")],
            deniedPatterns: [])
        let embedding = AgentLoopKnowledgeEmbeddingProvider()
        let reranker = AgentLoopKnowledgeRerankerProvider()
        let authorityProbe = AgentLoopExternalKnowledgeAuthorityProbe()
        let externalAuthority = KnowledgeExternalAuthorityProvider { request in
            guard externalStores.contains(where: {
                $0.path == request.requestedRoot.path
            }) else {
                throw KnowledgeDomainError(
                    .accessDenied,
                    "The test host rejected a substituted external directory.")
            }
            await authorityProbe.acquired(
                operation: request.operation,
                path: request.requestedRoot.path)
            let access: KnowledgeLeaseAccess = request.operation == .search
                ? .readOnly
                : .readWrite
            let lease = try KnowledgeLease(
                root: request.requestedRoot,
                sessionID: request.sessionID,
                agentID: request.agentID,
                taskID: request.taskID,
                reuseScope: .session,
                access: access,
                operations: [request.operation],
                authorizationReferenceKind: .cliPermission,
                authorizationReferenceDigest: KnowledgeDigest.sha256(
                    "agentloop-external-authority/1\n"
                        + request.authorizationID + "\n"
                        + request.requestedRoot.path))
            return KnowledgeExternalAuthorityGrant(
                lease: lease,
                release: { await authorityProbe.released() })
        }
        let host = try ModelDrivenKnowledgeToolHost(
            embeddingProvider: embedding,
            rerankerProvider: reranker,
            authorityResolver: KnowledgeStoreAuthorityResolver(
                externalProvider: externalAuthority),
            policy: KnowledgeSearchPolicy(
                evaluationDate: "2026-08-10T12:00:00Z"))
        let augmentation = try await host.augment(
            HostToolRegistryAugmentationInput(
                sessionID: sessionID,
                agentID: agentID,
                taskID: nil,
                capabilityLease: capabilityLease,
                workspaceLease: workspaceLease,
                baseRegistry: .standard()))

        let provider = AgentLoopKnowledgeCallingProvider(
            storePaths: externalStores.map(\.path))
        let runtime = AgentRuntime.code(
            registry: augmentation.registry,
            allowsShell: false,
            maxIterations: 6)
        let loop = runtime.makeLoop(
            log: log,
            provider: provider,
            responder: FixedResponder(.allow),
            agent: Agent(
                name: agentID,
                workspaceRoot: root,
                model: ModelID(rawValue: "scripted-knowledge-model"),
                profile: .reviewed),
            capabilityLease: capabilityLease,
            workspaceLease: workspaceLease)

        let answer = try await loop.send(
            "Build the prepared material into both authorized external stores, search both, and answer with evidence from each exact snapshot.")
        XCTAssertEqual(
            answer.components(separatedBy: "[[evidence:ev_").count - 1,
            2,
            answer)
        let releasesBeforeDrain = await authorityProbe.releaseCount()
        XCTAssertEqual(releasesBeforeDrain, 2)
        let augmentationDrained = await augmentation.close()
        XCTAssertTrue(augmentationDrained)
        let releasesAfterDrain = await authorityProbe.releaseCount()
        let authorityOperations = await authorityProbe.operations()
        let authorityPaths = await authorityProbe.paths()
        XCTAssertEqual(releasesAfterDrain, 4)
        XCTAssertEqual(
            authorityOperations,
            [.build, .build, .search, .search])
        XCTAssertEqual(Set(authorityPaths), Set(externalStores.map(\.path)))
        for store in externalStores {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: store.appendingPathComponent(
                    ".intatis-rag-store.json").path))
        }

        let requests = provider.recordedRequests()
        XCTAssertEqual(requests.count, 5)
        XCTAssertTrue(requests[0].tools.contains { $0.name == "build_knowledge" })
        XCTAssertTrue(requests[0].tools.contains { $0.name == "search_knowledge" })
        let modelFacingBuild = try XCTUnwrap(
            requests[0].tools.first { $0.name == "build_knowledge" })
        XCTAssertTrue(modelFacingBuild.description.contains("index.md"))
        XCTAssertTrue(modelFacingBuild.description.contains(
            "sources: [{id: source-1"))
        XCTAssertTrue(modelFacingBuild.description.contains(
            "Do not invent provenance"))
        let modelFacingSystem = try XCTUnwrap(
            requests[0].messages.first?.content)
        XCTAssertTrue(modelFacingSystem.contains("dedicated advertised tool"))
        XCTAssertTrue(modelFacingSystem.contains(
            "host obtains exact authorization"))
        XCTAssertFalse(modelFacingSystem.contains(
            "Never attempt to access files outside the workspace"))
        let documentTextCount = await embedding.documentTextCount()
        let queryCount = await embedding.queryCount()
        let rerankerInvocationCount = await reranker.invocationCount()
        XCTAssertGreaterThan(documentTextCount, 0)
        XCTAssertEqual(queryCount, 2)
        XCTAssertEqual(rerankerInvocationCount, 2)

        let events = await log.replay()
        let calls = events.compactMap { envelope -> ToolCallPayload? in
            guard case .toolCall(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(
            calls.map { $0.name },
            [
                "build_knowledge", "build_knowledge",
                "search_knowledge", "search_knowledge",
            ])
        XCTAssertTrue(calls.allSatisfy {
            $0.args == #"{"_intatis":"arguments_redacted"}"#
                && $0.argsRedacted == true
        })
        let results = events.compactMap { envelope -> ToolResultPayload? in
            guard case .toolResult(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(results.count, 4)
        if let first = results.first {
            XCTAssertEqual(
                first.outcome,
                ToolCallOutcome.succeeded,
                first.observation)
        }
        XCTAssertTrue(results.allSatisfy {
            $0.outcome == ToolCallOutcome.succeeded
        })
        let searches = results.suffix(2).compactMap {
            $0.structuredResult?.structuredContent
        }
        XCTAssertEqual(searches.count, 2)
        for value in searches {
            guard case .object(let search) = value else {
                return XCTFail("search_knowledge did not persist a structured result")
            }
            XCTAssertEqual(search["status"], JSONValue.string("ok"))
            XCTAssertEqual(search["rerank_applied"], JSONValue.bool(true))
            XCTAssertFalse((search["evidence"]?.arrayValue ?? []).isEmpty)
        }

        let prepared = events.compactMap { envelope
            -> ToolExecutionPreparedPayload? in
            guard case .toolExecutionPrepared(let payload) = envelope.event else {
                return nil
            }
            return payload
        }
        let settled = events.compactMap { envelope
            -> ToolExecutionSettledPayload? in
            guard case .toolExecutionSettled(let payload) = envelope.event else {
                return nil
            }
            return payload
        }
        XCTAssertEqual(prepared.count, 4)
        XCTAssertEqual(settled.count, 4)
        XCTAssertEqual(
            Set(prepared.map { $0.executionID }),
            Set(settled.map { $0.executionID }))

        // A fresh host generation has no process-local mount handle. It must
        // reacquire exact external authority, reopen the durable current
        // pointer, mount that snapshot, and produce current-turn evidence.
        let restoredHost = try ModelDrivenKnowledgeToolHost(
            embeddingProvider: embedding,
            rerankerProvider: reranker,
            authorityResolver: KnowledgeStoreAuthorityResolver(
                externalProvider: externalAuthority),
            policy: KnowledgeSearchPolicy(
                evaluationDate: "2026-08-10T12:00:00Z"))
        let restoredAugmentation = try await restoredHost.augment(
            HostToolRegistryAugmentationInput(
                sessionID: sessionID,
                agentID: agentID,
                taskID: nil,
                capabilityLease: capabilityLease,
                workspaceLease: workspaceLease,
                baseRegistry: .standard()))
        let restoredProvider = AgentLoopKnowledgeSearchCallingProvider(
            storePath: externalStores[0].path)
        let restoredLoop = AgentRuntime.code(
            registry: restoredAugmentation.registry,
            allowsShell: false,
            maxIterations: 3).makeLoop(
                log: log,
                provider: restoredProvider,
                responder: FixedResponder(.allow),
                agent: Agent(
                    name: agentID,
                    workspaceRoot: root,
                    model: ModelID(rawValue: "scripted-knowledge-model"),
                    profile: .reviewed),
                capabilityLease: capabilityLease,
                workspaceLease: workspaceLease)
        let restoredAnswer = try await restoredLoop.send(
            "Restore the previously published external knowledge store and answer from its exact current snapshot.")
        XCTAssertEqual(
            restoredAnswer.components(separatedBy: "[[evidence:ev_").count - 1,
            1,
            restoredAnswer)
        let restoredReleasesBeforeDrain = await authorityProbe.releaseCount()
        XCTAssertEqual(restoredReleasesBeforeDrain, 4)
        let restoredDrained = await restoredAugmentation.close()
        XCTAssertTrue(restoredDrained)
        let restoredReleasesAfterDrain = await authorityProbe.releaseCount()
        let restoredOperations = await authorityProbe.operations()
        let restoredQueryCount = await embedding.queryCount()
        let restoredRerankerCount = await reranker.invocationCount()
        XCTAssertEqual(restoredReleasesAfterDrain, 5)
        XCTAssertEqual(restoredOperations.last, .search)
        XCTAssertEqual(restoredQueryCount, 3)
        XCTAssertEqual(restoredRerankerCount, 3)
    }

    func testDeniedExternalBuildStopsBeforeAuthorityFilesystemAndModels()
        async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "intatis-agentloop-knowledge-deny-\(UUID().uuidString)",
            isDirectory: true)
        let externalStore = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-agentloop-external-denied-\(UUID().uuidString)",
                isDirectory: true)
        defer {
            makeWritable(root)
            try? FileManager.default.removeItem(at: root)
            makeWritable(externalStore)
            try? FileManager.default.removeItem(at: externalStore)
        }
        try createDirectory(root)

        let sessionID = SessionID(
            rawValue: "knowledge-loop-deny-\(UUID().uuidString)")
        let agentID = AgentID(rawValue: "KnowledgeAgent")
        let log = try EventLog(
            session: sessionID,
            fileURL: root.appendingPathComponent("events.jsonl"))
        let capabilityLease = CapabilityLease(
            tools: [.buildKnowledge, .searchKnowledge],
            expiresAtTaskCompletion: false)
        let workspaceLease = WorkspaceLease(
            rootPath: root.path,
            access: .readWrite,
            allowedPathRules: [PathRule(pattern: ".")],
            deniedPatterns: [])
        let embedding = AgentLoopKnowledgeEmbeddingProvider()
        let reranker = AgentLoopKnowledgeRerankerProvider()
        let authorityProbe = AgentLoopExternalKnowledgeAuthorityProbe()
        let externalAuthority = KnowledgeExternalAuthorityProvider { request in
            await authorityProbe.acquired(
                operation: request.operation,
                path: request.requestedRoot.path)
            throw KnowledgeDomainError(
                .accessDenied,
                "The denied tool call unexpectedly reached external authority.")
        }
        let host = try ModelDrivenKnowledgeToolHost(
            embeddingProvider: embedding,
            rerankerProvider: reranker,
            authorityResolver: KnowledgeStoreAuthorityResolver(
                externalProvider: externalAuthority),
            policy: KnowledgeSearchPolicy(
                evaluationDate: "2026-08-10T12:00:00Z"))
        let augmentation = try await host.augment(
            HostToolRegistryAugmentationInput(
                sessionID: sessionID,
                agentID: agentID,
                taskID: nil,
                capabilityLease: capabilityLease,
                workspaceLease: workspaceLease,
                baseRegistry: .standard()))
        let provider = AgentLoopDeniedKnowledgeBuildProvider(
            storePath: externalStore.path)
        let loop = AgentRuntime.code(
            registry: augmentation.registry,
            allowsShell: false,
            maxIterations: 3).makeLoop(
                log: log,
                provider: provider,
                responder: FixedResponder(.deny),
                agent: Agent(
                    name: agentID,
                    workspaceRoot: root,
                    model: ModelID(rawValue: "scripted-knowledge-model"),
                    profile: .reviewed),
                capabilityLease: capabilityLease,
                workspaceLease: workspaceLease)

        let answer = try await loop.send(
            "Do not authorize this proposed external knowledge build.")
        XCTAssertTrue(answer.contains("denied"), answer)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: externalStore.path))
        let authorityOperations = await authorityProbe.operations()
        let documentTextCount = await embedding.documentTextCount()
        let queryCount = await embedding.queryCount()
        let rerankerInvocationCount = await reranker.invocationCount()
        XCTAssertTrue(authorityOperations.isEmpty)
        XCTAssertEqual(documentTextCount, 0)
        XCTAssertEqual(queryCount, 0)
        XCTAssertEqual(rerankerInvocationCount, 0)

        let events = await log.replay()
        let requests = events.compactMap { envelope
            -> PermissionRequestPayload? in
            guard case .permissionRequest(let payload) = envelope.event else {
                return nil
            }
            return payload
        }
        let resolutions = events.compactMap { envelope
            -> PermissionResolvedPayload? in
            guard case .permissionResolved(let payload) = envelope.event else {
                return nil
            }
            return payload
        }
        let toolResults = events.compactMap { envelope -> ToolResultPayload? in
            guard case .toolResult(let payload) = envelope.event else {
                return nil
            }
            return payload
        }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.tool, "build_knowledge")
        XCTAssertEqual(
            requests.first?.args,
            "digest="
                + (requests.first?.context?.authorization?
                    .normalizedArgumentsDigest ?? "")
                + "; characters="
                + String(requests.first?.context?.authorization?
                    .normalizedArgumentsCharacterCount ?? -1))
        XCTAssertEqual(resolutions.count, 1)
        XCTAssertEqual(resolutions.first?.decision, .deny)
        XCTAssertEqual(resolutions.first?.failureSource, .userDenied)
        XCTAssertEqual(toolResults.count, 1)
        XCTAssertEqual(toolResults.first?.outcome, .denied)
        XCTAssertTrue(events.allSatisfy { envelope in
            if case .toolExecutionPrepared = envelope.event { return false }
            if case .toolExecutionSettled = envelope.event { return false }
            return true
        })
        let drained = await augmentation.close()
        XCTAssertTrue(drained)
    }

    private func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        _ = chmod(url.path, 0o700)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        _ = chmod(url.path, 0o600)
    }

    private func makeWritable(_ root: URL) {
        _ = chmod(root.path, 0o700)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory) {
                _ = chmod(url.path, isDirectory.boolValue ? 0o700 : 0o600)
            }
        }
    }
}

private final class AgentLoopKnowledgeCallingProvider:
    ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let storePaths: [String]
    private var step = 0
    private var requests: [AgentRequest] = []

    init(storePaths: [String]) {
        precondition(storePaths.count == 2)
        self.storePaths = storePaths
    }

    func stream(_ request: AgentRequest)
        -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        let current = step
        step += 1
        requests.append(request)
        lock.unlock()

        let chunks: [AgentChunk]
        switch current {
        case 0:
            chunks = [
                .toolCalls([ToolCall(
                    id: "build-knowledge",
                    name: "build_knowledge",
                    arguments: Self.arguments([
                        "draft_path": "draft",
                        "store_path": storePaths[0],
                    ]))]),
                .done(finishReason: "tool_calls"),
            ]
        case 1:
            chunks = [
                .toolCalls([ToolCall(
                    id: "build-knowledge-b",
                    name: "build_knowledge",
                    arguments: Self.arguments([
                        "draft_path": "draft",
                        "store_path": storePaths[1],
                    ]))]),
                .done(finishReason: "tool_calls"),
            ]
        case 2:
            chunks = [
                .toolCalls([ToolCall(
                    id: "search-knowledge-a",
                    name: "search_knowledge",
                    arguments: Self.arguments([
                        "store_path": storePaths[0],
                        "query": "How does Intatis validate evidence?",
                        "limit": 4,
                    ]))]),
                .done(finishReason: "tool_calls"),
            ]
        case 3:
            chunks = [
                .toolCalls([ToolCall(
                    id: "search-knowledge-b",
                    name: "search_knowledge",
                    arguments: Self.arguments([
                        "store_path": storePaths[1],
                        "query": "How does Intatis validate evidence?",
                        "limit": 4,
                    ]))]),
                .done(finishReason: "tool_calls"),
            ]
        default:
            let evidenceIDs = Self.evidenceIDs(in: request)
            if evidenceIDs.count == 2 {
                chunks = [
                    .textDelta(
                        "Both exact stores say Intatis revalidates evidence before the final response [[evidence:\(evidenceIDs[0])]] [[evidence:\(evidenceIDs[1])]]."),
                    .done(finishReason: "stop"),
                ]
            } else {
                let lastToolOutput = request.messages.reversed().first {
                    $0.role == .tool
                }?.content ?? "missing tool output"
                chunks = [
                    .textDelta("No evidence was returned. \(lastToolOutput)"),
                    .done(finishReason: "stop"),
                ]
            }
        }
        return AsyncThrowingStream<AgentChunk, Error> { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    func recordedRequests() -> [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private static func evidenceIDs(in request: AgentRequest) -> [String] {
        var result: [String] = []
        for message in request.messages.reversed()
            where message.role == .tool {
            guard let text = message.content else { continue }
            for line in text.split(separator: "\n").reversed() {
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                      object["status"] as? String == "ok",
                      let evidence = object["evidence"] as? [[String: Any]],
                      let id = evidence.first?["evidence_id"] as? String else {
                    continue
                }
                if !result.contains(id) { result.append(id) }
            }
        }
        return Array(result.reversed())
    }

    private static func arguments(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

private final class AgentLoopKnowledgeSearchCallingProvider:
    ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let storePath: String
    private var step = 0

    init(storePath: String) {
        self.storePath = storePath
    }

    func stream(_ request: AgentRequest)
        -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        let current = step
        step += 1
        lock.unlock()
        let chunks: [AgentChunk]
        if current == 0 {
            chunks = [
                .toolCalls([ToolCall(
                    id: "search-restored-knowledge",
                    name: "search_knowledge",
                    arguments: Self.arguments([
                        "store_path": storePath,
                        "query": "How does Intatis validate evidence?",
                        "limit": 4,
                    ]))]),
                .done(finishReason: "tool_calls"),
            ]
        } else if let evidenceID = Self.latestEvidenceID(in: request) {
            chunks = [
                .textDelta(
                    "The restored snapshot requires final evidence revalidation [[evidence:\(evidenceID)]]."),
                .done(finishReason: "stop"),
            ]
        } else {
            chunks = [
                .textDelta("The restored knowledge search returned no evidence."),
                .done(finishReason: "stop"),
            ]
        }
        return AsyncThrowingStream<AgentChunk, Error> { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    private static func latestEvidenceID(in request: AgentRequest) -> String? {
        for message in request.messages.reversed() where message.role == .tool {
            guard let text = message.content else { continue }
            for line in text.split(separator: "\n").reversed() {
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                      object["status"] as? String == "ok",
                      let evidence = object["evidence"] as? [[String: Any]],
                      let id = evidence.first?["evidence_id"] as? String else {
                    continue
                }
                return id
            }
        }
        return nil
    }

    private static func arguments(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

private final class AgentLoopDeniedKnowledgeBuildProvider:
    ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let storePath: String
    private var step = 0

    init(storePath: String) {
        self.storePath = storePath
    }

    func stream(_ request: AgentRequest)
        -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        let current = step
        step += 1
        lock.unlock()
        let chunks: [AgentChunk]
        if current == 0 {
            let arguments = try! JSONSerialization.data(
                withJSONObject: [
                    "draft_path": "draft",
                    "store_path": storePath,
                ],
                options: [.sortedKeys])
            chunks = [
                .toolCalls([ToolCall(
                    id: "build-denied-external-knowledge",
                    name: "build_knowledge",
                    arguments: String(decoding: arguments, as: UTF8.self))]),
                .done(finishReason: "tool_calls"),
            ]
        } else {
            let denied = request.messages.contains {
                $0.role == .tool && ($0.content?.contains("denied") == true)
            }
            chunks = [
                .textDelta(denied
                    ? "The external knowledge build was denied before execution."
                    : "The external knowledge build did not return a denial."),
                .done(finishReason: "stop"),
            ]
        }
        return AsyncThrowingStream<AgentChunk, Error> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private actor AgentLoopExternalKnowledgeAuthorityProbe {
    private var acquiredOperations: [KnowledgeLeaseOperation] = []
    private var acquiredPaths: [String] = []
    private var releases = 0

    func acquired(operation: KnowledgeLeaseOperation, path: String) {
        acquiredOperations.append(operation)
        acquiredPaths.append(path)
    }

    func released() { releases += 1 }
    func releaseCount() -> Int { releases }
    func operations() -> [KnowledgeLeaseOperation] { acquiredOperations }
    func paths() -> [String] { acquiredPaths }
}

private actor AgentLoopKnowledgeEmbeddingProvider: KnowledgeEmbeddingProvider {
    nonisolated let modelIdentity = KnowledgeEmbeddingModelIdentity(
        identity: "org.vita.intatis.tests.agentloop-embedding",
        revision: KnowledgeDigest.sha256("agentloop-embedding-revision"),
        tokenizerRevision: "agentloop-tokenizer/1",
        runtimeBindingKind: .remote,
        runtimeBindingDigest: KnowledgeDigest.sha256("agentloop-embedding-route"),
        dimensions: 2,
        pooling: "provider-defined",
        maxInputTokens: 2_048)

    private var documentTexts = 0
    private var queries = 0

    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        documentTexts += texts.count
        return texts.map { _ in [1, 0] }
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        queries += 1
        return [1, 0]
    }

    func documentTextCount() -> Int { documentTexts }
    func queryCount() -> Int { queries }
}

private actor AgentLoopKnowledgeRerankerProvider: KnowledgeRerankerProvider {
    nonisolated let modelIdentity = KnowledgeRerankerModelIdentity(
        identity: "org.vita.intatis.tests.agentloop-reranker",
        revision: KnowledgeDigest.sha256("agentloop-reranker-revision"),
        tokenizerRevision: "provider-defined",
        runtimeBindingKind: .remote,
        runtimeBindingDigest: KnowledgeDigest.sha256("agentloop-reranker-route"),
        templateDigest: KnowledgeDigest.sha256("agentloop-reranker-template"),
        maxInputTokens: 2_048,
        truncation: "end",
        scoreSemantics: "relevance_score_descending")

    private var invocations = 0

    func rerank(
        query: String,
        candidates: [KnowledgeRerankCandidate]
    ) async throws -> [KnowledgeRerankedCandidate] {
        invocations += 1
        return candidates.enumerated().map {
            KnowledgeRerankedCandidate(
                chunkID: $0.element.chunkID,
                score: Double(candidates.count - $0.offset))
        }
    }

    func invocationCount() -> Int { invocations }
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}
