import Foundation
import XCTest
import IntatisAgentKernel
import IntatisConversation
import IntatisCore
import IntatisCowork
import IntatisKnowledge
import IntatisPermission
import IntatisProtocol
import IntatisProviders
import IntatisTools
@testable import TranslatisCLI

final class RealProviderSmokeTests: XCTestCase {
    func testRealKnowledgeRerankQualityWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment[
            "TRANSLATIS_REAL_KNOWLEDGE_QUALITY"
        ] == "1" else {
            throw XCTSkip(
                "Set TRANSLATIS_REAL_KNOWLEDGE_QUALITY=1 to run the configured embedding and semantic reranker over the frozen mixed-language quality set.")
        }

        let config = try CLIConfig.load()
        let registry = ProviderRegistry(
            config: config.providerConfig(),
            resolver: CLIExactSecretResolver(config: config))
        let models = try await registry.configuredKnowledgeModels()
        let corpus = Self.knowledgeQualityCorpus
        let documentResponse = try await models.embedding.embedWithUsage(
            corpus.documents.map(\.text),
            instruction: models.embedding.configuration.documentInstruction)
        let queryResponse = try await models.embedding.embedWithUsage(
            corpus.queries.map(\.text),
            instruction: models.embedding.configuration.queryInstruction)
        let documentVectors = documentResponse.vectors
        let queryVectors = queryResponse.vectors
        let embeddingUsage = Self.addingUsage(
            documentResponse.usage,
            queryResponse.usage)
        XCTAssertEqual(documentVectors.count, corpus.documents.count)
        XCTAssertEqual(queryVectors.count, corpus.queries.count)

        var baselineRankings: [[String]] = []
        var rerankedRankings: [[String]] = []
        var rerankerUsage: ProviderKnowledgeUsage?
        for (queryOffset, query) in corpus.queries.enumerated() {
            let baseline = zip(corpus.documents, documentVectors).map {
                (id: $0.0.id,
                 score: Self.cosine(queryVectors[queryOffset], $0.1))
            }.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.id < $1.id
            }.map(\.id)
            baselineRankings.append(baseline)

            let documentsByID = Dictionary(
                uniqueKeysWithValues: corpus.documents.map { ($0.id, $0.text) })
            let candidateTexts = try baseline.map {
                try XCTUnwrap(documentsByID[$0])
            }
            let rerankResponse = try await models.reranker.rerankWithUsage(
                query: query.text,
                documents: candidateTexts)
            let reranked = rerankResponse.results
            rerankerUsage = Self.addingUsage(
                rerankerUsage,
                rerankResponse.usage)
            XCTAssertEqual(reranked.count, baseline.count)
            rerankedRankings.append(reranked.map { baseline[$0.index] })
        }

        let baseline = Self.qualityMetrics(
            rankings: baselineRankings,
            queries: corpus.queries)
        let reranked = Self.qualityMetrics(
            rankings: rerankedRankings,
            queries: corpus.queries)
        let metricLine = String(
            format: "[RealKnowledgeQuality] queries=%d baseline(MRR=%.3f,nDCG@5=%.3f,Recall@5=%.3f) configured-reranker(MRR=%.3f,nDCG@5=%.3f,Recall@5=%.3f)",
            corpus.queries.count,
            baseline.mrr,
            baseline.nDCGAtFive,
            baseline.recallAtFive,
            reranked.mrr,
            reranked.nDCGAtFive,
            reranked.recallAtFive)
        print(metricLine
            + " embedding_usage=" + Self.usageSummary(embeddingUsage)
            + " reranker_usage=" + Self.usageSummary(rerankerUsage))
        XCTAssertTrue([
            baseline.mrr, baseline.nDCGAtFive, baseline.recallAtFive,
            reranked.mrr, reranked.nDCGAtFive, reranked.recallAtFive,
        ].allSatisfy(\.isFinite))
    }

    func testRealKnowledgeEmbeddingAndRerankerWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment[
            "TRANSLATIS_REAL_KNOWLEDGE_SMOKE"
        ] == "1" else {
            throw XCTSkip(
                "Set TRANSLATIS_REAL_KNOWLEDGE_SMOKE=1 to spend one embedding request and one reranker request using the exact configured Knowledge routes.")
        }

        let config = try CLIConfig.load()
        let registry = ProviderRegistry(
            config: config.providerConfig(),
            resolver: CLIExactSecretResolver(config: config))
        let models = try await registry.configuredKnowledgeModels()

        let embeddingResponse = try await models.embedding.embedWithUsage(
            ["Translatis knowledge route smoke test."],
            instruction: models.embedding.configuration.documentInstruction)
        let vectors = embeddingResponse.vectors
        XCTAssertEqual(vectors.count, 1)
        XCTAssertEqual(
            vectors.first?.count,
            models.embedding.configuration.dimensions)
        XCTAssertTrue(vectors.first?.allSatisfy(\.isFinite) == true)

        let rerankResponse = try await models.reranker.rerankWithUsage(
            query: "Which candidate is about knowledge retrieval?",
            documents: [
                "This candidate describes knowledge retrieval.",
                "This candidate describes a weather forecast.",
            ])
        let reranked = rerankResponse.results
        XCTAssertEqual(reranked.count, 2)
        XCTAssertEqual(Set(reranked.map(\.index)), Set([0, 1]))
        XCTAssertTrue(reranked.allSatisfy { $0.score.isFinite })
        print("[RealKnowledgeSmoke] embedding_route="
            + String(models.embedding.configuration.route.definitionDigest.prefix(20))
            + " embedding_usage=" + Self.usageSummary(embeddingResponse.usage)
            + " reranker_route="
            + String(models.reranker.configuration.route.definitionDigest.prefix(20))
            + " reranker_usage=" + Self.usageSummary(rerankResponse.usage))
    }

    func testRealModelBuildsSearchesAndCitesExternalKnowledgeWhenEnabled()
        async throws {
        guard ProcessInfo.processInfo.environment[
            "TRANSLATIS_REAL_KNOWLEDGE_AGENT_E2E"
        ] == "1" else {
            throw XCTSkip(
                "Set TRANSLATIS_REAL_KNOWLEDGE_AGENT_E2E=1 to let the configured Agent, embedding, and reranker routes perform the full read-organize-build-search-cite flow. This can make multiple billable requests.")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "translatis-real-knowledge-agent-\(UUID().uuidString)",
            isDirectory: true)
        let workspace = root.appendingPathComponent(
            "workspace",
            isDirectory: true)
        let externalStore = root.appendingPathComponent(
            "external-store",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try FileManager.default.createDirectory(
            at: externalStore,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        defer { try? FileManager.default.removeItem(at: root) }
        let source = """
        Intatis has three permission layers. DeterministicPolicyGate applies
        model-independent hard denials and decides whether an operation must be
        reviewed. ModelPermissionReviewer may only narrow a gate pass; it can
        never override a hard denial. PermissionEngine owns the final ask-user
        or automatic-review settlement before a tool may execute.
        """
        try Data(source.utf8).write(
            to: workspace.appendingPathComponent("permission-layers.txt"),
            options: .atomic)

        let config = try CLIConfig.load()
        let registry = ProviderRegistry(
            config: config.providerConfig(),
            resolver: CLIExactSecretResolver(config: config))
        let augmenter = try XCTUnwrap(makeCLIKnowledgeToolAugmenter(
            config: config,
            registry: registry))
        let route = try await registry.agentRuntimeRoute(
            model: ModelID(rawValue: config.model))
        let sessionID = SessionID(
            rawValue: "real_knowledge_agent_\(UUID().uuidString)")
        let agentID = AgentID(rawValue: "cli")
        let log = try EventLog(
            session: sessionID,
            fileURL: root.appendingPathComponent("events.jsonl"))
        var capabilityLease = CapabilityLease.worker(
            workspaceAccess: .readWrite)
        capabilityLease.tools.formUnion(augmenter.additionalCapabilities)
        capabilityLease.expiresAtTaskCompletion = false
        let workspaceLease = WorkspaceLease(
            rootPath: workspace.path,
            access: .readWrite,
            expiresAtTaskCompletion: false)
        let baseRegistry = ToolRegistry(
            [ReadFileTool(), ListFilesTool(), WriteFileTool()],
            registryVersion: "translatis.real-knowledge-agent-e2e/1")
        let augmentation = try await augmenter.augment(
            HostToolRegistryAugmentationInput(
                sessionID: sessionID,
                agentID: agentID,
                taskID: nil,
                capabilityLease: capabilityLease,
                workspaceLease: workspaceLease,
                baseRegistry: baseRegistry))
        let loop = AgentRuntime.code(
            registry: augmentation.registry,
            allowsShell: false,
            reasoningEffort: config.reasoningEffort,
            includeUsage: true,
            maxIterations: max(config.maxSteps, 16),
            modelContextPolicy: route.modelContextPolicy).makeLoop(
                log: log,
                provider: route.provider,
                responder: FixedResponder(.allow),
                agent: Agent(
                    name: agentID,
                    workspaceRoot: workspace,
                    model: route.model,
                    profile: .reviewed),
                context: ContextBuilder(runtimeEnvironment: .code),
                capabilityLease: capabilityLease,
                workspaceLease: workspaceLease)

        let prompt = """
        Read permission-layers.txt yourself. Organize it into a grounded OKF 0.2
        draft under knowledge-draft, including a source copy inside that draft.
        Build the knowledge store at this exact external path:
        \(externalStore.path)
        Then search that store to answer: What responsibility does each of the
        three Intatis permission layers have? Cite only evidence returned by the
        successful search. Do not merely describe what you would do.
        """
        let answer: String
        do {
            answer = try await loop.send(prompt)
            try await augmentation.closeRequiringDrain()
        } catch {
            try? await augmentation.closeRequiringDrain()
            throw error
        }

        let events = await log.replay()
        let calls = events.compactMap { envelope -> ToolCallPayload? in
            guard case .toolCall(let payload) = envelope.event else { return nil }
            return payload
        }
        let names = calls.map(\.name)
        XCTAssertTrue(names.contains("read_file"), names.joined(separator: ","))
        XCTAssertTrue(names.contains("write_file"), names.joined(separator: ","))
        XCTAssertTrue(names.contains("build_knowledge"), names.joined(separator: ","))
        XCTAssertTrue(names.contains("search_knowledge"), names.joined(separator: ","))
        XCTAssertTrue(answer.contains("[[evidence:ev_"), answer)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: externalStore.appendingPathComponent(
                ".translatis-rag-store.json").path))
        let results = events.compactMap { envelope -> ToolResultPayload? in
            guard case .toolResult(let payload) = envelope.event else { return nil }
            return payload
        }
        let successfulSearches = results.filter {
            guard $0.outcome == .succeeded,
                  let content = $0.structuredResult?.structuredContent,
                  case .object(let object) = content else {
                return false
            }
            return object["rerank_applied"] == .bool(true)
        }
        XCTAssertFalse(
            successfulSearches.isEmpty,
            "No successful required-rerank search was persisted.")
        print("[RealKnowledgeAgentE2E] model=" + route.model.rawValue
            + " tool_calls=" + names.joined(separator: ",")
            + " final_characters=\(answer.count)")
    }

    func testRealModelBuildsSearchesAndCitesPDFKnowledgeWhenEnabled()
        async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TRANSLATIS_REAL_KNOWLEDGE_PDF_E2E"] == "1" else {
            throw XCTSkip(
                "Set TRANSLATIS_REAL_KNOWLEDGE_PDF_E2E=1 and TRANSLATIS_REAL_KNOWLEDGE_PDF_SOURCE to let the configured Agent read selected real PDFs, build, rerank, and cite. This can make multiple billable requests.")
        }
        guard let sourcePath = environment[
            "TRANSLATIS_REAL_KNOWLEDGE_PDF_SOURCE"
        ], !sourcePath.isEmpty else {
            return XCTFail("TRANSLATIS_REAL_KNOWLEDGE_PDF_SOURCE is required")
        }

        let fileManager = FileManager.default
        let sourceRoot = URL(
            fileURLWithPath: sourcePath,
            isDirectory: true).standardizedFileURL
        var sourceIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: sourceRoot.path,
            isDirectory: &sourceIsDirectory),
            sourceIsDirectory.boolValue else {
            return XCTFail("the configured PDF source directory is unavailable")
        }

        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "translatis-real-knowledge-pdf-\(UUID().uuidString)",
            isDirectory: true)
        let workspace = root.appendingPathComponent(
            "workspace",
            isDirectory: true)
        let inputDirectory = workspace.appendingPathComponent(
            "source-pdfs",
            isDirectory: true)
        let externalStore = root.appendingPathComponent(
            "external-store",
            isDirectory: true)
        try fileManager.createDirectory(
            at: inputDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try fileManager.createDirectory(
            at: externalStore,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        defer { try? fileManager.removeItem(at: root) }

        let sourceFiles = [
            "DPV-chap2.pdf",
            "DPV-chap4.pdf",
            "DPV-chap6.pdf",
        ]
        for fileName in sourceFiles {
            let source = sourceRoot.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: source.path) else {
                return XCTFail("missing required PDF fixture: \(fileName)")
            }
            try fileManager.copyItem(
                at: source,
                to: inputDirectory.appendingPathComponent(fileName))
        }

        let config = try CLIConfig.load()
        let registry = ProviderRegistry(
            config: config.providerConfig(),
            resolver: CLIExactSecretResolver(config: config))
        let augmenter = try XCTUnwrap(makeCLIKnowledgeToolAugmenter(
            config: config,
            registry: registry))
        let route = try await registry.agentRuntimeRoute(
            model: ModelID(rawValue: config.model))
        let sessionID = SessionID(
            rawValue: "real_knowledge_pdf_\(UUID().uuidString)")
        let agentID = AgentID(rawValue: "cli")
        let log = try EventLog(
            session: sessionID,
            fileURL: root.appendingPathComponent("events.jsonl"))
        var capabilityLease = CapabilityLease.worker(
            workspaceAccess: .readWrite)
        capabilityLease.tools.formUnion(augmenter.additionalCapabilities)
        capabilityLease.expiresAtTaskCompletion = false
        let workspaceLease = WorkspaceLease(
            rootPath: workspace.path,
            access: .readWrite,
            expiresAtTaskCompletion: false)
        let baseRegistry = ToolRegistry(
            [
                ReadFileTool(), ListFilesTool(), WriteFileTool(),
                ReadPDFTool(),
            ],
            registryVersion: "translatis.real-knowledge-pdf-e2e/1")
        let augmentation = try await augmenter.augment(
            HostToolRegistryAugmentationInput(
                sessionID: sessionID,
                agentID: agentID,
                taskID: nil,
                capabilityLease: capabilityLease,
                workspaceLease: workspaceLease,
                baseRegistry: baseRegistry))
        let loop = AgentRuntime.code(
            registry: augmentation.registry,
            allowsShell: false,
            reasoningEffort: config.reasoningEffort,
            includeUsage: true,
            maxIterations: max(config.maxSteps, 16),
            modelContextPolicy: route.modelContextPolicy).makeLoop(
                log: log,
                provider: route.provider,
                responder: FixedResponder(.allow),
                agent: Agent(
                    name: agentID,
                    workspaceRoot: workspace,
                    model: route.model,
                    profile: .reviewed),
                context: ContextBuilder(runtimeEnvironment: .code),
                capabilityLease: capabilityLease,
                workspaceLease: workspaceLease)

        let prompt = """
        Use read_pdf yourself on exactly these representative native-text page
        ranges: source-pdfs/DPV-chap2.pdf pages 6-7,
        source-pdfs/DPV-chap4.pdf pages 5-7, and
        source-pdfs/DPV-chap6.pdf pages 1-5. Do not rely on prior knowledge.

        Create a grounded OKF 0.2 draft under knowledge-draft. Preserve the
        extracted text from each PDF as a separate UTF-8 source copy under the
        draft's references directory, and write separate grounded concepts for
        divide-and-conquer/mergesort, Dijkstra, and dynamic programming/LIS.
        Build the store once at this exact external path:
        \(externalStore.path)
        A successful status=ok publication is final; do not rebuild it.

        Search the built store to answer: How do mergesort, Dijkstra's shortest
        path algorithm, and longest increasing subsequence dynamic programming
        differ in how they choose or order work, and what condition or runtime
        claim does the selected text state for each? The final answer must cover
        all three topics and use exact [[evidence:<evidence_id>]] citations from
        the successful search result. Do not merely describe what you would do.
        """
        let answer: String
        do {
            answer = try await loop.send(prompt)
            try await augmentation.closeRequiringDrain()
        } catch {
            try? await augmentation.closeRequiringDrain()
            throw error
        }

        let events = await log.replay()
        let calls = events.compactMap { envelope -> ToolCallPayload? in
            guard case .toolCall(let payload) = envelope.event else {
                return nil
            }
            return payload
        }
        let names = calls.map(\.name)
        XCTAssertGreaterThanOrEqual(
            names.filter { $0 == "read_pdf" }.count,
            3,
            names.joined(separator: ","))
        XCTAssertTrue(names.contains("write_file"), names.joined(separator: ","))
        XCTAssertTrue(names.contains("build_knowledge"), names.joined(separator: ","))
        XCTAssertTrue(names.contains("search_knowledge"), names.joined(separator: ","))
        XCTAssertTrue(answer.contains("[[evidence:ev_"), answer)
        let normalizedAnswer = answer.lowercased()
        XCTAssertTrue(normalizedAnswer.contains("mergesort"), answer)
        XCTAssertTrue(normalizedAnswer.contains("dijkstra"), answer)
        XCTAssertTrue(
            normalizedAnswer.contains("increasing subsequence"),
            answer)
        XCTAssertTrue(fileManager.fileExists(
            atPath: externalStore.appendingPathComponent(
                ".translatis-rag-store.json").path))

        let results = events.compactMap { envelope -> ToolResultPayload? in
            guard case .toolResult(let payload) = envelope.event else {
                return nil
            }
            return payload
        }
        let successfulRerankedSearch = results.contains {
            guard $0.outcome == .succeeded,
                  let content = $0.structuredResult?.structuredContent,
                  case .object(let object) = content else {
                return false
            }
            return object["rerank_applied"] == .bool(true)
        }
        XCTAssertTrue(
            successfulRerankedSearch,
            "No successful required-rerank PDF search was persisted.")
        print("[RealKnowledgePDFE2E] model=" + route.model.rawValue
            + " pdfs=" + sourceFiles.joined(separator: ",")
            + " tool_calls=" + names.joined(separator: ",")
            + " final_characters=\(answer.count)")
    }

    func testRealOpenAIMultimodalUserAndFunctionOutputWhenEnabled()
        async throws
    {
        guard ProcessInfo.processInfo.environment[
            "TRANSLATIS_REAL_MULTIMODAL_SMOKE"
        ] == "1" else {
            throw XCTSkip(
                "Set TRANSLATIS_REAL_MULTIMODAL_SMOKE=1 to spend one real provider request containing both user and function-output images.")
        }

        let config = try CLIConfig.load()
        let registry = ProviderRegistry(
            config: config.providerConfig(),
            resolver: CLIExactSecretResolver(config: config))
        let models = await registry.models()
        let route = models.agent ?? models.chat
        let provider = try await registry.agentProvider(for: route)
        XCTAssertTrue(
            provider.toolCallingCapabilities.supportsUserImageInput,
            "The exact configured Agent route does not advertise user images.")
        XCTAssertTrue(
            provider.toolCallingCapabilities
                .supportsFunctionOutputImageInput,
            "The exact configured Agent route does not advertise function-output images.")

        let image = ImageAttachment(url:
            "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        let call = ToolCall(
            id: "call_real_multimodal_smoke",
            name: "inspect_image",
            arguments: "{}")
        let request = AgentRequest(
            model: route.model,
            messages: [
                .user(
                    "A one-pixel image is attached. A completed image tool call follows; acknowledge the available evidence briefly.",
                    images: [image]),
                .assistant(toolCalls: [call]),
                .tool(
                    id: call.id,
                    content: "The tool returned one image.",
                    images: [image]),
            ],
            tools: [
                ToolSpec(
                    name: call.name,
                    description: "Returns a previously inspected image.",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "additionalProperties": .bool(false),
                    ])),
            ],
            includeUsage: true,
            maxOutputTokens: 64)

        var sawTerminal = false
        for try await chunk in provider.stream(request) {
            if case .done = chunk {
                sawTerminal = true
            }
        }
        XCTAssertTrue(
            sawTerminal,
            "The real multimodal Responses stream ended without a completion marker.")
    }

    func testConfiguredAgentRouteWithRealProvider() async throws {
        guard ProcessInfo.processInfo.environment["TRANSLATIS_REAL_PROVIDER_SMOKE"] == "1" else {
            throw XCTSkip(
                "Set TRANSLATIS_REAL_PROVIDER_SMOKE=1 to spend one minimal real provider request.")
        }

        let config = try CLIConfig.load()
        let registry = ProviderRegistry(
            config: config.providerConfig(),
            resolver: CLIExactSecretResolver(config: config))

        let report = await registry.healthCheck(
            role: .agent,
            options: ProviderHealthCheckOptions(
                timeoutSeconds: 60,
                prompt: "Return exactly OK.",
                maxPreviewCharacters: 16))

        XCTAssertEqual(report.status, .ok, report.message)
        XCTAssertEqual(report.role, .agent)
        XCTAssertEqual(report.model.rawValue, config.model)
        XCTAssertFalse(report.responsePreview?.isEmpty ?? true)
    }

    func testRealAgentAuthorizationSidecarShapeWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment[
            "TRANSLATIS_REAL_TOOL_SHAPE_DIAGNOSTIC"
        ] == "1" else {
            throw XCTSkip(
                "Set TRANSLATIS_REAL_TOOL_SHAPE_DIAGNOSTIC=1 to verify that the configured Agent route emits a same-call authorization sidecar. This makes one billable request.")
        }

        let config = try CLIConfig.load()
        let registry = ProviderRegistry(
            config: config.providerConfig(),
            resolver: CLIExactSecretResolver(config: config))
        let route = try await registry.agentRuntimeRoute(
            model: ModelID(rawValue: config.model))
        let businessParameters: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "status": .object([
                    "type": .string("string"),
                ]),
            ]),
            "required": .array([.string("status")]),
            "additionalProperties": .bool(false),
        ])

        func toolRequest() throws -> AgentRequest {
            let decorated = try AuthorizationSidecarCodec.decorate(
                ToolSpec(
                    name: "diagnostic_noop",
                    description: "A no-op diagnostic function.",
                    parameters: businessParameters,
                    strict: true))
            guard case .object(let schema) = decorated.parameters,
                  case .object(let properties)? = schema["properties"],
                  case .array(let required)? = schema["required"] else {
                throw IntatisError.config(
                    "The authorization-sidecar diagnostic schema is malformed.")
            }
            XCTAssertEqual(decorated.strict, true)
            XCTAssertEqual(
                Set(properties.keys),
                Set(required.compactMap { value -> String? in
                    guard case .string(let name) = value else { return nil }
                    return name
                }))
            return AgentRequest(
                model: route.model,
                messages: [.user("""
                    Call diagnostic_noop exactly once with status OK. In the required
                    __intatis_authorization_context field, explain that this is a
                    user-requested provider-shape diagnostic and cite this user request.
                    """)],
                tools: [decorated],
                reasoningEffort: config.reasoningEffort,
                includeUsage: true)
        }

        var outputError: Error?
        var outputText = ""
        var outputCalls: [ToolCall] = []
        do {
            for try await chunk in route.provider.stream(
                try toolRequest()) {
                if case .textDelta(let delta) = chunk {
                    outputText += delta
                }
                if case .toolCalls(let calls) = chunk {
                    outputCalls.append(contentsOf: calls)
                }
            }
        } catch {
            outputError = error
        }

        print("[RealAgentToolShape] authorization_sidecar="
            + (outputError == nil ? "accepted" : "rejected"))
        XCTAssertNil(
            outputError,
            outputError?.localizedDescription
                ?? "authorization sidecar request failed")
        XCTAssertEqual(outputCalls.count, 1)
        XCTAssertEqual(outputCalls.first?.name, "diagnostic_noop")
        let call = try XCTUnwrap(outputCalls.first)
        let extraction = AuthorizationSidecarCodec.extract(
            from: call.arguments)
        XCTAssertEqual(extraction.sidecarStatus, .valid)
        XCTAssertNotNil(extraction.modelAuthorizationContext)
        let arguments = try XCTUnwrap(
            extraction.canonicalBusinessArguments?.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(
            with: arguments) as? [String: Any]
        XCTAssertEqual(object?["status"] as? String, "OK")
        _ = outputText
    }

    func testRealPermissionReviewControlPlaneWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment[
            "TRANSLATIS_REAL_PERMISSION_REVIEW_SMOKE"
        ] == "1" else {
            throw XCTSkip(
                "Set TRANSLATIS_REAL_PERMISSION_REVIEW_SMOKE=1 to spend one real permission-review request.")
        }

        let config = try CLIConfig.load()
        let registry = ProviderRegistry(
            config: config.providerConfig(),
            resolver: CLIExactSecretResolver(config: config))
        let models = await registry.models()
        let route = models.agent ?? models.chat
        let sessionID = SessionID(
            rawValue: "real_permission_review_\(UUID().uuidString)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            sessionID.rawValue,
            isDirectory: true)
        let workspace = root.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try EventLog(
            session: sessionID,
            fileURL: root.appendingPathComponent("events.jsonl"))
        let responder = AgentPermissionResponder(
            log: log,
            reviewerAgent: Agent(
                name: Orchestrator.automaticPermissionReviewerID,
                workspaceRoot: workspace,
                model: route.model,
                profile: .readOnly,
                coordinationDepth: 0),
            providerFactory: {
                try await registry.agentProvider(for: route)
            },
            fallback: FixedResponder(.deny),
            policy: PermissionReviewControlPlanePolicy(timeoutSeconds: 60))

        let request = makePermissionReviewRequest(sessionID: sessionID)
        let resolution = await responder.requestResolution(request)

        XCTAssertTrue(
            resolution.decision == .allow || resolution.decision == .deny)
        XCTAssertEqual(
            resolution.source,
            .automaticReviewer,
            resolution.reason ?? "missing reviewer reason")
        XCTAssertTrue(
            resolution.reviewStatus == .allowed
                || resolution.reviewStatus == .denied)
        XCTAssertNil(resolution.failureKind, resolution.reason ?? "")
        XCTAssertFalse(resolution.reason?.isEmpty ?? true)

        let events = await log.replay()
        let requested = events.compactMap { envelope -> PermissionReviewRequestedPayload? in
            if case .permissionReviewRequested(let payload) = envelope.event {
                return payload
            }
            return nil
        }
        let settled = events.compactMap { envelope -> PermissionReviewSettledPayload? in
            if case .permissionReviewSettled(let payload) = envelope.event {
                return payload
            }
            return nil
        }
        XCTAssertEqual(requested.count, 1)
        XCTAssertEqual(settled.count, 1)
        XCTAssertEqual(requested.first?.task.requestID, request.requestId)
        XCTAssertEqual(settled.first?.requestID, request.requestId)
    }

    private func makePermissionReviewRequest(
        sessionID: SessionID
    ) -> PermissionRequestPayload {
        let agent = AgentID(rawValue: "main")
        let arguments = #"{"content":"smoke","path":"smoke-output.txt"}"#
        let gate = PermissionReviewGateSnapshot(
            decision: .ask,
            risk: .medium,
            reason: "write a non-sensitive file inside the workspace",
            policyVersion: "translatis.real-smoke.v1")
        let intent = PermissionIntent(
            action: "filesystem.write",
            resources: [PermissionResource(
                kind: .workspacePath,
                value: "smoke-output.txt",
                access: .readWrite)],
            dataEffects: [.mutate],
            risks: [.workspaceMutation],
            replayPolicy: .doNotReplay)
        let authorization = ResolvedToolAuthorization(
            authorizationID: "real-permission-review-smoke",
            registryVersion: "translatis.real-smoke.v1",
            concreteToolID: "translatis.standard/write_file",
            descriptorFingerprint: ToolRegistry.authorizationDigest(
                "write_file|real-smoke"),
            toolName: "write_file",
            canonicalAction: intent.action,
            canonicalPermission: "filesystem.edit",
            actionPreview: PermissionActionPreview(
                kind: "workspace_write",
                fields: ["path": "smoke-output.txt"]),
            requiredCapabilities: [],
            membership: .notRequired,
            capabilityLeaseID: nil,
            capabilityTaskID: nil,
            workspaceLeaseID: nil,
            workspaceAccess: nil,
            workspaceRootIdentity: nil,
            invocation: ToolAuthorizationInvocationContext(
                sessionID: sessionID,
                agent: agent),
            normalizedArgumentsDigest: ToolRegistry.authorizationDigest(
                arguments),
            normalizedArgumentsCharacterCount: arguments.count,
            intent: intent,
            sideEffect: .write,
            risksNetwork: false,
            replayPolicy: .doNotReplay,
            deterministicGate: gate)
        let context = PermissionRequestContext(
            normalizedArgs: arguments,
            touchedPaths: ["smoke-output.txt"],
            risksNetwork: false,
            sideEffect: .write,
            intent: intent,
            gate: gate,
            authorization: authorization,
            replayPolicy:
                ToolExecutionReplayPolicy.doNotReplay.rawValue)
        return PermissionRequestPayload(
            requestId: RequestID.new(),
            agent: agent,
            tool: "write_file",
            args: arguments,
            risk: .medium,
            reason: gate.reason,
            context: context,
            approvalMode: .automaticReviewer)
    }

    private struct KnowledgeQualityCorpus {
        struct Document {
            let id: String
            let text: String
        }
        struct Query {
            let text: String
            let relevant: Set<String>
        }
        let documents: [Document]
        let queries: [Query]
    }

    private struct KnowledgeQualityMetrics {
        let mrr: Double
        let nDCGAtFive: Double
        let recallAtFive: Double
    }

    private static let knowledgeQualityCorpus = KnowledgeQualityCorpus(
        documents: [
            .init(id: "event-log", text: "EventLog stores append-only JSONL and is the canonical durable truth for a session."),
            .init(id: "workspace-lease", text: "WorkspaceLease and PathConfinement prevent an agent from reading or mutating paths outside its exact reviewed workspace root."),
            .init(id: "bookmark", text: "macOS external knowledge access persists an exact security-scoped bookmark per session and revalidates the canonical directory identity after restart."),
            .init(id: "embedding", text: "Document and query embeddings must share the complete compatible model identity, dimensions, normalization, instructions, and truncation policy."),
            .init(id: "reranker", text: "A dedicated semantic reranker receives the query and bounded authorized candidates after recall; provider failure must not fall back to cosine order."),
            .init(id: "snapshot", text: "Knowledge publication installs an immutable snapshot and atomically advances a revisioned current pointer under an exclusive writer lock."),
            .init(id: "cancellation", text: "Swift structured cancellation propagates to provider and tool tasks, which must drain before a runtime reports shutdown complete."),
            .init(id: "permission", text: "The deterministic policy gate can hard deny, while the model reviewer may only narrow a pass decision and cannot expand authority."),
            .init(id: "weather", text: "A maritime weather forecast estimates wind speed, cloud cover, rainfall, and wave height for coastal navigation."),
            .init(id: "cooking", text: "Bread fermentation depends on flour hydration, yeast activity, dough temperature, and proofing time."),
            .init(id: "zh-grounding", text: "最终回答只能引用本轮检索返回并重新校验过来源、哈希和精确快照版本的证据。"),
            .init(id: "code", text: "A compare-and-swap update rejects stale expected_store_id and expected_snapshot_id values before publishing new index bytes."),
        ],
        queries: [
            .init(text: "What is the authoritative persisted history for a session?", relevant: ["event-log"]),
            .init(text: "What confines an agent to the user-approved project directory?", relevant: ["workspace-lease"]),
            .init(text: "外部知识库目录在应用重启后怎样恢复精确授权？", relevant: ["bookmark"]),
            .init(text: "Why is semantic ranking required after candidate recall?", relevant: ["reranker"]),
            .init(text: "What must finish before shutdown is reported complete?", relevant: ["cancellation"]),
            .init(text: "How is a stale concurrent knowledge update rejected?", relevant: ["code", "snapshot"]),
            .init(text: "最终答案可以引用哪些知识证据？", relevant: ["zh-grounding"]),
            .init(text: "Can the model permission reviewer override a deterministic hard deny?", relevant: ["permission"]),
        ])

    private static func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -.infinity }
        var dot = 0.0
        var lhsNorm = 0.0
        var rhsNorm = 0.0
        for (left, right) in zip(lhs, rhs) {
            dot += left * right
            lhsNorm += left * left
            rhsNorm += right * right
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return -.infinity }
        return dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
    }

    private static func addingUsage(
        _ current: ProviderKnowledgeUsage?,
        _ increment: ProviderKnowledgeUsage?
    ) -> ProviderKnowledgeUsage? {
        guard let current else { return increment }
        return current.adding(increment)
    }

    private static func usageSummary(_ usage: ProviderKnowledgeUsage?) -> String {
        guard let usage else { return "unreported" }
        let values: [(String, Double?)] = [
            ("input_tokens", usage.inputTokens),
            ("output_tokens", usage.outputTokens),
            ("total_tokens", usage.totalTokens),
            ("billed_input_tokens", usage.billedInputTokens),
            ("billed_output_tokens", usage.billedOutputTokens),
            ("billed_search_units", usage.billedSearchUnits),
        ]
        let fields = values.compactMap { name, value -> String? in
            guard let value else { return nil }
            return name + ":" + String(format: "%.3f", value)
        }
        return fields.isEmpty ? "unreported" : fields.joined(separator: ",")
    }

    private static func qualityMetrics(
        rankings: [[String]],
        queries: [KnowledgeQualityCorpus.Query]
    ) -> KnowledgeQualityMetrics {
        precondition(rankings.count == queries.count && !queries.isEmpty)
        var reciprocalRank = 0.0
        var nDCG = 0.0
        var recallAtFive = 0.0
        for (ranking, query) in zip(rankings, queries) {
            if let offset = ranking.firstIndex(where: query.relevant.contains) {
                reciprocalRank += 1.0 / Double(offset + 1)
            }
            if !Set(ranking.prefix(5)).isDisjoint(with: query.relevant) {
                recallAtFive += 1
            }
            let actual = ranking.prefix(5).enumerated().reduce(0.0) {
                total, item in
                query.relevant.contains(item.element)
                    ? total + 1.0 / log2(Double(item.offset) + 2.0)
                    : total
            }
            let idealCount = min(5, query.relevant.count)
            let ideal = (0..<idealCount).reduce(0.0) {
                $0 + 1.0 / log2(Double($1) + 2.0)
            }
            nDCG += ideal == 0 ? 0 : actual / ideal
        }
        let count = Double(queries.count)
        return KnowledgeQualityMetrics(
            mrr: reciprocalRank / count,
            nDCGAtFive: nDCG / count,
            recallAtFive: recallAtFive / count)
    }
}
